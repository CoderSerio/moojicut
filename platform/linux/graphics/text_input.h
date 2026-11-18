#ifndef MOOJICUT_LINUX_TEXT_INPUT_H
#define MOOJICUT_LINUX_TEXT_INPUT_H
#include <gtk/gtk.h>
#include "platform/shared/graphics/canvas.h"

typedef struct MCLinuxTextInputs MCLinuxTextInputs;
enum { MC_LINUX_TEXT_ACCEPT = 1, MC_LINUX_TEXT_CANCEL = 2, MC_LINUX_TEXT_BLUR = 3 };
/* UI-thread input-system adapter. The event is borrowed; the owner must apply
 * the root event and synchronously return its ACK frame. Callbacks may retire
 * fields or destroy the group. This adapter never validates domain values or
 * publishes documents. GtkTextView owns each field's real ATK text interface. */
typedef struct {
  gboolean (*event)(gpointer context, moonbit_string_t event);
  void (*action)(gpointer context, GtkWidget *field, int action);
  /* Optional unconsumed single-line navigation key; shared UI decides whether
   * it means numeric stepping. Return FALSE to preserve GTK's default action. */
  gboolean (*key)(gpointer context, const MCCanvasInput *input);
  /* Optional single-line wheel input, in the group's logical coordinates.
   * Positive deltas mean up/left; smooth GDK deltas remain fractional steps. */
  gboolean (*scroll)(gpointer context, const MCCanvasInput *input);
} MCLinuxTextCallbacks;
MCLinuxTextInputs *mc_linux_text_inputs_new(const MCLinuxTextCallbacks *callbacks, gpointer context);
GtkWidget *mc_linux_text_inputs_widget(MCLinuxTextInputs *inputs);
void mc_linux_text_inputs_destroy(MCLinuxTextInputs *inputs);
/* Borrows frame; copies fields. Coordinates are local logical GTK units.
 * Zero retires all fields. Same token/version never resets native IME or caret. */
gboolean mc_linux_text_inputs_set_frame(MCLinuxTextInputs *inputs, int32_t frame);
GtkWidget *mc_linux_text_inputs_field(MCLinuxTextInputs *inputs, const char *id);
gboolean mc_linux_text_inputs_contains(MCLinuxTextInputs *inputs, GtkWidget *widget);
GtkWidget *mc_linux_text_inputs_active(MCLinuxTextInputs *inputs);
gboolean mc_linux_text_inputs_composing(MCLinuxTextInputs *inputs);
gboolean mc_linux_text_inputs_history(MCLinuxTextInputs *inputs, GtkWidget *field, gboolean redo);
/* Flushes completed native buffer actions. Never ends composition. */
gboolean mc_linux_text_inputs_flush(MCLinuxTextInputs *inputs);
#endif
