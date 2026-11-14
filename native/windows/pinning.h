#ifndef MOOJICUT_PINNING_H
#define MOOJICUT_PINNING_H
#include <windows.h>
BOOL mc_pin_image(HINSTANCE instance, HGLOBAL dib, int x, int y, BOOL hidden);
void mc_pins_close(void);
void mc_pins_hide(BOOL hidden);
void mc_pin_load_keys(const wchar_t *registry_path);
WORD mc_pin_key(int action);
BOOL mc_pin_save_keys(const wchar_t *registry_path, const WORD keys[4]);
void mc_pin_default_keys(WORD keys[4]);
BOOL mc_pin_smoke(HINSTANCE instance);
#endif
