import Foundation

enum URLValidationError: Error, Equatable, Sendable {
    case empty
    case invalidFormat
    case unsupportedHost
    case missingVideoID
    case invalidVideoID
}

/// Classification of a validated URL's source.
enum SourceKind: String, Equatable, Sendable {
    case youtube
    case genericHTTPS
    case unsupported
}

/// Result of general URL validation (Phase 2 revised spec).
struct ValidatedSource: Equatable, Sendable {
    var url: URL
    var kind: SourceKind
    /// Present only for YouTube URLs.
    var videoID: String?
}

/// Structured URL parsing via URLComponents.
/// Validates host / path / query — never simple string replacement.
struct URLValidationService: Sendable {
    static let youTubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"
    ]
    /// Kept name for compatibility with Phase 2 tests.
    static var supportedHosts: Set<String> { youTubeHosts }

    static func isValidVideoID(_ id: String) -> Bool {
        guard id.count == 11 else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Looks like a YouTube host but is not an exact supported host
    /// (e.g. youtube.com.evil.com, notyoutube.com) — always rejected.
    static func isLookalikeYouTubeHost(_ host: String) -> Bool {
        (host.contains("youtube") || host.contains("youtu.be")) && !youTubeHosts.contains(host)
    }

    static func classify(host: String) -> SourceKind {
        if youTubeHosts.contains(host) { return .youtube }
        if isLookalikeYouTubeHost(host) { return .unsupported }
        return .genericHTTPS
    }

    /// General validation used by the metadata aggregator.
    /// HTTPS is required; non-HTTPS input is rejected as invalidFormat.
    static func validate(_ string: String) throws -> ValidatedSource {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw URLValidationError.empty }
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty, host.contains("."),
              let url = components.url else {
            throw URLValidationError.invalidFormat
        }
        switch classify(host: host) {
        case .unsupported:
            throw URLValidationError.unsupportedHost
        case .youtube:
            return ValidatedSource(url: url, kind: .youtube, videoID: try extractVideoID(from: url))
        case .genericHTTPS:
            return ValidatedSource(url: url, kind: .genericHTTPS, videoID: nil)
        }
    }

    /// YouTube-specific parse (watch / youtu.be / shorts / embed / live).
    static func parse(_ string: String) throws -> (url: URL, videoID: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw URLValidationError.empty }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let url = components.url else {
            throw URLValidationError.invalidFormat
        }
        let videoID = try extractVideoID(from: url)
        return (url, videoID)
    }

    static func extractVideoID(from url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else {
            throw URLValidationError.invalidFormat
        }
        guard youTubeHosts.contains(host) else {
            throw URLValidationError.unsupportedHost
        }
        let segments = components.path.split(separator: "/").map(String.init)

        let candidate: String?
        if host == "youtu.be" {
            candidate = segments.first
        } else if components.path == "/watch" {
            candidate = components.queryItems?.first(where: { $0.name == "v" })?.value
        } else if let first = segments.first, ["shorts", "embed", "live"].contains(first) {
            candidate = segments.count > 1 ? segments[1] : nil
        } else {
            candidate = nil
        }
        guard let candidate, !candidate.isEmpty else {
            throw URLValidationError.missingVideoID
        }
        guard isValidVideoID(candidate) else {
            throw URLValidationError.invalidVideoID
        }
        return candidate
    }
}
