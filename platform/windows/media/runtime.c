#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include "runtime.h"

static bool fail(wchar_t *error, size_t capacity, const wchar_t *message) {
    if (error && capacity) swprintf_s(error, capacity, L"%ls (Windows error %lu)", message, GetLastError());
    return false;
}

static bool set_variable(const wchar_t *key, const wchar_t *value, wchar_t *error, size_t capacity) {
    if (SetEnvironmentVariableW(key, value)) return true;
    return fail(error, capacity, L"Cannot configure the private media runtime");
}

bool mc_win_media_runtime_init(wchar_t *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    wchar_t directory[32768], path[32768], cache[32768];
    // Match the isolated build/runtime checks. Inherited SDK paths, feature
    // ranks or disabled registry updates must not silently alter this bundle.
    LPWCH environment = GetEnvironmentStringsW();
    if (!environment) return fail(error, capacity, L"Cannot inspect media environment");
    bool cleared = true;
    for (const wchar_t *entry = environment; *entry; entry += wcslen(entry) + 1) {
        if (_wcsnicmp(entry, L"GST_", 4) && _wcsnicmp(entry, L"GSTREAMER_", 10) &&
            _wcsnicmp(entry, L"GIO_", 4) && _wcsnicmp(entry, L"GSETTINGS_SCHEMA_DIR=", 21) &&
            _wcsnicmp(entry, L"GI_TYPELIB_PATH=", 16)) continue;
        const wchar_t *equals = wcschr(entry, L'=');
        if (!equals || equals == entry) continue;
        size_t size = (size_t)(equals - entry);
        if (size >= 32768) { cleared = false; break; }
        memcpy(path, entry, size * sizeof(wchar_t)); path[size] = 0;
        if (!SetEnvironmentVariableW(path, NULL)) { cleared = false; break; }
    }
    FreeEnvironmentStringsW(environment);
    if (!cleared) return fail(error, capacity, L"Cannot clear inherited media configuration");
    DWORD length = GetModuleFileNameW(NULL, directory, 32768);
    if (!length || length >= 32768) return fail(error, capacity, L"Cannot locate the application directory");
    wchar_t *separator = wcsrchr(directory, L'\\');
    if (!separator) return fail(error, capacity, L"Invalid application path");
    *separator = 0;
    if (swprintf_s(path, 32768, L"%ls\\runtime\\gstreamer\\plugins", directory) < 0)
        return fail(error, capacity, L"Media runtime path is too long");
    DWORD attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY))
        return fail(error, capacity, L"The application media runtime is missing. Extract the entire download");
    if (!set_variable(L"GST_PLUGIN_SYSTEM_PATH_1_0", path, error, capacity) ||
        !set_variable(L"GST_PLUGIN_SYSTEM_PATH", path, error, capacity) ||
        !set_variable(L"GST_PLUGIN_PATH_1_0", L"", error, capacity) ||
        !set_variable(L"GST_PLUGIN_PATH", L"", error, capacity)) return false;
    if (swprintf_s(path, 32768, L"%ls\\gst-plugin-scanner.exe", directory) < 0)
        return fail(error, capacity, L"Media scanner path is too long");
    attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY))
        return fail(error, capacity, L"The application media scanner is missing");
    if (!set_variable(L"GST_PLUGIN_SCANNER_1_0", path, error, capacity) ||
        !set_variable(L"GST_PLUGIN_SCANNER", path, error, capacity)) return false;
    DWORD count = GetEnvironmentVariableW(L"MOOJICUT_MEDIA_CACHE_DIR", cache, 32768);
    if (count >= 32768) return fail(error, capacity, L"Media cache path is too long");
    if (count) {
        if (!((count >= 3 && cache[1] == L':' && (cache[2] == L'\\' || cache[2] == L'/')) ||
              (count >= 2 && cache[0] == L'\\' && cache[1] == L'\\')))
            return fail(error, capacity, L"Media cache path must be absolute");
    } else {
        PWSTR base = NULL;
        if (FAILED(SHGetKnownFolderPath(&FOLDERID_LocalAppData, 0, NULL, &base)))
            return fail(error, capacity, L"Cannot locate the media cache directory");
        int copied = swprintf_s(cache, 32768, L"%ls\\MoojiCut\\Cache\\Media", base);
        CoTaskMemFree(base);
        if (copied < 0) return fail(error, capacity, L"Media cache path is too long");
    }
    int created = SHCreateDirectoryExW(NULL, cache, NULL);
    if (created != ERROR_SUCCESS && created != ERROR_ALREADY_EXISTS && created != ERROR_FILE_EXISTS) {
        SetLastError((DWORD)created); return fail(error, capacity, L"Cannot create the media cache directory");
    }
    attributes = GetFileAttributesW(cache);
    if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY))
        return fail(error, capacity, L"Media cache is not a directory");
    if (swprintf_s(path, 32768, L"%ls\\registry-x64.bin", cache) < 0)
        return fail(error, capacity, L"Media registry path is too long");
    if (!set_variable(L"GST_REGISTRY_1_0", path, error, capacity) ||
        !set_variable(L"GST_REGISTRY", path, error, capacity)) return false;
    if (swprintf_s(path, 32768, L"%ls\\runtime\\gio-modules", directory) < 0)
        return fail(error, capacity, L"Media module path is too long");
    if (!set_variable(L"GIO_MODULE_DIR", path, error, capacity) ||
        !set_variable(L"GIO_EXTRA_MODULES", L"", error, capacity) ||
        !set_variable(L"GIO_USE_VFS", L"local", error, capacity) ||
        !set_variable(L"GIO_USE_PROXY_RESOLVER", L"dummy", error, capacity)) return false;
    if (swprintf_s(path, 32768, L"%ls\\runtime\\schemas", directory) < 0)
        return fail(error, capacity, L"Media schema path is too long");
    if (!set_variable(L"GSETTINGS_SCHEMA_DIR", path, error, capacity)) return false;
    // Initial imports resolve beside the EXE before this function. Subsequent
    // plugin loads also resolve only application/system libraries, never cwd.
    if (!SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32))
        return fail(error, capacity, L"Cannot configure media DLL search directories");
    return true;
}
