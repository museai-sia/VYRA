import SwiftUI

struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.addMockItem()
                    } label: {
                        Label("モックを追加", systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-mock-button")
                }
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
            Text("Homeで動画URLを入力すると、モックの保存がここに表示されます。下のボタンからモック項目を追加することもできます。")
                .font(.footnote)
                .foregroundStyle(VYRATheme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                viewModel.addMockItem()
            } label: {
                Text("モックファイルを追加")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VYRATheme.background)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(VYRATheme.primaryText, in: Capsule())
            }
            .accessibilityIdentifier("add-mock-button-empty")
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(VYRATheme.background)
        .accessibilityIdentifier("library-empty-state")
    }

    private var list: some View {
        List {
            ForEach(viewModel.items) { item in
                LibraryRowView(item: item) { viewModel.delete(item) }
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

struct LibraryRowView: View {
    var item: DownloadItem
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.thumbnailSymbol)
                .font(.system(size: 22))
                .foregroundStyle(VYRATheme.secondary)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(VYRATheme.primaryText)
                    .lineLimit(1)
                Text("\(item.format.displayName) · \(item.formattedFileSize) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(VYRATheme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            ShareLink(item: item.fileName) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(VYRATheme.primaryText)
            }
            .accessibilityIdentifier("share-button")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(VYRATheme.secondary)
            }
            .accessibilityIdentifier("delete-button")
        }
        .padding(.vertical, 4)
    }
}
