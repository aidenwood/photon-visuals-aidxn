# Photon — Effect Catalogue

**What this is:** the complete target list of effects for Photon — full Resolume Arena parity
first, then researched additions worth having beyond it — plus a prioritised build order.

**What this is not:** a description of how Photon's existing 35 effects should look and behave.
That lives in [`effect-behaviour.md`](effect-behaviour.md). This file is catalogue, gap analysis
and roadmap only.

**Baseline:** Photon implements **35** effects — `EffectKind` in
[`engine/Sources/PhotonRender/EffectChain.swift`](../../engine/Sources/PhotonRender/EffectChain.swift).
Colour 11 · Stylise 7 · Distort 9 · Texture 6 · Key 2.

**Engine constraints that shape everything below:**

- Compositing is in **linear light**, `rgba16Float`, all the way to the output encode.
- Each effect gets **exactly one render pass** — one fullscreen triangle, one `src` texture in,
  one target out, ping-ponged.
- Each effect carries **exactly two floats** (`amount`, `param`) plus `time`, `beat`, `resolution`.
- There is **no frame history**. The ping-pong pool is reused within a frame and is `.dontCare`
  on load; nothing survives to the next frame.
- There is **no second input texture** binding.

Four of the top ten recommendations below are blocked on those last three lines, not on shader
work. Section 5 states which.

---

## 1. Source provenance — and why the repo's JSON is not enough

### 1.1 `arena-effects-presets.json` is a **partial** extract

It says so itself, and the numbers confirm it:

```json
"schemaVersion": 1,
"observedAt":    "2026-10-12",
"sourceRoot":    "/Applications/Resolume Arena/default/Presets/Video Effects",
"coverage":      "Shipped XML presets only; not the entire Effects browser or shader implementation.",
"presetCount":   116,
"familyCount":   32
```

`sourceRoot` is the **factory-preset folder**, not the effect registry. An effect only appears in
that folder if Resolume ships a saved `.xml` preset for it. Most do not. So the file's 32 families
are a biased sample — biased, specifically, toward the big parameter-heavy effects worth shipping
presets for (Linear Cloner, Particle System, Stripper, VideoWall) and silent on the ~70 effects
that are one knob and need no preset.

**Determination: partial. 32 of ~96 operator-facing effects — roughly one third.** Verified two ways:

1. The `coverage` string states it in plain English.
2. Resolume's own marketing claims "over a 100 built-in video effects"
   ([resolume.com/support/en/effects](https://resolume.com/support/en/effects)) — irreconcilable
   with 32.

It is still the **highest-weight source for parameter detail**, because it is a real dump of real
shipped data with exact parameter names, defaults and ranges. Sections 2 and 6 lean on it heavily
for that. It is simply not the list.

### 1.2 The authoritative list: the Arena binary's render-pass registry

Resolume Arena 7.3 is installed on this machine. Every effect, generator and mixer is registered
through three C++ templates whose instantiations survive in the shipped binary's symbol table:

```
ra::RenderPassManager::registerExtension<T>(RenderPassCategory, int, bool, bool, ...)
ra::RenderPassManager::registerMixerExtension<T>(int, bool, ...)
```

Extracted from `/Applications/Resolume Arena/Arena.app/Contents/MacOS/Arena`
(read-only; `strings` + demangle of the template parameter):

| | Count |
|---|---|
| `registerExtension` instantiations (effects + generators) | **128** symbols → **124** distinct types after de-duplicating wrapper variants |
| of which **generators / sources** | **19** |
| of which **effect passes** | **105** |
| of which **internal utility passes** (never shown in the Effects browser) | **9** |
| **→ operator-facing video effects** | **96** |
| `registerMixerExtension` instantiations (blend modes + transitions) | **58** |

96 + 19 = 115, which is exactly the "over a 100" Resolume advertises. The numbers close.

A second corroborating extract from the same binary gives each class's **display name**, its
4-character preset `uniqueId` (`A101`, `sy08`, `MWWP` …) and, for most, a one-line description —
the strings the Effects browser renders. Those display names are what the tables below use, so an
operator coming from Arena sees his own vocabulary.

> **Why this matters beyond counting.** The three registration templates are three *pipeline
> positions*. A `registerExtension` with a generator category occupies a **clip slot**; an effect
> pass sits **in a layer's chain**; a `registerMixerExtension` needs the **destination** composite
> below it. They are not interchangeable, and §4 keeps them apart.

### 1.3 The structural finding hiding in the preset JSON

Every one of the 116 presets has the same `passes` shape:

```
DryWetEffect  ──►  <TheActualEffect>  ──►  <a Mixer: Add / Alpha / Lighten / Difference / …>
```

And every one carries `Bypassed` + `Opacity` twice (once for the dry/wet wrapper, once for the
effect) plus a trailing `Blend Mode` choice.

**Dry/wet mix and per-effect blend mode are universal infrastructure in Resolume, not per-effect
code.** The effect shader renders its wet result; the host blends it back over the dry input using
any of the 58 mixers at any opacity.

Photon currently bakes the mix into each shader via `amount` — which is why `amount` means a
different thing in every one of the 35 (cut point for threshold, segment count for kaleidoscope,
mix for invert). Hoisting dry/wet + blend-mode out of the shaders and into the chain:

- frees `amount` to be the effect's real first parameter,
- makes every future effect shorter and more honest,
- and multiplies the catalogue — `Blur` blended `Difference` over dry is a completely different
  look from `Blur` blended `Alpha`, for zero extra shader code.

This is the single cheapest multiplier in this document. It is listed as **E1** in §5.

---

## 2. Part 1 — the Resolume catalogue, mapped against Photon

Legend: ✅ genuine equivalent · ⚠️ something in the family, materially less capable · ❌ absent.

`uid` is the Resolume preset `uniqueId`, useful later for importing `.xml` presets directly.

### 2.1 Colour and tone

| Resolume effect | uid | Photon | `EffectKind` | Gap |
|---|---|---|---|---|
| Exposure | A134 | ✅ | `.exposure` | — |
| Hue Rotate | A128 | ✅ | `.hueRotate` | — |
| Posterize | A109 | ✅ | `.posterize` | — |
| Saturation | A110 | ✅ | `.saturation` | — |
| Levels | A141 | ⚠️ | `.levels` | Photon = contrast + gamma. Resolume = in/out black and white points, per channel. |
| Invert RGB | A105 | ⚠️ | `.invert` | Resolume inverts R/G/B independently; Photon inverts uniformly. |
| Colorize | A103 | ⚠️ | `.colorize` | Resolume has palette mode, colour count, weighted ramp, greys-keep + tolerance, contrast, invert (16 params). Photon tints luma by one hue. |
| Threshold | A106 | ⚠️ | `.threshold` | Resolume thresholds **colour**, per channel. Photon thresholds luma only. |
| Bright.Contrast | A102 | ⚠️ | `.levels` | No dedicated brightness/contrast pair; `.levels` approximates contrast and nothing approximates brightness cleanly. |
| Tint | A179 | ⚠️ | `.temperature` | Resolume tints toward an arbitrary colour; Photon's is a warm/cool + green/magenta pair. |
| Recolor | sy99 | ⚠️ | `.duotone` | Resolume is a full palette remap; `.duotone` is a two-stop ramp. |
| Vibrance | — | ⚠️ | `.saturation` | Vibrance is luma-weighted saturation that protects skin tones; `.saturation` is linear. |
| Add Subtract | A101 | ❌ | — | Per-channel add/subtract, −1…+1 each, with a blend mode. 3 of the 116 shipped presets. Trivial shader. |
| Color Pass | A143 | ❌ | — | Keep one hue, desaturate everything else. Classic. |
| Heat | A107 | ❌ | — | Fake thermal LUT. |
| Dither | — | ❌ | — | Patterned quantisation. Resolume's is on `LoRez` too but also standalone. |
| Solid Color | A175 | ❌ | — | Replace content with a flat colour, keeping alpha. Used constantly as a masked fill. |
| To Luminosity | — | ❌ | *(utility)* | Internal pass, not browser-facing. |

**Photon extras with no Resolume counterpart:** `.solarize`, and `.duotone`/`.temperature` are
closer to standalone effects than Resolume's equivalents are.

### 2.2 Blur, sharpen and stylise

| Resolume effect | uid | Photon | `EffectKind` | Gap |
|---|---|---|---|---|
| Blur | A140 | ✅ | `.blur` | Caveat: Photon's is a fixed 5×5 kernel scaled by radius — at `amount` near 1 it is an 8-texel-spread 25-tap, which under-samples and will shimmer. Correct fix is separable multi-pass (**E3**). |
| Sharpen | — | ✅ | `.sharpen` | — |
| Edge Detection | MEDG | ✅ | `.edgeDetect` | — |
| Bloom | — | ⚠️ | `.glow` | Same idea; Photon's bright-pass uses one 5×5 blur, Resolume's is a real multi-tap. Quality, not concept. |
| Dot Screen | A176 | ⚠️ | `.halftone` | Comparable. Resolume exposes angle and shape; Photon hardcodes angle 0.4 rad and circular dots. |
| LoRez | A142 | ⚠️ | `.pixelate` | Resolume LoRez = pixel size **+ bit reduction + dither**. Photon only downsamples. |
| Raster | — | ⚠️ | `.scanlines` | Related family. Not the same effect. |
| Shift RGB | A153 | ⚠️ | `.rgbShift` + `.chromaticAberration` | Resolume has a **Mode** choice — channels can be shifted, **rotated or scaled** — plus per-channel toggles and BPM sync. Photon only translates R and B along one angle. |
| Vignette | sy77 | ⚠️ | `.vignette` | Resolume: Roundness, Size, Softness (3 independent). Photon: amount + softness, roundness fixed by aspect. |
| HV Blur | — | ❌ | *(utility)* | Internal separable blur primitive. |
| Pixel Blur | — | ❌ | — | |
| Radial Blur | sy03 | ❌ | — | Zoom/spin blur. **High value, see §5.** |
| Kuwahara | — | ❌ | — | Edge-preserving painterly smoothing. |
| Dilate | — | ❌ | — | Colour dilation → painterly. |
| Pixel High Pass | A130 | ❌ | — | |
| Drop Shadow | — | ❌ | — | Needs an alpha-bearing source; pairs with keying. |
| Hatched | — | ❌ | — | |
| Polkadot | A181 | ❌ | — | |
| Circles | A125 | ❌ | — | Content resampled into a field of circles. |
| Point Grid | A148 | ❌ | — | 3D point grid — needs geometry (**E4**). |
| Triangulate | A182 | ❌ | — | Triangular pixelation with Sierpiński recursion. |
| Snow | A159 | ❌ | — | Overlay simulation. |
| Snowy | A189 | ❌ | — | |
| Sparkles | A188 | ❌ | — | |
| Noisy | A185 | ❌ | — | |
| Static | MSTF | ⚠️ | `.noise` | Resolume's has a Mode choice and is designed to be blended; Photon's is multiplicative grain only. |

**Photon extras:** `.emboss` has no Resolume counterpart.

### 2.3 Geometry and distortion

| Resolume effect | uid | Photon | `EffectKind` | Gap |
|---|---|---|---|---|
| Kaleidoscope | sy02 | ⚠️ | `.kaleidoscope` | Resolume: Angles, Rotation, Zoom, **Input Rotation**, BPM sync. Photon: segments + rotation. |
| PolarKaleido | A190 | ⚠️ | `.polar` + `.kaleidoscope` | Two Photon effects chained get near it; the real one is a single pass with its own controls. |
| Mirror | A108 | ⚠️ | `.mirror` | Resolume: mirror **position** X/Y, In/Out, Flip X, Flip Y, BPM sync. Photon: three fixed axis modes, no position. This is a materially smaller effect. |
| Mirror Quad | A180 | ⚠️ | `.mirror` | Photon's `p > 0.66` branch folds both axes, which is close — but no position or rotation. |
| Fish Eye | A123 | ⚠️ | `.fisheye` | |
| Twisted | A122 | ⚠️ | `.twirl` | "Pixel twister". Nearest honest match; the maths differs. |
| Wave Warp | MWWP | ⚠️ | `.wave` | Resolume: **Mode** (waveform choice), Height, Width, **Angle**, BPM sync, pin-edges. Photon: amount + frequency, axis-locked, free-running time only. |
| Ripples | sy05 | ⚠️ | `.wave` | Separate H/V frequency + amplitude + phase. Photon's `.wave` is a crude subset. |
| Slide | A136 | ⚠️ | `.slide` | Equivalent behaviour (wrapping XY offset), different parameterisation (angle+amount vs X,Y). BPM sync missing. |
| Tile | A113 | ⚠️ | `.tile` | Resolume: Tile X, Tile Y, **Skew X, Skew Y, Rotation Angle**. Photon: one uniform count. |
| Transform | — | ⚠️ | `.zoom` + `.slide` | Translate and scale exist separately; **no rotation, no anchor point, no single effect**. Resolume's Transform is on practically every clip. The gap is bigger than the ⚠️ suggests. |
| Flip | A104 | ❌ | — | Horizontal / vertical / both flip. `.mirror` **folds**, it does not flip. Trivial, and genuinely missing. |
| Distortion | A129 | ❌ | — | Distort + radius, BPM-syncable. |
| Suckr | A126 | ❌ | — | |
| Bendoscope | A124 | ❌ | — | |
| Goo | sy06 | ❌ | — | Oozing displacement. 3-axis max-distortion + speed. |
| Tunnel | sy04 | ❌ | — | Position, twist, kaleidoscope, rotation, turn H/V, wobble H/V. Big, loved, pure shader. |
| Infinite Zoom | P205 | ❌ | — | **Needs frame feedback (E2).** |
| Sphere | — | ❌ | — | Needs geometry (**E4**). |
| Stingy Sphere | A147 | ❌ | — | Geometry (**E4**). |
| Cube Tiles | A117 | ❌ | — | Geometry (**E4**). 3D cubes textured with the content. |
| Terrain | P202 | ❌ | — | Geometry (**E4**) — luma as displacement over a mesh. |
| VideoWall | sy88 | ❌ | — | Grid of sub-screens with pan/zoom/gap/rotation. |
| Grid | A413 | ❌ | — | |
| Fragment | sy08 | ❌ | — | Radial fragmentation with per-fragment 3D rotation. |
| Iterate | sy13 | ❌ | — | Repeated transform with per-iteration deltas. 40+ params. |
| Linear Cloner | — | ❌ | — | Clones along a line with scale/rotation ramps and tails. |
| Radial Cloner | — | ❌ | — | Clones around a circle, Fibonacci distribution, fan. |
| Stripper | sy69 | ❌ | — | Removes/recolours strips; 21 params, heavily modulatable. |
| Blow | A139 | ❌ | — | Smears a region outward. |
| Reveal | — | ❌ | — | Grid-pattern reveal over time. |
| Radar | J004 | ❌ | — | Pie-shaped sweep mask. |
| UV Map | — | ❌ | — | **Needs a second input texture (E5).** Warps content by a UV map image. |
| Displace | A131 | ❌ | — | **Needs a second input texture (E5).** |
| Meta Shape | — | ❌ | — | SDF shape combiner — effectively a generator used as an effect. |

### 2.4 Keying, masking and framing

| Resolume effect | uid | Photon | `EffectKind` | Gap |
|---|---|---|---|---|
| ChromaKey | RhCk | ⚠️ | `.chromaKey` | Photon keys by hue distance with a tolerance. Resolume has a colour picker, separate edge and spill controls. No spill suppression in Photon — that is the difference between "keyed" and "usable". |
| Luma Key | — | ⚠️ | `.lumaKey` | **Pipeline-position mismatch:** in Resolume `LumaKey` / `LumaKeyI` / `LumaIsAlpha` are **mixers**, not effects — they key against the composite below. Photon's `.lumaKey` keys against the layer's own luma. Both are useful; they are not the same tool. |
| Mask | — | ❌ | — | Mask a layer with an image. **Needs a second input texture (E5).** |
| Auto Mask | A120 | ❌ | — | |
| Crop | A166 | ❌ | — | Trivial shader, used constantly for bad content and for mapping. |
| Keystone | A137 | ❌ | — | Exists in Photon's **Advanced Output** (output stage), not as a per-layer effect. Maths is already written; it is a plumbing job. |
| Keystone Crop | A156 | ❌ | — | As above. |
| Keystone Mask | A155 | ❌ | — | As above. Pokes holes through content. |
| Slice Transform | — | ❌ | — | Transform applied in slice space — Arena-specific, mapping-adjacent. |
| Alpha Limiter | — | ❌ | *(utility)* | Internal. |
| Premultiply | — | ❌ | *(utility)* | Internal. Photon handles premultiply in the compositor. |

### 2.5 Time-based — every one of these needs frame history

None of these can be built at all under the current one-pass, no-history chain. Flagged as a group
because they are one architecture decision, not five.

| Resolume effect | uid | Photon | Needs |
|---|---|---|---|
| Trails | A111 | ❌ | 1 persistent buffer. Described by Resolume as "a feedback effect". |
| Freeze | A132 | ❌ | 1 persistent buffer + a latch. Freezes *part* of the image (X/Y region). |
| Stop Motion | MSTP | ❌ | 1 persistent buffer + a sample clock. |
| Delay RGB | A152 | ❌ | **N-frame ring** — one delay per channel. Named by a practising VJ as a go-to (§3.6). |
| Infinite Zoom | P205 | ❌ | 1 persistent buffer, read scaled. |
| Strobe | MSTX | ⚠️ `.strobe` | Photon's is beat-gated, which is arguably better. Covered. |
| Twitch | A183 | ❌ | Random-walk state. Photon's effects are stateless; Twitch needs per-instance RNG continuity. 15 params. |
| Shift Glitch | MBSH | ❌ | Stateless — **does not** need history. Listed here only because it reads as time-based. |
| Particle System | A191 | ❌ | Full GPU particle sim — persistent state buffers + instanced geometry (**E2 + E4**). 30 params. |

### 2.6 Text

| Resolume effect | Photon | Notes |
|---|---|---|
| Text Animator (effect form) | ❌ | Animated text over content. Needs glyph rasterisation + an atlas — a subsystem, not an effect. |
| Block Text (effect form) | ❌ | As above. |
| Shaper (effect form) | ❌ | SDF shape generator usable as an effect. |

### 2.7 Running total

| | Count |
|---|---|
| Operator-facing Resolume video effects | **96** |
| ✅ genuine equivalent in Photon | **7** |
| ⚠️ partial — family present, materially less capable | **28** |
| ❌ absent | **61** |
| Resolume internal utility passes (not browser-facing, not counted above) | 9 |
| Resolume generators / sources — **different pipeline position**, §4.1 | 19 |
| Resolume mixers / blend modes / transitions — **different pipeline position**, §4.2 | 58 |

*Reconciling against the tables above: they contain 102 rows. Subtract 4 internal-utility rows
(`Alpha Limiter`, `Premultiply`, `HV Blur`, `To Luminosity`), 1 duplicate (`Infinite Zoom`, listed
under both Distortion and Time), and 1 row that is not an effect at all (`Luma Key`, which is a
Resolume **mixer** — kept in the table because Photon ships it as an effect). 102 − 6 = 96.*

And the other direction: **4 of Photon's 35 have no Resolume counterpart** — `.emboss`,
`.solarize`, and arguably `.duotone` and `.temperature` as standalone effects. Keep them.

The ⚠️ column is the honest headline. Photon has *a* kaleidoscope, *a* mirror, *a* tile — each with
two knobs where Resolume has six to twenty. **Parity is as much a parameter-count problem as an
effect-count problem**, which is why **E0** below outranks every shader in this document.

---

## 3. Part 2 — researched additions beyond Resolume

Sourcing note, per the house research rule: the primary sources here are the ISF specification and
its reference library, the hydra-synth source tree, Derivative's own TouchDesigner docs, and
practitioner write-ups. Listicles and reseller blogs were excluded. **Where the evidence is thin I
say so rather than padding** — in particular, there is no credible, independent, quantitative
source for "which effects VJs actually use most". §3.6 is one named practitioner's own post and is
labelled anecdotal.

### 3.1 ISF support — the strategic item, not an effect

**What it is.** Interactive Shader Format: a GLSL fragment shader plus a JSON manifest describing
its inputs, passes and buffers. Spec and reference at [docs.isf.video](https://docs.isf.video/ref_index.html);
library at [github.com/vidvox/isf](https://github.com/vidvox/isf) — **200+ free, open-source
generators, transitions and effects** maintained by Vidvox (VDMX's authors).

**Why a VJ reaches for it.** Resolume already supports ISF. Every pack he owns, every shader on
isf.video, every Shadertoy port someone has already wrapped — runs. It converts "build 65 effects"
into "build a shader loader".

**Difficulty.** High, and front-loaded: GLSL→MSL translation (glslang → SPIRV-Cross is the
well-trodden path), ISF's uniform conventions, and the `PASSES` model. But it is the only item here
whose payoff is unbounded.

**Architecture.** It *is* the architecture. ISF's `PASSES` array — with per-pass `TARGET`,
`WIDTH`/`HEIGHT` expressions, `FLOAT`, and **`PERSISTENT: true`** for frame-to-frame feedback — is
exactly the multi-pass + frame-history model §5 says Photon needs for its own native effects.

**Build Photon's native multi-pass/persistent-buffer model to the ISF spec's shape, and the ISF
runtime later becomes a loader rather than a rewrite.** That is the single most consequential
sentence in this document.

### 3.2 Feedback family — needs frame history (E2)

Analogue video feedback is the oldest VJ look there is and it is still the most reliably
crowd-moving. Once one persistent buffer exists, all of these are short shaders:

| Effect | What it is | Difficulty |
|---|---|---|
| **Feedback Zoom / Spin** | Previous frame resampled scaled + rotated, mixed under the current one. Endless tunnels. | Trivial shader |
| **Echo / Trails** | Decaying accumulation. Resolume's `Trails`. | Trivial |
| **Rainbow feedback** | Hue-rotate the fed-back frame each iteration. One extra line over Feedback Zoom; disproportionate payoff. | Trivial |
| **Frame difference** | Current minus previous — motion as an image. Drives other effects. | Trivial |
| **Smear / Freeze-paint** | Feedback gated by a luma or motion mask, so only moving pixels update. | Easy |

Lumen (the Mac analogue-video synth) is built almost entirely on this family; so is most of the
Signal Culture modular-app catalogue.

### 3.3 Slit-scan / time displacement — needs an N-frame ring (E2b)

**What it is.** Each output pixel samples a *different frame in the past*, chosen by a gradient
image. A vertical gradient gives the classic rolling-shutter smear; an arbitrary gradient gives
anything.

**Why a VJ reaches for it.** It makes ordinary footage look expensive, and it responds to movement
— so it reads as live rather than as a filter.

**Difficulty.** Shader is easy. The cost is the ring: *N* full-resolution `rgba16Float` frames.
At 1080p that is ~8 MB/frame, so a 60-frame ring is ~500 MB — which collides directly with
`photon-core`'s `src/budget.rs` pools. Mitigations that practitioners actually use: half-resolution
ring, `rgba8` ring for the history only, or a shorter ring with interpolation.

Practitioner discussion of implementations and their trade-offs:
[scanlines.xyz "Video slitscan/time displacement"](https://scanlines.xyz/t/video-slitscan-time-displacement-hows-does-they-work/277)
and Signal Culture's SSSScan. **Anecdotal, but from people shipping it live.**

### 3.4 Datamosh — needs history, and there are two honest versions

**What it is.** The compression artefact where a frame's motion vectors are applied to the *wrong*
picture, so blocks drag and smear.

**The cheap version (recommended).** Estimate displacement from the frame difference or a luma
gradient, then displace the *previous* frame by it in a feedback loop and mix the current frame in
with a small constant to keep the loop stable. This is what the Codrops Three.js write-up and
Buck's OpenFrameworks production tool both do in practice. **Medium difficulty, needs only E2.**

**The real version.** Dense optical flow. Honest assessment: this is expensive and not obviously
worth it. Derivative's own docs say TouchDesigner's **Optical Flow TOP is Windows-only and requires
an NVIDIA 3000-series or newer GPU** — if the leading node-based tool ships it with those
constraints, treating it as a commodity effect on Apple Silicon is wishful. On macOS the realistic
routes are Vision's `VNGenerateOpticalFlowRequest` (CPU/ANE latency, a frame behind) or a hand-
rolled GPU Lucas-Kanade pyramid (several passes). **Defer. The cheap version looks nearly as good
on a dance floor at 30 m.**

Sources: [Derivative — Optical Flow TOP](https://docs.derivative.ca/Optical_Flow_TOP),
[Codrops — Breaking the Frame](https://tympanus.net/codrops/2026/09/02/breaking-the-frame-building-a-real-time-datamosh-effect-with-three-js/),
[Buck — Moshing](https://www.buck.co/research/moshing).

### 3.5 Hydra's `modulate*` family — the biggest idea Resolume under-exploits

Hydra (Olivia Jack's live-coding synth) has a small operator set whose power is almost entirely in
one family: **one texture modulating another's coordinates.** Taken from the primary source,
`hydra-synth/src/glsl/glsl-functions.js`:

```
modulate        modulateHue       modulateKaleid    modulatePixelate
modulateRotate  modulateScale     modulateRepeat    modulateRepeatX / Y
modulateScrollX modulateScrollY
```

Resolume has three of these in spirit (`Displace`, `UV Map`, `DisplaceMixer`) and stops there.

**Why a VJ reaches for it.** It is the difference between "a filter was applied" and "two things are
interacting". A noise generator modulating a clip's kaleidoscope angle is alive in a way no fixed
parameter is — and it is the cheapest route to content that never repeats across a two-hour set.

**Difficulty.** Each operator is five lines of shader. The whole family costs **one architectural
change**: letting an effect bind a **second input texture** (**E5**) — another layer, a loaded
image, or a generator.

**Highest looks-per-line-of-code item in this entire document**, conditional on E5.

Hydra's `src` family (`osc`, `noise`, `voronoi`, `shape`, `gradient`) is a good generator shortlist
too — see §4.1.

### 3.6 What practitioners say they actually reach for — thin evidence, stated as such

There is **no credible quantitative source** for Resolume effect usage. Nobody publishes telemetry
and no survey exists. What follows is **one named VJ's own write-up** of his set, plus scattered
forum mentions. Anecdotal, n≈1, and listed only because it is first-hand rather than recycled:

> Mirror Quad, Blur (BPM-pulsed), Twitch, Distortion, Edge Detection (for fades into a drop),
> RGB Delay, VideoWall, Meta Shape, Triangulate.

Source: [note.com — "Introducing Resolume settings and frequently used effects"](https://note.com/atmosphe_on_air/n/nc8df74541b36?hl=en),
plus the [Resolume forum](https://resolume.com/forum/viewtopic.php?t=20466).

The recurring structural point across both — and it is not about any individual effect — is that
**BPM sync is what makes effects usable live**. "Effects synced to BPM stay in sync like a glove."
Photon passes `beat` into the shader but has no per-parameter phase source. See **E6**.

### 3.7 Other researched additions worth building

| Effect | What it is | Why a VJ reaches for it | Difficulty | Pipeline |
|---|---|---|---|---|
| **CRT / VHS composite** | Chroma subcarrier emulation, dot crawl, tracking error, head-switching noise at the frame bottom | The dominant nostalgic look of the last decade. Scanlines alone do not sell it — the colour bleed does. | Medium | 1 pass passable, 3 passes convincing (**E3**) |
| **Anisotropic Kuwahara** | Kuwahara steered by a structure tensor | Genuine oil-paint look, holds up on a 4K wall where plain Kuwahara mushes | Hard | **E3** — tensor pass + smoothing pass + filter pass |
| **Pixel sort** | Sort pixel runs by luma along rows/columns, gated by a threshold | Instantly recognisable glitch-art signature; nothing else looks like it | Hard on GPU | Bitonic sort = **log₂(n)² passes** (**E3**). Row-local segmented variants cut this a lot. |
| **Ordered dither / 1-bit** | Bayer-matrix quantisation to 1–4 bits | Harsh, legible, projects beautifully. Distinct from Resolume's `Dither`. | Trivial | 1 pass |
| **ASCII / glyph mosaic** | Luma per cell → glyph from an atlas | Cliché, and crowds still love it | Easy | 1 pass + a static atlas texture (**E5**) |
| **Flow-field advection** | Curl-noise velocity field advecting the previous frame | Smoke and ink without a fluid solver | Medium | **E2** |
| **Proper bloom (mip chain)** | Progressive downsample + upsample-blur | Photon's `.glow` is a single 5×5 bright-pass; real bloom needs the chain. Linear-light `rgba16Float` means Photon is already set up to do this *correctly*, which most tools are not. | Medium | **E3** |
| **Chromatic glass / refraction** | Per-wavelength IOR offsets with a normal map | Expensive-looking "liquid glass" | Easy | 1 pass (+ **E5** for a custom normal map) |
| **Voronoi / cellular shatter** | Partition the frame into cells, transform each | Shatter and reassemble on a drop | Medium | 1 pass |
| **Scanline sync disturbance** | Per-row horizontal offset from banded noise | The analogue "signal breaking up" hit. One knob, enormous impact. | Trivial | 1 pass |

**Deliberately not recommended:** raymarched Shadertoy fractals as per-layer effects. They are
generators, they cost hundreds of ALU ops per pixel, and they ignore their input — which defeats
the point of a layer filter. Build them as **sources** (§4.1) if at all.

---

## 4. Different pipeline positions — do not file these with layer filters

### 4.1 Generators / sources — 19 in Resolume

These occupy a **clip slot**. They have no input texture and own their own resolution. Photon has
**none** and the `EffectChain` signature (`apply(_:to source:)`) cannot express one.

Resolume's set, from the binary registry and `/Applications/Resolume Arena/default/Presets/Sources`:

`Blank` · `Block Text` · `CheckerBoard` · `Checkered` · `Gradient` · `Line Scape` · `Lines` ·
`Metaballs` · `Moving Bar` · `Rings` · `Shaper` · `Sine Wave` · `Solid Color` · `Spiral` ·
`Static` · `Stroboscope` · `Test Card` · `Text Animator` · `Waves`

Plus `Abstract Field` and `Tunnelines`, which ship as *presets* of the above.

Worth adding beyond Resolume, from Hydra's `src` family: **`osc`** (oscillator bars),
**`noise`** (value noise), **`voronoi`**, **`shape`** (n-gon SDF).

**`Solid Color`, `Gradient` and `Test Card` are the urgent three.** Not because they are exciting,
but because a VJ needs a black clip, a colour wash and a test pattern in every single show, and
without a source concept he cannot have them. Photon already has test patterns in Advanced Output
— at the wrong pipeline position for this use.

### 4.2 Mixers / blend modes / transitions — 58 in Resolume

These need the **destination** — the composite below the layer — so they live in the compositor, not
the effect chain. Photon's PLAN already covers blend modes; this is the target list, for completeness.

**Arithmetic / photographic (20):** `Add` · `Add 50` · `Subtract` · `Subtract 50` · `Multiply` ·
`Multiply 50` · `Screen` · `Overlay` · `Overlay 50` · `Darken` · `Lighten` · `Lighten 50` ·
`Difference` · `Difference 50` · `Difference I` · `Exclusion` · `Burn` · `Burn 50` · `Dodge` ·
`Dodge 50` · `HardLight` · `SoftLight` · `Distance 50`

**Keying / alpha (7):** `Alpha` · `LumaKey` · `LumaKey I` · `LumaIsAlpha` · `Mask 50` ·
`MixRGB` · `B&W`

**Mix-to (3):** `MixToBlack` · `MixToWhite` · `MixToColor`

**Transitions — these are the ones Photon will notice missing (13):** `Cut` · `Dissolve` ·
`PushLeft` · `PushRight` · `PushUp` · `PushDown` · `ZoomIn` · `ZoomOut` · `RotateX` · `RotateY` ·
`WipeEllipse` · `SideBySide` · `CubeMixer`

**Effect-as-mixer (10):** `LoRez` · `Tile` · `Parts` · `MultiTask` · `MetaMix` · `JitterBug` ·
`StaticMixer` · `TwitchMixer` · `NoisyMixer` · `ShiftRGBMixer` · `DisplaceMixer` · `TimeSwitcher`

That last group is a neat trick worth copying: the same shader registered at both pipeline
positions, so `Static` can be a filter *or* the thing two layers mix through.

---

## 5. Part 3 — prioritised build order

### 5.1 Engine work, ranked — do these first or build the catalogue twice

Six architecture items. Everything in §5.2 is gated on some subset of them.

| | Item | Unblocks | Verdict |
|---|---|---|---|
| **E0** | **Variable parameter count per effect.** `Effect` is `{kind, amount, param, enabled}`; `EffectUniforms` is 32 fixed bytes. Resolume's `Stripper` has 21 parameters, `Iterate` 40+, `Particle System` 30. | **Everything.** Every ⚠️ in §2 is partly this. | **Do this before writing another shader.** Cheap now — one uniform buffer plus a per-kind parameter descriptor. Ruinous after 60 effects hardcode two floats. |
| **E1** | **Hoist dry/wet + per-effect blend mode out of the shaders** into the chain, matching Resolume's `DryWetEffect → Effect → Mixer` (§1.3). | Multiplies every existing and future effect by the blend-mode count. Frees `amount` to mean something. | Highest ratio in the document. Half a day. |
| **E2** | **Persistent frame buffers** — per effect *instance*, surviving across frames, invalidated on clip change / resolution change / bypass. The current pool is shared and `.dontCare` on load. | Trails, Freeze, Stop Motion, Infinite Zoom, Twitch, all feedback, datamosh, frame-difference. **9 Resolume effects + an entire researched family.** | Required. Budget it against `src/budget.rs` transient-target pool. **E2b** (an N-frame ring for slit-scan and RGB Delay) is a strictly larger version — design E2's lifecycle so E2b is a parameter, not a rewrite. |
| **E3** | **Multi-pass per effect** — a declared pass list with per-pass target size, following ISF's `PASSES` shape (§3.1). | Correct separable blur, real bloom, anisotropic Kuwahara, pixel sort, quality radial blur. Also fixes `.blur`'s under-sampling. | Build to the ISF schema so the ISF runtime is later a loader, not a rewrite. |
| **E5** | **Second input texture** per effect — another layer, a loaded image, or a generator. | Mask, Auto Mask, Displace, UV Map, the whole Hydra `modulate*` family, ASCII atlases, custom normal maps. | Small change, very large catalogue unlock. |
| **E6** | **Per-parameter phase sources** — BPM/beats/speed/sync-mode/play-direction bound to *any* parameter, not just a global `beat` uniform. Every Resolume preset in the JSON carries `Beats`/`BPM`/`Speed`/`Syncmode`/`PlayDirection`/`PlayMode`/`Interval`. | Nothing *visually*, and it is the reason Resolume presets feel alive while a parameter set feels dead. Corroborated by the one practitioner source (§3.6). | `photon-core` already has musical time and modulation bindings. This is wiring, not invention. |
| **E4** | **Geometry stage** — effects that are not one fullscreen triangle. | Cube Tiles, Sphere, Stingy Sphere, Terrain, Point Grid, Particle System, Linear/Radial Cloner (as instanced quads). | **Defer.** 7 effects for a whole new pipeline shape. Cloners can be faked in a fragment loop first; revisit if they land well. |
| **E7** | **Source/generator position** — a render pass with no input that occupies a clip slot (§4.1). | 19 Resolume sources + Hydra's `src` family. | Needed, but it is a compositor and document-model change, not an effect-chain one. Sequence it with clip-type work, not with this roadmap. |

### 5.2 The top 10 builds, ranked by value to a working VJ per unit of effort

| # | Build | Gate | Why this, here |
|---|---|---|---|
| 1 | **Transform** (translate · scale · rotate · anchor) | E0 | It is on practically every clip in every Resolume show. Photon's `.zoom` + `.slide` cover two of four axes badly and cannot rotate at all. Trivial shader; the only reason it is not already done is E0. |
| 2 | **Dry/wet + per-effect blend mode** (E1 itself) | — | Not an effect — it multiplies all 35 existing ones by 58 mixers. Nothing else in this list comes close on payoff per hour. |
| 3 | **Trails / Feedback Zoom / Echo** | E2 | The oldest and most reliable VJ look there is, and three shaders share one buffer. Pays for E2 on its own, then Freeze, Stop Motion and Infinite Zoom arrive nearly free. |
| 4 | **Hydra-style `modulate` family** (coords · hue · scale · rotate · kaleid · pixelate) | E5 | Ten effects, five lines of shader each, from one texture binding. Takes Photon somewhere Resolume does not go — the brief asks for additions beyond parity, and this is the strongest one. |
| 5 | **Mirror done properly** + **Mirror Quad** + **Flip** | E0 | The most-cited "makes anything look designed" family, and Photon's current `.mirror` is three hardcoded folds with no position. Highest ratio of *perceived* parity to work in §2.3. |
| 6 | **Shift Glitch** + **Scanline sync disturbance** | E0 | Pure single-pass shaders, no history, no second texture. They read from the back of the room, which most subtle effects do not. The cheapest real wins on the whole list. |
| 7 | **Radial Blur** (zoom and spin) | E0, E3 for quality | The drop effect. A 16-tap single pass is already convincing; E3 makes it clean. Nothing else conveys acceleration as directly. |
| 8 | **Mask** + **Crop** | E5 (Mask), E0 (Crop) | Unglamorous and non-negotiable. Crop fixes bad content live; Mask is how a layer gets shaped to a surface. A VJ hits both every show. |
| 9 | **RGB Delay** | E2b | Named explicitly by the practitioner source, and three channels of frame delay is a trivial shader over a short ring. Buy the ring here and slit-scan becomes a shader later. |
| 10 | **Stripper** | E0, E6 | 21 parameters of animated strip removal, BPM-synced — the clearest demonstration that E0 and E6 were worth doing, and one of the most heavily preset-ed families in the Arena extract (6 of 116). |

**Deliberately below the line, with reasons:**

- **ISF runtime** — strictly the highest-value item in the document, and *not* ranked, because it is
  a quarter of work rather than a build task. The actionable version of it is: **make E2, E3 and E5
  match the ISF spec's shape** (§3.1). Then ISF is a loader later instead of a rewrite.
- **Cube Tiles, Sphere, Terrain, Point Grid, Particle System** — gated on E4, a whole pipeline
  shape for 7 effects. Revisit after the top 10 land.
- **Dense optical flow** — see §3.4. The cheap datamosh looks nearly as good and costs E2, which is
  already being bought at #3.
- **Text Animator / Block Text** — a glyph subsystem, not an effect. Separate project.
- **Pixel sort** — distinctive and wanted, but log₂(n)² passes means it is the *second* thing built
  on E3, never the first.

### 5.3 Sequencing in one line

**E0 → E1 → (builds 1, 5, 6) → E2 → (build 3, 9) → E5 → (builds 4, 8) → E3 → (build 7) → E6 →
(build 10)** — architecture bought only when the next batch of effects is waiting on it, never
speculatively, and every architecture item shaped to the ISF spec so the 200-shader library stays
reachable.

---

## 6. Appendix — parameter detail available right now

For the 32 families in `arena-effects-presets.json`, exact parameter names, defaults, ranges and
blend modes are already in the repo and should be read directly rather than reinvented. These are
the ones where Photon can match Resolume's control surface exactly, today:

`Add Subtract` · `Blow` · `Colorize` · `Cube Tiles` · `Distortion` · `Flip` · `Fragment` · `Freeze` ·
`Goo` · `Invert RGB` · `Iterate` · `Kaleidoscope` · `Keystone` · `Linear Cloner` · `LoRez` ·
`Mirror` · `Particle System` · `Radial Cloner` · `RadialBlur` · `Ripples` · `Shift Glitch` ·
`Shift RGB` · `Slide` · `Static` · `Stripper` · `Suckr` · `Tile` · `Tunnel` · `Twitch` · `VideoWall` ·
`Vignette` · `Wave Warp`

For the other ~64, the binary's description strings (§1.2) give a one-line behavioural spec per
effect, and the Effects browser in the installed copy of Arena gives the live control surface.

---

## Sources

Primary, in weight order:

- `/Applications/Resolume Arena/Arena.app/Contents/MacOS/Arena` — render-pass registry
  (`registerExtension` / `registerMixerExtension` template instantiations), display-name table and
  description strings. Arena 7.3.0 rev 70000. **Authoritative for the effect list.**
- [`docs/reference/arena-effects-presets.json`](arena-effects-presets.json) — 116 shipped presets
  across 32 families. **Authoritative for parameter detail. Partial for coverage** (§1.1).
- [ISF JSON Reference](https://docs.isf.video/ref_index.html) and
  [multi-pass / persistent buffers](https://docs.isf.video/ref_multipass.html) — Vidvox.
- [github.com/vidvox/isf](https://github.com/vidvox/isf) — the 200+ shader reference library.
- `hydra-synth/src/glsl/glsl-functions.js` — Hydra's complete operator set, read from source.
- [Derivative — Optical Flow TOP](https://docs.derivative.ca/Optical_Flow_TOP) — platform and GPU
  constraints, stated by the vendor.
- [resolume.com/support/en/effects](https://resolume.com/support/en/effects) — Resolume's own
  "over a 100 built-in video effects" claim and the dry/wet + blend-mode model.

Practitioner / anecdotal, labelled as such in §3:

- [note.com — Resolume settings and frequently used effects](https://note.com/atmosphe_on_air/n/nc8df74541b36?hl=en) (n≈1)
- [Resolume forum — How I'm learning to VJ](https://resolume.com/forum/viewtopic.php?t=20466)
- [scanlines.xyz — Video slitscan / time displacement](https://scanlines.xyz/t/video-slitscan-time-displacement-hows-does-they-work/277)
- [Codrops — Breaking the Frame: real-time datamosh with Three.js](https://tympanus.net/codrops/2026/09/02/breaking-the-frame-building-a-real-time-datamosh-effect-with-three-js/)
- [Buck — Moshing](https://www.buck.co/research/moshing)
- [Signal Culture modular apps](https://signalculture.org/sc-modular-apps.html) (SSSScan, Interstream)

**Evidence gap, stated rather than padded:** there is no credible quantitative source for which
Resolume effects get used most in live sets. The prioritisation in §5.2 is therefore reasoned from
pipeline position, parameter count, preset density in the Arena extract, and implementation cost —
not from usage data, because none exists.
