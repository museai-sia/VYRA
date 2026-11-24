import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    section(title: "アプリ情報") {
                        row("アプリ名", viewModel.appName)
                        row("バージョン", viewModel.versionText)
                        row("フェーズ", "Phase 3 — Download / Library")
                    }
                    section(title: "保存先") {
                        row("保存先", viewModel.saveLocationText)
                        Text("ダウンロードしたファイルはアプリのDocuments内に保存され、Libraryで管理します。ダウンロードはアプリ表示中のみ継続します。")
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
                        Text("VYRAは外部ライブラリを使用していません。SwiftUI、SwiftData、SF SymbolsなどApple標準フレームワークのみで構成されています。")
                            .font(.footnote)
                            .foregroundStyle(VYRATheme.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .background(VYRATheme.background)
            .navigationTitle("Settings")
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
