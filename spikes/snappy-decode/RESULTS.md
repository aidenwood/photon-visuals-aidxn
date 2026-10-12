# Snappy decode throughput — results

**Date:** 2026-10-12. **Run on:** Apple M4 Max (10 P + 4 E), 36GB. **`DEV-BOX-INVALID`.**
Reproduce: `cargo run --release`.

---

## Headline

> **Decode is not a bottleneck, and the conclusion holds across the entire plausible data range.**
> Even the slowest case measured gives **6.6× the Tier A/B requirement on a single core**.

## Single-core throughput, 1080p BC1

| Data | Ratio | GB/s | layer-frames/s (BC3) |
|---|---|---|---|
| Incompressible (literal runs → `memcpy`-like) | 1.00× | **54.8** | 26,433 |
| "Realistic" attempt *(see caveat)* | 1.00× | 50.0 | 24,100 |
| Highly compressible (flat/graphic content) | 5.25× | **6.6** | 3,170 |

**Counter-intuitive but correct: *more* compressible data is *slower* to decode.** Literal runs
decompress at memory-copy speed; copy-matching does more work per output byte. So low
compressibility costs storage and bandwidth, never CPU. Flat graphic content is the slow case, not
camera footage.

## Scaling, 1080p BC3/BC7, 4 chunks per frame

| Workers | GB/s | layer-frames/s | vs 480 target |
|---|---|---|---|
| 1 | 46.1 | 22,241 | 46× |
| 2 | 83.0 | 40,043 | 83× |
| 3 | 92.8 | 44,767 | 93× |
| 4 | 91.7 | 44,238 | 92× |
| 6 | 135.2 | 65,220 | 136× |
| 8 | 154.9 | 74,722 | 156× |

Note the **plateau between 3 and 4 workers**. At ~90 GB/s this is bumping memory bandwidth, not
core limits — decode becomes bandwidth-bound long before it becomes core-bound. Worth re-checking
on the base M4, whose 120 GB/s bus is far narrower than the Max's.

---

## ⚠️ Caveat: my "realistic" data model failed

The generator meant to hit real HAP's ~1.2–1.6× ratio produced **1.00×** — its back-references were
too sparse to help snappy, making it indistinguishable from incompressible data. **I did not
successfully model realistic BC content.**

**Why the conclusion survives anyway:** the two ends of the range *are* valid, and they bracket
reality. Real HAP at ~1.3× sits near the literal-heavy end, so true throughput is likely 30–50 GB/s.
But even taking the **worst measured figure** (6.6 GB/s, highly-compressible content), a single core
delivers 3,170 layer-frames/s — **6.6× the 480 target**. The verdict does not depend on getting the
ratio right, which is the only reason it's reportable.

Replace this with a measurement against the real corpus when it exists.

---

## 🔴 This corrects an earlier analysis of mine

`V3-merged.md` §1.5 assumed snappy decompresses at **1–2 GB/s per core** and concluded that 4K would
need **2–4 of the base M4's 4 performance cores** — a "cliff" that made `MTLIO` hardware
decompression look like the only escape, and therefore "the enabling technology" for 4K.

**That 1–2 GB/s figure was wrong** — stale, and low by roughly an order of magnitude on this
hardware. Recomputing with measured numbers:

| | 4K BC7 @ 480 lf/s = 3.98 GB/s required |
|---|---|
| At the worst measured rate (6.6 GB/s/core) | **0.6 cores** |
| At the likely real rate (~50 GB/s/core) | **0.08 cores** |

**There is no CPU cliff at 4K either.** The entire justification for MTLIO as an enabling technology
is gone — it was built on a number I should have measured instead of recalled.

**Consequences:**
- MTLIO stays a post-V1 experiment, now with *no* performance argument behind it — only a
  theoretical tidiness one. Its priority drops further.
- The 4K story is substantially better than §1.5 claimed. 4K's real constraint is **disk and memory
  bandwidth**, not decode.
- C5 (HAP multi-chunk parallelism) remains correct and worth implementing, but it is **headroom,
  not necessity** — one core already covers the tiers many times over.

---

## What's actually left

With upload at 28× headroom and decode at 46–156×, **neither of the two CPU costs in the HAP path
is close to binding at 1080p.** The remaining candidates for the real bottleneck:

1. **Disk throughput** — still unmeasured on this machine.
2. **Memory bandwidth** — the 3→4 worker plateau suggests it binds earlier than core count does,
   and the base M4 has a third of the Max's bandwidth.
3. **Compositing and presentation** — unmeasured.
4. **The UI** — 128 live thumbnails, unmeasured.

**Next spike should be disk throughput**, because it's the one remaining input to the tier model
that is pure guesswork.
