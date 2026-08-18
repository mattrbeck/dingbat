#!/usr/bin/env bash
# probe_f_shape -- probe (f) scored the way the finding is actually stated.
#
# probe_f_fit.sh compares ABSOLUTE columns, so the uniform 8-dot offset that
# dingbat carries in the plain arm too (probe (e), 68/136) pins it at 0/8 no
# matter what the window path does. That offset is a separate bug, and holding
# the two together means neither can be worked on. This script takes it out and
# scores what is left: for each SCX it finds the single uniform column offset
# that most bands agree on, and asks whether ALL of them agree on it -- i.e.
# whether the two staircases have the same SHAPE once shifted.
#
# The silicon-confirmed law at the top of this work was
# `dingbat(s) = oracle(s+1) + 8` -- a constant offset AND a one-unit SCX slip.
# This scores the slip alone. Stock is 3/8.
#
# --dmg builds the cart with no CGB flag, which makes BOTH sides a DMG: the
# SameBoy runner picks GB_MODEL_DMG_B off byte 0x143 and dingbat is told --dmg.
# That is the differential that matters for anything touching the window
# restart, because the row such a change historically costs is mealybug DMG.
#
#   tools/gbprobe/probe_f_shape.sh [--dmg] [-d:KNOB=V ...]
set -uo pipefail
cd "$(dirname "$0")/../.."
T=${TMPDIR:-/tmp}/probe_f_fit          # share probe_f_fit's ROM/oracle cache
mkdir -p "$T"
SB=${SAMEBOY_RUNNER:-tools/gbfuzz/sameboy_runner}
BR=${SAMEBOY_BOOTROMS:-$HOME/code/SameBoy/build/bin/BootROMs}

MODEL=--cgb; SUF=cgb; CGBFLAG=1
if [ "${1:-}" = "--dmg" ]; then MODEL=--dmg; SUF=dmg; CGBFLAG=0; shift; fi
ORACLE=$T/oracle-$SUF.txt

nim c --nimcache:$T/nc -d:test_harness -d:release --path:src "$@" \
    -o:$T/dt tests/dingbat_test.nim >$T/build.log 2>&1 || {
  echo "build failed"; tail -5 $T/build.log; exit 1; }
echo "knobs: ${*:-<stock>} [$SUF]"

cols() {
  python3 tools/gbprobe/read_probe_e.py "$1" 2>/dev/null \
    | sed -n 's/^  raw cols : //p'
}
rom() {
  GBPROBE_CGB=$CGBFLAG GBPROBE_OUT=probe_f_fit ./tools/gbprobe/mk.sh \
      probe_e_objgrid -DWIN_LIVE=1 -DSCX_DEFAULT=$1 -DOBJX_DEFAULT='$FF' \
      >/dev/null 2>&1
}

if [ ! -f "$ORACLE" ]; then
  [ -x "$SB" ] || { echo "no SameBoy runner at $SB" >&2; exit 1; }
  : > "$ORACLE"
  for S in 0 1 2 3 4 5 6 7; do
    rom $S
    $SB tools/gbprobe/probe_f_fit.gb "$BR" "$T/o" "" 240 >/dev/null 2>&1
    echo "$S|$(cols $T/o.f0240.ppm)" >> "$ORACLE"
  done
fi

hit=0
for S in 0 1 2 3 4 5 6 7; do
  want=$(grep "^$S|" "$ORACLE" | cut -d'|' -f2)
  rom $S
  $T/dt tools/gbprobe/probe_f_fit.gb --mode=screenshot $MODEL \
      --timeout=30 --screenshot=$T/d.ppm >/dev/null 2>&1
  got=$(cols $T/d.ppm)
  out=$(python3 tools/gbprobe/probe_f_shape.py "$want" "$got")
  case "$out" in *"shape ok"*) hit=$((hit+1));; esac
  echo "SCX $S $out"
  if [ -n "${PROBE_F_VERBOSE:-}" ]; then
    echo "      oracle : $want"
    echo "      dingbat: $got"
  fi
done
echo "probe (f) shape $hit / 8 SCX [windowed $SUF, uniform offset removed]"
rm -f tools/gbprobe/probe_f_fit.gb tools/gbprobe/probe_f_fit.sym
