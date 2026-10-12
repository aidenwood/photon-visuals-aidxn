import SwiftUI

struct LibrarySkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            ForEach(0..<6) { _ in
                VStack(alignment: .leading, spacing: 7) {
                    SkeletonBlock(width: 120)
                    SkeletonBlock(width: 80, height: 8)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
