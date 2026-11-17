#ifndef MOOJICUT_WINDOWS_CANVAS_ACCESSIBILITY_H
#define MOOJICUT_WINDOWS_CANVAS_ACCESSIBILITY_H
#include <windows.h>
#include <stdint.h>
typedef struct MCCanvasAccessible MCCanvasAccessible;
typedef void (*MCCanvasAccessibleAction)(void *context, const uint16_t *identifier, size_t length);
MCCanvasAccessible *mc_canvas_accessible_create(HWND window, MCCanvasAccessibleAction action, void *context);
/* Borrowed immutable frame; caller keeps it alive until replacement/disconnect.
 * False leaves the old frame and child identities unchanged. */
BOOL mc_canvas_accessible_frame(MCCanvasAccessible *accessible, int32_t frame);
/* Publish only after the canvas has committed ownership of the same frame. */
void mc_canvas_accessible_publish(MCCanvasAccessible *accessible);
LRESULT mc_canvas_accessible_object(MCCanvasAccessible *accessible, WPARAM wp, LPARAM lp);
/* Retained COM references become unavailable; child IDs are never reused. */
void mc_canvas_accessible_disconnect(MCCanvasAccessible *accessible);
#endif
