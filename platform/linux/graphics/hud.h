#ifndef MOOJICUT_LINUX_HUD_H
#define MOOJICUT_LINUX_HUD_H
#include <gtk/gtk.h>
#include "components/icons/shared/mc_icons.h"
/* GTK drawing/theme primitives. Product labels, contribution order and layout
 * belong to the calling feature/shared MoonBit UI. Widgets are caller-owned. */
gboolean mc_linux_hud_draw_icon(GtkWidget *widget, cairo_t *cr, MCIcon icon);
GtkWidget *mc_linux_hud_icon_button(MCIcon icon, const char *label, GCallback callback, gpointer data);
GtkWidget *mc_linux_hud_separator(void);
void mc_linux_hud_apply(GtkWidget *toolbar);
#endif
