import Foundation

/// Permission state for a specific source host. Default: unverified.
enum SourcePermission: Equatable, Sendable {
    case unverified
    case verified
}

/// Skeleton provider for sources whose terms explicitly permit metadata
/// access. It returns metadata only when permission for the URL's host
/// has been explicitly verified AND a fetcher has been connected.
///
/// In Phase 2 no source is verified and no fetcher is connected, and no
/// real network fetching of YouTube or any specific service is performed.
struct AuthorizedSourceProvider: MetadataProvider {
    let id = "authorized-source"
    let displayName = "許可済みソース"

    var verifiedHosts: Set<String> = []
    var fetcher: (@Sendable (URL) async throws -> VideoMetadata)?

    init(verifiedHosts: Set<String> = [],
         fetcher: (@Sendable (URL) async throws -> VideoMetadata)? = nil) {
        self.verifiedHosts = verifiedHosts
        self.fetcher = fetcher
    }

    func permission(for url: URL) -> SourcePermission {
        guard let host = url.host?.lowercased() else { return .unverified }
        return verifiedHosts.contains(host) ? .verified : .unverified
    }

    func canHandle(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil
    }

    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        guard permission(for: url) == .verified else {
            throw MetadataError.permissionNotVerified
        }
        guard let fetcher else {
            throw MetadataError.integrationUnavailable(
                reason: "許可済みソース向けの取得実装はまだ接続されていません。"
            )
        }
        return try await fetcher(url)
    }
}
