#!/usr/bin/env bash
# probe_c_cmp -- probe (c)'s two staircases (BGP band edge = emission, LCDC.4
# glitch column = fetch grid; only `glit - band` is meaningful, see
# arbread.py), dingbat against the sameboy_runner. Both are shot at frame 400
# (the runner reads blank on this ROM before that). The cart has no CGB flag
# (BGP is dead in CGB-native mode), so this is compatibility mode: dingbat
# gets --cgb and the runner GBFUZZ_MODEL=cgb (it otherwise picks its model
# off the cart flag).
#
#   tools/gbprobe/probe_c_cmp.sh [SCXVAL] [-d:KNOB=V ...]
set -uo pipefail
cd "$(dirname "$0")/../.."
# The runner is built for CGB-E and dingbat defaults to CGB-C; force rev E.
# SB_REV overrides.
SB_REV=${SB_REV:---cgb-rev=E}
T=${TMPDIR:-/tmp}
SCXV=${1:-0}; shift || true
SB=${SAMEBOY_RUNNER:-tools/gbfuzz/sameboy_runner}
BR=${SAMEBOY_BOOTROMS:-$HOME/code/SameBoy/build/bin/BootROMs}

nim c --nimcache:$T/nc-pc -d:test_harness -d:release --path:src "$@" \
    -o:$T/dt_pc tests/dingbat_test.nim >$T/pc.log 2>&1 || {
  echo "build failed"; tail -5 $T/pc.log; exit 1; }

GBPROBE_CGB=0 GBPROBE_OUT=pc_cmp ./tools/gbprobe/mk.sh probe_c_arbitrate \
    -DSCXVAL=$SCXV >/dev/null 2>&1
$T/dt_pc tools/gbprobe/pc_cmp.gb --mode=screenshot --cgb $SB_REV --timeout=400 \
    --screenshot=$T/pc_d.ppm >/dev/null 2>&1
GBFUZZ_MODEL=cgb $SB tools/gbprobe/pc_cmp.gb "$BR" $T/pc_o "" 400 >/dev/null 2>&1

echo "== SCX $SCXV, knobs: ${*:-<stock>}"
echo "-- dingbat"
python3 tools/gbprobe/arbread.py $T/pc_d.ppm 2>&1 | head -14
echo "-- SameBoy"
python3 tools/gbprobe/arbread.py $T/pc_o.f0400.ppm 2>&1 | head -14
rm -f tools/gbprobe/pc_cmp.gb tools/gbprobe/pc_cmp.sym
