# Photon — V5 context snapshot (R0 build findings)

**Date:** 2026-10-12. **Author:** Claude (engine). **Status:** record, not a plan.

> **This is NOT a competing proposal and does not supersede anything.**
> The build contract remains [`docs/scaffold.md`](../../docs/scaffold.md); the reasoning remains
> [`V3-merged.md`](../V3/V3-merged.md). V5 exists to capture **what was actually built, measured and
> disproven** during R0, so the next session doesn't re-derive it. Where a finding contradicts an
> earlier document, the contradiction is stated and the earlier doc has been corrected in place.

---

## 1. What exists and runs

| Artifact | State |
|---|---|
| `photon-core/` | Rust, **45 tests green**, portability guard passing + self-proving |
| `photon-core/ci/check-portable.sh` | 3 independent checks; **self-tests by injecting a `core-foundation` dep and confirming failure** |
| `photon-core/src/doc/` | `.photon` v0 — rational time, stable `Id`s, `ColorDescriptor`, transport/playthrough, blend modes, modulation bindings |
| `photon-core/src/codec/hap.rs` | HAP parser incl. multi-chunk Decode Instructions |
| `photon-core/src/codec/dxv.rs` | DXV parser, **verified against a real file** |
| `photon-core/src/budget.rs` | Six memory pools, all **derived from device caps at runtime** |
| `engine/` | Standalone SwiftPM package. **Runs: 32 layers @ 120fps, GPU 5.19ms, all 10 blend modes** |
| `spikes/metal-upload/` | BC upload path measured and verified correct |
| `spikes/snappy-decode/` | Decode throughput bracketed |
| `docs/thread-qos-map.md` | C1 thread/QoS contract |
| `docs/resolume-ui-reference.md` | Arena's UI model, extracted from its own XML — **for Codex** |

**R0 status: 5 of my 7 items done** (#2 core+CI, #3 schema, #4 QoS map, #6 upload spike, #8 budget).
Outstanding: #5 FFI spike, #10 runtime contracts review. #1/#7/#9 are Codex's.

---

## 2. 🔴 Claims that were disproven — corrected at source, listed here so they stay dead

| Claim | Reality | Where it came from |
|---|---|---|
| **Xcode blocks R1** | **False.** `MTLDevice.makeLibrary(source:)` compiles MSL at **runtime**; CLT is sufficient. Verified by building and running a Metal pipeline with no Xcode. Xcode is needed only for Instruments and shipping. | My own assertion |
| **Snappy runs at 1–2 GB/s per core** | **Wrong by ~an order of magnitude.** Measured 6.6 GB/s (highly compressible) to 54.8 GB/s (literal-heavy). | My §1.5 arithmetic |
| **4K has a CPU "cliff" needing 2–4 P-cores** | **No cliff exists.** 4K BC7 at 480 lf/s needs **0.08–0.6 cores**. | Followed from the above |
| **MTLIO is "the enabling technology" for 4K** | **Justification gone.** It was built entirely on the wrong snappy figure. Remains a post-V1 experiment with *no* performance argument behind it. | Followed from the above |
| **`MTLBuffer.makeTexture` gives zero-copy BC upload** | **API doesn't accept block-compressed formats.** | Caught by Codex |
| **Alley is the DXV conversion route** | **ffmpeg does DXV both directions.** No Alley, no GUI, no ffmpeg rebuild. | My answer, now corrected |
| **Snappy is the only CPU work in the playback path** | True for HAP. DXV uses a different scheme entirely. | Imprecise framing |
| **DXV uses LZF** | **False — DXV uses a codec-SPECIFIC LZ variant.** Proven by falsification: a stock LZF decoder fed a real DXV3 payload returns `InvalidData`. FFmpeg implements its own `dxv_decompress_*` routines. **DXV decode is therefore unimplemented and is real work, not a header parse.** | My own claim, same session |
| **More compressible data is slower to decompress** — *counter-intuitive but TRUE* | Literal runs decompress at `memcpy` speed; copy-matching does more work per output byte. Low compressibility costs storage, never CPU. | Measured |

---

## 3. ✅ Verified facts (measured on this machine, not assumed)

**GPU capability** — `supportsBCTextureCompression: true`, Apple family 7/8/9, **argument buffers
Tier 2**, unified memory, 28.7GB recommended working set. *This was an unexamined assumption under
the entire project*: DXV and HAP are BC blocks, and without BC support every frame would have
needed an ASTC transcode.

**BC upload** — `replaceRegion` on a shared-storage texture: **0.073 ms/frame, 13,713 layer-frames/s
at 1080p — 28× the 480 target.** Buffer→blit→private is 2.94× slower. Both verified correct by
sampling into `rgba16Float` and reading back exact values. **Upload is a non-problem; stop
optimising it.**

**Decode** — 6.6–54.8 GB/s single core depending on compressibility. Even the worst case is **6.6×
the target on one core**. Scaling plateaus between 3 and 4 workers at ~90 GB/s, which is memory
bandwidth, not cores.

**Compositor** — register fold holds **120fps at every layer count to 32**, GPU time linear at
~0.16 ms/layer (1.11ms @ 6, 2.96ms @ 16, 5.19ms @ 32). **32 layers × 120fps = 3,840 lf/s, 8× the
target.** All four destination-reading blend modes (Difference, Mask, Overlay, Hard Light) render —
the ones Metal's fixed-function blending cannot express at all.

> ⚠️ All of the above is `DEV-BOX-INVALID` (M4 Max, not base M4), and the compositor figures use
> **procedural layers — no decode, no upload, no texture sampling yet.**

---

## 4. 🔴 Format findings that change engineering decisions

### HAP vs DXV parallelism — they are not interchangeable
- **HAP** splits a frame into independently-compressed chunks with per-chunk compressor/size/offset
  tables. Several cores can decode **one frame**. Mixed compressors within a frame are legal.
- **DXV has no chunk table.** Single contiguous LZ stream, one worker start to finish.

**Consequence:** DXV decode parallelism exists only *across layers*. Fine at 4–12 layers, but a
single large DXV layer is bounded by one core and **the scheduler must not assume a frame can be
split.** Encoded as `Frame::is_parallel()` on both codecs, with tests.

### DXV layout (from FFmpeg's public decoder, verified against a real file)
```
31 54 58 44 | 04 | 00 | 00 | 00 | 59 33 01 00
 tag "1TXD"  ver  min  comp rsv   78,681 bytes
```
12-byte header: tag · version major (**stored +1**) · version minor · compression flag (non-zero =
raw) · reserved · payload size LE. Tags: `DXT1`→BC1, `DXT5`→BC3 (premultiplied), `YCG6`/`YG10`→BC3
YCoCg. Legacy form packs size in low 24 bits, flags in high 8.

> **⚠️ Tags are stored REVERSED on disk** — `"DXT1"` appears as bytes `1TXD`. Reading them
> little-endian yields the big-endian value of the ASCII. This bug was caught only because the test
> fixture used bytes from a real file; synthetic data would have hidden it until the first real clip.

### ffmpeg is the corpus generator, never the runtime path
`ffmpeg -c:v dxv` produces real DXV directly. But **its DXV decoder outputs RGBA — CPU-decoded**,
which destroys the GPU-blocks advantage. It is our corpus generator and reference decoder only;
playback demuxes the packet and extracts BC blocks itself.

---

## 5. 🎯 Findings for Codex (front end) — full detail in `docs/resolume-ui-reference.md`

Arena ships its **entire UI model as plain XML** in `default/Presets/`. No decompiler needed.

1. **`LayersAndClips` is ONE panel** — layer strip and clip grid share a panel and scroll together.
   The single most important detail for "copy Resolume", and the easiest to build wrong.
2. Layout is a nested **`FlexContainer`** tree with `orientation` + `*_desired` sizes and stable
   integer `panel_id`s — **identical in shape to the declarative struct tree we specified
   independently.**
3. **Arena ships nine named layouts** — direct proof that templates-not-docking is sufficient for a
   professional tool in this exact category.
4. **🔴 Arena's parameters carry THREE ranges** — `defaultRange` (natural), `minMax` (user-narrowed),
   `startStop` (animation sweep within). Ours has only depth/offset/curve. **Retrofitting ranges
   touches every parameter in the app — decide before the parameter system is written.**
5. Durations serialise as beat literals (`"4b"`); phase source is **per-parameter** with a
   `hardSynced` flag — corroborating and extending our separable tempo/phase decision.
6. Arena ships **Pioneer DJ TCNet** and **Denon DJ StageLinQ** toggles — the category's real answer
   to the rekordbox phase problem is a dedicated DJ-link integration, not Ableton Link alone.

---

## 6. Two Metal bugs worth not repeating

1. **Assigning `layer = CAMetalLayer()` after `wantsLayer = true` is not honoured.** AppKit owns
   backing-layer creation; it must come from `makeBackingLayer()`.
2. **`CAMetalDisplayLink` hands you a drawable in its update.** Calling `nextDrawable()` yourself
   instead leaves the window black.

---

## 7. Tooling state

- **REA is healthy**: Ghidra 12.1.4 + `node@22` (22.23.3) + JDK 21, all **keg-only — the default
  `node` is untouched**. `GHIDRA_INSTALL_DIR=/opt/homebrew/opt/ghidra/libexec`, `JAVA_HOME` set.
  Helper: `/tmp/rea-env.sh`.
- Ghidra **cannot import universal Mach-O** — thin first: `lipo -thin arm64`. Arena arm64 slice is
  54MB at `/tmp/rea-work/Arena.arm64`; headless analysis was running at time of writing.
- **REA was not what solved the front end.** Arena ships readable XML, which beat disassembly on
  both speed and authority. REA's value is the parts genuinely locked in the binary.
- `ffmpeg` cannot encode **HAP** (no `--enable-libsnappy`) and **exits 0 while failing** — preflight
  must inspect capabilities, never exit codes. DXV is unaffected.

---

## 8. Next

**Engine:** HAP end-to-end first (snappy is a solved, available crate), then DXV once §9 is decided.
Then FFI spike (#5).

---

## 9. 🔴 OPEN FOR AIDEN — DXV decode has a licensing question

DXV's decompressor is a codec-specific LZ variant. The only public implementation is FFmpeg's
`libavcodec/dxv.c`, which is **LGPL**. Photon is intended as a commercial product, so:

- **Linking FFmpeg dynamically is fine under LGPL** — but FFmpeg's DXV decoder outputs **RGBA**
  (CPU-decoded), which destroys the GPU-blocks advantage. It does not solve the playback path.
- **A line-by-line port into our Rust core would be a derivative work** of LGPL code, which
  conflicts with shipping `photon-core` closed.
- **A clean-room reimplementation from the format's behaviour** is the standard route and is what
  interop work normally does — more effort, no licence entanglement.

**This is Aiden's call, not an engineering one.** Until it's decided, DXV stays parse-only.
HAP is unaffected — snappy is available as a permissively-licensed crate and HAP's own spec is
published, so HAP can go end-to-end now.

⚠️ Reminder: **tier claims require DXV** (correction A3). So this decision gates tier verification,
not the walking skeleton.
**Open to Codex:** the shape of `ProgramSurfaceFactory`, so `engine/` builds to it rather than
guessing. Asked in `CODEX-HANDOVER.md` §5b.

---

# ⏰ Overnight addendum — 2026-10-12 → 13

Full narrative in [`NIGHT-LOG.md`](../../NIGHT-LOG.md). This section carries only what changes
decisions. **Read this before resuming.**

## What now exists and is verified

| Artifact | State |
|---|---|
| `photon-core` | **226 tests**, 0 clippy warnings, portable (incl. `wasm32`). Modules: doc, codec (HAP+DXV), clock, modulation, graph, ir, protocol, budget, platform |
| `photon-ffi` | **NEW.** C ABI bridge, **the only crate permitted `unsafe`**. 11 tests. |
| `engine/` | Compositor · VideoSource · **OutputStage (warp)** · **Warp** · **Transport** · **ThumbnailCache** · **OutputTopology** · Engine facade |
| `PhotonVerify` | **47 GPU checks**, all passing. `cd engine && swift run -c release PhotonVerify` |
| `macos` app | Builds and runs; preview monitor shows **real Trees Have Eyes media** |

## 🔴 Findings that change decisions

**1. DXV compression is CRACKED for DXT1 — but your library is DXT5.**
Derived clean-room (FFmpeg's source never opened), verified byte-exact on 119 frames / 44 files,
and validated bidirectionally. **But a tag census of the real library returned 56 × DXT5, 2 × YG10,
0 × DXT1.** So the solved path covers none of Aiden's actual media. DXT5 is *the* blocker, and an
agent is now on it with the 56 real samples it previously lacked.

**2. XCTest requires full Xcode.** This corrects an earlier claim that Xcode was needed only for
Instruments and shipping. `PhotonVerify` is therefore an **executable**, which works on Command Line
Tools and suits CI better.

**3. The FFI boundary is free — 6.4 ns/frame, flat from 1 to 32 layers.** Measured Swift→Rust, not
extrapolated. It is not a performance consideration; any future debate about it is about safety and
ergonomics only.

**4. One colour convention, enforced:** shaders emit **linear**, the target is an **`_srgb` format**,
the hardware encodes. The hand-rolled sRGB encode was deleted rather than left as a second
convention. This also makes projector-overlap blending happen in linear space — verified: a
2-projector soft edge matches a single-projector reference to within 6/255.

**5. 🔶 Deviation from the scaffold:** hand-written C ABI instead of `swift-bridge` (R0 #5 named
swift-bridge as default). Reasoning in `photon-ffi/FINDINGS.md`. Reversible.

**6. FFI is NOT yet linked into the app.** Linking the staticlib needs `macos/Package.swift`, which
Codex owns, and SwiftPM rejects `unsafeFlags` for non-root packages. Ticketed to him
(`CODEX-HANDOVER.md` §5b⑥) rather than risking his build.

## Bugs the verifier caught that review would not have

Written down because they argue for keeping `PhotonVerify` in the loop:
- **No sRGB encode was happening at all** — 0.25 linear rendered as 64 instead of ~137.
- **Test-pattern line widths were resolution-dependent** — sub-pixel at preview size, fat at 4K. Now
  derived from screen-space derivatives, so ~1px at any resolution.
- Two of my own test expectations were simply wrong (corner convention; a vertical flip in the warp
  stage). Worth noting that *tests being wrong* is itself a failure mode.

And from the workflow's adversarial pass on `clock.rs`: **a rejected downbeat correction still
permanently rotated the bar**, reporting "Rejected" while having already changed which beat is "1".
The author's 58 tests plus 24 injected mutations missed it. **One agent's own tests are not a
substitute for an independent adversarial pass.**
