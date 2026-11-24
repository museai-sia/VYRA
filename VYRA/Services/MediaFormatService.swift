import Foundation

/// Derives the selectable formats/qualities from information that is
/// actually available (Phase 3, spec §7). Nothing is invented: a format is
/// offered only when a verified source reports it, or when the URL itself
/// is a direct media file.
enum MediaFormatService {
    static let supportedExtensions: Set<String> = ["mp4", "mov", "m4a"]

    static func isDirectMediaURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func directFormat(for url: URL) -> DownloadFormat? {
        DownloadFormat(rawValue: url.pathExtension.lowercased())
    }

    /// The single real option for a direct file URL: its own container and
    /// "Original" quality (there are no other renditions to choose from).
    static func optionsForDirectURL(_ url: URL, contentType: String? = nil, contentLength: Int64? = nil) -> [MediaFormatOption] {
        guard let format = directFormat(for: url) else { return [] }
        return [MediaFormatOption(
            id: "direct-\(format.rawValue)",
            container: format.rawValue,
            fileExtension: format.fileExtension,
            mimeType: contentType ?? MediaFormatOption.mimeType(forExtension: format.fileExtension),
            displayName: format.displayName,
            isVideo: !format.isAudioOnly,
            isAudio: format.isAudioOnly,
            qualityLabel: DownloadQuality.original.displayName,
            estimatedFileSize: contentLength
        )]
    }

    /// Options from a permission-verified source's reported formats.
    static func options(from metadata: VideoMetadata) -> [MediaFormatOption] {
        guard let available = metadata.availableFormats else { return [] }
        return available.compactMap { entry in
            let container = entry.container.lowercased()
            guard let format = DownloadFormat(rawValue: container) else { return nil }
            return MediaFormatOption(
                id: "verified-\(container)-\(entry.qualityLabel ?? "original")",
                container: container,
                fileExtension: format.fileExtension,
                mimeType: MediaFormatOption.mimeType(forExtension: container),
                displayName: format.displayName,
                isVideo: !entry.isAudioOnly && !format.isAudioOnly,
                isAudio: entry.isAudioOnly || format.isAudioOnly,
                qualityLabel: entry.qualityLabel,
                estimatedFileSize: nil
            )
        }
    }

    static func formats(from options: [MediaFormatOption]) -> [DownloadFormat] {
        var seen: [DownloadFormat] = []
        for option in options {
            if let format = option.format, !seen.contains(format) { seen.append(format) }
        }
        return seen
    }

    static func qualities(for format: DownloadFormat, in options: [MediaFormatOption]) -> [DownloadQuality] {
        var seen: [DownloadQuality] = []
        for option in options where option.format == format {
            if !seen.contains(option.quality) { seen.append(option.quality) }
        }
        return seen
    }
}

/// Decides whether — and from which URL — a download may start (spec §6).
/// Only two honest routes exist:
/// 1. The source URL itself is a direct HTTPS media file (.mp4/.mov/.m4a).
/// 2. A permission-verified provider supplied a direct file URL.
/// Everything else (e.g. a YouTube watch page) is refused with a reason.
enum DirectMediaResolver {
    enum Resolution: Equatable, Sendable {
        case downloadable(url: URL, option: MediaFormatOption)
        case unavailable(reason: String)
    }

    static func resolve(sourceURL: URL,
                        format: DownloadFormat,
                        metadata: VideoMetadata? = nil,
                        capability: DownloadCapability? = nil) -> Resolution {
        guard sourceURL.scheme?.lowercased() == "https" else {
            return .unavailable(reason: DownloadError.invalidURL.userMessage)
        }
        if MediaFormatService.isDirectMediaURL(sourceURL) {
            guard MediaFormatService.directFormat(for: sourceURL) == format else {
                return .unavailable(reason: "このURLのファイル形式は \(sourceURL.pathExtension.uppercased()) です。選択した形式とは異なるためダウンロードできません。")
            }
            let option = MediaFormatService.optionsForDirectURL(sourceURL)[0]
            return .downloadable(url: sourceURL, option: option)
        }
        if let capability, capability.isDownloadable,
           let metadata,
           let option = MediaFormatService.options(from: metadata).first(where: { $0.format == format }) {
            // A verified format is known, but downloading still requires the
            // provider to hand out a direct file URL; the watch/page URL
            // itself is never downloaded as if it were a media file.
            _ = option
            return .unavailable(reason: "許可済みソースから直接ファイルURLが提供されていないため、ダウンロードできません。")
        }
        return .unavailable(reason: DownloadError.permissionNotVerified(reason: "no direct file URL").userMessage)
    }
}
