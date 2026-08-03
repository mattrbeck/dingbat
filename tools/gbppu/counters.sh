#!/bin/bash
# Retired-instruction A/B between two gbgate build slots. See
# docs/gb_oam_dma_cost.md: fps has a ~1.3% layout noise floor, retired
# instructions reproduce to 0.002%, and `cycles=` must match between the arms
# or they did different work.
#   tools/gbppu/counters.sh <gbgate-workdir> <rom> [frames] [warmup]
W=$1; ROM=$2; FRAMES=${3:-2400}; WARMUP=${4:-300}
for slot in A B; do
  d="$W/$slot"
  base=$(basename "$ROM")
  ln -sf "$ROM" "$d/roms/$base"
  rm -f "$d/roms/"*.sav
  printf '%s ' "$slot"
  ( cd "$d" && TMPDIR="$W/tmp$slot" DINGBAT_NO_WAITLOOP=1 \
      DINGBAT_BENCH_COUNTERS=1 ./dingbat_bench "$d/roms/$base" "$FRAMES" "$WARMUP" \
  ) 2>&1 | grep -E "cycles=|instructions=" | tr '\n' ' '
  echo
done
