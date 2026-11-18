#include "capture.h"
#include "bindings/c/image_session.h"
#include "bindings/c/capture_ui.h"
#include "bindings/c/capture_toolbar.h"
#include "bindings/c/capture_edit.h"
#include "platform/linux/graphics/text_input.h"
#include "platform/linux/graphics/shared_canvas.h"
#include "platform/linux/graphics/hud.h"
#include "bindings/c/tool_registry.h"
#include "platform/shared/image/pixelate.h"
#include "moonbit.h"
#include "plugins/feature/select/linux/selection.h"
#include "bindings/c/editor_style.h"
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
  int session, edit, version;
} ColorRequest;
typedef struct {
  GtkApplication *application;
  MCLinuxCaptureHost host;
  GtkWidget *editor, *canvas, *overlay, *toolbar, *entry, *toolbar_canvas;
  int toolbar_handle, toolbar_generation, toolbar_frame, prepared_snapshot;
  gboolean toolbar_dark;
  char *tool_command, *drag_annotation_id;
  double drag_revision;
  int style_bank;
  GdkPixbuf *image;
  GdkRectangle toolbar_bounds, entry_bounds;
  MCLinuxTextInputs *body_inputs, *property_inputs;
  GtkWidget *body_fixed, *property_overlay, *property_canvas, *color_dialog;
  /* The shared edit owner also covers non-text property drafts. */
  int text_edit, prepared_tool_candidate;
  gboolean syncing_text, ending_text, pointer_dispatch;
  guint text_blur_idle;
  GDBusConnection *bus;
  char *request_path;
  guint subscription;
  int session, tool, color, width, height, root_width, root_height;
  double font_size, stroke;
  int selected, edit_index, gesture, shape, block;
  MCSelectionDrag selection;
  double zoom, offset_x, offset_y, opacity, crop[4], original[10], preview[10];
  gboolean dragging, pending, smoke, closing, selecting, editing, composing, x11;
} Capture;
static Capture capture;
static guint generation;
/* The application owns published snapshots; shared toolbar sessions copy descriptors. */
static int published_tools;

static gboolean open_editor(GdkPixbuf *image);
static gboolean commit_text(void);
static void layout_controls(void);
static void refresh_context(void);
static void sync_control_values(void);
static void draw_document(cairo_t *cr, gboolean export);
static gboolean open_toolbar(void);
static gboolean toolbar_context(void);
static gboolean pin_available(void);
static gboolean toolbar_activate(const char *id);
static void sync_toolbar_tool(void);
static void sync_style(void);
static void sync_text(void);
static void cancel_text(void);
static double text_measurement(void);
static int text_version(void);
static gboolean text_event(moonbit_string_t event);
static void end_text_controls(void);
static gboolean start_text_transaction(int mode, int index, double x, double y, double w, double h);
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
static moonbit_string_t core_string(const char *text) {
  glong length = 0;
  gunichar2 *value = g_utf8_to_utf16(text ? text : "", -1, NULL, &length, NULL);
  moonbit_string_t result = moonbit_make_string_raw((int32_t)length);
  if (length) memcpy(result, value, (gsize)length * sizeof(gunichar2));
  g_free(value); return result;
}
static char *core_text(moonbit_string_t value) {
  char *text = g_utf16_to_utf8((const gunichar2 *)value, Moonbit_array_length(value), NULL, NULL, NULL);
  moonbit_decref(value); return text ? text : g_strdup("");
}
static void draft_undo(gboolean redo) {
  if (capture.entry) mc_linux_text_inputs_history(capture.body_inputs, capture.entry, redo);
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
  end_text_controls();
  mc_linux_text_inputs_destroy(capture.body_inputs); capture.body_inputs = NULL;
  mc_linux_text_inputs_destroy(capture.property_inputs); capture.property_inputs = NULL;
  GtkWidget *window = capture.editor;
  capture.editor = NULL;
  if (window)
    gtk_widget_destroy(window);
  g_clear_pointer(&capture.tool_command, g_free);
  g_clear_pointer(&capture.drag_annotation_id, g_free);
  capture_toolbar_close(capture.toolbar_handle);
  if (capture.session > 0)
    image_session_dispose(capture.session);
  if (capture.style_bank > 0)
    editor_style_dispose(capture.style_bank);
  g_clear_object(&capture.image);

  memset(&capture, 0, sizeof(capture));
  if (host.restore_visibility)
    host.restore_visibility(host.data);
}
gboolean mc_linux_capture_busy(void) {
  return capture.editor || capture.pending;
}
gboolean mc_linux_capture_preflight_tools(int snapshot, const char **reason) {
  const char *failure = NULL;
  if (capture.prepared_tool_candidate) capture_toolbar_config_close(capture.prepared_tool_candidate);
  capture.prepared_tool_candidate = 0;
  capture.prepared_snapshot = 0;
  if (tool_registry_snapshot_count(snapshot, MC_TOOL_GROUP_SCREENSHOT) < 0)
    failure = "工具配置无效，原设置未改动。";
  else if (capture.selecting || capture.dragging)
    failure = "请先完成当前框选或拖动，再调整工具。";
  else if (capture.toolbar_handle) {
    if (toolbar_context())
      capture.prepared_tool_candidate = capture_toolbar_config_prepare(capture.toolbar_handle, snapshot);
    if (!capture.prepared_tool_candidate)
      failure = "请先完成有效的属性输入，再调整工具。";
    else
      capture.prepared_snapshot = snapshot;
  }
  if (reason) *reason = failure;
  return failure == NULL;
}
void mc_linux_capture_publish_tools(int snapshot) {
  if (!capture.toolbar_handle) { published_tools = snapshot; return; }
  const char *reason = NULL;
  if ((capture.prepared_snapshot != snapshot ||
       !capture_toolbar_config_ready(capture.toolbar_handle, capture.prepared_tool_candidate)) &&
      !mc_linux_capture_preflight_tools(snapshot, &reason)) {
    report(reason); return;
  }
  char *publication = g_strdup_printf("[{\"toolbar\":%d,\"candidate\":%d}]",
      capture.toolbar_handle, capture.prepared_tool_candidate);
  moonbit_string_t request = core_string(publication);
  g_free(publication);
  int accepted = capture_toolbar_config_commit_many(request);
  moonbit_decref(request);
  if (!accepted) { report("工具配置已过期，请重试。"); return; }
  capture.prepared_tool_candidate = 0;
  capture.prepared_snapshot = 0;
  published_tools = snapshot;
  if (capture.text_edit && text_version() < 0) {
    end_text_controls();
    capture.selected = -1;
  }
  sync_toolbar_tool();
  sync_style();
  layout_controls();
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
  for (int i = 0; i < 10; i++)
    r[i] = image_session_value(capture.session, index, i + 1);
}
static char *annotation_text(int index) {
  moonbit_string_t value = image_session_text(capture.session, index);
  char *text = g_utf16_to_utf8((const gunichar2 *)value, Moonbit_array_length(value), NULL, NULL, NULL);
  moonbit_decref(value);
  return text;
}
static gboolean update_annotation(int index, const double *r) {
  moonbit_string_t id = image_session_annotation_id(capture.session, index);
  double font = -1;
  if ((int)image_session_value(capture.session, index, 0) == TEXT &&
      r[6] != image_session_value(capture.session, index, 7)) font = r[6];
  int result = image_session_geometry(capture.session, image_session_revision(capture.session), id,
                                     r[0], r[1], r[2], r[3], font);
  moonbit_decref(id);
  return result == 1;
}
static PangoLayout *text_layout(cairo_t *cr, const char *text, double width, double size) {
  PangoLayout *layout = pango_cairo_create_layout(cr);
  PangoFontDescription *font = pango_font_description_from_string("Sans Semibold");
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
  if (kind == REDACT && (int)r[8] == 2) {
    cairo_surface_t *target = cairo_get_target(cr);
    cairo_surface_flush(target);
    mc_pixelate_bgra(cairo_image_surface_get_data(target), cairo_image_surface_get_width(target),
        cairo_image_surface_get_height(target), cairo_image_surface_get_stride(target),
        (int)floor(x), (int)floor(y), (int)ceil(x + w) - (int)floor(x),
        (int)ceil(y + h) - (int)floor(y), (int)r[9]);
    cairo_surface_mark_dirty(target);
  } else if (kind == RECTANGLE) {
    if ((int)r[8] == 1) {
      cairo_save(cr); cairo_translate(cr, x + w / 2, y + h / 2); cairo_scale(cr, w / 2, h / 2);
      cairo_arc(cr, 0, 0, 1, 0, 2 * G_PI); cairo_restore(cr);
    } else cairo_rectangle(cr, x, y, w, h);
    cairo_stroke(cr);
  } else if (kind == REDACT) {
    if ((int)r[8] == 1) {
      cairo_save(cr); cairo_translate(cr, x + w / 2, y + h / 2); cairo_scale(cr, w / 2, h / 2);
      cairo_arc(cr, 0, 0, 1, 0, 2 * G_PI); cairo_restore(cr);
    } else { cairo_set_antialias(cr, CAIRO_ANTIALIAS_NONE); cairo_rectangle(cr, x, y, w, h); }
    cairo_fill(cr);
  } else if (kind == ARROW) {
    double len = hypot(w, h);
    if (len > .5) {
      cairo_move_to(cr, x, y);
      cairo_line_to(cr, x + w, y + h);
      cairo_stroke(cr);
      cairo_move_to(cr, image_arrowhead_value(x, y, x + w, y + h, stroke, 0),
                    image_arrowhead_value(x, y, x + w, y + h, stroke, 1));
      cairo_line_to(cr, x + w, y + h);
      cairo_line_to(cr, image_arrowhead_value(x, y, x + w, y + h, stroke, 2),
                    image_arrowhead_value(x, y, x + w, y + h, stroke, 3));
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
static void composite_document(cairo_t *destination, gboolean export, gboolean draft_text, int candidate) {
  // A source-pixel surface makes preview, mask sampling and crop export agree.
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, capture.width, capture.height);
  if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) { cairo_surface_destroy(surface); return; }
  cairo_t *cr = cairo_create(surface);
  gdk_cairo_set_source_pixbuf(cr, capture.image, 0, 0);
  cairo_paint(cr);
  int count = candidate ? capture_candidate_count(candidate) : image_session_count(capture.session);
  for (int pass = 0; pass < 2; pass++) {
    for (int i = 0; i < count; i++) {
      int kind = (int)(candidate ? capture_candidate_value(candidate, i, 0) : image_session_value(capture.session, i, 0));
      if ((kind == REDACT) != (pass == 1)) continue;
      if (!export && capture.editing && kind == REDACT && !draft_text) continue;
      double r[10];
      if (candidate) {
        for (int field = 0; field < 10; field++) r[field] = capture_candidate_value(candidate, i, field + 1);
      } else read_annotation(i, r);
      gboolean draft = !export && capture.text_edit && capture.edit_index == i;
      if (draft && kind == TEXT && capture.editing && !draft_text) continue;
      if (draft || (!export && capture.dragging && capture.gesture == 1 && capture.selected == i))
        memcpy(r, capture.preview, sizeof(r));
      char *text = NULL;
      if (kind == TEXT) {
        if (candidate) text = core_text(capture_candidate_text(candidate, i));
        else if (draft) text = core_text(capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RAW));
        else text = annotation_text(i);
      }
      draw_shape(cr, kind, r, text); g_free(text);
    }
    if (pass == 0 && !export && capture.text_edit &&
        capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_MODE) == MC_CAPTURE_TEXT_NEW &&
        (draft_text || !capture.editing)) {
      char *text = core_text(capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RAW));
      draw_shape(cr, TEXT, capture.preview, text); g_free(text);
    }
    if (!export && capture.dragging && !capture.gesture && !capture.selecting) {
      int kind = (int)image_session_preview_value(capture.session, 0);
      if (kind && (kind == REDACT) == (pass == 1)) {
        double r[10];
        for (int i = 0; i < 10; i++) r[i] = image_session_preview_value(capture.session, i + 1);
        draw_shape(cr, kind, r, NULL);
      }
    }
  }
  cairo_destroy(cr);
  cairo_set_source_surface(destination, surface, 0, 0);
  cairo_paint(destination);
  cairo_surface_destroy(surface);
}
static void draw_document(cairo_t *cr, gboolean export) { composite_document(cr, export, FALSE, 0); }
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
    double r[10];
    read_annotation(capture.selected, r);
    if (capture.dragging && capture.gesture == 1)
      memcpy(r, capture.preview, sizeof(r));
    selection_outline(cr, r, TRUE);
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
  // Replace the entire masked scene under the live GTK editor once, including
  // the current draft. Translucent covers must not be alpha-composited twice.
  for (int i = 0; i < image_session_count(capture.session); i++)
    if ((int)image_session_value(capture.session, i, 0) == REDACT) {
      double r[10]; read_annotation(i, r);
      if ((int)r[8] == 1) {
        cairo_save(cr); cairo_translate(cr, r[0] + r[2]/2, r[1] + r[3]/2); cairo_scale(cr, r[2]/2, r[3]/2);
        cairo_new_sub_path(cr); cairo_arc(cr, 0, 0, 1, 0, 2*G_PI); cairo_restore(cr);
      } else if ((int)r[8] == 2)
        cairo_rectangle(cr, floor(r[0]), floor(r[1]), ceil(r[0] + r[2]) - floor(r[0]), ceil(r[1] + r[3]) - floor(r[1]));
      else cairo_rectangle(cr, r[0], r[1], r[2], r[3]);
    }
  cairo_clip(cr);
  composite_document(cr, FALSE, TRUE, 0);
  cairo_restore(cr);
  return FALSE;
}
static GdkPixbuf *flatten_document(int candidate) {
  double crop[4];
  for (int i = 0; i < 4; i++) crop[i] = candidate ? capture_candidate_viewport_value(candidate, i) : capture.crop[i];
  int width = (int)crop[2], height = (int)crop[3];
  if (width < 2 || height < 2)
    return NULL;
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
  if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(surface);
    return NULL;
  }
  cairo_t *cr = cairo_create(surface);
  cairo_translate(cr, -crop[0], -crop[1]);
  composite_document(cr, TRUE, FALSE, candidate);
  cairo_destroy(cr);
  GdkPixbuf *image = gdk_pixbuf_get_from_surface(surface, 0, 0, width, height);
  cairo_surface_destroy(surface);
  return image;
}
static GdkPixbuf *flatten(void) { return flatten_document(0); }
static GdkPixbuf *flatten_preview(void) {
  if (!capture.text_edit) return flatten();
  int ticket = capture_text_prepare(capture.session, capture.text_edit, text_version(), MC_CAPTURE_CANDIDATE_PREVIEW, text_measurement());
  if (!ticket) return NULL;
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)capture.crop[2], (int)capture.crop[3]);
  cairo_t *cr = cairo_create(surface); cairo_translate(cr, -capture.crop[0], -capture.crop[1]);
  composite_document(cr, FALSE, TRUE, 0); cairo_destroy(cr);
  GdkPixbuf *result = gdk_pixbuf_get_from_surface(surface, 0, 0, (int)capture.crop[2], (int)capture.crop[3]);
  cairo_surface_destroy(surface); capture_candidate_close(ticket); return result;
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
  if (capture.text_edit)
    return (int)capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_TOOL);
  if (capture.selected >= 0)
    return (int)image_session_value(capture.session, capture.selected, 0);
  return capture.tool;
}
static void sync_control_values(void) {
  if (capture.ending_text) return;
  if (!capture.text_edit && !capture.dragging && !capture.gesture && !capture.pointer_dispatch && capture.session > 0) {
    int kind = capture.selected >= 0 ? (int)image_session_value(capture.session, capture.selected, 0) : capture.tool;
    if (kind == TEXT) {
      int mode = capture.selected >= 0 ? MC_CAPTURE_TEXT_EXISTING : MC_CAPTURE_TEXT_DEFAULTS;
      start_text_transaction(mode, capture.selected, 0, 0, 0, 0);
    } else if (kind != SELECT) {
      moonbit_string_t id = capture.selected >= 0 ? image_session_annotation_id(capture.session, capture.selected) : core_string("");
      moonbit_string_t command = core_string(capture.selected < 0 && capture.tool_command ? capture.tool_command : "");
      capture.text_edit = capture_properties_begin(capture.session, capture.style_bank, kind, id,
          image_session_revision(capture.session), command);
      moonbit_decref(command); moonbit_decref(id);
      if (capture.text_edit) capture.edit_index = capture.selected;
    }
  }
  if (capture.text_edit) { sync_text(); return; }
  if (capture.property_overlay) gtk_widget_hide(capture.property_overlay);
}
static void refresh_context(void) { sync_control_values(); }
static void load_tool_style(int tool) {
  capture.color = (int)editor_style_get(capture.style_bank, tool, MC_STYLE_COLOR);
  capture.opacity = editor_style_get(capture.style_bank, tool, MC_STYLE_OPACITY);
  capture.stroke = editor_style_get(capture.style_bank, tool, MC_STYLE_STROKE);
  capture.font_size = editor_style_get(capture.style_bank, tool, MC_STYLE_FONT);
  capture.shape = (int)editor_style_get(capture.style_bank, tool, MC_STYLE_SHAPE);
  capture.block = (int)editor_style_get(capture.style_bank, tool, MC_STYLE_BLOCK);
}
static void sync_style(void) {
  if (capture.selected >= 0) {
    capture.color = (int)image_session_value(capture.session, capture.selected, 5);
    capture.stroke = image_session_value(capture.session, capture.selected, 6);
    capture.opacity = image_session_value(capture.session, capture.selected, 8);
    capture.shape = (int)image_session_value(capture.session, capture.selected, 9);
    capture.block = (int)image_session_value(capture.session, capture.selected, 10);
    if ((int)image_session_value(capture.session, capture.selected, 0) == TEXT)
      capture.font_size = image_session_value(capture.session, capture.selected, 7);
  } else if (!capture.editing)
    load_tool_style(capture.tool);
  sync_control_values();
}
static int text_version(void) {
  return (int)capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_VERSION);
}
static void retire_tool_configuration(void) {
  if (capture.prepared_tool_candidate) capture_toolbar_config_close(capture.prepared_tool_candidate);
  capture.prepared_tool_candidate = 0;
  capture.prepared_snapshot = 0;
}
static gboolean text_event(moonbit_string_t event) {
  if (!capture.text_edit || capture.closing) return FALSE;
  int accepted = capture_text_event_json(capture.session, capture.text_edit, text_version(), event);
  if (accepted) retire_tool_configuration();
  sync_text();
  if (capture.editor) { layout_controls(); gtk_widget_queue_draw(capture.editor); }
  return accepted == 1;
}
static gboolean input_event(gpointer data, moonbit_string_t event) { (void)data; return text_event(event); }
static double text_measurement(void) {
  if (!capture.text_edit || capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_TOOL) != TEXT ||
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_MODE) == MC_CAPTURE_TEXT_DEFAULTS) return 0;
  char *text = core_text(capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RAW));
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
  cairo_t *cr = cairo_create(surface);
  PangoLayout *layout = text_layout(cr, text,
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_WIDTH),
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_FONT_SIZE));
  int height; pango_layout_get_size(layout, NULL, &height);
  g_object_unref(layout); cairo_destroy(cr); cairo_surface_destroy(surface); g_free(text);
  return (double)height / PANGO_SCALE;
}
static gboolean start_text_transaction(int mode, int index, double x, double y, double w, double h) {
  moonbit_string_t id = index >= 0 ? image_session_annotation_id(capture.session, index) : core_string("");
  capture.text_edit = capture_text_begin(capture.session, capture.style_bank, mode, id,
      image_session_revision(capture.session), x, y, w, h);
  moonbit_decref(id);
  if (!capture.text_edit) return FALSE;
  capture.edit_index = index; return TRUE;
}
static void end_text_controls(void) {
  capture.ending_text = TRUE;
  if (capture.text_blur_idle) { g_source_remove(capture.text_blur_idle); capture.text_blur_idle = 0; }
  retire_tool_configuration();
  if (capture.color_dialog) { GtkWidget *dialog = capture.color_dialog; capture.color_dialog = NULL; gtk_widget_destroy(dialog); }
  capture.text_edit = 0; capture.entry = NULL; capture.editing = capture.composing = FALSE;
  mc_linux_text_inputs_set_frame(capture.body_inputs, 0);
  mc_linux_text_inputs_set_frame(capture.property_inputs, 0);
  if (capture.body_fixed) gtk_widget_hide(capture.body_fixed);
  if (capture.property_overlay) gtk_widget_hide(capture.property_overlay);
  capture.ending_text = FALSE;
}
static gboolean commit_text(void) {
  if (!capture.text_edit) return TRUE;
  if (mc_linux_text_inputs_composing(capture.body_inputs) || mc_linux_text_inputs_composing(capture.property_inputs)) return FALSE;
  if (!mc_linux_text_inputs_flush(capture.body_inputs) || !mc_linux_text_inputs_flush(capture.property_inputs)) return FALSE;
  char *id = core_text(capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ANNOTATION_ID));
  int ticket = capture_text_prepare(capture.session, capture.text_edit, text_version(), MC_CAPTURE_CANDIDATE_PUBLISH, text_measurement());
  if (!ticket || !capture_candidate_commit(capture.session, ticket)) {
    g_free(id);
    if (ticket) capture_candidate_close(ticket);
    sync_text(); return FALSE;
  }
  /* Commit ends the root edit. Remember its stable identity before native
   * controls retire; list indices are merely transient rendering lookups. */
  if (!*id && capture.edit_index >= 0) { g_free(id); id = core_text(image_session_annotation_id(capture.session, capture.edit_index)); }
  end_text_controls();
  capture.selected = -1;
  for (int i = 0; i < image_session_count(capture.session); i++) {
    char *candidate = core_text(image_session_annotation_id(capture.session, i));
    if (!strcmp(id, candidate)) capture.selected = i;
    g_free(candidate);
  }
  g_free(id);
  if (capture.editor) gtk_widget_queue_draw(capture.editor);
  return TRUE;
}
static void cancel_text(void) {
  if (capture.text_edit) capture_text_cancel(capture.session, capture.text_edit, text_version());
  capture.selected = capture.edit_index;
  end_text_controls();
  if (capture.canvas) gtk_widget_grab_focus(capture.canvas);
  if (capture.editor) gtk_widget_queue_draw(capture.editor);
}
static gboolean blur_text(gpointer data) {
  int edit = GPOINTER_TO_INT(data); capture.text_blur_idle = 0;
  if (!capture.editor || capture.closing || capture.text_edit != edit ||
      capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_MODE) != MC_CAPTURE_TEXT_DEFAULTS) return G_SOURCE_REMOVE;
  GtkWidget *focus = gtk_window_get_focus(GTK_WINDOW(capture.editor));
  gboolean in_properties = focus && capture.property_overlay &&
      (focus == capture.property_overlay || gtk_widget_is_ancestor(focus, capture.property_overlay));
  if (!in_properties && focus != capture.toolbar_canvas && !capture.color_dialog) {
    if (commit_text()) { refresh_context(); layout_controls(); }
  }
  return G_SOURCE_REMOVE;
}
static void input_action(gpointer data, GtkWidget *field, int action) {
  (void)data; (void)field;
  if (!capture.text_edit || capture.ending_text || capture.closing) return;
  if (action == MC_LINUX_TEXT_CANCEL) { cancel_text(); refresh_context(); layout_controls(); }
  else if (action == MC_LINUX_TEXT_ACCEPT) {
    if (commit_text()) { gtk_widget_grab_focus(capture.canvas); refresh_context(); layout_controls(); }
  } else if (action == MC_LINUX_TEXT_BLUR && !capture.text_blur_idle)
    capture.text_blur_idle = g_idle_add(blur_text, GINT_TO_POINTER(capture.text_edit));
}
static void sync_text(void) {
  if (!capture.text_edit || capture.syncing_text || capture.ending_text || !capture.property_canvas) return;
  capture.syncing_text = TRUE;
  int edit = capture.text_edit;
  capture.color = (int)capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_RGB);
  capture.opacity = capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_OPACITY);
  capture.font_size = capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_FONT_SIZE);
  capture.stroke = capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_STROKE);
  capture.shape = (int)capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_SHAPE);
  capture.block = (int)capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_BLOCK);
  capture.composing = mc_linux_text_inputs_composing(capture.body_inputs) || mc_linux_text_inputs_composing(capture.property_inputs);
  for (int i = 0; i < 4; i++) capture.preview[i] = capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_X + i);
  capture.preview[4] = capture.color; capture.preview[5] = capture.stroke;
  capture.preview[6] = capture.font_size; capture.preview[7] = capture.opacity;
  capture.preview[8] = capture.shape; capture.preview[9] = capture.block;
  double height = capture_text_measured_height(capture.session, edit, text_version(), text_measurement());
  if (height > 0) capture.preview[3] = height;
  double rw = capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_ROW_WIDTH);
  double rh = capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_ROW_HEIGHT);
  gboolean dark = FALSE; g_object_get(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", &dark, NULL);
  moonbit_string_t json = capture_text_frame(capture.session, edit, MC_CAPTURE_TEXT_PROPERTIES, rw, rh, 1, dark);
  int frame = ui_frame_open(json); moonbit_decref(json);
  if (frame) {
    mc_linux_text_inputs_set_frame(capture.property_inputs, frame);
    if (!mc_linux_canvas_set_frame(capture.property_canvas, frame)) ui_frame_close(frame);
    gtk_widget_set_size_request(capture.property_overlay, (int)ceil(rw), (int)ceil(rh));
  }
  gtk_widget_show(capture.property_canvas);
  gtk_widget_show(mc_linux_text_inputs_widget(capture.property_inputs));
  gtk_widget_show(capture.property_overlay);
  if (capture.editing) {
    double scale = capture.zoom > 0 ? capture.zoom : 1;
    json = capture_text_frame(capture.session, edit, MC_CAPTURE_TEXT_INLINE,
        capture.preview[2] * scale, capture.preview[3] * scale, scale, dark);
    frame = ui_frame_open(json); moonbit_decref(json);
    if (frame) { mc_linux_text_inputs_set_frame(capture.body_inputs, frame); ui_frame_close(frame); }
    capture.entry = mc_linux_text_inputs_field(capture.body_inputs, "annotation.text");
    gtk_widget_show(capture.body_fixed);
  }
  capture.syncing_text = FALSE;
}
static void begin_text(int index, double x, double y) {
  if (!commit_text()) return;
  if (index >= 0) read_annotation(index, capture.preview);
  else {
    capture.preview[0] = x; capture.preview[1] = y;
    capture.preview[2] = fmin(240, capture.crop[0] + capture.crop[2] - x);
    capture.preview[3] = fmin(80, capture.crop[1] + capture.crop[3] - y);
  }
  if (!start_text_transaction(index >= 0 ? MC_CAPTURE_TEXT_EXISTING : MC_CAPTURE_TEXT_NEW, index,
      capture.preview[0], capture.preview[1], capture.preview[2], capture.preview[3])) return;
  capture.editing = TRUE; capture.selected = index;
  sync_text(); layout_controls();
  if (capture.entry) gtk_widget_grab_focus(capture.entry);
  gtk_widget_queue_draw(capture.editor);
}
static int handle_at(double x, double y, const double *r) {
  return mc_selection_handle_at(selection_rect(r), (MCSelectionPoint){x, y}, capture.zoom);
}
static int hit_test(double x, double y) {
  int hit = image_session_hit(capture.session, x, y, 5 / capture.zoom, 0);
  // Keep dragging a selected outlined rectangle from its interior, after
  // visible objects have had priority. contains already delegates to MoonBit.
  int i = capture.selected;
  if (hit < 0 && i >= 0 && (int)image_session_value(capture.session, i, 0) == RECTANGLE) {
    double r[10];
    read_annotation(i, r);
    if (inside(x, y, r))
      return i;
  }
  return hit;
}
static void event_position(double ex, double ey, double *x, double *y) {
  MCSelectionViewport viewport = {capture.offset_x, capture.offset_y, capture.zoom,
                                   capture.width, capture.height};
  MCSelectionPoint point = mc_selection_from_surface((MCSelectionPoint){ex, ey}, viewport);
  *x = point.x;
  *y = point.y;
}
static gboolean canvas_press_inner(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)data;
  if (event->button != 1 || capture.zoom <= 0)
    return FALSE;
  if (!commit_text())
    return TRUE;
  g_clear_pointer(&capture.drag_annotation_id, g_free);
  capture.drag_revision = -1;
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
    image_session_shape_event(capture.session, 2, 0, 0);
    int accepted;
    if (capture.tool_command) {
      glong length = 0;
      gunichar2 *text = g_utf8_to_utf16(capture.tool_command, -1, NULL, &length, NULL);
      moonbit_string_t value = moonbit_make_string_raw((int32_t)length);
      if (length) memcpy(value, text, (gsize)length * sizeof(gunichar2));
      g_free(text);
      accepted = image_session_tool_begin(capture.session, value, x, y, capture.color,
        capture.stroke, capture.opacity, 0, capture.block);
      moonbit_decref(value);
    } else accepted = image_session_shape_begin(capture.session, capture.tool, x, y, capture.color,
      capture.stroke, capture.opacity, capture.shape, capture.block);
    if (!accepted) return TRUE;
  }
  capture.selection.original = selection_rect(capture.original);
  memcpy(capture.preview, capture.original, sizeof(capture.preview));
  if (capture.gesture == 1) {
    capture.drag_annotation_id = core_text(image_session_annotation_id(capture.session, capture.selected));
    capture.drag_revision = image_session_revision(capture.session);
  }
  capture.dragging = TRUE;
  gtk_grab_add(widget);
  gtk_widget_queue_draw(widget);
  return TRUE;
}
static gboolean canvas_press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  capture.pointer_dispatch = TRUE;
  gboolean handled = canvas_press_inner(widget, event, data);
  capture.pointer_dispatch = FALSE;
  return handled;
}
static void motion(double x, double y) {
  mc_selection_update(&capture.selection, (MCSelectionPoint){x, y});
  if (!capture.selecting && !capture.gesture) image_session_shape_event(capture.session, 0, x, y);
  if (capture.gesture) {
    double *r = capture.preview, *o = capture.original;
    memcpy(r, o, sizeof(capture.preview));
    selection_values(mc_selection_transform(&capture.selection, capture.width, capture.height,
                                            capture.gesture == 2 ? 2 : 8), r);
    int handle = capture.selection.handle;
    if (capture.gesture == 1 && handle >= 0 && (handle % 2) == 0 &&
        (int)image_session_value(capture.session, capture.selected, 0) == TEXT)
      r[6] = CLAMP(o[6] * fmin(r[2] / o[2], r[3] / o[3]),
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
  if (!open_toolbar()) {
    image_session_dispose(capture.session);
    capture.session = 0;
    return FALSE;
  }
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
    if (capture.drag_annotation_id) {
      moonbit_string_t id = core_string(capture.drag_annotation_id);
      double *r = capture.preview;
      image_session_geometry(capture.session, capture.drag_revision, id, r[0], r[1], r[2], r[3],
          (int)image_session_value(capture.session, capture.selected, 0) == TEXT && r[6] != capture.original[6] ? r[6] : -1);
      moonbit_decref(id);
      capture.selected = -1;
      for (int i = 0; i < image_session_count(capture.session); i++) {
        char *stored = core_text(image_session_annotation_id(capture.session, i));
        if (!strcmp(stored, capture.drag_annotation_id)) capture.selected = i;
        g_free(stored);
      }
    } else update_annotation(capture.selected, capture.preview);
    sync_style();
  } else if (capture.gesture == 2) {
    image_session_crop(capture.session, (int)capture.preview[0], (int)capture.preview[1],
                       (int)capture.preview[2], (int)capture.preview[3]);
    sync_crop();
  } else if (capture.tool != SELECT && capture.tool != TEXT) {
    image_session_shape_event(capture.session, 1, x, y);
  }
  capture.gesture = 0;
  g_clear_pointer(&capture.drag_annotation_id, g_free); capture.drag_revision = -1;
  layout_controls();
  gtk_widget_queue_draw(widget);
  return TRUE;
}
static gboolean pin_available(void) {
  return capture.host.pin_result && (!capture.host.can_pin || capture.host.can_pin(capture.host.data));
}
static gboolean toolbar_field_focused(void *context) {
  (void)context;
  if (!capture.editor) return FALSE;
  GtkWidget *focus = gtk_window_get_focus(GTK_WINDOW(capture.editor));
  return mc_linux_text_inputs_contains(capture.body_inputs, focus) ||
         mc_linux_text_inputs_contains(capture.property_inputs, focus);
}
static gboolean toolbar_context(void) {
  if (!capture.toolbar_handle || capture.closing) return FALSE;
  gboolean composing = mc_linux_text_inputs_composing(capture.body_inputs) ||
                       mc_linux_text_inputs_composing(capture.property_inputs);
  GtkWidget *focus = capture.editor ? gtk_window_get_focus(GTK_WINDOW(capture.editor)) : NULL;
  char measurement[G_ASCII_DTOSTR_BUF_SIZE];
  g_ascii_dtostr(measurement, sizeof(measurement), text_measurement());
  char *json = g_strdup_printf(
      "{\"hasRegion\":%s,\"blocked\":%s,\"fieldFocused\":%s,\"toolbarFocused\":%s,"
      "\"bodyEditing\":%s,\"pinAvailable\":%s,\"edit\":%d,\"editVersion\":%d,\"measuredHeight\":%s}",
      capture.selecting ? "false" : "true",
      (capture.dragging || capture.color_dialog || composing) ? "true" : "false",
      toolbar_field_focused(NULL) ? "true" : "false",
      (focus && focus == capture.toolbar_canvas) ? "true" : "false",
      capture.editing ? "true" : "false",
      pin_available() ? "true" : "false",
      capture.text_edit, capture.text_edit ? text_version() : 0, measurement);
  moonbit_string_t input = core_string(json);
  g_free(json);
  gboolean accepted = capture_toolbar_context(capture.toolbar_handle, input) == 1;
  moonbit_decref(input);
  return accepted;
}
static gboolean open_toolbar(void) {
  int snapshot = published_tools;
  if (!snapshot) {
    moonbit_string_t empty = core_string("");
    moonbit_string_t config = tool_registry_normalize(empty);
    moonbit_decref(empty);
    snapshot = tool_registry_snapshot_open(config, MC_TOOL_CAP_COMMANDS);
    moonbit_decref(config);
  }
  capture.toolbar_handle = capture_toolbar_open(capture.session, capture.style_bank, snapshot);
  if (!published_tools) tool_registry_snapshot_close(snapshot);
  return capture.toolbar_handle > 0;
}
static void sync_toolbar_tool(void) {
  capture.tool = (int)capture_toolbar_value(capture.toolbar_handle, MC_CAPTURE_TOOLBAR_KIND);
  g_free(capture.tool_command);
  capture.tool_command = core_text(capture_toolbar_text(capture.toolbar_handle, MC_CAPTURE_TOOLBAR_COMMAND));
  if (!*capture.tool_command) g_clear_pointer(&capture.tool_command, g_free);
}
static void handle_toolbar_effect(void) {
  int toolbar = capture.toolbar_handle;
  int effect = (int)capture_toolbar_value(toolbar, MC_CAPTURE_TOOLBAR_EFFECT);
  if (effect == MC_CAPTURE_TOOLBAR_NONE) {
    char *message = core_text(capture_toolbar_text(toolbar, MC_CAPTURE_TOOLBAR_ERROR));
    if (*message) report(message);
    g_free(message);
    layout_controls();
    return;
  }
  int ticket = (int)capture_toolbar_value(toolbar, MC_CAPTURE_TOOLBAR_TICKET);
  if (capture.text_edit && text_version() < 0) end_text_controls();
  gboolean success = TRUE;
  const char *error = "";
  switch (effect) {
    case MC_CAPTURE_TOOLBAR_REFRESH: {
      char *id = core_text(capture_toolbar_text(toolbar, MC_CAPTURE_TOOLBAR_EFFECT_ID));
      if (strcmp(id, "host.undo") && strcmp(id, "host.redo")) {
        capture.selected = -1;
        gtk_widget_grab_focus(capture.canvas);
      } else if (!capture.text_edit) capture.selected = -1;
      g_free(id);
      sync_toolbar_tool();
      break;
    }
    case MC_CAPTURE_TOOLBAR_CANCEL:
      break;
    case MC_CAPTURE_TOOLBAR_COPY:
      sync_crop();
      success = copy_image();
      if (!success) error = "暂时无法复制图片，请重试。";
      break;
    case MC_CAPTURE_TOOLBAR_PIN: {
      int candidate = (int)capture_toolbar_value(toolbar, MC_CAPTURE_TOOLBAR_CANDIDATE);
      GdkPixbuf *pin = candidate > 0 ? flatten_document(candidate) : NULL;
      success = FALSE;
      if (pin && pin_available()) {
        int x, y;
        gdk_window_get_origin(gtk_widget_get_window(capture.editor), &x, &y);
        GdkRectangle bounds = {x + (int)round(capture.offset_x + capture.crop[0] * capture.zoom),
                                y + (int)round(capture.offset_y + capture.crop[1] * capture.zoom),
                                (int)round(capture.crop[2] * capture.zoom), (int)round(capture.crop[3] * capture.zoom)};
        success = capture.host.pin_result(pin, &bounds, capture.host.data);
      }
      g_clear_object(&pin);
      if (capture.toolbar_handle != toolbar) return;
      if (!success) error = "暂时无法创建贴图，请重试。";
      break;
    }
    default:
      success = FALSE;
      error = "当前后端尚未提供这个操作。";
  }
  moonbit_string_t detail = core_string(error);
  gboolean acknowledged = capture_toolbar_ack(toolbar, ticket, success, detail) == 1;
  moonbit_decref(detail);
  if (success && acknowledged &&
      (effect == MC_CAPTURE_TOOLBAR_COPY || effect == MC_CAPTURE_TOOLBAR_CANCEL || effect == MC_CAPTURE_TOOLBAR_PIN)) {
    mc_linux_capture_close();
  } else {
    if (*error) report(error);
    sync_crop();
    if (capture.selected >= image_session_count(capture.session)) capture.selected = -1;
    if (capture.text_edit) sync_text(); else sync_style();
    layout_controls();
    gtk_widget_queue_draw(capture.canvas);
  }
}
static gboolean toolbar_activate(const char *id) {
  if (!toolbar_context()) return FALSE;
  moonbit_string_t input = core_string(id);
  int current = (int)capture_toolbar_value(capture.toolbar_handle, MC_CAPTURE_TOOLBAR_GENERATION);
  gboolean accepted = capture_toolbar_activate(capture.toolbar_handle, current, input) == 1;
  moonbit_decref(input);
  if (accepted) handle_toolbar_effect();
  else {
    char *message = core_text(capture_toolbar_text(capture.toolbar_handle, MC_CAPTURE_TOOLBAR_ERROR));
    if (*message) report(message);
    g_free(message);
  }
  return accepted;
}
static void toolbar_event(void *context, GtkWidget *widget, const MCCanvasInput *event) {
  (void)context; (void)widget;
  if (capture.closing || !capture.toolbar_handle) return;
  if (event->type == MC_UI_INPUT_APPEARANCE) {
    capture.toolbar_dark = event->text_length == 4 && event->text[0] == 'd';
    mc_linux_hud_set_dark(capture.toolbar, capture.toolbar_dark);
    layout_controls();
    return;
  }
  if (!toolbar_context()) return;
  moonbit_string_t input = mc_canvas_input_json(event);
  gboolean accepted = capture_toolbar_event(capture.toolbar_handle, capture.toolbar_generation, input) == 1;
  moonbit_decref(input);
  if (accepted) handle_toolbar_effect();
  else layout_controls();
}
void mc_linux_capture_refresh_capabilities(void) {
  if (capture.editor) layout_controls();
}
static gboolean editor_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)widget;
  (void)data;
  GtkWidget *focus = gtk_window_get_focus(GTK_WINDOW(capture.editor));
  if (mc_linux_text_inputs_contains(capture.body_inputs, focus) ||
      mc_linux_text_inputs_contains(capture.property_inputs, focus) || (focus && GTK_IS_EDITABLE(focus))) return FALSE;
  if (event->keyval == GDK_KEY_Escape) {
    if (capture.selecting) mc_linux_capture_close();
    else toolbar_activate("host.cancel");
    return TRUE;
  }
  if (capture.selecting)
    return FALSE;
  if (event->keyval == GDK_KEY_Delete && capture.selected >= 0) {
    if (!commit_text()) return TRUE;
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
    toolbar_activate("host.confirm");
    return TRUE;
  }
  if (key == GDK_KEY_z || key == GDK_KEY_y) {
    toolbar_activate(key == GDK_KEY_y || (event->state & GDK_SHIFT_MASK) ? "host.redo" : "host.undo");
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
  transform();
  refresh_context();
  int ww = gtk_widget_get_allocated_width(capture.canvas),
      hh = gtk_widget_get_allocated_height(capture.canvas);
  if (toolbar_context()) {
    double max_width = MAX(32, ww - 26.0);
    moonbit_string_t json = capture_toolbar_frame(capture.toolbar_handle, max_width, capture.toolbar_dark);
    int frame = ui_frame_open(json);
    moonbit_decref(json);
    if (frame) {
      if (mc_linux_canvas_set_frame(capture.toolbar_canvas, frame)) {
        capture.toolbar_frame = frame;
        capture.toolbar_generation = (int)capture_toolbar_value(capture.toolbar_handle, MC_CAPTURE_TOOLBAR_GENERATION);
        gtk_widget_set_size_request(capture.toolbar_canvas,
            (int)ceil(capture_toolbar_value(capture.toolbar_handle, MC_CAPTURE_TOOLBAR_WIDTH)),
            (int)ceil(capture_toolbar_value(capture.toolbar_handle, MC_CAPTURE_TOOLBAR_HEIGHT)));
      } else ui_frame_close(frame);
    }
  }
  GtkRequisition size;
  gtk_widget_get_preferred_size(capture.toolbar, &size, NULL);
  double *frame = capture_ui_measured_toolbar_frame(ww, hh,
      capture.offset_x + capture.crop[0] * capture.zoom, capture.offset_y + capture.crop[1] * capture.zoom,
      capture.crop[2] * capture.zoom, capture.crop[3] * capture.zoom, size.width, size.height);
  GdkRectangle toolbar_bounds = {(int)frame[0], (int)frame[1], (int)frame[2], (int)frame[3]};
  moonbit_decref(frame);
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
  if (child == capture.body_fixed) {
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
static void color_request_free(gpointer data, GClosure *closure) {
  (void)closure;
  g_free(data);
}
static void color_response(GtkDialog *dialog, int response, gpointer data) {
  /* Closing the widget can release the signal closure synchronously. Copy its
   * lease before any callback and never adopt a newer version of the draft. */
  ColorRequest request = *(ColorRequest *)data;
  gboolean current = capture.editor && !capture.closing && capture.session == request.session &&
      capture.text_edit == request.edit && text_version() == request.version && capture.color_dialog == GTK_WIDGET(dialog);
  gboolean accepted = FALSE;
  int accepted_version = -1;
  if (current && response == GTK_RESPONSE_OK) {
    GdkRGBA rgba; gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(dialog), &rgba);
    int rgb = ((int)lround(rgba.red * 255) << 16) | ((int)lround(rgba.green * 255) << 8) | (int)lround(rgba.blue * 255);
    char *json = g_strdup_printf("{\"type\":\"color\",\"rgb\":%d}", rgb);
    moonbit_string_t event = core_string(json); g_free(json);
    accepted = capture_text_event_json(request.session, request.edit, request.version, event) == 1;
    moonbit_decref(event);
    if (accepted) {
      accepted_version = text_version();
      retire_tool_configuration();
    }
  }
  if (capture.color_dialog == GTK_WIDGET(dialog)) capture.color_dialog = NULL;
  gtk_widget_destroy(GTK_WIDGET(dialog));
  if (!accepted || !capture.editor || capture.closing || capture.session != request.session ||
      capture.text_edit != request.edit || text_version() != accepted_version) return;
  sync_text();
  if (capture.editor && !capture.closing && capture.session == request.session &&
      capture.text_edit == request.edit && text_version() == accepted_version &&
      capture_text_value(request.session, request.edit, MC_CAPTURE_TEXT_MODE) == MC_CAPTURE_TEXT_DEFAULTS)
    commit_text();
  refresh_context(); layout_controls();
  if (capture.editor) gtk_widget_queue_draw(capture.editor);
}
static gboolean input_key(gpointer data, const MCCanvasInput *input) {
  (void)data;
  if (!capture.text_edit || capture.closing) return FALSE;
  moonbit_string_t event = mc_canvas_input_json(input);
  int result = capture_text_ui_event(capture.session, capture.text_edit, text_version(), event,
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_WIDTH),
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_HEIGHT));
  moonbit_decref(event); sync_text();
  if (capture.editor) { layout_controls(); gtk_widget_queue_draw(capture.editor); }
  return result != MC_CAPTURE_TEXT_REJECTED;
}
static void property_event(gpointer data, GtkWidget *canvas, const MCCanvasInput *input) {
  (void)data;
  if (!capture.text_edit || capture.closing) return;
  moonbit_string_t event = mc_canvas_input_json(input);
  int result = capture_text_ui_event(capture.session, capture.text_edit, text_version(), event,
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_WIDTH),
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_HEIGHT));
  moonbit_decref(event);
  if (input->type == MC_UI_INPUT_POINTER_DOWN) mc_linux_canvas_set_capture(canvas, TRUE);
  if (input->type == MC_UI_INPUT_POINTER_UP || input->type == MC_UI_INPUT_CANCEL) mc_linux_canvas_set_capture(canvas, FALSE);
  sync_text();
  if (result == MC_CAPTURE_TEXT_CHOOSE_COLOR && !capture.color_dialog) {
    capture.color_dialog = gtk_color_chooser_dialog_new("颜色", GTK_WINDOW(capture.editor));
    gtk_window_set_modal(GTK_WINDOW(capture.color_dialog), TRUE);
    gtk_color_chooser_set_use_alpha(GTK_COLOR_CHOOSER(capture.color_dialog), FALSE);
    int rgb = (int)capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RGB);
    GdkRGBA rgba = {((rgb >> 16) & 255) / 255.0, ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0, 1};
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(capture.color_dialog), &rgba);
    ColorRequest *request = g_new(ColorRequest, 1);
    *request = (ColorRequest){capture.session, capture.text_edit, text_version()};
    g_signal_connect_data(capture.color_dialog, "response", G_CALLBACK(color_response), request, color_request_free, 0);
    gtk_widget_show(capture.color_dialog);
  }
  if (capture.editor) { layout_controls(); gtk_widget_queue_draw(capture.editor); }
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
    if (capture.session <= 0 || !open_toolbar())
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
  MCLinuxTextCallbacks input_callbacks = {input_event, input_action, input_key};
  capture.body_inputs = mc_linux_text_inputs_new(&input_callbacks, NULL);
  capture.property_inputs = mc_linux_text_inputs_new(&input_callbacks, NULL);
  capture.body_fixed = mc_linux_text_inputs_widget(capture.body_inputs);
  gtk_widget_set_no_show_all(capture.body_fixed, TRUE);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), capture.body_fixed);
  GtkWidget *masks = gtk_drawing_area_new();
  /* The overlay wrapper is pass-through; its child must not create a separate
   * full-screen input window or it would still intercept canvas events. */
  gtk_widget_set_has_window(masks, FALSE);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), masks);
  gtk_overlay_set_overlay_pass_through(GTK_OVERLAY(overlay), masks, TRUE);
  g_signal_connect(masks, "draw", G_CALLBACK(masks_draw), NULL);
  capture.toolbar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
  gtk_widget_set_size_request(capture.toolbar, -1, -1);
  gtk_container_set_border_width(GTK_CONTAINER(capture.toolbar), 0);
  gtk_widget_set_no_show_all(capture.toolbar, TRUE);
  gtk_style_context_add_class(gtk_widget_get_style_context(capture.toolbar), "mc-hud");
  MCLinuxCanvasCallbacks toolbar_callbacks = {toolbar_event, NULL, NULL, NULL};
  capture.toolbar_canvas = mc_linux_canvas_new(&toolbar_callbacks, NULL);
  mc_linux_canvas_preserve_focus_on_press(capture.toolbar_canvas, toolbar_field_focused);
  gtk_box_pack_start(GTK_BOX(capture.toolbar), capture.toolbar_canvas, FALSE, FALSE, 0);
  capture.property_overlay = gtk_overlay_new();
  gtk_widget_set_no_show_all(capture.property_overlay, TRUE);
  MCLinuxCanvasCallbacks property_callbacks = {property_event, NULL, NULL, NULL};
  capture.property_canvas = mc_linux_canvas_new(&property_callbacks, NULL);
  gtk_container_add(GTK_CONTAINER(capture.property_overlay), capture.property_canvas);
  gtk_overlay_add_overlay(GTK_OVERLAY(capture.property_overlay), mc_linux_text_inputs_widget(capture.property_inputs));
  gtk_box_pack_start(GTK_BOX(capture.toolbar), capture.property_overlay, FALSE, FALSE, 0);
  sync_control_values();
  mc_linux_hud_apply(capture.toolbar);
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
static const char *smoke_field_id(int field) {
  switch (field) {
  case MC_STYLE_FONT: return "style.fontSize";
  case MC_STYLE_OPACITY: return "style.opacity";
  case MC_STYLE_STROKE: return "style.stroke";
  case MC_STYLE_BLOCK: return "style.blockSize";
  default: return "";
  }
}
static GtkWidget *smoke_property(int field) {
  return mc_linux_text_inputs_field(capture.property_inputs, smoke_field_id(field));
}
static int smoke_property_frame(void) {
  if (!capture.text_edit) return 0;
  moonbit_string_t json = capture_text_frame(capture.session, capture.text_edit, MC_CAPTURE_TEXT_PROPERTIES,
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_WIDTH),
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_HEIGHT), 1, 0);
  int frame = ui_frame_open(json); moonbit_decref(json); return frame;
}
static gboolean smoke_semantic(const char *id, gboolean click) {
  int frame = smoke_property_frame();
  gboolean found = FALSE;
  for (int i = 0; i < ui_frame_semantic_count(frame); i++) {
    char *item = core_text(ui_frame_semantic_text(frame, i, MC_UI_SEM_ID));
    gboolean match = !strcmp(item, id); g_free(item);
    if (!match) continue;
    found = TRUE;
    if (click) {
      GdkEventButton event = {0};
      event.type = GDK_BUTTON_PRESS; event.button = 1;
      event.x = ui_frame_semantic_number(frame, i, MC_UI_SEM_X) + ui_frame_semantic_number(frame, i, MC_UI_SEM_WIDTH) / 2;
      event.y = ui_frame_semantic_number(frame, i, MC_UI_SEM_Y) + ui_frame_semantic_number(frame, i, MC_UI_SEM_HEIGHT) / 2;
      gboolean handled = FALSE;
      g_signal_emit_by_name(capture.property_canvas, "button-press-event", &event, &handled);
      /* A human can keep the button pressed across a main-loop turn. Leaving
       * the numeric input for another control in this row must not end edit. */
      smoke_pump();
      event.type = GDK_BUTTON_RELEASE;
      g_signal_emit_by_name(capture.property_canvas, "button-release-event", &event, &handled);
    }
    break;
  }
  if (frame) ui_frame_close(frame);
  return found;
}
static gboolean smoke_property_visible(int field) {
  if (!capture.text_edit || !gtk_widget_get_visible(capture.property_overlay)) return FALSE;
  if (field == MC_STYLE_COLOR) return smoke_semantic("style.color", FALSE);
  if (field == MC_STYLE_SHAPE) return smoke_semantic("style.shape.0", FALSE);
  GtkWidget *widget = smoke_property(field);
  return widget && gtk_widget_get_visible(widget);
}
static void smoke_buffer_set(GtkWidget *widget, const char *text) {
  GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(widget));
  gtk_text_buffer_begin_user_action(buffer); gtk_text_buffer_set_text(buffer, text, -1);
  GtkTextIter end; gtk_text_buffer_get_end_iter(buffer, &end); gtk_text_buffer_place_cursor(buffer, &end);
  gtk_text_buffer_end_user_action(buffer);
}
static void smoke_preedit(const char *text) {
  g_signal_emit_by_name(capture.entry, "preedit-changed", text);
}
static gboolean smoke_style_step(int field, gboolean increase) {
  GtkWidget *widget = smoke_property(field);
  if (!widget || !capture.editor) return FALSE;
  g_object_ref(widget);
  /* Color-dialog fixtures can leave the X11 toplevel inactive. A keyboard
   * event must follow real focus delivery, not just setting GtkWindow's stored
   * focus widget while its shared field still has no observed focus-in. */
  if (capture.x11) gdk_window_focus(gtk_widget_get_window(capture.editor), GDK_CURRENT_TIME);
  gtk_widget_grab_focus(widget);
  smoke_pump();
  GdkWindow *window = gtk_widget_get_window(widget);
  if (!capture.editor || widget != smoke_property(field) || !window || !gtk_widget_has_focus(widget) ||
      mc_linux_text_inputs_active(capture.property_inputs) != widget) {
    g_printerr("Linux numeric step: field focus was not delivered before the key event (field=%d).\n", field);
    g_object_unref(widget); return FALSE;
  }
  GdkEvent *event = gdk_event_new(GDK_KEY_PRESS);
  event->key.window = g_object_ref(window);
  event->key.send_event = TRUE; event->key.time = GDK_CURRENT_TIME;
  event->key.keyval = increase ? GDK_KEY_Up : GDK_KEY_Down;
  GdkDisplay *display = gdk_window_get_display(window);
  GdkKeymapKey *keys = NULL; gint count = 0;
  if (gdk_keymap_get_entries_for_keyval(gdk_keymap_get_for_display(display), event->key.keyval, &keys, &count) && count > 0) {
    event->key.hardware_keycode = keys[0].keycode; event->key.group = keys[0].group;
  }
  g_free(keys);
  gdk_event_set_device(event, gdk_seat_get_keyboard(gdk_display_get_default_seat(display)));
  gboolean handled = gtk_widget_event(widget, event);
  gdk_event_free(event); g_object_unref(widget);
  return handled;
}
static void smoke_style_number(int field, const char *text) {
  GtkWidget *widget = smoke_property(field);
  if (GTK_IS_TEXT_VIEW(widget)) smoke_buffer_set(widget, text);
}
typedef struct { int closed, results; gboolean valid, reject_pin; } CaptureHostProbe;
static gboolean smoke_pin_unavailable(gpointer data) { (void)data; return FALSE; }
static void smoke_host_closed(gpointer data) { ((CaptureHostProbe *)data)->closed++; }
static gboolean smoke_host_pin(GdkPixbuf *image, const GdkRectangle *bounds, gpointer data) {
  CaptureHostProbe *probe = data;
  probe->results++;
  probe->valid = probe->closed == 0 && image && bounds && bounds->width > 0 && bounds->height > 0 &&
                 mc_linux_capture_busy();
  return probe->valid && !probe->reject_pin;
}
static void smoke_style_rgba(int color, double opacity) {
  char *json = g_strdup_printf("{\"type\":\"color\",\"rgb\":%d}", color);
  moonbit_string_t value = core_string(json); g_free(json); text_event(value); moonbit_decref(value);
  char raw[G_ASCII_DTOSTR_BUF_SIZE]; g_ascii_dtostr(raw, sizeof(raw), opacity * 100);
  smoke_style_number(MC_STYLE_OPACITY, raw);
}
static moonbit_string_t smoke_core_string(const char *text) {
  glong length = 0; gunichar2 *utf16 = g_utf8_to_utf16(text, -1, NULL, &length, NULL);
  moonbit_string_t result = moonbit_make_string_raw((int32_t)length);
  if (length) memcpy(result, utf16, (gsize)length * sizeof(gunichar2));
  g_free(utf16); return result;
}
static int smoke_find_tool(const char *id) {
  int count = ui_frame_semantic_count(capture.toolbar_frame);
  for (int index = 0; index < count; index++) {
    char *identifier = core_text(ui_frame_semantic_text(capture.toolbar_frame, index, MC_UI_SEM_ID));
    gboolean matches = !strcmp(identifier, id);
    g_free(identifier);
    if (matches) return index;
  }
  return -1;
}
static gboolean smoke_toolbar_enabled(const char *id) {
  int index = smoke_find_tool(id);
  return index >= 0 && ui_frame_semantic_value(capture.toolbar_frame, index, MC_UI_SEM_ENABLED) == 1;
}
static gboolean smoke_toolbar_press(const char *id) {
  int index = smoke_find_tool(id);
  if (index < 0) return FALSE;
  AtkObject *node = atk_object_ref_accessible_child(gtk_widget_get_accessible(capture.toolbar_canvas), index);
  gboolean result = node && ATK_IS_ACTION(node) && atk_action_do_action(ATK_ACTION(node), 0);
  g_clear_object(&node);
  return result;
}
static gboolean smoke_toolbar_point(const char *id, int *x, int *y) {
  int index = smoke_find_tool(id);
  if (index < 0) return FALSE;
  const int frame = capture.toolbar_frame;
  return gtk_widget_translate_coordinates(capture.toolbar_canvas, capture.editor,
    (int)(ui_frame_semantic_number(frame, index, MC_UI_SEM_X) + ui_frame_semantic_number(frame, index, MC_UI_SEM_WIDTH)/2),
    (int)(ui_frame_semantic_number(frame, index, MC_UI_SEM_Y) + ui_frame_semantic_number(frame, index, MC_UI_SEM_HEIGHT)/2), x, y);
}
static void smoke_choose_tool(int kind) {
  static const char *ids[] = {"host.select", "builtin.image.rectangle", "builtin.image.arrow",
                             "builtin.image.text", "builtin.image.cover"};
  if (kind >= SELECT && kind <= REDACT) smoke_toolbar_press(ids[kind]);
}
static gboolean smoke_reopen_toolbar(void) {
  capture_toolbar_close(capture.toolbar_handle);
  capture.toolbar_handle = 0;
  capture.prepared_tool_candidate = 0;
  capture.prepared_snapshot = 0;
  if (!open_toolbar()) return FALSE;
  sync_toolbar_tool();
  layout_controls();
  return TRUE;
}
static gboolean smoke_contributions(void) {
  int original_session = capture.session, original_snapshot = published_tools;
  capture.session = image_session_create(capture.width, capture.height);
  if (capture.session <= 0) { capture.session = original_session; return FALSE; }
  if (!smoke_reopen_toolbar()) return FALSE;
  moonbit_string_t id = smoke_core_string("builtin.image.numberedRectangle");
  int enabled = tool_registry_snapshot_set_enabled(original_snapshot, id, 1);
  if (enabled <= 0) {
    moonbit_decref(id); image_session_dispose(capture.session); capture.session = original_session;
    smoke_reopen_toolbar();
    g_printerr("Linux contribution fixture: shared descriptor candidate rejected.\n"); return FALSE;
  }
  gboolean ok = enabled > 0 && smoke_find_tool("builtin.image.numberedRectangle") < 0;
  const char *reason = NULL;
  begin_text(-1, 60, 80);
  gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(capture.entry)), "未提交草稿", -1);
  ok = mc_linux_capture_preflight_tools(enabled, &reason) && !reason && image_session_count(capture.session) == 0 && ok;
  TextSnapshot *draft = snapshot_text(); ok = !strcmp(draft->text, "未提交草稿") && ok; snapshot_free(draft);
  smoke_preedit("组合中");
  ok = !mc_linux_capture_preflight_tools(enabled, &reason) && capture.composing && ok;
  smoke_preedit(""); cancel_text();
  gtk_widget_grab_focus(capture.canvas);
  ok = mc_linux_capture_preflight_tools(enabled, &reason) && ok;
  if (enabled > 0) mc_linux_capture_publish_tools(enabled);
  ok = smoke_toolbar_press("builtin.image.numberedRectangle") && ok;
  ok = capture.tool_command && !smoke_property_visible(MC_STYLE_SHAPE) &&
    smoke_property_visible(MC_STYLE_COLOR) && ok;
  GdkEventButton event = {0}; event.button = 1;
  event.x = capture.offset_x + 60 * capture.zoom; event.y = capture.offset_y + 80 * capture.zoom;
  canvas_press(capture.canvas, &event, NULL); motion(130, 140);
  ok = capture.dragging && image_session_count(capture.session) == 0 &&
    !mc_linux_capture_preflight_tools(original_snapshot, &reason) && ok;
  /* Cancellation must not spend a number or commit part of the contribution. */
  image_session_shape_event(capture.session, 2, 0, 0); capture.dragging = FALSE;
  if (gtk_widget_has_grab(capture.canvas)) gtk_grab_remove(capture.canvas);
  canvas_press(capture.canvas, &event, NULL);
  event.x = capture.offset_x + 130 * capture.zoom; event.y = capture.offset_y + 140 * capture.zoom;
  canvas_release(capture.canvas, &event, NULL);
  ok = image_session_count(capture.session) == 2 && ok;
  if (image_session_count(capture.session) == 2) {
    char *number = annotation_text(1);
    ok = !strcmp(number, "1") && image_session_value(capture.session, 0, 0) == RECTANGLE &&
      image_session_value(capture.session, 1, 0) == TEXT && ok; g_free(number);
  }
  ok = commit_text() && image_session_undo(capture.session) == 1 && image_session_count(capture.session) == 0 && ok;
  ok = image_session_redo(capture.session) == 1 && image_session_count(capture.session) == 2 && ok;
  int disabled = tool_registry_snapshot_set_enabled(enabled, id, 0);
  if (disabled > 0) mc_linux_capture_publish_tools(disabled); else ok = FALSE;
  ok = capture.tool == SELECT && !capture.tool_command && smoke_find_tool("builtin.image.numberedRectangle") < 0 &&
    image_session_count(capture.session) == 2 && smoke_find_tool("builtin.image.pin") >= 0 && ok;
  moonbit_string_t text = smoke_core_string("builtin.image.text"), rectangle = smoke_core_string("builtin.image.rectangle");
  int moved = tool_registry_snapshot_move(disabled, text, rectangle);
  moonbit_decref(text); moonbit_decref(rectangle); moonbit_decref(id);
  if (moved > 0) mc_linux_capture_publish_tools(moved); else ok = FALSE;
  ok = smoke_find_tool("builtin.image.text") == 1 && ok;
  ok = smoke_toolbar_press("builtin.image.text") && ok;
  ok = capture.tool == TEXT && image_session_count(capture.session) == 2 && ok;
  /* Prepared candidates are read-only until the caller has stored settings. */
  smoke_style_number(MC_STYLE_FONT, "31.25");
  double previous_default = editor_style_get(capture.style_bank, TEXT, MC_STYLE_FONT);
  ok = mc_linux_capture_preflight_tools(moved, &reason) && !reason &&
       editor_style_get(capture.style_bank, TEXT, MC_STYLE_FONT) == previous_default && ok;
  mc_linux_capture_publish_tools(moved);
  ok = editor_style_get(capture.style_bank, TEXT, MC_STYLE_FONT) == previous_default &&
       capture.font_size == 31.25 && image_session_count(capture.session) == 2 && ok;
  ok = commit_text() && editor_style_get(capture.style_bank, TEXT, MC_STYLE_FONT) == 31.25 && ok;
  /* Configuration defaults do not introduce document history. */
  cancel_text();
  ok = image_session_undo(capture.session) == 1 && image_session_count(capture.session) == 0 && ok;
  mc_linux_capture_publish_tools(original_snapshot);
  if (enabled > 0) tool_registry_snapshot_close(enabled);
  if (disabled > 0) tool_registry_snapshot_close(disabled);
  if (moved > 0) tool_registry_snapshot_close(moved);
  cancel_text();
  image_session_dispose(capture.session); capture.session = original_session;
  capture.selected = -1; ok = smoke_reopen_toolbar() && ok; sync_crop();
  g_print("Linux contribution fixture %s: slots, draft/IME/drag preflight, generic composite undo, disable and reorder.\n", ok ? "passed" : "FAILED");
  return ok;
}
static gboolean smoke_tool_styles(void) {
  int original_session = capture.session;
  cancel_text(); editor_style_dispose(capture.style_bank); capture.style_bank = editor_style_create();
  capture.session = image_session_create(capture.width, capture.height);
  if (capture.session <= 0) {
    capture.session = original_session;
    return FALSE;
  }
  if (!smoke_reopen_toolbar()) return FALSE;
  smoke_choose_tool(RECTANGLE);
  smoke_style_rgba(0x225577, .45);
  smoke_style_number(MC_STYLE_STROKE, "8");
  smoke_choose_tool(ARROW);
  gboolean ok = capture.color == editor_style_default(MC_STYLE_COLOR) && capture.opacity == 1 &&
                capture.stroke == editor_style_default(MC_STYLE_STROKE);
  smoke_style_rgba(0x66BB88, .7);
  smoke_style_number(MC_STYLE_STROKE, "12");
  smoke_choose_tool(REDACT);
  ok = capture.color == 0x111111 && capture.opacity == 1 && ok;
  smoke_style_rgba(0xCC8844, .25);
  smoke_choose_tool(TEXT);
  ok = capture.font_size == editor_style_default(MC_STYLE_FONT) && ok;
  smoke_style_rgba(0xABCDEF, .8);
  smoke_style_number(MC_STYLE_FONT, "40");
  smoke_choose_tool(RECTANGLE);
  ok = capture.color == 0x225577 && fabs(capture.opacity - .45) < .00001 && capture.stroke == 8 && ok;
  ok = commit_text() && image_session_add_rgba(capture.session, RECTANGLE, 50, 60, 80, 60,
                               capture.color, capture.stroke, capture.font_size, capture.opacity) == 1 && ok;
  capture.selected = 0;
  sync_style();
  smoke_style_rgba(0xFF3355, .2);
  smoke_style_number(MC_STYLE_STROKE, "6");
  ok = capture.color == 0xFF3355 && image_session_value(capture.session, 0, 5) == 0x225577 &&
       commit_text() && image_session_value(capture.session, 0, 5) == 0xFF3355 &&
       fabs(image_session_value(capture.session, 0, 8) - .2) < .00001 &&
       editor_style_get(capture.style_bank, RECTANGLE, MC_STYLE_COLOR) == 0x225577 && ok;
  smoke_choose_tool(ARROW);
  ok = capture.color == 0x66BB88 && fabs(capture.opacity - .7) < .00001 && capture.stroke == 12 && ok;
  smoke_choose_tool(RECTANGLE);
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
  smoke_choose_tool(TEXT);
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
  smoke_choose_tool(REDACT);
  ok = capture.color == 0xCC8844 && fabs(capture.opacity - .25) < .00001 && ok;
  cancel_text();
  image_session_dispose(capture.session);
  capture.session = original_session;
  editor_style_dispose(capture.style_bank);
  capture.style_bank = editor_style_create();
  ok = smoke_reopen_toolbar() && ok;
  g_print("Linux tool styles smoke %s: independent defaults, existing-object isolation, new/old text drafts.\n",
           ok ? "passed" : "FAILED");
  return ok;
}
static gboolean smoke_shape_variants(void) {
  int original_session = capture.session, original_bank = capture.style_bank;
  cancel_text();
  capture.session = image_session_create_viewport(capture.width, capture.height, 30, 50, 320, 200);
  capture.style_bank = editor_style_create();
  gboolean ok = smoke_reopen_toolbar();
  for (int tool = RECTANGLE; tool <= REDACT; tool += 3) {
    for (int shape = 0; shape < editor_style_shape_count(tool); shape++) {
      smoke_choose_tool(tool);
      char *shape_id = g_strdup_printf("style.shape.%d", shape);
      ok = smoke_semantic(shape_id, TRUE) && capture.shape == shape && ok;
      g_free(shape_id);
      if (shape == 2) {
        smoke_style_number(MC_STYLE_BLOCK, "16");
        ok = !smoke_property_visible(MC_STYLE_COLOR) &&
          smoke_property_visible(MC_STYLE_BLOCK) && ok;
      }
      int count = image_session_count(capture.session);
      GdkEventButton event = {0}; event.button = 1;
      event.x = capture.offset_x + 100 * capture.zoom; event.y = capture.offset_y + 100 * capture.zoom;
      ok = canvas_press(capture.canvas, &event, NULL) && ok;
      motion(180, 160);
      ok = image_session_count(capture.session) == count && ok;
      event.x = capture.offset_x + 180 * capture.zoom; event.y = capture.offset_y + 160 * capture.zoom;
      ok = canvas_release(capture.canvas, &event, NULL) && image_session_count(capture.session) == count + 1 &&
        image_session_value(capture.session, count, 9) == shape && ok;
      GdkPixbuf *image = flatten();
      ok = image != NULL && ok;
      if (image) {
        int stride = gdk_pixbuf_get_rowstride(image), channels = gdk_pixbuf_get_n_channels(image);
        const guchar *pixels = gdk_pixbuf_get_pixels(image);
        if (tool == REDACT && shape == 1) {
          const guchar *corner = pixels + 50 * stride + 70 * channels;
          const guchar *source = gdk_pixbuf_get_pixels(capture.image) + 100 * gdk_pixbuf_get_rowstride(capture.image) +
            100 * gdk_pixbuf_get_n_channels(capture.image);
          const guchar *center = pixels + 80 * stride + 110 * channels;
          ok = memcmp(corner, source, 3) == 0 && center[0] == 17 && center[1] == 17 && center[2] == 17 && ok;
        }
        if (shape == 2) {
          const guchar *a = pixels + 70 * stride + 90 * channels;
          ok = memcmp(a, a + channels, 3) == 0 && image_session_value(capture.session, count, 10) == 16 && ok;
        }
        g_object_unref(image);
      }
      ok = smoke_toolbar_enabled("host.undo") && smoke_toolbar_press("host.undo") && ok;
      ok = image_session_count(capture.session) == count && ok;
    }
  }
  cancel_text();
  image_session_dispose(capture.session); editor_style_dispose(capture.style_bank);
  capture.session = original_session; capture.style_bank = original_bank;
  ok = smoke_reopen_toolbar() && ok;
  g_print("Linux shape variants smoke %s: input, shared gesture commit, ellipse pixels, mosaic, undo.\n", ok ? "passed" : "FAILED");
  return ok;
}
static gboolean smoke_shared_properties(void) {
  gboolean ok = TRUE;
#define PROPERTY_CHECK(condition, description) do { if (!(condition)) { ok = FALSE; g_printerr("Linux shared properties: %s\n", description); } } while (0)
  int original_session = capture.session, original_bank = capture.style_bank;
  cancel_text();
  capture.session = image_session_create_viewport(capture.width, capture.height, 30, 50, 320, 200);
  capture.style_bank = editor_style_create();
  capture.selected = -1; sync_crop();
  if (!smoke_reopen_toolbar()) return FALSE;
  smoke_choose_tool(RECTANGLE);
  GtkWidget *stroke = smoke_property(MC_STYLE_STROKE);
  PROPERTY_CHECK(stroke && ATK_IS_TEXT(gtk_widget_get_accessible(stroke)) &&
      smoke_property_visible(MC_STYLE_SHAPE), "shared rectangle controls expose real editable and choice nodes");
  double revision = image_session_revision(capture.session);
  double default_stroke = editor_style_get(capture.style_bank, RECTANGLE, MC_STYLE_STROKE);
  smoke_style_number(MC_STYLE_STROKE, "-");
  int edit = capture.text_edit;
  smoke_choose_tool(ARROW);
  PROPERTY_CHECK(capture.tool == RECTANGLE && capture.text_edit == edit && !commit_text(), "invalid raw vetoes tool switch and publication");
  PROPERTY_CHECK(smoke_semantic("style.shape.1", TRUE) && capture.shape == 0, "shape switch cannot hide an invalid visible draft");
  const char *reason = NULL;
  PROPERTY_CHECK(!mc_linux_capture_preflight_tools(published_tools, &reason) && reason &&
      image_session_revision(capture.session) == revision && editor_style_get(capture.style_bank, RECTANGLE, MC_STYLE_STROKE) == default_stroke,
      "settings preflight preserves invalid raw and document/defaults");
  smoke_style_number(MC_STYLE_STROKE, "6.25");
  smoke_style_rgba(0x225577, .45);
  PROPERTY_CHECK(capture.stroke == 6.25 && editor_style_get(capture.style_bank, RECTANGLE, MC_STYLE_STROKE) == default_stroke,
      "fractional numeric input only changes shared draft");
  PROPERTY_CHECK(mc_linux_capture_preflight_tools(published_tools, &reason) && !reason &&
      editor_style_get(capture.style_bank, RECTANGLE, MC_STYLE_STROKE) == default_stroke,
      "prepared settings candidate is read-only before durable publication");
  mc_linux_capture_publish_tools(published_tools);
  PROPERTY_CHECK(editor_style_get(capture.style_bank, RECTANGLE, MC_STYLE_STROKE) == default_stroke &&
      capture.stroke == 6.25 && image_session_revision(capture.session) == revision,
      "settings reorder retains a valid draft without document history");
  GdkEventButton drag = {0}; drag.button = 1;
  drag.x = capture.offset_x + 80 * capture.zoom; drag.y = capture.offset_y + 90 * capture.zoom;
  PROPERTY_CHECK(canvas_press(capture.canvas, &drag, NULL), "rectangle gesture begins after defaults commit");
  drag.x = capture.offset_x + 200 * capture.zoom; drag.y = capture.offset_y + 170 * capture.zoom;
  PROPERTY_CHECK(canvas_release(capture.canvas, &drag, NULL) && image_session_count(capture.session) == 1 &&
      image_session_value(capture.session, 0, 6) == 6.25, "new shape retains fractional shared stroke");
  PROPERTY_CHECK(commit_text(), "finish automatic defaults before selecting existing object");
  capture.selected = 0; sync_style();
  revision = image_session_revision(capture.session);
  smoke_style_number(MC_STYLE_STROKE, "8.5"); smoke_style_rgba(0xAA3355, .7);
  PROPERTY_CHECK(image_session_value(capture.session, 0, 6) == 6.25 && capture.stroke == 8.5,
      "selected shape uses same preview-only transaction");
  GdkPixbuf *preview = flatten_preview(), *committed = flatten();
  gboolean pixels_differ = preview && committed && gdk_pixbuf_get_byte_length(preview) == gdk_pixbuf_get_byte_length(committed) &&
      memcmp(gdk_pixbuf_get_pixels(preview), gdk_pixbuf_get_pixels(committed), gdk_pixbuf_get_byte_length(preview));
  PROPERTY_CHECK(pixels_differ && image_session_revision(capture.session) == revision,
      "PNG preview contains pending style without publishing document");
  g_clear_object(&preview); g_clear_object(&committed);
  stroke = smoke_property(MC_STYLE_STROKE);
  gtk_widget_grab_focus(stroke); smoke_style_number(MC_STYLE_STROKE, "9.5");
  smoke_toolbar_press("host.undo");
  PROPERTY_CHECK(capture.stroke == 8.5 && image_session_revision(capture.session) == revision, "toolbar undo follows numeric draft");
  smoke_toolbar_press("host.redo");
  PROPERTY_CHECK(capture.stroke == 9.5 && commit_text() && image_session_value(capture.session, 0, 6) == 9.5 &&
      image_session_value(capture.session, 0, 5) == 0xAA3355 && editor_style_get(capture.style_bank, RECTANGLE, MC_STYLE_STROKE) == 6.25,
      "existing style publication never changes tool defaults");
  PROPERTY_CHECK(image_session_undo(capture.session) && image_session_value(capture.session, 0, 6) == 6.25 &&
      image_session_value(capture.session, 0, 5) == 0x225577 && image_session_redo(capture.session),
      "one document undo restores the complete property transaction");
  sync_style();
  PROPERTY_CHECK(smoke_semantic("style.shape.1", TRUE) && capture.shape == 1 && image_session_value(capture.session, 0, 9) == 0,
      "existing ellipse is previewed before publication");
  smoke_toolbar_press("host.undo");
  PROPERTY_CHECK(capture.shape == 0 && image_session_value(capture.session, 0, 9) == 0, "toolbar undo addresses shared shape draft without a native field");
  smoke_toolbar_press("host.redo");
  PROPERTY_CHECK(capture.shape == 1 && image_session_value(capture.session, 0, 9) == 0, "toolbar redo restores shared shape preview only");
  cancel_text();
  PROPERTY_CHECK(image_session_value(capture.session, 0, 9) == 0, "cancel does not publish shape preview");
  smoke_choose_tool(REDACT);
  GtkWidget *opacity = smoke_property(MC_STYLE_OPACITY);
  g_signal_emit_by_name(opacity, "preedit-changed", "组合");
  PROPERTY_CHECK(smoke_semantic("style.shape.2", TRUE) && capture.shape == 0 && mc_linux_text_inputs_composing(capture.property_inputs),
      "shape switching does not retire active IME");
  g_signal_emit_by_name(opacity, "preedit-changed", ""); smoke_pump();
  PROPERTY_CHECK(smoke_semantic("style.shape.2", TRUE) && capture.shape == 2 &&
      !smoke_property_visible(MC_STYLE_COLOR) && smoke_property_visible(MC_STYLE_BLOCK),
      "shared mosaic choice controls field visibility");
  smoke_style_number(MC_STYLE_BLOCK, "-");
  PROPERTY_CHECK(!commit_text() && smoke_semantic("style.shape.0", TRUE) && capture.shape == 2,
      "invalid mosaic size cannot be hidden or committed");
  smoke_style_number(MC_STYLE_BLOCK, "16");
  PROPERTY_CHECK(smoke_semantic("style.shape.0", TRUE) && smoke_property_visible(MC_STYLE_COLOR),
      "valid mosaic draft can return to solid cover");
  PROPERTY_CHECK(smoke_semantic("style.color", TRUE) && capture.color_dialog, "shared color activation opens native chooser");
  PROPERTY_CHECK(!mc_linux_capture_preflight_tools(published_tools, &reason), "live native chooser vetoes settings publication");
  PROPERTY_CHECK(capture.color_dialog && gtk_window_get_modal(GTK_WINDOW(capture.color_dialog)), "native chooser is modal");
  edit = capture.text_edit;
  int before_color = capture.color, before_version = text_version();
  revision = image_session_revision(capture.session);
  smoke_style_number(MC_STYLE_OPACITY, "31");
  PROPERTY_CHECK(capture.text_edit == edit && text_version() != before_version, "same owner can advance through a queued field event");
  if (capture.color_dialog) {
    GdkRGBA other = {1, 0, 0, 1};
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(capture.color_dialog), &other);
    gtk_dialog_response(GTK_DIALOG(capture.color_dialog), GTK_RESPONSE_OK);
  }
  PROPERTY_CHECK(capture.text_edit == edit && capture.color == before_color && capture.opacity == .31 &&
      image_session_revision(capture.session) == revision && editor_style_get(capture.style_bank, REDACT, MC_STYLE_OPACITY) == 1,
      "late OK for old version neither changes color nor publishes the newer draft");
  PROPERTY_CHECK(smoke_semantic("style.color", TRUE) && capture.color_dialog, "another chooser captures the current lease");
  moonbit_string_t mosaic = core_string("{\"type\":\"shape\",\"value\":2}");
  PROPERTY_CHECK(text_event(mosaic) && capture.shape == 2, "queued shape change invalidates chooser version");
  moonbit_decref(mosaic);
  if (capture.color_dialog) gtk_dialog_response(GTK_DIALOG(capture.color_dialog), GTK_RESPONSE_OK);
  PROPERTY_CHECK(capture.text_edit == edit && capture.shape == 2 && editor_style_get(capture.style_bank, REDACT, MC_STYLE_SHAPE) == 0,
      "rejected stale color cannot accidentally commit a newer mosaic draft");
  PROPERTY_CHECK(smoke_semantic("style.shape.0", TRUE) && smoke_semantic("style.color", TRUE) && capture.color_dialog,
      "restore solid cover and open a current chooser");
  if (capture.color_dialog) gtk_dialog_response(GTK_DIALOG(capture.color_dialog), GTK_RESPONSE_CANCEL);
  PROPERTY_CHECK(capture.text_edit == edit && editor_style_get(capture.style_bank, REDACT, MC_STYLE_OPACITY) == 1,
      "chooser cancellation does not publish pending numeric values");
  PROPERTY_CHECK(smoke_semantic("style.color", TRUE) && capture.color_dialog, "open a current chooser for successful color publication");
  if (capture.color_dialog) {
    GdkRGBA chosen = {0x33 / 255.0, 0x44 / 255.0, 0x55 / 255.0, 1};
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(capture.color_dialog), &chosen);
    gtk_dialog_response(GTK_DIALOG(capture.color_dialog), GTK_RESPONSE_OK);
  }
  PROPERTY_CHECK(capture.text_edit != edit && editor_style_get(capture.style_bank, REDACT, MC_STYLE_COLOR) == 0x334455 &&
      editor_style_get(capture.style_bank, REDACT, MC_STYLE_OPACITY) == .31 && image_session_revision(capture.session) == revision,
      "current successful color response atomically publishes valid defaults only");
  PROPERTY_CHECK(smoke_semantic("style.color", TRUE) && capture.color_dialog, "open a chooser for retirement");
  GtkWidget *dialog = capture.color_dialog ? g_object_ref(capture.color_dialog) : NULL;
  revision = image_session_revision(capture.session);
  cancel_text();
  PROPERTY_CHECK(!capture.color_dialog, "cancel retires color chooser before root owner disappears");
  if (dialog) { gtk_dialog_response(GTK_DIALOG(dialog), GTK_RESPONSE_OK); g_object_unref(dialog); }
  PROPERTY_CHECK(image_session_revision(capture.session) == revision && editor_style_get(capture.style_bank, REDACT, MC_STYLE_COLOR) == 0x334455,
      "late chooser response cannot publish into a retired owner");
  cancel_text(); image_session_dispose(capture.session); editor_style_dispose(capture.style_bank);
  capture.session = original_session; capture.style_bank = original_bank; capture.selected = -1;
  ok = smoke_reopen_toolbar() && ok; sync_crop();
  g_print("Linux shared properties fixture %s: real numeric/IME input, shared shape UI, preview/cancel/history, settings preflight and chooser retirement.\n", ok ? "passed" : "FAILED");
#undef PROPERTY_CHECK
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
  capture.host = (MCLinuxCaptureHost){smoke_host_pin, smoke_host_closed, &host_probe, NULL};
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
      const char *id = i ? "builtin.capture.translate" : "builtin.capture.ocr";
      if (!smoke_toolbar_point(id, &x, &y)) {
        ok = FALSE; g_printerr("XTest fixture: unavailable action missing from descriptor toolbar\n"); break;
      }
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
    ok = smoke_toolbar_point("builtin.image.text", &x, &y);
    if (!ok) g_printerr("XTest fixture: text contribution missing\n");
    if (ok) {
      motion_event(display, -1, ox + x, oy + y, 0);
      button_event(display, 1, TRUE, 0);
      button_event(display, 1, FALSE, 0);
      smoke_pump();
      ok = capture.tool == TEXT;
      if (!ok)
        g_printerr("XTest fixture: toolbar click routing failed\n");
    }
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
    GtkWidget *button = smoke_property(MC_STYLE_FONT);
    gtk_widget_translate_coordinates(button, capture.editor, gtk_widget_get_allocated_width(button) / 2,
                                     gtk_widget_get_allocated_height(button) / 2, &x, &y);
    motion_event(display, -1, ox + x, oy + y, 0);
    button_event(display, 1, TRUE, 0); button_event(display, 1, FALSE, 0); smoke_pump();
    smoke_style_number(MC_STYLE_FONT, "31.25");
    ok = capture.editing && capture.font_size == 31.25 && image_session_count(capture.session) == 0 &&
         gtk_window_get_focus(GTK_WINDOW(capture.editor)) == button && ok;
    if (!ok) g_printerr("XTest fixture: shared numeric input routing/focus failed\n");
  }
  mc_linux_capture_close();
  ok = host_probe.closed == 1 && host_probe.results == 0 && ok;
  dlclose(library);
  g_print("Linux XTest pointer fixture %s: frozen canvas, toolbar, inline text focus.\n",
          ok ? "passed" : "FAILED");
  return ok;
}
typedef struct { int session, style, edit, events; gboolean retire; MCLinuxTextInputs *inputs; } TextBridgeProbe;
static gboolean bridge_probe_event(gpointer data, moonbit_string_t event) {
  TextBridgeProbe *probe = data; probe->events++;
  int version = (int)capture_text_value(probe->session, probe->edit, MC_CAPTURE_TEXT_VERSION);
  gboolean accepted = capture_text_event_json(probe->session, probe->edit, version, event) == 1;
  if (probe->retire) {
    MCLinuxTextInputs *inputs = probe->inputs; probe->inputs = NULL; mc_linux_text_inputs_destroy(inputs);
  } else {
    moonbit_string_t json = capture_text_frame(probe->session, probe->edit, MC_CAPTURE_TEXT_INLINE, 200, 80, 1, 0);
    int frame = ui_frame_open(json); moonbit_decref(json);
    if (frame) { mc_linux_text_inputs_set_frame(probe->inputs, frame); ui_frame_close(frame); }
  }
  return accepted;
}
static void bridge_probe_destroy(GtkWidget *widget, gpointer data) {
  (void)widget; TextBridgeProbe *probe = data;
  MCLinuxTextInputs *inputs = probe->inputs; probe->inputs = NULL;
  mc_linux_text_inputs_destroy(inputs);
}
static gboolean smoke_bridge_retirement(void) {
  TextBridgeProbe probe = {0}; probe.session = image_session_create(640, 400); probe.style = editor_style_create();
  moonbit_string_t empty = core_string("");
  probe.edit = capture_text_begin(probe.session, probe.style, MC_CAPTURE_TEXT_NEW, empty,
      image_session_revision(probe.session), 10, 10, 200, 80); moonbit_decref(empty);
  MCLinuxTextCallbacks callbacks = {bridge_probe_event, NULL, NULL};
  probe.inputs = mc_linux_text_inputs_new(&callbacks, &probe);
  moonbit_string_t json = capture_text_frame(probe.session, probe.edit, MC_CAPTURE_TEXT_INLINE, 200, 80, 1, 0);
  int frame = ui_frame_open(json); moonbit_decref(json);
  gboolean ok = frame && mc_linux_text_inputs_set_frame(probe.inputs, frame);
  if (frame) ui_frame_close(frame);
  GtkWidget *view = mc_linux_text_inputs_field(probe.inputs, "annotation.text");
  if (!view) { mc_linux_text_inputs_destroy(probe.inputs); image_session_dispose(probe.session); editor_style_dispose(probe.style); return FALSE; }
  g_object_ref(view);
  smoke_buffer_set(view, "已确认😀");
  g_signal_emit_by_name(view, "preedit-changed", "迟到");
  g_signal_emit_by_name(view, "preedit-changed", "");
  int events = probe.events;
  mc_linux_text_inputs_destroy(probe.inputs); probe.inputs = NULL;
  smoke_pump();
  ok = probe.events == events && image_session_count(probe.session) == 0 && ok;
  g_object_unref(view);
  capture_text_cancel(probe.session, probe.edit, (int)capture_text_value(probe.session, probe.edit, MC_CAPTURE_TEXT_VERSION));
  empty = core_string("");
  probe.edit = capture_text_begin(probe.session, probe.style, MC_CAPTURE_TEXT_NEW, empty,
      image_session_revision(probe.session), 10, 10, 200, 80); moonbit_decref(empty);
  probe.inputs = mc_linux_text_inputs_new(&callbacks, &probe);
  json = capture_text_frame(probe.session, probe.edit, MC_CAPTURE_TEXT_INLINE, 200, 80, 1, 0);
  frame = ui_frame_open(json); moonbit_decref(json);
  if (frame) { mc_linux_text_inputs_set_frame(probe.inputs, frame); ui_frame_close(frame); } else ok = FALSE;
  view = mc_linux_text_inputs_field(probe.inputs, "annotation.text");
  if (view) {
    g_object_ref(view);
    char *limit = g_malloc0(10000); memset(limit, 'x', 9999);
    smoke_buffer_set(view, limit); g_free(limit);
    g_signal_emit_by_name(view, "preedit-changed", "你");
    g_signal_emit_by_name(view, "preedit-changed", "");
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));
    gtk_text_buffer_begin_user_action(buffer);
    gtk_text_buffer_insert_at_cursor(buffer, "你好", -1);
    gtk_text_buffer_end_user_action(buffer);
    smoke_pump();
    moonbit_string_t raw = capture_text_text(probe.session, probe.edit, MC_CAPTURE_TEXT_RAW);
    ok = !mc_linux_text_inputs_composing(probe.inputs) && Moonbit_array_length(raw) == 9999 &&
         gtk_text_buffer_get_char_count(buffer) == 9999 &&
         capture_text_value(probe.session, probe.edit, MC_CAPTURE_TEXT_VALID) == 1 && ok;
    moonbit_decref(raw);
    /* A rejected terminal result restores the old draft, not an orphaned
     * marked range: the next ordinary insertion must still be accepted. */
    gtk_text_buffer_insert_at_cursor(buffer, "a", -1);
    raw = capture_text_text(probe.session, probe.edit, MC_CAPTURE_TEXT_RAW);
    ok = Moonbit_array_length(raw) == 10000 && capture_text_value(probe.session, probe.edit, MC_CAPTURE_TEXT_VALID) == 1 && ok;
    moonbit_decref(raw);
    probe.retire = TRUE;
    smoke_buffer_set(view, "回调退休");
    ok = !probe.inputs && image_session_count(probe.session) == 0 && ok;
    g_object_unref(view);
  } else ok = FALSE;
  mc_linux_text_inputs_destroy(probe.inputs); probe.inputs = NULL;
  capture_text_cancel(probe.session, probe.edit, (int)capture_text_value(probe.session, probe.edit, MC_CAPTURE_TEXT_VERSION));
  empty = core_string("");
  probe.edit = capture_text_begin(probe.session, probe.style, MC_CAPTURE_TEXT_DEFAULTS, empty,
      image_session_revision(probe.session), 0, 0, 0, 0); moonbit_decref(empty);
  probe.retire = FALSE; probe.inputs = mc_linux_text_inputs_new(&callbacks, &probe);
  json = capture_text_frame(probe.session, probe.edit, MC_CAPTURE_TEXT_PROPERTIES,
      capture_text_value(probe.session, probe.edit, MC_CAPTURE_TEXT_ROW_WIDTH),
      capture_text_value(probe.session, probe.edit, MC_CAPTURE_TEXT_ROW_HEIGHT), 1, 0);
  frame = ui_frame_open(json); moonbit_decref(json);
  if (frame) { mc_linux_text_inputs_set_frame(probe.inputs, frame); ui_frame_close(frame); } else ok = FALSE;
  view = mc_linux_text_inputs_field(probe.inputs, "style.opacity");
  if (view) {
    /* Retirement of the first of two fields synchronously retires the owner:
     * the outer set_frame must not retain the second GList node across it. */
    g_signal_connect(view, "destroy", G_CALLBACK(bridge_probe_destroy), &probe);
    mc_linux_text_inputs_set_frame(probe.inputs, 0);
    ok = !probe.inputs && ok;
  } else ok = FALSE;
  mc_linux_text_inputs_destroy(probe.inputs);
  image_session_dispose(probe.session); editor_style_dispose(probe.style);
  g_print("Linux text bridge lifetime fixture %s: rejected IME result, cancelled idle, event and field-destroy reentrancy.\n", ok ? "passed" : "FAILED");
  return ok;
}
static gboolean smoke_shared_text(void) {
  gboolean ok = TRUE;
#define TEXT_CHECK(condition, description) do { if (!(condition)) { ok = FALSE; g_printerr("Linux shared text: %s\n", description); } } while (0)
  smoke_choose_tool(SELECT);
  if (capture.x11) gdk_window_focus(gtk_widget_get_window(capture.editor), GDK_CURRENT_TIME);
  begin_text(-1, 60, 80);
  smoke_pump();
  if (!capture.entry) { g_printerr("Linux shared text: failed to mount body\n"); return FALSE; }
  smoke_buffer_set(capture.entry, "截图 MoonBit 😀\r\n第二行");
  char *raw = core_text(capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RAW));
  TEXT_CHECK(!strcmp(raw, "截图 MoonBit 😀\n第二行"), "CRLF and astral text round trip"); g_free(raw);
  GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(capture.entry));
  gtk_text_buffer_begin_user_action(buffer); gtk_text_buffer_insert_at_cursor(buffer, "追加", -1); gtk_text_buffer_end_user_action(buffer);
  draft_undo(FALSE);
  TextSnapshot *draft = snapshot_text(); TEXT_CHECK(!strstr(draft->text, "追加") && image_session_count(capture.session) == 0, "draft undo must not commit"); snapshot_free(draft);
  draft_undo(TRUE); draft = snapshot_text(); TEXT_CHECK(strstr(draft->text, "追加"), "draft redo"); snapshot_free(draft);
  draft_undo(FALSE);
  /* Preedit is not inserted into GtkTextBuffer. Root keeps it separately and
   * reports unknown caret, never fabricates a position GTK did not expose. */
  smoke_preedit("拼😀");
  moonbit_string_t json = capture_text_frame(capture.session, capture.text_edit, MC_CAPTURE_TEXT_INLINE, 240, 80, 1, 0);
  int frame = ui_frame_open(json); moonbit_decref(json);
  TEXT_CHECK(frame > 0 && ui_frame_field_value(frame, 0, MC_UI_FIELD_SELECTION_KNOWN) == 0 && ui_frame_field_value(frame, 0, MC_UI_FIELD_MARKED_START) >= 0, "IME unknown selection");
  if (frame) ui_frame_close(frame);
  sync_text(); draft = snapshot_text(); TEXT_CHECK(!strstr(draft->text, "拼"), "same-identity redraw must not copy preedit into the buffer"); snapshot_free(draft);
  const char *reason = NULL;
  TEXT_CHECK(!commit_text() && !mc_linux_capture_preflight_tools(published_tools, &reason), "preflight must preserve live composition");
  smoke_preedit("");
  gtk_text_buffer_begin_user_action(buffer); gtk_text_buffer_insert_at_cursor(buffer, "拼好😀", -1); gtk_text_buffer_end_user_action(buffer);
  raw = core_text(capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RAW));
  TEXT_CHECK(strstr(raw, "拼好😀") && !mc_linux_text_inputs_composing(capture.body_inputs), "empty preedit followed by commit must not cancel"); g_free(raw);
  smoke_pump();
  raw = core_text(capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RAW));
  TEXT_CHECK(strstr(raw, "拼好😀"), "late empty-preedit idle cannot restore old text"); g_free(raw);
  smoke_preedit("未确认"); smoke_preedit(""); smoke_pump();
  raw = core_text(capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RAW));
  TEXT_CHECK(!strstr(raw, "未确认") && strstr(raw, "拼好😀"), "composition cancellation restores previous draft"); g_free(raw);
  GtkWidget *font = smoke_property(MC_STYLE_FONT), *opacity = smoke_property(MC_STYLE_OPACITY);
  TEXT_CHECK(font && opacity && ATK_IS_TEXT(gtk_widget_get_accessible(font)), "real accessible numeric input");
  gtk_widget_grab_focus(font);
  smoke_style_number(MC_STYLE_FONT, "-");
  sync_text();
  TEXT_CHECK(capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_VALID) == 0 && !commit_text() && !mc_linux_capture_preflight_tools(published_tools, &reason), "raw invalid numeric draft remains pending");
  GtkTextIter first, last; GtkTextBuffer *numbers = gtk_text_view_get_buffer(GTK_TEXT_VIEW(font));
  gtk_text_buffer_get_bounds(numbers, &first, &last); raw = gtk_text_buffer_get_text(numbers, &first, &last, FALSE);
  TEXT_CHECK(!strcmp(raw, "-"), "redraw must preserve invalid numeric raw"); g_free(raw);
  smoke_style_number(MC_STYLE_FONT, "31.25");
  GdkEventKey step_key = {0}; step_key.keyval = GDK_KEY_Up; gboolean stepped = FALSE;
  g_signal_emit_by_name(font, "key-press-event", &step_key, &stepped);
  TEXT_CHECK(stepped && capture.font_size == 32.25, "native ArrowUp delegates step to shared UI");
  step_key.keyval = GDK_KEY_Down; stepped = FALSE;
  g_signal_emit_by_name(font, "key-press-event", &step_key, &stepped);
  TEXT_CHECK(stepped && capture.font_size == 31.25, "native ArrowDown delegates step to shared UI");
  smoke_style_rgba(0x225577, .35);
  TEXT_CHECK(capture.font_size == 31.25 && fabs(capture.opacity - .35) < 1e-12 && image_session_count(capture.session) == 0, "fractional font and opacity preview");
  int version = text_version(); double revision = image_session_revision(capture.session);
  GdkPixbuf *preview = flatten_preview();
  TEXT_CHECK(preview && text_version() == version && image_session_revision(capture.session) == revision && capture.editing, "read-only PNG preparation"); g_clear_object(&preview);
  /* Focus is an input fact even when selection did not change. */
  gtk_widget_grab_focus(capture.entry); smoke_pump();
  smoke_toolbar_press("host.undo");
  raw = core_text(capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RAW));
  TEXT_CHECK(!strstr(raw, "拼好😀") && capture.opacity == .35, "toolbar undo follows focused body, not last numeric field"); g_free(raw);
  smoke_toolbar_press("host.redo");
  TEXT_CHECK(commit_text() && image_session_count(capture.session) == 1 && image_session_value(capture.session, 0, 7) == 31.25 && image_session_value(capture.session, 0, 8) == .35, "atomic body/style publication");
  TEXT_CHECK(editor_style_get(capture.style_bank, TEXT, MC_STYLE_FONT) == 31.25 && editor_style_get(capture.style_bank, TEXT, MC_STYLE_OPACITY) == .35, "new annotation publishes default bank with document");
  TEXT_CHECK(image_session_undo(capture.session) == 1 && image_session_count(capture.session) == 0 && image_session_redo(capture.session) == 1, "one document undo restores whole annotation");
  begin_text(0, 0, 0); smoke_buffer_set(capture.entry, "改过的文字");
  smoke_style_number(MC_STYLE_FONT, "40"); smoke_style_rgba(0xAA3355, .6);
  cancel_text();
  TEXT_CHECK(image_session_value(capture.session, 0, 7) == 31.25 && image_session_value(capture.session, 0, 8) == .35, "cancel keeps original style");
  begin_text(0, 0, 0); smoke_buffer_set(capture.entry, "改过的文字");
  TEXT_CHECK(commit_text() && editor_style_get(capture.style_bank, TEXT, MC_STYLE_FONT) == 31.25, "existing edit leaves tool defaults alone");
  char *text = annotation_text(0); TEXT_CHECK(!strcmp(text, "改过的文字"), "existing text commits"); g_free(text);
  TEXT_CHECK(image_session_undo(capture.session) == 1, "existing edit undo");
  text = annotation_text(0); TEXT_CHECK(strstr(text, "MoonBit"), "undo restores body"); g_free(text);
  image_session_redo(capture.session);
  /* Move preserves the complete annotation style; no native remeasure/rounding. */
  double height = image_session_value(capture.session, 0, 4);
  GdkEventButton gesture = {0}; gesture.button = 1;
  gesture.x = capture.offset_x + 100 * capture.zoom; gesture.y = capture.offset_y + 100 * capture.zoom;
  TEXT_CHECK(canvas_press(capture.canvas, &gesture, NULL), "text move begins");
  GdkEventMotion move = {0}; move.x = gesture.x + 15 * capture.zoom; move.y = gesture.y + 10 * capture.zoom;
  canvas_motion(capture.canvas, &move, NULL); gesture.x = move.x; gesture.y = move.y;
  TEXT_CHECK(canvas_release(capture.canvas, &gesture, NULL) && image_session_value(capture.session, 0, 1) == 75 && image_session_value(capture.session, 0, 7) == 31.25 && image_session_value(capture.session, 0, 4) == height, "move preserves fractional font and original height");
  TEXT_CHECK(smoke_property_visible(MC_STYLE_FONT) && smoke_property_visible(MC_STYLE_COLOR) && !smoke_property_visible(MC_STYLE_STROKE), "existing properties use shared row");
  smoke_style_number(MC_STYLE_FONT, "40");
  TEXT_CHECK(image_session_value(capture.session, 0, 7) == 31.25 && capture.font_size == 40, "property typing is preview only");
  GdkEventKey key = {0}; key.keyval = GDK_KEY_c; key.state = GDK_CONTROL_MASK;
  gtk_widget_grab_focus(smoke_property(MC_STYLE_FONT));
  TEXT_CHECK(!editor_key(capture.editor, &key, NULL), "numeric copy cannot export/close capture");
  smoke_style_number(MC_STYLE_FONT, "999");
  TEXT_CHECK(!commit_text(), "invalid numeric publication rejected");
  cancel_text();
  TEXT_CHECK(image_session_value(capture.session, 0, 7) == 31.25 && editor_style_get(capture.style_bank, TEXT, MC_STYLE_FONT) == 31.25, "invalid cancel does not mutate object or defaults");
  /* A concurrent core command invalidates the frozen pointer revision. */
  gesture.x = capture.offset_x + 100 * capture.zoom; gesture.y = capture.offset_y + 110 * capture.zoom;
  TEXT_CHECK(canvas_press(capture.canvas, &gesture, NULL) && capture.drag_annotation_id, "text drag freezes identity and revision");
  double before_x = image_session_value(capture.session, 0, 1);
  TEXT_CHECK(image_session_add(capture.session, RECTANGLE, 400, 300, 30, 30, 0, 2) == 1, "concurrent document command");
  gesture.x += 10 * capture.zoom; gesture.y += 5 * capture.zoom;
  canvas_release(capture.canvas, &gesture, NULL);
  TEXT_CHECK(image_session_value(capture.session, 0, 1) == before_x, "stale pointer release cannot overwrite newer document");
  cancel_text(); image_session_undo(capture.session); capture.selected = -1;
  g_print("Linux shared text fixture %s: real GTK input, UTF-16/IME, focus/history, root preview and atomic styles.\n", ok ? "passed" : "FAILED");
#undef TEXT_CHECK
  return ok;
}
gboolean mc_linux_capture_smoke(GtkApplication *application) {
  if (mc_linux_capture_busy())
    return FALSE;
  memset(&capture, 0, sizeof(capture));
  capture.application = application;
  CaptureHostProbe host_probe = {0};
  capture.host = (MCLinuxCaptureHost){smoke_host_pin, smoke_host_closed, &host_probe, NULL};
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
  gboolean ok = open_editor(source);
  g_object_unref(source);
  if (!ok) {
    mc_linux_capture_close();
    return FALSE;
  }
  while (gtk_events_pending())
    gtk_main_iteration();
#define CAPTURE_CHECK(condition) do { if (!(condition)) { ok = FALSE; g_printerr("Linux screenshot smoke line %d: %s\n", __LINE__, #condition); } } while (0)
  GtkWidget *original = capture.editor;
  GdkEventButton selection_event = {0};
  selection_event.button = 1;
  selection_event.x = capture.offset_x + 350 * capture.zoom;
  selection_event.y = capture.offset_y + 250 * capture.zoom;
  CAPTURE_CHECK(canvas_press(capture.canvas, &selection_event, NULL));
  selection_event.x = capture.offset_x + 30 * capture.zoom;
  selection_event.y = capture.offset_y + 50 * capture.zoom;
  CAPTURE_CHECK(canvas_release(capture.canvas, &selection_event, NULL) && !capture.selecting &&
       capture.editor == original && !gtk_window_get_decorated(GTK_WINDOW(original)));
  CAPTURE_CHECK(smoke_contributions() && smoke_tool_styles() && smoke_shape_variants() && smoke_shared_properties());
  CAPTURE_CHECK((editor_style_property_mask(context_kind()) == 0) && !smoke_property_visible(MC_STYLE_COLOR) &&
       !smoke_property_visible(MC_STYLE_FONT));
  smoke_choose_tool(TEXT);
  CAPTURE_CHECK(smoke_property_visible(MC_STYLE_COLOR) && smoke_property_visible(MC_STYLE_FONT) &&
       !smoke_property_visible(MC_STYLE_STROKE));
  CAPTURE_CHECK(smoke_style_step(MC_STYLE_FONT, TRUE));
  CAPTURE_CHECK(capture.font_size == editor_style_default(MC_STYLE_FONT) + editor_style_step(MC_STYLE_FONT) && image_session_count(capture.session) == 0);
  CAPTURE_CHECK(smoke_style_step(MC_STYLE_FONT, FALSE));
  smoke_choose_tool(RECTANGLE);
  CAPTURE_CHECK(smoke_property_visible(MC_STYLE_COLOR) && smoke_property_visible(MC_STYLE_STROKE) &&
       !smoke_property_visible(MC_STYLE_FONT));
  smoke_style_number(MC_STYLE_STROKE, "8");
  CAPTURE_CHECK(capture.stroke == 8);
  smoke_style_number(MC_STYLE_STROKE, "4");
  smoke_choose_tool(REDACT);
  CAPTURE_CHECK(!(editor_style_property_mask(context_kind()) == 0) && smoke_property_visible(MC_STYLE_COLOR) &&
       smoke_property_visible(MC_STYLE_OPACITY) && !smoke_property_visible(MC_STYLE_FONT) &&
       !smoke_property_visible(MC_STYLE_STROKE));
  for (int i = 0; i < 2; i++) {
    const char *id = i ? "builtin.capture.translate" : "builtin.capture.ocr";
    int index = smoke_find_tool(id);
    if (index < 0) { ok = FALSE; continue; }
    AtkObject *node = atk_object_ref_accessible_child(gtk_widget_get_accessible(capture.toolbar_canvas), index);
    AtkStateSet *state = node ? atk_object_ref_state_set(node) : NULL;
    const char *tip = node ? atk_object_get_description(node) : NULL;
    CAPTURE_CHECK(state && !atk_state_set_contains_state(state, ATK_STATE_ENABLED) && tip && *tip);
    g_clear_object(&state);
    g_clear_object(&node);
  }
  CAPTURE_CHECK(smoke_bridge_retirement() && smoke_shared_text());
  double r[10];
  CAPTURE_CHECK(image_session_add(capture.session, REDACT, 50, 60, 80, 60, 0, 4) == 1);
  CAPTURE_CHECK(hit_test(70, 80) == image_session_count(capture.session) - 1);
  GdkPixbuf *image = flatten();
  CAPTURE_CHECK(image && gdk_pixbuf_get_width(image) == 320 && gdk_pixbuf_get_height(image) == 200);
  if (image) {
    const guchar *p = gdk_pixbuf_get_pixels(image) + 30 * gdk_pixbuf_get_rowstride(image) +
                      30 * gdk_pixbuf_get_n_channels(image);
    CAPTURE_CHECK(p[0] == 0 && p[1] == 0 && p[2] == 0);
    g_object_unref(image);
  }
  CAPTURE_CHECK(copy_image());
  GtkClipboard *clip = gtk_clipboard_get(gdk_atom_intern_static_string("MOOJICUT_TEST_IMAGE"));
  image = gtk_clipboard_wait_for_image(clip);
  CAPTURE_CHECK(image && gdk_pixbuf_get_width(image) == 320);
  g_clear_object(&image);
  gtk_clipboard_clear(clip);
  /* A translucent colored cover must blend once on the source, including the
   * blank portion of an active native text editor, and preserve alpha on move. */
  CAPTURE_CHECK(image_session_add_rgba(capture.session, REDACT, 180, 160, 80, 50, 0xFF0000, 4, 24, .5) == 1);
  int cover = image_session_count(capture.session) - 1;
  double cover_rect[10];
  read_annotation(cover, cover_rect);
  cover_rect[0] += 5;
  CAPTURE_CHECK(update_annotation(cover, cover_rect) && image_session_value(capture.session, cover, 8) == .5);
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
      CAPTURE_CHECK(abs(pixel[c] - expected[c]) <= 1);
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
      CAPTURE_CHECK(abs(pixel[c] - expected[c]) <= 1);
    g_object_unref(live_image);
  } else
    ok = FALSE;
  cancel_text();
  image_session_undo(capture.session);
  image_session_undo(capture.session);
  capture.selected = 0;
  sync_style();
  smoke_style_number(MC_STYLE_OPACITY, "45");
  CAPTURE_CHECK(commit_text());
  read_annotation(0, r);
  r[0] += 1;
  CAPTURE_CHECK(update_annotation(0, r) && fabs(image_session_value(capture.session, 0, 8) - .45) < .001);
  image_session_undo(capture.session);
  image_session_undo(capture.session);
  cancel_text();
  capture.selected = -1;
  CAPTURE_CHECK(image_session_crop(capture.session, 40, 60, 200, 120) == 1);
  sync_crop();
  image = flatten();
  CAPTURE_CHECK(image && gdk_pixbuf_get_width(image) == 200);
  g_clear_object(&image);
  image_session_undo(capture.session);
  sync_crop();
  CAPTURE_CHECK(capture.crop[2] == 320);
  const char *preview_path = g_getenv("MOOJICUT_SMOKE_SCREENSHOT");
  if (preview_path && *preview_path) {
    /* Readable synthetic preview, after all behavior and privacy pixel checks.
     * It uses the same document and native renderer as interactive capture. */
    begin_text(0, 0, 0);
    if (capture.entry) smoke_buffer_set(capture.entry, "原地编辑");
    CAPTURE_CHECK(commit_text());
    read_annotation(0, r); r[0] = 150; r[1] = 100; r[2] = 180; r[3] = 70;
    CAPTURE_CHECK(update_annotation(0, r));
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
    CAPTURE_CHECK(preview && gdk_pixbuf_save(preview, path, "png", NULL, NULL));
    g_free(path);
    g_clear_object(&preview);
  }
  capture.host.can_pin = smoke_pin_unavailable;
  mc_linux_capture_refresh_capabilities();
  smoke_toolbar_press("builtin.image.pin");
  CAPTURE_CHECK(capture.editor && !smoke_toolbar_enabled("builtin.image.pin") && host_probe.closed == 0 && host_probe.results == 0);
  capture.host.can_pin = NULL;
  mc_linux_capture_refresh_capabilities();
  CAPTURE_CHECK(smoke_toolbar_enabled("builtin.image.pin"));
  smoke_choose_tool(RECTANGLE);
  smoke_style_number(MC_STYLE_STROKE, "9.25");
  int pin_edit = capture.text_edit;
  double pin_revision = image_session_revision(capture.session);
  host_probe.reject_pin = TRUE;
  CAPTURE_CHECK(smoke_toolbar_press("builtin.image.pin") && capture.editor && capture.text_edit == pin_edit &&
      capture.stroke == 9.25 && image_session_revision(capture.session) == pin_revision &&
      host_probe.closed == 0 && host_probe.results == 1);
  host_probe.reject_pin = FALSE;
  smoke_toolbar_press("builtin.image.pin");
  CAPTURE_CHECK(host_probe.closed == 1 && host_probe.results == 2 && host_probe.valid);
  mc_linux_capture_close();
  CAPTURE_CHECK(host_probe.closed == 1);
  gboolean geometry_ok = mc_selection_smoke();
  g_print("Linux selection geometry smoke %s: reverse regions, zoom hit areas, bounds, signed arrows.\n",
           geometry_ok ? "passed" : "FAILED");
  CAPTURE_CHECK(geometry_ok);
  CAPTURE_CHECK(smoke_pointer_route(application));
  g_print("Linux screenshot/selection smoke %s: retained overlay, inline multilingual text/re-edit/undo/style, "
          "crop export, masks, private clipboard, selection geometry.\n",
          ok ? "passed" : "FAILED");
#undef CAPTURE_CHECK
  return ok;
}
