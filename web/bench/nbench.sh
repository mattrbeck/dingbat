#!/bin/sh
# Native throughput bench with noise rejection.
#
# Background load on a desktop (WindowServer, Spotlight, browsers) only ever
# steals cycles, so the contention noise is one-sided: the FASTEST run of N is
# the least-contaminated estimate of true throughput, while a mean or median
# drifts with whatever else is happening. Report best-of-N and also the spread
# so a genuinely unstable measurement is visible rather than hidden.
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
