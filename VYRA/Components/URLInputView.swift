import SwiftUI
import UIKit

/// URL entry placed directly on the black background: no card, no nested
/// fills — just text, small glass actions and a hairline divider.
struct URLInputView: View {
    @Bindable var viewModel: HomeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                "動画のURLを入力",
                text: $viewModel.urlString
            )
            .font(.body)
            .foregroundStyle(VYRATheme.primaryText)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("url-input")
            .onChange(of: viewModel.urlString) { _, _ in
                if viewModel.errorMessage != nil { viewModel.errorMessage = nil }
            }

            Divider().overlay(VYRATheme.secondary.opacity(0.5))

            HStack(spacing: 10) {
                GlassIconButton(symbolName: "doc.on.clipboard", label: "貼り付け") {
                    viewModel.paste(from: UIPasteboard.general.string)
                }
                .accessibilityIdentifier("paste-button")
                GlassIconButton(symbolName: "xmark", label: "クリア") {
                    viewModel.clear()
                }
                .accessibilityIdentifier("clear-button")
                Spacer()
            }

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(VYRATheme.secondary)
                    .accessibilityIdentifier("url-error")
            }
        }
    }
}
