#ifndef MOOJICUT_WINDOWS_MEDIA_RUNTIME_H
#define MOOJICUT_WINDOWS_MEDIA_RUNTIME_H
#include <stdbool.h>
#include <stddef.h>
#include <wchar.h>
/* Process startup, before the first GStreamer call. Uses the verified runtime
 * beside the EXE and a writable per-user cache, independent of cwd/system SDKs.
 * MOOJICUT_MEDIA_CACHE_DIR can isolate automated tests; it must be absolute. */
bool mc_win_media_runtime_init(wchar_t *error, size_t capacity);
#endif
