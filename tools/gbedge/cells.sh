#!/bin/sh
# cells.sh <tag> -- the CGB TILE_SEL arbitration corpus for one px-trace build.
set -e
W=/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556
TAG=$1
export XDG_CACHE_HOME=$W/.cache
export DINGBAT_ROM_CACHE=$W/.romcache
export TMPDIR=$W/.tmp/tmp-$TAG
mkdir -p "$TMPDIR" "$W/.tmp/cells-$TAG"
cd "$W"
python3 tools/gbppu/tdselcells.py "./dt_px-$TAG" "$W/.tmp/cells-$TAG"
