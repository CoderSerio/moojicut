#include "hud.h"

/* GTK owns the window's chrome. Buttons and interaction come from the shared frame. */
void mc_linux_hud_apply(GtkWidget *toolbar) {
  static const char css[] =
      ".mc-hud { background-color: #f5f5f5; border: 1px solid #cbcbcb;"
      " border-radius: 8px; padding: 4px; }"
      ".mc-hud.mc-dark { background-color: #262626; border-color: #4b4b4b; }";
  GtkCssProvider *provider = gtk_css_provider_new();
  gtk_css_provider_load_from_data(provider, css, -1, NULL);
  gtk_style_context_add_provider(gtk_widget_get_style_context(toolbar), GTK_STYLE_PROVIDER(provider),
                                 GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
  g_object_unref(provider);
}

void mc_linux_hud_set_dark(GtkWidget *toolbar, gboolean dark) {
  GtkStyleContext *style = gtk_widget_get_style_context(toolbar);
  if (dark) gtk_style_context_add_class(style, "mc-dark");
  else gtk_style_context_remove_class(style, "mc-dark");
}
