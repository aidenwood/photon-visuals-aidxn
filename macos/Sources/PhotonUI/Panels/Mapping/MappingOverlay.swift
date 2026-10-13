import SwiftUI

struct MappingOverlay: View {
    @Binding var quad: MappingQuad
    @State private var dragOrigin: SIMD2<Double>?
    private let labels = ["Top left", "Top right", "Bottom right", "Bottom left"]

    var body: some View {
        GeometryReader { geometry in
            let points = quad.corners.map { CGPoint(x: $0.x * geometry.size.width, y: $0.y * geometry.size.height) }
            Path { path in
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
            }
            .stroke(PhotonTheme.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .allowsHitTesting(false)

            ForEach(0..<4) { corner in
                Rectangle()
                    .fill(PhotonTheme.accent)
                    .frame(width: 8, height: 8)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .position(points[corner])
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        if dragOrigin == nil { dragOrigin = quad.corners[corner] }
                        guard let origin = dragOrigin, geometry.size.width > 0, geometry.size.height > 0 else { return }
                        let delta = SIMD2<Double>(drag.translation.width / geometry.size.width,
                                                  drag.translation.height / geometry.size.height)
                        quad = quad.moving(corner, to: origin + delta)
                    }.onEnded { _ in dragOrigin = nil })
                    .help("Drag \(labels[corner].lowercased()) corner")
                    .accessibilityLabel("\(labels[corner]) slice corner")
                    .accessibilityValue("X \(Int(quad.corners[corner].x * 100))%, Y \(Int(quad.corners[corner].y * 100))%")
            }
        }
    }
}
