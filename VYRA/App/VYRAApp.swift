import SwiftUI
import SwiftData

@main
struct VYRAApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // SwiftData is wired up for DownloadItem persistence. Phase 1 keeps
        // the in-memory mock flow in LibraryViewModel so behaviour stays
        // deterministic in previews and tests.
        .modelContainer(for: DownloadItem.self)
    }
}
