// Photon compositor — register-folded multi-layer blending.
//
// The whole layer stack is folded in ONE fragment shader: every layer is
// sampled and blended in registers, bottom to top, with no intermediate
// textures and no ping-ponging. That is what makes blend modes like Difference
// and Mask possible at all — they need the accumulated result beneath them, and
// Metal's fixed-function blending cannot express that.
//
// Working space is linear (rgba16Float). Encoding happens once, at output.
// Compositing in sRGB would put a visible seam through every soft-edge blend.

import Metal
import simd

/// Layer blend modes.
///
/// ⚠️ **These raw values are a shared ABI with `photon-core`'s `BlendMode` and
/// with the `switch` in `blend_rgb` below. All three must agree exactly.**
///
/// They did not. `subtract` was missing here while present in the Rust model at
/// 8, so every mode above it was shifted by one: a document saying `Subtract`
/// rendered as Lighten, `Lighten` rendered as Darken, and `Darken` — raw value
/// 10 — had no case at all and ran off the end of the name array. That is a
/// crash, from opening a perfectly valid show file. Found 2026-10-13 by
/// diffing the two enums rather than by anything failing, which is the
/// problem: nothing here is checked against the core at build time.
public enum BlendMode: Int32, CaseIterable, Sendable {
    case over = 0, add, multiply, screen, difference, mask, overlay, hardLight,
         subtract, lighten, darken

    public var name: String {
        ["Over", "Add", "Multiply", "Screen", "Difference", "Mask",
         "Overlay", "Hard Light", "Subtract", "Lighten", "Darken"][Int(rawValue)]
    }

    /// Whether this mode must read what's underneath it.
    /// `false` means fixed-function blending could express it; one `true`
    /// anywhere in the stack forces the folded path for the whole stack.
    ///
    /// Mirrors `BlendMode::needs_destination` in `photon-core`.
    public var needsDestination: Bool {
        switch self {
        case .over, .add, .multiply, .screen, .lighten, .darken: return false
        case .difference, .mask, .overlay, .hardLight, .subtract: return true
        }
    }
}

/// What a layer draws. Values are part of the shader ABI.
public enum LayerKind: Int32, Sendable, CaseIterable {
    case solid = 0, gradient, rings, video
    /// Alignment grid — the primary rigging aid. Lines land on exact pixel
    /// fractions so a mis-set keystone shows up as curvature immediately.
    case testGrid = 4
    /// Centre crosshair plus a one-pixel border, for edge and centre alignment.
    case testCrosshair = 5
    /// Colour bars, for projector colour and gamma matching.
    case testBars = 6

    public var isTestPattern: Bool { rawValue >= 4 }

    public var name: String {
        switch self {
        case .solid: return "Solid"
        case .gradient: return "Gradient"
        case .rings: return "Rings"
        case .video: return "Video"
        case .testGrid: return "Test Grid"
        case .testCrosshair: return "Crosshair"
        case .testBars: return "Colour Bars"
        }
    }
}

/// Per-layer state handed to the GPU. Must match `LayerUniform` in the shader.
public struct LayerUniform {
    public var tint: SIMD4<Float>
    public var offsetScale: SIMD4<Float>  // xy = offset, zw = scale
    public var opacity: Float
    public var blend: Int32
    public var kind: Int32                // 0 = solid, 1 = gradient, 2 = rings, 3 = video
    /// Index into the bound texture array, or -1 for a procedural layer.
    public var texSlot: Int32

    public init(tint: SIMD4<Float>, offsetScale: SIMD4<Float>,
                opacity: Float, blend: BlendMode, kind: Int32, texSlot: Int32 = -1) {
        self.tint = tint
        self.offsetScale = offsetScale
        self.opacity = opacity
        self.blend = blend.rawValue
        self.kind = kind
        self.texSlot = texSlot
    }
}

public final class Compositor: @unchecked Sendable {
    // No mutable state crosses threads here. Frame timing belongs to
    // `FrameMeter` — one owner, so a number can never be measured two ways and
    // disagree with itself.

    public static let maxLayers = 32

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var layerBuffer: MTLBuffer!

    /// Linear working target. Separate from the drawable so the composite
    /// happens in linear light and is encoded exactly once.
    private var workTarget: MTLTexture?
    private var encodePipeline: MTLRenderPipelineState!

    /// Where this compositor's own command buffers report their GPU time.
    /// Set by `PhotonEngine`; `nil` for a standalone compositor (the GPU
    /// verification harness), where there is nothing to report to.
    public var meter: FrameMeter?

    public init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = q
        guard build() else { return nil }
    }

    private func build() -> Bool {
        let src = Self.shaderSource
        do {
            let lib = try device.makeLibrary(source: src, options: nil)

            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "fullscreen_vertex")
            d.fragmentFunction = lib.makeFunction(name: "composite_fragment")
            d.colorAttachments[0].pixelFormat = .rgba16Float
            pipeline = try device.makeRenderPipelineState(descriptor: d)

            let e = MTLRenderPipelineDescriptor()
            e.vertexFunction = lib.makeFunction(name: "fullscreen_vertex")
            e.fragmentFunction = lib.makeFunction(name: "encode_fragment")
            e.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            encodePipeline = try device.makeRenderPipelineState(descriptor: e)

            layerBuffer = device.makeBuffer(
                length: MemoryLayout<LayerUniform>.stride * Self.maxLayers,
                options: .storageModeShared)
            return layerBuffer != nil
        } catch {
            print("[Compositor] shader build failed: \(error)")
            return false
        }
    }

    private func ensureTarget(width: Int, height: Int) -> MTLTexture? {
        if let t = workTarget, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: max(width, 1), height: max(height, 1),
            mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        workTarget = device.makeTexture(descriptor: d)
        return workTarget
    }

    /// Maximum simultaneous video textures. Matches the shader's array size.
    public static let maxTextures = 8

    /// Composites the stack into the linear working target and returns it.
    ///
    /// Separated from presentation so the output stage can warp it into one or
    /// more projector slices. The composite happens **once** no matter how many
    /// slices consume it.
    @discardableResult
    public func composite(into cb: MTLCommandBuffer,
                          layers: [LayerUniform], time: Float,
                          width: Int, height: Int,
                          textures: [MTLTexture?] = []) -> MTLTexture? {
        let n = min(layers.count, Self.maxLayers)
        guard n > 0, let work = ensureTarget(width: width, height: height) else { return nil }

        memcpy(layerBuffer.contents(), layers, MemoryLayout<LayerUniform>.stride * n)
        var resolution = SIMD2<Float>(Float(width), Float(height))

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = work
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        enc.label = "composite"
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBuffer(layerBuffer, offset: 0, index: 0)
        var count = Int32(n)
        var t = time
        enc.setFragmentBytes(&count, length: 4, index: 1)
        enc.setFragmentBytes(&t, length: 4, index: 2)
        enc.setFragmentBytes(&resolution, length: MemoryLayout<SIMD2<Float>>.size, index: 3)
        for i in 0..<Self.maxTextures {
            enc.setFragmentTexture(i < textures.count ? textures[i] : nil, index: i)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        return work
    }

    /// Creates a command buffer for callers that drive compositing themselves.
    public func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }

    /// Renders the stack straight to `drawable`, unwarped.
    public func render(layers: [LayerUniform], time: Float,
                       drawable: MTLDrawable, output: MTLTexture,
                       textures: [MTLTexture?] = []) {
        let n = min(layers.count, Self.maxLayers)
        guard n > 0, let work = ensureTarget(width: output.width, height: output.height),
              let cb = queue.makeCommandBuffer() else { return }

        memcpy(layerBuffer.contents(), layers, MemoryLayout<LayerUniform>.stride * n)
        var resolution = SIMD2<Float>(Float(output.width), Float(output.height))

        // Pass 1 — fold the whole stack in linear light.
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = work
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
            enc.label = "composite"
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBuffer(layerBuffer, offset: 0, index: 0)
            var count = Int32(n)
            var t = time
            enc.setFragmentBytes(&count, length: 4, index: 1)
            enc.setFragmentBytes(&t, length: 4, index: 2)
            enc.setFragmentBytes(&resolution, length: MemoryLayout<SIMD2<Float>>.size, index: 3)
            // Every slot must be bound or the shader reads an unset binding.
            for i in 0..<Self.maxTextures {
                enc.setFragmentTexture(i < textures.count ? textures[i] : nil, index: i)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // Pass 2 — encode linear -> display, exactly once.
        let rp2 = MTLRenderPassDescriptor()
        rp2.colorAttachments[0].texture = output
        rp2.colorAttachments[0].loadAction = .dontCare
        rp2.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: rp2) {
            enc.label = "encode"
            enc.setRenderPipelineState(encodePipeline)
            enc.setFragmentTexture(work, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        meter?.observe(cb)
        cb.present(drawable)
        cb.commit()
    }

    // MARK: - MSL

    /// `blend_rgb` is spliced in from ``BlendMSL`` rather than written here, so
    /// the compositor and the effect chain share one definition of what each
    /// mode means. Two copies is how the Swift enum drifted from the Rust one.
    static var shaderSource: String { shaderHead + BlendMSL.source + shaderTail }

    private static let shaderHead = """
    #include <metal_stdlib>
    using namespace metal;

    struct LayerUniform {
        float4 tint;
        float4 offsetScale;
        float  opacity;
        int    blend;
        int    kind;
        int    texSlot;
    };

    vertex float4 fullscreen_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    // Procedural stand-ins for media. Real sources replace these with sampled
    // BC textures; the fold logic around them is unchanged.
    static float4 sample_layer(constant LayerUniform &L, float2 uv, float t) {
        float2 p = (uv - 0.5) / max(L.offsetScale.zw, float2(0.001)) + 0.5 - L.offsetScale.xy;
        float a = 1.0;
        float3 c = L.tint.rgb;
        if (L.kind == 1) {
            c *= mix(0.15, 1.0, saturate(p.x));
            a = (p.x > -0.2 && p.x < 1.2 && p.y > -0.2 && p.y < 1.2) ? 1.0 : 0.0;
        } else if (L.kind == 2) {
            float d = length(p - 0.5);
            float rings = 0.5 + 0.5 * sin(d * 40.0 - t * 2.0);
            c *= rings;
            a = smoothstep(0.52, 0.48, d);
        } else if (L.kind == 4) {
            // Alignment grid. Lines sit on exact 1/16 fractions, so a wrong
            // keystone shows as curvature rather than as a plausible image.
            float2 g = fract(p * 16.0);
            float2 gw = fwidth(p) * 16.0 * 1.5;
            float line = (min(g.x, 1.0 - g.x) < gw.x || min(g.y, 1.0 - g.y) < gw.y) ? 1.0 : 0.0;
            // Heavier lines on thirds to judge centring at a distance.
            float2 t = fract(p * 3.0);
            float2 tw = fwidth(p) * 3.0 * 2.5;
            float third = (min(t.x, 1.0 - t.x) < tw.x || min(t.y, 1.0 - t.y) < tw.y) ? 1.0 : 0.0;
            c = float3(max(line * 0.55, third));
            a = (p.x > 0.0 && p.x < 1.0 && p.y > 0.0 && p.y < 1.0) ? 1.0 : 0.0;
        } else if (L.kind == 5) {
            // Line widths come from screen-space derivatives so a line is ~1px
            // at ANY output resolution. A fixed fraction would be sub-pixel on
            // a small preview and fat on a 4K canvas — and an alignment aid
            // that changes thickness with resolution is worse than useless.
            float2 w = fwidth(p) * 1.5;
            float2 d = abs(p - 0.5);
            float cross = (d.x < w.x || d.y < w.y) ? 1.0 : 0.0;
            // A border exactly at the edge: if any of it is missing, the slice
            // is overscanning and content is being cropped off the surface.
            float2 b = fwidth(p) * 2.0;
            float border = (p.x < b.x || p.x > 1.0 - b.x ||
                            p.y < b.y || p.y > 1.0 - b.y) ? 1.0 : 0.0;
            float circle = (abs(length(d) - 0.25) < max(w.x, w.y)) ? 1.0 : 0.0;
            c = float3(max(max(cross, border), circle));
            a = (p.x > 0.0 && p.x < 1.0 && p.y > 0.0 && p.y < 1.0) ? 1.0 : 0.0;
        } else if (L.kind == 6) {
            // Colour bars, then a greyscale ramp strip for gamma matching.
            float3 bars[7] = { float3(1,1,1), float3(1,1,0), float3(0,1,1), float3(0,1,0),
                               float3(1,0,1), float3(1,0,0), float3(0,0,1) };
            int idx = clamp(int(p.x * 7.0), 0, 6);
            c = (p.y > 0.75) ? float3(saturate(p.x)) : bars[idx];
            a = (p.x > 0.0 && p.x < 1.0 && p.y > 0.0 && p.y < 1.0) ? 1.0 : 0.0;
        } else {
            a = (p.x > 0.0 && p.x < 1.0 && p.y > 0.0 && p.y < 1.0) ? 1.0 : 0.0;
        }
        return float4(c, a * L.opacity);
    }

    """

    private static let shaderTail = """

    fragment float4 composite_fragment(float4 pos [[position]],
                                       constant LayerUniform *layers [[buffer(0)]],
                                       constant int &count [[buffer(1)]],
                                       constant float &t [[buffer(2)]],
                                       constant float2 &resolution [[buffer(3)]],
                                       array<texture2d<float>, 8> texs [[texture(0)]])
    {
        // Fold the whole stack in registers, bottom to top. No intermediates,
        // no ping-pong, no per-layer render target.
        float2 uv = pos.xy / resolution;
        float3 acc = float3(0.0);

        for (int i = 0; i < count; ++i) {
            constant LayerUniform &L = layers[i];
            float4 s;
            if (L.kind == 3 && L.texSlot >= 0) {
                // Real media. Transform matches the procedural path so a video
                // layer animates identically to a generated one.
                constexpr sampler vs(filter::linear, address::clamp_to_edge);
                float2 p = (uv - 0.5) / max(L.offsetScale.zw, float2(0.001))
                           + 0.5 - L.offsetScale.xy;
                float4 c = texs[L.texSlot].sample(vs, float2(p.x, 1.0 - p.y));
                float inside = (p.x > 0.0 && p.x < 1.0 && p.y > 0.0 && p.y < 1.0) ? 1.0 : 0.0;
                s = float4(c.rgb, c.a * L.opacity * inside);
            } else {
                s = sample_layer(L, uv, t);
            }
            if (s.a <= 0.0) continue;

            // Mask used to be special-cased here because `blend_rgb` had it
            // wrong. It is correct in `BlendMSL` now, so there is one
            // definition and the mode cannot mean two things.
            float3 blended = blend_rgb(L.blend, acc, s.rgb);
            acc = mix(acc, blended, s.a);
        }
        return float4(acc, 1.0);
    }

    fragment float4 encode_fragment(float4 pos [[position]],
                                    texture2d<float> src [[texture(0)]]) {
        constexpr sampler s(filter::linear);
        float2 uv = float2(pos.x / src.get_width(), pos.y / src.get_height());
        // Emit LINEAR. The attachment is an _srgb format, so the hardware
        // performs the encode on write — and, importantly, any blending into
        // that attachment happens in linear space. Encoding by hand here and
        // writing to an _srgb target would apply the curve twice.
        return float4(src.sample(s, uv).rgb, 1.0);
    }
    """
}
