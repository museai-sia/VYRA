import SwiftUI

/// Download confirmation (Phase 3, spec §8): thumbnail, editable file
/// name (extension protected), format, quality, size (only when actually
/// known — never guessed) and destination.
struct DownloadConfirmationView: View {
    var previewViewModel: VideoPreviewViewModel
    var libraryViewModel: LibraryViewModel
    @State private var editedBaseName: String = ""
    @State private var fileNameError: String?
    @State private var downloadItem: DownloadItem?
    @State private var manager: DownloadTaskManager?

    private var fullFileName: String {
        FileNameValidator.sanitizedBaseName(editedBaseName) + "." + previewViewModel.selectedFormat.fileExtension
    }

    private var isFileNameValid: Bool {
        !FileNameValidator.sanitizedBaseName(editedBaseName).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let thumbnailURL = previewViewModel.thumbnailURL {
                    AsyncImage(url: thumbnailURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        VideoThumbnailView(symbolName: previewViewModel.video.thumbnailSymbol,
                                           durationText: previewViewModel.durationText)
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VideoThumbnailView(symbolName: previewViewModel.video.thumbnailSymbol,
                                       durationText: previewViewModel.durationText)
                }

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ファイル名")
                            .font(.subheadline)
                            .foregroundStyle(VYRATheme.secondary)
                        HStack(spacing: 4) {
                            TextField("ファイル名", text: $editedBaseName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(VYRATheme.primaryText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("filename-field")
                                .onChange(of: editedBaseName) { _, _ in validateFileName() }
                            Text(".\(previewViewModel.selectedFormat.fileExtension)")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(VYRATheme.secondary)
                        }
                        if let fileNameError {
                            Text(fileNameError)
                                .font(.caption)
                                .foregroundStyle(VYRATheme.secondary)
                        }
                    }
                    Divider().overlay(VYRATheme.secondary.opacity(0.3))
                    row(label: "形式", value: previewViewModel.selectedFormat.displayName)
                    Divider().overlay(VYRATheme.secondary.opacity(0.3))
                    if previewViewModel.showsQualitySelection {
                        row(label: "品質", value: previewViewModel.selectedQuality.displayName)
                        Divider().overlay(VYRATheme.secondary.opacity(0.3))
                    }
                    if let knownFileSize = previewViewModel.knownFileSize {
                        row(label: "ファイルサイズ", value: ByteCountFormatter.string(fromByteCount: knownFileSize, countStyle: .file))
                        Divider().overlay(VYRATheme.secondary.opacity(0.3))
                    } else if !previewViewModel.hasVerifiedOptions {
                        row(label: "ファイルサイズ", value: previewViewModel.estimatedSizeText)
                        Divider().overlay(VYRATheme.secondary.opacity(0.3))
                    }
                    row(label: "保存先", value: "アプリ内ライブラリ（Documents）")
                }

                if let reason = previewViewModel.downloadUnavailableReason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(VYRATheme.secondary)
                        .accessibilityIdentifier("download-unavailable-reason")
                } else {
                    Text("ダウンロードはアプリが表示されている間のみ継続します。アプリを終了すると中断され、失敗として扱われます。")
                        .font(.footnote)
                        .foregroundStyle(VYRATheme.secondary)
                }

                NavigationLink {
                    if let downloadItem, let manager {
                        DownloadProgressScreen(
                            viewModel: DownloadViewModel(item: downloadItem, video: previewViewModel.video, manager: manager),
                            libraryViewModel: libraryViewModel)
                    }
                } label: {
                    Text("ダウンロード開始")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(VYRATheme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(VYRATheme.primaryText, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityIdentifier("start-download-button")
                .disabled(!isFileNameValid || !previewViewModel.isDownloadable)
                .opacity((!isFileNameValid || !previewViewModel.isDownloadable) ? 0.45 : 1.0)
                .simultaneousGesture(TapGesture().onEnded { prepareDownload() })
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(VYRATheme.background)
        .navigationTitle("Download")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if editedBaseName.isEmpty {
                editedBaseName = FileNameValidator.baseName(of: previewViewModel.suggestedFileName)
            }
            previewViewModel.reconcileSelection()
        }
    }

    private func validateFileName() {
        fileNameError = isFileNameValid ? nil : FileNameError.empty.userMessage
    }

    private func prepareDownload() {
        guard isFileNameValid, previewViewModel.isDownloadable else { return }
        do {
            let item = try previewViewModel.makeDownloadItem(fileName: fullFileName)
            downloadItem = item
            let library = libraryViewModel
            manager = DownloadTaskManager(
                engine: URLSessionDownloadEngine(),
                storage: library.storage,
                onCompleted: { completed in library.registerCompleted(completed) }
            )
        } catch let error as FileNameError {
            fileNameError = error.userMessage
        } catch {
            fileNameError = "ファイル名が正しくありません。"
        }
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
