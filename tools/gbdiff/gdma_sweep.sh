#!/usr/bin/env bash
# Read gambatte's gdma_cycles_* family out at each setting of
# GDMA_SETUP_MCYCLES. Each member is a pair differing by one NOP ahead of
# `LDH A,($41)`, so the pair's two expected values put the mode 3 -> 0 edge
# between them; a setting is correct only if every pair lands on the right
# side of its own flip point at once.
#
# Usage: tools/gbdiff/gdma_sweep.sh [max-mcycles]   (default 8)
set -uo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD
GB=/tmp/dingbat-test-roms/game-boy-test-roms/gambatte/dma
BOOT=${GBDIFF_BOOT:-/tmp/gbdiff-work/boot}
WORK=$(mktemp -d)
MAX=${1:-8}

# One pair per line: rom-stem-1 rom-stem-2 expected1 expected2
PAIRS=(
  "gdma_cycles_long_1_cgb04c_out3 gdma_cycles_long_2_cgb04c_out0 3 0"
  "gdma_cycles_short_1_cgb04c_out3 gdma_cycles_short_2_cgb04c_out0 3 0"
  "gdma_cycles_long_ds_1_cgb04c_out3 gdma_cycles_long_ds_2_cgb04c_out0 3 0"
  "gdma_cycles_2xshort_ds_1_cgb04c_out3 gdma_cycles_2xshort_ds_2_cgb04c_out0 3 0"
  "gdma_cycles_long_scx2_1_cgb04c_out3 gdma_cycles_long_scx2_2_cgb04c_out0 3 0"
  "gdma_cycles_long_scx3_1_cgb04c_out3 gdma_cycles_long_scx3_2_cgb04c_out0 3 0"
  "gdma_cycles_long_scx5_1_cgb04c_out3 gdma_cycles_long_scx5_2_cgb04c_out0 3 0"
  "gdma_cycles_long_scx5_ds_1_cgb04c_out3 gdma_cycles_long_scx5_ds_2_cgb04c_out0 3 0"
  "gdma_cycles_2xshort_scx5_ds_1_cgb04c_out3 gdma_cycles_2xshort_scx5_ds_2_cgb04c_out0 3 0"
)

for n in $(seq 0 "$MAX"); do
  nim c -d:release -d:GDMA_SETUP_MCYCLES="$n" --path:src --hints:off \
    --nimcache:"$WORK/nc$n" -o:"$WORK/nav$n" tools/gbfuzz/dingbat_gb_nav.nim \
    >"$WORK/build$n.log" 2>&1
  if [ ! -x "$WORK/nav$n" ]; then
    echo "build failed at n=$n, see $WORK/build$n.log" >&2
    exit 1
  fi
  ok=0; bad=0; detail=""
  for pair in "${PAIRS[@]}"; do
    set -- $pair
    for side in 1 2; do
      if [ "$side" = 1 ]; then rom=$1; want=$3; else rom=$2; want=$4; fi
      "$WORK/nav$n" "$GB/$rom.gbc" "$BOOT" "$WORK/s" "" "300" >/dev/null 2>&1
      got=$(python3 "$REPO/tools/gbdiff/readout.py" "$WORK/s.f0300.ppm" --glyphs 1)
      if [ "$got" = "$want" ]; then ok=$((ok+1)); else bad=$((bad+1))
        detail="$detail ${rom%%_cgb*}:got$got/want$want"
      fi
    done
  done
  printf 'GDMA_SETUP_MCYCLES=%-2d  pass %2d / %2d %s\n' "$n" "$ok" "$((ok+bad))" \
    "$( [ "$bad" -gt 0 ] && echo "|$detail" )"
done

echo "workdir: $WORK"
