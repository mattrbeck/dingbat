#!/bin/sh
# Builds the dingbat emulator core as iOS static libraries:
#
#   ios/lib/iphoneos/libdingbat.a          arm64 device
#   ios/lib/iphonesimulator/libdingbat.a   arm64 simulator
#
# from src/dingbat_ios.nim (C API; header: ios/include/dingbat.h). The Xcode
# project links lib/$(PLATFORM_NAME)/libdingbat.a, so both slices coexist
# without an XCFramework (fine for local dev; wrap in an XCFramework for
# distribution).
#
# Usage: ios/build-core.sh              (both slices)
#        ios/build-core.sh sim|device   (one slice)
# Env:   NIMCACHE=<dir>  nimcache root (default /tmp/dingbat-ios-nimcache)
#        OUT=<dir>       output root   (default ios/lib)
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SIMSDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=${OUT:-$REPO/ios/lib}
NIMCACHE=${NIMCACHE:-/tmp/dingbat-ios-nimcache}
MINVER=16.0
# The app targets iOS 16, whose oldest devices have the A11; naming it turns
# on the CRC instructions zippy's crc32 uses (the generic arm64 target lacks
# them, and the simulator's Apple-silicon default has them).
DEVICE_CPU=-mcpu=apple-a11
ONLY=${1:-all}

build_slice() {
  # $1 = sdk path, $2 = target triple, $3 = output subdir, $4 = extra cflags
  # Flags pinned explicitly (mm/threads also live in nim.cfg, but that file
  # is not picked up when compiling from outside the repo — keep them here).
  # No -d:test_harness: the APUs take their audio-queue path, and
  # common/audio_out.nim's iOS calls are src/dingbat_ios_audio.c inside the lib.
  mkdir -p "$OUT/$3"
  nim c --app:staticlib --noMain --os:ios --cpu:arm64 --cc:clang \
    -d:release -d:noSignalHandler --mm:arc --threads:off \
    --path:"$REPO/src" \
    --nimcache:"$NIMCACHE/$3" \
    --passC:"-isysroot $1 -target $2 ${4:-}" \
    --passL:"-isysroot $1 -target $2" \
    -o:"$OUT/$3/libdingbat.a" "$REPO/src/dingbat_ios.nim"
}

case "$ONLY" in
  device) build_slice "$SDK" "arm64-apple-ios$MINVER" iphoneos "$DEVICE_CPU" ;;
  sim)    build_slice "$SIMSDK" "arm64-apple-ios$MINVER-simulator" iphonesimulator ;;
  all)
    build_slice "$SDK" "arm64-apple-ios$MINVER" iphoneos "$DEVICE_CPU"
    build_slice "$SIMSDK" "arm64-apple-ios$MINVER-simulator" iphonesimulator
    ;;
  *) echo "usage: $0 [device|sim]" >&2; exit 2 ;;
esac

echo "--- artifacts ---"
find "$OUT" -name 'libdingbat.a' -exec file {} \;
