import Foundation
import Observation

@MainActor
@Observable
final class DownloadViewModel {
    let item: DownloadItem
    let video: Video
    private(set) var progress: Double = 0
    var state: DownloadState = .waiting

    /// Fraction added on each tick of the mock progress loop.
    var progressStep: Double = 0.05
    var tickIntervalNanoseconds: UInt64 = 180_000_000

    private let downloadService: any DownloadService
    private var progressTask: Task<Void, Never>?

    init(item: DownloadItem, video: Video, downloadService: any DownloadService = MockDownloadService()) {
        self.item = item
        self.video = video
        self.downloadService = downloadService
        self.state = item.state
    }

    var progressPercentText: String { "\(Int((progress * 100).rounded()))%" }

    var isRunning: Bool { state == .downloading }
    var isFinished: Bool { state == .completed }

    func start() {
        guard state == .waiting || state == .cancelled || state == .failed else { return }
        if state != .waiting { progress = 0 }
        state = .downloading
        item.state = .downloading
        let service = downloadService
        let itemID = item.id
        progressTask = Task { [weak self] in
            await service.prepare(itemID: itemID)
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.tickIntervalNanoseconds)
                if Task.isCancelled { break }
                self.tick()
                if self.state != .downloading { break }
            }
        }
    }

    /// Advances the mock progress by one step. Used by the timer loop and tests.
    func tick() {
        guard state == .downloading else { return }
        progress = min(1.0, progress + progressStep)
        if progress >= 1.0 {
            complete()
        }
    }

    func complete() {
        progress = 1.0
        state = .completed
        item.state = .completed
        progressTask?.cancel()
        progressTask = nil
        let service = downloadService
        let itemID = item.id
        Task { await service.finish(itemID: itemID) }
    }

    func cancel() {
        guard state == .downloading || state == .waiting else { return }
        progressTask?.cancel()
        progressTask = nil
        state = .cancelled
        item.state = .cancelled
        let service = downloadService
        let itemID = item.id
        Task { await service.cancel(itemID: itemID) }
    }

    func simulateFailure() {
        progressTask?.cancel()
        progressTask = nil
        state = .failed
        item.state = .failed
    }
}
