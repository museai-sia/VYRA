import Foundation

/// A video's metadata. In Phase 1 every value comes from the mock service.
struct Video: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: UUID
    var title: String
    var author: String
    var durationSeconds: Int
    var sourceName: String
    var sourceURLString: String
    /// SF Symbol used as the placeholder thumbnail artwork (monochrome).
    var thumbnailSymbol: String
    /// Phase 2 bridging fields (all optional, defaulted so Phase 1 code
    /// and existing initializers keep compiling unchanged).
    var externalID: String? = nil
    var thumbnailURL: URL? = nil
    var publishedAt: Date? = nil
    var descriptionText: String? = nil

    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        durationSeconds: Int,
        sourceName: String,
        sourceURLString: String,
        thumbnailSymbol: String = "play.rectangle.fill",
        externalID: String? = nil,
        thumbnailURL: URL? = nil,
        publishedAt: Date? = nil,
        descriptionText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.durationSeconds = durationSeconds
        self.sourceName = sourceName
        self.sourceURLString = sourceURLString
        self.thumbnailSymbol = thumbnailSymbol
        self.externalID = externalID
        self.thumbnailURL = thumbnailURL
        self.publishedAt = publishedAt
        self.descriptionText = descriptionText
    }

    /// Bridges Phase 2 metadata into the Phase 1 display model.
    init(metadata: VideoMetadata) {
        self.init(
            title: metadata.title,
            author: metadata.channelTitle,
            durationSeconds: metadata.durationSeconds,
            sourceName: "YouTube",
            sourceURLString: metadata.sourceURL.absoluteString,
            thumbnailSymbol: "play.rectangle.fill",
            externalID: metadata.id,
            thumbnailURL: metadata.thumbnailURL,
            publishedAt: metadata.publishedAt,
            descriptionText: metadata.description
        )
    }

    var formattedDuration: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static let mock = Video(
        title: "Designing with Liquid Glass — Mock Video",
        author: "VYRA Studio (Mock)",
        durationSeconds: 754,
        sourceName: "Mock Source",
        sourceURLString: "https://example.com/videos/mock-liquid-glass",
        thumbnailSymbol: "play.rectangle.fill"
    )
}
