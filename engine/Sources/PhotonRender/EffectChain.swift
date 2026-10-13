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

    // Field order and offsets must match the Swift `EffectUniforms` exactly.
    // `time` and `beat` were previously named `pad`/`pad2` here, so every
    // free-running or tempo-locked effect silently read nothing.
    struct EffectUniforms {
        float  amount;      // 0
        float  param;       // 4
        int    kind;        // 8
        float  time;        // 12
        float2 resolution;  // 16
        float  beat;        // 24
        float  pad;         // 28
    };

    vertex float4 effect_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    constant float TAU = 6.283185307;

    static inline float luma709(float3 c) {
        return dot(c, float3(0.2126, 0.7152, 0.0722));
    }

    // Rodrigues rotation about the grey axis — hue without a full HSV round trip.
    static inline float3 hueShift(float3 c, float h) {
        const float3 k = float3(0.57735027);
        float ca = cos(h), sa = sin(h);
        return c * ca + cross(k, c) * sa + k * dot(k, c) * (1.0 - ca);
    }

    static inline float3 hsv2rgb(float3 c) {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }

    static inline float hash21(float2 p) {
        p = fract(p * float2(443.897, 441.423));
        p += dot(p, p + 19.19);
        return fract((p.x + p.y) * p.x);
    }

    // A 5x5 gaussian used by blur, glow and sharpen. Radius in texels.
    static inline float4 gauss25(texture2d<float> src, sampler sm,
                                 float2 uv, float2 texel, float r) {
        float4 sum = float4(0.0);
        float wsum = 0.0;
        for (int y = -2; y <= 2; ++y) {
            for (int x = -2; x <= 2; ++x) {
                float w = exp(-float(x * x + y * y) * 0.3);
                sum += src.sample(sm, uv + float2(x, y) * texel * r) * w;
                wsum += w;
            }
        }
        return sum / max(wsum, 1e-5);
    }

    // The `case` numbers below are `EffectKind.rawValue` and nothing else.
    // They are asserted against Swift by `every effect kind is implemented` in
    // PhotonVerify — a kind that falls through to `default` is a bug, not a
    // placeholder, because the browser offers it to the operator regardless.
    fragment float4 effect_fragment(float4 pos [[position]],
                                    constant EffectUniforms &u [[buffer(0)]],
                                    texture2d<float> src [[texture(0)]])
    {
        constexpr sampler sm(filter::linear, address::clamp_to_edge);
        float2 uv = pos.xy / u.resolution;
        float2 texel = 1.0 / u.resolution;
        float  a = u.amount;
        float  p = u.param;

        switch (u.kind) {

        // ---- Colour: operate on the pixel where it is ----
        case 0: {   // levels — contrast about mid-grey, then gamma
            float4 c = src.sample(sm, uv);
            float3 v = (c.rgb - 0.5) * (1.0 + a * 3.0) + 0.5;
            v = pow(max(v, 0.0), float3(mix(0.4, 2.5, p)));
            return float4(v, c.a);
        }
        case 1: {   // invert
            float4 c = src.sample(sm, uv);
            return float4(mix(c.rgb, 1.0 - c.rgb, a), c.a);
        }
        case 2: {   // saturation — 0.5 is identity, 0 greyscale, 1 double
            float4 c = src.sample(sm, uv);
            return float4(mix(float3(luma709(c.rgb)), c.rgb, a * 2.0), c.a);
        }
        case 3: {   // hue rotate — param picks the angle, amount mixes
            float4 c = src.sample(sm, uv);
            return float4(mix(c.rgb, saturate(hueShift(c.rgb, p * TAU)), a), c.a);
        }
        case 4: {   // colorize — luma tinted by a hue
            float4 c = src.sample(sm, uv);
            float3 t = hsv2rgb(float3(p, 1.0, 1.0)) * luma709(c.rgb);
            return float4(mix(c.rgb, t, a), c.a);
        }
        case 5: {   // duotone — luma ramped between complementary hues
            float4 c = src.sample(sm, uv);
            float3 lo = hsv2rgb(float3(p, 0.9, 0.25));
            float3 hi = hsv2rgb(float3(fract(p + 0.5), 0.7, 1.0));
            return float4(mix(c.rgb, mix(lo, hi, luma709(c.rgb)), a), c.a);
        }
        case 6: {   // threshold — amount IS the cut point
            float4 c = src.sample(sm, uv);
            return float4(float3(step(a, luma709(c.rgb))), c.a);
        }
        case 7: {   // posterize — param sets the step count
            float4 c = src.sample(sm, uv);
            float n = max(2.0, floor(mix(2.0, 16.0, 1.0 - p)));
            return float4(mix(c.rgb, floor(c.rgb * n) / n, a), c.a);
        }
        case 8: {   // solarize — invert only above mid
            float4 c = src.sample(sm, uv);
            float3 s = select(c.rgb, 1.0 - c.rgb, c.rgb > 0.5);
            return float4(mix(c.rgb, s, a), c.a);
        }
        case 9: {   // exposure — 0.5 is identity, +/- 3 stops
            float4 c = src.sample(sm, uv);
            return float4(c.rgb * exp2(mix(-3.0, 3.0, a)), c.a);
        }
        case 10: {  // temperature — amount warms/cools, param tints green/magenta
            float4 c = src.sample(sm, uv);
            float t = (a - 0.5) * 2.0;
            float g = (p - 0.5) * 2.0;
            float3 v = c.rgb * float3(1.0 + t * 0.4, 1.0 + g * 0.2, 1.0 - t * 0.4);
            return float4(max(v, 0.0), c.a);
        }

        // ---- Stylise: read a neighbourhood ----
        case 11: {  // blur
            return gauss25(src, sm, uv, texel, a * 8.0);
        }
        case 12: {  // sharpen — unsharp mask
            float4 c = src.sample(sm, uv);
            float4 b = gauss25(src, sm, uv, texel, mix(1.0, 4.0, p));
            return float4(c.rgb + (c.rgb - b.rgb) * a * 3.0, c.a);
        }
        case 13: {  // edge detect — sobel magnitude
            float r = mix(1.0, 4.0, p);
            float gx = 0.0, gy = 0.0;
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    float l = luma709(src.sample(sm, uv + float2(x, y) * texel * r).rgb);
                    float sx = float(x) * ((y == 0) ? 2.0 : 1.0);
                    float sy = float(y) * ((x == 0) ? 2.0 : 1.0);
                    gx += l * sx; gy += l * sy;
                }
            }
            float e = sqrt(gx * gx + gy * gy);
            float4 c = src.sample(sm, uv);
            return float4(mix(c.rgb, float3(e), a), c.a);
        }
        case 14: {  // emboss — directional difference plus mid-grey
            float r = mix(1.0, 4.0, p);
            float3 d = src.sample(sm, uv - texel * r).rgb
                     - src.sample(sm, uv + texel * r).rgb;
            float e = luma709(d) + 0.5;
            float4 c = src.sample(sm, uv);
            return float4(mix(c.rgb, float3(e), a), c.a);
        }
        case 15: {  // glow — bright pass, blurred, added back
            float4 c = src.sample(sm, uv);
            float4 b = gauss25(src, sm, uv, texel, 6.0);
            float3 bright = max(b.rgb - p, 0.0);
            return float4(c.rgb + bright * a * 2.0, c.a);
        }
        case 16: {  // halftone — luma into dots on a rotated grid
            float cell = mix(4.0, 40.0, p);
            float2 g = uv * u.resolution / cell;
            float ang = 0.4;
            float2 rg = float2(g.x * cos(ang) - g.y * sin(ang),
                               g.x * sin(ang) + g.y * cos(ang));
            float2 f = fract(rg) - 0.5;
            float l = luma709(src.sample(sm, (floor(rg) + 0.5) * cell / u.resolution).rgb);
            float dot_ = step(length(f), sqrt(l) * 0.7);
            float4 c = src.sample(sm, uv);
            return float4(mix(c.rgb, float3(dot_), a), c.a);
        }
        case 17: {  // pixelate
            float n = mix(u.resolution.x, 8.0, a);
            float2 cell = max(u.resolution / max(n, 1.0), float2(1.0));
            float2 q = (floor(uv * u.resolution / cell) + 0.5) * cell / u.resolution;
            return src.sample(sm, q);
        }

        // ---- Distort: read somewhere else entirely ----
        case 18: {  // kaleidoscope
            float2 c = uv - 0.5;
            float ang = atan2(c.y, c.x) + p * TAU;
            float rad = length(c);
            float seg = TAU / max(2.0, floor(mix(2.0, 16.0, a)));
            ang = abs(fmod(ang, seg) - seg * 0.5);
            return src.sample(sm, 0.5 + float2(cos(ang), sin(ang)) * rad);
        }
        case 19: {  // mirror — param picks the axis
            float2 q = uv;
            if (p < 0.33)      { q.x = 0.5 - abs(q.x - 0.5); }
            else if (p < 0.66) { q.y = 0.5 - abs(q.y - 0.5); }
            else               { q = 0.5 - abs(q - 0.5); }
            return src.sample(sm, mix(uv, q, step(0.001, a)));
        }
        case 20: {  // twirl
            float2 ctr = float2(p, 0.5);
            float2 d = uv - ctr;
            float r = length(d);
            float ang = atan2(d.y, d.x) + (1.0 - saturate(r * 2.0)) * a * TAU;
            return src.sample(sm, ctr + float2(cos(ang), sin(ang)) * r);
        }
        case 21: {  // fisheye
            float2 ctr = float2(p, 0.5);
            float2 d = uv - ctr;
            float r = length(d);
            float k = 1.0 + (a - 0.5) * 2.0;
            return src.sample(sm, ctr + d * pow(max(r, 1e-5), k - 1.0));
        }
        case 22: {  // wave
            float f = mix(2.0, 40.0, p);
            float2 q = uv + float2(sin(uv.y * f + u.time) , cos(uv.x * f + u.time))
                            * a * 0.05;
            return src.sample(sm, q);
        }
        case 23: {  // tile
            float n = max(1.0, floor(mix(1.0, 8.0, a)));
            return src.sample(sm, fract(uv * n));
        }
        case 24: {  // slide
            float ang = p * TAU;
            return src.sample(sm, fract(uv + float2(cos(ang), sin(ang)) * a));
        }
        case 25: {  // polar
            float2 c = uv - 0.5;
            float2 q = float2(atan2(c.y, c.x) / TAU + 0.5, length(c) * 2.0);
            return src.sample(sm, mix(uv, q, a));
        }
        case 26: {  // zoom
            float2 ctr = float2(p, 0.5);
            float s = mix(1.0, 0.2, a);
            return src.sample(sm, ctr + (uv - ctr) * s);
        }

        // ---- Texture ----
        case 27: {  // rgb shift — channels diverge along an angle
            float ang = p * TAU;
            float2 d = float2(cos(ang), sin(ang)) * texel * a * 30.0;
            float4 c = src.sample(sm, uv);
            return float4(src.sample(sm, uv + d).r, c.g, src.sample(sm, uv - d).b, c.a);
        }
        case 28: {  // chromatic aberration — radial, strongest at the edges
            float2 d = (uv - 0.5) * a * 0.05;
            float4 c = src.sample(sm, uv);
            return float4(src.sample(sm, uv + d).r, c.g, src.sample(sm, uv - d).b, c.a);
        }
        case 29: {  // vignette
            float r = length((uv - 0.5) * float2(1.0, u.resolution.y / u.resolution.x));
            float v = smoothstep(0.75, mix(0.75, 0.1, a), r);
            float4 c = src.sample(sm, uv);
            return float4(c.rgb * v, c.a);
        }
        case 30: {  // scanlines
            float n = mix(80.0, 900.0, p);
            float s = 0.5 + 0.5 * sin(uv.y * n * TAU);
            float4 c = src.sample(sm, uv);
            return float4(c.rgb * mix(1.0, s, a), c.a);
        }
        case 31: {  // noise — free-running, so it needs `time`
            float n = hash21(uv * u.resolution + u.time * 60.0);
            float4 c = src.sample(sm, uv);
            return float4(mix(c.rgb, c.rgb * (0.5 + n), a), c.a);
        }
        case 32: {  // strobe — gated on musical phase, not wall-clock
            float phase = fract(u.beat / max(mix(4.0, 0.25, p), 0.01));
            float g = step(phase, 0.5);
            float4 c = src.sample(sm, uv);
            return float4(mix(c.rgb, c.rgb * g, a), c.a);
        }

        // ---- Keying ----
        case 33: {  // luma key — amount is the cut, param the softness
            float4 c = src.sample(sm, uv);
            float k = smoothstep(a, a + mix(0.001, 0.4, p), luma709(c.rgb));
            return float4(c.rgb, c.a * k);
        }
        case 34: {  // chroma key — distance from a hue, param the tolerance
            float4 c = src.sample(sm, uv);
            float3 key = hsv2rgb(float3(a, 1.0, 1.0));
            float d = distance(normalize(max(c.rgb, 1e-5)), normalize(key));
            float k = smoothstep(0.0, mix(0.05, 0.9, p), d);
            return float4(c.rgb, c.a * k);
        }

        default:
            return src.sample(sm, uv);
        }
    }
    """
}
