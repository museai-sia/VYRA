import Foundation
import SwiftData

/// A saved (or in-progress) item, persisted with SwiftData (Phase 3).
/// Only completed downloads with a real file on disk are registered in
/// the Library; in-progress and failed tasks never create Library entries.
@Model
final class DownloadItem {
    var id: UUID
    var fileName: String
    var formatRawValue: String
    var qualityRawValue: String
    /// Actual measured size once completed; before completion this is an
    /// estimate only and must be labelled as such in the UI.
    var fileSizeBytes: Int64
    var createdAt: Date
    var stateRawValue: String
    var thumbnailSymbol: String
    var sourceURLString: String
    // Phase 3 fields (all defaulted so Phase 1/2 records migrate lightly).
    /// Path of the saved file relative to the app's Documents directory.
    var localFileRelativePath: String?
    var mimeType: String?
    var thumbnailURLString: String?
    var durationSeconds: Int?
    var downloadedBytes: Int64 = 0
    /// User-facing failure reason, when state == .failed.
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        fileName: String,
        format: DownloadFormat,
        quality: DownloadQuality,
        fileSizeBytes: Int64,
        createdAt: Date = Date(),
        state: DownloadState = .waiting,
        thumbnailSymbol: String = "play.rectangle.fill",
        sourceURLString: String = "",
        localFileRelativePath: String? = nil,
        mimeType: String? = nil,
        thumbnailURLString: String? = nil,
        durationSeconds: Int? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.formatRawValue = format.rawValue
        self.qualityRawValue = quality.rawValue
        self.fileSizeBytes = fileSizeBytes
        self.createdAt = createdAt
        self.stateRawValue = state.rawValue
        self.thumbnailSymbol = thumbnailSymbol
        self.sourceURLString = sourceURLString
        self.localFileRelativePath = localFileRelativePath
        self.mimeType = mimeType
        self.thumbnailURLString = thumbnailURLString
        self.durationSeconds = durationSeconds
    }

    var format: DownloadFormat {
        get { DownloadFormat(rawValue: formatRawValue) ?? .mp4 }
        set { formatRawValue = newValue.rawValue }
    }

    var quality: DownloadQuality {
        get { DownloadQuality(rawValue: qualityRawValue) ?? .p720 }
        set { qualityRawValue = newValue.rawValue }
    }

    var state: DownloadState {
        get { DownloadState(rawValue: stateRawValue) ?? .waiting }
        set { stateRawValue = newValue.rawValue }
    }

    var sourceURL: URL? { URL(string: sourceURLString) }

    var thumbnailURL: URL? {
        guard let thumbnailURLString else { return nil }
        return URL(string: thumbnailURLString)
    }

    /// Attempts a validated state transition; illegal transitions are
    /// rejected and leave the state unchanged (spec §9).
    @discardableResult
    func transition(to next: DownloadState) -> Bool {
        guard state.canTransition(to: next) else { return false }
        state = next
        return true
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var formattedDuration: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Formats AVKit can play back from a local file.
    var isPlayableFormat: Bool {
        switch format {
        case .mp4, .mov, .m4a: return true
        }
    }

    static func mockItem() -> DownloadItem {
        DownloadItem(
            fileName: "mock-video-\(Int.random(in: 1000...9999)).mp4",
            format: .mp4,
            quality: .p720,
            fileSizeBytes: 48_000_000,
            state: .completed,
            sourceURLString: Video.mock.sourceURLString
        )
    }
}
