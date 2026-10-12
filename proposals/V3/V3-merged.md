# Photon — V3 (merged proposal)

**Author:** Claude Code agent, adjudicating `V2-claude.md` against `V2-codex.md`.
**Date:** 2026-10-12. **Status:** proposed for adoption. **Supersedes both V2s.**

**Final Codex pass:** [V3-codex.md](V3-codex.md). The performance amendments below are incorporated;
the single V4 build contract is [docs/scaffold.md](../../docs/scaffold.md).

> **On adoption, both V2s move to `proposals/_retired/`.** V3 becomes the single source of truth.
> This document does not duplicate the V2s — where a section was right, it says so and cites it
> rather than copying it. Detail lives in the retired docs until V3 absorbs it during scaffolding.

**Headline:** Codex wins on **engineering method and measurement**. Claude wins on **product scope,
feature specification and the pipeline decisions that must be made before any code exists.** Those
two things barely overlap, which is why a merge is genuinely better than either — and why the right
move is adoption, not a bake-off.

---

## 1. Adjudication

### 1.0b Second-pass corrections from the expanded `V2-codex.md`

*Accepted after re-reviewing Codex's 597-line revision. Detail in `review-of-v2-codex.md`.*

| # | Correction | Effect |
|---|---|---|
| **A1** | **HEVC is not the universal WebRTC baseline.** RFC 7742 requires **VP8 + H.264**. | Use **H.264** as the interoperability target and negotiate newer codecs when supported; NDI stays a separate native adapter. |
| **A2** | **🔴 Browsers can't enumerate Bonjour.** | Claude assumed mDNS discovery for the *web* remote. → mDNS for **native** clients only; engine-displayed **URL + QR code** and manual address for browsers. |
| **A3** | **A HAP-only prototype cannot claim the tiers.** The spec is written in **DXV**. | The initial walking slice stays HAP, but **no tier pass/fail is valid until the DXV adapter lands.** Current build contract: docs/scaffold.md. |
| **A4** | **128 clip slots ≠ 128 decoders**, and not every UI element must be custom Metal. | Claude over-specified. → **one bounded shared Metal thumbnail surface**; static thumbnails for idle clips, ready source textures for playing ones; ordinary SwiftUI/AppKit for controls; measure before making anything else custom. |
| **A5** | **§7's R0–R8 staging** with per-stage acceptance evidence. | **Adopted as V3's delivery plan (§5.1)**, replacing V2-claude's P0–P8 phases. It's better — each stage names the evidence that closes it, rather than just the work. |
| **A6** | **Defer CBOR** until measured load time justifies a second serialisation. | Supersedes Claude's JSON+CBOR dual format. Versioned JSON only. |

### 1.1 Codex wins — adopted outright

| # | Point | Why it wins |
|---|---|---|
| 1 | **H2's zero-copy path doesn't exist.** `MTLBuffer.makeTexture` doesn't accept block-compressed formats. | Factual API constraint. Claude asserted a capability that isn't there. |
| 2 | **Linked libraries ≠ active render path.** MoltenVK caches translated shaders; translation isn't necessarily per-frame. | Claude over-attributed cause from `otool` output. H1 needs a trace. |
| 3 | **🔴 `NDI_send` takes linear frame memory; Art-Net needs CPU-visible packets.** | **Kills Claude's "pixels never touch the CPU" invariant.** It would have broken on the first NDI output. Invariant rewritten — §2.3. |
| 4 | **🔴 A tile-memory result cannot be handed to an external consumer after the pass.** | Directly contradicts Claude §3.3's "every sink reads from the same tile-resident result". Codex is right. |
| 5 | **"One extra pass total" for arbitrary output topology is wrong.** Independent sinks need their own destination render, conversion and sync. | Claude's claim only held for slices sharing one destination. |
| 6 | **Mixed-refresh outputs are not one vsync source.** Per-output presentation adapters; `CAMetalDisplayLink`, not a main-thread timer. **Don't promise genlock from ordinary presentation.** | Correct and Claude under-specified it. |
| 7 | **🔴 Arena's Auto mode follows display refresh** — a 60Hz cap hides throughput in any comparison. | Would have silently invalidated every benchmark. |
| 8 | **🔴 Resolume's published REST API exposes no raw frame-timing stream** (258-path spec reviewed; `framerate` is a *target*). | **Undermines P0's premise.** See §4.1 — this is the single most important finding in either document. |
| 9 | **Installed ffmpeg cannot encode HAP** (no `--enable-libsnappy`) and **exits 0 while failing.** | Blocks corpus generation. Preflight must inspect capabilities, not exit codes. |
| 10 | **Dev box is 36GB, target is 32GB.** Claude's "128GB" was invented. | Cache budgets must come off real numbers. |
| 11 | **A near-static video still advances timestamps and decodes.** Benchmark stills, paused clips, near-static playback and motion separately. | H4's "free" case was overstated. |
| 12 | **Argument-buffer arrays of individual texture refs, not one 2D array**, for heterogeneous sources. | A shared descriptor forces conversions and copies. |
| 13 | **"N resolves" conflates attachment stores with MSAA resolves**; multiple draws can share an attachment without storing. | Sloppy framing that overstated H3. |
| 14 | **Preserve the last valid frame on underrun; blackout is an explicit operator command.** | Correct live-production instinct, absent from Claude's. |
| 15 | **Full colour descriptor** — primaries, transfer function, matrix/range, alpha convention — on every source/frame. | Claude had linear-light but not the descriptor. Both needed. |
| 16 | **Match Arena's output bit depth and colour behaviour when comparing.** | Otherwise we "win" by doing less colour work. |
| 17 | **Bounded queues with defined backpressure**; render path does no I/O, no shader compilation, no sync waits. | Standard realtime discipline, correctly specified. |
| 18 | **MTLIO and ICB are experiments, not commitments.** | Agreed — and Claude's §1.5 already demoted them. See §1.3 #2. |

### 1.2 Claude wins — retained

| # | Point | Why it stands |
|---|---|---|
| 1 | **Mask/difference need destination access; fixed-function blending can't express them.** | A **capability** requirement, not a perf preference. Codex's "ordinary ordered draws in one pass" baseline cannot produce those blend modes at all. **Refined** by Codex's valid caveat — see §1.3 #1. |
| 2 | **🔴 Projective (homography) UV interpolation for keystone warps.** | Affine interpolation bends the texture along the triangle diagonal. Absent from Codex's. Day-one decision. |
| 3 | **🔴 Linear-light compositing**, encode only at output. | Soft-edge blending in sRGB produces a visible seam — the exact artifact it exists to remove. Pipeline-wide, absent from Codex's. |
| 4 | **ISF as the native effect format.** | Hundreds of existing effects for free; the VJ world's standard. Absent from Codex's. |
| 5 | **Advanced Output parity checklist** (12 items), mapping stored separately from the composition. | Codex specifies *concepts* correctly but no feature bar. Both needed. |
| 6 | **Persona shell + fixed UI templates; docking cut.** | Aiden's decision; Codex concurs on deferral. |
| 7 | **Transport-capability negotiation; BLE carries control but not preview; protocol is state-sync-first because MIDI pushes state to pads.** | Absent from Codex's. Sizing the wire format for BLE is a day-one call. |
| 8 | **Internet control is a security problem** — outbound-only relay, revocable per-device tokens, authorisation tiers. | Absent from Codex's. |
| 9 | **Lazy-load the editor, never the source.** Closing the Sources pane must not black a live clip. | Decides where compiled pipelines are *owned*. Absent from Codex's. |
| 10 | **`photon-core` contains no Apple API, enforced by CI.** | Both agree on the boundary; Claude adds the enforcement mechanism. |

### 1.3 Split decisions — neither wins outright

**1. Blend modes: hybrid, not uniform.** Codex is right that "all blend modes need the same
machinery" is too broad — **add, multiply and screen *are* expressible in fixed-function blending**;
difference, overlay and hard-light need programmable destination access; mask behavior depends on
its exact equation and alpha semantics. Register folding is the initial candidate at 4–12 layers,
not a measured cheapest implementation. Programmable fragment blending remains another supported
candidate if the chosen stack or coverage benefits from it.

> **Resolution:** the planner picks per stack. A stack that is entirely fixed-function-expressible
> uses ordinary ordered draws. The moment one layer needs destination access, that stack compiles to
> a register-folded shader. **Keep a correct generic unfused reference implementation permanently**
> (Codex) and validate the fast path against it.
>
> Also adopted from Codex: **specialise asynchronously, bound the pipeline cache, never block
> playback on compilation.** A new blend stack appearing mid-show must fall back to the generic
> shader that frame, not stall. Function stitching is not evidence that pipeline creation is free.

**2. The MTLIO contradiction Codex caught is real — resolved here.** `V2-claude.md` demotes MTLIO in
§1.5 (correct, once 1080p landed) but §2.5 still calls it "the headline mechanism". That is an
internal inconsistency introduced when the resolution target changed and not propagated.
> **Resolution: MTLIO is an experiment, scheduled after V1 ships, gated on 4K ever mattering.**
> V1 uses CPU snappy on a bounded worker pool. All "mandatory"/"zero-CPU" language is withdrawn.

**3. "480 layer-frames/sec, one target two shapes" — half right.** Codex: 4×120 and 8×60 are *not*
interchangeable tests; presentation, final stores, output warps and deadlines differ.
> **Resolution:** 480 lf/s is a valid **source-throughput** metric and useful for sizing decode,
> disk and RAM. It is **not** an equivalence for acceptance. Tiers A and B are measured separately,
> and the bench reports **source frame production, composition frames and output presentation as
> three distinct numbers.** Also adopted: corpus cadence must be genuine — drawing a 30fps texture
> at 120Hz does not demonstrate 120fps media decoding.

**4. Measure-first vs. ship-first.** Codex defers nearly every decision to measurement; this is
methodologically right but, applied uniformly, becomes a research programme, and this project's real
risk is stalling before it ships.
> **Resolution — the dividing line:** *decisions that are expensive to reverse are made now on
> reasoning; decisions that are cheap to reverse are made later on data.* Projective UVs, linear
> light, the colour descriptor, core/shell boundary, state-sync-first protocol, document schema →
> **decide now.** MTLIO, ICBs, tile shading, operator fusion, cache sizing, thread counts →
> **measure later.** §3 applies this split to every item.

---

## 1.5 ⭐ Who this is for, and the design principle that follows (Aiden, 2026-10-12)

*"Obviously we are all LD techs using this."* · *"But we can keep it simple and less of a learning curve."*

**The user is a working lighting/AV technician.** Not a novice, not a programmer. They know what a
universe is, what a gobo is, what patching means, what a cue stack does. That changes the design
target in a specific way:

> **Domain-expert simple, not beginner simple.**
>
> **Use their vocabulary** — fixture, patch, universe, cue, pan/tilt, gobo, strobe, slice, soft edge.
> Industry words, not software words. An LD should never have to learn our invented terminology for
> something that already has a name on every rig they've worked.
>
> **Remove the plumbing, not the information.** They shouldn't do channel arithmetic when the
> fixture profile already knows it, re-patch from scratch every show, or run three applications to
> do one job. But **never hide the technical layer** — when a tech is on headset at 10pm asking why
> universe 3 is dead, they need the universe number, the transport, the address and the live values
> immediately. **Human names in the foreground, technical truth one click away, never required for
> the normal path.**

**The learning-curve target, stated as positioning:**

| | |
|---|---|
| **Resolume** | Easy to start, limited ceiling |
| **TouchDesigner** | Very high ceiling, famously brutal learning curve |
| **Photon** | **Resolume's first hour, TouchDesigner's ceiling** |

That's the whole product thesis in one line, and it's achievable *only* because of decisions already
made: the node pane is **opt-in and lazy-loaded** (§2.4b/§3.5.4d) so nothing about the grid requires
knowing it exists; the **modulation system** means beat-syncing a parameter is a drag, not a patch;
**GDTF** means fixtures arrive pre-defined; **ISF** means effects arrive pre-built.

**Rules this imposes on everything downstream:**
1. **Defaults must work.** Drop a node, patch a fixture, add an effect — it does something sensible
   with zero configuration. Configuration is for changing behaviour, never for achieving it.
2. **Programming is never *required* to produce visual output — but it's welcome as an addition.**
   *(Corrected by Aiden 2026-10-12; the original "no programming, ever" was too absolute.)*
   Shaders, expressions and scripting live **only in the node pane**, as a ceiling-raiser for people
   who want it. **No path to a visual output may depend on writing code.** TouchDesigner's Python
   requirement is its single biggest adoption barrier; the difference is *optional vs. load-bearing*,
   not present vs. absent.
3. **Progressive disclosure.** Simple surface, technical detail available on demand, expert controls
   present but not in the way.
4. **Presets over blank canvases.** Common rigs, common mappings, common looks ship as starting
   points. A blank node graph is intimidating; a working one you can modify is not.
5. **The grid alone is a complete product.** Someone who never opens Sources, Effects or the patch
   screen should still have a tool worth using.

---

## 2. The merged architecture

### 2.1 Unchanged from both (both proposals agree)
Native macOS app, Swift + Metal + MSL, Mac is the target market. Shared `photon-core` Rust crate
owning documents, codecs, graph, IR and protocol, with **no Apple API in it**. Windows later as a
separate repo with its own renderer and shell. Web/iOS are remote control surfaces only, later.
*(See `V2-claude.md` §0.6 and `V2-codex.md` §2 — identical conclusions, reached independently.)*

### 2.2 Render graph (Codex's shape, Claude's requirements)
```
source prep → effects → layer composition → slice / warp / colour → sinks
```
Per-output **presentation adapters** with their own deadlines (`CAMetalDisplayLink`), not one shared
vsync. Composition, output canvas, slice and physical sink are **four distinct concepts** — a slice
is a mapped region; a sink owns refresh, mode, colour capability and delivery.

### 2.2b ⭐ Sinks run at their own rates — Art-Net is a slow sink, not a constraint (Aiden, 2026-10-12)

**"If we need to go through Art-Net it can degrade in frames, that's an old technology."** Correct,
and it resolves cleanly once sinks are rate-independent.

**Why Art-Net is capped:** it's DMX512 over UDP — 512 channels per universe, and DMX's serial timing
tops out near **44 Hz**, with most nodes emitting 30–40 Hz. It is structurally incapable of 60fps,
let alone 120. That is a property of DMX, not of our implementation, and no amount of engineering
changes it.

> **Therefore Art-Net never gates the render rate.** It is a **rate-limited sink** with its own
> deadline, sampling the most recent composition at 30–44 Hz while projectors run at 60 or 120. This
> falls straight out of Codex's per-output presentation adapters (§2.2) — Art-Net is simply an
> adapter with a slow clock. **A sink that cannot keep up must degrade itself, never the engine.**

**And for real LED, Art-Net is usually the wrong path entirely.** Modern LED processors — Novastar,
Brompton, ColorLight — accept **HDMI/DisplayPort video directly** and drive the panels themselves,
at up to 240 Hz on high-end units. **So an LED wall is just another output canvas rectangle in the
screen/slice model, at full frame rate, with no DMX involved.** That's already built.

| LED path | Rate | Use |
|---|---|---|
| **Video → LED processor** (HDMI/DP) | Full — 60/120/240 Hz | **The default.** Any real LED wall. Already handled by screens/slices. |
| **NDI → processor** | Full, minus encode | Processors that accept NDI; avoids a cable run. |
| **sACN (E1.31)** | ~44 Hz | Better than Art-Net: multicast, priority, sync packets for coordinated universe updates. **Prefer over Art-Net where supported.** |
| **Art-Net** | 30–44 Hz | Legacy nodes, architectural installs, pixel tape. Compatibility only. |

**Revised position — confirmed by Aiden 2026-10-12:** *"This is mostly for projectors. DMX and other
things way later."*

> **V1 is a projector product.** Physical display outputs, warping, soft-edge blending and
> multi-projector topology (§3.2b) are the V1 output story, full stop. **Art-Net, sACN and all DMX
> pixel-mapping are way later**, implemented as a low-rate compatibility sink when they come.
> When they do: **sACN first, Art-Net after, for old gear.**

The engine must still be *built* with rate-independent sinks (above), because that's what lets a slow
sink attach later without touching the render path — but no DMX code ships in V1.

#### ⭐ …but fixtures are a real destination, and the node graph is how they're controlled (Aiden, 2026-10-12)

*"They will be a thing, especially in the node output — that will be the main way we control it, and
we aim to make it more simple. The nodes just speak the more human names, like fixture, then the
technology. Just making it easier to find in the menu."*

**This changes what the node graph is.** §3.5.2 framed it as post-effects. It is also the **output
patching and fixture-control surface** — the place where composition, effects and physical
destinations all meet. That's a bigger role and it needs designing for, even though it ships later.

**The principle: human concept first, transport second.** The node library is organised by *what the
thing is*, not by how it's wired:

```
Outputs ▸  Projector        → screen / slice / warp         (video)
           LED Wall         → processor feed                (video / NDI)
           Fixture          → Moving Head · Wash · PAR · Strobe · Haze   (sACN / Art-Net)
           LED Strip        → pixel map                     (sACN / Art-Net)
           Laser            →                               (later)
           Syphon / NDI     → other software                (video)
```

A user drops a **Fixture** node, picks "Moving Head", and gets **Pan, Tilt, Dimmer, Colour, Gobo,
Strobe** — the words on the fixture's own spec sheet. Addressing, universe and transport are set
**once** in a patch screen rather than repeated in every node.

**This is not hiding DMX from people who understand DMX** (§1.5) — our users are LD techs. The
universe, address and live channel values stay visible on the node, in the patch screen, and in a
live DMX monitor, because at 10pm on headset that's exactly what they need. What's removed is the
*arithmetic* and the *repetition*, not the information. Every other tool in this space makes the
channel offset the primary interface; that's the thing worth fixing.

> **🔴 Adopt GDTF for fixtures — the same play as ISF for effects.**
> **GDTF** (General Device Type Format) is the open fixture-definition standard backed by MA
> Lighting, Robe and Vectorworks, with a large public library at gdtf-share.com; **MVR** is its
> companion rig-exchange format. Supporting GDTF means **a fixture library we don't have to author
> or maintain**, correct channel layouts per mode, and real manufacturer names in the menu for free.
> It is exactly the ISF argument applied to lighting, and it's what makes "human names" actually
> achievable rather than a hand-curated subset.
>
> *Verify adoption breadth and parser-library maturity before committing — but this is the obvious
> candidate.*

**Consequences to design for now, build later:**
- The node graph sits in the **output path**, not only the effects path. Its planner must handle
  nodes whose sinks run at 30–44 Hz alongside video sinks at 60–120 Hz — which the rate-independent
  sink model (above) already supports.
- **Fixture parameters are modulation targets like any other** (§2.4c): a beat LFO can drive a
  moving head's pan exactly as it drives a layer's opacity. One modulation system covers lighting
  and video, which is the whole reason to build it generically.
- **Patch state is part of the document**, and like the mapping (§3.2b) it travels separately —
  the same show, a different rig.

This positions Photon as a **media server and lighting controller in one**, which is what the high
end (disguise, Hippotizer) does. Ambitious, explicitly later, but the architecture should not
preclude it — and the only thing needed *now* is that sinks are rate-independent and parameters are
uniformly modulatable. Both are already decided.

#### ⭐ What the node pane is *for* — scope, settled (Aiden, 2026-10-12)

*"The TD pane is for manipulating the things made in the 2 panes before, or if really skilled and
not for V1, building visuals from scratch in just the last pane."*

```
   PANE 1: Sources   →   PANE 2: Grid   →   PANE 3: Node / TD pane
   shaders, media,       clips, layers,      manipulate what the
   generators            blend, composite    first two produced
```

**Primary role — manipulation, not origination.** The node pane consumes the composition (or
selected layers, per §3.5.2) and transforms it. Its first version therefore needs **manipulator
operators only** — blur, displace, feedback, colour, warp, instancing, routing to outputs and
fixtures. **It does not need generator operators**, because sources are Pane 1's job.

That is a large scope reduction and it should be held to: an operator set of ~25 manipulators is a
tractable first node pane; a full generative environment is not.

**Secondary role — generative, explicitly later and explicitly not V1.** A skilled user eventually
building a visual from nothing inside the node pane alone. Allowed by the architecture, not
scheduled, and never the path a normal user takes.

**The consequence that matters:** the node pane is **always optional**. Every visual output in the
product is achievable through Sources + Grid with no node graph open at all. The node pane raises
the ceiling; it never holds up the floor. This is what makes §1.5's "Resolume's first hour,
TouchDesigner's ceiling" actually true rather than aspirational — and it's why the pane is
lazy-loaded and unloaded (§3.5.4d) rather than being part of the running engine.

#### ⭐ The graph is heterogeneous: every node declares a domain and a rate (Aiden, 2026-10-12)

*"DMX and other signals can be in the later TD-like pane, and they can all have their own output,
CPU or GPU when required in that pane."*

This is TouchDesigner's operator-family model and it's the correct shape: TD separates **TOPs**
(textures → GPU) from **CHOPs** (channels → CPU) and **DATs** (data → CPU), because they genuinely
run in different places. Photon adopts the same split, generalised to two axes:

> **Ports declare data kind; nodes declare placement and scheduling.**
> Data = texture/image · sampled channels · events · tables/bytes.
> Placement = GPU · CPU · either. Scheduling = clock domain + inherit/fixed/on-change/event policy.
> Channel sample rate is separate from processing-job cadence.

| Node family | Domain | Typical rate | Examples |
|---|---|---|---|
| **Texture** | GPU | composition rate (60/120) | blur, displace, feedback, composite, warp |
| **Channel** | CPU | varies | audio bands, LFOs, envelopes, MIDI, OSC, math |
| **Data** | CPU | on-change | tables, cue lists, fixture patch, text |
| **Fixture / DMX out** | CPU | **30–44 Hz** | sACN/Art-Net universes, fixture parameters |
| **Video out** | GPU | 60–120 Hz | projector, Syphon, NDI, LED processor |

**The planner's job** is grouping work with compatible placement, effective clock/rate,
dependencies and side effects. GPU batches may fuse compatible operations; small CPU operations
run within a batch rather than creating one thread-pool job each. A lower-rate DMX branch can run
independently of the video branch. Cross-rate edges explicitly hold/interpolate/resample values
or preserve ordered events, with timestamps and bounded queues.

> **🔴 The expensive thing is crossing domains, and it must be explicit.**
> A GPU→CPU edge — e.g. sampling the composition to produce pixel-mapped DMX values — is a
> **readback**, and a synchronous one would stall the render thread and destroy the frame budget.
>
> **Rules:**
> - Domain crossings are **explicit nodes**, visible in the graph, never implicit in an edge. The
>   user can see where the expensive boundary is.
> - GPU→CPU readback is **asynchronous and ring-buffered**. Its latency and maximum age are measured
>   in time; no universal “one frame” or imperceptibility guarantee is made.
> - The readback runs at the **consumer's** rate (44 Hz for DMX), not the render rate — so pixel
>   mapping costs a fraction of what a per-frame readback would.
> - Its cost is **counted and reported**, per Codex's rewritten invariant #3 (§2.3).
>
> This is exactly the case Codex's invariant was written for, and it's why "no CPU readback ever"
> was the wrong rule: pixel mapping is a legitimate, necessary readback. The discipline is that it's
> bounded, async, rate-limited and measured — not that it's forbidden.

**Each node may own its output/sink**, so the graph can fan out to many destinations at different
rates and in different domains from one composition — which is the thing that makes a single node
pane able to drive projectors, LED walls and lighting rigs simultaneously.

**Decide-now from this:** typed ports, placement, clocks/rate policies, temporal dependencies,
and explicit domain/rate crossings. These are structural contracts; the public node editor and
its operator library remain later work.

This also removes a risk from §2.3: Art-Net needing CPU-visible packet data is no longer a per-frame
cost on the hot path, because it's sampled at a fraction of the render rate on its own adapter.

### 2.3 Invariants — rewritten
Claude's originals were too absolute and conflicted with NDI and Art-Net. Replaced with Codex's,
plus the two Claude additions that survive:

1. No **synchronous** CPU frame readback in the compositor or GPU effects.
2. Store/export the finished composition when another pass or external consumer needs it.
3. Permit **bounded asynchronous** readback in output adapters and correctness tests — and count its cost.
4. Fuse compatible work when evidence supports it; **always keep a correct unfused reference.**
5. Generate all consumer types from **one** authoritative document definition.
6. **(Claude)** The compositor works in **linear light**; encode only at final output.
7. **(Claude)** Warps interpolate **projectively**, never affinely.

### 2.4 ⭐ Music / beat integration and the modulation system (Aiden, 2026-10-12)

**"We very much need music beat integration for these effects and the way the videos play, through
their playthrough type or other selections."** Neither V2 specified this properly. It is a V1
requirement and it reshapes the clock from a transport readout into a **tempo authority the whole
engine reads.**

#### (a) Clip transport modes — "playthrough type"
Per clip, matching Resolume's model:

| Mode | Behaviour |
|---|---|
| **Timeline** | Free-running at the clip's own rate. Not tempo-locked. |
| **BPM Sync** | Clip loop length quantised to musical time — ½, 1, 2, 4, 8, 16 beats/bars. Playback rate is derived from tempo, so the clip *always* lands on the beat. |
| **Frames / position** | Direct scrub; position driven by a parameter (so it can be modulated — see (c)). |

Plus the orthogonal playthrough selections: **once / loop / ping-pong / random / hold-last-frame**,
forward or reverse, with in/out trim points.

**Trigger quantisation** is separate from transport: launch on next beat / bar / 2 / 4 / 8 bars, or
immediately. A VJ sets this globally and overrides per clip.

#### (b) Tempo sources — the clock becomes an authority
`photon-core`'s `clock` owns tempo and **phase**, with pluggable sources:

| Source | Notes |
|---|---|
| **Tap tempo** | Baseline, always available. |
| **🔴 Ableton Link** | The one that matters most — tempo *and phase* shared over LAN with Ableton, Traktor, Serato, Resolume, VDMX. If the DJ runs Link, Photon is locked to the actual set with zero configuration. Highest value-per-effort in this whole feature. |
| **MIDI clock** | From a DJ mixer, drum machine or DAW. |
| **Audio beat detection** | From a live input when nothing else is available. |
| **LTC / MTC timecode** | Theatre and broadcast; already in the plan. |
| **Manual** | Fixed BPM. |

> **Design note: predict, don't react.** Onset detection has tens of milliseconds of inherent
> latency, so *reacting* to a detected beat is always visibly late. The clock maintains a **tempo and
> phase estimate** and predicts beat boundaries ahead of time; detection corrects the estimate rather
> than triggering the visual. Link and MIDI clock give phase directly and should be preferred over
> audio detection whenever present.

#### (b2) ⭐ Ableton Link early + rekordbox compatibility (Aiden, 2026-10-12)

**Link is scheduled early.** Two findings from checking primary sources, both consequential:

> ### 🔻 Deferred by Aiden (2026-10-12): **Ableton Link is a later release, not V1.**
> Target: **Photon 3.0 or 4.0** (see naming note in §8). Removed from the early path.
>
> **Licensing gate still applies when it lands.** Link is **dual-licensed GPLv2+ or proprietary**; a
> closed-source commercial Photon cannot use the GPL version and needs a proprietary grant from
> `link-devs@ableton.com`. Free, but request-and-agree, not a download. **No longer urgent** — but
> it must be obtained *before* Link ships, not after it's integrated. *(Source: Ableton/link repo.)*
>
> **What this changes for V1:** tempo comes from **tap tempo** and **MIDI clock**, with the clock
> built tempo/phase-separable from day one so Link and Pro DJ Link slot in later without rework.
> The separability decision stays in "decide now" (§3) precisely because Link is deferred — it's
> what makes the deferral cheap.

**Integration shape:** C++17, header-only, depends on Asio. Runs on macOS, Windows and Linux — so it
belongs in **`photon-core`** (no Apple API, satisfies the Windows rule) behind a thin Rust FFI
(`cxx` or a C shim). One implementation serves both shells.

**🔴 rekordbox: Link gives you tempo, but not phase.** Per Pioneer's own community forums,
rekordbox's Link implementation syncs BPM but does **not** reliably communicate the downbeat — "the
kicks do not match" against a Link peer. For a VJ tool this is the difference between useful and
useless: matching tempo while drifting against the downbeat means every beat-synced visual is
subtly, continuously wrong.

> **Design consequence, and it's the important one: tempo and phase must be separable sources.**
> The clock must accept BPM from one source and downbeat/phase from another, rather than assuming a
> single source provides both. Cheap to design in; a rewrite to retrofit.

**The rekordbox ladder**, best to worst:

| Path | Gives | Notes |
|---|---|---|
| **Pro DJ Link** (CDJ/XDJ over ethernet) | **Tempo + beat grid + phase + master player + track metadata** | What clubs actually run. CDJ-3000/XDJ, not laptops. **The real answer for rekordbox.** Protocol is undocumented; open implementations (Deep Symmetry `beat-link`, `dysentery`) are reverse-engineered — same interop posture as DXV: no redistribution of their code, compatibility only. Maturity of Rust bindings needs checking before committing. |
| **Ableton Link** | Tempo; phase unreliable with rekordbox | Ship early anyway — it's one integration covering Ableton, Traktor, Serato, VDMX, Resolume and laptop rekordbox. |
| **MIDI clock** | Tempo + coarse phase via song-position pointer | Universal fallback from a mixer or DAW. |
| **Audio beat detection** | Estimated tempo + phase | Last resort when nothing else is on the network. |

**Recommendation:** Link early as Aiden asked, with the clock built tempo/phase-separable from day
one. Then evaluate Pro DJ Link as the phase source for Pioneer rigs — that combination (Link for
tempo, Pro DJ Link for phase, audio detection as fallback) is what makes Photon actually lock to a
club set, and it's a genuine differentiator.

#### (c) One modulation system, many sources
Beat sync and audio reactivity are the same problem as MIDI mapping (§3.2b of V2-claude), so they
share one mechanism rather than three. **Any parameter, addressed by path, can be driven by any
modulation source:**

| Source | Examples |
|---|---|
| **Audio bands** | FFT → low / mid / high envelopes, with gain, threshold, attack/decay smoothing. Plus user-defined bands. |
| **Beat LFOs** | Sine/saw/square/noise **synced to musical time** — a 4-bar sine, an eighth-note square. |
| **Envelopes** | Triggered on clip launch or beat. |
| **MIDI CC / OSC** | Already specified. |
| **Manual / automation** | Direct value or recorded automation. |

Each binding has depth, offset, curve and polarity, and several can stack on one parameter. **This is
the single feature that makes a VJ tool feel alive**, and because it reduces to "modulation sources
write to parameter paths", it costs one well-designed subsystem rather than per-feature special cases.

#### (d) Audio I/O constraints
- Audio input callbacks publish preallocated blocks to a **bounded analysis worker**. FFT setup,
  windows and scratch buffers are reused; no heavy analysis, allocation or logging in the input callback.
- Analysis publishes **timestamped snapshots** that the render path samples without waiting.
  **Audio analysis must never block or be blocked by the render path.**
- Input sources: system audio in, specific device, Syphon/NDI-adjacent audio, or the OS loopback.
- **Photon plays no audio.** It analyses and syncs only — audio playback stays explicitly out of V1
  (consistent with both V2s).

#### (e) Where this lands
**V1.** Transport modes, trigger quantisation, tap tempo, Ableton Link, audio bands and beat LFOs.
MIDI clock and audio beat detection can follow. The modulation system must exist in V1 regardless,
because retrofitting it means rewriting every parameter in the app.

**Decide-now (§3):** the clock as a phase authority, the modulation-binding model, and
parameter-path addressing. All three are expensive to reverse and cheap to get right up front.

### 2.4b Product specification
Carried from `V2-claude.md` unchanged — Codex's proposal does not contest any of it and contains no
competing product scope: Advanced Output parity checklist (§3.2b), personas + UI templates (§3.5.0–b),
effects library and ISF (§3.5.4), Sources pane with editor-only unloading (§3.5.4d), control
transports and security (§3.1b), MIDI mapping with state push (§3.2b).

---

## 2.9 ⭐ The positive performance plan — how Photon is actually fast

*Added after reviewing the expanded `V2-codex.md` (see `review-of-v2-codex.md`). Both V2s demoted
every exotic mechanism to "measure first" — correctly — which left the project with **no stated
means of being fast.** This section is that means. **None of it depends on an unproven API.***

| # | Mechanism | Why it matters here | Stage |
|---|---|---|---|
| **C1** | **QoS / task priorities** | Deadline-sensitive presentation stays short and separate from active decode/analysis (`.userInitiated`). Optional preparation/logging uses lower QoS; active-stream prefetch retains deadline priority. QoS informs the OS, **does not pin cores or guarantee deadlines**. The observed dev box has 10 P-cores, not 16. | **R0** |
| **C2** | **Conservative occlusion** | Truncate lower compositing work only when source-over coverage and source alpha are provably opaque, including masks, crop, transforms and effects. Opacity=1 alone is insufficient. Preserve transport and demanded side effects. Compare with the correct reference. | **R2** |
| **C3** | **Damage regions** | Evaluate after full redraw works. Include old/new bounds, removals, filter expansion and dependencies. Disable for unknown/global or temporal feedback dependencies. Cached target load/store traffic may erase the win on a tile-based GPU. | **R2** |
| **C4** | **Bounded in-flight resources** | Preallocate three dynamic resource slots; initially cap submitted GPU frames at two, comparing three in R1. Explicit leases last through all GPU/sink consumers. Never overwrite an in-use slot or wait for decode in presentation. | **R1** |
| **C5** | **Deadline-aware decode pool** | One bounded pool across sources; chunk tasks only where the file contains independent chunks and the task is large enough. Small tasks run inline within the batch. No per-layer or nested decoder pools; verify DXV independently. Cache by requested media timestamp and seek generation. | **R1** |
| **C6** | **Sustained load and optional-work degradation** | >=60-minute R2 soak on the actual target chassis. Reduce optional previews, thumbnails and optional preparation/encoding first. Program sinks keep their target; unavoidable misses are measured and last valid frames retained. Do not promise zero misses under arbitrary thermal/load conditions. | **R2** |
| **C7** | **Measured UI budget** | Optional UI starts with <=10% of frame-interval GPU work; report tails and contention. Playing thumbnails default to 15 Hz/256 px, hidden views skip work, state changes redraw promptly. Master preview has its own budget. Defaults require validation, not a claim of imperceptibility. | **R3** |

**Additional scaffold contracts from the final Codex review:** parameter paths resolve to dense
IDs before playback; requested source frames are scheduled separately from nonblocking readiness;
seek generations reject stale completions; unchanged media timestamps reuse decode/upload work.
Linear working targets start at RGBA16Float, with precision validated; shader/UI/logging work is
budgeted separately. Warp meshes and calibration resources are cached until edited.
Details and primary sources: [V3-codex.md](V3-codex.md).

**The honest framing for Aiden:** C1–C5 are conventional realtime-engine work, not exotic bets. If
they land and Arena still matches us, then the honest pitch is *"comparable frame rate, far better
workflow — node graph, fixtures, modulation, mapping, remotes"*, and that's a good product.

### ✅ Aiden's answer (2026-10-12): accepted — *"but we want to push the boundaries of FPS wherever we can. Moore's law is also a thing though."*

**Decision recorded.** Comparable-with-better-workflow is an acceptable floor, **and maximising
throughput stays an active goal rather than a nice-to-have.** Two consequences, both architectural:

#### C8 — Scale with the machine, never hard-code for the M4

**Every performance constant must be derived at runtime from device capabilities, not compiled in.**
Decode worker count, frames in flight, texture pool size, cache budgets, tile dimensions, prefetch
depth — all of it. The tiers (§1.5) are a **floor on a base M4**, not a target; on an M4 Max or an
M6 the same build should automatically do far more without a recompile or a tuning pass.

This is the actual Moore's-law-proofing, and it costs almost nothing if done at R1: query core
counts, GPU family, memory size and bandwidth at startup, derive the budgets, log what was chosen.
A build tuned to constants that fit one machine leaves half of next year's machine idle — and
**that failure is silent**, which is what makes it worth preventing now rather than noticing later.

#### C9 — Put work where silicon is actually improving

Hardware does not improve uniformly, and the plan should lean into the fast axes:

| Improving fast | Roughly flat |
|---|---|
| GPU cores, GPU fill rate | **Single-thread CPU latency** (~10%/gen) |
| Memory bandwidth | Disk seek latency |
| **CPU core counts** | DMX512 (44 Hz, fixed forever) |
| NVMe sequential throughput | Display refresh in most projectors (60 Hz) |

So: **prefer parallel CPU work over serial, and GPU work over CPU work.** Concretely, this raises
the value of C5's HAP multi-chunk decode — core counts grow faster than single-core speed, so
frame-level parallelism compounds while per-core snappy throughput does not. It also means a design
bottlenecked on one serial thread ages badly even as the machine gets faster.

> **⚠️ The honest caveat on "push FPS": above the display's refresh, extra frames are discarded.**
> Most projectors are 60 Hz; high-refresh exists mainly on LED processors (Brompton to 240 Hz).
>
> **So headroom should be spent, not just measured** — converted into **more layers, higher
> composition resolution, more effects, more outputs**, which the operator actually sees. The right
> metric is therefore **work-per-frame at a locked output rate**, not peak FPS into a void.
>
> **Keep measuring uncapped throughput anyway** — it's the honest number for headroom, it's how we
> know whether an optimisation worked, and it's what tells us how far the machine can be pushed
> before the tiers degrade. Report both: tier pass/fail at the locked rate, and headroom above it.

**And the experiments get a home.** MTLIO, ICBs, tile shading and operator fusion were demoted off
the critical path because the 1080p spec doesn't need them. They stay live precisely as
**headroom plays** — the route to 4K, to 32 layers, to 240 Hz LED — evaluated on their own merits at
R4+, with failure changing nothing structural. That is the correct place for ambition: after the
floor is proven, not load-bearing underneath it.

---

## 3. Decide-now vs. measure-later

| Decide **now** (expensive to reverse) | Measure **later** (cheap to reverse) |
|---|---|
| Linear-light pipeline | MTLIO vs. conventional file I/O |
| Projective UV interpolation | ICBs vs. ordinary CPU encoding |
| Colour descriptor on every frame | Tile shading vs. register folding vs. ordered draws |
| `photon-core` has no Apple API (CI-enforced) | Operator fusion (H7) |
| Document schema + generated types | Cache sizes, prefetch depth, worker counts |
| State-sync-first control protocol, BLE-sized | Specialisation granularity (per-composition vs. per-tile) |
| Mapping stored separately from composition | Bicubic vs. bilinear slice sampling |
| Per-output presentation adapters | Whether H1's translation delta exists at all |
| Last-valid-frame-on-underrun; explicit blackout | Scissoring vs. per-tile variants on wide canvases |
| **Clock as tempo+phase authority, with tempo and phase as *separable* sources** (§2.4b2) | Beat-detection algorithm choice |
| **Modulation-binding model + parameter paths** | FFT band defaults, smoothing curves |
| **Rate-independent sinks** (so DMX can attach later without touching the render path) | Which DMX protocol, and when |

---

## 4. Benchmarking — rebuilt around Codex's finding

### 4.1 🔴 The feasibility check comes first, and it may kill the Arena comparison
Codex found that Resolume's published REST API exposes **no raw rendered-frame timing stream**.
Without one, frame-time percentiles against Arena cannot be derived from its API — and
**percentiles derived from a sampled average-FPS counter are not percentiles.**

> **Therefore P0 begins with a one-day measurement feasibility spike, not a harness build.**
> Determine what Arena actually exposes — supported trace, external observer, Instruments capture,
> or nothing. Document sampling precision and overhead. **If only average FPS is obtainable, report
> only average FPS**, and say so publicly rather than manufacturing precision we don't have.
>
> **Consequence:** the primary acceptance criterion becomes **Tier A/B/C pass-fail on target
> hardware**, which needs no Arena cooperation. Arena comparison is secondary and may be
> coarse-grained. Aiden should know this up front: *"we beat Resolume by X%" may not be a claim this
> project can honestly make* — but *"we hit 8 layers at 60fps on a base M4"* is.

### 4.2 Three workloads, measured separately (Codex)
Resident textures without decode · warm file-backed playback · sustained large-working-set streaming.
Shared-source and independently-timed-source cases both — reusing one frame across every layer
cannot establish independent-stream capacity.

### 4.3 Telemetry (Codex)
CPU preparation, GPU execution, presentation interval, decode lateness, repeated source frames,
output deadline misses, queue depth — **distinct metrics.** A GPU command duration is not the
interval between frames on a projector. Plus Claude's bottleneck labelling: every run tagged
GPU-bound / CPU-bound / disk-bound, and `DEV-BOX-INVALID` on anything from the M4 Max.

### 4.4 Fairness lock (Codex)
Source and output resolutions locked separately, source cadence, composition cadence, vsync, bit
depth, blend modes, opacity/occlusion, effects, previews/UI, output sinks, cache state, thermal
state, hardware decode. **Arena's Auto mode follows display refresh — confirm actual behaviour
before labelling any run "uncapped".**

### 4.5 Immediate blocker
**Installed ffmpeg cannot encode HAP** (no `--enable-libsnappy`) and exits 0 while failing. Rebuild
ffmpeg with snappy, or generate HAP another way, before any corpus work. Preflight must inspect
capabilities, never exit codes.

---

## 5. V1 scope and delivery staging

### 5.1 Delivery staging — adopted from `V2-codex.md` §7 (A5)

Supersedes V2-claude's P0–P8. Each stage closes on **evidence**, not on work being done.

| Stage | Deliverable | Closes on |
|---|---|---|
| **R0** | Contracts + decisions: Arena measurement route, fairness, frame/resource boundary, minimal document schema, **C1 QoS map** | Arena trace interpreted correctly; reviewable contracts; FFI/lifetime spike |
| **R1** | Vertical playback slice: one HAP layer, native window, transport, save/load, telemetry. **+C4 frames-in-flight, C5 decode model** | Correct output and cadence; bounded memory; graceful late/missing media |
| **R2** | Measured composition: layer sweep, **DXV adapter**, blend modes, transforms, dirty generations. **+C2 occlusion, C3 damage regions, C6 soak test** | Matches unfused reference; CPU/GPU/deadline distributions; **base-M4 tier results** |
| **R3** | First show workflow: clip/deck control, cues, recovery, physical output, Syphon, quad/grid warp, soft edge. **+C7 UI budget** | Sustained playback through cue changes and output/source disconnects |
| **R4** | Explicit I/O additions: NDI, capture, DeckLink, recording, virtual camera — in measured increments | Per-sink cost and supported limits reported |
| **R5** | Node product: graph + operators, then editor, then selective fusion | Graph correctness; measured fusion gains |
| **R6/R7** | Remotes: control service, WebRTC preview, web + iOS clients | Reconnect/state tests; measured preview interference |
| **R8** | *(cut per Aiden — UI templates instead)* | — |
| **W** | Windows product: platform adapters, renderer, shell consuming the released core | Shared document/command/blend fixtures pass |

**R3 is the release milestone** — the first Mac show workflow. Everything before it is the engine;
everything after it is reach.

⚠️ **Tier claims require DXV (A3).** R1's HAP-only slice de-risks fastest but cannot declare Tier
A/B/C. Those close at **R2**, with the DXV adapter present.

### 5.1b ⚠️ Naming — three different "V" scales are now colliding

They mean different things and must stop sharing notation:

| Scale | Notation | Meaning |
|---|---|---|
| **Proposal documents** | `V2-claude`, `V2-codex`, `V3-merged` | Review history. **Retire on adoption; stop incrementing.** |
| **Build stages** | **R0 … R8, W** | Engineering milestones (§5.1). What the agents work to. |
| **Product releases** | **Photon 1.0, 2.0, 3.0 …** | What ships to users. **This is what Aiden means by "v3 or v4".** |

**From here: "V3/V4" in Aiden's scheduling always means a *product release*.** Build work is
R-numbered; proposal numbering is frozen.

### 5.1c Release roadmap — deferrals recorded 2026-10-12

| Release | Lands |
|---|---|
| **1.0** *(= R3)* | 1080p HAP + **DXV read** playback at Tier A/B/C · 4–12 layer compositor, full blend set · Advanced Output at parity · Perform + Map personas, fixed UI templates · ~30 ISF effects · clip transport modes + playthrough types + trigger quantisation · **tap tempo + MIDI clock** · modulation system · MIDI learn + state push · save/load, cue transitions, recovery · physical output + Syphon |
| **2.0** | Explicitly-needed I/O adapters (NDI, capture, DeckLink, recording, virtual camera), measured one at a time *(R4)* |
| **3.0** | Sources + Effects node panes; **Ableton Link** *(Aiden, 2026-10-12: "for later")* *(R5)* |
| **3.0–4.0** | Remotes: control service, WebRTC preview, web + iOS clients *(R6/R7)* |
| **4.0–5.0** | **DXV *conversion*/encoding** — *"we can use Alley for DXV conversion until later"* (Aiden) · Pro DJ Link · DMX/sACN fixtures + the human-named fixture node library |
| **Later, unscheduled** | Windows *(W)* · moveable/dockable UI · MTLIO, ICBs, tile shading, operator fusion as **headroom experiments** (§2.9 C8/C9) |

**Note the asymmetry that matters:** DXV **read** is V1 and gates the tier claims (A3). DXV
**write** is 4.0–5.0, with **Alley covering conversion in the meantime** — which it genuinely does,
since that is exactly what Alley is for.

### 5.2 V1 scope

Smaller than `V2-claude.md` proposed, structured as Codex's §7 argues.

**V1 ships:** 1080p DXV/HAP playback hitting Tiers A/B/C on a base M4 · 4–12 layer compositor with
the full blend set · Advanced Output at parity (§3.2b checklist) · Perform + Map personas with fixed
UI templates · ~30 ISF effects · **clip transport modes (Timeline / BPM Sync / Frames) + playthrough
types + trigger quantisation** · **tap tempo + MIDI clock** · **the modulation system — audio
bands, beat-synced LFOs, envelopes, MIDI CC, OSC — bound to any parameter by path** · MIDI
learn-mode mapping with state push · save/load, device disconnect and cue transitions ·
last-valid-frame-on-underrun.

> The **modulation system is non-negotiable for V1** even though individual sources can follow:
> retrofitting it means rewriting every parameter in the app.

**Not V1:** node graph · Sources pane · MTLIO · ICBs · operator fusion · remotes · Windows · DXV
encoding · docking · **Art-Net/sACN pixel mapping** (demoted to a post-V1 compatibility feature per
§2.2b — real LED walls are driven as video outputs, which V1 already covers).

---

## 6. First scaffold and current frontend assignment

1. **`photon-core/`** — one portable Rust crate initially, with `doc`, `codec`, `graph`, `ir`,
   `clock`, `modulation`, `protocol` and platform-contract modules. Platform/FFI adapters are separate.
   Use a libavformat packet adapter rather than a new MOV parser. CI checks dependencies/builds for
   Apple coupling; split modules into crates when dependency/release boundaries justify it.
2. **`macos/`** — Swift package. Codex builds `PhotonApp` and `PhotonUI`: individual panels,
   controls, skeletons and local recovery. Claude supplies engine/render/FFI targets and is obtaining
   Xcode. The UI preview runs now; native media/render integration follows its existing milestones.
3. **`bench/`** — *starts with the §4.1 feasibility spike*, not the harness. Then corpus (after the
   ffmpeg fix), then analysis, then harness.
4. **`docs/`** — the single V4 `scaffold.md`, plus `bench-fairness.md`, `bench-cli.md`,
   `control-protocol.md`.
5. **Git:** commit and set a remote **before any formal run** — reproducible results need a pinned
   revision (Codex §1).

**First three tasks each**
*Claude:* `photon-core` skeleton + document schema v0 + the no-Apple-API CI check → packet/HAP adapter
with a test corpus → Metal bring-up with one quad and real telemetry.
*Codex:* native app shell and small components → independent loading/recovery states → provider and
GPU-surface integration with Claude. Benchmark execution is deferred by Aiden. See
[frontend.md](../../docs/frontend.md); this user-directed assignment supersedes the old bench-first role.

---

## 7. For Aiden — three things that need a decision

1. **The Arena comparison may not be honestly claimable** (§4.1). Is Tier A/B/C pass-fail on target
   hardware an acceptable primary success criterion, with Arena comparison as a soft secondary?
2. **MTLIO and the Photon-native format are now post-V1 experiments.** That means V1 plays HAP/DXV
   only and makes no "faster than DXV" claim. Confirm that's the right trade for shipping sooner.
3. **V1 scope (§5)** — anything in "not V1" you actually need in V1?

---

## 8. Status

- [x] Both V2s assessed; 18 Codex points adopted, 10 Claude points retained, 4 split decisions resolved
- [x] **Codex final review incorporated** — V3-codex.md
- [x] **Claude acknowledges the engineering amendments in docs/scaffold.md**
- [x] Aiden reports planning questions answered with Claude and authorises the frontend build
- [x] **V4 engineering agreement recorded; frontend construction started**

**On adoption: `V2-claude.md` and `V2-codex.md` move to `proposals/_retired/` the same hour.**
