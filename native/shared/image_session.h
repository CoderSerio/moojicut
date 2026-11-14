#ifndef MOOJICUT_IMAGE_SESSION_H
#define MOOJICUT_IMAGE_SESSION_H

#include <stdint.h>
#include "moonbit.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Checked MoonBit document API. Mutations return 1 on success, 0 on invalid
 * session/input. Indices refer to the current document and may change after
 * remove/undo/redo. Coordinates always refer to the full captured image.
 * Hosts retain live drag/text drafts and commit once when a gesture finishes. */
int32_t image_session_create(int32_t width, int32_t height);
/* Initial selection has no undo entry. Subsequent crop changes are undoable. */
int32_t image_session_create_viewport(int32_t width, int32_t height,
                                     int32_t x, int32_t y, int32_t w, int32_t h);
int32_t image_session_crop(int32_t id, int32_t x, int32_t y, int32_t w, int32_t h);
/* Viewport fields: 0=x, 1=y, 2=width, 3=height. */
double image_session_viewport_value(int32_t id, int32_t field);

/* Kinds: 1=rectangle, 2=arrow, 3=text, 4=filled cover (legacy name: redact). Arrow width/height
 * are signed deltas to the endpoint. Color is RGB 0x000000..0xffffff.
 * Text add/update consumes the pending content set with set_text; set it
 * before every text commit, including geometry/style-only text updates. */
int32_t image_session_set_text(int32_t id, moonbit_string_t text);
int32_t image_session_add(int32_t id, int32_t kind, int32_t x, int32_t y,
                         int32_t w, int32_t h, int32_t color, int32_t stroke);
int32_t image_session_add_styled(int32_t id, int32_t kind, int32_t x, int32_t y,
                                int32_t w, int32_t h, int32_t color,
                                int32_t stroke, int32_t font_size);
/* RGBA operations commit geometry/style/text atomically. Opacity must be
 * finite and between 0 and 1 inclusive; zero is a transparent annotation.
 * Legacy add defaults to opacity 1; legacy update preserves existing opacity. */
int32_t image_session_add_rgba(int32_t id, int32_t kind, int32_t x, int32_t y,
                              int32_t w, int32_t h, int32_t color,
                              int32_t stroke, int32_t font_size, double opacity);
int32_t image_session_update_rgba(int32_t id, int32_t index, int32_t x, int32_t y,
                                 int32_t w, int32_t h, int32_t color,
                                 int32_t stroke, int32_t font_size, double opacity);
int32_t image_session_update(int32_t id, int32_t index, int32_t x, int32_t y,
                            int32_t w, int32_t h, int32_t color,
                            int32_t stroke, int32_t font_size);
int32_t image_session_remove(int32_t id, int32_t index);
int32_t image_session_undo(int32_t id);
int32_t image_session_redo(int32_t id);
int32_t image_session_count(int32_t id);
/* Annotation fields: 0=kind, 1=x, 2=y, 3=width, 4=height, 5=RGB color,
 * 6=stroke width, 7=font size (text only), 8=opacity (0..1).
 * Unknown fields return zero. */
double image_session_value(int32_t id, int32_t index, int32_t field);
moonbit_string_t image_session_text(int32_t id, int32_t index);
void image_session_dispose(int32_t id);

#ifdef __cplusplus
}
#endif
#endif
