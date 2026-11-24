import Foundation
import Observation

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
    var urlString: String = ""
    var errorMessage: String?
    var isLoading: Bool = false
    var fetchedVideo: Video?

    /// Mock counters shown in the "recent" section of Home.
    var savedCount: Int = 0

    private let metadataService: any VideoMetadataService

    init(metadataService: any VideoMetadataService = MockVideoMetadataService()) {
        self.metadataService = metadataService
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
        urlString = ""
        errorMessage = nil
        fetchedVideo = nil
    }

    /// Validates the input and, when valid, loads mock metadata.
    /// Returns the video on success so the View can navigate.
    @discardableResult
    func fetchVideoInfo() async -> Video? {
        guard let url = URLValidator.normalizedURL(urlString) else {
            errorMessage = "URLの形式が正しくありません。http:// または https:// から始まるURLを入力してください。"
            fetchedVideo = nil
            return nil
        }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let video = try await metadataService.fetchMetadata(for: url)
            fetchedVideo = video
            return video
        } catch {
            errorMessage = "動画情報を取得できませんでした。（モック）"
            return nil
        }
    }
}
