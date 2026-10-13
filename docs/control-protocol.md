# Control protocol — versioned contract

**Status:** implemented in [`photon-core/src/protocol.rs`](../photon-core/src/protocol.rs). 10 tests,
inside the 275-test core suite. `PROTOCOL_VERSION = 1`.

This file documents the *contract*. The Rust module is the source of truth for the shapes — when
they disagree, the module is right and this file is stale. Don't fork the definitions into a Swift
or TypeScript copy; both shells decode the same serde JSON.

---

## Why it is shaped this way

**One message set, many transports.** The engine is authoritative. Clients hold optimistic state and
reconcile against pushed revisions.

**State-sync-first, not request/response.** The pads on an APC40 light up to show what is playing, so
the engine streams state outward continuously rather than answering questions. Retrofitting push onto
a request/response protocol is painful, which is why it is not done that way here.

**Sized for the Bluetooth LE budget.** LAN WebSocket is 1–5 ms at full bandwidth; BLE gives
single-digit KB/s and cannot carry preview at all; an internet relay is 50–300 ms. The wire format is
sized for BLE because **what fits BLE fits everything else — the reverse is not true.**

---

## Transports

| Transport | Typical one-way | Preview | Notes |
|---|---|---|---|
| `lan` | 5 ms | ✅ | WebSocket over the venue LAN |
| `midi` | 5 ms | ❌ | USB and BLE-MIDI control surfaces |
| `osc` | 5 ms | ❌ | OSC over UDP |
| `ble` | 60 ms | ❌ | Control only, single-digit KB/s |
| `relay` | 200 ms | ✅ | Outbound-only, token auth |

## Control classes, and refusing what cannot work

Every `Command` carries a `ControlClass`. A transport declares what it can carry, and a UI is
expected to **disable** controls its transport cannot serve.

| Class | Examples | Required latency |
|---|---|---|
| `trigger` | clip launch, cue go, tap, ping | any — quantisation hides the lag |
| `continuous` | faders, knobs, warp-point drags | ≤ 60 ms |
| `critical` | blackout, output enable | ≤ 60 ms |

Clip launch over BLE at 50 ms is fine. **A fader over an internet relay at 200 ms is unusable, so it
is not offered.** `Transport::supports(ControlClass)` is the check — refusing a control is better
than presenting one that feels broken and gets blamed on the hardware.

> ⚠️ **Open question for Aiden.** `critical` currently requires ≤ 60 ms, so `relay` refuses
> **blackout**. The reasoning is that a panic button which may take 300 ms is not a panic button.
> The counter-argument is that an operator away from the machine may want emergency blackout from
> anywhere, slow being better than impossible. Not changed unilaterally — the current behaviour is
> the conservative one and is covered by `relay_refuses_continuous_and_critical_controls`.

## Capabilities

Declared by the client on connect: `version`, `transport`, `wants_preview`, `needs_state_push`,
`max_message_bytes`.

Preview is sent only when the client **wants** it *and* the transport **can carry** it
(`preview_enabled()`). A BLE remote asking for preview must degrade silently and keep working —
never fail the connection.

## Commands (client → engine)

`trigger_clip{layer,column}` · `clear_layer{layer}` · `set_param{id,value}` · `blackout{on}` · `tap`
· `ping{t_ms}`

Two rules that are load-bearing:

- **Quantisation is applied engine-side, never by the client.** Every surface then lands on the same
  beat. A client that quantised locally would drift against the others.
- **`set_param` carries a dense `u32` id, not a path.** The frame loop must never parse a string, and
  the wire format must never carry one it does not need. Path → id resolution happens once, off the
  frame loop.

`blackout` is explicit and never implied by anything else.

**Every command must serialise to ≤ 180 bytes** so it fits a typical ~185-byte BLE ATT MTU without
fragmenting. Enforced by `commands_fit_a_ble_mtu` — adding a field that breaks the budget fails the
build rather than silently fragmenting on the one transport that cannot afford it.

## State updates (engine → client)

`snapshot` · `layer_changed` · `param_changed` · `clock_changed`, each carrying a monotonic
`revision`.

`RevisionTracker::accept` returns:

| Outcome | When | Client action |
|---|---|---|
| `Applied` | `rev == last + 1`, or any snapshot | apply it |
| `Stale` | `rev <= last` — duplicate or reordered | drop it; held state is newer |
| `GapDetected{missing_from}` | `rev > last + 1` | **request a full snapshot** |

A snapshot resynchronises unconditionally, and the stream continues cleanly from its revision.

**Why gaps are detected rather than tolerated:** silently applying an out-of-order update leaves the
surface showing state the engine does not have. On a lit controller that is worse than showing
nothing — the operator trusts a lit pad.

## Versioning

`PROTOCOL_VERSION` bumps on any breaking message change. Clients send the version they speak in
`Capabilities`. Because both shells consume the same crate, a version mismatch is a deployment
problem, not a schema-drift problem — which is the whole reason the protocol lives in the shared
core rather than in each shell.

## Not yet built

The transport **adapters** — WebSocket, BLE GATT, relay, MIDI, OSC. The message set, the
class/latency policy and the reconciliation logic above are done and tested; what remains is
carrying the bytes. Adapters are per-shell and live outside `photon-core`, which holds no platform
API.
