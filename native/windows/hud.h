#ifndef MOOJICUT_WINDOWS_HUD_H
#define MOOJICUT_WINDOWS_HUD_H
#include <windows.h>
#ifdef __cplusplus
extern "C" {
#endif
/* System GDI+ paints the HUD; native BUTTON/EDIT controls retain input and accessibility. */
enum { MC_HUD_COLOR = 100, MC_HUD_STROKE = 101, MC_HUD_FONT = 102 };
void mc_hud_card(HDC dc, const RECT *bounds, float scale, const wchar_t *hint);
void mc_hud_button(HDC dc, const RECT *bounds, int kind, int value, BOOL selected, BOOL hovered, BOOL pressed,
                   BOOL focused, float scale);
void mc_hud_frame(HDC dc, const RECT *bounds, BOOL handles, float scale);
#ifdef __cplusplus
}
#endif
#endif
