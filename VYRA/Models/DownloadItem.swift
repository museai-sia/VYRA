import Foundation
import SwiftData

/// A saved (or in-progress) item. Persisted with SwiftData; in Phase 1 all
/// items are created from mock data and no real file is ever downloaded.
@Model
final class DownloadItem {
    var id: UUID
    var fileName: String
    var formatRawValue: String
    var qualityRawValue: String
    /// Mock/estimated size in bytes. Never a measured real file size.
    var fileSizeBytes: Int64
    var createdAt: Date
    var stateRawValue: String
    var thumbnailSymbol: String
    var sourceURLString: String

    init(
        id: UUID = UUID(),
        fileName: String,
        format: DownloadFormat,
        quality: DownloadQuality,
        fileSizeBytes: Int64,
        createdAt: Date = Date(),
        state: DownloadState = .waiting,
        thumbnailSymbol: String = "play.rectangle.fill",
        sourceURLString: String = ""
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

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
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
