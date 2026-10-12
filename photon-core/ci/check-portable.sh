#!/usr/bin/env bash
# photon-core portability guard — R0 #2.
#
# Enforces the hard rule from docs/scaffold.md §4:
#   "No Apple API in photon-core" — and per Codex's amendment, a short crate-name
#   deny-list alone is insufficient. This checks three independent ways:
#     1. RESOLVED dependency graph (catches renamed/aliased crates)
#     2. Source-level FFI and framework linkage
#     3. A genuinely portable build for a non-Apple target
#
# Must FAIL on a deliberate violation. Prove it with:  ci/check-portable.sh --self-test
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
FAIL=0
SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

# Package families that must never appear in the resolved graph.
# Matched against the RESOLVED package name, so `foo = { package = "objc2" }`
# is still caught.
DENY_EXACT="objc block blocks dispatch cocoa cocoa-foundation core-foundation \
core-foundation-sys core-graphics core-graphics-types core-video core-video-sys \
core-media core-text io-surface io-kit-sys metal metal-rs mach mach2 \
security-framework system-configuration \
windows windows-sys windows-core winapi ntapi \
wgpu wgpu-core wgpu-hal ash d3d12 glow gl glutin vulkano \
ffmpeg-sys ffmpeg-sys-next ffmpeg-next rusty_ffmpeg"

# Prefix families (covers objc2-*, windows-*, icrate, etc.)
DENY_PREFIX="objc2 icrate windows- apple- core- metal- wgpu- ffmpeg av-"

echo "── 1/3  resolved dependency graph ──────────────────────────────"
if ! command -v cargo >/dev/null; then red "cargo not found"; exit 2; fi

META=$(cargo metadata --format-version 1 --all-features 2>/dev/null) || {
  red "FAIL  cargo metadata failed (does the crate build?)"; exit 2; }

# Every package in the resolved graph except ourselves.
PKGS=$(printf '%s' "$META" \
  | /usr/bin/python3 -c '
import json,sys
m=json.load(sys.stdin)
for p in m.get("packages",[]):
    if p["name"]!="photon-core":
        print(p["name"])
' | sort -u)

HITS=""
for p in $PKGS; do
  for d in $DENY_EXACT; do
    [ "$p" = "$d" ] && HITS="$HITS $p"
  done
  for d in $DENY_PREFIX; do
    case "$p" in "$d"*) HITS="$HITS $p";; esac
  done
done
HITS=$(printf '%s' "$HITS" | tr ' ' '\n' | sed '/^$/d' | sort -u)

if [ -n "$HITS" ]; then
  red "FAIL  non-portable packages in the resolved graph:"
  printf '        %s\n' $HITS
  echo "        → move this behind a shell-side adapter (macos/ or photon-windows/)"
  FAIL=1
else
  grn "OK    $(printf '%s' "$PKGS" | grep -c . 2>/dev/null || echo 0) resolved packages, none denied"
fi

echo "── 2/3  source-level FFI / framework linkage ───────────────────"
# Apple frameworks are linked via #[link(.., kind="framework")] or build.rs
# emitting cargo:rustc-link-lib=framework=…
SRC_HITS=$(grep -rnE \
  'kind *= *"framework"|rustc-link-lib=framework|rustc-link-search=framework|#\[link\(|extern *"C"' \
  src/ build.rs 2>/dev/null || true)
if [ -n "$SRC_HITS" ]; then
  red "FAIL  source declares native linkage or FFI:"
  printf '%s\n' "$SRC_HITS" | sed 's/^/        /'
  FAIL=1
else
  grn "OK    no #[link], no extern \"C\", no framework linkage in src/"
fi

echo "── 3/3  portable (non-Apple) target build ──────────────────────"
# The strongest check: if it compiles for a target with no OS and no Apple
# frameworks, it cannot be depending on them.
TARGET="wasm32-unknown-unknown"
if rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
  if cargo check --quiet --target "$TARGET" --all-features 2>/tmp/photon-portable.log; then
    grn "OK    builds for $TARGET"
  else
    red "FAIL  does not build for $TARGET:"
    sed 's/^/        /' /tmp/photon-portable.log | head -20
    FAIL=1
  fi
else
  ylw "SKIP  $TARGET not installed — run: rustup target add $TARGET"
  ylw "      (this check is required in CI; skipping locally is not a pass)"
fi

# ── self-test: the guard is worthless unless a violation actually fails ──────
if [ "$SELF_TEST" = "1" ]; then
  echo "── self-test  injecting a deliberate violation ─────────────────"
  cp Cargo.toml /tmp/photon-Cargo.toml.bak
  printf '\ncore-foundation = "0.10"\n' >> Cargo.toml
  if "$0" >/tmp/photon-selftest.log 2>&1; then
    red  "SELF-TEST FAILED  the guard PASSED a deliberate violation."
    red  "                  The check is not doing its job."
    cp /tmp/photon-Cargo.toml.bak Cargo.toml
    exit 3
  else
    grn "SELF-TEST OK      guard correctly rejected an injected core-foundation dep"
  fi
  cp /tmp/photon-Cargo.toml.bak Cargo.toml
  rm -f /tmp/photon-Cargo.toml.bak
fi

echo
if [ "$FAIL" = "0" ]; then grn "photon-core is portable."; else red "photon-core portability guard FAILED."; fi
exit $FAIL
