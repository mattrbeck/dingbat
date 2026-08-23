#!/usr/bin/env bash
# probe_e_penalty -- the object penalty as a function of object X and SCX,
# read off the oracle (or, with --dingbat, off ./dingbat_test). An object
# that stalls the fetcher N dots moves the staircase's column by N against
# the same SCX's objects-off baseline. Pan Docs gives two rules (Rendering.md:
# X = 0 always costs 11 dots regardless of SCX; pixel_fifo.md: SCX & 7 when
# nonzero); this measures it.
#
# Prints one row per SCX: the objects-off baseline column, then the shift each
# object X causes. A shift is negative (the bar moves left) when the object
# delays the fetcher.
#
#   tools/gbprobe/probe_e_penalty.sh [--dingbat] [--dmg]
set -uo pipefail
cd "$(dirname "$0")/../.."
# The runner is built for CGB-E and dingbat defaults to CGB-C; force rev E
# or the C/D palette-step split lands in the count. SB_REV overrides.
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
