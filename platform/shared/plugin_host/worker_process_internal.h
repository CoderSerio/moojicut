#ifndef MC_PLUGIN_WORKER_PROCESS_INTERNAL_H
#define MC_PLUGIN_WORKER_PROCESS_INTERNAL_H
#include "worker_process.h"

/* Copies the validated wire header and both input ranges into one allocation.
 * The adapter owns the result and frees it after stdin closes. Absolute path
 * validation and copying must be done separately by the platform adapter. */
int mc_plugin_process_prepare(const MCPluginProcessRequest *request,
                              uint8_t **payload, size_t *size);
#endif
