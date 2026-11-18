#ifndef MC_PLUGIN_WORKER_PROTOCOL_H
#define MC_PLUGIN_WORKER_PROTOCOL_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Private byte protocol, safe to link into the GUI. No engine, allocation,
 * filesystem, process creation or product request/output JSON dependency. */
#define MC_PLUGIN_WIRE_HEADER_BYTES 36u
#define MC_WASM_MAX_MODULE_BYTES (4u * 1024u * 1024u)
#define MC_WASM_MAX_INPUT_BYTES (64u * 1024u)
#define MC_WASM_MAX_OUTPUT_BYTES (256u * 1024u)
#define MC_WASM_MAX_MEMORY_PAGES 1024u
#define MC_WASM_MAX_TIMEOUT_MS 1000u
#define MC_WASM_MAX_FUEL UINT64_C(50000000)
#define MC_WASM_DIAGNOSTIC_BYTES 4096u
#define MC_PLUGIN_MAX_STDERR_BYTES (16u * 1024u)
#define MC_PLUGIN_DEFAULT_WALL_SECONDS 5.0
#define MC_PLUGIN_MAX_WALL_SECONDS 30.0

typedef struct {
    /* size_t avoids truncating host byte lengths before validating the caps. */
    size_t wasm_size, input_size, max_output_bytes;
    uint64_t fuel;
    uint32_t timeout_ms, max_memory_pages;
} MCPluginWireRequest;

typedef enum {
    MC_PLUGIN_WIRE_OK = 0,
    MC_PLUGIN_WIRE_INVALID_HEADER,
    MC_PLUGIN_WIRE_INVALID_LIMITS
} MCPluginWireStatus;

int mc_plugin_wire_request_valid(const MCPluginWireRequest *request);
/* Exactly 36 bytes: magic "MOOJIW1\0", then seven big-endian u32 words:
 * Wasm bytes, input bytes, timeout ms, pages, output bytes, fuel high, fuel low.
 * Failure leaves caller output unchanged. Payload/EOF and OS IO stay in the
 * process adapter; successfully decoding this header authorizes no execution. */
MCPluginWireStatus mc_plugin_wire_encode(const MCPluginWireRequest *request, uint8_t *header, size_t size);
MCPluginWireStatus mc_plugin_wire_decode(const uint8_t *header, size_t size, MCPluginWireRequest *request);

#ifdef __cplusplus
}
#endif
#endif
