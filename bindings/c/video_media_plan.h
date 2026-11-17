#ifndef MOOJICUT_VIDEO_MEDIA_PLAN_H
#define MOOJICUT_VIDEO_MEDIA_PLAN_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* UI-thread-only immutable copy of a validated video project plan. Open returns
 * 0 for an invalid/closed session or the 64-live-plan limit. Positive handles
 * are never reused; close is idempotent. The plan survives project edits/close.
 * Native callers copy the numeric fields before giving them to media workers.
 * There is no mutable document or media resource behind this handle. */
int32_t video_media_plan_open(int32_t project_session);
void video_media_plan_close(int32_t handle);
enum {
  MC_MEDIA_PLAN_WIDTH, MC_MEDIA_PLAN_HEIGHT, MC_MEDIA_PLAN_VIDEO_COUNT,
  MC_MEDIA_PLAN_AUDIO_COUNT, MC_MEDIA_PLAN_QUALITY, MC_MEDIA_PLAN_MUTED
};
int32_t video_media_plan_value(int32_t handle, int32_t key);
enum {
  MC_MEDIA_PLAN_DURATION_TICKS, MC_MEDIA_PLAN_SOURCE_DURATION_MS,
  MC_MEDIA_PLAN_CROP_X, MC_MEDIA_PLAN_CROP_Y, MC_MEDIA_PLAN_CROP_WIDTH,
  MC_MEDIA_PLAN_CROP_HEIGHT
};
double video_media_plan_number(int32_t handle, int32_t key);
enum { MC_MEDIA_PLAN_VIDEO, MC_MEDIA_PLAN_AUDIO };
enum {
  MC_MEDIA_CLIP_START_TICKS, MC_MEDIA_CLIP_SOURCE_START_TICKS,
  MC_MEDIA_CLIP_SOURCE_END_TICKS, MC_MEDIA_CLIP_DURATION_TICKS
};
/* All ticks are exact integers in a 90,000 Hz timebase (30 fps output). Each
 * stream is ordered by output start, then clip ID. Muted plans have no audio
 * entries, but their duration includes the retained muted clips. Invalid
 * handles/keys/indices return -1; zero is a legitimate value. */
double video_media_plan_clip_number(int32_t handle, int32_t kind, int32_t index, int32_t key);
#ifdef __cplusplus
}
#endif
#endif
