#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include "shared_canvas.h"
#include "shared_canvas_accessibility.h"
#include <commctrl.h>
#include <windowsx.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static const wchar_t canvas_class[] = L"MoojiCut.SharedCanvas";
typedef struct {
  wchar_t *text;
  RECT rect;
} Tooltip;
typedef struct {
  HWND window, tooltip;
  MCWinCanvasCallbacks callbacks;
  void *context;
  int32_t frame, background;
  unsigned references;
  BOOL dead, pointer_down, active, capture_owned, tracking;
  BOOL delivered_size;
  double delivered_width, delivered_height;
  Tooltip *tips;
  int tip_count;
  MCCanvasAccessible *accessible;
} Canvas;
typedef struct {
  HDC dc;
  double scale;
  int left, top;
  struct { int size, weight; HFONT font; } fonts[16];
  int font_count;
} Paint;

static void release(Canvas *canvas) { if (!--canvas->references) free(canvas); }
static HCURSOR canvas_cursor(Canvas *canvas);
static Canvas *canvas_for(HWND window) { return (Canvas *)GetWindowLongPtrW(window, GWLP_USERDATA); }
static UINT window_dpi(HWND window) { UINT dpi = GetDpiForWindow(window); return dpi ? dpi : 96; }
static int scaled(double n, double scale) { return (int)floor(n * scale + .5); }
static COLORREF rgb(int32_t color) { return RGB((color >> 16) & 255, (color >> 8) & 255, color & 255); }
static RECT pixel_rect(MCCanvasRect rect, Paint *paint) {
  RECT result = {paint->left + scaled(rect.x, paint->scale), paint->top + scaled(rect.y, paint->scale),
    paint->left + scaled(rect.x + rect.width, paint->scale), paint->top + scaled(rect.y + rect.height, paint->scale)};
  return result;
}
static void draw_rectangle(void *context, MCCanvasRect rect, double radius,
                           int32_t fill, int32_t stroke, double width) {
  Paint *paint = context;
  RECT r = pixel_rect(rect, paint);
  int diameter = max(0, scaled(2 * radius, paint->scale));
  // Rectangle with NULL_PEN drops a pixel on each axis, including 1px glyphs.
  if (!diameter && fill >= 0 && stroke < 0) {
    SetDCBrushColor(paint->dc, rgb(fill));
    FillRect(paint->dc, &r, (HBRUSH)GetStockObject(DC_BRUSH));
    return;
  }
  HBRUSH brush = fill >= 0 ? CreateSolidBrush(rgb(fill)) : (HBRUSH)GetStockObject(NULL_BRUSH);
  HPEN pen = stroke >= 0 ? CreatePen(PS_SOLID, max(1, scaled(width, paint->scale)), rgb(stroke)) : (HPEN)GetStockObject(NULL_PEN);
  if (!brush || !pen) { if (fill >= 0 && brush) DeleteObject(brush); if (stroke >= 0 && pen) DeleteObject(pen); return; }
  HGDIOBJ old_brush = SelectObject(paint->dc, brush), old_pen = SelectObject(paint->dc, pen);
  if (diameter) RoundRect(paint->dc, r.left, r.top, r.right, r.bottom, diameter, diameter);
  else Rectangle(paint->dc, r.left, r.top, r.right, r.bottom);
  SelectObject(paint->dc, old_pen); SelectObject(paint->dc, old_brush);
  if (fill >= 0) DeleteObject(brush);
  if (stroke >= 0) DeleteObject(pen);
}
static void draw_line(void *context, double x1, double y1, double x2, double y2, int32_t color, double width) {
  Paint *paint = context;
  HPEN pen = CreatePen(PS_SOLID, max(1, scaled(width, paint->scale)), rgb(color));
  if (!pen) return;
  HGDIOBJ previous = SelectObject(paint->dc, pen);
  MoveToEx(paint->dc, paint->left + scaled(x1, paint->scale), paint->top + scaled(y1, paint->scale), NULL);
  LineTo(paint->dc, paint->left + scaled(x2, paint->scale), paint->top + scaled(y2, paint->scale));
  SelectObject(paint->dc, previous); DeleteObject(pen);
}
static HFONT paint_font(Paint *paint, int size, int weight, BOOL *temporary) {
  *temporary = FALSE;
  for (int i = 0; i < paint->font_count; i++)
    if (paint->fonts[i].size == size && paint->fonts[i].weight == weight) return paint->fonts[i].font;
  HFONT font = CreateFontW(-size, 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
      OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  if (!font) return NULL;
  if (paint->font_count < (int)(sizeof(paint->fonts) / sizeof(paint->fonts[0]))) {
    int i = paint->font_count++;
    paint->fonts[i].size = size; paint->fonts[i].weight = weight; paint->fonts[i].font = font;
  } else *temporary = TRUE;
  return font;
}
static void draw_text(void *context, const MCCanvasText *text) {
  if (!text->length || text->length > INT_MAX) return;
  Paint *paint = context;
  RECT clip = pixel_rect(text->rect, paint), rect = clip;
  int weight = text->weight == MC_UI_WEIGHT_BOLD ? FW_BOLD : text->weight == MC_UI_WEIGHT_MEDIUM ? FW_MEDIUM : FW_NORMAL;
  BOOL temporary;
  HFONT font = paint_font(paint, max(1, scaled(text->size, paint->scale)), weight, &temporary);
  if (!font) return;
  int saved = SaveDC(paint->dc);
  if (!saved) { if (temporary) DeleteObject(font); return; }
  IntersectClipRect(paint->dc, clip.left, clip.top, clip.right, clip.bottom);
  SelectObject(paint->dc, font); SetBkMode(paint->dc, TRANSPARENT); SetTextColor(paint->dc, rgb(text->color));
  UINT align = text->align == MC_UI_ALIGN_CENTER ? DT_CENTER : text->align == MC_UI_ALIGN_RIGHT ? DT_RIGHT : DT_LEFT;
  UINT format = DT_NOPREFIX | DT_END_ELLIPSIS | align;
  format |= text->single_line ? DT_SINGLELINE : DT_WORDBREAK;
  if (text->single_line && text->valign == MC_UI_VALIGN_CENTER) {
    format |= DT_VCENTER;
  } else if (text->valign == MC_UI_VALIGN_CENTER) {
    RECT measured = clip;
    DrawTextW(paint->dc, (const wchar_t *)text->text, (int)text->length, &measured, format | DT_CALCRECT);
    int height = measured.bottom - measured.top;
    rect.top += (clip.bottom - clip.top - height) / 2;
    rect.bottom = rect.top + height;
  }
  DrawTextW(paint->dc, (const wchar_t *)text->text, (int)text->length, &rect, format);
  RestoreDC(paint->dc, saved);
  if (temporary) DeleteObject(font);
}
static BOOL paint_canvas(Canvas *canvas, HDC target, const RECT *bounds, UINT dpi) {
  if (canvas->dead || !target || !bounds || !dpi || dpi > 960 ||
      bounds->right < bounds->left || bounds->bottom < bounds->top) return FALSE;
  int saved = SaveDC(target);
  if (!saved) return FALSE;
  IntersectClipRect(target, bounds->left, bounds->top, bounds->right, bounds->bottom);
  SetDCBrushColor(target, rgb(canvas->background));
  FillRect(target, bounds, (HBRUSH)GetStockObject(DC_BRUSH));
  Paint paint = {0}; paint.dc = target; paint.scale = dpi / 96.0; paint.left = bounds->left; paint.top = bounds->top;
  MCCanvasPainter painter = {&paint, draw_rectangle, draw_line, draw_text, NULL};
  BOOL ok = !canvas->frame || mc_canvas_draw_layer(canvas->frame, MC_UI_LAYER_COMMANDS, &painter);
  MCCanvasRect video;
  if (ok && canvas->callbacks.video && mc_canvas_video_rect(canvas->frame, &video)) {
    RECT rect = pixel_rect(video, &paint);
    int video_saved = SaveDC(target);
    if (video_saved) {
      IntersectClipRect(target, rect.left, rect.top, rect.right, rect.bottom);
      canvas->callbacks.video(canvas->context, canvas->window, target, &rect);
      RestoreDC(target, video_saved);
    }
  }
  if (ok && canvas->frame) ok = mc_canvas_draw_layer(canvas->frame, MC_UI_LAYER_OVERLAY, &painter);
  for (int i = 0; i < paint.font_count; i++) DeleteObject(paint.fonts[i].font);
  RestoreDC(target, saved);
  return ok;
}
BOOL mc_win_canvas_paint(HWND window, HDC target, const RECT *bounds, UINT dpi) {
  Canvas *canvas = canvas_for(window);
  return canvas && paint_canvas(canvas, target, bounds, dpi);
}
BOOL mc_win_canvas_set_background(HWND window, int32_t color) {
  Canvas *canvas = canvas_for(window);
  if (!canvas || canvas->dead || color < 0 || color > 0xffffff) return FALSE;
  if (canvas->background != color) {
    canvas->background = color;
    InvalidateRect(window, NULL, FALSE);
  }
  return TRUE;
}
static void emit(Canvas *canvas, const MCCanvasInput *input) {
  if (!canvas->dead && canvas->callbacks.event) canvas->callbacks.event(canvas->context, canvas->window, input);
}
static void release_capture(Canvas *canvas) {
  canvas->capture_owned = FALSE;
  if (GetCapture() == canvas->window) ReleaseCapture();
}
static void cancel(Canvas *canvas) {
  BOOL had_input = canvas->active || canvas->pointer_down || canvas->capture_owned;
  canvas->active = FALSE; canvas->pointer_down = FALSE;
  release_capture(canvas);
  if (had_input) { MCCanvasInput input = {0}; input.type = MC_UI_INPUT_CANCEL; emit(canvas, &input); }
}
void mc_win_canvas_cancel(HWND window) {
  Canvas *canvas = canvas_for(window);
  if (canvas) { canvas->references++; cancel(canvas); release(canvas); }
}
void mc_win_canvas_set_capture(HWND window, BOOL capture) {
  Canvas *canvas = canvas_for(window);
  if (!canvas || canvas->dead) return;
  canvas->references++;
  if (capture) {
    SetCapture(window);
    if (!canvas->dead) { canvas->capture_owned = GetCapture() == window; if (!canvas->capture_owned) cancel(canvas); }
  } else { canvas->pointer_down = FALSE; release_capture(canvas); }
  release(canvas);
}
static void clear_tooltips(Canvas *canvas) {
  if (canvas->tooltip) SendMessageW(canvas->tooltip, TTM_POP, 0, 0);
  for (int i = 0; i < canvas->tip_count; i++) {
    if (canvas->tooltip) { TOOLINFOW tool = {sizeof(tool)}; tool.hwnd = canvas->window; tool.uId = (UINT_PTR)i + 1;
      SendMessageW(canvas->tooltip, TTM_DELTOOLW, 0, (LPARAM)&tool); }
    free(canvas->tips[i].text);
  }
  free(canvas->tips); canvas->tips = NULL; canvas->tip_count = 0;
}
static void update_tooltips(Canvas *canvas) {
  int count = ui_frame_semantic_count(canvas->frame);
  if (count <= 0 || !canvas->tooltip) { clear_tooltips(canvas); return; }
  Tooltip *tips = calloc((size_t)count, sizeof(Tooltip));
  if (!tips) return;
  Paint paint = {0}; paint.scale = window_dpi(canvas->window) / 96.0;
  for (int i = 0; i < count; i++) {
    moonbit_string_t text = ui_frame_semantic_text(canvas->frame, i, MC_UI_SEM_TOOLTIP);
    int length = Moonbit_array_length(text);
    if (!length) { moonbit_decref(text); text = ui_frame_semantic_text(canvas->frame, i, MC_UI_SEM_LABEL); length = Moonbit_array_length(text); }
    if (length) { tips[i].text = calloc((size_t)length + 1, sizeof(wchar_t));
      if (tips[i].text) memcpy(tips[i].text, text, (size_t)length * sizeof(wchar_t)); }
    moonbit_decref(text);
    if (!tips[i].text) continue;
    MCCanvasRect rect = {ui_frame_semantic_number(canvas->frame, i, MC_UI_SEM_X),
      ui_frame_semantic_number(canvas->frame, i, MC_UI_SEM_Y), ui_frame_semantic_number(canvas->frame, i, MC_UI_SEM_WIDTH),
      ui_frame_semantic_number(canvas->frame, i, MC_UI_SEM_HEIGHT)};
    tips[i].rect = pixel_rect(rect, &paint);
  }
  for (int i = 0; i < max(count, canvas->tip_count); i++) {
    Tooltip *old = i < canvas->tip_count ? &canvas->tips[i] : NULL;
    Tooltip *next = i < count ? &tips[i] : NULL;
    TOOLINFOW tool = {sizeof(tool)}; tool.hwnd = canvas->window; tool.uId = (UINT_PTR)i + 1;
    if (old && old->text && next && next->text && !wcscmp(old->text, next->text)) {
      if (!EqualRect(&old->rect, &next->rect)) { tool.rect = next->rect; SendMessageW(canvas->tooltip, TTM_NEWTOOLRECTW, 0, (LPARAM)&tool); }
      free(next->text); next->text = old->text; old->text = NULL;
    } else {
      if (old && old->text) { SendMessageW(canvas->tooltip, TTM_DELTOOLW, 0, (LPARAM)&tool); free(old->text); }
      if (next && next->text) { tool.uFlags = TTF_SUBCLASS; tool.rect = next->rect; tool.lpszText = next->text;
        SendMessageW(canvas->tooltip, TTM_ADDTOOLW, 0, (LPARAM)&tool); }
    }
  }
  free(canvas->tips); canvas->tips = tips; canvas->tip_count = count;
}
BOOL mc_win_canvas_set_frame(HWND window, int32_t frame) {
  Canvas *canvas = canvas_for(window);
  if (!canvas || canvas->dead || frame < 0 || (frame && ui_frame_command_count(frame, MC_UI_LAYER_COMMANDS) < 0)) return FALSE;
  if (frame == canvas->frame) return TRUE;
  canvas->references++;
  if (!mc_canvas_accessible_frame(canvas->accessible, frame)) { release(canvas); return FALSE; }
  int32_t previous = canvas->frame; canvas->frame = frame;
  update_tooltips(canvas);
  if (previous) ui_frame_close(previous);
  if (!canvas->dead) {
    InvalidateRect(window, NULL, FALSE);
    POINT point; RECT bounds; GetCursorPos(&point); ScreenToClient(window, &point); GetClientRect(window, &bounds);
    if (PtInRect(&bounds, point) && GetForegroundWindow() == GetAncestor(window, GA_ROOT)) SetCursor(canvas_cursor(canvas));
  }
  mc_canvas_accessible_publish(canvas->accessible);
  release(canvas); return TRUE;
}
static HCURSOR canvas_cursor(Canvas *canvas) {
  int cursor = ui_frame_value(canvas->frame, MC_UI_FRAME_CURSOR);
  return LoadCursorW(NULL, cursor == MC_UI_CURSOR_RESIZE_HORIZONTAL ? IDC_SIZEWE :
      cursor == MC_UI_CURSOR_POINTER ? IDC_HAND : cursor == MC_UI_CURSOR_CROSSHAIR ? IDC_CROSS : IDC_ARROW);
}
static void deliver_size(Canvas *canvas) {
  RECT bounds; GetClientRect(canvas->window, &bounds);
  double scale = window_dpi(canvas->window) / 96.0;
  double width = (bounds.right - bounds.left) / scale, height = (bounds.bottom - bounds.top) / scale;
  if (width <= 0 || height <= 0) return;
  if (!canvas->delivered_size || width != canvas->delivered_width || height != canvas->delivered_height) {
    canvas->delivered_size = TRUE; canvas->delivered_width = width; canvas->delivered_height = height;
    if (canvas->callbacks.resize) canvas->callbacks.resize(canvas->context, canvas->window, width, height);
  }
}
static int input_flags(void) {
  return ((GetKeyState(VK_CONTROL) & 0x8000) ? MC_UI_INPUT_MOD : 0) |
      ((GetKeyState(VK_SHIFT) & 0x8000) ? MC_UI_INPUT_SHIFT : 0);
}
static void accessible_action(void *context, const uint16_t *identifier, size_t length) {
  Canvas *canvas = context;
  canvas->references++;
  MCCanvasInput input = {0}; input.type = MC_UI_INPUT_ACTIVATE; input.text = identifier; input.text_length = length;
  canvas->active = TRUE; emit(canvas, &input);
  release(canvas);
}
static void appearance(Canvas *canvas) {
  DWORD light = 1, bytes = sizeof(light);
  RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"AppsUseLightTheme", RRF_RT_REG_DWORD, NULL, &light, &bytes);
  const wchar_t *mode = light ? L"light" : L"dark";
  MCCanvasInput input = {0}; input.type = MC_UI_INPUT_APPEARANCE; input.text = (const uint16_t *)mode; input.text_length = wcslen(mode);
  emit(canvas, &input);
}
static void pointer(Canvas *canvas, int type, int x, int y) {
  double scale = window_dpi(canvas->window) / 96.0;
  MCCanvasInput input = {0}; input.type = type; input.x = x / scale; input.y = y / scale;
  emit(canvas, &input);
}
static const wchar_t *key_name(WPARAM key, int flags) {
  switch (key) {
  case VK_SPACE: return L"Space"; case VK_ESCAPE: return L"Escape";
  case VK_LEFT: return L"ArrowLeft"; case VK_RIGHT: return L"ArrowRight";
  case VK_UP: return L"ArrowUp"; case VK_DOWN: return L"ArrowDown";
  case VK_TAB: return L"Tab"; case VK_RETURN: return L"Enter";
  case VK_HOME: return L"Home"; case VK_END: return L"End";
  case VK_BACK: return L"Backspace"; case VK_DELETE: return L"Delete";
  default: break;
  }
  if (flags & MC_UI_INPUT_MOD) switch (key) {
  case 'Z': return L"z"; case VK_OEM_PLUS: case VK_ADD: return L"+";
  case VK_OEM_MINUS: case VK_SUBTRACT: return L"-"; case '0': case VK_NUMPAD0: return L"0";
  default: break;
  }
  return NULL;
}
static LRESULT canvas_message(Canvas *canvas, UINT message, WPARAM wp, LPARAM lp) {
  HWND window = canvas->window;
  switch (message) {
  case WM_CREATE:
    canvas->accessible = mc_canvas_accessible_create(window, accessible_action, canvas);
    if (!canvas->accessible) return -1;
    canvas->tooltip = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE, TOOLTIPS_CLASSW, NULL,
        WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
        window, NULL, (HINSTANCE)GetWindowLongPtrW(window, GWLP_HINSTANCE), NULL);
    if (canvas->tooltip) SendMessageW(canvas->tooltip, TTM_SETMAXTIPWIDTH, 0, 400);
    return 0;
  case WM_GETOBJECT: {
    LRESULT object = mc_canvas_accessible_object(canvas->accessible, wp, lp);
    if (object) return object;
    break;
  }
  case WM_THEMECHANGED: case WM_SETTINGCHANGE: appearance(canvas); return 0;
  case WM_SIZE: deliver_size(canvas); return 0;
  case WM_DPICHANGED_BEFOREPARENT: cancel(canvas); return 0;
  case WM_DPICHANGED_AFTERPARENT:
    update_tooltips(canvas); canvas->delivered_size = FALSE; deliver_size(canvas); InvalidateRect(window, NULL, FALSE); return 0;
  case WM_PAINT: {
    PAINTSTRUCT ps; HDC dc = BeginPaint(window, &ps); RECT bounds; GetClientRect(window, &bounds);
    HDC buffer = CreateCompatibleDC(dc);
    HBITMAP bitmap = buffer && bounds.right > 0 && bounds.bottom > 0 ? CreateCompatibleBitmap(dc, bounds.right, bounds.bottom) : NULL;
    HGDIOBJ old = bitmap ? SelectObject(buffer, bitmap) : NULL;
    paint_canvas(canvas, bitmap ? buffer : dc, &bounds, window_dpi(window));
    if (bitmap) { BitBlt(dc, ps.rcPaint.left, ps.rcPaint.top, ps.rcPaint.right - ps.rcPaint.left,
        ps.rcPaint.bottom - ps.rcPaint.top, buffer, ps.rcPaint.left, ps.rcPaint.top, SRCCOPY);
      SelectObject(buffer, old); DeleteObject(bitmap); }
    if (buffer) DeleteDC(buffer); EndPaint(window, &ps); return 0;
  }
  case WM_PRINTCLIENT: { RECT bounds; GetClientRect(window, &bounds); paint_canvas(canvas, (HDC)wp, &bounds, window_dpi(window)); return 0; }
  case WM_ERASEBKGND: return 1;
  case WM_SETCURSOR:
    if (LOWORD(lp) == HTCLIENT) { SetCursor(canvas_cursor(canvas)); return TRUE; } break;
  case WM_LBUTTONDOWN: {
    BOOL preserve = canvas->callbacks.preserve_focus_on_press &&
        canvas->callbacks.preserve_focus_on_press(canvas->context, window);
    if (canvas->dead) return 0;
    if (!preserve) SetFocus(window);
    if (canvas->dead) return 0;
    canvas->active = TRUE; canvas->pointer_down = TRUE;
    pointer(canvas, MC_UI_INPUT_POINTER_DOWN, GET_X_LPARAM(lp), GET_Y_LPARAM(lp)); return 0;
  }
  case WM_MOUSEMOVE:
    if (!canvas->tracking) { TRACKMOUSEEVENT tracking = {sizeof(tracking), TME_LEAVE, window, 0};
      canvas->tracking = TrackMouseEvent(&tracking); }
    if (canvas->pointer_down && !(wp & MK_LBUTTON)) cancel(canvas);
    pointer(canvas, MC_UI_INPUT_POINTER_MOVE, GET_X_LPARAM(lp), GET_Y_LPARAM(lp)); return 0;
  case WM_MOUSELEAVE: canvas->tracking = FALSE; if (!canvas->pointer_down) pointer(canvas, MC_UI_INPUT_POINTER_MOVE, -1, -1); return 0;
  case WM_LBUTTONUP:
    if (canvas->pointer_down) {
      canvas->pointer_down = FALSE;
      pointer(canvas, MC_UI_INPUT_POINTER_UP, GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
      if (!canvas->dead) release_capture(canvas);
    } return 0;
  case WM_MOUSEWHEEL: case WM_MOUSEHWHEEL: {
    POINT point = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)}; ScreenToClient(window, &point);
    double scale = window_dpi(window) / 96.0;
    double delta = GET_WHEEL_DELTA_WPARAM(wp) / (double)WHEEL_DELTA;
    MCCanvasInput input = {0}; input.type = MC_UI_INPUT_SCROLL; input.x = point.x / scale; input.y = point.y / scale;
    /* Windows horizontal positive means right; the shared contract's positive
     * delta means earlier/left. Fractional wheel input is never discarded. */
    if (message == WM_MOUSEHWHEEL) input.delta_x = -delta; else input.delta_y = delta;
    input.flags = ((GET_KEYSTATE_WPARAM(wp) & MK_CONTROL) ? MC_UI_INPUT_MOD : 0) |
        ((GET_KEYSTATE_WPARAM(wp) & MK_SHIFT) ? MC_UI_INPUT_SHIFT : 0);
    canvas->active = TRUE; emit(canvas, &input); return 0;
  }
  case WM_GETDLGCODE: return DLGC_WANTARROWS | DLGC_WANTTAB;
  case WM_KEYDOWN: {
    if (GetFocus() != window || (GetKeyState(VK_MENU) & 0x8000)) break;
    int flags = input_flags(); const wchar_t *name = key_name(wp, flags);
    if (!name) break;
    if (wp == VK_ESCAPE) { canvas->pointer_down = FALSE; release_capture(canvas); }
    MCCanvasInput input = {0}; input.type = MC_UI_INPUT_KEY; input.flags = flags;
    input.text = (const uint16_t *)name; input.text_length = wcslen(name);
    canvas->active = TRUE; emit(canvas, &input); return 0;
  }
  case WM_SETFOCUS: canvas->active = TRUE; return 0;
  case WM_KILLFOCUS: cancel(canvas); return 0;
  case WM_CANCELMODE: cancel(canvas); return 0;
  case WM_CAPTURECHANGED:
    if ((HWND)lp != window && (canvas->capture_owned || canvas->pointer_down)) cancel(canvas); return 0;
  case WM_SHOWWINDOW: if (!wp) cancel(canvas); break;
  case WM_DESTROY: cancel(canvas); return 0;
  case WM_NCDESTROY: {
    canvas->dead = TRUE; SetWindowLongPtrW(window, GWLP_USERDATA, 0);
    mc_canvas_accessible_disconnect(canvas->accessible); canvas->accessible = NULL;
    clear_tooltips(canvas);
    if (canvas->tooltip) DestroyWindow(canvas->tooltip);
    if (canvas->frame) ui_frame_close(canvas->frame);
    canvas->frame = 0;
    if (canvas->callbacks.destroyed) canvas->callbacks.destroyed(canvas->context, window);
    release(canvas); break;
  }
  default: break;
  }
  return DefWindowProcW(window, message, wp, lp);
}
static LRESULT CALLBACK canvas_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  Canvas *canvas = canvas_for(window);
  if (message == WM_NCCREATE) {
    CREATESTRUCTW *creation = (CREATESTRUCTW *)lp;
    canvas = creation->lpCreateParams; canvas->window = window; canvas->references++;
    SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)canvas);
  }
  if (!canvas) return DefWindowProcW(window, message, wp, lp);
  canvas->references++;
  LRESULT result = canvas_message(canvas, message, wp, lp);
  release(canvas); return result;
}
HWND mc_win_canvas_create(HWND parent, HINSTANCE instance, int identifier,
                         const MCWinCanvasCallbacks *callbacks, void *context) {
  if (!parent || !callbacks) return NULL;
  WNDCLASSEXW klass = {sizeof(klass)}; klass.hInstance = instance; klass.lpfnWndProc = canvas_proc;
  klass.lpszClassName = canvas_class; klass.hCursor = LoadCursorW(NULL, IDC_ARROW);
  if (!RegisterClassExW(&klass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return NULL;
  Canvas *canvas = calloc(1, sizeof(*canvas)); if (!canvas) return NULL;
  canvas->references = 1; canvas->callbacks = *callbacks; canvas->context = context;
  HWND window = CreateWindowExW(0, canvas_class, L"", WS_CHILD | WS_CLIPSIBLINGS | WS_VISIBLE | WS_TABSTOP,
      0, 0, 1, 1, parent, (HMENU)(INT_PTR)identifier, instance, canvas);
  /* The shared component defaults to dark. Deliver the actual system setting
   * after creation, keeping the creator lease through this reentrant callback. */
  if (window && !canvas->dead) appearance(canvas);
  if (canvas->dead) window = NULL;
  release(canvas); return window;
}
