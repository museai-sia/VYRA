//
//  RemuxBridge.h
//  VYRA — minimal C remux layer over the bundled FFmpeg libraries.
//
//  The app never spawns an ffmpeg process (impossible in the iOS
//  sandbox). Instead, the FFmpeg libraries (libavformat / libavcodec /
//  libavutil, LGPL, see Documentation/THIRD_PARTY_LICENSES.md) are
//  linked into the app and used in-process to merge a video-only MP4
//  and an audio-only M4A into one MP4 by stream copy — no decoding,
//  no re-encoding, exactly what `ffmpeg -c copy` would do.
//

#ifndef VYRA_REMUXBRIDGE_H
#define VYRA_REMUXBRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque remux job handle. Owns the cancellation flag consulted by
/// the FFmpeg interrupt callbacks, so a remux can be aborted while it
/// is blocked in I/O or mid-stream.
typedef struct vyra_remux_context vyra_remux_context;

vyra_remux_context *vyra_remux_create(void);
void vyra_remux_destroy(vyra_remux_context *context);

/// Requests cancellation. Safe to call from any thread while
/// vyra_remux_run is executing on another thread.
void vyra_remux_cancel(vyra_remux_context *context);

/// Stream-copies the first video stream of `video_path` and the first
/// audio stream of `audio_path` into a new MP4 at `output_path`.
/// Returns 0 on success, 1 when cancelled, -1 on failure (in which
/// case `error_buffer` receives a human-readable description of the
/// failing stage and the FFmpeg error). The output file may exist
/// partially on failure/cancel; the caller deletes it.
int vyra_remux_run(vyra_remux_context *context,
                   const char *video_path,
                   const char *audio_path,
                   const char *output_path,
                   char *error_buffer,
                   int error_buffer_size);

/// Stream-copies the video and/or audio streams of ONE input file
/// into a new MP4 at `output_path`. This is the HLS path: yt-dlp's
/// native HLS downloader delivers MPEG-TS bytes under an .mp4 name,
/// and this rewraps them into a real MP4 without re-encoding (the
/// input is probed by content, so the file name is irrelevant).
/// A missing video or audio stream is tolerated (the other is
/// copied alone); a file with neither fails. Same return contract
/// as vyra_remux_run.
int vyra_remux_run_single(vyra_remux_context *context,
                          const char *input_path,
                          const char *output_path,
                          char *error_buffer,
                          int error_buffer_size);

#ifdef __cplusplus
}
#endif

#endif /* VYRA_REMUXBRIDGE_H */
