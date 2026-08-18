#!/usr/bin/env bash
# probe_e_base -- probe (e)'s 136 cells, scored at a chosen BASE.
#
# WHY. probe_e_fit.sh compares ABSOLUTE columns at the ROM's shipping BASE and
# ships 68/136, which was read as "the fetch grid is wrong". It is not that
# simple: probe_f_base.sh, sweeping the write position instead of the model,
# found that with objects OFF dingbat reproduces the oracle at EVERY fine-scroll
# residue provided the write is moved by one constant -- BASE 24 on CGB, BASE 27
# on DMG, 8 dots one way and 4 the other. A constant that large swamps an
# absolute-column score and looks exactly like a broken grid.
#
# So this re-asks probe (e)'s question with that constant taken out: build
# dingbat's ROM matrix at --base N, hold the oracle at the shipping BASE, and
# count the cells that then agree. What survives is the part of the object
# model that a phase constant cannot explain.
#
#   tools/gbprobe/probe_e_base.sh [--dmg] [--base N] [-d:KNOB=V ...]
set -uo pipefail
cd "$(dirname "$0")/../.."
# SameBoy's runner is hardcoded to GB_MODEL_CGB_E and dingbat defaults to
# CGB-C, so every CGB comparison must force rev E. SB_REV overrides.
SB_REV=${SB_REV:---cgb-rev=E}
SB=${SAMEBOY_RUNNER:-tools/gbfuzz/sameboy_runner}
BR=${SAMEBOY_BOOTROMS:-$HOME/code/SameBoy/build/bin/BootROMs}

MODEL=cgb; DBFLAG="--cgb $SB_REV"; CGBFLAG=1; BASE=24
while :; do
  case "${1:-}" in
    --dmg)  MODEL=dmg; DBFLAG=--dmg; CGBFLAG=0; BASE=27; shift ;;
    --base) BASE=$2; shift 2 ;;
    *) break ;;
  esac
done

T=${TMPDIR:-/tmp}/probe_e_fit          # share probe_e_fit's oracle cache
ROMS=$T/roms/$MODEL                    # the oracle's matrix, shipping BASE
DROMS=$T/roms_b$BASE/$MODEL            # dingbat's matrix, this BASE
ORACLE=$T/oracle_$MODEL.txt
mkdir -p "$ROMS" "$DROMS"
XS="FF 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F"
SCXS="0 1 2 3 4 5 6 7"

nim c --nimcache:$T/nc -d:test_harness -d:release --path:src "$@" \
    -o:$T/dt tests/dingbat_test.nim >$T/build.log 2>&1 || {
  echo "build failed"; tail -5 $T/build.log; exit 1; }
echo "knobs: ${*:-<stock>} [$MODEL, dingbat BASE $BASE vs oracle BASE 26]"

col0() {
  python3 tools/gbprobe/read_probe_d_photo.py "$1" --skip-top 16 --bands 2>/dev/null \
    | sed -n 's/^  bar *0 .*x= *\([0-9]*\)-.*/\1/p' | head -1
}
# $1 = out dir, $2 = extra rgbasm flags
matrix() {
  [ -f "$1/.done" ] && return
  for S in $SCXS; do
    for X in $XS; do
      GBPROBE_CGB=$CGBFLAG GBPROBE_OUT=probe_e_base ./tools/gbprobe/mk.sh \
          probe_e_objgrid -DSCX_DEFAULT=$S -DOBJX_DEFAULT="\$$X" $2 \
          >/dev/null 2>&1
      mv tools/gbprobe/probe_e_base.gb "$1/s${S}_x${X}.gb"
      rm -f tools/gbprobe/probe_e_base.sym
    done
  done
  touch "$1/.done"
}

matrix "$ROMS" ""
matrix "$DROMS" "-DBASE=$BASE"

if [ ! -f "$ORACLE" ]; then
  [ -x "$SB" ] || { echo "no SameBoy runner at $SB" >&2; exit 1; }
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

hit=0; miss=0
for S in $SCXS; do
  want=($(grep "^$S " "$ORACLE" | cut -d' ' -f2-))
  i=0; line=""
  for X in $XS; do
    $T/dt "$DROMS/s${S}_x${X}.gb" --mode=screenshot $DBFLAG --timeout=30 \
        --screenshot=$T/d.ppm >/dev/null 2>&1
    g=$(col0 $T/d.ppm)
    if [ "$g" = "${want[$i]}" ]; then hit=$((hit+1)); line="$line ."
    else miss=$((miss+1)); line="$line X"; fi
    i=$((i+1))
  done
  echo "SCX $S$line"
done
echo "probe (e) at BASE $BASE: $hit / $((hit+miss)) cells [$MODEL]   (columns: objoff, X=0..15)"
