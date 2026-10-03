#!/bin/bash
# Build the persistent playtest drivers. MGBA / NBA point at headless source
# builds of the two reference emulators (override via the environment):
#   mGBA 0.10.5: cmake -DBUILD_STATIC=ON -DBUILD_SHARED=OFF -DBUILD_QT=OFF
#                -DBUILD_SDL=OFF -DM_CORE_GB=OFF -DENABLE_SCRIPTING=OFF ...
#                into $MGBA/build-headless (make mgba)
#   second reference: its normal CMake build in $NBA/build
#
#   build.sh [TARGET...]   only these (mgba_driver nba_driver dingbat_driver
#                          dingbat_driver_trace screenread); default all
#   NIMCACHE=DIR           the dingbat drivers' nimcache (default under
#                          $TMPDIR, shared by every checkout: concurrent
#                          builds each want their own, as train.py gives them)
set -e
cd "$(dirname "$0")/../.."
MGBA=${MGBA:-~/code/mgba-ref-src}
NBA=${NBA:-~/code/NanoBoyAdvance}
OUT=tools/playtest/bin
NIMCACHE=${NIMCACHE:-${TMPDIR:-/tmp}/nimcache-playtest-driver}
mkdir -p "$OUT"
TARGETS=" ${*:-mgba_driver nba_driver dingbat_driver dingbat_driver_trace screenread} "
want() { [[ "$TARGETS" == *" $1 "* ]]; }

if want mgba_driver; then
echo "== mgba_driver"
cc -O2 -std=gnu11 -pthread \
   -I"$MGBA/include" -I"$MGBA/src" -I"$MGBA/build-headless/include" \
   tools/playtest/drivers/mgba_driver.c \
   "$MGBA/build-headless/libmgba.a" \
   -lz -lpng -lm -framework Foundation -L/opt/homebrew/lib \
   -o "$OUT/mgba_driver"
fi

if want nba_driver; then
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
fi

if want dingbat_driver; then
echo "== dingbat_driver"
nim c -d:test_harness -d:release --path:src --hints:off \
   --nimcache:"$NIMCACHE" \
   -o:"$OUT/dingbat_driver" tools/playtest/drivers/dingbat_driver.nim
fi

# The same driver with the core's passive I/O write hooks compiled in, for
# `apulog` (select it with PLAYTEST_DINGBAT_DRIVER=.../dingbat_driver_trace)
if want dingbat_driver_trace; then
echo "== dingbat_driver_trace"
nim c -d:test_harness -d:release -d:biosdrvtrace --path:src --hints:off \
   --nimcache:"$NIMCACHE-trace" \
   -o:"$OUT/dingbat_driver_trace" tools/playtest/drivers/dingbat_driver.nim
fi

if want screenread; then
echo "== screenread"
swiftc -O tools/playtest/screenread.swift -o "$OUT/screenread"
fi

echo "built:$TARGETS"
