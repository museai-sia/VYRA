import Foundation
import Observation
import SwiftData

/// Library state (Phase 3, spec §13/§14). Backed by SwiftData
/// (`DownloadItem`) plus `FileStorageService` for the actual files.
/// Without an attached ModelContext it behaves as a plain in-memory list
/// (used by previews and unit tests).
@MainActor
@Observable
final class LibraryViewModel {
    private(set) var items: [DownloadItem] = []
    let storage: FileStorageService
    private var modelContext: ModelContext?

    init(storage: FileStorageService = .appDefault) {
        self.storage = storage
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.fileSizeBytes } }
    /// Phase 1/2 name kept for compatibility.
    var totalMockBytes: Int64 { totalBytes }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    // MARK: - Persistence (SwiftData)

    /// Attaches the app's ModelContext and restores the Library,
    /// repairing inconsistencies (spec §14): records whose file is gone
    /// are removed; interrupted downloads are marked failed, never shown
    /// as completed.
    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        restore()
    }

    func restore() {
        guard let modelContext else { return }
        storage.cleanupTemporaryDownloads()
        let descriptor = FetchDescriptor<DownloadItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
        var valid: [DownloadItem] = []
        for item in fetched {
            if item.state == .downloading || item.state == .preparing || item.state == .queued {
                // Interrupted by app termination: honest failure, and not a
                // Library entry (no complete file exists).
                item.state = .failed
                item.errorMessage = "アプリ終了によりダウンロードが中断されました。"
                modelContext.delete(item)
                continue
            }
            guard item.state == .completed else { continue }
            if item.externalBookmarkData != nil {
                // File in a user-chosen external folder: valid only
                // while its bookmark resolves to an existing file.
                if let url = resolvedFileURL(for: item) {
                    if let actual = storage.fileSize(at: url) {
                        item.fileSizeBytes = actual
                    }
                    valid.append(item)
                } else {
                    // Same orphan repair as a missing in-app file.
                    modelContext.delete(item)
                }
            } else if let relativePath = item.localFileRelativePath {
                if storage.fileExists(relativePath: relativePath) {
                    if let actual = storage.fileSize(relativePath: relativePath) {
                        item.fileSizeBytes = actual
                    }
                    valid.append(item)
                } else {
                    // Record without a file: repair by removing it.
                    modelContext.delete(item)
                }
            } else {
                // Legacy Phase 1/2 mock record (no file): keep it visible
                // only in-memory; it has no persisted file to verify.
                valid.append(item)
            }
        }
        try? modelContext.save()
        items = valid.sorted { $0.createdAt > $1.createdAt }
    }

    /// Persists a completed download (file already moved into the Library
    /// directory by the download manager) and shows it at the top.
    func registerCompleted(_ item: DownloadItem) {
        guard item.state == .completed else { return }
        if let modelContext, item.modelContext == nil {
            modelContext.insert(item)
            try? modelContext.save()
        }
        add(item)
    }

    // MARK: - List operations

    func add(_ item: DownloadItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.insert(item, at: 0)
        items.sort { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func addMockItem() -> DownloadItem {
        let item = DownloadItem.mockItem()
        add(item)
        return item
    }

    /// Deletes the record AND its file, keeping both in sync (spec §13).
    func delete(_ item: DownloadItem) {
        if let bookmarkData = item.externalBookmarkData {
            if let url = ExternalFileAccess.shared.url(forBookmarkData: bookmarkData) {
                try? FileManager.default.removeItem(at: url)
            }
            ExternalFileAccess.shared.stopAccess(forBookmarkData: bookmarkData)
        } else if let relativePath = item.localFileRelativePath {
            try? storage.deleteFile(relativePath: relativePath)
        }
        if let modelContext, item.modelContext != nil {
            modelContext.delete(item)
            try? modelContext.save()
        }
        items.removeAll { $0.id == item.id }
    }

    func delete(at offsets: IndexSet) {
        let targets = offsets.map { items[$0] }
        for target in targets { delete(target) }
    }

    func clearAll() {
        for item in items { delete(item) }
        items.removeAll()
    }

    // MARK: - Playback / sharing

    /// The item's file URL wherever it lives — the app folder (via
    /// its Documents-relative path) or a user-chosen external folder
    /// (via its per-file bookmark, with security-scoped access held
    /// by ExternalFileAccess) — only when the file actually exists.
    func resolvedFileURL(for item: DownloadItem) -> URL? {
        if let bookmarkData = item.externalBookmarkData {
            guard let url = ExternalFileAccess.shared.url(forBookmarkData: bookmarkData),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        guard let relativePath = item.localFileRelativePath,
              storage.fileExists(relativePath: relativePath) else { return nil }
        return storage.url(forRelativePath: relativePath)
    }

    /// Local file URL for playback, only when the file exists and the
    /// format is playable by AVKit.
    func playableURL(for item: DownloadItem) -> URL? {
        guard item.isPlayableFormat else { return nil }
        return resolvedFileURL(for: item)
    }

    func isPlayable(_ item: DownloadItem) -> Bool { playableURL(for: item) != nil }

    /// Local file URL for the share sheet, only when the file exists.
    func shareURL(for item: DownloadItem) -> URL? {
        resolvedFileURL(for: item)
    }
}
