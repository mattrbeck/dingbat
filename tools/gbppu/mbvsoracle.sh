#!/usr/bin/env bash
# mbvsoracle -- a mealybug CGB row's frame next to the sameboy_runner's, in
# the same colour space. No `--color`: dingbat's raw RGB555 -> RGB888
# expansion is the space the runner dumps in (it sets
# GB_COLOR_CORRECTION_DISABLED), so the diff is timing-only.
#
#   tools/gbppu/mbvsoracle.sh <binary> <rom-basename> [<rom-basename> ...]
set -uo pipefail
cd "$(dirname "$0")/../.."
# The runner is built for CGB-E and dingbat defaults to CGB-C; force rev E
# or the C/D palette-step split lands in the count. SB_REV overrides.
SB_REV=${SB_REV:---cgb-rev=E}
T=${TMPDIR:-/tmp}
C=$T/romcache/game-boy-test-roms/mealybug-tearoom-tests/ppu
SB=${SAMEBOY_RUNNER:-tools/gbfuzz/sameboy_runner}
BR=${SAMEBOY_BOOTROMS:-$HOME/code/SameBoy/build/bin/BootROMs}
BIN=$1; shift

for N in "$@"; do
  R=$C/$N.gb
  [ -f "$R" ] || { echo "$N: no ROM at $R"; continue; }
  $BIN "$R" --mode=screenshot --cgb $SB_REV --timeout=120 --screenshot=$T/mb_d.ppm \
      >/dev/null 2>&1
  $SB "$R" "$BR" "$T/mb_o" "" 240 >/dev/null 2>&1
  D=$(python3 tools/gbprobe/ppmdiff.py $T/mb_d.ppm $T/mb_o.f0240.ppm \
        | sed -n 's/.*\([0-9][0-9]*\) differing pixels.*/\1/p' | head -1)
  echo "$N: ${D:-?} px vs oracle"
done
