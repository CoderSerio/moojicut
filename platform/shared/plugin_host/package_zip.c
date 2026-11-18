#include "package_zip.h"
#include <stdlib.h>
#include <string.h>

enum { MANIFEST, WASM, ICON, ASSETS, ENTRY_COUNT };
typedef struct {
    size_t start, end, data, packed, unpacked;
    uint32_t crc;
    uint16_t method;
    unsigned kind;
} Entry;

static uint16_t word(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}
static uint32_t dword(const uint8_t *p) {
    return (uint32_t)word(p) | ((uint32_t)word(p + 2) << 16);
}
static uint32_t checksum(const uint8_t *p, size_t size) {
    uint32_t crc = UINT32_MAX;
    for (size_t i = 0; i < size; ++i) {
        crc ^= p[i];
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ ((crc & 1u) ? UINT32_C(0xedb88320) : 0u);
    }
    return crc ^ UINT32_MAX;
}
static bool reject(MCPluginZipError *error, MCPluginZipError value) {
    if (error) *error = value;
    return false;
}
static unsigned name_kind(const uint8_t *name, size_t size) {
    static const char *const names[] = {"manifest.json", "plugin.wasm", "assets/icon.png", "assets/"};
    for (unsigned i = 0; i < ENTRY_COUNT; ++i)
        if (strlen(names[i]) == size && !memcmp(name, names[i], size)) return i;
    return ENTRY_COUNT;
}
static size_t entry_limit(unsigned kind) {
    static const size_t limits[] = {MC_PLUGIN_ZIP_MAX_MANIFEST_BYTES,
        MC_PLUGIN_ZIP_MAX_WASM_BYTES, MC_PLUGIN_ZIP_MAX_ICON_BYTES, 0};
    return limits[kind];
}
static bool extra_valid(const uint8_t *p, size_t size, const uint8_t *name, size_t name_size) {
    while (size) {
        if (size < 4) return false;
        unsigned tag = word(p);
        size_t length = word(p + 2);
        if (length > size - 4 || tag == 1 || tag == 0x0017 || tag == 0x9901)
            return false; /* ZIP64, strong encryption, WinZip AES */
        /* Do not let an alternate filename disagree with the exact ASCII entry
         * name. libarchive also exposes Unicode-path extra fields to its caller. */
        if (tag == 0x7075 && (length != 5 + name_size || p[4] != 1 ||
            dword(p + 5) != checksum(name, name_size) || memcmp(p + 9, name, name_size))) return false;
        /* These Unix extensions may encode links independently of the central
         * mode. No link representation is part of this package container. */
        if (tag == 0x756e || (tag == 0x000d && length > 12)) return false;
        p += 4 + length;
        size -= 4 + length;
    }
    return true;
}

static bool index_zip(const uint8_t *zip, size_t size, Entry entries[ENTRY_COUNT],
    size_t *entry_count, size_t *total, MCPluginZipError *error) {
    if (size > MC_PLUGIN_ZIP_MAX_BYTES) return reject(error, MC_PLUGIN_ZIP_LIMIT);
    if (size < 22) return reject(error, MC_PLUGIN_ZIP_INVALID);
    size_t end = SIZE_MAX, low = size > 65557 ? size - 65557 : 0;
    for (size_t pos = size - 22;; --pos) {
        if (dword(zip + pos) == UINT32_C(0x06054b50) && pos + 22 + word(zip + pos + 20) == size) {
            end = pos;
            break;
        }
        if (pos == low) break;
    }
    if (end == SIZE_MAX || word(zip + end + 4) || word(zip + end + 6) ||
        word(zip + end + 8) != word(zip + end + 10)) return reject(error, MC_PLUGIN_ZIP_INVALID);
    size_t count = word(zip + end + 10), central = dword(zip + end + 16);
    if (count < 2 || count > ENTRY_COUNT || central > end || dword(zip + end + 12) != end - central)
        return reject(error, MC_PLUGIN_ZIP_INVALID);
    size_t cursor = central;
    unsigned seen = 0;
    *total = 0;
    for (size_t i = 0; i < count; ++i) {
        if (cursor > end || end - cursor < 46 || dword(zip + cursor) != UINT32_C(0x02014b50))
            return reject(error, MC_PLUGIN_ZIP_INVALID);
        const uint8_t *p = zip + cursor;
        size_t name_size = word(p + 28), extra = word(p + 30), comment = word(p + 32);
        size_t record_size = 46 + name_size + extra + comment;
        if (record_size > end - cursor || word(p + 34) ||
            !extra_valid(p + 46 + name_size, extra, p + 46, name_size))
            return reject(error, MC_PLUGIN_ZIP_INVALID);
        unsigned kind = name_kind(p + 46, name_size);
        uint16_t flags = word(p + 8), method = word(p + 10);
        uint32_t attributes = dword(p + 38), type = (attributes >> 16) & 0170000u;
        if (kind == ENTRY_COUNT || (seen & (1u << kind)) || (flags & UINT16_C(0xf7f1)) ||
            (method != 0 && method != 8) || (type && type != (kind == ASSETS ? 0040000u : 0100000u)) ||
            (kind != ASSETS && (attributes & 0x10u))) return reject(error, MC_PLUGIN_ZIP_INVALID);
        Entry entry = {0};
        entry.kind = kind; entry.method = method; entry.crc = dword(p + 16);
        entry.packed = dword(p + 20); entry.unpacked = dword(p + 24);
        if (entry.unpacked > entry_limit(kind) || entry.unpacked > MC_PLUGIN_ZIP_MAX_EXPANDED_BYTES - *total)
            return reject(error, MC_PLUGIN_ZIP_LIMIT);
        *total += entry.unpacked;
        entry.start = dword(p + 42);
        if (entry.start > central || central - entry.start < 30 ||
            dword(zip + entry.start) != UINT32_C(0x04034b50)) return reject(error, MC_PLUGIN_ZIP_INVALID);
        const uint8_t *local = zip + entry.start;
        size_t local_name = word(local + 26), local_extra = word(local + 28);
        size_t header = 30 + local_name + local_extra;
        if (header > central - entry.start || local_name != name_size ||
            word(local + 6) != flags || word(local + 8) != method ||
            memcmp(local + 30, p + 46, name_size) || entry.packed > central - entry.start - header ||
            !extra_valid(local + 30 + local_name, local_extra, local + 30, local_name))
            return reject(error, MC_PLUGIN_ZIP_INVALID);
        entry.data = entry.start + header;
        entry.end = entry.data + entry.packed;
        if (flags & 8u) {
            if (central - entry.end >= 4 && dword(zip + entry.end) == UINT32_C(0x08074b50)) entry.end += 4;
            if (central - entry.end < 12 || dword(zip + entry.end) != entry.crc ||
                dword(zip + entry.end + 4) != entry.packed || dword(zip + entry.end + 8) != entry.unpacked)
                return reject(error, MC_PLUGIN_ZIP_INVALID);
            entry.end += 12;
        } else if (dword(local + 14) != entry.crc || dword(local + 18) != entry.packed ||
                   dword(local + 22) != entry.unpacked) return reject(error, MC_PLUGIN_ZIP_INVALID);
        if (!method && entry.packed != entry.unpacked) return reject(error, MC_PLUGIN_ZIP_INVALID);
        seen |= 1u << kind;
        entries[i] = entry;
        cursor += record_size;
    }
    if (cursor != end || !(seen & (1u << MANIFEST)) || !(seen & (1u << WASM)))
        return reject(error, MC_PLUGIN_ZIP_INVALID);
    /* At most four records: fixed insertion sort, no allocation or unbounded scan. */
    for (size_t i = 1; i < count; ++i) {
        Entry value = entries[i];
        size_t j = i;
        while (j && entries[j - 1].start > value.start) { entries[j] = entries[j - 1]; --j; }
        entries[j] = value;
    }
    cursor = 0;
    for (size_t i = 0; i < count; ++i) {
        if (entries[i].start != cursor) return reject(error, MC_PLUGIN_ZIP_INVALID);
        cursor = entries[i].end;
    }
    if (cursor != central) return reject(error, MC_PLUGIN_ZIP_INVALID);
    *entry_count = count;
    return true;
}

void mc_plugin_zip_clear(MCPluginZipPackage *package) {
    if (!package) return;
    free(package->storage);
    memset(package, 0, sizeof(*package));
}

bool mc_plugin_zip_read(const uint8_t *zip, size_t size, MCPluginZipInflate inflate_raw,
    void *context, MCPluginZipPackage *output, MCPluginZipError *error) {
    if (error) *error = MC_PLUGIN_ZIP_OK;
    if (!zip || !output || output->storage || output->manifest.bytes || output->wasm.bytes ||
        output->icon.bytes || output->manifest.size || output->wasm.size || output->icon.size || output->has_icon)
        return reject(error, MC_PLUGIN_ZIP_ARGUMENT);
    Entry entries[ENTRY_COUNT];
    size_t count = 0, total = 0;
    if (!index_zip(zip, size, entries, &count, &total, error)) return false;
    for (size_t i = 0; i < count; ++i)
        if (entries[i].method && !inflate_raw) return reject(error, MC_PLUGIN_ZIP_DEFLATE_REQUIRED);
    MCPluginZipPackage package = {0};
    uint8_t *storage = malloc(total + count);
    if (!storage) return reject(error, MC_PLUGIN_ZIP_MEMORY);
    package.storage = storage;
    size_t offset = 0;
    for (size_t i = 0; i < count; ++i) {
        const Entry *entry = &entries[i];
        uint8_t *bytes = storage + offset;
        if (entry->method) {
            size_t consumed = 0, written = 0;
            if (!inflate_raw(context, zip + entry->data, entry->packed, bytes,
                    entry->unpacked + 1, &consumed, &written) || consumed != entry->packed || written != entry->unpacked) {
                mc_plugin_zip_clear(&package);
                return reject(error, MC_PLUGIN_ZIP_DEFLATE_FAILED);
            }
        } else {
            memcpy(bytes, zip + entry->data, entry->unpacked);
        }
        if (checksum(bytes, entry->unpacked) != entry->crc) {
            mc_plugin_zip_clear(&package);
            return reject(error, MC_PLUGIN_ZIP_CRC);
        }
        bytes[entry->unpacked] = 0;
        MCPluginZipBytes view = {bytes, entry->unpacked};
        switch (entry->kind) {
            case MANIFEST: package.manifest = view; break;
            case WASM: package.wasm = view; break;
            case ICON: package.icon = view; package.has_icon = true; break;
            case ASSETS: break;
        }
        offset += entry->unpacked + 1;
    }
    *output = package;
    return true;
}

const char *mc_plugin_zip_error_text(MCPluginZipError error) {
    switch (error) {
        case MC_PLUGIN_ZIP_OK: return "OK";
        case MC_PLUGIN_ZIP_ARGUMENT: return "Invalid input or output is not empty";
        case MC_PLUGIN_ZIP_INVALID: return "Invalid, unsupported or ambiguous ZIP32 package";
        case MC_PLUGIN_ZIP_LIMIT: return "ZIP package exceeds a byte limit";
        case MC_PLUGIN_ZIP_MEMORY: return "Cannot allocate bounded package buffer";
        case MC_PLUGIN_ZIP_DEFLATE_REQUIRED: return "Raw DEFLATE adapter is required";
        case MC_PLUGIN_ZIP_DEFLATE_FAILED: return "Invalid DEFLATE stream or byte count";
        case MC_PLUGIN_ZIP_CRC: return "ZIP payload CRC does not match";
    }
    return "Unknown ZIP error";
}
