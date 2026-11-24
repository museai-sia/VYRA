import Foundation

/// A concrete, actually-available format/quality combination (Phase 3, spec §7).
/// Built only from real information: a verified source's reported formats, or a
/// direct media file's extension / Content-Type / Content-Length. Unknown
/// fields stay nil.
struct MediaFormatOption: Identifiable, Equatable, Sendable {
    var id: String
    var container: String
    var fileExtension: String
    var mimeType: String?
    var displayName: String
    var isVideo: Bool
    var isAudio: Bool
    var qualityLabel: String?
    var estimatedFileSize: Int64?

    var format: DownloadFormat? { DownloadFormat(rawValue: fileExtension.lowercased()) }

    var quality: DownloadQuality {
        switch qualityLabel?.lowercased() {
        case "360p": return .p360
        case "720p": return .p720
        case "1080p": return .p1080
        default: return .original
        }
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }

    static func format(forMimeType mime: String) -> DownloadFormat? {
        switch mime.lowercased() {
        case "video/mp4": return .mp4
        case "video/quicktime": return .mov
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return .m4a
        default: return nil
        }
    }
}
