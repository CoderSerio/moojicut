#ifndef MOOJICUT_MP4_MUX_H
#define MOOJICUT_MP4_MUX_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Worker-only final packaging of this backend's newly encoded H.264 + optional
 * AAC MP4. Copies every compressed packet; never interprets an editing plan.
 * aac_priming_samples comes from the selected encoder configuration, not from
 * an assumption about arbitrary imported AAC. A video-only input requires 0.
 * Input and output are UTF-8 filesystem paths, not URLs. The output must not
 * exist: it is exclusively created and removed on failure/cancellation. Input
 * is read-only. Publication to the user's final path belongs to the caller.
 * Returns only after all file/codec resources are closed. cancel may be NULL;
 * it runs synchronously on the calling worker, including during AVIO calls.
 * No CLI, file-protocol support, network, or global FFmpeg registration needed.
 */
bool mc_mp4_mux_copy(const char *input_path, const char *new_temporary_path,
                     int aac_priming_samples, bool (*cancel)(void *), void *context,
                     char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
