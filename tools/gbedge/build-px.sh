#!/bin/sh
# build-px.sh <tag> [-d:FLAG ...] -- the px/m3 trace binary tdselcells.py wants,
# built as ./dt_px-<tag> in the worktree root (the corpus tool takes the binary
# path as its first argument, so several may coexist).
set -e
W=/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556
TAG=$1
shift
export XDG_CACHE_HOME=$W/.cache
export DINGBAT_ROM_CACHE=$W/.romcache
export TMPDIR=$W/.tmp
cd "$W"
nim c -d:test_harness -d:release -d:gb_px_trace -d:gb_m3_trace -d:GB_TRACE_LY=-1 \
    --path:src "$@" -o:"dt_px-$TAG" tests/dingbat_test.nim
echo "built dt_px-$TAG: $*"
