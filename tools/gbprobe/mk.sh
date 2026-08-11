#!/bin/bash
# Assemble, link and header-fix one probe source.
#
#   ./mk.sh <name> [rgbasm-defines...]
#
# <name> is a file in roms/ without the .asm, and the outputs are
# build/<name>.{o,gb,sym} plus a copy of the .gb beside the sources.
#
# The header flags are not decoration. These ROMs are meant to be burned to a
# flash cartridge, so the global and header checksums have to be right or a
# real Game Boy refuses to boot them; and the CGB flag decides which MACHINE
# the probe measures, which for probe (c) is the whole experiment (see its
# header comment).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RGBDS="$ROOT/.scratch/rgbds"
# GBPROBE_OUT renames the outputs, so one source can be built at several sets
# of -D values and every variant keeps its own .gb (probe (c) at three SCX).
NAME="$1"; shift
OUT="${GBPROBE_OUT:-$NAME}"
mkdir -p "$HERE/build"

case "$NAME" in
  # probe (c) must run the CGB's PPU in DMG-COMPATIBILITY mode, because BGP --
  # daid's emission ruler -- is only live there. A cart with no CGB flag is
  # what selects that mode, and the same cart runs natively on a DMG.
  probe_c_*) CGBFLAG="" ;;
  *)         CGBFLAG="-c" ;;
esac

"$RGBDS/rgbasm" -I "$HERE/roms" "$@" -o "$HERE/build/$OUT.o" "$HERE/roms/$NAME.asm"
"$RGBDS/rgblink" -o "$HERE/build/$OUT.gb" -n "$HERE/build/$OUT.sym" \
                 -p 0xFF "$HERE/build/$OUT.o"
"$RGBDS/rgbfix" -v $CGBFLAG -p 0xFF -m 0x00 -r 0 -k 00 -l 0x33 \
                -t "$(echo "$OUT" | tr 'a-z_' 'A-Z ' | cut -c1-11)" \
                "$HERE/build/$OUT.gb"
# The .sym goes next to the .gb: readout.py lifts the font glyphs out of the
# ROM image using it, so a committed .gb is only readable with its .sym.
cp "$HERE/build/$OUT.gb" "$HERE/$OUT.gb"
cp "$HERE/build/$OUT.sym" "$HERE/$OUT.sym"
echo "$HERE/$OUT.gb"
