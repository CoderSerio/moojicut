#ifndef MOOJICUT_PINNING_H
#define MOOJICUT_PINNING_H
#include <windows.h>
BOOL mc_pin_image(HINSTANCE instance, HGLOBAL dib, int x, int y, BOOL hidden);
void mc_pins_close(void);
void mc_pins_shutdown(void);
void mc_pins_restore_hidden(void);
void mc_pins_exit_passthrough(void);
void mc_pins_hide(BOOL hidden);
void mc_pin_load_keys(const wchar_t *registry_path);
WORD mc_pin_key(int action);
BOOL mc_pin_save_keys(const wchar_t *registry_path, const WORD keys[6]);
void mc_pin_default_keys(WORD keys[6]);
void mc_pin_suspend_shortcuts(BOOL suspended);
void mc_pin_set_capture_keys(const WORD keys[3]);
BOOL mc_pin_capture_conflicts(const WORD keys[3]);
BOOL mc_pin_smoke(HINSTANCE instance);
#endif
