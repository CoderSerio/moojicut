#ifndef MC_PLUGIN_WORKER_PROCESS_H
#define MC_PLUGIN_WORKER_PROCESS_H
#include "worker_protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MCPluginProcess MCPluginProcess;
typedef struct {
    /* Absolute UTF-8 path selected from the trusted application bundle by its
     * host. User plugin metadata never selects the executable. Paths and byte
     * ranges are copied before start returns, and are then caller-owned. */
    const char *executable;
    const uint8_t *wasm, *input;
    MCPluginWireRequest wire;
    size_t max_stderr_bytes;
    uint32_t wall_ms;
} MCPluginProcessRequest;

typedef enum {
    MC_PLUGIN_PROCESS_RUNNING = 0,
    MC_PLUGIN_PROCESS_OK,
    MC_PLUGIN_PROCESS_CANCELLED,
    MC_PLUGIN_PROCESS_TIMED_OUT,
    MC_PLUGIN_PROCESS_LAUNCH_FAILED,
    MC_PLUGIN_PROCESS_IO_FAILED,
    MC_PLUGIN_PROCESS_LIMIT_EXCEEDED,
    MC_PLUGIN_PROCESS_EXECUTION_FAILED
} MCPluginProcessStatus;

typedef struct {
    /* Immutable borrowed bytes. Output is exposed only on success. Diagnostics
     * are bounded raw bytes, not a NUL-terminated string. */
    const uint8_t *output, *diagnostics;
    size_t output_size, diagnostics_size;
    uint32_t exit_code, system_error;
} MCPluginProcessResult;

/* Call start, poll, cancel and close from the owning application thread.
 * Start validates and copies the request then schedules background work.
 * Immediate validation/allocation failure returns NULL. The deadline includes
 * child startup, communication, execution and draining. wall_ms must be
 * positive and within MC_PLUGIN_MAX_WALL_SECONDS * 1000. This is a process
 * lifetime boundary, not an OS sandbox. */
MCPluginProcess *mc_plugin_process_start(const MCPluginProcessRequest *request);
/* A terminal result is published only after the process is reaped and all
 * pipe endpoints are closed. It remains readable through repeated polls until
 * close. Running polls clear result. The result parameter may be NULL. */
MCPluginProcessStatus mc_plugin_process_poll(MCPluginProcess *process, MCPluginProcessResult *result);
/* Request cancellation without waiting; a terminal result stays immutable. */
void mc_plugin_process_cancel(MCPluginProcess *process);
/* A running process cannot be disposed. Returns 1 on terminal disposal. */
int mc_plugin_process_close(MCPluginProcess *process);

#ifdef __cplusplus
}
#endif
#endif
