#ifndef MOOJICUT_CAPTURE_UI_H
#define MOOJICUT_CAPTURE_UI_H
#include <stdint.h>
#include "moonbit.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Main/UI thread. Ephemeral per-editor gestures; the image document remains
 * owned by image_apply. UTF-16 input stays caller-owned; release outputs.
 * Zero open handle means failure. close is idempotent; IDs are never reused. */
int32_t capture_ui_open(double width, double height);
moonbit_string_t capture_ui_event(moonbit_string_t request);
void capture_ui_close(int32_t handle);
/* Positive finite surface/region dimensions and renderer measurements only.
 * Top-left logical coordinates. Caller releases the four-double result. */
double *capture_ui_toolbar_frame(double sw, double sh, double x, double y,
                                double w, double h, double row, double properties);
#ifdef __cplusplus
}
#endif
#endif
