import SwiftUI

struct ColumnTrigger: View {
    let column: Int
    let trigger: () -> Void

    var body: some View {
        Button(action: trigger) {
            HStack(spacing: 7) {
                Image(systemName: "play.fill").font(.system(size: 7))
                Text("Column \(column + 1)").font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PhotonTheme.raised)
            .overlay { Rectangle().strokeBorder(PhotonTheme.border) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(PhotonTheme.muted)
        .accessibilityLabel("Trigger column \(column + 1)")
    }
}
