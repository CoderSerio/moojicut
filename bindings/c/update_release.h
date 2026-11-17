#ifndef MOOJICUT_UPDATE_RELEASE_H
#define MOOJICUT_UPDATE_RELEASE_H
#include <stdint.h>
#include "moonbit.h"
#ifdef __cplusplus
extern "C" {
#endif
enum { MC_UPDATE_MACOS_ARM64 = 0, MC_UPDATE_WINDOWS_X64 = 1, MC_UPDATE_LINUX_X64 = 2 };
enum { MC_UPDATE_INVALID = -1, MC_UPDATE_CURRENT = 0, MC_UPDATE_AVAILABLE = 1, MC_UPDATE_INCOMPLETE = 2 };
enum { MC_UPDATE_VERSION = 0, MC_UPDATE_DOWNLOAD_URL = 1, MC_UPDATE_ASSET_NAME = 2,
       MC_UPDATE_SHA256 = 3, MC_UPDATE_FEED_URL = 4, MC_UPDATE_RELEASE_URL = 5 };
/* Main thread only, like the document core. Arguments remain caller-owned;
 * release input strings after the call. Returned strings are owned and must
 * also be moonbit_decref'd by the host.
 * Input is the unauthenticated GitHub /releases array (up to 100 entries).
 * Stable installs exclude previews; preview installs accept both channels.
 * Drafts, malformed versions, foreign URLs and source archives are rejected.
 * 0 means invalid input or exhausted handles. Dispose every successful handle.
 * SHA256 authenticates download integrity against GitHub's asset metadata;
 * it is NOT a replacement for Sparkle's pinned-key signature validation. */
int32_t update_release_create(moonbit_string_t current, int32_t platform, moonbit_string_t body);
int32_t update_release_status(int32_t handle);
moonbit_string_t update_release_text(int32_t handle, int32_t field);
int32_t update_release_size(int32_t handle);
void update_release_dispose(int32_t handle);
/* -1 / 0 / 1, or 2 for an unsupported version label. */
int32_t update_version_compare(moonbit_string_t left, moonbit_string_t right);
#ifdef __cplusplus
}
#endif
#endif
