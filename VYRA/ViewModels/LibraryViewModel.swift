import Foundation
import Observation

@MainActor
@Observable
final class LibraryViewModel {
    private(set) var items: [DownloadItem] = []

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    var totalMockBytes: Int64 { items.reduce(0) { $0 + $1.fileSizeBytes } }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalMockBytes, countStyle: .file)
    }

    func add(_ item: DownloadItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.insert(item, at: 0)
    }

    @discardableResult
    func addMockItem() -> DownloadItem {
        let item = DownloadItem.mockItem()
        add(item)
        return item
    }

    func delete(_ item: DownloadItem) {
        items.removeAll { $0.id == item.id }
    }

    func delete(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    func clearAll() {
        items.removeAll()
    }
}
