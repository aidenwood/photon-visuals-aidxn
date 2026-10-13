import SwiftUI

struct LibrarySkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<6) { _ in
                VStack(alignment: .leading, spacing: 2) {
                    SkeletonBlock(width: 120)
                    SkeletonBlock(width: 80, height: 8)
                }
            }
        }
        .padding(PhotonTheme.contentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
