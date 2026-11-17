#include "platform/shared/media/media_worker.h"
#include "platform/shared/media/mp4_mux.h"
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <io.h>
#else
#include <unistd.h>
#endif

typedef struct {
    MCMediaRequest request;
    MCGstPlan *plan;
    char *path;
} Request;

struct MCMediaWorker {
    GAsyncQueue *requests, *completions;
    GMutex mutex;
    GHashTable *outstanding, *cancelled;
    char *source;
    bool silent, accepting;
    gint close_requested;
    uint64_t wanted_generation, wanted_seek;
    MCMediaState state;
    MCMediaFrame frame;
};

typedef struct {
    MCMediaWorker *owner;
    MCGstEngine *preview, *render;
    Request *export_request;
    char *staging, *raw, *final;
    bool staging_created;
    MCMediaState state;
    char initialization_error[1024];
    bool initialized;
} Worker;

/* GES requires every call on its initialization thread. This process-lifetime
 * executor owns all GES objects; individual editor handles retain independent
 * queues, plans, media and mailboxes. Decoder/encoder streaming threads remain
 * managed internally by GStreamer. No UI/default context is ever dispatched. */
typedef struct {
    GThread *thread;
    GMainContext *context;
    GAsyncQueue *registrations;
} Service;
static Service *service;
static gsize service_initialized;
static char service_error[1024];

static void error_text(char *out, size_t capacity, const char *message) {
    if (!out || !capacity) return;
    char *valid = g_utf8_make_valid(message ? message : "Media operation failed", -1);
    g_strlcpy(out, valid, capacity);
    const char *end = NULL;
    if (!g_utf8_validate(out, -1, &end)) out[end - out] = '\0';
    g_free(valid);
}

static bool reject(char *out, size_t capacity, const char *message) {
    error_text(out, capacity, message); return false;
}

static bool path_valid(const char *path) {
    return path && path[0] && strlen(path) <= 131072 && g_utf8_validate(path, -1, NULL) && g_path_is_absolute(path);
}

static void request_free(Request *request) {
    if (!request) return;
    g_free(request->plan); g_free(request->path); g_free(request);
}

static void frame_drop(MCMediaWorker *worker) {
    mc_gst_frame_clear(&worker->frame.image);
    memset(&worker->frame, 0, sizeof worker->frame);
}

static void publish_state(Worker *worker) {
    g_mutex_lock(&worker->owner->mutex);
    worker->owner->state = worker->state;
    g_mutex_unlock(&worker->owner->mutex);
}

static void completion(Worker *worker, Request *request, int status, const char *message,
                       const MCGstMetadata *metadata) {
    MCMediaCompletion *result = g_new0(MCMediaCompletion, 1);
    result->kind = request->request.kind; result->token = request->request.token;
    result->generation = request->request.generation; result->status = status;
    if (metadata) result->metadata = *metadata;
    if (status == MC_MEDIA_FAILED) error_text(result->error, sizeof result->error, message);
    g_async_queue_push(worker->owner->completions, result);
    request_free(request);
}

static void media_error(Worker *worker, const char *message) {
    error_text(worker->state.error, sizeof worker->state.error, message);
    worker->state.error_serial++;
}

static bool cancelled(Worker *worker, uint64_t token) {
    if (g_atomic_int_get(&worker->owner->close_requested)) return true;
    g_mutex_lock(&worker->owner->mutex);
    bool value = g_hash_table_contains(worker->owner->cancelled, &token);
    g_mutex_unlock(&worker->owner->mutex);
    return value;
}

static bool export_cancelled(void *context) {
    Worker *worker = context;
    return worker->export_request && cancelled(worker, worker->export_request->request.token);
}

static void publish_frame(Worker *worker) {
    if (!worker->preview || !worker->state.media_ready) return;
    MCGstFrame image = {0};
    if (!mc_gst_engine_frame(worker->preview, &image)) return;
    g_mutex_lock(&worker->owner->mutex);
    if (worker->owner->wanted_generation == worker->state.plan_generation &&
        worker->owner->wanted_seek == worker->state.completed_seek_token &&
        !g_atomic_int_get(&worker->owner->close_requested)) {
        frame_drop(worker->owner);
        worker->owner->frame.image = image;
        worker->owner->frame.plan_generation = worker->state.plan_generation;
        worker->owner->frame.seek_token = worker->state.completed_seek_token;
        memset(&image, 0, sizeof image);
    }
    g_mutex_unlock(&worker->owner->mutex);
    mc_gst_frame_clear(&image);
}

/* Both queries follow symlinks. A dangling/unsupported existing destination is
 * refused rather than guessed safe. Local file IDs include device/inode (or
 * the platform equivalent), catching hard links as well as different paths. */
static bool destination_safe(const char *source_path, const char *destination_path,
                             char *error, size_t capacity) {
    GFile *source = g_file_new_for_path(source_path), *destination = g_file_new_for_path(destination_path);
    GError *failure = NULL;
    bool safe = false;
    if (g_file_equal(source, destination)) { error_text(error, capacity, "Export cannot replace the original recording"); goto done; }
    GFileInfo *src = g_file_query_info(source, G_FILE_ATTRIBUTE_ID_FILE "," G_FILE_ATTRIBUTE_STANDARD_TYPE,
        G_FILE_QUERY_INFO_NONE, NULL, &failure);
    if (!src) { error_text(error, capacity, failure->message); g_clear_error(&failure); goto done; }
    if (g_file_info_get_file_type(src) != G_FILE_TYPE_REGULAR) {
        error_text(error, capacity, "Original recording is not a regular file"); g_object_unref(src); goto done;
    }
    GFileInfo *dst = g_file_query_info(destination, G_FILE_ATTRIBUTE_ID_FILE "," G_FILE_ATTRIBUTE_STANDARD_TYPE,
        G_FILE_QUERY_INFO_NONE, NULL, &failure);
    if (!dst) {
        if (g_error_matches(failure, G_IO_ERROR, G_IO_ERROR_NOT_FOUND)) {
            g_clear_error(&failure);
            GFileInfo *link = g_file_query_info(destination, G_FILE_ATTRIBUTE_STANDARD_TYPE,
                G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL, &failure);
            safe = !link && g_error_matches(failure, G_IO_ERROR, G_IO_ERROR_NOT_FOUND);
            if (link) g_object_unref(link);
            if (!safe) error_text(error, capacity, "Cannot safely replace this destination");
        } else error_text(error, capacity, failure ? failure->message : "Cannot inspect export destination");
        g_clear_error(&failure); g_object_unref(src); goto done;
    }
    const char *source_id = g_file_info_get_attribute_string(src, G_FILE_ATTRIBUTE_ID_FILE);
    const char *destination_id = g_file_info_get_attribute_string(dst, G_FILE_ATTRIBUTE_ID_FILE);
    safe = source_id && destination_id && strcmp(source_id, destination_id) != 0 &&
        g_file_info_get_file_type(dst) == G_FILE_TYPE_REGULAR;
    if (!safe) error_text(error, capacity, "Destination aliases the original recording or its identity is unknown");
    g_object_unref(src); g_object_unref(dst);
done:
    g_object_unref(source); g_object_unref(destination); return safe;
}

static bool atomic_publish(const char *path, const char *destination, char *error, size_t capacity) {
#ifdef _WIN32
    gunichar2 *from = g_utf8_to_utf16(path, -1, NULL, NULL, NULL);
    gunichar2 *to = g_utf8_to_utf16(destination, -1, NULL, NULL, NULL);
    bool success = from && to && MoveFileExW((const wchar_t *)from, (const wchar_t *)to,
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    if (!success) {
        char *message = g_win32_error_message(GetLastError()); error_text(error, capacity, message); g_free(message);
    }
    g_free(from); g_free(to); return success;
#else
    if (g_rename(path, destination) == 0) return true;
    return reject(error, capacity, g_strerror(errno));
#endif
}

static bool sync_file(const char *path, char *error, size_t capacity) {
    int fd = g_open(path, O_RDWR, 0);
    if (fd < 0) return reject(error, capacity, g_strerror(errno));
#ifdef _WIN32
    int result = _commit(fd), saved = errno;
    _close(fd);
#else
    int result = fsync(fd), saved = errno;
    close(fd);
#endif
    return result == 0 || reject(error, capacity, g_strerror(saved));
}

static void clean_export(Worker *worker) {
    mc_gst_engine_free(worker->render); worker->render = NULL;
    if (worker->raw) g_unlink(worker->raw);
    if (worker->final) g_unlink(worker->final);
    if (worker->staging_created) g_rmdir(worker->staging);
    worker->staging_created = false;
    g_clear_pointer(&worker->raw, g_free); g_clear_pointer(&worker->final, g_free);
    g_clear_pointer(&worker->staging, g_free);
}

static void export_complete(Worker *worker, int status, const char *error) {
    Request *request = worker->export_request;
    clean_export(worker);
    worker->export_request = NULL; worker->state.export_token = 0;
    if (status == MC_MEDIA_OK) worker->state.export_progress = 1;
    publish_state(worker);
    completion(worker, request, status, error, NULL);
}

static void finalize_export(Worker *worker) {
    char error[1024] = {0};
    Request *request = worker->export_request;
    int priming = mc_gst_engine_aac_priming(worker->render);
    mc_gst_engine_free(worker->render); worker->render = NULL;
    if (export_cancelled(worker)) { export_complete(worker, MC_MEDIA_CANCELLED, ""); return; }
    const char *candidate = worker->raw;
    if (request->request.flag) {
        if (!mc_mp4_mux_copy(worker->raw, worker->final, priming, export_cancelled, worker, error, sizeof error)) {
            export_complete(worker, export_cancelled(worker) ? MC_MEDIA_CANCELLED : MC_MEDIA_FAILED, error); return;
        }
        candidate = worker->final;
    }
    MCGstMetadata metadata = {0};
    bool valid = mc_gst_media_probe(candidate, &metadata, error, sizeof error);
    const MCGstPlan *plan = request->plan;
    if (valid) valid = metadata.width == plan->crop_width && metadata.height == plan->crop_height &&
        fabs(metadata.duration_ms - (double)plan->duration / 90.0) <= 100 &&
        (!plan->audio_count || metadata.has_audio);
    if (!valid) {
        export_complete(worker, MC_MEDIA_FAILED, error[0] ? error : "Exported media does not match its plan"); return;
    }
    if (export_cancelled(worker)) { export_complete(worker, MC_MEDIA_CANCELLED, ""); return; }
    if (!sync_file(candidate, error, sizeof error) ||
        !destination_safe(worker->owner->source, request->path, error, sizeof error)) {
        export_complete(worker, MC_MEDIA_FAILED, error); return;
    }
    if (export_cancelled(worker)) { export_complete(worker, MC_MEDIA_CANCELLED, ""); return; }
    // Atomic rename is the publication commit point. Cancellation racing after
    // it does not delete a successfully published output or its old destination.
    if (!atomic_publish(candidate, request->path, error, sizeof error)) {
        export_complete(worker, MC_MEDIA_FAILED, error); return;
    }
    export_complete(worker, MC_MEDIA_OK, "");
}

static void start_export(Worker *worker, Request *request) {
    char error[1024] = {0};
    if (worker->export_request) { completion(worker, request, MC_MEDIA_FAILED, "An export is already running", NULL); return; }
    if (cancelled(worker, request->request.token)) { completion(worker, request, MC_MEDIA_CANCELLED, "", NULL); return; }
    worker->export_request = request;
    worker->state.export_token = request->request.token; worker->state.export_progress = 0;
    if (!destination_safe(worker->owner->source, request->path, error, sizeof error)) {
        export_complete(worker, MC_MEDIA_FAILED, error); return;
    }
    char *parent = g_path_get_dirname(request->path);
    worker->staging = g_build_filename(parent, ".moojicut-export-XXXXXX", NULL); g_free(parent);
    if (!g_mkdtemp_full(worker->staging, 0700)) {
        export_complete(worker, MC_MEDIA_FAILED, g_strerror(errno)); return;
    }
    worker->staging_created = true;
    worker->raw = g_build_filename(worker->staging, request->request.flag ? "encoded.mp4" : "encoded.mkv", NULL);
    worker->final = g_build_filename(worker->staging, "final.mp4", NULL);
    worker->render = mc_gst_engine_new(worker->owner->source, request->plan, error, sizeof error);
    if (!worker->render || !mc_gst_engine_render(worker->render, worker->raw, request->request.flag, error, sizeof error)) {
        export_complete(worker, export_cancelled(worker) ? MC_MEDIA_CANCELLED : MC_MEDIA_FAILED, error); return;
    }
    publish_state(worker);
}

static void execute(Worker *worker, Request *request) {
    MCMediaRequest *r = &request->request;
    char error[1024] = {0};
    bool success = false;
    if (r->kind == MC_MEDIA_CANCEL_EXPORT) {
        if (worker->export_request && worker->export_request->request.token == r->target)
            export_complete(worker, MC_MEDIA_CANCELLED, "");
        completion(worker, request, MC_MEDIA_OK, "", NULL); return;
    }
    if (!worker->initialized) {
        completion(worker, request, MC_MEDIA_FAILED, worker->initialization_error, NULL); return;
    }
    if (r->kind == MC_MEDIA_PROBE) {
        MCGstMetadata metadata = {0};
        success = mc_gst_media_probe(worker->owner->source, &metadata, error, sizeof error);
        if (success) worker->state.metadata = metadata;
        publish_state(worker);
        completion(worker, request, g_atomic_int_get(&worker->owner->close_requested) ? MC_MEDIA_CANCELLED :
            success ? MC_MEDIA_OK : MC_MEDIA_FAILED, error, success ? &metadata : NULL); return;
    }
    if (r->kind == MC_MEDIA_EXPORT) { start_export(worker, request); return; }
    if (r->kind == MC_MEDIA_APPLY) {
        MCGstEngine *next = mc_gst_engine_new(worker->owner->source, request->plan, error, sizeof error);
        success = next && mc_gst_engine_preview(next, worker->owner->silent, error, sizeof error);
        if (success && worker->state.rate != 1)
            success = mc_gst_engine_seek(next, 0, worker->state.rate, false, error, sizeof error);
        if (success && !g_atomic_int_get(&worker->owner->close_requested)) {
            mc_gst_engine_free(worker->preview); worker->preview = next; next = NULL;
            worker->state.media_ready = true; worker->state.playing = false;
            worker->state.plan_generation = r->generation; worker->state.completed_seek_token = 0;
            worker->state.position_ms = 0;
        }
        mc_gst_engine_free(next);
    } else if (r->generation != worker->state.plan_generation) {
        completion(worker, request, MC_MEDIA_CANCELLED, "", NULL); return;
    } else if (!worker->preview || !worker->state.media_ready) {
        error_text(error, sizeof error, "Preview generation is unavailable");
    } else if (r->kind == MC_MEDIA_SEEK || r->kind == MC_MEDIA_RATE) {
        double rate = r->kind == MC_MEDIA_RATE ? r->number : worker->state.rate;
        double position = r->kind == MC_MEDIA_SEEK ? r->number : mc_gst_engine_position(worker->preview);
        if (position < 0) position = worker->state.position_ms;
        success = mc_gst_engine_seek(worker->preview, position, rate, worker->state.playing, error, sizeof error);
        if (success) {
            worker->state.rate = rate;
            worker->state.position_ms = mc_gst_engine_position(worker->preview);
            if (r->kind == MC_MEDIA_SEEK) worker->state.completed_seek_token = r->token;
        }
    } else if (r->kind == MC_MEDIA_PLAY) {
        success = mc_gst_engine_play(worker->preview, r->flag, error, sizeof error);
        if (success) worker->state.playing = r->flag;
    }
    if (!success) {
        media_error(worker, error);
        if (r->kind != MC_MEDIA_APPLY) {
            worker->state.media_ready = false; worker->state.playing = false;
            g_mutex_lock(&worker->owner->mutex); frame_drop(worker->owner); g_mutex_unlock(&worker->owner->mutex);
        }
    }
    publish_state(worker);
    completion(worker, request, g_atomic_int_get(&worker->owner->close_requested) ? MC_MEDIA_CANCELLED :
        success ? MC_MEDIA_OK : MC_MEDIA_FAILED, error, NULL);
}

static void tick(Worker *worker) {
    char error[1024] = {0};
    if (worker->preview && worker->state.media_ready) {
        int result = mc_gst_engine_poll(worker->preview, error, sizeof error);
        if (result == MC_GST_ERROR) {
            worker->state.media_ready = false; worker->state.playing = false; media_error(worker, error);
        } else {
            if (result == MC_GST_EOS) worker->state.playing = false;
            double position = mc_gst_engine_position(worker->preview);
            if (position >= 0) worker->state.position_ms = position;
            publish_frame(worker);
        }
    }
    if (worker->export_request) {
        if (export_cancelled(worker)) { export_complete(worker, MC_MEDIA_CANCELLED, ""); }
        else {
            int result = mc_gst_engine_poll(worker->render, error, sizeof error);
            if (result == MC_GST_EOS) finalize_export(worker);
            else if (result == MC_GST_ERROR) export_complete(worker, MC_MEDIA_FAILED, error);
            else {
                double position = mc_gst_engine_position(worker->render);
                if (position >= 0) worker->state.export_progress = CLAMP(position * 90.0 /
                    (double)worker->export_request->plan->duration, 0.0, 0.99);
            }
        }
    }
    publish_state(worker);
}

static void close_worker(Worker *worker, Request *close_request) {
    if (worker->export_request) export_complete(worker, MC_MEDIA_CANCELLED, "");
    mc_gst_engine_free(worker->preview); worker->preview = NULL;
    Request *request;
    while ((request = g_async_queue_try_pop(worker->owner->requests))) {
        if (request->request.kind == MC_MEDIA_CLOSE) close_request = request;
        else completion(worker, request, MC_MEDIA_CANCELLED, "", NULL);
    }
    worker->state.closed = true; worker->state.media_ready = false; worker->state.playing = false;
    MCMediaWorker *owner = worker->owner;
    // Publishing closed and its completion is one memory transaction. After
    // unlocking, the executor no longer touches owner; free needs no global
    // thread join and cannot race another editor's playback.
    g_mutex_lock(&owner->mutex);
    frame_drop(owner); owner->state = worker->state;
    if (close_request) completion(worker, close_request, MC_MEDIA_OK, "", NULL);
    g_mutex_unlock(&owner->mutex);
    g_free(worker);
}

static gboolean service_timer(gpointer unused) {
    (void)unused; return G_SOURCE_CONTINUE;
}

static gpointer service_main(gpointer context) {
    Service *executor = context;
    g_main_context_push_thread_default(executor->context);
    char initialization_error[1024] = {0};
    bool initialized = mc_gst_media_init(initialization_error, sizeof initialization_error);
    GPtrArray *workers = g_ptr_array_new();
    GSource *timer = NULL;
    for (;;) {
        MCMediaWorker *owner;
        while ((owner = g_async_queue_try_pop(executor->registrations))) {
            Worker *worker = g_new0(Worker, 1); worker->owner = owner; worker->state.rate = 1;
            worker->initialized = initialized;
            error_text(worker->initialization_error, sizeof worker->initialization_error, initialization_error);
            if (!initialized) media_error(worker, initialization_error);
            g_ptr_array_add(workers, worker);
        }
        // One request per live editor per round: a busy scrubber cannot drain
        // its entire queue ahead of another editor's accepted close or seek.
        for (guint index = 0; index < workers->len;) {
            Worker *worker = g_ptr_array_index(workers, index);
            if (g_atomic_int_get(&worker->owner->close_requested)) {
                g_ptr_array_remove_index(workers, index); close_worker(worker, NULL); continue;
            }
            Request *request = g_async_queue_try_pop(worker->owner->requests);
            if (request && request->request.kind == MC_MEDIA_CLOSE) {
                g_ptr_array_remove_index(workers, index); close_worker(worker, request); continue;
            }
            if (request) execute(worker, request);
            tick(worker); index++;
        }
        for (int i = 0; i < 64 && g_main_context_pending(executor->context); i++)
            g_main_context_iteration(executor->context, FALSE);
        if (workers->len && !timer) {
            timer = g_timeout_source_new(10); g_source_set_callback(timer, service_timer, NULL, NULL);
            g_source_attach(timer, executor->context);
        } else if (!workers->len && timer) {
            g_source_destroy(timer); g_source_unref(timer); timer = NULL;
        }
        bool pending = g_async_queue_length(executor->registrations) > 0;
        for (guint index = 0; !pending && index < workers->len; index++) {
            Worker *worker = g_ptr_array_index(workers, index);
            pending = g_async_queue_length(worker->owner->requests) > 0;
        }
        // With no sessions there is no periodic source: this sleeps until a
        // registration wakes the context or GES finishes its own cache cleanup.
        if (!pending) g_main_context_iteration(executor->context, TRUE);
    }
}

static bool ensure_service(char *error, size_t capacity) {
    if (g_once_init_enter(&service_initialized)) {
        Service *executor = g_new0(Service, 1);
        executor->context = g_main_context_new(); executor->registrations = g_async_queue_new();
        GError *failure = NULL;
        executor->thread = g_thread_try_new("moojicut-media", service_main, executor, &failure);
        if (executor->thread) {
            service = executor;
        } else {
            error_text(service_error, sizeof service_error, failure ? failure->message : "Cannot start media executor");
            g_clear_error(&failure); g_main_context_unref(executor->context);
            g_async_queue_unref(executor->registrations); g_free(executor);
        }
        g_once_init_leave(&service_initialized, service ? 1 : 2);
    }
    return service != NULL || reject(error, capacity, service_error);
}

MCMediaWorker *mc_media_worker_create(const char *source_path, bool silent, char *error, size_t capacity) {
    if (error && capacity) error[0] = '\0';
    if (!path_valid(source_path)) { reject(error, capacity, "Expected an absolute local UTF-8 source path"); return NULL; }
    if (!ensure_service(error, capacity)) return NULL;
    MCMediaWorker *worker = g_new0(MCMediaWorker, 1);
    worker->source = g_strdup(source_path); worker->silent = silent; worker->accepting = true; worker->state.rate = 1;
    g_mutex_init(&worker->mutex);
    worker->requests = g_async_queue_new(); worker->completions = g_async_queue_new();
    worker->outstanding = g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free, NULL);
    worker->cancelled = g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free, NULL);
    g_async_queue_push(service->registrations, worker); g_main_context_wakeup(service->context);
    return worker;
}

bool mc_media_worker_submit(MCMediaWorker *worker, const MCMediaRequest *input, char *error, size_t capacity) {
    if (error && capacity) error[0] = '\0';
    if (!worker || !input || input->kind < MC_MEDIA_PROBE || input->kind > MC_MEDIA_CLOSE || !input->token ||
        !input->generation || ((input->kind == MC_MEDIA_APPLY || input->kind == MC_MEDIA_EXPORT) && !input->plan) ||
        (input->kind == MC_MEDIA_EXPORT && !path_valid(input->path)) ||
        (input->kind == MC_MEDIA_SEEK && (!isfinite(input->number) || input->number < 0 || input->number > 604800000)) ||
        (input->kind == MC_MEDIA_RATE && (!isfinite(input->number) || input->number < 0.25 || input->number > 4)))
        return reject(error, capacity, "Invalid media request");
    g_mutex_lock(&worker->mutex);
    size_t count = g_hash_table_size(worker->outstanding);
    bool stale_preview = input->kind == MC_MEDIA_APPLY ? input->generation < worker->wanted_generation :
        (input->kind == MC_MEDIA_SEEK || input->kind == MC_MEDIA_PLAY || input->kind == MC_MEDIA_RATE) &&
        input->generation != worker->wanted_generation;
    if (!worker->accepting || g_hash_table_contains(worker->outstanding, &input->token) ||
        stale_preview ||
        (input->kind != MC_MEDIA_CLOSE && count >= (input->kind == MC_MEDIA_CANCEL_EXPORT ? 65u : 64u)) ||
        (input->kind == MC_MEDIA_CANCEL_EXPORT && GPOINTER_TO_INT(g_hash_table_lookup(worker->outstanding, &input->target)) != MC_MEDIA_EXPORT)) {
        g_mutex_unlock(&worker->mutex); return reject(error, capacity, "Media worker closed, full, or request token unavailable");
    }
    Request *request = g_new0(Request, 1); request->request = *input;
    if (input->kind == MC_MEDIA_APPLY || input->kind == MC_MEDIA_EXPORT) {
        request->plan = g_memdup2(input->plan, sizeof *input->plan); request->request.plan = request->plan;
    }
    if (input->kind == MC_MEDIA_EXPORT) { request->path = g_strdup(input->path); request->request.path = request->path; }
    uint64_t *token = g_new(uint64_t, 1); *token = input->token;
    g_hash_table_insert(worker->outstanding, token, GINT_TO_POINTER(input->kind));
    if (input->kind == MC_MEDIA_CANCEL_EXPORT) {
        uint64_t *target = g_new(uint64_t, 1); *target = input->target; g_hash_table_add(worker->cancelled, target);
    }
    if (input->kind == MC_MEDIA_APPLY) { worker->wanted_generation = input->generation; worker->wanted_seek = 0; frame_drop(worker); }
    if (input->kind == MC_MEDIA_SEEK) { worker->wanted_generation = input->generation; worker->wanted_seek = input->token; frame_drop(worker); }
    // Push before publishing close: the worker can then drain the accepted
    // CLOSE request without racing an empty queue and losing its completion.
    g_async_queue_push(worker->requests, request);
    if (input->kind == MC_MEDIA_CLOSE) { worker->accepting = false; g_atomic_int_set(&worker->close_requested, 1); }
    g_mutex_unlock(&worker->mutex);
    g_main_context_wakeup(service->context);
    return true;
}

bool mc_media_worker_poll(MCMediaWorker *worker, MCMediaCompletion *out) {
    if (!worker || !out) return false;
    MCMediaCompletion *completion = g_async_queue_try_pop(worker->completions);
    if (!completion) return false;
    *out = *completion;
    g_mutex_lock(&worker->mutex);
    g_hash_table_remove(worker->outstanding, &out->token); g_hash_table_remove(worker->cancelled, &out->token);
    g_mutex_unlock(&worker->mutex);
    g_free(completion); return true;
}

bool mc_media_worker_snapshot(MCMediaWorker *worker, MCMediaState *state) {
    if (!worker || !state) return false;
    g_mutex_lock(&worker->mutex); *state = worker->state; g_mutex_unlock(&worker->mutex); return true;
}

bool mc_media_worker_take_frame(MCMediaWorker *worker, MCMediaFrame *frame) {
    if (!worker || !frame || frame->image.pixels) return false;
    g_mutex_lock(&worker->mutex);
    bool fresh = worker->frame.image.pixels != NULL;
    if (fresh) { *frame = worker->frame; memset(&worker->frame, 0, sizeof worker->frame); }
    g_mutex_unlock(&worker->mutex); return fresh;
}

void mc_media_frame_clear(MCMediaFrame *frame) {
    if (!frame) return;
    mc_gst_frame_clear(&frame->image); memset(frame, 0, sizeof *frame);
}

bool mc_media_worker_free(MCMediaWorker *worker) {
    if (!worker) return true;
    g_mutex_lock(&worker->mutex); bool closed = worker->state.closed; g_mutex_unlock(&worker->mutex);
    if (!closed) return false;
    Request *request; while ((request = g_async_queue_try_pop(worker->requests))) request_free(request);
    gpointer completion; while ((completion = g_async_queue_try_pop(worker->completions))) g_free(completion);
    g_async_queue_unref(worker->requests); g_async_queue_unref(worker->completions);
    g_hash_table_unref(worker->outstanding); g_hash_table_unref(worker->cancelled);
    frame_drop(worker); g_mutex_clear(&worker->mutex); g_free(worker->source); g_free(worker); return true;
}
