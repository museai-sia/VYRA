import Foundation

enum MetadataError: Error, Equatable, Sendable {
    case urlValidation(URLValidationError)
    /// No configured provider can handle this source.
    case unsupportedSource
    /// An integration (e.g. yt-dlp) cannot run inside the iOS app.
    case integrationUnavailable(reason: String)
    /// The source's terms/permission have not been verified.
    case permissionNotVerified
    case notFound
    case network(String)
    case decoding
    case invalidResponse
    case cancelled
}

/// The abstraction the ViewModels depend on.
protocol VideoMetadataFetching: Sendable {
    func fetchMetadata(for url: URL) async throws -> VideoMetadata
}

/// A single metadata source integration.
protocol MetadataProvider: VideoMetadataFetching {
    var id: String { get }
    var displayName: String { get }
    func canHandle(_ url: URL) -> Bool
}

/// Aggregating service: validates the URL, then delegates to the first
/// provider that can handle it. Throws `unsupportedSource` when none can.
struct VideoMetadataService: VideoMetadataFetching {
    var providers: [any MetadataProvider]

    init(providers: [any MetadataProvider]) {
        self.providers = providers
    }

    /// App default: authorized-source skeleton + yt-dlp interface stub.
    /// Real URLs therefore fail with a clear, actionable error instead of
    /// silently receiving mock data presented as real. The mock provider
    /// is injected only in tests and previews.
    static var appDefault: VideoMetadataService {
        VideoMetadataService(providers: [
            YtDlpIntegrationProvider(),
            AuthorizedSourceProvider()
        ])
    }

    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        let validated: ValidatedSource
        do {
            validated = try URLValidationService.validate(url.absoluteString)
        } catch let error as URLValidationError {
            throw MetadataError.urlValidation(error)
        }
        guard let provider = providers.first(where: { $0.canHandle(validated.url) }) else {
            throw MetadataError.unsupportedSource
        }
        return try await provider.fetchMetadata(for: validated.url)
    }
}
