#!/bin/bash
# Like sweep2.sh but scores the FULL LOCAL RUNNER per value, not just gambatte.
# Needed when the axis under test trades between suites -- gambatte alone cannot
# see a GBMicrotest or mooneye row move, and this campaign's last two rounds
# both turned on exactly that.
#
#   tools/gbscx/runsweep.sh '-d:FLAG=%V%' 1 2 3 4
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
TMPL=$1; shift
for v in "$@"; do
  flags=${TMPL//%V%/$v}
  nim c -d:test_harness -d:release --path:src $flags \
      -o:"$WORKTREE/dt_sw" tests/dingbat_test.nim >/dev/null 2>&1
  cp "$WORKTREE/dt_sw" "$WORKTREE/dingbat_test"
  line=$(./dingbat_test_runner 2>&1 | grep -E "^Total:")
  gam=$(grep -E "^\| gambatte/" tests/results.md | grep -oE "[0-9]+/[0-9]+ passed" \
        | awk -F'[/ ]' '{a+=$1; b+=$2} END {print a"/"b}')
  echo "$flags   runner: $line   gambatte: $gam"
done
git checkout tests/ 2>/dev/null || true
