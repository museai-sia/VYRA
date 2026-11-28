import Foundation

/// A concrete, actually-available format/quality combination (Phase 3, spec §7).
/// Built only from real information: a verified source's reported formats, or a
/// direct media file's extension / Content-Type / Content-Length. Unknown
/// fields stay nil.
struct MediaFormatOption: Identifiable, Equatable, Sendable {
    var id: String
    var container: String
    var fileExtension: String
    var mimeType: String?
    var displayName: String
    var isVideo: Bool
    var isAudio: Bool
    var qualityLabel: String?
    var estimatedFileSize: Int64?
    /// yt-dlp format_id, when this option came from the yt-dlp engine.
    var ytDlpFormatID: String? = nil
    /// For a split pair (video-only format + separate audio format
    /// that the FFmpeg remux/transcode joins): the audio format's
    /// yt-dlp format_id. `ytDlpFormatID` then holds the video format_id.
    var audioYtDlpFormatID: String? = nil
    /// How the downloaded format(s) become the saved MP4/M4A:
    /// saved as-is, stream-copy remux, or full transcode.
    var processing: MediaProcessingKind = .direct
    /// Source video codec reported by yt-dlp (e.g. "avc1.640028",
    /// "vp09.00.10.08"), when this option came from the yt-dlp engine.
    var videoCodec: String? = nil
    /// Source audio codec of the chosen video format (combined) or of
    /// the paired audio format (split), e.g. "mp4a.40.2", "opus".
    var audioCodec: String? = nil
    /// Container of the source video format (or audio format for
    /// audio-only options), e.g. "mp4", "webm". The saved file's
    /// container is always `container`/`fileExtension` (mp4/m4a).
    var sourceContainer: String? = nil
    /// When the source format URL(s) stop being safely usable
    /// (googlevideo `expire` − 60s, worker.js rule; for a split pair
    /// the earlier of the two). nil when the source reported no
    /// expiry — unknown is not treated as stale.
    var urlExpiresAt: Date? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil

    /// True when the format URL expiry has passed (or is within the
    /// 60-second safety margin) at `now`.
    func isStale(now: Date = Date()) -> Bool {
        guard let urlExpiresAt else { return false }
        return now >= urlExpiresAt
    }

    /// True when this option downloads as two streams (video + audio)
    /// that are merged in-process before saving.
    var isSplitPair: Bool { audioYtDlpFormatID != nil }

    var format: DownloadFormat? { DownloadFormat(rawValue: fileExtension.lowercased()) }

    var quality: DownloadQuality {
        DownloadQuality.forLabel(qualityLabel)
            ?? pixelHeight.flatMap(DownloadQuality.forHeight)
            ?? .original
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }

    static func format(forMimeType mime: String) -> DownloadFormat? {
        switch mime.lowercased() {
        case "video/mp4": return .mp4
        case "video/quicktime": return .mov
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return .m4a
        default: return nil
        }
    }
}
