#ifndef MOOJICUT_WINDOWS_RECORDING_H
#define MOOJICUT_WINDOWS_RECORDING_H
#include <windows.h>
#include <stdbool.h>
#define MOOJICUT_RECORDING_STATE_CHANGED (WM_APP + 0x61)
#ifdef __cplusplus
extern "C" {
#endif
bool mc_recording_start(HINSTANCE instance, HWND owner);
bool mc_recording_resume_last(HINSTANCE instance, HWND owner);
void mc_recording_stop(void);
bool mc_recording_busy(void);
bool mc_recording_recording(void);
bool mc_recording_preparing(void);
bool mc_recording_exporting(void);
void mc_recording_close(void);
void mc_recording_activate(void);
bool mc_recording_handle_message(MSG *message);
int mc_recording_smoke(HINSTANCE instance);
#ifdef __cplusplus
}
#endif
#endif
