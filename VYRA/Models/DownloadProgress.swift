import Foundation

/// Progress snapshot for one download task (Phase 3, spec §10).
/// Values that cannot be known are nil — never guessed.
struct DownloadProgress: Equatable, Sendable {
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64?
    var speedBytesPerSecond: Double?
    var estimatedRemainingTime: TimeInterval?
    var state: DownloadState = .queued

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
}
