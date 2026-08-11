#!/bin/bash
# The per-SCX mode 3 -> 0 ladders, as dots rather than verdicts.
#
# `m2int_m3stat/scx/m2int_scxN_m3stat_{1,2}` is one ROM per SCX residue that
# takes a mode-2 interrupt and reads STAT a swept number of M-cycles later, so
# the pair brackets the 3 -> 0 edge to one M-cycle at that residue. Printing our
# edge next to the read dot says, per residue, how far our edge is from the
# window hardware puts it in -- which a pass/fail column cannot.
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
D="$ROMS/gambatte/m2int_m3stat/scx"
DEV=${1:-}
for f in "$D"/*.gbc; do
  case "$(basename "$f")" in
    *_ds_*) [ "$DEV" = "--cgb" ] || continue ;;
  esac
  bash tools/gbscx/edgemap.sh "${DT:-./dt_all}" $DEV "$f"
done
