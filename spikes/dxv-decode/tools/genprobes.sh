#!/usr/bin/env bash
# Regenerate the heavy probe set (probes2/) - gitignored, deterministic enough to re-make.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p probes2
gen() { ffmpeg -y -v error -f lavfi -i "$2" -frames:v "${3:-1}" -c:v dxv -pix_fmt rgba "probes2/$1.mov"; }
for s in 8x8 12x12 16x16 20x20 24x24 28x28 36x36 40x24 64x48 100x100 854x480 1280x720 1920x1080; do
  gen "sz_$s" "testsrc2=s=$s:d=0.1:r=1"
done
gen testsrc1080 "testsrc2=s=1920x1080:d=1:r=5" 5
gen smpte720    "smptehdbars=s=1280x720:d=1:r=5" 5
gen noise1080   "nullsrc=s=1920x1080:d=0.2:r=5,geq=random(1)*255:random(2)*255:random(3)*255"
gen gradients   "gradients=s=800x600:d=1:r=5" 5
gen rgbtest     "rgbtestsrc=s=640x360:d=1:r=5" 5
gen allrgb      "allrgb=d=0.2:r=5"
echo "probes2/ regenerated"
