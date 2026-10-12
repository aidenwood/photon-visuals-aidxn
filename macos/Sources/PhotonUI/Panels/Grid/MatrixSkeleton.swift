import SwiftUI

struct MatrixSkeleton: View {
    var body: some View {
        HStack(spacing: 4) {
            VStack(spacing: 4) {
                ForEach(0..<4) { _ in SkeletonBlock(width: 230, height: 56, radius: 2) }
            }
            ForEach(0..<6) { _ in
                VStack(spacing: 4) {
                    ForEach(0..<4) { _ in SkeletonBlock(height: 56, radius: 2) }
                }
            }
        }
        .padding(4).frame(maxHeight: .infinity, alignment: .top)
    }
}
