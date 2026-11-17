#ifndef MOOJICUT_GST_MEDIA_ENGINE_H
#define MOOJICUT_GST_MEDIA_ENGINE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Private media-worker API: initialization, probing and every engine operation
 * (including destruction) run on ONE process-wide GES owner thread, the same
 * thread that first calls mc_gst_media_init. GES does not support independent
 * per-editor threads, even when their engine objects differ. The owner uses a
 * persistent non-UI thread-default GMainContext in production. Calls may block
 * on discovery/codec work and must never run on a UI thread; shutdown waits for
 * actual callbacks/resource drain rather than abandoning an in-flight request.
 *
 * No MoonBit handles, views, or editable document are held here. The caller
 * supplies a copied, validated 90 kHz render plan. Transferred frame bytes are
 * independent of GES: mc_gst_frame_clear may run on their receiving thread. */
#define MC_GST_MAX_CLIPS 256
typedef struct {
    int64_t start, source_start, source_end, duration;
} MCGstClip;
typedef struct {
    int width, height, crop_x, crop_y, crop_width, crop_height;
    int64_t duration;
    bool quality;
    size_t video_count, audio_count;
    MCGstClip video[MC_GST_MAX_CLIPS], audio[MC_GST_MAX_CLIPS];
} MCGstPlan;
typedef struct {
    int width, height;
    double duration_ms;
    bool has_audio;
} MCGstMetadata;
typedef struct {
    unsigned char *pixels;
    int width, height, stride;
    int64_t pts_ns;
} MCGstFrame;
typedef struct MCGstEngine MCGstEngine;
enum { MC_GST_RUNNING, MC_GST_EOS, MC_GST_ERROR };

/* Errors are bounded UTF-8; supplying NULL/zero is allowed. */
bool mc_gst_media_init(char *error, size_t capacity);
bool mc_gst_media_probe(const char *path, MCGstMetadata *metadata, char *error, size_t capacity);
MCGstEngine *mc_gst_engine_new(const char *path, const MCGstPlan *plan, char *error, size_t capacity);
bool mc_gst_engine_preview(MCGstEngine *engine, bool silent, char *error, size_t capacity);
bool mc_gst_engine_seek(MCGstEngine *engine, double milliseconds, double rate, bool playing,
                        char *error, size_t capacity);
bool mc_gst_engine_play(MCGstEngine *engine, bool playing, char *error, size_t capacity);
bool mc_gst_engine_render(MCGstEngine *engine, const char *temporary_path, bool mp4,
                          char *error, size_t capacity);
/* Raw MP4 is an intermediate. After EOS and free(NULL barrier), the worker
 * must pass this encoder's priming count to mc_mp4_mux_copy before publication. */
int mc_gst_engine_aac_priming(MCGstEngine *engine);
int mc_gst_engine_poll(MCGstEngine *engine, char *error, size_t capacity);
double mc_gst_engine_position(MCGstEngine *engine);
/* On success, frame owns its BGRA bytes. Pass a zeroed/cleared frame; lack of a
 * new sample returns false and leaves it untouched. Call clear after use. */
bool mc_gst_engine_frame(MCGstEngine *engine, MCGstFrame *frame);
void mc_gst_frame_clear(MCGstFrame *frame);
/* NULL is a real resource-release barrier, not merely a cancel request. */
void mc_gst_engine_free(MCGstEngine *engine);
#endif
