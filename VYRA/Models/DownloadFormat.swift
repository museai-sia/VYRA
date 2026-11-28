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

struct DownloadQuality: RawRepresentable, CaseIterable, Identifiable, Hashable, Sendable {
    static let p144 = Self(height: 144)
    static let p240 = Self(height: 240)
    static let p360 = Self(height: 360)
    static let p480 = Self(height: 480)
    static let p720 = Self(height: 720)
    static let p1080 = Self(height: 1080)
    static let p1440 = Self(height: 1440)
    static let p2160 = Self(height: 2160)
    static let original = Self(height: nil)

    static let allCases: [Self] = [.p144, .p240, .p360, .p480, .p720, .p1080, .p1440, .p2160, .original]

    /// Height named by the quality label. A source tier can differ from
    /// the dimensions of the selected stream.
    let heightHint: Int?
    var id: String { rawValue }
    var rawValue: String { heightHint.map { "p\($0)" } ?? "original" }
    var displayName: String { heightHint.map { "\($0)p" } ?? "Original" }

    private init(height: Int?) {
        heightHint = height
    }

    init?(rawValue: String) {
        if rawValue == "original" {
            self = .original
        } else {
            guard rawValue.hasPrefix("p"), let height = Int(rawValue.dropFirst()),
                  let quality = Self.forHeight(height), quality.rawValue == rawValue else { return nil }
            self = quality
        }
    }

    static func forHeight(_ height: Int) -> Self? {
        height > 0 ? Self(height: height) : nil
    }

    static func forLabel(_ label: String?) -> Self? {
        guard let label, label.lowercased().hasSuffix("p"), let height = Int(label.dropLast()) else { return nil }
        return forHeight(height)
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
        default: return 2.2
        }
    }
}
