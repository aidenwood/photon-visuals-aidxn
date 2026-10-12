# Photon — Scaffold (V4 agreement)

**The one scaffold. Edited in place; no versioned copies.** **Updated:** 2026-10-12.
**Status:** Both agents agree on the engineering baseline. Aiden confirms the remaining questions
were answered with Claude and explicitly authorises Codex to scaffold the native front end.
**Basis:** [merged V3](../proposals/V3/V3-merged.md) +
[Codex final V3](../proposals/V3/V3-codex.md) +
[Claude's performance review](../proposals/V3/review-of-v2-codex.md).
**Revision:** V4, frontend ownership and component resilience update, 2026-10-12.

This is the build agreement. Deliberately short: where V3 settled something, this cites it rather
than restating it. Aiden's latest instructions supersede earlier ownership and approval notes.
The front-end scaffold below is authorised now; engine stages retain their gates.

---

## 1. What we agree on (both agents, independently reached)

Native macOS app — Swift + Metal + MSL. Shared `photon-core` Rust crate with **no Apple API**.
Windows later, separate repo, consuming the core at a pinned tag. Web/iOS are remote control
surfaces only. Staged delivery closing on **evidence**, not effort. Keep a **correct unfused
reference** and validate every fast path against it. Treat MTLIO, ICBs, tile shaders, sparse
textures, heap aliasing and general fusion as **independent experiments whose failure changes
nothing structural**.

---

## 2. R0 — the only stage this document authorises

Everything past R0 is sequenced in V3 §5.1 but **not yet authorised**. R0 exists to make the rest
decidable rather than guessed.

| # | Deliverable | Owner | Done when |
|---|---|---|---|
| 1 | **Arena measurement feasibility spike** | Codex | A written answer to *what can Arena actually expose?*, with sampling precision and overhead. **If nothing usable: say so loudly** — it changes what the project can claim (§5 Q1). |
| 2 | ✅ **`photon-core` package + CI guards** | Claude | **DONE** — `ci/check-portable.sh` passes 3 independent checks (resolved graph incl. renamed crates · source FFI/linkage · `wasm32` build) and **self-tests by injecting a `core-foundation` dep and confirming failure**. `forbid(unsafe_code)` crate-wide. |
| 3 | ✅ **`.photon` v0 schema** | Claude | **DONE** — `src/doc/`: rational time, stable `Id`s, full `ColorDescriptor`, transport/playthrough, blend modes with `needs_destination()`, modulation bindings. 26 tests green. *Generated-Swift drift check pending Codex's shell scaffold.* |
| 4 | ✅ **C1 — thread/QoS map** | Claude | **DONE** — `docs/thread-qos-map.md`. QoS recorded as an **OS hint, not core affinity**; worker counts derived and compared empirically at R1; active prefetch split from speculative preparation. |
| 5 | ✅ **FFI spike** | Claude | **DONE** — `photon-ffi/FINDINGS.md`. New crate; **the only one permitted `unsafe`**, so `photon-core` keeps `forbid(unsafe_code)` and stays portable. **Measured Swift→Rust: 6.4 ns/frame, FLAT from 1 to 32 layers** (0.000076% of a 120fps frame) — the packed one-crossing-per-frame design works. Swift asserts struct strides against Rust at startup so layout drift fails loudly. 🔶 **Deviation: hand-written C ABI, not `swift-bridge`** — 8 fns + 2 POD structs, and swift-bridge would add a codegen step to a package that currently needs no Xcode. Revisit when the interface carries strings or the document model. |
| 6 | ✅ **HAP upload path spike** | Claude | **DONE** — `spikes/metal-upload/RESULTS.md`. **BC compression + argument buffers Tier 2 confirmed available** (was an unexamined assumption under the whole plan). `replaceRegion` on a shared texture = **0.073 ms/frame, 13,713 layer-frames/s — 28× the 480 target**; buffer→blit→private is 2.94× slower. Both verified correct by sampling into `rgba16Float` and reading back exact values. **H2 closed: upload is a non-problem.** `DEV-BOX-INVALID`. |
| 7 | **`bench-fairness.md` + `bench-cli.md`** | Claude drafts fairness; **Codex specifies the CLI** | Both reviewable; Codex owns the consumer side |
| 8 | ✅ **Memory budget for the 32GB target** | Claude | **DONE** — `src/budget.rs`. Six independent pools (read-ahead · decoded blocks · native frames · persistent textures · transient targets · thumbnails), **all derived from `DeviceCapabilities` at runtime, none compiled in** (C8). Tested: pools never exceed working set; budgets scale with machine size; 4K cache depth is ¼ of 1080p — which is *why* the ring cache must be cue-aware. |
| 9 | **Git remote + first commit** | Claude | `photonbench` can refuse to record from a dirty tree |
| 10 | **Runtime contracts** | Claude drafts; Codex reviews | Typed graph/rate crossings, ready-frame access, resource leases, parameter IDs, telemetry schema and buffer budgets specified as §3b |

### 2b. Load split — Codex leads the native front end; Claude leads the engine

Aiden's latest instruction: "I want you more working on the front end when you scaffold."
The previous exclusion of Codex from all of `macos/` is superseded.

| | Claude | Codex |
|---|---|---|
| Primary | Portable Rust core, codecs, Metal/MSL, native runtime/FFI adapters, presentation scheduling | Native SwiftUI shell, fixed persona templates, individual panels and controls, loading/error/retry UX, keyboard interaction |
| Paths | `photon-core/`; future native render/platform/bridge targets under `macos/Sources/` | `macos/Sources/PhotonApp/`, `macos/Sources/PhotonUI/`, frontend tests and local run script |
| Integration | Owns engine state, generated types, GPU resources and runtime telemetry | Consumes snapshots/commands through an injected provider; owns presentation state and view composition |
| Secondary | Engine-side measurements and benchmark fairness review | `bench/`, corpus and independent performance review; later web/iOS remotes |

Codex initially owns frontend Swift package wiring. Claude adds engine targets through a handover
rather than concurrently rewriting the manifest. GPU-backed surfaces belong to the engine; native
UI hosts, chrome and interaction overlays belong to Codex.

### 2c. Authorised front-end scaffold

Aiden: "start scaffolding the front end, individual components ... not massive app components"
and skeleton loading with local recovery during a show. Use the local Velocity editor/dashboard
as the visual reference, adapted to native desktop controls. Build a thin shell, small named
components, independent panel models, per-panel skeletons, errors/retry, retained last-good data
and cancelled/stale request protection. The initial provider is explicitly a UI preview fixture;
it does not claim playback or measured engine performance. See [frontend.md](frontend.md).

Recoverable panel/data failures remain local. Fatal native crashes need process isolation;
SwiftUI fallback views cannot contain a segmentation fault or fatal process termination.
Program playback remains engine-owned when an editor closes or reloads.

**R0 engine work does NOT include:** a production renderer, compositor, effects, node graph, I/O
adapter, or the benchmark harness itself. Each spike is **time-boxed to a few focused
days** and stops at its decision point (Codex §7) — no open-ended study.
The upload spike may use an isolated sampling/readback probe to establish correctness; it does
not create the R1 application. Public node/editor and hardware-adapter implementations remain later.

---

## 3. Repo layout

```
photon/
├── photon-core/                 One portable Rust crate — no Apple API
│   ├── Cargo.toml
│   └── src/
│       ├── doc/                 .photon schema + generated types (SOURCE OF TRUTH)
│       ├── codec/               HAP/DXV block logic; packet/decompression interfaces
│       ├── graph/               typed ports, dirty/temporal dependencies, rate policies
│       ├── ir/                  logical compositor plan; MSL emitter first
│       ├── clock/               rational transport; separable tempo/phase sources
│       ├── modulation/          persisted paths -> resolved parameter IDs
│       ├── protocol/            authoritative commands + revisioned state
│       ├── platform/            nonblocking portable contracts
│       └── budget.rs            per-pool memory budgets DERIVED from device caps (R0 #8)
│   └── ci/check-portable.sh     portability guard; self-tests via injected violation
├── macos/                       Swift package; frontend scaffolding started
│   ├── Sources/PhotonApp/       Codex — native app entry point
│   ├── Sources/PhotonUI/        Codex — small panels, controls, state, recovery
│   └── Tests/PhotonUITests/     Codex — local recovery checks, deferred for now
├── bench/                       Codex
├── docs/                        this file + contracts
└── proposals/                   review history; no proposal adopted yet
```

Logical boundaries exist immediately; split into separate published crates when dependencies or
release needs justify it. Existing native libraries sit behind adapters with isolated unsafe FFI.
Default container path is a **libavformat packet adapter**, not a handwritten MOV atom parser;
HAP packets decode to compressed blocks, retaining the compressed-texture path. Native FFmpeg
linkage belongs in an adapter outside the portable crate, so an Apple-enabled FFmpeg build cannot
quietly pull Apple frameworks into the core.

### 3b. Performance contracts fixed before R1

- **Parameters:** persist readable paths with stable object IDs; resolve to dense parameter IDs
  and slots on load/structural changes. Publish one immutable packed plan/snapshot per batch.
  No JSON/path parsing or individual per-layer FFI calls in the frame loop.
- **Sources:** request a media timestamp asynchronously; obtain a ready frame through a
  nonblocking operation. Cache by source/configuration/timestamp/seek generation. A changing
  effect/opacity does not restart decode; stale seek completions are discarded.
- **Leases:** resource ID + generation + lease identify a ready frame. Reuse only after every GPU
  and sink consumer completes. Start with three dynamic slots and at most two submitted GPU
  frames; compare a cap of three in R1. Decode work and telemetry never hold up presentation.
- **Graph:** ports declare data kind; nodes declare placement, effective clock/rate, dependencies
  and side effects. Channel sample rate is distinct from job cadence. Batch compatible work;
  hold/interpolate/resample scalar/sample crossings and preserve ordered events explicitly.
  GPU readback is asynchronous, bounded and consumer-rate driven, with age/latency telemetry.
- **Color/geometry:** RGBA16Float linear working targets initially, precision checked; encoded
  compressed source textures and final output encoding. Projective quad UVs. Static meshes,
  masks and calibration resources are cached until edited; FP32 working targets require need.
- **Scheduling:** one bounded decode pool, initially two workers; compare two/three/four on the
  base M4 in R1 without core-pinning assumptions. Deadline order across sources and optional substantial
  independent HAP chunks. Small operations run inline within compatible batches. Separate active
  playback work from optional editor/thumbnail/transcode work. Audio input callbacks publish
  preallocated blocks to a bounded analysis worker with reused FFT setup/scratch.
- **Telemetry:** fixed-capacity event ring; background CSV writes; completed GPU timings collected
  without waiting. HUD updates independently. Queue overflow/lost telemetry invalidates the
  measurement rather than being treated as zero dropped frames.

These specify data/lifetime and scheduling contracts now; advanced operators, editors and rate-
limited DMX output remain later implementation. Full details and sources are in the Codex V3 review.

---

## 4. Rules enforced mechanically, not by prose

| Rule | Mechanism |
|---|---|
| No Apple API in `photon-core` | Dependency/source/link checks cover Apple binding families, including renamed crates; portable Windows build of the core; deliberate violation must fail. A short crate-name deny-list alone is insufficient |
| Owned safe logic forbids `unsafe` | `#![forbid(unsafe_code)]`; audited native-library/generated bridge code isolated in explicit adapter crates, including codec FFI |
| Document types generated, never hand-written | Schema emits; CI fails on drift |
| Every optimized compositor has a correct reference | Introduce the reference with R2 blend work; R1 checks color and warped single-layer correctness. No unused full blend engine in R0 |
| No bench run from a dirty tree | `photonbench` refuses; requires a pinned revision |
| Optional UI stays inside budget | Initial <=10% frame-interval GPU budget, tail/deadline reporting; hidden views skipped; playing thumbnails initially 15 Hz/256 px; master preview separately budgeted (R3) |

---

## 5. Corrections already baked in — do not re-derive these

- **`MTLBuffer.makeTexture` does not accept block-compressed formats.** The zero-copy upload route
  does not exist. Use a supported pooled path (R0 #6).
- **Tier claims require DXV, not HAP.** R1 is HAP-only and cannot declare Tier A/B/C; those close at R2.
- **WebRTC baseline is VP8 + H.264, not HEVC.** Browser preview is H.264.
- **Browsers cannot enumerate Bonjour.** mDNS for native clients; URL + QR for browsers.
- **128 clip slots ≠ 128 decoders.** One bounded shared Metal thumbnail surface; ordinary controls.
- **Linked libraries ≠ active render path.** No cause attributed to MoltenVK without a trace.
- **MB/s arithmetic ≠ disk reads.** Snappy compresses; loops may serve from the OS file cache.
- **Dev box is 36GB M4 Max; target is 32GB base M4.** Dev runs tagged `DEV-BOX-INVALID`.
- **NDI send takes linear memory; Art-Net needs CPU-visible packets.** Bounded *async* readback is
  permitted and counted — "no CPU readback ever" was wrong.
- **C1–C7 accepted with limits:** QoS does not pin cores; opacity=1 does not prove opaque coverage;
  damage includes old/new bounds and dependency expansion; chunk parallelism depends on the file;
  optional work degrades before program sinks; unavoidable program misses remain observable.
- **Alley is the DXV route, not a verified HAP encoder.** Use capability-verified HAP tooling or an
  existing verified fixture for the first probe, then a reproducible generator. Preserve the
  installed FFmpeg; an isolated Snappy-enabled build is one possible route.

---

## 6. Codex answers and first consumer contract

1. **Core granularity:** one crate, logical modules, explicit native/FFI adapters; split later.
2. **Bridge:** generated swift-bridge first; measure batched layout/copies/allocations, warmed
   latency, cancellation and resource lifetimes. Alternative only on a concrete failure.
3. **R0 additions:** §3b's source/readiness, leases, typed/rate graph and resolved parameter
   contracts; supported color/upload path and explicit R1 success configuration.
4. **Bench interface:** capabilities -> prepare -> start -> collect -> stop/finalize. Freeze the
   job config and its hash before prepare. Separate control and measurement adapters. Photon
   capability output declares supported codecs, output/rate modes and telemetry availability.
   Jobs specify source/composition/output cadence, dimensions, layer/source identities, paths,
   warm-up/duration, sinks and settings. CSV events include explicit units/timestamps and
   distinct source-underrun/presentation-miss counters; unavailable measurements are null.
   Contract schema and version/exit/cancellation semantics are completed in R0's bench-cli.md.
5. **Arena:** no feasibility conclusion yet. Average-only measurement limits that comparison
   without blocking Photon telemetry or tier acceptance. Do not manufacture frame percentiles.
6. **Performance plan:** accept C1–C7 as bounded mechanisms with §5's limits; add §3b's concrete
   mechanisms. Faster-than-Arena remains an objective to test, not a pre-implementation fact.

**R1 milestone configuration to record in R0:** 1080p HAP source, composition and one physical
output; verified source/composition/output cadence (60 Hz initially, using the actual rational
display mode), one projectively warped slice, linear working format, warm-up, then a ten-minute
loop. Measure source age/repeats, presentation misses, CPU/GPU/queue times and memory. Do not
claim zero misses from a counter that cannot observe them. This HAP slice does not claim DXV tiers.

---

## 7. Decisions and current build authority

Aiden confirms the remaining questions were answered with Claude. Do not reopen them.
Carry the exact comparison and release-scope answers forward from Claude's decision record.
The front-end build is explicitly authorised in this session; benchmark runs are deferred.

1. **Arena comparison:** answered with Claude; the performance goals and honest-measurement rules remain.
2. **First show's I/O:** the current release roadmap records physical output + Syphon at R3,
   with explicit additions at R4.
3. ✅ **ANSWERED — Ableton Link deferred to Photon 3.0/4.0.** Off the early path; no licence email
   needed yet. V1 tempo = **tap tempo + MIDI clock**, with the clock built **tempo/phase-separable**
   so Link and Pro DJ Link slot in later without rework. Licence must still be obtained *before*
   Link ships.
4. ✅ **RESOLVED — ffmpeg generates DXV directly; no Alley, no GUI, no ffmpeg rebuild.**
   The installed ffmpeg has a full **DXV decoder AND encoder** (verified: 1920x1080/60/120-frame
   file produced and decoded back exactly). Supersedes the earlier "Alley for DXV" answer.
   DXV frame header = `fourcc("DXT1" LE) | version | compressed_size | payload`.
   ⚠️ ffmpeg's DXV decoder outputs **RGBA (CPU-decoded)** — it is the corpus generator and
   reference decoder, **never the runtime path**; playback extracts BC blocks itself.
   DXV *encoding inside Photon* stays deferred to Photon 4.0/5.0; DXV *read* is V1 and gates tiers.
5. **Frontend go:** Aiden explicitly instructs Codex to start the component scaffold now.
   Claude is obtaining Xcode. Codex builds against the installed Swift toolchain meanwhile.

---

## 8. Sign-off

| Party | Status | Notes |
|---|---|---|
| Claude | ✅ | Engineering baseline accepted in the acknowledgement below, before the user-directed frontend reassignment |
| Codex | ✅ | Engineering baseline retained; accepts and implements Aiden's frontend assignment |
| Aiden | ✅ | Reports questions answered with Claude; explicitly authorises the frontend build and defers performance tests |

**Claude's acknowledgement (2026-10-12), recorded here as the shared record:**

Accepted without reservation, including four amendments that correct me:
1. **QoS is a scheduler hint, not core affinity.** Apple Silicon exposes no public pinning API; C1
   as I wrote it implied placement that cannot be guaranteed. Codex's "compare 2/3/4 workers without
   core-pinning assumptions" is the correct form.
2. **`opacity=1` does not prove opaque coverage** — the source texture itself may carry alpha
   (HAP Alpha, DXV with alpha). My C2 occlusion test was unsound; it needs source-alpha knowledge
   plus geometric coverage.
3. **Damage regions must union old *and* new bounds** plus dependency expansion. A moved layer
   dirties where it was as well as where it is. I specified only the new bounds — a real defect.
4. **Alley is the DXV route, not a verified HAP encoder.** I asserted HAP capability without
   verifying it. Verify tooling independently; preserve the installed FFmpeg.

Also adopted: one crate with logical modules over my 8 (premature decomposition); **libavformat
packet adapter over a handwritten MOV atom parser**, with FFmpeg linkage isolated outside the
portable crate so an Apple-enabled build cannot pull Apple frameworks in; reference compositor
introduced at R2 rather than sitting unused in R0; swift-bridge as default; three dynamic slots /
two submitted GPU frames; RGBA16Float linear working targets.

Two of Codex's telemetry rules are worth naming because they prevent false results, not just bad
ones: **"queue overflow or lost telemetry invalidates the measurement rather than reading as zero
dropped frames"**, and **"do not claim zero misses from a counter that cannot observe them."**

**V4 engineering terms are agreed. Aiden's latest frontend ownership and build instructions are
recorded in §2b/§2c.** The working frontend and native integration handover are in
[frontend.md](frontend.md). The existing performance contracts are preserved.
