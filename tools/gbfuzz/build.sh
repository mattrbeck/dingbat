#!/bin/bash
# Build the three headless GB/GBC runners for cross-emulator comparison.
#
# Prerequisites, all outside this repo (ROMs and boot ROMs must never be
# committed here):
#   ~/code/SameBoy         git clone https://github.com/LIJI32/SameBoy && make lib
#   ~/code/mgba-ref-src    mGBA 0.10.5 source with a build-headless/ CMake build,
#                          patched so GBIsBIOS() returns true when GBFUZZ_ANY_BIOS
#                          is set (mGBA otherwise CRC-rejects any boot ROM that
#                          is not a Nintendo dump, silently falling back to
#                          skip-boot and drifting out of phase with the others)
#   <workdir>/boot/{dmg,cgb}_boot.bin   SameBoy's own boot ROMs, e.g. from
#                          SameBoy.app/Contents/Resources or `make bootroms`
set -e
cd "$(dirname "$0")/../.."
MGBA=~/code/mgba-ref-src
SAMEBOY=~/code/SameBoy

echo "== sameboy_runner"
cc -O2 -std=gnu11 -I"$SAMEBOY" -D_GNU_SOURCE -DGB_VERSION='"1.0.3"' \
   tools/gbfuzz/sameboy_runner.c \
   "$SAMEBOY/build/lib/libsameboy.a" \
   -lm -o tools/gbfuzz/sameboy_runner

echo "== mgba_gb_runner"
cc -O2 -std=gnu11 -pthread \
   -I"$MGBA/include" -I"$MGBA/src" -I"$MGBA/build-headless/include" \
   tools/gbfuzz/mgba_gb_runner.c \
   "$MGBA/build-headless/libmgba.a" \
   -lz -lpng -lm -framework Foundation -L/opt/homebrew/lib \
   -o tools/gbfuzz/mgba_gb_runner

echo "== dingbat_gb_nav"
nim c -d:release --path:src --hints:off \
   -o:tools/gbfuzz/dingbat_gb_nav tools/gbfuzz/dingbat_gb_nav.nim

echo "all built"
