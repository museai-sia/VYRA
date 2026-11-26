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
    /// The yt-dlp engine failed (Python error, extraction failure, ...).
    case engineFailed(description: String)
    /// A yt-dlp failure classified by the worker.js taxonomy: the
    /// Japanese `message` is the primary text; `rawDetail` keeps the
    /// raw yt-dlp text for the small detail line / debug log.
    case ytDlpClassified(message: String, rawDetail: String)

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
        case .engineFailed:
            return "yt-dlpでダウンロードできませんでした。URLが有効か確認して再試行してください。"
        case .ytDlpClassified(let message, _):
            return message
        }
    }

    /// Short, user-readable *specific* cause, shown under the generic
    /// `userMessage` (small gray text) and persisted on the item. For
    /// engine failures this is the Python exception's last meaningful
    /// line (e.g. "ERROR: HTTP Error 403: Forbidden") — the detail that
    /// used to be discarded between the bridge and the UI.
    var detailMessage: String? {
        switch self {
        case .engineFailed(let description),
             .network(let description),
             .fileSystem(let description):
            return Self.lastMeaningfulLine(of: description)
        case .ytDlpClassified(_, let rawDetail):
            return Self.lastMeaningfulLine(of: rawDetail)
        case .permissionNotVerified(let reason),
             .integrityFailed(let reason):
            return Self.lastMeaningfulLine(of: reason)
        case .httpStatus:
            return developerDescription
        default:
            return nil
        }
    }

    /// The last non-empty line of a (possibly multi-line) error string,
    /// trimmed and capped, so a Python traceback tail never floods the UI.
    static func lastMeaningfulLine(of text: String) -> String? {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
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
        case .engineFailed(let description): return "engineFailed: \(description)"
        case .ytDlpClassified(let message, _): return "ytDlpClassified: \(message)"
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
