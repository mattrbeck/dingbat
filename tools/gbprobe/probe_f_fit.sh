#!/usr/bin/env bash
# probe_f_fit -- score a build's WINDOWED staircase against the oracle, SCX 0..7.
#
# SameBoy is allowed to stand in for the GBA SP here for the same reason as in
# probe (e), and with its own evidence: all EIGHT probe (f) photographs
# (IMG_3833-3840, 2026-08-18) reproduce its prediction, five of them byte for
# byte and the rest differing only where the photograph's own perspective drift
# is worth a pixel. dingbat matches none of them.
#
#   tools/gbprobe/probe_f_fit.sh [--verbose]
set -uo pipefail
cd "$(dirname "$0")/../.."
T=${TMPDIR:-/tmp}/probe_f_fit
mkdir -p "$T"
SB=${SAMEBOY_RUNNER:-tools/gbfuzz/sameboy_runner}
BR=${SAMEBOY_BOOTROMS:-$HOME/code/SameBoy/build/bin/BootROMs}
ORACLE=$T/oracle.txt
VERBOSE=${1:-}

cols() {
  python3 tools/gbprobe/read_probe_e.py "$1" 2>/dev/null \
    | sed -n 's/^  raw cols : //p'
}
rom() {
  GBPROBE_OUT=probe_f_fit ./tools/gbprobe/mk.sh probe_e_objgrid \
      -DWIN_LIVE=1 -DSCX_DEFAULT=$1 -DOBJX_DEFAULT='$FF' >/dev/null 2>&1
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

hit=0; miss=0
for S in 0 1 2 3 4 5 6 7; do
  want=$(grep "^$S|" "$ORACLE" | cut -d'|' -f2)
  rom $S
  ./dingbat_test tools/gbprobe/probe_f_fit.gb --mode=screenshot --cgb \
      --timeout=30 --screenshot=$T/d.ppm >/dev/null 2>&1
  got=$(cols $T/d.ppm)
  if [ "$want" = "$got" ]; then hit=$((hit+1)); else miss=$((miss+1)); fi
  if [ -n "$VERBOSE" ]; then
    echo "SCX $S"
    echo "  oracle : $want"
    echo "  dingbat: $got"
  fi
done
echo "probe (f) fit $hit / 8 SCX [windowed]"
rm -f tools/gbprobe/probe_f_fit.gb tools/gbprobe/probe_f_fit.sym
