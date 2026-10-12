import SwiftUI

struct PreviewSkeleton: View {
    var body: some View {
        GeometryReader { geometry in
            Rectangle()
            .fill(PhotonTheme.background)
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "play.rectangle").font(.system(size: 26))
                    Text("Preparing preview").font(.system(size: 11))
                }
                .foregroundStyle(PhotonTheme.faint)
            }
        }
        .padding(12)
    }
}
