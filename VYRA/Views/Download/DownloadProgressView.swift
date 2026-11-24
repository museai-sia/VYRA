import SwiftUI

struct DownloadProgressScreen: View {
    @State private var viewModel: DownloadViewModel
    var libraryViewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var addedToLibrary = false

    init(viewModel: DownloadViewModel, libraryViewModel: LibraryViewModel) {
        _viewModel = State(initialValue: viewModel)
        self.libraryViewModel = libraryViewModel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VideoThumbnailView(symbolName: viewModel.video.thumbnailSymbol,
                                   durationText: viewModel.video.formattedDuration)

                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.item.fileName)
                        .font(.headline)
                        .foregroundStyle(VYRATheme.primaryText)
                        .lineLimit(2)
                    Text("\(viewModel.item.format.displayName) · \(viewModel.item.formattedFileSize)（推定・モック）")
                        .font(.footnote)
                        .foregroundStyle(VYRATheme.secondary)
                }

                DownloadProgressView(progress: viewModel.progress, state: viewModel.state)

                if viewModel.state == .downloading || viewModel.state == .waiting {
                    PrimaryButton(title: "キャンセル") { viewModel.cancel() }
                        .accessibilityIdentifier("cancel-download-button")
                }

                if viewModel.isFinished {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("完了しました（モック）", systemImage: "checkmark.circle")
                            .font(.headline)
                            .foregroundStyle(VYRATheme.primaryText)
                        PrimaryButton(title: "ライブラリで確認") {
                            addToLibraryIfNeeded()
                            dismiss()
                        }
                        .accessibilityIdentifier("to-library-button")
                    }
                }

                if viewModel.state == .cancelled {
                    Text("キャンセルされました。もう一度開始できます。")
                        .font(.footnote)
                        .foregroundStyle(VYRATheme.secondary)
                    PrimaryButton(title: "再開（モック）") { viewModel.start() }
                }

                if viewModel.state == .failed {
                    Text("失敗しました（モック）。")
                        .font(.footnote)
                        .foregroundStyle(VYRATheme.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(VYRATheme.background)
        .navigationTitle("Downloading")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.start() }
        .onChange(of: viewModel.state) { _, newState in
            if newState == .completed { addToLibraryIfNeeded() }
        }
        .onDisappear { if viewModel.state == .downloading { viewModel.cancel() } }
    }

    private func addToLibraryIfNeeded() {
        guard !addedToLibrary else { return }
        addedToLibrary = true
        libraryViewModel.add(viewModel.item)
    }
}

