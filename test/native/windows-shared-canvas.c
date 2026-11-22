/* Isolated Windows canvas + real MoonBit v2 scene. Synthetic media/clock only;
 * this proves drawing and input integration, not a playback/media backend. */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <oleacc.h>
#include <oleauto.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <math.h>
#include "platform/windows/graphics/shared_canvas.h"
#include "bindings/c/video_ui.h"
#include "bindings/c/video_project.h"

typedef struct {
  HWND canvas;
  int32_t project, ui, frame;
  wchar_t *snapshot, *frame_json;
  double width, height;
  unsigned commands, inputs, cancels, plays, appearances;
  MCCanvasInput last_input;
  BOOL failed, destroyed, destroy_on_input, destroy_on_appearance;
} Harness;
static moonbit_string_t input(const wchar_t *text) {
  int length = (int)wcslen(text);
  moonbit_string_t result = moonbit_make_string_raw(length);
  memcpy(result, text, (size_t)length * sizeof(wchar_t)); return result;
}
static wchar_t *output(moonbit_string_t text) {
  int length = Moonbit_array_length(text); wchar_t *result = calloc((size_t)length + 1, sizeof(wchar_t));
  if (result) memcpy(result, text, (size_t)length * sizeof(wchar_t));
  moonbit_decref(text); return result;
}
/* Fixture-only extraction from trusted core output, never application input.
 * Native production adapters consume typed frames and encode typed events. */
static const wchar_t *field(const wchar_t *json, const wchar_t *key) {
  wchar_t pattern[80]; swprintf_s(pattern, 80, L"\"%ls\":", key);
  const wchar_t *at = json ? wcsstr(json, pattern) : NULL;
  if (!at) return NULL; at += wcslen(pattern); while (*at == L' ' || *at == L'\n') at++; return at;
}
static BOOL flag(const wchar_t *json, const wchar_t *key) { const wchar_t *at = field(json, key); return at && !wcsncmp(at, L"true", 4); }
static double number(const wchar_t *json, const wchar_t *key) { const wchar_t *at = field(json, key); return at ? wcstod(at, NULL) : -1; }
static wchar_t *object(const wchar_t *json, const wchar_t *key) {
  const wchar_t *start = field(json, key); if (!start || *start != '{') return NULL;
  int depth = 0; BOOL quoted = FALSE, escaped = FALSE;
  for (const wchar_t *at = start; *at; at++) {
    if (quoted) { if (escaped) escaped = FALSE; else if (*at == '\\') escaped = TRUE; else if (*at == '"') quoted = FALSE; }
    else if (*at == '"') quoted = TRUE;
    else if (*at == '{') depth++;
    else if (*at == '}' && !--depth) {
      size_t count = (size_t)(at - start + 1); wchar_t *copy = calloc(count + 1, sizeof(wchar_t));
      if (copy) memcpy(copy, start, count * sizeof(wchar_t)); return copy;
    }
  }
  return NULL;
}
static void render(Harness *h) {
  if (!h->canvas || h->destroyed || h->width <= 0 || h->height <= 0) return;
  moonbit_string_t json = video_ui_frame(h->ui, h->width, h->height);
  int32_t frame = ui_frame_open(json);
  free(h->frame_json); h->frame_json = output(json);
  if (!frame || !mc_win_canvas_set_frame(h->canvas, frame)) { if (frame) ui_frame_close(frame); h->failed = TRUE; return; }
  h->frame = frame;
}
static void send_json(Harness *h, const wchar_t *json) {
  moonbit_string_t encoded = input(json);
  wchar_t *result = output(video_ui_event(h->ui, encoded)); moonbit_decref(encoded);
  if (!result || !flag(result, L"ok")) { h->failed = TRUE; free(result); return; }
  if (h->canvas) mc_win_canvas_set_capture(h->canvas, flag(result, L"capture"));
  wchar_t *command = object(result, L"command");
  if (command) {
    size_t capacity = wcslen(command) + 180; wchar_t *request = calloc(capacity, sizeof(wchar_t));
    if (!request) h->failed = TRUE;
    else {
      swprintf_s(request, capacity, L"{\"expectedRevision\":%.0f,\"requestId\":\"canvas-%u\",%ls",
          number(h->snapshot, L"revision"), ++h->commands, command + 1);
      encoded = input(request); wchar_t *next = output(video_project_command(h->project, encoded)); moonbit_decref(encoded);
      if (!next || !flag(next, L"ok")) { h->failed = TRUE; free(next); }
      else {
        free(h->snapshot); h->snapshot = next;
        size_t count = wcslen(next) + 48; wchar_t *event = calloc(count, sizeof(wchar_t));
        if (!event) h->failed = TRUE;
        else { swprintf_s(event, count, L"{\"type\":\"snapshot\",\"snapshot\":%ls}", next); send_json(h, event); free(event); }
      }
      free(request);
    }
    free(command);
  }
  if (wcsstr(result, L"\"type\":\"play\"")) h->plays++;
  free(result); render(h);
}
static void on_input(void *context, HWND window, const MCCanvasInput *event) {
  Harness *h = context; h->inputs++; h->last_input = *event; h->last_input.text = NULL;
  if (event->type == MC_UI_INPUT_CANCEL) h->cancels++;
  if (event->type == MC_UI_INPUT_APPEARANCE) h->appearances++;
  if (h->destroy_on_appearance && event->type == MC_UI_INPUT_APPEARANCE) { DestroyWindow(window); return; }
  if (h->destroy_on_input && event->type == MC_UI_INPUT_POINTER_DOWN) { DestroyWindow(window); return; }
  moonbit_string_t json = mc_canvas_input_json(event); wchar_t *text = output(json);
  if (!text || !*text) h->failed = TRUE; else send_json(h, text);
  free(text);
}
static void on_resize(void *context, HWND window, double width, double height) {
  Harness *h = context; h->canvas = window; h->width = width; h->height = height; render(h);
}
static void on_destroyed(void *context, HWND window) { (void)window; Harness *h = context; h->destroyed = TRUE; h->canvas = NULL; }
static void video_fixture(void *context, HWND window, HDC target, const RECT *rect) {
  (void)context; (void)window; HBRUSH color = CreateSolidBrush(RGB(0, 255, 0)); FillRect(target, rect, color); DeleteObject(color);
}
static int semantic(Harness *h, const wchar_t *id) {
  for (int i = 0; i < ui_frame_semantic_count(h->frame); i++) {
    wchar_t *text = output(ui_frame_semantic_text(h->frame, i, MC_UI_SEM_ID));
    BOOL found = text && !wcscmp(text, id); free(text); if (found) return i;
  }
  return -1;
}
static POINT semantic_point(Harness *h, int index) {
  double scale = GetDpiForWindow(h->canvas) / 96.0;
  POINT p = {(LONG)lround((ui_frame_semantic_number(h->frame, index, MC_UI_SEM_X) +
      ui_frame_semantic_number(h->frame, index, MC_UI_SEM_WIDTH) / 2) * scale),
    (LONG)lround((ui_frame_semantic_number(h->frame, index, MC_UI_SEM_Y) +
      ui_frame_semantic_number(h->frame, index, MC_UI_SEM_HEIGHT) / 2) * scale)};
  return p;
}
static void click(Harness *h, const wchar_t *id) {
  int i = semantic(h, id); if (i < 0) { h->failed = TRUE; return; }
  POINT p = semantic_point(h, i);
  SendMessageW(h->canvas, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(p.x, p.y));
  SendMessageW(h->canvas, WM_LBUTTONUP, 0, MAKELPARAM(p.x, p.y));
}
static void key(Harness *h, WPARAM key, BOOL control) {
  BYTE saved[256], current[256]; GetKeyboardState(saved); memcpy(current, saved, sizeof(current));
  current[VK_CONTROL] = control ? 0x80 : 0; current[VK_MENU] = 0; current[VK_SHIFT] = 0;
  SetKeyboardState(current); SetFocus(h->canvas); SendMessageW(h->canvas, WM_KEYDOWN, key, 0); SetKeyboardState(saved);
}
static BOOL screenshot(HWND window, const wchar_t *path, int dpi, BOOL fixture) {
  if (dpi <= 0 || dpi > 960) return FALSE;
  int width = fixture ? MulDiv(200, dpi, 96) : 1040, height = fixture ? MulDiv(120, dpi, 96) : 720;
  BITMAPINFO info = {0}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER); info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height; info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
  HDC screen = GetDC(NULL), dc = CreateCompatibleDC(screen); void *pixels = NULL;
  HBITMAP bitmap = dc ? CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, NULL, 0) : NULL; ReleaseDC(NULL, screen);
  if (!bitmap) { if (dc) DeleteDC(dc); return FALSE; }
  HGDIOBJ previous = SelectObject(dc, bitmap); RECT bounds = {0, 0, width, height};
  BOOL ok = mc_win_canvas_paint(window, dc, &bounds, (UINT)dpi);
  if (fixture) {
    ok = ok && GetPixel(dc, MulDiv(20, dpi, 96), MulDiv(20, dpi, 96)) == RGB(255, 0, 0) &&
        GetPixel(dc, MulDiv(15, dpi, 96), MulDiv(65, dpi, 96)) == RGB(0, 255, 0) &&
        GetPixel(dc, MulDiv(25, dpi, 96), MulDiv(75, dpi, 96)) == RGB(255, 255, 255) &&
        GetPixel(dc, MulDiv(4, dpi, 96), MulDiv(4, dpi, 96)) == RGB(16, 16, 16);
    unsigned glyphs = 0;
    for (int y = MulDiv(10, dpi, 96); y < MulDiv(40, dpi, 96); y++)
      for (int x = MulDiv(60, dpi, 96); x < MulDiv(180, dpi, 96); x++) if (GetPixel(dc, x, y) != RGB(16, 16, 16)) glyphs++;
    ok = ok && glyphs > 15 && GetPixel(dc, MulDiv(185, dpi, 96), MulDiv(20, dpi, 96)) == RGB(16, 16, 16);
    // Each compact property label must match its full-width reference, including
    // the last glyph. This catches both wrapping and premature ellipses.
    unsigned label_ink = 0;
    for (int y = MulDiv(52, dpi, 96); y < MulDiv(100, dpi, 96); y++) {
      for (int x = 0; x < MulDiv(48, dpi, 96); x++) {
        COLORREF full = GetPixel(dc, MulDiv(136, dpi, 96) + x, y);
        if (full != RGB(16, 16, 16)) label_ink++;
        if (GetPixel(dc, MulDiv(80, dpi, 96) + x, y) != full) ok = FALSE;
      }
    }
    ok = ok && label_ink > 30;
  }
  GdiFlush();
  BITMAPFILEHEADER header = {0}; header.bfType = 0x4d42;
  header.bfOffBits = sizeof(header) + sizeof(info.bmiHeader); header.bfSize = header.bfOffBits + (DWORD)width * (DWORD)height * 4;
  HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  DWORD written; BOOL saved = file != INVALID_HANDLE_VALUE && WriteFile(file, &header, sizeof(header), &written, NULL) && written == sizeof(header) &&
      WriteFile(file, &info.bmiHeader, sizeof(info.bmiHeader), &written, NULL) && written == sizeof(info.bmiHeader) &&
      WriteFile(file, pixels, (DWORD)width * (DWORD)height * 4, &written, NULL) && written == (DWORD)width * (DWORD)height * 4;
  if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
  SelectObject(dc, previous); DeleteObject(bitmap); DeleteDC(dc); return ok && saved;
}
static BOOL install_json(Harness *h, const wchar_t *json) {
  moonbit_string_t text = input(json); int32_t frame = ui_frame_open(text); moonbit_decref(text);
  if (!frame) return FALSE;
  if (!mc_win_canvas_set_frame(h->canvas, frame)) { ui_frame_close(frame); return FALSE; }
  h->frame = frame; return TRUE;
}
static VARIANT child_variant(LONG id) { VARIANT result; VariantInit(&result); result.vt = VT_I4; result.lVal = id; return result; }
static LONG find_accessible(IAccessible *a, const wchar_t *label) {
  VARIANT child; VariantInit(&child);
  HRESULT found = IAccessible_accNavigate(a, NAVDIR_FIRSTCHILD, child_variant(CHILDID_SELF), &child);
  while (found == S_OK && child.vt == VT_I4) {
    BSTR name = NULL; IAccessible_get_accName(a, child, &name);
    BOOL match = name && !wcscmp(name, label); SysFreeString(name); if (match) return child.lVal;
    VARIANT next; VariantInit(&next); found = IAccessible_accNavigate(a, NAVDIR_NEXT, child, &next); child = next;
  }
  return 0;
}
static BOOL enumeration_check(BOOL condition, const char *step, HRESULT result, LONG actual, LONG expected) {
  if (!condition) fprintf(stderr, "FAIL canvas enumeration %s: hr=0x%08lx actual=%ld expected=%ld\n",
      step, (unsigned long)result, actual, expected);
  return condition;
}
static BOOL enumerate_accessible(IAccessible *accessible, LONG retired) {
  LONG count = 0, obtained = 0; ULONG fetched = 0;
  HRESULT result = IAccessible_get_accChildCount(accessible, &count);
  if (!enumeration_check(SUCCEEDED(result) && count >= 2, "child count", result, count, 2)) return FALSE;
  VARIANT *children = calloc((size_t)count, sizeof(*children)); if (!children) return FALSE;
  IEnumVARIANT *enumeration = NULL, *clone = NULL;
  IUnknown *provider_identity = NULL, *enum_identity = NULL, *clone_identity = NULL;
  VARIANT first, second, cloned, reset;
  VariantInit(&first); VariantInit(&second); VariantInit(&cloned); VariantInit(&reset);
  result = AccessibleChildren(accessible, 0, count, children, &obtained);
  BOOL ok = enumeration_check(result == S_OK && obtained == count, "AccessibleChildren", result, obtained, count);
  if (obtained < 0 || obtained > count) { ok = FALSE; goto cleanup; }
  for (LONG i = 0; i < obtained; i++) {
    VARIANT role; VariantInit(&role);
    result = IAccessible_get_accRole(accessible, children[i], &role);
    ok = enumeration_check(children[i].vt == VT_I4 && children[i].lVal > 0 && children[i].lVal != retired &&
        SUCCEEDED(result), "live child role", result, children[i].lVal, retired) && ok;
    for (LONG j = 0; j < i; j++) ok = enumeration_check(children[i].lVal != children[j].lVal,
        "unique child identity", result, children[i].lVal, children[j].lVal) && ok;
    VariantClear(&role);
  }
  result = IAccessible_QueryInterface(accessible, &IID_IEnumVARIANT, (void **)&enumeration);
  if (!enumeration_check(result == S_OK && enumeration, "QI enumeration", result, 0, 0)) { ok = FALSE; goto cleanup; }
  /* QueryInterface does not rewind an existing COM object. AccessibleChildren
   * has already consumed this provider's primary enumeration. */
  result = IEnumVARIANT_Reset(enumeration);
  ok = enumeration_check(result == S_OK, "primary Reset", result, 0, 0) && ok;
  result = IEnumVARIANT_Next(enumeration, 1, &first, &fetched);
  ok = enumeration_check(result == S_OK && fetched == 1 && first.vt == VT_I4 && first.lVal == children[0].lVal,
      "primary first child", result, first.lVal, children[0].lVal) && ok;
  result = IEnumVARIANT_Clone(enumeration, &clone);
  if (!enumeration_check(result == S_OK && clone, "Clone", result, 0, 0)) { ok = FALSE; goto cleanup; }
  result = IAccessible_QueryInterface(accessible, &IID_IUnknown, (void **)&provider_identity);
  ok = enumeration_check(result == S_OK && provider_identity, "provider IUnknown", result, 0, 0) && ok;
  result = IEnumVARIANT_QueryInterface(enumeration, &IID_IUnknown, (void **)&enum_identity);
  ok = enumeration_check(result == S_OK && enum_identity && enum_identity == provider_identity,
      "primary shares provider identity", result, 0, 0) && ok;
  result = IEnumVARIANT_QueryInterface(clone, &IID_IUnknown, (void **)&clone_identity);
  ok = enumeration_check(result == S_OK && clone_identity && clone_identity != enum_identity,
      "clone has independent COM identity", result, 0, 0) && ok;
  result = IEnumVARIANT_Next(enumeration, 1, &second, NULL);
  ok = enumeration_check(result == S_OK && second.vt == VT_I4 && second.lVal == children[1].lVal,
      "primary advances independently", result, second.lVal, children[1].lVal) && ok;
  result = IEnumVARIANT_Next(clone, 1, &cloned, NULL);
  ok = enumeration_check(result == S_OK && cloned.vt == VT_I4 && cloned.lVal == second.lVal,
      "clone preserves copied position", result, cloned.lVal, second.lVal) && ok;
  result = IEnumVARIANT_Skip(clone, (ULONG)count + 1);
  ok = enumeration_check(result == S_FALSE, "clone Skip beyond end", result, 0, 0) && ok;
  result = IEnumVARIANT_Reset(clone);
  ok = enumeration_check(result == S_OK, "clone Reset", result, 0, 0) && ok;
  result = IEnumVARIANT_Next(clone, 1, &reset, NULL);
  ok = enumeration_check(result == S_OK && reset.vt == VT_I4 && reset.lVal == first.lVal,
      "clone rewinds its own snapshot", result, reset.lVal, first.lVal) && ok;
  VariantClear(&second);
  result = IEnumVARIANT_Next(enumeration, 1, &second, &fetched);
  ok = enumeration_check(count > 2 ? result == S_OK && fetched == 1 && second.vt == VT_I4 && second.lVal == children[2].lVal
      : result == S_FALSE && fetched == 0, "clone Reset leaves primary cursor unchanged", result,
      second.lVal, count > 2 ? children[2].lVal : 0) && ok;
cleanup:
  if (clone_identity) IUnknown_Release(clone_identity);
  if (enum_identity) IUnknown_Release(enum_identity);
  if (provider_identity) IUnknown_Release(provider_identity);
  if (clone) IEnumVARIANT_Release(clone);
  if (enumeration) IEnumVARIANT_Release(enumeration);
  VariantClear(&first); VariantClear(&second); VariantClear(&cloned); VariantClear(&reset);
  for (LONG i = 0; i < count; i++) VariantClear(&children[i]); free(children); return ok;
}
#define CHECK(test, label) do { if (!(test)) { fprintf(stderr, "FAIL canvas: %s\n", label); passed = FALSE; } } while (0)
int wmain(int argc, wchar_t **argv) {
  if (argc != 2) return 2;
  BOOL passed = TRUE; Harness h = {0}; h.project = h.ui = -1;
  moonbit_init(); HRESULT initialized = OleInitialize(NULL); if (FAILED(initialized)) return 2;
  MCCanvasInput invalid = {0}; invalid.type = MC_UI_INPUT_KEY; invalid.text_length = 257;
  moonbit_string_t rejected = mc_canvas_input_json(&invalid);
  CHECK(Moonbit_array_length(rejected) == 0, "oversized/null key input is rejected before allocation or access"); moonbit_decref(rejected);
  invalid.text_length = 1; rejected = mc_canvas_input_json(&invalid);
  CHECK(Moonbit_array_length(rejected) == 0, "nonempty input cannot borrow a NULL text buffer"); moonbit_decref(rejected);
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  INITCOMMONCONTROLSEX controls = {sizeof(controls), ICC_WIN95_CLASSES}; InitCommonControlsEx(&controls);
  CreateDirectoryW(argv[1], NULL);
  HINSTANCE instance = GetModuleHandleW(NULL); HWND parent = CreateWindowExW(0, L"STATIC", L"Mooji Cut canvas fixture",
      WS_OVERLAPPEDWINDOW, 60, 60, 1100, 800, NULL, NULL, instance, NULL);
  if (!parent) { OleUninitialize(); return 2; }
  moonbit_string_t source = input(L"{\"durationMs\":4000,\"width\":320,\"height\":240,\"hasAudio\":true}"), draft = input(L"");
  h.snapshot = output(video_project_open(source, draft)); moonbit_decref(source); moonbit_decref(draft);
  CHECK(h.snapshot && flag(h.snapshot, L"ok"), "real v2 project opens");
  if (!passed) goto cleanup;
  h.project = (int32_t)number(h.snapshot, L"session"); source = input(h.snapshot); h.ui = video_ui_open(source); moonbit_decref(source);
  CHECK(h.ui >= 0, "shared UI opens from the authoritative v2 snapshot"); if (!passed) goto cleanup;
  MCWinCanvasCallbacks callbacks = {on_input, on_resize, on_destroyed, video_fixture};
  h.canvas = mc_win_canvas_create(parent, instance, 101, &callbacks, &h);
  CHECK(h.canvas != NULL, "native canvas is created"); if (!passed) goto cleanup;
  CHECK(h.appearances == 1, "initial system appearance is delivered before any manually injected theme message");
  UINT window_dpi = GetDpiForWindow(h.canvas);
  CHECK(window_dpi > 0 && window_dpi <= 960, "fixture DPI fits the drawing adapter and signed MulDiv arguments");
  if (!passed) goto cleanup;
  int dpi = (int)window_dpi;
  SetWindowPos(h.canvas, NULL, 0, 0, MulDiv(1040, dpi, 96), MulDiv(720, dpi, 96), SWP_NOZORDER | SWP_NOACTIVATE);
  ShowWindow(parent, SW_SHOW); SetForegroundWindow(parent); SetFocus(h.canvas); UpdateWindow(parent);
  CHECK(h.frame > 0 && !h.failed, "WM_SIZE produces an owned typed frame");
  SendMessageW(h.canvas, WM_THEMECHANGED, 0, 0);
  CHECK(h.last_input.type == MC_UI_INPUT_APPEARANCE, "system appearance becomes a shared input event");
  click(&h, L"clip:v1");
  /* Clip-body clicks select; a separate real ruler click seeks inside the
   * source. Splitting at the initial zero playhead is correctly unavailable. */
  click(&h, L"playhead");
  double split_time = ui_frame_semantic_number(h.frame, semantic(&h, L"playhead"), MC_UI_SEM_VALUE);
  CHECK(split_time > 0 && split_time < 4000 &&
      ui_frame_semantic_value(h.frame, semantic(&h, L"project-split"), MC_UI_SEM_ENABLED) == 1,
      "a real ruler click seeks inside the selected clip before splitting");
  click(&h, L"project-split");
  CHECK(h.commands == 1 && !h.failed, "real mouse events split through UI effects and core");
  int second = -1;
  for (int i = 0; i < ui_frame_semantic_count(h.frame); i++) {
    wchar_t *id = output(ui_frame_semantic_text(h.frame, i, MC_UI_SEM_ID));
    if (id && !wcsncmp(id, L"clip:v", 6) && wcscmp(id, L"clip:v1")) second = i; free(id);
  }
  CHECK(second >= 0, "split produces a second actual video clip");
  if (second >= 0) {
    POINT at = semantic_point(&h, second); int delta = MulDiv(160, dpi, 96);
    SendMessageW(h.canvas, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(at.x, at.y));
    CHECK(GetCapture() == h.canvas, "shared capture result acquires native pointer capture");
    SendMessageW(h.canvas, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(at.x + delta, at.y));
    unsigned commands = h.commands;
    SendMessageW(h.canvas, WM_CANCELMODE, 0, 0);
    SendMessageW(h.canvas, WM_LBUTTONUP, 0, MAKELPARAM(at.x + delta, at.y));
    CHECK(h.commands == commands && GetCapture() != h.canvas && h.cancels > 0, "cancellation releases capture and late mouse-up cannot commit");
    SendMessageW(h.canvas, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(at.x, at.y));
    SendMessageW(h.canvas, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(at.x + delta, at.y));
    SendMessageW(h.canvas, WM_LBUTTONUP, 0, MAKELPARAM(at.x + delta, at.y));
    BOOL gap = FALSE;
    for (int i = 0; i < ui_frame_semantic_count(h.frame); i++) {
      wchar_t *id = output(ui_frame_semantic_text(h.frame, i, MC_UI_SEM_ID)); gap |= id && !wcsncmp(id, L"gap:", 4); free(id);
    }
    CHECK(h.commands == commands + 1 && gap && !h.failed, "body dragging leaves an actual v2 gap with no native timeline rules");
    key(&h, 'Z', TRUE); CHECK(h.commands == commands + 2 && !h.failed, "Ctrl+Z follows the shared command/undo path");
  }
  double before_span = number(field(h.frame_json, L"viewport"), L"spanMs");
  POINT wheel = {MulDiv(400, dpi, 96), MulDiv(600, dpi, 96)}; ClientToScreen(h.canvas, &wheel);
  SendMessageW(h.canvas, WM_MOUSEWHEEL, MAKEWPARAM(MK_CONTROL, WHEEL_DELTA / 2), MAKELPARAM(wheel.x, wheel.y));
  CHECK(h.last_input.type == MC_UI_INPUT_SCROLL && fabs(h.last_input.delta_y - .5) < .00001 &&
      number(field(h.frame_json, L"viewport"), L"spanMs") < before_span, "fractional Ctrl+wheel changes the shared viewport, preserving half-notch input");
  unsigned cancel_count = h.cancels; SetFocus(parent);
  CHECK(h.cancels > cancel_count, "focus loss cancels shared input"); SetFocus(h.canvas);
  wchar_t path[MAX_PATH]; swprintf_s(path, MAX_PATH, L"%ls\\video-ui.bmp", argv[1]);
  CHECK(screenshot(h.canvas, path, 96, FALSE), "actual v2 frame renders to a screenshot");
  IAccessible *accessible = NULL;
  CHECK(SUCCEEDED(AccessibleObjectFromWindow(h.canvas, (DWORD)OBJID_CLIENT, &IID_IAccessible, (void **)&accessible)) && accessible,
      "WM_GETOBJECT supplies a real MSAA provider");
  LONG retained_child = 0;
  if (accessible) {
    CHECK(enumerate_accessible(accessible, 0), "AccessibleChildren and snapshot IEnumVARIANT expose every live semantic child");
    wchar_t *label = output(ui_frame_semantic_text(h.frame, semantic(&h, L"play"), MC_UI_SEM_LABEL));
    retained_child = find_accessible(accessible, label); free(label);
    VARIANT role; VariantInit(&role);
    CHECK(retained_child && SUCCEEDED(IAccessible_get_accRole(accessible, child_variant(retained_child), &role)) &&
        role.vt == VT_I4 && role.lVal == ROLE_SYSTEM_PUSHBUTTON, "MSAA consumes shared labels and button roles");
    unsigned plays = h.plays;
    CHECK(SUCCEEDED(IAccessible_accDoDefaultAction(accessible, child_variant(retained_child))) && h.plays == plays + 1,
        "MSAA action routes through typed activate and the shared UI");
  }
  CHECK(install_json(&h, L"{\"ok\":true,\"commands\":["
      L"{\"type\":\"rect\",\"x\":0,\"y\":0,\"width\":200,\"height\":120,\"fill\":\"#101010\"},"
      L"{\"type\":\"rect\",\"x\":10,\"y\":10,\"width\":30,\"height\":20,\"fill\":\"#ff0000\"},"
      L"{\"type\":\"line\",\"x1\":10,\"y1\":40,\"x2\":50,\"y2\":40,\"color\":\"#0000ff\",\"lineWidth\":2},"
      L"{\"type\":\"text\",\"x\":60,\"y\":10,\"width\":120,\"height\":30,\"text\":\"中 A&B\",\"size\":16,\"color\":\"#ffffff\",\"align\":\"center\",\"valign\":\"center\"},"
      L"{\"type\":\"text\",\"x\":80,\"y\":52,\"width\":24,\"height\":22,\"text\":\"颜色\",\"size\":11,\"color\":\"#ffffff\",\"valign\":\"center\",\"singleLine\":true},"
      L"{\"type\":\"text\",\"x\":136,\"y\":52,\"width\":60,\"height\":22,\"text\":\"颜色\",\"size\":11,\"color\":\"#ffffff\",\"valign\":\"center\",\"singleLine\":true},"
      L"{\"type\":\"text\",\"x\":80,\"y\":76,\"width\":35,\"height\":22,\"text\":\"透明度\",\"size\":11,\"color\":\"#ffffff\",\"valign\":\"center\",\"singleLine\":true},"
      L"{\"type\":\"text\",\"x\":136,\"y\":76,\"width\":60,\"height\":22,\"text\":\"透明度\",\"size\":11,\"color\":\"#ffffff\",\"valign\":\"center\",\"singleLine\":true}],"
      L"\"videoRect\":{\"x\":10,\"y\":60,\"width\":60,\"height\":40},\"overlayCommands\":["
      L"{\"type\":\"rect\",\"x\":20,\"y\":70,\"width\":10,\"height\":10,\"fill\":\"#ffffff\"}],\"semantics\":[],\"cursor\":\"default\"}"),
      "primitive fixture is validated by the same immutable frame ABI");
  if (accessible) CHECK(FAILED(IAccessible_accDoDefaultAction(accessible, child_variant(retained_child))), "removed semantic child cannot activate a later frame");
  const int dpis[] = {96, 120, 144, 192};
  for (size_t i = 0; i < ARRAYSIZE(dpis); i++) {
    swprintf_s(path, MAX_PATH, L"%ls\\primitives-%d.bmp", argv[1], dpis[i]);
    CHECK(screenshot(h.canvas, path, dpis[i], TRUE), "DPI fixture validates full single-line labels, clipping and video/overlay order");
  }
  CHECK(!mc_win_canvas_set_frame(h.canvas, INT32_MAX), "invalid frame replacement is rejected");
  render(&h);
  if (accessible) {
    CHECK(FAILED(IAccessible_accDoDefaultAction(accessible, child_variant(retained_child))), "retired child identity is not reused when controls return");
    wchar_t *label = output(ui_frame_semantic_text(h.frame, semantic(&h, L"play"), MC_UI_SEM_LABEL));
    CHECK(find_accessible(accessible, label) != retained_child, "returning semantic node gets a new lifetime identity"); free(label);
    CHECK(enumerate_accessible(accessible, retained_child), "standard AccessibleChildren enumerates noncontiguous IDs after frame removal/recreation");
  }
  int32_t final_frame = h.frame; h.destroy_on_input = TRUE;
  SendMessageW(h.canvas, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(10, 10));
  CHECK(h.destroyed && !h.canvas && ui_frame_command_count(final_frame, MC_UI_LAYER_COMMANDS) == -1,
      "synchronous callback destruction safely releases the owned frame");
  if (accessible) { LONG count; CHECK(FAILED(IAccessible_get_accChildCount(accessible, &count)), "retained MSAA provider disconnects after destruction"); IAccessible_Release(accessible); }
  h.destroyed = FALSE; h.destroy_on_appearance = TRUE;
  CHECK(!mc_win_canvas_create(parent, instance, 102, &callbacks, &h) && h.destroyed && !h.canvas,
      "initial appearance callback may destroy its HWND safely during create");
cleanup:
  if (IsWindow(parent)) DestroyWindow(parent);
  if (h.ui >= 0) video_ui_close(h.ui); if (h.project >= 0) video_project_close(h.project);
  free(h.snapshot); free(h.frame_json); OleUninitialize();
  printf("Windows shared canvas %s: real v2 commands, pointer cancellation, wheel, drawing/DPI/layers, MSAA, owned lifetime. No media backend claimed.\n", passed && !h.failed ? "passed" : "FAILED");
  return passed && !h.failed ? 0 : 1;
}
