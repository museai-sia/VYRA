import Foundation

/// Metadata provider for DIRECT media file URLs (Phase 3).
/// When the user pastes a URL that itself serves an .mp4/.mov/.m4a file,
/// the file's own name, extension, Content-Type and Content-Length are its
/// metadata — obtained with a single HEAD request to that exact URL.
/// No scraping, no page parsing, no other host is contacted.
/// `availableFormats` contains exactly the file's own format, which (via
/// DownloadCapability) marks this source as downloadable: the permission
/// question does not arise for a direct file URL the user supplied.
struct DirectMediaProvider: MetadataProvider {
    let id = "direct-media"
    let displayName = "直接ファイル"

    var session: URLSession = .shared

    func canHandle(_ url: URL) -> Bool {
        MediaFormatService.isDirectMediaURL(url)
    }

    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw MetadataError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MetadataError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw MetadataError.notFound
        }
        let format = MediaFormatService.directFormat(for: url)!
        let fileName = url.lastPathComponent
        let title = (fileName as NSString).deletingPathExtension
        return VideoMetadata(
            id: fileName,
            title: title.isEmpty ? fileName : title,
            creatorName: url.host ?? "",
            sourceName: "Direct HTTPS",
            thumbnailURL: nil,
            durationSeconds: 0,
            publishedAt: nil,
            description: nil,
            sourceURL: url,
            availableFormats: [AvailableMediaFormat(
                container: format.rawValue,
                qualityLabel: DownloadQuality.original.displayName,
                isAudioOnly: format.isAudioOnly
            )]
        )
    }
}
