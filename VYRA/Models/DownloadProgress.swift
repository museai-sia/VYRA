import Foundation

/// Progress snapshot for one download task (Phase 3, spec §10).
/// Values that cannot be known are nil — never guessed.
struct DownloadProgress: Equatable, Sendable {
    /// What the engine is doing right now. `.merging` is the FFmpeg
    /// remux of a split pair: byte counts no longer move, so the UI
    /// shows an indeterminate "結合中" state instead of a fake percent.
    /// `.transcoding` is the FFmpeg decode/re-encode of a format that
    /// could not be copied: progress is the real processed-duration
    /// fraction reported by the transcoder, shown as "変換中".
    enum Phase: Equatable, Sendable {
        case downloading
        case merging
        case transcoding
    }

    var downloadedBytes: Int64 = 0
    var totalBytes: Int64?
    var speedBytesPerSecond: Double?
    var estimatedRemainingTime: TimeInterval?
    var state: DownloadState = .queued
    var phase: Phase = .downloading

    /// 0...1, or nil when the total size is unknown (indeterminate).
    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(totalBytes)))
    }

    var percentText: String? {
        guard let fraction else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    var downloadedText: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    var totalText: String? {
        guard let totalBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var speedText: String? {
        guard let speedBytesPerSecond, speedBytesPerSecond > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(speedBytesPerSecond), countStyle: .file) + "/s"
    }

    var remainingTimeText: String? {
        guard let estimatedRemainingTime, estimatedRemainingTime.isFinite, estimatedRemainingTime >= 0 else { return nil }
        let seconds = Int(estimatedRemainingTime.rounded())
        if seconds < 60 { return "残り約\(seconds)秒" }
        return "残り約\(seconds / 60)分\(seconds % 60)秒"
    }

    static func initial(state: DownloadState = .queued) -> DownloadProgress {
        DownloadProgress(state: state)
    }
}

/// One concrete download job handed to a `DownloadService` engine.
struct DownloadRequest: Equatable, Sendable {
    var taskID: UUID
    var sourceURL: URL
    /// Sanitized file name (with extension) the finished file should carry.
    var fileName: String
    /// When set, the request is handled by the yt-dlp engine with this
    /// exact format_id (sourceURL is then a page URL, not a file URL).
    var ytDlpFormatID: String? = nil
    /// For a split pair: the audio format_id to download alongside
    /// `ytDlpFormatID` (which is then the video format_id) and merge.
    var ytDlpAudioFormatID: String? = nil
    /// How the yt-dlp download becomes the saved file (direct save,
    /// stream-copy remux, or transcode). Nil = legacy default.
    var ytDlpProcessing: MediaProcessingKind? = nil
    /// True when the yt-dlp format is an audio-only format (the
    /// transcode then produces an M4A from the audio stream alone).
    var ytDlpIsAudioOnly: Bool = false
    /// Estimated total size of the finished download, when a real
    /// source reported one; used to derive transcode bitrates.
    var estimatedBytes: Int64? = nil
    /// Media duration in seconds, when known; likewise.
    var durationSeconds: Int? = nil
    /// Pixel height of the selected rendition, when known; likewise.
    var estimatedHeight: Int? = nil
}
