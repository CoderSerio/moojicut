#include "hud.h"

/* GTK owns the window's chrome. Buttons and interaction come from the shared frame. */
void mc_linux_hud_apply(GtkWidget *toolbar, int32_t light_rgb, int32_t dark_rgb) {
  g_return_if_fail(light_rgb >= 0 && light_rgb <= 0xffffff && dark_rgb >= 0 && dark_rgb <= 0xffffff);
  gchar *css = g_strdup_printf(
      ".mc-hud { background-color: #%06x; border: 1px solid #cbcbcb;"
      " border-radius: 8px; padding: 4px; }"
      ".mc-hud.mc-dark { background-color: #%06x; border-color: #4b4b4b; }",
      (unsigned int)light_rgb, (unsigned int)dark_rgb);
  GtkCssProvider *provider = gtk_css_provider_new();
  gtk_css_provider_load_from_data(provider, css, -1, NULL);
  g_free(css);
  gtk_style_context_add_provider(gtk_widget_get_style_context(toolbar), GTK_STYLE_PROVIDER(provider),
                                 GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
  g_object_unref(provider);
}

void mc_linux_hud_set_dark(GtkWidget *toolbar, gboolean dark) {
  GtkStyleContext *style = gtk_widget_get_style_context(toolbar);
  if (dark) gtk_style_context_add_class(style, "mc-dark");
  else gtk_style_context_remove_class(style, "mc-dark");
}
