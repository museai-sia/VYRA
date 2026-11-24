import Foundation

enum URLValidationError: Error, Equatable, Sendable {
    case empty
    case invalidFormat
    case unsupportedHost
    case missingVideoID
    case invalidVideoID
}

/// Structured YouTube URL parsing via URLComponents.
/// Validates host / path / query — never simple string replacement.
struct URLValidationService: Sendable {
    static let supportedHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"
    ]

    static func isValidVideoID(_ id: String) -> Bool {
        guard id.count == 11 else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Parses a string into (normalized URL, videoID) or throws a distinct error.
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
        guard supportedHosts.contains(host) else {
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
