#!/bin/sh
# witness.sh <world> -- capture every screenshot witness of the 2026-08-10
# renderer-phase question from one built world.
#
#   strike-cgb / strike-dmg   the OAM-DMA-vs-object-fetch race
#   acidhell                  the CGB LCDC.4 mid-fetch glitch
#   daid-cgb  / daid-dmg      the BGP-write-vs-emission ruler
#   acid2-cgb / acid2-dmg     the two control frames that must never move
set -e
W=/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556
WORLD=$1
R=$W/.romcache
D=$W/.worlds/$WORLD
mkdir -p "$W/.shots" "$W/.tmp/tmp-$WORLD"
export XDG_CACHE_HOME=$W/.cache
export DINGBAT_ROM_CACHE=$R
export TMPDIR=$W/.tmp/tmp-$WORLD
cd "$D"
shot() {
  tag=$1; rom=$2
  shift 2
  ./dingbat_test "$rom" --mode=screenshot --screenshot="$W/.shots/$tag.$WORLD.ppm" "$@" >/dev/null 2>&1 || true
}
shot strike-cgb "$R/game-boy-test-roms/strikethrough/strikethrough.gb" --cgb --color --timeout=400
shot strike-dmg "$R/game-boy-test-roms/strikethrough/strikethrough.gb" --timeout=400
shot acidhell   "$R/game-boy-test-roms/cgb-acid-hell/cgb-acid-hell.gbc" --cgb --color --timeout=400
shot daid-cgb   "$R/shootout-38b926b/daid/ppu_scanline_bgp.gb" --cgb --color --timeout=400
shot daid-dmg   "$R/shootout-38b926b/daid/ppu_scanline_bgp.gb" --timeout=400
shot acid2-cgb  "$R/cgb-acid2.gbc" --cgb --color --timeout=400
shot acid2-dmg  "$R/dmg-acid2.gb" --timeout=400
ls "$W/.shots" | grep "\.$WORLD\.ppm" | tr '\n' ' '
echo ""
