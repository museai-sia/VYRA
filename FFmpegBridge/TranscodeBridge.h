//
//  TranscodeBridge.h
//  VYRA — in-process transcode layer over the bundled FFmpeg libraries.
//
//  Companion to RemuxBridge (stream copy). When a downloaded format
//  cannot be stream-copied into a playable MP4 — VP9/AV1 video, WebM
//  container, Opus audio — this layer decodes it with the bundled
//  FFmpeg libraries and re-encodes it in-process: video to H.264 via
//  the VideoToolbox hardware encoder, audio to AAC via FFmpeg's
//  native encoder. Output is always an AVKit-playable MP4 (or an
//  M4A when there is no video). No subprocess is ever spawned.
//

#ifndef VYRA_TRANSCODEBRIDGE_H
#define VYRA_TRANSCODEBRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque transcode job handle. Owns the cancellation flag consulted
/// by the FFmpeg interrupt callbacks and the encode loop, so a
/// transcode can be aborted while it is blocked in I/O or mid-stream.
typedef struct vyra_transcode_context vyra_transcode_context;

vyra_transcode_context *vyra_transcode_create(void);
void vyra_transcode_destroy(vyra_transcode_context *context);

/// Requests cancellation. Safe to call from any thread while
/// vyra_transcode_run is executing on another thread.
void vyra_transcode_cancel(vyra_transcode_context *context);

/// Progress report: `fraction` is the processed share of the media
/// duration in [0, 1]. Called from the thread running
/// vyra_transcode_run, whenever the fraction meaningfully advances.
typedef void (*vyra_transcode_progress_callback)(void *opaque, double fraction);

typedef struct {
    /// Target video bitrate in bit/s. 0 = derive from the input
    /// stream (its reported bitrate, else a 5 Mbit/s default).
    long long video_bitrate;
    /// Target audio bitrate in bit/s. 0 = 160 kbit/s.
    long long audio_bitrate;
    /// Video encoder name override; NULL selects the production
    /// encoder ("h264_videotoolbox"). Exists so the pipeline can be
    /// exercised on platforms without VideoToolbox (tests on Linux).
    const char *video_encoder_name;
} vyra_transcode_options;

/// Transcodes into a new MP4 (or audio-only MP4/M4A) at
/// `output_path`.
///
/// Inputs:
///   - `video_path` and `audio_path` both set and different: a split
///     pair (video-only file + audio-only file).
///   - `video_path` == `audio_path` (same string): one combined file
///     carrying both streams.
///   - `video_path` NULL, `audio_path` set: audio-only transcode.
///   - `audio_path` NULL, `video_path` set: video-only transcode.
///
/// Returns 0 on success, 1 when cancelled, -1 on failure (in which
/// case `error_buffer` receives a human-readable description of the
/// failing stage and the FFmpeg error). The output file may exist
/// partially on failure/cancel; the caller deletes it.
int vyra_transcode_run(vyra_transcode_context *context,
                       const char *video_path,
                       const char *audio_path,
                       const char *output_path,
                       const vyra_transcode_options *options,
                       vyra_transcode_progress_callback progress_callback,
                       void *progress_opaque,
                       char *error_buffer,
                       int error_buffer_size);

#ifdef __cplusplus
}
#endif

#endif /* VYRA_TRANSCODEBRIDGE_H */
