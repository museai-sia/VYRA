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
    var channelText: String { metadata?.creatorName ?? video.author }
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

    // MARK: - Phase 3: actually-available formats

    /// Options derived ONLY from real information (spec §7): a direct
    /// media file URL yields exactly its own format; verified metadata
    /// yields its reported formats. When metadata is absent (Phase 1 mock
    /// preview), this is empty and the legacy all-formats picker is used,
    /// clearly labelled as mock behaviour.
    var availableOptions: [MediaFormatOption] {
        guard let metadata else { return [] }
        if MediaFormatService.isDirectMediaURL(metadata.sourceURL) {
            return MediaFormatService.optionsForDirectURL(metadata.sourceURL)
        }
        return MediaFormatService.options(from: metadata)
    }

    var hasVerifiedOptions: Bool { !availableOptions.isEmpty }

    var availableFormats: [DownloadFormat] {
        hasVerifiedOptions ? MediaFormatService.formats(from: availableOptions) : Array(DownloadFormat.allCases)
    }

    var availableQualities: [DownloadQuality] {
        guard hasVerifiedOptions else { return Array(DownloadQuality.allCases) }
        let qualities = MediaFormatService.qualities(for: selectedFormat, in: availableOptions)
        return qualities.isEmpty ? [.original] : qualities
    }

    /// Keeps the selection inside the actually-available options.
    func reconcileSelection() {
        if hasVerifiedOptions, !availableFormats.contains(selectedFormat),
           let first = availableFormats.first {
            selectedFormat = first
        }
        if !availableQualities.contains(selectedQuality),
           let first = availableQualities.first {
            selectedQuality = first
        }
    }

    var sourceURL: URL? { metadata?.sourceURL ?? URL(string: video.sourceURLString) }

    /// Whether the current selection can really be downloaded, and why not.
    var downloadResolution: DirectMediaResolver.Resolution? {
        guard let sourceURL else { return nil }
        return DirectMediaResolver.resolve(
            sourceURL: sourceURL, format: selectedFormat, quality: selectedQuality, metadata: metadata)
    }

    /// The yt-dlp format_id of the current selection, when the download
    /// will be handled by the yt-dlp engine.
    var selectedYtDlpFormatID: String? {
        if case .ytDlp(let formatID, _, _) = downloadResolution { return formatID }
        return nil
    }

    /// The audio format_id when the current selection is a split pair
    /// (the video format_id is `selectedYtDlpFormatID`).
    var selectedYtDlpAudioFormatID: String? {
        if case .ytDlp(_, let audioFormatID, _) = downloadResolution { return audioFormatID }
        return nil
    }

    var isDownloadable: Bool {
        if case .downloadable = downloadResolution { return true }
        if case .ytDlp = downloadResolution { return true }
        return false
    }

    var downloadUnavailableReason: String? {
        if case .unavailable(let reason) = downloadResolution { return reason }
        return nil
    }

    /// Known size for the current selection, when a real source reported
    /// one. Never a guess: nil means "unknown" and the UI omits the row.
    var knownFileSize: Int64? {
        selectedOption?.estimatedFileSize
    }

    var selectedOption: MediaFormatOption? {
        MediaFormatService.selectOption(
            in: availableOptions, format: selectedFormat, quality: selectedQuality)
    }

    /// True when the selected format's URL expiry (googlevideo
    /// `expire` − 60s, the worker.js rule) has passed since the
    /// metadata was fetched. Downloads re-resolve URLs inside yt-dlp,
    /// so this is a guard against starting a flow on a selection made
    /// from long-stale metadata: the user re-fetches instead of
    /// failing mid-flow.
    var selectionIsStale: Bool {
        selectedOption?.isStale() ?? false
    }

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
        let item = DownloadItem(
            fileName: suggestedFileName,
            format: selectedFormat,
            quality: selectedQuality,
            fileSizeBytes: knownFileSize ?? estimatedMockBytes,
            state: .waiting,
            thumbnailSymbol: video.thumbnailSymbol,
            sourceURLString: sourceURLString,
            mimeType: MediaFormatOption.mimeType(forExtension: selectedFormat.fileExtension),
            thumbnailURLString: thumbnailURL?.absoluteString,
            durationSeconds: (metadata?.durationSeconds ?? video.durationSeconds) > 0
                ? (metadata?.durationSeconds ?? video.durationSeconds) : nil,
            title: titleText,
            creatorName: channelText
        )
        item.ytDlpFormatID = selectedYtDlpFormatID
        item.ytDlpAudioFormatID = selectedYtDlpAudioFormatID
        if case .ytDlp(_, _, let option) = downloadResolution {
            item.ytDlpProcessing = option.processing
        }
        return item
    }

    /// Builds the item for the confirmation screen with a user-edited,
    /// validated file name (extension protected, spec §8).
    func makeDownloadItem(fileName: String) throws -> DownloadItem {
        let validated = try FileNameValidator.validate(fileName: fileName, format: selectedFormat)
        var item = makeDownloadItem()
        item.fileName = validated
        return item
    }
}
