#ifndef MOOJICUT_FILE_SYNC_H
#define MOOJICUT_FILE_SYNC_H

#include <glib.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#endif

/* Flush an existing local file. This primitive neither creates nor publishes
 * files; alias checks, staging ownership and atomic replacement belong to the
 * caller. Windows handles must not cross the GLib DLL / application CRT fd
 * boundary. Preserve the first operation error while always closing the handle. */
static inline gboolean mc_file_sync(const char *path, GError **error) {
#ifdef _WIN32
    gunichar2 *wide = g_utf8_to_utf16(path, -1, NULL, NULL, error);
    if (!wide) return FALSE;
    HANDLE file = CreateFileW((const wchar_t *)wide, GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD code = file == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
    const char *operation = "open";
    g_free(wide);
    if (file != INVALID_HANDLE_VALUE) {
        if (!FlushFileBuffers(file)) { code = GetLastError(); operation = "flush"; }
        if (!CloseHandle(file) && code == ERROR_SUCCESS) { code = GetLastError(); operation = "close"; }
    }
    if (code == ERROR_SUCCESS) return TRUE;
    char *message = g_win32_error_message((gint)code);
    g_set_error(error, g_quark_from_static_string("moojicut-file-sync-win32"), (gint)code,
        "Cannot %s file (Windows error %lu): %s", operation, (unsigned long)code, message);
    g_free(message);
    return FALSE;
#else
    int descriptor = open(path, O_RDWR);
    if (descriptor < 0) {
        int code = errno;
        g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(code), "Cannot open file: %s", g_strerror(code));
        return FALSE;
    }
    int result = fsync(descriptor);
    int code = result ? errno : 0;
    const char *operation = "flush";
    if (close(descriptor) && !code) { code = errno; operation = "close"; }
    if (!code) return TRUE;
    g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(code), "Cannot %s file: %s", operation, g_strerror(code));
    return FALSE;
#endif
}

#endif
