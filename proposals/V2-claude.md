# Photon — V2 Proposal (Claude)

**Author:** Claude Code agent. **Owner:** Aidxn Design (personal). **Date:** 2026-10-12.
**Status:** proposal, submitted for higher-model review. Not adopted. No production code yet.

> This is **one input to a decision**, not the project's source of truth. If it wins review it gets
> adopted and `PLAN.md` points at it; if a better proposal lands, this one is retired to
> `proposals/_retired/`. Competing proposals live alongside it in `proposals/` — they are never
> merged into each other.

**What changed from V1:** browser removed from the render path entirely (Aiden's call); Rust core
narrowed so Swift owns everything touching an Apple framework; full I/O matrix added (Syphon in,
NDI, DeckLink, capture, Art-Net/sACN out); and an optimisation pass that found three stronger GPU
mechanisms plus a storage bottleneck that moves the optimisation target (§2.5).

A realtime media server + projection-mapping engine. Resolume Arena's clip/deck/compositor model,
with TouchDesigner's compiled-DAG approach to keeping everything resident on the GPU — targeting
higher sustained frame rate than Arena on the same machine, same files, same output.

**v0.2 change:** the browser is out of the render path entirely. Decided 2026-10-12.

---

## 0. Settled: native engine, remote control surface, later

**Decided by Aiden 2026-10-12 — closed, not up for review.**

- **The engine is a native macOS app. Metal. One backend, hand-tuned.** This is the whole product.
- **The web app is a remote control surface for an engine running on a different machine**, over the
  LAN. Operator on a laptop or tablet at FOH, render machine at the projectors. This is the standard
  live-production topology and it is also how Resolume, MadMapper and Hippotizer are actually used.
- **That control surface is a later phase.** V1 is the native engine with its own native UI. The
  remote surface comes after the engine is real and fast.
- **iOS is the same control surface in a second shell.** Not a renderer. Not ever.

Consequences, all of them simplifying:

- **No `backend-wgpu`. No WASM core. No graphics abstraction layer in the core at all.** The core
  targets Metal directly and can use argument buffers, TBDR tile memory, `MTLHeap` aliasing and
  Metal 4 features without hiding them behind a lowest-common-denominator API. This is worth real
  frame time — see H3.
- **The web app never renders a frame.** Preview is an encoded stream from the engine (see §3.2).
- **Networking becomes a first-class design concern**, not an afterthought: discovery, latency under
  venue wifi, reconnect without losing operator state, and authentication on an untrusted network.

Why a browser could never have been the engine, recorded so this doesn't get relitigated:

| Constraint | Reality in a browser |
|---|---|
| Frame pacing | Hard-capped at display vsync via `requestAnimationFrame`. No 240Hz headroom, no genlock. |
| DXV / HAP decode | No native support. Would need our own demuxer + snappy in WASM — an extra CPU hop Arena doesn't pay. |
| BC texture upload | WebGPU `texture-compression-bc` is **desktop-only. Safari and all of iOS expose ASTC, never BC.** |
| Projector output | No control over display mode, refresh, EDID, bit depth, or which GPU scans out. No Syphon, no NDI, no DisplayPort MST. |
| iPhone as renderer | Thermally throttles within minutes under sustained GPU load. Cannot drive a projector at all. |

---

## 0.6 ⭐ Windows is a requirement (Aiden, 2026-10-12) — and it reverses two earlier decisions

**"Later, but it's a need. Main performance goals are Mac right now."**

Recording this honestly: §0 justified "Metal only, hand-written, one backend" and "Swift owns
everything touching a framework" **partly on the grounds that there was only one platform.** That
premise is now gone, so both decisions have to be re-taken rather than patched.

### What saves us: §3.5.3 already moved off the Apple-only mechanism

Tile shading and imageblocks are Apple-specific and have no portable equivalent — they were the
reason for going Metal-only. But §3.5.3 chose **register folding** instead, for *capability* reasons
(mask and difference need destination access), and register folding is **just a fragment shader
sampling N textures and folding in registers**. That is trivially expressible in WGSL, HLSL or MSL.

**The compositor design is already portable.** That's a lucky convergence, not a plan, but it's real.

### And the §1.5 spec makes the portability tax affordable

At 1080p the GPU runs at **~2% of memory bandwidth** with >10× sampling headroom. A portable
abstraction costing even 20–30% of GPU time is invisible against that margin. **Had the spec stayed
at 4K/32 layers, hand-written Metal would be mandatory. At 1080p/12 layers it isn't.**

### ⭐ Refined by Aiden (same session): *"They can be independent programs or repos, but they'll eventually need to mostly update together with roughly the same features — not all the same, that's fine."* and **"Mac is our target market."**

That changes the answer again, and in the opposite direction from the paragraph above. **Two
independent apps are permitted. Mac is the product.** So don't force a portable shell on the Mac
build to serve a platform that is neither the market nor the near-term deliverable.

**The model: one shared core, two shells.**

```
photon-core (Rust crate)  ← THE shared thing. No OS API, no graphics API.
├── container/ codec/ (DXV, HAP, snappy)   ├── graph/ (DAG, dirty cook)
├── ir/ (compositor IR → shader codegen)   ├── clock/ (transport, BPM, timecode)
├── doc/ (.photon schema — source of truth) └── net/ (control server)
          │                                           │
   ┌──────▼───────────────┐                  ┌────────▼─────────────┐
   │ Photon macOS         │                  │ Photon Windows       │
   │ Swift + Metal (+MSL) │                  │ Rust + wgpu/D3D12    │
   │ THE PRODUCT. V1.     │                  │ Later. Separate repo │
   │ Native, hand-tuned.  │                  │ ok. Feature-parity-ish│
   └──────────────────────┘                  └──────────────────────┘
```

| | Decision |
|---|---|
| **Core** | **Rust crate, shared verbatim.** Contains **zero** Apple API. This is the non-negotiable discipline — it's what makes "update together with roughly the same features" possible at all. |
| **macOS graphics** | **Hand-written Metal.** Target market, best perf, and §1.5's spec is verified here. |
| **macOS UI** | **Swift + SwiftUI shell**, with grid/previews/mapper rendered in Metal (§3.5.1). |
| **Windows** | Separate app, own repo, **own renderer and UI.** Likely Rust + wgpu. Decided *when the port starts*, not now. |
| **Parity** | Enforced by the shared core + a shared `.photon` document, **not** by a shared UI. Feature drift in the shells is explicitly acceptable. |

**Why not force one portable codebase:** the UI is the largest workstream in this project (docking
alone is P8) and Mac is the market. Making the Mac build worse to pre-pay for a later platform is the
wrong trade. **And the decision doesn't need making now** — if the core stays genuinely platform-free,
the Windows shell technology can be chosen when that port actually begins, with better information.

**The one thing that must be enforced from day one** is therefore a *discipline*, not a technology:
> **No Apple API in `photon-core`. Ever.** Platform capabilities sit behind Rust traits, implemented
> per-OS in the shells. The moment `CoreVideo` or `AVFoundation` appears in the core crate, the
> Windows port becomes a rewrite instead of a port — and that failure happens quietly, months before
> anyone notices.

A CI check that fails the build if the core crate links any Apple framework is cheap insurance and
should exist before the first line of Windows code.

**Dropped from the previous paragraph:** the wgpu-everywhere and egui recommendations, and the
"widen Rust back out" reversal. Those were right for *one portable app*; they're wrong for *two
independent shells with a shared core*. The Swift-owns-framework-I/O decision from §3.0 **stands for
the macOS shell** — it just no longer applies to the core.

### Platform I/O — the real Windows work

Every item in §3.3's matrix needs a Windows counterpart behind the same trait:

| Capability | macOS | Windows |
|---|---|---|
| **Inter-app video** | **Syphon** | **Spout** *(the direct equivalent)* |
| Screen capture | ScreenCaptureKit | Windows Graphics Capture |
| Camera / UVC | AVFoundation | Media Foundation |
| H.264/HEVC decode | VideoToolbox | Media Foundation / NVDEC / DXVA2 |
| Capture cards | DeckLink SDK | DeckLink SDK *(same SDK)* |
| NDI, Art-Net/sACN | libndi / libArtnet | *same libraries — already cross-platform* |
| Display/output control | CGDirectDisplay | DXGI |
| Virtual camera | CoreMediaIO | DirectShow / MF virtual camera |

**DXV/HAP decode, the DAG, the IR, the document model and the control server are all
platform-independent already** — they're pure Rust. The Windows port is I/O adapters plus a wgpu
backend, not a second engine.

### ⭐ "Completely separate repos if it means much better native performance for each" (Aiden, 2026-10-12)

**Answered directly: separate repos are the right call, but they will not buy native performance —
because nothing performance-critical is shared in the first place.**

The per-frame hot path is `decompress → upload texture → run shader → present`. Steps 2–4 are
entirely in the shell and already platform-native by design. Step 1 is pure compute where Rust is at
parity with anything. **The shared core contains no per-frame GPU work at all:**

| Core component | On the per-frame hot path? | Native-tunable? |
|---|---|---|
| Container demux | Once per frame, microseconds of byte parsing | No meaningful platform delta |
| snappy / LZ4 decode | Yes — but pure compute, already optimal | Same instructions either way |
| DAG + dirty cook | CPU bookkeeping, sub-microsecond at 12 layers | No |
| **IR → shader codegen** | **No — runs at cook time, not per frame** | Emits *native* MSL/WGSL anyway |
| `.photon` document | Load/save only | No |
| Clock / transport | Nanoseconds | No |
| Control server | Off-thread, not in the frame | No |

So the trade isn't "shared core vs. native performance" — **there is no such trade.** The things that
genuinely must be native (renderer, shaders, UI, platform I/O, display control) are already in the
per-platform shells, and nothing in this plan proposes abstracting them.

**What full duplication would actually cost — and one of these is a product bug, not a maintenance
annoyance:**

| If duplicated | Consequence |
|---|---|
| **`.photon` document schema** | 🔴 **A project saved on Mac won't open on Windows.** Product-level failure. Violates the house rule against forking a source of truth, in the place where it does most damage. |
| **Control protocol** | 🔴 A Mac engine couldn't be driven by a Windows remote, or vice versa. |
| **DXV/HAP demux + decode** | 🟠 Subtle container-parsing bugs get found and fixed twice, at different times. Codec edge cases are exactly where silent corruption lives. |
| Renderer / shaders | 🟢 **Should** diverge — native is the whole point. |
| UI shell | 🟢 **Should** diverge. |
| Platform I/O | 🟢 Must diverge by definition. |

### Recommendation

- **`photon-core` — one versioned Rust crate, shared.** Consumed by both apps as a dependency (git
  submodule or a private registry package), never vendored-and-edited. It is the *source of truth*
  for the document format, the codecs and the protocol.
- **`photon-macos` and `photon-windows` — fully separate repos.** Own renderer, own shaders, own UI,
  own platform I/O, own release cadence. Free to diverge in features; §0.6's "roughly the same
  features, not all the same" is satisfied here, not by a shared shell.
- **The core is the contract. The shells are the products.**

If a shell ever needs the core to do something differently for performance, the answer is a trait or
a feature flag in the core — **not a fork of it.**

### What this costs us, stated plainly

Two shells means the compositor is implemented twice — once in MSL, once in WGSL/HLSL. That is
**genuinely duplicated work and a genuine drift risk**, and it's the price of making the Mac build
as good as it can be for the market it's aimed at.

**Mitigation:** the compositor is *generated*, not hand-written. §3.5.3 already specialises a
pipeline per blend-mode stack via the IR — so the IR emits MSL for the Mac shell and WGSL for the
Windows one **from the same compositor IR in the shared core.** The blend-mode semantics, layer
folding and specialisation logic live in Rust once; only the backend emitter differs. That turns
"write the compositor twice" into "write one more emitter", which is a far smaller and far more
testable job.

*This is the strongest argument for keeping the IR in the core rather than hand-writing shaders —
and it only became apparent once Windows was on the table.*

### Sequencing
Windows is **later**; Mac V1 is unaffected in scope. What changes *now* is only the discipline above
— platform-free core, capabilities behind traits, IR emits shaders rather than hand-writing them.
Retrofitting those after a Swift/Metal V1 would be close to a rewrite, which is exactly the cost
this section exists to avoid. **Nothing here slows V1 down; it just stops a door being welded shut.**

---

## 1. Evidence already gathered (2026-10-12, from the installed binaries)

Not assumptions — read directly off `/Applications/Resolume Arena` on this machine.

> ## ⚠️ 1.0 Corrections accepted from `V2-codex.md` (2026-10-12)
>
> Codex reviewed this proposal and found real errors. Recorded here rather than quietly patched,
> because several affect how much weight the rest of this document deserves.
>
> | # | Correction | Where |
> |---|---|---|
> | 1 | **H2's zero-copy path does not exist.** `MTLBuffer.makeTexture` doesn't accept block-compressed formats; UMA doesn't remove texture-layout restrictions. **I asserted an API capability that isn't there.** | §2 H2 — rewritten |
> | 2 | **Linked libraries ≠ active render path.** `otool` showing OpenGL *and* Vulkan does not prove both are used per-draw, nor that they're sequential translation layers. MoltenVK also caches translated shaders, so translation isn't necessarily a per-frame cost. **H1 needs a trace before any cause is attributed.** | §1, §2 H1 |
> | 3 | **My MB/s figures are decompressed block throughput, not disk reads.** Snappy compresses, so on-disk rates are *lower* — and looping clips may be served from the OS file cache entirely. The storage-bound claim is a hypothesis, not arithmetic. | §1.5, §2.5 |
> | 4 | **"128GB of unified memory" was an unfounded assumption.** The dev box has 36GB; the target has 32GB. Cache sizing must come off real numbers. | §2.5 |
> | 5 | **"N resolves" conflates attachment stores with MSAA resolves,** and multiple draws can share one attachment without storing between them. Sloppy framing that overstated H3. | §2 H3 |
> | 6 | **A near-static video is not an unchanged source** — it still advances timestamps and decodes frames. H4's "free" case applies to still images and paused clips, not low-motion video. | §2 H4 |
> | 7 | **A single 2D texture array is wrong for heterogeneous sources** (mixed sizes, formats, video planes). Use an argument buffer of individual texture references. | §3.5.3 |
> | 8 | **MTLIO completes out of order and Apple doesn't document a guaranteed hardware decompressor** for this workload. H5 was stated more confidently than the docs support. | §2.5 H5 |
>
> **Where I'd push back:** Codex's remedy for nearly everything is "measure first, don't pick the
> elaborate implementation." Methodologically correct, but applied uniformly it's a research
> programme rather than a plan, and this project's risk is stalling before it ships. The resolution
> is its own §7 — a smaller first release — not deferring every design decision to a benchmark.
>
> **And one place the critique doesn't land:** §3.5.3's blend-mode argument is about *capability*,
> not performance. Mask and difference must read the accumulated destination, and Metal's
> fixed-function blending cannot express them. Codex's suggested baseline — "ordinary ordered layer
> draws in one pass" — cannot produce those blend modes at all without destination access. So
> register folding (or tile shading) isn't the elaborate option here; it's the only option that
> meets the requirement. That one stands.

**Arena renders through two translation layers on macOS.**
`otool -L Arena.app/Contents/MacOS/Arena` links **both** `/System/.../OpenGL.framework` (deprecated,
emulated on Apple Silicon) **and** `@executable_path/../../../libvulkan.1.dylib` (MoltenVK →
Vulkan-on-Metal). Neither is native Metal. Every draw crosses an API translation shim, and MoltenVK
performs SPIR-V→MSL shader translation plus its own command-buffer bookkeeping.

**DXV is BC/S3TC blocks + snappy, and the symbol is right there.**
```
__ZN...dxv412Decompressor15decompressFrameEPhPKhmm
  → DXV4::Decompressor::decompressFrame(unsigned char*, unsigned char const*, size_t, size_t)
```
Also present: `DXV3Compressor`, `DXV3Decompressor`, `DXV4Compressor`, `DXV4Decompressor`, `DXV_TC`,
`snappy`, `s3tc`, `bc1`–`bc6`, `astc`, `HAP`/`hap`. The shape is unambiguous: DXV stores GPU-ready
block-compressed texture data wrapped in a lossless entropy pass. **The GPU never decodes video —
it receives texture blocks.** That is the entire reason DXV is fast, and it's reproducible by us.

**Everything else goes through ffmpeg.**
Bundled `libavcodec.61.dylib` (61.19.101), `libavformat`, `libavfilter`, `libswscale`, plus
`VideoToolbox.framework` and `CoreVideo.framework`. So H.264/HEVC/ProRes take a genuinely different,
slower path than DXV — matching the "other types with slower frame rate" in the brief.

**Outputs:** `Syphon.framework`, `libndi.dylib` (NDI 5), `libArtnet.dylib`, `libLTC.dylib` (timecode).
**Wire** (their node-graph product) is `libwire.dylib` + `libwirenodes.dylib` — 150MB combined, and
the closest existing analogue to the TouchDesigner half of this brief.

> **Scope note on reverse engineering.** This is interoperability and performance research on
> software Aiden owns and has licensed: understanding a container/codec layout well enough to read
> DXV files, and measuring where frame time goes. No license circumvention, no redistribution of
> their code, no DXV *encoder* shipped without a cleanroom basis. HAP (Vidvox, open, BSD) is our
> primary codec; DXV support is read-only, for compatibility with existing Resolume content.

---

## 1.5 ⭐ The performance spec (set by Aiden, 2026-10-12)

**Target hardware: base M4, 32GB.** Not the M4 Max dev box. Per Apple: 10-core CPU
(**4 performance** + 6 efficiency), 10-core GPU, **120GB/s** memory bandwidth, 32GB max unified memory.

| Tier | Target | Layer-frames/sec | Frame budget | Stance |
|---|---|---|---|---|
| **A** | 4 layers DXV @ **120fps** | **480** | 8.33 ms | "easily" |
| **B** | 8 layers DXV @ **60fps** | **480** | 16.67 ms | target |
| **C** | 12 layers DXV @ **≥30fps** | 360 | 33.3 ms | floor — "fine to go to disk" |

**Tiers A and B are the same number: 480 layer-frames/second.** One bandwidth target, two shapes —
so the engine should be specified and benchmarked in layer-frames/sec, not fps. Tier C is *lower*
throughput than A/B, which makes it the graceful-degradation floor rather than the hard case.

### ⭐ Target resolution: 1080p (Aiden, 2026-10-12) — "the usual projection size"

**DXV3 and DXV4 at 1920×1080.** 4K is a later concern, not the spec. This materially de-risks the
project — see the verdict below.

#### …but the output canvas is arbitrary, and that's a different number (Aiden, 2026-10-12)

**"Users can set whatever projection mapping output they want."** So three resolutions are distinct
and must never be conflated in the code or the benchmark:

| | What it is | Typical | Scales what |
|---|---|---|---|
| **Source res** | the clip's own pixels | **1080p** — the spec above | disk, CPU decode, RAM cache |
| **Composition res** | the mix canvas layers composite into | user-set; often ≫1080p | **GPU fill + sampling** |
| **Output topology** | screens → slices → warped projector rects | arbitrary, multi-projector | the warp pass, scan-out |

A 4-projector-wide rig is a **7680 × 1080** canvas (8.3M px — more pixels than 4K); eight wide is
16.6M. **The 480 layer-frames/sec spec is about source throughput; GPU cost scales with the
composition canvas instead.** Both have to be in the benchmark matrix independently, or we'll report
a spec pass that falls over on a real multi-projector rig.

Recomputed for register folding (§3.5.3), 12 layers @ 60fps:

| Canvas | Pixels | Samples/sec | Verdict |
|---|---|---|---|
| 1920×1080 | 2.1M | 1.5 G | trivial |
| 3840×1080 (2 proj) | 4.1M | 3.0 G | fine |
| 7680×1080 (4 proj) | 8.3M | 6.0 G | fine |
| 15360×1080 (8 proj) | 16.6M | 12.0 G | **measure this one** |

> **⚠️ Design consequence — naive register folding wastes most of its work on a wide canvas.**
> It samples *every* layer at *every* pixel. But in projection mapping a 1080p clip typically covers
> only a slice of a wide canvas, so on a 4-projector rig roughly 75% of those samples are of a layer
> that isn't there.
>
> **Mitigation: bin layers by screen-space tile** (the same idea as Forward+ light culling) and
> select a pipeline variant per tile containing only the layers whose bounds intersect it. This folds
> naturally into the per-blend-stack specialisation already proposed in §3.5.3 — the stack signature
> just becomes per-tile rather than per-composition. **Cheap if designed in; awkward to retrofit.**

**Pipeline order:** layers → composition texture → **slices sample it through warp meshes** →
per-projector outputs. The composition is materialised once regardless, so arbitrary output topology
costs one extra pass total, not one per projector.

### What 480 layer-frames/sec actually costs

DXV3 opaque is BC1-class (0.5 B/px); DXV4 and alpha variants are BC3/BC7-class (1 B/px).

| Format | Per frame | Tier A/B (480 lf/s) | Tier C (360 lf/s) |
|---|---|---|---|
| 1080p BC1 | 1.04 MB | 498 MB/s | 373 MB/s |
| 1080p BC7 | 2.07 MB | **995 MB/s** | 747 MB/s |
| 4K BC1 | 4.15 MB | **1.99 GB/s** | 1.49 GB/s |
| 4K BC7 | 8.29 MB | **3.98 GB/s** | 2.99 GB/s |

### ⭐ Verdict at 1080p — the spec is comfortable, and the risky bet is no longer load-bearing

At the actual target resolution, **every tier clears every constraint with headroom:**

| Constraint | Tier A/B @ 1080p DXV4 (worst case) | Available | Headroom |
|---|---|---|---|
| **Disk read** | 995 MB/s | ~3 GB/s+ internal SSD | **3×** |
| **CPU snappy decode** | ~1 GB/s decompressed | ~1–2 GB/s **per core**, 4 P-cores | **under one core** |
| **GPU sampling** (12 layers, register fold) | ~1.5 Gsample/s | tens of Gsample/s | **>10×** |
| **Memory bandwidth** | ~2.5 GB/s | 120 GB/s | **~2% used** |
| **RAM cache** @ 20GB usable | ~9,600 frames ≈ 20s per layer across 8 @ 60fps | 32GB total | workable |

Disk-bound doesn't begin until **~24 layers at 1080p60** — double the Tier C ceiling.

> ### 🔻 This demotes H5 (MTLIO) off the critical path
>
> At 4K, CPU snappy needed 2–4 of this machine's 4 performance cores, and MTLIO hardware
> decompression was the only escape — a load-bearing bet on an API designed for asset streaming, not
> frame-locked playback. **At 1080p the same work costs under one core.** The cliff isn't there.
>
> **So V1 ships the straightforward, well-understood path: CPU snappy decode on a worker pool.**
> MTLIO becomes a *headroom* play — the thing that unlocks 4K and higher layer counts later — and
> gets prototyped on its own merits instead of the spec depending on it. §6 Q10 drops from
> "attack hardest" to "evaluate when 4K matters".
>
> **This is the single biggest de-risking in the plan.** The most technically uncertain component is
> now optional.

### Verdict against each constraint at 4K (retained for later — not the V1 spec)

**GPU — massively over-provisioned. Not the constraint.** Compositing 8 × 4K layers and writing one
4K RGBA8 output ≈ 75 MB of traffic per frame; at 60fps that's ~4.5 GB/s, plus ~4 GB/s of texture
upload. **Under 10 GB/s of the 120 GB/s available — roughly 8%.** The ALU work (a handful of taps and
a blend per pixel) is trivial. *The GPU is not what makes this hard, and a plan that optimises the
compositor first is optimising the wrong thing.*

**Storage — the wall, but only at 4K.** 1080p at any tier is ≤1 GB/s: trivial. 4K BC1 at 2 GB/s is
comfortable. **4K BC7 at 4 GB/s is at or past the internal SSD of a base M4** (256GB configs are
notably slower than 512GB+ ones). So Tier A/B at 4K-with-alpha is gated by hardware we don't control
— mitigation is the RAM cache below, not cleverness in the engine.

**CPU — ⚠️ this is the real binding constraint, and it's why H5 matters.** Snappy decompression runs
~1–2 GB/s per core. Tier A/B at 4K BC7 needs ~4 GB/s of decompressed output, i.e. **2–4 saturated
performance cores out of the 4 this machine has** — while also running the UI, the DAG, the control
server and the OS. That's not a budget, that's a cliff.

> **Therefore: `MTLIO` hardware decompression (H5) is not an optimisation for this spec — it is the
> enabling technology.** It moves decompression off the CPU entirely into the storage→GPU path. On a
> 4-performance-core machine there is no other way to hit Tier A/B at 4K. Everything else in this
> proposal is negotiable; this is the load-bearing bet, and §6 Q10 is the question that decides
> whether the spec is reachable at all.

**RAM — 32GB is tight, and it dictates the cache *policy*.** At 4K BC7 (8.29 MB/frame), ~20GB of
usable cache holds ~2,400 frames — **20 seconds at 120fps, or 2–5 seconds per layer across 8 layers.**
That cannot preload a show. At 1080p BC7 it's ~80 seconds, which can. So the ring cache must be
**cue-aware**: preload what's armed in the next column, evict what isn't. That's a V1 architectural
requirement, not a later optimisation.

### What this spec changes about the plan

1. **Drop H6 (indirect command buffers) from V1.** At 4–12 layers the CPU is encoding ~12 draw calls.
   ICB solves a problem this spec does not have. Revisit only if a 32-layer goal returns.
2. ~~**Demote H3 (tile shading).**~~ **Superseded — see §3.5.3.** As a *performance* play H3 is worth
   only ~3% of budget at 8 layers. But blend modes like **mask and difference must read the
   accumulated result underneath**, and Metal's fixed-function blending can't express them — so
   destination access is a **capability** requirement, not an optimisation. The chosen mechanism is
   **register folding** (one shader samples all N layers and folds the stack in registers),
   specialised per blend-mode stack. §3.5.3 has the full reasoning.
3. **Promote H5 to the critical path.** See above.
4. **Keep H4 (dirty-cook).** Static layers costing zero still directly buys headroom.
5. **H7 (kernel fusion) is a P4 concern**, not V1.
6. **V1 is therefore much smaller than V1-as-proposed:** a straightforward 4–12 layer compositor
   wrapped around a world-class I/O path. That ships considerably sooner.

### ⚠️ Benchmarking on the M4 Max dev box is invalid for this spec

The dev machine has **~3.4–4.5× the memory bandwidth and ~4× the performance cores** of the target.
Any number measured on it will flatter us enormously and tell us nothing about whether the spec is met.

✅ **Resolved 2026-10-12 — Aiden has a base M4 / 32GB target machine available to test on.** Tier A/B/C
verification happens there. Dev-box runs are still permitted for iteration speed but **must be tagged
`DEV-BOX-INVALID` in the CSV** so they can never be mistaken for a spec result. No number quoted
against Tier A, B or C may come from the M4 Max.

### Honest note on 120fps
Tier A needs a 120Hz output chain. Most projectors are 60Hz; 120Hz is found on some laser DLP units
and on LED processors. So Tier A is largely a **headroom** target — an engine that can do 480 lf/s
never drops a frame at 60 — which is a legitimate goal, but worth naming so nobody expects a 120Hz
projector to appear.

---

## 2. Why we can plausibly win — four hypotheses, each with a kill test

A performance claim with no test attached is marketing. Each of these gets measured in P0 and is
allowed to be **wrong**.

**H1 — API translation tax.** Arena pays MoltenVK (SPIR-V→MSL, Vulkan→Metal) + legacy OpenGL.
Native Metal removes both.
*Test:* Metal System Trace in Instruments on Arena vs. a 1-layer Photon prototype, identical clip.
Compare CPU frame time and encoder submission count. *Kill:* if the delta is <10%, H1 is noise and
the win has to come from H2–H4.

**H2 — Unified memory.** ❌ **CORRECTED — the original form of this hypothesis was wrong.**

~~On UMA, snappy can decompress directly into an `MTLBuffer` the GPU already sees — zero copy.~~
**This does not work for BC/compressed formats.** `MTLBuffer.makeTexture(descriptor:offset:bytesPerRow:)`
accepts ordinary and packed colour formats, **not block-compressed ones**. Shared physical memory
does not remove texture *layout* and API restrictions — a BC texture still has to be in a
GPU-tiled layout the buffer-backed path won't produce. Credit to V2-codex §3 H2 for catching this;
I asserted a zero-copy path that the API does not offer.

**Revised H2:** start from a known-correct pooled path — decompress to staging storage, then upload
into a compressed texture — and *measure* `replaceRegion` on a shared texture against a
buffer→private-texture blit. UMA still plausibly helps (no PCIe hop, cheaper staging), just not via
aliasing. A private texture plus one efficient blit may beat a superficially more direct route.
*Test:* bytes/frame and upload time per layer, both paths, on target hardware.
*Kill:* if upload cost is already negligible at 1080p — which §1.5 suggests it may well be — H2
stops mattering for the V1 spec entirely.

**H3 — Pass fusion (the big one).** The classic VJ compositor does one render pass per layer: N
layers → N render targets → **N resolves**. On a TBDR GPU like Apple's, tile resolves are the
dominant cost. Fusing the whole layer stack into a *single* pass — texture array + per-layer
argument buffer + a generated blend switch, with intermediates living in tile memory and never
touching VRAM — collapses N resolves to 1. **Going native-Metal-only is what makes this reachable;**
it is not expressible in a portable API.
*Test:* synthetic 1/4/8/16/32-layer stack, Photon fused vs. Photon unfused vs. Arena. Expect the
curves to diverge hard past ~8 layers.
*Kill:* if Arena already fuses, we match rather than beat, and the win narrows to H1+H2.

**H4 — Compiled DAG with dirty-cook (the TouchDesigner lesson).** TD's frame rate comes from a
cached operator graph where only *dirty* nodes re-cook, textures stay resident on the GPU across
frames, and there is no CPU round-trip. A static clip on a static layer should cost **zero** GPU
work after its first frame — just a reference to a live texture. A fixed pipeline re-renders
everything every frame regardless.
*Test:* 16-layer composition with 2 layers animating. Measure GPU time vs. the all-16-animating case.
Photon should scale with *change*, Arena with *count*.

---

## 2.5 The optimisation pass — three more mechanisms, and one that breaks the premise

*Added 2026-10-12 after challenging the first draft. All Metal features below were verified present
in this machine's SDK (`MacOSX.sdk/System/Library/Frameworks/Metal.framework/Headers`), not recalled.*

**H5 — Direct-to-GPU streaming. This should be the headline, not H3.**
`MTLIOCommandQueue` / `MTLIOCommandBuffer.loadTexture:` loads **straight from an NVMe file into a GPU
texture, hardware-decompressed, with zero CPU involvement** (macOS 13+; `MTLIOCompressionMethod` =
Zlib / LZFSE / LZ4 / LZMA / LZBitmap).

DXV's entire advantage is "the CPU only does snappy, the GPU receives blocks". MTLIO's advantage is
that **the CPU does nothing at all.** So: a Photon-native clip format — BC7/ASTC blocks written into
an `MTLIO` pack file with LZBitmap — removes the last CPU hop in the playback path. Resolume cannot
follow us here: there is no MoltenVK path to it, and no Vulkan equivalent on macOS.
*Test:* 16 × 4K, Photon-native via MTLIO vs. Photon HAP via CPU snappy vs. Arena DXV. Measure CPU
time per frame and frames-dropped.
*Kill:* if MTLIO's queue depth or latency makes frame-accurate seeking unworkable — it's designed for
asset streaming, not frame-rate-locked playback, and that mismatch is the real risk.
*Consequence if it works:* HAP/DXV become **import formats**, and the native format is what ships.

**H6 — GPU-driven encoding.** `MTLIndirectCommandBuffer` lets the GPU build its own draw calls. With
argument buffers holding per-layer state, the CPU stops encoding per layer entirely — **CPU cost
becomes flat with respect to layer count.** Vulkan's device-generated commands are an extension with
poor-to-absent MoltenVK support, so this is structural, not incremental.
*Test:* CPU frame time across the 1→32 layer sweep. Expect flat for Photon, linear for Arena.

**H7 — Kernel fusion in the node graph (beats TouchDesigner, doesn't just match it).** TD executes
**one pass per TOP**. A chain of ten operators is ten render targets and ten resolves. If our IR
compiles a chain of operators into a *single fused kernel* — the way a shader compiler fuses ops —
then a 10-node chain costs one dispatch.
*Test:* 10-deep operator chain, Photon fused vs. Photon unfused vs. the TD equivalent.
*Kill:* fusion breaks at any node needing a full-image dependency (blur, feedback, reduction); the
compiler has to split there. Real question is how many chains in practice are fusible — if it's 20%,
this isn't worth the compiler.

**H3 is refined, not replaced.** "Pass fusion" was imprecise. The actual mechanism is **tile
shading**: `MTLTileRenderPipelineDescriptor` + `imageblock` + `dispatchThreadsPerTile` let the blend
read the current framebuffer value in-shader, so N layers composite **in tile memory with zero
intermediate textures and a single resolve**.

> **Re-read §1.5 before weighting these.** The performance spec (4–12 layers on a base M4) reorders
> them substantially: **H5 becomes critical-path, H6 drops out of V1, H3 is demoted to ~3% of the
> budget.** The analysis below was written for a 32-layer goal on an M4 Max; its arithmetic still
> holds and agrees with §1.5, but its *priorities* are superseded.

### ⚠️ The finding that changes the optimisation target: past ~12 layers we are storage-bound, not GPU-bound

Arithmetic, not vibes. 4K HapQ is BC3-class, ~1 byte/px → 3840 × 2160 ≈ **8.3 MB/frame**. At 60fps
that's **~500 MB/s per layer**:

| Layers @ 4K60 HapQ | Disk read required |
|---|---|
| 4 | ~2 GB/s |
| 8 | ~4 GB/s |
| 16 | **~8 GB/s — exceeds this machine's internal SSD** |
| 32 | ~16 GB/s — not achievable from disk by any means |

(BC1-class HAP is half that, so the wall sits around 24–32 layers instead of 12–16. Either way,
there is a wall, and it is not the GPU.)

**Implications, and they're significant:**
1. Beyond that point, optimising the compositor buys **nothing**. The entire contest moves to the
   I/O path — which is precisely where H5 (MTLIO) lives. These two findings reinforce each other.
2. A **RAM-resident ring cache** becomes core architecture, not an optimisation. 128GB of unified
   memory holds a lot of 4K BC frames; the right design preloads cued clips to RAM and streams only
   what won't fit.
3. **The benchmark must report the bottleneck, not just the FPS.** A run that's disk-bound tells you
   nothing about either compositor. `docs/bench-fairness.md` must require disk-throughput logging
   alongside frame time, or every high-layer-count number we publish is meaningless.
4. Arena hits this identical wall, so it remains winnable — but the *reason* we'd win changes from
   "better compositor" to "better I/O path", and the marketing has to follow the truth.

---

**The real claim, stated honestly:** we are unlikely to beat Arena by much on *one* 4K DXV layer —
that path is already near-optimal and bandwidth-bound. The win is in **layer count and
static-content scaling**, via a shorter I/O path (H5), flat CPU cost (H6) and tile-memory blending
(H3). That is the benchmark to publish, and the one to be honest about.

---

## 3. Architecture

### 3.0 The stack

> **Revised 2026-10-12 after an optimisation pass.** The first draft put too much in Rust and
> under-specified the GPU strategy. See §2.5 for the four mechanisms that changed this.

| Layer | Choice | Why |
|---|---|---|
| **Engine core** | **Rust — narrowed** | **Only the parts that touch no Apple framework:** container demux, codec block extraction, snappy/LZ4, the DAG + dirty propagation, IR→MSL codegen, the `.photon` document model, and the control server. Memory-safe parsing of untrusted media (an app that crashes on a malformed MOV mid-show is dead), no GC pauses, `cargo` for the compression crates. |
| **Everything touching a framework** | **Swift** | *Every* item in the I/O matrix (§3.3) is an Apple API — Syphon, DeckLink, ScreenCaptureKit, AVFoundation, VideoToolbox, CoreMediaIO, CoreVideo — and so is Metal. Rust buys nothing here and would cost hand-written bindings for all of it. **This was the first draft's main error.** |
| **Rust ↔ Swift** | **`swift-bridge`, crossed once per frame** | The boundary passes a **flat frame descriptor (plain-old-data: texture handles, per-layer params, cook order)** — never an object graph, never per-layer calls. If the boundary is ever crossed in a loop, the design is wrong. |
| **Graphics** | **Metal 3/4, hand-written MSL** | The only backend. The three mechanisms below are the whole reason for going single-API — none are expressible portably. |
| ↳ **Blending** | **Tile shading / imageblocks** | `MTLTileRenderPipelineDescriptor`, `imageblock`, `dispatchThreadsPerTile` — verified present in this machine's SDK. N layers blend **in tile memory, zero intermediate textures, one resolve.** |
| ↳ **Encoding** | **Indirect Command Buffers** | `MTLIndirectCommandBuffer` — the GPU builds its own draw calls. CPU encode cost ≈ 0 *regardless of layer count*. Vulkan's equivalent is an extension that MoltenVK barely supports. |
| ↳ **Streaming** | **`MTLIOCommandQueue` → `loadTexture:`** | **NVMe → GPU texture, hardware-decompressed, zero CPU.** See H5 — this is the headline mechanism. |
| ↳ **Memory** | `MTLHeap` aliasing, `MTLResidencySet`, sparse textures | Texture pool with no allocation churn; sparse for 8K+ media. |
| **App shell + UI** | **Swift + SwiftUI**, AppKit where SwiftUI is too slow | SwiftUI for panels and inspectors; the clip grid, output mapper and node editor render **in Metal**, not in views. |
| **Media decode** | **ffmpeg (`libavcodec`) + VideoToolbox** | Same path Resolume takes for H.264/HEVC/ProRes. No point being clever; VideoToolbox is hardware and gives us `CVPixelBuffer` → Metal with zero copy. |
| **Fast codecs** | **HAP / HapQ / HapAlpha (primary), DXV3/4 (read-only)** | Both are BC blocks + snappy. HAP is open (Vidvox, BSD) so we can encode it; DXV stays read-only for compatibility with existing Resolume content. |
| **Control server** | **Rust — `axum` + `tokio-tungstenite`**, OSC over UDP, mDNS via `mdns-sd` | Embedded in the engine. Serves the remote UI's static files too, so there's no deploy step and no version skew. |
| **Project format** | **`.photon` — JSON + CBOR fast-path**, schema generated from Rust types | One definition, in `core/doc/`. Human-diffable for git, binary for load speed. |
| **Remote UI (P6, later)** | **React + TypeScript strict + Tailwind + Zustand + Vite** | Aiden's default stack. Served by the engine. Renders zero frames. |
| **Remote UI (P7, later)** | **SwiftUI** | Same protocol, second shell. |
| **Bench harness (P0)** | **TypeScript + ffmpeg + Python for plots** | Codex's lane. No engine dependency. |

**Rejected, and why:** C++ (the obvious choice — Resolume and TD both use it — but we'd inherit the
memory-safety problem that makes media parsing dangerous, for a performance benefit that's ~zero
against Rust); wgpu (portable, but hides the exact Metal features H3 depends on); Electron/Tauri for
the engine UI (a frame-accurate instrument can't have a webview on the hot path); Unity/Unreal
(enormous, wrong abstraction, no DXV).

```
┌──────────────────────────────────────────────────────────────────┐
│  photon-core  (Rust)                                             │
│  ├─ container/   MOV/MP4 atom demux, AVI, MKV                    │
│  ├─ codec/       DXV3/4 (read), HAP/HapQ/HapAlpha (read+write),  │
│  │               snappy, LZ4, BC1-7 passthrough                  │
│  ├─ decode/      ffmpeg-sys + VideoToolbox bridge (H264/HEVC/PR) │
│  ├─ graph/       DAG, dirty propagation, topological cook order  │
│  ├─ ir/          compositor IR → MSL codegen + pipeline cache    │
│  ├─ clock/       transport, BPM, timecode (LTC/MTC), frame pacing│
│  ├─ net/         embedded control server (WS + OSC + mDNS)       │
│  └─ doc/         .photon document + schema (SOURCE OF TRUTH)     │
└──────────────────────────┬───────────────────────────────────────┘
                           │  Metal 3/4 — the only backend
              ┌────────────▼─────────────┐
              │  Photon (macOS)          │
              │  Swift + SwiftUI + Metal │
              │  THE ENGINE. V1.         │
              │  embeds control server   │
              └────────────┬─────────────┘
                           │  LAN: WebSocket + OSC + mDNS discovery
                           │  preview: hardware-encoded H.265 / NDI
         ┌─────────────────┴──────────────────┐
         │                                    │
┌────────▼─────────┐                ┌─────────▼─────────┐
│ Photon Remote    │                │ Photon Remote     │
│ web — React/TS   │                │ iOS — SwiftUI     │
│ runs on operator │                │ same protocol     │
│ machine. LATER.  │                │ LATER.            │
└──────────────────┘                └───────────────────┘
```

### 3.1 The remote topology
Engine machine at the projectors, operator machine at FOH, connected by venue LAN. Design rules
this forces:

- **Discovery:** engine advertises over mDNS/Bonjour (`_photon._tcp`). Remote finds it, no IP typing.
- **The engine is authoritative.** Remote holds optimistic local state and reconciles. A dropped
  connection must never desync a live show or black an output.
- **Reconnect is the normal case, not the error case.** Venue wifi drops. Session resumes silently.
- **Auth on an untrusted network.** Pairing code + token. An open WebSocket that can black a client's
  show is not acceptable, even on a "private" LAN.
- **The engine serves the web app itself** from its embedded server. No internet, no Netlify, no
  deploy step, no version skew between engine and UI. Open `http://photon.local:7777`.

### 3.1b ⭐ Control transports (Aiden, 2026-10-12)

**"Mac engine and Windows engine will only need control from a web / phone remote over bluetooth or
internet, eventually MIDI and others."**

Both engines expose the **same control protocol**; only the *transport* differs. So: **one message
set defined once in `photon-core`, many transport adapters.** Critically, transports differ enormously
in bandwidth and latency, and the protocol must model that explicitly rather than pretend they're
interchangeable.

| Transport | Latency | Preview video? | Use case | Phase |
|---|---|---|---|---|
| **WebSocket / LAN** (mDNS) | 1–5 ms | ✅ full | FOH laptop or tablet at the venue | P5 |
| **Bluetooth LE** | 20–100 ms | ❌ **no — control only** | **Venue with no usable wifi.** Very common. | P6 |
| **Internet / relay** | 50–300 ms | 🟠 low-rate only | Remote cueing, off-site operation, support | P7 |
| **MIDI** (USB + BLE-MIDI) | <5 ms | ❌ n/a | APC40 / Launchpad / fader controllers | P6 |
| **OSC** (UDP) | 1–5 ms | ❌ n/a | The AV industry's lingua franca; TouchOSC, Lemur, lighting desks | P5 |
| **Art-Net / sACN in** | — | ❌ n/a | Lighting desk drives Photon as a fixture | P3c |

**Design consequences, each of which is cheap now and expensive later:**

1. **Transport capability negotiation is part of the protocol.** A client announces what it supports;
   the engine adapts. A BLE remote must degrade to *no preview* gracefully, not fail — BLE GATT gives
   single-digit KB/s in practice, which is fine for control messages and useless for video.
2. **Messages must be small and idempotent.** Design the wire format for the BLE budget, not the LAN
   one. If it fits BLE it fits everything; the reverse isn't true.
3. **🔴 State push, not just command pull — this is what MIDI forces.** On an APC40 or Launchpad the
   pads *light up* to show clip state. That's bidirectional: the engine pushes state to the surface
   continuously. Designing a request/response protocol and retrofitting push is painful, so the
   protocol is **state-sync-first** from the start.
4. **Latency honesty per transport.** Clip launch over BLE at 50ms is fine. A *fader* over an internet
   relay at 200ms is unusable and shouldn't be offered — the UI should disable or warn on controls
   whose transport can't carry them. Better to refuse than to feel broken.
5. **MIDI mapping is a first-class feature, not a transport detail.** Learn-mode, per-parameter
   binding by path (`layer.3.opacity`), saved with the project. The §3.5.1 parameter system already
   addresses every parameter by path, which is exactly what this needs.

> ### 🔴 Internet control is a security problem, not a networking one
>
> An internet-reachable endpoint that can black out a live show is a materially different risk from
> a LAN one, and it's the kind of thing that gets discovered the hard way.
>
> - **The engine makes an *outbound* connection to a relay.** Never accept inbound connections at a
>   venue — no port forwarding, no open ports on untrusted networks, works behind any NAT.
> - **Pairing code + per-device revocable token.** TLS throughout. A lost phone must not be a
>   permanent backdoor.
> - **Authorisation tiers:** a remote may be limited to cueing without being able to blackout, kill
>   outputs, or alter mapping.
> - **The engine stays authoritative and fail-safe:** a lost or hostile connection must never change
>   what's on screen. §3.1's "a dropped connection must never black a live output" applies doubly here.
>
> Internet control should ship **after** LAN and BLE, precisely because it carries this weight.

### 3.2 Preview
Hardware-encoded H.265 via VideoToolbox (or NDI, which we already need for output) streamed to the
remote. **The remote never decodes a project file or renders a composition.** Thumbnails for the clip
grid are generated engine-side and cached.

### 3.2b ⭐ Advanced Output — parity with Resolume is a V1 requirement (Aiden, 2026-10-12)

**"Keystoning / advanced output just as good as Resolume."** This is the feature that decides whether
Photon is usable at a real gig, so it's specified as a checklist rather than an aspiration. It is the
content of the **Map** persona (§3.5.0).

#### The model
`Composition → Screens → Slices → warped output`. A **Screen** is an output target (physical display,
Syphon/Spout, NDI, virtual). A **Slice** takes an input rectangle from the composition and maps it to
a warped output shape on a screen. This is Resolume's model and it's the right one — it's also what
§1.5's "a projector is a rectangle inside an output canvas" abstraction requires.

#### Parity checklist

| | Feature | Notes |
|---|---|---|
| ☐ | **Quad warp / keystone** | 4-corner perspective. The baseline. |
| ☐ | **Bezier warp** | Control-point patch with adjustable subdivision — curved and cylindrical surfaces. |
| ☐ | **Grid warp** | Arbitrary N×M control points for irregular geometry. |
| ☐ | **Polygon slices + masks** | Non-rectangular output shapes, feathered edges. |
| ☐ | **Soft-edge blending** | Overlap regions between projectors, with adjustable curve, gamma and luminance. |
| ☐ | **Per-slice colour correction** | Brightness, contrast, gamma, RGB balance — projectors never match out of the box. |
| ☐ | **Per-slice input rect** | Which part of the composition feeds this slice. |
| ☐ | **Slice transform** | Position, scale, rotate, flip. |
| ☐ | **Test patterns** | Grids, crosshairs, colour bars, per-slice identification. Essential for rigging. |
| ☐ | **Multi-screen / multi-output** | Including Datapath FX4 / MST-style one-canvas-many-projectors (§1.5). |
| ☐ | **Output presets** | Save/load a venue's mapping independently of the composition. |
| ☐ | **Live preview with slice overlays** | See the composition with slice boundaries while editing. |

Mapping is stored **separately from the composition** — the same show travels to a different venue
with a different mapping. Resolume gets this right and it matters operationally.

> #### 🔴 Two traps that make hobby projection mappers look obviously broken
>
> **1. Affine UV interpolation on a 4-corner quad warp.** The classic failure. Draw a keystoned quad
> as two triangles with ordinary 2-component UVs and the texture *bends along the diagonal* — a
> visible crease straight through the image that no amount of tweaking fixes. The cause is that
> affine interpolation across each triangle is wrong under perspective.
>
> **The fix: compute the homography and interpolate projectively** — pass 3-component UVs (`uvq`) and
> divide by `q` in the fragment shader, or tessellate heavily enough to hide it (worse, and it never
> fully goes away). **Get this right on day one**; it's a small amount of maths and it's the
> difference between "looks professional" and "looks like a student project".
>
> **2. Soft-edge blending computed in sRGB instead of linear light.** Two projectors overlapping each
> at 50% should sum to 100% *of light*, but sRGB values aren't proportional to light. Blend in gamma
> space and the overlap band reads as a visible bright or dark stripe — exactly the artifact soft edge
> exists to remove.
>
> **The fix: the whole compositor works in linear light**, with encoding only at final output. This
> is a pipeline-wide decision, not a slice-level one — which is why it belongs here, before any of it
> is written. It also improves every blend mode in §3.5.3 for free.

#### Quality factors that separate "works" from "as good as Resolume"
- **Sampling quality.** Bilinear is not enough where a slice compresses the image; it aliases and
  shimmers on motion. Use mipmaps with correct derivatives, and bicubic where it's affordable.
- **Adaptive tessellation** on bezier/grid warps — dense enough for the curvature, not uniformly dense.
- **Edit-time precision**: numeric entry for every control point, nudge by arrow key, snapping,
  undo/redo. Riggers work in the dark, at height, against the clock.
- **Mapping must stay live while editing.** Dragging a corner updates the projector in real time —
  no apply button, no re-render pause.

#### MIDI mapping — also a V1 requirement
Confirmed by Aiden in the same breath, so it's not deferred to P6: **learn-mode MIDI binding on any
parameter**, addressed by path (`layer.3.opacity`, `slice.2.corner.0.x`), saved with the project, with
**bidirectional state push** so clip state lights up the pads on an APC40 or Launchpad (§3.1b). The
parameter-by-path system in §3.5.1 is the mechanism; MIDI is its first consumer.

### 3.3 I/O — sources in, outputs out

A media server is defined by its I/O surface as much as its compositor. **Every source below becomes
an `MTLTexture` on the GPU and joins the same layer stack as a clip — there is no separate "live
input" path.** Same for outputs: every sink reads from the same tile-resident result.

**Sources in**

| Source | API | Notes |
|---|---|---|
| **Syphon in** | `Syphon.framework` (`SyphonMetalClient`) | Zero-copy `IOSurface` from another app on the same Mac — TouchDesigner, Unity, MadMapper, a game. **Costs nothing**: it's already a GPU texture, we just bind it. Highest-value input per unit of work. |
| NDI in | `libndi` | Video over ethernet from anywhere on the LAN. Decode cost is real (NDI HX is H.264/5; full NDI is SpeedHQ) — budget for it. |
| Capture cards | Blackmagic `DeckLinkAPI` | SDI/HDMI in. The pro path. `DeckLink` delivers to a GPU-visible buffer. |
| UVC / webcam / HDMI-USB | `AVFoundation` + `CoreVideo` | Cheap capture, Elgato-class. Arrives as `CVPixelBuffer` → `CVMetalTextureCache`, zero-copy. |
| Screen / window capture | `ScreenCaptureKit` | Capture a window or display. Modern, GPU-side, low overhead. |
| Camera | `AVFoundation` | Same path as UVC. |
| Generators | internal | Solids, gradients, noise, shader nodes (P4). |

**Outputs out**

| Output | API | Notes |
|---|---|---|
| **Physical displays** | Metal + `CGDirectDisplay` | The projector path. Fullscreen, display-mode locked, vsync owned. See the hard limit below. |
| **Syphon out** | `SyphonMetalServer` | One server per slice/screen if wanted. Zero-copy out to other apps. Trivial to add, very high value. |
| **NDI out** | `libndi` | **This is "video over ethernet".** Multiple independent streams, one per screen or slice. Encode cost is per-stream and real — it is the thing that will eat frame time if we're careless, so it runs on its own queue off the render thread. |
| **Art-Net / sACN (E1.31)** | `libArtnet` / own sACN | Pixel-mapping: sample the composition at LED fixture positions and emit DMX universes. This is how LED tape/panels get driven over ethernet. Thousands of universes = a real throughput problem; sample on GPU, pack on CPU. |
| Virtual camera | CoreMediaIO Camera Extension | Photon as a webcam source for Zoom/OBS/Teams. |
| Record to disk | VideoToolbox + HAP encode | Capture the program output. |

**The hard constraint, stated up front:** an **M4 Max drives 4 external displays, maximum** (5 total
including the built-in). "Lots of video outs" past that needs one of:
- **DisplayPort MST / Datapath FX4 or Matrox TripleHead** — one physical out, split into 4 projectors
  by hardware. The engine sees one wide canvas and slices it. **This is the standard rig and should
  be the default assumption in the slice/screen model.**
- **NDI to additional machines** running a lightweight Photon output node — scales horizontally,
  costs latency and encode.
- **Art-Net/sACN** for LED, which isn't display-limited at all.

So the screen/slice model must treat "a projector" as *a rectangle inside an output canvas*, never as
"a display". Getting that abstraction right in P3 is what makes 16-projector rigs possible on one Mac.

### 3.4 Non-negotiable invariants
1. **Pixels never touch the CPU after decode.** Any CPU readback of a frame is a bug, not a tradeoff.
2. **One render pass for the layer stack.** Added passes need a measured justification in the PR.
3. **The `.photon` document schema has exactly one definition**, in `core/doc/`. Every consumer
   derives its types from it. No hand-written parallel TS or Swift model. (House rule: never fork a
   source of truth.)
4. **Every perf claim ships with the bench run that proves it.** No "should be faster".

---

## 3.5 UI (set by Aiden, 2026-10-12)

**Panels are Resolume Arena. The shell around them is Affinity Designer.** The *content* of the
performance surface should be familiar enough that a VJ drives it without reading anything; the
*chrome* should be minimal, modal, and get out of the way.

### 3.5.0 ⭐ Shell — Affinity-style personas (Aiden, 2026-10-12)

Affinity's **Personas** — the small icon cluster in the corner that swaps the entire toolset while
the document canvas stays put. Photon does the same, with **very thin chrome around the outside** so
the maximum area goes to output preview, mapping and the grid.

| Persona | Purpose | Pipeline position | Replaces |
|---|---|---|---|
| **Perform** | Clip grid, decks, layer strip, transport, previews. The live instrument. | the grid | Arena's main window |
| **Map** | Output canvas, screens, slices, warp meshes, soft-edge, test patterns. | post-output | Arena's Advanced Output |
| **Sources** *(later)* | Shader authoring (GLSL/ISF), generators, media prep + batch transcode. | **PRE** | Resolume Alley |
| **Effects** *(later)* | Node graph canvas, operator library, parameter inspector. | **POST** | TouchDesigner |

**Sources and Effects are lazy-loaded and unloaded when closed** (§3.5.4d) — but only their *editors*
unload; anything they created keeps running in the engine.

**Why this is the right call here, not just a style borrow:** those three activities have almost no
tool overlap, happen at different times (map during setup, perform during the show, patch while
designing), and Arena already concedes the point by putting Advanced Output in a *separate window*.
Personas make that separation first-class instead of an afterthought.

**Shell rules**
- **Icon cluster in the corner** switches personas. Thin top bar, thin left tool column, collapsible
  right panels — Affinity's proportions.
- **Each persona owns its own saved layout.** Panels still move, dock, float and persist, but within
  a persona. 🔻 **This materially shrinks the docking workstream flagged below**: we ship three
  well-designed layouts rather than expecting users to build one mega-layout that serves all modes.
- **Canvas-first.** Panels overlay or dock to thin edges; nothing permanently eats the middle.
- **`⌘K` command palette** for grid search, clip search, effect search, and jumping to a
  slice/screen/layer. This is the answer to "grid searching" — a palette scales to a 2,000-clip
  library in a way a visual grid never does.

> ### ⚠️ The one real risk in this model: persona switching during a live show
>
> Affinity is a design tool — mode switching is free because nothing is on air. **Photon is a live
> instrument.** A mis-tapped icon mid-set that replaces the clip grid with a warp editor is a
> show-stopping UX failure, and it's exactly the failure mode Arena's everything-visible-at-once
> layout avoids by design.
>
> Mitigations, all of which should be in V1:
> 1. **Rendering is fully decoupled from the UI persona.** Output never changes because a panel did.
>    (True regardless, but it must be stated and tested.)
> 2. **A persistent slim performance bar** that survives every persona switch: master output
>    thumbnail, master opacity, and blackout/panic. The things you cannot afford to lose.
> 3. **Performance Lock** — a toggle that freezes the persona and disarms destructive edits while a
>    show is live. The stage equivalent of a seatbelt.
>
> Without these, personas are strictly worse than Arena's layout for the actual job. With them,
> they're better.

### 3.5.1 The Perform persona — Arena-shaped layout

| Panel | Contents | Renders in |
|---|---|---|
| **Clip grid** (centre) | Columns × layers of clips. Click-to-trigger, column triggers along the top, deck tabs. **Live animating thumbnails** for playing clips. | **Metal** |
| **Layer strip** (left of grid) | Per layer: name, opacity, blend mode, solo / bypass, transition, FX indicator. | SwiftUI |
| **Browser** (left) | Tabs: Files · Effects · Sources · Compositions. Drag onto grid or layer. | SwiftUI |
| **Preview monitors** (right) | Two: **Clip preview** (pre-fade / selected) and **Master output**. | **Metal** |
| **Effects / Inspector** (right or bottom) | FX chain for the current selection with parameters; reorder, bypass, drag to reorder. | SwiftUI |
| **Transport** (bottom) | BPM, tap tempo, play/pause, position, beat-sync launch quantise. | SwiftUI |
| **Performance bar** (persistent) | Master output thumbnail, master opacity, blackout/panic. **Survives persona switches** (§3.5.0). | **Metal** + SwiftUI |

*Screens, slices and warping live in the **Map** persona (§3.5.0), not a separate window.*

### 3.5.1b ⭐ UI templates instead of moveable UI (Aiden, 2026-10-12)

**Decided: no docking. Ship a few fixed UI templates and let users pick one.** A real docking system
is a substantial build — SwiftUI has no native equivalent and every app in this category (Resolume,
TouchDesigner, Ableton, Blender) ships a custom one. It's a classic way for a project like this to
stall at 80%. Templates deliver most of the value for a small fraction of the cost.

**And it makes the layout work pay off immediately.** The declarative layout description was
previously scaffolding for a feature that might never arrive; now it *is* the feature. Templates are
just different instances of the same description — so this costs essentially nothing beyond what was
already planned, and ships something users can see.

**Proposed templates** (name them for the job, not the layout):

| Persona | Template | Optimised for |
|---|---|---|
| **Perform** | **Perform** *(default)* | Grid dominant, compact previews, layer strip. Driving a show. |
| | **Preview** | Large master + clip preview, compact grid. Checking output, lining up a mapping. |
| | **Build** | FX inspector and parameters dominant, grid compact, browser open. Prepping a set. |
| **Map** | **Map** *(default)* | Output canvas dominant, slice list, warp tools. |
| | **Overview** | All outputs tiled at once. Multi-projector rigs. |
| **Effects** *(later)* | **Patch** | Node canvas dominant, operator library, inspector. |

Six total, three in V1. A `⌘1…⌘3`-style switch within a persona; selection persists per persona.

**What this needs (all already planned):**
- Panels are self-contained, position-agnostic views — data from the store, size from the container.
- Layouts are a **declarative struct tree**, not hard-coded nested SwiftUI. Templates = different trees.
- Stable serialisable `PanelID`s, so selection persists and layouts can migrate across versions.
- No panel owns a window; render targets are requested from the engine by ID.

**Explicitly not building:** drag-to-dock, float/undock, resize-and-save, a layout editor.

**If moveable UI is ever genuinely wanted,** it becomes "let users edit a template and save it as a
new one" — an editor over a data structure that already exists and already persists, rather than a
new subsystem. That's the cheapest possible version of that future, and it's free to preserve.

**The grid renders in Metal, not in views.** A 16 × 8 grid of live animating thumbnails is 128
simultaneous video surfaces; as SwiftUI views that will not hold 60fps while the engine is also
running a show. Thumbnails come from the same texture pool as playback, downsampled once.

### 3.5.2 Later — the node editor

TouchDesigner-style graph for post effects, as a **separate surface** (own tab/window), not bolted
into the grid view. Metal-rendered canvas: pan/zoom, live preview thumbnails on nodes, thousands of
nodes without dropping frames.

**Insertion points — this is the part with teeth.** The graph can be applied at:
1. **Master** — post effects on the composited grid output. (The default case Aiden described.)
2. **Selected layers only** — a graph attached to one or more individual layers, pre-composite.
3. *(implied)* **Groups**, if we add layer groups later.

> ### ⚠️ This forces a compositor decision — and blend modes force the same one
>
> A layer with its own FX graph **must be materialised to a real texture** before that graph can run.
> That's exactly the intermediate a fused single pass exists to avoid.
>
> **Resolution: a hybrid compositor.** Partition layers at cook time — layers with no attached graph
> stay in the fused path; layers with a graph break out, render to their own target, run their graph,
> and **rejoin the stack as an ordinary source texture**. The IR must do this partition automatically;
> it cannot be bolted on later. Cheap at runtime, expensive to retrofit — so design for it from day
> one even though the node editor ships much later.

### 3.5.4 ⭐ Effects library, and the Sources pane (Aiden, 2026-10-12)

Two separate asks, and they sit on **opposite sides of the grid**:

```
   SOURCES  ──►  GRID (clips → layers → composite)  ──►  EFFECTS  ──►  OUTPUT
   "PRE"          the performance surface              "POST"       Map persona
   shaders,       built-in FX apply per clip/layer     node graph
   generators,                                         (§3.5.2)
   media prep
```

#### (a) Built-in effects library — "a fairly decent selection like Resolume's"
Parameterised effects applied per **clip / layer / group / composition**, from the FX inspector —
*not* the node editor. Resolume ships ~100; a credible V1 is ~30 covering the categories that
actually get used: blur/glow, displace/distort, kaleidoscope/mirror, RGB shift/chromatic, feedback
and trails, colour (HSV, levels, curves, LUT), keying (luma/chroma), edge/sharpen, pixelate/posterise,
transforms, and strobe/flash.

Every effect is **a shader plus a parameter manifest** — same mechanism as a user-authored one. No
privileged built-ins; the library is just shaders we ship. That keeps one code path and means
anything we can build, a user can.

#### (b) 🔴 Support ISF, and the effect library mostly solves itself
**ISF (Interactive Shader Format, Vidvox)** is the VJ world's de facto shader standard — GLSL plus a
JSON parameter manifest. VDMX, Resolume and others support it, and **hundreds of ISF effects and
generators already exist for free.** Supporting ISF as a first-class format means we ship a large,
battle-tested library on day one instead of hand-writing 30 effects, and users can bring shaders
they already own.

**Strong recommendation: ISF is the native effect format**, and our built-ins are written in it.

#### (c) The Sources pane — PRE to the grid
Alley-like in that it's a **separate surface inside the one app**, for preparing what *feeds* the
grid. Proposed as a fourth persona, **Sources**:
- **Shader authoring** — write GLSL/ISF, live-compile, live-preview, expose parameters. Output
  becomes a source usable in any clip slot.
- **Generators** — noise, gradients, text, solids, patterns, audio-reactive visuals.
- **Media prep** — the genuinely Alley-ish part: browse, preview, inspect codec, and **batch
  transcode to HAP/DXV**. Converting a folder of H.264 to HAP is the single highest-value thing a VJ
  does before a gig, and having it in-app removes a whole separate tool from the workflow.

#### (d) Lazy load and unload — and the trap in it
**"Will not load unless opened, and will turn off if not used."** Agreed, and it's worth being
precise, because the obvious implementation breaks shows:

> **What unloads is the *editor*, never the *source*.** If a user authors a shader, assigns it to a
> clip, and closes the Sources pane, **that shader must keep rendering** — it's feeding a live layer.
> Closing a pane must never black a clip.
>
> So the module boundary is: **unload** the editor UI, the text buffer, the shader *compiler*, the
> preview renderer, the media-browser thumbnail cache and any transcode workers. **Keep** compiled
> pipelines and running source instances, which live in the engine's normal source pool like any
> video clip.

That split is cheap if designed in and nasty to retrofit, because it decides where compiled shader
pipelines are *owned* — the engine, not the editor. Same applies to the Effects persona (§3.5.2).

Lazy-loading is worth it beyond memory: a shader compiler and a live-preview renderer are real GPU
and CPU consumers, and §1.5's frame budget has no room for them during a show.

#### (e) GLSL on a Metal/D3D engine — the translation question
GLSL is what the VJ world writes; we run MSL on Mac and HLSL/WGSL on Windows. So shaders must be
translated, and this is a real subsystem, not a detail:

| Option | Notes |
|---|---|
| **`naga`** (wgpu's translator, Rust) | GLSL in → MSL / HLSL / WGSL out. Rust-native, fits `photon-core`, one dependency. **Likely the right default.** |
| **glslang + SPIRV-Cross** | GLSL → SPIR-V → MSL/HLSL. More mature and battle-tested for exotic GLSL; C++ dependency. |

**This belongs in `photon-core`** — translation feeds the same IR that emits native shaders per
platform (§0.6), so Mac and Windows get identical shader *semantics* with native backends. It also
means an ISF effect behaves the same on both, which is a product requirement, not a nicety.

**Risk to flag:** real-world ISF/ShaderToy GLSL uses constructs that don't translate cleanly
(dynamic loops, certain texture ops, driver-specific slop). Expect a compatibility tier — "ISF
subset supported, with a clear error when a shader can't be translated" — rather than claiming
universal support and failing mysteriously at a gig.

### 3.5.3 Blend modes decide the compositor design (Aiden, 2026-10-12)

**This is the constraint that actually settles how compositing works, and it overrides the
performance argument in §1.5.**

Metal's fixed-function blending (`MTLBlendOperation`) offers only add / subtract / reverse-subtract /
min / max with simple source and destination factors. **Mask, difference, multiply, overlay, hard
light, screen, colour burn — almost none of Resolume's blend set maps onto it.** Every one of them
needs to read the *accumulated result underneath* and compute against it.

So H3 was filed wrong. **Tile shading is not a ~3%-of-budget optimisation — programmable access to
the destination value is a capability requirement.** Three ways to get it:

| Approach | How | Verdict |
|---|---|---|
| **Ping-pong targets** | Two render targets, alternate read/write per layer | ✗ N intermediates, N resolves. What a naive implementation does. Rejected. |
| **Tile shading / imageblocks** | Read current framebuffer value in-shader, blend in tile memory | ✓ Works, one resolve. Needs tile-pipeline machinery. |
| **⭐ Register folding** | **One fragment shader samples all N layers and folds the blend stack in registers** | ✓✓ **Best at 4–12 layers.** No framebuffer read, no intermediates, no tile plumbing. Any blend mode is just arithmetic. |

**Recommendation: register folding, specialised per composition.** At this spec's layer counts the
whole stack fits in one fragment shader — an argument buffer holds N layer descriptors (texture,
opacity, blend-mode id, transform, crop) and the shader folds them bottom-to-top in registers. Mask
and difference become ordinary arithmetic on a value already in a register, which is the cheapest
place it can possibly live.

**Specialise, don't branch.** A `switch` on blend mode per layer per pixel is the slow way. Instead
compile a pipeline variant per *blend-mode stack*, using function constants, and cache it — keyed on
the stack signature so a given composition compiles once. Metal 4's `MTL4StitchedFunctionDescriptor`
(verified present in this machine's SDK) composes shader functions at runtime without a full
recompile, which is precisely the tool for assembling a blend stack on the fly. **This is the
compositor-level version of H7's kernel fusion, and it's needed in V1, not P4.**

**Cost to watch:** every layer is sampled at every pixel, even where occluded. 12 layers at 4K = ~100M
samples/frame; at 60fps that's ~6 Gsample/s. Comfortable on a 10-core M4, but it must be measured —
and it's the one place where raising the layer ceiling past ~16 would change the approach back toward
tile shading.

**And it composes cleanly with the hybrid above:** an FX'd layer is materialised first, then joins the
fold as just another texture to sample. One mechanism covers both requirements.

Master-level post effects don't have the materialisation problem at all — they run after the
composite, on one texture. **So a master-only node editor as the V1.5 cut avoids the break-out path
entirely** while still delivering the TouchDesigner surface.

---

## 4. Phases

**P0 — Evidence + benchmark harness.** *(gate: nothing else starts until the bench is repeatable)*
REA/MCP pass over Arena, Wire and TouchDesigner. Build `photonbench`: drives Arena via its own
OSC/REST API and Photon via CLI, same clips, same output res, locked 10-min runs, logs frame times
to CSV, produces p50/p99/worst-frame + a plot. Fairness rules written down and fixed before any
number is quoted. Generate a corpus: 1/4/8/16/32 layers × DXV3 / DXV4 / HAP / HapQ / H.264 / HEVC /
ProRes, 1080p / 4K / 8K.

**P1 — One layer, native Metal, measured.** MOV demux → DXV/HAP block extract → snappy → direct
`MTLBuffer` → `MTLTexture` → single fullscreen pass → window. Prove or kill H1 + H2.

**P2 — Fused compositor.** Layer stack, Resolume's blend-mode set, opacity/transform/crop, texture
array + argument buffer, generated single-pass blend, intermediates in tile memory. Prove or kill H3.
**This is where the headline number comes from.**

**P3 — I/O, projection mapping, and the native UI.** The biggest phase; split into three:

- **P3a — Sources in.** Syphon in first (zero-copy, highest value per unit of work), then
  ScreenCaptureKit and AVFoundation capture, then NDI in, then DeckLink. Every source lands as an
  `MTLTexture` and becomes a clip-equivalent in the layer stack.
- **P3b — Advanced Output, at Resolume parity.** ⭐ **A V1 requirement, not a stretch goal** — work
  the §3.2b checklist: screens/slices, quad (keystone) + bezier + grid warp, polygon masks, soft-edge
  blending, per-slice colour correction, test patterns, output presets stored separately from the
  composition. **Projective UV interpolation and linear-light blending are day-one decisions** (§3.2b
  traps). Then the sinks: physical displays, Syphon/Spout out, NDI out (own queue, off the render
  thread), Art-Net/sACN pixel mapping, virtual camera, record to disk.
- **P3c — Native UI (Perform + Map personas).** Affinity-style shell: corner persona switcher, thin
  chrome, persistent performance bar, `⌘K` command palette (§3.5.0). **Perform** persona = clip grid,
  deck tabs, layer strip, browser, dual previews, FX inspector, transport. **Map** persona = screens,
  slices, warp mesh, soft-edge. Grid, previews and mapper render in **Metal**, not views. Plus
  Art-Net/DMX in, MIDI in, LTC/MTC sync. Layouts are **fixed per persona** but expressed as a
  declarative, serialisable layout description per §3.5.1b. **V1 ships usable with no remote at all.**

- **P3d — Effects library.** ~30 built-in effects shipped **as ISF** (§3.5.4b), applied per
  clip/layer/group/composition from the FX inspector. Requires the GLSL→MSL translation path in the
  core, which is the same machinery P4 and the Sources persona need — so it lands here first and
  de-risks both.

**P4 — Sources + Effects personas (lazy-loaded).** Shader authoring, generators, media prep and
batch transcode to HAP/DXV (Sources, PRE); node graph (Effects, POST). Both load on open and unload
on close — **editors only; compiled pipelines and running sources stay owned by the engine** (§3.5.4d).

**P4b — The TouchDesigner half.** DAG with dirty-cook, node editor, TOP-equivalent GPU operators
(feedback, blur, displace, instancing), MSL node→shader compiler with pipeline cache, CHOP-equivalent
data channels (audio FFT, MIDI, OSC, LFO) driving any parameter. Prove or kill H4.

**P5 — Control server + remote protocol.** mDNS discovery, WebSocket + OSC, pairing/auth, state sync
and reconciliation, H.265 preview stream, embedded static file server.

**P6 — Photon Remote (web).** React/TS control surface served by the engine. Deck grid, layer strip,
transport, cue list, parameter binding, preview.

**P7 — Photon Remote (iOS).** Same protocol, SwiftUI shell, tuned for one-handed stage use.

**P8 — Moveable UI / docking.** ❌ **Cut, not scheduled** *(Aiden, 2026-10-12)*. Superseded by UI
templates in P3c (§3.5.1b). Revisit only if users actually ask for it — at which point it's "let
users edit and save a template", an editor over a data structure that already exists, not a new
subsystem.

**Deliberately not in V1:** moveable/dockable UI (cut), the node editor (P4), DXV *encoding*,
Windows build, audio playback engine, VST hosting, cloud sync, plugin marketplace, browser rendering
of any kind.

---

## 5. Parallel work split (Claude ↔ Codex)

The engine is Rust/Swift/Metal and single-threaded work by nature — so Codex does **not** get the web
app yet (that's P6, far away). Codex gets the thing that actually gates everything and is fully
independent: **P0, the benchmark harness and media corpus.**

| | **Claude (this agent)** | **Codex (parallel agent)** |
|---|---|---|
| Owns | `core/` (Rust), `macos/` (Swift+Metal), all RE and binary analysis | `bench/` (harness, corpus, analysis, plots), later `web/` + `ios/` |
| Language | Rust, Swift, MSL | TypeScript / Python, ffmpeg, shell |
| Phase | P1 → P4 | P0 now; P6/P7 when the engine is real |
| Needs | REA, Instruments, Resolume, TouchDesigner | ffmpeg, Resolume's OSC/REST API docs, a corpus spec |
| Blocked by | Nothing | Nothing — P0 is self-contained |

**Why this split works:** P0 has to exist before any performance claim is credible, it's pure
scripting with zero overlap into the engine, and it produces the artefact that tells us whether
H1–H4 are real. Codex building the scoreboard while Claude builds the player is clean parallelism
with one handoff (`photonbench` CLI contract) instead of a shared codebase.

**The contracts, frozen before parallel work begins:**
- `docs/bench-fairness.md` — the rules every published number must obey. **Claude writes this first;
  it is the spec Codex builds to.**
- `docs/bench-cli.md` — the CLI contract `photonbench` drives (so it can run against Arena today and
  Photon later, unchanged).
- `core/doc/schema.json` — the `.photon` document. Needed at P5, not now.
- `docs/control-protocol.md` — WebSocket + OSC message set. Needed at P5, not now.

Never edit the other agent's directories. Handover via Slack `#aidxn-claude`, as tickets, not chat.

---

## 6. Open questions for the review model

Browser-vs-native and iOS-as-controller are **settled** (§0) — don't reopen them.

1. Is H3 (pass fusion) actually where the win is, or is Arena's real bottleneck somewhere this
   evidence hasn't looked — its UI thread, its deck/preview rendering, per-clip state churn, or the
   ffmpeg path for non-DXV media?
2. **Is beating Arena on FPS even the right goal**, or is the defensible wedge "comparable FPS, plus
   a node graph and a networked control surface Resolume doesn't have"? Honest answer wanted — the
   FPS claim is expensive to chase and may not be what makes anyone switch.
3. What's the minimum credible V1 that's **usable at a real gig** rather than a benchmark demo? The
   phase list says P3; is that right, or is something missing that makes it unshippable in practice?
4. Licensing/IP: is read-only DXV support via clean interop RE the right line, or should V1 be
   HAP-only and treat DXV as a convert-on-import step through Resolume Alley?
5. Is **Rust core + Swift shell** the right division, or does the FFI boundary cost more than writing
   the engine in Swift outright — given there's now only one platform and one graphics API?
6. Is P0-as-Codex's-lane sound, or does the benchmark harness need engine internals (frame
   instrumentation hooks) that make it non-independent?
7. What's the realistic calendar here for one person plus agents, and which phase is most likely to
   be where this stalls?
8. **I/O priority.** §3.3 lists 7 sources and 6 sinks. Which subset is the actual minimum for a real
   show — and is NDI out (encode cost on every stream) going to quietly destroy the frame-rate
   advantage the whole project is premised on? If so, what's the mitigation: dedicated encode queue,
   lower-rate preview streams, or accept it and publish both numbers?
9. Is the "projector = rectangle inside an output canvas" abstraction (§3.3) right, or does it break
   on genlock, per-projector refresh, or mixed-resolution rigs in a way that'll need rework at P3b?
10. **H5 is the one to attack hardest.** `MTLIO` is designed for asset streaming, not frame-locked
    playback. Is per-frame `loadTexture:` with a 16ms deadline actually viable, or does queue depth /
    completion latency / lack of frame-accurate seek kill it? If it dies, the headline mechanism dies
    with it and we fall back to CPU snappy like everyone else — so this deserves a prototype before
    anything else is built on it.
11. Given the storage wall (§2.5), **should the RAM-resident ring cache be V1 rather than an
    optimisation?** 128GB of unified memory changes what's possible here, and a design that assumes
    streaming-from-disk may be the wrong shape from day one.
12. Is a **Photon-native clip format** (BC7/ASTC + LZBitmap in an MTLIO pack) worth the adoption cost
    of asking users to transcode their library — or does that friction sink the product regardless of
    how fast it is? Resolume solved this by making DXV *their* format and bundling Alley to convert.
13. H7 (operator kernel fusion): what fraction of real node chains are actually fusible once
    full-image dependencies (blur, feedback, reductions) force splits? If it's low, the compiler
    isn't worth building and P4 should just do one-pass-per-operator like TD.

---

## 7. Status

- [x] Evidence pass 1 — Arena binary linkage + codec symbols
- [x] REA installed globally (`rea-agents` 6.4.0)
- [x] Browser-vs-native decision settled (2026-10-12)
- [x] Optimisation pass — H5/H6/H7 added, stack narrowed, storage wall found (§2.5)
- [ ] **Higher-model review of this proposal** ← current gate
- [ ] Freeze `docs/bench-fairness.md` + `docs/bench-cli.md`
- [ ] P0 benchmark harness (Codex) ‖ P1 single-layer Metal prototype (Claude)

**Nothing below the review gate starts until the plan is signed off.**

> `web/` currently holds an untouched Vite scaffold from before this decision. It is **not** part of
> V1 and is not in the import path of anything. It stays dormant until P6, or gets deleted at review
> sign-off if P6 is cut.
