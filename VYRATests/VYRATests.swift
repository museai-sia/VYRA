import XCTest
@testable import VYRA

@MainActor
final class VYRATests: XCTestCase {


    private func makeWaitingItem() -> DownloadItem {
        DownloadItem(fileName: "test.mp4", format: .mp4, quality: .p720, fileSizeBytes: 1_000_000, state: .waiting)
    }

    // MARK: - URL validation (spec items 3, 4, 5)

    func testValidHTTPSURL() {
        XCTAssertTrue(URLValidator.isValidVideoURL("https://example.com/video/123"))
    }

    func testValidHTTPURL() {
        XCTAssertTrue(URLValidator.isValidVideoURL("http://example.co.jp/watch?v=1"))
    }

    func testInvalidURLPlainText() {
        XCTAssertFalse(URLValidator.isValidVideoURL("not a url"))
    }

    func testInvalidURLEmpty() {
        XCTAssertFalse(URLValidator.isValidVideoURL(""))
        XCTAssertFalse(URLValidator.isValidVideoURL("   "))
    }

    func testInvalidURLMissingHost() {
        XCTAssertFalse(URLValidator.isValidVideoURL("https://"))
        XCTAssertFalse(URLValidator.isValidVideoURL("example.com/video"))
    }

    func testHomeViewModelRejectsInvalidURL() async {
        let vm = HomeViewModel(metadataService: MockVideoMetadataService(delayNanoseconds: 0))
        vm.urlString = "invalid"
        let result = await vm.fetchVideoInfo()
        XCTAssertNil(result)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testHomeViewModelPasteAndClear() {
        let vm = HomeViewModel()
        vm.paste(from: "  https://example.com/abc  ")
        XCTAssertEqual(vm.urlString, "https://example.com/abc")
        vm.clear()
        XCTAssertEqual(vm.urlString, "")
        XCTAssertNil(vm.errorMessage)
    }

    func testHomeViewModelPasteEmptyClipboardShowsError() {
        let vm = HomeViewModel()
        vm.paste(from: nil)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Mock metadata (spec item 6)

    func testMockMetadataFetch() async throws {
        let service = MockVideoMetadataService(delayNanoseconds: 0)
        let url = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        let metadata = try await service.fetchMetadata(for: url)
        XCTAssertFalse(metadata.title.isEmpty)
        XCTAssertFalse(metadata.channelTitle.isEmpty)
        XCTAssertGreaterThan(metadata.durationSeconds, 0)
        XCTAssertEqual(metadata.sourceURL, url)
        XCTAssertEqual(metadata.id, "dQw4w9WgXcQ")
    }

    func testHomeViewModelFetchesMockVideo() async {
        let vm = HomeViewModel(metadataService: MockVideoMetadataService(delayNanoseconds: 0))
        vm.urlString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let video = await vm.fetchVideoInfo()
        XCTAssertNotNil(video)
        XCTAssertEqual(vm.fetchedVideo, video)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertEqual(vm.recentFetches.count, 1)
    }

    // MARK: - Format & quality (spec items 7, 8, 9)

    func testFormatChangeUpdatesSummaryAndFileName() {
        let vm = VideoPreviewViewModel(video: .mock)
        vm.selectedFormat = .mov
        XCTAssertTrue(vm.selectionSummary.hasPrefix("MOV"))
        XCTAssertTrue(vm.suggestedFileName.hasSuffix(".mov"))
    }

    func testQualityChangeUpdatesEstimate() {
        let vm = VideoPreviewViewModel(video: .mock)
        vm.selectedFormat = .mp4
        vm.selectedQuality = .p360
        let small = vm.estimatedMockBytes
        vm.selectedQuality = .p1080
        XCTAssertGreaterThan(vm.estimatedMockBytes, small)
    }

    func testM4AHidesQualitySelection() {
        let vm = VideoPreviewViewModel(video: .mock)
        XCTAssertTrue(vm.showsQualitySelection)
        vm.selectedFormat = .m4a
        XCTAssertFalse(vm.showsQualitySelection)
        XCTAssertTrue(vm.selectedFormat.isAudioOnly)
    }

    func testEstimatedSizeIsLabelledAsMock() {
        let vm = VideoPreviewViewModel(video: .mock)
        XCTAssertTrue(vm.estimatedSizeText.contains("モック"))
    }

    func testMakeDownloadItemCarriesSelection() {
        let vm = VideoPreviewViewModel(video: .mock)
        vm.selectedFormat = .mov
        vm.selectedQuality = .p1080
        let item = vm.makeDownloadItem()
        XCTAssertEqual(item.format, .mov)
        XCTAssertEqual(item.quality, .p1080)
        XCTAssertEqual(item.state, .waiting)
        XCTAssertTrue(item.fileName.hasSuffix(".mov"))
    }

    // MARK: - Download progress (spec items 11, 12, 13)

    func testDownloadProgressAdvancesOnTick() {
        let vm = DownloadViewModel(item: makeWaitingItem(), video: .mock)
        vm.state = .downloading
        vm.progressStep = 0.25
        vm.tick()
        XCTAssertEqual(vm.progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(vm.progressPercentText, "25%")
    }

    func testDownloadCompletesAtFullProgress() {
        let vm = DownloadViewModel(item: makeWaitingItem(), video: .mock)
        vm.state = .downloading
        vm.progressStep = 0.6
        vm.tick()
        vm.tick()
        XCTAssertEqual(vm.progress, 1.0, accuracy: 0.001)
        XCTAssertEqual(vm.state, .completed)
        XCTAssertTrue(vm.isFinished)
    }

    func testDownloadCancel() {
        let vm = DownloadViewModel(item: makeWaitingItem(), video: .mock)
        vm.start()
        XCTAssertEqual(vm.state, .downloading)
        vm.cancel()
        XCTAssertEqual(vm.state, .cancelled)
        XCTAssertFalse(vm.isRunning)
    }

    func testDownloadFailureState() {
        let vm = DownloadViewModel(item: makeWaitingItem(), video: .mock)
        vm.start()
        vm.simulateFailure()
        XCTAssertEqual(vm.state, .failed)
    }

    func testAllDownloadStatesHaveDisplayNames() {
        XCTAssertEqual(DownloadState.waiting.displayName, "Waiting")
        XCTAssertEqual(DownloadState.downloading.displayName, "Downloading")
        XCTAssertEqual(DownloadState.completed.displayName, "Completed")
        XCTAssertEqual(DownloadState.failed.displayName, "Failed")
        XCTAssertEqual(DownloadState.cancelled.displayName, "Cancelled")
    }

    // MARK: - Library (spec items 14, 15)

    func testLibraryAddAndDelete() {
        let vm = LibraryViewModel()
        XCTAssertTrue(vm.isEmpty)
        let item = vm.addMockItem()
        XCTAssertEqual(vm.count, 1)
        XCTAssertFalse(vm.isEmpty)
        vm.delete(item)
        XCTAssertTrue(vm.isEmpty)
    }

    func testLibraryAddSameItemTwiceDoesNotDuplicate() {
        let vm = LibraryViewModel()
        let item = makeWaitingItem()
        vm.add(item)
        vm.add(item)
        XCTAssertEqual(vm.count, 1)
    }

    func testLibraryDeleteAtOffsets() {
        let vm = LibraryViewModel()
        vm.addMockItem()
        vm.addMockItem()
        XCTAssertEqual(vm.count, 2)
        vm.delete(at: IndexSet(integer: 0))
        XCTAssertEqual(vm.count, 1)
    }

    // MARK: - Tabs & Settings (spec items 16, 17)

    func testAppTabs() {
        XCTAssertEqual(AppTab.allCases.count, 3)
        XCTAssertEqual(AppTab.allCases.map(\.title), ["Home", "Library", "Settings"])
    }

    func testSettingsViewModelAndCacheClear() {
        let vm = SettingsViewModel()
        XCTAssertEqual(vm.appName, "VYRA")
        XCTAssertTrue(vm.versionText.contains("1.0"))
        XCTAssertFalse(vm.cacheCleared)
        vm.clearCache()
        XCTAssertTrue(vm.cacheCleared)
        XCTAssertTrue(vm.cacheSizeText.hasPrefix("0 MB"))
    }

    // MARK: - Models

    func testVideoFormattedDuration() {
        let video = Video(title: "t", author: "a", durationSeconds: 754, sourceName: "s", sourceURLString: "https://example.com")
        XCTAssertEqual(video.formattedDuration, "12:34")
    }

    func testDownloadItemFormattedSizeAndStateRoundTrip() {
        let item = DownloadItem(fileName: "a.mp4", format: .m4a, quality: .original, fileSizeBytes: 1_000_000, state: .completed)
        XCTAssertEqual(item.format, .m4a)
        XCTAssertEqual(item.quality, .original)
        XCTAssertEqual(item.state, .completed)
        XCTAssertFalse(item.formattedFileSize.isEmpty)
    }
}
