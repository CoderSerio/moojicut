#ifndef MOOJICUT_LINUX_PINNING_H
#define MOOJICUT_LINUX_PINNING_H
#include <gtk/gtk.h>
void mc_linux_pins_init(GtkApplication *application, const char *settings_path);
void mc_linux_pins_set_enabled(gboolean enabled);
gboolean mc_linux_pins_enabled(void);
void mc_linux_pin_image(GdkPixbuf *image);
void mc_linux_pin_image_at(GdkPixbuf *image, const GdkRectangle *bounds);
void mc_linux_pins_restore(void);
void mc_linux_pins_hide(gboolean hidden);
void mc_linux_pins_close(void);
void mc_linux_pins_close_interactive(void);
void mc_linux_pins_restore_input(void);
GtkWidget *mc_linux_pin_preferences(void);
gboolean mc_linux_pin_smoke(void);
#endif
