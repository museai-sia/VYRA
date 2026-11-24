import SwiftUI

struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    @State private var navigationPath: [Video] = []
    var libraryViewModel: LibraryViewModel

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    headline
                    URLInputView(viewModel: viewModel)

                    PrimaryButton(
                        title: "動画情報を取得",
                        isLoading: viewModel.isLoading
                    ) {
                        Task {
                            if let video = await viewModel.fetchVideoInfo() {
                                navigationPath.append(video)
                            }
                        }
                    }
                    .accessibilityIdentifier("fetch-button")

                    Divider().overlay(VYRATheme.secondary.opacity(0.4))

                    recentSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(VYRATheme.background)
            .navigationDestination(for: Video.self) { video in
                VideoPreviewView(video: video, libraryViewModel: libraryViewModel)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.square.stack.fill")
                .font(.system(size: 26))
                .foregroundStyle(VYRATheme.primaryText)
            Text("VYRA")
                .font(.title2.weight(.bold))
                .foregroundStyle(VYRATheme.primaryText)
                .accessibilityIdentifier("vyra-logo")
            Spacer()
            // Settings live in the Settings tab; this icon is the header
            // affordance required by the spec and mirrors that destination.
            Image(systemName: "gearshape")
                .font(.system(size: 19))
                .foregroundStyle(VYRATheme.secondary)
                .accessibilityIdentifier("home-settings-icon")
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("動画を保存する")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(VYRATheme.primaryText)
                .accessibilityIdentifier("home-headline")
            Text("動画のURLを貼り付けて、情報を確認してから保存形式を選べます。（Phase 1: モック）")
                .font(.subheadline)
                .foregroundStyle(VYRATheme.secondary)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近の保存履歴")
                    .font(.headline)
                    .foregroundStyle(VYRATheme.primaryText)
                Spacer()
                Text("保存済み \(libraryViewModel.count) 件")
                    .font(.footnote)
                    .foregroundStyle(VYRATheme.secondary)
            }
            if libraryViewModel.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundStyle(VYRATheme.secondary)
                    Text("まだ保存した動画はありません")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(VYRATheme.primaryText)
                    Text("URLを入力して動画情報を取得すると、ここから保存を始められます。")
                        .font(.footnote)
                        .foregroundStyle(VYRATheme.secondary)
                }
                .padding(.vertical, 8)
                .accessibilityIdentifier("home-empty-state")
            } else {
                ForEach(libraryViewModel.items.prefix(3)) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.thumbnailSymbol)
                            .foregroundStyle(VYRATheme.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.fileName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(VYRATheme.primaryText)
                                .lineLimit(1)
                            Text("\(item.format.displayName) · \(item.formattedFileSize)")
                                .font(.caption)
                                .foregroundStyle(VYRATheme.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}
