import SwiftUI

struct DownloadConfirmationView: View {
    var previewViewModel: VideoPreviewViewModel
    var libraryViewModel: LibraryViewModel
    @State private var downloadItem: DownloadItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VideoThumbnailView(symbolName: previewViewModel.video.thumbnailSymbol,
                                   durationText: previewViewModel.video.formattedDuration)

                VStack(alignment: .leading, spacing: 14) {
                    row(label: "ファイル名", value: previewViewModel.suggestedFileName)
                    Divider().overlay(VYRATheme.secondary.opacity(0.3))
                    row(label: "形式", value: previewViewModel.selectedFormat.displayName)
                    Divider().overlay(VYRATheme.secondary.opacity(0.3))
                    if previewViewModel.showsQualitySelection {
                        row(label: "品質", value: previewViewModel.selectedQuality.displayName)
                        Divider().overlay(VYRATheme.secondary.opacity(0.3))
                    }
                    row(label: "ファイルサイズ", value: previewViewModel.estimatedSizeText)
                    Divider().overlay(VYRATheme.secondary.opacity(0.3))
                    row(label: "保存先", value: "アプリ内ライブラリ（モック）")
                }

                Text("Phase 1では実際のダウンロードは行いません。サイズは推定値（モック）です。")
                    .font(.footnote)
                    .foregroundStyle(VYRATheme.secondary)

                NavigationLink {
                    if let downloadItem {
                        DownloadProgressScreen(viewModel: DownloadViewModel(item: downloadItem, video: previewViewModel.video),
                                             libraryViewModel: libraryViewModel)
                    }
                } label: {
                    Text("ダウンロード開始（モック）")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(VYRATheme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(VYRATheme.primaryText, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityIdentifier("start-download-button")
                .simultaneousGesture(TapGesture().onEnded {
                    if downloadItem == nil { downloadItem = previewViewModel.makeDownloadItem() }
                })
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(VYRATheme.background)
        .navigationTitle("Download")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if downloadItem == nil { downloadItem = previewViewModel.makeDownloadItem() } }
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(VYRATheme.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(VYRATheme.primaryText)
            Spacer()
        }
    }
}
