import SwiftUI

/// Download progress (Phase 3, spec §10): real progress from the engine.
/// Percentage is shown only when the total size is known; speed and ETA
/// appear only when measured. Leaving this screen does NOT cancel the
/// download — the manager owns the task while the app is active.
struct DownloadProgressScreen: View {
    @State private var viewModel: DownloadViewModel
    var libraryViewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tabSelection) private var tabSelection
    @State private var addedToLibrary = false

    init(viewModel: DownloadViewModel, libraryViewModel: LibraryViewModel) {
        _viewModel = State(initialValue: viewModel)
        self.libraryViewModel = libraryViewModel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Same thumbnail treatment as the confirmation screen:
                // the video's real artwork (carried on the item from
                // the extracted metadata) in the 16:9 frame, with the
                // monochrome placeholder while loading / on failure.
                if let thumbnailURL = viewModel.item.thumbnailURL ?? viewModel.video.thumbnailURL {
                    AsyncImage(url: thumbnailURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        VideoThumbnailView(symbolName: viewModel.video.thumbnailSymbol,
                                           durationText: viewModel.video.formattedDuration)
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VideoThumbnailView(symbolName: viewModel.video.thumbnailSymbol,
                                       durationText: viewModel.video.formattedDuration)
                }

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
                            // Actually go to the Library tab: this
                            // screen is pushed inside the Home tab's
                            // stack, so dismiss() alone only pops back
                            // to the confirmation screen. The tab
                            // switch also resets the Home stack (see
                            // HomeView), leaving the flow finished.
                            if let tabSelection {
                                withAnimation(.smooth(duration: 0.3)) {
                                    tabSelection.wrappedValue = .library
                                }
                            } else {
                                dismiss()
                            }
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
                    if let detail = viewModel.errorDetail {
                        // The specific cause (e.g. the Python exception),
                        // selectable so it can be copied or screenshotted.
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(VYRATheme.secondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("download-error-detail")
                    }
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
            if snapshot.phase == .merging {
                // Split-pair remux in progress: no bytes are moving,
                // so show an honest indeterminate state, not 100%.
                ProgressView()
                    .tint(VYRATheme.primaryText)
                HStack {
                    Label("結合中…（映像と音声を1つのMP4にまとめています）", systemImage: "arrow.triangle.merge")
                        .foregroundStyle(VYRATheme.secondary)
                    Spacer()
                }
                .font(.footnote)
            } else if snapshot.phase == .transcoding {
                // Transcode in progress: the fraction is the real
                // processed-duration share from the transcoder, so a
                // determinate bar + percent is honest here (the byte
                // row below is hidden — no bytes are moving).
                if let fraction = snapshot.fraction {
                    DownloadProgressView(progress: fraction, state: viewModel.state)
                } else {
                    ProgressView()
                        .tint(VYRATheme.primaryText)
                }
                HStack {
                    Label("変換中…（再生できるMP4に変換しています）", systemImage: "wand.and.stars")
                        .foregroundStyle(VYRATheme.secondary)
                    Spacer()
                    if let percent = snapshot.percentText {
                        Text(percent)
                            .foregroundStyle(VYRATheme.secondary)
                    }
                }
                .font(.footnote)
            } else if let fraction = snapshot.fraction {
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
            if snapshot.phase != .transcoding {
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
