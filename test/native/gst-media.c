#include "platform/shared/media/gst_engine.h"
#include "platform/shared/media/mp4_mux.h"
#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <gst/video/video.h>
#include <glib/gstdio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* A generated source and an independent decoder exercise the production engine.
 * No display/audio device, external CLI, or pre-existing recording is required. */
enum { WIDTH = 320, HEIGHT = 180, FPS = 30, RATE = 48000, SECONDS = 6 };
static int failures;
static char error_text[2048];

static gboolean check(gboolean condition, const char *message) {
    printf("%s %s%s%s\n", condition ? "PASS" : "FAIL", message,
           !condition && error_text[0] ? ": " : "", !condition ? error_text : "");
    fflush(stdout);
    if (!condition) failures++;
    error_text[0] = '\0';
    return condition;
}

static gboolean bus_error(GstMessage *message) {
    if (GST_MESSAGE_TYPE(message) != GST_MESSAGE_ERROR) return FALSE;
    GError *error = NULL;
    gst_message_parse_error(message, &error, NULL);
    g_snprintf(error_text, sizeof error_text, "%s", error ? error->message : "GStreamer error");
    g_clear_error(&error);
    return TRUE;
}

static gboolean finish_pipeline(GstElement *pipeline, unsigned seconds) {
    GstBus *bus = gst_element_get_bus(pipeline);
    GstMessage *message = gst_bus_timed_pop_filtered(bus, (GstClockTime)seconds * GST_SECOND,
        (GstMessageType)(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
    gboolean ok = message && !bus_error(message);
    if (!message) g_strlcpy(error_text, "pipeline timed out", sizeof error_text);
    if (message) gst_message_unref(message);
    gst_object_unref(bus);
    return ok;
}

static gboolean generate_source(const char *path, gboolean with_audio) {
    GError *error = NULL;
    GstElement *pipeline = gst_parse_launch(with_audio ?
        "appsrc name=video format=time ! queue ! videoconvert ! "
        "vp8enc deadline=1 target-bitrate=3000000 keyframe-max-dist=30 ! queue ! mux. "
        "appsrc name=audio format=time ! queue ! audioconvert ! flacenc ! queue ! mux. "
        "matroskamux name=mux ! filesink name=output" :
        "appsrc name=video format=time ! queue ! videoconvert ! "
        "vp8enc deadline=1 target-bitrate=3000000 keyframe-max-dist=30 ! "
        "matroskamux ! filesink name=output", &error);
    if (!pipeline || error) {
        g_snprintf(error_text, sizeof error_text, "%s", error ? error->message : "source pipeline missing");
        g_clear_error(&error);
        if (pipeline) gst_object_unref(pipeline);
        return FALSE;
    }
    GstElement *video = gst_bin_get_by_name(GST_BIN(pipeline), "video");
    GstElement *audio = gst_bin_get_by_name(GST_BIN(pipeline), "audio");
    GstElement *output = gst_bin_get_by_name(GST_BIN(pipeline), "output");
    g_object_set(output, "location", path, NULL);
    GstCaps *caps = gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING, "BGRA",
        "width", G_TYPE_INT, WIDTH, "height", G_TYPE_INT, HEIGHT,
        "framerate", GST_TYPE_FRACTION, FPS, 1, NULL);
    gst_app_src_set_caps(GST_APP_SRC(video), caps); gst_caps_unref(caps);
    if (with_audio) {
    caps = gst_caps_new_simple("audio/x-raw", "format", G_TYPE_STRING, "S16LE",
        "layout", G_TYPE_STRING, "interleaved", "rate", G_TYPE_INT, RATE,
        "channels", G_TYPE_INT, 2, NULL);
    gst_app_src_set_caps(GST_APP_SRC(audio), caps); gst_caps_unref(caps);
    }
    gboolean ok = gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE;
    for (int index = 0; ok && index < FPS * SECONDS; index++) {
        GstBuffer *buffer = gst_buffer_new_allocate(NULL, (gsize)WIDTH * HEIGHT * 4, NULL);
        GstMapInfo map;
        if (!gst_buffer_map(buffer, &map, GST_MAP_WRITE)) { gst_buffer_unref(buffer); ok = FALSE; break; }
        for (int y = 0; y < HEIGHT; y++) for (int x = 0; x < WIDTH; x++) {
            unsigned char *pixel = map.data + ((gsize)y * WIDTH + (gsize)x) * 4;
            unsigned char red, green, blue;
            if (y < 32) {
                red = green = blue = (index & (1 << (x / 40))) ? 240 : 15;
            } else if (y < HEIGHT / 2) {
                red = x < WIDTH / 2 ? 230 : 25;
                green = x < WIDTH / 2 ? 25 : 220;
                blue = 25;
            } else {
                red = x < WIDTH / 2 ? 25 : 230;
                green = x < WIDTH / 2 ? 25 : 210;
                blue = x < WIDTH / 2 ? 230 : 25;
            }
            pixel[0] = blue; pixel[1] = green; pixel[2] = red; pixel[3] = 255;
        }
        gst_buffer_unmap(buffer, &map);
        GST_BUFFER_PTS(buffer) = gst_util_uint64_scale((guint64)index, GST_SECOND, FPS);
        GST_BUFFER_DURATION(buffer) = gst_util_uint64_scale((guint64)index + 1, GST_SECOND, FPS) - GST_BUFFER_PTS(buffer);
        ok = gst_app_src_push_buffer(GST_APP_SRC(video), buffer) == GST_FLOW_OK;
        if (!ok) break;
        if (!with_audio) continue;
        buffer = gst_buffer_new_allocate(NULL, (gsize)(RATE / FPS) * 4, NULL);
        if (!gst_buffer_map(buffer, &map, GST_MAP_WRITE)) { gst_buffer_unref(buffer); ok = FALSE; break; }
        for (int sample = 0; sample < RATE / FPS; sample++) {
            double time = ((double)index * (RATE / FPS) + sample) / RATE;
            gint16 value = (gint16)(sin(time * 440.0 * 2.0 * G_PI) * 12000.0);
            GST_WRITE_UINT16_LE(map.data + (gsize)sample * 4, (guint16)value);
            GST_WRITE_UINT16_LE(map.data + (gsize)sample * 4 + 2, (guint16)value);
        }
        gst_buffer_unmap(buffer, &map);
        GST_BUFFER_PTS(buffer) = gst_util_uint64_scale((guint64)index, GST_SECOND, FPS);
        GST_BUFFER_DURATION(buffer) = gst_util_uint64_scale((guint64)index + 1, GST_SECOND, FPS) - GST_BUFFER_PTS(buffer);
        ok = gst_app_src_push_buffer(GST_APP_SRC(audio), buffer) == GST_FLOW_OK;
    }
    gst_app_src_end_of_stream(GST_APP_SRC(video));
    if (audio) gst_app_src_end_of_stream(GST_APP_SRC(audio));
    if (ok) ok = finish_pipeline(pipeline, 30);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(video); if (audio) gst_object_unref(audio); gst_object_unref(output); gst_object_unref(pipeline);
    return ok;
}

typedef struct { double ms; int barcode; unsigned char red, green, blue; } VideoPoint;
typedef struct {
    GArray *video, *audio;
    GByteArray *coverage;
    int width, height;
    double end_ms;
} Decoded;

static void decoded_clear(Decoded *decoded) {
    if (decoded->video) g_array_unref(decoded->video);
    if (decoded->audio) g_array_unref(decoded->audio);
    if (decoded->coverage) g_byte_array_unref(decoded->coverage);
    memset(decoded, 0, sizeof *decoded);
}

static int barcode(const unsigned char *pixels, int width, int stride) {
    int result = 0;
    for (int bit = 0; bit < 8; bit++) {
        const unsigned char *p = pixels + 12 * stride + (bit * width / 8 + width / 16) * 4;
        if ((int)p[0] + p[1] + p[2] > 384) result |= 1 << bit;
    }
    return result;
}

static gboolean sample_time(GstSample *sample, GstBuffer *buffer, GstClockTime *time) {
    const GstSegment *segment = gst_sample_get_segment(sample);
    if (!segment || segment->format != GST_FORMAT_TIME || !GST_BUFFER_PTS_IS_VALID(buffer)) return FALSE;
    /* MP4 edit lists expose nonzero buffer PTS/segment.start for decoder delay.
     * Evaluate media stream time, as a player does, instead of raw codec PTS. */
    *time = gst_segment_to_stream_time(segment, GST_FORMAT_TIME, GST_BUFFER_PTS(buffer));
    return GST_CLOCK_TIME_IS_VALID(*time);
}

static gboolean consume_video(Decoded *decoded, GstSample *sample) {
    GstVideoInfo info; GstVideoFrame frame;
    GstBuffer *buffer = gst_sample_get_buffer(sample);
    GstClockTime time;
    if (!gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) ||
        !sample_time(sample, buffer, &time) ||
        !gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ)) return FALSE;
    decoded->width = GST_VIDEO_INFO_WIDTH(&info); decoded->height = GST_VIDEO_INFO_HEIGHT(&info);
    int stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
    const unsigned char *pixels = GST_VIDEO_FRAME_PLANE_DATA(&frame, 0);
    const unsigned char *center = pixels + (decoded->height * 3 / 4) * stride + (decoded->width * 3 / 4) * 4;
    VideoPoint point = { (double)time / GST_MSECOND,
        barcode(pixels, decoded->width, stride), center[2], center[1], center[0] };
    g_array_append_val(decoded->video, point);
    decoded->end_ms = fmax(decoded->end_ms, (double)time / GST_MSECOND +
        (GST_BUFFER_DURATION_IS_VALID(buffer) ? (double)GST_BUFFER_DURATION(buffer) / GST_MSECOND : 1000.0 / FPS));
    gst_video_frame_unmap(&frame);
    return TRUE;
}

static gboolean consume_audio(Decoded *decoded, GstSample *sample) {
    GstBuffer *buffer = gst_sample_get_buffer(sample); GstMapInfo map;
    GstClockTime time;
    if (!sample_time(sample, buffer, &time) || !gst_buffer_map(buffer, &map, GST_MAP_READ)) return FALSE;
    guint64 offset = gst_util_uint64_scale_round(time, RATE, GST_SECOND);
    gsize count = map.size / (sizeof(float) * 2);
    if (offset + count > RATE * 30 || map.size % (sizeof(float) * 2) != 0) {
        gst_buffer_unmap(buffer, &map); return FALSE;
    }
    guint end = (guint)(offset + count), old = decoded->audio->len;
    if (end > old) {
        g_array_set_size(decoded->audio, end); g_byte_array_set_size(decoded->coverage, end);
        memset(decoded->coverage->data + old, 0, end - old);
    }
    for (gsize i = 0; i < count; i++) {
        /* Read the advertised little-endian float without unaligned access. */
        guint32 bits = GST_READ_UINT32_LE(map.data + i * 8); float value;
        memcpy(&value, &bits, sizeof value);
        if (!isfinite(value)) { gst_buffer_unmap(buffer, &map); return FALSE; }
        g_array_index(decoded->audio, float, (guint)offset + (guint)i) = value;
        decoded->coverage->data[(guint)offset + (guint)i] = 1;
    }
    decoded->end_ms = fmax(decoded->end_ms, (double)end * 1000.0 / RATE);
    gst_buffer_unmap(buffer, &map); return TRUE;
}

static gboolean decode_streams(const char *path, Decoded *decoded, gboolean with_audio) {
    GError *error = NULL;
    GstElement *pipeline = gst_parse_launch(with_audio ?
        "filesrc name=input ! decodebin name=d "
        "d. ! queue ! videoconvert ! video/x-raw,format=BGRA ! appsink name=video sync=false "
        "d. ! queue ! audioconvert ! audioresample ! "
        "audio/x-raw,format=F32LE,rate=48000,channels=2,layout=interleaved ! appsink name=audio sync=false" :
        "filesrc name=input ! decodebin ! queue ! videoconvert ! "
        "video/x-raw,format=BGRA ! appsink name=video sync=false", &error);
    if (!pipeline || error) {
        g_snprintf(error_text, sizeof error_text, "%s", error ? error->message : "decoder missing");
        g_clear_error(&error); if (pipeline) gst_object_unref(pipeline); return FALSE;
    }
    decoded->video = g_array_new(FALSE, FALSE, sizeof(VideoPoint));
    decoded->audio = g_array_new(FALSE, TRUE, sizeof(float)); decoded->coverage = g_byte_array_new();
    GstElement *input = gst_bin_get_by_name(GST_BIN(pipeline), "input");
    GstElement *video = gst_bin_get_by_name(GST_BIN(pipeline), "video");
    GstElement *audio = gst_bin_get_by_name(GST_BIN(pipeline), "audio");
    GstBus *bus = gst_element_get_bus(pipeline);
    g_object_set(input, "location", path, NULL);
    gboolean ok = gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE;
    gint64 deadline = g_get_monotonic_time() + 30000000;
    gboolean eos = FALSE;
    while (ok && g_get_monotonic_time() < deadline) {
        gboolean consumed = FALSE;
        GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(video), 0);
        if (sample) { consumed = TRUE; ok = consume_video(decoded, sample); gst_sample_unref(sample); }
        sample = audio ? gst_app_sink_try_pull_sample(GST_APP_SINK(audio), 0) : NULL;
        if (sample) { consumed = TRUE; ok = consume_audio(decoded, sample) && ok; gst_sample_unref(sample); }
        GstMessage *message;
        while ((message = gst_bus_pop(bus))) {
            if (bus_error(message)) ok = FALSE;
            if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS) eos = TRUE;
            gst_message_unref(message);
        }
        if (eos && !consumed) break;
        if (!consumed) g_usleep(1000);
    }
    if (!eos && ok) { g_strlcpy(error_text, "independent decode timed out", sizeof error_text); ok = FALSE; }
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(input); gst_object_unref(video); if (audio) gst_object_unref(audio); gst_object_unref(bus); gst_object_unref(pipeline);
    return ok && decoded->video->len > 0 && (!with_audio || decoded->audio->len > 0);
}

static gboolean decode(const char *path, Decoded *decoded) {
    return decode_streams(path, decoded, TRUE);
}

static const VideoPoint *video_at(const Decoded *decoded, double ms) {
    const VideoPoint *nearest = NULL;
    double distance = 1e30;
    for (guint i = 0; i < decoded->video->len; i++) {
        const VideoPoint *point = &g_array_index(decoded->video, VideoPoint, i);
        if (fabs(point->ms - ms) < distance) { nearest = point; distance = fabs(point->ms - ms); }
    }
    return distance < 35 ? nearest : NULL;
}

static gboolean tone_at(const Decoded *decoded, double ms, gboolean audible) {
    guint start = (guint)(ms * RATE / 1000.0), count = RATE / 10;
    if (start + count > decoded->audio->len) return FALSE;
    double sum = 0; int crossing = 0; float previous = 0;
    for (guint i = start; i < start + count; i++) {
        if (!decoded->coverage->data[i]) return FALSE; /* Missing data is not silence. */
        float value = g_array_index(decoded->audio, float, i);
        sum += (double)value * value;
        if (i > start && previous <= 0 && value > 0) crossing++;
        previous = value;
    }
    double rms = sqrt(sum / count);
    gboolean ok = audible ? rms > 0.12 && crossing >= 41 && crossing <= 47 : rms < 0.001;
    if (!ok) g_snprintf(error_text, sizeof error_text, "at %.0fms rms=%.5f pitch≈%dHz expected %s",
        ms, rms, crossing * 10, audible ? "440Hz tone" : "silence");
    return ok;
}

static gboolean video_matches(const Decoded *decoded, double ms, double source_ms, gboolean crop) {
    const VideoPoint *point = video_at(decoded, ms);
    if (!point) return FALSE;
    gboolean ok;
    if (source_ms < 0) ok = point->red < 10 && point->green < 10 && point->blue < 10;
    else if (crop) ok = point->red > 190 && point->green > 170 && point->blue < 60;
    else ok = abs(point->barcode - (int)(source_ms * FPS / 1000.0)) <= 1;
    if (!ok) g_snprintf(error_text, sizeof error_text, "at %.0fms barcode=%d expected source %.0fms, RGB=%u,%u,%u",
        ms, point->barcode, source_ms, point->red, point->green, point->blue);
    return ok;
}

static MCGstPlan identity(void) {
    MCGstPlan plan = {0};
    plan.width = WIDTH; plan.height = HEIGHT; plan.crop_width = WIDTH; plan.crop_height = HEIGHT;
    plan.duration = SECONDS * 90000; plan.video_count = plan.audio_count = 1;
    plan.video[0] = (MCGstClip){0, 0, SECONDS * 90000, SECONDS * 90000}; plan.audio[0] = plan.video[0];
    return plan;
}

static gboolean render(const char *source, const char *output, const MCGstPlan *plan,
                       gboolean mp4, int *priming) {
    MCGstEngine *engine = mc_gst_engine_new(source, plan, error_text, sizeof error_text);
    if (!engine) return FALSE;
    gboolean ok = mc_gst_engine_render(engine, output, mp4 != FALSE, error_text, sizeof error_text);
    gint64 deadline = g_get_monotonic_time() + 45000000;
    int status = MC_GST_RUNNING;
    while (ok && status == MC_GST_RUNNING && g_get_monotonic_time() < deadline) {
        while (g_main_context_iteration(NULL, FALSE)) {}
        status = mc_gst_engine_poll(engine, error_text, sizeof error_text); g_usleep(1000);
    }
    if (priming) *priming = mc_gst_engine_aac_priming(engine);
    mc_gst_engine_free(engine);
    if (status == MC_GST_RUNNING && ok) g_strlcpy(error_text, "render timed out", sizeof error_text);
    return ok && status == MC_GST_EOS;
}

static gboolean frame_at(MCGstEngine *engine, double ms, MCGstFrame *frame) {
    if (!mc_gst_engine_seek(engine, ms, 1, false, error_text, sizeof error_text)) return FALSE;
    gint64 deadline = g_get_monotonic_time() + 3000000;
    while (g_get_monotonic_time() < deadline) {
        if (mc_gst_engine_frame(engine, frame)) return TRUE;
        if (mc_gst_engine_poll(engine, error_text, sizeof error_text) == MC_GST_ERROR) return FALSE;
        while (g_main_context_iteration(NULL, FALSE)) {}
        g_usleep(1000);
    }
    g_strlcpy(error_text, "no preview frame after seek", sizeof error_text); return FALSE;
}

static void preview_test(const char *source) {
    MCGstPlan plan = identity();
    MCGstEngine *engine = mc_gst_engine_new(source, &plan, error_text, sizeof error_text);
    if (!check(engine != NULL, "preview engine opens")) return;
    if (!check(mc_gst_engine_preview(engine, true, error_text, sizeof error_text), "preview prerolls without devices")) {
        mc_gst_engine_free(engine); return;
    }
    MCGstFrame frame = {0};
    const double positions[] = {1500, 500, 3500, 1000, 4500, 2500, 0, 1500};
    for (size_t i = 0; i < G_N_ELEMENTS(positions); i++) {
        if (check(frame_at(engine, positions[i], &frame), "paused seek produces a BGRA frame")) {
            int actual = barcode(frame.pixels, frame.width, frame.stride);
            int expected = (int)(positions[i] * FPS / 1000);
            g_snprintf(error_text, sizeof error_text, "size=%dx%d frame=%d expected=%d PTS=%.3fms",
                frame.width, frame.height, actual, expected, (double)frame.pts_ns / GST_MSECOND);
            check(frame.width == WIDTH && frame.height == HEIGHT && abs(actual - expected) <= 1,
                "preview frame corresponds to requested source time");
            mc_gst_frame_clear(&frame);
        }
    }
    double before = mc_gst_engine_position(engine);
    check(mc_gst_engine_play(engine, true, error_text, sizeof error_text), "play resumes the actual pipeline");
    gint64 deadline = g_get_monotonic_time() + 250000;
    while (g_get_monotonic_time() < deadline) {
        while (g_main_context_iteration(NULL, FALSE)) {}
        if (mc_gst_engine_frame(engine, &frame)) mc_gst_frame_clear(&frame);
        g_usleep(1000);
    }
    check(mc_gst_engine_play(engine, false, error_text, sizeof error_text), "pause acknowledges PAUSED state");
    double paused = mc_gst_engine_position(engine);
    g_usleep(100000);
    check(paused > before + 80 && fabs(mc_gst_engine_position(engine) - paused) < 5,
        "play advances and pause freezes the actual media clock");
    mc_gst_engine_free(engine);
}

static void case_test(const char *directory, const char *source, const char *name, MCGstPlan *plan,
                      double at, double source_at, gboolean audible, gboolean crop) {
    char *path = g_strdup_printf("%s/%s.mkv", directory, name);
    char label[160];
    MCGstEngine *preview = mc_gst_engine_new(source, plan, error_text, sizeof error_text);
    MCGstFrame frame = {0};
    gboolean ready = preview && mc_gst_engine_preview(preview, true, error_text, sizeof error_text);
    g_snprintf(label, sizeof label, "%s previews the same immutable plan", name);
    if (check(ready && frame_at(preview, at, &frame), label)) {
        const unsigned char *p = frame.pixels + (frame.height * 3 / 4) * frame.stride + (frame.width * 3 / 4) * 4;
        gboolean matches = source_at < 0 ? p[0] < 10 && p[1] < 10 && p[2] < 10 : crop ?
            p[2] > 190 && p[1] > 170 && p[0] < 60 :
            abs(barcode(frame.pixels, frame.width, frame.stride) - (int)(source_at * FPS / 1000)) <= 1;
        g_snprintf(label, sizeof label, "%s preview pixels match source mapping and crop", name);
        g_snprintf(error_text, sizeof error_text, "frame=%d RGB=%u,%u,%u PTS=%.3fms",
            barcode(frame.pixels, frame.width, frame.stride), p[2], p[1], p[0], (double)frame.pts_ns / GST_MSECOND);
        check(matches && frame.width == plan->crop_width && frame.height == plan->crop_height, label);
    }
    mc_gst_frame_clear(&frame); mc_gst_engine_free(preview);
    g_snprintf(label, sizeof label, "%s reaches real render EOS", name);
    if (!check(render(source, path, plan, FALSE, NULL), label)) { g_free(path); return; }
    Decoded decoded = {0}; g_snprintf(label, sizeof label, "%s independently decodes both streams", name);
    if (check(decode(path, &decoded), label)) {
        double duration_ms = (double)plan->duration / 90;
        const VideoPoint *last = &g_array_index(decoded.video, VideoPoint, decoded.video->len - 1);
        g_snprintf(label, sizeof label, "%s preserves output dimensions and duration", name);
        check(decoded.width == plan->crop_width && decoded.height == plan->crop_height &&
            fabs(last->ms + 1000.0 / FPS - duration_ms) < 35 && fabs(decoded.end_ms - duration_ms) < 35, label);
        g_snprintf(label, sizeof label, "%s pixels follow immutable plan", name);
        check(video_matches(&decoded, at, source_at, crop), label);
        g_snprintf(label, sizeof label, "%s audio content and pitch follow explicit audio clips", name);
        check(tone_at(&decoded, at, audible), label);
        if (!strcmp(name, "identity") || !strcmp(name, "speed-1.5") || !strcmp(name, "speed-3")) {
            check(tone_at(&decoded, 30, TRUE), "tone remains audible near the leading edge");
            check(tone_at(&decoded, duration_ms - 150, TRUE), "tone remains audible near the trailing edge");
        }
        if (!strcmp(name, "linked-gap") || !strcmp(name, "independent-audio")) {
            check(video_matches(&decoded, 4000, 3000, FALSE), "post-gap video uses its own source range");
            check(tone_at(&decoded, 4000, TRUE), "post-gap audio remains audible");
        }
        if (!strcmp(name, "independent-audio"))
            check(tone_at(&decoded, 6400, FALSE), "independent audio stops at its own end while video continues");
    }
    decoded_clear(&decoded); g_free(path);
}

static gboolean edge_tone(const Decoded *decoded, double ms) {
    guint start = (guint)(ms * RATE / 1000.0), count = RATE / 100;
    if (start + count > decoded->audio->len) return FALSE;
    double sum = 0;
    for (guint i = start; i < start + count; i++) {
        if (!decoded->coverage->data[i]) return FALSE;
        double value = g_array_index(decoded->audio, float, i);
        sum += value * value;
    }
    double rms = sqrt(sum / count);
    if (rms <= 0.12) g_snprintf(error_text, sizeof error_text,
        "edge at %.3fms rms=%.6f: AAC priming/tail must not replace source audio", ms, rms);
    return rms > 0.12;
}

static void mp4_test(const char *directory, const char *source, const char *name,
                     const MCGstPlan *plan, double source_ms) {
    char *raw = g_strdup_printf("%s/%s-raw.mp4", directory, name);
    char *final = g_strdup_printf("%s/%s.mp4", directory, name);
    char label[160]; int priming = 0;
    Decoded decoded = {0};
    g_snprintf(label, sizeof label, "%s raw H264/AAC render reaches EOS", name);
    if (!check(render(source, raw, plan, TRUE, &priming), label)) goto done;
    if (!check(priming > 0, "selected AAC encoder declares its priming samples")) goto done;
    /* render() has already crossed EOS and freed the GES pipeline. Only the
     * finalizer output is a publishable MP4; keep raw input for mp4-mux tests. */
    g_snprintf(label, sizeof label, "%s packet-copy finalization compensates AAC priming", name);
    if (!check(mc_mp4_mux_copy(raw, final, priming, NULL, NULL, error_text, sizeof error_text), label)) goto done;
    g_snprintf(label, sizeof label, "%s finalized MP4 independently decodes", name);
    if (check(decode(final, &decoded), label)) {
        double duration_ms = (double)plan->duration / 90;
        const VideoPoint *last = &g_array_index(decoded.video, VideoPoint, decoded.video->len - 1);
        g_snprintf(label, sizeof label, "%s final MP4 retains duration and dimensions", name);
        check(decoded.width == plan->crop_width && decoded.height == plan->crop_height &&
            fabs(last->ms + 1000.0 / FPS - duration_ms) < 35 &&
            fabs(decoded.end_ms - duration_ms) < 35, label);
        g_snprintf(label, sizeof label, "%s MP4 video still follows source-time mapping", name);
        check(video_matches(&decoded, 1000, source_ms, FALSE), label);
        check(tone_at(&decoded, 1000, TRUE), "final MP4 preserves audible 440Hz pitch");
        check(edge_tone(&decoded, 0), "final MP4 preserves the first 10ms of source audio");
        check(edge_tone(&decoded, duration_ms - 10), "final MP4 preserves the last 10ms of source audio");
        if (!strcmp(name, "audio-tail")) {
            check(video_matches(&decoded, 4500, -1, FALSE) && tone_at(&decoded, 4500, TRUE),
                "final MP4 keeps independent audio after video ends, with black video tail");
        }
    }
done:
    decoded_clear(&decoded); g_free(raw); g_free(final);
}

static void no_audio_test(const char *directory, const char *source, const char *name) {
    MCGstPlan plan = identity(); plan.audio_count = 0;
    char label[192];
    /* Remove the audio-device selector from this isolated process registry.
     * silent=false must still work for a plan without audio, proving that the
     * production path does not merely happen to find an available device. */
    GstElementFactory *device = gst_element_factory_find("autoaudiosink");
    if (device) gst_registry_remove_feature(gst_registry_get(), GST_PLUGIN_FEATURE(device));
    MCGstEngine *preview = mc_gst_engine_new(source, &plan, error_text, sizeof error_text);
    MCGstFrame frame = {0};
    gboolean ready = preview && mc_gst_engine_preview(preview, false, error_text, sizeof error_text);
    g_snprintf(label, sizeof label, "%s production preview needs no audio-device factory", name);
    check(ready && frame_at(preview, 1500, &frame) &&
        abs(barcode(frame.pixels, frame.width, frame.stride) - 45) <= 1, label);
    mc_gst_frame_clear(&frame);
    g_snprintf(label, sizeof label, "%s production play/pause works without an audio device", name);
    check(ready && mc_gst_engine_play(preview, true, error_text, sizeof error_text) &&
        mc_gst_engine_play(preview, false, error_text, sizeof error_text), label);
    mc_gst_engine_free(preview);
    if (device) { gst_registry_add_feature(gst_registry_get(), GST_PLUGIN_FEATURE(device)); gst_object_unref(device); }
    for (int mp4 = 0; mp4 < 2; mp4++) {
        char *raw = g_strdup_printf("%s/%s-raw.%s", directory, name, mp4 ? "mp4" : "mkv");
        char *final = g_strdup_printf("%s/%s.mp4", directory, name);
        int priming = -1;
        g_snprintf(label, sizeof label, "%s video-only %s reaches EOS without a phantom audio stream", name, mp4 ? "MP4" : "Matroska");
        if (!check(render(source, raw, &plan, mp4, &priming), label)) { g_free(raw); g_free(final); continue; }
        check(priming == 0, "video-only output declares zero AAC priming");
        const char *output = raw;
        if (mp4) {
            if (!check(mc_mp4_mux_copy(raw, final, priming, NULL, NULL, error_text, sizeof error_text),
                "video-only MP4 crosses the same finalization/publication boundary")) { g_free(raw); g_free(final); continue; }
            output = final;
        }
        MCGstMetadata metadata = {0};
        g_snprintf(label, sizeof label, "%s %s has video and no encoded audio track", name, mp4 ? "MP4" : "Matroska");
        check(mc_gst_media_probe(output, &metadata, error_text, sizeof error_text) && !metadata.has_audio &&
            metadata.width == WIDTH && metadata.height == HEIGHT && fabs(metadata.duration_ms - 6000) < 35, label);
        Decoded decoded = {0};
        g_snprintf(label, sizeof label, "%s %s independently decodes source frames through the tail", name, mp4 ? "MP4" : "Matroska");
        check(decode_streams(output, &decoded, FALSE) && fabs(decoded.end_ms - 6000) < 35 &&
            video_matches(&decoded, 0, 0, FALSE) && video_matches(&decoded, 1500, 1500, FALSE) &&
            video_matches(&decoded, 5850, 5850, FALSE), label);
        decoded_clear(&decoded); g_free(raw); g_free(final);
    }
}

static void cancel_test(const char *directory, const char *source) {
    char *path = g_build_filename(directory, "cancelled.mkv", NULL);
    MCGstPlan plan = identity();
    plan.duration = 30 * 90000; plan.video_count = plan.audio_count = 5;
    for (size_t i = 0; i < 5; i++) {
        plan.video[i] = (MCGstClip){(int64_t)i * 540000, 0, 540000, 540000};
        plan.audio[i] = plan.video[i];
    }
    MCGstEngine *engine = mc_gst_engine_new(source, &plan, error_text, sizeof error_text);
    if (check(engine != NULL, "cancellable engine opens")) {
        check(mc_gst_engine_render(engine, path, false, error_text, sizeof error_text), "cancelled render starts");
        check(mc_gst_engine_poll(engine, error_text, sizeof error_text) == MC_GST_RUNNING,
            "cancellation occurs before render EOS");
        mc_gst_engine_free(engine); /* Synchronous NULL barrier, not an optimistic cancellation ACK. */
        check(!g_file_test(path, G_FILE_TEST_EXISTS) || g_remove(path) == 0,
            "cancel NULL barrier releases the output file");
        engine = mc_gst_engine_new(source, &plan, error_text, sizeof error_text);
        if (check(engine != NULL, "source reopens after cancelled render")) {
            gboolean ready = mc_gst_engine_preview(engine, true, error_text, sizeof error_text);
            MCGstFrame frame = {0};
            check(ready && frame_at(engine, 500, &frame), "reopened preview decodes after cancellation");
            mc_gst_frame_clear(&frame); mc_gst_engine_free(engine);
        }
    }
    g_free(path);
}

static char *file_hash(const char *path) {
    char *bytes = NULL; gsize length = 0;
    if (!g_file_get_contents(path, &bytes, &length, NULL)) return NULL;
    char *hash = g_compute_checksum_for_data(G_CHECKSUM_SHA256, (const guchar *)bytes, length);
    g_free(bytes); return hash;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: gst-media OUTPUT_DIRECTORY\n"); return 2; }
    if (g_mkdir_with_parents(argv[1], 0700) != 0) return 2;
    if (!check(mc_gst_media_init(error_text, sizeof error_text), "GStreamer and GES initialize")) return 1;
    char *source = g_build_filename(argv[1], "generated-source.mkv", NULL);
    if (!check(generate_source(source, TRUE), "portable source generated with frame barcode and 440Hz tone")) { g_free(source); return 1; }
    char *original_hash = file_hash(source);
    MCGstMetadata metadata = {0};
    check(mc_gst_media_probe(source, &metadata, error_text, sizeof error_text) &&
        metadata.width == WIDTH && metadata.height == HEIGHT && metadata.has_audio &&
        fabs(metadata.duration_ms - SECONDS * 1000) < 35, "probe reports generated source metadata");
    char *silent_source = g_build_filename(argv[1], "generated-silent-source.mkv", NULL);
    if (check(generate_source(silent_source, FALSE), "portable recording source genuinely contains no audio stream")) {
        check(mc_gst_media_probe(silent_source, &metadata, error_text, sizeof error_text) && !metadata.has_audio,
            "video-only recording probe reports hasAudio=false");
        no_audio_test(argv[1], silent_source, "silent-recording");
    }
    g_free(silent_source);
    no_audio_test(argv[1], source, "muted-plan");
    preview_test(source);
    MCGstPlan plan = identity();
    case_test(argv[1], source, "identity", &plan, 1500, 1500, TRUE, FALSE);
    plan.duration = 7 * 90000; plan.video_count = plan.audio_count = 2;
    plan.video[0] = (MCGstClip){0, 0, 180000, 180000};
    plan.video[1] = (MCGstClip){270000, 180000, 540000, 360000};
    plan.audio[0] = plan.video[0]; plan.audio[1] = plan.video[1];
    case_test(argv[1], source, "linked-gap", &plan, 2400, -1, FALSE, FALSE);
    plan.audio_count = 1; plan.audio[0] = (MCGstClip){0, 0, 540000, 540000};
    case_test(argv[1], source, "independent-audio", &plan, 2400, -1, TRUE, FALSE);
    plan = identity(); plan.video[0].source_end = plan.video[0].duration = 3 * 90000;
    case_test(argv[1], source, "audio-tail", &plan, 4500, -1, TRUE, FALSE);
    mp4_test(argv[1], source, "audio-tail", &plan, 1000);
    plan = identity(); plan.duration = 360000; plan.video[0].duration = plan.audio[0].duration = plan.duration;
    case_test(argv[1], source, "speed-1.5", &plan, 1000, 1500, TRUE, FALSE);
    plan.duration = 180000; plan.video[0].duration = plan.audio[0].duration = plan.duration;
    case_test(argv[1], source, "speed-3", &plan, 1000, 3000, TRUE, FALSE);
    plan = identity(); plan.crop_x = WIDTH / 2; plan.crop_y = HEIGHT / 2;
    plan.crop_width = WIDTH / 2; plan.crop_height = HEIGHT / 2;
    case_test(argv[1], source, "crop", &plan, 1000, 1000, TRUE, TRUE);
    plan = identity();
    mp4_test(argv[1], source, "identity", &plan, 1000);
    plan.duration = 180000; plan.video[0].duration = plan.audio[0].duration = plan.duration;
    mp4_test(argv[1], source, "speed-3", &plan, 3000);
    cancel_test(argv[1], source);
    char *final_hash = file_hash(source);
    check(original_hash && final_hash && !strcmp(original_hash, final_hash),
        "preview edits exports and cancellation leave original source bytes unchanged");
    g_free(original_hash); g_free(final_hash);
    g_free(source);
    printf("gst-media: %d failure(s)\n", failures);
    return failures ? 1 : 0;
}
