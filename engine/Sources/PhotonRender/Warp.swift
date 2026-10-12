// Photon warp — projection-mapping geometry.
//
// A projector is almost never square to the surface it throws at, so the
// rectangle the GPU rasterises is a keystone: four arbitrary corners. Drawn as
// two triangles with ordinary 2-component UVs the texture BENDS along the
// shared diagonal — the rasteriser interpolates attributes affinely and the
// correct mapping is projective, so the two halves disagree everywhere except
// on the diagonal itself. Any straight line in the content kinks there.
//
// The fix is to carry the homography through the interpolator: attach
// `uvq = H⁻¹ · (x, y, 1)` at each vertex and divide by q per fragment. H⁻¹ is a
// linear map and (x, y, 1) interpolates affinely across a flat triangle, so the
// interpolated uvq equals H⁻¹ of the fragment's own position EXACTLY — the
// divide recovers the true texture coordinate at every pixel, not just at the
// three corners. Same trick the hardware uses for 3D perspective correction,
// done by hand because our quad is flat in clip space and the hardware has
// nothing to correct for.
//
// Geometry only: no MTLDevice, no encoder, no texture. Everything here is a
// value type and a pure function, so the maths is testable without a GPU.
// `WarpShader.source` is the matching MSL, kept beside the maths that feeds it.

import Foundation
import simd

// MARK: - Errors

/// Why a surface could not be turned into a mesh.
public enum WarpError: Error, Sendable, CustomStringConvertible {
    /// Three or more corners are collinear, or two coincide — there is no
    /// homography from the unit square onto that shape.
    case degenerateQuad
    /// The corners cross (bowtie), a grid offset folded a cell back over itself,
    /// or a control point was dragged past the mapping's vanishing line. The
    /// first two are caught by ``QuadCorners/isConvex`` on the cell's own
    /// outline; the third by the sign of q at the control point. All three
    /// render as a mirrored smear rather than a warp.
    case nonConvexQuad(column: Int, row: Int)
    /// Index buffers are 16-bit; a grid finer than ~128×128 overflows them.
    case meshTooLarge(vertices: Int)

    public var description: String {
        switch self {
        case .degenerateQuad:
            return "degenerate quad: corners are collinear or coincident"
        case let .nonConvexQuad(c, r):
            return "cell (\(c), \(r)) is non-convex or crosses the vanishing line"
        case let .meshTooLarge(v):
            return "mesh needs \(v) vertices, 16-bit indices address 65536"
        }
    }
}

// MARK: - Corners

/// Four corners in the order the unit square visits them: (0,0), (1,0), (1,1),
/// (0,1). `v` increases downward, matching texture space.
public struct QuadCorners: Sendable, Equatable {
    /// Unit-square (0, 0).
    public var topLeft: SIMD2<Float>
    /// Unit-square (1, 0).
    public var topRight: SIMD2<Float>
    /// Unit-square (1, 1).
    public var bottomRight: SIMD2<Float>
    /// Unit-square (0, 1).
    public var bottomLeft: SIMD2<Float>

    /// Corners in unit-square order.
    public init(topLeft: SIMD2<Float>, topRight: SIMD2<Float>,
                bottomRight: SIMD2<Float>, bottomLeft: SIMD2<Float>) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// Index in unit-square order: 0 = (0,0), 1 = (1,0), 2 = (1,1), 3 = (0,1).
    /// The whole file relies on this order lining up with ``Homography/unitSquare(to:)``.
    public subscript(index: Int) -> SIMD2<Float> {
        get {
            switch index {
            case 0: return topLeft
            case 1: return topRight
            case 2: return bottomRight
            default: return bottomLeft
            }
        }
        set {
            switch index {
            case 0: topLeft = newValue
            case 1: topRight = newValue
            case 2: bottomRight = newValue
            default: bottomLeft = newValue
            }
        }
    }

    /// An axis-aligned rectangle, corners in unit-square order.
    public static func rect(x: Float, y: Float, width: Float, height: Float) -> QuadCorners {
        QuadCorners(topLeft: SIMD2(x, y),
                    topRight: SIMD2(x + width, y),
                    bottomRight: SIMD2(x + width, y + height),
                    bottomLeft: SIMD2(x, y + height))
    }

    /// The identity quad: (0,0) → (1,1).
    public static let unitSquare = QuadCorners.rect(x: 0, y: 0, width: 1, height: 1)

    /// Full-viewport quad in Metal clip space.
    public static let clipSpace = QuadCorners.rect(x: -1, y: -1, width: 2, height: 2)

    /// Mean of the four corners. Used as the normalisation reference so q lands
    /// near 1 in the middle of the surface rather than near 1 at one corner.
    public var centroid: SIMD2<Float> {
        (topLeft + topRight + bottomRight + bottomLeft) * 0.25
    }

    /// True when the corners wind a convex quadrilateral — either direction, with
    /// no collinear or coincident turn.
    ///
    /// This is the direct test, on the outline itself: every turn around the ring
    /// has to bend the same way. A bowtie reverses, a corner dragged inside the
    /// other three reverses, a collapsed cell gives a zero turn. The tolerance is
    /// relative to the longest edge, so it means the same thing for a clip-space
    /// quad and for one cell of a 64×64 grid.
    public var isConvex: Bool {
        var longest: Double = 0
        for i in 0..<4 {
            let e = self[(i + 1) % 4] - self[i]
            longest = max(longest, Double(e.x) * Double(e.x) + Double(e.y) * Double(e.y))
        }
        guard longest > 0 else { return false }
        let tolerance = longest * 1e-6
        var sign = 0
        for i in 0..<4 {
            let a = self[i], b = self[(i + 1) % 4], c = self[(i + 2) % 4]
            let cross = Double(b.x - a.x) * Double(c.y - b.y)
                      - Double(b.y - a.y) * Double(c.x - b.x)
            if abs(cross) <= tolerance { return false }
            let s = cross > 0 ? 1 : -1
            if sign == 0 { sign = s } else if s != sign { return false }
        }
        return true
    }
}

// MARK: - Homography

/// A 3×3 projective transform of the plane.
///
/// Stored row-major in `Double`. The 8×8 solve on a steep keystone loses around
/// four significant digits through elimination; in `Float` that surfaces as UV
/// swim at the far corner, which is exactly where a projection map is already
/// hardest to line up. The result is narrowed to `Float` once, at the vertex.
public struct Homography: Sendable, Equatable {
    var m00: Double, m01: Double, m02: Double
    var m10: Double, m11: Double, m12: Double
    var m20: Double, m21: Double, m22: Double

    init(_ m00: Double, _ m01: Double, _ m02: Double,
         _ m10: Double, _ m11: Double, _ m12: Double,
         _ m20: Double, _ m21: Double, _ m22: Double) {
        self.m00 = m00; self.m01 = m01; self.m02 = m02
        self.m10 = m10; self.m11 = m11; self.m12 = m12
        self.m20 = m20; self.m21 = m21; self.m22 = m22
    }

    /// The identity transform.
    public static let identity = Homography(1, 0, 0, 0, 1, 0, 0, 0, 1)

    /// The homography taking the unit square to `quad`, or `nil` if `quad` is
    /// degenerate.
    ///
    /// Eight unknowns, four point correspondences, two equations each. With
    /// h₂₂ pinned to 1 (projective transforms are scale-invariant, so one degree
    /// of freedom is free) each correspondence (u,v) → (x,y) contributes
    ///
    ///     u·h₀₀ + v·h₀₁ + h₀₂ − x·u·h₂₀ − x·v·h₂₁ = x
    ///     u·h₁₀ + v·h₁₁ + h₁₂ − y·u·h₂₀ − y·v·h₂₁ = y
    ///
    /// which is linear in the unknowns — the nonlinearity of the projective
    /// divide is absorbed by moving the denominator across the equals sign.
    public static func unitSquare(to quad: QuadCorners) -> Homography? {
        let uv: [(Double, Double)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
        var a = [Double](repeating: 0, count: 64)  // 8×8, row-major
        var b = [Double](repeating: 0, count: 8)

        for i in 0..<4 {
            let (u, v) = uv[i]
            let x = Double(quad[i].x), y = Double(quad[i].y)
            let r0 = i * 2 * 8, r1 = (i * 2 + 1) * 8

            a[r0 + 0] = u;  a[r0 + 1] = v;  a[r0 + 2] = 1
            a[r0 + 6] = -x * u; a[r0 + 7] = -x * v
            b[i * 2] = x

            a[r1 + 3] = u;  a[r1 + 4] = v;  a[r1 + 5] = 1
            a[r1 + 6] = -y * u; a[r1 + 7] = -y * v
            b[i * 2 + 1] = y
        }

        guard let h = solve8(&a, &b) else { return nil }
        return Homography(h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1)
    }

    /// The homography taking `source` onto `destination`, composed through the
    /// unit square. `nil` if either quad is degenerate.
    public static func mapping(from source: QuadCorners,
                               to destination: QuadCorners) -> Homography? {
        guard let s = unitSquare(to: source),
              let d = unitSquare(to: destination),
              let sInv = s.inverse else { return nil }
        return d * sInv
    }

    /// Gauss–Jordan with partial pivoting. `nil` when the system is singular,
    /// which for our construction means the quad has collinear corners.
    private static func solve8(_ a: inout [Double], _ b: inout [Double]) -> [Double]? {
        let n = 8
        for col in 0..<n {
            // Pivot on the largest magnitude available: without it a quad with a
            // zero-valued corner (very common — (0,0) is a corner of every
            // source rect) divides by a structural zero on the first column.
            var pivot = col
            var best = abs(a[col * n + col])
            for row in (col + 1)..<n {
                let value = abs(a[row * n + col])
                if value > best { best = value; pivot = row }
            }
            guard best > 1e-12 else { return nil }

            if pivot != col {
                for k in 0..<n { a.swapAt(col * n + k, pivot * n + k) }
                b.swapAt(col, pivot)
            }

            let inv = 1.0 / a[col * n + col]
            for k in col..<n { a[col * n + k] *= inv }
            b[col] *= inv

            for row in 0..<n where row != col {
                let f = a[row * n + col]
                if f == 0 { continue }
                for k in col..<n { a[row * n + k] -= f * a[col * n + k] }
                b[row] -= f * b[col]
            }
        }
        return b
    }

    /// Matrix product: `lhs` applied after `rhs`.
    public static func * (lhs: Homography, rhs: Homography) -> Homography {
        Homography(
            lhs.m00 * rhs.m00 + lhs.m01 * rhs.m10 + lhs.m02 * rhs.m20,
            lhs.m00 * rhs.m01 + lhs.m01 * rhs.m11 + lhs.m02 * rhs.m21,
            lhs.m00 * rhs.m02 + lhs.m01 * rhs.m12 + lhs.m02 * rhs.m22,
            lhs.m10 * rhs.m00 + lhs.m11 * rhs.m10 + lhs.m12 * rhs.m20,
            lhs.m10 * rhs.m01 + lhs.m11 * rhs.m11 + lhs.m12 * rhs.m21,
            lhs.m10 * rhs.m02 + lhs.m11 * rhs.m12 + lhs.m12 * rhs.m22,
            lhs.m20 * rhs.m00 + lhs.m21 * rhs.m10 + lhs.m22 * rhs.m20,
            lhs.m20 * rhs.m01 + lhs.m21 * rhs.m11 + lhs.m22 * rhs.m21,
            lhs.m20 * rhs.m02 + lhs.m21 * rhs.m12 + lhs.m22 * rhs.m22)
    }

    /// The inverse transform, or `nil` if the matrix is singular.
    public var inverse: Homography? {
        let c00 = m11 * m22 - m12 * m21
        let c01 = m02 * m21 - m01 * m22
        let c02 = m01 * m12 - m02 * m11
        let det = m00 * c00 + m10 * c01 + m20 * c02
        guard abs(det) > 1e-18 else { return nil }
        let d = 1.0 / det
        return Homography(
            c00 * d, c01 * d, c02 * d,
            (m12 * m20 - m10 * m22) * d, (m00 * m22 - m02 * m20) * d, (m02 * m10 - m00 * m12) * d,
            (m10 * m21 - m11 * m20) * d, (m01 * m20 - m00 * m21) * d, (m00 * m11 - m01 * m10) * d)
    }

    /// The homogeneous image of `(x, y, 1)` — the raw (u·q, v·q, q) triple,
    /// **undivided**. This is the vertex attribute; dividing here would throw
    /// away the very information the fragment stage needs.
    public func homogeneous(_ p: SIMD2<Float>) -> SIMD3<Double> {
        let x = Double(p.x), y = Double(p.y)
        return SIMD3(m00 * x + m01 * y + m02,
                     m10 * x + m11 * y + m12,
                     m20 * x + m21 * y + m22)
    }

    /// The image of a point, perspective divide applied. Returns `nil` on the
    /// vanishing line, where the point has no finite image.
    public func apply(_ p: SIMD2<Float>) -> SIMD2<Float>? {
        let h = homogeneous(p)
        guard abs(h.z) > 1e-12 else { return nil }
        return SIMD2(Float(h.x / h.z), Float(h.y / h.z))
    }

    /// Every element scaled. The projective meaning is unchanged (uv = xy/q is
    /// scale-invariant) but the interpolated magnitudes move, which is why
    /// normalisation has to be uniform across a cell and never per vertex —
    /// per-vertex scaling would break the linearity the whole scheme rests on.
    public func scaled(by s: Double) -> Homography {
        Homography(m00 * s, m01 * s, m02 * s,
                   m10 * s, m11 * s, m12 * s,
                   m20 * s, m21 * s, m22 * s)
    }

    /// Scaled so that `homogeneous(reference).z == 1`. Keeps q around 1 over the
    /// surface, well inside `Float` precision, instead of wherever the solve
    /// happened to leave it. `nil` if the reference point is on the vanishing line.
    public func normalised(at reference: SIMD2<Float>) -> Homography? {
        let q = m20 * Double(reference.x) + m21 * Double(reference.y) + m22
        guard abs(q) > 1e-12 else { return nil }
        return scaled(by: 1.0 / q)
    }

    /// Column-major, `Float`, ready for `setVertexBytes`. For shaders that
    /// prefer to map positions in the vertex stage rather than consume baked UVQ.
    public var float3x3: simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(Float(m00), Float(m10), Float(m20)),
                                SIMD3<Float>(Float(m01), Float(m11), Float(m21)),
                                SIMD3<Float>(Float(m02), Float(m12), Float(m22))))
    }
}

// MARK: - Soft edge

/// Per-edge blend ramps for overlapping projectors.
///
/// **The weights multiply LINEAR radiance. This is not a preference.** Two
/// projectors meeting at the band centre each contribute 0.5, and 0.5 + 0.5 = 1
/// only if the 0.5 is a fraction of light. Applied to an sRGB-encoded signal the
/// projector's own ≈2.2 EOTF turns each contribution into 0.5^2.2 = 0.22 of full
/// output, so the overlap lands at 0.44 instead of 1.0 — a dark stripe down the
/// seam, which is the exact artefact soft edge exists to remove. (Blend after
/// encoding and you get the same stripe in reverse where the curve is convex.)
/// ``encodedOverlapSum(weight:displayGamma:)`` computes the miss.
///
/// Photon composites in `rgba16Float` and encodes once in `encode_fragment`, so
/// a warp fragment shader is already in linear light — just do not "helpfully"
/// gamma-correct the weight on the way in.
public struct SoftEdge: Sendable, Equatable {
    /// Overlap width at u = 0, as a fraction of surface width. 0 disables.
    public var left: Float { didSet { left = Self.clampWidth(left) } }
    /// Overlap width at u = 1, as a fraction of surface width. 0 disables.
    public var right: Float { didSet { right = Self.clampWidth(right) } }
    /// Overlap width at v = 0, as a fraction of surface height. 0 disables.
    public var top: Float { didSet { top = Self.clampWidth(top) } }
    /// Overlap width at v = 1, as a fraction of surface height. 0 disables.
    public var bottom: Float { didSet { bottom = Self.clampWidth(bottom) } }
    /// Ramp shape. 1 is a straight line; 1.8–2.4 compensates a typical
    /// projector's S-curve and black lift. Any value keeps the pair summing to 1.
    public var gamma: Float { didSet { gamma = max(gamma, 0.01) } }

    /// All edges hard.
    public static let none = SoftEdge()

    /// A width is a fraction of the surface, 0...0.5. Past half, an axis's two
    /// ramps start overlapping each other and the band stops summing to unity.
    ///
    /// Enforced on assignment as well as in the initialiser: these are public
    /// `var`s on a value type, and a UI slider writing `edge.left` directly would
    /// otherwise walk straight past a constraint the initialiser only pretended
    /// to guarantee.
    private static func clampWidth(_ w: Float) -> Float { min(max(w, 0), 0.5) }

    /// Widths are clamped to 0...0.5, gamma to at least 0.01.
    public init(left: Float = 0, right: Float = 0, top: Float = 0, bottom: Float = 0,
                gamma: Float = 2.2) {
        // Property observers do not run during initialisation, so clamp here too.
        self.left = Self.clampWidth(left)
        self.right = Self.clampWidth(right)
        self.top = Self.clampWidth(top)
        self.bottom = Self.clampWidth(bottom)
        self.gamma = max(gamma, 0.01)
    }

    /// Blend weight across one overlap band, `t` running 0 (outer edge) to 1
    /// (inner edge).
    ///
    /// Two half-powers spliced at the centre. The splice is what guarantees
    /// `ramp(t) + ramp(1 - t) == 1` for every gamma: a bare `pow(t, gamma)` ramp
    /// only sums to 1 at gamma = 1, and every projectionist who has tried one has
    /// watched the band go dark as they tuned the curve.
    public static func ramp(_ t: Float, gamma: Float) -> Float {
        let c = min(max(t, 0), 1)
        let g = max(gamma, 0.01)
        return c <= 0.5 ? 0.5 * pow(2 * c, g)
                        : 1 - 0.5 * pow(2 * (1 - c), g)
    }

    /// Weight at a point in surface space (0...1 across the surface, v down).
    ///
    /// Opposing edges multiply. At a four-projector corner that is still exactly
    /// right: (a + (1−a))·(b + (1−b)) = 1, so the four tiles sum to unity with no
    /// special corner case.
    public func weight(u: Float, v: Float) -> Float {
        var w: Float = 1
        if left > 0 { w *= Self.ramp(u / left, gamma: gamma) }
        if right > 0 { w *= Self.ramp((1 - u) / right, gamma: gamma) }
        if top > 0 { w *= Self.ramp(v / top, gamma: gamma) }
        if bottom > 0 { w *= Self.ramp((1 - v) / bottom, gamma: gamma) }
        return w
    }

    /// Diagnostic: the linear output two projectors actually reach in the overlap
    /// when the weights were applied to sRGB-**encoded** values instead of linear
    /// light. Correct is 1.0; this returns ≈0.44 at the band centre.
    public static func encodedOverlapSum(weight w: Float, displayGamma: Float = 2.2) -> Float {
        let c = min(max(w, 0), 1)
        return pow(c, displayGamma) + pow(1 - c, displayGamma)
    }
}

// MARK: - Grid warp

/// Control-point offsets for an N×M subdivision of a surface.
///
/// Offsets are in **output space** and applied after the quad's projective map,
/// so dragging a handle in the UI moves the surface exactly where the operator
/// sees the handle. Storing them in uv space would make the same drag move
/// different distances at the near and far ends of a keystone.
public struct WarpGrid: Sendable, Equatable {
    /// Cells across. At least 1.
    public let columns: Int
    /// Cells down. At least 1.
    public let rows: Int
    /// `(columns + 1) × (rows + 1)` offsets, row-major.
    public private(set) var offsets: [SIMD2<Float>]

    /// A grid with no displacement. Dimensions clamp to 1...64 — the ceiling is
    /// the 16-bit index buffer (4 unshared vertices per cell).
    public init(columns: Int, rows: Int) {
        let c = min(max(columns, 1), 64)
        let r = min(max(rows, 1), 64)
        self.columns = c
        self.rows = r
        self.offsets = [SIMD2<Float>](repeating: .zero, count: (c + 1) * (r + 1))
    }

    /// Flat index of a control point. Traps on an out-of-range coordinate.
    ///
    /// The bounds check is not decoration: the grid is stored row-major, so
    /// `index(column: columns + 2, row: 0)` lands on a perfectly valid element of
    /// the *next* row. Without the precondition an off-by-one in UI code silently
    /// moves the wrong handle instead of crashing where the mistake is.
    public func index(column: Int, row: Int) -> Int {
        precondition(column >= 0 && column <= columns,
                     "column \(column) out of range 0...\(columns)")
        precondition(row >= 0 && row <= rows, "row \(row) out of range 0...\(rows)")
        return row * (columns + 1) + column
    }

    /// Offset of one control point.
    public subscript(column: Int, row: Int) -> SIMD2<Float> {
        get { offsets[index(column: column, row: row)] }
        set { offsets[index(column: column, row: row)] = newValue }
    }

    /// True when no control point has been moved — the mesh is then the plain
    /// keystone, just drawn as more triangles.
    public var isIdentity: Bool { offsets.allSatisfy { $0 == .zero } }
}

// MARK: - Vertex / mesh

/// One warp vertex. Field order **is** the GPU layout: six tightly packed
/// `Float`s, 24 bytes, no padding. ``WarpVertexLayout`` mirrors the offsets for
/// the `MTLVertexDescriptor`, and ``WarpSurface/selfCheck()`` asserts they still
/// agree, so reordering these fields fails loudly instead of rendering noise.
public struct WarpVertex: Sendable, Equatable {
    /// Output-space x.
    public var x: Float
    /// Output-space y.
    public var y: Float
    /// u pre-multiplied by q.
    public var uq: Float
    /// v pre-multiplied by q.
    public var vq: Float
    /// Projective denominator. Constant across a quad only when the quad is affine.
    public var q: Float
    /// Soft-edge weight sampled at this vertex, in linear light.
    public var blend: Float

    /// Output-space position.
    public var position: SIMD2<Float> { SIMD2(x, y) }
    /// The attribute the fragment shader divides.
    public var uvq: SIMD3<Float> { SIMD3(uq, vq, q) }
    /// The texture coordinate this vertex resolves to. Verification and tooling
    /// only — per-vertex division is precisely the bug this type avoids.
    public var textureCoordinate: SIMD2<Float> { SIMD2(uq / q, vq / q) }
}

/// Byte offsets for a `MTLVertexDescriptor`. `float3` at offset 8 is legal in a
/// vertex buffer: vertex attribute formats need 4-byte alignment, not the
/// 16-byte alignment `float3` carries inside a struct.
public enum WarpVertexLayout {
    /// Bytes per vertex.
    public static let stride = MemoryLayout<WarpVertex>.stride
    /// `.float2`, attribute 0.
    public static let positionOffset = 0
    /// `.float3`, attribute 1.
    public static let uvqOffset = 8
    /// `.float`, attribute 2.
    public static let blendOffset = 20
}

/// A triangulated surface, ready to copy into `MTLBuffer`s.
///
/// `device.makeBuffer(bytes: mesh.vertices, length: mesh.vertexBufferLength, …)`
/// and the index equivalent — no Metal types reach this file.
public struct WarpMesh: Sendable, Equatable {
    /// Vertices, four per cell.
    public var vertices: [WarpVertex]
    /// Triangle list, six indices per cell.
    public var indices: [UInt16]

    /// Triangles in the list.
    public var triangleCount: Int { indices.count / 3 }
    /// Bytes to allocate for the vertex buffer.
    public var vertexBufferLength: Int { vertices.count * WarpVertexLayout.stride }
    /// Bytes to allocate for the index buffer.
    public var indexBufferLength: Int { indices.count * MemoryLayout<UInt16>.stride }
}

// MARK: - Surface

/// One projector's output: a keystone quad, optional grid warp, optional soft
/// edges, and the region of the source texture it shows.
public struct WarpSurface: Sendable {
    /// Output-space corners. Clip space (−1...1) if the mesh is drawn directly.
    public var corners: QuadCorners
    /// Grid subdivision, or `nil` for a plain two-triangle keystone.
    public var grid: WarpGrid?
    /// Overlap ramps.
    public var softEdge: SoftEdge
    /// Top-left of the source region in texture space.
    public var sourceOrigin: SIMD2<Float>
    /// Size of the source region in texture space. Slicing one source across
    /// several projectors is just a different rect per surface.
    public var sourceSize: SIMD2<Float>

    /// A surface over the full source texture.
    public init(corners: QuadCorners,
                grid: WarpGrid? = nil,
                softEdge: SoftEdge = .none,
                sourceOrigin: SIMD2<Float> = SIMD2(0, 0),
                sourceSize: SIMD2<Float> = SIMD2(1, 1)) {
        self.corners = corners
        self.grid = grid
        self.softEdge = softEdge
        self.sourceOrigin = sourceOrigin
        self.sourceSize = sourceSize
    }

    /// Surface uv (0...1) → output position. The map the corners define.
    public func homography() throws -> Homography {
        guard let h = Homography.unitSquare(to: corners) else { throw WarpError.degenerateQuad }
        return h
    }

    /// Where a control point sits in output space, offset included. For drawing
    /// handles — the UI and the mesh must agree, so both come from here.
    ///
    /// The undisplaced position is the **projective** image of (u, v), not a
    /// bilinear lerp of the corners. Bilinear would sag away from the keystone's
    /// edges, so an operator aligning a grid point to a physical feature would be
    /// fighting an error the renderer invented.
    public func controlPoint(column: Int, row: Int) throws -> SIMD2<Float> {
        let h = try homography()
        let cols = grid?.columns ?? 1
        let rows = grid?.rows ?? 1
        let u = Float(min(max(column, 0), cols)) / Float(cols)
        let v = Float(min(max(row, 0), rows)) / Float(rows)
        guard let p = h.apply(SIMD2(u, v)) else { throw WarpError.degenerateQuad }
        return p + (grid?[min(max(column, 0), cols), min(max(row, 0), rows)] ?? .zero)
    }

    /// Builds the mesh: position + UVQ + blend weight per vertex, triangle list
    /// per cell.
    ///
    /// **Every attribute is computed once per CONTROL POINT and reused by all
    /// four cells that touch it.** That sharing is the whole correctness argument
    /// for the grid path, and it is not an optimisation.
    ///
    /// The tempting alternative — fit a separate homography to each cell's own
    /// four displaced corners — is exact *inside* a cell and silently wrong
    /// *between* cells. Two neighbours render their shared edge from their own
    /// two vertices; the rasteriser interpolates each side's (u·q, v·q, q) along
    /// that edge and divides. Both sides agree at the two endpoints, because the
    /// endpoints are control points. In between they do not: a 1D projective map
    /// along a segment is pinned by its endpoints *plus* a vanishing point, and
    /// each cell's vanishing point comes from its own pair of opposite edges. The
    /// two sides therefore disagree across the interior of every shared edge — a
    /// hard texture discontinuity, not a kink. Measured on a 4×3 grid, a 5-pixel
    /// handle drag tore by ~5 texels of a 1920-wide source and a 38-pixel drag by
    /// ~38; it grows linearly with the drag and does **not** shrink as the grid is
    /// refined. The vertex-level checks all pass while this happens, which is why
    /// ``selfCheck()`` now walks the seams.
    ///
    /// So: q comes from the surface map sampled at the control point's actual
    /// (displaced) position, u and v stay the point's nominal grid coordinates.
    /// Neighbours read the same numbers, so the seam is continuous by
    /// construction rather than by luck. With no displacement this reduces to the
    /// exact global projective map — identical to the bare-quad path, to the last
    /// bit — and inside a displaced cell the two triangles meet C0 along their
    /// diagonal. A slope kink inside a cell is the price; a tear between cells is
    /// not a price worth paying for it.
    ///
    /// Vertices are still emitted four-per-cell rather than welded, so each cell
    /// can be validated and reported by (column, row); the duplicates now carry
    /// identical data, so welding them would be a pure buffer-size win and is
    /// left as a separate change.
    public func triangulate() throws -> WarpMesh {
        let base = try homography()
        guard let inverse = base.inverse else { throw WarpError.degenerateQuad }
        let cols = grid?.columns ?? 1
        let rows = grid?.rows ?? 1

        let vertexCount = cols * rows * 4
        guard vertexCount <= Int(UInt16.max) + 1 else {
            throw WarpError.meshTooLarge(vertices: vertexCount)
        }

        // Output position → texture coordinate, in one matrix. The source rect is
        // affine, so folding it in here is exact and the shader never has to
        // correct for it.
        let toTexture = Homography(Double(sourceSize.x), 0, Double(sourceOrigin.x),
                                   0, Double(sourceSize.y), Double(sourceOrigin.y),
                                   0, 0, 1)
        // Normalised once for the whole surface. A uniform scale cannot move any
        // uv — the interpolator is homogeneous of degree one, so the factor
        // survives into both numerator and denominator and divides out — but it
        // keeps q near 1 across the surface, well inside Float's comfortable
        // range. Scaling per cell would be equally harmless for the same reason;
        // scaling per vertex would not, and would break everything.
        guard let toUVQ = (toTexture * inverse).normalised(at: corners.centroid) else {
            throw WarpError.degenerateQuad
        }

        // One position, one UVQ, one blend weight per control point.
        let pointCount = (cols + 1) * (rows + 1)
        var points = [SIMD2<Float>](repeating: .zero, count: pointCount)
        var uvqs = [SIMD3<Float>](repeating: .zero, count: pointCount)
        var blends = [Float](repeating: 0, count: pointCount)

        for row in 0...rows {
            let v = Float(row) / Float(rows)
            for col in 0...cols {
                let u = Float(col) / Float(cols)
                guard let undisplaced = base.apply(SIMD2(u, v)) else {
                    throw WarpError.degenerateQuad
                }
                let p = undisplaced + (grid?[col, row] ?? .zero)

                // q from the surface map at where the point actually ended up, so
                // perspective keeps tracking the drag; u and v stay nominal, so the
                // content follows the handle. Undisplaced, the two are consistent
                // and this is exactly `toUVQ.homogeneous(p)`.
                let q = toUVQ.homogeneous(p).z
                guard q > 1e-6 else {
                    throw WarpError.nonConvexQuad(column: min(col, cols - 1),
                                                  row: min(row, rows - 1))
                }
                let tu = Double(sourceOrigin.x) + Double(sourceSize.x) * Double(u)
                let tv = Double(sourceOrigin.y) + Double(sourceSize.y) * Double(v)

                let i = row * (cols + 1) + col
                points[i] = p
                uvqs[i] = SIMD3(Float(q * tu), Float(q * tv), Float(q))
                blends[i] = softEdge.weight(u: u, v: v)
            }
        }

        var vertices = [WarpVertex]()
        vertices.reserveCapacity(vertexCount)
        var indices = [UInt16]()
        indices.reserveCapacity(cols * rows * 6)

        func emit(_ i: Int) {
            vertices.append(WarpVertex(x: points[i].x, y: points[i].y,
                                       uq: uvqs[i].x, vq: uvqs[i].y, q: uvqs[i].z,
                                       blend: blends[i]))
        }

        for row in 0..<rows {
            for col in 0..<cols {
                let i0 = row * (cols + 1) + col
                let i1 = (row + 1) * (cols + 1) + col

                // Convexity is tested on the cell's own outline. Once neighbours
                // share one projective basis the sign of q no longer reports a cell
                // folding over on itself, so the fold has to be caught geometrically
                // — which also catches bowties and collapsed cells, and reports the
                // cell that is actually wrong.
                let outline = QuadCorners(topLeft: points[i0], topRight: points[i0 + 1],
                                          bottomRight: points[i1 + 1], bottomLeft: points[i1])
                guard outline.isConvex else {
                    throw WarpError.nonConvexQuad(column: col, row: row)
                }

                let first = UInt16(vertices.count)
                emit(i0); emit(i0 + 1); emit(i1 + 1); emit(i1)
                indices.append(contentsOf: [first, first + 1, first + 2,
                                            first, first + 2, first + 3])
            }
        }

        return WarpMesh(vertices: vertices, indices: indices)
    }
}

// MARK: - MSL

/// The matching Metal source. Lives beside the maths because the vertex layout,
/// the UVQ convention and the blend curve have to stay in step with it.
public enum WarpShader {
    /// Vertex + fragment pair consuming ``WarpVertex``. Render into the
    /// compositor's linear `rgba16Float` target; `encode_fragment` applies the
    /// transfer function once, downstream.
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Matches WarpVertex: float2 @0, float3 @8, float @20, stride 24.
    struct WarpVertexIn {
        float2 position [[attribute(0)]];
        float3 uvq      [[attribute(1)]];   // (u*q, v*q, q) — do NOT divide here
        float  blend    [[attribute(2)]];
    };

    struct WarpUniforms {
        float4 sourceRect;   // xy = origin, zw = size, texture space
        float4 edges;        // left, right, top, bottom overlap widths
        float  gamma;        // soft-edge curve
        float  opacity;
        // Per-slice colour correction. Projectors never match out of the box —
        // different lamps, different ages, different panels — so every slice
        // needs its own trim or the seams show as colour shifts even when the
        // geometry is perfect.
        float4 gain;         // rgb multiplier, a = unused
        float4 lift;         // rgb offset, a = unused
        float  outGamma;     // per-slice gamma, 1.0 = off
        int    maskCount;    // polygon points in use, 0 = no mask
        float  maskFeather;  // feather width in surface units
        int    maskInvert;   // 1 = keep OUTSIDE the polygon
        // Mask polygon in surface space (0..1), padded to float4 for alignment.
        float4 maskPoints[16];
    };

    // Signed distance to a polygon: negative inside, positive outside.
    // Distance rather than a boolean so the edge can be feathered — a hard
    // binary mask aliases badly on a projector, where the operator is looking
    // at a 3-metre-wide edge.
    static float warp_polygon_sdf(float2 p, constant float4 *pts, int n) {
        float d = dot(p - pts[0].xy, p - pts[0].xy);
        float sign = 1.0;
        for (int i = 0, j = n - 1; i < n; j = i, i++) {
            float2 a = pts[i].xy, b = pts[j].xy;
            float2 e = b - a, w = p - a;
            float2 c = w - e * saturate(dot(w, e) / max(dot(e, e), 1e-9));
            d = min(d, dot(c, c));
            // Winding test, branchless: flips sign on each crossing.
            bool3 cond = bool3(p.y >= a.y, p.y < b.y, e.x * w.y > e.y * w.x);
            if (all(cond) || all(!cond)) { sign = -sign; }
        }
        return sign * sqrt(d);
    }

    struct WarpVaryings {
        float4 position [[position]];
        float3 uvq;      // interpolated affinely in screen space — that is the point
        float  blend;
    };

    vertex WarpVaryings warp_vertex(WarpVertexIn in [[stage_in]]) {
        WarpVaryings o;
        o.position = float4(in.position, 0.0, 1.0);
        o.uvq      = in.uvq;
        o.blend    = in.blend;
        return o;
    }

    // Spliced half-powers: ramp(t) + ramp(1 - t) == 1 for every gamma, so an
    // overlapping pair always sums to unity.
    static float warp_ramp(float t, float g) {
        t = saturate(t);
        return (t <= 0.5) ? 0.5 * pow(2.0 * t, g)
                          : 1.0 - 0.5 * pow(2.0 * (1.0 - t), g);
    }

    fragment float4 warp_fragment(WarpVaryings in [[stage_in]],
                                  constant WarpUniforms &u [[buffer(0)]],
                                  texture2d<float> src [[texture(0)]])
    {
        // THE line. uvq interpolates linearly across the triangle and equals
        // H^-1 * (x, y, 1) at this exact fragment; the divide recovers the true
        // texture coordinate. Sampling with a plain interpolated float2 instead
        // bends the image along the shared diagonal of the quad.
        float2 uv = in.uvq.xy / in.uvq.z;

        constexpr sampler smp(filter::linear, address::clamp_to_edge);
        float4 c = src.sample(smp, uv);

        // Back to surface space. The source rect is affine, so this inverse is
        // exact for any sub-rect.
        float2 suv = (uv - u.sourceRect.xy) / u.sourceRect.zw;

        float w = 1.0;
        if (u.edges.x > 0.0) w *= warp_ramp(suv.x / u.edges.x, u.gamma);
        if (u.edges.y > 0.0) w *= warp_ramp((1.0 - suv.x) / u.edges.y, u.gamma);
        if (u.edges.z > 0.0) w *= warp_ramp(suv.y / u.edges.z, u.gamma);
        if (u.edges.w > 0.0) w *= warp_ramp((1.0 - suv.y) / u.edges.w, u.gamma);
        // in.blend is the same weight evaluated per vertex. Cheaper, but only
        // right where the grid is fine enough for the curve to be near-linear
        // inside a cell; on a bare quad it is a straight line through a curve.

        // LINEAR LIGHT, deliberately. The target is rgba16Float and the sRGB
        // encode happens once, later. Weight an encoded value here and the pair
        // reaches pow(w, 2.2) + pow(1 - w, 2.2) = 0.44 at the band centre instead
        // of 1.0 — the dark seam soft edge exists to remove.
        // Colour correction in LINEAR light, before the soft-edge weight, so
        // trimming a projector's colour cannot disturb the overlap sum.
        // Polygon mask, before colour so a masked-out region is truly dark
        // rather than lifted by a colour trim.
        if (u.maskCount >= 3) {
            float sd = warp_polygon_sdf(suv, u.maskPoints, u.maskCount);
            float m = (u.maskFeather > 0.0)
                    ? saturate(0.5 - sd / max(u.maskFeather, 1e-5))
                    : (sd <= 0.0 ? 1.0 : 0.0);
            if (u.maskInvert != 0) { m = 1.0 - m; }
            c.rgb *= m;
            c.a   *= m;
        }

        float3 rgb = c.rgb * u.gain.rgb + u.lift.rgb;
        if (u.outGamma != 1.0) {
            rgb = pow(max(rgb, 0.0), float3(u.outGamma));
        }
        return float4(max(rgb, 0.0) * w * u.opacity, c.a);
    }
    """
}

// MARK: - Self-check

#if DEBUG
extension WarpSurface {
    /// Proves the geometry without a GPU or a test target: returns the list of
    /// failures, empty when everything holds. Asserts as well so a debug build
    /// that calls it stops at the first broken invariant.
    ///
    /// Lives here rather than in `Tests/` because adding a test target means
    /// editing `Package.swift`, which this file is not allowed to touch.
    @discardableResult
    public static func selfCheck() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ message: @autoclosure () -> String) {
            if !ok { failures.append(message()) }
        }
        func near(_ a: Float, _ b: Float, _ tol: Float = 1e-4) -> Bool { abs(a - b) <= tol }

        // A trapezoid with real perspective in it: top edge wider than bottom.
        let keystone = QuadCorners(topLeft: SIMD2(-0.8, -0.5), topRight: SIMD2(0.8, -0.5),
                                   bottomRight: SIMD2(0.5, 0.5), bottomLeft: SIMD2(-0.5, 0.5))

        // 1. The homography hits all four corners exactly.
        guard let h = Homography.unitSquare(to: keystone) else {
            return ["unitSquare(to:) failed on a valid keystone"]
        }
        for (i, uv) in [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)].enumerated() {
            guard let p = h.apply(uv) else { check(false, "corner \(i) has no image"); continue }
            check(near(p.x, keystone[i].x, 1e-5) && near(p.y, keystone[i].y, 1e-5),
                  "corner \(i): got \(p), want \(keystone[i])")
        }

        // 2. Round trip: inverse maps the corners back to the unit square.
        guard let hInv = h.inverse else { return failures + ["keystone homography is singular"] }
        for (i, uv) in [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)].enumerated() {
            guard let back = hInv.apply(keystone[i]) else {
                check(false, "inverse corner \(i) has no image"); continue
            }
            check(near(back.x, uv.x, 1e-5) && near(back.y, uv.y, 1e-5),
                  "inverse corner \(i): got \(back), want \(uv)")
        }

        // 3. Degenerate input is rejected, not silently fudged.
        let collinear = QuadCorners(topLeft: SIMD2(0, 0), topRight: SIMD2(1, 1),
                                    bottomRight: SIMD2(2, 2), bottomLeft: SIMD2(3, 3))
        check(Homography.unitSquare(to: collinear) == nil, "collinear quad produced a homography")

        // 4. The keystone mesh: q must vary. Equal q everywhere is the affine
        //    case, i.e. the bug.
        guard let mesh = try? WarpSurface(corners: keystone).triangulate() else {
            return failures + ["triangulate() threw on a valid keystone"]
        }
        check(mesh.vertices.count == 4 && mesh.indices.count == 6,
              "bare quad: \(mesh.vertices.count) verts / \(mesh.indices.count) indices")
        let qs = mesh.vertices.map(\.q)
        let spread = (qs.max() ?? 0) / max(qs.min() ?? 1, 1e-6)
        check(spread > 1.05, "q spread \(spread) — mapping is affine, not projective")
        check(qs.allSatisfy { $0 > 0 }, "non-positive q in a convex keystone")

        // 5. …and an affine quad must have uniform q, or normalisation is adding
        //    perspective that is not there.
        let rect = QuadCorners.rect(x: -0.5, y: -0.5, width: 1, height: 1)
        if let flat = try? WarpSurface(corners: rect).triangulate() {
            check(flat.vertices.allSatisfy { near($0.q, 1, 1e-6) },
                  "affine quad has non-unit q: \(flat.vertices.map(\.q))")
        } else {
            check(false, "triangulate() threw on an axis-aligned rect")
        }

        // 6. Corner UVs resolve to the unit square.
        let wantUV: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        for (i, vertex) in mesh.vertices.enumerated() {
            let uv = vertex.textureCoordinate
            check(near(uv.x, wantUV[i].x, 1e-5) && near(uv.y, wantUV[i].y, 1e-5),
                  "vertex \(i) uv \(uv), want \(wantUV[i])")
        }

        // 7. The real proof. Walk halfway down the shared diagonal the way the
        //    rasteriser does — lerp the attributes, then divide — and compare
        //    against the exact inverse map of that screen point. They must agree,
        //    and must NOT agree with (0.5, 0.5), which is what plain 2-component
        //    UVs would have produced.
        let a = mesh.vertices[0], b = mesh.vertices[2]
        let lerped = SIMD3<Float>((a.uq + b.uq) * 0.5, (a.vq + b.vq) * 0.5, (a.q + b.q) * 0.5)
        let interpolated = SIMD2(lerped.x / lerped.z, lerped.y / lerped.z)
        let midPosition = (a.position + b.position) * 0.5
        guard let exact = hInv.apply(midPosition) else {
            return failures + ["diagonal midpoint has no image"]
        }
        check(near(interpolated.x, exact.x, 1e-5) && near(interpolated.y, exact.y, 1e-5),
              "diagonal midpoint: interpolated \(interpolated) vs exact \(exact)")
        let affineError = max(abs(interpolated.x - 0.5), abs(interpolated.y - 0.5))
        check(affineError > 0.01,
              "interpolated midpoint \(interpolated) is affine's answer — nothing is being corrected")

        // 8. A bowtie is caught rather than rendered as a smear.
        let bowtie = QuadCorners(topLeft: SIMD2(-1, -1), topRight: SIMD2(1, 1),
                                 bottomRight: SIMD2(1, -1), bottomLeft: SIMD2(-1, 1))
        do {
            _ = try WarpSurface(corners: bowtie).triangulate()
            check(false, "bowtie quad triangulated without complaint")
        } catch {
            // expected
        }

        // 9. Grid with zero offsets is the same surface, more triangles: every
        //    control point still lands on the projective map, and the uv field
        //    matches the bare quad's.
        var grid = WarpGrid(columns: 4, rows: 3)
        check(grid.isIdentity, "fresh grid is not identity")
        if let subdivided = try? WarpSurface(corners: keystone, grid: grid).triangulate() {
            check(subdivided.vertices.count == 4 * 4 * 3, "grid vertex count \(subdivided.vertices.count)")
            check(subdivided.indices.count == 6 * 4 * 3, "grid index count \(subdivided.indices.count)")
            for vertex in subdivided.vertices {
                let uv = vertex.textureCoordinate
                guard let want = hInv.apply(vertex.position) else {
                    check(false, "grid vertex off the map"); continue
                }
                check(near(uv.x, want.x, 1e-4) && near(uv.y, want.y, 1e-4),
                      "grid vertex uv \(uv) vs quad uv \(want)")
            }
        } else {
            check(false, "triangulate() threw on an identity grid")
        }

        // 10. A displaced control point moves the mesh, and controlPoint() agrees
        //     with where the mesh actually put it — the UI draws handles from it.
        grid[2, 1] = SIMD2(0.05, -0.07)
        check(!grid.isIdentity, "displaced grid still reports identity")
        let warped = WarpSurface(corners: keystone, grid: grid)
        if let handle = try? warped.controlPoint(column: 2, row: 1),
           let base = h.apply(SIMD2(2.0 / 4.0, 1.0 / 3.0)),
           let displaced = try? warped.triangulate() {
            check(near(handle.x, base.x + 0.05) && near(handle.y, base.y - 0.07),
                  "controlPoint \(handle) does not include its offset")
            check(displaced.vertices.contains { near($0.x, handle.x) && near($0.y, handle.y) },
                  "no mesh vertex at the displaced control point")
        } else {
            check(false, "displaced grid failed to build")
        }

        // 11. Soft edge: complementary ramps sum to exactly 1 at every gamma. If
        //     this slips, two projectors never sum to white.
        for gamma in [Float(1.0), 1.8, 2.2, 3.0] {
            for step in 0...20 {
                let t = Float(step) / 20
                let sum = SoftEdge.ramp(t, gamma: gamma) + SoftEdge.ramp(1 - t, gamma: gamma)
                check(near(sum, 1, 1e-5), "ramp(\(t)) + ramp(\(1 - t)) = \(sum) at gamma \(gamma)")
            }
        }
        check(near(SoftEdge.ramp(0, gamma: 2.2), 0), "ramp(0) != 0")
        check(near(SoftEdge.ramp(1, gamma: 2.2), 1), "ramp(1) != 1")
        check(near(SoftEdge.ramp(0.5, gamma: 2.2), 0.5), "ramp(0.5) != 0.5")
        var previous: Float = -1
        for step in 0...32 {
            let value = SoftEdge.ramp(Float(step) / 32, gamma: 2.2)
            check(value >= previous - 1e-6, "ramp is not monotonic at \(step)")
            previous = value
        }

        // 12. Edge weights: interior untouched, band centre at half, outside at zero.
        let edge = SoftEdge(left: 0.2, right: 0.2, gamma: 2.2)
        check(near(edge.weight(u: 0.5, v: 0.5), 1), "interior weight \(edge.weight(u: 0.5, v: 0.5))")
        check(near(edge.weight(u: 0.1, v: 0.5), 0.5), "band centre \(edge.weight(u: 0.1, v: 0.5))")
        check(near(edge.weight(u: 0, v: 0.5), 0), "outer edge is lit")
        check(near(edge.weight(u: 0.1, v: 0.5) + edge.weight(u: 0.9, v: 0.5), 1),
              "opposed bands do not sum to 1")
        let corner = SoftEdge(left: 0.2, top: 0.2, gamma: 2.2)
        // Four tiles meeting at a corner: the weights must still sum to unity.
        let cornerSum = corner.weight(u: 0.1, v: 0.1)
            + SoftEdge(right: 0.2, top: 0.2, gamma: 2.2).weight(u: 0.9, v: 0.1)
            + SoftEdge(left: 0.2, bottom: 0.2, gamma: 2.2).weight(u: 0.1, v: 0.9)
            + SoftEdge(right: 0.2, bottom: 0.2, gamma: 2.2).weight(u: 0.9, v: 0.9)
        check(near(cornerSum, 1, 1e-5), "four-way corner sums to \(cornerSum)")
        check(SoftEdge(left: 0.9).left == 0.5, "edge width was not clamped")

        // 13. Blend weights reached the vertices.
        if let blended = try? WarpSurface(corners: keystone,
                                          grid: WarpGrid(columns: 8, rows: 8),
                                          softEdge: edge).triangulate() {
            check(blended.vertices.contains { $0.blend < 0.01 }, "no fully-dark vertex in the ramp")
            check(blended.vertices.contains { $0.blend > 0.99 }, "no full-brightness vertex")
        } else {
            check(false, "soft-edged grid failed to build")
        }

        // 14. The linear-light claim, as a number: half and half is 1.0 in linear
        //     light and 0.44 if the same weights are applied to encoded values.
        check(near(0.5 + 0.5, 1), "arithmetic is broken, stop reading")
        let encoded = SoftEdge.encodedOverlapSum(weight: 0.5)
        check(encoded < 0.95, "encoded overlap sum \(encoded) — the stripe should be obvious")
        check(near(encoded, 0.435, 0.01), "encoded overlap sum drifted: \(encoded)")
        check(near(SoftEdge.encodedOverlapSum(weight: 0.5, displayGamma: 1.0), 1),
              "gamma 1.0 must be lossless")

        // 15. A source sub-rect is baked into the UVQ, not corrected downstream.
        let sliced = WarpSurface(corners: keystone,
                                 sourceOrigin: SIMD2(0.5, 0),
                                 sourceSize: SIMD2(0.5, 1))
        if let sliceMesh = try? sliced.triangulate() {
            check(near(sliceMesh.vertices[0].textureCoordinate.x, 0.5, 1e-5),
                  "slice top-left u \(sliceMesh.vertices[0].textureCoordinate.x), want 0.5")
            check(near(sliceMesh.vertices[1].textureCoordinate.x, 1.0, 1e-5),
                  "slice top-right u \(sliceMesh.vertices[1].textureCoordinate.x), want 1.0")
        } else {
            check(false, "sliced surface failed to build")
        }

        // 16. The GPU layout the vertex descriptor is written against.
        check(WarpVertexLayout.stride == 24, "vertex stride \(WarpVertexLayout.stride), want 24")
        check(MemoryLayout<WarpVertex>.offset(of: \.x) == WarpVertexLayout.positionOffset,
              "position offset moved")
        check(MemoryLayout<WarpVertex>.offset(of: \.uq) == WarpVertexLayout.uvqOffset,
              "uvq offset moved")
        check(MemoryLayout<WarpVertex>.offset(of: \.blend) == WarpVertexLayout.blendOffset,
              "blend offset moved")

        // 17. Grid limits are enforced where they are cheap to enforce.
        check(WarpGrid(columns: 0, rows: 0).columns == 1, "zero-column grid was allowed")
        check(WarpGrid(columns: 500, rows: 500).columns == 64, "grid size was not clamped")

        // 18. The seam test every check above is blind to. Neighbouring cells draw
        //     their shared edge from their own two vertices; walk that edge the way
        //     the rasteriser does — lerp the attributes, divide — from BOTH sides at
        //     once. The texture coordinates must agree at every step, not just at
        //     the endpoints. A per-cell-homography grid passes checks 1-17 and still
        //     tears here by tens of texels.
        var seam = WarpGrid(columns: 4, rows: 3)
        seam[1, 0] = SIMD2(0, -0.08)
        seam[1, 1] = SIMD2(0.06, 0)
        seam[2, 2] = SIMD2(-0.05, 0.04)
        seam[3, 1] = SIMD2(0.03, 0.05)
        if let torn = try? WarpSurface(corners: keystone, grid: seam).triangulate() {
            // Cell (c, r) owns vertices [((r * cols) + c) * 4 ..< +4] as TL,TR,BR,BL.
            func cellVertices(_ c: Int, _ r: Int) -> [WarpVertex] {
                let start = (r * 4 + c) * 4
                return Array(torn.vertices[start..<(start + 4)])
            }
            func edgeUV(_ a: WarpVertex, _ b: WarpVertex, _ t: Float) -> SIMD2<Float> {
                let q = a.q + (b.q - a.q) * t
                return SIMD2((a.uq + (b.uq - a.uq) * t) / q,
                             (a.vq + (b.vq - a.vq) * t) / q)
            }
            var worstTear: Float = 0
            var worstGap: Float = 0
            func compare(_ a0: WarpVertex, _ a1: WarpVertex,
                         _ b0: WarpVertex, _ b1: WarpVertex) {
                worstGap = max(worstGap, max(simd_distance(a0.position, b0.position),
                                             simd_distance(a1.position, b1.position)))
                for step in 1..<16 {
                    let t = Float(step) / 16
                    worstTear = max(worstTear, simd_distance(edgeUV(a0, a1, t),
                                                             edgeUV(b0, b1, t)))
                }
            }
            for r in 0..<3 {
                for c in 0..<4 {
                    let me = cellVertices(c, r)
                    // Right neighbour: my TR→BR is its TL→BL.
                    if c + 1 < 4 {
                        let other = cellVertices(c + 1, r)
                        compare(me[1], me[2], other[0], other[3])
                    }
                    // Lower neighbour: my BL→BR is its TL→TR.
                    if r + 1 < 3 {
                        let other = cellVertices(c, r + 1)
                        compare(me[3], me[2], other[0], other[1])
                    }
                }
            }
            check(worstGap < 1e-6, "displaced grid leaves a positional gap of \(worstGap)")
            check(worstTear < 1e-5,
                  "texture tears across a cell seam by \(worstTear) uv — "
                  + "\(worstTear * 1920) texels of a 1920-wide source")
        } else {
            check(false, "seam grid failed to build")
        }

        // 19. Convexity is read off the outline, so a fold is caught even when all
        //     four corners still sit on the near side of the vanishing line.
        check(QuadCorners.unitSquare.isConvex, "unit square reported non-convex")
        check(keystone.isConvex, "keystone reported non-convex")
        check(!bowtie.isConvex, "bowtie reported convex")
        check(!collinear.isConvex, "collinear quad reported convex")
        // A corner dragged inside the triangle of the other three.
        check(!QuadCorners(topLeft: SIMD2(-1, -1), topRight: SIMD2(1, -1),
                           bottomRight: SIMD2(-0.2, -0.4), bottomLeft: SIMD2(-1, 1)).isConvex,
              "concave quad reported convex")
        var folded = WarpGrid(columns: 2, rows: 2)
        folded[1, 1] = SIMD2(-0.9, -0.9)   // centre handle dragged past a corner
        do {
            _ = try WarpSurface(corners: keystone, grid: folded).triangulate()
            check(false, "a folded cell triangulated without complaint")
        } catch {
            // expected
        }

        // 20. The clamps have to survive assignment, not just initialisation —
        //     these are public vars on a value type, and an invariant only the
        //     initialiser enforces is not an invariant.
        var mutated = SoftEdge(left: 0.2, right: 0.2)
        mutated.left = 0.9
        check(mutated.left == 0.5, "left width \(mutated.left) escaped the clamp on assignment")
        mutated.right = -3
        check(mutated.right == 0, "negative width \(mutated.right) escaped the clamp")
        mutated.gamma = -5
        check(mutated.gamma >= 0.01, "gamma \(mutated.gamma) escaped the clamp on assignment")

        assert(failures.isEmpty, "WarpSurface.selfCheck failed:\n" + failures.joined(separator: "\n"))
        return failures
    }
}
#endif
