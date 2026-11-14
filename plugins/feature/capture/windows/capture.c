#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include "capture.h"
#include "native/shared/image_session.h"
#include "components/icons/shared/mc_icons.h"
#include "components/hud/windows/hud.h"
#include "components/style_controls/windows/style_controls.h"
#include "moonbit.h"
#include "plugins/feature/select/windows/selection.h"
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
  ID_PIN,
  ID_OCR,
  ID_TRANSLATE
};
enum { ID_STYLE_BASE = 8500 };
typedef struct {
  HDC dc;
  HBITMAP bitmap;
  HGDIOBJ previous;
  BYTE *pixels;
  int width, height;
} Surface;
typedef struct {
  HINSTANCE instance;
  HWND owner, overlay, editor, text, tooltip, buttons[12];
  MCStyleControls *style_controls;
  MCCaptureHost host;
  MCSelection selection;
  HFONT font, text_font;
  Surface desktop, dimmed, image, rendered;
  RECT desktop_bounds, canvas, viewport, toolbar, drag_bounds, draft;
  POINT start, end;
  double zoom, opacity;
  int32_t session, style_bank;
  int tool, color, stroke, font_size, selected, editing, drag_mode, handle;
  BOOL dragging, dirty, smoke, closing, composing;
} Capture;
static Capture capture;
static const wchar_t *OVERLAY_CLASS = L"MoojiCut.Capture.Selection";
static const wchar_t *EDITOR_CLASS = L"MoojiCut.Capture.Editor";
static void set_pins_hidden(BOOL hidden) {
  if (capture.host.set_pins_hidden)
    capture.host.set_pins_hidden(capture.host.context, hidden);
}

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
    HBRUSH fill = CreateSolidBrush(color_ref(color));
    FillRect(dc, &rect, fill);
    DeleteObject(fill);
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

/* Rasterize coverage once, then source-over blend RGB. This preserves the same
 * GDI font layout for preview/export and supports opacity 0 without special colors. */
static BOOL blend_annotation(int kind, double x, double y, double w, double h, int color, double stroke,
                             const wchar_t *text, int length, double font, double opacity) {
  if (opacity <= 0)
    return TRUE;
  int margin = rounded(stroke + 18), left = maximum(0, (int)floor(fmin(x, x + w)) - margin),
      top = maximum(0, (int)floor(fmin(y, y + h)) - margin);
  int right = minimum(capture.image.width, (int)ceil(fmax(x, x + w)) + margin),
      bottom = minimum(capture.image.height, (int)ceil(fmax(y, y + h)) + margin);
  if (right <= left || bottom <= top)
    return TRUE;
  Surface mask = {0};
  if (!surface_new(&mask, right - left, bottom - top))
    return FALSE;
  memset(mask.pixels, 0, (SIZE_T)mask.width * mask.height * 4);
  draw_annotation(mask.dc, kind, x, y, w, h, 0xffffff, stroke, text, length, font, 1, -left, -top);
  GdiFlush();
  BYTE rgb[3] = {(BYTE)color, (BYTE)(color >> 8), (BYTE)(color >> 16)};
  for (int row = 0; row < mask.height; row++)
    for (int col = 0; col < mask.width; col++) {
      BYTE *coverage = mask.pixels + ((SIZE_T)row * mask.width + col) * 4;
      double alpha = opacity * (coverage[0] + coverage[1] + coverage[2]) / (3.0 * 255);
      BYTE *target = capture.rendered.pixels + ((SIZE_T)(top + row) * capture.image.width + left + col) * 4;
      for (int c = 0; c < 3; c++)
        target[c] = (BYTE)rounded(target[c] * (1 - alpha) + rgb[c] * alpha);
    }
  surface_free(&mask);
  return TRUE;
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
  GdiFlush();
  count = image_session_count(capture.session);
  /* Covers are the upper layer, with their chosen color and opacity. */
  for (pass = 0; pass < 2; pass++) {
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
                            rounded(editor_style_min(MC_STYLE_FONT)), rounded(editor_style_max(MC_STYLE_FONT)));
      BOOL painted = blend_annotation(
          kind, moving ? draft.left : image_session_value(capture.session, i, 1),
          moving ? draft.top : image_session_value(capture.session, i, 2),
          moving ? draft.right - draft.left : image_session_value(capture.session, i, 3),
          moving ? draft.bottom - draft.top : image_session_value(capture.session, i, 4),
          (int)image_session_value(capture.session, i, 5), image_session_value(capture.session, i, 6),
          (const wchar_t *)text, text ? Moonbit_array_length(text) : 0, font_size,
          image_session_value(capture.session, i, 8));
      if (text)
        moonbit_decref(text);
      if (!painted)
        return FALSE;
    }
    if (pass == 0 && capture.editing != -2) {
      int length = GetWindowTextLengthW(capture.text);
      wchar_t *text = calloc((size_t)length + 1, 2);
      if (text) {
        GetWindowTextW(capture.text, text, length + 1);
        RECT r = capture.draft;
        BOOL painted =
            blend_annotation(TOOL_TEXT, r.left, r.top, r.right - r.left, r.bottom - r.top, capture.color,
                             capture.stroke, text, length, capture.font_size, capture.opacity);
        free(text);
        if (!painted)
          return FALSE;
      }
    }
    if (capture.dragging && capture.drag_mode == 0 && ((capture.tool == TOOL_REDACT) == (pass == 1))) {
      RECT b = mc_selection_normalize(capture.start, capture.end);
      if (!blend_annotation(capture.tool, capture.tool == TOOL_ARROW ? capture.start.x : b.left,
                            capture.tool == TOOL_ARROW ? capture.start.y : b.top,
                            capture.tool == TOOL_ARROW ? capture.end.x - capture.start.x : b.right - b.left,
                            capture.tool == TOOL_ARROW ? capture.end.y - capture.start.y : b.bottom - b.top,
                            capture.color, capture.stroke, NULL, 0, capture.font_size, capture.opacity))
        return FALSE;
    }
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

/* Style context follows an active text draft/selection before the current drawing tool. */
static int style_context(void) {
  if (capture.editing != -2 ||
      (capture.selected >= 0 && (int)image_session_value(capture.session, capture.selected, 0) == TOOL_TEXT))
    return TOOL_TEXT;
  return capture.tool;
}
static void sync_style_controls(void) {
  MCStyleControlsModel model = {0};
  model.mask = (unsigned)editor_style_property_mask(style_context());
  model.enabled = !capture.composing;
  const double values[] = {capture.color, capture.opacity, capture.stroke, capture.font_size};
  for (int field = 0; field < 4; field++)
    model.property[field] = (MCStyleProperty){values[field], editor_style_min(field),
        editor_style_max(field), editor_style_step(field)};
  mc_style_controls_update(capture.style_controls, &model);
}
static void load_tool_style(int tool) {
  capture.color = rounded(editor_style_get(capture.style_bank, tool, MC_STYLE_COLOR));
  capture.opacity = editor_style_get(capture.style_bank, tool, MC_STYLE_OPACITY);
  capture.stroke = rounded(editor_style_get(capture.style_bank, tool, MC_STYLE_STROKE));
  capture.font_size = rounded(editor_style_get(capture.style_bank, tool, MC_STYLE_FONT));
  sync_style_controls();
}
static void load_annotation_style(int index) {
  capture.color = rounded(image_session_value(capture.session, index, 5));
  capture.opacity = image_session_value(capture.session, index, 8);
  capture.stroke = rounded(image_session_value(capture.session, index, 6));
  capture.font_size = rounded(image_session_value(capture.session, index, 7));
  sync_style_controls();
}
static void changed(void) {
  sync_style_controls();
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
  int width = dpi_px(window, 500), height = dpi_px(window, 92), gap = dpi_px(window, 10);
  int x = bounded(capture.viewport.left, 6, maximum(6, client.right - width - 6)),
      y = capture.viewport.bottom + gap;
  if (y + height > client.bottom - 6)
    y = capture.viewport.top - height - gap;
  y = bounded(y, 6, maximum(6, client.bottom - height - 6));
  SetRect(&capture.toolbar, x, y, x + width, y + height);
  int size = dpi_px(window, 32);
  for (int i = 0; i < 5; i++)
    MoveWindow(capture.buttons[i], x + dpi_px(window, 12 + i * 36), y + dpi_px(window, 8), size, size, TRUE);
  for (int i = 10; i < 12; i++) {
    int left = x + dpi_px(window, 208 + (i - 10) * 36), top = y + dpi_px(window, 8);
    MoveWindow(capture.buttons[i], left, top, size, size, TRUE);
    TOOLINFOW tip = {sizeof(tip)};
    tip.hwnd = window;
    tip.uId = i == 10 ? ID_OCR : ID_TRANSLATE;
    SetRect(&tip.rect, left, top, left + size, top + size);
    SendMessageW(capture.tooltip, TTM_NEWTOOLRECTW, 0, (LPARAM)&tip);
  }
  MoveWindow(capture.buttons[5], x + dpi_px(window, 296), y + dpi_px(window, 8), size, size, TRUE);
  MoveWindow(capture.buttons[6], x + dpi_px(window, 332), y + dpi_px(window, 8), size, size, TRUE);
  for (int i = 7; i < 10; i++)
    MoveWindow(capture.buttons[i], x + dpi_px(window, 384 + (i - 7) * 36), y + dpi_px(window, 8), size, size,
               TRUE);
  mc_style_controls_layout(capture.style_controls, x + dpi_px(window, 12), y + dpi_px(window, 52));
  capture.canvas = capture.viewport;
  capture.zoom = 1;
  sync_style_controls();
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
  if (message == WM_IME_STARTCOMPOSITION) {
    capture.composing = TRUE;
    sync_style_controls();
  }
  if (message == WM_IME_ENDCOMPOSITION) {
    LRESULT result = DefSubclassProc(window, message, wp, lp);
    capture.composing = FALSE;
    sync_style_controls();
    return result;
  }
  if (message == WM_NCDESTROY) {
    capture.composing = FALSE;
    RemoveWindowSubclass(window, text_proc, 1);
  }
  LRESULT result = DefSubclassProc(window, message, wp, lp);
  if (capture.opacity < 1 &&
      (message == WM_KEYUP || message == WM_MOUSEMOVE || message == WM_LBUTTONUP || message == EM_SETSEL))
    InvalidateRect(capture.editor, NULL, FALSE);
  return result;
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
  // Translucent text is displayed by the canvas compositor while the native
  // EDIT retains focus/IME. Covers similarly expose exactly one composited layer.
  if (capture.opacity < 1) {
    DeleteObject(region);
    region = CreateRectRgn(0, 0, 0, 0);
  }
  SetWindowRgn(capture.text, region, TRUE);
  capture.dirty = TRUE;
  if (capture.editor)
    InvalidateRect(capture.editor, NULL, FALSE);
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
    ok = (index < 0 ? image_session_add_rgba(capture.session, TOOL_TEXT, r.left, r.top, r.right - r.left,
                                             r.bottom - r.top, capture.color, capture.stroke,
                                             capture.font_size, capture.opacity)
                    : image_session_update_rgba(capture.session, index, r.left, r.top, r.right - r.left,
                                                r.bottom - r.top, capture.color, capture.stroke,
                                                capture.font_size, capture.opacity)) == 1;
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
  if (cancel || capture.selected < 0) {
    if (capture.selected >= 0)
      load_annotation_style(capture.selected);
    else
      load_tool_style(capture.tool);
  }
  changed();
  return TRUE;
}
static void begin_text(POINT point, int index) {
  if (!finish_text(FALSE))
    return;
  capture.editing = index;
  capture.selected = index;
  if (index >= 0) {
    capture.draft = annotation_rect(index);
    load_annotation_style(index);
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
    load_tool_style(TOOL_TEXT);
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
static int hit_handle(RECT rect, POINT point) {
  int radius = dpi_px(capture.editor ? capture.editor : capture.overlay, 7);
  return mc_selection_hit_handle(rect, point, radius);
}
static RECT drag_rect(RECT rect, POINT from, POINT to, int handle) {
  RECT bounds = {0, 0, capture.image.width, capture.image.height};
  return mc_selection_transform(rect, from, to, handle, bounds, 8);
}
static void frame(HDC dc, RECT r, BOOL handles) {
  HWND window = capture.editor ? capture.editor : capture.overlay;
  mc_hud_frame(dc, &r, handles, window ? (float)GetDpiForWindow(window) / 96 : 1);
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
static const int button_ids[12] = {ID_SELECT, ID_RECT, ID_ARROW,  ID_TEXT, ID_REDACT, ID_UNDO,
                                   ID_REDO,   ID_PIN,  ID_CANCEL, ID_COPY, ID_OCR,    ID_TRANSLATE};
static const MCIcon button_icons[12] = {MC_ICON_SELECT, MC_ICON_RECTANGLE, MC_ICON_ARROW, MC_ICON_TEXT,
                                        MC_ICON_REDACT, MC_ICON_UNDO,      MC_ICON_REDO,  MC_ICON_PIN,
                                        MC_ICON_CLOSE,  MC_ICON_CHECK,     MC_ICON_OCR,   MC_ICON_TRANSLATE};
static LRESULT CALLBACK hud_button_proc(HWND window, UINT message, WPARAM wp, LPARAM lp, UINT_PTR id,
                                        DWORD_PTR data) {
  (void)id;
  (void)data;
  if (message == WM_MOUSEMOVE && !GetPropW(window, L"MoojiCut.Hover")) {
    SetPropW(window, L"MoojiCut.Hover", (HANDLE)1);
    TRACKMOUSEEVENT track = {sizeof(track), TME_LEAVE, window, 0};
    TrackMouseEvent(&track);
    InvalidateRect(window, NULL, FALSE);
  } else if (message == WM_MOUSELEAVE) {
    RemovePropW(window, L"MoojiCut.Hover");
    InvalidateRect(window, NULL, FALSE);
  } else if (message == WM_NCDESTROY) {
    RemovePropW(window, L"MoojiCut.Hover");
    RemoveWindowSubclass(window, hud_button_proc, 2);
  }
  return DefSubclassProc(window, message, wp, lp);
}
static HWND hud_button(HWND parent, int id, const wchar_t *label) {
  HWND button = CreateWindowW(L"BUTTON", label, WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW, 0, 0, 1, 1,
                              parent, (HMENU)(INT_PTR)id, capture.instance, NULL);
  SetWindowSubclass(button, hud_button_proc, 2, 0);
  TOOLINFOW tip = {sizeof(tip)};
  tip.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
  tip.hwnd = parent;
  tip.uId = (UINT_PTR)button;
  tip.lpszText = (LPWSTR)label;
  SendMessageW(capture.tooltip, TTM_ADDTOOLW, 0, (LPARAM)&tip);
  return button;
}
static BOOL add_shape(void) {
  RECT b = mc_selection_normalize(capture.start, capture.end);
  if (capture.tool == TOOL_ARROW)
    return abs(capture.end.x - capture.start.x) + abs(capture.end.y - capture.start.y) >= 3 &&
           image_session_add_rgba(capture.session, capture.tool, capture.start.x, capture.start.y,
                                  capture.end.x - capture.start.x, capture.end.y - capture.start.y,
                                  capture.color, capture.stroke, capture.font_size, capture.opacity) == 1;
  if (b.right - b.left < 2 || b.bottom - b.top < 2)
    return FALSE;
  return image_session_add_rgba(capture.session, capture.tool, b.left, b.top, b.right - b.left,
                                b.bottom - b.top, capture.color, capture.stroke, capture.font_size,
                                capture.opacity) == 1;
}
static void editor_command(int command) {
  if (command == ID_OCR || command == ID_TRANSLATE)
    return;
  if (!finish_text(FALSE))
    return;
  if (command >= ID_SELECT && command <= ID_REDACT) {
    capture.tool = command - ID_SELECT;
    capture.selected = -1;
    load_tool_style(capture.tool);
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
    load_tool_style(capture.tool);
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
      if (capture.host.pin_image && capture.host.pin_image(capture.host.context, dib, x, y)) {
        mc_capture_close();
      } else
        GlobalFree(dib);
    }
  }
}
static BOOL apply_style(void) {
  if (capture.editing != -2) {
    style_text();
    return TRUE;
  }
  if (capture.selected >= 0) {
    RECT r = fit_annotation_bounds(capture.selected, annotation_rect(capture.selected), capture.font_size);
    preserve_text(capture.selected);
    if (!image_session_update_rgba(capture.session, capture.selected, r.left, r.top, r.right - r.left,
        r.bottom - r.top, capture.color, capture.stroke, capture.font_size, capture.opacity))
      return FALSE;
    changed();
  }
  return TRUE;
}
static BOOL style_changed(void *context, int field, double value) {
  (void)context;
  if (capture.composing)
    return FALSE;
  BOOL defaults = capture.editing == -1 || (capture.editing == -2 && capture.selected < 0);
  if (defaults && !editor_style_set(capture.style_bank, style_context(), field, value))
    return FALSE;
  int color = capture.color, stroke = capture.stroke, font = capture.font_size;
  double opacity = capture.opacity;
  if (field == MC_STYLE_COLOR) capture.color = rounded(value);
  else if (field == MC_STYLE_OPACITY) capture.opacity = value;
  else if (field == MC_STYLE_STROKE) capture.stroke = rounded(value);
  else if (field == MC_STYLE_FONT) capture.font_size = rounded(value);
  else return FALSE;
  BOOL ok = apply_style();
  if (!ok) {
    capture.color = color; capture.opacity = opacity;
    capture.stroke = stroke; capture.font_size = font;
  }
  sync_style_controls();
  changed();
  return ok;
}
static void paint_editor(HDC dc) {
  BitBlt(dc, 0, 0, capture.dimmed.width, capture.dimmed.height, capture.dimmed.dc, 0, 0, SRCCOPY);
  if (render_image()) {
    RECT v = capture.viewport;
    BitBlt(dc, v.left, v.top, v.right - v.left, v.bottom - v.top, capture.rendered.dc, v.left, v.top,
           SRCCOPY);
    int saved = SaveDC(dc);
    IntersectClipRect(dc, v.left, v.top, v.right, v.bottom);
    if (capture.selected >= 0 && capture.editing == -2) {
      RECT r = capture.dragging && capture.drag_mode == 1 ? capture.draft : annotation_rect(capture.selected);
      frame(dc, r, TRUE);
    }
    if (capture.editing != -2 && capture.opacity < 1) {
      frame(dc, capture.draft, FALSE);
      if (GetFocus() == capture.text) {
        POINT caret;
        if (GetCaretPos(&caret)) {
          HPEN pen = CreatePen(PS_SOLID, 1, RGB(250, 245, 235));
          HGDIOBJ previous = SelectObject(dc, pen);
          MoveToEx(dc, capture.draft.left + caret.x, capture.draft.top + caret.y, NULL);
          LineTo(dc, capture.draft.left + caret.x, capture.draft.top + caret.y + capture.font_size);
          SelectObject(dc, previous);
          DeleteObject(pen);
        }
      }
    }
    RestoreDC(dc, saved);
    frame(dc, v, TRUE);
    region_label(dc, v);
  }
  int context = style_context();
  mc_hud_card(dc, &capture.toolbar, (float)GetDpiForWindow(capture.editor) / 96,
              context == TOOL_SELECT ? L"选择标注以调整样式" : L"");
}
static LRESULT CALLBACK editor_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  switch (message) {
  case WM_CREATE: {
    capture.editor = window;
    capture.font =
        CreateFontW(-dpi_px(window, 14), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                    OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    const wchar_t *labels[12] = {L"选择",
                                 L"矩形",
                                 L"箭头",
                                 L"文字",
                                 L"填充覆盖",
                                 L"撤销 Ctrl+Z",
                                 L"重做 Ctrl+Y",
                                 L"贴图",
                                 L"取消 Esc",
                                 L"确认并复制 Ctrl+Enter",
                                 L"文字识别 · 尚未开放",
                                 L"翻译 · 尚未开放"};
    capture.tooltip =
        CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, NULL, WS_POPUP | TTS_ALWAYSTIP, CW_USEDEFAULT,
                        CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, window, NULL, capture.instance, NULL);
    for (int i = 0; i < 12; i++)
      capture.buttons[i] = hud_button(window, button_ids[i], labels[i]);
    for (int i = 10; i < 12; i++) {
      EnableWindow(capture.buttons[i], FALSE);
      TOOLINFOW tip = {sizeof(tip)};
      tip.hwnd = window;
      tip.uId = (UINT_PTR)capture.buttons[i];
      tip.uFlags = TTF_IDISHWND;
      SendMessageW(capture.tooltip, TTM_DELTOOLW, 0, (LPARAM)&tip);
      tip.uId = button_ids[i];
      tip.uFlags = TTF_SUBCLASS;
      tip.lpszText = (LPWSTR)labels[i];
      SendMessageW(capture.tooltip, TTM_ADDTOOLW, 0, (LPARAM)&tip);
    }
    capture.style_controls = mc_style_controls_create(window, capture.instance, ID_STYLE_BASE,
        style_changed, NULL);
    if (!capture.style_controls)
      return -1;
    sync_style_controls();
    capture.text = CreateWindowExW(0, L"EDIT", L"",
                                   WS_CHILD | WS_TABSTOP | ES_MULTILINE | ES_WANTRETURN | ES_AUTOVSCROLL, 0,
                                   0, 1, 1, window, (HMENU)ID_TEXT_INPUT, capture.instance, NULL);
    SetWindowSubclass(capture.text, text_proc, 1, 0);
    SendMessageW(capture.text, EM_SETLIMITTEXT, 10000, 0);
    SendMessageW(capture.text, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, 0);
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
    if (mc_style_controls_draw(capture.style_controls, item))
      return TRUE;
    int kind = -1, value = 0;
    BOOL selected = FALSE;
    for (int i = 0; i < 12; i++)
      if (item->CtlID == (UINT)button_ids[i]) {
        kind = button_icons[i];
        selected = i < 5 && capture.tool == i;
      }
    if (kind >= 0) {
      mc_hud_button(item->hDC, &item->rcItem, kind, value, selected,
                    GetPropW(item->hwndItem, L"MoojiCut.Hover") != NULL,
                    (item->itemState & ODS_SELECTED) != 0, (item->itemState & ODS_FOCUS) != 0,
                    !IsWindowEnabled(item->hwndItem), (float)GetDpiForWindow(window) / 96);
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
    if (LOWORD(wp) == ID_OCR || LOWORD(wp) == ID_TRANSLATE)
      return 0;
    if (LOWORD(wp) == ID_TEXT_INPUT && HIWORD(wp) == EN_CHANGE && capture.editing != -2) {
      style_text();
      return 0;
    }
    if (mc_style_controls_command(capture.style_controls, wp, lp)) {
      if (capture.editing != -2)
        SetFocus(capture.text);
      return 0;
    }
    if (HIWORD(wp) == BN_CLICKED)
      editor_command(LOWORD(wp));
    return 0;
  case WM_ERASEBKGND:
    return 1;
  case WM_PRINTCLIENT:
    paint_editor((HDC)wp);
    return 0;
  case WM_PAINT: {
    PAINTSTRUCT paint;
    HDC dc = BeginPaint(window, &paint);
    paint_editor(dc);
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
    if (capture.editing != -2 && capture.opacity < 1 && PtInRect(&capture.draft, p)) {
      SetFocus(capture.text);
      SendMessageW(capture.text, WM_LBUTTONDOWN, wp,
                   MAKELPARAM(p.x - capture.draft.left, p.y - capture.draft.top));
      InvalidateRect(window, NULL, FALSE);
      return 0;
    }
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
      load_tool_style(capture.tool);
      changed();
      return 0;
    } else {
      int index = hit_text(p);
      if (index >= 0 && (capture.tool == TOOL_SELECT || capture.tool == TOOL_TEXT)) {
        capture.selected = index;
        load_annotation_style(index);
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
    if (capture.selected < 0 && capture.editing == -2)
      load_tool_style(capture.tool);
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
                         rounded(editor_style_min(MC_STYLE_FONT)), rounded(editor_style_max(MC_STYLE_FONT)));
        r = fit_annotation_bounds(capture.selected, r, size);
        preserve_text(capture.selected);
        image_session_update_rgba(capture.session, capture.selected, r.left, r.top, r.right - r.left,
                                  r.bottom - r.top, capture.color, capture.stroke, size, capture.opacity);
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
  capture.style_bank = editor_style_create();
  if (capture.style_bank <= 0)
    return FALSE;
  load_tool_style(capture.tool);
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
    RECT rect = mc_selection_rect(&capture.selection);
    BitBlt(dc, 0, 0, capture.desktop.width, capture.desktop.height, capture.dimmed.dc, 0, 0, SRCCOPY);
    if (rect.right > rect.left && rect.bottom > rect.top) {
      BitBlt(dc, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
             capture.desktop.dc, rect.left, rect.top, SRCCOPY);
      frame(dc, rect, FALSE);
      region_label(dc, rect);
    }
    EndPaint(window, &paint);
    return 0;
  }
  case WM_KEYDOWN:
    if (wp != VK_ESCAPE)
      return 0;
    // Escape uses the same cancellation path as dismissing the overlay.
    // fall through
  case WM_RBUTTONDOWN:
  case WM_CLOSE:
  case WM_DISPLAYCHANGE:
    mc_selection_update(&capture.selection, MC_SELECTION_CANCEL, (POINT){0, 0});
    mc_capture_close();
    return 0;
  case WM_LBUTTONDOWN:
    mc_selection_update(&capture.selection, MC_SELECTION_BEGIN,
                        (POINT){GET_X_LPARAM(lp), GET_Y_LPARAM(lp)});
    SetCapture(window);
    return 0;
  case WM_MOUSEMOVE: {
    MCSelectionResult result = mc_selection_update(&capture.selection, MC_SELECTION_MOVE,
        (POINT){GET_X_LPARAM(lp), GET_Y_LPARAM(lp)});
    if (result.status == MC_SELECTION_CHANGED)
      InvalidateRect(window, NULL, FALSE);
    return 0;
  }
  case WM_LBUTTONUP: {
    BOOL dragging = capture.selection.dragging;
    MCSelectionResult result = mc_selection_update(&capture.selection, MC_SELECTION_END,
        (POINT){GET_X_LPARAM(lp), GET_Y_LPARAM(lp)});
    if (dragging)
      ReleaseCapture();
    if (result.status == MC_SELECTION_COMMITTED) {
      capture.viewport = result.rect;
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
  }
  case WM_CAPTURECHANGED:
    mc_selection_update(&capture.selection, MC_SELECTION_LOST_CAPTURE, (POINT){0, 0});
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
  mc_selection_init(&capture.selection, (RECT){0, 0, capture.desktop.width, capture.desktop.height}, 8);
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
bool mc_capture_start(HINSTANCE instance, HWND owner, const MCCaptureHost *services) {
  if (mc_capture_busy()) {
    mc_capture_activate();
    return true;
  }
  if (!register_windows(instance)) {
    if (services && services->set_pins_hidden)
      services->set_pins_hidden(services->context, FALSE);
    return false;
  }
  ZeroMemory(&capture, sizeof(capture));
  capture.instance = instance;
  capture.owner = owner;
  if (services)
    capture.host = *services;
  set_pins_hidden(TRUE);
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
  MCCaptureHost services = capture.host;
  HWND overlay = capture.overlay, editor = capture.editor;
  capture.overlay = NULL;
  capture.editor = NULL;
  capture.dragging = FALSE;
  if (GetCapture() == overlay || GetCapture() == editor)
    ReleaseCapture();
  if (overlay)
    DestroyWindow(overlay);
  mc_style_controls_destroy(capture.style_controls);
  capture.style_controls = NULL;
  if (editor)
    DestroyWindow(editor);
  if (capture.session > 0)
    image_session_dispose(capture.session);
  if (capture.style_bank > 0)
    editor_style_dispose(capture.style_bank);
  surface_free(&capture.desktop);
  surface_free(&capture.dimmed);
  surface_free(&capture.image);
  surface_free(&capture.rendered);
  if (capture.font)
    DeleteObject(capture.font);
  if (capture.text_font)
    DeleteObject(capture.text_font);
  ZeroMemory(&capture, sizeof(capture));
  if (services.set_pins_hidden)
    services.set_pins_hidden(services.context, FALSE);
}
bool mc_capture_handle_message(MSG *message) {
  if (!capture.editor || (message->hwnd != capture.editor && !IsChild(capture.editor, message->hwnd)))
    return false;
  if (message->message >= WM_MOUSEFIRST && message->message <= WM_MOUSELAST)
    SendMessageW(capture.tooltip, TTM_RELAYEVENT, 0, (LPARAM)message);
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
      image_session_update_rgba(capture.session, capture.selected, r.left, r.top, r.right - r.left,
                                r.bottom - r.top,
                                (int)image_session_value(capture.session, capture.selected, 5),
                                (int)image_session_value(capture.session, capture.selected, 6),
                                (int)image_session_value(capture.session, capture.selected, 7),
                                image_session_value(capture.session, capture.selected, 8));
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
      load_tool_style(capture.tool);
      changed();
      return true;
    }
  }
  if (GetFocus() == capture.text)
    return false;
  return IsDialogMessageW(capture.editor, message) != FALSE;
}
/* Optional CI diagnostic. Print only our synthetic image and native controls.
 * Briefly show this fixture without activation so the real themed paint path runs,
 * independently of hidden-ancestor WM_PRINT behavior.
 * There is no screen DC, desktop capture, or substitute text painted by the test. */
static BOOL save_capture_preview(void) {
  wchar_t path[32768];
  DWORD length = GetEnvironmentVariableW(L"MOOJICUT_SMOKE_SCREENSHOT", path, ARRAYSIZE(path));
  if (!length)
    return TRUE;
  if (length >= ARRAYSIZE(path) - 16 || !capture.smoke)
    return FALSE;
  wcscat_s(path, ARRAYSIZE(path), L".capture.bmp");
  RECT client;
  GetClientRect(capture.editor, &client);
  Surface preview = {0};
  if (!surface_new(&preview, client.right, client.bottom))
    return FALSE;
  ShowWindow(capture.editor, SW_SHOWNOACTIVATE);
  RedrawWindow(capture.editor, NULL, NULL, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
  BOOL printed = PrintWindow(capture.editor, preview.dc, PW_CLIENTONLY);
  ShowWindow(capture.editor, SW_HIDE);
  GdiFlush();
  if (!printed) {
    surface_free(&preview);
    return FALSE;
  }
  BITMAPFILEHEADER file_header = {0};
  BITMAPINFOHEADER info = {0};
  DWORD bytes = (DWORD)preview.width * (DWORD)preview.height * 4, written;
  info.biSize = sizeof(info);
  info.biWidth = preview.width;
  info.biHeight = -preview.height;
  info.biPlanes = 1;
  info.biBitCount = 32;
  info.biCompression = BI_RGB;
  info.biSizeImage = bytes;
  file_header.bfType = 0x4d42;
  file_header.bfOffBits = sizeof(file_header) + sizeof(info);
  file_header.bfSize = file_header.bfOffBits + bytes;
  HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  BOOL ok = FALSE;
  if (file != INVALID_HANDLE_VALUE) {
    ok = WriteFile(file, &file_header, sizeof(file_header), &written, NULL) &&
         written == sizeof(file_header) && WriteFile(file, &info, sizeof(info), &written, NULL) &&
         written == sizeof(info) && WriteFile(file, preview.pixels, bytes, &written, NULL) &&
         written == bytes;
    CloseHandle(file);
  }
  surface_free(&preview);
  return ok;
}
static BOOL style_visible(int control) {
  HWND window = mc_style_controls_window(capture.style_controls, control);
  return window && (GetWindowLongPtrW(window, GWL_STYLE) & WS_VISIBLE) != 0;
}
static BOOL choose_style(int field, double value) {
  return mc_style_controls_choose(capture.style_controls, field, value);
}
static void step_style(BOOL increase) {
  HWND button = mc_style_controls_window(capture.style_controls,
      increase ? MC_STYLE_CONTROL_INCREASE : MC_STYLE_CONTROL_DECREASE);
  SendMessageW(capture.editor, WM_COMMAND, MAKEWPARAM(GetDlgCtrlID(button), BN_CLICKED), (LPARAM)button);
}
static BOOL context_toolbar_smoke(void) {
  RECT initial = capture.toolbar;
  if (style_visible(MC_STYLE_CONTROL_COLOR) || style_visible(MC_STYLE_CONTROL_FONT) ||
      style_visible(MC_STYLE_CONTROL_STROKE))
    return FALSE;
  editor_command(ID_TEXT);
  if (!style_visible(MC_STYLE_CONTROL_COLOR) || !style_visible(MC_STYLE_CONTROL_FONT) ||
      !style_visible(MC_STYLE_CONTROL_INCREASE) || !style_visible(MC_STYLE_CONTROL_DECREASE) ||
      style_visible(MC_STYLE_CONTROL_STROKE) || capture.font_size != 32)
    return FALSE;
  if (!choose_style(MC_STYLE_COLOR, 0x246BFD) || !choose_style(MC_STYLE_OPACITY, .5))
    return FALSE;
  editor_command(ID_RECT);
  if (!style_visible(MC_STYLE_CONTROL_COLOR) || !style_visible(MC_STYLE_CONTROL_STROKE) ||
      style_visible(MC_STYLE_CONTROL_FONT) || !style_visible(MC_STYLE_CONTROL_INCREASE) ||
      capture.color != 0xF26769 || capture.opacity != 1)
    return FALSE;
  if (!choose_style(MC_STYLE_STROKE, 8) || !choose_style(MC_STYLE_COLOR, 0x25A56A) ||
      !choose_style(MC_STYLE_OPACITY, .3))
    return FALSE;
  step_style(TRUE);
  if (capture.stroke != 9)
    return FALSE;
  step_style(FALSE);
  if (capture.stroke != 8)
    return FALSE;
  editor_command(ID_ARROW);
  if (capture.color != 0xF26769 || capture.opacity != 1 || capture.stroke != 4)
    return FALSE;
  if (!choose_style(MC_STYLE_COLOR, 0xFFFFFF) || !choose_style(MC_STYLE_OPACITY, .8))
    return FALSE;
  editor_command(ID_REDACT);
  if (!style_visible(MC_STYLE_CONTROL_COLOR) || !style_visible(MC_STYLE_CONTROL_OPACITY) ||
      style_visible(MC_STYLE_CONTROL_FONT) || style_visible(MC_STYLE_CONTROL_STROKE) ||
      capture.color != 0x111111 || capture.opacity != 1)
    return FALSE;
  if (!choose_style(MC_STYLE_COLOR, 0x25A56A) || !choose_style(MC_STYLE_OPACITY, .2))
    return FALSE;
  editor_command(ID_TEXT);
  if (capture.color != 0x246BFD || capture.opacity != .5)
    return FALSE;
  editor_command(ID_RECT);
  if (capture.color != 0x25A56A || capture.opacity != .3 || capture.stroke != 8)
    return FALSE;
  editor_command(ID_ARROW);
  if (capture.color != 0xFFFFFF || capture.opacity != .8)
    return FALSE;
  editor_command(ID_REDACT);
  if (capture.color != 0x25A56A || capture.opacity != .2)
    return FALSE;
  // Restore the drawing defaults before the existing geometry/export fixture.
  for (int tool = TOOL_RECT; tool <= TOOL_REDACT; tool++) {
    editor_command(ID_SELECT + tool);
    unsigned mask = (unsigned)editor_style_property_mask(tool);
    for (int field = 0; field < 4; field++)
      if ((mask & (1u << field)) && !choose_style(field,
          tool == TOOL_REDACT && field == MC_STYLE_COLOR ? 0x111111 : editor_style_default(field)))
        return FALSE;
  }
  for (int i = 10; i < 12; i++) {
    if (IsWindowEnabled(capture.buttons[i]))
      return FALSE;
    RECT button;
    GetWindowRect(capture.buttons[i], &button);
    POINT point = {(button.left + button.right) / 2, (button.top + button.bottom) / 2};
    ScreenToClient(capture.editor, &point);
    TTHITTESTINFOW hit = {0};
    hit.hwnd = capture.editor;
    hit.pt = point;
    hit.ti.cbSize = sizeof(hit.ti);
    if (!SendMessageW(capture.tooltip, TTM_HITTESTW, 0, (LPARAM)&hit) ||
        hit.ti.uId != (UINT_PTR)button_ids[i])
      return FALSE;
    wchar_t label[128] = {0};
    TOOLINFOW tip = {sizeof(tip)};
    tip.hwnd = capture.editor;
    tip.uId = button_ids[i];
    tip.lpszText = label;
    SendMessageW(capture.tooltip, TTM_GETTEXTW, ARRAYSIZE(label), (LPARAM)&tip);
    if (!wcsstr(label, L"尚未开放"))
      return FALSE;
  }
  editor_command(ID_SELECT);
  return EqualRect(&initial, &capture.toolbar) && !style_visible(MC_STYLE_CONTROL_COLOR) &&
         !style_visible(MC_STYLE_CONTROL_FONT);
}
static BOOL independent_text_style_smoke(void) {
  editor_command(ID_TEXT);
  if (!choose_style(MC_STYLE_COLOR, 0x246BFD) || !choose_style(MC_STYLE_OPACITY, .5) ||
      !choose_style(MC_STYLE_FONT, 40))
    return FALSE;
  begin_text((POINT){50, 70}, -1);
  SetWindowTextW(capture.text, L"独立文字样式");
  step_style(TRUE); // A new draft updates the text tool's remembered default.
  if (capture.font_size != 41 || !finish_text(FALSE))
    return FALSE;
  int index = capture.selected;
  begin_text((POINT){50, 70}, index);
  if (!choose_style(MC_STYLE_COLOR, 0xFFFFFF) || !choose_style(MC_STYLE_OPACITY, .8) ||
      !choose_style(MC_STYLE_FONT, 60) || !finish_text(FALSE))
    return FALSE;
  // Selected-but-not-editing style changes follow the same isolation rule.
  step_style(TRUE);
  if (image_session_value(capture.session, index, 7) != 61 ||
      !image_session_undo(capture.session) || image_session_value(capture.session, index, 7) != 60)
    return FALSE;
  load_annotation_style(index);
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(600, 400));
  if (capture.selected != -1 || capture.color != 0x246BFD || capture.opacity != .5 || capture.font_size != 41)
    return FALSE;
  editor_command(ID_RECT);
  if (capture.color != 0xF26769 || capture.opacity != 1 || capture.stroke != 4)
    return FALSE;
  editor_command(ID_TEXT);
  if (capture.color != 0x246BFD || capture.opacity != .5 || capture.font_size != 41 ||
      image_session_value(capture.session, index, 5) != 0xFFFFFF ||
      image_session_value(capture.session, index, 8) != .8 ||
      image_session_value(capture.session, index, 7) != 60)
    return FALSE;
  begin_text((POINT){150, 80}, -1);
  if (capture.color != 0x246BFD || capture.opacity != .5 || capture.font_size != 41)
    return FALSE;
  // Cancelling the draft cannot change the existing annotation or its style.
  if (!finish_text(TRUE) || image_session_count(capture.session) != 1 ||
      image_session_value(capture.session, index, 5) != 0xFFFFFF)
    return FALSE;
  if (!choose_style(MC_STYLE_COLOR, editor_style_default(MC_STYLE_COLOR)) ||
      !choose_style(MC_STYLE_OPACITY, editor_style_default(MC_STYLE_OPACITY)) ||
      !choose_style(MC_STYLE_FONT, editor_style_default(MC_STYLE_FONT)) ||
      image_session_value(capture.session, index, 7) != 60 ||
      image_session_value(capture.session, index, 5) != 0xFFFFFF ||
      image_session_value(capture.session, index, 8) != .8)
    return FALSE;
  image_session_remove(capture.session, index);
  editor_command(ID_SELECT);
  return image_session_count(capture.session) == 0;
}
typedef struct {
  BOOL accept, valid_image;
  int attempts, accepted, hidden, restored, x, y, width, height;
} CaptureHostSmoke;
static BOOL smoke_pin_image(void *context, HGLOBAL dib, int x, int y) {
  CaptureHostSmoke *host = context;
  host->attempts++;
  host->x = x;
  host->y = y;
  BITMAPINFOHEADER *info = GlobalLock(dib);
  host->valid_image = info && info->biSize == sizeof(*info) && info->biBitCount == 24;
  if (info) {
    host->width = info->biWidth;
    host->height = abs(info->biHeight);
    GlobalUnlock(dib);
  }
  if (!host->accept)
    return FALSE; // Caller retains ownership and must remain editable.
  host->accepted++;
  GlobalFree(dib); // Successful receiver owns this flattened image.
  return TRUE;
}
static void smoke_pins_hidden(void *context, BOOL hidden) {
  CaptureHostSmoke *host = context;
  if (hidden)
    host->hidden++;
  else
    host->restored++;
}
int mc_capture_smoke(HINSTANCE instance) {
  int result = 1;
  HGLOBAL dib = NULL;
  CaptureHostSmoke host = {0};
  ZeroMemory(&capture, sizeof(capture));
  capture.instance = instance;
  capture.smoke = TRUE;
  capture.host = (MCCaptureHost){&host, smoke_pin_image, smoke_pins_hidden};
  set_pins_hidden(TRUE);
  SetRect(&capture.desktop_bounds, 0, 0, 640, 480);
  if (!mc_selection_smoke() || !register_windows(instance) || !surface_new(&capture.desktop, 640, 480) ||
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
  if (!mc_style_controls_smoke(instance) || !context_toolbar_smoke() || !independent_text_style_smoke())
    goto cleanup;
  if (image_session_add(capture.session, TOOL_REDACT, 40, 60, 80, 60, 0, 4) != 1)
    goto cleanup;
  begin_text((POINT){50, 70}, -1);
  SetWindowTextW(capture.text, L"截图测试 MoonBit\r\n第二行");
  int initial_font = capture.font_size;
  SendMessageW(capture.editor, WM_COMMAND, MAKEWPARAM(ID_OCR, BN_CLICKED), 0);
  SendMessageW(capture.editor, WM_COMMAND, MAKEWPARAM(ID_TRANSLATE, BN_CLICKED), 0);
  if (!capture.editor || capture.editing != -1 || image_session_count(capture.session) != 1)
    goto cleanup;
  step_style(TRUE);
  if (capture.font_size != initial_font + 1 || image_session_count(capture.session) != 1)
    goto cleanup;
  step_style(FALSE);
  if (capture.font_size != initial_font || !style_visible(MC_STYLE_CONTROL_FONT) || style_visible(MC_STYLE_CONTROL_STROKE))
    goto cleanup;

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
  // Covers blend once, including blank areas of an active native text box.
  if (!image_session_add_rgba(capture.session, TOOL_REDACT, 230, 130, 80, 50, 0x204080, 4, 24, .5))
    goto cleanup;
  begin_text((POINT){150, 100}, index);
  changed();
  if (!render_image())
    goto cleanup;
  BYTE *blend = capture.rendered.pixels + ((SIZE_T)150 * capture.image.width + 280) * 4;
  if (blend[0] != 104 || blend[1] != 112 || blend[2] != 126)
    goto cleanup;
  if (!finish_text(FALSE) || !render_image())
    goto cleanup;
  blend = capture.rendered.pixels + ((SIZE_T)150 * capture.image.width + 280) * 4;
  if (blend[0] != 104 || blend[1] != 112 || blend[2] != 126)
    goto cleanup;
  capture.selected = index;
  capture.opacity = .4;
  apply_style();
  if (image_session_value(capture.session, index, 8) != .4)
    goto cleanup;
  begin_text((POINT){150, 100}, index);
  if (capture.opacity != .4 || !finish_text(FALSE) || image_session_value(capture.session, index, 8) != .4)
    goto cleanup;
  capture.opacity = 1;
  apply_style();
  image_session_remove(capture.session, image_session_count(capture.session) - 1);
  // Font changes must resize the box and leave visible pixels in the exported image.
  set_session_text(L"A", 1);
  if (!image_session_add_rgba(capture.session, TOOL_TEXT, 170, 30, 140, 72, 0xF26769, 4, 24, 1))
    goto cleanup;
  capture.selected = image_session_count(capture.session) - 1;
  capture.color = 0xF26769;
  capture.stroke = 4;
  sync_style_controls();
  if (!choose_style(MC_STYLE_FONT, 128))
    goto cleanup;
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
  // Keep the optional visual fixture readable after the large-font regression.
  image_session_remove(capture.session, capture.selected);
  capture.selected = index;
  capture.tool = TOOL_TEXT;
  capture.color = (int)image_session_value(capture.session, index, 5);
  capture.opacity = image_session_value(capture.session, index, 8);
  capture.stroke = (int)image_session_value(capture.session, index, 6);
  capture.font_size = (int)image_session_value(capture.session, index, 7);
  sync_style_controls();
  layout_editor(capture.editor);
  // Separate visual fixture after pixel assertions; no desktop content is used.
  for (int y = 0; y < capture.image.height; y++)
    for (int x = 0; x < capture.image.width; x++) {
      BYTE *pixel = capture.image.pixels + ((SIZE_T)y * capture.image.width + x) * 4;
      double fx = (double)x / capture.image.width, fy = (double)y / capture.image.height;
      pixel[0] = (BYTE)(65 + fx * 26 + fy * 10);
      pixel[1] = (BYTE)(43 + fy * 37);
      pixel[2] = (BYTE)(40 + fx * 25);
      pixel[3] = 0;
      for (int c = 0; c < 3; c++)
        capture.dimmed.pixels[((SIZE_T)y * capture.image.width + x) * 4 + c] = (BYTE)(pixel[c] * .55);
    }
  image_session_crop(capture.session, 70, 50, 500, 270);
  sync_viewport();
  layout_editor(capture.editor);
  changed();
  if (!save_capture_preview())
    goto cleanup;
  editor_command(ID_PIN);
  if (host.attempts != 1 || host.accepted || host.restored || !mc_capture_busy() || !host.valid_image)
    goto cleanup;
  host.accept = TRUE;
  editor_command(ID_PIN);
  if (host.attempts != 2 || host.accepted != 1 || host.hidden != 1 || host.restored != 1 ||
      host.x != 70 || host.y != 50 || host.width != 500 || host.height != 270 || mc_capture_busy())
    goto cleanup;
  result = 0;
cleanup:
  if (dib)
    GlobalFree(dib);
  mc_capture_close();
  printf("Windows screenshot smoke: %s (synthetic frozen overlay, inline multiline edit, style undo/redo, "
         "independent tool styles, isolated text edits, cropped DIB, RGBA blend, "
         "host image ownership and visibility callbacks; clipboard untouched).\n",
         result ? "FAILED" : "passed");
  return result;
}
