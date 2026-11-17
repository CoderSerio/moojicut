#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include "surface.h"
#include "selection.h"
#include <stdlib.h>
#include <wchar.h>
#include <windowsx.h>

typedef struct {
  MCSelectionSurfaceOptions options;
  MCSelection selection;
  BOOL finishing;
} SelectionSurface;
typedef struct { SelectionSurface *surface; BOOL attached; } SurfaceCreation;
static const wchar_t surface_class[] = L"MoojiCut.Shared.Selection";

static BOOL CALLBACK monitor_bounds(HMONITOR monitor, HDC dc, LPRECT rect, LPARAM context) {
  RECT *bounds = (RECT *)context;
  (void)monitor; (void)dc;
  if (IsRectEmpty(bounds)) *bounds = *rect;
  else UnionRect(bounds, bounds, rect);
  return TRUE;
}
BOOL mc_selection_desktop_bounds(RECT *bounds) {
  SetRectEmpty(bounds);
  /* Under the application's PerMonitorV2 context these are physical pixels;
   * do not combine monitor-local DIPs with GetSystemMetrics-derived sizes. */
  return EnumDisplayMonitors(NULL, NULL, monitor_bounds, (LPARAM)bounds) && !IsRectEmpty(bounds);
}
static void finish(HWND window, SelectionSurface *surface, BOOL accepted, RECT rect) {
  if (surface->finishing) return;
  surface->finishing = TRUE;
  MCSelectionSurfaceOptions options = surface->options;
  if (GetCapture() == window) ReleaseCapture();
  DestroyWindow(window);
  if (options.finished) options.finished(options.context, accepted, rect);
}
static void decorate(HWND window, HDC dc, RECT rect) {
  HPEN pen = CreatePen(PS_SOLID, 1, RGB(238, 238, 238));
  HGDIOBJ old_pen = SelectObject(dc, pen), old_brush = SelectObject(dc, GetStockObject(HOLLOW_BRUSH));
  Rectangle(dc, rect.left, rect.top, rect.right, rect.bottom);
  SelectObject(dc, old_brush); SelectObject(dc, old_pen); DeleteObject(pen);
  wchar_t text[64];
  swprintf_s(text, 64, L" %ld × %ld px ", rect.right - rect.left, rect.bottom - rect.top);
  HGDIOBJ old_font = SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT));
  SetTextColor(dc, RGB(245, 245, 245)); SetBkColor(dc, RGB(32, 32, 32)); SetBkMode(dc, OPAQUE);
  int top = rect.top - MulDiv(24, (int)GetDpiForWindow(window), 96);
  TextOutW(dc, rect.left, top < 0 ? 0 : top, text, (int)wcslen(text));
  SelectObject(dc, old_font);
}
static POINT event_point(const SelectionSurface *surface, LPARAM lp) {
  POINT point = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
  /* LPARAM stores signed 16-bit client coordinates. Physical cursor positions
   * avoid wrapping at the edge of a 32768px/negative-origin virtual desktop.
   * Hidden test surfaces deliberately consume their synthetic message points. */
  if (!surface->options.hidden && GetPhysicalCursorPos(&point)) {
    LONGLONG x = (LONGLONG)point.x - surface->options.desktop_bounds.left;
    LONGLONG y = (LONGLONG)point.y - surface->options.desktop_bounds.top;
    point.x = (LONG)(x < 0 ? 0 : x > surface->selection.bounds.right ? surface->selection.bounds.right : x);
    point.y = (LONG)(y < 0 ? 0 : y > surface->selection.bounds.bottom ? surface->selection.bounds.bottom : y);
  }
  return point;
}
static LRESULT CALLBACK surface_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  SelectionSurface *surface = (SelectionSurface *)GetWindowLongPtrW(window, GWLP_USERDATA);
  if (message == WM_NCCREATE) {
    SurfaceCreation *creation = (SurfaceCreation *)((CREATESTRUCTW *)lp)->lpCreateParams;
    surface = creation->surface; creation->attached = TRUE;
    SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)surface);
  }
  if (!surface) return DefWindowProcW(window, message, wp, lp);
  switch (message) {
  case WM_ERASEBKGND: return 1;
  case WM_PAINT: {
    PAINTSTRUCT paint; HDC dc = BeginPaint(window, &paint);
    RECT bounds = surface->selection.bounds, rect = mc_selection_rect(&surface->selection);
    BitBlt(dc, 0, 0, bounds.right, bounds.bottom, surface->options.dimmed, 0, 0, SRCCOPY);
    if (!IsRectEmpty(&rect)) {
      BitBlt(dc, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
             surface->options.desktop, rect.left, rect.top, SRCCOPY);
      if (surface->options.decorate) surface->options.decorate(surface->options.context, window, dc, rect);
      else decorate(window, dc, rect);
    }
    EndPaint(window, &paint); return 0;
  }
  case WM_LBUTTONDOWN:
    mc_selection_update(&surface->selection, MC_SELECTION_BEGIN, event_point(surface, lp));
    SetCapture(window); InvalidateRect(window, NULL, FALSE); return 0;
  case WM_MOUSEMOVE: {
    MCSelectionResult result = mc_selection_update(&surface->selection, MC_SELECTION_MOVE,
        event_point(surface, lp));
    if (result.status == MC_SELECTION_CHANGED) InvalidateRect(window, NULL, FALSE);
    return 0;
  }
  case WM_LBUTTONUP: {
    BOOL dragging = surface->selection.dragging;
    MCSelectionResult result = mc_selection_update(&surface->selection, MC_SELECTION_END,
        event_point(surface, lp));
    if (dragging && GetCapture() == window) ReleaseCapture();
    if (result.status == MC_SELECTION_COMMITTED) finish(window, surface, TRUE, result.rect);
    return 0;
  }
  case WM_CAPTURECHANGED:
    mc_selection_update(&surface->selection, MC_SELECTION_LOST_CAPTURE, (POINT){0, 0});
    InvalidateRect(window, NULL, FALSE); return 0;
  case WM_KEYDOWN:
    if (wp != VK_ESCAPE) return 0;
    /* fall through */
  case WM_RBUTTONDOWN:
  case WM_CLOSE:
  case WM_DISPLAYCHANGE:
    finish(window, surface, FALSE, (RECT){0, 0, 0, 0}); return 0;
  case WM_ACTIVATE:
    if (LOWORD(wp) == WA_INACTIVE && !surface->options.hidden && !surface->finishing)
      finish(window, surface, FALSE, (RECT){0, 0, 0, 0});
    return 0;
  case WM_DPICHANGED:
    /* The frozen bitmap/window remains in desktop physical pixels. Moving it
     * to the suggested DPI-scaled rectangle would misalign the selected area. */
    InvalidateRect(window, NULL, FALSE); return 0;
  case WM_NCDESTROY:
    SetWindowLongPtrW(window, GWLP_USERDATA, 0);
    free(surface); break;
  }
  return DefWindowProcW(window, message, wp, lp);
}
HWND mc_selection_surface_open(HINSTANCE instance, HWND owner, const MCSelectionSurfaceOptions *options) {
  if (!options || !options->desktop || !options->dimmed || !options->finished) return NULL;
  LONGLONG width = (LONGLONG)options->desktop_bounds.right - options->desktop_bounds.left;
  LONGLONG height = (LONGLONG)options->desktop_bounds.bottom - options->desktop_bounds.top;
  if (width < 2 || height < 2 || width > 32768 || height > 32768) return NULL;
  WNDCLASSEXW klass = {0};
  klass.cbSize = sizeof(klass);
  klass.hInstance = instance; klass.lpfnWndProc = surface_proc; klass.lpszClassName = surface_class;
  klass.hCursor = LoadCursorW(NULL, IDC_CROSS);
  if (!RegisterClassExW(&klass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return NULL;
  SelectionSurface *surface = (SelectionSurface *)calloc(1, sizeof(*surface));
  if (!surface) return NULL;
  surface->options = *options;
  mc_selection_init(&surface->selection, (RECT){0, 0, (LONG)width, (LONG)height}, 2);
  SurfaceCreation creation = {surface, FALSE};
  HWND window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, surface_class, L"Mooji Cut · 框选", WS_POPUP,
      options->desktop_bounds.left, options->desktop_bounds.top, (int)width, (int)height,
      owner, NULL, instance, &creation);
  /* WM_NCCREATE/WM_NCDESTROY own surface from window creation onwards. */
  if (!window && !creation.attached) free(surface);
  return window;
}
void mc_selection_surface_activate(HWND window) {
  if (!window || !IsWindow(window)) return;
  ShowWindow(window, SW_SHOW); UpdateWindow(window); SetForegroundWindow(window); SetFocus(window);
}
void mc_selection_surface_dismiss(HWND window) {
  if (!window || !IsWindow(window)) return;
  SelectionSurface *surface = (SelectionSurface *)GetWindowLongPtrW(window, GWLP_USERDATA);
  if (surface) surface->finishing = TRUE;
  if (GetCapture() == window) ReleaseCapture();
  DestroyWindow(window);
}
