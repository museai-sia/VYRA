import Foundation

/// Persistent, shareable debug logs for the yt-dlp engine.
///
/// The Python bridge captures the real exception and the last yt-dlp
/// log lines for every failed job, but before this store existed the
/// Swift side dropped them and the UI could only show a generic
/// message. Every engine failure (extraction or download) is now
/// appended here as a timestamped session file under
/// Application Support/VYRA/logs/, keeping the newest few sessions.
/// Settings > エンジン shows the latest one and offers it as a
/// ShareLink so a failure on device can always be diagnosed.
enum DebugLogStore {
    static let maxSessions = 5

    private static let lock = NSLock()

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VYRA/logs", isDirectory: true)
    }

    /// Writes one failure session file and prunes older ones.
    /// Returns the written file's URL, or nil when the write failed
    /// (logging must never take the app down with it).
    @discardableResult
    static func appendSession(kind: String,
                              url: String?,
                              formatID: String?,
                              error: String,
                              log: [String],
                              traceback: String?,
                              directory: URL = DebugLogStore.defaultDirectory,
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
                "ytdlp-\(formatter.string(from: date))-\(kind).log")
            var lines: [String] = [
                "VYRA yt-dlp debug log",
                "time: \(ISO8601DateFormatter().string(from: date))",
                "kind: \(kind)",
                "url: \(url ?? "-")",
                "format_id: \(formatID ?? "-")",
                "error: \(error)",
                "",
                "--- yt-dlp log (tail) ---",
            ]
            lines.append(contentsOf: log)
            if let traceback, !traceback.isEmpty {
                lines.append("")
                lines.append("--- traceback ---")
                lines.append(traceback)
            }
            try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            prune(in: directory, keeping: maxSessions)
            return fileURL
        } catch {
            return nil
        }
    }

    static func sessionFiles(in directory: URL = DebugLogStore.defaultDirectory) -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("ytdlp-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func latestLogURL(in directory: URL = DebugLogStore.defaultDirectory) -> URL? {
        sessionFiles(in: directory).last
    }

    static func latestLogText(in directory: URL = DebugLogStore.defaultDirectory) -> String? {
        guard let url = latestLogURL(in: directory) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func prune(in directory: URL, keeping count: Int) {
        let files = sessionFiles(in: directory)
        guard files.count > count else { return }
        for file in files.prefix(files.count - count) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
