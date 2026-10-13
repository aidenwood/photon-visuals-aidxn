# Adversarial validation — 2026-10-13

Pinned to **HEAD = `5871307`**. Built a clean export (`git archive HEAD`) to `/tmp/photon-head`
and drove that, because the live working tree was being rewritten throughout this run.

Evidence: screenshots + mean-pixel measurement of the Composition Monitor, the macOS
Accessibility API for authoritative control values, and the gates run directly.

---

## ⚠️ Finding 0 — the tree was mutated continuously during validation

| time | dirty files vs HEAD |
|---|---|
| session start | 1 (`spikes/dxv-decode/tools/yscore.py`) |
| 20:23 | 11 |
| 20:26 | 28 |
| 20:41 | **47** |

- A second Photon was built and launched from that tree at **20:32:11** (pid 27337), on top of
  the instance being driven. Its UI already shows the in-flight blend refactor
  (layer blends read `Over` / `Darken`, not `Normal`).
- The first instance under test was terminated mid-run at **20:27:14** by another agent's
  `build_and_run.sh`. The system log shows a clean `App termination approved` — a SIGTERM,
  **not** a crash.
- This is the repo's own "never change a definition mid-run" rule being broken against an
  audit. Any result from before 20:27 should be read as "the 20:18 build", which the code
  review independently confirms was equivalent to HEAD.

Also: `./script/build_and_run.sh --verify` printed **"Photon UI preview did not start"** while
the app was running fine. It compares `$PHOTON_BINARY` against `ps` output, and `open`
reports the resolved `/private/tmp/...` path. Its own success check is unreliable.

---

## A. Clip selection reaches the engine — **CONFIRMED**, and the three "unverifiable" controls work

Everything the reporter claimed to have observed, I reproduced:

| behaviour | evidence |
|---|---|
| Grid cell launches that clip on that layer, in both monitors | Clicked Layer 1 / Column 1; both monitors showed `M1-10_Earth` |
| BLACKOUT blacks Composition only | Composition black, Preview still playing **and animating** (colour changed between frames — proves live playback, not a thumbnail) |
| Layer bypass (B) blacks the layer | Bypassing Layer 2 revealed Layer 1 beneath |
| Two layers composite in the right order | Layer 2 over Layer 1, correct |
| A clip set to `Add` visibly composites | Eye + torus additively combined |

### The reporter's three unverified claims — all three work, and the excuse was wrong

> *"layer opacity, solo and master ride the same call but were NOT observed; a script cannot
> drag a SwiftUI slider"*

A script **can** drag these sliders. A `CGEvent` down → 40 × dragged → up moves them fine.

| control | measured |
|---|---|
| **Master opacity** | 100% → mean 24.6 · 5% → visibly dim · 0% → **4.1** (black) · back to 100% → 22.5 |
| **Layer opacity** | Layer 1 @ 1.0 → mean **47.1** · @ 0.476 → **30.4** · @ 0.0 → **0.000**. Only Layer 1's AX value changed; layers 2–4 stayed at 1.0 |
| **Solo** | Both layers live; pressed `Solo Layer 1` → Layer 2's torus vanished, only `M1-10_Earth` rendered |

All three reach the engine. **This should have been in the original report as confirmed.**

One caveat on *effect-parameter* sliders: those are a different control
(`EffectParameterRow`, not `LiveFader`) and they genuinely do **not** respond to synthetic
drags or arrow keys. `Strobe amount` stayed at 0.5 through every attempt.

---

## B. Telemetry is real — **CONFIRMED**, with two real gaps

Confirmed in code and in the running app:

- CPU from `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` (monotonic, not `Date()`), bracketing
  `Engine.render` from first line to after `cb.commit()`.
- GPU from `gpuEndTime - gpuStartTime` inside `addCompletedHandler`, with
  `guard elapsed > 0, elapsed.isFinite` so an untimed buffer is dropped, not averaged as 0.
- Output FPS from `drawable.addPresentedHandler`. There is **no render-call counter anywhere
  in the tree**. The zero case is handled correctly and subtly: `guard time > 0` returns
  *before* the `defer` that writes `lastPresentedTime`, so an unpresented drawable doesn't
  punch a hole in the timeline. That is exactly what makes 60 fps come out of a 120 Hz render.
- No `?? 0`, `?? 60`, `nominal`, `preferredFramesPerSecond` or RNG on the telemetry path.
- 60-frame window confirmed.

**Observed live:** `CPU 0.3→0.7 ms` (rose when effects were added — it tracks real load),
`GPU 0.1→0.4 ms`, `Output 57.1 fps` then `60.0 fps`.
**The 57.1 is the proof.** A substituted target rate or last-known-good could never print 57.1.

### Gap 1 — the measurement code is entirely untested by the gate
Gutting both handlers to empty bodies still passes every telemetry check. The three checks at
`PhotonVerify/main.swift:1678-1682` assert `nil` on a meter that was never handed a drawable
or command buffer — tautologies that hold for an empty function. The interval arithmetic and
the zero-`presentedTime` handling, which the whole FPS claim rests on, have **no test at all**.
There is no check that GPU ms or FPS is ever *correct* when measured — only that it stays
`nil` when unmeasured.

### Gap 2 — "unmeasured shows —" covers *never measured*, not *stopped measuring*
`FrameRing` evicts by sample count, never by age. If the completion or presentation handlers
stop firing while rendering continues, the last 60 samples are averaged forever; the field
never returns to `nil`. `LiveTelemetryBus.staleAfter = 1.0` doesn't catch it — the publish loop
refreshes `publishedAt` every 250 ms regardless of whether the engine rendered, so the
staleness guard measures whether the *publisher* is alive, not whether the *engine* is.

---

## C. All 35 effects implemented, clock reaches them — **CONFIRMED with one refutation**

- **Exactly 35**, verified from the running app's own Add-effect menu: Colour 11, Stylise 7,
  Distort 9, Texture 6, Key 2 = **35**, matching `EffectKind` case-for-case.
- All 35 rendered on the GPU in a standalone harness: **no stubs, no `default` fallthrough, no
  duplicates, no NaN at either knob extreme**.
- The `time:`/`beat:` fix is real (`Engine.swift:483-487`). Measured: exactly `wave`, `noise`
  and `strobe` change between beat 0 and beat 1.37 — matching `isTimeVarying` precisely.

**REFUTED — `amount = 0` is not a true identity for `lumaKey`.** At the fader's zero it leaves
RGB bit-exact but drives **alpha to 0.219, altering 958 / 4096 pixels (23%)**, because
`soft = mix(0.002, 0.5, param)` is not gated by amount and `param` defaults to 0.5. This
contradicts the comment directly above it at `EffectChain.swift:1082-1083` — *"at amount 0 even
a pure black pixel is fully opaque — a true identity, not 'almost'."* `lumaKey` needs
`neutralParam = 0` and doesn't declare it.

**"In time with tempo" needs rewording.** `beat` advances off `Engine.bpm`, which defaults to
120 and is written **only by MIDI**. Nothing in `macos/` ever sets it, and the UI BPM field is
inert. It is "locked to a running 120 BPM engine clock", not "to the tempo you set".

**UNVERIFIABLE — strobe visibly strobing in the running app.** 30 frames with Strobe enabled vs
30 disabled were statistically indistinguishable (`min 8.85 / max 31.08 / mean 17.42` vs
`min 9.35 / max 31.20 / mean 18.61`); the clip's own animation dominates, and with Invert
stacked on top the 12 samples sat at 175–179 with no dark or saturated phase. I could not
raise `Strobe amount` off its 0.5 default because that slider rejects synthetic input, and
`screencapture` at ~3 Hz cannot resolve a 2 Hz gate. Not evidence of a bug — evidence I could
not see it.

---

## D. Effects drag-and-drop reaches real engine state — **CONFIRMED behaviourally**

Decisive paired A/B, toggling `Invert enabled` between every capture to cancel out the clip's
own animation:

```
ON  (invert enabled):  179.1 177.5 175.4 177.2 177.2 178.0 179.1 177.9 175.4 177.2 178.2 178.1
OFF                 :   11.2  18.2  21.2  16.9  11.2   8.8   7.8  18.2  28.7  16.7   8.0  12.3
```

An effect added through the real UI reaches the GPU and changes the picture. Not in doubt.

- **Browser lists the real cases — CONFIRMED.** `NativeEffectDefinitions` is
  `EffectKind.allCases.map { … }`. The hand-written `EffectCatalog.swift` with invented names
  **no longer exists at HEAD** — genuinely deleted, not shadowed.
- **Inspector parameters are real** and route to the engine.
- **REFUTED — the stated path is wrong.** The commit says effects now reach
  `engine.setEffects(layer:)` and that it "was public and called from nowhere in `macos/`".
  It is **still** called from nowhere in `macos/` — two hits in the whole tree, both inside
  `Engine.swift` (`:288` definition, `:414` deck sync). Effects actually arrive via
  `setLayers`. Mechanism fine, claim false.
- **`Engine.swift:414` can clobber UI-set effects.** On `deck.advance` it calls
  `setEffects(layer:, states[layer].effects)`, overwriting the chain `setLayers` just
  installed. Not reproduced; flagged.

---

## E. BlendMode ABI drift fixed — **CONFIRMED, but unguarded and mostly unreachable**

All four layers agree exactly at HEAD — 11 contiguous modes, `needsDestination` matches
`needs_destination`, and `BlendMode(rawValue: 10)!.name` indexes an 11-element array.
**No crash reproducible.**

| # | Rust `doc/mod.rs:550-563` | Swift `Compositor.swift:28` | Metal `blend_rgb` | Name table |
|---|---|---|---|---|
| 0–10 | Over, Add, Multiply, Screen, Difference, Mask, Overlay, HardLight, Subtract, Lighten, Darken | identical | identical | identical |

Three caveats that matter more than the fix:

1. **The new guard cannot fail.** Its own comment says *"nothing at build time compares these
   two enums across the language boundary, so the test has to be the compiler"* — and then
   compares Swift to a **hardcoded literal retyped from the Swift file**
   (`PhotonVerify/main.swift:799, 818-821`). Nothing reads `photon-core`. Add a 12th variant to
   the Rust enum and all six checks still pass. The original defect now wears a green tick.
   Rust also has no `#[repr]`, so the discriminants the FFI relies on are implicit.
2. **7 of 11 modes are unreachable.** `BlendModeControl.swift:10` offers four strings; `ProgramMetalView.swift:171-177`
   maps `Add`/`Multiply`/`Screen` and silently `default: return .over`. Difference, Mask,
   Overlay, HardLight and the three the commit title names — **Subtract, Lighten, Darken** —
   cannot be selected. I confirmed this in the running app: the Blend menu lists exactly
   Normal, Add, Multiply, Screen. A string key with a silent wrong-mode fallback is the same
   failure class the fix was about.
3. **`blend_rgb` case 5 (Mask) is wrong maths** — returns `dst * src`, identical to Multiply.
   The compositor escapes it by special-casing mode 5 before the call
   (`Compositor.swift:380-382`), so composition is correct, but the shared helper is a trap.

---

## F. Gate integrity — all green, but **"211/211" is not reproducible from HEAD**

Everything claimed passes:

```
211/211 checks passed          (binary built from the dirty tree at ~20:21)
24/24 frontend checks passed
292 passed; 0 failed           (cargo test, photon-core)
clippy: Finished, no warnings
photon-core is portable.       (ci/check-portable.sh, 3/3)
swift test: error: no such module 'Testing'   ← broken as stated
```

**No test was weakened, skipped or deleted today.** `git diff ec5a1fd..HEAD` on PhotonVerify is
**360 insertions, 0 deletions**. PhotonVerify is a *real GPU verifier* — real device, real
`Compositor`/`EffectChain.apply`, real command buffers, `getBytes` readback. Both of those
attacks failed. The effect loops iterate `EffectKind.allCases` with **no skip list**, and the
exemptions are tiny and justified (1 `neutralParam`, 6 unlabelled params, 29 + 6 = 35).

### But the denominator floats
Built from a clean `git archive HEAD` export, PhotonVerify reports **221/221**, five runs in a
row, from three different working directories. The commit says 211. Same commit, same machine.

Cause: four whole sections are wrapped in `if let dev = MTLCreateSystemDefaultDevice(), let eng = PhotonEngine(...)`
with **no `else`** (`main.swift:369, 1127, 1226, 1470`). A section that silently vanishes still
prints "N/N checks passed" and exits 0. **A disappeared check is indistinguishable from a
passing one**, so "211/211" is not a citable fact. (The blend-name skip at `:915-918` does the
opposite and registers a *failing* check — that one is honest.)

### Tests that cannot fail

1. **The bug HEAD exists to fix is not covered by the gate HEAD cites.** All six new effect
   guards call `chain.apply(...)` with the clock **passed explicitly**. Nothing asserts that
   `PhotonEngine.render` threads it. Revert HEAD's two lines and 211/211 still passes. The
   commit message even says the verifier "passes the clock explicitly" — and then adds no check.
2. **The neutral-identity guard samples 16 points of 4096 — 0.4%.** `probeGrid` strides
   `SIZE/4` from `SIZE/8`. This is what lets `lumaKey` through: whole-image delta 0.845, verify-grid
   delta **0.00000**. Any spatially-localised defect — a vignette corner, an edge seam, a key on
   shadows — passes for free. The probe image is also bright everywhere, so a luma key has
   almost nothing to bite on.
3. **The mirror→engine seam has zero coverage on both sides.** `grep -rn "ProgramMetalView\|SurfacePlan" macos/Tests macos/Checks engine/Sources/PhotonVerify`
   → no matches. The hop that actually puts effects on screen is untested.
4. **Five hardcoded-`true` checks** (`main.swift:1038, 1044, 1052, 1466, 1166`). Useful
   crash-smoke-tests, but no failure mode; `:1166` writes both branches to pass.
5. **"Labelled param does something" ≠ "does what the label says".** Three labels were changed
   by eye today; nothing verifies any of them.
6. 21 of the 33 new checks are pure CPU ring-buffer arithmetic. The 211 grew mostly from unit
   tests, not effect coverage.

---

## G. Honesty sweep

### There is no output path at all
`NSScreen`, `Syphon`, `NDI`, `DeckLink`, `toggleFullScreen`, `CVDisplayLink`-on-second-display —
**zero hits** in `macos/Sources`. One `Window("Photon", id: "workspace")` scene. `ScreenTarget.interApp`
/ `.ndi` exist as data-model only; nothing constructs or consumes them. The two "outputs" in
the Output panel are hardcoded fixtures. Confirmed by observation: one window per instance.
**`Preview mode · Output inactive` and the `UI preview` pill are accurate.**

### The one label that is now a lie
`ClipMatrixPanel.swift:7` renders **`LOCAL MEDIA · UI PREVIEW`** across the Composition panel —
unconditional, and the grid it disclaims now launches real files into a real engine. This is
the inverse failure: it understates working behaviour. `PLANNED`, `coming soon`, `stub`,
`mock`, `TODO` — zero hits anywhere in `macos/Sources`. DEMO badges are conditional on
`.demonstration` and the app injects `.workspace`, so they never show.

### Controls that look functional and are not, ranked
1. **Composition-scope effects.** `EffectsBrowser.swift:120` offers *"Add to the composition"*.
   You can add one, see it listed, reorder it, scrub its value, hit reset — and nothing touches
   the picture. `reloadRenderEffects` gathers only `.layer` and `.clip`; `.composition` appears
   nowhere in `EngineSurface`. Every sibling scope is genuinely live, which makes this one
   indistinguishable from working.
2. **Clip opacity fader** (`InspectorContents.swift:14`). Full-travel opacity fader in a VJ app
   that does nothing — sitting directly above a blend menu that *does* work. `opacities` is
   private and read only by `inspector()`.
3. **Transport play/pause.** Icon flips, state round-trips through the provider, nothing reads
   `playing`, video keeps playing. Also exposed as "Play preview"/"Pause preview" in the command palette.
4. **The hardcoded `Text("Normal")`** beside every layer fader (`LayerControlRow.swift:22`).
   Not merely inert — now actively *wrong*, since clip blend is live, so the strip reads
   "Normal" while the layer composites in Add. I saw exactly this on screen.
5. Timecode `00:00:00` never advances; BPM readout is a constant `120` with no BPM field and no
   tap tempo anywhere; Transform Position/Scale/Rotation are literals; monitor badge is a
   constant `1920 × 1080`.

### `docs/ui-wiring-audit.md` is materially stale — 3 rows now wrong
Its framing sentence *"Only five facts survive that whole chain"* is false; `SurfacePlan.Layer`
now carries seven.
- Rows 132–139 "Effects … STORED / never becomes a `PhotonRender.Effect`" → **wrong**, layer and
  clip scope are live.
- Rows 88–90 "CPU/GPU/FPS … always `—`" → **wrong**, real telemetry flows.
- Row 119 "Clip → Blend … `engine.setBlend` never called" → **wrong**, reaches the engine as the
  layer's blend.
- Row 111 "Composition → Effects = STORED" → still correct, and now the only dead effect scope.
- The no-output rows → still correct.

---

## Verdicts

| Claim | Verdict |
|---|---|
| A — clip selection reaches the engine | **CONFIRMED** + opacity/solo/master also confirmed working |
| B — telemetry real, never faked | **CONFIRMED** (57.1 fps is the proof); measurement code untested; no staleness on a dead handler |
| C — 35 effects implemented, clock reaches them | **CONFIRMED**; `amount=0` identity **REFUTED for `lumaKey`**; tempo wording overclaimed; strobe-in-app **UNVERIFIABLE** |
| D — effects DnD reaches real engine state | **CONFIRMED**; `setEffects` path claim **REFUTED** |
| E — BlendMode ABI drift fixed | **CONFIRMED**; guard cannot fail; 7/11 modes unreachable |
| F — gates green | **CONFIRMED**; "211/211" **not reproducible** (HEAD gives 221/221) |
| G — honesty sweep | No output path, confirmed. One stale label, three inert-but-convincing controls, audit doc stale |

## Overclaims, most severe first

1. **`211/211` is not a reproducible fact** — HEAD yields 221/221, and four sections can vanish
   silently without changing the "N/N passed" format or the exit code.
2. **The clock fix HEAD exists for is unguarded** — revert it and the gate stays green.
3. **`lumaKey` is not an identity at rest** (23% of pixels), and the guard meant to catch that
   samples 0.4% of the image.
4. **"A script cannot drag a SwiftUI slider"** — it can. Layer opacity, solo and master all work
   and should have been reported as confirmed, not deferred.
5. **"Reaches `engine.setEffects`"** — it does not; `setEffects` is still called from nowhere in `macos/`.
6. **The BlendMode guard compares Swift to a copy of itself**, which is the exact defect the
   commit says it found.
7. **HEAD's commit message describes work that is not in HEAD** — the shader quality pass, the
   new guards and the browser rewrite are all in `HEAD~1`; HEAD's own diff is 8 lines in one file.
8. **`Subtract`, `Lighten` and `Darken` — the three modes in the fix commit's title — cannot be
   selected in the UI.**

## Crashes / hangs / misbehaviour

- **No crash found.** The termination at 20:27:14 was a clean SIGTERM from another agent's
  build script, not a fault. `BlendMode(rawValue: 10)` does not crash at HEAD.
- `build_and_run.sh --verify` reports a false "did not start" when the bundle path resolves
  through a symlink.
- The working tree does not currently compile (`WorkspaceAction has no member setBlendMode`),
  and `build_and_run.sh` masked it with a cached `Build complete! (0.12s)` no-op.

## The single most misleading thing still in the app

**Composition-scope effects.** Drag an effect onto the Composition inspector and it is accepted,
listed, reorderable, its parameters scrub and reset — and it never reaches a pixel. Layer-scope
and clip-scope effects beside it are fully live, so there is nothing on screen to tell an
operator which of the three did anything. In a live VJ set that is the failure you find on stage.
