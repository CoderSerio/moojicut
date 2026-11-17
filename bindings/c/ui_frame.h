#ifndef MOOJICUT_UI_FRAME_H
#define MOOJICUT_UI_FRAME_H
#include <stdint.h>
#include "moonbit.h"
#ifdef __cplusplus
extern "C" {
#endif
/* ABI version 1, for the in-repository frame JSON format (no JSON schemaVersion
 * required). All calls belong to the owning UI thread. Frames are immutable,
 * detached snapshots; opening one never mutates a UI session or another frame.
 * Open returns a positive never-reused handle, or 0 on malformed/oversized data
 * or exhaustion. At most 64 frames, 32768 commands total, 16384 semantic nodes,
 * 4194304 UTF-16 code units of JSON, depth 32. Strings in commands <=32768 units;
 * IDs <=256; labels/tooltips <=4096. Coordinates are finite logical units bounded
 * to +/-1e6 (sizes nonnegative). Unknown command types/invalid fields reject the
 * entire frame. Extra top-level producer metadata is ignored.
 * Input strings remain caller-owned. Every returned string is an owned MoonBit
 * UTF-16 string: use Moonbit_array_length, never assume NUL termination, and
 * moonbit_decref after use. Numeric getters do not return borrowed pointers.
 * Missing or empty semantic tooltip resolves to its label in the shared decoder.
 * Invalid handle/index/key: integer/count=-1, number=0, text="". Check kind/count
 * before reading. Optional absent fill/stroke=-1. Close returns 1 once, else 0. */
enum { MC_UI_FRAME_ABI_VERSION = 1 };
enum { MC_UI_LAYER_COMMANDS = 0, MC_UI_LAYER_OVERLAY = 1 };
enum { MC_UI_COMMAND_RECT = 1, MC_UI_COMMAND_LINE = 2, MC_UI_COMMAND_TEXT = 3 };
enum { MC_UI_CURSOR_DEFAULT = 0, MC_UI_CURSOR_RESIZE_HORIZONTAL = 1,
       MC_UI_CURSOR_POINTER = 2, MC_UI_CURSOR_CROSSHAIR = 3 };
enum { MC_UI_FRAME_CURSOR = 0, MC_UI_FRAME_HAS_VIDEO = 1 };
enum { MC_UI_RECT_X = 0, MC_UI_RECT_Y = 1, MC_UI_RECT_WIDTH = 2, MC_UI_RECT_HEIGHT = 3 };
/* For line commands X/Y mean x1/y1, and X2/Y2 are the endpoint. */
enum { MC_UI_DRAW_X = 0, MC_UI_DRAW_Y = 1, MC_UI_DRAW_WIDTH = 2, MC_UI_DRAW_HEIGHT = 3,
       MC_UI_DRAW_RADIUS = 4, MC_UI_DRAW_LINE_WIDTH = 5, MC_UI_DRAW_X2 = 6,
       MC_UI_DRAW_Y2 = 7, MC_UI_DRAW_FONT_SIZE = 8 };
enum { MC_UI_DRAW_TYPE = 0, MC_UI_DRAW_FILL = 1, MC_UI_DRAW_STROKE = 2,
       MC_UI_DRAW_COLOR = 3, MC_UI_DRAW_WEIGHT = 4, MC_UI_DRAW_ALIGN = 5, MC_UI_DRAW_VALIGN = 6 };
enum { MC_UI_WEIGHT_REGULAR = 0, MC_UI_WEIGHT_MEDIUM = 1, MC_UI_WEIGHT_BOLD = 2 };
enum { MC_UI_ALIGN_LEFT = 0, MC_UI_ALIGN_CENTER = 1, MC_UI_ALIGN_RIGHT = 2 };
enum { MC_UI_VALIGN_TOP = 0, MC_UI_VALIGN_CENTER = 1 };
enum { MC_UI_ROLE_GROUP = 0, MC_UI_ROLE_BUTTON = 1, MC_UI_ROLE_SLIDER = 2,
       MC_UI_ROLE_CHECKBOX = 3, MC_UI_ROLE_TEXT = 4 };
enum { MC_UI_VALUE_NONE = 0, MC_UI_VALUE_NUMBER = 1, MC_UI_VALUE_TEXT = 2, MC_UI_VALUE_BOOL = 3 };
enum { MC_UI_SEM_ROLE = 0, MC_UI_SEM_ENABLED = 1, MC_UI_SEM_FOCUSED = 2,
       MC_UI_SEM_VALUE_TYPE = 3, MC_UI_SEM_HAS_MIN = 4, MC_UI_SEM_HAS_MAX = 5, MC_UI_SEM_HAS_STEP = 6 };
enum { MC_UI_SEM_X = 0, MC_UI_SEM_Y = 1, MC_UI_SEM_WIDTH = 2, MC_UI_SEM_HEIGHT = 3,
       MC_UI_SEM_VALUE = 4, MC_UI_SEM_MIN = 5, MC_UI_SEM_MAX = 6, MC_UI_SEM_STEP = 7 };
enum { MC_UI_SEM_ID = 0, MC_UI_SEM_LABEL = 1, MC_UI_SEM_TOOLTIP = 2, MC_UI_SEM_VALUE_TEXT = 3 };
int32_t ui_frame_open(moonbit_string_t json);
int32_t ui_frame_close(int32_t handle);
int32_t ui_frame_value(int32_t handle, int32_t field);
double ui_frame_video_rect(int32_t handle, int32_t field);
int32_t ui_frame_command_count(int32_t handle, int32_t layer);
int32_t ui_frame_command_value(int32_t handle, int32_t layer, int32_t index, int32_t field);
double ui_frame_command_number(int32_t handle, int32_t layer, int32_t index, int32_t field);
moonbit_string_t ui_frame_command_text(int32_t handle, int32_t layer, int32_t index);
int32_t ui_frame_semantic_count(int32_t handle);
int32_t ui_frame_semantic_value(int32_t handle, int32_t index, int32_t field);
double ui_frame_semantic_number(int32_t handle, int32_t index, int32_t field);
moonbit_string_t ui_frame_semantic_text(int32_t handle, int32_t index, int32_t field);
/* Generic event encoder, no hit-testing or business interpretation. Pointer and
 * scroll positions/deltas must be finite +/-1e6. Text is empty for pointer,
 * cancel/scroll; key/activate require 1..256 units; appearance is light/dark.
 * Flags outside MOD|SHIFT|PRECISE reject. Invalid input returns owned "". */
enum { MC_UI_INPUT_POINTER_DOWN = 1, MC_UI_INPUT_POINTER_MOVE = 2, MC_UI_INPUT_POINTER_UP = 3,
       MC_UI_INPUT_CANCEL = 4, MC_UI_INPUT_SCROLL = 5, MC_UI_INPUT_KEY = 6,
       MC_UI_INPUT_ACTIVATE = 7, MC_UI_INPUT_APPEARANCE = 8 };
enum { MC_UI_INPUT_MOD = 1, MC_UI_INPUT_SHIFT = 2, MC_UI_INPUT_PRECISE = 4 };
moonbit_string_t ui_input_event(int32_t type, double x, double y, double dx, double dy,
                               int32_t flags, moonbit_string_t text);
#ifdef __cplusplus
}
#endif
#endif
