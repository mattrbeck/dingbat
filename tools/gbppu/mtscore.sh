#!/bin/bash
# Score a GBMicrotest prefix with the local ./dingbat_test, without a runner
# pass. The win*_a/_b pairs bracket the end of mode 3 per WX, so this is the
# other half of the window loop next to gamscore.sh / gamall.sh.
#
#   tools/gbppu/mtscore.sh win      # the 36 window rows
#   tools/gbppu/mtscore.sh          # every GBMicrotest ROM
#
# Prints the failing rows and the pass/fail counts. VERBOSE=1 lists passes too.
MD=${MD:-/tmp/dingbat-test-roms/game-boy-test-roms/gbmicrotest}
cd "$(dirname "$0")/../.."
P=0; F=0
for f in "$MD"/${1:-}*.gb; do
  [ -e "$f" ] || continue
  b=$(basename "$f" .gb)
  # 2 frames is what the runner gives every row but is_if_set_during_ime0;
  # these ROMs have no completion signal, they just write their verdict.
  out=$(./dingbat_test "$f" --mode=microtest --timeout=2 --nosave 2>&1 | tail -1)
  case "$out" in
    *PASS*) P=$((P+1)); [ -n "$VERBOSE" ] && echo "PASS $b";;
    *) F=$((F+1)); echo "FAIL $b  $out";;
  esac
done
echo "microtest ${1:-all}: $P pass / $F fail"
