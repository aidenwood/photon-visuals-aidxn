#!/usr/bin/env bash
set -euo pipefail

PHOTON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHOTON_CONFIGURATION="${PHOTON_BUILD_CONFIGURATION:-debug}"
PHOTON_PACKAGE="$PHOTON_ROOT/macos"
cargo build --release --locked --manifest-path "$PHOTON_ROOT/photon-ffi/Cargo.toml"
swift build --package-path "$PHOTON_PACKAGE" --configuration "$PHOTON_CONFIGURATION"
PHOTON_BIN="$(swift build --package-path "$PHOTON_PACKAGE" --configuration "$PHOTON_CONFIGURATION" --show-bin-path)"

# SwiftPM can retain object files for removed views. Use its current source map,
# not an object-directory glob that links obsolete implementations back in.
PHOTON_UI_OBJECTS=()
while IFS= read -r photon_object; do
  PHOTON_UI_OBJECTS+=("$photon_object")
done < <(/usr/bin/python3 - "$PHOTON_BIN/PhotonUI.build/output-file-map.json" <<'PY'
import json, sys
for source, outputs in json.load(open(sys.argv[1])).items():
    if source and outputs.get('object'):
        print(outputs['object'])
PY
)

# No XCTest/Swift Testing dependency: compile the same test cases into a local runner.
swiftc -parse-as-library -swift-version 6 \
  -I "$PHOTON_BIN/Modules" \
  "${PHOTON_UI_OBJECTS[@]}" \
  "$PHOTON_PACKAGE/Tests/PhotonUITests/PanelModelTests.swift" \
  "$PHOTON_PACKAGE/Tests/PhotonUITests/SnapshotValidationTests.swift" \
  "$PHOTON_PACKAGE/Tests/PhotonUITests/WorkspaceControlTests.swift" \
  "$PHOTON_PACKAGE/Tests/PhotonUITests/RecoveryCases.swift" \
  "$PHOTON_PACKAGE/Checks/RunChecks.swift" \
  -o "$PHOTON_BIN/PhotonUIChecks"
"$PHOTON_BIN/PhotonUIChecks"
