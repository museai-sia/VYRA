import Foundation

/// Real yt-dlp provider (Phase 4): metadata comes from the embedded
/// CPython + yt-dlp engine running on-device (see YtDlpEngine.swift and
/// Documentation/Phases/PHASE_4_YTDLP.md).
///
/// History: through Phase 3 this type was a stub that always threw
/// `integrationUnavailable`, because the Phase 2 investigation concluded
/// yt-dlp could not run on iOS. That conclusion was superseded on
/// 2026-11-25 by the project owner's explicit order to embed CPython
/// (BeeWare Python-Apple-support) + yt-dlp, following working precedents
/// (Squirrel, YoutubeDL-iOS, FreeTube iOS forks): the interpreter runs
/// in-process, JavaScriptCore replaces the external JS runtime via a
/// yt-dlp challenge provider, and ffmpeg is never invoked (downloads
/// are restricted to single-file formats).
struct YtDlpIntegrationProvider: MetadataProvider {
    let id = "yt-dlp"
    let displayName = "yt-dlp"

    var engine: any YtDlpEngineProtocol

    init(engine: any YtDlpEngineProtocol = EmbeddedYtDlpEngine.shared) {
        self.engine = engine
    }

    func canHandle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        // Direct media files are handled by DirectMediaProvider instead;
        // the aggregator orders it first, but stay explicit here.
        return !MediaFormatService.isDirectMediaURL(url)
    }

    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        do {
            let info = try await engine.extractMetadata(url: url)
            return YtDlpMetadataMapper.metadata(from: info, sourceURL: url)
        } catch let error as YtDlpEngineError {
            switch error {
            case .cancelled:
                throw MetadataError.cancelled
            case .runtimeUnavailable(let reason):
                throw MetadataError.integrationUnavailable(reason: reason)
            case .pythonError(let message):
                throw MetadataError.network(message)
            case .classifiedFailure(let message, _):
                throw MetadataError.classifiedFailure(message: message)
            case .remuxFailed(let message), .transcodeFailed(let message):
                // Extraction never remuxes/transcodes; map defensively.
                throw MetadataError.network(message)
            }
        }
    }
}
