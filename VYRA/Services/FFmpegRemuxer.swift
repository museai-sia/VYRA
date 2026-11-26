import Foundation

/// Errors from the in-process FFmpeg remux. The message is the real
/// FFmpeg failure (stage + av_strerror), never a generic placeholder.
enum FFmpegRemuxError: Error, Equatable, Sendable {
    case failed(message: String)
    case cancelled

    var message: String {
        switch self {
        case .failed(let message): return message
        case .cancelled: return "キャンセルしました。"
        }
    }
}

/// Cancellation handle for one remux job. The C context owns a flag
/// that the FFmpeg interrupt callbacks poll, so cancelling aborts a
/// remux blocked in I/O or mid-stream.
final class FFmpegRemuxJob: @unchecked Sendable {
    private let context: OpaquePointer?

    init() {
        context = vyra_remux_create()
    }

    deinit {
        if let context { vyra_remux_destroy(context) }
    }

    func cancel() {
        if let context { vyra_remux_cancel(context) }
    }

    var pointer: OpaquePointer? { context }
}

/// Merges a video-only MP4 and an audio-only M4A into one MP4 by
/// stream copy, using the bundled FFmpeg libraries in-process
/// (`FFmpegBridge/RemuxBridge.c`). No subprocess, no transcoding:
/// the equivalent of `ffmpeg -c copy`.
enum FFmpegRemuxer {
    static func remux(videoURL: URL, audioURL: URL, outputURL: URL,
                      job: FFmpegRemuxJob) async throws {
        guard let context = job.pointer else {
            throw FFmpegRemuxError.failed(message: "remux context allocation failed")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorBuffer = [CChar](repeating: 0, count: 512)
                let result = vyra_remux_run(
                    context,
                    videoURL.path, audioURL.path, outputURL.path,
                    &errorBuffer, Int32(errorBuffer.count))
                Self.resume(continuation, result: result, errorBuffer: errorBuffer)
            }
        }
    }

    /// Stream-copies the streams of ONE input file into an MP4.
    /// The HLS path: the downloaded file holds MPEG-TS bytes (its
    /// name says .mp4, its content does not), and the remux probes
    /// the content, so any extension works.
    static func remuxSingle(inputURL: URL, outputURL: URL,
                            job: FFmpegRemuxJob) async throws {
        guard let context = job.pointer else {
            throw FFmpegRemuxError.failed(message: "remux context allocation failed")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorBuffer = [CChar](repeating: 0, count: 512)
                let result = vyra_remux_run_single(
                    context,
                    inputURL.path, outputURL.path,
                    &errorBuffer, Int32(errorBuffer.count))
                Self.resume(continuation, result: result, errorBuffer: errorBuffer)
            }
        }
    }

    private static func resume(_ continuation: CheckedContinuation<Void, Error>,
                               result: Int32, errorBuffer: [CChar]) {
        switch result {
        case 0:
            continuation.resume()
        case 1:
            continuation.resume(throwing: FFmpegRemuxError.cancelled)
        default:
            let message = String(cString: errorBuffer)
            continuation.resume(throwing: FFmpegRemuxError.failed(
                message: message.isEmpty ? "unknown FFmpeg error" : message))
        }
    }
}
