#ifndef MOOJICUT_LINUX_RECORDING_H
#define MOOJICUT_LINUX_RECORDING_H
#include <gtk/gtk.h>
/* All entry points/callbacks are on the GTK/core thread. Application is held
 * through source cancellation, pipeline EOS/NULL and pending portal callbacks. */
typedef void (*MCLinuxRecordingChanged)(gboolean busy, gboolean can_stop, const char *status, gpointer data);
void mc_linux_recording_init(GtkApplication *application, MCLinuxRecordingChanged changed, gpointer data);
void mc_linux_recording_start(void);
void mc_linux_recording_stop(void);
void mc_linux_recording_shutdown(void);
gboolean mc_linux_recording_busy(void);
gboolean mc_linux_recording_smoke(GtkApplication *application, const char *directory);
#endif
