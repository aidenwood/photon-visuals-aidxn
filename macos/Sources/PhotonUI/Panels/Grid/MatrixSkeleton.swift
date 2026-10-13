import SwiftUI

struct MatrixSkeleton: View {
    var body: some View {
        HStack(spacing: PhotonTheme.panelGap) {
            VStack(spacing: PhotonTheme.panelGap) {
                ForEach(0..<4) { _ in SkeletonBlock(width: PhotonTheme.layerStripWidth, height: 56) }
            }
            ForEach(0..<6) { _ in
                VStack(spacing: PhotonTheme.panelGap) {
                    ForEach(0..<4) { _ in SkeletonBlock(height: 56) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
