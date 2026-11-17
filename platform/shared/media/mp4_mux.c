#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include "mp4_mux.h"

#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <windows.h>
#include <io.h>
#include <share.h>
#else
#include <unistd.h>
#endif

#include <libavcodec/codec_id.h>
#include <libavcodec/codec_par.h>
#include <libavcodec/packet.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>

typedef struct {
    int fd;
    bool (*cancel)(void *);
    void *context;
} MCMuxIO;

static bool cancelled(MCMuxIO *io) {
    return io->cancel && io->cancel(io->context);
}

#ifdef _WIN32
static wchar_t *wide_path(const char *path) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (n <= 0) { errno = EINVAL; return NULL; }
    wchar_t *wide = av_malloc_array((size_t)n, sizeof(*wide));
    if (!wide) { errno = ENOMEM; return NULL; }
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, n)) {
        av_free(wide); errno = EINVAL; return NULL;
    }
    return wide;
}
static int open_file(const char *path, bool output) {
    wchar_t *wide = wide_path(path);
    if (!wide) return -1;
    int fd = -1;
    int flags = _O_BINARY | (output ? _O_WRONLY | _O_CREAT | _O_EXCL : _O_RDONLY);
    errno_t result = _wsopen_s(&fd, wide, flags, _SH_DENYWR, _S_IREAD | _S_IWRITE);
    av_free(wide);
    if (result) { errno = (int)result; return -1; }
    return fd;
}
static void remove_file(const char *path) {
    wchar_t *wide = wide_path(path);
    if (wide) { _wunlink(wide); av_free(wide); }
}
#define mc_close _close
#define mc_sync _commit
#define mc_read _read
#define mc_write _write
#define mc_seek _lseeki64
#else
static int open_file(const char *path, bool output) {
    int flags = O_CLOEXEC | (output ? O_WRONLY | O_CREAT | O_EXCL : O_RDONLY);
    return open(path, flags, 0600);
}
static void remove_file(const char *path) { (void)unlink(path); }
#define mc_close close
#define mc_sync fsync
#define mc_read read
#define mc_write write
#define mc_seek lseek
#endif

static int read_packet(void *opaque, uint8_t *buffer, int size) {
    MCMuxIO *io = opaque;
    if (cancelled(io)) return AVERROR_EXIT;
    int n;
    do { n = (int)mc_read(io->fd, buffer, (unsigned)size); } while (n < 0 && errno == EINTR);
    return n < 0 ? AVERROR(errno) : n == 0 ? AVERROR_EOF : n;
}

#if LIBAVFORMAT_VERSION_MAJOR >= 61
static int write_packet(void *opaque, const uint8_t *buffer, int size) {
#else
/* FFmpeg 4.4–6.x does not const-qualify the callback's read-only input. */
static int write_packet(void *opaque, uint8_t *buffer, int size) {
#endif
    MCMuxIO *io = opaque;
    int written = 0;
    while (written < size) {
        if (cancelled(io)) return AVERROR_EXIT;
        int n = (int)mc_write(io->fd, buffer + written, (unsigned)(size - written));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return AVERROR(n < 0 ? errno : EIO);
        written += n;
    }
    return written;
}

static int64_t seek_file(void *opaque, int64_t offset, int whence) {
    MCMuxIO *io = opaque;
    if (cancelled(io)) return AVERROR_EXIT;
    if (whence & AVSEEK_SIZE) {
#ifdef _WIN32
        struct _stati64 status;
        if (_fstati64(io->fd, &status)) return AVERROR(errno);
#else
        struct stat status;
        if (fstat(io->fd, &status)) return AVERROR(errno);
#endif
        return status.st_size;
    }
    int64_t result = mc_seek(io->fd, offset, whence & ~AVSEEK_FORCE);
    return result < 0 ? AVERROR(errno) : result;
}

static AVIOContext *make_io(MCMuxIO *io, bool output) {
    unsigned char *buffer = av_malloc(32768);
    if (!buffer) return NULL;
    AVIOContext *avio = avio_alloc_context(buffer, 32768, output, io,
        output ? NULL : read_packet, output ? write_packet : NULL, seek_file);
    if (!avio) av_free(buffer);
    return avio;
}

static void free_io(AVIOContext **avio) {
    if (*avio) av_freep(&(*avio)->buffer);
    avio_context_free(avio);
}

bool mc_mp4_mux_copy(const char *input_path, const char *new_temporary_path,
                     int aac_priming_samples, bool (*cancel)(void *), void *context,
                     char *error, size_t error_capacity) {
    MCMuxIO input = {-1, cancel, context}, output = {-1, cancel, context};
    AVFormatContext *demux = NULL, *mux = NULL;
    AVIOContext *input_io = NULL, *output_io = NULL;
    AVPacket *packet = NULL;
    AVDictionary *options = NULL;
    int result = AVERROR(EINVAL), audio_index = -1;
    int64_t priming_ticks = 0;
    bool created_output = false, success = false, first_audio = true;
    const char *step = "Invalid MP4 remux request";
    if (error && error_capacity) error[0] = '\0';
    if (!input_path || !input_path[0] || !new_temporary_path || !new_temporary_path[0] ||
        aac_priming_samples < 0) goto done;
    step = "MP4 remux cancelled";
    if (cancelled(&input)) { result = AVERROR_EXIT; goto done; }
    step = "Cannot open encoded MP4 input";
    input.fd = open_file(input_path, false);
    if (input.fd < 0) { result = AVERROR(errno); goto done; }
    input_io = make_io(&input, false);
    demux = avformat_alloc_context();
    if (!input_io || !demux) { result = AVERROR(ENOMEM); goto done; }
    demux->pb = input_io;
    demux->flags |= AVFMT_FLAG_CUSTOM_IO;
    result = avformat_open_input(&demux, NULL, av_find_input_format("mov"), NULL);
    if (result < 0) goto done;
    result = avformat_find_stream_info(demux, NULL);
    if (result < 0) goto done;
    step = "Expected backend H.264 and optional AAC streams";
    result = AVERROR(EINVAL);
    if (demux->nb_streams < 1 || demux->nb_streams > 2) goto done;
    int videos = 0;
    for (unsigned i = 0; i < demux->nb_streams; ++i) {
        const AVCodecParameters *codec = demux->streams[i]->codecpar;
        if (codec->codec_type == AVMEDIA_TYPE_VIDEO && codec->codec_id == AV_CODEC_ID_H264) {
            ++videos;
        } else if (codec->codec_type == AVMEDIA_TYPE_AUDIO && codec->codec_id == AV_CODEC_ID_AAC && audio_index < 0) {
            audio_index = (int)i;
            if (codec->sample_rate <= 0 || aac_priming_samples > codec->sample_rate) goto done;
            priming_ticks = av_rescale_q(aac_priming_samples,
                (AVRational){1, codec->sample_rate}, demux->streams[i]->time_base);
            if (av_compare_ts(priming_ticks, demux->streams[i]->time_base,
                             aac_priming_samples, (AVRational){1, codec->sample_rate}) != 0) goto done;
        } else goto done;
    }
    if (videos != 1 || (audio_index < 0 && aac_priming_samples != 0)) goto done;
    step = "Cannot create MP4 muxer";
    result = avformat_alloc_output_context2(&mux, NULL, "mp4", NULL);
    if (result < 0 || !mux) { if (result >= 0) result = AVERROR(ENOMEM); goto done; }
    for (unsigned i = 0; i < demux->nb_streams; ++i) {
        AVStream *stream = avformat_new_stream(mux, NULL);
        if (!stream) { result = AVERROR(ENOMEM); goto done; }
        result = avcodec_parameters_copy(stream->codecpar, demux->streams[i]->codecpar);
        if (result < 0) goto done;
        stream->codecpar->codec_tag = 0;
        stream->time_base = demux->streams[i]->time_base;
        stream->avg_frame_rate = demux->streams[i]->avg_frame_rate;
    }
    packet = av_packet_alloc();
    if (!packet) { result = AVERROR(ENOMEM); goto done; }
    step = "Cannot exclusively create temporary MP4";
    output.fd = open_file(new_temporary_path, true);
    if (output.fd < 0) { result = AVERROR(errno); goto done; }
    created_output = true;
    output_io = make_io(&output, true);
    if (!output_io) { result = AVERROR(ENOMEM); goto done; }
    mux->pb = output_io;
    mux->flags |= AVFMT_FLAG_CUSTOM_IO;
    /* The public avoid_negative_ts option uses 0 for disabled, including
     * FFmpeg 4.4, whose headers do not yet name that value. Keep AAC preroll. */
    mux->avoid_negative_ts = 0;
    result = av_dict_set(&options, "use_editlist", "1", 0);
    if (result < 0) goto done;
    step = "Cannot write MP4 header";
    result = avformat_write_header(mux, &options);
    av_dict_free(&options);
    if (result < 0) goto done;
    step = "Cannot copy encoded MP4 packets";
    for (;;) {
        if (cancelled(&input)) { result = AVERROR_EXIT; goto done; }
        result = av_read_frame(demux, packet);
        if (result == AVERROR_EOF) break;
        if (result < 0) goto done;
        if (packet->stream_index < 0 || (unsigned)packet->stream_index >= demux->nb_streams) {
            result = AVERROR_INVALIDDATA; goto done;
        }
        AVStream *source = demux->streams[packet->stream_index];
        AVStream *target = mux->streams[packet->stream_index];
        if (packet->stream_index == audio_index && priming_ticks) {
            /* Reject an already compensated input: applying priming twice
             * would erase real content. This API is not an import normalizer. */
            if (first_audio && (packet->pts != 0 || packet->dts != 0 ||
                av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, NULL))) {
                step = "AAC input already compensated or does not start at zero";
                result = AVERROR_INVALIDDATA; goto done;
            }
            first_audio = false;
            if (packet->pts == AV_NOPTS_VALUE || packet->dts == AV_NOPTS_VALUE ||
                packet->pts < INT64_MIN + priming_ticks || packet->dts < INT64_MIN + priming_ticks) {
                result = AVERROR_INVALIDDATA; goto done;
            }
            packet->pts -= priming_ticks;
            packet->dts -= priming_ticks;
        }
        av_packet_rescale_ts(packet, source->time_base, target->time_base);
        packet->pos = -1;
        result = av_interleaved_write_frame(mux, packet);
        av_packet_unref(packet);
        if (result < 0) goto done;
    }
    if (audio_index >= 0 && priming_ticks && first_audio) { result = AVERROR_INVALIDDATA; goto done; }
    step = "Cannot finalize MP4";
    result = av_write_trailer(mux);
    if (result < 0) goto done;
    avio_flush(output_io);
    if (output_io->error < 0) { result = output_io->error; goto done; }
    if (cancelled(&output)) { result = AVERROR_EXIT; goto done; }
    if (mc_sync(output.fd)) { result = AVERROR(errno); goto done; }
    success = true;
done:
    av_dict_free(&options);
    av_packet_free(&packet);
    avformat_close_input(&demux);
    avformat_free_context(mux);
    free_io(&input_io);
    free_io(&output_io);
    if (input.fd >= 0) (void)mc_close(input.fd);
    if (output.fd >= 0 && mc_close(output.fd) != 0 && success) {
        success = false; result = AVERROR(errno); step = "Cannot close temporary MP4";
    }
    if (!success && created_output) remove_file(new_temporary_path);
    if (!success && error && error_capacity) {
        char detail[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(result, detail, sizeof(detail));
        snprintf(error, error_capacity, "%s: %s", result == AVERROR_EXIT ? "MP4 remux cancelled" : step, detail);
    }
    return success;
}
