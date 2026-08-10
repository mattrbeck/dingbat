#!/bin/sh
# bench.sh <world> <rom> [frames] [warmup] [extra dingbat_bench args]
# Retired-instruction counters for one world. Per docs/gb_oam_dma_cost.md:
# wall-clock has a ~1.3% layout noise floor and retired instructions reproduce
# to 0.002%, so this is the only A/B worth quoting -- and `cycles=` must match
# between arms or they did different work.
#
# Each world gets its own ROM symlink directory so no .sav crosses builds.
set -e
W=/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556
WORLD=$1; ROM=$2; FRAMES=${3:-2400}; WARMUP=${4:-300}
shift 4 2>/dev/null || shift $#
D=$W/.worlds/$WORLD
R=$D/benchroms
mkdir -p "$R" "$W/.tmp/tmp-$WORLD"
rm -f "$R"/*.sav
case $ROM in /*) SRC=$ROM ;; *) SRC=$W/$ROM ;; esac
ln -sf "$SRC" "$R/$(basename "$SRC")"
export XDG_CACHE_HOME=$W/.cache
export DINGBAT_ROM_CACHE=$W/.romcache
export TMPDIR=$W/.tmp/tmp-$WORLD
export DINGBAT_NO_WAITLOOP=1
export DINGBAT_BENCH_COUNTERS=1
cd "$D"
./dingbat_bench "$R/$(basename "$SRC")" "$FRAMES" "$WARMUP" "$@" 2>&1 \
  | grep -E "cycles=|instructions=" | tr '\n' ' '
echo ""
