#include "wasm_runner.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#else
#include <unistd.h>
#endif

/* Private, one-request IPC: eight-byte magic, seven big-endian u32 words,
 * then immutable Wasm and input bytes. The last two words form the fuel u64.
 * The parent must close stdin and enforce a wall deadline, including reads. */
enum { InputFD = 0, OutputFD = 1, ErrorFD = 2, IOChunk = 64 * 1024 };

static long ReadSome(int fd, void *bytes, size_t size) {
    size_t chunk = size < IOChunk ? size : IOChunk;
#ifdef _WIN32
    return (long)_read(fd, bytes, (unsigned int)chunk);
#else
    return (long)read(fd, bytes, chunk);
#endif
}
static long WriteSome(int fd, const void *bytes, size_t size) {
    size_t chunk = size < IOChunk ? size : IOChunk;
#ifdef _WIN32
    return (long)_write(fd, bytes, (unsigned int)chunk);
#else
    return (long)write(fd, bytes, chunk);
#endif
}
static int ReadExact(void *bytes, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        long n = ReadSome(InputFD, (uint8_t *)bytes + offset, size - offset);
        if (n > 0) offset += (size_t)n;
        else if (n < 0 && errno == EINTR) continue;
        else return 0;
    }
    return 1;
}
static int WriteExact(int fd, const void *bytes, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        long n = WriteSome(fd, (const uint8_t *)bytes + offset, size - offset);
        if (n > 0) offset += (size_t)n;
        else if (n < 0 && errno == EINTR) continue;
        else return 0;
    }
    return 1;
}
static int Failure(const char *message) {
    size_t size = 0;
    if (!message) message = "Plugin execution failed";
    while (size < MC_WASM_DIAGNOSTIC_BYTES && message[size]) size++;
    WriteExact(ErrorFD, message, size);
    WriteExact(ErrorFD, "\n", 1);
    return 1;
}
int main(void) {
#ifdef _WIN32
    /* Text mode would reinterpret CR/LF and Ctrl+Z inside Wasm/input/output. */
    if (_setmode(InputFD, _O_BINARY) == -1 || _setmode(OutputFD, _O_BINARY) == -1 ||
        _setmode(ErrorFD, _O_BINARY) == -1)
        return Failure("Cannot configure binary worker IPC");
#endif
    uint8_t header[MC_PLUGIN_WIRE_HEADER_BYTES];
    if (!ReadExact(header, sizeof(header)))
        return Failure("Invalid worker IPC header");
    MCPluginWireRequest wire;
    MCPluginWireStatus decoded = mc_plugin_wire_decode(header, sizeof(header), &wire);
    if (decoded == MC_PLUGIN_WIRE_INVALID_HEADER) return Failure("Invalid worker IPC header");
    if (decoded != MC_PLUGIN_WIRE_OK)
        return Failure("Worker IPC limit exceeded");

    /* The validated independent caps also bound this sum on 32-bit size_t. */
    uint8_t *payload = malloc(wire.wasm_size + wire.input_size);
    if (!payload) return Failure("Cannot allocate worker request");
    MCWasmRunResult result = {0};
    int exitCode;
    if (!ReadExact(payload, wire.wasm_size + wire.input_size)) {
        exitCode = Failure("Truncated worker request");
        goto cleanup;
    }
    uint8_t extra;
    long remaining;
    do { remaining = ReadSome(InputFD, &extra, 1); } while (remaining < 0 && errno == EINTR);
    if (remaining != 0) {
        exitCode = Failure("Unexpected trailing worker input");
        goto cleanup;
    }
    MCWasmRunRequest request = {
        .wasm = payload, .wasm_size = wire.wasm_size,
        .input = payload + wire.wasm_size, .input_size = wire.input_size,
        .fuel = wire.fuel, .timeout_ms = wire.timeout_ms,
        .max_memory_pages = wire.max_memory_pages, .max_output_bytes = (uint32_t)wire.max_output_bytes
    };
    MCWasmRunStatus status = mc_wasm_run(&request, &result);
    exitCode = status == MC_WASM_OK
        ? (WriteExact(OutputFD, result.output, result.output_size) ? 0 : Failure("Cannot write plugin output"))
        : Failure(result.diagnostic);
cleanup:
    mc_wasm_result_clear(&result);
    free(payload);
    return exitCode;
}
