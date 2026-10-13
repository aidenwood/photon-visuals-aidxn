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
    /// second control says what it is — and **every effect whose label is `nil`
    /// ignores `param` entirely in the shader**. The two are checked against each
    /// other by eye on every change to the switch below; a label that lies is
    /// worse than no label, because the operator trusts it mid-show.
    ///
    /// Three labels changed on the 2026-10-13 quality pass:
    ///   - `blur` was "Threshold", which a blur does not have. It is "Direction"
    ///     now and drives a real anisotropic (horizontal↔vertical) blur.
    ///   - `threshold` was `nil` with `amount` as the cut. The cut moved to
    ///     `param` so `amount` can be a mix and start from a true identity.
    ///   - `chromaKey` was "Tolerance" with `amount` as the key hue. Swapped, for
    ///     the same reason: tolerance at zero keys nothing, which is identity.
    public var paramLabel: String? {
        switch self {
        case .levels: return "Gamma"
        // `colorize` and `duotone` take an absolute hue to paint with.
        // `hueRotate` takes an angle to turn the existing hues BY — same word,
        // two different meanings, which is why it is not called "Hue".
        case .colorize, .duotone: return "Hue"
        case .hueRotate: return "Rotation"
        case .posterize: return "Levels"
        case .temperature: return "Tint"
        case .threshold: return "Cut"
        case .blur: return "Direction"
        case .glow: return "Threshold"
        case .sharpen, .edgeDetect, .emboss: return "Radius"
        case .halftone: return "Dot Size"
        case .kaleidoscope: return "Rotation"
        case .mirror: return "Axis"
        // One knob, one axis. Calling it "Centre" implied a 2D control that does
        // not exist — Y is pinned to the middle of the frame. A second axis
        // needs a third parameter, which is a separate piece of work.
        case .twirl, .fisheye, .zoom: return "Centre X"
        case .wave: return "Frequency"
        case .tile: return "Offset"
        case .slide, .polar: return "Direction"
        case .rgbShift: return "Angle"
        case .vignette: return "Softness"
        case .scanlines: return "Count"
        case .noise: return "Grain"
        case .strobe: return "Rate"
        case .lumaKey: return "Softness"
        case .chromaKey: return "Key Hue"
        case .invert, .saturation, .solarize, .exposure,
             .pixelate, .chromaticAberration:
            return nil
        }
    }

    /// What `amount` means, and therefore where its neutral point sits.
    ///
    /// An operator automates `amount` from a fader, an LFO or an envelope. If
    /// the neutral point is not predictable the effect jumps the moment the
    /// modulation source touches its rest position, which on a 10-metre wall is
    /// not a subtlety. So every effect declares which of three shapes it is, and
    /// the shader is written to honour it exactly — `PhotonVerify` asserts it.
    public enum AmountMode: String, Sendable {
        /// `0` is a bit-exact identity, `1` is the effect at full strength.
        /// This is the default and all but four effects use it.
        case intensity
        /// `0.5` is identity; the two halves of the fader do opposite things.
        /// Only for effects where the inverse is a real, wanted look —
        /// desaturate/oversaturate, under/over expose, cool/warm, pinch/bulge.
        case bipolar
    }

    public var amountMode: AmountMode {
        switch self {
        // Bipolar by design. Collapsing these to unipolar would delete the
        // negative half of each effect, which is half the effect.
        case .saturation, .exposure, .temperature, .fisheye: return .bipolar
        default: return .intensity
        }
    }

    /// Where `param` has to sit for the effect to be parked, or `nil` if it does
    /// not matter.
    ///
    /// `nil` for everything except `temperature`, and that is deliberate: at the
    /// neutral `amount` every other effect is an identity no matter where its
    /// second knob is left, so an operator can preset the second knob and then
    /// bring the effect in on one fader.
    ///
    /// `temperature` is the exception because its two knobs are *independent*
    /// white-balance axes — warm/cool on `amount`, green/magenta on `param` —
    /// and gating the tint behind the temperature would make a pure tint
    /// impossible. It is parked at 0.5/0.5, not at 0.5/anything.
    public var neutralParam: Float? {
        self == .temperature ? 0.5 : nil
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
        // `wave` was missing here until 2026-10-13 even though its shader reads
        // `u.time`: a wave on a still frame would have frozen the moment damage
        // tracking decided nothing had changed.
        case .noise, .strobe, .wave: return true
        default: return false
        }
    }
}

/// One effect instance with its parameters.
/// One effect instance in a chain.
///
/// ## Why there is a `values` array rather than two named floats
///
/// This was `{ amount, param }` — exactly two controls. That is enough for the
/// 35 built-ins and for nothing beyond them: Resolume's `Stripper` has 21
/// parameters, `Iterate` has 40+, `ParticleSystem` has 30. Two floats is not a
/// simplification of those, it is a wall, and every effect written against the
/// pair cements it. Widening the shape is cheap now and ruinous once sixty
/// effects have hardcoded two floats, so it happens now.
///
/// `amount` and `param` remain as accessors onto `values[0]` and `values[1]`,
/// because they are the right names for the first two controls and every
/// existing call site is correct. Nothing had to be rewritten to gain the
/// capacity.
///
/// ## Why `mix` and `blend` live here and not in each shader
///
/// Every one of the 116 presets in Resolume's own factory set has the shape
/// `DryWetEffect → Effect → Mixer`. Dry/wet and a per-effect blend mode are
/// **host infrastructure**, not something each effect implements. Photon's
/// `amount` was doing double duty as both strength and wet/dry, which is why
/// effects like `kaleidoscope` and `posterize` have no natural fade-in: their
/// `amount` changes *what* they do, so it cannot also control *how much*.
///
/// Hoisting it here gives all 35 a real fade and a blend mode without touching
/// any of their shader code.
public struct Effect: Sendable {
    /// Largest parameter count a single effect may declare.
    ///
    /// Sized past Resolume's worst case (`Iterate`, 40+) so the limit is not
    /// reached by porting something that already exists. The uniform buffer is
    /// per-pass and tiny; there is no reason to be mean here.
    public static let maxValues = 48

    public var kind: EffectKind
    /// Parameter values, indexed as the effect's own spec defines them.
    ///
    /// Always at least two entries, so `amount` and `param` are total.
    public private(set) var values: [Float]
    /// Bypassed without being removed, so settings survive an A/B.
    public var enabled: Bool
    /// Dry/wet, `0` = untouched input, `1` = the effect alone.
    ///
    /// Separate from `amount` on purpose — see the type note above.
    public var mix: Float
    /// How the wet result combines back over the dry input.
    ///
    /// `.over` reproduces ordinary behaviour, so this is free to ignore.
    public var blend: BlendMode

    /// Primary amount, 0...1. Modulatable like any other parameter.
    public var amount: Float {
        get { values[0] }
        set { values[0] = newValue }
    }

    /// Secondary control; meaning depends on the effect. See ``EffectKind/paramLabel``.
    public var param: Float {
        get { values[1] }
        set { values[1] = newValue }
    }

    public init(kind: EffectKind, amount: Float = 0.5,
                param: Float = 0.5, enabled: Bool = true,
                mix: Float = 1, blend: BlendMode = .over) {
        self.kind = kind
        self.values = [amount, param]
        self.enabled = enabled
        self.mix = mix
        self.blend = blend
    }

    /// An effect with an explicit parameter list.
    ///
    /// Padded to two and clamped to ``maxValues`` so `amount` and `param`
    /// cannot trap, whatever a caller or a loaded document supplies. A show
    /// file is untrusted input.
    public init(kind: EffectKind, values: [Float], enabled: Bool = true,
                mix: Float = 1, blend: BlendMode = .over) {
        var v = Array(values.prefix(Self.maxValues))
        while v.count < 2 { v.append(0.5) }
        self.kind = kind
        self.values = v
        self.enabled = enabled
        self.mix = mix
        self.blend = blend
    }

    /// Reads a parameter beyond the first two, or `nil` if not present.
    ///
    /// Returns `nil` rather than a default: an effect asking for a control it
    /// was not given is a bug in the caller, and a silent `0.5` would hide it.
    public func value(at index: Int) -> Float? {
        values.indices.contains(index) ? values[index] : nil
    }

    /// Sets a parameter, growing the list if needed. Ignored past ``maxValues``.
    public mutating func setValue(_ v: Float, at index: Int) {
        guard index < Self.maxValues else { return }
        while values.count <= index { values.append(0.5) }
        values[index] = v
    }
}

/// Uniforms for one effect pass. Must match `EffectUniforms` in the shader.
struct EffectUniforms {
    var amount: Float
    var param: Float
    var kind: Int32
    /// Seconds since start, for anything that must free-run against wall-clock.
    /// Nothing does, as of the 2026-10-13 pass: `wave` and `noise` moved onto
    /// `beat` with `strobe`, because an animating effect that drifts against the
    /// music is the first thing an operator notices and the last thing they can
    /// fix from the surface. Kept in the ABI; a future effect may want it.
    var time: Float
    var resolution: SIMD2<Float>
    /// Continuous musical position, so a strobe can lock to tempo rather than
    /// to wall-clock seconds — which is the entire point of having a clock.
    var beat: Float
    /// Dry/wet. Applied by the chain, not by any effect.
    var mix: Float
    /// `BlendMode.rawValue` for folding the wet result over the dry input.
    var blend: Int32
    /// How many entries of the parameter buffer are real.
    var valueCount: Int32
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
                // Wrapped so the float stays precise across a long show: a
                // 32-bit float at beat 400,000 cannot represent a sixteenth
                // note, and a strobe would visibly quantise.
                //
                // 256 beats, not 4. A strobe period that does not divide the
                // wrap gets one phase discontinuity per wrap, and at a 4-beat
                // wrap that was a visible stutter every two seconds for most
                // settings. 256 is a power of two (so every binary division
                // stays seamless), keeps 2^-15-beat precision in fp32, and
                // pushes the worst case to once every ~2 minutes at 128 BPM.
                beat: Float(beat.truncatingRemainder(dividingBy: 256.0)),
                mix: fx.mix,
                blend: fx.blend.rawValue,
                valueCount: Int32(fx.values.count))
            enc.setFragmentBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            // The full parameter list rides in its own buffer so adding a
            // control to an effect never changes the uniform layout — the
            // exact class of silent ABI drift that cost a crash today.
            var vals = fx.values
            enc.setFragmentBytes(&vals, length: MemoryLayout<Float>.stride * vals.count,
                                 index: 1)
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

    /// The blend maths are spliced in from ``BlendMSL`` rather than written
    /// here, so the compositor and the effect chain cannot disagree about what
    /// "Multiply" means. A second copy is how the Swift/Rust enum drifted.
    static var shaderSource: String { shaderHead + BlendMSL.source + shaderBody }

    private static let shaderHead = """
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
        float  mix;         // 28
        int    blend;       // 32
        int    valueCount;  // 36
    };

    vertex float4 effect_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    """

    private static let shaderBody = """

    constant float TAU = 6.283185307;
    constant float GOLDEN_ANGLE = 2.39996323;

    static inline float luma709(float3 c) {
        return dot(c, float3(0.2126, 0.7152, 0.0722));
    }

    // ---- Linear <-> display transfer ----------------------------------------
    //
    // Everything in this pipeline is linear light (rgba16Float), which is right
    // for compositing and wrong for every operation an operator thinks of in
    // terms of "mid grey". Contrast, gamma, posterize bands, a threshold cut, a
    // halftone dot's coverage and a hue wheel are all *perceptual* quantities:
    // done in linear light they bunch everything into the bottom of the range
    // and the top 80% of the fader does nothing visible.
    //
    // So the perceptual effects convert to display space, do the work there, and
    // convert back. The round trip is exact to ~1e-7, which keeps "amount = 0 is
    // an identity" true in practice as well as in principle.
    //
    // Effects that are physical rather than perceptual — exposure, temperature,
    // glow's bright pass, every blur and every geometric warp — stay in linear
    // light, because that is where adding and averaging light is correct.
    static inline float3 srgbToLin(float3 c) {
        c = max(c, 0.0);
        float3 lo = c * (1.0 / 12.92);
        float3 hi = pow((c + 0.055) * (1.0 / 1.055), 2.4);
        return select(lo, hi, c > 0.04045);
    }

    static inline float3 linToSRGB(float3 c) {
        c = max(c, 0.0);
        float3 lo = c * 12.92;
        float3 hi = 1.055 * pow(c, 1.0 / 2.4) - 0.055;
        return select(lo, hi, c > 0.0031308);
    }

    /// Perceptual luma, 0...1 for an in-gamut pixel. What a key, a threshold or
    /// a halftone dot should be measuring.
    static inline float lumaPerceptual(float3 linear_c) {
        return luma709(linToSRGB(linear_c));
    }

    /// A cheap stand-in for the above, for the multi-tap operators where a
    /// per-tap sRGB transfer is not worth the ALU. sqrt is gamma 2.0 — close
    /// enough to 2.2 that no one can see the difference in an edge map.
    static inline float lumaFast(float3 linear_c) {
        return sqrt(max(luma709(linear_c), 0.0));
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

    /// Chroma coordinates with luma divided out. The right space for a chroma
    /// key: a desaturated pixel sits near the origin whatever its brightness,
    /// so grey footage stops being "almost every hue at once".
    static inline float2 chromaUV(float3 display_c) {
        float y = luma709(display_c);
        return float2(display_c.b - y, display_c.r - y);
    }

    static inline float hash21(float2 p) {
        p = fract(p * float2(443.897, 441.423));
        p += dot(p, p + 19.19);
        return fract((p.x + p.y) * p.x);
    }

    /// 25-tap disc blur on a golden-angle spiral, radius in *output pixels*.
    ///
    /// The old 5x5 grid cost the same 25 taps but spaced them on a lattice, so
    /// past about a 3-texel radius it stopped being a blur and became 25 visible
    /// ghosts in a square. A spiral with sqrt-distributed radii samples the disc
    /// uniformly, and `jitter` rotates it per pixel so the residual undersampling
    /// lands as fine grain instead of as rings — the same trade every real-time
    /// bokeh does, and the only way to get a wide blur out of one pass.
    ///
    /// `aniso` scales the disc per axis, which is what makes a directional blur
    /// possible without a second pass.
    static inline float4 discBlur(texture2d<float> src, sampler sm, float2 uv,
                                  float2 texel, float2 aniso,
                                  float radiusPx, float jitter) {
        float4 sum = src.sample(sm, uv);
        if (!(radiusPx > 0.0)) { return sum; }   // also catches NaN
        float wsum = 1.0;
        const int N = 24;
        for (int i = 0; i < N; ++i) {
            float fi = float(i) + 0.5;
            float rr = sqrt(fi / float(N));
            float th = fi * GOLDEN_ANGLE + jitter;
            float2 off = float2(cos(th), sin(th)) * rr * radiusPx * aniso * texel;
            float w = exp(-rr * rr * 1.6);
            sum += src.sample(sm, uv + off) * w;
            wsum += w;
        }
        return sum / wsum;
    }

    // The `case` numbers below are `EffectKind.rawValue` and nothing else.
    // They are asserted against Swift by `every effect kind is implemented` in
    // PhotonVerify — a kind that falls through to `default` is a bug, not a
    // placeholder, because the browser offers it to the operator regardless.
    // The effect itself. Returns the WET result only — dry/wet and the
    // per-effect blend are applied by `effect_fragment` below, so no effect
    // has to implement them and none can implement them inconsistently.
    //
    // `vals` carries the full parameter list. `u.amount` and `u.param` are
    // `vals[0]` and `vals[1]`; effects needing more read `vals[n]` after
    // checking `u.valueCount`.
    static float4 effect_wet(constant EffectUniforms &u,
                             texture2d<float> src,
                             sampler sm,
                             float2 uv,
                             float2 texel,
                             constant float *vals)
    {
        float  a = u.amount;
        float  p = u.param;
        // Aspect, for every effect with a notion of "round" or "the same
        // distance in both directions". Without it a kaleidoscope on a 16:9
        // canvas is an ellipse and a vignette is an oval, which reads as a bug.
        float  asp = u.resolution.x / max(u.resolution.y, 1.0);
        float2 aspv = float2(asp, 1.0);
        float  minRes = min(u.resolution.x, u.resolution.y);

        switch (u.kind) {

        // ---- Colour: operate on the pixel where it is ----
        //
        // These are perceptual operations, so they run in display space. In
        // linear light a "contrast" knob crushes everything below 18% grey and
        // the operator only ever uses the first fifth of the fader.
        case 0: {   // levels — contrast (amount) then gamma (param)
            float4 c = src.sample(sm, uv);
            float3 s = linToSRGB(c.rgb);
            float contrast = 1.0 + a * a * 7.0;         // 1x .. 8x
            // Gamma is neutral at param 0.5, and `amount` is the drive for BOTH
            // knobs — raising gamma to the power of `amount` is what keeps
            // amount = 0 an exact identity even with the gamma knob parked
            // somewhere else. A fader at rest must not be doing anything.
            float gBase = (p <= 0.5) ? mix(0.35, 1.0, p * 2.0)
                                     : mix(1.0, 3.0, (p - 0.5) * 2.0);
            float g = pow(gBase, a);
            s = (s - 0.5) * contrast + 0.5;
            s = pow(max(s, 0.0), g);
            return float4(srgbToLin(s), c.a);
        }
        case 1: {   // invert
            // Perceptual, not 1-x in linear light: a linear invert turns mid
            // grey into near-white and looks blown out. This one maps 18% grey
            // to 18% grey's complement, which is what an operator expects.
            float4 c = src.sample(sm, uv);
            float3 inv = srgbToLin(1.0 - linToSRGB(c.rgb));
            return float4(mix(c.rgb, inv, a), c.a);
        }
        case 2: {   // saturation — BIPOLAR: 0 grey, 0.5 identity, 1 is 3x
            float4 c = src.sample(sm, uv);
            float3 s = linToSRGB(c.rgb);
            float l = luma709(s);
            float k = (a <= 0.5) ? (a * 2.0) : (1.0 + (a - 0.5) * 4.0);
            s = max(l + (s - l) * k, 0.0);
            return float4(srgbToLin(s), c.a);
        }
        case 3: {   // hue rotate — param is the target hue, amount how far
            // The old version cross-faded between the original and the rotated
            // colour, which desaturates through the middle of the fader. Scaling
            // the *angle* keeps saturation and still lands on identity at zero.
            float4 c = src.sample(sm, uv);
            float3 s = linToSRGB(c.rgb);
            float3 r = max(hueShift(s, a * p * TAU), 0.0);
            return float4(srgbToLin(r), c.a);
        }
        case 4: {   // colorize — luma ramped into a single hue
            float4 c = src.sample(sm, uv);
            float3 s = linToSRGB(c.rgb);
            float3 t = hsv2rgb(float3(fract(p), 1.0, 1.0)) * luma709(s);
            return float4(srgbToLin(mix(s, t, a)), c.a);
        }
        case 5: {   // duotone — shadows and highlights to complementary hues
            float4 c = src.sample(sm, uv);
            float3 s = linToSRGB(c.rgb);
            float l = saturate(luma709(s));
            float3 lo = hsv2rgb(float3(fract(p), 0.85, 0.20));
            float3 hi = hsv2rgb(float3(fract(p + 0.5), 0.65, 1.0));
            // Smoothstepped ramp: a linear ramp between two saturated hues goes
            // muddy through the midtones.
            float3 d = mix(lo, hi, l * l * (3.0 - 2.0 * l));
            return float4(srgbToLin(mix(s, d, a)), c.a);
        }
        case 6: {   // threshold — param is the cut, amount the mix
            float4 c = src.sample(sm, uv);
            float l = lumaPerceptual(c.rgb);
            // Antialiased: a hard step on a moving image crawls badly, and the
            // screen is 10 metres wide. fwidth gives the cut a one-pixel ramp
            // for free. Floored so a flat region cannot divide by zero.
            float w = max(fwidth(l) * 0.5, 1e-4);
            float k = smoothstep(p - w, p + w, l);
            return float4(mix(c.rgb, float3(k), a), c.a);
        }
        case 7: {   // posterize — param sets the band count
            float4 c = src.sample(sm, uv);
            float3 s = linToSRGB(c.rgb);
            // Label says "Levels", so more param = more levels. It was inverted.
            float n = max(floor(mix(2.0, 16.0, p)), 2.0);
            // Bands in perceptual space, spanning the full 0..1 range, so the
            // darkest band is black and the brightest is white.
            float3 q = saturate(floor(min(s, 0.99999) * n) / (n - 1.0));
            return float4(srgbToLin(mix(s, q, a)), c.a);
        }
        case 8: {   // solarize — Sabattier fold of the highlights
            float4 c = src.sample(sm, uv);
            float3 s = linToSRGB(c.rgb);
            // min(s, 1-s) is the same curve as the old branch but branchless and
            // safe above 1.0, where HDR pixels used to flip to large negatives.
            float3 f = min(s, max(1.0 - s, 0.0));
            return float4(srgbToLin(mix(s, f, a)), c.a);
        }
        case 9: {   // exposure — BIPOLAR: 0.5 identity, +/- 4 stops
            // Stays in linear light on purpose. Exposure is a physical scaling
            // of light and this is the one place linear is unambiguously right.
            float4 c = src.sample(sm, uv);
            return float4(c.rgb * exp2((a - 0.5) * 8.0), c.a);
        }
        case 10: {  // temperature — BIPOLAR on both knobs, 0.5/0.5 identity
            float4 c = src.sample(sm, uv);
            float t = (a - 0.5) * 2.0;
            float g = (p - 0.5) * 2.0;
            float3 v = c.rgb * float3(exp2(t * 0.9), exp2(g * 0.45), exp2(-t * 0.9));
            // Renormalise to the original luma: a white balance shift should
            // change the colour of the light, not how much of it there is.
            // Without this the knob doubles as a brightness control and an
            // operator chasing a warm look ends up clipping the wall.
            float l0 = luma709(max(c.rgb, 0.0));
            float l1 = luma709(max(v, 0.0));
            v *= (l0 > 1e-5 && l1 > 1e-5) ? (l0 / l1) : 1.0;
            return float4(max(v, 0.0), c.a);
        }

        // ---- Stylise: read a neighbourhood ----
        case 11: {  // blur — 25-tap disc, radius up to 15% of the short edge
            // At amount 1 this is ~160px at 1080p: the picture is *gone*, which
            // is what the top of the fader is for. The old 5x5 grid topped out
            // at 8 texels and the last two thirds of the sweep did nothing.
            float rad = a * a * 0.15 * minRes;
            float t = (p - 0.5) * 2.0;
            // Direction: 0 = horizontal streak, 0.5 = round, 1 = vertical.
            float2 aniso = float2(mix(1.0, 0.12, saturate(t)),
                                  mix(1.0, 0.12, saturate(-t)));
            float j = hash21(uv * u.resolution) * TAU;
            return discBlur(src, sm, uv, texel, aniso, rad, j);
        }
        case 12: {  // sharpen — unsharp mask, 9 taps (was 25)
            float r = mix(0.6, 4.0, p);
            float4 c = src.sample(sm, uv);
            float3 b = float3(0.0);
            float wsum = 0.0;
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    float w = (x == 0 && y == 0) ? 4.0 : ((x == 0 || y == 0) ? 2.0 : 1.0);
                    b += src.sample(sm, uv + float2(x, y) * texel * r).rgb * w;
                    wsum += w;
                }
            }
            b /= wsum;
            // Clamped at zero: an unsharp mask on a hard edge undershoots, and a
            // negative in a linear-light buffer survives all the way to a pow()
            // in the output encode, where it becomes NaN.
            return float4(max(c.rgb + (c.rgb - b) * a * 4.0, 0.0), c.a);
        }
        case 13: {  // edge detect — sobel on perceptual luma
            float r = mix(1.0, 4.0, p);
            float gx = 0.0, gy = 0.0;
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    float l = lumaFast(src.sample(sm, uv + float2(x, y) * texel * r).rgb);
                    float sx = float(x) * ((y == 0) ? 2.0 : 1.0);
                    float sy = float(y) * ((x == 0) ? 2.0 : 1.0);
                    gx += l * sx; gy += l * sy;
                }
            }
            // Edges off a linear-light luma are invisible in shadow and blown in
            // highlight; off a gamma-ish luma they track what the eye sees.
            float e = saturate(sqrt(gx * gx + gy * gy) * 1.25);
            float4 c = src.sample(sm, uv);
            return float4(mix(c.rgb, srgbToLin(float3(e)), a), c.a);
        }
        case 14: {  // emboss — diagonal difference around perceptual mid-grey
            float r = mix(1.0, 4.0, p);
            float d = lumaFast(src.sample(sm, uv - texel * r).rgb)
                    - lumaFast(src.sample(sm, uv + texel * r).rgb);
            // 0.5 here means *perceptual* mid-grey, so it is converted rather
            // than written straight into a linear buffer where it reads as 73%.
            float e = saturate(0.5 + d * 2.0);
            float4 c = src.sample(sm, uv);
            return float4(mix(c.rgb, srgbToLin(float3(e)), a), c.a);
        }
        case 15: {  // glow — thresholded bright pass, blurred, added back
            // The bright pass now happens *per tap*, before the blur. Blurring
            // first and thresholding after (the old order) halos the whole
            // image instead of only what is actually bright.
            float4 c = src.sample(sm, uv);
            float thr = mix(0.02, 1.2, p);
            float rad = (0.012 + a * 0.06) * minRes;   // radius follows amount
            float j = hash21(uv * u.resolution + 7.13) * TAU;
            float3 sum = max(c.rgb - thr, 0.0);
            float wsum = 1.0;
            const int N = 20;
            for (int i = 0; i < N; ++i) {
                float fi = float(i) + 0.5;
                float rr = sqrt(fi / float(N));
                float th = fi * GOLDEN_ANGLE + j;
                float2 off = float2(cos(th), sin(th)) * rr * rad * texel;
                float w = exp(-rr * rr * 1.4);
                sum += max(src.sample(sm, uv + off).rgb - thr, 0.0) * w;
                wsum += w;
            }
            // Linear light, additively — bloom is light arriving, not a blend.
            return float4(c.rgb + (sum / wsum) * a * 3.0, c.a);
        }
        case 16: {  // halftone — perceptual luma into dots on a rotated grid
            float cellPx = mix(3.0, 40.0, p);
            float ca = cos(0.4), sa = sin(0.4);
            float2 g = uv * u.resolution / cellPx;
            float2 rg = float2(g.x * ca - g.y * sa, g.x * sa + g.y * ca);
            float2 cc = floor(rg) + 0.5;
            // Un-rotate the cell centre so the source is sampled where the cell
            // actually is, and average four points inside it. Sampling one
            // texel at the centre (the old way) aliased into a shimmering mess
            // the moment the footage moved.
            float2 ig = float2(cc.x * ca + cc.y * sa, -cc.x * sa + cc.y * ca);
            float2 cuv = ig * cellPx / u.resolution;
            float2 o = cellPx * texel * 0.25;
            float3 acc = src.sample(sm, cuv + float2(-o.x, -o.y)).rgb
                       + src.sample(sm, cuv + float2( o.x, -o.y)).rgb
                       + src.sample(sm, cuv + float2(-o.x,  o.y)).rgb
                       + src.sample(sm, cuv + float2( o.x,  o.y)).rgb;
            float3 avg = acc * 0.25;
            // Dot *area* tracks perceptual luma, so radius goes as its sqrt.
            float l = saturate(lumaPerceptual(avg));
            float d = length(rg - cc) - sqrt(l) * 0.78;
            float w = max(fwidth(d), 1e-4);          // one-pixel edge, no jaggies
            float dotv = 1.0 - smoothstep(-w, w, d);
            // Dots carry the cell's hue, normalised to full value — Resolume's
            // Polkadot keeps the raw cell colour, which darkens twice (small dot
            // AND dim dot) and loses the shadows entirely. Normalising lets the
            // dot area do all the tonal work, which is what a halftone is.
            float mx = max(max(avg.r, avg.g), avg.b);
            float3 tint = (mx > 1e-3) ? avg / mx : float3(1.0);
            float4 c = src.sample(sm, uv);
            return float4(mix(c.rgb, tint * dotv, a), c.a);
        }
        case 17: {  // pixelate
            // Geometric, not linear: 1 texel at amount 0 up to 8 blocks across
            // at amount 1, so the whole sweep is useful instead of the first 5%.
            float cellPx = pow(max(minRes / 8.0, 1.0), a);
            float2 q = (floor(uv * u.resolution / cellPx) + 0.5) * cellPx / u.resolution;
            // Four taps spanning the cell instead of one at its centre — kills
            // the shimmer a point sample gives on moving footage. The offset
            // collapses to zero at cellPx = 1, which is what keeps amount = 0 a
            // bit-exact identity rather than a quarter-texel smear.
            float2 o = max(cellPx - 1.0, 0.0) * texel * 0.25;
            float4 s = src.sample(sm, q + float2(-o.x, -o.y))
                     + src.sample(sm, q + float2( o.x, -o.y))
                     + src.sample(sm, q + float2(-o.x,  o.y))
                     + src.sample(sm, q + float2( o.x,  o.y));
            return s * 0.25;
        }

        // ---- Distort: read somewhere else entirely ----
        case 18: {  // kaleidoscope — amount is segment count, param the rotation
            float segs = floor(mix(1.0, 16.0, a) + 1e-4);
            if (segs <= 1.0) { return src.sample(sm, uv); }   // identity at zero
            float2 d = (uv - 0.5) * aspv;
            float rad = length(d);
            float ang = atan2(d.y, d.x) + p * TAU;
            float seg = TAU / segs;
            // Positive modulo. fmod() keeps the sign of the dividend, so the old
            // version folded the left half of the screen differently from the
            // right and put a seam down the middle.
            ang -= seg * floor(ang / seg);
            ang = abs(ang - seg * 0.5);
            return src.sample(sm, 0.5 + float2(cos(ang), sin(ang)) * rad / aspv);
        }
        case 19: {  // mirror — param picks the axis, amount dissolves it in
            float2 q = uv;
            if (p < 1.0 / 3.0)      { q.x = 0.5 - abs(q.x - 0.5); }
            else if (p < 2.0 / 3.0) { q.y = 0.5 - abs(q.y - 0.5); }
            else                    { q = 0.5 - abs(q - 0.5); }
            // Cross-fade the two images, not the two coordinates. Lerping the
            // coordinate squashes the picture on the way across; lerping the
            // colour dissolves, which is what a mix knob should do. The old
            // step(0.001, a) made this a switch with a dead fader attached.
            return mix(src.sample(sm, uv), src.sample(sm, q), a);
        }
        case 20: {  // twirl
            float2 ctr = float2(p, 0.5);
            float2 d = (uv - ctr) * aspv;
            float r = length(d);
            float falloff = 1.0 - smoothstep(0.0, 0.55, r);
            float ang = atan2(d.y, d.x) + falloff * falloff * a * TAU * 2.0;
            return src.sample(sm, ctr + float2(cos(ang), sin(ang)) * r / aspv);
        }
        case 21: {  // fisheye — BIPOLAR: 0 pinch, 0.5 identity, 1 bulge
            float2 ctr = float2(p, 0.5);
            float2 d = (uv - ctr) * aspv;
            // Polynomial lens distortion rather than pow(r, k-1): no singularity
            // at the centre, no pow of a near-zero base, and the usual shape.
            float s = max(1.0 + (a - 0.5) * 4.0 * dot(d, d), 0.05);
            return src.sample(sm, ctr + d * s / aspv);
        }
        case 22: {  // wave — tempo-locked, see EffectKind.isTimeVarying
            float f = mix(1.0, 12.0, p) * TAU;
            // Runs on `beat`, not wall-clock. A ripple that drifts against the
            // music is the thing a VJ notices first and cannot fix from the
            // surface. The two rates are 1/2 and 1/4 cycles per beat: binary
            // fractions, so they are also seamless across the 256-beat wrap.
            float ph = u.beat * TAU;
            float2 amp = float2(a * 0.06 / asp, a * 0.06);
            float2 q = uv + float2(sin(uv.y * f + ph * 0.5),
                                   sin(uv.x * f * 0.8 + ph * 0.25 + 1.7)) * amp;
            return src.sample(sm, q);
        }
        case 23: {  // tile — amount is the count, param the offset
            float n = floor(mix(1.0, 8.0, a) + 1e-4);
            if (n <= 1.0) { return src.sample(sm, uv); }       // identity at zero
            // param was documented as "Offset" and then ignored. It phases the
            // tiling now, which is the whole point of having it.
            float2 q = fract(uv * n + p);
            // Half a texel in from each wrap, or the linear sampler interpolates
            // across the seam and every tile gets a bright line down two edges.
            return src.sample(sm, clamp(q, texel * 0.5, 1.0 - texel * 0.5));
        }
        case 24: {  // slide — wraps, param is the direction
            float ang = p * TAU;
            float2 q = fract(uv + float2(cos(ang), sin(ang)) * a);
            return src.sample(sm, clamp(q, texel * 0.5, 1.0 - texel * 0.5));
        }
        case 25: {  // polar — param picks the direction of the mapping
            float2 d = (uv - 0.5) * aspv;
            float2 toPolar = float2(atan2(d.y, d.x) / TAU + 0.5,
                                    saturate(length(d) * 2.0));
            float2 toRect = 0.5 + float2(cos(uv.x * TAU), sin(uv.x * TAU))
                                  * uv.y * 0.5 / aspv;
            float2 q = (p < 0.5) ? toPolar : toRect;
            return src.sample(sm, mix(uv, q, a));
        }
        case 26: {  // zoom — param is the centre
            // Exponential, so the fader is even all the way up to ~11x instead
            // of spending its first half between 1.0x and 1.6x.
            return src.sample(sm, float2(p, 0.5) + (uv - float2(p, 0.5)) * exp2(-a * 3.5));
        }

        // ---- Texture ----
        case 27: {  // rgb shift — channels diverge along an angle
            float ang = p * TAU;
            // A fraction of the frame, not a texel count: 30 texels is a strong
            // effect at 480p and invisible at 4K, and the operator should not
            // have to re-dial the knob when the output resolution changes.
            float2 d = float2(cos(ang) / asp, sin(ang)) * a * 0.03;
            float4 c = src.sample(sm, uv);
            return float4(src.sample(sm, uv + d).r, c.g, src.sample(sm, uv - d).b, c.a);
        }
        case 28: {  // chromatic aberration — radial, strongest at the edges
            float2 d = uv - 0.5;
            float k = a * 0.09;
            // Green shifted a third as far in the same direction as red: a real
            // lens does not leave the green channel exactly where it started,
            // and the slight offset is what stops this looking like RGB Shift
            // with a different angle. Four taps, up from three.
            float4 c = src.sample(sm, uv);
            return float4(src.sample(sm, 0.5 + d * (1.0 + k)).r,
                          src.sample(sm, 0.5 + d * (1.0 + k * 0.35)).g,
                          src.sample(sm, 0.5 + d * (1.0 - k)).b,
                          c.a);
        }
        case 29: {  // vignette
            // The old form was smoothstep(0.75, mix(0.75, 0.1, a), r), whose two
            // edges are EQUAL at amount 0 — a division by zero, and whatever the
            // driver returned for it went straight to the wall. This cannot.
            float rn = length((uv - 0.5) * aspv) / (0.5 * length(aspv));
            float soft = mix(0.05, 1.0, p);
            float start = 1.0 - a;                 // amount 0 -> starts past the corner
            float t = saturate((rn - start) / max(soft, 1e-3));
            float v = 1.0 - t * t * (3.0 - 2.0 * t);
            float4 c = src.sample(sm, uv);
            return float4(c.rgb * v, c.a);
        }
        case 30: {  // scanlines — param is the count, via a pixel pitch
            // Pitch in *output pixels*, not cycles across the frame. 900 cycles
            // over a 1080p frame is a 1.2px pitch, which is below Nyquist and
            // aliases into moire; worse, the same setting means something
            // different on every output size.
            float pitch = mix(32.0, 2.0, p);
            float s = 0.5 + 0.5 * cos((uv.y * u.resolution.y / pitch) * TAU);
            // Fade the modulation out as the pitch approaches two pixels.
            float depth = a * saturate(pitch - 1.6);
            float4 c = src.sample(sm, uv);
            return float4(c.rgb * mix(1.0, s * s, depth), c.a);
        }
        case 31: {  // noise — free-running grain, param is the grain size
            // param was documented as "Grain" and ignored. It is the grain cell
            // size now, 1 to 8 pixels.
            float gs = mix(1.0, 8.0, p);
            // Re-rolled 32 times a beat off the musical clock rather than off
            // wall-clock seconds — ~68 Hz at 128 BPM, and it slows with the set
            // instead of sliding against it. 32 is a power of two, so the
            // sequence is also continuous across the 256-beat wrap.
            //
            // Quantised rather than continuous so the grain is stable *within* a
            // frame: sampling a hash on an unquantised clock makes the pattern
            // depend on the exact float the frame was submitted with, which is
            // how grain ends up crawling at a different rate to the frame rate.
            float n = hash21(floor(uv * u.resolution / gs) + floor(u.beat * 32.0) * 17.13);
            float4 c = src.sample(sm, uv);
            // Signed and additive in display space. The old multiplicative
            // (0.5 + n) form left black pixels black, so grain vanished in the
            // shadows — exactly where film grain is most visible.
            float3 s = max(linToSRGB(c.rgb) + (n - 0.5) * a * 0.7, 0.0);
            return float4(srgbToLin(s), c.a);
        }
        case 32: {  // strobe — gated on musical phase, not wall-clock
            float period = mix(4.0, 0.125, p);     // beats per cycle
            float ph = fract(u.beat / max(period, 1e-3));
            // A duty cycle, and edges with a ramp. A bare step() gates on or off
            // between two frames: at 60 Hz against a 128 BPM eighth-note that
            // lands on a different sub-frame position every cycle and the strobe
            // visibly stutters. The ramp also means the gate is temporally
            // antialiased rather than a hard binary per frame.
            const float duty = 0.4, edge = 0.05;
            float g = 1.0 - smoothstep(duty - edge, duty + edge, ph);
            g = max(g, smoothstep(1.0 - edge, 1.0, ph));   // soften the wrap back on
            float4 c = src.sample(sm, uv);
            return float4(c.rgb * mix(1.0, g, a), c.a);
        }

        // ---- Keying ----
        case 33: {  // luma key — amount is the cut, param the softness
            float4 c = src.sample(sm, uv);
            float l = lumaPerceptual(c.rgb);       // perceptual: a key is an eye judgement
            float soft = mix(0.002, 0.5, p);
            // The WHOLE ramp has to clear zero at amount 0, not just its lower
            // edge. A fixed -0.05 offset left the ramp's top at +0.45 for a
            // wide softness, so a parked key still dimmed every shadow in the
            // frame — alpha 0.219 across 23% of a test image. Scaling the
            // offset by the softness makes `lo + soft == 0` exactly when
            // amount is 0, so every non-negative luma is fully opaque and the
            // identity is real at any softness rather than only a narrow one.
            float lo = a * (1.0 + soft) - soft;
            return float4(c.rgb, c.a * smoothstep(lo, lo + soft, l));
        }
        case 34: {  // chroma key — amount is the tolerance, param the key hue
            float4 c = src.sample(sm, uv);
            float3 s = linToSRGB(c.rgb);
            float3 key = hsv2rgb(float3(fract(p), 1.0, 1.0));
            // Distance in the luma-free chroma plane. The old version compared
            // normalize(rgb) vectors, which on desaturated footage is the
            // direction of a near-grey vector: numerically unstable, wildly
            // sensitive, and it keyed shadows out of anything slightly tinted.
            float d = distance(chromaUV(s), chromaUV(key));
            float tol = a * 1.2;
            float soft = a * 0.25 + 1e-4;          // never a zero-width smoothstep
            float k = smoothstep(tol - soft, tol + soft, d);
            // Spill suppression: partly-keyed pixels keep the key colour around
            // their edges, which is the giveaway on every bad key. Pull them
            // toward their own luma in proportion to how keyed they are.
            float3 despilled = mix(s, float3(luma709(s)), (1.0 - k) * 0.6);
            return float4(srgbToLin(despilled), c.a * k);
        }

        default:
            return src.sample(sm, uv);
        }
    }

    // Dry/wet and the per-effect blend, applied once for every effect.
    //
    // This is the `DryWetEffect -> Effect -> Mixer` shape every Resolume preset
    // has. Doing it here rather than inside each effect is the difference
    // between 35 effects that each fade their own way and 35 that fade the
    // same way — and it gives a real fade to the ones whose `amount` changes
    // WHAT they do rather than how much, which could never fade themselves.
    //
    // At `mix == 1` and `blend == over` this is a bit-exact passthrough of the
    // wet result, so nothing that worked before changes.
    fragment float4 effect_fragment(float4 pos [[position]],
                                    constant EffectUniforms &u [[buffer(0)]],
                                    constant float *vals [[buffer(1)]],
                                    texture2d<float> src [[texture(0)]])
    {
        constexpr sampler sm(filter::linear, address::clamp_to_edge);
        float2 uv = pos.xy / u.resolution;
        float2 texel = 1.0 / u.resolution;

        float4 wet = effect_wet(u, src, sm, uv, texel, vals);
        if (u.mix >= 1.0 && u.blend == 0) { return wet; }

        float4 dry = src.sample(sm, uv);
        float3 combined = blend_rgb(u.blend, dry.rgb, wet.rgb);
        // Alpha is crossfaded, never blended: a key's alpha is its entire
        // output, and running it through a colour blend would make a luma key
        // at half wet mean something nobody could predict.
        return float4(mix(dry.rgb, combined, u.mix), mix(dry.a, wet.a, u.mix));
    }
    """
}
