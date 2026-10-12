# Photon for macOS

Native SwiftUI front end. Swift 6; macOS 15 or later.

From the Photon project root, run:

```sh
./script/build_and_run.sh
```

The local bundle is `macos/.build/local-app/Photon.app`. The Codex Run button uses that script.
Build without launching: `swift build --package-path macos`.

`Sources/PhotonApp/` contains the small application entry point.
`Sources/PhotonUI/` contains individual panels, controls, loading/retry components, observable
presentation models and provider interfaces. Each panel owns its recovery state.

Perform/Map and Studio/Focus switch the workspace layout. Clip selection, opacity, blend choice,
preview transport, native menu shortcuts and the command palette work against the preview provider.
UI artwork and output configuration are fixtures; actual playback needs Claude's native adapter.

[Frontend ownership and integration](../docs/frontend.md).
