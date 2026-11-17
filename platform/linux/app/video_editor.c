#include "video_editor.h"
#include "platform/shared/app/video_editor_host.h"
#include "platform/linux/graphics/shared_canvas.h"
#include <math.h>
#include <string.h>

typedef struct {
    GtkApplication *application;
    GtkWidget *window, *canvas, *error_dialog;
    GtkFileChooserNative *chooser;
    GtkSettings *settings;
    MCVideoEditorHost *host;
    char *source, *draft, *reported_error;
    guint timer;
    int32_t chooser_ticket;
    int phase;
    gboolean painting, rendering, dirty, close_requested, appearance_ready, destroyed;
    double width, height;
    uint64_t presentation_serial;
    int64_t video_pts;
    uint64_t video_generation, video_seek;
} EditorWindow;

static GSList *editors;
static void render(EditorWindow *editor);
static void close_editor(EditorWindow *editor);
static gboolean poll_editor(gpointer data);

static EditorWindow *get_editor(GtkWidget *window) {
    return window ? g_object_get_data(G_OBJECT(window), "moojicut-video-editor") : NULL;
}

static void appearance(EditorWindow *editor) {
    gboolean dark = FALSE;
    g_object_get(editor->settings, "gtk-application-prefer-dark-theme", &dark, NULL);
    const uint16_t light_text[] = {'l','i','g','h','t'}, dark_text[] = {'d','a','r','k'};
    MCCanvasInput input = {0}; input.type = MC_UI_INPUT_APPEARANCE;
    input.text = dark ? dark_text : light_text; input.text_length = dark ? 4 : 5;
    mc_video_editor_host_event(editor->host, &input);
    editor->appearance_ready = TRUE;
}

static void appearance_changed(GObject *settings, GParamSpec *property, gpointer data) {
    (void)settings; (void)property; EditorWindow *editor = data;
    editor->appearance_ready = FALSE;
    editor->dirty = TRUE;
}

static void on_input(void *context, GtkWidget *canvas, const MCCanvasInput *input) {
    (void)canvas; EditorWindow *editor = context;
    if (!editor->host) return;
    mc_video_editor_host_event(editor->host, input);
    editor->dirty = TRUE; render(editor);
}

static void on_resize(void *context, GtkWidget *canvas, double width, double height) {
    EditorWindow *editor = context; editor->canvas = canvas;
    editor->width = width; editor->height = height; editor->dirty = TRUE; render(editor);
}

static void on_canvas_destroyed(void *context, GtkWidget *canvas) {
    (void)canvas; EditorWindow *editor = context; editor->canvas = NULL;
}

static void paint_video(void *context, GtkWidget *canvas, cairo_t *target, const MCCanvasRect *bounds) {
    (void)canvas; EditorWindow *editor = context; editor->painting = TRUE;
    cairo_save(target);
    cairo_rectangle(target, bounds->x, bounds->y, bounds->width, bounds->height);
    cairo_clip(target); cairo_set_source_rgb(target, 0, 0, 0); cairo_paint(target);
    const MCMediaFrame *frame = mc_video_editor_host_video(editor->host);
    if (frame && frame->image.pixels && frame->image.width > 0 && frame->image.height > 0) {
        const MCGstFrame *image = &frame->image;
        double scale = fmin(bounds->width / image->width, bounds->height / image->height);
        cairo_surface_t *surface = cairo_image_surface_create_for_data(image->pixels,
            CAIRO_FORMAT_ARGB32, image->width, image->height, image->stride);
        if (cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS && scale > 0) {
            cairo_translate(target, bounds->x + (bounds->width - image->width * scale) / 2,
                bounds->y + (bounds->height - image->height * scale) / 2);
            cairo_scale(target, scale, scale); cairo_set_source_surface(target, surface, 0, 0);
            cairo_pattern_set_filter(cairo_get_source(target), CAIRO_FILTER_BILINEAR); cairo_paint(target);
        }
        cairo_surface_destroy(surface);
    }
    cairo_restore(target); editor->painting = FALSE;
}

static void render(EditorWindow *editor) {
    if (!editor->host || editor->destroyed || !editor->canvas || editor->painting || editor->rendering || !editor->dirty ||
        editor->width <= 0 || editor->height <= 0 ||
        mc_video_editor_host_phase(editor->host) != MC_VIDEO_HOST_OPEN) return;
    editor->rendering = TRUE;
    editor->dirty = FALSE;
    uint64_t serial = mc_video_editor_host_presentation_serial(editor->host);
    int32_t frame = mc_video_editor_host_frame(editor->host, editor->width, editor->height);
    if (!frame || !mc_linux_canvas_set_frame(editor->canvas, frame)) {
        if (frame) ui_frame_close(frame);
        editor->dirty = TRUE;
    }
    // ATK notifications/capture changes can synchronously dispatch input or
    // destroy the child. Do not erase dirty state set by those callbacks.
    if (editor->canvas) mc_linux_canvas_set_capture(editor->canvas,
        mc_video_editor_host_value(editor->host, MC_EDITOR_CAPTURE) == 1);
    editor->presentation_serial = serial;
    if (serial != mc_video_editor_host_presentation_serial(editor->host)) editor->dirty = TRUE;
    editor->rendering = FALSE;
}

static void chooser_response(GtkNativeDialog *dialog, int response, gpointer data) {
    EditorWindow *editor = data;
    char *path = response == GTK_RESPONSE_ACCEPT ?
        gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog)) : NULL;
    int32_t ticket = editor->chooser_ticket;
    editor->chooser = NULL; editor->chooser_ticket = 0;
    gtk_native_dialog_destroy(dialog); g_object_unref(dialog);
    mc_video_editor_host_choose(editor->host, ticket, path); g_free(path);
    editor->dirty = TRUE;
    if (editor->close_requested) close_editor(editor);
}

static void show_chooser(EditorWindow *editor, int32_t ticket) {
    editor->chooser = gtk_file_chooser_native_new("Save video", GTK_WINDOW(editor->window),
        GTK_FILE_CHOOSER_ACTION_SAVE, NULL, NULL);
    editor->chooser_ticket = ticket;
    gtk_file_chooser_set_do_overwrite_confirmation(GTK_FILE_CHOOSER(editor->chooser), TRUE);
    GDateTime *now = g_date_time_new_now_local();
    char *name = g_date_time_format(now, "moojicut-%Y%m%d-%H%M%S.mp4"); g_date_time_unref(now);
    gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(editor->chooser), name); g_free(name);
    GtkFileFilter *filter = gtk_file_filter_new(); gtk_file_filter_set_name(filter, "MP4 video");
    gtk_file_filter_add_pattern(filter, "*.mp4");
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(editor->chooser), filter);
    g_signal_connect(editor->chooser, "response", G_CALLBACK(chooser_response), editor);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(editor->chooser));
}

static void error_response(GtkDialog *dialog, int response, gpointer data) {
    EditorWindow *editor = data; editor->error_dialog = NULL;
    gtk_widget_destroy(GTK_WIDGET(dialog));
    if (response == GTK_RESPONSE_APPLY) {
        editor->close_requested = FALSE;
        g_clear_pointer(&editor->reported_error, g_free);
        mc_video_editor_host_retry(editor->host);
    } else close_editor(editor);
    editor->dirty = TRUE;
}

static void error_destroyed(GtkWidget *dialog, gpointer data) {
    EditorWindow *editor = data;
    if (editor->error_dialog == dialog) editor->error_dialog = NULL;
}

static void show_error(EditorWindow *editor, const char *message) {
    if (editor->destroyed || editor->error_dialog || !message || !*message ||
        !g_strcmp0(editor->reported_error, message)) return;
    g_free(editor->reported_error); editor->reported_error = g_strdup(message);
    editor->error_dialog = gtk_message_dialog_new(GTK_WINDOW(editor->window), GTK_DIALOG_DESTROY_WITH_PARENT,
        GTK_MESSAGE_ERROR, GTK_BUTTONS_NONE, "%s", message);
    gtk_dialog_add_buttons(GTK_DIALOG(editor->error_dialog), "Close editor", GTK_RESPONSE_CLOSE,
        "Retry", GTK_RESPONSE_APPLY, NULL);
    g_signal_connect(editor->error_dialog, "response", G_CALLBACK(error_response), editor);
    g_signal_connect(editor->error_dialog, "destroy", G_CALLBACK(error_destroyed), editor);
    gtk_widget_show(editor->error_dialog);
}

static void close_editor(EditorWindow *editor) {
    editor->close_requested = TRUE;
    if (editor->error_dialog) {
        GtkWidget *dialog = editor->error_dialog; editor->error_dialog = NULL;
        g_signal_handlers_disconnect_by_data(dialog, editor); gtk_widget_destroy(dialog);
    }
    if (editor->chooser) {
        GtkFileChooserNative *dialog = editor->chooser;
        g_signal_handlers_disconnect_by_data(dialog, editor);
        editor->chooser = NULL; editor->chooser_ticket = 0;
        gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(dialog)); g_object_unref(dialog);
    }
    // An export click already creates a shared chooser ticket before the next
    // timer presents its native dialog. Closing in that interval must ACK it as
    // well; otherwise the session correctly vetoes close and remains alive.
    int32_t ticket = mc_video_editor_host_chooser(editor->host);
    if (ticket) mc_video_editor_host_choose(editor->host, ticket, NULL);
    if (editor->canvas) mc_linux_canvas_cancel(editor->canvas);
    if (!mc_video_editor_host_request_close(editor->host, true)) editor->close_requested = FALSE;
    editor->dirty = TRUE;
}

static gboolean on_delete(GtkWidget *window, GdkEvent *event, gpointer data) {
    (void)window; (void)event; close_editor(data); return TRUE;
}

static void on_destroy(GtkWidget *window, gpointer data) {
    (void)window; EditorWindow *editor = data;
    editor->destroyed = TRUE;
    // A toolkit/application teardown can bypass delete-event. Keep the owned
    // window and callback context alive until asynchronous media/IO is closed.
    if (editor->host) close_editor(editor);
}

static gboolean poll_editor(gpointer data) {
    EditorWindow *editor = data;
    mc_video_editor_host_tick(editor->host);
    int phase = mc_video_editor_host_phase(editor->host);
    if (phase == MC_VIDEO_HOST_CLOSED && !editor->chooser) {
        if (!mc_video_editor_host_free(editor->host)) return G_SOURCE_CONTINUE;
        editor->host = NULL; editor->timer = 0;
        editors = g_slist_remove(editors, editor);
        g_object_set_data(G_OBJECT(editor->window), "moojicut-video-editor", NULL);
        // Destruction can deliver input cancellation. The native owner has
        // already closed; detach the child first while the context is alive.
        if (editor->canvas) gtk_widget_destroy(editor->canvas);
        gtk_widget_destroy(editor->window);
        g_signal_handlers_disconnect_by_data(editor->window, editor);
        g_signal_handlers_disconnect_by_data(editor->settings, editor);
        g_object_unref(editor->window); g_object_unref(editor->settings);
        g_application_release(G_APPLICATION(editor->application));
        g_object_unref(editor->application);
        g_free(editor->source); g_free(editor->draft); g_free(editor->reported_error); g_free(editor);
        return G_SOURCE_REMOVE;
    }
    if (phase == MC_VIDEO_HOST_OPEN && !editor->appearance_ready && !editor->destroyed) appearance(editor);
    if (phase != editor->phase ||
        mc_video_editor_host_presentation_serial(editor->host) != editor->presentation_serial) editor->dirty = TRUE;
    editor->phase = phase;
    // A SAVE failure can return OPEN entirely within this tick (without an
    // observed phase transition). The app must be able to withdraw its quit.
    if (editor->close_requested && phase == MC_VIDEO_HOST_OPEN) editor->close_requested = FALSE;
    const char *error = mc_video_editor_host_error(editor->host);
    if (error && *error) {
        if (g_strcmp0(error, editor->reported_error)) editor->dirty = TRUE;
        show_error(editor, error);
    }
    int32_t chooser = mc_video_editor_host_chooser(editor->host);
    if (chooser && !editor->chooser && !editor->close_requested && !editor->destroyed) show_chooser(editor, chooser);
    const MCMediaFrame *video = mc_video_editor_host_video(editor->host);
    int64_t pts = video ? video->image.pts_ns : -1;
    uint64_t generation = video ? video->plan_generation : 0, seek = video ? video->seek_token : 0;
    if (pts != editor->video_pts || generation != editor->video_generation || seek != editor->video_seek) {
        editor->video_pts = pts; editor->video_generation = generation; editor->video_seek = seek;
        if (editor->canvas) gtk_widget_queue_draw(editor->canvas);
    }
    render(editor); return G_SOURCE_CONTINUE;
}

GtkWidget *mc_linux_video_editor_open_test(GtkApplication *application, const char *source,
                                          const char *draft, gboolean silent) {
    if (!application || !source || !draft) return NULL;
    for (GSList *at = editors; at; at = at->next) {
        EditorWindow *existing = at->data;
        if (!g_strcmp0(existing->draft, draft)) {
            if (existing->destroyed) return NULL;
            gtk_window_present(GTK_WINDOW(existing->window)); return existing->window;
        }
    }
    char error[1024] = {0};
    MCVideoEditorHost *host = mc_video_editor_host_create(source, draft, silent != FALSE, error, sizeof error);
    if (!host) { g_warning("Cannot open video editor: %s", error); return NULL; }
    EditorWindow *editor = g_new0(EditorWindow, 1);
    editor->application = g_object_ref(application); editor->host = host; editor->source = g_strdup(source);
    editor->draft = g_strdup(draft); editor->dirty = TRUE; editor->video_pts = -1;
    editor->window = gtk_application_window_new(application);
    g_object_ref_sink(editor->window);
    editor->settings = g_object_ref(gtk_widget_get_settings(editor->window));
    g_signal_connect(editor->settings, "notify::gtk-application-prefer-dark-theme", G_CALLBACK(appearance_changed), editor);
    gtk_window_set_title(GTK_WINDOW(editor->window), "Mooji Cut");
    gtk_window_set_default_size(GTK_WINDOW(editor->window), 1040, 720);
    g_object_set_data(G_OBJECT(editor->window), "moojicut-video-editor", editor);
    g_signal_connect(editor->window, "delete-event", G_CALLBACK(on_delete), editor);
    g_signal_connect(editor->window, "destroy", G_CALLBACK(on_destroy), editor);
    const MCLinuxCanvasCallbacks callbacks = {on_input, on_resize, on_canvas_destroyed, paint_video};
    editor->canvas = mc_linux_canvas_new(&callbacks, editor);
    gtk_container_add(GTK_CONTAINER(editor->window), editor->canvas);
    editors = g_slist_prepend(editors, editor);
    g_application_hold(G_APPLICATION(application));
    editor->timer = g_timeout_add(33, poll_editor, editor);
    gtk_widget_show_all(editor->window); gtk_widget_grab_focus(editor->canvas);
    return editor->window;
}

GtkWidget *mc_linux_video_editor_open(GtkApplication *application, const char *source, const char *draft) {
    return mc_linux_video_editor_open_test(application, source, draft, FALSE);
}

gboolean mc_linux_video_editors_busy(void) { return editors != NULL; }
gboolean mc_linux_video_editors_closing(void) {
    for (GSList *at = editors; at; at = at->next)
        if (!((EditorWindow *)at->data)->close_requested) return FALSE;
    return TRUE;
}
gboolean mc_linux_video_editors_close(void) {
    for (GSList *at = editors; at; at = at->next) close_editor(at->data);
    return editors == NULL;
}
gboolean mc_linux_video_editor_command(GtkWidget *window, const char *json) {
    EditorWindow *editor = get_editor(window); if (!editor) return FALSE;
    gboolean result = mc_video_editor_host_command(editor->host, json);
    editor->dirty = TRUE; render(editor); return result;
}
char *mc_linux_video_editor_state(GtkWidget *window) {
    EditorWindow *editor = get_editor(window);
    return editor ? mc_video_editor_host_state(editor->host) : NULL;
}
void mc_linux_video_editor_text_free(char *text) { mc_video_editor_host_text_free(text); }
int32_t mc_linux_video_editor_frame_snapshot(GtkWidget *window) {
    EditorWindow *editor = get_editor(window);
    return editor && !editor->destroyed && editor->width > 0 && editor->height > 0 ?
        mc_video_editor_host_frame(editor->host, editor->width, editor->height) : 0;
}
