#!/bin/bash
# Sweep the two OBJ-penalty terms against a gambatte subset.
#   tools/objsweep.sh <subdir>...
cd "$(dirname "$0")/../.."
for flat in 4 5 6 7 8; do
  for sub in 1 2 3 4 5; do
    nim c -d:test_harness -d:release -d:OBJ_FETCH_DOTS=$flat -d:OBJ_WAIT_SUB=$sub \
      --path:src -o:dt_sweep --nimcache:/tmp/nc_sweep tests/dingbat_test.nim > /dev/null 2>&1 || { echo "build fail $flat $sub"; continue; }
    python3 tools/gbppu/gamlist.py "$@" > /tmp/gam.tsv
    ./dt_sweep --mode=gambatte --list=/tmp/gam.tsv > /tmp/gamraw.txt 2>&1
    n=$(grep -c ' PASS' /tmp/gamraw.txt)
    t=$(grep -c '^GAM ' /tmp/gamraw.txt)
    echo "flat=$flat sub=$sub  $n / $t"
  done
done
