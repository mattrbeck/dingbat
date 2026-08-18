#!/usr/bin/env bash
# probe_e_compare -- dingbat against SameBoy on probe (e), settings by settings.
#
# WHY SAMEBOY IS ALLOWED TO BE THE ORACLE HERE. It normally is not: Pan Docs
# and datasheets are the spec, and other emulators are cross-checks. But for
# this one probe SameBoy was measured against the GBA SP on all eight
# photographed settings and reproduced the staircase column for column -- five
# of the eight byte for byte, the other three differing only in the last band,
# where the photograph's own perspective drift is worth a pixel. That is a
# stronger agreement than any single photograph can establish on its own, and
# it means the rest of the sweep no longer needs a hardware session: a setting
# SameBoy and dingbat disagree on is a setting worth a photograph, and one they
# agree on is not.
#
#   tools/gbprobe/probe_e_compare.sh [--dmg] [SCX ...]
#
# Sweeps object X = OFF, 0..7 at each SCX given (default 0 4 7) and prints the
# two staircases wherever they differ. Build dingbat_test with whatever knob is
# under test first; this script only reads it.
set -uo pipefail
cd "$(dirname "$0")/../.."
# SameBoy's runner is hardcoded to GB_MODEL_CGB_E, and dingbat defaults
# to CGB-C. Every comparison here must therefore force rev E or it is
# measuring the CGB-C/CGB-D palette-step split on top of whatever it
# meant to measure -- which is exactly what happened, unnoticed, to every
# probe number in this tree until 2026-08-18. SB_REV overrides.
SB_REV=${SB_REV:---cgb-rev=E}
T=${TMPDIR:-/tmp}/probe_e_cmp
mkdir -p "$T"
SB=${SAMEBOY_RUNNER:-tools/gbfuzz/sameboy_runner}
BR=${SAMEBOY_BOOTROMS:-$HOME/code/SameBoy/build/bin/BootROMs}
if [ ! -x "$SB" ]; then
  echo "no SameBoy runner at $SB -- build it with tools/gbfuzz/build.sh" >&2
  echo "(one cc line against SameBoy's prebuilt libsameboy.a; no SDL, no rgbds)" >&2
  exit 1
fi

MODEL="--cgb $SB_REV"
CGBFLAG=1
QUIET=
while :; do
  case "${1:-}" in
    --dmg)   MODEL=--dmg; CGBFLAG=0; shift ;;
    --quiet) QUIET=1; shift ;;
    *) break ;;
  esac
done
SCXS=${*:-0 4 7}

cols() {
  python3 tools/gbprobe/read_probe_d_photo.py "$1" --skip-top 16 --bands 2>/dev/null \
    | sed -n 's/^  bar *[0-9]*.*x= *\([0-9]*\)-.*/\1/p' | tr '\n' ' '
}

same=0; diff=0
for S in $SCXS; do
  for X in FF 00 01 02 03 04 05 06 07; do
    GBPROBE_CGB=$CGBFLAG GBPROBE_OUT=probe_e_cmp ./tools/gbprobe/mk.sh probe_e_objgrid \
        -DSCX_DEFAULT=$S -DOBJX_DEFAULT="\$$X" >/dev/null 2>&1
    $SB tools/gbprobe/probe_e_cmp.gb "$BR" "$T/sb" "" 240 >/dev/null 2>&1
    ./dingbat_test tools/gbprobe/probe_e_cmp.gb --mode=screenshot $MODEL \
        --timeout=200 --screenshot=$T/db.ppm >/dev/null 2>&1
    a=$(cols $T/sb.f0240.ppm); b=$(cols $T/db.ppm)
    if [ "$a" = "$b" ]; then
      same=$((same+1))
    else
      diff=$((diff+1))
      if [ -z "$QUIET" ]; then
        echo "SCX $S  OBJ $X"
        echo "   sameboy: $a"
        echo "   dingbat: $b"
      fi
    fi
  done
done
echo "agree $same / $((same+diff))"
rm -f tools/gbprobe/probe_e_cmp.gb tools/gbprobe/probe_e_cmp.sym
