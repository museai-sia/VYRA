import Foundation
import os

/// The yt-dlp engine boundary. ViewModels/providers depend on this
/// protocol; the production implementation runs the embedded CPython
/// interpreter, tests inject `MockYtDlpEngine`.
/// What the engine needs to turn a downloaded format into the
/// saved file: the processing the selection requires plus the
/// source-reported estimates used to derive transcode bitrates.
struct YtDlpProcessingContext: Equatable, Sendable {
    var processing: MediaProcessingKind = .direct
    var isAudioOnly: Bool = false
    var estimatedBytes: Int64? = nil
    var durationSeconds: Int? = nil
    var height: Int? = nil
}

protocol YtDlpEngineProtocol: Sendable {
    func versions() async throws -> YtDlpVersions
    func extractMetadata(url: URL) async throws -> YtDlpExtractedInfo
    /// Downloads the exact `formatID` (a single-file format) into a
    /// temporary directory and returns the finished file's URL.
    /// When the context's processing is `.transcode`, the downloaded
    /// file is first re-encoded to a playable MP4/M4A in-process;
    /// when it is `.remuxSingle` (an HLS selection), the downloaded
    /// MPEG-TS bytes are first remuxed to MP4 in-process.
    func download(jobID: UUID, url: URL, formatID: String, fileName: String,
                  context: YtDlpProcessingContext,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL
    /// Downloads a split pair through ONE bridge job (yt-dlp fetches
    /// both formats; the bridge aggregates their progress) and joins
    /// the two files into one MP4 with the bundled FFmpeg libraries:
    /// a stream-copy remux when the context's processing is `.remux`,
    /// a full transcode when it is `.transcode`. Progress is the
    /// bridge's aggregate stream and ends with a `.merging` or
    /// `.transcoding` phase.
    func downloadSplit(jobID: UUID, url: URL, videoFormatID: String, audioFormatID: String,
                       fileName: String, context: YtDlpProcessingContext,
                       progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL
    func cancel(jobID: UUID) async
}

/// Production engine backed by the embedded CPython + yt-dlp runtime.
final class EmbeddedYtDlpEngine: YtDlpEngineProtocol, @unchecked Sendable {
    static let shared = EmbeddedYtDlpEngine()

    private let runtime: YtDlpRuntime
    private let cookieStore: CookieStore
    private let potSettings: PotProviderSettings
    private let failureStore: TerminalFailureStore
    private let logger = Logger(subsystem: "com.siatube.vyra", category: "ytdlp-engine")

    init(runtime: YtDlpRuntime = .shared,
         cookieStore: CookieStore = .shared,
         potSettings: PotProviderSettings = .shared,
         failureStore: TerminalFailureStore = .shared) {
        self.runtime = runtime
        self.cookieStore = cookieStore
        self.potSettings = potSettings
        self.failureStore = failureStore
    }

    /// Bridge arguments shared by every engine operation: the
    /// optional cookie file — present only when the user imported one
    /// AND left the Settings toggle on (see CookieStore; the path is
    /// all that crosses the bridge, never the contents) — and the
    /// POトークン mode (Settings > POトークン）: on-device minting
    /// flag, or the bgutil server base URL.
    private func sessionArguments() -> [String: Any] {
        var arguments: [String: Any] = [:]
        if let url = cookieStore.activeCookieFileURL() {
            arguments["cookiefile"] = url.path
        }
        if potSettings.onDeviceEnabled {
            arguments["pot_ondevice"] = true
        }
        if let potURL = potSettings.activeBaseURL {
            arguments["pot_base_url"] = potURL.absoluteString
        }
        return arguments
    }

    /// Converts a raw yt-dlp failure into its classified form when
    /// the worker.js taxonomy recognizes it: terminal classifications
    /// are remembered for the video (see TerminalFailureStore), and
    /// the error becomes `.classifiedFailure` so the Japanese message
    /// is the UI's primary text. Unclassified errors pass through
    /// unchanged. There is deliberately NO retry/rotation here —
    /// VYRA is a personal app with a single cookie set (しあ
    /// rejected the worker's server-scale account rotation).
    private func classifiedForm(of error: Error, url: URL) -> Error {
        guard let engineError = error as? YtDlpEngineError,
              case .pythonError(let rawMessage) = engineError,
              let failure = YtDlpFailureClassifier.classify(rawMessage)
        else { return error }
        if failure.isTerminal, let videoID = Self.videoID(of: url) {
            failureStore.remember(videoID: videoID, failure: failure)
        }
        return YtDlpEngineError.classifiedFailure(
            message: failure.message, rawDetail: rawMessage)
    }

    /// Strict 11-character YouTube video ID of a URL, when it is one
    /// (the worker's key rule; non-YouTube URLs have no ID and are
    /// never failure-cached).
    static func videoID(of url: URL) -> String? {
        try? URLValidationService.extractVideoID(from: url)
    }

    func versions() async throws -> YtDlpVersions {
        try await runtime.versions()
    }

    func extractMetadata(url: URL) async throws -> YtDlpExtractedInfo {
        _ = try await runtime.versions()
        // Fail fast on a remembered terminal judgement (worker.js:
        // expiresAtまでは yt-dlp を実行しない). The cached message
        // says it is a cached judgement.
        if let videoID = Self.videoID(of: url),
           let record = failureStore.record(for: videoID) {
            throw YtDlpEngineError.classifiedFailure(
                message: TerminalFailureStore.cachedMessage(for: record),
                rawDetail: record.message)
        }
        do {
            return try await extractOnce(url: url)
        } catch {
            throw classifiedForm(of: error, url: url)
        }
    }

    private func extractOnce(url: URL) async throws -> YtDlpExtractedInfo {
        let extraArguments = sessionArguments()
        return try await Task.detached(priority: .userInitiated) { [runtime] in
            var arguments: [String: Any] = ["url": url.absoluteString]
            for (key, value) in extraArguments { arguments[key] = value }
            let response = try runtime.call(function: "extract", arguments: arguments)
            guard let metadata = response.metadata else {
                throw YtDlpEngineError.pythonError(message: "extract returned no metadata")
            }
            // Keep the unprocessed extractor output for Settings >
            // yt-dlp生出力: it is the ground truth for what this
            // session was actually offered.
            if let rawInfo = response.rawInfo {
                RawOutputStore.save(rawJSON: rawInfo, url: url.absoluteString)
            }
            return metadata
        }.value
    }

    func download(jobID: UUID, url: URL, formatID: String, fileName: String,
                  context: YtDlpProcessingContext,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        _ = try await runtime.versions()
        do {
            return try await downloadBody(jobID: jobID, url: url, formatID: formatID,
                                          fileName: fileName, context: context,
                                          progress: progress)
        } catch {
            throw classifiedForm(of: error, url: url)
        }
    }

    private func downloadBody(jobID: UUID, url: URL, formatID: String, fileName: String,
                              context: YtDlpProcessingContext,
                              progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        switch context.processing {
        case .direct, .remux:
            // .direct: the downloaded file is saved as-is (the
            // defensive .remux, which never applies to a single
            // file, takes the same path).
            return try await performDownload(
                jobID: jobID, url: url, formatID: formatID, audioFormatID: nil,
                fileName: fileName, progress: progress)[0]
        case .remuxSingle:
            // HLS: yt-dlp's native downloader delivers MPEG-TS
            // bytes; remux them in-process into the final MP4.
            defer { unregister(jobID: jobID) }
            let sourceFile = try await performDownload(
                jobID: jobID, url: url, formatID: formatID, audioFormatID: nil,
                fileName: "hls-source.media", progress: progress)[0]
            do {
                let outputURL = try makeProcessingOutputDirectory(jobID: jobID)
                    .appendingPathComponent(fileName)
                try await runRemuxSingle(
                    jobID: jobID, url: url, formatID: formatID,
                    inputURL: sourceFile, outputURL: outputURL, progress: progress)
                try? FileManager.default.removeItem(at: sourceFile)
                return outputURL
            } catch {
                try? FileManager.default.removeItem(at: sourceFile)
                throw error
            }
        case .transcode:
            // Download under a neutral temp name first (the bytes
            // may be WebM/VP9/Opus regardless of the final name),
            // then re-encode into the final file name.
            defer { unregister(jobID: jobID) }
            let sourceFile = try await performDownload(
                jobID: jobID, url: url, formatID: formatID, audioFormatID: nil,
                fileName: "transcode-source.media", progress: progress)[0]
            do {
                let outputURL = try makeProcessingOutputDirectory(jobID: jobID)
                    .appendingPathComponent(fileName)
                try await runTranscode(
                    jobID: jobID, url: url, formatIDs: formatID,
                    videoURL: context.isAudioOnly ? nil : sourceFile,
                    audioURL: sourceFile,
                    outputURL: outputURL, context: context, progress: progress)
                try? FileManager.default.removeItem(at: sourceFile)
                return outputURL
            } catch {
                try? FileManager.default.removeItem(at: sourceFile)
                throw error
            }
        }
    }

    /// THE download: one bridge job per selection. Starts the
    /// Python-side job keyed by `jobID` — a single format, or a
    /// split pair when `audioFormatID` is set (the bridge runs both
    /// format downloads inside that one job and aggregates their
    /// progress) — and polls it to completion, returning every file
    /// the job produced ([file] single, [video, audio] split).
    /// There is no Swift-side leg orchestration anymore: yt-dlp
    /// does all downloading, including HLS fragments and retries.
    private func performDownload(jobID: UUID, url: URL, formatID: String, audioFormatID: String?,
                                 fileName: String,
                                 progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> [URL] {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYRA-YtDlp", isDirectory: true)
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: outputDir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var startArguments: [String: Any] = [
            "job_id": jobID.uuidString,
            "url": url.absoluteString,
            "format_id": formatID,
            "output_dir": outputDir.path,
            "filename": fileName,
        ]
        if let audioFormatID {
            startArguments["audio_format_id"] = audioFormatID
        }
        for (key, value) in sessionArguments() { startArguments[key] = value }
        _ = try runtime.call(function: "download_start", arguments: startArguments)

        // Poll the Python-side job until it finishes. Cancellation is
        // cooperative: cancelling this Task asks the bridge to cancel,
        // and the yt-dlp progress hook then aborts the download —
        // including mid-HLS, where the hook fires per fragment.
        while true {
            if Task.isCancelled {
                await cancel(jobID: jobID)
                try? FileManager.default.removeItem(at: outputDir)
                throw YtDlpEngineError.cancelled
            }
            let response = try runtime.call(function: "download_status", arguments: [
                "job_id": jobID.uuidString,
            ])
            guard let job = response.job else {
                throw YtDlpEngineError.pythonError(message: "download_status returned no job")
            }
            switch job.status {
            case "downloading":
                progress(DownloadProgress(
                    downloadedBytes: job.downloadedBytes ?? 0,
                    totalBytes: job.totalBytes,
                    speedBytesPerSecond: job.speed,
                    estimatedRemainingTime: job.eta,
                    state: .downloading))
            case "finished":
                let paths = (job.files?.isEmpty == false) ? job.files! : [job.filename].compactMap { $0 }
                guard !paths.isEmpty else {
                    throw YtDlpEngineError.pythonError(message: "download finished without a file")
                }
                progress(DownloadProgress(
                    downloadedBytes: job.downloadedBytes ?? 0,
                    totalBytes: job.totalBytes ?? job.downloadedBytes,
                    state: .downloading))
                return paths.map { URL(fileURLWithPath: $0) }
            case "cancelled":
                try? FileManager.default.removeItem(at: outputDir)
                throw YtDlpEngineError.cancelled
            case "error":
                let message = job.error ?? "unknown yt-dlp error"
                logger.error("yt-dlp download failed: \(message, privacy: .public)")
                // Persist the full picture (exception + yt-dlp log
                // tail + traceback) so the failure can be diagnosed
                // from Settings > エンジン on device.
                DebugLogStore.appendSession(
                    kind: "download", url: url.absoluteString,
                    formatID: audioFormatID.map { "\(formatID)+\($0)" } ?? formatID,
                    error: message, log: job.log ?? [], traceback: job.traceback)
                throw YtDlpEngineError.pythonError(message: message)
            default:
                throw YtDlpEngineError.pythonError(message: "unknown job status: \(job.status)")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    // MARK: - In-process processing (remux / remuxSingle / transcode)

    /// Remux handle of an in-flight processed download, keyed by the
    /// caller's job ID, so `cancel` can stop it.
    private var remuxJobs: [UUID: FFmpegRemuxJob] = [:]
    /// Transcode handle of an in-flight processed download.
    private var transcodeJobs: [UUID: FFmpegTranscodeJob] = [:]
    private let registryLock = NSLock()

    private func unregister(jobID: UUID) {
        registryLock.lock()
        remuxJobs[jobID] = nil
        transcodeJobs[jobID] = nil
        registryLock.unlock()
    }

    /// Transcoding-phase progress on a fixed pseudo-byte scale (the
    /// transcode reports a fraction, not bytes).
    private static func transcodingProgress(fraction: Double) -> DownloadProgress {
        let clamped = min(max(fraction, 0), 1)
        return DownloadProgress(
            downloadedBytes: Int64(clamped * 1000), totalBytes: 1000,
            state: .downloading, phase: .transcoding)
    }

    /// The directory a remux/transcode writes its output into. The
    /// output takes the final file name; the task manager moves it
    /// into the Library afterwards.
    private func makeProcessingOutputDirectory(jobID: UUID) throws -> URL {
        let fm = FileManager.default
        let outputDir = fm.temporaryDirectory
            .appendingPathComponent("VYRA-YtDlp", isDirectory: true)
            .appendingPathComponent(jobID.uuidString + "-processed", isDirectory: true)
        try? fm.removeItem(at: outputDir)
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        return outputDir
    }

    /// Runs the single-input remux (the HLS path: MPEG-TS bytes in,
    /// MP4 out), translating FFmpeg errors into engine errors and
    /// the debug log (kind "remux").
    private func runRemuxSingle(jobID: UUID, url: URL, formatID: String,
                                inputURL: URL, outputURL: URL,
                                progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let remuxJob = FFmpegRemuxJob()
        registryLock.lock()
        remuxJobs[jobID] = remuxJob
        registryLock.unlock()
        let size = (try? FileManager.default.attributesOfItem(atPath: inputURL.path))?[.size] as? Int64 ?? 0
        progress(DownloadProgress(
            downloadedBytes: size, totalBytes: size,
            state: .downloading, phase: .merging))
        do {
            try await FFmpegRemuxer.remuxSingle(
                inputURL: inputURL, outputURL: outputURL, job: remuxJob)
        } catch let error as FFmpegRemuxError {
            try? FileManager.default.removeItem(at: outputURL)
            switch error {
            case .cancelled:
                throw YtDlpEngineError.cancelled
            case .failed(let message):
                logger.error("remux failed: \(message, privacy: .public)")
                DebugLogStore.appendSession(
                    kind: "remux", url: url.absoluteString,
                    formatID: formatID,
                    error: message, log: [], traceback: nil)
                throw YtDlpEngineError.remuxFailed(message: message)
            }
        }
    }

    /// Runs the transcode for an already-downloaded source (single
    /// file or split pair), translating FFmpeg errors into engine
    /// errors and the debug log (kind "transcode").
    private func runTranscode(jobID: UUID, url: URL, formatIDs: String,
                              videoURL: URL?, audioURL: URL, outputURL: URL,
                              context: YtDlpProcessingContext,
                              progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let transcodeJob = FFmpegTranscodeJob()
        registryLock.lock()
        transcodeJobs[jobID] = transcodeJob
        registryLock.unlock()
        progress(Self.transcodingProgress(fraction: 0))
        do {
            try await FFmpegTranscoder.transcode(
                videoURL: videoURL, audioURL: audioURL, outputURL: outputURL,
                videoBitrate: TranscodeBitrateEstimator.videoBitrate(
                    estimatedBytes: context.estimatedBytes,
                    durationSeconds: context.durationSeconds,
                    height: context.height, isAudioOnly: context.isAudioOnly),
                audioBitrate: TranscodeBitrateEstimator.audioBitrate(
                    isAudioOnly: context.isAudioOnly),
                job: transcodeJob,
                progress: { progress(Self.transcodingProgress(fraction: $0)) })
        } catch let error as FFmpegTranscodeError {
            try? FileManager.default.removeItem(at: outputURL)
            switch error {
            case .cancelled:
                throw YtDlpEngineError.cancelled
            case .failed(let message):
                logger.error("transcode failed: \(message, privacy: .public)")
                DebugLogStore.appendSession(
                    kind: "transcode", url: url.absoluteString,
                    formatID: formatIDs,
                    error: message, log: [], traceback: nil)
                throw YtDlpEngineError.transcodeFailed(message: message)
            }
        }
    }

    func downloadSplit(jobID: UUID, url: URL, videoFormatID: String, audioFormatID: String,
                       fileName: String, context: YtDlpProcessingContext,
                       progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        _ = try await runtime.versions()
        do {
            return try await downloadSplitBody(jobID: jobID, url: url, videoFormatID: videoFormatID,
                                               audioFormatID: audioFormatID, fileName: fileName,
                                               context: context, progress: progress)
        } catch {
            throw classifiedForm(of: error, url: url)
        }
    }

    private func downloadSplitBody(jobID: UUID, url: URL, videoFormatID: String, audioFormatID: String,
                                   fileName: String, context: YtDlpProcessingContext,
                                   progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let processing = context.processing == .direct ? .remux : context.processing
        defer { unregister(jobID: jobID) }

        let fm = FileManager.default
        // ONE bridge job for the pair: yt-dlp downloads both formats
        // (bridge-side), returns [video, audio]. The base name is
        // neutral — the bridge derives the two leg file names from
        // it, and the bytes may be WebM/Opus on the transcode path.
        let files = try await performDownload(
            jobID: jobID, url: url, formatID: videoFormatID, audioFormatID: audioFormatID,
            fileName: "split-source.media", progress: progress)
        guard files.count == 2 else {
            throw YtDlpEngineError.pythonError(
                message: "split download returned \(files.count) file(s), expected 2")
        }
        let videoFile = files[0]
        let audioFile = files[1]
        do {
            let outputURL = try makeProcessingOutputDirectory(jobID: jobID)
                .appendingPathComponent(fileName)
            if processing == .transcode {
                var transcodeContext = context
                transcodeContext.isAudioOnly = false
                try await runTranscode(
                    jobID: jobID, url: url,
                    formatIDs: "\(videoFormatID)+\(audioFormatID)",
                    videoURL: videoFile, audioURL: audioFile,
                    outputURL: outputURL, context: transcodeContext, progress: progress)
            } else {
                let remuxJob = FFmpegRemuxJob()
                registryLock.lock()
                remuxJobs[jobID] = remuxJob
                registryLock.unlock()
                let totalSize = [videoFile, audioFile].reduce(Int64(0)) { sum, file in
                    sum + (((try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int64) ?? 0)
                }
                progress(DownloadProgress(
                    downloadedBytes: totalSize, totalBytes: totalSize,
                    state: .downloading, phase: .merging))
                do {
                    try await FFmpegRemuxer.remux(
                        videoURL: videoFile, audioURL: audioFile,
                        outputURL: outputURL, job: remuxJob)
                } catch let error as FFmpegRemuxError {
                    try? fm.removeItem(at: outputURL)
                    switch error {
                    case .cancelled:
                        throw YtDlpEngineError.cancelled
                    case .failed(let message):
                        logger.error("remux failed: \(message, privacy: .public)")
                        DebugLogStore.appendSession(
                            kind: "remux", url: url.absoluteString,
                            formatID: "\(videoFormatID)+\(audioFormatID)",
                            error: message, log: [], traceback: nil)
                        throw YtDlpEngineError.remuxFailed(message: message)
                    }
                }
            }
            // The pair is consumed by the processing; remove the
            // downloaded leg files.
            try? fm.removeItem(at: videoFile)
            try? fm.removeItem(at: audioFile)
            return outputURL
        } catch {
            try? fm.removeItem(at: videoFile)
            try? fm.removeItem(at: audioFile)
            throw error
        }
    }

    func cancel(jobID: UUID) async {
        // One bridge job per selection since the download rework:
        // cancelling the caller's job ID stops the yt-dlp job itself
        // (its progress hook aborts promptly, HLS fragments
        // included); an in-process remux/transcode stops via its
        // C cancellation flag.
        _ = try? runtime.call(function: "download_cancel", arguments: [
            "job_id": jobID.uuidString,
        ])
        registryLock.lock()
        let remuxJob = remuxJobs[jobID]
        let transcodeJob = transcodeJobs[jobID]
        registryLock.unlock()
        remuxJob?.cancel()
        transcodeJob?.cancel()
    }
}

/// DownloadService adapter: routes a request carrying a yt-dlp
/// `formatID` to the embedded engine. The DownloadTaskManager picks
/// this engine when DirectMediaResolver resolves a `.ytDlp` download.
final class YtDlpDownloadEngine: DownloadService, @unchecked Sendable {
    private let engine: any YtDlpEngineProtocol

    init(engine: any YtDlpEngineProtocol = EmbeddedYtDlpEngine.shared) {
        self.engine = engine
    }

    func download(request: DownloadRequest,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        guard let formatID = request.ytDlpFormatID else {
            throw DownloadError.permissionNotVerified(reason: "yt-dlp formatID missing")
        }
        let context = YtDlpProcessingContext(
            processing: request.ytDlpProcessing
                ?? (request.ytDlpAudioFormatID != nil ? .remux : .direct),
            isAudioOnly: request.ytDlpIsAudioOnly,
            estimatedBytes: request.estimatedBytes,
            durationSeconds: request.durationSeconds,
            height: request.estimatedHeight)
        do {
            if let audioFormatID = request.ytDlpAudioFormatID {
                return try await engine.downloadSplit(
                    jobID: request.taskID, url: request.sourceURL,
                    videoFormatID: formatID, audioFormatID: audioFormatID,
                    fileName: request.fileName, context: context, progress: progress)
            }
            return try await engine.download(
                jobID: request.taskID, url: request.sourceURL,
                formatID: formatID, fileName: request.fileName,
                context: context, progress: progress)
        } catch let error as YtDlpEngineError {
            switch error {
            case .cancelled:
                throw DownloadError.cancelled
            case .classifiedFailure(let message, let rawDetail):
                throw DownloadError.ytDlpClassified(message: message, rawDetail: rawDetail)
            case .runtimeUnavailable(let reason), .pythonError(let reason),
                 .remuxFailed(let reason), .transcodeFailed(let reason):
                throw DownloadError.engineFailed(description: reason)
            }
        }
    }

    func cancel(taskID: UUID) async {
        await engine.cancel(jobID: taskID)
    }
}

/// Deterministic in-memory engine for tests and previews. Never touches
/// Python or the network.
final class MockYtDlpEngine: YtDlpEngineProtocol, @unchecked Sendable {
    var stubInfo: YtDlpExtractedInfo
    var stubFileContent: Data = Data("mock".utf8)
    var extractError: YtDlpEngineError?
    var downloadError: YtDlpEngineError?
    /// (videoFormatID, audioFormatID) of every split download, in order.
    private(set) var splitDownloads: [(video: String, audio: String)] = []
    /// Processing context of every download / split download, in order.
    private(set) var downloadContexts: [YtDlpProcessingContext] = []
    private(set) var splitContexts: [YtDlpProcessingContext] = []
    private(set) var cancelledJobIDs: [UUID] = []
    private let lock = NSLock()

    init(stubInfo: YtDlpExtractedInfo) {
        self.stubInfo = stubInfo
    }

    static var sampleInfo: YtDlpExtractedInfo { .sampleInfo }

    func versions() async throws -> YtDlpVersions {
        YtDlpVersions(python: "3.14.0", ytDlp: "2026.11.23", ytDlpEjs: "0.8.0", jscProvider: true)
    }

    func extractMetadata(url: URL) async throws -> YtDlpExtractedInfo {
        if let extractError { throw extractError }
        return stubInfo
    }

    func download(jobID: UUID, url: URL, formatID: String, fileName: String,
                  context: YtDlpProcessingContext,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        if let downloadError { throw downloadError }
        lock.lock()
        downloadContexts.append(context)
        lock.unlock()
        progress(DownloadProgress(
            downloadedBytes: Int64(stubFileContent.count), totalBytes: Int64(stubFileContent.count),
            state: .downloading,
            phase: context.processing == .transcode ? .transcoding : .downloading))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-ytdlp-\(jobID.uuidString)-\(fileName)")
        try stubFileContent.write(to: fileURL)
        return fileURL
    }

    func downloadSplit(jobID: UUID, url: URL, videoFormatID: String, audioFormatID: String,
                       fileName: String, context: YtDlpProcessingContext,
                       progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        if let downloadError { throw downloadError }
        lock.lock()
        splitDownloads.append((video: videoFormatID, audio: audioFormatID))
        splitContexts.append(context)
        lock.unlock()
        progress(DownloadProgress(
            downloadedBytes: Int64(stubFileContent.count), totalBytes: Int64(stubFileContent.count),
            state: .downloading,
            phase: context.processing == .transcode ? .transcoding : .merging))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-ytdlp-split-\(jobID.uuidString)-\(fileName)")
        try stubFileContent.write(to: fileURL)
        return fileURL
    }

    func cancel(jobID: UUID) async {
        lock.lock()
        cancelledJobIDs.append(jobID)
        lock.unlock()
    }
}
