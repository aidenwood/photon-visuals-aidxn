# R0 #6 — BC compressed-texture upload path: results

**Date:** 2026-10-12. **Run on:** Apple M4 Max, 36GB. **`DEV-BOX-INVALID`** — not the base-M4
acceptance machine. Reproduce with `swiftc -O upload.swift -o upload && ./upload`.

---

## Capability check (ran first, because everything rested on it)

```
supportsBCTextureCompression : true
GPU families apple7/8/9      : true
argumentBuffersSupport       : Tier 2
hasUnifiedMemory             : true
recommendedMaxWorkingSetSize : 28753 MB
```

**This was an unexamined assumption underneath the entire plan.** DXV and HAP store BC blocks; if
Apple Silicon didn't expose BC we'd have needed a transcode to ASTC on every frame, which would
have changed the project's shape completely. It does. Argument buffers at **Tier 2** also confirms
the §3.5.3 compositor design (argument-buffer arrays of individual texture references) is available.

> Still to confirm on the **base M4** — same GPU generation, so expected, but "expected" is not
> "measured" and the tiers are defined on that machine.

## Upload paths

1080p BC1, 1,036,800 B/frame, 240 iterations.

| Path | ms/frame | GB/s | layer-frames/s | Correct? |
|---|---|---|---|---|
| **A — shared texture + `replaceRegion`** | **0.073** | **14.22** | **13,713** | ✅ exact |
| B — shared buffer → blit → private texture | 0.215 | 4.83 | 4,657 | ✅ exact |

**A is 2.94× faster and is the recommended path.**

### Correctness method
A BC1 block with `colour0 == colour1 == 0xF800` and zero indices encodes solid pure red, so the
expected sampled value is exact rather than approximate. The texture is sampled through a render
pipeline into an **`rgba16Float` linear target** — the real working format — and read back. Both
paths returned `(1.000, 0.000, 0.000)`. A silently-wrong upload (wrong row stride, wrong block
layout, wrong format) could not have produced that.

---

## What this means

**Upload is not a bottleneck, and it is not close to being one.** Tier A/B need **480
layer-frames/sec**; path A delivers **13,713** on this machine — **28× headroom**. Even assuming
the base M4 manages a third of this (120 GB/s vs. the Max's much wider bus), that is still ~9×.

**H2 is effectively closed.** The hypothesis was that unified memory could remove an upload cost
via a zero-copy buffer→texture alias. That route doesn't exist for block-compressed formats — and
it no longer matters, because the *supported* path is already 28× faster than the spec requires.
**There is nothing to optimise here.** Any further effort on upload would be work spent on a
non-problem, which is exactly what this spike existed to determine.

**The remaining CPU question is decode, not upload.** Snappy is the only CPU work in the HAP path,
and it is still unmeasured.

---

## Caveats — stated so these numbers aren't over-read

1. **`DEV-BOX-INVALID`.** M4 Max, not the base M4 the tiers are defined on.
2. **Path B's figure includes a full command-buffer round trip per iteration**
   (`commit` + `waitUntilCompleted`). Production would batch blits into the frame's existing
   command buffer, so B's real cost is lower than measured. A's advantage is real but likely
   smaller than 2.94× in context. *This does not change the conclusion — both paths clear the
   target by an order of magnitude.*
3. **Synthetic data.** Every block is identical, which is friendlier to cache than real
   snappy-decompressed output. Re-measure against the real corpus when it exists.
4. **Upload only.** No demux, no decompression, no compositing.

---

## Decisions this settles

- ✅ **Use `replaceRegion` on a shared-storage texture** as the default upload path.
- ✅ **Stop pursuing zero-copy BC upload.** It is unavailable and unnecessary.
- ✅ **BC formats and Tier 2 argument buffers are available** — §3.5.3's compositor design stands.
- ⏭ **Next measurement that matters: snappy decode throughput on 4 performance cores**, since that
  is now the only CPU work left in the playback path.
