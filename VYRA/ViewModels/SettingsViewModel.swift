import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    let appName: String = "VYRA"
    let versionText: String = "1.0.0 (Phase 4)"

    // MARK: - Save destination (保存先)

    /// Where new downloads are saved; backed by SaveDestinationStore.
    let destinationStore: SaveDestinationStore
    private(set) var saveDestinationText: String = ""
    private(set) var hasExternalSaveFolder = false
    var saveFolderErrorText: String?

    func refreshSaveDestination() {
        saveDestinationText = destinationStore.displayText
        hasExternalSaveFolder = destinationStore.hasExternalFolder
    }

    /// Handles a folder picked with the document picker: the picker
    /// grants security-scoped access to the URL for this callback, so
    /// the bookmark is created inside that window.
    func chooseSaveFolder(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try destinationStore.setExternalFolder(url)
            saveFolderErrorText = nil
        } catch {
            saveFolderErrorText = "フォルダを保存先として登録できませんでした: \(error.localizedDescription)"
        }
        refreshSaveDestination()
    }

    func resetSaveFolder() {
        destinationStore.resetToAppFolder()
        saveFolderErrorText = nil
        refreshSaveDestination()
    }

    var cacheSizeText: String = "12.4 MB（モック）"
    var storageUsedText: String = "0 MB"
    private(set) var cacheCleared: Bool = false

    // MARK: - yt-dlp engine diagnostics (Phase 4)

    /// Well-known stable video used by the in-app extraction self-test.
    static let extractionTestURL = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!

    private let engine: any YtDlpEngineProtocol
    var pythonVersionText: String = "未確認"
    var ytDlpVersionText: String = "未確認"
    var ytDlpEjsVersionText: String = "未確認"
    var jscProviderText: String = "未確認"
    var engineStatusText: String?
    private(set) var isLoadingEngineInfo = false
    private(set) var isRunningExtractionTest = false
    var extractionTestResultText: String?
    private(set) var isRunningDownloadTest = false
    var downloadTestResultText: String?
    /// Latest persisted yt-dlp debug log (Settings > エンジン viewer).
    private(set) var debugLogText: String?
    private(set) var debugLogFileURL: URL?

    // MARK: - yt-dlp raw output （生出力）

    /// Newest stored raw extraction (Settings > yt-dlp生出力）.
    private(set) var rawOutputText: String?
    private(set) var rawOutputFileURL: URL?
    private(set) var rawOutputSourceText: String?

    func refreshRawOutput() {
        rawOutputFileURL = RawOutputStore.latestFileURL()
        rawOutputText = RawOutputStore.latestText()
        if let info = RawOutputStore.latestInfo() {
            rawOutputSourceText = "\(info.url)\n\(info.time)"
        } else {
            rawOutputSourceText = nil
        }
    }

    // MARK: - Cookies (optional, Settings > Cookie)

    let cookieStore: CookieStore
    private(set) var cookieStatusText: String = "未設定"
    private(set) var hasCookies = false
    var cookieErrorText: String?

    /// The Settings toggle. Setting it only flips the gate in
    /// CookieStore; engine calls consult the store on every call, so
    /// the change takes effect on the next extraction/download.
    /// OFF simply means "no cookies" — a normal option, nothing more.
    var cookieEnabled: Bool {
        get { cookieStore.isEnabled }
        set {
            cookieStore.isEnabled = newValue
            refreshCookieStatus()
        }
    }

    func refreshCookieStatus() {
        if let status = cookieStore.status {
            hasCookies = true
            let dateText = status.importedAt.formatted(
                date: .numeric, time: .omitted)
            cookieStatusText = "設定済み（\(status.fileName) / \(dateText) 取り込み / \(status.entryCount) 件）"
        } else {
            hasCookies = false
            cookieStatusText = "未設定"
        }
    }

    /// Handles a cookies.txt picked with the document picker: the
    /// picker grants security-scoped access for this callback, so the
    /// copy into the store happens inside that window. Cookie values
    /// are never shown — only validation errors surface here.
    func importCookieFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            _ = try cookieStore.importCookies(from: url)
            cookieErrorText = nil
        } catch let error as CookieStore.ImportError {
            cookieErrorText = error.userMessage
        } catch {
            cookieErrorText = error.localizedDescription
        }
        refreshCookieStatus()
    }

    func deleteCookies() {
        cookieStore.deleteCookies()
        cookieErrorText = nil
        refreshCookieStatus()
    }

    // MARK: - PO token provider (optional, Settings > POトークン）

    let potSettings: PotProviderSettings
    var potBaseURLText: String {
        get { potSettings.baseURLString }
        set {
            potSettings.baseURLString = newValue
            refreshPotStatus()
        }
    }
    var potMode: PotMode {
        get { potSettings.mode }
        set {
            potSettings.mode = newValue
            refreshPotStatus()
        }
    }
    private(set) var potStatusText: String?

    func refreshPotStatus() {
        switch potSettings.mode {
        case .off:
            potStatusText = nil
        case .onDevice:
            potStatusText = "有効: POトークンを端末内で生成します（実験的）。生成に失敗した場合はトークンなしで続行し、失敗はデバッグログ（pot）に残ります。"
        case .server:
            if potSettings.hasInvalidBaseURLText {
                potStatusText = "URLの形式が正しくありません（http:// または https:// で始まるアドレスを入力してください）。"
            } else if potSettings.activeBaseURL != nil {
                potStatusText = "有効: 同梱の bgutil プラグイン（HTTPモード）がサーバーからトークンを取得します。"
            } else {
                potStatusText = "サーバーのアドレスを入力してください。"
            }
        }
    }

    init(engine: any YtDlpEngineProtocol = EmbeddedYtDlpEngine.shared,
         destinationStore: SaveDestinationStore = .shared,
         cookieStore: CookieStore = .shared,
         potSettings: PotProviderSettings = .shared) {
        self.engine = engine
        self.destinationStore = destinationStore
        self.cookieStore = cookieStore
        self.potSettings = potSettings
        refreshSaveDestination()
        refreshCookieStatus()
        refreshPotStatus()
    }

    /// Boots the embedded engine (once) and shows the REAL versions it
    /// reports — nothing is hard-coded.
    func loadEngineInfo() async {
        guard !isLoadingEngineInfo else { return }
        isLoadingEngineInfo = true
        defer { isLoadingEngineInfo = false }
        do {
            let versions = try await engine.versions()
            pythonVersionText = versions.python
            ytDlpVersionText = versions.ytDlp
            ytDlpEjsVersionText = versions.ytDlpEjs ?? "不明"
            jscProviderText = versions.jscProvider ? "有効" : "無効"
            engineStatusText = nil
        } catch let error as YtDlpEngineError {
            engineStatusText = error.userMessage
        } catch {
            engineStatusText = error.localizedDescription
        }
    }

    /// Runs a real extraction against the fixed test URL and reports the
    /// title, how many formats yt-dlp returned, and how many of them are
    /// downloadable single-file formats — or the raw error on failure.
    /// This is the intended on-device acceptance check: CI/datacenter
    /// IPs are often blocked by YouTube, a home line usually is not.
    func runExtractionTest() async {
        guard !isRunningExtractionTest else { return }
        isRunningExtractionTest = true
        extractionTestResultText = nil
        defer { isRunningExtractionTest = false }
        do {
            let info = try await engine.extractMetadata(url: Self.extractionTestURL)
            let metadata = YtDlpMetadataMapper.metadata(from: info, sourceURL: Self.extractionTestURL)
            let downloadable = MediaFormatService.options(from: metadata).count
            extractionTestResultText =
                "成功: 「\(info.title)」 / 形式 \(info.formats.count) 件（ダウンロード可能 \(downloadable) 件）"
        } catch let error as YtDlpEngineError {
            switch error {
            case .pythonError(let message):
                extractionTestResultText = "失敗: \(message)"
            case .runtimeUnavailable(let reason):
                extractionTestResultText = "失敗: \(reason)"
            case .remuxFailed(let message):
                extractionTestResultText = "失敗: \(message)"
            case .transcodeFailed(let message):
                extractionTestResultText = "失敗: \(message)"
            case .classifiedFailure(let message, _):
                extractionTestResultText = "失敗: \(message)"
            case .cancelled:
                extractionTestResultText = "失敗: キャンセルされました"
            }
        } catch {
            extractionTestResultText = "失敗: \(error.localizedDescription)"
        }
    }

    /// One-tap acceptance test for downloads: extracts the fixed test
    /// video, downloads its best MP4 option (the same selection rule
    /// the real flow uses — a split pair when that is the best, with
    /// the real remux) into a temporary file, and
    /// reports the byte count — or the FULL Python error on failure.
    /// Together with the debug log below, this is how a download
    /// failure on device gets diagnosed instead of guessed at.
    func runDownloadTest() async {
        guard !isRunningDownloadTest else { return }
        isRunningDownloadTest = true
        downloadTestResultText = nil
        defer {
            isRunningDownloadTest = false
            refreshDebugLog()
        }
        do {
            let info = try await engine.extractMetadata(url: Self.extractionTestURL)
            let metadata = YtDlpMetadataMapper.metadata(from: info, sourceURL: Self.extractionTestURL)
            let options = MediaFormatService.options(from: metadata)
            guard let option = MediaFormatService.selectOption(in: options, format: .mp4, quality: .original),
                  let formatID = option.ytDlpFormatID else {
                downloadTestResultText = "失敗: ダウンロード可能なMP4形式がありませんでした"
                return
            }
            let fileURL: URL
            let formatText: String
            let context = YtDlpProcessingContext(
                processing: option.processing,
                isAudioOnly: option.isAudio,
                estimatedBytes: option.estimatedFileSize,
                durationSeconds: info.duration,
                height: option.heightPixels)
            if let audioFormatID = option.audioYtDlpFormatID {
                // The best MP4 is a split pair: download both streams
                // and merge (remux or transcode), exactly like the
                // real download flow.
                fileURL = try await engine.downloadSplit(
                    jobID: UUID(), url: Self.extractionTestURL,
                    videoFormatID: formatID, audioFormatID: audioFormatID,
                    fileName: "vyra-download-test.mp4", context: context,
                    progress: { _ in })
                formatText = "形式ID \(formatID)+\(audioFormatID)（分割・結合）"
            } else {
                fileURL = try await engine.download(
                    jobID: UUID(), url: Self.extractionTestURL, formatID: formatID,
                    fileName: "vyra-download-test.mp4", context: context,
                    progress: { _ in })
                formatText = "形式ID \(formatID)"
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int64
            let byteText = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "サイズ不明"
            downloadTestResultText =
                "成功: \(fileURL.lastPathComponent) / \(byteText)（\(formatText)）"
            try? FileManager.default.removeItem(at: fileURL)
        } catch let error as YtDlpEngineError {
            switch error {
            case .pythonError(let message):
                downloadTestResultText = "失敗: \(message)"
            case .runtimeUnavailable(let reason):
                downloadTestResultText = "失敗: \(reason)"
            case .remuxFailed(let message):
                downloadTestResultText = "失敗: 結合エラー \(message)"
            case .transcodeFailed(let message):
                downloadTestResultText = "失敗: 変換エラー \(message)"
            case .classifiedFailure(let message, _):
                downloadTestResultText = "失敗: \(message)"
            case .cancelled:
                downloadTestResultText = "失敗: キャンセルされました"
            }
        } catch {
            downloadTestResultText = "失敗: \(error.localizedDescription)"
        }
    }

    /// Reloads the newest persisted debug log for the viewer/share UI.
    func refreshDebugLog() {
        debugLogFileURL = DebugLogStore.latestLogURL()
        debugLogText = DebugLogStore.latestLogText()
    }

    func clearCache() {
        cacheSizeText = "0 MB（モック）"
        cacheCleared = true
    }

    func updateStorageUsed(mockBytes: Int64) {
        storageUsedText = ByteCountFormatter.string(fromByteCount: mockBytes, countStyle: .file)
    }

    /// Real Library usage from disk (Phase 3).
    func refreshStorageUsed(from storage: FileStorageService = .appDefault) {
        storageUsedText = ByteCountFormatter.string(fromByteCount: storage.totalLibraryBytes, countStyle: .file)
    }
}
