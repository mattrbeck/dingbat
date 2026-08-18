#!/usr/bin/env bash
# mbvsoracle -- put a mealybug CGB row's frame next to SameBoy's, in the SAME
# colour space, so the oracle can be asked whether it agrees with the reference
# a runner row is scored against.
#
# The colour question is why this is not obvious: the runner applies gambatte's
# CGB correction and SameBoy's runner sets GB_COLOR_CORRECTION_DISABLED, so a
# naive diff of the two is thousands of pixels of palette and says nothing
# about timing. dingbat's screenshot mode without `--color` is the raw
# RGB555 -> RGB888 expansion, which is the same space SameBoy dumps in -- so
# the comparison below is timing-only.
#
#   tools/gbppu/mbvsoracle.sh <binary> <rom-basename> [<rom-basename> ...]
set -uo pipefail
cd "$(dirname "$0")/../.."
# SameBoy's runner is hardcoded to GB_MODEL_CGB_E, and dingbat defaults
# to CGB-C. Every comparison here must therefore force rev E or it is
# measuring the CGB-C/CGB-D palette-step split on top of whatever it
# meant to measure -- which is exactly what happened, unnoticed, to every
# probe number in this tree until 2026-08-18. SB_REV overrides.
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
