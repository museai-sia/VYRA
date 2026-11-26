import XCTest
@testable import VYRA

final class VideoMetadataTests: XCTestCase {
    private let watchURL = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!

    // MARK: - Mock provider (tests/previews only, labelled mock)

    func testMockProviderReturnsDeterministicMockMetadata() async throws {
        let provider = MockMetadataProvider(delayNanoseconds: 0)
        let metadata = try await provider.fetchMetadata(for: watchURL)
        XCTAssertEqual(metadata.id, "dQw4w9WgXcQ")
        XCTAssertEqual(metadata.sourceName, "Mock")
        XCTAssertFalse(metadata.title.isEmpty)
        XCTAssertFalse(metadata.creatorName.isEmpty)
        XCTAssertGreaterThan(metadata.durationSeconds, 0)
        XCTAssertEqual(metadata.sourceURL, watchURL)
        XCTAssertNil(metadata.availableFormats)
    }

    // MARK: - yt-dlp provider (Phase 4: real engine, mocked in tests)

    func testYtDlpProviderReturnsEngineMetadata() async throws {
        let provider = YtDlpIntegrationProvider(engine: MockYtDlpEngine(stubInfo: .sampleInfo))
        XCTAssertTrue(provider.canHandle(watchURL))
        let metadata = try await provider.fetchMetadata(for: watchURL)
        XCTAssertEqual(metadata.id, "dQw4w9WgXcQ")
        XCTAssertEqual(metadata.title, "Sample Video")
        XCTAssertEqual(metadata.creatorName, "Sample Channel")
        XCTAssertEqual(metadata.durationSeconds, 212)
        XCTAssertEqual(metadata.sourceName, "YouTube")
        let formats = try XCTUnwrap(metadata.availableFormats)
        XCTAssertEqual(Set(formats.compactMap(\.formatID)), ["18", "137", "140"])
    }

    func testYtDlpProviderHandlesPageURLsButNotDirectFilesOrHTTP() {
        let provider = YtDlpIntegrationProvider(engine: MockYtDlpEngine(stubInfo: .sampleInfo))
        // yt-dlp supports many sites, not just YouTube.
        XCTAssertTrue(provider.canHandle(URL(string: "https://example.com/video")!))
        // Direct media files belong to DirectMediaProvider.
        XCTAssertFalse(provider.canHandle(URL(string: "https://example.com/file.mp4")!))
        XCTAssertFalse(provider.canHandle(URL(string: "http://www.youtube.com/watch?v=dQw4w9WgXcQ")!))
    }

    func testYtDlpProviderMapsRuntimeFailureToIntegrationUnavailable() async {
        let engine = MockYtDlpEngine(stubInfo: .sampleInfo)
        engine.extractError = .runtimeUnavailable(reason: "no resources")
        let provider = YtDlpIntegrationProvider(engine: engine)
        do {
            _ = try await provider.fetchMetadata(for: watchURL)
            XCTFail("expected throw")
        } catch let error as MetadataError {
            guard case .integrationUnavailable = error else {
                return XCTFail("expected .integrationUnavailable, got \(error)")
            }
        } catch { XCTFail("wrong error: \(error)") }
    }

    // MARK: - Authorized source provider skeleton

    func testAuthorizedProviderThrowsWhenPermissionUnverified() async {
        let provider = AuthorizedSourceProvider()
        XCTAssertEqual(provider.permission(for: watchURL), .unverified)
        do {
            _ = try await provider.fetchMetadata(for: watchURL)
            XCTFail("expected throw")
        } catch let error as MetadataError {
            XCTAssertEqual(error, .permissionNotVerified)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testAuthorizedProviderVerifiedButNoFetcherThrowsIntegrationUnavailable() async {
        let provider = AuthorizedSourceProvider(verifiedHosts: ["www.youtube.com"])
        XCTAssertEqual(provider.permission(for: watchURL), .verified)
        do {
            _ = try await provider.fetchMetadata(for: watchURL)
            XCTFail("expected throw")
        } catch let error as MetadataError {
            guard case .integrationUnavailable = error else {
                return XCTFail("expected .integrationUnavailable, got \(error)")
            }
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testAuthorizedProviderVerifiedWithFetcherReturnsMetadata() async throws {
        let expected = VideoMetadata(
            id: "abc", title: "Permitted", creatorName: "Creator", sourceName: "Example",
            thumbnailURL: nil, durationSeconds: 10, publishedAt: nil, description: nil,
            sourceURL: URL(string: "https://example.com/video")!
        )
        let provider = AuthorizedSourceProvider(verifiedHosts: ["example.com"]) { _ in expected }
        let metadata = try await provider.fetchMetadata(for: URL(string: "https://example.com/video")!)
        XCTAssertEqual(metadata, expected)
    }

    // MARK: - Aggregator

    /// A provider that handles nothing, for aggregator contract tests.
    private struct NeverHandlesProvider: MetadataProvider {
        let id = "never"
        let displayName = "Never"
        func canHandle(_ url: URL) -> Bool { false }
        func fetchMetadata(for url: URL) async throws -> VideoMetadata {
            throw MetadataError.unsupportedSource
        }
    }

    func testAggregatorThrowsUnsupportedSourceWhenNoProviderHandles() async {
        // Aggregator whose only provider handles nothing: any URL must
        // surface as unsupportedSource. (The Phase 2 stub provider used
        // to play this role; the real yt-dlp provider now handles all
        // HTTPS page URLs by design.)
        let service = VideoMetadataService(providers: [NeverHandlesProvider()])
        do {
            _ = try await service.fetchMetadata(for: URL(string: "https://example.com/video")!)
            XCTFail("expected throw")
        } catch let error as MetadataError {
            XCTAssertEqual(error, .unsupportedSource)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testAggregatorRejectsNonHTTPS() async {
        let service = VideoMetadataService(providers: [MockMetadataProvider(delayNanoseconds: 0)])
        do {
            _ = try await service.fetchMetadata(for: URL(string: "http://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
            XCTFail("expected throw")
        } catch let error as MetadataError {
            XCTAssertEqual(error, .urlValidation(.invalidFormat))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testAggregatorDelegatesToHandlingProvider() async throws {
        let ytDlp = YtDlpIntegrationProvider(engine: MockYtDlpEngine(stubInfo: .sampleInfo))
        let service = VideoMetadataService(providers: [
            ytDlp,
            MockMetadataProvider(delayNanoseconds: 0)
        ])
        // First matching provider wins: yt-dlp claims YouTube here.
        let metadata = try await service.fetchMetadata(for: watchURL)
        XCTAssertEqual(metadata.sourceName, "YouTube")
        let mockFirst = VideoMetadataService(providers: [
            MockMetadataProvider(delayNanoseconds: 0),
            ytDlp
        ])
        let mockMetadata = try await mockFirst.fetchMetadata(for: watchURL)
        XCTAssertEqual(mockMetadata.sourceName, "Mock")
    }

    func testAppDefaultRoutesYouTubeToYtDlpProvider() {
        // Wiring check only (no fetch): the app default's yt-dlp provider
        // must be the first provider that claims a YouTube watch URL.
        let service = VideoMetadataService.appDefault
        let handler = service.providers.first(where: { $0.canHandle(watchURL) })
        XCTAssertEqual(handler?.id, "yt-dlp")
    }

    // MARK: - DownloadCapability (Phase 3 design only)

    private func makeMetadata(formats: [AvailableMediaFormat]? = nil) -> VideoMetadata {
        VideoMetadata(
            id: "dQw4w9WgXcQ", title: "T", creatorName: "C", sourceName: "YouTube",
            thumbnailURL: nil, durationSeconds: 60, publishedAt: nil, description: nil,
            sourceURL: watchURL, availableFormats: formats
        )
    }

    func testCapabilityFalseForUnknownPermission() {
        let capability = DownloadCapability.evaluate(
            metadata: makeMetadata(formats: [AvailableMediaFormat(container: "mp4")]),
            permission: .unknown
        )
        XCTAssertFalse(capability.isDownloadable)
        XCTAssertTrue(capability.availableFormats.isEmpty)
    }

    func testCapabilityFalseForDeniedPermission() {
        let capability = DownloadCapability.evaluate(
            metadata: makeMetadata(formats: [AvailableMediaFormat(container: "mp4")]),
            permission: .denied
        )
        XCTAssertFalse(capability.isDownloadable)
    }

    func testCapabilityTrueOnlyForVerifiedWithFormats() {
        let verified = DownloadCapability.evaluate(
            metadata: makeMetadata(formats: [AvailableMediaFormat(container: "mp4", qualityLabel: "720p")]),
            permission: .verified
        )
        XCTAssertTrue(verified.isDownloadable)
        XCTAssertEqual(verified.source, .youtube)

        let verifiedNoFormats = DownloadCapability.evaluate(
            metadata: makeMetadata(), permission: .verified
        )
        XCTAssertFalse(verifiedNoFormats.isDownloadable)
    }

    // MARK: - Model helpers

    func testISO8601DurationParsing() {
        XCTAssertEqual(VideoMetadata.parseISO8601Duration("PT1H2M3S"), 3723)
        XCTAssertEqual(VideoMetadata.parseISO8601Duration("PT15M"), 900)
        XCTAssertEqual(VideoMetadata.parseISO8601Duration("PT45S"), 45)
        XCTAssertEqual(VideoMetadata.parseISO8601Duration("PT2H"), 7200)
        XCTAssertEqual(VideoMetadata.parseISO8601Duration(""), 0)
    }

    func testVideoBridgingFromMetadata() {
        let metadata = VideoMetadata(
            id: "dQw4w9WgXcQ", title: "T", creatorName: "C", sourceName: "YouTube",
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/x/hq.jpg"),
            durationSeconds: 90, publishedAt: Date(timeIntervalSince1970: 0),
            description: "D", sourceURL: watchURL
        )
        let video = Video(metadata: metadata)
        XCTAssertEqual(video.title, "T")
        XCTAssertEqual(video.author, "C")
        XCTAssertEqual(video.externalID, "dQw4w9WgXcQ")
        XCTAssertEqual(video.thumbnailURL, metadata.thumbnailURL)
        XCTAssertEqual(video.sourceName, "YouTube")
    }
}
