import XCTest
import SwiftData
@testable import VYRA

/// Save-destination tests (Settings > 保存先): the destination store
/// (bookmark persist / resolve / fallback), storage moves into an
/// external directory, and an end-to-end download that lands in a
/// chosen folder and stays playable/deletable through the Library.
@MainActor
final class SaveDestinationTests: XCTestCase {

    private var tempRoot: URL!
    private var externalFolder: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: SaveDestinationStore!
    private var storage: FileStorageService!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-DestinationTests-\(UUID().uuidString)", isDirectory: true)
        externalFolder = tempRoot.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: externalFolder, withIntermediateDirectories: true)
        suiteName = "VYRA-DestinationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SaveDestinationStore(defaults: defaults)
        storage = FileStorageService(
            documentsDirectory: tempRoot.appendingPathComponent("Documents", isDirectory: true),
            temporaryDirectory: tempRoot.appendingPathComponent("Temp", isDirectory: true))
        try FileManager.default.createDirectory(at: storage.documentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage.temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    // MARK: - Store

    func testDefaultDestinationIsAppFolder() {
        XCTAssertEqual(store.currentDestination(), .appFolder)
        XCTAssertFalse(store.hasExternalFolder)
        XCTAssertNil(store.beginFolderAccess())
        XCTAssertTrue(store.displayText.contains("アプリ内フォルダ"))
    }

    func testSetExternalFolderResolvesAndResets() throws {
        try store.setExternalFolder(externalFolder)
        XCTAssertTrue(store.hasExternalFolder)
        XCTAssertEqual(store.currentDestination(), .external(folderName: "Chosen"))
        let access = try XCTUnwrap(store.beginFolderAccess())
        XCTAssertEqual(access.url.standardizedFileURL, externalFolder.standardizedFileURL)
        access.end()
        store.resetToAppFolder()
        XCTAssertEqual(store.currentDestination(), .appFolder)
        XCTAssertFalse(store.hasExternalFolder)
    }

    func testCorruptBookmarkFallsBackHonestly() {
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: SaveDestinationStore.bookmarkDefaultsKey)
        defaults.set("消えたフォルダ", forKey: SaveDestinationStore.nameDefaultsKey)
        XCTAssertEqual(store.currentDestination(), .externalUnavailable(folderName: "消えたフォルダ"))
        XCTAssertNil(store.beginFolderAccess(), "unusable bookmark must not grant access")
        XCTAssertTrue(store.displayText.contains("アクセスできません"))
    }

    func testBookmarkOfDeletedFolderIsUnavailable() throws {
        let doomed = tempRoot.appendingPathComponent("Doomed", isDirectory: true)
        try FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: true)
        try store.setExternalFolder(doomed)
        XCTAssertEqual(store.currentDestination(), .external(folderName: "Doomed"))
        try FileManager.default.removeItem(at: doomed)
        XCTAssertEqual(store.currentDestination(), .externalUnavailable(folderName: "Doomed"))
        XCTAssertNil(store.beginFolderAccess())
    }

    // MARK: - Storage

    func testMoveIntoDirectoryResolvesDuplicates() throws {
        let first = try storage.moveIntoDirectory(
            tempFileURL: storage.writeTemporaryFile(data: Data(count: 10), fileName: "clip.mp4"),
            desiredFileName: "clip.mp4", directory: externalFolder)
        let second = try storage.moveIntoDirectory(
            tempFileURL: storage.writeTemporaryFile(data: Data(count: 10), fileName: "clip.mp4"),
            desiredFileName: "clip.mp4", directory: externalFolder)
        XCTAssertEqual(first.lastPathComponent, "clip.mp4")
        XCTAssertEqual(second.lastPathComponent, "clip 1.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    // MARK: - End to end: download lands in the chosen folder

    func testDownloadSavesToExternalFolderAndLibraryResolvesIt() async throws {
        try store.setExternalFolder(externalFolder)
        let engine = StubDownloadEngine(behavior: .success(totalBytes: 2_048, chunkBytes: 1_024), chunkDelayNanoseconds: 0)
        var completedItem: DownloadItem?
        let manager = DownloadTaskManager(
            engine: engine, storage: storage, destinationStore: store,
            onCompleted: { completedItem = $0 })
        let item = DownloadItem(
            fileName: "ext.mp4", format: .mp4, quality: .original, fileSizeBytes: 0,
            state: .waiting, sourceURLString: "https://example.com/files/ext.mp4")

        XCTAssertTrue(manager.startResolved(item: item, directURL: URL(string: "https://example.com/files/ext.mp4")!, fileName: "ext.mp4"))
        let deadline = Date().addingTimeInterval(5)
        while item.state != .completed && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(completedItem?.id, item.id)
        XCTAssertNil(item.localFileRelativePath)
        XCTAssertNotNil(item.externalBookmarkData)

        let library = LibraryViewModel(storage: storage)
        let resolved = try XCTUnwrap(library.resolvedFileURL(for: item))
        XCTAssertEqual(resolved.deletingLastPathComponent().standardizedFileURL,
                       externalFolder.standardizedFileURL)
        XCTAssertNotNil(library.playableURL(for: item))
        XCTAssertNotNil(library.shareURL(for: item))

        library.delete(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.path))
    }

    func testDownloadFallsBackToAppFolderWhenBookmarkIsDead() async throws {
        defaults.set(Data([0xFF, 0xFE]), forKey: SaveDestinationStore.bookmarkDefaultsKey)
        defaults.set("Gone", forKey: SaveDestinationStore.nameDefaultsKey)
        let engine = StubDownloadEngine(behavior: .success(totalBytes: 1_024, chunkBytes: 512), chunkDelayNanoseconds: 0)
        let manager = DownloadTaskManager(engine: engine, storage: storage, destinationStore: store)
        let item = DownloadItem(
            fileName: "fallback.mp4", format: .mp4, quality: .original, fileSizeBytes: 0,
            state: .waiting, sourceURLString: "https://example.com/files/fallback.mp4")

        XCTAssertTrue(manager.startResolved(item: item, directURL: URL(string: "https://example.com/files/fallback.mp4")!, fileName: "fallback.mp4"))
        let deadline = Date().addingTimeInterval(5)
        while item.state != .completed && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(item.state, .completed)
        let relative = try XCTUnwrap(item.localFileRelativePath)
        XCTAssertTrue(storage.fileExists(relativePath: relative))
        XCTAssertNil(item.externalBookmarkData)
    }
}
