import XCTest
@testable import VYRA

/// Split-pair (video-only + audio-only) format offering, selection
/// and download routing. Offering is not narrowed by codec or
/// container: an avc1 video-only MP4 format paired with the best M4A
/// audio format is a stream-copy (.remux) option, and VP9/AV1/WebM
/// formats are offered too — paired with the best available audio
/// and transcoded in-process to H.264 + AAC (.transcode).
@MainActor
final class SplitFormatTests: XCTestCase {

    private let watchURL = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!

    private func format(_ id: String, ext: String = "mp4",
                        vcodec: String?, acodec: String?,
                        height: Int? = nil, size: Int64? = nil,
                        tbr: Double? = nil, protocol: String = "https") -> YtDlpFormatInfo {
        let hasVideo = (vcodec ?? "none") != "none"
        let hasAudio = (acodec ?? "none") != "none"
        return YtDlpFormatInfo(
            formatID: id, ext: ext, vcodec: vcodec, acodec: acodec,
            height: height, fps: 30, filesize: size, filesizeApprox: nil,
            formatNote: height.map { "\($0)p" },
            singleFile: hasVideo && hasAudio || hasAudio && !hasVideo,
            requiresMerge: hasVideo && !hasAudio,
            tbr: tbr, protocolName: `protocol`)
    }

    private func metadata(_ formats: [YtDlpFormatInfo]) -> VideoMetadata {
        var info = MockYtDlpEngine.sampleInfo
        info.formats = formats
        return YtDlpMetadataMapper.metadata(from: info, sourceURL: watchURL)
    }

    private var typicalFormats: [YtDlpFormatInfo] {
        [
            format("18", vcodec: "avc1.42001E", acodec: "mp4a.40.2", height: 360, size: 12_000_000, tbr: 500),
            format("136", vcodec: "avc1.64001F", acodec: "none", height: 720, size: 25_000_000, tbr: 1200),
            format("137", vcodec: "avc1.640028", acodec: "none", height: 1080, size: 45_000_000, tbr: 2200),
            format("248", ext: "webm", vcodec: "vp09.00.10.08", acodec: "none", height: 1080, size: 40_000_000, tbr: 1800),
            format("139", ext: "m4a", vcodec: "none", acodec: "mp4a.40.5", size: 1_500_000, tbr: 48),
            format("140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", size: 3_800_000, tbr: 128),
        ]
    }

    // MARK: - Pairing

    func testMapperCarriesCodecs() {
        let meta = metadata(typicalFormats)
        let videoOnly = meta.availableFormats?.first { $0.formatID == "137" }
        XCTAssertEqual(videoOnly?.videoCodec, "avc1.640028")
        XCTAssertEqual(videoOnly?.audioCodec, "none")
        let audio = meta.availableFormats?.first { $0.formatID == "140" }
        XCTAssertEqual(audio?.audioCodec, "mp4a.40.2")
    }

    func testSplitPairingOffers720And1080() {
        let options = MediaFormatService.options(from: metadata(typicalFormats))
        let qualities = MediaFormatService.qualities(for: .mp4, in: options)
        XCTAssertTrue(qualities.contains(.p360))
        XCTAssertTrue(qualities.contains(.p720))
        XCTAssertTrue(qualities.contains(.p1080))
        let split720 = options.first { $0.ytDlpFormatID == "136" }
        XCTAssertEqual(split720?.audioYtDlpFormatID, "140")
        XCTAssertEqual(split720?.estimatedFileSize, 25_000_000 + 3_800_000)
    }

    func testPairingPicksBestM4AAudio() {
        // 140 (128 kbps) must win over 139 (48 kbps) as the pair's audio.
        let meta = metadata(typicalFormats)
        let best = MediaFormatService.bestPairedAudio(in: meta.availableFormats ?? [])
        XCTAssertEqual(best?.formatID, "140")
        let options = MediaFormatService.options(from: meta)
        XCTAssertTrue(options.filter(\.isSplitPair).allSatisfy { $0.audioYtDlpFormatID == "140" })
    }

    func testCopyablePreferredOverVP9AtSameHeight() {
        // At 1080p both avc1 (137) and vp9 (248, and vp9-in-mp4 616)
        // exist: the copyable avc1 split pair wins the height, so the
        // option is the .remux pair 137+140 — VP9 is only chosen when
        // no copyable format exists at that height.
        var formats = typicalFormats
        formats.append(format("616", vcodec: "vp09.00.10.08", acodec: "none", height: 1080, size: 40_000_000, tbr: 1800))
        let options = MediaFormatService.options(from: metadata(formats))
        let at1080 = options.filter { $0.qualityLabel == "1080p" }
        XCTAssertEqual(at1080.count, 1, "one option per height")
        XCTAssertEqual(at1080.first?.ytDlpFormatID, "137")
        XCTAssertEqual(at1080.first?.processing, .remux)
        XCTAssertFalse(options.contains { $0.ytDlpFormatID == "248" })
        XCTAssertFalse(options.contains { $0.ytDlpFormatID == "616" })
    }

    func testVP9OnlyHeightIsOfferedAsTranscode() {
        // A height served ONLY by VP9/WebM (the common 1440p/2160p
        // situation, here 1080p without avc1) is offered, paired with
        // the best audio and marked .transcode.
        let formats = [
            format("18", vcodec: "avc1.42001E", acodec: "mp4a.40.2", height: 360, size: 12_000_000, tbr: 500),
            format("248", ext: "webm", vcodec: "vp09.00.10.08", acodec: "none", height: 1080, size: 40_000_000, tbr: 1800),
            format("140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", size: 3_800_000, tbr: 128),
            format("251", ext: "webm", vcodec: "none", acodec: "opus", size: 3_400_000, tbr: 110),
        ]
        let options = MediaFormatService.options(from: metadata(formats))
        let at1080 = options.first { $0.qualityLabel == "1080p" }
        XCTAssertEqual(at1080?.ytDlpFormatID, "248")
        XCTAssertEqual(at1080?.processing, .transcode)
        XCTAssertEqual(at1080?.videoCodec, "vp09.00.10.08")
        XCTAssertEqual(at1080?.sourceContainer, "webm")
        // AAC audio is preferred for pairing even for a transcode.
        XCTAssertEqual(at1080?.audioYtDlpFormatID, "140")
        // The saved file is still an MP4.
        XCTAssertEqual(at1080?.fileExtension, "mp4")
        XCTAssertEqual(at1080?.format, .mp4)
    }

    func testOpusPairedWhenNoAACAudioExists() {
        // No AAC anywhere: the best opus audio pairs with everything,
        // and even an avc1 video becomes a .transcode (its audio leg
        // cannot be stream-copied).
        let formats = [
            format("137", vcodec: "avc1.640028", acodec: "none", height: 1080, size: 45_000_000, tbr: 2200),
            format("251", ext: "webm", vcodec: "none", acodec: "opus", size: 3_400_000, tbr: 110),
            format("250", ext: "webm", vcodec: "none", acodec: "opus", size: 1_700_000, tbr: 55),
        ]
        let meta = metadata(formats)
        XCTAssertEqual(MediaFormatService.bestPairedAudio(in: meta.availableFormats ?? [])?.formatID, "251")
        let options = MediaFormatService.options(from: meta)
        let at1080 = options.first { $0.qualityLabel == "1080p" }
        XCTAssertEqual(at1080?.ytDlpFormatID, "137")
        XCTAssertEqual(at1080?.audioYtDlpFormatID, "251")
        XCTAssertEqual(at1080?.processing, .transcode)
    }

    func test1440And2160HeightsAreOffered() {
        var formats = typicalFormats
        formats.append(format("271", ext: "webm", vcodec: "vp09.00.10.08", acodec: "none", height: 1440, size: 90_000_000, tbr: 4500))
        formats.append(format("313", ext: "webm", vcodec: "vp09.00.10.08", acodec: "none", height: 2160, size: 180_000_000, tbr: 9000))
        let options = MediaFormatService.options(from: metadata(formats))
        let qualities = MediaFormatService.qualities(for: .mp4, in: options)
        XCTAssertTrue(qualities.contains(.p1440))
        XCTAssertTrue(qualities.contains(.p2160))
        XCTAssertTrue(qualities.contains(.original))
        // Original = the global best height (2160p VP9, transcoded).
        let original = MediaFormatService.selectOption(in: options, format: .mp4, quality: .original)
        XCTAssertEqual(original?.ytDlpFormatID, "313")
        XCTAssertEqual(original?.processing, .transcode)
        let at1440 = MediaFormatService.selectOption(in: options, format: .mp4, quality: .p1440)
        XCTAssertEqual(at1440?.ytDlpFormatID, "271")
    }

    func testCombinedWebMIsOfferedAsTranscode() {
        // A combined VP9+Opus WebM file: one download, then transcode.
        let formats = [
            format("43x", ext: "webm", vcodec: "vp09.00.10.08", acodec: "opus", height: 360, size: 9_000_000, tbr: 400),
            format("140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", size: 3_800_000, tbr: 128),
        ]
        let options = MediaFormatService.options(from: metadata(formats))
        let at360 = options.first { $0.qualityLabel == "360p" }
        XCTAssertEqual(at360?.ytDlpFormatID, "43x")
        XCTAssertNil(at360?.audioYtDlpFormatID)
        XCTAssertEqual(at360?.processing, .transcode)
    }

    func testCombinedMP4WithOpusAudioIsTranscodeNotDirect() {
        // avc1 video but non-AAC audio in one file: cannot be saved
        // as-is for AVKit, so it is a transcode, not .direct.
        let formats = [
            format("99x", ext: "mp4", vcodec: "avc1.640028", acodec: "opus", height: 1080, size: 40_000_000, tbr: 2000),
            format("140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", size: 3_800_000, tbr: 128),
        ]
        let options = MediaFormatService.options(from: metadata(formats))
        let at1080 = options.first { $0.qualityLabel == "1080p" }
        XCTAssertEqual(at1080?.processing, .transcode)
        XCTAssertNil(at1080?.audioYtDlpFormatID)
    }

    func testAudioOnlyOpusIsOfferedAsM4ATranscode() {
        // Opus/WebM audio-only is offered as an M4A option (transcode
        // to AAC); an AAC/M4A option still wins selection (direct).
        let formats = [
            format("251", ext: "webm", vcodec: "none", acodec: "opus", size: 3_400_000, tbr: 110),
            format("140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", size: 3_800_000, tbr: 128),
        ]
        let options = MediaFormatService.options(from: metadata(formats))
        let opus = options.first { $0.ytDlpFormatID == "251" }
        XCTAssertEqual(opus?.format, .m4a)
        XCTAssertEqual(opus?.fileExtension, "m4a")
        XCTAssertEqual(opus?.processing, .transcode)
        let selected = MediaFormatService.selectOption(in: options, format: .m4a, quality: nil)
        XCTAssertEqual(selected?.ytDlpFormatID, "140")
        XCTAssertEqual(selected?.processing, .direct)
    }

    func testManagerDownloadsTranscodeSplitViaEngine() async throws {
        // The processing kind chosen at selection time must reach the
        // engine through item -> request -> adapter.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-TranscodeRouteTests-\(UUID().uuidString)", isDirectory: true)
        let storage = FileStorageService(
            documentsDirectory: tempRoot.appendingPathComponent("Documents", isDirectory: true),
            temporaryDirectory: tempRoot.appendingPathComponent("Temp", isDirectory: true))
        try FileManager.default.createDirectory(at: storage.documentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage.temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockYtDlpEngine(stubInfo: .sampleInfo)
        let manager = DownloadTaskManager(
            engine: StubDownloadEngine(),
            ytDlpEngine: YtDlpDownloadEngine(engine: mock),
            storage: storage)
        let item = DownloadItem(
            fileName: "sample.mp4", format: .mp4, quality: .p2160,
            fileSizeBytes: 0, state: .waiting,
            sourceURLString: watchURL.absoluteString)
        item.ytDlpFormatID = "313"
        item.ytDlpAudioFormatID = "251"
        item.ytDlpProcessing = .transcode

        XCTAssertTrue(manager.start(item: item, sourceURL: watchURL, fileName: "sample.mp4"))
        let deadline = Date().addingTimeInterval(5)
        while item.state != .completed && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(mock.splitContexts.first?.processing, .transcode)
    }

    func testSplitPairNeedsAnAudioFormat() {
        let noAudio = typicalFormats.filter { $0.formatID != "139" && $0.formatID != "140" }
        let options = MediaFormatService.options(from: metadata(noAudio))
        XCTAssertEqual(Set(options.compactMap(\.ytDlpFormatID)), ["18"])
    }

    func testSplitPairSizeIsNilWhenEitherSideUnknown() {
        var formats = typicalFormats
        formats[2] = format("137", vcodec: "avc1.640028", acodec: "none", height: 1080, size: nil, tbr: 2200)
        let options = MediaFormatService.options(from: metadata(formats))
        let split = options.first { $0.ytDlpFormatID == "137" }
        XCTAssertNotNil(split)
        XCTAssertNil(split?.estimatedFileSize)
    }

    // MARK: - Selection

    func testOriginalSelectsHighestSplitPair() {
        let options = MediaFormatService.options(from: metadata(typicalFormats))
        let original = MediaFormatService.selectOption(in: options, format: .mp4, quality: .original)
        XCTAssertEqual(original?.ytDlpFormatID, "137")
        XCTAssertEqual(original?.audioYtDlpFormatID, "140")
    }

    func testCombinedPreferredOverSplitAtSameHeight() {
        var formats = typicalFormats
        formats.append(format("22", vcodec: "avc1.64001F", acodec: "mp4a.40.2", height: 720, size: 28_000_000, tbr: 1500))
        let options = MediaFormatService.options(from: metadata(formats))
        let selected = MediaFormatService.selectOption(in: options, format: .mp4, quality: .p720)
        XCTAssertEqual(selected?.ytDlpFormatID, "22")
        XCTAssertNil(selected?.audioYtDlpFormatID)
    }

    func testExactQualitySelectsSplitPair() {
        let options = MediaFormatService.options(from: metadata(typicalFormats))
        let selected = MediaFormatService.selectOption(in: options, format: .mp4, quality: .p1080)
        XCTAssertEqual(selected?.ytDlpFormatID, "137")
        XCTAssertEqual(selected?.audioYtDlpFormatID, "140")
    }

    func testYouTubeQualityTiersRetainCustomStreamDimensions() {
        var hd = format("137", vcodec: "avc1.640028", acodec: "none", height: 804)
        hd.width = 1920
        hd.formatNote = "1080p"
        var hls = format("96", vcodec: "avc1.640028", acodec: "mp4a.40.2", height: 804, protocol: "m3u8_native")
        hls.width = 1920
        hls.formatNote = nil
        var uhd = format("337", ext: "webm", vcodec: "vp09.02.51.10", acodec: "none", height: 1608)
        uhd.width = 3840
        uhd.formatNote = "2160p60 HDR, tv"
        let audio = format("140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2")

        let viewModel = VideoPreviewViewModel(metadata: metadata([hd, hls, uhd, audio]))
        XCTAssertEqual(viewModel.availableQualities, [.p1080, .p2160, .original])
        viewModel.selectedQuality = .p1080
        XCTAssertEqual(viewModel.selectionSummary, "MP4 · 1080p (1920×804)")
        XCTAssertEqual(viewModel.selectedYtDlpFormatID, "96")
        viewModel.selectedQuality = .p2160
        XCTAssertEqual(viewModel.selectionSummary, "MP4 · 2160p (3840×1608)")
        let item = viewModel.makeDownloadItem()
        XCTAssertEqual(item.ytDlpFormatID, "337")
        XCTAssertEqual(item.ytDlpAudioFormatID, "140")
        XCTAssertEqual(item.ytDlpPixelHeight, 1608)
        viewModel.selectedQuality = .original
        XCTAssertEqual(viewModel.selectedYtDlpFormatID, "337")
    }

    func testUnlabelledCustomHeightIsSelectableAlongsideOriginal() throws {
        var custom = format("17", vcodec: "avc1.640028", acodec: "mp4a.40.2", height: 768)
        custom.formatNote = nil
        let options = MediaFormatService.options(from: metadata(typicalFormats + [custom]))
        let quality = try XCTUnwrap(DownloadQuality.forHeight(768))
        XCTAssertEqual(DownloadQuality(rawValue: quality.rawValue), quality)
        XCTAssertEqual(DownloadQuality(rawValue: "p1080"), .p1080)
        XCTAssertTrue(MediaFormatService.qualities(for: .mp4, in: options).contains(quality))
        XCTAssertEqual(MediaFormatService.selectOption(in: options, format: .mp4, quality: quality)?.ytDlpFormatID, "17")
        XCTAssertEqual(MediaFormatService.selectOption(in: options, format: .mp4, quality: .original)?.ytDlpFormatID, "137")
    }

    // MARK: - Resolver

    func testResolverReturnsAudioFormatIDForSplitSelection() {
        let resolution = DirectMediaResolver.resolve(
            sourceURL: watchURL, format: .mp4, quality: .p1080, metadata: metadata(typicalFormats))
        guard case .ytDlp(let formatID, let audioFormatID, _) = resolution else {
            return XCTFail("expected .ytDlp, got \(resolution)")
        }
        XCTAssertEqual(formatID, "137")
        XCTAssertEqual(audioFormatID, "140")
    }

    func testResolverReturnsNoAudioFormatIDForCombinedSelection() {
        let resolution = DirectMediaResolver.resolve(
            sourceURL: watchURL, format: .mp4, quality: .p360, metadata: metadata(typicalFormats))
        guard case .ytDlp(let formatID, let audioFormatID, _) = resolution else {
            return XCTFail("expected .ytDlp, got \(resolution)")
        }
        XCTAssertEqual(formatID, "18")
        XCTAssertNil(audioFormatID)
    }

    // MARK: - Download through the task manager

    func testManagerDownloadsSplitPairViaEngine() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-SplitTests-\(UUID().uuidString)", isDirectory: true)
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
            fileName: "sample.mp4", format: .mp4, quality: .p1080,
            fileSizeBytes: 0, state: .waiting,
            sourceURLString: watchURL.absoluteString)
        item.ytDlpFormatID = "137"
        item.ytDlpAudioFormatID = "140"

        XCTAssertTrue(manager.start(item: item, sourceURL: watchURL, fileName: "sample.mp4"))
        let deadline = Date().addingTimeInterval(5)
        while item.state != .completed && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(mock.splitDownloads.count, 1)
        XCTAssertEqual(mock.splitDownloads.first?.video, "137")
        XCTAssertEqual(mock.splitDownloads.first?.audio, "140")
        XCTAssertEqual(completedItem?.id, item.id)
        let relative = try XCTUnwrap(item.localFileRelativePath)
        XCTAssertTrue(storage.fileExists(relativePath: relative))
    }

    // MARK: - HLS offering

    func testHLSOnlyHeightsAreOfferedAsRemuxSingle() {
        // The SABR-session shape: above 360p ONLY HLS combined
        // renditions (itag 95/96 style) exist. Those heights must
        // stay selectable — as .remuxSingle options (yt-dlp's
        // native HLS download + in-process TS->MP4 remux), never
        // silently dropped.
        let formats = [
            format("18", vcodec: "avc1.42001E", acodec: "mp4a.40.2", height: 360, size: 12_000_000, tbr: 500),
            format("95", vcodec: "avc1.4d401f", acodec: "mp4a.40.2", height: 720, size: 30_000_000, tbr: 2500, protocol: "m3u8_native"),
            format("96", vcodec: "avc1.640028", acodec: "mp4a.40.2", height: 1080, size: 55_000_000, tbr: 5000, protocol: "m3u8_native"),
            format("140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", size: 3_800_000, tbr: 128),
        ]
        let options = MediaFormatService.options(from: metadata(formats))
        let at720 = options.first { $0.qualityLabel == "720p" }
        XCTAssertEqual(at720?.ytDlpFormatID, "95")
        XCTAssertEqual(at720?.processing, .remuxSingle)
        XCTAssertNil(at720?.audioYtDlpFormatID, "HLS combined needs no paired audio")
        let at1080 = options.first { $0.qualityLabel == "1080p" }
        XCTAssertEqual(at1080?.ytDlpFormatID, "96")
        XCTAssertEqual(at1080?.processing, .remuxSingle)
        let qualities = MediaFormatService.qualities(for: .mp4, in: options)
        XCTAssertTrue(qualities.contains(.p720))
        XCTAssertTrue(qualities.contains(.p1080))
    }

    func testHTTPSCombinedBeatsHLSAtSameHeight() {
        // Preference order: a copyable HTTPS combined format saves
        // as-is (.direct) and wins over the HLS rendition of the
        // same height even when the HLS one reports a higher bitrate.
        let formats = [
            format("22", vcodec: "avc1.64001F", acodec: "mp4a.40.2", height: 720, size: 28_000_000, tbr: 2000),
            format("95", vcodec: "avc1.4d401f", acodec: "mp4a.40.2", height: 720, size: 30_000_000, tbr: 2500, protocol: "m3u8_native"),
            format("140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", size: 3_800_000, tbr: 128),
        ]
        let options = MediaFormatService.options(from: metadata(formats))
        let at720 = options.filter { $0.qualityLabel == "720p" }
        XCTAssertEqual(at720.count, 1, "one option per height")
        XCTAssertEqual(at720.first?.ytDlpFormatID, "22")
        XCTAssertEqual(at720.first?.processing, .direct)
    }

    func testHLSCombinedBeatsSplitPairAtSameHeight() {
        // Preference order: HLS combined (one download + TS remux)
        // wins over a split pair (two downloads + pair remux).
        let formats = [
            format("95", vcodec: "avc1.4d401f", acodec: "mp4a.40.2", height: 720, size: 30_000_000, tbr: 2500, protocol: "m3u8_native"),
            format("136", vcodec: "avc1.64001F", acodec: "none", height: 720, size: 25_000_000, tbr: 1200),
            format("140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", size: 3_800_000, tbr: 128),
        ]
        let options = MediaFormatService.options(from: metadata(formats))
        let at720 = options.filter { $0.qualityLabel == "720p" }
        XCTAssertEqual(at720.count, 1, "one option per height")
        XCTAssertEqual(at720.first?.ytDlpFormatID, "95")
        XCTAssertEqual(at720.first?.processing, .remuxSingle)
        XCTAssertNil(at720.first?.audioYtDlpFormatID)
    }

    func testNonCopyableHLSCombinedIsOfferedAsTranscode() {
        // An HLS combined format whose codecs cannot be
        // stream-copied (here AV1 video) is still offered — as a
        // transcode, not dropped.
        let formats = [
            format("18", vcodec: "avc1.42001E", acodec: "mp4a.40.2", height: 360, size: 12_000_000, tbr: 500),
            format("96", vcodec: "av01.0.08M.08", acodec: "mp4a.40.2", height: 1080, size: 40_000_000, tbr: 3000, protocol: "m3u8_native"),
            format("140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", size: 3_800_000, tbr: 128),
        ]
        let options = MediaFormatService.options(from: metadata(formats))
        let at1080 = options.first { $0.qualityLabel == "1080p" }
        XCTAssertEqual(at1080?.ytDlpFormatID, "96")
        XCTAssertEqual(at1080?.processing, .transcode)
        XCTAssertNil(at1080?.audioYtDlpFormatID)
    }

    func testHLSVideoOnlyIsNotOffered() {
        // An HLS video-only rendition cannot be paired (pairs form
        // within one protocol; the paired audio comes from the
        // HTTPS formats), so a height served only by it yields no
        // option rather than a silent video file.
        let formats = [
            format("18", vcodec: "avc1.42001E", acodec: "mp4a.40.2", height: 360, size: 12_000_000, tbr: 500),
            format("hls-v720", vcodec: "avc1.64001F", acodec: "none", height: 720, size: 25_000_000, tbr: 1200, protocol: "m3u8_native"),
            format("140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", size: 3_800_000, tbr: 128),
        ]
        let options = MediaFormatService.options(from: metadata(formats))
        XCTAssertFalse(options.contains { $0.qualityLabel == "720p" })
        XCTAssertFalse(options.contains { $0.ytDlpFormatID == "hls-v720" })
    }

    // NOTE: SplitProgressCombiner is gone — since the download
    // rework the bridge aggregates a split job's progress itself
    // (one bridge job per selection), so there is no Swift-side
    // leg combining left to test. The aggregation rule (total only
    // once every file's total is known) is implemented and
    // exercised in vyra_bridge.py's progress hook.
}
