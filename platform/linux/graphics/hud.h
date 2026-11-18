#ifndef MOOJICUT_LINUX_HUD_H
#define MOOJICUT_LINUX_HUD_H
#include <gtk/gtk.h>
#include <stdint.h>

/* Surface colors are supplied by the shared UI; this adapter owns GTK chrome. */
void mc_linux_hud_apply(GtkWidget *toolbar, int32_t light_rgb, int32_t dark_rgb);
void mc_linux_hud_set_dark(GtkWidget *toolbar, gboolean dark);
#endif
