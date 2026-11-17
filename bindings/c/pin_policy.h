#ifndef MOOJICUT_PIN_POLICY_H
#define MOOJICUT_PIN_POLICY_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum { MC_PIN_MACOS = 1, MC_PIN_WINDOWS = 2, MC_PIN_LINUX = 3 };
enum { MC_PIN_VISIBILITY_NONE = 0, MC_PIN_SHOW_SELECTED = 1, MC_PIN_HIDE_SELECTED = 2,
       MC_PIN_SHOW_HIDDEN = 3, MC_PIN_HIDE_ALL = 4, MC_PIN_RECOVERY_UNAVAILABLE = 5,
       MC_PIN_RESTORE_HIDDEN = 6 };
/* Dimensions share host units (AppKit points / native pixels). No OS resources
 * cross this ABI. Zero sizing result means invalid: retain current geometry. */
double pin_scale(int32_t platform, double requested, double width, double height,
                 double work_width, double work_height);
/* macOS-only unanchored initial fit: 75% work area, no upscaling. */
double pin_initial_scale(double width, double height, double work_width, double work_height);
double pin_zoom_step(double value, int32_t direction);
/* Fractional wheel notches; no host-side rounding of precise wheel input. */
double pin_scroll_scale(double value, double steps);
/* Top-left local coordinates; edge bitmask left=1/right=2/top=4/bottom=8. */
int32_t pin_hit_handle(double width, double height, double x, double y, double margin);
/* Original gesture frame + screen pointer delta, in top-left host units.
 * Returns owned [x,y,width,height,scale]; release with moonbit_decref.
 * Zero scale rejects input. Opposite edges anchor; aspect ratio is preserved. */
double *pin_resize_frame(int32_t platform, double x, double y, double source_width, double source_height,
                         double start_scale, int32_t handle, double dx, double dy,
                         double work_x, double work_y, double work_width, double work_height);
/* direction is negative/down, zero/clamp, positive/up. Windows uses byte alpha;
 * macOS/Linux use unit alpha. Invalid nonfinite input restores full opacity. */
double pin_opacity(int32_t platform, double value, int32_t direction);
int32_t pin_visibility_action(int32_t platform, int32_t has_selected, int32_t selected_hidden,
                              int32_t selected_passthrough, int32_t any_hidden, int32_t recovery_available);
int32_t pin_hidden_after(int32_t platform, int32_t action, int32_t hidden, int32_t passthrough, int32_t target);
#ifdef __cplusplus
}
#endif
#endif
