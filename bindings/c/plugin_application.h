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
moonbit_string_t plugin_application_open(moonbit_string_t index, moonbit_string_t archives,
                                        moonbit_string_t layout);
moonbit_string_t plugin_application_request(int32_t application, moonbit_string_t request);
int32_t plugin_application_close(int32_t application);

#ifdef __cplusplus
}
#endif
#endif
