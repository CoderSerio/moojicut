#ifndef MOOJICUT_WINDOWS_UPDATES_H
#define MOOJICUT_WINDOWS_UPDATES_H
#include <windows.h>
#define MOOJICUT_UPDATES_CHANGED (WM_APP + 0x62)
BOOL mc_updates_initialize(HINSTANCE instance, HWND owner);
BOOL mc_updates_check(void);
BOOL mc_updates_download(HWND dialog_owner);
void mc_updates_cancel(void);
BOOL mc_updates_busy(void);
BOOL mc_updates_available(void);
BOOL mc_updates_downloaded(void);
const wchar_t *mc_updates_status(void);
void mc_updates_open_location(void);
/* Returns FALSE until the bounded background operation has drained. Owner
 * receives UPDATES_CHANGED when it can retry closing; never wait on the UI. */
BOOL mc_updates_prepare_close(void);
void mc_updates_shutdown(void);
BOOL mc_updates_smoke(HINSTANCE instance);
#endif
