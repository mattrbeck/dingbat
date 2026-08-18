#!/usr/bin/env bash
# probe_e_penalty -- the object penalty as a function of object X and SCX,
# read off the oracle rather than off dingbat.
#
# Pan Docs contradicts itself here. Rendering.md: an object at X = 0 "always
# incurs an 11-dot penalty, regardless of SCX". pixel_fifo.md: when SCX & 7 > 0
# the penalty is "whatever the lower 3 bits of SCX are". probe (e) measures it
# directly -- an object that stalls the fetcher for N dots pushes every later
# fetch N dots later, so the staircase's COLUMN moves by N against the same
# SCX's objects-off baseline.
#
# SameBoy stands in for the GBA SP: it reproduced all eight photographed
# settings (see docs/probe-e-plan.md), which is what makes a full sweep
# affordable at all -- 136 settings is not a hardware session.
#
# Prints one row per SCX: the objects-off baseline column, then the shift each
# object X causes. A shift is negative (the bar moves LEFT) when the object
# delays the fetcher, since a later grid means an earlier tile is under the
# write.
#
#   tools/gbprobe/probe_e_penalty.sh [--dingbat] [--dmg]
#
# --dingbat reads the same table out of ./dingbat_test instead, so the two
# laws can be compared as laws rather than setting by setting -- which is what
# says whether a candidate model change has the right SHAPE before anyone
# counts dots.
set -uo pipefail
cd "$(dirname "$0")/../.."
# SameBoy's runner is hardcoded to GB_MODEL_CGB_E, and dingbat defaults
# to CGB-C. Every comparison here must therefore force rev E or it is
# measuring the CGB-C/CGB-D palette-step split on top of whatever it
# meant to measure -- which is exactly what happened, unnoticed, to every
# probe number in this tree until 2026-08-18. SB_REV overrides.
SB_REV=${SB_REV:---cgb-rev=E}
T=${TMPDIR:-/tmp}/probe_e_pen
mkdir -p "$T"
SB=${SAMEBOY_RUNNER:-tools/gbfuzz/sameboy_runner}
BR=${SAMEBOY_BOOTROMS:-$HOME/code/SameBoy/build/bin/BootROMs}

WHO=sameboy
MODEL="--cgb $SB_REV"
CGBFLAG=1
while :; do
  case "${1:-}" in
    --dingbat) WHO=dingbat; shift ;;
    --dmg)     MODEL=--dmg; CGBFLAG=0; shift ;;
    *) break ;;
  esac
done
if [ $WHO = sameboy ]; then
  [ -x "$SB" ] || { echo "no SameBoy runner at $SB (tools/gbfuzz/build.sh)" >&2; exit 1; }
  [ $CGBFLAG = 1 ] || { echo "--dmg needs --dingbat: the runner picks its model from the cart flag" >&2; exit 1; }
else
  [ -x ./dingbat_test ] || { echo "no ./dingbat_test -- build it first" >&2; exit 1; }
fi

col0() {   # the first band's column, which is the staircase's phase
  python3 tools/gbprobe/read_probe_d_photo.py "$1" --skip-top 16 --bands 2>/dev/null \
    | sed -n 's/^  bar *0 .*x= *\([0-9]*\)-.*/\1/p' | head -1
}
shot() {
  GBPROBE_CGB=$CGBFLAG GBPROBE_OUT=probe_e_pen ./tools/gbprobe/mk.sh probe_e_objgrid \
      -DSCX_DEFAULT=$1 -DOBJX_DEFAULT="\$$2" >/dev/null 2>&1
  if [ $WHO = sameboy ]; then
    $SB tools/gbprobe/probe_e_pen.gb "$BR" "$T/p" "" 240 >/dev/null 2>&1
    col0 "$T/p.f0240.ppm"
  else
    ./dingbat_test tools/gbprobe/probe_e_pen.gb --mode=screenshot $MODEL \
        --timeout=200 --screenshot=$T/p.ppm >/dev/null 2>&1
    col0 "$T/p.ppm"
  fi
}

printf '%-5s %-8s' SCX baseline
for X in 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F; do printf ' %3s' "$X"; done
echo
for S in 0 1 2 3 4 5 6 7; do
  B=$(shot $S FF)
  printf '%-5s %-8s' "$S" "$B"
  for X in 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F; do
    C=$(shot $S $X)
    if [ -n "$C" ] && [ -n "$B" ]; then printf ' %3d' $((C - B)); else printf ' %3s' '?'; fi
  done
  echo
done
rm -f tools/gbprobe/probe_e_pen.gb tools/gbprobe/probe_e_pen.sym
