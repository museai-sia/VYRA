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
    /// Engine for yt-dlp downloads (items carrying a ytDlpFormatID).
    let ytDlpEngine: (any DownloadService)?
    let storage: FileStorageService
    /// Where completed downloads are saved (Settings > 保存先).
    let destinationStore: SaveDestinationStore
    /// Called on the main actor with the completed item after its file has
    /// been moved into the Library directory. The Library layer persists it.
    var onCompleted: ((DownloadItem) -> Void)?

    private(set) var progresses: [UUID: DownloadProgress] = [:]
    private(set) var errors: [UUID: DownloadError] = [:]
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var requests: [UUID: DownloadRequest] = [:]

    init(engine: any DownloadService = URLSessionDownloadEngine(),
         ytDlpEngine: (any DownloadService)? = nil,
         storage: FileStorageService = .appDefault,
         destinationStore: SaveDestinationStore = .shared,
         onCompleted: ((DownloadItem) -> Void)? = nil) {
        self.engine = engine
        self.ytDlpEngine = ytDlpEngine
        self.storage = storage
        self.destinationStore = destinationStore
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
        // yt-dlp route: the item carries a concrete format_id from real
        // yt-dlp metadata; the page URL goes to the yt-dlp engine.
        if let formatID = item.ytDlpFormatID {
            guard let ytDlpEngine else {
                let error = DownloadError.engineFailed(description: "yt-dlp engine not configured")
                if item.transition(to: .failed) {
                    item.errorMessage = error.userMessage
                    item.errorDetail = error.detailMessage
                }
                errors[item.id] = error
                return false
            }
            let request = DownloadRequest(
                taskID: item.id, sourceURL: sourceURL, fileName: fileName,
                ytDlpFormatID: formatID, ytDlpAudioFormatID: item.ytDlpAudioFormatID,
                ytDlpProcessing: item.ytDlpProcessing,
                ytDlpIsAudioOnly: item.format.isAudioOnly,
                estimatedBytes: item.fileSizeBytes > 0 ? item.fileSizeBytes : nil,
                durationSeconds: item.durationSeconds,
                estimatedHeight: item.ytDlpPixelHeight ?? item.quality.heightHint)
            return startResolved(item: item, request: request, engine: ytDlpEngine)
        }
        switch DirectMediaResolver.resolve(sourceURL: sourceURL, format: item.format) {
        case .downloadable(let url, _):
            return startResolved(item: item, directURL: url, fileName: fileName)
        case .ytDlp:
            // Unreachable here: yt-dlp items carry a formatID and are
            // routed above; without metadata the resolver cannot pick one.
            let error = DownloadError.engineFailed(description: "yt-dlp formatID missing on item")
            if item.transition(to: .failed) {
                item.errorMessage = error.userMessage
                item.errorDetail = error.detailMessage
            }
            errors[item.id] = error
            return false
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
        let request = DownloadRequest(taskID: item.id, sourceURL: directURL, fileName: fileName)
        return startResolved(item: item, request: request, engine: engine)
    }

    @discardableResult
    func startResolved(item: DownloadItem, request: DownloadRequest, engine: any DownloadService) -> Bool {
        guard runningTasks[item.id] == nil else { return false }
        if item.state == .waiting || item.state == .failed || item.state == .cancelled {
            guard item.transition(to: .queued) else { return false }
        }
        guard item.state == .queued else { return false }
        errors[item.id] = nil
        item.errorMessage = nil
        item.errorDetail = nil
        requests[item.id] = request
        progresses[item.id] = DownloadProgress.initial(state: .queued)

        let engine = engine
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
                // Success: move into the save destination, then register.
                let storedURL = try self.storeDownloadedFile(
                    tempFileURL: tempURL, desiredFileName: request.fileName, item: item)
                let actualSize = storage.fileSize(at: storedURL) ?? 0
                guard actualSize > 0 else {
                    storage.deleteTemporaryFile(at: storedURL)
                    throw DownloadError.integrityFailed(reason: "downloaded file is empty")
                }
                item.fileName = storedURL.lastPathComponent
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
                        item.errorDetail = downloadError.detailMessage
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

    // MARK: - Save destination

    /// Moves a finished download into the user's chosen save folder
    /// (Settings > 保存先), recording how to find the file on the
    /// item: a per-file security-scoped bookmark for external files,
    /// a Documents-relative path for app-folder files. When the
    /// external folder cannot be used — no folder chosen, bookmark
    /// dead, or the move itself fails — the file goes to the app
    /// folder instead of being lost; Settings surfaces the folder's
    /// unavailable state.
    private func storeDownloadedFile(tempFileURL: URL, desiredFileName: String,
                                     item: DownloadItem) throws -> URL {
        if let access = destinationStore.beginFolderAccess() {
            defer { access.end() }
            do {
                let url = try storage.moveIntoDirectory(
                    tempFileURL: tempFileURL, desiredFileName: desiredFileName,
                    directory: access.url)
                item.externalBookmarkData = ExternalFileAccess.bookmark(forFileAt: url)
                item.localFileRelativePath = nil
                return url
            } catch {
                logger.error("save to external folder failed, falling back to app folder: \(error.localizedDescription, privacy: .public)")
                // Fall through: the temp file is still there (the
                // move did not complete), save it in-app instead.
            }
        }
        let moved = try storage.moveIntoLibrary(tempFileURL: tempFileURL, desiredFileName: desiredFileName)
        item.localFileRelativePath = moved.relativePath
        item.externalBookmarkData = nil
        return moved.url
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
        let engine = engine(for: requests[item.id])
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
        return startResolved(item: item, request: request, engine: engine(for: request))
    }

    /// The engine that owns a request: yt-dlp requests go to the yt-dlp
    /// engine, everything else to the direct-file engine.
    private func engine(for request: DownloadRequest?) -> any DownloadService {
        if request?.ytDlpFormatID != nil, let ytDlpEngine {
            return ytDlpEngine
        }
        return engine
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
