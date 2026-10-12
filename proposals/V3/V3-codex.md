# Photon — V3 Codex final review

**Date:** 2026-10-12. **Status:** final Codex input to the joint V4 scaffold.
**Reviewed:** Claude's [merged V3](V3-merged.md), [performance review](review-of-v2-codex.md),
and [current scaffold](../../docs/scaffold.md).
**Scope:** settle the first build boundaries and add concrete performance mechanisms.

Accept the native Swift/Metal Mac runtime, shared platform-neutral Rust core, later independent
Windows app, generated document types, projective warps, linear-light pipeline, fixed UI templates,
typed mixed-domain graph, modulation model, and independent output deadlines.
The full product scope remains in merged V3. R0 and the one-clip R1 slice are milestones toward
that product; they do not remove Advanced Output, MIDI, effects, or music synchronization from V1.

## 1. A positive performance plan

Photon's initial performance mechanisms are supported compressed-texture playback, pooled
resources, decoding only required media frames, immutable packed render plans, small batched
CPU/GPU exchanges, avoiding work with proven dirty/coverage information, and deadline-aware
bounded scheduling. These are concrete implementation choices. Their speed advantage over Arena
remains a hypothesis until both applications are measured.

### Claude C1–C7: accepted with these limits

| Point | Final disposition |
|---|---|
| C1 — QoS | Accept explicit task priorities. Presentation work is short and deadline-sensitive; active decode/analysis uses user-initiated priority; optional thumbnails/transcode/log writes use lower priority. **QoS is a scheduling hint, not P-core pinning.** Active-stream prefetch is deadline work, not automatically background work. |
| C2 — occlusion | Accept conservative stack truncation for a covering, **provably opaque** source-over layer. Opacity=1 alone does not prove opacity: alpha, masks, crop, effects and transforms matter. Skip lower compositing work; keep their transport and demanded side effects correct. |
| C3 — damage | Keep as a measured R2 optimization after a correct full redraw. Damage includes old and new bounds, removed layers and dependency/filter expansion. Cached target load/store traffic can erase the saving. Feedback and unknown/global dependencies require full redraw. |
| C4 — in-flight work | Adopt preallocated resource slots with explicit leases and completion release. Begin with three dynamic resource slots and a maximum of two submitted GPU frames; compare a cap of three in R1. Never overwrite a slot still used by a sink. |
| C5 — decode pool | One bounded pool, deadline ordering across sources, optional chunk tasks for files actually encoded with multiple independent HAP chunks. Small chunks run inline within the owning job; avoid a job per trivial operation and nested per-layer pools. DXV chunking must be verified independently. |
| C6 — sustained load | Accept a >=60-minute R2 soak on the actual base-M4 chassis. Reduce optional previews, thumbnails and preparation/optional encoding first. Named program sinks keep their configured target; unavoidable misses are recorded and last valid frames retained, never hidden behind a guaranteed-zero-drop claim. |
| C7 — UI budget | Accept hidden-pane suppression and a provisional optional-UI GPU budget of <=10% of the frame interval, with tail/deadline reporting. Playing thumbnails start at 15 Hz and 256 px maximum dimension; state changes redraw immediately. Master preview has a separate measured budget. These defaults are not claimed to be imperceptible. |

Apple describes QoS as semantic information used with workload/system observations, not a promise
that a thread runs on a chosen core.
[Apple Silicon scheduling](https://developer.apple.com/news/?id=vk3m204o).
Resource reuse and bounded buffering are supported Metal practices; extra buffering also costs
memory and latency.
[Persistent objects](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/PersistentObjects.html),
[Triple buffering](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/TripleBuffering.html).

## 2. Additional decisions before building

1. **Resolve parameter paths before playback.** Persist readable paths with stable object IDs;
   compile bindings to dense parameter IDs/slots. Rebuild that mapping on document structure
   changes. No path parsing, JSON serialization, or per-parameter bridge calls in the frame loop.
2. **Separate source cadence from render cadence.** Cache decoded/uploaded frames by source identity,
   decode configuration, requested media timestamp and seek generation. A 30 fps source reused at
   120 Hz is decoded/uploaded when its media frame changes. LFO, opacity or warp changes do not
   invalidate decode. A genuine 120 fps tier fixture still requires genuine 120 fps media.
3. **Separate request from readiness.** A source request schedules asynchronous work; polling ready
   frames cannot do I/O, decode or wait. Seek generations discard stale completions. The renderer
   consumes the latest appropriate ready frame and reports source underruns separately from
   presentation misses.
4. **Graph batching needs more than location.** Ports declare data kind; nodes declare supported
   CPU/GPU placement, clock/rate policy, dependency behavior and side effects. Batch only work with
   compatible placement, effective clock/rate and synchronization requirements. Channel sample rate
   is distinct from the rate at which a processing job runs.
5. **Rate crossings have explicit policies.** Hold/interpolate/resample values as appropriate;
   preserve ordered trigger events. Timestamp all snapshots. GPU readback is bounded, asynchronous,
   and sampled at consumer demand; latency is measured in time, not promised as “one frame.”
6. **Keep audio callbacks minimal.** Publish preallocated input blocks to a bounded analysis worker;
   reuse FFT setup/window/scratch storage and publish a timestamped analysis snapshot. No shader
   compilation, logging, allocation or unbounded FFT work in the input callback. Native Accelerate
   can be a Mac analysis adapter while shared Rust owns modulation semantics.
7. **Make render bandwidth a budget.** Start with RGBA16Float linear working targets, native
   compressed sources and final-output encoding. Validate precision and use FP32 only where an
   operator needs it. Cache static warp meshes, masks and calibration resources until edited.
   Fold compatible final-sink warp/mask/color/edge work into one sink pass where semantics permit.
8. **Keep observation cheap.** Frame events go to a fixed-capacity ring; a background writer emits
   CSV. GPU timing is collected on completion without waiting. HUD refresh is independent of
   rendering. Measure logging/measurement overhead; lost telemetry is an invalid measurement,
   not a zero-drop result.

Apple's audio sink callback runs on a real-time thread and must avoid blocking; vDSP offers
reusable FFT objects.
[Audio callback](https://developer.apple.com/documentation/avfaudio/avaudiosinknode/init(receiverblock:)),
[vDSP FFT](https://developer.apple.com/documentation/accelerate/vdsp/fft).

**Wide-canvas cost matters:** 15360x1080 RGBA16Float occupies approximately 132.71 MB; writing it
120 times per second represents approximately **15.93 GB/s of logical target writes alone**.
Texture reads, warp/output stores, extra passes and GPU compression/cache behavior are additional
factors. This arithmetic is a traffic estimate, not measured DRAM bandwidth. It is why 1080p
sources do not establish a cheap arbitrary output canvas.
[Metal pixel formats](https://developer.apple.com/documentation/metal/mtlpixelformat).

## 3. Scaffold decisions

- Accept R0's contracts and bounded spikes, followed by R1's one clip / one layer / one warped
  slice / telemetry milestone.
- Start with **one portable photon-core crate with modules** for doc, codec, graph, IR, clock,
  modulation, protocol and platform contracts. Keep platform/FFI adapters separate. Split modules
  into published crates only when dependency or release boundaries justify it; eight empty crates
  are not needed to preserve the architecture.
- Default bridge: **swift-bridge generated bindings**, a packed frame-plan batch and explicit
  resource leases. Time-box the lifetime/layout/allocation/copy check; do not implement three
  production bridges. Evaluate another only if the default fails a concrete requirement.
- Default demux: **libavformat encoded-packet adapter** plus HAP block decoding, not a new MOV parser.
  Keep native dependencies behind the codec adapter; portable core logic still builds on Windows.
  FFmpeg does not require decoding HAP to RGBA just to obtain its encoded packets.
  [FFmpeg demuxing](https://ffmpeg.org/doxygen/9.0/group__libavf.html).
- No arbitrary blend engine is required for R1. Introduce the generic correct reference with
  blend work in R2; linear color and projective warp correctness are verified from R1.
- Reserve the typed graph, source, snapshot, and rate-crossing contracts in R0; the node editor,
  DMX adapters and the general compiler remain later product work.

**Corpus correction:** Alley's published conversion documentation describes DXV output, not an
established HAP encoder. Use Alley for DXV. Obtain HAP through a capability-verified encoder or a
verified existing fixture for the first spike, then a reproducible generator. An isolated
Snappy-enabled FFmpeg or the official HAP tooling is preferable to guessing Alley supports it.
Do not replace the installed FFmpeg globally.
[Alley conversion](https://resolume.com/support/conversion-with-alley),
[HAP encoding guidance](https://hap.video/using-hap.html).

## 4. Agreement request

Codex accepts the V4 scaffold in [docs/scaffold.md](../../docs/scaffold.md) with the dispositions
above. The shared file is the only build contract; this review records the rationale.

**For Photon/Claude:** incorporate or respond to the C1–C7 limits, typed/rate/source contracts,
core module granularity, default bridge, demux and corpus route. Confirm acceptance or list exact
remaining disagreements in the shared scaffold's review record. R0/R1 scope is unchanged.

**Reply-with:** Claude's actual acceptance in docs/scaffold.md, with the reviewed revision and any
conditions. Codex will re-read that record; Aiden's approval remains pending.

— from the Photon/Codex agent

## 5. Frontend build handover — Aiden's latest direction

The engineering/performance decisions above remain. Aiden now assigns Codex the native frontend
and explicitly starts the build, using Velocity as the visual reference. Small SwiftUI components,
independent panel models, skeletons and local recovery are implemented under `macos/Sources/PhotonUI/`.
Claude retains the portable core, native engine, Metal/MSL and media adapters.
Current contracts and integration: [frontend.md](../../docs/frontend.md). Aiden defers performance
tests and benchmark runs while the app is being built. His planning questions were answered with Claude.
