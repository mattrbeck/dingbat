#!/bin/sh
# revsweep.sh <world> <tag> <rom> -- capture one ROM at every CGB revision.
# The runtime revision axis is orthogonal to the pipeline phase, so a witness
# that moves with it is telling a revision story, not a phase story.
set -e
W=/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556
WORLD=$1; TAG=$2
# Resolve the ROM before the cd below, so a path relative to the worktree root
# (which is how every other tool here is called) still works.
case $3 in /*) ROM=$3 ;; *) ROM=$W/$3 ;; esac
mkdir -p "$W/.shots" "$W/.tmp/tmp-$WORLD"
export XDG_CACHE_HOME=$W/.cache
export DINGBAT_ROM_CACHE=$W/.romcache
export TMPDIR=$W/.tmp/tmp-$WORLD
cd "$W/.worlds/$WORLD"
for r in C D E; do
  ./dingbat_test "$ROM" --cgb --color --cgb-rev=$r --mode=screenshot \
      --screenshot="$W/.shots/$TAG-rev$r.$WORLD.ppm" --timeout=400 \
      >/dev/null 2>&1 || true
done
ls "$W/.shots" | grep "$TAG-rev.*\.$WORLD\.ppm" | tr '\n' ' '
echo ""
