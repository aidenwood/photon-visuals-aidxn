import SwiftUI

struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 28, height: 28)
                .background(PhotonTheme.raised, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(PhotonTheme.muted)
        .help(label)
        .accessibilityLabel(label)
    }
}
