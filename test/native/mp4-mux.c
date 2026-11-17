#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include "platform/shared/media/mp4_mux.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <direct.h>
#include <io.h>
#define file_seek _fseeki64
#define file_tell _ftelli64
#define make_directory(path) _mkdir(path)
#else
#include <unistd.h>
#define file_seek fseeko
#define file_tell ftello
#define make_directory(path) mkdir(path, 0700)
#endif

#include <libavcodec/packet.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/sha.h>

/* This fixture deliberately uses custom AVIO too: the official SDK does not
 * ship FFmpeg's file protocol. No command-line encoder or decoder is needed. */
typedef struct {
    AVRational time_base;
    enum AVMediaType type;
    enum AVCodecID codec;
    int sample_rate;
    AVPacket **packets;
    size_t count;
} PacketStream;

typedef struct {
    PacketStream streams[2];
    unsigned count;
} PacketFile;

static void require(bool condition, const char *format, ...) {
    if (condition) return;
    va_list args;
    va_start(args, format);
    fputs("MP4 mux fixture FAILED: ", stderr);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    va_end(args);
    exit(1);
}

static bool exists(const char *path) {
#ifdef _WIN32
    struct __stat64 status;
    return _stat64(path, &status) == 0;
#else
    struct stat status;
    return stat(path, &status) == 0;
#endif
}

static void path_join(char *out, size_t capacity, const char *directory, const char *name) {
    int size = snprintf(out, capacity, "%s/%s", directory, name);
    require(size > 0 && (size_t)size < capacity, "output path is too long");
}

static FILE *open_file(const char *path, const char *mode) {
#ifdef _WIN32
    FILE *file = NULL;
    return fopen_s(&file, path, mode) == 0 ? file : NULL;
#else
    return fopen(path, mode);
#endif
}

static void file_digest(const char *path, uint8_t digest[32]) {
    FILE *file = open_file(path, "rb");
    struct AVSHA *sha = av_sha_alloc();
    require(file && sha && av_sha_init(sha, 256) == 0, "cannot hash %s", path);
    uint8_t bytes[16384];
    size_t count;
    while ((count = fread(bytes, 1, sizeof(bytes), file)) != 0)
        av_sha_update(sha, bytes, count);
    require(!ferror(file), "read failed while hashing %s", path);
    require(fclose(file) == 0, "cannot close hash input");
    av_sha_final(sha, digest);
    av_free(sha);
}

static void unchanged(const char *path, const uint8_t expected[32], const char *phase) {
    uint8_t digest[32];
    file_digest(path, digest);
    require(memcmp(digest, expected, sizeof(digest)) == 0,
            "%s modified existing file %s", phase, path);
}

static int read_bytes(void *opaque, uint8_t *buffer, int size) {
    FILE *file = opaque;
    size_t count = fread(buffer, 1, (size_t)size, file);
    if (count) return (int)count;
    return ferror(file) ? AVERROR(EIO) : AVERROR_EOF;
}

static int64_t seek_bytes(void *opaque, int64_t offset, int whence) {
    FILE *file = opaque;
    if (whence & AVSEEK_SIZE) {
        int64_t original = file_tell(file);
        if (original < 0 || file_seek(file, 0, SEEK_END) != 0) return AVERROR(EIO);
        int64_t size = file_tell(file);
        if (file_seek(file, original, SEEK_SET) != 0) return AVERROR(EIO);
        return size < 0 ? AVERROR(EIO) : size;
    }
    if (file_seek(file, offset, whence & ~AVSEEK_FORCE) != 0) return AVERROR(errno);
    int64_t position = file_tell(file);
    return position < 0 ? AVERROR(EIO) : position;
}

static PacketFile read_packets(const char *path) {
    PacketFile result = {0};
    FILE *file = open_file(path, "rb");
    require(file != NULL, "cannot open packet input %s", path);
    uint8_t *buffer = av_malloc(32768);
    require(buffer != NULL, "cannot allocate AVIO buffer");
    AVIOContext *io = avio_alloc_context(buffer, 32768, 0, file, read_bytes, NULL, seek_bytes);
    AVFormatContext *format = avformat_alloc_context();
    require(io && format, "cannot allocate demux context");
    format->pb = io;
    format->flags |= AVFMT_FLAG_CUSTOM_IO;
    int status = avformat_open_input(&format, NULL, av_find_input_format("mov"), NULL);
    require(status >= 0, "custom AVIO could not open %s (%d)", path, status);
    require(avformat_find_stream_info(format, NULL) >= 0, "cannot inspect %s", path);
    require(format->nb_streams == 2, "fixture input must have one H.264 and one AAC stream");
    result.count = format->nb_streams;
    for (unsigned i = 0; i < result.count; ++i) {
        AVStream *stream = format->streams[i];
        result.streams[i].time_base = stream->time_base;
        result.streams[i].type = stream->codecpar->codec_type;
        result.streams[i].codec = stream->codecpar->codec_id;
        result.streams[i].sample_rate = stream->codecpar->sample_rate;
    }
    AVPacket *packet = av_packet_alloc();
    require(packet != NULL, "cannot allocate packet");
    while ((status = av_read_frame(format, packet)) >= 0) {
        require(packet->stream_index >= 0 && (unsigned)packet->stream_index < result.count,
                "invalid stream index");
        PacketStream *stream = &result.streams[packet->stream_index];
        require(stream->count < 1000000, "fixture input exceeds packet limit");
        AVPacket **packets = av_realloc_array(stream->packets, stream->count + 1, sizeof(*packets));
        require(packets != NULL, "cannot retain packet list");
        stream->packets = packets;
        stream->packets[stream->count] = av_packet_clone(packet);
        require(stream->packets[stream->count] != NULL, "cannot retain packet");
        ++stream->count;
        av_packet_unref(packet);
    }
    require(status == AVERROR_EOF, "packet read failed (%d)", status);
    av_packet_free(&packet);
    avformat_close_input(&format);
    av_freep(&io->buffer);
    avio_context_free(&io);
    require(fclose(file) == 0, "cannot close packet input");
    return result;
}

static void free_packets(PacketFile *file) {
    for (unsigned i = 0; i < file->count; ++i) {
        PacketStream *stream = &file->streams[i];
        for (size_t j = 0; j < stream->count; ++j) av_packet_free(&stream->packets[j]);
        av_freep(&stream->packets);
    }
    memset(file, 0, sizeof(*file));
}

static void compare_packets(const PacketFile *source, const char *path) {
    PacketFile output = read_packets(path);
    require(output.count == source->count, "stream count changed");
    unsigned videos = 0, audios = 0;
    for (unsigned i = 0; i < source->count; ++i) {
        const PacketStream *before = &source->streams[i], *after = &output.streams[i];
        require(after->type == before->type && after->codec == before->codec,
                "stream %u codec/order changed", i);
        require(before->count > 0 && before->count == after->count,
                "stream %u packet count changed: %zu -> %zu", i, before->count, after->count);
        int64_t shift = 0;
        if (before->type == AVMEDIA_TYPE_VIDEO) {
            ++videos;
            require(before->codec == AV_CODEC_ID_H264, "input video is not H.264");
        } else {
            ++audios;
            require(before->type == AVMEDIA_TYPE_AUDIO && before->codec == AV_CODEC_ID_AAC &&
                    before->sample_rate == 48000 && after->sample_rate == 48000,
                    "input audio must be 48 kHz AAC");
            shift = av_rescale_q(1024, (AVRational){1, 48000}, before->time_base);
            require(av_compare_ts(shift, before->time_base, 1024, (AVRational){1, 48000}) == 0,
                    "input timebase cannot express exact priming");
#if LIBAVCODEC_VERSION_MAJOR >= 59
            size_t side_size = 0;
#else
            int side_size = 0;
#endif
            const uint8_t *side = av_packet_get_side_data(after->packets[0],
                                                        AV_PKT_DATA_SKIP_SAMPLES, &side_size);
            require(side && side_size >= 10 && AV_RL32(side) == 1024,
                    "first AAC packet must retain priming and advertise skip_samples=1024");
            require(before->packets[0]->pts == 0 && before->packets[0]->dts == 0,
                    "fixture input is already shifted");
        }
        for (size_t j = 0; j < before->count; ++j) {
            const AVPacket *a = before->packets[j], *b = after->packets[j];
            require(a->size == b->size && (a->size == 0 || memcmp(a->data, b->data, (size_t)a->size) == 0),
                    "compressed payload changed in stream %u packet %zu", i, j);
            require(a->pts != AV_NOPTS_VALUE && a->dts != AV_NOPTS_VALUE &&
                    b->pts != AV_NOPTS_VALUE && b->dts != AV_NOPTS_VALUE,
                    "missing packet timestamp in stream %u packet %zu", i, j);
            require(av_compare_ts(a->pts - shift, before->time_base, b->pts, after->time_base) == 0 &&
                    av_compare_ts(a->dts - shift, before->time_base, b->dts, after->time_base) == 0,
                    "unexpected PTS/DTS change in stream %u packet %zu", i, j);
            require(av_compare_ts(a->duration, before->time_base, b->duration, after->time_base) == 0,
                    "packet duration changed in stream %u packet %zu", i, j);
        }
        printf("stream %u: %zu compressed packets preserved with exact %s timestamps\n",
               i, before->count, shift ? "AAC priming-shifted" : "video");
    }
    require(videos == 1 && audios == 1, "fixture requires one video and one audio stream");
    free_packets(&output);
}

typedef struct {
    const char *output;
    bool saw_created_output;
} CancelAfterCreate;

static bool cancel_after_create(void *opaque) {
    CancelAfterCreate *cancel = opaque;
    if (exists(cancel->output)) cancel->saw_created_output = true;
    return cancel->saw_created_output;
}

static void make_collision(const char *path) {
    static const char bytes[] = "Existing user output: must not be replaced or removed.\n";
    FILE *file = open_file(path, "wbx");
    require(file != NULL, "collision fixture must be a new file: %s", path);
    require(fwrite(bytes, 1, sizeof(bytes), file) == sizeof(bytes), "cannot write collision fixture");
    require(fclose(file) == 0, "cannot close collision fixture");
}

int main(int argc, char **argv) {
    require(argc == 3, "usage: mp4-mux input_tmp_mp4 new_output_directory");
    if (make_directory(argv[2]) != 0) require(errno == EEXIST, "cannot create output directory");
    char success[4096], collision[4096], cancelled[4096], twice[4096], error[512];
    path_join(success, sizeof(success), argv[2], "copied.mp4");
    path_join(collision, sizeof(collision), argv[2], "existing.mp4");
    path_join(cancelled, sizeof(cancelled), argv[2], "cancel-then-recover.mp4");
    path_join(twice, sizeof(twice), argv[2], "twice.mp4");
    require(!exists(success) && !exists(collision) && !exists(cancelled) && !exists(twice),
            "use an output directory without previous fixture files");

    uint8_t input_digest[32], existing_digest[32], successful_digest[32];
    file_digest(argv[1], input_digest);
    PacketFile input = read_packets(argv[1]);
    require(mc_mp4_mux_copy(argv[1], success, 1024, NULL, NULL, error, sizeof(error)),
            "initial copy failed: %s", error);
    require(error[0] == '\0', "successful copy left an error");
    compare_packets(&input, success);
    unchanged(argv[1], input_digest, "successful copy");

    make_collision(collision);
    file_digest(collision, existing_digest);
    require(!mc_mp4_mux_copy(argv[1], collision, 1024, NULL, NULL, error, sizeof(error)) && error[0],
            "existing output was not rejected");
    unchanged(collision, existing_digest, "exclusive-create failure");
    unchanged(argv[1], input_digest, "exclusive-create failure");

    CancelAfterCreate cancel = {cancelled, false};
    require(!mc_mp4_mux_copy(argv[1], cancelled, 1024, cancel_after_create, &cancel, error, sizeof(error)),
            "cancellation incorrectly succeeded");
    require(cancel.saw_created_output, "cancellation did not happen after real output creation");
    require(strstr(error, "cancelled") != NULL && !exists(cancelled),
            "cancelled operation left its temporary output or lost cancellation error: %s", error);
    unchanged(argv[1], input_digest, "cancellation");
    unchanged(collision, existing_digest, "cancellation");
    require(mc_mp4_mux_copy(argv[1], cancelled, 1024, NULL, NULL, error, sizeof(error)),
            "same-process/same-path recovery failed: %s", error);
    compare_packets(&input, cancelled);

    file_digest(success, successful_digest);
    require(!mc_mp4_mux_copy(success, twice, 1024, NULL, NULL, error, sizeof(error)),
            "already compensated input was accepted twice");
    require(strstr(error, "already compensated") != NULL && !exists(twice),
            "second compensation left output or gave wrong error: %s", error);
    unchanged(success, successful_digest, "second-compensation rejection");
    unchanged(argv[1], input_digest, "all operations");
    unchanged(collision, existing_digest, "all operations");
    free_packets(&input);
    puts("MP4 packet preservation, exact priming, collision, cancellation, recovery and ownership checks passed.");
    return 0;
}
