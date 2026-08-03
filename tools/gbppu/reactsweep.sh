#!/bin/bash
# Sweep WIN_REACT_PHASE against the three mealybug ROMs that see the window's
# re-trigger edge, the way the constant was originally pinned.
cd "$(dirname "$0")/../.."
for n in 0 1 2 3 4 5 6 7; do
  nim c -d:test_harness -d:release --path:src -d:WIN_REACT_PHASE=$n \
    -o:/tmp/dt_react tests/dingbat_test.nim >/dev/null 2>&1 || { echo "$n BUILD FAIL"; continue; }
  printf "phase %d: " "$n"
  python3 tools/gbppu/mbscore.py /tmp/dt_react 2>/dev/null |
    grep -E "m3_wx_[456]_change|m3_window_timing |m3_lcdc_win_en_change_multiple " |
    tr '\n' ' '
  echo
done
