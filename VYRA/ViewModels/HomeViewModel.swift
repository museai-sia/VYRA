import Foundation
import Observation

/// Generic URL syntax validation (Phase 1 behaviour, preserved).
/// Source classification and YouTube parsing live in `URLValidationService`.
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

    private let metadataService: any VideoMetadataFetching
    private var fetchTask: Task<Video?, Never>?

    /// Default wiring is the aggregating `VideoMetadataService` with the
    /// authorized-source skeleton and the yt-dlp interface stub: real URLs
    /// fail with a clear message until a permitted provider is connected.
    /// The mock provider is injected only by tests and previews.
    init(metadataService: (any VideoMetadataFetching)? = nil) {
        self.metadataService = metadataService ?? VideoMetadataService.appDefault
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

    /// Validates the input URL, then loads metadata via the aggregator.
    /// Duplicate calls while a fetch is in flight are ignored.
    /// Returns the video on success so the View can navigate.
    @discardableResult
    func fetchVideoInfo() async -> Video? {
        guard !isLoading else { return nil }
        state = .validating
        let validated: ValidatedSource
        do {
            validated = try URLValidationService.validate(urlString)
        } catch let error as URLValidationError {
            state = .failed
            errorMessage = Self.message(for: error)
            fetchedVideo = nil
            return nil
        } catch {
            state = .failed
            errorMessage = "URLの形式が正しくありません。https:// から始まる動画URLを入力してください。"
            fetchedVideo = nil
            return nil
        }
        errorMessage = nil
        state = .loading
        let service = metadataService
        let url = validated.url
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
            } catch let error as MetadataError {
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
            return "URLの形式が正しくありません。https:// から始まる動画URLを入力してください。"
        case .unsupportedHost:
            return "対応していないURLです。公式の動画URLをそのまま貼り付けてください（似た名前の別サイトのURLは使えません）。"
        case .missingVideoID:
            return "動画IDが見つかりません。動画ページのURLをそのまま貼り付けてください。"
        case .invalidVideoID:
            return "動画IDの形式が正しくありません。URLを確認してもう一度お試しください。"
        }
    }

    static func message(for error: MetadataError) -> String {
        switch error {
        case .urlValidation(let urlError):
            return message(for: urlError)
        case .unsupportedSource:
            return "このソースの取得元が未設定です。対応するプロバイダが接続されていません。"
        case .integrationUnavailable:
            return "このソースの取得元が未設定です。アプリ内でのyt-dlp実行はiOSの制約によりできないため、許可済みプロバイダの接続が必要です。"
        case .permissionNotVerified:
            return "このソースは利用許可が確認できていないため、情報を取得できません。許可済みのソースのURLを入力してください。"
        case .notFound:
            return "動画が見つかりませんでした。URLが正しいか、動画が公開されているか確認してください。"
        case .network:
            return "通信に失敗しました。ネットワーク接続を確認して再試行してください。"
        case .decoding, .invalidResponse:
            return "取得元からの応答を読み取れませんでした。再試行してください。"
        case .cancelled:
            return "取得をキャンセルしました。"
        }
    }
}
