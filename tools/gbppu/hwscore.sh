#!/usr/bin/env bash
# hwscore -- score a build against the instruments whose expectations came from
# SILICON, with no emulator's opinion in the number.
#
# WHY THIS IS SEPARATE FROM THE RUNNER. Passing a row is not evidence that the
# model matches hardware; it is evidence that it matches whatever produced the
# row's expectation. gambatte's 5,005 rows are gambatte's output, and this tree
# already disagrees with ~800 of them, so a change that moves gambatte by
# hundreds has said nothing until you know which way the hardware-anchored
# instruments moved. Those are:
#
#   objtab      GBMicrotest ppu_spritex_vs_scx -- 153 cells of OBJ penalty in
#               dots, expectations transcribed from the ROM's own `cp` operands.
#               Mode 3's LENGTH. Ships 0/153 and must stay there.
#   probe (e)   136 cells of fetch-grid POSITION against SameBoy, which
#               reproduced the GBA SP on all eight photographed settings.
#               Ships 68/136 -- this one is WRONG and is the open problem.
#   acid-hell   cgb-acid-hell against its reference, which SameBoy renders
#               pixel-exact. Ships at 2 px.
#
# mealybug is the fourth such instrument -- its references are captures of real
# DMG/CGB silicon -- but it is only scored colour-correctly by the full runner,
# so it is not in here; run the runner for it and read the mealybug rows.
#
#   tools/gbppu/hwscore.sh [-d:KNOB=V ...]
set -uo pipefail
cd "$(dirname "$0")/../.."
T=${TMPDIR:-/tmp}/hwscore
mkdir -p "$T"
CACHE=${DINGBAT_ROM_CACHE:-/tmp/dingbat-test-roms}
HELL=$CACHE/game-boy-test-roms/cgb-acid-hell/cgb-acid-hell

nim c --nimcache:$T/nc -d:test_harness -d:release --path:src "$@" \
    -o:$T/dt tests/dingbat_test.nim >$T/build.log 2>&1 || {
  echo "build failed"; tail -5 $T/build.log; exit 1; }
nim c --nimcache:$T/ncm -d:test_harness -d:release -d:gb_m3_len --path:src "$@" \
    -o:$T/dt_m3len tests/dingbat_test.nim >$T/buildm.log 2>&1 || {
  echo "m3len build failed"; tail -5 $T/buildm.log; exit 1; }

echo "knobs: ${*:-<stock>}"
printf '  objtab (mode 3 length, hardware `cp` operands) : %s\n' \
  "$(DINGBAT_ROM_CACHE=$CACHE python3 tools/gbppu/objtab.py $T/dt_m3len 2>/dev/null \
     | sed -n 's/^mismatched cells: //p')"

cp $T/dt ./dingbat_test
printf '  probe (e) (fetch grid, SameBoy = GBA SP)       : %s\n' \
  "$(./tools/gbprobe/probe_e_fit.sh 2>/dev/null | sed -n 's/^fit //p')"

./dingbat_test "$HELL.gbc" --mode=screenshot --cgb --color --timeout=140 \
    --screenshot=$T/hell.ppm >/dev/null 2>&1
printf '  cgb-acid-hell (vs reference)                   : %s\n' \
  "$(python3 tools/gbprobe/ppmdiff.py $T/hell.ppm "$HELL.png" 2>/dev/null | head -1)"
