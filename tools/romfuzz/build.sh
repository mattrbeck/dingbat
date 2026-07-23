#!/bin/bash
# Build the three headless runners for cross-emulator screenshot comparison.
set -e
cd "$(dirname "$0")/../.."
MGBA=~/code/mgba-ref-src
NBA=~/code/NanoBoyAdvance

echo "== mgba_runner"
cc -O2 -std=gnu11 -pthread \
   -I"$MGBA/include" -I"$MGBA/src" -I"$MGBA/build-headless/include" \
   tools/romfuzz/mgba_runner.c \
   "$MGBA/build-headless/libmgba.a" \
   -lz -lpng -lm -framework Foundation -L/opt/homebrew/lib \
   -o tools/romfuzz/mgba_runner

echo "== nba_runner"
c++ -O2 -std=c++17 \
   -I"$NBA/src/nba/include" -I"$NBA/src/platform/core/include" \
   -I"$NBA/build/_deps/fmt-src/include" \
   tools/romfuzz/nba_runner.cpp \
   "$NBA/build/src/platform/core/libplatform-core.a" \
   "$NBA/build/src/nba/libnba.a" \
   "$NBA/build/_deps/fmt-build/libfmt.a" \
   "$NBA/build/_deps/unarr-build/libunarr.a" \
   -lz -o tools/romfuzz/nba_runner

echo "== dingbat_nav"
nim c -d:test_harness -d:release --path:src --hints:off \
   -o:tools/romfuzz/dingbat_nav tools/romfuzz/dingbat_nav.nim

echo "all built"
