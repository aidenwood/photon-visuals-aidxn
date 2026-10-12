import SwiftUI

/// Static vector fixtures, not decoded media. No display timer or animation loop.
struct ArtworkView: View {
    let style: ArtworkStyle

    private var colors: [Color] {
        switch style {
        case .orbit: [.black, Color(red: 0.16, green: 0.06, blue: 0.3), PhotonTheme.accent.opacity(0.7)]
        case .contour: [Color(red: 0.08, green: 0.1, blue: 0.17), .black, .indigo.opacity(0.7)]
        case .bloom: [.black, .purple.opacity(0.75), .orange.opacity(0.45)]
        case .monochrome: [.black, .gray.opacity(0.6), .black]
        case .empty: [.black, .black]
        }
    }

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Canvas { context, size in
                    guard style != .empty else { return }
                    let center = CGPoint(x: size.width * 0.56, y: size.height * 0.53)
                    for index in 0..<14 {
                        let fraction = CGFloat(index + 1) / 14
                        let width = size.width * (0.15 + fraction * 0.48)
                        let height = size.height * (0.12 + fraction * 0.62)
                        let rect = CGRect(
                            x: center.x - width / 2, y: center.y - height / 2,
                            width: width, height: height
                        )
                        var path = Path()
                        if style == .contour {
                            path.addRoundedRect(in: rect, cornerSize: CGSize(width: width * 0.3, height: height * 0.3))
                        } else {
                            path.addEllipse(in: rect)
                        }
                        let opacity = 0.12 + Double(index) / 30
                        context.stroke(path, with: .color(.white.opacity(opacity)), lineWidth: max(0.6, size.width / 600))
                    }
                }
                .rotationEffect(.degrees(style == .contour ? -28 : -18))
            }
            .clipped()
            .accessibilityHidden(true)
    }
}
