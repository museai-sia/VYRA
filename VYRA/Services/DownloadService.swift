import Foundation

protocol DownloadService: Sendable {
    /// Prepares a (mock) download session for an item.
    func prepare(itemID: UUID) async
    /// Marks a (mock) download session as finished.
    func finish(itemID: UUID) async
    /// Cancels a (mock) download session.
    func cancel(itemID: UUID) async
}

/// Phase 1 mock. Performs no network access and writes no media file.
/// Progress simulation itself is driven by `DownloadViewModel.tick()`.
actor MockDownloadService: DownloadService {
    private(set) var preparedIDs: [UUID] = []
    private(set) var finishedIDs: [UUID] = []
    private(set) var cancelledIDs: [UUID] = []

    func prepare(itemID: UUID) async { preparedIDs.append(itemID) }
    func finish(itemID: UUID) async { finishedIDs.append(itemID) }
    func cancel(itemID: UUID) async { cancelledIDs.append(itemID) }
}
