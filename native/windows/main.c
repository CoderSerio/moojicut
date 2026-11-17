#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <shellapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include "moonbit.h"
#include "resource.h"
#include "updates.h"
#include "bindings/c/tool_registry.h"
#include "plugins/feature/capture/windows/capture.h"
#include "plugins/feature/pin/windows/pinning.h"
#include "plugins/feature/recording/windows/recording.h"

#ifndef MOOJICUT_VERSION
#define MOOJICUT_VERSION "0.1.0-alpha.2"
#endif
#define WIDE_IMPL(x) L##x
#define WIDE(x) WIDE_IMPL(x)
#define WM_TRAY (WM_APP + 1)
#define WM_SHOW_SETTINGS (WM_APP + 2)
#define WM_REFRESH_SHORTCUTS (WM_APP + 3)
#define CAPTURE_TIMER 6101
#define CAPTURE_HOTKEY 6102
#define RECORD_HOTKEY 6103
#define STOP_HOTKEY 6104
#define RECORD_TIMER 6105
#define SETTINGS_SUBCLASS 1

extern int32_t preview_core_check(void);
extern int32_t shortcut_validate(int32_t, int32_t, int32_t, int32_t, int32_t, int32_t);

static const wchar_t *HOST_CLASS = L"MoojiCut.Native.TrayHost";
static wchar_t registry_path[160] = L"Software\\MoojiCut";
typedef struct {
    DWORD version;
    DWORD open_on_start;
    DWORD hotkeys[3];
} PreferenceRecord;
static const WORD DEFAULT_KEYS[3] = {
    MAKEWORD('1', HOTKEYF_CONTROL | HOTKEYF_SHIFT),
    MAKEWORD('2', HOTKEYF_CONTROL | HOTKEYF_SHIFT),
    MAKEWORD('X', HOTKEYF_CONTROL | HOTKEYF_SHIFT)
};
static HINSTANCE instance;
static HWND host, settings;
static HICON app_icon;
static UINT taskbar_created;
static NOTIFYICONDATAW tray;
static BOOL tray_added, smoke_mode, updating;
static BOOL smoke_shortcut_registration;
static WORD hotkeys[3];
static BOOL open_on_start;
static BOOL update_exit_pending;
static int core_ok;
static BOOL global_registered[3];
static int32_t tool_snapshot;
static BOOL tool_publishing, smoke_fail_tool_save;
static unsigned smoke_tool_save_attempts;
static HWND tools_window;
static void refresh_tools_page(HWND page, int selected);
static wchar_t shortcut_registration_error[180];
static void refresh_global_shortcuts(void);
static void unregister_shortcuts(void) {
    int i;
    for (i = 0; i < 3; i++) {
        if (global_registered[i]) UnregisterHotKey(host, CAPTURE_HOTKEY + i);
        global_registered[i] = FALSE;
    }
}

static LRESULT CALLBACK hotkey_recorder_proc(HWND window, UINT message, WPARAM wp, LPARAM lp, UINT_PTR id, DWORD_PTR data) {
    (void)id; (void)data;
    if (message == WM_SETFOCUS) {
        unregister_shortcuts();mc_pin_suspend_shortcuts(TRUE);
    } else if (message == WM_KILLFOCUS) {mc_pin_suspend_shortcuts(FALSE);PostMessageW(host, WM_REFRESH_SHORTCUTS, 0, 0);}
    else if (message == WM_NCDESTROY) RemoveWindowSubclass(window, hotkey_recorder_proc, 1);
    return DefSubclassProc(window, message, wp, lp);
}

static void refresh_global_shortcuts(void) {
    int i;
    HWND focused = GetFocus();
    wchar_t class_name[64];
    if ((smoke_mode && !smoke_shortcut_registration) || !host) return;
    unregister_shortcuts();
    shortcut_registration_error[0] = L'\0';
    if (focused && GetClassNameW(focused, class_name, ARRAYSIZE(class_name)) &&
        wcscmp(class_name, HOTKEY_CLASSW) == 0) return;
    for (i = 0; i < 3; i++) {
        UINT modifiers = MOD_NOREPEAT;
        BYTE flags = HIBYTE(hotkeys[i]);
        if (!LOBYTE(hotkeys[i])) continue;
        if (flags & HOTKEYF_CONTROL) modifiers |= MOD_CONTROL;
        if (flags & HOTKEYF_ALT) modifiers |= MOD_ALT;
        if (flags & HOTKEYF_SHIFT) modifiers |= MOD_SHIFT;
        global_registered[i] = RegisterHotKey(host, CAPTURE_HOTKEY + i, modifiers, LOBYTE(hotkeys[i]));
        if (!global_registered[i] && smoke_shortcut_registration)
            fprintf(stderr, "Hotkey smoke: RegisterHotKey action=%d failed, error=%lu.\n", i, GetLastError());
        if (!global_registered[i]) swprintf_s(shortcut_registration_error, ARRAYSIZE(shortcut_registration_error),
            L"%s快捷键未能启用，可能已被其他程序占用。请换一个组合。", i == 0 ? L"截图" : i == 1 ? L"开始录屏" : L"停止录屏");
    }
    if (settings) {
        HWND page = PropSheet_GetCurrentPageHwnd(settings);
        if (page && GetDlgItem(page, IDC_SHORTCUT_STATUS))
            SetDlgItemTextW(page, IDC_SHORTCUT_STATUS, shortcut_registration_error[0] ? shortcut_registration_error :
                L"快捷键已启用。录入时暂时停用，离开输入框后恢复。");
    }
}

static BOOL capture_pin_image(void *context, HGLOBAL dib, int x, int y) {
    HINSTANCE application = *(HINSTANCE *)context;
    return mc_pin_image(application, dib, x, y, TRUE);
}
static void capture_set_pins_hidden(void *context, BOOL hidden) {
    (void)context;
    mc_pins_hide(hidden);
}
static BOOL capture_pin_enabled(void *context) { (void)context; return mc_pin_enabled(); }
static const MCCaptureHost capture_services = {&instance, capture_pin_image, capture_set_pins_hidden, capture_pin_enabled};

static void start_capture(void) {
    if (update_exit_pending) return;
    if (mc_capture_busy()) { mc_capture_activate(); return; }
    if (mc_recording_preparing()) { mc_recording_activate(); return; }
    KillTimer(host, RECORD_TIMER);
    if (settings) ShowWindow(settings, SW_HIDE);
    mc_pins_hide(TRUE);
    SetTimer(host, CAPTURE_TIMER, 160, NULL);
}
static void start_recording(void) {
    if (update_exit_pending) return;
    if (mc_recording_busy()) { mc_recording_activate(); return; }
    if (mc_capture_busy()) { mc_capture_activate(); return; }
    KillTimer(host, CAPTURE_TIMER);
    mc_pins_hide(FALSE);
    if (settings) ShowWindow(settings, SW_HIDE);
    SetTimer(host, RECORD_TIMER, 160, NULL);
}

static int normalized_key(WORD combination) {
    int vk = LOBYTE(combination);
    if (vk >= VK_F1 && vk <= VK_F24) return 256 + vk - VK_F1;
    return vk;
}

static int normalized_modifiers(WORD combination) {
    BYTE flags = HIBYTE(combination);
    return ((flags & HOTKEYF_CONTROL) ? 1 : 0) |
           ((flags & HOTKEYF_ALT) ? 2 : 0) |
           ((flags & HOTKEYF_SHIFT) ? 4 : 0);
}

static int validate_keys(const WORD keys[3]) {
    int i;
    for (i = 0; i < 3; i++) {
        int a = (i + 1) % 3, b = (i + 2) % 3;
        int result;
        if (HIBYTE(keys[i]) & ~(HOTKEYF_CONTROL | HOTKEYF_ALT | HOTKEYF_SHIFT | HOTKEYF_EXT)) return 3;
        result = shortcut_validate(normalized_key(keys[i]), normalized_modifiers(keys[i]),
            normalized_key(keys[a]), normalized_modifiers(keys[a]),
            normalized_key(keys[b]), normalized_modifiers(keys[b]));
        if (result != 0) return result;
    }
    return 0;
}

static wchar_t *copy_tool_text(int32_t snapshot, int group, int index, int field) {
    moonbit_string_t text = tool_registry_snapshot_text(snapshot, group, index, field);
    int length = Moonbit_array_length(text);
    wchar_t *result = calloc((SIZE_T)length + 1, sizeof(wchar_t));
    if (result) memcpy(result, text, (SIZE_T)length * sizeof(wchar_t));
    moonbit_decref(text);
    return result;
}
static int find_tool_action(int32_t snapshot, const wchar_t *action) {
    int count = tool_registry_snapshot_count(snapshot, MC_TOOL_GROUP_SCREENSHOT);
    for (int i = 0; i < count; i++) {
        wchar_t *value = copy_tool_text(snapshot, MC_TOOL_GROUP_SCREENSHOT, i, MC_TOOL_ACTION);
        BOOL match = value && !wcscmp(value, action); free(value);
        if (match) return i;
    }
    return -1;
}
static BOOL save_tool_layout(int32_t snapshot) {
    if (smoke_mode) smoke_tool_save_attempts++;
    if (smoke_mode && smoke_fail_tool_save) return FALSE;
    moonbit_string_t value = tool_registry_snapshot_layout(snapshot);
    int length = Moonbit_array_length(value);
    BOOL saved = FALSE;
    HKEY key;
    if (length > 0 && RegCreateKeyExW(HKEY_CURRENT_USER, registry_path, 0, NULL, 0,
        KEY_SET_VALUE, NULL, &key, NULL) == ERROR_SUCCESS) {
        /* One value is the complete layout; no partial per-row preferences. */
        saved = RegSetValueExW(key, L"ToolLayout", 0, REG_BINARY,
            (const BYTE *)value, (DWORD)length * sizeof(wchar_t)) == ERROR_SUCCESS;
        RegCloseKey(key);
    }
    moonbit_decref(value);
    return saved;
}
static BOOL publish_tools(int32_t candidate, BOOL persist) {
    if (candidate <= 0 || tool_publishing) { if (candidate > 0) tool_registry_snapshot_close(candidate); return FALSE; }
    tool_publishing = TRUE;
    BOOL ok = mc_capture_prepare_tools(candidate);
    int pin = find_tool_action(candidate, L"pin");
    BOOL enabled = pin >= 0 && tool_registry_snapshot_value(candidate, 0, pin, MC_TOOL_ENABLED) == 1;
    if (ok) ok = mc_pin_can_set_enabled(enabled);
    if (ok && persist) ok = save_tool_layout(candidate);
    if (ok) {
        /* Pin disable drains native resources; its user preference lives only
         * in the shared layout. Preflight, registry save and commit run on this
         * UI thread without a nested message loop, so an enable accepted above
         * cannot enter draining before commit. No document annotations change. */
        mc_pin_set_enabled(enabled);
        int32_t previous = tool_snapshot;
        tool_snapshot = candidate;
        mc_capture_commit_tools(candidate);
        if (previous > 0) tool_registry_snapshot_close(previous);
    } else {
        mc_capture_discard_tools();
        tool_registry_snapshot_close(candidate);
    }
    tool_publishing = FALSE;
    return ok;
}
static void load_tool_layout(BOOL legacy_pin_enabled) {
    DWORD bytes = 0;
    moonbit_string_t saved = moonbit_make_string_raw(0);
    BOOL present = RegGetValueW(HKEY_CURRENT_USER, registry_path, L"ToolLayout", RRF_RT_REG_BINARY,
        NULL, NULL, &bytes) == ERROR_SUCCESS && bytes && bytes <= 131072 && !(bytes % sizeof(wchar_t));
    if (present) {
        moonbit_decref(saved); saved = moonbit_make_string_raw((int)(bytes / sizeof(wchar_t)));
        if (RegGetValueW(HKEY_CURRENT_USER, registry_path, L"ToolLayout", RRF_RT_REG_BINARY,
            NULL, saved, &bytes) != ERROR_SUCCESS) {
            moonbit_decref(saved); saved = moonbit_make_string_raw(0); present = FALSE;
        }
    }
    moonbit_string_t result = tool_registry_normalize(saved);
    moonbit_decref(saved);
    int32_t candidate = tool_registry_snapshot_open(result, MC_TOOL_CAP_COMMANDS);
    moonbit_decref(result);
    if (!candidate) {
        saved = moonbit_make_string_raw(0); result = tool_registry_normalize(saved); moonbit_decref(saved);
        candidate = tool_registry_snapshot_open(result, MC_TOOL_CAP_COMMANDS); moonbit_decref(result);
    }
    if (candidate && !present && !legacy_pin_enabled) {
        int pin = find_tool_action(candidate, L"pin");
        moonbit_string_t id = tool_registry_snapshot_text(candidate, 0, pin, MC_TOOL_ID);
        int32_t migrated = tool_registry_snapshot_set_enabled(candidate, id, 0); moonbit_decref(id);
        if (migrated) { tool_registry_snapshot_close(candidate); candidate = migrated; }
    }
    if (candidate) publish_tools(candidate, FALSE);
}

static void load_preferences(void) {
    HKEY key;
    int i;
    for (i = 0; i < 3; i++) hotkeys[i] = DEFAULT_KEYS[i];
    open_on_start = FALSE;
    DWORD pin_enabled = 1, pin_bytes = sizeof(pin_enabled);
    RegGetValueW(HKEY_CURRENT_USER, registry_path, L"PinEnabled", RRF_RT_REG_DWORD, NULL, &pin_enabled, &pin_bytes);
    if (RegOpenKeyExW(HKEY_CURRENT_USER, registry_path, 0, KEY_QUERY_VALUE, &key) == ERROR_SUCCESS) {
        PreferenceRecord record;
        DWORD size = sizeof(record);
        if (RegGetValueW(key, NULL, L"PreferencesV1", RRF_RT_REG_BINARY, NULL, &record, &size) == ERROR_SUCCESS &&
            size == sizeof(record) && record.version == 1 && record.hotkeys[0] <= 0xffff &&
            record.hotkeys[1] <= 0xffff && record.hotkeys[2] <= 0xffff) {
            for (i = 0; i < 3; i++) hotkeys[i] = (WORD)record.hotkeys[i];
            open_on_start = record.open_on_start != 0;
        }
        RegCloseKey(key);
    }
    if (validate_keys(hotkeys) != 0) for (i = 0; i < 3; i++) hotkeys[i] = DEFAULT_KEYS[i];
    mc_pin_set_capture_keys(hotkeys);mc_pin_load_keys(registry_path);
    load_tool_layout(pin_enabled != 0);
}

static BOOL save_preferences(void) {
    HKEY key;
    PreferenceRecord record;
    int i;
    BOOL succeeded;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, registry_path, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS)
        return FALSE;
    record.version = 1;
    record.open_on_start = open_on_start ? 1 : 0;
    for (i = 0; i < 3; i++) record.hotkeys[i] = hotkeys[i];
    // A single registry value keeps the three shortcuts consistent on failure.
    succeeded = RegSetValueExW(key, L"PreferencesV1", 0, REG_BINARY, (const BYTE *)&record, sizeof(record)) == ERROR_SUCCESS;
    RegCloseKey(key);
    return succeeded;
}

static void fill_shortcuts(HWND page) {
    int i;
    updating = TRUE;
    for (i = 0; i < 3; i++) {
        SendDlgItemMessageW(page, IDC_HOTKEY_CAPTURE + i, HKM_SETRULES, 0, 0);
        SendDlgItemMessageW(page, IDC_HOTKEY_CAPTURE + i, HKM_SETHOTKEY, hotkeys[i], 0);
    }
    updating = FALSE;
}

static void update_shortcuts(HWND page) {
    WORD proposed[3], previous[3];
    int i, result;
    if (updating) return;
    for (i = 0; i < 3; i++) proposed[i] = (WORD)SendDlgItemMessageW(page, IDC_HOTKEY_CAPTURE + i, HKM_GETHOTKEY, 0, 0);
    result = validate_keys(proposed);
    if(mc_pin_capture_conflicts(proposed)){SetDlgItemTextW(page,IDC_SHORTCUT_STATUS,L"与贴图隐藏或鼠标穿透快捷键冲突，尚未保存。");return;}
    if (result != 0) {
        SetDlgItemTextW(page, IDC_SHORTCUT_STATUS, result == 1 ? L"字母与数字需搭配 Ctrl 或 Alt。尚未保存。" :
            result == 2 ? L"快捷键重复，请使用不同的组合。尚未保存。" : L"请使用字母、数字或 F1–F24。尚未保存。");
        return;
    }
    for (i = 0; i < 3; i++) { previous[i] = hotkeys[i]; hotkeys[i] = proposed[i]; }
    if (save_preferences()) {
        mc_pin_set_capture_keys(hotkeys);
        SetDlgItemTextW(page, IDC_SHORTCUT_STATUS, L"已保存；离开输入框后启用快捷键。");
        refresh_global_shortcuts();
    }
    else {
        for (i = 0; i < 3; i++) hotkeys[i] = previous[i];
        SetDlgItemTextW(page, IDC_SHORTCUT_STATUS, L"保存失败，请检查账户权限。");
    }
}

static BOOL set_pin_enabled(BOOL enabled) {
    int pin = find_tool_action(tool_snapshot, L"pin");
    if (pin < 0) return FALSE;
    moonbit_string_t id = tool_registry_snapshot_text(tool_snapshot, 0, pin, MC_TOOL_ID);
    int32_t candidate = tool_registry_snapshot_set_enabled(tool_snapshot, id, enabled ? 1 : 0);
    moonbit_decref(id);
    BOOL ok = publish_tools(candidate, TRUE);
    if (tools_window) refresh_tools_page(tools_window, -1);
    return ok;
}

static INT_PTR CALLBACK general_page(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    (void)lp;
    if (message == WM_INITDIALOG) {
        CheckDlgButton(window, IDC_START_SETTINGS, open_on_start ? BST_CHECKED : BST_UNCHECKED);
        CheckDlgButton(window, IDC_PIN_ENABLED, mc_pin_enabled() ? BST_CHECKED : BST_UNCHECKED);
        return TRUE;
    }
    if (message == WM_COMMAND && LOWORD(wp) == IDC_PIN_ENABLED && HIWORD(wp) == BN_CLICKED) {
        BOOL saved = set_pin_enabled(IsDlgButtonChecked(window, IDC_PIN_ENABLED) == BST_CHECKED);
        CheckDlgButton(window, IDC_PIN_ENABLED, mc_pin_enabled() ? BST_CHECKED : BST_UNCHECKED);
        SetDlgItemTextW(window, IDC_FEATURE_STATUS, saved ? (mc_pin_enabled() ? L"贴图已启用。" : L"贴图已关闭，现有贴图和全局按键已收回。") : L"更改未保存，请稍后重试。");
        return TRUE;
    }
    if (message == WM_COMMAND && LOWORD(wp) == IDC_START_SETTINGS && HIWORD(wp) == BN_CLICKED) {
        BOOL previous = open_on_start;
        open_on_start = IsDlgButtonChecked(window, IDC_START_SETTINGS) == BST_CHECKED;
        if (!save_preferences()) {
            open_on_start = previous;
            CheckDlgButton(window, IDC_START_SETTINGS, previous ? BST_CHECKED : BST_UNCHECKED);
            MessageBoxW(window, L"设置未能保存，请检查账户权限。", L"Mooji Cut", MB_OK | MB_ICONWARNING);
        }
        return TRUE;
    }
    return FALSE;
}

static INT_PTR CALLBACK shortcuts_page(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    (void)lp;
    if (message == WM_INITDIALOG) {
        int i;
        fill_shortcuts(window);
        for (i = 0; i < 3; i++) SetWindowSubclass(GetDlgItem(window, IDC_HOTKEY_CAPTURE + i), hotkey_recorder_proc, 1, 0);
        if (shortcut_registration_error[0]) SetDlgItemTextW(window, IDC_SHORTCUT_STATUS, shortcut_registration_error);
        return TRUE;
    }
    if (message == WM_COMMAND) {
        int id = LOWORD(wp);
        if (id >= IDC_HOTKEY_CAPTURE && id <= IDC_HOTKEY_STOP && HIWORD(wp) == EN_CHANGE) {
            update_shortcuts(window);
            return TRUE;
        }
        if (HIWORD(wp) == BN_CLICKED && id >= IDC_CLEAR_CAPTURE && id <= IDC_CLEAR_STOP) {
            SendDlgItemMessageW(window, IDC_HOTKEY_CAPTURE + id - IDC_CLEAR_CAPTURE, HKM_SETHOTKEY, 0, 0);
            update_shortcuts(window);
            return TRUE;
        }
        if (id == IDC_RESET_SHORTCUTS && HIWORD(wp) == BN_CLICKED) {
            int i;
            updating = TRUE;
            for (i = 0; i < 3; i++) SendDlgItemMessageW(window, IDC_HOTKEY_CAPTURE + i, HKM_SETHOTKEY, DEFAULT_KEYS[i], 0);
            updating = FALSE;
            update_shortcuts(window);
            return TRUE;
        }
    }
    return FALSE;
}

static int tool_page_group(HWND page) {
    int group = (int)SendDlgItemMessageW(page, IDC_TOOL_GROUP, CB_GETCURSEL, 0, 0);
    return group >= 0 && group <= 2 ? group : 0;
}
static int tool_neighbor(int group, int index, int direction) {
    int count = tool_registry_snapshot_count(tool_snapshot, group);
    int slot = tool_registry_snapshot_value(tool_snapshot, group, index, MC_TOOL_SLOT);
    for (int i = index + direction; i >= 0 && i < count; i += direction)
        if (tool_registry_snapshot_value(tool_snapshot, group, i, MC_TOOL_SLOT) == slot) return i;
    return -1;
}
static void refresh_tool_selection(HWND page) {
    int group = tool_page_group(page);
    int index = (int)SendDlgItemMessageW(page, IDC_TOOL_LIST, LB_GETCURSEL, 0, 0);
    BOOL valid = index >= 0 && index < tool_registry_snapshot_count(tool_snapshot, group);
    EnableWindow(GetDlgItem(page, IDC_TOOL_ENABLED), valid);
    CheckDlgButton(page, IDC_TOOL_ENABLED, valid &&
        tool_registry_snapshot_value(tool_snapshot, group, index, MC_TOOL_ENABLED) == 1 ? BST_CHECKED : BST_UNCHECKED);
    EnableWindow(GetDlgItem(page, IDC_TOOL_UP), valid && tool_neighbor(group, index, -1) >= 0);
    EnableWindow(GetDlgItem(page, IDC_TOOL_DOWN), valid && tool_neighbor(group, index, 1) >= 0);
    wchar_t *reason = valid ? copy_tool_text(tool_snapshot, group, index, MC_TOOL_UNAVAILABLE_REASON) : NULL;
    SetDlgItemTextW(page, IDC_TOOL_STATUS, reason && *reason ? reason :
        valid ? L"修改自动保存；上下调整同组顺序。" : L"暂无可管理项。");
    free(reason);
}
static void refresh_tools_page(HWND page, int selected) {
    if (selected < 0) selected = (int)SendDlgItemMessageW(page, IDC_TOOL_LIST, LB_GETCURSEL, 0, 0);
    int group = tool_page_group(page);
    SendDlgItemMessageW(page, IDC_TOOL_LIST, LB_RESETCONTENT, 0, 0);
    int count = tool_registry_snapshot_count(tool_snapshot, group);
    for (int i = 0; i < count; i++) {
        wchar_t *title = copy_tool_text(tool_snapshot, group, i, MC_TOOL_TITLE);
        BOOL enabled = tool_registry_snapshot_value(tool_snapshot, group, i, MC_TOOL_ENABLED) == 1;
        BOOL available = tool_registry_snapshot_value(tool_snapshot, group, i, MC_TOOL_AVAILABLE) == 1;
        BOOL finish = tool_registry_snapshot_value(tool_snapshot, group, i, MC_TOOL_SLOT) == MC_TOOL_SLOT_FINISH;
        wchar_t label[256];
        swprintf_s(label, ARRAYSIZE(label), L"%s  %.160s%s%s", enabled ? L"✓" : L"○", title ? title : L"",
            finish ? L" · 完成操作" : L"", available ? L"" : L" · 暂不可用");
        SendDlgItemMessageW(page, IDC_TOOL_LIST, LB_ADDSTRING, 0, (LPARAM)label);
        free(title);
    }
    if (count > 0) SendDlgItemMessageW(page, IDC_TOOL_LIST, LB_SETCURSEL,
        selected >= 0 && selected < count ? selected : 0, 0);
    refresh_tool_selection(page);
}
static INT_PTR CALLBACK tools_page(HWND page, UINT message, WPARAM wp, LPARAM lp) {
    if (message == WM_INITDIALOG) {
        tools_window = page;
        const wchar_t *groups[] = {L"截图工具", L"录制控制", L"录后编辑"};
        for (unsigned i = 0; i < ARRAYSIZE(groups); i++)
            SendDlgItemMessageW(page, IDC_TOOL_GROUP, CB_ADDSTRING, 0, (LPARAM)groups[i]);
        SendDlgItemMessageW(page, IDC_TOOL_GROUP, CB_SETCURSEL, 0, 0);
        refresh_tools_page(page, 0);
        return TRUE;
    }
    if (message == WM_DESTROY) { if (tools_window == page) tools_window = NULL; return TRUE; }
    if (message == WM_NOTIFY && ((NMHDR *)lp)->code == PSN_SETACTIVE) { refresh_tools_page(page, -1); return TRUE; }
    if (message != WM_COMMAND || tool_publishing) return FALSE;
    int control = LOWORD(wp);
    if (control == IDC_TOOL_GROUP && HIWORD(wp) == CBN_SELCHANGE) { refresh_tools_page(page, 0); return TRUE; }
    if (control == IDC_TOOL_LIST && HIWORD(wp) == LBN_SELCHANGE) { refresh_tool_selection(page); return TRUE; }
    if (HIWORD(wp) != BN_CLICKED || (control != IDC_TOOL_ENABLED && control != IDC_TOOL_UP && control != IDC_TOOL_DOWN)) return FALSE;
    int group = tool_page_group(page), index = (int)SendDlgItemMessageW(page, IDC_TOOL_LIST, LB_GETCURSEL, 0, 0);
    if (index < 0) return TRUE;
    moonbit_string_t id = tool_registry_snapshot_text(tool_snapshot, group, index, MC_TOOL_ID);
    int32_t candidate = 0;
    if (control == IDC_TOOL_ENABLED) candidate = tool_registry_snapshot_set_enabled(tool_snapshot, id,
        IsDlgButtonChecked(page, IDC_TOOL_ENABLED) == BST_CHECKED ? 1 : 0);
    else {
        int next = tool_neighbor(group, index, control == IDC_TOOL_UP ? -1 : 1);
        if (next >= 0) {
            int before_index = control == IDC_TOOL_UP ? next : tool_neighbor(group, next, 1);
            moonbit_string_t before = before_index >= 0 ?
                tool_registry_snapshot_text(tool_snapshot, group, before_index, MC_TOOL_ID) : moonbit_make_string_raw(0);
            candidate = tool_registry_snapshot_move(tool_snapshot, id, before);
            moonbit_decref(before);
        }
    }
    BOOL ok = publish_tools(candidate, TRUE);
    int selected = index;
    if (ok) for (int i = 0; i < tool_registry_snapshot_count(tool_snapshot, group); i++) {
        moonbit_string_t found = tool_registry_snapshot_text(tool_snapshot, group, i, MC_TOOL_ID);
        BOOL same = Moonbit_array_length(found) == Moonbit_array_length(id) &&
            !memcmp(found, id, (SIZE_T)Moonbit_array_length(id) * sizeof(wchar_t));
        moonbit_decref(found);
        if (same) { selected = i; break; }
    }
    moonbit_decref(id);
    refresh_tools_page(page, selected);
    if (!ok) SetDlgItemTextW(page, IDC_TOOL_STATUS, L"修改未保存；请先完成截图输入/拖动，并检查设置写入权限。");
    return TRUE;
}

static void refresh_pin_page(HWND window) {
    BOOL enabled = mc_pin_enabled();
    for (int i = 0; i < 6; i++) EnableWindow(GetDlgItem(window, IDC_PIN_ZOOM_IN + i), enabled);
    EnableWindow(GetDlgItem(window, IDC_PIN_RESET), enabled);
    SetDlgItemTextW(window, IDC_PIN_STATUS, enabled ? L"隐藏/恢复与穿透按键可跨应用使用。" : L"贴图已停用，请先在通用页启用。");
}
static INT_PTR CALLBACK pins_page(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    if (message == WM_INITDIALOG) {
        updating = TRUE;
        for (int i = 0; i < 6; i++) {
            SendDlgItemMessageW(window, IDC_PIN_ZOOM_IN + i, HKM_SETRULES, 0, 0);
            SendDlgItemMessageW(window, IDC_PIN_ZOOM_IN + i, HKM_SETHOTKEY, mc_pin_key(i), 0);
            SetWindowSubclass(GetDlgItem(window, IDC_PIN_ZOOM_IN + i), hotkey_recorder_proc, 1, 0);
        }
        updating = FALSE;
        refresh_pin_page(window);
        return TRUE;
    }
    if (message == WM_NOTIFY && ((NMHDR *)lp)->code == PSN_SETACTIVE) {
        refresh_pin_page(window);
        return TRUE;
    }
    if (message == WM_COMMAND) {
        int id = LOWORD(wp);
        WORD proposed[6];
        if (id == IDC_PIN_RESET && HIWORD(wp) == BN_CLICKED) {
            mc_pin_default_keys(proposed);
            updating = TRUE;
            for (int i = 0; i < 6; i++) SendDlgItemMessageW(window, IDC_PIN_ZOOM_IN + i, HKM_SETHOTKEY, proposed[i], 0);
            updating = FALSE;
        } else if (!(id >= IDC_PIN_ZOOM_IN && id < IDC_PIN_ZOOM_IN + 6 && HIWORD(wp) == EN_CHANGE)) return FALSE;
        if (updating) return TRUE;
        for (int i = 0; i < 6; i++) proposed[i] = (WORD)SendDlgItemMessageW(window, IDC_PIN_ZOOM_IN + i, HKM_GETHOTKEY, 0, 0);
        SetDlgItemTextW(window, IDC_PIN_STATUS, mc_pin_save_keys(registry_path, proposed) ?
            L"已保存；隐藏/恢复与穿透按键可跨应用使用。" : L"未保存：按键冲突、穿透未关闭或无法写入。");
        return TRUE;
    }
    return FALSE;
}

static INT_PTR CALLBACK about_page(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    (void)wp; (void)lp;
    if (message == WM_INITDIALOG) {
        SetDlgItemTextW(window, IDC_VERSION, WIDE(MOOJICUT_VERSION) L" · Windows x64");
        SetDlgItemTextW(window, IDC_CORE_STATUS, core_ok ? L"MoonBit native 核心已连接" : L"MoonBit 核心检查失败");
        return TRUE;
    }
    return FALSE;
}

static void refresh_updates_page(HWND window) {
    SetDlgItemTextW(window, IDC_UPDATE_STATUS, mc_updates_status());
    BOOL busy = mc_updates_busy();
    EnableWindow(GetDlgItem(window, IDC_UPDATE_CHECK), !busy);
    EnableWindow(GetDlgItem(window, IDC_UPDATE_DOWNLOAD), !busy && mc_updates_available());
    EnableWindow(GetDlgItem(window, IDC_UPDATE_CANCEL), busy);
    EnableWindow(GetDlgItem(window, IDC_UPDATE_OPEN), mc_updates_downloaded());
}
static INT_PTR CALLBACK updates_page(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    if (message == WM_INITDIALOG) { refresh_updates_page(window); return TRUE; }
    if (message == WM_NOTIFY && ((NMHDR *)lp)->code == PSN_SETACTIVE) {
        refresh_updates_page(window);
        return TRUE;
    }
    if (message == WM_COMMAND && HIWORD(wp) == BN_CLICKED) {
        if (LOWORD(wp) == IDC_UPDATE_CHECK) mc_updates_check();
        else if (LOWORD(wp) == IDC_UPDATE_DOWNLOAD) mc_updates_download(window);
        else if (LOWORD(wp) == IDC_UPDATE_CANCEL) mc_updates_cancel();
        else if (LOWORD(wp) == IDC_UPDATE_OPEN) mc_updates_open_location();
        else return FALSE;
        refresh_updates_page(window);
        return TRUE;
    }
    return FALSE;
}

static LRESULT CALLBACK settings_subclass(HWND window, UINT message, WPARAM wp, LPARAM lp, UINT_PTR id, DWORD_PTR data) {
    (void)id; (void)data;
    if (message == WM_CLOSE || (message == WM_COMMAND && (LOWORD(wp) == IDOK || LOWORD(wp) == IDCANCEL))) {
        DestroyWindow(window);
        return 0;
    }
    if (message == WM_NCDESTROY) {
        RemoveWindowSubclass(window, settings_subclass, SETTINGS_SUBCLASS);
        settings = NULL;
        PostMessageW(host, WM_REFRESH_SHORTCUTS, 0, 0);
    }
    return DefSubclassProc(window, message, wp, lp);
}

static BOOL show_settings(void) {
    if (!settings) {
        PROPSHEETPAGEW pages[6];
        PROPSHEETHEADERW header;
        const DLGPROC procedures[6] = {general_page, shortcuts_page, about_page, pins_page, updates_page, tools_page};
        int i;
        ZeroMemory(pages, sizeof(pages));
        for (i = 0; i < 6; i++) {
            pages[i].dwSize = sizeof(pages[i]);
            pages[i].dwFlags = PSP_DEFAULT;
            pages[i].hInstance = instance;
            pages[i].pszTemplate = MAKEINTRESOURCEW(IDD_GENERAL + i);
            pages[i].pfnDlgProc = procedures[i];
        }
        ZeroMemory(&header, sizeof(header));
        header.dwSize = sizeof(header);
        header.dwFlags = PSH_PROPSHEETPAGE | PSH_MODELESS | PSH_NOAPPLYNOW | PSH_NOCONTEXTHELP;
        header.hwndParent = host;
        header.hInstance = instance;
        header.pszCaption = L"Mooji Cut 设置";
        header.nPages = 6;
        header.ppsp = pages;
        settings = (HWND)PropertySheetW(&header);
        if (settings == (HWND)-1) settings = NULL;
        if (!settings) return FALSE;
        SetWindowSubclass(settings, settings_subclass, SETTINGS_SUBCLASS, 0);
        SendMessageW(settings, WM_SETICON, ICON_BIG, (LPARAM)app_icon);
        SendMessageW(settings, WM_SETICON, ICON_SMALL, (LPARAM)app_icon);
        SetDlgItemTextW(settings, IDOK, L"关闭");
        ShowWindow(GetDlgItem(settings, IDCANCEL), SW_HIDE);
    }
    ShowWindow(settings, SW_SHOWNORMAL);
    SetForegroundWindow(settings);
    return TRUE;
}

static BOOL add_tray(void) {
    ZeroMemory(&tray, sizeof(tray));
    tray.cbSize = sizeof(tray);
    tray.hWnd = host;
    tray.uID = 1;
    tray.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    tray.uCallbackMessage = WM_TRAY;
    tray.hIcon = app_icon;
    wcscpy_s(tray.szTip, ARRAYSIZE(tray.szTip), L"Mooji Cut · 设置与快捷键");
    tray_added = Shell_NotifyIconW(NIM_ADD, &tray);
    if (tray_added) {
        tray.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, &tray);
    }
    return tray_added;
}

static void tray_menu(void) {
    HMENU menu = CreatePopupMenu();
    POINT point;
    UINT chosen;
    if (!menu) return;
    AppendMenuW(menu, MF_STRING, IDM_CAPTURE, L"截图…");
    AppendMenuW(menu, MF_STRING | (mc_recording_busy() ? MF_GRAYED : 0), IDM_RECORD, L"框选录屏（无声音）…");
    AppendMenuW(menu, MF_STRING | ((mc_recording_recording() || mc_recording_preparing()) ? 0 : MF_GRAYED), IDM_STOP_RECORD,
        mc_recording_preparing() ? L"取消本次录屏" : L"停止录屏并编辑");
    AppendMenuW(menu, MF_STRING | (mc_recording_busy() ? MF_GRAYED : 0), IDM_RESUME_RECORD, L"继续编辑上次录屏…");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    UINT pin_flags = MF_STRING | (mc_pin_enabled() ? 0 : MF_GRAYED);
    AppendMenuW(menu, pin_flags, IDM_RESTORE_PINS, L"恢复隐藏的贴图");
    AppendMenuW(menu, pin_flags, IDM_EXIT_PIN_PASSTHROUGH, L"关闭鼠标穿透");
    AppendMenuW(menu, pin_flags, IDM_CLOSE_PINS, L"关闭可交互的贴图");
    AppendMenuW(menu, MF_STRING, IDM_SETTINGS, L"设置…");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, IDM_QUIT, L"退出 Mooji Cut");
    SetMenuDefaultItem(menu, IDM_SETTINGS, FALSE);
    GetCursorPos(&point);
    SetForegroundWindow(host);
    chosen = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, host, NULL);
    PostMessageW(host, WM_NULL, 0, 0);
    DestroyMenu(menu);
    if (chosen == IDM_CAPTURE) start_capture();
    else if (chosen == IDM_RECORD) start_recording();
    else if (chosen == IDM_STOP_RECORD) mc_recording_stop();
    else if (chosen == IDM_RESUME_RECORD) mc_recording_resume_last(instance, host);
    else if (chosen == IDM_RESTORE_PINS) mc_pins_restore_hidden();
    else if (chosen == IDM_EXIT_PIN_PASSTHROUGH) mc_pins_exit_passthrough();
    else if (chosen == IDM_CLOSE_PINS) mc_pins_close();
    else if (chosen == IDM_SETTINGS) show_settings();
    else if (chosen == IDM_QUIT) PostMessageW(host, WM_CLOSE, 0, 0);
}

static LRESULT CALLBACK host_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    if (message == taskbar_created && taskbar_created != 0 && !smoke_mode) {
        if (!add_tray()) show_settings();
        return 0;
    }
    switch (message) {
    case WM_HOTKEY:
        // Tests register real, uncommon shortcuts but never capture the desktop.
        if (smoke_mode) return 0;
        if (wp == CAPTURE_HOTKEY) start_capture();
        else if (wp == RECORD_HOTKEY) start_recording();
        else if (wp == STOP_HOTKEY) { KillTimer(window, RECORD_TIMER); mc_recording_stop(); }
        return 0;
    case WM_REFRESH_SHORTCUTS: refresh_global_shortcuts(); return 0;
    case WM_TIMER:
        if (smoke_mode && (wp == CAPTURE_TIMER || wp == RECORD_TIMER)) {
            KillTimer(window, (UINT_PTR)wp); return 0;
        }
        if (wp == CAPTURE_TIMER) {
            KillTimer(window, CAPTURE_TIMER);
            if (update_exit_pending) return 0;
            if (!mc_capture_start(instance, host, &capture_services)) MessageBoxW(host,
                L"无法读取当前桌面。请退出安全桌面或远程会话限制后重试。", L"Mooji Cut", MB_OK | MB_ICONWARNING);
        }
        if (wp == RECORD_TIMER) { KillTimer(window, RECORD_TIMER); if (!update_exit_pending && !mc_capture_busy()) mc_recording_start(instance, host); }
        return 0;
    case MOOJICUT_RECORDING_STATE_CHANGED:
        if (tray_added) {
            wcscpy_s(tray.szTip, ARRAYSIZE(tray.szTip), mc_recording_recording() ? L"Mooji Cut · 录屏中，请使用停止录屏快捷键结束" : L"Mooji Cut · 截图与录屏");
            Shell_NotifyIconW(NIM_MODIFY, &tray);
        }
        return 0;
    case WM_TRAY:
        switch (LOWORD(lp)) {
        case WM_CONTEXTMENU: tray_menu(); break;
        case NIN_SELECT: case NIN_KEYSELECT: case WM_LBUTTONDBLCLK: show_settings(); break;
        }
        return 0;
    case WM_SHOW_SETTINGS: show_settings(); return 0;
    case MOOJICUT_UPDATES_CHANGED:
        if (settings) {
            HWND page = PropSheet_GetCurrentPageHwnd(settings);
            if (page && GetDlgItem(page, IDC_UPDATE_STATUS)) refresh_updates_page(page);
        }
        if (update_exit_pending && !mc_updates_busy()) PostMessageW(host, WM_CLOSE, 0, 0);
        return 0;
    case WM_CLOSE:
        if (mc_recording_busy()) {
            mc_recording_close();
            if (mc_recording_busy()) return 0;
        }
        update_exit_pending = TRUE;
        KillTimer(host, CAPTURE_TIMER);
        KillTimer(host, RECORD_TIMER);
        if (!mc_updates_prepare_close()) return 0;
        DestroyWindow(window); return 0;
    case WM_DESTROY:
        unregister_shortcuts();
        mc_capture_close();
        if (tool_snapshot) { tool_registry_snapshot_close(tool_snapshot); tool_snapshot = 0; }
        mc_pins_shutdown();
        mc_updates_shutdown();
        if (settings) DestroyWindow(settings);
        if (tray_added) Shell_NotifyIconW(NIM_DELETE, &tray);
        tray_added = FALSE;
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, wp, lp);
}

static BOOL save_smoke_screenshot(HWND window) {
    wchar_t path[32768];
    DWORD path_length = GetEnvironmentVariableW(L"MOOJICUT_SMOKE_SCREENSHOT", path, ARRAYSIZE(path));
    RECT bounds;
    HDC screen = NULL, memory = NULL;
    HBITMAP bitmap = NULL;
    HGDIOBJ previous = NULL;
    BITMAPINFO info;
    BITMAPFILEHEADER header;
    BYTE *pixels = NULL;
    HANDLE file = INVALID_HANDLE_VALUE;
    DWORD size, written;
    int width, height;
    BOOL passed = FALSE;
    if (path_length == 0) return TRUE;
    if (path_length >= ARRAYSIZE(path) || !GetWindowRect(window, &bounds)) return FALSE;
    width = bounds.right - bounds.left;
    height = bounds.bottom - bounds.top;
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) return FALSE;
    size = (DWORD)width * (DWORD)height * 4;
    ZeroMemory(&info, sizeof(info));
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    screen = GetWindowDC(window);
    if (!screen) goto cleanup;
    memory = CreateCompatibleDC(screen);
    bitmap = CreateCompatibleBitmap(screen, width, height);
    if (!memory || !bitmap) goto cleanup;
    previous = SelectObject(memory, bitmap);
    RedrawWindow(window, NULL, NULL, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
    if (!PrintWindow(window, memory, 0) && !BitBlt(memory, 0, 0, width, height, screen, 0, 0, SRCCOPY)) goto cleanup;
    SelectObject(memory, previous);
    previous = NULL;
    pixels = HeapAlloc(GetProcessHeap(), 0, size);
    if (!pixels || !GetDIBits(memory, bitmap, 0, (UINT)height, pixels, &info, DIB_RGB_COLORS)) goto cleanup;
    ZeroMemory(&header, sizeof(header));
    header.bfType = 0x4D42;
    header.bfOffBits = sizeof(header) + sizeof(BITMAPINFOHEADER);
    header.bfSize = header.bfOffBits + size;
    file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) goto cleanup;
    passed = WriteFile(file, &header, sizeof(header), &written, NULL) && written == sizeof(header) &&
        WriteFile(file, &info.bmiHeader, sizeof(BITMAPINFOHEADER), &written, NULL) && written == sizeof(BITMAPINFOHEADER) &&
        WriteFile(file, pixels, size, &written, NULL) && written == size;
cleanup:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (pixels) HeapFree(GetProcessHeap(), 0, pixels);
    if (previous) SelectObject(memory, previous);
    if (bitmap) DeleteObject(bitmap);
    if (memory) DeleteDC(memory);
    if (screen) ReleaseDC(window, screen);
    return passed;
}

static BOOL run_shortcut_smoke(HWND page) {
    WORD saved[3];
    HWND previous_focus = GetFocus(), recorder = GetDlgItem(page, IDC_HOTKEY_CAPTURE);
    HWND neutral = GetDlgItem(settings, IDOK);
    MSG message;
    BOOL passed = FALSE;
    int i;
    const BYTE modifiers = HOTKEYF_CONTROL | HOTKEYF_ALT | HOTKEYF_SHIFT;
    if (!smoke_mode || !recorder || !neutral) return FALSE;
    for (i = 0; i < 3; i++) saved[i] = hotkeys[i];
    unregister_shortcuts();
    smoke_shortcut_registration = TRUE;
    for (i = 0; i < 3; i++) hotkeys[i] = MAKEWORD(VK_F17 + i, modifiers);
    SetFocus(neutral);
    if (GetFocus() != neutral) { fprintf(stderr, "Hotkey smoke: cannot focus neutral control.\n"); goto cleanup; }
    refresh_global_shortcuts();
    if (!global_registered[0] || !global_registered[1] || !global_registered[2]) goto cleanup;
    SetFocus(recorder);
    if (GetFocus() != recorder || global_registered[0] || global_registered[1] || global_registered[2]) {
        fprintf(stderr, "Hotkey smoke: entering recorder did not suspend all shortcuts.\n"); goto cleanup;
    }
    SetFocus(neutral);
    if (GetFocus() != neutral) { fprintf(stderr, "Hotkey smoke: cannot leave recorder.\n"); goto cleanup; }
    while (PeekMessageW(&message, host, WM_REFRESH_SHORTCUTS, WM_REFRESH_SHORTCUTS, PM_REMOVE))
        DispatchMessageW(&message);
    if (!global_registered[0] || !global_registered[1] || !global_registered[2]) {
        fprintf(stderr, "Hotkey smoke: leaving recorder did not restore all shortcuts.\n"); goto cleanup;
    }
    hotkeys[1] = 0;
    refresh_global_shortcuts();
    if (!global_registered[0] || global_registered[1] || !global_registered[2]) {
        fprintf(stderr, "Hotkey smoke: disabled recording shortcut was registered.\n"); goto cleanup;
    }
    // Exercise the smoke guard without synthesizing or sending user input.
    for (i = 0; i < 3; i++) SendMessageW(host, WM_HOTKEY, CAPTURE_HOTKEY + i, 0);
    passed = !mc_capture_busy() && !mc_recording_busy();
    if (!passed) fprintf(stderr, "Hotkey smoke: test events started a capture operation.\n");
cleanup:
    unregister_shortcuts();
    smoke_shortcut_registration = FALSE;
    for (i = 0; i < 3; i++) hotkeys[i] = saved[i];
    shortcut_registration_error[0] = L'\0';
    if (previous_focus && IsWindow(previous_focus)) SetFocus(previous_focus);
    printf("Windows global shortcut smoke: %s (real registration, focus suspend/resume, disabled action).\n",
        passed ? "passed" : "FAILED");
    return passed;
}

static BOOL smoke_saved_tool_layout_matches(int32_t snapshot) {
    moonbit_string_t layout = tool_registry_snapshot_layout(snapshot);
    DWORD expected = (DWORD)Moonbit_array_length(layout) * sizeof(wchar_t), bytes = expected;
    BYTE *saved = malloc(expected ? expected : 1);
    BOOL matches = saved && expected && RegGetValueW(HKEY_CURRENT_USER, registry_path, L"ToolLayout", RRF_RT_REG_BINARY,
        NULL, saved, &bytes) == ERROR_SUCCESS && bytes == expected && !memcmp(saved, layout, expected);
    free(saved); moonbit_decref(layout);
    return matches;
}
static BOOL smoke_pin_draining_transaction(void) {
    /* Called inside the real pin menu callback after disable destroys its
     * window, while TrackPopupMenu still owns the retirement lease. */
    if (!set_pin_enabled(FALSE)) return FALSE;
    int32_t previous = tool_snapshot;
    unsigned saves = smoke_tool_save_attempts;
    BOOL persisted_before = smoke_saved_tool_layout_matches(previous);
    BOOL rejected = !set_pin_enabled(TRUE);
    int pin = find_tool_action(tool_snapshot, L"pin");
    BOOL ok = persisted_before && rejected && tool_snapshot == previous && smoke_tool_save_attempts == saves &&
        pin >= 0 && tool_registry_snapshot_value(tool_snapshot, 0, pin, MC_TOOL_ENABLED) == 0 &&
        !mc_pin_enabled() && smoke_saved_tool_layout_matches(previous);
    printf("Windows pin settings drain smoke %s: real menu lease rejects enable before disk or snapshot publication.\n", ok ? "passed" : "FAILED");
    return ok;
}

static int run_smoke(void) {
    HWND page, first;
    WORD changed = MAKEWORD(VK_F6, HOTKEYF_CONTROL);
    int passed = 0;
    RegDeleteTreeW(HKEY_CURRENT_USER, registry_path);
    load_preferences();
    if (!show_settings()) goto cleanup;
    first = settings;
    page = PropSheet_GetCurrentPageHwnd(settings);
    if (!mc_pin_enabled() || !GetDlgItem(page, IDC_PIN_ENABLED)) goto cleanup;
    CheckDlgButton(page, IDC_PIN_ENABLED, BST_UNCHECKED);
    SendMessageW(page, WM_COMMAND, MAKEWPARAM(IDC_PIN_ENABLED, BN_CLICKED), 0);
    load_preferences();
    if (mc_pin_enabled()) goto cleanup;
    CheckDlgButton(page, IDC_PIN_ENABLED, BST_CHECKED);
    SendMessageW(page, WM_COMMAND, MAKEWPARAM(IDC_PIN_ENABLED, BN_CLICKED), 0);
    load_preferences();
    if (!mc_pin_enabled()) goto cleanup;
    if (!show_settings() || settings != first) goto cleanup;
    PropSheet_SetCurSel(settings, NULL, 1);
    page = PropSheet_GetCurrentPageHwnd(settings);
    if (!page || !GetDlgItem(page, IDC_HOTKEY_CAPTURE)) goto cleanup;
    SendDlgItemMessageW(page, IDC_HOTKEY_CAPTURE, HKM_SETHOTKEY, changed, 0);
    update_shortcuts(page);
    if (hotkeys[0] != changed) goto cleanup;
    SendDlgItemMessageW(page, IDC_HOTKEY_RECORD, HKM_SETHOTKEY, changed, 0);
    update_shortcuts(page);
    if (hotkeys[1] != DEFAULT_KEYS[1]) goto cleanup;
    SendDlgItemMessageW(page, IDC_HOTKEY_RECORD, HKM_SETHOTKEY, 0, 0);
    update_shortcuts(page);
    if (hotkeys[1] != 0) goto cleanup;
    SendMessageW(settings, WM_CLOSE, 0, 0);
    if (settings != NULL) goto cleanup;
    load_preferences();
    if (hotkeys[0] != changed || hotkeys[1] != 0 || !show_settings()) goto cleanup;
    PropSheet_SetCurSel(settings, NULL, 1);
    page = PropSheet_GetCurrentPageHwnd(settings);
    if ((WORD)SendDlgItemMessageW(page, IDC_HOTKEY_CAPTURE, HKM_GETHOTKEY, 0, 0) != changed) goto cleanup;
    SendMessageW(page, WM_COMMAND, MAKEWPARAM(IDC_RESET_SHORTCUTS, BN_CLICKED), 0);
    if (hotkeys[0] != DEFAULT_KEYS[0] || hotkeys[1] != DEFAULT_KEYS[1]) goto cleanup;
    if (!run_shortcut_smoke(page)) goto cleanup;
    PropSheet_SetCurSel(settings, NULL, 2);
    page = PropSheet_GetCurrentPageHwnd(settings);
    if (!page || !GetDlgItem(page, IDC_CORE_STATUS)) goto cleanup;
    PropSheet_SetCurSel(settings, NULL, 3);
    page = PropSheet_GetCurrentPageHwnd(settings);
    if (!page || !GetDlgItem(page, IDC_PIN_ZOOM_IN)) goto cleanup;
    SendDlgItemMessageW(page, IDC_PIN_ZOOM_IN, HKM_SETHOTKEY, MAKEWORD(VK_F8, HOTKEYF_CONTROL), 0);
    SendMessageW(page, WM_COMMAND, MAKEWPARAM(IDC_PIN_ZOOM_IN, EN_CHANGE), 0);
    if (mc_pin_key(0) != MAKEWORD(VK_F8, HOTKEYF_CONTROL)) goto cleanup;
    mc_pin_load_keys(registry_path);
    if (mc_pin_key(0) != MAKEWORD(VK_F8, HOTKEYF_CONTROL)) goto cleanup;
    SendMessageW(page, WM_COMMAND, MAKEWPARAM(IDC_PIN_RESET, BN_CLICKED), 0);
    if (mc_pin_key(0) != VK_OEM_PLUS) goto cleanup;
    PropSheet_SetCurSel(settings, NULL, 5);
    page = PropSheet_GetCurrentPageHwnd(settings);
    if (!page || SendDlgItemMessageW(page, IDC_TOOL_LIST, LB_GETCOUNT, 0, 0) < 9) goto cleanup;
    SendDlgItemMessageW(page, IDC_TOOL_LIST, LB_SETCURSEL, 0, 0);
    SendMessageW(page, WM_COMMAND, MAKEWPARAM(IDC_TOOL_LIST, LBN_SELCHANGE), 0);
    moonbit_string_t first_id = tool_registry_snapshot_text(tool_snapshot, 0, 0, MC_TOOL_ID);
    int32_t before_failure = tool_snapshot;
    smoke_fail_tool_save = TRUE;
    CheckDlgButton(page, IDC_TOOL_ENABLED, BST_UNCHECKED);
    SendMessageW(page, WM_COMMAND, MAKEWPARAM(IDC_TOOL_ENABLED, BN_CLICKED), 0);
    smoke_fail_tool_save = FALSE;
    BOOL tools_ok = tool_snapshot == before_failure &&
        tool_registry_snapshot_value(tool_snapshot, 0, 0, MC_TOOL_ENABLED) == 1 &&
        IsDlgButtonChecked(page, IDC_TOOL_ENABLED) == BST_CHECKED;
    CheckDlgButton(page, IDC_TOOL_ENABLED, BST_UNCHECKED);
    SendMessageW(page, WM_COMMAND, MAKEWPARAM(IDC_TOOL_ENABLED, BN_CLICKED), 0);
    tools_ok = tool_registry_snapshot_value(tool_snapshot, 0, 0, MC_TOOL_ENABLED) == 0 && tools_ok;
    load_preferences();
    tools_ok = tool_registry_snapshot_value(tool_snapshot, 0, 0, MC_TOOL_ENABLED) == 0 && tools_ok;
    refresh_tools_page(page, 0);
    CheckDlgButton(page, IDC_TOOL_ENABLED, BST_CHECKED);
    SendMessageW(page, WM_COMMAND, MAKEWPARAM(IDC_TOOL_ENABLED, BN_CLICKED), 0);
    SendMessageW(page, WM_COMMAND, MAKEWPARAM(IDC_TOOL_DOWN, BN_CLICKED), 0);
    int selected = (int)SendDlgItemMessageW(page, IDC_TOOL_LIST, LB_GETCURSEL, 0, 0);
    moonbit_string_t moved = tool_registry_snapshot_text(tool_snapshot, 0, selected, MC_TOOL_ID);
    tools_ok = selected > 0 && Moonbit_array_length(first_id) == Moonbit_array_length(moved) &&
        !memcmp(first_id, moved, (SIZE_T)Moonbit_array_length(first_id) * sizeof(wchar_t)) && tools_ok;
    moonbit_decref(moved); moonbit_decref(first_id);
    SendMessageW(page, WM_COMMAND, MAKEWPARAM(IDC_TOOL_UP, BN_CLICKED), 0);
    tools_ok = SendDlgItemMessageW(page, IDC_TOOL_LIST, LB_GETCURSEL, 0, 0) == 0 && tools_ok;
    printf("Windows tool settings smoke %s: shared rows, save failure rollback, enabled persistence and ordering.\n", tools_ok ? "passed" : "FAILED");
    if (!tools_ok) goto cleanup;
    passed = core_ok && save_smoke_screenshot(settings);
cleanup:
    if (settings) DestroyWindow(settings);
    RegDeleteTreeW(HKEY_CURRENT_USER, registry_path);
    printf("Windows settings smoke: %s\n", passed ? "passed" : "FAILED");
    return passed ? 0 : 1;
}

int WINAPI wWinMain(HINSTANCE application, HINSTANCE previous, PWSTR command, int show) {
    INITCOMMONCONTROLSEX controls = {sizeof(controls), ICC_WIN95_CLASSES | ICC_HOTKEY_CLASS};
    WNDCLASSEXW klass;
    MSG message;
    HANDLE mutex = NULL;
    BOOL preferences_requested = FALSE, self_test = FALSE;
    int count, i, result = 0;
    wchar_t **args = CommandLineToArgvW(GetCommandLineW(), &count);
    (void)previous; (void)command; (void)show;
    for (i = 1; args && i < count; i++) {
        if (wcscmp(args[i], L"--self-test") == 0) self_test = TRUE;
        else if (wcscmp(args[i], L"--smoke") == 0) smoke_mode = TRUE;
        else if (wcscmp(args[i], L"--preferences") == 0) preferences_requested = TRUE;
    }
    if (args) LocalFree(args);
    moonbit_init();
    core_ok = preview_core_check() == 1;
    if (self_test) {
        for (i = 0; i < 1000 && core_ok; i++) core_ok = preview_core_check() == 1;
        return core_ok ? 0 : 1;
    }
    if (!core_ok) {
        if (smoke_mode) fprintf(stderr, "MoonBit core check failed.\n");
        else MessageBoxW(NULL, L"MoonBit 核心初始化失败。请重新解压完整的预览包。", L"Mooji Cut", MB_OK | MB_ICONERROR);
        return 1;
    }
    if (smoke_mode) {
        _snwprintf_s(registry_path, ARRAYSIZE(registry_path), _TRUNCATE, L"Software\\MoojiCut.Smoke.%lu", GetCurrentProcessId());
    } else {
        mutex = CreateMutexW(NULL, FALSE, L"Local\\MoojiCut.Native.Preview");
        if (!mutex) return 1;
        if (GetLastError() == ERROR_ALREADY_EXISTS) {
            HWND existing = NULL;
            for (i = 0; i < 20 && !existing; i++) {
                existing = FindWindowW(HOST_CLASS, NULL);
                if (!existing) Sleep(100);
            }
            if (existing) {
                DWORD process_id;
                GetWindowThreadProcessId(existing, &process_id);
                AllowSetForegroundWindow(process_id);
                PostMessageW(existing, WM_SHOW_SETTINGS, 0, 0);
            }
            CloseHandle(mutex);
            return existing ? 0 : 1;
        }
    }
    instance = application;
    if (!InitCommonControlsEx(&controls)) { if (mutex) CloseHandle(mutex); return 1; }
    app_icon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_MOOJICUT));
    ZeroMemory(&klass, sizeof(klass));
    klass.cbSize = sizeof(klass);
    klass.hInstance = instance;
    klass.lpfnWndProc = host_proc;
    klass.lpszClassName = HOST_CLASS;
    klass.hIcon = app_icon;
    klass.hCursor = LoadCursorW(NULL, IDC_ARROW);
    if (!RegisterClassExW(&klass)) { if (mutex) CloseHandle(mutex); return 1; }
    host = CreateWindowExW(WS_EX_TOOLWINDOW, HOST_CLASS, L"Mooji Cut", WS_OVERLAPPED,
        CW_USEDEFAULT, CW_USEDEFAULT, 0, 0, NULL, NULL, instance, NULL);
    if (!host) { if (mutex) CloseHandle(mutex); return 1; }
    load_preferences();
    if (smoke_mode) {
        result = run_smoke();
        if (result == 0) result = mc_capture_smoke(instance);
        if (result == 0 && !mc_pin_smoke(instance, smoke_pin_draining_transaction)) result = 1;
        if (result == 0 && (!set_pin_enabled(TRUE) || !smoke_saved_tool_layout_matches(tool_snapshot))) result = 1;
        if (result == 0 && !mc_updates_smoke(instance)) result = 1;
        if (result == 0) result = mc_recording_smoke(instance);
        RegDeleteTreeW(HKEY_CURRENT_USER, registry_path);
        DestroyWindow(host);
    } else {
        if (!mc_updates_initialize(instance, host)) return 1;
        taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
        refresh_global_shortcuts();
        if (!add_tray() || preferences_requested || open_on_start) show_settings();
        while ((result = GetMessageW(&message, NULL, 0, 0)) > 0) {
            if (mc_capture_handle_message(&message)) continue;
            if (mc_recording_handle_message(&message)) continue;
            if (!settings || !PropSheet_IsDialogMessage(settings, &message)) {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
            if (settings && PropSheet_GetCurrentPageHwnd(settings) == NULL) DestroyWindow(settings);
        }
        result = result == -1 ? 1 : (int)message.wParam;
    }
    if (mutex) CloseHandle(mutex);
    return result;
}
