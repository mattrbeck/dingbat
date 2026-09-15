#!/usr/bin/env bash
# Retired-instruction A/B of two bench binaries (tools/mp2ksweep/build_at.sh
# ... bench), HLE off and on, on the two MP2K baselines.
#
# Usage: bench_ab.sh <bench A> <bench B> [runs=3]
#
#   $MP2K_BENCH_EMERALD  Pokémon Emerald ROM, with its .sav beside it (the
#                        script walks from the title into Littleroot)
#   $MP2K_BENCH_BEAST    Beast Shooter (power-on attract, no save)
#
# Reports the minimum instruction count over the runs (DINGBAT_BENCH_COUNTERS;
# wall-clock A/B is unreliable below ~1.3 %, the code-layout noise floor).
set -euo pipefail

a=${1:?bench A}
b=${2:?bench B}
runs=${3:-3}
emerald=${MP2K_BENCH_EMERALD:?set MP2K_BENCH_EMERALD}
beast=${MP2K_BENCH_BEAST:?set MP2K_BENCH_BEAST}

one() {  # <bin> <rom> <frames> <warmup> <script> <label>
  local bin=$1 rom=$2 frames=$3 warmup=$4 script=$5 label=$6
  for mode in off on; do
    local best=""
    for _ in $(seq 1 "$runs"); do
      local out ins
      if [ $mode = on ]; then
        out=$(DINGBAT_MP2K=1 DINGBAT_BENCH_COUNTERS=1 "$bin" "$rom" "$frames" "$warmup" "$script" 2>&1)
      else
        out=$(DINGBAT_BENCH_COUNTERS=1 "$bin" "$rom" "$frames" "$warmup" "$script" 2>&1)
      fi
      ins=$(echo "$out" | sed -n 's/.*instructions=\([0-9]*\).*/\1/p')
      if [ -z "$best" ] || [ "$ins" -lt "$best" ]; then best=$ins; fi
    done
    echo "$label hle=$mode min_instructions=$best"
  done
}

for bin in "$a" "$b"; do
  one "$bin" "$emerald" 600 1200 "400:START,700:START,900:A,1000:A,1100:A" "emerald $(basename "$bin")"
  one "$bin" "$beast" 900 600 "" "beast $(basename "$bin")"
done
