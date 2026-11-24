import Foundation
import Observation

@MainActor
@Observable
final class VideoPreviewViewModel {
    let video: Video
    var selectedFormat: DownloadFormat = .mp4
    var selectedQuality: DownloadQuality = .p720

    init(video: Video) {
        self.video = video
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
