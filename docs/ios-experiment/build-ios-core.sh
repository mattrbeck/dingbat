#!/bin/sh
# Reproduces the iOS cross-compile experiments from docs/ios-feasibility.md
# (2026-07-10). Run from the repo root on a Mac with Xcode.app installed.
#
# Produces, under $OUT:
#   dingbat_test_ios       arm64 iOS *device* binary of the SDL-free test harness
#   dingbat_test_iossim    arm64 iOS *simulator* binary of the same
#   libdingbat_core.a      arm64 iOS device static lib exporting the C API in
#                          docs/ios-experiment/ios_core_api.nim
#   libdingbat_core_sim.a  simulator variant of the static lib
#   driver_sim             docs/ios-experiment/driver.c linked against the sim lib
#
# Verify / run (simulator must be booted, e.g. `xcrun simctl boot "iPhone 17 Pro"`):
#   xcrun simctl spawn booted $OUT/dingbat_test_iossim <rom.gba> --mode=mgba-suite --timeout=36000
#   xcrun simctl spawn booted $OUT/driver_sim <rom.gba>
set -eu

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SIMSDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=${OUT:-/tmp/dingbat-ios-experiment}
MINVER=15.0
mkdir -p "$OUT"

# 1. SDL-free test harness -> arm64 iOS device executable (proves the core compiles)
nim c --os:ios --cpu:arm64 --cc:clang -d:test_harness -d:release --path:src \
  --nimcache:"$OUT/cache-device" \
  --passC:"-isysroot $SDK -target arm64-apple-ios$MINVER" \
  --passL:"-isysroot $SDK -target arm64-apple-ios$MINVER" \
  -o:"$OUT/dingbat_test_ios" tests/dingbat_test.nim

# 2. Same, for the arm64 simulator (runnable on this Mac via simctl spawn)
nim c --os:ios --cpu:arm64 --cc:clang -d:test_harness -d:release --path:src \
  --nimcache:"$OUT/cache-sim" \
  --passC:"-isysroot $SIMSDK -target arm64-apple-ios$MINVER-simulator" \
  --passL:"-isysroot $SIMSDK -target arm64-apple-ios$MINVER-simulator" \
  -o:"$OUT/dingbat_test_iossim" tests/dingbat_test.nim

# 3. Static library with a C API (the Swift-shell architecture), device + sim.
#    -d:test_harness keeps the APU from binding SDL audio; a real port widens
#    the APU gate to an ios_shell define and reuses the wasm audio ring.
for tgt in device sim; do
  if [ "$tgt" = device ]; then tsdk=$SDK; ttriple="arm64-apple-ios$MINVER"; lib=libdingbat_core.a
  else tsdk=$SIMSDK; ttriple="arm64-apple-ios$MINVER-simulator"; lib=libdingbat_core_sim.a; fi
  nim c --app:staticlib --noMain --os:ios --cpu:arm64 --cc:clang \
    -d:test_harness -d:release -d:noSignalHandler --mm:arc --threads:off --path:src \
    --nimcache:"$OUT/cache-staticlib-$tgt" \
    --passC:"-isysroot $tsdk -target $ttriple" \
    --passL:"-isysroot $tsdk -target $ttriple" \
    -o:"$OUT/$lib" docs/ios-experiment/ios_core_api.nim
done

# 4. Link the C driver against the simulator lib (proves a plain-C/Swift
#    consumer links with no Nim toolchain involvement)
clang -target "arm64-apple-ios$MINVER-simulator" -isysroot "$SIMSDK" -O2 \
  docs/ios-experiment/driver.c "$OUT/libdingbat_core_sim.a" -o "$OUT/driver_sim"

echo "--- artifacts ---"
file "$OUT/dingbat_test_ios" "$OUT/dingbat_test_iossim" "$OUT/driver_sim"
nm -gU "$OUT/libdingbat_core.a" | grep dingbat_ | sort
