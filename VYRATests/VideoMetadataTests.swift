import XCTest
@testable import VYRA

/// Stub HTTP client: returns a fixed response or throws, never networks.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    var statusCode: Int = 200
    var body: Data = Data()
    var error: Error?
    var delayNanoseconds: UInt64 = 0
    private(set) var lastRequest: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if let error { throw error }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

final class VideoMetadataTests: XCTestCase {
    private let watchURL = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!

    static let fullJSON = """
    {
      "items": [{
        "id": "dQw4w9WgXcQ",
        "snippet": {
          "title": "Test Title",
          "channelTitle": "Test Channel",
          "publishedAt": "2024-01-15T12:34:56Z",
          "description": "A description",
          "thumbnails": {
            "default": {"url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/default.jpg"},
            "medium": {"url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg"},
            "high": {"url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"},
            "maxres": {"url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg"}
          }
        },
        "contentDetails": {"duration": "PT1H2M3S"}
      }]
    }
    """

    private func makeService(_ stub: StubHTTPClient, key: String? = "test-key") -> YouTubeDataAPIService {
        YouTubeDataAPIService(apiKey: key, httpClient: stub)
    }

    func testSuccessfulFetchMapsAllFields() async throws {
        let stub = StubHTTPClient()
        stub.body = Data(Self.fullJSON.utf8)
        let metadata = try await makeService(stub).fetchMetadata(for: watchURL)
        XCTAssertEqual(metadata.id, "dQw4w9WgXcQ")
        XCTAssertEqual(metadata.title, "Test Title")
        XCTAssertEqual(metadata.channelTitle, "Test Channel")
        XCTAssertEqual(metadata.durationSeconds, 3723)
        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg")
        XCTAssertNotNil(metadata.publishedAt)
        XCTAssertEqual(metadata.description, "A description")
        XCTAssertEqual(metadata.sourceURL, watchURL)
        // Endpoint / query shape
        let requestURL = try XCTUnwrap(stub.lastRequest?.url)
        XCTAssertEqual(requestURL.host, "www.googleapis.com")
        XCTAssertEqual(requestURL.path, "/youtube/v3/videos")
    }

    func testMissingOptionalFieldsBecomeNil() async throws {
        let stub = StubHTTPClient()
        stub.body = Data("""
        {"items": [{"id": "dQw4w9WgXcQ",
                     "snippet": {"title": "Only Title"},
                     "contentDetails": {"duration": "PT45S"}}]}
        """.utf8)
        let metadata = try await makeService(stub).fetchMetadata(for: watchURL)
        XCTAssertEqual(metadata.title, "Only Title")
        XCTAssertEqual(metadata.channelTitle, "")
        XCTAssertNil(metadata.thumbnailURL)
        XCTAssertNil(metadata.publishedAt)
        XCTAssertNil(metadata.description)
        XCTAssertEqual(metadata.durationSeconds, 45)
    }

    func testMissingSnippetThrowsInvalidResponse() async {
        let stub = StubHTTPClient()
        stub.body = Data(#"{"items": [{"id": "dQw4w9WgXcQ"}]}"#.utf8)
        do {
            _ = try await makeService(stub).fetchMetadata(for: watchURL)
            XCTFail("expected throw")
        } catch let error as VideoMetadataError {
            XCTAssertEqual(error, .invalidResponse)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testInvalidJSONThrowsDecoding() async {
        let stub = StubHTTPClient()
        stub.body = Data("this is not json".utf8)
        do {
            _ = try await makeService(stub).fetchMetadata(for: watchURL)
            XCTFail("expected throw")
        } catch let error as VideoMetadataError {
            XCTAssertEqual(error, .decoding)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testHTTPErrorMapped() async {
        let stub = StubHTTPClient()
        stub.statusCode = 500
        do {
            _ = try await makeService(stub).fetchMetadata(for: watchURL)
            XCTFail("expected throw")
        } catch let error as VideoMetadataError {
            XCTAssertEqual(error, .httpError(500))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testQuotaErrorsMapped() async {
        for code in [403, 429] {
            let stub = StubHTTPClient()
            stub.statusCode = code
            do {
                _ = try await makeService(stub).fetchMetadata(for: watchURL)
                XCTFail("expected throw for \(code)")
            } catch let error as VideoMetadataError {
                XCTAssertEqual(error, .quotaExceeded)
            } catch { XCTFail("wrong error: \(error)") }
        }
    }

    func testNetworkFailureMapped() async {
        let stub = StubHTTPClient()
        stub.error = URLError(.notConnectedToInternet)
        do {
            _ = try await makeService(stub).fetchMetadata(for: watchURL)
            XCTFail("expected throw")
        } catch let error as VideoMetadataError {
            guard case .network = error else { return XCTFail("expected .network, got \(error)") }
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testEmptyItemsThrowsNotFound() async {
        let stub = StubHTTPClient()
        stub.body = Data(#"{"items": []}"#.utf8)
        do {
            _ = try await makeService(stub).fetchMetadata(for: watchURL)
            XCTFail("expected throw")
        } catch let error as VideoMetadataError {
            XCTAssertEqual(error, .notFound)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testNoThumbnailWhenThumbnailsAbsent() async throws {
        let stub = StubHTTPClient()
        stub.body = Data("""
        {"items": [{"id": "dQw4w9WgXcQ", "snippet": {"title": "T", "channelTitle": "C"}}]}
        """.utf8)
        let metadata = try await makeService(stub).fetchMetadata(for: watchURL)
        XCTAssertNil(metadata.thumbnailURL)
    }

    func testThumbnailPreferenceFallsBackToHigh() async throws {
        let stub = StubHTTPClient()
        stub.body = Data("""
        {"items": [{"id": "dQw4w9WgXcQ",
                     "snippet": {"title": "T",
                                 "thumbnails": {"default": {"url": "https://x/default.jpg"},
                                                "high": {"url": "https://x/high.jpg"}}}}]}
        """.utf8)
        let metadata = try await makeService(stub).fetchMetadata(for: watchURL)
        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://x/high.jpg")
    }

    func testMissingAPIKeyThrows() async {
        let stub = StubHTTPClient()
        do {
            _ = try await makeService(stub, key: nil).fetchMetadata(for: watchURL)
            XCTFail("expected throw")
        } catch let error as VideoMetadataError {
            XCTAssertEqual(error, .apiKeyMissing)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testNonYouTubeURLThrowsValidationError() async {
        let stub = StubHTTPClient()
        do {
            _ = try await makeService(stub).fetchMetadata(for: URL(string: "https://example.com/watch?v=dQw4w9WgXcQ")!)
            XCTFail("expected throw")
        } catch let error as VideoMetadataError {
            XCTAssertEqual(error, .urlValidation(.unsupportedHost))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testISO8601DurationParsing() {
        XCTAssertEqual(VideoMetadata.parseISO8601Duration("PT1H2M3S"), 3723)
        XCTAssertEqual(VideoMetadata.parseISO8601Duration("PT15M"), 900)
        XCTAssertEqual(VideoMetadata.parseISO8601Duration("PT45S"), 45)
        XCTAssertEqual(VideoMetadata.parseISO8601Duration("PT2H"), 7200)
        XCTAssertEqual(VideoMetadata.parseISO8601Duration(""), 0)
        XCTAssertEqual(VideoMetadata.parseISO8601Duration("P1D"), 0)
    }

    func testVideoBridgingFromMetadata() {
        let metadata = VideoMetadata(
            id: "dQw4w9WgXcQ", title: "T", channelTitle: "C",
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

    func testConfiguredAPIKeyFromEnvironment() {
        XCTAssertEqual(
            YouTubeDataAPIService.configuredAPIKey(infoDictionary: [:], environment: ["YOUTUBE_API_KEY": "abc"]),
            "abc"
        )
        XCTAssertNil(YouTubeDataAPIService.configuredAPIKey(infoDictionary: [:], environment: [:]))
        XCTAssertNil(YouTubeDataAPIService.configuredAPIKey(
            infoDictionary: ["YouTubeAPIKey": "$(YOUTUBE_API_KEY)"], environment: [:]
        ))
    }
}
