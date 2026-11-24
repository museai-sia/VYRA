import SwiftUI

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

struct ContentView: View {
    @State private var selectedTab: AppTab = .home
    @State private var libraryViewModel = LibraryViewModel()
    @State private var settingsViewModel = SettingsViewModel()

    var body: some View {
        ZStack {
            VYRATheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Group {
                    switch selectedTab {
                    case .home:
                        HomeView(libraryViewModel: libraryViewModel)
                    case .library:
                        LibraryView(viewModel: libraryViewModel)
                    case .settings:
                        SettingsView(viewModel: settingsViewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                GlassTabBar(selectedTab: $selectedTab)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        .tint(VYRATheme.primaryText)
    }
}

#Preview {
    ContentView()
}
