#include "platform/shared/media/waveform.h"
#include <gst/app/gstappsrc.h>
#include <gst/gst.h>
#include <glib/gstdio.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static int failures, default_dispatches;
static char error_text[1024];

static bool check(bool condition, const char *message) {
    printf("%s %s%s%s\n", condition ? "PASS" : "FAIL", message,
        !condition && error_text[0] ? ": " : "", !condition ? error_text : "");
    fflush(stdout); if (!condition) failures++; error_text[0] = '\0'; return condition;
}

static gboolean sentinel(gpointer unused) {
    (void)unused; default_dispatches++; return G_SOURCE_REMOVE;
}

static bool finish_pipeline(GstElement *pipeline) {
    GstBus *bus = gst_element_get_bus(pipeline);
    GstMessage *message = gst_bus_timed_pop_filtered(bus, 30 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
    bool success = message && GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS;
    if (message && !success) {
        GError *failure = NULL; gst_message_parse_error(message, &failure, NULL);
        g_strlcpy(error_text, failure ? failure->message : "source pipeline failed", sizeof error_text);
        g_clear_error(&failure);
    }
    if (message) gst_message_unref(message);
    gst_object_unref(bus); gst_element_set_state(pipeline, GST_STATE_NULL); gst_object_unref(pipeline); return success;
}

static GstElement *source_pipeline(const char *description, const char *path) {
    GError *failure = NULL;
    GstElement *pipeline = gst_parse_launch(description, &failure);
    if (!pipeline || failure) {
        g_strlcpy(error_text, failure ? failure->message : "source pipeline unavailable", sizeof error_text);
        g_clear_error(&failure); if (pipeline) gst_object_unref(pipeline); return NULL;
    }
    GstElement *output = gst_bin_get_by_name(GST_BIN(pipeline), "output");
    g_object_set(output, "location", path, NULL); gst_object_unref(output); return pipeline;
}

static bool make_timestamp_source(const char *path) {
    GstElement *pipeline = source_pipeline(
        "videotestsrc num-buffers=120 pattern=black ! video/x-raw,width=160,height=90,framerate=30/1 ! "
        "vp8enc deadline=1 ! queue ! mux. "
        "appsrc name=audio format=time ! audioconvert ! flacenc ! queue ! mux. "
        "matroskamux name=mux ! filesink name=output", path);
    if (!pipeline) return false;
    GstElement *audio = gst_bin_get_by_name(GST_BIN(pipeline), "audio");
    GstCaps *caps = gst_caps_new_simple("audio/x-raw", "format", G_TYPE_STRING, "F32LE", "rate", G_TYPE_INT, 48000,
        "channels", G_TYPE_INT, 1, "layout", G_TYPE_STRING, "interleaved", NULL);
    gst_app_src_set_caps(GST_APP_SRC(audio), caps); gst_caps_unref(caps);
    bool ready = gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE;
    for (int part = 0; ready && part < 2; part++) {
        int chunks = part == 0 ? 100 : 50;
        for (int chunk = 0; ready && chunk < chunks; chunk++) {
            GstBuffer *buffer = gst_buffer_new_allocate(NULL, 480 * sizeof(float), NULL);
            GstMapInfo map; gst_buffer_map(buffer, &map, GST_MAP_WRITE);
            for (int i = 0; i < 480; i++) {
                float value = (float)((part == 0 ? 0.8 : 0.35) * sin(2 * G_PI * (part == 0 ? 440 : 880) *
                    (double)(chunk * 480 + i) / 48000.0));
                memcpy(map.data + (size_t)i * sizeof value, &value, sizeof value);
            }
            gst_buffer_unmap(buffer, &map);
            GST_BUFFER_PTS(buffer) = (GstClockTime)(part == 0 ? 1 : 3) * GST_SECOND + (GstClockTime)chunk * 10 * GST_MSECOND;
            GST_BUFFER_DURATION(buffer) = 10 * GST_MSECOND;
            ready = gst_app_src_push_buffer(GST_APP_SRC(audio), buffer) == GST_FLOW_OK;
        }
    }
    gst_app_src_end_of_stream(GST_APP_SRC(audio)); gst_object_unref(audio);
    return finish_pipeline(pipeline) && ready;
}

static bool make_simple_source(const char *path, const char *description) {
    GstElement *pipeline = source_pipeline(description, path);
    if (!pipeline) return false;
    if (gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        gst_element_set_state(pipeline, GST_STATE_NULL); gst_object_unref(pipeline); return false;
    }
    return finish_pipeline(pipeline);
}

static bool wait_status(MCWaveformAnalysis *analysis, int expected) {
    gint64 deadline = g_get_monotonic_time() + 20000000;
    MCWaveformState state = {0};
    do {
        if (!mc_waveform_poll(analysis, &state)) return false;
        if (state.status != MC_WAVEFORM_RUNNING) break;
        g_usleep(1000);
    } while (g_get_monotonic_time() < deadline);
    if (state.status != expected) {
        g_snprintf(error_text, sizeof error_text, "status %d expected %d: %.900s", state.status, expected, state.error); return false;
    }
    return true;
}

static bool range(const MCWaveformResult *result, size_t start, size_t end, float low, float high) {
    if (end > result->count) return false;
    for (size_t i = start; i < end; i++)
        if (!isfinite(result->peaks[i]) || result->peaks[i] < low || result->peaks[i] > high) return false;
    return true;
}

static char *file_hash(const char *path) {
    char *data = NULL; gsize length = 0;
    if (!g_file_get_contents(path, &data, &length, NULL)) return NULL;
    char *hash = g_compute_checksum_for_data(G_CHECKSUM_SHA256, (const guchar *)data, length); g_free(data); return hash;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: media-waveform OUTPUT_DIRECTORY\n"); return 2; }
    g_log_set_always_fatal(G_LOG_FATAL_MASK | G_LOG_LEVEL_CRITICAL);
    gst_init(NULL, NULL); /* Gst only; no GES is linked or initialized. */
    char *directory = g_canonicalize_filename(argv[1], NULL);
    if (g_mkdir_with_parents(directory, 0700)) return 2;
    char *source = g_build_filename(directory, "timestamp-gaps.mkv", NULL);
    if (!check(make_timestamp_source(source), "generate source with video origin 0 and audio at 1s/3s")) return 1;
    char *original = file_hash(source);
    guint idle = g_idle_add(sentinel, NULL);
    MCWaveformAnalysis *analysis = mc_waveform_create(source, 4000, 400, error_text, sizeof error_text);
    check(analysis != NULL, "start nonblocking bounded waveform analysis");
    check(!mc_waveform_free(analysis), "running analysis cannot be freed");
    MCWaveformResult peaks = {0};
    check(!mc_waveform_take(analysis, &peaks), "incomplete peaks are never exposed");
    check(wait_status(analysis, MC_WAVEFORM_READY) && mc_waveform_take(analysis, &peaks), "take immutable source-time peaks after actual pipeline drain");
    check(peaks.duration_ms == 4000 && peaks.count == 400, "duration and bin count match the caller's validated source contract");
    check(range(&peaks, 0, 95, 0, 0.001f), "leading source-time gap stays silent instead of shifting audio to zero");
    check(range(&peaks, 105, 195, 0.78f, 0.82f), "first tone appears at its actual 1s source timestamp");
    check(range(&peaks, 210, 290, 0, 0.001f), "discontinuous timestamps preserve the interior silent interval");
    check(range(&peaks, 305, 345, 0.33f, 0.37f), "second quieter tone retains amplitude at 3s");
    check(range(&peaks, 355, 400, 0, 0.001f), "trailing source interval stays silent");
    MCWaveformResult duplicate = {0};
    check(!mc_waveform_take(analysis, &duplicate), "result ownership transfers only once");
    check(mc_waveform_free(analysis) && range(&peaks, 105, 195, 0.78f, 0.82f), "owned peaks survive analysis destruction");
    mc_waveform_result_clear(&peaks);

    char *silent = g_build_filename(directory, "no-audio.mkv", NULL);
    check(make_simple_source(silent, "videotestsrc num-buffers=30 ! video/x-raw,width=160,height=90,framerate=30/1 ! vp8enc deadline=1 ! matroskamux ! filesink name=output"), "generate video without audio");
    analysis = mc_waveform_create(silent, 1000, 1024, error_text, sizeof error_text);
    check(wait_status(analysis, MC_WAVEFORM_NO_AUDIO) && mc_waveform_take(analysis, &peaks) &&
        peaks.count == 0 && peaks.peaks == NULL && peaks.duration_ms == 1000, "no audio is explicit successful empty analysis");
    check(mc_waveform_free(analysis), "no-audio job closes cleanly"); mc_waveform_result_clear(&peaks);

    char *multiple = g_build_filename(directory, "multiple-audio.mkv", NULL);
    check(make_simple_source(multiple, "audiotestsrc num-buffers=50 freq=440 ! audioconvert ! flacenc ! queue ! mux. audiotestsrc num-buffers=50 freq=880 ! audioconvert ! flacenc ! queue ! mux. matroskamux name=mux ! filesink name=output"), "generate ambiguous multiple-audio source");
    analysis = mc_waveform_create(multiple, 2000, 128, error_text, sizeof error_text);
    check(wait_status(analysis, MC_WAVEFORM_UNSUPPORTED) && !mc_waveform_take(analysis, &peaks), "unsupported multiple streams do not masquerade as silence");
    check(mc_waveform_free(analysis), "unsupported analysis releases resources");

    char *long_source = g_build_filename(directory, "long-audio.mkv", NULL);
    check(make_simple_source(long_source, "audiotestsrc num-buffers=5625 samplesperbuffer=1024 freq=440 ! audio/x-raw,rate=48000,channels=1 ! audioconvert ! flacenc ! matroskamux ! filesink name=output"), "generate longer source for cancellation during active decoding");
    analysis = mc_waveform_create(long_source, 120000, 16384, error_text, sizeof error_text);
    MCWaveformState state = {0}; gint64 until = g_get_monotonic_time() + 15000000;
    do { mc_waveform_poll(analysis, &state); if (state.progress > 0 || state.status != MC_WAVEFORM_RUNNING) break; g_usleep(1000); }
    while (g_get_monotonic_time() < until);
    check(state.status == MC_WAVEFORM_RUNNING && state.progress > 0, "cancellation fixture reaches actual decoded samples");
    gint64 cancelled_at = g_get_monotonic_time(); mc_waveform_cancel(analysis);
    check(wait_status(analysis, MC_WAVEFORM_CANCELLED) && g_get_monotonic_time() - cancelled_at < 5000000,
        "active analysis cancellation drains promptly without exposing partial peaks");
    check(!mc_waveform_take(analysis, &peaks) && mc_waveform_free(analysis), "cancelled worker releases all analysis ownership");
    analysis = mc_waveform_create(source, 4000, 16384, error_text, sizeof error_text);
    check(wait_status(analysis, MC_WAVEFORM_READY) && mc_waveform_take(analysis, &peaks) && peaks.count == 16384,
        "analysis reopens after cancellation and honors the maximum bin bound");
    check(mc_waveform_free(analysis), "reopened analysis releases cleanly"); mc_waveform_result_clear(&peaks);

    check(mc_waveform_create(source, 0, 1024, error_text, sizeof error_text) == NULL &&
        mc_waveform_create(source, 4000, 16385, error_text, sizeof error_text) == NULL,
        "invalid duration and oversized bin count are rejected before creating a thread");
    char *missing = g_build_filename(directory, "missing.wav", NULL);
    analysis = mc_waveform_create(missing, 1000, 100, error_text, sizeof error_text);
    check(wait_status(analysis, MC_WAVEFORM_FAILED) && !mc_waveform_take(analysis, &peaks) && mc_waveform_free(analysis),
        "unreadable source reports failure distinct from no audio");
    char *after = file_hash(source);
    check(original && after && !strcmp(original, after), "audio analysis leaves original source bytes unchanged");
    check(default_dispatches == 0, "analysis never dispatches UI global-default context"); g_source_remove(idle);
    g_free(original); g_free(after); g_free(source); g_free(silent); g_free(multiple); g_free(long_source); g_free(missing); g_free(directory);
    printf("media-waveform: %d failure(s)\n", failures); return failures ? 1 : 0;
}
