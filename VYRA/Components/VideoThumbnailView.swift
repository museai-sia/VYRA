import SwiftUI

/// 16:9 monochrome placeholder thumbnail drawn directly on the background.
struct VideoThumbnailView: View {
    var symbolName: String = "play.rectangle.fill"
    var durationText: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(VYRATheme.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(VYRATheme.secondary.opacity(0.55), lineWidth: 1)
                )
            Image(systemName: symbolName)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(VYRATheme.secondary)
            if let durationText {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(durationText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(VYRATheme.primaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .glassEffect(.regular, in: Capsule())
                    }
                }
                .padding(8)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }
}
