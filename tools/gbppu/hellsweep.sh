#!/usr/bin/env bash
# hellsweep -- cgb-acid-hell's pixel count for a list of knob sets, and nothing
# else. hwscore.sh builds two binaries and runs three instruments; when the
# question is only "does this move the 2 px", that is 10x the work.
#
# The 2 px are ONE black pixel drawn one scanline early (see
# tools/gbppu/hellpx.py): dingbat puts it at x = 80 on ly 68, hardware on ly 69.
#
#   tools/gbppu/hellsweep.sh "KNOB=V" "KNOB=V,KNOB2=W" ...
set -uo pipefail
cd "$(dirname "$0")/../.."
T=${TMPDIR:-/tmp}
CACHE=${DINGBAT_ROM_CACHE:-/tmp/dingbat-test-roms}
HELL=$CACHE/game-boy-test-roms/cgb-acid-hell/cgb-acid-hell

for KV in "$@"; do
  D=""
  [ "$KV" != "-" ] && for k in $(echo "$KV" | tr ',' ' '); do D="$D -d:$k"; done
  nim c --nimcache:$T/nc-hell -d:test_harness -d:release --path:src $D \
      -o:$T/dt_hell tests/dingbat_test.nim >$T/hell.log 2>&1 || {
    echo "$KV: BUILD FAILED"; continue; }
  $T/dt_hell "$HELL.gbc" --mode=screenshot --cgb --color --timeout=120 \
      --screenshot=$T/hell.ppm >/dev/null 2>&1
  N=$(python3 tools/gbprobe/ppmdiff.py $T/hell.ppm "$HELL.png" \
        | sed -n 's/^\([0-9][0-9]*\) differing pixels.*/\1/p' | head -1)
  echo "$KV: ${N:-?} px"
done
