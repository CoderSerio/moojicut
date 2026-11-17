#include "platform/shared/app/video_editor_host.h"
#include <glib/gstdio.h>
#include <gst/gst.h>
#include <gst/pbutils/pbutils.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

static int failures;
static int default_dispatches;
static char error_text[1024];
extern void moonbit_init(void);

static bool check(bool condition, const char *message) {
    printf("%s %s%s%s\n", condition ? "PASS" : "FAIL", message,
           !condition && error_text[0] ? ": " : "", !condition ? error_text : "");
    fflush(stdout);
    if (!condition) failures++;
    error_text[0] = '\0';
    return condition;
}

static gboolean default_sentinel(gpointer unused) {
    (void)unused;
    default_dispatches++;
    return G_SOURCE_REMOVE;
}

static char *file_hash(const char *path) {
    char *bytes = NULL;
    gsize size = 0;
    if (!g_file_get_contents(path, &bytes, &size, NULL)) return NULL;
    char *hash = g_compute_checksum_for_data(G_CHECKSUM_SHA256, (const guchar *)bytes, size);
    g_free(bytes);
    return hash;
}

static bool hash_matches(const char *path, const char *expected) {
    char *actual = file_hash(path);
    bool matches = actual && expected && strcmp(actual, expected) == 0;
    g_free(actual);
    return matches;
}

static bool hard_link(const char *source, const char *alias) {
#ifdef _WIN32
    gunichar2 *from = g_utf8_to_utf16(source, -1, NULL, NULL, NULL);
    gunichar2 *to = g_utf8_to_utf16(alias, -1, NULL, NULL, NULL);
    bool success = from && to && CreateHardLinkW((const wchar_t *)to, (const wchar_t *)from, NULL);
    g_free(from);
    g_free(to);
    return success;
#else
    return link(source, alias) == 0;
#endif
}

/* Asset generation/probing never initializes GES. The media worker remains
 * the process's only GES owner, even while this fixture uses plain Gst APIs. */
static bool generate_source(const char *path) {
    GError *failure = NULL;
    GstElement *pipeline = gst_parse_launch(
        "videotestsrc num-buffers=90 pattern=solid-color foreground-color=0xffff2020 ! "
        "video/x-raw,width=160,height=90,framerate=30/1 ! vp8enc deadline=1 ! queue ! mux. "
        "audiotestsrc num-buffers=141 samplesperbuffer=1024 freq=440 ! "
        "audio/x-raw,rate=48000,channels=2 ! audioconvert ! flacenc ! queue ! mux. "
        "matroskamux name=mux ! filesink name=output", &failure);
    if (!pipeline || failure) {
        g_strlcpy(error_text, failure ? failure->message : "cannot create fixture source", sizeof error_text);
        g_clear_error(&failure);
        if (pipeline) gst_object_unref(pipeline);
        return false;
    }
    GstElement *output = gst_bin_get_by_name(GST_BIN(pipeline), "output");
    g_object_set(output, "location", path, NULL);
    gst_object_unref(output);
    GstBus *bus = gst_element_get_bus(pipeline);
    bool ok = gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE;
    GstMessage *message = ok ? gst_bus_timed_pop_filtered(bus, 15 * GST_SECOND,
        GST_MESSAGE_EOS | GST_MESSAGE_ERROR) : NULL;
    ok = message && GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS;
    if (message && !ok) {
        gst_message_parse_error(message, &failure, NULL);
        g_strlcpy(error_text, failure ? failure->message : "fixture source failed", sizeof error_text);
        g_clear_error(&failure);
    }
    if (message) gst_message_unref(message);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(bus);
    gst_object_unref(pipeline);
    return ok;
}

static bool actual_export(const char *path) {
    GError *failure = NULL;
    gchar *uri = gst_filename_to_uri(path, &failure);
    GstDiscoverer *probe = uri ? gst_discoverer_new(10 * GST_SECOND, &failure) : NULL;
    GstDiscovererInfo *info = probe ? gst_discoverer_discover_uri(probe, uri, &failure) : NULL;
    bool ok = info && gst_discoverer_info_get_result(info) == GST_DISCOVERER_OK;
    if (ok) {
        GList *videos = gst_discoverer_info_get_video_streams(info);
        GList *audio = gst_discoverer_info_get_audio_streams(info);
        double duration = (double)gst_discoverer_info_get_duration(info) / GST_MSECOND;
        ok = videos && !videos->next && audio && !audio->next &&
             gst_discoverer_video_info_get_width(videos->data) == 160 &&
             gst_discoverer_video_info_get_height(videos->data) == 90 &&
             duration >= 3950 && duration <= 4100;
        gst_discoverer_stream_info_list_free(videos);
        gst_discoverer_stream_info_list_free(audio);
    }
    if (failure) {
        g_strlcpy(error_text, failure->message, sizeof error_text);
        g_error_free(failure);
    }
    if (info) gst_discoverer_info_unref(info);
    if (probe) g_object_unref(probe);
    g_free(uri);
    return ok;
}

enum WaitFor { WAIT_READY, WAIT_CLOSED, WAIT_FAILED, WAIT_CHOOSER, WAIT_EXPORT, WAIT_SAVE_FAILED };
static bool wait_host(MCVideoEditorHost *host, enum WaitFor condition) {
    gint64 deadline = g_get_monotonic_time() + 45000000;
    while (g_get_monotonic_time() < deadline) {
        mc_video_editor_host_tick(host);
        int phase = mc_video_editor_host_phase(host);
        bool ready = phase == MC_VIDEO_HOST_OPEN &&
            mc_video_editor_host_value(host, MC_EDITOR_MEDIA_READY) == 1 &&
            mc_video_editor_host_value(host, MC_EDITOR_DIRTY) == 0;
        if ((condition == WAIT_READY && ready) ||
            (condition == WAIT_CLOSED && phase == MC_VIDEO_HOST_CLOSED) ||
            (condition == WAIT_FAILED && phase == MC_VIDEO_HOST_FAILED) ||
            (condition == WAIT_CHOOSER && mc_video_editor_host_chooser(host) > 0) ||
            (condition == WAIT_SAVE_FAILED && phase == MC_VIDEO_HOST_OPEN &&
             mc_video_editor_host_value(host, MC_EDITOR_MEDIA_READY) == 1 &&
             mc_video_editor_host_value(host, MC_EDITOR_DIRTY) == 1 &&
             mc_video_editor_host_error(host)[0]) ||
            (condition == WAIT_EXPORT && phase == MC_VIDEO_HOST_OPEN &&
             mc_video_editor_host_value(host, MC_EDITOR_EXPORT_BUSY) == 0)) return true;
        if (phase == MC_VIDEO_HOST_FAILED && condition != WAIT_FAILED && condition != WAIT_CLOSED) break;
        g_usleep(1000);
    }
    g_snprintf(error_text, sizeof error_text, "host wait %d, phase %d: %.850s", condition,
               mc_video_editor_host_phase(host), mc_video_editor_host_error(host));
    return false;
}

static bool close_host(MCVideoEditorHost *host) {
    bool requested = mc_video_editor_host_request_close(host, true);
    bool closed = requested && wait_host(host, WAIT_CLOSED);
    return closed && mc_video_editor_host_video(host) == NULL && mc_video_editor_host_free(host);
}

static bool idle_presentation_stable(MCVideoEditorHost *host) {
    if (mc_video_editor_host_value(host, MC_EDITOR_PLAYING) != 0) return false;
    gint64 deadline = g_get_monotonic_time() + 5000000;
    gint64 quiet_since = g_get_monotonic_time();
    uint64_t serial = mc_video_editor_host_presentation_serial(host);
    /* Initial playback facts and optional waveform completion may arrive after
     * MEDIA_READY. Require a quiet interval before testing idle polling. */
    while (g_get_monotonic_time() < deadline) {
        mc_video_editor_host_tick(host);
        uint64_t next = mc_video_editor_host_presentation_serial(host);
        if (next != serial) {
            serial = next;
            quiet_since = g_get_monotonic_time();
        }
        if (g_get_monotonic_time() - quiet_since >= 200000) {
            for (int i = 0; i < 64; i++) {
                mc_video_editor_host_tick(host);
                if (mc_video_editor_host_presentation_serial(host) != serial) return false;
            }
            return serial > 0;
        }
        g_usleep(1000);
    }
    g_strlcpy(error_text, "paused presentation did not become quiet within five seconds", sizeof error_text);
    return false;
}

static char *utf8(moonbit_string_t text) {
    char *result = g_utf16_to_utf8((const gunichar2 *)text, Moonbit_array_length(text), NULL, NULL, NULL);
    moonbit_decref(text);
    return result;
}

static int semantic(int32_t frame, const char *id) {
    for (int i = 0; i < ui_frame_semantic_count(frame); i++) {
        char *actual = utf8(ui_frame_semantic_text(frame, i, MC_UI_SEM_ID));
        bool same = actual && strcmp(actual, id) == 0;
        g_free(actual);
        if (same) return i;
    }
    return -1;
}

static bool activate(MCVideoEditorHost *host, const char *id) {
    int32_t frame = mc_video_editor_host_frame(host, 1040, 700);
    int node = frame > 0 ? semantic(frame, id) : -1;
    bool enabled = node >= 0 && ui_frame_semantic_value(frame, node, MC_UI_SEM_ENABLED) == 1;
    if (frame > 0) ui_frame_close(frame);
    if (!enabled) return false;
    glong length = 0;
    gunichar2 *text = g_utf8_to_utf16(id, -1, NULL, &length, NULL);
    MCCanvasInput input = {.type=MC_UI_INPUT_ACTIVATE, .text=text, .text_length=(size_t)length};
    bool accepted = text && mc_video_editor_host_event(host, &input);
    g_free(text);
    return accepted;
}

static bool seek_pointer(MCVideoEditorHost *host, double milliseconds) {
    int32_t frame = mc_video_editor_host_frame(host, 1040, 700);
    int node = frame > 0 ? semantic(frame, "playhead") : -1;
    bool valid = node >= 0 && ui_frame_semantic_value(frame, node, MC_UI_SEM_ENABLED) == 1;
    double maximum = valid ? ui_frame_semantic_number(frame, node, MC_UI_SEM_MAX) : 0;
    double x = valid ? ui_frame_semantic_number(frame, node, MC_UI_SEM_X) +
        ui_frame_semantic_number(frame, node, MC_UI_SEM_WIDTH) * milliseconds / maximum : 0;
    double y = valid ? ui_frame_semantic_number(frame, node, MC_UI_SEM_Y) +
        ui_frame_semantic_number(frame, node, MC_UI_SEM_HEIGHT) / 2 : 0;
    if (frame > 0) ui_frame_close(frame);
    if (!valid || maximum < milliseconds || maximum <= 0) return false;
    MCCanvasInput input = {.type=MC_UI_INPUT_POINTER_DOWN, .x=x, .y=y};
    if (!mc_video_editor_host_event(host, &input)) return false;
    input.type = MC_UI_INPUT_POINTER_UP;
    return mc_video_editor_host_event(host, &input);
}

static bool frame_at(MCVideoEditorHost *host, double milliseconds, bool black) {
    gint64 deadline = g_get_monotonic_time() + 5000000;
    while (g_get_monotonic_time() < deadline) {
        mc_video_editor_host_tick(host);
        const MCMediaFrame *frame = mc_video_editor_host_video(host);
        if (frame && frame->image.pixels && frame->image.width && frame->image.height &&
            fabs(mc_video_editor_host_number(host, MC_EDITOR_OUTPUT_MS) - milliseconds) < 50) {
            const unsigned char *pixel = frame->image.pixels +
                (size_t)(frame->image.height / 2) * frame->image.stride + (size_t)(frame->image.width / 2) * 4;
            bool matches = black ? pixel[0] < 10 && pixel[1] < 10 && pixel[2] < 10 :
                                   pixel[2] > 180 && pixel[0] < 80 && pixel[1] < 80;
            if (matches) return true;
        }
        g_usleep(1000);
    }
    g_strlcpy(error_text, mc_video_editor_host_error(host), sizeof error_text);
    return false;
}

/* Extract an object from the public state envelope, respecting JSON strings.
 * No child project/UI handles or new JSON dependency are used by this fixture. */
static char *document(MCVideoEditorHost *host) {
    char *state = mc_video_editor_host_state(host);
    const char *key = state ? strstr(state, "\"document\"") : NULL;
    const char *start = key ? strchr(key + strlen("\"document\""), ':') : NULL;
    if (start) {
        do { start++; } while (g_ascii_isspace(*start));
    }
    char *result = NULL;
    if (start && *start == '{') {
        bool quoted = false, escaped = false;
        int depth = 0;
        for (const char *at = start; *at; at++) {
            if (quoted) {
                if (escaped) escaped = false;
                else if (*at == '\\') escaped = true;
                else if (*at == '"') quoted = false;
            } else if (*at == '"') quoted = true;
            else if (*at == '{') depth++;
            else if (*at == '}' && --depth == 0) {
                result = g_strndup(start, (gsize)(at - start + 1));
                break;
            }
        }
    }
    mc_video_editor_host_text_free(state);
    return result;
}

static bool clip_start(const char *json, const char *id, int64_t expected) {
    if (!json) return false;
    char *pattern = g_strdup_printf("\\{[^{}]*\"id\"\\s*:\\s*\"%s\"[^{}]*\\}", id);
    GRegex *regex = g_regex_new(pattern, 0, 0, NULL);
    GMatchInfo *match = NULL;
    bool found = regex && g_regex_match(regex, json, 0, &match);
    char *clip = found ? g_match_info_fetch(match, 0) : NULL;
    const char *field = clip ? strstr(clip, "\"startTicks\"") : NULL;
    const char *colon = field ? strchr(field, ':') : NULL;
    bool correct = colon && g_ascii_strtoll(colon + 1, NULL, 10) == expected;
    if (match) g_match_info_free(match);
    if (regex) g_regex_unref(regex);
    g_free(clip);
    g_free(pattern);
    return correct;
}

static bool command(MCVideoEditorHost *host, const char *request_id, const char *operation) {
    char *json = g_strdup_printf("{\"expectedRevision\":%.0f,\"requestId\":\"%s\",\"op\":%s}",
        mc_video_editor_host_number(host, MC_EDITOR_REVISION), request_id, operation);
    bool accepted = mc_video_editor_host_command(host, json);
    g_free(json);
    return accepted;
}

static bool save_failure_recovery(const char *source, const char *directory, const char *original) {
    char *folder = g_build_filename(directory, "save-failure", NULL);
    char *preserved = g_build_filename(directory, "preserved-draft", NULL);
    char *draft = g_build_filename(folder, "edit.json", NULL);
    char *retained = g_build_filename(preserved, "edit.json", NULL);
    if (!check(g_mkdir(folder, 0700) == 0, "create isolated draft directory for real IO failure")) return false;
    MCVideoEditorHost *host = mc_video_editor_host_create(source, draft, true, error_text, sizeof error_text);
    if (!check(host && wait_host(host, WAIT_READY), "save-failure fixture opens and persists its initial draft")) return false;
    char *old_hash = file_hash(draft);
    double old_revision = mc_video_editor_host_number(host, MC_EDITOR_REVISION);
    /* Unlike chmod, replacing a parent directory with our own regular file
     * fails on Windows as well. Keep the original draft and its etag intact. */
    if (!check(g_rename(folder, preserved) == 0 &&
               g_file_set_contents(folder, "owned blocker", -1, NULL),
               "replace draft parent with a regular file to force actual save IO failure")) return false;
    check(command(host, "mute-while-save-blocked", "{\"type\":\"mute\",\"muted\":true}") &&
          wait_host(host, WAIT_SAVE_FAILED), "failed durable save reports error while the edited preview remains usable");
    char *memory = document(host);
    check(memory && g_regex_match_simple("\"muted\"\\s*:\\s*true", memory, 0, 0) &&
          mc_video_editor_host_number(host, MC_EDITOR_REVISION) == old_revision + 1 &&
          mc_video_editor_host_number(host, MC_EDITOR_SAVED_REVISION) == old_revision &&
          hash_matches(retained, old_hash) && hash_matches(source, original),
          "save failure retains edited memory and dirty revision while preserving old draft and source bytes");
    check(mc_video_editor_host_request_close(host, false) && wait_host(host, WAIT_SAVE_FAILED) &&
          !mc_video_editor_host_free(host), "close cannot discard dirty memory or report CLOSED after failed save");
    if (!check(g_unlink(folder) == 0 && g_rename(preserved, folder) == 0,
               "restore the exact original draft file after removing only the fixture-owned blocker")) return false;
    check(mc_video_editor_host_retry(host) && wait_host(host, WAIT_READY),
          "retry acknowledges a real successful save after filesystem recovery");
    char *disk = NULL;
    check(g_file_get_contents(draft, &disk, NULL, NULL) && memory &&
          strcmp(g_strstrip(disk), memory) == 0 &&
          mc_video_editor_host_number(host, MC_EDITOR_SAVED_REVISION) == old_revision + 1,
          "retry persists exactly the previously retained edited document");
    check(close_host(host), "recovered dirty editor drains and frees normally");
    g_free(old_hash); g_free(memory); g_free(disk);
    g_free(folder); g_free(preserved); g_free(draft); g_free(retained);
    return true;
}

static bool legacy_migration(const char *source, const char *directory, const char *v2_document) {
    char *legacy_v2 = g_build_filename(directory, "legacy-v2.json", NULL);
    char *new_v2 = g_build_filename(directory, "migrated-v2.json", NULL);
    char *legacy_v1 = g_build_filename(directory, "legacy-v1.json", NULL);
    char *new_v1 = g_build_filename(directory, "migrated-v1.json", NULL);
    char *bad_new = g_build_filename(directory, "existing-bad-new.json", NULL);
    if (!check(v2_document && g_file_set_contents(legacy_v2, v2_document, -1, NULL),
               "prepare an explicit legacy-location v2 document")) return false;
    char *v2_hash = file_hash(legacy_v2);
    MCVideoEditorHost *host = mc_video_editor_host_create_with_legacy(source, new_v2, legacy_v2,
        true, error_text, sizeof error_text);
    if (!check(host && wait_host(host, WAIT_READY), "legacy-location v2 opens and publishes the genuinely missing new draft")) return false;
    char *restored = document(host), *disk = NULL;
    check(restored && strcmp(restored, v2_document) == 0 &&
          g_file_get_contents(new_v2, &disk, NULL, NULL) && strcmp(g_strstrip(disk), v2_document) == 0 &&
          hash_matches(legacy_v2, v2_hash),
          "v2 location migration really saves the new file while preserving exact legacy bytes");
    g_free(restored);
    g_free(disk);
    check(close_host(host), "migrated v2 editor drains and releases normally");

    static const char v1[] = "{\"schemaVersion\":1,\"trim\":{\"startMs\":0,\"endMs\":2000},"
        "\"cuts\":[],\"crop\":{\"x\":10,\"y\":10,\"width\":100,\"height\":60},"
        "\"muted\":true,\"preset\":\"share\"}";
    if (!check(g_file_set_contents(legacy_v1, v1, -1, NULL), "prepare a real v1 trim/crop/mute draft")) return false;
    char *v1_hash = file_hash(legacy_v1);
    host = mc_video_editor_host_create_with_legacy(source, new_v1, legacy_v1,
        true, error_text, sizeof error_text);
    if (!check(host && wait_host(host, WAIT_READY), "host migrates legacy v1 through the shared document core")) return false;
    restored = document(host);
    disk = NULL;
    check(restored && g_regex_match_simple("\"schemaVersion\"\\s*:\\s*2", restored, 0, 0) &&
          g_regex_match_simple("\"muted\"\\s*:\\s*true", restored, 0, 0) &&
          g_regex_match_simple("\"durationTicks\"\\s*:\\s*180000", restored, 0, 0) &&
          g_regex_match_simple("\"crop\"\\s*:\\s*\\{[^{}]*\"width\"\\s*:\\s*100\\b", restored, 0, 0) &&
          g_regex_match_simple("\"crop\"\\s*:\\s*\\{[^{}]*\"height\"\\s*:\\s*60\\b", restored, 0, 0) &&
          clip_start(restored, "v1", 0) && g_file_get_contents(new_v1, &disk, NULL, NULL) &&
          strcmp(g_strstrip(disk), restored) == 0 && hash_matches(legacy_v1, v1_hash),
          "v1 migration preserves trim/crop/mute in saved v2 and retains the old file unchanged");
    g_free(restored);
    g_free(disk);
    check(close_host(host), "migrated v1 editor drains and frees");

    if (!check(g_file_set_contents(bad_new, "{broken new draft", -1, NULL),
               "prepare an existing malformed new draft beside a valid legacy fallback")) return false;
    char *bad_hash = file_hash(bad_new);
    host = mc_video_editor_host_create_with_legacy(source, bad_new, legacy_v2,
        true, error_text, sizeof error_text);
    check(host && wait_host(host, WAIT_FAILED) && hash_matches(bad_new, bad_hash) && hash_matches(legacy_v2, v2_hash),
          "an existing bad new draft fails without falling back to or modifying legacy data");
    if (host) check(close_host(host), "failed migration guard still drains and frees");
    g_free(v2_hash); g_free(v1_hash); g_free(bad_hash);
    g_free(legacy_v2); g_free(new_v2); g_free(legacy_v1); g_free(new_v1); g_free(bad_new);
    return true;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: video-editor-host NEW_OUTPUT_DIRECTORY\n");
        return 2;
    }
    g_log_set_always_fatal(G_LOG_FATAL_MASK | G_LOG_LEVEL_CRITICAL);
    moonbit_init();
    GError *failure = NULL;
    if (!gst_init_check(NULL, NULL, &failure)) {
        fprintf(stderr, "GStreamer init: %s\n", failure ? failure->message : "failed");
        g_clear_error(&failure);
        return 2;
    }
    char *directory = g_canonicalize_filename(argv[1], NULL);
    if (g_mkdir_with_parents(directory, 0700)) return 2;
    char *source = g_build_filename(directory, "source.mkv", NULL);
    char *draft = g_build_filename(directory, "edit.json", NULL);
    char *output = g_build_filename(directory, "export.mp4", NULL);
    char *alias = g_build_filename(directory, "source-alias.mp4", NULL);
    char *bad_draft = g_build_filename(directory, "bad-edit.json", NULL);
    if (!check(!g_file_test(source, G_FILE_TEST_EXISTS) && !g_file_test(draft, G_FILE_TEST_EXISTS),
               "fixture refuses an output directory containing previous source/draft")) return 2;
    if (!check(generate_source(source), "generate actual short audio/video source without GES on caller thread")) return 1;
    char *original = file_hash(source);
    guint sentinel = g_idle_add(default_sentinel, NULL);
    MCVideoEditorHost *host = mc_video_editor_host_create(source, draft, true, error_text, sizeof error_text);
    if (!check(host != NULL, "production host starts asynchronous source/draft IO")) return 1;
    check(!mc_video_editor_host_free(host), "opening host cannot be freed before worker drain");
    if (!check(wait_host(host, WAIT_READY), "async probe, MoonBit session, preview apply and initial draft save complete")) return 1;
    check(g_file_test(draft, G_FILE_TEST_IS_REGULAR) &&
          mc_video_editor_host_number(host, MC_EDITOR_SAVED_REVISION) ==
          mc_video_editor_host_number(host, MC_EDITOR_REVISION), "initial saved revision is backed by an actual draft file");
    check(idle_presentation_stable(host), "paused host presentation serial stays unchanged across consecutive idle ticks");
    uint64_t presentation = mc_video_editor_host_presentation_serial(host);
    double appearance_revision = mc_video_editor_host_number(host, MC_EDITOR_REVISION);
    static const uint16_t light[] = {'l', 'i', 'g', 'h', 't'};
    MCCanvasInput appearance = {.type=MC_UI_INPUT_APPEARANCE, .text=light, .text_length=5};
    check(mc_video_editor_host_event(host, &appearance) &&
          mc_video_editor_host_presentation_serial(host) > presentation &&
          mc_video_editor_host_number(host, MC_EDITOR_REVISION) == appearance_revision &&
          mc_video_editor_host_value(host, MC_EDITOR_DIRTY) == 0,
          "public appearance event advances presentation serial without creating a document edit");
    check(command(host, "split-one", "{\"type\":\"split\",\"clipId\":\"v1\",\"atTicks\":90000}") &&
          wait_host(host, WAIT_READY), "complete JSON command splits linked audio/video through the public host");
    check(command(host, "move-two", "{\"type\":\"move\",\"clipId\":\"v2\",\"startTicks\":180000}") &&
          wait_host(host, WAIT_READY), "absolute linked move saves and applies a real one-second gap");
    char *saved_document = document(host);
    check(clip_start(saved_document, "v2", 180000) && clip_start(saved_document, "a2", 180000),
          "public document keeps linked video and audio at the requested output position");
    check(seek_pointer(host, 500) && frame_at(host, 500, false), "shared ruler pointer input seeks decoded source pixels");
    bool seek_gap = seek_pointer(host, 1500);
    check(seek_gap && mc_video_editor_host_video(host) == NULL,
          "new seek immediately hides stale borrowed preview pixels");
    check(seek_gap && frame_at(host, 1500, true), "host preview exposes actual black pixels in the output gap");
    check(seek_pointer(host, 2500) && frame_at(host, 2500, false), "seek after the gap returns moved source pixels");

    check(activate(host, "export") && wait_host(host, WAIT_CHOOSER), "shared export semantic opens one pending chooser ticket");
    int32_t ticket = mc_video_editor_host_chooser(host);
    check(ticket > 0 && mc_video_editor_host_chooser(host) == ticket &&
          !mc_video_editor_host_choose(host, ticket + 1, output), "pending chooser remains stable and rejects a foreign ticket");
    check(mc_video_editor_host_choose(host, ticket, NULL) && wait_host(host, WAIT_EXPORT) &&
          !g_file_test(output, G_FILE_TEST_EXISTS), "chooser cancellation completes without creating an export");
    check(hard_link(source, alias), "create an actual source hard-link export alias");
    check(activate(host, "export") && wait_host(host, WAIT_CHOOSER), "export can be requested again after chooser cancellation");
    ticket = mc_video_editor_host_chooser(host);
    check(mc_video_editor_host_choose(host, ticket, alias) && wait_host(host, WAIT_EXPORT) &&
          mc_video_editor_host_error(host)[0] && hash_matches(alias, original) && hash_matches(source, original),
          "source alias export is rejected without overwriting either hard link");
    check(activate(host, "export") && wait_host(host, WAIT_CHOOSER), "failed alias export leaves the editor usable");
    ticket = mc_video_editor_host_chooser(host);
    check(mc_video_editor_host_choose(host, ticket, output) && wait_host(host, WAIT_EXPORT) && actual_export(output),
          "host chooser drives actual H.264/AAC MP4 export and drained publication");
    char *disk_document = NULL;
    check(g_file_get_contents(draft, &disk_document, NULL, NULL) && saved_document &&
          g_strcmp0(g_strstrip(disk_document), saved_document) == 0,
          "saved draft bytes match the public document after editing and export");
    char *draft_hash = file_hash(draft);
    check(close_host(host), "request_close reaches actual CLOSED with no frame before free succeeds");
    host = mc_video_editor_host_create(source, draft, true, error_text, sizeof error_text);
    if (!check(host && wait_host(host, WAIT_READY), "saved production editor reopens through asynchronous IO")) return 1;
    char *reopened = document(host);
    check(saved_document && reopened && strcmp(saved_document, reopened) == 0 && hash_matches(draft, draft_hash),
          "reopen restores exactly the durable document without rewriting valid draft bytes");
    check(close_host(host), "reopened editor drains and frees independently");

    check(g_file_set_contents(bad_draft, "{broken draft", -1, NULL), "create malformed existing draft");
    char *bad_hash = file_hash(bad_draft);
    host = mc_video_editor_host_create(source, bad_draft, true, error_text, sizeof error_text);
    check(host && wait_host(host, WAIT_FAILED) && hash_matches(bad_draft, bad_hash) && hash_matches(source, original),
          "malformed existing draft fails without replacing it or the original media");
    if (host) check(close_host(host), "failed editor still closes and releases the real worker");
    host = mc_video_editor_host_create(source, alias, true, error_text, sizeof error_text);
    check(host && wait_host(host, WAIT_FAILED) && hash_matches(alias, original) && hash_matches(source, original),
          "draft/source identity alias is rejected without overwriting the recording");
    if (host) check(close_host(host), "source-alias failure can be drained and freed");
    if (!save_failure_recovery(source, directory, original)) return 1;
    if (!legacy_migration(source, directory, saved_document)) return 1;
    char *early_draft = g_build_filename(directory, "closed-before-open.json", NULL);
    host = mc_video_editor_host_create(source, early_draft, true, error_text, sizeof error_text);
    check(host && mc_video_editor_host_phase(host) == MC_VIDEO_HOST_OPENING &&
          mc_video_editor_host_request_close(host, true) &&
          mc_video_editor_host_phase(host) == MC_VIDEO_HOST_CLOSING && !mc_video_editor_host_free(host),
          "immediate close keeps ownership while asynchronous probe and draft read are pending");
    if (host) {
        check(wait_host(host, WAIT_CLOSED) && mc_video_editor_host_video(host) == NULL &&
              mc_video_editor_host_free(host) && !g_file_test(early_draft, G_FILE_TEST_EXISTS),
              "early close drains outstanding work and never creates a replacement draft");
    }
    g_free(early_draft);
    check(default_dispatches == 0, "host tick never dispatches unrelated default-context callbacks");
    g_source_remove(sentinel);
    check(hash_matches(source, original), "all preview, draft, chooser and export paths preserve original media bytes");
    g_free(original); g_free(saved_document); g_free(disk_document); g_free(draft_hash); g_free(reopened); g_free(bad_hash);
    g_free(directory); g_free(source); g_free(draft); g_free(output); g_free(alias); g_free(bad_draft);
    printf("video-editor-host: %d failure(s)\n", failures);
    return failures ? 1 : 0;
}
