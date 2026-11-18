#ifndef MOOJICUT_SHARED_CANVAS_H
#define MOOJICUT_SHARED_CANVAS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "bindings/c/ui_frame.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { double x, y, width, height; } MCCanvasRect;
typedef struct {
  MCCanvasRect rect;
  const uint16_t *text;
  size_t length;
  int32_t color, weight, align, valign;
  double size;
} MCCanvasText;

/* Backend primitives only: the shared MoonBit frame owns geometry, colors,
 * text, icons and ordering. Coordinates are top-left logical points; the host
 * converts its device scale once. RGB -1 means absent paint. Text is borrowed
 * for the callback, must be clipped to rect, and must not be saved by a backend.
 * Each caller owns its graphics context and clips to the native surface bounds.
 * Painters must not pump events or replace/close the frame during a draw. */
typedef struct {
  void *context;
  void (*rectangle)(void *, MCCanvasRect, double radius, int32_t fill,
                    int32_t stroke, double line_width);
  void (*line)(void *, double x1, double y1, double x2, double y2,
               int32_t color, double line_width);
  void (*text)(void *, const MCCanvasText *);
} MCCanvasPainter;

bool mc_canvas_draw_layer(int32_t frame, int32_t layer, const MCCanvasPainter *painter);
bool mc_canvas_video_rect(int32_t frame, MCCanvasRect *rect);

/* Native input carries device-independent facts, never tool/clip decisions.
 * Text holds a key name, semantic ID or appearance mode; it is not an IME text
 * commit. This canvas is not a text editor. The returned string is caller-owned
 * and requires moonbit_decref; an empty result denotes invalid input. */
typedef struct {
  int32_t type;
  double x, y, delta_x, delta_y;
  int32_t flags;
  const uint16_t *text;
  size_t text_length;
} MCCanvasInput;

moonbit_string_t mc_canvas_input_json(const MCCanvasInput *input);

/* Independent text-system facts. Offsets are canonical LF/UTF-16; Windows
 * CRLF/GTK character offsets must be converted by the native bridge first.
 * Unknown selection uses zero placeholders, never an invented native caret.
 * The callback may synchronously replace a frame/retire a field; check identity
 * after returning. Strings in this structure are borrowed for this call only. */
typedef struct {
  int32_t type, token, version, start, end, selection_kind, anchor, focus;
  const uint16_t *id, *text;
  size_t id_length, text_length;
} MCCanvasTextInput;
moonbit_string_t mc_canvas_text_input_json(const MCCanvasTextInput *input);

#ifdef __cplusplus
}
#endif
#endif
