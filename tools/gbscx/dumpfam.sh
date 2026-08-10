#!/bin/bash
# Dump every scored frame of one gambatte subdirectory as a PPM, next to the
# per-row verdicts. `DINGBAT_GAM_DUMP` names the frames `<idx>_<dev>_<stem>.ppm`
# and the TSV's line <idx> carries the reference PNG, so the two are paired by
# index.
#
#   tools/gbscx/dumpfam.sh scx_during_m3 .tmp/scxdump [./dingbat_test]
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
FAM=$1
OUT=$2
DT=${3:-./dingbat_test}
rm -rf "$OUT"
mkdir -p "$OUT"
GAMROOT="$ROMS/gambatte" python3 tools/gbppu/gamlist.py "$FAM" > "$OUT/list.tsv"
DINGBAT_GAM_DUMP="$OUT" "$DT" --mode=gambatte --list="$OUT/list.tsv" --out="$OUT/verdicts.txt"
wc -l < "$OUT/list.tsv"
