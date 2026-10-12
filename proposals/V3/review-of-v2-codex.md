# Claude's review of `V2-codex.md`

**Reviewer:** Claude. **Date:** 2026-10-12. **Reviewed:** `V2-codex.md` @ 597 lines (post-expansion).
**Scope requested by Aiden:** performance improvements.

**Summary:** the updated V2-codex is stronger than the version I adjudicated in V3 — §7's staged
R0–R8 release plan is better than V3's phase list and should replace it. It corrects me on three
further points beyond the 18 already accepted. **Its remaining weakness is unchanged: it is a
superb method with no positive performance plan.** Seven concrete gaps below, in impact order;
three of them are gaps in *my* documents too and I've flagged which.

---

## A. Three more corrections I accept

**A1. Browsers don't do HEVC over WebRTC.** V3 §3.2/V2-claude proposed "hardware-encoded H.265
preview" to the web remote. Per RFC 7742 the WebRTC baseline is **VP8 and H.264**. My preview
transport was wrong. ✅ Adopt: WebRTC with H.264 as the interoperability target, negotiate newer
codecs where supported, keep NDI as a separate native adapter.

**A2. Browsers can't enumerate Bonjour.** V2-claude §3.1 assumed mDNS discovery for the *web* remote.
Wrong — mDNS is right for native clients only. ✅ Adopt: engine-displayed URL + QR code, manual
address fallback, mDNS for native clients.

**A3. A HAP-only prototype can't claim the tiers.** The spec is stated in **DXV**; my
`scaffold-v1.md` Milestone 0 is HAP-only. Codex is right that tier pass/fail cannot be declared
without DXV3/DXV4. ✅ Adopt: Milestone 0 stays HAP (it de-risks faster), but **no tier claim is valid
until the DXV adapter lands.** I'll amend the scaffold's "done when" accordingly.

**A4 (partial).** Codex pushes back on "the grid must be custom Metal widgets" and is right that
**128 clip slots ≠ 128 decoders** — static thumbnails for idle clips, ready source textures for
playing ones. I over-specified. ✅ Adopt his framing: one *bounded shared* Metal thumbnail surface,
ordinary SwiftUI/AppKit for controls, and measure before deciding anything else must be custom.

**Also adopted:** §7's R0–R8 staging with per-stage acceptance evidence — better than V3 §4's phases.
V3 should take it wholesale. And "defer CBOR until measured load time justifies it" over my
JSON+CBOR dual format.

---

## B. The structural gap

> **V2-codex demotes every performance mechanism and proposes none.**

H1 (translation tax), H2 (UMA upload), H3 (tile shading), H5 (MTLIO), H6 (ICBs), H7 (fusion) are all
correctly moved to "measure first" — and I accepted every one of those demotions in V3. But the
document never answers the resulting question: **by what mechanism is Photon fast?**

"Measure, then choose" is a method for *validating* a performance idea. It cannot *generate* one.
§9's success criteria ("correctly rendered, reliably paced frames… publish higher FPS when a
controlled comparison demonstrates it") is a definition of *not being slow*, not a plan for being
fast.

That's defensible if the honest answer is "Photon won't be meaningfully faster than Arena, and the
node graph plus the workflow is the product" — and §9 nearly says this. **If that's the position, it
should be stated plainly to Aiden as a recommendation**, because it changes the project's pitch and
he's entitled to decide it deliberately rather than discover it. V3 §5.1 raises the same point from
the benchmarking angle; this is the design-side half of it.

The gaps in §C are offered as the missing positive plan — none of them require an unproven API.

---

## C. Seven performance gaps

### C1. 🔴 No QoS / core-affinity plan — biggest gap, and it's free
*(Gap in both documents. Mine too.)*

The target is **4 performance + 6 efficiency cores**. E-cores run at a fraction of P-core throughput.
A snappy decode worker scheduled onto an E-core **will miss its deadline**, and on macOS that is
decided by **QoS class**, not by thread count.

Nothing in either document mentions QoS. Yet:
- Decode workers must be `.userInitiated` or `.userInteractive` to be eligible for P-cores.
- The render thread needs realtime-adjacent priority and must never share a queue with decode.
- The audio capture thread (V3 §2.4d) is genuinely realtime and must not be starved by decode.
- `.utility`/`.background` work (thumbnail generation, transcode, prefetch, telemetry writes) must be
  explicitly demoted so it lands on E-cores — which is a *benefit*, not a problem, if deliberate.

**This is close to free to get right and expensive to diagnose later** — symptoms are intermittent
frame drops under load that don't reproduce on the M4 Max dev box (16 P-cores, no contention).
**Recommend: an explicit thread/QoS map in R0, and a bench run that deliberately misassigns QoS to
demonstrate the delta.**

### C2. 🔴 No occlusion culling
*(Gap in both.)*

Register folding (V3 §1.3) samples **every layer at every pixel**. But a layer that is
`blend=over`, `opacity=1.0`, fully covering the slice, makes **every layer beneath it dead work**.

In real VJ use a full-frame opaque base layer is extremely common. A cheap cook-time check —
"topmost fully-opaque covering layer" — truncates the fold stack at that index. For a 12-layer
composition with an opaque layer at index 4, that's **8 layers of sampling eliminated**, far more
than tile shading was ever going to save (V3 §1.2 estimated H3 at ~3%).

Extends naturally to *partial* coverage via the per-tile binning already proposed for wide canvases
(V2-claude §1.5): a tile only folds the layers whose bounds intersect it **and** that aren't occluded
within it. **Recommend: cook-time occlusion truncation in R2, measured against the unfused reference.**

### C3. 🔴 Dirty tracking is temporal only — no spatial/damage regions
*(Gap in both.)*

Both documents handle *temporal* dirtiness (H4, dirty generations): a node that didn't change doesn't
re-cook. Neither handles **spatial** dirtiness: if 2 of 12 layers changed and they occupy 20% of the
canvas, **80% of the composite is recomputed identically every frame.**

Damage-region compositing — union the dirty layers' bounds, scissor the composite to it, reuse the
previous target elsewhere — is a large win precisely in the static-heavy case the tiers care about,
and it's the same insight as H4 applied to the X/Y axes instead of time.

**Caveat:** it interacts badly with full-frame effects and feedback, so the planner must disable it
when any full-canvas-dependency node is present. **Recommend: evaluate in R2 alongside dirty
generations, since they share machinery.**

### C4. No frames-in-flight or GPU/CPU sync model
V2-codex correctly specifies `CAMetalDisplayLink` and per-output presentation adapters. Neither
document specifies **how many frames are in flight**, double vs. triple buffering, or the sync
primitive (`MTLSharedEvent` vs. a dispatch semaphore).

This directly determines whether 120fps is smooth or stutters, and it constrains the texture pool
size — so it's a prerequisite for the memory budgets §4 asks for, not a detail. **Recommend:
decide in R1; it's cheap then and invasive later.**

### C5. Decode concurrency has a principle but no model
"Cap worker concurrency and avoid multiplying per-decoder thread pools" is right but isn't a plan.
What's missing: how many decode threads for 12 layers on 4 P-cores, how a frame is chunked, and how
decode interacts with the realtime audio thread.

**The specific mechanism neither document names: HAP deliberately splits each frame into several
independent snappy streams so multiple cores can decode one frame in parallel.** That's what makes
decode scale across a 4-core budget instead of being stuck at one-core-per-layer, and DXV's chunking
should be checked for the same property. **Recommend: a decode scheduling model in R1 — one bounded
pool, work-stealing across layers *and* within a frame's chunks, never a pool per layer.**

### C6. No sustained-thermal plan
§6 lists thermal state in the fairness lock — good — but neither document plans for it. A base M4
may be in a **fanless MacBook Air**, and a 10-minute benchmark does not predict a 3-hour set.

**Recommend: a sustained soak test (60+ min) in R2 reporting frame drops over time and clock
throttling, plus a defined graceful-degradation policy** (drop preview rate first, then thumbnail
rate, then NDI encode — never program output). "Which thing degrades first" is a product decision
and should be made deliberately.

### C7. Preview and UI cost is bounded but not budgeted
§7's thumbnail framing is right and better than mine (A4). It stops short of a **number**: thumbnail
surface refresh rate (10–15fps is plenty and invisible), resolution cap, and the rule that thumbnails
and preview are **skipped entirely when their pane isn't visible** — which the persona model makes
easy, since only one persona is on screen at a time.

**Recommend: fold into C6's degradation ladder and give it an explicit frame-budget allocation**
(e.g. ≤10% of frame time) that the telemetry reports against.

---

## D. Proposed disposition

| | |
|---|---|
| **V3 adopts from this review** | A1–A4, §7's R0–R8 staging replacing V3 §4, CBOR deferral |
| **V3 adds as the positive performance plan** | C1 (QoS map, R0) · C2 (occlusion, R2) · C3 (damage regions, R2) · C4 (frames in flight, R1) · C5 (decode model + HAP chunk parallelism, R1) · C6 (soak test + degradation ladder, R2) · C7 (UI budget) |
| **Needs Aiden** | §B — if the honest position is "comparable to Arena, better workflow", say so now |

**None of C1–C7 depend on an unproven API.** They're conventional realtime-engine work, which is
exactly the kind of positive performance plan V2-codex's method is designed to validate. They're
offered in that spirit, not as a counter-argument to it.

— from the Photon/Claude agent
