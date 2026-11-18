#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include "platform/windows/app/video_editor.h"
#include "platform/windows/graphics/shared_canvas.h"
#include "platform/shared/app/video_editor_host.h"
#include <commctrl.h>
#include <shobjidl.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <math.h>

#define EDITOR_CANVAS 1801
#define EDITOR_SHOW_CHOOSER (WM_APP + 0x671)
#define EDITOR_SHOW_ERROR (WM_APP + 0x672)
#define EDITOR_RETRY 0x1ff0
static const wchar_t editor_class[] = L"MoojiCut.VideoEditor";
typedef struct Editor Editor;
struct Editor {
    Editor *next;
    HWND window, canvas, owner, error_dialog;
    MCVideoEditorHost *host;
    IFileSaveDialog *chooser;
    double width, height;
    int phase, modal_depth;
    BOOL close_requested, close_submitted, cancel_export, chooser_posted, error_posted;
    BOOL cancelling_modal;
    BOOL theme_delivered;
    uint64_t presentation_serial, video_generation, video_seek;
    int64_t video_pts;
    BOOL had_video;
    char reported_error[1024], local_error[1024];
};
static Editor *editors;
static UINT_PTR service_timer;
static BOOL servicing;
static DWORD ui_thread;

static Editor *find_editor(HWND window) {
    for (Editor *e = editors; e; e = e->next) if (e->window == window) return e;
    return NULL;
}
static BOOL on_ui_thread(void) { return !ui_thread || ui_thread == GetCurrentThreadId(); }
static char *utf8(const wchar_t *text) {
    if (!text) return NULL;
    int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1, NULL, 0, NULL, NULL);
    if (!length) return NULL;
    char *result = malloc((size_t)length);
    if (result && !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1, result, length, NULL, NULL)) {
        free(result); return NULL;
    }
    return result;
}
static wchar_t *wide(const char *text) {
    if (!text) return NULL;
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (!length) return NULL;
    wchar_t *result = calloc((size_t)length, sizeof(*result));
    if (result && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, result, length)) {
        free(result); return NULL;
    }
    return result;
}
static void notify_owner(Editor *e, int phase) {
    if (e->owner && IsWindow(e->owner))
        PostMessageW(e->owner, MC_WIN_VIDEO_EDITOR_CHANGED, (WPARAM)e->window, (LPARAM)phase);
}
static const char *current_error(Editor *e) {
    if (e->local_error[0]) return e->local_error;
    return e->host ? mc_video_editor_host_error(e->host) : "";
}
static void refresh(Editor *e) {
    if (!e->host || !e->canvas || e->width <= 0 || e->height <= 0) return;
    int32_t frame = mc_video_editor_host_frame(e->host, e->width, e->height);
    if (frame && !mc_win_canvas_set_frame(e->canvas, frame)) ui_frame_close(frame);
    e->presentation_serial = mc_video_editor_host_presentation_serial(e->host);
    mc_win_canvas_set_capture(e->canvas, mc_video_editor_host_value(e->host, MC_EDITOR_CAPTURE) == 1);
    InvalidateRect(e->canvas, NULL, FALSE);
}
static void input(void *context, HWND window, const MCCanvasInput *event) {
    Editor *e = context;
    e->canvas = window;
    if (!e->host) return;
    mc_video_editor_host_event(e->host, event);
    refresh(e);
}
static void resize(void *context, HWND window, double width, double height) {
    Editor *e = context; e->canvas = window; e->width = width; e->height = height;
    refresh(e);
}
static void canvas_destroyed(void *context, HWND window) {
    Editor *e = context; if (e->canvas == window) e->canvas = NULL;
}
static void video(void *context, HWND window, HDC target, const RECT *bounds) {
    (void)window;
    Editor *e = context;
    FillRect(target, bounds, (HBRUSH)GetStockObject(BLACK_BRUSH));
    const MCMediaFrame *frame = e->host ? mc_video_editor_host_video(e->host) : NULL;
    if (!frame || !frame->image.pixels || frame->image.width <= 0 || frame->image.height <= 0 ||
        frame->image.stride != frame->image.width * 4) return;
    int width = bounds->right - bounds->left, height = bounds->bottom - bounds->top;
    if (width <= 0 || height <= 0) return;
    double scale = fmin((double)width / frame->image.width, (double)height / frame->image.height);
    int shown_width = max(1, (int)floor(frame->image.width * scale + .5));
    int shown_height = max(1, (int)floor(frame->image.height * scale + .5));
    BITMAPINFO info = {0}; info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = frame->image.width; info.bmiHeader.biHeight = -frame->image.height;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
    int saved = SaveDC(target);
    if (!saved) return;
    IntersectClipRect(target, bounds->left, bounds->top, bounds->right, bounds->bottom);
    SetStretchBltMode(target, HALFTONE); SetBrushOrgEx(target, 0, 0, NULL);
    StretchDIBits(target, bounds->left + (width - shown_width) / 2, bounds->top + (height - shown_height) / 2,
        shown_width, shown_height, 0, 0, frame->image.width, frame->image.height,
        frame->image.pixels, &info, DIB_RGB_COLORS, SRCCOPY);
    RestoreDC(target, saved);
}
static void cancel_modal(Editor *e) {
    /* COM can pump messages while creating/closing its native window. Keep
     * cancellation pending until Show actually returns, and avoid a nested
     * timer issuing Close recursively from inside this Close call. */
    if (e->cancelling_modal) return;
    e->cancelling_modal = TRUE;
    if (e->chooser) IFileSaveDialog_Close(e->chooser, HRESULT_FROM_WIN32(ERROR_CANCELLED));
    if (e->error_dialog) PostMessageW(e->error_dialog, TDM_CLICK_BUTTON, IDCANCEL, 0);
    e->cancelling_modal = FALSE;
}
static void request_close(Editor *e, BOOL cancel_export) {
    e->close_requested = TRUE; e->cancel_export = cancel_export;
    if (e->canvas) mc_win_canvas_cancel(e->canvas);
    cancel_modal(e);
}
static BOOL retry(Editor *e) {
    if (!e->host || e->close_submitted || e->modal_depth) return FALSE;
    e->local_error[0] = '\0';
    BOOL accepted = mc_video_editor_host_retry(e->host);
    if (accepted) e->reported_error[0] = '\0';
    refresh(e); return accepted;
}
static HRESULT CALLBACK error_callback(HWND dialog, UINT notification, WPARAM wp, LPARAM lp, LONG_PTR data) {
    (void)wp; (void)lp;
    Editor *e = (Editor *)data;
    if (notification == TDN_CREATED) {
        e->error_dialog = dialog;
        if (e->close_requested) PostMessageW(dialog, TDM_CLICK_BUTTON, IDCANCEL, 0);
    } else if (notification == TDN_DESTROYED) e->error_dialog = NULL;
    return S_OK;
}
static void show_error(Editor *e) {
    e->error_posted = FALSE;
    if (!e->window || !e->host || e->modal_depth || e->close_requested) return;
    const char *message = current_error(e);
    if (!message || !*message) return;
    wchar_t *text = wide(message);
    TASKDIALOGCONFIG config = {0}; config.cbSize = sizeof(config); config.hwndParent = e->window;
    config.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_SIZE_TO_CONTENT;
    config.dwCommonButtons = TDCBF_RETRY_BUTTON | TDCBF_CANCEL_BUTTON;
    config.pszWindowTitle = L"Mooji Cut"; config.pszMainIcon = TD_ERROR_ICON;
    config.pszMainInstruction = L"The operation could not be completed.";
    config.pszContent = text ? text : L"The recording and editing window have been retained.";
    config.pfCallback = error_callback; config.lpCallbackData = (LONG_PTR)e;
    int button = IDCANCEL;
    e->modal_depth++;
    TaskDialogIndirect(&config, &button, NULL, NULL);
    e->modal_depth--; e->error_dialog = NULL; free(text);
    if (button == IDRETRY && !e->close_requested) retry(e);
}
static void show_chooser(Editor *e) {
    e->chooser_posted = FALSE;
    if (!e->window || !e->host || e->modal_depth || e->close_requested) return;
    int32_t ticket = mc_video_editor_host_chooser(e->host);
    if (!ticket) return;
    e->modal_depth++;
    HRESULT initialized = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    HRESULT result = initialized;
    IFileSaveDialog *dialog = NULL;
    char *destination = NULL;
    if (SUCCEEDED(initialized)) result = CoCreateInstance(&CLSID_FileSaveDialog, NULL, CLSCTX_INPROC_SERVER,
        &IID_IFileSaveDialog, (void **)&dialog);
    if (SUCCEEDED(result) && dialog) {
        e->chooser = dialog;
        COMDLG_FILTERSPEC types[] = {{L"MP4 video", L"*.mp4"}};
        FILEOPENDIALOGOPTIONS options = 0;
        result = IFileSaveDialog_GetOptions(dialog, &options);
        if (SUCCEEDED(result)) result = IFileSaveDialog_SetOptions(dialog, options | FOS_FORCEFILESYSTEM |
            FOS_OVERWRITEPROMPT | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR | FOS_STRICTFILETYPES);
        if (SUCCEEDED(result)) result = IFileSaveDialog_SetFileTypes(dialog, 1, types);
        if (SUCCEEDED(result)) result = IFileSaveDialog_SetDefaultExtension(dialog, L"mp4");
        SYSTEMTIME time; GetLocalTime(&time); wchar_t name[96];
        swprintf_s(name, ARRAYSIZE(name), L"moojicut-%04u%02u%02u-%02u%02u%02u.mp4",
            (unsigned)time.wYear, (unsigned)time.wMonth, (unsigned)time.wDay,
            (unsigned)time.wHour, (unsigned)time.wMinute, (unsigned)time.wSecond);
        if (SUCCEEDED(result)) result = IFileSaveDialog_SetFileName(dialog, name);
        if (SUCCEEDED(result)) result = e->close_requested ? HRESULT_FROM_WIN32(ERROR_CANCELLED) :
            IFileSaveDialog_Show(dialog, e->window);
        if (SUCCEEDED(result) && !e->close_requested) {
            IShellItem *item = NULL;
            result = IFileSaveDialog_GetResult(dialog, &item);
            if (SUCCEEDED(result) && item) {
                PWSTR path = NULL; result = IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &path);
                if (SUCCEEDED(result)) { destination = utf8(path); if (!destination) result = E_INVALIDARG; }
                CoTaskMemFree(path); IShellItem_Release(item);
            }
        }
        e->chooser = NULL; IFileSaveDialog_Release(dialog);
    }
    if (SUCCEEDED(initialized)) CoUninitialize();
    /* The host/ticket stays alive throughout Show's nested message loop. Timer
     * callbacks may drain media, but never close/free a modal editor. */
    mc_video_editor_host_choose(e->host, ticket, e->close_requested ? NULL : destination);
    free(destination); e->modal_depth--;
    if (FAILED(result) && result != HRESULT_FROM_WIN32(ERROR_CANCELLED) && !e->close_requested)
        strcpy_s(e->local_error, sizeof(e->local_error), "Unable to open or complete the system save dialog.");
    refresh(e);
}
static void update(Editor *e) {
    if (!e->host) return;
    if (e->close_requested) cancel_modal(e);
    if (e->close_requested && !e->close_submitted && !e->modal_depth) {
        int32_t ticket = mc_video_editor_host_chooser(e->host);
        if (ticket) mc_video_editor_host_choose(e->host, ticket, NULL);
        e->close_submitted = mc_video_editor_host_request_close(e->host, e->cancel_export != FALSE);
        if (!e->close_submitted) { e->close_requested = FALSE; notify_owner(e, mc_video_editor_host_phase(e->host)); }
    }
    mc_video_editor_host_tick(e->host);
    int phase = mc_video_editor_host_phase(e->host);
    if (phase != e->phase) {
        e->phase = phase; notify_owner(e, phase);
    }
    if (phase == MC_VIDEO_HOST_OPEN && e->close_submitted) {
        /* A failed save can return to OPEN within the same host tick, without
         * an externally observed intermediate CLOSING frame. */
        e->close_submitted = FALSE; e->close_requested = FALSE;
        notify_owner(e, MC_VIDEO_HOST_OPEN);
    }
    if (phase == MC_VIDEO_HOST_OPEN && !e->theme_delivered && e->canvas) {
        e->theme_delivered = TRUE; SendMessageW(e->canvas, WM_THEMECHANGED, 0, 0);
    }
    if (e->window && phase != MC_VIDEO_HOST_CLOSED) {
        if (e->presentation_serial != mc_video_editor_host_presentation_serial(e->host)) refresh(e);
        const MCMediaFrame *image = mc_video_editor_host_video(e->host);
        BOOL has_video = image && image->image.pixels;
        if (has_video != e->had_video || (has_video && (image->image.pts_ns != e->video_pts ||
            image->plan_generation != e->video_generation || image->seek_token != e->video_seek))) {
            e->had_video = has_video;
            if (has_video) { e->video_pts = image->image.pts_ns; e->video_generation = image->plan_generation; e->video_seek = image->seek_token; }
            if (e->canvas) InvalidateRect(e->canvas, NULL, FALSE);
        }
        const char *error = current_error(e);
        if (!error) error = "";
        HMENU menu = GetSystemMenu(e->window, FALSE);
        if (menu) EnableMenuItem(menu, EDITOR_RETRY, MF_BYCOMMAND | (*error ? MF_ENABLED : MF_GRAYED));
        if (strcmp(error, e->reported_error)) {
            strncpy_s(e->reported_error, sizeof(e->reported_error), error, _TRUNCATE);
            notify_owner(e, phase);
            if (*error && !e->modal_depth && !e->close_requested && !e->error_posted) {
                e->error_posted = PostMessageW(e->window, EDITOR_SHOW_ERROR, 0, 0);
            }
        }
        if (!e->modal_depth && !e->close_requested && !e->chooser_posted && mc_video_editor_host_chooser(e->host))
            e->chooser_posted = PostMessageW(e->window, EDITOR_SHOW_CHOOSER, 0, 0);
    }
}
static void CALLBACK timer(HWND window, UINT message, UINT_PTR id, DWORD time) {
    (void)window; (void)message; (void)id; (void)time;
    if (servicing) return;
    servicing = TRUE;
    Editor **link = &editors;
    while (*link) {
        Editor *e = *link;
        update(e);
        if (e->host && mc_video_editor_host_phase(e->host) == MC_VIDEO_HOST_CLOSED && !e->modal_depth) {
            if (!mc_video_editor_host_free(e->host)) { link = &e->next; continue; }
            e->host = NULL;
            notify_owner(e, MC_VIDEO_HOST_CLOSED);
            if (e->window) DestroyWindow(e->window);
            *link = e->next; free(e);
        } else link = &e->next;
    }
    if (!editors && service_timer) { KillTimer(NULL, service_timer); service_timer = 0; }
    servicing = FALSE;
}
static LRESULT CALLBACK editor_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    Editor *e = (Editor *)GetWindowLongPtrW(window, GWLP_USERDATA);
    if (message == WM_NCCREATE) {
        e = ((CREATESTRUCTW *)lp)->lpCreateParams; e->window = window;
        SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)e);
    }
    if (!e) return DefWindowProcW(window, message, wp, lp);
    switch (message) {
    case WM_CREATE: {
        MCWinCanvasCallbacks callbacks = {input, resize, canvas_destroyed, video};
        e->canvas = mc_win_canvas_create(window, ((CREATESTRUCTW *)lp)->hInstance, EDITOR_CANVAS, &callbacks, e);
        if (!e->canvas) return -1;
        HMENU menu = GetSystemMenu(window, FALSE);
        if (menu) { AppendMenuW(menu, MF_SEPARATOR, 0, NULL); AppendMenuW(menu, MF_STRING | MF_GRAYED, EDITOR_RETRY, L"Retry"); }
        return 0;
    }
    case WM_SIZE: {
        RECT bounds; GetClientRect(window, &bounds);
        if (e->canvas) MoveWindow(e->canvas, 0, 0, bounds.right, bounds.bottom, TRUE);
        return 0;
    }
    case WM_GETMINMAXINFO: {
        UINT dpi = GetDpiForWindow(window); if (!dpi) dpi = 96;
        MINMAXINFO *limits = (MINMAXINFO *)lp;
        limits->ptMinTrackSize.x = MulDiv(640, (int)dpi, 96);
        limits->ptMinTrackSize.y = MulDiv(420, (int)dpi, 96); return 0;
    }
    case WM_DPICHANGED: {
        const RECT *r = (const RECT *)lp;
        SetWindowPos(window, NULL, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_SETFOCUS: if (e->canvas) SetFocus(e->canvas); return 0;
    case WM_ACTIVATEAPP: if (!wp && e->canvas) mc_win_canvas_cancel(e->canvas); break;
    case WM_THEMECHANGED: case WM_SETTINGCHANGE:
        if (e->canvas) SendMessageW(e->canvas, message, wp, lp); return 0;
    case WM_SYSCOMMAND: if ((wp & 0xfff0) == EDITOR_RETRY) { retry(e); return 0; } break;
    case EDITOR_SHOW_CHOOSER: show_chooser(e); return 0;
    case EDITOR_SHOW_ERROR: show_error(e); return 0;
    case WM_CLOSE: request_close(e, TRUE); return 0;
    case WM_QUERYENDSESSION: request_close(e, TRUE); return FALSE;
    case WM_ERASEBKGND: { RECT r; GetClientRect(window, &r); FillRect((HDC)wp, &r, (HBRUSH)GetStockObject(BLACK_BRUSH)); return 1; }
    case WM_NCDESTROY:
        /* Defensive external destruction still drains through the thread timer.
         * Normal closure only reaches here after the host's actual CLOSED ACK. */
        SetWindowLongPtrW(window, GWLP_USERDATA, 0); e->window = NULL; e->canvas = NULL;
        if (e->host) request_close(e, TRUE);
        break;
    default: break;
    }
    return DefWindowProcW(window, message, wp, lp);
}
HWND mc_win_video_editor_open_with_legacy(HINSTANCE instance, HWND owner, const wchar_t *source,
                                          const wchar_t *draft, const wchar_t *legacy, BOOL silent_preview) {
    if (!instance || !on_ui_thread()) { SetLastError(ERROR_INVALID_PARAMETER); return NULL; }
    unsigned count = 0; for (Editor *e = editors; e; e = e->next) count++;
    if (count >= 16) { SetLastError(ERROR_TOO_MANY_OPEN_FILES); return NULL; }
    char *source_path = utf8(source), *draft_path = utf8(draft), *legacy_path = utf8(legacy);
    if (!source_path || !draft_path || (legacy && !legacy_path)) {
        free(source_path); free(draft_path); free(legacy_path); SetLastError(ERROR_INVALID_PARAMETER); return NULL;
    }
    WNDCLASSEXW klass = {0}; klass.cbSize = sizeof(klass); klass.hInstance = instance; klass.lpfnWndProc = editor_proc;
    klass.lpszClassName = editor_class; klass.hCursor = LoadCursorW(NULL, IDC_ARROW);
    klass.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(1));
    if (!RegisterClassExW(&klass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) { free(source_path); free(draft_path); free(legacy_path); return NULL; }
    Editor *e = calloc(1, sizeof(*e));
    if (!e) { free(source_path); free(draft_path); free(legacy_path); SetLastError(ERROR_NOT_ENOUGH_MEMORY); return NULL; }
    e->owner = owner; e->phase = MC_VIDEO_HOST_OPENING;
    UINT dpi = owner ? GetDpiForWindow(owner) : GetDpiForSystem(); if (!dpi) dpi = 96;
    RECT bounds = {0, 0, MulDiv(1040, (int)dpi, 96), MulDiv(720, (int)dpi, 96)};
    AdjustWindowRectExForDpi(&bounds, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_APPWINDOW, dpi);
    HWND window = CreateWindowExW(WS_EX_APPWINDOW, editor_class, L"Mooji Cut", WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
        CW_USEDEFAULT, CW_USEDEFAULT, bounds.right - bounds.left, bounds.bottom - bounds.top, owner, NULL, instance, e);
    if (window && !service_timer) service_timer = SetTimer(NULL, 0, 16, timer);
    if (window && service_timer)
        e->host = mc_video_editor_host_create_with_legacy(source_path, draft_path, legacy_path,
            silent_preview != FALSE, e->local_error, sizeof(e->local_error));
    free(source_path); free(draft_path); free(legacy_path);
    if (!window || !e->host) {
        if (window) DestroyWindow(window);
        if (!editors && service_timer) { KillTimer(NULL, service_timer); service_timer = 0; }
        free(e); SetLastError(ERROR_OPEN_FAILED); return NULL;
    }
    ui_thread = GetCurrentThreadId(); e->next = editors; editors = e;
    ShowWindow(window, SW_SHOWNORMAL); UpdateWindow(window); SetFocus(e->canvas);
    notify_owner(e, e->phase); return window;
}
HWND mc_win_video_editor_open_ex(HINSTANCE instance, HWND owner, const wchar_t *source, const wchar_t *draft, BOOL silent_preview) {
    return mc_win_video_editor_open_with_legacy(instance, owner, source, draft, NULL, silent_preview);
}
HWND mc_win_video_editor_open(HINSTANCE instance, HWND owner, const wchar_t *source, const wchar_t *draft) {
    return mc_win_video_editor_open_ex(instance, owner, source, draft, FALSE);
}
BOOL mc_win_video_editor_busy(void) { return editors != NULL; }
BOOL mc_win_video_editor_activate(HWND window) {
    if (!on_ui_thread()) return FALSE;
    Editor *e = window ? find_editor(window) : editors;
    if (!e || !e->window) return FALSE;
    ShowWindow(e->window, SW_RESTORE); SetForegroundWindow(e->window);
    if (e->canvas) SetFocus(e->canvas); return TRUE;
}
BOOL mc_win_video_editor_request_close_all(BOOL cancel_export) {
    if (!on_ui_thread()) return FALSE;
    for (Editor *e = editors; e; e = e->next) request_close(e, cancel_export);
    return editors == NULL;
}
BOOL mc_win_video_editor_handle_message(MSG *message) {
    if (!on_ui_thread() || !message) return FALSE;
    Editor *e = find_editor(message->hwnd);
    if (e && e->canvas && !e->modal_depth && message->message == WM_KEYDOWN) {
        SendMessageW(e->canvas, message->message, message->wParam, message->lParam); return TRUE;
    }
    return FALSE;
}
BOOL mc_win_video_editor_command(HWND window, const char *json) {
    Editor *e = on_ui_thread() ? find_editor(window) : NULL;
    if (!e || !e->host || e->close_requested || e->modal_depth) return FALSE;
    BOOL accepted = mc_video_editor_host_command(e->host, json); refresh(e); return accepted;
}
BOOL mc_win_video_editor_retry(HWND window) {
    Editor *e = on_ui_thread() ? find_editor(window) : NULL;
    return e ? retry(e) : FALSE;
}
char *mc_win_video_editor_state(HWND window) {
    Editor *e = on_ui_thread() ? find_editor(window) : NULL;
    return e && e->host ? mc_video_editor_host_state(e->host) : NULL;
}
void mc_win_video_editor_text_free(char *text) { mc_video_editor_host_text_free(text); }
int32_t mc_win_video_editor_frame_snapshot(HWND window) {
    Editor *e = on_ui_thread() ? find_editor(window) : NULL;
    return e && e->host ? mc_video_editor_host_frame(e->host, e->width, e->height) : 0;
}
