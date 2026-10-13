# Photon native front end

**Owner:** Codex. **Authorised by Aiden:** 2026-10-12. **Build agreement:** [scaffold.md](scaffold.md).
**Updated:** 2026-10-13. Latest shared replies: [Codex → Claude handover](codex-claude-handover.md).
Claude owns the portable core, native runtime, Metal/MSL and media/FFI adapters.
Aiden's latest direction is to build the app now; performance experiments and benchmark runs wait.

## What exists

A runnable SwiftUI macOS app, built with SwiftPM and packaged locally as an app bundle.
The entry point is `macos/Sources/PhotonApp/`; components live in `macos/Sources/PhotonUI/`.
The app shell composes components rather than containing their implementations.

- Perform and Map workspaces. Perform / Big Monitor / Many Layers templates, plus Mapping /
  Wide Canvas. Each persona remembers its layout. Stable integer `WorkspacePanelID`s identify panes.
- Combined layer-strip/column grid with shared vertical scrolling, clip/column triggers and deck
  selection. Browsing an empty deck preserves active clips. Clip-instance and asset IDs are distinct.
- Two monitors, scope inspector tabs and Files / Effects / Sources / Compositions browser tabs.
- Compact horizontal `ParameterRow`s, continuous faders, opacity/blend, bypass/solo and master
  controls. Layout lock and blackout remain in the persistent footer.
- Output cards and the mapping overlay.
- Searchable command palette, arrow-key selection and native menu shortcuts.
- Component-specific skeletons; local error/retry views.
- Debug-only panel failure controls. Release builds retain loading, validation and recovery code.

The `PreviewWorkspaceProvider` supplies UI fixtures. Grid art, codec labels, transport state and
output cards are examples. Separately, Claude's injected native Metal surfaces play prepared
H.264 demo footage. Monitors say **DEMO**; they do not label that unrelated footage as the selected
fixture clip. The provider and surfaces still need one shared runtime adapter before controls
drive that playback. This does not establish native HAP/DXV playback or active projectors.

The Rust staticlib is now linked through `PhotonFFI`/`PhotonCoreBridge`. Startup validates ABI
version and struct strides; `PhotonCoreCheck` also verifies a packed-frame field round-trip.
Core ticks and real commands remain engine-owned. Unmeasured telemetry stays absent (a dash).
Effects browser entries are planned/unavailable; [the FPS plan](effects-fps-plan.md) precedes
their UI execution wiring. Sources/groups/output editing still have scaffold states.

## Visual direction

Use **Arena's workflow and panel geometry**, Affinity-style personas, and Aiden's Velocity identity.
The grid is layers × columns, not a dashboard of clip cards. Claude's
[XML reference](resolume-ui-reference.md) and targeted REA screenshots guide the native layout.
REA is the inspection tool, not a UI component repository or visual template.
The palette comes from [Velocity 9 editor](../../velocity9-editor/tailwind.config.ts):
dark `#0c0c10` canvas, `#141419` panels, `#1c1c24` raised controls, thin `#26262f` edges,
violet `#8b5cf6`, foreground `#e7e7ee` and restrained muted labels.
Use square corners throughout app chrome, compact technical labels and canvas-first hierarchy.
Panels sit flush against the workspace edges with 1-point seams and no outer gutters. Keep
small insets only for controls, focus states and readable labels; do not add card-style panel
padding. Shared density dimensions live in `PhotonTheme` so Perform, Map and loading states agree.
Use the same native system text approach as that editor.
The [Aidxn brand brain](../../aidxn-brand-brain/halls/components/rooms/cards-and-panels.md) is a
secondary identity reference. Website typography and dashboard structure do not set desktop
control sizes or the grid layout. The local app icon uses the same code-native circle mark/palette.

## Failure and lifetime boundaries

Each subsystem has its own observable `PanelModel`; there is no global loading/error gate.
Library, layers/decks, clip preview, composition preview, inspector, master, outputs, transport and
telemetry have separate models. Only the components consuming one domain share its state.

A model retains its last successful value while refreshing or failing. Its first load shows
a skeleton; failed first loads show a local retry view. A ten-second deadline ends the local
loading state. Cancellation and request generations reject stale successes and stale errors.
Providers must honor cancellation or coalesce bounded work internally; cancelling a UI task
cannot forcibly stop an uncooperative native operation.

Validate identifiers, dimensions, control values, deck/slot identity and telemetry before rendering. Views avoid
force unwraps and forced casts. The shell does not swap out the entire workspace on failure.
A retained preview value keeps the same surface branch mounted when a panel fails.

Commands have a separate bounded serial lifetime from panel reads. Adjacent unsent opacity
updates coalesce, without crossing trigger/play/blackout barriers. Faders flush on release;
metadata reconciles after an 80-ms quiet interval. Native command acknowledgements must be
bounded; an uncooperative provider cannot be forcibly cancelled by SwiftUI. The engine/protocol
owns urgent blackout scheduling and frame publication. Directory scans and shader preparation
must stay off the main actor; local panel deadlines cannot run while that actor is blocked.

This contains recoverable data/command failures. SwiftUI cannot catch a native process crash.
Program lifetime and any separate-process supervision belong to the runtime, independently of
editor visibility. Retained UI metadata is not a guarantee that a physical output keeps running.

## Integration handover for Photon/Claude

1. Keep engine sources in separate targets, outside `PhotonUI/` and `PhotonApp/`.
   Codex owns frontend target wiring in `macos/Package.swift`; coordinate manifest additions.
2. Implement `WorkspaceProvider` as an actor or explicit off-main adapter. Map generated engine
   types into display snapshots; these DTOs are not a second document/control schema.
3. Translate `WorkspaceAction` into authoritative engine commands. Reconcile acknowledged state;
   cancelling a UI request does not undo an engine command already accepted.
4. Inject the native GPU view through `ProgramSurfaceFactory` into `PhotonWorkspace`.
   Signature: `(PreviewSnapshot, PreviewRole) -> AnyView`; roles `.master`/`.clip`. Factory content
   is `.workspace` once connected, `.demonstration` for the current independent demo.
   Its renderer, presentation clock and frame leases stay engine-owned. UI observations are
   metadata/control updates, not render ticks or CPU copies of program frames.
5. Inject cached grid posters through `ClipPosterFactory { MediaClip in AnyView(...) }`, passed
   as `PhotonWorkspace(..., clipPoster:)`. Share by `assetID`; controls address the instance `id`.
   Bound decode concurrency, cache residency and subscriber lifetime in the engine adapter.
   See [integration review](engine-integration-review.md) before consuming the current cache.
6. Replace fixture connection labels with authoritative runtime status when wiring the real
   provider. Keep unavailable telemetry absent and actual presentation misses observable.
   **The CPU/GPU/Output readout is now live** (2026-10-13): `PhotonRender.FrameMeter` measures
   it, `ProgramMetalView` (master role only) publishes into `PhotonUI.LiveTelemetryBus`, and
   `LocalMediaWorkspaceProvider.telemetry()` reads it. Every metric is `Double?` end to end — an
   unmeasured one stays `nil` and renders as "—", and nothing in that path substitutes a value.
   `EngineTelemetry.unpresentedFrames` counts composited frames the display never showed, read
   from `presentedTime == 0`; it is **not** a dropped-frame count.
7. Preserve the existing performance contracts: coalesced UI observations, hidden-view suppression,
   bounded previews/thumbnails, no frame-loop path parsing and no synchronous GPU readback.

## Local run

From the project root:

```sh
./script/build_and_run.sh
```

The Codex Run action uses the same script. It stages `macos/.build/local-app/Photon.app`.
It builds Rust then Swift, checks the ABI, stages prepared demo media and the app icon, ad-hoc
signs the completed bundle and only restarts this checkout's executable. A failed compile leaves
the previous preview running. Command Line Tools plus Rust are sufficient; full Xcode is not a
prerequisite for this local app. Normal user media import/bookmarks remain the adapter's job.

Shortcuts: ⌘K commands, ⌘1 Perform, ⌘2 Map, ⇧⌘F toggle monitor layout,
⌥⌘P preview transport, ⌥⌘B blackout, ⇧⌘R reload library.

Recovery checks are written in `macos/Tests/PhotonUITests/`. They can run with Swift Testing
after Xcode is ready, or with `./script/check_frontend.sh` using the installed command-line tools.
**19/19 functional frontend checks passed**: independent recovery, retained data, stale results,
timeouts, validation, command lifetime/coalescing, rapid blackout, deck playback isolation and
independent clip instances. Native Cmd-K/filter/Return was exercised, and an injected clip-preview
failure stayed local while the composition monitor continued visibly displaying demo footage.
No FPS benchmark or target-tier result is claimed. New screenshots live in ignored
`.codex/artifacts/frontend/`, outside SwiftPM's disposable build directory.
