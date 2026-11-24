import Foundation

enum DownloadState: String, CaseIterable, Equatable, Sendable {
    case waiting
    case downloading
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .waiting: return "Waiting"
        case .downloading: return "Downloading"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .waiting: return "clock"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }
}
