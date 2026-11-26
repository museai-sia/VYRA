import Foundation

/// Errors from the in-process FFmpeg transcode. The message is the
/// real FFmpeg failure (stage + av_strerror), never a placeholder.
enum FFmpegTranscodeError: Error, Equatable, Sendable {
    case failed(message: String)
    case cancelled

    var message: String {
        switch self {
        case .failed(let message): return message
        case .cancelled: return "キャンセルしました。"
        }
    }
}

/// Cancellation handle for one transcode job. The C context owns a
/// flag that the FFmpeg interrupt callbacks and the encode loop
/// poll, so cancelling aborts a transcode mid-stream.
final class FFmpegTranscodeJob: @unchecked Sendable {
    private let context: OpaquePointer?

    init() {
        context = vyra_transcode_create()
    }

    deinit {
        if let context { vyra_transcode_destroy(context) }
    }

    func cancel() {
        if let context { vyra_transcode_cancel(context) }
    }

    var pointer: OpaquePointer? { context }
}

/// Target bitrates for a transcode, derived from what the source
/// reported — never invented from nothing: when the estimated total
/// size and the duration are known, the source's overall bitrate
/// follows from them and the video keeps ~85% of it. Otherwise a
/// per-height table (matched to typical YouTube rendition bitrates)
/// is used. Video is clamped to 400 kbit/s...45 Mbit/s; audio is a
/// flat 192 kbit/s for video files (160 kbit/s for audio-only),
/// which matches or exceeds the AAC/Opus renditions YouTube serves.
enum TranscodeBitrateEstimator {
    static func videoBitrate(estimatedBytes: Int64?, durationSeconds: Int?,
                             height: Int?, isAudioOnly: Bool) -> Int64 {
        if isAudioOnly { return 0 }
        if let estimatedBytes, let durationSeconds, durationSeconds > 0, estimatedBytes > 0 {
            let overall = Double(estimatedBytes) * 8.0 / Double(durationSeconds)
            let video = overall * 0.85
            return Int64(min(45_000_000, max(400_000, video)))
        }
        switch height ?? 0 {
        case 2160...: return 28_000_000
        case 1440...: return 16_000_000
        case 1080...: return 9_000_000
        case 720...: return 5_500_000
        case 480...: return 2_600_000
        case 360...: return 1_100_000
        case 240...: return 600_000
        case 1...: return 300_000
        default: return 8_000_000
        }
    }

    static func audioBitrate(isAudioOnly: Bool) -> Int64 {
        isAudioOnly ? 160_000 : 192_000
    }
}

private final class TranscodeProgressBox: @unchecked Sendable {
    let handler: @Sendable (Double) -> Void
    init(handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }
}

private let vyraTranscodeProgressCallback: @convention(c) (UnsafeMutableRawPointer?, Double) -> Void = { opaque, fraction in
    guard let opaque else { return }
    Unmanaged<TranscodeProgressBox>.fromOpaque(opaque).takeUnretainedValue().handler(fraction)
}

/// Re-encodes a downloaded format that cannot be stream-copied
/// (VP9/AV1/WebM video, Opus audio, ...) into an AVKit-playable
/// MP4 — H.264 via VideoToolbox + AAC — using the bundled FFmpeg
/// libraries in-process (`FFmpegBridge/TranscodeBridge.c`). No
/// subprocess. Exactly one of the input combinations is used:
/// split pair (video + audio files), combined file (same URL for
/// both), or audio-only (videoURL nil).
enum FFmpegTranscoder {
    static func transcode(videoURL: URL?, audioURL: URL?, outputURL: URL,
                          videoBitrate: Int64, audioBitrate: Int64,
                          job: FFmpegTranscodeJob,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let context = job.pointer else {
            throw FFmpegTranscodeError.failed(message: "transcode context allocation failed")
        }
        let box = TranscodeProgressBox(handler: progress)
        let opaque = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<TranscodeProgressBox>.fromOpaque(opaque).release() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var options = vyra_transcode_options(
                    video_bitrate: videoBitrate,
                    audio_bitrate: audioBitrate,
                    video_encoder_name: nil)
                var errorBuffer = [CChar](repeating: 0, count: 512)
                let result: Int32
                if let videoURL, let audioURL {
                    result = vyra_transcode_run(
                        context, videoURL.path, audioURL.path, outputURL.path,
                        &options, vyraTranscodeProgressCallback, opaque,
                        &errorBuffer, Int32(errorBuffer.count))
                } else if let audioURL {
                    result = vyra_transcode_run(
                        context, nil, audioURL.path, outputURL.path,
                        &options, vyraTranscodeProgressCallback, opaque,
                        &errorBuffer, Int32(errorBuffer.count))
                } else if let videoURL {
                    result = vyra_transcode_run(
                        context, videoURL.path, nil, outputURL.path,
                        &options, vyraTranscodeProgressCallback, opaque,
                        &errorBuffer, Int32(errorBuffer.count))
                } else {
                    result = -1
                    errorBuffer = Array("no input file given".utf8CString)
                }
                switch result {
                case 0:
                    continuation.resume()
                case 1:
                    continuation.resume(throwing: FFmpegTranscodeError.cancelled)
                default:
                    let message = String(cString: errorBuffer)
                    continuation.resume(throwing: FFmpegTranscodeError.failed(
                        message: message.isEmpty ? "unknown FFmpeg error" : message))
                }
            }
        }
    }
}
