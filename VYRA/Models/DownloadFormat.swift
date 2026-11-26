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
    case p144
    case p240
    case p360
    case p480
    case p720
    case p1080
    case p1440
    case p2160
    case original

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .p144: return "144p"
        case .p240: return "240p"
        case .p360: return "360p"
        case .p480: return "480p"
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "2160p"
        case .original: return "Original"
        }
    }

    /// The pixel height this quality names, when it names one
    /// (`.original` names none — it means "the best available").
    var heightHint: Int? {
        switch self {
        case .p144: return 144
        case .p240: return 240
        case .p360: return 360
        case .p480: return 480
        case .p720: return 720
        case .p1080: return 1080
        case .p1440: return 1440
        case .p2160: return 2160
        case .original: return nil
        }
    }

    /// The quality case for an exact pixel height, when one exists.
    /// Heights without a dedicated case (rare, e.g. 768p) are reached
    /// through `.original`-style best-height selection instead.
    static func forHeight(_ height: Int) -> DownloadQuality? {
        switch height {
        case 144: return .p144
        case 240: return .p240
        case 360: return .p360
        case 480: return .p480
        case 720: return .p720
        case 1080: return .p1080
        case 1440: return .p1440
        case 2160: return .p2160
        default: return nil
        }
    }

    /// Relative size factor used only for mock size estimates.
    var sizeFactor: Double {
        switch self {
        case .p144: return 0.08
        case .p240: return 0.18
        case .p360: return 0.35
        case .p480: return 0.5
        case .p720: return 0.7
        case .p1080: return 1.4
        case .p1440: return 2.0
        case .p2160: return 3.2
        case .original: return 2.2
        }
    }
}
