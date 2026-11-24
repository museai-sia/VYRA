import Foundation

protocol VideoMetadataService: Sendable {
    func fetchMetadata(for url: URL) async throws -> Video
}

enum VideoMetadataError: Error, Equatable {
    case invalidURL
}

/// Phase 1 mock. Returns deterministic mock metadata after a short delay.
/// Phase 2 will provide a real, terms-compliant implementation behind the
/// same protocol; no network access happens here.
struct MockVideoMetadataService: VideoMetadataService {
    var delayNanoseconds: UInt64 = 600_000_000

    func fetchMetadata(for url: URL) async throws -> Video {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return Video(
            title: Video.mock.title,
            author: Video.mock.author,
            durationSeconds: Video.mock.durationSeconds,
            sourceName: Video.mock.sourceName,
            sourceURLString: url.absoluteString,
            thumbnailSymbol: Video.mock.thumbnailSymbol
        )
    }
}
