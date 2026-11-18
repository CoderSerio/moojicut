#ifndef MOOJICUT_PLUGIN_PACKAGE_STORE_H
#define MOOJICUT_PLUGIN_PACKAGE_STORE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { MC_PLUGIN_STORE_SNAPSHOT_LIMIT = 1024 * 1024,
       MC_PLUGIN_STORE_ZIP_LIMIT = 8 * 1024 * 1024 };
typedef enum {
    MC_PLUGIN_STORE_OK = 0,
    MC_PLUGIN_STORE_MISSING,
    MC_PLUGIN_STORE_STALE,
    MC_PLUGIN_STORE_CONFLICT,
    MC_PLUGIN_STORE_INVALID,
    MC_PLUGIN_STORE_BUSY,
    MC_PLUGIN_STORE_IO,
    /* Publication succeeded, but the containing directory could not be synced.
     * This is committed, NOT a failed CAS. Read back/reconcile; never retry as if
     * expected bytes were still current. Repeating the same desired bytes may
     * confirm durability. No previous version is restored behind the caller. */
    MC_PLUGIN_STORE_COMMITTED_NOT_DURABLE
} MCPluginStoreStatus;
typedef struct { uint8_t *bytes; size_t size; } MCPluginStoreBytes;
typedef struct { uint32_t system_error; char message[256]; } MCPluginStoreError;

/* Host-selected absolute UTF-8 root (normally its private plugins-v2 directory).
 * Parent must already exist and be trusted. Mutations may create only root and
 * its packages/ directory; reads never create anything. Fixed layout:
 * snapshot.bin, packages/<64-lowercase-SHA256>.zip, .lock, owned temporary files.
 * No JSON parsing, SHA calculation, ZIP validation, plugin policy or garbage
 * collection. The caller rehashes returned ZIP bytes and owns all policy.
 * Synchronous bounded IO: run outside the GUI; a held transaction lock returns
 * BUSY instead of waiting. Concurrent callers/processes use the same CAS lock.
 * Byte arguments remain immutable until return. No pointers are retained.
 * Output must start {0}; failures/MISSING leave it unchanged. An empty existing
 * snapshot returns OK with size 0, distinctly from MISSING. Use the free helper
 * even on Windows, where allocator ownership must not cross CRT boundaries. */
MCPluginStoreStatus mc_plugin_store_read_snapshot(const char *root,
    MCPluginStoreBytes *output, MCPluginStoreError *error);
MCPluginStoreStatus mc_plugin_store_replace_snapshot(const char *root,
    bool expected_exists, const uint8_t *expected, size_t expected_size,
    const uint8_t *replacement, size_t replacement_size, MCPluginStoreError *error);
MCPluginStoreStatus mc_plugin_store_stage_zip(const char *root, const char *digest,
    const uint8_t *bytes, size_t size, MCPluginStoreError *error);
MCPluginStoreStatus mc_plugin_store_read_zip(const char *root, const char *digest,
    MCPluginStoreBytes *output, MCPluginStoreError *error);
void mc_plugin_store_bytes_free(MCPluginStoreBytes *bytes);

/* replace_snapshot compares exact current bytes (or actual absence) under lock.
 * expected_exists=false requires expected=NULL, expected_size=0. For an existing
 * empty file use expected_exists=true, expected=NULL, expected_size=0.
 * STALE never changes the snapshot; read_snapshot obtains the new current value.
 * stage_zip publishes exclusively: an existing identical ZIP is OK, a different
 * byte sequence is CONFLICT, and existing/foreign files are never deleted.
 * Invalid/unreadable files fail closed, never masquerading as MISSING. POSIX
 * refuses symlinks, nonregular/hardlinked files and nonprivate store directories;
 * the Windows implementation must provide equivalent reparse/file-ID checks. */
#ifdef __cplusplus
}
#endif
#endif
