#ifndef MOOJICUT_WINDOWS_SELECTION_SURFACE_H
#define MOOJICUT_WINDOWS_SELECTION_SURFACE_H
#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif
/* A shared screenshot/recording selection window. The caller owns both DCs
 * until finished/dismiss returns. Rectangles are image pixels relative to the
 * physical desktop_bounds origin, including desktops with negative origins.
 * finished runs once, on the window thread, after the overlay is destroyed. */
typedef struct {
  RECT desktop_bounds;
  HDC desktop, dimmed;
  BOOL hidden;
  void *context;
  void (*decorate)(void *context, HWND window, HDC dc, RECT rect);
  void (*finished)(void *context, BOOL accepted, RECT rect);
} MCSelectionSurfaceOptions;

BOOL mc_selection_desktop_bounds(RECT *bounds);
HWND mc_selection_surface_open(HINSTANCE instance, HWND owner,
                               const MCSelectionSurfaceOptions *options);
void mc_selection_surface_activate(HWND window);
/* Explicit dismissal has no finished callback; the caller is already handling
 * cancellation and owns the ordering of resource release. */
void mc_selection_surface_dismiss(HWND window);
#ifdef __cplusplus
}
#endif
#endif
