import SwiftUI

struct OutputTile: View {
    let output: OutputDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: "display").font(.system(size: 20)).foregroundStyle(PhotonTheme.accent)
                Spacer()
                StatusPill(title: "Preview")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(output.title).font(.system(size: 12, weight: .medium))
                Text(output.detail).font(.system(size: 10)).foregroundStyle(PhotonTheme.muted)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(PhotonTheme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(PhotonTheme.border) }
    }
}
