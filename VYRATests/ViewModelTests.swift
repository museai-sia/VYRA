import XCTest
@testable import VYRA

/// Fetch stub whose behaviour can be flipped between calls (for retry).
final class FlippableService: VideoMetadataFetching, @unchecked Sendable {
    var shouldFail = true
    var delayNanoseconds: UInt64 = 0
    private(set) var callCount = 0

    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        callCount += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if shouldFail { throw MetadataError.network("stub failure") }
        return VideoMetadata(
            id: "dQw4w9WgXcQ", title: "Fetched", creatorName: "Channel", sourceName: "Stub",
            thumbnailURL: nil, durationSeconds: 60, publishedAt: nil,
            description: nil, sourceURL: url
        )
    }
}

@MainActor
final class ViewModelTests: XCTestCase {
    private let youTubeURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    func testLoadingThenSuccess() async {
        let service = FlippableService()
        service.shouldFail = false
        let vm = HomeViewModel(metadataService: service)
        vm.urlString = youTubeURL
        let video = await vm.fetchVideoInfo()
        XCTAssertNotNil(video)
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.fetchedMetadata?.title, "Fetched")
        XCTAssertEqual(vm.recentFetches.count, 1)
        XCTAssertNil(vm.errorMessage)
    }

    func testFailureSetsFailedStateAndMessage() async {
        let service = FlippableService()
        service.shouldFail = true
        let vm = HomeViewModel(metadataService: service)
        vm.urlString = youTubeURL
        let video = await vm.fetchVideoInfo()
        XCTAssertNil(video)
        XCTAssertEqual(vm.state, .failed)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.recentFetches.isEmpty)
    }

    func testRetrySucceedsAfterFailure() async {
        let service = FlippableService()
        let vm = HomeViewModel(metadataService: service)
        vm.urlString = youTubeURL
        let firstResult = await vm.fetchVideoInfo()
        XCTAssertNil(firstResult)
        XCTAssertEqual(vm.state, .failed)
        service.shouldFail = false
        let video = await vm.retry()
        XCTAssertNotNil(video)
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertEqual(service.callCount, 2)
    }

    func testDuplicateRequestPrevented() async {
        let service = FlippableService()
        service.shouldFail = false
        service.delayNanoseconds = 500_000_000
        let vm = HomeViewModel(metadataService: service)
        vm.urlString = youTubeURL
        let first = Task { await vm.fetchVideoInfo() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(vm.isLoading)
        let second = await vm.fetchVideoInfo()
        XCTAssertNil(second)
        _ = await first.value
        XCTAssertEqual(service.callCount, 1)
    }

    func testCancelStopsFetch() async {
        let service = FlippableService()
        service.shouldFail = false
        service.delayNanoseconds = 2_000_000_000
        let vm = HomeViewModel(metadataService: service)
        vm.urlString = youTubeURL
        let task = Task { await vm.fetchVideoInfo() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(vm.isLoading)
        vm.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.state, .idle)
    }

    func testLookalikeHostFailsWithActionableMessage() async {
        let vm = HomeViewModel(metadataService: MockMetadataProvider(delayNanoseconds: 0))
        vm.urlString = "https://youtube.com.evil.com/watch?v=dQw4w9WgXcQ"
        let video = await vm.fetchVideoInfo()
        XCTAssertNil(video)
        XCTAssertEqual(vm.state, .failed)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testYtDlpEngineFailureShowsEngineMessage() async {
        // With the yt-dlp engine unavailable, the failure must be honest
        // and engine-specific — never mock data presented as real.
        let engine = MockYtDlpEngine(stubInfo: .sampleInfo)
        engine.extractError = .runtimeUnavailable(reason: "no resources")
        let service = VideoMetadataService(providers: [YtDlpIntegrationProvider(engine: engine)])
        let vm = HomeViewModel(metadataService: service)
        vm.urlString = youTubeURL
        let video = await vm.fetchVideoInfo()
        XCTAssertNil(video)
        XCTAssertEqual(vm.state, .failed)
        XCTAssertTrue(vm.errorMessage?.contains("yt-dlp") ?? false)
    }

    func testForeignHostFailsWithPermissionMessage() async {
        let service = VideoMetadataService(providers: [AuthorizedSourceProvider()])
        let vm = HomeViewModel(metadataService: service)
        vm.urlString = "https://example.com/video"
        let video = await vm.fetchVideoInfo()
        XCTAssertNil(video)
        XCTAssertEqual(vm.state, .failed)
        XCTAssertTrue(vm.errorMessage?.contains("許可") ?? false)
    }

    func testNonHTTPSRejectedByViewModel() async {
        let vm = HomeViewModel(metadataService: MockMetadataProvider(delayNanoseconds: 0))
        vm.urlString = "http://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let video = await vm.fetchVideoInfo()
        XCTAssertNil(video)
        XCTAssertEqual(vm.state, .failed)
    }

    func testRecentFetchesDeduplicated() async {
        let service = FlippableService()
        service.shouldFail = false
        let vm = HomeViewModel(metadataService: service)
        vm.urlString = youTubeURL
        _ = await vm.fetchVideoInfo()
        _ = await vm.fetchVideoInfo()
        XCTAssertEqual(vm.recentFetches.count, 1)
    }

    func testPreviewViewModelExposesMetadata() {
        let metadata = VideoMetadata(
            id: "dQw4w9WgXcQ", title: "Real Title", creatorName: "Real Channel", sourceName: "YouTube",
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/x/hq.jpg"),
            durationSeconds: 3723, publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            description: "Desc",
            sourceURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        )
        let vm = VideoPreviewViewModel(metadata: metadata)
        XCTAssertEqual(vm.titleText, "Real Title")
        XCTAssertEqual(vm.channelText, "Real Channel")
        XCTAssertEqual(vm.durationText, "1:02:03")
        XCTAssertNotNil(vm.publishedDateText)
        XCTAssertEqual(vm.thumbnailURL?.absoluteString, "https://i.ytimg.com/vi/x/hq.jpg")
        // Phase 1 format/quality behaviour is untouched.
        XCTAssertTrue(vm.showsQualitySelection)
        vm.selectedFormat = .m4a
        XCTAssertFalse(vm.showsQualitySelection)
    }
}
