# Photon — V2 Codex Proposal

**Author:** Photon/Codex agent. **Date:** 2026-10-12.
**Status:** submitted for review; not adopted. Architecture proposal, no engine implementation.
**Scope:** the entire project: native engine, media pipeline, GPU strategy, scheduling, outputs,
benchmarking, project format, native UI, later Windows app, and later remote clients.
**Adaptation:** incorporates Aiden's Windows, feature-parity, UI deferral, and sequencing instructions
recorded in Claude V2. The performance recommendations in §§3–6 remain intact.

Keep the native macOS/Metal direction. Keep Rust, Swift, and MSL, but make the ownership boundary
explicit and build a small, measurable playback engine before committing to a custom clip format,
GPU-generated commands, tile shaders, or a general shader compiler. The language choices are
reasonable. Several claimed performance mechanisms and the proposed release scope need revision.

This is a standalone alternative to [Claude's V2 proposal](V2-claude.md), not an amendment to it.
The Mac product uses a native macOS engine and one Metal backend. The later Windows product may
have its own renderer and shell, with a shared Rust core. The web remote runs on another machine
later, and iOS is another controller. Claude §0.6 records Aiden's subsequent Windows instruction;
the older “one backend” wording in [PLAN.md](../PLAN.md) now needs that platform scope.

## 1. What was actually checked

Reviewed the initial PLAN v0.2, its replacement plan index, the handover, the expanded
`proposals/V2-claude.md`, and all configuration and entry-point files in the existing web scaffold.
Checked primary documentation for Metal, Metal I/O, indirect command buffers, MoltenVK, HAP,
FFmpeg, Resolume's REST API, NDI, and WebRTC.

The expanded Claude proposal was read after the repository changed during this review. Its
initial reviewed SHA-256 was `f95839c719a1cf8f60438e2c8951b8a5e8927d637e3acbdec44b5386e1e6738e`.
Subsequent additions to §0.6, §1.5, §3.5, and the P8 phase were read and incorporated below.
The adaptation reviewed Claude snapshot SHA-256
`a770dc28e5e94edb1860de4e99e18cd2913d85fe8e575519ff2940cf2e59c742`.
Claude's file continues to evolve; references use section and hypothesis names, and hashes identify
reviewed snapshots rather than its current contents.

| Local observation | Evidence and implication |
|---|---|
| No native scaffold exists yet | `core/`, `macos/`, `bench/`, and `ios/` were absent. This is an architectural review, not a measured engine-performance review. |
| Machine memory is 36 GB, not 128 GB | `system_profiler SPHardwareDataType` reports Apple M4 Max, 36 GB. `sysctl -n hw.memsize` returns 38,654,705,664 bytes. Cache design must use the actual memory budget. |
| Installed FFmpeg cannot encode HAP | FFmpeg 9.0.1 configuration omits `--enable-libsnappy`; `ffmpeg -h encoder=hap` reports no available HAP encoder. Its exit status is zero despite this message, so preflight must inspect capabilities. |
| Web build passes | `npm run build` completed successfully: TypeScript project build and Vite build. |
| Web lint passes | `npm run lint` completed successfully. Neither check establishes runtime controller performance. |
| TypeScript strict mode is absent | Neither referenced web tsconfig enables `strict`. The root tsconfig only contains project references. |
| Tailwind is installed but unwired | `@tailwindcss/vite` is absent from Vite's plugins; the stylesheet has no Tailwind import. |
| Benchmark contracts are missing | `docs/bench-fairness.md` and `docs/bench-cli.md` were absent. |
| Repository has no commit or remote | Local `main`, all source untracked, no configured Git remote. Reproducible results need a committed source revision before formal runs. |

No Arena performance baseline, GPU capture, codec throughput measurement, storage-speed test, or
FFI benchmark was performed. Recommendations below are engineering judgments unless identified
as local observations or documented API constraints.

### Target requirements incorporated during review

The current Claude proposal records Aiden's target as **base M4, 32 GB, 1080p DXV3/DXV4 sources**:
four layers at 120 fps, eight at 60 fps, and twelve at at least 30 fps. It also records arbitrary
user-selected composition/output sizes, a base-M4 test machine, and an Arena-like Perform surface
inside an Affinity-like persona shell. Treat those as design inputs; none of those performance
tiers has been verified.

Apple documents the base M4 configuration with four performance CPU cores, ten GPU cores,
120 GB/s memory bandwidth, and an optional 32 GB memory configuration.
[Apple M4 Mac mini specifications](https://support.apple.com/en-ie/121555).

Separate the 36 GB M4 Max development machine from the 32 GB base-M4 acceptance machine.
Dev measurements remain useful for iteration but must not count as target-tier passes.
Cache budgets must fit the target, including OS/UI/GPU headroom.

“480 layer-frames per second” is a useful source-throughput metric, but four layers at 120 fps
and eight at 60 fps are not interchangeable tests: presentation, final stores, output warps,
per-frame scheduling, and deadlines differ. Record source frame production, composition frames,
and output presentation separately. Use genuinely appropriate source cadences; repeatedly drawing
a 30 fps texture at 120 Hz does not establish 120 fps media decoding.

Add acceptance sweeps for 1920×1080, 3840×1080, 7680×1080, and 15360×1080 composition canvases,
with both full-canvas layers and sparse slice coverage. State sink count and each sink's resolution
and refresh. “Arbitrary output size” needs capability/memory limits and a preflight result rather
than an unconditional real-time guarantee.

The current proposal demotes Metal I/O and ICBs in one place while retaining mandatory/zero-cost
claims elsewhere. Resolve those contradictory requirements before adoption. Its throughput and
Snappy-per-core estimates are planning arithmetic, not evidence that all tiers are comfortable.

Windows is a **required later product**, while Mac remains the target market and first release.
Separate apps or repositories are acceptable. They should mostly advance together with roughly
matching features; identical UI and every platform-specific feature are not required.
Moveable/dockable panels are explicitly **way later**. V1 has fixed Perform and Map layouts;
Effects, remotes, docking, and Windows have later delivery stages.

## 2. Recommended stack and ownership

| Responsibility | Recommended choice | Reason |
|---|---|---|
| GPU resources, command submission, presentation, native media and capture adapters | Swift + Metal/MetalKit + CoreVideo/VideoToolbox | One owner for Apple objects, texture lifetimes, and GPU synchronization. |
| Shader execution | MSL; prebuilt pipelines first | Keep native Metal access; avoid live shader compilation on the playback path. |
| Documents, logical graph, scheduling decisions, transport, portable codec logic, render IR and blend semantics | Shared Rust core | Reuse behavior across Mac and Windows while keeping Apple objects and graphics execution in the Mac shell. |
| Container demux | Existing libavformat initially | Preserve compressed HAP packets and avoid writing MOV/MP4/AVI/MKV parsers before evidence demands one. |
| HAP texture decoding | Reference-compatible HAP block decoder | A generic decoder returning RGBA would discard the fast compressed-texture path. |
| H.264/HEVC/ProRes | Native VideoToolbox adapter where supported; explicit software fallback | Report the actual decode path, output format, and hardware/software status. |
| Native UI | SwiftUI panels + AppKit collections where needed; Metal for projection canvas | Avoid writing a custom GPU UI framework before normal native controls prove inadequate. |
| Control service, later | Rust axum with its WebSocket support, OSC, mDNS | Keep network work outside rendering; avoid separate WebSocket plumbing unless needed. |
| Web remote, later | React + Vite + strict TypeScript + Tailwind + Zustand | Appropriate for a LAN controller. No need for Next.js or another renderer. |
| iOS remote, later | SwiftUI | Same versioned engine protocol; independent presentation shell. |
| Windows product, later | Separate native shell and renderer; choose its stack when the port starts | Consume the same Rust core and document; avoid making Mac performance depend on an early Windows backend choice. |
| Bench | TypeScript orchestration, FFmpeg corpus, Python analysis | Add a separate measurement interface; controlling an app is not measuring its frames. |

Claude's expanded V2 already narrows Rust and assigns Apple framework work to Swift. That change
is sound. Its architecture diagram still places the VideoToolbox bridge in the Rust core; adoption
must align the diagram, ownership table, and directory layout.

**Should the languages change?** My recommendation is to retain this hybrid with Swift owning the
Mac render/media runtime and Rust owning shared behavior. The later Windows requirement gives the
Rust core a concrete purpose: portable transport, document, graph, codec, and compositor semantics.
A Swift-only shared engine no longer fits these requirements well. That is an architecture decision,
not evidence of a Rust frame-rate advantage. GPU work, memory traffic, decode, and deadline
management still decide performance.

Before creating the full core, exercise the proposed Rust–Swift boundary with a small release-build
spike. Transfer one batch of frame-plan data, process an asynchronous decode completion, retain
resources through GPU completion, and measure allocations and copies. If the generated bridge
requires recurring bulk copies or complicated ownership, revise the bridge and the boundary first.
Keep shared behavior in Rust; do not trade the Windows requirement away to hide an inefficient
bridge.

Use resource IDs with generations in the logical graph. Swift's resource registry resolves those
IDs to retained Metal textures. Rust should not own raw Metal object pointers. A generated bridge
does not automatically make a vector or byte buffer transfer free.

Replace “crossed once per frame” with “one batched render-plan exchange; separate lifecycle and
worker-completion exchanges as required.” Rendering should avoid individual per-layer bridge calls.
Decode scheduling, source changes, and completion events still need a practical asynchronous
contract. Define ownership, cancellation, pointer lifetime, layout, and error behavior explicitly.

FFmpeg remains native C behind bindings. Choosing Rust does not make all codec and container
parsing memory-safe. Use bounded inputs and clear failure handling rather than claiming a language
choice eliminates malformed-media crashes.

HAP's official integration guidance explicitly supports obtaining compressed packets with
libavformat and decoding them into compressed texture blocks; HAP Q also needs YCoCg conversion.
That conversion belongs in the source sampling shader, with a correctness test.
[HAP developer guidance](https://hap.video/developers.html),
[FFmpeg demuxing API](https://ffmpeg.org/doxygen/9.0/group__lavf__decoding.html).

### Windows readiness with a native Mac renderer

Choose **shared behavior, platform-owned execution** now:

| Shared in Rust | Owned by each platform shell |
|---|---|
| Versioned project model, stable IDs, migrations, commands, transport, cues | Windows, panels, input events, display enumeration and presentation |
| Logical graph, dirty generations, effect insertion points, resource dependencies | GPU allocation, resource registry, synchronization, shader/pipeline objects |
| Codec/block semantics, scheduling policies and bounded budgets | Native hardware decode, capture, inter-app video and device adapters |
| Blend equations, layer order, alpha/color semantics, render-plan/IR representation | Metal execution on Mac; a later Windows renderer |
| Control protocol, authoritative state and reconciliation | Platform capability reporting and optional feature availability |

No CoreVideo, AVFoundation, Metal object ownership, or Apple framework links belong in the shared
core. Keep native library adapters separate where necessary. Introduce small boundaries for the
capabilities actually used by V1; don't implement hypothetical Windows adapters or a universal
graphics API now.

Keep native Metal on Mac. A future Windows implementation may use wgpu or D3D12, selected against
Windows requirements when that work begins. Windows support does not establish an acceptable
20–30% Mac performance loss, nor require moving the Mac render path to wgpu.

Define blend/operator semantics once and keep a platform-neutral logical IR. Start with a small
typed operation set or shader-template emitter for the supported blends. Emit MSL initially;
add another emitter when Windows starts. This shares the mathematical definition without making
a general optimizing shader compiler a V1 prerequisite. Device-specific optimizations may use
different execution strategies provided conformance fixtures prove the same required result.

Support master and per-layer effects as explicit graph insertion points. A per-layer effect may
materialize a texture and rejoin the compositor; a pointwise effect may later fuse. The node editor
can arrive later without changing the project model or imposing one pass on every workload.

Use shared document/command fixtures and color/blend reference results to test both platforms.
When the core exists, build/test it in Mac and Windows CI to catch accidental platform coupling;
Mac GPU acceptance still runs on the base M4. The Windows GPU acceptance matrix is defined when
its renderer starts.

One core remains authoritative even if the apps use separate repositories. Pin each app to an
exact core release/revision and publish its core, document, and protocol versions. Coordinate
feature changes through that core release and shared fixtures, with an explicit capability matrix
for supported differences. Do not copy the crate or maintain a second project schema. Allow
platform layouts to differ while preserving recognizable commands, project behavior, and compatible
files.

This readiness work has a real cost: a clear boundary, a small shared semantic model, and portable
tests. Time-box it in R0/R1. “Later Windows” must not become an excuse to build a cross-platform UI,
second renderer, or general shader compiler before the first working Mac slice.

## 3. Changes to the performance hypotheses

### H1: linked libraries do not establish the active render path

The documented binary linkage is useful evidence about dependencies. It does not establish that
every composition draw uses both OpenGL and MoltenVK, or that the two are sequential translation
layers. Attribute the active path through a trace. Shader translation is also not automatically a
per-frame expense: MoltenVK supports cached translated shaders.
[MoltenVK runtime guide](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Runtime_UserGuide.md).

Retain native Metal, but measure steady playback separately from cold pipeline creation. An Arena
versus Photon result is a whole-application comparison, not a controlled experiment isolating
translation overhead. Use CPU/GPU traces to support attribution; otherwise report the observed
delta without assigning its cause to H1.

### H2: unified memory does not make a compressed texture alias a raw buffer

The proposed `snappy → MTLBuffer → MTLTexture` zero-copy route is not established. Apple's
buffer-backed linear texture API accepts ordinary or packed color formats, rather than BC
compressed formats. Shared physical RAM does not remove texture layout and API restrictions.
[Metal buffer-backed texture restrictions](https://developer.apple.com/documentation/metal/mtlbuffer/maketexture(descriptor:offset:bytesperrow:)).

Start with a known-correct pooled path: decode HAP to compressed blocks in staging storage, then
copy/upload into a supported compressed texture. Measure direct compressed-texture updates against
buffer-to-private-texture blits on the target GPU. Remove copies when a supported path demonstrably
improves total frame time. A private texture plus one efficient blit may outperform a superficially
more direct path.

### H3: compare render passes, draw calls, and actual memory traffic

One draw per layer does not imply one render pass or a stored intermediate per layer. A shared
render attachment can receive multiple draws before a final store. Tile-local processing is
valuable, but tile shaders are not the only starting point.
[Apple's single-pass rendering example](https://developer.apple.com/documentation/metal/rendering-a-scene-with-deferred-lighting-in-objective-c).

Compare four implementations on resident textures: ordinary ordered draws with supported
fixed-function modes, ordered draws using programmable fragment blending, a fused fragment shader,
and a tile/imageblock implementation. Use a correct multi-pass reference for modes that need it.
Compare identical semantics and validate blend order, transparency, transforms, and mixed source
formats before comparing timings. Measure GPU time, CPU submission, bandwidth, and shader
occupancy. Do not choose the most elaborate implementation by default.

Claude's later §3.5.3 favors register folding for 4–12 layers. That is a reasonable candidate,
not an established winner. Its alternatives omit programmable blending from fragment functions,
which can access attached render targets without requiring a tile compute pipeline. Check the
target's support and order guarantees. Also classify each blend's alpha/color semantics: some
multiply, screen, and mask formulations map to ordinary blend factors; others need programmable
access. Avoid a blanket claim that all of them require the same machinery.
[Apple on programmable blending](https://developer.apple.com/videos/play/wwdc2020/10602/).

For wide canvases, test geometry bounds and scissoring before adding per-tile shader variants.
Keep a correct generic blend shader as an immediate fallback. Specialize asynchronously and bound
the pipeline cache; a new live blend stack or moving tile membership must not trigger blocking
compilation. Function stitching is not evidence that pipeline creation has no cost.

Distinguish attachment stores from MSAA resolves. For ordinary non-MSAA composition, “N resolves”
can obscure which operation is actually expensive.

Use argument-buffer arrays of individual texture references for heterogeneous inputs. A single
2D-array texture has a shared descriptor; forcing different sizes, pixel formats, and video planes
into it creates conversions and copies.

### H4: unchanged images, changing timelines, and final composition are different

A near-static video is still advancing through timestamps and decoded frames. It is not an
unchanged source node. Benchmark still images, paused clips, near-static playing video, and moving
video separately.

An unchanged source can avoid decode, upload, and its own effect processing. It may still be
sampled when a changing layer forces recomposition. A reference to a cached texture does not make
that compositing work free.

Introduce dirty generations and time-dependent nodes early. Cache contiguous static subgraphs
where blend semantics permit, and measure the extra pass/cache cost. Feedback reads previous-frame
state through an explicit temporal edge; it cannot be treated as an ordinary cycle in a DAG.

### H5: Metal I/O is an experiment, not a required native media format

Metal I/O supports asynchronous resource loading and inline decompression of packed assets.
Concurrent loads can complete out of order. Apple's documentation does not establish the proposal's
claim of zero total CPU work or a guaranteed hardware decompressor for this workload.
[Apple Metal resource loading](https://developer.apple.com/documentation/metal/resource-loading),
[Apple's fast resource loading session](https://developer.apple.com/videos/play/wwdc2022/10104/).

Prototype identical compressed texture blocks through conventional file I/O and Metal I/O.
Measure completion-latency tails, request overhead, sequential playback, random seeks, reverse
playback, cancellation, cue transitions, and deadline misses. Load ahead into a bounded pool; a
missing frame must not stall all outputs while rendering waits for a file operation.

Keep HAP as a first-class playback format. If Metal I/O wins, begin with a disposable derived cache
containing a frame index and texture blocks. Do not make operators transcode their libraries into
a new mandatory format before the gain is measured.

Photon-native versus Arena DXV is a different workflow comparison. It must disclose conversion
time, visual quality, storage footprint, and memory use, alongside the same-file playback tests.

### H6: an indirect command buffer does not remove every per-layer CPU cost

ICBs can reuse commands encoded by the CPU or accept commands generated by a GPU kernel. Simply
allocating one does not make rendering GPU-driven. Apple documents both approaches.
[CPU-encoded ICB example](https://developer.apple.com/documentation/metal/encoding-indirect-command-buffers-on-the-cpu),
[GPU-encoded ICB example](https://developer.apple.com/documentation/metal/encoding-indirect-command-buffers-on-the-gpu).

For a modest ordered 1–32 layer stack, first measure ordinary CPU encoding and reusable CPU-encoded
ICBs. GPU command generation adds its own dispatch and dependency cost. Decode scheduling and
changed layer data can still scale with layer count. Replace “CPU cost is flat/zero” with the
specific measured reduction in command-encoding cost.

### H7: fuse selected operators after implementing a correct graph

Pointwise operators are good fusion candidates. Some neighborhood operations can also be fused
by recomputing samples, with a potentially unfavorable cost. Feedback and reductions need explicit
dependencies. “Every blur breaks fusion” and “every TOP costs a resolve” are too broad.

Begin with a small supported operator set and a simple render planner. Add a compiler only after
traces identify representative chains whose measured bandwidth/dispatch cost justifies it.
Compile away from playback; switch to a complete new plan at a frame boundary.

**Metal version:** one native Metal renderer is sufficient. Choose and document a minimum OS and
GPU capability set. Use the established command API for the first measurable prototype, then
adopt Metal 4 where it reduces measured submission cost. Do not create two permanent command
implementations merely to say “Metal 3/4.”
Apple supports incremental Metal 4 adoption.
[Metal 4 core API](https://developer.apple.com/documentation/metal/understanding-the-metal-4-core-api).

## 4. Correct the storage and memory model

Claude §2.5 calculates roughly 498 MB/s for one 4K60 HapQ layer before Snappy compression:
`3840 × 2160 × 1 byte × 60`. That is useful decompressed block throughput, not a measurement
of bytes read from disk. The on-disk rate depends on compression, clip content, chunking, shared
sources, time offsets, cache hits, and the working set.

“Storage-bound beyond about 12 layers” is a hypothesis. This Mac's SSD throughput was not measured,
and repeated loops can be served from the OS file cache. A RAM-resident ring is useful for bounded
prefetch, but a short ring cannot overcome insufficient sustained storage bandwidth.

The development machine has 36 GB of memory; the acceptance target is 32 GB. One minute of 4K60
BC3 blocks is about 29.86 GB; sixteen
such full clips are about 477.76 GB, before Snappy compression. One minute of 8K60 BC3 is about
119.44 GB. Do not design around a 128 GB machine or fully preloaded large libraries.

Define separate budgets for encoded read-ahead, decoded compressed blocks, native decoded video
frames, persistent textures, transient render targets, and UI thumbnails. Include the OS cache and
memory pressure in reporting. Cap worker concurrency and avoid multiplying per-decoder thread
pools across dozens of layers. Defer sparse textures and aggressive heap aliasing until a measured
working-set problem warrants their synchronization complexity.

Benchmark three different workloads explicitly:

| Workload | Measures |
|---|---|
| Resident textures, no media decoding | Compositor scaling and submission overhead |
| Warm file-backed playback | The practical looped/cued playback path, including decode |
| Sustained large working-set streaming | Storage, prefetch, and decode under ongoing I/O |

Use both shared-source and independently timed source cases. Reusing the same frame across every
layer can be a legitimate optimization, but cannot establish independent-stream capacity.

## 5. Runtime design before advanced optimization

Use one authoritative composition clock and rational media timestamps. Presentation adapters
map that timeline to each output's refresh and deadline; mixed-refresh displays are not one shared
vsync source. Use display-aware presentation such as CAMetalDisplayLink where the selected OS
supports it, rather than a main-thread timer.
[CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink).

The render path consumes prepared state and ready frames. It does not perform file I/O, await
network messages, compile shaders, synchronously wait for decode, write CSV, or wait for GPU
completion. Preallocate bounded frame/resource pools. Retain source resources until every GPU
and output consumer has finished with them.

Use bounded queues with defined backpressure: preview may discard old frames; control messages
reconcile to current state; recording must surface overruns. A separate encode queue still shares
memory bandwidth and hardware resources, so measure output interference.

Preserve the last valid frame when a media source underruns or fails, with visible operator status.
Output blackout remains an explicit operator command. Apply document changes and completed render
plans atomically at frame boundaries. Save/load, recovery, device disconnects, and cue transitions
belong in the first usable product.

Carry a source/frame descriptor containing resource IDs and generations, dimensions, pixel format,
planes, timestamp/timebase, color primaries, transfer function, matrix/range, and alpha convention.
Perform YUV or HAP Q conversion in source sampling where suitable. Match Arena's output bit depth
and color behavior when comparing, rather than obtaining speed by doing less color work.

Introduce a render graph that permits intermediate resources and output passes. A practical chain
is source preparation → effects → layer composition → slice/warp/color conversion → sinks.
Fusion and aliasing are planner optimizations, not rules forbidding necessary work.

Replace the original absolute invariants with:

- Keep the compositor and GPU effects free of synchronous CPU frame readback.
- Store/export the finished composition when another pass or external consumer requires it.
- Permit bounded asynchronous readback in output adapters and correctness tests; count its cost.
- Fuse compatible work when evidence supports it; preserve a correct unfused reference.
- Generate consumer types from one authoritative document definition.

This resolves existing conflicts: a memoryless tile result cannot be handed to an external consumer
after the pass; Art-Net needs CPU-visible packet data; the standard NDI send API accepts linear
frame memory and retains it during asynchronous sending.
[NDI frame types](https://docs.ndi.video/all/developing-with-ndi/sdk/frame-types),
[NDI asynchronous send](https://docs.ndi.video/all/developing-with-ndi/sdk/ndi-send).

Keep separate concepts for composition, output canvas, slice, and physical sink. A slice is a
mapped region; a sink owns refresh, mode, color capabilities, and delivery. Hardware splitters,
physical displays, and network sinks should not acquire identical synchronization promises.
Do not promise genlock from ordinary display presentation alone.

One materialized composition can feed many slices, but independent sink textures and drawables
still require destination rendering and synchronization. “One extra pass total” is only justified
for slices rendered into one shared destination; multiple physical/network outputs must have their
actual pass, conversion, and delivery costs counted.

## 6. Benchmark architecture that can support a claim

**Control and measurement need separate adapters.** Resolume's published API supports composition
loading, layer changes, and clip triggering. In the reviewed 258-path OpenAPI specification, the
composition `framerate` is explicitly a target rate; video file `framerate` is media metadata.
No raw rendered-frame timing stream was found in that specification. This does not rule out another
supported measurement route, but its existence cannot be assumed.
[Resolume API documentation](https://resolume.com/support/en/restapi),
[published API specification](https://resolume.com/docs/restapi/swagger.yaml).

Do a measurement feasibility check before implementing the large harness: capture a short Arena
run with a supported trace or external observer, establish what events it exposes, and document
sampling precision and overhead. If only average FPS is available, report only that. Do not derive
frame-time percentiles from a periodically sampled average FPS counter.

Photon telemetry should distinguish CPU preparation, GPU execution, presentation interval,
decode lateness, repeated source frames, output deadline misses, and queue depth. These are
different metrics. A GPU command duration is not the interval between frames on a projector.

Fairness must lock source and output resolutions separately, source cadence, composition cadence,
vsync, bit depth, blend modes, opacity/occlusion, effects, previews/UI, output sinks, cache state,
power/thermal conditions, and hardware decode. Arena's Auto mode follows display refresh, so a
60 Hz cap can hide extra throughput. Use matched deadline tests; label a run “uncapped” only after
confirming the actual behavior of both targets.
[Resolume composition frame-rate behavior](https://resolume.com/support/en/composition).

Avoid an opaque top layer hiding the workload below it. Confirm that the chosen scene exercises
the intended sources and blends. Also validate output correctness, alpha and color behavior,
mixed dimensions, seeks, loops, transitions, and cached-vs-uncached results.

Freeze each batch configuration and record its hash, corpus checksums, tool/application versions,
Git SHA, settings, cache mode, measurement method, and limitations. Persist raw events with explicit
units and timestamps. Unknown metrics are null/unavailable, not zero. Keep synthetic/stub results
visibly separate from measurements and exclude them from real performance comparisons.

Use a tiered run schedule: capability preflight, short correctness smoke runs, representative
1/4/8/16/32-layer sweeps, then ten-minute repeated validation for the cases supporting a claim.
Interleave or randomize target order under fixed thermal rules. State repetition count and aggregate
variation across runs, rather than pooling all frames and calling it independent evidence.

Seven codecs × three resolutions × five layer counts × two motion classes × two engines ×
ten minutes already means **70 hours for one sweep**, excluding warm-up, cooldown, failures, DXV,
and repetitions. The full Cartesian product should not be the default development command.

Add still-image/paused-source cases for H4, alpha content, explicit source FPS, deterministic seeds,
pixel/color formats, HAP chunk/compressor settings, and encoder build information to the corpus
manifest. Use short high-resolution fixtures initially and calculate storage before generation.
A Snappy-enabled FFmpeg build or a tested alternate HAP encoder is a prerequisite; do not replace
the installed FFmpeg globally just to conceal the missing capability.
[HAP encoding requirements](https://hap.video/using-hap.html).

P0 can remain Codex's lane, but it depends on telemetry contracts and measurement feasibility.
It is not completely independent of engine instrumentation.

## 7. Smaller first release and revised build order

The original P3 combines several substantial products: projection mapping, many capture/output
adapters, recording, virtual camera, LED pixel mapping, and a native performance UI. Requiring all
of them before a usable V1 makes both schedule and performance attribution harder.

| Stage | Concrete deliverable | Acceptance evidence |
|---|---|---|
| R0 — decisions and contracts | Measurement route, fairness, frame/resource boundary, minimal document schema | Short Arena trace interpreted correctly; reviewable contracts; FFI/resource-lifetime spike |
| R1 — vertical playback slice | One HAP layer, native window, basic transport, save/load, telemetry | Correct output and frame cadence; bounded memory; graceful missing/late media |
| R2 — measured composition | Layer sweep, DXV compatibility adapter, selected blend modes, transforms, dirty generations, resident and media tests | Correct reference output; CPU/GPU/deadline distributions; base-M4 tier/canvas results; measured implementation choice |
| R3 — first show workflow | Clip/deck control, cues/preload, recovery, physical output, Syphon, quad/grid warp, soft edges | Sustained playback plus cue changes and output/source disconnect tests |
| R4 — explicit I/O additions | Add NDI, capture, DeckLink, LED output, recording, virtual camera in measured increments | Report the cost of each sink/source and supported limits |
| R5 — node product | Expand graph/operators, then editor and selective fusion | Representative graph correctness and measured fusion gains |
| R6/R7 — remotes | Control protocol, browser preview, web and iOS clients | Reconnect/state tests and measured preview interference |
| R8 — moveable UI, way later | Dock/undock/float, layout editor, multi-monitor panel placement | Stable panels and render targets survive layout changes; versioned layout migration |
| W — Windows product, later | Platform adapters, renderer and native shell consuming the released Rust core | Shared document/command/blend fixtures pass; Windows-specific performance and capability results |

Define the persisted document model in R0/R1. A product that saves projects at P3 cannot postpone
the authoritative schema until P5. Start with versioned JSON, stable IDs, media references, layers,
outputs, and migrations. Defer CBOR until measured load time justifies a second serialization.

Make a small internal graph/planner part of R2; postpone the public node editor and general
compiler. This tests dirty scheduling before the rest of the engine hardens around a fixed pipeline.
Keep its logical IR and shared semantics platform-neutral from R0 onward; Windows execution code
arrives in W.

HAP first for the vertical prototype; add hardware-decoded common media next as needed. Develop
read-only DXV as a separately scoped compatibility adapter, so its unknowns do not block initial
playback or force a custom media format. **DXV3/DXV4 support is required before declaring the
recorded target tiers or first DXV show workflow met.** A HAP-only prototype does not satisfy that
requirement. No DXV implementation or legal conclusion is established by this review.

Use SwiftUI for ordinary inspectors and controls, AppKit collections if virtualization requires it,
and a Metal projection canvas. Preserve the requested Perform/Map personas, familiar clip/layer
controls, thin shell, persistent performance controls, and per-persona layout. Persona changes
must never alter program output; include performance locking and keyboard access.

Treat the grid's animated thumbnails as a bounded shared rendering surface, separate from
interactive controls. A grid containing 128 clip slots does not imply 128 independent video
decoders: static/precomputed thumbnails serve idle clips, and ready source textures serve playing
clips. Measure the Metal thumbnail surface and native control virtualization on the base M4.
Avoid deciding that every piece of UI must be a custom Metal widget before that measurement.

Docking is explicitly out of V1 and lands at R8. Prepare with position-independent panel views,
stable serializable panel IDs, fixed layouts described by a small declarative tree, persisted
per-persona UI state, and preview/render-target references by engine ID. Panels get their size from
their container and data from shared state; they do not own output windows. Keep this UI layout
state separate from the cross-platform project document. Do not build a partial docking system now.
Isolate program rendering from main-thread UI stalls.

Define the first show's required I/O with Aiden before committing to the full catalog. Physical
output and Syphon are the proposed starting subset; this is a scope recommendation, not deletion
of a working feature.

No credible delivery date follows from the present scaffold. Re-estimate after R1/R2 reveal media,
FFI, correctness, and pacing costs. The main schedule risks are a new clip format, a general shader
compiler, custom GPU UI, and attempting every output adapter before the first show.

### Sequencing and time budgets

The recorded instructions specify relative timing (“later” and “way later”), not calendar dates.
Use the following delivery order and dependency gates; dates follow the first working prototype.

- **Now, R0/R1:** freeze the minimal contracts, measure the Arena observation route, establish the
  shared Rust/platform boundary, and get one correct native Mac playback slice running. Time-box
  the bridge and upload experiments to a few focused working days rather than an open-ended study.
- **Next, R2/R3:** deliver DXV compatibility, tier/canvas measurements, fixed Perform/Map layouts,
  cue/transport behavior, and the chosen first-show I/O. The first Mac show workflow is the release
  milestone. Performance Lock, persistent master controls and the command palette belong here.
- **After that, R4/R5:** add explicitly needed I/O adapters and the Effects/node surface. Transport
  and operator bindings should accommodate BPM, MIDI, OSC, and timecode as requirements demand;
  platform adapters arrive with the stage needing them.
- **Later, R6/R7:** control service, browser preview and web/iOS remotes. Internal native commands
  use the authoritative model from the start; network implementation and client UIs follow here.
- **Way later, R8:** user-editable docking/floating layouts. V1 only prepares the stable panel model.
- **Later, W:** start Windows after the shared core and Mac workflow are stable enough to consume.
  W need not wait for docking or identical feature lists. Choose its renderer/UI then, and coordinate
  releases around shared behavior and compatible files.

The “few working days” is a proposed experiment budget, not a product delivery promise. Stop an
experiment at its decision point and proceed with the supported baseline. Do not repeat all
compositor experiments before every feature: use one correct baseline and run focused comparisons
when they affect the chosen workload. Full show-ready delivery, node tooling, and Windows cannot be
credibly dated from the current files.

## 8. Later remote architecture and actual web scaffold

Keep React/Vite; no renderer or server framework replacement is warranted. When the remote starts,
enable `strict` in both referenced tsconfigs, wire the installed Tailwind Vite plugin and stylesheet
import, and remove unused `vite-plugin-top-level-await` if the resulting client has no requirement
for it. Preserve the lockfile and global design tokens.

Use Zustand selectors scoped to each control, coalesce frequent telemetry, virtualize large grids,
and keep preview video outside React state. Load heavy editors only when opened. Treat confirmed
engine state and pending optimistic commands separately, with revisions, command IDs, replay rules,
and reconnection snapshots. The current template has no controller functionality to benchmark.

Specify a browser-compatible preview transport. Encoded H.265 alone is not a transport, and a
browser does not automatically become an NDI receiver. Prefer a measured WebRTC preview with
H.264 as the initial interoperability target and negotiate newer codecs when supported. WebRTC's
baseline requirements include VP8 and H.264, rather than HEVC.
[WebRTC codec requirements, RFC 7742](https://www.rfc-editor.org/rfc/rfc7742).

Share a low-resolution/rate preview where practical, cap its resource budget, and drop preview
frames before risking program deadlines. Keep NDI as a distinct native/network adapter.

mDNS advertisement is appropriate, but a normal browser client should not be assumed to enumerate
Bonjour services. Provide an engine-displayed URL/QR code and manual address fallback. Native
clients can discover services through their platform APIs. Keep pairing and version negotiation;
design them before remote state synchronization.

## 9. Decision proposed for adoption

Adopt the native Metal direction and the Swift-owned render/media runtime with a bounded Rust CPU
core shared with the later Windows app. Adopt measured render planning, explicit
resource/timestamp/color contracts, bounded caching, and a smaller show-ready Mac release.
Keep fixed Perform/Map layouts in V1, the later Effects and remote clients, and docking at R8.

Before engine scaffold work proceeds, resolve these five items:

1. Freeze fairness and telemetry contracts, including an actual Arena measurement route.
2. Validate the generated Rust–Swift bridge's layout, copies, asynchronous behavior, and lifetimes.
3. Specify the supported HAP texture upload path and test output correctness.
4. Budget for the 32 GB base-M4 target, tag 36 GB M4 Max dev runs, and separate resident, cached,
   and streaming tests.
5. Define the first show's output/control subset and versioned document, then verify the recorded
   DXV tiers on the base M4 with explicit composition canvases and sink topology.

The Windows adaptation makes the shared Rust core and portable semantics a deliberate commitment.
It leaves the Mac performance recommendations intact: native Metal execution, supported
compressed-texture uploads, batched FFI with explicit lifetimes, bounded memory, a render graph
that permits necessary passes, and valid frame/deadline measurements.

Treat Metal I/O, mandatory native media conversion, tile shaders, GPU-generated ICBs, sparse
textures, heap aliasing, and general operator fusion as independently measured experiments.
Their failure must not require redesigning the product.

Judge success by correctly rendered, reliably paced frames, cue responsiveness, and usable layer
capacity at the required output rate. Publish higher FPS when a controlled comparison demonstrates
it. The node graph and live-show workflow remain useful even if Arena's performance is already close.
