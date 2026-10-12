import SwiftUI

struct MappingOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(
                x: geometry.size.width * 0.08, y: geometry.size.height * 0.08,
                width: geometry.size.width * 0.84, height: geometry.size.height * 0.84
            )
            Path { path in
                path.addRect(rect)
                for index in 1...3 {
                    let x = rect.minX + rect.width * CGFloat(index) / 4
                    let y = rect.minY + rect.height * CGFloat(index) / 4
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(PhotonTheme.accent.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(0..<4) { corner in
                RoundedRectangle(cornerRadius: 2)
                    .fill(PhotonTheme.accent)
                    .frame(width: 9, height: 9)
                    .position(
                        x: corner.isMultiple(of: 2) ? rect.minX : rect.maxX,
                        y: corner < 2 ? rect.minY : rect.maxY
                    )
            }
            Text("SLICE 01")
                .font(.system(size: 9, weight: .semibold)).tracking(1)
                .padding(6)
                .background(PhotonTheme.accent, in: RoundedRectangle(cornerRadius: 3))
                .position(x: rect.minX + 40, y: rect.minY - 14)
        }
        .accessibilityLabel("Preview mapping grid, slice one")
        .allowsHitTesting(false)
    }
}
