#ifndef MOOJICUT_WINDOWS_VIDEO_EDITOR_H
#define MOOJICUT_WINDOWS_VIDEO_EDITOR_H
#include <windows.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* UI-thread only; MoonBit must already be initialized. The window owns its
 * shared editor host and never exposes a mutable child/session handle. Source
 * and draft are absolute UTF-16 filenames. The source is never overwritten.
 * A successful open is asynchronous: decoding/draft failures keep the window
 * available for Retry. Do not call DestroyWindow; send WM_CLOSE instead. */
#define MC_WIN_VIDEO_EDITOR_CHANGED (WM_APP + 0x670)
/* Posted to owner after a phase/error change or completed close. wParam is the
 * editor HWND (possibly retired); lParam is MC_VIDEO_HOST_* phase. Treat this
 * as a wakeup and query busy(), not as ownership of the HWND or a pointer. */
HWND mc_win_video_editor_open(HINSTANCE instance, HWND owner,
                              const wchar_t *source, const wchar_t *draft);
/* Silent playback is for automated/headless media checks. Normal app opens
 * use open(), which always enables actual audio output. */
HWND mc_win_video_editor_open_ex(HINSTANCE instance, HWND owner,
                                 const wchar_t *source, const wchar_t *draft,
                                 BOOL silent_preview);
/* App selects the explicit legacy filename. Only a genuinely absent new draft
 * permits migration; malformed/unreadable files are never silently replaced. */
HWND mc_win_video_editor_open_with_legacy(HINSTANCE instance, HWND owner,
                                          const wchar_t *source, const wchar_t *draft,
                                          const wchar_t *legacy, BOOL silent_preview);
BOOL mc_win_video_editor_busy(void);
BOOL mc_win_video_editor_activate(HWND window);
/* Returns TRUE only when every window and worker has actually closed. FALSE
 * means keep the app/message loop alive; a failed save keeps its editor open.
 * A live chooser is dismissed/acknowledged before requesting session close. */
BOOL mc_win_video_editor_request_close_all(BOOL cancel_export);
BOOL mc_win_video_editor_handle_message(MSG *message);

/* UI-thread automation through the same shared session as mouse/keyboard.
 * Commands require expectedRevision/requestId. Returned state is owned UTF-8;
 * release with text_free. Snapshot owns an immutable ui_frame handle and must
 * be ui_frame_close'd by its caller. No mutable document handle escapes. */
BOOL mc_win_video_editor_command(HWND window, const char *json);
BOOL mc_win_video_editor_retry(HWND window);
char *mc_win_video_editor_state(HWND window);
void mc_win_video_editor_text_free(char *text);
int32_t mc_win_video_editor_frame_snapshot(HWND window);
#ifdef __cplusplus
}
#endif
#endif
