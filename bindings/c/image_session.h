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
/* Read-only hit in full-image coordinates; tolerance is also in image pixels.
 * text_only is 0 or 1. Returns a current annotation index, or -1 for no hit or
 * invalid input/session. Filled covers win over other shapes; rectangles hit
 * their outline, arrows their strokes, and text/filled covers their bounds. */
int32_t image_session_hit(int32_t id, double x, double y, double tolerance, int32_t text_only);
/* Arrowhead wings before host scaling: fields 0/1=first x/y, 2/3=second x/y.
 * The same geometry is used by hit testing. Invalid input/field returns zero. */
double image_arrowhead_value(double x, double y, double x2, double y2, double stroke, int32_t field);
/* Annotation fields: 0=kind, 1=x, 2=y, 3=width, 4=height, 5=RGB color,
 * 6=stroke width, 7=font size (text only), 8=opacity (0..1), 9=shape (0=rect, 1=ellipse, 2=mosaic),
 * 10=mosaic block size. Kinds retain their family: ellipse=1, mosaic=4.
 * Unknown fields return zero. */
double image_session_value(int32_t id, int32_t index, int32_t field);
moonbit_string_t image_session_text(int32_t id, int32_t index);
/* Shared capture_ui gesture adapter. Begin freezes tool/style; move previews
 * only; end adds one undo entry; cancel adds none. Preview fields match value(). */
int32_t image_session_shape_begin(int32_t id, int32_t kind, double x, double y,
    int32_t color, double stroke, double opacity, int32_t shape, double block);
/* Declarative dragRect interaction. Commands are resolved by the shared feature,
 * never by a platform button ID. Shape is reserved/ignored for this rectangle
 * template. End/move/cancel and rectangle preview use the existing APIs below.
 * End publishes all resulting annotations in one undo step; a document change
 * since begin rejects the stale gesture. Command strings remain caller-owned. */
int32_t image_session_tool_begin(int32_t id, moonbit_string_t command, double x, double y,
    int32_t color, double stroke, double opacity, int32_t shape, double block);
/* Pure JSON host adapter: {document, expectedRevision, command, rectangle} ->
 * {ok:true,command} or structured error. A normal image_apply commits the result.
 * Request remains caller-owned; release the owned result with moonbit_decref. */
moonbit_string_t image_contribution_command(moonbit_string_t request);
int32_t image_session_shape_event(int32_t id, int32_t phase, double x, double y);
double image_session_preview_value(int32_t id, int32_t field);
/* editor_style field 4=shape, 5=block size. One checked undoable mutation. */
int32_t image_session_set_variant(int32_t id, int32_t index, int32_t field, double value);
void image_session_dispose(int32_t id);

#ifdef __cplusplus
}
#endif
#endif
