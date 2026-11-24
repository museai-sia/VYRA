import SwiftUI

/// Download progress (Phase 3, spec §10): real progress from the engine.
/// Percentage is shown only when the total size is known; speed and ETA
/// appear only when measured. Leaving this screen does NOT cancel the
/// download — the manager owns the task while the app is active.
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
                    if viewModel.isFinished {
                        Text("\(viewModel.item.format.displayName) · \(viewModel.item.formattedFileSize)")
                            .font(.footnote)
                            .foregroundStyle(VYRATheme.secondary)
                    } else if viewModel.usesManager {
                        Text(viewModel.item.format.displayName)
                            .font(.footnote)
                            .foregroundStyle(VYRATheme.secondary)
                    } else {
                        Text("\(viewModel.item.format.displayName) · \(viewModel.item.formattedFileSize)（推定・モック）")
                            .font(.footnote)
                            .foregroundStyle(VYRATheme.secondary)
                    }
                }

                if viewModel.usesManager {
                    managerProgressDetails
                } else {
                    DownloadProgressView(progress: viewModel.progress, state: viewModel.state)
                }

                if viewModel.isRunning || viewModel.state == .waiting || viewModel.state == .queued {
                    PrimaryButton(title: "キャンセル") { viewModel.cancel() }
                        .accessibilityIdentifier("cancel-download-button")
                }

                if viewModel.isFinished {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(viewModel.usesManager ? "完了しました" : "完了しました（モック）", systemImage: "checkmark.circle")
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
                    Text("キャンセルされました。不完全なファイルはライブラリに登録されていません。")
                        .font(.footnote)
                        .foregroundStyle(VYRATheme.secondary)
                    PrimaryButton(title: "もう一度開始") { viewModel.start() }
                        .accessibilityIdentifier("restart-download-button")
                }

                if viewModel.state == .failed {
                    Text(viewModel.errorMessage ?? "ダウンロードに失敗しました。再試行してください。")
                        .font(.footnote)
                        .foregroundStyle(VYRATheme.secondary)
                    PrimaryButton(title: "再試行") { viewModel.retry() }
                        .accessibilityIdentifier("retry-download-button")
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
    }

    private var managerProgressDetails: some View {
        let snapshot = viewModel.downloadProgress
        return VStack(alignment: .leading, spacing: 8) {
            if let fraction = snapshot.fraction {
                DownloadProgressView(progress: fraction, state: viewModel.state)
            } else {
                ProgressView()
                    .tint(VYRATheme.primaryText)
                HStack {
                    Label(viewModel.state.displayName, systemImage: viewModel.state.symbolName)
                        .foregroundStyle(VYRATheme.secondary)
                    Spacer()
                }
                .font(.footnote)
            }
            HStack(spacing: 12) {
                Text(snapshot.downloadedText)
                    .foregroundStyle(VYRATheme.primaryText)
                if let totalText = snapshot.totalText {
                    Text("/ \(totalText)")
                        .foregroundStyle(VYRATheme.secondary)
                }
                if let speedText = snapshot.speedText {
                    Text(speedText)
                        .foregroundStyle(VYRATheme.secondary)
                }
                if let remaining = snapshot.remainingTimeText {
                    Text(remaining)
                        .foregroundStyle(VYRATheme.secondary)
                }
            }
            .font(.footnote)
        }
        .accessibilityIdentifier("download-progress-details")
    }

    private func addToLibraryIfNeeded() {
        // In manager mode the manager already registered the completed
        // item (with its real file) via onCompleted. Only the legacy
        // simulation adds its mock item here.
        guard !viewModel.usesManager else { return }
        guard !addedToLibrary else { return }
        addedToLibrary = true
        libraryViewModel.add(viewModel.item)
    }
}
