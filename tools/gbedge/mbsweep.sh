#!/bin/sh
# mbsweep.sh <world> <dmg|cgb> -- the full mealybug dual-reference sweep for one
# built world, via tools/gbppu/mbscore.py (which takes the ROM driver and the
# device). Run from the world's own directory so its binary is the one scored.
set -e
W=/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556
WORLD=$1; DEV=$2
export XDG_CACHE_HOME=$W/.cache
export DINGBAT_ROM_CACHE=$W/.romcache
export TMPDIR=$W/.tmp/tmp-$WORLD
mkdir -p "$TMPDIR"
cd "$W"
python3 tools/gbppu/mbscore.py "$W/.worlds/$WORLD/dingbat_test" "$DEV"
