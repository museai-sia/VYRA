import Foundation

/// Deterministic mock provider for tests and previews ONLY.
/// Its output is always labelled as mock (sourceName "Mock", mock
/// title/creator) and is never wired as the app's production default.
struct MockMetadataProvider: MetadataProvider {
    let id = "mock"
    let displayName = "Mock"
    var delayNanoseconds: UInt64 = 600_000_000

    func canHandle(_ url: URL) -> Bool { true }

    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let videoID = (try? URLValidationService.extractVideoID(from: url)) ?? "mockVideo01"
        return VideoMetadata(
            id: videoID,
            title: Video.mock.title,
            creatorName: Video.mock.author,
            sourceName: "Mock",
            thumbnailURL: nil,
            durationSeconds: Video.mock.durationSeconds,
            publishedAt: nil,
            description: nil,
            sourceURL: url
        )
    }
}
