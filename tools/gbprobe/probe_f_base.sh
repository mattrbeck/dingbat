#!/usr/bin/env bash
# probe_f_base -- probe (f) scored by BASE equivalence. BASE is the M-cycles
# from the anchor's wake to the LCDC.4 write (one step = 4 dots); it is swept
# in dingbat with the oracle held at the shipping BASE, and each SCX reports
# which BASE values reproduce the oracle's columns exactly. One BASE common to
# every SCX means a pure phase offset; none, or a different one per SCX, means
# a window-path error. Absolute columns cannot be compared (a uniform offset
# dominates) and a best-fit offset cannot be subtracted (the staircase is
# self-similar under shift). Only even offsets land on the column grid (a
# write is 4 dots, a column 8), so most rows report at most one hit.
#
#   tools/gbprobe/probe_f_base.sh [--dmg] [--compat] [--plain] [-d:KNOB=V ...]
# Env: PROBE_F_BASES (default 22..30), PROBE_F_EXTRA, PROBE_F_VERBOSE.
set -uo pipefail
cd "$(dirname "$0")/../.."
# The runner is built for CGB-E and dingbat defaults to CGB-C; force rev E.
# SB_REV overrides.
SB_REV=${SB_REV:---cgb-rev=E}
T=${TMPDIR:-/tmp}/probe_f_fit          # share probe_f_fit's ROM/oracle cache
mkdir -p "$T"
SB=${SAMEBOY_RUNNER:-tools/gbfuzz/sameboy_runner}
BR=${SAMEBOY_BOOTROMS:-$HOME/code/SameBoy/build/bin/BootROMs}
BASES=${PROBE_F_BASES:-"22 23 24 25 26 27 28 29 30"}

MODEL="--cgb $SB_REV"; SUF=cgb; CGBFLAG=1; WIN=-DWIN_LIVE=1
while :; do
  case "${1:-}" in
    --dmg)   MODEL=--dmg; SUF=dmg; CGBFLAG=0; shift ;;
    # CGB compatibility mode: a cart with no CGB flag run on a CGB (the
    # machine daid's ppu_scanline_bgp runs on). GBFUZZ_MODEL tells the runner,
    # which otherwise picks its model off the cart flag.
    --compat) MODEL="--cgb $SB_REV"; SUF=compat; CGBFLAG=0; export GBFUZZ_MODEL=cgb; shift ;;
    # Control arm: same ROM, no window; only the difference between the two
    # arms is the window's.
    --plain) WIN=""; SUF=${SUF}-plain; shift ;;
    *) break ;;
  esac
done
# PROBE_F_EXTRA changes the ROM, so it must change the oracle cache's name.
[ -n "${PROBE_F_EXTRA:-}" ] && SUF="$SUF$(echo "$PROBE_F_EXTRA" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')"
ORACLE=$T/oracle-$SUF.txt

nim c --nimcache:$T/nc -d:test_harness -d:release --path:src "$@" \
    -o:$T/dt tests/dingbat_test.nim >$T/build.log 2>&1 || {
  echo "build failed"; tail -5 $T/build.log; exit 1; }
echo "knobs: ${*:-<stock>} [$SUF]"

cols() {
  python3 tools/gbprobe/read_probe_e.py "$1" 2>/dev/null \
    | sed -n 's/^  raw cols : //p'
}
# $1 = SCX, $2 = BASE (empty for the ROM's own default)
rom() {
  local extra=""
  [ -n "${2:-}" ] && extra="-DBASE=$2"
  GBPROBE_CGB=$CGBFLAG GBPROBE_OUT=probe_f_fit ./tools/gbprobe/mk.sh \
      probe_e_objgrid $WIN ${PROBE_F_EXTRA:-} -DSCX_DEFAULT=$1 -DOBJX_DEFAULT='$FF' \
      $extra >/dev/null 2>&1
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

declare -a ALLHITS
hit=0
for S in 0 1 2 3 4 5 6 7; do
  want=$(grep "^$S|" "$ORACLE" | cut -d'|' -f2)
  hits=""
  for B in $BASES; do
    rom $S $B
    $T/dt tools/gbprobe/probe_f_fit.gb --mode=screenshot $MODEL \
        --timeout=30 --screenshot=$T/d.ppm >/dev/null 2>&1
    got=$(cols $T/d.ppm)
    [ "$got" = "$want" ] && hits="$hits $B"
    [ -n "${PROBE_F_VERBOSE:-}" ] && echo "      B$B : $got"
  done
  [ -n "${PROBE_F_VERBOSE:-}" ] && echo "      want: $want"
  if [ -n "$hits" ]; then hit=$((hit+1)); else hits=" --"; fi
  ALLHITS[$S]="$hits"
  echo "SCX $S  BASE ->$hits"
done
echo "probe (f) base-equivalence $hit / 8 SCX [windowed $SUF]"
# A model is only right if one BASE explains every SCX.
common=""
for B in $BASES; do
  ok=1
  for S in 0 1 2 3 4 5 6 7; do
    case " ${ALLHITS[$S]} " in *" $B "*) ;; *) ok=0 ;; esac
  done
  [ $ok = 1 ] && common="$common $B"
done
echo "common BASE across all 8 SCX:${common:- none}"
rm -f tools/gbprobe/probe_f_fit.gb tools/gbprobe/probe_f_fit.sym
