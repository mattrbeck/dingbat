# GB/GBC and GBA derivations: claim, evidence, constant

One entry per hardware behaviour dingbat models that is not obvious from the
code. Each entry is the claim, the evidence that pins it, and the constant or
site that carries it. An entry's "Default" line gives the `{.intdefine.}`
values in `src/dingbat/gb/*.nim` and `src/dingbat/gba/*.nim`; the sweep tables
behind them live at the constants. Scores are in `tests/results*.md`; what is
still red and why is in `docs/dev/gb-failure-triage.md`.

Test-ROM names are evidence: `gambatte x/y` is a test of the gambatte suite,
`mooneye a/b` of Gekkio's suite (wilbertpol's fork where named), `mealybug m3_*`
a reference PNG, `mGBA suite <section>` a section of mGBA's test ROM.

## 1. GB PPU: line phase and the CPU clock

### The LCD-on first line starts 5 dots before the LCDC write retires
- Default: `LCD_ON_HEAD_START = 5` (`ppu.nim`); `LCD_ON_LINE0_TRIM = LCD_ON_LINE1_TRIM = 0` (`gb.nim`).
- Evidence: mooneye `acceptance/ppu/lcdon_timing-GS` brackets all three line-0
  boundaries to 5..8 dots before the write; `hblank_ly_scx_timing-GS` cannot
  tell 5 from 7 (runner row-for-row identical at 7). gambatte `enable_display`
  and the `scx_during_m3` PNGs pin 5. The seed is measured from an M-cycle
  boundary: a flat 5 restarts a double-speed PPU one M-cycle late
  (gambatte `enable_display/*_ds_*`).
- Open: the ROMs that time line 0 after an enable say 0 dots, line 1 says
  −2, the steady state says −2, later frames say 0. No single-shaped
  constant satisfies all four; a 454/458-dot line pair fits best but has no
  mechanism, so it does not ship. Table at `LCD_ON_LINE0_TRIM`.

### The CGB boot hand-off lands on the M-cycle grid at phase 165
- Default: `CGB_BOOT_PHASE = 165` (`ppu.nim`).
- Claim: the CPU and PPU share one clock, so the dot-grid-to-M-cycle offset is
  a property of the machine, not of the boot ROM. DMG's 5-dot head start
  leaves 452 = 113 × 4 dots to the line end; the CGB seed must also satisfy
  `457 − phase ≡ 0 (mod 4)`.
- Evidence: gambatte `display_startstate/stat_*_1` read STAT mode 3 and
  `stat_*_2`, one NOP later, mode 0 (SCX 0/2/3/5, so the mode-0 edge is read
  at four offsets). 165 is the only value that takes all eight: 158..161
  fail every `_2` row, 162..164 take them one SCX at a time, 166 loses
  `stat_1`. 157/161/165 score alike on every other gambatte row (5157-row
  A/B, 2026-09-22), because the rest resync on LY; 160 scores lowest, and
  the `m2int_*` families, whose DMG and CGB twins expect the same value, all
  missed by one M-cycle on CGB at 160. 161 shipped 2026-08..09 on the `_1`
  rows alone (the `_2` rows were red from the day the suite was scored).

### A CPU write commits at the start of its M-cycle
- Site: `mem_write` (`memory.nim`) runs the bus tick, lands the byte, then runs
  the M-cycle's PPU dots. Reads are untouched (their sample point is the
  `read_mode` latch). The STAT-line re-drive from an LCDC/STAT/LYC write stays
  on the M-cycle boundary (`mem_flush_deferred`); moving IF there costs 18
  gambatte rows.
- Evidence: gambatte `bgtiledata` and `bgtilemap` are four ROMs each whose
  mid-line LCDC write moves one M-cycle, drawing a staircase whose unknown is
  the fetcher's LCDC sample dot. Solved at single and double speed the windows
  are {3,4} and {1,2} dots: disjoint in dots, one M-cycle in both. mealybug
  `m3_scx_low_3_bits` brackets the SCX latch with two writes one M-cycle
  apart; mooneye `lcdon_write_timing-GS` keeps the OAM-write rule that needs
  to know whether mode 2 ends inside the M-cycle (it always ends at dot 80).

### The BG fetch restarts on the dot it pushes; the pipeline leads by 2 dots
- Default: `M3_PIPE_DELAY = 2`, `M3_THROWAWAY_DOTS = 4` (`fifo_ppu.nim`, `gb.nim`).
- Claim: Pan Docs, "Pixel FIFO": the fetcher's idle dots are at the tail
  (step 4 waits on the FIFO), so a push taken at Get-Tile-Data-High restarts
  the fetch rather than falling through Sleep/Push. The 172-dot line is the
  check: 12 dots of head + 160 pixels only adds up if the first push is
  immediate. The head splits 4 + 8: the discarded fetch is a `B0` and the
  first real cycle runs to its own push slot.
- Evidence: mealybug `m3_bgp_change` (no objects) pins the 2-dot lead;
  `m3_scy_change` reads the 4 + 8 split off directly
  (`docs/dev/gb-mealybug-sources.md` §3.4); GBMicrotest `ppu_spritex_vs_scx`
  (read back with `tools/gbppu/objtab.py`) is exact in all 153 cells at this
  phase and a dot over in 79 of them at the next.
- Cost: the lead is arrangement, not work; the per-dot machinery is
  `when M3_PIPE_DELAY == 0`-guarded. See `docs/dev/gb_oam_dma_cost.md` for how it
  was measured.

### Mode 3 ends when the fetcher retires, not when pixel 159 emits
- Site: `fifo_pipeline_dot` / `fetcher_retired` (`fifo_ppu.nim`).
- Claim: the last `M3_PIPE_DELAY` pixels leave the FIFO in one burst on the
  dot the fetcher retires; the fetcher never runs in H-Blank. The CPU VRAM/OAM
  locks read the live mode and open with the flag. An object at X 160..167,
  and a window with WX ≤ 166 that has not started, hold mode 3 open.
- Evidence: mooneye `hblank_*`, GBMicrotest `int_hblank_*`, Blargg, MagenTests
  and the mGBA suite do not move at any lead 0..8; mealybug
  `m3_scx_low_3_bits` catches a fetcher that runs on into H-Blank within one
  line.

### The pipeline runs one M-cycle ahead of the STAT/mode machinery
- Default: `M3_PIPE_AHEAD = 1` (`fifo_ppu.nim`), `STAT_M2_LEAD = 1` (`ppu.nim`),
  `LY0_PIPE_MCYCLES = 0`.
- Evidence: daid `ppu_scanline_bgp.gbc` is exact only with this trio plus
  `--cgb-rev=D` (band-edge pairing shows the trio is worth exactly +4 dots
  and rev D exactly −1); gambatte `m2int_m3stat`, `m2int_m0stat`,
  `m2int_m2stat` and most of `window` want it. `STAT_M2_LEAD` and
  `LY0_PIPE_MCYCLES` are the compensation that keeps the M2-synced mealybug
  frames still while the pipeline moves; neither moves daid on its own.

### `M3_END_EARLY` is an instrument, not a fix
- Default: `M3_END_EARLY = 0` (`fifo_ppu.nim`). It moves the mode 3 -> 0 edge
  uniformly, so a family that differs only in SCX (GBMicrotest
  `hblank_int_scx0..7`) samples one offset at eight residues through it.
- Refuted at 2: mooneye `hblank_ly_scx_timing-GS`, wilbertpol
  `intr_2_mode0_scx{1,2,5,6}_timing_nops` and 150 gambatte rows measure the
  same residues from the other side (`docs/dev/gb-failure-triage.md`, "Refuted
  models"). GBMicrotest's own header states two overhead rows for the SCX
  family — `docs/dev/gb-test-suite-sources.md`, "GBMicrotest".

### STAT reads the coincidence bit clear in the M-cycle LY advances
- Site: bit 7 of the `read_mode` latch (`ppu.nim`).
- Evidence: mooneye `lcdon_timing-GS`: true for a comparison that has just
  become true and one that has just become false.

### CGB raises the line-144 mode-2 STAT source one M-cycle before vblank
- Site: `m2_line144` (`ppu.nim`): high on line 144 in mode 1, and on CGB also
  for the last 4 dots of line 143. Which CGB revisions keep the mode-0
  M-cycle at the end of mode 1 is `GbQuirks.m1_end_no_mode0`.
- The pulse is continuous across the 143 -> 144 boundary (2026-09-22): LY
  advances before mode 1 is set and the comparator's drop is evaluated in
  between (`ly_advance_vblank_entry`), so a pulse gated on mode 1 read low
  there and the mode-1 rise became a false STAT edge. gambatte
  `m1/m1irq_m2enable_lyc_1`, `m2m1irq_ifw_2`, `m1irq_m2disable_lycdisable_3`,
  `lyc143_late_m2enable_lycdisable_2` (+13 / -3; the three CGB `_2`/`_ds_1`
  arms are triage A3's vblank-entry latency).
- Evidence: mooneye `misc/ppu/vblank_stat_intr-C` vs `-GS`: the DIV-reset
  bracket is 54/55 NOPs for vblank on every model and for STAT on DMG, but
  53/54 for STAT on CGB.

### A STAT write's cleared enables let the line fall at the commit
- Default: `stat_drop_arm` / `stat_drop_settle` (`ppu.nim`), at the existing
  `STAT_ENABLE_LATENCY = 0` / `CGB_STAT_ENABLE_LATENCY = 2`.
- Claim: the STAT interrupt line is a level OR into an edge detector, and a
  write that disables the source holding it high takes it low when the
  enable bits reach the line (the top of the write's M-cycle on DMG, 2 dots
  in on CGB), not at the M-cycle boundary where the byte lands. A source
  rising between those two instants is therefore an edge.
- Evidence: gambatte `m2enable/m2_late_m0disable_1` (both devices, and
  `_ds_1`): $28 -> $20 commits on dot 449, the mode-2 source rises on 452,
  hardware takes the interrupt; the `_2` arm, one M-cycle later, does not.
  Same shape in `late_enable_m0disable_1`, `late_enable_after_lycint_
  disable_1`, `lyc1_m2irq_late_lycdisable_1`, `m0enable/lycdisable_ff41_*`
  and `lycEnable/lyc{0,153}_late_{enable_,}m1disable_2 [dmg]`: +22 / -2 on
  the suite (2026-09-22). The two losses are the CGB arms of the LYC = 153
  pair, where the disable landing on the latency's last dot still blocks;
  a strict comparison loses six other CGB rows, so that source's window is
  one dot longer, an open row of triage A3.
- The DMG's LYC write is the same disable through the comparator, one dot
  after the top of its M-cycle (`LYC_DROP_LATENCY_DMG = 1`), and a write
  whose M-cycle holds the line boundary does not drop the line there
  (`LYC_DROP_BOUNDARY_SKIP = 1`): the write lands on the dot the
  comparator's own LY steps on (line end - 2, "The comparator's LY steps two
  dots before the line boundary", section 7), so old match and new are one
  level. Tests and brackets in that entry. The CGB's LYC write does not come
  through here: "CGB LYC write: a sampled comparator", section 7.

### The STAT line falls where a line's OAM pulse ends
- Default: `M2_PULSE_END_EDGE = 1` (`ppu.nim`), `stat_m2_pulse_settle`.
- Claim: the OAM source is a pulse (`STAT_M2_PULSE`), and with nothing else
  enabled the STAT line is low again a few dots into mode 2, not at mode 3.
  A source enabled later in mode 2 is therefore a rising edge.
- Evidence: gambatte `lycEnable/late_ff41_enable_after_m2int` and
  `late_ff41_enable_after_m2int_disable` (both devices) take the mode-2
  interrupt of the line LYC matches and write STAT $60 / $40 from dot 49:
  hardware requests again. Off loses the four tests and nothing else moves.
- Site: the pulse's last dot is not a stop of the idle skip (a stop there
  would be paid on every line). Between the pulse's end and mode 3 only a
  CPU write can move the line, so the fall is taken by the first STAT or LYC
  write that looks at it: at the write's commit, and where a STAT write's
  byte lands at the end of its M-cycle (under the old enables: the pulse
  ended first).
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### A STAT write with the LCD off meets the comparator's frozen answer
- Default: `STAT_WRITE_LCD_OFF = 1` (`gb.nim`), `ppu_stat_write_lcd_off`
  (`ppu.nim`).
- Claim: switching the LCD off stops the comparator, it does not clear it
  (mooneye `stat_lyc_onoff`: the coincidence bit freezes). The frozen answer
  stays an input of the STAT line, so with the LCD off a STAT write that
  enables the LYC source over a frozen match raises the line, and one that
  disables it lets the line fall. On a DMG every STAT write passes through
  its all-enabled phase first (Pan Docs, "Spurious STAT interrupts") and
  finds the frozen match whatever it writes.
- Evidence: gambatte `lycEnable/lcdoff_lycirqen_{1,2,3,4}`. `_1` (LCD off on
  the matching line, then STAT $00, IF cleared, STAT $40) reads IF bit 1 set
  on both devices; `_2` (no match when the LCD went off; LYC then written
  equal to the LY the register reads back) reads it clear, so the comparator
  is not running; `_3` ($40 rewritten over $40, the line never fell) clear;
  `_4` ($00 twice) set on a DMG, clear on a CGB. Off loses `_1` on both
  devices and `_4` [dmg].
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### The mode-0 request does not wait for work that starts on the last pixel
- Default: `M0_REQ_LAST_PX = 1` (`gb.nim`), `fifo_tail_m0_request`,
  `fetch_work_pending(for_irq)` (`fifo_ppu.nim`).
- Claim: an object at X = 167 and a window at WX = 166 both match on pixel
  159. Their fetch holds the mode flag at 3 (and the VRAM/OAM locks with
  it), but the mode-0 STAT request rises where it does on a line without
  them: the request follows the pixel counter reaching the end of the line,
  the flag follows the fetcher. One pixel to the left the match is ordinary
  work and the request waits for it.
- Evidence: gambatte `sprites/10spritesPrLine_10xposA7_m3stat_{1,2}` read
  mode 3 at dot 305 and mode 0 at 309 with ten X = 167 objects (the flag),
  while `10spritesPrLine_10xposA7_m0irq_{1,2}` (both devices) read IF clear
  from dot 249 and set from 253, the bare line's dots (the request);
  `10spritesPrLine_10xposA6_m0irq_{1,2}` find the request after the X = 166
  fetches. `window/m2int_wxA6_m0irq_{1,2}`, `m2int_wxA6_m0irq2_{1,2}` [cgb]
  (the CGB holds the flag for the last-pixel window, `CGB_WIN_TAIL_LAST`),
  `m2int_wxA6_spxA7_m0irq_{1,2}` (both devices), `m0enable/
  enable_wxA6_2x_spxA7_{1,2}` and `_ds_{1,2,3,4}` [cgb] (the CGB object at
  X = 167 that waited for the window start, section 2). Off loses twelve
  tests: the `_2` arm of each `m0irq` pair on the devices named and the six
  `m0enable` tests.
- Site: the request is raised from the mode-3 loop's tail branch (the last
  `m3_lead` pixels), `adv - lead` dots after the first dot on which nothing
  but last-pixel work is pending, the hand-off the ordinary retire makes
  through `m3_hold`. The loop's hot path keeps its one `lx` compare.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### CPU VRAM/OAM locks close on the live mode and open with the STAT bits
- Site: `cpu_vram_open` / `cpu_oam_open`, checked on the CPU bus
  (`mem_read`/`mem_write`), never in `ppu_read`/`ppu_write`, so the OAM DMA
  unit keeps its access.
- Evidence: mooneye `lcdon_write_timing-GS` (an OAM write lands in the last
  M-cycle of mode 2 while a read in that M-cycle is refused);
  `hblank_ly_scx_timing-GS` for the mode-0 quantisation.

### A mode-3 VRAM write asks its lock three dots into its M-cycle
- Default: `VRAM_WRITE_M3_END_DOTS = 3`, `VRAM_WRITE_M3_END_DOTS_DS = 0`
  (`memory.nim`, `mem_write_vram_m3`).
- Rule: a VRAM write issued with the PPU in mode 3 does not ask the lock at
  the top of its M-cycle but 3 dots in, so a mode 3 that ends inside those
  dots lets the write through. At double speed the write asks at the top.
  Writes issued in any other mode are unchanged (they ask at the top).
- Evidence: gambatte `vramw_m3end/*` moves one write across the end of mode
  3 one M-cycle per ROM, at SCX 0 and 3 (the SCX step moves the edge by
  three dots against the M-cycle grid). Single speed: 0, 1 and 2 lose
  `vramw_m3end_scx3_5` on both devices, 4 loses `vramw_m3end_4` on both; 3
  passes all twelve. Double speed: 1 loses `vramw_m3end_scx5_ds_4`, 2 also
  `vramw_m3end_ds_4`; 0 passes all twelve.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### The CGB's VRAM write lock closes late on the LCD-on line
- Default: `VRAM_WRITE_LINE0_CGB_GRACE = 1` (`gb.nim`; the arm is in
  `cpu_vram_open`).
- Rule: on the line the LCD is switched on with, a CGB VRAM write is still
  taken for one CPU M-cycle and a dot past the mode-3 flag edge (5 dots at
  single speed, 3 at double). The DMG closes on the edge.
- Evidence: gambatte `enable_display/ly0_late_vramw_2_dmg08_out55_cgb04c_outAA`
  states the split in its name (the DMG drops the write, the CGB takes it;
  `_1` is taken and `_3` dropped on both); DocBoy
  `cgb/double_speed/ppu/double_speed_ppu_vram_write_block_timing_ly0_1_out_of_4`.
  0 loses both tests and nothing passes only at 0.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### On a CGB the VRAM lock is shut for an M-cycle that starts on mode 3's first dot
- Default: `VRAM_READ_CGB_M3_EDGE_SS = 4`, `VRAM_WRITE_CGB_M3_EDGE_SS = 80`
  (`ppu.nim`, `cpu_vram_open`).
- Rule: at single speed a CGB VRAM read or write whose M-cycle starts on
  dot 80, the dot the mode flag turns 3, is locked; one starting on dot 79
  is not. The DMG's read is locked earlier (the live mode at its sample,
  `VRAM_READ_LIVE_LOCK`), and a CPU on the PPU's 4-dot grid never starts an
  M-cycle on dot 80, so the case exists only after a speed switch has left
  the CPU off that grid (gambatte's `lcdoffset` tests). The two knobs are the
  same statement at the two places the lock is asked: a read is judged
  where it samples, at the end of its M-cycle, by the M-cycle-start mode
  latch, which is taken before dot 80 runs and so still says 2 (hence
  "the edge 4 dots back"); a write is judged at its commit, ahead of its
  dots, where the flag has not moved either (hence "from line dot 80").
- Evidence (M-cycle start dot -> answer, [cgb]): gambatte `vram_m3/
  preread_1` 73 open, `preread_2` 77 open, `preread_3` 81 locked;
  `preread_lcdoffset2_1` 79 open, `preread_lcdoffset1_2` 80 locked,
  `preread_lcdoffset1_1` 76 open, `preread_lcdoffset2_2` 83 locked. Read
  knob: 3 loses `preread_lcdoffset2_1`, 5 loses `preread_lcdoffset1_2`.
  Writes: `prewrite_lcdoffset2_1` 79 lands, `prewrite_lcdoffset1_2` 80
  dropped; 79 loses the first, 81 the second.
- The palette RAM closes one dot later ("The CGB palette RAM lock around the
  mode-3 edges", section 7): `cgbpal_m3/cgbpal_read_m3start_lcdoffset1_1`
  reads from dot 80 and gets the palette.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

## 2. Window

### WY is a sampled comparator behind a per-frame latch
- Claim: Pan Docs, "Window": "WY == LY at any point in the frame". The latch
  (`window_trigger`) is cleared entering vblank and set by a sample of
  `WY == LY and LCDC.5`; nothing re-reads WY once it is set. The comparator is
  not a continuous level. It samples on three occasions only: once per line at
  the line's start, a fixed number of dots after a WY write, and the same
  number of dots after a write that sets LCDC.5 (or switches the LCD on with
  it set). The schedule is the next entry.
- The match counts only with LCDC.5 set at the sample: enabling the window on
  a later line of the frame draws nothing (first-party hardware: gbprobe
  `probe_g_wy1` on an AGB SP, docs/dev/hwprobe-questions.md row 19).
- Evidence: gambatte `window/arg/late_wy_1` vs `_2` put the per-line sample at
  dot 0, not 80; `late_wy_1toFF_*` show a `ly >= wy` re-test retracting a
  window hardware keeps drawing.

### The window's WY comparator: when it samples
Dots are dingbat's line dots; W is the first dot of the writing M-cycle
(`ppu_write`). "Sampled on dot X" means before dot X's pipeline step.
- **A write's sample.** A WY write, or an LCDC write that raises bit 5 (or
  bit 7 with bit 5 set), is sampled `WIN_CHECK_DEFER_*` dots after W:
  1 on a DMG, 5 on a CGB at single speed, 1 on a CGB at double speed
  (`win_check_schedule`, `win_check_now`, ppu.nim). A WY write's sample is
  also the dot the comparator's copy of WY (`wy_cmp`) takes the new value, so
  the per-line sample reads the old value until then; the readable register
  and `CGB_WY_LATENCY` are untouched.
  - DMG 1: gambatte `window/arg/late_wy_FFto2_ly2_scx3_3` [dmg] writes WY = LY
    on W = 93 of a line whose window would start on dot 93 and reads no
    window; 0 starts one, and (a sample at the store, with no cut-off and
    no late head) also loses the five W = 453 line-end tests below and
    `late_scx_late_wy_FFto4_ly4_wx00_2` [dmg]. 2 loses `late_wy_FFto2_ly2_2`,
    `_wx0f_2`, `late_wy_FFto0_ly0_2`, `late_wy_10to1_ly1_2`,
    `late_scx_late_wy_FFto4_ly4_wx00_1` [dmg] (W one M-cycle before the start
    dot, window expected).
  - CGB 5: `late_wy_FFto2_ly2_scx3_2` [cgb] (W = 89, start dot 93, no
    window), `late_wy_FFto2_ly2_wx00_2` and `late_scx_late_wy_FFto4_ly4_wx00_2`
    [cgb] fail at 4; `late_wy_FFto2_ly2_1`, `_wx0f_1`, `late_wy_FFto0_ly0_1`,
    `late_wy_10to1_ly1_1` [cgb] (W = 85, start dot 90) fail at 6. One M-cycle
    more than the DMG, as `CGB_WY_LATENCY` already said of the store; the
    LCDC.5 rise takes the same five (`window/late_enable_afterVblank_{1,2}`
    [cgb] have the thresholds of the WY tests), so the delay is the
    comparator's, not the WY register's.
  - CGB double speed 1: 0 (a sample at the store, which then has no line-end
    cut-off) loses `late_wy_FFto0_ly2_ds_2`, `late_enable_afterVblank_ds_2`,
    `late_enable_afterVblank_ds_lcdoffset1_2`, `late_wy_ds_lcdoffset1_2`; 2
    loses `late_wy_FFto2_ly2_ds_1`, `late_wy_1toFF_ds_1`,
    `late_enable_ly0_ds_1`, `late_wy_ds_1`, `late_wy_FFto0_ly2_ds_1`,
    `late_enable_afterVblank_ds_1`. Not half the single-speed five.
- **The line-end cut-off.** At single speed a write's sample landing in the
  last `WIN_CHECK_CUT_DOTS = 2` dots of a line (dot 454 on) latches nothing
  for the line being drawn. Dot 454 is also the dot the LY = LYC
  comparator's LY steps (`STAT_LYC_LY_LEAD_DOTS = 2`, section 7); the
  written value is in place for the next line's own sample. gambatte
  `late_wy_FFto0_ly2_{1,2,3}`, `late_wy_10to0_ly1_{1,2,3}`,
  `late_wy_FFto1_ly2_{1,2,3}` and `window/late_enable_afterVblank_{1,2,3}`,
  `arg/late_enable_afterVblank_{3,4,5}` write on W = 445 / 449 / 453: the DMG
  latches on the first two (samples on 446, 450) and not the third (454),
  the CGB on the first only (450; 454 is cut), so 1 loses the DMG `_3` tests
  and the CGB `_2` tests. `window/late_enable_afterVblank_lcdoffset1_{1,2}`
  [cgb], a dot off the grid, write on W = 448 and 452: the sample on 453
  latches and 3 loses `_1`. Double speed has a figure of its own,
  `WIN_CHECK_CUT_DOTS_DS = 3` (dot 453 on), where the comparator's LY has
  no lead: W = 451 (sample 452) latches, W = 452 and 453 do not
  (`late_wy_FFto0_ly2_ds_{1,2}`, `late_enable_afterVblank_ds_{1,2}`,
  `_ds_lcdoffset1_{1,2}`); 2 loses `late_enable_afterVblank_ds_lcdoffset1_2`,
  4 loses `late_wy_FFto0_ly2_ds_1` and `late_enable_afterVblank_ds_1`.
- **The per-line sample** is one dot into the line at single speed
  (`WIN_LINE_CHECK_DOT_SS = 1`), after a write's sample due by then, and on
  the line's first dot at double speed. `late_wy_1toFF_{1,2,3}`,
  `late_wy_2toFF_{1,2,3}` take a matching WY away at the end of the line
  before: the DMG's W = 453 (sample 454) is in time and W = 457 (sample on
  dot 2) is not; the CGB's W = 449 (sample 454) is in time and W = 453
  (sample on dot 2) is not, although the WY register itself changed on dot
  456. `arg/late_wy_1toFF_lcdoffset1_{1,2}` [cgb] write on W = 452 and 456:
  the sample on dot 1 is in time (0 loses `_1`), the one on dot 5 is not; 2
  loses `late_wy_1toFF_2` and `late_wy_2toFF_2` [cgb]. The DMG tests pass at
  0, 1 and 2. Double speed: W = 455
  (sample 456) in time, 456 and 457 not (`late_wy_1toFF_ds_{1,2}`,
  `_ds_lcdoffset1_{1,2}`). Nothing runs on dot 1 for it: the boundary's
  check looks one dot ahead at a write's sample already queued
  (`win_line_wy`, ppu.nim), the only thing that can move in that dot.
- **Line 0 on a CGB** samples on dot `WIN_LINE0_CHECK_DOT_CGB = 5`
  (`_DS = 5`), not dot 0; the DMG's line 0 is an ordinary line.
  `window/late_wy_{1,2}` and `arg/late_wy_{1,2}` [cgb] take WY = 0 away on
  W = 453 of line 153 (sample dot 2: in time) and W = 1 of line 0 (sample
  dot 6: too late), and `window/late_wy_lcdoffset1_{1,2}` [cgb] on W = 456
  (sample dot 5: in time) and W = 4 (dot 9): 5..6 pass, 4 loses
  `late_wy_lcdoffset1_1` and 7 loses `late_wy_2`. Double speed pins 5:
  `late_wy_ds_1` (W = 3, sample 4, in time) fails at 4 and
  `late_wy_ds_lcdoffset1_2` (W = 4, sample 5, too late) fails at 6. The line's
  check and a write's sample can both be in flight, so the queue holds two
  (`win_check_push`).
- Sites: `win_check_push` / `win_check_now` / `win_check_due` (ppu.nim), the
  stop in `fifo_skip_target` and the three dot-loop tests (fifo_ppu.nim),
  which were already there for the knobs. `wy_cmp` and the queue are in
  flight for at most seven dots after a write and are not serialized
  (`win_check_clear` on load).
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### A WY match past the head still makes a WX < 6 line a window line
- Default: `WIN_HEAD_LATE_DOT = 85` (`gb.nim`; `fifo_head_window_late`).
- Claim: a line whose WX is below `WIN_LINE_START_WX` decides to be a window
  line at the head of mode 3, but a WY match sampled up to dot
  `85 + (SCX & 7)` still turns it into one, the startup fetch beginning
  there: the decision moves with the fine-scroll discard.
- Evidence: gambatte `window/arg/late_scx_late_wy_FFto4_ly4_wx00_{1,2,3}`
  (WX = 0, SCX = 4 written eight dots ahead of WY): the DMG's W = 85 and the
  CGB's W = 81 (both sampled on dot 86) draw the window, one M-cycle later
  (dot 90) does not; `late_wy_FFto2_ly2_wx00_{1,2,3}` (SCX = 0) put the same
  edge between dots 82 and 86. 82..85 pass all twelve tests; 81 and 0 lose
  `late_scx_late_wy_FFto4_ly4_wx00_1` [cgb] and `_2` [dmg]; 86 loses
  `late_scx_late_wy_FFto4_ly4_wx00_2` [cgb], `_3` [dmg] and
  `late_wy_FFto2_ly2_wx00_2` [cgb], `_3` [dmg]. Default 85: the last dot before
  the head's own read of WX (dot 86, `WIN_LINE_START_LATCH`).
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### LCDC.5 and WX reach a CGB's window logic late
- Default (`gb.nim`): `CGB_WX_LATE_SS = 1`, `CGB_WE_ENABLE_LATE = 1`,
  `CGB_WE_DISABLE_LATE = 2`, `WIN_REVOKE_DS_PUSH = 1`.
- `CGB_WX_LATE_SS`: every CGB, not only the AGB, takes a WX store
  `CGB_WX_LATENCY` (1) dot late at single speed. gambatte
  `window/late_wx_scx3_2` writes WX = $FF on the very dot WX = 7 matches
  (dot 93 at SCX = 3): the DMG reads no window, the CGB a window (0 fails the
  CGB test; `late_wx_scx2_2`, one dot of slack, cannot tell). DocBoy
  `cgb/ppu/visual/change_wx_glitch_{wx6_nops16,wx6_nops17,wx7_nops17,wx8_nops17}`
  need the same dot (all four fail at 0). The AGB SP photograph of gbprobe
  `probe_h_wx` (docs/dev/flashcart-runbook.md row 32) is the same dot on a third
  console.
- `CGB_WE_ENABLE_LATE`: an LCDC.5 rise at single speed reaches the WX
  comparator a dot late, so a match on the write's own dot is missed.
  gambatte `window/late_reenable_scx3_2` (DMG window, CGB none) and DocBoy
  `cgb_dmg_mode/ppu/visual/enable_win_during_pixel_transfer_round1` fail at 0.
- `CGB_WE_DISABLE_LATE`: an LCDC.5 fall reaches the fetcher's window abort
  (`WIN_EN_ABORT`) two dots late, so a map read on the write's dot or the
  next still fetches a window tile. DocBoy `cgb/ppu/visual/window_bg_reprise_wx{14,15,22,23}`
  and gambatte `window/on_screen/wx17_weoff_wxA5_weon` [cgb]: 1 passes
  `_wx14`, `_wx22` only; 2 passes all five; 3 loses `window_bg_reprise_wx{8,16,24}`
  and gambatte `on_screen/weon_wx18_weoff_weon_wx80` [cgb].
- `WIN_REVOKE_DS_PUSH`: at double speed a CGB window start is still revoked
  by an LCDC.5 fall on the dot its restart pushes the first tile (the fifth
  dot is inside the same 2-dot M-cycle). gambatte
  `window/late_disable_scx5_ds_1` fails at 0.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### A carried window start against LCDC.5 low
- Default: `WIN_CARRY_HEAD_DROP = 1` (`gb.nim`; `fifo_head_window`).
- Claim: a DMG window start owed from the previous line's last pixel
  (`DMG_WIN_LAST_PX_CARRY`) is spent or lost at the head of the next mode 3:
  with LCDC.5 low there it is gone, not kept for a later line. Inside the
  window's lines nothing shows it, because every line's WX = 166 match owes a
  new start; it shows on the first line after vblank, where the WY latch is
  clear and nothing re-owes it.
- Evidence: gambatte `window/on_screen/wxA6_late_we_reenable_{1,2,3,4}` [dmg]
  hold LCDC.5 low from early mode 2 to dot 77 / 81 / 85 / 89 of every line.
  Line 0's head reads on dot 82: `_1` and `_2` draw a window line on line 0
  (the start carried over the frame boundary from line 143); `_3` (bit back on
  dot 85, three dots after line 0's head and one before line 1's) draws none
  on line 0 and none on line 1 either. Kept, the start is spent on line 1
  and every later window test comes a line early (916 pixels). 0 fails `_3`
  alone; `wxA6_wy01_weoff_ly02`, `wxA6_wy01_weoff_ly02_weon_ly60`,
  `wxA6_weoff_at_xposA6`, `wxA6_wy8F` are unmoved.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### The last pixel: object against window on a CGB
- Default: `CGB_OBJ_LAST_PX_YIELDS = 1` (`fifo_ppu.nim`;
  `obj_yields_to_window`).
- Claim: an object at OAM X = 167 and a window at WX = 166 both trigger on
  the line's last pixel. The DMG fetches the object in front of the start
  (which it then cannot draw, `DMG_WIN_LAST_PX_CARRY`). The CGB orders them
  as on every other column: the object waits for the window start and is
  fetched against the window's first tile, a full 11 dots. Those dots hold
  the mode flag only: the mode-0 STAT request is not waiting for work that
  starts on the last pixel (section 1, `M0_REQ_LAST_PX`), so it rises where
  the object-less WX = 166 line raises it.
- Evidence: gambatte `window/m2int_wxA6_spxA7_m3stat_{1,2,4,5}` [cgb] read
  STAT on dots 257 / 261 / 269 / 273 of the line and want 3, 3, 3, 0, where
  the object-less `m2int_wxA6_m3stat_{1,2,3}` [cgb] want 3, 3, 0 on 253 / 257 /
  261: the flag falls 10..13 dots later with the object; window start (6) +
  object at tile pixel 0 (11) puts it on dot 269 against 258. The DMG twins
  move by one read (the object's six dots). 0 fails `_m3stat_2` and
  `_m3stat_4` [cgb]. The request: `m0enable/enable_wxA6_2x_spxA7_{1,2}` and
  `_ds_{1,2,3,4}` [cgb] enable the mode-0 source on dots 249..261 of such a
  line and want the interrupt at once, and
  `window/m2int_wxA6_spxA7_m0irq_{1,2}` want IF on the same read as the
  object-less `m2int_wxA6_m0irq_{1,2}`. Those tests are `M0_REQ_LAST_PX`'s:
  this entry adds no request rule of its own.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### The window starts on an equality with the pixel about to be emitted
- Claim: `lx + 7 == wx`, not `>=`. A `>=` cannot be un-satisfied, so a window
  armed late (mid-line WY write, LCDC.5 returning) would start wherever the
  shifter had reached.
- Evidence: gambatte `late_wy_FFto2_ly2_1..3` bracket the start dot at
  `83 + WX + (SCX&7)` across WX and SCX variants. The start restarts the BG
  fetch at step 1.
- Site: one cached trigger `lx` on `GbFifoPpu`, compared once per dot; the
  inputs (LCDC.5, WX, the latch, `fetching_window`) only change on a register
  write or fetch restart. A second branch in the dot loop cost +1.7 % retired
  instructions on blargg 01-special.

### WX = 7 is an ordinary window start at screen x = 0
- Evidence: gambatte `m2int_wx07_m3stat_*`: it pays the ordinary fetch restart.
  Only WX < 7 is the hardware-bug corner.

### Re-reaching WX while the window is already active injects one colour-0 pixel
- Default: `WIN_REACT_PHASE = 7` (`fifo_ppu.nim`).
- Claim: the window does not restart; one colour-0, lowest-priority pixel is
  inserted behind the FIFO head and the rest of the line shifts right by one.
  Colour 0 is what lets an OBJ-behind-BG sprite show through it.
- Evidence: mealybug `m3_wx_4_change`, `m3_wx_4_change_sprites`,
  `m3_wx_5_change` — all three pixel-exact at phase 7 and at no other of the
  eight fetcher positions (`tools/gbppu/reactsweep.sh`). Which fetcher step
  swallows the edge is a property of this renderer's phase, hence a knob.

### A refused window start on a tile boundary inserts one colour-0 pixel (DMG)
- Default: `WIN_EN_HOLD_ZERO = 2` (`gb.nim`).
- Claim: Pan Docs, "Window": with LCDC.5 clear but the other conditions met,
  a start that would land exactly on a BG tile boundary inserts a single
  colour-0 pixel and offsets the rest of the line (the Star Trek 25th
  Anniversary glitch).
- Evidence: nitro2k01's SGB logic-analyser trace
  (https://github.com/LIJI32/SameBoy/issues/278) shows the rest of the line
  delayed. DocBoy `dmg/ppu/visual/window_retrigger_pixel_glitch_*` pin the
  insert (1, a replaced pixel, fails them).

### LCDC.5 falling inside a window tile's fetch (DMG)
- Default: `WIN_OFF_BG_ROW = true` (`gb.nim`; the plane reads in
  `tick_bg_fetcher`).
- Rule: each bitplane read takes its row term from LCDC.5 as it stands at
  that read: the window line counter's low 3 bits while the bit is set,
  `(LY + SCY) and 7` once it is clear. The tile index the window map read
  latched stays, and the fetcher goes back to background tiles at its next
  map read (`WIN_EN_ABORT`), so the tile's dots and position do not move;
  only its row does.
- Evidence: DocBoy `dmg/ppu/visual/window_turn_off_*`, the 40 whose write
  lands between the window map read and the planes (false fails all 40).
  mealybug `m3_lcdc_win_en_change_multiple_wx` reaches the rule on about
  500 reads with the two rows different and its DMG frame is unchanged.
  SameBoy (DMG B, black box) keeps the window row; no spec text or photo
  separates the two (decider: gb-failure-triage.md I6). The CGB keeps the
  window row; no test reaches it there.
- Clean-room: derived from the test ROMs' frames and dingbat's own trace
  runs; no emulator source consulted.

### The background column after a window abort (DMG)
- Default: `WIN_ABORT_COL_LEAD = 1`, `WIN_ABORT_PUSH_POS = true` (`gb.nim`;
  `fetcher_window_abort`).
- Rule: the abort's map read takes the background column under the pixel
  one right of where the last pushed tile ended, `(P + 1) div 8`; while the
  window has pushed nothing, P is where the background's own pushes had
  reached before the start emptied the FIFO. The column counter restarts
  from the screen position, `(lx + FIFO size + 1) div 8`, which is the same
  number once the window has pushed and one less when it has not, so in
  that case the read's column is fetched twice.
- Evidence: DocBoy `dmg/ppu/visual/window_bg_reprise_wx*` (the lead) and
  `window_turn_off_*` (all 43; three put the fall on the window's first map
  read and need P; the 22 rows of both families whose fall lands on a
  map-read dot fail a background counter frozen at the window start, or one
  the window's pushes advance). SameBoy (DMG B, black box) draws neither the old nor the new
  picture of the three. No hardware capture (gb-failure-triage.md I6).
- Clean-room: derived from the test ROMs' frames and dingbat's own trace
  runs; no emulator source consulted.

### The bytes a cut CGB window fetch leaves
- Default: `CGB_WIN_CUT_PLANES = true` (`gb.nim`; `win_revoke_keep`, the
  `fsGetTile` abort in `tick_bg_fetcher`). CGB, single speed.
- Rule: an LCDC.5 fall reaches the fetcher `CGB_WE_DISABLE_LATE` (2) dots
  after the write, so a revoked window restart (`CGB_WIN_REVOKE_KEEP`, landing
  on the write's dot) has run its steps up to `fetch_counter` there, no
  further. Its tile is pushed with the window map's index, the low plane if
  step 3 ran (else the previous tile's low byte stays in the latch), and the
  high plane if step 5 ran (else the tile index is the high byte). When the
  fall reaches the fetcher on an idle step after a read (odd
  `fetch_counter`), the map read that ends the window takes that read's byte
  as the background tile's index instead of VRAM's. The same holds when the
  fall reaches it on the idle dot just before the map read after the
  window's first tile (WX < 7, the tile fetched in full): the byte is that
  tile's high plane.
- Per restart dot k of the write (k = W - match): 5 full tile, next index =
  high plane; 4 low plane + index; 3 low plane + index, next index = low
  plane; 2 previous low + index; 1 previous low + index, next index = the
  window's own index (so a full window tile follows).
- Evidence: DocBoy `cgb_dmg_mode/ppu/visual/m3_lcdc_win_en_change_multiple_
  wx_bg_{0000,00ff,ff00,ffff}_win_{0000,00ff,ff00,ffff}`, `_win_afff` and
  `_win_tilenum_02` decode every byte (the window map holds 1, the
  background map 0, the rest of VRAM is 0, so tile $FF / $AF reads as
  colour 0). mealybug's own CPU CGB C and CPU CGB D photographs of
  `m3_lcdc_win_en_change_multiple_wx` (the repository's `photos/`; its
  `expected/` CGB images are placeholders) show the same lines: the
  one-pixel window remnant on k = 4 and 2, the colour-0 run after k = 3 and
  after a head line's first tile, the nine-pixel run on k = 1. dingbat drew
  a full window tile on every k before. DocBoy `cgb/ppu/visual/
  window_bg_reprise_wx25` (CGB mode, k = 5) passes with it. A later window
  tile met the same way (`_wx` line 25, the fall reaching the fetcher the dot
  before the second tile's successor map read) keeps VRAM's index, hence the
  first-tile condition, which only DocBoy pins.
- Not modelled: a WX match on the write's own dot (k = 0; lines 10 and 38),
  gb-failure-triage.md I3.
- Clean-room: derived from the test ROMs' frames, the mealybug photographs
  and dingbat's own trace runs; no emulator source consulted.

## 3. Objects

### An object costs 6 dots plus a per-tile wait, per Pan Docs
- Claim: Pan Docs, "Rendering" → "OBJ penalty algorithm": 6 for the object's
  own fetch plus a wait for the BG fetch it interrupted, 6..11 total, paid once
  per tile. The BG FIFO's occupancy at the trigger dot is the "pixels strictly
  right of The Pixel" term; an object hanging off the left edge charges the
  tile before the first on-screen one, which is why X = 0 costs a flat 11
  regardless of SCX. Spelled out rather than derived for X = 0: the derived
  form ramped 11..6 over the SCX residues.
- Evidence: sweeping the flat term 4..8 and the wait offset 1..5 over all 476
  gambatte `sprites` rows has a unique optimum at Pan Docs' (6, −2);
  `10spritesPrLine_1xpos0` vs `10spritesPrLine` for the left-edge tile;
  mooneye `intr_2_mode0_timing_sprites` for a second object at the same X
  costing 6, not 2.
- The BG fetcher runs during the wait and stops for the object's six dots
  (one address bus). Running it through the object fetch too costs no dots
  but moves every later BG VRAM read on the line; eleven mealybug `m3_*` rows
  refuse it, `m3_scy_change` most sharply.

### A head object's plane reads walk with X past the wait's clamp
- Default: `OBJ_HEAD_SLIDE = 1` (`fifo_ppu.nim`, `tick_shifter`), on
  `OBJ_PLANE1_HEAD = 4`.
- Rule: an object hanging off the left edge (X < 8, the head arm) reads its
  two planes on T + 2 and T + 4 (T the trigger) up to sub = (X + SCX) & 7 =
  5, and `sub - 5` dots later past it, when it is the head tile's first
  object. The stall stays Pan Docs' `6 + max(0, 5 - sub)`. This is the tail
  arm's shape: there the reads hold still while the wait shrinks and walk
  a dot per pixel with the trigger once the wait is clamped.
- Evidence: DocBoy `cgb/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_
  64_bytes_sprite_y16_x*` (which GDMA bytes the fetch refuses): the X = 5,
  6, 7 maps are the X = 13, 14, 15 maps four bytes (one tile) earlier, and
  only X = 7 differs from X = 6 at the DMA's two-dot resolution. 0 fails
  `_x07` alone. mealybug `m3_lcdc_obj_size_change` bounds the head reads only
  from above (before dot 101). SameBoy (black box) draws the 0 map for
  `_x07`; no hardware capture covers it (hardware question 21 is the
  background map).
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### The line the LCD is switched on with has no objects
- Default: `LCD_ON_LINE_NO_SCAN = 1` (`fifo_ppu.nim`; applied at the mode
  2 -> 3 edge in `fifo_tick_slow`).
- Rule: that line has no mode 2 (STAT reads mode 0 until mode 3 begins), and
  no OAM scan runs on it. Its mode 3 has the object-free length whatever OAM
  holds.
- Evidence: DocBoy `dmg/ppu/turn_on_ly0_sprites_round{1,2}` puts an object at
  Y = $10, X = $10 and reads STAT 59 and 60 M-cycles after the LCDC write:
  mode 3, then mode 0, the object-free end. gambatte
  `enable_display/enable_display_ly0_sprites_m0stat_{1,2}` (objects at X = 8
  and $18, both devices) brackets the same end by one M-cycle. 0 (scan the
  line) loses the three `_2` tests.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### A CGB fetches objects with LCDC.1 clear
- Default: `CGB_OBJ_FETCH_OFF = 1` (`fifo_ppu.nim`, `obj_fetch_on`).
- Rule: on a CGB the fetcher stops for every object the scan kept whether or
  not LCDC.1 is set; the bit only keeps object pixels out of the mixer. On a
  DMG a clear LCDC.1 stops the fetches (and their dots) as well.
- Evidence: gambatte `sprites/late_disable_ds_1` [cgb] runs with LCDC = $91
  throughout, ten objects on the line, and still reads mode 3 where an
  object-free line has ended. `sprites/enable/late_disable_ds_{3,4}` clear
  the bit on the line before and bracket the end of mode 3 to one
  double-speed M-cycle at the full object length. `oamdma/late_sp39x_{3,4}`
  and the twelve `oamdma/late_sp*_ds_*` tests never set the bit and time an
  object's presence by the length of mode 3. 0 loses nine tests
  (`late_disable_ds_1`, `enable/late_disable_ds_3`, `late_sp39x_4`,
  `late_sp{00,01,39}x_ds_2`, `late_sp{00,01,39}y_ds_1`). The DMG half is the
  sixteen `sprites/sprite_late_disable_*` and `sprite_late_late_disable_*`
  tests, which the knob does not touch.
- Open: nothing here says whether a DMG cart on a CGB behaves as the CGB or
  as the DMG; the rule is applied to the console.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### Reading a mealybug `m3_*` frame as eighteen measurements
- `m3_scy_change`'s OAM table is Y = 16 + 8k, X = k, so each 8-line band is one
  object whose X sets the wait term; score per band, not per frame, or a
  constant gets fitted to a residual from another band. Method in
  `tools/gbppu/README.md` (`-d:gb_m3_trace -d:GB_TRACE_LY=-1`, `mbscore.py`).

## 4. CGB register write latency

### The CGB delays a mid-line write per register, not by one phase
- Default (`gb.nim`): `CGB_SCY_LATENCY = 2`, `CGB_SCX_LATENCY = 2`,
  `CGB_WY_LATENCY = 4`, `CGB_WX_LATENCY = 1`, `CGB_WY_LATCH_LATENCY = 0`,
  `CGB_LCDC_LATENCY = 0`, `CGB_MAP_LATENCY = 2`, `CGB_MIXER_LATENCY = 1`,
  `CGB_LATENCY_CAP = 1`. The mechanism (`mem_tick_ppu_latched`) parks the
  store and runs the M-cycle's dots around it, so nothing runs per dot.
- Why independent per register: gambatte `window/late_disable_{0,1,2}` wants
  CGB one M-cycle later than DMG while
  `late_disable_early_scx03_wx12_{1,2,3}`, the same shape, wants it one
  M-cycle earlier. No phase offset produces both.
- SCY/SCX 2: Pan Docs, "Scrolling" → "Mid-frame behavior" gives the CGB a
  2-T-cycle SCY delay; mealybug `m3_scy_change*`, `m3_scx_high_5_bits*`
  (`_cgb_c`) and gambatte `enable_display/ly0_late_scx7_m3stat_scx0_274` pin
  it, given the object-fetch phase of §3 (with that phase wrong the same rows
  read 1: the fetch phase absorbs a dot of latency).
- WY 4: gambatte `window/arg/late_wy_*` expect the CGB step one M-cycle
  earlier than DMG in 13 of 14 families; the sweep saturates from 3 up.
- WX: `CGB_WX_LATENCY = 1`, taken by every CGB at single speed
  (`CGB_WX_LATE_SS`, §2) and by the AGB at both speeds.
- LCDC 0: every nonzero whole-register value costs gambatte
  `window/late_disable*`, which want a CGB fetcher abort on a mid-fetch
  window disable, not a dot. Per-bit readers carry their own delay
  (`CGB_OBJ_SIZE_LATENCY`, `CGB_TDSEL_LATENCY`, `CGB_MAP_LATENCY`).
- MIXER 1: mealybug `m3_bgp_change_cgb_c.png` pixel-exact with the dot,
  `_cgb_d.png` pixel-exact without it; CGB D+ drop it
  (`GbQuirks.mixer_write_immediate`). LCDC keeps the dot on every revision:
  the `_cgb_c`/`_cgb_d` captures of the LCDC ROMs are byte-identical.
- CAP 1: keeps a register latency from being scored against the
  double-speed `_ds_` / `lcd_offset` families, which measure the CPU-to-PPU
  phase a KEY1 switch leaves (0..3 dots), a different quantity.
- Open: the CGB-only fetcher abort on a mid-fetch window disable (gambatte
  `late_disable` / `late_reenable`; mealybug's two `m3_lcdc_win_en_change`
  rows are bad on both devices).

### SCX: high 5 bits per fetch, low 3 at the line start
- Claim: Pan Docs, "Scrolling": the high five bits are re-read per tile fetch
  and the fine scroll is latched once per line. The discard is the fetcher's,
  taken when the throw-away first fetch completes.
- Evidence: mealybug `m3_scx_low_3_bits`, `m3_scx_high_5_bits`.

### The map column's borrow is measured against the pixels the discard threw away
- Default: `SCX_WRAP_BORROW = 1` (`gb.nim`; `fifo_arm_scx` in `fifo_ppu.nim`).
- Rule: the BG fetcher's map column is `floor((SCX + 8k - D) / 8)`, k the
  fetch index and D the number of pixels the line's fine-scroll discard
  threw away (less one on a DMG, `SCX_FINE_BORROW_DMG_LEAD`). On an
  undisturbed line D is the latched `SCX and 7` and the term is the one-tile
  borrow `SCX_FINE_BORROW` describes. A store the discard takes
  (`SCX_FINE_LATCH_LIVE`) moves D with it, and a store that wraps the
  discard's slot counter (`SCX_FINE_LATCH_WRAP`) adds its eight pixels to D.
- Evidence: gambatte `scx_during_m3/scx_0761c0` latches SCX = 7, stores $61
  inside the discard (the target 1 is already behind the slot counter, so it
  wraps: 9 pixels thrown away) and stores $C0 at a point that moves across
  the line from ROM to ROM. Its map has tiles 2/3 alternating in columns
  0..11 and 0/1 in 12..31, so the picture gives the column's parity. After
  the $C0 store the CGB frames show the column of `($C0 - 9) shr 3 = 22`;
  measured against the latched 7 it would be 23. With D frozen at the
  latched value (0) `scx_during_m3_{2,3,4}` and `_ds_{2,3,4,5}` [cgb] fail
  by one tile from the $C0 store on. The DMG frames show 23 and pass either
  way: `($C0 - 9 + 1) shr 3 = 23`. The term is only ever a borrow: on a DMG
  whose reference is -1 (an unscrolled line) the plain floor would add a
  tile at `SCX and 7 = 7`; no test asks for that and the borrow is clamped
  at none there, as it was before the wrap term. A variant in which D moves only on a wrap
  was tried and scores the same on every suite; the rule with no special
  case is the default (1; 0 is the frozen reference).
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### The LCD-on line takes an SCX store for longer
- Default: `SCX_LATCH_LCDON_EXTRA = 1` (DMG), `SCX_LATCH_LCDON_EXTRA_CGB = 2`
  (`fifo_ppu.nim`, `fifo_sample_smooth_scroll`).
- Rule: on the line the LCD is switched on with, the fine-scroll discard
  keeps taking an SCX store (`SCX_FINE_LATCH_LIVE`) for 1 dot (DMG) or 2
  dots (CGB) past its own length.
- Evidence: gambatte `enable_display/ly0_late_scx7_m3stat_scx{0,1,3}_*`
  replace SCX 0, 1 or 3 by 7 one M-cycle later per ROM on that line and read
  the end of mode 3. Both values are strict optima: DMG 0 loses
  `scx0_2` [dmg], 2 loses `scx3_2` [dmg]; CGB 1 loses `scx1_1` [cgb], 3
  loses `scx0_2` [cgb].
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

## 5. VRAM DMA (HDMA/GDMA)

### HDMA1–4 are write-only and read $FF
- Claim: Pan Docs, "CGB Registers" → "LCD VRAM DMA Transfers" marks
  FF51–FF54 write-only; the read value is not documented.
- Evidence: gambatte `dma/ff51_bits` … `ff54_bits` expect $FF on cgb04c.

### HDMA1–4 are the transfer's counters; a write to FF55 does not reload them
- Evidence: SameSuite `dma/gbc_dma_cont` runs two one-block GDMAs with the
  address registers written once and hardware copies two tiles; gambatte
  `hdma_late_destl` shows a mid-transfer FF51–54 write moving the blocks that
  follow. The destination mask is on the driven address, not the counter: a
  transfer that would step off the top of VRAM stops (gambatte `dma_dst_wrap`,
  Pan Docs "if the transfer's destination address overflows, the transfer
  stops prematurely"); the source wraps (`dma_src_wrap`).

### A halted CPU stalls an armed HBlank transfer
- Claim: Pan Docs, same section: "Upon halting the CPU … the transfer will
  also be halted and will be resumed only when the CPU resumes execution". A
  block is owed only for as long as its HBlank lasts; halt across the end of
  mode 0 and that line's block is never transferred. Paid at the M-cycle the
  halt ends, ahead of that wake's interrupt dispatch.
- Evidence: MagenTests `hblank_vram_dma`; gambatte
  `dma/hdma_m3halt_m1unhalt_hdma5`. The `hdma_late_*` / `_unhalt_*`
  one-M-cycle pairs are the next two entries; `HDMA_HALT_BLIND_LAG*` is
  documented at its declaration in `gb.nim`.
- Site: the check sits inside the halted branch of `cpu.tick` and is asked
  only on the M-cycle the halt ends (asking every halted M-cycle measured
  0.3 % of Pokemon Blue).

### A HALT's execute cycle is an opcode fetch: an HBlank request it meets waits for the wake
- Default: `HDMA_HALT_REQ = 1` (`gb.nim`); `cpu_halt`, `cpu_halt_wake`,
  `cpu_latched_op` (`cpu.nim`), `ppu_hdma_halt_request`,
  `ppu_hdma_pay_halt_request`, the mode 3 -> 0 edge in `mode_flag=`
  (`ppu.nim`), `stop_instr` (`memory.nim`), the STOP handler (`opcodes.nim`).
- Rule. The SM83 reads the byte after a HALT in the HALT's own execute
  cycle, as it reads the next opcode in the last cycle of every instruction.
  That cycle is therefore one of the CPU's hand-over points for a VRAM DMA
  (the end of an opcode fetch, `HDMA_GRANT_FETCH_DOTS`). An HBlank request
  that comes up inside it (the mode 3 -> 0 edge 4 dots earlier, so on one of
  the last three dots of the HALT's fetch or on the dot that fetch ends, at
  single speed; on the last two dots of the fetch at double speed, where the
  cycle is 2 dots) is taken at its end, but the CPU halts there and a
  halted CPU's transfer does not run (Pan Docs, FF55). The block waits for
  the wake, in whatever mode the wake finds the PPU, and then:
  1. its sixteen bytes go out, 32 dots; an HBlank edge inside them, or
     inside the M-cycle after them, makes no second request;
  2. the byte the HALT's execute cycle read is executed from the latch, with
     no second read and no step of PC over it. The instruction after the
     HALT so runs twice in effect: once from the latch with its operands
     taken from its own address, then again from memory. Its first M-cycle
     is the block's hand-back, so the block costs 36 dots in all;
  3. the interrupt that ended the halt is dispatched after that instruction.
  One dot earlier the request is up by the end of the HALT's fetch and the
  block runs before the halt; one dot later the CPU is halted when the edge
  arrives and the block is an ordinary halted one (paid at the wake only if
  its HBlank is still running, `HDMA_WAKE_M0_MARGIN`).
- The speed switch's stall is the same halt (Pan Docs' STOP chart: "HALT
  mode"), and the latched byte is STOP's second, which is executed instead
  of skipped. Into single speed the block is paid at the stall's end exactly
  as above. Into double speed the block's bytes go out under the stall at no
  cost to the CPU and the transfer's control state is lost with the clock
  change: FF55 then reads bit 7 set over the undecremented length and no
  further block follows.
- Tests (gambatte `dma/`, CGB), each a HALT or STOP walked across the edge one
  M-cycle at a time, the middle member inside the window:
  `hdma_late_m3halt_m2unhalt_scx{1,2}_{1,2}` (FF55 after a mode-2 wake: $00
  before the window, $FF inside), `_inc_scx{1,2}_{1,2,3}` (`inc a` after the
  HALT: 1, 2, 1), `_ly_scx2_{1..6}` (LY read after the wake: the same NOP
  count before the window, where the next line's own block costs 36 dots,
  and inside it, the doubled NOP included; nine NOPs more after it, the
  block before the HALT), `hdma_late_ei_m3halt_m2unhalt_{ly,pc}_scx1_*`
  (IME on: the same time, the pushed address HALT + 1),
  `hdma_transition_halt_m0unhalt_ldaaimm_scx1` (`ld a,[$0080]` reads
  [$80FA]), `hdma_transition_7fffhalt_inc_m3unhalt` (the latched `inc a`
  from $8000 runs under a mode-3 wake, the re-read answers $FF),
  `hdma_transition_{,ei_}halt_late_unhalt_{,ldaaimm_hdma_}scx1_{1,2}` (a wake
  36 and 40 dots before the next edge: the edge is lost, or its block
  follows; with IME on the latched `ld [$0080],a` writes [$80EA] before the
  handler reads it). Speed switch: `hdma_late_m3speedchange_inc_scx1_{1,2,3}`
  and `hdma_late_speedchange_inc_scx1_ds_{1,2,3}` (`stop, $3C`: A = 1, 2, 1),
  `hdma_transition_speedchange_ldaaimm_scx1{,_ds}` (`stop, $FA` then
  `$80 $80`: [$8080] is read), `hdma_transition_speedchange_7fffstop_inc`,
  `hdma_late_m3speedchange_hdma5_scx{1,2}_{1,2,3}` ($00, $80, $FF) and
  `_ds_{1,2}` ($00, $FF), `_read_hdmadst00_scx{1,2}{,_ds}_{1,2}` (the first
  byte is in VRAM in both directions), `_ly_scx1_{1..6}` (into double speed:
  one NOP late, no block time), `_tima_scx1_ds_{1..6}` (into single speed:
  TIMA 36 dots on), `hdma_transition_speedchange_hdmalen{00,01,7f}_hdma5_scx1`
  and `_hdmalen{01,7f}_hdmadst10_scx1`.
- Two-sided: `-d:HDMA_HALT_REQ=0` (the request paid at the HALT) loses 33
  gambatte tests and gains none. The window's width is not a constant: it is
  the execute cycle, 4 dots or 2, and the double-speed tests
  `hdma_late_m3speedchange_*_ds_1` (the edge on the dot the STOP's fetch
  ends, or the one before: not taken) fail at the single-speed
  width.
- Save states: the taken request and its latched byte ride in a slot
  of `GB_SEC_MACH` that was reserved (format unchanged); a HALT can outlast a
  frame.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### A HALT wake and the HBlank edge detector
- Default: `HDMA_WAKE_M0_MARGIN = 4`, `HDMA_WAKE_BLIND_DOTS = 4` (`gb.nim`);
  `ppu_hdma_wake`, `mode_flag=` (`ppu.nim`).
- Rule. A block that came due under a HALT is taken at the wake if its
  HBlank is still running once the PPU's held-back dots are paid
  (`CGB_HALT_PPU_LEAD`): the margin is that lead, 4 dots, 2 at double speed.
  A CPU halted in mode 0 has an edge detector whose copy of the mode still
  reads 0 (`HDMA_HALT_M0_BLIND`); the first M-cycle after the wake is what
  clocks it again, so an edge inside that M-cycle is not seen.
- Tests and brackets. Margin [3, 5]: gambatte `dma/hdma_late_m0unhalt_{1,2}`
  (2 loses `_1`, 7 loses `_2`) and `_ds_{1,2}` (6 loses `_ds_2`). Blind
  window [4, 7]: `dma/hdma_m0halt_late_m3unhalt_scx1_{1,2}` (3 loses `_2`, 8
  loses `_1`). A stall that runs out its count has no wake M-cycle and no
  blind window: `dma/hdma_m0speedchange_late_m3wakeup_scx{1,2}_{1,2}`; the
  stall freezes the detector as a HALT does and pays a due block at its end
  on the same margin (`dma/hdma_m3speedchange_late_m0wakeup_{1,2}`).
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### The first M-cycle of an interrupt dispatch is a hand-over point
- Default: `HDMA_DISPATCH_FETCH = 1` (`cpu.nim`, `dispatch_interrupt`).
- Rule. The end of a dispatch's first M-cycle (of the five Pan Docs lists
  under "Interrupt Handling"; PC is pushed in the fourth and fifth, section
  7) is a hand-over point on the same terms as the end of an opcode fetch;
  the tests show the hand-over, not its cause. An HBlank request up by the end of that M-cycle (the
  mode 3 -> 0 edge no later than the dot the dispatch begins on) runs its
  block ahead of the two pushes; one dot later the block waits for the
  handler's first fetch.
- Tests: gambatte `irq_precedence/hdma_vs_m0_scx{1,2,3}`,
  `hdma_vs_m0_scx2_halt`, `late_hdma_vs_{ei,ie}_scx{1,2}_{1,2}`,
  `late_hdma_vs_tima_scx{1,2}{,_halt}_{1,2}`: the block's source is the stack
  the dispatch pushes onto, and the tests read $1234 (block first) or the
  pushed PC. `-d:HDMA_DISPATCH_FETCH=0` loses the seven tests with the edge
  on the dispatch's first dot.
- Every dispatch has that M-cycle; only one under an armed HBlank transfer
  or a requested general-purpose burst stops at its end to ask. The block
  runs beside the dispatch: the two wait M-cycles that are left, the pushes
  and the IF clear keep their places after it ("The dispatch pushes in its
  fourth and fifth M-cycles", section 7). With the pushes moved from the
  first two M-cycles to the last two the seven tests did not move: the
  hand-over is ahead of the pushes either way.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### A general-purpose DMA takes the bus at the next opcode fetch
- Default: `GDMA_GRANT_FETCH = 1` (`gb.nim`); `ppu_start_hdma` (`ppu.nim`),
  `hdma_grant` (`cpu.nim`).
- Rule. The FF55 write raises the request; the CPU fetches its next opcode
  and hands the bus over at the end of that fetch. The burst runs, then the
  fetched instruction's remaining M-cycles.
- Tests: gambatte `dma/late_gdma_pc_7ffe_1` (the write at $7FFE: `LD A,[nn]`
  is fetched from the old byte at $8000 and reads its operands from the
  burst's bytes); DocBoy `cgb/hdma/gdma_source_*` (19 tests: the first byte
  from a source no bus answers is the opcode after the write,
  `VDMA_BUS_RESIDUE`) and `gdma_ppu_on_pixel_transfer_conflict_relaxed_*`
  (82 tests: which bytes mode 3's fetches refuse, `VDMA_M3_PORT`, places the
  burst to the dot). `-d:GDMA_GRANT_FETCH=0` loses 103 tests.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### An FF55 write arming an HBlank transfer inside HBlank
- Default: `HDMA_START_GRANT_FETCH = 2` (`gb.nim`), `HDMA_START_REQ_LAG = 1`
  (`ppu.nim`).
- Rule. The request is up at once and is answered at the end of the next
  opcode fetch, not on the write and not at the write's own instruction
  boundary. The request is the HBlank level: if the line ends first, the
  block is still taken when that fetch ends within one dot of the new line's
  start, and otherwise waits for the next HBlank.
- Tests and brackets. `HDMA_START_GRANT_FETCH` [2, 3]: gambatte
  `dma/hdma_pc_7ffe` (1 loses it and two `hdma_late_enable_*_2` tests),
  `dma/hdma_late_enable_ds_lcdoffset1_1` (4 loses it), DocBoy
  `cgb/hdma/hdma_start_during_oam_scan_with_dma_running` and
  `hdma_source_wram_dma_source_ram_during_oam_scan` (5 loses both).
  `HDMA_START_REQ_LAG` = 1 exactly: gambatte `dma/hdma_late_enable_{1,2}`,
  `_ds_{1,2}`, `_lcdoffset3_{1,2}`, `_ds_lcdoffset1_{1,2}` (the fetch ends on
  dot 1 of the next line in `_1` and `_ds_1`, block taken; on dot 2 in
  `_lcdoffset3_2` and `_ds_lcdoffset1_2`, not taken). The two cutoff knobs
  this replaces (`HDMA_START_CUTOFF_SS`/`_DS`, dots back from the line end
  to the write) fit single speed at 2 and have no value at double speed: 0
  loses `_ds_lcdoffset1_2`, 1 loses `_ds_1`.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### Switching the LCD off moves one HBlank block
- Default: `HDMA_LCD_OFF_BLOCK = 1`, `HDMA_LCD_OFF_EDGE = 1` (`gb.nim`);
  `ppu_write` $FF40 (`ppu.nim`).
- Rule. With the LCD off the mode reads 0, so the switch-off is one more
  entry into HBlank for an armed transfer, and the last until the LCD is
  back on. It is an edge: a PPU already in HBlank, its block paid, moves
  nothing more; a block still owed when the write lands is paid.
- Tests: `-d:HDMA_LCD_OFF_BLOCK=0` loses 16: gambatte
  `dma/hdma_disable_display_1`; DocBoy `cgb/hdma/hdma_ppu_on_turn_off_
  during_ly1_oam_scan`, nine `hdma_halt_resume_with_stat_vblank_*`, four
  `hdma_halt_resume_with_timer_interrupt_*`, `double_speed_hdma_basic_
  transfer`. `-d:HDMA_LCD_OFF_EDGE=0` (every switch-off moves a block) loses
  6: `hdma_ppu_on_turn_off_during_{ly0,ly1}_hblank` and the four
  `hdma_halt_resume_with_timer_interrupt_*` tests that switch off in HBlank.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### FF55 bit 7 means "no transfer active" on every path into that state
- Claim: Pan Docs: "This works under any circumstances — after completion of
  General Purpose, or HBlank Transfer, and after manually terminating a HBlank
  Transfer." The write's own low bits land in the length register whether it
  starts or stops a transfer ($00 written to stop with three blocks left reads
  $80, not $82).
- Evidence: gambatte `dma/hdma_lcd_off`, `hdma_mode0`.

### A source outside cartridge or WRAM transfers $FF
- Claim: Pan Docs gives the source as $0000–$7FF0 or $A000–$DFF0; anything
  else is open bus. Decided once per 16-byte block (HDMA2 masks the low
  nibble, so a block cannot straddle a region).
- Evidence: gambatte `dma/dma_hiram_read_result` (GDMA $FF80 → $8000, then
  `SUB $FE` expecting 1, i.e. $FF landed); `dma_hiram_read`, `dma_oam_read`,
  `dma_vram_read` only assert the destination differs from the source.

### GDMA setup cost — open
- Default: `GDMA_SETUP_MCYCLES = 0` (`gb.nim`). gambatte `dma/gdma_cycles_*` say
  general-purpose DMA is short of hardware, but no constant satisfies all
  nine pairs; the residual tracks SCX, so it is not a fixed setup cost.
  `tools/gbdiff/gdma_sweep.sh` reads the pairs at any setting.

## 6. OAM DMA bus conflicts

### The DMA unit owns one bus for the whole 160-M-cycle transfer
- Claim: Pan Docs, "OAM DMA Transfer" → "OAM DMA bus conflicts", generalised by
  the memory map and the PPU's own video bus:
  - external: cart ROM $0000–$7FFF + SRAM $A000–$BFFF, plus WRAM $C000–$FDFF
    on DMG (one external bus for cart and RAM);
  - video: VRAM $8000–$9FFF;
  - WRAM $C000–$FDFF on CGB only.
  A CPU access on the DMA's bus does not reach memory: a read returns the
  byte in flight; a write is lost and the CPU's value ends up in OAM at this
  M-cycle's position. IO, HRAM and IE are on no bus and are untouched.
- What lands in OAM on a colliding write depends on the source memory:
  cartridge source → the CPU's byte (gambatte `oamdma/src0000/7F00/A000/BF00
  push*`); DMG WRAM source → wired-AND of the two (`srcC000/DF00 push*`,
  $55 & $65 = $45); CGB WRAM source → the CPU's access is lost, the DMA's read
  completes; CGB video source → the DMA loses the cycle and OAM takes $00,
  for a colliding read too (`src8000/9F00 pop7FFF/9FFF`).
- On CGB a source at or above $E000 drives the external bus, where nothing
  answers: every byte is $FF. The echo remap stays DMG-only (mooneye
  `oam_dma/sources-GS`). The whole page $FE00–$FEFF reads $FF while the unit
  owns it, not just $FE00–$FE9F.
- Word accesses wrap the 16-bit address bus: `push`/`pop` with SP at
  $0001/$FFFF (the `busypush`/`busypop` families) sent the high byte to $10000.
- Site: `dma_busy` (set alongside every `dma_position` mutation, re-derived in
  `load_mem_state`) gates the hot path; the conflict logic is in the
  `{.noinline.}` `mem_read_busy`/`mem_write_busy`. Real games busy-wait in
  HRAM, so the cold path sees essentially zero conflicts (Zelda: 8181 DMAs,
  989 901 accesses through it, 0 conflicts). Cost analysis:
  `docs/dev/gb_oam_dma_cost.md`.

### An FF46 write under a running transfer moves the bus at once
- Default: `OAMDMA_RESTART_HANDOVER = 1` (`gb.nim`); `write_byte` $FF46
  (`memory.nim`).
- Rule. Written while a transfer runs, FF46 moves the bus the unit holds to
  the new source page with the write: a CPU access on the new source's bus
  conflicts from the next M-cycle, two M-cycles before the restart.
- Not pinned: where the old transfer's last two bytes come from. The test
  passes whether they are read from the old page or the new one, and no
  other test asks, so they stay on the old page.
- Tests: gambatte `oamdma/oamdma_src8000_srcchange0000_busyinc` (DMG and CGB;
  0 loses both). `oamdma_src8000_srcchange0000_busyread0000_{1,2}` and
  `oamdma_src8000_srcchangeC000_busyread8000` do not move.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### The OAM DMA unit under a HALT: one more M-cycle, and the release needs none
- Default: `OAMDMA_HALT_GRACE = 1`, `OAMDMA_WAKE_EXTRA = 0`,
  `OAMDMA_FROZEN_RELEASE = 1` (`gb.nim`); `mem_dma_tick`,
  `mem_dma_release_frozen`, `mem_tick_stalled` (`memory.nim`).
- Rule. The unit is clocked by the CPU's bus cycles and stops with them
  (`OAMDMA_HALT_PAUSE`). The HALT's execute cycle is a bus cycle (it reads
  the byte after the HALT), so the unit moves one more byte after the HALT's
  fetch and owes nothing at the wake. The step after byte 159, which only
  gives OAM back, is not a bus cycle: a unit frozen with every byte moved
  releases OAM. The speed switch's stall is the same
  (`SPEED_SWITCH_OAM_DMA_HANDBACK_T`).
- Tests and joint fit. gambatte `oamdma/oamdmasrc80_halt_{lycirq,m2irq}_
  read8000` (DMG and CGB) and `dma/hdma_transition_oamdma_2` pin grace +
  hand-back at one M-cycle: (1, 0) and (0, 4) pass, every other pair in
  {0,1,2} x {0,4,8} loses all five. `oamdma/oamdma_late_halt_stat_{1,2}`
  (DMG and CGB) pick (1, 0) with the release rule: byte 159 must move under
  the halt in `_2` and byte 158 with 159 still owed must not finish in `_1`.
  Without the release rule only grace 2 passes `_2`, and loses the five.
  `oamdma/oamdma_late_speedchange_stat_2` [cgb] is the same across the
  stall, but its LCDC has bit 1 clear, so it also needs the CGB's object
  fetch with LCDC.1 clear (`obj_fetch_on`, `fifo_ppu.nim`, another entry):
  with that fetch forced on for a CGB the test passes with the release and
  fails with `-d:OAMDMA_FROZEN_RELEASE=0`; without it the test reads mode 0
  either way.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### The mode-2 scan under an OAM DMA compares what its latches last held
- Default: `OAM_SCAN_DMA_HOLD = 1`, `OAM_SCAN_DMA_EDGE_DS = 1` (`fifo_ppu.nim`;
  `oam_scan_advance`, `fifo_oam_lock_change`, `sprite_fetch_merge`), on top
  of `OAM_SCAN_DMA_LOCK` and `OAMDMA_FREEZE_BUS`.
- Rule: the scan steps through its forty two-dot slots whoever has the OAM
  bus. While a transfer has the bus the scan's Y/X input latches are not
  loaded, so each slot inside the transfer's span compares the word the
  latches last loaded, and an object is kept (at that X) for every slot in
  which that Y is on the line, up to the usual ten. The latches
  (`scan_y_latch`, `scan_x_latch`) load an entry's Y and X in its slot, until
  the line has its ten objects. An object's mode-3 fetch then replaces the Y
  latch with its tile byte; under a transfer that is the byte the unit has
  on its bus (the read strikethrough pins, `OBJ_DMA_BUS_LEAD`). A transfer
  frozen by HALT on a DMG drives the latches with its destination word
  instead (`OAMDMA_FREEZE_BUS`).
- Evidence, the hold: DocBoy `dmg/ppu/oam_scan_blocked_by_dma_nops{100..107}`
  (ten objects in entries 0..9, X = $10, $18 .. $58) and `nops{115..122}`
  (the same ten in entries 30..39) start a transfer one M-cycle later per
  ROM and bracket the end of mode 3 to one M-cycle (`_round1` reads mode 3,
  `_round2` one M-cycle later reads mode 0). The object dots come out as 0
  for nops 100/115, then 64, 72, 84, 92, 104 (each +0..3) for 101..105 and
  116..120, then 108 for the rest. A transfer that takes the bus after k
  entries were read (k = 1, 3, 5, 7, 9) leaves k objects on k tiles (11 dots
  each) and 10 - k copies of the last one read at its X (6 dots each): 60 +
  5k = 65, 75, 85, 95, 105. Dropping the blocked entries gives 11k and loses
  the ten `_round1` tests; reading OAM at the unit's address would put
  several X values per M-cycle on the line and fits neither group. The same
  two groups, 60 dots apart with identical lengths, show the count follows
  the entries read and not the dot. `strikethrough` (both frames, and the
  shootout's test) and mooneye `madness/mgb_oam_dma_halt_sprites` (both
  copies) pass only with the hold; the second reaches the comparator through
  the frozen-bus word.
- Evidence, what is held before a line's first slot: gambatte
  `oamdma/late_sp39y_2` (both devices) has entry 39 on the line (Y = $10,
  X = $A0, tile and flags $A0), fetched on line 2, and a transfer covering
  all of line 3's scan: no object is found. A Y latch still holding entry
  39's Y (the scan's last read) finds ten; one the fetch replaced with the
  tile byte ($A0) finds none. `late_sp39y_ds_2` [cgb] starts the transfer
  before that fetch and still finds none, so the fetch replaces the Y latch
  under a transfer as well (the unit's byte, $A0).
- Pinned and chosen. Pinned by tests: the hold and the X the copies take
  (the twenty DocBoy tests, strikethrough, `mgb_oam_dma_halt_sprites`); that
  a fetch replaces the Y latch, with and without a transfer running (the two
  `late_sp39y` tests). Those two tests only need a Y that is off the line.
  Modelling choices no test sees: that the replacing byte is the tile byte
  (any off-line value passes); that the fetch leaves the X latch alone
  (loading the flags byte into it gives identical verdicts and screenshots);
  that the latches stop loading once the line has ten objects (loading on
  through entry 39 gives identical verdicts and screenshots). The smaller
  model is the default in both cases.
- Evidence, the double-speed edge: `OAM_SCAN_DMA_EDGE_DS` is the number of
  dots the take/give edge sits ahead of the dot its M-cycle starts on, at
  double speed. gambatte `oamdma/late_sp{00,01,39}{x,y}_ds_{1,2}` [cgb]: 0
  loses the six `_ds_1` tests, 3 loses `late_sp{00,01}{x,y}_ds_2`, 1 and 2
  pass all twelve (slots sit on even dots, these edges on odd ones). The
  value is relative to `OBJ_SCAN_DOT_ADJ = 0`; at -1 the six `_ds_1` tests
  fail again. By
  their traced edge dots (not swept) the single-speed CGB tests would accept
  -1..2 and DocBoy's DMG tests -1..0, so the term is double-speed only.
- Shared test: `oamdma/oamdma_late_speedchange_stat_2` [cgb] needs this
  entry's neighbour, the CGB fetch with LCDC.1 clear (it runs at LCDC = $91),
  and one thing more on the DMA unit's side: its `_1`/`_2` pair stops the
  unit by a speed switch with one byte left (`_1`, no object on line 3) or
  with the last byte written (`_2`, the object is found), and a unit whose
  last byte is written releases OAM at the stall (`OAMDMA_FROZEN_RELEASE`,
  "The OAM DMA unit under a HALT", above). With both the test is green.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### DMG OAM bug: a word-3 write after the scan's last row also corrupts word 2
- Site: `oam_bug_scan_end` (`ppu.nim`), the row-20 M-cycle (cc 77..80) of
  "The DMG OAM corruption bug" table there; the rest of that table is
  `docs/dev/gb-failure-triage.md` I5.
- Rule: a CPU write to word 3 of row X on that M-cycle gives X's word 3
  maj(X w3, 19 w3, 19 w2), as for every word, and X's word 2 maj(X w2,
  19 w2, that word 3) (taken before the CPU's byte lands) where every other
  word is a plain copy of row 19. Reads and writes of words 0-2 are
  unchanged. Word 3 is already the odd one out at row 20: a read of it is
  `19 w3 | (X w3 & 19 w2)`, not the majority.
- Evidence: DocBoy `dmg/oam_bug/oam_bug_ld_{hl,hli}_a_round23_fe46/fe47`
  (byte 0 or 1 of row 8's word 3 written with $00; expected word 2 $11 $0F
  where row 19 has $55 $0F and row 8 had $AA $0F; the low byte, $AA against
  $55, shows all eight bits of the third input, $11 = the word-3 value, and
  the high byte is equal in both rows so the majority keeps it). Words 0-2
  at round 23 (`_fe40`..`_fe45`, `_fe48`) leave word 2 a copy of row 19
  under the same pattern, so the rule is word 3's alone; `push_round21`
  writes word 3 at round 23 with words 2 already equal. The fit is not
  unique: `19 w2 & 19 w3` as the third input gives the same $11; the
  word-3 value is the quantity the row-20 rule already computes. SameBoy (DMG B, black box) fails all four.
  DocBoy's author runs the suite on his DMG; no hardware claim per row.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

## 7. CPU

### The eleven undefined opcodes lock the CPU until reset
- Claim: Pan Docs, "CPU Instruction Set": D3/DB/DD/E3/E4/EB/EC/ED/F4/FC/FD
  hang the SM83. Modelled as `halted` plus a sticky `locked` so the PPU,
  timer, OAM DMA and scheduler keep ticking (the frame keeps drawing) and no
  interrupt clears it. PC stays on the opcode. GB payload rev 4.
- Evidence: gambatte `undef_ops/*` (20 ROMs).

### The KEY1 speed switch resets DIV and stalls the CPU
- Default: `SPEED_SWITCH_STALL_CPU` (`memory.nim`), with
  `SPEED_SWITCH_PPU_EXTRA_DOTS` (to-double 8, to-single 3).
- Claim: Pan Docs, "Reducing Power Consumption" has STOP resetting DIV; the
  reset goes through the FF04 write path so the APU frame sequencer, serial
  and TIMA see it as any DIV write. Pan Docs, "CGB Registers" → "FF4D — KEY1"
  says the CPU stops for 2050 M-cycles (8200 T); hardware stalls for about
  2^16 dots. Dingbat disagrees with Pan Docs here (`docs/dev/pandocs-upstream.md`).
  The CPU-clock domain (timer, serial, OAM DMA) stops; the LCD, HDMA and the
  APU's real-time events run; the DIV-APU frame sequencer is lifted over the
  stall and re-aimed from the reset divider ("some audio events are not
  processed"). 8200 is real-time T-cycles, `shl current_speed` in the
  scheduler domain.
- Evidence: gambatte `speedchange_div_*` / `speedchange2_div_*` (DIV 00/01);
  `speedchange/speedchange_ly44_m3_ly`, `speedchange_ly97_ly` and
  `dma/hdma_late_m3speedchange_ly*` want ~143 scanlines across the switch,
  which 8200 cannot give; blargg `cpu_instrs` 03/06/11 render their result
  line only in the 2^16 region (the ROM's bounded vblank poll is half a
  frame at double speed, so it blits with the LCD on and mode 3 correctly
  drops cells — the panel is a phase probe, not a glyph oracle, which is why
  `--screen-check` asserts only that it settles and is not flat). The 12-dot
  extra and its 8/3 split are the `ly44_m3` switch-count ladder (five rungs,
  two unknowns; all 55 rows green at (8, 3), 20 lost at B = 4, 14 at B = 2).
  The gambatte tests pin the region.
- Open: the `lcd_offset` family wants A + B ≡ 0 (mod 4) where the ladder says
  11, and contradicts itself at that resolution (`offset1_lyc99int_m0stat_*`
  vs `_m0irq_*`): the known one-dot-early mode-0 STAT raise seen from inside
  the instrument.

### HALT with an interrupt already pending, and the DMG HALT's minimum length
- Default: `HALT_IME_PENDING_REDO = 1`, `DMG_HALT_MIN_MCYCLES = 2`,
  `M2_LEAD_HALT_BLIND_DMG_ONLY = 1` (`cpu.nim`).
- Rule. HALT with IF & IE != 0 does not halt, whatever IME is, and PC fails
  to step. With IME clear that is the halt bug (Pan Docs). With IME set the
  dispatch that follows at once pushes the unstepped PC, the HALT's own
  address, so the handler returns onto the HALT.
- Tests: gambatte `halt/late_m0int_halt_m0stat_scx{2,3}_*` (a mode-0 handler
  that returns with interrupts off: the members whose HALT follows the
  request halt again on the return and read STAT 48 NOPs after the next
  line's wake; the members whose HALT comes first read it 30 NOPs after
  their handler), DocBoy `dmg/cpu/halt_ime1_interrupt1_ret`.
  `-d:HALT_IME_PENDING_REDO=0` loses the four `_3a` tests, `_scx3_3b` [dmg]
  and the DocBoy test.
- `DMG_HALT_MIN_MCYCLES`: a request rising inside a DMG's first halted
  M-cycle ends the HALT one M-cycle later. 2 exactly: 1 loses gambatte
  `halt/late_m0int_halt_m0stat_scx3_2b` and `late_m0irq_halt_m0stat_scx3_2b`
  [dmg]; 3 loses six `late_m0{int,irq}_halt_m0stat_*` tests [dmg].
- `M2_LEAD_HALT_BLIND_DMG_ONLY`: the halted CPU's blindness to the mode-2
  source inside its lead is the DMG family's. 0 loses gambatte
  `halt/noime_m2irq_m0stat_1` [cgb].
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### The halted CPU samples the interrupt line at the end of its M-cycle
- Default: `HALT_IF_SAMPLE_T = 4` (`cpu.nim`); 2 is the alternative arm.
- Open: at 2, GBMicrotest `int_hblank_halt_scx{0,3,4,7}` and wilbertpol
  `hblank_ly_scx_timing-C` go green and mooneye `hblank_ly_scx_timing-GS`
  (both copies) goes red; no value passes both, and `int_hblank_nops_scx0`
  (the non-halt sled endpoint) is green at either. The 2 arm splits every
  halted M-cycle's PPU tick and costs +5 % retired instructions on Pokemon
  Blue; the untried reduction is to skip the split when the PPU's idle-skip
  target is past the M-cycle's end.

### The dispatch pushes in its fourth and fifth M-cycles
- Default: `DISPATCH_PUSH_MCYCLE = 4` (`cpu.nim`, `dispatch_interrupt`).
- Claim: Pan Docs, "Interrupt Handling": two wait M-cycles, two pushes, the
  jump, five M-cycles in all. Counted from the instruction boundary the
  interrupt is taken on, PC's high and low bytes are written in the fourth
  and fifth of the five, which is where the test below finds them, and the
  handler's first opcode fetch follows the fifth. The vector is chosen
  between the two writes (mooneye `acceptance/interrupts/ie_push`).
- Evidence: gambatte `oamdma/oamdma_src0000_busyint0002` (both devices)
  starts an OAM DMA from $0000, burns 154 M-cycles, and takes a timer
  interrupt with SP = $0002, so the two pushes go to the cartridge bus the
  transfer is on and the CPU's bytes land in OAM where the transfer stands
  (section 6). The handler reads $FE9E = $FF and $FE9F = $94, PC's two
  bytes in the transfer's last two slots: M-cycles 160 and 161 after the
  FF46 write, the fourth and fifth of the dispatch. Pushes in the third and
  fourth read $94 $87; in the second and third (or first and second, as the
  tree stood) $76 $87. gambatte `irq_precedence/late_m0irq_vs_tima_scx{2,3}
  {,_halt}_1` (both devices, eight tests) come with it: which of a mode-0
  STAT request and a timer request rising during the dispatch is taken
  depends on where "between the pushes" is.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### The dispatch clears IF inside its fifth M-cycle
- Default: `IRQ_SAMPLE_T = 18`, `IRQ_SAMPLE_T_DS = 18` (`cpu.nim`): T-cycles
  from the dispatch's first; 2 T (one dot at double speed) into the M-cycle
  that writes PC's low byte (`mem_write_head`, `memory.nim`).
- Claim: the taken line's IF bit is cleared part-way through the last
  M-cycle. A PPU request rising on a dot before the clear is lost with it;
  one rising after survives. The timer and the serial port are on the CPU's
  clock and raise their requests where two M-cycles meet, T 16, 20, 24 of
  the dispatch: the clear at 18 takes the T 16 one and leaves T 20.
- Evidence: gambatte `*_late_retrigger` (six STAT sources and the timer):
  the handler's IF re-request moves one M-cycle per member and the second
  dispatch's read of IF says whether the clear beat the source's next rise.
  Single speed, both devices: 16 and 17 lose the `_2` arms of
  `irq_precedence/late_m0irq_retrigger`, `ly0/lycint152_lyc{0,153}irq`,
  `lyc153int_m2irq`, `m1/lycint143_m1irq` and `m1/lycint_vblankirq` (their
  sources rise on the second dot of an M-cycle); 19 loses
  `late_m0irq_retrigger_scx1_1`; 20 also `m2int_m2irq_late_retrigger_1`
  and, on a DMG, the timer and serial `_2` arms. `tima/
  tc00_irq_late_retrigger_{1,2,3}` [dmg] (overflow reload on T 24, 20, 16:
  kept, kept, lost) and `serial/start_wait_trigger_int8_read_if_{1,2,3}`
  [dmg] (the eighth shift on T 24, 20, 16: the same) are the CPU-clocked
  pair. Double speed: 16 and 17 lose `irq_precedence/
  late_m0irq_retrigger_scx1_ds_2`, `serial/
  start_wait_trigger_int8_read_if_ds_2`, `tima/tc00_irq_late_retrigger_ds_2`
  [cgb]; 18 and 19 are one value (a dot is two T-cycles); 20 loses the seven
  `*_late_retrigger_ds_1` tests.
- A serial byte finished by the tap edge of the fifth M-cycle is on T 20,
  after the clear, although dingbat runs the bus half (and the edge) at the
  top of the M-cycle: the request is put back (`SERIAL_CPU_SAMPLE_T`'s
  ordering, applied to the clear).
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### A CGB clears a timer or serial request at the end of the dispatch
- Default: `IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD = 2` (`gb.nim`): T-cycles past
  `IRQ_SAMPLE_T` at which a CGB dispatch clears the TIMER or SERIAL line.
  `GbInterrupts.clear_line` / `clear_until`, `irq_clear_holds`
  (`interrupts.nim`), asked where the timer reload and the serial
  completion raise their request.
- Claim: on a CGB the clear of these two lines reaches T 20, the end of the
  dispatch, so the request the unit raises on that boundary is lost with
  the one being served; the LCD lines keep T 18 on both devices.
- Evidence: gambatte `tima/tc00_irq_late_retrigger_2` reads IF $E4 on a DMG
  and $E0 on a CGB, `_1` $E4 and `_3` $E0 on both; `serial/
  start_wait_trigger_int8_read_if_2` $E8 / $E0 likewise, and the `_ds_`
  pairs agree. 0 and 1 lose the four CGB `_2` / `_ds_2` tests; 2..5 are one
  value (the clear past T 20, short of T 24); 6 loses the four `_1` /
  `_ds_1` tests.
- Not serialized: the clear is held for one M-cycle past the dispatch
  and `step_frame` runs an instruction past a frame edge that would cut it.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### The comparator's LY steps two dots before the line boundary
- Default: `STAT_LYC_LY_LEAD_DOTS = 2`, `STAT_LYC_LY_LEAD_DS = 0`,
  `STAT_M1_LEAD = 1`, `VBLANK_IRQ_LEAD = 1` (`gb.nim`),
  `STAT_M2_LY0_LEAD = 1` (`ppu.nim`), `LYC_STEPPED_VBLANK_SHUT = 1`
  (`gb.nim`); `fifo_lyc_ly_lead` (`fifo_ppu.nim`). Below, S names the dot
  the comparator's LY steps on (the line end less the lead: 454 at single
  speed, the boundary at double).
- Claim: at single speed the LY the LY = LYC comparator sees moves to the
  next line on dot 454, half a CPU M-cycle before the readable LY and the
  mode flag. Three other things ride that dot rather than the boundary: at
  the end of line 143 the mode-1 STAT source and the vblank request, and at
  the end of line 153 line 0's OAM pulse. At double speed all of them are
  on the boundary.
- Evidence for 2: every source's `*_late_retrigger_{1,2}` pair (the handler
  re-requests itself one M-cycle later per member; the second dispatch's IF
  clear, `IRQ_SAMPLE_T`, falls either side of the source's next rise), the
  `lcd_offset` families (a KEY1 round trip puts the CPU on each of the four
  dot phases, so an interrupt-driven read brackets the source's dot from
  both sides), and the CGB LYC-write model below, whose sample grid sits on
  S and whose quiet window (`ff45_enable_weirdpoint`, writes from 449..452)
  is one grid period ending on 454. 1 loses 54 tests, 3 loses 36 (lists at
  the constant); `STAT_LYC_LY_LEAD_DS` 1, 2, 3, 4 lose 70, 288, 102, 97.
- `STAT_M1_LEAD` 0 loses ten tests (`m1/lycint143_m1irq_late_retrigger_2` on
  both devices, `m1/m1irq_m0disable_{2,3}`, `m1irq_m2disable_lycdisable_
  {2,3}`, `m1irq_m2enable_lyc_1`, `m2m1irq_ifw_2`, `lcdirq_precedence/
  m1irq_lcdstat18`, `lcd_offset/offset2_lyc8fint_m1irq_2` [cgb]).
  `VBLANK_IRQ_LEAD` 0 loses nine (`m1/lycint_vblankirq_late_retrigger_2` on
  both devices, `lcd_offset/offset{1,2}_lyc99int_m2irq_count_2`,
  `offset2_lyc8fint_m1irq_2` [cgb], DocBoy `double_speed/interrupts/
  single_speed_interrupt_vblank_c`, `_c_halted_round1`, `_d_halted_round1`,
  `speed_switch_to_single_interrupt_vblank_c_round1`). `STAT_M2_LY0_LEAD` 0
  loses eight (`lyc153int_m2irq/lyc153int_m2irq_late_retrigger_2` on both
  devices, `m1/m1irq_late_enable_2`, `m2enable/late_enable_m1disable_ly0_2`,
  `late_m1disable_ly0_2`, `lyc0_late_m2enable_lycdisable_2`, `lcd_offset/
  offset{1,2}_lyc99int_m2irq_count_2` [cgb]).
- A vblank line's boundary leaves a stepped comparator alone
  (`LYC_STEPPED_VBLANK_SHUT`): between two vblank lines nothing happens on
  the boundary (the mode does not change), and the comparator's answer for
  the new line has been on the STAT line since S. Opening the boundary's
  blind window as well (`ly_advance_vblank`) drops and re-raises the match
  two dots after it rose. gambatte `ly0/lycint152_lyc153irq_late_retrigger_
  {1,2}` (both devices): `_2` dispatches from dot 437 of line 152, clears IF
  on 455, one dot after the LYC = 153 match rose, and reads IF clear; with
  the window it reads the second request. Off loses `_2` on both devices.
  A rendered line's boundary keeps its window: the OAM pulse sits inside it
  (`ly_advance_line`).
- The DMG's LYC write against S: `LYC_DROP_LATENCY_DMG = 1` (the comparator
  sees a new LYC one dot into the write's M-cycle; gambatte `m0enable/
  lycdisable_ff45_*` [dmg]: 0 loses `lycdisable_ff45_scx3_3`, 2 loses
  `lycdisable_ff45_3`, 3 and 4 more) and `LYC_DROP_BOUNDARY_SKIP = 1` (a
  write from dot 453 lands on S, where the comparator's LY steps too: a
  match moved from the line ending to the line starting is one level;
  0 loses `lycEnable/ff45_enable_weirdpoint_3` and
  `lyc153_late_ff45_enable_3` [dmg]). When the LYC replaced did not match
  the line ending there is no level to carry, and the line start is the
  ordinary one with its blind window (`LYC_PARK_OPEN_DMG = 1`): gambatte
  `miscmstatirq/lycwirq_trigger_m0_late_ly44_lyc45_4` [dmg] (STAT $48, the
  line held by the mode-0 source, LYC written to the next line from dot
  453) requests, the mode-0 source falling before the new match answers.
  Off loses that test; opening the window for every parked LYC write loses
  `ff45_enable_weirdpoint_3` [dmg]. The CGB's side of the same statement is
  `CGB_LYC_BRIDGE`, below.
- Tests other rules answer once the LYC interrupt is taken from S: gambatte
  `vram_m3/preread_lcdoffset1_2` and `prewrite_lcdoffset1_2` [cgb] touch
  VRAM in an M-cycle that begins on mode 3's first dot and find the lock
  shut (section 1, "On a CGB the VRAM lock is shut for an M-cycle that
  starts on mode 3's first dot"); `cgbpal_m3/
  cgbpal_read_m3start_lcdoffset1_1` reads the palette there (`CRAM_LOCK_ON_
  LAT`, below); `window/late_enable_afterVblank_lcdoffset1_1` and `window/
  arg/late_wy_1toFF_lcdoffset1_1` [cgb] are the window comparator's cut-off
  on S and its per-line sample (section 2, "The window's WY comparator:
  when it samples"). With the lead at 0 the dispatch was one M-cycle late
  and each of them read the far side of its edge.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### CGB LYC write: a sampled comparator
- Default: `CGB_LYC_CMP_LATCH = true`, `CGB_LYC_LAND_T = 2`,
  `CGB_LYC_LATCH_PHASE = 0`, `CGB_LYC_BRIDGE = 1` (`gb.nim`); `GB.lyc_sampled`,
  `lyc_sample_write` / `lyc_sample_land` / `lyc_sample_settle` (`ppu.nim`),
  `fifo_tick_lyc_land` (`fifo_ppu.nim`).
- Claim: on a CGB the LY = LYC STAT source does not read the LYC register
  the CPU reads back. (1) A write reaches the comparator's input half a CPU
  M-cycle after the top of the write's M-cycle: 2 dots at single speed, 1 at
  double. (2) The comparator's answer reaches the STAT line only on a 4-dot
  grid of the PPU's own clock, the grid its LY step is on (S at single
  speed, `STAT_LYC_LY_LEAD_DOTS`; at double speed the dot
  `STAT_LYC_LY_LEAD_DS` gives). So the line moves, up or down, on
  the first grid dot at or after the landing: 2..5 dots after the top of
  the write's M-cycle at single speed (5 on the power-on CPU grid, 2 on the
  grid a KEY1 round trip leaves), 1..4 at double. (3) The sample is one
  event with whatever else the PPU does on its dot: a mode source rising or
  falling there, or the comparator's own LY changing (the step before the
  boundary, line 153's snap to 0), meets the new LYC, and the line sees one
  change, not two. (4) A write whose sample is the LY step itself, moving a
  match on the line ending onto the line starting, changes nothing in the
  comparator's answer, so the line stays high through the step: at single
  speed the line end's second step (the comparator letting go of the old
  line's match, `fifo_cgb_line_end`, the STAT-write entries below) has
  nothing to let go of, and at either speed the line boundary's comparator
  window (`ly_advance_open`) stays shut for it; if the old LYC did not match the line ending, the window
  opens as on any line and a mode-0 source hands the line to the new match
  with an edge. The readable register and STAT bit 2 keep their own timing
  (`CGB_LYC_WRITE_DEFER`, `CGB_LYC_EDGE_DEFER`).
- Evidence, single speed (W = the first dot of the write's M-cycle; every
  row is gambatte, [cgb]):
  - `lycEnable/ff45_enable_weirdpoint_{1,2,3,4}` and `_lcdoffset1_{1,2,3}`
    hold LYC = LY = 5 and write LYC = 6 around the 5 -> 6 boundary. W = 445
    and 448 request (the old match drops on the sample before the step, the
    new one rises at S), W = 449 and 452 do not (both inputs move under
    the sample at S), W = 453, 456 and 457 request again (the line is low
    from S until the next sample finds the new LYC). The quiet window is
    exactly one grid period, W in 449..452, across both CPU grids, so the
    grid is the PPU's and not the CPU's.
  - `lycEnable/late_ff45_enable_{1,2,3}` and `_lcdoffset1_{1,2}` turn a match
    on late in the matching line: W = 445 and 448 request, 449, 452 and 453
    do not (the first sample that holds the new LYC is the one LY leaves on).
  - `lycEnable/lyc153_late_ff45_enable_{1..5}` and `_lcdoffset1_{1,2}` do the
    same across 152 -> 153, where the comparator's LY is 153 for two
    samples only (S and the next; it is 0 from the snap's sample): W = 445
    requests, 449 is the carried match, 453 and 456 request (the sample
    after S), dot 1, dot 4 and dot 5 do not (their sample is the snap's
    own).
  - `lycEnable/lyc0_ff45_disable_{1,2,3}` take LYC = 0 away around the snap:
    W = dot 1 is quiet (sampled together with the snap), dots 5 and 9
    request.
  - `m0enable/lycdisable_ff45_{1..4}` and `_scx{1,2,3}_{1,2,3}` break a
    match ahead of the mode-0 rise at dot 250 + SCX: W = 241 (sample 246)
    and W = 245 with the rise on 251..253 (sample 250) dip and request;
    W = 245 with the rise on 250 itself does not (one event), nor does
    W = 249 (sample 254).
  - `lycEnable/lycwirq_trigger_ly00_stat50_{1,2,3}` and `_lcdoffset1_{1,2}`
    (mode-1 source up through line 153, LYC 255 -> 0): W = 449 and 452 are
    quiet (LYC is up at S, before mode 1 lets go at the boundary), 453,
    456 and dot 1 request.
  - `miscmstatirq/lycwirq_trigger_m0_late_ly44_lyc45_{1..5}`: the old LYC
    did not match the line ending, so every position requests, W = 449
    (sample on the step) included: the bridge is for a carried match only.
- Evidence, double speed (the grid is on the boundary's phase, the landing
  one dot in): `ff45_enable_weirdpoint_ds_{1..4}` and
  `_ds_lcdoffset1_{1..4}` are quiet for W = 452..455 and request at 450,
  451, 456 and dot 1, again one grid period over both CPU grids;
  `late_ff45_enable_ds_{1,2}`, `_ds_lcdoffset1_{1,2}` request at 450 and
  451 and not at 452 and 453; `lyc153_late_ff45_enable_ds_{1..6}` and
  `_ds_lcdoffset1_{1,2}`; `lyc0_ff45_disable_ds_{1,2}`;
  `m0enable/lycdisable_ff45_ds_1`, `_scx1_ds_{1,2}`;
  `lycwirq_trigger_ly00_stat50_ds_{1,2}`, `_ds_lcdoffset1_{1,2}` (W = 454
  and 455 land on the boundary's sample with the mode-1 source's fall: one
  event, quiet; 456 and dot 1 request); `miscmstatirq/
  lycwirq_trigger_m0_late_ly44_lyc45_ds_{1..4}`.
- Brackets (gambatte hex rows, 4,302 scored, all green with the STAT-write
  half below; the same counts and the same rows before and after the two
  were combined):
  `CGB_LYC_LAND_T` 0 or 1 loses 22 (the single-speed `_2` arms of nearly
  every family above and the `ds_lcdoffset1` arms), 3 loses 5 (the
  single-speed `lcdoffset1` arms: `ff45_enable_weirdpoint_lcdoffset1_{1,2}`,
  `late_ff45_enable_lcdoffset1_1`, `lyc153_late_ff45_enable_lcdoffset1_1`,
  `lycwirq_trigger_ly00_stat50_lcdoffset1_1`), 4 loses 20 (those and the
  `_ds_` arms). `CGB_LYC_LATCH_PHASE` 1, 2, 3 lose 29, 28, 26.
  `CGB_LYC_BRIDGE` 0 loses 8 (the six quiet `ff45_enable_weirdpoint` arms,
  `lyc153_late_ff45_enable_ds_{2,3}`); 2 (shut for any write on the step's
  sample) loses `lycwirq_trigger_m0_late_ly44_lyc45_{3,ds_2,ds_3}`.
  Sampling ahead of the dot's own events loses `m0enable/lycdisable_ff45_2`;
  sampling after them, with the line evaluated in between, loses
  `lyc0_ff45_disable_{1,ds_1}`. `CGB_LYC_CMP_LATCH = false` loses the
  twelve rows below and nothing else.
- With the STAT-write half's ordered line end (below), the carried match
  is one more row's worth of evidence: without the exception in step 2 the
  match is dropped and re-raised inside dot S and
  `lycEnable/ff45_enable_weirdpoint_2` [cgb] (W = 449) requests, the only
  row red in the two halves' combination. (`_lcdoffset1_2`, W = 452, is
  the same case and the same exception.)
- Rows taken (12, nothing lost anywhere in `tests/results*.md`):
  `lycEnable/ff45_enable_weirdpoint_{2, ds_2, ds_lcdoffset1_2,
  ds_lcdoffset1_3, ds_lcdoffset1_4, lcdoffset1_2}`,
  `late_ff45_enable_{ds_2, ds_lcdoffset1_2}`,
  `lyc153_late_ff45_enable_{ds_2, lcdoffset1_1}`,
  `lycwirq_trigger_ly00_stat50_ds_lcdoffset1_2`,
  `miscmstatirq/lycwirq_trigger_m0_late_ly44_lyc45_ds_3`.
- Supersedes, on the CGB's STAT line only, the line half of
  `CGB_LYC_EDGE_DEFER` (the rise is the sample's; its event still times the
  readable bit for wilbertpol `ly_lyc*_write-C`).
- Not serialized: the write is in flight for at most five dots, and
  `step_frame` runs an instruction past a frame edge that would cut one.
- Cost: the landing is dot-exact, so every tick has to know a write is in
  flight. As a compare of its own on the PPU's fast paths that was
  +0.30..0.53% of retired instructions on five GBC games (1800 frames, min
  of 4, against `CGB_LYC_CMP_LATCH = false`); folded into two stops those
  paths already test (`LYC_STOP_FOLDED`, fifo_ppu.nim: the window check's
  dot slot for the idle skip, `lazy_end` for a deferred mode 3) it is
  -0.07..+0.16%, run-to-run noise being about 0.1%.
  `-d:LYC_STOP_FOLD=false` is the explicit compare, the same machine frame
  for frame.
- The grid is anchored to the dot the comparator's LY steps on
  (`STAT_LYC_LY_LEAD_DOTS = 2`, `STAT_LYC_LY_LEAD_DS = 0`, re-fitted
  2026-11-13: "The comparator's LY steps two dots before the line
  boundary"). The DMG's LYC write keeps its own form
  (`LYC_DROP_LATENCY_DMG`, `LYC_DROP_BOUNDARY_SKIP`, `LYC_PARK_OPEN_DMG`).
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted. (Every figure above is a gambatte
  test ROM's own filename verdict against dingbat's trace of the write's
  dot; no other emulator was run.)

### CGB STAT/LYC write timing
- The rules that stood here were removed on 2026-11-12 (070a5637) and
  re-derived clean-room the same day, in two halves: the LYC-write (FF45)
  half is "CGB LYC write: a sampled comparator" above, the STAT-write
  (FF41) half the five entries below. Where the halves meet (an LYC write
  sampled on the dot the line end's five steps run on) is the carried
  match, item (4) of the entry above. gambatte is 5213/5213 with both.

### A CGB STAT write across a line's end: what its enables find (single speed)
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted. (No other emulator was run: every figure
  below is a gambatte hwtests row's expected value, read off the ROM's name
  and its `.asm`, against dingbat's own `-d:gb_stat_read_trace` output.)
- Method: each family is one STAT write stepped a CPU M-cycle at a time
  across the end of a line, and the `_lcdoffsetN_` rows (a KEY1 round trip
  first) put the same write on the dots in between. With `w` the dot the
  write's M-cycle starts on, the CGB at single speed answers:

  | write (old -> new) | at the end of | interrupt for `w` <= | none for `w` >= | rows [cgb] |
  |---|---|---|---|---|
  | $00 -> $08, mode 0 enabled late | a rendered line | 452 | 453 | `m0enable/late_enable_{1,2}`, `_lcdoffset1_{1,2}` |
  | $00 -> $08 | line 143 | 449 | 453 | `m1/ly143_late_m0enable_{1,2}` |
  | $00 -> $40, LY = LYC | a rendered line | 452 | 453 | `lycEnable/late_ff41_enable_{1,2}`, `_lcdoffset1_{1,2}` |
  | $00 -> $20 | a rendered line / line 153 | 454 | 455 | `m2enable/late_enable_{1,2}`, `_lcdoffset{2,3}_{1,2}`, `late_enable_ly0_{1,2}`, `_ly0_lcdoffset2_{1,2}` |
  | $00 -> $20 | line 143 | 449 | 453 | `m1/ly143_late_m2enable_{1,2}` |
  | $48 -> $00, LYC = next line | a rendered line | (none: 449) | fires from 453 | `lycEnable/ff41_disable_{1,2,3}` |
  | $08 -> $20 | a rendered line | 453 | 457 | `m2enable/late_enable_m0disable_{1,2,3}` |
  | $10 -> $50, LYC = 0 | line 153 | fires from 454 | (none: 453) | `miscmstatirq/lycstatwirq_trigger_ly00_10_50_{1,2}`, `_lcdoffset3_{1,2}` |

- Claim: the enables take hold `CGB_STAT_ENABLE_LATENCY` (2) dots after `w`,
  as before, and inside dot S -- the comparator's lead dot -- the CGB's
  sources change in a fixed order, the edge detector seeing each step:
  (1) enables landing on S take hold; (2) the comparator lets go of the
  line's match (and, with `STAT_M1_LEAD`, on line 143 the mode-1 source
  rises); (3) the mode-0 source falls; (4) the comparator answers for the
  next line; (5) line 143's OAM pulse ends. Mode 0 therefore ends at S on a
  CGB, where a later landing no longer finds it and the DMG (whose write
  acts on its own dot) still does; a mode-0-to-LYC hand-over is an edge (3
  before 4) that enables about to be cleared still see.
- Evidence, two-sided per step (each "moved" build loses exactly the rows
  named): no step 1, `lycEnable/late_ff41_enable_lcdoffset1_1`; step 1 for
  LYC writes too, `late_ff45_enable_2` and `lyc0_late_ff45_enable_2`; step 3
  ahead of 2, `lcdirq_precedence/m1irq_lcdstat18` and
  `m1/m1irq_m0disable_{2,3}`; 3 and 4 swapped, `lycEnable/ff41_disable_2`;
  step 5 with step 3, `lcdirq_precedence/lcdirqprecedence_lycirq_ly90_
  lcdstat68`. The whole rule off loses seven rows (listed at the constant).
- With the hand-over done on S, the 143 -> 144 boundary has no comparator
  dip left for a CGB at single speed (`ly_advance_vblank_entry`).
- Site: `CGB_LINE_END_STEPS` (gb.nim), `fifo_cgb_line_end` (fifo_ppu.nim),
  `m0_source`, `m2_line144` (ppu.nim).

### The CGB's OAM pulse is narrower for a landing enable
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.
- Claim: a CGB STAT write that sets the mode-2 enable is looked at again when
  its M-cycle ends, and finds the OAM source still high through dot 2 of the
  line at single speed (the DMG's `STAT_M2_PULSE` is 3, and double speed
  keeps 3). The vblank-entry pulse is shorter again: over inside line 143 at
  single speed (step 5 above) and high through dot 1 of line 144 at double.
- Evidence: `m2enable/late_enable_lcdoffset2_2` and
  `late_enable_ly0_lcdoffset2_2` [cgb] write from dot 455 (M-cycle ending on
  dot 3) and are silent; `_lcdoffset3_1` writes from 454 and fires.
  `CGB_M2_PULSE_SS`: 3 loses the first two, -1 loses seven, 0..2 are
  indistinguishable (2 ships, the nearest to the DMG). Double speed,
  `m1/ly143_late_m2enable_ds_{1,2}` and `_ds_lcdoffset1_{1,2}`: writes from
  454 and 455 fire, 456 and 457 do not. `CGB_M2_144_PULSE_DS`: 2 loses
  `_ds_lcdoffset1_2`, -1 loses four, 0 and 1 are indistinguishable.
- Site: `CGB_M2_PULSE_SS`, `CGB_M2_144_PULSE_DS` (gb.nim), `m2_pulse_last`,
  `m2_144_within_pulse` (ppu.nim).

### Line 153 -> 0: the mode-1 source falls ahead of a landing enable
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.
- Claim: at single speed the mode-1 source's fall where line 0 starts comes
  before STAT enables landing on that same dot (a write from dot 454); at
  double speed the landing is first.
- Evidence: last row of the table above. `CGB_M1_FALL_FIRST = false` loses
  `miscmstatirq/lycstatwirq_trigger_ly00_10_50_lcdoffset3_2` [cgb] and takes
  nothing; the double-speed pair (`_ds_1` from dot 455 silent, `_ds_2` from
  457 fires, `_ds_lcdoffset1_{1,2}` from 454/456) passes with the landing
  first.
- Site: `CGB_M1_FALL_FIRST` (gb.nim), `STAT_LAND_AFTER` in
  `stat_enables_leading` / `stat_drop_settle` (ppu.nim).

### Double speed: mode 0 falls, the enables land, the comparator lets go
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.
- Claim: at double speed the three share the boundary dot (456) of a rendered
  line in that order, for a STAT write from dot 455 (latency 1). Line 143 is
  the exception: there mode 0 outlasts the landing.
- Evidence: `lycEnable/late_ff41_enable_ds_1` [cgb] ($00 -> $40 from 455:
  the old line's match is still found; `_ds_2` from 457 is not),
  `miscmstatirq/lycstatwirq_trigger_m0_late_ly44_lyc44_08_40_ds_3` [cgb]
  ($08 -> $40 from 455 fires: mode 0 fell before the match was enabled;
  `_ds_2` from 453 and `_ds_4` from 457 are silent), with
  `m0enable/late_enable_ds_2` (mode 0 enabled from 455: silent) for the
  first half. `CGB_M0_FALL_DS_FIRST = false` loses the first two. On line
  143 `m1/ly143_late_m0enable_ds_1` (from 455) fires, and applying the order
  there loses `m1/lyc143_late_m0enable_lycdisable_ds_1`.
- Site: `CGB_M0_FALL_DS_FIRST` (gb.nim), the mode-0 line boundary in
  `fifo_tick_slow` (fifo_ppu.nim).

### The 153 match outlasts the snapback for a landing STAT enable
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.
- Claim: LY reads 0 from dot 5 of line 153 and nothing else sees the
  LYC = 153 match past it, but a CGB STAT write that sets the LYC enable
  still finds it until the dot the source relatches for LY = 0
  (`lyc_src_relatch_dot`), inclusive.
- Evidence: gambatte `lycEnable/lyc153_late_ff41_enable_*` [cgb], writes
  from dot 1 and 4 (single speed) and 6 and 7 (double) get the interrupt;
  from 5 and 8 (single), 8 and 9 (double) they do not. Off loses
  `_lcdoffset1_1`, `_ds_1`, `_ds_lcdoffset1_1`; `CGB_LYC153_HOLD_PAST = -1`
  loses the same three. Restricted to STAT writes: the LYC-write twins
  (`lyc153_late_ff45_enable_4`, `_ds_6`, `_ds_lcdoffset1_2`) go red if any
  evaluation sees the held match.
- Site: `CGB_LYC153_SRC_HOLD`, `CGB_LYC153_HOLD_PAST` (gb.nim),
  `lyc153_src_held` (ppu.nim), `mem_flush_deferred` (memory.nim),
  `fifo_line153_edge` (fifo_ppu.nim).

### An IF write replaces the register on its M-cycle's second dot
- Default: `IF_WRITE_LAND_DOTS = 1`, `IF_WRITE_LAND_DOTS_DS = 1`
  (`memory.nim`); `LYC_SRC_RELATCH_ADJ = 1` (`ppu.nim`).
- Claim: a CPU write to IF replaces the register one dot after the top of
  its M-cycle, at either speed: a request the PPU raises on the M-cycle's
  first dot is overwritten, one raised on its second survives. Line 153's
  LY = LYC source answers for LY = 0 one dot later than the M-cycle-early
  figure (`LYC_SRC_RELATCH_LEAD`): dot 6 at single speed, dot 8 at double.
  The two are fitted together because the `_ifw_` tests that clear IF across
  the LYC = 0 relatch read one against the other.
- Evidence, `IF_WRITE_LAND_DOTS`: 0 loses gambatte `m2int_m0irq/
  m2int_m0irq_scx3_ifw_{2,4}` (both devices) and DocBoy `dmg/interrupts/
  hblank_stat_interrupt_reset_if_scx3_round2`, `_scx7_round3` (IF cleared
  on the dot the mode-0 source rises: hardware reads it back clear); 2
  loses 21 (`ly0/lycint152_lyc{0,153}irq_ifw_1`, `lyc153int_m2irq_ifw_1`,
  `m1/lycint143_m1irq_ifw_1`, `m2int_m0irq_scx4_ifw_{1,3}` on both devices,
  DocBoy `hblank_stat_interrupt_reset_if_scx0_round1`, `_scx4_round2`,
  `vblank_interrupt_reset_if_round2` among them); 3 and 4 lose 23.
  `_DS`: 0 loses `m2int_m0irq_scx3_ifw_ds_2` [cgb]; 2 loses eight
  `*_ifw_ds_1` tests.
- Evidence, `LYC_SRC_RELATCH_ADJ`: 0 loses ten tests (`ly0/
  lycint152_lyc0irq_ifw_1` on both devices, `lycEnable/lyc0_ff45_disable_1`,
  `lyc0_ff41_disable_ds_1`, `lyc0_m1disable_ds_1`, `lyc153_late_ff41_enable_
  {ds_1,lcdoffset1_1}` [cgb] among them), -1 and -2 fourteen; 2 loses nine
  (`ly0/lycint152_lyc0irq_late_retrigger_2` on both devices, `lycEnable/
  lyc0_ff41_disable_2`, `lyc0_m1disable_2`, `lyc153_late_ff41_enable_2`,
  `lyc0int_m0irq/lyc0int_m0irq_ds_1` [cgb] among them).
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### Double speed: the mode-0 source, the line-144 pulse, the LCD-on line
- Default: `STAT_M0_LEAD_DS = 0`, `CGB_M0_HALT_BLIND_DS_DOTS = 0`,
  `M2_144_EARLY_DOT_DS = 454`, `STAT_READ_M23_LEAD_DS = 1`,
  `LYC_JUST_CHANGED_HOLD_DS = 2`, `LYC153_HOLD_DS = 1` (`ppu.nim`);
  `IRQ_SAMPLE_T_DS = 18` (`cpu.nim`); `LCDON_M0_LAG_DS = 8`,
  `IF_READ_M2_144_TIE_DS = 0` (`gb.nim`).
- Claims, each bracketed on both sides at the constant with the others at
  their defaults:
  - The mode-0 STAT source rises with the mode flag (no lead), and a halted
    CGB sees it in the M-cycle it rises in. DocBoy `double_speed/interrupts/
    double_speed_interrupt_stat_{a,b}_scx{0..3}` and their `_halted_` and
    `speed_switch_to_double_` twins, `double_speed/ppu/
    double_speed_ppu_hblank_if_{a,b}_scx{1,3}_round1`: a lead of 1 dot loses
    30 tests (the odd SCX), 2 loses 64; blindness 1 loses
    `double_speed_interrupt_stat_halted_{a,b}_scx{0,2}_round1` and gambatte
    `halt/m0int_m0stat_scx2_ds_1`, `halt/m0irq_m0stat_scx2_ds_1`.
  - The dispatch clears IF one dot into its fifth M-cycle, as at single
    speed (entry above).
  - The line-144 OAM pulse rises one CPU M-cycle before line 143 ends, dot
    454, as every other line's pulse does: 452 loses five tests
    (`enable_display/frame{0,1}_m2irq_count_ds_1`, `lcd_offset/
    offset1_lyc99int_m2irq_count_ds_1`, `m1/lyc143_late_m2enable_lycdisable_
    ds_1`, `m1/m2m1irq_ifw_ds_1`), 453 three, 455 `enable_display/
    frame{0,1}_m2irq_count_ds_2`. With the pulse there an IF read needs no
    tie rule (`IF_READ_M2_144_TIE_DS` 1 loses `offset1_lyc99int_m2irq_count_
    ds_1`).
  - On the LCD-on line the mode-0 source trails the flag by one M-cycle
    (2 dots): gambatte `enable_display/ly0_m0irq_scx{0,1}_ds_{1,2}`,
    `frame0_m0irq_count_scx{2,3}_ds_{1,2}`; 0..4 scheduler cycles lose the
    `_ds_1` tests, 9 and up the `_ds_2` tests, 5..8 are one M-cycle.
  - A STAT read sees modes 2 and 3 one dot sooner than the mode-0 edge's
    double-speed sample point gives: 0 loses DocBoy `double_speed_ppu_d3_
    {oam,px}_round2` and gambatte `lcd_offset/offset1_lyc99int_{m2stat,
    m3stat}_count_ds_2`; 2 loses 36.
  - A STAT read in the M-cycle LY stepped still shows the old line's
    coincidence while the dot counter is below 2: 0 and 1 lose
    `enable_display/frame{0,1}_m2stat_count_ds_1`, `ly0/
    lycint152_lyc0flag_ds_3`, `lycint_lycflag/lycint_lycflag_ds_3`; 3 and 4
    lose `lcd_offset/offset1_lyc8fint_m1stat_ds_1`. And CPU CGB C holds the
    LYC = 153 comparison through the snapback at double speed, as CGB D+ do
    at both (`ly0/lycint152_lyc153flag_ds_3` reads $C5).
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### STAT reads at vblank entry; the DMG STAT-write bug at the mode-0 edge
- Default: `STAT_READ_M1_LAG = 1` (`ppu.nim`), `STAT_GLITCH_M0_LEAD = 1`
  (`gb.nim`).
- Claim: at single speed a STAT read keeps showing mode 0 for one dot more
  into line 144 than the other mode edges' sample point gives. On a DMG the
  STAT-write bug's all-enabled phase finds the mode-0 source one dot after
  the source's own rise (which is `STAT_M0_LEAD_T` ahead of the flag).
- Evidence: DocBoy `cgb/double_speed/ppu/single_speed_ppu_s{0..5,1b..4b,x}_
  vblank_round{1,2}` (a KEY1 round trip leaves the CPU on each dot phase;
  STAT read one M-cycle apart across line 144's start) and gambatte
  `lcd_offset/offset{1,2,3}_lyc8fint_m1stat_{1,2}` [cgb]: 0 loses
  `single_speed_ppu_{s3,s3b,s4b,sx}_vblank_round1` and
  `offset3_lyc8fint_m1stat_1`; 2 loses `single_speed_ppu_s5_vblank_round2`
  and `offset2_lyc8fint_m1stat_2`; 3 loses six, 4 twenty. The STAT-write
  bug: gambatte `miscmstatirq/m0statwirq_scx{2,5}_2` [dmg] and DocBoy
  `dmg/stat_write_bug/stat_write_bug_hblank_scx{1,2,5,6}_round2`: 0, 3 and
  4 lose all six, 2 loses three.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### A TAC write judges both taps where it ends; an SC write samples its tap where it starts
- Default: `TAC_SELECT_LEAD_T = 0` (`timer.nim`), `SERIAL_SC_WRITE_LEAD_T = 4`
  (`serial.nim`).
- Claim: a TAC write that changes the selected divider bit compares the old
  tap and the new one at the same instant, the end of the write's M-cycle
  (Pan Docs, "Timer Obscure Behaviour": the mux output's falling edge
  ticks TIMA). An SC write restarts the serial slot sequence from the tap's
  level at the top of its M-cycle, where a CPU write lands (the divider
  four counts back from where the bus half has left it).
- Evidence: gambatte `tima/tc00_late_tc01_{1..8}` (both devices): a lead of
  1, 2, 3 or 4 T loses `_5` and `_7` on both. Serial: 0 loses 28 tests
  (DocBoy `dmg/serial/serial_timing_{nops0,nops64,sb_bit0..7,
  change_sb_during_transfer_*,reset_div_during_transfer_*}`, `cgb/serial/
  serial_timing_high_speed_nops{0,2,32}_round2`, `double_speed/serial/
  double_speed_serial_high_speed_round2`, gambatte `serial/
  nopx1_start{,83}_wait_read_if_2`, `start83_late_div_write_wait_read_if_
  {1b,2b}`); 1..4 are one value; 5 and up lose 12.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  runs; no emulator source consulted.

### The window's WY comparator sample after a CGB write
- See §2, "The window's WY comparator: when it samples".

### The CGB palette RAM lock around the mode-3 edges
- Default: `CRAM_LOCK_DOTS = true`, `CRAM_LOCK_ON_LAT = 1`,
  `CRAM_LOCK_ON_LAT_DS = 2`, `CRAM_LOCK_OFF_LAT = 2`,
  `CRAM_LOCK_OFF_LAT_DS = 3`, `CRAM_LOCK_LINE0_EXTRA = 2`,
  `CRAM_LOCK_LINE0_EXTRA_DS = -1` (the single-speed value) (`ppu.nim`,
  `cpu_cram_open_dots`).
- Rule: BCPD/OCPD are locked from the dot after the mode-3 edge (2 dots
  after it at double speed) until 2 dots after the mode-0 edge (3 at double speed), the VRAM
  read lock's own open edge (`VRAM_READ_M0_OPEN_DOTS{,_DS}`). A write asks
  at its commit, a read at the start of its M-cycle, so a read and a write in
  the same M-cycle get the same answer. On the line the LCD is switched on
  with the lock closes `LCD_ON_LINE0_LOCK_LEAD` = 2 dots later, as the VRAM
  and OAM locks do.
- Evidence, the open edge: gambatte `cgbpal_m3/cgbpal_m3end_*` write BCPD
  and read it back two M-cycles later, one M-cycle later per ROM, at SCX 0,
  2, 3, 5 and at double speed: out 7 (read locked), 0 (read open, write was
  locked), 0, 1 (both open). Single speed 2 is a strict optimum (1 loses
  `cgbpal_m3end_{1,3}`, 3 loses `cgbpal_m3end_scx3_{2,4}`); double speed 3
  is (2 loses `cgbpal_m3end_scx5_ds_{1,3}`, 4 loses `cgbpal_m3end_ds_{2,4}`).
- Evidence, the close edge: `cgbpal_m3start_*`, `cgbpal_read_m3start_*`,
  `cgbpal_write_m3start_*`. Double speed 2 is a strict optimum (1 loses the
  three `_ds_1` tests, 3 loses `cgbpal_{read,write}_m3start_ds_lcdoffset1_2`).
  Single speed 1 is a strict optimum: 2 loses the three `_2` tests and
  `enable_display/ly1_late_cgbpw_2` (an
  M-cycle starting on dot 81 is locked) and 0 loses
  `cgbpal_read_m3start_lcdoffset1_1` (one starting on dot 80, mode 3's
  first, still reads the palette, where the VRAM lock is already shut:
  section 1).
- Evidence, the LCD-on line: `enable_display/ly0_late_cgbp{r,w}{,_ds}_{1,2}`.
  Single speed 1..4 pass on top of `CRAM_LOCK_ON_LAT = 1` (0 loses the
  `_1` pair, 5 the `_2` pair), double speed 2..3 (1 loses `_ds_1`, 4 loses
  `_ds_2`); 2 is the lead the other locks take on that line.
- With `CRAM_LOCK_DOTS = false` (the mode-based `CRAM_LOCK_R`/`CRAM_LOCK_W`)
  thirteen tests are lost: `cgbpal_m3end_{1,3}`, `_ds_{1,3}`, `_scx5_ds_{1,3}`,
  `cgbpal_m3start_ds_1`, `cgbpal_{read,write}_m3start_ds_1`,
  `ly0_late_cgbp{r,w}{,_ds}_2`.
- Clean-room: derived from test ROM sources/outputs and dingbat's own trace runs; no emulator source consulted.

### The interrupt check stays a leaf
- `handle_interrupts` runs after every instruction and almost never takes the
  branch; its taken half (`dispatch_interrupt`) is `{.noinline.}` so the
  always-inlined `mem_write`s do not give the leaf a prologue (~1 % of
  retired instructions).

## 8. Device model

### A DMG cart on CGB hardware is a third device
- Claim: `cgb_enabled` is the console (timing, the DMG STAT-write glitch, the
  OAM bus release in mode 2, the serial tap, the line-144 STAT lead);
  `cgb_native` is the mode (the CGB register map, BG map attributes, the OBJ
  palette/bank nibble, LCDC.0 as BG on/off vs master priority, X-ordered
  objects, BGP/OBP before palette 0). DMG-compatibility mode is CGB timing
  with a DMG picture. Pan Docs, "CGB Registers" and "Compatibility mode".
- Evidence: mooneye `misc/*` are DMG-header carts on CGB/AGB; gambatte
  `m2int_m3stat/nobg/*_cgb04c`; every mealybug cart is DMG-flagged, so its
  `_cgb_c`/`_cgb_d` references are compatibility-mode captures (only the six
  compat-palette colours appear in all 47).
- Skipping the boot ROM installs the fallback compatibility palette (the one
  the boot ROM uses for any cart without a Nintendo licensee); the per-title
  table is not reproduced.

### The CGB boot ROM leaves the logo map only for title checksums $43 and $58
- Site: `skip_boot` (`ppu.nim`), `nintendo_title_sum` (`timer.nim`, shared
  with the B and HL hand-off in `cpu.nim`).
- Claim: over a DMG cart with a Nintendo licensee and title checksum $43 or
  $58, the CGB/AGB boot ROM writes the DMG boot ROM's logo tile map ($9904-
  $990F, $9910, $9924-$992F); any other cart, and every CGB cart, gets no
  map. A two-value rule, not the palette table.
- Evidence: Pan Docs, "Power Up Sequence", Compatibility palettes ("If the ID
  is either $43 or $58, then the Nintendo logo's tilemap is written to VRAM")
  and [^cgbdmg_hl] (HL = $991A exactly when B, the title checksum, is
  $43/$58). DocBoy `cgb_dmg_mode/boot/boot_vram_nintendo_logo_checksum_
  {43,58}` compare $9900-$997F against that map; `_1a` against zeros.

### VBK is locked outside CGB mode; FF4F reads $FE
- Claim: VBK leaves the register map with the rest of the CGB set when KEY0 is
  set, so bank 1 is unwritable and the attribute plane is all zero by
  construction; the fetcher reads it unconditionally (a branch there cost
  +0.8 % on Pokemon Crystal).
- Evidence: mooneye `misc/bits/unused_hwio-C` reads $FE from FF4F.

### SVBK reads back the stored bits, not the mapped bank
- Default: `SVBK_READS_WRITTEN = true` (`memory.nim`); `GbMemory.svbk` beside
  `wram_bank`.
- Claim: `$FF70` is a 3-bit register. A read returns the three bits last
  stored with bits 3-7 set. Storing 0 maps bank 1 at `$D000` but the register
  still holds 0: the 0 -> 1 substitution is in the bank decode. The boot ROM
  stores nothing to it, so it hands off holding 0 and reads `$F8` with bank 1
  mapped. Outside CGB mode it reads `$FF` and ignores stores (unchanged).
- Evidence: DocBoy `cgb/boot/boot_regs_cgb` passes at `true` and fails at
  `false` (which reads `$F9`, the mapped bank). Hardware: gbedge p00 on an
  AGS reads SVBK = `$F8` after the boot ROM (docs/dev/flashcart-runbook.md), and
  p18 on the same console shows SVBK 0 and 1 mapping the same bank. Pan Docs,
  "FF70 - SVBK": bits 0-2 read/write, 0 selects bank 1.
- The save state's SVBK byte is written as the full readback (`$F8` | bits)
  and only its low three bits are loaded, and only where they agree with the
  mapped bank (a stored 0 over bank 1); anything else loads as the bank's own
  number, which is also what a state without the byte gets.
- Clean-room: derived from test ROM sources/outputs, Pan Docs and the tree's
  own hardware reads; no emulator source consulted.

### Game Boy Printer status
- Default: `PRN_STATUS_SEQUENCE = true`, `PRN_DONE_HOLD = true`,
  `PRN_INIT_REPLY_CLEAN = true` (`printer.nim`).
- Claim: the status byte follows Pan Docs' "Example" on the Game Boy Printer
  page. INIT replies `$00`. A DATA packet with a payload sets bit 3
  (unprocessed data), which the next packet's reply is the first to show
  (`$00`, then `$08`); the empty DATA leaves it. PRINT's own reply is still
  `$08`; from the next packet on the status is `$06` (bits 2 and 1) while the
  print runs, and `$04` when it ends. A packet's status byte is therefore the
  state before that packet took effect, except INIT's, which is already the
  cleared `$00` (Pan Docs: "the normal status replied should be `$00`").
  `$04` stays until INIT, BREAK or the next DATA with a payload. The 100 ms
  idle timeout resets the link and the graphics buffer (Pan Docs' wording),
  and bit 3 and the error bits with them, but it does not take `$04` away
  and never interrupts a running print (`PRN_DONE_HOLD`). A DATA with a
  payload that finds `$04` replies `$04` itself and leaves `$08`: the done
  bit goes with the new transfer, so no reply is `$0C`. A DATA during a
  running print keeps the `$06`.
- Evidence, Pan Docs: the example's byte sequence, bit names and the 100 ms
  timeout. `tests/gb_printer_test.nim` holds each step.
- Evidence, Game Boy Camera Gold (USA) run on dingbat as a black box (a
  scratch driver pressing through Shoot, View, Print and decoding
  `GbPrinter.log`): the game sends INIT, nine 640-byte DATA packets with a
  STATUS after each pair, the empty DATA, PRINT `01 13 E4 40`, then STATUS
  about every six frames.
  - Default: 180 polls read `$06` over the 1080 frames of a 144-row print,
    the "Printing..." screen stays up for all of them, the next poll reads
    `$04` and the game returns to its print menu. A second print straight
    after runs the same dialogue.
  - `PRN_STATUS_SEQUENCE=false` (status always `$00`): six polls, then the
    game is back at its menu half a second after PRINT with the paper still
    running. The same happens if PRINT sets bit 2 without bit 1, so the game
    waits on bit 1: it must rise within six polls and fall at the end.
  - Bit 3 after DATA, bit 2 during and after the print: the game runs the
    same with or without them. They rest on Pan Docs alone.
  - `PRN_DONE_HOLD=false` (the timeout returns the status to `$00`): the
    game's last poll reads `$00`, not `$04`. Its poll period is the length of
    the idle timeout, which then fires between the end of the print and the
    next poll.
- Evidence, reported game behaviour (not run here; the ROM was not
  available): Hello Kitty Pocket Camera sends PRINT again, indefinitely, if
  a poll after the print reads `$00` rather than done, and a camera game
  stays on its "transferring" screen if a DATA sent while `$04` is reported
  is answered `$0C`. `tests/gb_printer_test.nim` models both: a poller every
  10 frames reads `$06`, then `$04` for as long as it keeps asking (ten
  seconds of silence included) until INIT; DATA after done replies `$04`,
  `$08`, `$08`. With `PRN_DONE_HOLD=false` the slow-poller checks fail.
- `PRN_INIT_REPLY_CLEAN` rests on Pan Docs alone; no ROM here sends INIT
  within 100 ms of a finished print.
- Unchanged and still assumed: about 7.5 frames per printed row, only full
  640-byte bands are kept, PRINT does not require the empty DATA first.
- Clean-room: derived from Pan Docs and black-box runs of Game Boy Camera
  Gold on dingbat itself; no emulator source consulted.

### LCD-on frame push (frontend pacing)
- Default: `LCD_ON_FRAME_DOTS = 37392` (`ppu.nim`): an LCD enable more than
  that many dots after the last presented frame presents one at the enable.
- Hardware side: with the LCD off nothing refreshes; an enable restarts the
  PPU at line 0 wherever the old frame was, so its first vblank is 144 lines
  = 65664 dots away; the panel stays blank for that first frame (Pan Docs,
  LCDC.7). The picture is white from the enable to that vblank either way,
  so the pushed frame (a white one; on SGB the held one) shows nothing the
  panel would not. The threshold only decides when the frontend, which
  expects a frame every 70224 dots, gets one.
- Derivation: with d dots since the last present, waiting gives one interval
  of d + 65664 (long by d - 4560), pushing gives d (short by 70224 - d) and
  then 65664. The two errors are equal at d = (70224 + 4560) / 2 = 37392 =
  70224 - 65664 / 2 (82 lines). Push above it, wait below it, and no
  interval is further than 65664 / 2 = 32832 dots (72 lines) from a frame
  period; any other threshold has a worse worst case on one side.
- Evidence: `tests/gb_lcd_on_pacing_test.nim` (`nimble test_gblcdonpacing`)
  switches the LCD off at vblank and on again after 0 to 2 frames in steps
  of 1/64 frame, DMG and CGB, and measures every `step_frame` in dots. At
  37392: longest interval +32656, shortest -32248, all checks pass (37300
  to 37800 measure the same; the sweep's step is 1097 dots). 37000: shortest
  -33008, fails. 36000: -34100. 30000: -39892. 20000: -49720. 39000: longest
  +33748, fails. 45000: +40300. 60000: +55284. 0 (never push): +65416, a
  step of nearly two frames.
- `tests/savestate_compat_test.nim` reaches the LCD-on frame state (LY 0,
  mode 2 at a frame boundary) only when the constant is non-zero, and checks
  it loads and replays.
- Clean-room: derived from Pan Docs' LCDC description and dingbat's own
  runs; no emulator source consulted.

### Revision-dependent behaviour
- `docs/dev/gb-hardware-revisions.md`: the `GbRevision` → `GbQuirks` axis, its
  defaults (CGB C / DMG ABC) and the ROM behind each flag.

## 9. GBA

### The prefetcher surrenders the ROM bus at the in-flight halfword's last cycle
- Site: `Bus.pf_commit` bitmap, precomputed per page in `update_waitcnt`
  (`bus.nim`); the hot path is a shift and a test.
- Claim: GBATEK, "GBA System Control" (WAITCNT prefetch): opcode halfwords
  stream whenever the CPU executes from the gamepak and does not need the
  bus. A CPU data access to the gamepak stalls one cycle iff
  `elapsed mod s == s − 1`, i.e. the in-flight halfword is in its data
  phase; earlier it is abandoned. Not "wait for the whole fetch" (that
  predicts 2 for (1,3) and breaks `ldmia [#0x07FFFFFC] P..`). Bounded by the
  8-halfword buffer; only while fetching from the gamepak; never for fetches.
- Evidence: mGBA suite Timing: the `ldr r2,[#0x08000000]` pair and the twelve
  `ldmia [#0x07FFFFF*]` region-crossing rows, instrumented as
  (elapsed, s) → extra: (0,3)→0 (1,2)→1 (1,3)→0 (2,2)→0 (2,3)→1 (3,2)→1
  (3,3)→0.
- The DMA side counts the hand-off forward from the grant
  (`dma_grant_now`, `dma.nim`), which closes the Timing DMA rows; a channel
  that pre-empts another mid-burst pays nothing (AGS aging cartridge DMA
  priority test).

### DMA latches its word count at enable and reloads it on repeat
- Claim: GBATEK, "DMA Transfers": the internal registers are copied at enable;
  a later DMACNT_L write does not resize an armed burst. GBA payload rev 5.
- Evidence: mGBA suite Misc, fixture `mgba-emu/suite@fbe6156` (absent from the
  pinned v1.0 ROM; `tests/README.md`).

### IRQ entry costs 2, the return gives 1 back
- Site: `cpu.nim` (GBA); `HALT_RETURN_COST = 20` (`hle_bios.nim`).
- Claim: the ARM7TDMI data sheet charges exception entry 2S+1N and the
  `MOVS pc` return 2S+1N; the two pipeline refills are already charged, and
  the remaining two cycles split 2/1 rather than the old lopsided split plus
  ad-hoc halt-wake and back-to-back-return discounts.
- Evidence: mGBA suite Timer count-up (the poll loop is 8 cycles, so the
  round trip matters mod 8; hardware reproduces only at 121 or 125) and
  Timer IRQ (the handler's first instruction runs 4 cycles after the
  interrupted boundary; 3 fails 21 rows).
- Residual: under the real BIOS the four SIO timing rows read one cycle high
  — one instruction in that BIOS Halt path is modelled a cycle long.

### The H-blank IRQ rises with DISPSTAT bit 1 at cycle 1006
- Default: `HBLANK_IRQ_SYNC_DELAY = 6` (`ppu.nim`); `IRQ_SYNC_DELAY = 3`
  (`interrupts.nim`) stays the timers' figure.
- Claim: GBATEK, "LCD I/O Interrupts and Status": the flag is 0 for 1006
  cycles, so bit 1 rises 46 cycles into the 272-cycle gap, and the IRQ is
  that same condition. Peripherals do not share one path to the interrupt
  controller; the video controller's recognition delay is 6.
- Evidence: mGBA suite Misc "H-blank bit start / Flip 1" (under the ROM
  rebuilt with upstream's two fixture fixes, `tests/README.md`): the
  halt-wake was a flat 48 cycles late, invariant under any flag offset, and
  recognition anywhere in 1010..1014 passes. A +48 on the halt-wake path
  instead collapses Timer count-up 893 → 689.
- H-blank DMA stays at 960. Assumed; nothing in the suite distinguishes it.

## 10. Instruments

The trace builds (`-d:gb_m3_trace`, `gb_win_trace`, `gb_stat_read_trace`, …),
`DINGBAT_GAM_DUMP`, the readers (`objtab.py`, `famflip.py`, `windot.py`) and
the sweep scripts are catalogued in
[`tools/gbppu/README.md`](../../tools/gbppu/README.md); runner hazards (shared
`TMPDIR`, one binary pair per world) in [`tests/README.md`](../../tests/README.md),
"Exit code, baselines, hazards"; the retired-instruction A/B rules in
`docs/dev/gb_oam_dma_cost.md`.

## 11. GB APU: triggers against the clocks

Clean-room for every entry in this section: derived from test ROM sources and
outputs (gambatte `test/hwtests/sound`, `speedchange`; DocBoy's test-suite
sources; SameSuite `apu/`), Pan Docs, and dingbat's own trace runs; no emulator
source consulted, no other emulator run.

### A trigger with the envelope clock next gets one more clock
- Claim: a trigger while the frame sequencer's next step is 7 loads the
  envelope timer with the period plus one, so that step only brings it back to
  the period (Pan Docs, Audio Details, "Obscure Behavior": "If a channel is
  triggered when the DIV-APU next step will clock the volume envelope, the
  envelope's timer is reloaded with one greater than it would have been"). On
  the GB "next" is judged an M-cycle ahead: a trigger written in the M-cycle
  whose end is step 6's DIV-APU edge already finds step 7 next.
- Default: `psg_env_trigger_extra` (`common/psg_channels.nim`),
  `ENV_TRIGGER_LEAD_T = 4` scheduler cycles (`common/psg.nim`).
- Evidence: gambatte `sound/ch2_init_reset_env_counter_timing_{9..16}`
  trigger a volume-0, increasing, period-1 note and rewrite NR22 = $08 one
  M-cycle either side of an envelope clock; the mix is silent if the volume
  had not stepped. Trigger 8 cycles before step 6: the next step 7 steps it
  (`_9`/`_10` [dmg], `_13`/`_14` [cgb]). Trigger 4 cycles before step 6: the
  step 7 after that one does (`_11`/`_12` [dmg], `_15`/`_16` [cgb]). With
  step 7 next outright (`_13`..`_16` [dmg]) the first step 7 is skipped too.
  DocBoy `cgb/apu/ch2/ch2_volume_sweep_retrigger_divapu0_round{1,2}` (a
  retrigger 7 steps after the APU power-on: the volume moves 18384 M-cycles
  later, not 2048).
- Brackets: lead 4..7 pass; 0..3 lose `_11` [dmg] and `_15` [cgb]; 8 loses
  `_10` [dmg] and `_14` [cgb]. Without the rule `_11`, `_13`, `_14` [dmg],
  `_15` [cgb] and DocBoy's two fail.
- GBA: the shared PSG takes Pan Docs' rule without the lead. No GBA test sees
  the rule either way (dbsuite, mGBA suite, alyosha and hwverified are
  identical on every test with it and without); the lead is unmeasured there.
- Open: the lead at double speed (every test is single speed; the default
  counts CPU cycles, like the sweep's).

### A trigger just before a sweep clock misses it
- Claim: a channel 1 trigger within one M-cycle (DMG) or two (CGB) of a sweep
  clock (frame sequencer steps 2 and 6) does not have that clock count: the
  sweep timer runs one clock longer. The count is CPU cycles: two M-cycles at
  double speed as well.
- Default: `SWEEP_TRIGGER_LEAD_T_DMG = 4`, `SWEEP_TRIGGER_LEAD_T_CGB = 8`
  scheduler cycles (`common/psg.nim`, `psg_sweep_trigger_extra`).
- Evidence, DMG: gambatte `sound/ch1_init_reset_sweep_counter_timing_{1..6}`
  [dmg] (pace 2, step 0 at $700; the second clock's overflow check stops the
  note unless NR10 = 0 lands first): the clock 8 cycles after the trigger
  counts, the one 4 after does not. DocBoy `dmg/apu/ch1_period_sweep_change_
  period_nr14_during_recalc_delay14284` (8 before) and `_delay14285_round{1,2}`
  (4 before) agree. 0 loses `_4` [dmg] and `delay14285_round2`; 8 loses `_3`
  [dmg], `delay14284` and `step0_delay14284_round1`.
- Evidence, CGB: gambatte `_7`..`_12` [cgb]: 12 cycles after counts, 8 after
  does not. SameSuite `apu/channel_1/channel_1_sweep_restart_2` (CGB E
  hardware) passes at 8 and fails at 4 and 12. DocBoy `cgb/double_speed/apu/
  ch1/..._nr14_during_recalc_delay1224{1,2}_round2` and six `double_trigger_
  delay{0,1,2}_delay1224{3..6}_round1` tests need 8 scheduler cycles at
  double speed (4 passes half of them, 0 none), and `delay12240`,
  `step0_delay12240_round2` and three `double_trigger_*` tests fail at 12, so
  the lead is two M-cycles at double speed, not 8 T-cycles of real time.
- Open: DocBoy's single-speed CGB tests `cgb/apu/ch1/..._delay14284` and
  `..._step0_delay14284_round1` want 4 on the CGB and fail at 8 (scored,
  docs/dev/gb-failure-triage.md I2). They disagree with SameSuite (its apu
  README: CPU CGB E passes all tests) and gambatte's `[cgb]` rows, which are
  CGB C. `..._step0_delay14284_round1` is SameSuite's own subtest (same
  registers, 8 cycles before the clock, same 512 kHz phase, read 3 M-cycles
  on) before step 6 instead of step 2, with the opposite answer. A step-6
  gate (lead 4 before frame-sequencer step 6 at single speed) passes every
  GB row but has no mechanism or citation; not adopted. DocBoy's CGB rows
  all fit the DMG's one-tick lead at both speeds, which SameSuite and
  gambatte `_10` [cgb] refute at single speed.

### A sweep clock samples NR10 after its own M-cycle
- Claim: a CPU write to NR10 in the M-cycle of a channel 1 sweep clock
  reaches all of the clock: the calculation it starts (its step), the pace
  its timer reloads with, and its write-back, which a non-zero step given on
  a step-0 clock's M-cycle turns on (the adder's output, 0 if it holds
  nothing). A write-back already done at a non-zero step stays when step 0
  is written on that M-cycle.
- Default: `ch1_write` (NR10, a clock in flight: any `sweep_load_kind` but
  `SWEEP_LOAD_ARRIVAL`) reloads `sweep_timer`; `SWEEP_LOAD_LATCH_STEP0` in
  `ch1_sweep_run` writes the adder back (`common/psg_channels.nim`).
- Evidence (DocBoy only, CGB E): `cgb/apu/ch1/ch1_period_sweep_change_pace_
  4_to_6_during_recalc_round{0,1,2}_{1,2}` (pace 4 -> 6 one M-cycle before,
  on, and after the clock: the first two stop at the same time, the third
  two sweep clocks earlier), `change_step_during_recalc_0_to_4_alt_round
  {0,1,2}_{1,2}` (step 0 -> 4 with a step-0 calculation's operand held:
  round 0 and 1 stop alike, round 2 a pace period later), with
  `change_step_during_recalc_0_to_{4,6}_round1` (the 0-writing clock) and
  `6_to_0_round2_*` (the write-back kept) unchanged.
- Without it: `..._pace_4_to_6_..._round1_1` and `..._0_to_4_alt_round1_2`
  fail. SameBoy fails both; no hardware-verified test writes NR10 on a
  clock's M-cycle (blargg, SameSuite APU, gambatte `sound` unchanged).

### An APU power-on samples the DIV-APU bit an M-cycle ahead
- Claim: the NR52 power-on skips the first DIV-APU edge when the divider's tap
  bit is set (SameSuite `div_write_trigger_10`); the bit it sees is the one
  the divider holds 4 counts after the write's time stamp.
- Default: `APU_POWERON_TAP_LEAD = 4` (`gb/apu.nim`).
- Evidence: gambatte `sound/ch2_init_reset_env_counter_timing_{1..8}`:
  powered on 8 counts before the bit rises, a period-1 envelope steps at the
  eighth DIV-APU edge (`_1`/`_2` [dmg], `_3`/`_4` [cgb]); 4 counts before,
  one edge later (`_5`/`_6` [dmg], `_7`/`_8` [cgb]). `sound/ch2_late_reset_
  nr52_2b` [dmg, cgb] and `ch2_late_reset_nr52_ds_2b` [cgb] read the same skip
  through the length counter, the last at double speed.
- Brackets: 4..7 pass; 0..3 lose `_5` [dmg], `_7` [cgb] and the three `2b`
  tests; 8 loses `_2` [dmg], `_4` [cgb] and their `1a` siblings
  (`ch2_late_reset_nr52_1a` [dmg, cgb], `_ds_1a` [cgb]).
- The three leads above are one M-cycle of the write against the divider's
  edge, seen from three registers; the CGB's sweep unit adds a second.

### CPU CGB C and older: a double-speed square trigger acts at once and starts on the 512 kHz clock
- Claim: on CPU CGB D/E a trigger waits for the next 1 MHz edge, and a duty
  step due on that edge still happens (DocBoy, CGB E). On CPU CGB 0/A/B/C at
  double speed (a) the trigger acts in the write's own M-cycle: a step half a
  tick or less ahead is lost with the restart; and (b) a channel started from
  off begins its first period on the first 1 MHz edge at least one tick after
  the write that is an odd tick of the 512 kHz clock the power-on starts with
  the 1 MHz one (the noise channel's grid, `GbApu.noise_phase`).
- Default: `gb_trigger_pickup` returns no edge for `GbQuirks.cgb_c_or_older` at
  double speed; `SQ_START_HALF_RATE_LEAD_T = 4` T-cycles in
  `gb_trigger_deadline` (`gb/apu/psg_host.nim`).
- Evidence for (b), write time -> start of the first period, in 2 MHz
  M-cycles after the NR52 power-on (a tick is two):
  - 25 -> 30: SameSuite `channel_1_freq_change_timing-cgb0BC` cells 8..15
    (period 8 M-cycles; the sixth step is 53 M-cycles after the trigger: an
    NR14 write on it wins the reload, one M-cycle later does not), and
    gambatte `speedchange/speedchange{,2}*_ch1_duty0_pos6_to_pos7_timing_
    {,nop_}ds_{1,2}` (five pairs, through one or two KEY1 switches).
  - 30 -> 34: gambatte `sound/ch1_duty0_pos6_to_pos7_timing_ds_{1..4}`.
  - 31 -> 34: `sound/ch1_duty0_pos6_to_pos7_timing_ds_{5,6}`.
  - powered on at single speed, triggered after a switch:
    `speedchange_ch1_nr4init_duty0_pos6_to_pos7_timing_{1,2}`, 5 M-cycles.
  25 and 31 are both half a tick off the 1 MHz grid and start 5 and 3
  M-cycles later, so no rule on the 1 MHz grid alone fits; 30, 34 are odd
  ticks (15, 17).
- Two-sided: CGB D/E's two ticks after the next edge loses `_ds_6` and
  `nr4init_..._2`; the even 512 kHz phase loses nine tests and SameSuite's;
  the lead passes at 4 T, loses the five `ds_1` speedchange tests and
  SameSuite's at 2, `nr4init_..._2` at 6, that and `_ds_6` at 8.
- Evidence for (a): `sound/ch1_duty0_pos6_to_pos7_timing_ds_{1,3}` retrigger
  half a tick before the seventh duty step and stay silent, `_ds_{2,4}` on it
  and sound; `speedchange{,3_nop}_ch1_duty0_pos6_to_pos7_timing_{,nop_}1`
  retrigger 1 T before it. With CGB D/E's pickup nine tests of the two ladders
  fail.
- Open: a restart's own next step on these revisions at double speed (no test
  sees it; it keeps the D/E placement), and whether single speed has the
  512 kHz dependence (its tests trigger on even ticks only). Every test is
  channel 1; channel 2 shares the code.

### PCM12 on CPU CGB C and older: channel 2 reads as channel 1 does
- Claim: a PCM12 read in the M-cycle a square's duty output rises answers 0
  for that channel on CPU CGB 0/A/B/C. Measured on channel 1 (SameSuite
  `channel_1_freq_change_timing-cgb0BC` cells 4 and 15); channel 2 is the same
  circuit and SameSuite's `apu/README.md` names channels 1, 2 and 4.
- Default: `PCM12_CH2_EDGE_ZERO = true` (`gb/apu/psg_host.nim`), `$FF76` in
  `gb/memory.nim`.
- Evidence: none of its own. No scored test reads PCM12 on a channel 2 step on
  those revisions; every suite is identical with the knob off.

### A noise restart holds for two ticks
- Claim: a channel 4 trigger that restarts the divisor stage holds the
  stage's restart for two 1 MHz ticks. A retrigger one tick after that
  restart joins it: the stage keeps the earlier restart's timing (the LFSR
  is still reset). On the 512 kHz stage (divisor codes >= 1) a retrigger two
  ticks after is taken one tick late, and later triggers are measured from
  that edge. A dropped retrigger is not; anything further away is an
  ordinary restart.
- Default: `ch4_restart_edge` (`common/psg_channels.nim`), the edge kept in
  `PsgNoise.restart_edge` (GB only).
- Evidence: DocBoy `cgb/double_speed/apu/ch4/double_speed_apu_ch4_
  {retrigger,double_retrigger}_shift*_divider{0,1,3}_*` (CGB E). Each pair
  of rounds reads PCM34 either side of the 15th LFSR clock after the last
  trigger, so the ROM's write and read cycles give DocBoy's restart for
  every trigger spacing at one-M-cycle phase (the `nops` pre-delay walks the
  four phases of the 512 kHz grid). For code 3 with triggers on ticks
  k0 < k1 < k2: (1, 2) keeps k0's timing and (1, 3) starts one grid step
  late; (0, 2, 4) and (0, 3, 4) keep k1's, (0, 2, 5) and (0, 3, 5) start a
  step late; (0, 4, 6) and (1, 4, 6) are ordinary, the k1 = 2 case taking
  its window from the late edge 3. Codes 0 and 1: (0, 1) keeps k0's
  timing, and for code 0 so does (1, 2).
- Two-sided (round pairs, scored): the join alone fixes 29 and breaks 6;
  the late pickup alone 30 and 6; measured from the last write instead of
  the last restart 51 and 18; a pickup two ticks late 55 and 50. Code 0
  with the late pickup draws probe (m) `c0_pend_b` 4 M-cycles later than
  the DocBoy line recorded for it in tools/gbprobe/README.md (a black-box
  run, the one input here from another emulator); no scored test sees code
  0 there.
- Open: all of it is DocBoy's word (SameBoy fails the 59 code-3 tests,
  docs/dev/gb-failure-triage.md I1). No hardware-verified row (SameSuite,
  blargg, gambatte) and no single-speed row moves with it; two `ld [hl],a`
  stores are two ticks apart at single speed, so the late pickup reaches
  there untested. Probe (m) `c1_absorb`, `c3_absorb`, `c3_defer` on a CGB
  settle it (docs/dev/hwprobe-questions.md 20).
