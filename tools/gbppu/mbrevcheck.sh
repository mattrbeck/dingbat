#!/usr/bin/env bash
# mbrevcheck -- does dingbat switch CGB revision behaviour where mealybug says
# it should?
#
# mealybug ships `_cgb_c` and `_cgb_d` captures of two silicon revisions, by the
# same author as cgb-acid-hell and Beaten Dying Moon, so they are the
# per-revision ground truth. Only the ROMs whose two references actually DIFFER
# carry a revision axis; for the rest the pair is byte-identical and any
# revision passes.
#
# NOTHING ELSE IN THE TREE SCORES `_cgb_d`. The local runner wires the 27
# `_cgb_c` rows only, and the shootout's mealybug CGB rows (which do define
# RevC/RevD variants in testroms/mealybug.py) are not in its active list at all
# -- its recorded dingbat run contains zero RevC/RevD rows. So a revision defect
# is invisible to both harnesses, which is exactly how the one below survived.
#
#   tools/gbppu/mbrevcheck.sh
cd /Users/matt/code/dingbat/.claude/worktrees/win-hold-zero-fix
T=/Users/matt/.claude/jobs/e4d5536b/tmp
C=$T/romcache/game-boy-test-roms/mealybug-tearoom-tests/ppu
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
