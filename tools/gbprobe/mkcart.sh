#!/bin/bash
# Assemble a probe that needs a REAL MBC, which mk.sh cannot do: it fixes every
# header to $00 (ROM ONLY), and a ROM-only cart has no $A000 window and no RTC,
# so rtcrate would read open bus on hardware and wramscan could not persist.
#
#   ./mkcart.sh <name> <mbc-hex> <ram-code> [rgbasm-defines...]
#
# e.g. ./mkcart.sh rtcrate 0x10 2      MBC3+TIMER+RAM+BATTERY, 8 KB RAM
#      ./mkcart.sh wramscan 0x00 0     ROM only
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RGBDS="$ROOT/.scratch/rgbds"
NAME="$1"; MBC="$2"; RAM="$3"; shift 3
mkdir -p "$HERE/build"

"$RGBDS/rgbasm" -I "$HERE/roms" "$@" -o "$HERE/build/$NAME.o" "$HERE/roms/$NAME.asm"
"$RGBDS/rgblink" -o "$HERE/build/$NAME.gb" -n "$HERE/build/$NAME.sym" \
                 -p 0xFF "$HERE/build/$NAME.o"
# -v computes both checksums, which a real Game Boy's boot ROM enforces.
"$RGBDS/rgbfix" -v -p 0xFF -m "$MBC" -r "$RAM" -k 00 -l 0x33 \
                -t "$(echo "$NAME" | tr 'a-z_' 'A-Z ' | cut -c1-11)" \
                "$HERE/build/$NAME.gb"
cp "$HERE/build/$NAME.gb" "$HERE/$NAME.gb"
cp "$HERE/build/$NAME.sym" "$HERE/$NAME.sym"
echo "$HERE/$NAME.gb"
