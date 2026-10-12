# Codex Handover — Photon

**Read top to bottom. Updated 2026-10-12 with Aiden's latest decisions.**
`PLAN.md` is the index and lists which proposal is adopted — **read it first.**
Build agreement: `docs/scaffold.md`. Frontend ownership/integration: `docs/frontend.md`.
V2/V3 files are review history. Aiden has authorised the frontend build.

---

## 1. The project

**Photon** — a realtime media server and projection-mapping engine. Resolume Arena's
clip/deck/compositor model fused with the parts of TouchDesigner that make it fast (a compiled node
graph where changed/temporal dependencies determine work and CPU/GPU crossings are explicit).

**Repo:** `/Users/aidenwood/Desktop/00 - Aidxn/Aidxn/Main Projects/photon`
**Owner:** Aiden Wood / Aidxn Design (personal brand). Personal project, not work.

---

## 2. ⭐ Settled decisions — all from Aiden, 2026-10-12. Do not reopen these.

**Platform**
- **Mac is the target market.** Native macOS app: Swift + hand-written Metal + MSL. Performance goals
  are set and verified on macOS.
- **Windows is a requirement but later**, and ships as a **fully separate repo** — own renderer, own
  shaders, own UI, own platform I/O, own release cadence. Feature drift between shells is fine.
- **`photon-core` is one shared versioned Rust crate** consumed by both apps, never vendored-and-edited.
  Owns the `.photon` document schema, codecs, compositor IR and control protocol. Native GPU
  execution is preserved; CPU scheduling and bridge costs must be measured.
- **🔴 Hard rule: no Apple API in `photon-core`, ever.** Platform capabilities go behind Rust traits,
  implemented per-shell. Enforce with a CI check. Breaking this turns the Windows port into a rewrite,
  quietly, months before anyone notices.
- **No browser in the render path.** Web and iOS are *remote control surfaces only*, later phases.

**Performance spec** *(this is the bar — see §1.5 of V2-claude)*
- Tier **A**: 4 layers @ 120fps · Tier **B**: 8 layers @ 60fps · Tier **C**: 12 layers @ ≥30fps.
- A and B are the same number: **480 layer-frames/second.** Report in layer-frames/sec, not fps.
- **1080p source** ("the usual projection size"). 4K is later, not the spec.
- Target hardware: **base M4 / 32GB** — Aiden has one. The M4 Max dev box has ~4× the bandwidth and
  ~4× the performance cores; runs on it must be tagged `DEV-BOX-INVALID`.
- **Output canvas is a separate axis from source resolution** — users set arbitrary projection
  mapping outputs. A 4-projector rig is 7680×1080, more pixels than 4K. Sweep both independently.

**Features**
- **Advanced Output at Resolume parity is V1**: keystone/quad + bezier + grid warp, polygon masks,
  soft-edge blending, per-slice colour correction, test patterns, output presets stored separately
  from the composition.
- **Two day-one pipeline decisions**: projective (homography) UV interpolation for warps, and a
  **linear-light compositor** with encoding only at output. Retrofitting either is a rewrite.
- **MIDI learn-mode mapping on any parameter**, addressed by path, with **bidirectional state push**
  (pads light up on an APC40). V1.
- **Blend modes** (mask, difference, …) need destination access, which Metal's fixed-function blending
  can't express → **register folding**: one shader samples all N layers and folds in registers,
  specialised per blend-mode stack.
- **~30 built-in effects, shipped as ISF** (Interactive Shader Format — GLSL + JSON manifest). ISF is
  the VJ world's standard; hundreds already exist free. GLSL→MSL/WGSL translation via `naga` lives in
  the core.
- **UI**: Affinity-style persona shell — **Perform** / **Map** / **Sources** (PRE, later) / **Effects**
  (POST, later). Thin chrome, canvas-first, `⌘K` palette.
- **No moveable/dockable UI — cut.** Ship a few fixed **UI templates** per persona; layouts are a
  declarative struct tree so templates are just different trees.
- **Sources and Effects personas lazy-load and unload** — but **editors only**. Compiled pipelines and
  running sources stay owned by the engine; closing a pane must never black a clip.
- **Control is transport-agnostic**: one message set, many adapters — LAN WebSocket, **Bluetooth LE**
  (control only, *no preview* — BLE gives single-digit KB/s), internet relay (outbound-only, token
  auth), **MIDI** (USB + BLE-MIDI), OSC, Art-Net in. Protocol is **state-sync-first**, sized for BLE.

---

## 3. Latest direction from Aiden

Start the native front end now. Codex leads the front end; Claude leads the engine and is obtaining
Xcode. Use Aiden's Velocity work as the visual reference. Keep components small, with their own
loading, error and retry states. Build the app; performance tests and benchmark runs are deferred.
Aiden confirms the remaining planning questions were answered with Claude. Do not ask them again.

---

## 4. Ownership

| | Claude | Codex |
|---|---|---|
| Primary | `photon-core/`, native runtime/FFI targets, Metal/MSL, codecs and binary analysis | `macos/Sources/PhotonApp/`, `macos/Sources/PhotonUI/`, frontend tests, local app/run wiring |
| Secondary | Engine-side measurement and benchmark contract review | `bench/`, corpus and independent performance review; later web/iOS remotes |

The previous rule excluding Codex from all of `macos/` is superseded by Aiden's instruction.
Engine target additions to `macos/Package.swift` need a concrete handover to its frontend owner.
Codex hosts engine-owned GPU surfaces through `ProgramSurfaceFactory`; native rendering stays
Claude's responsibility. Shared plans/contracts can be updated in place by either agent.

---

## 5. Current frontend scaffold

`PhotonApp` is the small native entry point. `PhotonUI` holds separate library, deck, preview,
inspector, transport, mapping/output and telemetry components, plus shared loading/recovery views.
`PanelModel` retains good data and rejects cancelled/stale requests. `WorkspaceProvider` is the
injected service boundary; display DTOs do not replace the generated document/control schema.

Run from the project root: `./script/build_and_run.sh`.
Local bundle: `macos/.build/local-app/Photon.app`. Codex Run uses the same script.
The current provider is explicitly a UI preview fixture. Media decoding and real output are not
implemented by this frontend scaffold. See `docs/frontend.md` for integration and current limits.

**Benchmark work remains later:** freeze configs and record actual target hardware. Preserve the
performance review's fairness and telemetry contracts. Do not launch benchmark runs while Aiden
wants app construction first.

---

## 5b. 🎯 Handover from Claude — 2026-10-12. Four things for you, one request.

*Aiden: "make sure you work with codex and not against". This is what I've landed that touches your
lane. Nothing here edits your files — flagging, not changing.*

### ① `docs/resolume-ui-reference.md` — read this before more grid work
Aiden: *"grid needs to copy resolume"*, *"especially the front end"*.

Arena ships its **entire UI layout model as plain XML** in `/Applications/Resolume Arena/default/
Presets/Interface/*.xml`. I read the authoritative structure directly — no decompiler. Headlines:

- **`LayersAndClips` is ONE panel.** The layer strip and clip grid share a panel and scroll
  together; they are not separate surfaces. Easy to get wrong and it's the heart of "copy Resolume".
- Layout = nested **`FlexContainer`** with `orientation` + `*_desired` sizes, stable integer
  `panel_id`s, `TabbedContainer`s grouping panels. **This matches the declarative struct tree we
  already specified** — we arrived at it independently and it's confirmed against the real thing.
- **Arena ships nine named layouts** (`Minimal`, `Many Layers`, `Panels Left & Right`, …) — direct
  proof that templates-not-docking is sufficient for a professional tool in this exact category.
- Two monitors by default: `Composition` (program, `showUI=0`) and `Preview` (`checker_board=1`,
  `showUI=1`). Six `subject_type`s exist.
- Inspectors tabbed by scope (Composition/Layer/Group/Clip/Column); browser tabbed
  (Files/Effects/Sources/Compositions).
- Full 34-item `Show *` feature inventory is in the doc.

### ② 🔴 Arena's parameter model is richer than ours — decide before you build parameter UI
Every Arena parameter carries **three** ranges, not one:
`defaultRange` (natural bounds) · `minMax` (user-narrowed) · `startStop` (animation sweep within).

Our modulation binding only has `depth`/`offset`/`curve`. A VJ wanting *"LFO sweeps opacity
0.3–0.7, and I've clamped this parameter to never exceed 0.8"* needs both. **Retrofitting ranges
touches every parameter in the app**, so this wants deciding now. Also: durations serialise as beat
literals (`"4b"`), and phase source is **per-parameter** with a `hardSynced` flag.

### ③ ✅ Your DXV corpus blocker is gone — and so is the HAP one's workaround
**ffmpeg ships a full DXV decoder *and* encoder.** No Alley, no GUI, no manual step:
```
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=60 -t 2 -c:v dxv -pix_fmt rgba out.mov
→ codec_name=dxv  codec_tag=DXD3  1920x1080  60fps  120 frames   (verified, decodes back exactly)
```
DXV frame header is 12 bytes: `fourcc("DXT1" LE) | version | compressed_size | payload`.
**Caveat for the engine, not for you:** ffmpeg's DXV decoder outputs RGBA — CPU-decoded, which
defeats the GPU-blocks advantage. It's our *corpus generator and reference decoder*, never the
runtime path. Playback demuxes the packet and extracts BC blocks itself.

The earlier handover line "Alley supplies DXV conversion" is now superseded — I've corrected it above.

### ④ `engine/` exists — standalone, does NOT touch `macos/Package.swift`
I built the render path as its own SwiftPM package at `engine/` precisely so I don't rewrite your
manifest concurrently (per §4). It runs today:

```
PhotonEngineDemo:  32 layers · 120 fps · p50 8.33ms · GPU 5.19ms · folded (dest-read)
```

Register-folded compositor, linear-light `rgba16Float` working target, single sRGB encode at
output, `CAMetalDisplayLink` presentation, all ten blend modes incl. the four Metal's
fixed-function blending cannot express. Procedural layers stand in for media so far.

**Two bugs worth you knowing**, since they'd hit any Metal view: assigning `layer = CAMetalLayer()`
after `wantsLayer = true` is *not* honoured — it must come from `makeBackingLayer()`. And
`CAMetalDisplayLink` hands you a drawable in its update; calling `nextDrawable()` yourself instead
leaves the window black.

### ⑤ 🎯 TICKET — parameter rows must be horizontal (Aiden, direct request)

> *"Make the menu items like opacity and its control horizontally stacked to show more controls
> listed on the screen like resolume"*

**Target:** `macos/Sources/PhotonUI/Panels/Inspector/*` — your lane, so I have not touched it.

**Ask:** parameter **label and its control share one row**, not stacked vertically. Resolume fits
dozens of parameters in an inspector precisely because each is a single horizontal line:

```
Opacity      ──────●───────  0.85
Blend        [ Screen      ▾ ]
Speed        ──●───────────  1.00
```
not
```
Opacity
──────●───────  0.85
Blend
[ Screen      ▾ ]
```

Vertical stacking roughly halves how many parameters fit on screen, and this is a tool where an
operator wants everything visible at once rather than scrolling mid-show.

**Suggested shape:** a single `ParameterRow` component — fixed-width label column (right-aligned
reads well), flexible control column, fixed-width numeric readout. Every parameter uses it, so the
columns line up down the panel.

**Also relevant from `docs/resolume-ui-reference.md` §4** — Arena's parameters carry **three**
ranges (`defaultRange` / `minMax` / `startStop`). If the row is being rebuilt anyway, worth deciding
the data shape now; retrofitting ranges touches every parameter.

### ⑥ 🎯 TICKET — link `photon-ffi` into the app (needs your manifest, so it's yours)

**Overnight 2026-10-12→13.** The Rust core is now real and reachable, but the last hop into the app
needs `macos/Package.swift`, which **you own** — and SwiftPM rejects `unsafeFlags` for non-root
packages, so if I guessed wrong here I'd break *your* build, not just mine. Hence a ticket.

**What's ready:**
- `photon-ffi/` — new crate, **the only one permitted `unsafe`**, so `photon-core` keeps
  `forbid(unsafe_code)` and keeps passing its portability guard. Builds a **staticlib** (nothing to
  ship, nothing to sign).
- `photon-ffi/include/photon_ffi.h` + `module.modulemap` already written.
- **Measured Swift→Rust: 6.4 ns/frame, flat from 1 to 32 layers.** The boundary is free; it is not
  a performance consideration. Details in `photon-ffi/FINDINGS.md`.

**What it gives the app:** beat-synced modulation running in the core. A 4-beat sine LFO at 120 BPM
driving layer opacity is tested end-to-end (`cargo test -p photon-ffi`). Today the engine animates
transforms with a local `sin()`; this replaces that with real musical time.

**The asks:**
1. Add a build step that runs `cargo build --release --manifest-path ../photon-ffi/Cargo.toml`
   before the Swift build (`script/build_and_run.sh` is yours too).
2. Add a `systemLibrary`-style target (or linker settings on the **root** `PhotonApp` target, where
   `unsafeFlags` are permitted) pointing at:
   - header/modulemap: `photon-ffi/include`
   - library: `photon-ffi/target/release/libphoton_ffi.a`
3. **Assert the ABI at startup.** Non-negotiable — a silently mismatched struct layout is the worst
   bug class at this boundary:
   ```swift
   precondition(photon_abi_version() == 1)
   precondition(Int(photon_layer_stride()) == MemoryLayout<PhotonLayer>.stride)
   precondition(Int(photon_frame_stride()) == MemoryLayout<PhotonFrame>.stride)
   ```
4. **Reply with the target name you create**, and I'll wire `PhotonEngine` to call `photon_tick`
   once per frame instead of animating locally.

**The one rule for this boundary:** `photon_tick` is called **once per frame** and returns a pointer
to N contiguous structs. Never call across per layer. That flatness is why it costs 6.4 ns, and the
benchmark proves it stays flat to 32 layers.

**Lifetime:** the returned `layers` pointer is valid **only until the next `photon_tick` on that
handle**. Read it within the frame; never retain it. Getting this wrong gives intermittent
corruption rather than a clean crash.

### ⑦ Engine state as of 02:30 — all green, all verifiable

| | |
|---|---|
| `photon-core` | **226 tests**, 0 clippy warnings, portability guard green (incl. `wasm32`) |
| `photon-ffi` | 11 tests |
| `engine` | **12/12 GPU checks** — `cd engine && swift run -c release PhotonVerify` |

`PhotonVerify` is an **executable, not XCTest** — because **XCTest requires full Xcode** and this
package deliberately builds on Command Line Tools alone. Worth knowing before you add a test target.

It renders real frames and reads pixels back, and it immediately caught three bugs I'd introduced.
If you touch anything in the render path, run it.

**Two render-path decisions now locked, both verified:**
- Shaders emit **linear**; the target is an **`_srgb` format** and the hardware encodes. There is no
  hand-rolled sRGB conversion anywhere — I deleted it rather than leave two conventions.
- Projector overlap blends in **linear space**, so a 2-projector soft edge matches a single-projector
  reference to within 6/255. In gamma space that band lands at ~0.44 of correct brightness — a dark
  stripe down the middle of the screen.

### ⑧ ⚠️ Fixed a build break in your shared-media change (03:25)

`macos` stopped building. `ProgramMetalView.swift` had:

```swift
nonisolated private static let developmentMedia =
    Task.detached(priority: .utility) { Self.mediaURLs() }
```

`error: covariant 'Self' type cannot be referenced from a stored property initializer`

Changed `Self.mediaURLs()` → `ProgramMetalView.mediaURLs()`. **Your design is right** — one bounded
scan shared across both monitors and across remounts is better than what I had, and the `.utility`
priority matches the thread/QoS map. Only the `Self` reference was the problem.

Flagging because it's a file I own that you improved, and I'd rather you know I touched it than
discover a silent edit. Build is green again.

### ⑨ Engine API now available to your UI (overnight 2026-10-12→13)

All in `PhotonRender`, all verified by **112 GPU/engine checks**
(`cd engine && swift run -c release PhotonVerify`). These are ready for the UI to drive — you
should not need to invent any of this:

| You need | Use |
|---|---|
| **Clip grid** | `engine.deck` — `Deck(layers:columns:)`, `triggerColumn(_:)`, `triggerCell(layer:column:)` |
| **Cell render state** | `deck.state(layer:column:atBeat:)` → `.empty / .idle / .armed(beatsRemaining:) / .playing` |
| **Grid thumbnails** | `ThumbnailCache.beside(mediaDir)` — async, disk-cached, de-duplicating, `.utility` |
| **Layer controls** | `setOpacity / setBlend / setBypassed / setEffects / setTransport` |
| **Output mapping (Map persona)** | `OutputTopology` — screens → slices, Codable, `.splitter(projectors:)` |
| **Test patterns** | `engine.patternKind = .testGrid / .testCrosshair / .testBars` |
| **Telemetry panel** | `engine.telemetry` — fps, p50/p99, GPU ms, active layers, source repeats, effect passes |
| **Status lines** | `engine.audioStatus`, `engine.midiStatus` |
| **Effects** | `EffectKind.allCases` (6 native) + `ISF.parse(_:)` for GLSL effects |

**Three behaviours the UI should mirror rather than reimplement:**

1. **`.armed` is a real state.** A quantised trigger doesn't fire immediately — the cell must show
   as armed with `beatsRemaining`, or the operator presses again thinking it didn't register.
2. **Triggering an empty cell is a no-op, not a clear.** Hitting an empty pad mid-show must not
   black the layer. Clearing is a separate, explicit action.
3. **Blackout is explicit.** It is never a side effect of a clip ending, a decode failure, a closed
   panel, or an empty mapping. The engine guarantees this; please don't add a path that breaks it.

⚠️ **The engine's `beat` is provisional** — a plain accumulator so the deck could be built before
the FFI is linked (§5b⑥). The authoritative clock is `photon-core/src/clock.rs`. Don't build
anything that depends on the engine's beat being authoritative; it's marked to be replaced.

### ⑩ ⚠️ Gotcha: adding a file to `engine/` needs `rm -rf macos/.build`

Hit this at 07:30. **`macos` failed to build with `cannot find 'CueList' in scope` while `engine`
built fine standalone.** SwiftPM had cached the dependency's source list and never picked up the new
file — the stale `PhotonRender.build/sources` simply didn't contain it.

`swift build` does not recover from this, and the error points at the *consuming* file rather than
the real cause, so it reads like a genuine compile error.

**If you see a symbol that obviously exists reported as missing: `rm -rf macos/.build`** (~55s
rebuild). Worth knowing before you lose twenty minutes to it.

### 🙋 My one request
**Tell me the shape you want for `ProgramSurfaceFactory`** and I'll build `engine/` to it rather
than guessing. You own the host side; I own what renders into it. Reply here or in
`docs/frontend.md` — whichever you prefer as the channel; I'll read both.

*No Slack connector in my session either, so this file is the handover record.*

---

## 6. House rules (non-negotiable, this machine)

- **Git: `main` only.** Commit straight to main, push main. Never branch, never PR unless asked.
  A pre-tool hook enforces it.
- **Never use `npx`.** `npm run`, an installed binary, or `npm install` it properly first.
- **Never fork a source of truth.** No `thing_v2.ts`, no `_final`. One file owns a definition, edited
  in place. Supersede by moving the old one out of the import path.
- **Never change a definition mid-run.** A batch reading config live applies an edit to item 9 while
  items 1–8 carry the old one — silently inconsistent, no error. Freeze config before a bench batch;
  queue corrections for between runs. **If a fault appears mid-run, say so immediately** — a
  contaminated batch handed over as finished is worse than the original mistake. This rule is doubly
  live for you: it's exactly how a benchmark lies.
- **A change without evidence is a hypothesis — label it.** Never write "verified working" for
  something that hasn't been run.
- **Never remove a working feature to make a bug go away.** Diagnose the root cause.
- **Browser automation is `pinchtab`, never Playwright.**
- **Verify before claiming done.** Re-read, grep for orphans and stale references, clean up after
  moves and renames. One clean deliverable.
- **Communicate tersely.** Abbreviations, fragments, exact paths and errors preserved.

**Tech defaults:** native front end = Swift 6 + SwiftUI, with AppKit when needed.
Later remotes/tooling use TypeScript strict, Vite, Zod; Python for plots. The dormant web scaffold
is not the Mac application.

---

## 7. Context worth not rediscovering

- **Machine (dev):** M4 Max, 32 GPU cores, Metal 4, Darwin 25.5, 36GB. Node 22.17.1, npm 10.9.2.
  **Target:** base M4 / 32GB — 4 performance + 6 efficiency cores, 10-core GPU, 120GB/s.
- **Installed:** Resolume Arena, Wire, Alley, TouchDesigner under `/Applications/`. Run them, script
  them via public APIs, study them. **Don't RE the binaries** — Claude's lane, with legal scoping.
- **DXV is not a video codec in the normal sense.** It stores GPU block-compressed texture data
  (BC1/BC3-class, plus BC6/BC7 and ASTC variants) wrapped in a lossless **snappy** pass. The GPU never
  decodes video; it receives texture blocks. Confirmed from Arena's symbols:
  `DXV4Decompressor::decompressFrame(uchar*, uchar const*, size_t, size_t)`.
- **Snappy** = Google's LZ77-family compressor, ~1.5–2× ratio but ~1–2 GB/s decompress per core. It's
  the *only* CPU work in the DXV/HAP playback path, which is why it dominates the budget analysis.
  HAP deliberately splits frames into several independent snappy streams so multiple cores can decode
  one frame in parallel — worth copying.
- **HAP** (Vidvox, open, BSD) is the same idea and is our primary codec; DXV is read-only for
  compatibility with existing Resolume content.
- **Arena links both `libvulkan.1.dylib` (MoltenVK) and `OpenGL.framework`** — but per your own
  critique, linkage ≠ active render path, and attribution needs a trace. Accepted.
- **Windows equivalents:** Syphon→**Spout**, ScreenCaptureKit→Windows Graphics Capture,
  AVFoundation→Media Foundation, VideoToolbox→MF/NVDEC. NDI, Art-Net and DeckLink SDK are already
  cross-platform.
- **M4 drives 4 external displays max** — "lots of outputs" means Datapath FX4 / DisplayPort MST
  splitting one canvas in hardware. Hence "a projector is a rectangle inside an output canvas".
- Personal-project contact is `hi@aidxn.com`, never his work address.

---

## 8. Coordination

**Slack `#aidxn-claude` (`C0BCLUN0NAH`)** — the handover channel between agents. Thread follow-ups.

**Every handover is a precise ticket, never a chat:** ① target + scope ("🎯 For the *Photon/Claude*
agent") ② one line of context ③ numbered concrete asks with exact paths/values — paste the diff if
you have a tested fix ④ what to reply with and where ⑤ sign-off ("— from the Photon/Codex agent").

**Current native handover:** `docs/frontend.md` describes the provider and GPU surface seams.
Benchmark contracts remain deferred work. Shared files are the coordination record when no Slack
connector is available; do not claim an external message was sent.

---

## 9. Status

- V4 engineering agreement is recorded in `docs/scaffold.md`; both agents accepted the baseline.
- Aiden confirms decisions were answered with Claude and explicitly starts frontend construction.
- The SwiftUI frontend builds and its local app bundle launches. It uses preview data.
- Claude is building the portable core and obtaining Xcode for native runtime work.
- `web/` is a dormant earlier template; the Mac app is in `macos/`.
- Performance experiments and benchmark runs are deferred by Aiden's latest instruction.

---

## 10. Ticket ⑪ — MIDI learn is live in the core; the UI side is yours

🎯 **For the Photon/Codex agent.** Others ignore.

**Context.** Aiden named MIDI mapping as a V1 requirement. The mapping model now exists in
`photon-core` (portable, so Windows gets it free), is exposed through `photon-ffi`, and has a Swift
face in `PhotonCoreBridge`. It is verified end to end — `macos/.build/debug/PhotonCoreCheck` runs
it against the actually-linked library and passes. **Nothing in the UI calls it yet.** That part is
yours; the API below is stable and I will not change it without telling you.

While wiring this I found that `PhotonApp` validates the ABI and then never creates a handle, so
the Rust clock and modulation have been doing nothing. `PhotonCoreSession` is the fix — see ask ④.

**What I added** (new files only; I edited one line of `Sources/PhotonCoreCheck/main.swift` to call
the new probes, and nothing else of yours):

| File | What it gives you |
|---|---|
| `photon-ffi/Sources/PhotonCoreBridge/PhotonCoreSession.swift` | `PhotonCoreSession` — owns the core handle, ticks it, routes control |
| `photon-ffi/Sources/PhotonCoreBridge/PhotonControl.swift` | `ControlSource`, `ControlAction`, `ControlValue`, `ControlOutcome` |
| `engine/Sources/PhotonRender/ControlEvent.swift` | MIDI / OSC / keyboard collapsed to one `ControlEvent` |
| `macos/Sources/PhotonApp/ControlRouting.swift` | `session.enqueue(midi:)`, `.enqueue(osc:)` |

### Asks

**① Learn mode on every parameter row.** Right-click (or a Learn button in the toolbar that puts
the whole inspector into learn state) → `session.arm(parameter: "layer.1.opacity")`. While
`session.isLearning` is true, show the armed row highlighted.

The path is the registry path, not a label. Use the same string you register the parameter under.

**② Show what a learn displaced.** `drainControl()` returns `.learned(displaced: String?)`. When
`displaced` is non-nil, say so — *"CC 7 taken from Blackout"*. Do not swallow it. A pad silently
stolen from blackout is how a show loses its panic button mid-set with nothing on screen to
explain it.

**③ Show the pickup state.** `.ignored(.awaitingPickup)` means the control is bound but out of sync
and is being held until it passes through the current value. Its `.reason` string is written for
display: *"move through the current value to take control"*. Without this the operator thinks the
mapping is broken. A small amber dot on the row is enough.

**④ Create the session once, at app start, and keep it.** It is **not** thread-safe — that is
deliberate. Drive `tick`/`drainControl` from the render thread only; everything else calls
`enqueue`, which is locked and bounded at 512.

```swift
let session = PhotonCoreSession(bpm: 120)     // hold this for the app's lifetime

// CoreMIDI / OSC threads:
session.enqueue(midi: parser.parse(bytes))
session.enqueue(osc: listener.drain())

// Render thread, once per frame:
let frame = session.tick(deltaNanos: delta)    // frame.beat, .phase, .bpm
for outcome in session.drainControl(currentPosition: { path in currentValue(of: path) }) {
    switch outcome {
    case .parameter(let path, let position): apply(path, position)
    case .action(let action):                perform(action)
    case .learned(let displaced):            showLearned(displaced)
    case .ignored(let why):                  showHint(why.reason)
    case .learning:                          break
    }
}
```

**⑤ Save the map with the document.** `session.controlMapJSON` → store it; `loadControlMap(json:)`
on open. It returns the failure **reason** as a string rather than a bool — show it. "The map
didn't load" is useless to someone standing in a venue.

### Reply with

The registry paths your inspector uses for layer opacity, layer blend and master opacity, in the
exact string form — I will register those in the core so learn binds to something real rather than
to a path nothing provides. `ControlMap.unresolved()` exists to list exactly that mismatch.

— from the Photon/Claude agent
