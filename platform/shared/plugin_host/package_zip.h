#ifndef MOOJICUT_PLUGIN_PACKAGE_ZIP_H
#define MOOJICUT_PLUGIN_PACKAGE_ZIP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    MC_PLUGIN_ZIP_MAX_BYTES = 8 * 1024 * 1024,
    MC_PLUGIN_ZIP_MAX_MANIFEST_BYTES = 64 * 1024,
    MC_PLUGIN_ZIP_MAX_WASM_BYTES = 4 * 1024 * 1024,
    MC_PLUGIN_ZIP_MAX_ICON_BYTES = 256 * 1024,
    MC_PLUGIN_ZIP_MAX_EXPANDED_BYTES = 5 * 1024 * 1024
};

typedef struct {
    const uint8_t *bytes;
    size_t size;
} MCPluginZipBytes;

typedef struct {
    MCPluginZipBytes manifest;
    MCPluginZipBytes wasm;
    MCPluginZipBytes icon;
    bool has_icon; /* An absent icon differs from an empty icon entry. */
    void *storage; /* Private allocation; release only with mc_plugin_zip_clear. */
} MCPluginZipPackage;

typedef enum {
    MC_PLUGIN_ZIP_OK = 0,
    MC_PLUGIN_ZIP_ARGUMENT,
    MC_PLUGIN_ZIP_INVALID,
    MC_PLUGIN_ZIP_LIMIT,
    MC_PLUGIN_ZIP_MEMORY,
    MC_PLUGIN_ZIP_DEFLATE_REQUIRED,
    MC_PLUGIN_ZIP_DEFLATE_FAILED,
    MC_PLUGIN_ZIP_CRC
} MCPluginZipError;

/* A trusted native adapter, not a plugin callback. Return true only at the raw
 * DEFLATE stream end. Never write beyond output_capacity. Report exact input
 * consumed/output written, including on failure when available. The reader
 * requires all packed bytes consumed and precisely the declared output size.
 * Capacity is declared size + 1, so overflow and an empty stream can be detected.
 * No ownership transfers to this callback; pointers expire when it returns. */
typedef bool (*MCPluginZipInflate)(void *context, const uint8_t *input, size_t input_size,
    uint8_t *output, size_t output_capacity, size_t *input_consumed, size_t *output_written);

/* Strict single-disk ZIP32: manifest.json, plugin.wasm, optional assets/icon.png
 * and optional empty assets/. Stored and raw-DEFLATE only; local/central records,
 * CRC, descriptors, bounds and the complete contiguous local area are validated.
 * No file IO, manifest interpretation, Wasm execution, hashing or image decoding.
 * Initialize output to {0}; clear before reusing a successful output. On failure
 * output is unchanged. On success its bytes are independent of the ZIP buffer.
 * A NULL inflater is valid for stored archives; deflated entries fail explicitly.
 * The input must remain immutable for this synchronous call. error may be NULL. */
bool mc_plugin_zip_read(const uint8_t *zip, size_t size, MCPluginZipInflate inflate_raw,
    void *context, MCPluginZipPackage *output, MCPluginZipError *error);
void mc_plugin_zip_clear(MCPluginZipPackage *package);
const char *mc_plugin_zip_error_text(MCPluginZipError error);

#ifdef __cplusplus
}
#endif
#endif
