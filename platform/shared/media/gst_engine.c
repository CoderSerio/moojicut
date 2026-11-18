#include "platform/shared/media/gst_engine.h"
#include <ges/ges.h>
#include <gst/app/gstappsink.h>
#include <gst/pbutils/pbutils.h>
#include <gst/video/video.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

struct MCGstEngine {
    GESPipeline *pipeline;
    GstBus *bus;
    GstAppSink *sink;
    MCGstPlan plan;
    bool rendering;
    int aac_priming;
};

static bool fail(char *out, size_t capacity, const char *message, GError *error) {
    if (out && capacity) snprintf(out, capacity, "%s%s%s", message,
        error ? ": " : "", error ? error->message : "");
    g_clear_error(&error);
    return false;
}

static GstClockTime time_ns(int64_t ticks) {
    return gst_util_uint64_scale_round((guint64)ticks, GST_SECOND, 90000);
}

static bool initialize_media(char *error, size_t capacity) {
    GError *failure = NULL;
    if (!gst_init_check(NULL, NULL, &failure)) return fail(error, capacity, "GStreamer initialization failed", failure);
    if (!ges_init()) return fail(error, capacity, "GStreamer Editing Services is unavailable", NULL);
    /* Bound discovery at its actual owner. Abandoning an async GES request at
     * an independent deadline would leave its GTask/callback on a context that
     * a closing media worker can no longer dispatch. GES cancellation alone
     * does not complete all cached-asset requests. */
#if GES_VERSION_MAJOR > 1 || (GES_VERSION_MAJOR == 1 && GES_VERSION_MINOR >= 24)
    GESDiscovererManager *manager = ges_discoverer_manager_get_default();
    ges_discoverer_manager_set_timeout(manager, 10 * GST_SECOND);
    gst_object_unref(manager);
#else
    GESUriClipAssetClass *asset_class = g_type_class_ref(GES_TYPE_URI_CLIP_ASSET);
    ges_uri_clip_asset_class_set_timeout(asset_class, 10 * GST_SECOND);
    g_type_class_unref(asset_class);
#endif
    /* encodebin filters out rank-NONE factories even with an explicit profile
     * factory name. Make the pinned AAC encoder eligible in this process;
     * profiles below still require that exact factory. No registry file or
     * user environment is modified. */
    GstElementFactory *aac = gst_element_factory_find("avenc_aac");
    if (aac) {
        if (gst_plugin_feature_get_rank(GST_PLUGIN_FEATURE(aac)) < GST_RANK_SECONDARY)
            gst_plugin_feature_set_rank(GST_PLUGIN_FEATURE(aac), GST_RANK_SECONDARY);
        gst_object_unref(aac);
    }
    return true;
}

bool mc_gst_media_init(char *error, size_t capacity) {
    static gsize initialized;
    static char initialization_error[1024];
    if (g_once_init_enter(&initialized)) {
        bool success = initialize_media(initialization_error, sizeof initialization_error);
        g_once_init_leave(&initialized, success ? 1 : 2);
    }
    return initialized == 1 || fail(error, capacity, initialization_error, NULL);
}

bool mc_gst_media_probe(const char *path, MCGstMetadata *metadata, char *error, size_t capacity) {
    if (!path || !metadata) return fail(error, capacity, "Invalid source", NULL);
    GError *failure = NULL;
    gchar *uri = gst_filename_to_uri(path, &failure);
    if (!uri) return fail(error, capacity, "Invalid source path", failure);
    GstDiscoverer *discoverer = gst_discoverer_new(10 * GST_SECOND, &failure);
    if (!discoverer) { g_free(uri); return fail(error, capacity, "Cannot probe source", failure); }
    GstDiscovererInfo *info = gst_discoverer_discover_uri(discoverer, uri, &failure);
    g_free(uri); g_object_unref(discoverer);
    if (!info || gst_discoverer_info_get_result(info) != GST_DISCOVERER_OK) {
        if (info) gst_discoverer_info_unref(info);
        return fail(error, capacity, "Cannot decode source", failure);
    }
    GList *video = gst_discoverer_info_get_video_streams(info);
    GList *audio = gst_discoverer_info_get_audio_streams(info);
    GstClockTime duration = gst_discoverer_info_get_duration(info);
    bool valid = video && !video->next && (!audio || !audio->next) && GST_CLOCK_TIME_IS_VALID(duration) && duration > 0 &&
        duration <= 604800 * GST_SECOND;
    if (valid) {
        GstDiscovererVideoInfo *track = GST_DISCOVERER_VIDEO_INFO(video->data);
        metadata->width = (int)gst_discoverer_video_info_get_width(track);
        metadata->height = (int)gst_discoverer_video_info_get_height(track);
        const GstTagList *tags = gst_discoverer_stream_info_get_tags(GST_DISCOVERER_STREAM_INFO(track));
        gchar *orientation = NULL;
        if (tags && gst_tag_list_get_string(tags, GST_TAG_IMAGE_ORIENTATION, &orientation)) {
            if (strstr(orientation, "rotate-90") || strstr(orientation, "rotate-270")) {
                int width = metadata->width; metadata->width = metadata->height; metadata->height = width;
            }
            g_free(orientation);
        }
        metadata->duration_ms = (double)duration / GST_MSECOND;
        metadata->has_audio = audio != NULL;
        valid = metadata->width > 0 && metadata->height > 0 && metadata->width <= 32768 && metadata->height <= 32768 &&
            (guint64)metadata->width * (guint64)metadata->height <= 67108864;
    }
    gst_discoverer_stream_info_list_free(video); gst_discoverer_stream_info_list_free(audio);
    gst_discoverer_info_unref(info); g_clear_error(&failure);
    return valid || fail(error, capacity, "Source needs one bounded video stream with a known duration", NULL);
}

static bool plan_bounds(const MCGstPlan *p) {
    if (!p || p->width <= 0 || p->height <= 0 || p->width > 32768 || p->height > 32768 ||
        (guint64)p->width * (guint64)p->height > 67108864 ||
        p->crop_x < 0 || p->crop_y < 0 || p->crop_width <= 0 || p->crop_height <= 0 ||
        p->crop_width > p->width || p->crop_height > p->height ||
        p->crop_x > p->width - p->crop_width || p->crop_y > p->height - p->crop_height ||
        p->duration <= 0 || p->duration > INT64_C(54432000000) ||
        p->video_count > MC_GST_MAX_CLIPS || p->audio_count > MC_GST_MAX_CLIPS) return false;
    for (int kind = 0; kind < 2; kind++) {
        size_t count = kind ? p->audio_count : p->video_count;
        const MCGstClip *clips = kind ? p->audio : p->video;
        for (size_t i = 0; i < count; i++) {
            const MCGstClip *c = clips + i;
            if (c->start < 0 || c->source_start < 0 || c->source_end <= c->source_start ||
                c->source_end > INT64_C(54432000000) || c->duration <= 0 || c->duration > p->duration ||
                c->start > p->duration - c->duration) return false;
            double rate = (double)(c->source_end - c->source_start) / (double)c->duration;
            if (rate < 0.25 || rate > 4) return false;
        }
    }
    return true;
}

static GESLayer *layer_new(GESTimeline *timeline, guint priority) {
    GESLayer *layer = ges_layer_new();
    ges_layer_set_priority(layer, priority); ges_layer_set_auto_transition(layer, FALSE);
    if (!ges_timeline_add_layer(timeline, layer)) { g_object_unref(layer); return NULL; }
    return layer;
}

static bool child_integer(GESTimelineElement *element, const char *name, int number) {
    GValue value = G_VALUE_INIT; g_value_init(&value, G_TYPE_INT); g_value_set_int(&value, number);
    bool result = ges_timeline_element_set_child_property(element, name, &value);
    g_value_unset(&value); return result;
}

static bool add_clip(GESTimeline *timeline, GESUriClipAsset *asset, const MCGstPlan *plan,
                     const MCGstClip *c, bool audio, guint priority, GError **error) {
    GESLayer *layer = layer_new(timeline, priority);
    if (!layer) return false;
    GESClip *clip = ges_layer_add_asset_full(layer, GES_ASSET(asset), time_ns(c->start),
        time_ns(c->source_start), time_ns(c->duration), audio ? GES_TRACK_TYPE_AUDIO : GES_TRACK_TYPE_VIDEO, error);
    if (!clip) return false;
    double rate = (double)(c->source_end - c->source_start) / (double)c->duration;
    if (rate != 1) {
        gchar rate_text[G_ASCII_DTOSTR_BUF_SIZE]; g_ascii_dtostr(rate_text, sizeof rate_text, rate);
        gchar *description = g_strconcat(audio ? "pitch tempo=" : "videorate rate=", rate_text, NULL);
        GESEffect *effect = ges_effect_new(description); g_free(description);
        if (!effect) return false;
        if (!ges_clip_add_top_effect(clip, GES_BASE_EFFECT(effect), -1, error)) { g_object_unref(effect); return false; }
    }
    if (!audio) {
        GList *children = ges_container_get_children(GES_CONTAINER(clip), FALSE);
        bool positioned = false;
        for (GList *at = children; at; at = at->next) {
            if (!GES_IS_VIDEO_SOURCE(at->data)) continue;
            GESTimelineElement *source = GES_TIMELINE_ELEMENT(at->data);
            positioned = child_integer(source, "width", plan->width) && child_integer(source, "height", plan->height) &&
                child_integer(source, "posx", -plan->crop_x) && child_integer(source, "posy", -plan->crop_y);
        }
        g_list_free_full(children, g_object_unref);
        if (!positioned) return false;
    }
    return ges_timeline_element_get_duration(GES_TIMELINE_ELEMENT(clip)) == time_ns(c->duration) &&
        ges_timeline_element_get_inpoint(GES_TIMELINE_ELEMENT(clip)) == time_ns(c->source_start);
}

typedef struct {
    GESUriClipAsset *asset;
    GError *error;
    gboolean completed;
} AssetRequest;

static void asset_ready(GObject *source, GAsyncResult *result, gpointer context) {
    (void)source;
    AssetRequest *request = context;
    request->asset = ges_uri_clip_asset_finish(result, &request->error);
    request->completed = TRUE;
}

static void release_fallback_context(gpointer context) {
    g_main_context_unref(context);
}

static GESUriClipAsset *request_asset(const char *uri, GError **error) {
    /* GES request_sync pumps the process-default context, while its GTask is
     * delivered to the caller's thread-default context. That deadlocks a media
     * worker. Use the async API (available in GES 1.20) and dispatch only this
     * worker's context. Standalone callers also get a private, thread-stable
     * context: GES caches each thread's discoverer and its original context. */
    static GPrivate fallback_context = G_PRIVATE_INIT(release_fallback_context);
    GMainContext *context = g_main_context_get_thread_default();
    gboolean pushed = !context || context == g_main_context_default();
    if (pushed) {
        context = g_private_get(&fallback_context);
        if (!context) {
            context = g_main_context_new();
            g_private_set(&fallback_context, context);
        }
        g_main_context_push_thread_default(context);
    }
    AssetRequest request = {0};
    ges_uri_clip_asset_new(uri, NULL, asset_ready, &request);
    /* The discoverer above supplies the finite timeout. Wait for its terminal
     * callback even on failure; no stack data or request remains after return,
     * and CLOSE must not acknowledge resources before this operation drains. */
    while (!request.completed) g_main_context_iteration(context, TRUE);
    if (pushed) g_main_context_pop_thread_default(context);
    if (request.error) g_propagate_error(error, request.error);
    return request.asset;
}

MCGstEngine *mc_gst_engine_new(const char *path, const MCGstPlan *plan, char *error, size_t capacity) {
    if (!path || !plan_bounds(plan)) { fail(error, capacity, "Invalid copied render plan", NULL); return NULL; }
    GError *failure = NULL;
    gchar *uri = gst_filename_to_uri(path, &failure);
    if (!uri) { fail(error, capacity, "Invalid source path", failure); return NULL; }
    GESUriClipAsset *asset = request_asset(uri, &failure); g_free(uri);
    if (!asset) { fail(error, capacity, "Cannot open source media", failure); return NULL; }
    GESTimeline *timeline = ges_timeline_new();
    GESTrack *video = GES_TRACK(ges_video_track_new());
    GESTrack *audio = plan->audio_count ? GES_TRACK(ges_audio_track_new()) : NULL;
    GstCaps *caps = gst_caps_new_simple("video/x-raw", "width", G_TYPE_INT, plan->crop_width,
        "height", G_TYPE_INT, plan->crop_height, "framerate", GST_TYPE_FRACTION, 30, 1,
        "pixel-aspect-ratio", GST_TYPE_FRACTION, 1, 1, NULL);
    ges_track_set_restriction_caps(video, caps); gst_caps_unref(caps);
    if (audio) {
        caps = gst_caps_new_simple("audio/x-raw", "rate", G_TYPE_INT, 48000, "channels", G_TYPE_INT, 2, NULL);
        ges_track_set_restriction_caps(audio, caps); gst_caps_unref(caps);
    }
    if (!ges_timeline_add_track(timeline, video)) {
        g_object_unref(video); if (audio) g_object_unref(audio); goto rejected;
    }
    if (audio && !ges_timeline_add_track(timeline, audio)) { g_object_unref(audio); goto rejected; }
    /* A black baseline preserves output duration when muted/independent audio
     * extends beyond the last video clip. It contains no source audio. */
    GESLayer *background = layer_new(timeline, (guint)(plan->video_count + plan->audio_count));
    GESTestClip *black = ges_test_clip_new();
    ges_clip_set_supported_formats(GES_CLIP(black), GES_TRACK_TYPE_VIDEO);
    ges_test_clip_set_vpattern(black, GES_VIDEO_TEST_PATTERN_BLACK);
    ges_timeline_element_set_duration(GES_TIMELINE_ELEMENT(black), time_ns(plan->duration));
    if (!background || !ges_layer_add_clip(background, GES_CLIP(black))) { g_object_unref(black); goto rejected; }
    guint priority = 0;
    for (size_t i = 0; i < plan->video_count; i++)
        if (!add_clip(timeline, asset, plan, plan->video + i, false, priority++, &failure)) goto rejected;
    for (size_t i = 0; i < plan->audio_count; i++)
        if (!add_clip(timeline, asset, plan, plan->audio + i, true, priority++, &failure)) goto rejected;
    if (!ges_timeline_commit_sync(timeline)) goto rejected;
    MCGstEngine *engine = g_new0(MCGstEngine, 1); engine->plan = *plan;
    engine->pipeline = ges_pipeline_new();
    if (!ges_pipeline_set_timeline(engine->pipeline, timeline)) {
        g_object_unref(engine->pipeline); g_free(engine); goto rejected;
    }
    g_object_unref(asset);
    engine->bus = gst_element_get_bus(GST_ELEMENT(engine->pipeline));
    /* Avoid implicit device probing even for a fresh render-only pipeline. */
    GstElement *video_sink = gst_element_factory_make("fakesink", NULL);
    GstElement *audio_sink = gst_element_factory_make("fakesink", NULL);
    if (!video_sink || !audio_sink) {
        if (video_sink) gst_object_unref(video_sink);
        if (audio_sink) gst_object_unref(audio_sink);
        mc_gst_engine_free(engine); fail(error, capacity, "Required fallback sink is unavailable", NULL); return NULL;
    }
    gst_object_ref_sink(video_sink); gst_object_ref_sink(audio_sink);
    ges_pipeline_preview_set_video_sink(engine->pipeline, video_sink);
    ges_pipeline_preview_set_audio_sink(engine->pipeline, audio_sink);
    gst_object_unref(video_sink); gst_object_unref(audio_sink);
    return engine;
rejected:
    g_object_unref(asset); g_object_unref(timeline);
    fail(error, capacity, "Media backend rejected the render plan", failure); return NULL;
}

static bool set_state(MCGstEngine *engine, GstState state, char *error, size_t capacity) {
    if (gst_element_set_state(GST_ELEMENT(engine->pipeline), state) == GST_STATE_CHANGE_FAILURE)
        return fail(error, capacity, "Media state change failed", NULL);
    GstState current, pending;
    GstStateChangeReturn result = gst_element_get_state(GST_ELEMENT(engine->pipeline), &current, &pending, 10 * GST_SECOND);
    if (result == GST_STATE_CHANGE_FAILURE || current != state || pending != GST_STATE_VOID_PENDING) {
        if (mc_gst_engine_poll(engine, error, capacity) != MC_GST_ERROR)
            fail(error, capacity, "Media state change timed out", NULL);
        return false;
    }
    return true;
}

bool mc_gst_engine_preview(MCGstEngine *engine, bool silent, char *error, size_t capacity) {
    if (!engine || engine->rendering) return fail(error, capacity, "Invalid preview session", NULL);
    GstElement *sink = gst_element_factory_make("appsink", NULL);
    if (!sink) return fail(error, capacity, "Video frame sink is unavailable", NULL);
    GstCaps *caps = gst_caps_from_string("video/x-raw,format=BGRA");
    g_object_set(sink, "caps", caps, "max-buffers", 2u, "drop", TRUE, "sync", TRUE, NULL); gst_caps_unref(caps);
    gst_object_ref_sink(sink);
    ges_pipeline_preview_set_video_sink(engine->pipeline, sink);
    engine->sink = GST_APP_SINK(sink);
    GError *failure = NULL;
    GstElement *sound = gst_parse_bin_from_description(silent || !engine->plan.audio_count ? "fakesink sync=true" :
        "scaletempo ! audioconvert ! audioresample ! autoaudiosink", TRUE, &failure);
    if (!sound) return fail(error, capacity, "Audio preview is unavailable", failure);
    gst_object_ref_sink(sound); ges_pipeline_preview_set_audio_sink(engine->pipeline, sound); gst_object_unref(sound);
    if (!ges_pipeline_set_mode(engine->pipeline, GES_PIPELINE_MODE_PREVIEW))
        return fail(error, capacity, "Cannot prepare timeline preview", NULL);
    return set_state(engine, GST_STATE_PAUSED, error, capacity);
}

bool mc_gst_engine_seek(MCGstEngine *engine, double milliseconds, double rate, bool playing,
                        char *error, size_t capacity) {
    if (!engine || !engine->sink || !isfinite(milliseconds) || milliseconds < 0 ||
        !isfinite(rate) || rate < 0.25 || rate > 4) return fail(error, capacity, "Invalid preview seek", NULL);
    if (!set_state(engine, GST_STATE_PAUSED, error, capacity)) return false;
    /* A retained PAUSED state is not proof that a new seek has preroll'd. Drain
     * the old bus before issuing this serial operation, then wait for its new
     * ASYNC_DONE. Otherwise a fast scrub can publish the previous seek's frame. */
    if (mc_gst_engine_poll(engine, error, capacity) == MC_GST_ERROR) return false;
    GstSample *old;
    while ((old = gst_app_sink_try_pull_preroll(engine->sink, 0))) gst_sample_unref(old);
    while ((old = gst_app_sink_try_pull_sample(engine->sink, 0))) gst_sample_unref(old);
    gint64 position = (gint64)(fmin(milliseconds * GST_MSECOND, (double)time_ns(engine->plan.duration) - 1));
    if (!gst_element_seek(GST_ELEMENT(engine->pipeline), rate, GST_FORMAT_TIME,
        GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE, GST_SEEK_TYPE_SET, position,
        GST_SEEK_TYPE_SET, (gint64)time_ns(engine->plan.duration)))
        return fail(error, capacity, "Preview seek rejected", NULL);
    GstMessage *done = gst_bus_timed_pop_filtered(engine->bus, 10 * GST_SECOND,
        GST_MESSAGE_ASYNC_DONE | GST_MESSAGE_ERROR);
    if (!done) return fail(error, capacity, "Preview seek timed out", NULL);
    if (GST_MESSAGE_TYPE(done) == GST_MESSAGE_ERROR) {
        GError *failure = NULL; gchar *debug = NULL;
        gst_message_parse_error(done, &failure, &debug);
        if (debug) g_printerr("GStreamer seek error from %s: %s\n", GST_OBJECT_NAME(GST_MESSAGE_SRC(done)), debug);
        g_free(debug); gst_message_unref(done);
        return fail(error, capacity, "Preview seek failed", failure);
    }
    gst_message_unref(done);
    return set_state(engine, playing ? GST_STATE_PLAYING : GST_STATE_PAUSED, error, capacity);
}

bool mc_gst_engine_play(MCGstEngine *engine, bool playing, char *error, size_t capacity) {
    if (!engine || !engine->sink) return fail(error, capacity, "Preview is not ready", NULL);
    return set_state(engine, playing ? GST_STATE_PLAYING : GST_STATE_PAUSED, error, capacity);
}

bool mc_gst_engine_render(MCGstEngine *engine, const char *path, bool mp4, char *error, size_t capacity) {
    if (!engine || engine->sink || !path) return fail(error, capacity, "Invalid export session", NULL);
    if (g_file_test(path, G_FILE_TEST_EXISTS | G_FILE_TEST_IS_SYMLINK))
        return fail(error, capacity, "Intermediate output already exists", NULL);
    GError *failure = NULL; gchar *uri = gst_filename_to_uri(path, &failure);
    if (!uri) return fail(error, capacity, "Invalid output path", failure);
    GstCaps *caps = gst_caps_from_string(mp4 ? "video/quicktime,variant=iso" : "video/x-matroska");
    GstEncodingContainerProfile *profile = gst_encoding_container_profile_new("moojicut", "Mooji Cut", caps, NULL);
    gst_caps_unref(caps);
    caps = gst_caps_from_string(mp4 ? "video/x-h264" : "video/x-vp8");
    GstEncodingVideoProfile *video = gst_encoding_video_profile_new(caps, NULL, NULL, 1); gst_caps_unref(caps);
    if (mp4) {
        const char *encoder = NULL;
        const char *candidates[] = { "openh264enc", "mfh264enc", "vtenc_h264" };
        for (size_t i = 0; i < G_N_ELEMENTS(candidates); i++) {
            GstElementFactory *factory = gst_element_factory_find(candidates[i]);
            if (factory) { gst_object_unref(factory); encoder = candidates[i]; break; }
        }
        if (!encoder) {
            gst_encoding_profile_unref(video); gst_encoding_profile_unref(profile); g_free(uri);
            return fail(error, capacity, "A supported H.264 encoder is unavailable", NULL);
        }
        gst_encoding_profile_set_preset_name(GST_ENCODING_PROFILE(video), encoder);
        guint bitrate = (guint)CLAMP((guint64)engine->plan.crop_width * (guint64)engine->plan.crop_height *
            (engine->plan.quality ? 8u : 4u), 800000u, 24000000u);
        gst_encoding_profile_set_element_properties(GST_ENCODING_PROFILE(video),
            gst_structure_new("element-properties", "bitrate", G_TYPE_UINT, bitrate, NULL));
    }
    /* Timeline caps already fix 30 fps. A second videorate adds a terminal frame. */
    gst_encoding_video_profile_set_variableframerate(video, TRUE);
    gst_encoding_container_profile_add_profile(profile, GST_ENCODING_PROFILE(video));
    /* A silent recording or muted project has no output audio stream. An empty
     * GES audio track/profile would synthesize silence, probe audio devices and
     * falsely declare AAC priming even though the plan contains no audio. */
    engine->aac_priming = 0;
    if (engine->plan.audio_count) {
        caps = gst_caps_from_string(mp4 ? "audio/mpeg,mpegversion=4,base-profile=lc" : "audio/x-flac");
        GstCaps *restriction = gst_caps_from_string("audio/x-raw,rate=48000,channels=2");
        GstEncodingAudioProfile *audio = gst_encoding_audio_profile_new(caps, NULL, restriction, 1);
        gst_caps_unref(caps); gst_caps_unref(restriction);
        if (mp4) {
            /* voaacenc discards a partial terminal frame; other AAC encoders
             * have different priming contracts. Use the verified AAC-LC one. */
            gst_encoding_profile_set_preset_name(GST_ENCODING_PROFILE(audio), "avenc_aac");
            engine->aac_priming = 1024;
        }
        gst_encoding_container_profile_add_profile(profile, GST_ENCODING_PROFILE(audio));
    }
    bool ready = ges_pipeline_set_render_settings(engine->pipeline, uri, GST_ENCODING_PROFILE(profile)) &&
        ges_pipeline_set_mode(engine->pipeline, GES_PIPELINE_MODE_RENDER);
    gst_encoding_profile_unref(profile); g_free(uri);
    if (!ready) return fail(error, capacity, "Output codecs are unavailable", NULL);
    engine->rendering = true;
    return gst_element_set_state(GST_ELEMENT(engine->pipeline), GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE ||
        fail(error, capacity, "Cannot start export", NULL);
}

int mc_gst_engine_aac_priming(MCGstEngine *engine) {
    return engine ? engine->aac_priming : 0;
}

int mc_gst_engine_poll(MCGstEngine *engine, char *error, size_t capacity) {
    if (!engine) { fail(error, capacity, "Media session closed", NULL); return MC_GST_ERROR; }
    GstMessage *message;
    while ((message = gst_bus_pop(engine->bus))) {
        GstMessageType type = GST_MESSAGE_TYPE(message);
        if (type == GST_MESSAGE_ERROR) {
            GError *failure = NULL; gchar *debug = NULL;
            gst_message_parse_error(message, &failure, &debug);
            if (debug) g_printerr("GStreamer processing error from %s: %s\n", GST_OBJECT_NAME(GST_MESSAGE_SRC(message)), debug);
            g_free(debug);
            fail(error, capacity, "Media processing failed", failure); gst_message_unref(message); return MC_GST_ERROR;
        }
        gst_message_unref(message);
        if (type == GST_MESSAGE_EOS) return MC_GST_EOS;
    }
    return MC_GST_RUNNING;
}

double mc_gst_engine_position(MCGstEngine *engine) {
    gint64 time = 0;
    if (!engine || !gst_element_query_position(GST_ELEMENT(engine->pipeline), GST_FORMAT_TIME, &time)) return -1;
    return (double)time / GST_MSECOND;
}

bool mc_gst_engine_frame(MCGstEngine *engine, MCGstFrame *out) {
    if (!engine || !engine->sink || !out) return false;
    /* Pulling a regular sample clears the stored preroll even when PAUSED and
     * no regular sample is queued. Consume preroll first after an accurate seek. */
    GstSample *sample = gst_app_sink_try_pull_preroll(engine->sink, 0);
    if (!sample) sample = gst_app_sink_try_pull_sample(engine->sink, 0);
    if (!sample) return false;
    GstVideoInfo info; GstVideoFrame frame;
    GstBuffer *buffer = gst_sample_get_buffer(sample);
    bool valid = gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) &&
        GST_VIDEO_INFO_FORMAT(&info) == GST_VIDEO_FORMAT_BGRA && gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ);
    if (valid) {
        int width = GST_VIDEO_INFO_WIDTH(&info), height = GST_VIDEO_INFO_HEIGHT(&info);
        int stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
        valid = width > 0 && height > 0 && width <= 32768 && height <= 32768 && stride >= width * 4 &&
            (gsize)width * (gsize)height <= 67108864;
        if (valid) {
            out->width = width; out->height = height; out->stride = width * 4;
            out->pts_ns = GST_BUFFER_PTS_IS_VALID(buffer) ? (int64_t)GST_BUFFER_PTS(buffer) : -1;
            out->pixels = g_malloc((gsize)out->stride * (gsize)height);
            const unsigned char *pixels = GST_VIDEO_FRAME_PLANE_DATA(&frame, 0);
            for (int y = 0; y < height; y++) memcpy(out->pixels + (gsize)y * (gsize)out->stride,
                pixels + (gsize)y * (gsize)stride, (gsize)out->stride);
        }
        gst_video_frame_unmap(&frame);
    }
    gst_sample_unref(sample); return valid;
}

void mc_gst_frame_clear(MCGstFrame *frame) {
    if (!frame) return;
    g_free(frame->pixels); memset(frame, 0, sizeof *frame);
}

void mc_gst_engine_free(MCGstEngine *engine) {
    if (!engine) return;
    gst_element_set_state(GST_ELEMENT(engine->pipeline), GST_STATE_NULL);
    if (engine->sink) gst_object_unref(engine->sink);
    gst_object_unref(engine->bus); gst_object_unref(engine->pipeline); g_free(engine);
}
