#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "platform/shared/plugin_host/package_store.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* Uses real Kernel32 files, a second process, competing threads and the same
 * packaged MoonBit ZIP as the worker fixture. No production profile is opened. */
static unsigned checks, failures;
static MCPluginStoreError error;
static const uint8_t a[] = {'o','l','d',0,'A'}, b[] = {'n','e','w',0,'B'}, c[] = {'n','e','w',0,'C'};
#define CHECK(value,label) do { ++checks; if (!(value)) { ++failures; fprintf(stderr,"FAIL Windows package store: %s (Win32 %lu, store %s)\n",label,(unsigned long)GetLastError(),error.message); } } while (0)

static char *utf8(const wchar_t *wide) {
    int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1, NULL, 0, NULL, NULL);
    if (!size) return NULL;
    char *value = malloc((size_t)size);
    if (value && !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1, value, size, NULL, NULL)) { free(value); value = NULL; }
    return value;
}
static wchar_t *wide(const char *value) {
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
    if (!size) return NULL;
    wchar_t *result = calloc((size_t)size, sizeof(*result));
    if (result && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, result, size)) { free(result); result = NULL; }
    return result;
}
static void path_join(wchar_t out[4096], const wchar_t *root, const wchar_t *name) {
    if (swprintf_s(out, 4096, L"%ls\\%ls", root, name) < 0) abort();
}
static bool inspect(const wchar_t *path, BY_HANDLE_FILE_INFORMATION *identity) {
    HANDLE file = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (file == INVALID_HANDLE_VALUE) return false;
    bool ok = GetFileInformationByHandle(file, identity) != 0;
    CloseHandle(file); return ok;
}
static bool same_id(const BY_HANDLE_FILE_INFORMATION *a_id, const BY_HANDLE_FILE_INFORMATION *b_id) {
    return a_id->dwVolumeSerialNumber == b_id->dwVolumeSerialNumber && a_id->nFileIndexHigh == b_id->nFileIndexHigh && a_id->nFileIndexLow == b_id->nFileIndexLow;
}
static bool equals_snapshot(const char *root, const uint8_t *expected, size_t size) {
    MCPluginStoreBytes bytes = {0};
    bool ok = mc_plugin_store_read_snapshot(root, &bytes, &error) == MC_PLUGIN_STORE_OK && bytes.size == size && (!size || !memcmp(bytes.bytes, expected, size));
    mc_plugin_store_bytes_free(&bytes); return ok;
}
static bool load_zip(const char *path, MCPluginStoreBytes *result) {
    wchar_t *name = wide(path); if (!name) return false;
    HANDLE file = CreateFileW(name, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    free(name); if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size; bool ok = GetFileSizeEx(file, &size) && size.QuadPart >= 0 && size.QuadPart <= MC_PLUGIN_STORE_ZIP_LIMIT;
    uint8_t *bytes = ok ? malloc((size_t)size.QuadPart + 1) : NULL;
    DWORD count = 0;
    if (!bytes || !ReadFile(file, bytes, (DWORD)size.QuadPart, &count, NULL) || count != (DWORD)size.QuadPart) ok = false;
    CloseHandle(file);
    if (!ok) { free(bytes); return false; }
    result->bytes = bytes; result->size = count; return true;
}
static unsigned staging_count(const wchar_t *directory) {
    wchar_t pattern[4096]; path_join(pattern, directory, L".stage-*");
    WIN32_FIND_DATAW entry; HANDLE search = FindFirstFileW(pattern, &entry);
    if (search == INVALID_HANDLE_VALUE) return 0;
    unsigned count = 0;
    do { ++count; } while (FindNextFileW(search, &entry));
    FindClose(search); return count;
}
static void remove_fixture(const wchar_t *path) {
    DWORD attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES) return;
    if (!(attributes & FILE_ATTRIBUTE_DIRECTORY)) { SetFileAttributesW(path, FILE_ATTRIBUTE_NORMAL); DeleteFileW(path); return; }
    if (!(attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        wchar_t pattern[4096]; path_join(pattern, path, L"*");
        WIN32_FIND_DATAW entry; HANDLE search = FindFirstFileW(pattern, &entry);
        if (search != INVALID_HANDLE_VALUE) {
            do {
                if (!wcscmp(entry.cFileName, L".") || !wcscmp(entry.cFileName, L"..")) continue;
                wchar_t child[4096]; path_join(child, path, entry.cFileName); remove_fixture(child);
            } while (FindNextFileW(search, &entry));
            FindClose(search);
        }
    }
    RemoveDirectoryW(path);
}
static int lock_child(void) {
    wchar_t root[4096];
    DWORD length = GetEnvironmentVariableW(L"MOOJICUT_STORE_TEST_ROOT", root, 4096);
    if (!length || length >= 4096) return 2;
    char *path = utf8(root); if (!path) return 2;
    MCPluginStoreStatus status = mc_plugin_store_replace_snapshot(path, true, b, sizeof(b), c, sizeof(c), NULL);
    free(path);
    return status == MC_PLUGIN_STORE_BUSY ? 0 : 1;
}
static bool run_lock_child(const wchar_t *root) {
    wchar_t executable[4096], command[4200];
    DWORD size = GetModuleFileNameW(NULL, executable, 4096);
    if (!size || size >= 4096 || swprintf_s(command, 4200, L"\"%ls\" --lock-child", executable) < 0 ||
        !SetEnvironmentVariableW(L"MOOJICUT_STORE_TEST_ROOT", root)) return false;
    STARTUPINFOW startup = {0}; startup.cb = sizeof(startup);
    PROCESS_INFORMATION process = {0};
    BOOL started = CreateProcessW(executable, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process);
    SetEnvironmentVariableW(L"MOOJICUT_STORE_TEST_ROOT", NULL);
    if (!started) return false;
    CloseHandle(process.hThread);
    DWORD wait = WaitForSingleObject(process.hProcess, 5000), code = 2;
    if (wait == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &code);
    else { TerminateProcess(process.hProcess, 99); WaitForSingleObject(process.hProcess, 5000); }
    CloseHandle(process.hProcess);
    return wait == WAIT_OBJECT_0 && code == 0;
}
typedef struct { const char *root; const uint8_t *replacement; HANDLE start; MCPluginStoreStatus status; } Race;
static DWORD WINAPI race_replace(void *context) {
    Race *race = context;
    if (WaitForSingleObject(race->start, 5000) != WAIT_OBJECT_0) return 1;
    for (unsigned attempt = 0; attempt < 1000; ++attempt) {
        race->status = mc_plugin_store_replace_snapshot(race->root, true, a, sizeof(a), race->replacement, sizeof(a), NULL);
        if (race->status != MC_PLUGIN_STORE_BUSY) break;
        Sleep(1);
    }
    return 0;
}
static DWORD trace_handles(const char *phase) {
    DWORD count = 0;
    CHECK(GetProcessHandleCount(GetCurrentProcess(), &count), "read process handle count");
    printf("Windows package store handles after %s: %lu\n", phase, (unsigned long)count);
    return count;
}

static int exercise(char **argv, unsigned attempt) {
    wchar_t base[4096], temporary[4096], root_wide[4096], snapshot[4096], packages[4096], lock_path[4096], zip_name[69], zip_path[4096];
    DWORD base_size = GetTempPathW(4096, base);
    if (!base_size || base_size >= 4096 || swprintf_s(temporary, 4096, L"%lsmoojicut store-%lu-%llu-%u-\x622a\x56fe",
        base, (unsigned long)GetCurrentProcessId(), (unsigned long long)GetTickCount64(), attempt) < 0 || !CreateDirectoryW(temporary, NULL)) return 2;
    path_join(root_wide, temporary, L"plugins-v2"); path_join(snapshot, root_wide, L"snapshot.bin");
    path_join(packages, root_wide, L"packages"); path_join(lock_path, root_wide, L".lock");
    if (strlen(argv[2]) != 64) { remove_fixture(temporary); return 2; }
    for (size_t i = 0; i < 64; ++i) zip_name[i] = (wchar_t)argv[2][i];
    memcpy(zip_name + 64, L".zip", 5 * sizeof(*zip_name)); path_join(zip_path, packages, zip_name);
    char *root = utf8(root_wide); if (!root) { remove_fixture(temporary); return 2; }
    MCPluginStoreBytes bytes = {0}, original_zip = {0};
    CHECK(mc_plugin_store_read_snapshot(root, &bytes, &error) == MC_PLUGIN_STORE_MISSING && !bytes.bytes && GetFileAttributesW(root_wide) == INVALID_FILE_ATTRIBUTES, "missing read does not create store");
    CHECK(mc_plugin_store_read_zip(root, argv[2], &bytes, &error) == MC_PLUGIN_STORE_MISSING && GetFileAttributesW(root_wide) == INVALID_FILE_ATTRIBUTES, "missing ZIP does not create store");
    CHECK(mc_plugin_store_read_snapshot("relative", &bytes, &error) == MC_PLUGIN_STORE_INVALID, "relative root rejected");
    CHECK(mc_plugin_store_read_snapshot("C:\\private\\..\\other", &bytes, &error) == MC_PLUGIN_STORE_INVALID, "parent traversal rejected before IO");
    CHECK(mc_plugin_store_read_snapshot("C:\\private\\store:stream", &bytes, &error) == MC_PLUGIN_STORE_INVALID, "alternate streams rejected before IO");
    CHECK(mc_plugin_store_read_snapshot("\\\\.\\pipe\\name", &bytes, &error) == MC_PLUGIN_STORE_INVALID, "device namespace rejected");
    CHECK(mc_plugin_store_stage_zip(root, "../escape", a, sizeof(a), &error) == MC_PLUGIN_STORE_INVALID && GetFileAttributesW(root_wide) == INVALID_FILE_ATTRIBUTES, "invalid digest creates nothing");
    CHECK(mc_plugin_store_replace_snapshot(root, false, NULL, 0, a, sizeof(a), &error) == MC_PLUGIN_STORE_OK && equals_snapshot(root, a, sizeof(a)), "UTF-8 path and exact binary first snapshot");
    BY_HANDLE_FILE_INFORMATION first = {0}, second = {0};
    CHECK(inspect(snapshot, &first), "snapshot has a file identity");
    CHECK(mc_plugin_store_replace_snapshot(root, false, NULL, 0, b, sizeof(b), &error) == MC_PLUGIN_STORE_STALE && equals_snapshot(root, a, sizeof(a)), "absent expectation cannot overwrite");
    CHECK(mc_plugin_store_replace_snapshot(root, true, b, sizeof(b), c, sizeof(c), &error) == MC_PLUGIN_STORE_STALE && equals_snapshot(root, a, sizeof(a)), "wrong exact bytes preserve old snapshot");
    CHECK(mc_plugin_store_replace_snapshot(root, true, a, sizeof(a), b, sizeof(b), &error) == MC_PLUGIN_STORE_OK && equals_snapshot(root, b, sizeof(b)), "matching CAS replaces complete snapshot");
    CHECK(inspect(snapshot, &second) && !same_id(&first, &second), "replacement has new file ID");
    CHECK(mc_plugin_store_replace_snapshot(root, true, b, sizeof(b), b, sizeof(b), &error) == MC_PLUGIN_STORE_OK && inspect(snapshot, &first) && same_id(&first, &second), "same bytes confirm durability without rewrite");
    trace_handles("snapshot CAS");
    HANDLE lock = CreateFileW(lock_path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    CHECK(lock != INVALID_HANDLE_VALUE, "fixture acquires actual exclusive lock");
    CHECK(mc_plugin_store_replace_snapshot(root, true, b, sizeof(b), c, sizeof(c), &error) == MC_PLUGIN_STORE_BUSY, "busy snapshot mutation does not block");
    CHECK(mc_plugin_store_stage_zip(root, argv[2], a, sizeof(a), &error) == MC_PLUGIN_STORE_BUSY, "ZIP stage uses same lock");
    CHECK(run_lock_child(root_wide), "second real process also returns BUSY");
    if (lock != INVALID_HANDLE_VALUE) CloseHandle(lock);
    trace_handles("child and exclusive lock");
    CHECK(load_zip(argv[1], &original_zip), "load actual MoonBit package ZIP");
    CHECK(mc_plugin_store_stage_zip(root, argv[2], original_zip.bytes, original_zip.size, &error) == MC_PLUGIN_STORE_OK, "immutable ZIP publication");
    CHECK(inspect(zip_path, &first), "ZIP has file identity");
    CHECK(mc_plugin_store_stage_zip(root, argv[2], original_zip.bytes, original_zip.size, &error) == MC_PLUGIN_STORE_OK && inspect(zip_path, &second) && same_id(&first, &second), "same digest reuses exact immutable ZIP");
    CHECK(mc_plugin_store_stage_zip(root, argv[2], a, sizeof(a), &error) == MC_PLUGIN_STORE_CONFLICT, "different bytes under existing digest rejected");
    CHECK(mc_plugin_store_read_zip(root, argv[2], &bytes, &error) == MC_PLUGIN_STORE_OK && bytes.size == original_zip.size && !memcmp(bytes.bytes, original_zip.bytes, bytes.size), "conflict leaves original ZIP intact");
    mc_plugin_store_bytes_free(&bytes);
    CHECK(mc_plugin_store_stage_zip(root, argv[2], a, MC_PLUGIN_STORE_ZIP_LIMIT + 1u, &error) == MC_PLUGIN_STORE_INVALID, "oversized caller ZIP rejected before read");
    CHECK(SetFileAttributesW(snapshot, FILE_ATTRIBUTE_READONLY), "fixture makes destination replacement fail");
    CHECK(mc_plugin_store_replace_snapshot(root, true, b, sizeof(b), c, sizeof(c), &error) == MC_PLUGIN_STORE_IO && equals_snapshot(root, b, sizeof(b)) && !staging_count(root_wide), "failed rename preserves old snapshot and cleans staging");
    CHECK(SetFileAttributesW(snapshot, FILE_ATTRIBUTE_NORMAL), "restore fixture destination");
    CHECK(mc_plugin_store_replace_snapshot(root, true, b, sizeof(b), NULL, 0, &error) == MC_PLUGIN_STORE_OK, "empty opaque snapshot is allowed");
    CHECK(mc_plugin_store_read_snapshot(root, &bytes, &error) == MC_PLUGIN_STORE_OK && bytes.bytes && !bytes.size, "empty snapshot differs from missing");
    mc_plugin_store_bytes_free(&bytes);
    CHECK(mc_plugin_store_replace_snapshot(root, false, NULL, 0, a, sizeof(a), &error) == MC_PLUGIN_STORE_STALE, "empty existing file is not absence");
    CHECK(mc_plugin_store_replace_snapshot(root, true, NULL, 0, a, sizeof(a), &error) == MC_PLUGIN_STORE_OK, "empty exact expected bytes accepted");
    HANDLE start = CreateEventW(NULL, TRUE, FALSE, NULL);
    Race races[2] = {{root, b, start, MC_PLUGIN_STORE_IO}, {root, c, start, MC_PLUGIN_STORE_IO}};
    HANDLE left = start ? CreateThread(NULL, 0, race_replace, &races[0], 0, NULL) : NULL;
    HANDLE right = start ? CreateThread(NULL, 0, race_replace, &races[1], 0, NULL) : NULL;
    if (start) SetEvent(start);
    DWORD left_wait = left ? WaitForSingleObject(left, 10000) : WAIT_FAILED;
    DWORD right_wait = right ? WaitForSingleObject(right, 10000) : WAIT_FAILED;
    CHECK(left_wait == WAIT_OBJECT_0 && right_wait == WAIT_OBJECT_0 &&
        ((races[0].status == MC_PLUGIN_STORE_OK && races[1].status == MC_PLUGIN_STORE_STALE) ||
         (races[1].status == MC_PLUGIN_STORE_OK && races[0].status == MC_PLUGIN_STORE_STALE)), "competing exact CAS publishes only once");
    /* A timed-out IO thread cannot safely outlive its stack context. Fail the
     * fixture process; the test runner retains its external timeout as well. */
    if ((left && left_wait != WAIT_OBJECT_0) || (right && right_wait != WAIT_OBJECT_0)) ExitProcess(1);
    if (left) CloseHandle(left);
    if (right) CloseHandle(right);
    if (start) CloseHandle(start);
    trace_handles("competing writer threads");
    wchar_t alias[4096]; path_join(alias, temporary, L"owned-alias");
    CHECK(CreateHardLinkW(alias, snapshot, NULL) && mc_plugin_store_read_snapshot(root, &bytes, &error) == MC_PLUGIN_STORE_INVALID && !bytes.bytes, "hardlinked snapshot rejected without publishing output");
    DeleteFileW(alias);
    CHECK(CreateHardLinkW(alias, zip_path, NULL) && mc_plugin_store_read_zip(root, argv[2], &bytes, &error) == MC_PLUGIN_STORE_INVALID && !bytes.bytes, "hardlinked ZIP rejected");
    DeleteFileW(alias);
    if (CreateSymbolicLinkW(alias, root_wide, SYMBOLIC_LINK_FLAG_DIRECTORY | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) {
        char *alias_utf8 = utf8(alias);
        CHECK(alias_utf8 && mc_plugin_store_read_snapshot(alias_utf8, &bytes, &error) == MC_PLUGIN_STORE_INVALID, "directory reparse point rejected");
        free(alias_utf8); RemoveDirectoryW(alias);
    } else if (GetLastError() == ERROR_PRIVILEGE_NOT_HELD) {
        printf("SKIP directory symlink fixture: runner does not grant symlink creation\n");
    } else CHECK(false, "create private directory symlink fixture");
    trace_handles("link rejection");
    CHECK(!staging_count(root_wide) && !staging_count(packages), "no owned staging files remain");
    MCPluginStoreBytes source_after = {0};
    CHECK(load_zip(argv[1], &source_after) && source_after.size == original_zip.size && !memcmp(source_after.bytes, original_zip.bytes, original_zip.size), "source package bytes unchanged");
    mc_plugin_store_bytes_free(&source_after); mc_plugin_store_bytes_free(&original_zip); mc_plugin_store_bytes_free(&bytes);
    free(root); remove_fixture(temporary);
    CHECK(GetFileAttributesW(temporary) == INVALID_FILE_ATTRIBUTES && GetLastError() == ERROR_FILE_NOT_FOUND,
        "all file, directory and lock handles permit profile deletion");
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--lock-child")) return lock_child();
    if (argc != 3) { fprintf(stderr, "Usage: plugin-package-store-windows real-plugin.zip lowercase-sha256\n"); return 2; }
    trace_handles("process entry");
    if (exercise(argv, 1) != 0) return 2;
    DWORD previous_handles = trace_handles("first complete profile");
    if (exercise(argv, 2) != 0) return 2;
    DWORD final_handles = trace_handles("second complete profile");
    CHECK(previous_handles == final_handles, "repeating success and failure paths retains no additional handles");
    printf("Windows package store: %u checks, %u failures\n", checks, failures);
    return failures ? 1 : 0;
}
