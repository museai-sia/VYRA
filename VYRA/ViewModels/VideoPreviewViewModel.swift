import Foundation
import Observation

@MainActor
@Observable
final class VideoPreviewViewModel {
    let video: Video
    /// Phase 2 metadata backing this preview, when it came from a fetch.
    let metadata: VideoMetadata?
    var selectedFormat: DownloadFormat = .mp4
    var selectedQuality: DownloadQuality = .p720

    init(video: Video, metadata: VideoMetadata? = nil) {
        self.video = video
        self.metadata = metadata
    }

    convenience init(metadata: VideoMetadata) {
        self.init(video: Video(metadata: metadata), metadata: metadata)
    }

    // MARK: - Metadata-backed display data

    var titleText: String { metadata?.title ?? video.title }
    var channelText: String { metadata?.channelTitle ?? video.author }
    var durationText: String { metadata?.formattedDuration ?? video.formattedDuration }
    var sourceText: String { video.sourceName }
    var sourceURLString: String { metadata?.sourceURL.absoluteString ?? video.sourceURLString }
    var thumbnailURL: URL? { metadata?.thumbnailURL ?? video.thumbnailURL }
    var descriptionText: String? { metadata?.description ?? video.descriptionText }

    var publishedDateText: String? {
        guard let date = metadata?.publishedAt ?? video.publishedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: date)
    }

    /// Audio-only formats have no video quality choice.
    var showsQualitySelection: Bool { !selectedFormat.isAudioOnly }

    /// Base mock size (bytes) for a 720p MP4 of this video's duration.
    private var baseMockBytes: Double {
        Double(max(video.durationSeconds, 1)) * 95_000.0
    }

    var estimatedMockBytes: Int64 {
        let formatFactor: Double
        switch selectedFormat {
        case .mp4: formatFactor = 1.0
        case .mov: formatFactor = 1.35
        case .m4a: formatFactor = 0.12
        }
        let qualityFactor = selectedFormat.isAudioOnly ? 1.0 : selectedQuality.sizeFactor
        return Int64(baseMockBytes * formatFactor * qualityFactor)
    }

    /// Always labelled as an estimate / mock value, never a measurement.
    var estimatedSizeText: String {
        "推定サイズ（モック）: 約 \(ByteCountFormatter.string(fromByteCount: estimatedMockBytes, countStyle: .file))"
    }

    var suggestedFileName: String {
        let base = video.title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(5)
            .joined(separator: "-")
        return (base.isEmpty ? "vyra-video" : base) + "." + selectedFormat.fileExtension
    }

    var selectionSummary: String {
        if selectedFormat.isAudioOnly {
            return "\(selectedFormat.displayName) · Audio"
        }
        return "\(selectedFormat.displayName) · \(selectedQuality.displayName)"
    }

    func makeDownloadItem() -> DownloadItem {
        DownloadItem(
            fileName: suggestedFileName,
            format: selectedFormat,
            quality: selectedQuality,
            fileSizeBytes: estimatedMockBytes,
            state: .waiting,
            thumbnailSymbol: video.thumbnailSymbol,
            sourceURLString: video.sourceURLString
        )
    }
}
