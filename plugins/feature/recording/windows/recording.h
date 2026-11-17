#ifndef MOOJICUT_WINDOWS_RECORDING_H
#define MOOJICUT_WINDOWS_RECORDING_H
#include <windows.h>
#include <stdbool.h>
#define MOOJICUT_RECORDING_STATE_CHANGED (WM_APP + 0x61)
#ifdef __cplusplus
extern "C" {
#endif
/* UI-thread delivery after the recording worker finalized and released all
 * capture resources. The App chooses/open its editor and draft paths; this
 * feature never owns an editor. source is borrowed only for the callback.
 * False retains the source and reports that the App could not accept it. */
typedef bool (*MCRecordingCompleted)(void *context, const wchar_t *source);
void mc_recording_set_completed_callback(MCRecordingCompleted callback, void *context);
bool mc_recording_start(HINSTANCE instance, HWND owner);
bool mc_recording_resume_last(HINSTANCE instance, HWND owner);
void mc_recording_stop(void);
bool mc_recording_busy(void);
bool mc_recording_recording(void);
bool mc_recording_preparing(void);
void mc_recording_close(void);
void mc_recording_activate(void);
bool mc_recording_handle_message(MSG *message);
int mc_recording_smoke(HINSTANCE instance);
#ifdef __cplusplus
}
#endif
#endif
