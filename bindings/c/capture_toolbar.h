#ifndef MOOJICUT_CAPTURE_TOOLBAR_H
#define MOOJICUT_CAPTURE_TOOLBAR_H
#include <stdint.h>
#include "moonbit.h"
#ifdef __cplusplus
extern "C" {
#endif
/* UI-thread authority borrowing image/style, copying a VERIFIED registry
 * snapshot. Closing that registry snapshot is safe after open/prepare returns.
 * One toolbar per image; close toolbar before disposing image/style. */
int32_t capture_toolbar_open(int32_t image, int32_t style, int32_t registry_snapshot);
/* Complete facts: {hasRegion:bool,blocked:bool,fieldFocused:bool,pinAvailable:bool,
 * edit:int,editVersion:int,measuredHeight:number,toolbarFocused?:bool,bodyEditing?:bool,
 * capabilities?:int(0..31),
 * assets?:{contributionId:assetId}}. Missing capabilities uses snapshot facts.
 * edit=0 iff no property edit. Measurement belongs to this exact edit version.
 * blocked reports native drag/modal ownership; it does not override root validity.
 * Asset IDs are opaque [A-Za-z0-9._-]+, never paths. Missing assets use icons.
 * Returns 1 on accepted facts, 0 on malformed/stale facts; no document mutation. */
int32_t capture_toolbar_context(int32_t toolbar, moonbit_string_t facts);
/* Frame consumes shared layout/input state. Width >= 32 logical pixels, <= 32768.
 * Returned JSON is a generic ui_frame description; strings are owned UTF-16. */
moonbit_string_t capture_toolbar_frame(int32_t toolbar, double max_width, int32_t dark);
/* Opaque surface RGB for hosts without a native popover material. */
int32_t capture_toolbar_surface_color(int32_t dark);
/* Pass GENERATION sampled from the displayed frame. Pointer, keyboard and AX
 * activation all use the same ui_input_event JSON protocol. 1=handled, 0=rejected.
 * Read effect/value after a handled event; at most one unacknowledged effect. */
int32_t capture_toolbar_event(int32_t toolbar, int32_t generation, moonbit_string_t input);
/* Same root dispatch, also works when the item is outside the visible page. */
int32_t capture_toolbar_activate(int32_t toolbar, int32_t generation, moonbit_string_t id);
int32_t capture_toolbar_tool_enabled(int32_t toolbar, int32_t annotation_kind);
enum { MC_CAPTURE_TOOLBAR_KIND = 0, MC_CAPTURE_TOOLBAR_INTERACTION = 1,
    MC_CAPTURE_TOOLBAR_GENERATION = 2, MC_CAPTURE_TOOLBAR_WIDTH = 3,
    MC_CAPTURE_TOOLBAR_HEIGHT = 4, MC_CAPTURE_TOOLBAR_EFFECT = 5,
    MC_CAPTURE_TOOLBAR_TICKET = 6, MC_CAPTURE_TOOLBAR_CANDIDATE = 7 };
enum { MC_CAPTURE_TOOLBAR_ACTIVE_ID = 0, MC_CAPTURE_TOOLBAR_COMMAND = 1,
    MC_CAPTURE_TOOLBAR_EFFECT_ID = 2, MC_CAPTURE_TOOLBAR_PAYLOAD = 3,
    MC_CAPTURE_TOOLBAR_ERROR = 4 };
/* COMMAND is the active dragRect contribution handler; ordinary annotations
 * and selection return empty. Other action routing is exclusively EFFECT. */
enum { MC_CAPTURE_TOOLBAR_NONE = 0, MC_CAPTURE_TOOLBAR_REFRESH = 1,
    MC_CAPTURE_TOOLBAR_COPY = 2, MC_CAPTURE_TOOLBAR_CANCEL = 3,
    MC_CAPTURE_TOOLBAR_PIN = 4, MC_CAPTURE_TOOLBAR_OCR = 5,
    MC_CAPTURE_TOOLBAR_TRANSLATE = 6, MC_CAPTURE_TOOLBAR_SCROLL = 7,
    MC_CAPTURE_TOOLBAR_USER_TOOL = 8, MC_CAPTURE_TOOLBAR_SAVE = 9 };
double capture_toolbar_value(int32_t toolbar, int32_t key); /* invalid: -1 */
moonbit_string_t capture_toolbar_text(int32_t toolbar, int32_t key);
/* REFRESH means root already performed selection/history/publication. Native
 * only tears down retired controls and re-renders. COPY/OCR/TRANSLATE/SCROLL/
 * USER_TOOL publish a valid draft BEFORE the external effect; failure preserves
 * that committed document. PIN or SAVE renders CANDIDATE without publishing and ACK
 * success publishes it; failure preserves the uncommitted draft. CANCEL never
 * publishes. The host MUST ACK every effect, including synchronous REFRESH.
 * Late/duplicate ACK rejects. No callback runs inside root publication. */
int32_t capture_toolbar_ack(int32_t toolbar, int32_t ticket, int32_t success, moonbit_string_t error);
/* Config transaction: pure prepare/ready -> durable saved layout -> ONE
 * commit_many -> native cleanup. Each ticket freezes document/style/edit/context.
 * Disabled active tools fall back to select after committing their valid draft;
 * retained tools keep the same edit. Invalid/IME/native-busy/pending-effect veto.
 * JSON [{toolbar:int,candidate:int}], 1..16, all-or-nothing, no native callbacks.
 * Config ticket owns its property candidate; do not separately commit it. */
int32_t capture_toolbar_config_prepare(int32_t toolbar, int32_t registry_snapshot);
int32_t capture_toolbar_config_ready(int32_t toolbar, int32_t candidate);
int32_t capture_toolbar_config_commit_many(moonbit_string_t request);
int32_t capture_toolbar_config_close(int32_t candidate);
int32_t capture_toolbar_close(int32_t toolbar);
#ifdef __cplusplus
}
#endif
#endif
