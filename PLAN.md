# Photon — Plan index

A realtime media server + projection-mapping engine. Resolume Arena's clip/deck/compositor model,
with TouchDesigner's compiled-DAG approach to keeping work on the GPU — targeting higher sustained
frame rate than Arena on the same machine, same files, same output.

**Owner:** Aidxn Design (personal).

---

## ☀️ Good morning — state as of 2026-10-13 12:00

**Everything is green.** Full narrative in [`NIGHT-LOG.md`](NIGHT-LOG.md); the short version:

| | |
|---|---|
| `photon-core` (Rust) | **275 tests**, 0 clippy warnings, portable incl. `wasm32` |
| `photon-ffi` (Rust→Swift) | **33 tests**. 6.4 ns/frame, flat to 32 layers |
| `engine` (Swift+Metal) | **178 GPU checks** — `cd engine && swift run -c release PhotonVerify` |
| `macos` app | Builds and runs; preview shows **your real Trees Have Eyes media** |
| `macos` core link | **4 probes pass** — `cd macos && swift run PhotonCoreCheck` |

**Three things worth your attention first:**

1. **🔓 DXV: DXT1 *and* DXT5 are cracked and verified on YOUR media — 52,407 frames byte-exact**
   across 147 real Resolume files, 4K and 1080p, 0 mismatches. Round-tripped both directions too
   (0 of 2,073,600 texels wrong on three synthetic 1080p textures exercising every op).

   The breakthrough: DXT5 is **not** a position-keyed table. It runs **two independent LZ planes**
   — alpha halves and colour halves, each with its own block cursor, and the plane that is behind
   takes the next op. They usually alternate, which is why cursor parity *looked* like the key;
   an alpha run breaks the alternation, and that is where every earlier model desynced.

   Also banked: DXV stores *premultiplied* RGB (skip it and everything renders dark), BC3 colour
   always uses 4-colour interpolation, and the run varint is `0xFF -> 255 + u16_le`.

   **Remaining: `YCG6` / `YG10` — 190 files, the biggest chunk of your library.** ffmpeg names them
   `YOCOCG6` / `YAOCOCG10`; they are a genuinely different scheme, *ruled out rather than untested*.
   That is the next derivation job.
2. **MIDI learn / control mapping is live** — in the portable core, so Windows gets it free, and
   verified through the real C boundary. Pickup (no jump on bank switch), displaced-binding
   reporting, note-velocity-0, inverted and sub-ranges, four curves. **The UI side is Codex's** —
   ticket ⑪ in `CODEX-HANDOVER.md`.
3. **The app was validating the ABI and then never calling the core.** Fixed: `PhotonCoreSession`
   owns the handle, and musical time, modulation, mapping and audio reactivity now actually reach
   the app.

**Advanced Output remains at V1 parity** — keystone, grid warp, feathered polygon masks, soft edge
(verified seamless), per-slice colour, test patterns, multi-projector splitter rigs, mapping saved
separately from the show.

**Two decisions still need you** — see `docs/scaffold.md` §7. Nothing is blocked on them.

**Try it:** `cd engine && swift run -c release PhotonEngineDemo` — keys for test patterns, keystone,
2/4-projector rigs, effects, blend modes. *(Must be launched from a GUI session; from a background
shell macOS throttles the display link and it renders invisibly.)*

---

**V4 engineering agreement; native frontend construction underway.**

## Proposals

| Proposal | Author | Status |
|---|---|---|
| [`proposals/V5/V5-context.md`](proposals/V5/V5-context.md) | Claude | 📋 **R0 state snapshot — what was built, measured and DISPROVEN. Not a plan. Read this before resuming work.** |
| [`proposals/V3/V3-merged.md`](proposals/V3/V3-merged.md) | Claude + final Codex performance amendments | **Reviewed into the agreed V4 scaffold** |
| [`proposals/V3/V3-codex.md`](proposals/V3/V3-codex.md) | Codex final performance review | **Reviewed into V4 scaffold** |
| [`proposals/V2-claude.md`](proposals/V2-claude.md) | Claude Code agent | Superseded by V3 — retire on adoption |
| [`proposals/V2-codex.md`](proposals/V2-codex.md) | Codex agent | Superseded by V3 — retire on adoption |

Competing proposals go in `proposals/` as **separate files**. They are never merged into one
another. When one wins, this table marks it `ADOPTED`, it becomes the thing everyone builds to, and
every loser moves to `proposals/_retired/` the same hour.

### Current work: native frontend construction

The single V4 build agreement is [`docs/scaffold.md`](docs/scaffold.md), edited in place.
Both agents accepted its engineering baseline. Aiden confirms the remaining questions were answered
with Claude and explicitly starts Codex on the frontend. Claude owns the engine and is obtaining Xcode.

Codex has created the runnable SwiftUI shell and individual loading/recovery components.
The current provider supplies clearly labelled UI fixtures. Native engine integration is described
in [`docs/frontend.md`](docs/frontend.md). Performance tests and benchmark runs are deferred.

## Settled decisions (closed — don't reopen in a proposal)

- **The Mac engine is a native macOS app. Metal. One backend on Mac.** No browser in the render
  path. Windows is a separate later platform. *(Aiden, 2026-10-12)*
- **Windows is required later; Mac is the target market and first release.** Separate apps or
  repositories are acceptable, with roughly aligned features and updates. *(Aiden's subsequent
  instructions, recorded in Claude V2 §0.6, 2026-10-12)*
- **The web app is a remote control surface for an engine on a different machine**, over the venue
  LAN — and it is a **later phase**, not V1. *(Aiden, 2026-10-12)*
- **iOS is the same control surface in a second shell.** Never a renderer. *(Aiden, 2026-10-12)*
- **Moveable UI/docking is cut.** V1 uses fixed persona templates and a stable panel model.
  *(Aiden's later instruction, recorded in Claude V2 §3.5.1b, 2026-10-12)*
- **Mac is the target market.** Performance goals are set and verified on macOS. *(Aiden, 2026-10-12)*
- **Windows is a requirement, but later**, and ships as a **fully separate repo** — own renderer,
  own shaders, own UI, own platform I/O, own release cadence. Feature drift between shells is
  acceptable. *(Aiden, 2026-10-12)*
- **`photon-core` is one shared versioned Rust crate** consumed by both apps — never vendored and
  edited. It owns the `.photon` document schema, the codecs and the control protocol. Sharing it
  preserves native GPU execution; CPU scheduling and bridge costs are measured. Forking the
  document schema would mean a Mac project can't open on Windows — a product failure, not a
  maintenance annoyance. **The core is the contract; the shells are the products.**
- **Hard discipline from day one: no Apple API in `photon-core`.** Platform capabilities sit behind
  Rust traits implemented per-shell. Enforce with a CI check. Breaking this turns the Windows port
  into a rewrite, quietly, months before anyone notices.
- **Performance spec:** 4 layers @ 120fps / 8 @ 60 / 12 @ ≥30 — **480 layer-frames/sec** — at
  **1080p** source, on a **base M4 / 32GB**. *(Aiden, 2026-10-12)*
- **UI:** Affinity-style persona shell (Perform / Map / Effects-later), Arena-shaped panels inside.
  **No moveable/dockable UI — cut.** Ship a few fixed **UI templates** per persona instead; layouts
  are a declarative struct tree so templates are just different trees. *(Aiden, 2026-10-12)*

- **Advanced Output at Resolume parity is a V1 requirement** — keystone/quad, bezier and grid warp,
  masks, soft-edge blending, per-slice colour, test patterns, output presets. Plus **MIDI learn-mode
  mapping on any parameter, with bidirectional state push.** *(Aiden, 2026-10-12)*
- **Two pipeline decisions that must be made on day one:** projective (homography) UV interpolation
  for warps, and a **linear-light compositor** with encoding only at final output. Retrofitting
  either is a rewrite, and getting them wrong is what makes projection mapping look amateur.
- **Control is transport-agnostic:** one message set, many adapters — LAN WebSocket, **Bluetooth LE**
  (control only, no preview), internet relay (outbound-only, token auth), **MIDI** (USB + BLE-MIDI),
  OSC, Art-Net in. Protocol is **state-sync-first**, sized for the BLE budget. *(Aiden, 2026-10-12)*

## Contract artifacts

| File | Purpose | Status |
|---|---|---|
| [`docs/scaffold.md`](docs/scaffold.md) | **V4 build agreement — R0 only. One file, edited in place.** | Engineering agreed; frontend build authorised and started |
| [`docs/frontend.md`](docs/frontend.md) | Native frontend ownership, components and engine adapter handover | Implemented scaffold; runtime integration follows |
| `docs/bench-fairness.md` | Rules every published performance number must obey | **not written** |
| `docs/bench-cli.md` | CLI contract `photonbench` drives | **not written** |
| `photon-core/src/doc/` | Authoritative Rust document model + generated schema/types | ✅ **implemented** — 882 lines, serde `deny_unknown_fields`, inside the 275-test suite |
| [`docs/control-protocol.md`](docs/control-protocol.md) | Versioned state/command semantics; transport adapters later | ✅ **contract written, protocol implemented** — `photon-core/src/protocol.rs`, 422 lines, 10 tests. Transport **adapters** still to build |

## Agents

- **Codex** — native front end: `macos/Sources/PhotonApp/`, `macos/Sources/PhotonUI/`, frontend tests
  and local run wiring. Benchmark/tooling work is secondary; later web/iOS remotes remain his scope.
- **Claude** — `photon-core/` and native runtime/render/platform/bridge targets; Rust, codecs,
  Metal/MSL and binary analysis. Obtaining Xcode.
- Shared handover: [`docs/frontend.md`](docs/frontend.md). Coordinate shared manifest edits before
  adding engine targets. Do not concurrently rewrite the other agent's source files.

## Repo layout

```
proposals/      V2/V3 review history
docs/           V4 agreement and current contracts
photon-core/    Claude — portable Rust core
macos/          Swift package and native app
  Sources/PhotonApp/    Codex — small app entry point
  Sources/PhotonUI/     Codex — individual panels, controls, loading and recovery
  Tests/PhotonUITests/  Codex — recovery/validation cases; execution deferred
script/         local native build/run entry point
bench/          later benchmark tooling
web/            dormant Vite template; later remote control only
```
