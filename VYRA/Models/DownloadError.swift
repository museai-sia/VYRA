import Foundation

/// Typed download errors (Phase 3, spec §17). `userMessage` is the concise
/// Japanese message shown in the UI; `developerDescription` carries detail
/// for logs only.
enum DownloadError: Error, Equatable, Sendable {
    case invalidURL
    case permissionNotVerified(reason: String)
    case unsupportedFormat
    case httpStatus(Int)
    case network(description: String)
    case cancelled
    case fileSystem(description: String)
    case insufficientStorage
    case integrityFailed(reason: String)
    case invalidStateTransition

    var userMessage: String {
        switch self {
        case .invalidURL:
            return "URLが正しくありません。https:// から始まる直接ファイルのURLを確認してください。"
        case .permissionNotVerified:
            return "このソースはダウンロード許可が確認できないため、ダウンロードできません。直接ファイルのURL（.mp4 / .mov / .m4a）を使用してください。"
        case .unsupportedFormat:
            return "対応していないファイル形式です。MP4 / MOV / M4A のファイルのみ保存できます。"
        case .httpStatus(let code):
            return "取得元がエラーを返しました（HTTP \(code)）。URLが有効か確認してください。"
        case .network:
            return "通信に失敗しました。ネットワーク接続を確認して再試行してください。"
        case .cancelled:
            return "ダウンロードをキャンセルしました。"
        case .fileSystem:
            return "ファイルの保存に失敗しました。空き容量を確認して再試行してください。"
        case .insufficientStorage:
            return "ストレージの空き容量が不足しています。"
        case .integrityFailed:
            return "ダウンロードしたファイルが不完全なため、保存できませんでした。再試行してください。"
        case .invalidStateTransition:
            return "現在の状態ではこの操作はできません。"
        }
    }

    var developerDescription: String {
        switch self {
        case .invalidURL: return "DownloadError.invalidURL"
        case .permissionNotVerified(let reason): return "permissionNotVerified: \(reason)"
        case .unsupportedFormat: return "DownloadError.unsupportedFormat"
        case .httpStatus(let code): return "HTTP status \(code)"
        case .network(let description): return "network: \(description)"
        case .cancelled: return "DownloadError.cancelled"
        case .fileSystem(let description): return "fileSystem: \(description)"
        case .insufficientStorage: return "DownloadError.insufficientStorage"
        case .integrityFailed(let reason): return "integrityFailed: \(reason)"
        case .invalidStateTransition: return "DownloadError.invalidStateTransition"
        }
    }

    static func from(_ error: Error) -> DownloadError {
        if let downloadError = error as? DownloadError { return downloadError }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return .cancelled }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError { return .insufficientStorage }
        if nsError.domain == NSURLErrorDomain { return .network(description: nsError.localizedDescription) }
        return .network(description: nsError.localizedDescription)
    }
}
