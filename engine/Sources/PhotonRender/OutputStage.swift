// Output stage — composition → warped projector output.
//
// The composite is produced once, in linear light, into an offscreen target.
// This stage then draws one warped mesh per slice, sampling that target with
// **projective** UVs and applying soft-edge blend weights, encoding to the
// display exactly once at the very end.
//
// Two decisions here are load-bearing and expensive to reverse:
//
//  1. **Projective (homography) UV interpolation.** A keystoned quad drawn as
//     two triangles with ordinary 2-component UVs bends the texture along the
//     diagonal, because affine interpolation is wrong under perspective. The
//     mesh carries uvq and the fragment divides by q.
//
//  2. **Soft edge blends in LINEAR light.** Two projectors overlapping at 50%
//     each should sum to 100% *of light*; sRGB values are not proportional to
//     light, so blending in gamma space leaves a visible stripe down the
//     overlap — the exact artifact soft edge exists to remove.

import Metal
import simd

/// One projector's worth of output: where it samples from, and where it lands.
public struct OutputSlice {
    /// Warp geometry and soft-edge configuration.
    public var surface: WarpSurface
    /// Per-slice output level, for matching projector brightness.
    public var opacity: Float
    /// Per-channel multiplier. Trims colour between projectors.
    public var gain: SIMD3<Float>
    /// Per-channel offset, for lifting crushed blacks on a tired lamp.
    public var lift: SIMD3<Float>
    /// Per-slice gamma. 1.0 disables it.
    public var outGamma: Float
    /// Mask polygon in surface space (0..1). Fewer than 3 points = no mask.
    ///
    /// Used to cut output away from architecture that must not be lit — a
    /// doorway, a window, the edge of a building.
    public var mask: [SIMD2<Float>]
    /// Feather width in surface units. 0 is a hard edge, which aliases badly
    /// on a projector where the operator is looking at a metres-wide boundary.
    public var maskFeather: Float
    /// Keep the OUTSIDE of the polygon instead of the inside.
    public var maskInvert: Bool

    /// Largest polygon the shader can carry.
    public static let maxMaskPoints = 16

    public init(surface: WarpSurface, opacity: Float = 1,
                gain: SIMD3<Float> = .init(1, 1, 1),
                lift: SIMD3<Float> = .init(0, 0, 0),
                outGamma: Float = 1,
                mask: [SIMD2<Float>] = [],
                maskFeather: Float = 0.01,
                maskInvert: Bool = false) {
        self.mask = Array(mask.prefix(OutputSlice.maxMaskPoints))
        self.maskFeather = maskFeather
        self.maskInvert = maskInvert
        self.surface = surface
        self.opacity = opacity
        self.gain = gain
        self.lift = lift
        self.outGamma = outGamma
    }
}

/// Draws warped, soft-edged slices from a composited texture.
public final class OutputStage {
    private let device: MTLDevice
    private var pipeline: MTLRenderPipelineState!

    /// Cached GPU buffers, keyed by slice index. Rebuilt only when geometry
    /// changes — warp meshes are static while nobody is dragging a corner, and
    /// re-uploading them every frame would be pure waste.
    private var vertexBuffers: [Int: MTLBuffer] = [:]
    private var indexBuffers: [Int: (MTLBuffer, Int)] = [:]
    private var cachedMeshes: [Int: WarpMesh] = [:]

    /// Slices that failed to triangulate, so the caller can surface it instead
    /// of silently projecting nothing.
    public private(set) var failedSlices: [Int: String] = [:]

    /// - Parameter outputPixelFormat: **must be an `_srgb` format.** The warp
    ///   fragment emits LINEAR light; the hardware performs the sRGB encode on
    ///   write, and — critically — blends overlapping slices in linear space,
    ///   which is what makes soft-edge overlap sum to full brightness instead
    ///   of showing a seam.
    public init?(device: MTLDevice, outputPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb) {
        self.device = device
        do {
            let lib = try device.makeLibrary(source: WarpShader.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "warp_vertex")
            d.fragmentFunction = lib.makeFunction(name: "warp_fragment")
            d.colorAttachments[0].pixelFormat = outputPixelFormat

            // Slices may overlap; blending is additive in linear light so an
            // overlap region sums to full brightness rather than replacing.
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].rgbBlendOperation = .add
            d.colorAttachments[0].alphaBlendOperation = .add
            d.colorAttachments[0].sourceRGBBlendFactor = .one
            d.colorAttachments[0].destinationRGBBlendFactor = .one
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .one

            let vd = MTLVertexDescriptor()
            vd.attributes[0].format = .float2          // position
            vd.attributes[0].offset = WarpVertexLayout.positionOffset
            vd.attributes[0].bufferIndex = 0
            vd.attributes[1].format = .float3          // uvq
            vd.attributes[1].offset = WarpVertexLayout.uvqOffset
            vd.attributes[1].bufferIndex = 0
            vd.attributes[2].format = .float           // blend weight
            vd.attributes[2].offset = WarpVertexLayout.blendOffset
            vd.attributes[2].bufferIndex = 0
            vd.layouts[0].stride = WarpVertexLayout.stride
            d.vertexDescriptor = vd

            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            print("[OutputStage] pipeline build failed: \(error)")
            return nil
        }
    }

    /// Uploads geometry for a slice, rebuilding only when it actually changed.
    private func buffers(for index: Int, slice: OutputSlice) -> (MTLBuffer, MTLBuffer, Int)? {
        let mesh: WarpMesh
        do {
            mesh = try slice.surface.triangulate()
        } catch {
            failedSlices[index] = String(describing: error)
            return nil
        }
        failedSlices[index] = nil

        if cachedMeshes[index] == mesh,
           let vb = vertexBuffers[index], let (ib, count) = indexBuffers[index] {
            return (vb, ib, count)
        }

        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty,
              let vb = device.makeBuffer(bytes: mesh.vertices,
                                         length: mesh.vertexBufferLength,
                                         options: .storageModeShared),
              let ib = device.makeBuffer(bytes: mesh.indices,
                                         length: mesh.indices.count * MemoryLayout<UInt16>.stride,
                                         options: .storageModeShared)
        else { return nil }

        cachedMeshes[index] = mesh
        vertexBuffers[index] = vb
        indexBuffers[index] = (ib, mesh.indices.count)
        return (vb, ib, mesh.indices.count)
    }

    /// Encodes all slices into `descriptor`, sampling `source`.
    ///
    /// `source` is the linear-light composite. Encoding to display gamma
    /// happens inside the warp fragment shader, once.
    public func encode(into cb: MTLCommandBuffer,
                       descriptor: MTLRenderPassDescriptor,
                       source: MTLTexture,
                       slices: [OutputSlice]) {
        guard !slices.isEmpty, let enc = cb.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        enc.label = "output/warp"
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)

        for (i, slice) in slices.enumerated() {
            guard let (vb, ib, indexCount) = buffers(for: i, slice: slice) else { continue }

            var u = WarpUniformsSwift(
                sourceRect: SIMD4<Float>(slice.surface.sourceOrigin.x,
                                         slice.surface.sourceOrigin.y,
                                         slice.surface.sourceSize.x,
                                         slice.surface.sourceSize.y),
                edges: SIMD4<Float>(slice.surface.softEdge.left,
                                    slice.surface.softEdge.right,
                                    slice.surface.softEdge.top,
                                    slice.surface.softEdge.bottom),
                gamma: slice.surface.softEdge.gamma,
                opacity: slice.opacity,
                gain: SIMD4<Float>(slice.gain, 0),
                lift: SIMD4<Float>(slice.lift, 0),
                outGamma: slice.outGamma,
                maskCount: Int32(slice.mask.count >= 3 ? slice.mask.count : 0),
                maskFeather: slice.maskFeather,
                maskInvert: slice.maskInvert ? 1 : 0)
            withUnsafeMutableBytes(of: &u.maskPoints) { raw in
                let p = raw.bindMemory(to: SIMD4<Float>.self)
                for (i, pt) in slice.mask.prefix(OutputSlice.maxMaskPoints).enumerated() {
                    p[i] = SIMD4<Float>(pt.x, pt.y, 0, 0)
                }
            }

            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<WarpUniformsSwift>.stride, index: 0)
            enc.drawIndexedPrimitives(type: .triangle,
                                      indexCount: indexCount,
                                      indexType: .uint16,
                                      indexBuffer: ib,
                                      indexBufferOffset: 0)
        }
        enc.endEncoding()
    }

    /// A single full-canvas slice — the no-mapping default, so an operator who
    /// has not configured anything still gets output.
    public static func identitySlice() -> OutputSlice {
        OutputSlice(surface: WarpSurface(corners: .clipSpace))
    }
}

/// Swift mirror of the shader's `WarpUniforms`. Field order and types must
/// match exactly; a mismatch here shows up as geometry that is subtly wrong
/// rather than as a clean failure.
struct WarpUniformsSwift {
    var sourceRect: SIMD4<Float>
    var edges: SIMD4<Float>
    var gamma: Float
    var opacity: Float
    var gain: SIMD4<Float>
    var lift: SIMD4<Float>
    var outGamma: Float
    var maskCount: Int32
    var maskFeather: Float
    var maskInvert: Int32
    /// 16 polygon points, padded to `float4` to match the shader's alignment.
    var maskPoints: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero,
         .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
}
