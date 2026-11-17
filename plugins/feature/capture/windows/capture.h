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
} MCCaptureHost;
void mc_capture_refresh_capabilities(void);
/* Main thread configuration transaction. Snapshot handles remain host-owned.
 * Prepare is non-mutating and refuses active IME/text/drag input. Commit must
 * follow a successful durable save; discard releases prepared native views. */
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
