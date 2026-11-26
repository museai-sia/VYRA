import Foundation
import JavaScriptCore
import os

/// Errors from the embedded yt-dlp engine. `userMessage` is shown in the
/// UI; the raw Python error is kept for logs only.
enum YtDlpEngineError: Error, Equatable, Sendable {
    case runtimeUnavailable(reason: String)
    case pythonError(message: String)
    /// A failure the classifier (worker.js taxonomy) understood:
    /// `message` is the primary Japanese user message (classified or
    /// cached-judgement), `rawDetail` the raw yt-dlp text kept for
    /// the detail line / debug log.
    case classifiedFailure(message: String, rawDetail: String)
    /// The in-process FFmpeg remux of a split pair failed; the message
    /// is the real FFmpeg error (stage + description).
    case remuxFailed(message: String)
    /// The in-process FFmpeg transcode failed; the message is the
    /// real FFmpeg error (stage + description).
    case transcodeFailed(message: String)
    case cancelled

    var userMessage: String {
        switch self {
        case .runtimeUnavailable:
            return "yt-dlpエンジンを起動できませんでした。アプリを再起動して再試行してください。"
        case .pythonError:
            return "yt-dlpで情報を取得できませんでした。URLが正しいか確認して再試行してください。"
        case .classifiedFailure(let message, _):
            return message
        case .remuxFailed:
            return "映像と音声の結合に失敗しました。"
        case .transcodeFailed:
            return "形式の変換に失敗しました。"
        case .cancelled:
            return "キャンセルしました。"
        }
    }
}

// MARK: - Bridge DTOs (mirror vyra_bridge.py's JSON)

struct YtDlpVersions: Codable, Equatable, Sendable {
    var python: String
    var ytDlp: String
    var ytDlpEjs: String?
    var jscProvider: Bool

    enum CodingKeys: String, CodingKey {
        case python
        case ytDlp = "yt_dlp"
        case ytDlpEjs = "yt_dlp_ejs"
        case jscProvider = "jsc_provider"
    }
}

struct YtDlpFormatInfo: Codable, Equatable, Sendable {
    var formatID: String?
    var ext: String?
    var vcodec: String?
    var acodec: String?
    var height: Int?
    var fps: Double?
    var filesize: Int64?
    var filesizeApprox: Int64?
    var formatNote: String?
    var singleFile: Bool
    var requiresMerge: Bool
    var width: Int? = nil
    var tbr: Double? = nil
    var abr: Double? = nil
    /// yt-dlp protocol ("https", "m3u8_native", ...). HLS formats
    /// are MPEG-TS segment data even when named .mp4; selection
    /// offers combined HLS formats (their downloads are remuxed
    /// from TS to MP4 in-process) and excludes HLS video-only
    /// formats, which cannot be paired across protocols.
    var protocolName: String? = nil
    /// Direct format URL when yt-dlp resolved one; carries the
    /// googlevideo `expire` parameter used for staleness checks
    /// (see FormatURLExpiry). Downloads never reuse it — the bridge
    /// re-resolves by format_id — it exists for the expiry guard.
    var url: String? = nil

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case ext, vcodec, acodec, height, fps, filesize
        case filesizeApprox = "filesize_approx"
        case formatNote = "format_note"
        case singleFile = "single_file"
        case requiresMerge = "requires_merge"
        case width, tbr, abr, url
        case protocolName = "protocol"
    }
}

struct YtDlpExtractedInfo: Codable, Equatable, Sendable {
    var id: String?
    var title: String
    var uploader: String?
    var duration: Int?
    var thumbnail: String?
    var published: String?
    var description: String?
    var webpageURL: String?
    var extractor: String?
    var formats: [YtDlpFormatInfo]

    enum CodingKeys: String, CodingKey {
        case id, title, uploader, duration, thumbnail, published, description, extractor, formats
        case webpageURL = "webpage_url"
    }
}

extension YtDlpExtractedInfo {
    /// Deterministic fixture mirroring a typical YouTube extraction
    /// (combined 360p mp4, video-only 1080p mp4, audio-only m4a).
    /// Used by tests and previews; never presented as real data.
    static var sampleInfo: YtDlpExtractedInfo {
        YtDlpExtractedInfo(
            id: "dQw4w9WgXcQ",
            title: "Sample Video",
            uploader: "Sample Channel",
            duration: 212,
            thumbnail: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
            published: "2009-10-25",
            description: "A sample.",
            webpageURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            extractor: "Youtube",
            formats: [
                YtDlpFormatInfo(formatID: "18", ext: "mp4", vcodec: "avc1.42001E", acodec: "mp4a.40.2",
                                height: 360, fps: 30, filesize: 10_000_000, filesizeApprox: nil,
                                formatNote: "360p", singleFile: true, requiresMerge: false),
                YtDlpFormatInfo(formatID: "137", ext: "mp4", vcodec: "avc1.640028", acodec: "none",
                                height: 1080, fps: 30, filesize: nil, filesizeApprox: 40_000_000,
                                formatNote: "1080p", singleFile: false, requiresMerge: true),
                YtDlpFormatInfo(formatID: "140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2",
                                height: nil, fps: nil, filesize: 3_000_000, filesizeApprox: nil,
                                formatNote: "medium", singleFile: true, requiresMerge: false),
            ])
    }
}

/// Pure mapping from yt-dlp output to VYRA's metadata model. Only
/// formats yt-dlp actually returned are mapped. Containers are NOT
/// narrowed to what the saved file will be: WebM sources are carried
/// through and transcoded to MP4 by the bundled FFmpeg libraries, so
/// every container yt-dlp serves (mp4/m4a/webm) is mapped.
enum YtDlpMetadataMapper {
    static let supportedContainers: Set<String> = ["mp4", "m4a", "webm"]

    static func metadata(from info: YtDlpExtractedInfo, sourceURL: URL) -> VideoMetadata {
        let formats: [AvailableMediaFormat] = info.formats.compactMap { format in
            guard let ext = format.ext?.lowercased(),
                  supportedContainers.contains(ext),
                  let formatID = format.formatID else { return nil }
            let isAudioOnly = (format.vcodec ?? "none") == "none"
            let qualityLabel: String?
            if isAudioOnly {
                qualityLabel = nil
            } else if let height = format.height {
                qualityLabel = "\(height)p"
            } else {
                qualityLabel = nil
            }
            return AvailableMediaFormat(
                container: ext,
                qualityLabel: qualityLabel,
                isAudioOnly: isAudioOnly,
                formatID: formatID,
                requiresMerge: format.requiresMerge,
                videoCodec: format.vcodec,
                audioCodec: format.acodec,
                estimatedFileSize: format.filesize ?? format.filesizeApprox,
                height: format.height,
                fps: format.fps,
                totalBitrate: format.tbr,
                protocolName: format.protocolName,
                formatURL: format.url
            )
        }
        let published = info.published.flatMap { VideoMetadata.parseISO8601Date("\($0)T00:00:00Z") }
        return VideoMetadata(
            id: info.id ?? sourceURL.absoluteString,
            title: info.title,
            creatorName: info.uploader ?? "",
            sourceName: "YouTube",
            thumbnailURL: info.thumbnail.flatMap(URL.init(string:)),
            durationSeconds: info.duration ?? 0,
            publishedAt: published,
            description: info.description,
            sourceURL: sourceURL,
            availableFormats: formats
        )
    }
}

// MARK: - JavaScriptCore runner (the `_host.run_js` implementation)

/// Evaluates the yt-dlp-ejs solver scripts in a fresh JSContext and
/// returns what they wrote to console.log — the same contract the
/// Python `_host` module expects.
enum JSCRunner {
    static func run(_ script: String) -> (output: String, error: String?) {
        guard let context = JSContext() else { return ("", "Could not create JSContext") }
        var output = ""
        var error: String?

        let log: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            output += args.map { $0.toString() ?? "" }.joined(separator: " ") + "\n"
        }
        let console = JSValue(newObjectIn: context)!
        console.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        context.exceptionHandler = { _, exception in
            error = exception?.toString() ?? "Unknown JavaScript error"
        }
        context.evaluateScript(script)
        return (output, error)
    }
}

private let vyraJSRunner: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>? = { code, isError in
    guard let code else { return nil }
    let (output, error) = JSCRunner.run(String(cString: code))
    if let error {
        isError?.pointee = 1
        return strdup(error)
    }
    return strdup(output)
}

// MARK: - Runtime (interpreter lifecycle + JSON calls)

/// Owns the embedded CPython interpreter. Initialization happens once,
/// lazily, on a dedicated thread with a large stack (yt-dlp recurses
/// deeply; default worker stacks are too small). Every bridge call runs
/// on a fresh such thread, as CPython requires consistent GIL handling
/// rather than a specific thread.
final class YtDlpRuntime: @unchecked Sendable {
    static let shared = YtDlpRuntime()

    private let logger = Logger(subsystem: "com.siatube.vyra", category: "ytdlp-runtime")
    private let stateLock = NSLock()
    private var initializationError: String?
    private var didInitialize = false
    private var initTask: Task<YtDlpVersions, Error>?

    private init() {}

    /// Whether the Python resources are present in the app bundle.
    static var resourcesPresent: Bool {
        guard let resourcePath = Bundle.main.resourcePath else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: resourcePath + "/pybridge/vyra_bridge.py")
            && fm.fileExists(atPath: resourcePath + "/app_packages/yt_dlp")
            && fm.fileExists(atPath: resourcePath + "/python/lib/python3.14")
    }

    /// Starts the interpreter (once) and returns engine versions.
    func versions() async throws -> YtDlpVersions {
        if let initTask {
            return try await initTask.value
        }
        let task = Task.detached(priority: .userInitiated) { [self] in
            try ensureInitialized()
            let response = try call(function: "configure", arguments: [
                "cache_dir": cacheDirectory.path,
            ])
            guard let versions = response.versions else {
                throw YtDlpEngineError.pythonError(message: "versions missing in bridge response")
            }
            return versions
        }
        initTask = task
        return try await task.value
    }

    /// Calls `vyra_bridge.<function>(json)` and decodes the envelope.
    func call(function: String, arguments: [String: Any]) throws -> BridgeResponse {
        try ensureInitialized()
        let json = try Self.encode(arguments)
        let raw = try Self.runOnPythonThread { () -> String in
            guard let pointer = vyra_python_call(function, json) else {
                throw YtDlpEngineError.pythonError(message: "bridge returned no output")
            }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        let response = try BridgeResponse.decode(raw)
        // POT failures happen INSIDE otherwise-successful calls (the
        // POT director swallows provider errors and extraction
        // continues without a token), so surface them in the debug
        // log with kind 'pot' — otherwise an on-device mint failure
        // would be invisible on device.
        if response.ok, let events = response.potEvents,
           events.contains(where: { $0.hasPrefix("ERROR:") }) {
            DebugLogStore.appendSession(
                kind: "pot",
                url: arguments["url"] as? String,
                formatID: arguments["format_id"] as? String,
                error: events.first(where: { $0.hasPrefix("ERROR:") }) ?? "POT failure",
                log: events,
                traceback: nil)
        }
        if !response.ok {
            // Never let the real cause vanish: persist it (with the
            // yt-dlp log tail) before surfacing the error.
            DebugLogStore.appendSession(
                kind: function,
                url: arguments["url"] as? String,
                formatID: arguments["format_id"] as? String,
                error: response.error ?? "unknown Python error",
                log: response.log ?? [],
                traceback: response.traceback)
            throw YtDlpEngineError.pythonError(message: response.error ?? "unknown Python error")
        }
        return response
    }

    // MARK: Private

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("yt-dlp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func ensureInitialized() throws {
        stateLock.lock()
        if didInitialize {
            let error = initializationError
            stateLock.unlock()
            if let error { throw YtDlpEngineError.runtimeUnavailable(reason: error) }
            return
        }
        stateLock.unlock()

        var failure: String?
        if !Self.resourcesPresent {
            failure = "Python resources are not bundled in this build"
        } else if let resourcePath = Bundle.main.resourcePath {
            do {
                try Self.runOnPythonThread {
                    vyra_python_set_js_runner(vyraJSRunner)
                    vyraRegisterPotRunners()
                    if let error = vyra_python_initialize(resourcePath) {
                        let message = String(cString: error)
                        free(error)
                        throw YtDlpEngineError.runtimeUnavailable(reason: message)
                    }
                }
            } catch let error as YtDlpEngineError {
                failure = error.userMessage
                if case .runtimeUnavailable(let reason) = error { failure = reason }
            } catch {
                failure = error.localizedDescription
            }
        } else {
            failure = "Bundle resource path unavailable"
        }

        stateLock.lock()
        didInitialize = true
        initializationError = failure
        stateLock.unlock()
        if let failure {
            logger.error("Python init failed: \(failure, privacy: .public)")
            throw YtDlpEngineError.runtimeUnavailable(reason: failure)
        }
    }

    private static func encode(_ arguments: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs `body` on a dedicated thread with a 16 MB stack and waits.
    private static func runOnPythonThread<T>(_ body: @escaping () throws -> T) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.result = Result { try body() }
            semaphore.signal()
        }
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
        semaphore.wait()
        return try box.result!.get()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// The JSON envelope every vyra_bridge function returns.
struct BridgeResponse: Decodable {
    var ok: Bool
    var error: String?
    var log: [String]?
    var traceback: String?
    var versions: YtDlpVersions?
    var metadata: YtDlpExtractedInfo?
    /// Full unprocessed yt-dlp info JSON from `extract`, for the
    /// raw-output store (Settings > yt-dlp生出力）.
    var rawInfo: String?
    var hasCookiefile: Bool?
    var cookiefile: String?
    /// The bgutil base URL _base_opts wired into the
    /// youtubepot-bgutilhttp settings namespace (opts_probe only).
    var potBgutilBaseURL: String?
    /// Whether _base_opts carried youtubepot-vyraondevice settings
    /// (opts_probe only).
    var potOndeviceSettings: Bool?
    var potPluginAvailable: Bool?
    /// PROVIDER_NAMEs registered in yt-dlp's POT provider registry
    /// after the plugin loader's import (opts_probe only).
    var potProviders: [String]?
    var potBgutilRegistered: Bool?
    var potOndeviceRegistered: Bool?
    /// Must be false in the app: the bgutil script-mode module
    /// (subprocess-based) is removed at bootstrap time.
    var potScriptModulePresent: Bool?
    /// POT provider diagnostics drained from the bridge (extract /
    /// download_status); failures are prefixed "ERROR:".
    var potEvents: [String]?
    /// pot_probe only: is_available() with settings off / on.
    var potAvailableOff: Bool?
    var potAvailableOn: Bool?
    /// pot_mint_fixture only.
    var poToken: String?
    var potBackend: String?
    var snapshotLen: Int?
    var potHasMinterFn: Bool?
    var output: String?
    var playerURL: String?
    var results: [String: [String: String]]?
    var job: JobStatus?

    enum CodingKeys: String, CodingKey {
        case ok, error, log, traceback, versions, metadata, output, results, job
        case rawInfo = "raw_info"
        case hasCookiefile = "has_cookiefile"
        case cookiefile
        case potBgutilBaseURL = "pot_bgutil_base_url"
        case potOndeviceSettings = "pot_ondevice_settings"
        case potPluginAvailable = "pot_plugin_available"
        case potProviders = "pot_providers"
        case potBgutilRegistered = "pot_bgutil_registered"
        case potOndeviceRegistered = "pot_ondevice_registered"
        case potScriptModulePresent = "pot_script_module_present"
        case potEvents = "pot_events"
        case potAvailableOff = "pot_available_off"
        case potAvailableOn = "pot_available_on"
        case poToken = "po_token"
        case potBackend = "pot_backend"
        case snapshotLen = "snapshot_len"
        case potHasMinterFn = "pot_has_minter_fn"
        case playerURL = "player_url"
    }

    struct JobStatus: Decodable, Equatable {
        var status: String
        var downloadedBytes: Int64?
        var totalBytes: Int64?
        var speed: Double?
        var eta: Double?
        var filename: String?
        /// Every file the job produced: the single file for a
        /// single-format job, [video, audio] for a split job (one
        /// bridge job per selection; see vyra_bridge.py).
        var files: [String]?
        var error: String?
        var log: [String]?
        var traceback: String?

        enum CodingKeys: String, CodingKey {
            case status, speed, eta, filename, error, log, traceback, files
            case downloadedBytes = "downloaded_bytes"
            case totalBytes = "total_bytes"
        }
    }

    static func decode(_ raw: String) throws -> BridgeResponse {
        guard let data = raw.data(using: .utf8) else {
            throw YtDlpEngineError.pythonError(message: "bridge returned non-UTF8 output")
        }
        do {
            return try JSONDecoder().decode(BridgeResponse.self, from: data)
        } catch {
            throw YtDlpEngineError.pythonError(message: "bridge returned malformed JSON: \(raw.prefix(200))")
        }
    }
}

extension BridgeResponse.JobStatus {
    /// Custom decode so the byte counts go through the lenient
    /// path below: a fractional count must degrade to a truncated
    /// integer, never fail the whole status response (that failure
    /// killed an HLS download mid-flight — the status poll threw
    /// and the job was abandoned).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        downloadedBytes = try container.decodeLenientInt64IfPresent(forKey: .downloadedBytes)
        totalBytes = try container.decodeLenientInt64IfPresent(forKey: .totalBytes)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed)
        eta = try container.decodeIfPresent(Double.self, forKey: .eta)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        files = try container.decodeIfPresent([String].self, forKey: .files)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        log = try container.decodeIfPresent([String].self, forKey: .log)
        traceback = try container.decodeIfPresent(String.self, forKey: .traceback)
    }
}

private extension KeyedDecodingContainer {
    /// Byte counts are JSON numbers on the wire, and yt-dlp reports
    /// HLS/fragment totals as fractional estimates (e.g.
    /// 34226326.5882353); a strict Int64 decode throws on those.
    /// Accept any finite number and truncate toward zero.
    func decodeLenientInt64IfPresent(forKey key: Key) throws -> Int64? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return nil }
        let value = try decode(Double.self, forKey: key)
        guard value.isFinite else { return nil }
        if value >= 9_223_372_036_854_775_807.0 { return .max }
        if value <= -9_223_372_036_854_775_808.0 { return .min }
        return Int64(value)
    }
}
