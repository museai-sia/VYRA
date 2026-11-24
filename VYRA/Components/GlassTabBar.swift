import SwiftUI

/// Floating Liquid Glass tab bar for Home / Library / Settings.
/// Rendered in the normal layout flow (not an overlay) so content never
/// slides underneath it.
struct GlassTabBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(AppTab.allCases) { tab in
                    Button {
                        withAnimation(.smooth(duration: 0.25)) {
                            selectedTab = tab
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.symbolName)
                                .font(.system(size: 19, weight: selectedTab == tab ? .semibold : .regular))
                            Text(tab.title)
                                .font(.caption2)
                        }
                        .foregroundStyle(selectedTab == tab ? VYRATheme.primaryText : VYRATheme.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tab-\(tab.rawValue)")
                    .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 10)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
    }
}
