import XCTest
@testable import VYRA

/// Tests for the Settings diagnostics features added after the
/// on-device "only one format option" report, plus the worker.js
/// (しあ's LAN yt-dlp worker) mechanisms adopted on his order:
/// failure classification, terminal-failure memory, format-URL
/// expiry, and the bgutil POT plumbing. (The worker's multi-cookie
/// rotation and cookie-free window were rejected by しあ as
/// server-scale ops for a public web service — not adopted.)
///
/// Cookie fixtures use FAKE values only — real session cookies must
/// never appear in this repository.
final class CookieStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var storeDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: CookieStore!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-CookieTests-\(UUID().uuidString)", isDirectory: true)
        storeDirectory = tempRoot.appendingPathComponent("cookies", isDirectory: true)
        suiteName = "VYRA-CookieTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = CookieStore(defaults: defaults, directory: storeDirectory)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    /// A plausible Netscape cookies.txt: header, a comment, one
    /// regular cookie line and one #HttpOnly_ line (7 fields each).
    private static let validFixture = """
        # Netscape HTTP Cookie File
        # This is a generated file! Do not edit.

        .youtube.com\tTRUE\t/\tTRUE\t1893456000\tFAKE_SESSION\tfake-value-1
        #HttpOnly_.google.com\tTRUE\t/\tTRUE\t1893456000\tFAKE_ID\tfake-value-2
        """

    private func writeFixture(_ text: String, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let url = tempRoot.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testEntryCountParsesValidFixture() {
        XCTAssertEqual(CookieStore.entryCount(in: Self.validFixture), 2)
    }

    func testEntryCountRejectsNonCookieText() {
        XCTAssertNil(CookieStore.entryCount(in: "just some text\nwith lines\n"))
        XCTAssertNil(CookieStore.entryCount(in: ""))
    }

    func testEntryCountAcceptsHeaderOnlyFile() {
        // Header present but zero entries: plausible (an export of an
        // empty jar) — accepted, count 0.
        XCTAssertEqual(CookieStore.entryCount(in: "# Netscape HTTP Cookie File\n"), 0)
    }

    func testImportStoresFileAndReportsStatus() throws {
        let picked = try writeFixture(Self.validFixture, name: "cookies.txt")
        let status = try store.importCookies(from: picked)
        XCTAssertEqual(status.entryCount, 2)
        XCTAssertEqual(status.fileName, "cookies.txt")
        XCTAssertTrue(status.isEnabled, "a fresh import starts enabled")
        XCTAssertTrue(store.hasCookieFile)
        XCTAssertEqual(store.activeCookieFileURL(), store.cookieFileURL)
    }

    func testImportRejectsInvalidFileAndKeepsState() throws {
        let picked = try writeFixture("not a cookie file at all", name: "bad.txt")
        XCTAssertThrowsError(try store.importCookies(from: picked)) { error in
            XCTAssertEqual(error as? CookieStore.ImportError, .notNetscapeFormat)
        }
        XCTAssertFalse(store.hasCookieFile)
        XCTAssertNil(store.status)
        XCTAssertNil(store.activeCookieFileURL())
    }

    func testImportRejectsEmptyFile() throws {
        let picked = try writeFixture("", name: "empty.txt")
        XCTAssertThrowsError(try store.importCookies(from: picked)) { error in
            XCTAssertEqual(error as? CookieStore.ImportError, .emptyFile)
        }
        XCTAssertFalse(store.hasCookieFile)
    }

    func testToggleGatesActiveFile() throws {
        let picked = try writeFixture(Self.validFixture, name: "cookies.txt")
        _ = try store.importCookies(from: picked)
        store.isEnabled = false
        XCTAssertNil(store.activeCookieFileURL(),
                     "toggle off must make the engine behave as if no cookies exist")
        XCTAssertNotNil(store.status, "status still reports the stored file")
        store.isEnabled = true
        XCTAssertEqual(store.activeCookieFileURL(), store.cookieFileURL)
    }

    func testDeleteRemovesFileAndMetadata() throws {
        let picked = try writeFixture(Self.validFixture, name: "cookies.txt")
        _ = try store.importCookies(from: picked)
        store.deleteCookies()
        XCTAssertFalse(store.hasCookieFile)
        XCTAssertNil(store.status)
        XCTAssertNil(store.activeCookieFileURL())
        XCTAssertFalse(store.isEnabled)
    }

    func testReimportReplacesTheSingleSet() throws {
        _ = try store.importCookies(from: writeFixture(Self.validFixture, name: "a.txt"))
        let second = try store.importCookies(
            from: writeFixture("# Netscape HTTP Cookie File\n", name: "b.txt"))
        XCTAssertEqual(second.entryCount, 0)
        XCTAssertEqual(store.status?.entryCount, 0,
                       "there is exactly one cookie set; re-import replaces it")
    }
}

final class YtDlpFailureClassifierTests: XCTestCase {

    func testRateLimitedIsNeverTerminalAndWinsOverOtherPatterns() {
        // Even with an "unavailable" phrase present, the worker's
        // rate-limit check runs first and must win.
        let failure = YtDlpFailureClassifier.classify(
            "ERROR: This content isn't available, try again later. Video unavailable")
        XCTAssertEqual(failure?.kind, .rateLimited)
        XCTAssertEqual(failure?.isTerminal, false)

        let other = YtDlpFailureClassifier.classify(
            "ERROR: The account has been rate-limited by YouTube. Please try again later.")
        XCTAssertEqual(other?.kind, .rateLimited)
    }

    func testMembersOnly() {
        let failure = YtDlpFailureClassifier.classify(
            "ERROR: [youtube] abc: This video is members-only content")
        XCTAssertEqual(failure?.kind, .membersOnly)
        XCTAssertEqual(failure?.isTerminal, true)
        XCTAssertEqual(failure?.message, "この動画はメンバー限定コンテンツのため取得できません。")
        let join = YtDlpFailureClassifier.classify(
            "ERROR: Join this channel to get access to members-only content")
        XCTAssertNotNil(join)
    }

    func testDeletedPrivateCopyrightTerminatedDrm() {
        XCTAssertEqual(YtDlpFailureClassifier.classify(
            "ERROR: This video has been removed by the uploader")?.kind, .deleted)
        XCTAssertEqual(YtDlpFailureClassifier.classify(
            "ERROR: Private video. Sign in if you've been granted access to this video")?.kind, .private)
        XCTAssertEqual(YtDlpFailureClassifier.classify(
            "ERROR: This video is no longer available due to a copyright claim by X")?.kind, .copyrightRemoved)
        XCTAssertEqual(YtDlpFailureClassifier.classify(
            "ERROR: The account associated with this video has been terminated")?.kind, .accountTerminated)
        XCTAssertEqual(YtDlpFailureClassifier.classify(
            "ERROR: This video is drm protected and only images are available for download")?.kind, .drmProtected)
    }

    func testScheduledMessagesParseAmountAndUnit() {
        let live = YtDlpFailureClassifier.classify(
            "ERROR: This live event will begin in 3 hours.")
        XCTAssertEqual(live?.kind, .liveScheduled)
        XCTAssertEqual(live?.message, "このライブ配信は3時間後に開始される予約動画です。")
        XCTAssertEqual(live?.isTerminal, true)

        let premiere = YtDlpFailureClassifier.classify(
            "ERROR: Premieres in 2 days")
        XCTAssertEqual(premiere?.kind, .premiereScheduled)
        XCTAssertEqual(premiere?.message, "この動画は2日後にプレミア公開される予約動画です。")

        let minutes = YtDlpFailureClassifier.classify(
            "This live event will begin in 45 minutes.")
        XCTAssertEqual(minutes?.message, "このライブ配信は45分後に開始される予約動画です。")
    }

    func testUnavailableIsClassifiedButNotTerminal() {
        let failure = YtDlpFailureClassifier.classify(
            "ERROR: [youtube] qwYhKlY4Tx0: Video unavailable. This video is not available")
        XCTAssertEqual(failure?.kind, .unavailable)
        XCTAssertEqual(failure?.isTerminal, false)
    }

    func testUnclassifiedReturnsNil() {
        XCTAssertNil(YtDlpFailureClassifier.classify("ERROR: HTTP Error 403: Forbidden"))
        XCTAssertNil(YtDlpFailureClassifier.classify(""))
    }
}

final class TerminalFailureStoreTests: XCTestCase {

    private var fileURL: URL!
    private var store: TerminalFailureStore!
    private let videoID = "qwYhKlY4Tx0"
    /// Base time for the injected clocks. Must be ~now: the store's
    /// load filter (like the worker's) drops temporary records that
    /// are expired relative to the real clock when reading the file.
    private var t0: Date!

    override func setUp() async throws {
        t0 = Date()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-TerminalTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("terminal-failures.json")
        store = TerminalFailureStore(fileURL: fileURL)
    }

    override func tearDown() async throws {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    }

    private func failure(_ kind: ClassifiedYtDlpFailure.Kind, _ message: String) -> ClassifiedYtDlpFailure {
        ClassifiedYtDlpFailure(kind: kind, message: message)
    }

    func testMembersOnlyIsPermanent() {
        store.remember(videoID: videoID,
                       failure: failure(.membersOnly, "この動画はメンバー限定コンテンツのため取得できません。"),
                       now: t0)
        let farFuture = t0.addingTimeInterval(365 * 24 * 3600)
        let record = store.record(for: videoID, now: farFuture)
        XCTAssertNotNil(record, "members_only must never expire")
        XCTAssertTrue(record?.isPermanent ?? false)
        XCTAssertTrue(TerminalFailureStore.cachedMessage(for: record!)
            .contains("メンバー限定"))
    }

    func testTemporaryFailureExpiresAfter15Minutes() {
        store.remember(videoID: videoID,
                       failure: failure(.deleted, "この動画は削除されているため取得できません。"),
                       now: t0)
        XCTAssertNotNil(store.record(for: videoID, now: t0.addingTimeInterval(14 * 60)))
        XCTAssertNil(store.record(for: videoID, now: t0.addingTimeInterval(15 * 60 + 1)),
                     "temporary records expire 15 minutes after judgement")
        XCTAssertEqual(store.count, 0, "expired record is pruned")
    }

    func testUnavailableAndRateLimitedAreNeverStored() {
        store.remember(videoID: videoID,
                       failure: failure(.unavailable, "この動画は視聴できない状態のため取得できません。"),
                       now: t0)
        store.remember(videoID: videoID,
                       failure: failure(.rateLimited, "レート制限"),
                       now: t0)
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.record(for: videoID, now: t0))
    }

    func testInvalidVideoIDsAreRefused() {
        store.remember(videoID: "too-short",
                       failure: failure(.membersOnly, "x"), now: t0)
        store.remember(videoID: "waytoolongvideoid123",
                       failure: failure(.membersOnly, "x"), now: t0)
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.record(for: "not an id", now: t0))
    }

    func testPersistenceAcrossInstances() {
        store.remember(videoID: videoID,
                       failure: failure(.private, "この動画は非公開のため取得できません。"),
                       now: t0)
        let reloaded = TerminalFailureStore(fileURL: fileURL)
        let record = reloaded.record(for: videoID, now: t0.addingTimeInterval(60))
        XCTAssertEqual(record?.code, "private")
        XCTAssertEqual(record?.message, "この動画は非公開のため取得できません。")
    }
}

final class FormatURLExpiryTests: XCTestCase {

    func testParsesExpireParameter() {
        let url = "https://rr1---sn-example.googlevideo.com/videoplayback?expire=1893456000&id=abc"
        XCTAssertEqual(FormatURLExpiry.expirationDate(of: url),
                       Date(timeIntervalSince1970: 1_893_456_000))
        XCTAssertEqual(FormatURLExpiry.usableUntil(of: url),
                       Date(timeIntervalSince1970: 1_893_456_000 - 60))
    }

    func testMissingOrInvalidExpireIsNeverStale() {
        XCTAssertNil(FormatURLExpiry.expirationDate(of: "https://example.com/file.mp4"))
        XCTAssertNil(FormatURLExpiry.expirationDate(of: nil))
        XCTAssertNil(FormatURLExpiry.expirationDate(of: "https://x/?expire=abc"))
        XCTAssertFalse(FormatURLExpiry.isStale("https://example.com/file.mp4"))
        XCTAssertFalse(FormatURLExpiry.isStale(nil))
    }

    func testStaleWithinSafetyMargin() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let soon = "https://x/videoplayback?expire=\(Int(now.timeIntervalSince1970) + 30)"
        XCTAssertTrue(FormatURLExpiry.isStale(soon, now: now),
                      "expiring inside the 60s margin counts as stale (worker rule)")
        let later = "https://x/videoplayback?expire=\(Int(now.timeIntervalSince1970) + 3600)"
        XCTAssertFalse(FormatURLExpiry.isStale(later, now: now))
        let past = "https://x/videoplayback?expire=\(Int(now.timeIntervalSince1970) - 10)"
        XCTAssertTrue(FormatURLExpiry.isStale(past, now: now))
    }

    func testOptionStalenessUsesPlumbedExpiry() {
        var option = MediaFormatOption(
            id: "x", container: "mp4", fileExtension: "mp4", mimeType: nil,
            displayName: "MP4", isVideo: true, isAudio: false, qualityLabel: "720p")
        XCTAssertFalse(option.isStale())
        option.urlExpiresAt = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(option.isStale(now: Date(timeIntervalSince1970: 1_700_000_100)))
        XCTAssertFalse(option.isStale(now: Date(timeIntervalSince1970: 1_699_999_000)))
    }
}

final class PotProviderSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: PotProviderSettings!

    override func setUp() async throws {
        suiteName = "VYRA-PotTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = PotProviderSettings(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
    }

    func testDefaultIsOnDevice() {
        // Nothing stored: the default is on-device minting (hard
        // budget + fail-open makes it safe to default on). The server
        // URL stays gated to server mode.
        XCTAssertEqual(settings.mode, .onDevice)
        XCTAssertTrue(settings.onDeviceEnabled)
        XCTAssertNil(settings.activeBaseURL)
        XCTAssertFalse(settings.hasInvalidBaseURLText)
    }

    func testValidURLBecomesActiveOnlyInServerMode() {
        settings.baseURLString = "http://192.168.1.10:4416"
        settings.mode = .off
        XCTAssertNil(settings.activeBaseURL, "off mode must gate the URL")
        settings.mode = .onDevice
        XCTAssertNil(settings.activeBaseURL, "on-device mode must gate the URL")
        XCTAssertTrue(settings.onDeviceEnabled)
        settings.mode = .server
        XCTAssertEqual(settings.activeBaseURL?.absoluteString, "http://192.168.1.10:4416")
        XCTAssertFalse(settings.onDeviceEnabled)
    }

    func testLegacyEnabledToggleMigratesToServerMode() {
        // The pre-mode UI stored a bare toggle (vyra.pot.enabled);
        // an enabled legacy install must come up in server mode.
        defaults.set(true, forKey: PotProviderSettings.enabledDefaultsKey)
        XCTAssertEqual(settings.mode, .server)
        settings.baseURLString = "http://192.168.1.10:4416"
        XCTAssertEqual(settings.activeBaseURL?.absoluteString, "http://192.168.1.10:4416")
        // An explicit mode choice wins over the legacy toggle.
        settings.mode = .off
        XCTAssertEqual(settings.mode, .off)
        XCTAssertNil(settings.activeBaseURL)
    }

    func testInvalidTextIsFlaggedNotUsed() {
        settings.mode = .server
        settings.baseURLString = "not a url"
        XCTAssertNil(settings.activeBaseURL)
        XCTAssertTrue(settings.hasInvalidBaseURLText)
        settings.baseURLString = "ftp://example.com:4416"
        XCTAssertNil(settings.activeBaseURL)
        XCTAssertTrue(settings.hasInvalidBaseURLText)
    }
}

final class RawOutputStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-RawTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testSaveWritesHeaderAndBody() {
        let url = RawOutputStore.save(
            rawJSON: "{\"formats\": []}",
            url: "https://www.youtube.com/watch?v=abc",
            directory: directory,
            date: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNotNil(url)
        let text = RawOutputStore.latestText(in: directory) ?? ""
        XCTAssertTrue(text.hasPrefix("// VYRA yt-dlp raw output"))
        XCTAssertTrue(text.contains("// url: https://www.youtube.com/watch?v=abc"))
        XCTAssertTrue(text.contains("{\"formats\": []}"))
    }

    func testRotationKeepsNewestThree() {
        for i in 0..<5 {
            RawOutputStore.save(
                rawJSON: "{\"n\": \(i)}",
                url: "https://example.com/\(i)",
                directory: directory,
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 2)))
        }
        XCTAssertEqual(RawOutputStore.sessionFiles(in: directory).count,
                       RawOutputStore.maxSessions)
        let latest = RawOutputStore.latestText(in: directory) ?? ""
        XCTAssertTrue(latest.contains("\"n\": 4"), "latest must be the newest save: \(latest)")
    }

    func testLatestInfoParsesHeader() {
        RawOutputStore.save(
            rawJSON: "{}",
            url: "https://m.youtube.com/watch?v=qwYhKlY4Tx0",
            directory: directory,
            date: Date(timeIntervalSince1970: 1_700_000_000))
        let info = RawOutputStore.latestInfo(in: directory)
        XCTAssertEqual(info?.url, "https://m.youtube.com/watch?v=qwYhKlY4Tx0")
        XCTAssertNotNil(info?.time)
    }

    func testEmptyStoreReportsNothing() {
        XCTAssertNil(RawOutputStore.latestFileURL(in: directory))
        XCTAssertNil(RawOutputStore.latestText(in: directory))
        XCTAssertNil(RawOutputStore.latestInfo(in: directory))
    }
}

final class BridgeRawInfoDecodingTests: XCTestCase {

    func testExtractResponseDecodesRawInfo() throws {
        let json = """
            {"ok": true, "metadata": null, "raw_info": "{\\"formats\\": [{\\"format_id\\": \\"18\\"}]}"}
            """
        let response = try BridgeResponse.decode(json)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.rawInfo, "{\"formats\": [{\"format_id\": \"18\"}]}")
    }

    func testOptsProbeResponseDecodes() throws {
        let json = """
            {"ok": true, "has_cookiefile": true, "cookiefile": "/tmp/cookies.txt",
             "pot_bgutil_base_url": "http://192.168.1.10:4416", "pot_ondevice_settings": true,
             "pot_plugin_available": false, "pot_ondevice_registered": true,
             "pot_events": ["INFO: on-device mint ok (gvs/visitor_data)"]}
            """
        let response = try BridgeResponse.decode(json)
        XCTAssertEqual(response.hasCookiefile, true)
        XCTAssertEqual(response.cookiefile, "/tmp/cookies.txt")
        XCTAssertEqual(response.potBgutilBaseURL, "http://192.168.1.10:4416")
        XCTAssertEqual(response.potOndeviceSettings, true)
        XCTAssertEqual(response.potPluginAvailable, false)
        XCTAssertEqual(response.potOndeviceRegistered, true)
        XCTAssertEqual(response.potEvents, ["INFO: on-device mint ok (gvs/visitor_data)"])
    }
}
