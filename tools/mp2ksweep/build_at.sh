#!/usr/bin/env bash
# Build an MP2K harness from any commit, or from the working tree.
#
# Usage: build_at.sh <commit|WORKTREE> <sweep|probe|census|bench> <output binary>
#
#   sweep   tests/mp2k_sweep.nim   -d:danger -d:mp2kwav   (tools/mp2k_sweep.py, capture.sh)
#   probe   tests/mp2k_probe.nim   -d:danger -d:mp2kwav   (tools/mp2kprobe)
#   census  tests/mp2k_sweep.nim   -d:danger -d:mp2kwav -d:mp2kwcensus  (runs.py census)
#   bench   tests/dingbat_bench.nim -d:release            (bench_ab.sh)
#
# A commit is exported with `git archive` (src, tests, nim.cfg) into a
# temporary directory, so the checkout is never touched. Commits from before
# 2026-09-15 kept a real-stream sample from before the HLE was armed, which
# puts the two captures a sample apart; the sweep and probe harnesses are
# patched to clear both captures, so every build compares the same way. That
# is the only change made to an exported tree.
set -euo pipefail

rev=${1:?commit or WORKTREE}
target=${2:?sweep, probe, census or bench}
out=$(cd "$(dirname "${3:?output binary}")" && pwd)/$(basename "$3")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

case $target in
  sweep)  src=tests/mp2k_sweep.nim;   flags=(-d:danger -d:mp2kwav -d:test_harness --mm:arc) ;;
  probe)  src=tests/mp2k_probe.nim;   flags=(-d:danger -d:mp2kwav -d:test_harness --mm:arc) ;;
  census) src=tests/mp2k_sweep.nim;   flags=(-d:danger -d:mp2kwav -d:mp2kwcensus -d:test_harness --mm:arc) ;;
  bench)  src=tests/dingbat_bench.nim; flags=(-d:release -d:test_harness) ;;
  *) echo "unknown target: $target" >&2; exit 2 ;;
esac

if [ "$rev" = WORKTREE ]; then
  tree=$root
else
  tree=$(mktemp -d "${TMPDIR:-/tmp}/mp2k_build_at.XXXXXX")
  trap 'rm -rf "$tree"' EXIT
  git -C "$root" archive "$rev" src tests nim.cfg | tar -x -C "$tree"
  for h in tests/mp2k_sweep.nim tests/mp2k_probe.nim; do
    [ -f "$tree/$h" ] || continue
    python3 - "$tree/$h" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
if 'realDmaCapture.setLen(0)' in s:
    sys.exit(0)
a = '  emu.mp2k_hle = getEnv("DINGBAT_NOHLE") != "1"\n'
if s.count(a) != 1:
    sys.exit(0)
s = s.replace(a, a + '  when defined(mp2kwav):\n    realDmaCapture.setLen(0)\n    mp2kWavCapture.setLen(0)\n')
open(p, 'w').write(s)
EOF
  done
fi

cd "$tree"
rm -f "$out"
nim c "${flags[@]}" --hints:off --nimcache:"${TMPDIR:-/tmp}/mp2k_build_at_cache_${target}_${rev//\//_}" \
  --path:src -o:"$out" "$src" 2>&1 | grep -v AboveMaxSizeSet | grep -E "Error" || true
[ -x "$out" ] && echo "built $out ($target at $rev)"
