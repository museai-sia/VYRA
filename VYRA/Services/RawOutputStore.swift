import Foundation

/// Persistent store for yt-dlp's raw extraction output (the full
/// info JSON, formats array included), viewable and shareable from
/// Settings > yt-dlp生出力.
///
/// Why this exists: format availability is entirely session-dependent
/// (PO tokens, SABR, bot flags), so when the app offers few formats
/// the only way to know what YouTube actually returned is to look at
/// the unprocessed extractor output. Every successful metadata
/// extraction saves its raw JSON here, keeping the newest few under
/// Application Support/VYRA/raw/. The content is the user's own
/// session data on their own device — the same exposure level as the
/// debug logs — and it is never sent anywhere by the app itself.
enum RawOutputStore {
    static let maxSessions = 3

    private static let lock = NSLock()

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VYRA/raw", isDirectory: true)
    }

    /// The two header lines written ahead of the JSON body, so a
    /// shared file still says which URL it came from and when.
    static func header(url: String, date: Date) -> String {
        "// VYRA yt-dlp raw output\n"
            + "// url: \(url)\n"
            + "// time: \(ISO8601DateFormatter().string(from: date))\n"
    }

    /// Writes one extraction's raw JSON and prunes older files.
    /// Returns the written file's URL, or nil when the write failed
    /// (diagnostics must never take the app down with them).
    @discardableResult
    static func save(rawJSON: String,
                     url: String,
                     directory: URL = RawOutputStore.defaultDirectory,
                     date: Date = Date()) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let fileURL = directory.appendingPathComponent(
                "raw-\(formatter.string(from: date)).json")
            try (header(url: url, date: date) + rawJSON)
                .write(to: fileURL, atomically: true, encoding: .utf8)
            prune(in: directory, keeping: maxSessions)
            return fileURL
        } catch {
            return nil
        }
    }

    static func sessionFiles(in directory: URL = RawOutputStore.defaultDirectory) -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("raw-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func latestFileURL(in directory: URL = RawOutputStore.defaultDirectory) -> URL? {
        sessionFiles(in: directory).last
    }

    static func latestText(in directory: URL = RawOutputStore.defaultDirectory) -> String? {
        guard let url = latestFileURL(in: directory) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// URL + timestamp of the newest stored extraction, parsed back
    /// out of the file header for the viewer screen.
    static func latestInfo(in directory: URL = RawOutputStore.defaultDirectory)
        -> (url: String, time: String)? {
        guard let text = latestText(in: directory) else { return nil }
        var url: String?
        var time: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(3) {
            if line.hasPrefix("// url: ") { url = String(line.dropFirst("// url: ".count)) }
            if line.hasPrefix("// time: ") { time = String(line.dropFirst("// time: ".count)) }
        }
        guard let url, let time else { return nil }
        return (url, time)
    }

    private static func prune(in directory: URL, keeping count: Int) {
        let files = sessionFiles(in: directory)
        guard files.count > count else { return }
        for file in files.prefix(files.count - count) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
