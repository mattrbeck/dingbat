#!/usr/bin/env bash
# probe_f_base -- probe (f) scored by BASE EQUIVALENCE, which is the only
# unambiguous way to read this staircase.
#
# WHY NOT COMPARE COLUMNS. dingbat carries a uniform column offset in this
# probe that has nothing to do with the window (the plain arm has it too --
# probe (e) 68/136), so probe_f_fit.sh's absolute comparison is pinned at 0/8
# whatever the window path does. Subtracting a best-fit offset instead does not
# work either: the staircase is SELF-SIMILAR under shift (`24 24 32 32 ...`
# against `24 32 32 40 ...`), so a metric that is free to slide one against the
# other calls two genuinely different pairing phases a match.
#
# So do what probe (e) did: BASE is the M-cycles from the anchor's wake to the
# LCDC.4 write, and moving it by one moves the write by 4 dots. Sweep it in
# DINGBAT, hold the oracle at the shipping BASE, and ask which value -- if any
# -- reproduces the oracle's columns EXACTLY. A pure phase error answers with
# one BASE that works at every SCX. A window-path error answers with no BASE at
# all, or with a different one per SCX, and the spread is the shape of the bug.
#
# Only even offsets can land on the oracle's grid at all (a write is 4 dots and
# a column is 8), which is why the sweep steps by one M and most rows report at
# most one hit.
#
#   tools/gbprobe/probe_f_base.sh [--dmg] [-d:KNOB=V ...]
set -uo pipefail
cd "$(dirname "$0")/../.."
# SameBoy's runner is hardcoded to GB_MODEL_CGB_E and dingbat defaults to
# CGB-C, so every CGB comparison must force rev E. SB_REV overrides.
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
    # CGB COMPATIBILITY mode: a cart with no CGB flag, run on a CGB. It is a
    # third machine, distinct from both --dmg (DMG silicon) and the default
    # (CGB native), and it is the one daid's ppu_scanline_bgp runs on -- so it
    # is what separates that ROM from this probe. SameBoy needs GBFUZZ_MODEL to
    # be told, since it otherwise picks its model off the cart flag.
    --compat) MODEL="--cgb $SB_REV"; SUF=compat; CGBFLAG=0; export GBFUZZ_MODEL=cgb; shift ;;
    # The CONTROL arm: same ROM, same anchor, same bands, no window. Whatever
    # uniform offset this reports is not the window's, and only the difference
    # between the two arms is.
    --plain) WIN=""; SUF=${SUF}-plain; shift ;;
    *) break ;;
  esac
done
# PROBE_F_EXTRA changes the ROM, so it must change the oracle cache's name too
# -- reusing the halt-anchored oracle for a polled-anchor ROM would silently
# compare two different experiments.
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
# A model is only right if ONE base explains every SCX; per-SCX hits with no
# common member are still a window-path bug wearing a phase costume.
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
