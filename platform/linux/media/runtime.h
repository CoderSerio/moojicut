#ifndef MOOJICUT_LINUX_MEDIA_RUNTIME_H
#define MOOJICUT_LINUX_MEDIA_RUNTIME_H
#include <stdbool.h>
#include <stddef.h>

/* Configure this executable's private media bundle before GTK/GStreamer start.
 * The linker supplies an executable-relative RPATH for initial ELF imports.
 * System GLib/GTK and desktop services remain shared with the host desktop. */
bool mc_linux_media_runtime_init(char *error, size_t capacity);
#endif
