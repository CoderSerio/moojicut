#ifndef MOOJICUT_SHARED_SELECTION_H
#define MOOJICUT_SHARED_SELECTION_H

#include <stdint.h>
#include "moonbit.h"

/* Geometry follows the macOS editor: half-open handle hits and anchored resize.
 * Geometry values only: no native window, gesture or document state crosses
 * this boundary. Initialize the MoonBit runtime once before calling the core. */
typedef struct { double x, y; } MCCorePoint;
typedef struct { double x, y, width, height; } MCCoreRect;

enum { MC_SELECTION_MIDPOINT_EXACT = 0, MC_SELECTION_MIDPOINT_INTEGER = 1 };

#ifdef __cplusplus
extern "C" {
#endif

/* FixedArray[Double] has the documented double* C ABI. Each result is owned
 * by its caller: two coordinates for a point, four for an x/y/width/height rect.
 * The value helpers below copy the result and release its MoonBit reference. */
double *selection_region(double ax, double ay, double bx, double by);
double *selection_handle_point(double x, double y, double width, double height,
                               int32_t handle, int32_t midpoint_mode);
int32_t selection_hit_handle(double x, double y, double width, double height,
                             double px, double py, double radius,
                             int32_t midpoint_mode);
int32_t selection_contains(double x, double y, double width, double height,
                           double px, double py);
int32_t selection_border_contains(double x, double y, double width, double height,
                                  double px, double py, double radius);
double *selection_transform(double x, double y, double width, double height,
                            double ax, double ay, double px, double py, int32_t handle,
                            double bounds_x, double bounds_y, double bounds_width,
                            double bounds_height, double minimum, int32_t directed);

#ifdef __cplusplus
}
#endif

static inline MCCoreRect mc_core_take_rect(double *values) {
  MCCoreRect rect = {values[0], values[1], values[2], values[3]};
  moonbit_decref(values);
  return rect;
}
static inline MCCoreRect mc_core_region(MCCorePoint anchor, MCCorePoint current) {
  return mc_core_take_rect(selection_region(anchor.x, anchor.y, current.x, current.y));
}
static inline MCCorePoint mc_core_handle_point(MCCoreRect rect, int32_t handle, int32_t midpoint_mode) {
  double *values = selection_handle_point(rect.x, rect.y, rect.width, rect.height, handle, midpoint_mode);
  MCCorePoint point = {values[0], values[1]};
  moonbit_decref(values);
  return point;
}
static inline int32_t mc_core_hit_handle(MCCoreRect rect, MCCorePoint point, double radius,
                                        int32_t midpoint_mode) {
  return selection_hit_handle(rect.x, rect.y, rect.width, rect.height, point.x, point.y,
                              radius, midpoint_mode);
}
static inline int32_t mc_core_contains(MCCoreRect rect, MCCorePoint point) {
  return selection_contains(rect.x, rect.y, rect.width, rect.height, point.x, point.y);
}
static inline int32_t mc_core_border_contains(MCCoreRect rect, MCCorePoint point, double radius) {
  return selection_border_contains(rect.x, rect.y, rect.width, rect.height, point.x, point.y, radius);
}
static inline MCCoreRect mc_core_transform(MCCoreRect rect, MCCorePoint anchor, MCCorePoint current,
                                          int32_t handle, MCCoreRect bounds, double minimum) {
  return mc_core_take_rect(selection_transform(rect.x, rect.y, rect.width, rect.height,
    anchor.x, anchor.y, current.x, current.y, handle, bounds.x, bounds.y,
    bounds.width, bounds.height, minimum, 0));
}
/* Directed arrows carry endpoint deltas instead of ordinary rectangle sizes.
 * Keep that representation explicit so it cannot change the macOS baseline. */
static inline MCCoreRect mc_core_transform_directed(MCCoreRect rect, MCCorePoint anchor, MCCorePoint current,
                                                   int32_t handle, MCCoreRect bounds, double minimum) {
  return mc_core_take_rect(selection_transform(rect.x, rect.y, rect.width, rect.height,
    anchor.x, anchor.y, current.x, current.y, handle, bounds.x, bounds.y,
    bounds.width, bounds.height, minimum, 1));
}

#endif
