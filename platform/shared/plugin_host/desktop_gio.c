#include "desktop.h"
#include <gio/gio.h>
#include <stdlib.h>
#include <string.h>

static bool read_zip(const char *path, uint8_t **bytes, size_t *size, char error[256]) {
    if (!g_path_is_absolute(path) || !g_utf8_validate(path, -1, NULL)) {
        g_strlcpy(error, "Choose an absolute UTF-8 ZIP path.", 256);
        return false;
    }
    GFile *file = g_file_new_for_path(path);
    GError *failure = NULL;
    GFileInputStream *input = g_file_read(file, NULL, &failure);
    g_object_unref(file);
    if (!input) {
        g_strlcpy(error, failure ? failure->message : "Cannot open plugin ZIP.", 256);
        g_clear_error(&failure);
        return false;
    }
    size_t capacity = MC_PLUGIN_ZIP_MAX_BYTES + 1u;
    uint8_t *data = malloc(capacity);
    gsize length = 0;
    bool read = data && g_input_stream_read_all(G_INPUT_STREAM(input), data, capacity, &length,
                                               NULL, &failure);
    g_object_unref(input);
    if (!read || length >= capacity) {
        g_strlcpy(error, failure ? failure->message :
            length >= capacity ? "Plugin ZIP exceeds 8 MiB." : "Cannot read plugin ZIP.", 256);
        g_clear_error(&failure);
        free(data);
        return false;
    }
    *bytes = data;
    *size = length;
    return true;
}

static bool sha256(const uint8_t *bytes, size_t size, char digest[65]) {
    if (size > MC_PLUGIN_ZIP_MAX_BYTES) return false;
    gchar *value = g_compute_checksum_for_data(G_CHECKSUM_SHA256, bytes, size);
    if (!value) return false;
    memcpy(digest, value, 65);
    g_free(value);
    return true;
}

static bool inflate_raw(void *context, const uint8_t *input, size_t input_size,
    uint8_t *output, size_t capacity, size_t *consumed, size_t *written) {
    (void)context;
    GZlibDecompressor *inflater = g_zlib_decompressor_new(G_ZLIB_COMPRESSOR_FORMAT_RAW);
    GConverterResult result = G_CONVERTER_ERROR;
    size_t in = 0, out = 0;
    while (out < capacity) {
        gsize read = 0, produced = 0;
        result = g_converter_convert(G_CONVERTER(inflater), input + in, input_size - in,
            output + out, capacity - out, G_CONVERTER_INPUT_AT_END, &read, &produced, NULL);
        in += read;
        out += produced;
        if (result != G_CONVERTER_CONVERTED || (!read && !produced)) break;
    }
    g_object_unref(inflater);
    *consumed = in;
    *written = out;
    return result == G_CONVERTER_FINISHED;
}

MCDesktopPlugins *mc_desktop_plugins_open(const char *root, const char *worker, const char *layout,
    int32_t capabilities, const MCDesktopPluginHooks *hooks) {
    const MCDesktopPluginPlatform platform = {read_zip, sha256, inflate_raw};
    return mc_desktop_plugins_open_with_platform(root, worker, layout, capabilities, hooks, &platform);
}
