#!/bin/bash
# Like sweep.sh but the varying value is substituted into a whole flag TEMPLATE,
# so a hypothesis that needs two `-d:` flags moving together can be swept as one
# axis. `%V%` is replaced by each value.
#
#   tools/gbscx/sweep2.sh .tmp/g3_base.txt '-d:STAT_MODE0_LAG=%V% -d:STAT_MODE0_LAG_OBJ=true' 0 2 3 4 5
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
BASE=$1; TMPL=$2; shift 2
for v in "$@"; do
  flags=${TMPL//%V%/$v}
  nim c -d:test_harness -d:release --path:src $flags \
      -o:"$WORKTREE/dt_sw" tests/dingbat_test.nim >/dev/null 2>&1
  cp "$WORKTREE/dt_sw" "$WORKTREE/dingbat_test"
  tot=$(tools/gbppu/gamall.sh "$WORKTREE/.tmp/g_sw$v" | grep TOTAL)
  echo "=== $flags  $tot"
  bash tools/gbscx/gamdiff.sh "$BASE" "$WORKTREE/.tmp/g_sw$v.txt"
done
