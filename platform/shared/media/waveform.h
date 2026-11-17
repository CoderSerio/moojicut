#ifndef MOOJICUT_MEDIA_WAVEFORM_H
#define MOOJICUT_MEDIA_WAVEFORM_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct MCWaveformAnalysis MCWaveformAnalysis;
enum {
    MC_WAVEFORM_RUNNING, MC_WAVEFORM_READY, MC_WAVEFORM_NO_AUDIO,
    MC_WAVEFORM_UNSUPPORTED, MC_WAVEFORM_FAILED, MC_WAVEFORM_CANCELLED
};
typedef struct {
    int status;
    double progress; /* [0,1], approximate source-time coverage. */
    int64_t duration_ms;
    size_t peak_count;
    char error[1024]; /* Inline bounded UTF-8. Empty for ready/no-audio/cancelled. */
} MCWaveformState;
typedef struct {
    float *peaks; /* Caller-owned immutable amplitudes in [0,1], not a spectrum. */
    size_t count; /* <=16384 equally spaced bins over duration_ms, source time. */
    int64_t duration_ms;
} MCWaveformResult;

/* Absolute local UTF-8 path; no URLs. duration_ms is the same validated integer
 * source duration supplied to MoonBit, in [1,604800000]; peak_count is 1..16384.
 * Create copies input and starts a Gst-only thread/private context, never GES,
 * MoonBit or UI calls. Decoded mono F32 samples are assigned by their actual
 * GstSegment stream time and sample rate. Missing timestamp gaps stay silent;
 * edited clip offsets/speed/trim are exclusively the shared UI's concern.
 *
 * Poll/cancel/take perform no media or filesystem work. READY/NO_AUDIO are
 * published only after pipeline NULL and all Gst objects/callbacks are gone.
 * NO_AUDIO is successful empty analysis; unsupported/multiple streams and
 * failures remain distinct. Do not race owner-thread calls with free.
 */
MCWaveformAnalysis *mc_waveform_create(const char *source_path, int64_t duration_ms,
                                      size_t peak_count, char *error, size_t capacity);
bool mc_waveform_poll(MCWaveformAnalysis *analysis, MCWaveformState *state);
/* Pass a zeroed/cleared result. One successful ownership transfer per analysis;
 * returns false while running, on failure/cancel, or after a previous take.
 * The result survives analysis.free and may be serialized on the UI thread. */
bool mc_waveform_take(MCWaveformAnalysis *analysis, MCWaveformResult *result);
void mc_waveform_result_clear(MCWaveformResult *result);
void mc_waveform_cancel(MCWaveformAnalysis *analysis);
/* False while running, leaving ownership intact. Terminal state is a resource
 * barrier; free then joins only the thread's return, with no backend work. */
bool mc_waveform_free(MCWaveformAnalysis *analysis);
#ifdef __cplusplus
}
#endif
#endif
