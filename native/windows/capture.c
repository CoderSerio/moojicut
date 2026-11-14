#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include "capture.h"
#include "../shared/image_session.h"
#include "../shared/mc_icons.h"
#include "moonbit.h"
#include "pinning.h"
#include <commctrl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <windowsx.h>

enum { TOOL_SELECT = 0, TOOL_RECT, TOOL_ARROW, TOOL_TEXT, TOOL_REDACT };
enum {
  ID_SELECT = 8100,
  ID_RECT,
  ID_ARROW,
  ID_TEXT,
  ID_REDACT,
  ID_UNDO,
  ID_REDO,
  ID_COPY,
  ID_CANCEL,
  ID_TEXT_INPUT,
  ID_COLOR,
  ID_STROKE,
  ID_PIN,
  ID_FONT
};
typedef struct {
  HDC dc;
  HBITMAP bitmap;
  HGDIOBJ previous;
  BYTE *pixels;
  int width, height;
} Surface;
typedef struct {
  HINSTANCE instance;
  HWND owner, overlay, editor, text, colors, strokes, fonts, tooltip, buttons[10];
  HFONT font, text_font;
  Surface desktop, dimmed, image, rendered;
  RECT desktop_bounds, canvas, viewport, toolbar, drag_bounds, draft;
  POINT start, end;
  double zoom;
  int32_t session;
  int tool, color, stroke, font_size, selected, editing, drag_mode, handle;
  BOOL dragging, dirty, smoke, closing, composing;
} Capture;
static Capture capture;
static const wchar_t *OVERLAY_CLASS = L"MoojiCut.Capture.Selection";
static const wchar_t *EDITOR_CLASS = L"MoojiCut.Capture.Editor";
static const int PALETTE[] = {0xF26769, 0x246BFD, 0x25A56A, 0xFFFFFF, 0x111111};

static int minimum(int a, int b) { return a < b ? a : b; }
static int maximum(int a, int b) { return a > b ? a : b; }
static int bounded(int value, int low, int high) { return maximum(low, minimum(value, high)); }
static int rounded(double value) { return (int)floor(value + 0.5); }
static COLORREF color_ref(int rgb) { return RGB((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }
static int dpi_px(HWND window, int value) { return MulDiv(value, (int)GetDpiForWindow(window), 96); }

static void surface_free(Surface *surface) {
  if (surface->previous && surface->dc)
    SelectObject(surface->dc, surface->previous);
  if (surface->bitmap)
    DeleteObject(surface->bitmap);
  if (surface->dc)
    DeleteDC(surface->dc);
  ZeroMemory(surface, sizeof(*surface));
}

static BOOL surface_new(Surface *surface, int width, int height) {
  BITMAPINFO info;
  if (width <= 0 || height <= 0 || (uint64_t)width * (uint64_t)height > 64000000)
    return FALSE;
  ZeroMemory(&info, sizeof(info));
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  surface->dc = CreateCompatibleDC(NULL);
  if (!surface->dc)
    return FALSE;
  surface->bitmap = CreateDIBSection(surface->dc, &info, DIB_RGB_COLORS, (void **)&surface->pixels, NULL, 0);
  if (!surface->bitmap) {
    surface_free(surface);
    return FALSE;
  }
  surface->previous = SelectObject(surface->dc, surface->bitmap);
  surface->width = width;
  surface->height = height;
  return TRUE;
}

static RECT selection(POINT a, POINT b) {
  RECT rect = {minimum(a.x, b.x), minimum(a.y, b.y), maximum(a.x, b.x), maximum(a.y, b.y)};
  return rect;
}

static void draw_annotation(HDC dc, int kind, double x, double y, double width, double height, int color,
                            double stroke, const wchar_t *text, int text_length, double font_size,
                            double scale, int offset_x, int offset_y) {
  int left = offset_x + rounded(x * scale), top = offset_y + rounded(y * scale);
  int right = offset_x + rounded((x + width) * scale), bottom = offset_y + rounded((y + height) * scale);
  int thickness = maximum(1, rounded(stroke * scale));
  HPEN pen = CreatePen(PS_SOLID, thickness, color_ref(color));
  HGDIOBJ prior_pen = SelectObject(dc, pen), prior_brush = SelectObject(dc, GetStockObject(HOLLOW_BRUSH));
  if (kind == TOOL_RECT)
    Rectangle(dc, left, top, right, bottom);
  else if (kind == TOOL_ARROW) {
    double dx = (double)right - left, dy = (double)bottom - top, length = sqrt(dx * dx + dy * dy);
    if (length > 0.5) {
      double head = minimum(rounded(length * 0.45), maximum(8, rounded(14 * scale + thickness)));
      POINT wings[3];
      wings[0].x = rounded(right - head * dx / length + head * 0.45 * dy / length);
      wings[0].y = rounded(bottom - head * dy / length - head * 0.45 * dx / length);
      wings[1].x = right;
      wings[1].y = bottom;
      wings[2].x = rounded(right - head * dx / length - head * 0.45 * dy / length);
      wings[2].y = rounded(bottom - head * dy / length + head * 0.45 * dx / length);
      MoveToEx(dc, left, top, NULL);
      LineTo(dc, right, bottom);
      Polyline(dc, wings, 3);
    }
  } else if (kind == TOOL_REDACT) {
    RECT rect = {left, top, right, bottom};
    FillRect(dc, &rect, (HBRUSH)GetStockObject(BLACK_BRUSH));
  } else if (kind == TOOL_TEXT && text && text_length > 0) {
    HFONT font = CreateFontW(-maximum(1, rounded(font_size * scale)), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE,
                             FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                             ANTIALIASED_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    HGDIOBJ previous_font = SelectObject(dc, font);
    SetTextColor(dc, color_ref(color));
    SetBkMode(dc, TRANSPARENT);
    RECT box = {left, top, right, bottom};
    DrawTextW(dc, text, text_length, &box, DT_LEFT | DT_TOP | DT_WORDBREAK | DT_NOPREFIX);
    SelectObject(dc, previous_font);
    DeleteObject(font);
  }
  SelectObject(dc, prior_brush);
  SelectObject(dc, prior_pen);
  DeleteObject(pen);
}

static BOOL render_image(void) {
  int pass, i, count;
  if (!capture.session || !capture.image.dc)
    return FALSE;
  if (!capture.rendered.dc && !surface_new(&capture.rendered, capture.image.width, capture.image.height))
    return FALSE;
  if (!capture.dirty)
    return TRUE;
  BitBlt(capture.rendered.dc, 0, 0, capture.image.width, capture.image.height, capture.image.dc, 0, 0,
         SRCCOPY);
  count = image_session_count(capture.session);
  /* Privacy masks always render last, including after later annotations. */
  for (pass = 0; pass < 2; pass++)
    for (i = 0; i < count; i++) {
      int kind = (int)image_session_value(capture.session, i, 0);
      moonbit_string_t text = NULL;
      if ((kind == TOOL_REDACT) != (pass == 1))
        continue;
      if (i == capture.editing)
        continue;
      if (kind == TOOL_TEXT)
        text = image_session_text(capture.session, i);
      BOOL moving = capture.dragging && capture.drag_mode == 1 && capture.selected == i;
      RECT draft = capture.draft;
      double font_size = image_session_value(capture.session, i, 7);
      if (moving &&
          (capture.handle == 0 || capture.handle == 2 || capture.handle == 4 || capture.handle == 6))
        font_size = bounded(rounded(font_size * (draft.right - draft.left) /
                                    maximum(1, capture.drag_bounds.right - capture.drag_bounds.left)),
                            8, 128);
      draw_annotation(
          capture.rendered.dc, kind, moving ? draft.left : image_session_value(capture.session, i, 1),
          moving ? draft.top : image_session_value(capture.session, i, 2),
          moving ? draft.right - draft.left : image_session_value(capture.session, i, 3),
          moving ? draft.bottom - draft.top : image_session_value(capture.session, i, 4),
          (int)image_session_value(capture.session, i, 5), image_session_value(capture.session, i, 6),
          (const wchar_t *)text, text ? Moonbit_array_length(text) : 0, font_size, 1, 0, 0);
      if (text)
        moonbit_decref(text);
    }
  GdiFlush();
  capture.dirty = FALSE;
  return TRUE;
}

static HGLOBAL image_dib(void) {
  SIZE_T stride, bytes;
  HGLOBAL memory;
  BITMAPINFOHEADER *header;
  BYTE *out;
  int x, y;
  if (!render_image())
    return NULL;
  int width = capture.viewport.right - capture.viewport.left,
      height = capture.viewport.bottom - capture.viewport.top;
  stride = ((SIZE_T)width * 3 + 3) & ~(SIZE_T)3;
  bytes = stride * (SIZE_T)height;
  memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(*header) + bytes);
  if (!memory)
    return NULL;
  header = (BITMAPINFOHEADER *)GlobalLock(memory);
  if (!header) {
    GlobalFree(memory);
    return NULL;
  }
  header->biSize = sizeof(*header);
  header->biWidth = width;
  header->biHeight = height;
  header->biPlanes = 1;
  header->biBitCount = 24;
  header->biCompression = BI_RGB;
  header->biSizeImage = (DWORD)bytes;
  out = (BYTE *)(header + 1);
  for (y = 0; y < height; y++) {
    const BYTE *source =
        capture.rendered.pixels +
        ((SIZE_T)(y + capture.viewport.top) * capture.image.width + capture.viewport.left) * 4;
    BYTE *row = out + (SIZE_T)(height - 1 - y) * stride;
    for (x = 0; x < width; x++)
      memcpy(row + (SIZE_T)x * 3, source + (SIZE_T)x * 4, 3);
  }
  GlobalUnlock(memory);
  return memory;
}

static BOOL copy_image(void) {
  HGLOBAL dib = image_dib();
  BOOL success = FALSE;
  if (!dib)
    return FALSE;
  if (OpenClipboard(capture.editor)) {
    if (EmptyClipboard() && SetClipboardData(CF_DIB, dib)) {
      dib = NULL;
      success = TRUE;
    }
    CloseClipboard();
  }
  if (dib)
    GlobalFree(dib);
  return success;
}

static void changed(void) {
  capture.dirty = TRUE;
  if (capture.editor)
    InvalidateRect(capture.editor, NULL, FALSE);
}
static RECT annotation_rect(int i) {
  RECT r;
  r.left = rounded(image_session_value(capture.session, i, 1));
  r.top = rounded(image_session_value(capture.session, i, 2));
  r.right = r.left + rounded(image_session_value(capture.session, i, 3));
  r.bottom = r.top + rounded(image_session_value(capture.session, i, 4));
  return r;
}
static void sync_viewport(void) {
  capture.viewport.left = rounded(image_session_viewport_value(capture.session, 0));
  capture.viewport.top = rounded(image_session_viewport_value(capture.session, 1));
  capture.viewport.right = capture.viewport.left + rounded(image_session_viewport_value(capture.session, 2));
  capture.viewport.bottom = capture.viewport.top + rounded(image_session_viewport_value(capture.session, 3));
}
static void set_session_text(const wchar_t *text, int length) {
  moonbit_string_t value = moonbit_make_string_raw(length);
  memcpy(value, text, (SIZE_T)length * 2);
  image_session_set_text(capture.session, value);
  moonbit_decref(value);
}
static void preserve_text(int index) {
  moonbit_string_t value = image_session_text(capture.session, index);
  image_session_set_text(capture.session, value);
  moonbit_decref(value);
}
static void layout_editor(HWND window) {
  RECT client;
  GetClientRect(window, &client);
  int gap = dpi_px(window, 6), size = dpi_px(window, 30), width = size * 10 + gap * 11,
      height = size * 2 + gap * 3;
  int x = bounded(capture.viewport.left, 0, maximum(0, client.right - width)),
      y = capture.viewport.bottom + gap;
  if (y + height > client.bottom)
    y = capture.viewport.top - height - gap;
  y = bounded(y, 0, maximum(0, client.bottom - height));
  SetRect(&capture.toolbar, x, y, x + width, y + height);
  for (int i = 0; i < 10; i++)
    MoveWindow(capture.buttons[i], x + gap + i * (size + gap), y + gap, size, size, TRUE);
  MoveWindow(capture.colors, x + gap, y + size + gap * 2, dpi_px(window, 100), size * 6, TRUE);
  MoveWindow(capture.strokes, x + gap * 2 + dpi_px(window, 100), y + size + gap * 2, dpi_px(window, 90),
             size * 5, TRUE);
  MoveWindow(capture.fonts, x + gap * 3 + dpi_px(window, 190), y + size + gap * 2, dpi_px(window, 90),
             size * 8, TRUE);
  capture.canvas = capture.viewport;
  capture.zoom = 1;
  InvalidateRect(window, NULL, FALSE);
}
/* Use the export font and wrapping rules for all live/committed text geometry.
 * Grow height on style/reflow so increasing the font cannot silently hide a line. */
static RECT fit_text_bounds(RECT bounds, int size, const wchar_t *text, int length) {
  HDC dc = CreateCompatibleDC(NULL);
  HFONT font =
      CreateFontW(-size, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                  CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  HGDIOBJ old = SelectObject(dc, font);
  TEXTMETRICW metrics;
  GetTextMetricsW(dc, &metrics);
  RECT measured = {0, 0, maximum(1, bounds.right - bounds.left), 0};
  DrawTextW(dc, text, length, &measured, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
  int height = maximum(metrics.tmHeight, measured.bottom);
  bounds.bottom = minimum(capture.image.height, maximum(bounds.bottom, bounds.top + height + 2));
  SelectObject(dc, old);
  DeleteObject(font);
  DeleteDC(dc);
  return bounds;
}
static RECT fit_annotation_bounds(int index, RECT bounds, int size) {
  moonbit_string_t value = image_session_text(capture.session, index);
  bounds = fit_text_bounds(bounds, size, (const wchar_t *)value, Moonbit_array_length(value));
  moonbit_decref(value);
  return bounds;
}
static LRESULT CALLBACK text_proc(HWND window, UINT message, WPARAM wp, LPARAM lp, UINT_PTR id,
                                  DWORD_PTR data) {
  (void)id;
  (void)data;
  if (message == WM_IME_STARTCOMPOSITION)
    capture.composing = TRUE;
  if (message == WM_IME_ENDCOMPOSITION) {
    LRESULT result = DefSubclassProc(window, message, wp, lp);
    capture.composing = FALSE;
    return result;
  }
  if (message == WM_NCDESTROY) {
    capture.composing = FALSE;
    RemoveWindowSubclass(window, text_proc, 1);
  }
  return DefSubclassProc(window, message, wp, lp);
}
static void style_text(void) {
  int length = GetWindowTextLengthW(capture.text);
  wchar_t *content = calloc((size_t)length + 1, sizeof(wchar_t));
  if (content) {
    GetWindowTextW(capture.text, content, length + 1);
    capture.draft = fit_text_bounds(capture.draft, capture.font_size, content, length);
    free(content);
  }
  HFONT old = capture.text_font;
  capture.text_font =
      CreateFontW(-capture.font_size, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                  OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  SendMessageW(capture.text, WM_SETFONT, (WPARAM)capture.text_font, TRUE);
  if (old)
    DeleteObject(old);
  RECT r = capture.draft;
  MoveWindow(capture.text, r.left, r.top, maximum(2, r.right - r.left), maximum(2, r.bottom - r.top), TRUE);
  HRGN region = CreateRectRgn(0, 0, r.right - r.left, r.bottom - r.top),
       clip = CreateRectRgn(capture.viewport.left - r.left, capture.viewport.top - r.top,
                            capture.viewport.right - r.left, capture.viewport.bottom - r.top);
  CombineRgn(region, region, clip, RGN_AND);
  DeleteObject(clip);
  for (int i = 0; i < image_session_count(capture.session); i++)
    if ((int)image_session_value(capture.session, i, 0) == TOOL_REDACT) {
      RECT mask = annotation_rect(i);
      clip = CreateRectRgn(mask.left - r.left, mask.top - r.top, mask.right - r.left, mask.bottom - r.top);
      CombineRgn(region, region, clip, RGN_DIFF);
      DeleteObject(clip);
    }
  SetWindowRgn(capture.text, region, TRUE);
}
static BOOL finish_text(BOOL cancel) {
  if (capture.composing)
    return FALSE;
  if (capture.editing == -2)
    return TRUE;
  int index = capture.editing;
  capture.editing = -2;
  BOOL ok = TRUE;
  int length = GetWindowTextLengthW(capture.text);
  if (!cancel && length) {
    wchar_t *text = calloc((size_t)length + 1, sizeof(wchar_t));
    if (!text) {
      capture.editing = index;
      return FALSE;
    }
    GetWindowTextW(capture.text, text, length + 1);
    set_session_text(text, length);
    RECT r = fit_text_bounds(capture.draft, capture.font_size, text, length);
    free(text);
    ok =
        (index < 0
             ? image_session_add_styled(capture.session, TOOL_TEXT, r.left, r.top, r.right - r.left,
                                        r.bottom - r.top, capture.color, capture.stroke, capture.font_size)
             : image_session_update(capture.session, index, r.left, r.top, r.right - r.left, r.bottom - r.top,
                                    capture.color, capture.stroke, capture.font_size)) == 1;
    if (ok)
      capture.selected = index < 0 ? image_session_count(capture.session) - 1 : index;
  }
  if (!cancel && !length && index >= 0) {
    ok = image_session_remove(capture.session, index) == 1;
    if (ok)
      capture.selected = -1;
  }
  if (!ok) {
    capture.editing = index;
    return FALSE;
  }
  ShowWindow(capture.text, SW_HIDE);
  changed();
  return TRUE;
}
static void sync_style_controls(void) {
  for (int i = 0; i < 5; i++)
    if (PALETTE[i] == capture.color)
      SendMessageW(capture.colors, CB_SETCURSEL, i, 0);
  SendMessageW(capture.strokes, CB_SETCURSEL, capture.stroke == 2 ? 0 : capture.stroke == 8 ? 2 : 1, 0);
  int count = (int)SendMessageW(capture.fonts, CB_GETCOUNT, 0, 0), found = -1;
  for (int i = 0; i < count; i++)
    if ((int)SendMessageW(capture.fonts, CB_GETITEMDATA, i, 0) == capture.font_size)
      found = i;
  if (found < 0) {
    wchar_t label[32];
    swprintf_s(label, 32, L"文字 %d", capture.font_size);
    found = (int)SendMessageW(capture.fonts, CB_ADDSTRING, 0, (LPARAM)label);
    SendMessageW(capture.fonts, CB_SETITEMDATA, found, capture.font_size);
  }
  SendMessageW(capture.fonts, CB_SETCURSEL, found, 0);
}
static void begin_text(POINT point, int index) {
  if (!finish_text(FALSE))
    return;
  capture.editing = index;
  capture.selected = index;
  if (index >= 0) {
    capture.draft = annotation_rect(index);
    capture.font_size = (int)image_session_value(capture.session, index, 7);
    capture.stroke = (int)image_session_value(capture.session, index, 6);
    capture.color = (int)image_session_value(capture.session, index, 5);
    moonbit_string_t value = image_session_text(capture.session, index);
    int n = Moonbit_array_length(value);
    wchar_t *text = calloc((size_t)n + 1, 2);
    if (text) {
      memcpy(text, value, (size_t)n * 2);
      SetWindowTextW(capture.text, text);
      free(text);
    }
    moonbit_decref(value);
  } else {
    SetRect(&capture.draft, point.x, point.y, minimum(capture.viewport.right, point.x + 280),
            minimum(capture.viewport.bottom, point.y + capture.font_size * 3));
    SetWindowTextW(capture.text, L"");
  }
  sync_style_controls();
  style_text();
  ShowWindow(capture.text, SW_SHOW);
  SetFocus(capture.text);
  SendMessageW(capture.text, EM_SETSEL, 0, -1);
  changed();
}
static int hit_text(POINT p) {
  for (int i = image_session_count(capture.session) - 1; i >= 0; i--)
    if ((int)image_session_value(capture.session, i, 0) == TOOL_TEXT) {
      RECT r = annotation_rect(i);
      if (PtInRect(&r, p))
        return i;
    }
  return -1;
}
static int hit_handle(RECT r, POINT p) {
  POINT points[8] = {{r.left, r.top},     {(r.left + r.right) / 2, r.top},
                     {r.right, r.top},    {r.right, (r.top + r.bottom) / 2},
                     {r.right, r.bottom}, {(r.left + r.right) / 2, r.bottom},
                     {r.left, r.bottom},  {r.left, (r.top + r.bottom) / 2}};
  for (int i = 0; i < 8; i++)
    if (abs(p.x - points[i].x) <= 7 && abs(p.y - points[i].y) <= 7)
      return i;
  return -1;
}
static RECT drag_rect(RECT r, POINT from, POINT to, int handle) {
  int dx = to.x - from.x, dy = to.y - from.y;
  if (handle < 0) {
    int w = r.right - r.left, h = r.bottom - r.top;
    r.left = bounded(r.left + dx, 0, capture.image.width - w);
    r.top = bounded(r.top + dy, 0, capture.image.height - h);
    r.right = r.left + w;
    r.bottom = r.top + h;
    return r;
  }
  if (handle == 0 || handle == 6 || handle == 7)
    r.left = bounded(r.left + dx, 0, r.right - 8);
  if (handle == 2 || handle == 3 || handle == 4)
    r.right = bounded(r.right + dx, r.left + 8, capture.image.width);
  if (handle == 0 || handle == 1 || handle == 2)
    r.top = bounded(r.top + dy, 0, r.bottom - 8);
  if (handle == 4 || handle == 5 || handle == 6)
    r.bottom = bounded(r.bottom + dy, r.top + 8, capture.image.height);
  return r;
}
static void frame(HDC dc, RECT r, BOOL handles) {
  HPEN pen = CreatePen(PS_SOLID, 3, RGB(44, 36, 54));
  HGDIOBJ prior = SelectObject(dc, pen), brush = SelectObject(dc, GetStockObject(HOLLOW_BRUSH));
  Rectangle(dc, r.left, r.top, r.right, r.bottom);
  SelectObject(dc, prior);
  DeleteObject(pen);
  pen = CreatePen(PS_SOLID, 1, RGB(194, 191, 186));
  SelectObject(dc, pen);
  Rectangle(dc, r.left, r.top, r.right, r.bottom);
  if (handles) {
    HBRUSH fill = CreateSolidBrush(RGB(250, 245, 234));
    SelectObject(dc, fill);
    POINT points[8] = {{r.left, r.top},     {(r.left + r.right) / 2, r.top},
                       {r.right, r.top},    {r.right, (r.top + r.bottom) / 2},
                       {r.right, r.bottom}, {(r.left + r.right) / 2, r.bottom},
                       {r.left, r.bottom},  {r.left, (r.top + r.bottom) / 2}};
    for (int i = 0; i < 8; i++)
      Rectangle(dc, points[i].x - 3, points[i].y - 3, points[i].x + 4, points[i].y + 4);
    SelectObject(dc, brush);
    DeleteObject(fill);
  }
  SelectObject(dc, brush);
  SelectObject(dc, prior);
  DeleteObject(pen);
}
static void region_label(HDC dc, RECT rect) {
  wchar_t label[64];
  swprintf_s(label, 64, L" %ld × %ld px ", rect.right - rect.left, rect.bottom - rect.top);
  HGDIOBJ old = SelectObject(dc, capture.font ? capture.font : GetStockObject(DEFAULT_GUI_FONT));
  SetBkColor(dc, RGB(43, 36, 54));
  SetTextColor(dc, RGB(250, 245, 235));
  SetBkMode(dc, OPAQUE);
  TextOutW(dc, maximum(0, rect.left), maximum(0, rect.top - 24), label, (int)wcslen(label));
  SelectObject(dc, old);
}
static const int button_ids[10] = {ID_SELECT, ID_RECT, ID_ARROW, ID_TEXT,   ID_REDACT,
                                   ID_UNDO,   ID_REDO, ID_PIN,   ID_CANCEL, ID_COPY};
static const MCIcon button_icons[10] = {MC_ICON_SELECT, MC_ICON_RECTANGLE, MC_ICON_ARROW, MC_ICON_TEXT,
                                        MC_ICON_REDACT, MC_ICON_UNDO,      MC_ICON_REDO,  MC_ICON_PIN,
                                        MC_ICON_CLOSE,  MC_ICON_CHECK};
static void draw_icon(HDC dc, RECT bounds, MCIcon icon, BOOL selected) {
  HBRUSH fill = CreateSolidBrush(selected ? RGB(104, 99, 109) : RGB(43, 41, 48));
  FillRect(dc, &bounds, fill);
  DeleteObject(fill);
  double scale = (bounds.right - bounds.left) * .65 / 24;
  int x = (bounds.left + bounds.right - rounded(24 * scale)) / 2,
      y = (bounds.top + bounds.bottom - rounded(24 * scale)) / 2;
  LOGBRUSH lb = {BS_SOLID, RGB(247, 243, 234), 0};
  HPEN pen = ExtCreatePen(PS_GEOMETRIC | PS_SOLID | PS_ENDCAP_ROUND | PS_JOIN_ROUND,
                          (DWORD)maximum(1, rounded(2 * scale)), &lb, 0, NULL);
  HGDIOBJ previous = SelectObject(dc, pen);
  MCIconPath path = mc_icon_path(icon);
  BeginPath(dc);
  for (unsigned i = 0; i < path.count; i++) {
    const MCIconCommand *c = &path.commands[i];
    if (c->op == 'M')
      MoveToEx(dc, x + rounded(c->x1 * scale), y + rounded(c->y1 * scale), NULL);
    else if (c->op == 'L')
      LineTo(dc, x + rounded(c->x1 * scale), y + rounded(c->y1 * scale));
    else if (c->op == 'C') {
      POINT p[3] = {{x + rounded(c->x1 * scale), y + rounded(c->y1 * scale)},
                    {x + rounded(c->x2 * scale), y + rounded(c->y2 * scale)},
                    {x + rounded(c->x3 * scale), y + rounded(c->y3 * scale)}};
      PolyBezierTo(dc, p, 3);
    } else if (c->op == 'Z')
      CloseFigure(dc);
  }
  EndPath(dc);
  StrokePath(dc);
  SelectObject(dc, previous);
  DeleteObject(pen);
}
static BOOL add_shape(void) {
  RECT b = selection(capture.start, capture.end);
  if (capture.tool == TOOL_ARROW)
    return abs(capture.end.x - capture.start.x) + abs(capture.end.y - capture.start.y) >= 3 &&
           image_session_add(capture.session, capture.tool, capture.start.x, capture.start.y,
                             capture.end.x - capture.start.x, capture.end.y - capture.start.y, capture.color,
                             capture.stroke) == 1;
  if (b.right - b.left < 2 || b.bottom - b.top < 2)
    return FALSE;
  return image_session_add(capture.session, capture.tool, b.left, b.top, b.right - b.left, b.bottom - b.top,
                           capture.tool == TOOL_REDACT ? 0 : capture.color, capture.stroke) == 1;
}
static void editor_command(int command) {
  if (!finish_text(FALSE))
    return;
  if (command >= ID_SELECT && command <= ID_REDACT) {
    capture.tool = command - ID_SELECT;
    capture.selected = -1;
    changed();
    for (int i = 0; i < 5; i++)
      InvalidateRect(capture.buttons[i], NULL, FALSE);
    SetFocus(capture.editor);
  } else if (command == ID_UNDO || command == ID_REDO) {
    if (command == ID_UNDO)
      image_session_undo(capture.session);
    else
      image_session_redo(capture.session);
    capture.selected = -1;
    sync_viewport();
    layout_editor(capture.editor);
    changed();
  } else if (command == ID_CANCEL)
    mc_capture_close();
  else if (command == ID_COPY) {
    if (copy_image())
      mc_capture_close();
    else if (!capture.smoke)
      MessageBoxW(capture.editor, L"剪贴板暂时被占用，请重试。", L"Mooji Cut", MB_OK | MB_ICONWARNING);
  } else if (command == ID_PIN) {
    HGLOBAL dib = image_dib();
    if (dib) {
      int x = capture.desktop_bounds.left + capture.viewport.left,
          y = capture.desktop_bounds.top + capture.viewport.top;
      HINSTANCE instance = capture.instance;
      if (mc_pin_image(instance, dib, x, y, TRUE)) {
        mc_capture_close();
        mc_pins_hide(FALSE);
      } else
        GlobalFree(dib);
    }
  }
}
static void apply_style(void) {
  if (capture.editing != -2) {
    style_text();
    return;
  }
  if (capture.selected >= 0) {
    RECT r = fit_annotation_bounds(capture.selected, annotation_rect(capture.selected), capture.font_size);
    preserve_text(capture.selected);
    image_session_update(capture.session, capture.selected, r.left, r.top, r.right - r.left, r.bottom - r.top,
                         capture.color, capture.stroke, capture.font_size);
    changed();
  }
}
static LRESULT CALLBACK editor_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  switch (message) {
  case WM_CREATE: {
    capture.editor = window;
    capture.font =
        CreateFontW(-dpi_px(window, 14), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                    OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    const wchar_t *labels[10] = {
        L"选择",        L"矩形",        L"箭头", L"文字",     L"遮挡",
        L"撤销 Ctrl+Z", L"重做 Ctrl+Y", L"贴图", L"取消 Esc", L"确认并复制 Ctrl+Enter"};
    capture.tooltip =
        CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, NULL, WS_POPUP | TTS_ALWAYSTIP, CW_USEDEFAULT,
                        CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, window, NULL, capture.instance, NULL);
    for (int i = 0; i < 10; i++) {
      capture.buttons[i] =
          CreateWindowW(L"BUTTON", labels[i], WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW, 0, 0, 1, 1,
                        window, (HMENU)(INT_PTR)button_ids[i], capture.instance, NULL);
      TOOLINFOW ti = {sizeof(ti)};
      ti.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
      ti.hwnd = window;
      ti.uId = (UINT_PTR)capture.buttons[i];
      ti.lpszText = (LPWSTR)labels[i];
      SendMessageW(capture.tooltip, TTM_ADDTOOLW, 0, (LPARAM)&ti);
    }
    capture.colors =
        CreateWindowW(L"COMBOBOX", L"文字颜色", WS_CHILD | WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST, 0, 0,
                      1, 1, window, (HMENU)ID_COLOR, capture.instance, NULL);
    const wchar_t *colors[5] = {L"珊瑚红", L"蓝色", L"绿色", L"白色", L"黑色"};
    for (int i = 0; i < 5; i++)
      SendMessageW(capture.colors, CB_ADDSTRING, 0, (LPARAM)colors[i]);
    SendMessageW(capture.colors, CB_SETCURSEL, 0, 0);
    capture.strokes =
        CreateWindowW(L"COMBOBOX", L"线条宽度", WS_CHILD | WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST, 0, 0,
                      1, 1, window, (HMENU)ID_STROKE, capture.instance, NULL);
    const wchar_t *strokes[3] = {L"细线 2", L"中线 4", L"粗线 8"};
    for (int i = 0; i < 3; i++)
      SendMessageW(capture.strokes, CB_ADDSTRING, 0, (LPARAM)strokes[i]);
    SendMessageW(capture.strokes, CB_SETCURSEL, 1, 0);
    capture.fonts =
        CreateWindowW(L"COMBOBOX", L"文字大小", WS_CHILD | WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST, 0, 0,
                      1, 1, window, (HMENU)ID_FONT, capture.instance, NULL);
    const int sizes[8] = {8, 12, 16, 24, 32, 48, 72, 128};
    for (int i = 0; i < 8; i++) {
      wchar_t label[30];
      swprintf_s(label, 30, L"文字 %d", sizes[i]);
      SendMessageW(capture.fonts, CB_ADDSTRING, 0, (LPARAM)label);
      SendMessageW(capture.fonts, CB_SETITEMDATA, i, sizes[i]);
    }
    SendMessageW(capture.fonts, CB_SETCURSEL, 3, 0);
    capture.text = CreateWindowExW(0, L"EDIT", L"",
                                   WS_CHILD | WS_TABSTOP | ES_MULTILINE | ES_WANTRETURN | ES_AUTOVSCROLL, 0,
                                   0, 1, 1, window, (HMENU)ID_TEXT_INPUT, capture.instance, NULL);
    SetWindowSubclass(capture.text, text_proc, 1, 0);
    SendMessageW(capture.text, EM_SETLIMITTEXT, 10000, 0);
    SendMessageW(capture.text, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, 0);
    SendMessageW(capture.colors, WM_SETFONT, (WPARAM)capture.font, TRUE);
    SendMessageW(capture.strokes, WM_SETFONT, (WPARAM)capture.font, TRUE);
    SendMessageW(capture.fonts, WM_SETFONT, (WPARAM)capture.font, TRUE);
    layout_editor(window);
    return 0;
  }
  case WM_SIZE:
    if (capture.session)
      layout_editor(window);
    return 0;
  case WM_DISPLAYCHANGE:
    mc_capture_close();
    return 0;
  case WM_DRAWITEM: {
    DRAWITEMSTRUCT *item = (DRAWITEMSTRUCT *)lp;
    for (int i = 0; i < 10; i++)
      if (item->CtlID == (UINT)button_ids[i]) {
        draw_icon(item->hDC, item->rcItem, button_icons[i], i < 5 && capture.tool == i);
        if (item->itemState & ODS_FOCUS)
          DrawFocusRect(item->hDC, &item->rcItem);
        return TRUE;
      }
    break;
  }
  case WM_CTLCOLOREDIT:
    if ((HWND)lp == capture.text) {
      SetTextColor((HDC)wp, color_ref(capture.color));
      SetBkColor((HDC)wp, RGB(250, 245, 234));
      return (LRESULT)GetSysColorBrush(COLOR_INFOBK);
    }
    break;
  case WM_COMMAND:
    if (LOWORD(wp) == ID_TEXT_INPUT && HIWORD(wp) == EN_CHANGE && capture.editing != -2) {
      style_text();
      return 0;
    }
    if (HIWORD(wp) == CBN_SELCHANGE) {
      if (LOWORD(wp) == ID_COLOR) {
        int i = (int)SendMessageW(capture.colors, CB_GETCURSEL, 0, 0);
        if (i >= 0 && i < 5)
          capture.color = PALETTE[i];
      } else if (LOWORD(wp) == ID_STROKE) {
        int i = (int)SendMessageW(capture.strokes, CB_GETCURSEL, 0, 0);
        capture.stroke = i == 0 ? 2 : i == 2 ? 8 : 4;
      } else if (LOWORD(wp) == ID_FONT) {
        int i = (int)SendMessageW(capture.fonts, CB_GETCURSEL, 0, 0);
        capture.font_size = (int)SendMessageW(capture.fonts, CB_GETITEMDATA, i, 0);
      }
      apply_style();
    } else if (HIWORD(wp) == BN_CLICKED)
      editor_command(LOWORD(wp));
    return 0;
  case WM_ERASEBKGND:
    return 1;
  case WM_PAINT: {
    PAINTSTRUCT paint;
    HDC dc = BeginPaint(window, &paint);
    BitBlt(dc, 0, 0, capture.dimmed.width, capture.dimmed.height, capture.dimmed.dc, 0, 0, SRCCOPY);
    if (render_image()) {
      RECT v = capture.viewport;
      BitBlt(dc, v.left, v.top, v.right - v.left, v.bottom - v.top, capture.rendered.dc, v.left, v.top,
             SRCCOPY);
      int saved = SaveDC(dc);
      IntersectClipRect(dc, v.left, v.top, v.right, v.bottom);
      if (capture.dragging && capture.drag_mode == 0) {
        RECT b = selection(capture.start, capture.end);
        draw_annotation(dc, capture.tool, capture.tool == TOOL_ARROW ? capture.start.x : b.left,
                        capture.tool == TOOL_ARROW ? capture.start.y : b.top,
                        capture.tool == TOOL_ARROW ? capture.end.x - capture.start.x : b.right - b.left,
                        capture.tool == TOOL_ARROW ? capture.end.y - capture.start.y : b.bottom - b.top,
                        capture.color, capture.stroke, NULL, 0, capture.font_size, 1, 0, 0);
      }
      if (capture.selected >= 0 && capture.editing == -2) {
        RECT r =
            capture.dragging && capture.drag_mode == 1 ? capture.draft : annotation_rect(capture.selected);
        frame(dc, r, TRUE);
      }
      RestoreDC(dc, saved);
      frame(dc, v, TRUE);
      region_label(dc, v);
    }
    HBRUSH brush = CreateSolidBrush(RGB(43, 41, 48));
    FillRect(dc, &capture.toolbar, brush);
    DeleteObject(brush);
    EndPaint(window, &paint);
    return 0;
  }
  case WM_LBUTTONDBLCLK: {
    POINT p = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
    int index = hit_text(p);
    if (index >= 0 && PtInRect(&capture.viewport, p))
      begin_text(p, index);
    return 0;
  }
  case WM_LBUTTONDOWN: {
    POINT p = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
    if (PtInRect(&capture.toolbar, p))
      return 0;
    if (!finish_text(FALSE))
      return 0;
    SetFocus(window);
    capture.start = capture.end = p;
    capture.handle = -1;
    capture.drag_mode = 0;
    if (capture.selected >= 0 && (capture.handle = hit_handle(annotation_rect(capture.selected), p)) >= 0) {
      capture.drag_mode = 1;
      capture.drag_bounds = capture.draft = annotation_rect(capture.selected);
    } else if ((capture.handle = hit_handle(capture.viewport, p)) >= 0) {
      capture.drag_mode = 2;
      capture.drag_bounds = capture.draft = capture.viewport;
      capture.selected = -1;
    } else if (!PtInRect(&capture.viewport, p)) {
      capture.selected = -1;
      changed();
      return 0;
    } else {
      int index = hit_text(p);
      if (index >= 0 && (capture.tool == TOOL_SELECT || capture.tool == TOOL_TEXT)) {
        capture.selected = index;
        capture.color = (int)image_session_value(capture.session, index, 5);
        capture.font_size = (int)image_session_value(capture.session, index, 7);
        capture.stroke = (int)image_session_value(capture.session, index, 6);
        sync_style_controls();
        capture.drag_mode = 1;
        capture.drag_bounds = capture.draft = annotation_rect(index);
        capture.handle = -1;
      } else if (capture.tool == TOOL_TEXT) {
        begin_text(p, -1);
        return 0;
      } else if (capture.tool == TOOL_SELECT) {
        capture.drag_mode = 2;
        capture.drag_bounds = capture.draft = capture.viewport;
        capture.handle = -1;
        capture.selected = -1;
      } else
        capture.selected = -1;
    }
    capture.dragging = TRUE;
    SetCapture(window);
    changed();
    return 0;
  }
  case WM_MOUSEMOVE:
    if (capture.dragging) {
      capture.end.x = bounded(GET_X_LPARAM(lp), 0, capture.image.width);
      capture.end.y = bounded(GET_Y_LPARAM(lp), 0, capture.image.height);
      if (capture.drag_mode) {
        capture.draft = drag_rect(capture.drag_bounds, capture.start, capture.end, capture.handle);
        if (capture.drag_mode == 2)
          capture.viewport = capture.draft;
      }
      capture.dirty = TRUE;
      InvalidateRect(window, NULL, FALSE);
    }
    return 0;
  case WM_LBUTTONUP:
    if (capture.dragging) {
      capture.dragging = FALSE;
      ReleaseCapture();
      if (capture.drag_mode == 1 && capture.selected >= 0) {
        RECT r = capture.draft;
        int size = capture.font_size;
        if (capture.handle == 0 || capture.handle == 2 || capture.handle == 4 || capture.handle == 6)
          size = bounded(rounded(capture.font_size * (double)(r.right - r.left) /
                                 maximum(1, capture.drag_bounds.right - capture.drag_bounds.left)),
                         8, 128);
        r = fit_annotation_bounds(capture.selected, r, size);
        preserve_text(capture.selected);
        image_session_update(capture.session, capture.selected, r.left, r.top, r.right - r.left,
                             r.bottom - r.top, capture.color, capture.stroke, size);
        capture.font_size = size;
        sync_style_controls();
      } else if (capture.drag_mode == 2) {
        RECT r = capture.viewport;
        image_session_crop(capture.session, r.left, r.top, r.right - r.left, r.bottom - r.top);
        sync_viewport();
        layout_editor(window);
      } else
        add_shape();
      changed();
    }
    return 0;
  case WM_CAPTURECHANGED:
    if (capture.dragging) {
      capture.dragging = FALSE;
      sync_viewport();
      changed();
    }
    return 0;
  case WM_CLOSE:
    mc_capture_close();
    return 0;
  case WM_NCDESTROY:
    capture.editor = NULL;
    return DefWindowProcW(window, message, wp, lp);
  }
  return DefWindowProcW(window, message, wp, lp);
}
static BOOL open_editor(void) {
  if (!capture.image.dc) {
    if (!surface_new(&capture.image, capture.desktop.width, capture.desktop.height))
      return FALSE;
    BitBlt(capture.image.dc, 0, 0, capture.image.width, capture.image.height, capture.desktop.dc, 0, 0,
           SRCCOPY);
  }
  RECT v = capture.viewport;
  capture.session = image_session_create_viewport(capture.image.width, capture.image.height, v.left, v.top,
                                                  v.right - v.left, v.bottom - v.top);
  if (capture.session <= 0)
    return FALSE;
  capture.selected = -1;
  capture.editing = -2;
  capture.tool = TOOL_SELECT;
  capture.color = PALETTE[0];
  capture.stroke = 4;
  capture.font_size = 24;
  capture.dirty = TRUE;
  HWND editor = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_CONTROLPARENT, EDITOR_CLASS,
                                L"Mooji Cut · 标注后复制", WS_POPUP | WS_CLIPCHILDREN,
                                capture.desktop_bounds.left, capture.desktop_bounds.top, capture.image.width,
                                capture.image.height, capture.owner, NULL, capture.instance, NULL);
  if (!editor)
    return FALSE;
  if (!capture.smoke) {
    ShowWindow(editor, SW_SHOW);
    UpdateWindow(editor);
    SetForegroundWindow(editor);
    SetFocus(editor);
  }
  return TRUE;
}
static LRESULT CALLBACK overlay_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  switch (message) {
  case WM_ERASEBKGND:
    return 1;
  case WM_PAINT: {
    PAINTSTRUCT paint;
    HDC dc = BeginPaint(window, &paint);
    RECT r = selection(capture.start, capture.end);
    BitBlt(dc, 0, 0, capture.desktop.width, capture.desktop.height, capture.dimmed.dc, 0, 0, SRCCOPY);
    if (r.right > r.left && r.bottom > r.top) {
      BitBlt(dc, r.left, r.top, r.right - r.left, r.bottom - r.top, capture.desktop.dc, r.left, r.top,
             SRCCOPY);
      frame(dc, r, FALSE);
      region_label(dc, r);
    }
    EndPaint(window, &paint);
    return 0;
  }
  case WM_KEYDOWN:
    if (wp == VK_ESCAPE)
      mc_capture_close();
    return 0;
  case WM_RBUTTONDOWN:
  case WM_CLOSE:
  case WM_DISPLAYCHANGE:
    mc_capture_close();
    return 0;
  case WM_LBUTTONDOWN:
    capture.start.x = capture.end.x = bounded(GET_X_LPARAM(lp), 0, capture.desktop.width);
    capture.start.y = capture.end.y = bounded(GET_Y_LPARAM(lp), 0, capture.desktop.height);
    capture.dragging = TRUE;
    SetCapture(window);
    return 0;
  case WM_MOUSEMOVE:
    if (capture.dragging) {
      capture.end.x = bounded(GET_X_LPARAM(lp), 0, capture.desktop.width);
      capture.end.y = bounded(GET_Y_LPARAM(lp), 0, capture.desktop.height);
      InvalidateRect(window, NULL, FALSE);
    }
    return 0;
  case WM_LBUTTONUP:
    if (capture.dragging) {
      capture.end.x = bounded(GET_X_LPARAM(lp), 0, capture.desktop.width);
      capture.end.y = bounded(GET_Y_LPARAM(lp), 0, capture.desktop.height);
      capture.dragging = FALSE;
      ReleaseCapture();
      capture.viewport = selection(capture.start, capture.end);
      if (capture.viewport.right - capture.viewport.left < 8 ||
          capture.viewport.bottom - capture.viewport.top < 8)
        return 0;
      capture.overlay = NULL;
      if (!open_editor()) {
        DestroyWindow(window);
        mc_capture_close();
        return 0;
      }
      DestroyWindow(window);
      surface_free(&capture.desktop);
    }
    return 0;
  case WM_CAPTURECHANGED:
    capture.dragging = FALSE;
    return 0;
  case WM_ACTIVATE:
    if (LOWORD(wp) == WA_INACTIVE && capture.overlay == window)
      mc_capture_close();
    return 0;
  case WM_NCDESTROY:
    if (capture.overlay == window)
      capture.overlay = NULL;
    break;
  }
  return DefWindowProcW(window, message, wp, lp);
}
static BOOL register_windows(HINSTANCE instance) {
  WNDCLASSEXW k = {sizeof(k)};
  k.hInstance = instance;
  k.lpfnWndProc = overlay_proc;
  k.lpszClassName = OVERLAY_CLASS;
  k.hCursor = LoadCursorW(NULL, IDC_CROSS);
  if (!RegisterClassExW(&k) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
    return FALSE;
  k.style = CS_DBLCLKS;
  k.lpfnWndProc = editor_proc;
  k.lpszClassName = EDITOR_CLASS;
  k.hCursor = LoadCursorW(NULL, IDC_ARROW);
  return RegisterClassExW(&k) || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}
static BOOL show_selection(void) {
  capture.overlay =
      CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, OVERLAY_CLASS, L"Mooji Cut · 框选", WS_POPUP,
                      capture.desktop_bounds.left, capture.desktop_bounds.top, capture.desktop.width,
                      capture.desktop.height, capture.owner, NULL, capture.instance, NULL);
  if (!capture.overlay)
    return FALSE;
  if (!capture.smoke) {
    ShowWindow(capture.overlay, SW_SHOW);
    UpdateWindow(capture.overlay);
    SetForegroundWindow(capture.overlay);
    SetFocus(capture.overlay);
  }
  return TRUE;
}
static void dim_desktop(void) {
  GdiFlush();
  SIZE_T bytes = (SIZE_T)capture.desktop.width * capture.desktop.height * 4;
  for (SIZE_T i = 0; i < bytes; i += 4) {
    for (int j = 0; j < 3; j++)
      capture.dimmed.pixels[i + j] = (BYTE)(capture.desktop.pixels[i + j] * 3 / 5);
    capture.dimmed.pixels[i + 3] = 0;
  }
}
bool mc_capture_start(HINSTANCE instance, HWND owner) {
  if (mc_capture_busy()) {
    mc_capture_activate();
    return true;
  }
  if (!register_windows(instance)) {
    mc_pins_hide(FALSE);
    return false;
  }
  ZeroMemory(&capture, sizeof(capture));
  capture.instance = instance;
  capture.owner = owner;
  mc_pins_hide(TRUE);
  int x = GetSystemMetrics(SM_XVIRTUALSCREEN), y = GetSystemMetrics(SM_YVIRTUALSCREEN),
      w = GetSystemMetrics(SM_CXVIRTUALSCREEN), h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  SetRect(&capture.desktop_bounds, x, y, x + w, y + h);
  if (!surface_new(&capture.desktop, w, h) || !surface_new(&capture.dimmed, w, h)) {
    mc_capture_close();
    return false;
  }
  GdiFlush();
  HDC desktop = GetDC(NULL);
  if (!desktop || !BitBlt(capture.desktop.dc, 0, 0, w, h, desktop, x, y, SRCCOPY | CAPTUREBLT)) {
    if (desktop)
      ReleaseDC(NULL, desktop);
    mc_capture_close();
    return false;
  }
  ReleaseDC(NULL, desktop);
  dim_desktop();
  if (!show_selection()) {
    mc_capture_close();
    return false;
  }
  return true;
}
bool mc_capture_busy(void) { return capture.overlay || capture.editor; }
void mc_capture_activate(void) {
  HWND w = capture.editor ? capture.editor : capture.overlay;
  if (w) {
    ShowWindow(w, SW_RESTORE);
    SetForegroundWindow(w);
    SetFocus(w);
  }
}
void mc_capture_close(void) {
  if (capture.closing)
    return;
  capture.closing = TRUE;
  HWND overlay = capture.overlay, editor = capture.editor;
  capture.overlay = NULL;
  capture.editor = NULL;
  capture.dragging = FALSE;
  if (GetCapture() == overlay || GetCapture() == editor)
    ReleaseCapture();
  if (overlay)
    DestroyWindow(overlay);
  if (editor)
    DestroyWindow(editor);
  if (capture.session > 0)
    image_session_dispose(capture.session);
  surface_free(&capture.desktop);
  surface_free(&capture.dimmed);
  surface_free(&capture.image);
  surface_free(&capture.rendered);
  if (capture.font)
    DeleteObject(capture.font);
  if (capture.text_font)
    DeleteObject(capture.text_font);
  ZeroMemory(&capture, sizeof(capture));
  mc_pins_hide(FALSE);
}
bool mc_capture_handle_message(MSG *message) {
  if (!capture.editor || (message->hwnd != capture.editor && !IsChild(capture.editor, message->hwnd)))
    return false;
  // Let the native EDIT/IME consume candidate selection and cancellation keys.
  if (capture.composing)
    return false;
  if (message->message == WM_KEYDOWN) {
    BOOL control = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
    BOOL text = GetFocus() == capture.text;
    if (message->wParam == VK_ESCAPE) {
      if (capture.editing != -2) {
        finish_text(TRUE);
        SetFocus(capture.editor);
      } else
        mc_capture_close();
      return true;
    }
    if (control && message->wParam == VK_RETURN) {
      if (text) {
        if (finish_text(FALSE))
          SetFocus(capture.editor);
      } else
        editor_command(ID_COPY);
      return true;
    }
    if (text && control && message->wParam == 'A') {
      SendMessageW(capture.text, EM_SETSEL, 0, -1);
      return true;
    }
    if (!text && !control && capture.selected >= 0 && message->wParam >= VK_LEFT &&
        message->wParam <= VK_DOWN) {
      RECT r = annotation_rect(capture.selected);
      int step = (GetKeyState(VK_SHIFT) & 0x8000) ? 10 : 1;
      POINT from = {0, 0}, to = {0, 0};
      if (message->wParam == VK_LEFT)
        to.x = -step;
      else if (message->wParam == VK_RIGHT)
        to.x = step;
      else if (message->wParam == VK_UP)
        to.y = -step;
      else
        to.y = step;
      r = drag_rect(r, from, to, -1);
      preserve_text(capture.selected);
      image_session_update(capture.session, capture.selected, r.left, r.top, r.right - r.left,
                           r.bottom - r.top, (int)image_session_value(capture.session, capture.selected, 5),
                           (int)image_session_value(capture.session, capture.selected, 6),
                           (int)image_session_value(capture.session, capture.selected, 7));
      changed();
      return true;
    }
    if (!text && control) {
      if (message->wParam == 'Z') {
        editor_command(GetKeyState(VK_SHIFT) & 0x8000 ? ID_REDO : ID_UNDO);
        return true;
      }
      if (message->wParam == 'Y') {
        editor_command(ID_REDO);
        return true;
      }
      if (message->wParam == 'C') {
        editor_command(ID_COPY);
        return true;
      }
    }
    if (!text && message->wParam == VK_DELETE && capture.selected >= 0) {
      image_session_remove(capture.session, capture.selected);
      capture.selected = -1;
      changed();
      return true;
    }
  }
  if (GetFocus() == capture.text)
    return false;
  return IsDialogMessageW(capture.editor, message) != FALSE;
}
int mc_capture_smoke(HINSTANCE instance) {
  int result = 1;
  HGLOBAL dib = NULL;
  ZeroMemory(&capture, sizeof(capture));
  capture.instance = instance;
  capture.smoke = TRUE;
  SetRect(&capture.desktop_bounds, 0, 0, 640, 480);
  if (!register_windows(instance) || !surface_new(&capture.desktop, 640, 480) ||
      !surface_new(&capture.dimmed, 640, 480))
    goto cleanup;
  for (int y = 0; y < 480; y++)
    for (int x = 0; x < 640; x++) {
      BYTE *pixel = capture.desktop.pixels + ((SIZE_T)y * 640 + x) * 4;
      pixel[0] = 80;
      pixel[1] = 160;
      pixel[2] = 220;
      pixel[3] = 0;
    }
  dim_desktop();
  if (!show_selection())
    goto cleanup;
  SendMessageW(capture.overlay, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(330, 220));
  SendMessageW(capture.overlay, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(10, 20));
  SendMessageW(capture.overlay, WM_LBUTTONUP, 0, MAKELPARAM(10, 20));
  if (!capture.editor || capture.viewport.left != 10 || capture.viewport.top != 20 ||
      (GetWindowLongPtrW(capture.editor, GWL_STYLE) & WS_CAPTION))
    goto cleanup;
  if (image_session_add(capture.session, TOOL_REDACT, 40, 60, 80, 60, 0, 4) != 1)
    goto cleanup;
  begin_text((POINT){50, 70}, -1);
  SetWindowTextW(capture.text, L"截图测试 MoonBit\r\n第二行");
  SendMessageW(capture.text, WM_IME_STARTCOMPOSITION, 0, 0);
  MSG ime_key = {0};
  ime_key.hwnd = capture.text;
  ime_key.message = WM_KEYDOWN;
  ime_key.wParam = VK_ESCAPE;
  if (mc_capture_handle_message(&ime_key) || finish_text(FALSE) || finish_text(TRUE) ||
      image_session_count(capture.session) != 1)
    goto cleanup;
  SendMessageW(capture.text, WM_IME_ENDCOMPOSITION, 0, 0);

  if (!finish_text(FALSE) || image_session_count(capture.session) != 2)
    goto cleanup;
  int index = capture.selected;
  begin_text((POINT){50, 70}, index);
  SetWindowTextW(capture.text, L"修改后");
  if (!finish_text(FALSE) || image_session_count(capture.session) != 2)
    goto cleanup;
  preserve_text(index);
  if (image_session_update(capture.session, index, 150, 100, 150, 70, 0xF26769, 4, 32) != 1 ||
      image_session_value(capture.session, index, 7) != 32)
    goto cleanup;
  if (image_session_undo(capture.session) != 1 || image_session_value(capture.session, index, 1) != 50 ||
      image_session_redo(capture.session) != 1)
    goto cleanup;
  // Drive the actual mouse gesture handlers; the MoonBit document commits only at mouse-up.
  capture.tool = TOOL_SELECT;
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(180, 125));
  SendMessageW(capture.editor, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(190, 135));
  if (image_session_value(capture.session, index, 1) != 150)
    goto cleanup;
  SendMessageW(capture.editor, WM_LBUTTONUP, 0, MAKELPARAM(190, 135));
  if (image_session_value(capture.session, index, 1) != 160 || image_session_undo(capture.session) != 1)
    goto cleanup;
  capture.selected = -1;
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(330, 220));
  SendMessageW(capture.editor, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(350, 240));
  SendMessageW(capture.editor, WM_LBUTTONUP, 0, MAKELPARAM(350, 240));
  if (image_session_viewport_value(capture.session, 2) != 340 || image_session_undo(capture.session) != 1)
    goto cleanup;
  sync_viewport();
  changed();
  dib = image_dib();
  if (!dib)
    goto cleanup;
  BITMAPINFOHEADER *header = GlobalLock(dib);
  if (!header)
    goto cleanup;
  SIZE_T stride = ((SIZE_T)320 * 3 + 3) & ~(SIZE_T)3;
  const BYTE *mask = (const BYTE *)(header + 1) + 149 * stride + 50 * 3,
             *source = (const BYTE *)(header + 1) + 194 * stride + 5 * 3;
  BOOL valid = header->biWidth == 320 && header->biHeight == 200 && !mask[0] && !mask[1] && !mask[2] &&
               source[0] == 80 && source[1] == 160 && source[2] == 220;
  GlobalUnlock(dib);
  if (!valid)
    goto cleanup;
  // Font changes must resize the box and leave visible pixels in the exported image.
  set_session_text(L"A", 1);
  if (!image_session_add_styled(capture.session, TOOL_TEXT, 170, 30, 140, 72, 0xF26769, 4, 24))
    goto cleanup;
  capture.selected = image_session_count(capture.session) - 1;
  capture.color = 0xF26769;
  capture.stroke = 4;
  capture.font_size = 128;
  apply_style();
  if (image_session_value(capture.session, capture.selected, 4) < 128 || !render_image())
    goto cleanup;
  int colored = 0;
  for (int y = 35; y < 180; y++)
    for (int x = 175; x < 300; x++) {
      BYTE *pixel = capture.rendered.pixels + ((SIZE_T)y * capture.image.width + x) * 4;
      if (pixel[2] > 230 && pixel[1] < 130 && pixel[0] < 130)
        colored++;
    }
  if (colored < 100)
    goto cleanup;
  if (!mc_pin_smoke(instance))
    goto cleanup;
  result = 0;
cleanup:
  if (dib)
    GlobalFree(dib);
  mc_capture_close();
  printf("Windows screenshot smoke: %s (synthetic frozen overlay, inline multiline edit, style undo/redo, "
         "cropped DIB, privacy masks, pin geometry; clipboard untouched).\n",
         result ? "FAILED" : "passed");
  return result;
}
