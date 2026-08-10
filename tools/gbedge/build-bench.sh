#!/bin/sh
# build-bench.sh <tag> [-d:FLAG ...] -- dingbat_bench into .worlds/<tag>/.
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
nim c -d:test_harness -d:release --path:src "$@" \
    -o:"$OUT/dingbat_bench" tests/dingbat_bench.nim
echo "built bench $TAG: $*"
