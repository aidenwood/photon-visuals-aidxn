import SwiftUI

struct StatusPill: View {
    let title: String
    var color: Color = PhotonTheme.accent

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.09), in: Capsule())
        .overlay { Capsule().strokeBorder(color.opacity(0.18)) }
    }
}
