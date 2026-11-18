#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include "platform/windows/graphics/text_input.h"
#include <commctrl.h>
#include <imm.h>
/* Own the SDK's dynamic-annotation GUID definitions in this translation unit. */
#include <initguid.h>
#include <oleacc.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef struct Field Field;
struct Field {
  Field *next;
  MCWinTextInputs *owner;
  HWND window;
  HFONT font;
  wchar_t *id, *raw;
  int refs, token, version, anchor, focus, marked_start, marked_end, color;
  int composing_start, suppress;
  BOOL composing, known, directed, multiline, seen, dead, focused, pending_surrogate, continuing_ime;
  double font_size, opacity; int font_weight, line_height;
};
struct MCWinTextInputs {
  HWND parent;
  HINSTANCE instance;
  MCWinTextCallbacks callbacks;
  void *context;
  Field *fields;
  IAccPropServices *accessibility;
  HRESULT com;
  int refs;
  BOOL dead;
};
static void group_release(MCWinTextInputs *g) {
  if (--g->refs) return;
  if (g->accessibility) IAccPropServices_Release(g->accessibility);
  if (SUCCEEDED(g->com)) CoUninitialize();
  free(g);
}
static void field_release(Field *f) {
  if (--f->refs) return;
  if (f->font) DeleteObject(f->font);
  free(f->id); free(f->raw); free(f);
}
static wchar_t *copy_string(moonbit_string_t value) {
  int length = Moonbit_array_length(value);
  wchar_t *result = calloc((size_t)length + 1, sizeof(*result));
  if (result) memcpy(result, value, (size_t)length * sizeof(*result));
  moonbit_decref(value); return result;
}
/* EDIT uses CRLF and UTF-16 offsets. Shared fields use LF. Never convert by
 * Unicode scalar count: emoji occupy two units in both coordinate systems. */
static int shared_offset(const wchar_t *native, int offset) {
  int result = 0;
  for (int i = 0; native[i] && i < offset; i++, result++)
    if (native[i] == L'\r' && native[i + 1] == L'\n' && i + 1 < offset) i++;
  return result;
}
static int native_offset(const wchar_t *raw, int offset) {
  int result = 0;
  for (int i = 0; raw[i] && i < offset; i++, result++) if (raw[i] == L'\n') result++;
  return result;
}
static void to_shared_in_place(wchar_t *native) {
  size_t at = 0;
  for (size_t i = 0; native[i]; i++) {
    if (native[i] == L'\r') { native[at++] = L'\n'; if (native[i + 1] == L'\n') i++; }
    else native[at++] = native[i];
  }
  native[at] = 0;
}
static wchar_t *to_native(const wchar_t *raw) {
  size_t n = wcslen(raw); wchar_t *out = calloc(n * 2 + 1, sizeof(*out));
  if (!out) return NULL;
  size_t at = 0;
  for (size_t i = 0; i < n; i++) { if (raw[i] == L'\n') out[at++] = L'\r'; out[at++] = raw[i]; }
  return out;
}
static wchar_t *native_state(Field *f, int *anchor, int *focus) {
  int n = GetWindowTextLengthW(f->window);
  if (n < 0 || n > 65536) return NULL;
  wchar_t *native = calloc((size_t)n + 1, sizeof(*native));
  if (!native) return NULL;
  GetWindowTextW(f->window, native, n + 1);
  DWORD a = 0, b = 0; SendMessageW(f->window, EM_GETSEL, (WPARAM)&a, (LPARAM)&b);
  *anchor = shared_offset(native, (int)a); *focus = shared_offset(native, (int)b);
  to_shared_in_place(native); return native;
}
static BOOL emit(Field *f, int type, int start, int end, const wchar_t *text,
                 int selection, int anchor, int focus) {
  MCWinTextInputs *g = f->owner;
  if (g->dead || f->dead || !g->callbacks.event) return FALSE;
  MCCanvasTextInput input = {0};
  input.type = type; input.token = f->token; input.version = f->version;
  input.start = start; input.end = end; input.selection_kind = selection;
  input.anchor = anchor; input.focus = focus;
  input.id = (const uint16_t *)f->id; input.id_length = wcslen(f->id);
  input.text = (const uint16_t *)(text ? text : L""); input.text_length = text ? wcslen(text) : 0;
  moonbit_string_t json = mc_canvas_text_input_json(&input);
  g->refs++; f->refs++;
  BOOL result = Moonbit_array_length(json) > 0 && g->callbacks.event(g->context, f->window, json);
  moonbit_decref(json); field_release(f); group_release(g); return result;
}
static void restore_native(Field *f) {
  if (f->dead || !f->window || f->composing || f->continuing_ime) return;
  int a = 0, b = 0; wchar_t *observed = native_state(f, &a, &b);
  f->suppress++;
  if (!observed || wcscmp(observed, f->raw)) {
    wchar_t *restored = to_native(f->raw);
    if (restored) { SetWindowTextW(f->window, restored); free(restored); }
  }
  if (f->known && (!observed || a != min(f->anchor, f->focus) || b != max(f->anchor, f->focus)))
    SendMessageW(f->window, EM_SETSEL, (WPARAM)native_offset(f->raw, f->anchor), (LPARAM)native_offset(f->raw, f->focus));
  f->suppress--; free(observed);
}
static BOOL flush_field(Field *f) {
  if (f->dead || f->suppress || f->composing || !f->window) return TRUE;
  if (f->pending_surrogate) return FALSE;
  f->refs++;
  int a = 0, b = 0; wchar_t *raw = native_state(f, &a, &b);
  if (!raw) { field_release(f); return FALSE; }
  BOOL ok = TRUE;
  if (wcscmp(raw, f->raw)) {
    size_t old = wcslen(f->raw), now = wcslen(raw), first = 0, tail = 0;
    while (first < old && first < now && f->raw[first] == raw[first]) first++;
    /* A common UTF-16 prefix/suffix must not bisect a surrogate pair. */
    if (first && first < now && raw[first] >= 0xdc00 && raw[first] <= 0xdfff) first--;
    while (tail < old - first && tail < now - first && f->raw[old - tail - 1] == raw[now - tail - 1]) tail++;
    if (tail && now > tail && raw[now - tail] >= 0xdc00 && raw[now - tail] <= 0xdfff) tail--;
    wchar_t saved = raw[now - tail]; raw[now - tail] = 0;
    ok = emit(f, MC_UI_TEXT_REPLACE, (int)first, (int)(old - tail), raw + first,
              MC_UI_SELECTION_UNDIRECTED, a, b);
    raw[now - tail] = saved;
  } else if (GetFocus() == f->window && (!f->known || f->anchor != a || f->focus != b)) {
    ok = emit(f, MC_UI_TEXT_SELECT, 0, 0, NULL, MC_UI_SELECTION_UNDIRECTED, a, b);
  }
  if (!ok) restore_native(f);
  free(raw); field_release(f); return ok;
}
static void action(Field *f, int kind) {
  MCWinTextInputs *g = f->owner;
  if (g->dead || f->dead || !g->callbacks.action) return;
  g->refs++; f->refs++; g->callbacks.action(g->context, f->window, kind);
  field_release(f); group_release(g);
}
static wchar_t *composition_string(HIMC imc, DWORD key) {
  LONG bytes = ImmGetCompositionStringW(imc, key, NULL, 0);
  if (bytes < 0 || bytes > 65536 || bytes % 2) return NULL;
  wchar_t *text = calloc((size_t)bytes / 2 + 1, sizeof(*text));
  if (text && ImmGetCompositionStringW(imc, key, text, (DWORD)bytes) < 0) { free(text); return NULL; }
  return text;
}
static BOOL cancel_composition(Field *f) {
  BOOL accepted = emit(f, MC_UI_TEXT_COMPOSITION_CANCEL, 0, 0, NULL, 0, 0, 0);
  if (!f->dead && accepted && f->marked_start < 0) f->composing = FALSE;
  return accepted;
}
/* The immutable strings are decoded IMM facts, not edits inferred from field
 * IDs. This path is also usable by a native input provider replaying its
 * already-updated EDIT buffer; all acceptance belongs to the shared owner. */
static BOOL composition_snapshot(Field *f, const wchar_t *confirmed, const wchar_t *pending,
                                 int cursor, BOOL canceled) {
  BOOL accepted = TRUE, continue_pending = TRUE;
  f->continuing_ime = confirmed && pending;
  if (!f->dead && confirmed && f->composing) {
    int a = 0, b = 0; wchar_t *raw = native_state(f, &a, &b); free(raw);
    accepted = emit(f, MC_UI_TEXT_COMPOSITION_COMMIT, 0, 0, confirmed,
        pending ? MC_UI_SELECTION_UNKNOWN : MC_UI_SELECTION_UNDIRECTED,
        pending ? 0 : a, pending ? 0 : b);
    if (!f->dead) {
      if (accepted && f->marked_start < 0) {
        f->composing = FALSE;
        f->composing_start += (int)wcslen(confirmed);
      } else {
        /* The native IME has confirmed its result, but the shared owner can
         * reject it (for example a longer final result than the preedit).
         * Cancel that shared composition before clearing the native gate, and
         * restore its pre-composition draft instead of accepting the preedit. */
        accepted = FALSE; continue_pending = FALSE;
        cancel_composition(f);
      }
    }
  }
  if (!f->dead && pending && continue_pending) {
    if (!f->composing) {
      int at = f->composing_start; f->composing = TRUE;
      if (!emit(f, MC_UI_TEXT_COMPOSITION_START, at, at, NULL, MC_UI_SELECTION_UNDIRECTED, at, at)) f->composing = FALSE;
    }
    if (f->composing) {
      int kind = cursor >= 0 && (size_t)cursor <= wcslen(pending) ? MC_UI_SELECTION_UNDIRECTED : MC_UI_SELECTION_UNKNOWN;
      int at = kind ? f->composing_start + cursor : 0;
      accepted = emit(f, MC_UI_TEXT_COMPOSITION_UPDATE, 0, 0, pending, kind, at, at) && accepted;
    } else accepted = FALSE;
  } else if (!f->dead && canceled && f->composing) accepted = cancel_composition(f) && accepted;
  f->continuing_ime = FALSE;
  if (!f->dead && !continue_pending && pending) {
    /* A result+next-preedit rejection also ends that native next segment. */
    HIMC imc = ImmGetContext(f->window);
    if (imc) { f->suppress++; ImmNotifyIME(imc, NI_COMPOSITIONSTR, CPS_CANCEL, 0); f->suppress--; ImmReleaseContext(f->window, imc); }
  }
  if (!f->dead) restore_native(f);
  if (!f->dead) action(f, MC_TEXT_INPUT_STATE);
  return accepted;
}
static LRESULT CALLBACK field_proc(HWND window, UINT message, WPARAM wp, LPARAM lp,
                                    UINT_PTR identifier, DWORD_PTR data) {
  Field *f = (Field *)data; MCWinTextInputs *g = f->owner;
  (void)identifier;
  g->refs++; f->refs++;
  LRESULT result = 0; BOOL handled = FALSE;
  if (message == WM_NCDESTROY) {
    f->window = NULL; f->dead = TRUE; RemoveWindowSubclass(window, field_proc, 1);
  } else if (!f->multiline && f->line_height > 0 && message == WM_NCCALCSIZE && lp) {
    /* EM_SETRECT applies only to multiline EDIT. Center a single-line native
     * client using the actual selected font, retaining the complete HWND hit
     * rectangle and the system's caret, selection and IME implementation. */
    DefSubclassProc(window, message, wp, lp);
    RECT *client = wp ? &((NCCALCSIZE_PARAMS *)lp)->rgrc[0] : (RECT *)lp;
    int available = client->bottom - client->top;
    if (available > f->line_height) {
      client->top += (available - f->line_height) / 2;
      client->bottom = client->top + f->line_height;
    }
    handled = TRUE;
  } else if (!f->multiline && message == WM_NCHITTEST) {
    RECT bounds; POINT point={(short)LOWORD(lp),(short)HIWORD(lp)};
    if (GetWindowRect(window,&bounds) && PtInRect(&bounds,point)) { result = HTCLIENT; handled = TRUE; }
  } else if (!f->suppress && !f->multiline && message == WM_MOUSEWHEEL && g->callbacks.wheel) {
    handled = g->callbacks.wheel(g->context, window, wp, lp);
  } else if (!f->suppress && message == WM_IME_STARTCOMPOSITION) {
    flush_field(f);
    if (!f->dead) {
      int a = 0, b = 0; wchar_t *raw = native_state(f, &a, &b); free(raw);
      f->composing_start = a; f->composing = TRUE;
      if (!emit(f, MC_UI_TEXT_COMPOSITION_START, a, b, NULL, MC_UI_SELECTION_UNDIRECTED, a, b)) f->composing = FALSE;
    }
  } else if (!f->suppress && message == WM_IME_COMPOSITION) {
    HIMC imc = ImmGetContext(window);
    wchar_t *confirmed = imc && (lp & GCS_RESULTSTR) ? composition_string(imc, GCS_RESULTSTR) : NULL;
    wchar_t *pending = imc && (lp & GCS_COMPSTR) ? composition_string(imc, GCS_COMPSTR) : NULL;
    LONG cursor = imc ? ImmGetCompositionStringW(imc, GCS_CURSORPOS, NULL, 0) : -1;
    if (imc) ImmReleaseContext(window, imc);
    f->suppress++; result = DefSubclassProc(window, message, wp, lp); f->suppress--; handled = TRUE;
    if (!f->dead) mc_win_text_inputs_composition(g, window, confirmed, pending, (int)cursor, !lp);
    free(confirmed); free(pending);
  } else if (!f->suppress && message == WM_IME_ENDCOMPOSITION) {
    f->suppress++; result = DefSubclassProc(window, message, wp, lp); f->suppress--; handled = TRUE;
    if (!f->dead && f->composing) cancel_composition(f);
    if (!f->dead) restore_native(f);
    if (!f->dead) action(f, MC_TEXT_INPUT_STATE);
    if (!f->dead) flush_field(f);
  } else if (!f->suppress && !f->composing && message == WM_CHAR && wp >= 0xd800 && wp <= 0xdbff) {
    f->pending_surrogate = TRUE;
    f->suppress++; result = DefSubclassProc(window, message, wp, lp); f->suppress--; handled = TRUE;
  } else if (!f->suppress && !f->composing && message == WM_CHAR) {
    f->pending_surrogate = FALSE;
  } else if (!f->suppress && !f->composing && message == WM_KEYDOWN) {
    BOOL control = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
    if (!f->multiline && (wp == VK_UP || wp == VK_DOWN) && g->callbacks.key) {
      const wchar_t *name = wp == VK_UP ? L"ArrowUp" : L"ArrowDown";
      MCCanvasInput input = {0}; input.type = MC_UI_INPUT_KEY; input.text = (const uint16_t *)name;
      input.text_length = wcslen(name); input.flags = (control ? MC_UI_INPUT_MOD : 0) |
          ((GetKeyState(VK_SHIFT) & 0x8000) ? MC_UI_INPUT_SHIFT : 0);
      handled = g->callbacks.key(g->context, window, &input);
    } else if (control && (wp == 'Z' || wp == 'Y')) {
      emit(f, wp == 'Y' || (GetKeyState(VK_SHIFT) & 0x8000) ? MC_UI_TEXT_REDO : MC_UI_TEXT_UNDO, 0, 0, NULL, 0, 0, 0);
      handled = TRUE;
    } else if (wp == VK_ESCAPE || (wp == VK_RETURN && (!f->multiline || control))) {
      flush_field(f); if (!f->dead) action(f, wp == VK_ESCAPE ? MC_TEXT_CANCEL : MC_TEXT_ACCEPT); handled = TRUE;
    }
  } else if (!f->suppress && message == WM_UNDO && !f->composing) {
    result = emit(f, MC_UI_TEXT_UNDO, 0, 0, NULL, 0, 0, 0); handled = TRUE;
  }
  BOOL native_edit = FALSE;
  if (!handled && (!f->dead || message == WM_NCDESTROY)) {
    /* A selected-range replacement may notify for deletion and insertion.
     * Observe one completed native operation, so one keystroke/paste is one
     * shared undo step. IME and frame-driven changes have their own gates. */
    native_edit = !g->dead && !f->dead && !f->suppress && !f->composing && !f->continuing_ime &&
      (message == WM_CHAR || message == WM_SETTEXT || message == WM_CUT ||
       message == WM_PASTE || message == WM_CLEAR || message == EM_REPLACESEL);
    if (native_edit) f->suppress++;
    result = DefSubclassProc(window, message, wp, lp);
    if (native_edit) f->suppress--;
  }
  /* Multiline EDIT omits EN_CHANGE for WM_SETTEXT, so flush the completed
   * operation here as well as handling ordinary native change notifications. */
  if (!g->dead && !f->dead && !f->suppress && !f->composing && !f->continuing_ime &&
      (native_edit || message == WM_KEYUP || message == WM_LBUTTONUP || message == WM_MOUSEMOVE || message == EM_SETSEL)) flush_field(f);
  if (!f->dead && !f->suppress && message == WM_SETFOCUS) {
    int a = 0, b = 0; wchar_t *raw = native_state(f, &a, &b); free(raw);
    emit(f, MC_UI_TEXT_SELECT, 0, 0, NULL, f->composing ? MC_UI_SELECTION_UNKNOWN : MC_UI_SELECTION_UNDIRECTED,
        f->composing ? 0 : a, f->composing ? 0 : b);
  }
  if (!f->dead && !f->suppress && message == WM_KILLFOCUS) { flush_field(f); if (!f->dead) action(f, MC_TEXT_BLUR); }
  field_release(f); group_release(g); return result;
}
static Field *find_window(MCWinTextInputs *g, HWND window) {
  for (Field *f = g->fields; f; f = f->next) if (f->window == window) return f;
  return NULL;
}
static LRESULT CALLBACK parent_proc(HWND window, UINT message, WPARAM wp, LPARAM lp,
                                     UINT_PTR identifier, DWORD_PTR data) {
  MCWinTextInputs *g = (MCWinTextInputs *)data; (void)identifier;
  g->refs++; LRESULT result = 0; BOOL handled = FALSE;
  Field *f = message == WM_COMMAND || message == WM_CTLCOLOREDIT ? find_window(g, (HWND)lp) : NULL;
  if (f && message == WM_COMMAND && HIWORD(wp) == EN_CHANGE) { flush_field(f); handled = TRUE; }
  if (f && message == WM_CTLCOLOREDIT) {
    SetTextColor((HDC)wp, RGB((f->color >> 16) & 255, (f->color >> 8) & 255, f->color & 255));
    SetBkMode((HDC)wp, TRANSPARENT);
    HBRUSH brush = g->callbacks.background ? g->callbacks.background(g->context, f->window, (HDC)wp) : NULL;
    result = (LRESULT)(brush ? brush : GetStockObject(HOLLOW_BRUSH)); handled = TRUE;
  }
  if (message == WM_LBUTTONDOWN || message == WM_LBUTTONDBLCLK) {
    POINT point = {(short)LOWORD(lp), (short)HIWORD(lp)};
    for (Field *input = g->fields; input && !handled; input = input->next) {
      if (input->opacity != 0 || !input->window || !IsWindowEnabled(input->window) || !IsWindowVisible(input->window)) continue;
      RECT bounds; GetWindowRect(input->window, &bounds); MapWindowPoints(NULL, window, (POINT *)&bounds, 2);
      if (!PtInRect(&bounds, point)) continue;
      POINT local = {point.x - bounds.left, point.y - bounds.top};
      HRGN region = CreateRectRgn(0, 0, 0, 0);
      int kind = GetWindowRgn(input->window, region);
      BOOL inside = kind == ERROR || PtInRegion(region, local.x, local.y); DeleteObject(region);
      if (!inside) continue;
      HWND target = input->window; input->refs++;
      SetFocus(target);
      if (!g->dead && !input->dead && input->window == target)
        SendMessageW(target, message, wp, MAKELPARAM(local.x, local.y));
      field_release(input); handled = TRUE;
      /* SetFocus/SendMessage may retire the entire list. Even with handled set,
       * a for-loop increment would otherwise dereference the retired node. */
      break;
    }
  }
  if (message == WM_NCDESTROY) { RemoveWindowSubclass(window, parent_proc, (UINT_PTR)g); g->parent = NULL; }
  if (!handled) result = DefSubclassProc(window, message, wp, lp);
  group_release(g); return result;
}
MCWinTextInputs *mc_win_text_inputs_create(HWND parent, HINSTANCE instance,
    const MCWinTextCallbacks *callbacks, void *context) {
  if (!IsWindow(parent) || !instance || !callbacks) return NULL;
  MCWinTextInputs *g = calloc(1, sizeof(*g)); if (!g) return NULL;
  g->parent = parent; g->instance = instance; g->callbacks = *callbacks; g->context = context; g->refs = 1;
  g->com = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  if (SUCCEEDED(g->com)) CoCreateInstance(&CLSID_AccPropServices, NULL, CLSCTX_INPROC_SERVER,
      &IID_IAccPropServices, (void **)&g->accessibility);
  if (!SetWindowSubclass(parent, parent_proc, (UINT_PTR)g, (DWORD_PTR)g)) { group_release(g); return NULL; }
  return g;
}
static void retire(Field *f) {
  f->dead = TRUE;
  if (f->window) DestroyWindow(f->window);
  field_release(f);
}
void mc_win_text_inputs_destroy(MCWinTextInputs *g) {
  if (!g || g->dead) return;
  g->dead = TRUE;
  if (g->parent) RemoveWindowSubclass(g->parent, parent_proc, (UINT_PTR)g);
  while (g->fields) { Field *f = g->fields; g->fields = f->next; retire(f); }
  group_release(g);
}
BOOL mc_win_text_inputs_set_frame(MCWinTextInputs *g, int32_t frame, int x, int y, double scale) {
  if (!g || g->dead || !isfinite(scale) || scale <= 0) return FALSE;
  int count = frame ? ui_frame_field_count(frame) : 0;
  if (count < 0 || count > 64) return FALSE;
  g->refs++;
  for (Field *f = g->fields; f; f = f->next) f->seen = FALSE;
  BOOL ok = TRUE;
  for (int i = 0; i < count && !g->dead; i++) {
    wchar_t *id = copy_string(ui_frame_field_text(frame, i, MC_UI_FIELD_ID));
    wchar_t *raw = copy_string(ui_frame_field_text(frame, i, MC_UI_FIELD_RAW));
    if (!id || !raw) { free(id); free(raw); ok = FALSE; break; }
    int token = ui_frame_field_value(frame, i, MC_UI_FIELD_TOKEN);
    Field *f = g->fields;
    while (f && (f->token != token || wcscmp(f->id, id))) f = f->next;
    BOOL created = !f;
    if (!f) {
      f = calloc(1, sizeof(*f));
      if (!f) { free(id); free(raw); ok = FALSE; break; }
      f->owner = g; f->id = id; id = NULL; f->refs = 1; f->token = token;
      f->multiline = ui_frame_field_value(frame, i, MC_UI_FIELD_MULTILINE) == 1;
      DWORD style = WS_CHILD | WS_TABSTOP | (f->multiline ? ES_MULTILINE | ES_WANTRETURN | ES_AUTOVSCROLL : ES_AUTOHSCROLL);
      f->window = CreateWindowExW(0, L"EDIT", L"", style, 0, 0, 1, 1, g->parent, NULL, g->instance, NULL);
      if (!f->window || !SetWindowSubclass(f->window, field_proc, 1, (DWORD_PTR)f)) {
        if (f->window) DestroyWindow(f->window); field_release(f); free(id); free(raw); ok = FALSE; break;
      }
      f->next = g->fields; g->fields = f;
      SendMessageW(f->window, EM_SETLIMITTEXT, 65536, 0);
      SendMessageW(f->window, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, 0);
    }
    free(id); f->refs++; f->suppress++; f->seen = TRUE;
    BOOL requested_focus = ui_frame_field_value(frame, i, MC_UI_FIELD_FOCUSED) == 1;
    BOOL focus_changed = requested_focus && !f->focused;
    f->focused = requested_focus;
    f->version = ui_frame_field_value(frame, i, MC_UI_FIELD_VERSION);
    f->anchor = ui_frame_field_value(frame, i, MC_UI_FIELD_ANCHOR); f->focus = ui_frame_field_value(frame, i, MC_UI_FIELD_FOCUS);
    f->known = ui_frame_field_value(frame, i, MC_UI_FIELD_SELECTION_KNOWN) == 1;
    f->directed = ui_frame_field_value(frame, i, MC_UI_FIELD_DIRECTION_KNOWN) == 1;
    f->marked_start = ui_frame_field_value(frame, i, MC_UI_FIELD_MARKED_START);
    f->marked_end = ui_frame_field_value(frame, i, MC_UI_FIELD_MARKED_END);
    free(f->raw); f->raw = raw;
    /* A normal ACK/frame refresh must never reset the native IME context. */
    if (!f->composing && !f->continuing_ime) {
      int native_anchor = 0, native_focus = 0;
      wchar_t *observed = native_state(f, &native_anchor, &native_focus);
      BOOL needs_text = !observed || wcscmp(observed, raw);
      free(observed);
      if (needs_text) {
        f->pending_surrogate = FALSE;
        wchar_t *native = to_native(raw); if (native) { SetWindowTextW(f->window, native); free(native); }
        SendMessageW(f->window, EM_EMPTYUNDOBUFFER, 0, 0);
      }
      if (f->known && (needs_text || created || native_anchor != min(f->anchor, f->focus) || native_focus != max(f->anchor, f->focus)))
        SendMessageW(f->window, EM_SETSEL, (WPARAM)native_offset(raw, f->anchor), (LPARAM)native_offset(raw, f->focus));
    }
    f->color = ui_frame_field_value(frame, i, MC_UI_FIELD_COLOR);
    int px = x + (int)lround(ui_frame_field_number(frame, i, MC_UI_FIELD_X) * scale);
    int py = y + (int)lround(ui_frame_field_number(frame, i, MC_UI_FIELD_Y) * scale);
    int width = max(1, (int)lround(ui_frame_field_number(frame, i, MC_UI_FIELD_WIDTH) * scale));
    int height = max(1, (int)lround(ui_frame_field_number(frame, i, MC_UI_FIELD_HEIGHT) * scale));
    double size = ui_frame_field_number(frame, i, MC_UI_FIELD_FONT_SIZE) * scale;
    int shared_weight = ui_frame_field_value(frame, i, MC_UI_FIELD_WEIGHT);
    int weight = shared_weight == MC_UI_WEIGHT_SEMIBOLD ? FW_SEMIBOLD : shared_weight == MC_UI_WEIGHT_BOLD ? FW_BOLD :
      shared_weight == MC_UI_WEIGHT_MEDIUM ? FW_MEDIUM : FW_NORMAL;
    if (!f->font || size != f->font_size || weight != f->font_weight) {
      HFONT font = CreateFontW(-(int)lround(size), 0, 0, 0, weight,
          FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
          ANTIALIASED_QUALITY, DEFAULT_PITCH, L"Segoe UI");
      if (font) { SendMessageW(f->window, WM_SETFONT, (WPARAM)font, TRUE); if (f->font) DeleteObject(f->font); f->font = font; f->font_size = size; f->font_weight = weight; }
    }
    if (!f->multiline && f->font) {
      HDC dc = GetDC(f->window);
      if (dc) {
        HGDIOBJ previous = SelectObject(dc, f->font); TEXTMETRICW metrics = {0};
        if (GetTextMetricsW(dc, &metrics)) f->line_height = (int)metrics.tmHeight;
        SelectObject(dc, previous); ReleaseDC(f->window, dc);
      }
    }
    SetWindowPos(f->window, NULL, px, py, width, height, SWP_NOACTIVATE | SWP_NOZORDER |
        (f->multiline ? 0 : SWP_FRAMECHANGED));
    int clip_x = x + (int)lround(ui_frame_field_number(frame, i, MC_UI_FIELD_CLIP_X) * scale) - px;
    int clip_y = y + (int)lround(ui_frame_field_number(frame, i, MC_UI_FIELD_CLIP_Y) * scale) - py;
    int clip_w = (int)lround(ui_frame_field_number(frame, i, MC_UI_FIELD_CLIP_WIDTH) * scale);
    int clip_h = (int)lround(ui_frame_field_number(frame, i, MC_UI_FIELD_CLIP_HEIGHT) * scale);
    HRGN clip = CreateRectRgn(max(0, clip_x), max(0, clip_y), min(width, clip_x + clip_w), min(height, clip_y + clip_h));
    SetWindowRgn(f->window, clip, TRUE);
    f->opacity = ui_frame_field_number(frame, i, MC_UI_FIELD_OPACITY);
    LONG_PTR extended = GetWindowLongPtrW(f->window, GWL_EXSTYLE);
    if (f->opacity < 1) {
      if (!(extended & WS_EX_LAYERED)) SetWindowLongPtrW(f->window, GWL_EXSTYLE, extended | WS_EX_LAYERED);
      SetLayeredWindowAttributes(f->window, 0, (BYTE)lround(f->opacity * 255), LWA_ALPHA);
    } else if (extended & WS_EX_LAYERED) SetWindowLongPtrW(f->window, GWL_EXSTYLE, extended & ~WS_EX_LAYERED);
    SendMessageW(f->window, EM_SETREADONLY, ui_frame_field_value(frame, i, MC_UI_FIELD_READ_ONLY) == 1, 0);
    EnableWindow(f->window, ui_frame_field_value(frame, i, MC_UI_FIELD_ENABLED) == 1);
    if (g->accessibility) {
      wchar_t *label = copy_string(ui_frame_field_text(frame, i, MC_UI_FIELD_LABEL));
      if (label) { IAccPropServices_SetHwndPropStr(g->accessibility, f->window, (DWORD)OBJID_CLIENT, CHILDID_SELF, PROPID_ACC_NAME, label); free(label); }
    }
    ShowWindow(f->window, SW_SHOWNOACTIVATE);
    if (focus_changed && !f->dead && IsWindowEnabled(f->window) && GetFocus() != f->window && !f->composing && !f->continuing_ime) SetFocus(f->window);
    f->suppress--; field_release(f);
  }
  Field **at = &g->fields;
  while (*at) { Field *f = *at; if (!f->seen) { *at = f->next; retire(f); } else at = &f->next; }
  group_release(g); return ok;
}
HWND mc_win_text_inputs_field(MCWinTextInputs *g, const wchar_t *id) {
  if (!g || g->dead) return NULL;
  for (Field *f = g->fields; f; f = f->next) if (!wcscmp(f->id, id)) return f->window;
  return NULL;
}
BOOL mc_win_text_inputs_contains(MCWinTextInputs *g, HWND window) { return g && !g->dead && find_window(g, window) != NULL; }
BOOL mc_win_text_inputs_composing(MCWinTextInputs *g) {
  if (g && !g->dead) for (Field *f = g->fields; f; f = f->next) if (f->composing) return TRUE;
  return FALSE;
}
BOOL mc_win_text_inputs_history(MCWinTextInputs *g, HWND window, BOOL redo) {
  Field *f = g && !g->dead ? find_window(g, window) : NULL;
  return f && !f->composing && emit(f, redo ? MC_UI_TEXT_REDO : MC_UI_TEXT_UNDO, 0, 0, NULL, 0, 0, 0);
}
BOOL mc_win_text_inputs_composition(MCWinTextInputs *g, HWND window,
    const wchar_t *result, const wchar_t *preedit, int cursor, BOOL canceled) {
  Field *f = g && !g->dead ? find_window(g, window) : NULL;
  if (!f) return FALSE;
  wchar_t *confirmed = result ? _wcsdup(result) : NULL;
  wchar_t *pending = preedit ? _wcsdup(preedit) : NULL;
  if ((result && !confirmed) || (preedit && !pending)) { free(confirmed); free(pending); return FALSE; }
  if (pending) { if (cursor >= 0) cursor = shared_offset(pending, cursor); to_shared_in_place(pending); }
  if (confirmed) to_shared_in_place(confirmed);
  g->refs++; f->refs++;
  BOOL accepted = composition_snapshot(f, confirmed, pending, cursor, canceled);
  free(confirmed); free(pending); field_release(f); group_release(g); return accepted;
}
BOOL mc_win_text_inputs_flush(MCWinTextInputs *g) {
  if (!g || g->dead) return TRUE;
  g->refs++; BOOL ok = TRUE;
  /* Each callback may replace this list. Restart from current identities and
   * only flush the focused control; EN_CHANGE already synchronizes the rest. */
  Field *f = find_window(g, GetFocus());
  if (f) ok = flush_field(f);
  group_release(g); return ok;
}
