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

    // MARK: - yt-dlp integration stub: never executes, always unavailable

    func testYtDlpProviderAlwaysThrowsIntegrationUnavailable() async {
        let provider = YtDlpIntegrationProvider()
        XCTAssertTrue(provider.canHandle(watchURL))
        do {
            _ = try await provider.fetchMetadata(for: watchURL)
            XCTFail("expected throw")
        } catch let error as MetadataError {
            guard case .integrationUnavailable(let reason) = error else {
                return XCTFail("expected .integrationUnavailable, got \(error)")
            }
            XCTAssertTrue(reason.contains("iOS"))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testYtDlpProviderDoesNotHandleForeignHosts() {
        let provider = YtDlpIntegrationProvider()
        XCTAssertFalse(provider.canHandle(URL(string: "https://example.com/video")!))
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

    func testAggregatorThrowsUnsupportedSourceWhenNoProviderHandles() async {
        // Aggregator with only the yt-dlp stub: a foreign HTTPS host is
        // handled by no provider.
        let service = VideoMetadataService(providers: [YtDlpIntegrationProvider()])
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
        let service = VideoMetadataService(providers: [
            YtDlpIntegrationProvider(),
            MockMetadataProvider(delayNanoseconds: 0)
        ])
        // First matching provider wins: the yt-dlp stub claims YouTube and
        // throws; reorder so the mock handles it instead.
        let mockFirst = VideoMetadataService(providers: [
            MockMetadataProvider(delayNanoseconds: 0),
            YtDlpIntegrationProvider()
        ])
        let metadata = try await mockFirst.fetchMetadata(for: watchURL)
        XCTAssertEqual(metadata.sourceName, "Mock")
        do {
            _ = try await service.fetchMetadata(for: watchURL)
            XCTFail("expected yt-dlp stub to throw")
        } catch let error as MetadataError {
            guard case .integrationUnavailable = error else {
                return XCTFail("expected .integrationUnavailable, got \(error)")
            }
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testAppDefaultWiringFailsHonestlyForYouTube() async {
        do {
            _ = try await VideoMetadataService.appDefault.fetchMetadata(for: watchURL)
            XCTFail("expected throw")
        } catch let error as MetadataError {
            guard case .integrationUnavailable = error else {
                return XCTFail("expected .integrationUnavailable, got \(error)")
            }
        } catch { XCTFail("wrong error: \(error)") }
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
