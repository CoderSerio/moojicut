#ifndef MOOJICUT_FEATURE_RUNTIME_H
#define MOOJICUT_FEATURE_RUNTIME_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum { MC_FEATURE_DISABLED = 0, MC_FEATURE_ENABLED = 1, MC_FEATURE_DISABLING = 2 };
enum { MC_FEATURE_ENABLE = 0, MC_FEATURE_REQUEST_DISABLE = 1, MC_FEATURE_CLEANUP_FINISHED = 2 };
/* Shared policy, not a dynamic loader. Host owns state and native resources.
 * Gate new work before releasing windows/hotkeys/callbacks; report cleanup only
 * after they are gone. Enable during cleanup is rejected (state unchanged).
 * Unknown states fail closed. Calls run on each platform's UI thread. */
int32_t feature_transition(int32_t state, int32_t event);
int32_t feature_can_invoke(int32_t state);
#ifdef __cplusplus
}
#endif
#endif
