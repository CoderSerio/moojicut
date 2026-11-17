#ifndef MOOJICUT_LINUX_STYLE_CONTROLS_H
#define MOOJICUT_LINUX_STYLE_CONTROLS_H

#include <gtk/gtk.h>
#include "components/icons/shared/mc_icons.h"
#include "bindings/c/editor_style.h"

/* GTK controls own their widgets; the containing widget owns each opaque
 * instance. Values/ranges are supplied by the caller, never read from an editor.
 * Programmatic set/sync operations are silent. User changes invoke on_change. */
typedef struct MCNumericControl MCNumericControl;
typedef struct MCColorControl MCColorControl;
typedef struct MCStyleControls MCStyleControls;
typedef void (*MCNumericChanged)(double value, gpointer data);
typedef void (*MCColorChanged)(const GdkRGBA *value, gpointer data);
typedef void (*MCControlFinished)(gpointer data);
typedef void (*MCStyleChanged)(unsigned fields, const double values[MC_STYLE_PROPERTY_COUNT], gpointer data);
typedef struct {
  double minimum, maximum, step, value;
  double display_scale;
} MCStyleRange;

MCNumericControl *mc_numeric_control_new(const char *label, double value, double minimum,
                                         double maximum, double step, MCNumericChanged on_change,
                                         MCControlFinished on_finish, gpointer data);
GtkWidget *mc_numeric_control_widget(MCNumericControl *control);
GtkWidget *mc_numeric_control_entry(MCNumericControl *control);
GtkWidget *mc_numeric_control_step_button(MCNumericControl *control, gboolean increase);
gboolean mc_numeric_control_set(MCNumericControl *control, double value);
void mc_numeric_control_set_blocked(MCNumericControl *control, gboolean blocked);

MCColorControl *mc_color_control_new(GtkWindow *parent, const GdkRGBA *value,
                                     MCColorChanged on_change, MCControlFinished on_finish,
                                     gpointer data);
GtkWidget *mc_color_control_widget(MCColorControl *control);
gboolean mc_color_control_set(MCColorControl *control, const GdkRGBA *value);
void mc_color_control_set_blocked(MCColorControl *control, gboolean blocked);
void mc_color_control_close_dialog(MCColorControl *control);

MCStyleControls *mc_style_controls_new(GtkWindow *parent, const MCStyleRange ranges[MC_STYLE_PROPERTY_COUNT],
                                      MCStyleChanged on_change, MCControlFinished on_finish,
                                      gpointer data);
GtkWidget *mc_style_controls_widget(MCStyleControls *controls);
void mc_style_controls_set_tool(MCStyleControls *controls, int tool);
void mc_style_controls_sync(MCStyleControls *controls, unsigned mask, const double values[MC_STYLE_PROPERTY_COUNT]);
void mc_style_controls_set_blocked(MCStyleControls *controls, gboolean blocked);
void mc_style_controls_close_dialog(MCStyleControls *controls);
GtkWidget *mc_style_controls_entry(MCStyleControls *controls, int field);
GtkWidget *mc_style_controls_step_button(MCStyleControls *controls, int field, gboolean increase);
gboolean mc_style_controls_property_visible(MCStyleControls *controls, int field);

/* Shared HUD primitives stay windowless below the native buttons. */
GtkWidget *mc_style_icon_button(MCIcon icon, const char *label, GCallback callback, gpointer data);
GtkWidget *mc_style_separator(void);
void mc_style_hud_apply(GtkWidget *toolbar);
gboolean mc_style_controls_smoke(void);

#endif
