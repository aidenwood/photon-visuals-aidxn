# Thread and QoS map — R0 #4

**Owner:** Claude (engine). **Status:** draft for Codex review. **Date:** 2026-10-12.
Implements **C1** from `V3-merged.md` §2.9, with the correction Codex supplied.

---

## The correction that shapes this document

My original C1 said decode workers must be `.userInitiated` "to land on P-cores". **That was wrong.**

> **macOS QoS is a scheduler *hint*, not core affinity.** Apple Silicon exposes **no public API to
> pin a thread to a performance core.** `thread_policy_set` affinity tags are a no-op there. QoS
> influences scheduling decisions — placement, timeslice, frequency — but guarantees nothing.

So this map specifies **priority and deadline roles**, and treats placement as something to
*measure*, never to assume. Worker counts are **derived and compared empirically** (2/3/4 on the
base M4 at R1), not fixed by a core-count formula.

---

## Target hardware

Base M4: **4 performance + 6 efficiency cores**, 10 GPU cores, 120 GB/s. Dev box is an M4 Max with
~4× the P-cores — **it will not reproduce contention**, which is exactly why QoS bugs found here
are invisible there.

---

## The map

| Thread / pool | QoS | Role | Rules |
|---|---|---|---|
| **Presentation** | `.userInteractive` | Drives `CAMetalDisplayLink`, encodes and submits the frame | Never blocks. No file I/O, no shader compilation, no `waitUntilCompleted`, no lock shared with decode. One per output, each with its own deadline. |
| **Decode pool** | `.userInitiated` | snappy/BC block decode for *playing* clips | **One bounded pool**, not one per layer. Start at 2 workers; compare 2/3/4 at R1. Work-stealing across layers *and* across a frame's independent HAP chunks. |
| **Audio capture** | OS-owned realtime callback | Device callback → preallocated block → ring | **Never allocates, never locks, never logs.** Publishes to the analysis worker; does no FFT itself. |
| **Audio analysis** | `.userInitiated` | FFT, band envelopes | Reused FFT setup and scratch. Publishes a lock-free snapshot the render thread samples once per frame. |
| **Prefetch** | `.utility` | Read-ahead for *armed/cued* clips | Distinct from decode: **active playback prefetch is `.userInitiated`; speculative preparation is `.utility`.** Cancellable, and cancelled on cue change. |
| **Thumbnails** | `.utility` | Idle-clip thumbnails for the grid | Idle clips use static/precomputed thumbnails; playing clips reuse the already-decoded source texture. Skipped entirely when the pane is not visible. |
| **Transcode / export** | `.background` | Media conversion, recording finalisation | Deliberately demoted so it lands on E-cores. Must never contend with playback. |
| **Telemetry writer** | `.utility` | Drains the event ring to CSV | Fixed-capacity ring; background writes. **Overflow invalidates the measurement** — it is never reported as zero drops. |
| **Control / network** | `.utility` | WebSocket, OSC, MIDI I/O | MIDI *output* (pad state) is latency-sensitive but low-volume; it must not sit behind a bulk telemetry write. |

---

## Rules that matter more than the table

1. **Never share a lock between the presentation thread and anything `.utility` or lower.**
   Priority inversion on a contended lock is the classic realtime failure, and macOS's donation
   only helps when the OS can see the dependency. Use lock-free snapshots across QoS boundaries.
2. **Separate active prefetch from speculative preparation.** They have genuinely different
   urgency, and lumping both into one `.utility` pool starves playback on a cue change.
3. **Decode work and telemetry never hold up presentation.** If a frame isn't ready, the previous
   frame is held and the repeat is *counted* — the render thread does not wait.
4. **Everything degrades before program output does.** Ladder, in order: preview rate → thumbnail
   rate → NDI encode → **never the program.**
5. **Worker counts are derived at runtime, never compiled in.** See C8 — a build tuned to constants
   that suit an M4 leaves half of an M6 idle, and that failure is silent.

---

## What R1 must measure

- Frame-time distribution at 2, 3 and 4 decode workers on the **base M4** — pick empirically.
- Whether `.utility` thumbnail work measurably perturbs presentation under a 12-layer load.
- Whether audio analysis latency affects beat-locked visuals at the tiers.
- **A deliberate QoS misassignment run** (decode at `.utility`) to demonstrate the delta. If there
  is no measurable difference, this document is over-engineered and should be cut — which is a
  result worth having rather than an assumption worth keeping.

---

## Open for Codex
1. Does the prefetch/preparation split match what §3b intends by "active prefetch separated from
   optional preparation"?
2. Should MIDI output have its own `.userInitiated` path given pad-state latency is visible to a
   performer, or is `.utility` sufficient at its message volume?
3. Is a deliberate-misassignment run worth harness support, or is it a one-off manual check?
