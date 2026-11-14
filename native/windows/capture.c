#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include "capture.h"
#include <windowsx.h>
#include <commctrl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <wchar.h>
#include "moonbit.h"

extern int32_t image_session_create(int32_t, int32_t);
extern int32_t image_session_add(int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t);
extern int32_t image_session_set_text(int32_t, moonbit_string_t);
extern int32_t image_session_undo(int32_t);
extern int32_t image_session_redo(int32_t);
extern int32_t image_session_count(int32_t);
extern double image_session_value(int32_t, int32_t, int32_t);
extern moonbit_string_t image_session_text(int32_t, int32_t);
extern void image_session_dispose(int32_t);

enum { TOOL_RECT = 1, TOOL_ARROW, TOOL_TEXT, TOOL_REDACT };
enum { ID_RECT = 8101, ID_ARROW, ID_TEXT, ID_REDACT, ID_UNDO, ID_REDO,
       ID_COPY, ID_CANCEL, ID_TEXT_INPUT, ID_COLOR, ID_STROKE };
typedef struct { HDC dc; HBITMAP bitmap; HGDIOBJ previous; BYTE *pixels; int width, height; } Surface;
typedef struct {
  HINSTANCE instance;
  HWND owner, overlay, editor, text, colors, strokes, buttons[8];
  HFONT font;
  Surface desktop, dimmed, image, rendered;
  RECT desktop_bounds, canvas;
  POINT start, end;
  double zoom;
  int32_t session;
  int tool, color, stroke;
  BOOL dragging, dirty, smoke;
} Capture;
static Capture capture;
static const wchar_t *OVERLAY_CLASS = L"MoojiCut.Capture.Selection";
static const wchar_t *EDITOR_CLASS = L"MoojiCut.Capture.Editor";
static const int PALETTE[] = { 0xF26769, 0x246BFD, 0x25A56A, 0xFFFFFF, 0x111111 };

static int minimum(int a, int b) { return a < b ? a : b; }
static int maximum(int a, int b) { return a > b ? a : b; }
static int bounded(int value, int low, int high) { return maximum(low, minimum(value, high)); }
static int rounded(double value) { return (int)floor(value + 0.5); }
static COLORREF color_ref(int rgb) { return RGB((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }
static int dpi_px(HWND window, int value) { return MulDiv(value, (int)GetDpiForWindow(window), 96); }

static void surface_free(Surface *surface) {
  if (surface->previous && surface->dc) SelectObject(surface->dc, surface->previous);
  if (surface->bitmap) DeleteObject(surface->bitmap);
  if (surface->dc) DeleteDC(surface->dc);
  ZeroMemory(surface, sizeof(*surface));
}

static BOOL surface_new(Surface *surface, int width, int height) {
  BITMAPINFO info;
  if (width <= 0 || height <= 0 || (uint64_t)width * (uint64_t)height > 64000000) return FALSE;
  ZeroMemory(&info, sizeof(info));
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  surface->dc = CreateCompatibleDC(NULL);
  if (!surface->dc) return FALSE;
  surface->bitmap = CreateDIBSection(surface->dc, &info, DIB_RGB_COLORS, (void **)&surface->pixels, NULL, 0);
  if (!surface->bitmap) { surface_free(surface); return FALSE; }
  surface->previous = SelectObject(surface->dc, surface->bitmap);
  surface->width = width; surface->height = height;
  return TRUE;
}

static RECT selection(POINT a, POINT b) {
  RECT rect = { minimum(a.x, b.x), minimum(a.y, b.y), maximum(a.x, b.x), maximum(a.y, b.y) };
  return rect;
}

static void draw_annotation(HDC dc, int kind, double x, double y, double width, double height,
                            int color, double stroke, const wchar_t *text, int text_length,
                            double scale, int offset_x, int offset_y) {
  int left = offset_x + rounded(x * scale), top = offset_y + rounded(y * scale);
  int right = offset_x + rounded((x + width) * scale), bottom = offset_y + rounded((y + height) * scale);
  int thickness = maximum(1, rounded(stroke * scale));
  HPEN pen = CreatePen(PS_SOLID, thickness, color_ref(color));
  HGDIOBJ prior_pen = SelectObject(dc, pen), prior_brush = SelectObject(dc, GetStockObject(HOLLOW_BRUSH));
  if (kind == TOOL_RECT) Rectangle(dc, left, top, right, bottom);
  else if (kind == TOOL_ARROW) {
    double dx = (double)right - left, dy = (double)bottom - top, length = sqrt(dx * dx + dy * dy);
    if (length > 0.5) {
      double head = minimum(rounded(length * 0.45), maximum(8, rounded(14 * scale + thickness)));
      POINT wings[3];
      wings[0].x = rounded(right - head * dx / length + head * 0.45 * dy / length);
      wings[0].y = rounded(bottom - head * dy / length - head * 0.45 * dx / length);
      wings[1].x = right; wings[1].y = bottom;
      wings[2].x = rounded(right - head * dx / length - head * 0.45 * dy / length);
      wings[2].y = rounded(bottom - head * dy / length + head * 0.45 * dx / length);
      MoveToEx(dc, left, top, NULL); LineTo(dc, right, bottom); Polyline(dc, wings, 3);
    }
  } else if (kind == TOOL_REDACT) {
    RECT rect = { left, top, right, bottom };
    FillRect(dc, &rect, (HBRUSH)GetStockObject(BLACK_BRUSH));
  } else if (kind == TOOL_TEXT && text && text_length > 0) {
    HFONT font = CreateFontW(-maximum(1, rounded(24 * scale)), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE,
      FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
      DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    HGDIOBJ previous_font = SelectObject(dc, font);
    SetTextColor(dc, color_ref(color)); SetBkMode(dc, TRANSPARENT);
    TextOutW(dc, left, top, text, text_length);
    SelectObject(dc, previous_font); DeleteObject(font);
  }
  SelectObject(dc, prior_brush); SelectObject(dc, prior_pen); DeleteObject(pen);
}

static BOOL render_image(void) {
  int pass, i, count;
  if (!capture.session || !capture.image.dc) return FALSE;
  if (!capture.rendered.dc && !surface_new(&capture.rendered, capture.image.width, capture.image.height)) return FALSE;
  if (!capture.dirty) return TRUE;
  BitBlt(capture.rendered.dc, 0, 0, capture.image.width, capture.image.height, capture.image.dc, 0, 0, SRCCOPY);
  count = image_session_count(capture.session);
  /* Privacy masks always render last, including after later annotations. */
  for (pass = 0; pass < 2; pass++) for (i = 0; i < count; i++) {
    int kind = (int)image_session_value(capture.session, i, 0);
    moonbit_string_t text = NULL;
    if ((kind == TOOL_REDACT) != (pass == 1)) continue;
    if (kind == TOOL_TEXT) text = image_session_text(capture.session, i);
    draw_annotation(capture.rendered.dc, kind, image_session_value(capture.session, i, 1),
      image_session_value(capture.session, i, 2), image_session_value(capture.session, i, 3),
      image_session_value(capture.session, i, 4), (int)image_session_value(capture.session, i, 5),
      image_session_value(capture.session, i, 6), (const wchar_t *)text,
      text ? Moonbit_array_length(text) : 0, 1, 0, 0);
    if (text) moonbit_decref(text);
  }
  GdiFlush(); capture.dirty = FALSE;
  return TRUE;
}

static HGLOBAL image_dib(void) {
  SIZE_T stride, bytes; HGLOBAL memory; BITMAPINFOHEADER *header; BYTE *out; int x, y;
  if (!render_image()) return NULL;
  stride = ((SIZE_T)capture.image.width * 3 + 3) & ~(SIZE_T)3;
  bytes = stride * (SIZE_T)capture.image.height;
  memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(*header) + bytes);
  if (!memory) return NULL;
  header = (BITMAPINFOHEADER *)GlobalLock(memory);
  if (!header) { GlobalFree(memory); return NULL; }
  header->biSize = sizeof(*header); header->biWidth = capture.image.width;
  header->biHeight = capture.image.height; header->biPlanes = 1;
  header->biBitCount = 24; header->biCompression = BI_RGB; header->biSizeImage = (DWORD)bytes;
  out = (BYTE *)(header + 1);
  for (y = 0; y < capture.image.height; y++) {
    const BYTE *source = capture.rendered.pixels + (SIZE_T)y * capture.image.width * 4;
    BYTE *row = out + (SIZE_T)(capture.image.height - 1 - y) * stride;
    for (x = 0; x < capture.image.width; x++) memcpy(row + (SIZE_T)x * 3, source + (SIZE_T)x * 4, 3);
  }
  GlobalUnlock(memory);
  return memory;
}

static BOOL copy_image(void) {
  HGLOBAL dib = image_dib(); BOOL success = FALSE;
  if (!dib) return FALSE;
  if (OpenClipboard(capture.editor)) {
    if (EmptyClipboard() && SetClipboardData(CF_DIB, dib)) { dib = NULL; success = TRUE; }
    CloseClipboard();
  }
  if (dib) GlobalFree(dib);
  return success;
}

static void changed(void) {
  capture.dirty = TRUE;
  if (capture.editor) InvalidateRect(capture.editor, NULL, FALSE);
}

static void layout_editor(HWND window) {
  RECT client; int gap, top, button_width, height, i, toolbar;
  double sx, sy;
  GetClientRect(window, &client);
  gap = dpi_px(window, 10); top = gap; height = dpi_px(window, 30);
  button_width = maximum(dpi_px(window, 48), (client.right - 9 * gap) / 8);
  for (i = 0; i < 8; i++) MoveWindow(capture.buttons[i], gap + i * (button_width + gap), top, button_width, height, TRUE);
  top += height + gap;
  MoveWindow(capture.colors, gap, top, dpi_px(window, 100), height * 6, TRUE);
  MoveWindow(capture.strokes, gap * 2 + dpi_px(window, 100), top, dpi_px(window, 75), height * 5, TRUE);
  MoveWindow(capture.text, gap * 3 + dpi_px(window, 175), top,
    maximum(dpi_px(window, 100), client.right - gap * 4 - dpi_px(window, 175)), height, TRUE);
  toolbar = top + height + gap * 2;
  sx = (double)maximum(1, client.right - gap * 2) / capture.image.width;
  sy = (double)maximum(1, client.bottom - toolbar - gap) / capture.image.height;
  capture.zoom = fmin(1.0, fmin(sx, sy));
  capture.canvas.left = (client.right - rounded(capture.image.width * capture.zoom)) / 2;
  capture.canvas.top = toolbar + maximum(0, (client.bottom - toolbar - rounded(capture.image.height * capture.zoom)) / 2);
  capture.canvas.right = capture.canvas.left + maximum(1, rounded(capture.image.width * capture.zoom));
  capture.canvas.bottom = capture.canvas.top + maximum(1, rounded(capture.image.height * capture.zoom));
  InvalidateRect(window, NULL, FALSE);
}

static POINT image_point(int x, int y) {
  POINT result = { bounded(rounded((x - capture.canvas.left) / capture.zoom), 0, capture.image.width),
                   bounded(rounded((y - capture.canvas.top) / capture.zoom), 0, capture.image.height) };
  return result;
}

static BOOL add_shape(void) {
  RECT bounds = selection(capture.start, capture.end);
  if (capture.tool == TOOL_ARROW) {
    if (abs(capture.end.x - capture.start.x) + abs(capture.end.y - capture.start.y) < 3) return FALSE;
    return image_session_add(capture.session, capture.tool, capture.start.x, capture.start.y,
      capture.end.x - capture.start.x, capture.end.y - capture.start.y, capture.color, capture.stroke) == 1;
  }
  if (bounds.right - bounds.left < 2 || bounds.bottom - bounds.top < 2) return FALSE;
  return image_session_add(capture.session, capture.tool, bounds.left, bounds.top,
    bounds.right - bounds.left, bounds.bottom - bounds.top,
    capture.tool == TOOL_REDACT ? 0 : capture.color, capture.stroke) == 1;
}

static BOOL add_text(POINT point) {
  wchar_t text[1025]; int length = GetWindowTextW(capture.text, text, ARRAYSIZE(text));
  moonbit_string_t input;
  if (!length || point.x >= capture.image.width || point.y >= capture.image.height) return FALSE;
  input = moonbit_make_string_raw(length); memcpy(input, text, (SIZE_T)length * sizeof(wchar_t));
  if (!image_session_set_text(capture.session, input)) { moonbit_decref(input); return FALSE; }
  moonbit_decref(input);
  return image_session_add(capture.session, TOOL_TEXT, point.x, point.y,
    capture.image.width - point.x, minimum(32, capture.image.height - point.y), capture.color, capture.stroke) == 1;
}

static void editor_command(int command) {
  if (command >= ID_RECT && command <= ID_REDACT) {
    int i; capture.tool = command - ID_RECT + 1;
    for (i = 0; i < 4; i++) SendMessageW(capture.buttons[i], BM_SETCHECK, capture.tool == i + 1 ? BST_CHECKED : BST_UNCHECKED, 0);
    if (capture.tool == TOOL_TEXT) SetFocus(capture.text); else SetFocus(capture.editor);
  } else if (command == ID_UNDO) { image_session_undo(capture.session); changed(); }
  else if (command == ID_REDO) { image_session_redo(capture.session); changed(); }
  else if (command == ID_CANCEL) mc_capture_close();
  else if (command == ID_COPY) {
    if (copy_image()) mc_capture_close();
    else if (!capture.smoke) MessageBoxW(capture.editor, L"暂时无法复制，请关闭正在占用剪贴板的程序后重试。", L"Mooji Cut", MB_OK | MB_ICONWARNING);
  }
}

static LRESULT CALLBACK editor_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  switch (message) {
  case WM_CREATE: {
    const wchar_t *labels[] = { L"矩形", L"箭头", L"文字", L"遮挡", L"撤销", L"重做", L"复制", L"取消" };
    const wchar_t *colors[] = { L"珊瑚红", L"蓝色", L"绿色", L"白色", L"黑色" };
    int i;
    capture.editor = window;
    capture.font = CreateFontW(-dpi_px(window, 14), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    for (i = 0; i < 8; i++) {
      capture.buttons[i] = CreateWindowW(L"BUTTON", labels[i], WS_CHILD | WS_VISIBLE | WS_TABSTOP |
        (i < 4 ? BS_AUTOCHECKBOX | BS_PUSHLIKE : BS_PUSHBUTTON),
        0, 0, 1, 1, window, (HMENU)(INT_PTR)(ID_RECT + i), capture.instance, NULL);
      SendMessageW(capture.buttons[i], WM_SETFONT, (WPARAM)capture.font, TRUE);
    }
    capture.colors = CreateWindowW(L"COMBOBOX", NULL, WS_CHILD | WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST,
      0, 0, 1, 1, window, (HMENU)(INT_PTR)ID_COLOR, capture.instance, NULL);
    for (i = 0; i < 5; i++) SendMessageW(capture.colors, CB_ADDSTRING, 0, (LPARAM)colors[i]);
    SendMessageW(capture.colors, CB_SETCURSEL, 0, 0);
    capture.strokes = CreateWindowW(L"COMBOBOX", NULL, WS_CHILD | WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST,
      0, 0, 1, 1, window, (HMENU)(INT_PTR)ID_STROKE, capture.instance, NULL);
    SendMessageW(capture.strokes, CB_ADDSTRING, 0, (LPARAM)L"细线 2");
    SendMessageW(capture.strokes, CB_ADDSTRING, 0, (LPARAM)L"中线 4");
    SendMessageW(capture.strokes, CB_ADDSTRING, 0, (LPARAM)L"粗线 8");
    SendMessageW(capture.strokes, CB_SETCURSEL, 1, 0);
    capture.text = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"在这里输入文字，然后点击图片放置", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
      0, 0, 1, 1, window, (HMENU)(INT_PTR)ID_TEXT_INPUT, capture.instance, NULL);
    SendMessageW(capture.text, EM_SETLIMITTEXT, 1024, 0);
    SendMessageW(capture.text, EM_SETCUEBANNER, TRUE, (LPARAM)L"输入文字，再点击图片放置");
    SetWindowTextW(capture.text, L"");
    SendMessageW(capture.text, WM_SETFONT, (WPARAM)capture.font, TRUE);
    SendMessageW(capture.colors, WM_SETFONT, (WPARAM)capture.font, TRUE);
    SendMessageW(capture.strokes, WM_SETFONT, (WPARAM)capture.font, TRUE);
    SendMessageW(capture.buttons[0], BM_SETCHECK, BST_CHECKED, 0);
    layout_editor(window); return 0;
  }
  case WM_SIZE: if (capture.image.width) layout_editor(window); return 0;
  case WM_DPICHANGED: {
    RECT *suggested = (RECT *)lp;
    HFONT previous_font = capture.font; int i;
    capture.font = CreateFontW(-dpi_px(window, 14), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    for (i = 0; i < 8; i++) SendMessageW(capture.buttons[i], WM_SETFONT, (WPARAM)capture.font, TRUE);
    SendMessageW(capture.text, WM_SETFONT, (WPARAM)capture.font, TRUE);
    SendMessageW(capture.colors, WM_SETFONT, (WPARAM)capture.font, TRUE);
    SendMessageW(capture.strokes, WM_SETFONT, (WPARAM)capture.font, TRUE);
    if (previous_font) DeleteObject(previous_font);
    SetWindowPos(window, NULL, suggested->left, suggested->top, suggested->right - suggested->left,
      suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE); return 0;
  }
  case WM_GETMINMAXINFO:
    ((MINMAXINFO *)lp)->ptMinTrackSize.x = dpi_px(window, 660);
    ((MINMAXINFO *)lp)->ptMinTrackSize.y = dpi_px(window, 280); return 0;
  case WM_COMMAND:
    if (LOWORD(wp) == ID_COLOR && HIWORD(wp) == CBN_SELCHANGE) {
      int index = (int)SendMessageW(capture.colors, CB_GETCURSEL, 0, 0);
      if (index >= 0 && index < 5) capture.color = PALETTE[index];
    } else if (LOWORD(wp) == ID_STROKE && HIWORD(wp) == CBN_SELCHANGE) {
      int index = (int)SendMessageW(capture.strokes, CB_GETCURSEL, 0, 0);
      capture.stroke = index == 0 ? 2 : index == 2 ? 8 : 4;
    } else if (HIWORD(wp) == BN_CLICKED) editor_command(LOWORD(wp));
    return 0;
  case WM_ERASEBKGND: return 1;
  case WM_PAINT: {
    PAINTSTRUCT paint; HDC dc = BeginPaint(window, &paint); RECT client;
    GetClientRect(window, &client); FillRect(dc, &client, GetSysColorBrush(COLOR_BTNFACE));
    if (render_image()) {
      int prior = SetStretchBltMode(dc, HALFTONE); SetBrushOrgEx(dc, 0, 0, NULL);
      StretchBlt(dc, capture.canvas.left, capture.canvas.top, capture.canvas.right - capture.canvas.left,
        capture.canvas.bottom - capture.canvas.top, capture.rendered.dc, 0, 0, capture.image.width, capture.image.height, SRCCOPY);
      SetStretchBltMode(dc, prior);
      if (capture.dragging) {
        RECT box = selection(capture.start, capture.end); int saved = SaveDC(dc);
        IntersectClipRect(dc, capture.canvas.left, capture.canvas.top, capture.canvas.right, capture.canvas.bottom);
        draw_annotation(dc, capture.tool, capture.tool == TOOL_ARROW ? capture.start.x : box.left,
          capture.tool == TOOL_ARROW ? capture.start.y : box.top,
          capture.tool == TOOL_ARROW ? capture.end.x - capture.start.x : box.right - box.left,
          capture.tool == TOOL_ARROW ? capture.end.y - capture.start.y : box.bottom - box.top,
          capture.color, capture.stroke, NULL, 0, capture.zoom, capture.canvas.left, capture.canvas.top);
        RestoreDC(dc, saved);
      }
    }
    EndPaint(window, &paint); return 0;
  }
  case WM_LBUTTONDOWN: {
    POINT point = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
    if (!PtInRect(&capture.canvas, point)) return 0;
    SetFocus(window); capture.start = capture.end = image_point(point.x, point.y);
    if (capture.tool == TOOL_TEXT) { if (add_text(capture.start)) changed(); return 0; }
    capture.dragging = TRUE; SetCapture(window); return 0;
  }
  case WM_MOUSEMOVE:
    if (capture.dragging) { capture.end = image_point(GET_X_LPARAM(lp), GET_Y_LPARAM(lp)); InvalidateRect(window, &capture.canvas, FALSE); }
    return 0;
  case WM_LBUTTONUP:
    if (capture.dragging) {
      capture.end = image_point(GET_X_LPARAM(lp), GET_Y_LPARAM(lp)); capture.dragging = FALSE;
      ReleaseCapture(); if (add_shape()) changed(); else InvalidateRect(window, &capture.canvas, FALSE);
    }
    return 0;
  case WM_CAPTURECHANGED: capture.dragging = FALSE; InvalidateRect(window, NULL, FALSE); return 0;
  case WM_CLOSE: mc_capture_close(); return 0;
  case WM_NCDESTROY: capture.editor = NULL; return DefWindowProcW(window, message, wp, lp);
  }
  return DefWindowProcW(window, message, wp, lp);
}

static BOOL open_editor(void) {
  MONITORINFO monitor; POINT pointer; HWND editor;
  int width, height;
  capture.session = image_session_create(capture.image.width, capture.image.height);
  if (capture.session <= 0) return FALSE;
  capture.tool = TOOL_RECT; capture.color = PALETTE[0]; capture.stroke = 4; capture.dirty = TRUE;
  GetCursorPos(&pointer); ZeroMemory(&monitor, sizeof(monitor)); monitor.cbSize = sizeof(monitor);
  GetMonitorInfoW(MonitorFromPoint(pointer, MONITOR_DEFAULTTOPRIMARY), &monitor);
  width = minimum(1100, monitor.rcWork.right - monitor.rcWork.left);
  height = minimum(800, monitor.rcWork.bottom - monitor.rcWork.top);
  editor = CreateWindowExW(WS_EX_CONTROLPARENT, EDITOR_CLASS, L"Mooji Cut · 标注后复制",
    WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, monitor.rcWork.left + (monitor.rcWork.right - monitor.rcWork.left - width) / 2,
    monitor.rcWork.top + (monitor.rcWork.bottom - monitor.rcWork.top - height) / 2,
    width, height, capture.owner, NULL, capture.instance, NULL);
  if (!editor) return FALSE;
  ShowWindow(editor, SW_SHOW); UpdateWindow(editor); SetForegroundWindow(editor); SetFocus(editor);
  return TRUE;
}

static LRESULT CALLBACK overlay_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  switch (message) {
  case WM_ERASEBKGND: return 1;
  case WM_PAINT: {
    PAINTSTRUCT paint; HDC dc = BeginPaint(window, &paint);
    RECT rect = selection(capture.start, capture.end); wchar_t label[128];
    BitBlt(dc, 0, 0, capture.desktop.width, capture.desktop.height, capture.dimmed.dc, 0, 0, SRCCOPY);
    if (rect.right > rect.left && rect.bottom > rect.top) {
      HPEN pen = CreatePen(PS_SOLID, 2, RGB(242, 103, 105)); HGDIOBJ prior_pen = SelectObject(dc, pen);
      HGDIOBJ prior_brush = SelectObject(dc, GetStockObject(HOLLOW_BRUSH));
      BitBlt(dc, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, capture.desktop.dc, rect.left, rect.top, SRCCOPY);
      Rectangle(dc, rect.left, rect.top, rect.right, rect.bottom);
      SelectObject(dc, prior_pen); SelectObject(dc, prior_brush); DeleteObject(pen);
      _snwprintf_s(label, ARRAYSIZE(label), _TRUNCATE, L"%d × %d   松开后标注 · Esc 取消", rect.right - rect.left, rect.bottom - rect.top);
    } else wcscpy_s(label, ARRAYSIZE(label), L"拖动框选截图区域 · Esc 取消");
    SetBkColor(dc, RGB(44, 32, 60)); SetTextColor(dc, RGB(250, 245, 234));
    TextOutW(dc, bounded(rect.left, 16, maximum(16, capture.desktop.width - 400)),
      bounded(rect.top - 28, 16, maximum(16, capture.desktop.height - 40)), label, (int)wcslen(label));
    EndPaint(window, &paint); return 0;
  }
  case WM_KEYDOWN: if (wp == VK_ESCAPE) mc_capture_close(); return 0;
  case WM_RBUTTONDOWN: mc_capture_close(); return 0;
  case WM_LBUTTONDOWN:
    capture.start.x = capture.end.x = bounded(GET_X_LPARAM(lp), 0, capture.desktop.width);
    capture.start.y = capture.end.y = bounded(GET_Y_LPARAM(lp), 0, capture.desktop.height);
    capture.dragging = TRUE; SetCapture(window); return 0;
  case WM_MOUSEMOVE:
    if (capture.dragging) {
      capture.end.x = bounded(GET_X_LPARAM(lp), 0, capture.desktop.width);
      capture.end.y = bounded(GET_Y_LPARAM(lp), 0, capture.desktop.height);
      InvalidateRect(window, NULL, FALSE);
    }
    return 0;
  case WM_LBUTTONUP:
    if (capture.dragging) {
      RECT rect;
      capture.end.x = bounded(GET_X_LPARAM(lp), 0, capture.desktop.width);
      capture.end.y = bounded(GET_Y_LPARAM(lp), 0, capture.desktop.height);
      capture.dragging = FALSE; ReleaseCapture(); rect = selection(capture.start, capture.end);
      if (rect.right - rect.left < 2 || rect.bottom - rect.top < 2) return 0;
      if (!surface_new(&capture.image, rect.right - rect.left, rect.bottom - rect.top)) { mc_capture_close(); return 0; }
      BitBlt(capture.image.dc, 0, 0, capture.image.width, capture.image.height, capture.desktop.dc, rect.left, rect.top, SRCCOPY);
      capture.overlay = NULL; /* The focus loss during this handoff is expected. */
      DestroyWindow(window); surface_free(&capture.desktop); surface_free(&capture.dimmed);
      if (!open_editor()) mc_capture_close();
    }
    return 0;
  case WM_CLOSE: mc_capture_close(); return 0;
  case WM_CAPTURECHANGED:
    capture.dragging = FALSE; InvalidateRect(window, NULL, FALSE); return 0;
  case WM_ACTIVATE:
    if (LOWORD(wp) == WA_INACTIVE && capture.overlay == window) mc_capture_close();
    return 0;
  case WM_NCDESTROY: capture.overlay = NULL; return DefWindowProcW(window, message, wp, lp);
  }
  return DefWindowProcW(window, message, wp, lp);
}

static BOOL register_windows(HINSTANCE instance) {
  WNDCLASSEXW klass;
  ZeroMemory(&klass, sizeof(klass)); klass.cbSize = sizeof(klass); klass.hInstance = instance;
  klass.lpfnWndProc = overlay_proc; klass.lpszClassName = OVERLAY_CLASS; klass.hCursor = LoadCursorW(NULL, IDC_CROSS);
  if (!RegisterClassExW(&klass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return FALSE;
  klass.lpfnWndProc = editor_proc; klass.lpszClassName = EDITOR_CLASS; klass.hCursor = LoadCursorW(NULL, IDC_ARROW);
  klass.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(101));
  return RegisterClassExW(&klass) || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

bool mc_capture_start(HINSTANCE instance, HWND owner) {
  HDC desktop; SIZE_T i, bytes; int x, y, width, height;
  if (mc_capture_busy()) { mc_capture_activate(); return true; }
  if (!register_windows(instance)) return false;
  ZeroMemory(&capture, sizeof(capture)); capture.instance = instance; capture.owner = owner;
  x = GetSystemMetrics(SM_XVIRTUALSCREEN); y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  width = GetSystemMetrics(SM_CXVIRTUALSCREEN); height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  SetRect(&capture.desktop_bounds, x, y, x + width, y + height);
  if (!surface_new(&capture.desktop, width, height) || !surface_new(&capture.dimmed, width, height)) { mc_capture_close(); return false; }
  desktop = GetDC(NULL);
  if (!desktop || !BitBlt(capture.desktop.dc, 0, 0, width, height, desktop, x, y, SRCCOPY | CAPTUREBLT)) {
    if (desktop) ReleaseDC(NULL, desktop);
    mc_capture_close(); return false;
  }
  ReleaseDC(NULL, desktop); GdiFlush(); bytes = (SIZE_T)width * height * 4;
  for (i = 0; i < bytes; i += 4) {
    capture.dimmed.pixels[i] = (BYTE)(capture.desktop.pixels[i] * 3 / 5);
    capture.dimmed.pixels[i + 1] = (BYTE)(capture.desktop.pixels[i + 1] * 3 / 5);
    capture.dimmed.pixels[i + 2] = (BYTE)(capture.desktop.pixels[i + 2] * 3 / 5);
    capture.dimmed.pixels[i + 3] = 0;
  }
  capture.overlay = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, OVERLAY_CLASS, L"Mooji Cut · 框选",
    WS_POPUP, x, y, width, height, owner, NULL, instance, NULL);
  if (!capture.overlay) { mc_capture_close(); return false; }
  ShowWindow(capture.overlay, SW_SHOW); UpdateWindow(capture.overlay);
  SetForegroundWindow(capture.overlay); SetFocus(capture.overlay);
  return true;
}

bool mc_capture_busy(void) { return capture.overlay || capture.editor; }
void mc_capture_activate(void) {
  HWND window = capture.editor ? capture.editor : capture.overlay;
  if (window) { ShowWindow(window, SW_RESTORE); SetForegroundWindow(window); SetFocus(window); }
}
void mc_capture_close(void) {
  HWND overlay = capture.overlay, editor = capture.editor;
  capture.overlay = NULL; capture.editor = NULL;
  capture.dragging = FALSE;
  if (GetCapture() == overlay || GetCapture() == editor) ReleaseCapture();
  if (overlay) DestroyWindow(overlay);
  if (editor) DestroyWindow(editor);
  if (capture.session > 0) image_session_dispose(capture.session);
  surface_free(&capture.desktop); surface_free(&capture.dimmed);
  surface_free(&capture.image); surface_free(&capture.rendered);
  if (capture.font) DeleteObject(capture.font);
  ZeroMemory(&capture, sizeof(capture));
}

bool mc_capture_handle_message(MSG *message) {
  HWND focus;
  if (!capture.editor || (message->hwnd != capture.editor && !IsChild(capture.editor, message->hwnd))) return false;
  focus = GetFocus();
  if (message->message == WM_KEYDOWN) {
    BOOL control = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
    if (message->wParam == VK_ESCAPE) { mc_capture_close(); return true; }
    if (control && message->wParam == VK_RETURN) { editor_command(ID_COPY); return true; }
    if (focus != capture.text && control) {
      if (message->wParam == 'Z') { editor_command((GetKeyState(VK_SHIFT) & 0x8000) ? ID_REDO : ID_UNDO); return true; }
      if (message->wParam == 'Y') { editor_command(ID_REDO); return true; }
      if (message->wParam == 'C') { editor_command(ID_COPY); return true; }
    }
  }
  return IsDialogMessageW(capture.editor, message) != FALSE;
}

int mc_capture_smoke(HINSTANCE instance) {
  int result = 1, x, y; HGLOBAL dib = NULL; BITMAPINFOHEADER *header; SIZE_T stride; DWORD clipboard_sequence;
  wchar_t permit[16] = {0}, ci[16] = {0};
  DWORD permit_length = GetEnvironmentVariableW(L"MOOJICUT_ALLOW_CLIPBOARD_TEST", permit, ARRAYSIZE(permit));
  DWORD ci_length = GetEnvironmentVariableW(L"CI", ci, ARRAYSIZE(ci));
  BOOL allow_clipboard = permit_length == 1 && wcscmp(permit, L"1") == 0;
  BOOL continuous_integration = ci_length == 4 && _wcsicmp(ci, L"true") == 0;
  if (!allow_clipboard && !continuous_integration) {
    fprintf(stderr, "Screenshot clipboard smoke requires CI=true or MOOJICUT_ALLOW_CLIPBOARD_TEST=1. It replaces the clipboard with a synthetic test image.\n");
    return 1;
  }
  if (mc_capture_busy()) return 1;
  ZeroMemory(&capture, sizeof(capture)); capture.instance = instance; capture.smoke = TRUE;
  if (!register_windows(instance) || !surface_new(&capture.image, 320, 200)) goto cleanup;
  for (y = 0; y < 200; y++) for (x = 0; x < 320; x++) {
    BYTE *pixel = capture.image.pixels + ((SIZE_T)y * 320 + x) * 4;
    pixel[0] = 80; pixel[1] = 160; pixel[2] = 220; pixel[3] = 0;
  }
  if (!open_editor()) goto cleanup;
  if (image_session_add(capture.session, TOOL_REDACT, 30, 40, 80, 60, 0, 4) != 1) goto cleanup;
  if (image_session_add(capture.session, TOOL_RECT, 20, 30, 120, 100, 0xF26769, 4) != 1) goto cleanup;
  if (image_session_add(capture.session, TOOL_ARROW, 240, 160, -100, -70, 0x246BFD, 4) != 1) goto cleanup;
  SetWindowTextW(capture.text, L"截图测试 MoonBit ✅");
  if (!add_text((POINT){ 40, 50 })) goto cleanup;
  if (image_session_count(capture.session) != 4 || image_session_undo(capture.session) != 1 || image_session_count(capture.session) != 3) goto cleanup;
  if (image_session_redo(capture.session) != 1 || image_session_count(capture.session) != 4) goto cleanup;
  changed(); UpdateWindow(capture.editor);
  dib = image_dib(); if (!dib) goto cleanup;
  header = (BITMAPINFOHEADER *)GlobalLock(dib); if (!header) goto cleanup;
  stride = ((SIZE_T)320 * 3 + 3) & ~(SIZE_T)3;
  if (header->biWidth != 320 || header->biHeight != 200 || header->biBitCount != 24) { GlobalUnlock(dib); goto cleanup; }
  {
    const BYTE *mask = (const BYTE *)(header + 1) + 149 * stride + 50 * 3;
    const BYTE *source = (const BYTE *)(header + 1) + 194 * stride + 5 * 3;
    if (mask[0] || mask[1] || mask[2] || source[0] != 80 || source[1] != 160 || source[2] != 220) { GlobalUnlock(dib); goto cleanup; }
  }
  GlobalUnlock(dib);
  if (!copy_image() || !IsClipboardFormatAvailable(CF_DIB)) goto cleanup;
  clipboard_sequence = GetClipboardSequenceNumber();
  mc_capture_close();
  /* Exercise the real frozen-desktop selection path in both drag directions. */
  if (!mc_capture_start(instance, NULL)) goto cleanup;
  if (capture.desktop.width < 320 || capture.desktop.height < 220) goto cleanup;
  SendMessageW(capture.overlay, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(300, 200));
  SendMessageW(capture.overlay, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(10, 20));
  SendMessageW(capture.overlay, WM_LBUTTONUP, 0, MAKELPARAM(10, 20));
  if (!capture.editor || capture.image.width != 290 || capture.image.height != 180) goto cleanup;
  mc_capture_close();
  if (GetClipboardSequenceNumber() != clipboard_sequence) goto cleanup;
  if (!mc_capture_start(instance, NULL)) goto cleanup;
  SendMessageW(capture.overlay, WM_KEYDOWN, VK_ESCAPE, 0);
  if (mc_capture_busy() || GetClipboardSequenceNumber() != clipboard_sequence) goto cleanup;
  result = 0;
cleanup:
  if (dib) GlobalFree(dib);
  mc_capture_close();
  printf("Windows screenshot smoke: %s (MoonBit annotations, undo/redo, original-resolution DIB, final privacy masks, clipboard).\n", result ? "FAILED" : "passed");
  return result;
}
