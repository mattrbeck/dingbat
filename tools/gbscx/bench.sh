#!/bin/bash
# Retired-instruction A/B for one `-d:` flag, interleaved.
#
# docs/gb_oam_dma_cost.md is the authority: wall clock has a ~1.3% layout noise
# floor and cannot resolve a change to the mode 3 dot loop, retired
# instructions reproduce to ~0.002%, and `cycles=` must be IDENTICAL between
# the arms or the two did different work and the comparison is void.
#
# Runs the arms alternately rather than one after the other, so a machine that
# warms or throttles mid-measurement cannot be mistaken for a result, and
# reports each arm's own spread next to the delta.
#
#   tools/gbscx/bench.sh <rom> <reps> -d:FLAG=0 -- -d:FLAG=1
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
ROM=$1; REPS=${2:-6}; shift 2
AFLAGS=(); BFLAGS=(); cur=A
for a in "$@"; do
  if [ "$a" = "--" ]; then cur=B; continue; fi
  if [ "$cur" = A ]; then AFLAGS+=("$a"); else BFLAGS+=("$a"); fi
done
mkdir -p "$WORKTREE/.tmp/benchA" "$WORKTREE/.tmp/benchB"
nim c -d:test_harness -d:release --path:src "${AFLAGS[@]}" \
    -o:"$WORKTREE/.tmp/benchA/dingbat_bench" tests/dingbat_bench.nim >/dev/null
nim c -d:test_harness -d:release --path:src "${BFLAGS[@]}" \
    -o:"$WORKTREE/.tmp/benchB/dingbat_bench" tests/dingbat_bench.nim >/dev/null
echo "A: ${AFLAGS[*]:-<none>}"
echo "B: ${BFLAGS[*]:-<none>}"
for i in $(seq 1 "$REPS"); do
  for s in A B; do
    printf '%s ' "$s"
    ( cd "$WORKTREE/.tmp/bench$s" && TMPDIR="$WORKTREE/.tmp/bench$s" \
        DINGBAT_NO_WAITLOOP=1 DINGBAT_BENCH_COUNTERS=1 \
        ./dingbat_bench "$ROM" 2400 300 ) 2>&1 \
      | grep -oE "(cycles|instructions)=[0-9]+" | tr '\n' ' '
    echo
  done
done
