import Foundation
import Observation

/// Download screen state (Phase 3). Two modes:
/// - Manager mode (real flow): a `DownloadTaskManager` drives a real
///   engine; this view model mirrors its progress/state.
/// - Legacy tick mode (no manager): the Phase 1 deterministic tick
///   simulation, kept for previews and the Phase 1 unit tests. It never
///   writes files and is always labelled as mock in the UI.
@MainActor
@Observable
final class DownloadViewModel {
    let item: DownloadItem
    let video: Video
    private(set) var progress: Double = 0
    var state: DownloadState = .waiting
    private(set) var downloadProgress: DownloadProgress = .initial()
    var errorMessage: String?

    /// Fraction added on each tick of the legacy simulation loop.
    var progressStep: Double = 0.05
    var tickIntervalNanoseconds: UInt64 = 180_000_000

    let manager: DownloadTaskManager?
    private var progressTask: Task<Void, Never>?
    private var mirrorTask: Task<Void, Never>?

    init(item: DownloadItem, video: Video, manager: DownloadTaskManager? = nil) {
        self.item = item
        self.video = video
        self.manager = manager
        self.state = item.state
    }

    var usesManager: Bool { manager != nil }

    var progressPercentText: String { "\(Int((progress * 100).rounded()))%" }

    var isRunning: Bool { state == .downloading || state == .preparing || state == .queued }
    var isFinished: Bool { state == .completed }

    // MARK: - Start / retry

    func start() {
        if let manager {
            guard state == .waiting || state == .cancelled || state == .failed || state == .queued else { return }
            if state != .waiting { progress = 0 }
            if let sourceURL = item.sourceURL {
                _ = manager.start(item: item, sourceURL: sourceURL, fileName: item.fileName)
            } else {
                state = .failed
                errorMessage = DownloadError.invalidURL.userMessage
                return
            }
            syncFromManager()
            startMirroring()
            return
        }
        // Legacy tick simulation (Phase 1 behaviour, tests/previews only).
        guard state == .waiting || state == .cancelled || state == .failed else { return }
        if state != .waiting { progress = 0 }
        state = .downloading
        item.state = .downloading
        progressTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.tickIntervalNanoseconds)
                if Task.isCancelled { break }
                self.tick()
                if self.state != .downloading { break }
            }
        }
    }

    func retry() {
        guard let manager else {
            progress = 0
            state = .waiting
            item.state = .waiting
            start()
            return
        }
        guard state == .failed || state == .cancelled else { return }
        progress = 0
        if manager.retry(item: item) {
            syncFromManager()
            startMirroring()
        } else if let sourceURL = item.sourceURL {
            // No previous request recorded (e.g. resolution failure):
            // start fresh so the error is re-evaluated honestly.
            state = item.state
            _ = manager.start(item: item, sourceURL: sourceURL, fileName: item.fileName)
            syncFromManager()
            startMirroring()
        }
    }

    /// Advances the legacy simulation by one step. Used by tests.
    func tick() {
        guard manager == nil else { return }
        guard state == .downloading else { return }
        progress = min(1.0, progress + progressStep)
        downloadProgress = DownloadProgress(
            downloadedBytes: Int64(progress * Double(item.fileSizeBytes)),
            totalBytes: item.fileSizeBytes,
            state: .downloading
        )
        if progress >= 1.0 {
            complete()
        }
    }

    func complete() {
        progress = 1.0
        state = .completed
        item.state = .completed
        downloadProgress = DownloadProgress(
            downloadedBytes: item.fileSizeBytes, totalBytes: item.fileSizeBytes, state: .completed)
        progressTask?.cancel()
        progressTask = nil
    }

    func cancel() {
        if let manager {
            manager.cancel(item: item)
            syncFromManager()
            return
        }
        guard state == .downloading || state == .waiting else { return }
        progressTask?.cancel()
        progressTask = nil
        state = .cancelled
        item.state = .cancelled
        downloadProgress.state = .cancelled
    }

    func simulateFailure() {
        progressTask?.cancel()
        progressTask = nil
        mirrorTask?.cancel()
        mirrorTask = nil
        state = .failed
        item.state = .failed
        downloadProgress.state = .failed
    }

    // MARK: - Manager mirroring

    private func startMirroring() {
        mirrorTask?.cancel()
        mirrorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.syncFromManager()
                if self.state == .completed || self.state == .failed || self.state == .cancelled {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func syncFromManager() {
        guard let manager else { return }
        state = item.state
        if let snapshot = manager.progress(for: item.id) {
            downloadProgress = snapshot
            if let fraction = snapshot.fraction {
                progress = fraction
            }
        }
        if state == .failed {
            errorMessage = item.errorMessage ?? manager.errors[item.id]?.userMessage
        }
    }
}
