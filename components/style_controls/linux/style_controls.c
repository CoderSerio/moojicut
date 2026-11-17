#include "style_controls.h"
#include <math.h>
#include <string.h>

struct MCNumericControl {
  GtkWidget *group, *entry, *buttons[2];
  double value, minimum, maximum, step;
  MCNumericChanged on_change;
  MCControlFinished on_finish;
  gpointer data;
  gboolean syncing, blocked;
};
struct MCColorControl {
  GtkWidget *group, *button, *dialog;
  GtkWindow *parent;
  GdkRGBA value;
  MCColorChanged on_change;
  MCControlFinished on_finish;
  gpointer data;
  gboolean blocked, destroyed;
};
struct MCStyleControls {
  GtkWidget *row, *hint, *shapes, *shape_buttons[3];
  int tool;
  gboolean blocked;
  MCNumericControl *numbers[MC_STYLE_PROPERTY_COUNT];
  MCColorControl *color;
  MCStyleRange ranges[MC_STYLE_PROPERTY_COUNT];
  double values[MC_STYLE_PROPERTY_COUNT];
  unsigned mask;
  MCStyleChanged on_change;
  MCControlFinished on_finish;
  gpointer data;
};

static gboolean icon_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
  MCIconPath path = mc_icon_path((MCIcon)GPOINTER_TO_INT(data));
  MCIcon icon = (MCIcon)GPOINTER_TO_INT(data);
  double size = (icon == MC_ICON_CHEVRON_UP || icon == MC_ICON_CHEVRON_DOWN) ? 10 : 18;
  cairo_translate(cr, (gtk_widget_get_allocated_width(widget) - size) / 2.0,
                  (gtk_widget_get_allocated_height(widget) - size) / 2.0);
  cairo_scale(cr, size / 24, size / 24);
  GdkRGBA color;
  gtk_style_context_get_color(gtk_widget_get_style_context(widget), gtk_widget_get_state_flags(widget), &color);
  gdk_cairo_set_source_rgba(cr, &color);
  for (unsigned i = 0; i < path.count; i++) {
    const MCIconCommand *c = &path.commands[i];
    switch (c->op) {
    case 'M':
      cairo_move_to(cr, c->x1, c->y1);
      break;
    case 'L':
      cairo_line_to(cr, c->x1, c->y1);
      break;
    case 'C':
      cairo_curve_to(cr, c->x1, c->y1, c->x2, c->y2, c->x3, c->y3);
      break;
    case 'Z':
      cairo_close_path(cr);
      break;
    case 'F': {
      GdkRGBA shade = color; shade.alpha *= c->x1;
      gdk_cairo_set_source_rgba(cr, &shade); cairo_fill(cr);
      gdk_cairo_set_source_rgba(cr, &color); break;
    }
    }
  }
  gdk_cairo_set_source_rgba(cr, &color);
  cairo_set_line_width(cr, 2);
  cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
  cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
  if (mc_icon_filled(icon)) cairo_fill(cr); else cairo_stroke(cr);
  return FALSE;
}
GtkWidget *mc_style_icon_button(MCIcon icon, const char *label, GCallback callback, gpointer data) {
  GtkWidget *button = gtk_button_new(), *drawing = gtk_drawing_area_new();
  gtk_widget_set_has_window(drawing, FALSE);
  gtk_widget_set_size_request(drawing, 18, 18);
  gtk_widget_set_size_request(button, 32, 32);
  gtk_style_context_add_class(gtk_widget_get_style_context(button), "mc-icon-button");
  g_signal_connect(drawing, "draw", G_CALLBACK(icon_draw), GINT_TO_POINTER(icon));
  gtk_container_add(GTK_CONTAINER(button), drawing);
  gtk_widget_set_tooltip_text(button, label);
  atk_object_set_name(gtk_widget_get_accessible(button), label);
  if (callback)
    g_signal_connect(button, "clicked", callback, data);
  return button;
}
/* Attach this provider only to the screenshot HUD subtree, including native
 * control child widgets. Preferences, dialogs and the inline TextView retain
 * their own theme and input behavior. */
static void hud_provider(GtkWidget *widget, gpointer data) {
  gtk_style_context_add_provider(gtk_widget_get_style_context(widget), GTK_STYLE_PROVIDER(data),
                                 GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
  if (GTK_IS_CONTAINER(widget))
    gtk_container_forall(GTK_CONTAINER(widget), hud_provider, data);
}
void mc_style_hud_apply(GtkWidget *toolbar) {
  static const char css[] =
      ".mc-capture-hud { background-color: #292730; background-image: none; color: #ece8e2;"
      " border: 1px solid #514b59; border-radius: 8px; padding: 4px; box-shadow: 0 4px 12px alpha(black, "
      "0.25); }"
      ".mc-capture-hud button { background-image: none; background-color: transparent; color: #ece8e2;"
      " border: 1px solid transparent; border-radius: 7px; box-shadow: none; text-shadow: none;"
      " -gtk-icon-shadow: none; padding: 0; min-width: 26px; min-height: 26px; }"
      ".mc-capture-hud button:hover { background-color: #403b48; }"
      ".mc-capture-hud button:active, .mc-capture-hud button.mc-selected { background-color: #56505f;"
      " border-color: #686170; color: #fff9ef; }"
      ".mc-capture-hud button:focus { border-color: #b8b0bf; outline: none; }"
      ".mc-capture-hud button:disabled, .mc-capture-hud button:disabled * { color: #6f6978; }"
      ".mc-capture-hud separator { background-color: #514b59; min-width: 1px; margin: 6px 5px; }"
      ".mc-capture-hud entry { background-color: #201e26; background-image:none; color:#ece8e2;"
      " border:1px solid #514b59; border-radius:5px; min-height:26px; padding:0 4px; font-size:12px; }"
      ".mc-capture-hud button.mc-step { min-width:18px; min-height:13px; border-radius:3px; }"
      ".mc-capture-hud button.mc-color-swatch { min-width:0; min-height:0; border:0; padding:0;"
      " background:none; box-shadow:none; border-radius:50%; }"
      ".mc-capture-hud .mc-property-label { color:#b8b1bf; font-size:11px; margin-right:4px; }"
      ".mc-capture-hud .mc-context-row { min-height:32px; }"
      ".mc-capture-hud .mc-hint { color: #aaa3b0; font-size: 10px; }"
      ".mc-capture-hud .mc-font-label { color: #aaa3b0; }";
  GtkCssProvider *provider = gtk_css_provider_new();
  GError *error = NULL;
  if (!gtk_css_provider_load_from_data(provider, css, -1, &error)) {
    g_warning("Screenshot HUD styling: %s", error->message);
    g_clear_error(&error);
  }
  hud_provider(toolbar, provider);
  g_object_unref(provider);
}
GtkWidget *mc_style_separator(void) {
  GtkWidget *separator = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
  gtk_widget_set_valign(separator, GTK_ALIGN_CENTER);
  gtk_widget_set_size_request(separator, -1, 22);
  return separator;
}

static gboolean number_valid(MCNumericControl *control, double value) {
  return isfinite(value) && value >= control->minimum && value <= control->maximum;
}
static void number_sync(MCNumericControl *control) {
  char text[G_ASCII_DTOSTR_BUF_SIZE];
  g_ascii_formatd(text, sizeof(text), "%.6g", control->value);
  control->syncing = TRUE;
  if (g_strcmp0(gtk_entry_get_text(GTK_ENTRY(control->entry)), text))
    gtk_entry_set_text(GTK_ENTRY(control->entry), text);
  control->syncing = FALSE;
}
gboolean mc_numeric_control_set(MCNumericControl *control, double value) {
  if (!control || !number_valid(control, value))
    return FALSE;
  control->value = value;
  number_sync(control);
  return TRUE;
}
static void number_commit(MCNumericControl *control, double value) {
  if (control->blocked || !number_valid(control, value) || control->value == value)
    return;
  control->value = value;
  number_sync(control);
  if (control->on_change)
    control->on_change(value, control->data);
}
static void number_changed(GtkEditable *editable, gpointer data) {
  MCNumericControl *control = data;
  if (control->syncing || control->blocked)
    return;
  const char *text = gtk_entry_get_text(GTK_ENTRY(editable));
  char *end = NULL;
  double value = g_ascii_strtod(text, &end);
  if (*text && end && !*end)
    number_commit(control, value);
}
static gboolean number_focus_out(GtkWidget *widget, GdkEventFocus *event, gpointer data) {
  (void)widget;
  (void)event;
  number_sync(data);
  return FALSE;
}
static void number_step(GtkWidget *widget, gpointer data) {
  MCNumericControl *control = data;
  int direction = widget == control->buttons[0] ? 1 : -1;
  number_commit(control, CLAMP(control->value + direction * control->step,
                                control->minimum, control->maximum));
}
static gboolean number_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)widget;
  MCNumericControl *control = data;
  if (event->keyval == GDK_KEY_Escape || event->keyval == GDK_KEY_Return ||
      event->keyval == GDK_KEY_KP_Enter) {
    number_sync(control);
    if (control->on_finish)
      control->on_finish(control->data);
    return TRUE;
  }
  if (event->keyval == GDK_KEY_Up || event->keyval == GDK_KEY_Down) {
    number_step(control->buttons[event->keyval == GDK_KEY_Up ? 0 : 1], control);
    return TRUE;
  }
  return FALSE;
}
MCNumericControl *mc_numeric_control_new(const char *label, double value, double minimum,
                                         double maximum, double step, MCNumericChanged on_change,
                                         MCControlFinished on_finish, gpointer data) {
  if (!isfinite(minimum) || !isfinite(maximum) || minimum > maximum ||
      !isfinite(step) || step <= 0 || !isfinite(value) || value < minimum || value > maximum)
    return NULL;
  MCNumericControl *control = g_new0(MCNumericControl, 1);
  control->value = value;
  control->minimum = minimum;
  control->maximum = maximum;
  control->step = step;
  control->on_change = on_change;
  control->on_finish = on_finish;
  control->data = data;
  control->group = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
  g_object_set_data_full(G_OBJECT(control->group), "mc-numeric-control", control, g_free);
  GtkWidget *caption = gtk_label_new(label);
  gtk_style_context_add_class(gtk_widget_get_style_context(caption), "mc-property-label");
  gtk_box_pack_start(GTK_BOX(control->group), caption, FALSE, FALSE, 0);
  control->entry = gtk_entry_new();
  gtk_entry_set_width_chars(GTK_ENTRY(control->entry), 3);
  gtk_entry_set_max_width_chars(GTK_ENTRY(control->entry), 3);
  gtk_entry_set_max_length(GTK_ENTRY(control->entry), 12);
  gtk_entry_set_input_purpose(GTK_ENTRY(control->entry), GTK_INPUT_PURPOSE_NUMBER);
  gtk_entry_set_alignment(GTK_ENTRY(control->entry), .5);
  gtk_widget_set_valign(control->entry, GTK_ALIGN_CENTER);
  atk_object_set_name(gtk_widget_get_accessible(control->entry), label);
  gtk_widget_set_tooltip_text(control->entry, label);
  g_signal_connect(control->entry, "changed", G_CALLBACK(number_changed), control);
  g_signal_connect(control->entry, "focus-out-event", G_CALLBACK(number_focus_out), control);
  g_signal_connect(control->entry, "key-press-event", G_CALLBACK(number_key), control);
  gtk_box_pack_start(GTK_BOX(control->group), control->entry, FALSE, FALSE, 0);
  GtkWidget *steps = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_valign(steps, GTK_ALIGN_CENTER);
  for (int i = 0; i < 2; i++) {
    char *tip = g_strdup_printf("%s%s", i == 0 ? "增加" : "减少", label);
    GtkWidget *button = mc_style_icon_button(i == 0 ? MC_ICON_CHEVRON_UP : MC_ICON_CHEVRON_DOWN,
                                            tip, G_CALLBACK(number_step), control);
    g_free(tip);
    control->buttons[i] = button;
    gtk_widget_set_size_request(button, 20, 14);
    gtk_widget_set_size_request(gtk_bin_get_child(GTK_BIN(button)), 10, 10);
    gtk_widget_set_focus_on_click(button, FALSE);
    gtk_style_context_add_class(gtk_widget_get_style_context(button), "mc-step");
    gtk_box_pack_start(GTK_BOX(steps), button, FALSE, FALSE, 0);
  }
  gtk_box_pack_start(GTK_BOX(control->group), steps, FALSE, FALSE, 0);
  number_sync(control);
  return control;
}
GtkWidget *mc_numeric_control_widget(MCNumericControl *control) { return control->group; }
GtkWidget *mc_numeric_control_entry(MCNumericControl *control) { return control->entry; }
GtkWidget *mc_numeric_control_step_button(MCNumericControl *control, gboolean increase) {
  return control->buttons[increase ? 0 : 1];
}
void mc_numeric_control_set_blocked(MCNumericControl *control, gboolean blocked) {
  control->blocked = blocked;
}

static gboolean color_valid(const GdkRGBA *value) {
  return value && isfinite(value->red) && isfinite(value->green) && isfinite(value->blue) &&
         isfinite(value->alpha) && value->red >= 0 && value->red <= 1 && value->green >= 0 &&
         value->green <= 1 && value->blue >= 0 && value->blue <= 1 && value->alpha >= 0 && value->alpha <= 1;
}
gboolean mc_color_control_set(MCColorControl *control, const GdkRGBA *value) {
  if (!control || !color_valid(value))
    return FALSE;
  control->value = *value;
  gtk_widget_queue_draw(control->button);
  if (control->dialog)
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(control->dialog), value);
  return TRUE;
}
static gboolean swatch_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
  MCColorControl *control = data;
  double x = gtk_widget_get_allocated_width(widget) / 2.0, y = gtk_widget_get_allocated_height(widget) / 2.0;
  gboolean focused = gtk_widget_has_focus(control->button);
  double line_width = focused ? 2 : 1;
  double diameter = editor_style_swatch_size(), radius = (diameter - line_width) / 2;
  cairo_arc(cr, x, y, radius, 0, 2 * G_PI);
  cairo_save(cr);
  cairo_clip(cr);
  /* A small checkerboard makes alpha visible without a second color UI. */
  for (int row = 0; row < (int)ceil(diameter / 4); row++)
    for (int col = 0; col < (int)ceil(diameter / 4); col++) {
      double gray = (row + col) % 2 ? .38 : .68;
      cairo_set_source_rgb(cr, gray, gray, gray);
      cairo_rectangle(cr, x - diameter / 2 + col * 4, y - diameter / 2 + row * 4, 4, 4);
      cairo_fill(cr);
    }
  gdk_cairo_set_source_rgba(cr, &control->value);
  cairo_paint(cr);
  cairo_restore(cr);
  cairo_arc(cr, x, y, radius, 0, 2 * G_PI);
  cairo_set_line_width(cr, line_width);
  if (focused) cairo_set_source_rgb(cr, .76, .69, .95);
  else cairo_set_source_rgb(cr, .68, .64, .71);
  cairo_stroke(cr);
  return FALSE;
}
static gboolean swatch_press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)data;
  double radius = editor_style_swatch_size() / 2.0;
  double dx = event->x - gtk_widget_get_allocated_width(widget) / 2.0;
  double dy = event->y - gtk_widget_get_allocated_height(widget) / 2.0;
  return dx * dx + dy * dy > radius * radius;
}
static void color_dialog_destroyed(GtkWidget *dialog, gpointer data) {
  MCColorControl *control = data;
  if (control->dialog == dialog)
    control->dialog = NULL;
}
void mc_color_control_close_dialog(MCColorControl *control) {
  if (control && control->dialog)
    gtk_widget_destroy(control->dialog);
}
static void color_response(GtkDialog *dialog, int response, gpointer data) {
  MCColorControl *control = data;
  /* A consumer may close its editor from a callback. Keep this instance alive
   * through response cleanup, and do not restore focus after it was destroyed. */
  g_object_ref(control->group);
  g_object_ref(dialog);
  if (response == GTK_RESPONSE_OK && !control->blocked) {
    GdkRGBA value;
    gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(dialog), &value);
    if (color_valid(&value) && !gdk_rgba_equal(&control->value, &value)) {
      control->value = value;
      gtk_widget_queue_draw(control->button);
      if (control->on_change)
        control->on_change(&value, control->data);
    }
  }
  gtk_widget_destroy(GTK_WIDGET(dialog));
  if (control->on_finish && !control->destroyed)
    control->on_finish(control->data);
  g_object_unref(dialog);
  g_object_unref(control->group);
}
static void choose_color(GtkWidget *widget, gpointer data) {
  (void)widget;
  MCColorControl *control = data;
  if (control->blocked)
    return;
  if (control->dialog) {
    gtk_window_present(GTK_WINDOW(control->dialog));
    return;
  }
  control->dialog = gtk_color_chooser_dialog_new("标注颜色", control->parent);
  gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(control->dialog), &control->value);
  gtk_color_chooser_set_use_alpha(GTK_COLOR_CHOOSER(control->dialog), TRUE);
  gtk_window_set_modal(GTK_WINDOW(control->dialog), TRUE);
  gtk_window_set_keep_above(GTK_WINDOW(control->dialog), TRUE);
  gtk_window_set_destroy_with_parent(GTK_WINDOW(control->dialog), TRUE);
  g_signal_connect(control->dialog, "response", G_CALLBACK(color_response), control);
  g_signal_connect(control->dialog, "destroy", G_CALLBACK(color_dialog_destroyed), control);
  gtk_widget_show(control->dialog);
}
static void color_destroy(GtkWidget *widget, gpointer data) {
  (void)widget;
  MCColorControl *control = data;
  control->destroyed = TRUE;
  mc_color_control_close_dialog(control);
}
MCColorControl *mc_color_control_new(GtkWindow *parent, const GdkRGBA *value,
                                     MCColorChanged on_change, MCControlFinished on_finish,
                                     gpointer data) {
  if (!color_valid(value))
    return NULL;
  MCColorControl *control = g_new0(MCColorControl, 1);
  control->parent = parent;
  control->value = *value;
  control->on_change = on_change;
  control->on_finish = on_finish;
  control->data = data;
  control->group = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
  g_object_set_data_full(G_OBJECT(control->group), "mc-color-control", control, g_free);
  g_signal_connect(control->group, "destroy", G_CALLBACK(color_destroy), control);
  GtkWidget *label = gtk_label_new("颜色");
  gtk_style_context_add_class(gtk_widget_get_style_context(label), "mc-property-label");
  gtk_box_pack_start(GTK_BOX(control->group), label, FALSE, FALSE, 0);
  control->button = gtk_button_new();
  gtk_style_context_add_class(gtk_widget_get_style_context(control->button), "mc-color-swatch");
  gtk_widget_set_size_request(control->button, editor_style_swatch_size(), editor_style_swatch_size());
  gtk_widget_set_valign(control->button, GTK_ALIGN_CENTER);
  gtk_widget_set_focus_on_click(control->button, FALSE);
  GtkWidget *swatch = gtk_drawing_area_new();
  gtk_widget_set_has_window(swatch, FALSE);
  gtk_widget_set_size_request(swatch, editor_style_swatch_size(), editor_style_swatch_size());
  g_signal_connect(swatch, "draw", G_CALLBACK(swatch_draw), control);
  gtk_container_add(GTK_CONTAINER(control->button), swatch);
  gtk_widget_set_tooltip_text(control->button, "选择标注颜色与透明度");
  atk_object_set_name(gtk_widget_get_accessible(control->button), "标注颜色与透明度");
  g_signal_connect(control->button, "clicked", G_CALLBACK(choose_color), control);
  g_signal_connect(control->button, "button-press-event", G_CALLBACK(swatch_press), control);
  gtk_box_pack_start(GTK_BOX(control->group), control->button, FALSE, FALSE, 0);
  return control;
}
GtkWidget *mc_color_control_widget(MCColorControl *control) { return control->group; }
void mc_color_control_set_blocked(MCColorControl *control, gboolean blocked) { control->blocked = blocked; }

static GdkRGBA style_rgba(const double values[MC_STYLE_PROPERTY_COUNT]) {
  int color = (int)values[MC_STYLE_COLOR];
  return (GdkRGBA){((color >> 16) & 255) / 255.0, ((color >> 8) & 255) / 255.0,
                    (color & 255) / 255.0, values[MC_STYLE_OPACITY]};
}
static void style_finished(gpointer data) {
  MCStyleControls *controls = data;
  if (controls->on_finish)
    controls->on_finish(controls->data);
}
static void style_number_changed(double value, gpointer data) {
  MCNumericControl *number = data;
  MCStyleControls *controls = g_object_get_data(G_OBJECT(number->group), "mc-style-owner");
  int field = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(number->group), "mc-style-field"));
  controls->values[field] = value / controls->ranges[field].display_scale;
  if (field == MC_STYLE_OPACITY) {
    GdkRGBA color = style_rgba(controls->values);
    mc_color_control_set(controls->color, &color);
  }
  if (controls->on_change)
    controls->on_change(1u << field, controls->values, controls->data);
}
static void style_number_finished(gpointer data) {
  MCNumericControl *number = data;
  style_finished(g_object_get_data(G_OBJECT(number->group), "mc-style-owner"));
}
static void style_color_changed(const GdkRGBA *value, gpointer data) {
  MCStyleControls *controls = data;
  controls->values[MC_STYLE_COLOR] = ((int)round(value->red * 255) << 16) |
                                    ((int)round(value->green * 255) << 8) | (int)round(value->blue * 255);
  controls->values[MC_STYLE_OPACITY] = value->alpha;
  mc_numeric_control_set(controls->numbers[MC_STYLE_OPACITY],
                          value->alpha * controls->ranges[MC_STYLE_OPACITY].display_scale);
  if (controls->on_change)
    controls->on_change((1u << MC_STYLE_COLOR) | (1u << MC_STYLE_OPACITY), controls->values, controls->data);
}
static gboolean shape_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
  MCStyleControls *controls = data;
  int index = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(widget), "shape-index"));
  const MCIcon outline[] = {MC_ICON_RECTANGLE, MC_ICON_ELLIPSE, MC_ICON_MOSAIC};
  const MCIcon cover[] = {MC_ICON_REDACT, MC_ICON_COVER_ELLIPSE, MC_ICON_MOSAIC};
  return icon_draw(widget, cr, GINT_TO_POINTER(controls->tool == MC_STYLE_TOOL_COVER ? cover[index] : outline[index]));
}
static void shape_clicked(GtkWidget *widget, gpointer data) {
  MCStyleControls *controls = data;
  int index = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(widget), "shape-index"));
  if (controls->blocked || !(controls->mask & (1u << MC_STYLE_SHAPE)) ||
      index >= editor_style_shape_count(controls->tool) || controls->values[MC_STYLE_SHAPE] == index) return;
  controls->values[MC_STYLE_SHAPE] = index;
  if (controls->on_change) controls->on_change(1u << MC_STYLE_SHAPE, controls->values, controls->data);
  style_finished(controls);
}
void mc_style_controls_set_tool(MCStyleControls *controls, int tool) { controls->tool = tool; }
MCStyleControls *mc_style_controls_new(GtkWindow *parent, const MCStyleRange ranges[MC_STYLE_PROPERTY_COUNT],
                                      MCStyleChanged on_change, MCControlFinished on_finish,
                                      gpointer data) {
  for (int field = 0; field < MC_STYLE_PROPERTY_COUNT; field++)
    if (!isfinite(ranges[field].minimum) || !isfinite(ranges[field].maximum) ||
        !isfinite(ranges[field].step) || !isfinite(ranges[field].value) ||
        !isfinite(ranges[field].display_scale) || ranges[field].step <= 0 ||
        ranges[field].display_scale <= 0 || ranges[field].minimum > ranges[field].maximum ||
        ranges[field].value < ranges[field].minimum || ranges[field].value > ranges[field].maximum)
      return NULL;
  MCStyleControls *controls = g_new0(MCStyleControls, 1);
  memcpy(controls->ranges, ranges, sizeof(controls->ranges));
  for (int field = 0; field < MC_STYLE_PROPERTY_COUNT; field++)
    controls->values[field] = ranges[field].value;
  controls->on_change = on_change;
  controls->on_finish = on_finish;
  controls->data = data;
  controls->row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, editor_style_group_gap());
  g_object_set_data_full(G_OBJECT(controls->row), "mc-style-controls", controls, g_free);
  gtk_style_context_add_class(gtk_widget_get_style_context(controls->row), "mc-context-row");
  controls->hint = gtk_label_new("选择标注以调整样式");
  gtk_label_set_xalign(GTK_LABEL(controls->hint), 0);
  gtk_style_context_add_class(gtk_widget_get_style_context(controls->hint), "mc-property-label");
  gtk_box_pack_start(GTK_BOX(controls->row), controls->hint, FALSE, FALSE, 0);
  controls->shapes = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
  GtkWidget *label = gtk_label_new("形状");
  gtk_style_context_add_class(gtk_widget_get_style_context(label), "mc-property-label");
  gtk_box_pack_start(GTK_BOX(controls->shapes), label, FALSE, FALSE, 0);
  const char *shape_names[] = {"方框", "圆框", "马赛克"};
  for (int index = 0; index < 3; index++) {
    GtkWidget *button = controls->shape_buttons[index] = gtk_button_new();
    GtkWidget *glyph = gtk_drawing_area_new();
    gtk_widget_set_has_window(glyph, FALSE);
    gtk_widget_set_size_request(glyph, 18, 18);
    gtk_widget_set_size_request(button, 28, 28);
    gtk_widget_set_focus_on_click(button, FALSE);
    g_object_set_data(G_OBJECT(button), "shape-index", GINT_TO_POINTER(index));
    g_object_set_data(G_OBJECT(glyph), "shape-index", GINT_TO_POINTER(index));
    g_signal_connect(glyph, "draw", G_CALLBACK(shape_draw), controls);
    g_signal_connect(button, "clicked", G_CALLBACK(shape_clicked), controls);
    gtk_widget_set_tooltip_text(button, shape_names[index]);
    atk_object_set_name(gtk_widget_get_accessible(button), shape_names[index]);
    gtk_container_add(GTK_CONTAINER(button), glyph);
    gtk_box_pack_start(GTK_BOX(controls->shapes), button, FALSE, FALSE, 0);
  }
  gtk_box_pack_start(GTK_BOX(controls->row), controls->shapes, FALSE, FALSE, 0);
  GdkRGBA color = style_rgba(controls->values);
  controls->color = mc_color_control_new(parent, &color, style_color_changed, style_finished, controls);
  gtk_box_pack_start(GTK_BOX(controls->row), mc_color_control_widget(controls->color), FALSE, FALSE, 0);
  const int fields[] = {MC_STYLE_FONT, MC_STYLE_STROKE, MC_STYLE_OPACITY, MC_STYLE_BLOCK};
  const char *labels[] = {"字号", "线宽", "不透明度 %", "颗粒"};
  for (unsigned i = 0; i < G_N_ELEMENTS(fields); i++) {
    int field = fields[i];
    const MCStyleRange *range = &ranges[field];
    MCNumericControl *number = mc_numeric_control_new(labels[i], range->value * range->display_scale,
      range->minimum * range->display_scale, range->maximum * range->display_scale,
      range->step * range->display_scale, style_number_changed, style_number_finished, NULL);
    controls->numbers[field] = number;
    number->data = number;
    g_object_set_data(G_OBJECT(number->group), "mc-style-owner", controls);
    g_object_set_data(G_OBJECT(number->group), "mc-style-field", GINT_TO_POINTER(field));
    gtk_box_pack_start(GTK_BOX(controls->row), number->group, FALSE, FALSE, 0);
  }
  gtk_widget_show_all(controls->row);
  gtk_widget_set_no_show_all(controls->row, TRUE);
  gtk_widget_set_no_show_all(controls->hint, TRUE);
  gtk_widget_set_no_show_all(controls->shapes, TRUE);
  for (int i = 0; i < 3; i++) gtk_widget_set_no_show_all(controls->shape_buttons[i], TRUE);
  gtk_widget_set_no_show_all(mc_color_control_widget(controls->color), TRUE);
  for (unsigned i = 0; i < G_N_ELEMENTS(fields); i++)
    gtk_widget_set_no_show_all(controls->numbers[fields[i]]->group, TRUE);
  mc_style_controls_sync(controls, 0, controls->values);
  return controls;
}
GtkWidget *mc_style_controls_widget(MCStyleControls *controls) { return controls->row; }
void mc_style_controls_sync(MCStyleControls *controls, unsigned mask, const double values[MC_STYLE_PROPERTY_COUNT]) {
  if (!controls)
    return;
  controls->mask = mask;
  gtk_widget_set_visible(controls->row, mask != 0);
  memmove(controls->values, values, sizeof(controls->values));
  GdkRGBA color = style_rgba(values);
  mc_color_control_set(controls->color, &color);
  gtk_widget_set_visible(mc_color_control_widget(controls->color), (mask & (1u << MC_STYLE_COLOR)) != 0);
  for (int field = 0; field < MC_STYLE_PROPERTY_COUNT; field++)
    if (controls->numbers[field]) {
      mc_numeric_control_set(controls->numbers[field], values[field] * controls->ranges[field].display_scale);
      gtk_widget_set_visible(controls->numbers[field]->group, (mask & (1u << field)) != 0);
    }
  gtk_widget_set_visible(controls->shapes, (mask & (1u << MC_STYLE_SHAPE)) != 0);
  for (int i = 0; i < 3; i++) {
    GtkWidget *button = controls->shape_buttons[i];
    gtk_widget_set_visible(button, i < editor_style_shape_count(controls->tool));
    GtkStyleContext *style = gtk_widget_get_style_context(button);
    if (i == (int)values[MC_STYLE_SHAPE]) gtk_style_context_add_class(style, "mc-selected");
    else gtk_style_context_remove_class(style, "mc-selected");
    gtk_widget_queue_draw(button);
  }
  gtk_widget_set_visible(controls->hint, FALSE);
}
void mc_style_controls_set_blocked(MCStyleControls *controls, gboolean blocked) {
  if (!controls)
    return;
  controls->blocked = blocked;
  gtk_widget_set_sensitive(controls->shapes, !blocked);
  mc_color_control_set_blocked(controls->color, blocked);
  for (int field = 0; field < MC_STYLE_PROPERTY_COUNT; field++)
    if (controls->numbers[field])
      mc_numeric_control_set_blocked(controls->numbers[field], blocked);
}
void mc_style_controls_close_dialog(MCStyleControls *controls) {
  if (controls)
    mc_color_control_close_dialog(controls->color);
}
GtkWidget *mc_style_controls_entry(MCStyleControls *controls, int field) {
  return field >= 0 && field < MC_STYLE_PROPERTY_COUNT && controls->numbers[field] ? controls->numbers[field]->entry : NULL;
}
GtkWidget *mc_style_controls_step_button(MCStyleControls *controls, int field, gboolean increase) {
  return field >= 0 && field < MC_STYLE_PROPERTY_COUNT && controls->numbers[field]
    ? mc_numeric_control_step_button(controls->numbers[field], increase) : NULL;
}
gboolean mc_style_controls_property_visible(MCStyleControls *controls, int field) {
  if (field == MC_STYLE_SHAPE) return gtk_widget_get_visible(controls->shapes);
  if (field == MC_STYLE_COLOR)
    return gtk_widget_get_visible(mc_color_control_widget(controls->color));
  return field >= 0 && field < MC_STYLE_PROPERTY_COUNT && controls->numbers[field] &&
         gtk_widget_get_visible(controls->numbers[field]->group);
}

/* Independent instances exercise native signals without touching the desktop
 * clipboard or application document. This is used only by --smoke. */
typedef struct { int calls, finishes; unsigned fields; double values[MC_STYLE_PROPERTY_COUNT]; } StyleProbe;
static void smoke_style_changed(unsigned fields, const double values[MC_STYLE_PROPERTY_COUNT], gpointer data) {
  StyleProbe *probe = data;
  probe->calls++;
  probe->fields = fields;
  memcpy(probe->values, values, sizeof(probe->values));
}
static void smoke_style_finished(gpointer data) { ((StyleProbe *)data)->finishes++; }
static void smoke_dialog_destroyed(GtkWidget *widget, gpointer data) {
  (void)widget;
  *(gboolean *)data = TRUE;
}
typedef struct { gboolean painted, timed_out; } StyleFrameProbe;
static void smoke_style_painted(GdkFrameClock *clock, gpointer data) {
  (void)clock;
  ((StyleFrameProbe *)data)->painted = TRUE;
}
static gboolean smoke_style_timeout(gpointer data) {
  ((StyleFrameProbe *)data)->timed_out = TRUE;
  return G_SOURCE_REMOVE;
}
static gboolean smoke_style_settled(GtkWidget *window) {
  GdkFrameClock *clock = gtk_widget_get_frame_clock(window);
  if (!clock) return FALSE;
  StyleFrameProbe probe = {0};
  gulong handler = g_signal_connect(clock, "after-paint", G_CALLBACK(smoke_style_painted), &probe);
  guint timeout = g_timeout_add(2000, smoke_style_timeout, &probe);
  gtk_widget_queue_draw(window);
  gdk_frame_clock_request_phase(clock, GDK_FRAME_CLOCK_PHASE_AFTER_PAINT);
  while (!probe.painted && !probe.timed_out) g_main_context_iteration(NULL, TRUE);
  g_signal_handler_disconnect(clock, handler);
  if (!probe.timed_out) g_source_remove(timeout);
  if (!probe.painted) g_printerr("Style controls: initial GTK layout/paint did not complete.\n");
  return probe.painted;
}
static gboolean smoke_property_spacing(MCStyleControls *controls, const double *values) {
  const int tools[] = {MC_STYLE_TOOL_RECTANGLE, MC_STYLE_TOOL_ARROW, MC_STYLE_TOOL_TEXT,
                       MC_STYLE_TOOL_COVER, MC_STYLE_TOOL_COVER};
  const int shapes[] = {0, 0, 0, 0, 2};
  gboolean ok = TRUE;
  for (unsigned test = 0; test < G_N_ELEMENTS(tools); test++) {
    double current[MC_STYLE_PROPERTY_COUNT];
    memcpy(current, values, sizeof(current));
    current[MC_STYLE_SHAPE] = shapes[test];
    mc_style_controls_set_tool(controls, tools[test]);
    mc_style_controls_sync(controls, editor_style_visible_mask(tools[test], shapes[test]), current);
    GtkRequisition natural;
    gtk_widget_get_preferred_size(controls->row, NULL, &natural);
    GtkAllocation allocation = {0, 0, natural.width, natural.height};
    gtk_widget_size_allocate(controls->row, &allocation);
    if (gtk_widget_get_visible(controls->color->group)) {
      GtkWidget *button = controls->color->button;
      int width = gtk_widget_get_allocated_width(button), height = gtk_widget_get_allocated_height(button);
      gboolean sized = width == editor_style_swatch_size() && height == editor_style_swatch_size();
      if (!sized) g_printerr("Style geometry tool=%d shape=%d: swatch=%dx%d expected=%d.\n",
        tools[test], shapes[test], width, height, editor_style_swatch_size());
      ok = sized && ok;
      GdkEventButton event = {0};
      event.x = event.y = editor_style_swatch_size() / 2.0;
      gboolean center = !swatch_press(button, &event, NULL);
      event.x = event.y = .5;
      gboolean corner = swatch_press(button, &event, NULL);
      if (!center || !corner) g_printerr("Style geometry tool=%d shape=%d: circle hit center=%d cornerRejected=%d.\n",
        tools[test], shapes[test], center, corner);
      ok = center && corner && ok;
    }
    GList *groups = gtk_container_get_children(GTK_CONTAINER(controls->row));
    int right = 0, count = 0;
    for (GList *item = groups; item; item = item->next) {
      GtkWidget *group = item->data;
      if (!gtk_widget_get_visible(group)) continue;
      GtkAllocation frame;
      gtk_widget_get_allocation(group, &frame);
      int expected_gap = count ? editor_style_group_gap() : 0;
      gboolean spaced = frame.x - right == expected_gap;
      if (!spaced) g_printerr("Style geometry tool=%d shape=%d group=%d: frame=(%d,%d %dx%d), previousRight=%d gap=%d expected=%d row=%dx%d.\n",
        tools[test], shapes[test], count, frame.x, frame.y, frame.width, frame.height,
        right, frame.x - right, expected_gap, natural.width, natural.height);
      ok = spaced && ok;
      if (GTK_IS_BOX(group)) {
        GList *children = gtk_container_get_children(GTK_CONTAINER(group));
        int label_x = -1, label_y = -1;
        gboolean translated = children && gtk_widget_translate_coordinates(children->data, group, 0, 0,
          &label_x, &label_y);
        if (!translated || label_x != 0) g_printerr("Style geometry tool=%d shape=%d group=%d: label translated=%d origin=(%d,%d) expectedX=0.\n",
          tools[test], shapes[test], count, translated, label_x, label_y);
        ok = translated && label_x == 0 && ok;
        g_list_free(children);
      }
      right = frame.x + frame.width;
      count++;
    }
    if (!count || right != natural.width) g_printerr("Style geometry tool=%d shape=%d: groups=%d lastRight=%d naturalWidth=%d.\n",
      tools[test], shapes[test], count, right, natural.width);
    ok = count > 0 && right == natural.width && ok;
    g_list_free(groups);
  }
  return ok;
}
gboolean mc_style_controls_smoke(void) {
  MCStyleRange ranges[MC_STYLE_PROPERTY_COUNT] = {{0, 16777215, 1, 0xF26769, 1}, {0, 1, .01, 1, 100},
                           {1, 96, 1, 4, 1}, {8, 128, 1, 32, 1}, {0, 2, 1, 0, 1}, {4, 48, 1, 12, 1}};
  StyleProbe a = {0}, b = {0};
  GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL), *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_container_add(GTK_CONTAINER(window), box);
  MCStyleControls *first = mc_style_controls_new(GTK_WINDOW(window), ranges, smoke_style_changed,
                                                 smoke_style_finished, &a);
  MCStyleControls *second = mc_style_controls_new(GTK_WINDOW(window), ranges, smoke_style_changed,
                                                  smoke_style_finished, &b);
  gtk_box_pack_start(GTK_BOX(box), first->row, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(box), second->row, FALSE, FALSE, 0);
  // Match the production HUD: install its subtree provider before mapping.
  // Styling an already mapped window and measuring in the same call stack
  // observes the previous theme's cached requisition until GTK lays out again.
  gtk_style_context_add_class(gtk_widget_get_style_context(window), "mc-capture-hud");
  mc_style_hud_apply(window);
  double initial[] = {0xF26769, 1, 4, 32, 0, 12};
  mc_style_controls_sync(first, 15, initial);
  mc_style_controls_sync(second, 15, initial);
  gtk_button_clicked(GTK_BUTTON(first->numbers[MC_STYLE_FONT]->buttons[0]));
  gboolean ok = a.calls == 1 && a.values[MC_STYLE_FONT] == 33 && b.calls == 0 &&
                second->numbers[MC_STYLE_FONT]->value == 32;
  gtk_entry_set_text(GTK_ENTRY(second->numbers[MC_STYLE_STROKE]->entry), "12");
  ok = b.calls == 1 && b.values[MC_STYLE_STROKE] == 12 && a.calls == 1 && ok;
  const char *invalid[] = {"", "oops", "nan", "inf", "999", "-1"};
  for (unsigned i = 0; i < G_N_ELEMENTS(invalid); i++)
    gtk_entry_set_text(GTK_ENTRY(second->numbers[MC_STYLE_STROKE]->entry), invalid[i]);
  ok = b.calls == 1 && second->numbers[MC_STYLE_STROKE]->value == 12 &&
       !mc_numeric_control_set(second->numbers[MC_STYLE_STROKE], NAN) &&
       !mc_numeric_control_set(second->numbers[MC_STYLE_STROKE], 97) && ok;
  number_focus_out(NULL, NULL, second->numbers[MC_STYLE_STROKE]);
  ok = !strcmp(gtk_entry_get_text(GTK_ENTRY(second->numbers[MC_STYLE_STROKE]->entry)), "12") && ok;
  mc_style_controls_set_blocked(first, TRUE);
  gtk_button_clicked(GTK_BUTTON(first->numbers[MC_STYLE_FONT]->buttons[0]));
  ok = a.calls == 1 && first->numbers[MC_STYLE_FONT]->value == 33 && ok;
  mc_style_controls_set_blocked(first, FALSE);
  gtk_entry_set_text(GTK_ENTRY(first->numbers[MC_STYLE_OPACITY]->entry), "35");
  ok = a.calls == 2 && fabs(a.values[MC_STYLE_OPACITY] - .35) < .00001 && b.calls == 1 && ok;
  GdkRGBA rgba = {.1, .2, .3, .45};
  choose_color(NULL, first->color);
  gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(first->color->dialog), &rgba);
  gtk_dialog_response(GTK_DIALOG(first->color->dialog), GTK_RESPONSE_OK);
  ok = first->color->dialog == NULL && a.calls == 3 && b.calls == 1 &&
       fabs(a.values[MC_STYLE_OPACITY] - .45) < .001 &&
       fabs(first->numbers[MC_STYLE_OPACITY]->value - 45) < .01 && ok;
  choose_color(NULL, second->color);
  gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(second->color->dialog), &rgba);
  gtk_dialog_response(GTK_DIALOG(second->color->dialog), GTK_RESPONSE_CANCEL);
  ok = b.calls == 1 && second->values[MC_STYLE_COLOR] == initial[MC_STYLE_COLOR] && ok;
  GdkRGBA invalid_rgba = {0, 0, 0, NAN};
  ok = !mc_color_control_set(first->color, &invalid_rgba) && a.calls == 3 && ok;
  mc_style_controls_sync(first, (1u << MC_STYLE_COLOR) | (1u << MC_STYLE_OPACITY), initial);
  ok = a.calls == 3 && mc_style_controls_property_visible(first, MC_STYLE_COLOR) &&
       !mc_style_controls_property_visible(first, MC_STYLE_FONT) && ok;
  mc_style_controls_set_tool(first, MC_STYLE_TOOL_COVER);
  mc_style_controls_sync(first, editor_style_visible_mask(MC_STYLE_TOOL_COVER, 0), initial);
  gtk_button_clicked(GTK_BUTTON(first->shape_buttons[2]));
  ok = a.calls == 4 && a.values[MC_STYLE_SHAPE] == 2 && ok;
  mc_style_controls_sync(first, editor_style_visible_mask(MC_STYLE_TOOL_COVER, 2), a.values);
  ok = mc_style_controls_property_visible(first, MC_STYLE_SHAPE) &&
    mc_style_controls_property_visible(first, MC_STYLE_BLOCK) &&
    !mc_style_controls_property_visible(first, MC_STYLE_COLOR) && ok;
  mc_style_controls_set_tool(first, MC_STYLE_TOOL_RECTANGLE);
  mc_style_controls_sync(first, editor_style_visible_mask(MC_STYLE_TOOL_RECTANGLE, 0), initial);
  gtk_button_clicked(GTK_BUTTON(first->shape_buttons[2]));
  ok = a.calls == 4 && !gtk_widget_get_visible(first->shape_buttons[2]) && ok;
  // Allocate real GTK children: label packing must not add hidden leading space
  // and switching to mosaic must not retain gaps for detached color controls.
  if (!ok) g_printerr("Style controls: interaction assertions failed before geometry.\n");
  gtk_widget_show_all(window);
  ok = smoke_style_settled(window) && ok;
  ok = smoke_property_spacing(first, initial) && ok;
  mc_style_controls_set_tool(first, MC_STYLE_TOOL_RECTANGLE);
  mc_style_controls_sync(first, editor_style_visible_mask(MC_STYLE_TOOL_RECTANGLE, 0), initial);
  choose_color(NULL, first->color);
  gboolean closed = FALSE;
  g_signal_connect(first->color->dialog, "destroy", G_CALLBACK(smoke_dialog_destroyed), &closed);
  gtk_widget_destroy(window);
  if (!closed) g_printerr("Style controls: active color dialog survived owner destruction.\n");
  ok = closed && ok;
  g_print("Linux style controls smoke %s: isolated callbacks, invalid numbers, RGBA/cancel, dialog lifetime, property group geometry.\n",
           ok ? "passed" : "FAILED");
  return ok;
}
