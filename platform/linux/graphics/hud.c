#include "hud.h"

gboolean mc_linux_hud_draw_icon(GtkWidget *widget, cairo_t *cr, MCIcon icon) {
  MCIconPath path = mc_icon_path(icon);
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
static gboolean icon_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
  return mc_linux_hud_draw_icon(widget, cr, (MCIcon)GPOINTER_TO_INT(data));
}
GtkWidget *mc_linux_hud_icon_button(MCIcon icon, const char *label, GCallback callback, gpointer data) {
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
/* Scope the theme to the supplied HUD subtree. The caller supplies buttons,
 * labels and layout; this adapter owns only GTK drawing and theme primitives. */
static void hud_provider(GtkWidget *widget, gpointer data) {
  gtk_style_context_add_provider(gtk_widget_get_style_context(widget), GTK_STYLE_PROVIDER(data),
                                 GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
  if (GTK_IS_CONTAINER(widget))
    gtk_container_forall(GTK_CONTAINER(widget), hud_provider, data);
}
void mc_linux_hud_apply(GtkWidget *toolbar) {
  static const char css[] =
      ".mc-hud { background-color: #292730; background-image: none; color: #ece8e2;"
      " border: 1px solid #514b59; border-radius: 8px; padding: 4px; box-shadow: 0 4px 12px alpha(black, "
      "0.25); }"
      ".mc-hud button { background-image: none; background-color: transparent; color: #ece8e2;"
      " border: 1px solid transparent; border-radius: 7px; box-shadow: none; text-shadow: none;"
      " -gtk-icon-shadow: none; padding: 0; min-width: 26px; min-height: 26px; }"
      ".mc-hud button:hover { background-color: #403b48; }"
      ".mc-hud button:active, .mc-hud button.mc-selected { background-color: #56505f;"
      " border-color: #686170; color: #fff9ef; }"
      ".mc-hud button:focus { border-color: #b8b0bf; outline: none; }"
      ".mc-hud button:disabled, .mc-hud button:disabled * { color: #6f6978; }"
      ".mc-hud separator { background-color: #514b59; min-width: 1px; margin: 6px 5px; }";
  GtkCssProvider *provider = gtk_css_provider_new();
  GError *error = NULL;
  if (!gtk_css_provider_load_from_data(provider, css, -1, &error)) {
    g_warning("HUD styling: %s", error->message);
    g_clear_error(&error);
  }
  hud_provider(toolbar, provider);
  g_object_unref(provider);
}
GtkWidget *mc_linux_hud_separator(void) {
  GtkWidget *separator = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
  gtk_widget_set_valign(separator, GTK_ALIGN_CENTER);
  gtk_widget_set_size_request(separator, -1, 22);
  return separator;
}
