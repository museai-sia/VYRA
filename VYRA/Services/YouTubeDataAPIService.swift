import Foundation

/// Minimal HTTP abstraction so tests can stub responses without networking.
protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {}

/// Fetches video metadata from the official YouTube Data API v3
/// (`videos.list`). Metadata only — no downloading, streaming-URL
/// extraction, scraping, or unofficial endpoints.
///
/// The API key is never hardcoded: it is read from the app's Info.plist
/// key `YouTubeAPIKey` or the `YOUTUBE_API_KEY` environment variable.
/// Note: any key shipped inside an app can be extracted; a backend proxy
/// is the recommended production design (see PHASE_2_HANDOFF.md).
struct YouTubeDataAPIService: VideoMetadataService {
    var apiKey: String?
    var httpClient: any HTTPClient

    init(apiKey: String? = YouTubeDataAPIService.configuredAPIKey(),
         httpClient: any HTTPClient = URLSession.shared) {
        self.apiKey = apiKey
        self.httpClient = httpClient
    }

    static func configuredAPIKey(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let env = environment["YOUTUBE_API_KEY"], !env.isEmpty { return env }
        if let plist = infoDictionary?["YouTubeAPIKey"] as? String,
           !plist.isEmpty, !plist.hasPrefix("$(") { return plist }
        return nil
    }

    /// The service used by default in production: this service when a key
    /// is configured, otherwise a service that fails with `apiKeyMissing`.
    static func defaultService() -> any VideoMetadataService {
        if configuredAPIKey() != nil { return YouTubeDataAPIService() }
        return UnconfiguredVideoMetadataService()
    }

    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        guard let apiKey, !apiKey.isEmpty else {
            throw VideoMetadataError.apiKeyMissing
        }
        let videoID: String
        do {
            videoID = try URLValidationService.extractVideoID(from: url)
        } catch let error as URLValidationError {
            throw VideoMetadataError.urlValidation(error)
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = "/youtube/v3/videos"
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet,contentDetails"),
            URLQueryItem(name: "id", value: videoID),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let requestURL = components.url else {
            throw VideoMetadataError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch is CancellationError {
            throw VideoMetadataError.cancelled
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw VideoMetadataError.cancelled }
            throw VideoMetadataError.network(urlError.localizedDescription)
        } catch {
            throw VideoMetadataError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw VideoMetadataError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            break
        case 403, 429:
            throw VideoMetadataError.quotaExceeded
        default:
            throw VideoMetadataError.httpError(http.statusCode)
        }

        let decoded: YouTubeVideosListResponse
        do {
            decoded = try JSONDecoder().decode(YouTubeVideosListResponse.self, from: data)
        } catch {
            throw VideoMetadataError.decoding
        }
        guard let item = decoded.items?.first else {
            throw VideoMetadataError.notFound
        }
        return try item.toVideoMetadata(sourceURL: url)
    }
}
