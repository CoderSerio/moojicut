#ifndef MOOJICUT_VIDEO_EDITOR_SESSION_H
#define MOOJICUT_VIDEO_EDITOR_SESSION_H
#include <stdint.h>
#include "moonbit.h"
#ifdef __cplusplus
extern "C" {
#endif
/* UI-thread-only shared editor owner. Open returns a positive handle or 0.
 * Source path is explicit (recordings may be MP4 or WebM). Inputs are borrowed
 * UTF-16; every returned string is owned by the caller and must be decref'd.
 * Boolean arguments/results are 0/1. An open editor owns its document and UI.
 * take_effect claims an immutable ticket: copy all values before invoking a
 * worker, and acknowledge only after its actual result. Do not give a worker
 * MoonBit handles. Plan handles are BORROWED until ACK, not caller-owned.
 * CLOSE_MEDIA success means all media workers/callbacks have drained. Only a
 * closed editor can be released. A failed save keeps its document alive.
 * Before exporting, the file backend must verify source/destination identity;
 * the session's path comparison alone cannot detect aliases or hard links.
 */
enum {
  MC_EDITOR_APPLY_PLAN = 1, MC_EDITOR_SAVE_DRAFT, MC_EDITOR_SEEK, MC_EDITOR_PLAY,
  MC_EDITOR_PREVIEW_RATE, MC_EDITOR_CHOOSE_EXPORT, MC_EDITOR_EXPORT,
  MC_EDITOR_CANCEL_EXPORT, MC_EDITOR_CLOSE_MEDIA
};
enum { MC_EDITOR_ACK_OK, MC_EDITOR_ACK_FAILED, MC_EDITOR_ACK_CANCELLED };
enum {
  MC_EDITOR_PHASE, MC_EDITOR_DIRTY, MC_EDITOR_MEDIA_READY, MC_EDITOR_EXPORT_BUSY,
  MC_EDITOR_CAPTURE, MC_EDITOR_PLAYING, MC_EDITOR_GENERATION
};
enum { MC_EDITOR_OPEN = 1, MC_EDITOR_CLOSING, MC_EDITOR_CLOSED };
enum {
  MC_EDITOR_REVISION, MC_EDITOR_SAVED_REVISION, MC_EDITOR_MEDIA_REVISION,
  MC_EDITOR_OUTPUT_MS, MC_EDITOR_RATE, MC_EDITOR_EXPORT_PROGRESS
};
enum { MC_EDITOR_SOURCE_PATH, MC_EDITOR_DOCUMENT, MC_EDITOR_ERROR };
/* An asynchronous preview failure after a prior successful ACK. Stale media
 * generations are ignored. This never marks an independent export complete. */
int32_t video_editor_media_failed(int32_t handle, int32_t generation, moonbit_string_t message);
/* Effect number: SEEK=output ms; PLAY=0/1; RATE=rate; CANCEL_EXPORT=target ticket.
 * Effect text: SAVE=exact document JSON; EXPORT=destination; APPLY=source path.
 * ACK message: CHOOSE_EXPORT success=destination; otherwise an error message.
 * A stale generation may release its resources but cannot change current UI.
 */
int32_t video_editor_open(moonbit_string_t source_path, moonbit_string_t metadata, moonbit_string_t draft);
/* A fallback/imported draft still needs durable SAVE at its new destination. */
int32_t video_editor_open_unsaved(moonbit_string_t source_path, moonbit_string_t metadata, moonbit_string_t draft);
int32_t video_editor_event(int32_t handle, moonbit_string_t input);
int32_t video_editor_command(int32_t handle, moonbit_string_t command);
moonbit_string_t video_editor_frame(int32_t handle, double width, double height);
moonbit_string_t video_editor_state(int32_t handle);
int32_t video_editor_value(int32_t handle, int32_t key);
double video_editor_number(int32_t handle, int32_t key);
moonbit_string_t video_editor_text(int32_t handle, int32_t key);
int32_t video_editor_take_effect(int32_t handle);
int32_t video_editor_effect_kind(int32_t handle, int32_t effect);
int32_t video_editor_effect_plan(int32_t handle, int32_t effect);
int32_t video_editor_effect_generation(int32_t handle, int32_t effect);
double video_editor_effect_revision(int32_t handle, int32_t effect);
double video_editor_effect_number(int32_t handle, int32_t effect);
moonbit_string_t video_editor_effect_text(int32_t handle, int32_t effect);
int32_t video_editor_ack(int32_t handle, int32_t effect, int32_t status, moonbit_string_t message);
int32_t video_editor_playback(int32_t handle, int32_t generation, double milliseconds, int32_t playing);
int32_t video_editor_export_progress(int32_t handle, int32_t effect, double fraction);
int32_t video_editor_waveform(int32_t handle, moonbit_string_t event);
int32_t video_editor_retry(int32_t handle);
int32_t video_editor_request_close(int32_t handle, int32_t cancel_export);
int32_t video_editor_release(int32_t handle);
#ifdef __cplusplus
}
#endif
#endif
