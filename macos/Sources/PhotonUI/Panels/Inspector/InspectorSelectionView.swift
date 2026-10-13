import SwiftUI

struct InspectorSelectionView: View {
    let clip: MediaClip

    var body: some View {
        HStack(spacing: 6) {
            ClipArtworkView(clip: clip)
                .frame(width: 32, height: 32)
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title).font(.system(size: 12, weight: .medium))
                Text(clip.detail).font(.system(size: 10)).foregroundStyle(PhotonTheme.muted)
            }
        }
    }
}
