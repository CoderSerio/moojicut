#include "capture.h"
#include "native/shared/image_session.h"
#include "components/icons/shared/mc_icons.h"
#include "moonbit.h"
#include "plugins/feature/select/linux/selection.h"
#include "components/style_controls/linux/style_controls.h"
#include <dlfcn.h>
#include <gdk/gdkx.h>
#include <math.h>
#include <pango/pangocairo.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { SELECT = MC_STYLE_TOOL_SELECT, RECTANGLE = MC_STYLE_TOOL_RECTANGLE,
       ARROW = MC_STYLE_TOOL_ARROW, TEXT = MC_STYLE_TOOL_TEXT, REDACT = MC_STYLE_TOOL_COVER };
typedef struct {
  char *text;
  int cursor, selection;
} TextSnapshot;
typedef struct {
  GtkApplication *application;
  MCLinuxCaptureHost host;
  GtkWidget *editor, *canvas, *overlay, *toolbar, *entry, *tools[5], *future_tools[2];
  MCStyleControls *style_controls;
  int style_bank;
  GdkPixbuf *image;
  GdkRectangle toolbar_bounds, entry_bounds;
  GPtrArray *draft_undo, *draft_redo;
  TextSnapshot *draft_before;
  int draft_action_depth;
  gboolean restoring_draft;
  GDBusConnection *bus;
  char *request_path;
  guint subscription;
  int session, tool, color, stroke, font_size, width, height, root_width, root_height;
  int selected, edit_index, gesture;
  MCSelectionDrag selection;
  double zoom, offset_x, offset_y, opacity, crop[4], original[8], preview[8];
  gboolean dragging, pending, smoke, closing, selecting, editing, composing, x11;
} Capture;
static Capture capture;
static guint generation;

static gboolean open_editor(GdkPixbuf *image);
static gboolean commit_text(void);
static void layout_controls(void);
static void refresh_context(void);
static void sync_control_values(void);
static void draw_document(cairo_t *cr, gboolean export);
static PangoLayout *text_layout(cairo_t *cr, const char *text, double width, double size);
static void snapshot_free(gpointer value) {
  TextSnapshot *snapshot = value;
  if (!snapshot)
    return;
  g_free(snapshot->text);
  g_free(snapshot);
}
static TextSnapshot *snapshot_text(void) {
  GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(capture.entry));
  GtkTextIter first, last, cursor, selection;
  gtk_text_buffer_get_bounds(buffer, &first, &last);
  TextSnapshot *value = g_new0(TextSnapshot, 1);
  value->text = gtk_text_buffer_get_text(buffer, &first, &last, FALSE);
  gtk_text_buffer_get_iter_at_mark(buffer, &cursor, gtk_text_buffer_get_insert(buffer));
  gtk_text_buffer_get_iter_at_mark(buffer, &selection, gtk_text_buffer_get_selection_bound(buffer));
  value->cursor = gtk_text_iter_get_offset(&cursor);
  value->selection = gtk_text_iter_get_offset(&selection);
  return value;
}
static void push_snapshot(GPtrArray *array, TextSnapshot *snapshot) {
  if (strlen(snapshot->text) > 40000) {
    snapshot_free(snapshot);
    return;
  }
  if (array->len >= 100)
    g_ptr_array_remove_index(array, 0);
  g_ptr_array_add(array, snapshot);
}
static void reset_draft_history(void) {
  if (!capture.draft_undo)
    capture.draft_undo = g_ptr_array_new_with_free_func(snapshot_free);
  if (!capture.draft_redo)
    capture.draft_redo = g_ptr_array_new_with_free_func(snapshot_free);
  g_ptr_array_set_size(capture.draft_undo, 0);
  g_ptr_array_set_size(capture.draft_redo, 0);
  g_clear_pointer(&capture.draft_before, snapshot_free);
  capture.draft_action_depth = 0;
}
static void draft_action_begin(GtkTextBuffer *buffer, gpointer data) {
  (void)buffer;
  (void)data;
  if (!capture.editing || capture.restoring_draft)
    return;
  if (capture.draft_action_depth++ == 0)
    capture.draft_before = snapshot_text();
}
static void draft_action_end(GtkTextBuffer *buffer, gpointer data) {
  (void)buffer;
  (void)data;
  if (!capture.editing || capture.restoring_draft || capture.draft_action_depth <= 0)
    return;
  if (--capture.draft_action_depth || !capture.draft_before)
    return;
  TextSnapshot *after = snapshot_text(), *before = capture.draft_before;
  capture.draft_before = NULL;
  if (strcmp(before->text, after->text)) {
    push_snapshot(capture.draft_undo, before);
    g_ptr_array_set_size(capture.draft_redo, 0);
  } else
    snapshot_free(before);
  snapshot_free(after);
}
static void draft_undo(gboolean redo) {
  GPtrArray *from = redo ? capture.draft_redo : capture.draft_undo;
  GPtrArray *to = redo ? capture.draft_undo : capture.draft_redo;
  if (!from || !from->len)
    return;
  TextSnapshot *value = g_ptr_array_steal_index(from, from->len - 1);
  push_snapshot(to, snapshot_text());
  capture.restoring_draft = TRUE;
  GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(capture.entry));
  gtk_text_buffer_set_text(buffer, value->text, -1);
  GtkTextIter cursor, selection;
  gtk_text_buffer_get_iter_at_offset(buffer, &cursor, value->cursor);
  gtk_text_buffer_get_iter_at_offset(buffer, &selection, value->selection);
  gtk_text_buffer_select_range(buffer, &cursor, &selection);
  capture.restoring_draft = FALSE;
  snapshot_free(value);
}
static void report(const char *message) {
  if (capture.smoke) {
    g_printerr("%s\n", message);
    return;
  }
  GtkWidget *dialog = gtk_message_dialog_new(capture.editor ? GTK_WINDOW(capture.editor) : NULL,
                                             GTK_DIALOG_DESTROY_WITH_PARENT, GTK_MESSAGE_INFO,
                                             GTK_BUTTONS_CLOSE, "%s", message);
  gtk_window_set_title(GTK_WINDOW(dialog), "Mooji Cut");
  g_signal_connect_swapped(dialog, "response", G_CALLBACK(gtk_widget_destroy), dialog);
  gtk_widget_show_all(dialog);
}
static void release_portal(gboolean cancel) {
  if (capture.bus && capture.subscription)
    g_dbus_connection_signal_unsubscribe(capture.bus, capture.subscription);
  capture.subscription = 0;
  if (cancel && capture.bus && capture.request_path)
    g_dbus_connection_call(capture.bus, "org.freedesktop.portal.Desktop", capture.request_path,
                           "org.freedesktop.portal.Request", "Close", NULL, NULL, G_DBUS_CALL_FLAGS_NONE,
                           3000, NULL, NULL, NULL);
  g_clear_pointer(&capture.request_path, g_free);
  g_clear_object(&capture.bus);
  capture.pending = FALSE;
}
void mc_linux_capture_close(void) {
  if (capture.closing)
    return;
  capture.closing = TRUE;
  MCLinuxCaptureHost host = capture.host;
  generation++;
  if (capture.canvas && gtk_widget_has_grab(capture.canvas))
    gtk_grab_remove(capture.canvas);
  release_portal(TRUE);
  mc_style_controls_close_dialog(capture.style_controls);
  GtkWidget *window = capture.editor;
  capture.editor = NULL;
  if (window)
    gtk_widget_destroy(window);
  if (capture.session > 0)
    image_session_dispose(capture.session);
  if (capture.style_bank > 0)
    editor_style_dispose(capture.style_bank);
  g_clear_object(&capture.image);
  g_clear_pointer(&capture.draft_before, snapshot_free);
  g_clear_pointer(&capture.draft_undo, g_ptr_array_unref);
  g_clear_pointer(&capture.draft_redo, g_ptr_array_unref);
  memset(&capture, 0, sizeof(capture));
  if (host.restore_visibility)
    host.restore_visibility(host.data);
}
gboolean mc_linux_capture_busy(void) {
  return capture.editor || capture.pending;
}
static MCSelectionRect selection_rect(const double *r) {
  return (MCSelectionRect){r[0], r[1], r[2], r[3]};
}
static void selection_values(MCSelectionRect rect, double *r) {
  r[0] = rect.x;
  r[1] = rect.y;
  r[2] = rect.width;
  r[3] = rect.height;
}
static gboolean inside(double x, double y, const double *r) {
  return mc_selection_contains(selection_rect(r), (MCSelectionPoint){x, y});
}
static void read_annotation(int index, double *r) {
  for (int i = 0; i < 8; i++)
    r[i] = image_session_value(capture.session, index, i + 1);
}
static char *annotation_text(int index) {
  moonbit_string_t value = image_session_text(capture.session, index);
  char *text = g_utf16_to_utf8((const gunichar2 *)value, Moonbit_array_length(value), NULL, NULL, NULL);
  moonbit_decref(value);
  return text;
}
static gboolean pending_text(const char *text) {
  glong length = 0;
  gunichar2 *value = g_utf8_to_utf16(text, -1, NULL, &length, NULL);
  if (!value || length < 1 || length > 10000) {
    g_free(value);
    return FALSE;
  }
  moonbit_string_t input = moonbit_make_string_raw((int32_t)length);
  memcpy(input, value, (gsize)length * sizeof(gunichar2));
  g_free(value);
  int result = image_session_set_text(capture.session, input);
  moonbit_decref(input);
  return result == 1;
}
static gboolean update_annotation(int index, const double *r) {
  double adjusted[8];
  memcpy(adjusted, r, sizeof(adjusted));
  int kind = (int)image_session_value(capture.session, index, 0);
  if (kind == TEXT && !capture.editing) {
    char *text = annotation_text(index);
    gboolean ok = pending_text(text ? text : "");
    if (ok) {
      cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
      cairo_t *cr = cairo_create(surface);
      PangoLayout *layout = text_layout(cr, text, adjusted[2], adjusted[6]);
      int height;
      pango_layout_get_pixel_size(layout, NULL, &height);
      adjusted[3] = fmin(capture.height - adjusted[1], fmax(adjusted[3], height + 2));
      g_object_unref(layout);
      cairo_destroy(cr);
      cairo_surface_destroy(surface);
    }
    g_free(text);
    if (!ok)
      return FALSE;
  }
  return image_session_update_rgba(capture.session, index, (int)adjusted[0], (int)adjusted[1],
                                   kind == ARROW ? (int)adjusted[2] : MAX(1, (int)adjusted[2]),
                                   kind == ARROW ? (int)adjusted[3] : MAX(1, (int)adjusted[3]),
                                   (int)adjusted[4], (int)adjusted[5], (int)adjusted[6], adjusted[7]) == 1;
}
static PangoLayout *text_layout(cairo_t *cr, const char *text, double width, double size) {
  PangoLayout *layout = pango_cairo_create_layout(cr);
  PangoFontDescription *font = pango_font_description_from_string("Sans Bold");
  pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
  pango_layout_set_font_description(layout, font);
  pango_font_description_free(font);
  pango_layout_set_text(layout, text, -1);
  pango_layout_set_width(layout, MAX(1, (int)(width * PANGO_SCALE)));
  pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);
  return layout;
}
static void draw_shape(cairo_t *cr, int kind, const double *r, const char *text) {
  double x = r[0], y = r[1], w = r[2], h = r[3], stroke = r[5];
  int rgb = (int)r[4];
  cairo_save(cr);
  cairo_set_source_rgba(cr, ((rgb >> 16) & 255) / 255.0, ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0,
                        r[7]);
  cairo_set_line_width(cr, stroke);
  cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
  if (kind == RECTANGLE) {
    cairo_rectangle(cr, x, y, w, h);
    cairo_stroke(cr);
  } else if (kind == REDACT) {
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_NONE);
    cairo_rectangle(cr, x, y, w, h);
    cairo_fill(cr);
  } else if (kind == ARROW) {
    double len = hypot(w, h);
    if (len > .5) {
      double head = fmin(len * .45, 14 + stroke);
      cairo_move_to(cr, x, y);
      cairo_line_to(cr, x + w, y + h);
      cairo_stroke(cr);
      cairo_move_to(cr, x + w - head * w / len + head * .45 * h / len,
                    y + h - head * h / len - head * .45 * w / len);
      cairo_line_to(cr, x + w, y + h);
      cairo_line_to(cr, x + w - head * w / len - head * .45 * h / len,
                    y + h - head * h / len + head * .45 * w / len);
      cairo_stroke(cr);
    }
  } else if (kind == TEXT && text) {
    cairo_rectangle(cr, x, y, w, h);
    cairo_clip(cr);
    PangoLayout *layout = text_layout(cr, text, w, r[6]);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, layout);
    g_object_unref(layout);
  }
  cairo_restore(cr);
}
static void draw_document(cairo_t *cr, gboolean export) {
  gdk_cairo_set_source_pixbuf(cr, capture.image, 0, 0);
  cairo_paint(cr);
  int count = image_session_count(capture.session);
  for (int pass = 0; pass < 2; pass++)
    for (int i = 0; i < count; i++) {
      int kind = (int)image_session_value(capture.session, i, 0);
      if ((kind == REDACT) != (pass == 1))
        continue;
      if (!export && capture.editing && (capture.edit_index == i || kind == REDACT))
        continue;
      double r[8];
      read_annotation(i, r);
      if (!export && capture.dragging && capture.gesture == 1 && capture.selected == i)
        memcpy(r, capture.preview, sizeof(r));
      char *text = kind == TEXT ? annotation_text(i) : NULL;
      draw_shape(cr, kind, r, text);
      g_free(text);
    }
}
static void selection_outline(cairo_t *cr, const double *r, gboolean handles) {
  cairo_save(cr);
  cairo_rectangle(cr, r[0], r[1], r[2], r[3]);
  cairo_set_source_rgb(cr, .2, .17, .23);
  cairo_set_line_width(cr, 3 / capture.zoom);
  cairo_stroke_preserve(cr);
  cairo_set_source_rgb(cr, .76, .75, .73);
  cairo_set_line_width(cr, 1 / capture.zoom);
  cairo_stroke(cr);
  if (handles)
    for (int i = 0; i < 8; i++) {
      static const double xs[] = {0, .5, 1, 1, 1, .5, 0, 0}, ys[] = {0, 0, 0, .5, 1, 1, 1, .5};
      cairo_arc(cr, r[0] + r[2] * xs[i], r[1] + r[3] * ys[i], 2.5 / capture.zoom, 0, 2 * G_PI);
      cairo_set_source_rgb(cr, .98, .96, .92);
      cairo_fill_preserve(cr);
      cairo_set_source_rgb(cr, .3, .28, .32);
      cairo_stroke(cr);
    }
  cairo_restore(cr);
}
static void transform(void) {
  int width = gtk_widget_get_allocated_width(capture.canvas),
      height = gtk_widget_get_allocated_height(capture.canvas);
  capture.zoom = fmin((double)MAX(1, width) / capture.width, (double)MAX(1, height) / capture.height);
  capture.offset_x = (width - capture.width * capture.zoom) / 2;
  capture.offset_y = (height - capture.height * capture.zoom) / 2;
}
static gboolean canvas_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
  (void)widget;
  (void)data;
  transform();
  cairo_save(cr);
  cairo_translate(cr, capture.offset_x, capture.offset_y);
  cairo_scale(cr, capture.zoom, capture.zoom);
  draw_document(cr, FALSE);
  double crop[4];
  memcpy(crop, capture.crop, sizeof(crop));
  if (capture.selecting) {
    selection_values(mc_selection_region(&capture.selection), crop);
  }
  if (capture.dragging && capture.gesture == 2)
    memcpy(crop, capture.preview, sizeof(crop));
  cairo_save(cr);
  cairo_rectangle(cr, 0, 0, capture.width, capture.height);
  cairo_rectangle(cr, crop[0], crop[1], crop[2], crop[3]);
  cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
  cairo_set_source_rgba(cr, 0, 0, 0, .42);
  cairo_fill(cr);
  cairo_restore(cr);
  selection_outline(cr, crop, !capture.selecting);
  if (capture.selecting) {
    cairo_save(cr);
    cairo_scale(cr, 1 / capture.zoom, 1 / capture.zoom);
    PangoLayout *hint = pango_cairo_create_layout(cr);
    pango_layout_set_text(hint, "拖动框选 · 松开后直接标注 · Esc 取消", -1);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_move_to(cr, 16, 16);
    pango_cairo_show_layout(cr, hint);
    g_object_unref(hint);
    cairo_restore(cr);
  }
  if (capture.selected >= 0 && !capture.editing) {
    double r[8];
    read_annotation(capture.selected, r);
    if (capture.dragging && capture.gesture == 1)
      memcpy(r, capture.preview, sizeof(r));
    selection_outline(cr, r, TRUE);
  }
  if (capture.dragging && capture.gesture == 0 && !capture.selecting) {
    MCSelectionRect region = capture.tool == ARROW ? mc_selection_vector(&capture.selection)
                                                    : mc_selection_region(&capture.selection);
    double r[] = {region.x, region.y, region.width, region.height,
                    capture.color, capture.stroke, capture.font_size, capture.opacity};
    draw_shape(cr, capture.tool, r, NULL);
  }
  cairo_restore(cr);
  return FALSE;
}
static gboolean masks_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
  (void)widget;
  (void)data;
  if (!capture.editing)
    return FALSE;
  cairo_save(cr);
  cairo_translate(cr, capture.offset_x, capture.offset_y);
  cairo_scale(cr, capture.zoom, capture.zoom);
  cairo_save(cr);
  cairo_rectangle(cr, 0, 0, capture.width, capture.height);
  cairo_rectangle(cr, capture.crop[0], capture.crop[1], capture.crop[2], capture.crop[3]);
  cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
  cairo_clip(cr);
  draw_document(cr, FALSE);
  cairo_set_source_rgba(cr, 0, 0, 0, .42);
  cairo_paint(cr);
  cairo_restore(cr);
  cairo_rectangle(cr, capture.crop[0], capture.crop[1], capture.crop[2], capture.crop[3]);
  cairo_clip(cr);
  for (int i = 0; i < image_session_count(capture.session); i++)
    if ((int)image_session_value(capture.session, i, 0) == REDACT) {
      double r[8];
      read_annotation(i, r);
      draw_shape(cr, REDACT, r, NULL);
    }
  cairo_restore(cr);
  return FALSE;
}
static GdkPixbuf *flatten(void) {
  int width = (int)capture.crop[2], height = (int)capture.crop[3];
  if (width < 2 || height < 2)
    return NULL;
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
  if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(surface);
    return NULL;
  }
  cairo_t *cr = cairo_create(surface);
  cairo_translate(cr, -capture.crop[0], -capture.crop[1]);
  draw_document(cr, TRUE);
  cairo_destroy(cr);
  GdkPixbuf *image = gdk_pixbuf_get_from_surface(surface, 0, 0, width, height);
  cairo_surface_destroy(surface);
  return image;
}
static gboolean copy_image(void) {
  GdkPixbuf *image = flatten();
  if (!image)
    return FALSE;
  GtkClipboard *clipboard = gtk_clipboard_get(
      capture.smoke ? gdk_atom_intern_static_string("MOOJICUT_TEST_IMAGE") : GDK_SELECTION_CLIPBOARD);
  gtk_clipboard_set_image(clipboard, image);
  if (!capture.smoke) {
    gtk_clipboard_set_can_store(clipboard, NULL, 0);
    gtk_clipboard_store(clipboard);
  }
  g_object_unref(image);
  return TRUE;
}
static void sync_crop(void) {
  for (int i = 0; i < 4; i++)
    capture.crop[i] = image_session_viewport_value(capture.session, i);
}
static int context_kind(void) {
  if (capture.editing)
    return TEXT;
  if (capture.selected >= 0)
    return (int)image_session_value(capture.session, capture.selected, 0);
  return capture.tool;
}
static void current_style(double values[4]) {
  values[MC_STYLE_COLOR] = capture.color;
  values[MC_STYLE_OPACITY] = capture.opacity;
  values[MC_STYLE_STROKE] = capture.stroke;
  values[MC_STYLE_FONT] = capture.font_size;
}
static void sync_control_values(void) {
  double values[4];
  current_style(values);
  mc_style_controls_sync(capture.style_controls, editor_style_property_mask(context_kind()), values);
}
static void refresh_context(void) { sync_control_values(); }
static void load_tool_style(int tool) {
  capture.color = (int)editor_style_get(capture.style_bank, tool, MC_STYLE_COLOR);
  capture.opacity = editor_style_get(capture.style_bank, tool, MC_STYLE_OPACITY);
  capture.stroke = (int)editor_style_get(capture.style_bank, tool, MC_STYLE_STROKE);
  capture.font_size = (int)editor_style_get(capture.style_bank, tool, MC_STYLE_FONT);
}
static void sync_style(void) {
  if (capture.selected >= 0) {
    capture.color = (int)image_session_value(capture.session, capture.selected, 5);
    capture.stroke = (int)image_session_value(capture.session, capture.selected, 6);
    capture.opacity = image_session_value(capture.session, capture.selected, 8);
    if ((int)image_session_value(capture.session, capture.selected, 0) == TEXT)
      capture.font_size = (int)image_session_value(capture.session, capture.selected, 7);
  } else if (!capture.editing)
    load_tool_style(capture.tool);
  sync_control_values();
}
static void text_style(void) {
  char *css = g_strdup_printf("textview, textview text {background-color: transparent; color: "
                              "rgba(%d,%d,%d,%.3f); caret-color:#faf5eb; font-family: "
                              "Sans; font-weight: bold; font-size: %.2fpx; padding: 0; border: 0;}",
                              (capture.color >> 16) & 255, (capture.color >> 8) & 255, capture.color & 255,
                              capture.opacity, capture.font_size * capture.zoom);
  GtkCssProvider *provider = gtk_css_provider_new();
  gtk_css_provider_load_from_data(provider, css, -1, NULL);
  gtk_style_context_add_provider(gtk_widget_get_style_context(capture.entry), GTK_STYLE_PROVIDER(provider),
                                 GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  g_object_unref(provider);
  g_free(css);
}
static void begin_text(int index, double x, double y) {
  if (index < 0 && (x >= capture.crop[0] + capture.crop[2] - 8 || y >= capture.crop[1] + capture.crop[3] - 8))
    return;
  if (!commit_text())
    return;
  reset_draft_history();
  capture.editing = TRUE;
  capture.edit_index = index;
  capture.selected = index;
  if (index >= 0) {
    read_annotation(index, capture.preview);
    sync_style();
  } else {
    load_tool_style(TEXT);
    refresh_context();
    double right = capture.crop[0] + capture.crop[2], bottom = capture.crop[1] + capture.crop[3];
    double r[] = {x,
                  y,
                  fmin(240, right - x),
                  fmin(80, bottom - y),
                  capture.color,
                  capture.stroke,
                  capture.font_size,
                  capture.opacity};
    memcpy(capture.preview, r, sizeof(r));
  }
  char *text = index >= 0 ? annotation_text(index) : g_strdup("");
  gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(capture.entry)), text ? text : "", -1);
  g_free(text);
  text_style();
  layout_controls();
  gtk_widget_show(capture.entry);
  gtk_widget_grab_focus(capture.entry);
  gtk_widget_queue_draw(capture.editor);
}
static gboolean commit_text(void) {
  if (capture.composing)
    return FALSE;
  if (!capture.editing)
    return TRUE;
  GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(capture.entry));
  GtkTextIter start, end;
  gtk_text_buffer_get_bounds(buffer, &start, &end);
  char *text = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
  gboolean ok = TRUE;
  if (*text) {
    if (!pending_text(text))
      ok = FALSE;
    else {
      double *r = capture.preview;
      r[4] = capture.color;
      r[6] = capture.font_size;
      r[7] = capture.opacity;
      cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
      cairo_t *cr = cairo_create(s);
      PangoLayout *layout = text_layout(cr, text, r[2], r[6]);
      int h;
      pango_layout_get_pixel_size(layout, NULL, &h);
      r[3] = fmin(capture.height - r[1], fmax(r[3], h + 2));
      g_object_unref(layout);
      cairo_destroy(cr);
      cairo_surface_destroy(s);
      if (capture.edit_index >= 0)
        ok = update_annotation(capture.edit_index, r);
      else {
        ok = image_session_add_rgba(capture.session, TEXT, (int)r[0], (int)r[1], (int)r[2], (int)r[3],
                                    (int)r[4], (int)r[5], (int)r[6], r[7]) == 1;
        if (ok)
          capture.selected = image_session_count(capture.session) - 1;
      }
    }
  } else if (capture.edit_index >= 0) {
    ok = image_session_remove(capture.session, capture.edit_index) == 1;
    capture.selected = -1;
  }
  g_free(text);
  if (!ok) {
    report("文字未能保存。请缩短内容或调整文字框后重试。");
    return FALSE;
  }
  capture.editing = FALSE;
  gtk_widget_hide(capture.entry);
  sync_style();
  gtk_widget_queue_draw(capture.editor);
  return TRUE;
}
static void cancel_text(void) {
  capture.editing = FALSE;
  capture.selected = capture.edit_index;
  sync_style();
  gtk_widget_hide(capture.entry);
  gtk_widget_grab_focus(capture.canvas);
  gtk_widget_queue_draw(capture.editor);
}
static int handle_at(double x, double y, const double *r) {
  return mc_selection_handle_at(selection_rect(r), (MCSelectionPoint){x, y}, capture.zoom);
}
static int hit_test(double x, double y) {
  for (int i = image_session_count(capture.session) - 1; i >= 0; i--) {
    double r[8];
    read_annotation(i, r);
    if (inside(x, y, r))
      return i;
  }
  return -1;
}
static void event_position(double ex, double ey, double *x, double *y) {
  MCSelectionViewport viewport = {capture.offset_x, capture.offset_y, capture.zoom,
                                   capture.width, capture.height};
  MCSelectionPoint point = mc_selection_from_surface((MCSelectionPoint){ex, ey}, viewport);
  *x = point.x;
  *y = point.y;
}
static gboolean canvas_press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)data;
  if (event->button != 1 || capture.zoom <= 0)
    return FALSE;
  if (!commit_text())
    return TRUE;
  double x, y;
  event_position(event->x, event->y, &x, &y);
  gtk_widget_grab_focus(widget);
  mc_selection_begin(&capture.selection, (MCSelectionPoint){x, y}, (MCSelectionRect){0}, -1);
  capture.gesture = 0;
  if (!capture.selecting) {
    if (capture.selected >= 0) {
      read_annotation(capture.selected, capture.original);
      capture.selection.handle = (int)image_session_value(capture.session, capture.selected, 0) == ARROW
                           ? -1
                           : handle_at(x, y, capture.original);
      if (capture.selection.handle >= 0)
        capture.gesture = 1;
    }
    if (capture.gesture == 0 && capture.tool == SELECT) {
      int index = hit_test(x, y);
      capture.selected = index;
      refresh_context();
      if (index >= 0) {
        read_annotation(index, capture.original);
        capture.gesture = 1;
        sync_style();
        if (event->type == GDK_2BUTTON_PRESS && (int)image_session_value(capture.session, index, 0) == TEXT) {
          begin_text(index, x, y);
          return TRUE;
        }
      } else {
        sync_style();
        capture.selection.handle = handle_at(x, y, capture.crop);
        if (capture.selection.handle >= 0 || inside(x, y, capture.crop)) {
          memcpy(capture.original, capture.crop, sizeof(capture.crop));
          capture.gesture = 2;
        }
      }
    }
    if (capture.gesture == 0 && capture.tool == TEXT && inside(x, y, capture.crop)) {
      int index = hit_test(x, y);
      if (index >= 0 && (int)image_session_value(capture.session, index, 0) == TEXT) {
        capture.selected = index;
        sync_style();
        if (event->type == GDK_2BUTTON_PRESS) {
          begin_text(index, x, y);
          return TRUE;
        }
        read_annotation(index, capture.original);
        capture.gesture = 1;
      } else {
        begin_text(-1, x, y);
        return TRUE;
      }
    }
    if (capture.gesture == 0 && capture.tool == SELECT) {
      gtk_widget_queue_draw(widget);
      return TRUE;
    }
    if (!inside(x, y, capture.crop) && capture.gesture == 0)
      return TRUE;
  }
  if (!capture.selecting && !capture.gesture && capture.tool != SELECT && capture.tool != TEXT) {
    capture.selected = -1;
    sync_style();
  }
  capture.selection.original = selection_rect(capture.original);
  memcpy(capture.preview, capture.original, sizeof(capture.preview));
  capture.dragging = TRUE;
  gtk_grab_add(widget);
  gtk_widget_queue_draw(widget);
  return TRUE;
}
static void motion(double x, double y) {
  mc_selection_update(&capture.selection, (MCSelectionPoint){x, y});
  if (capture.gesture) {
    double *r = capture.preview, *o = capture.original;
    memcpy(r, o, sizeof(capture.preview));
    selection_values(mc_selection_transform(&capture.selection, capture.width, capture.height,
                                            capture.gesture == 2 ? 2 : 8), r);
    int handle = capture.selection.handle;
    if (capture.gesture == 1 && handle >= 0 && (handle % 2) == 0 &&
        (int)image_session_value(capture.session, capture.selected, 0) == TEXT)
      r[6] = CLAMP(round(o[6] * fmin(r[2] / o[2], r[3] / o[3])),
                   editor_style_min(MC_STYLE_FONT), editor_style_max(MC_STYLE_FONT));
  }
}
static gboolean canvas_motion(GtkWidget *widget, GdkEventMotion *event, gpointer data) {
  (void)data;
  if (!capture.dragging)
    return FALSE;
  double x, y;
  event_position(event->x, event->y, &x, &y);
  motion(x, y);
  gtk_widget_queue_draw(widget);
  return TRUE;
}
static gboolean finish_selection(void) {
  MCSelectionRect region = mc_selection_region(&capture.selection);
  if (region.width < 2 || region.height < 2)
    return FALSE;
  capture.session = image_session_create_viewport(capture.width, capture.height, (int)region.x,
    (int)region.y, (int)region.width, (int)region.height);
  if (capture.session <= 0)
    return FALSE;
  capture.selecting = FALSE;
  sync_crop();
  gtk_widget_set_no_show_all(capture.toolbar, FALSE);
  gtk_widget_show_all(capture.toolbar);
  layout_controls();
  gtk_widget_queue_draw(capture.canvas);
  return TRUE;
}
static gboolean canvas_release(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)data;
  if (!capture.dragging || event->button != 1)
    return FALSE;
  double x, y;
  event_position(event->x, event->y, &x, &y);
  motion(x, y);
  capture.dragging = FALSE;
  if (gtk_widget_has_grab(widget))
    gtk_grab_remove(widget);
  if (capture.selecting)
    finish_selection();
  else if (capture.gesture == 1) {
    update_annotation(capture.selected, capture.preview);
    sync_style();
  } else if (capture.gesture == 2) {
    image_session_crop(capture.session, (int)capture.preview[0], (int)capture.preview[1],
                       (int)capture.preview[2], (int)capture.preview[3]);
    sync_crop();
  } else if (capture.tool != SELECT && capture.tool != TEXT) {
    MCSelectionRect region = capture.tool == ARROW ? mc_selection_vector(&capture.selection)
                                                    : mc_selection_region(&capture.selection);
    int w = (int)region.width, h = (int)region.height;
    if ((capture.tool == ARROW && abs(w) + abs(h) >= 3) || (w >= 2 && h >= 2))
      image_session_add_rgba(capture.session, capture.tool, (int)region.x, (int)region.y, w, h,
                             capture.color, capture.stroke, capture.font_size, capture.opacity);
  }
  capture.gesture = 0;
  layout_controls();
  gtk_widget_queue_draw(widget);
  return TRUE;
}
static void tool_clicked(GtkWidget *widget, gpointer data) {
  (void)widget;
  if (!commit_text())
    return;
  capture.tool = GPOINTER_TO_INT(data);
  for (int i = 0; i < 5; i++) {
    GtkStyleContext *style = gtk_widget_get_style_context(capture.tools[i]);
    if (i == capture.tool)
      gtk_style_context_add_class(style, "mc-selected");
    else
      gtk_style_context_remove_class(style, "mc-selected");
  }
  capture.selected = -1;
  sync_style();
  gtk_widget_grab_focus(capture.canvas);
  gtk_widget_queue_draw(capture.canvas);
}
static void style_finished(gpointer data) {
  (void)data;
  if (capture.editor && !capture.closing)
    gtk_widget_grab_focus(capture.editing ? capture.entry : capture.canvas);
}
static void style_changed(unsigned fields, const double values[4], gpointer data) {
  (void)data;
  if (capture.closing || capture.composing)
    return;
  fields &= (unsigned)editor_style_property_mask(context_kind());
  gboolean defaults = capture.editing ? capture.edit_index < 0 : capture.selected < 0;
  int tool = capture.editing ? TEXT : capture.tool;
  /* Only edits to an active tool or a new text draft change its future style.
   * Selecting/re-editing an existing object never writes the tool style bank. */
  for (int field = 0; field < 4; field++)
    if (fields & (1u << field)) {
      double value = values[field];
      if (!isfinite(value) || value < editor_style_min(field) || value > editor_style_max(field) ||
          (field != MC_STYLE_OPACITY && value != floor(value))) {
        sync_control_values();
        return;
      }
    }
  if (!fields) {
    sync_control_values();
    return;
  }
  if (defaults)
    for (int field = 0; field < 4; field++)
      if ((fields & (1u << field)) && !editor_style_set(capture.style_bank, tool, field, values[field])) {
        sync_control_values();
        return;
      }
  if (fields & (1u << MC_STYLE_COLOR)) capture.color = (int)values[MC_STYLE_COLOR];
  if (fields & (1u << MC_STYLE_OPACITY)) capture.opacity = values[MC_STYLE_OPACITY];
  if (fields & (1u << MC_STYLE_STROKE)) capture.stroke = (int)values[MC_STYLE_STROKE];
  if (fields & (1u << MC_STYLE_FONT)) capture.font_size = (int)values[MC_STYLE_FONT];
  if (capture.editing)
    text_style();
  else if (capture.selected >= 0) {
    double r[8];
    read_annotation(capture.selected, r);
    r[4] = capture.color;
    r[5] = capture.stroke;
    r[6] = capture.font_size;
    r[7] = capture.opacity;
    if (!update_annotation(capture.selected, r))
      sync_style();
  }
  sync_control_values();
  gtk_widget_queue_draw(capture.editor);
}
static void command(GtkWidget *widget, gpointer data) {
  (void)widget;
  int action = GPOINTER_TO_INT(data);
  if (action == 4) {
    mc_linux_capture_close();
    return;
  }
  if (action == 5 && !capture.host.pin_result)
    return;
  if (!commit_text())
    return;
  if (action == 1 || action == 2) {
    if (action == 1)
      image_session_undo(capture.session);
    else
      image_session_redo(capture.session);
    capture.selected = -1;
    sync_style();
    sync_crop();
    layout_controls();
  }
  if (action == 3) {
    if (copy_image())
      mc_linux_capture_close();
    else
      report("暂时无法复制图片，请重试。");
    return;
  }
  if (action == 5) {
    GdkPixbuf *image = flatten();
    if (image) {
      int origin_x = 0, origin_y = 0;
      gdk_window_get_origin(gtk_widget_get_window(capture.editor), &origin_x, &origin_y);
      GdkRectangle bounds = {origin_x + (int)round(capture.offset_x + capture.crop[0] * capture.zoom),
                             origin_y + (int)round(capture.offset_y + capture.crop[1] * capture.zoom),
                             (int)round(capture.crop[2] * capture.zoom),
                             (int)round(capture.crop[3] * capture.zoom)};
      MCLinuxCaptureHost host = capture.host;
      mc_linux_capture_close();
      if (host.pin_result)
        host.pin_result(image, &bounds, host.data);
      g_object_unref(image);
    }
    return;
  }
  gtk_widget_queue_draw(capture.canvas);
}
static gboolean editor_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)widget;
  (void)data;
  /* Property entries own copy/delete/undo and caret movement while focused.
   * Do not turn their editing shortcuts into document/export commands. */
  GtkWidget *focus = gtk_window_get_focus(GTK_WINDOW(capture.editor));
  if (focus && GTK_IS_EDITABLE(focus))
    return FALSE;
  if (capture.editing) {
    if (capture.composing)
      return FALSE;
    guint key = gdk_keyval_to_lower(event->keyval);
    if ((event->state & GDK_CONTROL_MASK) && (key == GDK_KEY_z || key == GDK_KEY_y)) {
      draft_undo(key == GDK_KEY_y || (event->state & GDK_SHIFT_MASK));
      return TRUE;
    }
    if (event->keyval == GDK_KEY_Escape) {
      cancel_text();
      return TRUE;
    }
    if ((event->state & GDK_CONTROL_MASK) && event->keyval == GDK_KEY_Return) {
      if (commit_text())
        gtk_widget_grab_focus(capture.canvas);
      return TRUE;
    }
    return FALSE;
  }
  if (event->keyval == GDK_KEY_Escape) {
    mc_linux_capture_close();
    return TRUE;
  }
  if (capture.selecting)
    return FALSE;
  if (event->keyval == GDK_KEY_Delete && capture.selected >= 0) {
    image_session_remove(capture.session, capture.selected);
    capture.selected = -1;
    sync_style();
    gtk_widget_queue_draw(capture.canvas);
    return TRUE;
  }
  if (!(event->state & GDK_CONTROL_MASK))
    return FALSE;
  guint key = gdk_keyval_to_lower(event->keyval);
  if (key == GDK_KEY_Return || key == GDK_KEY_c) {
    command(NULL, GINT_TO_POINTER(3));
    return TRUE;
  }
  if (key == GDK_KEY_z || key == GDK_KEY_y) {
    command(NULL, GINT_TO_POINTER(key == GDK_KEY_y || (event->state & GDK_SHIFT_MASK) ? 2 : 1));
    return TRUE;
  }
  return FALSE;
}
static gboolean delete_window(GtkWidget *widget, GdkEvent *event, gpointer data) {
  (void)widget;
  (void)event;
  (void)data;
  mc_linux_capture_close();
  return TRUE;
}
static void layout_controls(void) {
  if (!capture.canvas || !capture.toolbar)
    return;
  refresh_context();
  transform();
  int ww = gtk_widget_get_allocated_width(capture.canvas),
      hh = gtk_widget_get_allocated_height(capture.canvas);
  GtkRequisition size;
  gtk_widget_get_preferred_size(capture.toolbar, &size, NULL);
  int x = CLAMP((int)(capture.offset_x + capture.crop[0] * capture.zoom), 0, MAX(0, ww - size.width));
  int y = (int)(capture.offset_y + (capture.crop[1] + capture.crop[3]) * capture.zoom) + 12;
  if (y + size.height > hh)
    y = MAX(0, (int)(capture.offset_y + capture.crop[1] * capture.zoom) - size.height - 12);
  GdkRectangle toolbar_bounds = {x, y, size.width, size.height};
  gboolean changed = memcmp(&toolbar_bounds, &capture.toolbar_bounds, sizeof(toolbar_bounds)) != 0;
  capture.toolbar_bounds = toolbar_bounds;
  if (capture.editing) {
    double *r = capture.preview;
    GdkRectangle entry_bounds = {(int)(capture.offset_x + r[0] * capture.zoom),
                                 (int)(capture.offset_y + r[1] * capture.zoom),
                                 MAX(8, (int)(r[2] * capture.zoom)), MAX(8, (int)(r[3] * capture.zoom))};
    changed = changed || memcmp(&entry_bounds, &capture.entry_bounds, sizeof(entry_bounds)) != 0;
    capture.entry_bounds = entry_bounds;
  }
  if (changed)
    gtk_widget_queue_resize(capture.overlay);
}
static gboolean overlay_position(GtkOverlay *overlay, GtkWidget *child, GdkRectangle *allocation,
                                 gpointer data) {
  (void)overlay;
  (void)data;
  if (child == capture.toolbar) {
    *allocation = capture.toolbar_bounds;
    return TRUE;
  }
  if (child == capture.entry) {
    *allocation = capture.entry_bounds;
    return TRUE;
  }
  return FALSE;
}
static void size_changed(GtkWidget *widget, GtkAllocation *allocation, gpointer data) {
  (void)widget;
  (void)allocation;
  (void)data;
  layout_controls();
}
static void preedit_changed(GtkTextView *view, const char *text, gpointer data) {
  (void)view;
  (void)data;
  capture.composing = text && *text;
  mc_style_controls_set_blocked(capture.style_controls, capture.composing);
}
static gboolean open_editor(GdkPixbuf *image) {
  int width = gdk_pixbuf_get_width(image), height = gdk_pixbuf_get_height(image);
  if (width < 2 || height < 2 || width > 32768 || height > 32768 || (guint64)width * height > 64000000)
    return FALSE;
  capture.image = g_object_ref(image);
  capture.width = width;
  capture.height = height;
  capture.selected = capture.edit_index = -1;
  capture.tool = SELECT;
  capture.style_bank = editor_style_create();
  if (capture.style_bank <= 0)
    return FALSE;
  load_tool_style(SELECT);
  capture.crop[2] = width;
  capture.crop[3] = height;
  if (!capture.selecting) {
    capture.session = image_session_create_viewport(width, height, 0, 0, width, height);
    if (capture.session <= 0)
      return FALSE;
  }
  /* An X11 override-redirect surface avoids window-manager work-area constraints
   * across the frozen virtual desktop. Portal images use a normal borderless
   * surface because Wayland owns placement and focus. */
  capture.editor =
      capture.x11 ? gtk_window_new(GTK_WINDOW_POPUP) : gtk_application_window_new(capture.application);
  if (capture.x11) {
    gtk_window_set_application(GTK_WINDOW(capture.editor), capture.application);
    gtk_window_set_accept_focus(GTK_WINDOW(capture.editor), TRUE);
  }
  gtk_window_set_title(GTK_WINDOW(capture.editor), "Mooji Cut · 截图标注");
  gtk_window_set_decorated(GTK_WINDOW(capture.editor), FALSE);
  gtk_window_set_keep_above(GTK_WINDOW(capture.editor), TRUE);
  gtk_window_set_skip_taskbar_hint(GTK_WINDOW(capture.editor), TRUE);
  gtk_window_set_default_size(GTK_WINDOW(capture.editor),
                              capture.root_width ? capture.root_width : MIN(width + 40, 1000),
                              capture.root_height ? capture.root_height : MIN(height + 140, 800));
  g_signal_connect(capture.editor, "delete-event", G_CALLBACK(delete_window), NULL);
  g_signal_connect(capture.editor, "key-press-event", G_CALLBACK(editor_key), NULL);
  GtkWidget *overlay = gtk_overlay_new();
  capture.overlay = overlay;
  g_signal_connect(overlay, "get-child-position", G_CALLBACK(overlay_position), NULL);
  gtk_container_add(GTK_CONTAINER(capture.editor), overlay);
  capture.canvas = gtk_drawing_area_new();
  gtk_widget_set_can_focus(capture.canvas, TRUE);
  gtk_container_add(GTK_CONTAINER(overlay), capture.canvas);
  capture.entry = gtk_text_view_new();
  g_signal_connect(capture.entry, "preedit-changed", G_CALLBACK(preedit_changed), NULL);
  GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(capture.entry));
  g_signal_connect(buffer, "begin-user-action", G_CALLBACK(draft_action_begin), NULL);
  g_signal_connect(buffer, "end-user-action", G_CALLBACK(draft_action_end), NULL);
  gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(capture.entry), GTK_WRAP_WORD_CHAR);
  gtk_text_view_set_left_margin(GTK_TEXT_VIEW(capture.entry), 0);
  gtk_text_view_set_right_margin(GTK_TEXT_VIEW(capture.entry), 0);
  gtk_text_view_set_top_margin(GTK_TEXT_VIEW(capture.entry), 0);
  gtk_text_view_set_bottom_margin(GTK_TEXT_VIEW(capture.entry), 0);
  gtk_widget_set_no_show_all(capture.entry, TRUE);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), capture.entry);
  GtkWidget *masks = gtk_drawing_area_new();
  /* The overlay wrapper is pass-through; its child must not create a separate
   * full-screen input window or it would still intercept canvas events. */
  gtk_widget_set_has_window(masks, FALSE);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), masks);
  gtk_overlay_set_overlay_pass_through(GTK_OVERLAY(overlay), masks, TRUE);
  g_signal_connect(masks, "draw", G_CALLBACK(masks_draw), NULL);
  capture.toolbar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
  gtk_widget_set_size_request(capture.toolbar, 500, 92);
  gtk_container_set_border_width(GTK_CONTAINER(capture.toolbar), 0);
  gtk_widget_set_no_show_all(capture.toolbar, TRUE);
  gtk_style_context_add_class(gtk_widget_get_style_context(capture.toolbar), "mc-capture-hud");
  GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
  gtk_box_pack_start(GTK_BOX(capture.toolbar), row, FALSE, FALSE, 0);
  const char *names[] = {"选择 / 移动", "矩形", "箭头", "文字：单击新建，双击编辑", "遮盖"};
  MCIcon icons[] = {MC_ICON_SELECT, MC_ICON_RECTANGLE, MC_ICON_ARROW, MC_ICON_TEXT, MC_ICON_REDACT};
  for (int i = 0; i < 5; i++) {
    capture.tools[i] = mc_style_icon_button(icons[i], names[i], G_CALLBACK(tool_clicked), GINT_TO_POINTER(i));
    gtk_box_pack_start(GTK_BOX(row), capture.tools[i], FALSE, FALSE, 0);
  }
  gtk_style_context_add_class(gtk_widget_get_style_context(capture.tools[0]), "mc-selected");
  gtk_box_pack_start(GTK_BOX(row), mc_style_separator(), FALSE, FALSE, 0);
  MCIcon future_icons[] = {MC_ICON_OCR, MC_ICON_TRANSLATE};
  const char *future_names[] = {"OCR · 尚未开放", "翻译 · 尚未开放"};
  for (int i = 0; i < 2; i++) {
    GtkWidget *wrapper = gtk_event_box_new();
    gtk_event_box_set_visible_window(GTK_EVENT_BOX(wrapper), FALSE);
    gtk_event_box_set_above_child(GTK_EVENT_BOX(wrapper), TRUE);
    capture.future_tools[i] = mc_style_icon_button(future_icons[i], future_names[i], NULL, NULL);
    gtk_widget_set_sensitive(capture.future_tools[i], FALSE);
    gtk_container_add(GTK_CONTAINER(wrapper), capture.future_tools[i]);
    gtk_widget_set_tooltip_text(wrapper, future_names[i]);
    gtk_box_pack_start(GTK_BOX(row), wrapper, FALSE, FALSE, 0);
  }
  gtk_box_pack_start(GTK_BOX(row), mc_style_separator(), FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(row), mc_style_icon_button(MC_ICON_UNDO, "撤销 Ctrl+Z", G_CALLBACK(command), GINT_TO_POINTER(1)), FALSE,
                     FALSE, 0);
  gtk_box_pack_start(GTK_BOX(row), mc_style_icon_button(MC_ICON_REDO, "重做 Ctrl+Shift+Z", G_CALLBACK(command), GINT_TO_POINTER(2)),
                     FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(row), mc_style_separator(), FALSE, FALSE, 0);
  gtk_box_pack_end(GTK_BOX(row), mc_style_icon_button(MC_ICON_CHECK, "确认并复制 Ctrl+Enter", G_CALLBACK(command), GINT_TO_POINTER(3)),
                   FALSE, FALSE, 0);
  gtk_box_pack_end(GTK_BOX(row), mc_style_icon_button(MC_ICON_CLOSE, "取消 Esc", G_CALLBACK(command), GINT_TO_POINTER(4)), FALSE, FALSE,
                   0);
  GtkWidget *pin_button = mc_style_icon_button(MC_ICON_PIN, "固定贴图", G_CALLBACK(command), GINT_TO_POINTER(5));
  gtk_widget_set_sensitive(pin_button, capture.host.pin_result != NULL);
  gtk_box_pack_end(GTK_BOX(row), pin_button, FALSE, FALSE, 0);
  MCStyleRange ranges[4];
  for (int field = 0; field < 4; field++)
    ranges[field] = (MCStyleRange){editor_style_min(field), editor_style_max(field),
      editor_style_step(field), editor_style_default(field), field == MC_STYLE_OPACITY ? 100 : 1};
  capture.style_controls = mc_style_controls_new(GTK_WINDOW(capture.editor), ranges,
                                                 style_changed, style_finished, NULL);
  gtk_box_pack_start(GTK_BOX(capture.toolbar), mc_style_controls_widget(capture.style_controls),
                     FALSE, FALSE, 0);
  sync_control_values();
  mc_style_hud_apply(capture.toolbar);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), capture.toolbar);
  gtk_widget_add_events(capture.canvas,
                        GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK | GDK_POINTER_MOTION_MASK);
  g_signal_connect(capture.canvas, "draw", G_CALLBACK(canvas_draw), NULL);
  g_signal_connect(capture.canvas, "button-press-event", G_CALLBACK(canvas_press), NULL);
  g_signal_connect(capture.canvas, "motion-notify-event", G_CALLBACK(canvas_motion), NULL);
  g_signal_connect(capture.canvas, "button-release-event", G_CALLBACK(canvas_release), NULL);
  g_signal_connect(capture.canvas, "size-allocate", G_CALLBACK(size_changed), NULL);
  gtk_widget_show_all(capture.editor);
  if (!capture.selecting) {
    gtk_widget_set_no_show_all(capture.toolbar, FALSE);
    gtk_widget_show_all(capture.toolbar);
  }
  gtk_widget_grab_focus(capture.canvas);
  layout_controls();
  if (!capture.smoke)
    gtk_window_present(GTK_WINDOW(capture.editor));
  return TRUE;
}
static gboolean start_x11(void) {
  GdkWindow *root = gdk_get_default_root_window();
  int x, y;
  capture.root_width = gdk_window_get_width(root);
  capture.root_height = gdk_window_get_height(root);
  gdk_window_get_origin(root, &x, &y);
  GdkPixbuf *image = gdk_pixbuf_get_from_window(root, 0, 0, capture.root_width, capture.root_height);
  if (!image)
    return FALSE;
  capture.selecting = TRUE;
  capture.x11 = TRUE;
  gboolean ok = open_editor(image);
  g_object_unref(image);
  if (ok) {
    gtk_window_move(GTK_WINDOW(capture.editor), x, y);
    gtk_window_resize(GTK_WINDOW(capture.editor), capture.root_width, capture.root_height);
    gdk_window_focus(gtk_widget_get_window(capture.editor), GDK_CURRENT_TIME);
  }
  return ok;
}
#include "portal.inc"
void mc_linux_capture_start(GtkApplication *application, const MCLinuxCaptureHost *host) {
  if (mc_linux_capture_busy()) {
    if (capture.editor)
      gtk_window_present(GTK_WINDOW(capture.editor));
    return;
  }
  memset(&capture, 0, sizeof(capture));
  capture.application = application;
  if (host)
    capture.host = *host;
  generation++;
  if (GDK_IS_X11_DISPLAY(gdk_display_get_default())) {
    if (!start_x11()) {
      report("无法冻结屏幕，请退出其他截屏操作后重试。");
      mc_linux_capture_close();
    }
  } else
    start_portal();
}
/* Opt-in CI check only: inject pointer input into this synthetic Xvfb fixture.
 * libXtst is dynamically loaded for the test, never a production dependency. */
static void smoke_background(GdkPixbuf *image) {
  int width = gdk_pixbuf_get_width(image), height = gdk_pixbuf_get_height(image);
  int stride = gdk_pixbuf_get_rowstride(image), channels = gdk_pixbuf_get_n_channels(image);
  guchar *pixels = gdk_pixbuf_get_pixels(image);
  for (int y = 0; y < height; y++)
    for (int x = 0; x < width; x++) {
      double horizontal = (double)x / MAX(1, width - 1), vertical = (double)y / MAX(1, height - 1);
      guchar *pixel = pixels + y * stride + x * channels;
      pixel[0] = (guchar)(22 + 37 * horizontal + 5 * vertical);
      pixel[1] = (guchar)(29 + 6 * horizontal + 43 * vertical);
      pixel[2] = (guchar)(49 + 30 * horizontal + 13 * vertical);
    }
}
static gboolean smoke_pump_timeout(gpointer data) {
  *(gboolean *)data = TRUE;
  return G_SOURCE_REMOVE;
}
static void smoke_pump(void) {
  gboolean elapsed = FALSE;
  gint64 deadline = g_get_monotonic_time() + 100000;
  guint timer = g_timeout_add(100, smoke_pump_timeout, &elapsed);
  gdk_display_sync(gdk_display_get_default());
  while (!elapsed && g_get_monotonic_time() < deadline)
    g_main_context_iteration(NULL, TRUE);
  if (!elapsed)
    g_source_remove(timer);
}
static void smoke_style_step(int field, gboolean increase) {
  gtk_button_clicked(GTK_BUTTON(mc_style_controls_step_button(capture.style_controls, field, increase)));
}
static void smoke_style_number(int field, const char *text) {
  gtk_entry_set_text(GTK_ENTRY(mc_style_controls_entry(capture.style_controls, field)), text);
}
static gboolean smoke_style_key(int field, GdkEventKey *event) {
  gboolean handled = FALSE;
  g_signal_emit_by_name(mc_style_controls_entry(capture.style_controls, field),
                        "key-press-event", event, &handled);
  return handled;
}
typedef struct { int closed, results; gboolean valid; } CaptureHostProbe;
static void smoke_host_closed(gpointer data) { ((CaptureHostProbe *)data)->closed++; }
static void smoke_host_pin(GdkPixbuf *image, const GdkRectangle *bounds, gpointer data) {
  CaptureHostProbe *probe = data;
  probe->results++;
  probe->valid = probe->closed == 1 && image && bounds && bounds->width > 0 && bounds->height > 0 &&
                 !mc_linux_capture_busy();
}
static void smoke_style_rgba(int color, double opacity) {
  double values[4];
  current_style(values);
  values[MC_STYLE_COLOR] = color;
  values[MC_STYLE_OPACITY] = opacity;
  style_changed((1u << MC_STYLE_COLOR) | (1u << MC_STYLE_OPACITY), values, NULL);
}
static gboolean smoke_tool_styles(void) {
  int original_session = capture.session;
  capture.session = image_session_create(capture.width, capture.height);
  if (capture.session <= 0) {
    capture.session = original_session;
    return FALSE;
  }
  tool_clicked(NULL, GINT_TO_POINTER(RECTANGLE));
  smoke_style_rgba(0x225577, .45);
  smoke_style_number(MC_STYLE_STROKE, "8");
  tool_clicked(NULL, GINT_TO_POINTER(ARROW));
  gboolean ok = capture.color == editor_style_default(MC_STYLE_COLOR) && capture.opacity == 1 &&
                capture.stroke == editor_style_default(MC_STYLE_STROKE);
  smoke_style_rgba(0x66BB88, .7);
  smoke_style_number(MC_STYLE_STROKE, "12");
  tool_clicked(NULL, GINT_TO_POINTER(REDACT));
  ok = capture.color == 0x111111 && capture.opacity == 1 && ok;
  smoke_style_rgba(0xCC8844, .25);
  tool_clicked(NULL, GINT_TO_POINTER(TEXT));
  ok = capture.font_size == editor_style_default(MC_STYLE_FONT) && ok;
  smoke_style_rgba(0xABCDEF, .8);
  smoke_style_number(MC_STYLE_FONT, "40");
  tool_clicked(NULL, GINT_TO_POINTER(RECTANGLE));
  ok = capture.color == 0x225577 && fabs(capture.opacity - .45) < .00001 && capture.stroke == 8 && ok;
  ok = image_session_add_rgba(capture.session, RECTANGLE, 50, 60, 80, 60,
                               capture.color, capture.stroke, capture.font_size, capture.opacity) == 1 && ok;
  capture.selected = 0;
  sync_style();
  smoke_style_rgba(0xFF3355, .2);
  smoke_style_number(MC_STYLE_STROKE, "6");
  ok = image_session_value(capture.session, 0, 5) == 0xFF3355 &&
       fabs(image_session_value(capture.session, 0, 8) - .2) < .00001 &&
       editor_style_get(capture.style_bank, RECTANGLE, MC_STYLE_COLOR) == 0x225577 && ok;
  tool_clicked(NULL, GINT_TO_POINTER(ARROW));
  ok = capture.color == 0x66BB88 && fabs(capture.opacity - .7) < .00001 && capture.stroke == 12 && ok;
  tool_clicked(NULL, GINT_TO_POINTER(RECTANGLE));
  ok = capture.color == 0x225577 && capture.stroke == 8 && ok;
  GdkEventButton gesture = {0};
  gesture.button = 1;
  gesture.x = capture.offset_x + 250 * capture.zoom;
  gesture.y = capture.offset_y + 180 * capture.zoom;
  ok = canvas_press(capture.canvas, &gesture, NULL) && ok;
  gesture.x = capture.offset_x + 300 * capture.zoom;
  gesture.y = capture.offset_y + 220 * capture.zoom;
  ok = canvas_release(capture.canvas, &gesture, NULL) &&
       image_session_count(capture.session) == 2 &&
       image_session_value(capture.session, 1, 5) == 0x225577 &&
       image_session_value(capture.session, 1, 6) == 8 &&
       fabs(image_session_value(capture.session, 1, 8) - .45) < .00001 &&
       image_session_value(capture.session, 0, 5) == 0xFF3355 && ok;
  tool_clicked(NULL, GINT_TO_POINTER(TEXT));
  begin_text(-1, 150, 100);
  ok = capture.color == 0xABCDEF && capture.font_size == 40 && ok;
  gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(capture.entry)), "新文字", -1);
  smoke_style_rgba(0xAA7744, .6);
  smoke_style_number(MC_STYLE_FONT, "42");
  ok = commit_text() && editor_style_get(capture.style_bank, TEXT, MC_STYLE_COLOR) == 0xAA7744 &&
       editor_style_get(capture.style_bank, TEXT, MC_STYLE_FONT) == 42 && ok;
  int text_index = image_session_count(capture.session) - 1;
  begin_text(text_index, 0, 0);
  smoke_style_rgba(0x778899, .3);
  smoke_style_number(MC_STYLE_FONT, "36");
  ok = commit_text() && image_session_value(capture.session, text_index, 5) == 0x778899 &&
       editor_style_get(capture.style_bank, TEXT, MC_STYLE_COLOR) == 0xAA7744 &&
       editor_style_get(capture.style_bank, TEXT, MC_STYLE_FONT) == 42 && ok;
  begin_text(-1, 200, 120);
  ok = capture.color == 0xAA7744 && capture.font_size == 42 && fabs(capture.opacity - .6) < .00001 && ok;
  cancel_text();
  tool_clicked(NULL, GINT_TO_POINTER(REDACT));
  ok = capture.color == 0xCC8844 && fabs(capture.opacity - .25) < .00001 && ok;
  image_session_dispose(capture.session);
  capture.session = original_session;
  editor_style_dispose(capture.style_bank);
  capture.style_bank = editor_style_create();
  tool_clicked(NULL, GINT_TO_POINTER(SELECT));
  g_print("Linux tool styles smoke %s: independent defaults, existing-object isolation, new/old text drafts.\n",
           ok ? "passed" : "FAILED");
  return ok;
}
static gboolean smoke_pointer_route(GtkApplication *application) {
  if (g_strcmp0(g_getenv("MOOJICUT_X11_INPUT_SMOKE"), "1") != 0)
    return TRUE;
  if (!GDK_IS_X11_DISPLAY(gdk_display_get_default())) {
    g_printerr("XTest fixture: an X11/Xvfb display is required\n");
    return FALSE;
  }
  void *library = dlopen("libXtst.so.6", RTLD_NOW | RTLD_LOCAL);
  if (!library) {
    g_printerr("XTest fixture: libXtst.so.6 unavailable\n");
    return FALSE;
  }
  typedef int (*MotionFn)(Display *, int, int, int, unsigned long);
  typedef int (*ButtonFn)(Display *, unsigned int, int, unsigned long);
  MotionFn motion_event = (MotionFn)dlsym(library, "XTestFakeMotionEvent");
  ButtonFn button_event = (ButtonFn)dlsym(library, "XTestFakeButtonEvent");
  gboolean ok = motion_event && button_event;
  if (!ok) {
    g_printerr("XTest fixture: required event entry points unavailable\n");
    dlclose(library);
    return FALSE;
  }
  memset(&capture, 0, sizeof(capture));
  capture.application = application;
  CaptureHostProbe host_probe = {0};
  capture.host = (MCLinuxCaptureHost){smoke_host_pin, smoke_host_closed, &host_probe};
  capture.smoke = capture.selecting = capture.x11 = TRUE;
  capture.root_width = 640;
  capture.root_height = 400;
  GdkPixbuf *source = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, 640, 400);
  if (!source) {
    mc_linux_capture_close();
    dlclose(library);
    return FALSE;
  }
  smoke_background(source);
  ok = open_editor(source);
  g_object_unref(source);
  if (!ok) {
    mc_linux_capture_close();
    dlclose(library);
    return FALSE;
  }
  GdkWindow *window = gtk_widget_get_window(capture.editor);
  gdk_window_focus(window, GDK_CURRENT_TIME);
  smoke_pump();
  int ox, oy;
  gdk_window_get_origin(window, &ox, &oy);
  Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
  motion_event(display, -1, ox + 20, oy + 30, 0);
  button_event(display, 1, TRUE, 0);
  smoke_pump();
  motion_event(display, -1, ox + 300, oy + 230, 0);
  smoke_pump();
  button_event(display, 1, FALSE, 0);
  smoke_pump();
  ok = !capture.selecting && capture.crop[0] == 20 && capture.crop[1] == 30 && capture.crop[2] == 280 &&
       capture.crop[3] == 200;
  if (!ok) {
    GdkDevice *pointer = gdk_seat_get_pointer(gdk_display_get_default_seat(gdk_display_get_default()));
    GdkWindow *target = gdk_device_get_window_at_position(pointer, NULL, NULL);
    gpointer owner = NULL;
    if (target)
      gdk_window_get_user_data(target, &owner);
    g_printerr("XTest fixture: selection failed, target=%s selecting=%d points=%.0f,%.0f -> %.0f,%.0f "
               "crop=%.0f,%.0f %.0fx%.0f zoom=%.2f origin=%d,%d\n",
               owner && GTK_IS_WIDGET(owner) ? G_OBJECT_TYPE_NAME(owner) : "none", capture.selecting,
               capture.selection.anchor.x, capture.selection.anchor.y, capture.selection.current.x, capture.selection.current.y, capture.crop[0], capture.crop[1],
               capture.crop[2], capture.crop[3], capture.zoom, ox, oy);
  }
  if (ok)
    for (int i = 0; i < 2; i++) {
      int x, y;
      GtkWidget *button = capture.future_tools[i];
      gtk_widget_translate_coordinates(button, capture.editor, gtk_widget_get_allocated_width(button) / 2,
                                       gtk_widget_get_allocated_height(button) / 2, &x, &y);
      motion_event(display, -1, ox + x, oy + y, 0);
      button_event(display, 1, TRUE, 0);
      button_event(display, 1, FALSE, 0);
      smoke_pump();
      ok = capture.editor && capture.tool == SELECT && !capture.editing && ok;
      if (!ok)
        g_printerr("XTest fixture: disabled future action changed capture state\n");
    }
  if (ok) {
    int x, y;
    GtkWidget *button = capture.tools[TEXT];
    gtk_widget_translate_coordinates(button, capture.editor, gtk_widget_get_allocated_width(button) / 2,
                                     gtk_widget_get_allocated_height(button) / 2, &x, &y);
    motion_event(display, -1, ox + x, oy + y, 0);
    button_event(display, 1, TRUE, 0);
    button_event(display, 1, FALSE, 0);
    smoke_pump();
    ok = capture.tool == TEXT;
    if (!ok)
      g_printerr("XTest fixture: toolbar click routing failed\n");
  }
  if (ok) {
    motion_event(display, -1, ox + 100, oy + 100, 0);
    button_event(display, 1, TRUE, 0);
    button_event(display, 1, FALSE, 0);
    smoke_pump();
    ok = capture.editing && gtk_window_get_focus(GTK_WINDOW(capture.editor)) == capture.entry;
    if (!ok)
      g_printerr("XTest fixture: inline text activation/focus failed\n");
  }
  if (ok) {
    motion_event(display, -1, ox + 110, oy + 110, 0);
    button_event(display, 1, TRUE, 0);
    button_event(display, 1, FALSE, 0);
    smoke_pump();
    ok = capture.editing && gtk_window_get_focus(GTK_WINDOW(capture.editor)) == capture.entry;
    if (!ok)
      g_printerr("XTest fixture: inline native TextView pointer routing failed\n");
  }
  if (ok) {
    int x, y;
    GtkWidget *button = mc_style_controls_step_button(capture.style_controls, MC_STYLE_FONT, TRUE);
    int previous = capture.font_size;
    gtk_widget_translate_coordinates(button, capture.editor, gtk_widget_get_allocated_width(button) / 2,
                                     gtk_widget_get_allocated_height(button) / 2, &x, &y);
    motion_event(display, -1, ox + x, oy + y, 0);
    button_event(display, 1, TRUE, 0);
    button_event(display, 1, FALSE, 0);
    smoke_pump();
    ok = capture.editing && capture.font_size == previous + 1 &&
         gtk_window_get_focus(GTK_WINDOW(capture.editor)) == capture.entry;
    if (!ok)
      g_printerr("XTest fixture: font stepper failed or stole inline text focus\n");
  }
  mc_linux_capture_close();
  ok = host_probe.closed == 1 && host_probe.results == 0 && ok;
  dlclose(library);
  g_print("Linux XTest pointer fixture %s: frozen canvas, toolbar, inline text focus.\n",
          ok ? "passed" : "FAILED");
  return ok;
}
gboolean mc_linux_capture_smoke(GtkApplication *application) {
  if (mc_linux_capture_busy())
    return FALSE;
  memset(&capture, 0, sizeof(capture));
  capture.application = application;
  CaptureHostProbe host_probe = {0};
  capture.host = (MCLinuxCaptureHost){smoke_host_pin, smoke_host_closed, &host_probe};
  capture.smoke = TRUE;
  capture.selecting = TRUE;
  capture.x11 = GDK_IS_X11_DISPLAY(gdk_display_get_default());
  capture.root_width = 640;
  capture.root_height = 400;
  GdkPixbuf *source = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, 640, 400);
  if (!source) {
    mc_linux_capture_close();
    return FALSE;
  }
  smoke_background(source);
  gboolean controls_ok = mc_style_controls_smoke();
  gboolean ok = open_editor(source);
  g_object_unref(source);
  if (!ok) {
    mc_linux_capture_close();
    return FALSE;
  }
  while (gtk_events_pending())
    gtk_main_iteration();
  ok = controls_ok && ok;
  GtkWidget *original = capture.editor;
  GdkEventButton selection_event = {0};
  selection_event.button = 1;
  selection_event.x = capture.offset_x + 350 * capture.zoom;
  selection_event.y = capture.offset_y + 250 * capture.zoom;
  ok = canvas_press(capture.canvas, &selection_event, NULL) && ok;
  selection_event.x = capture.offset_x + 30 * capture.zoom;
  selection_event.y = capture.offset_y + 50 * capture.zoom;
  ok = canvas_release(capture.canvas, &selection_event, NULL) && !capture.selecting &&
       capture.editor == original && !gtk_window_get_decorated(GTK_WINDOW(original)) && ok;
  ok = smoke_tool_styles() && ok;
  ok = (editor_style_property_mask(context_kind()) == 0) && !mc_style_controls_property_visible(capture.style_controls, MC_STYLE_COLOR) &&
       !mc_style_controls_property_visible(capture.style_controls, MC_STYLE_FONT) && ok;
  tool_clicked(NULL, GINT_TO_POINTER(TEXT));
  ok = mc_style_controls_property_visible(capture.style_controls, MC_STYLE_COLOR) && mc_style_controls_property_visible(capture.style_controls, MC_STYLE_FONT) &&
       !mc_style_controls_property_visible(capture.style_controls, MC_STYLE_STROKE) && ok;
  smoke_style_step(MC_STYLE_FONT, TRUE);
  ok = capture.font_size == editor_style_default(MC_STYLE_FONT) + editor_style_step(MC_STYLE_FONT) && image_session_count(capture.session) == 0 && ok;
  smoke_style_step(MC_STYLE_FONT, FALSE);
  tool_clicked(NULL, GINT_TO_POINTER(RECTANGLE));
  ok = mc_style_controls_property_visible(capture.style_controls, MC_STYLE_COLOR) && mc_style_controls_property_visible(capture.style_controls, MC_STYLE_STROKE) &&
       !mc_style_controls_property_visible(capture.style_controls, MC_STYLE_FONT) && ok;
  smoke_style_number(MC_STYLE_STROKE, "8");
  ok = capture.stroke == 8 && ok;
  smoke_style_number(MC_STYLE_STROKE, "4");
  tool_clicked(NULL, GINT_TO_POINTER(REDACT));
  ok = !(editor_style_property_mask(context_kind()) == 0) && mc_style_controls_property_visible(capture.style_controls, MC_STYLE_COLOR) &&
       mc_style_controls_property_visible(capture.style_controls, MC_STYLE_OPACITY) && !mc_style_controls_property_visible(capture.style_controls, MC_STYLE_FONT) &&
       !mc_style_controls_property_visible(capture.style_controls, MC_STYLE_STROKE) && ok;
  for (int i = 0; i < 2; i++) {
    AtkStateSet *state = atk_object_ref_state_set(gtk_widget_get_accessible(capture.future_tools[i]));
    char *tip = gtk_widget_get_tooltip_text(gtk_widget_get_parent(capture.future_tools[i]));
    ok = !atk_state_set_contains_state(state, ATK_STATE_ENABLED) && tip && strstr(tip, "尚未开放") && ok;
    g_free(tip);
    g_object_unref(state);
  }
  tool_clicked(NULL, GINT_TO_POINTER(SELECT));
  begin_text(-1, 60, 80);
  gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(capture.entry)), "截图 MoonBit ✅\n第二行",
                           -1);
  GtkTextBuffer *draft_buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(capture.entry));
  gtk_text_buffer_begin_user_action(draft_buffer);
  gtk_text_buffer_insert_at_cursor(draft_buffer, "追加", -1);
  gtk_text_buffer_end_user_action(draft_buffer);
  draft_undo(FALSE);
  TextSnapshot *draft = snapshot_text();
  ok = strstr(draft->text, "追加") == NULL && image_session_count(capture.session) == 0 && ok;
  snapshot_free(draft);
  draft_undo(TRUE);
  draft = snapshot_text();
  ok = strstr(draft->text, "追加") != NULL && ok;
  snapshot_free(draft);
  draft_undo(FALSE);
  gtk_widget_grab_focus(mc_style_controls_entry(capture.style_controls, MC_STYLE_FONT));
  guint undo_count = capture.draft_undo->len;
  GdkEventKey property_key = {0};
  property_key.state = GDK_CONTROL_MASK;
  property_key.keyval = GDK_KEY_z;
  ok = !editor_key(capture.editor, &property_key, NULL) && capture.draft_undo->len == undo_count &&
       capture.editing && ok;
  property_key.keyval = GDK_KEY_c;
  ok = !editor_key(capture.editor, &property_key, NULL) && capture.editor && capture.editing && ok;
  property_key.state = 0;
  property_key.keyval = GDK_KEY_Delete;
  ok = !editor_key(capture.editor, &property_key, NULL) && capture.editing && ok;
  property_key.keyval = GDK_KEY_Up;
  int before_font = capture.font_size;
  ok = smoke_style_key(MC_STYLE_FONT, &property_key) && capture.font_size == before_font + 1 && ok;
  property_key.keyval = GDK_KEY_Down;
  smoke_style_key(MC_STYLE_FONT, &property_key);
  property_key.keyval = GDK_KEY_Escape;
  ok = smoke_style_key(MC_STYLE_FONT, &property_key) &&
       gtk_window_get_focus(GTK_WINDOW(capture.editor)) == capture.entry && ok;
  preedit_changed(GTK_TEXT_VIEW(capture.entry), "拼", NULL);
  before_font = capture.font_size;
  smoke_style_step(MC_STYLE_FONT, TRUE);
  ok = capture.font_size == before_font && ok;
  GdkEventKey ime_key = {0};
  ime_key.keyval = GDK_KEY_Escape;
  ok = !editor_key(capture.editor, &ime_key, NULL) && capture.editing && !commit_text() && ok;
  preedit_changed(GTK_TEXT_VIEW(capture.entry), "", NULL);
  ok = commit_text() && ok;
  ok = image_session_count(capture.session) == 1 && ok;
  begin_text(0, 0, 0);
  gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(capture.entry)), "改过的文字", -1);
  ok = commit_text() && ok;
  char *text = annotation_text(0);
  ok = g_strcmp0(text, "改过的文字") == 0 && ok;
  g_free(text);
  ok = image_session_undo(capture.session) == 1 && ok;
  text = annotation_text(0);
  ok = text && strstr(text, "MoonBit") && ok;
  g_free(text);
  image_session_redo(capture.session);
  GdkEventButton gesture = {0};
  gesture.button = 1;
  gesture.x = capture.offset_x + 100 * capture.zoom;
  gesture.y = capture.offset_y + 100 * capture.zoom;
  ok = canvas_press(capture.canvas, &gesture, NULL) && ok;
  GdkEventMotion move = {0};
  move.x = gesture.x + 15 * capture.zoom;
  move.y = gesture.y + 10 * capture.zoom;
  ok = canvas_motion(capture.canvas, &move, NULL) && ok;
  gesture.x = move.x;
  gesture.y = move.y;
  ok = canvas_release(capture.canvas, &gesture, NULL) && image_session_value(capture.session, 0, 1) == 75 &&
       ok;
  text = annotation_text(0);
  ok = g_strcmp0(text, "改过的文字") == 0 && ok;
  g_free(text);
  double r[8];
  read_annotation(0, r);
  r[2] = 100;
  r[4] = 0x225577;
  r[6] = 32;
  ok = update_annotation(0, r) && image_session_value(capture.session, 0, 7) == 32 && ok;
  sync_style();
  ok = mc_style_controls_property_visible(capture.style_controls, MC_STYLE_FONT) && mc_style_controls_property_visible(capture.style_controls, MC_STYLE_COLOR) &&
       !mc_style_controls_property_visible(capture.style_controls, MC_STYLE_STROKE) && ok;
  smoke_style_step(MC_STYLE_FONT, TRUE);
  ok = image_session_value(capture.session, 0, 7) == 33 && ok;
  image_session_undo(capture.session);
  sync_style();
  ok = capture.font_size == 32 && ok;
  gtk_entry_set_text(GTK_ENTRY(mc_style_controls_entry(capture.style_controls, MC_STYLE_FONT)), "40");
  ok = image_session_value(capture.session, 0, 7) == 40 && ok;
  gtk_widget_grab_focus(mc_style_controls_entry(capture.style_controls, MC_STYLE_FONT));
  int annotation_count = image_session_count(capture.session);
  property_key.keyval = GDK_KEY_Delete;
  property_key.state = 0;
  ok = !editor_key(capture.editor, &property_key, NULL) &&
       image_session_count(capture.session) == annotation_count && ok;
  property_key.keyval = GDK_KEY_c;
  property_key.state = GDK_CONTROL_MASK;
  ok = !editor_key(capture.editor, &property_key, NULL) && capture.editor &&
       image_session_count(capture.session) == annotation_count && ok;
  gtk_widget_grab_focus(capture.canvas);
  gtk_entry_set_text(GTK_ENTRY(mc_style_controls_entry(capture.style_controls, MC_STYLE_FONT)), "999");
  sync_control_values();
  ok = !strcmp(gtk_entry_get_text(GTK_ENTRY(mc_style_controls_entry(capture.style_controls, MC_STYLE_FONT))), "40") && ok;
  image_session_undo(capture.session);
  sync_style();
  ok = image_session_add(capture.session, REDACT, 50, 60, 80, 60, 0, 4) == 1 && ok;
  GdkPixbuf *image = flatten();
  ok = image && gdk_pixbuf_get_width(image) == 320 && gdk_pixbuf_get_height(image) == 200 && ok;
  if (image) {
    const guchar *p = gdk_pixbuf_get_pixels(image) + 30 * gdk_pixbuf_get_rowstride(image) +
                      30 * gdk_pixbuf_get_n_channels(image);
    ok = p[0] == 0 && p[1] == 0 && p[2] == 0 && ok;
    g_object_unref(image);
  }
  ok = copy_image() && ok;
  GtkClipboard *clip = gtk_clipboard_get(gdk_atom_intern_static_string("MOOJICUT_TEST_IMAGE"));
  image = gtk_clipboard_wait_for_image(clip);
  ok = image && gdk_pixbuf_get_width(image) == 320 && ok;
  g_clear_object(&image);
  gtk_clipboard_clear(clip);
  /* A translucent colored cover must blend once on the source, including the
   * blank portion of an active native text editor, and preserve alpha on move. */
  ok = image_session_add_rgba(capture.session, REDACT, 180, 160, 80, 50, 0xFF0000, 4, 24, .5) == 1 && ok;
  int cover = image_session_count(capture.session) - 1;
  double cover_rect[8];
  read_annotation(cover, cover_rect);
  cover_rect[0] += 5;
  ok = update_annotation(cover, cover_rect) && image_session_value(capture.session, cover, 8) == .5 && ok;
  const guchar *source_pixel = gdk_pixbuf_get_pixels(capture.image) +
                               180 * gdk_pixbuf_get_rowstride(capture.image) +
                               210 * gdk_pixbuf_get_n_channels(capture.image);
  int expected[3] = {(source_pixel[0] + 255 + 1) / 2, (source_pixel[1] + 1) / 2, (source_pixel[2] + 1) / 2};
  image = flatten();
  if (image) {
    const guchar *pixel = gdk_pixbuf_get_pixels(image) +
                          (180 - (int)capture.crop[1]) * gdk_pixbuf_get_rowstride(image) +
                          (210 - (int)capture.crop[0]) * gdk_pixbuf_get_n_channels(image);
    for (int c = 0; c < 3; c++)
      ok = abs(pixel[c] - expected[c]) <= 1 && ok;
    g_object_unref(image);
  } else
    ok = FALSE;
  begin_text(-1, 190, 170);
  gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(capture.entry)), "", -1);
  cairo_surface_t *live = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, capture.width, capture.height);
  cairo_t *live_cr = cairo_create(live);
  draw_document(live_cr, FALSE);
  cairo_save(live_cr);
  cairo_scale(live_cr, 1 / capture.zoom, 1 / capture.zoom);
  cairo_translate(live_cr, -capture.offset_x, -capture.offset_y);
  masks_draw(NULL, live_cr, NULL);
  cairo_restore(live_cr);
  cairo_destroy(live_cr);
  GdkPixbuf *live_image = gdk_pixbuf_get_from_surface(live, 0, 0, capture.width, capture.height);
  cairo_surface_destroy(live);
  if (live_image) {
    const guchar *pixel = gdk_pixbuf_get_pixels(live_image) + 180 * gdk_pixbuf_get_rowstride(live_image) +
                          210 * gdk_pixbuf_get_n_channels(live_image);
    for (int c = 0; c < 3; c++)
      ok = abs(pixel[c] - expected[c]) <= 1 && ok;
    g_object_unref(live_image);
  } else
    ok = FALSE;
  cancel_text();
  image_session_undo(capture.session);
  image_session_undo(capture.session);
  capture.selected = 0;
  sync_style();
  smoke_style_number(MC_STYLE_OPACITY, "35");
  read_annotation(0, r);
  r[0] += 1;
  ok = update_annotation(0, r) && fabs(image_session_value(capture.session, 0, 8) - .35) < .001 && ok;
  image_session_undo(capture.session);
  image_session_undo(capture.session);
  sync_style();
  ok = image_session_crop(capture.session, 40, 60, 200, 120) == 1 && ok;
  sync_crop();
  image = flatten();
  ok = image && gdk_pixbuf_get_width(image) == 200 && ok;
  g_clear_object(&image);
  image_session_undo(capture.session);
  sync_crop();
  ok = capture.crop[2] == 320 && ok;
  const char *preview_path = g_getenv("MOOJICUT_SMOKE_SCREENSHOT");
  if (preview_path && *preview_path) {
    /* Readable synthetic preview, after all behavior and privacy pixel checks.
     * It uses the same document and native renderer as interactive capture. */
    if (pending_text("原地编辑"))
      image_session_update(capture.session, 0, 150, 100, 180, 70, 0xF26769, 4, 32);
    image_session_crop(capture.session, 30, 50, 440, 200);
    capture.selected = 0;
    sync_crop();
    sync_style();
    layout_controls();
    gtk_widget_queue_draw(capture.editor);
    while (gtk_events_pending())
      gtk_main_iteration();
    GdkWindow *window = gtk_widget_get_window(capture.editor);
    GdkPixbuf *preview = window ? gdk_pixbuf_get_from_window(window, 0, 0, gdk_window_get_width(window),
                                                             gdk_window_get_height(window))
                                : NULL;
    char *path = g_strconcat(preview_path, ".capture.png", NULL);
    ok = preview && gdk_pixbuf_save(preview, path, "png", NULL, NULL) && ok;
    g_free(path);
    g_clear_object(&preview);
  }
  command(NULL, GINT_TO_POINTER(5));
  ok = host_probe.closed == 1 && host_probe.results == 1 && host_probe.valid && ok;
  mc_linux_capture_close();
  ok = host_probe.closed == 1 && ok;
  gboolean geometry_ok = mc_selection_smoke();
  g_print("Linux selection geometry smoke %s: reverse regions, zoom hit areas, bounds, signed arrows.\n",
           geometry_ok ? "passed" : "FAILED");
  ok = geometry_ok && ok;
  ok = smoke_pointer_route(application) && ok;
  g_print("Linux screenshot/selection smoke %s: retained overlay, inline multilingual text/re-edit/undo/style, "
          "crop export, masks, private clipboard, selection geometry.\n",
          ok ? "passed" : "FAILED");
  return ok;
}
