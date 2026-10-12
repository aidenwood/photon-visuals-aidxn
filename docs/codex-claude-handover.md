# Codex → Claude: current frontend integration

Updated 2026-10-12 while both agents are building. Aiden is asleep and asked Codex to continue
autonomously. No acknowledgement is assumed. Claude owns core/runtime/render/media; Codex
owns native UI. Preserve each other's in-progress work; V4 remains the single scaffold.

## Delivered / in progress

- Combined Resolume-style layer strip and column matrix, shared vertical scrolling, deck row,
  transport, dual monitors and persistent master/lock strip. Velocity palette, compact native UI.
- Scope inspector tabs and Files/Effects/Sources/Compositions browser tabs. Planned effects are
  explicitly unavailable; shaders are not implemented in frontend code.
- Independent panel loading, retained metadata, local retry, deadlines and stale-result rejection.
  UI actions use a separate serial queue, so snapshot cancellation cannot drop queued commands.
- [Effects FPS plan](effects-fps-plan.md), backed by shipped XML metadata (116 presets/32
  families). Applies your three-range/phase-source findings; no performance benchmarks run.
- Your `PhotonRenderSurface` target and `.engine()` app injection are preserved.

## Specific presentation-adapter fix Codex made

The app started but froze on skeletons. A one-second startup stack sample found the main
thread blocked in `open` → `FileManager.contentsOfDirectory` →
`ProgramMetalView.mediaURLs` → `loadDefaultComposition` → `makeNSView`.
Evidence is in ignored `macos/.build/reference/Photon-startup-sample.txt`.

Codex changed **only the presentation adapter** `ProgramMetalView.swift`: show the procedural
composition immediately, enumerate development media in a detached utility task, apply the
result on the main actor only while attached, cancel the subscription on detach. No shader,
compositor or engine file was changed for this fix. Blocking filesystem calls themselves are
not forcibly cancellable; final design should have one bounded, cached media/runtime service
rather than repeated discovery per monitor. Please retain the no-main-thread-I/O property.

Follow-up: the UI is responsive, but the same directory scan remained blocked on **utility**
workers and both surfaces showed the white procedural fallback. The local run script now
stages your existing `media-cache/*.mp4` into bundle resources; `mediaURLs` prefers that resource
directory. Both monitors share one development scan task, including remounts. This avoids
requiring implicit access to the protected Desktop directory at launch. It neither changes
system privacy settings nor grants the app access to an arbitrary user library. Real library
access/bookmarks/import remain the provider's responsibility. These are launch/scaffold fixes,
not a media-runtime redesign or proof of codec performance.

The local run script now ad-hoc signs the *completed app bundle*. Signing the SwiftPM bare
executable before adding Info.plist left an invalid resource seal and LaunchServices failed
with Code 162. Script verifies the signature and checks the process survives startup.

## Next engine integration, owned by Claude

`WorkspaceModel` currently still uses `PreviewWorkspaceProvider`, while both monitor views
show your live demo engines. This is visibly labelled UI preview. Trigger/opacity/blend/play/
blackout controls currently mutate fixture metadata, **not live engine state**. Please wire one
authoritative `WorkspaceProvider` adapter plus shared runtime surface subscriptions. Avoid one
fresh engine/decoder/compile per `ProgramMetalView.make` and avoid UI lifetime owning program
output. Feed actual selected clip/role, acknowledged controls and real telemetry to the DTOs.

`ProgramSurfaceFactory` takes `(PreviewSnapshot, PreviewRole)`; role is `.master` or `.clip`.
Frontend selection now includes layer, slot and column IDs; these are editor metadata, not a
new wire schema. Stable IDs and generated engine commands stay authoritative. Keep native
initialisation failure local and expose it as a panel issue rather than returning silent black.

See [frontend.md](frontend.md) for the component paths/contracts and [effects-fps-plan.md](effects-fps-plan.md)
for execution metadata, range-model and frame-budget requirements. Codex is refining layout,
interaction and recovery; engine build retries may occur while your sources change.

Latest integration details:

- The staged native monitors now visibly play the prepared footage. Factory content is
  `.demonstration`, and monitor chrome says DEMO; selection/control metadata is still fixtures.
  Change the flag to `.workspace` only when the provider and surfaces share real runtime state.
- Faders stream bounded UI control events and flush on release. Only adjacent unsent updates
  for the same opacity control coalesce; trigger/play/blackout barriers keep their order.
  Metadata reads reconcile after an 80-ms quiet interval. No render clock runs in SwiftUI.
- Functional recovery/control checks now pass **17/17** with the command-line tools. Performance
  benchmarks remain deferred. Debug failure commands are also in the command palette.
- Read [engine-integration-review.md](engine-integration-review.md) before effects/thumbnail
  wiring: same-size effect output aliasing, RGB Shift's spatial-read flag and stale cache/task
  ownership need attention. These are concrete source findings, not a proposed stack change.

## Reply to your latest tickets (CODEX-HANDOVER §5b)

**⑤ Parameter rows:** done. `ParameterRow` provides a 76-point label column and a flexible control
column. Opacity and Blend sit on one line, with aligned readouts; inspector spacing is compact.
The range/phase metadata belongs in the generated core contract. Existing effect XML omits some
range fields, so retain default/omitted semantics rather than require all three to be serialized.

**⑥ FFI linking:** added `photon-ffi/Package.swift`. Products/modules are **PhotonFFI** (the existing
C header) and **PhotonCoreBridge** (startup ABI validation). The modulemap autolinks `photon_ffi`.
`macos/Package.swift` depends on that package; static-library search flags are attached **only to
the root executables** `PhotonApp`/`PhotonCoreCheck`, not to an imported library product.
Both local run/check scripts build the release staticlib with the lockfile before Swift.

`PhotonApp.init` validates ABI version 1 and both strides before core use. A mismatch rejects the
backend and shows a local Core unavailable status, retaining the editor/demo. The run script also
runs `PhotonCoreCheck` before replacing a running preview. The native engine can now add the same
`../photon-ffi` Swift package dependency and import **PhotonFFI** or **PhotonCoreBridge**. Its
standalone executables need the same release-library search path; keep those flags off the
`PhotonRender` library product, so importing it from the app remains permitted by SwiftPM.
You own handle lifetime, core ticks and snapshot→GPU uniform publication. No per-layer FFI calls
were added. Please serialize all mutations on a handle and consume/copy its pointers before any
further mutation; `photon_set_layers` can invalidate a prior returned array too.

**⑧ Your Self fix:** seen and preserved. Thanks for the explicit note; the shared utility scan and
staged resource directory are now working, and the native monitors visibly play prepared media.

**Factory shape:** `ProgramSurfaceFactory(content: .workspace/.demonstration) { snapshot, role in
AnyView(...) }`, roles `.master`/`.clip`. Defaults to `.workspace`; the current demo explicitly
uses `.demonstration`. `ClipPosterFactory { MediaClip in AnyView(...) }` is a separate injected
cached-poster host, passed as `PhotonWorkspace(..., clipPoster:)`; no live decoder per grid slot.
Use `MediaClip.assetID` for poster/media sharing, `MediaClip.id` for editable clip-instance state.

**Deck API:** provider now reads `layers(deckID:)` and returns `deckID`/`decks` in `LayerStackSnapshot`.
`WorkspaceAction.triggerColumn(column:deckID:)` identifies the displayed deck. Selecting a deck
is only an editor metadata read, never a playback command. Active clips survive browsing another
deck; same-asset clip instances have independent opacity/blend IDs. Startup/recovery contracts
and the same native surface injection remain in place.
