import Foundation

/// App-internal video metadata model (Phase 2). `id` is the source's
/// video ID (for YouTube, the 11-character video ID), not a UUID.
/// Unknown values are always nil — never guessed or filled in.
struct VideoMetadata: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    /// Creator / channel name (mapped to `Video.author` for display).
    var creatorName: String
    /// Human-readable source name, e.g. "YouTube" or "Mock".
    var sourceName: String
    var thumbnailURL: URL?
    var durationSeconds: Int
    var publishedAt: Date?
    var description: String?
    var sourceURL: URL
    /// Only populated when the source's download permission is verified
    /// (see DownloadCapability). Default nil: metadata alone never
    /// implies downloadable formats.
    var availableFormats: [AvailableMediaFormat]? = nil

    var formattedDuration: String {
        let h = durationSeconds / 3600
        let m = (durationSeconds % 3600) / 60
        let s = durationSeconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Parses an ISO 8601 duration such as "PT1H2M3S", "PT15M", "PT45S".
    static func parseISO8601Duration(_ string: String) -> Int {
        guard string.hasPrefix("PT") else { return 0 }
        var total = 0
        var number = ""
        for ch in string.dropFirst(2) {
            if ch.isNumber { number.append(ch); continue }
            let value = Int(number) ?? 0
            number = ""
            switch ch {
            case "H": total += value * 3600
            case "M": total += value * 60
            case "S": total += value
            default: break
            }
        }
        return total
    }

    static func parseISO8601Date(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
