import XCTest
import AVFoundation
import Darwin
@testable import VYRA

/// Phase 4 tests for the embedded yt-dlp engine wiring. Fully offline:
/// the engine is mocked (`MockYtDlpEngine`); the real CPython runtime is
/// exercised only by `EmbeddedPythonRuntimeTests`, which skips when the
/// Python resources are not bundled.
@MainActor
final class YtDlpEngineTests: XCTestCase {

    private let watchURL = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!

    // MARK: - Metadata mapping

    func testMapperKeepsRealFormatsWithIDsAndSizes() {
        let metadata = YtDlpMetadataMapper.metadata(from: .sampleInfo, sourceURL: watchURL)
        XCTAssertEqual(metadata.title, "Sample Video")
        XCTAssertEqual(metadata.creatorName, "Sample Channel")
        XCTAssertEqual(metadata.durationSeconds, 212)
        XCTAssertNotNil(metadata.publishedAt)
        let formats = metadata.availableFormats ?? []
        XCTAssertEqual(formats.count, 3)
        let combined = formats.first { $0.formatID == "18" }
        XCTAssertEqual(combined?.container, "mp4")
        XCTAssertEqual(combined?.qualityLabel, "360p")
        XCTAssertEqual(combined?.estimatedFileSize, 10_000_000)
        XCTAssertEqual(combined?.requiresMerge, false)
        let videoOnly = formats.first { $0.formatID == "137" }
        XCTAssertEqual(videoOnly?.requiresMerge, true)
        let audio = formats.first { $0.formatID == "140" }
        XCTAssertEqual(audio?.isAudioOnly, true)
        XCTAssertNil(audio?.qualityLabel)
    }

    func testMapperCarriesWebMFormats() {
        // Containers are not narrowed at mapping time (owner order,
        // 2026-11-25): WebM/VP9 formats are carried through and the
        // selection step offers them with a transcode processing.
        // Only containers outside mp4/m4a/webm (e.g. mhtml
        // storyboards) are dropped.
        var info = MockYtDlpEngine.sampleInfo
        info.formats.append(YtDlpFormatInfo(
            formatID: "248", ext: "webm", vcodec: "vp9", acodec: "none",
            height: 1080, fps: 30, filesize: nil, filesizeApprox: nil,
            formatNote: "1080p", singleFile: false, requiresMerge: true))
        info.formats.append(YtDlpFormatInfo(
            formatID: "sb0", ext: "mhtml", vcodec: "none", acodec: "none",
            height: 180, fps: nil, filesize: nil, filesizeApprox: nil,
            formatNote: "storyboard", singleFile: false, requiresMerge: false))
        let metadata = YtDlpMetadataMapper.metadata(from: info, sourceURL: watchURL)
        XCTAssertTrue((metadata.availableFormats ?? []).contains { $0.container == "webm" })
        XCTAssertFalse((metadata.availableFormats ?? []).contains { $0.formatID == "sb0" })
    }

    // MARK: - Format options: split pairs are offered with their audio half

    func testOptionsOfferSplitPairForVideoOnlyAVC1() {
        // sampleInfo: 18 = combined 360p, 137 = video-only 1080p avc1,
        // 140 = m4a audio. The 1080p must now be offered as a split
        // pair (137 + 140) instead of being dropped.
        let metadata = YtDlpMetadataMapper.metadata(from: .sampleInfo, sourceURL: watchURL)
        let options = MediaFormatService.options(from: metadata)
        XCTAssertEqual(Set(options.compactMap(\.ytDlpFormatID)), ["18", "137", "140"])
        let split = options.first { $0.ytDlpFormatID == "137" }
        XCTAssertEqual(split?.audioYtDlpFormatID, "140")
        XCTAssertEqual(split?.isSplitPair, true)
        XCTAssertEqual(split?.qualityLabel, "1080p")
        // Estimated size of a pair is the sum of both streams.
        XCTAssertEqual(split?.estimatedFileSize, 43_000_000)
        XCTAssertTrue(MediaFormatService.qualities(for: .mp4, in: options).contains(.p1080))
    }

    // MARK: - Resolver

    func testResolverSelectsYtDlpRoute() {
        let metadata = YtDlpMetadataMapper.metadata(from: .sampleInfo, sourceURL: watchURL)
        let resolution = DirectMediaResolver.resolve(
            sourceURL: watchURL, format: .mp4, quality: .p360, metadata: metadata)
        guard case .ytDlp(let formatID, _, _) = resolution else {
            return XCTFail("expected .ytDlp, got \(resolution)")
        }
        XCTAssertEqual(formatID, "18")
    }

    func testResolverSelectsYtDlpAudioRoute() {
        let metadata = YtDlpMetadataMapper.metadata(from: .sampleInfo, sourceURL: watchURL)
        let resolution = DirectMediaResolver.resolve(
            sourceURL: watchURL, format: .m4a, metadata: metadata)
        guard case .ytDlp(let formatID, _, _) = resolution else {
            return XCTFail("expected .ytDlp, got \(resolution)")
        }
        XCTAssertEqual(formatID, "140")
    }

    // MARK: - Download via yt-dlp engine through the task manager

    func testManagerDownloadsViaYtDlpEngine() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-YtDlpTests-\(UUID().uuidString)", isDirectory: true)
        let storage = FileStorageService(
            documentsDirectory: tempRoot.appendingPathComponent("Documents", isDirectory: true),
            temporaryDirectory: tempRoot.appendingPathComponent("Temp", isDirectory: true))
        try FileManager.default.createDirectory(at: storage.documentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage.temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockYtDlpEngine(stubInfo: .sampleInfo)
        var completedItem: DownloadItem?
        let manager = DownloadTaskManager(
            engine: StubDownloadEngine(),
            ytDlpEngine: YtDlpDownloadEngine(engine: mock),
            storage: storage,
            onCompleted: { completedItem = $0 })
        let item = DownloadItem(
            fileName: "sample.mp4", format: .mp4, quality: .p360,
            fileSizeBytes: 0, state: .waiting,
            sourceURLString: watchURL.absoluteString)
        item.ytDlpFormatID = "18"

        XCTAssertTrue(manager.start(item: item, sourceURL: watchURL, fileName: "sample.mp4"))
        let deadline = Date().addingTimeInterval(5)
        while item.state != .completed && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(completedItem?.id, item.id)
        let relative = try XCTUnwrap(item.localFileRelativePath)
        XCTAssertTrue(storage.fileExists(relativePath: relative))
    }

    func testManagerWithoutYtDlpEngineRefusesYtDlpItem() async {
        let manager = DownloadTaskManager(engine: StubDownloadEngine(), storage: .appDefault)
        let item = DownloadItem(
            fileName: "sample.mp4", format: .mp4, quality: .p360,
            fileSizeBytes: 0, state: .waiting,
            sourceURLString: watchURL.absoluteString)
        item.ytDlpFormatID = "18"
        XCTAssertFalse(manager.start(item: item, sourceURL: watchURL, fileName: "sample.mp4"))
        XCTAssertEqual(item.state, .failed)
    }

    // MARK: - Settings diagnostics

    func testSettingsDiagnosticsShowRealEngineValues() async {
        let vm = SettingsViewModel(engine: MockYtDlpEngine(stubInfo: .sampleInfo))
        await vm.loadEngineInfo()
        XCTAssertEqual(vm.pythonVersionText, "3.14.0")
        XCTAssertEqual(vm.ytDlpVersionText, "2026.11.23")
        XCTAssertEqual(vm.jscProviderText, "有効")
        await vm.runExtractionTest()
        let result = vm.extractionTestResultText ?? "nil"
        XCTAssertTrue(result.contains("Sample Video"), "got: \(result)")
        XCTAssertTrue(result.contains("形式 3 件"), "got: \(result)")
    }

    func testSettingsDiagnosticsSurfaceRawError() async {
        let engine = MockYtDlpEngine(stubInfo: .sampleInfo)
        engine.extractError = .pythonError(message: "Sign in to confirm you're not a bot")
        let vm = SettingsViewModel(engine: engine)
        await vm.runExtractionTest()
        XCTAssertTrue(vm.extractionTestResultText?.contains("not a bot") ?? false)
    }

    // MARK: - Mock engine contract

    func testMockEngineVersionsAndCancel() async throws {
        let mock = MockYtDlpEngine(stubInfo: .sampleInfo)
        let versions = try await mock.versions()
        XCTAssertEqual(versions.ytDlp, "2026.11.23")
        XCTAssertTrue(versions.jscProvider)
        let jobID = UUID()
        await mock.cancel(jobID: jobID)
        XCTAssertEqual(mock.cancelledJobIDs, [jobID])
    }

    // MARK: - Format selection: "Original" means best single-file

    private func infoWithFormats(_ formats: [YtDlpFormatInfo]) -> YtDlpExtractedInfo {
        var info = MockYtDlpEngine.sampleInfo
        info.formats = formats
        return info
    }

    /// Regression test for the on-device failure (2026-11-25): an
    /// ultralow audio-only .mp4 (itag 599, ~2.2 MB) was offered and
    /// picked as "MP4 / Original", so the "video" download was a tiny
    /// audio file whose client requires a PO token.
    func testOriginalNeverSelectsUltralowAudioOnlyMP4() {
        let info = infoWithFormats([
            YtDlpFormatInfo(formatID: "599", ext: "mp4", vcodec: "none", acodec: "mp4a.40.2",
                            height: nil, fps: nil, filesize: 2_200_000, filesizeApprox: nil,
                            formatNote: "ultralow", singleFile: true, requiresMerge: false,
                            tbr: 66, protocolName: "https"),
            YtDlpFormatInfo(formatID: "18", ext: "mp4", vcodec: "avc1.42001E", acodec: "mp4a.40.2",
                            height: 360, fps: 30, filesize: 12_000_000, filesizeApprox: nil,
                            formatNote: "360p", singleFile: true, requiresMerge: false,
                            tbr: 500, protocolName: "https"),
            YtDlpFormatInfo(formatID: "140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2",
                            height: nil, fps: nil, filesize: 4_000_000, filesizeApprox: nil,
                            formatNote: "medium", singleFile: true, requiresMerge: false,
                            tbr: 128, protocolName: "https"),
        ])
        let metadata = YtDlpMetadataMapper.metadata(from: info, sourceURL: watchURL)
        let options = MediaFormatService.options(from: metadata)
        XCTAssertFalse(options.contains { $0.ytDlpFormatID == "599" },
                       "audio-only mp4 must not be offered as an MP4 video option")
        let selected = MediaFormatService.selectOption(in: options, format: .mp4, quality: .original)
        XCTAssertEqual(selected?.ytDlpFormatID, "18")
        XCTAssertEqual(selected?.estimatedFileSize, 12_000_000)
        let resolution = DirectMediaResolver.resolve(
            sourceURL: watchURL, format: .mp4, quality: .original, metadata: metadata)
        guard case .ytDlp(let formatID, _, _) = resolution else {
            return XCTFail("expected .ytDlp, got \(resolution)")
        }
        XCTAssertEqual(formatID, "18")
    }

    func testOriginalPrefersHighestProgressiveFormat() {
        let info = infoWithFormats([
            YtDlpFormatInfo(formatID: "18", ext: "mp4", vcodec: "avc1.42001E", acodec: "mp4a.40.2",
                            height: 360, fps: 30, filesize: 12_000_000, filesizeApprox: nil,
                            formatNote: "360p", singleFile: true, requiresMerge: false,
                            protocolName: "https"),
            YtDlpFormatInfo(formatID: "22x", ext: "mp4", vcodec: "avc1.64001F", acodec: "mp4a.40.2",
                            height: 720, fps: 30, filesize: 30_000_000, filesizeApprox: nil,
                            formatNote: "720p", singleFile: true, requiresMerge: false,
                            protocolName: "https"),
        ])
        let metadata = YtDlpMetadataMapper.metadata(from: info, sourceURL: watchURL)
        let options = MediaFormatService.options(from: metadata)
        XCTAssertEqual(
            MediaFormatService.selectOption(in: options, format: .mp4, quality: .original)?.ytDlpFormatID,
            "22x")
        XCTAssertEqual(
            MediaFormatService.selectOption(in: options, format: .mp4, quality: .p360)?.ytDlpFormatID,
            "18")
    }

    func testHLSCombinedFormatsAreOfferedAsRemuxSingle() {
        // HLS combined formats ARE offered (HLS support phase):
        // the 720p HLS rendition becomes a .remuxSingle option
        // alongside the plain 360p .direct one. (This replaces the
        // pre-HLS-support assertion that HLS was excluded.)
        let info = infoWithFormats([
            YtDlpFormatInfo(formatID: "hls-720", ext: "mp4", vcodec: "avc1.64001F", acodec: "mp4a.40.2",
                            height: 720, fps: 30, filesize: 30_000_000, filesizeApprox: nil,
                            formatNote: "720p", singleFile: true, requiresMerge: false,
                            protocolName: "m3u8_native"),
            YtDlpFormatInfo(formatID: "18", ext: "mp4", vcodec: "avc1.42001E", acodec: "mp4a.40.2",
                            height: 360, fps: 30, filesize: 12_000_000, filesizeApprox: nil,
                            formatNote: "360p", singleFile: true, requiresMerge: false,
                            protocolName: "https"),
        ])
        let metadata = YtDlpMetadataMapper.metadata(from: info, sourceURL: watchURL)
        let options = MediaFormatService.options(from: metadata)
        XCTAssertEqual(Set(options.compactMap(\.ytDlpFormatID)), ["18", "hls-720"])
        let hlsOption = options.first { $0.ytDlpFormatID == "hls-720" }
        XCTAssertEqual(hlsOption?.processing, .remuxSingle)
        XCTAssertNil(hlsOption?.audioYtDlpFormatID)
    }

    // MARK: - Error surfacing: the Python exception must reach the UI

    func testDownloadErrorDetailUsesLastMeaningfulLine() {
        let error = DownloadError.engineFailed(
            description: "some warning\n\nERROR: HTTP Error 403: Forbidden\n")
        XCTAssertEqual(error.detailMessage, "ERROR: HTTP Error 403: Forbidden")
        XCTAssertNil(DownloadError.invalidURL.detailMessage)
        XCTAssertTrue(error.userMessage.contains("yt-dlpでダウンロードできませんでした"))
    }

    func testManagerSurfacesPythonErrorDetailOnItem() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-YtDlpErrTests-\(UUID().uuidString)", isDirectory: true)
        let storage = FileStorageService(
            documentsDirectory: tempRoot.appendingPathComponent("Documents", isDirectory: true),
            temporaryDirectory: tempRoot.appendingPathComponent("Temp", isDirectory: true))
        try FileManager.default.createDirectory(at: storage.documentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage.temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockYtDlpEngine(stubInfo: .sampleInfo)
        mock.downloadError = .pythonError(message: "ERROR: HTTP Error 403: Forbidden")
        let manager = DownloadTaskManager(
            engine: StubDownloadEngine(),
            ytDlpEngine: YtDlpDownloadEngine(engine: mock),
            storage: storage)
        let item = DownloadItem(
            fileName: "sample.mp4", format: .mp4, quality: .p360,
            fileSizeBytes: 0, state: .waiting,
            sourceURLString: watchURL.absoluteString)
        item.ytDlpFormatID = "18"

        XCTAssertTrue(manager.start(item: item, sourceURL: watchURL, fileName: "sample.mp4"))
        let deadline = Date().addingTimeInterval(5)
        while item.state != .failed && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.errorMessage, DownloadError.engineFailed(description: "x").userMessage)
        XCTAssertTrue(item.errorDetail?.contains("403") ?? false,
                      "item must carry the Python exception, got: \(item.errorDetail ?? "nil")")
        XCTAssertTrue(manager.errors[item.id]?.detailMessage?.contains("403") ?? false)
    }

    // MARK: - Settings download test

    func testSettingsDownloadTestReportsSuccess() async {
        let vm = SettingsViewModel(engine: MockYtDlpEngine(stubInfo: .sampleInfo))
        await vm.runDownloadTest()
        let result = vm.downloadTestResultText ?? "nil"
        XCTAssertTrue(result.contains("成功"), "got: \(result)")
        XCTAssertTrue(result.contains("形式ID 137+140"), "got: \(result)")
    }

    func testSettingsDownloadTestSurfacesFullError() async {
        let engine = MockYtDlpEngine(stubInfo: .sampleInfo)
        engine.downloadError = .pythonError(message: "ERROR: HTTP Error 403: Forbidden")
        let vm = SettingsViewModel(engine: engine)
        await vm.runDownloadTest()
        XCTAssertTrue(vm.downloadTestResultText?.contains("403") ?? false,
                      "got: \(vm.downloadTestResultText ?? "nil")")
    }

    // MARK: - Debug log store

    func testDebugLogStoreWritesAndRotates() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-DebugLogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<7 {
            let written = DebugLogStore.appendSession(
                kind: "download", url: "https://www.youtube.com/watch?v=x",
                formatID: "18", error: "boom \(i)", log: ["line \(i)"],
                traceback: nil, directory: dir,
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 61)))
            XCTAssertNotNil(written)
        }
        XCTAssertEqual(DebugLogStore.sessionFiles(in: dir).count, DebugLogStore.maxSessions)
        let latest = DebugLogStore.latestLogText(in: dir) ?? ""
        XCTAssertTrue(latest.contains("boom 6"), "latest log must be the newest session: \(latest)")
        XCTAssertTrue(latest.contains("line 6"))
    }

    // Regression (on-device, 2026-11-25): a 1080p HLS download died
    // after ~11 MB with "bridge returned malformed JSON" because
    // yt-dlp's total_bytes_estimate is fractional (34226326.5882353)
    // and JobStatus decoded byte counts as strict Int64, so the
    // status poll threw once every file's total became known.
    // Fractional counts must decode (truncated), never throw.
    func testBridgeStatusDecodesFractionalByteCounts() throws {
        let json = """
        {"ok": true, "job": {"status": "downloading", \
        "downloaded_bytes": 11205760.9, "total_bytes": 34226326.5882353, \
        "speed": 9331730.746783491, "eta": 2.073259748681488, \
        "filename": null, "files": [], "error": null}}
        """
        let response = try BridgeResponse.decode(json)
        XCTAssertEqual(response.job?.status, "downloading")
        XCTAssertEqual(response.job?.downloadedBytes, 11_205_760)
        XCTAssertEqual(response.job?.totalBytes, 34_226_326)
        XCTAssertEqual(response.job?.speed ?? 0, 9_331_730.746783491, accuracy: 0.001)
        XCTAssertEqual(response.job?.eta ?? 0, 2.073259748681488, accuracy: 0.000001)
    }

    func testBridgeStatusDecodesIntegerByteCountsAndNullTotal() throws {
        let json = """
        {"ok": true, "job": {"status": "downloading", \
        "downloaded_bytes": 1024, "total_bytes": null, \
        "speed": null, "eta": null, "filename": null, "files": []}}
        """
        let response = try BridgeResponse.decode(json)
        XCTAssertEqual(response.job?.downloadedBytes, 1024)
        XCTAssertNil(response.job?.totalBytes)
        XCTAssertNil(response.job?.speed)
    }
}

/// On-device/simulator integration tests for the real embedded CPython
/// runtime. These never touch the network: they boot the interpreter,
/// read versions, and run a trivial JS snippet through JavaScriptCore.
/// They skip when the Python resources are not part of the build.
final class EmbeddedPythonRuntimeTests: XCTestCase {

    func testRuntimeBootsAndReportsVersions() async throws {
        try XCTSkipUnless(YtDlpRuntime.resourcesPresent, "Python resources not bundled in this build")
        let versions = try await EmbeddedYtDlpEngine.shared.versions()
        XCTAssertFalse(versions.python.isEmpty)
        XCTAssertFalse(versions.ytDlp.isEmpty)
        XCTAssertTrue(versions.jscProvider, "JSC challenge provider must register")
        // Pin guard: these must match scripts/bootstrap_python.sh.
        // "Latest" claims bit-rot fast (2026.8.19 was three months
        // stale when Phase 4 shipped) — bump both places together.
        XCTAssertEqual(versions.ytDlp, "2026.11.23")
        XCTAssertEqual(versions.ytDlpEjs, "0.8.0")
    }

    /// Regression test for the on-device extraction failure of
    /// 2026-11-25: yt-dlp must NOT solve JS challenges against the
    /// player_ias ("main") player variant — the yt-dlp-ejs solver
    /// crashes on it with "a.addOnDisposeCallback is not a function"
    /// (reproduced offline against player b485e332 under Node, so the
    /// crash is in the solver/player combination, not JavaScriptCore).
    /// The bridge pins player_js_variant=tv; this asserts the
    /// extractor really resolves an ias URL to the tv variant.
    func testPlayerJSVariantIsForcedToTV() async throws {
        try XCTSkipUnless(YtDlpRuntime.resourcesPresent, "Python resources not bundled in this build")
        _ = try await EmbeddedYtDlpEngine.shared.versions()
        let response = try YtDlpRuntime.shared.call(function: "player_url", arguments: [
            "player_url": "https://www.youtube.com/s/player/b485e332/player_ias.vflset/en_US/base.js",
        ])
        let resolved = try XCTUnwrap(response.playerURL)
        XCTAssertTrue(resolved.contains("tv-player-ias"),
                      "ias player URL must be forced to the tv variant, got: \(resolved)")
    }

    /// End-to-end solver test, fully offline: the real registered JSC
    /// provider + JavaScriptCore run the bundled yt-dlp-ejs solver
    /// scripts against a fixed player fixture (player b485e332, tv
    /// variant — see VYRATests/Fixtures/README.md) and must return
    /// the known-correct n transform (verified against Node) plus a
    /// transformed sig string, instead of throwing.
    func testJSCSolverSolvesBundledPlayerFixture() async throws {
        try XCTSkipUnless(YtDlpRuntime.resourcesPresent, "Python resources not bundled in this build")
        _ = try await EmbeddedYtDlpEngine.shared.versions()

        let fixtureURL = try XCTUnwrap(
            Self.fixtureURL(named: "player-b485e332-tv.js.gz"),
            "player fixture missing from the test bundle")
        let fixtureData = try Data(contentsOf: fixtureURL)

        let sigInput = String((0...100).map { Character(UnicodeScalar($0)) })
        let response = try YtDlpRuntime.shared.call(function: "solve_fixture", arguments: [
            "player_gz_b64": fixtureData.base64EncodedString(),
            "player_url": "https://www.youtube.com/s/player/b485e332/tv-player-ias.vflset/tv-player-ias.js",
            "requests": [
                ["type": "n", "challenges": ["UWw7_jxUmCxZEi-Ie"]],
                ["type": "sig", "challenges": [sigInput]],
            ],
        ])
        let results = try XCTUnwrap(response.results, "solver returned no results")
        XCTAssertEqual(results["n"]?["UWw7_jxUmCxZEi-Ie"], "hNUP-K3dOsYDZQ")
        let sigOutput = try XCTUnwrap(results["sig"]?[sigInput], "sig challenge was not solved")
        XCTAssertNotEqual(sigOutput, sigInput)
        XCTAssertGreaterThanOrEqual(sigOutput.count, sigInput.count - 1)
    }

    private static func fixtureURL(named name: String) -> URL? {
        let bundle = Bundle(for: EmbeddedPythonRuntimeTests.self)
        if let url = bundle.url(forResource: name, withExtension: nil) {
            return url
        }
        // Folder-synchronized targets may nest resources; search.
        guard let enumerator = FileManager.default.enumerator(
            at: bundle.bundleURL, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    /// Cookie gating at the bridge boundary: `cookiefile` must reach
    /// yt-dlp's options only when the app passes a path AND the file
    /// exists there. (Contents are never involved — a header-only
    /// fixture file suffices.)
    func testBridgeCookiefileGating() async throws {
        try XCTSkipUnless(YtDlpRuntime.resourcesPresent, "Python resources not bundled in this build")
        _ = try await EmbeddedYtDlpEngine.shared.versions()

        // No param -> no cookiefile.
        var response = try YtDlpRuntime.shared.call(function: "opts_probe", arguments: [:])
        XCTAssertEqual(response.hasCookiefile, false)

        // Nonexistent path -> gated out.
        response = try YtDlpRuntime.shared.call(function: "opts_probe", arguments: [
            "cookiefile": "/nonexistent/cookies.txt",
        ])
        XCTAssertEqual(response.hasCookiefile, false)

        // Existing file -> passed through verbatim.
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("vyra-opts-probe-cookies.txt")
        try "# Netscape HTTP Cookie File\n".write(to: fixture, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixture) }
        response = try YtDlpRuntime.shared.call(function: "opts_probe", arguments: [
            "cookiefile": fixture.path,
        ])
        XCTAssertEqual(response.hasCookiefile, true)
        XCTAssertEqual(response.cookiefile, fixture.path)

        // POT plumbing: providers read their settings from their
        // own extractor-args namespace (youtubepot-<key>), which is
        // what _base_opts must produce. No base URL -> no bgutil
        // settings; with one -> youtubepot-bgutilhttp base_url. No
        // on-device flag -> no youtubepot-vyraondevice settings.
        // The bgutil plugin is vendored (bootstrap_python.sh pins
        // bgutil-ytdlp-pot-provider==2.0.2 into app_packages), so
        // the HTTP provider module must be discoverable, importing
        // it must register 'bgutil:http' in yt-dlp's POT provider
        // registry, the in-process on-device provider must register
        // 'vyra:ondevice', and the subprocess-based script-mode
        // module must be absent (deleted at bootstrap time).
        XCTAssertNil(response.potBgutilBaseURL)
        XCTAssertEqual(response.potOndeviceSettings, false)
        XCTAssertEqual(response.potPluginAvailable, true)
        XCTAssertEqual(response.potBgutilRegistered, true)
        XCTAssertEqual(response.potOndeviceRegistered, true)
        XCTAssertEqual(response.potScriptModulePresent, false)
        XCTAssertTrue(response.potProviders?.contains("bgutil:http") ?? false,
                      "registered POT providers: \(response.potProviders ?? [])")
        XCTAssertTrue(response.potProviders?.contains("vyra:ondevice") ?? false,
                      "registered POT providers: \(response.potProviders ?? [])")
        response = try YtDlpRuntime.shared.call(function: "opts_probe", arguments: [
            "pot_base_url": "http://192.168.1.10:4416",
            "pot_ondevice": true,
        ])
        XCTAssertEqual(response.potBgutilBaseURL, "http://192.168.1.10:4416")
        XCTAssertEqual(response.potOndeviceSettings, true)
    }

    func testJavaScriptCoreBridgeRoundTrip() async throws {
        try XCTSkipUnless(YtDlpRuntime.resourcesPresent, "Python resources not bundled in this build")
        _ = try await EmbeddedYtDlpEngine.shared.versions()
        let response = try YtDlpRuntime.shared.call(function: "run_js", arguments: [
            "script": "console.log(JSON.stringify({sum: 20 + 22}));",
        ])
        let output = try XCTUnwrap(response.output)
        XCTAssertTrue(output.contains("\"sum\":42") || output.contains("\"sum\": 42"), "got: \(output)")
    }

    private static func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(fixtureURL(named: name), "fixture \(name) missing from the test bundle")
        return try Data(contentsOf: url)
    }

    /// REAL HLS path, no mocks: the committed two-segment HLS
    /// fixture is served over localhost HTTP, the embedded engine
    /// extracts it (generic extractor -> the m3u8 format), and
    /// yt-dlp's native HLS downloader downloads it through the
    /// bridge. (a) A .direct download must be the raw MPEG-TS
    /// bytes (both segments concatenated, 0x47 sync bytes) — that
    /// is what yt-dlp produces on iOS, where no ffmpeg binary
    /// exists for its M3U8 fixup postprocessor. (b) The same
    /// selection with .remuxSingle must come back as a playable
    /// MP4 with video+audio tracks (the in-process TS->MP4 remux).
    func testHLSDownloadThroughBridgeAndRemux() async throws {
        try XCTSkipUnless(YtDlpRuntime.resourcesPresent, "Python resources not bundled in this build")
        _ = try await EmbeddedYtDlpEngine.shared.versions()

        let playlist = try Self.fixtureData(named: "playlist.m3u8")
        let seg0 = try Self.fixtureData(named: "seg00.bin")
        let seg1 = try Self.fixtureData(named: "seg01.bin")
        let server = FixtureHTTPServer(files: [
            "playlist.m3u8": playlist, "seg00.ts": seg0, "seg01.ts": seg1,
        ])
        let port = try server.start()
        defer { server.stop() }
        let pageURL = URL(string: "http://127.0.0.1:\(port)/playlist.m3u8")!

        let engine = EmbeddedYtDlpEngine.shared
        let info = try await engine.extractMetadata(url: pageURL)
        let hlsFormat = try XCTUnwrap(
            info.formats.first { ($0.protocolName ?? "").contains("m3u8") },
            "extract must report the HLS format, got: \(info.formats.map(\.formatID))")
        let hlsFormatID = try XCTUnwrap(hlsFormat.formatID)

        // (a) Raw yt-dlp HLS download = MPEG-TS bytes.
        let rawFile = try await engine.download(
            jobID: UUID(), url: pageURL, formatID: hlsFormatID,
            fileName: "hls-raw.mp4",
            context: YtDlpProcessingContext(processing: .direct),
            progress: { _ in })
        let rawData = try Data(contentsOf: rawFile)
        XCTAssertEqual(rawData.count, seg0.count + seg1.count,
                       "downloaded bytes must be exactly the two TS segments")
        XCTAssertEqual(rawData.first, 0x47, "MPEG-TS sync byte")
        XCTAssertEqual(rawData[188], 0x47, "MPEG-TS packets are 188-byte aligned")
        XCTAssertEqual(rawData[seg0.count], 0x47, "second segment follows the first")

        // (b) .remuxSingle = the same download, remuxed in-process
        // to a playable MP4.
        let mp4 = try await engine.download(
            jobID: UUID(), url: pageURL, formatID: hlsFormatID,
            fileName: "hls.mp4",
            context: YtDlpProcessingContext(processing: .remuxSingle),
            progress: { _ in })
        let asset = AVURLAsset(url: mp4)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1, "remuxed HLS download must have a video track")
        XCTAssertEqual(audioTracks.count, 1, "remuxed HLS download must have an audio track")
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2.0, accuracy: 0.6,
                       "two 1s segments must give ~2s, got \(duration.seconds)")
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "remuxed HLS download must be playable by AVKit")
    }
}

/// Minimal HTTP/1.1 file server over POSIX sockets (no NWListener:
/// no local-network permission surface in the test host). Serves
/// fixed name -> Data files on 127.0.0.1 with an ephemeral port,
/// one connection at a time, `Connection: close` per response —
/// exactly what yt-dlp's downloader needs for the HLS fixture.
private final class FixtureHTTPServer: @unchecked Sendable {
    private let files: [String: Data]
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let stateLock = NSLock()
    private var running = false

    init(files: [String: Data]) {
        self.files = files
    }

    func start() throws -> UInt16 {
        listenFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw NSError(domain: "FixtureHTTPServer", code: 1) }
        var reuse: Int32 = 1
        Darwin.setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listenFD, 16) == 0 else {
            throw NSError(domain: "FixtureHTTPServer", code: 2)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.getsockname(listenFD, $0, &length)
            }
        }
        let port = UInt16(bigEndian: actual.sin_port)
        stateLock.lock()
        running = true
        stateLock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.stackSize = 1 << 20
        acceptThread = thread
        thread.start()
        return port
    }

    func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
        if listenFD >= 0 {
            Darwin.shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    private func isRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func acceptLoop() {
        while isRunning() {
            let client = Darwin.accept(listenFD, nil, nil)
            if client < 0 {
                if !isRunning() { break }
                continue
            }
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while request.count < 65536 {
            let received = Darwin.recv(client, &buffer, buffer.count, 0)
            if received <= 0 { break }
            request.append(contentsOf: buffer[..<received])
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let text = String(data: request, encoding: .utf8),
              let path = text.split(separator: " ").dropFirst().first else { return }
        let name = path.hasPrefix("/") ? String(path.dropFirst()) : String(path)
        let response: Data
        if let body = files[name] {
            var data = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            data.append(body)
            response = data
        } else {
            response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        response.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let written = Darwin.send(client, base + sent, raw.count - sent, 0)
                if written <= 0 { break }
                sent += written
            }
        }
    }
}
