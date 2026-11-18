#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include "updates.h"
#include "bindings/c/update_release.h"
#include <bcrypt.h>
#include <commdlg.h>
#include <shlobj.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <winhttp.h>

#ifndef MOOJICUT_VERSION
#define MOOJICUT_VERSION "0.1.0-alpha.9"
#endif
#define WIDE_(x) L##x
#define WIDE(x) WIDE_(x)
#define UPDATE_DONE (WM_APP + 0x63)
#define PATH_CAPACITY 32768
#define BODY_LIMIT (4u * 1024u * 1024u)
#define DOWNLOAD_LIMIT (1024u * 1024u * 1024u)
static const wchar_t *endpoint =
    L"https://api.github.com/repos/CoderSerio/moojicut/releases?per_page=100";
typedef struct {
  HWND destination;
  HANDLE cancel, done, thread;
  BOOL download, success, cancelled;
  DWORD error, http_status, expected_size, generation;
  LONG progress;
  wchar_t url[8192], path[PATH_CAPACITY], partial[PATH_CAPACITY], digest[65];
  char *body;
  SIZE_T body_size;
  /* Private smoke transport; production entry points never populate these. */
  const BYTE *fixture;
  SIZE_T fixture_size;
  HANDLE fixture_gate, fixture_entered;
  DWORD fixture_status;
  BOOL fixture_more_pages, fixture_gate_after_first;
} UpdateJob;
typedef struct {
  HWND window, owner;
  UpdateJob *job;
  int32_t release;
  DWORD generation;
  BOOL prompt, closing, last_success;
  wchar_t status[512], completed[PATH_CAPACITY];
} Updates;
static Updates updates;
static void notify(void) {
  if (IsWindow(updates.owner))
    PostMessageW(updates.owner, MOOJICUT_UPDATES_CHANGED, 0, 0);
}
static BOOL cancelled(UpdateJob *job) {
  return WaitForSingleObject(job->cancel, 0) == WAIT_OBJECT_0;
}
static BOOL allowed_url(const wchar_t *url) {
  URL_COMPONENTS parts = {sizeof(parts)};
  wchar_t host[256];
  parts.lpszHostName = host;
  parts.dwHostNameLength = ARRAYSIZE(host);
  parts.dwUserNameLength = parts.dwPasswordLength = 1;
  if (!WinHttpCrackUrl(url, 0, 0, &parts) || parts.nScheme != INTERNET_SCHEME_HTTPS ||
      parts.nPort != INTERNET_DEFAULT_HTTPS_PORT || parts.dwUserNameLength ||
      parts.dwPasswordLength)
    return FALSE;
  host[parts.dwHostNameLength] = 0;
  return !_wcsicmp(host, L"api.github.com") || !_wcsicmp(host, L"github.com") ||
         !_wcsicmp(host, L"release-assets.githubusercontent.com") ||
         !_wcsicmp(host, L"objects.githubusercontent.com");
}
typedef struct {
  HINTERNET session, connection, request;
  SIZE_T offset;
} Reader;
static BOOL response_ok(UpdateJob *job, BOOL more_pages) {
  if (job->http_status != 200) {
    SetLastError(ERROR_WINHTTP_INVALID_SERVER_RESPONSE);
    return FALSE;
  }
  if (!job->download && more_pages) {
    SetLastError(ERROR_MORE_DATA);
    return FALSE;
  }
  return TRUE;
}
static void reader_close(Reader *reader) {
  if (reader->request)
    WinHttpCloseHandle(reader->request);
  if (reader->connection)
    WinHttpCloseHandle(reader->connection);
  if (reader->session)
    WinHttpCloseHandle(reader->session);
  ZeroMemory(reader, sizeof(*reader));
}
static BOOL reader_open(UpdateJob *job, Reader *reader) {
  if (job->fixture) {
    if (job->fixture_entered && !job->fixture_gate_after_first)
      SetEvent(job->fixture_entered);
    if (job->fixture_gate && !job->fixture_gate_after_first) {
      HANDLE waits[] = {job->cancel, job->fixture_gate};
      if (WaitForMultipleObjects(2, waits, FALSE, 5000) != WAIT_OBJECT_0 + 1) {
        SetLastError(ERROR_CANCELLED);
        return FALSE;
      }
    }
    job->http_status = job->fixture_status;
    return response_ok(job, job->fixture_more_pages);
  }
  wchar_t current[8192];
  wcscpy_s(current, ARRAYSIZE(current), job->url);
  reader->session =
      WinHttpOpen(L"MoojiCut/" WIDE(MOOJICUT_VERSION), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                  WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (!reader->session || !WinHttpSetTimeouts(reader->session, 5000, 5000, 5000, 5000))
    return FALSE;
  for (int redirects = 0; redirects < 6; redirects++) {
    if (cancelled(job)) {
      SetLastError(ERROR_CANCELLED);
      return FALSE;
    }
    if (!allowed_url(current)) {
      SetLastError(ERROR_ACCESS_DENIED);
      return FALSE;
    }
    URL_COMPONENTS parts = {sizeof(parts)};
    wchar_t host[256], path[8192], extra[8192], target[16384];
    parts.lpszHostName = host;
    parts.dwHostNameLength = ARRAYSIZE(host);
    parts.lpszUrlPath = path;
    parts.dwUrlPathLength = ARRAYSIZE(path);
    parts.lpszExtraInfo = extra;
    parts.dwExtraInfoLength = ARRAYSIZE(extra);
    if (!WinHttpCrackUrl(current, 0, 0, &parts))
      return FALSE;
    host[parts.dwHostNameLength] = 0;
    path[parts.dwUrlPathLength] = 0;
    extra[parts.dwExtraInfoLength] = 0;
    swprintf_s(target, ARRAYSIZE(target), L"%s%s", path[0] ? path : L"/", extra);
    reader->connection = WinHttpConnect(reader->session, host, parts.nPort, 0);
    if (!reader->connection)
      return FALSE;
    reader->request =
        WinHttpOpenRequest(reader->connection, L"GET", target, NULL, WINHTTP_NO_REFERER,
                           WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if (!reader->request)
      return FALSE;
    DWORD disabled = WINHTTP_DISABLE_REDIRECTS;
    if (!WinHttpSetOption(reader->request, WINHTTP_OPTION_DISABLE_FEATURE, &disabled,
                          sizeof(disabled)))
      return FALSE;
    const wchar_t *headers =
        job->download
            ? L"Accept: application/octet-stream\r\nX-GitHub-Api-Version: 2022-11-28\r\n"
            : L"Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2022-11-28\r\n";
    if (!WinHttpSendRequest(reader->request, headers, (DWORD)-1L, WINHTTP_NO_REQUEST_DATA, 0, 0, 0))
      return FALSE;
    if (cancelled(job)) {
      SetLastError(ERROR_CANCELLED);
      return FALSE;
    }
    if (!WinHttpReceiveResponse(reader->request, NULL))
      return FALSE;
    DWORD bytes = sizeof(job->http_status);
    if (!WinHttpQueryHeaders(reader->request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX, &job->http_status, &bytes,
                             WINHTTP_NO_HEADER_INDEX))
      return FALSE;
    if (job->http_status == 200) {
      if (!job->download) {
        wchar_t link[8192];
        DWORD link_bytes = sizeof(link);
        if (WinHttpQueryHeaders(reader->request, WINHTTP_QUERY_CUSTOM, L"Link", link, &link_bytes,
                                WINHTTP_NO_HEADER_INDEX)) {
          if (!response_ok(job, wcsstr(link, L"rel=\"next\"") || wcsstr(link, L"rel=next")))
            return FALSE;
        } else if (GetLastError() != ERROR_WINHTTP_HEADER_NOT_FOUND)
          return FALSE;
      }
      DWORD length = 0;
      bytes = sizeof(length);
      if (WinHttpQueryHeaders(
              reader->request, WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER,
              WINHTTP_HEADER_NAME_BY_INDEX, &length, &bytes, WINHTTP_NO_HEADER_INDEX) &&
          (length > (job->download ? DOWNLOAD_LIMIT : BODY_LIMIT) ||
           (job->download && length != job->expected_size))) {
        SetLastError(ERROR_INVALID_DATA);
        return FALSE;
      }
      return TRUE;
    }
    // The API endpoint is fixed. Only archive downloads may follow CDN redirects.
    if (!job->download) {
      SetLastError(ERROR_WINHTTP_REDIRECT_FAILED);
      return FALSE;
    }
    if (job->http_status != 301 && job->http_status != 302 && job->http_status != 303 &&
        job->http_status != 307 && job->http_status != 308) {
      SetLastError(ERROR_WINHTTP_INVALID_SERVER_RESPONSE);
      return FALSE;
    }
    bytes = sizeof(current);
    if (!WinHttpQueryHeaders(reader->request, WINHTTP_QUERY_LOCATION, WINHTTP_HEADER_NAME_BY_INDEX,
                             current, &bytes, WINHTTP_NO_HEADER_INDEX))
      return FALSE;
    WinHttpCloseHandle(reader->request);
    reader->request = NULL;
    WinHttpCloseHandle(reader->connection);
    reader->connection = NULL;
  }
  SetLastError(ERROR_WINHTTP_REDIRECT_FAILED);
  return FALSE;
}
static BOOL reader_read(UpdateJob *job, Reader *reader, BYTE *buffer, DWORD capacity, DWORD *read) {
  if (!job->fixture)
    return WinHttpReadData(reader->request, buffer, capacity, read);
  if (job->fixture_gate_after_first && reader->offset && job->fixture_gate) {
    if (job->fixture_entered)
      SetEvent(job->fixture_entered);
    HANDLE waits[] = {job->cancel, job->fixture_gate};
    if (WaitForMultipleObjects(2, waits, FALSE, 5000) != WAIT_OBJECT_0 + 1) {
      SetLastError(ERROR_CANCELLED);
      return FALSE;
    }
  }
  SIZE_T available = job->fixture_size - reader->offset;
  *read = available > capacity ? capacity : (DWORD)available;
  memcpy(buffer, job->fixture + reader->offset, *read);
  reader->offset += *read;
  return TRUE;
}
static BOOL transfer(UpdateJob *job) {
  Reader reader = {0};
  HANDLE file = INVALID_HANDLE_VALUE;
  BCRYPT_ALG_HANDLE algorithm = NULL;
  BCRYPT_HASH_HANDLE hash = NULL;
  BYTE *hash_object = NULL;
  BOOL ok = FALSE, created = FALSE;
  if (job->download && (!job->expected_size || job->expected_size > DOWNLOAD_LIMIT)) {
    job->error = ERROR_INVALID_DATA;
    return FALSE;
  }
  if (!reader_open(job, &reader))
    goto done;
  if (job->download) {
    file =
        CreateFileW(job->partial, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE)
      goto done;
    created = TRUE;
    DWORD object_size = 0, received = 0;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0 ||
        BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, (PUCHAR)&object_size,
                          sizeof(object_size), &received, 0) < 0 ||
        !(hash_object = malloc(object_size)) ||
        BCryptCreateHash(algorithm, &hash, hash_object, object_size, NULL, 0, 0) < 0) {
      SetLastError(ERROR_INVALID_DATA);
      goto done;
    }
  }
  BYTE buffer[16384];
  SIZE_T total = 0;
  ULONGLONG started = GetTickCount64();
  for (;;) {
    if (cancelled(job)) {
      SetLastError(ERROR_CANCELLED);
      goto done;
    }
    if (GetTickCount64() - started > (job->download ? 600000u : 60000u)) {
      SetLastError(ERROR_TIMEOUT);
      goto done;
    }
    DWORD count = 0;
    if (!reader_read(job, &reader, buffer, sizeof(buffer), &count))
      goto done;
    if (!count)
      break;
    if (count > (job->download ? job->expected_size : BODY_LIMIT) - total) {
      SetLastError(ERROR_INVALID_DATA);
      goto done;
    }
    if (job->download) {
      DWORD written;
      if (!WriteFile(file, buffer, count, &written, NULL) || written != count ||
          BCryptHashData(hash, buffer, count, 0) < 0)
        goto done;
    } else {
      char *next = realloc(job->body, total + count + 1);
      if (!next) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        goto done;
      }
      job->body = next;
      memcpy(job->body + total, buffer, count);
      job->body[total + count] = 0;
    }
    total += count;
    if (job->download)
      InterlockedExchange(&job->progress, (LONG)(total * 100 / job->expected_size));
  }
  if (cancelled(job)) {
    SetLastError(ERROR_CANCELLED);
    goto done;
  }
  if (job->download) {
    BYTE digest[32];
    wchar_t hex[65];
    if (total != job->expected_size || BCryptFinishHash(hash, digest, sizeof(digest), 0) < 0) {
      SetLastError(ERROR_INVALID_DATA);
      goto done;
    }
    for (int i = 0; i < 32; i++)
      swprintf_s(hex + i * 2, 65 - i * 2, L"%02x", (unsigned)digest[i]);
    if (_wcsicmp(hex, job->digest)) {
      SetLastError(ERROR_CRC);
      goto done;
    }
    if (!FlushFileBuffers(file))
      goto done;
    CloseHandle(file);
    file = INVALID_HANDLE_VALUE;
    if (cancelled(job)) {
      SetLastError(ERROR_CANCELLED);
      goto done;
    }
    if (!MoveFileExW(job->partial, job->path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
      goto done;
  } else
    job->body_size = total;
  ok = TRUE;
done:
  if (!ok)
    job->error = GetLastError();
  job->cancelled = !ok && (cancelled(job) || job->error == ERROR_CANCELLED);
  reader_close(&reader);
  if (file != INVALID_HANDLE_VALUE)
    CloseHandle(file);
  if (hash)
    BCryptDestroyHash(hash);
  if (algorithm)
    BCryptCloseAlgorithmProvider(algorithm, 0);
  free(hash_object);
  if (!ok && created)
    DeleteFileW(job->partial);
  return ok;
}
static DWORD WINAPI worker(void *context) {
  UpdateJob *job = context;
  job->success = transfer(job);
  HWND destination = job->destination;
  HANDLE done = job->done;
  SetEvent(done);
  // No job/state access after signaling: UI may drain it immediately.
  PostMessageW(destination, UPDATE_DONE, 0, 0);
  return 0;
}
static moonbit_string_t moon_string(const wchar_t *text, int length) {
  moonbit_string_t result = moonbit_make_string_raw(length);
  memcpy(result, text, (SIZE_T)length * sizeof(wchar_t));
  return result;
}
static BOOL release_text(int field, wchar_t *buffer, SIZE_T capacity) {
  moonbit_string_t value = update_release_text(updates.release, field);
  SIZE_T length = (SIZE_T)Moonbit_array_length(value);
  BOOL valid = length < capacity;
  if (valid) {
    memcpy(buffer, value, length * sizeof(wchar_t));
    buffer[length] = 0;
  }
  moonbit_decref(value);
  return valid;
}
static void parse_release(const char *body, SIZE_T size) {
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, body, (int)size, NULL, 0);
  wchar_t *wide = length > 0 ? calloc((SIZE_T)length, sizeof(wchar_t)) : NULL;
  if (!wide) {
    wcscpy_s(updates.status, ARRAYSIZE(updates.status), L"发布信息无效，请稍后重试。");
    return;
  }
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, body, (int)size, wide, length);
  moonbit_string_t current =
      moon_string(WIDE(MOOJICUT_VERSION), (int)wcslen(WIDE(MOOJICUT_VERSION)));
  moonbit_string_t json = moon_string(wide, length);
  int32_t parsed = update_release_create(current, MC_UPDATE_WINDOWS_X64, json);
  moonbit_decref(current);
  moonbit_decref(json);
  free(wide);
  if (updates.release)
    update_release_dispose(updates.release);
  updates.release = parsed;
  int status = parsed ? update_release_status(parsed) : MC_UPDATE_INVALID;
  wchar_t version[80] = {0};
  if (parsed)
    release_text(MC_UPDATE_VERSION, version, ARRAYSIZE(version));
  if (status == MC_UPDATE_AVAILABLE)
    swprintf_s(updates.status, ARRAYSIZE(updates.status),
               L"发现新版本 %s，可以下载 Windows x64 更新包。", version);
  else if (status == MC_UPDATE_INCOMPLETE)
    swprintf_s(updates.status, ARRAYSIZE(updates.status),
               L"发现版本 %s，暂时没有可校验的 Windows x64 更新包。", version);
  else
    wcscpy_s(updates.status, ARRAYSIZE(updates.status),
             status == MC_UPDATE_CURRENT ? L"当前已是此更新渠道的最新版本。"
                                         : L"发布信息无效，请稍后重试。");
}
static void poll(void) {
  UpdateJob *job = updates.job;
  if (!job)
    return;
  if (WaitForSingleObject(job->done, 0) != WAIT_OBJECT_0)
    return;
  updates.job = NULL;
  KillTimer(updates.window, 1);
  updates.last_success = job->success;
  if (job->cancelled)
    wcscpy_s(updates.status, ARRAYSIZE(updates.status), L"已取消，未保留未完成的下载。");
  else if (!job->success) {
    if (job->error == ERROR_CRC)
      wcscpy_s(updates.status, ARRAYSIZE(updates.status), L"SHA256 校验失败，下载已删除。");
    else if (job->error == ERROR_MORE_DATA)
      wcscpy_s(updates.status, ARRAYSIZE(updates.status),
               L"发布记录超过当前支持的 100 条，请从 GitHub Releases 查看更新。");
    else if (job->http_status && job->http_status != 200)
      swprintf_s(updates.status, ARRAYSIZE(updates.status),
                 L"GitHub 请求失败（HTTP %lu），请稍后重试。", job->http_status);
    else
      swprintf_s(updates.status, ARRAYSIZE(updates.status),
                 L"更新操作失败（%lu），请检查网络或保存位置后重试。", job->error);
  } else if (job->download) {
    wcscpy_s(updates.completed, ARRAYSIZE(updates.completed), job->path);
    wcscpy_s(updates.status, ARRAYSIZE(updates.status),
             L"更新包已下载并通过 SHA256 校验。打开文件位置，解压后运行新版本。");
  } else if (!updates.closing)
    parse_release(job->body, job->body_size);
  CloseHandle(job->thread);
  CloseHandle(job->cancel);
  CloseHandle(job->done);
  free(job->body);
  free(job);
  notify();
}
static LRESULT CALLBACK update_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  if (message == UPDATE_DONE || message == WM_TIMER) {
    poll();
    return 0;
  }
  return DefWindowProcW(window, message, wp, lp);
}
BOOL mc_updates_initialize(HINSTANCE instance, HWND owner) {
  if (updates.window)
    return TRUE;
  WNDCLASSEXW cls = {sizeof(cls)};
  cls.lpfnWndProc = update_proc;
  cls.hInstance = instance;
  cls.lpszClassName = L"MoojiCut.Updates";
  if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
    return FALSE;
  updates.owner = owner;
  updates.window =
      CreateWindowExW(0, cls.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, instance, NULL);
  wcscpy_s(updates.status, ARRAYSIZE(updates.status),
           L"从 GitHub Releases 手动检查更新；不需要登录。");
  return updates.window != NULL;
}
static BOOL start(UpdateJob *job) {
  if (!job || !updates.window || updates.job || updates.closing) {
    free(job);
    return FALSE;
  }
  job->destination = updates.window;
  job->generation = ++updates.generation;
  if (job->download && swprintf_s(job->partial, ARRAYSIZE(job->partial), L"%s.mooji-part-%lu-%lu",
                                  job->path, GetCurrentProcessId(), job->generation) < 0) {
    free(job);
    return FALSE;
  }
  job->cancel = CreateEventW(NULL, TRUE, FALSE, NULL);
  job->done = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!job->cancel || !job->done)
    goto failed;
  updates.job = job;
  job->thread = CreateThread(NULL, 0, worker, job, 0, NULL);
  if (!job->thread) {
    updates.job = NULL;
    goto failed;
  }
  SetTimer(updates.window, 1, 100, NULL);
  wcscpy_s(updates.status, ARRAYSIZE(updates.status),
           job->download ? L"正在下载并校验更新包…" : L"正在检查 GitHub Releases…");
  notify();
  return TRUE;
failed:
  if (job->cancel)
    CloseHandle(job->cancel);
  if (job->done)
    CloseHandle(job->done);
  free(job);
  wcscpy_s(updates.status, ARRAYSIZE(updates.status), L"无法启动更新任务，请重试。");
  notify();
  return FALSE;
}
BOOL mc_updates_check(void) {
  UpdateJob *job = calloc(1, sizeof(*job));
  if (!job)
    return FALSE;
  wcscpy_s(job->url, ARRAYSIZE(job->url), endpoint);
  BOOL started = start(job);
  if (started && updates.release) {
    update_release_dispose(updates.release);
    updates.release = 0;
  }
  return started;
}
BOOL mc_updates_download(HWND owner) {
  if (!mc_updates_available() || mc_updates_busy() || updates.closing)
    return FALSE;
  UpdateJob *job = calloc(1, sizeof(*job));
  if (!job)
    return FALSE;
  job->download = TRUE;
  job->expected_size = (DWORD)update_release_size(updates.release);
  if (!release_text(MC_UPDATE_DOWNLOAD_URL, job->url, ARRAYSIZE(job->url)) ||
      !release_text(MC_UPDATE_SHA256, job->digest, ARRAYSIZE(job->digest)) ||
      !release_text(MC_UPDATE_ASSET_NAME, job->path, ARRAYSIZE(job->path))) {
    free(job);
    return FALSE;
  }
  OPENFILENAMEW dialog = {sizeof(dialog)};
  dialog.hwndOwner = owner;
  dialog.lpstrFile = job->path;
  dialog.nMaxFile = ARRAYSIZE(job->path);
  dialog.lpstrFilter = L"ZIP 更新包\0*.zip\0\0";
  dialog.lpstrDefExt = L"zip";
  dialog.Flags = OFN_EXPLORER | OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
  updates.prompt = TRUE;
  BOOL chosen = GetSaveFileNameW(&dialog);
  updates.prompt = FALSE;
  if (!chosen || updates.closing) {
    free(job);
    notify();
    return FALSE;
  }
  return start(job);
}
void mc_updates_cancel(void) {
  if (updates.job) {
    SetEvent(updates.job->cancel);
    wcscpy_s(updates.status, ARRAYSIZE(updates.status), L"正在取消，等待当前网络请求结束…");
    notify();
  }
}
BOOL mc_updates_busy(void) { return updates.job || updates.prompt; }
BOOL mc_updates_available(void) {
  return updates.release && update_release_status(updates.release) == MC_UPDATE_AVAILABLE;
}
BOOL mc_updates_downloaded(void) {
  return updates.completed[0] && GetFileAttributesW(updates.completed) != INVALID_FILE_ATTRIBUTES;
}
const wchar_t *mc_updates_status(void) { return updates.status; }
static BOOL show_file_location(const wchar_t *path) {
  PIDLIST_ABSOLUTE item = NULL;
  HRESULT initialized = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  BOOL opened = FALSE;
  if (SUCCEEDED(SHParseDisplayName(path, NULL, &item, 0, NULL))) {
    opened = SUCCEEDED(SHOpenFolderAndSelectItems(item, 0, NULL, 0));
    CoTaskMemFree(item);
  }
  if (SUCCEEDED(initialized))
    CoUninitialize();
  return opened;
}
void mc_updates_open_location(void) {
  if (mc_updates_downloaded()) show_file_location(updates.completed);
}

static BOOL launch_uninstaller(const wchar_t *source, const wchar_t *root) {
  wchar_t temp[MAX_PATH], directory[MAX_PATH], executable[MAX_PATH], command[MAX_PATH + 80];
  const wchar_t helper_name[] = L"MoojiCutUninstaller.exe";
  GUID id;
  wchar_t guid[40];
  DWORD length = GetTempPathW(ARRAYSIZE(temp), temp);
  if (!length || length >= ARRAYSIZE(temp) - 80 || FAILED(CoCreateGuid(&id)) ||
      !StringFromGUID2(&id, guid, ARRAYSIZE(guid))) return FALSE;
  swprintf_s(directory, ARRAYSIZE(directory), L"%lsMoojiCut-Uninstall-%ls", temp, guid);
  if (!CreateDirectoryW(directory, NULL)) return FALSE;
  swprintf_s(executable, ARRAYSIZE(executable), L"%ls\\%ls", directory, helper_name);

  BOOL launched = FALSE;
  SECURITY_ATTRIBUTES inherited = {sizeof(inherited), NULL, TRUE};
  HANDLE handles[] = {OpenProcess(SYNCHRONIZE, TRUE, GetCurrentProcessId()),
    CreateFileW(root, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                &inherited, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL)};
  BY_HANDLE_FILE_INFORMATION identity;
  SIZE_T bytes = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &bytes);
  LPPROC_THREAD_ATTRIBUTE_LIST attributes = bytes ? malloc(bytes) : NULL;
  BOOL list_ready = attributes && InitializeProcThreadAttributeList(attributes, 1, 0, &bytes);
  if (handles[0] && handles[1] != INVALID_HANDLE_VALUE && GetFileInformationByHandle(handles[1], &identity) &&
      (identity.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(identity.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
      list_ready && UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                              handles, sizeof(handles), NULL, NULL) &&
      CopyFileW(source, executable, TRUE)) {
    STARTUPINFOEXW startup = {0};
    PROCESS_INFORMATION child = {0};
    startup.StartupInfo.cb = sizeof(startup);
    startup.lpAttributeList = attributes;
    swprintf_s(command, ARRAYSIZE(command), L"\"%ls\" --after-exit %llu %llu", executable,
        (unsigned long long)(uintptr_t)handles[0], (unsigned long long)(uintptr_t)handles[1]);
    launched = CreateProcessW(executable, command, NULL, NULL, TRUE, EXTENDED_STARTUPINFO_PRESENT,
                             NULL, directory, &startup.StartupInfo, &child);
    if (launched) { CloseHandle(child.hThread); CloseHandle(child.hProcess); }
  }
  if (list_ready) DeleteProcThreadAttributeList(attributes);
  free(attributes);
  if (handles[0]) CloseHandle(handles[0]);
  if (handles[1] != INVALID_HANDLE_VALUE) CloseHandle(handles[1]);
  if (!launched) { DeleteFileW(executable); RemoveDirectoryW(directory); }
  return launched;
}
BOOL mc_updates_uninstall(HWND owner, BOOL (*ready)(void)) {
  wchar_t path[PATH_CAPACITY], root[MAX_PATH], helper[MAX_PATH], manifest[MAX_PATH];
  DWORD length = GetModuleFileNameW(NULL, path, ARRAYSIZE(path));
  if (!length || length >= ARRAYSIZE(path) || !ready || !ready()) return FALSE;
  const wchar_t *name = wcsrchr(path, L'\\');
  BOOL bundled = name && !_wcsicmp(name + 1, L"MoojiCut.exe") && (size_t)(name - path) < MAX_PATH - 30;
  if (bundled) {
    wcsncpy_s(root, ARRAYSIZE(root), path, (size_t)(name - path));
    const wchar_t *folder = wcsrchr(root, L'\\');
    swprintf_s(helper, ARRAYSIZE(helper), L"%ls\\MoojiCutUninstaller.exe", root);
    swprintf_s(manifest, ARRAYSIZE(manifest), L"%ls\\uninstall-manifest.txt", root);
    DWORD helper_attrs = GetFileAttributesW(helper), manifest_attrs = GetFileAttributesW(manifest);
    wchar_t volume[] = {root[0], root[1], L'\\', L'\0'};
    bundled = root[1] == L':' && root[2] == L'\\' && GetDriveTypeW(volume) == DRIVE_FIXED &&
      folder && !_wcsicmp(folder + 1, L"MoojiCut") && helper_attrs != INVALID_FILE_ATTRIBUTES &&
      manifest_attrs != INVALID_FILE_ATTRIBUTES &&
      !((helper_attrs | manifest_attrs) & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY));
  }
  if (bundled) {
    wchar_t confirmation[MAX_PATH + 160];
    swprintf_s(confirmation, ARRAYSIZE(confirmation),
        L"退出 Mooji Cut，并将以下便携包文件夹移到回收站？\n\n%ls\n\n"
        L"会先核对文件清单。偏好设置、导入的插件和录屏草稿会保留。", root);
    if (MessageBoxW(owner, confirmation, L"卸载 Mooji Cut",
        MB_YESNO | MB_DEFBUTTON2 | MB_ICONWARNING) != IDYES || !ready()) return FALSE;
    if (launch_uninstaller(helper, root)) return TRUE;
  }
  if (MessageBoxW(owner, L"此目录需要手动卸载。要打开程序位置并退出 Mooji Cut 吗？\n\n"
      L"退出后，仅删除当前便携包的文件。", L"卸载 Mooji Cut",
      MB_OKCANCEL | MB_DEFBUTTON2 | MB_ICONINFORMATION) != IDOK || !ready()) return FALSE;
  if (show_file_location(path)) return TRUE;
  MessageBoxW(owner, path, L"Mooji Cut 程序位置", MB_OK | MB_ICONINFORMATION);
  return FALSE;
}
BOOL mc_updates_prepare_close(void) {
  updates.closing = TRUE;
  mc_updates_cancel();
  return !mc_updates_busy();
}
void mc_updates_shutdown(void) {
  if (mc_updates_busy())
    return;
  if (updates.release)
    update_release_dispose(updates.release);
  if (updates.window)
    DestroyWindow(updates.window);
  ZeroMemory(&updates, sizeof(updates));
}

/* Runs the real worker, hashing, file commit and UI completion paths with an
 * in-memory transport. It never contacts GitHub or opens a downloaded file. */
static BOOL smoke_drain(void) {
  ULONGLONG deadline = GetTickCount64() + 6000;
  while (updates.job && GetTickCount64() < deadline) {
    MSG message;
    while (PeekMessageW(&message, updates.window, 0, 0, PM_REMOVE))
      DispatchMessageW(&message);
    poll();
    if (updates.job)
      WaitForSingleObject(updates.job->done, 10);
  }
  return !updates.job;
}
static UpdateJob *smoke_job(const char *body, DWORD status) {
  UpdateJob *job = calloc(1, sizeof(*job));
  if (job) {
    job->fixture = (const BYTE *)body;
    job->fixture_size = strlen(body);
    job->fixture_status = status;
  }
  return job;
}
static BOOL smoke_file(const wchar_t *path, const char *expected) {
  HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
  if (file == INVALID_HANDLE_VALUE)
    return FALSE;
  char bytes[16];
  DWORD size = 0;
  BOOL ok = ReadFile(file, bytes, sizeof(bytes), &size, NULL) && size == strlen(expected) &&
            !memcmp(bytes, expected, size);
  CloseHandle(file);
  return ok;
}
BOOL mc_updates_smoke(HINSTANCE instance) {
  static const char fixture[] =
      "[{\"tag_name\":\"v99.0.0\",\"draft\":false,\"prerelease\":false,"
      "\"published_at\":\"2026-11-15T00:00:00Z\","
      "\"html_url\":\"https://github.com/CoderSerio/moojicut/releases/tag/v99.0.0\",\"assets\":[{"
      "\"name\":\"moojicut-99.0.0-windows-x64.zip\",\"state\":\"uploaded\",\"size\":3,"
      "\"digest\":\"sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\","
      "\"browser_download_url\":\"https://github.com/CoderSerio/moojicut/releases/download/v99.0.0/"
      "moojicut-99.0.0-windows-x64.zip\"}]}]";
  static const wchar_t digest[] =
      L"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
  BOOL ok = FALSE;
  const char *stage = "initialize";
  wchar_t directory[MAX_PATH], path[MAX_PATH] = L"", partial[PATH_CAPACITY], version[64];
  HANDLE gate = NULL, entered = NULL;
  HWND observer = CreateWindowW(L"STATIC", L"Update fixture observer", 0, 0, 0, 0, 0, HWND_MESSAGE,
                                NULL, instance, NULL);
  if (!observer || !mc_updates_initialize(instance, observer))
    goto done;
  if (!allowed_url(endpoint) || allowed_url(L"http://github.com/a") ||
      allowed_url(L"https://github.com.evil.example/a") ||
      allowed_url(L"https://user:pass@github.com/a"))
    goto done;
  stage = "release selection";
  UpdateJob *job = smoke_job(fixture, 200);
  if (!start(job) || !smoke_drain() || !updates.last_success || !mc_updates_available() ||
      !release_text(MC_UPDATE_VERSION, version, ARRAYSIZE(version)) || wcscmp(version, L"99.0.0"))
    goto done;
  job = smoke_job(fixture, 200);
  if (!job)
    goto done;
  job->fixture_more_pages = TRUE;
  stage = "pagination rejection";
  if (!start(job) || !smoke_drain() || updates.last_success || !wcsstr(updates.status, L"100"))
    goto done;
  job = smoke_job(fixture, 503);
  stage = "HTTP status";
  if (!start(job) || !smoke_drain() || updates.last_success || !wcsstr(updates.status, L"503"))
    goto done;
  job = smoke_job(fixture, 302);
  if (!start(job) || !smoke_drain() || updates.last_success)
    goto done;
  if (!GetTempPathW(ARRAYSIZE(directory), directory) ||
      !GetTempFileNameW(directory, L"mcu", 0, path))
    goto done;
  HANDLE file =
      CreateFileW(path, GENERIC_WRITE, 0, NULL, TRUNCATE_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE)
    goto done;
  DWORD written = 0;
  BOOL seeded = WriteFile(file, "old", 3, &written, NULL) && written == 3;
  CloseHandle(file);
  if (!seeded)
    goto done;
  stage = "archive verification";
  for (int scenario = 0; scenario < 3; scenario++) {
    job = smoke_job("abc", 200);
    if (!job)
      goto done;
    job->download = TRUE;
    job->expected_size = scenario == 1 ? 4 : 3;
    wcscpy_s(job->path, ARRAYSIZE(job->path), path);
    wcscpy_s(job->digest, ARRAYSIZE(job->digest), digest);
    if (scenario == 0)
      job->digest[0] = L'0';
    if (!start(job))
      goto done;
    wcscpy_s(partial, ARRAYSIZE(partial), job->partial);
    if (!smoke_drain() || updates.last_success != (scenario == 2) ||
        GetFileAttributesW(partial) != INVALID_FILE_ATTRIBUTES ||
        !smoke_file(path, scenario == 2 ? "abc" : "old"))
      goto done;
  }
  if (!mc_updates_downloaded())
    goto done;
  stage = "cancel and observer disposal";
  gate = CreateEventW(NULL, TRUE, FALSE, NULL);
  entered = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!gate || !entered)
    goto done;
  job = smoke_job("abc", 200);
  if (!job)
    goto done;
  job->download = TRUE;
  job->expected_size = 3;
  job->fixture_gate = gate;
  job->fixture_entered = entered;
  job->fixture_gate_after_first = TRUE;
  wcscpy_s(job->path, ARRAYSIZE(job->path), path);
  wcscpy_s(job->digest, ARRAYSIZE(job->digest), digest);
  if (!start(job))
    goto done;
  wcscpy_s(partial, ARRAYSIZE(partial), job->partial);
  if (WaitForSingleObject(entered, 2000) != WAIT_OBJECT_0 ||
      GetFileAttributesW(partial) == INVALID_FILE_ATTRIBUTES)
    goto done;
  DestroyWindow(observer);
  observer = NULL; // Settings may disappear before completion.
  if (mc_updates_prepare_close() || !smoke_drain() || updates.last_success ||
      !mc_updates_prepare_close() || GetFileAttributesW(partial) != INVALID_FILE_ATTRIBUTES ||
      !smoke_file(path, "abc"))
    goto done;
  ok = TRUE;
done:
  if (!ok)
    fprintf(stderr, "Windows update smoke failed at %s.\n", stage);
  mc_updates_cancel();
  if (!smoke_drain()) {
    fputs("Windows update fixture failed to drain its worker.\n", stderr);
    ExitProcess(1); // Never let the fixture release memory owned by a live worker.
  }
  mc_updates_shutdown();
  if (observer)
    DestroyWindow(observer);
  if (gate)
    CloseHandle(gate);
  if (entered)
    CloseHandle(entered);
  if (path[0])
    DeleteFileW(path);
  printf("Windows update smoke: %s (fixture HTTP status/pagination, MoonBit release selection, "
         "SHA256/size verification, atomic file replacement, cancel and observer disposal; no "
         "network).\n",
         ok ? "passed" : "FAILED");
  return ok;
}
