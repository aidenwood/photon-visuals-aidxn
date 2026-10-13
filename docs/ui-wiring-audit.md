# UI wiring audit — every interactive control

**Read-only audit of the working tree as it stands on 2026-10-13**, including the large body of
uncommitted work from concurrent agents (`git status` shows ~60 modified files). This audit
describes **what is on disk now**, not what was in the build Aiden screenshotted.

> **The screenshot and the code no longer agree.** The build that showed `PLANNED LIBRARY`,
> `Effect processing is not connected yet.` and `DEMO` monitor badges is older than the working
> tree. Those strings do not exist anywhere in `macos/Sources/` today
> (`grep -rn "PLANNED\|not connected"` → no matches), and `ProgramSurfaceFactory.Content` is now
> `.workspace` (`macos/Sources/PhotonRenderSurface/EngineSurface.swift:104`), which suppresses the
> `DEMO` badge (`macos/Sources/PhotonUI/Panels/Preview/PreviewPanel.swift:15`). **Rebuild before
> re-testing** — several of the complaints are already fixed in the tree.

---

## How to read the verdicts

The app's only visible render target is the pair of on-screen Metal monitors. There is **no
projector, no fullscreen output window, no Syphon/NDI** anywhere in `macos/Sources` — `grep -rn
"NSScreen\|NSWindow\|fullScreen\|Syphon\|NDI" macos/Sources` returns nothing. So:

- **LIVE** = the control reaches `PhotonEngine` and changes what the **Composition Monitor** draws.
  It does *not* mean it reaches a hardware output, because no hardware output exists.
- **STORED** = it mutates `PreviewWorkspaceProvider`'s in-memory dictionaries and the UI redraws
  from them, but nothing downstream of the UI consumes the value.
- **FIXTURE** = it displays a hardcoded or constant value.
- **INERT** = no handler.
- **UNKNOWN** = could not be determined by reading.

The LIVE chain, in full, is:

```
<control> → WorkspaceModel.<cmd>            macos/Sources/PhotonUI/Stores/WorkspaceModel+Live.swift
          → WorkspaceCommandQueue.send      macos/Sources/PhotonUI/Services/WorkspaceCommandQueue.swift:36
          → PreviewWorkspaceProvider.perform macos/Sources/PhotonUI/Services/PreviewWorkspaceProvider+Live.swift:38
          → reloadLayers()/reloadMaster()   → new LayerStackSnapshot / MasterSnapshot
          → masterPlan(model)               macos/Sources/PhotonRenderSurface/EngineSurface.swift:37
          → ProgramMetalView.apply(_:)      macos/Sources/PhotonRenderSurface/ProgramMetalView.swift:123
          → PhotonEngine.setLayers / .masterOpacity / .blackout
          → Compositor fragment fold        engine/Sources/PhotonRender/Engine.swift:452
```

Only **five** facts survive that whole chain: per-layer `opacity`, `bypassed`, `soloed`, the layer's
resolved `clipURL`, plus `masterOpacity` and `blackout`. `SurfacePlan.Layer`
(`EngineSurface.swift:14-20`) has no field for anything else — which is exactly why blend modes,
effects, transforms and clip-level opacity are STORED rather than LIVE.

---

## Truth table

### Clip grid and layer strip

| Control | Where it lives | What it claims to do | What it actually does | Verdict |
|---|---|---|---|---|
| Layer opacity fader | `PhotonUI/Panels/Grid/LayerControlRow.swift:23` → `LayerStrip.swift:22` | Fade that layer in the composite | Full chain to `LayerState.opacity`; compositor skips the layer when alpha ≤ 0 (`Compositor.swift:361`) | **LIVE** |
| Layer **B** (bypass) | `LayerControlRow.swift:18`, `LayerStrip.swift:23` | Exclude layer from composite | `setLayerBypass` → `LayerState.bypassed` → excluded by `Engine.activeLayers` (`Engine.swift:361`) | **LIVE** |
| Layer **S** (solo) | `LayerControlRow.swift:19`, `LayerStrip.swift:24` | Show only soloed layers | `setLayerSolo` → `LayerState.soloed` → `Engine.swift:362` | **LIVE** |
| Layer blend "Normal" | `LayerControlRow.swift:22` | Reads as the layer's blend mode | A literal `Text("Normal")`. Not a menu, not bound to anything, cannot be changed | **INERT** |
| Layer name (select) | `LayerControlRow.swift:14` → `WorkspaceModel.selectLayer` (`WorkspaceModel.swift:63`) | Select layer for the inspector | Sets `selectedLayerID`, switches inspector scope | **LIVE** |
| Clip cell (launch) | `PhotonUI/Panels/Grid/MatrixClipCell.swift:12` → `WorkspaceModel+Live.swift:17` | Launch clip on that layer | Sets `activeClips[layer]`; `masterPlan` resolves its `assetID` to a real file URL (`EngineSurface.swift:30`) and the engine opens a `VideoSource` | **LIVE** |
| Empty clip slot | `MatrixClipCell.swift:43` | — | A `Rectangle`. No drop target, no click target | **INERT** |
| Column launch arrow | `PhotonUI/Panels/Grid/ColumnTrigger.swift:8` → `WorkspaceModel+Live.swift:25` | Launch the whole column | Sets `activeClips` for every layer (`PreviewWorkspaceProvider+Live.swift:52`) | **LIVE** |
| Deck tabs | `PhotonUI/Panels/Grid/DeckTabs.swift:14` → `WorkspaceModel+Live.swift:36` | Switch deck | Reloads layers for the new deck. The deck *list* is two hardcoded fixtures, `"afterlight"` / `"empty"` (`PreviewWorkspaceProvider+Live.swift:27-30`) | **LIVE** (over FIXTURE data) |
| Panel header "· UI PREVIEW" | `PhotonUI/Panels/Grid/ClipMatrixPanel.swift:7` | Warns the grid is a mock | Hardcoded string, never conditional | **FIXTURE** |

### Transport bar

| Control | Where it lives | What it claims to do | What it actually does | Verdict |
|---|---|---|---|---|
| Play / pause | `PhotonUI/Panels/Transport/TransportControls.swift:10` → `WorkspaceModel.togglePlayback` (`WorkspaceModel.swift:119`) | Start/stop playback | Sets `PreviewWorkspaceProvider.playing` (`PreviewWorkspaceProvider.swift:111`). Nothing reads it. `VideoSource` playback is driven by the display link and never pauses | **STORED** |
| Timecode `00:00:00` | `TransportControls.swift:16` | Playhead position | Literal string | **FIXTURE** |
| `PREVIEW` pill | `TransportControls.swift:17` | Mode indicator | Literal string | **FIXTURE** |
| BPM readout | `TransportControls.swift:21` ← `PreviewWorkspaceProvider.swift:87` | Project tempo | Always `120`. `PhotonEngine.bpm` (`Engine.swift:295`) is never read or written by the UI | **FIXTURE** |
| BPM field (editable) | — | — | Does not exist. The BPM is a `Text`, not a `TextField` | **INERT** (absent) |
| Tap tempo | — | — | Does not exist anywhere in `macos/Sources` | **INERT** (absent) |

### Master strip (persistent footer)

| Control | Where it lives | What it claims to do | What it actually does | Verdict |
|---|---|---|---|---|
| Lock | `PhotonUI/Panels/Telemetry/MasterControls.swift:8` | "Lock" the performance | Toggles `performanceLocked`, which disables **only** the persona buttons, the layout menu and three menu items (`WorkspaceHeader.swift:27,49`, `WorkspaceCommands.swift:12-22`). Faders, triggers and blackout stay fully live | **LIVE** (narrow scope) |
| Master fader | `MasterControls.swift:16` → `WorkspaceModel+Live.swift:63` | Trim the whole composite | `MasterSnapshot.opacity` → `SurfacePlan.masterOpacity` → `engine.masterOpacity` → `st.opacity * masterOpacity` (`Engine.swift:452`) | **LIVE** |
| BLACKOUT | `MasterControls.swift:19` → `WorkspaceModel+Live.swift:64` | Kill output | Optimistic `requestedBlackout`, then `engine.blackout = true` → every layer's uniform alpha forced to 0 (`Engine.swift:452`) → compositor `continue`s past all of them (`Compositor.swift:361`) | **LIVE** |
| Master retry | `MasterControls.swift:33` | Retry master panel | `reloadMaster()` | **LIVE** |
| "Preview mode · Output inactive" | `PhotonUI/Panels/Telemetry/PerformanceBar.swift:11` | Status | Hardcoded. Happens to be **true** — there is no output | **FIXTURE** |
| CPU readout | `PhotonUI/Panels/Telemetry/TelemetryReadout.swift:8` | CPU ms/frame | `PreviewWorkspaceProvider.telemetry()` returns `nil, nil, nil` (`PreviewWorkspaceProvider.swift:92`), so always renders `—` | **FIXTURE** |
| GPU readout | `TelemetryReadout.swift:9` | GPU ms/frame | Same — always `—` | **FIXTURE** |
| Output fps readout | `TelemetryReadout.swift:10` | Presented FPS | Same — always `—` | **FIXTURE** |
| Metrics retry | `PhotonUI/Panels/Telemetry/TelemetryPanel.swift:13` | Retry metrics | `reloadTelemetry()` | **LIVE** |

### Monitors

| Control | Where it lives | What it claims to do | What it actually does | Verdict |
|---|---|---|---|---|
| Composition Monitor | `PhotonUI/Panels/Preview/PreviewPanel.swift:14` → `EngineSurface.swift:103`, `masterPlan` at `:37` | Show the composite | Real Metal render of the real layer stack, with real opacity/bypass/solo/master/blackout | **LIVE** |
| Preview (clip) Monitor | `EngineSurface.swift:63` (`clipPlan`) | Show the selected clip pre-composite | Real Metal render of the selected clip's file at opacity 1. Correctly unaffected by master/blackout | **LIVE** |
| Monitor dimension badge | `PreviewPanel.swift:30` ← `PreviewSnapshot(width: 1920, height: 1080)` (`PreviewWorkspaceProvider.swift:65`) | Output resolution | Constant `1920 × 1080`, never measured from the drawable | **FIXTURE** |
| Monitor caption ("… · Preview") | `PhotonUI/Panels/Preview/ProgramPreviewSurface.swift:27` | Clip name + mode | Clip name is real; the "Preview" suffix is hardcoded | **FIXTURE** |
| Mapping canvas (Map persona) | `PhotonUI/Workspace/MapWorkspace.swift:10` | Mapping surface | Same live master surface, with a decorative overlay on top | **LIVE** |

### Inspector

| Control | Where it lives | What it claims to do | What it actually does | Verdict |
|---|---|---|---|---|
| Scope tabs (Composition/Layer/Group/Clip/Column) | `PhotonUI/Panels/Inspector/InspectorPanel.swift:9` | Switch inspector scope | Sets `model.inspectorScope`, swaps the sub-view | **LIVE** |
| **Composition** → Opacity | `Inspector/CompositionInspector.swift:11` → `setMasterOpacity` | Master opacity | Same LIVE path as the footer Master fader | **LIVE** |
| **Composition** → Canvas `1920 × 1080` | `CompositionInspector.swift:14` | Canvas size | Literal string | **FIXTURE** |
| **Composition** → Blackout `On/Off` | `CompositionInspector.swift:15` | Blackout state | Reads real `MasterSnapshot.blackout`. Read-only readout | **LIVE** (readout) |
| **Composition** → Effects stack | `CompositionInspector.swift:17` | Composition effects | See Effects section — **STORED** | **STORED** |
| **Layer** → Opacity | `Inspector/LayerInspector.swift:12` | Layer opacity | Same LIVE path as the grid fader | **LIVE** |
| **Layer** → Bypass | `LayerInspector.swift:14` | Bypass layer | LIVE | **LIVE** |
| **Layer** → Solo | `LayerInspector.swift:15` | Solo layer | LIVE | **LIVE** |
| **Layer** → Effects stack | `LayerInspector.swift:18` | Layer effects | **STORED** | **STORED** |
| **Layer** → Modulation "Unbound" | `LayerInspector.swift:19-21` | Bindings | Literal text, no binding UI | **FIXTURE** |
| **Group** tab | `InspectorPanel.swift:36` | Group inspector | `PanelEmptyView` placeholder. No groups exist in any model | **INERT** |
| **Clip** → Opacity | `Inspector/InspectorContents.swift:14` → `WorkspaceModel.setOpacity` (`WorkspaceModel.swift:98`) | Clip opacity | Writes `PreviewWorkspaceProvider.opacities[clipID]` (`PreviewWorkspaceProvider.swift:103`). `SurfacePlan` has **no per-clip opacity field** — never reaches the engine | **STORED** |
| **Clip** → Blend | `InspectorContents.swift:15` → `BlendModeControl.swift` → `WorkspaceModel.setBlendMode` | Clip blend mode | Writes `blendModes[clipID]` (`PreviewWorkspaceProvider.swift:109`). `engine.setBlend` exists (`ProgramMetalView.swift:145`) and is **never called** | **STORED** |
| **Clip** → Transform Position `0, 0` | `InspectorContents.swift:18` | Layer offset | `ParameterReadout` with a literal string. `LayerUniform.offsetScale` exists and is never driven | **FIXTURE** |
| **Clip** → Transform Scale `100%` | `InspectorContents.swift:19` | Layer scale | Literal string | **FIXTURE** |
| **Clip** → Transform Rotation `0°` | `InspectorContents.swift:20` | Layer rotation | Literal string. The compositor has **no rotation term at all** | **FIXTURE** |
| **Clip** → Effects stack | `InspectorContents.swift:22` | Clip effects | **STORED** | **STORED** |
| **Clip** → Modulation / Bindings | `InspectorContents.swift:23-25` | Audio/MIDI bindings | Literal text "No bindings for this clip." | **FIXTURE** |
| **Column** → "Inspect clip" | `Inspector/ColumnInspector.swift:15` | Select that clip | `selectClip` — real | **LIVE** |
| **Column** → "Trigger column" | `ColumnInspector.swift:22` | Launch column | Same LIVE path as the column arrow | **LIVE** |

### Effects (every row here is STORED — see Root cause §2)

| Control | Where it lives | What it claims to do | What it actually does | Verdict |
|---|---|---|---|---|
| Add effect `+` menu | `Inspector/EffectStackView.swift:58`, items at `:77` | Insert an effect | Appends an `InspectorEffect` to `PreviewWorkspaceProvider.effectStacks` (`PreviewWorkspaceProvider+Effects.swift:14`). Never becomes a `PhotonRender.Effect` | **STORED** |
| Effect enable / bypass dot | `Inspector/EffectInspectorRow.swift:18` | Bypass the effect | Flips `InspectorEffect.enabled` in the fixture dict | **STORED** |
| Effect amount fader | `EffectInspectorRow.swift:28` | Effect intensity | Writes `InspectorEffect.amount` | **STORED** |
| Effect expand chevron | `EffectInspectorRow.swift:13` | Expand parameters | Local `@State` toggle | **LIVE** (UI only) |
| Effect "…" → Reset amount / Reset parameters / Remove | `EffectInspectorRow.swift:31-35` | Reset / remove | Fixture mutations | **STORED** |
| Effect remove `✕` | `EffectInspectorRow.swift:39` | Remove effect | Fixture mutation | **STORED** |
| Effect drag-reorder | `EffectStackView.swift:22-23`, `:45` | Reorder the chain | Reorders the fixture array (`PreviewWorkspaceProvider+Effects.swift:26`) | **STORED** |
| Effect parameter scrubber / slider / reset | `Inspector/EffectParameterRow.swift:11`, `:12`, `:14` | Set a parameter | Fixture mutation | **STORED** |
| Effect modulation icon | `EffectParameterRow.swift:18` | Suggests modulation routing | A plain `Image`, no `Button`, tooltip says "No modulation assigned" | **INERT** |

### Browser

| Control | Where it lives | What it claims to do | What it actually does | Verdict |
|---|---|---|---|---|
| Browser tabs | `PhotonUI/Panels/Library/BrowserPanel.swift:11` | Switch Files/Effects/Sources/Compositions | Local `@State`, swaps content | **LIVE** |
| Search field | `BrowserPanel.swift:16` | Search the browser | Client-side `localizedCaseInsensitiveContains` filter over the already-loaded list | **LIVE** |
| **Files** → clip row | `Library/LibraryClipRow.swift:9` via `BrowserPanel.swift:47` | Select a clip | `selectClip` → reloads Preview monitor + Inspector. The list is **real**: `LocalMediaCatalog` scans the bundle's `DevelopmentMedia` or the repo `media-cache/` (`PhotonApp/LocalMediaCatalog.swift:19-32`) and the posters are **real decoded frames** via `ThumbnailCache` (`LocalMediaCatalog.swift:54`) | **LIVE** |
| **Effects** → effect row `+` | `Library/EffectsBrowser.swift:22` | Add effect to the selected scope | Real catalogue (37 `EffectKind` cases, `NativeEffectDefinitions.swift:5`), but the add is **STORED** | **STORED** |
| **Sources** tab | `BrowserPanel.swift:24` | Generators / signal inputs | `PanelEmptyView` placeholder. `LiveInputs.swift` (209 lines) and `ISF.swift` (271 lines) exist in the engine and are referenced nowhere in the shell | **INERT** |
| **Compositions** tab | `BrowserPanel.swift:26-30` | Composition list | Two hardcoded `Text` views reading "Afterlight" / "Current preview composition". Not clickable | **FIXTURE** |

### Header, chrome, menus

| Control | Where it lives | What it claims to do | What it actually does | Verdict |
|---|---|---|---|---|
| Perform / Map persona switch | `PhotonUI/Workspace/WorkspaceHeader.swift:17` → `WorkspaceModel+Live.swift:85` | Switch workspace | Swaps the root layout, restores that persona's saved template | **LIVE** |
| "UI preview" warning pill | `WorkspaceHeader.swift:36` | Warns nothing is live | Hardcoded `StatusPill`, unconditional. Now **under**-states reality: the monitors *are* live | **FIXTURE** |
| Layout dropdown | `WorkspaceHeader.swift:39` → `switchTemplate` (`WorkspaceModel+Live.swift:91`) | Change panel layout | Changes layout and persists to `UserDefaults` (`WorkspacePreferences.swift:17`) | **LIVE** |
| Diagnostics 🐞 menu (DEBUG only) | `PhotonUI/Workspace/DiagnosticsMenu.swift:8-19` | Inject panel failures | Really injects failures into each `PanelModel` | **LIVE** |
| Commands button / ⌘K | `WorkspaceHeader.swift:53`, `WorkspaceCommands.swift:9` | Open command palette | Presents the sheet | **LIVE** |
| Command palette entries | `PhotonUI/Workspace/CommandPaletteView.swift:12-23` | Run a command | Dispatch works correctly; each entry inherits the verdict of the control it calls (e.g. "Blackout" LIVE, "Play preview" STORED) | **LIVE** (dispatch) |
| Menu bar: Workspace / Transport | `PhotonUI/Workspace/WorkspaceCommands.swift:8-33` | Shortcuts | All dispatch correctly; same inheritance rule | **LIVE** (dispatch) |
| Panel retry buttons (generic) | `PhotonUI/Components/PanelFailureView.swift:21` | Retry a failed panel | Calls the panel's real reload | **LIVE** |
| Output tiles (Map) | `PhotonUI/Panels/Mapping/OutputTile.swift` ← `PreviewWorkspaceProvider.swift:79-82` | Configured outputs | Two hardcoded descriptors, "Canvas 01" / "Slice 01". Non-interactive. `OutputTopology` (238 lines) and `Warp.swift` (1156 lines) are never touched by the shell | **FIXTURE** |
| Output panel "PREVIEW" badge | `PhotonUI/Panels/Mapping/OutputPanel.swift:7` | Status | Hardcoded | **FIXTURE** |
| Mapping overlay corner handles | `PhotonUI/Panels/Mapping/MappingOverlay.swift:22-29`, `:38` | Drag to warp the slice | Decorative `Rectangle`s inside a view with `.allowsHitTesting(false)` | **INERT** |

### Counts

| Verdict | Count |
|---|---|
| **LIVE** | 33 |
| **STORED** | 14 |
| **FIXTURE** | 19 |
| **INERT** | 7 |
| **UNKNOWN** | 0 |
| **Total** | **73** |

Nothing is marked UNKNOWN: every control's call chain terminates in code I read end to end. The
caveat is that this is a static read — the app was **not run** for this audit (six agents are
editing the tree; building it would race them).

---

## 1. Root cause

**`macos/Sources/PhotonApp/PhotonApp.swift:16`.**

```swift
let model = WorkspaceModel(provider: LocalMediaWorkspaceProvider(catalog: catalog), effectDefinitions: NativeEffectDefinitions.all)
```

That is the only place a `WorkspaceProvider` is chosen, and it chooses
`LocalMediaWorkspaceProvider` — which is a 34-line pass-through whose every method forwards to a
`PreviewWorkspaceProvider` (`macos/Sources/PhotonApp/LocalMediaWorkspaceProvider.swift:23-33`),
constructed at `:15`. Its own doc comment admits it: *"Live playback remains explicitly marked
DEMO until Claude supplies the shared runtime adapter."*

**There is no live provider.** `grep -rn ": WorkspaceProvider" macos/Sources` returns exactly two
conformances — `PreviewWorkspaceProvider` (`Services/PreviewWorkspaceProvider.swift:4`, whose
header comment reads *"UI fixtures only: no media decoder, renderer, hardware output, or measured
FPS"*) and the pass-through above. The real path **does not exist**. Every snapshot the UI reads
and every action it writes terminates in actor-local dictionaries on
`PreviewWorkspaceProvider` (`opacities`, `blendModes`, `layerOpacities`, `bypassedLayers`,
`soloLayers`, `activeClips`, `masterOpacity`, `blackedOut`, `effectStacks` — lines 6-21).

**But that is no longer the whole story, and this is the important correction.** A second,
*parallel* path was added in the uncommitted work and it **does** reach the engine:
`ProgramSurfaceFactory.engine(model:)` (`PhotonRenderSurface/EngineSurface.swift:103`) is injected
at `PhotonApp.swift:30`, and `masterPlan(_:)` (`EngineSurface.swift:37`) reads the fixture
snapshots **back out of the view model** and pushes them into a real `PhotonEngine` through
`ProgramMetalView.apply(_:)` (`ProgramMetalView.swift:123`). So the fixture provider is still the
only store of record — it is just that six of its fields are now mirrored into the engine on
every SwiftUI update.

That mirror is **narrow by construction**. `SurfacePlan.Layer` (`EngineSurface.swift:14-20`) carries
`name, url, opacity, bypassed, soloed`; `SurfacePlan` adds `masterOpacity, blackout`. Anything the
operator changes that is not one of those seven values is written to the fixture and stops there.
That single struct is the entire reason for the 14 STORED rows above, and widening it is the
highest-leverage change in this document.

Two structural consequences worth naming:

- **Two engines, not one.** `ProgramMetalView.make(role:)` constructs a fresh `PhotonEngine` per
  call (`ProgramMetalView.swift:37-41`), and `PreviewMonitors` mounts two of them
  (`Panels/Preview/PreviewMonitors.swift:9-10`). The same clip is therefore decoded twice, by two
  independent `VideoSource`s, out of sync with each other. The handover doc explicitly asked to
  avoid this (`docs/codex-claude-handover.md`, "Next engine integration": *"Avoid one fresh
  engine/decoder/compile per `ProgramMetalView.make`"*).
- **Program output is owned by a SwiftUI view's lifetime.** `viewDidMoveToWindow` invalidates the
  display link when the panel detaches (`ProgramMetalView.swift:83-87`). That directly contradicts
  the engine's own stated contract at `Engine.swift:8-9`: *"A UI panel closing, reloading or
  crashing must never change what is on the program output."*

### Divergence from the specified seam

`docs/frontend.md` and `docs/codex-claude-handover.md` are both **stale relative to the code**:

| Doc says | Code says |
|---|---|
| `frontend.md:28` — "Monitors say **DEMO**" | `EngineSurface.swift:104` sets `content: .workspace`, so `PreviewPanel.swift:15` shows dimensions instead |
| `frontend.md:35` — "Effects browser entries are planned/unavailable" | `EffectsBrowser.swift` lists all 37 real `EffectKind` cases and `editable` is `true` (`PreviewWorkspaceProvider+Effects.swift:6`) |
| `codex-claude-handover.md` — "Change the flag to `.workspace` only when the provider and surfaces share real runtime state" | The flag was changed; the provider and surfaces still do **not** share state — the surface reads the provider's output, one way, through the view model |
| `codex-claude-handover.md` — "`ProgramMetalView.mediaURLs` / `loadDefaultComposition`" | Both are gone; replaced by `apply(_ plan:)` |
| `frontend.md:30` — "This does not establish… active projectors" | Still true, and still the single biggest gap |

**Both docs need the same edit in the same breath as any fix here**, per the repo rule that a
reference resolving to nothing is a bug, not a nag.

---

## 2. What the engine already supports that the UI is not calling

`grep -rn "PhotonEngine" macos/Sources` returns **four hits, all inside
`ProgramMetalView.swift`**. The shell touches one class, through one method.

| Engine capability | Where | Called by the shell? |
|---|---|---|
| `setLayers([LayerState])` | `Engine.swift:240` | **Yes** — `ProgramMetalView.swift:131`. The only command the UI issues |
| `LayerState.opacity` | `Engine.swift:26` | **Yes** |
| `LayerState.bypassed` / `.soloed` | `Engine.swift:29,31` | **Yes** |
| `LayerState.clipURL` | `Engine.swift:33` | **Yes** |
| `masterOpacity` | `Engine.swift:183` | **Yes** — `ProgramMetalView.swift:126` |
| `blackout` | `Engine.swift:185` | **Yes** — `ProgramMetalView.swift:127` |
| `LayerState.blend` + 10 `BlendMode`s incl. Difference/Mask/Overlay | `Engine.swift:27`, `Compositor.swift:16` | **No.** `setBlend` is exposed at `ProgramMetalView.swift:145` and called from nowhere. The inspector's 4-mode dropdown is a hardcoded string list (`BlendModeControl.swift:10`) that does not even match the engine's 10 |
| `LayerState.effects: [Effect]` + full `EffectChain` (645 lines, 37 `EffectKind`s) | `Engine.swift:39`, `EffectChain.swift:32` | **No.** `setEffects` (`Engine.swift:281`) is not exposed on `ProgramMetalView` at all. The UI has a complete effects editor writing to a dictionary |
| `deck: Deck(layers:4, columns:8)` + `syncFromDeck()` + `triggerColumn/triggerCell` with **beat quantisation** | `Engine.swift:114,328,342,347` | **No.** The UI reimplements triggering in the fixture (`PreviewWorkspaceProvider+Live.swift:40-55`), unquantised. Launches land on the frame, not the beat |
| `cues: CueList` + `go()` | `Engine.swift:118,335` | **No.** No cue UI exists |
| `beat` / `bpm` / `adoptMusicalTime(beat:bpm:)` | `Engine.swift:132,295,158` | **No.** The UI shows a constant `120` and never reads or writes tempo |
| `patternKind` (test grid / crosshair / colour bars) | `Engine.swift:200`, `Compositor.swift:36-43` | **No.** Three rigging patterns exist, fully shaded, with no UI. The Map workspace draws a **fake** dashed overlay instead (`MappingOverlay.swift`) |
| `topology: OutputTopology` / `slices` / `sliceFailures` | `Engine.swift:209,220,223` + `OutputTopology.swift` (238 lines) + `Warp.swift` (1156 lines) | **No.** The Output panel shows two hardcoded cards. The entire warp/mapping engine is unreachable |
| `telemetry: EngineTelemetry` — real `outputFPS`, `gpuTime`, `cpuTime`, `frameTimeP50/P99`, `sourceRepeats`, `activeLayers`, `effectPasses` | `Engine.swift:202`, surfaced at `ProgramMetalView.swift:35` | **No.** `ProgramMetalView.telemetry` is a public property that **nothing reads**. The status bar instead renders `nil` from the fixture and shows `—` for all three. This is measured, correct data being thrown away |
| `audio: AudioAnalyser` + `startAudioInput()` | `Engine.swift:108,309` | **No.** 229 lines of FFT/band analysis, never started |
| `midi: MidiInput` + `startMidi()` + `pumpMidi()` | `Engine.swift:111,316,351` | **No.** 183 lines, never started. `PhotonApp/ControlRouting.swift` (52 lines) translates MIDI/OSC into core commands and is **imported by nothing** |
| `Recorder.swift` (241 lines), `OSC.swift` (289), `LiveInputs.swift` (209), `ISF.swift` (271) | `engine/Sources/PhotonRender/` | **No.** Zero references from `macos/Sources` |
| `PhotonCoreSession` (Rust core: clock, bindings, modulation) | `photon-ffi/Sources/PhotonCoreBridge/` | **No.** The app calls `PhotonCoreABI.validate()` once at `PhotonApp.swift:18` and never constructs a session. `AudioRouting.swift` and `ControlRouting.swift` are the finished seams for it, both dead code |

### `ThumbnailCache` — correction to the brief

**`ThumbnailCache` is not unreferenced.** It is used at
`macos/Sources/PhotonApp/LocalMediaCatalog.swift:11` and `:54`, backing the real decoded posters
in every grid cell via `LocalClipPoster` → `ClipPosterFactory` (`PhotonApp.swift:30-32`). The grid
artwork Aiden is looking at is genuine first-frame decode of his own `media-cache/*.mp4`, with
serialised generation, a 128-item purge threshold and shared request lifetime
(`LocalMediaCatalog.swift:57-68`). This part of the integration is **done and working** — it should
not be re-done.

---

## 3. Honesty failures, ranked by how badly they mislead mid-performance

**1 — Clip Opacity in the Inspector is a dead fader that looks identical to the live one.**
`InspectorContents.swift:14` renders the exact same `OpacityControl` component as the Layer
inspector's live one (`LayerInspector.swift:12`). Same widget, same label, same percentage readout,
same smooth animation — one changes the output, the other changes a dictionary entry. There is no
visual distinction whatsoever. An operator pulling the wrong one of two identical faders during a
show gets silence from the UI and no change on screen, and has no way to tell which fader was
which. **This is the worst control in the application.**

**2 — Clip Blend silently accepts a mode the engine never sees, and offers the wrong list.**
`BlendModeControl.swift:10` offers `Normal / Add / Multiply / Screen`. The checkmark moves, the
`InspectorSection` header text updates to the new mode (`InspectorContents.swift:13`), and the
composite does not change. Worse: the engine supports **ten** modes including Difference and Mask
(`Compositor.swift:16`), so the UI both lies about what it did and under-sells what the engine can
do. A blend change that visibly "takes" in the UI is the single easiest way to lose a cue.

**3 — Three telemetry readouts that permanently say `—` while real numbers are being measured and
discarded.** `TelemetryReadout.swift:8-10` is wired to a provider that returns `nil` by design
(`PreviewWorkspaceProvider.swift:92`), while `FrameMeter` is computing genuine presented-FPS from
drawable timestamps, real GPU times from completed command buffers, and `sourceRepeats`
(`Engine.swift:517-529`), all reachable at `ProgramMetalView.swift:35`. Mid-show, "—" reads as
"the meter is broken" when the number that would tell you a projector is dropping frames is sitting
one property access away. `Engine.swift:55-63` argues at length that a blank is better than an
invented number — correct, but a blank is *not* better than the number you already have.

**4 — The entire effects editor is a complete, convincing, non-functional UI.** Add, bypass,
amount, secondary parameter, reset, remove, drag-to-reorder and a 37-effect categorised browser
all respond correctly, persist across panel reloads, and validate their inputs
(`PreviewWorkspaceProvider+Effects.swift`). None of it reaches `EffectChain`. It is the largest
single block of UI in the app and it is the least connected.

**5 — "Lock" implies a performance safety that it does not provide.** `MasterControls.swift:8`
reads `Lock`/`Locked` with a padlock and turns amber. It disables persona switching, the layout
menu, and three menu items — and nothing else. Faders, clip triggers, column launches, blackout
and the whole inspector stay live. An operator who locks the surface believing it is now
accident-proof is strictly worse off than one who knows it is not.

**6 — Play/pause is a two-state button over a value nothing reads.** `TransportControls.swift:10`
toggles between ▶ and ❙❙ with full fidelity. Playback is driven by the display link
(`ProgramMetalView.swift:151-154`) and never stops. Pressing pause changes the icon and nothing
else, which is indistinguishable from "pause worked but this clip is a still frame".

**7 — Transform Position / Scale / Rotation are styled as parameters but are three string
literals.** `InspectorContents.swift:18-20` uses `ParameterReadout`, which renders in a raised
control well identical to editable controls. `LayerUniform.offsetScale` exists and is driven only
by the demo sine sweep (`Engine.swift:441-446`); rotation has no term in the shader at all.

**8 — The "UI preview" pill now under-warns.** `WorkspaceHeader.swift:36` is unconditional, so it
cannot distinguish the six controls that *are* live from the fourteen that are not. A blanket
warning that is always on is read as decoration within a day, and it is currently wrong in both
directions at once.

**9 — The Map workspace's corner handles invite a drag that cannot happen.**
`MappingOverlay.swift:22-29` draws four accent-coloured grab handles inside a view with
`.allowsHitTesting(false)` at `:38`. 1,156 lines of real warp maths sit in `Warp.swift`, unreachable.

**10 — Timing risk worth a test, not yet a confirmed bug.** `LiveFader` coalesces to one update per
16 ms and flushes on release (`Components/LiveFader.swift:28-41`); `ControlSnapshotRefresh` then
debounces the snapshot re-read by 80 ms (`Services/ControlSnapshotRefresh.swift:13`). Because the
engine is driven from the *snapshot*, not from the command, a fast fader flick could in principle
leave the engine at a value up to ~96 ms stale, or at the second-to-last value if a reload is
cancelled. I could not determine from reading alone whether the final flush always wins. **Verify
with a test before trusting a fader for a hard cut.**

---

## 4. Ordered fix list

Ranked by restored function per unit of work. Each names the exact seam.

**1. Add `blend` to `SurfacePlan.Layer` and call `engine.setBlend`.**
Seam: `EngineSurface.swift:14-20` (add `var blend: BlendMode`), `:44-53` (populate from the layer
snapshot), `ProgramMetalView.swift:132-138` (pass it into `LayerState`). Then replace
`BlendModeControl.swift:10`'s hardcoded 4-string array with `BlendMode.allCases.map(\.name)` and
move blend out of the clip scope into the **layer** scope, where the engine actually holds it
(`LayerState.blend`, `Engine.swift:27`). *Cost: ~30 lines. Restores 10 blend modes and kills
honesty failure #2.*

**2. Feed real telemetry.** Seam: `ProgramMetalView.telemetry` (`:35`) is already public and
already correct. Expose the master `ProgramMetalView` to the shell (an
`@Observable` box set in `makeNSView`), and have `WorkspaceModel.reloadTelemetry`
(`WorkspaceModel.swift:93`) read it instead of `provider.telemetry()`. Keep `nil` → `—` semantics
exactly as `Engine.swift:55-63` requires. *Cost: ~40 lines. Three dead readouts become the most
useful numbers in the app.*

**3. Route clip-scope Opacity and the Transform rows to the layer that owns the clip — or delete
them.** Seam: `InspectorContents.swift:14`. The engine has exactly one opacity per layer; the UI
invented a second one per clip with nowhere to put it. Either make the clip inspector's Opacity
call `setLayerOpacity` for the layer currently hosting that clip, or remove the control. Do not
leave two identical faders with different behaviour. *Cost: ~15 lines. Kills honesty failure #1 —
do this before any demo.*

**4. Widen the plan for effects.** Seam: add `var effects: [Effect]` to `SurfacePlan.Layer`,
translate `InspectorEffect.definitionID` (already an `EffectKind.rawValue`,
`NativeEffectDefinitions.swift:6`) + `amount` + `parameter` + `enabled` into
`PhotonRender.Effect` inside `EngineSurface.swift`, and pass it through `LayerState.effects`
(`Engine.swift:39`) — the hybrid break-out path at `Engine.swift:471-485` already handles it.
Read `docs/engine-integration-review.md` first; it flags same-size output aliasing and RGB Shift's
spatial-read flag. *Cost: a day. Turns the largest dead UI block in the app into the feature it
looks like.*

**5. Collapse to one engine and detach program output from view lifetime.** Seam:
`ProgramMetalView.make(role:)` (`:37`) — take an injected shared `PhotonEngine` rather than
constructing one, own it at `PhotonApp` scope beside `LocalMediaCatalog`
(`PhotonApp.swift:14-16`), and let each view own only its display link and drawable. This is a
prerequisite for a real projector output, it halves decode cost immediately, it stops the two
monitors drifting out of sync, and it restores the contract written at `Engine.swift:8-9`.
*Cost: ~80 lines, touches the riskiest file. Do it before building anything on top of the engine.*

**Then, in order and each a larger piece:** replace `PreviewWorkspaceProvider`'s trigger logic with
`engine.deck` + `triggerColumn(_:)` so launches quantise to the beat (`Engine.swift:342`); make BPM
a real control bound to `engine.bpm` / `adoptMusicalTime` and add tap; expose `patternKind` as a
rigging control in the Map persona and delete `MappingOverlay`'s fake handles; wire
`OutputTopology` + `Warp` behind the Output panel and build a genuine output window; start
`PhotonCoreSession` and connect the two finished-but-dead seams in `PhotonApp/ControlRouting.swift`
and `PhotonApp/AudioRouting.swift`.

**Finally — and this one costs nothing:** make the "UI preview" pill
(`WorkspaceHeader.swift:36`) conditional, and remove the hardcoded `· UI PREVIEW`
(`ClipMatrixPanel.swift:7`) and `PREVIEW` (`TransportControls.swift:17`,
`OutputPanel.swift:7`) strings as each surface is connected. Update `docs/frontend.md:28,35` and
`docs/codex-claude-handover.md` in the same commit — they currently describe a build that no
longer exists, and the next session will trust them.
