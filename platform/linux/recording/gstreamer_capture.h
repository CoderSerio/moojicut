#ifndef MOOJICUT_LINUX_GSTREAMER_CAPTURE_H
#define MOOJICUT_LINUX_GSTREAMER_CAPTURE_H
#include <glib.h>

typedef struct MCGstCapture MCGstCapture;
typedef enum { MC_GST_X11, MC_GST_PIPEWIRE } MCGstSource;
typedef struct {
    MCGstSource kind;
    int x, y, width, height; /* X11 root physical pixels; not portal logical size. */
    int output_width, output_height, frames_per_second;
    int pipewire_fd; /* borrowed; start duplicates it */
    guint32 pipewire_node;
} MCGstCaptureInput;
typedef void (*MCGstStarted)(MCGstCapture *, gpointer);
typedef void (*MCGstFinished)(MCGstCapture *, gboolean, const char *path,
                              const char *error, gpointer);
/* Callbacks run on the caller's main context. Finished means the worker has
 * stopped/unreffed the pipeline and closed its FD; strings are callback-borrowed.
 * Failed originals are never deleted. The owner must stop and wait for finished
 * before releasing its user_data; capture handles expire after finished returns. */
gboolean mc_gst_capture_available(MCGstSource source, GError **error);
MCGstCapture *mc_gst_capture_start(const MCGstCaptureInput *input, const char *directory,
                                 MCGstStarted started, MCGstFinished finished, gpointer data,
                                 GError **error);
void mc_gst_capture_stop(MCGstCapture *capture);
typedef void (*MCGstDimensions)(int width, int height, const char *error, gpointer data);
/* Probe a permitted PipeWire node without writing a recording. Duplicates fd;
 * completion follows pipeline NULL and closure of the duplicate. */
void mc_gst_pipewire_dimensions(int fd, guint32 node, MCGstDimensions callback, gpointer data);
/* Deterministic media + actual X11 source checks; never invokes a portal. */
gboolean mc_gst_capture_smoke(const char *directory);
#endif
