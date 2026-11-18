#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* Runs outside the portable bundle so the application's image and libraries
 * can be closed before asking the Shell to recycle the whole verified folder. */
#define MANIFEST_NAME "uninstall-manifest.txt"
#define MANIFEST_LIMIT (64u * 1024u)
#define FILE_LIMIT 2048u

typedef struct {
    char *name;
    BOOL seen;
} Entry;

typedef struct {
    Entry files[FILE_LIMIT];
    size_t count;
} Inventory;

static BOOL safe_relative_path(const char *path) {
    const char *part = path;
    for (const char *p = path; ; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '/' || c == '\0') {
            if (p == part || p[-1] == '.' || p[-1] == ' ') return FALSE;
            if (!c || !p[1]) return TRUE;
            part = p + 1;
        } else if (c < 32 || c > 126 || strchr("\\:*?\"<>|", c)) {
            return FALSE;
        }
    }
}

static Entry *find_entry(Inventory *inventory, const char *path) {
    for (size_t i = 0; i < inventory->count; i++) {
        if (!strcmp(inventory->files[i].name, path)) return &inventory->files[i];
    }
    return NULL;
}

static BOOL scan_directory(const wchar_t *root, const char *relative, Inventory *inventory, unsigned depth) {
    wchar_t pattern[MAX_PATH];
    WIN32_FIND_DATAW item;
    if (depth > 32 || wcslen(root) + 2 >= ARRAYSIZE(pattern) ||
        swprintf_s(pattern, ARRAYSIZE(pattern), L"%ls\\*", root) < 0) return FALSE;
    HANDLE search = FindFirstFileW(pattern, &item);
    if (search == INVALID_HANDLE_VALUE) return GetLastError() == ERROR_FILE_NOT_FOUND;
    BOOL ok = TRUE;
    do {
        if (!wcscmp(item.cFileName, L".") || !wcscmp(item.cFileName, L"..")) continue;
        if (item.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DEVICE)) {
            ok = FALSE;
            break;
        }
        char name[MAX_PATH], entry[MAX_PATH];
        size_t length = wcslen(item.cFileName);
        for (size_t i = 0; i < length; i++) {
            if (item.cFileName[i] < 32 || item.cFileName[i] > 126) {
                ok = FALSE;
                break;
            }
            name[i] = (char)item.cFileName[i];
        }
        if (!ok) break;
        name[length] = '\0';
        BOOL is_directory = (item.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        if (strlen(relative) + 1 + length >= ARRAYSIZE(entry) ||
            sprintf_s(entry, ARRAYSIZE(entry), "%s%s%s", relative, name, is_directory ? "/" : "") < 0) {
            ok = FALSE;
            break;
        }
        Entry *found = find_entry(inventory, entry);
        ok = found && !found->seen;
        if (ok) found->seen = TRUE;
        if (ok && is_directory) {
            wchar_t child[MAX_PATH];
            ok = wcslen(root) + 1 + length < ARRAYSIZE(child) &&
                swprintf_s(child, ARRAYSIZE(child), L"%ls\\%ls", root, item.cFileName) >= 0 &&
                scan_directory(child, entry, inventory, depth + 1);
        }
    } while (ok && FindNextFileW(search, &item));
    if (ok) ok = GetLastError() == ERROR_NO_MORE_FILES;
    FindClose(search);
    return ok;
}

static BOOL validate_inventory(const wchar_t *root) {
    wchar_t path[MAX_PATH];
    if (wcslen(root) + sizeof(MANIFEST_NAME) >= ARRAYSIZE(path) ||
        swprintf_s(path, ARRAYSIZE(path), L"%ls\\uninstall-manifest.txt", root) < 0) return FALSE;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                             FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) return FALSE;
    BY_HANDLE_FILE_INFORMATION info;
    char *data = malloc(MANIFEST_LIMIT + 1u);
    Inventory *inventory = calloc(1, sizeof(*inventory));
    DWORD size = 0;
    BOOL ok = data && inventory && GetFileInformationByHandle(file, &info) &&
        !(info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) &&
        info.nFileSizeHigh == 0 && info.nFileSizeLow <= MANIFEST_LIMIT &&
        ReadFile(file, data, MANIFEST_LIMIT, &size, NULL) && size == info.nFileSizeLow;
    if (ok) {
        static const char header[] = "MoojiCut portable 1\n";
        ok = size >= sizeof(header) && !memcmp(data, header, sizeof(header) - 1) &&
            !memchr(data, '\0', size) && data[size - 1] == '\n';
        data[size] = '\0';
        char *line = data + sizeof(header) - 1;
        while (ok && *line) {
            char *end = strchr(line, '\n');
            *end = '\0';
            ok = inventory->count < FILE_LIMIT && safe_relative_path(line) &&
                wcslen(root) + 1 + strlen(line) < MAX_PATH &&
                (!inventory->count || strcmp(inventory->files[inventory->count - 1].name, line) < 0);
            if (ok) inventory->files[inventory->count++].name = line;
            line = end + 1;
        }
    }
    if (ok) {
        ok = find_entry(inventory, MANIFEST_NAME) && find_entry(inventory, "build.json") &&
            find_entry(inventory, "MoojiCut.exe") && find_entry(inventory, "MoojiCutUninstaller.exe") &&
            scan_directory(root, "", inventory, 0);
        for (size_t i = 0; ok && i < inventory->count; i++) ok = inventory->files[i].seen;
    }
    CloseHandle(file);
    free(inventory);
    free(data);
    return ok;
}

static HANDLE open_directory(const wchar_t *path) {
    return CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
}

static BOOL ordinary_directory(HANDLE dir, BY_HANDLE_FILE_INFORMATION *info) {
    return GetFileInformationByHandle(dir, info) && (info->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
        !(info->dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT);
}

static BOOL resolve_directory(HANDLE dir, wchar_t path[MAX_PATH]) {
    BY_HANDLE_FILE_INFORMATION original;
    if (!ordinary_directory(dir, &original)) return FALSE;
    wchar_t canonical[MAX_PATH + 4];
    DWORD length = GetFinalPathNameByHandleW(dir, canonical, ARRAYSIZE(canonical), FILE_NAME_NORMALIZED);
    if (length < 8 || length >= ARRAYSIZE(canonical) || wcsncmp(canonical, L"\\\\?\\", 4) ||
        canonical[5] != L':' || canonical[6] != L'\\') return FALSE;
    wcscpy_s(path, MAX_PATH, canonical + 4);
    const wchar_t *base = wcsrchr(path, L'\\');
    if (_wcsicmp(base + 1, L"MoojiCut") != 0) return FALSE;
    wchar_t volume[] = {path[0], L':', L'\\', L'\0'};
    if (GetDriveTypeW(volume) != DRIVE_FIXED) return FALSE;
    HANDLE current = open_directory(path);
    BY_HANDLE_FILE_INFORMATION found;
    BOOL same = current != INVALID_HANDLE_VALUE && ordinary_directory(current, &found) &&
        original.dwVolumeSerialNumber == found.dwVolumeSerialNumber &&
        original.nFileIndexHigh == found.nFileIndexHigh && original.nFileIndexLow == found.nFileIndexLow;
    if (current != INVALID_HANDLE_VALUE) CloseHandle(current);
    return same;
}

static BOOL recycle(const wchar_t *path) {
    IFileOperation *operation = NULL;
    IShellItem *item = NULL;
    BOOL aborted = TRUE;
    HRESULT result = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(result)) return FALSE;
    result = CoCreateInstance(&CLSID_FileOperation, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOperation,
                              (void **)&operation);
    if (SUCCEEDED(result)) result = IFileOperation_SetOperationFlags(operation,
        FOFX_RECYCLEONDELETE | FOFX_ADDUNDORECORD | FOF_WANTNUKEWARNING | FOF_NO_CONNECTED_ELEMENTS);
    if (SUCCEEDED(result)) result = SHCreateItemFromParsingName(path, NULL, &IID_IShellItem, (void **)&item);
    if (SUCCEEDED(result)) result = IFileOperation_DeleteItem(operation, item, NULL);
    if (SUCCEEDED(result)) result = IFileOperation_PerformOperations(operation);
    if (SUCCEEDED(result)) result = IFileOperation_GetAnyOperationsAborted(operation, &aborted);
    if (item) IShellItem_Release(item);
    if (operation) IFileOperation_Release(operation);
    CoUninitialize();
    return SUCCEEDED(result) && !aborted;
}

static HANDLE parse_handle(const wchar_t *text) {
    if (*text < L'0' || *text > L'9') return NULL;
    wchar_t *end = NULL;
    unsigned long long value = wcstoull(text, &end, 10);
    uintptr_t handle = (uintptr_t)value;
    return handle && !*end && handle == value ? (HANDLE)handle : NULL;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command, int show) {
    (void)instance; (void)previous; (void)command; (void)show;
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32);
    int argc = 0;
    wchar_t **args = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!args) return 1;
    wchar_t root[MAX_PATH] = L"";
    int status = 1;
    if (argc == 3 && !wcscmp(args[1], L"--check-bundle")) {
        HANDLE directory = open_directory(args[2]);
        if (directory != INVALID_HANDLE_VALUE) {
            status = resolve_directory(directory, root) && validate_inventory(root) ? 0 : 1;
            CloseHandle(directory);
        }
    } else if (argc == 4 && !wcscmp(args[1], L"--after-exit")) {
        HANDLE process = parse_handle(args[2]), directory = parse_handle(args[3]);
        if (process && directory && WaitForSingleObject(process, 30000) == WAIT_OBJECT_0 &&
            resolve_directory(directory, root) && validate_inventory(root) && recycle(root)) {
            status = 0;
        } else {
            int answer = MessageBoxW(NULL, *root ?
                L"无法将此便携包移到回收站。可打开安装目录，核对后手动删除。" :
                L"卸载未完成。请先退出 Mooji Cut，再检查并手动删除解压的应用文件。",
                L"Mooji Cut", (*root ? MB_OKCANCEL : MB_OK) | MB_ICONWARNING);
            if (*root && answer == IDOK) ShellExecuteW(NULL, L"open", root, NULL, NULL, SW_SHOWNORMAL);
        }
        if (process) CloseHandle(process);
        if (directory) CloseHandle(directory);
    }
    LocalFree(args);
    return status;
}
