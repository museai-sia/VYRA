import Foundation

/// Optional user-supplied cookies for yt-dlp (Settings > Cookie).
///
/// Strictly optional: with no cookie file imported (or the toggle
/// off), the engine behaves exactly as it did before this feature.
/// When enabled, the bridge passes the file to yt-dlp as its
/// `cookiefile`, so extractions and downloads run as the user's
/// logged-in session — which can also restore format availability
/// that anonymous sessions lose to SABR / bot checks.
///
/// Sensitivity rules (do not weaken):
/// - The file lives only in the app sandbox
///   (Application Support/VYRA/cookies/cookies.txt), protected with
///   FileProtectionType.completeUnlessOpen.
/// - Cookie values are NEVER read into logs, the raw-output store,
///   error messages, or any share sheet. The only thing the app ever
///   derives from the contents is the entry COUNT (names/values are
///   not parsed out, displayed, or persisted anywhere else).
/// - There is deliberately no export/share UI for the cookie file.
/// - yt-dlp may rewrite the file in place with refreshed cookies;
///   that is expected, so the store path is stable.
final class CookieStore: @unchecked Sendable {
    static let shared = CookieStore()

    static let enabledDefaultsKey = "vyra.cookies.enabled"
    static let fileNameDefaultsKey = "vyra.cookies.fileName"
    static let importedAtDefaultsKey = "vyra.cookies.importedAt"

    enum ImportError: Error, Equatable {
        case emptyFile
        case notNetscapeFormat
        case unreadable

        var userMessage: String {
            switch self {
            case .emptyFile:
                return "ファイルが空です。cookies.txt を選び直してください。"
            case .notNetscapeFormat:
                return "Netscape形式の cookies.txt として認識できませんでした。ブラウザの拡張機能などで書き出したファイルを選んでください。"
            case .unreadable:
                return "ファイルを読み込めませんでした。"
            }
        }
    }

    struct Status: Equatable {
        var fileName: String
        var importedAt: Date
        var entryCount: Int
        var isEnabled: Bool
    }

    private let defaults: UserDefaults
    private let directory: URL

    init(defaults: UserDefaults = .standard, directory: URL = CookieStore.defaultDirectory) {
        self.defaults = defaults
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VYRA/cookies", isDirectory: true)
    }

    var cookieFileURL: URL { directory.appendingPathComponent("cookies.txt") }

    var hasCookieFile: Bool {
        FileManager.default.fileExists(atPath: cookieFileURL.path)
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledDefaultsKey) }
        set { defaults.set(newValue, forKey: Self.enabledDefaultsKey) }
    }

    /// The path the engine hands to the bridge, or nil when cookies
    /// must not be used (not imported, or toggle off). This single
    /// gate is what every engine call goes through.
    func activeCookieFileURL() -> URL? {
        guard isEnabled, hasCookieFile else { return nil }
        return cookieFileURL
    }

    /// Current state for Settings, or nil when nothing is imported.
    /// The entry count is recomputed from the file on demand (yt-dlp
    /// may have refreshed it); contents are otherwise untouched.
    var status: Status? {
        guard hasCookieFile,
              let fileName = defaults.string(forKey: Self.fileNameDefaultsKey) else { return nil }
        let importedAt = Date(timeIntervalSince1970:
            defaults.double(forKey: Self.importedAtDefaultsKey))
        let count = (try? String(contentsOf: cookieFileURL, encoding: .utf8))
            .flatMap(Self.entryCount(in:)) ?? 0
        return Status(fileName: fileName, importedAt: importedAt,
                      entryCount: count, isEnabled: isEnabled)
    }

    /// Validates Netscape cookie-file text and counts its entries.
    /// A line counts when it has the 7 tab-separated cookie fields;
    /// `#HttpOnly_` lines are cookie lines too. Comment and blank
    /// lines are skipped. Returns nil when the text is not plausibly
    /// a cookies.txt at all.
    static func entryCount(in text: String) -> Int? {
        var count = 0
        var sawHeader = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("# Netscape HTTP Cookie File") {
                sawHeader = true
                continue
            }
            let candidate = line.hasPrefix("#HttpOnly_")
                ? String(line.dropFirst("#HttpOnly_".count)) : line
            if candidate.hasPrefix("#") { continue }
            if candidate.components(separatedBy: "\t").count >= 7 {
                count += 1
            }
        }
        // Plausible = the standard header, or at least one well-formed
        // cookie line. Anything else is rejected rather than stored.
        guard sawHeader || count > 0 else { return nil }
        return count
    }

    /// Imports a picked cookies.txt: validates it, then copies it
    /// into the store (the picker URL is security-scoped; the caller
    /// starts/stops access around this call, like the save-folder
    /// flow). On any validation failure nothing is stored and the
    /// previous state is kept. New imports start out enabled.
    @discardableResult
    func importCookies(from pickedURL: URL, date: Date = Date()) throws -> Status {
        let data: Data
        do {
            data = try Data(contentsOf: pickedURL)
        } catch {
            throw ImportError.unreadable
        }
        guard !data.isEmpty else { throw ImportError.emptyFile }
        guard let text = String(data: data, encoding: .utf8),
              Self.entryCount(in: text) != nil else {
            throw ImportError.notNetscapeFormat
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: cookieFileURL, options: [.atomic])
            // Sensitive file: keep it out of reach while the device
            // is locked. Best-effort — some environments (simulator)
            // do not support protection classes.
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                  ofItemAtPath: cookieFileURL.path)
        } catch {
            throw ImportError.unreadable
        }
        defaults.set(pickedURL.lastPathComponent, forKey: Self.fileNameDefaultsKey)
        defaults.set(date.timeIntervalSince1970, forKey: Self.importedAtDefaultsKey)
        isEnabled = true
        guard let status else { throw ImportError.unreadable }
        return status
    }

    /// Removes the cookie file and its metadata (Settings > 削除）.
    func deleteCookies() {
        try? FileManager.default.removeItem(at: cookieFileURL)
        defaults.removeObject(forKey: Self.fileNameDefaultsKey)
        defaults.removeObject(forKey: Self.importedAtDefaultsKey)
        isEnabled = false
    }
}
