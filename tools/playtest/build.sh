#!/bin/bash
# Build the persistent playtest drivers. MGBA / NBA point at headless source
# builds of the two reference emulators (override via the environment):
#   mGBA 0.10.5: cmake -DBUILD_STATIC=ON -DBUILD_SHARED=OFF -DBUILD_QT=OFF
#                -DBUILD_SDL=OFF -DM_CORE_GB=OFF -DENABLE_SCRIPTING=OFF ...
#                into $MGBA/build-headless (make mgba)
#   second reference: its normal CMake build in $NBA/build
set -e
cd "$(dirname "$0")/../.."
MGBA=${MGBA:-~/code/mgba-ref-src}
NBA=${NBA:-~/code/NanoBoyAdvance}
OUT=tools/playtest/bin
mkdir -p "$OUT"

echo "== mgba_driver"
cc -O2 -std=gnu11 -pthread \
   -I"$MGBA/include" -I"$MGBA/src" -I"$MGBA/build-headless/include" \
   tools/playtest/drivers/mgba_driver.c \
   "$MGBA/build-headless/libmgba.a" \
   -lz -lpng -lm -framework Foundation -L/opt/homebrew/lib \
   -o "$OUT/mgba_driver"

echo "== nba_driver"
c++ -O2 -std=c++17 \
   -I"$NBA/src/nba/include" -I"$NBA/src/platform/core/include" \
   -I"$NBA/build/_deps/fmt-src/include" -I"$NBA/build/_deps/toml11-src" \
   tools/playtest/drivers/nba_driver.cpp \
   "$NBA/build/src/platform/core/libplatform-core.a" \
   "$NBA/build/src/nba/libnba.a" \
   "$NBA/build/_deps/fmt-build/libfmt.a" \
   "$NBA/build/_deps/unarr-build/libunarr.a" \
   -lz -o "$OUT/nba_driver"

echo "== dingbat_driver"
nim c -d:test_harness -d:release --path:src --hints:off \
   --nimcache:"${TMPDIR:-/tmp}/nimcache-playtest-driver" \
   -o:"$OUT/dingbat_driver" tools/playtest/drivers/dingbat_driver.nim

echo "== screenread"
swiftc -O tools/playtest/screenread.swift -o "$OUT/screenread"

echo "all built"
