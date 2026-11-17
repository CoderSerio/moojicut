#ifndef MOOJICUT_SHARED_RECORDING_PLAN_H
#define MOOJICUT_SHARED_RECORDING_PLAN_H

#include <stdint.h>
#include "moonbit.h"

enum { MC_RECORDING_MACOS = 0, MC_RECORDING_WINDOWS = 1,
       MC_RECORDING_LINUX_X11 = 2, MC_RECORDING_LINUX_WAYLAND = 3 };
typedef struct {
  int32_t width, height, frames_per_second;
  int32_t system_audio, microphone, countdown_seconds;
} MCCoreRecordingPlan;

#ifdef __cplusplus
extern "C" {
#endif
/* FixedArray[Int] is an owned int32_t*; invalid inputs return six zeros.
 * Call on the initialized core thread, then pass copied values to media workers.
 * This policy does not grant or implement any platform recording capability. */
int32_t *native_recording_plan(int32_t platform, int32_t width, int32_t height,
                               int32_t system_audio);
/* Pure JSON queries: platform is macOS/windows/linux-x11/linux-wayland.
 * Inputs remain caller-owned; returned MoonBit strings are owned and require
 * moonbit_decref. Call on the initialized core thread. Neither function probes
 * permissions, requests authorization, acquires a source, or starts recording.
 * A valid request plan still requires host permission/source/runtime checks.
 * Linux constants describe known unsupported environments; they do not enable
 * capture. native_recording_plan returns six zeros for them.
 * The legacy scalar API normalizes the Windows system_audio bit to zero; the
 * strict recording_request_plan API rejects unsupported audio/source/pause. */
moonbit_string_t recording_capabilities(moonbit_string_t platform);
moonbit_string_t recording_request_plan(moonbit_string_t request);
#ifdef __cplusplus
}
#endif

static inline MCCoreRecordingPlan mc_core_recording_plan(int32_t platform,
    int32_t width, int32_t height, int32_t system_audio) {
  int32_t *values = native_recording_plan(platform, width, height, system_audio);
  MCCoreRecordingPlan plan = {values[0], values[1], values[2], values[3], values[4], values[5]};
  moonbit_decref(values);
  return plan;
}

#endif
