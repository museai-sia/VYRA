import Foundation

/// Per-video terminal-failure memory, mirroring worker.js's
/// `yt-dlp-terminal-failures.json`:
///
/// - `members_only` records are PERMANENT.
/// - Every other terminal code expires 15 minutes after it was
///   recorded; until then, extraction for that video fails fast with
///   the recorded message instead of running yt-dlp again.
/// - `unavailable` and rate-limit failures are NEVER stored here
///   (the classifier marks them non-terminal; the store also refuses
///   them defensively).
///
/// Persisted as one JSON file in Application Support. Only video IDs
/// passing the strict 11-character validation (the same rule as
/// `URLValidationService.isValidVideoID`, i.e. the worker's
/// `/^[a-zA-Z0-9_-]{11}$/`) are ever used as keys.
final class TerminalFailureStore: @unchecked Sendable {
    static let shared = TerminalFailureStore()

    static let temporaryTTL: TimeInterval = 15 * 60

    struct Record: Codable, Equatable, Sendable {
        var code: String
        var message: String
        var recordedAt: Date
        /// nil = permanent (members_only).
        var expiresAt: Date?

        var isPermanent: Bool { expiresAt == nil }

        func isExpired(now: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= now
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [String: Record]?

    init(fileURL: URL = TerminalFailureStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VYRA/terminal-failures.json")
    }

    /// The worker's cache-hit explanation, appended to the recorded
    /// message when a lookup short-circuits an extraction, so the
    /// user can tell this failure did not come from a fresh yt-dlp
    /// run. (Worker wording: temporary records exclude the ID for 15
    /// minutes from judgement; members_only is remembered for good.)
    static func cachedMessage(for record: Record) -> String {
        if record.isPermanent {
            return record.message + "（前回の判定でメンバー限定と記録されているため、yt-dlpを実行せずに返しています）"
        }
        return record.message + "（前回の判定から15分間は yt-dlp を実行せずに返しています）"
    }

    /// The unexpired record for a video, or nil. Expired records are
    /// pruned (and the file rewritten) on lookup, like the worker.
    func record(for videoID: String, now: Date = Date()) -> Record? {
        guard URLValidationService.isValidVideoID(videoID) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        guard let record = cache?[videoID] else { return nil }
        if record.isExpired(now: now) {
            cache?[videoID] = nil
            saveLocked()
            return nil
        }
        return record
    }

    /// Remembers a terminal failure. Non-terminal classifications
    /// (unavailable / rate-limited) and invalid IDs are refused.
    func remember(videoID: String, failure: ClassifiedYtDlpFailure, now: Date = Date()) {
        guard failure.isTerminal,
              URLValidationService.isValidVideoID(videoID) else { return }
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        let permanent = failure.kind == .membersOnly
        cache?[videoID] = Record(
            code: failure.code,
            message: failure.message,
            recordedAt: now,
            expiresAt: permanent ? nil : now.addingTimeInterval(Self.temporaryTTL))
        saveLocked()
    }

    /// Number of stored records (diagnostics/tests).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        return cache?.count ?? 0
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        cache = [:]
        saveLocked()
    }

    // MARK: - Persistence (worker-style: whole-file JSON, atomic-ish)

    private func loadLocked() {
        guard cache == nil else { return }
        cache = [:]
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder.decode([String: Record].self, from: data)
        else { return }
        // Mirror the worker's load filter: valid IDs only, and
        // temporary records that already expired are dropped.
        let now = Date()
        cache = decoded.filter { videoID, record in
            URLValidationService.isValidVideoID(videoID) && !record.isExpired(now: now)
        }
    }

    private func saveLocked() {
        guard let cache else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(cache)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Caching must never take extraction down with it.
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
