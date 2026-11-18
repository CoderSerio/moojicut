#define _POSIX_C_SOURCE 200809L
#include "updates.h"
#include "bindings/c/update_release.h"
#include <curl/curl.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <glib/gstdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef MOOJICUT_VERSION
#define MOOJICUT_VERSION "development"
#endif
#define RELEASES_API "https://api.github.com/repos/CoderSerio/moojicut/releases?per_page=100"
#define RELEASES_PAGE "https://github.com/CoderSerio/moojicut/releases"
#define BODY_LIMIT (4u * 1024u * 1024u)
#define DOWNLOAD_LIMIT (1024u * 1024u * 1024u)
#define PORTABLE_MANIFEST "uninstall-manifest.txt"
#define PORTABLE_HEADER "MoojiCut portable 1"
#define PORTABLE_MANIFEST_LIMIT (256u * 1024u)

/* The worker owns only immutable request data and its sink. No GTK or MoonBit
 * is called off the UI thread. A page may die while its task is completing. */
typedef struct {
  char *url, *destination, *sha256;
  gsize expected, received;
  GByteArray *body;
  GChecksum *checksum;
  GCancellable *cancel;
  int fd;
  gboolean overflow, write_failed, paginated;
  GBytes *fixture; /* Only isolated smoke tasks supply a transport fixture. */
  char *fixture_header;
} Request;
typedef struct { char *body, *path; } Response;
typedef struct {
  int references, release;
  gboolean destroyed, busy, uninstalling;
  GtkWidget *page, *status, *check, *download, *cancel, *open, *uninstall, *spinner, *chooser;
  GCancellable *cancel_task;
  GApplication *application;
  char *downloaded;
  const char *(*uninstall_blocker)(void);
  void (*quit_after_uninstall)(void);
} UpdatePage;
static GSList *active_pages;
void mc_linux_updates_cancel_all(void) {
  for (GSList *node = active_pages; node; node = node->next) {
    UpdatePage *page = node->data;
    if (page->cancel_task) g_cancellable_cancel(page->cancel_task);
  }
}

static gboolean curl_ready(void) {
  static gsize result;
  if (g_once_init_enter(&result)) {
    CURLcode code = curl_global_init(CURL_GLOBAL_DEFAULT);
    g_once_init_leave(&result, code == CURLE_OK ? 1 : 2);
  }
  return result == 1;
}
static void response_free(Response *response) {
  if (!response) return;
  g_free(response->body);
  g_free(response->path);
  g_free(response);
}
static void request_free(Request *request) {
  g_free(request->url);
  g_free(request->destination);
  g_free(request->sha256);
  g_clear_pointer(&request->body, g_byte_array_unref);
  g_clear_pointer(&request->checksum, g_checksum_free);
  g_clear_pointer(&request->fixture, g_bytes_unref);
  g_free(request->fixture_header);
  g_free(request);
}
static size_t receive_data(char *data, size_t size, size_t count, void *context) {
  Request *request = context;
  if (size && count > G_MAXSIZE / size) return 0;
  gsize length = size * count;
  gsize limit = request->destination ? MIN(request->expected, (gsize)DOWNLOAD_LIMIT) : BODY_LIMIT;
  if (request->received > limit || length > limit - request->received) {
    request->overflow = TRUE;
    return 0;
  }
  if (g_cancellable_is_cancelled(request->cancel)) return 0;
  if (request->destination) {
    gsize written = 0;
    while (written < length) {
      ssize_t amount = write(request->fd, data + written, length - written);
      if (amount < 0 && errno == EINTR) continue;
      if (amount <= 0) { request->write_failed = TRUE; return 0; }
      written += (gsize)amount;
    }
    g_checksum_update(request->checksum, (const guchar *)data, length);
  } else g_byte_array_append(request->body, (const guint8 *)data, (guint)length);
  request->received += length;
  return length;
}
static int transfer_progress(void *context, curl_off_t total, curl_off_t now,
                             curl_off_t upload_total, curl_off_t uploaded) {
  (void)total; (void)now; (void)upload_total; (void)uploaded;
  return g_cancellable_is_cancelled(((Request *)context)->cancel) ? 1 : 0;
}
static size_t receive_header(char *data, size_t size, size_t count, void *context) {
  if (size && count > G_MAXSIZE / size) return 0;
  size_t length = size * count;
  Request *request = context;
  if (request->destination) return length;
  char *header = g_ascii_strdown(data, (gssize)length);
  if (g_str_has_prefix(header, "http/")) request->paginated = FALSE;
  if (g_str_has_prefix(header, "link:") &&
      (strstr(header, "rel=\"next\"") || strstr(header, "rel=next"))) request->paginated = TRUE;
  g_free(header);
  return length;
}
static void transfer_worker(GTask *task, gpointer source, gpointer data, GCancellable *cancel) {
  (void)source;
  Request *request = data;
  request->cancel = cancel;
  request->fd = -1;
  GError *error = NULL;
  char *temporary = NULL;
  CURL *curl = NULL;
  struct curl_slist *headers = NULL;
  Response *response = NULL;
  if (g_cancellable_set_error_if_cancelled(cancel, &error)) goto finished;
  if (!request->url || !g_str_has_prefix(request->url, "https://")) {
    g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "更新地址必须使用 HTTPS。");
    goto finished;
  }
  if (request->destination) {
    if (!request->expected || request->expected > DOWNLOAD_LIMIT || !request->sha256 || strlen(request->sha256) != 64) {
      g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "更新包大小或校验信息无效。");
      goto finished;
    }
    char *directory = g_path_get_dirname(request->destination);
    temporary = g_build_filename(directory, ".moojicut-download-XXXXXX", NULL);
    g_free(directory);
    request->fd = g_mkstemp_full(temporary, O_RDWR | O_CLOEXEC, 0600);
    if (request->fd < 0) {
      g_set_error(&error, G_IO_ERROR, g_io_error_from_errno(errno), "无法创建下载文件：%s", g_strerror(errno));
      goto finished;
    }
    request->checksum = g_checksum_new(G_CHECKSUM_SHA256);
  } else request->body = g_byte_array_new();
  CURLcode result = CURLE_OK;
  long http_status = 200;
  if (request->fixture) {
    if (request->fixture_header)
      receive_header(request->fixture_header, 1, strlen(request->fixture_header), request);
    gsize length;
    const char *bytes = g_bytes_get_data(request->fixture, &length);
    if (receive_data((char *)bytes, 1, length, request) != length) result = CURLE_WRITE_ERROR;
  } else {
    curl = curl_easy_init();
    if (!curl) {
      g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_FAILED, "无法启动 HTTPS 更新连接。");
      goto finished;
    }
    curl_easy_setopt(curl, CURLOPT_URL, request->url);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "MoojiCut/" MOOJICUT_VERSION " (Linux; update-check)");
    /* Fixed repository API identity; only package downloads may follow HTTPS
     * redirects to GitHub's asset CDN, with content integrity checked below. */
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, request->destination ? 1L : 0L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 5L);
#if LIBCURL_VERSION_NUM >= 0x075500
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "https");
#else
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS, (long)CURLPROTO_HTTPS);
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS, (long)CURLPROTO_HTTPS);
#endif
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, request->destination ? 600L : 30L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 128L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 30L);
    curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, receive_data);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, request);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, receive_header);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, request);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, transfer_progress);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, request);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    if (!request->destination) {
      headers = curl_slist_append(headers, "Accept: application/vnd.github+json");
      headers = curl_slist_append(headers, "X-GitHub-Api-Version: 2022-11-28");
      curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    }
    result = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_status);
  }
  if (g_cancellable_set_error_if_cancelled(cancel, &error)) goto finished;
  if (request->paginated) {
    g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "更新列表超出当前支持范围，请从 GitHub 发布页面确认最新版本。");
    goto finished;
  }
  if (request->overflow) {
    g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "响应超过允许大小，下载已停止。");
    goto finished;
  }
  if (request->write_failed) {
    g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_FAILED, "文件写入失败，请检查剩余空间和目录权限。");
    goto finished;
  }
  if (http_status != 200 && http_status != 0) {
    g_set_error(&error, G_IO_ERROR, G_IO_ERROR_FAILED, "GitHub 返回 HTTP %ld；请稍后重试。", http_status);
    goto finished;
  }
  if (result != CURLE_OK) {
    g_set_error(&error, G_IO_ERROR, G_IO_ERROR_FAILED, "HTTPS 请求失败：%s", curl_easy_strerror(result));
    goto finished;
  }
  if (request->destination) {
    if (request->received != request->expected ||
        g_ascii_strcasecmp(g_checksum_get_string(request->checksum), request->sha256) != 0) {
      g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "更新包大小或 SHA-256 不匹配，文件已丢弃。");
      goto finished;
    }
    int sync_result = fsync(request->fd);
    int close_result = close(request->fd);
    request->fd = -1;
    if (sync_result != 0 || close_result != 0) {
      g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_FAILED, "无法完整保存更新包。");
      goto finished;
    }
    if (g_cancellable_set_error_if_cancelled(cancel, &error)) goto finished;
    if (g_rename(temporary, request->destination) != 0) {
      g_set_error(&error, G_IO_ERROR, g_io_error_from_errno(errno), "无法保存更新包：%s", g_strerror(errno));
      goto finished;
    }
    response = g_new0(Response, 1);
    response->path = g_strdup(request->destination);
  } else {
    /* Reject embedded NUL and malformed UTF-8 before the shared JSON parser. */
    if (!request->body->len || memchr(request->body->data, 0, request->body->len) ||
        !g_utf8_validate((const char *)request->body->data, request->body->len, NULL)) {
      g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "GitHub 返回了无效的更新数据。");
      goto finished;
    }
    response = g_new0(Response, 1);
    response->body = g_strndup((const char *)request->body->data, request->body->len);
  }
finished:
  if (curl) curl_easy_cleanup(curl);
  curl_slist_free_all(headers);
  if (request->fd >= 0) { close(request->fd); request->fd = -1; }
  if (temporary) { g_unlink(temporary); g_free(temporary); }
  if (error) g_task_return_error(task, error);
  else g_task_return_pointer(task, response, (GDestroyNotify)response_free);
}
static moonbit_string_t core_string(const char *text) {
  glong length = 0;
  gunichar2 *wide = g_utf8_to_utf16(text, -1, NULL, &length, NULL);
  moonbit_string_t result = moonbit_make_string_raw((int32_t)length);
  if (length) memcpy(result, wide, (gsize)length * sizeof(gunichar2));
  g_free(wide);
  return result;
}
static char *release_text(int release, int field) {
  moonbit_string_t value = update_release_text(release, field);
  char *text = g_utf16_to_utf8((const gunichar2 *)value, Moonbit_array_length(value), NULL, NULL, NULL);
  moonbit_decref(value);
  return text ? text : g_strdup("");
}
static UpdatePage *page_ref(UpdatePage *page) { page->references++; return page; }
static void page_unref(UpdatePage *page) {
  if (--page->references) return;
  if (page->release) update_release_dispose(page->release);
  g_clear_object(&page->cancel_task);
  g_clear_object(&page->application);
  g_free(page->downloaded);
  g_free(page);
}
static void page_busy(UpdatePage *page, gboolean busy) {
  page->busy = busy;
  if (page->destroyed) return;
  gtk_widget_set_sensitive(page->check, !busy);
  gtk_widget_set_sensitive(page->cancel, busy);
  gtk_widget_set_sensitive(page->download, !busy && page->release && update_release_status(page->release) == MC_UPDATE_AVAILABLE);
  gtk_widget_set_sensitive(page->open, !busy && page->downloaded);
  gtk_widget_set_sensitive(page->uninstall, !busy && !page->uninstalling && page->quit_after_uninstall != NULL);
  if (busy) gtk_spinner_start(GTK_SPINNER(page->spinner));
  else gtk_spinner_stop(GTK_SPINNER(page->spinner));
}
static void transfer_done(GObject *source, GAsyncResult *result, gpointer data) {
  (void)source;
  UpdatePage *page = data;
  GError *error = NULL;
  Response *response = g_task_propagate_pointer(G_TASK(result), &error);
  g_clear_object(&page->cancel_task);
  if (!page->destroyed) {
    if (error) gtk_label_set_text(GTK_LABEL(page->status),
        g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED) ? "已取消。未完成的下载文件已移除。" : error->message);
    else if (response && response->path) {
      g_free(page->downloaded);
      page->downloaded = g_strdup(response->path);
      char *message = g_strdup_printf("下载完成，大小与 SHA-256 校验通过。\n%s\n退出应用后解压并运行新版本；当前版本尚未替换。", response->path);
      gtk_label_set_text(GTK_LABEL(page->status), message);
      g_free(message);
    } else if (response && response->body) {
      if (page->release) update_release_dispose(page->release);
      moonbit_string_t current = core_string(MOOJICUT_VERSION);
      moonbit_string_t body = core_string(response->body);
      page->release = update_release_create(current, MC_UPDATE_LINUX_X64, body);
      moonbit_decref(current);
      moonbit_decref(body);
      int status = page->release ? update_release_status(page->release) : MC_UPDATE_INVALID;
      char *version = page->release ? release_text(page->release, MC_UPDATE_VERSION) : g_strdup("");
      char *message = status == MC_UPDATE_AVAILABLE ? g_strdup_printf("发现新版本 %s。可下载经过校验的 Linux x64 便携包。", version) :
                      status == MC_UPDATE_CURRENT ? g_strdup("当前已是此渠道的最新版本。") :
                      status == MC_UPDATE_INCOMPLETE ? g_strdup_printf("发现新版本 %s，但 Linux x64 更新包尚未准备好。", version) :
                      g_strdup("暂时无法读取更新信息，请稍后重试或查看 GitHub Releases。");
      gtk_label_set_text(GTK_LABEL(page->status), message);
      g_free(version); g_free(message);
    }
  }
  page_busy(page, FALSE);
  active_pages = g_slist_remove(active_pages, page);
  if (page->application) g_application_release(page->application);
  response_free(response);
  g_clear_error(&error);
  page_unref(page);
}
static void start_transfer(UpdatePage *page, Request *request) {
  if (page->destroyed || page->busy || !curl_ready()) {
    if (!page->destroyed) gtk_label_set_text(GTK_LABEL(page->status), "无法启动更新任务。");
    request_free(request);
    return;
  }
  page->cancel_task = g_cancellable_new();
  active_pages = g_slist_prepend(active_pages, page);
  if (page->application) g_application_hold(page->application);
  GTask *task = g_task_new(NULL, page->cancel_task, transfer_done, page_ref(page));
  /* Completion waits for the worker to remove partial files. */
  g_task_set_check_cancellable(task, FALSE);
  g_task_set_task_data(task, request, (GDestroyNotify)request_free);
  gtk_label_set_text(GTK_LABEL(page->status), request->destination ? "正在下载并校验更新包…" : "正在检查 GitHub Releases…");
  page_busy(page, TRUE);
  g_task_run_in_thread(task, transfer_worker);
  g_object_unref(task);
}
static void check_clicked(GtkButton *button, gpointer data) {
  (void)button;
  UpdatePage *page = data;
  if (page->busy || page->destroyed) return;
  Request *request = g_new0(Request, 1);
  request->url = g_strdup(RELEASES_API);
  start_transfer(page, request);
}
static void chooser_response(GtkDialog *dialog, int response, gpointer data) {
  UpdatePage *page = data;
  char *path = response == GTK_RESPONSE_ACCEPT ? gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog)) : NULL;
  page->chooser = NULL;
  gtk_widget_destroy(GTK_WIDGET(dialog));
  if (path && !page->destroyed && !page->busy && page->release) {
    Request *request = g_new0(Request, 1);
    request->url = release_text(page->release, MC_UPDATE_DOWNLOAD_URL);
    request->sha256 = release_text(page->release, MC_UPDATE_SHA256);
    request->expected = (gsize)update_release_size(page->release);
    request->destination = path;
    start_transfer(page, request);
  } else g_free(path);
}
static void download_clicked(GtkButton *button, gpointer data) {
  (void)button;
  UpdatePage *page = data;
  if (page->destroyed || page->busy || page->chooser || !page->release || update_release_status(page->release) != MC_UPDATE_AVAILABLE) return;
  GtkWidget *top = gtk_widget_get_toplevel(page->page);
  page->chooser = gtk_file_chooser_dialog_new("保存 Linux 更新包", GTK_IS_WINDOW(top) ? GTK_WINDOW(top) : NULL,
      GTK_FILE_CHOOSER_ACTION_SAVE, "取消", GTK_RESPONSE_CANCEL, "下载", GTK_RESPONSE_ACCEPT, NULL);
  gtk_window_set_modal(GTK_WINDOW(page->chooser), TRUE);
  gtk_file_chooser_set_local_only(GTK_FILE_CHOOSER(page->chooser), TRUE);
  gtk_file_chooser_set_do_overwrite_confirmation(GTK_FILE_CHOOSER(page->chooser), TRUE);
  char *name = release_text(page->release, MC_UPDATE_ASSET_NAME);
  gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(page->chooser), name);
  g_free(name);
  const char *downloads = g_get_user_special_dir(G_USER_DIRECTORY_DOWNLOAD);
  if (downloads) gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(page->chooser), downloads);
  g_signal_connect(page->chooser, "response", G_CALLBACK(chooser_response), page);
  gtk_widget_show(page->chooser);
}
static void cancel_clicked(GtkButton *button, gpointer data) {
  (void)button;
  UpdatePage *page = data;
  if (page->cancel_task) g_cancellable_cancel(page->cancel_task);
}
static void open_clicked(GtkButton *button, gpointer data) {
  (void)button;
  UpdatePage *page = data;
  if (!page->downloaded || page->destroyed) return;
  char *directory = g_path_get_dirname(page->downloaded);
  char *uri = g_filename_to_uri(directory, NULL, NULL);
  GError *error = NULL;
  if (!uri || !g_app_info_launch_default_for_uri(uri, NULL, &error))
    gtk_label_set_text(GTK_LABEL(page->status), error ? error->message : "无法打开下载目录。");
  g_clear_error(&error); g_free(uri); g_free(directory);
}

enum { PORTABLE_FILE = 1, PORTABLE_DIRECTORY = 2 };

static gboolean portable_path(const char *path) {
  if (!*path || strlen(path) > 512) return FALSE;
  const char *component = path;
  unsigned depth = 0;
  for (const char *at = path; ; at++) {
    if (*at == '/' || !*at) {
      size_t length = (size_t)(at - component);
      if (!length || ++depth > 16 || at[-1] == '.') return FALSE;
      if (!*at) return TRUE;
      component = at + 1;
    } else if (!g_ascii_isalnum(*at) && !strchr("._-+", *at)) return FALSE;
  }
}

static int portable_kind(GHashTable *entries, const char *path) {
  return GPOINTER_TO_INT(g_hash_table_lookup(entries, path));
}

static gboolean read_portable_inventory(int folder, GHashTable *entries) {
  int manifest = openat(folder, PORTABLE_MANIFEST, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (manifest < 0) return FALSE;
  struct stat info;
  if (fstat(manifest, &info) != 0 || !S_ISREG(info.st_mode) ||
      info.st_size <= 0 || info.st_size > (off_t)PORTABLE_MANIFEST_LIMIT) {
    close(manifest);
    return FALSE;
  }
  gsize length = (gsize)info.st_size, offset = 0;
  g_autofree char *contents = g_malloc(length + 1);
  while (offset < length) {
    ssize_t bytes = read(manifest, contents + offset, length - offset);
    if (bytes < 0 && errno == EINTR) continue;
    if (bytes <= 0) break;
    offset += (gsize)bytes;
  }
  char extra;
  ssize_t tail;
  do { tail = read(manifest, &extra, 1); } while (tail < 0 && errno == EINTR);
  close(manifest);
  if (offset != length || tail != 0 || contents[length - 1] != '\n' || memchr(contents, 0, length)) return FALSE;
  contents[length] = 0;
  g_auto(GStrv) lines = g_strsplit(contents, "\n", -1);
  if (strcmp(lines[0], PORTABLE_HEADER) != 0) return FALSE;
  for (size_t i = 1; lines[i]; ++i) {
    const char *line = lines[i];
    if (!*line && !lines[i + 1]) break;
    if (i > 1 && strcmp(lines[i - 1], line) >= 0) return FALSE;
    size_t length = strlen(line);
    gboolean directory = length > 0 && line[length - 1] == '/';
    g_autofree char *path = g_strndup(line, length - (directory ? 1 : 0));
    if (!portable_path(path) || portable_kind(entries, path)) return FALSE;
    g_hash_table_insert(entries, g_steal_pointer(&path), GINT_TO_POINTER(directory ? PORTABLE_DIRECTORY : PORTABLE_FILE));
  }
  static const char *const required[] = {
    "moojicut", "build.json", "launch.sh", "MoojiPluginWorker", "runtime/bin/gst-plugin-scanner", PORTABLE_MANIFEST
  };
  for (size_t i = 0; i < G_N_ELEMENTS(required); ++i)
    if (portable_kind(entries, required[i]) != PORTABLE_FILE) return FALSE;
  return TRUE;
}

/* Inspect relative to an already opened directory. A mount, symlink, or
 * unexpected file aborts the whole operation before anything moves. */
static gboolean check_portable_tree(int folder, const char *prefix, dev_t device, GHashTable *entries) {
  int read_fd = dup(folder);
  if (read_fd < 0) return FALSE;
  DIR *stream = fdopendir(read_fd);
  if (!stream) { close(read_fd); return FALSE; }
  gboolean ok = TRUE;
  while (ok) {
    errno = 0;
    struct dirent *child = readdir(stream);
    if (!child) { ok = errno == 0; break; }
    if (!strcmp(child->d_name, ".") || !strcmp(child->d_name, "..")) continue;
    g_autofree char *relative = g_strconcat(prefix, child->d_name, NULL);
    int kind = portable_kind(entries, relative);
    struct stat info;
    if (!kind || fstatat(folder, child->d_name, &info, AT_SYMLINK_NOFOLLOW) != 0 ||
        info.st_dev != device || info.st_uid != geteuid()) { ok = FALSE; break; }
    if (kind == PORTABLE_DIRECTORY && S_ISDIR(info.st_mode)) {
      int sub = openat(folder, child->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      struct stat opened;
      g_autofree char *base = g_strconcat(relative, "/", NULL);
      ok = sub >= 0 && fstat(sub, &opened) == 0 && opened.st_ino == info.st_ino && opened.st_dev == device &&
          check_portable_tree(sub, base, device, entries);
      if (sub >= 0) close(sub);
    } else ok = kind == PORTABLE_FILE && S_ISREG(info.st_mode);
    if (ok) g_hash_table_remove(entries, relative);
  }
  closedir(stream);
  return ok;
}

static gboolean same_inode(const struct stat *a, const struct stat *b) {
  return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}

static gboolean validate_portable_folder(const char *path, const struct stat *executable, struct stat *root) {
  g_autofree char *name = g_path_get_basename(path);
  if (strcmp(name, "MoojiCut") != 0) return FALSE;
  int folder = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (folder < 0) return FALSE;
  struct stat program, current, parent;
  g_autoptr(GHashTable) entries = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  gboolean ok = fstat(folder, root) == 0 && root->st_uid == geteuid() &&
      fstatat(folder, "..", &parent, 0) == 0 && parent.st_dev == root->st_dev && !same_inode(&parent, root) &&
      fstatat(folder, "moojicut", &program, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(program.st_mode) &&
      same_inode(executable, &program) && read_portable_inventory(folder, entries) &&
      check_portable_tree(folder, "", root->st_dev, entries) && g_hash_table_size(entries) == 0 &&
      lstat(path, &current) == 0 && same_inode(&current, root);
  close(folder);
  return ok;
}

static gboolean managed_location(const char *folder) {
  static const char *const prefixes[] = {
    "/app", "/bin", "/sbin", "/usr", "/lib", "/lib64", "/etc", "/opt", "/var", "/snap", "/nix", "/run/user"
  };
  for (size_t i = 0; i < G_N_ELEMENTS(prefixes); ++i) {
    size_t length = strlen(prefixes[i]);
    if (strncmp(folder, prefixes[i], length) == 0 && (folder[length] == '/' || !folder[length])) return TRUE;
  }
  return g_str_has_prefix(folder, "/tmp/.mount_");
}

static void uninstall_notice(UpdatePage *page, const char *title, const char *details, const char *folder) {
  if (page->destroyed) return;
  GtkWidget *top = gtk_widget_get_toplevel(page->page);
  GtkWidget *dialog = gtk_message_dialog_new(GTK_IS_WINDOW(top) ? GTK_WINDOW(top) : NULL,
      GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, GTK_MESSAGE_INFO, GTK_BUTTONS_CLOSE, "%s", title);
  g_autofree char *display = folder ? g_filename_display_name(folder) : NULL;
  gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog), "%s%s%s", details, display ? "\n\n" : "", display ? display : "");
  if (folder) gtk_dialog_add_button(GTK_DIALOG(dialog), "打开所在位置", GTK_RESPONSE_ACCEPT);
  gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_CLOSE);
  g_object_ref_sink(dialog);
  int response = gtk_dialog_run(GTK_DIALOG(dialog));
  gtk_widget_destroy(dialog);
  g_object_unref(dialog);
  if (!page->destroyed && response == GTK_RESPONSE_ACCEPT && folder) {
    g_autofree char *parent = g_path_get_dirname(folder);
    g_autofree char *uri = g_filename_to_uri(parent, NULL, NULL);
    if (!uri || !g_app_info_launch_default_for_uri(uri, NULL, NULL))
      gtk_label_set_text(GTK_LABEL(page->status), "无法打开文件管理器。请按显示的路径找到应用目录。");
  }
}

static void uninstall_portable(UpdatePage *page) {
  const char *blocker = page->uninstall_blocker ? page->uninstall_blocker() : NULL;
  if (blocker) { gtk_label_set_text(GTK_LABEL(page->status), blocker); return; }
  g_autofree char *executable = g_file_read_link("/proc/self/exe", NULL);
  g_autofree char *folder = executable ? g_path_get_dirname(executable) : NULL;
  if (folder && managed_location(folder)) {
    uninstall_notice(page, "请通过原安装方式卸载", "此位置位于系统安装目录。若通过软件包管理器安装，请在该工具中移除 Mooji Cut。", folder);
    return;
  }
  g_autofree char *name = executable ? g_path_get_basename(executable) : NULL;
  struct stat original, program;
  const char *manual = "请退出 Mooji Cut，然后在文件管理器中移除应用文件。请保留目录里的其他文件。";
  if (!folder || !g_path_is_absolute(folder) || !name || strcmp(name, "moojicut") != 0 || geteuid() == 0 ||
      stat("/proc/self/exe", &program) != 0 || !validate_portable_folder(folder, &program, &original)) {
    uninstall_notice(page, "需要手动卸载", manual, folder);
    return;
  }
  GtkWidget *top = gtk_widget_get_toplevel(page->page);
  GtkWidget *dialog = gtk_message_dialog_new(GTK_IS_WINDOW(top) ? GTK_WINDOW(top) : NULL,
      GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, GTK_MESSAGE_WARNING, GTK_BUTTONS_NONE, "卸载 Mooji Cut？");
  g_autofree char *display = g_filename_display_name(folder);
  gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog),
      "将此便携应用目录移到回收站，并退出应用。设置、插件和录屏文件会保留。\n\n%s", display);
  gtk_dialog_add_button(GTK_DIALOG(dialog), "取消", GTK_RESPONSE_CANCEL);
  GtkWidget *action = gtk_dialog_add_button(GTK_DIALOG(dialog), "移到回收站", GTK_RESPONSE_ACCEPT);
  gtk_style_context_add_class(gtk_widget_get_style_context(action), "destructive-action");
  gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_CANCEL);
  g_object_ref_sink(dialog);
  int response = gtk_dialog_run(GTK_DIALOG(dialog));
  gtk_widget_destroy(dialog);
  g_object_unref(dialog);
  if (page->destroyed || response != GTK_RESPONSE_ACCEPT) return;

  blocker = page->uninstall_blocker ? page->uninstall_blocker() : NULL;
  if (active_pages || blocker) {
    gtk_label_set_text(GTK_LABEL(page->status), blocker ? blocker : "请先结束正在进行的更新。");
    return;
  }
  struct stat current;
  if (!validate_portable_folder(folder, &program, &current) || !same_inode(&current, &original)) {
    uninstall_notice(page, "应用目录已变化", manual, folder);
    return;
  }
  g_autoptr(GFile) file = g_file_new_for_path(folder);
  g_autoptr(GError) error = NULL;
  if (!g_file_trash(file, NULL, &error)) {
    uninstall_notice(page, "无法把应用移到回收站", manual, folder);
    return;
  }
  page->quit_after_uninstall();
}

static void uninstall_clicked(GtkButton *button, gpointer data) {
  (void)button;
  UpdatePage *page = data;
  if (page->destroyed || page->uninstalling || !page->quit_after_uninstall) return;
  if (page->busy || active_pages || page->chooser) {
    gtk_label_set_text(GTK_LABEL(page->status), "请先结束正在进行的更新。");
    return;
  }
  page_ref(page);
  page->uninstalling = TRUE;
  page_busy(page, FALSE);
  uninstall_portable(page);
  page->uninstalling = FALSE;
  page_busy(page, page->busy);
  page_unref(page);
}

static void page_destroyed(GtkWidget *widget, gpointer data) {
  (void)widget;
  UpdatePage *page = data;
  page->destroyed = TRUE;
  if (page->cancel_task) g_cancellable_cancel(page->cancel_task);
  if (page->chooser) { gtk_widget_destroy(page->chooser); page->chooser = NULL; }
}
static GtkWidget *text_label(const char *text) {
  GtkWidget *label = gtk_label_new(text);
  gtk_label_set_xalign(GTK_LABEL(label), 0);
  gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
  gtk_label_set_max_width_chars(GTK_LABEL(label), 56);
  return label;
}
GtkWidget *mc_linux_update_preferences(const char *(*uninstall_blocker)(void), void (*quit_after_uninstall)(void)) {
  UpdatePage *page = g_new0(UpdatePage, 1);
  page->references = 1;
  page->uninstall_blocker = uninstall_blocker;
  page->quit_after_uninstall = quit_after_uninstall;
  GApplication *application = g_application_get_default();
  if (application) page->application = g_object_ref(application);
  page->page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
  gtk_container_set_border_width(GTK_CONTAINER(page->page), 24);
  g_object_set_data_full(G_OBJECT(page->page), "mooji-updates", page, (GDestroyNotify)page_unref);
  g_signal_connect(page->page, "destroy", G_CALLBACK(page_destroyed), page);
  gtk_box_pack_start(GTK_BOX(page->page), text_label("当前版本  " MOOJICUT_VERSION), FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(page->page), text_label("更新来自 CoderSerio/moojicut 的 GitHub Releases。预览版接收预览更新，正式版接收正式更新。"), FALSE, FALSE, 0);
  page->status = text_label("检查并下载 Linux x64 便携包；下载后需手动解压运行，不会自动替换当前目录。");
  gtk_label_set_selectable(GTK_LABEL(page->status), TRUE);
  gtk_box_pack_start(GTK_BOX(page->page), page->status, FALSE, FALSE, 0);
  GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  page->check = gtk_button_new_with_label("检查更新");
  page->download = gtk_button_new_with_label("下载更新包…");
  page->cancel = gtk_button_new_with_label("取消");
  page->spinner = gtk_spinner_new();
  gtk_box_pack_start(GTK_BOX(row), page->check, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(row), page->download, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(row), page->cancel, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(row), page->spinner, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(page->page), row, FALSE, FALSE, 0);
  page->open = gtk_button_new_with_label("打开下载位置");
  gtk_widget_set_halign(page->open, GTK_ALIGN_START);
  gtk_box_pack_start(GTK_BOX(page->page), page->open, FALSE, FALSE, 0);
  GtkWidget *link = gtk_link_button_new_with_label(RELEASES_PAGE, "查看 GitHub Releases");
  gtk_widget_set_halign(link, GTK_ALIGN_START);
  gtk_box_pack_start(GTK_BOX(page->page), link, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(page->page), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), FALSE, FALSE, 0);
  page->uninstall = gtk_button_new_with_label("卸载 Mooji Cut…");
  gtk_widget_set_halign(page->uninstall, GTK_ALIGN_START);
  gtk_box_pack_start(GTK_BOX(page->page), page->uninstall, FALSE, FALSE, 0);
  g_signal_connect(page->check, "clicked", G_CALLBACK(check_clicked), page);
  g_signal_connect(page->download, "clicked", G_CALLBACK(download_clicked), page);
  g_signal_connect(page->cancel, "clicked", G_CALLBACK(cancel_clicked), page);
  g_signal_connect(page->open, "clicked", G_CALLBACK(open_clicked), page);
  g_signal_connect(page->uninstall, "clicked", G_CALLBACK(uninstall_clicked), page);
  page_busy(page, FALSE);
  return page->page;
}

typedef struct { gboolean done; Response *response; GError *error; } TransferProbe;
static void smoke_transfer_done(GObject *source, GAsyncResult *result, gpointer data) {
  (void)source;
  TransferProbe *probe = data;
  probe->response = g_task_propagate_pointer(G_TASK(result), &probe->error);
  probe->done = TRUE;
}
static void smoke_wait(volatile gboolean *done) {
  gint64 deadline = g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND;
  while (!*done && g_get_monotonic_time() < deadline) {
    while (g_main_context_iteration(NULL, FALSE)) {}
    g_usleep(1000);
  }
}
static Request *smoke_request(const char *path, const char *payload, const char *hash) {
  Request *request = g_new0(Request, 1);
  request->url = g_strdup("https://github.com/CoderSerio/moojicut/releases/download/v99.0.0/fixture.tar.gz");
  request->destination = g_strdup(path);
  request->expected = strlen(payload);
  request->sha256 = g_strdup(hash);
  request->fixture = g_bytes_new(payload, strlen(payload));
  return request;
}
static gboolean smoke_transfer(Request *request, gboolean cancelled, gboolean expect_success) {
  /* Keep the probe heap-owned if a broken worker exceeds the smoke deadline. */
  TransferProbe *probe = g_new0(TransferProbe, 1);
  GCancellable *cancel = g_cancellable_new();
  if (cancelled) g_cancellable_cancel(cancel);
  GTask *task = g_task_new(NULL, cancel, smoke_transfer_done, probe);
  g_task_set_check_cancellable(task, FALSE);
  g_task_set_task_data(task, request, (GDestroyNotify)request_free);
  g_task_run_in_thread(task, transfer_worker);
  g_object_unref(task);
  smoke_wait(&probe->done);
  gboolean ok = probe->done && (expect_success ? probe->response && !probe->error : !probe->response && probe->error);
  if (cancelled) ok = ok && g_error_matches(probe->error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  if (probe->done) {
    response_free(probe->response); g_clear_error(&probe->error); g_free(probe);
  } else g_cancellable_cancel(cancel);
  g_object_unref(cancel);
  return ok;
}
static gboolean smoke_uninstall_inventory(void) {
  static const char *const relative[] = { "MoojiPluginWorker", "build.json", "launch.sh", "moojicut", "runtime/bin/gst-plugin-scanner" };
  g_autofree char *fixture = g_dir_make_tmp("moojicut-uninstall-smoke-XXXXXX", NULL);
  if (!fixture) return FALSE;
  g_autofree char *folder = g_build_filename(fixture, "MoojiCut", NULL);
  g_autofree char *runtime = g_build_filename(folder, "runtime", NULL);
  g_autofree char *bin = g_build_filename(runtime, "bin", NULL);
  g_autofree char *empty = g_build_filename(runtime, "empty", NULL);
  g_autofree char *program = g_build_filename(folder, "moojicut", NULL);
  g_autofree char *manifest = g_build_filename(folder, PORTABLE_MANIFEST, NULL);
  g_autofree char *extra = g_build_filename(folder, "recording.webm", NULL);
  g_autofree char *internal = g_build_filename(bin, "gst-plugin-scanner", NULL);
  g_autoptr(GString) inventory = g_string_new(PORTABLE_HEADER "\n"
      "MoojiPluginWorker\n"
      "build.json\n"
      "launch.sh\n"
      "moojicut\n"
      "runtime/\n"
      "runtime/bin/\n"
      "runtime/bin/gst-plugin-scanner\n"
      "runtime/empty/\n"
      PORTABLE_MANIFEST "\n");
  gboolean ok = g_mkdir_with_parents(bin, 0700) == 0 && g_mkdir(empty, 0700) == 0;
  for (size_t i = 0; i < G_N_ELEMENTS(relative); ++i) {
    g_autofree char *path = g_build_filename(folder, relative[i], NULL);
    ok = g_file_set_contents(path, "fixture", -1, NULL) && ok;
  }
  struct stat executable = { 0 }, root;
  ok = g_file_set_contents(manifest, inventory->str, -1, NULL) && g_stat(program, &executable) == 0 && ok;
  ok = !validate_portable_folder(fixture, &executable, &root) && ok;
  ok = validate_portable_folder(folder, &executable, &root) && ok;
  ok = g_file_set_contents(extra, "user video", -1, NULL) && ok;
  ok = !validate_portable_folder(folder, &executable, &root) && g_file_test(extra, G_FILE_TEST_IS_REGULAR) && ok;
  ok = g_unlink(internal) == 0 && g_unlink(extra) == 0 && ok;
  ok = !validate_portable_folder(folder, &executable, &root) && ok;
  ok = symlink(program, internal) == 0 && !validate_portable_folder(folder, &executable, &root) && ok;
  g_unlink(internal);
  ok = g_file_set_contents(internal, "fixture", -1, NULL) && ok;
  g_string_insert(inventory, strlen(PORTABLE_HEADER) + 1, "../outside\n");
  ok = g_file_set_contents(manifest, inventory->str, -1, NULL) && !validate_portable_folder(folder, &executable, &root) && ok;
  ok = managed_location("/usr/local/bin") && managed_location("/tmp/.mount_Mooji") && !managed_location("/usr-data/MoojiCut") && ok;
  for (size_t i = 0; i < G_N_ELEMENTS(relative); ++i) {
    g_autofree char *path = g_build_filename(folder, relative[i], NULL);
    g_unlink(path);
  }
  g_unlink(extra); g_unlink(manifest); g_rmdir(empty); g_rmdir(bin); g_rmdir(runtime); g_rmdir(folder); g_rmdir(fixture);
  g_print("Linux uninstall smoke %s: inventory permits only a complete portable tree and rejects user files, missing files, symlinks, and traversal.\n", ok ? "passed" : "FAILED");
  return ok;
}

gboolean mc_linux_update_smoke(void) {
  if (!curl_ready()) return FALSE;
  char *directory = g_dir_make_tmp("moojicut-update-smoke-XXXXXX", NULL);
  if (!directory) return FALSE;
  char *path = g_build_filename(directory, "update.tar.gz", NULL);
  const char *payload = "synthetic verified update bytes";
  char *hash = g_compute_checksum_for_string(G_CHECKSUM_SHA256, payload, -1);
  gboolean ok = smoke_uninstall_inventory() && smoke_transfer(smoke_request(path, payload, hash), FALSE, TRUE);
  char *read = NULL;
  ok = g_file_get_contents(path, &read, NULL, NULL) && g_strcmp0(read, payload) == 0 && ok;
  g_free(read); read = NULL;
  /* A failed replacement must leave an already saved file untouched. */
  ok = smoke_transfer(smoke_request(path, "incorrect bytes", hash), FALSE, FALSE) && ok;
  Request *short_body = smoke_request(path, payload, hash);
  short_body->expected++;
  ok = smoke_transfer(short_body, FALSE, FALSE) && ok;
  Request *long_body = smoke_request(path, payload, hash);
  long_body->expected--;
  ok = smoke_transfer(long_body, FALSE, FALSE) && ok;
  ok = smoke_transfer(smoke_request(path, payload, hash), TRUE, FALSE) && ok;
  Request *insecure = smoke_request(path, payload, hash);
  g_free(insecure->url); insecure->url = g_strdup("http://example.invalid/update");
  ok = smoke_transfer(insecure, FALSE, FALSE) && ok;
  ok = g_file_get_contents(path, &read, NULL, NULL) && g_strcmp0(read, payload) == 0 && ok;
  g_free(read);
  Request *large = smoke_request(NULL, "", NULL);
  char *bytes = g_malloc0(BODY_LIMIT + 1);
  g_bytes_unref(large->fixture);
  large->fixture = g_bytes_new_take(bytes, BODY_LIMIT + 1);
  ok = smoke_transfer(large, FALSE, FALSE) && ok;
  Request *invalid_utf8 = smoke_request(NULL, "\xFF", NULL);
  ok = smoke_transfer(invalid_utf8, FALSE, FALSE) && ok;
  Request *paginated = smoke_request(NULL, "[]", NULL);
  paginated->fixture_header = g_strdup("Link: <https://api.github.com/repos/CoderSerio/moojicut/releases?page=2>; rel=\"next\"\r\n");
  ok = smoke_transfer(paginated, FALSE, FALSE) && ok;
  /* Close settings during an asynchronous transfer, then let its callback run. */
  GtkWidget *widget = mc_linux_update_preferences(NULL, NULL);
  g_object_ref_sink(widget);
  UpdatePage *page = page_ref(g_object_get_data(G_OBJECT(widget), "mooji-updates"));
  char *release = g_strdup_printf("[{\"tag_name\":\"v99.0.0\",\"draft\":false,\"prerelease\":false,"
      "\"published_at\":\"2026-11-15T00:00:00Z\","
      "\"html_url\":\"https://github.com/CoderSerio/moojicut/releases/tag/v99.0.0\",\"assets\":[{"
      "\"name\":\"moojicut-99.0.0-linux-x64.tar.gz\",\"state\":\"uploaded\",\"size\":%zu,\"digest\":\"sha256:%s\","
      "\"browser_download_url\":\"https://github.com/CoderSerio/moojicut/releases/download/v99.0.0/moojicut-99.0.0-linux-x64.tar.gz\"}]}]",
      strlen(payload), hash);
  start_transfer(page, smoke_request(NULL, release, NULL));
  g_free(release);
  gint64 deadline = g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND;
  while (page->busy && g_get_monotonic_time() < deadline) {
    while (g_main_context_iteration(NULL, FALSE)) {}
    g_usleep(1000);
  }
  ok = !page->busy && page->release && update_release_status(page->release) == MC_UPDATE_AVAILABLE &&
       gtk_widget_get_sensitive(page->download) && ok;
  start_transfer(page, smoke_request(path, payload, hash));
  gtk_widget_destroy(widget);
  g_object_unref(widget);
  deadline = g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND;
  while (page->busy && g_get_monotonic_time() < deadline) {
    while (g_main_context_iteration(NULL, FALSE)) {}
    g_usleep(1000);
  }
  ok = page->destroyed && !page->busy && ok;
  page_unref(page);
  GDir *entries = g_dir_open(directory, 0, NULL);
  const char *name;
  int count = 0;
  while (entries && (name = g_dir_read_name(entries))) {
    count++;
    ok = g_strcmp0(name, "update.tar.gz") == 0 && ok;
  }
  if (entries) g_dir_close(entries);
  ok = count == 1 && ok;
  g_unlink(path); g_rmdir(directory);
  g_free(path); g_free(directory); g_free(hash);
  g_print("Linux update smoke %s: asynchronous transfer, SHA-256/size limits, HTTPS requirement, cancellation, failed replacement preserves file, destroyed-page callback, no partial files.\n", ok ? "passed" : "FAILED");
  return ok;
}
