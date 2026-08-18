#!/bin/bash
# Exact pass/fail for the six rows CGB_TDSEL_LATENCY=5 costs, without paying for
# a full runner pass and without colour-correction worries: stock PASSES all of
# them, so a candidate whose frame is byte-identical to stock's still passes,
# and any differing pixel is the row moving. Comparing emulator-to-emulator with
# one colour pipeline sidesteps the mealybug palette question entirely.
#
#   ./atrisk.sh --bless              render the stock reference frames
#   ./atrisk.sh KNOB=V[,KNOB=V ...]  score candidates against them
# The REPO ROOT, not this script's directory. It was `dirname "$0"` until
# 2026-08-18, which put every `nim c` below in tools/gbppu, where they all died
# on "cannot open 'tests/dingbat_test.nim'" -- into a redirected log, with no
# exit check. So the tool never built anything: it scored whatever stale
# binaries happened to be in $T, and every candidate came back "moved: <the same
# four rows>", including a knob set to its own shipping value. Both build sites
# are now guarded so that can never be silent again.
cd "$(dirname "$0")/../.."
T=/Users/matt/.claude/jobs/e4d5536b/tmp
C=$T/romcache/game-boy-test-roms
REF=$T/atrisk
mkdir -p "$REF"

ROWS="mealybug-tearoom-tests/ppu/m3_lcdc_tile_sel_change:cgb
mealybug-tearoom-tests/ppu/m3_lcdc_tile_sel_change2:cgb
mealybug-tearoom-tests/ppu/m3_lcdc_tile_sel_win_change:cgb
mealybug-tearoom-tests/ppu/m3_lcdc_tile_sel_win_change2:cgb
mealybug-tearoom-tests/ppu/m3_lcdc_bg_map_change:cgb
mealybug-tearoom-tests/ppu/m3_scy_change:cgb"

render() { # $1 = binary, $2 = output dir
  mkdir -p "$2"
  for R in $ROWS; do
    P=${R%%:*}; N=$(basename $P)
    [ -f "$C/$P.gb" ] || continue
    $1 "$C/$P.gb" --mode=screenshot --cgb --color --timeout=120 \
        --screenshot=$2/$N.ppm >/dev/null 2>&1
  done
}

if [ "${1:-}" = "--bless" ]; then
  # Its OWN nimcache. Sharing one with the candidate build below made a no-op
  # knob report all four tile_sel rows "moved" -- 1340 differing pixels between
  # two binaries built from identical source and defines -- so every candidate
  # scored the same and the tool was pure noise. Same rule as
  # .github/scripts/build-tests.sh: one nimcache per output binary.
  nim c --nimcache:$T/nc-ar-stock -d:test_harness -d:release --path:src \
      -o:$T/dt_ar_stock tests/dingbat_test.nim >$T/ar.log 2>&1 || {
    echo "bless build FAILED"; tail -5 $T/ar.log; exit 1; }
  rm -f "$REF/stock"/*.ppm
  render $T/dt_ar_stock "$REF/stock"
  echo "blessed $(ls $REF/stock | wc -l | tr -d ' ') stock frames"
  exit 0
fi

for KV in "$@"; do
  D=""
  for k in $(echo "$KV" | tr ',' ' '); do D="$D -d:$k"; done
  nim c --nimcache:$T/nc-ar -d:test_harness -d:release --path:src $D \
      -o:$T/dt_ar tests/dingbat_test.nim >$T/ar.log 2>&1
  [ -x $T/dt_ar ] || { printf '%-40s BUILD FAILED\n' "$KV"; continue; }
  render $T/dt_ar "$REF/cand"
  moved=""
  for F in $REF/stock/*.ppm; do
    N=$(basename $F)
    if ! cmp -s "$F" "$REF/cand/$N"; then moved="$moved ${N%.ppm}"; fi
  done
  if [ -z "$moved" ]; then
    printf '%-40s all at-risk rows UNMOVED\n' "$KV"
  else
    printf '%-40s moved:%s\n' "$KV" "$moved"
  fi
done
