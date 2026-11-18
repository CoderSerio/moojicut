#ifndef MOOJICUT_LINUX_SHARED_CANVAS_H
#define MOOJICUT_LINUX_SHARED_CANVAS_H

#include <gtk/gtk.h>
#include "platform/shared/graphics/canvas.h"

/* UI-thread adapter only. Geometry, colors, hit testing, capture decisions and
 * semantic IDs belong to the shared UI. Event/resize callbacks may replace the
 * frame or destroy the widget; context must live through destroyed. */
typedef struct {
  void (*event)(void *context, GtkWidget *canvas, const MCCanvasInput *input);
  void (*resize)(void *context, GtkWidget *canvas, double width, double height);
  void (*destroyed)(void *context, GtkWidget *canvas);
  /* Optional media primitive, clipped to the shared logical rectangle, between
   * base and overlay layers. Must not pump events, replace frames or destroy. */
  void (*video)(void *context, GtkWidget *canvas, cairo_t *target,
                const MCCanvasRect *bounds);
} MCLinuxCanvasCallbacks;

GtkWidget *mc_linux_canvas_new(const MCLinuxCanvasCallbacks *callbacks, void *context);
/* Success transfers the immutable frame. Failure leaves it caller-owned.
 * Zero clears. Re-supplying the already-owned handle is a harmless no-op. */
gboolean mc_linux_canvas_set_frame(GtkWidget *canvas, int32_t frame);
void mc_linux_canvas_set_capture(GtkWidget *canvas, gboolean capture);
void mc_linux_canvas_preserve_focus_on_press(GtkWidget *canvas,
    gboolean (*preserve)(void *context));
void mc_linux_canvas_cancel(GtkWidget *canvas);
/* Logical coordinates; the caller's Cairo transform supplies device scale.
 * Saves/restores context, clips to width/height, and paints the same layers as
 * the on-screen widget. No media resource lifetime is owned here. */
gboolean mc_linux_canvas_paint(GtkWidget *canvas, cairo_t *target,
                              double width, double height);
#endif
