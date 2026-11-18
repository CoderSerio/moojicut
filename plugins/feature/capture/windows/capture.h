#ifndef MOOJICUT_WINDOWS_CAPTURE_H
#define MOOJICUT_WINDOWS_CAPTURE_H
#include <windows.h>
#include <stdbool.h>
#include <stdint.h>
/* Host services. A successful pin_image transfers ownership of dib to the
 * receiver; on failure capture keeps and frees it. Callbacks/context must live
 * through this capture session. Capture never imports the pin implementation. */
typedef struct {
  void *context;
  BOOL (*pin_image)(void *context, HGLOBAL dib, int screen_x, int screen_y);
  void (*set_pins_hidden)(void *context, BOOL hidden);
  BOOL (*pin_enabled)(void *context);
  /* Optional v2 service: accept/queue the request synchronously, then return.
   * Strings are borrowed NUL-terminated UTF-16 for this call only; copy before
   * asynchronous use. The image session remains capture-owned. Do not pump the
   * event loop or close capture here. TRUE acknowledges dispatch, not execution. */
  BOOL (*on_user_tool)(void *context, int32_t image_session,
                      const wchar_t *stable_id, const wchar_t *payload);
} MCCaptureHost;
void mc_capture_refresh_capabilities(void);
/* UI-thread completion notification after shared application validation. A
 * stale/closed image is ignored; this does not apply arbitrary native edits. */
BOOL mc_capture_plugin_result(int32_t image_session, BOOL document_changed);
/* Main thread configuration transaction. Snapshot handles remain host-owned.
 * Prepare is non-mutating; invalid input, IME, drag or modal ownership veto it.
 * Unaffected valid drafts retain their token/focus. Commit follows a successful
 * durable save; discard releases the shared configuration candidate. */
BOOL mc_capture_prepare_tools(int32_t snapshot);
void mc_capture_commit_tools(int32_t snapshot);
void mc_capture_discard_tools(void);
bool mc_capture_start(HINSTANCE instance, HWND owner, const MCCaptureHost *services);
bool mc_capture_busy(void);
void mc_capture_activate(void);
void mc_capture_close(void);
bool mc_capture_handle_message(MSG *message);
int mc_capture_smoke(HINSTANCE instance);
#endif
