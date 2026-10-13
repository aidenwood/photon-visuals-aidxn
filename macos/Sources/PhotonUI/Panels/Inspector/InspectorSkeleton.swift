import SwiftUI

struct InspectorSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SkeletonBlock(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    SkeletonBlock(width: 95)
                    SkeletonBlock(width: 70, height: 9)
                }
            }
            ForEach(0..<5) { _ in
                HStack(spacing: 6) {
                    SkeletonBlock(width: 68, height: 10)
                    SkeletonBlock(height: PhotonTheme.controlHeight)
                }
            }
        }
        .padding(PhotonTheme.contentInset)
    }
}
