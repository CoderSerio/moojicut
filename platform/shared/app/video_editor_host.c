#include "platform/shared/app/video_editor_host.h"
#include "bindings/c/video_media_plan.h"
#include "platform/shared/media/waveform.h"
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <string.h>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif

#define DRAFT_LIMIT (4u * 1024u * 1024u)
#define AUX_TOKEN (UINT64_C(1) << 63)

typedef struct {
    GAsyncQueue *queue;
    GThread *thread;
    char *source, *path, *legacy, *bytes, *etag;
    bool save, existed, success, fallback;
    int32_t ticket;
    char error[1024];
} DraftJob;

struct MCVideoEditorHost {
    char *source, *draft, *legacy, *etag;
    char error[1024];
    MCMediaWorker *worker;
    MCWaveformAnalysis *waveform;
    GAsyncQueue *io;
    unsigned jobs;
    int32_t editor, chooser, close_ticket;
    int phase;
    bool draft_exists, draft_done, probe_done, probe_ok, closing, fallback;
    char *draft_bytes;
    MCGstMetadata metadata;
    uint64_t aux_serial, probe_token, wanted_generation, wanted_seek, error_serial;
    uint64_t presentation_serial, clock_generation, progress_ticket;
    double clock_position, progress;
    bool clock_delivered, clock_playing;
    MCMediaFrame frame;
};

static void presentation_changed(MCVideoEditorHost *host) {
    if (host->presentation_serial != UINT64_MAX) host->presentation_serial++;
}

static void error_text(char *out, size_t capacity, const char *message) {
    if (!out || !capacity) return;
    char *valid = g_utf8_make_valid(message ? message : "Editor operation failed", -1);
    g_strlcpy(out, valid, capacity);
    const char *end = NULL;
    if (!g_utf8_validate(out, -1, &end)) out[end - out] = 0;
    g_free(valid);
}

static bool path_valid(const char *path) {
    return path && *path && strlen(path) <= 131072 &&
        g_utf8_validate(path, -1, NULL) && g_path_is_absolute(path);
}

static moonbit_string_t mb_string(const char *text) {
    glong length = 0;
    gunichar2 *utf16 = g_utf8_to_utf16(text ? text : "", -1, NULL, &length, NULL);
    if (!utf16 || length > INT32_MAX) { g_free(utf16); return moonbit_make_string_raw(0); }
    moonbit_string_t result = moonbit_make_string_raw((int32_t)length);
    if (length) memcpy(result, utf16, (size_t)length * sizeof *utf16);
    g_free(utf16);
    return result;
}

static char *take_string(moonbit_string_t text) {
    char *result = g_utf16_to_utf8((const gunichar2 *)text, Moonbit_array_length(text), NULL, NULL, NULL);
    moonbit_decref(text);
    return result ? result : g_strdup("");
}

/* Filesystem identity is intentionally checked here, not in the document model.
 * Refuse symlink draft destinations (including dangling links) and source hard
 * links before reading or replacing anything. Existing corrupt bytes are never
 * silently treated as an absent draft. */
static bool inspect_draft(DraftJob *job, GFile *file, bool *exists, char **etag) {
    GError *failure = NULL;
    GFile *source = g_file_new_for_path(job->source);
    GFileInfo *src = NULL, *dst = NULL;
    bool ok = false;
    *exists = false;
    *etag = NULL;
    if (g_file_equal(source, file)) {
        error_text(job->error, sizeof job->error, "草稿不能覆盖原始录制文件");
        goto done;
    }
    src = g_file_query_info(source, G_FILE_ATTRIBUTE_ID_FILE "," G_FILE_ATTRIBUTE_STANDARD_TYPE,
                            G_FILE_QUERY_INFO_NONE, NULL, &failure);
    if (!src) goto failed;
    const char *source_id = g_file_info_get_attribute_string(src, G_FILE_ATTRIBUTE_ID_FILE);
    if (!source_id || g_file_info_get_file_type(src) != G_FILE_TYPE_REGULAR) {
        error_text(job->error, sizeof job->error, "无法确认原片的文件身份");
        goto done;
    }
    dst = g_file_query_info(file, G_FILE_ATTRIBUTE_ID_FILE "," G_FILE_ATTRIBUTE_STANDARD_TYPE ","
                            G_FILE_ATTRIBUTE_ETAG_VALUE "," G_FILE_ATTRIBUTE_STANDARD_SIZE,
                            G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL, &failure);
    if (!dst) {
        if (g_error_matches(failure, G_IO_ERROR, G_IO_ERROR_NOT_FOUND)) {
            g_clear_error(&failure);
            ok = true;
            goto done;
        }
        goto failed;
    }
    *exists = true;
    const char *draft_id = g_file_info_get_attribute_string(dst, G_FILE_ATTRIBUTE_ID_FILE);
    const char *tag = g_file_info_get_etag(dst);
    if (g_file_info_get_file_type(dst) != G_FILE_TYPE_REGULAR || !draft_id || !tag ||
        !strcmp(source_id, draft_id)) {
        error_text(job->error, sizeof job->error, "草稿必须是独立普通文件，不能是原片或符号链接");
        goto done;
    }
    if (!job->save && (g_file_info_get_size(dst) <= 0 || g_file_info_get_size(dst) > DRAFT_LIMIT)) {
        error_text(job->error, sizeof job->error, "现有草稿为空或过大，已保留原文件");
        goto done;
    }
    *etag = g_strdup(tag);
    ok = true;
    goto done;
failed:
    error_text(job->error, sizeof job->error, failure ? failure->message : "无法读取草稿状态");
done:
    g_clear_error(&failure);
    g_clear_object(&src);
    g_clear_object(&dst);
    g_object_unref(source);
    return ok;
}

static bool sync_path(const char *path, char *error, size_t capacity) {
    int descriptor = g_open(path, O_RDWR, 0);
    if (descriptor < 0) { error_text(error, capacity, g_strerror(errno)); return false; }
#ifdef _WIN32
    int result = _commit(descriptor);
    int saved_errno = errno;
    _close(descriptor);
#else
    int result = fsync(descriptor);
    int saved_errno = errno;
    close(descriptor);
#endif
    if (result) error_text(error, capacity, g_strerror(saved_errno));
    return result == 0;
}

static bool read_draft(DraftJob *job, GFile *file) {
    GError *failure = NULL;
    bool exists = false;
    char *etag = NULL;
    if (!inspect_draft(job, file, &exists, &etag)) return false;
    job->existed = exists;
    g_free(job->etag);
    job->etag = etag;
    if (!exists) { job->bytes = g_strdup(""); return true; }
    GFileInputStream *stream = g_file_read(file, NULL, &failure);
    if (!stream) goto failed;
    char *bytes = g_malloc(DRAFT_LIMIT + 1);
    gsize size = 0;
    bool ok = g_input_stream_read_all(G_INPUT_STREAM(stream), bytes, DRAFT_LIMIT + 1, &size, NULL, &failure);
    if (ok && (!size || size > DRAFT_LIMIT || memchr(bytes, 0, size) || !g_utf8_validate(bytes, (gssize)size, NULL))) {
        error_text(job->error, sizeof job->error, "现有草稿不是有效 UTF-8 文档，已保留原文件");
        ok = false;
    }
    if (ok) {
        /* Recheck the pathname after the read, so a concurrent external edit
         * cannot be blessed with an unrelated version token. */
        char *after = NULL;
        bool still_exists = false;
        ok = inspect_draft(job, file, &still_exists, &after) && still_exists && !g_strcmp0(after, job->etag);
        g_free(after);
        if (!ok && !*job->error) error_text(job->error, sizeof job->error, "读取时草稿发生变化，请重试");
    }
    g_input_stream_close(G_INPUT_STREAM(stream), NULL, NULL);
    g_object_unref(stream);
    if (ok) { bytes[size] = 0; job->bytes = bytes; return true; }
    g_free(bytes);
failed:
    if (failure) error_text(job->error, sizeof job->error, failure->message);
    g_clear_error(&failure);
    return false;
}

static bool save_draft(DraftJob *job, GFile *file) {
    GError *failure = NULL;
    bool exists = false;
    char *current = NULL, *new_etag = NULL;
    if (!inspect_draft(job, file, &exists, &current)) return false;
    bool unchanged = exists == job->existed && (!exists || !g_strcmp0(current, job->etag));
    g_free(current);
    if (!unchanged) { error_text(job->error, sizeof job->error, "草稿已被外部修改，未覆盖现有文件"); return false; }
    bool committed = false;
    if (exists) {
        /* GIO compares the expected etag while atomically replacing a local
         * file. REPLACE_DESTINATION never follows a newly substituted symlink. */
        committed = g_file_replace_contents(file, job->bytes, strlen(job->bytes), job->etag, FALSE,
            G_FILE_CREATE_PRIVATE | G_FILE_CREATE_REPLACE_DESTINATION, &new_etag, NULL, &failure);
    } else {
        /* Initial publication must not overwrite a file created after our
         * read. Same-directory, no-fallback move gives exclusive publication. */
        char *directory = g_path_get_dirname(job->path);
        char *temporary = g_build_filename(directory, ".moojicut-draft-XXXXXX", NULL);
        g_free(directory);
        int fd = g_mkstemp_full(temporary, O_RDWR, 0600);
        if (fd >= 0) {
#ifdef _WIN32
            _close(fd);
#else
            close(fd);
#endif
            GFile *staging = g_file_new_for_path(temporary);
            bool written = g_file_replace_contents(staging, job->bytes, strlen(job->bytes), NULL, FALSE,
                                                   G_FILE_CREATE_PRIVATE, NULL, NULL, &failure);
            if (written && sync_path(temporary, job->error, sizeof job->error)) {
                committed = g_file_move(staging, file, G_FILE_COPY_NO_FALLBACK_FOR_MOVE, NULL, NULL, NULL, &failure);
            }
            g_file_delete(staging, NULL, NULL); /* Only our unique staging file. */
            g_object_unref(staging);
        } else error_text(job->error, sizeof job->error, g_strerror(errno));
        g_free(temporary);
    }
    if (committed) {
        /* Even a post-publication sync failure retains the new version token,
         * allowing a real retry instead of mistaking our own write for a race. */
        g_free(job->etag);
        job->etag = new_etag;
        new_etag = NULL;
        job->existed = true;
        bool present = false;
        char *verified = NULL;
        bool inspected = inspect_draft(job, file, &present, &verified);
        if (inspected && present) { g_free(job->etag); job->etag = verified; }
        else g_free(verified);
        bool synced = sync_path(job->path, job->error, sizeof job->error);
        g_clear_error(&failure);
        return inspected && present && synced;
    }
    if (failure) error_text(job->error, sizeof job->error, failure->message);
    g_clear_error(&failure);
    g_free(new_etag);
    return false;
}

static gpointer draft_thread(gpointer data) {
    DraftJob *job = data;
    GFile *file = g_file_new_for_path(job->path);
    job->success = job->save ? save_draft(job, file) : read_draft(job, file);
    g_object_unref(file);
    if (!job->save && job->success && !job->existed && job->legacy) {
        g_clear_pointer(&job->bytes, g_free);
        file = g_file_new_for_path(job->legacy);
        job->success = read_draft(job, file);
        job->fallback = job->success && job->existed;
        /* The save destination remains absent even when the fallback exists. */
        job->existed = false;
        g_clear_pointer(&job->etag, g_free);
        g_object_unref(file);
    }
    g_async_queue_push(job->queue, job);
    return NULL;
}

static void job_free(DraftJob *job) {
    g_free(job->source); g_free(job->path); g_free(job->legacy); g_free(job->bytes); g_free(job->etag);
    g_free(job);
}

static void start_io(MCVideoEditorHost *host, bool save, int32_t ticket, char *bytes) {
    DraftJob *job = g_new0(DraftJob, 1);
    job->queue = host->io;
    job->source = g_strdup(host->source); job->path = g_strdup(host->draft);
    job->legacy = g_strdup(host->legacy);
    job->etag = g_strdup(host->etag); job->existed = host->draft_exists;
    job->save = save; job->ticket = ticket; job->bytes = bytes;
    GError *failure = NULL;
    host->jobs++;
    job->thread = g_thread_try_new("editor-draft", draft_thread, job, &failure);
    if (!job->thread) {
        error_text(job->error, sizeof job->error, failure ? failure->message : "无法启动草稿任务");
        g_clear_error(&failure);
        g_async_queue_push(host->io, job);
    }
}

static void ack(MCVideoEditorHost *host, int32_t ticket, int status, const char *message) {
    moonbit_string_t text = mb_string(message);
    if (video_editor_ack(host->editor, ticket, status, text)) {
        presentation_changed(host);
        host->clock_delivered = false;
    }
    moonbit_decref(text);
}

static void sync_intent(MCVideoEditorHost *host) {
    if (!host->editor) return;
    uint64_t generation = (uint64_t)video_editor_value(host->editor, MC_EDITOR_GENERATION);
    if (host->wanted_generation != generation) {
        host->wanted_generation = generation;
        host->wanted_seek = 0;
        mc_media_frame_clear(&host->frame);
    }
    int phase = video_editor_value(host->editor, MC_EDITOR_PHASE);
    int next_phase = phase == MC_EDITOR_CLOSED ? MC_VIDEO_HOST_CLOSED :
        phase == MC_EDITOR_CLOSING ? MC_VIDEO_HOST_CLOSING : MC_VIDEO_HOST_OPEN;
    if (host->phase != next_phase) presentation_changed(host);
    host->phase = next_phase;
    if (phase != MC_EDITOR_OPEN || !video_editor_value(host->editor, MC_EDITOR_MEDIA_READY))
        mc_media_frame_clear(&host->frame);
}

static bool integer(double value, int64_t *out) {
    if (!isfinite(value) || value < 0 || value > 9007199254740991.0 || floor(value) != value) return false;
    *out = (int64_t)value;
    return true;
}

static bool copy_plan(int32_t handle, MCGstPlan *plan) {
    memset(plan, 0, sizeof *plan);
    plan->width = video_media_plan_value(handle, MC_MEDIA_PLAN_WIDTH);
    plan->height = video_media_plan_value(handle, MC_MEDIA_PLAN_HEIGHT);
    int videos = video_media_plan_value(handle, MC_MEDIA_PLAN_VIDEO_COUNT);
    int audios = video_media_plan_value(handle, MC_MEDIA_PLAN_AUDIO_COUNT);
    if (plan->width <= 0 || plan->height <= 0 || videos < 0 || videos > MC_GST_MAX_CLIPS ||
        audios < 0 || audios > MC_GST_MAX_CLIPS) return false;
    plan->video_count = (size_t)videos; plan->audio_count = (size_t)audios;
    plan->quality = video_media_plan_value(handle, MC_MEDIA_PLAN_QUALITY) != 0;
    if (!integer(video_media_plan_number(handle, MC_MEDIA_PLAN_DURATION_TICKS), &plan->duration)) return false;
    int *crop[] = { &plan->crop_x, &plan->crop_y, &plan->crop_width, &plan->crop_height };
    for (int i = 0; i < 4; i++) {
        int64_t value = 0;
        if (!integer(video_media_plan_number(handle, MC_MEDIA_PLAN_CROP_X + i), &value) || value > INT32_MAX) return false;
        *crop[i] = (int)value;
    }
    for (int kind = 0; kind < 2; kind++) {
        size_t count = kind ? plan->audio_count : plan->video_count;
        MCGstClip *clips = kind ? plan->audio : plan->video;
        for (size_t i = 0; i < count; i++) {
            int64_t *values[] = { &clips[i].start, &clips[i].source_start, &clips[i].source_end, &clips[i].duration };
            for (int key = 0; key < 4; key++)
                if (!integer(video_media_plan_clip_number(handle, kind, (int32_t)i, key), values[key])) return false;
        }
    }
    return true;
}

static void execute_effects(MCVideoEditorHost *host) {
    if (!host->editor) return;
    sync_intent(host);
    /* The session queues bounded effect lanes. Avoid an unbounded synchronous
     * failure/retry loop if a future session adds auto-retry behavior. */
    for (int count = 0; count < 64; count++) {
        int32_t ticket = video_editor_take_effect(host->editor);
        if (!ticket) break;
        int kind = video_editor_effect_kind(host->editor, ticket);
        char *text = NULL;
        if (kind == MC_EDITOR_SAVE_DRAFT) {
            text = take_string(video_editor_effect_text(host->editor, ticket));
            start_io(host, true, ticket, text);
            continue;
        }
        if (kind == MC_EDITOR_CHOOSE_EXPORT) { host->chooser = ticket; continue; }
        MCMediaRequest request = {0};
        MCGstPlan plan;
        request.token = (uint64_t)ticket;
        request.generation = (uint64_t)video_editor_effect_generation(host->editor, ticket);
        request.number = video_editor_effect_number(host->editor, ticket);
        bool valid = true;
        switch (kind) {
        case MC_EDITOR_APPLY_PLAN: request.kind = MC_MEDIA_APPLY; break;
        case MC_EDITOR_SEEK: request.kind = MC_MEDIA_SEEK; break;
        case MC_EDITOR_PLAY: request.kind = MC_MEDIA_PLAY; request.flag = request.number != 0; break;
        case MC_EDITOR_PREVIEW_RATE: request.kind = MC_MEDIA_RATE; break;
        case MC_EDITOR_EXPORT:
            request.kind = MC_MEDIA_EXPORT; request.flag = true;
            text = take_string(video_editor_effect_text(host->editor, ticket)); request.path = text;
            break;
        case MC_EDITOR_CANCEL_EXPORT:
            request.kind = MC_MEDIA_CANCEL_EXPORT; request.target = (uint64_t)request.number; break;
        case MC_EDITOR_CLOSE_MEDIA:
            request.kind = MC_MEDIA_CLOSE;
            if (host->waveform) mc_waveform_cancel(host->waveform);
            break;
        default: valid = false; break;
        }
        if (kind == MC_EDITOR_APPLY_PLAN || kind == MC_EDITOR_EXPORT) {
            valid = copy_plan(video_editor_effect_plan(host->editor, ticket), &plan);
            request.plan = &plan;
        }
        char error[1024] = {0};
        if (valid && mc_media_worker_submit(host->worker, &request, error, sizeof error)) {
            if (kind == MC_EDITOR_SEEK || kind == MC_EDITOR_APPLY_PLAN) {
                host->wanted_generation = request.generation;
                host->wanted_seek = kind == MC_EDITOR_SEEK ? request.token : 0;
                mc_media_frame_clear(&host->frame);
            }
        } else ack(host, ticket, MC_EDITOR_ACK_FAILED, *error ? error : "无法复制或提交媒体计划");
        g_free(text);
    }
    sync_intent(host);
}

static bool start_probe(MCVideoEditorHost *host) {
    MCMediaRequest request = {0};
    request.kind = MC_MEDIA_PROBE;
    request.generation = 1;
    request.token = AUX_TOKEN | ++host->aux_serial;
    host->probe_token = request.token;
    host->probe_done = false; host->probe_ok = false; host->draft_done = false;
    g_clear_pointer(&host->draft_bytes, g_free);
    host->error[0] = 0;
    host->phase = MC_VIDEO_HOST_OPENING;
    presentation_changed(host);
    if (!mc_media_worker_submit(host->worker, &request, host->error, sizeof host->error)) {
        host->probe_done = true;
    }
    start_io(host, false, 0, NULL);
    return true;
}

MCVideoEditorHost *mc_video_editor_host_create(const char *source, const char *draft,
                                              bool silent, char *error, size_t capacity) {
    return mc_video_editor_host_create_with_legacy(source, draft, NULL, silent, error, capacity);
}

MCVideoEditorHost *mc_video_editor_host_create_with_legacy(const char *source, const char *draft,
    const char *legacy, bool silent, char *error, size_t capacity) {
    if (!path_valid(source) || !path_valid(draft) || (legacy && !path_valid(legacy))) {
        error_text(error, capacity, "原片与草稿必须使用本地绝对路径"); return NULL;
    }
    MCVideoEditorHost *host = g_new0(MCVideoEditorHost, 1);
    host->source = g_strdup(source); host->draft = g_strdup(draft);
    host->legacy = g_strdup(legacy);
    host->io = g_async_queue_new();
    host->worker = mc_media_worker_create(source, silent, error, capacity);
    if (!host->worker) {
        g_async_queue_unref(host->io); g_free(host->source); g_free(host->draft); g_free(host->legacy); g_free(host); return NULL;
    }
    start_probe(host);
    return host;
}

static void maybe_open(MCVideoEditorHost *host) {
    if (host->editor || host->closing || host->phase != MC_VIDEO_HOST_OPENING ||
        !host->probe_done || !host->draft_done) return;
    if (!host->probe_ok || !host->draft_bytes) {
        host->phase = MC_VIDEO_HOST_FAILED; presentation_changed(host); return;
    }
    char metadata[256];
    g_snprintf(metadata, sizeof metadata, "{\"width\":%d,\"height\":%d,\"durationMs\":%.0f,\"hasAudio\":%s}",
        host->metadata.width, host->metadata.height, round(host->metadata.duration_ms), host->metadata.has_audio ? "true" : "false");
    moonbit_string_t source = mb_string(host->source), meta = mb_string(metadata), draft = mb_string(host->draft_bytes);
    host->editor = host->fallback ? video_editor_open_unsaved(source, meta, draft) : video_editor_open(source, meta, draft);
    moonbit_decref(source); moonbit_decref(meta); moonbit_decref(draft);
    g_clear_pointer(&host->draft_bytes, g_free);
    if (!host->editor) {
        host->phase = MC_VIDEO_HOST_FAILED;
        presentation_changed(host);
        error_text(host->error, sizeof host->error, "媒体信息或现有草稿无效，已保留原文件");
    } else {
        host->error[0] = 0;
        if (host->metadata.has_audio) {
            char error[1024] = {0};
            host->waveform = mc_waveform_create(host->source, (int64_t)round(host->metadata.duration_ms),
                                                1024, error, sizeof error);
            if (!host->waveform) g_message("Optional waveform unavailable: %s", error);
        }
        execute_effects(host);
    }
}

static void poll_waveform(MCVideoEditorHost *host) {
    if (!host->waveform) return;
    MCWaveformState state = {0};
    if (!mc_waveform_poll(host->waveform, &state) || state.status == MC_WAVEFORM_RUNNING) return;
    MCWaveformResult result = {0};
    if (mc_waveform_take(host->waveform, &result)) {
        if (host->editor && host->phase == MC_VIDEO_HOST_OPEN) {
            GString *json = g_string_new(NULL);
            g_string_append_printf(json, "{\"type\":\"waveform\",\"durationMs\":%" G_GINT64_FORMAT ",\"peaks\":[", result.duration_ms);
            for (size_t i = 0; i < result.count; i++) {
                char number[G_ASCII_DTOSTR_BUF_SIZE];
                g_ascii_dtostr(number, sizeof number, result.peaks[i]);
                g_string_append_printf(json, "%s%s", i ? "," : "", number);
            }
            g_string_append(json, "]}");
            moonbit_string_t value = mb_string(json->str);
            if (video_editor_waveform(host->editor, value)) presentation_changed(host);
            moonbit_decref(value);
            g_string_free(json, TRUE);
        }
        mc_waveform_result_clear(&result);
    } else if (*state.error) g_message("Optional waveform unavailable: %s", state.error);
    if (mc_waveform_free(host->waveform)) host->waveform = NULL;
}

void mc_video_editor_host_tick(MCVideoEditorHost *host) {
    if (!host || host->phase == MC_VIDEO_HOST_CLOSED) return;
    DraftJob *job;
    while ((job = g_async_queue_try_pop(host->io))) {
        if (job->thread) g_thread_join(job->thread); /* IO finished before enqueue. */
        host->jobs--;
        if (job->save) {
            /* A publication can succeed before a sync error. Keep its actual
             * token even when the session must retain dirty=true. */
            host->draft_exists = job->existed;
            g_free(host->etag); host->etag = g_strdup(job->etag);
            ack(host, job->ticket, job->success ? MC_EDITOR_ACK_OK : MC_EDITOR_ACK_FAILED, job->error);
        } else {
            host->draft_done = true;
            if (job->success) {
                host->draft_exists = job->existed;
                host->fallback = job->fallback;
                g_free(host->etag); host->etag = g_strdup(job->etag);
                host->draft_bytes = g_steal_pointer(&job->bytes);
            } else error_text(host->error, sizeof host->error, job->error);
        }
        job_free(job);
    }
    MCMediaCompletion completion;
    while (mc_media_worker_poll(host->worker, &completion)) {
        if (completion.token == host->probe_token) {
            host->probe_done = true;
            host->probe_ok = completion.status == MC_MEDIA_OK;
            if (host->probe_ok) host->metadata = completion.metadata;
            else error_text(host->error, sizeof host->error, completion.error);
        } else if (!(completion.token & AUX_TOKEN) && host->editor) {
            if (completion.kind == MC_MEDIA_CLOSE && completion.status == MC_MEDIA_OK)
                host->close_ticket = (int32_t)completion.token;
            else ack(host, (int32_t)completion.token, completion.status, completion.error);
        }
    }
    maybe_open(host);
    poll_waveform(host);
    if (host->close_ticket && !host->waveform && !host->jobs) {
        ack(host, host->close_ticket, MC_EDITOR_ACK_OK, "");
        host->close_ticket = 0;
    }
    execute_effects(host);
    MCMediaState state = {0};
    mc_media_worker_snapshot(host->worker, &state);
    if (host->closing && !host->editor && state.closed && !host->jobs) {
        host->phase = MC_VIDEO_HOST_CLOSED; presentation_changed(host);
    }
    if (host->editor && host->phase != MC_VIDEO_HOST_CLOSED) {
        if (state.error_serial != host->error_serial) {
            host->error_serial = state.error_serial;
            if (*state.error && state.plan_generation <= INT32_MAX) {
                moonbit_string_t message = mb_string(state.error);
                if (video_editor_media_failed(host->editor, (int32_t)state.plan_generation, message))
                    presentation_changed(host);
                moonbit_decref(message);
            }
        }
        if (state.plan_generation <= INT32_MAX && (!host->clock_delivered ||
            host->clock_generation != state.plan_generation || host->clock_position != state.position_ms ||
            host->clock_playing != state.playing)) {
            if (video_editor_playback(host->editor, (int32_t)state.plan_generation, state.position_ms, state.playing ? 1 : 0)) {
                host->clock_delivered = true; host->clock_generation = state.plan_generation;
                host->clock_position = state.position_ms; host->clock_playing = state.playing;
                presentation_changed(host);
            }
        }
        if (state.export_token && state.export_token <= INT32_MAX &&
            (host->progress_ticket != state.export_token || host->progress != state.export_progress)) {
            if (video_editor_export_progress(host->editor, (int32_t)state.export_token, state.export_progress)) {
                host->progress_ticket = state.export_token; host->progress = state.export_progress;
                presentation_changed(host);
            }
        }
        execute_effects(host);
    }
    MCMediaFrame incoming = {0};
    if (mc_media_worker_take_frame(host->worker, &incoming)) {
        if (host->phase == MC_VIDEO_HOST_OPEN && host->editor &&
            video_editor_value(host->editor, MC_EDITOR_MEDIA_READY) &&
            incoming.plan_generation == host->wanted_generation && incoming.seek_token == host->wanted_seek) {
            mc_media_frame_clear(&host->frame); host->frame = incoming;
            memset(&incoming, 0, sizeof incoming);
        }
        mc_media_frame_clear(&incoming);
    }
}

int mc_video_editor_host_phase(const MCVideoEditorHost *host) { return host ? host->phase : MC_VIDEO_HOST_CLOSED; }
uint64_t mc_video_editor_host_presentation_serial(const MCVideoEditorHost *host) {
    return host ? host->presentation_serial : 0;
}
const char *mc_video_editor_host_error(MCVideoEditorHost *host) {
    if (!host) return "";
    if (host->editor) {
        char *message = take_string(video_editor_text(host->editor, MC_EDITOR_ERROR));
        error_text(host->error, sizeof host->error, message); g_free(message);
    }
    return host->error;
}
int32_t mc_video_editor_host_value(const MCVideoEditorHost *host, int32_t key) {
    return host && host->editor ? video_editor_value(host->editor, key) : 0;
}
double mc_video_editor_host_number(const MCVideoEditorHost *host, int32_t key) {
    return host && host->editor ? video_editor_number(host->editor, key) : -1;
}
int32_t mc_video_editor_host_frame(MCVideoEditorHost *host, double width, double height) {
    if (!host || !host->editor || host->phase == MC_VIDEO_HOST_CLOSED) return 0;
    moonbit_string_t json = video_editor_frame(host->editor, width, height);
    int32_t frame = ui_frame_open(json);
    moonbit_decref(json);
    return frame;
}
char *mc_video_editor_host_state(MCVideoEditorHost *host) {
    return host && host->editor ? take_string(video_editor_state(host->editor)) : g_strdup("");
}
void mc_video_editor_host_text_free(char *text) { g_free(text); }
bool mc_video_editor_host_event(MCVideoEditorHost *host, const MCCanvasInput *input) {
    if (!host || !host->editor || host->phase != MC_VIDEO_HOST_OPEN) return false;
    moonbit_string_t json = mc_canvas_input_json(input);
    bool accepted = video_editor_event(host->editor, json) != 0;
    moonbit_decref(json);
    presentation_changed(host); host->clock_delivered = false;
    execute_effects(host);
    return accepted;
}
bool mc_video_editor_host_command(MCVideoEditorHost *host, const char *json) {
    if (!host || !host->editor || host->phase != MC_VIDEO_HOST_OPEN || !json || !g_utf8_validate(json, -1, NULL)) return false;
    moonbit_string_t value = mb_string(json);
    bool accepted = video_editor_command(host->editor, value) != 0;
    moonbit_decref(value);
    presentation_changed(host); host->clock_delivered = false;
    execute_effects(host);
    return accepted;
}
int32_t mc_video_editor_host_chooser(const MCVideoEditorHost *host) { return host ? host->chooser : 0; }
bool mc_video_editor_host_choose(MCVideoEditorHost *host, int32_t ticket, const char *destination) {
    if (!host || !host->editor || !ticket || ticket != host->chooser) return false;
    if (destination && !path_valid(destination)) return false;
    moonbit_string_t path = mb_string(destination);
    bool accepted = video_editor_ack(host->editor, ticket, destination ? MC_EDITOR_ACK_OK : MC_EDITOR_ACK_CANCELLED, path) != 0;
    moonbit_decref(path);
    if (accepted) { host->chooser = 0; presentation_changed(host); }
    execute_effects(host);
    return accepted;
}
bool mc_video_editor_host_request_close(MCVideoEditorHost *host, bool cancel_export) {
    if (!host) return false;
    if (host->phase == MC_VIDEO_HOST_CLOSED || host->closing) return true;
    if (host->editor) {
        bool accepted = video_editor_request_close(host->editor, cancel_export ? 1 : 0) != 0;
        if (accepted && host->waveform) mc_waveform_cancel(host->waveform);
        execute_effects(host);
        return accepted;
    }
    MCMediaRequest request = {0};
    request.kind = MC_MEDIA_CLOSE; request.token = AUX_TOKEN | ++host->aux_serial;
    request.generation = 1;
    if (!mc_media_worker_submit(host->worker, &request, host->error, sizeof host->error)) return false;
    host->closing = true; host->phase = MC_VIDEO_HOST_CLOSING;
    presentation_changed(host);
    mc_media_frame_clear(&host->frame);
    return true;
}
bool mc_video_editor_host_retry(MCVideoEditorHost *host) {
    if (!host || host->closing || host->phase == MC_VIDEO_HOST_CLOSED) return false;
    if (host->editor) {
        bool accepted = video_editor_retry(host->editor) != 0;
        if (accepted) { presentation_changed(host); host->clock_delivered = false; }
        execute_effects(host);
        return accepted;
    }
    if (host->phase != MC_VIDEO_HOST_FAILED || host->jobs || !host->probe_done) return false;
    return start_probe(host);
}
const MCMediaFrame *mc_video_editor_host_video(const MCVideoEditorHost *host) {
    return host && host->frame.image.pixels ? &host->frame : NULL;
}
bool mc_video_editor_host_free(MCVideoEditorHost *host) {
    if (!host) return true;
    if (host->phase != MC_VIDEO_HOST_CLOSED || host->jobs || host->waveform) return false;
    if (!mc_media_worker_free(host->worker)) return false;
    if (host->editor) video_editor_release(host->editor);
    mc_media_frame_clear(&host->frame);
    g_async_queue_unref(host->io);
    g_free(host->source); g_free(host->draft); g_free(host->legacy); g_free(host->etag); g_free(host->draft_bytes); g_free(host);
    return true;
}
