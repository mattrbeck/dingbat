#!/bin/sh
# build-world.sh <tag> [-d:FLAG ...]
#
# Build one "world" of the GB renderer -- the same tree with different
# {.intdefine.} values -- into its own directory under .worlds/<tag>, holding
# BOTH dingbat_test and dingbat_test_runner, because the runner shells out to
# getCurrentDir()/dingbat_test. Each world also gets its own TMPDIR, since two
# concurrent runner passes sharing one would delete each other's shard lists
# (recorded in docs/gb-bundle-measurement-2026-08-10.md).
set -e
W=/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556
TAG=$1
shift
OUT=$W/.worlds/$TAG
mkdir -p "$OUT" "$W/.tmp/tmp-$TAG"
export XDG_CACHE_HOME=$W/.cache
export DINGBAT_ROM_CACHE=$W/.romcache
export TMPDIR=$W/.tmp/tmp-$TAG
cd "$W"
nim c -d:release -d:test_harness --path:src "$@" \
    -o:"$OUT/dingbat_test" tests/dingbat_test.nim
# NORUNNER=1 builds only the ROM driver. Enough for screenshot witnesses, which
# can be compared frame-to-frame between worlds without the runner's scoring.
if [ -z "$NORUNNER" ]; then
  nim c -d:release -d:test_harness --path:src --path:tests "$@" \
      -o:"$OUT/dingbat_test_runner" tests/dingbat_test_runner.nim
fi
echo "built $TAG: $*"
