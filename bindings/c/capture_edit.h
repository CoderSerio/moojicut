#ifndef MOOJICUT_CAPTURE_EDIT_H
#define MOOJICUT_CAPTURE_EDIT_H
#include <stdint.h>
#include "moonbit.h"
#ifdef __cplusplus
extern "C" {
#endif
/* UI-thread capture authority. Returned strings are owned MoonBit UTF-16;
 * inputs are borrowed. Invalid handles yield 0, -1 or an empty string as noted.
 * No operation accepts a host-supplied authority document. Native consumers
 * keep only read-only render snapshots and report input/measurement facts. */
moonbit_string_t image_session_document(int32_t session);
double image_session_revision(int32_t session); /* invalid: -1 */
moonbit_string_t image_session_annotation_id(int32_t session, int32_t index);
int32_t image_session_command(int32_t session, double expected_revision, moonbit_string_t command);
/* Geometry-only move/resize of rectangular annotations or signed arrow extents.
 * Preserves text and all styles; font_size=-1 preserves the exact stored font,
 * otherwise a text resize may supply a validated fractional size. Rejects an
 * active text transaction: finish/cancel it before beginning the drag. */
int32_t image_session_geometry(int32_t session, double expected_revision, moonbit_string_t annotation_id,
    double x, double y, double width, double height, double font_size);

enum { MC_CAPTURE_TEXT_DEFAULTS = 0, MC_CAPTURE_TEXT_NEW = 1, MC_CAPTURE_TEXT_EXISTING = 2 };
enum { MC_CAPTURE_CANDIDATE_PREVIEW = 0, MC_CAPTURE_CANDIDATE_PUBLISH = 1 };
enum { MC_CAPTURE_TEXT_PROPERTIES = 0, MC_CAPTURE_TEXT_INLINE = 1 };
enum { MC_CAPTURE_TEXT_VERSION = 0, MC_CAPTURE_TEXT_MODE = 1, MC_CAPTURE_TEXT_RGB = 2,
       MC_CAPTURE_TEXT_OPACITY = 3, MC_CAPTURE_TEXT_FONT_SIZE = 4,
       MC_CAPTURE_TEXT_X = 5, MC_CAPTURE_TEXT_Y = 6, MC_CAPTURE_TEXT_WIDTH = 7,
       MC_CAPTURE_TEXT_HEIGHT = 8, MC_CAPTURE_TEXT_DOCUMENT_REVISION = 9,
       MC_CAPTURE_TEXT_CAN_UNDO = 10, MC_CAPTURE_TEXT_CAN_REDO = 11,
       MC_CAPTURE_TEXT_VALID = 12, MC_CAPTURE_TEXT_ROW_WIDTH = 13, MC_CAPTURE_TEXT_ROW_HEIGHT = 14 };
enum { MC_CAPTURE_TEXT_ANNOTATION_ID = 0, MC_CAPTURE_TEXT_RAW = 1, MC_CAPTURE_TEXT_ERROR = 2 };
enum { MC_CAPTURE_TEXT_REJECTED = 0, MC_CAPTURE_TEXT_HANDLED = 1, MC_CAPTURE_TEXT_CHOOSE_COLOR = 2 };
/* One edit per image session. Existing mode reads the stable annotation ID;
 * new mode allocates it in MoonBit. Defaults/new freeze the text style bank,
 * existing mode never changes tool defaults. The style handle must stay alive. */
int32_t capture_text_begin(int32_t session, int32_t style, int32_t mode,
    moonbit_string_t annotation_id, double expected_revision, double x, double y, double width, double height);
int32_t capture_text_event_json(int32_t session, int32_t edit, int32_t expected_version, moonbit_string_t event);
moonbit_string_t capture_text_snapshot(int32_t session, int32_t edit);
double capture_text_value(int32_t session, int32_t edit, int32_t key); /* invalid: -1 */
moonbit_string_t capture_text_text(int32_t session, int32_t edit, int32_t key);
moonbit_string_t capture_text_frame(int32_t session, int32_t edit, int32_t surface,
    double width, double height, double scale, int32_t dark);
int32_t capture_text_ui_event(int32_t session, int32_t edit, int32_t expected_version,
    moonbit_string_t event, double width, double height);
/* Preparation never commits, changes focus or ends IME. Measurement is the
 * text height in image coordinates for this exact edit version/raw/font/width.
 * Preview tickets cannot publish. New successful preparation retires the old
 * ticket; invalid/stale candidates reject without changing the live draft. */
int32_t capture_text_prepare(int32_t session, int32_t edit, int32_t version, int32_t purpose, double measured_height);
double capture_text_measured_height(int32_t session, int32_t edit, int32_t version, double measured_height);
int32_t capture_text_cancel(int32_t session, int32_t edit, int32_t version);
moonbit_string_t capture_candidate_document(int32_t candidate);
int32_t capture_candidate_ready(int32_t session, int32_t candidate);
int32_t capture_candidate_commit(int32_t session, int32_t candidate);
int32_t capture_candidate_close(int32_t candidate);
/* [{"session":id,"candidate":id}], 1..16 unique owners. Validate every ticket
 * before publishing any; publication makes no native callbacks. All native
 * focus/control teardown must happen after this atomic publication succeeds. */
int32_t capture_candidate_commit_many(moonbit_string_t request);
/* Non-text legacy host adapter: command JSON object/null, defaults JSON
 * null or {tool:int,values:{"0":number,...}}. Rejects an active text edit. */
int32_t image_session_prepare_command(int32_t session, int32_t style, double expected_revision,
    moonbit_string_t command, moonbit_string_t defaults);
#ifdef __cplusplus
}
#endif
#endif
