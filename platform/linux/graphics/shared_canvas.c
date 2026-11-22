#include "shared_canvas.h"
#include <gtk/gtk-a11y.h>
#include <math.h>
#include <string.h>

typedef struct _MCLinuxCanvas MCLinuxCanvas;
typedef struct _MCLinuxCanvasClass { GtkDrawingAreaClass parent; } MCLinuxCanvasClass;
typedef struct _MCCanvasNode {
  AtkObject parent;
  GWeakRef owner;
  gint index, role, value_type;
  gchar *id, *label, *tooltip, *value_text;
  MCCanvasRect rect;
  double value, minimum, maximum, step;
  gboolean enabled, focused, has_min, has_max, has_step, active;
} MCCanvasNode;
typedef struct _MCCanvasNodeClass { AtkObjectClass parent; } MCCanvasNodeClass;
typedef struct _MCCanvasAccessible { GtkWidgetAccessible parent; } MCCanvasAccessible;
typedef struct _MCCanvasAccessibleClass { GtkWidgetAccessibleClass parent; } MCCanvasAccessibleClass;
struct _MCLinuxCanvas {
  GtkDrawingArea parent;
  MCLinuxCanvasCallbacks callbacks;
  void *context;
  gboolean (*preserve_focus_on_press)(void *context);
  int32_t frame, background;
  GPtrArray *nodes;
  gboolean dead, destroying, captured, pointer_down, cancelling, painting;
  gboolean delivered_size;
  gboolean delivered_appearance, dark;
  double width, height;
};

static void node_action_init(AtkActionIface *iface);
static void node_value_init(AtkValueIface *iface);
static void node_component_init(AtkComponentIface *iface);
static void accessible_component_init(AtkComponentIface *iface);
G_DEFINE_TYPE_WITH_CODE(MCCanvasNode, mc_canvas_node, ATK_TYPE_OBJECT,
  G_IMPLEMENT_INTERFACE(ATK_TYPE_ACTION, node_action_init)
  G_IMPLEMENT_INTERFACE(ATK_TYPE_VALUE, node_value_init)
  G_IMPLEMENT_INTERFACE(ATK_TYPE_COMPONENT, node_component_init))
G_DEFINE_TYPE_WITH_CODE(MCCanvasAccessible, mc_canvas_accessible, GTK_TYPE_WIDGET_ACCESSIBLE,
  G_IMPLEMENT_INTERFACE(ATK_TYPE_COMPONENT, accessible_component_init))
G_DEFINE_TYPE(MCLinuxCanvas, mc_linux_canvas, GTK_TYPE_DRAWING_AREA)

static MCLinuxCanvas *canvas_for(GtkWidget *widget) {
  return widget && G_TYPE_CHECK_INSTANCE_TYPE(widget, mc_linux_canvas_get_type())
    ? (MCLinuxCanvas *)widget : NULL;
}
static gchar *owned_utf8(moonbit_string_t text) {
  gchar *result = g_utf16_to_utf8((const gunichar2 *)text, Moonbit_array_length(text), NULL, NULL, NULL);
  moonbit_decref(text);
  return result ? result : g_strdup("");
}
static void emit_input(MCLinuxCanvas *canvas, const MCCanvasInput *input) {
  if (canvas->dead || !canvas->callbacks.event) return;
  g_object_ref(canvas);
  canvas->callbacks.event(canvas->context, GTK_WIDGET(canvas), input);
  g_object_unref(canvas);
}
static void emit_text(MCLinuxCanvas *canvas, int32_t type, const gchar *text, int32_t flags) {
  glong length = 0;
  gunichar2 *value = g_utf8_to_utf16(text, -1, NULL, &length, NULL);
  if (!value) return;
  MCCanvasInput input = {type, 0, 0, 0, 0, flags, value, (size_t)length};
  emit_input(canvas, &input);
  g_free(value);
}
static int32_t modifiers(GdkModifierType state) {
  return ((state & (GDK_CONTROL_MASK | GDK_META_MASK | GDK_SUPER_MASK)) ? MC_UI_INPUT_MOD : 0)
    | ((state & GDK_SHIFT_MASK) ? MC_UI_INPUT_SHIFT : 0);
}

static void color(cairo_t *cr, int32_t rgb) {
  cairo_set_source_rgb(cr, ((rgb >> 16) & 255) / 255.0,
                       ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0);
}
static void draw_rect(void *context, MCCanvasRect r, double radius, int32_t fill,
                      int32_t stroke, double width) {
  cairo_t *cr = context;
  double a = MAX(0, MIN(radius, MIN(r.width, r.height) / 2));
  cairo_new_path(cr);
  if (a > 0) {
    const double pi = 3.14159265358979323846;
    cairo_arc(cr, r.x + r.width - a, r.y + a, a, -pi/2, 0);
    cairo_arc(cr, r.x + r.width - a, r.y + r.height - a, a, 0, pi/2);
    cairo_arc(cr, r.x + a, r.y + r.height - a, a, pi/2, pi);
    cairo_arc(cr, r.x + a, r.y + a, a, pi, pi*1.5);
    cairo_close_path(cr);
  } else cairo_rectangle(cr, r.x, r.y, r.width, r.height);
  if (fill >= 0) { color(cr, fill); cairo_fill_preserve(cr); }
  if (stroke >= 0 && width > 0) {
    color(cr, stroke); cairo_set_line_width(cr, width); cairo_stroke(cr);
  } else cairo_new_path(cr);
}
static void draw_line(void *context, double x1, double y1, double x2, double y2,
                      int32_t rgb, double width) {
  if (rgb < 0 || width <= 0) return;
  cairo_t *cr = context;
  cairo_new_path(cr); cairo_move_to(cr, x1, y1); cairo_line_to(cr, x2, y2);
  color(cr, rgb); cairo_set_line_width(cr, width); cairo_stroke(cr);
}
static void draw_text(void *context, const MCCanvasText *text) {
  if (!text->length || text->rect.width <= 0 || text->rect.height <= 0 || text->size <= 0) return;
  gchar *utf8 = g_utf16_to_utf8((const gunichar2 *)text->text, (glong)text->length, NULL, NULL, NULL);
  if (!utf8) return;
  cairo_t *cr = context;
  cairo_save(cr);
  cairo_rectangle(cr, text->rect.x, text->rect.y, text->rect.width, text->rect.height); cairo_clip(cr);
  PangoLayout *layout = pango_cairo_create_layout(cr);
  PangoFontDescription *font = pango_font_description_new();
  pango_font_description_set_family(font, "sans");
  pango_font_description_set_absolute_size(font, text->size * PANGO_SCALE);
  pango_font_description_set_weight(font, text->weight == MC_UI_WEIGHT_BOLD ? PANGO_WEIGHT_BOLD
    : text->weight == MC_UI_WEIGHT_MEDIUM ? PANGO_WEIGHT_MEDIUM : PANGO_WEIGHT_NORMAL);
  pango_layout_set_font_description(layout, font);
  pango_layout_set_text(layout, utf8, -1);
  pango_layout_set_width(layout, (int)(text->rect.width * PANGO_SCALE));
  pango_layout_set_single_paragraph_mode(layout, text->single_line);
  pango_layout_set_height(layout, text->single_line ? -1 : (int)(text->rect.height * PANGO_SCALE));
  pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);
  pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
  pango_layout_set_alignment(layout, text->align == MC_UI_ALIGN_CENTER ? PANGO_ALIGN_CENTER
    : text->align == MC_UI_ALIGN_RIGHT ? PANGO_ALIGN_RIGHT : PANGO_ALIGN_LEFT);
  int height = 0;
  pango_layout_get_pixel_size(layout, NULL, &height);
  double y = text->rect.y + (text->valign == MC_UI_VALIGN_CENTER ? (text->rect.height - height) / 2 : 0);
  cairo_move_to(cr, text->rect.x, y); color(cr, text->color); pango_cairo_show_layout(cr, layout);
  pango_font_description_free(font); g_object_unref(layout); g_free(utf8);
  cairo_restore(cr);
}
gboolean mc_linux_canvas_paint(GtkWidget *widget, cairo_t *cr, double width, double height) {
  MCLinuxCanvas *canvas = canvas_for(widget);
  if (!canvas || canvas->dead || canvas->painting || !cr || !isfinite(width) || !isfinite(height)
      || width < 0 || height < 0 || width > 1e6 || height > 1e6) return FALSE;
  g_object_ref(canvas); canvas->painting = TRUE;
  cairo_save(cr); cairo_rectangle(cr, 0, 0, width, height); cairo_clip(cr);
  color(cr, canvas->background); cairo_paint(cr);
  MCCanvasPainter painter = {cr, draw_rect, draw_line, draw_text, NULL};
  gboolean ok = !canvas->frame || mc_canvas_draw_layer(canvas->frame, MC_UI_LAYER_COMMANDS, &painter);
  MCCanvasRect video;
  if (ok && canvas->callbacks.video && mc_canvas_video_rect(canvas->frame, &video)) {
    cairo_save(cr); cairo_rectangle(cr, video.x, video.y, video.width, video.height); cairo_clip(cr);
    canvas->callbacks.video(canvas->context, widget, cr, &video);
    cairo_restore(cr);
  }
  if (ok && !canvas->dead && canvas->frame) ok = mc_canvas_draw_layer(canvas->frame, MC_UI_LAYER_OVERLAY, &painter);
  cairo_restore(cr); canvas->painting = FALSE; g_object_unref(canvas);
  return ok && cairo_status(cr) == CAIRO_STATUS_SUCCESS;
}

/* Nodes cache semantic values, never borrow a frame string or retain its handle.
 * A removed/replaced node is made defunct before it can activate another ID. */
static MCLinuxCanvas *node_owner(MCCanvasNode *node) {
  MCLinuxCanvas *canvas = g_weak_ref_get(&node->owner);
  if (!canvas) return NULL;
  if (canvas->dead || !node->active || node->index < 0 || (guint)node->index >= canvas->nodes->len
      || g_ptr_array_index(canvas->nodes, node->index) != node) {
    g_object_unref(canvas); return NULL;
  }
  return canvas;
}
static AtkRole node_role(AtkObject *object) {
  switch (((MCCanvasNode *)object)->role) {
    case MC_UI_ROLE_BUTTON: return ATK_ROLE_PUSH_BUTTON;
    case MC_UI_ROLE_SLIDER: return ATK_ROLE_SLIDER;
    case MC_UI_ROLE_CHECKBOX: return ATK_ROLE_CHECK_BOX;
    case MC_UI_ROLE_TEXT: return ATK_ROLE_STATIC;
    default: return ATK_ROLE_PANEL;
  }
}
static const gchar *node_name(AtkObject *object) { return ((MCCanvasNode *)object)->label; }
static const gchar *node_description(AtkObject *object) { return ((MCCanvasNode *)object)->tooltip; }
static gint node_index(AtkObject *object) { return ((MCCanvasNode *)object)->active ? ((MCCanvasNode *)object)->index : -1; }
static AtkObject *node_parent(AtkObject *object) {
  MCLinuxCanvas *canvas = node_owner((MCCanvasNode *)object);
  if (!canvas) return NULL;
  AtkObject *parent = gtk_widget_get_accessible(GTK_WIDGET(canvas));
  g_object_unref(canvas); return parent;
}
static AtkStateSet *node_states(AtkObject *object) {
  MCCanvasNode *node = (MCCanvasNode *)object;
  AtkStateSet *states = atk_state_set_new();
  MCLinuxCanvas *canvas = node_owner(node);
  if (!canvas) { atk_state_set_add_state(states, ATK_STATE_DEFUNCT); return states; }
  if (node->enabled) { atk_state_set_add_state(states, ATK_STATE_ENABLED); atk_state_set_add_state(states, ATK_STATE_SENSITIVE); }
  if (node->role == MC_UI_ROLE_BUTTON || node->role == MC_UI_ROLE_SLIDER || node->role == MC_UI_ROLE_CHECKBOX)
    atk_state_set_add_state(states, ATK_STATE_FOCUSABLE);
  if (node->focused && gtk_widget_has_focus(GTK_WIDGET(canvas))) atk_state_set_add_state(states, ATK_STATE_FOCUSED);
  if (node->role == MC_UI_ROLE_CHECKBOX && node->value_type == MC_UI_VALUE_BOOL && node->value != 0)
    atk_state_set_add_state(states, ATK_STATE_CHECKED);
  if (gtk_widget_get_visible(GTK_WIDGET(canvas))) atk_state_set_add_state(states, ATK_STATE_VISIBLE);
  if (gtk_widget_get_mapped(GTK_WIDGET(canvas)) && node->rect.width > 0 && node->rect.height > 0
      && node->rect.x < gtk_widget_get_allocated_width(GTK_WIDGET(canvas)) && node->rect.x + node->rect.width > 0
      && node->rect.y < gtk_widget_get_allocated_height(GTK_WIDGET(canvas)) && node->rect.y + node->rect.height > 0)
    atk_state_set_add_state(states, ATK_STATE_SHOWING);
  g_object_unref(canvas); return states;
}
static void node_finalize(GObject *object) {
  MCCanvasNode *node = (MCCanvasNode *)object;
  g_weak_ref_clear(&node->owner);
  g_free(node->id); g_free(node->label); g_free(node->tooltip); g_free(node->value_text);
  G_OBJECT_CLASS(mc_canvas_node_parent_class)->finalize(object);
}
static void mc_canvas_node_class_init(MCCanvasNodeClass *klass) {
  G_OBJECT_CLASS(klass)->finalize = node_finalize;
  AtkObjectClass *accessible = ATK_OBJECT_CLASS(klass);
  accessible->get_name = node_name; accessible->get_description = node_description;
  accessible->get_role = node_role; accessible->get_parent = node_parent;
  accessible->get_index_in_parent = node_index; accessible->ref_state_set = node_states;
}
static void mc_canvas_node_init(MCCanvasNode *node) { g_weak_ref_init(&node->owner, NULL); node->index = -1; }
static gint action_count(AtkAction *action) {
  MCCanvasNode *node = (MCCanvasNode *)action;
  return node->role == MC_UI_ROLE_SLIDER ? 3
    : node->role == MC_UI_ROLE_BUTTON || node->role == MC_UI_ROLE_CHECKBOX ? 1 : 0;
}
static void focus_for_press(MCLinuxCanvas *canvas) {
  if (!canvas->preserve_focus_on_press || !canvas->preserve_focus_on_press(canvas->context))
    gtk_widget_grab_focus(GTK_WIDGET(canvas));
}
static const gchar *action_name(AtkAction *action, gint index) {
  static const gchar *names[] = {"activate", "increment", "decrement"};
  return index >= 0 && index < action_count(action) ? names[index] : NULL;
}
static gboolean do_action(AtkAction *action, gint index) {
  MCCanvasNode *node = (MCCanvasNode *)action;
  if (!node->enabled || index < 0 || index >= action_count(action)) return FALSE;
  MCLinuxCanvas *canvas = node_owner(node);
  if (!canvas) return FALSE;
  g_object_ref(node);
  gchar *id = g_strdup(node->id);
  focus_for_press(canvas);
  MCLinuxCanvas *after_focus = node_owner(node);
  gboolean valid = after_focus && node->enabled;
  if (valid) emit_text(after_focus, MC_UI_INPUT_ACTIVATE, id, 0);
  if (after_focus) g_object_unref(after_focus);
  g_free(id);
  /* Activation is dispatched first so the shared UI owns slider focus. Recheck
   * identity because that callback may replace the frame or destroy the view. */
  MCLinuxCanvas *current = valid && index ? node_owner(node) : NULL;
  if (current) {
    if (node->enabled) emit_text(current, MC_UI_INPUT_KEY, index == 1 ? "ArrowRight" : "ArrowLeft", 0);
    g_object_unref(current);
  }
  g_object_unref(node); g_object_unref(canvas); return valid;
}
static void node_action_init(AtkActionIface *iface) {
  iface->get_n_actions = action_count; iface->get_name = action_name; iface->do_action = do_action;
}
static void value_and_text(AtkValue *value, gdouble *number, gchar **text) {
  MCCanvasNode *node = (MCCanvasNode *)value;
  if (number) *number = node->value;
  if (text) *text = node->value_text && *node->value_text ? g_strdup(node->value_text) : NULL;
}
static AtkRange *value_range(AtkValue *value) {
  MCCanvasNode *node = (MCCanvasNode *)value;
  return node->has_min && node->has_max ? atk_range_new(node->minimum, node->maximum, NULL) : NULL;
}
static gdouble value_increment(AtkValue *value) {
  MCCanvasNode *node = (MCCanvasNode *)value;
  return node->has_step ? node->step : 0;
}
static void node_value_init(AtkValueIface *iface) {
  iface->get_value_and_text = value_and_text; iface->get_range = value_range; iface->get_increment = value_increment;
  /* Arbitrary set-value has no shared event contract. Expose increment/decrement
   * actions instead of fabricating a native value mutation. */
}
static void node_extents(AtkComponent *component, gint *x, gint *y, gint *w, gint *h, AtkCoordType type) {
  MCCanvasNode *node = (MCCanvasNode *)component;
  MCLinuxCanvas *canvas = node_owner(node);
  gint ox = 0, oy = 0;
  if (canvas) {
    GtkWidget *widget = GTK_WIDGET(canvas), *top = gtk_widget_get_toplevel(widget);
    gtk_widget_translate_coordinates(widget, top, 0, 0, &ox, &oy);
    if (type == ATK_XY_SCREEN && gtk_widget_get_window(top)) {
      gint tx = 0, ty = 0; gdk_window_get_origin(gtk_widget_get_window(top), &tx, &ty); ox += tx; oy += ty;
    }
  }
  if (x) *x = canvas ? (gint)floor(ox + node->rect.x) : G_MININT;
  if (y) *y = canvas ? (gint)floor(oy + node->rect.y) : G_MININT;
  if (w) *w = canvas ? (gint)ceil(node->rect.width) : 0;
  if (h) *h = canvas ? (gint)ceil(node->rect.height) : 0;
  if (canvas) g_object_unref(canvas);
}
static gboolean node_contains(AtkComponent *component, gint x, gint y, AtkCoordType type) {
  gint ox, oy, w, h; node_extents(component, &ox, &oy, &w, &h, type);
  return w > 0 && h > 0 && x >= ox && y >= oy && (double)x < (double)ox + w && (double)y < (double)oy + h;
}
static gboolean node_focus(AtkComponent *component) {
  MCCanvasNode *node = (MCCanvasNode *)component;
  MCLinuxCanvas *canvas = node_owner(node);
  if (!canvas || !node->enabled) { if (canvas) g_object_unref(canvas); return FALSE; }
  gtk_widget_grab_focus(GTK_WIDGET(canvas));
  gboolean focused = !canvas->dead && gtk_widget_has_focus(GTK_WIDGET(canvas));
  g_object_unref(canvas);
  /* A focus request must never invoke a button's action. Semantic activation
   * remains explicit via AtkAction; key focus is owned by the shared UI. */
  return focused;
}
static AtkLayer node_layer(AtkComponent *component) { (void)component; return ATK_LAYER_WIDGET; }
static void node_component_init(AtkComponentIface *iface) {
  iface->get_extents = node_extents; iface->contains = node_contains;
  iface->grab_focus = node_focus; iface->get_layer = node_layer;
}
static MCLinuxCanvas *accessible_canvas(AtkObject *object) {
  return canvas_for(gtk_accessible_get_widget(GTK_ACCESSIBLE(object)));
}
static gint child_count(AtkObject *object) {
  MCLinuxCanvas *canvas = accessible_canvas(object);
  return canvas && !canvas->dead ? (gint)canvas->nodes->len : 0;
}
static AtkObject *child_ref(AtkObject *object, gint index) {
  MCLinuxCanvas *canvas = accessible_canvas(object);
  return canvas && !canvas->dead && index >= 0 && (guint)index < canvas->nodes->len
    ? g_object_ref(g_ptr_array_index(canvas->nodes, index)) : NULL;
}
static AtkObject *child_at_point(AtkComponent *component, gint x, gint y, AtkCoordType type) {
  MCLinuxCanvas *canvas = accessible_canvas(ATK_OBJECT(component));
  if (!canvas || canvas->dead) return NULL;
  for (gint i = (gint)canvas->nodes->len - 1; i >= 0; i--) {
    AtkObject *node = g_ptr_array_index(canvas->nodes, i);
    if (node_contains(ATK_COMPONENT(node), x, y, type)) return g_object_ref(node);
  }
  return NULL;
}
static void accessible_component_init(AtkComponentIface *iface) { iface->ref_accessible_at_point = child_at_point; }
static void mc_canvas_accessible_class_init(MCCanvasAccessibleClass *klass) {
  AtkObjectClass *object = ATK_OBJECT_CLASS(klass);
  object->get_n_children = child_count; object->ref_child = child_ref;
}
static void mc_canvas_accessible_init(MCCanvasAccessible *object) { (void)object; }

static void cursor_update(MCLinuxCanvas *canvas) {
  if (!gtk_widget_get_realized(GTK_WIDGET(canvas))) return;
  const gchar *name = "default";
  switch (ui_frame_value(canvas->frame, MC_UI_FRAME_CURSOR)) {
    case MC_UI_CURSOR_RESIZE_HORIZONTAL: name = "ew-resize"; break;
    case MC_UI_CURSOR_POINTER: name = "pointer"; break;
    case MC_UI_CURSOR_CROSSHAIR: name = "crosshair"; break;
  }
  GdkCursor *cursor = gdk_cursor_new_from_name(gtk_widget_get_display(GTK_WIDGET(canvas)), name);
  gdk_window_set_cursor(gtk_widget_get_window(GTK_WIDGET(canvas)), cursor);
  if (cursor) g_object_unref(cursor);
}
static void node_retire(MCCanvasNode *node) {
  node->active = FALSE; node->index = -1; g_weak_ref_set(&node->owner, NULL);
}
gboolean mc_linux_canvas_set_frame(GtkWidget *widget, int32_t frame) {
  MCLinuxCanvas *canvas = canvas_for(widget);
  if (!canvas || canvas->dead || canvas->painting || frame < 0
      || (frame && ui_frame_command_count(frame, MC_UI_LAYER_COMMANDS) < 0)) return FALSE;
  if (frame == canvas->frame) return TRUE;
  g_object_ref(canvas);
  GPtrArray *old = canvas->nodes, *nodes = g_ptr_array_new_with_free_func(g_object_unref);
  GHashTable *by_id = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  for (guint i = 0; i < old->len; i++) {
    MCCanvasNode *node = g_ptr_array_index(old, i);
    g_hash_table_insert(by_id, g_strdup(node->id), node);
  }
  GArray *changes = g_array_new(FALSE, TRUE, sizeof(guint));
  int32_t count = frame ? ui_frame_semantic_count(frame) : 0;
  gboolean structure_changed = count != (int32_t)old->len;
  for (int32_t i = 0; i < count; i++) {
    gchar *id = owned_utf8(ui_frame_semantic_text(frame, i, MC_UI_SEM_ID));
    gint role = ui_frame_semantic_value(frame, i, MC_UI_SEM_ROLE);
    MCCanvasNode *node = g_hash_table_lookup(by_id, id);
    gboolean reused = node && node->role == role;
    if (reused) g_object_ref(node);
    else { node = g_object_new(mc_canvas_node_get_type(), NULL); structure_changed = TRUE; }
    if ((guint)i >= old->len || g_ptr_array_index(old, i) != node) structure_changed = TRUE;
    guint changed = 0;
    gboolean enabled = ui_frame_semantic_value(frame, i, MC_UI_SEM_ENABLED) == 1;
    gboolean focused = ui_frame_semantic_value(frame, i, MC_UI_SEM_FOCUSED) == 1;
    double value = ui_frame_semantic_number(frame, i, MC_UI_SEM_VALUE);
    if (reused && node->value != value) changed |= 1;
    if (reused && node->enabled != enabled) changed |= 2;
    if (reused && node->focused != focused) changed |= 4;
    gchar *label = owned_utf8(ui_frame_semantic_text(frame, i, MC_UI_SEM_LABEL));
    if (reused && g_strcmp0(node->label, label)) changed |= 8;
    g_free(node->id); g_free(node->label); g_free(node->tooltip); g_free(node->value_text);
    node->id = id; node->label = label;
    node->tooltip = owned_utf8(ui_frame_semantic_text(frame, i, MC_UI_SEM_TOOLTIP));
    node->value_text = owned_utf8(ui_frame_semantic_text(frame, i, MC_UI_SEM_VALUE_TEXT));
    node->index = i; node->role = role; node->enabled = enabled; node->focused = focused; node->value = value;
    node->value_type = ui_frame_semantic_value(frame, i, MC_UI_SEM_VALUE_TYPE);
    node->has_min = ui_frame_semantic_value(frame, i, MC_UI_SEM_HAS_MIN) == 1;
    node->has_max = ui_frame_semantic_value(frame, i, MC_UI_SEM_HAS_MAX) == 1;
    node->has_step = ui_frame_semantic_value(frame, i, MC_UI_SEM_HAS_STEP) == 1;
    node->minimum = ui_frame_semantic_number(frame, i, MC_UI_SEM_MIN);
    node->maximum = ui_frame_semantic_number(frame, i, MC_UI_SEM_MAX);
    node->step = ui_frame_semantic_number(frame, i, MC_UI_SEM_STEP);
    node->rect = (MCCanvasRect){ui_frame_semantic_number(frame,i,MC_UI_SEM_X), ui_frame_semantic_number(frame,i,MC_UI_SEM_Y),
      ui_frame_semantic_number(frame,i,MC_UI_SEM_WIDTH), ui_frame_semantic_number(frame,i,MC_UI_SEM_HEIGHT)};
    node->active = TRUE; g_weak_ref_set(&node->owner, canvas);
    g_ptr_array_add(nodes, node); g_array_append_val(changes, changed);
  }
  int32_t previous = canvas->frame; canvas->frame = frame; canvas->nodes = nodes;
  for (guint i = 0; i < old->len; i++) {
    MCCanvasNode *node = g_ptr_array_index(old, i);
    if (node->index < 0 || (guint)node->index >= nodes->len || g_ptr_array_index(nodes, node->index) != node) node_retire(node);
  }
  g_hash_table_unref(by_id);
  if (previous) ui_frame_close(previous);
  /* Signals can re-enter set_frame/destroy. Local arrays keep nodes alive and
   * frame identity prevents emitting stale notifications after that callback. */
  g_ptr_array_ref(nodes);
  cursor_update(canvas); gtk_widget_queue_draw(widget); gtk_widget_trigger_tooltip_query(widget);
  if (structure_changed && !canvas->dead && canvas->frame == frame) {
    AtkObject *accessible = g_object_ref(gtk_widget_get_accessible(widget));
    for (gint i = (gint)old->len - 1; i >= 0 && !canvas->dead && canvas->frame == frame; i--) {
      if ((guint)i >= nodes->len || g_ptr_array_index(old,i) != g_ptr_array_index(nodes,i))
        g_signal_emit_by_name(accessible,"children-changed::remove",(guint)i,g_ptr_array_index(old,i));
    }
    for (guint i = 0; i < nodes->len && !canvas->dead && canvas->frame == frame; i++) {
      if (i >= old->len || g_ptr_array_index(old,i) != g_ptr_array_index(nodes,i))
        g_signal_emit_by_name(accessible,"children-changed::add",i,g_ptr_array_index(nodes,i));
    }
    g_object_unref(accessible);
  }
  for (guint i = 0; i < old->len && !canvas->dead && canvas->frame == frame; i++) {
    MCCanvasNode *node = g_ptr_array_index(old, i);
    if (!node->active) atk_object_notify_state_change(ATK_OBJECT(node), ATK_STATE_DEFUNCT, TRUE);
  }
  for (guint i = 0; i < nodes->len && !canvas->dead && canvas->frame == frame; i++) {
    MCCanvasNode *node = g_ptr_array_index(nodes, i);
    guint changed = g_array_index(changes, guint, i);
    if (changed & 1) g_signal_emit_by_name(node, "value-changed", node->value, node->value_text);
    if (canvas->dead || canvas->frame != frame) break;
    if ((changed & 1) && node->role == MC_UI_ROLE_CHECKBOX && node->value_type == MC_UI_VALUE_BOOL)
      atk_object_notify_state_change(ATK_OBJECT(node), ATK_STATE_CHECKED, node->value != 0);
    if (canvas->dead || canvas->frame != frame) break;
    if (changed & 2) atk_object_notify_state_change(ATK_OBJECT(node), ATK_STATE_ENABLED, node->enabled);
    if (canvas->dead || canvas->frame != frame) break;
    if (changed & 4) atk_object_notify_state_change(ATK_OBJECT(node), ATK_STATE_FOCUSED, node->focused && gtk_widget_has_focus(widget));
    if (canvas->dead || canvas->frame != frame) break;
    if (changed & 8) g_object_notify(G_OBJECT(node), "accessible-name");
  }
  if (structure_changed && !canvas->dead && canvas->frame == frame)
    g_signal_emit_by_name(gtk_widget_get_accessible(widget), "visible-data-changed");
  g_array_unref(changes); g_ptr_array_unref(nodes); g_ptr_array_unref(old); g_object_unref(canvas);
  return TRUE;
}

void mc_linux_canvas_set_capture(GtkWidget *widget, gboolean capture) {
  MCLinuxCanvas *canvas = canvas_for(widget);
  if (!canvas || canvas->dead || canvas->captured == !!capture) return;
  canvas->captured = !!capture;
  if (capture) gtk_grab_add(widget);
  else if (gtk_widget_has_grab(widget)) gtk_grab_remove(widget);
}
void mc_linux_canvas_cancel(GtkWidget *widget) {
  MCLinuxCanvas *canvas = canvas_for(widget);
  if (!canvas || canvas->dead || canvas->cancelling) return;
  g_object_ref(canvas); canvas->cancelling = TRUE;
  canvas->pointer_down = FALSE; mc_linux_canvas_set_capture(widget, FALSE);
  MCCanvasInput input = {MC_UI_INPUT_CANCEL,0,0,0,0,0,NULL,0}; emit_input(canvas, &input);
  canvas->cancelling = FALSE; g_object_unref(canvas);
}
static gboolean canvas_draw(GtkWidget *widget, cairo_t *cr) {
  mc_linux_canvas_paint(widget, cr, gtk_widget_get_allocated_width(widget), gtk_widget_get_allocated_height(widget));
  return FALSE;
}
static gboolean button_press(GtkWidget *widget, GdkEventButton *event) {
  MCLinuxCanvas *canvas = (MCLinuxCanvas *)widget;
  if (event->button != 1 || event->type != GDK_BUTTON_PRESS || canvas->dead) return FALSE;
  g_object_ref(canvas); focus_for_press(canvas);
  if (!canvas->dead) {
    canvas->pointer_down = TRUE;
    MCCanvasInput input = {MC_UI_INPUT_POINTER_DOWN,event->x,event->y,0,0,modifiers(event->state),NULL,0}; emit_input(canvas,&input);
  }
  g_object_unref(canvas); return TRUE;
}
static gboolean button_release(GtkWidget *widget, GdkEventButton *event) {
  MCLinuxCanvas *canvas = (MCLinuxCanvas *)widget;
  if (event->button != 1 || canvas->dead) return FALSE;
  canvas->pointer_down = FALSE;
  MCCanvasInput input = {MC_UI_INPUT_POINTER_UP,event->x,event->y,0,0,modifiers(event->state),NULL,0}; emit_input(canvas,&input);
  return TRUE;
}
static gboolean motion(GtkWidget *widget, GdkEventMotion *event) {
  MCCanvasInput input = {MC_UI_INPUT_POINTER_MOVE,event->x,event->y,0,0,modifiers(event->state),NULL,0};
  emit_input((MCLinuxCanvas *)widget,&input); return TRUE;
}
static gboolean scroll_event(GtkWidget *widget, GdkEventScroll *event) {
  /* GTK Wayland sends a compatibility discrete event before the matching smooth
   * event, marked pointer-emulated (XInput2 does the same for wheel buttons).
   * This widget subscribes to smooth events, so consuming both would double it. */
  if (event->direction != GDK_SCROLL_SMOOTH && gdk_event_get_pointer_emulated((GdkEvent *)event)) return TRUE;
  double dx = 0, dy = 0; int32_t flags = modifiers(event->state);
  /* Shared input uses positive up/left, matching AppKit and the normalized
   * Windows wheel adapter; GDK's native axes point down/right. GDK3 smooth
   * deltas are fractional wheel steps, not AppKit logical pixels: Wayland
   * normalizes axis values by 10 and XInput2 by the scroll valuator increment.
   * Keep fractions but leave PRECISE clear so the shared layer applies units. */
  if (event->direction == GDK_SCROLL_SMOOTH) { dx = -event->delta_x; dy = -event->delta_y; }
  else if (event->direction == GDK_SCROLL_UP) dy = 1;
  else if (event->direction == GDK_SCROLL_DOWN) dy = -1;
  else if (event->direction == GDK_SCROLL_LEFT) dx = 1;
  else if (event->direction == GDK_SCROLL_RIGHT) dx = -1;
  MCCanvasInput input = {MC_UI_INPUT_SCROLL,event->x,event->y,dx,dy,flags,NULL,0};
  emit_input((MCLinuxCanvas *)widget,&input); return TRUE;
}
static gboolean key_press(GtkWidget *widget, GdkEventKey *event) {
  const gchar *key = NULL;
  switch (event->keyval) {
    case GDK_KEY_space: key = "Space"; break;
    case GDK_KEY_Escape: key = "Escape"; break;
    case GDK_KEY_Left: key = "ArrowLeft"; break; case GDK_KEY_Right: key = "ArrowRight"; break;
    case GDK_KEY_Up: key = "ArrowUp"; break; case GDK_KEY_Down: key = "ArrowDown"; break;
    case GDK_KEY_Tab: case GDK_KEY_ISO_Left_Tab: key = "Tab"; break;
    case GDK_KEY_Return: case GDK_KEY_KP_Enter: key = "Enter"; break;
    case GDK_KEY_Home: key = "Home"; break; case GDK_KEY_End: key = "End"; break;
    case GDK_KEY_z: case GDK_KEY_Z: key = "z"; break;
    case GDK_KEY_plus: case GDK_KEY_KP_Add: key = "+"; break;
    case GDK_KEY_equal: case GDK_KEY_KP_Equal: key = "="; break;
    case GDK_KEY_minus: case GDK_KEY_KP_Subtract: key = "-"; break;
    case GDK_KEY_0: case GDK_KEY_KP_0: key = "0"; break;
    case GDK_KEY_Delete: key = "Delete"; break; case GDK_KEY_BackSpace: key = "Backspace"; break;
    default: return FALSE; /* In particular, no dead/compose/IME keys. */
  }
  emit_text((MCLinuxCanvas *)widget,MC_UI_INPUT_KEY,key,modifiers(event->state)); return TRUE;
}
static gboolean focus_out(GtkWidget *widget, GdkEventFocus *event) {
  (void)event; mc_linux_canvas_cancel(widget); return FALSE;
}
static gboolean grab_broken(GtkWidget *widget, GdkEventGrabBroken *event) {
  (void)event; mc_linux_canvas_cancel(widget); return FALSE;
}
static void grab_notify(GtkWidget *widget, gboolean was_grabbed) {
  g_object_ref(widget);
  GtkWidgetClass *parent = GTK_WIDGET_CLASS(mc_linux_canvas_parent_class);
  if (parent->grab_notify) parent->grab_notify(widget,was_grabbed);
  /* GTK modal grabs and GDK device grabs have different notifications. */
  if (!was_grabbed) mc_linux_canvas_cancel(widget);
  g_object_unref(widget);
}
static void canvas_unmap(GtkWidget *widget) {
  g_object_ref(widget); mc_linux_canvas_cancel(widget);
  if (gtk_widget_get_mapped(widget)) GTK_WIDGET_CLASS(mc_linux_canvas_parent_class)->unmap(widget);
  g_object_unref(widget);
}
static void canvas_realize(GtkWidget *widget) {
  GTK_WIDGET_CLASS(mc_linux_canvas_parent_class)->realize(widget); cursor_update((MCLinuxCanvas *)widget);
}
static void appearance_update(MCLinuxCanvas *canvas) {
  GtkWidget *widget = GTK_WIDGET(canvas);
  if (canvas->dead || !gtk_widget_get_mapped(widget)) return;
  gboolean dark = FALSE;
  g_object_get(gtk_widget_get_settings(widget), "gtk-application-prefer-dark-theme", &dark, NULL);
  GdkRGBA background;
  if (gtk_style_context_lookup_color(gtk_widget_get_style_context(widget), "theme_bg_color", &background))
    dark = background.red * .2126 + background.green * .7152 + background.blue * .0722 < .5;
  if (canvas->delivered_appearance && canvas->dark == dark) return;
  canvas->delivered_appearance = TRUE; canvas->dark = dark;
  emit_text(canvas, MC_UI_INPUT_APPEARANCE, dark ? "dark" : "light", 0);
}
static void canvas_map(GtkWidget *widget) {
  GTK_WIDGET_CLASS(mc_linux_canvas_parent_class)->map(widget);
  appearance_update((MCLinuxCanvas *)widget);
}
static void canvas_style_updated(GtkWidget *widget) {
  GTK_WIDGET_CLASS(mc_linux_canvas_parent_class)->style_updated(widget);
  appearance_update((MCLinuxCanvas *)widget);
}
static void canvas_size_allocate(GtkWidget *widget, GtkAllocation *allocation) {
  GTK_WIDGET_CLASS(mc_linux_canvas_parent_class)->size_allocate(widget, allocation);
  MCLinuxCanvas *canvas = (MCLinuxCanvas *)widget;
  if (canvas->dead || (canvas->delivered_size && canvas->width == allocation->width && canvas->height == allocation->height)) return;
  canvas->width = allocation->width; canvas->height = allocation->height; canvas->delivered_size = TRUE;
  if (canvas->callbacks.resize) {
    g_object_ref(canvas); canvas->callbacks.resize(canvas->context, widget, canvas->width, canvas->height); g_object_unref(canvas);
  }
}
static gboolean tooltip_query(GtkWidget *widget, gint x, gint y, gboolean keyboard, GtkTooltip *tooltip) {
  MCLinuxCanvas *canvas = (MCLinuxCanvas *)widget;
  if (canvas->dead) return FALSE;
  for (gint i = (gint)canvas->nodes->len - 1; i >= 0; i--) {
    MCCanvasNode *node = g_ptr_array_index(canvas->nodes, i);
    MCCanvasRect r = node->rect;
    if ((keyboard ? node->focused : x >= r.x && y >= r.y && x < r.x+r.width && y < r.y+r.height)
        && node->tooltip && *node->tooltip) {
      gtk_tooltip_set_text(tooltip, node->tooltip);
      GdkRectangle area = {(gint)floor(r.x),(gint)floor(r.y),(gint)ceil(r.width),(gint)ceil(r.height)};
      gtk_tooltip_set_tip_area(tooltip,&area); return TRUE;
    }
  }
  return FALSE;
}
static void canvas_destroy(GtkWidget *widget) {
  MCLinuxCanvas *canvas = (MCLinuxCanvas *)widget;
  if (canvas->destroying) return;
  g_object_ref(canvas); canvas->destroying = TRUE;
  if (!canvas->dead) {
    mc_linux_canvas_cancel(widget);
    canvas->dead = TRUE;
    if (canvas->captured && gtk_widget_has_grab(widget)) gtk_grab_remove(widget);
    canvas->captured = FALSE;
    if (canvas->frame) { ui_frame_close(canvas->frame); canvas->frame = 0; }
    for (guint i = 0; i < canvas->nodes->len; i++) node_retire(g_ptr_array_index(canvas->nodes,i));
    if (canvas->callbacks.destroyed) canvas->callbacks.destroyed(canvas->context,widget);
    memset(&canvas->callbacks,0,sizeof(canvas->callbacks)); canvas->context = NULL;
  }
  GTK_WIDGET_CLASS(mc_linux_canvas_parent_class)->destroy(widget);
  canvas->destroying = FALSE; g_object_unref(canvas);
}
static void canvas_finalize(GObject *object) {
  MCLinuxCanvas *canvas = (MCLinuxCanvas *)object;
  g_ptr_array_unref(canvas->nodes);
  G_OBJECT_CLASS(mc_linux_canvas_parent_class)->finalize(object);
}
static void mc_linux_canvas_class_init(MCLinuxCanvasClass *klass) {
  G_OBJECT_CLASS(klass)->finalize = canvas_finalize;
  GtkWidgetClass *widget = GTK_WIDGET_CLASS(klass);
  widget->draw = canvas_draw; widget->button_press_event = button_press; widget->button_release_event = button_release;
  widget->motion_notify_event = motion; widget->scroll_event = scroll_event; widget->key_press_event = key_press;
  widget->focus_out_event = focus_out; widget->grab_broken_event = grab_broken;
  widget->grab_notify = grab_notify;
  widget->unmap = canvas_unmap; widget->realize = canvas_realize; widget->size_allocate = canvas_size_allocate;
  widget->map = canvas_map; widget->style_updated = canvas_style_updated;
  widget->query_tooltip = tooltip_query; widget->destroy = canvas_destroy;
  gtk_widget_class_set_accessible_type(widget, mc_canvas_accessible_get_type());
}
static void mc_linux_canvas_init(MCLinuxCanvas *canvas) {
  canvas->nodes = g_ptr_array_new_with_free_func(g_object_unref);
  gtk_widget_set_can_focus(GTK_WIDGET(canvas), TRUE); gtk_widget_set_has_tooltip(GTK_WIDGET(canvas), TRUE);
  gtk_widget_add_events(GTK_WIDGET(canvas), GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK | GDK_POINTER_MOTION_MASK
    | GDK_SCROLL_MASK | GDK_SMOOTH_SCROLL_MASK | GDK_KEY_PRESS_MASK | GDK_FOCUS_CHANGE_MASK);
}
GtkWidget *mc_linux_canvas_new(const MCLinuxCanvasCallbacks *callbacks, void *context) {
  MCLinuxCanvas *canvas = g_object_new(mc_linux_canvas_get_type(), NULL);
  if (callbacks) canvas->callbacks = *callbacks;
  canvas->context = context;
  return GTK_WIDGET(canvas);
}
void mc_linux_canvas_set_background(GtkWidget *widget, int32_t rgb) {
  MCLinuxCanvas *canvas = canvas_for(widget);
  if (!canvas || canvas->dead || rgb < 0 || rgb > 0xffffff || canvas->background == rgb) return;
  canvas->background = rgb;
  gtk_widget_queue_draw(widget);
}
void mc_linux_canvas_preserve_focus_on_press(GtkWidget *widget, gboolean (*preserve)(void *)) {
  MCLinuxCanvas *canvas = canvas_for(widget);
  if (canvas && !canvas->dead) canvas->preserve_focus_on_press = preserve;
}
