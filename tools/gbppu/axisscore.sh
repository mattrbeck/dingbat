#!/usr/bin/env bash
# axisscore -- the two ROMs that pull the CGB halt phase in opposite directions,
# scored together against their own references, for one knob set per line.
#
# `cgb-acid-hell` wants the PPU advanced after a STAT/LYC wake (it draws its
# LCDC writes 20-50 M-cycles after the halt); `strikethrough` refuses the same
# advance 112 M-cycles later, where it moves the OAM DMA's start dot and an
# object reads the wrong byte off the DMA bus. Both are silicon references and
# both fail on LINE 68. Any candidate for CGB_HALT_PPU_LEAD has to be read on
# both at once or it is only half a measurement -- which is what
# docs/gb-failure-triage.md means by "the consumers may not share one phase".
#
#   tools/gbppu/axisscore.sh "KNOB=V[,KNOB=V ...]" ...
set -uo pipefail
cd "$(dirname "$0")/../.."
T=${TMPDIR:-/tmp}
C=${DINGBAT_ROM_CACHE:-/tmp/dingbat-test-roms}/game-boy-test-roms
HELL=$C/cgb-acid-hell/cgb-acid-hell
ST=$C/strikethrough/strikethrough

px() {  # $1 = ppm, $2 = reference png
  python3 tools/gbprobe/ppmdiff.py "$1" "$2" \
    | sed -n 's/^\([0-9][0-9]*\) differing pixels.*/\1/p' | head -1
}

for KV in "$@"; do
  D=""
  [ "$KV" != "-" ] && for k in $(echo "$KV" | tr ',' ' '); do D="$D -d:$k"; done
  nim c --nimcache:$T/nc-axis -d:test_harness -d:release --path:src $D \
      -o:$T/dt_axis tests/dingbat_test.nim >$T/axis.log 2>&1 || {
    printf '%-46s BUILD FAILED\n' "$KV"; continue; }
  $T/dt_axis "$HELL.gbc" --mode=screenshot --cgb --color --timeout=120 \
      --screenshot=$T/ax_h.ppm >/dev/null 2>&1
  $T/dt_axis "$ST.gb" --mode=screenshot --cgb --color --timeout=120 \
      --screenshot=$T/ax_c.ppm >/dev/null 2>&1
  # CGB only. The DMG arm of strikethrough needs the runner's own device/palette
  # handling to score at all (rendered here it differs in all 23040 pixels,
  # which is a colour-pipeline artefact and not a result), and the phase under
  # test is CGB-specific anyway.
  printf '%-46s acid-hell %4s px   strike-cgb %4s px\n' \
    "$KV" "$(px $T/ax_h.ppm $HELL.png)" "$(px $T/ax_c.ppm $ST-cgb.png)"
done
