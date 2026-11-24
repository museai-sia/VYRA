import Foundation

enum DownloadState: String, CaseIterable, Equatable, Sendable {
    /// Phase 1/2 legacy name for "not started yet". Kept so persisted
    /// Phase 1/2 records and existing tests keep working; new Phase 3
    /// tasks start as `queued`.
    case waiting
    case queued
    case preparing
    case downloading
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .waiting: return "Waiting"
        case .queued: return "Queued"
        case .preparing: return "Preparing"
        case .downloading: return "Downloading"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .waiting, .queued: return "clock"
        case .preparing: return "arrow.triangle.2.circlepath"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }

    /// Valid state transitions (Phase 3, spec §9). `paused` is deliberately
    /// NOT included: the URLSession download engine used here does not
    /// guarantee safe resume for arbitrary servers, so no paused state is
    /// offered rather than faking one.
    func canTransition(to next: DownloadState) -> Bool {
        if self == next { return false }
        switch self {
        case .waiting:
            return [.queued, .preparing, .downloading, .cancelled, .failed].contains(next)
        case .queued:
            return [.preparing, .downloading, .cancelled, .failed].contains(next)
        case .preparing:
            return [.downloading, .failed, .cancelled].contains(next)
        case .downloading:
            return [.completed, .failed, .cancelled].contains(next)
        case .failed, .cancelled:
            // Retry creates a fresh task.
            return [.queued, .preparing, .downloading, .waiting].contains(next)
        case .completed:
            return false
        }
    }
}
