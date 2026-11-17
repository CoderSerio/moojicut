#include "platform/shared/media/media_worker.h"
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <gst/gst.h>
#include <gst/pbutils/pbutils.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

static int failures;
static char error_text[1024];
static int default_context_dispatches;
typedef struct {
    MCMediaWorker *worker;
    MCMediaCompletion results[256];
    bool seen[256];
} Harness;

static gboolean default_context_sentinel(gpointer unused) {
    (void)unused; default_context_dispatches++; return G_SOURCE_REMOVE;
}

/* Independent file validation uses GStreamer only. The UI/test thread must
 * never enter GES or the engine while the process owner executor exists. */
static bool probe_output(const char *path, MCGstMetadata *metadata) {
    GError *failure = NULL;
    gchar *uri = gst_filename_to_uri(path, &failure);
    GstDiscoverer *probe = uri ? gst_discoverer_new(10 * GST_SECOND, &failure) : NULL;
    GstDiscovererInfo *info = probe ? gst_discoverer_discover_uri(probe, uri, &failure) : NULL;
    bool valid = info && gst_discoverer_info_get_result(info) == GST_DISCOVERER_OK;
    if (valid) {
        GList *videos = gst_discoverer_info_get_video_streams(info);
        GList *audio = gst_discoverer_info_get_audio_streams(info);
        valid = videos && !videos->next;
        if (valid) {
            metadata->width = gst_discoverer_video_info_get_width(videos->data);
            metadata->height = gst_discoverer_video_info_get_height(videos->data);
            metadata->duration_ms = (double)gst_discoverer_info_get_duration(info) / GST_MSECOND;
            metadata->has_audio = audio != NULL;
        }
        gst_discoverer_stream_info_list_free(videos); gst_discoverer_stream_info_list_free(audio);
    }
    if (failure) { g_strlcpy(error_text, failure->message, sizeof error_text); g_error_free(failure); }
    if (info) gst_discoverer_info_unref(info);
    if (probe) g_object_unref(probe);
    g_free(uri); return valid;
}

static bool check(bool condition, const char *message) {
    printf("%s %s%s%s\n", condition ? "PASS" : "FAIL", message,
        !condition && error_text[0] ? ": " : "", !condition ? error_text : "");
    fflush(stdout); if (!condition) failures++; error_text[0] = '\0'; return condition;
}

static bool submit(Harness *h, MCMediaRequest request) {
    return mc_media_worker_submit(h->worker, &request, error_text, sizeof error_text);
}

static void collect(Harness *h) {
    MCMediaCompletion result;
    while (mc_media_worker_poll(h->worker, &result)) {
        if (result.token >= 256 || h->seen[result.token]) {
            check(false, "accepted token completes exactly once"); continue;
        }
        h->seen[result.token] = true; h->results[result.token] = result;
    }
}

static bool wait_token(Harness *h, uint64_t token, int status) {
    gint64 until = g_get_monotonic_time() + 45000000;
    while (!h->seen[token] && g_get_monotonic_time() < until) {
        collect(h); if (!h->seen[token]) g_usleep(1000);
    }
    if (!h->seen[token]) { g_strlcpy(error_text, "request timeout", sizeof error_text); return false; }
    if (h->results[token].status != status) {
        g_snprintf(error_text, sizeof error_text, "status %d, expected %d: %.900s",
            h->results[token].status, status, h->results[token].error); return false;
    }
    return true;
}

static bool frame_at(Harness *h, uint64_t generation, uint64_t seek, bool black) {
    gint64 until = g_get_monotonic_time() + 3000000;
    while (g_get_monotonic_time() < until) {
        MCMediaFrame frame = {0};
        if (mc_media_worker_take_frame(h->worker, &frame)) {
            bool tag = frame.plan_generation == generation && frame.seek_token == seek;
            unsigned char *pixel = frame.image.pixels + (size_t)(frame.image.height / 2) * frame.image.stride +
                (size_t)(frame.image.width / 2) * 4;
            bool color = black ? pixel[0] < 10 && pixel[1] < 10 && pixel[2] < 10 : pixel[2] > 180;
            mc_media_frame_clear(&frame);
            return tag && color;
        }
        g_usleep(1000);
    }
    return false;
}

static bool generate_source(const char *path) {
    GError *failure = NULL;
    GstElement *pipeline = gst_parse_launch(
        "videotestsrc num-buffers=90 pattern=solid-color foreground-color=0xffff2020 ! "
        "video/x-raw,width=160,height=90,framerate=30/1 ! vp8enc deadline=1 ! queue ! mux. "
        "audiotestsrc num-buffers=141 samplesperbuffer=1024 freq=440 ! "
        "audio/x-raw,rate=48000,channels=2 ! audioconvert ! flacenc ! queue ! mux. "
        "matroskamux name=mux ! filesink name=output", &failure);
    if (!pipeline || failure) {
        g_strlcpy(error_text, failure ? failure->message : "cannot create source", sizeof error_text);
        g_clear_error(&failure); if (pipeline) gst_object_unref(pipeline); return false;
    }
    GstElement *output = gst_bin_get_by_name(GST_BIN(pipeline), "output");
    g_object_set(output, "location", path, NULL); gst_object_unref(output);
    bool ok = gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE;
    GstBus *bus = gst_element_get_bus(pipeline);
    GstMessage *message = ok ? gst_bus_timed_pop_filtered(bus, 15 * GST_SECOND,
        GST_MESSAGE_EOS | GST_MESSAGE_ERROR) : NULL;
    ok = message && GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS;
    if (message && !ok) {
        gst_message_parse_error(message, &failure, NULL);
        g_strlcpy(error_text, failure ? failure->message : "source generation failed", sizeof error_text);
        g_clear_error(&failure);
    }
    if (message) gst_message_unref(message);
    gst_element_set_state(pipeline, GST_STATE_NULL); gst_object_unref(bus); gst_object_unref(pipeline); return ok;
}

static MCGstPlan gap_plan(void) {
    MCGstPlan p = {0}; p.width = p.crop_width = 160; p.height = p.crop_height = 90;
    p.duration = 270000; p.video_count = p.audio_count = 2;
    p.video[0] = (MCGstClip){0, 0, 90000, 90000};
    p.video[1] = (MCGstClip){180000, 90000, 180000, 90000};
    p.audio[0] = p.video[0]; p.audio[1] = p.video[1]; return p;
}

static char *file_hash(const char *path) {
    char *bytes = NULL; gsize length = 0;
    if (!g_file_get_contents(path, &bytes, &length, NULL)) return NULL;
    char *hash = g_compute_checksum_for_data(G_CHECKSUM_SHA256, (const guchar *)bytes, length);
    g_free(bytes); return hash;
}

static bool marker_intact(const char *path) {
    char *bytes = NULL; gsize length = 0;
    bool intact = g_file_get_contents(path, &bytes, &length, NULL) && length == 8 && !memcmp(bytes, "keep-old", 8);
    g_free(bytes); return intact;
}

static bool hard_link(const char *source, const char *alias) {
#ifdef _WIN32
    gunichar2 *from = g_utf8_to_utf16(source, -1, NULL, NULL, NULL);
    gunichar2 *to = g_utf8_to_utf16(alias, -1, NULL, NULL, NULL);
    bool success = from && to && CreateHardLinkW((const wchar_t *)to, (const wchar_t *)from, NULL);
    g_free(from); g_free(to); return success;
#else
    return link(source, alias) == 0;
#endif
}

static bool no_staging(const char *directory) {
    GDir *dir = g_dir_open(directory, 0, NULL); if (!dir) return false;
    const char *name; bool empty = true;
    while ((name = g_dir_read_name(dir))) if (g_str_has_prefix(name, ".moojicut-export-")) empty = false;
    g_dir_close(dir); return empty;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: media-worker OUTPUT_DIRECTORY\n"); return 2; }
    g_log_set_always_fatal(G_LOG_FATAL_MASK | G_LOG_LEVEL_CRITICAL);
    char *directory = g_canonicalize_filename(argv[1], NULL);
    if (g_mkdir_with_parents(directory, 0700)) return 2;
    char *source = g_build_filename(directory, "source.mkv", NULL);
    GError *initialization_error = NULL;
    bool gst_ready = gst_init_check(NULL, NULL, &initialization_error);
    if (initialization_error) { g_strlcpy(error_text, initialization_error->message, sizeof error_text); g_error_free(initialization_error); }
    if (!check(gst_ready && generate_source(source), "generate actual audio/video source without initializing GES on UI thread")) return 1;
    guint sentinel = g_idle_add(default_context_sentinel, NULL);
    char *original = file_hash(source);
    Harness h = {0}; h.worker = mc_media_worker_create(source, true, error_text, sizeof error_text);
    if (!check(h.worker != NULL, "worker created without UI toolkit")) return 1;
    check(!mc_media_worker_free(h.worker), "live worker cannot be freed");
    check(submit(&h, (MCMediaRequest){.kind=MC_MEDIA_PROBE,.token=1,.generation=1}), "probe accepted asynchronously");
    check(wait_token(&h, 1, MC_MEDIA_OK) && h.results[1].metadata.has_audio && h.results[1].metadata.width == 160,
        "probe completes on isolated worker context without pumping the main context");
    MCGstPlan plan = gap_plan();
    check(submit(&h, (MCMediaRequest){.kind=MC_MEDIA_APPLY,.token=2,.generation=1,.plan=&plan}), "copied gap plan accepted");
    check(!submit(&h, (MCMediaRequest){.kind=MC_MEDIA_APPLY,.token=2,.generation=1,.plan=&plan}), "duplicate outstanding token rejected");
    check(wait_token(&h, 2, MC_MEDIA_OK), "preview plan becomes ready before ACK");
    check(submit(&h, (MCMediaRequest){.kind=MC_MEDIA_SEEK,.token=3,.generation=1,.number=500}), "source preview seek accepted");
    check(wait_token(&h, 3, MC_MEDIA_OK) && frame_at(&h, 1, 3, false), "seek ACK and tagged BGRA expose source pixels");
    Harness peer = {0}; peer.worker = mc_media_worker_create(source, true, error_text, sizeof error_text);
    check(peer.worker && submit(&peer, (MCMediaRequest){.kind=MC_MEDIA_APPLY,.token=1,.generation=7,.plan=&plan}),
        "second simultaneous editor registers on the same GES owner");
    check(submit(&h, (MCMediaRequest){.kind=MC_MEDIA_SEEK,.token=4,.generation=1,.number=2500}) &&
        submit(&h, (MCMediaRequest){.kind=MC_MEDIA_SEEK,.token=5,.generation=1,.number=1500}), "successive seeks accepted");
    MCMediaFrame discarded = {0};
    check(!mc_media_worker_take_frame(h.worker, &discarded), "new seek immediately invalidates mailbox from previous intent");
    check(wait_token(&h, 4, MC_MEDIA_OK) && wait_token(&h, 5, MC_MEDIA_OK) && frame_at(&h, 1, 5, true),
        "latest completed seek shows black gap instead of stale source frame");
    check(wait_token(&peer, 1, MC_MEDIA_OK) &&
        submit(&peer, (MCMediaRequest){.kind=MC_MEDIA_SEEK,.token=2,.generation=7,.number=2500}) &&
        wait_token(&peer, 2, MC_MEDIA_OK) && frame_at(&peer, 7, 2, false),
        "simultaneous editors keep independent generation seek and pixels");
    check(submit(&peer, (MCMediaRequest){.kind=MC_MEDIA_CLOSE,.token=3,.generation=7}) &&
        wait_token(&peer, 3, MC_MEDIA_OK) && mc_media_worker_free(peer.worker),
        "closing one editor releases only its resources");
    check(submit(&h, (MCMediaRequest){.kind=MC_MEDIA_RATE,.token=6,.generation=1,.number=1.5}) &&
        wait_token(&h, 6, MC_MEDIA_OK), "preview rate changes through worker");
    check(submit(&h, (MCMediaRequest){.kind=MC_MEDIA_PLAY,.token=7,.generation=1,.flag=true}) &&
        wait_token(&h, 7, MC_MEDIA_OK), "play acknowledged after state transition");
    check(submit(&h, (MCMediaRequest){.kind=MC_MEDIA_PLAY,.token=8,.generation=1,.flag=false}) &&
        wait_token(&h, 8, MC_MEDIA_OK), "pause acknowledged after state transition");
    char *output = g_build_filename(directory, "published.mkv", NULL);
    g_file_set_contents(output, "keep-old", 8, NULL);
    check(submit(&h, (MCMediaRequest){.kind=MC_MEDIA_EXPORT,.token=9,.generation=1,.plan=&plan,.path=output}),
        "export accepts copied plan and an existing destination");
    plan.duration = 0; plan.video_count = 0;
    check(wait_token(&h, 9, MC_MEDIA_OK), "worker exports submitted snapshot despite caller mutating plan immediately");
    MCGstMetadata metadata = {0};
    check(probe_output(output, &metadata) && metadata.width == 160 &&
        metadata.duration_ms > 2950 && metadata.duration_ms < 3100, "published replacement is validated actual media");
    plan = gap_plan();
    char *mp4 = g_build_filename(directory, "published.mp4", NULL);
    check(submit(&h, (MCMediaRequest){.kind=MC_MEDIA_EXPORT,.token=10,.generation=1,.plan=&plan,.path=mp4,.flag=true}) &&
        wait_token(&h, 10, MC_MEDIA_OK), "MP4 render drains then packet-copy finalizes before publication");
    check(probe_output(mp4, &metadata) && metadata.has_audio,
        "published MP4 contains actual audio and video");
    char *alias = g_build_filename(directory, "source-alias.mkv", NULL);
    check(hard_link(source, alias), "create source hard-link alias");
    check(submit(&h, (MCMediaRequest){.kind=MC_MEDIA_EXPORT,.token=11,.generation=1,.plan=&plan,.path=alias}) &&
        wait_token(&h, 11, MC_MEDIA_FAILED), "export rejects a hard-link alias of original recording");
    char *cancelled = g_build_filename(directory, "cancelled.mkv", NULL);
    g_file_set_contents(cancelled, "keep-old", 8, NULL);
    check(submit(&h, (MCMediaRequest){.kind=MC_MEDIA_EXPORT,.token=12,.generation=1,.plan=&plan,.path=cancelled}) &&
        submit(&h, (MCMediaRequest){.kind=MC_MEDIA_CANCEL_EXPORT,.token=13,.generation=1,.target=12}),
        "cancellation signals export independently of worker queue");
    check(wait_token(&h, 12, MC_MEDIA_CANCELLED) && wait_token(&h, 13, MC_MEDIA_OK) && marker_intact(cancelled),
        "cancelled export preserves existing destination and reports both terminal tickets");
    check(no_staging(directory), "success and cancellation leave no staging directories");

    // Fill accepted requests faster than they can execute. Close has reserved
    // capacity; every accepted request still receives its own terminal result.
    int accepted = 0;
    for (int i = 100; i < 164; i++) {
        if (submit(&h, (MCMediaRequest){.kind=MC_MEDIA_SEEK,.token=(uint64_t)i,.generation=1,.number=500})) accepted++;
    }
    check(accepted == 64, "bounded request queue accepts 64 outstanding tickets");
    check(!submit(&h, (MCMediaRequest){.kind=MC_MEDIA_SEEK,.token=164,.generation=1,.number=500}), "queue rejects overflow without promised completion");
    check(submit(&h, (MCMediaRequest){.kind=MC_MEDIA_CLOSE,.token=200,.generation=1}), "close accepted with full ordinary queue");
    check(!submit(&h, (MCMediaRequest){.kind=MC_MEDIA_PROBE,.token=201,.generation=1}), "closing rejects new requests");
    check(wait_token(&h, 200, MC_MEDIA_OK), "close ACK follows real engine drain");
    collect(&h);
    bool all_terminal = true;
    for (int i = 100; i < 164; i++) all_terminal = all_terminal && h.seen[i];
    check(all_terminal, "all accepted queued tickets terminate before close");
    MCMediaState state = {0};
    check(mc_media_worker_snapshot(h.worker, &state) && state.closed && !state.media_ready && !state.playing,
        "closed snapshot contains no live preview");
    check(mc_media_worker_free(h.worker), "closed session frees without stopping the shared executor");

    Harness closing = {0}; closing.worker = mc_media_worker_create(source, true, error_text, sizeof error_text);
    check(closing.worker != NULL, "a second worker opens after first context is closed");
    MCGstPlan long_plan = gap_plan(); long_plan.duration = 40 * 270000; long_plan.video_count = long_plan.audio_count = 40;
    for (int i = 0; i < 40; i++) {
        long_plan.video[i] = (MCGstClip){(int64_t)i * 270000, 0, 270000, 270000};
        long_plan.audio[i] = long_plan.video[i];
    }
    check(submit(&closing, (MCMediaRequest){.kind=MC_MEDIA_EXPORT,.token=1,.generation=1,.plan=&long_plan,.path=cancelled}),
        "long actual export starts before close");
    gint64 started_until = g_get_monotonic_time() + 10000000;
    do {
        mc_media_worker_snapshot(closing.worker, &state);
        if (state.export_token) break;
        collect(&closing); g_usleep(1000);
    } while (g_get_monotonic_time() < started_until && !closing.seen[1]);
    check(state.export_token == 1, "export pipeline is active before shutdown");
    check(submit(&closing, (MCMediaRequest){.kind=MC_MEDIA_CLOSE,.token=2,.generation=1}) &&
        wait_token(&closing, 1, MC_MEDIA_CANCELLED) && wait_token(&closing, 2, MC_MEDIA_OK),
        "close terminates active render and reports export before close barrier");
    check(marker_intact(cancelled) && no_staging(directory), "active-export close preserves destination and removes partials");
    check(mc_media_worker_free(closing.worker), "second worker frees after active-export drain");
    char *after = file_hash(source);
    check(original && after && !strcmp(original, after), "preview export replacement cancellation preserve original bytes");
    check(no_staging(directory), "close leaves no staging or partial output");
    check(default_context_dispatches == 0, "media executor never dispatches the UI global-default context");
    g_source_remove(sentinel);
    g_free(original); g_free(after); g_free(source); g_free(output); g_free(mp4); g_free(alias); g_free(cancelled); g_free(directory);
    printf("media-worker: %d failure(s)\n", failures); return failures ? 1 : 0;
}
