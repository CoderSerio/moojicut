#ifndef MC_WASM_RUNNER_H
#define MC_WASM_RUNNER_H
#include "worker_protocol.h"
#ifdef __cplusplus
extern "C" {
#endif

#define MC_WASM_RUNTIME_VERSION "1.41.0"

typedef struct {
    /* Borrowed immutable byte ranges, valid until mc_wasm_run returns. */
    const uint8_t *wasm;
    size_t wasm_size;
    const uint8_t *input;
    size_t input_size;
    uint64_t fuel;
    uint32_t timeout_ms;
    uint32_t max_memory_pages;
    uint32_t max_output_bytes;
} MCWasmRunRequest;

typedef enum {
    MC_WASM_OK = 0,
    MC_WASM_INVALID_REQUEST,
    MC_WASM_INVALID_MODULE,
    MC_WASM_RUNTIME_MISMATCH,
    MC_WASM_EXECUTION_FAILED,
    MC_WASM_OUTPUT_LIMIT,
    MC_WASM_ALLOCATION_FAILED
} MCWasmRunStatus;

typedef struct {
    /* Owned by this module, independent of the freed Extism instance. */
    uint8_t *output;
    size_t output_size;
    char diagnostic[MC_WASM_DIAGNOSTIC_BYTES + 1u];
} MCWasmRunResult;

/* Checks the selected plain-Wasm ABI/import boundary, not every instruction.
 * Extism/Wasmtime still validates and instantiates the actual module. No engine
 * initialization, filesystem access or guest execution occurs in this check. */
int mc_wasm_validate_module(const uint8_t *wasm, size_t size);

/* Synchronous CHILD-PROCESS operation, never an application UI-thread API.
 * Call with a zero-initialized or cleared result. Exactly one fresh instance,
 * no WASI/host functions/allowed network hosts/paths, then free the instance.
 * Product request/output JSON and authorization stay in MoonBit/app owners.
 * Parent process remains responsible for startup/compile/IPC wall deadline,
 * stderr/stdout caps, cancellation, forced termination and confirmed reaping.
 * Linear-memory pages do not limit the entire process RSS or constitute an OS
 * sandbox. Limits may be tightened but cannot exceed the constants above. */
MCWasmRunStatus mc_wasm_run(const MCWasmRunRequest *request, MCWasmRunResult *result);

/* Safe for a zero-initialized/cleared result. Never free output with a different
 * allocator/CRT: Windows consumers must call this function in the owning module. */
void mc_wasm_result_clear(MCWasmRunResult *result);

#ifdef __cplusplus
}
#endif
#endif
