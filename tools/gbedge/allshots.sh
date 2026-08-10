#!/bin/sh
# allshots.sh <baseWorld> <world...> -- diff every captured witness of this axis
# across worlds, against the first one named.
W=/Users/matt/code/dingbat/.claude/worktrees/agent-a23f3fac6bc332556
cd "$W"
for t in strike-cgb strike-dmg acidhell acid2-cgb acid2-dmg daid-cgb daid-dmg \
         mb-m3_bgp_change-cgb mb-m3_bgp_change-dmg \
         mb-m3_bgp_change_sprites-cgb mb-m3_obp0_change-cgb \
         mb-m3_lcdc_tile_sel_change-cgb mb-m3_lcdc_tile_sel_change2-cgb \
         mb-m3_lcdc_tile_sel_win_change-cgb mb-m3_lcdc_tile_sel_change-dmg \
         mb-m3_lcdc_bg_en_change-cgb mb-m3_lcdc_obj_en_change-cgb \
         mb-m3_scx_high_5_bits-cgb mb-m3_scx_high_5_bits-dmg; do
  [ -f "$W/.shots/$t.$1.ppm" ] || continue
  python3 tools/gbedge/diffshots.py "$t" "$@"
done
