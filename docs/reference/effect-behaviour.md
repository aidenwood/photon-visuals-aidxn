# Effect behaviour reference

What Photon's 35 video effects should *do*, what their controls are *called*, what ranges and
neutral points a VJ expects, and what feels wrong if it is missed.

Written for whoever is editing the Metal shader in
`engine/Sources/PhotonRender/EffectChain.swift`. Read the cross-cutting section first — most of
the "this doesn't feel like Resolume" complaints come from there, not from any individual shader.

---

## Sources and how they are weighted

Every claim below is tagged:

| Tag | Meaning |
| --- | --- |
| `[Resolume primary]` | Taken from Resolume Arena itself — either the shipped preset XML (`docs/reference/arena-effects-presets.json`) or the GLSL source and parameter-name tables embedded verbatim in `/Applications/Resolume Arena/Arena.app/Contents/MacOS/Arena` (Arena 7.3, build observed 2026-10-12). This is the actual implementation, not a description of it. |
| `[ISF]` | Interactive Shader Format — the spec (github.com/mrRay/ISF_Spec) and the Vidvox reference shader library (github.com/Vidvox/ISF-Files). Resolume loads ISF natively, so ISF naming is naming a Resolume user has already seen. |
| `[algorithm]` | The standard published algorithm (Sobel, unsharp mask, halftone screening, etc.). |
| `[practitioner, anecdotal]` | A working VJ / shader author's report. Weighted low, labelled every time. |
| `[thin evidence]` | I could not establish this authoritatively. Treat as a suggestion, not a requirement. |

**On the Resolume manual: it is not a usable source for this.** Resolume's own support site states
the manual "is too short to tell what every parameter of every effect does or how it should be
used" and does not enumerate effect parameters. Everything the manual *does* assert about effects
is architectural, not per-effect — quoted in the next section. The binary and the preset XML are
therefore the only primary record of parameter names, defaults and ranges, which is why they
dominate this document.

**Two local primary sources were mined for this doc and are worth re-mining:**

1. `docs/reference/arena-effects-presets.json` — 116 shipped presets over 32 effect families, each
   with exact `ParamRange` names, `default`, `value` and explicit `min`/`max` where non-unit.
2. The Arena binary — the GLSL for most built-in effects is stored as uncompressed string literals,
   followed immediately by that effect's UI parameter-name table. Recover with:
   `strings -n 4 "/Applications/Resolume Arena/Arena.app/Contents/MacOS/Arena" > /tmp/a.txt`
   then grep for a uniform name (`uniform float Twirl;`, `uniform float Posterize;`, …). The effect
   registry — every effect's class name, display name and 4-char type id — sits around line 110,400.

---

## Cross-cutting: the things Resolume does that Photon currently does not

These are the highest-value items in this document. A VJ who has used Arena will notice all five
before they notice any individual shader.

### 1. Dry/wet is a wrapper pass, not a `mix()` inside the shader `[Resolume primary]`

Every Resolume effect preset has this pass structure:

```
passes[0]  type: DryWetEffect   params: Bypassed, Opacity (default 1)
passes[1]  type: <the effect>   params: the effect's own controls
passes[2]  type: <a Mixer>      params: Bypassed, Opacity, Blend Mode
```

And the manual's one architectural statement: *"Video effects always have at least two parameters:
Opacity and Blend Mode. You use these to mix the effect with the original video."* Also:
*"Effects can be stacked together… they will be applied in order, starting with the top one in the
slot"*, and *"changing the effect order can dramatically change the resulting output."*

So in Arena the effect shader produces a **full-strength, fully-replaced** result, and a separate
wrapper blends it against the input at `Opacity` with a chosen `Blend Mode`. Resolume's Edge
Detection shader, for example, outputs *only* the edges — compositing it over the source is the
wrapper's job.

Photon collapses this: `amount` is simultaneously the effect's strength knob *and* its only wet/dry
control, and most shaders do their own internal `mix(c.rgb, effect, a)`. Consequences:

- Effects whose real primary control is not an intensity (chroma key's **key hue**, kaleidoscope's
  **segment count**, posterize's **step size**, mirror's **axis**) have to steal `amount`, so they
  have no dry/wet at all.
- Effects where `amount` *is* the intensity cannot be faded in independently of their look.
- The chain has no blend mode, so "add this glow over the source" is not expressible.

**Recommendation:** add a per-effect `opacity` (0…1, default 1) and `blendMode` at the chain level,
and let each shader return its result at full strength. That single change makes roughly a third of
the per-effect notes below moot.

### 2. Time-based effects share one transport block `[Resolume primary]`

Every animating Resolume effect — Wave Warp, Kaleidoscope, Mirror, Slide, Shift RGB, Ripples,
Stripper, Tunnel, VideoWall, Cube Tiles, Iterate, Radial/Linear Cloner, Particle System, Distortion
— carries the identical parameter group, with identical defaults and ranges:

| Parameter | Kind | Default | Range |
| --- | --- | --- | --- |
| `Speed` | ParamRange | 1 | 0…10 |
| `BPM` | ParamRange | 120 | 20…500 |
| `Beats` | ParamRange | 4 | 0.0078125…1048576 |
| `Syncmode` | ParamChoice | 0 | — |
| `PlayDirection` | ParamChoice | 1 | — |
| `PlayMode` / `PlayModeAway` | ParamChoice | 0 | — |
| `DurationIsScalable` | Param (bool) | 1 | — |

`Beats` ranging down to 1/128 and up to 2^20 is the giveaway: Resolume expects every animated effect
to be locked to the composition clock at any subdivision. Photon beat-locks exactly one effect
(strobe, via `u.beat`) and free-runs `wave` and `noise` off wall-clock `u.time`. **A VJ will read a
free-running wave as broken**, because in Arena it is beat-locked by default. Wave and noise should
take the same `beat`/`beats` input strobe does.

### 3. Colour effects unpremultiply, operate, re-premultiply, and clamp to alpha `[Resolume primary]`

Near-universal in Resolume's colour shaders:

```glsl
vec4 color = texture( Texture1, uv1 );
if( color.a > 0.0 ) color.rgb /= color.a;      // unpremultiply
...                                             // the actual operation
color.rgb = clamp( color.rgb * color.a, vec3(0.0), vec3(color.a) );   // premultiply + clamp
```

Photon's colour cases ignore alpha entirely and pass `c.a` through. On opaque content this is
identical; on keyed content, or downstream of `lumaKey`/`chromaKey`, it is not — edges will fringe
and brightness operations will lift the matte. If the engine composites premultiplied, adopt the
same unpremul/premul bracket.

### 4. Resolume's luma is Rec.601, Photon's is Rec.709 `[Resolume primary]`

Resolume's shaders repeatedly declare `const vec3 grayScaleWeights = vec3(0.30, 0.59, 0.11)` —
Rec.601 — and use it for Saturation, Tint, Threshold-style decisions, Polkadot dot sizing and the
Sphere/Stingy luminance reads. Photon uses `luma709`. Visible difference is small but systematic:
601 weights green lower and red higher, so reds come out brighter under 601. Low priority, but if
the goal is "matches Arena", match the weights.

### 5. Linear light vs gamma — which effects are conceptually perceptual

The engine composites in `rgba16Float` **linear** light. Resolume's effects were written against
8-bit, sRGB/Rec.709-*encoded* values where 0.5 means mid-grey. In linear light mid-grey is ~0.2158,
not 0.5. Any operation whose maths references a midpoint, a step spacing, a perceptual luma, or an
inversion is therefore **wrong if applied naively in linear**, and will look crushed, blown or
weirdly spaced.

**Must encode to a perceptual space (sRGB transfer or at minimum `pow(1/2.2)`), operate, and decode:**

| Effect | Why |
| --- | --- |
| `levels` | Contrast pivots on 0.5; gamma on linear data double-applies a transfer. Worst offender. |
| `invert` | `1.0 - x` is a gamma-space idea. In linear, inverting a mid-grey gives a near-white, not a mid-grey. |
| `saturation` | Luma coefficients are defined on gamma-encoded RGB. Linear desaturation reads as a darkening. |
| `hueRotate` | HSV/HSL are models over gamma-encoded RGB. Hue angles shift if fed linear. |
| `colorize` | Tint strength comes from perceptual luma. |
| `duotone` | The ramp position between the two colours is a perceptual luma. |
| `threshold` | The cut point is a perceptual brightness. A 0.5 cut in linear sits far too bright. |
| `posterize` | Band spacing must be perceptually even or all the banding piles into the highlights. |
| `solarize` | Folds about mid-grey. |
| `temperature` | Channel gains model a white-point shift on display-referred values. |
| `halftone` | Dot area is a function of perceptual luma (see that section — `sqrt(l)` is already an area correction). |
| `edgeDetect`, `emboss` | Gradient magnitude on linear luma loses all shadow detail; edges in dark areas vanish. |
| `sharpen` | Unsharp amount is a perceptual contrast. |
| `scanlines` | Scanline depth reads as a perceptual darkening. |
| `noise` | Grain visibility is perceptually uniform, not linearly uniform. |
| `lumaKey` | The cut point is a perceptual brightness. |
| `chromaKey` | RGB→HSV on linear data yields wrong hue/sat/value; tolerance becomes unusable. |

**Correct, and in fact better, in linear — leave alone:**
`exposure` (a true scene-referred gain; `exp2()` on linear is exactly right), `blur`, `glow`/bloom
(the bright-pass and additive recombination are physically meaningful in linear), `vignette`
(multiplicative falloff), `pixelate` if it averages, `strobe` (a gate), and every geometric
distort — `kaleidoscope`, `mirror`, `twirl`, `fisheye`, `wave`, `tile`, `slide`, `polar`, `zoom`,
`rgbShift`, `chromaticAberration` — which only move samples.

A shared `toPerceptual()` / `toLinear()` pair bracketing the colour and key cases is the whole fix.

### 6. Five effects advertise a second knob that the shader ignores

Cross-checking `paramLabel` against the shader body, these pass `p` into nothing:

| Effect | `paramLabel` claims | Shader actually uses |
| --- | --- | --- |
| `blur` | "Threshold" | `a` only — `gauss25(..., a * 8.0)` |
| `tile` | "Offset" | `a` only — tile count |
| `polar` | "Direction" | `a` only — mix amount |
| `vignette` | "Softness" | `a` only — inner radius |
| `noise` | "Grain" | `a` only — mix amount |

Each is a labelled knob that does nothing when turned. Fix the shader or drop the label — a dead
knob is worse than no knob.

---

# Colour (11)

## levels

**What it does.** Remaps the tonal range: lifts or crushes blacks, pulls the midpoint, stretches or
compresses the span between dark and light. The workhorse "make it pop" / "make it murky" control.

**Resolume** `[Resolume primary]` — effect `Levels` (type id `A141`). Three controls:
`Base`, `Midpoint`, `Ratio`. Resolume's own description: *"Levels affects the dark and bright parts
of your content. The Base sets the darkest point, the Midpoint shifts the balance between shadows
and highlights, and the Ratio controls how stretched or compressed the range between dark and light
areas becomes."* The implementation is a three-term curve on unpremultiplied RGB:

```glsl
color.rgb = vec3(Base) + pow(color.rgb, vec3(MidPoint)) * vec3(Ratio);
```

So `Midpoint` is literally a gamma exponent, `Ratio` a gain and `Base` a lift. Identity is
`Base = 0, Midpoint = 1, Ratio = 1`.

**ISF** `[ISF]` — `Color Levels.fs` names them `Minimum Point` (0.2), `Mid Point` (0.5),
`Maximum Point` (0.8), all 0…1.

**Photon today.** `amount` = contrast about 0.5 (`(c-0.5)*(1+a*3)+0.5`), `param` = gamma
`mix(0.4, 2.5, p)`. `paramLabel` = "Gamma".

**Naming verdict.** "Gamma" is correct and is the industry term (it is also what the maths does).
Resolume calls the same knob "Midpoint". Either is defensible; "Gamma" is clearer to a shader
author, "Midpoint" to a Resolume refugee. **No change required, but note Photon is missing the lift
("Base") entirely**, which is the control VJs use to haze blacks for projection.

**Neutral point.** `amount = 0` (no contrast change) and `param = 0.3611` (the value where
`mix(0.4, 2.5, p) == 1.0`). That second number is not a round slider position, which means
**levels has no reachable identity on a 0…1 knob at a detent**. Remap so `param = 0.5` is gamma 1.0.

**Would feel wrong if missed.** Pivoting contrast anywhere other than mid-grey; and in linear light
0.5 is not mid-grey — this is the single most gamma-sensitive effect in the set.

## invert

**What it does.** `1 - x` per channel. Expected to be instant, total, and free.

**Resolume** `[Resolume primary]` — effect `Invert RGB` (`A105`). Three `ParamRange` controls,
`R`, `G`, `B`, each defaulting to **1** (fully inverted). So Resolume's invert is *per channel and
continuous* — pulling only `R` down gives a cyan-shifted partial invert, which is a staple look.
Preset `Invert RGB/…` ships with all three at 1.

**ISF** `[ISF]` — `Color Invert.fs` has no parameters at all; `RGB Invert.fs` gates per channel.

**Photon today.** Single `amount` mix. No `paramLabel`.

**Verdict.** Photon's reduction is fine for a two-knob UI, but **per-channel invert is the one thing
VJs actually do with this effect** and it is unreachable. If a third control ever exists, this is
where it goes. Candidate for `paramLabel = "Channels"` with a 3-way enum (RGB / R / G / B).

**Neutral point.** `amount = 0`. Correct today.

**Gamma.** Perceptual — see cross-cutting §5. `1 - x` in linear light produces a visibly different
(much brighter) inverse than the one everyone expects.

## saturation

**What it does.** Scales colour away from or towards grey.

**Resolume** `[Resolume primary]` — effect `Saturation` (`A110`), one control, `Saturation`,
identity at **1.0**, 0 = greyscale, 2 = "lots of colour". The implementation has a deliberate
non-linearity above 1 (comment in the Arena source is verbatim *"get some crazy saturation going so
we don't need a lot of range on the slider… power to the power, by the castle of grayskull!"*):

```glsl
float sat = Saturation;
if( Saturation > 1.0 ) sat = pow( Saturation, pow( Saturation, Saturation ) );
vec3 outCol = (color.rgb - averageColor) * sat + averageColor;
```

That means the top half of the slider ramps *very* fast — at `Saturation = 2` the effective factor
is 2^4 = 16. Copying this curve is what makes a saturation knob feel like Arena's.

**ISF** `[ISF]` — `Color Controls.fs`: `saturation` 0…4, default 1.

**Photon today.** `mix(luma, rgb, a * 2.0)` — identity at 0.5, 0 = grey, 1 = 2×. Linear throughout.

**Verdict.** Mapping and neutral point (0.5) are right. **Missing the superlinear top half** — add
the `pow(S, pow(S, S))` ramp above the identity detent and it will feel correct.

**Gamma.** Perceptual. Both the grey reference and the perceived strength are gamma-space notions.

## hueRotate

**What it does.** Rotates every hue around the wheel; the classic rainbow-cycle knob.

**Resolume** `[Resolume primary]` — effect `Hue Rotate` (`A128`). Three controls, named exactly:
**`Hue Scale`**, **`Hue Rotate`**, **`Sat. Scale`**. It works in HSL, not HSV:

```glsl
vec3 hsl = RGBToHSL( color.rgb );
hsl.r *= HueScale;                  // multiply hue  (hue remap / posterised rainbow)
hsl.r = fract( hsl.r + HueRot );    // then rotate
hsl.g = clamp( hsl.g * SatScale, 0.0, 1.0 );
```

`Hue Scale` multiplying hue before the rotation is unusual and produces the splayed, channel-
separated rainbows people associate with this effect in Arena. Unpremultiplied, re-premultiplied.

**Photon today.** `param` = rotation angle (`p * TAU`), `amount` = dry/wet mix. `paramLabel` = "Hue".

**Naming mismatch.** Resolume calls the rotation knob **"Hue Rotate"**, not "Hue". `"Hue"` reads as
"pick a hue" (which is what `colorize` does), so the same label currently means two different things
across two effects. **Rename `hueRotate`'s param label to "Rotate" or "Hue Rotate".**

**Neutral point.** `param = 0` *or* `param = 1` (full turn) — both identity, which is correct and
desirable: a VJ wants to spin this knob continuously and it should wrap.

**Would feel wrong if missed.** Wrapping. If the knob clamps at 1.0 instead of wrapping to 0, the
rainbow cycle stalls — and a stalled hue cycle is the single most noticeable VJ-knob failure.

**Gamma.** Perceptual — HSV/HSL are defined over gamma-encoded RGB.

## colorize

**What it does.** Throws away the source's colour and re-tints it from its own luminance — one
colour, or a palette.

**Resolume** `[Resolume primary]` — effect `Colorize` (`A103`), and it is far richer than a hue
knob. Preset-confirmed controls, with defaults:

| Name | Kind | Default |
| --- | --- | --- |
| `Color` | ParamColor | red (`4278190335`) |
| `Red` / `Green` / `Blue` / `Alpha` | ParamRange 0…1 | 1 / 0 / 0 / 1 |
| `Hue` / `Saturation` / `Brightness` | ParamRange 0…1 | 0 / 1 / 1 |
| `Colors` | ParamChoice (palette) | — |
| `Mode` | ParamChoice | 0 |
| `Weighted` | bool | 1 |
| `GreysKeep` | bool | 0 |
| `GreysTolerance` | ParamRange 0…1 | 0.3 |
| `Contrast` | ParamRange 0…1 | 0.2 |
| `Invert` | bool | 0 |

Resolume's description: *"Applies a color filter to the content which is either a single color or
based on a palette."* `GreysKeep` + `GreysTolerance` — leave near-neutral pixels untinted — is the
control that makes colorize usable on footage with white text or logos, and is the one most likely
to be missed.

**ISF** `[ISF]` — `Color Monochrome.fs`: `color` (RGBA) + `intensity` 0…1 default 1.

**Photon today.** `param` = hue (`hsv2rgb(p,1,1) * luma`), `amount` = mix. `paramLabel` = "Hue".

**Verdict.** "Hue" is the right label for a one-knob reduction; keep it. But note the reduction
pins saturation and value at 1.0, so **Photon's colorize cannot produce a pastel or a dark tint** —
every colorize is a fully saturated neon. If a third control appears, make it `Saturation`.

**Neutral point.** `amount = 0`.

**Gamma.** Perceptual.

## duotone

**What it does.** Maps the luminance ramp between two colours — shadows become colour A, highlights
colour B. The Spotify-poster look.

**Resolume** `[Resolume primary]` — the effect is called **`Tint`** (`A179`), not Duotone, described
as *"Creates tint filter"*. Two colour pickers, named **`Black To`** and **`White To`**:

```glsl
float luminance = dot( color.rgb, vec3(0.30,0.59,0.11) );
vec3 whiteTint = mix( color.rgb, RGBWhite.rgb, RGBWhite.a );
vec3 blackTint = mix( color.rgb, RGBBlack.rgb, RGBBlack.a );
fragColor0.rgb = mix( blackTint, whiteTint, luminance ) * color.a;
```

Two details worth stealing: **each end's tint strength is the alpha of its own colour** (so you can
tint only the shadows and leave highlights alone), and the tint is a `mix` *towards* the colour from
the original pixel, not a replacement — so saturated source colour survives at low tint strength.
Photon's version replaces outright.

**ISF** `[ISF]` — `Duotone.fs`: `darkColor`, `brightColor`, plus `threshold` (0.5) and `softness`
(0…1) which control where the ramp sits and how hard it is. Those two are genuinely useful and
neither Resolume nor Photon has them.

**Photon today.** `param` = a hue, from which it derives two *complementary* colours
(`p` and `fract(p+0.5)`) at fixed S/V. `paramLabel` = "Hue".

**Verdict.** Auto-complementary is a defensible one-knob reduction — but it means **the two most
requested duotones (black→colour, and colour→white) are both unreachable**, because the dark end is
always a saturated hue at value 0.25. Consider making the dark end desaturate towards black as
`param` approaches 0.

**Neutral point.** `amount = 0`.

**Gamma.** Perceptual (the ramp position is a perceptual luma).

## threshold

**What it does.** Hard two-tone cut at a brightness level. Instant high-contrast stencil.

**Resolume** `[Resolume primary]` — effect `Threshold` (`A106`), registry description *"Color
threshold"*. No preset ships for it and its GLSL was not recoverable from the string table, so
**`[thin evidence]` on its exact parameter names.** The registry entry confirms it is a *colour*
threshold (per-channel), not a luma threshold — which, if right, means Resolume's Threshold produces
8-colour output (each channel independently cut), not black-and-white. Photon's is luma-based and
therefore monochrome. Worth testing in Arena before matching.

**Photon today.** `amount` **is** the cut point; output is pure black/white. No `param`.

**Serious problem — no identity.** Because `amount` is the cut point, `amount = 0` gives
`step(0, luma) == 1` → **the entire frame goes white**. There is no setting of the only knob that
leaves the image alone, and the knob that a VJ reaches for to fade an effect in instead blows the
output to white. In Arena this is a non-issue because the dry/wet wrapper is a separate control
(cross-cutting §1). Until that exists, either:
- move the cut point to `param` and make `amount` a mix (so `amount = 0` is identity), or
- accept it and document that threshold must be dropped in at a non-zero amount.

**Expected extra controls** `[ISF]`/`[algorithm]` — a **softness/feather** around the cut is standard
and is what stops the output crawling with aliasing on moving footage. `smoothstep(t - s, t + s, l)`.
A hard `step()` on video aliases badly.

**Gamma.** Perceptual — the cut point is meaningless in linear.

## posterize

**What it does.** Quantises each channel to a small number of levels. Banding, on purpose.

**Resolume** `[Resolume primary]` — effect `Posterize` (`A109`), one control also named
`Posterize`, and critically it is a **step size, not a level count**:

```glsl
if (Posterize > 0.0)
    color.rgb = floor( color.rgb / vec3( Posterize ) ) * vec3( Posterize );
```

Identity at **0** (guarded). Turning the knob *up* makes steps bigger, so *fewer* levels.

**ISF** `[ISF]` — the opposite convention: `Posterize.fs` has `numColors` 3…32 (default 6) plus a
`gamma` 0.5…2; `Luminance Posterize.fs` has `levels` 2…30. ISF counts levels, Resolume sizes steps.

**Photon today.** `param` sets a count via `floor(mix(2.0, 16.0, 1.0 - p))` — so `param = 0` gives
16 levels and `param = 1` gives 2. `paramLabel` = **"Levels"**.

**Naming mismatch — flag this one.** The label says "Levels" but the knob is wired so that turning
it up *reduces* levels. Either rename it to "Step" / "Posterize" (matching Resolume's semantics,
which is what the current wiring actually implements) or drop the `1.0 - p` so "Levels" counts up.
As shipped, the label is actively misleading.

**Neutral point.** `amount = 0` is identity (the mix). `param` has no identity — worth adding
Resolume's `> 0` guard so the bottom of the knob is a clean bypass.

**Gamma.** Perceptual, strongly. In linear light, evenly spaced steps put almost every band in the
highlights and leave the shadows as one flat block.

## solarize

**What it does.** Inverts only the tones above a pivot — the Sabattier effect. Metallic, X-ray look.

**Resolume** — **no Resolume equivalent exists.** Not in the effect registry (closest relatives are
`Invert RGB` and `Threshold`). `[Resolume primary]`, by absence.

**ISF** `[ISF]` — `Solarize.fs` is the reference, and it has three controls worth copying:
`centerBrightness` 0…1 default **0.5** (where the fold happens), `powerCurve` 0…4 default **1.0**
(how sharp the fold is — 1.0 is a hard crease, higher values round it), and `colorize` 0…1 default 0.
Plus an `inverse` bool. The `powerCurve` is what separates a cheap solarize from a good one; a hard
`x > 0.5` crease aliases on gradients.

**Photon today.** `select(c, 1-c, c > 0.5)` per channel, hard crease at a fixed 0.5, `amount` = mix.
No `param`.

**Verdict.** The free `param` slot should be the **fold point** (ISF's `centerBrightness`), or
failing that the `powerCurve`. A fixed pivot makes solarize a one-look effect.

**Gamma.** Perceptual — the pivot is a perceptual mid.

## exposure

**What it does.** Scene-referred brightness gain, in stops.

**Resolume** `[Resolume primary]` — effect `Exposure` (`A134`), one control `Exposure`, described as
*"Controls how bright or dark your content looks, like adjusting the light settings on a camera."*
The curve is unusual:

```glsl
const float sqrtoftwo = 1.41421356237;
fragColor0.rgb = log2( vec3( pow( Exposure + sqrtoftwo, 2.0 ) ) ) * color.rgb;
```

i.e. `gain = 2 * log2(Exposure + √2)`. At `Exposure = 0` the gain is exactly **1.0** — identity sits
at the bottom of the slider, and the response is logarithmic, so the knob is gentle at the top. The
slider range is not stated in any shipped preset: `[thin evidence]` on the max.

**ISF** `[ISF]` — `Exposure Adjust.fs`: `inputEV` −10…+10, default 0.5. EV stops, the standard.

**Photon today.** `exp2(mix(-3.0, 3.0, a))` — ±3 stops, identity at `amount = 0.5`. No `param`.

**Verdict.** Photon's is the better design (symmetric, identity at centre detent, true stops) and
should be kept. `exp2()` on linear light is exactly correct — **this is the one colour effect that
is more right in linear than it would be in gamma.** Do not gamma-bracket it.

**Would feel wrong if missed.** Clipping. In `rgba16Float` nothing clips at the effect, so +3 stops
produces values far above 1.0 that only blow out at display. That is correct behaviour and feeds
`glow` properly — do not clamp it.

## temperature

**What it does.** Warm/cool white-balance shift, with a green/magenta tint axis.

**Resolume** — **no Resolume equivalent.** `Tint` is a duotone, not a white balance; the closest
primitives are `Colorize` and `Bright.Contrast`. `[Resolume primary]`, by absence.

**ISF** `[ISF]` — `White Point Adjust.fs` is the nearest: a single colour multiplied into the pixel
("*Modifies the white point by multiplying the src pixel by the color value*"). That is the
physically honest formulation.

**Photon today.** `amount` = warm/cool (`R × (1+t·0.4)`, `B × (1−t·0.4)`), `param` = green/magenta
(`G × (1+g·0.2)`). `paramLabel` = **"Tint"**.

**Naming verdict — this one is right.** "Temperature + Tint" is the universal convention across
Lightroom, Resolve, Premiere and every camera menu. Keep it. Both knobs are identity at **0.5**,
which is correct and should be a UI detent.

**Would feel wrong if missed.** Nothing major. The one refinement worth having: real white-balance
preserves luminance, so a strong warm shift should not also brighten the frame. Normalising by the
luma of the gain vector costs two lines and makes the knob feel professional rather than like a
colour-channel multiplier.

**Gamma.** Perceptual — channel gains model a display-referred white point.

---

# Stylise (7)

## blur

**What it does.** Gaussian softening.

**Resolume** `[Resolume primary]` — effect `Blur` (`A140`, *"Blurs the image"*), plus `HV Blur`,
`Pixel Blur`, `Soft Blur` and `RadialBlur`. The HV Blur implementation is a **separable two-pass**
blur driven by a Gaussian **lookup texture**, with controls named:

| Name | Role |
| --- | --- |
| `Blur X Distance` | horizontal radius |
| `Blur Y Distance` | vertical radius |
| `Quality` | the `Steps` loop count — number of taps |
| `Gaussian` | the row of the LUT, i.e. the shape of the falloff |

Separating X and Y as two controls matters: directional/motion blur is a staple and is free once
they are separate. `RadialBlur` is a distinct effect with `Steps` (0.3), `Distance` (0.1),
`Rotation` (0.5), `High Quality` (bool).

**ISF** `[ISF]` — `Fast Blur.fs`: `blurAmount` 0…12. `Multi Pass Gaussian Blur.fs`: 0…24.

**Photon today.** A single-pass fixed **5×5** kernel with weights `exp(-d² · 0.3)`, sample spacing
scaled by `a * 8.0`. `paramLabel` = "Threshold", and **`param` is never read** (see cross-cutting §6).

**Two real bugs here.**

1. **The kernel does not widen, the taps just spread apart.** Sigma is baked into the weights at a
   fixed ~1.3 texels while the sample *positions* move out to ±16 texels at `amount = 1`. Past about
   `a = 0.25` this stops being a blur and becomes a 25-tap ghosting/ringing filter — the classic
   "why does my blur have a grid in it" artefact. Fix by making it separable (two passes of N taps)
   or by scaling the weight falloff with the radius so the kernel stays a Gaussian.
2. **Dead `param`.** Either wire it to a second axis (an X/Y aspect, matching Resolume's split) or
   drop the label. "Threshold" on a blur is meaningless in any case — it is almost certainly a
   copy-paste of `glow`'s label.

**Neutral point.** `amount = 0`. Correct.

**Gamma.** Blur in **linear is correct** and is one of the few places where Photon's float pipeline
is strictly better than Arena's. Leave it in linear.

## sharpen

**What it does.** Unsharp mask — adds back the difference between the image and a blurred copy.

**Resolume** `[Resolume primary]` — effect `Sharpen` exists (no 4-char id, so it is one of the newer
Vulkan effects; its shader is not in the GLSL string table). Resolume's own description:
*"Sharpen enhances the edges and fine details in an image… It works by increasing contrast around
edges, which helps textures stand out."* No parameter names recoverable — `[thin evidence]` on its
controls.

**ISF** `[ISF]` — `Sharpen Luminance.fs`: `intensity` 0…2, default 1 (sharpens luma only, leaving
chroma alone — this avoids the colour-fringing that RGB sharpening causes).
`Sharpen RGB.fs`: `intensityR/G/B` each 0…10, default 1.

**Algorithm** `[algorithm]` — canonical unsharp mask has **three** parameters: *Amount* (how much of
the difference to add), *Radius* (the blur sigma), and *Threshold* (minimum local contrast before
sharpening applies, which is what stops it amplifying sensor noise in flat areas).

**Photon today.** `amount` = strength (`×3`), `param` = blur radius `mix(1.0, 4.0, p)` reusing
`gauss25`. `paramLabel` = **"Radius"**.

**Naming verdict — correct.** "Radius" is the right second control for an unsharp mask and matches
the canonical algorithm. Keep it.

**Would feel wrong if missed.** Two things: (a) sharpening **chroma** as well as luma produces
coloured halos on every edge — ISF's choice to sharpen luminance only is the better default for
video; (b) no output clamp means halos go negative and read as black rims. Clamp the low side.

**Gamma.** Perceptual (the "amount" is a perceptual contrast boost).

## edgeDetect

**What it does.** Outlines. Sobel/Laplacian gradient magnitude.

**Resolume** `[Resolume primary]` — effect `Edge Detection` (`MEDG`), and there are **two kernels in
the binary with a mode switch between them**, with the kernels written out as comments in Resolume's
own source:

```glsl
//    -1 -2 -1       1 0 -1          //   -1 -1 -1
// H = 0  0  0   V = 2 0 -2          //   -1  8 -1     (Laplace)
//     1  2  1       1 0 -1          //   -1 -1 -1
```

Controls, recovered from the string table: a mode choice **`Sobel` / `Laplace`**, plus
**`Multiplier`** (`Mult`, applied to each sample *before* the kernel), **`Power`** (Sobel only),
**`Use Color`** (bool), **`Color`**, and **`Color Mix`**. A separate `Edge Detect` effect runs on
luma with `treshold` [sic], `edgeColor` and a `smoothIt` flag that squares the gradient *"to conceal
noise in the video"* — a cheap, effective trick worth stealing.

Critically: **Resolume's edge detect replaces the image with the edges.** Compositing over the
source is the wrapper's job (cross-cutting §1).

**ISF** `[ISF]` — `Edges.fs`: `intensity` 0…50 (default 50), `threshold` 0…1 (default 0),
`sobel` bool (Sobel vs Laplace — same two-kernel choice), `opaque` bool.

**Photon today.** Sobel magnitude on `luma709`, `param` = sample spacing `mix(1.0, 4.0, p)`,
`amount` = mix with source. `paramLabel` = **"Radius"**.

**Naming mismatch — flag.** Neither Resolume nor ISF exposes a radius here; both expose an
**intensity/multiplier** and both expose a **kernel choice**. A VJ turning "Radius" up on an edge
detect gets thicker, hollower, lower-fidelity edges — not what they want. **The highest-value second
knob is `Multiplier`/`Intensity` (gradient gain); the second-highest is the Sobel↔Laplace toggle.**
Recommend relabelling to "Intensity" and scaling `e` rather than the tap spacing.

**Would feel wrong if missed.** Noise. Raw Sobel on compressed video is a snowstorm. Both Resolume
paths address this (the `smoothIt` squaring, and the `step(threshold, edge) * edge` gate). Photon
has neither — add the threshold gate, it is one line and it is the difference between usable and not.

**Gamma.** Perceptual — gradients on linear luma lose all shadow detail.

## emboss

**What it does.** Directional difference plus mid-grey — a fake relief/bevel.

**Resolume** — **no Resolume equivalent.** Not in the registry. `[Resolume primary]`, by absence.
(`Hatched`, `Kuwahara` and `Dilate` are the nearby stylisers.)

**ISF** `[ISF]` — `Emboss.fs`: `intensity` 0…10 default **2.0**, `colorize` 0…1 default **1.0**
(blend between a grey relief and a colour-preserving one), `brightness` 0.25…0.75 default **0.5**
(the grey the flat areas sit at). All three are good controls; `brightness` in particular lets the
relief sit on a light or dark card.

**Algorithm** `[algorithm]` — a true emboss has a **direction** (which diagonal the light comes
from). Photon hard-codes the `-texel` / `+texel` diagonal, so the light is permanently top-left.

**Photon today.** `param` = sample spacing `mix(1.0, 4.0, p)`, `amount` = mix. `paramLabel` =
"Radius".

**Verdict.** "Radius" is at least honest here (the spacing really is the depth of the relief), but
**light direction is the control people actually reach for**, and it is free: replace the fixed
diagonal with `float2(cos(θ), sin(θ))`. If one knob has to serve, make it the angle and fix the
radius at 1–2 texels.

**Gamma.** Perceptual.

## glow

**What it does.** Bright parts bleed light into their surroundings.

**Resolume** `[Resolume primary]` — effect `Bloom`. Resolume's description: *"Makes the bright parts
of an image glow and spread light around. Great for neon effects, glowing bits or hazy looks. GPU
Intensive!"* Its bright-pass is:

```glsl
float luminance = perceivedLuminance( texColor.rgb );
float filteringAmount = smoothstep(Threshold - Knee, Threshold, luminance);
fragColor0 = mix(vec4(0), texColor, filteringAmount);
```

then a blur chain, then `clamp(input.rgb + bloom.rgb * Amount, 0, maxAlpha)`. Controls:
**`Threshold`**, **`Knee`**, **`Amount`**, **`Iterations`**, **`Width`**, **`Height`**.

`Knee` is the one Photon is missing and the one that matters: a hard `max(b - p, 0)` bright-pass
makes the glow *pop in* as a hard-edged blob the instant a pixel crosses the threshold. The
`smoothstep(T - Knee, T)` soft knee is why Arena's bloom eases in.

Note also: Resolume's bright-pass reads **perceived luminance**, not per-channel. Photon's
`max(b.rgb - p, 0.0)` is per-channel, which tints the glow toward whichever channel is brightest.
That is arguably a nicer look for VJ work — worth keeping deliberately rather than by accident.

**ISF** `[ISF]` — `Glow-Fast.fs`: `intensity` 0…1 and `blurAmount` 0…12.

**Photon today.** `amount` = add strength (`×2`), `param` = bright-pass threshold, blur radius fixed
at 6. `paramLabel` = **"Threshold"**.

**Naming verdict — correct**, matches Resolume exactly.

**Would feel wrong if missed.** The soft knee (above), and **the blur radius being fixed**. Glow
radius is the difference between "neon" and "haze" and there is no way to reach it. If a third
control appears, radius beats everything else.

**Gamma.** Linear is **correct** here — a bright-pass and an additive recombination in linear light
is physically what glare does. This is the second effect (with exposure) that Photon's float
pipeline gets more right than Arena. Do not gamma-bracket it.

## halftone

**What it does.** Reproduces the image as a grid of dots whose size tracks local brightness. Print
/ comic-book look.

**Resolume** `[Resolume primary]` — three related effects: **`Polkadot`** (`A181`, *"Polka like you
mean it"*), **`Dot Screen`** (`A176`) and **`Hatched`**. Polkadot's GLSL is recoverable and is the
closest match to Photon's:

```glsl
float radiusx = Radius;  float radiusy = Radius / Aspect;
// snap to the cell centre, offsetting every other column by half a cell for a mesh look
if (mod(floor((coord.x - Center.x)/radiusx), 2.0) == 0.0) coord.y += radiusy/2.0;
vec4 col = texture(Texture1, xy*MaxCoords);
float brt = (0.299*col.r + 0.587*col.g + 0.114*col.b);
float r = Radius * 0.5 * brt;
float v = 1.0 - pow(dist/r, r*1000.0);      // "dani's magic soft circle trick"
```

Controls: **`Radius`**, **`Threshold`**, **`Aspect`**, **`Center`**.

Three things Resolume does that Photon does not:
1. **Aspect correction** — the dot grid is scaled by aspect *after* sampling so the picture is not
   distorted but the dots stay circular. Photon's `uv * resolution / cell` keeps dots round by
   working in pixels, which achieves the same thing. Fine.
2. **Staggered rows** (every other column offset by half a cell) — the hexagonal packing that makes
   a dot screen look like a dot screen rather than a grid of pixels.
3. **A soft, anti-aliased dot edge** via that exponential falloff. Photon's `step(length(f), …)` is
   a hard circle and **will crawl and alias on every frame of moving video.** This is the most
   visible defect in the current halftone.

**Algorithm** `[algorithm]` — classic halftone screening rotates the screen to avoid interference
with the image's own structure; **45° is the standard angle for a single-colour (black) screen**,
with 15°/75°/0° used for the other inks in CMYK. Dot *area* is proportional to tone, so dot *radius*
goes as `sqrt(tone)` — Photon's `sqrt(l) * 0.7` is already correct and worth not breaking.

**ISF** `[ISF]` — `CMYK Halftone.fs`: `gridSize` 1…256 default **45**, `smoothing` 0…1 default 0.15.
(`smoothing` is the anti-aliasing of the dot edge — again, everyone has this.)

**Photon today.** `param` = cell size `mix(4.0, 40.0, p)` px, screen angle hard-coded at **0.4 rad
(≈23°)**, `amount` = mix. `paramLabel` = **"Dot Size"**.

**Naming verdict.** "Dot Size" is clear and acceptable; Resolume says "Radius", ISF says "gridSize".
No change needed.

**Three fixes, in priority order.** (1) Soften the dot edge — `smoothstep` over roughly one pixel,
or it crawls. (2) Change the screen angle to 45° unless there is a reason for 23°. (3) Stagger
alternate rows.

**Gamma.** Perceptual — dot area tracks *perceived* tone, and `sqrt()` on linear values is not that.

## pixelate

**What it does.** Mosaic. Big chunky blocks.

**Resolume** `[Resolume primary]` — effect **`LoRez`** (`A142`, *"Creates low res version of image"*),
and this is the one VJs actually use. It bundles three things:

| Name | Default | Role |
| --- | --- | --- |
| `Pixel Size` | 0 | `PixelNum` — the grid count; 0 = bypass |
| `Bit Reduction` | 0 | quantises colour depth (`ceil(c/B)*B`) |
| `Dither` | 0 | adds noise before quantising, to break up the banding |

The combination — chunky pixels *plus* a crushed palette *plus* dither — is the "lo-fi/vintage"
preset. Photon splits these across `pixelate` and `posterize` with no dither anywhere; that is a
reasonable decomposition, but **Resolume's LoRez samples the cell centre** (`base += gridSize*0.5`)
exactly as Photon does, so the core behaviour matches.

**ISF** `[ISF]` — `Pixellate.fs`: `cell_size` 0.001…0.5 default 0.125, plus a `shape` enum
(Square / Rectangle).

**Photon today.** `amount` = `mix(resolution.x, 8.0, a)` cells across. No `param`, no `paramLabel`.

**Verdict on the mapping.** `amount = 0` gives one cell per pixel = identity, which is correct. But
the response is **linear in cell count against a range of ~1920 to 8**, so the entire useful range
of the effect (say 8 to 200 cells) is crammed into the top 10% of the knob and 90% of the travel does
nothing visible. **Make it logarithmic** — this is the single most noticeable "feels cheap" issue in
the distort/stylise group, and a VJ will hit it within ten seconds.

**Free `param` slot.** Best candidates, in order: aspect/`shape` (ISF), or Resolume's `Bit Reduction`.

**Would feel wrong if missed.** Cell-centre sampling (already correct) and **averaging vs point
sampling.** Photon point-samples the centre texel, so pixelating noisy footage produces a flickering
mosaic. Resolume does the same, so this matches Arena — but averaging the cell looks better and is
free in linear light.

**Gamma.** Point sampling is colour-space agnostic. If you switch to averaging, averaging in linear
is the correct choice.

---

# Distort (9)

All nine are geometry-only and therefore **colour-space neutral** — correct as-is in linear light.
Two cross-cutting notes apply to the whole group:

- **Edge behaviour is a control in Resolume, not a constant.** Nearly every distort has a
  **`Black BG`** boolean (default 0) deciding whether out-of-frame samples wrap, clamp or go black;
  Wave Warp has **`Pin edges?`** (default **1**) which clamps instead of discarding. Photon uses
  `address::clamp_to_edge` universally, which gives the smeared-edge look always. Wrapping (`fract`)
  versus clamping is a visible, opinionated difference and Resolume lets the operator choose.
- **All of them are beat-syncable in Arena** — see cross-cutting §2.

## kaleidoscope

**What it does.** Mirrors a wedge of the frame around the centre N times. The VJ cliché, and it has
to be right.

**Resolume** `[Resolume primary]` — effect `Kaleidoscope` (`sy02`). Full GLSL recovered:

```glsl
float numberOfAngles = Angles * 12.0;        // slider 0..1  ->  0..12 segments
float rotationAngle  = Rotation * twopi;
float inputRotationAngle = InputRotation * twopi;
float angle_mod = twopi / floor( abs( numberOfAngles ) );
float angle = mod( orig_angle, angle_mod );
if (angle > angle_mod / 2.0) angle = angle_mod - angle;   // the mirror fold
angle = angle + inputRotationAngle;
vec2 new_tc = distanceToCentre * Zoom * vec2(cos(angle), sin(angle)) + centre;
```

Four controls, with shipped defaults: **`Angles`** (0.3 → ~3 segments), **`Rotation`** (0),
**`Zoom`** (0.5), **`Input Rotation`** (0), plus `Black BG` and the full transport block.

The distinction between **`Rotation`** (spins the *wedge boundaries* — the pinwheel spins) and
**`Input Rotation`** (spins the *source* inside a fixed wedge — the pattern churns while the frame
stays put) is the thing that makes Arena's kaleidoscope expressive, and it is the single most
valuable addition available here. Also note Resolume **folds** the angle (`angle_mod - angle`)
rather than taking an absolute value about the wedge centre; both mirror, but the fold keeps the
seam continuous.

**ISF** `[ISF]` — `Kaleidoscope.fs`: `sides` 1…32 default **6**, `angle` −1…1, `slidex`/`slidey`
0…1, `center` point2D. Note ISF's default of 6 segments against Resolume's ~3.

**Photon today.** `amount` = segment count `floor(mix(2.0, 16.0, a))`, `param` = rotation
(`p * TAU`). `paramLabel` = **"Rotation"**.

**Naming verdict — "Rotation" matches Resolume exactly.** Keep it. But `amount` is a **segment
count**, not an amount — it is really Resolume's "Angles"/ISF's "sides", and because it occupies the
amount slot the effect has no dry/wet. This is exhibit A for cross-cutting §1.

**Neutral point.** None — there is no setting that passes the image through. Correct and expected.

**Would feel wrong if missed.** The segment count must be an **integer** and must not jitter while
modulated (Photon's `floor()` handles this). Two is the minimum sensible value. And `Zoom`, which
Photon lacks: without it the wedge always samples from the same radius and the pattern cannot be
pushed in or out.

## mirror

**What it does.** Folds the frame across an axis.

**Resolume** `[Resolume primary]` — effect `Mirror` (`A108`), *"Mirrors the content over the X and Y
axis separately."* Five controls: **`X`** (0), **`Y`** (0), **`In / Out`** (1), **`Flip X`** (bool),
**`Flip Y`** (bool), plus `Black BG` and the transport block. The GLSL:

```glsl
coords = abs( coords - Pos ) + Pos * InOut;
coords.y = 1.0 - coords.y;
coords = mod( coords * MaxCoords, MaxCoords );
```

So the mirror **axis position is continuous and modulatable** (`X`/`Y`), `In / Out` chooses which
half is kept, and the `Flip` booleans mirror the whole result. There is also a separate
**`Mirror Quad`** (`A180`) for the four-way fold.

**ISF** `[ISF]` — `Mirror.fs`: `horizontal` bool (default on), `vertical` bool (default off). Axis
pinned to centre.

**Photon today.** `param` selects an axis by range (`< 0.33` = X, `< 0.66` = Y, else both), `amount`
is a binary switch via `step(0.001, a)`. `paramLabel` = **"Axis"**.

**Two problems.**
1. **"Axis" is a three-way enum wearing a continuous knob.** Dragging through it snaps between three
   states with no in-between. It should be a discrete control in the UI, and `EffectChain` should
   say so (a `paramIsDiscrete` / `paramChoices` field alongside `paramLabel`).
2. **`amount` is a boolean.** `step(0.001, a)` means mirror is either fully on or fully off, so the
   one knob a VJ will reach for to ease the effect in does nothing but click. Resolume's continuous
   `X`/`Y` axis position is the far better use of that knob — **move the mirror line to `amount` and
   the axis selection to a discrete `param`.** That alone makes mirror a performable effect instead
   of a toggle.

**Would feel wrong if missed.** A movable mirror line. Sliding the fold across the frame while the
content moves is the entire reason this effect is in a VJ set.

## twirl

**What it does.** Swirls the image around a point, strongest at the centre, falling off outward.

**Resolume** `[Resolume primary]` — effect **`Twisted`** (`A122`, registry description *"Pixel
twister"*). Two controls, **`Twirl`** and **`Radius`**:

```glsl
phi = phi + (1.0 - smoothstep( -Radius, Radius, r )) * Twirl;
...
texCoord = mod( texCoord, 1.0 );      // wraps, does not clamp
```

`Radius` controlling the falloff via `smoothstep` is the control Photon is missing, and it is the
difference between a tight vortex and a whole-frame swirl. Note Resolume **wraps** the result
(`mod`), so the spiral tears round the edges rather than smearing.

**ISF** `[ISF]` — `Twirl.fs`: `amount` −10…10 default **0** (signed — both directions), `radius`,
`center` point2D default `[0.5, 0.5]`.

**Photon today.** `amount` = twist `(1 - saturate(r*2)) * a * TAU`, `param` = `float2(p, 0.5)` as
the centre. `paramLabel` = **"Centre"**.

**Naming mismatch — flag this, it is the clearest one in the file.** The label promises a centre;
the knob delivers **only the X coordinate**, with Y permanently pinned to 0.5. The same bug is in
`fisheye` and `zoom`. Three options, best first:
1. Make centre a `point2D`-style control (requires a param pair — the real fix, and ISF, Resolume
   Polkadot and Resolume Blow all expose centre as two values).
2. Relabel to **"Centre X"** so the control is honest.
3. Drop the centre, pin it to the frame centre, and spend `param` on **`Radius`** (Resolume's choice,
   and the more useful knob of the two).

**Would feel wrong if missed.** A **signed** twirl. ISF's −10…10 lets you spin either way, and
alternating direction on the beat is a standard move. Photon's `a * TAU` is positive-only.

## fisheye

**What it does.** Barrel/pincushion lens warp — bulges or pinches the frame.

**Resolume** `[Resolume primary]` — effect `Fish Eye` (`A123`), one control, `FishEye`, described as
*"Warps the content in a curved, bubble-like way — like looking through a peephole."*

```glsl
float pr = (r * r) / sqrt(2.0);     // sqrt(2) is the max radius at the corners
r = mix( r, pr, FishEye );
```

So Resolume lerps between the identity radius and a squared radius: identity at **0**, full barrel
at **1**, and the `/sqrt(2)` normalises so the corners still land inside. Clean and bounded.

**ISF** `[ISF]` — `Bump Distortion.fs`: `level` −1…1 default 0.5 (**signed**, so bulge *and* pinch),
`radius` 0…1 default 0.25, `center` point2D.

**Photon today.** `pow(r, k-1)` with `k = 1 + (a - 0.5)*2`, so signed and identity at `amount = 0.5`
— good, better than Resolume's. `param` = `float2(p, 0.5)` centre. `paramLabel` = "Centre".

**Verdict.** The amount mapping is right (signed, centre detent — keep it). Same **"Centre" is
X-only** mismatch as `twirl`. Same remedy; here `radius` (the extent of the warped region) is the
better alternative use for `param`.

**Would feel wrong if missed.** Corner behaviour. `pow(r, k-1)` with a strong pinch samples far
outside [0,1] at the corners and `clamp_to_edge` smears it into streaks. Resolume's `/sqrt(2)`
normalisation avoids this; worth copying.

## wave

**What it does.** Ripples the image along a sine (or square) wave.

**Resolume** `[Resolume primary]` — effect `Wave Warp` (`MWWP`), *"Warps the image according to a
waveform."* Controls with shipped defaults:

| Name | Default | Notes |
| --- | --- | --- |
| `Mode` | 0 | separate shaders for sine and square — the square mode is the stepped/glitch look |
| **`Height`** | 0.2 | **amplitude**, mapped `mix(0.0, 0.5, Height)` |
| **`Width`** | 0.2 | **frequency**, mapped `mix(0.5, 45.0, Width)` |
| `Angle` | 1 | direction of travel, as `cosa`/`sina` |
| `Pin edges?` | **1** | clamp instead of `discard` at the frame edge |
| transport block | — | `Speed` 0.5, plus BPM/Beats/Syncmode |

```glsl
float sheight = mix( 0.0, 0.5, height );
xy -= sheight / 2.0 * dir;
vec2 rxy = R * xy;
xy += dir * sheight * sin( mod( mix(0.5, 45.0, width) * rxy.y + time, TWOPI ) );
```

Note Resolume **pre-shifts by half the amplitude** so the wave oscillates about the original position
rather than only pushing one way — without that, raising the amplitude also translates the image.

**ISF** `[ISF]` — `Sine Warp Tile.fs`: `size`, `rotation`, `angle`, `shift` point2D.

**Photon today.** `param` = frequency `mix(2.0, 40.0, p)`, `amount` = amplitude `× 0.05`, driven by
free-running `u.time`, both axes warped simultaneously (`sin` on y, `cos` on x). `paramLabel` =
**"Frequency"**.

**Naming note.** "Frequency" is the clearer engineering term and matches ISF's spirit; Resolume
confusingly calls amplitude **"Height"** and frequency **"Width"**. **Keep Photon's names** — this is
one place where Resolume's naming is worse — but be aware a Resolume user will look for Height/Width.

**Three gaps, in priority order.**
1. **Not beat-locked.** `u.time` free-runs. In Arena this effect is on the composition clock by
   default (cross-cutting §2). A wave that drifts against the music is the most audible failure in
   the whole set. Give it `u.beat` like `strobe` has.
2. **No direction/angle.** Resolume's `Angle` is a first-class control. Photon's fixed both-axes
   warp is a single look.
3. **No amplitude pre-shift** — raising amount visibly translates the image.

**Would feel wrong if missed.** The square-wave mode. It is a completely different, very popular
look (hard horizontal tearing rather than smooth ripple) and it is one `sign()` away.

## tile

**What it does.** Repeats the frame in a grid.

**Resolume** `[Resolume primary]` — effect `Tile` (`A113`, *"Tile and skew image"*). Five controls:
**`Tile X`** (0.1), **`Tile Y`** (0.1), **`Skew X`** (0.5), **`Skew Y`** (0.5),
**`Rotation Angle`** (0), plus `Black BG`.

```glsl
mat2 rotation = mat2( cos(Angle), -sin(Angle), sin(Angle), cos(Angle) );
coords = rotation * (coords - 0.5*MaxCoords);
coords = coords * Tile;
coords = coords + vec2( Skew.x * coords.y, Skew.y * coords.x );
coords = mod( coords - 0.5*MaxCoords, MaxCoords );
```

Independent X/Y counts, a **shear** and a **rotation** applied before the modulo — the rotation is
what produces the diagonal/herringbone tilings rather than a plain grid.

**ISF** `[ISF]` — `Quad Tile.fs`: `size` 0…2, `rotation`, `angle`, plus three point2D slides/shifts.

**Photon today.** `amount` = uniform tile count `floor(mix(1.0, 8.0, a))`. **`param` is never read.**
`paramLabel` = **"Offset"**.

**Flag — dead knob.** "Offset" is labelled and does nothing. The highest-value thing to wire it to,
given one slot: **rotation angle** (biggest visual payoff, per Resolume) or **X/Y aspect** (let the
grid be 4×2 rather than always square).

**Would feel wrong if missed.** Non-integer tile counts. `floor()` is correct — a fractional tile
count produces a sliced partial tile at the edge that reads as a bug.

## slide

**What it does.** Translates the frame with wraparound.

**Resolume** `[Resolume primary]` — effect `Slide` (`A136`), *"Moves and wraps the content over the
X and Y axis."* Controls: **`X`** (0), **`Y`** (0), `Black BG`, plus the full transport block —
five presets ship, all of them animated, confirming this is used as a *scrolling* effect driven by
the clock, not a static offset.

**ISF** `[ISF]` — `Channel Slide.fs` offsets per channel (`slideAmt` as an RGBA quad) with a
`reflection` bool. Per-channel sliding is a distinct, popular look.

**Photon today.** `param` = direction angle (`p * TAU`), `amount` = distance, `fract()` wrap.
`paramLabel` = **"Direction"**.

**Naming verdict.** Polar (direction + distance) versus Resolume's Cartesian (X + Y) — Photon's is
arguably the better two-knob reduction, since it makes "slide diagonally" one knob instead of two.
"Direction" is a clear label. **Keep it.**

**Would feel wrong if missed.** Beat-synced auto-scroll. All five Resolume presets animate; a static
offset is the less-used half of this effect. Once the transport block exists (cross-cutting §2), a
`Speed` on slide gives scrolling backgrounds for free.

## polar

**What it does.** Reinterprets the frame in polar coordinates — rectangular content wraps into a
disc, horizontal lines become rings.

**Resolume** `[Resolume primary]` — effect **`PolarKaleido`** (`A190`, *"Polar Kaleidoscope"*). Four
controls: **`Rings`**, **`Kaleidos`**, **`Aspect`**, **`Angle`**:

```glsl
coords.y /= Aspect;
float r     = length(coords) * (Rings + 1.0);
float theta = atan(coords.y, coords.x) * Kaleidos;
theta = ( theta + (Angle + 0.25) * 2.0 * pi * Kaleidos ) / (2.0 * pi);
vec2 endCoords = fract( vec2(theta, r) );
endCoords.x = 1.0 - endCoords.x;
```

`Rings` repeats the image radially (concentric copies), `Kaleidos` multiplies the angle (angular
repeats), `Angle` rotates. The `fract()` on both axes means the mapping tiles rather than clamping —
that is what gives the dense tunnel look. There is also a separate `Tunnel` effect (`sy04`) with
`Position`, `Twist`, `Kaleidoscope`, `Rotation`, `TurnH`, `TurnV`, `WobbleH`, `WobbleV`.

**ISF** `[ISF]` — `Polar Function.fs` with `segments` 0…10, but it is a transition, not a filter.

**Photon today.** `q = (atan2 / TAU + 0.5, length * 2.0)`, `amount` = mix between rectilinear and
polar. **`param` is never read.** `paramLabel` = **"Direction"**.

**Flag — dead knob**, and "Direction" is not a control any polar implementation exposes. Best uses
for the slot, in order: **`Angle`** (rotate the polar origin — cheap, immediately useful, and
modulating it spins the whole disc), or **`Rings`** (radial repeats).

**Would feel wrong if missed.** `fract()` rather than clamp on the radial axis. Photon's
`length * 2.0` exceeds 1.0 past the inscribed circle and `clamp_to_edge` smears the corners into
radial streaks. Resolume wraps, producing repeating rings instead — much better looking.

Also note: **lerping between the identity UV and the polar UV (Photon's `mix`) is not a meaningful
intermediate** — it drags samples along straight lines between two unrelated mappings and reads as a
smear rather than as "half polar". If `amount` is to be a wet/dry, it should blend the two *sampled
results*, not the two coordinate sets.

## zoom

**What it does.** Scales the frame about a point.

**Resolume** `[Resolume primary]` — zoom lives inside `Transform` and `Infinite Zoom` (`P205`,
*"Creates the illusion that the camera is endlessly zooming into the content"*) rather than as a
standalone effect; `Kaleidoscope` and `Cube Tiles` also carry a `Zoom` (default 0.75 in Cube Tiles'
presets, with one preset narrowing the range to 0.6…0.819). **`[thin evidence]` on a dedicated
Resolume Zoom's parameter names** — there isn't one to match.

**ISF** `[ISF]` — `Zoom.fs`: `level` 0.01…10 default **1** (identity at 1, and it goes both ways —
below 1 zooms out), `center` point2D.

**Photon today.** `s = mix(1.0, 0.2, a)` — zoom **in only**, 1× to 5×, identity at `amount = 0`.
`param` = `float2(p, 0.5)` centre. `paramLabel` = "Centre".

**Two gaps.**
1. **No zoom out.** ISF's 0.01…10 straddles 1.0. Pulling back to reveal the frame edges against
   black (or against a wrapped tile) is half of what this effect is for. Make it signed about a
   centre detent like `exposure` and `fisheye` already are.
2. Same **"Centre" is X-only** mismatch as `twirl`/`fisheye`.

**Would feel wrong if missed.** Zooming out past the frame should have a defined edge behaviour —
`clamp_to_edge` gives streaks, `fract` gives tiling, black gives letterboxing. Resolume's universal
`Black BG` flag exists precisely for this choice.

---

# Texture (6)

## rgbShift

**What it does.** Displaces the R and B channels against G along a direction — the classic 3D-glasses
/ VHS misregistration look.

**Resolume** `[Resolume primary]` — effect `Shift RGB` (`A153`), *"Shifts individual color channels"*.
Controls, with preset-confirmed ranges: **`Distance`** (default 1; one preset narrows to
0…0.322), **`Mode`** (choice), **`R`** / **`G`** / **`B`** each **−1…1** default 0, `Black BG`,
plus the full transport block. There is also **`Delay RGB`** (`A152`, *"Delay per color channel"*)
— temporal rather than spatial channel separation, a different and very popular effect.

The important design point: **all three channels get their own signed offset**, with `Distance` as a
master scale, and the `Mode` choice (per the related `Shift RGB` description: *"Shift, rotate or
scale the individual color channels"*) switches whether the offset is a translation, a rotation or
a scale. Scaling the channels against each other is how you get the "lens" variant without a
separate effect.

**Photon today.** `param` = angle (`p * TAU`), `amount` = distance (`× 30` texels), R forward and B
backward along that angle, G fixed. `paramLabel` = **"Angle"**.

**Naming verdict — "Angle" is clear and correct** for a polar two-knob reduction. Keep it.

**Would feel wrong if missed.** Nothing structural. One subtlety: Photon samples R at `uv + d` and B
at `uv - d` but reads G from the *unshifted* `c` — correct, that is the intended look.

**Gamma.** Geometry only; colour-space neutral.

## chromaticAberration

**What it does.** Radial channel separation that grows towards the frame edges — a lens defect,
distinct from `rgbShift`'s uniform displacement.

**Resolume** — **no Resolume equivalent.** `Shift RGB` is uniform, not radial. `[Resolume primary]`,
by absence.

**ISF** `[ISF]` — `Chromatic Aberration.fs` is the reference and has exactly the controls a VJ wants:
`amount` 0…0.2 default **0.02** (note how small — aberration is a subtle effect and a 0…1 knob is
mostly unusable), `falloff` 1…4 default **2.0** (the exponent on the radial term — this is what
distinguishes a lens from a linear smear), `balance` −1…1 (bias the effect towards red or blue),
`center` point2D, and a `direction` enum (Outward, lens-style / Inward).

**Photon today.** `d = (uv - 0.5) * a * 0.05`, so displacement is **linear** in radius. No `param`,
no `paramLabel`.

**Two notes.**
1. **A real lens' aberration goes as roughly r², not r.** ISF exposes this as `falloff` with a default
   of 2.0. Photon's linear falloff puts visible fringing in the middle of the frame where there
   should be none — the centre of a real lens is sharp. This is the one change that would make this
   effect read as "lens" rather than "shifted channels".
2. The `param` slot is free and `falloff` is the obvious occupant. `paramLabel = "Falloff"`.

**Would feel wrong if missed.** Magnitude. ISF's max is 0.2 against Photon's `0.05`, but Photon's
is in UV units applied to a centred coordinate so the scales are comparable — the current range is
sane. Do not increase it; chromatic aberration at high amounts just looks like a mistake.

**Gamma.** Geometry only; neutral.

## vignette

**What it does.** Darkens (and in Arena, *crops*) the frame edges to focus the centre.

**Resolume** `[Resolume primary]` — effect `Vignette` (`sy77`). Resolume's description is worth
quoting because it names a behaviour Photon does not have: *"Vignette **crops** and softens the
edges of your image to draw focus toward the center… can help guide the viewer's eye or **hide the
edges of a projection**."* Three controls with shipped defaults:

| Name | Default |
| --- | --- |
| **`Roundness`** | 0.3 |
| **`Size`** | 0 |
| **`Softness`** | 0.96 |

```glsl
float f = (1.0 - pos.x*pos.x) * (1.0 - pos.y*pos.y);     // pos is NDC, -1..1
float frame = clamp( Softness * (pow(f, Roundness) - Size), 0.0, 1.0 );
fragColor0 = frame * colorSrc;                            // note: multiplies ALPHA too
```

Three things to take from this:
1. **It multiplies the whole RGBA**, so the vignette cuts the alpha as well as the light. That is
   what "crops" means, and it is why Arena's vignette is the standard tool for masking off the edges
   of a projection. Photon multiplies `c.rgb` only and passes `c.a` through — so a Photon vignette
   darkens but never masks, and stacking it under another layer will show the original rectangle.
2. **`Roundness` is a power on a quartic**, not a radius — it morphs between a soft oval and a
   rounded rectangle. That shape control is what makes it fit a 16:9 frame; a `length()`-based
   circular vignette (Photon's) always leaves bright corners or crushes the sides.
3. Hidden in there, `Softness` acts as a *gain* on the falloff before clamping, so high values give
   a hard-edged mask and low values a gentle gradient.

**ISF** `[ISF]` — `v002 Vignette.fs`: `vignette` 0…1, `vignetteEdge` 0…1, `vignetteMix` 0…1.

**Photon today.** `smoothstep(0.75, mix(0.75, 0.1, a), r)` on an aspect-corrected radius.
**`param` is never read.** `paramLabel` = **"Softness"**.

**Flag — dead knob.** "Softness" is labelled and inert, and it happens to be a control Resolume *has*
and that a VJ will specifically look for. Wire it: make `amount` the size/radius and `param` the
softness (the inner edge of the `smoothstep`). That is a five-line change and closes the most
conspicuous gap in this group.

**Also worth fixing:** multiply alpha as well as RGB, or add a mode to. Edge-masking a projection is
a real working use and Photon currently cannot do it.

**Gamma.** Multiplicative falloff is **correct in linear** — leave it.

## scanlines

**What it does.** Horizontal dark lines across the frame — CRT, interlace, lo-fi.

**Resolume** `[Resolume primary]` — no effect literally named Scanlines. Nearest relatives:
**`Stripper`** (`sy69`, *"Removes or recolors strips of your content. Allows for multiple ways to
modulate and animate the strips"*), **`Interlace`**, and **`Raster`**. Stripper's controls, from its
shipped presets, are the most instructive:

| Name | Default |
| --- | --- |
| `Number` | 0.1 |
| `Mode` | 0 |
| `Direction` / `Direction Spread` | 0 / 0 |
| `MovementType` | 0 |
| `SpeedSpread` | 0 |
| `GlobalWidth` / `MinWidth` / `MaxWidth` | 1 / 0.1 / 0.4 |
| `Feather` | 0 |
| `Red` / `Green` / `Blue` / `Alpha` | 0 / 0 / 0 / 1 |
| transport block | — |

Two things stand out: **`Feather`** (soft-edged stripes, against Photon's pure sine) and the fact
that the stripes have a **colour with alpha** rather than just darkening — so you can lay down white
or coloured bars, not only black ones.

**ISF** `[ISF]` — `v002-CRT-Mask.fs`: `Amount` 0…1 and a `Style` enum
(Staggered / Shadow / Straight / **Scanline Staggered**) backed by mask textures. The enum is the
right shape for this effect: a scanline look is a choice of pattern, not a continuum.

**Photon today.** `param` = line count `mix(80.0, 900.0, p)`, `amount` = depth, `0.5 + 0.5*sin()`.
`paramLabel` = **"Count"**.

**Naming verdict — "Count" is clear and correct.** Keep it.

**Would feel wrong if missed.**
1. **Aliasing.** A pure sine at up to 900 cycles against a 1080-line frame is above Nyquist for most
   of the knob's range, so the top half will moiré and crawl horribly on any vertical motion. Either
   cap the count at ~resolution/4, or fade the amplitude towards zero as the period approaches two
   pixels (the standard analytic-antialiasing move).
2. **A sine is the soft version.** Real scanlines are narrow dark gaps between wide bright lines —
   a `pow(sin, k)` or a thresholded duty cycle. Stripper's `MinWidth`/`MaxWidth`/`Feather` exist for
   exactly this.
3. **Scrolling.** Stripper and the Interlace effect both animate. Static scanlines read as a filter;
   slowly rolling ones read as a CRT.

**Gamma.** Perceptual — the darkening depth is a perceived one.

## noise

**What it does.** Film grain / static over the image.

**Resolume** `[Resolume primary]` — three distinct effects, and the distinction matters:
**`Static`** (`MSTF`, *"Layers static noise on top of your content. Use the opacity slider and blend
modes for interesting mixes."*) which has exactly **one control, `Mode`** (a choice, default 1) and
leans entirely on the wrapper's Opacity and Blend Mode for its strength; **`Snow`** (`A159`,
*"Snow simulation"*); and **`Noisy`** (`A185`). There is also a `Static` **generator** (`MSTS`).

That Static exposes only a `Mode` is the clearest single illustration of cross-cutting §1 — in Arena,
"how much noise" is not a parameter of the noise effect, it is the effect's Opacity.

**ISF** `[ISF]` — `Noise.fs`: `seed` 0.01…1, `cell_size` 0…0.5 default 0.125 (grain *size* — the
control Photon lacks), `threshold` 0…1, `use_time` bool ("Animated"), and a `color_mode` enum
(B&W / Alpha / RGB / RGBA).

**Photon today.** `hash21(uv * resolution + time * 60.0)`, multiplied in as `c.rgb * (0.5 + n)`,
`amount` = mix. **`param` is never read.** `paramLabel` = **"Grain"**.

**Flag — dead knob**, and this one is a particular shame because "Grain" is the right name for the
control everyone wants: **grain size** (ISF's `cell_size`). Photon's noise is locked at exactly one
pixel per sample, which at 1080p+ is nearly invisible on a projector and looks like compression
noise rather than grain. Wire `param` to a cell size — `hash21(floor(uv * resolution / cell))` —
and this effect goes from unusable to good in two lines.

**Second issue: `time * 60.0` is frame-rate-independent only by accident.** It is a continuous
multiplier on wall-clock, so the noise field moves *smoothly* rather than resampling once per frame.
Real static resamples discretely. `floor(time * 24.0)` or similar gives the correct stepped
shimmer, and ISF's `use_time` bool lets you freeze it (a frozen grain pattern over moving footage is
a distinct, useful look).

**Gamma.** Perceptual — grain should be perceptually uniform, so modulating in linear makes it
invisible in shadows and harsh in highlights.

## strobe

**What it does.** Gates the image on and off rhythmically.

**Resolume** `[Resolume primary]` — effect `Strobe` (`MSTX`) plus a `Stroboscope` **generator**
(`MSTR`, *"A strobe generator with adjustable frequency"*). Neither ships a preset and neither
shader is in the string table, so **`[thin evidence]` on Resolume's exact strobe parameters.** What
is certain from the transport block (cross-cutting §2) is that **rate is expressed in `Beats`, on a
range of 1/128 to 2^20, against the composition BPM** — not in Hz.

**ISF** `[ISF]` — `Strobe.fs`: `strobeRate` 0…1 default 0, a `strobeMode` enum (**Invert** / **Color**)
and a `strobeColor`. The Invert mode — flashing to a negative rather than to black — is a distinct
and widely used look.

**Photon today.** `phase = fract(beat / mix(4.0, 0.25, p))`, `g = step(phase, 0.5)`, `amount` = mix.
`paramLabel` = **"Rate"**.

**Naming verdict — "Rate" is right, and beat-gating rather than wall-clock-gating is exactly
correct.** This is the best-specified effect in the set. The period range of 4 beats down to 1/4
beat is sensible for a VJ set; Resolume's `Beats` range is wider but nobody uses the extremes.

**Would feel wrong if missed.**
1. **Duty cycle.** Fixed at 50% (`step(phase, 0.5)`). A short bright flash (10% duty) reads
   completely differently from a 50% square and is the more common strobe. Worth exposing if a third
   control appears.
2. **Phase alignment.** The gate must open *on* the beat, not at an arbitrary offset. `fract(beat/n)`
   starting at 0 does this correctly provided `u.beat` is zeroed to the bar — confirm that upstream.
3. **Flash-to-white / flash-to-colour.** Gating to black is one of two obvious modes; gating to white
   or to an inverted frame (ISF's two modes) is the other.
4. **Epilepsy safety** `[practitioner, anecdotal]` — VJs routinely note that rates in the 15–25 Hz
   band are the risky ones. At 128 BPM a 1/4-beat period is ~8.5 Hz, so Photon's current range tops
   out safely; be careful if the range is widened.

**Gamma.** A gate — colour-space neutral.

---

# Key (2)

## lumaKey

**What it does.** Turns brightness into transparency — knocks out blacks (or whites).

**Resolume** `[Resolume primary]` — two separate things, and conflating them is a trap:

1. **`Auto Mask`** (`A120`) is the *effect*: *"Creates alpha channel based on luminance or a color
   channel. This is very useful to get rid of black backgrounds in your content."* Its GLSL:
   ```glsl
   float maskValue = dot( color.rgb, channelMask );   // channelMask selects luma or R/G/B
   if( Invert == 1) maskValue = 1.0 - maskValue;
   color.a = min( color.a, clamp( maskValue * Contrast, 0.0, 1.0 ) );
   color.rgb *= color.a;
   ```
   Controls: a **channel choice** (`channelMask` — Luminance / R / G / B), **`Contrast`** and
   **`Invert`**. Note it takes `min()` with the existing alpha, so it can only *remove* opacity,
   never add it — important for chaining.
2. **`Luma Key`** (`A009`) and **`Luma Key I`** (`A020`) are **blend modes / mixers**, not effects.
   A VJ asking for "luma key" in Arena usually means this one.

**Resolume has no softness control on Auto Mask** — the edge hardness comes from `Contrast`
multiplying the mask before the clamp, which is a gain, not a feather. Softness is Photon's addition
and it is a better control.

**Photon today.** `smoothstep(a, a + mix(0.001, 0.4, p), luma)`, multiplying into `c.a`.
`paramLabel` = **"Softness"**.

**Naming verdict — "Softness" is right** and is standard keyer vocabulary everywhere outside
Resolume. Keep it. `amount` is the cut point, which is the correct primary control for a keyer.

**Would feel wrong if missed.**
1. **Invert.** Knocking out *whites* is as common as knocking out blacks, and there is no way to do
   it. Resolume has `Invert`, as does every keyer ever made. If one more bit of state is available
   anywhere, spend it here.
2. **`min()` with existing alpha.** Photon does `c.a * k`, which is multiplicative and therefore also
   only ever reduces — equivalent in practice. Fine.
3. **Spill / edge treatment.** Not applicable to luma keys. Correctly absent.
4. **The RGB is not premultiplied after keying** — `return float4(c.rgb, c.a * k)`. If the engine
   composites premultiplied, this fringes. See cross-cutting §3.

**Gamma.** Perceptual — the cut point is a perceived brightness. A 0.5 luma key in linear light cuts
at what a human reads as ~73% grey.

## chromaKey

**What it does.** Keys out a colour. Green screen.

**Resolume** `[Resolume primary]` — effect `ChromaKey` (`RhCk`), *"Keys out a certain color"*. This
is the most sophisticated shader in Resolume's set and the full GLSL is recoverable:

```glsl
float GetHueDistance( float hue1, float hue2 ) {        // circular hue distance, done right
    vec2 a = vec2(cos(radians(hue1)), sin(radians(hue1)));
    vec2 b = vec2(cos(radians(hue2)), sin(radians(hue2)));
    return distance(a, b) * 0.5;
}
float ChromaKey(in float hueDist, in float sat, in float val) {
    vec3 values = vec3(hueDist, sat, val);
    vec3 a = smoothstep(startDists, endDists, values);  // independent soft ramps on H, S and V
    return saturate( length( vec3(a.x, 1.0-a.y, 1.0-a.z) ) );
}
vec3 DeSpill(in float hueDist, in vec3 col) {           // desaturate pixels near the key hue
    float despillAmount = 1.0 - smoothstep(spillDistance, spillDistance + spillFeather, hueDist);
    float luma = (col.r + col.g + col.b) / 3.0;
    return mix(col.rgb, vec3(luma), vec3(despillAmount));
}
```

Recovered parameter-name table (the entries immediately following `Bright.Contrast` and preceding
`Circles` in the registry): **`Show Mask`**, **`White Threshold`**, **`White Softness`**,
**`Black Threshold`**, **`Black Softness`**, **`Spill Threshold`**, **`Spill Softness`** — plus a key
colour picker. The mapping of White/Black onto the shader's value and saturation axes is
**`[thin evidence]`**; the three-axis structure (hue, saturation, value, each with an independent
threshold *and* softness) is certain from the shader.

Four design points worth taking:
1. **Hue distance is computed on the unit circle**, not as `abs(h1 - h2)`. That is the correct way
   and it avoids the wrap-around bug at hue 0/1 that catches every naive implementation.
2. **Three independent axes.** Keying on hue alone takes out dark greens and grey-greens that are
   not actually the backdrop; the saturation and value gates are what stop that.
3. **Despill is built in.** Green screens bounce green onto the subject's edges and hair; without
   despill the key always looks pasted. Resolume desaturates pixels near the key hue, weighted by
   how close they are. This is ~four lines and is the difference between an amateur and a usable key.
4. **`Show Mask`** — a dedicated matte-preview toggle. Every professional keyer has one because you
   cannot tune a key by looking at the composite. Resolume implements it as a separate pass
   (`if (showMask > 0) c = vec4(c.a, c.a, c.a, 1.0);`).

**ISF** `[ISF]` — `Chroma Mask.fs` independently arrives at the same three-axis structure, with
`HUE- Tol.` / `HUE- Min. Bracket` / `HUE- Max Bracket` and the same triple for SAT and VAL, plus
`Show Alpha`, a `Hard Cutoff`, an `Alpha Mode` enum (Additive / Multiply / Replace) and `Dilate` /
`Blur` on the matte. Default key colour `[0.24, 0.77, 0.38]` — standard chroma green.

**Photon today.** `key = hsv2rgb(amount, 1, 1)`, `d = distance(normalize(c.rgb), normalize(key))`,
`smoothstep(0, mix(0.05, 0.9, p), d)`. `paramLabel` = **"Tolerance"**.

**Naming verdict.** "Tolerance" is the standard name and is correct. But **`amount` is a hue
selector**, which means the generic "Amount" knob on this one effect does something categorically
different from every other effect in the set — and there is no label on it saying so. At minimum,
`EffectChain` needs an `amountLabel` for this case; a colour swatch is the real answer.

**Gaps, in priority order.**
1. **No despill.** Biggest quality gap. Four lines, per the Resolume source above.
2. **No saturation/value gating.** `normalize(c.rgb)` discards brightness, which is deliberate and
   gets you hue-ish matching for free, but it means **black and dark grey normalise to directions
   close to any key** — dark areas will punch holes in the matte. A saturation floor fixes it.
3. **No matte preview.** `Show Mask` is cheap and transforms how tunable the effect is.
4. **Hue distance via `normalize()` is not a hue distance.** It is an angle between RGB vectors,
   which is close but behaves oddly for desaturated and very bright pixels. Resolume's unit-circle
   formulation is more predictable.

**Gamma.** Perceptual, and this one is severe: **RGB→HSV on linear-light values yields wrong hues,
badly wrong saturations, and a value channel that bears no relation to perceived brightness.** A key
tuned on gamma-encoded footage will not transfer. Of all 35 effects this is the one most likely to be
visibly broken by the linear pipeline. Bracket it.

---

## Summary of `paramLabel` findings

**Dead — labelled, never read by the shader:**
`blur` ("Threshold"), `tile` ("Offset"), `polar` ("Direction"), `vignette` ("Softness"),
`noise` ("Grain").

**Misleading — label does not describe the behaviour:**

| Effect | Label | Problem |
| --- | --- | --- |
| `twirl`, `fisheye`, `zoom` | "Centre" | Only the X coordinate; Y is pinned to 0.5. |
| `posterize` | "Levels" | Turning it up *reduces* levels. |
| `edgeDetect` | "Radius" | Neither Resolume nor ISF has a radius here; both have intensity. |
| `mirror` | "Axis" | A 3-way enum presented as a continuous knob. |
| `hueRotate` | "Hue" | Resolume calls this knob "Hue Rotate"; "Hue" means "pick a hue" in `colorize`. |
| `chromaKey` | (amount unlabelled) | `amount` is a key-hue picker, not an amount. |

**Correct, matching Resolume or standard practice — leave alone:**
`levels` "Gamma", `temperature` "Tint", `sharpen` "Radius", `glow` "Threshold",
`halftone` "Dot Size", `kaleidoscope` "Rotation", `wave` "Frequency", `slide` "Direction",
`rgbShift` "Angle", `scanlines` "Count", `strobe` "Rate", `lumaKey` "Softness",
`chromaKey` "Tolerance", `colorize` "Hue", `duotone` "Hue", `emboss` "Radius".

## Where the evidence is strong, and where it is thin

**Strong primary evidence (Resolume's own GLSL and/or shipped presets recovered):**
levels, invert, saturation, hueRotate, colorize, duotone (as Tint), posterize, exposure, blur,
edgeDetect, glow (as Bloom), halftone (as Polkadot), pixelate (as LoRez), kaleidoscope, mirror,
twirl (as Twisted), fisheye, wave (as Wave Warp), tile, slide, polar (as PolarKaleido), rgbShift
(as Shift RGB), vignette, scanlines (as Stripper), lumaKey (as Auto Mask), chromaKey.

**Thin — stated as such in the sections above:**
- `threshold` — Resolume's `Threshold` effect exists (`A106`, "Color threshold") but ships no preset
  and its shader was not recoverable. Whether it is per-channel or luma-based is unconfirmed.
- `strobe` — Resolume's `Strobe` (`MSTX`) ships no preset and its shader was not recoverable. Only
  the shared transport block is certain.
- `sharpen` — exists in Resolume but is one of the newer Vulkan effects; no GLSL, no preset, no
  parameter names.
- `zoom` — no standalone Resolume effect to match against; ISF only.
- `chromaKey` parameter names — the name table is recovered but the mapping of
  "White/Black Threshold" onto the shader's saturation and value axes is inferred, not confirmed.
- `exposure` slider range — the curve is exact, the min/max are not stated anywhere.
- `solarize`, `emboss`, `temperature`, `chromaticAberration` — **no Resolume equivalent exists.**
  Documented from ISF and standard algorithm sources only. This is a real finding, not a gap:
  four of Photon's 35 have no Arena counterpart, so there is nothing for a VJ to compare them to
  and ISF conventions are the right target.

---

Sources:
- [Resolume — Effects (support)](https://resolume.com/support/en/effects)
- [ISF Specification](https://github.com/mrRay/ISF_Spec)
- [Vidvox ISF reference shader library](https://github.com/Vidvox/ISF-Files)
- In-repo: `docs/reference/arena-effects-presets.json`
- Local: Resolume Arena 7.3 application binary (embedded GLSL + parameter tables) and
  `/Applications/Resolume Arena/default/Presets/Video Effects`
