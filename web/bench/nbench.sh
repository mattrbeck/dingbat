#!/bin/sh
# Native throughput bench. Contention noise is one-sided (background load
# only steals cycles), so best-of-N is the estimate; the spread is reported
# so an unstable measurement is visible.
#
# Usage: nbench.sh <binary> <rom> [reps] [frames] [warmup]
#   DINGBAT_BENCH_STATE / DINGBAT_MP2K are passed through from the environment.
BIN=$1; ROM=$2; REPS=${3:-7}; FRAMES=${4:-600}; WARM=${5:-60}
i=0
while [ $i -lt "$REPS" ]; do
  "$BIN" "$ROM" "$FRAMES" "$WARM" 2>/dev/null | head -1 | sed 's/.*= //; s/ fps.*//'
  i=$((i+1))
done | sort -n | awk -v b="$(basename "$BIN")" '
  { v[NR]=$1 }
  END { printf "%-22s best %7.1f   median %7.1f   worst %7.1f  (n=%d)\n",
               b, v[NR], v[int((NR+1)/2)], v[1], NR }'
