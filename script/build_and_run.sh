#!/usr/bin/env bash
set -euo pipefail

PHOTON_MODE="${1:-run}"
PHOTON_CONFIGURATION="${PHOTON_BUILD_CONFIGURATION:-debug}"
PHOTON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHOTON_PACKAGE="$PHOTON_ROOT/macos"
PHOTON_BUNDLE="$PHOTON_PACKAGE/.build/local-app/Photon.app"
PHOTON_CONTENTS="$PHOTON_BUNDLE/Contents"
PHOTON_BINARY="$PHOTON_CONTENTS/MacOS/Photon"
PHOTON_BUNDLE_ID="com.aidxn.photon.preview"

case "$PHOTON_MODE" in
  run|--debug|--logs|--telemetry|--verify) ;;
  *) echo "Usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

# Only restart this checkout's local UI preview, never a different Photon app.
photon_owned_pids() {
  /bin/ps -axo pid=,command= | /usr/bin/python3 -c '
import sys
binary = sys.argv[1]
for line in sys.stdin:
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and (fields[1] == binary or fields[1].startswith(binary + " ")):
        print(fields[0])
' "$PHOTON_BINARY"
}

# Keep the running preview usable if an in-progress source edit fails to build.
cargo build --release --locked --manifest-path "$PHOTON_ROOT/photon-ffi/Cargo.toml"
swift build --package-path "$PHOTON_PACKAGE" --configuration "$PHOTON_CONFIGURATION"
PHOTON_BUILD_DIR="$(swift build --package-path "$PHOTON_PACKAGE" --configuration "$PHOTON_CONFIGURATION" --show-bin-path)"
"$PHOTON_BUILD_DIR/PhotonCoreCheck"

PHOTON_ICON_DIR="$PHOTON_PACKAGE/.build/branding"
mkdir -p "$PHOTON_ICON_DIR"
if [[ ! -f "$PHOTON_ICON_DIR/Photon.icns" || "$PHOTON_ROOT/script/render_app_icon.swift" -nt "$PHOTON_ICON_DIR/Photon.icns" ]]; then
  swift "$PHOTON_ROOT/script/render_app_icon.swift" "$PHOTON_ICON_DIR/Photon.iconset"
  /usr/bin/iconutil -c icns "$PHOTON_ICON_DIR/Photon.iconset" -o "$PHOTON_ICON_DIR/Photon.icns"
fi

while IFS= read -r photon_pid; do
  [[ -z "$photon_pid" ]] || kill "$photon_pid" 2>/dev/null || true
done < <(photon_owned_pids)

mkdir -p "$PHOTON_CONTENTS/MacOS"
mkdir -p "$PHOTON_CONTENTS/Resources"
cp "$PHOTON_BUILD_DIR/Photon" "$PHOTON_BINARY"
cp "$PHOTON_ICON_DIR/Photon.icns" "$PHOTON_CONTENTS/Resources/Photon.icns"
chmod +x "$PHOTON_BINARY"

# Development media prepared by the engine owner. Reading bundle resources
# avoids an implicit Desktop-folder access request during GUI startup.
if [[ -d "$PHOTON_ROOT/media-cache" ]]; then
  mkdir -p "$PHOTON_CONTENTS/Resources/DevelopmentMedia"
  /usr/bin/rsync -rt --delete --include='*.mp4' --exclude='*' \
    "$PHOTON_ROOT/media-cache/" "$PHOTON_CONTENTS/Resources/DevelopmentMedia/"
fi

cat > "$PHOTON_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Photon</string>
  <key>CFBundleIdentifier</key><string>$PHOTON_BUNDLE_ID</string>
  <key>CFBundleName</key><string>Photon</string>
  <key>CFBundleDisplayName</key><string>Photon</string>
  <key>CFBundleIconFile</key><string>Photon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# SwiftPM signs the executable, but the completed GUI bundle needs its own
# resource seal after staging Info.plist. Keep this local development ad-hoc.
/usr/bin/codesign --force --sign - "$PHOTON_BUNDLE"
/usr/bin/codesign --verify --strict "$PHOTON_BUNDLE"

photon_open_app() { /usr/bin/open -n "$PHOTON_BUNDLE"; }

case "$PHOTON_MODE" in
  run) photon_open_app ;;
  --debug) lldb -- "$PHOTON_BINARY" ;;
  --logs)
    photon_open_app
    /usr/bin/log stream --info --style compact --predicate 'process == "Photon"'
    ;;
  --telemetry)
    photon_open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$PHOTON_BUNDLE_ID\""
    ;;
  --verify)
    photon_open_app
    for photon_attempt in {1..50}; do
      if [[ -n "$(photon_owned_pids)" ]]; then
        # A briefly spawned process is not a usable launch. Allow the scene and
        # native surface to initialise, then check this checkout again.
        sleep 2
        if [[ -z "$(photon_owned_pids)" ]]; then
          echo "Photon exited during startup." >&2
          exit 1
        fi
        echo "Photon UI preview is running: $PHOTON_BUNDLE"
        exit 0
      fi
      sleep 0.1
    done
    echo "Photon UI preview did not start." >&2
    exit 1
    ;;
esac
