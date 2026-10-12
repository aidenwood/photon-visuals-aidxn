# Overnight log — 2026-10-12 → 13

Running record of autonomous work while Aiden slept. **Newest entries at the bottom.**
Every decision made without him is marked **[DECISION]** with the reasoning, so it can be reversed.

---

## 22:30 — Preview monitor fixed

**It wasn't broken.** Codex had already built `ProgramSurfaceFactory`; `PhotonApp` just wasn't
passing one, so it fell back to static artwork. Built the engine side:

- `macos/Sources/PhotonRenderSurface/` — Metal `NSView` + `CAMetalDisplayLink`, bridged into
  Codex's factory. PhotonUI still never imports Metal.
- Touched exactly **one line** of Codex's code (the injection) + an additive `Package.swift` dep.

## 22:35 — Real media on screen

Your **Trees Have Eyes** visuals are now playing in the preview, not placeholders. Path is the real
one: VideoToolbox decode → `CVPixelBuffer` → `CVMetalTextureCache` → **zero-copy** `MTLTexture` →
register-folded compositor in linear light.

**[DECISION]** Transcoded 4 clips to H.264 in `media-cache/` because your library is all DXV and
DXV decode is blocked on the licensing question. ffmpeg used as a *tooling* step, never the runtime
path. Reversible — delete `media-cache/`.

Two source files have problems worth knowing:
- `data rings.mov` — **no moov atom, the file is corrupt.**
- `bloom eye 720.mov`, `data worm center.mov` — decode fine but ffmpeg's filter graph chokes
  converting `yuva420p` (alpha DXV quirk). Not a Photon bug.

## 22:50 — DXV parser validated against YOUR files

Ran the parser over 12+ real Resolume renders from the show. **Every one parsed exactly**:
`tag=DXT5 ver=3 comp=LZ`, payload = packet − 12, no exceptions. Real content is **DXT5 with alpha**
(as expected for projection masks).

## 23:05 — DXV compression: structure derived empirically

Rather than decompile (binary is stripped; big uncertain job), derived the format from controlled
probes — cleaner legally and much faster.

For a solid-red 256×256 BC1 image the **entire** payload is:
```
+0000  00 f8 00 f8      literal — BC1 colour pair (changes with colour)
+0004  aa aa aa aa      literal — BC1 index word (all pixels index 2; content-independent)
+0008  55 × 1023        control
+0407  15               partial final word
```
Changing red→green→blue changes **only bytes 0..4**. Everything else is byte-identical.

Payload scales as **≈ 1024 flag bytes (1 bit per 4-byte output unit) + 4 × literal units**:

| probe | payload | implied literal units (of 8192) |
|---|---|---|
| solid | 1,032 | 2.0 |
| smptebars | 1,783 | 189.8 |
| checkerboard | 5,071 | 1011.8 |
| gradients | 5,225 | 1050.2 |
| noise | 14,188 | 3291.0 |

No 4-byte zero runs anywhere → all-zero words are **generated**, so the back-reference history is
zero-initialised. Handed the exact derivation to a dedicated agent with these findings.

## 23:10 — Engine facade

`engine/Sources/PhotonRender/Engine.swift` — `PhotonEngine`, the thing a UI drives. Owns sources,
layer stack, transport, telemetry. Commands: setLayers / setClip / setOpacity / setBlend /
setBypassed / blackout.

Design points worth keeping:
- **Sources survive a layer-stack rebuild** when the clip is unchanged — reordering layers must not
  restart video.
- **Solo beats bypass**, matching every tool in the category.
- **Blackout is explicit**, never an accident of decode timing. A late source holds its last valid
  frame instead.
- Telemetry counts **source repeats separately from dropped frames** — a repeat means the source
  was late, a drop means we missed a deadline. Conflating them hides which half is at fault.

Preview panels are now driven by this, so Codex's UI has a real surface to command.

---
## 23:40 — Parallel modules landed (clock, warp) + core modules written

Ran four agents on disjoint files. Landed so far: **`clock.rs`** (tempo/phase authority, 1768 lines)
and **`Warp.swift`** (projective homography + soft edge, 44KB). `modulation.rs` and `graph.rs` still
in flight.

I wrote in parallel, on files nobody else owned:
- **`ir.rs`** — compositor IR. Blend semantics defined **once**, emitted as both MSL and WGSL, so
  the Mac and Windows shells cannot drift. Includes **C2 occlusion culling** (an opaque, fully
  covering `Over` layer truncates everything beneath it) and per-blend-stack pipeline cache keys.
- **`protocol.rs`** — control protocol. State-sync-first (MIDI pads need pushed state), sized for
  the BLE budget, with revision tracking that **detects a dropped message instead of silently
  drifting**. A test asserts every command serialises under 180 bytes so it fits a BLE MTU.

**123 core tests passing, 0 warnings, portability guard green.**

## 00:05 — Projection mapping is rendering

`OutputStage.swift` — composite once in linear light, then draw one warped mesh per projector slice
with projective UVs and soft-edge weights. Wired into `PhotonEngine`, so the app's output now goes
through the real mapping path rather than a fullscreen blit.

## 00:20 — Built a GPU verifier, and it immediately found three bugs

**[DECISION]** Wrote `PhotonVerify` as an **executable, not an XCTest target** — because **XCTest
requires full Xcode** and the engine is deliberately buildable on Command Line Tools alone. This
also corrects something I told you earlier: Xcode isn't *only* for Instruments and shipping; XCTest
needs it too. The executable works everywhere and suits CI better.

It renders real frames and reads pixels back. First run: **6/9**. The three failures were all real,
and all **mine**, not the agent's:

1. **No sRGB encode was happening.** 0.25 linear came out as 64 instead of ~137. The warp shader
   deliberately emits linear (its comment says so); I'd wired it straight to a non-sRGB drawable.
2. Same root cause showed up in the multiply check.
3. **My homography test was wrong**, not the homography — `QuadCorners` indexes TL, TR, BR, BL and
   I'd assumed bottom-left-origin.

**Fix, done properly rather than patched:** one convention everywhere — shaders emit **linear**, the
target is an **`_srgb` format**, and the hardware does the encode. That also means blending between
overlapping projector slices happens in **linear space**, which is exactly what soft edge needs. I
deleted the hand-rolled sRGB encode entirely rather than leave two conventions in the codebase.

**9/9 passing.** And GPU time *dropped* 1.11ms → 0.76ms, because the hardware encode is cheaper
than the shader one. Demo still holds 120fps.

Run it yourself: `cd engine && swift run -c release PhotonVerify`

## 00:55 — FFI bridge built and measured (R0 #5 closed)

New crate `photon-ffi` — **the only crate permitted `unsafe`**, so `photon-core` keeps
`forbid(unsafe_code)` and keeps passing its portability guard. Windows will link the same core
through the same bridge. staticlib, so there's nothing to ship or sign.

**Measured Swift → Rust** (not Rust → Rust, since the former is what actually ships):

| Layers | ns/frame | share of a 120fps frame |
|---|---|---|
| 1 | 6.3 | 0.000076% |
| 12 | 6.4 | 0.000076% |
| 32 | 6.4 | 0.000076% |

**Flat across layer count** — that's the proof the packed design works: one crossing per frame
carrying a pointer to N contiguous structs costs the same whether N is 1 or 32. **The FFI boundary
is not a performance consideration for this project.**

The Swift side asserts `photon_layer_stride()`/`photon_frame_stride()` against
`MemoryLayout<T>.stride` at startup, so struct-layout drift fails loudly rather than producing
subtly wrong values. Verified matching at 24B/40B.

**[DECISION] Hand-written C ABI instead of `swift-bridge`,** which the scaffold named as default.
Reasons in `photon-ffi/FINDINGS.md`: the surface is 8 functions and 2 POD structs, swift-bridge adds
a codegen step to a package that currently builds with no Xcode at all, and the measured cost is
already nil. **Revisit when the interface starts carrying strings or the document model.** Flagging
clearly because Codex specified swift-bridge and I deviated.

Also found while adapting: the agent's `Clock` is better than my assumption — tempo changes are
**attributed to a source** (`set_bpm(TempoSource, …)`) and it rejects implausible runtime tempo
rather than following it. That's the separable tempo/phase design actually enforced in the type
system.

## 01:20 — All four agent modules landed; beat-synced modulation works end to end

`clock.rs` (1,942) · `graph.rs` (2,058) · `modulation.rs` (2,371) · `Warp.swift` (44KB), plus my
`ir.rs`, `protocol.rs`, `budget.rs`. **7,484 lines of core, 226 tests, 0 warnings, portable.**

Wired modulation through the FFI and **proved it with a test, not a compile**: a 4-beat sine LFO at
120 BPM sweeps layer opacity across >0.5 of its range over two seconds and stays inside 0..1;
disabling it leaves opacity perfectly static. So beat-synced modulation genuinely runs in the Rust
core and reaches the packed frame the renderer reads.

Musical time crosses as an exact `Rational`, not a float — the modulation engine takes one precisely
so a three-hour set cannot accumulate drift.

**[DECISION] Did NOT wire the FFI into the app yet.** Linking the Rust staticlib needs changes to
`macos/Package.swift`, which **Codex owns**, and SwiftPM's `unsafeFlags` are rejected for non-root
packages — so a wrong move there breaks *his* build, not just mine. I proved the path works with a
standalone Swift binary instead (that's where the 6.4ns number came from) and left the integration
for a handover. Working with him, not around him.

## 01:45 — Workflow verify phase found two real clock defects

The adversarial review pass earned its keep. The clock implementer wrote 58 tests *and* did mutation
testing (24 deliberately injected defects, all caught) — and the independent reviewer still found
two genuine bugs that suite had missed:

1. **A REJECTED downbeat still permanently relabelled the bar.** The code rotated `bar_origin`
   before testing whether the correction passed the plausibility ceiling, then returned
   `Rejected` — reporting that nothing happened while having already moved which beat is "1". Every
   bar-quantised clip launch would shift by two beats, silently, with no way for the shell to see
   it. Fixed by judging the correction *before* applying either half.
2. A non-finite capture timestamp could mutate the clock.

Worth noting as a method point: **one agent's own tests, however thorough, are not a substitute for
an adversarial second pass.** Mutation testing caught 24/24 of the defects its author thought to
inject — and missed the two he didn't.

## 02:00 — C3 damage regions + cleanup

Added spatial dirty tracking to `ir.rs`, completing the C-series performance plan. The correction
Codex flagged is enforced by a named test: **a moving layer dirties where it WAS as well as where it
IS** — union only the new bounds and the layer smears a trail across the canvas, which looks like a
rendering bug and is actually bookkeeping. Also falls back to a full redraw when any node reads the
whole canvas (blur, feedback), since scissoring would hand it partially-stale pixels.

Fixed all 6 clippy warnings. **Current state: 226 core tests, 11 FFI tests, 9/9 GPU checks, 0 clippy
warnings, portability guard green.**

## 02:15 — Soft edge proven seamless

Added a two-projector overlap check to `PhotonVerify`: left projector covering x∈[-1,0.2] ramping
down through its right third, right projector mirroring it, 20% overlap band.

**The overlap band matches a single-projector reference to within 6/255, and the non-overlap regions
match to within 4/255.** So the blend is genuinely invisible — which is only true because the
composite is in linear light and the hardware does the sRGB encode. Blend this in gamma space and
the band lands at ~0.44 of correct brightness: a dark stripe straight down the middle of the screen.

That property is exactly the kind of thing you'd otherwise discover on site, at night, with a client
watching. **12/12 checks now.**

## 02:40 — Thumbnails (for Codex's clip grid)

`ThumbnailCache` — poster frames for the library. **A 128-slot grid does not mean 128 decoders**:
idle clips show a cached poster, only *playing* clips cost a live source. That distinction is what
makes a dense grid affordable.

Details that matter in practice:
- Runs at **`.utility`**, deliberately below playback — scrolling a library must never steal cycles
  from program output.
- **Disk cache as well as memory**, so a relaunch mid-gig is instant.
- **Concurrent requests de-duplicate** — a scrolling grid asks for the same tile repeatedly.
- Samples at **t=1s, not t=0**, because frame zero is often black (fades, leaders) and a library full
  of black tiles looks broken.
- **Invalidates when the media is newer than the thumbnail** — a stale tile is worse than none,
  because the operator launches a clip that looks nothing like its picture.
- An undecodable file yields `nil`, never a crash. A real library always contains something odd.

Verified against **your actual clips**, not fixtures. **17/17 checks.**

## 03:00 — Clip transport (a V1 feature the engine didn't have)

`Transport.swift` + wired into `VideoSource` and `PhotonEngine`. Resolume's model, because an
operator moving between tools shouldn't have to relearn it:

- **Timeline** — free-running, ignores tempo.
- **BPM Sync** — loop spans N beats; the playback **rate** is derived from tempo, so the clip always
  lands on the beat regardless of how its native length relates to the BPM. A 4s clip over 4 beats
  at 120 BPM plays at exactly 2×; halve the tempo and it halves. Both asserted.
- **Position** — driven by a parameter, so it can be modulated.

Plus playthrough: loop / once / ping-pong / random / hold-last.

Details worth keeping:
- **Loop preserves the remainder** rather than snapping to the in point — snapping quantises away
  sub-frame timing and drifts against the beat.
- **An inverted trim is repaired at construction**, not left to silently stall a clip forever with
  no indication why.
- **Hold-last keeps the final frame on screen.** Blackout stays an explicit operator action, never a
  side effect of a clip ending.
- ⚠️ **Honest limitation:** ping-pong restarts forward rather than playing backwards. AVPlayer can't
  reverse compressed media reliably, so faking it would stutter. Flagged rather than pretended.

**26/26 checks**, and `bpm` lives on the engine so a tempo change lands on all synced clips in the
same frame — staggering it would visibly break the lock.

## 03:20 — Output topology (the mapping document)

`OutputTopology.swift` — screens → slices, **stored separately from the composition**, because the
same show travels to a different venue with a different rig. You don't want to re-cut a show to
re-hang it.

The abstraction that makes big rigs possible: **a projector is a rectangle inside an output canvas,
not "a display."** An M4 drives 4 external displays at most, so a 16-projector show runs through
splitters (Datapath FX4, DisplayPort MST) where one output carries four projectors side by side.
Model a projector as a display and that rig is impossible; model it as a rect in a canvas and it's
ordinary.

`OutputTopology.splitter(projectors: 4)` builds that rig in one call — a 7680×1080 canvas, 4 slices,
each sampling its quarter of the composition, with **soft-edge overlap only on interior edges**
(verified — if the outer edges faded too, the image would dim into black at the ends of the rig).

Mapping round-trips to disk as JSON, and a disabled screen drops out of output without losing its
mapping. **An empty or fully-disabled mapping falls back to a full-canvas slice rather than going
black** — blackout stays an explicit operator action, never a config accident.

**35/35 checks.** App still builds.

## 03:35 — Fixed a build break of Codex's, then test patterns

**The app stopped building.** Codex had added a shared one-shot media scan (good idea — better than
what I had, and correctly at `.utility`), but it referenced `Self.mediaURLs()` in a *static stored
property initializer*, which Swift disallows. One-word fix: name the type explicitly. Noted in the
handover rather than silently edited, since it's a file I own that he improved.

**Test patterns** (V1 Advanced Output checklist): alignment grid, crosshair + edge border +
circle, and colour bars with a greyscale ramp.

The verifier caught two real bugs in them, and they're the kind that only bite on site:

> **My line widths were a fixed fraction of the canvas, so they were resolution-dependent.** At
> 64px a 0.0015 line is sub-pixel and vanishes; at 4K it'd be fat. An alignment aid whose
> thickness changes with resolution is worse than useless. Now derived from **screen-space
> derivatives (`fwidth`)**, so lines are ~1px at any output size.

The third failure was my *test* sampling the wrong row — the warp stage flips vertically. Rather
than hard-code the corrected row (a coin flip), the test now scans for the ramp.

Patterns are deliberately chosen for rigging, not decoration: thirds lines to judge centring from
the back of a room, a border **exactly** at the edge so a missing one means the slice is
overscanning and cropping content off the surface, and a greyscale strip for gamma matching between
projectors.

**42/42 checks.**

## 03:50 — 🔓 DXV compression CRACKED (DXT1 path), and a hard finding about your library

The DXV agent derived the format and verified it **byte-exact on 119 frames across 44 files** —
without ever opening FFmpeg's LGPL source. Clean-room, so no licensing entanglement.

**How it cracked it, which is genuinely clever:** it patched a `.mov` to contain a deliberately
*invalid* back-reference, because ffmpeg's error message leaks both the computed distance and the
output cursor. That turns ffmpeg's decoder into a bit-accurate instruction tracer. It then
enumerated all 127 bit-prefixes of length 0–6 and fitted the model to every observed pair.

**The format:** output is 4-byte LE units (a BC1 block = 2 units: colour word, index word). Buffer
zero-initialised. First 8 bytes are an unconditional literal seed. Then 2-bit ops, LSB-first, from
lazily-refilled 32-bit mask words: `01` copy previous block, `10`/`11` copy at short/long distance,
and `00` = **SPLIT**, which codes the colour and index words independently. That SPLIT layer is
what my earlier arithmetic was missing — the common "new colour, same indices" case.

Strongest evidence: it *encoded* a random texture with its own model and ffmpeg decoded it
correctly, so the model is right in **both** directions, not merely permissive.

### 🔴 But: your entire library is DXT5, and that path is NOT solved

I ran a tag census over the Trees Have Eyes folders: **56 × DXT5, 2 × YG10, 0 × DXT1.**

So the solved path covers **none of your actual media**. DXT5 isn't a nice-to-have — it is the one
thing standing between this engine and your real content.

The agent had reported it couldn't find real Resolume samples to work from; it had searched the repo
rather than your projections folder. **It now has all 56.** I've resumed it on DXT5 with the file
paths and the specific leads from its own notes (it suspects multiple independent sub-streams before
the op loop; a BC3 block is 4 units vs BC1's 2).

It keeps returning `Error::NotDerived` rather than plausible garbage for DXT5 — correct call. A
decoder that silently produces wrong pixels during a show is far worse than one that admits defeat.

## 04:10 — Per-slice colour correction, then the hybrid compositor

**Per-slice colour correction** (V1 checklist): gain, lift and gamma per projector, because
projectors never match out of the box — different lamps, different ages, different panels. Applied
in **linear light, before the soft-edge weight**, so trimming one projector's colour cannot disturb
the overlap sum. Verified that a per-channel gain trims only that channel.

**The hybrid compositor is now real.** This is the thing V3 said to design for on day one:

> A layer with effects **must be materialised** before its effects can run — which is exactly the
> intermediate the register fold exists to avoid.

So the planner splits per frame: layers with no effects stay in the folded path and cost nothing;
layers with effects break out, render their chain into a private target, and **rejoin the stack as
an ordinary source texture**. One mechanism, both cases, no special-casing bolted on later.

Six effects to prove the infrastructure (blur, RGB shift, levels, pixelate, kaleidoscope, invert) —
native MSL for now; ISF is still the plan, and these get replaced when the GLSL translation lands.
Effects are flagged `isNeighbourhood` so the planner knows which ones read beyond the current pixel
and therefore disable damage-region scissoring.

**The verifier caught a crash before I shipped it:** effect targets are `.private` storage (correct
for production), and reading one with `getBytes` is a hard **segfault**, not an error. The test now
blits to shared storage first. Worth noting the test asserts something easy to get wrong and
invisible until it corrupts a live show: **a chain pass must never write back into the caller's
texture.**

**55/55 checks. App still builds.**

## 04:40 — Adversarial review of graph.rs + modulation.rs: four more defects

Independent reviewer found four genuine bugs the authors' own suites missed. **237 tests now**, 0
clippy, portable.

**The serious one:** `graph.rs` accepted or rejected *the same graph* depending on **node insertion
order**. Domain resolution did one forward and one backward sweep over a topological order, but
propagated across *delayed* (feedback) edges too — and a delayed edge can run backwards through
that order, so a node could be skipped by both sweeps and fall through to a CPU default, then fail
validation.

Repro is an ordinary GPU feedback/trails chain. Add the nodes one way → fine. Add them the other
way → `ImplicitCrossing` error naming an edge the operator never authored. Live, that's **a patch
that loads today and refuses to plan tomorrow** after someone deletes and re-adds a layer. Fixed by
iterating to a fixed point.

**The quiet one:** a zero or NaN frame delta made every audio follower **snap straight to the raw
band level**. The guard folded two opposite cases together — a bad *time constant* meaning "instant"
is right; a bad *frame delta* meaning "instant" is backwards, because no time passed so the filter
must not move. `dt = 0` happens on paused transport and on the first frame. The output is a
perfectly plausible number, so nothing reports it.

Plus: `CookGraph::new` accepted a negative composition rate (handing the scheduler a negative
period), and re-registering a parameter path updated its spec but not its pre-frame value, so after
a reload the UI drew the *previous* document's fader position.

## 04:50 — Demo rebuilt around the real engine

`PhotonEngineDemo` now drives `PhotonEngine` rather than the compositor directly, so one path is
exercised everywhere. Keyboard-drivable: layers, blend mode, **test patterns**, **keystone**,
**rig (single / 2-projector / 4-projector splitter)**, **per-projector colour trim**, effects,
media on/off.

Two things found while wiring it:
- **Per-slice colour wasn't persisting.** I'd added gain/lift/gamma to the runtime slice but not the
  *serialisable* one, so a venue's colour trim would have been lost on save. The compiler caught it.
- **The display link must start in `viewDidMoveToWindow`, not `init`** — it needs an attached,
  visible layer, and creating it early silently yields a window that never draws. Same bug class as
  the original black preview; worth writing down twice.

⚠️ **Note for running it:** launch the demo from a normal GUI session (`cd engine && swift run -c
release PhotonEngineDemo`). Launched from a background shell the window never comes to front and
macOS throttles the display link to ~0 fps — it renders, just not visibly.

## 05:05 — Polygon masks (Advanced Output checklist now essentially complete)

Per-slice polygon masks with **feathered edges**, for cutting output away from architecture that
must not be lit — a doorway, a window, the edge of a building.

Implemented as a signed-distance test rather than a boolean, specifically so the edge can be
feathered: a hard binary mask aliases badly on a projector, where the operator is looking at a
boundary several metres wide.

Verified, including the case a weaker test would miss: **concave polygons**. A convex-hull-only
implementation would light the whole bounding box and still pass a naive check. The test asserts on
the *shape* — that a meaningful fraction of the bounding box is dark — which also makes it immune
to the warp stage's vertical flip.

My first version of that test was simply wrong (I picked a corner that is genuinely *inside* the
L-shape). Worth recording: **a test being wrong is its own failure mode**, and that's now three
times tonight.

Masks persist with the mapping, like the colour trim — both belong to the venue, not the show.

**61/61 checks.** V1 Advanced Output parity checklist: quad/keystone ✓ grid warp ✓ masks ✓
soft edge ✓ per-slice colour ✓ test patterns ✓ multi-screen ✓ output presets ✓

## 05:25 — Audio analysis, and a design flaw the test exposed

`AudioAnalyser` — FFT band envelopes via Accelerate, the signal behind audio-reactive visuals.
Deliberately **separable from live capture**, so it can be verified with synthetic tones instead of
requiring a microphone and a human listening to it.

**The verifier caught a genuine design flaw.** My first version took the **mean** of the bins in
each band. That penalises width: the high band spans ~300 bins and the low band ~5, so a pure 8 kHz
tone averaged to *nothing* while a 60 Hz tone read strongly. In practice the bands would have been
wildly unbalanced and the high band nearly dead — and it would have looked like "treble just
doesn't do much", not like a bug.

Fixed to use **energy in the band**, so a given tone reads comparably wherever it sits and genuinely
broadband content reads higher, which is what an operator expects.

Other decisions worth keeping:
- **Asymmetric smoothing** — fast attack (5 ms), slow release (120–220 ms). A hit should land on the
  frame it happens; the decay should not. Verified the release is gradual rather than instant.
- **Hann window**, because a rectangular one smears a pure tone across bins and makes band
  separation look broken when it isn't.
- **A per-band threshold**, so room noise doesn't animate every parameter all night.
- **The same `dt` correction the core review surfaced**, applied here independently: a zero or NaN
  frame delta **freezes** the envelope rather than snapping it. Bad time constant = instant is
  right; bad frame delta = instant is backwards.

**69/69 checks.**

## 05:40 — MIDI

Parser deliberately separated from CoreMIDI so it can be tested against byte sequences rather than
requiring hardware — because the bug-prone part of MIDI isn't the plumbing, it's the protocol's
quirks. All of these are now covered by tests:

- **Running status.** A well-behaved controller omits the status byte on repeated messages, so a
  parser that assumes one per message **drops most of a fader sweep**. It presents as "the fader
  feels laggy", never as an error. Verified a 4-message sweep arrives intact.
- **Velocity-0 note-on is a note-off.** Most controllers send this instead of a real note-off.
  Treat it as an on and pads stay latched and clips never stop.
- **Realtime bytes can appear mid-message** — a clock byte between a note's data bytes must not
  corrupt it. Verified.
- **Messages split across packet boundaries** must still assemble.
- **MIDI clock → tempo**, averaged over two quarter notes because single-interval jitter makes a
  derived BPM visibly unstable, with implausible intervals rejected so one dropout can't drag the
  average. Verified: derives 120 BPM exactly, and stays within 2 BPM through a dropped tick.

Also the outbound half, which is the one people forget: **pad feedback**. The pads on an APC40 light
up to show what's playing — that's *why* the control protocol is state-sync-first rather than
request/response.

**80/80 checks.**

## 05:55 — Live audio + MIDI capture, and a hang I caused and caught

Wired `AudioAnalyser` and `MidiParser` into live capture (`AVAudioEngine` tap, CoreMIDI) and onto
the engine, so they aren't orphaned modules. MIDI is drained once per frame and **external MIDI
clock is adopted automatically**, so BPM-synced clips lock to a DJ's tempo with no configuration.

**Then the verifier hung for two minutes — on code I'd just written to "fail soft".**

`AVAudioEngine` start was triggering a **microphone permission prompt**, which blocks until
answered, and from a non-bundled binary can block indefinitely. An engine that stalls waiting on a
dialog has failed in precisely the way that class exists to prevent. On stage it would be worse
than a crash: silent, total, and with no error to read.

Fixed: **never trigger a permission request from the engine.** Check
`AVCaptureDevice.authorizationStatus` and return a status string if it isn't already granted.
Requesting permission is the *app's* job, up front, where a human is looking at the screen.

That's the right behaviour regardless of the test — but I'd have shipped it without the verifier,
because it works fine once permission has been granted. It only hangs the *first* time, which is to
say: on someone else's machine, at a gig.

**88/88 checks.** Also bounded the MIDI queue — a controller sending clock at 48 Hz fills it if
nobody drains, and dropping old control messages beats growing without limit during a show.

## 06:15 — Clip grid backend (Deck)

The engine side of what Codex's grid will drive. Resolume's model:

- **A column fires every layer at once** — that's the primary gesture; a column is a "look", not a
  list.
- **Launches are quantised engine-side**, not by the caller, so a grid click, a MIDI pad, OSC and a
  remote all land on the same beat.
- **An armed cell reports time remaining.** An operator needs to see their press registered or they
  press again — so quantisation needs a *pending* state, not just a delay.

Details that came from thinking about the gig rather than the code:
- **Triggering an empty cell is a no-op, not a clear.** Hitting an empty pad by accident mid-show
  must not black the layer. Clearing is explicit.
- **Re-triggering replaces the pending launch** rather than queueing a second one — the last press
  wins, which is what a human expects when they change their mind before the bar lands.
- A launch **exactly on** a boundary fires that frame rather than slipping to the next, and a
  trigger *at* a boundary goes to the *next* one rather than firing twice.

Musical time is injected rather than owned, so it's testable without a running clock and the
authoritative clock can stay in `photon-core`.

**98/98 checks.**

## 06:30 — Deck wired into the engine and the demo

The grid now drives the engine: triggering a cell or column reloads **only the layers that actually
changed**, rather than rebuilding the stack. The demo populates a 3×8 grid from whatever media is
in `media-cache/`, with **number keys 1–8 firing columns** and `=` cycling quantisation. That makes
it an actual VJ surface rather than a render test.

**[DECISION] The engine carries a provisional beat counter.** The authoritative clock is
`photon-core/src/clock.rs` and carries the parts that matter — separable tempo/phase sources, slewed
correction rather than jumps, tap tempo with outlier rejection. The engine's is a plain accumulator
so the deck could be built and tested *before* the FFI is linked into the app.

It's commented in the source as **provisional, to be replaced not grown**, because this is exactly
how a codebase ends up with two clocks that disagree — and a show syncing to the wrong one is the
kind of bug nobody finds until it matters.

**102/102 checks.**

## 06:50 — ISF loading (the "hundreds of effects for free" play)

ISF is the VJ world's de facto shader standard — GLSL plus a JSON manifest — and VDMX and Resolume
both support it. `ISF.swift` parses the manifest, maps inputs to our parameter model, and
**translates the GLSL to MSL**.

**The test that matters is that the generated MSL actually compiles**, not that the translator ran
without throwing. A transpiler that emits plausible-looking garbage passes every string check and
fails at `makeLibrary`. Verified end-to-end on a real saturation shader: `vec4`→`float4`,
`IMG_NORM_PIXEL`→`texture.sample`, `gl_FragColor =`→`return`, uniforms lifted into a struct and
rebound to the names the author wrote — then compiled as Metal and the entry point retrieved.

**Honest scope, enforced:** this handles a documented subset. Multi-pass shaders, persistent
buffers, feedback sampling, screen-space derivatives and `#version` pragmas are **rejected with a
specific reason**. That's deliberate — a shader that fails to load is a line in a log; a shader
that loads and renders subtly wrong is discovered on site, at night, with a client watching.

**112/112 checks.**

## 07:15 — Recording program output

`Recorder` — VideoToolbox H.264 via `AVAssetWriter`, fed from the composited texture. For capturing
a set, and for producing evidence when something goes wrong on site and nobody can reproduce it
afterwards.

My first version was too naive — it handed frames straight to the encoder and dropped whenever it
wasn't ready (12 of 30 made it). Rebuilt around the shape the runtime contract actually specifies:
**a bounded queue with a background drain**, so the render thread hands off and never waits, and
the encoder is waited on *off* that thread.

The bound is deliberate: **8 frames ≈ 130 ms at 60fps** — enough to ride out a disk hiccup, short
enough that a genuine stall gets reported instead of silently growing memory during a show.

**Then the test still failed, and the recorder was right.** `expectsMediaDataInRealTime = true`
tells AVFoundation "this is live, drop rather than stall" — exactly correct for a show recorder,
which must never apply backpressure to the renderer. My test blasting 30 frames instantly was
testing a scenario that cannot occur. **Paced the test to real time rather than weakening the
recorder**, which would have been the easy and wrong fix.

Verified it produces a file that **something else can actually decode** — an `AVURLAsset` loads it,
finds a video track, and reports the right dimensions. "The file exists" is not the same as "the
file plays", and the difference is only discovered when you need the recording.

Drops are surfaced in the summary and the status string, never swallowed: a recording quietly
missing a third of its frames is worse than no recording.

**120/120 checks.**

## 07:30 — Cue list and autopilot

Arena ships an Autopilot toggle (it was in the feature inventory I extracted), so here it is.

Two jobs that share one structure, and **conflating them is the classic mistake**:
- **Cue list** — a human presses GO and the show steps. Theatre, corporate, anything cued to
  something happening in the room.
- **Autopilot** — the show advances itself after a musical hold.

Same list, different trigger — which matters because an operator switching modes mid-show must not
lose their place. `go()` behaves identically in both, so taking manual control is always available.

Three decisions worth keeping:
- **A cue with no hold halts autopilot.** That's how you build a show that runs itself up to a
  point and then *waits for a human* — which is most real shows.
- **The list stops at the end by default**, rather than silently looping back to the top. Looping
  is opt-in; a show that quietly restarts is rarely what anyone wanted.
- **Autopilot fires through the deck, not around it**, so an automatic advance is quantised exactly
  like a manual press. Routing it separately is how you end up with auto-advances that land off the
  beat while manual ones don't.

**135/135 checks.**

## 07:35 — A stale-cache trap worth knowing

`macos` failed with **`cannot find 'CueList' in scope`** while `engine` built fine standalone.
SwiftPM had cached the dependency's source list and never picked up the newly-added file — the
stale `PhotonRender.build/sources` simply didn't contain it.

`swift build` does not recover from this, and the error points at the *consuming* file rather than
the real cause, so it reads like an ordinary compile error. Fix is `rm -rf macos/.build` (~55s).
Flagged to Codex, since adding engine files is now routine and he'd lose the same twenty minutes.

## 07:50 — `.photon` documents through the FFI (one schema, no fork)

The shell now loads and validates documents **without modelling them**. It passes JSON in and gets
JSON out; **Rust is the only thing that knows the schema**.

That's the point. A Swift mirror of the document would eventually drift from the Rust definition,
and a drifted schema means *a project saved on the Mac failing to open on Windows* — a product
failure, not a maintenance annoyance. This design makes that impossible rather than merely
discouraged.

Verified from Swift (not just Rust): a default document is 470 bytes, self-validates, and garbage
is rejected with a message an operator could act on —

```
unknown field `nope`, expected one of `schemaVersion`, `meta`, `composition`, ...
```

That matters more than it looks. "Invalid document" tells someone standing in a venue nothing. A
document saved by a *newer* build also says so explicitly rather than failing cryptically.

Also tested: normalisation is **idempotent**, and every malformed input — empty, `{`, `null`, `[]`,
a wrong-typed field, a null pointer — is rejected without panicking.

**16 FFI tests.**

## 09:20 — OSC in (the bugs are all in the alignment rules)

`engine/Sources/PhotonRender/OSC.swift`. Full OSC 1.0: ints, floats, strings, blobs, booleans,
null, impulse, bundles, and a `NWListener` over UDP that fails soft and bounds its queue at 512
like the MIDI input.

Parsing is a separate type from the socket so it can be tested against byte sequences. That split
is the whole point — **every OSC bug is in the 4-byte padding rule**, and a parser that silently
mis-aligns is worse than one that rejects: an operator sees a fader move the wrong parameter and
has no way to tell why.

The classic off-by-one is an address whose length is *exactly* a multiple of 4: it still needs a
full four bytes of padding, not zero. There is a check for precisely that.

Malformed input is rejected rather than half-parsed: empty packets, an address not starting with
`/`, an unterminated string, a truncated argument. **12 checks, engine at 147/147.**

## 09:55 — MIDI learn / control mapping (`photon-core/src/learn.rs`)

The feature Aiden named for V1 — *"we will need midi mapping ability"*. It went in the **portable
core**, not the shell, because mapping is pure logic and writing it twice is how a Windows port
becomes a rewrite. The shells own transport; everything after decode is shared.

Built on the existing `ParameterRegistry` rather than beside it — the three-range parameter model
already there is what a mapped control sweeps.

Four behaviours that experience says have to be right, each with a test naming the failure:

- **Learn does not latch onto noise.** A cheap fader idles by oscillating a value or two. Arm a
  parameter next to one and it binds before the operator touches anything — and they then have to
  find and undo a binding they never made. A continuous control must *move* ≥2% of travel, measured
  from the moment of arming, not from whenever it was last touched.
- **Rebinding reports what it displaced.** Surfaces run out of pads long before a show runs out of
  parameters. A pad silently stolen from blackout is how a show loses its panic button mid-set with
  nothing on screen to explain it. `Routed::Learned` carries the displaced assignment.
- **Pickup.** Switch banks and the physical fader sits at 0 while the layer sits at 0.8; touch it
  and the layer slams to black. The parameter is held until the control passes *through* its current
  value. This is the difference between a mapping usable live and one that is not.
- **Note-on with velocity 0 is a note-off.** In the spec, emitted constantly by real hardware under
  running status, and missing it leaves pads latched on.

Also: inverted ranges (reversed endpoints, no separate flag), sub-ranges (a fader that must never
fully black a layer), four response curves with exact endpoints, toggle latches with a
`sync_toggle` for when two pads drive one target and disagree, duplicate-target auditing, and
`unresolved()` listing what a map loaded against a different document cannot find.

**275 core tests, 0 clippy, still portable** (CI self-test passes).

## 10:30 — The mapper reaches the app (and the core stops being unused)

Found while wiring it: **the app validated the ABI and then never created a handle.** The clock,
modulation and mapper were written, tested, and doing nothing. That's now fixed end to end.

**[DECISION] Control crosses as packed structs, not JSON.** The document API uses JSON precisely so
Rust owns the schema — but a JSON *outcome* would need a Swift type to decode into, and that type
would be a second definition of the mapping model, free to drift. Discriminants are cheap; a forked
schema is not. Saving the map **is** JSON, because there the schema is the file format.

Caught in my own code before it shipped: `boundPath` serialised and re-parsed the entire map per
event, which on a fader sweep is hundreds of full JSON round-trips a second. Replaced with
`photon_control_bound_path`, a direct lookup.

New: `photon-ffi` control API (11 entry points, every one null-safe), `PhotonControl.swift` and
`PhotonCoreSession.swift` in `PhotonCoreBridge`, `ControlEvent.swift` in the engine collapsing MIDI
/ OSC / keyboard to one shape, and `ControlRouting.swift` in the app joining the two.

`PhotonCoreSession` owns the handle and frees it in `deinit` — a class, not a struct, because two
owners of a C pointer is a double free. It is **not thread-safe by design**: control arrives on
CoreMIDI's and the network's threads and is *queued* for the render thread. A lock would hide a
priority inversion inside the frame loop, the one place that cannot wait on anything. The queue is
bounded at 512 and drops the **oldest** — in a flood the newest reading is the true one, because an
operator's hand is where it is now.

**27 FFI tests. Engine 160/160. `PhotonCoreCheck` now proves control and session behaviour against
the actually-linked library**, including stride checks (same-size field reordering is invisible
until a value is subtly wrong) and that velocity 0 does not re-fire an action.

## 10:45 — DXV: DXT1 verified on real media, DXT5 still the blocker

The delegated agent came back with **23,823/23,823 frames byte-exact** across 36 real Resolume
DXT1 files, 4K and 1080p, verified against ffmpeg. The earlier census was wrong: the library is
**192 files — 37 DXT1, 109 DXT5, 9 YCG6, 11 YG10**, so DXT1 is ~20% rather than 0%.

Two findings worth more than the decoder itself, both verified:

- **DXV stores premultiplied RGB** — `out = min(255, c*255/a)`, passing `c` through when `a == 0`.
  Skip it and every real DXT5 asset renders visibly dark.
- **BC3 colour blocks always use 4-colour interpolation.** The `c0 > c1` 3-colour test is BC1-only;
  using the BC1 rule mismatched ffmpeg on 971/4096 texels.

DXT5 (`DXTR5` in ffmpeg's own trace) is a genuinely different codepath. Known: op granularity is
the 8-byte half-block with a *position-dependent* code table, block-aligned `00` is a run of N+1
whole blocks, `11` is an 8-byte literal. Unknown: block-aligned `01`/`10`, and what separates
mid-block `00` from `11`. Best partial model desyncs after 316 of 106,242 bytes — the agent said so
plainly rather than shipping it, which is the right call. Resumed on exactly those three slots.

## 11:20 — One clock, and the core's wins

`PhotonEngine` had a provisional beat accumulator with a comment saying it must be replaced, not
grown. Replaced: `adoptMusicalTime(beat:bpm:)`. From the first call the local accumulator **stops**.

That mutual exclusion is the point. Running both would mean two clocks disagreeing by a fraction of
a beat — which presents as a clip launch landing a frame early, with nothing in the symptom to
point at the cause.

A backwards jump is honoured rather than clamped, because a resync is *supposed* to move time. NaN,
zero and infinite tempo are refused: one NaN in the beat makes every quantised launch undefined for
the rest of the show.

## 11:40 — Audio reactivity, with the envelope applied exactly once

Aiden asked for *"music beat integration for these effects and the way the videos play"*. The wiring
now exists end to end, and the design decision in it is which side smooths.

Both sides had an envelope follower: `AudioAnalyser` (attack/release per band) and `modulation.rs`
(attack/release per binding). Feeding one into the other is **not twice as smooth** — it is laggy
and mushy, and it is exactly the kind of fault that gets blamed on the audio interface.

**[DECISION] The core owns the envelope; the shell pushes raw band energy.** `AudioSnapshot` now
carries `rawLevels` beside `levels`. Raw goes to modulation, because attack/release live with the
binding and are therefore shared with the Windows shell. Smoothed stays for the meter, which is
what a meter should show.

**[DECISION] The core decides which bands exist.** They are derived from what is bound, so a
composition with nothing audio-reactive runs **no filter bank at all**, and one bound to a single
bass band runs exactly one. `AudioAnalyser.setBands` makes the analyser reconfigurable to match.

Caught while writing it: `rebuild_modulation` wipes the whole modulation engine on every stack edit,
so an audio binding would silently die the moment a layer was added — "I mapped the bass to layer 2,
then added a layer, and it stopped working." Audio bindings are now held as **intent** on the handle
and replayed on rebuild. A binding whose layer is deleted is *kept*, so re-adding the layer restores
the mapping rather than making the operator redo it. There is a test for exactly that.

**33 FFI tests. Engine 178/178.**

## 11:55 — A real fix, not a weakened test

Three recorder checks failed: 5 of 20 frames accepted, the rest dropped on a full queue, and the
file came out with no video track. The machine was saturated by the DXV agent at the time.

The tempting move was to loosen the assertion. The actual cause was that the encoder drain ran at
`.utility` — wrong QoS for something the operator explicitly asked for. Under load it was starved,
the bounded queue filled, and the recording quietly came up short. Raised to `.userInitiated`,
still *below* the render thread, which is the constraint that actually matters: the show must never
wait on the encoder.

**178/178, three runs in a row, with the machine still under load.**
