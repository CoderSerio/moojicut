#ifndef MOOJICUT_LINUX_RECORDING_H
#define MOOJICUT_LINUX_RECORDING_H
#include <gtk/gtk.h>
/* All entry points/callbacks are on the GTK/core thread. Application is held
 * through source cancellation, pipeline EOS/NULL and pending portal callbacks. */
typedef void (*MCLinuxRecordingChanged)(gboolean busy, gboolean can_stop, const char *status, gpointer data);
typedef void (*MCLinuxRecordingCompleted)(const char *source, const char *draft_directory, gpointer data);
void mc_linux_recording_init(GtkApplication *application, MCLinuxRecordingChanged changed, gpointer data);
/* App owns the transition to editing. Callback paths are borrowed for this call.
 * Successful production recordings notify even during shutdown, after EOS/NULL;
 * the app persists recents but must suppress opening windows while quitting.
 * Cancelled/failed recordings and isolated smoke flows never publish media. */
void mc_linux_recording_set_completed(MCLinuxRecordingCompleted completed, gpointer data);
void mc_linux_recording_start(void);
void mc_linux_recording_stop(void);
void mc_linux_recording_shutdown(void);
gboolean mc_linux_recording_busy(void);
gboolean mc_linux_recording_smoke(GtkApplication *application, const char *directory);
#endif
