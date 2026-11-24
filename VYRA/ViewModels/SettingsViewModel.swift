import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    let appName: String = "VYRA"
    let versionText: String = "1.0.0 (Phase 3)"
    let saveLocationText: String = "アプリ内ライブラリ（Documents）"
    var cacheSizeText: String = "12.4 MB（モック）"
    var storageUsedText: String = "0 MB"
    private(set) var cacheCleared: Bool = false

    func clearCache() {
        cacheSizeText = "0 MB（モック）"
        cacheCleared = true
    }

    func updateStorageUsed(mockBytes: Int64) {
        storageUsedText = ByteCountFormatter.string(fromByteCount: mockBytes, countStyle: .file)
    }

    /// Real Library usage from disk (Phase 3).
    func refreshStorageUsed(from storage: FileStorageService = .appDefault) {
        storageUsedText = ByteCountFormatter.string(fromByteCount: storage.totalLibraryBytes, countStyle: .file)
    }
}
