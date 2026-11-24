import SwiftUI

/// Format + quality selection. Embedded in Video Preview and also usable
/// standalone; selection state lives entirely in the view model.
struct FormatSelectionView: View {
    @Bindable var viewModel: VideoPreviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("保存形式")
                    .font(.headline)
                    .foregroundStyle(VYRATheme.primaryText)
                ForEach(DownloadFormat.allCases) { format in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            viewModel.selectedFormat = format
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(format.displayName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(VYRATheme.primaryText)
                                Text(format.detailText)
                                    .font(.caption)
                                    .foregroundStyle(VYRATheme.secondary)
                            }
                            Spacer()
                            Image(systemName: viewModel.selectedFormat == format ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(viewModel.selectedFormat == format ? VYRATheme.primaryText : VYRATheme.secondary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("format-\(format.rawValue)")
                    if format != DownloadFormat.allCases.last {
                        Divider().overlay(VYRATheme.secondary.opacity(0.3))
                    }
                }
            }

            if viewModel.showsQualitySelection {
                VStack(alignment: .leading, spacing: 10) {
                    Text("品質")
                        .font(.headline)
                        .foregroundStyle(VYRATheme.primaryText)
                    HStack(spacing: 8) {
                        ForEach(DownloadQuality.allCases) { quality in
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    viewModel.selectedQuality = quality
                                }
                            } label: {
                                Text(quality.displayName)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(viewModel.selectedQuality == quality ? VYRATheme.background : VYRATheme.primaryText)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        viewModel.selectedQuality == quality ? VYRATheme.primaryText : Color.clear,
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule().stroke(VYRATheme.secondary.opacity(0.6), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("quality-\(quality.rawValue)")
                        }
                    }
                }
                .accessibilityIdentifier("quality-selection")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("選択中: \(viewModel.selectionSummary)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(VYRATheme.primaryText)
                Text(viewModel.estimatedSizeText)
                    .font(.footnote)
                    .foregroundStyle(VYRATheme.secondary)
                Text("ファイル名: \(viewModel.suggestedFileName)")
                    .font(.footnote)
                    .foregroundStyle(VYRATheme.secondary)
                    .lineLimit(1)
            }
        }
    }
}
