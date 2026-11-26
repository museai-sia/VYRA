import Foundation

/// How a selected yt-dlp format becomes the saved file. The output
/// is always an AVKit-playable file (MP4 for video, M4A for audio);
/// this kind only describes the work needed to get there.
///
/// - direct: the downloaded file is already a playable MP4/M4A
///   (avc1 + AAC) — saved as-is, no FFmpeg work.
/// - remux: a split pair (avc1 video-only MP4 + AAC audio-only M4A)
///   is stream-copied into one MP4 by the bundled FFmpeg libraries
///   (lossless, fast).
/// - remuxSingle: a single downloaded file whose bytes are not an
///   MP4 — an HLS download is MPEG-TS data under an .mp4 name — is
///   stream-copied into a real MP4 by the same libraries (the
///   codecs are already avc1 + AAC; only the container changes).
/// - transcode: anything else yt-dlp returned (VP9/AV1 video, WebM
///   container, Opus audio, ...) is decoded and re-encoded in-process
///   to H.264 (VideoToolbox) + AAC. Lossy and slower than a copy,
///   but it makes every resolution yt-dlp offers selectable.
enum MediaProcessingKind: String, Codable, Equatable, Sendable {
    case direct
    case remux
    case remuxSingle
    case transcode
}
