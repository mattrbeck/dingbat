#!/usr/bin/env bash
# hwscore -- score a build against the instruments whose expectations come
# from hardware rather than from the gambatte suite's recorded output:
#
#   objtab      GBMicrotest ppu_spritex_vs_scx: 153 cells of OBJ penalty in
#               dots (mode 3 length), transcribed from the ROM's `cp` operands.
#   probe (e)   tools/gbprobe probe_e_objgrid: 136 cells of fetch-grid position
#               (docs/hwprobe.md).
#   acid-hell   cgb-acid-hell against its reference PNG.
#
# mealybug's references are hardware captures too, but only the full runner
# scores them colour-correctly, so they are not here.
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
