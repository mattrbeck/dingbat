#!/usr/bin/env bash
# mbrevcheck -- for every mealybug ROM whose _cgb_c and _cgb_d references
# differ, render dingbat at --cgb-rev=C and --cgb-rev=D and check each frame
# matches its own reference. Rows whose two references are byte-identical
# carry no revision axis and are skipped. Nothing else in the tree scores
# the _cgb_d captures.
#
#   tools/gbppu/mbrevcheck.sh      (needs ./dingbat_test built in the repo root)
# ROMs come from $DINGBAT_ROM_CACHE (default /tmp/dingbat-test-roms); scratch
# frames go to $GBPPU_TMP (default <repo>/.scratch/gbppu).
cd "$(dirname "$0")/../.."
T=${GBPPU_TMP:-$PWD/.scratch/gbppu}
mkdir -p "$T"
C=${DINGBAT_ROM_CACHE:-/tmp/dingbat-test-roms}/game-boy-test-roms/mealybug-tearoom-tests/ppu
px() { python3 tools/gbprobe/ppmdiff.py "$1" "$2" \
         | sed -n 's/^\([0-9][0-9]*\) differing pixels.*/\1/p' | head -1; }
for D in "$C"/*_cgb_d.png; do
  N=$(basename "$D" _cgb_d.png)
  CREF="$C/${N}_cgb_c.png"
  [ -f "$CREF" ] || continue
  DIFF=$(px "$CREF" "$D")
  [ "$DIFF" = "0" ] && continue          # references identical: no revision axis
  ./dingbat_test "$C/$N.gb" --mode=screenshot --cgb --cgb-rev=C --color \
      --timeout=120 --screenshot=$T/v_c.ppm >/dev/null 2>&1
  ./dingbat_test "$C/$N.gb" --mode=screenshot --cgb --cgb-rev=D --color \
      --timeout=120 --screenshot=$T/v_d.ppm >/dev/null 2>&1
  AC=$(px $T/v_c.ppm "$CREF"); AD=$(px $T/v_d.ppm "$D")
  VERDICT="OK"
  { [ "$AC" != "0" ] || [ "$AD" != "0" ]; } && VERDICT="** MISMATCH **"
  printf '%-38s refs differ %-6s revC-vs-c %-6s revD-vs-d %-6s %s\n' \
    "$N" "${DIFF}px" "${AC}px" "${AD}px" "$VERDICT"
done
