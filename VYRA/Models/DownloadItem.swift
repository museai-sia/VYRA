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
    /// Display metadata captured when the download was created: the
    /// video's real title and creator, so saved-history rows can show
    /// them instead of the bare file name. Nil for records created
    /// before these fields existed (defaulted → lightweight migration);
    /// the UI falls back to the file name for those.
    var title: String?
    var creatorName: String?
    // Phase 3 fields (all defaulted so Phase 1/2 records migrate lightly).
    /// Path of the saved file relative to the app's Documents directory.
    /// Nil when the file lives in a user-chosen external folder; then
    /// `externalBookmarkData` locates it instead.
    var localFileRelativePath: String?
    /// Security-scoped bookmark of the saved file itself, for items
    /// saved into a user-chosen external folder (Settings > 保存先).
    var externalBookmarkData: Data?
    var mimeType: String?
    var thumbnailURLString: String?
    var durationSeconds: Int?
    var downloadedBytes: Int64 = 0
    /// User-facing failure reason, when state == .failed.
    var errorMessage: String?
    /// Specific failure detail (e.g. the Python exception's last line),
    /// shown under `errorMessage` when present.
    var errorDetail: String?
    /// yt-dlp format_id for downloads handled by the embedded yt-dlp
    /// engine; nil for direct-file downloads (URLSession engine).
    var ytDlpFormatID: String?
    /// For split-pair downloads: the audio format_id downloaded
    /// alongside `ytDlpFormatID` (the video format_id) and merged
    /// into the saved file. Nil for single-file downloads.
    var ytDlpAudioFormatID: String?
    /// How the yt-dlp download becomes the saved file
    /// (MediaProcessingKind raw value: direct / remux / transcode).
    /// Nil for items created before the field existed and for
    /// direct-file downloads; the engine treats nil as .direct for
    /// single files and .remux for split pairs (the pre-transcode
    /// behaviour).
    var ytDlpProcessingRawValue: String?

    var ytDlpProcessing: MediaProcessingKind? {
        get { ytDlpProcessingRawValue.flatMap(MediaProcessingKind.init(rawValue:)) }
        set { ytDlpProcessingRawValue = newValue?.rawValue }
    }

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
        durationSeconds: Int? = nil,
        title: String? = nil,
        creatorName: String? = nil
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
        self.title = title
        self.creatorName = creatorName
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

    /// Headline for saved-history rows: the video's real title when it
    /// was captured, otherwise the file name.
    var displayTitle: String { title ?? fileName }

    /// "Creator · duration" subtitle for saved-history rows when
    /// display metadata exists (either part may stand alone). Nil when
    /// the record carries no metadata, so the UI falls back to
    /// "format · size" for those rows.
    var metadataSubtitle: String? {
        let parts = [creatorName, formattedDuration]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
