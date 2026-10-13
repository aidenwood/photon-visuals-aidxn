import SwiftUI

struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: PhotonTheme.controlHeight, height: PhotonTheme.controlHeight)
                .background(PhotonTheme.raised, in: Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PhotonTheme.muted)
        .help(label)
        .accessibilityLabel(label)
    }
}
