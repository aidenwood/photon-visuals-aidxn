import SwiftUI

struct InspectorSelectionView: View {
    let clip: MediaClip

    var body: some View {
        HStack(spacing: 11) {
            ClipArtworkView(clip: clip)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                Text(clip.title).font(.system(size: 12, weight: .medium))
                Text(clip.detail).font(.system(size: 10)).foregroundStyle(PhotonTheme.muted)
            }
        }
    }
}
