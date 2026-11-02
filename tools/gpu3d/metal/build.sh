#!/bin/sh
# Builds tools/gpu3d/metal's harness (main.swift): the iOS app's core
# library (src/dingbat_ios.nim) for macOS, linked with the app's Metal
# renderer (ios/Dingbat/Sources/NdsGpu3d*.swift).
#
#   tools/gpu3d/metal/build.sh        -> $OUT/ndsmetal (default /tmp/ndsmetal)
# Env: OUT=<dir>, NIMCACHE=<dir>
#
# -d:test_harness gives the core library the iOS audio ring on macOS (the
# harness never drains it: no sound). The flags are otherwise the iOS
# build's (ios/build-core.sh).
set -eu
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
OUT=${OUT:-/tmp/ndsmetal}
NIMCACHE=${NIMCACHE:-$OUT/nimcache}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p "$OUT"
nim c --app:staticlib --noMain -d:release -d:noSignalHandler --mm:arc --threads:off \
  -d:test_harness --hints:off --warnings:off --path:"$REPO/src" \
  --nimcache:"$NIMCACHE" -o:"$OUT/libdingbat_mac.a" "$REPO/src/dingbat_ios.nim"
xcrun swiftc -O -import-objc-header "$REPO/ios/include/dingbat.h" \
  "$REPO/tools/gpu3d/metal/main.swift" \
  "$REPO/ios/Dingbat/Sources/NdsGpu3d.swift" "$REPO/ios/Dingbat/Sources/NdsGpu3dShader.swift" \
  -L"$OUT" -ldingbat_mac -framework Metal -framework AudioToolbox \
  -o "$OUT/ndsmetal"
echo "$OUT/ndsmetal"
