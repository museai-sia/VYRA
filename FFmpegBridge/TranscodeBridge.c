//
//  TranscodeBridge.c
//  VYRA — in-process transcode over the bundled FFmpeg libraries.
//
//  Decodes a downloaded format that cannot be stream-copied into a
//  playable MP4 (VP9/AV1 video, WebM container, Opus audio, ...) and
//  re-encodes it: video -> H.264 via the VideoToolbox hardware
//  encoder, audio -> AAC via FFmpeg's native encoder. The pipeline
//  follows FFmpeg's canonical decode -> filter -> encode shape:
//  format conversion happens in libavfilter graphs (the `format`
//  filter forces NV12 for VideoToolbox; `aformat` forces FLTP +
//  stereo/mono for the AAC encoder, with libswscale / libswresample
//  auto-inserted for the actual conversion), and the audio encoder
//  is fed fixed-size frames through an AVAudioFifo.
//
//  Inputs may be a split pair (separate video and audio files), one
//  combined file (same path twice), or a single stream only. Packets
//  are fed to the decoders in timestamp order across inputs, like
//  the remux bridge, and written with av_interleaved_write_frame.
//

#include "TranscodeBridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavfilter/avfilter.h"
#include "libavfilter/buffersink.h"
#include "libavfilter/buffersrc.h"
#include "libavformat/avformat.h"
#include "libavformat/avio.h"
#include "libavutil/audio_fifo.h"
#include "libavutil/channel_layout.h"
#include "libavutil/error.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"

struct vyra_transcode_context {
    volatile int cancelled;
};

vyra_transcode_context *vyra_transcode_create(void) {
    vyra_transcode_context *context = malloc(sizeof(*context));
    if (context) {
        context->cancelled = 0;
    }
    return context;
}

void vyra_transcode_destroy(vyra_transcode_context *context) {
    free(context);
}

void vyra_transcode_cancel(vyra_transcode_context *context) {
    if (context) {
        context->cancelled = 1;
    }
}

static int interrupt_callback(void *opaque) {
    vyra_transcode_context *context = opaque;
    return context && context->cancelled;
}

// MARK: - Shared job state

typedef struct {
    AVFormatContext *format;
    AVPacket *pending;
    int have_pending;
    int finished;
    /// Container start_time of the input, in AV_TIME_BASE units
    /// (0 when unknown). Subtracted from packet timestamps, like
    /// the ffmpeg CLI's per-input ts_offset.
    int64_t start_offset_us;
    /// Set once this input's channels have been flushed.
    int flushed;
} transcode_input;

typedef struct {
    enum AVMediaType type;
    transcode_input *input;
    AVStream *in_stream;
    AVCodecContext *dec_ctx;
    AVFilterGraph *graph;
    AVFilterContext *src_ctx;
    AVFilterContext *sink_ctx;
    AVCodecContext *enc_ctx;
    AVStream *out_stream;
    // Video only: the encoder and the pixel format the filter
    // graph converts to (NV12 for VideoToolbox), resolved when the
    // filter graph is built because the graph must produce exactly
    // the format the encoder consumes.
    const AVCodec *video_encoder;
    enum AVPixelFormat video_pix_fmt;
    // Audio only: the AAC encoder consumes fixed-size frames, so
    // filtered frames are re-chunked through a FIFO.
    AVAudioFifo *fifo;
    AVFrame *fifo_frame;
    int64_t fifo_next_pts;
    int flushed;
} transcode_channel;

typedef struct {
    vyra_transcode_context *context;
    AVFormatContext *out_format;
    int64_t total_duration_us;
    int64_t max_processed_us;
    double last_reported_fraction;
    vyra_transcode_progress_callback progress_callback;
    void *progress_opaque;
    const char *stage;
    int error_code;
} transcode_job;

static int job_fail(transcode_job *job, const char *stage, int code) {
    job->stage = stage;
    job->error_code = code;
    return -1;
}

static void job_report_progress(transcode_job *job, const AVPacket *packet) {
    if (!job->progress_callback || job->total_duration_us <= 0) {
        return;
    }
    if (!packet || packet->pts == AV_NOPTS_VALUE) {
        return;
    }
    AVStream *stream = job->out_format->streams[packet->stream_index];
    int64_t end_us = av_rescale_q(packet->pts + (packet->duration > 0 ? packet->duration : 0),
                                  stream->time_base, AV_TIME_BASE_Q);
    if (end_us > job->max_processed_us) {
        job->max_processed_us = end_us;
    }
    double fraction = (double)job->max_processed_us / (double)job->total_duration_us;
    if (fraction > 1.0) {
        fraction = 1.0;
    }
    if (fraction - job->last_reported_fraction >= 0.002 || fraction >= 1.0) {
        job->last_reported_fraction = fraction;
        job->progress_callback(job->progress_opaque, fraction);
    }
}

// MARK: - Encoding

/// Sends one frame (NULL = flush) to the channel's encoder and
/// writes every packet it produces. Returns 0, 1 (cancelled) or -1
/// (error recorded in `job`).
static int encode_write_frame(transcode_channel *channel, AVFrame *frame,
                              transcode_job *job) {
    int ret = avcodec_send_frame(channel->enc_ctx, frame);
    if (ret < 0) {
        return job_fail(job, "sending frame to encoder", ret);
    }
    for (;;) {
        if (job->context && job->context->cancelled) {
            return 1;
        }
        AVPacket *packet = av_packet_alloc();
        if (!packet) {
            return job_fail(job, "allocating packet", AVERROR(ENOMEM));
        }
        ret = avcodec_receive_packet(channel->enc_ctx, packet);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            av_packet_free(&packet);
            return 0;
        }
        if (ret < 0) {
            av_packet_free(&packet);
            return job_fail(job, "receiving packet from encoder", ret);
        }
        av_packet_rescale_ts(packet, channel->enc_ctx->time_base,
                             channel->out_stream->time_base);
        packet->stream_index = channel->out_stream->index;
        job_report_progress(job, packet);
        ret = av_interleaved_write_frame(job->out_format, packet);
        // av_interleaved_write_frame takes ownership of the packet.
        if (ret < 0) {
            return job_fail(job, "writing packet", ret);
        }
    }
}

/// Pushes one filtered audio frame into the FIFO and encodes every
/// complete frame_size chunk. With `flush` set, also encodes the
/// final partial chunk and flushes the encoder.
static int audio_encode(transcode_channel *channel, AVFrame *frame,
                        int flush, transcode_job *job) {
    int ret;
    if (frame) {
        ret = av_audio_fifo_write(channel->fifo,
                                  (void **)frame->extended_data,
                                  frame->nb_samples);
        if (ret < 0) {
            return job_fail(job, "buffering audio samples", ret);
        }
    }
    const int frame_size = channel->enc_ctx->frame_size > 0
                               ? channel->enc_ctx->frame_size
                               : 1024;
    for (;;) {
        int available = av_audio_fifo_size(channel->fifo);
        if (available <= 0 || (!flush && available < frame_size)) {
            break;
        }
        int to_read = available < frame_size ? available : frame_size;
        AVFrame *enc_frame = channel->fifo_frame;
        av_frame_unref(enc_frame);
        enc_frame->format = channel->enc_ctx->sample_fmt;
        enc_frame->sample_rate = channel->enc_ctx->sample_rate;
        ret = av_channel_layout_copy(&enc_frame->ch_layout,
                                     &channel->enc_ctx->ch_layout);
        if (ret < 0) {
            return job_fail(job, "preparing audio frame", ret);
        }
        enc_frame->nb_samples = to_read;
        ret = av_frame_get_buffer(enc_frame, 0);
        if (ret < 0) {
            return job_fail(job, "preparing audio frame", ret);
        }
        ret = av_audio_fifo_read(channel->fifo, (void **)enc_frame->data,
                                 to_read);
        if (ret < 0) {
            return job_fail(job, "reading buffered audio", ret);
        }
        enc_frame->pts = channel->fifo_next_pts;
        channel->fifo_next_pts += to_read;
        ret = encode_write_frame(channel, enc_frame, job);
        if (ret != 0) {
            return ret;
        }
    }
    if (flush) {
        return encode_write_frame(channel, NULL, job);
    }
    return 0;
}

/// Pulls every frame the channel's filter graph currently offers
/// and encodes it. A NULL `frame` result with AVERROR_EOF from the
/// sink means the graph was flushed: the encoder is flushed too.
static int filter_encode(transcode_channel *channel, transcode_job *job) {
    AVFrame *frame = av_frame_alloc();
    if (!frame) {
        return job_fail(job, "allocating frame", AVERROR(ENOMEM));
    }
    int result = 0;
    for (;;) {
        if (job->context && job->context->cancelled) {
            result = 1;
            break;
        }
        int ret = av_buffersink_get_frame(channel->sink_ctx, frame);
        if (ret == AVERROR(EAGAIN)) {
            break;
        }
        if (ret == AVERROR_EOF) {
            if (channel->type == AVMEDIA_TYPE_AUDIO) {
                result = audio_encode(channel, NULL, 1, job);
            } else {
                result = encode_write_frame(channel, NULL, job);
            }
            break;
        }
        if (ret < 0) {
            result = job_fail(job, "reading filtered frame", ret);
            break;
        }
        if (channel->type == AVMEDIA_TYPE_AUDIO) {
            result = audio_encode(channel, frame, 0, job);
        } else {
            // Rebase onto the encoder time_base and the media start:
            // drop the container start_time (like the remux bridge)
            // and never hand the encoder a negative timestamp.
            AVRational sink_tb = av_buffersink_get_time_base(channel->sink_ctx);
            if (frame->pts != AV_NOPTS_VALUE) {
                int64_t pts_us = av_rescale_q(frame->pts, sink_tb, AV_TIME_BASE_Q)
                                 - channel->input->start_offset_us;
                if (pts_us < 0) {
                    pts_us = 0;
                }
                frame->pts = av_rescale_q(pts_us, AV_TIME_BASE_Q,
                                          channel->enc_ctx->time_base);
            }
            result = encode_write_frame(channel, frame, job);
        }
        av_frame_unref(frame);
        if (result != 0) {
            break;
        }
    }
    av_frame_free(&frame);
    return result;
}

/// Decodes one packet (NULL = end of input) and pushes every frame
/// through the filter graph into the encoder.
static int channel_decode(transcode_channel *channel, AVPacket *packet,
                          transcode_job *job) {
    int ret = avcodec_send_packet(channel->dec_ctx, packet);
    if (ret < 0) {
        return job_fail(job, "sending packet to decoder", ret);
    }
    AVFrame *frame = av_frame_alloc();
    if (!frame) {
        return job_fail(job, "allocating frame", AVERROR(ENOMEM));
    }
    int result = 0;
    for (;;) {
        ret = avcodec_receive_frame(channel->dec_ctx, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        }
        if (ret < 0) {
            result = job_fail(job, "receiving frame from decoder", ret);
            break;
        }
        frame->pts = frame->best_effort_timestamp;
        ret = av_buffersrc_add_frame_flags(channel->src_ctx, frame,
                                           AV_BUFFERSRC_FLAG_KEEP_REF);
        av_frame_unref(frame);
        if (ret < 0) {
            result = job_fail(job, "sending frame to filter", ret);
            break;
        }
        result = filter_encode(channel, job);
        if (result != 0) {
            break;
        }
    }
    av_frame_free(&frame);
    if (result == 0 && !packet) {
        // End of input: signal EOF to the filter graph, which makes
        // filter_encode flush the encoder.
        ret = av_buffersrc_add_frame_flags(channel->src_ctx, NULL, 0);
        if (ret < 0) {
            return job_fail(job, "flushing filter", ret);
        }
        result = filter_encode(channel, job);
        if (result == 0) {
            channel->flushed = 1;
        }
    }
    return result;
}

// MARK: - Setup

static int input_open(transcode_input *input, vyra_transcode_context *context,
                      const char *path, const char *kind, transcode_job *job) {
    AVFormatContext *format = avformat_alloc_context();
    if (!format) {
        return job_fail(job, "allocating input context", AVERROR(ENOMEM));
    }
    format->interrupt_callback.callback = interrupt_callback;
    format->interrupt_callback.opaque = context;
    int ret = avformat_open_input(&format, path, NULL, NULL);
    if (ret < 0) {
        avformat_free_context(format);
        return job_fail(job,
                        kind[0] == 'v' ? "opening video input"
                                       : "opening audio input",
                        ret);
    }
    input->format = format;
    ret = avformat_find_stream_info(format, NULL);
    if (ret < 0) {
        return job_fail(job, "reading stream info", ret);
    }
    input->start_offset_us = format->start_time == AV_NOPTS_VALUE
                                 ? 0
                                 : format->start_time;
    input->pending = av_packet_alloc();
    if (!input->pending) {
        return job_fail(job, "allocating packet", AVERROR(ENOMEM));
    }
    return 0;
}

static int channel_open_decoder(transcode_channel *channel, transcode_job *job) {
    AVFormatContext *format = channel->input->format;
    int ret = av_find_best_stream(format, channel->type, -1, -1, NULL, 0);
    if (ret < 0) {
        return job_fail(job,
                        channel->type == AVMEDIA_TYPE_VIDEO
                            ? "finding video stream"
                            : "finding audio stream",
                        ret);
    }
    channel->in_stream = format->streams[ret];
    const AVCodec *decoder = avcodec_find_decoder(
        channel->in_stream->codecpar->codec_id);
    if (!decoder) {
        return job_fail(job, "finding decoder", AVERROR_DECODER_NOT_FOUND);
    }
    AVCodecContext *dec_ctx = avcodec_alloc_context3(decoder);
    if (!dec_ctx) {
        return job_fail(job, "allocating decoder context", AVERROR(ENOMEM));
    }
    channel->dec_ctx = dec_ctx;
    ret = avcodec_parameters_to_context(dec_ctx, channel->in_stream->codecpar);
    if (ret < 0) {
        return job_fail(job, "copying codec parameters", ret);
    }
    dec_ctx->time_base = channel->in_stream->time_base;
    dec_ctx->framerate = av_guess_frame_rate(format, channel->in_stream, NULL);
    ret = avcodec_open2(dec_ctx, decoder, NULL);
    if (ret < 0) {
        return job_fail(job, "opening decoder", ret);
    }
    return 0;
}

static int channel_init_filter(transcode_channel *channel,
                               const vyra_transcode_options *options,
                               transcode_job *job) {
    const AVFilter *src_filter = avfilter_get_by_name(
        channel->type == AVMEDIA_TYPE_VIDEO ? "buffer" : "abuffer");
    const AVFilter *sink_filter = avfilter_get_by_name(
        channel->type == AVMEDIA_TYPE_VIDEO ? "buffersink" : "abuffersink");
    if (!src_filter || !sink_filter) {
        return job_fail(job, "finding filter", AVERROR_FILTER_NOT_FOUND);
    }
    AVFilterGraph *graph = avfilter_graph_alloc();
    if (!graph) {
        return job_fail(job, "allocating filter graph", AVERROR(ENOMEM));
    }
    channel->graph = graph;
    AVCodecContext *dec_ctx = channel->dec_ctx;
    AVStream *in_stream = channel->in_stream;
    char args[512];
    char video_description[128];
    const char *description;
    if (channel->type == AVMEDIA_TYPE_VIDEO) {
        // Resolve the encoder now: the filter graph must output
        // exactly the pixel format the encoder consumes (NV12 for
        // VideoToolbox; a test encoder may accept only yuv420p).
        const char *encoder_name = (options && options->video_encoder_name)
                                       ? options->video_encoder_name
                                       : "h264_videotoolbox";
        channel->video_encoder = avcodec_find_encoder_by_name(encoder_name);
        if (!channel->video_encoder) {
            return job_fail(job, "finding video encoder",
                            AVERROR_ENCODER_NOT_FOUND);
        }
        channel->video_pix_fmt = AV_PIX_FMT_NONE;
        const enum AVPixelFormat *supported_fmts = NULL;
        if (avcodec_get_supported_config(NULL, channel->video_encoder,
                                         AV_CODEC_CONFIG_PIX_FORMAT, 0,
                                         (const void **)&supported_fmts, NULL) == 0
            && supported_fmts) {
            for (int i = 0; supported_fmts[i] != AV_PIX_FMT_NONE; i++) {
                if (supported_fmts[i] == AV_PIX_FMT_NV12) {
                    channel->video_pix_fmt = AV_PIX_FMT_NV12;
                    break;
                }
            }
            if (channel->video_pix_fmt == AV_PIX_FMT_NONE
                && supported_fmts[0] != AV_PIX_FMT_NONE) {
                channel->video_pix_fmt = supported_fmts[0];
            }
        }
        if (channel->video_pix_fmt == AV_PIX_FMT_NONE) {
            return job_fail(job, "finding video encoder pixel format",
                            AVERROR(EINVAL));
        }
        AVRational frame_rate = dec_ctx->framerate;
        if (frame_rate.num <= 0 || frame_rate.den <= 0) {
            frame_rate = (AVRational){30, 1};
        }
        AVRational aspect = dec_ctx->sample_aspect_ratio;
        if (aspect.num <= 0 || aspect.den <= 0) {
            aspect = (AVRational){0, 1};
        }
        snprintf(args, sizeof(args),
                 "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:"
                 "pixel_aspect=%d/%d:frame_rate=%d/%d",
                 dec_ctx->width, dec_ctx->height, dec_ctx->pix_fmt,
                 in_stream->time_base.num, in_stream->time_base.den,
                 aspect.num, aspect.den, frame_rate.num, frame_rate.den);
        // NV12 is the pixel format the VideoToolbox H.264 encoder
        // consumes natively; the graph auto-inserts libswscale for
        // the conversion (including 10-bit sources).
        snprintf(video_description, sizeof(video_description),
                 "format=pix_fmts=%s",
                 av_get_pix_fmt_name(channel->video_pix_fmt));
        description = video_description;
    } else {
        if (dec_ctx->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) {
            av_channel_layout_default(&dec_ctx->ch_layout,
                                      dec_ctx->ch_layout.nb_channels);
        }
        int written = snprintf(args, sizeof(args),
                               "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:"
                               "channel_layout=",
                               in_stream->time_base.num,
                               in_stream->time_base.den,
                               dec_ctx->sample_rate,
                               av_get_sample_fmt_name(dec_ctx->sample_fmt));
        if (written < 0 || (size_t)written >= sizeof(args)) {
            return job_fail(job, "building filter arguments", AVERROR(EINVAL));
        }
        av_channel_layout_describe(&dec_ctx->ch_layout, args + written,
                                   sizeof(args) - (size_t)written);
        // FLTP stereo/mono is what the native AAC encoder accepts;
        // the graph auto-inserts libswresample for conversion and
        // downmix.
        description = "aformat=sample_fmts=fltp:channel_layouts=stereo|mono";
    }

    int ret = avfilter_graph_create_filter(&channel->src_ctx, src_filter, "in",
                                           args, NULL, graph);
    if (ret < 0) {
        return job_fail(job, "creating filter source", ret);
    }
    ret = avfilter_graph_create_filter(&channel->sink_ctx, sink_filter, "out",
                                       NULL, NULL, graph);
    if (ret < 0) {
        return job_fail(job, "creating filter sink", ret);
    }
    AVFilterInOut *outputs = avfilter_inout_alloc();
    AVFilterInOut *inputs = avfilter_inout_alloc();
    if (!outputs || !inputs) {
        avfilter_inout_free(&outputs);
        avfilter_inout_free(&inputs);
        return job_fail(job, "allocating filter links", AVERROR(ENOMEM));
    }
    outputs->name = av_strdup("in");
    outputs->filter_ctx = channel->src_ctx;
    outputs->pad_idx = 0;
    outputs->next = NULL;
    inputs->name = av_strdup("out");
    inputs->filter_ctx = channel->sink_ctx;
    inputs->pad_idx = 0;
    inputs->next = NULL;
    ret = avfilter_graph_parse_ptr(graph, description, &inputs, &outputs, NULL);
    if (ret < 0) {
        return job_fail(job, "parsing filter graph", ret);
    }
    ret = avfilter_graph_config(graph, NULL);
    if (ret < 0) {
        return job_fail(job, "configuring filter graph", ret);
    }
    return 0;
}

static int channel_open_encoder(transcode_channel *channel,
                                const vyra_transcode_options *options,
                                transcode_job *job) {
    AVCodecContext *enc_ctx = NULL;
    AVStream *out_stream = avformat_new_stream(job->out_format, NULL);
    if (!out_stream) {
        return job_fail(job, "allocating output stream", AVERROR(ENOMEM));
    }
    channel->out_stream = out_stream;
    int ret;
    if (channel->type == AVMEDIA_TYPE_VIDEO) {
        const AVCodec *encoder = channel->video_encoder;
        if (!encoder) {
            return job_fail(job, "finding video encoder",
                            AVERROR_ENCODER_NOT_FOUND);
        }
        enc_ctx = avcodec_alloc_context3(encoder);
        if (!enc_ctx) {
            return job_fail(job, "allocating encoder context", AVERROR(ENOMEM));
        }
        channel->enc_ctx = enc_ctx;
        enc_ctx->width = av_buffersink_get_w(channel->sink_ctx);
        enc_ctx->height = av_buffersink_get_h(channel->sink_ctx);
        enc_ctx->pix_fmt = channel->video_pix_fmt;
        enc_ctx->time_base = av_buffersink_get_time_base(channel->sink_ctx);
        enc_ctx->framerate = av_buffersink_get_frame_rate(channel->sink_ctx);
        if (enc_ctx->framerate.num <= 0 || enc_ctx->framerate.den <= 0) {
            enc_ctx->framerate = channel->dec_ctx->framerate;
        }
        if (enc_ctx->framerate.num > 0 && enc_ctx->framerate.den > 0) {
            double fps = av_q2d(enc_ctx->framerate);
            if (fps >= 1.0 && fps <= 240.0) {
                enc_ctx->gop_size = (int)(fps * 2.0 + 0.5);
            }
        }
        int64_t bitrate = (options && options->video_bitrate > 0)
                              ? options->video_bitrate
                              : channel->in_stream->codecpar->bit_rate;
        if (bitrate <= 0) {
            bitrate = 5000000;
        }
        enc_ctx->bit_rate = bitrate;
        enc_ctx->rc_max_rate = bitrate;
        enc_ctx->rc_buffer_size = bitrate > INT32_MAX ? INT32_MAX : (int)bitrate;
        enc_ctx->color_primaries = channel->dec_ctx->color_primaries;
        enc_ctx->color_trc = channel->dec_ctx->color_trc;
        enc_ctx->colorspace = channel->dec_ctx->colorspace;
        enc_ctx->color_range = channel->dec_ctx->color_range;
    } else {
        const AVCodec *encoder = avcodec_find_encoder(AV_CODEC_ID_AAC);
        if (!encoder) {
            return job_fail(job, "finding audio encoder",
                            AVERROR_ENCODER_NOT_FOUND);
        }
        enc_ctx = avcodec_alloc_context3(encoder);
        if (!enc_ctx) {
            return job_fail(job, "allocating encoder context", AVERROR(ENOMEM));
        }
        channel->enc_ctx = enc_ctx;
        enc_ctx->sample_rate = av_buffersink_get_sample_rate(channel->sink_ctx);
        AVChannelLayout sink_layout;
        memset(&sink_layout, 0, sizeof(sink_layout));
        ret = av_buffersink_get_ch_layout(channel->sink_ctx, &sink_layout);
        if (ret >= 0) {
            ret = av_channel_layout_copy(&enc_ctx->ch_layout, &sink_layout);
            av_channel_layout_uninit(&sink_layout);
        }
        if (ret < 0) {
            return job_fail(job, "configuring audio encoder", ret);
        }
        enc_ctx->sample_fmt = AV_SAMPLE_FMT_FLTP;
        enc_ctx->time_base = (AVRational){1, enc_ctx->sample_rate};
        enc_ctx->bit_rate = (options && options->audio_bitrate > 0)
                                ? options->audio_bitrate
                                : 160000;
        channel->fifo = av_audio_fifo_alloc(enc_ctx->sample_fmt,
                                            enc_ctx->ch_layout.nb_channels,
                                            enc_ctx->frame_size > 0
                                                ? enc_ctx->frame_size
                                                : 1024);
        if (!channel->fifo) {
            return job_fail(job, "allocating audio fifo", AVERROR(ENOMEM));
        }
        channel->fifo_frame = av_frame_alloc();
        if (!channel->fifo_frame) {
            return job_fail(job, "allocating audio frame", AVERROR(ENOMEM));
        }
    }
    if (job->out_format->oformat->flags & AVFMT_GLOBALHEADER) {
        enc_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    ret = avcodec_open2(enc_ctx, NULL, NULL);
    if (ret < 0) {
        return job_fail(job,
                        channel->type == AVMEDIA_TYPE_VIDEO
                            ? "opening video encoder"
                            : "opening audio encoder",
                        ret);
    }
    ret = avcodec_parameters_from_context(out_stream->codecpar, enc_ctx);
    if (ret < 0) {
        return job_fail(job, "copying encoder parameters", ret);
    }
    out_stream->time_base = enc_ctx->time_base;
    return 0;
}

// MARK: - Packet feeding

/// Reads packets from the input until one belongs to a stream a
/// channel consumes (stored in input->pending) or the input ends.
static int input_fill(transcode_input *input, transcode_channel *channels,
                      int channel_count) {
    if (input->have_pending || input->finished) {
        return 0;
    }
    for (;;) {
        int ret = av_read_frame(input->format, input->pending);
        if (ret < 0) {
            input->finished = 1;
            return (ret == AVERROR_EOF) ? 0 : ret;
        }
        for (int i = 0; i < channel_count; i++) {
            if (channels[i].input == input
                && input->pending->stream_index == channels[i].in_stream->index) {
                input->have_pending = 1;
                return 0;
            }
        }
        av_packet_unref(input->pending);
    }
}

/// The timestamp used to order one input's pending packet against
/// the other input's: its DTS (falling back to PTS), in microseconds.
static int64_t input_order_key(const transcode_input *input) {
    const AVPacket *packet = input->pending;
    int64_t ts = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
    if (ts == AV_NOPTS_VALUE) {
        return INT64_MIN;
    }
    AVStream *stream = input->format->streams[packet->stream_index];
    return av_rescale_q(ts, stream->time_base, AV_TIME_BASE_Q)
           - input->start_offset_us;
}

// MARK: - Cleanup helpers

static void channel_close(transcode_channel *channel) {
    if (channel->fifo_frame) {
        av_frame_free(&channel->fifo_frame);
    }
    if (channel->fifo) {
        av_audio_fifo_free(channel->fifo);
    }
    if (channel->graph) {
        avfilter_graph_free(&channel->graph);
    }
    if (channel->dec_ctx) {
        avcodec_free_context(&channel->dec_ctx);
    }
    if (channel->enc_ctx) {
        avcodec_free_context(&channel->enc_ctx);
    }
}

static void input_close(transcode_input *input) {
    if (input->pending) {
        av_packet_free(&input->pending);
    }
    if (input->format) {
        avformat_close_input(&input->format);
    }
}

// MARK: - Entry point

int vyra_transcode_run(vyra_transcode_context *context,
                       const char *video_path,
                       const char *audio_path,
                       const char *output_path,
                       const vyra_transcode_options *options,
                       vyra_transcode_progress_callback progress_callback,
                       void *progress_opaque,
                       char *error_buffer,
                       int error_buffer_size) {
    transcode_job job;
    memset(&job, 0, sizeof(job));
    job.context = context;
    job.progress_callback = progress_callback;
    job.progress_opaque = progress_opaque;
    job.last_reported_fraction = -1.0;

    transcode_input inputs[2];
    memset(inputs, 0, sizeof(inputs));
    int input_count = 0;
    transcode_input *video_input = NULL;
    transcode_input *audio_input = NULL;

    transcode_channel channels[2];
    memset(channels, 0, sizeof(channels));
    int channel_count = 0;

    int ret = 0;
    const char *stage = "preparing transcode";

    if (!output_path || (!video_path && !audio_path)) {
        ret = job_fail(&job, "invalid arguments", AVERROR(EINVAL));
        goto cleanup;
    }

    const int same_file = video_path && audio_path
                          && strcmp(video_path, audio_path) == 0;
    if (video_path) {
        video_input = &inputs[input_count++];
        ret = input_open(video_input, context, video_path, "video", &job);
        if (ret < 0) {
            goto cleanup;
        }
    }
    if (audio_path && !same_file) {
        audio_input = &inputs[input_count++];
        ret = input_open(audio_input, context, audio_path, "audio", &job);
        if (ret < 0) {
            goto cleanup;
        }
    } else if (same_file) {
        audio_input = video_input;
    }

    ret = avformat_alloc_output_context2(&job.out_format, NULL, "mp4",
                                         output_path);
    if (ret < 0 || !job.out_format) {
        ret = job_fail(&job, "allocating output context",
                       ret < 0 ? ret : AVERROR(ENOMEM));
        goto cleanup;
    }
    job.out_format->interrupt_callback.callback = interrupt_callback;
    job.out_format->interrupt_callback.opaque = context;

    if (video_path) {
        transcode_channel *channel = &channels[channel_count++];
        channel->type = AVMEDIA_TYPE_VIDEO;
        channel->input = video_input;
        ret = channel_open_decoder(channel, &job);
        if (ret < 0) {
            goto cleanup;
        }
    }
    if (audio_path) {
        transcode_channel *channel = &channels[channel_count++];
        channel->type = AVMEDIA_TYPE_AUDIO;
        channel->input = audio_input;
        ret = channel_open_decoder(channel, &job);
        if (ret < 0) {
            goto cleanup;
        }
    }
    for (int i = 0; i < channel_count; i++) {
        ret = channel_init_filter(&channels[i], options, &job);
        if (ret < 0) {
            goto cleanup;
        }
        ret = channel_open_encoder(&channels[i], options, &job);
        if (ret < 0) {
            goto cleanup;
        }
    }

    for (int i = 0; i < input_count; i++) {
        if (inputs[i].format->duration > job.total_duration_us) {
            job.total_duration_us = inputs[i].format->duration;
        }
    }

    if (!(job.out_format->oformat->flags & AVFMT_NOFILE)) {
        AVIOInterruptCB io_interrupt = { interrupt_callback, context };
        ret = avio_open2(&job.out_format->pb, output_path, AVIO_FLAG_WRITE,
                         &io_interrupt, NULL);
        if (ret < 0) {
            ret = job_fail(&job, "opening output file", ret);
            goto cleanup;
        }
    }

    ret = avformat_write_header(job.out_format, NULL);
    if (ret < 0) {
        ret = job_fail(&job, "writing header", ret);
        goto cleanup;
    }

    for (;;) {
        if (context && context->cancelled) {
            ret = 1; // cancelled
            goto cleanup;
        }
        // Pick the input whose next relevant packet comes first in
        // time, like the remux bridge's interleave.
        transcode_input *next = NULL;
        for (int i = 0; i < input_count; i++) {
            ret = input_fill(&inputs[i], channels, channel_count);
            if (ret < 0) {
                ret = job_fail(&job, "reading input", ret);
                goto cleanup;
            }
            if (!inputs[i].have_pending) {
                continue;
            }
            if (!next || input_order_key(&inputs[i]) < input_order_key(next)) {
                next = &inputs[i];
            }
        }
        if (!next) {
            // No packets anywhere: flush the channels fed by any
            // finished input, then finish when all are flushed.
            int all_flushed = 1;
            for (int i = 0; i < channel_count; i++) {
                if (channels[i].flushed) {
                    continue;
                }
                if (channels[i].input->finished) {
                    ret = channel_decode(&channels[i], NULL, &job);
                    if (ret != 0) {
                        goto cleanup;
                    }
                } else {
                    all_flushed = 0;
                }
            }
            if (all_flushed) {
                break;
            }
            continue;
        }

        AVPacket *packet = next->pending;
        transcode_channel *channel = NULL;
        for (int i = 0; i < channel_count; i++) {
            if (channels[i].input == next
                && channels[i].in_stream->index == packet->stream_index) {
                channel = &channels[i];
                break;
            }
        }
        next->have_pending = 0;
        if (channel) {
            ret = channel_decode(channel, packet, &job);
            av_packet_unref(packet);
            if (ret != 0) {
                goto cleanup;
            }
        } else {
            av_packet_unref(packet);
        }
    }

    ret = av_write_trailer(job.out_format);
    if (ret < 0) {
        ret = job_fail(&job, "writing trailer", ret);
        goto cleanup;
    }
    if (job.progress_callback) {
        job.progress_callback(job.progress_opaque, 1.0);
    }
    ret = 0;

cleanup:
    if (ret < 0 && error_buffer && error_buffer_size > 0) {
        const char *failing_stage = job.stage ? job.stage : stage;
        if (job.error_code < 0) {
            char av_error[AV_ERROR_MAX_STRING_SIZE];
            if (av_strerror(job.error_code, av_error, sizeof(av_error)) == 0) {
                snprintf(error_buffer, (size_t)error_buffer_size,
                         "%s: %s", failing_stage, av_error);
            } else {
                snprintf(error_buffer, (size_t)error_buffer_size,
                         "%s: FFmpeg error %d", failing_stage,
                         job.error_code);
            }
        } else {
            snprintf(error_buffer, (size_t)error_buffer_size, "%s",
                     failing_stage);
        }
        error_buffer[error_buffer_size - 1] = '\0';
    }
    if (job.out_format) {
        if (job.out_format->pb) {
            avio_closep(&job.out_format->pb);
        }
        avformat_free_context(job.out_format);
    }
    for (int i = 0; i < channel_count; i++) {
        channel_close(&channels[i]);
    }
    for (int i = 0; i < input_count; i++) {
        input_close(&inputs[i]);
    }
    return ret;
}
