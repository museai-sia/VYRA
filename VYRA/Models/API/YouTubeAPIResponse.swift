import Foundation

/// DTOs for the YouTube Data API v3 `videos.list` response.
/// Kept separate from the app-internal `VideoMetadata` model.
struct YouTubeVideosListResponse: Decodable, Sendable {
    var items: [Item]?

    struct Item: Decodable, Sendable {
        var id: String
        var snippet: Snippet?
        var contentDetails: ContentDetails?
    }

    struct Snippet: Decodable, Sendable {
        var title: String?
        var channelTitle: String?
        var publishedAt: String?
        var description: String?
        var thumbnails: Thumbnails?
    }

    struct Thumbnails: Decodable, Sendable {
        var `default`: Thumbnail?
        var medium: Thumbnail?
        var high: Thumbnail?
        var maxres: Thumbnail?

        /// Preference order: maxres > high > medium > default.
        var bestURL: URL? {
            for thumb in [maxres, high, medium, `default`] {
                if let urlString = thumb?.url, let url = URL(string: urlString) { return url }
            }
            return nil
        }
    }

    struct Thumbnail: Decodable, Sendable {
        var url: String?
        var width: Int?
        var height: Int?
    }

    struct ContentDetails: Decodable, Sendable {
        var duration: String?
    }
}

extension YouTubeVideosListResponse.Item {
    /// Converts an API item into the app-internal model.
    /// Throws `VideoMetadataError.invalidResponse` when the snippet is missing.
    func toVideoMetadata(sourceURL: URL) throws -> VideoMetadata {
        guard let snippet, let title = snippet.title, !title.isEmpty else {
            throw VideoMetadataError.invalidResponse
        }
        return VideoMetadata(
            id: id,
            title: title,
            channelTitle: snippet.channelTitle ?? "",
            thumbnailURL: snippet.thumbnails?.bestURL,
            durationSeconds: contentDetails?.duration.map(VideoMetadata.parseISO8601Duration) ?? 0,
            publishedAt: snippet.publishedAt.flatMap(VideoMetadata.parseISO8601Date),
            description: snippet.description,
            sourceURL: sourceURL
        )
    }
}
