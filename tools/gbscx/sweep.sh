#!/bin/bash
# One build and one whole-gambatte score per value of one {.intdefine.},
# against a baseline row file, printing only what moved. The control arm is
# the first value swept, which must reproduce the baseline exactly -- that is
# what says the mechanism is free when it is off.
#
#   tools/gbscx/sweep.sh SCX_FINE_LATCH_DOTS .tmp/g_base.txt 0 1 2 3 4
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
NAME=$1; BASE=$2; shift 2
for v in "$@"; do
  nim c -d:test_harness -d:release --path:src "-d:$NAME=$v" \
      -o:"$WORKTREE/dt_sw" tests/dingbat_test.nim >/dev/null 2>&1
  cp "$WORKTREE/dt_sw" "$WORKTREE/dingbat_test"
  tot=$(tools/gbppu/gamall.sh "$WORKTREE/.tmp/g_$NAME$v" | grep TOTAL)
  echo "=== $NAME=$v  $tot"
  bash tools/gbscx/gamdiff.sh "$BASE" "$WORKTREE/.tmp/g_$NAME$v.txt"
done
