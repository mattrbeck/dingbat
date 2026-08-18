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
set -uo pipefail
cd "$(dirname "$0")/../.."
T=${TMPDIR:-/tmp}/probe_e_pen
mkdir -p "$T"
SB=${SAMEBOY_RUNNER:-tools/gbfuzz/sameboy_runner}
BR=${SAMEBOY_BOOTROMS:-$HOME/code/SameBoy/build/bin/BootROMs}
[ -x "$SB" ] || { echo "no SameBoy runner at $SB (tools/gbfuzz/build.sh)" >&2; exit 1; }

col0() {   # the first band's column, which is the staircase's phase
  python3 tools/gbprobe/read_probe_d_photo.py "$1" --skip-top 16 --bands 2>/dev/null \
    | sed -n 's/^  bar *0 .*x= *\([0-9]*\)-.*/\1/p' | head -1
}
shot() {
  GBPROBE_OUT=probe_e_pen ./tools/gbprobe/mk.sh probe_e_objgrid \
      -DSCX_DEFAULT=$1 -DOBJX_DEFAULT="\$$2" >/dev/null 2>&1
  $SB tools/gbprobe/probe_e_pen.gb "$BR" "$T/p" "" 240 >/dev/null 2>&1
  col0 "$T/p.f0240.ppm"
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
