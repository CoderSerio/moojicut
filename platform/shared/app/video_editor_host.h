#ifndef MOOJICUT_VIDEO_EDITOR_HOST_H
#define MOOJICUT_VIDEO_EDITOR_HOST_H
#include "bindings/c/video_editor.h"
#include "platform/shared/graphics/canvas.h"
#include "platform/shared/media/media_worker.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct MCVideoEditorHost MCVideoEditorHost;
enum {
    MC_VIDEO_HOST_OPENING = 1, MC_VIDEO_HOST_OPEN, MC_VIDEO_HOST_CLOSING,
    MC_VIDEO_HOST_CLOSED, MC_VIDEO_HOST_FAILED
};
/* Owner/UI-thread only; the caller initializes MoonBit before create. No native
 * event loop is pumped and no client callback is invoked. create starts async
 * probe/draft IO; FAILED retains the original file and can be retried/closed.
 * source and draft are absolute local UTF-8 filenames, never URLs. */
MCVideoEditorHost *mc_video_editor_host_create(const char *source, const char *draft,
                                              bool silent, char *error, size_t capacity);
/* Optional explicit legacy/backup path: consulted ONLY if draft is genuinely
 * absent. Errors in an existing draft never fall back. The old file is read
 * only; every SAVE writes draft. No directory or filename convention is guessed. */
MCVideoEditorHost *mc_video_editor_host_create_with_legacy(const char *source, const char *draft,
    const char *legacy, bool silent, char *error, size_t capacity);
/* Nonblocking decode/IO completion polling. Call regularly, outside painting. */
void mc_video_editor_host_tick(MCVideoEditorHost *host);
int mc_video_editor_host_phase(const MCVideoEditorHost *host);
/* Changes when shared presentation may have changed (including waveform and
 * async errors); idle ticks do not advance it. Video frames have separate PTS
 * and generation tags and can be repainted without rebuilding the UI frame. */
uint64_t mc_video_editor_host_presentation_serial(const MCVideoEditorHost *host);
const char *mc_video_editor_host_error(MCVideoEditorHost *host);
/* MC_EDITOR_* query keys. No mutable child/session handle escapes this owner. */
int32_t mc_video_editor_host_value(const MCVideoEditorHost *host, int32_t key);
double mc_video_editor_host_number(const MCVideoEditorHost *host, int32_t key);
/* Caller-owned immutable ui_frame handle (0 until open); canvas takes ownership
 * only on successful set_frame. State JSON is UTF-8, free with text_free. */
int32_t mc_video_editor_host_frame(MCVideoEditorHost *host, double width, double height);
char *mc_video_editor_host_state(MCVideoEditorHost *host);
void mc_video_editor_host_text_free(char *text);
bool mc_video_editor_host_event(MCVideoEditorHost *host, const MCCanvasInput *input);
/* Complete JSON command including expectedRevision/requestId; editing decisions
 * and rejection messages remain MoonBit's responsibility. */
bool mc_video_editor_host_command(MCVideoEditorHost *host, const char *json);
/* Stable pending ticket, 0 if none. The thin window presents at most one chooser
 * for this ticket. NULL destination acknowledges cancellation. Export is MP4.
 * Dismiss/ack a pending chooser before requesting window close. */
int32_t mc_video_editor_host_chooser(const MCVideoEditorHost *host);
bool mc_video_editor_host_choose(MCVideoEditorHost *host, int32_t ticket, const char *destination);
bool mc_video_editor_host_request_close(MCVideoEditorHost *host, bool cancel_export);
bool mc_video_editor_host_retry(MCVideoEditorHost *host);
/* Readonly BGRA frame, NULL while a newer plan/seek is pending. No backend work.
 * Borrowed until the next tick/event/command/retry/close, never retain pixels. */
const MCMediaFrame *mc_video_editor_host_video(const MCVideoEditorHost *host);
/* False keeps ownership with caller until CLOSED and all IO has really drained. */
bool mc_video_editor_host_free(MCVideoEditorHost *host);
#ifdef __cplusplus
}
#endif
#endif
