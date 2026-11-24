import SwiftUI
import AVKit

/// Library (Phase 3, spec §13): real saved files from SwiftData, newest
/// first, with AVKit playback, sharing and confirmed deletion.
struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    @State private var itemPendingDeletion: DownloadItem?
    @State private var playingItem: DownloadItem?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(VYRATheme.background)
            .navigationTitle("Library")
        }
        .confirmationDialog(
            "このファイルを削除しますか？",
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { if !$0 { itemPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: itemPendingDeletion
        ) { item in
            Button("削除", role: .destructive) {
                viewModel.delete(item)
                itemPendingDeletion = nil
            }
            Button("キャンセル", role: .cancel) { itemPendingDeletion = nil }
        } message: { item in
            Text("「\(item.fileName)」とその保存データを削除します。この操作は取り消せません。")
        }
        .sheet(item: $playingItem) { item in
            if let url = viewModel.playableURL(for: item) {
                MediaPlayerView(url: url, title: item.fileName)
            } else {
                VStack(spacing: 12) {
                    Text("このファイルは再生できません")
                        .font(.headline)
                        .foregroundStyle(VYRATheme.primaryText)
                    Text("対応形式でないか、ファイルが見つかりません。")
                        .font(.footnote)
                        .foregroundStyle(VYRATheme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VYRATheme.background)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "square.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(VYRATheme.secondary)
            Text("保存済みファイルはありません")
                .font(.headline)
                .foregroundStyle(VYRATheme.primaryText)
            Text("Homeで動画URLを入力し、ダウンロードが完了すると、保存したファイルがここに表示されます。")
                .font(.footnote)
                .foregroundStyle(VYRATheme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(VYRATheme.background)
        .accessibilityIdentifier("library-empty-state")
    }

    private var list: some View {
        List {
            ForEach(viewModel.items) { item in
                LibraryRowView(
                    item: item,
                    isPlayable: viewModel.isPlayable(item),
                    shareURL: viewModel.shareURL(for: item),
                    onPlay: { playingItem = item },
                    onDelete: { itemPendingDeletion = item }
                )
                .listRowBackground(VYRATheme.background)
                .listRowSeparatorTint(VYRATheme.secondary.opacity(0.35))
            }
            .onDelete { viewModel.delete(at: $0) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(VYRATheme.background)
    }
}

/// AVKit player sheet: standard iOS playback, no custom player (spec §16).
struct MediaPlayerView: View {
    let url: URL
    let title: String
    @State private var player: AVPlayer?
    @State private var playbackError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(VYRATheme.primaryText)
                    .lineLimit(1)
                Spacer()
                Button("閉じる") { dismiss() }
                    .foregroundStyle(VYRATheme.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if let player {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let playbackError {
                Spacer()
                Text(playbackError)
                    .font(.footnote)
                    .foregroundStyle(VYRATheme.secondary)
                    .padding(.horizontal, 24)
                Spacer()
            } else {
                Spacer()
                ProgressView().tint(VYRATheme.primaryText)
                Spacer()
            }
        }
        .background(VYRATheme.background)
        .onAppear {
            let asset = AVURLAsset(url: url)
            Task {
                let playable = (try? await asset.load(.isPlayable)) ?? false
                if playable {
                    let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    player = p
                    p.play()
                } else {
                    playbackError = "このファイルは再生に対応していません。"
                }
            }
        }
        .onDisappear { player?.pause() }
    }
}

struct LibraryRowView: View {
    var item: DownloadItem
    var isPlayable: Bool = false
    var shareURL: URL?
    var onPlay: (() -> Void)?
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnailURL = item.thumbnailURL {
                AsyncImage(url: thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: item.thumbnailSymbol)
                        .font(.system(size: 22))
                        .foregroundStyle(VYRATheme.secondary)
                }
                .frame(width: 44, height: 44)
                .clipped()
            } else {
                Image(systemName: item.thumbnailSymbol)
                    .font(.system(size: 22))
                    .foregroundStyle(VYRATheme.secondary)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(VYRATheme.primaryText)
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(VYRATheme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isPlayable, let onPlay {
                Button(action: onPlay) {
                    Image(systemName: "play.circle")
                        .foregroundStyle(VYRATheme.primaryText)
                }
                .accessibilityIdentifier("play-button")
            }
            if let shareURL {
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(VYRATheme.primaryText)
                }
                .accessibilityIdentifier("share-button")
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(VYRATheme.secondary)
            }
            .accessibilityIdentifier("delete-button")
        }
        .padding(.vertical, 4)
    }

    private var detailText: String {
        var parts = [item.format.displayName, item.formattedFileSize,
                     item.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let duration = item.formattedDuration {
            parts.insert(duration, at: 1)
        }
        return parts.joined(separator: " · ")
    }
}
