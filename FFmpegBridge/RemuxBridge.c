//
//  RemuxBridge.c
//  VYRA — in-process MP4 remux (stream copy) over libavformat.
//
//  Merges a video-only MP4 (avc1) and an audio-only M4A (AAC) into a
//  single MP4, the equivalent of `ffmpeg -i video -i audio -c copy`.
//  Timestamp handling mirrors the ffmpeg CLI: each input is shifted
//  by its container start_time (normally zero for YouTube formats),
//  and everything else — leading negative DTS from B-frame reorder
//  or AAC priming — is passed through untouched, because the MP4
//  muxer records those initial offsets as edit lists and players
//  honour them. (Verified against `ffmpeg -c copy`: identical track
//  start times and durations.) Packets from the two inputs are
//  interleaved by timestamp before writing.
//

#include "RemuxBridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavformat/avio.h"
#include "libavutil/error.h"
#include "libavutil/mem.h"

struct vyra_remux_context {
    volatile int cancelled;
};

vyra_remux_context *vyra_remux_create(void) {
    vyra_remux_context *context = malloc(sizeof(*context));
    if (context) {
        context->cancelled = 0;
    }
    return context;
}

void vyra_remux_destroy(vyra_remux_context *context) {
    free(context);
}

void vyra_remux_cancel(vyra_remux_context *context) {
    if (context) {
        context->cancelled = 1;
    }
}

static int interrupt_callback(void *opaque) {
    vyra_remux_context *context = opaque;
    return context && context->cancelled;
}

static int fail(char *error_buffer, int error_buffer_size,
                const char *stage, int code) {
    if (error_buffer && error_buffer_size > 0) {
        if (code < 0) {
            char av_error[AV_ERROR_MAX_STRING_SIZE];
            if (av_strerror(code, av_error, sizeof(av_error)) == 0) {
                snprintf(error_buffer, (size_t)error_buffer_size,
                         "%s: %s", stage, av_error);
            } else {
                snprintf(error_buffer, (size_t)error_buffer_size,
                         "%s: FFmpeg error %d", stage, code);
            }
        } else {
            snprintf(error_buffer, (size_t)error_buffer_size, "%s", stage);
        }
        error_buffer[error_buffer_size - 1] = '\0';
    }
    return -1;
}

/// One input file contributing exactly one stream to the output.
typedef struct {
    AVFormatContext *format;
    AVStream *in_stream;
    AVStream *out_stream;
    AVPacket *pending;
    int have_pending;
    int finished;
    /// Set when track_open fully succeeded. In single-input mode a
    /// track whose stream type is absent from the file stays
    /// inactive and is skipped everywhere.
    int active;
    /// Container start_time of the input, in AV_TIME_BASE units
    /// (0 when unknown). Subtracted from packet timestamps, like
    /// the ffmpeg CLI's per-input ts_offset.
    int64_t start_offset_us;
} remux_track;

static void track_close(remux_track *track) {
    if (track->pending) {
        av_packet_free(&track->pending);
    }
    if (track->format) {
        avformat_close_input(&track->format);
    }
}

/// Opens one input, selects its best stream of `type`, and creates
/// the matching output stream. Returns 0 or an AVERROR code; `stage`
/// is filled with the failing step for error reporting.
static int track_open(remux_track *track, vyra_remux_context *context,
                      const char *path, enum AVMediaType type,
                      AVFormatContext *out_format, const char **stage) {
    int ret;
    AVFormatContext *format = avformat_alloc_context();
    if (!format) {
        *stage = "allocating input context";
        return AVERROR(ENOMEM);
    }
    format->interrupt_callback.callback = interrupt_callback;
    format->interrupt_callback.opaque = context;

    ret = avformat_open_input(&format, path, NULL, NULL);
    if (ret < 0) {
        *stage = (type == AVMEDIA_TYPE_VIDEO)
                     ? "opening video input"
                     : "opening audio input";
        avformat_free_context(format);
        return ret;
    }
    track->format = format;

    ret = avformat_find_stream_info(format, NULL);
    if (ret < 0) {
        *stage = "reading stream info";
        return ret;
    }
    ret = av_find_best_stream(format, type, -1, -1, NULL, 0);
    if (ret < 0) {
        *stage = (type == AVMEDIA_TYPE_VIDEO)
                     ? "finding video stream"
                     : "finding audio stream";
        return ret;
    }
    track->in_stream = format->streams[ret];

    AVStream *out_stream = avformat_new_stream(out_format, NULL);
    if (!out_stream) {
        *stage = "allocating output stream";
        return AVERROR(ENOMEM);
    }
    track->out_stream = out_stream;
    ret = avcodec_parameters_copy(out_stream->codecpar,
                                  track->in_stream->codecpar);
    if (ret < 0) {
        *stage = "copying codec parameters";
        return ret;
    }
    // Let the MP4 muxer choose the right codec tag for the container.
    out_stream->codecpar->codec_tag = 0;

    track->start_offset_us = format->start_time == AV_NOPTS_VALUE
                                 ? 0
                                 : format->start_time;
    track->pending = av_packet_alloc();
    if (!track->pending) {
        *stage = "allocating packet";
        return AVERROR(ENOMEM);
    }
    track->active = 1;
    return 0;
}

/// Reads packets from the track's input until one belongs to the
/// selected stream (stored in track->pending) or the input ends.
static int track_fill(remux_track *track) {
    if (track->have_pending || track->finished) {
        return 0;
    }
    for (;;) {
        int ret = av_read_frame(track->format, track->pending);
        if (ret < 0) {
            track->finished = 1;
            return (ret == AVERROR_EOF) ? 0 : ret;
        }
        if (track->pending->stream_index == track->in_stream->index) {
            track->have_pending = 1;
            return 0;
        }
        av_packet_unref(track->pending);
    }
}

/// The timestamp used to order one pending packet against the other
/// track's: its DTS (falling back to PTS), normalized to microseconds.
static int64_t track_order_key(const remux_track *track) {
    const AVPacket *packet = track->pending;
    int64_t ts = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
    if (ts == AV_NOPTS_VALUE) {
        return INT64_MIN;
    }
    return av_rescale_q(ts, track->in_stream->time_base, AV_TIME_BASE_Q)
           - track->start_offset_us;
}

static int remux_impl(vyra_remux_context *context,
                      const char *video_path,
                      const char *audio_path,
                      const char *output_path,
                      char *error_buffer,
                      int error_buffer_size,
                      int single_input) {
    remux_track tracks[2];
    memset(tracks, 0, sizeof(tracks));
    AVFormatContext *out_format = NULL;
    const char *stage = "allocating output context";
    int ret;

    ret = avformat_alloc_output_context2(&out_format, NULL, "mp4", output_path);
    if (ret < 0 || !out_format) {
        ret = fail(error_buffer, error_buffer_size, stage,
                   ret < 0 ? ret : AVERROR(ENOMEM));
        goto cleanup;
    }
    out_format->interrupt_callback.callback = interrupt_callback;
    out_format->interrupt_callback.opaque = context;

    // Single-input mode opens the same file twice (one reader per
    // stream type, each filtering its own stream — the interleave
    // loop below merges them by timestamp exactly like the pair
    // case). A stream type the file does not have is tolerated
    // there; in pair mode both inputs must deliver their stream.
    ret = track_open(&tracks[0], context, video_path, AVMEDIA_TYPE_VIDEO,
                     out_format, &stage);
    if (ret < 0 && !single_input) {
        ret = fail(error_buffer, error_buffer_size, stage, ret);
        goto cleanup;
    }
    int video_error = tracks[0].active ? 0 : ret;
    const char *video_stage = stage;
    ret = track_open(&tracks[1], context, audio_path, AVMEDIA_TYPE_AUDIO,
                     out_format, &stage);
    if (ret < 0 && !single_input) {
        ret = fail(error_buffer, error_buffer_size, stage, ret);
        goto cleanup;
    }
    if (!tracks[0].active && !tracks[1].active) {
        // Neither stream could be opened: report the first failure.
        if (video_error) {
            ret = fail(error_buffer, error_buffer_size, video_stage, video_error);
        } else {
            ret = fail(error_buffer, error_buffer_size, stage, ret);
        }
        goto cleanup;
    }

    if (!(out_format->oformat->flags & AVFMT_NOFILE)) {
        AVIOInterruptCB io_interrupt = { interrupt_callback, context };
        ret = avio_open2(&out_format->pb, output_path, AVIO_FLAG_WRITE,
                         &io_interrupt, NULL);
        if (ret < 0) {
            ret = fail(error_buffer, error_buffer_size, "opening output file", ret);
            goto cleanup;
        }
    }

    ret = avformat_write_header(out_format, NULL);
    if (ret < 0) {
        ret = fail(error_buffer, error_buffer_size, "writing header", ret);
        goto cleanup;
    }

    for (;;) {
        if (context && context->cancelled) {
            ret = 1; // cancelled
            goto cleanup;
        }
        // Refill both pending slots, then write whichever packet
        // comes first in time — av_interleaved_write_frame expects
        // roughly chronological delivery across streams.
        remux_track *next = NULL;
        for (int i = 0; i < 2; i++) {
            if (!tracks[i].active) {
                continue;
            }
            ret = track_fill(&tracks[i]);
            if (ret < 0) {
                ret = fail(error_buffer, error_buffer_size,
                           "reading input", ret);
                goto cleanup;
            }
            if (!tracks[i].have_pending) {
                continue;
            }
            if (!next || track_order_key(&tracks[i]) < track_order_key(next)) {
                next = &tracks[i];
            }
        }
        if (!next) {
            break; // both inputs exhausted
        }

        AVPacket *packet = next->pending;
        if (packet->pts == AV_NOPTS_VALUE) {
            packet->pts = packet->dts;
        }
        if (packet->dts == AV_NOPTS_VALUE) {
            packet->dts = packet->pts;
        }
        if (next->start_offset_us != 0) {
            int64_t offset = av_rescale_q(next->start_offset_us,
                                          AV_TIME_BASE_Q,
                                          next->in_stream->time_base);
            if (packet->pts != AV_NOPTS_VALUE) {
                packet->pts -= offset;
            }
            if (packet->dts != AV_NOPTS_VALUE) {
                packet->dts -= offset;
            }
        }
        av_packet_rescale_ts(packet, next->in_stream->time_base,
                             next->out_stream->time_base);
        packet->pos = -1;
        packet->stream_index = next->out_stream->index;
        next->have_pending = 0;

        ret = av_interleaved_write_frame(out_format, packet);
        // av_interleaved_write_frame takes ownership of the packet.
        if (ret < 0) {
            ret = fail(error_buffer, error_buffer_size, "writing packet", ret);
            goto cleanup;
        }
    }

    ret = av_write_trailer(out_format);
    if (ret < 0) {
        ret = fail(error_buffer, error_buffer_size, "writing trailer", ret);
        goto cleanup;
    }
    ret = 0;

cleanup:
    if (out_format) {
        if (out_format->pb) {
            avio_closep(&out_format->pb);
        }
        avformat_free_context(out_format);
    }
    track_close(&tracks[0]);
    track_close(&tracks[1]);
    return ret;
}

int vyra_remux_run(vyra_remux_context *context,
                   const char *video_path,
                   const char *audio_path,
                   const char *output_path,
                   char *error_buffer,
                   int error_buffer_size) {
    return remux_impl(context, video_path, audio_path, output_path,
                      error_buffer, error_buffer_size, 0);
}

int vyra_remux_run_single(vyra_remux_context *context,
                          const char *input_path,
                          const char *output_path,
                          char *error_buffer,
                          int error_buffer_size) {
    return remux_impl(context, input_path, input_path, output_path,
                      error_buffer, error_buffer_size, 1);
}
