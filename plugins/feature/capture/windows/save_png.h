#ifndef MOOJICUT_CAPTURE_SAVE_PNG_H
#define MOOJICUT_CAPTURE_SAVE_PNG_H
#include <windows.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Borrows the 24-bit CF_DIB produced by the screenshot renderer. */
BOOL mc_capture_write_png(HGLOBAL dib, const wchar_t *destination);
#ifdef __cplusplus
}
#endif
#endif
