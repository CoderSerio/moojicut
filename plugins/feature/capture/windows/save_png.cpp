#define NOMINMAX
#include "save_png.h"
#include <objidl.h>
#include <gdiplus.h>
#include <cwchar>

BOOL mc_capture_write_png(HGLOBAL dib, const wchar_t *destination) {
    wchar_t directory[MAX_PATH];
    if (wcscpy_s(directory, destination) != 0) return FALSE;
    wchar_t *separator = wcsrchr(directory, L'\\');
    if (!separator) return FALSE;
    separator[1] = L'\0';

    Gdiplus::GdiplusStartupInput input;
    ULONG_PTR runtime = 0;
    if (Gdiplus::GdiplusStartup(&runtime, &input, nullptr) != Gdiplus::Ok) return FALSE;
    BOOL saved = FALSE;
    wchar_t temporary[MAX_PATH];
    if (GetTempFileNameW(directory, L"mjc", 0, temporary)) {
        const auto *info = static_cast<const BITMAPINFO *>(GlobalLock(dib));
        if (info) {
            const BYTE *pixels = reinterpret_cast<const BYTE *>(info) + info->bmiHeader.biSize;
            // System GDI+ PNG encoder. Keep the staging file on the target volume.
            const CLSID png = {0x557cf406, 0x1a04, 0x11d3, {0x9a,0x73,0x00,0x00,0xf8,0x1e,0xf3,0x2e}};
            {
                Gdiplus::Bitmap bitmap(info, const_cast<BYTE *>(pixels));
                saved = bitmap.GetLastStatus() == Gdiplus::Ok && bitmap.Save(temporary, &png) == Gdiplus::Ok;
            }
            GlobalUnlock(dib);
        }
        if (saved) saved = MoveFileExW(temporary, destination, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
        if (!saved) DeleteFileW(temporary);
    }
    Gdiplus::GdiplusShutdown(runtime);
    return saved;
}
