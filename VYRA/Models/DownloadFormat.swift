import Foundation

enum DownloadFormat: String, CaseIterable, Identifiable, Equatable, Sendable {
    case mp4
    case mov
    case m4a

    var id: String { rawValue }

    var displayName: String { rawValue.uppercased() }

    var fileExtension: String { rawValue }

    var isAudioOnly: Bool { self == .m4a }

    var detailText: String {
        switch self {
        case .mp4: return "Video · Most compatible"
        case .mov: return "Video · High quality"
        case .m4a: return "Audio only"
        }
    }
}

enum DownloadQuality: String, CaseIterable, Identifiable, Equatable, Sendable {
    case p360
    case p720
    case p1080
    case original

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .p360: return "360p"
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .original: return "Original"
        }
    }

    /// Relative size factor used only for mock size estimates.
    var sizeFactor: Double {
        switch self {
        case .p360: return 0.35
        case .p720: return 0.7
        case .p1080: return 1.4
        case .original: return 2.2
        }
    }
}
