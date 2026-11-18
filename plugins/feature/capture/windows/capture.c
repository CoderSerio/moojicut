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
#include "platform/windows/graphics/text_input.h"
#include "platform/windows/graphics/shared_canvas.h"
#include "bindings/c/capture_ui.h"
#include "bindings/c/tool_registry.h"
#include "platform/shared/image/pixelate.h"
#include "components/icons/shared/mc_icons.h"
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
  ID_CANCEL,
  ID_TEXT_INPUT,
  ID_CONTRIBUTION_BASE = 9000
};
enum { ID_STYLE_BASE = 8500 };
enum { MAX_TOOL_BUTTONS = 261 };
typedef struct {
  HWND window;
  int command, icon, slot, kind, interaction;
  BOOL available, registered;
  wchar_t *id, *action, *handler, *label;
} ToolButton;
typedef struct { ToolButton buttons[MAX_TOOL_BUTTONS]; int count; } ToolButtons;
typedef struct {
  HDC dc;
  HBITMAP bitmap;
  HGDIOBJ previous;
  BYTE *pixels;
  int width, height;
} Surface;
typedef struct {
  HINSTANCE instance;
  HWND owner, overlay, editor, text, tooltip, text_properties;
  MCWinTextInputs *body_inputs, *property_inputs;
  int32_t text_edit;
  int text_index;
  BOOL text_syncing, text_finishing, color_picker;
  ToolButtons toolbar_buttons, prepared_buttons;
  int active_button;
  MCCaptureHost host;
  HFONT font, text_font;
  HBRUSH text_background;
  unsigned render_serial, brush_serial;
  BOOL rendered_draft;
  Surface desktop, dimmed, image, rendered;
  RECT desktop_bounds, canvas, viewport, toolbar, drag_bounds, draft;
  POINT start, end;
  double zoom, opacity, font_size, stroke;
  int32_t session, style_bank, tool_snapshot, owned_tools, prepared_text_candidate;
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
static BOOL build_tool_buttons(int32_t snapshot, ToolButtons *buttons);
static void clear_tool_buttons(ToolButtons *buttons);
static void publish_tool_buttons(void);
static ToolButton *find_button(int command);
static BOOL custom_drag(void) {
  return capture.active_button >= 0 && capture.active_button < capture.toolbar_buttons.count &&
    capture.toolbar_buttons.buttons[capture.active_button].interaction == MC_TOOL_INTERACTION_DRAG_RECT;
}
static const wchar_t *EDITOR_CLASS = L"MoojiCut.Capture.Editor";
static BOOL pin_enabled(void) {
  return !capture.host.pin_enabled || capture.host.pin_enabled(capture.host.context);
}
void mc_capture_refresh_capabilities(void) {
  for (int i = 0; i < capture.toolbar_buttons.count; i++) {
    ToolButton *button = &capture.toolbar_buttons.buttons[i];
    BOOL enabled = button->available;
    if (button->action && !wcscmp(button->action, L"pin")) enabled = enabled && pin_enabled();
    EnableWindow(button->window, enabled);
  }
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
    const wchar_t *handler = index < 0 && custom_drag() ? capture.toolbar_buttons.buttons[capture.active_button].handler : L"";
    int length = (int)wcslen(handler);
    moonbit_string_t command = moonbit_make_string_raw(length);
    memcpy(command, handler, (size_t)length * sizeof(wchar_t));
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
  RECT client;
  GetClientRect(window, &client);
  sync_properties();
  double scale = (double)GetDpiForWindow(window) / 96;
  double *frame = capture_ui_toolbar_frame(client.right / scale, client.bottom / scale,
    capture.viewport.left / scale, capture.viewport.top / scale,
    (capture.viewport.right - capture.viewport.left) / scale,
    (capture.viewport.bottom - capture.viewport.top) / scale,
    capture.toolbar_buttons.count * 30 + 6, capture.text_edit ?
      capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_ROW_WIDTH) : 0);
  int x = rounded(frame[0] * scale), y = rounded(frame[1] * scale);
  SetRect(&capture.toolbar, x, y, x + rounded(frame[2] * scale), y + rounded(frame[3] * scale));
  moonbit_decref(frame);
  int left = 6;
  int previous_slot = MC_TOOL_SLOT_TOOLS;
  for (int position = 0; position < capture.toolbar_buttons.count; position++) {
    ToolButton *button = &capture.toolbar_buttons.buttons[position];
    if (button->slot != previous_slot) left += 8;
    previous_slot = button->slot;
    int bx = x + dpi_px(window, left), by = y + dpi_px(window, 6);
    MoveWindow(button->window, bx, by, dpi_px(window, 28), dpi_px(window, 28), TRUE);
    left += 30;
    TOOLINFOW tip = {sizeof(tip)}; tip.hwnd = window; tip.uId = button->command;
    SetRect(&tip.rect, bx, by, bx + dpi_px(window, 28), by + dpi_px(window, 28));
    SendMessageW(capture.tooltip, TTM_NEWTOOLRECTW, 0, (LPARAM)&tip);
  }
  refresh_text_frames(x + dpi_px(window, 6), y + dpi_px(window, 40), scale);
  capture.canvas = capture.viewport;
  capture.zoom = 1;
  sync_properties();
  InvalidateRect(window, NULL, FALSE);
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
  moonbit_string_t json = capture_text_frame(capture.session, capture.text_edit, surface, width, height, scale, 1);
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
  HWND button = CreateWindowW(L"BUTTON", label, WS_CHILD | WS_TABSTOP | BS_OWNERDRAW, 0, 0, 1, 1,
                              parent, (HMENU)(INT_PTR)id, capture.instance, NULL);
  SetWindowSubclass(button, hud_button_proc, 2, 0);
  return button;
}
static wchar_t *tool_text(int32_t snapshot, int index, int key) {
  moonbit_string_t text = tool_registry_snapshot_text(snapshot, MC_TOOL_GROUP_SCREENSHOT, index, key);
  int length = Moonbit_array_length(text);
  wchar_t *copy = calloc((SIZE_T)length + 1, sizeof(wchar_t));
  if (copy) memcpy(copy, text, (SIZE_T)length * sizeof(wchar_t));
  moonbit_decref(text);
  return copy;
}
static int tool_value(int32_t snapshot, int index, int key) {
  return tool_registry_snapshot_value(snapshot, MC_TOOL_GROUP_SCREENSHOT, index, key);
}
static MCIcon tool_icon(const wchar_t *name) {
  char key[96];
  if (!name || !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, name, -1, key, sizeof(key), NULL, NULL))
    return MC_ICON_RECTANGLE;
  MCIcon icon = mc_icon_from_name(key);
  return icon == MC_ICON_COUNT ? MC_ICON_RECTANGLE : icon;
}
static void clear_tool_buttons(ToolButtons *buttons) {
  for (int i = 0; i < buttons->count; i++) {
    ToolButton *button = &buttons->buttons[i];
    if (capture.tooltip && button->registered) {
      TOOLINFOW tip = {sizeof(tip)}; tip.hwnd = capture.editor; tip.uId = button->command;
      SendMessageW(capture.tooltip, TTM_DELTOOLW, 0, (LPARAM)&tip);
      tip.uFlags = TTF_IDISHWND; tip.uId = (UINT_PTR)button->window;
      SendMessageW(capture.tooltip, TTM_DELTOOLW, 0, (LPARAM)&tip);
    }
    if (button->window) DestroyWindow(button->window);
    free(button->id); free(button->action); free(button->handler); free(button->label);
  }
  ZeroMemory(buttons, sizeof(*buttons));
}
static BOOL add_host_button(ToolButtons *buttons, int command, int icon, int slot, const wchar_t *label) {
  if (buttons->count >= MAX_TOOL_BUTTONS) return FALSE;
  ToolButton *button = &buttons->buttons[buttons->count++];
  button->command = command; button->icon = icon; button->slot = slot; button->available = TRUE;
  button->label = _wcsdup(label);
  if (!button->label) return FALSE;
  button->window = hud_button(capture.editor, command, button->label);
  return button->window != NULL;
}
static BOOL add_contribution_buttons(int32_t snapshot, ToolButtons *buttons, int slot) {
  int count = tool_registry_snapshot_count(snapshot, MC_TOOL_GROUP_SCREENSHOT);
  if (count < 0 || count > MAX_TOOL_BUTTONS - 5) return FALSE;
  for (int i = 0; i < count; i++) {
    if (tool_value(snapshot, i, MC_TOOL_ENABLED) != 1 || tool_value(snapshot, i, MC_TOOL_SLOT) != slot) continue;
    ToolButton *button = &buttons->buttons[buttons->count++];
    button->command = ID_CONTRIBUTION_BASE + i; button->slot = slot;
    button->kind = tool_value(snapshot, i, MC_TOOL_KIND);
    button->interaction = tool_value(snapshot, i, MC_TOOL_INTERACTION);
    button->available = tool_value(snapshot, i, MC_TOOL_AVAILABLE) == 1;
    button->id = tool_text(snapshot, i, MC_TOOL_ID);
    button->action = tool_text(snapshot, i, MC_TOOL_ACTION);
    button->handler = tool_text(snapshot, i, MC_TOOL_COMMAND);
    button->label = tool_text(snapshot, i, MC_TOOL_TITLE);
    wchar_t *icon = tool_text(snapshot, i, MC_TOOL_ICON);
    button->icon = tool_icon(icon); free(icon);
    if (!button->id || !button->action || !button->handler || !button->label) return FALSE;
    if (!button->available) {
      wchar_t *reason = tool_text(snapshot, i, MC_TOOL_UNAVAILABLE_REASON);
      SIZE_T a = wcslen(button->label), b = reason ? wcslen(reason) : 0;
      wchar_t *label = calloc(a + b + 4, sizeof(wchar_t));
      if (!label) { free(reason); return FALSE; }
      swprintf_s(label, a + b + 4, L"%s · %s", button->label, reason ? reason : L"");
      free(reason); free(button->label); button->label = label;
    }
    button->window = hud_button(capture.editor, button->command, button->label);
    if (!button->window) return FALSE;
  }
  return TRUE;
}
static BOOL build_tool_buttons(int32_t snapshot, ToolButtons *buttons) {
  ZeroMemory(buttons, sizeof(*buttons));
  BOOL ok = add_host_button(buttons, ID_SELECT, MC_ICON_SELECT, MC_TOOL_SLOT_TOOLS, L"选择 / 移动") &&
    add_contribution_buttons(snapshot, buttons, MC_TOOL_SLOT_TOOLS) &&
    add_host_button(buttons, ID_UNDO, MC_ICON_UNDO, MC_TOOL_SLOT_TOOLS, L"撤销 Ctrl+Z") &&
    add_host_button(buttons, ID_REDO, MC_ICON_REDO, MC_TOOL_SLOT_TOOLS, L"重做 Ctrl+Y") &&
    add_contribution_buttons(snapshot, buttons, MC_TOOL_SLOT_FINISH) &&
    add_host_button(buttons, ID_CANCEL, MC_ICON_CLOSE, MC_TOOL_SLOT_FINISH, L"取消 Esc") &&
    add_host_button(buttons, ID_COPY, MC_ICON_CHECK, MC_TOOL_SLOT_FINISH, L"确认并复制 Ctrl+Enter");
  if (!ok) clear_tool_buttons(buttons);
  return ok;
}
static ToolButton *find_button(int command) {
  for (int i = 0; i < capture.toolbar_buttons.count; i++)
    if (capture.toolbar_buttons.buttons[i].command == command) return &capture.toolbar_buttons.buttons[i];
  return NULL;
}
static void publish_tool_buttons(void) {
  wchar_t *active = capture.active_button >= 0 && capture.active_button < capture.toolbar_buttons.count
    && capture.toolbar_buttons.buttons[capture.active_button].id
    ? _wcsdup(capture.toolbar_buttons.buttons[capture.active_button].id) : NULL;
  clear_tool_buttons(&capture.toolbar_buttons);
  capture.toolbar_buttons = capture.prepared_buttons;
  ZeroMemory(&capture.prepared_buttons, sizeof(capture.prepared_buttons));
  capture.active_button = -1;
  for (int i = 0; i < capture.toolbar_buttons.count; i++) {
    ToolButton *button = &capture.toolbar_buttons.buttons[i];
    /* Re-register after retiring old IDs; prepared controls were hidden. */
    TOOLINFOW tip = {sizeof(tip)}; tip.hwnd = capture.editor; tip.uId = button->command;
    tip.uFlags = TTF_SUBCLASS; tip.lpszText = button->label;
    SendMessageW(capture.tooltip, TTM_ADDTOOLW, 0, (LPARAM)&tip);
    /* Enabled child buttons receive their own mouse input. The parent region
     * also supplies the same reason when a disabled child cannot receive it. */
    if (button->available) {
      tip.uFlags = TTF_SUBCLASS | TTF_IDISHWND; tip.uId = (UINT_PTR)button->window;
      SendMessageW(capture.tooltip, TTM_ADDTOOLW, 0, (LPARAM)&tip);
    }
    button->registered = TRUE;
    ShowWindow(button->window, SW_SHOWNA);
    if (active && button->id && !wcscmp(active, button->id) && button->available) capture.active_button = i;
  }
  free(active);
  if (capture.active_button < 0) { capture.tool = TOOL_SELECT; capture.selected = -1; load_tool_style(TOOL_SELECT); }
  mc_capture_refresh_capabilities();
  layout_editor(capture.editor);
}
void mc_capture_discard_tools(void) {
  clear_tool_buttons(&capture.prepared_buttons); prepared_tools = 0;
  if (capture.prepared_text_candidate) { capture_candidate_close(capture.prepared_text_candidate); capture.prepared_text_candidate = 0; }
}
BOOL mc_capture_prepare_tools(int32_t snapshot) {
  mc_capture_discard_tools();
  if (tool_registry_snapshot_count(snapshot, MC_TOOL_GROUP_SCREENSHOT) < 0) return FALSE;
  if (capture.editor && (capture.color_picker || capture.composing || capture.editing != -2 || capture.dragging || GetCapture())) return FALSE;
  if (capture.text_edit) {
    capture.prepared_text_candidate = capture_text_prepare(capture.session, capture.text_edit,
        text_version(), MC_CAPTURE_CANDIDATE_PUBLISH, measure_text());
    if (!capture.prepared_text_candidate) return FALSE;
  }
  if (capture.editor && !build_tool_buttons(snapshot, &capture.prepared_buttons)) { mc_capture_discard_tools(); return FALSE; }
  prepared_tools = snapshot;
  return TRUE;
}
void mc_capture_commit_tools(int32_t snapshot) {
  if (snapshot != prepared_tools) return;
  if (capture.prepared_text_candidate) {
    if (!capture_candidate_commit(capture.session, capture.prepared_text_candidate)) return;
    capture_candidate_close(capture.prepared_text_candidate); capture.prepared_text_candidate = 0;
    capture.text_edit = 0; capture.text_index = -1;
  }
  configured_tools = snapshot; prepared_tools = 0;
  if (capture.editor) {
    capture.tool_snapshot = snapshot;
    publish_tool_buttons();
    if (capture.owned_tools) { tool_registry_snapshot_close(capture.owned_tools); capture.owned_tools = 0; }
  }
}
static BOOL add_shape(void) {
  return image_session_shape_event(capture.session, 1, capture.end.x, capture.end.y) == 1;
}
static void editor_command(int command) {
  ToolButton *button = find_button(command);
  if (button && !IsWindowEnabled(button->window)) return;
  BOOL pin = button && button->action && !wcscmp(button->action, L"pin");
  if (pin && !pin_enabled()) return;
  if ((command == ID_UNDO || command == ID_REDO) && capture.text_edit &&
      capture_text_value(capture.session, capture.text_edit, command == ID_UNDO ? MC_CAPTURE_TEXT_CAN_UNDO : MC_CAPTURE_TEXT_CAN_REDO) == 1) {
    const wchar_t *json = command == ID_REDO ? L"{\"type\":\"redo\"}" : L"{\"type\":\"undo\"}";
    int length = (int)wcslen(json); moonbit_string_t event = moonbit_make_string_raw(length);
    memcpy(event, json, (size_t)length * sizeof(wchar_t));
    text_field_event(NULL, NULL, event); moonbit_decref(event); return;
  }
  if (!finish_text(FALSE)) return;
  if (command == ID_SELECT || (button && (button->interaction == MC_TOOL_INTERACTION_ANNOTATION ||
      button->interaction == MC_TOOL_INTERACTION_DRAG_RECT))) {
    capture.active_button = command == ID_SELECT ? -1 : (int)(button - capture.toolbar_buttons.buttons);
    capture.tool = command == ID_SELECT ? TOOL_SELECT :
      button->interaction == MC_TOOL_INTERACTION_DRAG_RECT ? TOOL_RECT : button->kind;
    capture.selected = -1;
    load_tool_style(capture.tool);
    layout_editor(capture.editor);
    changed();
    for (int i = 0; i < capture.toolbar_buttons.count; i++)
      InvalidateRect(capture.toolbar_buttons.buttons[i].window, NULL, FALSE);
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
  } else if (pin) {
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
  mc_hud_card(dc, &capture.toolbar, (float)GetDpiForWindow(capture.editor) / 96, L"");
}
static LRESULT CALLBACK editor_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  switch (message) {
  case WM_CREATE: {
    capture.editor = window;
    capture.font =
        CreateFontW(-dpi_px(window, 14), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                    OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    capture.tooltip =
        CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, NULL, WS_POPUP | TTS_ALWAYSTIP, CW_USEDEFAULT,
                        CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, window, NULL, capture.instance, NULL);
    if (!capture.tooltip || !build_tool_buttons(capture.tool_snapshot, &capture.prepared_buttons)) return -1;
    MCWinCanvasCallbacks row_callbacks = {text_property_event, NULL, NULL, NULL};
    capture.text_properties = mc_win_canvas_create(window, capture.instance, ID_STYLE_BASE + 50, &row_callbacks, NULL);
    if (!capture.text_properties) return -1;
    ShowWindow(capture.text_properties, SW_HIDE);
    MCWinTextCallbacks text_callbacks = {text_field_event, text_field_action, text_background, text_field_key};
    capture.body_inputs = mc_win_text_inputs_create(window, capture.instance, &text_callbacks, NULL);
    capture.property_inputs = mc_win_text_inputs_create(window, capture.instance, &text_callbacks, NULL);
    if (!capture.body_inputs || !capture.property_inputs) return -1;
    publish_tool_buttons();
    return 0;
  }
  case TEXT_FIELD_ACTION:
    if (capture.text_edit == (int32_t)wp && !capture.color_picker) {
      BOOL defaults = capture_text_value(capture.session, capture.text_edit, MC_CAPTURE_TEXT_MODE) == MC_CAPTURE_TEXT_DEFAULTS;
      HWND focus = GetFocus();
      BOOL within = mc_win_text_inputs_contains(capture.property_inputs, focus) || mc_win_text_inputs_contains(capture.body_inputs, focus);
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
  case WM_DRAWITEM: {
    DRAWITEMSTRUCT *item = (DRAWITEMSTRUCT *)lp;
    int kind = -1, value = 0;
    BOOL selected = FALSE;
    for (int i = 0; i < capture.toolbar_buttons.count; i++)
      if (item->CtlID == (UINT)capture.toolbar_buttons.buttons[i].command) {
        kind = capture.toolbar_buttons.buttons[i].icon;
        selected = capture.active_button == i ||
          (capture.active_button < 0 && item->CtlID == ID_SELECT && capture.tool == TOOL_SELECT);
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
    if (HIWORD(wp) == BN_CLICKED && LOWORD(wp) >= ID_CONTRIBUTION_BASE) {
      ToolButton *button = find_button(LOWORD(wp));
      /* Snapshot reordering may reuse a numeric child ID. A queued notification
       * from a retired HWND must never invoke the new contribution at that ID. */
      if (!button || button->window != (HWND)lp) return 0;
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
        const wchar_t *name = capture.toolbar_buttons.buttons[capture.active_button].handler;
        int length = (int)wcslen(name);
        moonbit_string_t command = moonbit_make_string_raw(length);
        memcpy(command, name, (SIZE_T)length * sizeof(wchar_t));
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
  capture.active_button = -1;
  capture.tool_snapshot = configured_tools;
  if (!capture.tool_snapshot) {
    moonbit_string_t empty = moonbit_make_string_raw(0);
    moonbit_string_t result = tool_registry_normalize(empty);
    moonbit_decref(empty);
    capture.tool_snapshot = capture.owned_tools = tool_registry_snapshot_open(result, MC_TOOL_CAP_COMMANDS);
    moonbit_decref(result);
  }
  if (!capture.tool_snapshot) return FALSE;
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
  clear_tool_buttons(&capture.toolbar_buttons);
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
  if (message->message >= WM_MOUSEFIRST && message->message <= WM_MOUSELAST)
    SendMessageW(capture.tooltip, TTM_RELAYEVENT, 0, (LPARAM)message);
  // Let the native EDIT/IME consume candidate selection and cancellation keys.
  if (mc_win_text_inputs_contains(capture.body_inputs, message->hwnd) ||
      mc_win_text_inputs_contains(capture.property_inputs, message->hwnd)) return false;
  if (capture.composing) return false;
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
      r = drag_rect(r, from, to, -1, 8);
      if (!finish_text(FALSE)) return true;
      moonbit_string_t id = image_session_annotation_id(capture.session, capture.selected);
      image_session_geometry(capture.session, image_session_revision(capture.session), id,
          r.left, r.top, r.right - r.left, r.bottom - r.top, -1);
      moonbit_decref(id);
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
static ToolButton *smoke_annotation_button(int kind) {
  for (int i = 0; i < capture.toolbar_buttons.count; i++) {
    ToolButton *button = &capture.toolbar_buttons.buttons[i];
    if (button->interaction == MC_TOOL_INTERACTION_ANNOTATION && button->kind == kind) return button;
  }
  return NULL;
}
static void smoke_select_tool(int kind) {
  ToolButton *button = smoke_annotation_button(kind);
  if (kind == TOOL_SELECT) editor_command(ID_SELECT);
  else if (button) SendMessageW(capture.editor, WM_COMMAND, MAKEWPARAM(button->command, BN_CLICKED), (LPARAM)button->window);
}
static ToolButton *smoke_action_button(const wchar_t *action) {
  for (int i = 0; i < capture.toolbar_buttons.count; i++) {
    ToolButton *button = &capture.toolbar_buttons.buttons[i];
    if (button->action && !wcscmp(button->action, action)) return button;
  }
  return NULL;
}
static void smoke_invoke_action(const wchar_t *action) {
  ToolButton *button = smoke_action_button(action);
  if (button) SendMessageW(capture.editor, WM_COMMAND, MAKEWPARAM(button->command, BN_CLICKED), (LPARAM)button->window);
}
static BOOL context_toolbar_smoke(void) {
  RECT initial = capture.toolbar;
  if (style_visible(MC_STYLE_COLOR) || style_visible(MC_STYLE_FONT) ||
      style_visible(MC_STYLE_STROKE))
    return FALSE;
  smoke_select_tool(TOOL_TEXT);
  if (!style_visible(MC_STYLE_COLOR) || !style_visible(MC_STYLE_FONT) ||
      !style_visible(MC_STYLE_OPACITY) ||
      style_visible(MC_STYLE_STROKE) || capture.font_size != 32)
    return FALSE;
  if (!choose_style(MC_STYLE_COLOR, 0x246BFD) || !choose_style(MC_STYLE_OPACITY, .5))
    return FALSE;
  smoke_select_tool(TOOL_RECT);
  if (!style_visible(MC_STYLE_COLOR) || !style_visible(MC_STYLE_STROKE) ||
      style_visible(MC_STYLE_FONT) ||
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
  smoke_select_tool(TOOL_ARROW);
  if (capture.color != 0xF26769 || capture.opacity != 1 || capture.stroke != 4)
    return FALSE;
  if (!choose_style(MC_STYLE_COLOR, 0xFFFFFF) || !choose_style(MC_STYLE_OPACITY, .8))
    return FALSE;
  smoke_select_tool(TOOL_REDACT);
  if (!style_visible(MC_STYLE_COLOR) || !style_visible(MC_STYLE_OPACITY) ||
      style_visible(MC_STYLE_FONT) || style_visible(MC_STYLE_STROKE) ||
      capture.color != 0x111111 || capture.opacity != 1)
    return FALSE;
  if (!choose_style(MC_STYLE_COLOR, 0x25A56A) || !choose_style(MC_STYLE_OPACITY, .2))
    return FALSE;
  smoke_select_tool(TOOL_TEXT);
  if (capture.color != 0x246BFD || capture.opacity != .5)
    return FALSE;
  smoke_select_tool(TOOL_RECT);
  if (capture.color != 0x25A56A || capture.opacity != .3 || capture.stroke != 8)
    return FALSE;
  smoke_select_tool(TOOL_ARROW);
  if (capture.color != 0xFFFFFF || capture.opacity != .8)
    return FALSE;
  smoke_select_tool(TOOL_REDACT);
  if (capture.color != 0x25A56A || capture.opacity != .2)
    return FALSE;
  // Restore the drawing defaults before the existing geometry/export fixture.
  for (int tool = TOOL_RECT; tool <= TOOL_REDACT; tool++) {
    smoke_select_tool(tool);
    unsigned mask = (unsigned)editor_style_visible_mask(tool, 0);
    for (int field = 0; field < MC_STYLE_PROPERTY_COUNT; field++)
      if ((mask & (1u << field)) && !choose_style(field,
          tool == TOOL_REDACT && field == MC_STYLE_COLOR ? 0x111111 : editor_style_default(field)))
        return FALSE;
  }
  int unavailable = 0;
  for (int i = 0; i < capture.toolbar_buttons.count; i++) {
    ToolButton *entry = &capture.toolbar_buttons.buttons[i];
    if (entry->available) continue;
    unavailable++;
    if (IsWindowEnabled(entry->window))
      return FALSE;
    RECT button;
    GetWindowRect(entry->window, &button);
    POINT point = {(button.left + button.right) / 2, (button.top + button.bottom) / 2};
    ScreenToClient(capture.editor, &point);
    TTHITTESTINFOW hit = {0};
    hit.hwnd = capture.editor;
    hit.pt = point;
    hit.ti.cbSize = sizeof(hit.ti);
    if (!SendMessageW(capture.tooltip, TTM_HITTESTW, 0, (LPARAM)&hit) ||
        hit.ti.uId != (UINT_PTR)entry->command)
      return FALSE;
    wchar_t label[128] = {0};
    TOOLINFOW tip = {sizeof(tip)};
    tip.hwnd = capture.editor;
    tip.uId = entry->command;
    tip.lpszText = label;
    SendMessageW(capture.tooltip, TTM_GETTEXTW, ARRAYSIZE(label), (LPARAM)&tip);
    if (!*label || !wcsstr(label, L" · "))
      return FALSE;
  }
  if (unavailable < 2) return FALSE;
  editor_command(ID_SELECT);
  return EqualRect(&initial, &capture.toolbar) && !style_visible(MC_STYLE_COLOR) &&
         !style_visible(MC_STYLE_FONT);
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
  MCWinTextCallbacks callbacks = {retire_text_on_focus, NULL, NULL, NULL};
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
  int original_session = capture.session, original_bank = capture.style_bank;
  capture.session = image_session_create_viewport(capture.image.width, capture.image.height, 10, 20, 320, 200);
  capture.style_bank = editor_style_create();
  BOOL ok = TRUE;
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
  image_session_dispose(capture.session); editor_style_dispose(capture.style_bank);
  capture.session = original_session; capture.style_bank = original_bank;
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
  int32_t baseline = capture.tool_snapshot;
  int count = tool_registry_snapshot_count(baseline, 0), index = -1;
  for (int i = 0; i < count; i++) if (tool_value(baseline, i, MC_TOOL_INTERACTION) == MC_TOOL_INTERACTION_DRAG_RECT) { index = i; break; }
  if (index < 0 || tool_value(baseline, index, MC_TOOL_ENABLED) != 0) return FALSE;
  moonbit_string_t id = tool_registry_snapshot_text(baseline, 0, index, MC_TOOL_ID);
  int32_t enabled = tool_registry_snapshot_set_enabled(baseline, id, 1), disabled = 0;
  moonbit_decref(id);
  BOOL ok = enabled > 0;
  RECT original_toolbar = capture.toolbar;
  ToolButton *prior_rectangle = smoke_annotation_button(TOOL_RECT);
  HWND retired_button = prior_rectangle ? prior_rectangle->window : NULL;
  int retired_command = prior_rectangle ? prior_rectangle->command : 0;
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
  SendMessageW(capture.editor, WM_COMMAND, MAKEWPARAM(retired_command, BN_CLICKED), (LPARAM)retired_button);
  ok = capture.active_button == -1 && capture.tool == TOOL_SELECT && ok;
  ToolButton *button = find_button(ID_CONTRIBUTION_BASE + index);
  if (!button) { ok = FALSE; goto cleanup; }
  SendMessageW(capture.editor, WM_COMMAND, MAKEWPARAM(button->command, BN_CLICKED), (LPARAM)button->window);
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
  id = tool_registry_snapshot_text(enabled, 0, index, MC_TOOL_ID);
  disabled = tool_registry_snapshot_set_enabled(enabled, id, 0); moonbit_decref(id);
  if (!disabled || !mc_capture_prepare_tools(disabled)) { ok = FALSE; goto cleanup; }
  mc_capture_commit_tools(disabled);
  ok = !find_button(ID_CONTRIBUTION_BASE + index) && image_session_count(capture.session) == initial_count + 2 &&
    render_image() && ok;
  editor_command(ID_UNDO);
  ok = image_session_count(capture.session) == initial_count && ok;
  editor_command(ID_REDO);
  ok = image_session_count(capture.session) == initial_count + 2 && ok;
  editor_command(ID_UNDO);
cleanup:
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
} CaptureHostSmoke;
static BOOL smoke_pin_enabled(void *context) { return ((CaptureHostSmoke *)context)->enabled; }
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
#define CAPTURE_FAIL() do { fprintf(stderr, "Windows screenshot smoke FAILED line %d\n", __LINE__); goto cleanup; } while (0)
  int result = 1;
  HGLOBAL dib = NULL;
  CaptureHostSmoke host = {0};
  host.enabled = TRUE;
  ZeroMemory(&capture, sizeof(capture));
  capture.instance = instance;
  capture.smoke = TRUE;
  capture.host = (MCCaptureHost){&host, smoke_pin_image, smoke_pins_hidden, smoke_pin_enabled};
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
  if (!context_toolbar_smoke() || !independent_text_style_smoke() ||
      !shared_text_fields_smoke() || !text_ime_rejection_smoke() || !text_cover_preview_smoke() ||
      !text_document_boundaries_smoke() || !shape_variants_smoke() || !shared_properties_smoke() || !contribution_smoke())
    CAPTURE_FAIL();
  if (image_session_add(capture.session, TOOL_REDACT, 40, 60, 80, 60, 0, 4) != 1)
    CAPTURE_FAIL();
  begin_text((POINT){50, 70}, -1);
  SetWindowTextW(capture.text, L"截图测试 MoonBit\r\n第二行");
  double initial_font = capture.font_size;
  for (int i = 0; i < capture.toolbar_buttons.count; i++)
    if (!capture.toolbar_buttons.buttons[i].available)
      SendMessageW(capture.editor, WM_COMMAND, MAKEWPARAM(capture.toolbar_buttons.buttons[i].command, BN_CLICKED),
        (LPARAM)capture.toolbar_buttons.buttons[i].window);
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
  capture.selected = index;
  capture.tool = TOOL_TEXT;
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
  if ((!smoke_action_button(L"pin") || IsWindowEnabled(smoke_action_button(L"pin")->window)) || host.attempts || !mc_capture_busy())
    CAPTURE_FAIL();
  host.enabled = TRUE;
  mc_capture_refresh_capabilities();
  smoke_invoke_action(L"pin");
  if (host.attempts != 1 || host.accepted || host.restored || !mc_capture_busy() || !host.valid_image)
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
