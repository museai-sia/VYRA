import XCTest
import SwiftData
@testable import VYRA

/// Phase 3 tests (spec §19). Fully offline: stub engine, URLProtocol stub
/// and temporary directories only — no real external source is contacted.
@MainActor
final class Phase3DownloadTests: XCTestCase {

    private var tempRoot: URL!
    private var storage: FileStorageService!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-Phase3Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        storage = FileStorageService(
            documentsDirectory: tempRoot.appendingPathComponent("Documents", isDirectory: true),
            temporaryDirectory: tempRoot.appendingPathComponent("Temp", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: storage.documentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage.temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func makeItem(state: DownloadState = .waiting, fileName: String = "sample.mp4") -> DownloadItem {
        DownloadItem(fileName: fileName, format: .mp4, quality: .original,
                     fileSizeBytes: 0, state: state,
                     sourceURLString: "https://example.com/files/sample.mp4")
    }

    private func waitUntil(timeout: TimeInterval = 5, condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - DownloadTaskManager

    func testManagerStartProgressAndCompletion() async throws {
        let engine = StubDownloadEngine(behavior: .success(totalBytes: 4_096, chunkBytes: 1_024), chunkDelayNanoseconds: 0)
        var completedItem: DownloadItem?
        let manager = DownloadTaskManager(engine: engine, storage: storage, onCompleted: { completedItem = $0 })
        let item = makeItem()
        XCTAssertTrue(manager.startResolved(item: item, directURL: URL(string: "https://example.com/files/sample.mp4")!, fileName: "sample.mp4"))
        await waitUntil { item.state == .completed }
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(completedItem?.id, item.id)
        let relative = try XCTUnwrap(item.localFileRelativePath)
        XCTAssertTrue(storage.fileExists(relativePath: relative))
        XCTAssertEqual(storage.fileSize(relativePath: relative), 4_096)
        XCTAssertEqual(item.fileSizeBytes, 4_096)
        XCTAssertEqual(manager.progress(for: item.id)?.fraction, 1.0)
    }

    func testManagerFailure() async {
        let engine = StubDownloadEngine(behavior: .failure(.httpStatus(404)))
        let manager = DownloadTaskManager(engine: engine, storage: storage)
        let item = makeItem()
        XCTAssertTrue(manager.startResolved(item: item, directURL: URL(string: "https://example.com/files/sample.mp4")!, fileName: "sample.mp4"))
        await waitUntil { item.state == .failed }
        XCTAssertEqual(item.state, .failed)
        XCTAssertNotNil(item.errorMessage)
        XCTAssertNil(item.localFileRelativePath)
        XCTAssertEqual(manager.errors[item.id], .httpStatus(404))
    }

    func testManagerCancelLeavesNoLibraryFile() async {
        let engine = StubDownloadEngine(behavior: .hangAfterFirstChunk(totalBytes: 100_000), chunkDelayNanoseconds: 0)
        var completedCalled = false
        let manager = DownloadTaskManager(engine: engine, storage: storage, onCompleted: { _ in completedCalled = true })
        let item = makeItem()
        XCTAssertTrue(manager.startResolved(item: item, directURL: URL(string: "https://example.com/files/sample.mp4")!, fileName: "sample.mp4"))
        await waitUntil { item.state == .downloading }
        manager.cancel(item: item)
        await waitUntil { item.state == .cancelled }
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertFalse(completedCalled)
        XCTAssertNil(item.localFileRelativePath)
    }

    func testManagerRetryAfterFailure() async {
        let engine = StubDownloadEngine(behavior: .failure(.network(description: "boom")))
        let manager = DownloadTaskManager(engine: engine, storage: storage)
        let item = makeItem()
        XCTAssertTrue(manager.startResolved(item: item, directURL: URL(string: "https://example.com/files/sample.mp4")!, fileName: "sample.mp4"))
        await waitUntil { item.state == .failed }
        engine.behavior = .success(totalBytes: 2_048, chunkBytes: 1_024)
        XCTAssertTrue(manager.retry(item: item))
        await waitUntil { item.state == .completed }
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.fileSizeBytes, 2_048)
    }

    func testManagerMultipleConcurrentTasks() async {
        let engine = StubDownloadEngine(behavior: .success(totalBytes: 1_024, chunkBytes: 512), chunkDelayNanoseconds: 0)
        let manager = DownloadTaskManager(engine: engine, storage: storage)
        let first = makeItem(fileName: "a.mp4")
        let second = makeItem(fileName: "b.mp4")
        XCTAssertTrue(manager.startResolved(item: first, directURL: URL(string: "https://example.com/a.mp4")!, fileName: "a.mp4"))
        XCTAssertTrue(manager.startResolved(item: second, directURL: URL(string: "https://example.com/b.mp4")!, fileName: "b.mp4"))
        await waitUntil { first.state == .completed && second.state == .completed }
        XCTAssertEqual(first.state, .completed)
        XCTAssertEqual(second.state, .completed)
        XCTAssertNotEqual(first.localFileRelativePath, second.localFileRelativePath)
    }

    func testManagerRefusesNonDirectSource() {
        let manager = DownloadTaskManager(engine: StubDownloadEngine(), storage: storage)
        let item = DownloadItem(fileName: "v.mp4", format: .mp4, quality: .p720, fileSizeBytes: 0,
                                state: .waiting, sourceURLString: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertFalse(manager.start(item: item, sourceURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, fileName: "v.mp4"))
        XCTAssertEqual(item.state, .failed)
        XCTAssertNotNil(item.errorMessage)
    }

    func testManagerStartOnCompletedItemRejected() async {
        let manager = DownloadTaskManager(engine: StubDownloadEngine(), storage: storage)
        let item = makeItem(state: .completed)
        XCTAssertFalse(manager.startResolved(item: item, directURL: URL(string: "https://example.com/files/sample.mp4")!, fileName: "sample.mp4"))
        XCTAssertEqual(item.state, .completed)
    }

    // MARK: - DownloadState transitions

    func testValidTransitions() {
        XCTAssertTrue(DownloadState.waiting.canTransition(to: .queued))
        XCTAssertTrue(DownloadState.queued.canTransition(to: .preparing))
        XCTAssertTrue(DownloadState.preparing.canTransition(to: .downloading))
        XCTAssertTrue(DownloadState.downloading.canTransition(to: .completed))
        XCTAssertTrue(DownloadState.downloading.canTransition(to: .failed))
        XCTAssertTrue(DownloadState.downloading.canTransition(to: .cancelled))
        XCTAssertTrue(DownloadState.failed.canTransition(to: .queued))
        XCTAssertTrue(DownloadState.cancelled.canTransition(to: .queued))
    }

    func testIllegalTransitionsRejected() {
        XCTAssertFalse(DownloadState.completed.canTransition(to: .downloading))
        XCTAssertFalse(DownloadState.completed.canTransition(to: .queued))
        XCTAssertFalse(DownloadState.completed.canTransition(to: .failed))
        XCTAssertFalse(DownloadState.queued.canTransition(to: .completed))
        XCTAssertFalse(DownloadState.waiting.canTransition(to: .completed))
        XCTAssertFalse(DownloadState.downloading.canTransition(to: .queued))
        let item = makeItem(state: .completed)
        XCTAssertFalse(item.transition(to: .downloading))
        XCTAssertEqual(item.state, .completed)
    }

    func testNoPausedStateOffered() {
        XCTAssertNil(DownloadState(rawValue: "paused"))
    }

    // MARK: - FileStorageService

    func testStorageMoveExistsSizeDelete() throws {
        let temp = try storage.writeTemporaryFile(data: Data(count: 1_234), fileName: "clip.mp4")
        let moved = try storage.moveIntoLibrary(tempFileURL: temp, desiredFileName: "clip.mp4")
        XCTAssertEqual(moved.url.lastPathComponent, "clip.mp4")
        XCTAssertTrue(storage.fileExists(relativePath: moved.relativePath))
        XCTAssertEqual(storage.fileSize(relativePath: moved.relativePath), 1_234)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        try storage.deleteFile(relativePath: moved.relativePath)
        XCTAssertFalse(storage.fileExists(relativePath: moved.relativePath))
    }

    func testStorageDuplicateNamesResolved() throws {
        let first = try storage.moveIntoLibrary(
            tempFileURL: storage.writeTemporaryFile(data: Data(count: 10), fileName: "clip.mp4"),
            desiredFileName: "clip.mp4")
        let second = try storage.moveIntoLibrary(
            tempFileURL: storage.writeTemporaryFile(data: Data(count: 10), fileName: "clip.mp4"),
            desiredFileName: "clip.mp4")
        let third = try storage.moveIntoLibrary(
            tempFileURL: storage.writeTemporaryFile(data: Data(count: 10), fileName: "clip.mp4"),
            desiredFileName: "clip.mp4")
        XCTAssertEqual(first.url.lastPathComponent, "clip.mp4")
        XCTAssertEqual(second.url.lastPathComponent, "clip 1.mp4")
        XCTAssertEqual(third.url.lastPathComponent, "clip 2.mp4")
    }

    // MARK: - FileNameValidator

    func testFileNameSanitization() {
        XCTAssertEqual(FileNameValidator.sanitizedBaseName("  my/video: name? "), "myvideo name")
        XCTAssertEqual(FileNameValidator.sanitizedBaseName("...hidden"), "hidden")
        XCTAssertEqual(FileNameValidator.sanitizedBaseName("   "), "")
    }

    func testFileNameValidationProtectsExtension() throws {
        XCTAssertEqual(try FileNameValidator.validatedFileName(baseName: "My Video", format: .mp4), "My Video.mp4")
        XCTAssertEqual(try FileNameValidator.validate(fileName: "song.m4a", format: .m4a), "song.m4a")
        XCTAssertThrowsError(try FileNameValidator.validate(fileName: "song.mp3", format: .m4a))
        XCTAssertThrowsError(try FileNameValidator.validatedFileName(baseName: "///", format: .mp4)) {
            XCTAssertEqual($0 as? FileNameError, .empty)
        }
    }

    func testNextAvailableName() {
        let existing: Set<String> = ["a.mp4", "a 1.mp4"]
        XCTAssertEqual(FileNameValidator.nextAvailableName(for: "a.mp4", exists: { existing.contains($0) }), "a 2.mp4")
        XCTAssertEqual(FileNameValidator.nextAvailableName(for: "b.mp4", exists: { existing.contains($0) }), "b.mp4")
    }

    // MARK: - MediaFormatService / Resolver

    func testDirectURLProducesOnlyItsOwnFormat() {
        let options = MediaFormatService.optionsForDirectURL(URL(string: "https://example.com/a/movie.mov")!)
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.format, .mov)
        XCTAssertEqual(options.first?.quality, .original)
        XCTAssertEqual(MediaFormatService.formats(from: options), [.mov])
    }

    func testAudioDirectURLHidesQualityChoice() {
        let metadata = VideoMetadata(
            id: "song.m4a", title: "song", creatorName: "example.com", sourceName: "Direct HTTPS",
            thumbnailURL: nil, durationSeconds: 0, publishedAt: nil, description: nil,
            sourceURL: URL(string: "https://example.com/song.m4a")!,
            availableFormats: [AvailableMediaFormat(container: "m4a", qualityLabel: "Original", isAudioOnly: true)])
        let vm = VideoPreviewViewModel(metadata: metadata)
        vm.reconcileSelection()
        XCTAssertEqual(vm.selectedFormat, .m4a)
        XCTAssertFalse(vm.showsQualitySelection)
        XCTAssertTrue(vm.isDownloadable)
    }

    func testResolverRejectsYouTubeWatchPage() {
        let resolution = DirectMediaResolver.resolve(
            sourceURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, format: .mp4)
        if case .unavailable = resolution {} else { XCTFail("watch page must not be downloadable") }
    }

    func testResolverRejectsFormatMismatch() {
        let resolution = DirectMediaResolver.resolve(
            sourceURL: URL(string: "https://example.com/movie.mp4")!, format: .m4a)
        if case .unavailable = resolution {} else { XCTFail("format mismatch must be refused") }
    }

    func testProgressFractionNilWhenTotalUnknown() {
        let progress = DownloadProgress(downloadedBytes: 100, totalBytes: nil, state: .downloading)
        XCTAssertNil(progress.fraction)
        XCTAssertNil(progress.percentText)
    }

    // MARK: - LibraryViewModel + SwiftData persistence

    private func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: DownloadItem.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testLibraryRestorePlayableShareAndDelete() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        // Simulate a completed download on disk + persisted record.
        let moved = try storage.moveIntoLibrary(
            tempFileURL: storage.writeTemporaryFile(data: Data(count: 2_048), fileName: "saved.mp4"),
            desiredFileName: "saved.mp4")
        let item = DownloadItem(fileName: "saved.mp4", format: .mp4, quality: .original,
                                fileSizeBytes: 2_048, createdAt: Date(), state: .completed,
                                sourceURLString: "https://example.com/saved.mp4",
                                localFileRelativePath: moved.relativePath,
                                mimeType: "video/mp4", durationSeconds: 65)
        context.insert(item)
        try context.save()

        let vm = LibraryViewModel(storage: storage)
        vm.attach(modelContext: ModelContext(container))
        XCTAssertEqual(vm.count, 1)
        XCTAssertFalse(vm.isEmpty)
        XCTAssertEqual(vm.items.first?.fileName, "saved.mp4")
        let restored = try XCTUnwrap(vm.items.first)
        XCTAssertNotNil(vm.playableURL(for: restored))
        XCTAssertTrue(vm.isPlayable(restored))
        XCTAssertEqual(vm.shareURL(for: restored)?.lastPathComponent, "saved.mp4")

        vm.delete(restored)
        XCTAssertTrue(vm.isEmpty)
        XCTAssertFalse(storage.fileExists(relativePath: moved.relativePath))
        let verify = LibraryViewModel(storage: storage)
        verify.attach(modelContext: ModelContext(container))
        XCTAssertTrue(verify.isEmpty)
    }

    func testLibraryRestoreRemovesOrphanRecords() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let orphan = DownloadItem(fileName: "gone.mp4", format: .mp4, quality: .original,
                                  fileSizeBytes: 10, state: .completed,
                                  sourceURLString: "https://example.com/gone.mp4",
                                  localFileRelativePath: "VYRA/gone.mp4")
        context.insert(orphan)
        try context.save()
        let vm = LibraryViewModel(storage: storage)
        vm.attach(modelContext: ModelContext(container))
        XCTAssertTrue(vm.isEmpty)
    }

    func testLibraryEmptyStateAndMockAddStillWork() {
        let vm = LibraryViewModel(storage: storage)
        XCTAssertTrue(vm.isEmpty)
        let item = vm.addMockItem()
        XCTAssertEqual(vm.count, 1)
        XCTAssertNil(vm.playableURL(for: item))
        XCTAssertNil(vm.shareURL(for: item))
        vm.delete(item)
        XCTAssertTrue(vm.isEmpty)
    }

    func testLibraryNewestFirst() {
        let vm = LibraryViewModel(storage: storage)
        let older = DownloadItem(fileName: "old.mp4", format: .mp4, quality: .original,
                                 fileSizeBytes: 1, createdAt: Date(timeIntervalSince1970: 1_000), state: .completed)
        let newer = DownloadItem(fileName: "new.mp4", format: .mp4, quality: .original,
                                 fileSizeBytes: 1, createdAt: Date(timeIntervalSince1970: 2_000), state: .completed)
        vm.add(older)
        vm.add(newer)
        XCTAssertEqual(vm.items.map(\.fileName), ["new.mp4", "old.mp4"])
    }

    // MARK: - URLSession engine via URLProtocol stub

    func testURLSessionEngineDownloadsStubbedResponse() async throws {
        StubURLProtocol.payload = Data(count: 3_000)
        StubURLProtocol.statusCode = 200
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let engine = URLSessionDownloadEngine(configuration: config)
        let url = try await engine.download(
            request: DownloadRequest(taskID: UUID(), sourceURL: URL(string: "https://example.com/files/stub.mp4")!, fileName: "stub.mp4"),
            progress: { _ in })
        XCTAssertEqual(FileManager.default.fileSize(atPath: url.path), 3_000)
        try? FileManager.default.removeItem(at: url)
    }

    func testURLSessionEngineMapsHTTPError() async {
        StubURLProtocol.payload = Data(count: 10)
        StubURLProtocol.statusCode = 404
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let engine = URLSessionDownloadEngine(configuration: config)
        do {
            _ = try await engine.download(
                request: DownloadRequest(taskID: UUID(), sourceURL: URL(string: "https://example.com/files/missing.mp4")!, fileName: "missing.mp4"),
                progress: { _ in })
            XCTFail("404 must throw")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .httpStatus(404))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

/// URLProtocol stub serving fixed payloads — no network involved.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode,
                                       httpVersion: nil,
                                       headerFields: ["Content-Length": "\(Self.payload.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Deliver in two chunks so progress callbacks fire.
        let half = Self.payload.count / 2
        client?.urlProtocol(self, didLoad: Self.payload.prefix(half))
        client?.urlProtocol(self, didLoad: Self.payload.suffix(Self.payload.count - half))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension FileManager {
    func fileSize(atPath path: String) -> Int64 {
        (try? attributesOfItem(atPath: path))?[.size] as? Int64 ?? -1
    }
}
