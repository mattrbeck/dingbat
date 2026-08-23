#!/usr/bin/env bash
# axisscore -- the three hardware-referenced frames that constrain the CGB
# halt-wake phase (CGB_HALT_PPU_LEAD), scored together for one knob set per
# line: cgb-acid-hell and strikethrough pull it in opposite directions, and
# daid's ppu_scanline_bgp anchors on the LY 153->0 snapback.
#
#   tools/gbppu/axisscore.sh "KNOB=V[,KNOB=V ...]" ...
# ROMs from $DINGBAT_ROM_CACHE (default /tmp/dingbat-test-roms).
set -uo pipefail
cd "$(dirname "$0")/../.."
T=${TMPDIR:-/tmp}
C=${DINGBAT_ROM_CACHE:-/tmp/dingbat-test-roms}/game-boy-test-roms
HELL=$C/cgb-acid-hell/cgb-acid-hell
ST=$C/strikethrough/strikethrough
DAID=$(dirname "$C")/shootout-38b926b/daid/ppu_scanline_bgp

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
  # daid's ppu_scanline_bgp: a DMG-flagged cart captured on a CGB in
  # compatibility mode, so --cgb at the captured revision.
  $T/dt_axis "$DAID.gb" --mode=screenshot --cgb --model=cgbe --color \
      --timeout=600 --screenshot=$T/ax_g.ppm >/dev/null 2>&1
  # CGB only: strikethrough's DMG arm needs the runner's palette handling.
  printf '%-46s acid-hell %4s px   strike-cgb %4s px   daid-gbc %5s px\n' \
    "$KV" "$(px $T/ax_h.ppm $HELL.png)" "$(px $T/ax_c.ppm $ST-cgb.png)" \
    "$(px $T/ax_g.ppm $DAID.gbc.png)"
done
