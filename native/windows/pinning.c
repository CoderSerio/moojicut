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
  BOOL selected;
  struct Pin *next;
} Pin;
static Pin *pins;
static WORD keys[4] = {VK_OEM_PLUS, VK_OEM_MINUS, MAKEWORD(VK_OEM_PLUS, HOTKEYF_CONTROL),
                       MAKEWORD(VK_OEM_MINUS, HOTKEYF_CONTROL)};
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
void mc_pin_default_keys(WORD out[4]) {
  out[0] = VK_OEM_PLUS;
  out[1] = VK_OEM_MINUS;
  out[2] = MAKEWORD(VK_OEM_PLUS, HOTKEYF_CONTROL);
  out[3] = MAKEWORD(VK_OEM_MINUS, HOTKEYF_CONTROL);
}
static BOOL valid(const WORD proposed[4]) {
  for (int i = 0; i < 4; i++) {
    BYTE vk = LOBYTE(proposed[i]);
    if (vk == VK_ESCAPE || vk == VK_DELETE || vk == VK_TAB || vk == VK_RETURN || vk == VK_CONTROL ||
        vk == VK_SHIFT || vk == VK_MENU)
      return FALSE;
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
WORD mc_pin_key(int action) { return action >= 0 && action < 4 ? keys[action] : 0; }
void mc_pin_load_keys(const wchar_t *path) {
  WORD stored[4];
  DWORD size = sizeof(stored);
  mc_pin_default_keys(keys);
  if (RegGetValueW(HKEY_CURRENT_USER, path, L"PinShortcutsV1", RRF_RT_REG_BINARY, NULL, stored, &size) ==
          ERROR_SUCCESS &&
      size == sizeof(stored) && valid(stored))
    memcpy(keys, stored, sizeof(keys));
}
BOOL mc_pin_save_keys(const wchar_t *path, const WORD proposed[4]) {
  HKEY key;
  if (!valid(proposed))
    return FALSE;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS)
    return FALSE;
  LONG result = RegSetValueExW(key, L"PinShortcutsV1", 0, REG_BINARY, (const BYTE *)proposed, sizeof(keys));
  RegCloseKey(key);
  if (result == ERROR_SUCCESS)
    memcpy(keys, proposed, sizeof(keys));
  return result == ERROR_SUCCESS;
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
  case WM_LBUTTONDOWN:
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
    pin->selected = LOWORD(wp) != WA_INACTIVE;
    InvalidateRect(window, NULL, FALSE);
    return 0;
  case WM_KEYDOWN:
  case WM_SYSKEYDOWN: {
    if (wp == VK_ESCAPE) {
      pin->selected = FALSE;
      SetFocus(NULL);
      InvalidateRect(window, NULL, FALSE);
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
    for (int i = 0; i < 4; i++)
      if (LOBYTE(keys[i]) && pressed == normalize(keys[i])) {
        pin_action(pin, i);
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
  resize_pin(pin, 1);
  if (!hidden) {
    ShowWindow(window, SW_SHOWNOACTIVATE);
    SetForegroundWindow(window);
    SetFocus(window);
    pin->selected = TRUE;
  }
  return TRUE;
}
void mc_pins_hide(BOOL hidden) {
  for (Pin *pin = pins; pin; pin = pin->next)
    ShowWindow(pin->window, hidden ? SW_HIDE : SW_SHOWNOACTIVATE);
}
void mc_pins_close(void) {
  while (pins)
    DestroyWindow(pins->window);
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
  resize_pin(pin, .5);
  RECT rect;
  GetWindowRect(pin->window, &rect);
  BOOL ok = rect.right - rect.left == 160 && rect.bottom - rect.top == 100;
  WORD saved[4];
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
  WORD duplicate[4] = {VK_OEM_PLUS, VK_ADD, 0, 0};
  ok = ok && !valid(duplicate) && normalize(MAKEWORD(VK_OEM_PLUS, HOTKEYF_SHIFT)) == VK_OEM_PLUS;
  DestroyWindow(pin->window);
  return ok;
}
