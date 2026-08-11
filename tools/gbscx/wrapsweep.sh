#!/bin/bash
# One build and one whole-gambatte score per value of SCX_FINE_LATCH_WRAP, with
# SCX_FINE_LATCH_LIVE on throughout -- the wrap rides inside that window and
# has no meaning without it. `sweep.sh` cannot do this one: it passes a single
# -d: flag and this mechanism needs two.
#
#   tools/gbscx/wrapsweep.sh 6 7 8 9 10
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
for v in "$@"; do
  nim c -d:test_harness -d:release --path:src \
      -d:SCX_FINE_LATCH_LIVE=true "-d:SCX_FINE_LATCH_WRAP=$v" \
      -o:"$WORKTREE/dt_sw" tests/dingbat_test.nim >/dev/null 2>&1
  cp "$WORKTREE/dt_sw" "$WORKTREE/dingbat_test"
  tot=$(tools/gbppu/gamall.sh "$WORKTREE/.tmp/g_w$v" | grep TOTAL)
  echo "=== SCX_FINE_LATCH_WRAP=$v  $tot"
done
