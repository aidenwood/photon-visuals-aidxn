import Foundation

/// Editor coordinates, 0...1 with top-left origin; TL, TR, BR, BL order.
public struct MappingQuad: Equatable, Sendable {
    public private(set) var corners: [SIMD2<Double>]
    public static let identity = MappingQuad(corners: [.init(0, 0), .init(1, 0), .init(1, 1), .init(0, 1)])
    private init(corners: [SIMD2<Double>]) { self.corners = corners }

    public func moving(_ index: Int, to point: SIMD2<Double>) -> Self {
        guard corners.indices.contains(index), point.x.isFinite, point.y.isFinite else { return self }
        var candidate = corners
        candidate[index] = .init(min(1, max(0, point.x)), min(1, max(0, point.y)))
        // Reject crossed, collapsed or reversed quads before they reach the renderer.
        for i in 0..<4 {
            let a = candidate[(i + 1) % 4] - candidate[i]
            let b = candidate[(i + 2) % 4] - candidate[(i + 1) % 4]
            guard a.x * b.y - a.y * b.x > 0.0001 else { return self }
        }
        return Self(corners: candidate)
    }
}
