#!/bin/sh
# mealy.sh <world> -- capture the mealybug PPU frames this axis moves, from one
# built world, on BOTH devices.
#
# The CGB arm runs the DMG cart on a CGB in compatibility mode, which is the
# machine the `_cgb_c` / `_cgb_d` references capture.
set -e
W=/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556
WORLD=$1
M=$W/.romcache/game-boy-test-roms/mealybug-tearoom-tests/ppu
mkdir -p "$W/.shots" "$W/.tmp/tmp-$WORLD"
export XDG_CACHE_HOME=$W/.cache
export DINGBAT_ROM_CACHE=$W/.romcache
export TMPDIR=$W/.tmp/tmp-$WORLD
cd "$W/.worlds/$WORLD"
for r in m3_bgp_change m3_bgp_change_sprites m3_obp0_change \
         m3_lcdc_tile_sel_change m3_lcdc_tile_sel_change2 \
         m3_lcdc_tile_sel_win_change m3_lcdc_tile_sel_win_change2 \
         m3_lcdc_bg_en_change m3_lcdc_obj_en_change m3_scx_high_5_bits; do
  [ -f "$M/$r.gb" ] || continue
  ./dingbat_test "$M/$r.gb" --cgb --color --mode=screenshot \
      --screenshot="$W/.shots/mb-$r-cgb.$WORLD.ppm" --timeout=400 \
      >/dev/null 2>&1 || true
  ./dingbat_test "$M/$r.gb" --mode=screenshot \
      --screenshot="$W/.shots/mb-$r-dmg.$WORLD.ppm" --timeout=400 \
      >/dev/null 2>&1 || true
done
ls "$W/.shots" | grep -c "\.$WORLD\.ppm"
