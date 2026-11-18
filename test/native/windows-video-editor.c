/* Real Win32 window -> shared MoonBit owner -> media worker integration.
 * SOURCE is produced by gst-media; this fixture never invents a playback clock
 * or a second native document. OUTPUT must be an isolated existing directory. */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <ole2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <math.h>
#include "platform/windows/app/video_editor.h"
#include "platform/windows/graphics/shared_canvas.h"
#include "platform/windows/media/runtime.h"
#include "platform/shared/app/video_editor_host.h"

static int failures;
static HWND closing_window;
static BOOL saw_dialog, close_was_async;
static ULONGLONG chooser_started;
static BOOL expected_storage_error;
static unsigned error_dialogs;
static BOOL quit_pending;
static unsigned reopened_notifications;
static HWND diagnostic_editor;
static const char *diagnostic_stage = "startup";
static ULONGLONG diagnostic_started, diagnostic_last;
static LRESULT CALLBACK owner_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    if (message == MC_WIN_VIDEO_EDITOR_CHANGED) {
        if (lp == MC_VIDEO_HOST_OPEN || lp == MC_VIDEO_HOST_FAILED) {
            quit_pending = FALSE; reopened_notifications++;
        }
        return 0;
    }
    return DefWindowProcW(window, message, wp, lp);
}
static void check(BOOL condition, const char *name) {
    printf("%s %s\n", condition ? "PASS" : "FAIL", name); fflush(stdout);
    if (!condition) failures++;
}
static const char *field(const char *json, const char *name) {
    char pattern[96]; sprintf_s(pattern, sizeof(pattern), "\"%s\":", name);
    const char *at = json ? strstr(json, pattern) : NULL;
    if (!at) return NULL;
    at += strlen(pattern); while (*at == ' ' || *at == '\n') at++; return at;
}
static double number(const char *json, const char *name) {
    const char *at = field(json, name); return at ? strtod(at, NULL) : -1;
}
static BOOL flag(const char *json, const char *name) {
    const char *at = field(json, name); return at && !strncmp(at, "true", 4);
}
/* Preserve progress even when a native modal loop never returns to the next
 * assertion. These diagnostics do not dismiss dialogs or change test state. */
static BOOL CALLBACK diagnostic_child(HWND window, LPARAM data) {
    unsigned *count = (unsigned *)data;
    if (++*count > 24) return FALSE;
    wchar_t name[96], title[256];
    GetClassNameW(window, name, ARRAYSIZE(name)); GetWindowTextW(window, title, ARRAYSIZE(title));
    printf("INFO dialog child id=%d class=%ls visible=%d enabled=%d text=%ls\n",
        GetDlgCtrlID(window), name, IsWindowVisible(window), IsWindowEnabled(window), title);
    return TRUE;
}
static BOOL CALLBACK diagnostic_window(HWND window, LPARAM data) {
    (void)data;
    if (!IsWindowVisible(window)) return TRUE;
    wchar_t name[96], title[256];
    GetClassNameW(window, name, ARRAYSIZE(name)); GetWindowTextW(window, title, ARRAYSIZE(title));
    printf("INFO thread window hwnd=%p owner=%p class=%ls enabled=%d title=%ls\n",
        (void *)window, (void *)GetWindow(window, GW_OWNER), name, IsWindowEnabled(window), title);
    if (!wcscmp(name, L"#32770")) {
        unsigned count = 0; EnumChildWindows(window, diagnostic_child, (LPARAM)&count);
    }
    return TRUE;
}
static void diagnose(void) {
    char *state = mc_win_video_editor_state(diagnostic_editor);
    printf("INFO stage=%s elapsed=%llums window=%d busy=%d phase=%.0f revision=%.0f ready=%d dirty=%d error=%.700s\n",
        diagnostic_stage, (unsigned long long)(GetTickCount64() - diagnostic_started),
        IsWindow(diagnostic_editor), mc_win_video_editor_busy(), number(state, "phase"),
        number(state, "revision"), flag(state, "mediaReady"), flag(state, "dirty"),
        state && field(state, "error") ? field(state, "error") : "none");
    mc_win_video_editor_text_free(state);
    EnumThreadWindows(GetCurrentThreadId(), diagnostic_window, 0);
    fflush(stdout); diagnostic_last = GetTickCount64();
}
static void stage(const char *name, HWND editor) {
    diagnostic_stage = name; diagnostic_editor = editor; diagnostic_started = GetTickCount64(); diagnose();
}
static void pump(unsigned milliseconds) {
    ULONGLONG until = GetTickCount64() + milliseconds;
    do {
        MSG message;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            if (!mc_win_video_editor_handle_message(&message)) { TranslateMessage(&message); DispatchMessageW(&message); }
        }
        if (GetTickCount64() < until) MsgWaitForMultipleObjects(0, NULL, FALSE, 2, QS_ALLINPUT);
    } while (GetTickCount64() < until);
}
static BOOL settled(HWND editor, double revision) {
    ULONGLONG until = GetTickCount64() + 45000;
    do {
        pump(5);
        char *state = mc_win_video_editor_state(editor);
        BOOL ready = state && number(state, "revision") == revision && flag(state, "mediaReady") && !flag(state, "dirty");
        mc_win_video_editor_text_free(state);
        if (ready) return TRUE;
    } while (IsWindow(editor) && GetTickCount64() < until);
    char *state = mc_win_video_editor_state(editor);
    fprintf(stderr, "Window settle timeout: %s\n", state ? state : "no state"); mc_win_video_editor_text_free(state);
    return FALSE;
}
static BOOL semantic_id(int32_t frame, int index, const wchar_t *id) {
    moonbit_string_t text = ui_frame_semantic_text(frame, index, MC_UI_SEM_ID);
    size_t length = wcslen(id);
    BOOL equal = (size_t)Moonbit_array_length(text) == length && !memcmp(text, id, length * sizeof(wchar_t));
    moonbit_decref(text); return equal;
}
static int semantic(int32_t frame, const wchar_t *id) {
    for (int i = 0; i < ui_frame_semantic_count(frame); i++) if (semantic_id(frame, i, id)) return i;
    return -1;
}
static BOOL matching_id(HWND editor, const wchar_t *prefix, BOOL skip_first, wchar_t *out, size_t capacity) {
    int32_t frame = mc_win_video_editor_frame_snapshot(editor); BOOL found = FALSE;
    for (int i = 0; i < ui_frame_semantic_count(frame); i++) {
        moonbit_string_t text = ui_frame_semantic_text(frame, i, MC_UI_SEM_ID);
        int length = Moonbit_array_length(text); size_t prefix_length = wcslen(prefix);
        if ((size_t)length >= prefix_length && (size_t)length < capacity && !memcmp(text, prefix, prefix_length * sizeof(wchar_t))) {
            if (skip_first) skip_first = FALSE;
            else { memcpy(out, text, (size_t)length * sizeof(wchar_t)); out[length] = 0; found = TRUE; }
        }
        moonbit_decref(text); if (found) break;
    }
    if (frame) ui_frame_close(frame); return found;
}
static BOOL point(HWND editor, const wchar_t *id, POINT *at, double *width) {
    int32_t frame = mc_win_video_editor_frame_snapshot(editor); int index = semantic(frame, id);
    BOOL valid = index >= 0 && ui_frame_semantic_value(frame, index, MC_UI_SEM_ENABLED) == 1;
    if (valid) {
        double scale = GetDpiForWindow(editor) / 96.0;
        double w = ui_frame_semantic_number(frame, index, MC_UI_SEM_WIDTH);
        at->x = (LONG)lround((ui_frame_semantic_number(frame, index, MC_UI_SEM_X) + w / 2) * scale);
        at->y = (LONG)lround((ui_frame_semantic_number(frame, index, MC_UI_SEM_Y) +
            ui_frame_semantic_number(frame, index, MC_UI_SEM_HEIGHT) / 2) * scale);
        if (width) *width = w;
    }
    if (frame) ui_frame_close(frame); return valid;
}
static HWND canvas(HWND editor) { return FindWindowExW(editor, NULL, L"MoojiCut.SharedCanvas", NULL); }
static BOOL click(HWND editor, const wchar_t *id) {
    POINT at; if (!point(editor, id, &at, NULL)) return FALSE;
    SendMessageW(canvas(editor), WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(at.x, at.y));
    SendMessageW(canvas(editor), WM_LBUTTONUP, 0, MAKELPARAM(at.x, at.y)); return TRUE;
}
static void key(HWND editor, WPARAM value, BOOL control) {
    BYTE previous[256], current[256]; GetKeyboardState(previous); memcpy(current, previous, sizeof(current));
    current[VK_CONTROL] = control ? 0x80 : 0; current[VK_MENU] = current[VK_SHIFT] = 0;
    SetKeyboardState(current); SetFocus(canvas(editor)); SendMessageW(canvas(editor), WM_KEYDOWN, value, 0); SetKeyboardState(previous);
}
static double revision(HWND editor) {
    char *state = mc_win_video_editor_state(editor); double result = number(state, "revision");
    mc_win_video_editor_text_free(state); return result;
}
static uint64_t hash(const wchar_t *path) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    uint64_t value = UINT64_C(14695981039346656037); unsigned char bytes[16384]; DWORD count;
    while (ReadFile(file, bytes, sizeof(bytes), &count, NULL) && count)
        for (DWORD i = 0; i < count; i++) value = (value ^ bytes[i]) * UINT64_C(1099511628211);
    CloseHandle(file); return value;
}
static BOOL screenshot(HWND editor, const wchar_t *path, BOOL require_video) {
    HWND child = canvas(editor); RECT bounds; GetClientRect(child, &bounds);
    int width = bounds.right, height = bounds.bottom;
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) return FALSE;
    HDC screen = GetDC(NULL), dc = CreateCompatibleDC(screen); BITMAPINFO info = {0}; void *pixels = NULL;
    info.bmiHeader.biSize = sizeof(info.bmiHeader); info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
    HBITMAP bitmap = dc ? CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, NULL, 0) : NULL; ReleaseDC(NULL, screen);
    if (!bitmap) { if (dc) DeleteDC(dc); return FALSE; }
    HGDIOBJ previous = SelectObject(dc, bitmap);
    BOOL ok = mc_win_canvas_paint(child, dc, &bounds, GetDpiForWindow(child));
    if (require_video) {
        int32_t frame = mc_win_video_editor_frame_snapshot(editor); double scale = GetDpiForWindow(child) / 96.0;
        int x = (int)lround((ui_frame_video_rect(frame, MC_UI_RECT_X) + ui_frame_video_rect(frame, MC_UI_RECT_WIDTH) / 2) * scale);
        int y = (int)lround((ui_frame_video_rect(frame, MC_UI_RECT_Y) + ui_frame_video_rect(frame, MC_UI_RECT_HEIGHT) / 2) * scale);
        COLORREF pixel = GetPixel(dc, x, y);
        ok = ok && pixel != CLR_INVALID && (GetRValue(pixel) > 100 || GetGValue(pixel) > 100 || GetBValue(pixel) > 100);
        if (frame) ui_frame_close(frame);
    }
    GdiFlush();
    BITMAPFILEHEADER header = {0}; header.bfType = 0x4d42;
    header.bfOffBits = sizeof(header) + sizeof(info.bmiHeader);
    DWORD bytes = (DWORD)width * (DWORD)height * 4; header.bfSize = header.bfOffBits + bytes;
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL); DWORD written;
    ok = file != INVALID_HANDLE_VALUE && WriteFile(file, &header, sizeof(header), &written, NULL) && written == sizeof(header) &&
        WriteFile(file, &info.bmiHeader, sizeof(info.bmiHeader), &written, NULL) && written == sizeof(info.bmiHeader) &&
        WriteFile(file, pixels, bytes, &written, NULL) && written == bytes && ok;
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    SelectObject(dc, previous); DeleteObject(bitmap); DeleteDC(dc); return ok;
}
static BOOL CALLBACK find_dialog(HWND window, LPARAM data) {
    (void)data; wchar_t name[64]; GetClassNameW(window, name, ARRAYSIZE(name));
    HWND owner = GetWindow(window, GW_OWNER);
    while (owner && owner != closing_window) owner = GetWindow(owner, GW_OWNER);
    if (!wcscmp(name, L"#32770") && IsWindowVisible(window) && owner == closing_window) {
        saw_dialog = TRUE; close_was_async = !mc_win_video_editor_request_close_all(TRUE); return FALSE;
    }
    return TRUE;
}
static void CALLBACK cancel_chooser(HWND window, UINT message, UINT_PTR id, DWORD time) {
    (void)window; (void)message; (void)id; (void)time;
    if (closing_window && !saw_dialog) EnumThreadWindows(GetCurrentThreadId(), find_dialog, 0);
    if (closing_window && !saw_dialog && GetTickCount64() - chooser_started > 10000)
        mc_win_video_editor_request_close_all(TRUE);
}
static BOOL wait_closed(void) {
    ULONGLONG until = GetTickCount64() + 45000;
    while (mc_win_video_editor_busy() && GetTickCount64() < until) pump(5);
    return !mc_win_video_editor_busy();
}
static BOOL CALLBACK dismiss_error(HWND window, LPARAM data) {
    (void)data;
    wchar_t name[64], title[128];
    GetClassNameW(window, name, ARRAYSIZE(name)); GetWindowTextW(window, title, ARRAYSIZE(title));
    if (wcscmp(name, L"#32770") || wcscmp(title, L"Mooji Cut") || !IsWindowVisible(window) ||
        GetWindowThreadProcessId(window, NULL) != GetCurrentThreadId()) return TRUE;
    HWND owner = GetWindow(window, GW_OWNER);
    BOOL owned = FALSE;
    for (unsigned depth = 0; owner && depth < 32; depth++, owner = GetWindow(owner, GW_OWNER)) {
        /* The final chooser has its own close/reentrancy assertion. Never let
         * the error-dialog helper satisfy that separate test accidentally. */
        if (owner == closing_window) return TRUE;
        char *state = mc_win_video_editor_state(owner);
        owned = state != NULL; mc_win_video_editor_text_free(state);
        if (owned) break;
    }
    if (!owned) return TRUE;
    /* Native TaskDialog buttons are not ordinary child HWNDs. Identify our
     * owned dialog, then use its documented button-ID message directly. */
    error_dialogs++;
    printf("INFO dismiss owned error dialog stage=%s expected=%d\n", diagnostic_stage, expected_storage_error);
    fflush(stdout);
    if (!expected_storage_error) check(FALSE, "unexpected native error dialog");
    PostMessageW(window, TDM_CLICK_BUTTON, IDCANCEL, 0);
    return TRUE;
}
static void CALLBACK dismiss_errors(HWND window, UINT message, UINT_PTR id, DWORD time) {
    (void)window; (void)message; (void)id; (void)time;
    if (GetTickCount64() - diagnostic_last >= 10000) diagnose();
    EnumThreadWindows(GetCurrentThreadId(), dismiss_error, 0);
}
static BOOL save_failed(HWND editor) {
    ULONGLONG until = GetTickCount64() + 15000;
    do {
        pump(5); char *state = mc_win_video_editor_state(editor); const char *error = field(state, "error");
        BOOL failed = state && flag(state, "dirty") && number(state, "phase") == 1 && error && *error == '"' && error[1] && error[1] != '"';
        mc_win_video_editor_text_free(state); if (failed) return TRUE;
    } while (IsWindow(editor) && GetTickCount64() < until);
    return FALSE;
}
int wmain(int argc, wchar_t **argv) {
    if (argc != 3) { fprintf(stderr, "usage: windows-video-editor SOURCE OUTPUT\n"); return 2; }
    wchar_t runtime_error[1024] = {0};
    if (!mc_win_media_runtime_init(runtime_error, ARRAYSIZE(runtime_error))) {
        fwprintf(stderr, L"Private runtime bootstrap failed: %ls\n", runtime_error); return 2;
    }
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    moonbit_init(); HRESULT initialized = OleInitialize(NULL); if (FAILED(initialized)) return 2;
    INITCOMMONCONTROLSEX controls = {sizeof(controls), ICC_WIN95_CLASSES}; InitCommonControlsEx(&controls);
    UINT_PTR errors = SetTimer(NULL, 0, 25, dismiss_errors);
    if (!errors) { OleUninitialize(); return 2; }
    CreateDirectoryW(argv[2], NULL);
    wchar_t draft[32768], image[32768];
    swprintf_s(draft, ARRAYSIZE(draft), L"%ls\\edit-v2.json", argv[2]);
    swprintf_s(image, ARRAYSIZE(image), L"%ls\\editor.bmp", argv[2]);
    if (GetFileAttributesW(draft) != INVALID_FILE_ATTRIBUTES) { fprintf(stderr, "Expected a fresh output directory\n"); KillTimer(NULL, errors); OleUninitialize(); return 2; }
    uint64_t original = hash(argv[1]); HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW owner_class = {0}; owner_class.hInstance = instance; owner_class.lpfnWndProc = owner_proc;
    owner_class.lpszClassName = L"MoojiCut.VideoEditorFixture.Owner"; RegisterClassW(&owner_class);
    HWND owner = CreateWindowExW(0, owner_class.lpszClassName, L"Fixture owner", WS_OVERLAPPED,
        0, 0, 0, 0, NULL, NULL, instance, NULL);
    HWND editor = mc_win_video_editor_open_ex(instance, owner, argv[1], draft, TRUE);
    stage("initial ready", editor);
    check(editor && mc_win_video_editor_busy(), "real editor opens and retains async host ownership");
    if (!editor || !settled(editor, 0)) { check(FALSE, "initial probe/apply/draft IO reaches ready"); goto done; }
    check(TRUE, "initial probe/apply/draft IO reaches ready");
    wchar_t peer_draft[32768]; swprintf_s(peer_draft, ARRAYSIZE(peer_draft), L"%ls\\peer-v2.json", argv[2]);
    stage("second editor ready", editor);
    HWND peer = mc_win_video_editor_open_ex(instance, owner, argv[1], peer_draft, TRUE);
    check(peer && settled(peer, 0), "a second real editor shares the executor with independent draft ownership");
    if (peer) {
        stage("second editor close", editor);
        SendMessageW(peer, WM_CLOSE, 0, 0); ULONGLONG deadline = GetTickCount64() + 15000;
        while (IsWindow(peer) && GetTickCount64() < deadline) pump(5);
        check(!IsWindow(peer) && IsWindow(editor) && mc_win_video_editor_busy(), "closing one window leaves the other editor live");
        mc_win_video_editor_activate(editor);
    }
    pump(100);
    stage("initial screenshot", editor);
    check(screenshot(editor, image, TRUE), "canvas paints actual decoded BGRA video and the shared UI");
    DWORD affinity = 0;
    check(GetWindowDisplayAffinity(editor, &affinity) && affinity == WDA_NONE, "editor remains capturable by screenshot tools");
    stage("clip selection and ruler seek", editor);
    check(click(editor, L"clip:v1") && click(editor, L"playhead"), "real clip selection and ruler seek input");
    pump(150);
    stage("split and durable save", editor);
    check(click(editor, L"project-split") && settled(editor, 1), "split goes through shared root, media apply, and saved draft");
    wchar_t second[256] = {0}, gap[256] = {0}; POINT at; double clip_width = 0;
    if (!matching_id(editor, L"clip:v", TRUE, second, ARRAYSIZE(second)) || !point(editor, second, &at, &clip_width)) {
        check(FALSE, "split exposes second video clip"); goto done;
    }
    int delta = MulDiv(100, (int)GetDpiForWindow(editor), 96);
    stage("drag cancellation", editor);
    SendMessageW(canvas(editor), WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(at.x, at.y));
    SendMessageW(canvas(editor), WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(at.x + delta, at.y));
    check(revision(editor) == 1 && GetCapture() == canvas(editor), "body drag previews without committing");
    SendMessageW(canvas(editor), WM_CANCELMODE, 0, 0);
    SendMessageW(canvas(editor), WM_LBUTTONUP, 0, MAKELPARAM(at.x + delta, at.y));
    check(revision(editor) == 1 && GetCapture() != canvas(editor), "cancel releases capture and prevents a late commit");
    stage("drag gap commit", editor);
    SendMessageW(canvas(editor), WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(at.x, at.y));
    SendMessageW(canvas(editor), WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(at.x + delta, at.y));
    SendMessageW(canvas(editor), WM_LBUTTONUP, 0, MAKELPARAM(at.x + delta, at.y));
    check(settled(editor, 2) && matching_id(editor, L"gap:", FALSE, gap, ARRAYSIZE(gap)), "body drag commits an actual gap and applies its media plan");
    long long gap_start = 0, gap_end = 0;
    if (swscanf_s(gap, L"gap:%lld:%lld", &gap_start, &gap_end) == 2) {
        char *state = mc_win_video_editor_state(editor); int linked = 0;
        const char *cursor = state;
        while (cursor && (cursor = field(cursor, "startTicks"))) { if ((long long)strtod(cursor, NULL) == gap_end) linked++; cursor++; }
        check(linked >= 2 && gap_end > gap_start, "video and linked audio move together in the authoritative document");
        mc_win_video_editor_text_free(state);
    } else check(FALSE, "gap has shared timeline bounds");
    stage("undo and viewport keys", editor);
    key(editor, 'Z', TRUE); check(settled(editor, 3), "Ctrl+Z restores the linked edit through the root session");
    POINT unused; double before = 0, after = 0;
    point(editor, second, &unused, &before); key(editor, VK_OEM_PLUS, TRUE); point(editor, second, &unused, &after);
    check(after > before, "Ctrl+plus changes shared timeline zoom"); key(editor, '0', TRUE);
    stage("automation undo", editor);
    check(mc_win_video_editor_command(editor, "{\"expectedRevision\":3,\"requestId\":\"window-undo\",\"op\":{\"type\":\"undo\"}}") && settled(editor, 4),
        "automation uses the same authoritative command and media lane");
    HANDLE locked = CreateFileW(draft, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    check(locked != INVALID_HANDLE_VALUE, "hold a real Windows file lock against draft replacement");
    if (locked != INVALID_HANDLE_VALUE) {
        stage("locked draft write", editor);
        expected_storage_error = TRUE;
        check(mc_win_video_editor_command(editor, "{\"expectedRevision\":4,\"requestId\":\"locked-redo\",\"op\":{\"type\":\"redo\"}}") && save_failed(editor),
            "real draft write failure retains the edited document");
        pump(100); quit_pending = TRUE; unsigned notified_before = reopened_notifications;
        stage("close with failed save", editor);
        BOOL pending = !mc_win_video_editor_request_close_all(TRUE);
        ULONGLONG wake_deadline = GetTickCount64() + 15000;
        while (quit_pending && GetTickCount64() < wake_deadline) pump(5);
        check(pending && !quit_pending && reopened_notifications > notified_before && save_failed(editor) && IsWindow(editor),
            "failed save during close keeps the window and shared session alive");
        CloseHandle(locked); pump(150);
        stage("retry durable save", editor);
        check(error_dialogs > 0 && mc_win_video_editor_retry(editor) && settled(editor, 5),
            "retry after releasing the lock durably saves the same document");
        expected_storage_error = FALSE;
    }
    stage("play pause and final screenshot", editor);
    check(click(editor, L"play"), "play enters actual media worker"); pump(180); check(click(editor, L"play"), "pause uses shared transport"); pump(100);
    check(screenshot(editor, image, TRUE), "final window screenshot contains decoded video after editing");
    stage("close before reopen", editor);
    check(!mc_win_video_editor_request_close_all(TRUE) && wait_closed(), "close waits for actual worker and draft drain");
    editor = mc_win_video_editor_open_ex(instance, owner, argv[1], draft, TRUE);
    stage("reopen saved revision", editor);
    check(editor && settled(editor, 5), "reopening restores the saved v2 revision without touching original media");
    if (editor && IsWindow(editor)) {
        stage("close during system export chooser", editor);
        closing_window = editor; chooser_started = GetTickCount64();
        UINT_PTR cancellation = SetTimer(NULL, 0, 10, cancel_chooser);
        check(cancellation && click(editor, L"export"), "shared export opens the actual system chooser");
        check(wait_closed() && saw_dialog && close_was_async, "close during modal chooser cancels ticket then drains without reentrant free");
        if (cancellation) KillTimer(NULL, cancellation); closing_window = NULL;
    }
done:
    stage("final resource drain", editor);
    mc_win_video_editor_request_close_all(TRUE); check(wait_closed(), "all editor resources are closed");
    check(original && original == hash(argv[1]), "preview edits and closure preserve original source bytes");
    if (owner) DestroyWindow(owner);
    KillTimer(NULL, errors); OleUninitialize(); printf("windows-video-editor: %d failure(s)\n", failures); return failures ? 1 : 0;
}
