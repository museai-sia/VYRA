import XCTest
@testable import VYRA

final class URLValidationTests: XCTestCase {
    private func parse(_ s: String) throws -> (url: URL, videoID: String) {
        try URLValidationService.parse(s)
    }

    func testWatchURL() throws {
        let result = try parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(result.videoID, "dQw4w9WgXcQ")
    }

    func testWatchURLWithExtraQueryParameters() throws {
        let result = try parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&list=PL123")
        XCTAssertEqual(result.videoID, "dQw4w9WgXcQ")
    }

    func testShortenedURL() throws {
        XCTAssertEqual(try parse("https://youtu.be/dQw4w9WgXcQ").videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(try parse("https://youtu.be/dQw4w9WgXcQ?si=abc").videoID, "dQw4w9WgXcQ")
    }

    func testShortsURL() throws {
        XCTAssertEqual(try parse("https://www.youtube.com/shorts/dQw4w9WgXcQ").videoID, "dQw4w9WgXcQ")
    }

    func testEmbedURL() throws {
        XCTAssertEqual(try parse("https://www.youtube.com/embed/dQw4w9WgXcQ").videoID, "dQw4w9WgXcQ")
    }

    func testLiveURL() throws {
        XCTAssertEqual(try parse("https://www.youtube.com/live/dQw4w9WgXcQ").videoID, "dQw4w9WgXcQ")
    }

    func testSupportedHosts() throws {
        for host in ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"] {
            XCTAssertEqual(try parse("https://\(host)/watch?v=dQw4w9WgXcQ").videoID, "dQw4w9WgXcQ", host)
        }
    }

    func testEmptyThrowsEmpty() {
        XCTAssertThrowsError(try parse("")) { XCTAssertEqual($0 as? URLValidationError, .empty) }
        XCTAssertThrowsError(try parse("   ")) { XCTAssertEqual($0 as? URLValidationError, .empty) }
    }

    func testInvalidFormatThrows() {
        XCTAssertThrowsError(try parse("not a url")) { XCTAssertEqual($0 as? URLValidationError, .invalidFormat) }
        XCTAssertThrowsError(try parse("ftp://www.youtube.com/watch?v=dQw4w9WgXcQ")) {
            XCTAssertEqual($0 as? URLValidationError, .invalidFormat)
        }
    }

    func testMissingVideoID() {
        XCTAssertThrowsError(try parse("https://www.youtube.com/watch")) {
            XCTAssertEqual($0 as? URLValidationError, .missingVideoID)
        }
        XCTAssertThrowsError(try parse("https://www.youtube.com/watch?t=10")) {
            XCTAssertEqual($0 as? URLValidationError, .missingVideoID)
        }
        XCTAssertThrowsError(try parse("https://youtu.be/")) {
            XCTAssertEqual($0 as? URLValidationError, .missingVideoID)
        }
        XCTAssertThrowsError(try parse("https://www.youtube.com/")) {
            XCTAssertEqual($0 as? URLValidationError, .missingVideoID)
        }
    }

    func testInvalidVideoID() {
        XCTAssertThrowsError(try parse("https://www.youtube.com/watch?v=short")) {
            XCTAssertEqual($0 as? URLValidationError, .invalidVideoID)
        }
        XCTAssertThrowsError(try parse("https://youtu.be/dQw4w9WgXcQtoolong")) {
            XCTAssertEqual($0 as? URLValidationError, .invalidVideoID)
        }
        XCTAssertThrowsError(try parse("https://www.youtube.com/shorts/dQw4w9WgXc!")) {
            XCTAssertEqual($0 as? URLValidationError, .invalidVideoID)
        }
    }

    func testForeignHostUnsupported() {
        XCTAssertThrowsError(try parse("https://example.com/watch?v=dQw4w9WgXcQ")) {
            XCTAssertEqual($0 as? URLValidationError, .unsupportedHost)
        }
        XCTAssertThrowsError(try parse("https://vimeo.com/12345678901")) {
            XCTAssertEqual($0 as? URLValidationError, .unsupportedHost)
        }
    }

    func testLookalikeHostsRejected() {
        for s in [
            "https://youtube.com.evil.com/watch?v=dQw4w9WgXcQ",
            "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com.evil.com/watch?v=dQw4w9WgXcQ",
            "https://fake-youtube.com/watch?v=dQw4w9WgXcQ"
        ] {
            XCTAssertThrowsError(try parse(s), s) { XCTAssertEqual($0 as? URLValidationError, .unsupportedHost) }
        }
    }

    func testGenericValidatorStillAcceptsExampleCom() {
        // Phase 1 generic syntax validation is preserved.
        XCTAssertTrue(URLValidator.isValidVideoURL("https://example.com/video/123"))
    }
}
