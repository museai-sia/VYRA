import Foundation
import Observation
import os

/// Concrete download task manager (Phase 3, spec §9). Owns task state,
/// progress, cancellation, retry and the hand-off to storage + Library.
///
/// Naming note: Phase 2 declared a `DownloadManager` *protocol* as a
/// capability-evaluation placeholder in DownloadCapability.swift. That
/// protocol is now `DownloadCapabilityEvaluating`; this concrete class is
/// the real download manager the spec asks for.
@MainActor
@Observable
final class DownloadTaskManager {
    private let logger = Logger(subsystem: "com.siatube.vyra", category: "download-manager")

    let engine: any DownloadService
    let storage: FileStorageService
    /// Called on the main actor with the completed item after its file has
    /// been moved into the Library directory. The Library layer persists it.
    var onCompleted: ((DownloadItem) -> Void)?

    private(set) var progresses: [UUID: DownloadProgress] = [:]
    private(set) var errors: [UUID: DownloadError] = [:]
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var requests: [UUID: DownloadRequest] = [:]

    init(engine: any DownloadService = URLSessionDownloadEngine(),
         storage: FileStorageService = .appDefault,
         onCompleted: ((DownloadItem) -> Void)? = nil) {
        self.engine = engine
        self.storage = storage
        self.onCompleted = onCompleted
    }

    func progress(for itemID: UUID) -> DownloadProgress? { progresses[itemID] }
    func isRunning(_ itemID: UUID) -> Bool { runningTasks[itemID] != nil }

    // MARK: - Start

    /// Starts a download for `item` from an already-resolved direct file
    /// URL. Returns false (and records an error) when the state transition
    /// is illegal. Resolution failures are surfaced via `fail(item:...)`
    /// by the caller using `startResolved`.
    @discardableResult
    func start(item: DownloadItem, sourceURL: URL, fileName: String) -> Bool {
        switch DirectMediaResolver.resolve(sourceURL: sourceURL, format: item.format) {
        case .downloadable(let url, _):
            return startResolved(item: item, directURL: url, fileName: fileName)
        case .unavailable(let reason):
            let error = DownloadError.permissionNotVerified(reason: reason)
            if item.transition(to: .failed) {
                item.errorMessage = error.userMessage
            }
            errors[item.id] = error
            logger.error("download refused: \(error.developerDescription, privacy: .public)")
            return false
        }
    }

    /// Starts a download from a URL already known to be a direct file URL
    /// (used by the stub-engine tests and by `start` after resolution).
    @discardableResult
    func startResolved(item: DownloadItem, directURL: URL, fileName: String) -> Bool {
        guard runningTasks[item.id] == nil else { return false }
        if item.state == .waiting || item.state == .failed || item.state == .cancelled {
            guard item.transition(to: .queued) else { return false }
        }
        guard item.state == .queued else { return false }
        errors[item.id] = nil
        item.errorMessage = nil
        let request = DownloadRequest(taskID: item.id, sourceURL: directURL, fileName: fileName)
        requests[item.id] = request
        progresses[item.id] = DownloadProgress.initial(state: .queued)

        let engine = self.engine
        let storage = self.storage
        runningTasks[item.id] = Task { [weak self] in
            guard let self else { return }
            if item.transition(to: .preparing) {
                self.progresses[item.id]?.state = .preparing
            }
            do {
                let tempURL = try await engine.download(request: request) { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if item.state == .preparing { item.transition(to: .downloading) }
                        var merged = snapshot
                        merged.state = item.state
                        self.progresses[item.id] = merged
                        item.downloadedBytes = snapshot.downloadedBytes
                    }
                }
                // Success: move into the Library directory, then register.
                let moved = try storage.moveIntoLibrary(tempFileURL: tempURL, desiredFileName: fileName)
                let actualSize = storage.fileSize(at: moved.url) ?? 0
                guard actualSize > 0 else {
                    storage.deleteTemporaryFile(at: moved.url)
                    throw DownloadError.integrityFailed(reason: "downloaded file is empty")
                }
                item.fileName = moved.url.lastPathComponent
                item.localFileRelativePath = moved.relativePath
                item.fileSizeBytes = actualSize
                item.downloadedBytes = actualSize
                item.mimeType = MediaFormatOption.mimeType(forExtension: item.format.fileExtension)
                // A very fast engine may finish before the first progress
                // callback moved the item out of .preparing.
                if item.state == .preparing { item.transition(to: .downloading) }
                guard item.transition(to: .completed) else {
                    throw DownloadError.invalidStateTransition
                }
                self.progresses[item.id] = DownloadProgress(
                    downloadedBytes: actualSize, totalBytes: actualSize, state: .completed)
                self.onCompleted?(item)
            } catch {
                let downloadError = DownloadError.from(error)
                if downloadError == .cancelled {
                    if item.transition(to: .cancelled) {
                        self.progresses[item.id]?.state = .cancelled
                    }
                } else {
                    if item.transition(to: .failed) {
                        item.errorMessage = downloadError.userMessage
                        self.progresses[item.id]?.state = .failed
                    }
                    self.errors[item.id] = downloadError
                    self.logger.error("download failed: \(downloadError.developerDescription, privacy: .public)")
                }
            }
            self.runningTasks[item.id] = nil
        }
        return true
    }

    // MARK: - Cancel

    func cancel(item: DownloadItem) {
        guard let task = runningTasks[item.id] else {
            // Not running: only a queued/preparing item can be cancelled.
            if item.state == .queued || item.state == .preparing || item.state == .waiting {
                item.transition(to: .cancelled)
                progresses[item.id]?.state = .cancelled
            }
            return
        }
        let engine = self.engine
        let taskID = item.id
        Task { await engine.cancel(taskID: taskID) }
        task.cancel()
        // The engine surfaces cancellation as an error, which transitions
        // the item to .cancelled and cleans up; no Library entry is made.
    }

    // MARK: - Retry

    /// Retries a failed/cancelled download as a fresh task. Any stale
    /// temporary file for the task is removed first.
    @discardableResult
    func retry(item: DownloadItem) -> Bool {
        guard item.state == .failed || item.state == .cancelled else { return false }
        guard let request = requests[item.id] else { return false }
        storage.cleanupTemporaryDownloads()
        return startResolved(item: item, directURL: request.sourceURL, fileName: request.fileName)
    }

    /// A download interrupted by app termination is reported honestly as
    /// failed — never fake-resumed (spec §14/§15).
    func markInterrupted(item: DownloadItem) {
        if item.state == .downloading || item.state == .preparing || item.state == .queued {
            item.state = .failed
            item.errorMessage = "アプリ終了によりダウンロードが中断されました。再試行してください。"
        }
    }
}
