import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    let appName: String = "VYRA"
    let versionText: String = "1.0.0 (Phase 1)"
    let saveLocationText: String = "アプリ内ライブラリ（モック）"
    var cacheSizeText: String = "12.4 MB（モック）"
    var storageUsedText: String = "0 MB（モック）"
    private(set) var cacheCleared: Bool = false

    func clearCache() {
        cacheSizeText = "0 MB（モック）"
        cacheCleared = true
    }

    func updateStorageUsed(mockBytes: Int64) {
        storageUsedText = "\(ByteCountFormatter.string(fromByteCount: mockBytes, countStyle: .file))（モック）"
    }
}
