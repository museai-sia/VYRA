import Foundation
import Observation

/// Generic URL syntax validation (Phase 1 behaviour, preserved).
/// YouTube-specific parsing lives in `URLValidationService`.
enum URLValidator {
    static func isValidVideoURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, host.contains(".")
        else { return false }
        return true
    }

    static func normalizedURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidVideoURL(trimmed) else { return nil }
        return URL(string: trimmed)
    }
}

@MainActor
@Observable
final class HomeViewModel {
    enum FetchState: Equatable {
        case idle
        case validating
        case loading
        case loaded
        case failed
    }

    var urlString: String = ""
    var errorMessage: String?
    var state: FetchState = .idle
    var fetchedVideo: Video?
    var fetchedMetadata: VideoMetadata?
    /// In-memory history of successfully fetched metadata (not persisted).
    var recentFetches: [VideoMetadata] = []

    /// Mock counters shown in the "recent" section of Home.
    var savedCount: Int = 0

    var isLoading: Bool { state == .validating || state == .loading }

    private let metadataService: any VideoMetadataService
    private var fetchTask: Task<Video?, Never>?

    init(metadataService: (any VideoMetadataService)? = nil) {
        self.metadataService = metadataService ?? YouTubeDataAPIService.defaultService()
    }

    var trimmedURLString: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isURLValid: Bool { URLValidator.isValidVideoURL(urlString) }

    func paste(from clipboardText: String?) {
        guard let clipboardText, !clipboardText.isEmpty else {
            errorMessage = "クリップボードにURLがありません。"
            return
        }
        urlString = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
    }

    func clear() {
        cancel()
        urlString = ""
        errorMessage = nil
        fetchedVideo = nil
        fetchedMetadata = nil
        state = .idle
    }

    func cancel() {
        fetchTask?.cancel()
        fetchTask = nil
        if isLoading { state = .idle }
    }

    @discardableResult
    func retry() async -> Video? {
        await fetchVideoInfo()
    }

    /// Validates the input as a YouTube URL, then loads real metadata.
    /// Duplicate calls while a fetch is in flight are ignored.
    /// Returns the video on success so the View can navigate.
    @discardableResult
    func fetchVideoInfo() async -> Video? {
        guard !isLoading else { return nil }
        state = .validating
        let parsed: (url: URL, videoID: String)
        do {
            parsed = try URLValidationService.parse(urlString)
        } catch let error as URLValidationError {
            state = .failed
            errorMessage = Self.message(for: error)
            fetchedVideo = nil
            return nil
        } catch {
            state = .failed
            errorMessage = "URLの形式が正しくありません。YouTubeの動画URLを入力してください。"
            fetchedVideo = nil
            return nil
        }
        errorMessage = nil
        state = .loading
        let service = metadataService
        let url = parsed.url
        let task = Task<Video?, Never> {
            do {
                let metadata = try await service.fetchMetadata(for: url)
                if Task.isCancelled { return nil }
                self.fetchedMetadata = metadata
                let video = Video(metadata: metadata)
                self.fetchedVideo = video
                if !self.recentFetches.contains(where: { $0.id == metadata.id }) {
                    self.recentFetches.insert(metadata, at: 0)
                }
                self.state = .loaded
                return video
            } catch let error as VideoMetadataError {
                if error == .cancelled || Task.isCancelled {
                    self.state = .idle
                    return nil
                }
                self.state = .failed
                self.errorMessage = Self.message(for: error)
                return nil
            } catch {
                if Task.isCancelled {
                    self.state = .idle
                    return nil
                }
                self.state = .failed
                self.errorMessage = "動画情報を取得できませんでした。通信状態を確認して、もう一度お試しください。"
                return nil
            }
        }
        fetchTask = task
        let result = await task.value
        fetchTask = nil
        return result
    }

    static func message(for error: URLValidationError) -> String {
        switch error {
        case .empty:
            return "URLを入力してください。"
        case .invalidFormat:
            return "URLの形式が正しくありません。https:// から始まるYouTubeの動画URLを入力してください。"
        case .unsupportedHost:
            return "対応していないURLです。YouTubeの動画URL（youtube.com / youtu.be）を入力してください。"
        case .missingVideoID:
            return "動画IDが見つかりません。動画ページのURLをそのまま貼り付けてください。"
        case .invalidVideoID:
            return "動画IDの形式が正しくありません。URLを確認してもう一度お試しください。"
        }
    }

    static func message(for error: VideoMetadataError) -> String {
        switch error {
        case .invalidURL:
            return "URLの形式が正しくありません。YouTubeの動画URLを入力してください。"
        case .urlValidation(let urlError):
            return message(for: urlError)
        case .apiKeyMissing:
            return "YouTube APIキーが未設定のため、動画情報を取得できません。設定（GitHub Secrets: YOUTUBE_API_KEY）を確認してください。"
        case .httpError(let code):
            return "サーバーエラー（HTTP \(code)）が発生しました。しばらく待ってから再試行してください。"
        case .quotaExceeded:
            return "APIの利用上限に達しました。しばらく待ってから再試行してください。"
        case .notFound:
            return "動画が見つかりませんでした。URLが正しいか、動画が公開されているか確認してください。"
        case .network:
            return "通信に失敗しました。ネットワーク接続を確認して再試行してください。"
        case .decoding, .invalidResponse:
            return "サーバーからの応答を読み取れませんでした。再試行してください。"
        case .cancelled:
            return "取得をキャンセルしました。"
        }
    }
}
