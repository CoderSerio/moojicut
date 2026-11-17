#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include "style_controls.h"
#include "components/hud/windows/hud.h"
#include "components/icons/shared/mc_icons.h"
#include <commctrl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

struct MCStyleControls {
  HWND parent, tooltip, color_label, buttons[MC_STYLE_CONTROL_COUNT];
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
  if (visible(controls, MC_STYLE_BLOCK)) return MC_STYLE_BLOCK;
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
      L"线条宽度 · 点击选择", L"字号 · 点击选择", L"形状 · 点击选择", L"马赛克颗粒 · 点击选择", L"增大当前数值", L"减小当前数值"};
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
  controls->color_label = CreateWindowW(L"STATIC", L"颜色", WS_CHILD | SS_OWNERDRAW,
      0, 0, 1, 1, parent, NULL, instance, NULL);
  if (!controls->color_label) goto failed;
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
  if (IsWindow(controls->color_label)) DestroyWindow(controls->color_label);
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
  ShowWindow(controls->color_label, visible(controls, MC_STYLE_COLOR) ? SW_SHOWNA : SW_HIDE);
  EnableWindow(controls->color_label, model->enabled);
  for (int field = 0; field < MC_STYLE_PROPERTY_COUNT; field++) {
    HWND button = controls->buttons[field];
    wchar_t label[96];
    double value = model->property[field].value;
    if (field == MC_STYLE_COLOR)
      swprintf_s(label, 96, L"颜色：#%06X，点击选择", rounded(value));
    else if (field == MC_STYLE_OPACITY)
      swprintf_s(label, 96, L"不透明度：%d%%，点击选择", rounded(value * 100));
    else if (field == MC_STYLE_SHAPE)
      swprintf_s(label, 96, L"形状：%s，点击选择", (const wchar_t *[]){L"方框", L"圆框", L"马赛克"}[rounded(value) >= 0 && rounded(value) <= 2 ? rounded(value) : 0]);
    else if (field == MC_STYLE_BLOCK)
      swprintf_s(label, 96, L"颗粒：%g 像素，点击选择", value);
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
static int control_width(int field) {
  const int widths[] = {76, 112, 76, 76, 84, 76};
  return field == MC_STYLE_COLOR ? editor_style_swatch_size() : widths[field];
}
static int group_width(const MCStyleControls *controls, int field) {
  // The 4-point input/stepper space belongs inside the numeric group.
  return control_width(field) + (field == MC_STYLE_COLOR ? 24 + 4 :
    (field == numeric_property(controls) ? 4 + 20 : 0));
}
int mc_style_controls_width(const MCStyleControls *controls) {
  if (!controls || !controls->model.mask) return 0;
  int width = 0, count = 0;
  for (int field = 0; field < MC_STYLE_PROPERTY_COUNT; field++) {
    if (!visible(controls, field)) continue;
    if (count++) width += editor_style_group_gap();
    width += group_width(controls, field);
  }
  return width;
}
void mc_style_controls_layout(MCStyleControls *controls, int x, int y) {
  if (!controls || controls->retiring) return;
  HWND parent = controls->parent;
  const int order[] = {MC_STYLE_SHAPE, MC_STYLE_COLOR, MC_STYLE_FONT, MC_STYLE_STROKE, MC_STYLE_BLOCK, MC_STYLE_OPACITY};
  int left = 0, count = 0;
  for (int i = 0; i < MC_STYLE_PROPERTY_COUNT; i++) {
    int field = order[i];
    if (!visible(controls, field)) continue;
    if (count++) left += editor_style_group_gap();
    int button_left = left, button_y = y, button_height = 28;
    if (field == MC_STYLE_COLOR) {
      MoveWindow(controls->color_label, x + pixels(parent, left), y, pixels(parent, 24), pixels(parent, 28), TRUE);
      button_left += 24 + 4;
      button_height = editor_style_swatch_size();
      button_y += pixels(parent, (28 - button_height) / 2);
    }
    MoveWindow(controls->buttons[field], x + pixels(parent, button_left), button_y,
        pixels(parent, control_width(field)), pixels(parent, button_height), TRUE);
    if (field == MC_STYLE_COLOR) {
      int diameter = pixels(parent, editor_style_swatch_size());
      HRGN circle = CreateEllipticRgn(0, 0, diameter, diameter);
      if (circle && !SetWindowRgn(controls->buttons[field], circle, TRUE)) DeleteObject(circle);
    }
    if (field == numeric_property(controls)) {
      int step_left = left + control_width(field) + 4;
      for (int j = 0; j < 2; j++)
        MoveWindow(controls->buttons[MC_STYLE_CONTROL_INCREASE + j], x + pixels(parent, step_left),
          y + pixels(parent, j * 14), pixels(parent, 20), pixels(parent, 14), TRUE);
    }
    left += group_width(controls, field);
  }
}
BOOL mc_style_controls_choose(MCStyleControls *controls, int field, double value) {
  if (!controls || controls->retiring || field < 0 || field >= MC_STYLE_PROPERTY_COUNT || !controls->model.enabled ||
      !visible(controls, field))
    return FALSE;
  MCStyleProperty number = controls->model.property[field];
  if (!isfinite(value) || value < number.minimum || value > number.maximum ||
      ((field == MC_STYLE_COLOR || field == MC_STYLE_SHAPE || field == MC_STYLE_BLOCK) && value != floor(value)) ||
      (field == MC_STYLE_SHAPE && value >= editor_style_shape_count(controls->model.tool)))
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
  } else if (field == MC_STYLE_SHAPE) {
    for (int i = 0; i < editor_style_shape_count(controls->model.tool); i++) options[count++] = i;
  } else if (field == MC_STYLE_BLOCK) {
    const int sizes[] = {4, 8, 12, 16, 24, 32, 48};
    for (int i = 0; i < (int)ARRAYSIZE(sizes); i++) options[count++] = sizes[i];
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
    else if (field == MC_STYLE_SHAPE)
      wcscpy_s(label, ARRAYSIZE(label), (const wchar_t *[]){L"方框", L"圆框", L"马赛克"}[i]);
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
  if (control < MC_STYLE_PROPERTY_COUNT)
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
  if (item->hwndItem == controls->color_label) {
    mc_hud_button(item->hDC, &item->rcItem, MC_HUD_COLOR_LABEL, 0, FALSE, FALSE, FALSE, FALSE,
      !controls->model.enabled, (float)GetDpiForWindow(controls->parent) / 96);
    return TRUE;
  }
  int control = (int)item->CtlID - controls->first_id;
  if (control < 0 || control >= MC_STYLE_CONTROL_COUNT || item->hwndItem != controls->buttons[control])
    return FALSE;
  const int kinds[] = {MC_HUD_COLOR, MC_HUD_OPACITY, MC_HUD_STROKE, MC_HUD_FONT, MC_HUD_SHAPE, MC_HUD_BLOCK,
      MC_ICON_CHEVRON_UP, MC_ICON_CHEVRON_DOWN};
  int value = control < MC_STYLE_PROPERTY_COUNT ? rounded(controls->model.property[control].value *
      (control == MC_STYLE_OPACITY ? 100 : 1)) : 0;
  if (control == MC_STYLE_CONTROL_SHAPE) value += controls->model.tool * 10;
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
static BOOL layout_smoke(HWND parent, HINSTANCE instance) {
  Smoke state = {0};
  state.controls = mc_style_controls_create(parent, instance, 400, smoke_change, &state);
  if (!state.controls) return FALSE;
  state.model.enabled = TRUE;
  for (int field = 0; field < MC_STYLE_PROPERTY_COUNT; field++)
    state.model.property[field] = (MCStyleProperty){editor_style_default(field), editor_style_min(field),
      editor_style_max(field), editor_style_step(field)};
  const int tools[] = {MC_STYLE_TOOL_RECTANGLE, MC_STYLE_TOOL_ARROW, MC_STYLE_TOOL_TEXT,
                       MC_STYLE_TOOL_COVER, MC_STYLE_TOOL_COVER};
  const int shapes[] = {0, 0, 0, 0, 2};
  const int order[] = {MC_STYLE_SHAPE, MC_STYLE_COLOR, MC_STYLE_FONT, MC_STYLE_STROKE,
                       MC_STYLE_BLOCK, MC_STYLE_OPACITY};
  BOOL ok = TRUE;
  for (unsigned test = 0; test < ARRAYSIZE(tools); test++) {
    state.model.tool = tools[test];
    state.model.mask = editor_style_visible_mask(tools[test], shapes[test]);
    state.model.property[MC_STYLE_SHAPE].value = shapes[test];
    mc_style_controls_update(state.controls, &state.model);
    mc_style_controls_layout(state.controls, 8, 8);
    int right = 8, count = 0;
    for (unsigned i = 0; i < ARRAYSIZE(order); i++) {
      int field = order[i];
      RECT rect;
      if (!visible(state.controls, field)) continue;
      GetWindowRect(field == MC_STYLE_COLOR ? state.controls->color_label : state.controls->buttons[field], &rect);
      MapWindowPoints(HWND_DESKTOP, parent, (POINT *)&rect, 2);
      int gap = rect.left - right;
      ok = ok && (count ? abs(gap - pixels(parent, editor_style_group_gap())) <= 1 : gap == 0);
      right = rect.right;
      if (field == MC_STYLE_COLOR) {
        GetWindowRect(state.controls->buttons[field], &rect);
        MapWindowPoints(HWND_DESKTOP, parent, (POINT *)&rect, 2);
        int size = pixels(parent, editor_style_swatch_size());
        ok = ok && abs(rect.left - right - pixels(parent, 4)) <= 1 &&
          rect.right - rect.left == size && rect.bottom - rect.top == size;
        HRGN region = CreateRectRgn(0, 0, 0, 0);
        ok = ok && GetWindowRgn(state.controls->buttons[field], region) != ERROR &&
          PtInRegion(region, size / 2, size / 2) && !PtInRegion(region, 0, 0);
        DeleteObject(region);
        right = rect.right;
      }
      if (field == numeric_property(state.controls)) {
        GetWindowRect(state.controls->buttons[MC_STYLE_CONTROL_INCREASE], &rect);
        MapWindowPoints(HWND_DESKTOP, parent, (POINT *)&rect, 2);
        ok = ok && abs(rect.left - right - pixels(parent, 4)) <= 1;
        right = rect.right;
      }
      count++;
    }
    ok = ok && count > 0 && abs(right - 8 - pixels(parent, mc_style_controls_width(state.controls))) <= 1;
  }
  state.model.mask = 0;
  mc_style_controls_update(state.controls, &state.model);
  ok = ok && mc_style_controls_width(state.controls) == 0;
  mc_style_controls_destroy(state.controls);
  return ok;
}
BOOL mc_style_controls_smoke(HINSTANCE instance) {
  HWND parent = CreateWindowW(L"STATIC", L"Style controls fixture", WS_POPUP, 0, 0, 500, 120,
      NULL, NULL, instance, NULL);
  Smoke a = {0}, b = {0};
  BOOL ok = FALSE;
  if (!parent)
    return FALSE;
  if (!layout_smoke(parent, instance)) goto cleanup;
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
      "callback disposal, nested menu owner disposal, property group geometry).\n",
      ok ? "passed" : "FAILED");
  return ok;
}
