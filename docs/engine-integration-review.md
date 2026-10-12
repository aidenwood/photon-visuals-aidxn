# Integration review for Claude

**Codex, 2026-10-12.** Source review while building the native frontend. No benchmark run and
no renderer edits made for this review. These extend [the effects FPS plan](effects-fps-plan.md)
and V4's correctness/lifetime contracts. Engine work is still changing; check the current source
before fixing. Codex will keep refining the UI rather than duplicate your runtime implementation.

## Resolve before connecting the effects chain to multiple layers

1. **Same-size effect results alias.** `EffectChain.targets` caches one `(a,b)` pair keyed only
   by dimensions, and `apply` returns one of those textures. If two same-size layer chains are
   encoded before composition consumes their results, the second chain writes the first
   result's storage. A longer queue or a faster GPU cannot fix that ownership error. Keep each
   materialised layer result leased until its composite read completes; share scratch storage
   only where its last use is actually before the next writer. Frame slots also need distinct
   ownership when command buffers overlap. Two scratch targets suffice for **one serial
   chain**, not every live layer result and in-flight frame simultaneously.
2. **RGB Shift reads other pixels.** `EffectKind.isNeighbourhood` currently returns false for
   `rgbShift`, while its shader samples `uv+d`, `uv` and `uv-d`. It is not a pointwise colour op.
   Mark spatial reads conservatively before using that flag for damage regions or fusion.
   Coordinate warps and blur have different dependency footprints; eventually express those
   capabilities rather than one overloaded Boolean.
3. **Bound the resize pool.** The size-keyed effect pool has no eviction or connection to the
   core budget. Repeated preview/window sizes can retain pairs of RGBA16Float textures forever.
   Retire old dimensions after GPU completion, use a bounded leased pool and account for its
   residency. Resizing an editor must not expand an unbounded program resource cache.
4. **Count executed passes accurately.** `passesLastFrame` retains its old value on an empty or
   bypassed chain, and reports all active effects even if encoder creation fails part-way.
   Reset per frame and count successfully encoded work. Do not label this counter GPU kernel
   count or completed presentation count.
5. **Prewarm and share.** `ProgramMetalView.make` currently builds a separate engine per monitor;
   `EffectChain.init` compiles its MSL synchronously. Prepare/cache pipelines away from the
   main actor and presentation, and converge on shared runtime state. UI construction and
   opening a second preview should not repeat graph/shader/decoder preparation.

A small correctness check when you wire this: two same-size layers with deliberately different
effect results must remain different in the composite, including two submitted frames. That
tests a resource-ownership property; it is not a performance benchmark. Blur's current nested
`-2...2` loops sample **25** locations; its "9 tap" comment understates the actual reference work.
Optimise only after the reference semantics are settled.

## Poster cache integration

`ThumbnailCache` is the right separation from live decoding. Before the UI consumes it:

- Bound generation concurrency and memory/disk residency through the existing budget. An actor
  serialises metadata access but tasks suspended in `AVAssetImageGenerator` can still accumulate
  one decode per distinct file. `inFlight` and `memory` currently have no capacity limit.
- Validate media identity for **memory hits**, too. Modification-date checking is currently only
  on disk reads; an in-memory poster can survive a changed file indefinitely.
- Give each pending generation an identity. `cancel(url)` removes the dictionary entry; a new
  request can start, then the old task's continuation clears the new entry or caches a stale
  result. Generation checks should reject that old completion, as the UI's `PanelModel` does.
- Cancellation of one scrolled-off cell must not cancel a shared decode still needed by another
  visible cell. Use subscriptions/refcounts or let shared bounded generation finish into cache.
- Store writable caches under the application's Caches directory. The local run script stages
  demo media **inside the signed app bundle**; `beside(mediaDirectory)` must not write posters
  there and invalidate the signature. Read-only media volumes also need a writable fallback.
- Keep cached **poster frames** separate from bounded playing thumbnails. Browsing the grid
  must not create a live source per slot. Existing 256 px/15-Hz optional-preview guidance remains
  the initial runtime target; a 320-px static poster is not a claim of live thumbnail rate.

## Frontend integration boundaries

The running app currently combines UI fixture commands with native **demo** playback. The factory
now declares `content: .demonstration`; monitors say DEMO and do not label unrelated footage as
the selected fixture clip. Switch to `.workspace` only when selection/controls/metadata are
connected to the same runtime. `ProgramSurfaceFactory` still takes `(PreviewSnapshot, PreviewRole)`.

Please supply one provider adapter and shared surface subscriptions. The UI already has independent
panel reads, command lifetime separated from read cancellation, adjacent unsent fader coalescing,
80-ms trailing metadata refresh and local error recovery. Command acknowledgements must have bounded
latency; an unresponsive provider currently blocks the serial UI command worker. An urgent blackout
path belongs in the authoritative runtime/protocol, not a second ad hoc SwiftUI control channel.

Further lifetime audit: `VideoSource` holds only `currentTexture` while advancing frames. Ensure
the source's native backing owner and pixel buffer are kept through **the relevant GPU completion**,
not merely until the next frame arrives. Check the actual retain/lease path before concluding it is
safe; holding the UI snapshot or only the last source wrapper is not that proof. Its
`@unchecked Sendable` comment also does not provide synchronisation for simultaneous render/control
access. Confine mutations or publish the immutable packed snapshots already specified in V4.

The new `PhotonCoreCheck` verifies ABI version/strides **and** a packed-frame sentinel round-trip
through a private test handle. This catches field-order/type problems that equal stride alone
cannot establish. Consume the returned array before any further handle mutation; the source's
`photon_set_layers` clears/extends its Vec, so "until next tick" is not the complete lifetime rule.
Keep the tiny C ABI pragmatic, but revisit header generation/drift checking as document/string
functions are added. The measured call overhead is not a bound on total scheduling, modulation,
snapshot packing or GPU publication cost; those remain separate later acceptance checks.
