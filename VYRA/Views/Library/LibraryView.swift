import SwiftUI
import AVKit
import Combine

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
        // A centered alert, not a confirmationDialog: on iPhone the
        // dialog is a bottom-anchored action sheet, which here
        // surfaced detached down by the (custom) tab bar instead of
        // anywhere near the tapped trash icon. An alert is anchored
        // to the screen center regardless of the row tapped.
        .alert(
            "このファイルを削除しますか？",
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { if !$0 { itemPendingDeletion = nil } }
            ),
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

/// AVKit player sheet: standard iOS playback, no custom player
/// (spec §16) — but presented through AVPlayerViewController, which
/// owns and sizes its AVPlayerLayer itself.
///
/// Why not SwiftUI's `VideoPlayer` (the previous implementation):
/// on device, saved files played AUDIO ONLY — sound with no
/// picture. The files are not the cause: the TS→MP4 remux output
/// was verified locally (against the repo's HLS fixture and a
/// generated 1080p High-profile B-frame TS) to be structurally
/// identical to `ffmpeg -c copy` output — one video track, avc1
/// tag, valid avcC, correct track dimensions, every frame
/// decodable. The failure is in the presentation path: the player
/// was created asynchronously behind an `isPlayable` load and
/// handed to `VideoPlayer`, whose layer never rendered. The view
/// controller is the battle-tested playback surface (it manages
/// the layer's geometry in a sheet, controls and fullscreen), the
/// player is created up front with no async gate, and a failed
/// item now surfaces its real error instead of silent audio.
struct MediaPlayerView: View {
    let title: String
    private let item: AVPlayerItem
    @State private var player: AVPlayer
    @State private var loadError: String?
    @Environment(\.dismiss) private var dismiss

    init(url: URL, title: String) {
        self.title = title
        let item = AVPlayerItem(url: url)
        self.item = item
        _player = State(initialValue: AVPlayer(playerItem: item))
    }

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
            if let loadError {
                Spacer()
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(VYRATheme.secondary)
                    .padding(.horizontal, 24)
                Spacer()
            } else {
                PlayerViewController(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(VYRATheme.background)
        .onAppear {
            if item.status == .failed {
                loadError = item.error?.localizedDescription
                    ?? "このファイルは再生に対応していません。"
            }
            player.play()
        }
        .onDisappear { player.pause() }
        .onReceive(item.publisher(for: \.status)) { status in
            if status == .failed {
                loadError = item.error?.localizedDescription
                    ?? "このファイルは再生に対応していません。"
            }
        }
    }
}

/// AVPlayerViewController wrapper: AVKit manages the player
/// layer's geometry, playback controls and fullscreen behaviour.
private struct PlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
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
                // 16:9 (88 x 49.5), filled and clipped — the row
                // thumbnail is a video frame, never a square.
                .frame(width: 88, height: 49.5)
                .clipped()
            } else {
                Image(systemName: item.thumbnailSymbol)
                    .font(.system(size: 22))
                    .foregroundStyle(VYRATheme.secondary)
                    .frame(width: 88, height: 49.5)
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
            // In a List row, buttons without an explicit borderless
            // style are NOT independent tap targets: the row routes
            // every tap to a single button (here the last one —
            // delete — fired no matter which icon was tapped). Each
            // action below is borderless and carries its own 36x36
            // hit area, so play / share / delete fire independently.
            if isPlayable, let onPlay {
                Button(action: onPlay) {
                    Image(systemName: "play.circle")
                        .foregroundStyle(VYRATheme.primaryText)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("play-button")
            }
            if let shareURL {
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(VYRATheme.primaryText)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("share-button")
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(VYRATheme.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
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
