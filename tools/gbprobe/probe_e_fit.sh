#!/usr/bin/env bash
# probe_e_fit -- score ./dingbat_test against the oracle over the whole
# probe (e) matrix (8 SCX x 17 object settings = 136 cells) in absolute
# columns: the objects-off baseline is part of the law, so scoring per-SCX
# shifts against each emulator's own baseline would hide a baseline error.
#
#   tools/gbprobe/probe_e_fit.sh [--dmg] [--verbose]
#
# The ROM matrix and the oracle's table are built once and cached under
# TMPDIR; a knob sweep re-runs only the emulator.
set -uo pipefail
cd "$(dirname "$0")/../.."
# The runner is built for CGB-E and dingbat defaults to CGB-C; force rev E
# or the C/D palette-step split lands in the count. SB_REV overrides.
SB_REV=${SB_REV:---cgb-rev=E}
SB=${SAMEBOY_RUNNER:-tools/gbfuzz/sameboy_runner}
BR=${SAMEBOY_BOOTROMS:-$HOME/code/SameBoy/build/bin/BootROMs}

MODEL=cgb; DBFLAG="--cgb $SB_REV"; CGBFLAG=1; VERBOSE=
while :; do
  case "${1:-}" in
    --dmg)     MODEL=dmg; DBFLAG=--dmg; CGBFLAG=0; shift ;;
    --verbose) VERBOSE=1; shift ;;
    *) break ;;
  esac
done

T=${TMPDIR:-/tmp}/probe_e_fit
ROMS=$T/roms/$MODEL
ORACLE=$T/oracle_$MODEL.txt
mkdir -p "$ROMS"
XS="FF 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F"
SCXS="0 1 2 3 4 5 6 7"

col0() {
  python3 tools/gbprobe/read_probe_d_photo.py "$1" --skip-top 16 --bands 2>/dev/null \
    | sed -n 's/^  bar *0 .*x= *\([0-9]*\)-.*/\1/p' | head -1
}

# the ROM matrix, once
if [ ! -f "$ROMS/.done" ]; then
  echo "building the $MODEL ROM matrix (once)..." >&2
  for S in $SCXS; do
    for X in $XS; do
      GBPROBE_CGB=$CGBFLAG GBPROBE_OUT=probe_e_fit ./tools/gbprobe/mk.sh probe_e_objgrid \
          -DSCX_DEFAULT=$S -DOBJX_DEFAULT="\$$X" >/dev/null 2>&1
      mv tools/gbprobe/probe_e_fit.gb "$ROMS/s${S}_x${X}.gb"
      rm -f tools/gbprobe/probe_e_fit.sym
    done
  done
  touch "$ROMS/.done"
fi

# the oracle's table, once
if [ ! -f "$ORACLE" ]; then
  [ -x "$SB" ] || { echo "no SameBoy runner at $SB (tools/gbfuzz/build.sh)" >&2; exit 1; }
  echo "reading the oracle (once)..." >&2
  : > "$ORACLE"
  for S in $SCXS; do
    row=""
    for X in $XS; do
      $SB "$ROMS/s${S}_x${X}.gb" "$BR" "$T/o" "" 240 >/dev/null 2>&1
      row="$row $(col0 $T/o.f0240.ppm)"
    done
    echo "$S$row" >> "$ORACLE"
  done
fi

# this build's table
[ -x ./dingbat_test ] || { echo "no ./dingbat_test" >&2; exit 1; }
hit=0; miss=0; missing_cells=""
[ -n "$VERBOSE" ] && printf '%-4s %-4s %s\n' SCX who "OFF  00  01  02  03  04  05  06  07  08  09  0A  0B  0C  0D  0E  0F"
for S in $SCXS; do
  want=$(grep "^$S " "$ORACLE" | cut -d' ' -f2-)
  got=""
  for X in $XS; do
    ./dingbat_test "$ROMS/s${S}_x${X}.gb" --mode=screenshot $DBFLAG --timeout=30 \
        --screenshot=$T/d.ppm >/dev/null 2>&1
    got="$got $(col0 $T/d.ppm)"
  done
  i=0
  for X in $XS; do
    i=$((i + 1))
    w=$(echo $want | cut -d' ' -f$i); g=$(echo $got | cut -d' ' -f$i)
    if [ "$w" = "$g" ]; then hit=$((hit + 1)); else miss=$((miss + 1)); missing_cells="$missing_cells $S/$X"; fi
  done
  if [ -n "$VERBOSE" ]; then
    printf '%-4s %-4s %s\n' "$S" oracle "$(echo $want | awk '{for(i=1;i<=NF;i++)printf "%-4s",$i;print ""}')"
    printf '%-4s %-4s %s\n' ""   dingbat "$(echo $got  | awk '{for(i=1;i<=NF;i++)printf "%-4s",$i;print ""}')"
  fi
done
echo "fit $hit / $((hit + miss)) cells [$MODEL]"
