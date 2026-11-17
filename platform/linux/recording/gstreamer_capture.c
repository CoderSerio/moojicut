#define _POSIX_C_SOURCE 200809L
#include "gstreamer_capture.h"
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <gst/gst.h>
#include <gst/pbutils/pbutils.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

struct MCGstCapture {
    MCGstCaptureInput input;
    char *partial, *target, *error;
    int fd, stop, refs, first_frame;
    gboolean success, fixture, fixture_error, delivered_done;
    MCGstStarted started;
    MCGstFinished finished;
    gpointer data;
    GMainContext *context;
};
static GQuark capture_error(void) { return g_quark_from_static_string("moojicut-recording"); }
static void fail(MCGstCapture *c, const char *message) {
    if (!c->error) c->error = g_strdup(message);
}
static gboolean factory_available(const char *name, GError **error) {
    GstElementFactory *factory = gst_element_factory_find(name);
    if (factory) { gst_object_unref(factory); return TRUE; }
    g_set_error(error, capture_error(), 1, "缺少 GStreamer 组件 %s，请安装对应录屏依赖。", name);
    return FALSE;
}
gboolean mc_gst_capture_available(MCGstSource source, GError **error) {
    if (!gst_init_check(NULL, NULL, error)) return FALSE;
    const char *required[] = {"videoconvert", "videoscale", "videorate", "capsfilter",
                              "queue", "vp8enc", "webmmux", "filesink", NULL};
    for (int i = 0; required[i]; i++) if (!factory_available(required[i], error)) return FALSE;
    return factory_available(source == MC_GST_X11 ? "ximagesrc" : "pipewiresrc", error);
}
static void capture_unref(MCGstCapture *c);
static gboolean notify_started(gpointer data) {
    MCGstCapture *c = data;
    if (!c->delivered_done && c->started) c->started(c, c->data);
    return G_SOURCE_REMOVE;
}
static void capture_free(MCGstCapture *c) {
    if (c->fd >= 0) close(c->fd);
    g_free(c->partial); g_free(c->target); g_free(c->error);
    g_main_context_unref(c->context); g_free(c);
}
static void capture_unref(MCGstCapture *c) { if (g_atomic_int_dec_and_test(&c->refs)) capture_free(c); }
static void done(GObject *object, GAsyncResult *result, gpointer data) {
    (void)object;
    MCGstCapture *c = data;
    g_task_propagate_boolean(G_TASK(result), NULL);
    c->delivered_done = TRUE;
    if (c->finished) c->finished(c, c->success,
        c->success ? c->target : c->partial, c->error, c->data);
    capture_unref(c);
}
static gboolean probe_file(const char *path, int width, int height, GError **error) {
    GstDiscoverer *probe = gst_discoverer_new(5 * GST_SECOND, error);
    if (!probe) return FALSE;
    char *uri = g_filename_to_uri(path, NULL, error);
    GstDiscovererInfo *info = uri ? gst_discoverer_discover_uri(probe, uri, error) : NULL;
    gboolean valid = info && gst_discoverer_info_get_result(info) == GST_DISCOVERER_OK &&
        GST_CLOCK_TIME_IS_VALID(gst_discoverer_info_get_duration(info)) &&
        gst_discoverer_info_get_duration(info) > 0;
    GList *video = info ? gst_discoverer_info_get_video_streams(info) : NULL;
    GList *audio = info ? gst_discoverer_info_get_audio_streams(info) : NULL;
    valid = valid && g_list_length(video) == 1 && !audio;
    if (valid) {
        GstDiscovererVideoInfo *v = video->data;
        valid = gst_discoverer_video_info_get_width(v) == (guint)width &&
                gst_discoverer_video_info_get_height(v) == (guint)height;
    }
    gst_discoverer_stream_info_list_free(video); gst_discoverer_stream_info_list_free(audio);
    if (info) gst_discoverer_info_unref(info);
    g_free(uri); g_object_unref(probe);
    if (!valid && error && !*error) g_set_error_literal(error, capture_error(), 2, "录屏文件未通过时长/画面检查；原片已保留。");
    return valid;
}
static GstPadProbeReturn source_frame(GstPad *pad, GstPadProbeInfo *info, gpointer data) {
    (void)pad; (void)info;
    MCGstCapture *c = data; g_atomic_int_set(&c->first_frame, 1); return GST_PAD_PROBE_OK;
}
static GstElement *make_pipeline(MCGstCapture *c) {
    GstElement *pipeline = gst_pipeline_new(NULL);
    const char *names[] = {c->fixture ? "videotestsrc" : c->input.kind == MC_GST_X11 ? "ximagesrc" : "pipewiresrc",
        "queue", "videoconvert", "videoscale", "videorate", "capsfilter", "vp8enc", "webmmux", "filesink"};
    GstElement *elements[G_N_ELEMENTS(names)] = {NULL};
    for (guint i = 0; i < G_N_ELEMENTS(names); i++) {
        elements[i] = gst_element_factory_make(names[i], NULL);
        if (!elements[i]) {
            char *message = g_strdup_printf("无法创建 GStreamer 组件 %s。", names[i]);
            fail(c, message); g_free(message); gst_object_unref(pipeline); return NULL;
        }
        gst_bin_add(GST_BIN(pipeline), elements[i]);
    }
    GstElement *source = elements[0];
    if (c->fixture) g_object_set(source, "is-live", TRUE, NULL);
    else if (c->input.kind == MC_GST_X11) {
        /* ximagesrc end coordinates are inclusive, in X root physical pixels. */
        g_object_set(source, "startx", (guint)c->input.x, "starty", (guint)c->input.y,
            "endx", (guint)(c->input.x + c->input.width - 1),
            "endy", (guint)(c->input.y + c->input.height - 1),
            "use-damage", FALSE, "show-pointer", TRUE, NULL);
    } else {
        char *node = g_strdup_printf("%u", c->input.pipewire_node);
        g_object_set(source, "fd", c->fd, "path", node, "do-timestamp", TRUE, NULL);
        if (g_object_class_find_property(G_OBJECT_GET_CLASS(source), "always-copy"))
            g_object_set(source, "always-copy", TRUE, NULL);
        g_free(node);
    }
    g_object_set(elements[1], "max-size-buffers", 8, "max-size-bytes", 0, "max-size-time", (guint64)0, NULL);
    GstCaps *caps = gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING, "I420",
        "width", G_TYPE_INT, c->input.output_width, "height", G_TYPE_INT, c->input.output_height,
        "framerate", GST_TYPE_FRACTION, c->input.frames_per_second, 1,
        "pixel-aspect-ratio", GST_TYPE_FRACTION, 1, 1, NULL);
    g_object_set(elements[5], "caps", caps, NULL); gst_caps_unref(caps);
    GstPad *frame_pad = gst_element_get_static_pad(elements[5], "src");
    gst_pad_add_probe(frame_pad, GST_PAD_PROBE_TYPE_BUFFER, source_frame, c, NULL); gst_object_unref(frame_pad);
    g_object_set(elements[6], "deadline", (gint64)1, "cpu-used", 8,
        "threads", 2, "target-bitrate", 4000000, "keyframe-max-dist", c->input.frames_per_second * 2, NULL);
    g_object_set(elements[7], "streamable", FALSE, NULL);
    g_object_set(elements[8], "location", c->partial, "sync", FALSE, NULL);
    for (guint i = 1; i < G_N_ELEMENTS(names); i++) {
        GstElement *previous = elements[i - 1];
        if (i == 6 && c->fixture_error) {
            /* Smoke-only genuine streaming failure, after a few raw buffers. */
            GstElement *fault = gst_element_factory_make("identity", NULL);
            if (!fault) { fail(c, "Missing identity fixture element."); gst_object_unref(pipeline); return NULL; }
            gst_bin_add(GST_BIN(pipeline), fault); g_object_set(fault, "error-after", 4, NULL);
            if (!gst_element_link(previous, fault)) { fail(c, "Cannot link fault fixture."); gst_object_unref(pipeline); return NULL; }
            previous = fault;
        }
        if (!gst_element_link(previous, elements[i])) {
            fail(c, "无法连接静音录屏编码管线。"); gst_object_unref(pipeline); return NULL;
        }
    }
    return pipeline;
}
static void run_capture(GTask *task, gpointer object, gpointer task_data, GCancellable *cancel) {
    (void)object; (void)cancel;
    MCGstCapture *c = task_data;
    GstElement *pipeline = make_pipeline(c);
    gboolean eos = FALSE, started = FALSE, playing = FALSE, stopping = FALSE;
    gint64 deadline = g_get_monotonic_time() + 20 * G_TIME_SPAN_SECOND;
    GstBus *bus = pipeline ? gst_element_get_bus(pipeline) : NULL;
    if (pipeline && gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE)
        fail(c, "录屏来源或编码器无法启动；请检查显示环境和依赖。");
    while (pipeline && !c->error && !eos) {
        if (g_atomic_int_get(&c->stop) && !stopping) {
            stopping = TRUE; deadline = g_get_monotonic_time() + 20 * G_TIME_SPAN_SECOND;
            if (!gst_element_send_event(pipeline, gst_event_new_eos())) fail(c, "录屏停止请求失败；已写出的原片仍保留。");
        }
        GstMessage *message = gst_bus_timed_pop_filtered(bus, 100 * GST_MSECOND,
            GST_MESSAGE_ERROR | GST_MESSAGE_EOS | GST_MESSAGE_STATE_CHANGED);
        if (message) {
            if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
                GError *error = NULL; char *debug = NULL;
                gst_message_parse_error(message, &error, &debug);
                fail(c, error ? error->message : "录屏管线失败。");
                g_clear_error(&error); g_free(debug);
            } else if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS) eos = TRUE;
            else if (GST_MESSAGE_SRC(message) == GST_OBJECT(pipeline)) {
                GstState old, current, pending;
                gst_message_parse_state_changed(message, &old, &current, &pending);
                playing = current == GST_STATE_PLAYING;
            }
            gst_message_unref(message);
        }
        if (playing && g_atomic_int_get(&c->first_frame) && !started && !stopping && !c->error) {
            started = TRUE;
            g_atomic_int_inc(&c->refs);
            /* invoke() may acquire an idle context and run inline.
             * An attached source always waits for host loop dispatch. */
            GSource *notice = g_idle_source_new();
            g_source_set_callback(notice, notify_started, c, (GDestroyNotify)capture_unref);
            g_source_attach(notice, c->context); g_source_unref(notice);
        }
        if ((!started || stopping) && g_get_monotonic_time() > deadline)
            fail(c, stopping ? "录屏收尾超时；未完成原片已保留。" : "录屏来源没有及时提供视频帧。");
    }
    if (pipeline) {
        /* Worker retains ownership until NULL has stopped source/writer threads.
         * No UI callback reports cleanup while this potentially slow call runs. */
        if (gst_element_set_state(pipeline, GST_STATE_NULL) == GST_STATE_CHANGE_FAILURE)
            fail(c, "录屏管线释放失败；原片完整性尚未验证。");
        gst_object_unref(bus); gst_object_unref(pipeline);
    }
    if (c->fd >= 0) { close(c->fd); c->fd = -1; }
    if (eos && !c->error) {
        GError *error = NULL;
        if (!probe_file(c->partial, c->input.output_width, c->input.output_height, &error)) {
            fail(c, error ? error->message : "无法验证录屏文件。"); g_clear_error(&error);
        } else if (link(c->partial, c->target) != 0) {
            char *message = g_strdup_printf("无法发布录屏文件：%s；未覆盖任何已有文件。", g_strerror(errno));
            fail(c, message); g_free(message);
        } else {
            /* Same private directory/filesystem: link publishes without replace.
             * A failed unlink only leaves a second name for the same original. */
            g_unlink(c->partial); c->success = TRUE;
        }
    }
    g_task_return_boolean(task, TRUE);
}
static MCGstCapture *start(const MCGstCaptureInput *input, const char *directory,
                           MCGstStarted started, MCGstFinished finished, gpointer data,
                           int fixture, GError **error) {
    if (!input || (input->kind != MC_GST_X11 && input->kind != MC_GST_PIPEWIRE) ||
        input->output_width < 2 || input->output_height < 2 ||
        input->output_width > 3840 || input->output_height > 3840 ||
        input->output_width % 2 || input->output_height % 2 ||
        input->frames_per_second < 1 || input->frames_per_second > 30 ||
        (!fixture && input->kind == MC_GST_X11 && (input->x < 0 || input->y < 0 ||
        input->width < 2 || input->height < 2 || input->width > 32768 || input->height > 32768 ||
        input->x > 32768 - input->width || input->y > 32768 - input->height))) {
        g_set_error_literal(error, capture_error(), 3, "无效的录屏像素范围或编码计划。"); return NULL;
    }
    MCGstCapture *c = g_new0(MCGstCapture, 1);
    c->input = *input; c->fd = -1; c->fixture = fixture != 0; c->fixture_error = fixture == 3; c->refs = 1;
    c->partial = g_build_filename(directory, "source.partial.webm", NULL);
    c->target = g_build_filename(directory, "source.webm", NULL);
    c->context = g_main_context_ref_thread_default();
    if (!fixture && input->kind == MC_GST_PIPEWIRE) {
        c->fd = input->pipewire_fd < 0 ? -1 : fcntl(input->pipewire_fd, F_DUPFD_CLOEXEC, 3);
        if (c->fd < 0) { g_set_error_literal(error, capture_error(), 4, "PipeWire 录屏来源已失效。"); capture_free(c); return NULL; }
    }
    /* Fresh output only. Never truncate another attempt's retained original. */
    int file = g_open(c->partial, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    if (file < 0) { g_set_error(error, capture_error(), 5, "无法创建原片：%s", g_strerror(errno)); capture_free(c); return NULL; }
    close(file);
    c->started = started; c->finished = finished; c->data = data;
    GTask *task = g_task_new(NULL, NULL, done, c);
    g_task_set_task_data(task, c, NULL); g_task_run_in_thread(task, run_capture); g_object_unref(task);
    return c;
}
MCGstCapture *mc_gst_capture_start(const MCGstCaptureInput *input, const char *directory,
                                 MCGstStarted started, MCGstFinished finished, gpointer data,
                                 GError **error) {
    return start(input, directory, started, finished, data, FALSE, error);
}
void mc_gst_capture_stop(MCGstCapture *c) { if (c) g_atomic_int_set(&c->stop, 1); }

typedef struct { int fd, width, height; guint32 node; char *error; MCGstDimensions callback; gpointer data; } Probe;
static void probe_handoff(GstElement *sink, GstBuffer *buffer, GstPad *pad, gpointer data) {
    (void)sink; (void)buffer; Probe *p = data;
    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (caps) {
        const GstStructure *s = gst_caps_get_structure(caps, 0); int width = 0, height = 0;
        if (gst_structure_get_int(s, "width", &width) && gst_structure_get_int(s, "height", &height)) {
            g_atomic_int_set(&p->height, height); g_atomic_int_set(&p->width, width);
        }
        gst_caps_unref(caps);
    }
}
static void probe_worker(GTask *task, gpointer object, gpointer task_data, GCancellable *cancel) {
    (void)object; (void)cancel; Probe *p = task_data;
    GstElement *pipeline = gst_pipeline_new(NULL);
    GstElement *source = gst_element_factory_make("pipewiresrc", NULL), *sink = gst_element_factory_make("fakesink", NULL);
    if (p->fd < 0 || !source || !sink) {
        p->error = g_strdup("无法创建 PipeWire 视频探测；请检查来源和 gstreamer1.0-pipewire。");
        if (source) gst_object_unref(source);
        if (sink) gst_object_unref(sink);
    } else {
        char *node = g_strdup_printf("%u", p->node);
        g_object_set(source, "fd", p->fd, "path", node, NULL); g_free(node);
        g_object_set(sink, "signal-handoffs", TRUE, "sync", FALSE, NULL);
        g_signal_connect(sink, "handoff", G_CALLBACK(probe_handoff), p);
        gst_bin_add_many(GST_BIN(pipeline), source, sink, NULL);
        if (!gst_element_link(source, sink) || gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE)
            p->error = g_strdup("PipeWire 来源无法提供视频流。");
        GstBus *bus = gst_element_get_bus(pipeline);
        gint64 deadline = g_get_monotonic_time() + 15 * G_TIME_SPAN_SECOND;
        while (!p->error && !g_atomic_int_get(&p->width) && g_get_monotonic_time() < deadline) {
            GstMessage *m = gst_bus_timed_pop_filtered(bus, 100 * GST_MSECOND, GST_MESSAGE_ERROR | GST_MESSAGE_EOS);
            if (m) {
                if (GST_MESSAGE_TYPE(m) == GST_MESSAGE_ERROR) {
                    GError *e = NULL; gst_message_parse_error(m, &e, NULL); p->error = g_strdup(e->message); g_error_free(e);
                } else p->error = g_strdup("所选来源已关闭。");
                gst_message_unref(m);
            }
        }
        gst_object_unref(bus);
    }
    gst_element_set_state(pipeline, GST_STATE_NULL); gst_object_unref(pipeline);
    if (p->fd >= 0) { close(p->fd); p->fd = -1; }
    if (!p->error && (p->width < 2 || p->height < 2 || p->width > 32768 || p->height > 32768))
        p->error = g_strdup("未能取得有效的视频像素尺寸；来源可能已关闭或超时。");
    g_task_return_boolean(task, TRUE);
}
static void probe_done(GObject *object, GAsyncResult *result, gpointer data) {
    (void)object; Probe *p = data; g_task_propagate_boolean(G_TASK(result), NULL);
    p->callback(p->width, p->height, p->error, p->data); g_free(p->error); g_free(p);
}
void mc_gst_pipewire_dimensions(int fd, guint32 node, MCGstDimensions callback, gpointer data) {
    Probe *p = g_new0(Probe, 1); p->fd = fd < 0 ? -1 : fcntl(fd, F_DUPFD_CLOEXEC, 3);
    p->node = node; p->callback = callback; p->data = data;
    GTask *task = g_task_new(NULL, NULL, probe_done, p);
    g_task_set_task_data(task, p, NULL); g_task_run_in_thread(task, probe_worker); g_object_unref(task);
}

typedef struct {
    GMainLoop *loop; MCGstCapture *capture; gboolean success, started, correct_thread;
    GThread *thread; char *path;
} Smoke;
static gboolean smoke_stop(gpointer data) { Smoke *s = data; mc_gst_capture_stop(s->capture); return G_SOURCE_REMOVE; }
static void smoke_started(MCGstCapture *capture, gpointer data) {
    Smoke *s = data;
    s->correct_thread = s->correct_thread && g_thread_self() == s->thread && capture == s->capture;
    s->started = TRUE;
}
static void smoke_done(MCGstCapture *capture, gboolean success, const char *path, const char *error, gpointer data) {
    Smoke *s = data;
    s->correct_thread = s->correct_thread && g_thread_self() == s->thread && capture == s->capture;
    s->capture = NULL; s->success = success; s->path = g_strdup(path);
    if (error) g_printerr("Recording fixture: %s (%s)\n", error, path);
    g_main_loop_quit(s->loop);
}
typedef struct { int frames; gboolean dimensions; } Decode;
static void decoded_pad(GstElement *demux, GstPad *pad, gpointer data) {
    (void)demux; GstElement *decoder = data;
    GstPad *sink = gst_element_get_static_pad(decoder, "sink");
    if (!gst_pad_is_linked(sink)) gst_pad_link(pad, sink);
    gst_object_unref(sink);
}
static void decoded_frame(GstElement *sink, GstBuffer *buffer, GstPad *pad, gpointer data) {
    (void)sink; Decode *d = data; GstCaps *caps = gst_pad_get_current_caps(pad);
    int width = 0, height = 0;
    if (caps) {
        const GstStructure *s = gst_caps_get_structure(caps, 0);
        d->dimensions = gst_structure_get_int(s, "width", &width) && gst_structure_get_int(s, "height", &height) &&
            width == 160 && height == 120 && gst_buffer_get_size(buffer) >= 160 * 120;
        gst_caps_unref(caps);
    }
    g_atomic_int_inc(&d->frames);
}
static gboolean smoke_decode(const char *path) {
    GstElement *pipeline = gst_pipeline_new(NULL), *file = gst_element_factory_make("filesrc", NULL),
        *demux = gst_element_factory_make("matroskademux", NULL), *decoder = gst_element_factory_make("vp8dec", NULL),
        *sink = gst_element_factory_make("fakesink", NULL);
    GstElement *all[] = {file, demux, decoder, sink};
    gboolean valid = TRUE;
    for (guint i = 0; i < G_N_ELEMENTS(all); i++) {
        if (all[i]) gst_bin_add(GST_BIN(pipeline), all[i]); else valid = FALSE;
    }
    Decode decoded = {0, FALSE};
    if (valid) {
        g_object_set(file, "location", path, NULL);
        g_object_set(sink, "signal-handoffs", TRUE, "sync", FALSE, NULL);
        g_signal_connect(demux, "pad-added", G_CALLBACK(decoded_pad), decoder);
        g_signal_connect(sink, "handoff", G_CALLBACK(decoded_frame), &decoded);
        valid = gst_element_link(file, demux) && gst_element_link(decoder, sink) &&
            gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE;
    }
    if (valid) {
        GstBus *bus = gst_element_get_bus(pipeline);
        GstMessage *message = gst_bus_timed_pop_filtered(bus, 10 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
        valid = message && GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS;
        if (message) gst_message_unref(message);
        gst_object_unref(bus);
    }
    gst_element_set_state(pipeline, GST_STATE_NULL); gst_object_unref(pipeline);
    return valid && g_atomic_int_get(&decoded.frames) > 0 && decoded.dimensions;
}
gboolean mc_gst_capture_smoke(const char *directory) {
    GError *error = NULL;
    if (!mc_gst_capture_available(MC_GST_X11, &error)) { g_printerr("%s\n", error->message); g_clear_error(&error); return FALSE; }
    gboolean passed = TRUE;
    const char *folders[] = {"x11-region", "test-pattern", "publish-conflict", "stream-error"};
    for (int fixture = 0; fixture < 4; fixture++) {
        char *folder = g_build_filename(directory, folders[fixture], NULL);
        g_mkdir_with_parents(folder, 0700);
        char *target = g_build_filename(folder, "source.webm", NULL);
        if (fixture == 2) passed = g_file_set_contents(target, "existing original", -1, NULL) && passed;
        MCGstCaptureInput input = {MC_GST_X11, 10, 20, 160, 120, 160, 120, 15, -1, 0};
        Smoke s = {g_main_loop_new(NULL, FALSE), NULL, FALSE, FALSE, TRUE, g_thread_self(), NULL};
        s.capture = start(&input, folder, smoke_started, smoke_done, &s, fixture, &error);
        if (s.capture) { guint timer = g_timeout_add(1000, smoke_stop, &s); g_main_loop_run(s.loop);
            if (g_main_context_find_source_by_id(NULL, timer)) g_source_remove(timer); }
        else { g_printerr("Recording fixture setup: %s\n", error->message); g_clear_error(&error); }
        passed = s.correct_thread && passed;
        if (fixture < 2) passed = s.success && s.started && smoke_decode(s.path) && passed;
        else if (fixture == 2) {
            char *original = NULL; g_file_get_contents(target, &original, NULL, NULL);
            passed = !s.success && s.path && smoke_decode(s.path) &&
                g_strcmp0(original, "existing original") == 0 && passed; g_free(original);
        } else {
            GStatBuf stat;
            passed = !s.success && s.path && g_stat(s.path, &stat) == 0 &&
                !g_file_test(target, G_FILE_TEST_EXISTS) && passed;
        }
        g_free(target); g_free(s.path); g_main_loop_unref(s.loop); g_free(folder);
    }
    return passed;
}
