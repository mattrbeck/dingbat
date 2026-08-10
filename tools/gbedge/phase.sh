#!/bin/sh
# phase.sh <pxtag> -- tools/gbppu/tdselphase.py for one px-trace build: what an
# LCDC.4 change does at every OFFSET from a background bitplane read.
set -e
W=/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556
TAG=$1
export XDG_CACHE_HOME=$W/.cache
export DINGBAT_ROM_CACHE=$W/.romcache
export TMPDIR=$W/.tmp/tmp-$TAG
mkdir -p "$TMPDIR" "$W/.tmp/phase-$TAG"
cd "$W"
python3 tools/gbppu/tdselphase.py "./dt_px-$TAG" "$W/.tmp/phase-$TAG"
