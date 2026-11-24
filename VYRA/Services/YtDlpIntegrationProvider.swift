import Foundation

/// Interface stub for a possible yt-dlp integration, kept for Phase 3
/// evaluation. It NEVER executes anything:
///
/// Investigation conclusion (see Documentation/Phases/PHASE_2_METADATA.md):
/// in-app yt-dlp execution is not feasible or compliant on iOS —
/// yt-dlp needs CPython 3.11+, ffmpeg/ffprobe, and (for full YouTube
/// support) yt-dlp-ejs plus an external JS runtime (deno/node/bun/
/// QuickJS) to solve YouTube's n/sig challenges. None of those runtimes
/// have native iOS builds, iOS sandboxing forbids spawning subprocesses
/// in a normal app (sideloading does not lift that rule), and solving
/// n/sig challenges is signature circumvention, which the spec forbids.
///
/// Therefore this provider always throws `integrationUnavailable`.
/// No Process, no Python, no shelling out, no network scraping,
/// no cookie or signature handling exists in this file or app.
struct YtDlpIntegrationProvider: MetadataProvider {
    let id = "yt-dlp"
    let displayName = "yt-dlp (未接続)"

    static let infeasibilityReason =
        "iOSアプリ内ではyt-dlpを実行できません（CPython/ffmpeg/JSランタイムがiOSで動作せず、サンドボックスにより外部プロセス起動も禁止されています）。"

    func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return URLValidationService.youTubeHosts.contains(host)
    }

    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        throw MetadataError.integrationUnavailable(reason: Self.infeasibilityReason)
    }
}
