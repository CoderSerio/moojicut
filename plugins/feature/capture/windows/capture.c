#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include "capture.h"
#include "bindings/c/image_session.h"
#include "bindings/c/capture_edit.h"
#include "bindings/c/capture_toolbar.h"
#include "platform/windows/graphics/text_input.h"
#include "platform/windows/graphics/shared_canvas.h"
#include "bindings/c/capture_ui.h"
#include "bindings/c/tool_registry.h"
#include "platform/shared/image/pixelate.h"
#include "components/hud/windows/hud.h"
#include "bindings/c/editor_style.h"
#include "moonbit.h"
#include "plugins/feature/select/windows/selection.h"
#include "plugins/feature/select/windows/surface.h"
#include <commctrl.h>
#include <commdlg.h>
#include <oleacc.h>
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
  ID_UNDO = 8105,
  ID_REDO,
  ID_COPY,
  ID_CANCEL
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
  HWND owner, overlay, editor, text, toolbar_view, text_properties;
  MCWinTextInputs *body_inputs, *property_inputs;
  int32_t text_edit;
  int text_index;
  BOOL text_syncing, text_finishing, color_picker;
  int32_t toolbar_session, toolbar_frame, toolbar_generation, prepared_toolbar;
  BOOL toolbar_dispatching, toolbar_syncing, toolbar_dark;
  MCCaptureHost host;
  HFONT font, text_font;
  HBRUSH text_background;
  unsigned render_serial, brush_serial;
  BOOL rendered_draft;
  Surface desktop, dimmed, image, rendered;
  RECT desktop_bounds, canvas, viewport, toolbar, drag_bounds, draft;
  POINT start, end;
  double zoom, opacity, font_size, stroke;
  int32_t session, style_bank, tool_snapshot, owned_tools;
  moonbit_string_t drag_id;
  double drag_revision;
  int tool, color, selected, editing, drag_mode, handle, shape, block;
  BOOL dragging, dirty, smoke, closing, composing;
} Capture;
static Capture capture;
static int32_t configured_tools, prepared_tools;
static void layout_editor(HWND window);
static BOOL finish_text(BOOL cancel);
static void style_text(void);
static void sync_text_preview(void);
static void refresh_text_frames(int x, int y, double scale);
static BOOL ensure_property_edit(void);
static int property_tool(void);
static BOOL text_field_event(void *context, HWND field, moonbit_string_t event);
static void text_field_action(void *context, HWND field, int action);
static void text_property_event(void *context, HWND window, const MCCanvasInput *event);
static BOOL text_field_key(void *context, HWND field, const MCCanvasInput *event);
static HBRUSH text_background(void *context, HWND field, HDC target);
#define TEXT_FIELD_ACTION (WM_APP + 0x725)
#define TOOLBAR_FOCUS_CHANGED (WM_APP + 0x726)
static BOOL toolbar_context(void);
static void toolbar_input(void *context, HWND window, const MCCanvasInput *input);
static BOOL toolbar_activate(const wchar_t *id);
static void toolbar_sync_native(void);
static BOOL custom_drag(void) {
  return capture.toolbar_session && capture_toolbar_value(capture.toolbar_session,
      MC_CAPTURE_TOOLBAR_INTERACTION) == MC_TOOL_INTERACTION_DRAG_RECT;
}
static const wchar_t *EDITOR_CLASS = L"MoojiCut.Capture.Editor";
static BOOL pin_enabled(void) {
  return !capture.host.pin_enabled || capture.host.pin_enabled(capture.host.context);
}
static int tool_capabilities(void) {
  return MC_TOOL_CAP_COMMANDS | (capture.host.on_user_tool ? MC_TOOL_CAP_USER : 0);
}
void mc_capture_refresh_capabilities(void) {
  if (capture.editor && capture.toolbar_session) layout_editor(capture.editor);
}
BOOL mc_capture_plugin_result(int32_t image_session, BOOL document_changed) {
  if (image_session <= 0 || image_session != capture.session || !capture.editor || capture.closing) return FALSE;
  if (document_changed) toolbar_sync_native();
  return TRUE;
}
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
                            double scale, int offset_x, int offset_y, int shape) {
  int left = offset_x + rounded(x * scale), top = offset_y + rounded(y * scale);
  int right = offset_x + rounded((x + width) * scale), bottom = offset_y + rounded((y + height) * scale);
  int thickness = maximum(1, rounded(stroke * scale));
  HPEN pen = CreatePen(PS_SOLID, thickness, color_ref(color));
  HGDIOBJ prior_pen = SelectObject(dc, pen), prior_brush = SelectObject(dc, GetStockObject(HOLLOW_BRUSH));
  if (kind == TOOL_RECT) {
    if (shape == 1) Ellipse(dc, left, top, right, bottom);
    else Rectangle(dc, left, top, right, bottom);
  }
  else if (kind == TOOL_ARROW) {
    if (hypot(width, height) > 0.5) {
      POINT wings[3];
      wings[0].x = offset_x + rounded(image_arrowhead_value(x, y, x + width, y + height, stroke, 0) * scale);
      wings[0].y = offset_y + rounded(image_arrowhead_value(x, y, x + width, y + height, stroke, 1) * scale);
      wings[1].x = right;
      wings[1].y = bottom;
      wings[2].x = offset_x + rounded(image_arrowhead_value(x, y, x + width, y + height, stroke, 2) * scale);
      wings[2].y = offset_y + rounded(image_arrowhead_value(x, y, x + width, y + height, stroke, 3) * scale);
      MoveToEx(dc, left, top, NULL);
      LineTo(dc, right, bottom);
      Polyline(dc, wings, 3);
    }
  } else if (kind == TOOL_REDACT) {
    RECT rect = {left, top, right, bottom};
    HBRUSH fill = CreateSolidBrush(color_ref(color));
    if (shape == 1) {
      HGDIOBJ old = SelectObject(dc, fill), edge = SelectObject(dc, GetStockObject(NULL_PEN));
      Ellipse(dc, left, top, right, bottom);
      SelectObject(dc, edge); SelectObject(dc, old);
    } else FillRect(dc, &rect, fill);
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
                             const wchar_t *text, int length, double font, double opacity, int shape, int block) {
  if (kind == TOOL_REDACT && shape == 2) {
    GdiFlush();
    mc_pixelate_bgra(capture.rendered.pixels, capture.rendered.width, capture.rendered.height,
      capture.rendered.width * 4, (int)floor(x), (int)floor(y),
      (int)ceil(x + w) - (int)floor(x), (int)ceil(y + h) - (int)floor(y), block);
    return TRUE;
  }
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
  draw_annotation(mask.dc, kind, x, y, w, h, 0xffffff, stroke, text, length, font, 1, -left, -top, shape);
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
static BOOL render_image_mode(BOOL include_input) {
  int pass, i, count;
  if (!capture.session || !capture.image.dc)
    return FALSE;
  if (!capture.rendered.dc && !surface_new(&capture.rendered, capture.image.width, capture.image.height))
    return FALSE;
  if (!capture.dirty && capture.rendered_draft == include_input)
    return TRUE;
  capture.rendered_draft = include_input; capture.render_serial++;
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
      if (capture.text_edit && i == capture.text_index && property_tool() != TOOL_TEXT) {
        if (!blend_annotation(property_tool(),
            capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_X),
            capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_Y),
            capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_WIDTH),
            capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_HEIGHT),
            capture.color, capture.stroke, NULL, 0, capture.font_size, capture.opacity, capture.shape, capture.block)) return FALSE;
        continue;
      }
      if (i == capture.editing || (capture.text_edit && i == capture.text_index))
        continue;
      if (kind == TOOL_TEXT)
        text = image_session_text(capture.session, i);
      BOOL moving = capture.dragging && capture.drag_mode == 1 && capture.selected == i;
      RECT draft = capture.draft;
      double font_size = image_session_value(capture.session, i, 7);
      if (moving &&
          (capture.handle == 0 || capture.handle == 2 || capture.handle == 4 || capture.handle == 6))
        font_size = fmin(editor_style_max(MC_STYLE_FONT), fmax(editor_style_min(MC_STYLE_FONT),
            font_size * (draft.right - draft.left) / maximum(1, capture.drag_bounds.right - capture.drag_bounds.left)));
      BOOL painted = blend_annotation(
          kind, moving ? draft.left : image_session_value(capture.session, i, 1),
          moving ? draft.top : image_session_value(capture.session, i, 2),
          moving ? draft.right - draft.left : image_session_value(capture.session, i, 3),
          moving ? draft.bottom - draft.top : image_session_value(capture.session, i, 4),
          (int)image_session_value(capture.session, i, 5), image_session_value(capture.session, i, 6),
          (const wchar_t *)text, text ? Moonbit_array_length(text) : 0, font_size,
          image_session_value(capture.session, i, 8),
          (int)image_session_value(capture.session, i, 9), (int)image_session_value(capture.session, i, 10));
      if (text)
        moonbit_decref(text);
      if (!painted)
        return FALSE;
    }
    if (pass == 0 && capture.text_edit && property_tool() == TOOL_TEXT &&
        capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_MODE) != MC_CAPTURE_TEXT_DEFAULTS &&
        (include_input || capture.editing == -2)) {
      moonbit_string_t raw = capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RAW);
      RECT r = capture.draft;
      BOOL painted = blend_annotation(TOOL_TEXT, r.left, r.top, r.right - r.left, r.bottom - r.top,
          capture.color, capture.stroke, (const wchar_t *)raw, Moonbit_array_length(raw), capture.font_size, capture.opacity, 0, 12);
      moonbit_decref(raw); if (!painted) return FALSE;
    }
    if (capture.dragging && capture.drag_mode == 0) {
      int kind = (int)image_session_preview_value(capture.session, 0);
      if (kind && (kind == TOOL_REDACT) == (pass == 1)) {
        double r[10];
        for (int field = 0; field < 10; field++) r[field] = image_session_preview_value(capture.session, field + 1);
        if (!blend_annotation(kind, r[0], r[1], r[2], r[3], (int)r[4], r[5], NULL, 0,
                              r[6], r[7], (int)r[8], (int)r[9])) return FALSE;
      }
    }
  }
  GdiFlush();
  capture.dirty = FALSE;
  return TRUE;
}

static BOOL render_image(void) { return render_image_mode(TRUE); }
static HBRUSH text_background(void *context, HWND field, HDC target) {
  (void)context;
  if (field != capture.text || !render_image_mode(FALSE)) return (HBRUSH)GetStockObject(HOLLOW_BRUSH);
  if (!capture.text_background || capture.brush_serial != capture.render_serial) {
    HBRUSH brush = CreatePatternBrush(capture.rendered.bitmap);
    if (brush) { if (capture.text_background) DeleteObject(capture.text_background); capture.text_background = brush; capture.brush_serial = capture.render_serial; }
  }
  POINT origin = {0, 0}; MapWindowPoints(field, capture.editor, &origin, 1);
  SetBrushOrgEx(target, -origin.x, -origin.y, NULL);
  return capture.text_background;
}

static HGLOBAL rendered_dib(RECT viewport) {
  SIZE_T stride, bytes;
  HGLOBAL memory;
  BITMAPINFOHEADER *header;
  BYTE *out;
  int x, y;
  int width = viewport.right - viewport.left,
      height = viewport.bottom - viewport.top;
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
        ((SIZE_T)(y + viewport.top) * capture.image.width + viewport.left) * 4;
    BYTE *row = out + (SIZE_T)(height - 1 - y) * stride;
    for (x = 0; x < width; x++)
      memcpy(row + (SIZE_T)x * 3, source + (SIZE_T)x * 4, 3);
  }
  GlobalUnlock(memory);
  return memory;
}

static HGLOBAL image_dib(void) {
  return render_image() ? rendered_dib(capture.viewport) : NULL;
}
static HGLOBAL candidate_dib(int32_t candidate) {
  int count = capture_candidate_count(candidate);
  if (count < 0) return NULL;
  if (!capture.rendered.dc && !surface_new(&capture.rendered, capture.image.width, capture.image.height)) return NULL;
  BitBlt(capture.rendered.dc, 0, 0, capture.image.width, capture.image.height, capture.image.dc, 0, 0, SRCCOPY);
  GdiFlush(); capture.dirty = TRUE; // Candidate pixels are not the live renderer's cache.
  for (int pass = 0; pass < 2; pass++) for (int i = 0; i < count; i++) {
    int kind = (int)capture_candidate_value(candidate, i, 0);
    if ((kind == TOOL_REDACT) != (pass == 1)) continue;
    moonbit_string_t text = kind == TOOL_TEXT ? capture_candidate_text(candidate, i) : NULL;
    BOOL ok = blend_annotation(kind, capture_candidate_value(candidate,i,1), capture_candidate_value(candidate,i,2),
        capture_candidate_value(candidate,i,3), capture_candidate_value(candidate,i,4),
        (int)capture_candidate_value(candidate,i,5), capture_candidate_value(candidate,i,6),
        (const wchar_t *)text, text ? Moonbit_array_length(text) : 0, capture_candidate_value(candidate,i,7),
        capture_candidate_value(candidate,i,8), (int)capture_candidate_value(candidate,i,9),
        (int)capture_candidate_value(candidate,i,10));
    if (text) moonbit_decref(text);
    if (!ok) return NULL;
  }
  GdiFlush();
  RECT viewport;
  viewport.left = rounded(capture_candidate_viewport_value(candidate,0));
  viewport.top = rounded(capture_candidate_viewport_value(candidate,1));
  viewport.right = viewport.left + rounded(capture_candidate_viewport_value(candidate,2));
  viewport.bottom = viewport.top + rounded(capture_candidate_viewport_value(candidate,3));
  return rendered_dib(viewport);
}
static BOOL copy_image(void) {
  HGLOBAL dib = image_dib();
  BOOL success = FALSE;
  if (!dib) return FALSE;
  if (OpenClipboard(capture.editor)) {
    if (EmptyClipboard() && SetClipboardData(CF_DIB, dib)) { dib = NULL; success = TRUE; }
    CloseClipboard();
  }
  if (dib) GlobalFree(dib);
  return success;
}

/* Style context follows an active text draft/selection before the current drawing tool. */
static int style_context(void) {
  if (capture.editing != -2) return TOOL_TEXT;
  if (capture.selected >= 0) return (int)image_session_value(capture.session, capture.selected, 0);
  return capture.tool;
}
static int text_version(void) {
  return (int)capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_VERSION);
}
static int find_annotation_id(moonbit_string_t id) {
  for (int i = 0; i < image_session_count(capture.session); i++) {
    moonbit_string_t current = image_session_annotation_id(capture.session, i);
    BOOL equal = Moonbit_array_length(id) == Moonbit_array_length(current) &&
      !memcmp(id, current, (size_t)Moonbit_array_length(id) * sizeof(uint16_t));
    moonbit_decref(current); if (equal) return i;
  }
  return -1;
}
static int property_tool(void) {
  return capture.text_edit ? (int)capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_TOOL) : 0;
}
static BOOL ensure_property_edit(void) {
  if (capture.text_edit) return TRUE;
  int tool = style_context();
  if (capture.text_finishing || capture.dragging || !capture.session || !capture.style_bank || tool == TOOL_SELECT) return FALSE;
  int index = capture.selected;
  moonbit_string_t id = index >= 0 ? image_session_annotation_id(capture.session, index) : moonbit_make_string_raw(0);
  if (tool == TOOL_TEXT) capture.text_edit = capture_text_begin(capture.session, capture.style_bank,
      index >= 0 ? MC_CAPTURE_TEXT_EXISTING : MC_CAPTURE_TEXT_DEFAULTS,
      id, image_session_revision(capture.session), 0, 0, 1, 1);
  else {
    moonbit_string_t command = index < 0 && custom_drag() ?
      capture_toolbar_text(capture.toolbar_session, MC_CAPTURE_TOOLBAR_COMMAND) : moonbit_make_string_raw(0);
    capture.text_edit = capture_properties_begin(capture.session, capture.style_bank, tool,
        id, image_session_revision(capture.session), command);
    moonbit_decref(command);
  }
  moonbit_decref(id); capture.text_index = index;
  if (capture.text_edit) sync_text_preview();
  return capture.text_edit > 0;
}
static void sync_text_preview(void) {
  if (!capture.text_edit) return;
  capture.color = (int)capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RGB);
  capture.opacity = capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_OPACITY);
  capture.font_size = capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_FONT_SIZE);
  capture.stroke = capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_STROKE);
  capture.shape = (int)capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_SHAPE);
  capture.block = (int)capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_BLOCK);
  if (capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_MODE) != MC_CAPTURE_TEXT_DEFAULTS) {
    capture.draft.left = rounded(capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_X));
    capture.draft.top = rounded(capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_Y));
    capture.draft.right = capture.draft.left + rounded(capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_WIDTH));
    capture.draft.bottom = capture.draft.top + rounded(capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_HEIGHT));
  }
  capture.composing = mc_win_text_inputs_composing(capture.body_inputs) || mc_win_text_inputs_composing(capture.property_inputs);
}
static void sync_properties(void) {
  ensure_property_edit();
}
static void load_tool_style(int tool) {
  capture.color = rounded(editor_style_get(capture.style_bank, tool, MC_STYLE_COLOR));
  capture.opacity = editor_style_get(capture.style_bank, tool, MC_STYLE_OPACITY);
  capture.stroke = editor_style_get(capture.style_bank, tool, MC_STYLE_STROKE);
  capture.font_size = editor_style_get(capture.style_bank, tool, MC_STYLE_FONT);
  capture.shape = rounded(editor_style_get(capture.style_bank, tool, MC_STYLE_SHAPE));
  capture.block = rounded(editor_style_get(capture.style_bank, tool, MC_STYLE_BLOCK));
  sync_properties();
}
static void load_annotation_style(int index) {
  capture.color = rounded(image_session_value(capture.session, index, 5));
  capture.opacity = image_session_value(capture.session, index, 8);
  capture.stroke = image_session_value(capture.session, index, 6);
  capture.font_size = image_session_value(capture.session, index, 7);
  capture.shape = rounded(image_session_value(capture.session, index, 9));
  capture.block = rounded(image_session_value(capture.session, index, 10));
  sync_properties();
}
static void changed(void) {
  sync_properties();
  if (capture.editor) layout_editor(capture.editor);
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
  if (!window || capture.toolbar_syncing) return;
  capture.toolbar_syncing = TRUE;
  RECT client; GetClientRect(window, &client);
  if (client.right<=0 || client.bottom<=0) { capture.toolbar_syncing=FALSE; return; }
  sync_properties();
  double scale = (double)GetDpiForWindow(window) / 96;
  int32_t surface = capture_toolbar_surface_color(capture.toolbar_dark);
  mc_win_canvas_set_background(capture.toolbar_view, surface);
  mc_win_canvas_set_background(capture.text_properties, surface);
  if (capture.toolbar_session && toolbar_context()) {
    double max_width = fmax(32, client.right / scale - 24);
    moonbit_string_t json = capture_toolbar_frame(capture.toolbar_session, max_width, capture.toolbar_dark);
    int32_t frame_id = ui_frame_open(json); moonbit_decref(json);
    double width = capture_toolbar_value(capture.toolbar_session, MC_CAPTURE_TOOLBAR_WIDTH);
    double height = capture_toolbar_value(capture.toolbar_session, MC_CAPTURE_TOOLBAR_HEIGHT);
    double properties = capture.text_edit ? capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_WIDTH) : 0;
    double property_height = capture.text_edit ? capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_HEIGHT) : 0;
    double *frame = capture_ui_measured_toolbar_frame(client.right / scale, client.bottom / scale,
        capture.viewport.left / scale, capture.viewport.top / scale,
        (capture.viewport.right-capture.viewport.left)/scale, (capture.viewport.bottom-capture.viewport.top)/scale,
        fmax(width,properties)+8, height+8+(properties>0 ? property_height+2 : 0));
    int x = rounded(frame[0]*scale), y = rounded(frame[1]*scale);
    SetRect(&capture.toolbar,x,y,x+rounded(frame[2]*scale),y+rounded(frame[3]*scale)); moonbit_decref(frame);
    MoveWindow(capture.toolbar_view,x+dpi_px(window,4),y+dpi_px(window,4),rounded(width*scale),rounded(height*scale),TRUE);
    if (frame_id) {
      if (mc_win_canvas_set_frame(capture.toolbar_view,frame_id)) {
        capture.toolbar_frame=frame_id;
        capture.toolbar_generation=(int32_t)capture_toolbar_value(capture.toolbar_session,MC_CAPTURE_TOOLBAR_GENERATION);
      } else ui_frame_close(frame_id);
    }
    refresh_text_frames(x+dpi_px(window,4),y+rounded((height+6)*scale),scale);
  }
  capture.canvas=capture.viewport; capture.zoom=1;
  capture.toolbar_syncing=FALSE;
  InvalidateRect(window,NULL,FALSE);
}
/* Use the export font and wrapping rules for all live/committed text geometry.
 * Grow height on style/reflow so increasing the font cannot silently hide a line. */
static RECT fit_text_bounds(RECT bounds, double size, const wchar_t *text, int length) {
  HDC dc = CreateCompatibleDC(NULL);
  HFONT font =
      CreateFontW(-rounded(size), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
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
static RECT fit_annotation_bounds(int index, RECT bounds, double size) {
  moonbit_string_t value = image_session_text(capture.session, index);
  bounds = fit_text_bounds(bounds, size, (const wchar_t *)value, Moonbit_array_length(value));
  moonbit_decref(value);
  return bounds;
}
static HRGN cover_region(int origin_x, int origin_y) {
  HRGN result = CreateRectRgn(0, 0, 0, 0);
  for (int i = 0; i < image_session_count(capture.session); i++) {
    if ((int)image_session_value(capture.session, i, 0) != TOOL_REDACT) continue;
    RECT mask = annotation_rect(i);
    HRGN part = (int)image_session_value(capture.session, i, 9) == 1
      ? CreateEllipticRgn(mask.left - origin_x, mask.top - origin_y, mask.right - origin_x, mask.bottom - origin_y)
      : CreateRectRgn(mask.left - origin_x, mask.top - origin_y, mask.right - origin_x, mask.bottom - origin_y);
    CombineRgn(result, result, part, RGN_OR); DeleteObject(part);
  }
  return result;
}
static void style_text(void) {
  if (!capture.text || !capture.text_edit) return;
  RECT r = capture.draft;
  HRGN region = CreateRectRgn(0, 0, r.right - r.left, r.bottom - r.top),
       clip = CreateRectRgn(capture.viewport.left - r.left, capture.viewport.top - r.top,
                            capture.viewport.right - r.left, capture.viewport.bottom - r.top);
  CombineRgn(region, region, clip, RGN_AND);
  DeleteObject(clip);
  clip = cover_region(r.left, r.top);
  CombineRgn(region, region, clip, RGN_DIFF); DeleteObject(clip);
  SetWindowRgn(capture.text, region, TRUE);
  capture.dirty = TRUE;
  if (capture.editor)
    InvalidateRect(capture.editor, NULL, FALSE);
}
static double measure_text(void) {
  if (!capture.text_edit || property_tool() != TOOL_TEXT || capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_MODE) == MC_CAPTURE_TEXT_DEFAULTS) return 0;
  moonbit_string_t raw = capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RAW);
  HDC dc = CreateCompatibleDC(NULL);
  HFONT font = CreateFontW(-rounded(capture.font_size), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  HGDIOBJ previous = SelectObject(dc, font);
  TEXTMETRICW metrics = {0}; GetTextMetricsW(dc, &metrics);
  RECT measured = {0, 0, maximum(1, capture.draft.right - capture.draft.left), 0};
  DrawTextW(dc, (const wchar_t *)raw, Moonbit_array_length(raw), &measured, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
  double height = maximum(metrics.tmHeight, measured.bottom) + 2;
  SelectObject(dc, previous); DeleteObject(font); DeleteDC(dc); moonbit_decref(raw); return height;
}
static BOOL finish_text(BOOL cancel) {
  if (capture.text_finishing) return FALSE;
  if (!capture.text_edit) return TRUE;
  if (!cancel && (!mc_win_text_inputs_flush(capture.body_inputs) || !mc_win_text_inputs_flush(capture.property_inputs))) return FALSE;
  if ((mc_win_text_inputs_composing(capture.body_inputs) || mc_win_text_inputs_composing(capture.property_inputs))) return FALSE;
  int32_t edit = capture.text_edit;
  moonbit_string_t id = capture_text_text(capture.session, edit, MC_CAPTURE_TEXT_ANNOTATION_ID);
  BOOL defaults = capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_MODE) == MC_CAPTURE_TEXT_DEFAULTS;
  BOOL ok = FALSE;
  if (cancel) ok = capture_text_cancel(capture.session, edit, text_version()) == 1;
  else {
    int32_t ticket = capture_text_prepare(capture.session, edit, text_version(), MC_CAPTURE_CANDIDATE_PUBLISH, measure_text());
    if (ticket) { ok = capture_candidate_commit(capture.session, ticket) == 1; capture_candidate_close(ticket); }
  }
  if (!ok) { moonbit_decref(id); layout_editor(capture.editor); return FALSE; }
  capture.text_finishing = TRUE; capture.text_edit = 0; capture.editing = -2; capture.composing = FALSE;
  mc_win_text_inputs_set_frame(capture.body_inputs, 0, 0, 0, 1);
  mc_win_text_inputs_set_frame(capture.property_inputs, 0, 0, 0, 1); capture.text = NULL;
  if (!defaults && !cancel) capture.selected = find_annotation_id(id);
  moonbit_decref(id);
  if (capture.selected >= 0) load_annotation_style(capture.selected); else load_tool_style(capture.tool);
  changed(); capture.text_finishing = FALSE; return TRUE;
}
static void begin_text(POINT point, int index) {
  if (!finish_text(FALSE)) return;
  moonbit_string_t id = index >= 0 ? image_session_annotation_id(capture.session, index) : moonbit_make_string_raw(0);
  if (index < 0) load_tool_style(TOOL_TEXT);
  /* Loading defaults may materialize their property-only transaction. Retire it
   * before opening the actual annotation; no publication is needed. */
  if (capture.text_edit && !finish_text(FALSE)) { moonbit_decref(id); return; }
  double width = minimum(capture.viewport.right, point.x + 280) - point.x;
  double height = minimum(capture.viewport.bottom, point.y + rounded(capture.font_size * 3)) - point.y;
  capture.text_edit = capture_text_begin(capture.session, capture.style_bank,
      index >= 0 ? MC_CAPTURE_TEXT_EXISTING : MC_CAPTURE_TEXT_NEW, id,
      image_session_revision(capture.session), point.x, point.y, width, height);
  moonbit_decref(id);
  if (!capture.text_edit) return;
  capture.text_index = index; capture.editing = index; capture.selected = index;
  sync_text_preview(); changed(); style_text();
  if (capture.text) { SetFocus(capture.text); SendMessageW(capture.text, EM_SETSEL, 0, -1); }
}
static int32_t open_text_frame(int surface, double width, double height, double scale) {
  moonbit_string_t json = capture_text_frame(capture.session, capture.text_edit, surface, width, height, scale, capture.toolbar_dark);
  int32_t frame = ui_frame_open(json); moonbit_decref(json); return frame;
}
static void refresh_text_frames(int x, int y, double scale) {
  if (capture.text_syncing) return;
  capture.text_syncing = TRUE;
  if (!capture.text_edit) {
    if (capture.text_properties) ShowWindow(capture.text_properties, SW_HIDE);
    mc_win_text_inputs_set_frame(capture.property_inputs, 0, 0, 0, 1);
    mc_win_text_inputs_set_frame(capture.body_inputs, 0, 0, 0, 1); capture.text = NULL;
  } else {
    sync_text_preview();
    double width = capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_WIDTH);
    double height = capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_HEIGHT);
    int32_t row = open_text_frame(MC_CAPTURE_TEXT_PROPERTIES, width, height, 1);
    if (row) {
      MoveWindow(capture.text_properties, x, y, rounded(width * scale), rounded(height * scale), TRUE);
      mc_win_text_inputs_set_frame(capture.property_inputs, row, x, y, scale);
      ShowWindow(capture.text_properties, SW_SHOWNOACTIVATE);
      /* Native fields are siblings so their existing MSAA provider is visible
       * independently of the virtual canvas semantic children. */
      for (int i = 0; i < ui_frame_field_count(row); i++) {
        moonbit_string_t id = ui_frame_field_text(row, i, MC_UI_FIELD_ID);
        int length = Moonbit_array_length(id); wchar_t key[257] = {0};
        if (length > 0 && length < (int)ARRAYSIZE(key)) {
          memcpy(key, id, (size_t)length * sizeof(wchar_t));
          HWND field = mc_win_text_inputs_field(capture.property_inputs, key);
          if (field) BringWindowToTop(field);
        }
        moonbit_decref(id);
      }
      if (!mc_win_canvas_set_frame(capture.text_properties, row)) ui_frame_close(row);
    }
    if (property_tool() == TOOL_TEXT && capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_MODE) != MC_CAPTURE_TEXT_DEFAULTS) {
      double measured = measure_text();
      double height_px = capture_text_measured_height(capture.session, capture.text_edit, text_version(), measured);
      if (height_px > 0) capture.draft.bottom = capture.draft.top + rounded(height_px);
      int32_t body = capture.editing != -2 ? open_text_frame(MC_CAPTURE_TEXT_INLINE, capture.draft.right - capture.draft.left,
          capture.draft.bottom - capture.draft.top, 1) : 0;
      if (body) { mc_win_text_inputs_set_frame(capture.body_inputs, body, capture.draft.left, capture.draft.top, 1); ui_frame_close(body); }
      capture.text = mc_win_text_inputs_field(capture.body_inputs, L"annotation.text");
    } else { mc_win_text_inputs_set_frame(capture.body_inputs, 0, 0, 0, 1); capture.text = NULL; }
  }
  capture.text_syncing = FALSE;
}
static BOOL text_field_event(void *context, HWND field, moonbit_string_t event) {
  (void)context; (void)field;
  if (!capture.text_edit || capture.text_finishing) return FALSE;
  BOOL ok = capture_text_event_json(capture.session, capture.text_edit, text_version(), event) == 1;
  sync_text_preview(); changed(); if (capture.text) style_text(); return ok;
}
static void text_field_action(void *context, HWND field, int action) {
  (void)context; (void)field;
  if (!capture.text_edit || capture.text_syncing || capture.text_finishing) return;
  if (action == MC_TEXT_INPUT_STATE) { sync_text_preview(); changed(); if (capture.text) style_text(); return; }
  PostMessageW(capture.editor, TEXT_FIELD_ACTION, (WPARAM)capture.text_edit, (LPARAM)action);
}
static BOOL text_field_key(void *context, HWND field, const MCCanvasInput *event) {
  (void)context; (void)field;
  if (!capture.text_edit) return FALSE;
  moonbit_string_t json = mc_canvas_input_json(event);
  int result = capture_text_ui_event(capture.session, capture.text_edit, text_version(), json,
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_WIDTH),
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_HEIGHT));
  moonbit_decref(json);
  if (result == MC_CAPTURE_TEXT_HANDLED) {
    sync_text_preview(); changed(); if (capture.text) style_text(); return TRUE;
  }
  return FALSE;
}
static BOOL text_field_wheel(void *context, HWND field, WPARAM keys_delta, LPARAM screen_point) {
  (void)context;
  if (!capture.text_properties || !mc_win_text_inputs_contains(capture.property_inputs,field)) return FALSE;
  SendMessageW(capture.text_properties,WM_MOUSEWHEEL,keys_delta,screen_point);
  return TRUE;
}
static BOOL apply_color_result(int32_t session, int32_t edit, int version, COLORREF rgb) {
  if (!capture.editor || capture.session != session || capture.text_edit != edit || text_version() != version) return FALSE;
  char buffer[64]; snprintf(buffer, sizeof(buffer), "{\"type\":\"color\",\"rgb\":%u}",
      (unsigned)((GetRValue(rgb) << 16) | (GetGValue(rgb) << 8) | GetBValue(rgb)));
  moonbit_string_t color = moonbit_make_string_raw((int)strlen(buffer));
  for (int i = 0; buffer[i]; i++) color[i] = (uint16_t)buffer[i];
  BOOL ok = text_field_event(NULL, NULL, color); moonbit_decref(color);
  if (ok && capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_MODE) == MC_CAPTURE_TEXT_DEFAULTS)
    ok = finish_text(FALSE);
  return ok;
}
static void text_property_event(void *context, HWND window, const MCCanvasInput *event) {
  (void)context; (void)window;
  if (!capture.text_edit) return;
  int32_t session = capture.session;
  HWND owner = capture.editor;
  moonbit_string_t json = mc_canvas_input_json(event);
  int result = capture_text_ui_event(capture.session, capture.text_edit, text_version(), json,
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_WIDTH),
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_HEIGHT));
  moonbit_decref(json);
  if (result == MC_CAPTURE_TEXT_CHOOSE_COLOR) {
    int32_t edit = capture.text_edit;
    int version = text_version();
    static COLORREF custom[16]; CHOOSECOLORW picker = {0}; picker.lStructSize = sizeof(picker);
    picker.hwndOwner = capture.editor; picker.lpCustColors = custom; picker.rgbResult = color_ref(capture.color);
    picker.Flags = CC_FULLOPEN | CC_RGBINIT; capture.color_picker = TRUE;
    BOOL chosen = ChooseColorW(&picker);
    if (capture.editor == owner && capture.session == session) {
      capture.color_picker = FALSE;
      if (chosen) apply_color_result(session, edit, version, picker.rgbResult);
    }
  }
  if (capture.editor == owner && capture.session == session) { changed(); if (capture.text) style_text(); }
}
static int hit_text(POINT p) {
  // Pixel centers preserve Win32's right/bottom-exclusive integer rectangle.
  return image_session_hit(capture.session, p.x + 0.5, p.y + 0.5, 0, 1);
}
static int hit_handle(RECT rect, POINT point) {
  int radius = dpi_px(capture.editor ? capture.editor : capture.overlay, 6);
  return mc_selection_hit_handle(rect, point, radius);
}
static RECT drag_rect(RECT rect, POINT from, POINT to, int handle, int minimum_size) {
  RECT bounds = {0, 0, capture.image.width, capture.image.height};
  return mc_selection_transform(rect, from, to, handle, bounds, minimum_size);
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
static wchar_t *tool_text(int32_t snapshot, int index, int key) {
  moonbit_string_t text=tool_registry_snapshot_text(snapshot,MC_TOOL_GROUP_SCREENSHOT,index,key);
  int length=Moonbit_array_length(text);
  wchar_t *copy=calloc((SIZE_T)length+1,sizeof(wchar_t));
  if (copy) memcpy(copy,text,(SIZE_T)length*sizeof(wchar_t));
  moonbit_decref(text); return copy;
}
static int tool_value(int32_t snapshot,int index,int key) {
  return tool_registry_snapshot_value(snapshot,MC_TOOL_GROUP_SCREENSHOT,index,key);
}
static moonbit_string_t moon_text(const wchar_t *text) {
  size_t length=wcslen(text); moonbit_string_t result=moonbit_make_string_raw((int32_t)length);
  memcpy(result,text,length*sizeof(wchar_t)); return result;
}
static BOOL toolbar_context(void) {
  if (!capture.toolbar_session || capture.closing) return FALSE;
  HWND focus=GetFocus();
  BOOL field=mc_win_text_inputs_contains(capture.body_inputs,focus) || mc_win_text_inputs_contains(capture.property_inputs,focus);
  wchar_t json[512];
  swprintf_s(json,ARRAYSIZE(json),L"{\"hasRegion\":%s,\"blocked\":%s,\"fieldFocused\":%s,\"toolbarFocused\":%s,\"bodyEditing\":%s,\"pinAvailable\":%s,\"capabilities\":%d,\"edit\":%d,\"editVersion\":%d,\"measuredHeight\":%.17g}",
      capture.viewport.right>capture.viewport.left && capture.viewport.bottom>capture.viewport.top ? L"true":L"false",
      capture.dragging || capture.color_picker || capture.composing ? L"true":L"false",field ? L"true":L"false",focus==capture.toolbar_view ? L"true":L"false",capture.editing!=-2 && capture.text ? L"true":L"false",pin_enabled()?L"true":L"false",
      tool_capabilities(),capture.text_edit,capture.text_edit ? text_version():0,measure_text());
  moonbit_string_t facts=moon_text(json); BOOL ok=capture_toolbar_context(capture.toolbar_session,facts)==1;
  moonbit_decref(facts); return ok;
}
static void toolbar_sync_native(void) {
  BOOL retired=capture.text_edit && capture_text_value(capture.session,capture.text_edit,MC_CAPTURE_TEXT_VERSION)<0;
  if (retired) {
    capture.text_finishing=TRUE; capture.text_edit=0; capture.text_index=-1; capture.editing=-2; capture.composing=FALSE;
    mc_win_text_inputs_set_frame(capture.body_inputs,0,0,0,1);
    mc_win_text_inputs_set_frame(capture.property_inputs,0,0,0,1); capture.text=NULL;
    capture.text_finishing=FALSE; capture.selected=-1;
  }
  capture.tool=(int)capture_toolbar_value(capture.toolbar_session,MC_CAPTURE_TOOLBAR_KIND);
  if (capture.tool<0) capture.tool=TOOL_SELECT;
  if (!capture.text_edit) { capture.selected=-1; load_tool_style(capture.tool); }
  else sync_text_preview();
  sync_viewport(); changed();
}
static void toolbar_effect(void) {
  int32_t toolbar=capture.toolbar_session;
  int effect=(int)capture_toolbar_value(toolbar,MC_CAPTURE_TOOLBAR_EFFECT);
  int32_t ticket=(int32_t)capture_toolbar_value(toolbar,MC_CAPTURE_TOOLBAR_TICKET);
  if (effect<=MC_CAPTURE_TOOLBAR_NONE || ticket<=0) return;
  BOOL success=FALSE, close=FALSE;
  const wchar_t *error=L"";
  if (effect==MC_CAPTURE_TOOLBAR_REFRESH) success=TRUE;
  else if (effect==MC_CAPTURE_TOOLBAR_CANCEL) { success=TRUE; close=TRUE; }
  else if (effect==MC_CAPTURE_TOOLBAR_COPY) {
    toolbar_sync_native(); success=copy_image(); close=success;
    if (!success) error=L"剪贴板暂时被占用，请重试。";
  } else if (effect==MC_CAPTURE_TOOLBAR_PIN) {
    int32_t candidate=(int32_t)capture_toolbar_value(toolbar,MC_CAPTURE_TOOLBAR_CANDIDATE);
    HGLOBAL dib=candidate_dib(candidate);
    if (dib) {
      int x=capture.desktop_bounds.left+rounded(capture_candidate_viewport_value(candidate,0));
      int y=capture.desktop_bounds.top+rounded(capture_candidate_viewport_value(candidate,1));
      success=capture.host.pin_image && capture.host.pin_image(capture.host.context,dib,x,y);
      if (!success) GlobalFree(dib);
    }
    close=success; if (!success) error=L"无法贴图，请重试。";
  } else if (effect==MC_CAPTURE_TOOLBAR_USER_TOOL && capture.host.on_user_tool) {
    moonbit_string_t id=capture_toolbar_text(toolbar,MC_CAPTURE_TOOLBAR_EFFECT_ID);
    moonbit_string_t payload=capture_toolbar_text(toolbar,MC_CAPTURE_TOOLBAR_PAYLOAD);
    size_t id_length=(size_t)Moonbit_array_length(id), payload_length=(size_t)Moonbit_array_length(payload);
    wchar_t *stable=calloc(id_length+1,sizeof(wchar_t)), *raw=calloc(payload_length+1,sizeof(wchar_t));
    if (stable && raw) {
      memcpy(stable,id,id_length*sizeof(wchar_t)); memcpy(raw,payload,payload_length*sizeof(wchar_t));
      success=capture.host.on_user_tool(capture.host.context,capture.session,stable,raw);
    }
    free(stable); free(raw); moonbit_decref(id); moonbit_decref(payload);
    if (capture.toolbar_session!=toolbar) return;
    if (!success) error=L"插件请求未被接收，请重试。";
  } else error=L"当前平台尚未提供此能力。";
  moonbit_string_t detail=moon_text(error);
  BOOL accepted=capture_toolbar_ack(toolbar,ticket,success,detail)==1; moonbit_decref(detail);
  if (!accepted || capture.toolbar_session!=toolbar) return;
  if (close) { mc_capture_close(); return; }
  toolbar_sync_native();
  if (!success && !capture.smoke && *error) MessageBoxW(capture.editor,error,L"Mooji Cut",MB_OK|MB_ICONWARNING);
}
static void toolbar_input(void *context,HWND window,const MCCanvasInput *input) {
  (void)context; (void)window;
  if (!capture.toolbar_session || capture.toolbar_dispatching || capture.closing) return;
  if (input->type==MC_UI_INPUT_APPEARANCE) {
    capture.toolbar_dark=input->text_length==4 && !memcmp(input->text,L"dark",4*sizeof(wchar_t));
    layout_editor(capture.editor); return;
  }
  int32_t origin=capture.toolbar_session;
  capture.toolbar_dispatching=TRUE;
  if (toolbar_context()) {
    moonbit_string_t event=mc_canvas_input_json(input);
    BOOL handled=capture_toolbar_event(capture.toolbar_session,capture.toolbar_generation,event)==1;
    moonbit_decref(event);
    if (handled) toolbar_effect();
    if (capture.toolbar_session!=origin) return;
    if (capture.editor) {
      if (input->type==MC_UI_INPUT_POINTER_DOWN && handled) mc_win_canvas_set_capture(capture.toolbar_view,TRUE);
      if (input->type==MC_UI_INPUT_POINTER_UP || input->type==MC_UI_INPUT_CANCEL) mc_win_canvas_set_capture(capture.toolbar_view,FALSE);
      layout_editor(capture.editor);
    }
  }
  capture.toolbar_dispatching=FALSE;
}
static BOOL toolbar_activate(const wchar_t *id) {
  if (!capture.toolbar_session || capture.toolbar_dispatching || capture.closing || !toolbar_context()) return FALSE;
  int32_t origin=capture.toolbar_session;
  capture.toolbar_dispatching=TRUE;
  moonbit_string_t value=moon_text(id);
  BOOL handled=capture_toolbar_activate(capture.toolbar_session,capture.toolbar_generation,value)==1;
  moonbit_decref(value);
  if (handled) toolbar_effect();
  if (capture.toolbar_session!=origin) return handled;
  if (capture.editor) layout_editor(capture.editor);
  capture.toolbar_dispatching=FALSE; return handled;
}
static BOOL toolbar_preserve_focus(void *context,HWND window) {
  (void)context; (void)window; HWND focus=GetFocus();
  return mc_win_text_inputs_contains(capture.body_inputs,focus) || mc_win_text_inputs_contains(capture.property_inputs,focus);
}
static LRESULT CALLBACK toolbar_focus_proc(HWND window,UINT message,WPARAM wp,LPARAM lp,UINT_PTR id,DWORD_PTR data) {
  (void)id; (void)data;
  if ((message==WM_SETFOCUS || message==WM_KILLFOCUS) && capture.editor && !capture.closing)
    PostMessageW(capture.editor,TOOLBAR_FOCUS_CHANGED,(WPARAM)capture.toolbar_session,0);
  if (message==WM_NCDESTROY) RemoveWindowSubclass(window,toolbar_focus_proc,3);
  return DefSubclassProc(window,message,wp,lp);
}
void mc_capture_discard_tools(void) {
  if (capture.prepared_toolbar) capture_toolbar_config_close(capture.prepared_toolbar);
  capture.prepared_toolbar=0; prepared_tools=0;
}
BOOL mc_capture_prepare_tools(int32_t snapshot) {
  mc_capture_discard_tools();
  if (tool_registry_snapshot_count(snapshot,MC_TOOL_GROUP_SCREENSHOT)<0) return FALSE;
  if (capture.editor) {
    if (!toolbar_context()) return FALSE;
    capture.prepared_toolbar=capture_toolbar_config_prepare(capture.toolbar_session,snapshot);
    if (!capture.prepared_toolbar) return FALSE;
  }
  prepared_tools=snapshot; return TRUE;
}
void mc_capture_commit_tools(int32_t snapshot) {
  if (snapshot!=prepared_tools) return;
  if (capture.editor) {
    wchar_t json[128]; swprintf_s(json,ARRAYSIZE(json),L"[{\"toolbar\":%d,\"candidate\":%d}]",capture.toolbar_session,capture.prepared_toolbar);
    moonbit_string_t request=moon_text(json); BOOL ok=capture_toolbar_config_commit_many(request)==1; moonbit_decref(request);
    if (!ok) return;
  }
  configured_tools=snapshot; mc_capture_discard_tools();
  if (capture.editor) {
    capture.tool_snapshot=snapshot;
    mc_win_canvas_cancel(capture.toolbar_view); toolbar_sync_native();
    if (capture.owned_tools) { tool_registry_snapshot_close(capture.owned_tools); capture.owned_tools=0; }
  }
}
static BOOL add_shape(void) {
  return image_session_shape_event(capture.session, 1, capture.end.x, capture.end.y) == 1;
}
static void editor_command(int command) {
  const wchar_t *id=command==ID_SELECT ? L"host.select" : command==ID_UNDO ? L"host.undo" :
      command==ID_REDO ? L"host.redo" : command==ID_CANCEL ? L"host.cancel" : command==ID_COPY ? L"host.confirm" : NULL;
  if (id) toolbar_activate(id);
}
static void paint_editor(HDC dc) {
  BitBlt(dc, 0, 0, capture.dimmed.width, capture.dimmed.height, capture.dimmed.dc, 0, 0, SRCCOPY);
  if (render_image_mode(FALSE)) {
    RECT v = capture.viewport;
    BitBlt(dc, v.left, v.top, v.right - v.left, v.bottom - v.top, capture.rendered.dc, v.left, v.top,
           SRCCOPY);
    int saved = SaveDC(dc);
    IntersectClipRect(dc, v.left, v.top, v.right, v.bottom);
    if (capture.text && capture.text_edit) {
      /* Covers clip the native input to keep their top-layer ordering. Fill
       * exactly those holes with the complete shared draft composition, even
       * for transparent covers. Outside them only the EDIT paints its text. */
      HRGN covered = cover_region(0, 0); RECT bounds;
      if (GetRgnBox(covered, &bounds) != NULLREGION && render_image_mode(TRUE)) {
        int layer = SaveDC(dc);
        ExtSelectClipRgn(dc, covered, RGN_AND);
        IntersectClipRect(dc, capture.draft.left, capture.draft.top, capture.draft.right, capture.draft.bottom);
        BitBlt(dc, v.left, v.top, v.right - v.left, v.bottom - v.top, capture.rendered.dc, v.left, v.top, SRCCOPY);
        RestoreDC(dc, layer);
      }
      DeleteObject(covered);
    }
    if (capture.selected >= 0 && capture.editing == -2) {
      RECT r = capture.dragging && capture.drag_mode == 1 ? capture.draft : annotation_rect(capture.selected);
      frame(dc, r, TRUE);
    }
    RestoreDC(dc, saved);
    frame(dc, v, TRUE);
    region_label(dc, v);
  }
  mc_hud_card(dc, &capture.toolbar, (float)GetDpiForWindow(capture.editor) / 96,
      capture_toolbar_surface_color(capture.toolbar_dark));
}
static LRESULT CALLBACK editor_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  switch (message) {
  case WM_CREATE: {
    capture.editor = window;
    capture.font =
        CreateFontW(-dpi_px(window, 14), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                    OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    MCWinCanvasCallbacks toolbar_callbacks={toolbar_input,NULL,NULL,NULL,toolbar_preserve_focus};
    capture.toolbar_view=mc_win_canvas_create(window,capture.instance,ID_SELECT,&toolbar_callbacks,NULL);
    if (!capture.toolbar_view || !SetWindowSubclass(capture.toolbar_view,toolbar_focus_proc,3,0)) return -1;
    ShowWindow(capture.toolbar_view,SW_SHOWNOACTIVATE);
    MCWinCanvasCallbacks row_callbacks = {text_property_event, NULL, NULL, NULL, NULL};
    capture.text_properties = mc_win_canvas_create(window, capture.instance, ID_STYLE_BASE + 50, &row_callbacks, NULL);
    if (!capture.text_properties) return -1;
    ShowWindow(capture.text_properties, SW_HIDE);
    MCWinTextCallbacks text_callbacks = {text_field_event, text_field_action, text_background, text_field_key, text_field_wheel};
    capture.body_inputs = mc_win_text_inputs_create(window, capture.instance, &text_callbacks, NULL);
    capture.property_inputs = mc_win_text_inputs_create(window, capture.instance, &text_callbacks, NULL);
    if (!capture.body_inputs || !capture.property_inputs) return -1;
    layout_editor(window);
    return 0;
  }
  case TOOLBAR_FOCUS_CHANGED:
    if (capture.toolbar_session==(int32_t)wp && !capture.closing) layout_editor(window);
    return 0;
  case WM_SETFOCUS:
    if (capture.toolbar_session && !capture.closing) layout_editor(window);
    return 0;
  case TEXT_FIELD_ACTION:
    if (capture.text_edit == (int32_t)wp && !capture.color_picker) {
      BOOL defaults = capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_MODE) == MC_CAPTURE_TEXT_DEFAULTS;
      HWND focus = GetFocus();
      BOOL within = mc_win_text_inputs_contains(capture.property_inputs, focus) || mc_win_text_inputs_contains(capture.body_inputs, focus) ||
          focus == capture.toolbar_view || focus == capture.text_properties;
      if (lp == MC_TEXT_CANCEL || lp == MC_TEXT_ACCEPT || (lp == MC_TEXT_BLUR && defaults && !within)) {
        if (finish_text(lp == MC_TEXT_CANCEL)) SetFocus(window);
        layout_editor(window);
      }
    }
    return 0;
  case WM_SIZE:
    if (capture.session)
      layout_editor(window);
    return 0;
  case WM_DISPLAYCHANGE:
    mc_capture_close();
    return 0;
  case WM_CTLCOLOREDIT:
    if ((HWND)lp == capture.text) {
      SetTextColor((HDC)wp, color_ref(capture.color));
      SetBkColor((HDC)wp, RGB(250, 245, 234));
      return (LRESULT)GetSysColorBrush(COLOR_INFOBK);
    }
    break;
  case WM_COMMAND:
    // Main toolbar actions are emitted only by the immutable shared frame.
    // Retired BUTTON notifications from older layouts cannot invoke anything.
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
      int index = capture.tool == TOOL_SELECT
        ? image_session_hit(capture.session, p.x, p.y, 5, 0) : hit_text(p);
      if (index >= 0 && (capture.tool == TOOL_SELECT || capture.tool == TOOL_TEXT)) {
        capture.selected = index;
        capture.text_finishing = TRUE; load_annotation_style(index); capture.text_finishing = FALSE;
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
    if (capture.selected < 0 && capture.editing == -2) {
      // Refresh defaults without reopening a property transaction before the
      // gesture owns the document. Mouse-up will open it on the new revision.
      capture.text_finishing = TRUE;
      load_tool_style(capture.tool);
      capture.text_finishing = FALSE;
    }
    if (capture.drag_mode == 0) {
      image_session_shape_event(capture.session, 2, 0, 0);
      BOOL began;
      if (custom_drag()) {
        moonbit_string_t command=capture_toolbar_text(capture.toolbar_session,MC_CAPTURE_TOOLBAR_COMMAND);
        began = image_session_tool_begin(capture.session, command, p.x, p.y,
          capture.color, capture.stroke, capture.opacity, 0, capture.block);
        moonbit_decref(command);
      } else began = image_session_shape_begin(capture.session, capture.tool, p.x, p.y,
          capture.color, capture.stroke, capture.opacity, capture.shape, capture.block);
      if (!began) return 0;
    }
    if (capture.drag_id) { moonbit_decref(capture.drag_id); capture.drag_id = NULL; }
    if (capture.drag_mode == 1 && capture.selected >= 0) {
      capture.drag_id = image_session_annotation_id(capture.session, capture.selected);
      capture.drag_revision = image_session_revision(capture.session);
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
        capture.draft = drag_rect(capture.drag_bounds, capture.start, capture.end, capture.handle,
                                  capture.drag_mode == 2 ? 2 : 8);
        if (capture.drag_mode == 2)
          capture.viewport = capture.draft;
      }
      if (!capture.drag_mode) image_session_shape_event(capture.session, 0, capture.end.x, capture.end.y);
      capture.dirty = TRUE;
      InvalidateRect(window, NULL, FALSE);
    }
    return 0;
  case WM_LBUTTONUP:
    if (capture.dragging) {
      capture.end.x = bounded(GET_X_LPARAM(lp), 0, capture.image.width);
      capture.end.y = bounded(GET_Y_LPARAM(lp), 0, capture.image.height);
      capture.dragging = FALSE;
      ReleaseCapture();
      if (capture.drag_mode == 1 && capture.selected >= 0) {
        RECT r = capture.draft;
        BOOL corner = capture.handle == 0 || capture.handle == 2 || capture.handle == 4 || capture.handle == 6;
        BOOL text = image_session_value(capture.session, capture.selected, 0) == TOOL_TEXT;
        double size = capture.font_size;
        if (corner && text) size = fmin(editor_style_max(MC_STYLE_FONT), fmax(editor_style_min(MC_STYLE_FONT),
            capture.font_size * (double)(r.right - r.left) / maximum(1, capture.drag_bounds.right - capture.drag_bounds.left)));
        if (text && capture.handle >= 0) r = fit_annotation_bounds(capture.selected, r, size);
        if (capture.drag_id) image_session_geometry(capture.session, capture.drag_revision, capture.drag_id,
            r.left, r.top, r.right - r.left, r.bottom - r.top, corner && text ? size : -1);
        capture.font_size = size;
        if (capture.drag_id) { moonbit_decref(capture.drag_id); capture.drag_id = NULL; }
        sync_properties();
      } else if (capture.drag_mode == 2) {
        RECT r = capture.viewport;
        image_session_crop(capture.session, r.left, r.top, r.right - r.left, r.bottom - r.top);
        sync_viewport();
        layout_editor(window);
      } else
        add_shape();
      if (capture.toolbar_session && capture_toolbar_value(capture.toolbar_session,MC_CAPTURE_TOOLBAR_EFFECT)>MC_CAPTURE_TOOLBAR_NONE) {
        int32_t session=capture.session;
        toolbar_effect();
        if (!capture.editor || capture.session!=session) return 0;
      }
      changed();
    }
    return 0;
  case WM_CAPTURECHANGED:
    if (capture.dragging) {
      capture.dragging = FALSE;
      if (capture.drag_id) { moonbit_decref(capture.drag_id); capture.drag_id = NULL; }
      image_session_shape_event(capture.session, 2, 0, 0);
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
  capture.tool_snapshot = configured_tools;
  if (!capture.tool_snapshot) {
    moonbit_string_t empty = moonbit_make_string_raw(0);
    moonbit_string_t result = tool_registry_normalize(empty);
    moonbit_decref(empty);
    capture.tool_snapshot = capture.owned_tools = tool_registry_snapshot_open(result, tool_capabilities());
    moonbit_decref(result);
  }
  if (!capture.tool_snapshot) return FALSE;
  capture.style_bank = editor_style_create();
  if (capture.style_bank <= 0)
    return FALSE;
  capture.toolbar_session=capture_toolbar_open(capture.session,capture.style_bank,capture.tool_snapshot);
  if (!capture.toolbar_session) return FALSE;
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
static void decorate_selection(void *context, HWND window, HDC dc, RECT rect) {
  (void)context; (void)window;
  frame(dc, rect, FALSE);
  region_label(dc, rect);
}
static void finish_selection(void *context, BOOL accepted, RECT rect) {
  (void)context;
  capture.overlay = NULL;
  if (!accepted) { mc_capture_close(); return; }
  capture.viewport = rect;
  if (!open_editor()) { mc_capture_close(); return; }
  surface_free(&capture.desktop);
}
static BOOL register_windows(HINSTANCE instance) {
  WNDCLASSEXW k = {sizeof(k)};
  k.hInstance = instance;
  k.style = CS_DBLCLKS;
  k.lpfnWndProc = editor_proc;
  k.lpszClassName = EDITOR_CLASS;
  k.hCursor = LoadCursorW(NULL, IDC_ARROW);
  return RegisterClassExW(&k) || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}
static BOOL show_selection(void) {
  MCSelectionSurfaceOptions options = {0};
  options.desktop_bounds = capture.desktop_bounds;
  options.desktop = capture.desktop.dc;
  options.dimmed = capture.dimmed.dc;
  options.hidden = capture.smoke;
  options.decorate = decorate_selection;
  options.finished = finish_selection;
  capture.overlay = mc_selection_surface_open(capture.instance, capture.owner, &options);
  if (!capture.overlay) return FALSE;
  if (!capture.smoke) mc_selection_surface_activate(capture.overlay);
  return capture.overlay != NULL;
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
  if (!mc_selection_desktop_bounds(&capture.desktop_bounds)) { mc_capture_close(); return false; }
  int x = capture.desktop_bounds.left, y = capture.desktop_bounds.top,
      w = capture.desktop_bounds.right - x, h = capture.desktop_bounds.bottom - y;
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
  set_pins_hidden(TRUE);
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
  mc_capture_discard_tools();
  capture.overlay = NULL;
  capture.editor = NULL;
  capture.dragging = FALSE;
  if (capture.drag_id) { moonbit_decref(capture.drag_id); capture.drag_id = NULL; }
  if (GetCapture() == overlay || GetCapture() == editor)
    ReleaseCapture();
  if (overlay)
    mc_selection_surface_dismiss(overlay);
  if (capture.text_background) DeleteObject(capture.text_background); capture.text_background = NULL;
  mc_win_text_inputs_destroy(capture.body_inputs); capture.body_inputs = NULL;
  mc_win_text_inputs_destroy(capture.property_inputs); capture.property_inputs = NULL;
  if (capture.text_properties) DestroyWindow(capture.text_properties);
  if (capture.toolbar_view) DestroyWindow(capture.toolbar_view);
  capture.toolbar_view=NULL; capture.toolbar_frame=0;
  if (capture.toolbar_session) capture_toolbar_close(capture.toolbar_session);
  capture.toolbar_session=0;
  capture.text_properties = NULL; capture.text = NULL;
  if (editor)
    DestroyWindow(editor);
  if (capture.session > 0)
    image_session_dispose(capture.session);
  if (capture.style_bank > 0)
    editor_style_dispose(capture.style_bank);
  if (capture.owned_tools) tool_registry_snapshot_close(capture.owned_tools);
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
  // Let the native EDIT/IME consume candidate selection and cancellation keys.
  if (mc_win_text_inputs_contains(capture.body_inputs, message->hwnd) ||
      mc_win_text_inputs_contains(capture.property_inputs, message->hwnd)) return false;
  if (capture.composing) return false;
  if (message->message == WM_KEYDOWN) {
    BOOL control = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
    BOOL text=GetFocus()==capture.text;
    const wchar_t *key=message->wParam==VK_ESCAPE ? L"Escape" : message->wParam==VK_RETURN ? L"Enter" :
      control && message->wParam=='Z' ? L"z" : control && message->wParam=='Y' ? L"y" :
      control && message->wParam=='C' ? L"c" : NULL;
    if (key) {
      MCCanvasInput input={0}; input.type=MC_UI_INPUT_KEY;
      input.flags=(control ? MC_UI_INPUT_MOD:0) | ((GetKeyState(VK_SHIFT)&0x8000)?MC_UI_INPUT_SHIFT:0);
      input.text=(const uint16_t *)key; input.text_length=wcslen(key);
      toolbar_input(NULL,capture.toolbar_view,&input); return true;
    }
    if (message->hwnd==capture.toolbar_view) return false;
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
      r = drag_rect(r, from, to, -1, 8);
      if (!finish_text(FALSE)) return true;
      moonbit_string_t id = image_session_annotation_id(capture.session, capture.selected);
      image_session_geometry(capture.session, image_session_revision(capture.session), id,
          r.left, r.top, r.right - r.left, r.bottom - r.top, -1);
      moonbit_decref(id);
      changed();
      return true;
    }
    if (!text && message->wParam == VK_DELETE && capture.selected >= 0) {
      if (!finish_text(FALSE)) return true;
      if (capture.selected >= 0) image_session_remove(capture.session, capture.selected);
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
/* Fixture helpers query the actual shared frame and drive native input. */
static const wchar_t *smoke_property_id(int property) {
  static const wchar_t *ids[] = {L"style.color", L"style.opacity", L"style.stroke", L"style.fontSize", L"style.shape.0", L"style.blockSize"};
  return property >= 0 && property < (int)ARRAYSIZE(ids) ? ids[property] : L"";
}
static int smoke_semantic(int32_t frame, const wchar_t *id) {
  size_t length = wcslen(id);
  for (int i = 0; i < ui_frame_semantic_count(frame); i++) {
    moonbit_string_t value = ui_frame_semantic_text(frame, i, MC_UI_SEM_ID);
    BOOL match = Moonbit_array_length(value) == (int)length && !memcmp(value, id, length * sizeof(wchar_t));
    moonbit_decref(value); if (match) return i;
  }
  return -1;
}
static int32_t smoke_property_frame(void) {
  if (!capture.text_edit) return 0;
  return open_text_frame(MC_CAPTURE_TEXT_PROPERTIES,
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_WIDTH),
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_HEIGHT), 1);
}
static BOOL style_visible(int property) {
  if (!capture.text_edit) return FALSE;
  const wchar_t *id = smoke_property_id(property);
  if (property != MC_STYLE_COLOR && property != MC_STYLE_SHAPE) {
    HWND input = mc_win_text_inputs_field(capture.property_inputs, id);
    return input && (GetWindowLongPtrW(input, GWL_STYLE) & WS_VISIBLE) != 0;
  }
  int32_t frame = smoke_property_frame();
  BOOL visible = frame && smoke_semantic(frame, id) >= 0;
  if (frame) ui_frame_close(frame);
  return visible;
}
static BOOL smoke_property_click(const wchar_t *id) {
  int32_t frame = smoke_property_frame();
  int node = frame ? smoke_semantic(frame, id) : -1;
  if (node < 0) { if (frame) ui_frame_close(frame); return FALSE; }
  BOOL enabled = ui_frame_semantic_value(frame, node, MC_UI_SEM_ENABLED) == 1;
  double scale = (double)GetDpiForWindow(capture.text_properties) / 96;
  int x = rounded((ui_frame_semantic_number(frame, node, MC_UI_SEM_X) + ui_frame_semantic_number(frame, node, MC_UI_SEM_WIDTH) / 2) * scale);
  int y = rounded((ui_frame_semantic_number(frame, node, MC_UI_SEM_Y) + ui_frame_semantic_number(frame, node, MC_UI_SEM_HEIGHT) / 2) * scale);
  ui_frame_close(frame);
  if (!enabled) return FALSE;
  SendMessageW(capture.text_properties, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(x, y));
  SendMessageW(capture.text_properties, WM_LBUTTONUP, 0, MAKELPARAM(x, y));
  return TRUE;
}
static BOOL choose_style(int field, double value) {
  ensure_property_edit(); layout_editor(capture.editor);
  if (!capture.text_edit) return FALSE;
  BOOL inline_edit = capture.editing != -2, ok = FALSE;
  if (field == MC_STYLE_COLOR) {
    ok = style_visible(MC_STYLE_COLOR) && apply_color_result(capture.session, capture.text_edit, text_version(), color_ref((int)value));
  } else if (field == MC_STYLE_SHAPE) {
    wchar_t id[32]; swprintf_s(id, ARRAYSIZE(id), L"style.shape.%d", (int)value);
    ok = smoke_property_click(id) && capture.shape == (int)value;
  } else {
    HWND input = mc_win_text_inputs_field(capture.property_inputs, smoke_property_id(field));
    wchar_t raw[64]; swprintf_s(raw, ARRAYSIZE(raw), L"%.10g", field == MC_STYLE_OPACITY ? value * 100 : value);
    ok = input && SetWindowTextW(input, raw) && capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_VALID) == 1;
  }
  if (ok && !inline_edit) { ok = finish_text(FALSE); layout_editor(capture.editor); }
  return ok;
}
static void step_style(BOOL increase) {
  ensure_property_edit(); layout_editor(capture.editor);
  if (!capture.text_edit) return;
  BOOL inline_edit = capture.editing != -2;
  HWND input = mc_win_text_inputs_field(capture.property_inputs,
      property_tool() == TOOL_TEXT ? L"style.fontSize" : L"style.stroke");
  if (input) { SetFocus(input); SendMessageW(input, WM_KEYDOWN, increase ? VK_UP : VK_DOWN, 1); }
  if (!inline_edit) { finish_text(FALSE); layout_editor(capture.editor); }
}
static int smoke_toolbar_semantic(const wchar_t *id) {
  int count=ui_frame_semantic_count(capture.toolbar_frame);
  for (int i=0;i<count;i++) {
    moonbit_string_t value=ui_frame_semantic_text(capture.toolbar_frame,i,MC_UI_SEM_ID);
    BOOL equal=(size_t)Moonbit_array_length(value)==wcslen(id) && !memcmp(value,id,wcslen(id)*sizeof(wchar_t));
    moonbit_decref(value); if (equal) return i;
  }
  return -1;
}
static void smoke_toolbar_pointer(int index,UINT message) {
  double scale=(double)GetDpiForWindow(capture.toolbar_view)/96;
  int x=rounded((ui_frame_semantic_number(capture.toolbar_frame,index,MC_UI_SEM_X)+
      ui_frame_semantic_number(capture.toolbar_frame,index,MC_UI_SEM_WIDTH)/2)*scale);
  int y=rounded((ui_frame_semantic_number(capture.toolbar_frame,index,MC_UI_SEM_Y)+
      ui_frame_semantic_number(capture.toolbar_frame,index,MC_UI_SEM_HEIGHT)/2)*scale);
  SendMessageW(capture.toolbar_view,message,message==WM_LBUTTONUP ? 0:MK_LBUTTON,MAKELPARAM(x,y));
}
static BOOL smoke_toolbar_click(const wchar_t *id) {
  int index=smoke_toolbar_semantic(id);
  for (int page=0;index<0 && page<512;page++) {
    int previous=smoke_toolbar_semantic(L"__toolbar.previous");
    if (previous<0 || ui_frame_semantic_value(capture.toolbar_frame,previous,MC_UI_SEM_ENABLED)!=1) break;
    smoke_toolbar_pointer(previous,WM_LBUTTONDOWN); smoke_toolbar_pointer(previous,WM_LBUTTONUP);
    index=smoke_toolbar_semantic(id);
  }
  for (int page=0;index<0 && page<512;page++) {
    int next=smoke_toolbar_semantic(L"__toolbar.next");
    if (next<0 || ui_frame_semantic_value(capture.toolbar_frame,next,MC_UI_SEM_ENABLED)!=1) break;
    smoke_toolbar_pointer(next,WM_LBUTTONDOWN); smoke_toolbar_pointer(next,WM_LBUTTONUP);
    index=smoke_toolbar_semantic(id);
  }
  if (index<0) return FALSE;
  smoke_toolbar_pointer(index,WM_LBUTTONDOWN); smoke_toolbar_pointer(index,WM_LBUTTONUP);
  return TRUE;
}
static wchar_t *smoke_contribution_id(int kind,const wchar_t *action) {
  int count=tool_registry_snapshot_count(capture.tool_snapshot,MC_TOOL_GROUP_SCREENSHOT);
  for (int i=0;i<count;i++) {
    if (!tool_value(capture.tool_snapshot,i,MC_TOOL_ENABLED)) continue;
    if (action) {
      wchar_t *candidate=tool_text(capture.tool_snapshot,i,MC_TOOL_ACTION);
      BOOL same=candidate && !wcscmp(candidate,action); free(candidate); if (!same) continue;
    } else if (tool_value(capture.tool_snapshot,i,MC_TOOL_INTERACTION)!=MC_TOOL_INTERACTION_ANNOTATION ||
        tool_value(capture.tool_snapshot,i,MC_TOOL_KIND)!=kind) continue;
    return tool_text(capture.tool_snapshot,i,MC_TOOL_ID);
  }
  return NULL;
}
static void smoke_select_tool(int kind) {
  wchar_t *id=kind==TOOL_SELECT ? _wcsdup(L"host.select") : smoke_contribution_id(kind,NULL);
  if (id) { smoke_toolbar_click(id); free(id); }
}
static void smoke_invoke_action(const wchar_t *action) {
  wchar_t *id=smoke_contribution_id(0,action);
  if (id) { smoke_toolbar_click(id); free(id); }
}
static BOOL smoke_action_enabled(const wchar_t *action) {
  wchar_t *id=smoke_contribution_id(0,action);
  int index=id ? smoke_toolbar_semantic(id):-1; free(id);
  return index>=0 && ui_frame_semantic_value(capture.toolbar_frame,index,MC_UI_SEM_ENABLED)==1;
}
static BOOL CALLBACK smoke_find_toolbar_tip(HWND window,LPARAM result) {
  wchar_t name[64]={0}; GetClassNameW(window,name,ARRAYSIZE(name));
  if (wcscmp(name,TOOLTIPS_CLASSW)) return TRUE;
  /* A WS_POPUP tooltip created with a child HWND belongs to the top-level
   * editor. Identify this canvas by its registered tool, not GW_OWNER (both
   * the toolbar and property canvas have the same top-level owner). */
  TOOLINFOW tool={sizeof(tool)}; tool.hwnd=capture.toolbar_view; tool.uId=1;
  if (SendMessageW(window,TTM_GETTOOLINFOW,0,(LPARAM)&tool)) {
    *(HWND *)result=window; return FALSE;
  }
  return TRUE;
}
static void smoke_drain_field_actions(void) {
  MSG message;
  while (PeekMessageW(&message,capture.editor,TEXT_FIELD_ACTION,TOOLBAR_FOCUS_CHANGED,PM_REMOVE)) DispatchMessageW(&message);
}
static BOOL smoke_accessible_child(IAccessible *accessible,const wchar_t *id,VARIANT *child) {
  VariantInit(child);
  int index=smoke_toolbar_semantic(id);
  if (index<0) return FALSE;
  moonbit_string_t label=ui_frame_semantic_text(capture.toolbar_frame,index,MC_UI_SEM_LABEL);
  LONG count=0; BOOL found=FALSE;
  if (SUCCEEDED(IAccessible_get_accChildCount(accessible,&count)) && count>0 && count<=512) {
    VARIANT *children=calloc((size_t)count,sizeof(VARIANT)); LONG received=0;
    if (children && SUCCEEDED(AccessibleChildren(accessible,0,count,children,&received))) {
      for (LONG i=0;i<received;i++) {
        BSTR name=NULL;
        if (SUCCEEDED(IAccessible_get_accName(accessible,children[i],&name)) && name &&
            SysStringLen(name)==(UINT)Moonbit_array_length(label) &&
            !memcmp(name,label,SysStringLen(name)*sizeof(wchar_t))) {
          found=SUCCEEDED(VariantCopy(child,&children[i]));
        }
        SysFreeString(name); VariantClear(&children[i]);
      }
    }
    free(children);
  }
  moonbit_decref(label); return found;
}
static BOOL shared_toolbar_smoke(void) {
  BOOL ok=TRUE; IAccessible *accessible=NULL; VARIANT child; VariantInit(&child);
  RECT window_rect; GetWindowRect(capture.editor,&window_rect);
  int initial_count=image_session_count(capture.session);
#define TOOLBAR_CHECK(condition) do { if (!(condition)) { fprintf(stderr,"Windows shared toolbar FAILED line %d: %s\n",__LINE__,#condition); ok=FALSE; goto done; } } while (0)
  smoke_select_tool(TOOL_RECT);
  HWND stroke=mc_win_text_inputs_field(capture.property_inputs,L"style.stroke");
  int32_t edit=capture.text_edit; double revision=image_session_revision(capture.session);
  TOOLBAR_CHECK(stroke); SetFocus(stroke);
  TOOLBAR_CHECK(GetFocus()==stroke && SetWindowTextW(stroke,L"-"));
  smoke_select_tool(TOOL_ARROW); smoke_drain_field_actions();
  TOOLBAR_CHECK(capture.tool==TOOL_RECT && capture.text_edit==edit && IsWindow(stroke) &&
      image_session_revision(capture.session)==revision && capture_text_value(capture.session,edit,MC_CAPTURE_TEXT_VALID)==0);
  SetFocus(stroke); TOOLBAR_CHECK(SetWindowTextW(stroke,L"5.25"));
  TOOLBAR_CHECK(smoke_toolbar_click(L"host.undo")); smoke_drain_field_actions();
  TOOLBAR_CHECK(capture.text_edit==edit && IsWindow(stroke) && capture_text_value(capture.session,edit,MC_CAPTURE_TEXT_VALID)==0);
  TOOLBAR_CHECK(smoke_toolbar_click(L"host.redo")); smoke_drain_field_actions();
  TOOLBAR_CHECK(capture.text_edit==edit && capture.stroke==5.25 && image_session_revision(capture.session)==revision);
  TOOLBAR_CHECK(SetWindowTextW(stroke,L"4") && finish_text(FALSE)); changed();
  SendMessageW(capture.editor,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(200,80));
  SendMessageW(capture.editor,WM_MOUSEMOVE,MK_LBUTTON,MAKELPARAM(240,120));
  SendMessageW(capture.editor,WM_LBUTTONUP,0,MAKELPARAM(240,120));
  TOOLBAR_CHECK(image_session_count(capture.session)==initial_count+1);
  stroke=mc_win_text_inputs_field(capture.property_inputs,L"style.stroke");
  TOOLBAR_CHECK(stroke); SetFocus(stroke); revision=image_session_revision(capture.session);
  int undo=smoke_toolbar_semantic(L"host.undo");
  TOOLBAR_CHECK(undo>=0 && ui_frame_semantic_value(capture.toolbar_frame,undo,MC_UI_SEM_ENABLED)==0);
  TOOLBAR_CHECK(smoke_toolbar_click(L"host.undo")); smoke_drain_field_actions();
  TOOLBAR_CHECK(GetFocus()==stroke && image_session_count(capture.session)==initial_count+1 &&
      image_session_revision(capture.session)==revision);
  SetFocus(capture.editor); editor_command(ID_UNDO);
  TOOLBAR_CHECK(image_session_count(capture.session)==initial_count);
  SetFocus(capture.toolbar_view);
  SendMessageW(capture.toolbar_view,WM_KEYDOWN,VK_HOME,1);
  SendMessageW(capture.toolbar_view,WM_KEYDOWN,VK_RIGHT,1);
  MSG enter={0}; enter.hwnd=capture.toolbar_view; enter.message=WM_KEYDOWN; enter.wParam=VK_RETURN;
  TOOLBAR_CHECK(mc_capture_handle_message(&enter) && capture.editor && capture.tool==TOOL_RECT);
  wchar_t *arrow=smoke_contribution_id(TOOL_ARROW,NULL);
  int arrow_index=arrow ? smoke_toolbar_semantic(arrow):-1; free(arrow);
  TOOLBAR_CHECK(arrow_index>=0);
  smoke_toolbar_pointer(arrow_index,WM_LBUTTONDOWN);
  SendMessageW(capture.toolbar_view,WM_CANCELMODE,0,0);
  smoke_toolbar_pointer(arrow_index,WM_LBUTTONUP);
  TOOLBAR_CHECK(capture.tool==TOOL_RECT && GetCapture()!=capture.toolbar_view);
  TOOLBAR_CHECK(SUCCEEDED(AccessibleObjectFromWindow(capture.toolbar_view,(DWORD)OBJID_CLIENT,&IID_IAccessible,(void **)&accessible)) && accessible);
  TOOLBAR_CHECK(smoke_accessible_child(accessible,L"builtin.capture.ocr",&child));
  VARIANT state; VariantInit(&state);
  HRESULT state_result=IAccessible_get_accState(accessible,child,&state);
  BOOL unavailable=SUCCEEDED(state_result) && state.vt==VT_I4 && (state.lVal&STATE_SYSTEM_UNAVAILABLE)!=0;
  VariantClear(&state);
  TOOLBAR_CHECK(unavailable);
  IAccessible_accDoDefaultAction(accessible,child);
  TOOLBAR_CHECK(capture.tool==TOOL_RECT && image_session_count(capture.session)==initial_count);
  VariantClear(&child);
  MoveWindow(capture.editor,window_rect.left,window_rect.top,140,window_rect.bottom-window_rect.top,FALSE);
  TOOLBAR_CHECK(smoke_toolbar_semantic(L"__toolbar.next")>=0);
  SetFocus(capture.toolbar_view); SendMessageW(capture.toolbar_view,WM_KEYDOWN,VK_END,1);
  int confirm=smoke_toolbar_semantic(L"host.confirm");
  TOOLBAR_CHECK(confirm>=0 && ui_frame_semantic_value(capture.toolbar_frame,confirm,MC_UI_SEM_FOCUSED)==1);
  SendMessageW(capture.toolbar_view,WM_KEYDOWN,VK_HOME,1);
  TOOLBAR_CHECK(smoke_toolbar_semantic(L"host.select")>=0);
done:
  VariantClear(&child); if (accessible) IAccessible_Release(accessible);
  if (capture.editor) {
    MoveWindow(capture.editor,window_rect.left,window_rect.top,window_rect.right-window_rect.left,window_rect.bottom-window_rect.top,FALSE);
    if (ok) smoke_select_tool(TOOL_SELECT);
  }
  printf("Windows shared toolbar %s: pointer and keyboard, numeric focus/history, cancel, MSAA unavailable state, overflow.\n",ok?"passed":"FAILED");
#undef TOOLBAR_CHECK
  return ok;
}
static BOOL hud_surface_smoke(void) {
  BOOL ok=TRUE, original_dark=capture.toolbar_dark;
  Surface pixels={0}; HWND neutral=NULL; int32_t property_frame=0;
  int32_t field_ink[2]={0};
  RECT bounds={0,0,400,120}, card={10,10,390,110};
  MCWinCanvasCallbacks callbacks={0};
#define HUD_CHECK(condition) do { if (!(condition)) { fprintf(stderr,"Windows HUD surface FAILED line %d: %s\n",__LINE__,#condition); ok=FALSE; goto done; } } while (0)
  HUD_CHECK(surface_new(&pixels,1024,200));
  neutral=mc_win_canvas_create(capture.editor,capture.instance,ID_STYLE_BASE+51,&callbacks,NULL);
  HUD_CHECK(neutral && mc_win_canvas_paint(neutral,pixels.dc,&bounds,96));
  HUD_CHECK(GetPixel(pixels.dc,1,1)==RGB(0,0,0));
  HUD_CHECK(!mc_win_canvas_set_background(neutral,-1) && !mc_win_canvas_set_background(neutral,0x1000000));
  HUD_CHECK(mc_win_canvas_paint(neutral,pixels.dc,&bounds,96) && GetPixel(pixels.dc,1,1)==RGB(0,0,0));
  smoke_select_tool(TOOL_RECT);
  for (int dark=0;dark<2;dark++) {
    const wchar_t *mode=dark ? L"dark":L"light";
    MCCanvasInput appearance={0}; appearance.type=MC_UI_INPUT_APPEARANCE;
    appearance.text=(const uint16_t *)mode; appearance.text_length=wcslen(mode);
    toolbar_input(NULL,capture.toolbar_view,&appearance);
    HUD_CHECK(capture.toolbar_dark==dark && capture.text_edit);
    int32_t surface=capture_toolbar_surface_color(dark);
    COLORREF expected=color_ref(surface);
    /* Exercise the actual parent paint path, then each child renderer. Empty
     * child padding must match the card instead of exposing a black rectangle. */
    mc_hud_card(pixels.dc,&card,1,surface);
    HUD_CHECK(GetPixel(pixels.dc,20,30)==expected);
    for (int y=27;y<=41;y++) HUD_CHECK(GetPixel(pixels.dc,290,y)==expected);
    GetClientRect(capture.toolbar_view,&bounds);
    HUD_CHECK(mc_win_canvas_paint(capture.toolbar_view,pixels.dc,&bounds,GetDpiForWindow(capture.editor)));
    HUD_CHECK(GetPixel(pixels.dc,1,1)==expected);
    GetClientRect(capture.text_properties,&bounds);
    HUD_CHECK(mc_win_canvas_paint(capture.text_properties,pixels.dc,&bounds,GetDpiForWindow(capture.editor)));
    HUD_CHECK(GetPixel(pixels.dc,1,1)==expected);
    property_frame=smoke_property_frame();
    HUD_CHECK(property_frame && ui_frame_field_count(property_frame)>0);
    field_ink[dark]=ui_frame_field_value(property_frame,0,MC_UI_FIELD_COLOR);
    HUD_CHECK(field_ink[dark]>=0);
    ui_frame_close(property_frame); property_frame=0;
  }
  HUD_CHECK(field_ink[0]!=field_ink[1]);
done:
  if (property_frame) ui_frame_close(property_frame);
  if (neutral) DestroyWindow(neutral);
  surface_free(&pixels);
  capture.toolbar_dark=original_dark;
  if (capture.editor) { if (ok) smoke_select_tool(TOOL_SELECT); layout_editor(capture.editor); }
  printf("Windows HUD surface %s: one themed card, matching child surfaces, no native divider, default video canvas remains black.\n",ok?"passed":"FAILED");
#undef HUD_CHECK
  return ok;
}
static BOOL centered_field(HWND field) {
  RECT window, client; POINT origin={0,0}; TEXTMETRICW metrics={0};
  if (!GetWindowRect(field,&window) || !GetClientRect(field,&client) || !ClientToScreen(field,&origin)) return FALSE;
  HDC dc=GetDC(field); if (!dc) return FALSE;
  HFONT font=(HFONT)SendMessageW(field,WM_GETFONT,0,0);
  HGDIOBJ previous=SelectObject(dc,font);
  BOOL measured=GetTextMetricsW(dc,&metrics);
  SelectObject(dc,previous); ReleaseDC(field,dc);
  int top=origin.y-window.top, bottom=window.bottom-origin.y-client.bottom;
  LRESULT first=SendMessageW(field,EM_POSFROMCHAR,0,0);
  return measured && top>=0 && bottom>=0 && abs(top-bottom)<=1 &&
      client.bottom==minimum((int)metrics.tmHeight,window.bottom-window.top) && first!=-1 &&
      (short)HIWORD(first)>=0 && (short)HIWORD(first)<client.bottom;
}
static void wheel_field(HWND field,int delta) {
  RECT bounds; GetWindowRect(field,&bounds);
  SendMessageW(field,WM_MOUSEWHEEL,MAKEWPARAM(0,(WORD)(short)delta),
      MAKELPARAM((bounds.left+bounds.right)/2,(bounds.top+bounds.bottom)/2));
}
static BOOL numeric_input_smoke(void) {
  BOOL ok=TRUE;
  double revision=image_session_revision(capture.session);
#define NUMBER_CHECK(condition) do { if (!(condition)) { fprintf(stderr,"Windows numeric input FAILED line %d: %s\n",__LINE__,#condition); ok=FALSE; goto done; } } while (0)
  smoke_select_tool(TOOL_RECT);
  HWND field=mc_win_text_inputs_field(capture.property_inputs,L"style.stroke");
  NUMBER_CHECK(field && centered_field(field));
  SetFocus(field); NUMBER_CHECK(SetWindowTextW(field,L"4"));
  int32_t edit=capture.text_edit;
  wheel_field(field,WHEEL_DELTA);
  NUMBER_CHECK(capture.text_edit==edit && capture.stroke==5 && GetFocus()==field &&
      image_session_revision(capture.session)==revision);
  wheel_field(field,-WHEEL_DELTA);
  NUMBER_CHECK(capture.stroke==4 && GetFocus()==field && centered_field(field));
  SetFocus(capture.editor);
  for (int i=0;i<3;i++) wheel_field(field,WHEEL_DELTA/4);
  NUMBER_CHECK(capture.stroke==4 && GetFocus()==capture.editor);
  wheel_field(field,WHEEL_DELTA/4);
  NUMBER_CHECK(capture.stroke==5 && GetFocus()==capture.editor);
  NUMBER_CHECK(smoke_property_click(L"style.stroke.decrease") && capture.stroke==4);
  NUMBER_CHECK(smoke_property_click(L"style.stroke.increase") && capture.stroke==5);
  SetFocus(field); NUMBER_CHECK(SetWindowTextW(field,L"4"));
  NUMBER_CHECK(SetWindowTextW(field,L"-"));
  wheel_field(field,WHEEL_DELTA);
  wchar_t raw[16]={0}; GetWindowTextW(field,raw,ARRAYSIZE(raw));
  NUMBER_CHECK(!wcscmp(raw,L"-") && capture_text_value(capture.session,edit,MC_CAPTURE_TEXT_VALID)==0);
  NUMBER_CHECK(SetWindowTextW(field,L"4"));
  SendMessageW(field,EM_SETSEL,1,1);
  SendMessageW(field,WM_IME_STARTCOMPOSITION,0,0);
  NUMBER_CHECK(mc_win_text_inputs_composing(capture.property_inputs));
  wheel_field(field,WHEEL_DELTA);
  NUMBER_CHECK(capture.stroke==4 && mc_win_text_inputs_composing(capture.property_inputs));
  SendMessageW(field,WM_IME_ENDCOMPOSITION,0,0);
  NUMBER_CHECK(!mc_win_text_inputs_composing(capture.property_inputs) && GetFocus()==field);
  wheel_field(field,WHEEL_DELTA);
  NUMBER_CHECK(capture.stroke==5 && image_session_revision(capture.session)==revision);
done:
  if (capture.text_edit) finish_text(TRUE);
  if (capture.editor) { if (ok) smoke_select_tool(TOOL_SELECT); layout_editor(capture.editor); }
  printf("Windows numeric input %s: measured centering, native EDIT fractional wheel, shared step buttons, unchanged document, invalid/IME veto and retained focus.\n",ok?"passed":"FAILED");
#undef NUMBER_CHECK
  return ok;
}
static BOOL context_toolbar_smoke(void) {
#define CONTEXT_CHECK(condition) do { if (!(condition)) { fprintf(stderr,"Windows toolbar context FAILED line %d: %s (tool=%d edit=%d version=%d generation=%d)\n",__LINE__,#condition,capture.tool,capture.text_edit,capture.text_edit ? text_version():0,capture.toolbar_generation); return FALSE; } } while (0)
  RECT initial = capture.toolbar;
  CONTEXT_CHECK(!style_visible(MC_STYLE_COLOR) && !style_visible(MC_STYLE_FONT) &&
      !style_visible(MC_STYLE_STROKE));
  smoke_select_tool(TOOL_TEXT);
  CONTEXT_CHECK(style_visible(MC_STYLE_COLOR) && style_visible(MC_STYLE_FONT) &&
      style_visible(MC_STYLE_OPACITY) && !style_visible(MC_STYLE_STROKE) && capture.font_size == 32);
  CONTEXT_CHECK(choose_style(MC_STYLE_COLOR, 0x246BFD) && choose_style(MC_STYLE_OPACITY, .5));
  smoke_select_tool(TOOL_RECT);
  CONTEXT_CHECK(style_visible(MC_STYLE_COLOR) && style_visible(MC_STYLE_STROKE) &&
      !style_visible(MC_STYLE_FONT) && capture.color == 0xF26769 && capture.opacity == 1);
  CONTEXT_CHECK(choose_style(MC_STYLE_STROKE, 8) && choose_style(MC_STYLE_COLOR, 0x25A56A) &&
      choose_style(MC_STYLE_OPACITY, .3));
  step_style(TRUE);
  CONTEXT_CHECK(capture.stroke == 9);
  step_style(FALSE);
  CONTEXT_CHECK(capture.stroke == 8);
  smoke_select_tool(TOOL_ARROW);
  CONTEXT_CHECK(capture.color == 0xF26769 && capture.opacity == 1 && capture.stroke == 4);
  CONTEXT_CHECK(choose_style(MC_STYLE_COLOR, 0xFFFFFF) && choose_style(MC_STYLE_OPACITY, .8));
  smoke_select_tool(TOOL_REDACT);
  CONTEXT_CHECK(style_visible(MC_STYLE_COLOR) && style_visible(MC_STYLE_OPACITY) &&
      !style_visible(MC_STYLE_FONT) && !style_visible(MC_STYLE_STROKE) &&
      capture.color == 0x111111 && capture.opacity == 1);
  CONTEXT_CHECK(choose_style(MC_STYLE_COLOR, 0x25A56A) && choose_style(MC_STYLE_OPACITY, .2));
  smoke_select_tool(TOOL_TEXT);
  CONTEXT_CHECK(capture.color == 0x246BFD && capture.opacity == .5);
  smoke_select_tool(TOOL_RECT);
  CONTEXT_CHECK(capture.color == 0x25A56A && capture.opacity == .3 && capture.stroke == 8);
  smoke_select_tool(TOOL_ARROW);
  CONTEXT_CHECK(capture.color == 0xFFFFFF && capture.opacity == .8);
  smoke_select_tool(TOOL_REDACT);
  CONTEXT_CHECK(capture.color == 0x25A56A && capture.opacity == .2);
  // Restore the drawing defaults before the existing geometry/export fixture.
  for (int tool = TOOL_RECT; tool <= TOOL_REDACT; tool++) {
    smoke_select_tool(tool);
    unsigned mask = (unsigned)editor_style_visible_mask(tool, 0);
    for (int field = 0; field < MC_STYLE_PROPERTY_COUNT; field++)
      if (mask & (1u << field)) CONTEXT_CHECK(choose_style(field,
          tool == TOOL_REDACT && field == MC_STYLE_COLOR ? 0x111111 : editor_style_default(field)));
  }
  int unavailable=0;
  HWND tooltip=NULL; EnumThreadWindows(GetCurrentThreadId(),smoke_find_toolbar_tip,(LPARAM)&tooltip);
  CONTEXT_CHECK(tooltip);
  CONTEXT_CHECK(smoke_action_enabled(L"pin"));
  for (int i=0;i<ui_frame_semantic_count(capture.toolbar_frame);i++) {
    if (ui_frame_semantic_value(capture.toolbar_frame,i,MC_UI_SEM_ENABLED)==1) continue;
    moonbit_string_t id=ui_frame_semantic_text(capture.toolbar_frame,i,MC_UI_SEM_ID);
    BOOL contribution=Moonbit_array_length(id)>8 && !memcmp(id,L"builtin.",8*sizeof(wchar_t));
    moonbit_decref(id); if (!contribution) continue;
    unavailable++;
    double scale=(double)GetDpiForWindow(capture.toolbar_view)/96;
    TTHITTESTINFOW hit={0}; hit.hwnd=capture.toolbar_view; hit.ti.cbSize=sizeof(hit.ti);
    hit.pt.x=rounded((ui_frame_semantic_number(capture.toolbar_frame,i,MC_UI_SEM_X)+
      ui_frame_semantic_number(capture.toolbar_frame,i,MC_UI_SEM_WIDTH)/2)*scale);
    hit.pt.y=rounded((ui_frame_semantic_number(capture.toolbar_frame,i,MC_UI_SEM_Y)+
      ui_frame_semantic_number(capture.toolbar_frame,i,MC_UI_SEM_HEIGHT)/2)*scale);
    CONTEXT_CHECK(SendMessageW(tooltip,TTM_HITTESTW,0,(LPARAM)&hit));
    wchar_t label[256]={0}; TOOLINFOW tip={sizeof(tip)}; tip.hwnd=capture.toolbar_view;
    tip.uId=hit.ti.uId; tip.lpszText=label;
    SendMessageW(tooltip,TTM_GETTEXTW,ARRAYSIZE(label),(LPARAM)&tip);
    moonbit_string_t expected=ui_frame_semantic_text(capture.toolbar_frame,i,MC_UI_SEM_TOOLTIP);
    BOOL matches=(size_t)Moonbit_array_length(expected)==wcslen(label) &&
      !memcmp(expected,label,wcslen(label)*sizeof(wchar_t)); moonbit_decref(expected);
    CONTEXT_CHECK(matches && *label);
  }
  CONTEXT_CHECK(unavailable >= 2);
  editor_command(ID_SELECT);
  CONTEXT_CHECK(EqualRect(&initial, &capture.toolbar) && !style_visible(MC_STYLE_COLOR) &&
      !style_visible(MC_STYLE_FONT));
#undef CONTEXT_CHECK
  return TRUE;
}
static BOOL independent_text_style_smoke(void) {
  smoke_select_tool(TOOL_TEXT);
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
      !finish_text(FALSE) || !image_session_undo(capture.session) || image_session_value(capture.session, index, 7) != 60)
    return FALSE;
  load_annotation_style(index);
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(600, 400));
  if (capture.selected != -1 || capture.color != 0x246BFD || capture.opacity != .5 || capture.font_size != 41)
    return FALSE;
  smoke_select_tool(TOOL_RECT);
  if (capture.color != 0xF26769 || capture.opacity != 1 || capture.stroke != 4)
    return FALSE;
  smoke_select_tool(TOOL_TEXT);
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
  if (!finish_text(FALSE)) return FALSE;
  image_session_remove(capture.session, index);
  editor_command(ID_SELECT);
  return image_session_count(capture.session) == 0;
}
static BOOL text_equals(const wchar_t *expected) {
  moonbit_string_t raw = capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RAW);
  BOOL equal = Moonbit_array_length(raw) == (int)wcslen(expected) &&
    !memcmp(raw, expected, wcslen(expected) * sizeof(wchar_t));
  moonbit_decref(raw); return equal;
}
typedef struct { MCWinTextInputs *inputs; BOOL retired; } TextRetireProbe;
static BOOL retire_text_on_focus(void *context, HWND field, moonbit_string_t event) {
  (void)field; (void)event;
  TextRetireProbe *probe = context;
  MCWinTextInputs *inputs = probe->inputs; probe->inputs = NULL; probe->retired = TRUE;
  mc_win_text_inputs_destroy(inputs); return FALSE;
}
static BOOL text_retirement_smoke(void) {
  /* Exercise the real alpha-zero parent hit path. Acquiring native focus calls
   * the owner, which retires this very field/group before mouse-down resumes. */
  HWND parent = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE, 400, 30, 120, 80,
      capture.editor, NULL, capture.instance, NULL);
  if (!parent) return FALSE;
  TextRetireProbe probe = {0};
  MCWinTextCallbacks callbacks = {retire_text_on_focus, NULL, NULL, NULL, NULL};
  probe.inputs = mc_win_text_inputs_create(parent, capture.instance, &callbacks, &probe);
  int32_t frame = open_text_frame(MC_CAPTURE_TEXT_INLINE, 100, 60, 1);
  BOOL ok = probe.inputs && frame && mc_win_text_inputs_set_frame(probe.inputs, frame, 0, 0, 1);
  if (frame) ui_frame_close(frame);
  HWND field = mc_win_text_inputs_field(probe.inputs, L"annotation.text");
  SetFocus(capture.editor);
  if (ok) SendMessageW(parent, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(3, 8));
  ok = ok && probe.retired && !IsWindow(field);
  if (probe.inputs) mc_win_text_inputs_destroy(probe.inputs);
  DestroyWindow(parent); return ok;
}
static BOOL text_ime_rejection_smoke(void) {
  BOOL ok = FALSE; int before = image_session_count(capture.session);
  wchar_t *native = calloc(10002, sizeof(wchar_t));
  if (!native) return FALSE;
  for (int i = 0; i < 9999; i++) native[i] = L'x';
  smoke_select_tool(TOOL_TEXT); begin_text((POINT){30, 40}, -1);
  HWND body = capture.text;
  if (!body || !SetWindowTextW(body, native)) goto done;
  SetFocus(body); SendMessageW(body, EM_SETSEL, 9999, 9999);
  SendMessageW(body, WM_IME_STARTCOMPOSITION, 0, 0);
  if (!mc_win_text_inputs_composing(capture.body_inputs)) goto done;
  /* Replay copied IMM facts after updating the real EDIT, as its default
   * procedure does. This exercises the production provider/ACK path without
   * depending on which language IMEs happen to be installed on a CI runner. */
  native[9999] = L'你'; SetWindowTextW(body, native); SendMessageW(body, EM_SETSEL, 10000, 10000);
  if (!mc_win_text_inputs_composition(capture.body_inputs, body, NULL, L"你", 1, FALSE)) goto done;
  native[10000] = L'好'; SetWindowTextW(body, native); SendMessageW(body, EM_SETSEL, 10001, 10001);
  if (mc_win_text_inputs_composition(capture.body_inputs, body, L"你好", NULL, -1, FALSE) ||
      mc_win_text_inputs_composing(capture.body_inputs) || capture.composing ||
      GetWindowTextLengthW(body) != 9999) goto done;
  native[9999] = 0;
  if (!text_equals(native)) goto done;
  int32_t frame = open_text_frame(MC_CAPTURE_TEXT_INLINE, 280, 100, 1);
  BOOL terminal = frame && ui_frame_field_value(frame, 0, MC_UI_FIELD_MARKED_START) < 0;
  if (frame) ui_frame_close(frame);
  if (!terminal) goto done;
  SendMessageW(body, WM_IME_ENDCOMPOSITION, 0, 0);
  SendMessageW(body, WM_CHAR, L'Z', 1);
  native[9999] = L'Z'; native[10000] = 0;
  if (!text_equals(native) || !finish_text(FALSE) || image_session_count(capture.session) != before + 1) goto done;
  image_session_remove(capture.session, capture.selected); capture.selected = -1;
  editor_command(ID_SELECT); ok = image_session_count(capture.session) == before;
done:
  if (!ok && capture.text_edit) finish_text(TRUE);
  free(native);
  printf("Windows decoded IMM rejection %s: 9999 + preedit 1, rejected result 2, restored draft, typed and published 10000.\n", ok ? "passed" : "FAILED");
  return ok;
}
static BOOL text_cover_preview_smoke(void) {
  BOOL ok = TRUE; int initial_count = image_session_count(capture.session);
  Surface base = {0}, live = {0};
  double old_font = editor_style_get(capture.style_bank, TOOL_TEXT, MC_STYLE_FONT);
  double old_opacity = editor_style_get(capture.style_bank, TOOL_TEXT, MC_STYLE_OPACITY);
  int old_color = (int)editor_style_get(capture.style_bank, TOOL_TEXT, MC_STYLE_COLOR);
  if (!surface_new(&base, capture.image.width, capture.image.height) ||
      !surface_new(&live, capture.image.width, capture.image.height)) { ok = FALSE; goto done; }
  smoke_select_tool(TOOL_TEXT);
  if (!choose_style(MC_STYLE_FONT, 32) || !choose_style(MC_STYLE_OPACITY, 1) ||
      !choose_style(MC_STYLE_COLOR, 0) || !finish_text(FALSE)) { ok = FALSE; goto done; }
  for (int pass = 0; pass < 2 && ok; pass++) {
    if (!image_session_add_rgba(capture.session, TOOL_REDACT, 40, 60, 50, 40, 0x204080, 4, 24, pass * .5)) { ok = FALSE; break; }
    int mask = image_session_count(capture.session) - 1;
    begin_text((POINT){40, 60}, -1);
    if (!capture.text || !SetWindowTextW(capture.text, L"MMMMMMMM") || !render_image_mode(FALSE)) { ok = FALSE; break; }
    BitBlt(base.dc, 0, 0, base.width, base.height, capture.rendered.dc, 0, 0, SRCCOPY);
    SendMessageW(capture.editor, WM_PRINTCLIENT, (WPARAM)live.dc, PRF_CLIENT);
    if (!render_image()) { ok = FALSE; break; }
    GdiFlush();
    int covered_ink = 0, native_ink = 0;
    for (int y = 61; y < 98; y++) for (int x = 41; x < 250; x++) {
      SIZE_T offset = ((SIZE_T)y * base.width + x) * 4;
      const BYTE *under = base.pixels + offset, *output = capture.rendered.pixels + offset, *shown = live.pixels + offset;
      if (x < 90) {
        if (memcmp(under, output, 3)) covered_ink++;
        if (memcmp(shown, output, 3)) ok = FALSE;
      } else {
        /* Parent paint must leave the remaining glyphs to the real EDIT. */
        if (memcmp(under, output, 3)) native_ink++;
        if (memcmp(shown, under, 3)) ok = FALSE;
      }
    }
    if (covered_ink < 20 || native_ink < 20) ok = FALSE;
    if (!finish_text(TRUE) || !image_session_remove(capture.session, mask)) { ok = FALSE; break; }
    capture.selected = -1;
  }
  if (ok) {
    layout_editor(capture.editor);
    ok = choose_style(MC_STYLE_FONT, old_font) && choose_style(MC_STYLE_OPACITY, old_opacity) && choose_style(MC_STYLE_COLOR, old_color) && finish_text(FALSE);
    editor_command(ID_SELECT);
  }
done:
  surface_free(&base); surface_free(&live);
  if (!ok && capture.text_edit) finish_text(TRUE);
  printf("Windows covered input pixels %s: transparent/half-opacity cover matches export; uncovered input painted once.\n", ok ? "passed" : "FAILED");
  return ok && image_session_count(capture.session) == initial_count;
}
static BOOL text_document_boundaries_smoke(void) {
  BOOL ok = TRUE;
  int initial_count = image_session_count(capture.session);
  RECT original_viewport = capture.viewport;
  double original_font = editor_style_get(capture.style_bank, TOOL_TEXT, MC_STYLE_FONT);
#define BOUNDARY_CHECK(condition) do { if (!(condition)) { fprintf(stderr, "Windows text boundary FAILED line %d: %s\n", __LINE__, #condition); ok = FALSE; goto done; } } while (0)
  smoke_select_tool(TOOL_TEXT);
  begin_text((POINT){30, 40}, -1);
  BOUNDARY_CHECK(capture.text && SetWindowTextW(capture.text, L"Delete boundary") && finish_text(FALSE));
  layout_editor(capture.editor);
  HWND font = mc_win_text_inputs_field(capture.property_inputs, L"style.fontSize");
  BOUNDARY_CHECK(font && SetWindowTextW(font, L"-"));
  SetFocus(capture.editor);
  MSG remove = {0}; remove.hwnd = capture.editor; remove.message = WM_KEYDOWN; remove.wParam = VK_DELETE;
  BOUNDARY_CHECK(mc_capture_handle_message(&remove) && image_session_count(capture.session) == initial_count + 1 &&
      capture.text_edit && capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_VALID) == 0);
  wchar_t raw_font[64]; swprintf_s(raw_font, ARRAYSIZE(raw_font), L"%.10g", original_font);
  BOUNDARY_CHECK(SetWindowTextW(font, raw_font)); SetFocus(capture.editor);
  BOUNDARY_CHECK(mc_capture_handle_message(&remove) && image_session_count(capture.session) == initial_count);
  editor_command(ID_SELECT);
  BOUNDARY_CHECK(!capture.text_edit && capture.tool == TOOL_SELECT);

  // Resize the screenshot while Text is the current tool. Default properties
  // must reopen only after crop publication, against that exact new revision.
  smoke_select_tool(TOOL_TEXT); SetFocus(capture.editor);
  int x = original_viewport.right, y = original_viewport.bottom;
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(x, y));
  BOUNDARY_CHECK(capture.dragging && capture.drag_mode == 2 && !capture.text_edit);
  SendMessageW(capture.editor, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(x + 10, y + 10));
  BOUNDARY_CHECK(image_session_viewport_value(capture.session, 2) == original_viewport.right - original_viewport.left);
  SendMessageW(capture.editor, WM_LBUTTONUP, 0, MAKELPARAM(x + 10, y + 10));
  BOUNDARY_CHECK(!capture.dragging && capture.text_edit &&
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_VALID) == 1 &&
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_MODE) == MC_CAPTURE_TEXT_DEFAULTS &&
      image_session_viewport_value(capture.session, 2) == original_viewport.right - original_viewport.left + 10);
  BOUNDARY_CHECK(choose_style(MC_STYLE_FONT, original_font));
  editor_command(ID_UNDO);
  BOUNDARY_CHECK(EqualRect(&capture.viewport, &original_viewport));
  editor_command(ID_SELECT);
  BOUNDARY_CHECK(!capture.text_edit && image_session_count(capture.session) == initial_count);
done:
  printf("Windows text document boundaries %s: invalid draft vetoes Delete; valid Delete and text-tool crop settle before changing the document.\n", ok ? "passed" : "FAILED");
  return ok;
#undef BOUNDARY_CHECK
}
static BOOL shared_text_fields_smoke(void) {
  BOOL ok = TRUE; int initial_count = image_session_count(capture.session);
  BOOL was_visible = IsWindowVisible(capture.editor);
  double old_font = editor_style_get(capture.style_bank, TOOL_TEXT, MC_STYLE_FONT);
  double old_opacity = editor_style_get(capture.style_bank, TOOL_TEXT, MC_STYLE_OPACITY);
  int old_color = (int)editor_style_get(capture.style_bank, TOOL_TEXT, MC_STYLE_COLOR);
  moonbit_string_t stale = NULL;
#define TEXT_CHECK(condition) do { if (!(condition)) { fprintf(stderr, "Windows shared text FAILED line %d: %s\n", __LINE__, #condition); ok = FALSE; goto done; } } while (0)
  smoke_select_tool(TOOL_TEXT);
  TEXT_CHECK(choose_style(MC_STYLE_FONT, 31.25));
  begin_text((POINT){30, 40}, -1);
  HWND body = capture.text;
  TEXT_CHECK(body && SetWindowTextW(body, L"A\r\n🌙B") && text_equals(L"A\n🌙B"));
  SendMessageW(body, EM_SETSEL, 3, 5); /* native CRLF + emoji => shared [2,4). */
  int32_t frame = open_text_frame(MC_CAPTURE_TEXT_INLINE, 280, 100, 1);
  TEXT_CHECK(frame && ui_frame_field_count(frame) == 1);
  BOOL offsets = ui_frame_field_value(frame, 0, MC_UI_FIELD_ANCHOR) == 2 &&
    ui_frame_field_value(frame, 0, MC_UI_FIELD_FOCUS) == 4 &&
    ui_frame_field_value(frame, 0, MC_UI_FIELD_SELECTION_KNOWN) == 1 &&
    ui_frame_field_value(frame, 0, MC_UI_FIELD_DIRECTION_KNOWN) == 0;
  MCCanvasTextInput late = {0}; late.type = MC_UI_TEXT_REPLACE; late.token = ui_frame_field_value(frame, 0, MC_UI_FIELD_TOKEN);
  late.version = ui_frame_field_value(frame, 0, MC_UI_FIELD_VERSION); late.id = (const uint16_t *)L"annotation.text";
  late.id_length = wcslen(L"annotation.text"); late.selection_kind = MC_UI_SELECTION_UNKNOWN;
  late.text = (const uint16_t *)L"late"; late.text_length = 4;
  stale = mc_canvas_text_input_json(&late); ui_frame_close(frame);
  TEXT_CHECK(offsets);
  wchar_t malformed[] = {0xd83c, 0};
  SetWindowTextW(body, malformed);
  TEXT_CHECK(text_equals(L"A\n🌙B") && GetWindowTextLengthW(body) == 6);
  wchar_t *too_long = calloc(10002, sizeof(wchar_t)); TEXT_CHECK(too_long);
  for (int i = 0; i < 10001; i++) too_long[i] = L'x';
  SetWindowTextW(body, too_long); free(too_long);
  TEXT_CHECK(text_equals(L"A\n🌙B") && GetWindowTextLengthW(body) == 6);
  TEXT_CHECK(choose_style(MC_STYLE_OPACITY, .5));
  HRGN region = CreateRectRgn(0, 0, 0, 0); RECT input_bounds;
  int region_type = GetWindowRgn(body, region); GetRgnBox(region, &input_bounds); DeleteObject(region);
  TEXT_CHECK(region_type != NULLREGION && input_bounds.right > input_bounds.left && input_bounds.bottom > input_bounds.top);
  BYTE alpha = 0; DWORD flags = 0; COLORREF key = 0;
  TEXT_CHECK(GetLayeredWindowAttributes(body, &key, &alpha, &flags) && alpha == 128 && (flags & LWA_ALPHA));
  ShowWindow(capture.editor, SW_SHOWNOACTIVATE); SetForegroundWindow(capture.editor); SetFocus(body);
  RedrawWindow(capture.editor, NULL, NULL, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
  POINT hit = {3, 8}; ClientToScreen(body, &hit);
  TEXT_CHECK(WindowFromPoint(hit) == body);
  TEXT_CHECK(choose_style(MC_STYLE_OPACITY, 0));
  TEXT_CHECK(text_retirement_smoke());
  SetFocus(capture.editor);
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(capture.draft.left + 3, capture.draft.top + 8));
  SendMessageW(body, WM_LBUTTONUP, 0, MAKELPARAM(3, 8));
  TEXT_CHECK(GetFocus() == body);
  TEXT_CHECK(choose_style(MC_STYLE_OPACITY, .5)); SetFocus(body);
  LRESULT after_first = SendMessageW(body, EM_POSFROMCHAR, 1, 0);
  int end_x = maximum(8, (short)LOWORD(after_first));
  SendMessageW(body, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(0, 8));
  SendMessageW(body, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(end_x, 8));
  SendMessageW(body, WM_LBUTTONUP, 0, MAKELPARAM(end_x, 8));
  DWORD selection_start = 0, selection_end = 0;
  SendMessageW(body, EM_GETSEL, (WPARAM)&selection_start, (LPARAM)&selection_end);
  TEXT_CHECK(selection_end > selection_start);
  SendMessageW(body, WM_CHAR, L'Z', 1);
  TEXT_CHECK(text_equals(L"Z\n🌙B"));
  HWND font = mc_win_text_inputs_field(capture.property_inputs, L"style.fontSize");
  TEXT_CHECK(font);
  SetFocus(font); SetWindowTextW(font, L"32.25");
  TEXT_CHECK(capture.font_size == 32.25);
  SetFocus(body); editor_command(ID_UNDO);
  if (!text_equals(L"A\n🌙B") || capture.font_size != 32.25) {
    moonbit_string_t raw = capture_text_text(capture.session, capture.text_edit, MC_CAPTURE_TEXT_RAW);
    fprintf(stderr, "Windows field undo: focusBody=%d font=%.17g rawUnits=%d:",
            GetFocus() == body, capture.font_size, Moonbit_array_length(raw));
    for (int i = 0; i < Moonbit_array_length(raw) && i < 32; i++) fprintf(stderr, " %04x", (unsigned)raw[i]);
    fputc('\n', stderr); moonbit_decref(raw);
  }
  TEXT_CHECK(text_equals(L"A\n🌙B") && capture.font_size == 32.25); /* active body, not last edited property */
  editor_command(ID_REDO); TEXT_CHECK(text_equals(L"Z\n🌙B"));
  SetFocus(font); SetWindowTextW(font, L"-");
  double revision = image_session_revision(capture.session);
  TEXT_CHECK(!finish_text(FALSE) && image_session_revision(capture.session) == revision && IsWindow(body));
  SetWindowTextW(font, L"31.25");
  IAccessible *accessible = NULL;
  HRESULT accessibility = AccessibleObjectFromWindow(font, (DWORD)OBJID_CLIENT, &IID_IAccessible, (void **)&accessible);
  BSTR name = NULL; VARIANT self; VariantInit(&self); self.vt = VT_I4; self.lVal = CHILDID_SELF;
  if (SUCCEEDED(accessibility)) accessibility = IAccessible_get_accName(accessible, self, &name);
  BOOL named = SUCCEEDED(accessibility) && name && SysStringLen(name) > 0;
  if (name) SysFreeString(name); if (accessible) IAccessible_Release(accessible);
  TEXT_CHECK(named);
  int32_t retired_edit = capture.text_edit;
  TEXT_CHECK(finish_text(FALSE) && image_session_count(capture.session) == initial_count + 1);
  int index = capture.selected;
  TEXT_CHECK(image_session_value(capture.session, index, 7) == 31.25 && image_session_value(capture.session, index, 8) == .5);
  TEXT_CHECK(capture_text_event_json(capture.session, retired_edit, 0, stale) == 0);
  TEXT_CHECK(image_session_undo(capture.session) && image_session_count(capture.session) == initial_count);
  TEXT_CHECK(image_session_redo(capture.session) && image_session_count(capture.session) == initial_count + 1);
  moonbit_string_t moved_id = image_session_annotation_id(capture.session, index);
  double start_x = image_session_value(capture.session, index, 1), start_y = image_session_value(capture.session, index, 2);
  BOOL clipped = image_session_geometry(capture.session, image_session_revision(capture.session), moved_id,
      start_x, start_y, image_session_value(capture.session, index, 3), 20, -1);
  moonbit_decref(moved_id); TEXT_CHECK(clipped);
  POINT drag = {rounded(start_x) + 100, rounded(start_y) + 10};
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(drag.x, drag.y));
  SendMessageW(capture.editor, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(drag.x + 5, drag.y + 7));
  SendMessageW(capture.editor, WM_LBUTTONUP, 0, MAKELPARAM(drag.x + 5, drag.y + 7));
  TEXT_CHECK(image_session_value(capture.session, index, 1) == start_x + 5 &&
      image_session_value(capture.session, index, 4) == 20 && image_session_value(capture.session, index, 7) == 31.25);
  double before_x = image_session_value(capture.session, index, 1);
  SetFocus(capture.editor); MSG key_event = {0}; key_event.hwnd = capture.editor; key_event.message = WM_KEYDOWN; key_event.wParam = VK_RIGHT;
  TEXT_CHECK(mc_capture_handle_message(&key_event) && image_session_value(capture.session, index, 1) == before_x + 1 &&
      image_session_value(capture.session, index, 7) == 31.25 && image_session_value(capture.session, index, 4) == 20);
  TEXT_CHECK(finish_text(FALSE));
  image_session_remove(capture.session, index); capture.selected = -1;
  layout_editor(capture.editor);
  TEXT_CHECK(choose_style(MC_STYLE_FONT, old_font) && choose_style(MC_STYLE_OPACITY, old_opacity) && choose_style(MC_STYLE_COLOR, old_color));
  TEXT_CHECK(finish_text(FALSE));
  editor_command(ID_SELECT);
  TEXT_CHECK(image_session_count(capture.session) == initial_count);
done:
  if (stale) moonbit_decref(stale);
  if (!was_visible && capture.editor) ShowWindow(capture.editor, SW_HIDE);
  if (!ok && capture.text_edit) finish_text(TRUE);
  printf("Windows shared text fields %s: LF/UTF16 emoji, draft undo/focus, native alpha input, numeric draft, MSAA, atomic publish and fractional move.\n", ok ? "passed" : "FAILED");
#undef TEXT_CHECK
  return ok;
}
static BOOL shape_variants_smoke(void) {
  if (!finish_text(FALSE)) return FALSE;
  int original_session=capture.session, original_bank=capture.style_bank, original_toolbar=capture.toolbar_session;
  capture.session = image_session_create_viewport(capture.image.width, capture.image.height, 10, 20, 320, 200);
  capture.style_bank = editor_style_create();
  capture.toolbar_session=capture_toolbar_open(capture.session,capture.style_bank,capture.tool_snapshot);
  capture.tool=TOOL_SELECT; capture.selected=-1; changed();
  BOOL ok=capture.toolbar_session>0;
  for (int tool = TOOL_RECT; tool <= TOOL_REDACT; tool += 3) {
    for (int shape = 0; shape < editor_style_shape_count(tool); shape++) {
      smoke_select_tool(tool);
      ok = choose_style(MC_STYLE_SHAPE, shape) && ok;
      if (shape == 2) ok = choose_style(MC_STYLE_BLOCK, 16) && !choose_style(MC_STYLE_OPACITY, .5) && ok;
      int count = image_session_count(capture.session);
      SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(100, 100));
      SendMessageW(capture.editor, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(180, 160));
      ok = image_session_count(capture.session) == count && render_image() && ok;
      SendMessageW(capture.editor, WM_LBUTTONUP, 0, MAKELPARAM(180, 160));
      ok = image_session_count(capture.session) == count + 1 &&
        (int)image_session_value(capture.session, count, 9) == shape && render_image() && ok;
      if (tool == TOOL_REDACT && shape == 1) {
        const BYTE *corner = capture.rendered.pixels + ((SIZE_T)100 * capture.image.width + 100) * 4;
        const BYTE *source = capture.image.pixels + ((SIZE_T)100 * capture.image.width + 100) * 4;
        const BYTE *center = capture.rendered.pixels + ((SIZE_T)130 * capture.image.width + 140) * 4;
        ok = memcmp(corner, source, 3) == 0 && center[0] == 17 && center[1] == 17 && center[2] == 17 && ok;
      }
      if (shape == 2) {
        ok = image_session_value(capture.session, count, 10) == 16 && ok;
        const BYTE *a = capture.rendered.pixels + ((SIZE_T)120 * capture.image.width + 120) * 4;
        const BYTE *b = a + 4;
        ok = memcmp(a, b, 3) == 0 && ok;
      }
      editor_command(ID_UNDO);
      ok = image_session_count(capture.session) == count && ok;
    }
  }
  ok = finish_text(FALSE) && ok;
  capture_toolbar_close(capture.toolbar_session);
  image_session_dispose(capture.session); editor_style_dispose(capture.style_bank);
  capture.session=original_session; capture.style_bank=original_bank; capture.toolbar_session=original_toolbar;
  capture.tool=TOOL_SELECT; capture.selected=-1; changed();
  editor_command(ID_SELECT); changed();
  printf("Windows shape variants smoke %s: native input, shared gesture commit, ellipse pixels, mosaic, undo.\n", ok ? "passed" : "FAILED");
  return ok;
}
typedef struct { BOOL seen, vetoed; int attempts; } ColorDialogProbe;
static ColorDialogProbe color_dialog_probe;
static BOOL CALLBACK cancel_fixture_color(HWND window, LPARAM parameter) {
  (void)parameter;
  wchar_t name[32] = {0}; GetClassNameW(window, name, ARRAYSIZE(name));
  if (!IsWindowVisible(window) || GetWindow(window, GW_OWNER) != capture.editor || wcscmp(name, L"#32770")) return TRUE;
  color_dialog_probe.seen = TRUE;
  color_dialog_probe.vetoed = !mc_capture_prepare_tools(capture.tool_snapshot);
  SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), (LPARAM)GetDlgItem(window, IDCANCEL));
  return FALSE;
}
static void CALLBACK cancel_fixture_color_tick(HWND window, UINT message, UINT_PTR timer, DWORD time) {
  (void)window; (void)message; (void)time;
  color_dialog_probe.attempts++;
  EnumThreadWindows(GetCurrentThreadId(), cancel_fixture_color, 0);
  if (color_dialog_probe.seen || color_dialog_probe.attempts >= 100) {
    KillTimer(NULL, timer);
    if (!color_dialog_probe.seen) { fprintf(stderr, "Windows color fixture did not find its owned dialog.\n"); PostQuitMessage(1); }
  }
}
static BOOL fractional_pixels_equal(const Surface *expected, const char *stage) {
  SIZE_T bytes = (SIZE_T)expected->width * expected->height * 4;
  if (!memcmp(expected->pixels, capture.rendered.pixels, bytes)) return TRUE;
  for (SIZE_T offset = 0; offset < bytes; offset++) {
    if (expected->pixels[offset] == capture.rendered.pixels[offset]) continue;
    fprintf(stderr, "Windows fractional pixels FAILED %s: x=%zu y=%zu channel=%zu expected=%u actual=%u\n",
        stage, (size_t)((offset / 4) % expected->width), (size_t)((offset / 4) / expected->width),
        (size_t)(offset % 4), (unsigned)expected->pixels[offset], (unsigned)capture.rendered.pixels[offset]);
    break;
  }
  return FALSE;
}
static BOOL fractional_property_pixels_smoke(int index) {
  Surface expected = {0};
  BOOL ok = TRUE;
#define FRACTIONAL_CHECK(condition) do { if (!(condition)) { fprintf(stderr, "Windows fractional properties FAILED line %d: %s\n", __LINE__, #condition); ok = FALSE; goto done; } } while (0)
  FRACTIONAL_CHECK(finish_text(FALSE));
  moonbit_string_t id = image_session_annotation_id(capture.session, index);
  BOOL moved = image_session_geometry(capture.session, image_session_revision(capture.session), id,
      10.4, 10.4, 70.4, 50.4, -1);
  moonbit_decref(id);
  FRACTIONAL_CHECK(moved);
  capture.dirty = TRUE;
  FRACTIONAL_CHECK(render_image());
  FRACTIONAL_CHECK(surface_new(&expected, capture.image.width, capture.image.height));
  SIZE_T bytes = (SIZE_T)expected.width * expected.height * 4;
  memcpy(expected.pixels, capture.rendered.pixels, bytes);
  capture.selected = index;
  /* Match the production selection refresh: finishing retired the previous
   * native fields, so the new shared frame must be laid out before typing.
   * sync_properties alone only creates the MoonBit transaction/preview. */
  changed();
  FRACTIONAL_CHECK(capture.text_edit && render_image());
  FRACTIONAL_CHECK(fractional_pixels_equal(&expected, "selected preview"));
  HWND stroke = mc_win_text_inputs_field(capture.property_inputs, L"style.stroke");
  FRACTIONAL_CHECK(stroke && IsWindow(stroke));
  FRACTIONAL_CHECK(SetWindowTextW(stroke, L"7.25"));
  FRACTIONAL_CHECK(capture.stroke == 7.25 && render_image());
  memcpy(expected.pixels, capture.rendered.pixels, bytes);
  FRACTIONAL_CHECK(finish_text(FALSE));
  capture.dirty = TRUE;
  FRACTIONAL_CHECK(render_image());
  FRACTIONAL_CHECK(fractional_pixels_equal(&expected, "committed style"));
  FRACTIONAL_CHECK(image_session_value(capture.session, index, 1) == 10.4 &&
      image_session_value(capture.session, index, 3) == 70.4 &&
      image_session_value(capture.session, index, 6) == 7.25);
done:
  surface_free(&expected);
  printf("Windows fractional property pixels %s: selection and draft commit preserve exact geometry.\n", ok ? "passed" : "FAILED");
#undef FRACTIONAL_CHECK
  return ok;
}
static BOOL shared_properties_smoke(void) {
  BOOL ok = TRUE;
  int initial_count = image_session_count(capture.session);
  int32_t baseline = capture.tool_snapshot;
#define PROPERTY_CHECK(condition) do { if (!(condition)) { fprintf(stderr, "Windows shared properties FAILED line %d: %s\n", __LINE__, #condition); ok = FALSE; goto done; } } while (0)
  smoke_select_tool(TOOL_RECT);
  HWND stroke = mc_win_text_inputs_field(capture.property_inputs, L"style.stroke");
  PROPERTY_CHECK(stroke && style_visible(MC_STYLE_SHAPE) && !style_visible(MC_STYLE_FONT));
  double revision = image_session_revision(capture.session);
  int32_t edit = capture.text_edit;
  SetFocus(stroke); SetWindowTextW(stroke, L"-");
  PROPERTY_CHECK(capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_VALID) == 0 && !mc_capture_prepare_tools(baseline));
  smoke_select_tool(TOOL_ARROW);
  PROPERTY_CHECK(capture.tool == TOOL_RECT && capture.text_edit == edit && image_session_revision(capture.session) == revision);
  PROPERTY_CHECK(!smoke_property_click(L"style.shape.1") && capture.shape == 0);
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(120, 80));
  PROPERTY_CHECK(!capture.dragging && capture.text_edit == edit);
  SetFocus(stroke); SetWindowTextW(stroke, L"4.25");
  PROPERTY_CHECK(capture.stroke == 4.25 && editor_style_get(capture.style_bank, TOOL_RECT, MC_STYLE_STROKE) == 4);
  editor_command(ID_UNDO);
  PROPERTY_CHECK(capture_text_value(capture.session, edit, MC_CAPTURE_TEXT_VALID) == 0 && image_session_revision(capture.session) == revision);
  editor_command(ID_REDO); PROPERTY_CHECK(capture.stroke == 4.25);
  SendMessageW(stroke, WM_KEYDOWN, VK_UP, 1); PROPERTY_CHECK(capture.stroke == 5.25);
  SendMessageW(stroke, WM_KEYDOWN, VK_DOWN, 1); PROPERTY_CHECK(capture.stroke == 4.25);
  PROPERTY_CHECK(smoke_property_click(L"style.shape.1") && capture.shape == 1 &&
      editor_style_get(capture.style_bank, TOOL_RECT, MC_STYLE_SHAPE) == 0);
  editor_command(ID_UNDO); PROPERTY_CHECK(capture.shape == 0 && capture.stroke == 4.25);
  editor_command(ID_REDO); PROPERTY_CHECK(capture.shape == 1 && capture.stroke == 4.25);
  PROPERTY_CHECK(mc_capture_prepare_tools(baseline) && capture.text_edit == edit &&
      editor_style_get(capture.style_bank, TOOL_RECT, MC_STYLE_STROKE) == 4);
  mc_capture_discard_tools(); PROPERTY_CHECK(capture.text_edit == edit && finish_text(FALSE));
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(120, 80));
  SendMessageW(capture.editor, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(220, 140));
  SendMessageW(capture.editor, WM_LBUTTONUP, 0, MAKELPARAM(220, 140));
  int index = image_session_count(capture.session) - 1;
  PROPERTY_CHECK(index == initial_count && image_session_value(capture.session, index, 6) == 4.25 &&
      image_session_value(capture.session, index, 9) == 1);
  smoke_select_tool(TOOL_SELECT);
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(120, 110));
  SendMessageW(capture.editor, WM_LBUTTONUP, 0, MAKELPARAM(120, 110));
  PROPERTY_CHECK(capture.selected == index && property_tool() == TOOL_RECT);
  revision = image_session_revision(capture.session);
  stroke = mc_win_text_inputs_field(capture.property_inputs, L"style.stroke");
  PROPERTY_CHECK(stroke && SetWindowTextW(stroke, L"7.5"));
  HWND opacity = mc_win_text_inputs_field(capture.property_inputs, L"style.opacity");
  PROPERTY_CHECK(opacity && SetWindowTextW(opacity, L"45") && smoke_property_click(L"style.shape.0"));
  PROPERTY_CHECK(image_session_revision(capture.session) == revision && capture.stroke == 7.5 && capture.opacity == .45 && capture.shape == 0);
  PROPERTY_CHECK(finish_text(FALSE) && image_session_revision(capture.session) == revision + 1);
  editor_command(ID_UNDO);
  PROPERTY_CHECK(image_session_value(capture.session, index, 6) == 4.25 && image_session_value(capture.session, index, 9) == 1);
  editor_command(ID_REDO);
  PROPERTY_CHECK(image_session_value(capture.session, index, 6) == 7.5 && image_session_value(capture.session, index, 8) == .45 &&
      image_session_value(capture.session, index, 9) == 0 && editor_style_get(capture.style_bank, TOOL_RECT, MC_STYLE_STROKE) == 4.25);
  PROPERTY_CHECK(fractional_property_pixels_smoke(index));
  PROPERTY_CHECK(image_session_remove(capture.session, index)); capture.selected = -1;

  smoke_select_tool(TOOL_REDACT);
  opacity = mc_win_text_inputs_field(capture.property_inputs, L"style.opacity");
  PROPERTY_CHECK(opacity && SetWindowTextW(opacity, L"-") && !smoke_property_click(L"style.shape.2") && capture.shape == 0);
  PROPERTY_CHECK(SetWindowTextW(opacity, L"25") && smoke_property_click(L"style.shape.2") && capture.shape == 2);
  PROPERTY_CHECK(!IsWindow(opacity) && !style_visible(MC_STYLE_COLOR) && !style_visible(MC_STYLE_OPACITY) && style_visible(MC_STYLE_BLOCK));
  HWND block = mc_win_text_inputs_field(capture.property_inputs, L"style.blockSize");
  PROPERTY_CHECK(block && SetWindowTextW(block, L"12.5") && !smoke_property_click(L"style.shape.0") && capture.shape == 2 && !finish_text(FALSE));
  PROPERTY_CHECK(SetWindowTextW(block, L"16") && smoke_property_click(L"style.shape.0") && capture.shape == 0);
  opacity = mc_win_text_inputs_field(capture.property_inputs, L"style.opacity");
  wchar_t raw[32] = {0}; GetWindowTextW(opacity, raw, ARRAYSIZE(raw));
  PROPERTY_CHECK(!wcscmp(raw, L"25") && capture.opacity == .25 && smoke_property_click(L"style.shape.2"));
  block = mc_win_text_inputs_field(capture.property_inputs, L"style.blockSize");
  GetWindowTextW(block, raw, ARRAYSIZE(raw)); PROPERTY_CHECK(!wcscmp(raw, L"16"));
  PROPERTY_CHECK(choose_style(MC_STYLE_BLOCK, 12) && choose_style(MC_STYLE_SHAPE, 0) && choose_style(MC_STYLE_OPACITY, 1));

  int32_t picker_edit = capture.text_edit; int picker_version = text_version();
  int old_color = capture.color;
  ZeroMemory(&color_dialog_probe, sizeof(color_dialog_probe));
  UINT_PTR timer = SetTimer(NULL, 0, 20, cancel_fixture_color_tick);
  PROPERTY_CHECK(timer);
  BOOL clicked = smoke_property_click(L"style.color"); KillTimer(NULL, timer);
  PROPERTY_CHECK(clicked && color_dialog_probe.seen && color_dialog_probe.vetoed && !capture.color_picker && capture.color == old_color);
  PROPERTY_CHECK(!apply_color_result(capture.session, picker_edit, picker_version - 1, RGB(1, 2, 3)) && capture.color == old_color);
  PROPERTY_CHECK(finish_text(FALSE));
  smoke_select_tool(TOOL_RECT);
  PROPERTY_CHECK(choose_style(MC_STYLE_SHAPE, 0) && choose_style(MC_STYLE_STROKE, 4) && finish_text(FALSE));
  smoke_select_tool(TOOL_SELECT);
  PROPERTY_CHECK(image_session_count(capture.session) == initial_count && capture.tool_snapshot == baseline);
done:
  mc_capture_discard_tools();
  if (!ok && capture.text_edit) finish_text(TRUE);
  printf("Windows shared properties %s: native fractional inputs, invalid veto, draft history, shape visibility, one document undo, color modal lease.\n", ok ? "passed" : "FAILED");
#undef PROPERTY_CHECK
  return ok;
}
static BOOL contribution_smoke(void) {
  IAccessible *accessible=NULL; VARIANT retired_child; VariantInit(&retired_child);
  int32_t baseline = capture.tool_snapshot;
  int count = tool_registry_snapshot_count(baseline, 0), index = -1;
  for (int i = 0; i < count; i++) if (tool_value(baseline, i, MC_TOOL_INTERACTION) == MC_TOOL_INTERACTION_DRAG_RECT) { index = i; break; }
  if (index < 0 || tool_value(baseline, index, MC_TOOL_ENABLED) != 0) return FALSE;
  moonbit_string_t id = tool_registry_snapshot_text(baseline, 0, index, MC_TOOL_ID);
  int32_t enabled = tool_registry_snapshot_set_enabled(baseline, id, 1), disabled = 0;
  moonbit_decref(id);
  BOOL ok = enabled > 0;
  RECT original_toolbar = capture.toolbar;
  int32_t retired_generation=capture.toolbar_generation;
  int initial_count = image_session_count(capture.session);
  capture.composing = TRUE;
  ok = !mc_capture_prepare_tools(enabled) && capture.tool_snapshot == baseline && ok;
  capture.composing = FALSE;
  if (!mc_capture_prepare_tools(enabled)) { ok = FALSE; goto cleanup; }
  /* Preparing and aborting never changes live controls or their tooltips. */
  ok = EqualRect(&original_toolbar, &capture.toolbar) && capture.tool_snapshot == baseline && ok;
  mc_capture_discard_tools();
  if (!mc_capture_prepare_tools(enabled)) { ok = FALSE; goto cleanup; }
  mc_capture_commit_tools(enabled);
  ok = capture.toolbar.right - capture.toolbar.left > original_toolbar.right - original_toolbar.left && ok;
  moonbit_string_t stale=moon_text(L"{\"type\":\"activate\",\"id\":\"builtin.image.rectangle\"}");
  ok=capture_toolbar_event(capture.toolbar_session,retired_generation,stale)==0 && capture.tool==TOOL_SELECT && ok;
  moonbit_decref(stale);
  wchar_t *contribution=tool_text(enabled,index,MC_TOOL_ID);
  if (!contribution || !smoke_toolbar_click(contribution)) { free(contribution); ok=FALSE; goto cleanup; }
  free(contribution);
  ok = custom_drag() && !style_visible(MC_STYLE_SHAPE) && ok;
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(90, 90));
  SendMessageW(capture.editor, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(200, 165));
  ok = capture.dragging && image_session_count(capture.session) == initial_count &&
    !mc_capture_prepare_tools(baseline) && ok;
  ReleaseCapture();
  SendMessageW(capture.editor, WM_LBUTTONUP, 0, MAKELPARAM(200, 165));
  ok = !capture.dragging && image_session_count(capture.session) == initial_count && ok;
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(90, 90));
  SendMessageW(capture.editor, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(200, 165));
  SendMessageW(capture.editor, WM_LBUTTONUP, 0, MAKELPARAM(200, 165));
  ok = image_session_count(capture.session) == initial_count + 2 && render_image() && ok;
  if (image_session_count(capture.session) == initial_count + 2) {
    moonbit_string_t label = image_session_text(capture.session, initial_count + 1);
    ok = image_session_value(capture.session, initial_count, 0) == TOOL_RECT &&
      image_session_value(capture.session, initial_count + 1, 0) == TOOL_TEXT &&
      Moonbit_array_length(label) > 0 && ok;
    moonbit_decref(label);
    HGLOBAL dib = image_dib(); ok = dib != NULL && ok; if (dib) GlobalFree(dib);
  }
  wchar_t *accessible_id=tool_text(enabled,index,MC_TOOL_ID);
  if (!accessible_id || FAILED(AccessibleObjectFromWindow(capture.toolbar_view,(DWORD)OBJID_CLIENT,&IID_IAccessible,(void **)&accessible)) ||
      !accessible || !smoke_accessible_child(accessible,accessible_id,&retired_child)) {
    free(accessible_id); ok=FALSE; goto cleanup;
  }
  free(accessible_id);
  id = tool_registry_snapshot_text(enabled, 0, index, MC_TOOL_ID);
  disabled = tool_registry_snapshot_set_enabled(enabled, id, 0); moonbit_decref(id);
  if (!disabled || !mc_capture_prepare_tools(disabled)) { ok = FALSE; goto cleanup; }
  mc_capture_commit_tools(disabled);
  wchar_t *removed=tool_text(disabled,index,MC_TOOL_ID);
  ok=removed && smoke_toolbar_semantic(removed)<0 && image_session_count(capture.session)==initial_count+2 && render_image() && ok;
  free(removed);
  ok=IAccessible_accDoDefaultAction(accessible,retired_child)==E_INVALIDARG &&
      capture.tool==TOOL_SELECT && image_session_count(capture.session)==initial_count+2 && ok;
  editor_command(ID_UNDO);
  ok = image_session_count(capture.session) == initial_count && ok;
  editor_command(ID_REDO);
  ok = image_session_count(capture.session) == initial_count + 2 && ok;
  editor_command(ID_UNDO);
cleanup:
  VariantClear(&retired_child); if (accessible) IAccessible_Release(accessible);
  if (capture.dragging) ReleaseCapture();
  if (mc_capture_prepare_tools(baseline)) mc_capture_commit_tools(baseline); else ok = FALSE;
  if (disabled) tool_registry_snapshot_close(disabled);
  if (enabled) tool_registry_snapshot_close(enabled);
  editor_command(ID_SELECT); changed();
  printf("Windows contribution smoke %s: descriptor button, preflight/cancel, drag rectangle+text, export, disable and one undo.\n", ok ? "passed" : "FAILED");
  return ok;
}
typedef struct {
  BOOL accept, valid_image, enabled;
  int attempts, accepted, hidden, restored, x, y, width, height;
  uint64_t digest;
} CaptureHostSmoke;
typedef struct { int calls, image, count; double revision; BOOL accept, valid; } UserToolProbe;
static BOOL smoke_user_number(const wchar_t *object, const wchar_t *key, double expected) {
  const wchar_t *value=object ? wcsstr(object,key):NULL;
  if (!value) return FALSE;
  value+=wcslen(key); wchar_t *end=NULL; double actual=wcstod(value,&end);
  return end!=value && fabs(actual-expected)<0.000001;
}
static BOOL smoke_user_tool(void *context,int32_t image,const wchar_t *id,const wchar_t *payload) {
  UserToolProbe *probe=context; probe->calls++;
  BOOL valid=image==probe->image && !capture.dragging &&
      image_session_count(image)==probe->count && image_session_revision(image)==probe->revision &&
      capture_toolbar_value(capture.toolbar_session,MC_CAPTURE_TOOLBAR_EFFECT)==MC_CAPTURE_TOOLBAR_USER_TOOL;
  if (!wcscmp(id,L"user.com.example.fixture/info"))
    valid=valid && !wcscmp(payload,L"{\"effect\":\"result.text\"}");
  else if (!wcscmp(id,L"user.com.example.fixture/box")) {
    const wchar_t *selection=wcsstr(payload,L"\"selection\":");
    valid=valid && wcsstr(payload,L"\"capture.annotations.add\"") &&
        smoke_user_number(payload,L"\"revision\":",probe->revision) &&
        smoke_user_number(selection,L"\"x\":",20) && smoke_user_number(selection,L"\"y\":",20) &&
        smoke_user_number(selection,L"\"width\":",80) && smoke_user_number(selection,L"\"height\":",70);
  } else valid=FALSE;
  probe->valid=probe->valid && valid;
  return probe->accept;
}
static BOOL user_tool_smoke(void) {
  const wchar_t *request=L"{\"layout\":{\"version\":1,\"groups\":{\"screenshot\":["
      L"{\"id\":\"user.com.example.fixture/info\",\"enabled\":true},{\"id\":\"user.com.example.fixture/box\",\"enabled\":true}]}},"
      L"\"manifests\":[{\"apiVersion\":2,\"pluginId\":\"com.example.fixture\",\"name\":\"Capture fixture\",\"version\":\"2.0.0\","
      L"\"entry\":\"plugin.wasm\",\"runtime\":\"extism-1\",\"tools\":[{\"toolId\":\"info\",\"title\":\"Info\",\"gesture\":\"invoke\",\"effect\":\"result.text\"},"
      L"{\"toolId\":\"box\",\"title\":\"Box\",\"gesture\":\"dragRect\",\"effect\":\"capture.annotations.add\"}]}]}";
  MCCaptureHost saved_host=capture.host;
  int32_t baseline=capture.tool_snapshot;
  moonbit_string_t input=moon_text(request), resolved=tool_registry_resolve_packages(input);
  moonbit_decref(input);
  int32_t snapshot=tool_registry_snapshot_open_packages(resolved,MC_TOOL_CAP_COMMANDS|MC_TOOL_CAP_USER);
  moonbit_decref(resolved);
  if (!snapshot) return FALSE;
  BOOL ok=finish_text(FALSE);
  UserToolProbe probe={0}; probe.image=capture.session; probe.count=image_session_count(capture.session);
  probe.revision=image_session_revision(capture.session); probe.accept=TRUE; probe.valid=TRUE;
  capture.host=(MCCaptureHost){0}; capture.host.context=&probe;
#define USER_CHECK(condition) do { if (!(condition)) { ok=FALSE; fprintf(stderr,"Windows user tool smoke FAILED line %d: %s\n",__LINE__,#condition); } } while (0)
  if (!mc_capture_prepare_tools(snapshot)) { ok=FALSE; goto cleanup; }
  mc_capture_commit_tools(snapshot);
  int info=smoke_toolbar_semantic(L"user.com.example.fixture/info");
  USER_CHECK(info>=0 && ui_frame_semantic_value(capture.toolbar_frame,info,MC_UI_SEM_ENABLED)==0);
  USER_CHECK(!toolbar_activate(L"user.com.example.fixture/info") && probe.calls==0);
  capture.host.on_user_tool=smoke_user_tool; mc_capture_refresh_capabilities();
  info=smoke_toolbar_semantic(L"user.com.example.fixture/info");
  USER_CHECK(info>=0 && ui_frame_semantic_value(capture.toolbar_frame,info,MC_UI_SEM_ENABLED)==1);
  USER_CHECK(smoke_toolbar_click(L"user.com.example.fixture/info") && probe.calls==1 && probe.valid &&
      capture_toolbar_value(capture.toolbar_session,MC_CAPTURE_TOOLBAR_EFFECT)==MC_CAPTURE_TOOLBAR_NONE);
  probe.accept=FALSE;
  USER_CHECK(smoke_toolbar_click(L"user.com.example.fixture/info") && probe.calls==2 && probe.valid &&
      capture_toolbar_value(capture.toolbar_session,MC_CAPTURE_TOOLBAR_TICKET)==0);
  probe.accept=TRUE;
  USER_CHECK(smoke_toolbar_click(L"user.com.example.fixture/box") && custom_drag() && probe.calls==2);
  int x=capture.viewport.left+20,y=capture.viewport.top+20;
  SendMessageW(capture.editor,WM_LBUTTONDOWN,MK_LBUTTON,MAKELPARAM(x,y));
  SendMessageW(capture.editor,WM_MOUSEMOVE,MK_LBUTTON,MAKELPARAM(x+80,y+70));
  USER_CHECK(capture.dragging && image_session_preview_value(capture.session,0)==TOOL_RECT && probe.calls==2);
  SendMessageW(capture.editor,WM_LBUTTONUP,0,MAKELPARAM(x+80,y+70));
  USER_CHECK(!capture.dragging && probe.calls==3 && probe.valid &&
      capture_toolbar_value(capture.toolbar_session,MC_CAPTURE_TOOLBAR_EFFECT)==MC_CAPTURE_TOOLBAR_NONE &&
      image_session_count(capture.session)==probe.count && image_session_revision(capture.session)==probe.revision);
  SendMessageW(capture.editor,WM_LBUTTONUP,0,MAKELPARAM(x+80,y+70));
  USER_CHECK(probe.calls==3);
cleanup:
  if (capture.dragging) ReleaseCapture();
  editor_command(ID_SELECT);
  if (mc_capture_prepare_tools(baseline)) mc_capture_commit_tools(baseline); else ok=FALSE;
  capture.host=saved_host; mc_capture_refresh_capabilities();
  tool_registry_snapshot_close(snapshot);
  printf("Windows v2 user tool smoke %s: optional capability, shared invoke/dragRect callback, immediate ACK and unchanged document.\n",ok?"passed":"FAILED");
#undef USER_CHECK
  return ok;
}
static uint64_t smoke_dib_digest(HGLOBAL dib) {
  const BYTE *bytes=GlobalLock(dib);
  if (!bytes) return 0;
  SIZE_T size=GlobalSize(dib); uint64_t hash=UINT64_C(1469598103934665603);
  for (SIZE_T i=0;i<size;i++) hash=(hash^bytes[i])*UINT64_C(1099511628211);
  GlobalUnlock(dib); return hash;
}
static BOOL smoke_pin_enabled(void *context) { return ((CaptureHostSmoke *)context)->enabled; }
static BOOL smoke_pin_image(void *context, HGLOBAL dib, int x, int y) {
  CaptureHostSmoke *host = context;
  host->attempts++;
  host->digest=smoke_dib_digest(dib);
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
#define CAPTURE_FAIL() do { fprintf(stderr, "Windows screenshot smoke FAILED line %d\n", __LINE__); goto cleanup; } while (0)
  int result = 1;
  HGLOBAL dib = NULL;
  CaptureHostSmoke host = {0};
  host.enabled = TRUE;
  ZeroMemory(&capture, sizeof(capture));
  capture.instance = instance;
  capture.smoke = TRUE;
  capture.host = (MCCaptureHost){&host, smoke_pin_image, smoke_pins_hidden, smoke_pin_enabled, NULL};
  set_pins_hidden(TRUE);
  SetRect(&capture.desktop_bounds, 0, 0, 640, 480);
  if (!mc_selection_smoke() || !register_windows(instance) || !surface_new(&capture.desktop, 640, 480) ||
      !surface_new(&capture.dimmed, 640, 480))
    CAPTURE_FAIL();
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
    CAPTURE_FAIL();
  SendMessageW(capture.overlay, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(330, 220));
  SendMessageW(capture.overlay, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(10, 20));
  SendMessageW(capture.overlay, WM_LBUTTONUP, 0, MAKELPARAM(10, 20));
  if (!capture.editor || capture.viewport.left != 10 || capture.viewport.top != 20 ||
      (GetWindowLongPtrW(capture.editor, GWL_STYLE) & WS_CAPTION))
    CAPTURE_FAIL();
  /* Real child focus, IME and layered EDIT hit-testing require the generated
   * fixture window to be shown. Its pixels come only from the synthetic image. */
  ShowWindow(capture.editor, SW_SHOWNOACTIVATE); SetForegroundWindow(capture.editor); UpdateWindow(capture.editor);
#define CAPTURE_SUITE(test) do { if (!(test())) { fprintf(stderr,"Windows screenshot smoke FAILED suite %s\n",#test); CAPTURE_FAIL(); } } while (0)
  CAPTURE_SUITE(context_toolbar_smoke);
  CAPTURE_SUITE(shared_toolbar_smoke);
  CAPTURE_SUITE(hud_surface_smoke);
  CAPTURE_SUITE(numeric_input_smoke);
  CAPTURE_SUITE(independent_text_style_smoke);
  CAPTURE_SUITE(shared_text_fields_smoke);
  CAPTURE_SUITE(text_ime_rejection_smoke);
  CAPTURE_SUITE(text_cover_preview_smoke);
  CAPTURE_SUITE(text_document_boundaries_smoke);
  CAPTURE_SUITE(shape_variants_smoke);
  CAPTURE_SUITE(shared_properties_smoke);
  CAPTURE_SUITE(contribution_smoke);
  CAPTURE_SUITE(user_tool_smoke);
#undef CAPTURE_SUITE
  if (image_session_add(capture.session, TOOL_REDACT, 40, 60, 80, 60, 0, 4) != 1)
    CAPTURE_FAIL();
  begin_text((POINT){50, 70}, -1);
  SetWindowTextW(capture.text, L"截图测试 MoonBit\r\n第二行");
  double initial_font = capture.font_size;
  for (int i=0;i<ui_frame_semantic_count(capture.toolbar_frame);i++)
    if (ui_frame_semantic_value(capture.toolbar_frame,i,MC_UI_SEM_ENABLED)==0) {
      // Disabled real canvas semantics must not finish the inline draft.
      smoke_toolbar_pointer(i,WM_LBUTTONDOWN); smoke_toolbar_pointer(i,WM_LBUTTONUP);
    }
  if (!capture.editor || capture.editing != -1 || image_session_count(capture.session) != 1)
    CAPTURE_FAIL();
  step_style(TRUE);
  if (capture.font_size != initial_font + 1 || image_session_count(capture.session) != 1)
    CAPTURE_FAIL();
  step_style(FALSE);
  if (capture.font_size != initial_font || !style_visible(MC_STYLE_FONT) || style_visible(MC_STYLE_STROKE))
    CAPTURE_FAIL();

  SetFocus(capture.text);
  SendMessageW(capture.text, WM_IME_STARTCOMPOSITION, 0, 0);
  MSG ime_key = {0};
  ime_key.hwnd = capture.text;
  ime_key.message = WM_KEYDOWN;
  ime_key.wParam = VK_ESCAPE;
  if (mc_capture_handle_message(&ime_key) || finish_text(FALSE) || finish_text(TRUE) ||
      image_session_count(capture.session) != 1)
    CAPTURE_FAIL();
  SendMessageW(capture.text, WM_IME_ENDCOMPOSITION, 0, 0);

  if (!finish_text(FALSE) || image_session_count(capture.session) != 2)
    CAPTURE_FAIL();
  int index = capture.selected;
  begin_text((POINT){50, 70}, index);
  SetWindowTextW(capture.text, L"修改后");
  if (!finish_text(FALSE) || image_session_count(capture.session) != 2)
    CAPTURE_FAIL();
  preserve_text(index);
  if (image_session_update(capture.session, index, 150, 100, 150, 70, 0xF26769, 4, 32) != 1 ||
      image_session_value(capture.session, index, 7) != 32)
    CAPTURE_FAIL();
  if (hit_text((POINT){150, 100}) != index || hit_text((POINT){299, 169}) != index ||
      hit_text((POINT){300, 170}) != -1)
    CAPTURE_FAIL();
  if (image_session_undo(capture.session) != 1 || image_session_value(capture.session, index, 1) != 50 ||
      image_session_redo(capture.session) != 1)
    CAPTURE_FAIL();
  // Drive the actual mouse gesture handlers; the MoonBit document commits only at mouse-up.
  capture.tool = TOOL_SELECT;
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(180, 125));
  SendMessageW(capture.editor, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(190, 135));
  if (image_session_value(capture.session, index, 1) != 150)
    CAPTURE_FAIL();
  SendMessageW(capture.editor, WM_LBUTTONUP, 0, MAKELPARAM(190, 135));
  if (image_session_value(capture.session, index, 1) != 160)
    CAPTURE_FAIL();
  // Follow the real undo entry: it closes the selected text's property draft
  // before changing the document revision, just like a toolbar/keyboard undo.
  editor_command(ID_UNDO);
  if (image_session_value(capture.session, index, 1) != 150)
    CAPTURE_FAIL();
  capture.selected = -1;
  SendMessageW(capture.editor, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(330, 220));
  SendMessageW(capture.editor, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(350, 240));
  SendMessageW(capture.editor, WM_LBUTTONUP, 0, MAKELPARAM(350, 240));
  if (image_session_viewport_value(capture.session, 2) != 340)
    CAPTURE_FAIL();
  editor_command(ID_UNDO);
  if (image_session_viewport_value(capture.session, 2) != 320)
    CAPTURE_FAIL();
  sync_viewport();
  changed();
  dib = image_dib();
  if (!dib)
    CAPTURE_FAIL();
  BITMAPINFOHEADER *header = GlobalLock(dib);
  if (!header)
    CAPTURE_FAIL();
  SIZE_T stride = ((SIZE_T)320 * 3 + 3) & ~(SIZE_T)3;
  const BYTE *mask = (const BYTE *)(header + 1) + 149 * stride + 50 * 3,
             *source = (const BYTE *)(header + 1) + 194 * stride + 5 * 3;
  BOOL valid = header->biWidth == 320 && header->biHeight == 200 && !mask[0] && !mask[1] && !mask[2] &&
               source[0] == 80 && source[1] == 160 && source[2] == 220;
  GlobalUnlock(dib);
  if (!valid)
    CAPTURE_FAIL();
  // Covers blend once, including blank areas of an active native text box.
  if (!image_session_add_rgba(capture.session, TOOL_REDACT, 230, 130, 80, 50, 0x204080, 4, 24, .5))
    CAPTURE_FAIL();
  begin_text((POINT){150, 100}, index);
  changed();
  if (!render_image())
    CAPTURE_FAIL();
  BYTE *blend = capture.rendered.pixels + ((SIZE_T)150 * capture.image.width + 280) * 4;
  if (blend[0] != 104 || blend[1] != 112 || blend[2] != 126)
    CAPTURE_FAIL();
  if (!finish_text(FALSE) || !render_image())
    CAPTURE_FAIL();
  blend = capture.rendered.pixels + ((SIZE_T)150 * capture.image.width + 280) * 4;
  if (blend[0] != 104 || blend[1] != 112 || blend[2] != 126)
    CAPTURE_FAIL();
  capture.selected = index;
  sync_properties();
  if (!choose_style(MC_STYLE_OPACITY, .4)) CAPTURE_FAIL();
  if (image_session_value(capture.session, index, 8) != .4)
    CAPTURE_FAIL();
  begin_text((POINT){150, 100}, index);
  if (capture.opacity != .4 || !finish_text(FALSE) || image_session_value(capture.session, index, 8) != .4)
    CAPTURE_FAIL();
  if (!choose_style(MC_STYLE_OPACITY, 1) || !finish_text(FALSE)) CAPTURE_FAIL();
  image_session_remove(capture.session, image_session_count(capture.session) - 1);
  // Font changes must resize the box and leave visible pixels in the exported image.
  set_session_text(L"A", 1);
  if (!image_session_add_rgba(capture.session, TOOL_TEXT, 170, 30, 140, 72, 0xF26769, 4, 24, 1))
    CAPTURE_FAIL();
  capture.selected = image_session_count(capture.session) - 1;
  capture.color = 0xF26769;
  capture.stroke = 4;
  sync_properties();
  if (!choose_style(MC_STYLE_FONT, 128))
    CAPTURE_FAIL();
  if (image_session_value(capture.session, capture.selected, 4) < 128 || !render_image())
    CAPTURE_FAIL();
  int colored = 0;
  for (int y = 35; y < 180; y++)
    for (int x = 175; x < 300; x++) {
      BYTE *pixel = capture.rendered.pixels + ((SIZE_T)y * capture.image.width + x) * 4;
      if (pixel[2] > 230 && pixel[1] < 130 && pixel[0] < 130)
        colored++;
    }
  if (colored < 100)
    CAPTURE_FAIL();
  // Keep the optional visual fixture readable after the large-font regression.
  if (!finish_text(FALSE)) CAPTURE_FAIL();
  image_session_remove(capture.session, capture.selected);
  smoke_select_tool(TOOL_TEXT);
  capture.selected = index;
  capture.color = (int)image_session_value(capture.session, index, 5);
  capture.opacity = image_session_value(capture.session, index, 8);
  capture.stroke = image_session_value(capture.session, index, 6);
  capture.font_size = image_session_value(capture.session, index, 7);
  sync_properties();
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
  // This is synthetic setup, so settle the live property transaction before
  // issuing a direct core crop instead of going through the pointer handler.
  if (!finish_text(FALSE)) CAPTURE_FAIL();
  image_session_crop(capture.session, 70, 50, 500, 270);
  sync_viewport();
  layout_editor(capture.editor);
  changed();
  if (!save_capture_preview())
    CAPTURE_FAIL();
  host.enabled = FALSE;
  mc_capture_refresh_capabilities();
  smoke_invoke_action(L"pin");
  if (smoke_action_enabled(L"pin") || host.attempts || !mc_capture_busy())
    CAPTURE_FAIL();
  host.enabled = TRUE;
  mc_capture_refresh_capabilities();
  HGLOBAL before_pin=image_dib();
  if (!before_pin) CAPTURE_FAIL();
  uint64_t before_digest=smoke_dib_digest(before_pin); GlobalFree(before_pin);
  int before_pin_count=image_session_count(capture.session);
  double before_pin_revision=image_session_revision(capture.session);
  begin_text((POINT){100,80},-1);
  if (!capture.text || !SetWindowTextW(capture.text,L"Uncommitted pin draft")) CAPTURE_FAIL();
  int32_t pin_edit=capture.text_edit; HWND pin_input=capture.text;
  smoke_invoke_action(L"pin"); smoke_drain_field_actions();
  if (host.attempts != 1 || host.accepted || host.restored || !mc_capture_busy() || !host.valid_image ||
      host.digest==before_digest || capture.text_edit!=pin_edit || capture.text!=pin_input ||
      !text_equals(L"Uncommitted pin draft") || image_session_count(capture.session)!=before_pin_count ||
      image_session_revision(capture.session)!=before_pin_revision)
    CAPTURE_FAIL();
  host.accept = TRUE;
  smoke_invoke_action(L"pin");
  if (host.attempts != 2 || host.accepted != 1 || host.hidden != 1 || host.restored != 1 ||
      host.x != 70 || host.y != 50 || host.width != 500 || host.height != 270 || mc_capture_busy())
    CAPTURE_FAIL();
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
#undef CAPTURE_FAIL
}
