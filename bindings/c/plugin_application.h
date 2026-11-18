#ifndef MOOJICUT_PLUGIN_APPLICATION_H
#define MOOJICUT_PLUGIN_APPLICATION_H
#include "moonbit.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Main-thread owning String ABI. An empty index String represents an absent
 * index. Otherwise pass the exact original UTF-8 bytes decoded without
 * normalization. archives is {"archives":[{"manifest":string,"digest":hex}]};
 * the host independently verifies each archive digest before supplying it.
 * layout is the previously saved built-in toolbar layout for a new index.
 *
 * Each command returns {ok:true,...} or {ok:false,error:{code,message}}.
 * Worker requests are serialized Strings. Return the original output String
 * only after the worker is drained, or null for failure/cancellation.
 * A native read must distinguish a missing index from an existing empty file.
 *
 * prepareInstall -> healthComplete -> reserveInstall. reserveToolChange
 * accepts a catalog command; reserveUninstall accepts a package ID.
 * Reservations give exact expected and replacement Strings for a native CAS
 * and the resulting tool registry for consumer preflight. Use publishComplete
 * to acknowledge the disk result. A successful rename with uncertain
 * durability needs read-back; it is not a failed CAS.
 *
 * startCall -> finishCall invokes a tool against an existing capture handle.
 * closeCapture cancels calls owned by that capture. status supplies outstanding
 * cancellation tickets; beginClose stops new work and starts draining.
 * Shutdown completes after both worker and storage acknowledgements drain. */
/* Pure startup read plan {ok:true,packages:[{pluginId,digest}]}. */
moonbit_string_t plugin_application_requirements(moonbit_string_t index);
moonbit_string_t plugin_application_open(moonbit_string_t index, moonbit_string_t archives,
                                        moonbit_string_t layout);
moonbit_string_t plugin_application_request(int32_t application, moonbit_string_t request);
int32_t plugin_application_close(int32_t application);
/* Byte/String conversion for native hosts without a Unicode library. A
 * failed decode returns the empty String and leaves a UTF-8 BOM in valid data. */
moonbit_string_t plugin_application_decode_utf8(moonbit_bytes_t bytes);
moonbit_bytes_t plugin_application_encode_utf8(moonbit_string_t text);
/* Read a field from a trusted core reply. index=-1 and child="" skip those
 * selections. literal=1 returns serialized JSON instead of a String value. */
moonbit_string_t plugin_application_reply_field(moonbit_string_t reply, moonbit_string_t key,
    int32_t index, moonbit_string_t child, int32_t literal);

#ifdef __cplusplus
}
#endif
#endif
