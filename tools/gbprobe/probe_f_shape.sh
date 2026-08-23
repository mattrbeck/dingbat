#!/usr/bin/env bash
# probe_f_shape -- probe (f) scored modulo one uniform column offset per SCX:
# the offset most bands agree on is found and the row passes if all bands
# agree on it, i.e. the two staircases have the same shape once shifted. This
# separates the window path from the uniform offset the plain arm carries too.
#
# --dmg builds the cart with no CGB flag, making both sides a DMG (the runner
# picks GB_MODEL_DMG_B off byte 0x143; dingbat is told --dmg).
#
#   tools/gbprobe/probe_f_shape.sh [--dmg] [-d:KNOB=V ...]
set -uo pipefail
cd "$(dirname "$0")/../.."
# The runner is built for CGB-E and dingbat defaults to CGB-C; force rev E
# or the C/D palette-step split lands in the count. SB_REV overrides.
SB_REV=${SB_REV:---cgb-rev=E}
T=${TMPDIR:-/tmp}/probe_f_fit          # share probe_f_fit's ROM/oracle cache
mkdir -p "$T"
SB=${SAMEBOY_RUNNER:-tools/gbfuzz/sameboy_runner}
BR=${SAMEBOY_BOOTROMS:-$HOME/code/SameBoy/build/bin/BootROMs}

MODEL="--cgb $SB_REV"; SUF=cgb; CGBFLAG=1
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
