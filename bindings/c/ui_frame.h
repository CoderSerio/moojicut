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
enum { MC_UI_COMMAND_RECT = 1, MC_UI_COMMAND_LINE = 2, MC_UI_COMMAND_TEXT = 3, MC_UI_COMMAND_ASSET = 4 };
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
enum { MC_UI_WEIGHT_REGULAR = 0, MC_UI_WEIGHT_MEDIUM = 1, MC_UI_WEIGHT_BOLD = 2,
       MC_UI_WEIGHT_SEMIBOLD = 3 /* editable fields only */ };
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
/* For an asset command the text getter returns an opaque resource key,
 * never a path. Only a caller-supplied resource table may resolve it. */
moonbit_string_t ui_frame_command_text(int32_t handle, int32_t layer, int32_t index);
int32_t ui_frame_semantic_count(int32_t handle);
int32_t ui_frame_semantic_value(int32_t handle, int32_t index, int32_t field);
double ui_frame_semantic_number(int32_t handle, int32_t index, int32_t field);
moonbit_string_t ui_frame_semantic_text(int32_t handle, int32_t index, int32_t field);
/* Editable field snapshots, <=64/frame; native input objects own accessibility
 * for these IDs, which cannot also occur in semantics. Unknown selection has
 * placeholder offsets; never overwrite a real native caret with them. Marked
 * endpoints are -1 when not composing. All ranges are UTF-16 and end-exclusive.
 * clip defaults to the field rect. Background is optional (-1 when absent).
 * Getters follow the same invalid-value rules. */
enum { MC_UI_FIELD_TOKEN = 0, MC_UI_FIELD_VERSION = 1, MC_UI_FIELD_ENABLED = 2,
       MC_UI_FIELD_READ_ONLY = 3, MC_UI_FIELD_FOCUSED = 4, MC_UI_FIELD_MULTILINE = 5,
       MC_UI_FIELD_SELECTION_KNOWN = 6, MC_UI_FIELD_DIRECTION_KNOWN = 7,
       MC_UI_FIELD_ANCHOR = 8, MC_UI_FIELD_FOCUS = 9, MC_UI_FIELD_MARKED_START = 10,
       MC_UI_FIELD_MARKED_END = 11, MC_UI_FIELD_COLOR = 12,
       MC_UI_FIELD_CAN_UNDO = 13, MC_UI_FIELD_CAN_REDO = 14, MC_UI_FIELD_WEIGHT = 15,
       MC_UI_FIELD_BACKGROUND = 16 };
enum { MC_UI_FIELD_X = 0, MC_UI_FIELD_Y = 1, MC_UI_FIELD_WIDTH = 2, MC_UI_FIELD_HEIGHT = 3,
       MC_UI_FIELD_CLIP_X = 4, MC_UI_FIELD_CLIP_Y = 5, MC_UI_FIELD_CLIP_WIDTH = 6,
       MC_UI_FIELD_CLIP_HEIGHT = 7, MC_UI_FIELD_FONT_SIZE = 8, MC_UI_FIELD_OPACITY = 9 };
enum { MC_UI_FIELD_ID = 0, MC_UI_FIELD_RAW = 1, MC_UI_FIELD_LABEL = 2,
       MC_UI_FIELD_TOOLTIP = 3, MC_UI_FIELD_ERROR = 4 };
int32_t ui_frame_field_count(int32_t handle);
int32_t ui_frame_field_value(int32_t handle, int32_t index, int32_t field);
double ui_frame_field_number(int32_t handle, int32_t index, int32_t field);
moonbit_string_t ui_frame_field_text(int32_t handle, int32_t index, int32_t field);
enum { MC_UI_TEXT_REPLACE = 1, MC_UI_TEXT_SELECT = 2, MC_UI_TEXT_COMPOSITION_START = 3,
       MC_UI_TEXT_COMPOSITION_UPDATE = 4, MC_UI_TEXT_COMPOSITION_COMMIT = 5,
       MC_UI_TEXT_COMPOSITION_CANCEL = 6, MC_UI_TEXT_UNDO = 7, MC_UI_TEXT_REDO = 8 };
enum { MC_UI_SELECTION_UNKNOWN = 0, MC_UI_SELECTION_DIRECTED = 1, MC_UI_SELECTION_UNDIRECTED = 2 };
/* Generic field event encoder. No domain parsing or document mutation. ID is
 * 1..256 units, text <=32768; all ranges/known offsets 0..32768. Unused start/end
 * and anchor/focus are 0. Only replace/composition-update/commit carry text.
 * CompositionCommit confirms IME into the draft; it does NOT publish a document.
 * Invalid input yields owned empty string. Native selection/composition offsets
 * must first be normalized to absolute UTF-16 positions in the resulting raw. */
moonbit_string_t ui_text_event(int32_t type, moonbit_string_t id, int32_t token, int32_t version,
    int32_t start, int32_t end, moonbit_string_t text, int32_t selection_kind, int32_t anchor, int32_t focus);
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
