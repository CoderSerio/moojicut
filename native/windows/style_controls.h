#ifndef MOOJICUT_WINDOWS_STYLE_CONTROLS_H
#define MOOJICUT_WINDOWS_STYLE_CONTROLS_H

#include <windows.h>
#include "../shared/editor_style.h"

typedef struct MCStyleControls MCStyleControls;
typedef struct {
  double value, minimum, maximum, step;
} MCStyleProperty;
typedef struct {
  unsigned mask;
  BOOL enabled;
  MCStyleProperty property[4];
} MCStyleControlsModel;
/* Return FALSE to reject a change (e.g. while an IME draft is composing).
 * The host may synchronously supply an updated model from this callback. */
typedef BOOL (*MCStyleChange)(void *context, int property, double value);
enum {
  MC_STYLE_CONTROL_COLOR, MC_STYLE_CONTROL_OPACITY, MC_STYLE_CONTROL_STROKE,
  MC_STYLE_CONTROL_FONT, MC_STYLE_CONTROL_INCREASE, MC_STYLE_CONTROL_DECREASE,
  MC_STYLE_CONTROL_COUNT
};

/* Reserve six consecutive child IDs. Parent forwards WM_COMMAND/WM_DRAWITEM.
 * Controls own their tooltip, native menus and painting, but no document state. */
MCStyleControls *mc_style_controls_create(HWND parent, HINSTANCE instance, int first_id,
                                          MCStyleChange change, void *context);
/* Safe during a change callback or an active native popup. Retires HWNDs
 * immediately; pending menu dispatch is ignored and temporary refs drain. */
void mc_style_controls_destroy(MCStyleControls *controls);
void mc_style_controls_update(MCStyleControls *controls, const MCStyleControlsModel *model);
void mc_style_controls_layout(MCStyleControls *controls, int x, int y);
BOOL mc_style_controls_command(MCStyleControls *controls, WPARAM wp, LPARAM lp);
BOOL mc_style_controls_draw(MCStyleControls *controls, const DRAWITEMSTRUCT *item);
/* Same validated user-change path as popup selection; useful to other native
 * inputs/accessibility clients. Never mutates the supplied host model itself. */
BOOL mc_style_controls_choose(MCStyleControls *controls, int property, double value);
HWND mc_style_controls_window(const MCStyleControls *controls, int control);
BOOL mc_style_controls_smoke(HINSTANCE instance);

#endif
