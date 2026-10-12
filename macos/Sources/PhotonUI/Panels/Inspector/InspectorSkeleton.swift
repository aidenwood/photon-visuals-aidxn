import SwiftUI

struct InspectorSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(spacing: 12) {
                SkeletonBlock(width: 42, height: 42, radius: 6)
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 95)
                    SkeletonBlock(width: 70, height: 9)
                }
            }
            ForEach(0..<5) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBlock(width: 70, height: 10)
                    SkeletonBlock(height: 20)
                }
            }
        }
        .padding(18)
    }
}
