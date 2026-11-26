import SwiftUI
import SwiftData

enum AppTab: String, CaseIterable, Identifiable {
    case home
    case library
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .home: return "house"
        case .library: return "square.stack"
        case .settings: return "gearshape"
        }
    }
}

/// Environment channel for tab navigation. The selection itself is
/// owned by ContentView (and bound to the native TabView), but
/// screens deep inside a tab's navigation stack — the download
/// completion screen is the case that matters — need a way to
/// request a switch (e.g. "ライブラリで確認" must land on the
/// Library tab, not just pop one level back to the confirmation
/// screen).
private struct TabSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<AppTab>? = nil
}

extension EnvironmentValues {
    var tabSelection: Binding<AppTab>? {
        get { self[TabSelectionKey.self] }
        set { self[TabSelectionKey.self] = newValue }
    }
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .home
    @State private var libraryViewModel = LibraryViewModel()
    @State private var settingsViewModel = SettingsViewModel()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        // Genuine native TabView: on iOS 26 the system tab bar
        // renders Liquid Glass itself, including the selection
        // emphasis. The previous hand-built GlassTabBar (a painted
        // white-tint capsule morphed via glassEffectID) is retired —
        // no self-drawn selection backgrounds or corner shapes.
        // The tabSelection environment binding below is the very
        // binding this TabView selects on, so the download
        // completion screen's "ライブラリで確認" switches here.
        // (The "tab-<name>" accessibility identifiers the UI
        // tests use live on the tabItem labels: with a native
        // TabView the tab bar button takes its accessibility
        // identity from the label, not from the tab's root view —
        // identifiers placed on the roots never reached the
        // buttons and testTabSwitching found nothing to tap.)
        TabView(selection: $selectedTab) {
            HomeView(libraryViewModel: libraryViewModel)
                .tabItem {
                    Label(AppTab.home.title, systemImage: AppTab.home.symbolName)
                        .accessibilityIdentifier("tab-\(AppTab.home.rawValue)")
                }
                .tag(AppTab.home)
            LibraryView(viewModel: libraryViewModel)
                .tabItem {
                    Label(AppTab.library.title, systemImage: AppTab.library.symbolName)
                        .accessibilityIdentifier("tab-\(AppTab.library.rawValue)")
                }
                .tag(AppTab.library)
            SettingsView(viewModel: settingsViewModel)
                .tabItem {
                    Label(AppTab.settings.title, systemImage: AppTab.settings.symbolName)
                        .accessibilityIdentifier("tab-\(AppTab.settings.rawValue)")
                }
                .tag(AppTab.settings)
        }
        .environment(\.tabSelection, $selectedTab)
        .preferredColorScheme(.dark)
        .tint(VYRATheme.primaryText)
        .task {
            // Phase 3: restore the persisted Library and verify files.
            libraryViewModel.attach(modelContext: modelContext)
        }
    }
}

#Preview {
    ContentView()
}
