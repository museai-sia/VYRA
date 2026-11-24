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
                if let thumbnailURL = viewModel.thumbnailURL {
                    AsyncImage(url: thumbnailURL) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        VideoThumbnailView(symbolName: viewModel.video.thumbnailSymbol,
                                           durationText: viewModel.durationText)
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("video-thumbnail-image")
                } else {
                    VideoThumbnailView(symbolName: viewModel.video.thumbnailSymbol,
                                       durationText: viewModel.durationText)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.titleText)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(VYRATheme.primaryText)
                        .accessibilityIdentifier("video-title")
                    Text(viewModel.channelText)
                        .font(.subheadline)
                        .foregroundStyle(VYRATheme.secondary)
                    HStack(spacing: 14) {
                        Label(viewModel.durationText, systemImage: "clock")
                        Label(viewModel.sourceText, systemImage: "globe")
                        if let publishedDateText = viewModel.publishedDateText {
                            Label(publishedDateText, systemImage: "calendar")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(VYRATheme.secondary)
                    if let descriptionText = viewModel.descriptionText, !descriptionText.isEmpty {
                        Text(descriptionText)
                            .font(.footnote)
                            .foregroundStyle(VYRATheme.secondary)
                            .lineLimit(3)
                    }
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
