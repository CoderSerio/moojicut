#ifndef MOOJICUT_RECORDING_FLOW_H
#define MOOJICUT_RECORDING_FLOW_H
#include <stdint.h>
#include "moonbit.h"
#ifdef __cplusplus
extern "C" {
#endif
enum {
  MC_RECORDING_IDLE = 0, MC_RECORDING_SELECTING = 1, MC_RECORDING_COUNTDOWN = 2,
  MC_RECORDING_STARTING = 3, MC_RECORDING_ACTIVE = 4, MC_RECORDING_STOPPING = 5,
  MC_RECORDING_READY = 6, MC_RECORDING_ERROR = 7, MC_RECORDING_CANCELLED = 8
};
enum {
  MC_RECORDING_BEGIN = 1, MC_RECORDING_SELECTED = 2, MC_RECORDING_TICK = 3,
  MC_RECORDING_STARTED = 4, MC_RECORDING_STOP = 5, MC_RECORDING_COMPLETE = 6,
  MC_RECORDING_FAIL = 7, MC_RECORDING_CANCEL = 8
};
enum {
  MC_RECORDING_REJECTED = -1, MC_RECORDING_NO_EFFECT = 0,
  MC_RECORDING_REQUEST_SOURCE = 1, MC_RECORDING_START_MEDIA = 2,
  MC_RECORDING_STOP_MEDIA = 3, MC_RECORDING_RELEASE_SOURCE = 4,
  MC_RECORDING_DELIVER_MEDIA = 5
};
enum {
  MC_RECORDING_PHASE = 0, MC_RECORDING_REMAINING = 1, MC_RECORDING_ELAPSED_MS = 2,
  MC_RECORDING_BUSY = 3, MC_RECORDING_CAN_CANCEL = 4, MC_RECORDING_CAN_STOP = 5
};
/* Main/core thread only. No callbacks into MoonBit from media threads.
 * Positive handles are never reused. Carry the handle with asynchronous work;
 * check it against the current session before changing any native resources.
 * Time is monotonic milliseconds in one clock domain, not wall clock.
 * SELECTED starts a 3-second deadline. TICK emits START_MEDIA exactly once.
 * A user stop during STARTING must drain that pending start, not publish early.
 * Cancellation before start returns RELEASE_SOURCE and remains STOPPING until
 * COMPLETE acknowledges release. It ends CANCELLED, with no delivered media.
 * Other COMPLETE events are accepted only after STOP and media finalization /
 * resource cleanup, and return DELIVER_MEDIA. FAIL likewise requires completed
 * host cleanup, preserves raw bytes and ends ERROR. The core cannot inspect OS
 * resources: hosts must uphold this acknowledgement contract.
 * Invalid/late events return REJECTED and cannot mutate a closed session. */
int32_t recording_flow_open(void);
int32_t recording_flow_event(int32_t handle, int32_t event, double monotonic_ms);
int32_t recording_flow_value(int32_t handle, int32_t key);
/* Refuses active sessions (0); terminal/already closed sessions return 1. */
int32_t recording_flow_close(int32_t handle);
/* Shared logical-coordinate panel geometry. Fourteen owned doubles:
 * panel x/y/w/h, text x/y/w/h, button x/y/w/h, font size, button event.
 * Invalid/tiny surfaces or hidden phases return zeros. Host supplies theme,
 * drawing, text metrics and DPI conversion; all rectangles/hit tests come here.
 * Release returned arrays/strings with moonbit_decref. Text is UTF-16.
 * hit returns CANCEL/STOP or 0. Close/keyboard/tooltip use the same actions. */
double *recording_ui_frame(int32_t handle, double width, double height);
int32_t recording_ui_hit(int32_t handle, double x, double y, double width, double height);
moonbit_string_t recording_ui_text(int32_t handle);
#ifdef __cplusplus
}
#endif
#endif
