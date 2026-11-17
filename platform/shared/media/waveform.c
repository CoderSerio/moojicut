#include "platform/shared/media/waveform.h"
#include <gst/app/gstappsink.h>
#include <gst/audio/audio.h>
#include <gst/pbutils/pbutils.h>
#include <math.h>
#include <string.h>

struct MCWaveformAnalysis {
    GThread *thread;
    GMutex mutex;
    gint cancelled;
    char *source;
    float *peaks;
    bool taken;
    MCWaveformState state;
};

typedef struct {
    bool done;
    int status;
    char error[1024];
} Discovery;

typedef struct {
    GstElement *convert;
    gint audio_pads;
    gint link_failed;
} Decode;

static void text_error(char *out, size_t capacity, const char *message) {
    if (!out || !capacity) return;
    char *valid = g_utf8_make_valid(message ? message : "Audio analysis failed", -1);
    g_strlcpy(out, valid, capacity);
    const char *end = NULL;
    if (!g_utf8_validate(out, -1, &end)) out[end - out] = '\0';
    g_free(valid);
}

static bool cancelled(MCWaveformAnalysis *analysis) {
    return g_atomic_int_get(&analysis->cancelled) != 0;
}

static void discovered(GstDiscoverer *discoverer, GstDiscovererInfo *info, GError *error, gpointer data) {
    (void)discoverer;
    Discovery *result = data;
    GstDiscovererResult status = gst_discoverer_info_get_result(info);
    if (status == GST_DISCOVERER_OK) {
        GList *audio = gst_discoverer_info_get_audio_streams(info);
        result->status = !audio ? MC_WAVEFORM_NO_AUDIO : audio->next ? MC_WAVEFORM_UNSUPPORTED : MC_WAVEFORM_READY;
        if (audio && audio->next) text_error(result->error, sizeof result->error, "Waveform analysis supports one source audio stream");
        gst_discoverer_stream_info_list_free(audio);
    } else {
        result->status = status == GST_DISCOVERER_MISSING_PLUGINS ? MC_WAVEFORM_UNSUPPORTED : MC_WAVEFORM_FAILED;
        text_error(result->error, sizeof result->error, error ? error->message : "Cannot inspect source audio");
    }
    result->done = true;
}

static int discover(MCWaveformAnalysis *analysis, GMainContext *context, const char *uri,
                    char *error, size_t capacity) {
    GError *failure = NULL;
    GstDiscoverer *discoverer = gst_discoverer_new(10 * GST_SECOND, &failure);
    if (!discoverer) {
        text_error(error, capacity, failure ? failure->message : "Audio discoverer is unavailable");
        g_clear_error(&failure); return MC_WAVEFORM_FAILED;
    }
    Discovery result = {.status=MC_WAVEFORM_FAILED};
    gulong callback = g_signal_connect(discoverer, "discovered", G_CALLBACK(discovered), &result);
    gst_discoverer_start(discoverer);
    bool requested = gst_discoverer_discover_uri_async(discoverer, uri);
    gint64 deadline = g_get_monotonic_time() + 12000000;
    while (requested && !result.done && !cancelled(analysis) && g_get_monotonic_time() < deadline) {
        for (int i = 0; i < 64 && g_main_context_pending(context); i++) g_main_context_iteration(context, FALSE);
        if (!result.done && !cancelled(analysis)) g_usleep(5000);
    }
    // Stop destroys discovery's active pipeline, then disconnect before the
    // private callback storage leaves scope. No background task is abandoned.
    gst_discoverer_stop(discoverer);
    g_signal_handler_disconnect(discoverer, callback);
    g_object_unref(discoverer);
    if (cancelled(analysis)) return MC_WAVEFORM_CANCELLED;
    if (!result.done) {
        text_error(error, capacity, requested ? "Audio discovery timed out" : "Audio discovery was rejected");
        return MC_WAVEFORM_FAILED;
    }
    if (result.error[0]) text_error(error, capacity, result.error);
    return result.status;
}

static void decoded_pad(GstElement *decoder, GstPad *pad, gpointer data) {
    (void)decoder;
    Decode *decode = data;
    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) caps = gst_pad_query_caps(pad, NULL);
    bool audio = caps && !gst_caps_is_empty(caps) &&
        g_str_has_prefix(gst_structure_get_name(gst_caps_get_structure(caps, 0)), "audio/x-raw");
    if (caps) gst_caps_unref(caps);
    if (!audio) return;
    if (g_atomic_int_add(&decode->audio_pads, 1) != 0) return;
    GstPad *sink = gst_element_get_static_pad(decode->convert, "sink");
    if (!sink || gst_pad_link(pad, sink) != GST_PAD_LINK_OK) g_atomic_int_set(&decode->link_failed, 1);
    if (sink) gst_object_unref(sink);
}

static int sample_peaks(MCWaveformAnalysis *analysis, GstSample *sample,
                        char *error, size_t capacity) {
    GstBuffer *buffer = gst_sample_get_buffer(sample);
    const GstSegment *segment = gst_sample_get_segment(sample);
    GstAudioInfo info;
    gst_audio_info_init(&info);
    if (!buffer || !segment || segment->format != GST_FORMAT_TIME ||
        !GST_BUFFER_PTS_IS_VALID(buffer) ||
        !gst_audio_info_from_caps(&info, gst_sample_get_caps(sample)) ||
        GST_AUDIO_INFO_FORMAT(&info) != GST_AUDIO_FORMAT_F32 || GST_AUDIO_INFO_CHANNELS(&info) != 1 ||
        GST_AUDIO_INFO_LAYOUT(&info) != GST_AUDIO_LAYOUT_INTERLEAVED || GST_AUDIO_INFO_RATE(&info) <= 0 ||
        gst_buffer_get_size(buffer) > 16 * 1024 * 1024) {
        text_error(error, capacity, "Audio needs bounded mono F32 samples with source timestamps");
        return MC_WAVEFORM_UNSUPPORTED;
    }
    GstAudioBuffer map = {0};
    if (!gst_audio_buffer_map(&map, &info, buffer, GST_MAP_READ)) {
        text_error(error, capacity, "Cannot read decoded audio"); return MC_WAVEFORM_FAILED;
    }
    size_t count = GST_AUDIO_BUFFER_N_SAMPLES(&map);
    bool valid = GST_AUDIO_BUFFER_N_PLANES(&map) == 1 && count <= 4 * 1024 * 1024;
    size_t first = 0, end = count;
    GstAudioClippingMeta *clip = gst_buffer_get_audio_clipping_meta(buffer);
    guint rate = (guint)GST_AUDIO_INFO_RATE(&info);
    if (clip) {
        guint64 start_clip, end_clip;
        if (clip->format == GST_FORMAT_DEFAULT) { start_clip = clip->start; end_clip = clip->end; }
        else if (clip->format == GST_FORMAT_TIME) {
            start_clip = gst_util_uint64_scale_ceil(clip->start, rate, GST_SECOND);
            end_clip = gst_util_uint64_scale_ceil(clip->end, rate, GST_SECOND);
        } else { start_clip = end_clip = 0; valid = false; }
        if (start_clip > count || end_clip > count - MIN((guint64)count, start_clip)) valid = false;
        else { first = (size_t)start_clip; end = count - (size_t)end_clip; }
    }
    if (!valid) {
        gst_audio_buffer_unmap(&map); text_error(error, capacity, "Invalid decoded audio clipping metadata");
        return MC_WAVEFORM_UNSUPPORTED;
    }
    guint64 duration = (guint64)analysis->state.duration_ms * GST_MSECOND;
    guint64 latest = 0, step = gst_util_uint64_scale_ceil(1, GST_SECOND, rate);
    bool gap = GST_BUFFER_FLAG_IS_SET(buffer, GST_BUFFER_FLAG_GAP);
    for (size_t i = first; i < end; i++) {
        if ((i & 4095) == 0 && cancelled(analysis)) break;
        guint64 delta = gst_util_uint64_scale((guint64)i, GST_SECOND, rate);
        if (GST_BUFFER_PTS(buffer) > G_MAXUINT64 - delta - step) continue;
        guint64 position = GST_BUFFER_PTS(buffer) + delta, clipped_start, clipped_end, stream_time;
        if (!gst_segment_clip(segment, GST_FORMAT_TIME, position, position + step, &clipped_start, &clipped_end) ||
            gst_segment_to_stream_time_full(segment, GST_FORMAT_TIME, clipped_start, &stream_time) <= 0 ||
            stream_time >= duration) continue;
        latest = MAX(latest, stream_time);
        if (gap) continue;
        float value;
        memcpy(&value, (const guint8 *)GST_AUDIO_BUFFER_PLANE_DATA(&map, 0) + i * sizeof(float), sizeof value);
        if (!isfinite(value)) continue;
        value = MIN(fabsf(value), 1.0f);
        size_t bin = (size_t)gst_util_uint64_scale(stream_time, analysis->state.peak_count, duration);
        if (bin < analysis->state.peak_count && value > analysis->peaks[bin]) analysis->peaks[bin] = value;
    }
    gst_audio_buffer_unmap(&map);
    if (latest) {
        g_mutex_lock(&analysis->mutex);
        analysis->state.progress = MAX(analysis->state.progress, MIN((double)latest / (double)duration, 0.99));
        g_mutex_unlock(&analysis->mutex);
    }
    return cancelled(analysis) ? MC_WAVEFORM_CANCELLED : MC_WAVEFORM_READY;
}

static int decode(MCWaveformAnalysis *analysis, GMainContext *context, const char *uri,
                  char *error, size_t capacity) {
    GstElement *pipeline = gst_pipeline_new(NULL), *decoder = gst_element_factory_make("uridecodebin", NULL);
    GstElement *convert = gst_element_factory_make("audioconvert", NULL), *sink = gst_element_factory_make("appsink", NULL);
    if (!pipeline || !decoder || !convert || !sink) {
        if (pipeline) gst_object_unref(pipeline);
        if (decoder) gst_object_unref(decoder);
        if (convert) gst_object_unref(convert);
        if (sink) gst_object_unref(sink);
        text_error(error, capacity, "Required audio decoding elements are unavailable"); return MC_WAVEFORM_UNSUPPORTED;
    }
    GstCaps *audio = gst_caps_from_string("audio/x-raw");
    g_object_set(decoder, "uri", uri, "caps", audio, "expose-all-streams", FALSE, NULL); gst_caps_unref(audio);
    GstCaps *mono = gst_caps_new_simple("audio/x-raw", "format", G_TYPE_STRING, GST_AUDIO_NE(F32),
        "channels", G_TYPE_INT, 1, "layout", G_TYPE_STRING, "interleaved", NULL);
    g_object_set(sink, "caps", mono, "sync", FALSE, "max-buffers", 2u, "drop", FALSE, "wait-on-eos", FALSE, NULL);
    gst_caps_unref(mono);
    gst_bin_add_many(GST_BIN(pipeline), decoder, convert, sink, NULL);
    Decode state = {.convert=convert};
    gulong callback = g_signal_connect(decoder, "pad-added", G_CALLBACK(decoded_pad), &state);
    GstBus *bus = gst_element_get_bus(pipeline);
    int status = MC_WAVEFORM_READY;
    bool ready = gst_element_link(convert, sink) && gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE;
    if (!ready) { status = MC_WAVEFORM_UNSUPPORTED; text_error(error, capacity, "Cannot start source audio decoding"); }
    gint64 last_activity = g_get_monotonic_time();
    bool eos = false;
    while (ready && !cancelled(analysis)) {
        GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 20 * GST_MSECOND);
        if (sample) {
            status = sample_peaks(analysis, sample, error, capacity); gst_sample_unref(sample);
            last_activity = g_get_monotonic_time();
            if (status != MC_WAVEFORM_READY) break;
        }
        GstMessage *message;
        while ((message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR | GST_MESSAGE_EOS))) {
            if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
                GError *failure = NULL; gst_message_parse_error(message, &failure, NULL);
                status = failure && (g_error_matches(failure, GST_CORE_ERROR, GST_CORE_ERROR_MISSING_PLUGIN) ||
                    g_error_matches(failure, GST_STREAM_ERROR, GST_STREAM_ERROR_CODEC_NOT_FOUND)) ? MC_WAVEFORM_UNSUPPORTED : MC_WAVEFORM_FAILED;
                text_error(error, capacity, failure ? failure->message : "Source audio decoding failed"); g_clear_error(&failure);
            } else eos = true;
            gst_message_unref(message);
        }
        if (status != MC_WAVEFORM_READY) break;
        if (g_atomic_int_get(&state.audio_pads) > 1 || g_atomic_int_get(&state.link_failed)) {
            status = MC_WAVEFORM_UNSUPPORTED; text_error(error, capacity, "Source audio stream could not be linked unambiguously"); break;
        }
        if (!sample && (eos || gst_app_sink_is_eos(GST_APP_SINK(sink)))) break;
        if (g_get_monotonic_time() - last_activity > 15000000) {
            status = MC_WAVEFORM_FAILED; text_error(error, capacity, "Source audio decoding stopped making progress"); break;
        }
        for (int i = 0; i < 64 && g_main_context_pending(context); i++) g_main_context_iteration(context, FALSE);
    }
    gst_element_set_state(pipeline, GST_STATE_NULL);
    g_signal_handler_disconnect(decoder, callback);
    gst_object_unref(bus); gst_object_unref(pipeline);
    return cancelled(analysis) ? MC_WAVEFORM_CANCELLED : status;
}

static gpointer analyze(gpointer data) {
    MCWaveformAnalysis *analysis = data;
    GMainContext *context = g_main_context_new(); g_main_context_push_thread_default(context);
    int status = MC_WAVEFORM_FAILED;
    char error[1024] = {0};
    GError *failure = NULL;
    char *uri = NULL;
    if (!gst_init_check(NULL, NULL, &failure)) {
        text_error(error, sizeof error, failure ? failure->message : "GStreamer initialization failed");
        g_clear_error(&failure);
    } else if (cancelled(analysis)) status = MC_WAVEFORM_CANCELLED;
    else {
        uri = gst_filename_to_uri(analysis->source, &failure);
        if (!uri) { text_error(error, sizeof error, failure ? failure->message : "Invalid source path"); g_clear_error(&failure); }
        else {
            status = discover(analysis, context, uri, error, sizeof error);
            if (status == MC_WAVEFORM_READY) status = decode(analysis, context, uri, error, sizeof error);
        }
    }
    g_free(uri);
    g_main_context_pop_thread_default(context); g_main_context_unref(context);
    g_mutex_lock(&analysis->mutex);
    analysis->state.status = cancelled(analysis) ? MC_WAVEFORM_CANCELLED : status;
    if (analysis->state.status != MC_WAVEFORM_READY) {
        g_clear_pointer(&analysis->peaks, g_free); analysis->state.peak_count = 0;
    }
    if (analysis->state.status == MC_WAVEFORM_READY || analysis->state.status == MC_WAVEFORM_NO_AUDIO)
        analysis->state.progress = 1;
    if (analysis->state.status == MC_WAVEFORM_FAILED || analysis->state.status == MC_WAVEFORM_UNSUPPORTED)
        text_error(analysis->state.error, sizeof analysis->state.error, error);
    g_mutex_unlock(&analysis->mutex);
    return NULL;
}

MCWaveformAnalysis *mc_waveform_create(const char *source, int64_t duration, size_t count, char *error, size_t capacity) {
    if (error && capacity) error[0] = '\0';
    if (!source || !source[0] || strlen(source) > 131072 || !g_utf8_validate(source, -1, NULL) || !g_path_is_absolute(source) ||
        duration < 1 || duration > 604800000 || count < 1 || count > 16384) {
        text_error(error, capacity, "Expected a local source, validated duration and 1..16384 waveform bins"); return NULL;
    }
    MCWaveformAnalysis *analysis = g_new0(MCWaveformAnalysis, 1);
    g_mutex_init(&analysis->mutex); analysis->source = g_strdup(source); analysis->peaks = g_new0(float, count);
    analysis->state.duration_ms = duration; analysis->state.peak_count = count;
    GError *failure = NULL;
    analysis->thread = g_thread_try_new("moojicut-waveform", analyze, analysis, &failure);
    if (!analysis->thread) {
        text_error(error, capacity, failure ? failure->message : "Cannot start audio analysis"); g_clear_error(&failure);
        g_mutex_clear(&analysis->mutex); g_free(analysis->source); g_free(analysis->peaks); g_free(analysis); return NULL;
    }
    return analysis;
}

bool mc_waveform_poll(MCWaveformAnalysis *analysis, MCWaveformState *state) {
    if (!analysis || !state) return false;
    g_mutex_lock(&analysis->mutex); *state = analysis->state; g_mutex_unlock(&analysis->mutex); return true;
}

bool mc_waveform_take(MCWaveformAnalysis *analysis, MCWaveformResult *result) {
    if (!analysis || !result || result->peaks) return false;
    g_mutex_lock(&analysis->mutex);
    bool ready = !analysis->taken && (analysis->state.status == MC_WAVEFORM_READY || analysis->state.status == MC_WAVEFORM_NO_AUDIO);
    if (ready) {
        result->peaks = analysis->peaks; result->count = analysis->state.peak_count; result->duration_ms = analysis->state.duration_ms;
        analysis->peaks = NULL; analysis->taken = true;
    }
    g_mutex_unlock(&analysis->mutex); return ready;
}

void mc_waveform_result_clear(MCWaveformResult *result) {
    if (!result) return;
    g_free(result->peaks); memset(result, 0, sizeof *result);
}

void mc_waveform_cancel(MCWaveformAnalysis *analysis) {
    if (analysis) g_atomic_int_set(&analysis->cancelled, 1);
}

bool mc_waveform_free(MCWaveformAnalysis *analysis) {
    if (!analysis) return true;
    g_mutex_lock(&analysis->mutex); bool done = analysis->state.status != MC_WAVEFORM_RUNNING; g_mutex_unlock(&analysis->mutex);
    if (!done) return false;
    g_thread_join(analysis->thread); g_mutex_clear(&analysis->mutex);
    g_free(analysis->source); g_free(analysis->peaks); g_free(analysis); return true;
}
