import SwiftUI

struct LibraryClipRow: View {
    let clip: MediaClip
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: "film")
                    .font(.system(size: 11)).foregroundStyle(selected ? PhotonTheme.accent : PhotonTheme.faint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.title).font(.system(size: 11, weight: selected ? .medium : .regular))
                    Text(clip.detail).font(.system(size: 9)).foregroundStyle(PhotonTheme.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(selected ? PhotonTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? PhotonTheme.foreground : PhotonTheme.muted)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
