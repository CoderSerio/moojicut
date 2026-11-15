#ifndef MOOJICUT_VIDEO_PROJECT_H
#define MOOJICUT_VIDEO_PROJECT_H
#include <stdint.h>
#include "moonbit.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Shared multi-clip editing core. Initialize MoonBit once on the UI thread.
 * Input strings remain caller-owned; release each returned string.
 * Commands carry expectedRevision and may carry requestId for safe retries. */
moonbit_string_t video_project_open(moonbit_string_t source, moonbit_string_t draft);
moonbit_string_t video_project_command(int32_t session, moonbit_string_t command);
moonbit_string_t video_project_snapshot(int32_t session);
void video_project_close(int32_t session);
#ifdef __cplusplus
}
#endif
#endif
