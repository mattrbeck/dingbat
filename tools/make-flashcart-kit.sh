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

# 7 — APU: CH3 buffer-on-DAC-off (three-way emulator split) + sweep restarts
cp "$CACHE"/same-suite/apu/channel_3/channel_3_restart_stop_delay.gb      "$KIT/7-apu/"
cp "$CACHE"/same-suite/apu/channel_1/channel_1_sweep_restart.gb \
   "$CACHE"/same-suite/apu/channel_1/channel_1_sweep_restart_2.gb         "$KIT/7-apu/" 2>/dev/null || true

echo "kit assembled:"
find "$KIT" -type f | sort | sed 's/^/  /'
echo
echo "copy the whole $KIT/ folder to the flashcart SD card;"
echo "then follow docs/flashcart-runbook.md."
