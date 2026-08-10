#!/bin/bash
# Campaign environment for the scx_during_m3 / mode-3 structure derivation.
# Everything the runner and the harness touch is kept inside this worktree.
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export XDG_CACHE_HOME="$W/.cache"
export DINGBAT_ROM_CACHE="$W/.romcache"
export TMPDIR="$W/.tmp"
mkdir -p "$XDG_CACHE_HOME" "$DINGBAT_ROM_CACHE" "$TMPDIR"
export WORKTREE="$W"
export ROMS="$W/.romcache/game-boy-test-roms"
