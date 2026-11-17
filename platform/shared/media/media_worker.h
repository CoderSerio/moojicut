#ifndef MOOJICUT_MEDIA_WORKER_H
#define MOOJICUT_MEDIA_WORKER_H
#include "platform/shared/media/gst_engine.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct MCMediaWorker MCMediaWorker;
enum {
    MC_MEDIA_PROBE = 1, MC_MEDIA_APPLY, MC_MEDIA_SEEK, MC_MEDIA_PLAY,
    MC_MEDIA_RATE, MC_MEDIA_EXPORT, MC_MEDIA_CANCEL_EXPORT, MC_MEDIA_CLOSE
};
enum { MC_MEDIA_OK, MC_MEDIA_FAILED, MC_MEDIA_CANCELLED };
typedef struct {
    int kind;
    uint64_t token, generation;
    const MCGstPlan *plan; /* APPLY/EXPORT: copied synchronously by submit. */
    const char *path;     /* EXPORT: UTF-8 final destination; copied. */
    double number;       /* SEEK: output ms. RATE: multiplier. */
    bool flag;           /* PLAY: playing. EXPORT: MP4 (false = Matroska). */
    uint64_t target;     /* CANCEL_EXPORT: export request token. */
} MCMediaRequest;
typedef struct {
    int kind, status;
    uint64_t token, generation;
    MCGstMetadata metadata; /* PROBE success only. */
    char error[1024];       /* Inline, bounded UTF-8; no borrowed strings. */
} MCMediaCompletion;
typedef struct {
    bool closed, media_ready, playing;
    uint64_t plan_generation, completed_seek_token, export_token, error_serial;
    double position_ms, rate, export_progress;
    MCGstMetadata metadata;
    char error[1024];
} MCMediaState;
typedef struct {
    MCGstFrame image; /* Owns tightly packed BGRA bytes, same clear API as engine. */
    uint64_t plan_generation, seek_token;
} MCMediaFrame;

/* No UI toolkit or MoonBit runtime. Calls below are nonblocking with respect to
 * decoding/encoding and perform no file IO on the calling thread. Create only
 * copies source_path and registers a session with a process-lifetime GES
 * executor. Its one GThread/independent GMainContext owns GES initialization
 * and every pipeline, as required by GES. Editors are serviced round-robin;
 * a closed editor never stops another editor's executor or playback.
 * initialization/probe failures arrive through a request completion. Paths
 * must be absolute local UTF-8 filenames, never URLs. silent_preview is useful
 * for headless tests; production normally passes false.
 *
 * Caller tokens must be nonzero and never reused in this worker's lifetime.
 * APPLY generations are nondecreasing; SEEK/PLAY/RATE must match the latest
 * accepted APPLY generation. Rejected stale requests cannot affect its state.
 * All plan/path input is borrowed only for submit. False means no request was
 * accepted and no completion will be delivered. There are at most 64 ordinary
 * outstanding requests (including completions not yet polled), with reserved
 * cancellation/close capacity. Every accepted request gets one terminal result.
 * Submit/poll/snapshot/take_frame may run on the owner thread while the worker
 * runs. Do not call them concurrently with free.
 */
MCMediaWorker *mc_media_worker_create(const char *source_path, bool silent_preview,
                                     char *error, size_t capacity);
bool mc_media_worker_submit(MCMediaWorker *worker, const MCMediaRequest *request,
                            char *error, size_t capacity);
bool mc_media_worker_poll(MCMediaWorker *worker, MCMediaCompletion *completion);
bool mc_media_worker_snapshot(MCMediaWorker *worker, MCMediaState *state);
/* Latest-frame mailbox: ownership transfers to the caller, with no backend
 * work or large pixel copy under the lock. Pass a zeroed/cleared frame. After
 * APPLY/SEEK acceptance old mailbox contents are discarded; later frames are
 * tagged with the completed plan generation and seek token. Compare both to
 * the owner's latest intent before displaying. Lack of a new frame is false.
 * The caller's owned frame remains valid across future submits and close. */
bool mc_media_worker_take_frame(MCMediaWorker *worker, MCMediaFrame *frame);
void mc_media_frame_clear(MCMediaFrame *frame);
/* CLOSE immediately stops accepting new work and signals export/mux cancel.
 * Its completion and state.closed occur only after pipelines are NULL, files
 * and callbacks are drained, and all earlier requests have terminal results.
 * Only then can free release this session. It returns false while live, leaving
 * ownership with the caller. Cancellation after atomic publication may race
 * with success; a published file is never deleted to simulate cancellation. */
bool mc_media_worker_free(MCMediaWorker *worker);
#ifdef __cplusplus
}
#endif
#endif
