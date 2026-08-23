# pandocs-upstream: corrections to send upstream, and what hardware must settle first

Companion to docs/pandocs-audit.md. §1 is draftable as gbdev/pandocs PRs; §2
needs hardware first.

## 1. Upstream corrections (evidence settled)

1. **Speed-switch stall** (CGB_Registers, KEY1): "2050 M-cycles" is ~16×
   short — 131072 destination-clock cycles (gambatte `speedchange_tima00_*`
   +128 TIMA ticks, LY across the stall, daid `speed_switch_timing_*`). "DIV
   does not tick" belongs to true STOP only; the +128 ticks need a live timer.
2. **TMA write during the reload cycle** (Timer_and_Divider_Registers): the
   new value lands (mooneye `tma_write_reloading`; Pan Docs' own Obscure page
   agrees). Internal contradiction.
3. **HDMA5 readback after early termination** (CGB_Registers): the terminating
   write's own low 7 bits, not "remaining − 1" (SameSuite `dma/hdma_lcd_off`).
4. **MBC3 RTC latch** (MBC3): any `$6000` write latches — CasualPokePlayer
   `latch-rtc-test` capture 51/51 vs 28/51 for a bit-0 edge.
5. **Printer status bit 2** (Gameboy_Printer): bit 3 is data-present, bit 2
   print-done; clear-on-read variants leave Hello Kitty re-printing forever on
   real carts.
6. **"CPU can access only HRAM during OAM DMA"** (OAM_DMA_Transfer): the CPU
   uses the other bus freely; 314 gambatte `oamdma/busy*` rows, 0 mismatches.
7. **CGB registers in Non-CGB mode** (Power_Up_Sequence footnote): VBK reads
   `$FE|bank`, FF72/73/75 stay live (mooneye `misc/bits/unused_hwio-C`);
   KEY1/SVBK/HDMA/RP/FF74 do read $FF. Split the list.
8. **X=0 object penalty** (pixel_fifo vs Rendering): flat 11 at every SCX
   residue (GBMicrotest `ppu_spritex_vs_scx`, 153/153).
9. **Window Y condition needs LCDC.5 at the match** (Window): as written it
   predicts a white column through Pokemon Blue's intro (WX=7, WY=0, window
   never enabled); silicon shows none. The formulation itself is pinned by
   the game and emulator comparison only.
10. **DMG STAT-write glitch in "OAM scan"** (STAT): a write one M-cycle into
    mode 2 is silent (GBMicrotest `stat_write_glitch_l0_c/l1_d/l154_c`); only
    the hblank→mode-2 edge fires.
11. **Post-boot SC on CGB** (Power_Up_Sequence): $7C on AGS hardware, not $7F
    (gbedge p00, docs/flashcart-runbook.md).
12. **SVBK readback** (CGB_Registers): write 0 reads back raw $F8 on AGS.

## 2. Validate on hardware first

- **CGB TAC-disable glitch tick** — Pan Docs: Color models skip it; dingbat
  ticks. gbedge p02 bytes 10–13 captured on MGB + AGS, undecoded.
- **Glitch-overflow window interior** — whether TIMA reads $00 and the cycle-B
  rules apply to a DIV-write overflow; p03 TIMARELOAD matched dingbat on both
  consoles; a GBMicrotest-shaped ROM is needed.
- **Post-boot P1 on SGB/CGB** — Pan Docs $C7/$CF; dingbat $FF (the AGB boot
  ROM writes $FF, mooneye `misc/boot_hwio-C`); the AGS $CF photo is menu
  contamination. SGB and a menu-free CGB read wanted.
- **MBC5 RAM-enable value** — nibble (current Pan Docs, dingbat) vs exact
  $0A; write $1A to a real MBC5 cart.
- **CGB LCDC.5-clear resets the window Y condition** — flashcart folder 2.
- **CGB object fetch with LCDC.1 off** — Pan Docs says it happens; dingbat
  skips it (gambatte `oamdma/late_sp*` phase swap); STAT-poll ROM on CGB.
- **CRAM lock edges** — 11 gambatte `cgbpal_*` double-speed/lcdoffset rows
  remain; dot-level capture (folder 5).
- **Envelope trigger-before-step +1; NR10 pace 0→nonzero reload** — no
  SameSuite row; a PCM-probe ROM per rule.
- **HPF charge per model** — analog capture.
- **CH3 sample buffer on NR30 DAC-off** — re-run SameSuite
  `channel_3_restart_stop_delay` on hardware (folder 7).
- **Plain-access OAM corruption** — a ROM sweeping plain reads/writes and
  `$FEA0-$FEFF` in mode 2; blargg `oam_bug` is green either way.
- **Window glitch insert/replace + arming**; **OAM-DMA vs mode-2 scan lock** —
  hwprobe rows 19 and 18.

## 3. Deferred implementation work

- SGB multiplayer input routing (every MLT_REQ ID reads one pad; the 2P
  link-mode input path is the donor).
- Plain-access OAM corruption, once the call-site design avoids double-firing
  the IDU sites.
- Compat-mode colorization table (boot-ROM data deliberately not lifted).
