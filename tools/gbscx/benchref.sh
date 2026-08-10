#!/bin/bash
# Retired-instruction A/B between two git refs, interleaved.
#
# Both arms are exported with `git archive` into their own tree, so neither can
# see the other's nimcache or artifacts -- the trap tools/gbgate/build.sh exists
# for. `cycles=` must be identical between the arms or they did different work.
#
#   tools/gbscx/benchref.sh <refA> <refB> <rom> [reps]
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
A=$1; B=$2; ROM=$3; REPS=${4:-6}
for s in A B; do
  ref=$([ $s = A ] && echo "$A" || echo "$B")
  d="$WORKTREE/.tmp/ref$s"
  rm -rf "$d"; mkdir -p "$d"
  git archive "$ref" | tar -x -C "$d"
  ( cd "$d" && XDG_CACHE_HOME="$d/.cache" TMPDIR="$d" \
      nim c -d:test_harness -d:release --path:src \
        -o:"$d/dingbat_bench" tests/dingbat_bench.nim >/dev/null )
done
echo "A: $A"
echo "B: $B"
for i in $(seq 1 "$REPS"); do
  for s in A B; do
    d="$WORKTREE/.tmp/ref$s"
    printf '%s ' "$s"
    ( cd "$d" && TMPDIR="$d" DINGBAT_NO_WAITLOOP=1 DINGBAT_BENCH_COUNTERS=1 \
        ./dingbat_bench "$ROM" 2400 300 ) 2>&1 \
      | grep -oE "(cycles|instructions)=[0-9]+" | tr '\n' ' '
    echo
  done
done
