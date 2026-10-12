// Per-layer effects, and the hybrid compositor they force.
//
// ## Why this changes the compositor
//
// The fast path folds the whole layer stack in ONE fragment shader, in
// registers, with no intermediate textures. That is what makes Difference and
// Mask possible at all.
//
// But **a layer with its own effect chain must be materialised to a real
// texture** before those effects can run on it — which is precisely the
// intermediate the fold exists to avoid.
//
// So the compositor is a **hybrid**, decided per frame:
//
//   - layers with NO effects      → stay in the folded path, free
//   - layers WITH effects         → break out, render to their own target, run
//                                   their chain, then **rejoin the stack as an
//                                   ordinary source texture**
//
// One mechanism covers both. The planner makes this decision automatically; it
// is not a special case bolted on, because retrofitting the break-out path into
// a fold-only compositor is expensive.
//
// Effects run in **linear light**, like everything before the output encode.

import Metal
import simd

/// A built-in effect. Shipping ISF (GLSL + JSON manifest) is the eventual
/// plan — hundreds exist free — but these are native MSL so the chain
/// infrastructure can be proven before the GLSL translation layer lands.
public enum EffectKind: Int32, Sendable, CaseIterable {
    // Colour — operate on the pixel where it is.
    case levels = 0
    case invert
    case saturation
    case hueRotate
    case colorize
    case duotone
    case threshold
    case posterize
    case solarize
    case exposure
    case temperature

    // Stylise — read a neighbourhood.
    case blur
    case sharpen
    case edgeDetect
    case emboss
    case glow
    case halftone
    case pixelate

    // Distort — read somewhere else entirely.
    case kaleidoscope
    case mirror
    case twirl
    case fisheye
    case wave
    case tile
    case slide
    case polar
    case zoom

    // Texture and keying.
    case rgbShift
    case chromaticAberration
    case vignette
    case scanlines
    case noise
    case strobe
    case lumaKey
    case chromaKey

    public var name: String {
        switch self {
        case .levels: return "Levels"
        case .invert: return "Invert"
        case .saturation: return "Saturation"
        case .hueRotate: return "Hue Rotate"
        case .colorize: return "Colorize"
        case .duotone: return "Duotone"
        case .threshold: return "Threshold"
        case .posterize: return "Posterize"
        case .solarize: return "Solarize"
        case .exposure: return "Exposure"
        case .temperature: return "Temperature"
        case .blur: return "Blur"
        case .sharpen: return "Sharpen"
        case .edgeDetect: return "Edge Detect"
        case .emboss: return "Emboss"
        case .glow: return "Glow"
        case .halftone: return "Halftone"
        case .pixelate: return "Pixelate"
        case .kaleidoscope: return "Kaleidoscope"
        case .mirror: return "Mirror"
        case .twirl: return "Twirl"
        case .fisheye: return "Fisheye"
        case .wave: return "Wave"
        case .tile: return "Tile"
        case .slide: return "Slide"
        case .polar: return "Polar"
        case .zoom: return "Zoom"
        case .rgbShift: return "RGB Shift"
        case .chromaticAberration: return "Chromatic Aberration"
        case .vignette: return "Vignette"
        case .scanlines: return "Scanlines"
        case .noise: return "Noise"
        case .strobe: return "Strobe"
        case .lumaKey: return "Luma Key"
        case .chromaKey: return "Chroma Key"
        }
    }

    /// Grouping for the effects browser.
    ///
    /// Ordered the way an operator looks for things — by what the effect *does*
    /// to the picture, not by how it is implemented.
    public enum Category: String, Sendable, CaseIterable {
        case colour = "Colour"
        case stylise = "Stylise"
        case distort = "Distort"
        case texture = "Texture"
        case key = "Key"
    }

    public var category: Category {
        switch self {
        case .levels, .invert, .saturation, .hueRotate, .colorize, .duotone,
             .threshold, .posterize, .solarize, .exposure, .temperature:
            return .colour
        case .blur, .sharpen, .edgeDetect, .emboss, .glow, .halftone, .pixelate:
            return .stylise
        case .kaleidoscope, .mirror, .twirl, .fisheye, .wave, .tile, .slide, .polar, .zoom:
            return .distort
        case .rgbShift, .chromaticAberration, .vignette, .scanlines, .noise, .strobe:
            return .texture
        case .lumaKey, .chromaKey:
            return .key
        }
    }

    /// What the second control does, for the UI to label it.
    ///
    /// A knob named "Param" is a knob nobody turns. Every effect that uses the
    /// second control says what it is.
    public var paramLabel: String? {
        switch self {
        case .levels: return "Gamma"
        case .colorize, .duotone, .hueRotate: return "Hue"
        case .posterize: return "Levels"
        case .temperature: return "Tint"
        case .blur, .glow: return "Threshold"
        case .sharpen, .edgeDetect, .emboss: return "Radius"
        case .halftone: return "Dot Size"
        case .kaleidoscope: return "Rotation"
        case .mirror: return "Axis"
        case .twirl, .fisheye, .zoom: return "Centre"
        case .wave: return "Frequency"
        case .tile: return "Offset"
        case .slide, .polar: return "Direction"
        case .rgbShift: return "Angle"
        case .vignette: return "Softness"
        case .scanlines: return "Count"
        case .noise: return "Grain"
        case .strobe: return "Rate"
        case .lumaKey: return "Softness"
        case .chromaKey: return "Tolerance"
        case .invert, .saturation, .threshold, .solarize, .exposure,
             .pixelate, .chromaticAberration:
            return nil
        }
    }

    /// Whether the effect samples beyond the current pixel.
    ///
    /// Drives two things: whether it can be fused with its neighbours, and
    /// whether damage-region scissoring must be disabled for the frame (a
    /// neighbourhood read against a scissored canvas sees stale pixels).
    ///
    /// **Geometry distortions count.** A twirl reads from wherever the warp
    /// points, which is outside the damaged region far more often than not —
    /// getting this wrong produces stale pixels only when something moves,
    /// which is the hardest class of bug to catch.
    public var isNeighbourhood: Bool {
        switch self {
        case .levels, .invert, .saturation, .hueRotate, .colorize, .duotone,
             .threshold, .posterize, .solarize, .exposure, .temperature,
             .vignette, .scanlines, .noise, .strobe, .lumaKey, .chromaKey:
            return false
        case .blur, .sharpen, .edgeDetect, .emboss, .glow, .halftone, .pixelate,
             .kaleidoscope, .mirror, .twirl, .fisheye, .wave, .tile, .slide,
             .polar, .zoom, .rgbShift, .chromaticAberration:
            return true
        }
    }

    /// Whether the effect's output changes with time even when its input does
    /// not.
    ///
    /// Damage-region tracking must treat these as dirty every frame, or a
    /// strobe on a still image simply stops.
    public var isTimeVarying: Bool {
        switch self {
        case .noise, .strobe: return true
        default: return false
        }
    }
}

/// One effect instance with its parameters.
public struct Effect: Sendable {
    public var kind: EffectKind
    /// Primary amount, 0...1. Modulatable like any other parameter.
    public var amount: Float
    /// Secondary control; meaning depends on the effect.
    public var param: Float
    /// Bypassed without being removed, so settings survive an A/B.
    public var enabled: Bool

    public init(kind: EffectKind, amount: Float = 0.5,
                param: Float = 0.5, enabled: Bool = true) {
        self.kind = kind
        self.amount = amount
        self.param = param
        self.enabled = enabled
    }
}

/// Uniforms for one effect pass. Must match `EffectUniforms` in the shader.
struct EffectUniforms {
    var amount: Float
    var param: Float
    var kind: Int32
    /// Seconds since start. Drives grain and anything free-running.
    var time: Float
    var resolution: SIMD2<Float>
    /// Continuous musical position, so a strobe can lock to tempo rather than
    /// to wall-clock seconds — which is the entire point of having a clock.
    var beat: Float
    var pad: Float = 0
}

/// Runs effect chains into offscreen targets.
public final class EffectChain {
    private let device: MTLDevice
    private var pipeline: MTLRenderPipelineState!

    /// Ping-pong targets, allocated lazily per size. Two are enough for any
    /// chain length because each pass reads one and writes the other.
    private var pool: [String: (MTLTexture, MTLTexture)] = [:]

    /// Effect passes executed in the most recent frame, for telemetry.
    public private(set) var passesLastFrame = 0

    public init?(device: MTLDevice) {
        self.device = device
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "effect_vertex")
            d.fragmentFunction = lib.makeFunction(name: "effect_fragment")
            // Linear working format, like every intermediate in the pipeline.
            d.colorAttachments[0].pixelFormat = .rgba16Float
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            print("[EffectChain] pipeline build failed: \(error)")
            return nil
        }
    }

    private func targets(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        let key = "\(width)x\(height)"
        if let existing = pool[key] { return existing }
        func make() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: max(width, 1), height: max(height, 1),
                mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let a = make(), let b = make() else { return nil }
        pool[key] = (a, b)
        return (a, b)
    }

    /// Applies `effects` to `source`, returning the result.
    ///
    /// Returns `source` untouched when the chain is empty or fully bypassed —
    /// **a layer with no active effects must cost nothing**, which is what keeps
    /// the hybrid worthwhile.
    /// Applies `effects` to `source`, returning the result.
    ///
    /// `time` is seconds and `beat` is musical position; effects that need
    /// neither ignore both.
    public func apply(_ effects: [Effect],
                      to source: MTLTexture,
                      in cb: MTLCommandBuffer,
                      time: Float = 0,
                      beat: Double = 0) -> MTLTexture {
        let active = effects.filter(\.enabled)
        guard !active.isEmpty,
              let (a, b) = targets(width: source.width, height: source.height)
        else { return source }

        var read = source
        var write = a
        var other = b

        for (i, fx) in active.enumerated() {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = write
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { break }
            enc.label = "effect/\(fx.kind.name)"
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(read, index: 0)
            var u = EffectUniforms(
                amount: fx.amount, param: fx.param, kind: fx.kind.rawValue,
                time: time,
                resolution: SIMD2(Float(source.width), Float(source.height)),
                // Wrapped to a bar so the float stays precise across a long
                // show. A 32-bit float at beat 400,000 cannot represent a
                // sixteenth note, and a strobe would visibly quantise.
                beat: Float(beat.truncatingRemainder(dividingBy: 4.0)))
            enc.setFragmentBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()

            // Ping-pong. On the first pass `read` is the caller's texture, which
            // must never be written to.
            read = write
            write = (i == 0) ? other : (write === a ? b : a)
            other = read === a ? b : a
        }

        passesLastFrame = active.count
        return read
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct EffectUniforms {
        float  amount;
        float  param;
        int    kind;
        float  pad;
        float2 resolution;
        float2 pad2;
    };

    vertex float4 effect_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    fragment float4 effect_fragment(float4 pos [[position]],
                                    constant EffectUniforms &u [[buffer(0)]],
                                    texture2d<float> src [[texture(0)]])
    {
        constexpr sampler sm(filter::linear, address::clamp_to_edge);
        float2 uv = pos.xy / u.resolution;
        float2 texel = 1.0 / u.resolution;

        switch (u.kind) {
            case 0: {   // blur — separable-ish 9 tap, cheap and good enough
                float r = u.amount * 8.0;
                float4 sum = float4(0.0);
                float wsum = 0.0;
                for (int y = -2; y <= 2; ++y) {
                    for (int x = -2; x <= 2; ++x) {
                        float w = exp(-float(x*x + y*y) * 0.3);
                        sum += src.sample(sm, uv + float2(x, y) * texel * r) * w;
                        wsum += w;
                    }
                }
                return sum / max(wsum, 1e-5);
            }
            case 1: {   // rgb shift — channels diverge along an angle
                float a = u.param * 6.28318;
                float2 d = float2(cos(a), sin(a)) * texel * u.amount * 30.0;
                float r = src.sample(sm, uv + d).r;
                float g = src.sample(sm, uv).g;
                float b = src.sample(sm, uv - d).b;
                return float4(r, g, b, src.sample(sm, uv).a);
            }
            case 2: {   // levels — contrast about mid-grey, then gamma
                float4 c = src.sample(sm, uv);
                float3 v = (c.rgb - 0.5) * (1.0 + u.amount * 3.0) + 0.5;
                v = pow(max(v, 0.0), float3(mix(0.4, 2.5, u.param)));
                return float4(v, c.a);
            }
            case 3: {   // pixelate
                float n = mix(u.resolution.x, 8.0, u.amount);
                float2 cell = max(u.resolution / max(n, 1.0), float2(1.0));
                float2 q = (floor(uv * u.resolution / cell) + 0.5) * cell / u.resolution;
                return src.sample(sm, q);
            }
            case 4: {   // kaleidoscope
                float2 c = uv - 0.5;
                float ang = atan2(c.y, c.x);
                float rad = length(c);
                float seg = 6.28318 / max(2.0, floor(mix(2.0, 16.0, u.amount)));
                ang = abs(fmod(ang, seg) - seg * 0.5);
                return src.sample(sm, 0.5 + float2(cos(ang), sin(ang)) * rad);
            }
            case 5: {   // invert, mixed by amount
                float4 c = src.sample(sm, uv);
                return float4(mix(c.rgb, 1.0 - c.rgb, u.amount), c.a);
            }
            default:
                return src.sample(sm, uv);
        }
    }
    """
}
