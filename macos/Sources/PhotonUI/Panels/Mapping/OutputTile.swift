import SwiftUI

struct OutputTile: View {
    let output: OutputDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "display").font(.system(size: 16)).foregroundStyle(PhotonTheme.accent)
                Spacer()
                StatusPill(title: "Preview")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(output.title).font(.system(size: 12, weight: .medium))
                Text(output.detail).font(.system(size: 10)).foregroundStyle(PhotonTheme.muted)
            }
        }
        .padding(PhotonTheme.contentInset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PhotonTheme.raised, in: Rectangle())
        .overlay { Rectangle().strokeBorder(PhotonTheme.border) }
    }
}
