# Effects library and FPS plan

**Codex → Claude, 2026-10-12.** Aiden asked for REA of the effects library and a plan first.
This extends the agreed [V4 scaffold](scaffold.md); it does not replace the stack or authorise
benchmark work. Codex owns the catalog, browser and controls. Claude owns effect execution,
shader IR, GPU resources and the authoritative parameter/document model.

## Evidence and limits

- REA native observation of the installed Arena window: evidence
  `ev_3a90dd11ba0bca0a2274caaeff51be13c3cde4d9b7bee9e12ec1692ee69afc2b`.
  Screenshot shows Arena **7.26.1**, combined layers/columns above transport, dual monitors,
  scope inspectors and a tabbed browser. The first AX capture has 500 nodes and is truncated;
  it does not inventory the whole Effects tab.
- Follow-up REA Effects-tab action: evidence
  `ev_e368c9343fa4142cda174fca1e7e3c09437c64f948e12bd72fc65c97001a8b68`.
  The targeted action clicked only the Effects browser tab (no effect applied). The screenshot
  shows **Wire Effects** and **Video Effects**, nested effect families, child presets, search
  and an add control. Visible entries include Acuarela, Add Subtract with Blue/Green/Red,
  Auto Mask, Bendoscope, Bloom and Blow. This already proves the 32 preset folders are only
  a subset. AX exposes the outline rows without their text, and marks the post-action capture
  truncated despite 1468 nodes; a complete effect inventory is not established. Browser is
  left on Effects; the composition and output settings were not edited.
- REA artifact inspection: evidence
  `ev_47cfcf985d8dcc2a4904f1d78217e02df2d99a97452373abba6c61baa5b32db9`.
  This is artifact structure, not evidence of GPU execution or native shader cost.
- Direct XML extraction from `/Applications/Resolume Arena/default/Presets/Video Effects`:
  **116 presets in 32 family folders**. [Extracted metadata](reference/arena-effects-presets.json)
  includes per-file SHA-256, source path, version, logical passes, typed parameters, ranges and
  phase sources. These are the shipped presets, **not the complete Arena effect catalog**.
  XML versionInfo commonly says 7.3.0; that is preset provenance, not the running app version.
- Claude's [interface/animation extraction](resolume-ui-reference.md) supplies the three-range
  parameter model and named layout tree. No proprietary thumbnail, shader or binary is copied
  into Photon. The derived JSON is research metadata, not a runtime dependency on Arena.

Observed preset shape: a `DryWetEffect` wrapper carries bypass, opacity and blend, with the
effect's inner `RenderPass` carrying its controls. Logical nesting does **not** establish how
many physical GPU passes Arena uses. `PhaseSourceStatic`, `PhaseSourceTimeline` and
`PhaseSourceTransportTimeline` occur. A static parameter does not prove a static effect:
Goo/Static/Twitch may still use internal time; that remains unknown without executable evidence.
Names contain aliases, trailing spaces and even `TransformStrengt`. Keep source identifiers
verbatim in research; do not use display labels as authoritative parameter keys.

Reproduce the file extraction with `python3 script/extract_arena_effects.py`. The JSON preserves
logical pass descriptors; even the Add Subtract preset has a nested mixer descriptor, reinforcing
that XML node count is not GPU pass count. Range fields are not all serialized on every parameter:
the initial extraction finds 590 defaultRange, 133 minMax and 186 startStop records. Preserve
omitted/default semantics; adopt the three-range *model* without requiring every preset to
physically contain all three fields. Folder count also need not equal unique shader class count.

## Execution classes to plan for

The following are **implementation hypotheses**, not measured Arena cost classifications.
Inspect each Photon shader/IR before assigning its capabilities.

| Class | Observed families to investigate | Scheduling/resource rule |
|---|---|---|
| Pointwise colour | Add Subtract, Invert RGB, Colorize | Candidate for compatible colour-op folding; no extra target solely for a control wrapper |
| Coordinate/sample transforms | Flip, Mirror, Keystone, Tile, Slide, Kaleidoscope, Suckr, Wave Warp, Ripples, Tunnel | Compose coordinates only when sampling, borders, alpha and derivatives remain equivalent; otherwise materialise |
| Multi-sample / neighbourhood | RadialBlur, LoRez, Shift RGB, Blow, Twitch | Explicit sample/radius/quality limits and full-resolution reference; no assumption that a named effect is cheap |
| Replication / geometry | Linear Cloner, Radial Cloner, Cube Tiles, Fragment, VideoWall, Stripper, Iterate | Bound clone/iteration counts; decide instancing versus image accumulation from semantics |
| Temporal / stochastic | Freeze, Particle System, Goo, Static, Shift Glitch; any history-based Iterate variant | Declare time/random/history inputs explicitly, persistent state and reset/seek semantics; schedule while demanded even when knobs are unchanged |

Families can span classes. RadialBlur presets expose `Steps` and `High Quality`; those are
real workload controls. Particle System exposes particles, lifetime and velocity/gravity.
Freeze's retained frame is persistent ownership, not an ordinary disposable intermediate.
Iterate's name alone does not prove frame feedback; require its implementation's contract.

## Decisions before implementing effects

1. **Metadata is separate from execution.** Browsing, searching or opening a preset must not
   instantiate every effect, compile every pipeline, start decoders or render per-row previews.
   Catalog/search data is immutable and cached. Failed catalog loads get a local retry boundary.
   Unimplemented items are visibly unavailable; the browser never suggests they are live effects.
2. **Compile away from presentation.** Build/cache pipelines asynchronously, prewarm selected
   show effects, retain the last accepted graph while compiling and swap only at a safe epoch.
   Cache key: shader version, format and genuinely structural options. Slider values are
   uniform updates, not pipeline variants. Compilation failure is a rejected graph edit.
3. **Use the existing typed, rate-aware graph.** GPU images stay GPU images; CPU signals,
   FFT, OSC/MIDI/DMX and tables retain their own clocks and domains. Image→CPU conversion is
   explicit, bounded and consumer-rate driven. A 44-Hz DMX consumer cannot force 120 GPU
   renders or a synchronous readback. Evaluate shared demanded subgraphs once per epoch.
4. **Resolve parameters before the frame loop.** Stable effect/parameter IDs, types, aliases,
   natural range, user bounds and animation endpoints belong in the authoritative schema.
   UI DTOs display those fields. Compile bindings into numeric slots and publish packed
   immutable frame snapshots; no JSON, dictionary label lookup or UI observation per pixel/frame.
   Ranges, beat/second units and per-binding phase remain explicit, following Claude's evidence.
5. **Start correct, then fold narrowly.** Keep an unfused reference. Start with compatible
   pointwise colour operations and a proven dry/wet fold. Do not fuse across neighbourhood,
   history, multiple-consumer or colour/alpha boundaries without equivalence. Arbitrary fusion
   and heap aliasing remain later independent experiments, as agreed in V4.
6. **Budget texture lifetime explicitly.** Pool compatible transients, schedule last use and
   keep immutable resource leases through GPU completion. Preserve V4's three resource slots
   and two submitted GPU frames. History targets have explicit persistent leases and reset
   rules; bypass/seek/removal must not reuse memory still in flight. Bound pool/history/clone
   memory inside the existing project budget, not an unbounded effect-local cache.
7. **Avoid unnecessary full-frame traffic.** Prefer proven pass folding, crop/ROI only with
   valid coordinate rules and share common effect results. RGBA16Float 1920×1080 is about
   16.59 MB per target; one logical full read/write is 33.18 MB, or 1.99 GB/s at 60 Hz.
   This arithmetic illustrates scaling; it is not measured physical DRAM traffic. Tile caches,
   sampling and compression change real traffic. Never silently lower the working precision.
8. **Separate optional previews from output.** One composition result can feed several
   monitors through engine leases. Thumbnail images reuse already demanded frames or a
   bounded thumbnail path; never rerun a full effect stack for every visible slot. Initial
   playing thumbnails remain 256 px/15 Hz, hidden views skip work, optional UI GPU work stays
   within V4's initial ≤10% frame-interval budget. Program output survives editor closure;
   detaching a monitor releases only that monitor's subscription.
9. **Heavy effects are predictable.** Document bounded steps/particles/clones/history before
   exposing controls. Any quality tier is explicit and saved, not an automatic silent drop.
   Audio analysis is shared CPU work with bounded callbacks/workers; time and modulation are
   inputs to the same graph. No per-parameter FFT or readback.
10. **No stalls in UI construction.** File scans and shader compilation must not block
    `makeNSView`, layout or the main actor. The initial engine surface hit a real synchronous
    media-folder scan stall; Codex moved that scan off-main in the presentation adapter.
    Panel deadlines cannot recover from a blocked main thread. Final pipeline preparation and
    media ownership should move into Claude's shared runtime service.

## Build order and later acceptance

Keep the V1 target of roughly 30 built-ins. An initial implementation order is simple colour,
Flip/Mirror/Tile/Keystone, then Vignette/LoRez/Shift RGB; follow with controlled neighbourhood
filters, geometry replication and persistent/time effects. This is ordering, not a scope cut,
and the shipping selection need not match Arena's names or presets.

First ship the catalog and scope-aware browser shell, then authoritative parameter metadata,
then the engine's correct reference effects, then caching/scheduling and narrowly proven folds.
Codex must not create a second effect schema or implement Metal shaders inside SwiftUI views.

When Aiden resumes performance work, compare unfused/folded images in linear working space
including alpha, out-of-bounds sampling, transforms, animated parameters, seek and bypass.
Measure effect-chain CPU/GPU p50/p95/p99, presentation misses, source repeats, peak resident
and history memory, compilation hitches and optional-preview cost. Include chain length,
input/output rate, resolution, format and workload controls. Budget is **16.67 ms at 60 Hz** or
**8.33 ms at 120 Hz**, not a claimed achieved result. M4 Max development results remain tagged
`DEV-BOX-INVALID`; target qualification is on the specified base M4. No benchmarks run for
this plan, and no claim is made that Photon beats Arena.

## Claude handover

- Preserve the existing engine adapter injected into `PhotonApp`; Codex is updating only the
  UI and the specific synchronous-scan launch blocker, not rewriting the renderer.
- Please converge on one runtime shared by master/clip surfaces plus a provider adapter.
  Current `ProgramMetalView.make` creates a separate engine per view; UI fixture commands do
  not control it. Label this honestly until real commands, telemetry and selected clips connect.
- Add parameter metadata/ranges to the generated core contract before exposing modulation UI.
- Feed effect capability metadata and acknowledged graph state to the catalog/inspector.
  Unsupported shaders/presets must return a local issue, keeping the accepted program graph.
- Full Effects browser inventory and native execution attribution remain separate research
  questions. Shipped XML cannot answer kernel count, fusion, internal formats or scheduling.
