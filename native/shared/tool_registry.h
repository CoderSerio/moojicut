#ifndef MOOJICUT_TOOL_REGISTRY_H
#define MOOJICUT_TOOL_REGISTRY_H

#include "moonbit.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Inputs and returned strings follow the ordinary MoonBit owning C ABI.
 * normalize accepts the saved layout object JSON, or an empty string for defaults.
 * update accepts {layout,command}; command is enabled(id,enabled), or
 * move(group,id,beforeId), with null beforeId meaning the end of the saved group.
 * Success: {ok:true,layout:{version:1,groups:{...}},groups:{...}}.
 * Failure: {ok:false,error:{code,message}}; no replacement layout is returned.
 * Hosts persist layout, display groups, and dispatch by stable id/type rather
 * than array index. type:"annotation" has kind 1..4; type:"action" has
 * action:"pin" and no kind. Disabled entries remain in both outputs;
 * unknown IDs remain only in layout. Selection and workflow controls are not
 * configurable tools.
 * This API does not own feature lifecycle, editor documents, or style sessions. */
moonbit_string_t tool_registry_normalize(moonbit_string_t saved_json);
moonbit_string_t tool_registry_update(moonbit_string_t request_json);

#ifdef __cplusplus
}
#endif
#endif
