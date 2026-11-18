#include "wasm_runner.h"
#include "extism.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const uint8_t *bytes;
    size_t size, offset;
    int failed;
} Reader;
typedef struct {
    const uint8_t *bytes;
    uint32_t size;
} Name;
typedef struct {
    uint32_t params, results;
    uint8_t arguments[64], returns[16];
} FunctionType;

static uint8_t read_byte(Reader *reader) {
    if (reader->offset >= reader->size) { reader->failed = 1; return 0; }
    return reader->bytes[reader->offset++];
}
static uint32_t read_u32(Reader *reader) {
    uint32_t result = 0;
    for (unsigned i = 0; i < 5; i++) {
        uint8_t byte = read_byte(reader);
        if (reader->failed || (i == 4 && (byte & 0xf0))) { reader->failed = 1; return 0; }
        result |= (uint32_t)(byte & 0x7f) << (i * 7);
        if (!(byte & 0x80)) return result;
    }
    reader->failed = 1;
    return 0;
}
static int valid_utf8(const uint8_t *bytes, size_t size) {
    size_t i = 0;
    while (i < size) {
        uint8_t first = bytes[i++];
        if (first < 0x80) continue;
        unsigned extra;
        uint32_t value, minimum;
        if (first >= 0xc2 && first <= 0xdf) { extra = 1; value = first & 0x1fu; minimum = 0x80; }
        else if (first >= 0xe0 && first <= 0xef) { extra = 2; value = first & 0x0fu; minimum = 0x800; }
        else if (first >= 0xf0 && first <= 0xf4) { extra = 3; value = first & 0x07u; minimum = 0x10000; }
        else return 0;
        if (extra > size - i) return 0;
        for (unsigned j = 0; j < extra; j++) {
            uint8_t next = bytes[i++];
            if ((next & 0xc0) != 0x80) return 0;
            value = (value << 6) | (next & 0x3fu);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return 0;
    }
    return 1;
}
static Name read_name(Reader *reader) {
    Name name = {NULL, 0};
    uint32_t size = read_u32(reader);
    if (reader->failed || size > 128 || size > reader->size - reader->offset) {
        reader->failed = 1;
        return name;
    }
    name.bytes = reader->bytes + reader->offset;
    name.size = size;
    reader->offset += size;
    if (!valid_utf8(name.bytes, name.size)) reader->failed = 1;
    return name;
}
static int name_is(Name name, const char *value) {
    size_t size = strlen(value);
    return name.bytes && name.size == size && !memcmp(name.bytes, value, size);
}
static int name_equal(Name a, Name b) {
    return a.size == b.size && (!a.size || !memcmp(a.bytes, b.bytes, a.size));
}
static int value_type(uint8_t byte) {
    return byte == 0x7f || byte == 0x7e || byte == 0x7d || byte == 0x7c ||
        byte == 0x7b || byte == 0x70 || byte == 0x6f;
}
static int import_type(Name name, const FunctionType *type) {
    if (name_is(name, "output_set")) return type->params == 2 && type->arguments[0] == 0x7e && type->arguments[1] == 0x7e && type->results == 0;
    if (name_is(name, "store_u8")) return type->params == 2 && type->arguments[0] == 0x7e && type->arguments[1] == 0x7f && type->results == 0;
    if (name_is(name, "input_load_u8")) return type->params == 1 && type->arguments[0] == 0x7e && type->results == 1 && type->returns[0] == 0x7f;
    if (name_is(name, "alloc")) return type->params == 1 && type->arguments[0] == 0x7e && type->results == 1 && type->returns[0] == 0x7e;
    if (name_is(name, "input_length")) return type->params == 0 && type->results == 1 && type->returns[0] == 0x7e;
    if (name_is(name, "error_set")) return type->params == 1 && type->arguments[0] == 0x7e && type->results == 0;
    return 0;
}

int mc_wasm_validate_module(const uint8_t *wasm, size_t size) {
    if (!wasm || size < 8 || size > MC_WASM_MAX_MODULE_BYTES || memcmp(wasm, "\0asm\1\0\0\0", 8)) return 0;
    Reader module = {wasm + 8, size - 8, 0, 0};
    FunctionType *types = calloc(4096, sizeof(*types));
    uint32_t *functions = calloc(65536, sizeof(*functions));
    if (!types || !functions) { free(types); free(functions); return 0; }
    uint32_t type_count = 0, function_count = 0, import_count = 0, entry = UINT32_MAX;
    uint16_t seen = 0;
    uint8_t last_rank = 0;
    int valid = 1;
    while (valid && module.offset < module.size) {
        uint8_t id = read_byte(&module);
        uint32_t length = read_u32(&module);
        if (module.failed || id > 12 || length > module.size - module.offset || (id && (seen & (1u << id)))) { valid = 0; break; }
        uint8_t rank = (uint8_t)(id == 12 ? 10 : id >= 10 ? id + 1 : id);
        if (id && rank <= last_rank) { valid = 0; break; }
        if (id) { seen = (uint16_t)(seen | (1u << id)); last_rank = rank; }
        Reader section = {module.bytes + module.offset, length, 0, 0};
        module.offset += length;
        if (id == 1) {
            type_count = read_u32(&section);
            if (type_count > 4096) { valid = 0; break; }
            for (uint32_t i = 0; i < type_count && !section.failed; i++) {
                if (read_byte(&section) != 0x60) { section.failed = 1; break; }
                types[i].params = read_u32(&section);
                if (types[i].params > 64) { section.failed = 1; break; }
                for (uint32_t j = 0; j < types[i].params; j++) if (!value_type(types[i].arguments[j] = read_byte(&section))) section.failed = 1;
                types[i].results = read_u32(&section);
                if (types[i].results > 16) { section.failed = 1; break; }
                for (uint32_t j = 0; j < types[i].results; j++) if (!value_type(types[i].returns[j] = read_byte(&section))) section.failed = 1;
            }
        } else if (id == 2) {
            uint32_t count = read_u32(&section);
            if (count > 64 || count > 65536 - function_count) { valid = 0; break; }
            for (uint32_t i = 0; i < count && !section.failed; i++) {
                Name space = read_name(&section), name = read_name(&section);
                uint8_t kind = read_byte(&section);
                if (section.failed || kind != 0 || !name_is(space, "extism:host/env")) { section.failed = 1; break; }
                uint32_t type = read_u32(&section);
                if (section.failed || type >= type_count || !import_type(name, &types[type])) { section.failed = 1; break; }
                functions[function_count++] = type;
                import_count++;
            }
        } else if (id == 3) {
            uint32_t count = read_u32(&section);
            if (count > 65536 - function_count) { valid = 0; break; }
            for (uint32_t i = 0; i < count && !section.failed; i++) {
                uint32_t type = read_u32(&section);
                if (type >= type_count) { section.failed = 1; break; }
                functions[function_count++] = type;
            }
        } else if (id == 7) {
            uint32_t count = read_u32(&section);
            if (count > 256) { valid = 0; break; }
            Name names[256];
            for (uint32_t i = 0; i < count && !section.failed; i++) {
                Name name = read_name(&section);
                uint8_t kind = read_byte(&section);
                uint32_t index = read_u32(&section);
                if (section.failed) break;
                for (uint32_t j = 0; j < i; j++) if (name_equal(names[j], name)) section.failed = 1;
                if (section.failed) break;
                names[i] = name;
                if (name_is(name, "mooji_run")) {
                    if (kind != 0 || index < import_count || index >= function_count) { section.failed = 1; break; }
                    entry = index;
                }
            }
        } else section.offset = section.size;
        if (section.failed || section.offset != section.size) valid = 0;
    }
    if (entry == UINT32_MAX || entry >= function_count) valid = 0;
    if (valid) {
        const FunctionType *type = &types[functions[entry]];
        valid = type->params == 0 && type->results == 1 && type->returns[0] == 0x7f;
    }
    free(types);
    free(functions);
    return valid;
}

static MCWasmRunStatus fail(MCWasmRunResult *result, MCWasmRunStatus status, const char *message) {
    if (!message) message = "Plugin execution failed";
    size_t length = 0;
    while (length < MC_WASM_DIAGNOSTIC_BYTES && message[length]) length++;
    memcpy(result->diagnostic, message, length);
    result->diagnostic[length] = '\0';
    return status;
}
static char *runtime_manifest(const MCWasmRunRequest *request, size_t *length) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    static const char prefix[] = "{\"wasm\":[{\"data\":\"";
    char suffix[256];
    int n = snprintf(suffix, sizeof(suffix), "\"}],\"timeout_ms\":%" PRIu32 ",\"memory\":{\"max_pages\":%" PRIu32 ",\"max_http_response_bytes\":0,\"max_var_bytes\":0},\"allowed_hosts\":[],\"allowed_paths\":{}}", request->timeout_ms, request->max_memory_pages);
    if (n < 0 || (size_t)n >= sizeof(suffix)) return NULL;
    size_t encoded = ((request->wasm_size + 2) / 3) * 4;
    *length = sizeof(prefix) - 1 + encoded + (size_t)n;
    char *manifest = malloc(*length + 1);
    if (!manifest) return NULL;
    memcpy(manifest, prefix, sizeof(prefix) - 1);
    char *output = manifest + sizeof(prefix) - 1;
    for (size_t i = 0; i < request->wasm_size; i += 3) {
        size_t remaining = request->wasm_size - i;
        uint32_t word = (uint32_t)request->wasm[i] << 16;
        if (remaining > 1) word |= (uint32_t)request->wasm[i + 1] << 8;
        if (remaining > 2) word |= request->wasm[i + 2];
        *output++ = alphabet[(word >> 18) & 63];
        *output++ = alphabet[(word >> 12) & 63];
        *output++ = remaining > 1 ? alphabet[(word >> 6) & 63] : '=';
        *output++ = remaining > 2 ? alphabet[word & 63] : '=';
    }
    memcpy(output, suffix, (size_t)n + 1);
    return manifest;
}

MCWasmRunStatus mc_wasm_run(const MCWasmRunRequest *request, MCWasmRunResult *result) {
    if (!result) return MC_WASM_INVALID_REQUEST;
    memset(result, 0, sizeof(*result));
    if (!request || !request->wasm || !request->input)
        return fail(result, MC_WASM_INVALID_REQUEST, "Worker IPC limit exceeded");
    MCPluginWireRequest wire = {
        .wasm_size = request->wasm_size, .input_size = request->input_size,
        .max_output_bytes = request->max_output_bytes, .fuel = request->fuel,
        .timeout_ms = request->timeout_ms, .max_memory_pages = request->max_memory_pages
    };
    if (!mc_plugin_wire_request_valid(&wire))
        return fail(result, MC_WASM_INVALID_REQUEST, "Worker IPC limit exceeded");
    if (!mc_wasm_validate_module(request->wasm, request->wasm_size))
        return fail(result, MC_WASM_INVALID_MODULE, "Unsupported Wasm imports, sections or mooji_run signature");
    const char *version = extism_version();
    if (!version || strcmp(version, MC_WASM_RUNTIME_VERSION))
        return fail(result, MC_WASM_RUNTIME_MISMATCH, "Unexpected Extism runtime version");
    size_t manifest_size = 0;
    char *manifest = runtime_manifest(request, &manifest_size);
    if (!manifest) return fail(result, MC_WASM_ALLOCATION_FAILED, "Cannot allocate runtime manifest");
    char *error = NULL;
    ExtismPlugin *plugin = extism_plugin_new_with_fuel_limit((const uint8_t *)manifest, (ExtismSize)manifest_size, NULL, 0, false, request->fuel, &error);
    free(manifest);
    if (!plugin) {
        MCWasmRunStatus status = fail(result, MC_WASM_EXECUTION_FAILED, error);
        if (error) extism_plugin_new_error_free(error);
        return status;
    }
    MCWasmRunStatus status = MC_WASM_OK;
    if (!extism_plugin_function_exists(plugin, "mooji_run"))
        status = fail(result, MC_WASM_EXECUTION_FAILED, "Missing mooji_run export");
    else if (extism_plugin_call(plugin, "mooji_run", request->input, (ExtismSize)request->input_size) != EXTISM_SUCCESS)
        status = fail(result, MC_WASM_EXECUTION_FAILED, extism_plugin_error(plugin));
    else {
        ExtismSize size = extism_plugin_output_length(plugin);
        const uint8_t *bytes = extism_plugin_output_data(plugin);
        if (size > request->max_output_bytes) status = fail(result, MC_WASM_OUTPUT_LIMIT, "Plugin output limit exceeded");
        else if (size && !bytes) status = fail(result, MC_WASM_EXECUTION_FAILED, "Missing plugin output bytes");
        else if (size) {
            result->output = malloc((size_t)size);
            if (!result->output) status = fail(result, MC_WASM_ALLOCATION_FAILED, "Cannot allocate plugin output");
            else { memcpy(result->output, bytes, (size_t)size); result->output_size = (size_t)size; }
        }
    }
    extism_plugin_free(plugin);
    return status;
}

void mc_wasm_result_clear(MCWasmRunResult *result) {
    if (!result) return;
    free(result->output);
    memset(result, 0, sizeof(*result));
}
