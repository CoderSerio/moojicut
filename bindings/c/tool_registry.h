#ifndef MOOJICUT_TOOL_REGISTRY_H
#define MOOJICUT_TOOL_REGISTRY_H
#include <stdint.h>
#include "moonbit.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Pure JSON configuration boundary. Success is {ok:true,layout,groups,manifests}.
 * normalize takes a saved layout or ""; update takes {layout,command}; resolve
 * adds installed manifests. Commands: enabled(id,enabled), move(group,id,beforeId).
 * Unknown saved IDs survive but are not executable contributions. */
moonbit_string_t tool_registry_normalize(moonbit_string_t saved_json);
moonbit_string_t tool_registry_update(moonbit_string_t request_json);
moonbit_string_t tool_registry_resolve(moonbit_string_t request_json);
enum { MC_TOOL_GROUP_SCREENSHOT=0, MC_TOOL_GROUP_RECORDING=1, MC_TOOL_GROUP_VIDEO_EDITING=2 };
enum { MC_TOOL_SLOT_TOOLS=0, MC_TOOL_SLOT_FINISH=1 };
enum { MC_TOOL_TYPE_ANNOTATION=1, MC_TOOL_TYPE_ACTION=2, MC_TOOL_TYPE_COMMAND=3 };
enum { MC_TOOL_INTERACTION_INVOKE=0, MC_TOOL_INTERACTION_ANNOTATION=1, MC_TOOL_INTERACTION_DRAG_RECT=2 };
enum {
  MC_TOOL_CAP_OCR=1, MC_TOOL_CAP_TRANSLATE=2, MC_TOOL_CAP_SCROLL=4,
  MC_TOOL_CAP_COMMANDS=8, MC_TOOL_CAP_USER=16
};
/* Integer query keys. ENABLED is saved preference; AVAILABLE is backend support.
 * A visible enabled but unavailable contribution must be disabled with its
 * reason, not silently invoke another command. KIND is 0 when not annotation. */
enum {
  MC_TOOL_ENABLED=0, MC_TOOL_AVAILABLE=1, MC_TOOL_SLOT=2, MC_TOOL_KIND=3,
  MC_TOOL_TYPE=4, MC_TOOL_INTERACTION=5, MC_TOOL_DEFAULT_ENABLED=6,
  MC_TOOL_CAPABILITY=7
};
enum {
  MC_TOOL_ID=0, MC_TOOL_PLUGIN_ID=1, MC_TOOL_TITLE=2, MC_TOOL_ICON=3,
  MC_TOOL_COMMAND=4, MC_TOOL_ACTION=5, MC_TOOL_PAYLOAD=6,
  MC_TOOL_UNAVAILABLE_REASON=7, MC_TOOL_LOCAL_ID=8, MC_TOOL_TARGET=9,
  MC_TOOL_REQUIRES=10
};
/* Main/core thread only. Open consumes a successful normalize/update/resolve
 * result, validates a detached snapshot, and returns a positive never-reused
 * handle (0 on invalid input/resource exhaustion). It NEVER publishes a global
 * layout. Queries do not mutate configuration. At most 64 snapshots may be open.
 * Host transaction: pure update -> open candidate -> feature preflight -> durable
 * save(snapshot_layout) -> publish candidate handle -> close previous handle.
 * If preflight/save fails, close candidate and keep the old handle/configuration.
 * Count/value return -1 for invalid/closed handles or indices/keys; text/layout
 * return owned empty strings. All returned strings require moonbit_decref.
 * Entries include disabled tools, in saved order. Partition by SLOT when drawing.
 * Payload is extensible JSON; icon/command are stable names, not button indices. */
int32_t tool_registry_snapshot_open(moonbit_string_t result_json, int32_t capabilities);
int32_t tool_registry_snapshot_count(int32_t handle, int32_t group);
int32_t tool_registry_snapshot_value(int32_t handle, int32_t group, int32_t index, int32_t key);
moonbit_string_t tool_registry_snapshot_text(int32_t handle, int32_t group, int32_t index, int32_t key);
moonbit_string_t tool_registry_snapshot_layout(int32_t handle);
/* Pure candidates; the original snapshot remains valid and unchanged.
 * enabled must be 0 or 1. Empty before_id appends within its own group/slot;
 * a nonempty before_id must name an entry in that same group and slot.
 * Candidates retain the capability mask and installed-manifest snapshot. */
int32_t tool_registry_snapshot_set_enabled(int32_t handle, moonbit_string_t tool_id, int32_t enabled);
int32_t tool_registry_snapshot_move(int32_t handle, moonbit_string_t tool_id, moonbit_string_t before_id);
int32_t tool_registry_snapshot_close(int32_t handle);
#ifdef __cplusplus
}
#endif
#endif
