import SwiftUI

struct DownloadProgressView: View {
    var progress: Double
    var state: DownloadState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(VYRATheme.secondary.opacity(0.35))
                    Capsule()
                        .fill(VYRATheme.primaryText)
                        .frame(width: max(0, min(1, progress)) * geometry.size.width)
                        .animation(.easeInOut(duration: 0.2), value: progress)
                }
            }
            .frame(height: 6)

            HStack {
                Label(state.displayName, systemImage: state.symbolName)
                    .foregroundStyle(VYRATheme.secondary)
                Spacer()
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(VYRATheme.primaryText)
            }
            .font(.footnote)
        }
    }
}
