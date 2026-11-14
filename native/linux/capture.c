#include "capture.h"
#include <gdk/gdkx.h>
#include <pango/pangocairo.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"

extern int32_t image_session_create(int32_t, int32_t);
extern int32_t image_session_add(int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t);
extern int32_t image_session_set_text(int32_t, moonbit_string_t);
extern int32_t image_session_undo(int32_t);
extern int32_t image_session_redo(int32_t);
extern int32_t image_session_count(int32_t);
extern double image_session_value(int32_t, int32_t, int32_t);
extern moonbit_string_t image_session_text(int32_t, int32_t);
extern void image_session_dispose(int32_t);

enum { RECTANGLE = 1, ARROW, TEXT, REDACT };
typedef struct {
  GtkApplication *application;
  GtkWidget *overlay, *editor, *canvas, *entry, *status;
  GdkPixbuf *desktop, *image;
  GdkSeat *seat;
  GDBusConnection *bus;
  char *request_path;
  guint subscription;
  int session, tool, color, stroke, width, height, root_width, root_height;
  double x1, y1, x2, y2, zoom, offset_x, offset_y;
  gboolean dragging, pending, smoke, closing;
} Capture;
static Capture capture;
static guint generation;

static gboolean open_editor(GdkPixbuf *image);
static void report(const char *message) {
  if (capture.smoke) { g_printerr("%s\n", message); return; }
  GtkWidget *dialog = gtk_message_dialog_new(capture.editor ? GTK_WINDOW(capture.editor) : NULL,
    GTK_DIALOG_DESTROY_WITH_PARENT, GTK_MESSAGE_INFO, GTK_BUTTONS_CLOSE, "%s", message);
  gtk_window_set_title(GTK_WINDOW(dialog), "Mooji Cut");
  g_signal_connect_swapped(dialog, "response", G_CALLBACK(gtk_widget_destroy), dialog);
  gtk_widget_show_all(dialog);
}

static void release_overlay(void) {
  GdkSeat *seat = capture.seat;
  GtkWidget *window = capture.overlay;
  capture.overlay = NULL; capture.seat = NULL; capture.dragging = FALSE;
  if (seat) gdk_seat_ungrab(seat);
  if (window) gtk_widget_destroy(window);
  g_clear_object(&capture.desktop);
}

static void release_portal(gboolean cancel) {
  if (capture.bus && capture.subscription) g_dbus_connection_signal_unsubscribe(capture.bus, capture.subscription);
  capture.subscription = 0;
  if (cancel && capture.bus && capture.request_path) g_dbus_connection_call(capture.bus,
    "org.freedesktop.portal.Desktop", capture.request_path, "org.freedesktop.portal.Request", "Close",
    NULL, NULL, G_DBUS_CALL_FLAGS_NONE, 3000, NULL, NULL, NULL);
  g_clear_pointer(&capture.request_path, g_free);
  g_clear_object(&capture.bus);
  capture.pending = FALSE;
}

void mc_linux_capture_close(void) {
  if (capture.closing) return;
  capture.closing = TRUE;
  generation++;
  if (capture.canvas && gtk_widget_has_grab(capture.canvas)) gtk_grab_remove(capture.canvas);
  release_portal(TRUE);
  release_overlay();
  GtkWidget *window = capture.editor;
  capture.editor = NULL;
  if (window) gtk_widget_destroy(window);
  if (capture.session > 0) image_session_dispose(capture.session);
  g_clear_object(&capture.image);
  memset(&capture, 0, sizeof(capture));
}

gboolean mc_linux_capture_busy(void) { return capture.overlay || capture.editor || capture.pending; }

static void draw_shape(cairo_t *cr, int kind, double x, double y, double width, double height,
                       int rgb, double stroke, const char *text) {
  cairo_save(cr);
  cairo_set_source_rgb(cr, ((rgb >> 16) & 255) / 255.0, ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0);
  cairo_set_line_width(cr, stroke);
  cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
  if (kind == RECTANGLE) { cairo_rectangle(cr, x, y, width, height); cairo_stroke(cr); }
  else if (kind == REDACT) {
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_NONE);
    cairo_set_source_rgb(cr, 0, 0, 0); cairo_rectangle(cr, x, y, width, height); cairo_fill(cr);
  } else if (kind == ARROW) {
    double length = hypot(width, height);
    if (length > 0.5) {
      double head = fmin(length * 0.45, 14 + stroke);
      cairo_move_to(cr, x, y); cairo_line_to(cr, x + width, y + height); cairo_stroke(cr);
      cairo_move_to(cr, x + width - head * width / length + head * 0.45 * height / length,
        y + height - head * height / length - head * 0.45 * width / length);
      cairo_line_to(cr, x + width, y + height);
      cairo_line_to(cr, x + width - head * width / length - head * 0.45 * height / length,
        y + height - head * height / length + head * 0.45 * width / length); cairo_stroke(cr);
    }
  } else if (kind == TEXT && text) {
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *font = pango_font_description_from_string("Sans Bold");
    pango_font_description_set_absolute_size(font, 24 * PANGO_SCALE);
    pango_layout_set_font_description(layout, font); pango_layout_set_text(layout, text, -1);
    cairo_move_to(cr, x, y); pango_cairo_show_layout(cr, layout);
    pango_font_description_free(font); g_object_unref(layout);
  }
  cairo_restore(cr);
}

static void draw_document(cairo_t *cr) {
  gdk_cairo_set_source_pixbuf(cr, capture.image, 0, 0); cairo_paint(cr);
  int count = image_session_count(capture.session);
  for (int pass = 0; pass < 2; pass++) for (int i = 0; i < count; i++) {
    int kind = (int)image_session_value(capture.session, i, 0);
    if ((kind == REDACT) != (pass == 1)) continue;
    char *text = NULL;
    if (kind == TEXT) {
      moonbit_string_t value = image_session_text(capture.session, i);
      text = g_utf16_to_utf8((const gunichar2 *)value, Moonbit_array_length(value), NULL, NULL, NULL);
      moonbit_decref(value);
    }
    draw_shape(cr, kind, image_session_value(capture.session, i, 1), image_session_value(capture.session, i, 2),
      image_session_value(capture.session, i, 3), image_session_value(capture.session, i, 4),
      (int)image_session_value(capture.session, i, 5), image_session_value(capture.session, i, 6), text);
    g_free(text);
  }
}

static GdkPixbuf *flatten(void) {
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, capture.width, capture.height);
  if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) { cairo_surface_destroy(surface); return NULL; }
  cairo_t *cr = cairo_create(surface); draw_document(cr); cairo_destroy(cr);
  GdkPixbuf *image = gdk_pixbuf_get_from_surface(surface, 0, 0, capture.width, capture.height);
  cairo_surface_destroy(surface);
  return image;
}

static gboolean copy_image(void) {
  GdkPixbuf *image = flatten();
  if (!image) return FALSE;
  GdkAtom selection = capture.smoke ? gdk_atom_intern_static_string("MOOJICUT_TEST_IMAGE") : GDK_SELECTION_CLIPBOARD;
  GtkClipboard *clipboard = gtk_clipboard_get(selection);
  gtk_clipboard_set_image(clipboard, image);
  if (!capture.smoke) { gtk_clipboard_set_can_store(clipboard, NULL, 0); gtk_clipboard_store(clipboard); }
  g_object_unref(image);
  return TRUE;
}

static gboolean canvas_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
  (void)data;
  GtkAllocation allocation; gtk_widget_get_allocation(widget, &allocation);
  capture.zoom = fmin(1, fmin((double)MAX(1, allocation.width - 24) / capture.width,
    (double)MAX(1, allocation.height - 24) / capture.height));
  capture.offset_x = (allocation.width - capture.width * capture.zoom) / 2;
  capture.offset_y = (allocation.height - capture.height * capture.zoom) / 2;
  cairo_translate(cr, capture.offset_x, capture.offset_y); cairo_scale(cr, capture.zoom, capture.zoom);
  cairo_rectangle(cr, 0, 0, capture.width, capture.height); cairo_clip(cr);
  draw_document(cr);
  if (capture.dragging) draw_shape(cr, capture.tool,
    capture.tool == ARROW ? capture.x1 : fmin(capture.x1, capture.x2),
    capture.tool == ARROW ? capture.y1 : fmin(capture.y1, capture.y2),
    capture.tool == ARROW ? capture.x2 - capture.x1 : fabs(capture.x2 - capture.x1),
    capture.tool == ARROW ? capture.y2 - capture.y1 : fabs(capture.y2 - capture.y1), capture.color, capture.stroke, NULL);
  return FALSE;
}

static gboolean add_text(int x, int y) {
  glong length = 0; const char *text = gtk_entry_get_text(GTK_ENTRY(capture.entry));
  gunichar2 *utf16 = g_utf8_to_utf16(text, -1, NULL, &length, NULL);
  if (!utf16 || length < 1 || x >= capture.width || y >= capture.height) { g_free(utf16); return FALSE; }
  moonbit_string_t input = moonbit_make_string_raw((int32_t)length);
  memcpy(input, utf16, (gsize)length * sizeof(gunichar2)); g_free(utf16);
  int result = image_session_set_text(capture.session, input); moonbit_decref(input);
  return result == 1 && image_session_add(capture.session, TEXT, x, y, capture.width - x,
    MIN(32, capture.height - y), capture.color, capture.stroke) == 1;
}

static gboolean canvas_press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)data;
  if (event->button != 1 || capture.zoom <= 0) return FALSE;
  double x = (event->x - capture.offset_x) / capture.zoom, y = (event->y - capture.offset_y) / capture.zoom;
  if (x < 0 || y < 0 || x >= capture.width || y >= capture.height) return FALSE;
  capture.x1 = capture.x2 = floor(x); capture.y1 = capture.y2 = floor(y);
  gtk_widget_grab_focus(widget);
  if (capture.tool == TEXT) {
    if (!add_text((int)x, (int)y)) gtk_label_set_text(GTK_LABEL(capture.status), "先输入文字，再点击图片放置。");
    gtk_widget_queue_draw(widget);
  } else { capture.dragging = TRUE; gtk_grab_add(widget); }
  return TRUE;
}

static gboolean canvas_motion(GtkWidget *widget, GdkEventMotion *event, gpointer data) {
  (void)data;
  if (!capture.dragging || capture.zoom <= 0) return FALSE;
  capture.x2 = CLAMP(floor((event->x - capture.offset_x) / capture.zoom), 0, capture.width);
  capture.y2 = CLAMP(floor((event->y - capture.offset_y) / capture.zoom), 0, capture.height);
  gtk_widget_queue_draw(widget); return TRUE;
}

static gboolean canvas_release(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)data;
  if (!capture.dragging || event->button != 1) return FALSE;
  capture.x2 = CLAMP(floor((event->x - capture.offset_x) / capture.zoom), 0, capture.width);
  capture.y2 = CLAMP(floor((event->y - capture.offset_y) / capture.zoom), 0, capture.height);
  capture.dragging = FALSE; gtk_grab_remove(widget);
  int x = (int)(capture.tool == ARROW ? capture.x1 : fmin(capture.x1, capture.x2));
  int y = (int)(capture.tool == ARROW ? capture.y1 : fmin(capture.y1, capture.y2));
  int width = (int)(capture.tool == ARROW ? capture.x2 - capture.x1 : fabs(capture.x2 - capture.x1));
  int height = (int)(capture.tool == ARROW ? capture.y2 - capture.y1 : fabs(capture.y2 - capture.y1));
  if ((capture.tool == ARROW && abs(width) + abs(height) >= 3) || (width >= 2 && height >= 2))
    image_session_add(capture.session, capture.tool, x, y, width, height, capture.tool == REDACT ? 0 : capture.color, capture.stroke);
  gtk_widget_queue_draw(widget); return TRUE;
}

static void tool_changed(GtkComboBox *combo, gpointer data) {
  (void)data; capture.tool = gtk_combo_box_get_active(combo) + 1;
  if (capture.tool == TEXT) gtk_widget_grab_focus(capture.entry);
}
static void color_changed(GtkColorButton *button, gpointer data) {
  (void)data; GdkRGBA color; gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(button), &color);
  capture.color = ((int)round(color.red * 255) << 16) | ((int)round(color.green * 255) << 8) | (int)round(color.blue * 255);
}
static void stroke_changed(GtkSpinButton *spin, gpointer data) { (void)data; capture.stroke = gtk_spin_button_get_value_as_int(spin); }
static void command(GtkWidget *widget, gpointer data) {
  (void)widget; int action = GPOINTER_TO_INT(data);
  if (action == 1) image_session_undo(capture.session);
  if (action == 2) image_session_redo(capture.session);
  if (action == 3) { if (copy_image()) mc_linux_capture_close(); else report("暂时无法复制图片，请重试。"); return; }
  if (action == 4) { mc_linux_capture_close(); return; }
  gtk_widget_queue_draw(capture.canvas);
}
static gboolean editor_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)widget; (void)data;
  if (event->keyval == GDK_KEY_Escape) { mc_linux_capture_close(); return TRUE; }
  if (!(event->state & GDK_CONTROL_MASK)) return FALSE;
  if (event->keyval == GDK_KEY_Return) { command(NULL, GINT_TO_POINTER(3)); return TRUE; }
  if (gtk_window_get_focus(GTK_WINDOW(capture.editor)) == capture.entry) return FALSE;
  guint key = gdk_keyval_to_lower(event->keyval);
  if (key == GDK_KEY_z || key == GDK_KEY_y) { command(NULL, GINT_TO_POINTER(key == GDK_KEY_y || (event->state & GDK_SHIFT_MASK) ? 2 : 1)); return TRUE; }
  if (key == GDK_KEY_c) { command(NULL, GINT_TO_POINTER(3)); return TRUE; }
  return FALSE;
}
static gboolean delete_window(GtkWidget *widget, GdkEvent *event, gpointer data) {
  (void)widget; (void)event; (void)data; mc_linux_capture_close(); return TRUE;
}

static gboolean open_editor(GdkPixbuf *image) {
  int width = gdk_pixbuf_get_width(image), height = gdk_pixbuf_get_height(image);
  if (width < 2 || height < 2 || width > 32768 || height > 32768 || (guint64)width * height > 64000000) return FALSE;
  capture.session = image_session_create(width, height);
  if (capture.session <= 0) return FALSE;
  capture.image = g_object_ref(image); capture.width = width; capture.height = height;
  capture.tool = RECTANGLE; capture.color = 0xF26769; capture.stroke = 4;
  capture.editor = gtk_application_window_new(capture.application);
  gtk_window_set_title(GTK_WINDOW(capture.editor), "Mooji Cut · 标注后复制");
  gtk_window_set_default_size(GTK_WINDOW(capture.editor), 1000, 700);
  g_signal_connect(capture.editor, "delete-event", G_CALLBACK(delete_window), NULL);
  g_signal_connect(capture.editor, "key-press-event", G_CALLBACK(editor_key), NULL);
  GtkWidget *layout = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10), *toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_container_set_border_width(GTK_CONTAINER(layout), 12); gtk_container_add(GTK_CONTAINER(capture.editor), layout);
  gtk_box_pack_start(GTK_BOX(layout), toolbar, FALSE, FALSE, 0);
  GtkWidget *tools = gtk_combo_box_text_new();
  const char *names[] = { "矩形", "箭头", "文字", "实心遮挡" };
  for (int i = 0; i < 4; i++) gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(tools), names[i]);
  gtk_combo_box_set_active(GTK_COMBO_BOX(tools), 0);
  g_signal_connect(tools, "changed", G_CALLBACK(tool_changed), NULL); gtk_box_pack_start(GTK_BOX(toolbar), tools, FALSE, FALSE, 0);
  GdkRGBA color = { 242 / 255.0, 103 / 255.0, 105 / 255.0, 1 };
  GtkWidget *colors = gtk_color_button_new_with_rgba(&color), *stroke = gtk_spin_button_new_with_range(1, 24, 1);
  gtk_widget_set_tooltip_text(colors, "标注颜色"); gtk_widget_set_tooltip_text(stroke, "线宽（原图像素）");
  gtk_spin_button_set_value(GTK_SPIN_BUTTON(stroke), 4);
  g_signal_connect(colors, "color-set", G_CALLBACK(color_changed), NULL); g_signal_connect(stroke, "value-changed", G_CALLBACK(stroke_changed), NULL);
  gtk_box_pack_start(GTK_BOX(toolbar), colors, FALSE, FALSE, 0); gtk_box_pack_start(GTK_BOX(toolbar), stroke, FALSE, FALSE, 0);
  const char *actions[] = { "撤销", "重做", "复制", "取消" };
  for (int i = 0; i < 4; i++) {
    GtkWidget *button = gtk_button_new_with_label(actions[i]);
    g_signal_connect(button, "clicked", G_CALLBACK(command), GINT_TO_POINTER(i + 1));
    gtk_box_pack_start(GTK_BOX(toolbar), button, FALSE, FALSE, 0);
  }
  capture.entry = gtk_entry_new(); gtk_entry_set_max_length(GTK_ENTRY(capture.entry), 1024);
  gtk_entry_set_placeholder_text(GTK_ENTRY(capture.entry), "输入文字，选择“文字”工具，再点击图片放置");
  gtk_box_pack_start(GTK_BOX(layout), capture.entry, FALSE, FALSE, 0);
  capture.canvas = gtk_drawing_area_new(); gtk_widget_set_can_focus(capture.canvas, TRUE);
  gtk_widget_add_events(capture.canvas, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK | GDK_POINTER_MOTION_MASK);
  g_signal_connect(capture.canvas, "draw", G_CALLBACK(canvas_draw), NULL);
  g_signal_connect(capture.canvas, "button-press-event", G_CALLBACK(canvas_press), NULL);
  g_signal_connect(capture.canvas, "motion-notify-event", G_CALLBACK(canvas_motion), NULL);
  g_signal_connect(capture.canvas, "button-release-event", G_CALLBACK(canvas_release), NULL);
  gtk_box_pack_start(GTK_BOX(layout), capture.canvas, TRUE, TRUE, 0);
  capture.status = gtk_label_new("确认后复制原图尺寸的图片 · Ctrl+Z 撤销 · Ctrl+Enter 复制 · Esc 取消");
  gtk_box_pack_start(GTK_BOX(layout), capture.status, FALSE, FALSE, 0);
  gtk_widget_show_all(capture.editor); gtk_window_present(GTK_WINDOW(capture.editor));
  return TRUE;
}

static gboolean overlay_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
  (void)widget; (void)data;
  double sx = (double)capture.root_width / gdk_pixbuf_get_width(capture.desktop);
  double sy = (double)capture.root_height / gdk_pixbuf_get_height(capture.desktop);
  cairo_save(cr); cairo_scale(cr, sx, sy); gdk_cairo_set_source_pixbuf(cr, capture.desktop, 0, 0); cairo_paint(cr); cairo_restore(cr);
  cairo_set_source_rgba(cr, 0, 0, 0, 0.4); cairo_paint(cr);
  double x = fmin(capture.x1, capture.x2), y = fmin(capture.y1, capture.y2);
  double width = fabs(capture.x2 - capture.x1), height = fabs(capture.y2 - capture.y1);
  if (width > 0 && height > 0) {
    cairo_save(cr); cairo_rectangle(cr, x, y, width, height); cairo_clip(cr); cairo_scale(cr, sx, sy);
    gdk_cairo_set_source_pixbuf(cr, capture.desktop, 0, 0); cairo_paint(cr); cairo_restore(cr);
    cairo_set_source_rgb(cr, 242 / 255.0, 103 / 255.0, 105 / 255.0); cairo_set_line_width(cr, 2);
    cairo_rectangle(cr, x, y, width, height); cairo_stroke(cr);
  }
  cairo_set_source_rgb(cr, 1, 1, 1);
  PangoLayout *hint = pango_cairo_create_layout(cr); pango_layout_set_text(hint, "拖动框选 · 松开后标注 · Esc 取消", -1);
  cairo_move_to(cr, CLAMP(x, 16, MAX(16, capture.root_width - 380)), CLAMP(y - 28, 16, MAX(16, capture.root_height - 40)));
  pango_cairo_show_layout(cr, hint); g_object_unref(hint); return FALSE;
}
static gboolean overlay_press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)data;
  if (event->button == 3) { mc_linux_capture_close(); return TRUE; }
  if (event->button != 1) return FALSE;
  capture.x1 = capture.x2 = CLAMP(event->x, 0, capture.root_width);
  capture.y1 = capture.y2 = CLAMP(event->y, 0, capture.root_height); capture.dragging = TRUE;
  gtk_widget_queue_draw(widget); return TRUE;
}
static gboolean overlay_motion(GtkWidget *widget, GdkEventMotion *event, gpointer data) {
  (void)data; if (!capture.dragging) return FALSE;
  capture.x2 = CLAMP(event->x, 0, capture.root_width); capture.y2 = CLAMP(event->y, 0, capture.root_height);
  gtk_widget_queue_draw(widget); return TRUE;
}
static gboolean finish_selection(void) {
  double sx = (double)gdk_pixbuf_get_width(capture.desktop) / capture.root_width;
  double sy = (double)gdk_pixbuf_get_height(capture.desktop) / capture.root_height;
  int x = (int)floor(fmin(capture.x1, capture.x2) * sx), y = (int)floor(fmin(capture.y1, capture.y2) * sy);
  int right = MIN(gdk_pixbuf_get_width(capture.desktop), (int)ceil(fmax(capture.x1, capture.x2) * sx));
  int bottom = MIN(gdk_pixbuf_get_height(capture.desktop), (int)ceil(fmax(capture.y1, capture.y2) * sy));
  if (right - x < 2 || bottom - y < 2) return FALSE;
  GdkPixbuf *part = gdk_pixbuf_new_subpixbuf(capture.desktop, x, y, right - x, bottom - y);
  GdkPixbuf *copy = gdk_pixbuf_copy(part); g_object_unref(part);
  release_overlay();
  gboolean ok = copy && open_editor(copy); g_clear_object(&copy);
  if (!ok) { report("无法创建截图，请缩小区域后重试。"); mc_linux_capture_close(); }
  return ok;
}
static gboolean overlay_release(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)widget; (void)data;
  if (!capture.dragging || event->button != 1) return FALSE;
  capture.x2 = CLAMP(event->x, 0, capture.root_width); capture.y2 = CLAMP(event->y, 0, capture.root_height);
  capture.dragging = FALSE; finish_selection(); return TRUE;
}
static gboolean overlay_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)widget; (void)data;
  if (event->keyval == GDK_KEY_Escape) { mc_linux_capture_close(); return TRUE; }
  return FALSE;
}
static gboolean overlay_grab_broken(GtkWidget *widget, GdkEventGrabBroken *event, gpointer data) {
  (void)event; (void)data;
  if (capture.overlay == widget) mc_linux_capture_close();
  return FALSE;
}

static gboolean start_x11(void) {
  GdkWindow *root = gdk_get_default_root_window(); int origin_x, origin_y;
  capture.root_width = gdk_window_get_width(root); capture.root_height = gdk_window_get_height(root);
  gdk_window_get_origin(root, &origin_x, &origin_y);
  capture.desktop = gdk_pixbuf_get_from_window(root, 0, 0, capture.root_width, capture.root_height);
  if (!capture.desktop) return FALSE;
  capture.overlay = gtk_window_new(GTK_WINDOW_POPUP);
  gtk_window_set_application(GTK_WINDOW(capture.overlay), capture.application);
  gtk_window_set_decorated(GTK_WINDOW(capture.overlay), FALSE); gtk_window_set_keep_above(GTK_WINDOW(capture.overlay), TRUE);
  gtk_window_set_accept_focus(GTK_WINDOW(capture.overlay), TRUE);
  gtk_window_move(GTK_WINDOW(capture.overlay), origin_x, origin_y);
  gtk_window_set_default_size(GTK_WINDOW(capture.overlay), capture.root_width, capture.root_height);
  gtk_widget_add_events(capture.overlay, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK | GDK_POINTER_MOTION_MASK | GDK_KEY_PRESS_MASK);
  g_signal_connect(capture.overlay, "draw", G_CALLBACK(overlay_draw), NULL);
  g_signal_connect(capture.overlay, "button-press-event", G_CALLBACK(overlay_press), NULL);
  g_signal_connect(capture.overlay, "motion-notify-event", G_CALLBACK(overlay_motion), NULL);
  g_signal_connect(capture.overlay, "button-release-event", G_CALLBACK(overlay_release), NULL);
  g_signal_connect(capture.overlay, "key-press-event", G_CALLBACK(overlay_key), NULL);
  g_signal_connect(capture.overlay, "grab-broken-event", G_CALLBACK(overlay_grab_broken), NULL);
  gtk_widget_show_all(capture.overlay);
  GdkWindow *window = gtk_widget_get_window(capture.overlay);
  gdk_window_move_resize(window, origin_x, origin_y, capture.root_width, capture.root_height);
  GdkSeat *seat = gdk_display_get_default_seat(gdk_window_get_display(window));
  GdkCursor *cursor = gdk_cursor_new_from_name(gdk_window_get_display(window), "crosshair");
  GdkGrabStatus grabbed = gdk_seat_grab(seat, window, GDK_SEAT_CAPABILITY_ALL, FALSE, cursor, NULL, NULL, NULL);
  g_clear_object(&cursor);
  if (grabbed != GDK_GRAB_SUCCESS) { release_overlay(); return FALSE; }
  capture.seat = seat; gdk_window_focus(window, GDK_CURRENT_TIME);
  return TRUE;
}

static void portal_response(GDBusConnection *bus, const char *sender, const char *path,
                            const char *interface, const char *signal, GVariant *parameters, gpointer data) {
  (void)bus; (void)sender; (void)interface; (void)signal;
  if (GPOINTER_TO_UINT(data) != generation || !capture.pending || g_strcmp0(path, capture.request_path)) return;
  guint result; GVariant *values; g_variant_get(parameters, "(u@a{sv})", &result, &values);
  char *uri = NULL; g_variant_lookup(values, "uri", "s", &uri); g_variant_unref(values);
  release_portal(FALSE);
  if (result != 0 || !uri) {
    report(result == 1 ? "截图已取消，剪贴板未更改。" : "系统未允许截图，剪贴板未更改。请检查截图门户和权限。");
    g_free(uri); mc_linux_capture_close(); return;
  }
  GFile *file = g_file_new_for_uri(uri); char *filename = g_file_get_path(file); GError *error = NULL;
  GdkPixbuf *image = filename ? gdk_pixbuf_new_from_file(filename, &error) : NULL;
  gboolean ok = image && open_editor(image);
  g_clear_object(&image); g_object_unref(file); g_free(filename); g_free(uri); g_clear_error(&error);
  if (!ok) { report("无法读取系统提供的截图。剪贴板未更改。"); mc_linux_capture_close(); }
}
static void portal_started(GObject *object, GAsyncResult *result, gpointer data) {
  GError *error = NULL; GVariant *response = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), result, &error);
  if (GPOINTER_TO_UINT(data) != generation || !capture.pending) {
    /* A cancellation can race the method reply on older portal versions that
       return a different request path. Close that actual handle as well. */
    if (response && GPOINTER_TO_UINT(data) != generation) {
      const char *path; g_variant_get(response, "(&o)", &path);
      g_dbus_connection_call(G_DBUS_CONNECTION(object), "org.freedesktop.portal.Desktop", path,
        "org.freedesktop.portal.Request", "Close", NULL, NULL, G_DBUS_CALL_FLAGS_NONE, 3000, NULL, NULL, NULL);
    }
    g_clear_pointer(&response, g_variant_unref); g_clear_error(&error); return;
  }
  if (!response) { report("当前桌面未提供可用的截图门户，请安装并启用对应的 xdg-desktop-portal 后端。"); g_clear_error(&error); mc_linux_capture_close(); return; }
  const char *path; g_variant_get(response, "(&o)", &path);
  if (g_strcmp0(path, capture.request_path)) {
    g_dbus_connection_signal_unsubscribe(capture.bus, capture.subscription); g_free(capture.request_path);
    capture.request_path = g_strdup(path);
    capture.subscription = g_dbus_connection_signal_subscribe(capture.bus, "org.freedesktop.portal.Desktop",
      "org.freedesktop.portal.Request", "Response", path, NULL, G_DBUS_SIGNAL_FLAGS_NONE, portal_response, data, NULL);
  }
  g_variant_unref(response);
}
static void start_portal(void) {
  GError *error = NULL; capture.bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
  if (!capture.bus) { report("无法连接系统截图服务。请确认桌面会话的 D-Bus 正常运行。"); g_clear_error(&error); mc_linux_capture_close(); return; }
  char *sender = g_strdup(g_dbus_connection_get_unique_name(capture.bus) + 1);
  for (char *p = sender; *p; p++) if (*p == '.') *p = '_';
  char *token = g_strdup_printf("moojicut_%u_%u", generation, g_random_int());
  capture.request_path = g_strdup_printf("/org/freedesktop/portal/desktop/request/%s/%s", sender, token);
  capture.pending = TRUE;
  capture.subscription = g_dbus_connection_signal_subscribe(capture.bus, "org.freedesktop.portal.Desktop",
    "org.freedesktop.portal.Request", "Response", capture.request_path, NULL, G_DBUS_SIGNAL_FLAGS_NONE,
    portal_response, GUINT_TO_POINTER(generation), NULL);
  GVariantBuilder options; g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token));
  g_variant_builder_add(&options, "{sv}", "interactive", g_variant_new_boolean(TRUE));
  g_dbus_connection_call(capture.bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
    "org.freedesktop.portal.Screenshot", "Screenshot", g_variant_new("(s@a{sv})", "", g_variant_builder_end(&options)),
    G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, 10000, NULL, portal_started, GUINT_TO_POINTER(generation));
  g_free(sender); g_free(token);
}

void mc_linux_capture_start(GtkApplication *application) {
  if (mc_linux_capture_busy()) { if (capture.editor) gtk_window_present(GTK_WINDOW(capture.editor)); return; }
  memset(&capture, 0, sizeof(capture)); capture.application = application; generation++;
  if (GDK_IS_X11_DISPLAY(gdk_display_get_default())) {
    if (!start_x11()) { report("无法冻结屏幕，或其他应用正在选择区域。请退出其他截屏操作后重试。"); mc_linux_capture_close(); }
  } else start_portal();
}

gboolean mc_linux_capture_smoke(GtkApplication *application) {
  if (mc_linux_capture_busy()) return FALSE;
  memset(&capture, 0, sizeof(capture)); capture.application = application; capture.smoke = TRUE;
  GdkPixbuf *source = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, 320, 200);
  if (!source) return FALSE;
  gdk_pixbuf_fill(source, 0xDCA050FF);
  gboolean passed = open_editor(source); g_object_unref(source);
  if (!passed) { mc_linux_capture_close(); return FALSE; }
  passed = image_session_add(capture.session, REDACT, 30, 40, 80, 60, 0, 4) == 1;
  passed = passed && image_session_add(capture.session, RECTANGLE, 20, 30, 130, 110, 0xF26769, 4) == 1;
  passed = passed && image_session_add(capture.session, ARROW, 250, 170, -100, -60, 0x246BFD, 4) == 1;
  gtk_entry_set_text(GTK_ENTRY(capture.entry), "截图 MoonBit ✅"); passed = passed && add_text(40, 50);
  passed = passed && image_session_undo(capture.session) == 1 && image_session_count(capture.session) == 3;
  passed = passed && image_session_redo(capture.session) == 1 && image_session_count(capture.session) == 4;
  GdkPixbuf *image = flatten();
  passed = passed && image && gdk_pixbuf_get_width(image) == 320 && gdk_pixbuf_get_height(image) == 200;
  if (image) {
    const guchar *pixel = gdk_pixbuf_get_pixels(image) + 50 * gdk_pixbuf_get_rowstride(image) + 50 * gdk_pixbuf_get_n_channels(image);
    passed = passed && pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 0;
    g_object_unref(image);
  }
  passed = passed && copy_image();
  GtkClipboard *clipboard = gtk_clipboard_get(gdk_atom_intern_static_string("MOOJICUT_TEST_IMAGE"));
  image = gtk_clipboard_wait_for_image(clipboard);
  passed = passed && image && gdk_pixbuf_get_width(image) == 320 && gdk_pixbuf_get_height(image) == 200;
  g_clear_object(&image); gtk_clipboard_clear(clipboard); mc_linux_capture_close();
  if (GDK_IS_X11_DISPLAY(gdk_display_get_default())) {
    capture.application = application; capture.smoke = TRUE;
    if (!start_x11()) passed = FALSE;
    else {
      capture.x1 = 300; capture.y1 = 180; capture.x2 = 20; capture.y2 = 30;
      passed = finish_selection() && passed;
      passed = passed && capture.editor && capture.width >= 280 && capture.height >= 150;
    }
    mc_linux_capture_close();
  }
  g_print("Linux screenshot smoke %s: MoonBit edits, undo/redo, masks, original image, private clipboard, X11 selection.\n", passed ? "passed" : "FAILED");
  return passed;
}
