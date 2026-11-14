#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include "pinning.h"
#include <commctrl.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <windowsx.h>

typedef struct Pin {
  HWND window;
  HGLOBAL dib;
  int width, height;
  double zoom;
  BYTE opacity;
  BOOL selected, hidden, passthrough;
  struct Pin *next;
} Pin;
static Pin *pins;
static WORD keys[6] = {VK_OEM_PLUS,
                       VK_OEM_MINUS,
                       MAKEWORD(VK_OEM_PLUS, HOTKEYF_CONTROL),
                       MAKEWORD(VK_OEM_MINUS, HOTKEYF_CONTROL),
                       MAKEWORD('H', HOTKEYF_CONTROL | HOTKEYF_SHIFT),
                       MAKEWORD('P', HOTKEYF_CONTROL | HOTKEYF_SHIFT)};
static WORD capture_keys[3];
static HWND hotkey_host;
static BOOL global_registered[2], capture_hidden, shortcuts_suspended;
static BOOL refresh_pin_hotkeys(void);
static void toggle_hidden(void);
static BOOL toggle_passthrough(Pin *pin);
static Pin *selected_pin(void) {
  // Recovery always targets the pass-through pin, even if a native activation
  // event from another window temporarily reports a competing selection.
  for (Pin *pin = pins; pin; pin = pin->next)
    if (pin->passthrough)
      return pin;
  for (Pin *pin = pins; pin; pin = pin->next)
    if (pin->selected)
      return pin;
  return NULL;
}
static BOOL has_passthrough(void) {
  for (Pin *pin = pins; pin; pin = pin->next)
    if (pin->passthrough)
      return TRUE;
  return FALSE;
}
static void show_pin(Pin *pin) {
  ShowWindow(pin->window, capture_hidden || pin->hidden ? SW_HIDE : SW_SHOWNOACTIVATE);
}
BOOL mc_pin_capture_conflicts(const WORD proposed[3]) {
  for (int i = 0; i < 3; i++)
    for (int j = 4; j < 6; j++)
      if (LOBYTE(proposed[i]) && proposed[i] == keys[j])
        return TRUE;
  return FALSE;
}
void mc_pin_set_capture_keys(const WORD proposed[3]) { memcpy(capture_keys, proposed, sizeof(capture_keys)); }

static WORD normalize(WORD key) {
  BYTE vk = LOBYTE(key), mod = HIBYTE(key) & (HOTKEYF_CONTROL | HOTKEYF_ALT | HOTKEYF_SHIFT);
  if (vk == VK_ADD || vk == VK_OEM_PLUS) {
    vk = VK_OEM_PLUS;
    mod &= ~HOTKEYF_SHIFT;
  }
  if (vk == VK_SUBTRACT)
    vk = VK_OEM_MINUS;
  return MAKEWORD(vk, mod);
}
void mc_pin_default_keys(WORD out[6]) {
  out[0] = VK_OEM_PLUS;
  out[1] = VK_OEM_MINUS;
  out[2] = MAKEWORD(VK_OEM_PLUS, HOTKEYF_CONTROL);
  out[3] = MAKEWORD(VK_OEM_MINUS, HOTKEYF_CONTROL);
  out[4] = MAKEWORD('H', HOTKEYF_CONTROL | HOTKEYF_SHIFT);
  out[5] = MAKEWORD('P', HOTKEYF_CONTROL | HOTKEYF_SHIFT);
}
static BOOL valid(const WORD proposed[6]) {
  for (int i = 0; i < 6; i++) {
    BYTE vk = LOBYTE(proposed[i]);
    if (vk == VK_ESCAPE || vk == VK_DELETE || vk == VK_TAB || vk == VK_RETURN || vk == VK_CONTROL ||
        vk == VK_SHIFT || vk == VK_MENU)
      return FALSE;
    if (i >= 4) {
      if (!vk || !(HIBYTE(proposed[i]) & (HOTKEYF_CONTROL | HOTKEYF_ALT)))
        return FALSE;
      for (int c = 0; c < 3; c++)
        if (normalize(proposed[i]) == normalize(capture_keys[c]))
          return FALSE;
    }
    if (normalize(proposed[i]) == MAKEWORD('C', HOTKEYF_CONTROL))
      return FALSE;
    if (HIBYTE(proposed[i]) & ~(HOTKEYF_CONTROL | HOTKEYF_ALT | HOTKEYF_SHIFT | HOTKEYF_EXT))
      return FALSE;
    for (int j = 0; j < i; j++)
      if (vk && normalize(proposed[i]) == normalize(proposed[j]))
        return FALSE;
  }
  return TRUE;
}
WORD mc_pin_key(int action) { return action >= 0 && action < 6 ? keys[action] : 0; }
void mc_pin_load_keys(const wchar_t *path) {
  WORD stored[6];
  DWORD size = sizeof(stored);
  mc_pin_default_keys(keys);
  if (RegGetValueW(HKEY_CURRENT_USER, path, L"PinShortcutsV2", RRF_RT_REG_BINARY, NULL, stored, &size) ==
          ERROR_SUCCESS &&
      size == sizeof(stored) && valid(stored))
    memcpy(keys, stored, sizeof(keys));
  else {
    size = sizeof(WORD) * 4;
    memcpy(stored, keys, sizeof(keys));
    if (RegGetValueW(HKEY_CURRENT_USER, path, L"PinShortcutsV1", RRF_RT_REG_BINARY, NULL, stored, &size) ==
            ERROR_SUCCESS &&
        size == sizeof(WORD) * 4 && valid(stored))
      memcpy(keys, stored, sizeof(keys));
  }
}
/* While a recorder owns focus, verify both proposed global combinations using
 * inert temporary IDs. Never enable the live pin actions during key recording. */
static BOOL preflight_suspended_keys(const WORD proposed[6]) {
  if (!hotkey_host)
    refresh_pin_hotkeys();
  if (!hotkey_host)
    return FALSE;
  BOOL registered[2] = {FALSE, FALSE};
  for (int i = 0; i < 2; i++) {
    BYTE flags = HIBYTE(proposed[4 + i]);
    UINT modifiers = MOD_NOREPEAT | ((flags & HOTKEYF_CONTROL) ? MOD_CONTROL : 0) |
                     ((flags & HOTKEYF_ALT) ? MOD_ALT : 0) | ((flags & HOTKEYF_SHIFT) ? MOD_SHIFT : 0);
    registered[i] = RegisterHotKey(hotkey_host, 0x7b01 + i, modifiers, LOBYTE(proposed[4 + i]));
  }
  for (int i = 0; i < 2; i++)
    if (registered[i])
      UnregisterHotKey(hotkey_host, 0x7b01 + i);
  return registered[0] && registered[1];
}
BOOL mc_pin_save_keys(const wchar_t *path, const WORD proposed[6]) {
  if (!valid(proposed) || has_passthrough())
    return FALSE;
  if ((shortcuts_suspended || !pins) && !preflight_suspended_keys(proposed))
    return FALSE;
  WORD previous[6];
  memcpy(previous, keys, sizeof(keys));
  memcpy(keys, proposed, sizeof(keys));
  if (pins && !refresh_pin_hotkeys()) {
    memcpy(keys, previous, sizeof(keys));
    refresh_pin_hotkeys();
    return FALSE;
  }
  HKEY key;
  LONG result = RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL);
  if (result == ERROR_SUCCESS) {
    result = RegSetValueExW(key, L"PinShortcutsV2", 0, REG_BINARY, (const BYTE *)proposed, sizeof(keys));
    RegCloseKey(key);
  }
  if (result != ERROR_SUCCESS) {
    memcpy(keys, previous, sizeof(keys));
    refresh_pin_hotkeys();
    return FALSE;
  }
  return TRUE;
}
static LRESULT CALLBACK hotkey_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_HOTKEY) {
    if (capture_hidden)
      return 0;
    if (wp == 0x7a01)
      toggle_hidden();
    else if (wp == 0x7a02) {
      Pin *pin = selected_pin();
      if (pin)
        toggle_passthrough(pin);
    }
    return 0;
  }
  return DefWindowProcW(window, message, wp, lp);
}
static BOOL refresh_pin_hotkeys(void) {
  if (has_passthrough())
    return global_registered[0] && global_registered[1];
  if (!hotkey_host) {
    WNDCLASSEXW klass = {sizeof(klass)};
    klass.hInstance = GetModuleHandleW(NULL);
    klass.lpfnWndProc = hotkey_proc;
    klass.lpszClassName = L"MoojiCut.Pin.Keys";
    RegisterClassExW(&klass);
    hotkey_host = CreateWindowExW(0, klass.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL,
                                  klass.hInstance, NULL);
  }
  if (!hotkey_host)
    return FALSE;
  for (int i = 0; i < 2; i++) {
    if (global_registered[i])
      UnregisterHotKey(hotkey_host, 0x7a01 + i);
    global_registered[i] = FALSE;
  }
  if (!pins || shortcuts_suspended)
    return TRUE;
  for (int i = 0; i < 2; i++) {
    BYTE flags = HIBYTE(keys[4 + i]);
    UINT mods = MOD_NOREPEAT | ((flags & HOTKEYF_CONTROL) ? MOD_CONTROL : 0) |
                ((flags & HOTKEYF_ALT) ? MOD_ALT : 0) | ((flags & HOTKEYF_SHIFT) ? MOD_SHIFT : 0);
    global_registered[i] = RegisterHotKey(hotkey_host, 0x7a01 + i, mods, LOBYTE(keys[4 + i]));
  }
  return global_registered[0] && global_registered[1];
}
void mc_pin_suspend_shortcuts(BOOL suspended) {
  if (suspended)
    for (Pin *pin = pins; pin; pin = pin->next)
      if (pin->passthrough)
        toggle_passthrough(pin);
  shortcuts_suspended = suspended;
  refresh_pin_hotkeys();
}
static void toggle_hidden(void) {
  if (!global_registered[0])
    refresh_pin_hotkeys();
  if (!global_registered[0])
    return;
  Pin *selected = selected_pin();
  if (selected && selected->passthrough)
    return;
  if (selected) {
    selected->hidden = !selected->hidden;
    selected->selected = FALSE;
    show_pin(selected);
    return;
  }
  BOOL restore = FALSE;
  for (Pin *pin = pins; pin; pin = pin->next)
    if (pin->hidden)
      restore = TRUE;
  for (Pin *pin = pins; pin; pin = pin->next) {
    if (restore) {
      if (pin->hidden)
        pin->hidden = FALSE;
    } else
      pin->hidden = TRUE;
    show_pin(pin);
  }
}
static BOOL toggle_passthrough(Pin *pin) {
  if (!pin)
    return FALSE;
  if (!pin->passthrough && !global_registered[1])
    refresh_pin_hotkeys();
  if (!pin->passthrough && !global_registered[1])
    return FALSE;
  pin->passthrough = !pin->passthrough;
  pin->selected = TRUE;
  LONG_PTR style = GetWindowLongPtrW(pin->window, GWL_EXSTYLE);
  if (pin->passthrough)
    style |= WS_EX_TRANSPARENT | WS_EX_NOACTIVATE;
  else
    style &= ~(WS_EX_TRANSPARENT | WS_EX_NOACTIVATE);
  SetWindowLongPtrW(pin->window, GWL_EXSTYLE, style);
  SetWindowPos(pin->window, NULL, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  InvalidateRect(pin->window, NULL, FALSE);
  return TRUE;
}
static void resize_pin(Pin *pin, double zoom) {
  RECT rect;
  MONITORINFO monitor = {sizeof(monitor)};
  GetWindowRect(pin->window, &rect);
  GetMonitorInfoW(MonitorFromWindow(pin->window, MONITOR_DEFAULTTONEAREST), &monitor);
  double maximum = fmin(8.0, fmin((double)(monitor.rcWork.right - monitor.rcWork.left) / pin->width,
                                  (double)(monitor.rcWork.bottom - monitor.rcWork.top) / pin->height));
  pin->zoom = fmax(fmin(.1, maximum), fmin(maximum, zoom));
  int w = (int)fmax(1, round(pin->width * pin->zoom)), h = (int)fmax(1, round(pin->height * pin->zoom));
  int x = (rect.left + rect.right - w) / 2, y = (rect.top + rect.bottom - h) / 2;
  x = (int)fmax(monitor.rcWork.left, fmin(monitor.rcWork.right - w, x));
  y = (int)fmax(monitor.rcWork.top, fmin(monitor.rcWork.bottom - h, y));
  SetWindowPos(pin->window, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE);
  InvalidateRect(pin->window, NULL, FALSE);
}
static void pin_action(Pin *pin, int action) {
  if (action < 2)
    resize_pin(pin, pin->zoom * (action == 0 ? 1.1 : 1 / 1.1));
  else {
    int alpha = pin->opacity + (action == 2 ? 26 : -26);
    pin->opacity = (BYTE)(alpha < 26 ? 26 : alpha > 255 ? 255 : alpha);
    SetLayeredWindowAttributes(pin->window, 0, pin->opacity, LWA_ALPHA);
  }
}
static BOOL copy_pin(Pin *pin) {
  SIZE_T size = GlobalSize(pin->dib);
  HGLOBAL copy = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!copy)
    return FALSE;
  void *src = GlobalLock(pin->dib), *dst = GlobalLock(copy);
  if (!src || !dst) {
    if (src)
      GlobalUnlock(pin->dib);
    if (dst)
      GlobalUnlock(copy);
    GlobalFree(copy);
    return FALSE;
  }
  memcpy(dst, src, size);
  GlobalUnlock(pin->dib);
  GlobalUnlock(copy);
  BOOL ok = FALSE;
  if (OpenClipboard(pin->window)) {
    if (EmptyClipboard() && SetClipboardData(CF_DIB, copy)) {
      copy = NULL;
      ok = TRUE;
    }
    CloseClipboard();
  }
  if (copy)
    GlobalFree(copy);
  return ok;
}
static LRESULT CALLBACK pin_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  Pin *pin = (Pin *)GetWindowLongPtrW(window, GWLP_USERDATA);
  if (message == WM_NCCREATE) {
    pin = (Pin *)((CREATESTRUCTW *)lp)->lpCreateParams;
    pin->window = window;
    SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)pin);
  }
  if (!pin)
    return DefWindowProcW(window, message, wp, lp);
  if (pin->passthrough) {
    if (message == WM_NCHITTEST)
      return HTTRANSPARENT;
    if (message == WM_MOUSEACTIVATE)
      return MA_NOACTIVATE;
    if (message == WM_ACTIVATE) {
      pin->selected = TRUE;
      return 0;
    }
    if ((message >= WM_MOUSEFIRST && message <= WM_MOUSELAST) || message == WM_CONTEXTMENU ||
        message == WM_KEYDOWN || message == WM_SYSKEYDOWN || message == WM_CLOSE ||
        message == WM_NCLBUTTONDOWN || message == WM_NCLBUTTONDBLCLK || message == WM_SYSCOMMAND)
      return 0;
  }
  switch (message) {
  case WM_ERASEBKGND:
    return 1;
  case WM_PAINT: {
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(window, &ps);
    RECT rect;
    GetClientRect(window, &rect);
    BITMAPINFOHEADER *header = GlobalLock(pin->dib);
    if (header) {
      SetStretchBltMode(dc, HALFTONE);
      SetBrushOrgEx(dc, 0, 0, NULL);
      StretchDIBits(dc, 0, 0, rect.right, rect.bottom, 0, 0, pin->width, pin->height, header + 1,
                    (BITMAPINFO *)header, DIB_RGB_COLORS, SRCCOPY);
      GlobalUnlock(pin->dib);
    }
    if (pin->selected) {
      HBRUSH brush = CreateSolidBrush(RGB(194, 191, 186));
      FrameRect(dc, &rect, brush);
      DeleteObject(brush);
    }
    EndPaint(window, &ps);
    return 0;
  }
  case WM_LBUTTONDBLCLK:
    DestroyWindow(window);
    return 0;
  case WM_NCLBUTTONDBLCLK:
    DestroyWindow(window);
    return 0;
  case WM_LBUTTONDOWN:
    if (has_passthrough())
      return 0;
    for (Pin *other = pins; other; other = other->next)
      other->selected = FALSE;
    SetForegroundWindow(window);
    SetFocus(window);
    pin->selected = TRUE;
    InvalidateRect(window, NULL, FALSE);
    ReleaseCapture();
    POINT pointer;
    GetCursorPos(&pointer);
    SendMessageW(window, WM_NCLBUTTONDOWN, HTCAPTION, MAKELPARAM(pointer.x, pointer.y));
    return 0;
  case WM_ACTIVATE:
    pin->selected = !has_passthrough() && LOWORD(wp) != WA_INACTIVE;
    InvalidateRect(window, NULL, FALSE);
    return 0;
  case WM_KEYDOWN:
  case WM_SYSKEYDOWN: {
    if (wp == VK_ESCAPE) {
      if (pin->selected)
        DestroyWindow(window);
      return 0;
    }
    if (!pin->selected)
      return 0;
    if (wp == VK_DELETE) {
      DestroyWindow(window);
      return 0;
    }
    if (wp == 'C' && (GetKeyState(VK_CONTROL) & 0x8000)) {
      copy_pin(pin);
      return 0;
    }
    BYTE mod = (GetKeyState(VK_CONTROL) & 0x8000 ? HOTKEYF_CONTROL : 0) |
               ((GetKeyState(VK_MENU) & 0x8000) || (message == WM_SYSKEYDOWN && (lp & ((LPARAM)1 << 29)))
                    ? HOTKEYF_ALT
                    : 0) |
               (GetKeyState(VK_SHIFT) & 0x8000 ? HOTKEYF_SHIFT : 0);
    WORD pressed = normalize(MAKEWORD((BYTE)wp, mod));
    for (int i = 0; i < 6; i++)
      if (LOBYTE(keys[i]) && pressed == normalize(keys[i])) {
        if (i < 4)
          pin_action(pin, i);
        else if (i == 4)
          toggle_hidden();
        else if (!toggle_passthrough(pin))
          MessageBoxW(window, L"鼠标穿透快捷键被占用，请在设置中更换后重试。", L"Mooji Cut",
                      MB_OK | MB_ICONWARNING);
        return 0;
      }
    return message == WM_SYSKEYDOWN ? DefWindowProcW(window, message, wp, lp) : 0;
  }
  case WM_CONTEXTMENU: {
    HMENU menu = CreatePopupMenu();
    POINT p;
    GetCursorPos(&p);
    AppendMenuW(menu, MF_STRING, 1, L"复制原图");
    AppendMenuW(menu, MF_STRING, 2, L"恢复大小和透明度");
    AppendMenuW(menu, MF_STRING, 3, L"关闭贴图");
    int action = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, p.x, p.y, 0, window, NULL);
    DestroyMenu(menu);
    if (action == 1)
      copy_pin(pin);
    else if (action == 2) {
      pin->opacity = 255;
      SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA);
      resize_pin(pin, 1);
    } else if (action == 3)
      DestroyWindow(window);
    return 0;
  }
  case WM_DISPLAYCHANGE:
    resize_pin(pin, pin->zoom);
    return 0;
  case WM_CLOSE:
    DestroyWindow(window);
    return 0;
  case WM_NCDESTROY: {
    Pin **link = &pins;
    while (*link && *link != pin)
      link = &(*link)->next;
    if (*link)
      *link = pin->next;
    GlobalFree(pin->dib);
    free(pin);
    if (!pins)
      refresh_pin_hotkeys();
    SetWindowLongPtrW(window, GWLP_USERDATA, 0);
    break;
  }
  }
  return DefWindowProcW(window, message, wp, lp);
}
BOOL mc_pin_image(HINSTANCE instance, HGLOBAL dib, int x, int y, BOOL hidden) {
  if (!dib)
    return FALSE;
  BITMAPINFOHEADER *h = GlobalLock(dib);
  if (!h)
    return FALSE;
  int w = h->biWidth, height = abs(h->biHeight);
  GlobalUnlock(dib);
  if (w <= 0 || height <= 0)
    return FALSE;
  WNDCLASSEXW klass = {sizeof(klass)};
  klass.hInstance = instance;
  klass.style = CS_DBLCLKS;
  klass.lpszClassName = L"MoojiCut.Pin";
  klass.lpfnWndProc = pin_proc;
  klass.hCursor = LoadCursorW(NULL, IDC_ARROW);
  if (!RegisterClassExW(&klass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
    return FALSE;
  Pin *pin = calloc(1, sizeof(*pin));
  if (!pin)
    return FALSE;
  pin->width = w;
  pin->height = height;
  pin->zoom = 1;
  pin->opacity = 255;
  HWND window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED, klass.lpszClassName,
                                L"Mooji Cut · 贴图", WS_POPUP, x, y, w, height, NULL, NULL, instance, pin);
  if (!window)
    return FALSE;
  pin->dib = dib;
  pin->next = pins;
  pins = pin;
  SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA);
  refresh_pin_hotkeys();
  if (!hidden) {
    ShowWindow(window, SW_SHOWNOACTIVATE);
    SetForegroundWindow(window);
    SetFocus(window);
    pin->selected = TRUE;
  }
  return TRUE;
}
void mc_pins_hide(BOOL hidden) {
  capture_hidden = hidden;
  for (Pin *pin = pins; pin; pin = pin->next)
    show_pin(pin);
}
void mc_pins_close(void) {
  for (Pin *pin = pins; pin;) {
    Pin *next = pin->next;
    if (!pin->passthrough)
      DestroyWindow(pin->window);
    pin = next;
  }
}
void mc_pins_shutdown(void) {
  while (pins)
    DestroyWindow(pins->window);
}
void mc_pins_restore_hidden(void) {
  for (Pin *pin = pins; pin; pin = pin->next)
    if (!pin->passthrough && pin->hidden) {
      pin->hidden = FALSE;
      show_pin(pin);
    }
}
void mc_pins_exit_passthrough(void) {
  for (Pin *pin = pins; pin; pin = pin->next)
    if (pin->passthrough)
      toggle_passthrough(pin);
}
static HGLOBAL clone_dib(HGLOBAL original) {
  SIZE_T size = GlobalSize(original);
  HGLOBAL copy = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!copy)
    return NULL;
  void *src = GlobalLock(original), *dst = GlobalLock(copy);
  if (src && dst)
    memcpy(dst, src, size);
  BOOL ok = src && dst;
  if (src)
    GlobalUnlock(original);
  if (dst)
    GlobalUnlock(copy);
  if (!ok) {
    GlobalFree(copy);
    return NULL;
  }
  return copy;
}
BOOL mc_pin_smoke(HINSTANCE instance) {
  HGLOBAL dib = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(BITMAPINFOHEADER) + 320 * 200 * 3);
  if (!dib)
    return FALSE;
  BITMAPINFOHEADER *h = GlobalLock(dib);
  h->biSize = sizeof(*h);
  h->biWidth = 320;
  h->biHeight = 200;
  h->biPlanes = 1;
  h->biBitCount = 24;
  GlobalUnlock(dib);
  if (!mc_pin_image(instance, dib, 20, 20, TRUE)) {
    GlobalFree(dib);
    return FALSE;
  }
  Pin *pin = pins;
  RECT anchored;
  GetWindowRect(pin->window, &anchored);
  if (anchored.left != 20 || anchored.top != 20 || anchored.right != 340 || anchored.bottom != 220) {
    DestroyWindow(pin->window);
    return FALSE;
  }
  resize_pin(pin, .5);
  RECT rect;
  GetWindowRect(pin->window, &rect);
  BOOL ok = rect.right - rect.left == 160 && rect.bottom - rect.top == 100;
  WORD saved[6];
  memcpy(saved, keys, sizeof(keys));
  keys[0] = MAKEWORD(VK_F8, HOTKEYF_ALT);
  pin->selected = TRUE;
  SendMessageW(pin->window, WM_SYSKEYDOWN, VK_F8, (LPARAM)1 << 29);
  ok = ok && pin->zoom > .5;
  memcpy(keys, saved, sizeof(keys));

  for (int i = 0; i < 100; i++)
    resize_pin(pin, pin->zoom * 1.1);
  ok = ok && pin->zoom <= 8;
  for (int i = 0; i < 20; i++)
    pin_action(pin, 3);
  ok = ok && pin->opacity == 26;
  for (int i = 0; i < 20; i++)
    pin_action(pin, 2);
  ok = ok && pin->opacity == 255;
  h = GlobalLock(pin->dib);
  ok = ok && h && h->biWidth == 320 && h->biHeight == 200;
  if (h)
    GlobalUnlock(pin->dib);
  WORD duplicate[6];
  mc_pin_default_keys(duplicate);
  duplicate[0] = VK_OEM_PLUS;
  duplicate[1] = VK_ADD;
  ok = ok && !valid(duplicate) && normalize(MAKEWORD(VK_OEM_PLUS, HOTKEYF_SHIFT)) == VK_OEM_PLUS;
  // Use uncommon temporary combinations; real registration is required before pass-through.
  WORD configured[6];
  memcpy(configured, keys, sizeof(keys));
  keys[4] = MAKEWORD(VK_F22, HOTKEYF_CONTROL | HOTKEYF_ALT | HOTKEYF_SHIFT);
  keys[5] = MAKEWORD(VK_F23, HOTKEYF_CONTROL | HOTKEYF_ALT | HOTKEYF_SHIFT);
  refresh_pin_hotkeys();
  pin->opacity = 137;
  SetLayeredWindowAttributes(pin->window, 0, 137, LWA_ALPHA);
  pin->selected = TRUE;
  toggle_hidden();
  ok = ok && pin->hidden && !pin->selected && pin->opacity == 137;
  toggle_hidden();
  ok = ok && !pin->hidden && pin->opacity == 137;
  pin->selected = TRUE;
  ok = ok && toggle_passthrough(pin) && pin->passthrough && pin->selected;
  HWND live = pin->window;
  SendMessageW(live, WM_ACTIVATE, WA_INACTIVE, 0);
  SendMessageW(live, WM_KEYDOWN, VK_ESCAPE, 0);
  SendMessageW(live, WM_LBUTTONDBLCLK, 0, 0);
  SendMessageW(live, WM_CLOSE, 0, 0);
  toggle_hidden();
  ok = ok && IsWindow(live) && pin->passthrough && pin->selected && !pin->hidden && pin->opacity == 137;
  // A competing pin must never take over the global recovery key.
  HGLOBAL extra = clone_dib(pin->dib);
  if (!extra || !mc_pin_image(instance, extra, 60, 70, TRUE)) {
    if (extra)
      GlobalFree(extra);
    mc_pins_shutdown();
    return FALSE;
  }
  Pin *other = pins;
  HWND other_window = other->window;
  SendMessageW(other_window, WM_ACTIVATE, WA_ACTIVE, 0);
  ok = ok && !other->selected && pin->selected;
  other->selected = TRUE; // Also defend against a queued/stale activation state.
  SendMessageW(hotkey_host, WM_HOTKEY, 0x7a02, 0);
  ok = ok && !pin->passthrough && !other->passthrough;
  other->selected = FALSE;
  pin->selected = TRUE;
  ok = ok && toggle_passthrough(pin);
  // Explicit tray recovery skips protected pins; close-all cannot destroy them.
  pin->hidden = TRUE;
  other->hidden = TRUE;
  mc_pins_restore_hidden();
  ok = ok && pin->hidden && !other->hidden && pin->opacity == 137;
  pin->hidden = FALSE;
  mc_pins_close();
  ok = ok && IsWindow(live) && !IsWindow(other_window) && pin->passthrough;
  mc_pins_exit_passthrough();
  ok = ok && !pin->passthrough && !(GetWindowLongPtrW(live, GWL_EXSTYLE) & WS_EX_TRANSPARENT);
  WORD conflict[6];
  memcpy(conflict, keys, sizeof(keys));
  conflict[4] = capture_keys[0];
  ok = ok && !valid(conflict);
  if (global_registered[1]) {
    UnregisterHotKey(hotkey_host, 0x7a02);
    global_registered[1] = FALSE;
  }
  BOOL occupied = RegisterHotKey(hotkey_host, 0x7aff, MOD_CONTROL | MOD_ALT | MOD_SHIFT, VK_F23);
  if (occupied) {
    ok = ok && !toggle_passthrough(pin) && !pin->passthrough;
    UnregisterHotKey(hotkey_host, 0x7aff);
  } else
    ok = FALSE;
  // Saving from a focused recorder must reject an OS-level conflict without
  // writing it, changing the current keys, or reactivating either live action.
  mc_pin_suspend_shortcuts(TRUE);
  wchar_t test_path[160];
  swprintf_s(test_path, 160, L"Software\\MoojiCut.PinSmoke.%lu", GetCurrentProcessId());
  RegDeleteTreeW(HKEY_CURRENT_USER, test_path);
  WORD baseline[6], proposed[6], stored[6];
  memcpy(baseline, keys, sizeof(keys));
  memcpy(proposed, keys, sizeof(keys));
  ok = ok && mc_pin_save_keys(test_path, baseline);
  proposed[5] = MAKEWORD(VK_F24, HOTKEYF_CONTROL | HOTKEYF_ALT | HOTKEYF_SHIFT);
  occupied = RegisterHotKey(hotkey_host, 0x7aff, MOD_CONTROL | MOD_ALT | MOD_SHIFT, VK_F24);
  if (occupied) {
    ok = ok && !mc_pin_save_keys(test_path, proposed) && !memcmp(keys, baseline, sizeof(keys)) &&
         !global_registered[0] && !global_registered[1] && shortcuts_suspended;
    DWORD bytes = sizeof(stored);
    ok = ok &&
         RegGetValueW(HKEY_CURRENT_USER, test_path, L"PinShortcutsV2", RRF_RT_REG_BINARY, NULL, stored,
                      &bytes) == ERROR_SUCCESS &&
         bytes == sizeof(stored) && !memcmp(stored, baseline, sizeof(stored));
    UnregisterHotKey(hotkey_host, 0x7aff);
  } else
    ok = FALSE;
  RegDeleteTreeW(HKEY_CURRENT_USER, test_path);
  mc_pin_suspend_shortcuts(FALSE);
  memcpy(keys, configured, sizeof(keys));
  refresh_pin_hotkeys();
  HGLOBAL another = clone_dib(pin->dib);
  pin->selected = TRUE;
  SendMessageW(live, WM_KEYDOWN, VK_ESCAPE, 0);
  ok = ok && !IsWindow(live);
  if (!another || !mc_pin_image(instance, another, 40, 50, TRUE)) {
    if (another)
      GlobalFree(another);
    return FALSE;
  }
  live = pins->window;
  SendMessageW(live, WM_LBUTTONDBLCLK, 0, 0);
  ok = ok && !IsWindow(live);
  return ok;
}
