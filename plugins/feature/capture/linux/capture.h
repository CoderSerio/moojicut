#ifndef MOOJICUT_LINUX_CAPTURE_H
#define MOOJICUT_LINUX_CAPTURE_H
#include <gtk/gtk.h>
#include <stdint.h>
/* pin_result borrows image/bounds and returns whether it created a pin.
 * The editor closes and calls restore_visibility after an accepted result.
 * Do not pump the event loop or close the capture inside pin_result. */
typedef struct {
  gboolean (*pin_result)(GdkPixbuf *image, const GdkRectangle *bounds, gpointer data);
  void (*restore_visibility)(gpointer data);
  gpointer data;
  /* Optional live capability query. A disabled action must retain the draft. */
  gboolean (*can_pin)(gpointer data);
  /* Optional v2 service. Borrowed NUL-terminated UTF-8 strings are valid only
   * during the callback; copy before asynchronous use. The image session stays
   * capture-owned. Do not pump/close capture here. TRUE accepts queued dispatch,
   * not worker completion; capture immediately acknowledges the toolbar effect. */
  gboolean (*on_user_tool)(gpointer data, int32_t image_session,
                          const char *stable_id, const char *payload);
} MCLinuxCaptureHost;
void mc_linux_capture_start(GtkApplication *application, const MCLinuxCaptureHost *host);
gboolean mc_linux_capture_busy(void);
void mc_linux_capture_close(void);
void mc_linux_capture_refresh_capabilities(void);
/* Host owns the snapshot. Preflight never commits a draft or changes history;
 * publish is called only after durable settings save, before closing the old
 * snapshot. The shared toolbar session takes its own descriptor snapshot. */
gboolean mc_linux_capture_preflight_tools(int snapshot, const char **reason);
void mc_linux_capture_discard_tools(void);
void mc_linux_capture_publish_tools(int snapshot);
/* Refresh only a still-current capture after the shared plugin root accepted
 * its result. Returns FALSE for a retired capture; never parses/applies output. */
gboolean mc_linux_capture_plugin_result(int32_t session, gboolean document_changed);
gboolean mc_linux_capture_smoke(GtkApplication *application);
#endif
