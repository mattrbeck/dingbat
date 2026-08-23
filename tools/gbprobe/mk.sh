#!/bin/bash
# Assemble, link and header-fix one probe source.
#
#   ./mk.sh <name> [rgbasm-defines...]
#
# <name> is a file in roms/ without the .asm, and the outputs are
# build/<name>.{o,gb,sym} plus a copy of the .gb beside the sources.
#
# The checksums must be right or a real Game Boy refuses to boot the cart,
# and the CGB flag decides which machine the probe measures.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RGBDS="$ROOT/.scratch/rgbds"
# GBPROBE_OUT renames the outputs, so one source can be built at several sets
# of -D values and every variant keeps its own .gb (probe (c) at three SCX).
NAME="$1"; shift
OUT="${GBPROBE_OUT:-$NAME}"
mkdir -p "$HERE/build"

# GBPROBE_CGB overrides the flag: 0 = no CGB flag (a CGB runs the cart in
# DMG-compatibility mode), 1 = CGB-aware.
if [ -n "$GBPROBE_CGB" ]; then
  [ "$GBPROBE_CGB" = "0" ] && CGBFLAG="" || CGBFLAG="-c"
else
  case "$NAME" in
    # probe (c) reads BGP, which is only live in DMG-compatibility mode.
    probe_c_*) CGBFLAG="" ;;
    *)         CGBFLAG="-c" ;;
  esac
fi

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
