#!/bin/bash
# Assemble flashcart-kit/ — everything to load on a GB flashcart for the
# hardware-validation session. Pairs with docs/flashcart-runbook.md, which
# says what to do with each ROM and what each photo settles.
#
# Sources: the repo's probe ROM, the game-boy-test-roms bundle (auto-cached
# by the test runner; run `DINGBAT_ROM_CACHE=... ./dingbat_test_runner` once
# if the cache is empty), and nitro2k01's windesync ROM (downloaded from its
# SameBoy-issue attachment).
set -euo pipefail
cd "$(dirname "$0")/.."

CACHE="${DINGBAT_ROM_CACHE:-/tmp/dingbat-test-roms}/game-boy-test-roms"
KIT=flashcart-kit
[ -d "$CACHE" ] || { echo "bundle cache not found at $CACHE — run the test runner once"; exit 1; }
rm -rf "$KIT"
mkdir -p "$KIT"/{1-gbedge,2-windesync,3-window-glitch,4-timer,5-cram-lock,6-oamdma-phase,7-apu}

# 1 — the probe ROM (raw-value pages; the headline flash)
cp tests/roms/gbedge.gb "$KIT/1-gbedge/"

# 2 — nitro2k01's window-desync ROM (SameBoy issue #278; hwprobe row 19)
curl -sL -o "$KIT/2-windesync/windesync-2022-07-20.zip" \
  https://github.com/LIJI32/SameBoy/files/9145812/windesync-2022-07-20.zip
(cd "$KIT/2-windesync" && unzip -oq windesync-2022-07-20.zip && rm windesync-2022-07-20.zip)

# 3 — window-glitch neighbors: the mealybug ruler (insert-vs-replace axis),
#     the CGB LCDC.5 Y-condition question, and strikethrough (hwprobe row 18)
cp "$CACHE"/mealybug-tearoom-tests/ppu/m3_lcdc_win_en_change_multiple_wx.gb "$KIT/3-window-glitch/"
cp "$CACHE"/mealybug-tearoom-tests/ppu/m2_win_en_toggle.gb               "$KIT/3-window-glitch/"
cp "$CACHE"/strikethrough/strikethrough.gb                                "$KIT/3-window-glitch/"

# 4 — timer: the CGB TAC-disable arbitration ROM (gbedge p02 also covers it)
cp "$CACHE"/mooneye-test-suite/acceptance/timer/rapid_toggle.gb           "$KIT/4-timer/"

# 5 — CRAM mode-3 lock edges: the whole cgbpal_m3 family + the LCD-on rows
cp "$CACHE"/gambatte/cgbpal_m3/*.gbc                                      "$KIT/5-cram-lock/"
cp "$CACHE"/gambatte/enable_display/ly0_late_cgbp*.gbc                    "$KIT/5-cram-lock/"

# 6 — the CGB obj-fetch-while-disabled phase (the A13 revert's arbiter)
cp "$CACHE"/gambatte/oamdma/late_sp00*.gbc "$CACHE"/gambatte/oamdma/late_sp01*.gbc \
   "$CACHE"/gambatte/oamdma/late_sp39*.gbc \
   "$CACHE"/gambatte/oamdma/oamdma_late_speedchange_stat_*.gbc            "$KIT/6-oamdma-phase/"

# 8 — the shootout's 261st row: acid-hell itself, daid's band-edge ROM, and
#     the probe rig. probe (c) is a DMG cart on purpose (its BGP ruler is
#     inert in native-CGB mode); probe (d) is CGB-flagged to match the
#     native-mode evidence, with a _compat build as the control.
mkdir -p "$KIT"/8-shootout-261
cp "$CACHE"/cgb-acid-hell/cgb-acid-hell.gbc                               "$KIT/8-shootout-261/"
cp tools/gbprobe/probe_c_arbitrate.gb tools/gbprobe/probe_c_arbitrate_scx3.gb \
   tools/gbprobe/probe_c_arbitrate_scx7.gb tools/gbprobe/probe_a_statidiom.gb \
   tools/gbprobe/probe_b_scxm3.gb                                         "$KIT/8-shootout-261/"
# probe_cart: run this FIRST. It checks the flash cartridge is returning the
# ROM's real bytes (three access orders + an address-line hammer), so every
# other reading in the session rests on something checked rather than assumed.
mkdir -p "$KIT"/0-cart-check
cp tools/gbprobe/probe_cart.gb "$KIT/0-cart-check/"

# probe (d): the tile-select latency measurement that decides the 261st row.
# Read it by eye (sixteen bands, light vs dark) or with read_probe_d.py; the
# registered predictions are in docs/probe-d-tdsel.md.
cp tools/gbprobe/probe_d_tdsel.gb tools/gbprobe/probe_d_tdsel_scx*.gb \
   tools/gbprobe/probe_d_tdsel_compat.gb                                  "$KIT/8-shootout-261/"
# probe (e): ONE paged ROM -- D-pad picks SCX (left/right) and the object's X
# (up/down), so a whole sweep is one flashcart boot instead of thirteen. It
# subsumes probe (d): set the object to OFF and it IS probe (d).
cp tools/gbprobe/probe_e_objgrid.gb                                       "$KIT/8-shootout-261/"

DAID="$HOME/code/GBEmulatorShootout/testroms/daid/ppu_scanline_bgp.gb"
[ -f "$DAID" ] && cp "$DAID" "$KIT/8-shootout-261/" || \
  echo "note: $DAID not found — daid ROM skipped (clone GBEmulatorShootout)"

# 7 — APU: CH3 buffer-on-DAC-off (three-way emulator split) + sweep restarts
cp "$CACHE"/same-suite/apu/channel_3/channel_3_restart_stop_delay.gb      "$KIT/7-apu/"
cp "$CACHE"/same-suite/apu/channel_1/channel_1_sweep_restart.gb \
   "$CACHE"/same-suite/apu/channel_1/channel_1_sweep_restart_2.gb         "$KIT/7-apu/" 2>/dev/null || true

# 9 — g1: the halt-wake PPU phase (docs/hwprobe-questions.md, v8 section).
# TWO fixed builds rather than the paged ROM in folder 8, deliberately: the
# whole question is a 4-dot phase and a wrong d-pad press would silently answer
# a different one. Each ROM prints its own settings in the header, so the photo
# is self-labelling. Predictions for all three candidate models are rendered
# next to them, 3x, so the answer can be read by eye before any tooling runs.
mkdir -p "$KIT/9-halt-lead"
for S in 0 4; do
  GBPROBE_CGB=1 GBPROBE_OUT=g1_scx$S ./tools/gbprobe/mk.sh probe_e_objgrid \
      -DSCX_DEFAULT=$S -DOBJX_DEFAULT='$FF' >/dev/null
  mv tools/gbprobe/g1_scx$S.gb "$KIT/9-halt-lead/"
  rm -f tools/gbprobe/g1_scx$S.sym
done
cp tools/gbprobe/g1_README.md "$KIT/9-halt-lead/README.md"
echo "note: folder 9's predicted-*.png are rendered by hand -- see its README"

echo "kit assembled:"
find "$KIT" -type f | sort | sed 's/^/  /'
echo
echo "copy the whole $KIT/ folder to the flashcart SD card;"
echo "then follow docs/flashcart-runbook.md."
