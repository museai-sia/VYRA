import Foundation

protocol VideoMetadataService: Sendable {
    func fetchMetadata(for url: URL) async throws -> VideoMetadata
}

enum VideoMetadataError: Error, Equatable, Sendable {
    case invalidURL
    case urlValidation(URLValidationError)
    case apiKeyMissing
    case httpError(Int)
    case quotaExceeded
    case notFound
    case network(String)
    case decoding
    case invalidResponse
    case cancelled
}

/// Deterministic mock used by tests and previews. Never presented as
/// real fetched data by the production default path (see HomeViewModel).
struct MockVideoMetadataService: VideoMetadataService {
    var delayNanoseconds: UInt64 = 600_000_000

    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let videoID = (try? URLValidationService.extractVideoID(from: url)) ?? "mockVideo01"
        return VideoMetadata(
            id: videoID,
            title: Video.mock.title,
            channelTitle: Video.mock.author,
            thumbnailURL: nil,
            durationSeconds: Video.mock.durationSeconds,
            publishedAt: nil,
            description: nil,
            sourceURL: url
        )
    }
}

/// Used as the production default when no YouTube API key is configured.
/// Fails clearly instead of silently substituting mock data as real.
struct UnconfiguredVideoMetadataService: VideoMetadataService {
    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        // Still validate the URL first so users get URL errors, not key errors,
        // for malformed input.
        _ = try URLValidationService.extractVideoID(from: url)
        throw VideoMetadataError.apiKeyMissing
    }
}
