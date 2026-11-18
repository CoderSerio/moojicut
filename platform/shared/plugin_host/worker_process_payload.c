#include "worker_process_internal.h"
#include <stdlib.h>
#include <string.h>

int mc_plugin_process_prepare(const MCPluginProcessRequest *request,
                              uint8_t **payload, size_t *size) {
    if (!payload || !size) return 0;
    *payload = NULL;
    *size = 0;
    if (!request || !request->executable || !*request->executable ||
        !request->wasm || !request->input || !request->wall_ms ||
        request->wall_ms > (uint32_t)(MC_PLUGIN_MAX_WALL_SECONDS * 1000) ||
        !request->max_stderr_bytes || request->max_stderr_bytes > MC_PLUGIN_MAX_STDERR_BYTES)
        return 0;
    uint8_t header[MC_PLUGIN_WIRE_HEADER_BYTES];
    if (mc_plugin_wire_encode(&request->wire, header, sizeof(header)) != MC_PLUGIN_WIRE_OK)
        return 0;
    size_t length = sizeof(header) + request->wire.wasm_size + request->wire.input_size;
    uint8_t *bytes = malloc(length);
    if (!bytes) return 0;
    memcpy(bytes, header, sizeof(header));
    memcpy(bytes + sizeof(header), request->wasm, request->wire.wasm_size);
    memcpy(bytes + sizeof(header) + request->wire.wasm_size,
           request->input, request->wire.input_size);
    *payload = bytes;
    *size = length;
    return 1;
}
