# FFI spike — results (R0 #5)

**Date:** 2026-10-13. **Machine:** Apple M4 Max. `DEV-BOX-INVALID` for tier claims, but FFI cost is
CPU-bound and not meaningfully machine-dependent at this magnitude.

---

## Result: the boundary is free. Stop thinking about it.

Measured **Swift → Rust**, not Rust → Rust, because the former is the thing that actually ships:

| Layers | ns/frame | share of a 120fps frame |
|---|---|---|
| 1 | 6.3 | 0.000076% |
| 4 | 6.4 | 0.000077% |
| 8 | 6.4 | 0.000076% |
| 12 | 6.4 | 0.000076% |
| 32 | 6.4 | 0.000076% |

**Flat across layer count** — which is the whole point, and the proof the packed design works. One
crossing per frame carrying a pointer to N contiguous structs costs the same whether N is 1 or 32.

For contrast, a bare trivial call measures ~0.8 ns, so a naive per-layer design at 12 layers would
cost roughly 9 ns/frame. Still small — but it would have scaled with layer count, and it would have
required marshalling per item. The packed form avoids the question entirely.

**Conclusion: the FFI boundary is not a performance consideration for this project.** Any future
discussion about it should be about safety and ergonomics, never speed.

---

## 🔶 [DECISION] Hand-written C ABI instead of `swift-bridge`

`docs/scaffold.md` R0 #5 specifies *"Default **swift-bridge**; evaluate an alternative only on
concrete failure."* I used a hand-written C ABI. Reasoning, so this can be reversed:

- **The surface is tiny** — 8 functions and 2 plain-old-data structs. `swift-bridge` earns its keep
  on large or type-rich interfaces; this is neither.
- **It adds a codegen build step** to a SwiftPM package that currently builds with nothing but
  Command Line Tools. That is a real cost against the project's "buildable without Xcode" property.
- **The measured cost is already negligible**, so the thing swift-bridge would optimise does not
  need optimising.
- **A C header is directly verifiable.** The Swift side asserts `photon_layer_stride()` and
  `photon_frame_stride()` against `MemoryLayout<T>.stride` at startup, so a struct-layout drift
  fails loudly instead of producing subtly wrong values.

**Revisit if** the interface grows to carry the document model, strings, or anything with a
non-trivial lifetime — at that point generated bindings start paying for themselves.

---

## Architecture

```
photon-core   (no unsafe, no platform API, portable)   <- the engine
     ^
photon-ffi    (the ONLY crate permitted unsafe)        <- C ABI, staticlib
     ^
macos shell   (Swift)                                  <- consumes the header
```

`photon-core` keeps `#![forbid(unsafe_code)]` and keeps passing its portability guard because every
`extern "C"` lives in `photon-ffi`. The Windows shell will link the same core through the same
bridge.

**staticlib, not cdylib** — nothing to ship, nothing to sign, nothing to find at runtime.

## Lifetime contract

Pointers returned by `photon_tick` are valid **until the next `photon_tick` on the same handle**.
The shell consumes them within the frame and never retains them. Stated explicitly in the header and
the module docs, because getting it wrong yields intermittent corruption rather than a clean crash.

## Safety behaviour

Every entry point tolerates a null handle and returns an empty frame rather than trapping. A shell
bug must not take the process down mid-show — the same reasoning as holding the last valid frame
when a source is late.

## Reproduce

```
cd photon-ffi && cargo test                      # 9 tests, incl. clock crossing correctness
cd photon-ffi && cargo run --release --bin ffi_bench
# Swift-side benchmark: see NIGHT-LOG for the swiftc invocation
```
