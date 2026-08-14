#!/bin/bash
# Score daid's three speed-switch frames with a given dingbat_test binary and
# print the wrong-pixel count of each against its reference PNG. These are the
# only pixel witnesses in the tree for the PPU's advance across a KEY1 switch,
# and they are top-level GREEN results.md rows: any speed-switch change has to
# leave all three at 0. `strikethrough-cgb` rides along because it is the row
# `CGB_HALT_PPU_LEAD` is held back by, and that constant moves with these.
#
#   tools/gbppu/daidswitch.sh [<dingbat_test>]
cd "$(dirname "$0")/../.."
H="${1:-./dingbat_test}"
D=$(echo /tmp/dingbat-test-roms/shootout-*/daid)
S=/tmp/dingbat-test-roms/game-boy-test-roms/strikethrough
W=$(mktemp -d)
for which in div ly stat; do
  "$H" "$D/speed_switch_timing_$which.gbc" --mode=screenshot --cgb --color \
       --timeout=30 --screenshot="$W/$which.ppm" --nosave >/dev/null 2>&1
  python3 tools/gbppu/pngdiff.py "$D/speed_switch_timing_$which.png" \
          "$W/$which.ppm" "$which"
done
"$H" "$S/strikethrough.gb" --mode=screenshot --cgb --color --timeout=60 \
     --screenshot="$W/sc.ppm" --nosave >/dev/null 2>&1
python3 tools/gbppu/pngdiff.py "$S/strikethrough-cgb.png" "$W/sc.ppm" strike-c
"$H" "$S/strikethrough.gb" --mode=screenshot --timeout=60 \
     --screenshot="$W/sd.ppm" --nosave >/dev/null 2>&1
python3 tools/gbppu/pngdiff.py "$S/strikethrough-dmg.png" "$W/sd.ppm" strike-d
rm -rf "$W"
