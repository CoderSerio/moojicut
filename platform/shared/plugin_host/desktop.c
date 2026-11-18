#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include "desktop.h"
#include "package_store.h"
#include "worker_process.h"
#include "bindings/c/plugin_application.h"
#include "bindings/c/tool_registry.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <pthread.h>
#include <stdatomic.h>
#endif

enum { MAX_JOBS = 8, MAX_PACKAGES = 64, JSON_LIMIT = 14 * 1024 * 1024 };

typedef struct {
    char *text;
    size_t length, available;
    bool failed;
} JSONBuffer;

typedef struct {
    MCPluginZipPackage zip;
    char digest[65];
} Archive;

typedef struct {
    char *id;
    uint8_t *bytes;
    size_t size;
} Icon;

typedef struct {
    bool importing, reading, loaded, cancelled, queued, installed;
    int32_t ticket, capture;
    char *path, *tool_id, *request;
    Archive archive;
    MCPluginProcess *process;
    char error[256];
#ifdef _WIN32
    HANDLE reader;
#else
    pthread_t reader;
    atomic_bool done;
#endif
    struct MCDesktopPlugins *host;
} Job;

struct MCDesktopPlugins {
    char *root, *worker;
    int32_t application, capabilities;
    MCDesktopPluginPlatform platform;
    MCDesktopPluginHooks hooks;
    Job *jobs[MAX_JOBS];
    Icon icons[MAX_PACKAGES];
    bool closing, dispatching, desynced;
};

static char *copy_text(const void *bytes, size_t size) {
    if (size >= JSON_LIMIT) return NULL;
    char *copy = malloc(size + 1);
    if (!copy) return NULL;
    if (size) memcpy(copy, bytes, size);
    copy[size] = 0;
    return copy;
}

static void append_bytes(JSONBuffer *out, const char *source, size_t length) {
    if (out->failed || length >= JSON_LIMIT - out->length) {
        out->failed = true;
        return;
    }
    size_t needed = out->length + length + 1;
    if (needed > out->available) {
        size_t capacity = out->available ? out->available * 2 : 256;
        if (capacity < needed) capacity = needed;
        if (capacity > JSON_LIMIT) capacity = JSON_LIMIT;
        char *grown = realloc(out->text, capacity);
        if (!grown) { out->failed = true; return; }
        out->text = grown;
        out->available = capacity;
    }
    memcpy(out->text + out->length, source, length);
    out->length += length;
    out->text[out->length] = 0;
}

static void append(JSONBuffer *out, const char *source) {
    append_bytes(out, source, strlen(source));
}

static void quote(JSONBuffer *out, const char *text) {
    if (!text) { append(out, "null"); return; }
    append(out, "\"");
    const char *start = text;
    for (const char *p = text; *p; ++p) {
        const unsigned char c = (unsigned char)*p;
        if (c >= 32 && c != '"' && c != '\\') continue;
        append_bytes(out, start, (size_t)(p - start));
        if (c == '"' || c == '\\') {
            const char escaped[2] = {'\\', (char)c};
            append_bytes(out, escaped, sizeof(escaped));
        } else {
            char escaped[7];
            snprintf(escaped, sizeof(escaped), "\\u%04x", (unsigned)c);
            append(out, escaped);
        }
        start = p + 1;
    }
    append(out, start);
    append(out, "\"");
}

static void append_id(JSONBuffer *out, int32_t id) {
    char number[16];
    snprintf(number, sizeof(number), "%ld", (long)id);
    append(out, number);
}

static moonbit_string_t moon_text(const char *value) {
    size_t size = strlen(value);
    if (size >= JSON_LIMIT) return NULL;
    moonbit_bytes_t bytes = moonbit_make_bytes_raw((int32_t)size);
    if (size) memcpy(bytes, value, size);
    moonbit_string_t result = plugin_application_decode_utf8(bytes);
    moonbit_decref(bytes);
    if (size && !Moonbit_array_length(result)) {
        moonbit_decref(result);
        return NULL;
    }
    return result;
}

static char *take_text(moonbit_string_t value) {
    moonbit_bytes_t bytes = plugin_application_encode_utf8(value);
    moonbit_decref(value);
    char *copy = copy_text(bytes, (size_t)Moonbit_array_length(bytes));
    moonbit_decref(bytes);
    return copy;
}

static char *field(const char *reply, const char *key, int32_t index,
                   const char *child, bool literal) {
    if (!reply) return NULL;
    moonbit_string_t source = moon_text(reply), name = moon_text(key), nested = moon_text(child);
    char *result = source && name && nested ?
        take_text(plugin_application_reply_field(source, name, index, nested, literal ? 1 : 0)) : NULL;
    if (source) moonbit_decref(source);
    if (name) moonbit_decref(name);
    if (nested) moonbit_decref(nested);
    return result;
}

static char *text(const char *reply, const char *key) { return field(reply, key, -1, "", false); }

static bool flag(const char *reply, const char *key) {
    char *value = field(reply, key, -1, "", true);
    bool result = value && strcmp(value, "true") == 0;
    free(value);
    return result;
}

static int32_t number(const char *reply, const char *key, int32_t index) {
    char *value = field(reply, key, index, "", true);
    char *end = NULL;
    long parsed = value ? strtol(value, &end, 10) : 0;
    bool valid = value && end != value && *end == 0 && parsed > 0 && parsed < INT32_MAX;
    free(value);
    return valid ? (int32_t)parsed : 0;
}

static void notify(MCDesktopPlugins *host, const char *message, bool error) {
    if (host->hooks.message && !host->closing) host->hooks.message(host->hooks.context, message, error);
}

static void reply_error(MCDesktopPlugins *host, const char *reply) {
    char *message = field(reply, "error", -1, "message", false);
    notify(host, message && *message ? message : "Plugin operation failed.", true);
    free(message);
}

static char *command(MCDesktopPlugins *host, const char *value) {
    moonbit_string_t input = moon_text(value);
    if (!input) return NULL;
    char *reply = take_text(plugin_application_request(host->application, input));
    moonbit_decref(input);
    return reply;
}

static char *send(MCDesktopPlugins *host, JSONBuffer *out) {
    char *reply = out->failed ? NULL : command(host, out->text);
    free(out->text);
    return reply;
}

static char *ticket_command(MCDesktopPlugins *host, const char *operation, int32_t ticket,
                            const char *name, const char *value, bool literal) {
    JSONBuffer out = {0};
    append(&out, "{\"op\":");
    quote(&out, operation);
    append(&out, ",\"ticket\":");
    append_id(&out, ticket);
    if (name) {
        append(&out, ",");
        quote(&out, name);
        append(&out, ":");
        if (literal) append(&out, value);
        else quote(&out, value);
    }
    append(&out, "}");
    return send(host, &out);
}

static void cancel_install(MCDesktopPlugins *host, int32_t ticket) {
    free(ticket_command(host, "cancelInstall", ticket, NULL, NULL, false));
}

static bool archive_unpack(MCDesktopPlugins *host, const uint8_t *bytes, size_t size,
                           const char *expected, Archive *archive, char error[256]) {
    if (!host->platform.sha256(bytes, size, archive->digest) ||
        (expected && strcmp(expected, archive->digest) != 0)) {
        snprintf(error, 256, "Plugin ZIP digest does not match its content.");
        return false;
    }
    MCPluginZipError code;
    if (!mc_plugin_zip_read(bytes, size, host->platform.inflate, NULL, &archive->zip, &code)) {
        snprintf(error, 256, "%s", mc_plugin_zip_error_text(code));
        return false;
    }
    if (memchr(archive->zip.manifest.bytes, 0, archive->zip.manifest.size)) {
        snprintf(error, 256, "Plugin manifest contains a NUL byte.");
        return false;
    }
    return true;
}

static bool archive_restore(MCDesktopPlugins *host, const char *digest, Archive *archive, char error[256]) {
    MCPluginStoreBytes bytes = {0};
    MCPluginStoreError failure;
    MCPluginStoreStatus status = mc_plugin_store_read_zip(host->root, digest, &bytes, &failure);
    bool ok = status == MC_PLUGIN_STORE_OK;
    if (ok) ok = archive_unpack(host, bytes.bytes, bytes.size, digest, archive, error);
    else snprintf(error, 256, "%s", status == MC_PLUGIN_STORE_MISSING ? "Installed plugin ZIP is missing." : failure.message);
    mc_plugin_store_bytes_free(&bytes);
    return ok;
}

static bool verify_bytes(MCDesktopPlugins *host, const char *digest, const void *expected, size_t size) {
    MCPluginStoreBytes readback = {0};
    MCPluginStoreStatus status = digest ?
        mc_plugin_store_read_zip(host->root, digest, &readback, NULL) :
        mc_plugin_store_read_snapshot(host->root, &readback, NULL);
    bool match = status == MC_PLUGIN_STORE_OK && readback.size == size &&
        (!size || memcmp(readback.bytes, expected, size) == 0);
    mc_plugin_store_bytes_free(&readback);
    return match;
}

static bool archive_import(Job *job) {
    MCDesktopPlugins *host = job->host;
    uint8_t *bytes = NULL;
    size_t size = 0;
    if (!host->platform.read_zip(job->path, &bytes, &size, job->error)) return false;
    bool ok = size <= MC_PLUGIN_ZIP_MAX_BYTES && archive_unpack(host, bytes, size, NULL, &job->archive, job->error);
    if (ok) {
        MCPluginStoreError failure;
        MCPluginStoreStatus status = mc_plugin_store_stage_zip(
            host->root, job->archive.digest, bytes, size, &failure);
        ok = status == MC_PLUGIN_STORE_OK || (status == MC_PLUGIN_STORE_COMMITTED_NOT_DURABLE &&
            verify_bytes(host, job->archive.digest, bytes, size));
        if (!ok) snprintf(job->error, sizeof(job->error), "%s", failure.message);
    }
    free(bytes);
    return ok;
}

static void read_job(Job *job) {
    job->loaded = job->importing ? archive_import(job) :
        archive_restore(job->host, job->path, &job->archive, job->error);
}

#ifdef _WIN32
static DWORD WINAPI read_entry(void *argument) {
    read_job(argument);
    return 0;
}
#else
static void *read_entry(void *argument) {
    Job *job = argument;
    read_job(job);
    atomic_store_explicit(&job->done, true, memory_order_release);
    return NULL;
}
#endif

static bool start_reader(Job *job) {
#ifdef _WIN32
    job->reader = CreateThread(NULL, 0, read_entry, job, 0, NULL);
    job->reading = job->reader != NULL;
#else
    atomic_init(&job->done, false);
    job->reading = pthread_create(&job->reader, NULL, read_entry, job) == 0;
#endif
    return job->reading;
}

static bool reader_done(Job *job) {
#ifdef _WIN32
    if (WaitForSingleObject(job->reader, 0) != WAIT_OBJECT_0) return false;
    CloseHandle(job->reader);
#else
    if (!atomic_load_explicit(&job->done, memory_order_acquire)) return false;
    pthread_join(job->reader, NULL);
#endif
    job->reading = false;
    return true;
}

static void free_job(Job *job) {
    mc_plugin_zip_clear(&job->archive.zip);
    free(job->path);
    free(job->tool_id);
    free(job->request);
    free(job);
}

static Job *new_job(MCDesktopPlugins *host, bool importing) {
    for (size_t i = 0; i < MAX_JOBS; ++i) {
        if (host->jobs[i]) continue;
        Job *job = calloc(1, sizeof(*job));
        if (!job) return NULL;
        job->host = host;
        job->importing = importing;
        host->jobs[i] = job;
        return job;
    }
    return NULL;
}

static void erase_job(MCDesktopPlugins *host, Job *job) {
    for (size_t i = 0; i < MAX_JOBS; ++i) {
        if (host->jobs[i] != job) continue;
        host->jobs[i] = NULL;
        break;
    }
    if (job->importing && job->queued && host->hooks.import_complete)
        host->hooks.import_complete(host->hooks.context, job->installed);
    free_job(job);
}

static void update_icon(MCDesktopPlugins *host, const char *id, const MCPluginZipPackage *zip) {
    if (!id || !*id) return;
    Icon *entry = NULL;
    for (size_t i = 0; i < MAX_PACKAGES; ++i) {
        Icon *candidate = &host->icons[i];
        if (candidate->id && strcmp(candidate->id, id) == 0) { entry = candidate; break; }
        if (!candidate->id && !entry) entry = candidate;
    }
    if (!entry) return;
    free(entry->id);
    free(entry->bytes);
    *entry = (Icon){0};
    if (!zip || !zip->has_icon || !zip->icon.size) return;
    char *identifier = copy_text(id, strlen(id));
    uint8_t *image = malloc(zip->icon.size);
    if (!identifier || !image) { free(identifier); free(image); return; }
    memcpy(image, zip->icon.bytes, zip->icon.size);
    *entry = (Icon){identifier, image, zip->icon.size};
}

const uint8_t *mc_desktop_plugins_icon(const MCDesktopPlugins *host, const char *plugin_id, size_t *size) {
    if (size) *size = 0;
    if (!host || !plugin_id) return NULL;
    for (size_t i = 0; i < MAX_PACKAGES; ++i) {
        const Icon *entry = &host->icons[i];
        if (entry->id && strcmp(entry->id, plugin_id) == 0) {
            if (size) *size = entry->size;
            return entry->bytes;
        }
    }
    return NULL;
}

static int32_t open_snapshot(MCDesktopPlugins *host, const char *registry) {
    moonbit_string_t value = moon_text(registry);
    if (!value) return 0;
    int32_t snapshot = tool_registry_snapshot_open_packages(value, host->capabilities);
    moonbit_decref(value);
    return snapshot;
}

/* All UI preflights and the small index CAS run in one dispatch on the main
 * thread. No event loop is pumped between preflight and live publication. */
static bool publish(MCDesktopPlugins *host, const char *reply, const char *id,
                    const MCPluginZipPackage *icon) {
    if (!flag(reply, "ok")) { reply_error(host, reply); return false; }
    int32_t ticket = number(reply, "ticket", -1);
    char *registry = field(reply, "registry", -1, "", true);
    char *expected = text(reply, "expected");
    char *next = text(reply, "next");
    bool saved = false, reconciled = true;
    int32_t snapshot = registry && *registry ? open_snapshot(host, registry) : 0;
    if (!ticket || !snapshot || !expected || !next || !*next) {
        notify(host, "Cannot prepare the tool configuration.", true);
    } else if (!host->hooks.preflight(host->hooks.context, snapshot, registry)) {
        notify(host, "Finish the active screenshot edit before changing tools.", true);
    } else {
        MCPluginStoreError error;
        MCPluginStoreStatus status = mc_plugin_store_replace_snapshot(host->root, *expected != 0,
            *expected ? (const uint8_t *)expected : NULL, strlen(expected),
            (const uint8_t *)next, strlen(next), &error);
        saved = status == MC_PLUGIN_STORE_OK || status == MC_PLUGIN_STORE_COMMITTED_NOT_DURABLE;
        if (status == MC_PLUGIN_STORE_COMMITTED_NOT_DURABLE)
            reconciled = verify_bytes(host, NULL, next, strlen(next));
        if (!saved) notify(host, *error.message ? error.message : "Cannot save the plugin index.", true);
    }

    char *ack = ticket ? ticket_command(host, "publishComplete", ticket, "saved", saved ? "true" : "false", true) : NULL;
    bool published = saved && reconciled && flag(ack, "ok") && flag(ack, "published");
    if (published) {
        if (id) update_icon(host, id, icon);
        host->hooks.publish(host->hooks.context, snapshot, registry);
        snapshot = 0;
    } else {
        host->hooks.discard(host->hooks.context);
        if (saved) {
            host->desynced = true;
            notify(host, "The plugin index changed during publication. Reopen Mooji Cut to reload it.", true);
        }
    }
    if (snapshot) tool_registry_snapshot_close(snapshot);
    free(ack);
    free(registry);
    free(expected);
    free(next);
    return published;
}

static bool prepare_import(Job *job) {
    MCDesktopPlugins *host = job->host;
    const MCPluginZipBytes manifest = job->archive.zip.manifest;
    char *value = copy_text(manifest.bytes, manifest.size);
    if (!value) return false;
    JSONBuffer out = {0};
    append(&out, "{\"op\":\"prepareInstall\",\"importApproved\":true,\"manifest\":");
    quote(&out, value);
    append(&out, ",\"digest\":");
    quote(&out, job->archive.digest);
    append(&out, "}");
    free(value);
    char *prepared = send(host, &out);
    bool ok = flag(prepared, "ok");
    if (ok) {
        job->ticket = number(prepared, "ticket", -1);
        job->request = text(prepared, "request");
        ok = job->ticket > 0 && job->request && *job->request;
    } else reply_error(host, prepared);
    free(prepared);
    return ok;
}

static bool start_process(Job *job) {
    size_t length = strlen(job->request);
    MCPluginProcessRequest request = {
        .executable = job->host->worker,
        .wasm = job->archive.zip.wasm.bytes,
        .input = (const uint8_t *)job->request,
        .wire = {
            .wasm_size = job->archive.zip.wasm.size, .input_size = length,
            .max_output_bytes = MC_WASM_MAX_OUTPUT_BYTES, .fuel = MC_WASM_MAX_FUEL,
            .timeout_ms = MC_WASM_MAX_TIMEOUT_MS, .max_memory_pages = MC_WASM_MAX_MEMORY_PAGES,
        },
        .max_stderr_bytes = MC_WASM_DIAGNOSTIC_BYTES, .wall_ms = 5000,
    };
    job->process = mc_plugin_process_start(&request);
    return job->process != NULL;
}

static void finish_job(Job *job, const char *output) {
    MCDesktopPlugins *host = job->host;
    if (!job->ticket) return;
    char *result = ticket_command(host, job->importing ? "healthComplete" : "finishCall",
        job->ticket, "output", output, false);
    if (job->cancelled || host->closing || host->desynced) { free(result); return; }
    if (!flag(result, "ok")) {
        reply_error(host, result);
    } else if (job->importing) {
        if (flag(result, "ready")) {
            char *reserved = ticket_command(host, "reserveInstall", job->ticket, NULL, NULL, false);
            char *manifest = copy_text(job->archive.zip.manifest.bytes, job->archive.zip.manifest.size);
            char *id = text(manifest, "pluginId");
            job->installed = publish(host, reserved, id, &job->archive.zip);
            if (job->installed) notify(host, "Plugin installed.", false);
            else if (!flag(reserved, "ok")) cancel_install(host, job->ticket);
            free(id);
            free(manifest);
            free(reserved);
        } else if (!output) {
            notify(host, "The plugin worker could not complete its health check.", true);
        }
    } else if (host->hooks.result) {
        char *kind = text(result, "result");
        if (kind && strcmp(kind, "documentChanged") == 0) {
            host->hooks.result(host->hooks.context, job->capture, job->tool_id, "", "", true);
        } else if (kind && strcmp(kind, "text") == 0) {
            char *title = text(result, "title"), *value = text(result, "text");
            if (title && value) host->hooks.result(host->hooks.context, job->capture, job->tool_id, title, value, false);
            free(title);
            free(value);
        }
        free(kind);
    }
    free(result);
}

static void advance(MCDesktopPlugins *host, Job *job) {
    if (host->closing || host->desynced) job->cancelled = true;
    if (job->reading) {
        if (!reader_done(job)) return;
        if (!job->loaded || job->cancelled || (job->importing && !prepare_import(job))) {
            if (!job->loaded && !job->cancelled)
                notify(host, *job->error ? job->error : "Cannot load the plugin ZIP.", true);
            finish_job(job, NULL);
            erase_job(host, job);
            return;
        }
        if (start_process(job)) return;
        if (!job->importing) notify(host, "Cannot start the plugin worker.", true);
        finish_job(job, NULL);
        erase_job(host, job);
        return;
    }

    if (job->cancelled) mc_plugin_process_cancel(job->process);
    MCPluginProcessResult result;
    MCPluginProcessStatus status = mc_plugin_process_poll(job->process, &result);
    if (status == MC_PLUGIN_PROCESS_RUNNING) return;
    char *output = status == MC_PLUGIN_PROCESS_OK && result.output_size &&
        !memchr(result.output, 0, result.output_size) ?
        copy_text(result.output, result.output_size) : NULL;
    mc_plugin_process_close(job->process);
    job->process = NULL;
    if (!output && !job->cancelled && !job->importing) notify(host, "Plugin execution failed.", true);
    finish_job(job, output);
    free(output);
    erase_job(host, job);
}

void mc_desktop_plugins_pump(MCDesktopPlugins *host) {
    if (!host || host->dispatching) return;
    host->dispatching = true;
    char *status = command(host, "{\"op\":\"status\"}");
    for (int32_t i = 0; i < MAX_JOBS; ++i) {
        int32_t ticket = number(status, "cancel", i);
        if (!ticket) break;
        for (size_t j = 0; j < MAX_JOBS; ++j)
            if (host->jobs[j] && host->jobs[j]->ticket == ticket) host->jobs[j]->cancelled = true;
    }
    free(status);
    for (size_t i = 0; i < MAX_JOBS; ++i) if (host->jobs[i]) advance(host, host->jobs[i]);
    host->dispatching = false;
}

static bool service_ready(const MCDesktopPlugins *host) {
    return host && !host->closing && !host->desynced && !host->dispatching;
}

bool mc_desktop_plugins_import(MCDesktopPlugins *host, const char *path) {
    if (!service_ready(host) || !path || !*path) return false;
    for (size_t i = 0; i < MAX_JOBS; ++i) if (host->jobs[i] && host->jobs[i]->importing) return false;
    Job *job = new_job(host, true);
    if (!job) return false;
    job->path = copy_text(path, strlen(path));
    if (job->path && start_reader(job)) {
        job->queued = true;
        return true;
    }
    erase_job(host, job);
    return false;
}

bool mc_desktop_plugins_invoke(MCDesktopPlugins *host, int32_t capture,
                               const char *tool_id, const char *payload) {
    if (!service_ready(host) || capture <= 0 || !tool_id || !payload) return false;
    Job *job = new_job(host, false);
    if (!job) return false;
    host->dispatching = true;
    job->tool_id = copy_text(tool_id, strlen(tool_id));
    JSONBuffer out = {0};
    append(&out, "{\"op\":\"startCall\",\"capture\":");
    append_id(&out, capture);
    append(&out, ",\"tool\":");
    quote(&out, tool_id);
    append(&out, ",\"payload\":");
    quote(&out, payload);
    append(&out, "}");
    char *reply = send(host, &out);
    bool accepted = false;
    if (flag(reply, "ok")) {
        job->capture = capture;
        job->ticket = number(reply, "ticket", -1);
        job->path = text(reply, "digest");
        job->request = text(reply, "request");
        accepted = job->ticket && job->path && *job->path && job->request && *job->request &&
            job->tool_id && start_reader(job);
        if (!accepted) finish_job(job, NULL);
    } else reply_error(host, reply);
    free(reply);
    if (!accepted) erase_job(host, job);
    host->dispatching = false;
    return accepted;
}

void mc_desktop_plugins_close_capture(MCDesktopPlugins *host, int32_t capture) {
    if (!host || capture <= 0) return;
    for (size_t i = 0; i < MAX_JOBS; ++i)
        if (host->jobs[i] && host->jobs[i]->capture == capture) host->jobs[i]->cancelled = true;
    JSONBuffer out = {0};
    append(&out, "{\"op\":\"closeCapture\",\"capture\":");
    append_id(&out, capture);
    append(&out, "}");
    free(send(host, &out));
}

static bool tool_change(MCDesktopPlugins *host, const char *id, bool moving,
                        const char *before, bool enabled) {
    if (!service_ready(host) || !id || !*id) return false;
    host->dispatching = true;
    JSONBuffer out = {0};
    append(&out, "{\"op\":\"reserveToolChange\",\"command\":{\"id\":");
    quote(&out, id);
    if (moving) {
        append(&out, ",\"type\":\"move\",\"group\":\"screenshot\",\"beforeId\":");
        quote(&out, before && *before ? before : NULL);
    } else {
        append(&out, ",\"type\":\"enabled\",\"enabled\":");
        append(&out, enabled ? "true" : "false");
    }
    append(&out, "}}");
    char *reply = send(host, &out);
    bool ok = publish(host, reply, NULL, NULL);
    free(reply);
    host->dispatching = false;
    return ok;
}

bool mc_desktop_plugins_enabled(MCDesktopPlugins *host, const char *tool_id, bool enabled) {
    return tool_change(host, tool_id, false, NULL, enabled);
}

bool mc_desktop_plugins_move(MCDesktopPlugins *host, const char *tool_id, const char *before_id) {
    return tool_change(host, tool_id, true, before_id, false);
}

bool mc_desktop_plugins_uninstall(MCDesktopPlugins *host, const char *plugin_id) {
    if (!service_ready(host) || !plugin_id || !*plugin_id) return false;
    host->dispatching = true;
    JSONBuffer out = {0};
    append(&out, "{\"op\":\"reserveUninstall\",\"pluginId\":");
    quote(&out, plugin_id);
    append(&out, "}");
    char *reply = send(host, &out);
    bool ok = publish(host, reply, plugin_id, NULL);
    free(reply);
    host->dispatching = false;
    return ok;
}

bool mc_desktop_plugins_busy(const MCDesktopPlugins *host) {
    if (!host) return false;
    for (size_t i = 0; i < MAX_JOBS; ++i) if (host->jobs[i]) return true;
    return host->dispatching;
}

static void free_host(MCDesktopPlugins *host) {
    for (size_t i = 0; i < MAX_PACKAGES; ++i) {
        free(host->icons[i].id);
        free(host->icons[i].bytes);
    }
    free(host->root);
    free(host->worker);
    free(host);
}

bool mc_desktop_plugins_close(MCDesktopPlugins *host) {
    if (!host) return true;
    if (!host->closing) {
        host->closing = true;
        free(command(host, "{\"op\":\"beginClose\"}"));
    }
    if (host->dispatching) return false;
    mc_desktop_plugins_pump(host);
    if (mc_desktop_plugins_busy(host) || !plugin_application_close(host->application)) return false;
    free_host(host);
    return true;
}

static char *load_archives(MCDesktopPlugins *host, const char *index) {
    moonbit_string_t value = moon_text(index);
    if (!value) {
        notify(host, "The plugin settings index is not UTF-8.", true);
        return NULL;
    }
    char *requirements = take_text(plugin_application_requirements(value));
    moonbit_decref(value);
    if (!flag(requirements, "ok")) {
        reply_error(host, requirements);
        free(requirements);
        return NULL;
    }
    JSONBuffer out = {0};
    append(&out, "{\"archives\":[");
    bool valid = true;
    for (int32_t i = 0; i < MAX_PACKAGES; ++i) {
        char *digest = field(requirements, "packages", i, "digest", false);
        if (!digest || !*digest) { free(digest); break; }
        Archive archive = {0};
        char error[256] = {0};
        if (archive_restore(host, digest, &archive, error)) {
            const MCPluginZipBytes manifest = archive.zip.manifest;
            char *json = copy_text(manifest.bytes, manifest.size);
            char *id = field(requirements, "packages", i, "pluginId", false);
            if (json) {
                if (i) append(&out, ",");
                append(&out, "{\"digest\":");
                quote(&out, digest);
                append(&out, ",\"manifest\":");
                quote(&out, json);
                append(&out, "}");
                update_icon(host, id, &archive.zip);
            } else valid = false;
            free(id);
            free(json);
        } else {
            notify(host, *error ? error : "Cannot restore an installed plugin.", true);
            valid = false;
        }
        mc_plugin_zip_clear(&archive.zip);
        free(digest);
        if (!valid) break;
    }
    append(&out, "]}");
    free(requirements);
    if (valid && !out.failed) return out.text;
    free(out.text);
    return NULL;
}

MCDesktopPlugins *mc_desktop_plugins_open_with_platform(const char *root, const char *worker,
    const char *layout, int32_t capabilities, const MCDesktopPluginHooks *hooks,
    const MCDesktopPluginPlatform *platform) {
    if (!root || !worker || !layout || !hooks || !hooks->preflight || !hooks->publish ||
        !hooks->discard || !platform || !platform->read_zip || !platform->sha256 || !platform->inflate)
        return NULL;
    MCDesktopPlugins *host = calloc(1, sizeof(*host));
    if (!host) return NULL;
    host->hooks = *hooks;
    host->platform = *platform;
    host->capabilities = capabilities | MC_TOOL_CAP_USER;
    host->root = copy_text(root, strlen(root));
    host->worker = copy_text(worker, strlen(worker));
    if (!host->root || !host->worker) { free_host(host); return NULL; }

    MCPluginStoreBytes bytes = {0};
    MCPluginStoreError error;
    MCPluginStoreStatus status = mc_plugin_store_read_snapshot(root, &bytes, &error);
    char *index = status == MC_PLUGIN_STORE_MISSING ? copy_text("", 0) :
        status == MC_PLUGIN_STORE_OK && bytes.size && !memchr(bytes.bytes, 0, bytes.size) ?
            copy_text(bytes.bytes, bytes.size) : NULL;
    mc_plugin_store_bytes_free(&bytes);
    if (!index) {
        notify(host, *error.message ? error.message : "The plugin settings index is invalid.", true);
        free_host(host);
        return NULL;
    }

    char *archives = load_archives(host, index);
    if (archives) {
        moonbit_string_t saved = moon_text(index), list = moon_text(archives), seed = moon_text(layout);
        char *opened = saved && list && seed ? take_text(plugin_application_open(saved, list, seed)) : NULL;
        if (saved) moonbit_decref(saved);
        if (list) moonbit_decref(list);
        if (seed) moonbit_decref(seed);
        if (flag(opened, "ok")) host->application = number(opened, "application", -1);
        else reply_error(host, opened);
        free(opened);
    }
    free(index);
    free(archives);

    if (host->application) {
        char *registry = command(host, "{\"op\":\"registry\"}");
        int32_t snapshot = flag(registry, "ok") ? open_snapshot(host, registry) : 0;
        if (snapshot && host->hooks.preflight(host->hooks.context, snapshot, registry)) {
            host->hooks.publish(host->hooks.context, snapshot, registry);
            free(registry);
            return host;
        }
        host->hooks.discard(host->hooks.context);
        if (snapshot) tool_registry_snapshot_close(snapshot);
        free(registry);
        plugin_application_close(host->application);
    }
    free_host(host);
    return NULL;
}
