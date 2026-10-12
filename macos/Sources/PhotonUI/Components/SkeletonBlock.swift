import SwiftUI

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(PhotonTheme.raised)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .accessibilityHidden(true)
    }
}
