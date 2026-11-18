#include "worker_protocol.h"
#include <string.h>

int mc_plugin_wire_request_valid(const MCPluginWireRequest *request) {
    return request && request->wasm_size && request->wasm_size <= MC_WASM_MAX_MODULE_BYTES &&
        request->input_size && request->input_size <= MC_WASM_MAX_INPUT_BYTES &&
        request->max_output_bytes && request->max_output_bytes <= MC_WASM_MAX_OUTPUT_BYTES &&
        request->fuel && request->fuel <= MC_WASM_MAX_FUEL &&
        request->timeout_ms && request->timeout_ms <= MC_WASM_MAX_TIMEOUT_MS &&
        request->max_memory_pages && request->max_memory_pages <= MC_WASM_MAX_MEMORY_PAGES;
}
static void write_u32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)(value >> 24); p[1] = (uint8_t)(value >> 16);
    p[2] = (uint8_t)(value >> 8); p[3] = (uint8_t)value;
}
static uint32_t read_u32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
MCPluginWireStatus mc_plugin_wire_encode(const MCPluginWireRequest *request, uint8_t *header, size_t size) {
    if (!header || size != MC_PLUGIN_WIRE_HEADER_BYTES) return MC_PLUGIN_WIRE_INVALID_HEADER;
    if (!mc_plugin_wire_request_valid(request)) return MC_PLUGIN_WIRE_INVALID_LIMITS;
    memcpy(header, "MOOJIW1\0", 8);
    write_u32(header + 8, (uint32_t)request->wasm_size);
    write_u32(header + 12, (uint32_t)request->input_size);
    write_u32(header + 16, request->timeout_ms);
    write_u32(header + 20, request->max_memory_pages);
    write_u32(header + 24, (uint32_t)request->max_output_bytes);
    write_u32(header + 28, (uint32_t)(request->fuel >> 32));
    write_u32(header + 32, (uint32_t)request->fuel);
    return MC_PLUGIN_WIRE_OK;
}
MCPluginWireStatus mc_plugin_wire_decode(const uint8_t *header, size_t size, MCPluginWireRequest *request) {
    if (!header || !request || size != MC_PLUGIN_WIRE_HEADER_BYTES || memcmp(header, "MOOJIW1\0", 8))
        return MC_PLUGIN_WIRE_INVALID_HEADER;
    MCPluginWireRequest decoded = {
        .wasm_size = read_u32(header + 8), .input_size = read_u32(header + 12),
        .timeout_ms = read_u32(header + 16), .max_memory_pages = read_u32(header + 20),
        .max_output_bytes = read_u32(header + 24),
        .fuel = ((uint64_t)read_u32(header + 28) << 32) | read_u32(header + 32)
    };
    if (!mc_plugin_wire_request_valid(&decoded)) return MC_PLUGIN_WIRE_INVALID_LIMITS;
    *request = decoded;
    return MC_PLUGIN_WIRE_OK;
}
