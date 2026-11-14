#ifndef MOOJICUT_LINUX_CAPTURE_H
#define MOOJICUT_LINUX_CAPTURE_H
#include <gtk/gtk.h>
void mc_linux_capture_start(GtkApplication *application);
gboolean mc_linux_capture_busy(void);
void mc_linux_capture_close(void);
gboolean mc_linux_capture_smoke(GtkApplication *application);
#endif
