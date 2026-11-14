#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include "style_controls.h"
#include "hud.h"
#include "../shared/mc_icons.h"
#include <commctrl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

struct MCStyleControls {
  HWND parent, tooltip, buttons[MC_STYLE_CONTROL_COUNT];
  int first_id;
  unsigned references;
  BOOL retiring;
  MCStyleControlsModel model;
  MCStyleChange change;
  void *context;
};
/* Native menus run a nested message loop. Their owner can close while the menu
 * is open, and a change callback may dispose this component synchronously. */
static void retain(MCStyleControls *controls) { controls->references++; }
static void release(MCStyleControls *controls) {
  if (!--controls->references)
    free(controls);
}
static const int palette[] = {0xF26769, 0x246BFD, 0x25A56A, 0xFFFFFF, 0x111111};
static int rounded(double value) { return (int)floor(value + .5); }
static int pixels(HWND window, int value) { return MulDiv(value, (int)GetDpiForWindow(window), 96); }
static BOOL visible(const MCStyleControls *controls, int property) {
  return (controls->model.mask & (1u << property)) != 0;
}
static int numeric_property(const MCStyleControls *controls) {
  return visible(controls, MC_STYLE_FONT) ? MC_STYLE_FONT : MC_STYLE_STROKE;
}
static LRESULT CALLBACK button_proc(HWND window, UINT message, WPARAM wp, LPARAM lp,
                                    UINT_PTR id, DWORD_PTR data) {
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
    RemoveWindowSubclass(window, button_proc, id);
  }
  return DefSubclassProc(window, message, wp, lp);
}
MCStyleControls *mc_style_controls_create(HWND parent, HINSTANCE instance, int first_id,
                                          MCStyleChange change, void *context) {
  MCStyleControls *controls = calloc(1, sizeof(*controls));
  if (!controls)
    return NULL;
  controls->parent = parent;
  controls->references = 1;
  controls->first_id = first_id;
  controls->change = change;
  controls->context = context;
  controls->tooltip = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, NULL,
      WS_POPUP | TTS_ALWAYSTIP, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
      parent, NULL, instance, NULL);
  const wchar_t *labels[MC_STYLE_CONTROL_COUNT] = {L"标注颜色 · 点击选择", L"不透明度 · 点击选择",
      L"线条宽度 · 点击选择", L"字号 · 点击选择", L"增大当前数值", L"减小当前数值"};
  if (!controls->tooltip)
    goto failed;
  for (int i = 0; i < MC_STYLE_CONTROL_COUNT; i++) {
    HWND button = controls->buttons[i] = CreateWindowW(L"BUTTON", labels[i],
        WS_CHILD | WS_TABSTOP | BS_OWNERDRAW, 0, 0, 1, 1, parent,
        (HMENU)(INT_PTR)(first_id + i), instance, NULL);
    if (!button)
      goto failed;
    SetWindowSubclass(button, button_proc, 1, 0);
    TOOLINFOW tip = {sizeof(tip)};
    tip.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
    tip.hwnd = parent;
    tip.uId = (UINT_PTR)button;
    tip.lpszText = (LPWSTR)labels[i];
    SendMessageW(controls->tooltip, TTM_ADDTOOLW, 0, (LPARAM)&tip);
  }
  return controls;
failed:
  mc_style_controls_destroy(controls);
  return NULL;
}
void mc_style_controls_destroy(MCStyleControls *controls) {
  if (!controls || controls->retiring)
    return;
  controls->retiring = TRUE;
  if (IsWindow(controls->tooltip))
    DestroyWindow(controls->tooltip);
  for (int i = 0; i < MC_STYLE_CONTROL_COUNT; i++)
    if (IsWindow(controls->buttons[i]))
      DestroyWindow(controls->buttons[i]);
  release(controls);
}
HWND mc_style_controls_window(const MCStyleControls *controls, int control) {
  return controls && !controls->retiring && control >= 0 && control < MC_STYLE_CONTROL_COUNT
      ? controls->buttons[control] : NULL;
}
void mc_style_controls_update(MCStyleControls *controls, const MCStyleControlsModel *model) {
  if (!controls || controls->retiring || !model)
    return;
  controls->model = *model;
  for (int field = 0; field < 4; field++) {
    HWND button = controls->buttons[field];
    wchar_t label[96];
    double value = model->property[field].value;
    if (field == MC_STYLE_COLOR)
      swprintf_s(label, 96, L"颜色：#%06X，点击选择", rounded(value));
    else if (field == MC_STYLE_OPACITY)
      swprintf_s(label, 96, L"不透明度：%d%%，点击选择", rounded(value * 100));
    else
      swprintf_s(label, 96, field == MC_STYLE_FONT ? L"文字大小：%g 像素，点击选择" : L"线宽：%g 像素，点击选择", value);
    SetWindowTextW(button, label);
    ShowWindow(button, visible(controls, field) ? SW_SHOWNA : SW_HIDE);
    EnableWindow(button, model->enabled);
    InvalidateRect(button, NULL, FALSE);
  }
  int field = numeric_property(controls);
  const MCStyleProperty *number = &model->property[field];
  for (int i = MC_STYLE_CONTROL_INCREASE; i <= MC_STYLE_CONTROL_DECREASE; i++) {
    BOOL up = i == MC_STYLE_CONTROL_INCREASE;
    ShowWindow(controls->buttons[i], visible(controls, field) ? SW_SHOWNA : SW_HIDE);
    EnableWindow(controls->buttons[i], model->enabled &&
        (up ? number->value < number->maximum : number->value > number->minimum));
    InvalidateRect(controls->buttons[i], NULL, FALSE);
  }
}
void mc_style_controls_layout(MCStyleControls *controls, int x, int y) {
  if (!controls || controls->retiring)
    return;
  HWND parent = controls->parent;
  const int left[] = {0, 236, 100, 100, 192, 192};
  const int top[] = {0, 0, 0, 0, 0, 16};
  const int width[] = {88, 132, 88, 88, 24, 24};
  for (int i = 0; i < MC_STYLE_CONTROL_COUNT; i++)
    MoveWindow(controls->buttons[i], x + pixels(parent, left[i]), y + pixels(parent, top[i]),
        pixels(parent, width[i]), pixels(parent, i >= MC_STYLE_CONTROL_INCREASE ? 16 : 32), TRUE);
}
BOOL mc_style_controls_choose(MCStyleControls *controls, int field, double value) {
  if (!controls || controls->retiring || field < 0 || field >= 4 || !controls->model.enabled ||
      !visible(controls, field))
    return FALSE;
  MCStyleProperty number = controls->model.property[field];
  if (!isfinite(value) || value < number.minimum || value > number.maximum ||
      (field == MC_STYLE_COLOR && value != floor(value)))
    return FALSE;
  if (value == number.value)
    return TRUE;
  if (!controls->change)
    return FALSE;
  retain(controls);
  BOOL accepted = controls->change(controls->context, field, value);
  release(controls);
  return accepted;
}
static void popup(MCStyleControls *controls, int field) {
  if (controls->retiring || !visible(controls, field) || !controls->model.enabled)
    return;
  HMENU menu = CreatePopupMenu();
  if (!menu)
    return;
  double options[16];
  int count = 0;
  const wchar_t *color_names[] = {L"珊瑚红", L"蓝色", L"绿色", L"白色", L"黑色"};
  if (field == MC_STYLE_COLOR) {
    for (int i = 0; i < 5; i++)
      options[count++] = palette[i];
  } else if (field == MC_STYLE_OPACITY) {
    for (int i = 0; i <= 10; i++)
      options[count++] = i / 10.0;
  } else if (field == MC_STYLE_STROKE) {
    options[count++] = 2; options[count++] = 4; options[count++] = 8;
  } else {
    const int sizes[] = {8, 12, 16, 24, 28, 32, 48, 72, 128};
    for (int i = 0; i < (int)ARRAYSIZE(sizes); i++)
      options[count++] = sizes[i];
  }
  MCStyleProperty number = controls->model.property[field];
  for (int i = 0; i < count; i++) {
    if (options[i] < number.minimum || options[i] > number.maximum)
      continue;
    wchar_t label[40];
    if (field == MC_STYLE_COLOR)
      wcscpy_s(label, ARRAYSIZE(label), color_names[i]);
    else if (field == MC_STYLE_OPACITY)
      swprintf_s(label, ARRAYSIZE(label), L"%d%%", rounded(options[i] * 100));
    else
      swprintf_s(label, ARRAYSIZE(label), L"%g 像素", options[i]);
    AppendMenuW(menu, MF_STRING | (number.value == options[i] ? MF_CHECKED : 0), i + 1, label);
  }
  RECT rect;
  GetWindowRect(controls->buttons[field], &rect);
  HWND previous = GetFocus();
  retain(controls);
  int result = (int)TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_LEFTALIGN,
      rect.left, rect.bottom + pixels(controls->parent, 4), 0, controls->parent, NULL);
  DestroyMenu(menu);
  if (!controls->retiring && result > 0 && result <= count)
    mc_style_controls_choose(controls, field, options[result - 1]);
  if (!controls->retiring && IsWindow(previous))
    SetFocus(previous);
  release(controls);
}
BOOL mc_style_controls_command(MCStyleControls *controls, WPARAM wp, LPARAM lp) {
  if (!controls || controls->retiring)
    return FALSE;
  int control = LOWORD(wp) - controls->first_id;
  if (control < 0 || control >= MC_STYLE_CONTROL_COUNT ||
      (lp && (HWND)lp != controls->buttons[control]))
    return FALSE;
  if (HIWORD(wp) != BN_CLICKED || !controls->model.enabled)
    return TRUE;
  if (control < 4)
    popup(controls, control);
  else {
    int field = numeric_property(controls);
    MCStyleProperty number = controls->model.property[field];
    double value = number.value + (control == MC_STYLE_CONTROL_INCREASE ? number.step : -number.step);
    value = fmin(number.maximum, fmax(number.minimum, value));
    mc_style_controls_choose(controls, field, value);
  }
  return TRUE;
}
BOOL mc_style_controls_draw(MCStyleControls *controls, const DRAWITEMSTRUCT *item) {
  if (!controls || controls->retiring || !item)
    return FALSE;
  int control = (int)item->CtlID - controls->first_id;
  if (control < 0 || control >= MC_STYLE_CONTROL_COUNT || item->hwndItem != controls->buttons[control])
    return FALSE;
  const int kinds[] = {MC_HUD_COLOR, MC_HUD_OPACITY, MC_HUD_STROKE, MC_HUD_FONT,
      MC_ICON_CHEVRON_UP, MC_ICON_CHEVRON_DOWN};
  int value = control < 4 ? rounded(controls->model.property[control].value *
      (control == MC_STYLE_OPACITY ? 100 : 1)) : 0;
  mc_hud_button(item->hDC, &item->rcItem, kinds[control], value, FALSE,
      GetPropW(item->hwndItem, L"MoojiCut.Hover") != NULL, (item->itemState & ODS_SELECTED) != 0,
      (item->itemState & ODS_FOCUS) != 0, !IsWindowEnabled(item->hwndItem),
      (float)GetDpiForWindow(controls->parent) / 96);
  return TRUE;
}

typedef struct {
  MCStyleControls *controls;
  MCStyleControlsModel model;
  int calls, field;
  double value;
  BOOL destroy_on_change, menu_entered, parent_closed;
} Smoke;
static BOOL smoke_change(void *context, int field, double value) {
  Smoke *state = context;
  state->calls++;
  state->field = field;
  state->value = value;
  state->model.property[field].value = value;
  if (state->destroy_on_change) {
    MCStyleControls *controls = state->controls;
    state->controls = NULL;
    mc_style_controls_destroy(controls);
    return TRUE;
  }
  mc_style_controls_update(state->controls, &state->model);
  return TRUE;
}
static LRESULT CALLBACK menu_smoke_proc(HWND window, UINT message, WPARAM wp, LPARAM lp,
                                        UINT_PTR id, DWORD_PTR data) {
  Smoke *state = (Smoke *)data;
  if (message == WM_TIMER && wp == 1) {
    GUITHREADINFO info = {sizeof(info)};
    state->menu_entered = GetGUIThreadInfo(GetCurrentThreadId(), &info) &&
        (info.flags & (GUI_INMENUMODE | GUI_POPUPMENUMODE)) != 0;
    KillTimer(window, 1);
    EndMenu();
    DestroyWindow(window);
    return 0;
  }
  if (message == WM_NCDESTROY) {
    MCStyleControls *controls = state->controls;
    state->controls = NULL;
    state->parent_closed = TRUE;
    mc_style_controls_destroy(controls);
    RemoveWindowSubclass(window, menu_smoke_proc, id);
  }
  return DefSubclassProc(window, message, wp, lp);
}
typedef struct { HANDLE complete; HWND owner; DWORD ui_thread; LONG expired; } MenuWatchdog;
static DWORD WINAPI menu_watchdog(void *context) {
  MenuWatchdog *watchdog = context;
  if (WaitForSingleObject(watchdog->complete, 3000) == WAIT_TIMEOUT) {
    InterlockedExchange(&watchdog->expired, 1);
    PostMessageW(watchdog->owner, WM_CANCELMODE, 0, 0);
    // WM_QUIT also exits a native modal menu loop on a noninteractive runner.
    PostThreadMessageW(watchdog->ui_thread, WM_QUIT, 1, 0);
  }
  return 0;
}
static BOOL menu_retirement_smoke(HINSTANCE instance) {
  HWND parent = CreateWindowW(L"STATIC", L"Style menu lifetime fixture", WS_POPUP,
      0, 0, 500, 120, NULL, NULL, instance, NULL);
  if (!parent)
    return FALSE;
  Smoke state = {0};
  state.controls = mc_style_controls_create(parent, instance, 300, smoke_change, &state);
  if (!state.controls) {
    DestroyWindow(parent);
    return FALSE;
  }
  state.model.enabled = TRUE;
  state.model.mask = 1 << MC_STYLE_COLOR;
  state.model.property[MC_STYLE_COLOR] = (MCStyleProperty){0xF26769, 0, 0xFFFFFF, 1};
  mc_style_controls_update(state.controls, &state.model);
  mc_style_controls_layout(state.controls, 8, 8);
  if (!SetWindowSubclass(parent, menu_smoke_proc, 99, (DWORD_PTR)&state)) {
    mc_style_controls_destroy(state.controls);
    DestroyWindow(parent);
    return FALSE;
  }
  // A timer dispatched inside the real TrackPopupMenu loop closes this fixture
  // and retires its controls before TrackPopupMenu returns to popup().
  ShowWindow(parent, SW_SHOWNOACTIVATE);
  // TPM_NONOTIFY suppresses owner menu notifications, so arm the timer before
  // entering the modal loop rather than relying on WM_INITMENUPOPUP.
  if (!SetTimer(parent, 1, 1, NULL)) {
    DestroyWindow(parent);
    return FALSE;
  }
  MenuWatchdog watchdog = {CreateEventW(NULL, TRUE, FALSE, NULL), parent, GetCurrentThreadId(), 0};
  HANDLE thread = watchdog.complete ? CreateThread(NULL, 0, menu_watchdog, &watchdog, 0, NULL) : NULL;
  if (!thread) {
    if (watchdog.complete)
      CloseHandle(watchdog.complete);
    KillTimer(parent, 1);
    DestroyWindow(parent);
    return FALSE;
  }
  HWND button = mc_style_controls_window(state.controls, MC_STYLE_CONTROL_COLOR);
  mc_style_controls_command(state.controls, MAKEWPARAM(GetDlgCtrlID(button), BN_CLICKED), (LPARAM)button);
  SetEvent(watchdog.complete);
  // The watchdog only waits for the event and posts messages; it never waits on
  // the UI thread. Do not let a broken fixture hold up the Windows smoke job.
  if (WaitForSingleObject(thread, 4000) != WAIT_OBJECT_0) {
    fputs("Style menu watchdog did not exit.\n", stderr);
    ExitProcess(1);
  }
  CloseHandle(thread);
  CloseHandle(watchdog.complete);
  BOOL ok = !watchdog.expired && state.menu_entered && state.parent_closed && !state.controls && !state.calls;
  if (IsWindow(parent)) {
    KillTimer(parent, 1);
    DestroyWindow(parent);
  }
  return ok;
}
BOOL mc_style_controls_smoke(HINSTANCE instance) {
  HWND parent = CreateWindowW(L"STATIC", L"Style controls fixture", WS_POPUP, 0, 0, 500, 120,
      NULL, NULL, instance, NULL);
  Smoke a = {0}, b = {0};
  BOOL ok = FALSE;
  if (!parent)
    return FALSE;
  a.controls = mc_style_controls_create(parent, instance, 200, smoke_change, &a);
  b.controls = mc_style_controls_create(parent, instance, 220, smoke_change, &b);
  if (!a.controls || !b.controls)
    goto cleanup;
  a.model.enabled = b.model.enabled = TRUE;
  a.model.mask = 1 << MC_STYLE_FONT;
  b.model.mask = 1 << MC_STYLE_STROKE;
  a.model.property[MC_STYLE_FONT] = (MCStyleProperty){20, 10, 22, 2};
  b.model.property[MC_STYLE_STROKE] = (MCStyleProperty){4, 1, 8, 1};
  mc_style_controls_update(a.controls, &a.model);
  mc_style_controls_update(b.controls, &b.model);
  // Real child command dispatch, independent callback destinations and supplied ranges.
  HWND up = mc_style_controls_window(a.controls, MC_STYLE_CONTROL_INCREASE);
  if (!mc_style_controls_command(a.controls, MAKEWPARAM(GetDlgCtrlID(up), BN_CLICKED), (LPARAM)up) ||
      a.calls != 1 || a.field != MC_STYLE_FONT || a.value != 22 || b.calls || IsWindowEnabled(up))
    goto cleanup;
  if (mc_style_controls_command(b.controls, MAKEWPARAM(GetDlgCtrlID(up), BN_CLICKED), (LPARAM)up) ||
      mc_style_controls_choose(a.controls, MC_STYLE_FONT, 23) ||
      mc_style_controls_choose(a.controls, MC_STYLE_COLOR, 0))
    goto cleanup;
  HWND down = mc_style_controls_window(b.controls, MC_STYLE_CONTROL_DECREASE);
  mc_style_controls_command(b.controls, MAKEWPARAM(GetDlgCtrlID(down), BN_CLICKED), (LPARAM)down);
  if (b.calls != 1 || b.field != MC_STYLE_STROKE || b.value != 3 || a.value != 22)
    goto cleanup;
  b.model.enabled = FALSE;
  mc_style_controls_update(b.controls, &b.model);
  if (mc_style_controls_choose(b.controls, MC_STYLE_STROKE, 5) || b.calls != 1)
    goto cleanup;
  a.destroy_on_change = TRUE;
  if (!mc_style_controls_choose(a.controls, MC_STYLE_FONT, 18) || a.controls || a.calls != 2 ||
      a.value != 18 || !menu_retirement_smoke(instance))
    goto cleanup;
  ok = TRUE;
cleanup:
  mc_style_controls_destroy(a.controls);
  mc_style_controls_destroy(b.controls);
  DestroyWindow(parent);
  printf("Windows style controls smoke: %s (independent callbacks, native commands, supplied ranges, "
      "callback disposal, nested menu owner disposal).\n",
      ok ? "passed" : "FAILED");
  return ok;
}
