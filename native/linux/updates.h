#ifndef MOOJICUT_LINUX_UPDATES_H
#define MOOJICUT_LINUX_UPDATES_H
#include <gtk/gtk.h>
GtkWidget *mc_linux_update_preferences(void);
void mc_linux_updates_cancel_all(void);
gboolean mc_linux_update_smoke(void);
#endif
