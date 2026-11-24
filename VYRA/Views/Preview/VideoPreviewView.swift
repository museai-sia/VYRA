import SwiftUI

struct VideoPreviewView: View {
    @State private var viewModel: VideoPreviewViewModel
    var libraryViewModel: LibraryViewModel

    init(video: Video, libraryViewModel: LibraryViewModel) {
        _viewModel = State(initialValue: VideoPreviewViewModel(video: video))
        self.libraryViewModel = libraryViewModel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VideoThumbnailView(symbolName: viewModel.video.thumbnailSymbol,
                                   durationText: viewModel.video.formattedDuration)

                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.video.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(VYRATheme.primaryText)
                        .accessibilityIdentifier("video-title")
                    Text(viewModel.video.author)
                        .font(.subheadline)
                        .foregroundStyle(VYRATheme.secondary)
                    HStack(spacing: 14) {
                        Label(viewModel.video.formattedDuration, systemImage: "clock")
                        Label(viewModel.video.sourceName, systemImage: "globe")
                    }
                    .font(.footnote)
                    .foregroundStyle(VYRATheme.secondary)
                }

                Divider().overlay(VYRATheme.secondary.opacity(0.4))

                FormatSelectionView(viewModel: viewModel)

                NavigationLink {
                    DownloadConfirmationView(previewViewModel: viewModel,
                                             libraryViewModel: libraryViewModel)
                } label: {
                    Text("ダウンロード確認へ")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(VYRATheme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(VYRATheme.primaryText, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityIdentifier("to-confirmation-button")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(VYRATheme.background)
        .navigationTitle("Video Preview")
        .navigationBarTitleDisplayMode(.inline)
    }
}
