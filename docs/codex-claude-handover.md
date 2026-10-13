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

## 2026-10-13 — active audio-first UI contract (Codex)

Aiden is directing both agents concurrently. Codex owns the native presentation work;
Claude retains capture/analysis, core modulation, media library/cache and runtime adapters.
Do not replace each other's in-progress files. Current UI density rule: square chrome,
no outer gutters, 1-point panel seams, compact control insets.

New requirement: audio is the first pane, before the layer/clip grid. Multiple independent
input endpoints can be enabled simultaneously. Show each input's level, detected BPM and
beat count; keep these distinct from transport BPM. One explicitly selected input may be the
composition tempo source; selecting it must not disable other audio-reactive inputs. Route
readouts must expose input → signal → visual target, and clicking a target should focus its
layer/clip inspector. No simulated beats or hard-coded 120 BPM presented as audio detection.

Codex is adding presentation DTOs in `Models/AudioWorkspaceSnapshot.swift`, provider reads
`audio()` / `audioUpdates()` and actions `setAudioInputEnabled`, `setAudioTempoSource`,
`connectAudioSignal`, `disconnectAudioRoute`. Existing providers remain source-compatible via
unavailable/finished-stream defaults. Stable IDs represent actual device/channel endpoints,
engine-defined signals/bands and bindable visual targets; they are display DTOs, not a second
core document schema. Please supply authoritative snapshots, acknowledged selection, measured
levels/tempo/beat/confidence, and actual routing results through the runtime provider. The
updates stream must coalesce latest data at a bounded UI rate and release subscriptions on
cancellation; never drive the render clock from SwiftUI. No input is fabricated in the UI.

Thumbnail answer: startup still constructs the default `PreviewWorkspaceProvider`; its
`Self.clips`/grid slots are fixtures, and `PhotonApp` injects `.engine()` monitors but no
`ClipPosterFactory`. Consequently grid artwork and monitor media do not share a library.
Please wire local library import/bookmarks + the authoritative provider + cached posters
(`MediaClip.assetID`) to the SAME runtime. The frontend factory hook already exists. Do not
substitute unrelated demo frames for user's assets or run a video decoder per grid cell.

### Reply to ticket ⑫ — active 2026-10-13

Read your ticket while implementing. Use `EffectKind.allCases` in the app adapter NOW,
mapped to pure PhotonUI descriptors; no new FFI registry required for this native pass. Keep
engine category order. Parameter controls use normalized 0...1 doubles, 0.01 coarse steps,
0.001 with Shift, two decimal places, clamp before commit; reset defaults come from descriptor
metadata (native `Effect` defaults 0.5 currently). Scrub digits horizontally, keyboard arrows
step, double-click for direct numeric entry. Send authoritative ParamSpec ranges/precision when
ready and those descriptors can replace the normalized defaults without changing row controls.

Your binding API takes precedence over the earlier audio DTO sketch above: Codex will reserve
modulation affordances and the first audio pane; no second audio schema/clock will be invented.
Please expose source snapshots + enabled-input selection + per-source BPM/beat + bindings as
one runtime adapter contract when ready. Multiple inputs active together remains required.

Thumbnail wiring is implemented in app-owned `LocalMediaCatalog`, `LocalMediaWorkspaceProvider`
and `LocalClipPoster`: real catalogue from staged `DevelopmentMedia` (checkout `media-cache`
fallback), supplied to `PreviewWorkspaceProvider(clips:deckTitle:)`; `ClipPosterFactory` now
injected by `PhotonApp`. Existing `ThumbnailCache` generates 256 px posters, serialized by the
app adapter and shared across cells, with writable ~/Library/Caches storage. No engine files
edited. This solves the current fake grid names/artwork; runtime controls/selected monitor
playback still need your shared provider/surface wiring and remain labelled UI preview/DEMO.

### Active presentation ticket — corner-pin drag (2026-10-13)

Aiden reports slice handles cannot be dragged and the video never keystones. Confirmed:
`MappingOverlay` is decorative with `.allowsHitTesting(false)`, and no output state is sent.
Codex is implementing normalized TL/TR/BR/BL editor corners, convexity guards, draggable
handles and Reset in PhotonUI. To make the UI actually move rendered pixels, Codex will add
ONLY a small presentation bridge in `PhotonRenderSurface/EngineSurface.swift` and
`ProgramMetalView.swift`: a mapped factory view and `setMappingCorners` forwarding normalized
UI corners to existing `engine.topology.screens[0].slices[0].corners` in clip space. No engine,
warp, shader or core implementation edits. Please preserve this wiring while changing runtime
ownership; later replace the single-demo-slice target with the authoritative selected slice ID.

### Team split and build integration (2026-10-13, active)

Aiden explicitly asked Codex to run subagents. Codex now manages three frontend agents:
audio pane/adapter, inspector effects UX, mapping drag/keystone. Parent owns local media,
app integration and combined build/QA. No agent edits engine/core/FFI. Mapping agent may make
minimal changes to the presentation bridge documented above, preserving your SurfacePlan work.
Your new LiveTelemetryBus failed Swift6 on AnyObject captured in lock @Sendable closures;
Codex hoisted ObjectIdentifier creation outside the three closures (same semantics, compile fix).
