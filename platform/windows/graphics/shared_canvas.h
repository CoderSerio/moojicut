#ifndef MOOJICUT_WINDOWS_SHARED_CANVAS_H
#define MOOJICUT_WINDOWS_SHARED_CANVAS_H

#include <windows.h>
#include <stdint.h>
#include "platform/shared/graphics/canvas.h"

/* Generic UI-thread drawing/input adapter. It knows no document, timeline,
 * feature identifiers, media commands or application storage. Callbacks may
 * synchronously replace the frame or destroy the HWND. Context must remain
 * valid through the destroyed callback. */
typedef struct {
  void (*event)(void *context, HWND window, const MCCanvasInput *input);
  void (*resize)(void *context, HWND window, double width, double height);
  void (*destroyed)(void *context, HWND window);
  /* Optional media presentation between command and overlay layers. Bounds
   * are device pixels. Do not pump messages, replace frames or destroy the
   * window while drawing. The adapter owns no media/pixel buffer. */
  void (*video)(void *context, HWND window, HDC target, const RECT *bounds);
  /* Optional host focus fact: preserve an active native input during mouse
   * interaction. Keyboard/AX focus remains explicit. May retire the window. */
  BOOL (*preserve_focus_on_press)(void *context, HWND window);
} MCWinCanvasCallbacks;

HWND mc_win_canvas_create(HWND parent, HINSTANCE instance, int identifier,
                         const MCWinCanvasCallbacks *callbacks, void *context);
/* On success, transfers ownership of the immutable frame to this window.
 * Failure leaves ownership with the caller. Zero clears the displayed frame. */
BOOL mc_win_canvas_set_frame(HWND window, int32_t frame);
/* Apply the shared UI event result; capture is never inferred from geometry. */
void mc_win_canvas_set_capture(HWND window, BOOL capture);
/* Notify after a top-level activation loss if the application consumes that
 * message. Child focus loss/hide/capture loss also cancel input automatically. */
void mc_win_canvas_cancel(HWND window);
/* Render exactly the same frame into a caller-owned DC (physical-pixel client
 * bounds and DPI), used by printing and deterministic offscreen verification.
 * No video frames or media lifetime are owned by this adapter. */
BOOL mc_win_canvas_paint(HWND window, HDC target, const RECT *bounds, UINT dpi);

#endif
