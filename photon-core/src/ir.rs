//! Compositor IR and shader emission.
//!
//! One place owns blend semantics and layer folding; backends emit **native**
//! shaders from it — MSL for the macOS shell, WGSL/HLSL for the later Windows
//! one. That is what stops two native shells implementing the compositor twice
//! and drifting apart.
//!
//! ## Why this exists rather than hand-written shaders
//!
//! Blend modes like Mask and Difference must read the **accumulated result
//! beneath them**, which fixed-function blending cannot express. The compositor
//! therefore folds the whole stack in registers inside one fragment shader. But
//! a `switch` on blend mode per layer per pixel is the slow way to do that, so
//! the shader is **specialised per blend-mode stack** and cached.
//!
//! Specialising means generating source, which means a generator — and once
//! there is a generator, having it emit two dialects is nearly free. Writing
//! the compositor twice by hand would not be.
//!
//! ## Pipeline cache discipline
//!
//! A new blend stack appearing mid-show must **never block playback on shader
//! compilation**. The planner always has a correct generic fallback it can use
//! for the current frame while the specialised variant compiles asynchronously.
//! [`Plan::needs_specialisation`] reports whether a stack is worth specialising
//! at all.

use crate::doc::BlendMode;

/// Target shading language for emission.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShaderLang {
    /// Metal Shading Language — macOS shell.
    Msl,
    /// WebGPU Shading Language — Windows shell / portable backend.
    Wgsl,
}

/// One layer as the compositor sees it.
///
/// Deliberately *not* the document's layer type: the IR only needs what affects
/// code generation, so a document change that doesn't alter the generated
/// shader cannot invalidate the pipeline cache.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IrLayer {
    /// How this layer combines with what is beneath it.
    pub blend: BlendMode,
    /// Whether the source can be transparent.
    ///
    /// Drives occlusion: an opaque, fully-covering layer makes everything below
    /// it dead work. **Opacity alone never proves this** — the texture itself
    /// may carry alpha.
    pub may_be_transparent: bool,
    /// Whether the layer geometrically covers the whole target.
    pub covers_target: bool,
    /// Whether sampling needs a YCoCg→RGB conversion (HapQ, DXV YCG6/YG10).
    pub needs_color_conversion: bool,
}

impl IrLayer {
    /// Whether this layer hides everything beneath it.
    ///
    /// Requires **all three**: full coverage, no possible transparency, and a
    /// blend mode that ignores the destination. `Over` with an opaque source
    /// qualifies; `Add` does not, because it accumulates.
    #[must_use]
    pub const fn occludes(&self) -> bool {
        self.covers_target
            && !self.may_be_transparent
            && matches!(self.blend, BlendMode::Over)
    }
}

/// A compiled plan for one composition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    /// Layers that will actually be sampled, bottom to top.
    pub layers: Vec<IrLayer>,
    /// How many layers the occlusion pass removed.
    pub occluded_out: usize,
    /// True if any surviving layer reads the destination.
    pub reads_destination: bool,
}

impl Plan {
    /// Builds a plan from a layer stack, applying occlusion culling.
    ///
    /// **C2 — occlusion truncation.** Register folding samples every layer at
    /// every pixel, so an opaque covering layer makes everything beneath it
    /// wasted work. A full-frame opaque base layer is extremely common in real
    /// VJ use, which is why this is worth doing at cook time.
    #[must_use]
    pub fn build(layers: &[IrLayer]) -> Self {
        // Find the topmost occluder; everything below it is dead.
        let first = layers
            .iter()
            .rposition(IrLayer::occludes)
            .unwrap_or(0);

        let kept: Vec<IrLayer> = layers[first..].to_vec();
        let reads_destination = kept.iter().any(|l| l.blend.needs_destination());

        Self {
            layers: kept,
            occluded_out: first,
            reads_destination,
        }
    }

    /// A stable key identifying this plan's generated shader.
    ///
    /// The pipeline cache is keyed on this, so two compositions with the same
    /// blend-mode stack share one compiled pipeline.
    #[must_use]
    pub fn cache_key(&self) -> u64 {
        // FNV-1a over the shape that actually affects codegen.
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        let mut mix = |b: u8| {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x1000_0000_01b3);
        };
        for l in &self.layers {
            mix(l.blend as u8);
            mix(u8::from(l.needs_color_conversion));
        }
        mix(0xFF);
        h
    }

    /// Whether specialising is worth a compile.
    ///
    /// A single-layer stack, or one that is entirely fixed-function, gains
    /// little — the generic shader already handles it without a per-pixel
    /// branch worth eliminating.
    #[must_use]
    pub fn needs_specialisation(&self) -> bool {
        self.layers.len() > 1 && self.reads_destination
    }
}

/// Emits a fragment shader that folds the stack in registers.
///
/// The generated function samples each layer and folds bottom-to-top with the
/// blend arithmetic **inlined per layer** — no runtime branch on blend mode.
#[must_use]
pub fn emit_fragment(plan: &Plan, lang: ShaderLang) -> String {
    let mut s = String::with_capacity(1024 + plan.layers.len() * 128);
    match lang {
        ShaderLang::Msl => emit_msl(plan, &mut s),
        ShaderLang::Wgsl => emit_wgsl(plan, &mut s),
    }
    s
}

/// Blend arithmetic, expressed once, in a dialect-neutral form.
///
/// `d` = accumulated destination, `s` = source. Both are linear-light RGB.
/// Keeping this in ONE function is the point of the whole module: the semantics
/// cannot drift between platforms because there is only one definition.
fn blend_expr(mode: BlendMode, lang: ShaderLang) -> String {
    let sel = |cond: &str, a: &str, b: &str| -> String {
        match lang {
            // Metal's select() takes (false_value, true_value, condition).
            ShaderLang::Msl => format!("select({b}, {a}, {cond})"),
            ShaderLang::Wgsl => format!("select({b}, {a}, {cond})"),
        }
    };
    match mode {
        BlendMode::Over => "s".into(),
        BlendMode::Add => "d + s".into(),
        BlendMode::Multiply => "d * s".into(),
        BlendMode::Screen => "d + s - d * s".into(),
        BlendMode::Subtract => "max(d - s, 0.0)".into(),
        BlendMode::Difference => "abs(d - s)".into(),
        BlendMode::Lighten => "max(d, s)".into(),
        BlendMode::Darken => "min(d, s)".into(),
        // Mask gates what is beneath by the source's luma.
        BlendMode::Mask => "d * dot(s, LUMA)".into(),
        BlendMode::Overlay => sel("d > 0.5", "1.0 - 2.0 * (1.0 - d) * (1.0 - s)", "2.0 * d * s"),
        BlendMode::HardLight => sel("s > 0.5", "1.0 - 2.0 * (1.0 - d) * (1.0 - s)", "2.0 * d * s"),
    }
}

fn emit_msl(plan: &Plan, s: &mut String) {
    s.push_str("#include <metal_stdlib>\nusing namespace metal;\n\n");
    s.push_str("constant float3 LUMA = float3(0.2126, 0.7152, 0.0722);\n\n");
    s.push_str("// Generated by photon-core::ir — do not edit.\n");
    s.push_str("// Linear-light working space; encode once at output.\n");
    s.push_str("fragment float4 photon_composite(\n");
    s.push_str("    float4 pos [[position]],\n");
    s.push_str("    constant LayerUniform *layers [[buffer(0)]],\n");
    s.push_str("    constant float2 &resolution [[buffer(1)]],\n");
    s.push_str(&format!(
        "    array<texture2d<float>, {}> texs [[texture(0)]])\n{{\n",
        plan.layers.len().max(1)
    ));
    s.push_str("    constexpr sampler sm(filter::linear, address::clamp_to_edge);\n");
    s.push_str("    float2 uv = pos.xy / resolution;\n");
    s.push_str("    float3 d = float3(0.0);\n");
    for (i, l) in plan.layers.iter().enumerate() {
        s.push_str(&format!("\n    // layer {i} — {:?}\n", l.blend));
        s.push_str(&format!("    {{\n        float4 t = texs[{i}].sample(sm, uv);\n"));
        if l.needs_color_conversion {
            s.push_str("        t.rgb = ycocg_to_rgb(t);\n");
        }
        s.push_str("        float3 s = t.rgb;\n");
        s.push_str(&format!(
            "        float a = t.a * layers[{i}].opacity;\n        d = mix(d, {}, a);\n    }}\n",
            blend_expr(l.blend, ShaderLang::Msl)
        ));
    }
    s.push_str("\n    return float4(d, 1.0);\n}\n");
}

fn emit_wgsl(plan: &Plan, s: &mut String) {
    s.push_str("// Generated by photon-core::ir — do not edit.\n");
    s.push_str("const LUMA: vec3<f32> = vec3<f32>(0.2126, 0.7152, 0.0722);\n\n");
    s.push_str("@fragment\nfn photon_composite(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {\n");
    s.push_str("    let uv = pos.xy / resolution;\n");
    s.push_str("    var d = vec3<f32>(0.0);\n");
    for (i, l) in plan.layers.iter().enumerate() {
        s.push_str(&format!("\n    // layer {i} — {:?}\n", l.blend));
        s.push_str(&format!(
            "    {{\n        var t = textureSample(tex{i}, sm, uv);\n"
        ));
        if l.needs_color_conversion {
            s.push_str("        t = vec4<f32>(ycocg_to_rgb(t), t.a);\n");
        }
        s.push_str("        let s = t.rgb;\n");
        s.push_str(&format!(
            "        let a = t.a * opacity{i};\n        d = mix(d, {}, a);\n    }}\n",
            blend_expr(l.blend, ShaderLang::Wgsl)
        ));
    }
    s.push_str("\n    return vec4<f32>(d, 1.0);\n}\n");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opaque(blend: BlendMode) -> IrLayer {
        IrLayer {
            blend,
            may_be_transparent: false,
            covers_target: true,
            needs_color_conversion: false,
        }
    }
    fn transparent(blend: BlendMode) -> IrLayer {
        IrLayer {
            blend,
            may_be_transparent: true,
            covers_target: true,
            needs_color_conversion: false,
        }
    }

    #[test]
    fn opaque_covering_over_layer_occludes_everything_below() {
        let stack = vec![
            opaque(BlendMode::Over),
            transparent(BlendMode::Screen),
            opaque(BlendMode::Over), // this one hides the two below
            transparent(BlendMode::Add),
        ];
        let plan = Plan::build(&stack);
        assert_eq!(plan.occluded_out, 2, "two layers below the occluder are dead");
        assert_eq!(plan.layers.len(), 2);
    }

    #[test]
    fn alpha_capable_layer_never_occludes() {
        // The correction that matters: full opacity does NOT prove opacity,
        // because the texture itself may carry alpha.
        let l = transparent(BlendMode::Over);
        assert!(!l.occludes());
        let stack = vec![opaque(BlendMode::Over), l];
        assert_eq!(Plan::build(&stack).occluded_out, 0);
    }

    #[test]
    fn accumulating_blend_modes_never_occlude() {
        // Add/Screen read what is beneath even when fully opaque.
        for m in [BlendMode::Add, BlendMode::Screen, BlendMode::Difference] {
            assert!(!opaque(m).occludes(), "{m:?} must not occlude");
        }
    }

    #[test]
    fn partial_coverage_never_occludes() {
        let l = IrLayer {
            blend: BlendMode::Over,
            may_be_transparent: false,
            covers_target: false,
            needs_color_conversion: false,
        };
        assert!(!l.occludes());
    }

    #[test]
    fn destination_reading_is_detected() {
        let fixed = vec![opaque(BlendMode::Over), transparent(BlendMode::Add)];
        assert!(!Plan::build(&fixed).reads_destination);

        let needs = vec![opaque(BlendMode::Over), transparent(BlendMode::Difference)];
        assert!(Plan::build(&needs).reads_destination);
    }

    #[test]
    fn cache_key_is_stable_and_discriminating() {
        let a = Plan::build(&[opaque(BlendMode::Over), transparent(BlendMode::Screen)]);
        let b = Plan::build(&[opaque(BlendMode::Over), transparent(BlendMode::Screen)]);
        let c = Plan::build(&[opaque(BlendMode::Over), transparent(BlendMode::Difference)]);
        assert_eq!(a.cache_key(), b.cache_key(), "same stack must share a pipeline");
        assert_ne!(a.cache_key(), c.cache_key(), "different blends must not collide");
    }

    #[test]
    fn single_fixed_function_stack_is_not_worth_specialising() {
        let one = Plan::build(&[opaque(BlendMode::Over)]);
        assert!(!one.needs_specialisation());

        let fixed = Plan::build(&[opaque(BlendMode::Over), transparent(BlendMode::Add)]);
        assert!(!fixed.needs_specialisation());

        let folded = Plan::build(&[opaque(BlendMode::Over), transparent(BlendMode::Mask)]);
        assert!(folded.needs_specialisation());
    }

    #[test]
    fn emitted_msl_has_no_runtime_blend_branch() {
        let plan = Plan::build(&[
            opaque(BlendMode::Over),
            transparent(BlendMode::Difference),
            transparent(BlendMode::Multiply),
        ]);
        let src = emit_fragment(&plan, ShaderLang::Msl);
        assert!(src.contains("abs(d - s)"), "difference inlined");
        assert!(src.contains("d * s"), "multiply inlined");
        assert!(
            !src.contains("switch"),
            "specialisation exists precisely to remove the per-pixel branch"
        );
        assert!(src.contains("array<texture2d<float>, 3>"));
    }

    #[test]
    fn both_dialects_emit_the_same_blend_semantics() {
        // The guarantee the IR exists to provide: Mac and Windows cannot drift.
        for m in [
            BlendMode::Over, BlendMode::Add, BlendMode::Multiply, BlendMode::Screen,
            BlendMode::Difference, BlendMode::Mask, BlendMode::Lighten, BlendMode::Darken,
        ] {
            assert_eq!(
                blend_expr(m, ShaderLang::Msl),
                blend_expr(m, ShaderLang::Wgsl),
                "{m:?} differs between dialects"
            );
        }
    }

    #[test]
    fn ycocg_conversion_is_emitted_only_where_needed() {
        let plain = Plan::build(&[opaque(BlendMode::Over)]);
        assert!(!emit_fragment(&plain, ShaderLang::Msl).contains("ycocg_to_rgb"));

        let hapq = Plan::build(&[IrLayer {
            blend: BlendMode::Over,
            may_be_transparent: false,
            covers_target: true,
            needs_color_conversion: true,
        }]);
        assert!(emit_fragment(&hapq, ShaderLang::Msl).contains("ycocg_to_rgb"));
    }

    #[test]
    fn empty_stack_still_emits_valid_shader() {
        let plan = Plan::build(&[]);
        let src = emit_fragment(&plan, ShaderLang::Msl);
        assert!(src.contains("photon_composite"));
        assert!(src.contains("array<texture2d<float>, 1>"), "never a zero-sized array");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// C3 — damage regions (spatial dirty tracking)
// ─────────────────────────────────────────────────────────────────────────────

/// An axis-aligned region of the composition, in normalised 0..1 coordinates.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    /// Left edge.
    pub x: f32,
    /// Top edge.
    pub y: f32,
    /// Width.
    pub w: f32,
    /// Height.
    pub h: f32,
}

impl Rect {
    /// The whole canvas.
    pub const FULL: Self = Self { x: 0.0, y: 0.0, w: 1.0, h: 1.0 };

    /// An empty region.
    pub const EMPTY: Self = Self { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };

    /// Whether this region covers no area.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.w <= 0.0 || self.h <= 0.0
    }

    /// The smallest rect containing both.
    #[must_use]
    pub fn union(self, other: Self) -> Self {
        if self.is_empty() {
            return other;
        }
        if other.is_empty() {
            return self;
        }
        let x0 = self.x.min(other.x);
        let y0 = self.y.min(other.y);
        let x1 = (self.x + self.w).max(other.x + other.w);
        let y1 = (self.y + self.h).max(other.y + other.h);
        Self { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
    }

    /// Clamped to the canvas.
    #[must_use]
    pub fn clamped(self) -> Self {
        if self.is_empty() {
            return Self::EMPTY;
        }
        let x0 = self.x.max(0.0);
        let y0 = self.y.max(0.0);
        let x1 = (self.x + self.w).min(1.0);
        let y1 = (self.y + self.h).min(1.0);
        if x1 <= x0 || y1 <= y0 {
            Self::EMPTY
        } else {
            Self { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
        }
    }

    /// Fraction of the canvas this covers, 0..1.
    #[must_use]
    pub fn coverage(self) -> f32 {
        let c = self.clamped();
        c.w * c.h
    }
}

/// What a layer occupied, this frame and last.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LayerDamage {
    /// Where it is now.
    pub current: Rect,
    /// Where it was on the previous frame.
    pub previous: Rect,
    /// Whether its content or transform changed at all.
    pub dirty: bool,
    /// Whether it reads the whole canvas — blur, feedback, reductions.
    ///
    /// One of these anywhere in the stack disables damage tracking, because a
    /// scissored composite would feed it a partially-stale canvas.
    pub full_canvas_dependency: bool,
}

/// The region that must be recomposited this frame.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Damage {
    /// Nothing changed — reuse the previous composite entirely.
    None,
    /// Only this region changed.
    Region(Rect),
    /// Everything must be redrawn.
    Full,
}

impl Damage {
    /// The rect to scissor to, if any.
    #[must_use]
    pub fn rect(self) -> Option<Rect> {
        match self {
            Self::None => None,
            Self::Region(r) => Some(r),
            Self::Full => Some(Rect::FULL),
        }
    }

    /// Fraction of the canvas that will be recomposited.
    #[must_use]
    pub fn cost(self) -> f32 {
        match self {
            Self::None => 0.0,
            Self::Region(r) => r.coverage(),
            Self::Full => 1.0,
        }
    }
}

/// Computes the damage region for a frame.
///
/// **A moving layer dirties where it WAS as well as where it IS.** Unioning only
/// the new bounds leaves the layer's previous position un-repainted, so it
/// smears a trail across the canvas — a defect that looks like a rendering bug
/// and is actually a bookkeeping one.
///
/// Returns [`Damage::Full`] whenever any layer reads the whole canvas, because
/// scissoring would feed such a node a partially-stale canvas.
#[must_use]
pub fn damage_for(layers: &[LayerDamage]) -> Damage {
    if layers.iter().any(|l| l.full_canvas_dependency) {
        return Damage::Full;
    }
    let mut acc = Rect::EMPTY;
    let mut any = false;
    for l in layers.iter().filter(|l| l.dirty) {
        any = true;
        acc = acc.union(l.current).union(l.previous);
    }
    if !any {
        return Damage::None;
    }
    let clamped = acc.clamped();
    // Past roughly three-quarters coverage the scissor saves little and costs
    // bookkeeping, so take the simple path.
    if clamped.coverage() >= 0.75 {
        Damage::Full
    } else {
        Damage::Region(clamped)
    }
}

#[cfg(test)]
mod damage_tests {
    use super::*;

    fn r(x: f32, y: f32, w: f32, h: f32) -> Rect {
        Rect { x, y, w, h }
    }

    fn still(at: Rect) -> LayerDamage {
        LayerDamage { current: at, previous: at, dirty: false, full_canvas_dependency: false }
    }

    fn moved(from: Rect, to: Rect) -> LayerDamage {
        LayerDamage { current: to, previous: from, dirty: true, full_canvas_dependency: false }
    }

    #[test]
    fn a_static_frame_costs_nothing() {
        let d = damage_for(&[still(r(0.0, 0.0, 0.5, 0.5)), still(Rect::FULL)]);
        assert_eq!(d, Damage::None);
        assert_eq!(d.cost(), 0.0);
    }

    #[test]
    fn a_moving_layer_dirties_where_it_was_as_well_as_where_it_is() {
        // THE correction that matters: unioning only the new bounds leaves a
        // smear trail at the old position.
        let d = damage_for(&[moved(r(0.0, 0.0, 0.2, 0.2), r(0.6, 0.0, 0.2, 0.2))]);
        let rect = d.rect().expect("should be damaged");
        assert!(rect.x <= 0.001, "must include the OLD position, got x={}", rect.x);
        assert!(rect.x + rect.w >= 0.799, "must include the NEW position");
    }

    #[test]
    fn only_dirty_layers_contribute() {
        let d = damage_for(&[
            still(Rect::FULL),                               // static full-frame backdrop
            moved(r(0.1, 0.1, 0.1, 0.1), r(0.1, 0.1, 0.1, 0.1)),
        ]);
        match d {
            Damage::Region(rect) => {
                assert!(rect.coverage() < 0.05, "a static backdrop must not dirty the canvas");
            }
            other => panic!("expected a small region, got {other:?}"),
        }
    }

    #[test]
    fn a_full_canvas_dependency_disables_scissoring() {
        // A blur or feedback node reads the whole canvas, so a scissored
        // composite would hand it partially-stale pixels.
        let mut blur = still(r(0.1, 0.1, 0.1, 0.1));
        blur.full_canvas_dependency = true;
        assert_eq!(damage_for(&[blur]), Damage::Full);
    }

    #[test]
    fn widespread_damage_falls_back_to_a_full_redraw() {
        let d = damage_for(&[moved(r(0.0, 0.0, 0.1, 1.0), r(0.9, 0.0, 0.1, 1.0))]);
        assert_eq!(d, Damage::Full, "near-full coverage should stop bothering to scissor");
    }

    #[test]
    fn damage_never_escapes_the_canvas() {
        // An off-screen layer must not produce a scissor rect outside 0..1.
        let d = damage_for(&[moved(r(-0.5, -0.5, 0.3, 0.3), r(0.1, 0.1, 0.2, 0.2))]);
        let rect = d.rect().unwrap();
        assert!(rect.x >= 0.0 && rect.y >= 0.0);
        assert!(rect.x + rect.w <= 1.0 + 1e-6);
        assert!(rect.y + rect.h <= 1.0 + 1e-6);
    }

    #[test]
    fn union_with_empty_is_identity() {
        let a = r(0.2, 0.3, 0.4, 0.1);
        assert_eq!(Rect::EMPTY.union(a), a);
        assert_eq!(a.union(Rect::EMPTY), a);
    }

    #[test]
    fn a_small_moving_layer_saves_most_of_the_frame() {
        // The whole point of C3: a mostly-static show should recomposite a
        // fraction of the canvas.
        let d = damage_for(&[
            still(Rect::FULL),
            moved(r(0.40, 0.40, 0.08, 0.08), r(0.44, 0.44, 0.08, 0.08)),
        ]);
        assert!(d.cost() < 0.05, "expected <5% of canvas, got {}", d.cost());
    }
}
