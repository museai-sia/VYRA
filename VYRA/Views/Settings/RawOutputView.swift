import SwiftUI

/// Viewer for the newest stored yt-dlp raw extraction output
/// (Settings > yt-dlp生出力）. The full info JSON — formats array
/// included — is shown verbatim in monospaced text so exactly what
/// the session was offered can be inspected and shared for diagnosis.
struct RawOutputView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var copied = false

    var body: some View {
        Group {
            if let text = viewModel.rawOutputText {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let source = viewModel.rawOutputSourceText {
                            Text(source)
                                .font(.footnote)
                                .foregroundStyle(VYRATheme.secondary)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 16) {
                            if let fileURL = viewModel.rawOutputFileURL {
                                ShareLink(item: fileURL) {
                                    Label("共有", systemImage: "square.and.arrow.up")
                                        .font(.subheadline)
                                        .foregroundStyle(VYRATheme.primaryText)
                                }
                                .accessibilityIdentifier("share-raw-output-button")
                            }
                            Button {
                                UIPasteboard.general.string = text
                                copied = true
                            } label: {
                                Label(copied ? "コピーしました" : "コピー",
                                      systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.subheadline)
                                    .foregroundStyle(VYRATheme.primaryText)
                            }
                            .accessibilityIdentifier("copy-raw-output-button")
                        }
                        Text(text)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(VYRATheme.primaryText)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("raw-output-text")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("まだ抽出していません")
                        .font(.headline)
                        .foregroundStyle(VYRATheme.primaryText)
                    Text("動画の情報を取得すると、yt-dlpが返した生のJSON（formats配列を含む）がここに保存されます。")
                        .font(.footnote)
                        .foregroundStyle(VYRATheme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .background(VYRATheme.background)
        .navigationTitle("yt-dlp生出力")
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.refreshRawOutput() }
    }
}
