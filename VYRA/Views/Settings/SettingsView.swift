import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var isPickingSaveFolder = false
    @State private var isPickingCookieFile = false
    @State private var isConfirmingCookieDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    section(title: "アプリ情報") {
                        row("アプリ名", viewModel.appName)
                        row("バージョン", viewModel.versionText)
                        row("フェーズ", "Phase 4 — yt-dlp Engine")
                    }
                    section(title: "エンジン") {
                        row("Python", viewModel.pythonVersionText)
                        row("yt-dlp", viewModel.ytDlpVersionText)
                        row("yt-dlp-ejs", viewModel.ytDlpEjsVersionText)
                        row("JSCプロバイダ", viewModel.jscProviderText)
                        if viewModel.isLoadingEngineInfo {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("エンジン起動中…")
                                    .font(.footnote)
                                    .foregroundStyle(VYRATheme.secondary)
                            }
                        }
                        if let status = viewModel.engineStatusText {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(VYRATheme.secondary)
                        }
                        GlassIconButton(symbolName: "play.circle", label: viewModel.isRunningExtractionTest ? "抽出テスト実行中…" : "抽出テストを実行") {
                            Task {
                                await viewModel.runExtractionTest()
                                viewModel.refreshDebugLog()
                                viewModel.refreshRawOutput()
                            }
                        }
                        .accessibilityIdentifier("extraction-test-button")
                        if let result = viewModel.extractionTestResultText {
                            Text(result)
                                .font(.footnote)
                                .foregroundStyle(VYRATheme.secondary)
                        }
                        GlassIconButton(symbolName: "arrow.down.circle", label: viewModel.isRunningDownloadTest ? "ダウンロードテスト実行中…" : "ダウンロードテストを実行") {
                            Task { await viewModel.runDownloadTest() }
                        }
                        .accessibilityIdentifier("download-test-button")
                        if let result = viewModel.downloadTestResultText {
                            Text(result)
                                .font(.footnote)
                                .foregroundStyle(VYRATheme.secondary)
                                .textSelection(.enabled)
                        }
                        Text("固定のテスト動画URLに対して実際のメタデータ取得を行います。YouTubeはデータセンターIPをブロックすることがあるため、動作確認は実際の回線（ご自宅など）で行ってください。")
                            .font(.footnote)
                            .foregroundStyle(VYRATheme.secondary)
                    }
                    section(title: "yt-dlp生出力") {
                        if let source = viewModel.rawOutputSourceText {
                            Text(source)
                                .font(.footnote)
                                .foregroundStyle(VYRATheme.secondary)
                        }
                        NavigationLink {
                            RawOutputView(viewModel: viewModel)
                        } label: {
                            Label(viewModel.rawOutputText == nil ? "まだ抽出していません" : "最新の生出力を表示",
                                  systemImage: "doc.text")
                                .font(.subheadline)
                                .foregroundStyle(VYRATheme.primaryText)
                        }
                        .accessibilityIdentifier("open-raw-output-button")
                        Text("直近の抽出でyt-dlpが返した生のJSON（formats配列を含む）をそのまま保存しています。形式が少なく表示される場合の切り分けに使えます。")
                            .font(.footnote)
                            .foregroundStyle(VYRATheme.secondary)
                    }
                    section(title: "Cookie") {
                        row("状態", viewModel.cookieStatusText)
                        GlassIconButton(symbolName: "doc.badge.plus", label: "cookies.txt を取り込む") {
                            isPickingCookieFile = true
                        }
                        .accessibilityIdentifier("import-cookies-button")
                        if viewModel.hasCookies {
                            Toggle(isOn: $viewModel.cookieEnabled) {
                                Text("Cookieを使う")
                                    .font(.subheadline)
                                    .foregroundStyle(VYRATheme.primaryText)
                            }
                            .tint(VYRATheme.secondary)
                            .accessibilityIdentifier("cookie-enabled-toggle")
                            GlassIconButton(symbolName: "trash", label: "Cookieを削除") {
                                isConfirmingCookieDelete = true
                            }
                            .accessibilityIdentifier("delete-cookies-button")
                        }
                        if let error = viewModel.cookieErrorText {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(VYRATheme.secondary)
                        }
                        Text("任意設定です。YouTubeにログイン済みのブラウザから書き出した Netscape形式の cookies.txt を取り込むと、抽出とダウンロードがログイン状態のセッションで行われます（形式の選択肢が増える場合があります）。Cookieの内容がログや共有に出ることはありません。")
                            .font(.footnote)
                            .foregroundStyle(VYRATheme.secondary)
                    }
                    section(title: "POトークン") {
                        Picker("取得方式", selection: $viewModel.potMode) {
                            Text("オフ").tag(PotMode.off)
                            Text("オンデバイス").tag(PotMode.onDevice)
                            Text("サーバー").tag(PotMode.server)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("pot-mode-picker")
                        if viewModel.potMode == .server {
                            TextField("http://192.168.1.10:4416", text: $viewModel.potBaseURLText)
                                .font(.subheadline)
                                .foregroundStyle(VYRATheme.primaryText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .accessibilityIdentifier("pot-base-url-field")
                        }
                        if let status = viewModel.potStatusText {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(VYRATheme.secondary)
                        }
                        Text("既定はオンデバイスです。オンデバイスは端末内のJavaScript環境でBotGuardを実行してトークンを生成します（実験的：回線や端末の状態によっては生成できない場合があり、その場合はトークンなしで続行します）。サーバーはLAN内のPC等で稼働する bgutil POトークンサーバーから、同梱プラグイン（HTTPモードのみ）でトークンを取得します。オフにするとトークンなしで取得します。")
                            .font(.footnote)
                            .foregroundStyle(VYRATheme.secondary)
                    }
                    section(title: "デバッグログ") {
                        if let logURL = viewModel.debugLogFileURL {
                            ShareLink(item: logURL) {
                                Label("最新のデバッグログを共有", systemImage: "square.and.arrow.up")
                                    .font(.subheadline)
                                    .foregroundStyle(VYRATheme.primaryText)
                            }
                            .accessibilityIdentifier("share-debug-log-button")
                            if let logText = viewModel.debugLogText {
                                Text(logText)
                                    .font(.caption2)
                                    .foregroundStyle(VYRATheme.secondary)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("debug-log-text")
                            }
                        } else {
                            Text("まだログはありません。エンジンの処理が失敗すると、原因（Pythonのエラーとyt-dlpのログ末尾）がここに保存されます。")
                                .font(.footnote)
                                .foregroundStyle(VYRATheme.secondary)
                        }
                    }
                    section(title: "保存先") {
                        row("保存先", viewModel.saveDestinationText)
                        GlassIconButton(symbolName: "folder", label: "フォルダを選択…") {
                            isPickingSaveFolder = true
                        }
                        .accessibilityIdentifier("choose-save-folder-button")
                        if viewModel.hasExternalSaveFolder {
                            GlassIconButton(symbolName: "arrow.uturn.backward", label: "既定に戻す（アプリ内フォルダ）") {
                                viewModel.resetSaveFolder()
                            }
                            .accessibilityIdentifier("reset-save-folder-button")
                        }
                        if let error = viewModel.saveFolderErrorText {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(VYRATheme.secondary)
                        }
                        Text("選択したフォルダには次回以降のダウンロードが保存されます（既に保存済みのファイルは移動しません）。フォルダにアクセスできない場合はアプリ内フォルダに保存され、その状態がここに表示されます。ダウンロードはアプリ表示中のみ継続します。")
                            .font(.footnote)
                            .foregroundStyle(VYRATheme.secondary)
                    }
                    section(title: "ストレージ") {
                        row("使用量", viewModel.storageUsedText)
                        row("キャッシュ", viewModel.cacheSizeText)
                        GlassIconButton(symbolName: "trash", label: viewModel.cacheCleared ? "キャッシュをクリア済み" : "キャッシュをクリア") {
                            viewModel.clearCache()
                        }
                        .accessibilityIdentifier("clear-cache-button")
                    }
                    section(title: "ライセンス") {
                        Text("VYRAはアプリ内にCPython（Python-Apple-support）とyt-dlp / yt-dlp-ejsを同梱しています。各ライセンスの詳細はリポジトリの Documentation/THIRD_PARTY_LICENSES.md を参照してください。")
                            .font(.footnote)
                            .foregroundStyle(VYRATheme.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .background(VYRATheme.background)
            .navigationTitle("Settings")
            .fileImporter(isPresented: $isPickingSaveFolder,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    viewModel.chooseSaveFolder(url)
                }
            }
            .fileImporter(isPresented: $isPickingCookieFile,
                          allowedContentTypes: [.plainText, .text, .data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    viewModel.importCookieFile(url)
                }
            }
            .confirmationDialog("Cookieを削除しますか？",
                                isPresented: $isConfirmingCookieDelete,
                                titleVisibility: .visible) {
                Button("削除する", role: .destructive) {
                    viewModel.deleteCookies()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("取り込んだ cookies.txt をアプリから削除します。以降の抽出とダウンロードはログインなしのセッションに戻ります。")
            }
            .task {
                viewModel.refreshSaveDestination()
                viewModel.refreshDebugLog()
                viewModel.refreshRawOutput()
                viewModel.refreshCookieStatus()
                await viewModel.loadEngineInfo()
            }
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(VYRATheme.primaryText)
            content()
            Divider().overlay(VYRATheme.secondary.opacity(0.35))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(VYRATheme.secondary)
            Spacer()
            Text(value).foregroundStyle(VYRATheme.primaryText)
        }
        .font(.subheadline)
    }
}
