#!/usr/bin/env bash
# Sweep the picked ROM list with one sweep binary.
#
# Usage: sweep.sh <sweep binary> <run dir> [picked list] [workers]
#
# Writes <run dir>/results.jsonl and sweep.log. Resumable (tools/mp2k_sweep.py
# skips ROMs already in the JSONL); delete results.jsonl to start over. The
# ROM directory is $MP2K_ROMS (default ~/Documents/emu/gba/archive/roms). Any
# DINGBAT_* variables in the environment reach every run (the harness's A/B
# switches, tests/mp2k_sweep.nim header). 2354 ROMs take about 6 minutes on 8
# workers.
set -euo pipefail

bin=${1:?sweep binary}
run=${2:?run dir}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
picked=${3:-$root/tools/mp2ksweep/picked.txt}
workers=${4:-8}
roms=${MP2K_ROMS:-$HOME/Documents/emu/gba/archive/roms}

mkdir -p "$run"
python3 "$root/tools/mp2k_sweep.py" "$picked" "$roms" "$run/scratch" "$run/results.jsonl" \
  --bin "$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")" --workers "$workers" > "$run/sweep.log" 2>&1
rm -rf "$run/scratch"
tail -1 "$run/sweep.log"
