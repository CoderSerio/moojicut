#ifndef MOOJICUT_SHORTCUT_BINDINGS_H
#define MOOJICUT_SHORTCUT_BINDINGS_H
#include "moonbit.h"
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Modifier bits: Control 1, Alt 2, Shift 4, Super 8. Keys are opaque
 * platform IDs. Resolve is a pure reducer: platform defaults, saved bindings,
 * stable action order, modifier requirements and an optional atomic edit.
 * Null means explicitly disabled; malformed saved bindings use defaults.
 * Duplicate saved bindings keep the first action. Duplicate edits fail.
 * Inputs/results use the borrowed-input, owned-output MoonBit String ABI. */
int32_t shortcut_modifiers_allowed(int32_t modifiers, int32_t global);
moonbit_string_t shortcut_bindings_resolve(moonbit_string_t request_json);
#ifdef __cplusplus
}
#endif
#endif
