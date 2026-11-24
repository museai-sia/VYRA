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

    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        durationSeconds: Int,
        sourceName: String,
        sourceURLString: String,
        thumbnailSymbol: String = "play.rectangle.fill"
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.durationSeconds = durationSeconds
        self.sourceName = sourceName
        self.sourceURLString = sourceURLString
        self.thumbnailSymbol = thumbnailSymbol
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
