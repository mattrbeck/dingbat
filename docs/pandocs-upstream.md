# pandocs-upstream: corrections to send upstream, and what the flashcart must settle first

**Date:** 2026-08-14. Companion to `docs/pandocs-audit.md` (the full
disagreement list). Every entry here was triple-checked: dingbat's model and
its test evidence, SameBoy's implementation, and DocBoy's, read side by side.
Section 1 is where all the evidence lands on dingbat's side against today's
Pan Docs text — draftable as gbdev/pandocs PRs now. Section 2 is where the
evidence is split or absent — flash the cart before believing anyone.

## 1. Upstream corrections (evidence settled, Pan Docs text wrong or misleading)

1. **Speed-switch stall length + what runs during it** (CGB_Registers, KEY1).
   "2050 M-cycles / 8200 T-cycles" is ~16× short: SameBoy holds the CPU
   0x20008 T-states, DocBoy ≈16386/32769 M-cycles by direction, dingbat's
   131072-destination-clock model is pinned three independent ways (gambatte
   `speedchange_tima00_*` +128 TIMA ticks, LY across the stall, daid's
   pixel captures). And "DIV does not tick" belongs to the true-STOP leaves
   only — the timer/serial/OAM-DMA domain demonstrably runs through a speed
   switch (the +128 TIMA ticks are only possible with a live timer; SameBoy
   and DocBoy both keep it running).
2. **TMA write during the reload cycle** (Timer_and_Divider_Registers). The
   Timer page says the OLD value lands in TIMA; its own Obscure-Behaviour
   page, mooneye `tma_write_reloading`, SameBoy, DocBoy and dingbat all say
   the NEW value. Internal contradiction — fix the Timer page sentence.
3. **HDMA5 readback after early termination** (CGB_Registers). "How many
   blocks remained (minus 1)" only holds when software rewrites the count:
   hardware latches the terminating write's own low 7 bits (SameSuite
   `dma/hdma_lcd_off`; SameBoy and DocBoy both store the write's bits).
4. **MBC3 RTC latch condition** (MBC3). "$00 then $01" is the software
   convention, not the latch: CasualPokePlayer's latch-rtc-test hardware
   capture matches all 51 random-byte reports under "any write latches"
   (SameBoy agrees; a bit-0-edge rule — DocBoy's — misses 28 of 51).
5. **Printer status bit 2** (Gameboy_Printer). The status table's bit 2
   "Image data full" is wrong: bit 3 is data-present, bit 2 is
   printing/print-done (SameBoy printer.c; three clear-on-read variants
   against real carts left Hello Kitty re-printing forever — the done latch
   is load-bearing).
6. **"CPU can access only HRAM during OAM DMA"** (OAM_DMA_Transfer). True as
   advice, false as hardware: the CPU freely uses the OTHER bus (video vs
   external) during a DMA, per-bus conflicts only — 314 gambatte
   `oamdma/busy*` rows, 0 mismatches; SameBoy/DocBoy model the same split.
7. **CGB-register visibility in Non-CGB mode** (Power_Up_Sequence footnote).
   "KEY1/VBK/HDMA/RP/SVBK … read $FF in Non-CGB Mode" overreaches: VBK reads
   $FE|bank in compat mode and FF72/FF73/FF75 stay live (mooneye
   `misc/bits/unused_hwio-C`; SameBoy gates on `GB_is_cgb`, not mode;
   DocBoy likewise). KEY1/SVBK/HDMA/RP/FF74 do read $FF/open — the footnote
   just needs the register list split.
8. **X=0 object penalty** (pixel_fifo vs Rendering). The two pages contradict
   each other; GBMicrotest `ppu_spritex_vs_scx` (153/153 cells) settles it
   for Rendering.md's flat 11 at every SCX residue. pixel_fifo.md's
   SCX-dependent X=0 paragraph (self-flagged "not confirmed") should defer
   to it.
9. **Window Y condition needs the enable bit at the match** (Window,
   "rendering criteria"). As written, the Y condition sets on WY==LY alone —
   which, combined with the Star Trek insertion-glitch note, predicts a
   white column through Pokemon Blue's intro (WX=7, WY=0, window never
   enabled). Silicon shows none; SameBoy (`wy_check`) and DocBoy
   (`active_for_frame`) both require LCDC.5 at the match. One clause fixes
   both sections.
10. **DMG STAT-write glitch during OAM scan** (STAT). GBMicrotest's
    `stat_write_glitch_l0_c/l1_d/l154_c` land a write one M-cycle into mode
    2 and hardware stays silent; DocBoy never fires the mode-2 source, and
    SameBoy carves out exactly the hblank→mode-2 edge. The blanket "OAM
    scan" in the trigger list needs the edge caveat.

## 2. Validate on hardware first (evidence split or absent)

Ordered by how much hangs on the answer. Items marked [hwprobe N] are
already on the ranked flashcart list in docs/hwprobe-questions.md.

- **CGB TAC-disable glitch tick** — Pan Docs says Color models skip the
  DMG's disable-edge TIMA tick; SameBoy ("not tested or implemented",
  GiiBiiAdvance-sourced), DocBoy and dingbat all tick on CGB. One CGB run of
  a TAC-disable ROM decides it; nothing in mooneye/gambatte covers the CGB
  arm. If Pan Docs is right, dingbat needs a device gate in
  `timer_check_edge`.
- **Glitch-overflow window interior** — dingbat expresses the 1-M-cycle
  reload delay at its write-commit point (immediate reload there IS the
  delayed phase: arming the countdown instead fails mooneye `rapid_toggle`
  on both runners, measured 2026-08-14). What that phase cannot express is
  TIMA reading $00 and the cycle-B TIMA-write-ignore/TMA-follow rules for a
  DIV-write overflow specifically. A GBMicrotest-shaped ROM pins it.
- **Post-boot P1 and SC on SGB/CGB** — Pan Docs' table says P1 = $C7/$CF and
  SC(CGB) = $7F; dingbat and DocBoy(compat) read P1 = $FF, SameBoy's boot
  ROM hands off deselected (= $FF), and SC is a three-way split
  ($7C dingbat/DocBoy, $7E SameBoy, $7F Pan Docs). Trivial to read out on
  hardware at PC=$0100.
- **MBC5 RAM-enable value** — current Pan Docs: any low-nibble-$A enables;
  SameBoy compares exactly $0A; DocBoy nibble; dingbat switched to nibble
  this round. Write $1A to a real MBC5 and read RAM back.
- **CGB LCDC.5-clear resets the window Y condition** (Window's CGB note) —
  no emulator of the three models it; nothing in mealybug/gambatte covers
  it. Clear LCDC.5 mid-frame with WY matched, re-enable with LY > WY,
  photograph.
- **CGB object fetch with LCDC.1 off** — Pan Docs and SameBoy say the fetch
  (and its mode-3 cost) happens on CGB with objects disabled; DocBoy and
  (until this round) dingbat skip it. dingbat now models it; a STAT-poll
  ROM on CGB hardware confirms the mode-3 stretch.
- **CRAM lock edges** — the mode-3 BCPD/OCPD lock shipped this round gates
  on the latched mode (gambatte cgbpal_m3 16→33/44); the 11 rows still red
  are double-speed/lcdoffset boundary phases on the same sub-M-cycle grid
  the CGB write-latency study parked (CGB_WX_LATENCY). Hardware dot-level
  capture of the lock's two edges would close both files at once.
- **Envelope trigger-before-step +1 and NR10 pace 0→nonzero reload**
  (Audio_details / Audio_Registers) — Pan Docs states both as simple rules;
  none of the three emulators implements them literally (SameBoy and DocBoy
  each derive adjacent behavior from different underlying machines, all
  SameSuite-calibrated). Needs a PCM-probe ROM per rule before any of the
  three should change.
- **High-pass filter charge per model** (Audio_details: 0.999958 DMG vs
  0.998943 MGB/CGB) — SameBoy and dingbat both ship one constant. An
  analog capture (line-out decay) arbitrates; audible if Pan Docs is right.
- **CH3 sample buffer on NR30 DAC-off** — dingbat clears it (SameSuite
  `channel_3_restart_stop_delay` cited in-code); SameBoy preserves it (and
  sometimes loads a glitch byte), DocBoy preserves. Someone's test coverage
  is thin; re-run the SameSuite ROM on hardware.
- **Plain-access OAM corruption** (OAM_Corruption_Bug) — SameBoy and DocBoy
  corrupt on ANY mode-2 OAM-page access; dingbat only models the
  IDU-instruction family (blargg oam_bug is green either way — its causes
  ROMs never test plain accesses). Deferred rather than skipped: wiring it
  into dingbat needs care not to double-fire the ld [hl±]/push/pop sites
  that already trigger, so it wants a dedicated pass keyed to a hardware
  ROM that sweeps plain reads, plain writes, and $FEA0-$FEFF.
- **SVBK write-0 readback** — now raw $F8 (SameBoy + DocBoy agree); no
  hardware source actually states it. One readout confirms.
- **Star Trek window glitch: insert vs replace + exact arming** —
  [hwprobe 19], unchanged.
- **OAM-DMA vs mode-2 scan lock (strikethrough)** — [hwprobe 18], unchanged.

## 3. Deferred implementation work (not hardware-blocked)

- **SGB multiplayer input routing** (audit A19): the MLT_REQ ID machinery is
  hardware-exact but every ID reads the one physical pad; wiring a second
  input source is frontend plumbing (the 2P link-mode input path is the
  donor). Biggest remaining SGB gap.
- **Plain-access OAM corruption** — see above; emulator-side work once the
  call-site design is settled.
- **Compat-mode colorization table** (A15's sibling): per-title palette IDs
  are boot-ROM data dingbat deliberately does not lift; revisit only if a
  clean-room table (TCRF's) is acceptable.
