#ifndef MOOJICUT_SHARED_RECORDING_PLAN_H
#define MOOJICUT_SHARED_RECORDING_PLAN_H

#include <stdint.h>
#include "moonbit.h"

enum { MC_RECORDING_MACOS = 0, MC_RECORDING_WINDOWS = 1 };
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
