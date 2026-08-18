#!/usr/bin/env bash
# probe_c_cmp -- probe (c)'s two staircases, dingbat against SameBoy, in the
# EMULATORS. No photograph and therefore no registration problem, which is what
# blocks reading the hardware shots of this probe (it draws on black, so the
# frame has no visible border -- see docs/hwprobe-questions.md).
#
# probe (c) puts BOTH rulers on one frame: a BGP band edge (EMISSION) and an
# LCDC.4 pulse's glitched column (the FETCH GRID). Neither column means anything
# alone -- both carry the halt-wake latency -- but `glit - band` is internal to
# the frame, so it is exactly the emission-vs-fetch separation.
#
# SameBoy needs ~400 frames on this ROM where dingbat is settled by 200 (it
# reads blank before that), so both are taken at 400.
#
# The cart carries no CGB flag on purpose (BGP is dead in CGB-native mode), so
# this is CGB COMPATIBILITY mode: dingbat gets --cgb, SameBoy needs
# GBFUZZ_MODEL=cgb since it otherwise picks its model off the cart flag.
#
#   tools/gbprobe/probe_c_cmp.sh [SCXVAL] [-d:KNOB=V ...]
set -uo pipefail
cd "$(dirname "$0")/../.."
T=${TMPDIR:-/tmp}
SCXV=${1:-0}; shift || true
SB=${SAMEBOY_RUNNER:-tools/gbfuzz/sameboy_runner}
BR=${SAMEBOY_BOOTROMS:-$HOME/code/SameBoy/build/bin/BootROMs}

nim c --nimcache:$T/nc-pc -d:test_harness -d:release --path:src "$@" \
    -o:$T/dt_pc tests/dingbat_test.nim >$T/pc.log 2>&1 || {
  echo "build failed"; tail -5 $T/pc.log; exit 1; }

GBPROBE_CGB=0 GBPROBE_OUT=pc_cmp ./tools/gbprobe/mk.sh probe_c_arbitrate \
    -DSCXVAL=$SCXV >/dev/null 2>&1
$T/dt_pc tools/gbprobe/pc_cmp.gb --mode=screenshot --cgb --timeout=400 \
    --screenshot=$T/pc_d.ppm >/dev/null 2>&1
GBFUZZ_MODEL=cgb $SB tools/gbprobe/pc_cmp.gb "$BR" $T/pc_o "" 400 >/dev/null 2>&1

echo "== SCX $SCXV, knobs: ${*:-<stock>}"
echo "-- dingbat"
python3 tools/gbprobe/arbread.py $T/pc_d.ppm 2>&1 | head -14
echo "-- SameBoy"
python3 tools/gbprobe/arbread.py $T/pc_o.f0400.ppm 2>&1 | head -14
rm -f tools/gbprobe/pc_cmp.gb tools/gbprobe/pc_cmp.sym
