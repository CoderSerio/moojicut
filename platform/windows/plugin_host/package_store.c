#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "../../shared/plugin_host/package_store.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* The host supplies a private, trusted profile parent. New directories/files
 * inherit its ACL; this Kernel32 adapter does not claim to inspect DACLs. Every
 * path component is pinned without FILE_SHARE_DELETE, and reparse points,
 * device paths/streams and hardlinked files are rejected. No plugin policy,
 * archive decoding or hashing belongs in this filesystem adapter. */
typedef struct {
    wchar_t *path;
    HANDLE *directories;
    size_t count;
} StoreRoot;
static volatile LONG64 temporary_sequence = 0;

static MCPluginStoreStatus fail(MCPluginStoreError *error, MCPluginStoreStatus status,
    const char *operation, DWORD code) {
    if (error) {
        error->system_error = code;
        if (code) snprintf(error->message, sizeof(error->message), "%s (Win32 %lu)", operation, (unsigned long)code);
        else snprintf(error->message, sizeof(error->message), "%s", operation);
    }
    return status;
}
static void reset_error(MCPluginStoreError *error) { if (error) memset(error, 0, sizeof(*error)); }
static bool missing(DWORD error) { return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND; }
static bool collision(DWORD error) { return error == ERROR_FILE_EXISTS || error == ERROR_ALREADY_EXISTS; }
static bool separator(wchar_t c) { return c == L'\\' || c == L'/'; }
static bool drive_letter(wchar_t c) { return (c >= L'A' && c <= L'Z') || (c >= L'a' && c <= L'z'); }
static bool valid_digest(const char *digest) {
    if (!digest) return false;
    for (size_t i = 0; i < 64; ++i)
        if (!((digest[i] >= '0' && digest[i] <= '9') || (digest[i] >= 'a' && digest[i] <= 'f'))) return false;
    return digest[64] == 0;
}
static bool component_valid(const wchar_t *part, size_t length) {
    if (!length || length > 255 || part[length - 1] == L'.' || part[length - 1] == L' ') return false;
    size_t base = 0;
    for (size_t i = 0; i < length; ++i) {
        wchar_t c = part[i];
        if (c < 32 || c == L':' || c == L'"' || c == L'<' || c == L'>' || c == L'|' || c == L'?' || c == L'*') return false;
        if (!base && c == L'.') base = i;
    }
    if (!base) base = length;
    if ((base == 3 && (!_wcsnicmp(part, L"CON", 3) || !_wcsnicmp(part, L"PRN", 3) ||
                      !_wcsnicmp(part, L"AUX", 3) || !_wcsnicmp(part, L"NUL", 3))) ||
        (base == 4 && (!_wcsnicmp(part, L"COM", 3) || !_wcsnicmp(part, L"LPT", 3)) &&
                     ((part[3] >= L'0' && part[3] <= L'9') || part[3] == 0x00b9 || part[3] == 0x00b2 || part[3] == 0x00b3))) return false;
    return true;
}
/* Canonical extended drive/UNC path. Reject ambiguous components rather than
 * asking Win32 to normalize relative names, DOS devices or alternate streams. */
static wchar_t *root_path(const char *utf8, size_t *volume_end) {
    if (!utf8) return NULL;
    size_t bytes = 0;
    while (bytes <= 4096 && utf8[bytes]) ++bytes;
    if (!bytes || bytes > 4096) return NULL;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, (int)bytes, NULL, 0);
    if (count < 4) return NULL;
    wchar_t *input = calloc((size_t)count + 1, sizeof(*input));
    wchar_t *result = calloc((size_t)count + 9, sizeof(*result));
    if (!input || !result) { free(input); free(result); return NULL; }
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, (int)bytes, input, count) != count) goto invalid;
    for (int i = 0; i < count; ++i) if (input[i] == L'/') input[i] = L'\\';
    const wchar_t *path = input;
    bool extended = count >= 4 && !wcsncmp(path, L"\\\\?\\", 4);
    if (extended) path += 4;
    if (drive_letter(path[0]) && path[1] == L':' && path[2] == L'\\') {
        memcpy(result, L"\\\\?\\", 4 * sizeof(*result));
        memcpy(result + 4, path, (wcslen(path) + 1) * sizeof(*result));
        *volume_end = 7;
    } else {
        const wchar_t *server;
        if (extended && !_wcsnicmp(path, L"UNC\\", 4)) server = path + 4;
        else if (!extended && path[0] == L'\\' && path[1] == L'\\') server = path + 2;
        else goto invalid;
        const wchar_t *share = wcschr(server, L'\\');
        if (!share || !component_valid(server, (size_t)(share - server))) goto invalid;
        ++share;
        const wchar_t *after = wcschr(share, L'\\');
        if (!after || !component_valid(share, (size_t)(after - share))) goto invalid;
        memcpy(result, L"\\\\?\\UNC\\", 8 * sizeof(*result));
        memcpy(result + 8, server, (wcslen(server) + 1) * sizeof(*result));
        *volume_end = 8 + (size_t)(after - server) + 1;
    }
    size_t length = wcslen(result), start = *volume_end;
    if (start >= length || separator(result[length - 1])) goto invalid;
    for (size_t i = start; i <= length; ++i) {
        if (i == length || result[i] == L'\\') {
            if (!component_valid(result + start, i - start)) goto invalid;
            start = i + 1;
        }
    }
    free(input);
    return result;
invalid:
    free(input); free(result); return NULL;
}
static wchar_t *child_path(const wchar_t *directory, const wchar_t *name) {
    size_t a = wcslen(directory), b = wcslen(name);
    wchar_t *path = calloc(a + b + 2, sizeof(*path));
    if (path) {
        memcpy(path, directory, a * sizeof(*path)); path[a] = L'\\';
        memcpy(path + a + 1, name, (b + 1) * sizeof(*path));
    }
    return path;
}
static bool file_info(HANDLE handle, BY_HANDLE_FILE_INFORMATION *info, bool directory) {
    if (GetFileType(handle) != FILE_TYPE_DISK || !GetFileInformationByHandle(handle, info) ||
        (info->dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
    return directory ? (info->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 :
        !(info->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && info->nNumberOfLinks == 1;
}
static bool identity_equal(const BY_HANDLE_FILE_INFORMATION *a, const BY_HANDLE_FILE_INFORMATION *b) {
    return a->dwVolumeSerialNumber == b->dwVolumeSerialNumber && a->nFileIndexHigh == b->nFileIndexHigh &&
        a->nFileIndexLow == b->nFileIndexLow && ((a->dwFileAttributes ^ b->dwFileAttributes) & FILE_ATTRIBUTE_DIRECTORY) == 0;
}
static bool file_unchanged(const BY_HANDLE_FILE_INFORMATION *a, const BY_HANDLE_FILE_INFORMATION *b) {
    return identity_equal(a, b) && a->nFileSizeHigh == b->nFileSizeHigh && a->nFileSizeLow == b->nFileSizeLow &&
        a->nNumberOfLinks == b->nNumberOfLinks && !CompareFileTime(&a->ftCreationTime, &b->ftCreationTime) &&
        !CompareFileTime(&a->ftLastWriteTime, &b->ftLastWriteTime);
}
static bool inspect_path(const wchar_t *path, BY_HANDLE_FILE_INFORMATION *info) {
    HANDLE file = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (file == INVALID_HANDLE_VALUE) return false;
    bool valid = file_info(file, info, false);
    CloseHandle(file);
    return valid;
}
static void root_close(StoreRoot *root) {
    for (size_t i = root->count; i; --i) CloseHandle(root->directories[i - 1]);
    free(root->directories); free(root->path); memset(root, 0, sizeof(*root));
}
static bool root_current(const StoreRoot *root) {
    for (size_t i = 0; i < root->count; ++i) {
        BY_HANDLE_FILE_INFORMATION info;
        if (!file_info(root->directories[i], &info, true)) return false;
    }
    return true;
}
static MCPluginStoreStatus root_open(const char *path, bool create, StoreRoot *root, MCPluginStoreError *error) {
    memset(root, 0, sizeof(*root));
    size_t volume_end = 0;
    root->path = root_path(path, &volume_end);
    if (!root->path) return fail(error, MC_PLUGIN_STORE_INVALID, "Invalid absolute UTF-8 store root", 0);
    size_t length = wcslen(root->path);
    root->directories = calloc(length + 1, sizeof(*root->directories));
    if (!root->directories) { root_close(root); return fail(error, MC_PLUGIN_STORE_IO, "Cannot allocate directory guards", ERROR_NOT_ENOUGH_MEMORY); }
    /* All ancestors are already host-owned/trusted. Only the final root may
     * be created; holding every ancestor prevents path substitution via rename. */
    for (size_t end = volume_end; end <= length; ++end) {
        if (end != volume_end && end != length && root->path[end] != L'\\') continue;
        wchar_t saved = root->path[end]; root->path[end] = 0;
        if (end == length && create && !CreateDirectoryW(root->path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) {
            DWORD code = GetLastError(); root->path[end] = saved; root_close(root);
            return fail(error, MC_PLUGIN_STORE_IO, "Cannot create store root", code);
        }
        HANDLE directory = CreateFileW(root->path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
            NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
        DWORD code = GetLastError(); root->path[end] = saved;
        if (directory == INVALID_HANDLE_VALUE) {
            root_close(root);
            return !create && missing(code) ? MC_PLUGIN_STORE_MISSING : fail(error, MC_PLUGIN_STORE_IO, "Cannot open store directory", code);
        }
        BY_HANDLE_FILE_INFORMATION info;
        if (!file_info(directory, &info, true)) {
            CloseHandle(directory); root_close(root);
            return fail(error, MC_PLUGIN_STORE_INVALID, "Store paths must be directories without reparse points", 0);
        }
        root->directories[root->count++] = directory;
    }
    return MC_PLUGIN_STORE_OK;
}
static MCPluginStoreStatus packages_open(StoreRoot *root, bool create, wchar_t **path, MCPluginStoreError *error) {
    *path = child_path(root->path, L"packages");
    if (!*path) return fail(error, MC_PLUGIN_STORE_IO, "Cannot allocate package path", ERROR_NOT_ENOUGH_MEMORY);
    if (create && !CreateDirectoryW(*path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS)
        return fail(error, MC_PLUGIN_STORE_IO, "Cannot create package directory", GetLastError());
    HANDLE directory = CreateFileW(*path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (directory == INVALID_HANDLE_VALUE) {
        DWORD code = GetLastError();
        return !create && missing(code) ? MC_PLUGIN_STORE_MISSING : fail(error, MC_PLUGIN_STORE_IO, "Cannot open package directory", code);
    }
    BY_HANDLE_FILE_INFORMATION info;
    if (!file_info(directory, &info, true)) {
        CloseHandle(directory);
        return fail(error, MC_PLUGIN_STORE_INVALID, "Package directory cannot be a reparse point", 0);
    }
    root->directories[root->count++] = directory;
    return MC_PLUGIN_STORE_OK;
}
static MCPluginStoreStatus acquire_lock(const StoreRoot *root, HANDLE *lock, MCPluginStoreError *error) {
    wchar_t *path = child_path(root->path, L".lock");
    if (!path) return fail(error, MC_PLUGIN_STORE_IO, "Cannot allocate lock path", ERROR_NOT_ENOUGH_MEMORY);
    *lock = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    DWORD code = GetLastError(); free(path);
    if (*lock == INVALID_HANDLE_VALUE)
        return fail(error, code == ERROR_SHARING_VIOLATION || code == ERROR_LOCK_VIOLATION ? MC_PLUGIN_STORE_BUSY : MC_PLUGIN_STORE_IO,
            "Cannot acquire exclusive store lock", code);
    BY_HANDLE_FILE_INFORMATION info;
    if (!file_info(*lock, &info, false)) return fail(error, MC_PLUGIN_STORE_INVALID, "Store lock must be an independent regular file", 0);
    return root_current(root) ? MC_PLUGIN_STORE_OK : fail(error, MC_PLUGIN_STORE_STALE, "Store identity changed before lock", 0);
}
void mc_plugin_store_bytes_free(MCPluginStoreBytes *bytes) {
    if (bytes) { free(bytes->bytes); memset(bytes, 0, sizeof(*bytes)); }
}
static MCPluginStoreStatus read_file(const wchar_t *path, size_t limit, MCPluginStoreBytes *output,
    BY_HANDLE_FILE_INFORMATION *identity, MCPluginStoreError *error) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        DWORD code = GetLastError();
        return missing(code) ? MC_PLUGIN_STORE_MISSING : fail(error, MC_PLUGIN_STORE_IO, "Cannot open store file", code);
    }
    BY_HANDLE_FILE_INFORMATION before, after;
    MCPluginStoreBytes result = {0};
    MCPluginStoreStatus status = MC_PLUGIN_STORE_OK;
    if (!file_info(file, &before, false) || before.nFileSizeHigh || (size_t)before.nFileSizeLow > limit)
        status = fail(error, MC_PLUGIN_STORE_INVALID, "Store file must be independent, regular and bounded", 0);
    if (status == MC_PLUGIN_STORE_OK) {
        result.size = (size_t)before.nFileSizeLow; result.bytes = malloc(result.size + 1);
        if (!result.bytes) status = fail(error, MC_PLUGIN_STORE_IO, "Cannot allocate bounded store read", ERROR_NOT_ENOUGH_MEMORY);
    }
    size_t offset = 0;
    while (status == MC_PLUGIN_STORE_OK && offset < result.size) {
        DWORD count = 0, chunk = (DWORD)(result.size - offset > 65536 ? 65536 : result.size - offset);
        if (!ReadFile(file, result.bytes + offset, chunk, &count, NULL)) status = fail(error, MC_PLUGIN_STORE_IO, "Cannot read store file", GetLastError());
        else if (!count) status = fail(error, MC_PLUGIN_STORE_STALE, "Store file shortened during read", 0);
        else offset += count;
    }
    if (status == MC_PLUGIN_STORE_OK) {
        uint8_t extra; DWORD count = 0;
        if (!ReadFile(file, &extra, 1, &count, NULL)) status = fail(error, MC_PLUGIN_STORE_IO, "Cannot finish store read", GetLastError());
        else if (count || !file_info(file, &after, false) || !file_unchanged(&before, &after)) status = fail(error, MC_PLUGIN_STORE_STALE, "Store file changed during read", 0);
    }
    if (!CloseHandle(file) && status == MC_PLUGIN_STORE_OK) status = fail(error, MC_PLUGIN_STORE_IO, "Cannot close store read", GetLastError());
    if (status != MC_PLUGIN_STORE_OK) { mc_plugin_store_bytes_free(&result); return status; }
    result.bytes[result.size] = 0; *output = result; if (identity) *identity = before;
    return status;
}
static bool bytes_equal(const MCPluginStoreBytes *a, const uint8_t *b, size_t size) {
    return a->size == size && (!size || !memcmp(a->bytes, b, size));
}
static void remove_owned(const wchar_t *path, const BY_HANDLE_FILE_INFORMATION *identity) {
    BY_HANDLE_FILE_INFORMATION current;
    if (path && inspect_path(path, &current) && identity_equal(identity, &current)) DeleteFileW(path);
}
static MCPluginStoreStatus write_temporary(const wchar_t *directory, const uint8_t *bytes, size_t size,
    wchar_t **path, BY_HANDLE_FILE_INFORMATION *identity, MCPluginStoreError *error) {
    HANDLE file = INVALID_HANDLE_VALUE;
    for (unsigned attempt = 0; attempt < 128; ++attempt) {
        wchar_t name[96];
        unsigned long long sequence = (unsigned long long)InterlockedIncrement64(&temporary_sequence);
        int written = swprintf_s(name, sizeof(name) / sizeof(name[0]), L".stage-%lu-%llu-%llu",
            (unsigned long)GetCurrentProcessId(), (unsigned long long)GetTickCount64(), sequence);
        if (written < 0) return fail(error, MC_PLUGIN_STORE_IO, "Cannot name staging file", ERROR_INVALID_NAME);
        *path = child_path(directory, name);
        if (!*path) return fail(error, MC_PLUGIN_STORE_IO, "Cannot allocate staging path", ERROR_NOT_ENOUGH_MEMORY);
        file = CreateFileW(*path, GENERIC_WRITE, 0, NULL, CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, NULL);
        if (file != INVALID_HANDLE_VALUE) break;
        DWORD code = GetLastError(); free(*path); *path = NULL;
        if (!collision(code)) return fail(error, MC_PLUGIN_STORE_IO, "Cannot exclusively create staging file", code);
    }
    if (file == INVALID_HANDLE_VALUE) return fail(error, MC_PLUGIN_STORE_IO, "Staging names exhausted", ERROR_FILE_EXISTS);
    MCPluginStoreStatus status = MC_PLUGIN_STORE_OK;
    if (!file_info(file, identity, false)) status = fail(error, MC_PLUGIN_STORE_IO, "Cannot inspect staging file", GetLastError());
    size_t offset = 0;
    while (status == MC_PLUGIN_STORE_OK && offset < size) {
        DWORD count = 0, chunk = (DWORD)(size - offset > 65536 ? 65536 : size - offset);
        if (!WriteFile(file, bytes + offset, chunk, &count, NULL)) status = fail(error, MC_PLUGIN_STORE_IO, "Cannot write staging file", GetLastError());
        else if (!count) status = fail(error, MC_PLUGIN_STORE_IO, "Empty staging write", ERROR_WRITE_FAULT);
        else offset += count;
    }
    if (status == MC_PLUGIN_STORE_OK && !FlushFileBuffers(file)) status = fail(error, MC_PLUGIN_STORE_IO, "Cannot flush staging file", GetLastError());
    if (!CloseHandle(file) && status == MC_PLUGIN_STORE_OK) status = fail(error, MC_PLUGIN_STORE_IO, "Cannot close staging file", GetLastError());
    if (status != MC_PLUGIN_STORE_OK) { remove_owned(*path, identity); free(*path); *path = NULL; }
    return status;
}
static MCPluginStoreStatus confirm_existing(const wchar_t *path, const BY_HANDLE_FILE_INFORMATION *identity, MCPluginStoreError *error) {
    HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, NULL);
    if (file == INVALID_HANDLE_VALUE) return fail(error, MC_PLUGIN_STORE_IO, "Cannot confirm store durability", GetLastError());
    BY_HANDLE_FILE_INFORMATION current;
    MCPluginStoreStatus status = MC_PLUGIN_STORE_OK;
    if (!file_info(file, &current, false) || !file_unchanged(identity, &current)) status = fail(error, MC_PLUGIN_STORE_STALE, "Store file changed before durability check", 0);
    else if (!FlushFileBuffers(file)) status = fail(error, MC_PLUGIN_STORE_COMMITTED_NOT_DURABLE, "Existing bytes remain visible but flush failed", GetLastError());
    CloseHandle(file);
    return status;
}
static MCPluginStoreStatus publish(const wchar_t *temporary, const wchar_t *destination, bool replace,
    const BY_HANDLE_FILE_INFORMATION *identity, MCPluginStoreError *error) {
    if (MoveFileExW(temporary, destination, MOVEFILE_WRITE_THROUGH | (replace ? MOVEFILE_REPLACE_EXISTING : 0))) return MC_PLUGIN_STORE_OK;
    DWORD code = GetLastError();
    BY_HANDLE_FILE_INFORMATION current;
    if (inspect_path(destination, &current) && identity_equal(identity, &current))
        return fail(error, MC_PLUGIN_STORE_COMMITTED_NOT_DURABLE, "Published bytes are visible but move completion failed", code);
    return fail(error, collision(code) ? MC_PLUGIN_STORE_CONFLICT : MC_PLUGIN_STORE_IO, "Cannot atomically publish store file", code);
}
MCPluginStoreStatus mc_plugin_store_read_snapshot(const char *path, MCPluginStoreBytes *output, MCPluginStoreError *error) {
    reset_error(error);
    if (!output || output->bytes || output->size) return fail(error, MC_PLUGIN_STORE_INVALID, "Output must be empty", 0);
    StoreRoot root; MCPluginStoreStatus status = root_open(path, false, &root, error);
    if (status != MC_PLUGIN_STORE_OK) return status;
    wchar_t *name = child_path(root.path, L"snapshot.bin"); MCPluginStoreBytes result = {0};
    status = name ? read_file(name, MC_PLUGIN_STORE_SNAPSHOT_LIMIT, &result, NULL, error) : fail(error, MC_PLUGIN_STORE_IO, "Cannot allocate snapshot path", ERROR_NOT_ENOUGH_MEMORY);
    if ((status == MC_PLUGIN_STORE_OK || status == MC_PLUGIN_STORE_MISSING) && !root_current(&root)) status = fail(error, MC_PLUGIN_STORE_STALE, "Store changed during read", 0);
    free(name); root_close(&root);
    if (status == MC_PLUGIN_STORE_OK) *output = result; else mc_plugin_store_bytes_free(&result);
    return status;
}
static wchar_t *zip_path(const wchar_t *directory, const char *digest) {
    wchar_t name[69];
    for (size_t i = 0; i < 64; ++i) name[i] = (wchar_t)digest[i];
    memcpy(name + 64, L".zip", 5 * sizeof(*name));
    return child_path(directory, name);
}
MCPluginStoreStatus mc_plugin_store_read_zip(const char *path, const char *digest, MCPluginStoreBytes *output, MCPluginStoreError *error) {
    reset_error(error);
    if (!valid_digest(digest) || !output || output->bytes || output->size) return fail(error, MC_PLUGIN_STORE_INVALID, "Invalid digest or nonempty output", 0);
    StoreRoot root; MCPluginStoreStatus status = root_open(path, false, &root, error);
    if (status != MC_PLUGIN_STORE_OK) return status;
    wchar_t *directory = NULL, *name = NULL; MCPluginStoreBytes result = {0};
    status = packages_open(&root, false, &directory, error);
    if (status == MC_PLUGIN_STORE_OK) {
        name = zip_path(directory, digest);
        status = name ? read_file(name, MC_PLUGIN_STORE_ZIP_LIMIT, &result, NULL, error) : fail(error, MC_PLUGIN_STORE_IO, "Cannot allocate ZIP path", ERROR_NOT_ENOUGH_MEMORY);
    }
    if ((status == MC_PLUGIN_STORE_OK || status == MC_PLUGIN_STORE_MISSING) && !root_current(&root)) status = fail(error, MC_PLUGIN_STORE_STALE, "Package storage changed during read", 0);
    free(name); free(directory); root_close(&root);
    if (status == MC_PLUGIN_STORE_OK) *output = result; else mc_plugin_store_bytes_free(&result);
    return status;
}
MCPluginStoreStatus mc_plugin_store_replace_snapshot(const char *path, bool expected_exists,
    const uint8_t *expected, size_t expected_size, const uint8_t *replacement, size_t size, MCPluginStoreError *error) {
    reset_error(error);
    if (expected_size > MC_PLUGIN_STORE_SNAPSHOT_LIMIT || size > MC_PLUGIN_STORE_SNAPSHOT_LIMIT ||
        (expected_size && !expected) || (size && !replacement) || (!expected_exists && (expected || expected_size)))
        return fail(error, MC_PLUGIN_STORE_INVALID, "Invalid snapshot byte ranges", 0);
    StoreRoot root; MCPluginStoreStatus status = root_open(path, true, &root, error);
    if (status != MC_PLUGIN_STORE_OK) return status;
    wchar_t *name = child_path(root.path, L"snapshot.bin"), *temporary = NULL;
    HANDLE lock = INVALID_HANDLE_VALUE; MCPluginStoreBytes current = {0};
    BY_HANDLE_FILE_INFORMATION original = {0}, staging = {0}, observed;
    if (!name) { status = fail(error, MC_PLUGIN_STORE_IO, "Cannot allocate snapshot path", ERROR_NOT_ENOUGH_MEMORY); goto done; }
    status = acquire_lock(&root, &lock, error); if (status != MC_PLUGIN_STORE_OK) goto done;
    status = read_file(name, MC_PLUGIN_STORE_SNAPSHOT_LIMIT, &current, &original, error);
    if (status != MC_PLUGIN_STORE_OK && status != MC_PLUGIN_STORE_MISSING) goto done;
    bool exists = status == MC_PLUGIN_STORE_OK;
    if (!root_current(&root)) { status = fail(error, MC_PLUGIN_STORE_STALE, "Store identity changed before CAS", 0); goto done; }
    if (exists != expected_exists || (exists && !bytes_equal(&current, expected, expected_size))) {
        status = fail(error, MC_PLUGIN_STORE_STALE, "Snapshot does not match expected bytes or absence", 0); goto done;
    }
    if (exists && bytes_equal(&current, replacement, size)) { status = confirm_existing(name, &original, error); goto done; }
    status = write_temporary(root.path, replacement, size, &temporary, &staging, error); if (status != MC_PLUGIN_STORE_OK) goto done;
    if (!root_current(&root) || !inspect_path(temporary, &observed) || !identity_equal(&staging, &observed) ||
        (exists && (!inspect_path(name, &observed) || !file_unchanged(&original, &observed)))) {
        status = fail(error, MC_PLUGIN_STORE_STALE, "Snapshot identity changed before publication", 0); goto done;
    }
    status = publish(temporary, name, exists, &staging, error);
    if (status == MC_PLUGIN_STORE_CONFLICT) status = fail(error, MC_PLUGIN_STORE_STALE, "Snapshot appeared before publication", error ? error->system_error : 0);
done:
    remove_owned(temporary, &staging); free(temporary); free(name); mc_plugin_store_bytes_free(&current);
    if (lock != INVALID_HANDLE_VALUE) CloseHandle(lock);
    root_close(&root); return status;
}
MCPluginStoreStatus mc_plugin_store_stage_zip(const char *path, const char *digest, const uint8_t *bytes, size_t size, MCPluginStoreError *error) {
    reset_error(error);
    if (!valid_digest(digest) || size > MC_PLUGIN_STORE_ZIP_LIMIT || (size && !bytes)) return fail(error, MC_PLUGIN_STORE_INVALID, "Invalid digest or ZIP byte range", 0);
    StoreRoot root; MCPluginStoreStatus status = root_open(path, true, &root, error);
    if (status != MC_PLUGIN_STORE_OK) return status;
    HANDLE lock = INVALID_HANDLE_VALUE;
    wchar_t *directory = NULL, *name = NULL, *temporary = NULL; MCPluginStoreBytes current = {0};
    BY_HANDLE_FILE_INFORMATION original = {0}, staging = {0}, observed;
    status = acquire_lock(&root, &lock, error); if (status != MC_PLUGIN_STORE_OK) goto done;
    status = packages_open(&root, true, &directory, error); if (status != MC_PLUGIN_STORE_OK) goto done;
    name = zip_path(directory, digest);
    if (!name) { status = fail(error, MC_PLUGIN_STORE_IO, "Cannot allocate ZIP path", ERROR_NOT_ENOUGH_MEMORY); goto done; }
    status = read_file(name, MC_PLUGIN_STORE_ZIP_LIMIT, &current, &original, error);
    if ((status == MC_PLUGIN_STORE_OK || status == MC_PLUGIN_STORE_MISSING) && !root_current(&root)) { status = fail(error, MC_PLUGIN_STORE_STALE, "Package identity changed during comparison", 0); goto done; }
    if (status == MC_PLUGIN_STORE_OK) {
        status = bytes_equal(&current, bytes, size) ? confirm_existing(name, &original, error) : fail(error, MC_PLUGIN_STORE_CONFLICT, "Digest already names different bytes", 0); goto done;
    }
    if (status != MC_PLUGIN_STORE_MISSING) goto done;
    status = write_temporary(directory, bytes, size, &temporary, &staging, error); if (status != MC_PLUGIN_STORE_OK) goto done;
    if (!root_current(&root) || !inspect_path(temporary, &observed) || !identity_equal(&staging, &observed)) { status = fail(error, MC_PLUGIN_STORE_STALE, "Package identity changed before publication", 0); goto done; }
    status = publish(temporary, name, false, &staging, error);
    if (status == MC_PLUGIN_STORE_CONFLICT) {
        status = read_file(name, MC_PLUGIN_STORE_ZIP_LIMIT, &current, &original, error);
        if (status == MC_PLUGIN_STORE_OK) status = bytes_equal(&current, bytes, size) ? confirm_existing(name, &original, error) : fail(error, MC_PLUGIN_STORE_CONFLICT, "Digest publication conflicts with existing bytes", 0);
    }
done:
    remove_owned(temporary, &staging); free(temporary); free(name); free(directory); mc_plugin_store_bytes_free(&current);
    if (lock != INVALID_HANDLE_VALUE) CloseHandle(lock);
    root_close(&root); return status;
}
