#ifndef MOOJICUT_PLUGIN_PROTOCOL_H
#define MOOJICUT_PLUGIN_PROTOCOL_H

#include "moonbit.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Owning MoonBit String ABI. Every result is JSON:
 * success {ok:true,...}; failure {ok:false,error:{code,message}}.
 * Validation is pure; no loading, filesystem, network, or UI side effects.
 *
 * manifest_validate: manifest object -> {ok:true,manifest,tools}.
 * request_prepare: {manifest,toolId:<global id>,invocationId,capture}
 *   -> {ok:true,request:{apiVersion:1,invocationId,toolId:<local id>,capture}}.
 * output_validate: {invocationId:<expected>,output:<raw plugin JSON object>}
 *   -> {ok:true,result:{apiVersion:1,invocationId,kind:"text",title,text}}.
 * Embed original output JSON verbatim in the envelope: parsing/re-encoding it
 * in the host would hide duplicate keys before MoonBit validates them.
 * Host must bound raw plugin output to 256 KiB UTF-8 before wrapping it.
 * Core bounds text to 32 KiB UTF-8 and uses a separate envelope parsing budget.
 * tool_registry_resolve: {layout:null|<saved layout>,manifests:[...],command?:...}
 *   -> existing {ok:true,layout,groups}. User descriptors have type:"action",
 *   action:"run", pluginId and local toolId, with no annotation kind.
 * Existing feature gates and invocation cancellation remain host-owned. */
moonbit_string_t plugin_manifest_validate(moonbit_string_t manifest_json);
moonbit_string_t plugin_request_prepare(moonbit_string_t request_json);
moonbit_string_t plugin_output_validate(moonbit_string_t request_json);
moonbit_string_t tool_registry_resolve(moonbit_string_t request_json);

#ifdef __cplusplus
}
#endif
#endif
