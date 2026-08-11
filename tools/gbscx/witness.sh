#!/bin/bash
# The witness ladder of the 2026-08-10 renderer-phase question, captured from
# THIS worktree's ./dingbat_test into .shots/<tag>.<world>.ppm.
#
# Same seven frames as tools/gbedge/witness.sh, plus daid on CGB at the two
# revisions the row is sensitive to. Any change to mode 3 has to answer for all
# of them; the ones that must never move are the two acid2 frames and both
# strikethrough frames.
#
#   tools/gbscx/witness.sh <world-tag> [binary]
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
WORLD=$1
DT=${2:-./dingbat_test}
R=$ROMS
mkdir -p "$WORKTREE/.shots"
shot() {
  tag=$1; rom=$2
  shift 2
  "$DT" "$rom" --mode=screenshot \
    --screenshot="$WORKTREE/.shots/$tag.$WORLD.ppm" "$@" >/dev/null 2>&1 || true
}
shot strike-cgb "$R/strikethrough/strikethrough.gb" --cgb --color --timeout=400
shot strike-dmg "$R/strikethrough/strikethrough.gb" --timeout=400
shot acidhell-c "$R/cgb-acid-hell/cgb-acid-hell.gbc" --cgb --color --cgb-rev=C --timeout=400
shot acidhell-e "$R/cgb-acid-hell/cgb-acid-hell.gbc" --cgb --color --cgb-rev=E --timeout=400
shot daid-cgbD  "$WORKTREE/.romcache/shootout-38b926b/daid/ppu_scanline_bgp.gb" --cgb --color --cgb-rev=D --timeout=400
shot daid-cgbC  "$WORKTREE/.romcache/shootout-38b926b/daid/ppu_scanline_bgp.gb" --cgb --color --cgb-rev=C --timeout=400
shot daid-dmg   "$WORKTREE/.romcache/shootout-38b926b/daid/ppu_scanline_bgp.gb" --timeout=400
shot acid2-cgb  "$WORKTREE/.romcache/cgb-acid2.gbc" --cgb --color --timeout=400
shot acid2-dmg  "$WORKTREE/.romcache/dmg-acid2.gb" --timeout=400
ls "$WORKTREE/.shots" | grep "\.$WORLD\.ppm" | tr '\n' ' '
echo ""
