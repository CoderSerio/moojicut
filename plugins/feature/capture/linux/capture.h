#ifndef MOOJICUT_LINUX_CAPTURE_H
#define MOOJICUT_LINUX_CAPTURE_H
#include <gtk/gtk.h>
/* The host coordinates optional features. pin_result borrows image/bounds for
 * the callback; retaining an image requires its own GObject reference.
 * restore_visibility runs after editor teardown and before pin_result. Host
 * callbacks/data are borrowed and must survive this complete callback sequence. */
typedef struct {
  void (*pin_result)(GdkPixbuf *image, const GdkRectangle *bounds, gpointer data);
  void (*restore_visibility)(gpointer data);
  gpointer data;
  /* Optional live capability query. A disabled action must retain the draft. */
  gboolean (*can_pin)(gpointer data);
} MCLinuxCaptureHost;
void mc_linux_capture_start(GtkApplication *application, const MCLinuxCaptureHost *host);
gboolean mc_linux_capture_busy(void);
void mc_linux_capture_close(void);
void mc_linux_capture_refresh_capabilities(void);
gboolean mc_linux_capture_smoke(GtkApplication *application);
#endif
