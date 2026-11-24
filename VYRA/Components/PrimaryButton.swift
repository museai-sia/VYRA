import SwiftUI

struct PrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(VYRATheme.background)
                }
                Text(title)
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(VYRATheme.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(VYRATheme.primaryText, in: RoundedRectangle(cornerRadius: 14))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
    }
}

/// Small Liquid Glass action button (paste / clear / share style actions).
struct GlassIconButton: View {
    let symbolName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(VYRATheme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}
