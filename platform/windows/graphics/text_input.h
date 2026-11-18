#ifndef MOOJICUT_WINDOWS_TEXT_INPUT_H
#define MOOJICUT_WINDOWS_TEXT_INPUT_H
#include <windows.h>
#include "platform/shared/graphics/canvas.h"

typedef struct MCWinTextInputs MCWinTextInputs;
enum { MC_TEXT_ACCEPT = 1, MC_TEXT_CANCEL = 2, MC_TEXT_BLUR = 3, MC_TEXT_INPUT_STATE = 4 };
/* Field events are borrowed for the callback. The host applies its shared
 * transaction and synchronously supplies the resulting frame. No document or
 * numeric parsing lives in this adapter. Callbacks may destroy this group. */
typedef struct {
  BOOL (*event)(void *context, HWND field, moonbit_string_t event);
  void (*action)(void *context, HWND field, int action);
  /* Optional brush of the exact pixels behind a field. Required for a
   * translucent native input: the adapter blends the live EDIT (including its
   * real selection/caret) over identical background pixels, not duplicate text.
   * Borrowed brush remains host-owned; do not pump messages while supplying it. */
  HBRUSH (*background)(void *context, HWND field, HDC target);
  /* Optional single-line navigation intent. TRUE means the shared owner
   * handled it; FALSE leaves normal EDIT navigation intact. */
  BOOL (*key)(void *context, HWND field, const MCCanvasInput *input);
} MCWinTextCallbacks;
MCWinTextInputs *mc_win_text_inputs_create(HWND parent, HINSTANCE instance,
    const MCWinTextCallbacks *callbacks, void *context);
void mc_win_text_inputs_destroy(MCWinTextInputs *inputs);
/* Borrows the frame. Coordinates are logical points relative to origin in
 * parent device pixels. An empty/zero frame retires all field identities. */
BOOL mc_win_text_inputs_set_frame(MCWinTextInputs *inputs, int32_t frame,
    int x, int y, double scale);
HWND mc_win_text_inputs_field(MCWinTextInputs *inputs, const wchar_t *id);
BOOL mc_win_text_inputs_contains(MCWinTextInputs *inputs, HWND window);
BOOL mc_win_text_inputs_composing(MCWinTextInputs *inputs);
BOOL mc_win_text_inputs_history(MCWinTextInputs *inputs, HWND field, BOOL redo);
/* Deliver a copied IMM snapshot after the native EDIT has processed it.
 * Strings are borrowed native UTF-16 (CRLF allowed); NULL means absent, while
 * an empty string is an actual empty segment. Cursor is a native UTF-16 offset
 * inside preedit, or -1 when unknown. Production IMM and deterministic platform
 * contract replay use the same acceptance/terminal path, with no field policy. */
BOOL mc_win_text_inputs_composition(MCWinTextInputs *inputs, HWND field,
    const wchar_t *result, const wchar_t *preedit, int cursor, BOOL canceled);
/* Flushes changes made by native/AX SetWindowText and selection APIs. */
BOOL mc_win_text_inputs_flush(MCWinTextInputs *inputs);
#endif
