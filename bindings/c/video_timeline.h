#ifndef MOOJICUT_SHARED_VIDEO_TIMELINE_H
#define MOOJICUT_SHARED_VIDEO_TIMELINE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Stateless, scalar-only geometry. Initialize the shared core before use.
 * All times are milliseconds. NaN indicates invalid/nonfinite input or track.
 * Finite out-of-bounds pointer/time positions clamp to the track endpoints. */
double video_timeline_x_for_time(double time_ms, double duration_ms,
                                double track_x, double track_width);
double video_timeline_time_for_x(double x, double duration_ms,
                                double track_x, double track_width);
/* 1/2/5 × powers-of-ten ruler spacing, >=1ms. The view supplies label spacing
 * using its font metrics. Invalid/nonfinite inputs return NaN. */
double video_timeline_tick_step(double duration_ms, double track_width,
                               double min_label_spacing);

/* edge 0=start, 1=end; the opposite edge never moves. Existing range/duration
 * are integer milliseconds. The candidate rounds to nearest ms. min_span_ms
 * rounds up and is capped by duration, so a short full clip stays selectable.
 * Invalid/impossible fixed-edge constraints return NaN: retain current state.
 * Hosts preview during dragging, commit one edit on completion, restore on cancel. */
double video_timeline_trim_boundary(int32_t edge, double candidate_ms,
                                   double start_ms, double end_ms,
                                   double duration_ms, double min_span_ms);

/* Document adapter, separate from the standalone component's geometry:
 * session is the existing video_open/video_command handle (zero is valid).
 * Maps edited playback time into source time; -1 means invalid input/session.
 * At a cut join, use the next retained segment; at the output end, use the last
 * retained millisecond. No new session, history entry or document is created. */
double video_source_time(int32_t session, double output_ms);

#ifdef __cplusplus
}
#endif

#endif
