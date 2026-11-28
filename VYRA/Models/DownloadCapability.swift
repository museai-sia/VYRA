import Foundation

/// Phase 3 connection design ONLY — no download implementation exists
/// in Phase 2. These types model whether downloading could ever be
/// permitted for a source, so Phase 3 can build on explicit checks.

enum DownloadSource: String, Codable, Equatable, Sendable {
    case youtube
    case genericHTTPS
    case unknown
}

/// A media format a source reports as available. Only meaningful when
/// the source's download permission is verified.
struct AvailableMediaFormat: Codable, Equatable, Sendable {
    var container: String
    var qualityLabel: String?
    var isAudioOnly: Bool = false
    /// yt-dlp format_id, when this format came from the yt-dlp engine.
    var formatID: String? = nil
    /// True when this format is one stream of a split pair (video-only
    /// or audio-only) and needs the in-process FFmpeg remux to become
    /// a complete file.
    var requiresMerge: Bool = false
    /// Video codec reported by the source (yt-dlp `vcodec`, e.g.
    /// "avc1.640028", "vp09.00.10.08", "none"), if any. Every codec is
    /// carried through: avc1 can be stream-copied into MP4, anything
    /// else is transcoded by the bundled FFmpeg libraries.
    var videoCodec: String? = nil
    /// Audio codec reported by the source (yt-dlp `acodec`, e.g.
    /// "mp4a.40.2", "opus", "none"), if any.
    var audioCodec: String? = nil
    var estimatedFileSize: Int64? = nil
    /// Pixel height reported by the source (yt-dlp `height`), if any.
    var height: Int? = nil
    var width: Int? = nil
    /// Frames per second reported by the source (yt-dlp `fps`), if any.
    var fps: Double? = nil
    /// Total bitrate (kbit/s) reported by the source, if any.
    var totalBitrate: Double? = nil
    /// Delivery protocol reported by the source ("https", "m3u8_native", ...).
    var protocolName: String? = nil
    /// Direct format URL reported by the source, when any. Used only
    /// for its `expire` parameter (staleness guard before download);
    /// never fetched by the app.
    var formatURL: String? = nil
}

/// Whether downloading from a source is permitted.
/// Default is `unknown` — metadata alone never grants permission.
enum DownloadPermission: String, Codable, Equatable, Sendable {
    case unknown
    case verified
    case denied
}

struct DownloadCapability: Codable, Equatable, Sendable {
    var source: DownloadSource
    var permission: DownloadPermission = .unknown
    var availableFormats: [AvailableMediaFormat] = []

    /// Downloadable only when permission is explicitly verified AND at
    /// least one format is known. unknown / denied ⇒ never downloadable.
    var isDownloadable: Bool {
        permission == .verified && !availableFormats.isEmpty
    }

    static func evaluate(metadata: VideoMetadata,
                         permission: DownloadPermission) -> DownloadCapability {
        let source: DownloadSource
        if URLValidationService.youTubeHosts.contains(metadata.sourceURL.host?.lowercased() ?? "") {
            source = .youtube
        } else if metadata.sourceURL.scheme?.lowercased() == "https" {
            source = .genericHTTPS
        } else {
            source = .unknown
        }
        return DownloadCapability(
            source: source,
            permission: permission,
            availableFormats: permission == .verified ? (metadata.availableFormats ?? []) : []
        )
    }
}

/// Capability-evaluation interface (Phase 2 design, kept in Phase 3).
/// Renamed from the Phase 2 placeholder name `DownloadManager` in Phase 3:
/// that name now belongs to the concrete download task manager
/// (`DownloadTaskManager`), and this protocol only *evaluates* whether a
/// source could ever be downloadable — it never executes a download.
protocol DownloadCapabilityEvaluating: Sendable {
    func capability(for metadata: VideoMetadata) -> DownloadCapability
}
