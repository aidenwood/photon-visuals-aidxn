# Photon

A realtime media server and projection-mapping engine for macOS. Resolume Arena's clip/deck/
compositor model, fused with the parts of TouchDesigner that make it fast.

**Status:** engine substantially built and verified; native UI under construction. Not yet a usable
product. See [`NIGHT-LOG.md`](NIGHT-LOG.md) for what landed and when, and
[`PLAN.md`](PLAN.md) for current state.

---

## Run it

```bash
# Engine demo — test patterns, keystone, multi-projector rigs, effects
cd engine && swift run -c release PhotonEngineDemo

# The app (SwiftUI shell + engine-backed preview)
./script/build_and_run.sh

# Verification: 88 GPU checks that render real frames and read pixels back
cd engine && swift run -c release PhotonVerify

# Rust core
cd photon-core && cargo test && ./ci/check-portable.sh
cd photon-ffi  && cargo test
```

> The demo must be launched from a **GUI session**. From a background shell macOS throttles the
> display link and it renders invisibly.

**No Xcode required.** Metal shaders compile at runtime via `MTLDevice.makeLibrary(source:)`, which
is the architecture anyway — the compositor is *generated* per blend-mode stack. Xcode is needed
only for Instruments, XCTest, and shipping.

---

## Layout

```
photon-core/     Rust. Portable: NO Apple API, NO graphics API. 237 tests.
                 doc (.photon schema) · codec (HAP/DXV) · clock · modulation
                 graph · ir (MSL+WGSL emitters) · protocol · budget · platform traits
photon-ffi/      Rust. The ONLY crate permitted `unsafe`. C ABI, staticlib.
engine/          Swift + Metal. Compositor · warp output · effects · transport
                 · audio · MIDI · thumbnails · topology. 88 GPU checks.
macos/           The app. SwiftUI shell (Codex) + engine render surface (Claude).
spikes/          Throwaway experiments with their own RESULTS.md.
docs/            scaffold.md (build agreement) · thread-qos-map.md · resolume-ui-reference.md
proposals/       Design history. V5-context.md is the "read before resuming" doc.
media-cache/     Dev media, transcoded. Not source of truth, safe to delete.
```

---

## The decisions that shape everything

Full reasoning in [`proposals/V3/V3-merged.md`](proposals/V3/V3-merged.md). The ones that constrain
day-to-day work:

**No Apple API in `photon-core`, ever.** Platform capabilities sit behind Rust traits implemented
per shell. Enforced by `ci/check-portable.sh`, which checks the resolved dependency graph (catching
renamed crates), source-level FFI, *and* a `wasm32` build — and **self-tests by injecting a
violation and confirming it fails**. Breaking this turns the later Windows port into a rewrite,
quietly, months before anyone notices.

**Linear light everywhere; the hardware encodes.** Shaders emit linear, targets are `_srgb`
formats. There is no hand-rolled sRGB conversion. This is why a two-projector soft edge blends
seamlessly — in gamma space the overlap band lands at ~0.44 of correct brightness, a dark stripe
down the middle of the screen.

**Projective (homography) UV interpolation for warps.** A keystoned quad drawn with ordinary
2-component UVs bends the texture along the triangle diagonal. The mesh carries `uvq` and the
fragment divides by `q`.

**Register folding, not fixed-function blending.** Mask and Difference must read the accumulated
destination, which Metal's fixed-function blending cannot express. The whole stack folds in one
fragment shader. Layers *with effects* break out, materialise, and rejoin as ordinary textures —
the hybrid compositor.

**A projector is a rectangle inside an output canvas, not "a display."** An M4 drives 4 external
displays; a 16-projector show runs through hardware splitters. Model a projector as a display and
that rig is impossible.

**Cross the FFI once per frame, never per layer.** One call returns a pointer to N contiguous
structs. Measured at **6.4 ns/frame, flat from 1 to 32 layers**.

---

## Verification

`PhotonVerify` renders real frames and reads pixels back, because "it compiled" and "it didn't
crash" are not evidence a renderer works — a wrong blend, a bad vertex layout, or an entirely black
frame all build and run perfectly.

It has repeatedly earned its keep, catching: no sRGB encode happening at all; resolution-dependent
test-pattern line widths; a segfault from reading a `.private` texture; and a two-minute hang from
a microphone permission prompt inside code written to "fail soft".

**It has also caught three of my own tests being wrong** — which is its own failure mode, and worth
remembering before trusting a green suite.

---

## Who owns what

| | |
|---|---|
| **Claude** | `photon-core/`, `photon-ffi/`, `engine/`, `macos/Sources/PhotonRenderSurface/` |
| **Codex** | `macos/Sources/PhotonApp/`, `macos/Sources/PhotonUI/`, `bench/` |

Neither edits the other's tree without a ticket in [`CODEX-HANDOVER.md`](CODEX-HANDOVER.md).

---

## Known gaps

- **DXV DXT5 decode.** DXT1 is cracked and verified byte-exact, but a census of the real library
  found 56 × DXT5, 2 × YG10, **0 × DXT1** — so the solved path covers none of the actual media.
  This is the single thing between the engine and real content.
- **ISF effects.** Six native MSL effects prove the chain; ISF (GLSL + JSON) is the plan, and needs
  the GLSL→MSL translation layer.
- **Syphon / NDI / DMX output.** Designed for (sinks are rate-independent); not implemented.
- **The UI.** Under construction.
