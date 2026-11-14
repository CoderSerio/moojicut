#ifndef MOOJICUT_WINDOWS_CAPTURE_H
#define MOOJICUT_WINDOWS_CAPTURE_H
#include <windows.h>
#include <stdbool.h>
bool mc_capture_start(HINSTANCE instance, HWND owner);
bool mc_capture_busy(void);
void mc_capture_activate(void);
void mc_capture_close(void);
bool mc_capture_handle_message(MSG *message);
int mc_capture_smoke(HINSTANCE instance);
#endif
