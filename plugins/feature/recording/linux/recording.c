#include "recording.h"
#include "bindings/c/recording_flow.h"
#include "bindings/c/recording_plan.h"
#include "plugins/feature/select/linux/selection.h"
#include "platform/linux/recording/gstreamer_capture.h"
#include <gdk/gdkx.h>
#include <libportal/portal.h>
#include <libportal/remote.h>
#include <glib/gstdio.h>
#include <X11/Xlib.h>
#include <math.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

typedef struct {
    int handle;
    guint timer, pending;
    GtkWidget *selection, *panel, *canvas;
    GdkPixbuf *desktop;
    MCSelectionDrag drag;
    MCSelectionRect region;
    gboolean dragging, attempted_region, quiet, notify_completed, releasing;
    const char *selection_hint;
    int logical_width, logical_height, pixel_width, pixel_height, fd;
    MCGstCaptureInput input;
    MCGstCapture *media;
    XdpPortal *portal;
    XdpSession *session;
    GCancellable *cancellable;
    char *directory, *path, *error;
    const char *fixture_base; /* borrowed only by synchronous opt-in smoke */
} Recording;
/* pending owns the recorder across callbacks. No new flow can begin until all
 * callbacks and owned resources from this flow have drained. */
typedef struct { Recording *recording; int handle; XdpSession *session; } Pending;
static Recording *active;
static GtkApplication *application;
static MCLinuxRecordingChanged changed;
static gpointer changed_data;
static MCLinuxRecordingCompleted completed;
static gpointer completed_data;
void mc_linux_recording_set_completed(MCLinuxRecordingCompleted callback, gpointer data) {
    completed = callback; completed_data = data;
}
static void dispatch(Recording *r, int event);
static void drain(Recording *r);
static double now_ms(void) { return g_get_monotonic_time() / 1000.0; }
static int phase(Recording *r) { return recording_flow_value(r->handle, MC_RECORDING_PHASE); }
static gboolean current(Pending *p) { return active == p->recording && p->handle == p->recording->handle; }
static Pending *pending_new(Recording *r) {
    Pending *p = g_new0(Pending, 1); p->recording = r; p->handle = r->handle; r->pending++; return p;
}
static void pending_end(Pending *p) {
    p->recording->pending--; g_clear_object(&p->session); g_free(p);
}
static char *core_text(Recording *r) {
    moonbit_string_t value = recording_ui_text(r->handle);
    char *text = g_utf16_to_utf8((const gunichar2 *)value, Moonbit_array_length(value), NULL, NULL, NULL);
    moonbit_decref(value); return text ? text : g_strdup("");
}
static void notify(Recording *r) {
    if (!changed) return;
    int p = phase(r);
    char *timer = core_text(r);
    char *text = p == MC_RECORDING_ACTIVE ? g_strdup_printf("录屏中 %s · 静音 · 从托盘停止", timer) :
        g_strdup(p == MC_RECORDING_SELECTING ? "选择录屏来源…" :
            p == MC_RECORDING_COUNTDOWN ? "录屏倒计时 · 可取消" :
            p == MC_RECORDING_STARTING ? "正在启动录屏…" : "正在保存原片…");
    changed(TRUE, recording_flow_value(r->handle, MC_RECORDING_CAN_STOP) ||
        recording_flow_value(r->handle, MC_RECORDING_CAN_CANCEL), text, changed_data);
    g_free(text); g_free(timer);
}
static void destroy_window(GtkWidget **window) {
    if (*window) { GtkWidget *old = *window; *window = NULL; gtk_widget_destroy(old); }
}
static void close_source(Recording *r) {
    destroy_window(&r->selection);
    g_clear_object(&r->desktop);
    if (r->cancellable) g_cancellable_cancel(r->cancellable);
    if (r->session) {
        /* Close is a local portal request, not an acknowledgement that the
         * compositor has already destroyed its remote objects. */
        g_signal_handlers_disconnect_by_data(r->session, r);
        xdp_session_close(r->session); g_clear_object(&r->session);
    }
    if (r->fd >= 0) { close(r->fd); r->fd = -1; }
}
static void dialog_response(GtkDialog *dialog, int response, gpointer data) {
    (void)response; (void)data; gtk_widget_destroy(GTK_WIDGET(dialog));
}
static void report(const char *title, const char *detail, gboolean error) {
    GtkWidget *dialog = gtk_message_dialog_new(NULL, 0, error ? GTK_MESSAGE_ERROR : GTK_MESSAGE_INFO,
        GTK_BUTTONS_CLOSE, "%s", title);
    gtk_window_set_title(GTK_WINDOW(dialog), "Mooji Cut");
    gtk_window_set_application(GTK_WINDOW(dialog), application);
    gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog), "%s", detail);
    g_signal_connect(dialog, "response", G_CALLBACK(dialog_response), NULL);
    gtk_widget_show(dialog);
}
static void finish(Recording *r) {
    int result = recording_flow_event(r->handle, r->error ? MC_RECORDING_FAIL : MC_RECORDING_COMPLETE, now_ms());
    if (recording_flow_value(r->handle, MC_RECORDING_BUSY)) return;
    if (r->timer) g_source_remove(r->timer);
    destroy_window(&r->panel); r->canvas = NULL;
    if (changed) changed(FALSE, FALSE, r->error ? "录屏失败，已写出的原片保留。" :
        result == MC_RECORDING_DELIVER_MEDIA ? "录屏已保存（静音 WebM）。" : "已取消录屏。", changed_data);
    // Shutdown silences windows, but a successfully finalized production
    // recording must still reach the app so it can persist its recent paths.
    // Isolated smoke recordings opt out at creation, independently of quiet.
    if (r->notify_completed && !r->error && result == MC_RECORDING_DELIVER_MEDIA && completed) {
        completed(r->path, r->directory, completed_data);
    } else if (!r->quiet && (r->error || result == MC_RECORDING_DELIVER_MEDIA)) {
        char *detail = r->error ? g_strdup_printf("%s%s%s", r->error,
            r->path ? "\n已保留原片：\n" : "", r->path ? r->path : "") :
            g_strdup(r->path);
        report(r->error ? "录屏未完成" : "录屏已保存", detail, r->error != NULL); g_free(detail);
    }
    recording_flow_close(r->handle); active = NULL;
    g_clear_object(&r->portal); g_clear_object(&r->cancellable);
    g_free(r->directory); g_free(r->path); g_free(r->error); g_free(r);
    g_application_release(G_APPLICATION(application));
}
static void drain(Recording *r) {
    if (r->media) { mc_gst_capture_stop(r->media); return; }
    close_source(r);
    if (!r->pending) finish(r);
}
static void failure(Recording *r, const char *message) {
    if (!r->error) r->error = g_strdup(message);
    r->releasing = TRUE;
    if (phase(r) != MC_RECORDING_STOPPING) recording_flow_event(r->handle, MC_RECORDING_STOP, now_ms());
    drain(r);
}
static void selected(Recording *r, int width, int height) {
    MCCoreRecordingPlan plan = mc_core_recording_plan(r->input.kind == MC_GST_X11 ?
        MC_RECORDING_LINUX_X11 : MC_RECORDING_LINUX_WAYLAND, width, height, 0);
    if (!plan.width || !plan.height || plan.system_audio || plan.microphone) {
        failure(r, "当前来源不符合静音录屏编码计划。"); return;
    }
    r->input.width = width; r->input.height = height;
    r->input.output_width = plan.width; r->input.output_height = plan.height;
    r->input.frames_per_second = plan.frames_per_second;
    dispatch(r, MC_RECORDING_SELECTED);
}
static gboolean panel_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
    Recording *r = data;
    double *f = recording_ui_frame(r->handle, gtk_widget_get_allocated_width(widget), gtk_widget_get_allocated_height(widget));
    GtkStyleContext *style = gtk_widget_get_style_context(widget);
    gtk_render_background(style, cr, f[0], f[1], f[2], f[3]);
    GdkRGBA color; gtk_style_context_get_color(style, GTK_STATE_FLAG_NORMAL, &color);
    gdk_cairo_set_source_rgba(cr, &color);
    char *text = core_text(r);
    PangoLayout *layout = gtk_widget_create_pango_layout(widget, text);
    PangoFontDescription *font = pango_font_description_new();
    pango_font_description_set_family(font, "monospace"); pango_font_description_set_absolute_size(font, f[12] * PANGO_SCALE);
    pango_layout_set_font_description(layout, font);
    int w, h; pango_layout_get_pixel_size(layout, &w, &h);
    cairo_move_to(cr, f[4] + (f[6] - w) / 2, f[5] + (f[7] - h) / 2); pango_cairo_show_layout(cr, layout);
    if (f[13] == MC_RECORDING_CANCEL) {
        cairo_set_line_width(cr, 2); cairo_move_to(cr, f[8] + 10, f[9] + 10); cairo_line_to(cr, f[8] + 22, f[9] + 22);
        cairo_move_to(cr, f[8] + 22, f[9] + 10); cairo_line_to(cr, f[8] + 10, f[9] + 22); cairo_stroke(cr);
    } else if (f[13] == MC_RECORDING_STOP) { cairo_rectangle(cr, f[8] + 10, f[9] + 10, 12, 12); cairo_fill(cr); }
    pango_font_description_free(font); g_object_unref(layout); g_free(text); moonbit_decref(f); return TRUE;
}
static gboolean panel_press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
    Recording *r = data;
    int action = recording_ui_hit(r->handle, event->x, event->y,
        gtk_widget_get_allocated_width(widget), gtk_widget_get_allocated_height(widget));
    if (event->button == 1 && action) dispatch(r, action);
    return TRUE;
}
static gboolean cancel_window(GtkWidget *widget, GdkEvent *event, gpointer data) {
    (void)widget; (void)event; dispatch(data, MC_RECORDING_STOP); return TRUE;
}
static gboolean panel_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
    (void)widget;
    if (event->keyval == GDK_KEY_Escape) { dispatch(data, MC_RECORDING_STOP); return TRUE; }
    return FALSE;
}
static void show_panel(Recording *r) {
    if (!r->panel) {
        r->panel = gtk_application_window_new(application);
        gtk_window_set_title(GTK_WINDOW(r->panel), "录屏 · 从托盘停止");
        gtk_window_set_default_size(GTK_WINDOW(r->panel), 216, 192);
        gtk_window_set_resizable(GTK_WINDOW(r->panel), FALSE);
        gtk_window_set_keep_above(GTK_WINDOW(r->panel), TRUE);
        gtk_window_set_position(GTK_WINDOW(r->panel), GTK_WIN_POS_CENTER);
        r->canvas = gtk_drawing_area_new(); gtk_container_add(GTK_CONTAINER(r->panel), r->canvas);
        gtk_widget_add_events(r->canvas, GDK_BUTTON_PRESS_MASK);
        gtk_widget_set_tooltip_text(r->canvas, "取消倒计时；开始后请从托盘菜单停止录屏。");
        g_signal_connect(r->canvas, "draw", G_CALLBACK(panel_draw), r);
        g_signal_connect(r->canvas, "button-press-event", G_CALLBACK(panel_press), r);
        g_signal_connect(r->panel, "delete-event", G_CALLBACK(cancel_window), r);
        g_signal_connect(r->panel, "key-press-event", G_CALLBACK(panel_key), r);
    }
    if (!gtk_widget_get_visible(r->panel)) {
        gtk_widget_show_all(r->panel); gtk_window_present(GTK_WINDOW(r->panel));
    }
}
static MCSelectionPoint selection_point(Recording *r, double x, double y) {
    /* X11 uses one root scale. Independent x/y conversion also tolerates a
     * root pixbuf with logical dimensions different from its physical pixels. */
    MCSelectionViewport viewport = {0, 0, 1, r->pixel_width, r->pixel_height};
    return mc_selection_from_surface((MCSelectionPoint){x * r->pixel_width / r->logical_width,
        y * r->pixel_height / r->logical_height}, viewport);
}
static gboolean selection_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
    (void)widget; Recording *r = data;
    if (r->desktop) {
        cairo_save(cr); cairo_scale(cr, (double)r->logical_width / gdk_pixbuf_get_width(r->desktop),
            (double)r->logical_height / gdk_pixbuf_get_height(r->desktop));
        gdk_cairo_set_source_pixbuf(cr, r->desktop, 0, 0); cairo_paint(cr); cairo_restore(cr);
    }
    cairo_set_source_rgba(cr, 0, 0, 0, .35); cairo_paint(cr);
    MCSelectionRect v = r->region;
    cairo_set_source_rgb(cr, 1, 1, 1); cairo_set_line_width(cr, 2);
    cairo_rectangle(cr, v.x * r->logical_width / r->pixel_width, v.y * r->logical_height / r->pixel_height,
        v.width * r->logical_width / r->pixel_width, v.height * r->logical_height / r->pixel_height); cairo_stroke(cr);
    PangoLayout *text = gtk_widget_create_pango_layout(widget, r->selection_hint ? r->selection_hint :
        "拖选区域，Enter 确认；直接 Enter 录制整个屏幕，Esc 取消。\n静音录制 · 开始后从托盘菜单停止");
    cairo_move_to(cr, 24, 24); pango_cairo_show_layout(cr, text); g_object_unref(text); return TRUE;
}
static gboolean selection_press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
    (void)widget; Recording *r = data;
    if (event->button != 1) return TRUE;
    r->dragging = TRUE; r->attempted_region = TRUE; r->selection_hint = NULL; r->region = (MCSelectionRect){0};
    mc_selection_begin(&r->drag, selection_point(r, event->x, event->y), r->region, -1); return TRUE;
}
static gboolean selection_motion(GtkWidget *widget, GdkEventMotion *event, gpointer data) {
    Recording *r = data;
    if (r->dragging) {
        mc_selection_update(&r->drag, selection_point(r, event->x, event->y));
        r->region = mc_selection_region(&r->drag); gtk_widget_queue_draw(widget);
    }
    return TRUE;
}
static gboolean selection_release(GtkWidget *widget, GdkEventButton *event, gpointer data) {
    Recording *r = data;
    if (event->button == 1 && r->dragging) {
        mc_selection_update(&r->drag, selection_point(r, event->x, event->y)); r->region = mc_selection_region(&r->drag);
        r->dragging = FALSE; gtk_widget_queue_draw(widget);
    }
    return TRUE;
}
static gboolean selection_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
    (void)widget; Recording *r = data;
    if (event->keyval == GDK_KEY_Escape) { dispatch(r, MC_RECORDING_CANCEL); return TRUE; }
    if (event->keyval != GDK_KEY_Return && event->keyval != GDK_KEY_KP_Enter) return FALSE;
    if (r->dragging) return TRUE;
    MCSelectionRect v = r->region;
    if (v.width < 2 || v.height < 2) {
        if (r->attempted_region) {
            r->selection_hint = "选区太小，请重新拖选；Enter 确认，Esc 取消。";
            gtk_widget_queue_draw(r->selection); return TRUE;
        }
        v = (MCSelectionRect){0, 0, r->pixel_width, r->pixel_height};
    }
    int x = (int)floor(v.x), y = (int)floor(v.y);
    int right = MIN(r->pixel_width, (int)ceil(v.x + v.width));
    int bottom = MIN(r->pixel_height, (int)ceil(v.y + v.height));
    r->input.x = x; r->input.y = y;
    destroy_window(&r->selection); g_clear_object(&r->desktop);
    selected(r, right - x, bottom - y); return TRUE;
}
static gboolean x11_source(Recording *r) {
    GdkWindow *root = gdk_get_default_root_window();
    Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
    XWindowAttributes attrs;
    if (!root || !XGetWindowAttributes(display, DefaultRootWindow(display), &attrs)) return FALSE;
    r->pixel_width = attrs.width; r->pixel_height = attrs.height;
    r->logical_width = gdk_window_get_width(root); r->logical_height = gdk_window_get_height(root);
    if (r->logical_width < 2 || r->logical_height < 2) return FALSE;
    r->desktop = gdk_pixbuf_get_from_window(root, 0, 0, r->logical_width, r->logical_height);
    if (!r->desktop) return FALSE;
    r->selection = gtk_application_window_new(application);
    gtk_window_set_title(GTK_WINDOW(r->selection), "选择录屏区域");
    gtk_window_set_decorated(GTK_WINDOW(r->selection), FALSE);
    gtk_window_set_keep_above(GTK_WINDOW(r->selection), TRUE);
    gtk_window_set_skip_taskbar_hint(GTK_WINDOW(r->selection), TRUE);
    gtk_window_move(GTK_WINDOW(r->selection), 0, 0);
    gtk_window_set_default_size(GTK_WINDOW(r->selection), r->logical_width, r->logical_height);
    GtkWidget *area = gtk_drawing_area_new(); gtk_container_add(GTK_CONTAINER(r->selection), area);
    gtk_widget_add_events(area, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK | GDK_POINTER_MOTION_MASK);
    g_signal_connect(area, "draw", G_CALLBACK(selection_draw), r);
    g_signal_connect(area, "button-press-event", G_CALLBACK(selection_press), r);
    g_signal_connect(area, "button-release-event", G_CALLBACK(selection_release), r);
    g_signal_connect(area, "motion-notify-event", G_CALLBACK(selection_motion), r);
    g_signal_connect(r->selection, "key-press-event", G_CALLBACK(selection_key), r);
    g_signal_connect(r->selection, "delete-event", G_CALLBACK(cancel_window), r);
    gtk_widget_show_all(r->selection); gtk_window_present(GTK_WINDOW(r->selection)); return TRUE;
}
static void session_closed(XdpSession *session, gpointer data) {
    (void)session; Recording *r = data;
    if (active != r || r->releasing) return;
    failure(r, "系统已关闭录屏来源；已写出的原片仍会保留。");
}
static void dimensions_done(int width, int height, const char *error, gpointer data) {
    Pending *p = data; Recording *r = p->recording; gboolean live = current(p); pending_end(p);
    if (!live || r->releasing) { drain(r); return; }
    if (error) { failure(r, error); return; }
    selected(r, width, height);
}
static void fd_worker(GTask *task, gpointer object, gpointer task_data, GCancellable *cancel) {
    (void)object; (void)cancel; Pending *p = task_data;
    /* libportal 0.6's FD API blocks on D-Bus; never block GTK/core. */
    g_task_return_int(task, xdp_session_open_pipewire_remote(p->session));
}
static void fd_done(GObject *object, GAsyncResult *result, gpointer data) {
    (void)object; Pending *p = data; Recording *r = p->recording;
    int fd = g_task_propagate_int(G_TASK(result), NULL); gboolean live = current(p); pending_end(p);
    if (!live || r->releasing) { if (fd >= 0) close(fd); drain(r); return; }
    if (fd < 0) { failure(r, "无法打开系统授权的 PipeWire 视频流。"); return; }
    r->fd = fd; r->input.pipewire_fd = fd;
    /* Probe is fully stopped before its callback; only then can SELECTED start
     * the countdown. No probe callback can race a new capture pipeline. */
    mc_gst_pipewire_dimensions(fd, r->input.pipewire_node, dimensions_done, pending_new(r));
}
static void session_started(GObject *object, GAsyncResult *result, gpointer data) {
    Pending *p = data; Recording *r = p->recording; GError *error = NULL;
    gboolean ok = xdp_session_start_finish(XDP_SESSION(object), result, &error);
    gboolean live = current(p); pending_end(p);
    if (!live || r->releasing) { g_clear_error(&error); drain(r); return; }
    if (!ok) {
        gboolean cancelled = g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
        char *message = g_strdup(error ? error->message : "系统未授权录屏来源。"); g_clear_error(&error);
        if (cancelled) dispatch(r, MC_RECORDING_CANCEL); else failure(r, message);
        g_free(message); return;
    }
    GVariant *streams = xdp_session_get_streams(r->session);
    if (!streams || !g_variant_is_of_type(streams, G_VARIANT_TYPE("a(ua{sv})")) || g_variant_n_children(streams) != 1) {
        failure(r, "当前只支持一个系统显示器或窗口来源。"); return;
    }
    GVariant *properties = NULL;
    g_variant_get_child(streams, 0, "(u@a{sv})", &r->input.pipewire_node, &properties); g_variant_unref(properties);
    if (!r->input.pipewire_node) { failure(r, "系统返回了无效的视频流。"); return; }
    Pending *next = pending_new(r); next->session = g_object_ref(r->session);
    GTask *task = g_task_new(NULL, NULL, fd_done, next);
    g_task_set_task_data(task, next, NULL); g_task_run_in_thread(task, fd_worker); g_object_unref(task);
}
static void session_created(GObject *object, GAsyncResult *result, gpointer data) {
    Pending *p = data; Recording *r = p->recording; GError *error = NULL;
    XdpSession *session = xdp_portal_create_screencast_session_finish(XDP_PORTAL(object), result, &error);
    gboolean live = current(p); pending_end(p);
    if (!live || r->releasing) {
        if (session) { xdp_session_close(session); g_object_unref(session); }
        g_clear_error(&error); drain(r); return;
    }
    if (!session) {
        gboolean cancelled = g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
        char *message = g_strdup(error ? error->message : "无法创建 ScreenCast 系统来源。"); g_clear_error(&error);
        if (cancelled) dispatch(r, MC_RECORDING_CANCEL); else failure(r, message);
        g_free(message); return;
    }
    r->session = session;
    g_signal_connect(session, "closed", G_CALLBACK(session_closed), r);
    xdp_session_start(session, NULL, r->cancellable, session_started, pending_new(r));
}
static void request_source(Recording *r) {
    GError *error = NULL;
    if (!mc_gst_capture_available(r->input.kind, &error)) {
        char *message = g_strdup(error->message); g_clear_error(&error); failure(r, message); g_free(message); return;
    }
    if (r->input.kind == MC_GST_X11) {
        if (!x11_source(r)) failure(r, "无法读取 X11 屏幕或打开区域选择。");
    } else {
        r->portal = xdp_portal_new(); r->cancellable = g_cancellable_new();
        /* Single source, no persisted permission, universally supported hidden
         * cursor mode. ScreenCast is distinct from the Screenshot portal. */
        xdp_portal_create_screencast_session(r->portal, XDP_OUTPUT_MONITOR | XDP_OUTPUT_WINDOW,
            XDP_SCREENCAST_FLAG_NONE, XDP_CURSOR_MODE_HIDDEN, XDP_PERSIST_MODE_NONE, NULL,
            r->cancellable, session_created, pending_new(r));
    }
}
static void media_started(MCGstCapture *media, gpointer data) {
    Recording *r = data;
    if (active == r && r->media == media && !r->releasing) dispatch(r, MC_RECORDING_STARTED);
}
static void media_finished(MCGstCapture *media, gboolean success, const char *path, const char *error, gpointer data) {
    Recording *r = data;
    if (r->media != media) return;
    r->media = NULL; g_free(r->path); r->path = g_strdup(path);
    if (!success && !r->error) r->error = g_strdup(error ? error : "录屏未能完成；原片已保留。");
    r->releasing = TRUE;
    if (phase(r) != MC_RECORDING_STOPPING) recording_flow_event(r->handle, MC_RECORDING_STOP, now_ms());
    drain(r);
}
static void start_media(Recording *r) {
    if (r->input.kind == MC_GST_X11) {
        Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
        XWindowAttributes attrs; GdkWindow *root = gdk_get_default_root_window();
        if (!XGetWindowAttributes(display, DefaultRootWindow(display), &attrs) ||
            attrs.width != r->pixel_width || attrs.height != r->pixel_height ||
            gdk_window_get_width(root) != r->logical_width || gdk_window_get_height(root) != r->logical_height) {
            failure(r, "屏幕尺寸或缩放已改变，请重新选择录屏区域。"); return;
        }
    }
    /* There is no per-window exclusion in ximagesrc or a generic portal stream.
     * Hide our countdown before creating the pipeline; tray/CLI remain usable. */
    if (r->panel) gtk_widget_hide(r->panel);
    gdk_display_sync(gdk_display_get_default());
    const char *videos = g_get_user_special_dir(G_USER_DIRECTORY_VIDEOS);
    char *base = r->fixture_base ? g_strdup(r->fixture_base) :
        g_build_filename(videos ? videos : g_get_user_data_dir(), "Mooji Cut", NULL);
    if (g_mkdir_with_parents(base, 0700) != 0) { g_free(base); failure(r, "无法创建录屏保存目录。"); return; }
    r->directory = g_build_filename(base, "recording-XXXXXX", NULL); g_free(base);
    if (!g_mkdtemp(r->directory)) { failure(r, "无法创建本次录屏的独立保存目录。"); return; }
    GError *error = NULL;
    r->media = mc_gst_capture_start(&r->input, r->directory, media_started, media_finished, r, &error);
    if (!r->media) {
        char *message = g_strdup(error ? error->message : "无法开始录屏。"); g_clear_error(&error);
        char *partial = g_build_filename(r->directory, "source.partial.webm", NULL);
        if (g_file_test(partial, G_FILE_TEST_EXISTS)) r->path = g_strdup(partial);
        g_free(partial); failure(r, message); g_free(message);
    }
}
static void dispatch(Recording *r, int event) {
    int effect = recording_flow_event(r->handle, event, now_ms());
    if (effect == MC_RECORDING_REJECTED) return;
    notify(r);
    switch (effect) {
        case MC_RECORDING_REQUEST_SOURCE: request_source(r); return;
        case MC_RECORDING_START_MEDIA: start_media(r); return;
        case MC_RECORDING_STOP_MEDIA:
        case MC_RECORDING_RELEASE_SOURCE: r->releasing = TRUE; drain(r); return;
        default: break;
    }
    if (phase(r) == MC_RECORDING_COUNTDOWN) show_panel(r);
    if (r->canvas) gtk_widget_queue_draw(r->canvas);
}
static gboolean tick(gpointer data) {
    Recording *r = data; int handle = r->handle;
    dispatch(r, MC_RECORDING_TICK);
    return active && active->handle == handle ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
}
void mc_linux_recording_init(GtkApplication *app, MCLinuxRecordingChanged callback, gpointer data) {
    application = app; changed = callback; changed_data = data;
}
gboolean mc_linux_recording_busy(void) { return active != NULL; }
static void begin_recording(gboolean quiet) {
    if (!application || active) return;
    Recording *r = g_new0(Recording, 1); r->fd = -1; r->quiet = quiet;
    r->notify_completed = !quiet; r->handle = recording_flow_open();
    if (r->handle <= 0) { g_free(r); report("无法开始录屏", "无法创建录屏会话。", TRUE); return; }
    r->input.kind = GDK_IS_X11_DISPLAY(gdk_display_get_default()) ? MC_GST_X11 : MC_GST_PIPEWIRE;
    r->input.pipewire_fd = -1; active = r;
    g_application_hold(G_APPLICATION(application));
    r->timer = g_timeout_add(100, tick, r); dispatch(r, MC_RECORDING_BEGIN);
}
void mc_linux_recording_start(void) { begin_recording(FALSE); }
void mc_linux_recording_stop(void) { if (active) dispatch(active, MC_RECORDING_STOP); }
void mc_linux_recording_shutdown(void) { if (active) { active->quiet = TRUE; mc_linux_recording_stop(); } }
typedef struct { GMainLoop *loop; gint64 deadline; gboolean timed_out, observed_active, shutdown; char *path; } FlowSmoke;
typedef struct { unsigned calls; gboolean finalized; char *source, *directory; } CompletionSmoke;
static void smoke_completed(const char *source, const char *directory, gpointer data) {
    CompletionSmoke *s = data; s->calls++;
    g_free(s->source); g_free(s->directory);
    s->source = g_strdup(source); s->directory = g_strdup(directory);
    s->finalized = active && !active->media && !active->pending &&
        g_file_test(source, G_FILE_TEST_IS_REGULAR);
}
static gboolean flow_smoke_poll(gpointer data) {
    FlowSmoke *s = data;
    if (!active) { g_main_loop_quit(s->loop); return G_SOURCE_REMOVE; }
    if (active->directory && !s->path) s->path = g_build_filename(active->directory, "source.webm", NULL);
    if (phase(active) == MC_RECORDING_ACTIVE) {
        s->observed_active = TRUE;
        if (recording_flow_value(active->handle, MC_RECORDING_ELAPSED_MS) >= 400) {
            if (s->shutdown) mc_linux_recording_shutdown();
            else mc_linux_recording_stop();
        }
    }
    if (!s->timed_out && g_get_monotonic_time() > s->deadline) {
        s->timed_out = TRUE; mc_linux_recording_shutdown();
    }
    return G_SOURCE_CONTINUE;
}
static gboolean smoke_select_region(void) {
    if (!active || !active->selection) return FALSE;
    active->quiet = TRUE; active->attempted_region = TRUE;
    active->region = (MCSelectionRect){10, 20, 160, 120};
    GdkEventKey enter = {0}; enter.keyval = GDK_KEY_Return;
    selection_key(active->selection, &enter, active);
    return active && phase(active) == MC_RECORDING_COUNTDOWN && !active->directory;
}
static gboolean smoke_pending_cancel(gboolean fd_delivery) {
    /* Simulate only the external completion boundary, not portal permission or
     * compositor success. The FD is real and must be closed on late delivery. */
    Recording *r = g_new0(Recording, 1); r->fd = -1; r->quiet = TRUE;
    r->notify_completed = TRUE; // production cancellation must not publish media
    r->handle = recording_flow_open(); r->input.kind = MC_GST_PIPEWIRE; active = r;
    g_application_hold(G_APPLICATION(application));
    int handle = r->handle;
    recording_flow_event(handle, MC_RECORDING_BEGIN, now_ms());
    Pending *p = pending_new(r);
    dispatch(r, MC_RECORDING_CANCEL);
    gboolean passed = active == r && phase(r) == MC_RECORDING_STOPPING;
    mc_linux_recording_start(); /* must not replace the draining generation */
    passed = active == r && active->handle == handle && passed;
    int fd = -1;
    if (fd_delivery) {
        int descriptors[2];
        if (pipe(descriptors) == 0) { fd = descriptors[0]; close(descriptors[1]); } else passed = FALSE;
        GTask *task = g_task_new(NULL, NULL, fd_done, p);
        g_task_return_int(task, fd); g_object_unref(task);
        while (active) g_main_context_iteration(NULL, TRUE);
        passed = fd >= 0 && fcntl(fd, F_GETFD) == -1 && errno == EBADF && passed;
    } else dimensions_done(1920, 1080, NULL, p);
    return !active && recording_flow_event(handle, MC_RECORDING_SELECTED, now_ms()) == MC_RECORDING_REJECTED && passed;
}
gboolean mc_linux_recording_smoke(GtkApplication *app, const char *directory) {
    (void)app;
    MCLinuxRecordingCompleted saved_completed = completed; gpointer saved_data = completed_data;
    CompletionSmoke completion = {0}; mc_linux_recording_set_completed(smoke_completed, &completion);
    gboolean ok = mc_gst_capture_smoke(directory);
    /* Cancellation before source delivery is a real host lifetime path: no
     * output, no countdown, no surviving selection window or application hold. */
    begin_recording(TRUE);
    ok = active && phase(active) == MC_RECORDING_SELECTING && ok;
    if (active && active->selection) {
        active->quiet = TRUE;
        GdkEventButton press = {0}; press.button = 1; press.x = 20; press.y = 20;
        selection_press(active->selection, &press, active);
        selection_release(active->selection, &press, active);
        GdkEventKey enter = {0}; enter.keyval = GDK_KEY_Return;
        selection_key(active->selection, &enter, active);
        ok = active && phase(active) == MC_RECORDING_SELECTING && active->selection &&
            !active->input.width && active->selection_hint && ok;
    }
    if (active) { active->quiet = TRUE; mc_linux_recording_stop(); }
    ok = !active && ok;
    begin_recording(TRUE);
    ok = smoke_select_region() && ok;
    mc_linux_recording_stop();
    ok = !active && ok;
    /* Exercise the production selection -> actual deadline -> first buffer ->
     * stop -> EOS/NULL -> save route, in a temporary fixture directory. */
    for (unsigned production = 0; production < 2; production++) {
        begin_recording(!production);
        if (active) active->fixture_base = directory;
        if (smoke_select_region()) {
            FlowSmoke flow = {g_main_loop_new(NULL, FALSE), g_get_monotonic_time() + 30 * G_TIME_SPAN_SECOND,
                FALSE, FALSE, production != 0, NULL};
            g_timeout_add(50, flow_smoke_poll, &flow); g_main_loop_run(flow.loop);
            ok = !flow.timed_out && flow.observed_active && flow.path &&
                g_file_test(flow.path, G_FILE_TEST_IS_REGULAR) && completion.calls == production && ok;
            if (production) {
                char *parent = flow.path ? g_path_get_dirname(flow.path) : NULL;
                ok = completion.finalized && !g_strcmp0(completion.source, flow.path) &&
                    !g_strcmp0(completion.directory, parent) && ok;
                g_free(parent);
            }
            g_free(flow.path); g_main_loop_unref(flow.loop);
        } else { ok = FALSE; mc_linux_recording_shutdown(); }
    }
    // Even with notification enabled, a failed/cancelled flow is not a usable
    // recording and must never replace the application's recent successful one.
    begin_recording(TRUE);
    if (active) { active->notify_completed = TRUE; failure(active, "Expected recording smoke failure"); }
    else ok = FALSE;
    ok = !active && completion.calls == 1 && ok;
    ok = smoke_pending_cancel(TRUE) && smoke_pending_cancel(FALSE) && ok;
    ok = completion.calls == 1 && ok;
    mc_linux_recording_set_completed(saved_completed, saved_data);
    g_free(completion.source); g_free(completion.directory);
    g_print("Linux recording smoke %s: X11 region, decoded WebM, failure retention, small-region rejection, cancel/select/countdown/stop, late FD/probe, shutdown completion once, isolated smoke and failure never publish.\n", ok ? "passed" : "FAILED");
    return ok;
}
