#!/bin/sh
# run-world.sh <world> -- full local runner pass for one built world, into
# .worlds/<world>/results.txt.
#
# Each world gets its own TMPDIR: run_sharded_batch puts its shard list in
# getTempDir()/dingbat-gambatte and removeDirs it on entry, so two concurrent
# passes sharing one TMPDIR read back as a uniform 0/5005 (the trap recorded in
# docs/gb-bundle-measurement-2026-08-10.md).
set -e
W=/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556
WORLD=$1
mkdir -p "$W/.tmp/tmp-$WORLD"
export XDG_CACHE_HOME=$W/.cache
export DINGBAT_ROM_CACHE=$W/.romcache
export TMPDIR=$W/.tmp/tmp-$WORLD
cd "$W/.worlds/$WORLD"
./dingbat_test_runner > results.txt 2>&1 || true
tail -30 results.txt
