import Foundation

/// Where completed downloads are saved (Settings > 保存先).
enum SaveDestination: Equatable {
    /// The app folder (Documents/VYRA) — the default, and the
    /// fallback whenever an external folder cannot be used.
    case appFolder
    /// A user-chosen folder (Files / external volume) whose
    /// security-scoped bookmark resolves.
    case external(folderName: String)
    /// A folder was chosen but its bookmark no longer resolves
    /// (folder moved/deleted, volume unmounted). Downloads fall back
    /// to the app folder, and Settings shows this state honestly
    /// instead of silently pretending the folder still works.
    case externalUnavailable(folderName: String)
}

/// Persists the user's save-destination choice as a security-scoped
/// bookmark in UserDefaults and resolves it on demand.
final class SaveDestinationStore: @unchecked Sendable {
    static let shared = SaveDestinationStore()

    static let bookmarkDefaultsKey = "vyra.saveDestination.bookmark"
    static let nameDefaultsKey = "vyra.saveDestination.folderName"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether any external folder is currently chosen (usable or not).
    var hasExternalFolder: Bool { defaults.data(forKey: Self.bookmarkDefaultsKey) != nil }

    var storedFolderName: String? { defaults.string(forKey: Self.nameDefaultsKey) }

    /// Stores a bookmark for a folder picked with the document
    /// picker. Must be called while the picker's security-scoped
    /// access is active (the caller starts/stops it).
    func setExternalFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: Self.bookmarkDefaultsKey)
        defaults.set(url.lastPathComponent, forKey: Self.nameDefaultsKey)
    }

    func resetToAppFolder() {
        defaults.removeObject(forKey: Self.bookmarkDefaultsKey)
        defaults.removeObject(forKey: Self.nameDefaultsKey)
    }

    func currentDestination() -> SaveDestination {
        guard let data = defaults.data(forKey: Self.bookmarkDefaultsKey) else {
            return .appFolder
        }
        let name = storedFolderName ?? "外部フォルダ"
        return resolve(data: data) != nil
            ? .external(folderName: name)
            : .externalUnavailable(folderName: name)
    }

    /// Japanese one-line description for Settings / confirmation UI.
    var displayText: String {
        switch currentDestination() {
        case .appFolder:
            return "アプリ内フォルダ（Documents/VYRA）"
        case .external(let name):
            return "外部フォルダ「\(name)」"
        case .externalUnavailable(let name):
            return "外部フォルダ「\(name)」にアクセスできません（アプリ内フォルダに保存します）"
        }
    }

    /// Resolves the stored bookmark without starting access.
    private func resolve(data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Handle for one save operation into the chosen folder.
    struct FolderAccess {
        let url: URL
        fileprivate let store: SaveDestinationStore

        func end() {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Starts security-scoped access to the chosen folder. Returns
    /// nil when no folder is chosen or the bookmark is unusable —
    /// the caller then falls back to the app folder. A stale bookmark
    /// is refreshed in place while access works.
    func beginFolderAccess() -> FolderAccess? {
        guard let data = defaults.data(forKey: Self.bookmarkDefaultsKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        if stale, let refreshed = try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(refreshed, forKey: Self.bookmarkDefaultsKey)
        }
        return FolderAccess(url: url, store: self)
    }
}

/// Resolves per-file bookmarks of downloads saved into an external
/// folder and holds their security-scoped access open, so AVKit
/// playback, ShareLink and deletion keep working for those files.
/// Access is retained per file until `stopAccess` (on deletion) or
/// app termination — the standard pragmatic approach for a small
/// personal library.
final class ExternalFileAccess: @unchecked Sendable {
    static let shared = ExternalFileAccess()

    private let lock = NSLock()
    private var startedURLs: [String: URL] = [:]

    private init() {}

    /// Creates a bookmark for a file inside a folder the caller
    /// currently has security-scoped access to.
    static func bookmark(forFileAt url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a file bookmark and starts (once) its security-scoped
    /// access. Returns nil when the bookmark is unusable.
    func url(forBookmarkData data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        if startedURLs[url.path] == nil {
            guard url.startAccessingSecurityScopedResource() else { return nil }
            startedURLs[url.path] = url
        }
        return url
    }

    func stopAccess(forBookmarkData data: Data) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if let started = startedURLs.removeValue(forKey: url.path) {
            started.stopAccessingSecurityScopedResource()
        }
    }
}
