#ifndef MOOJICUT_SHARED_VIDEO_UI_H
#define MOOJICUT_SHARED_VIDEO_UI_H
#include <stdint.h>
#include "moonbit.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Prototype batch boundary. Initialize the MoonBit runtime once on the UI
 * thread. Strings are caller-owned UTF-16 inputs; release returned strings.
 * The component owns layout, drawing descriptions and interaction state.
 * A host forwards events and executes effects; it does not interpret hits. */
int32_t video_ui_open(moonbit_string_t snapshot);
moonbit_string_t video_ui_event(int32_t handle, moonbit_string_t event);
moonbit_string_t video_ui_frame(int32_t handle, double width, double height);
void video_ui_close(int32_t handle);
#ifdef __cplusplus
}
#endif
#endif
