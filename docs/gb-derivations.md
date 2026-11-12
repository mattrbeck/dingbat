# GB/GBC and GBA derivations: claim, evidence, constant

One entry per hardware behaviour dingbat models that is not obvious from the
code. Each entry is the claim, the evidence that pins it, and the constant or
site that carries it. Values quoted as "ships" are the `{.intdefine.}` defaults
in `src/dingbat/gb/*.nim` and `src/dingbat/gba/*.nim`; the sweep tables behind
them live at the constants. Scores are in `tests/results*.md`; what is still
red and why is in `docs/gb-failure-triage.md`.

Test-ROM names are evidence: `gambatte x/y` is a row of the gambatte suite,
`mooneye a/b` of Gekkio's suite (wilbertpol's fork where named), `mealybug m3_*`
a reference PNG, `mGBA suite <section>` a section of mGBA's test ROM.

## 1. GB PPU: line phase and the CPU clock

### The LCD-on first line starts 5 dots before the LCDC write retires
- Ships: `LCD_ON_HEAD_START = 5` (`ppu.nim`); `LCD_ON_LINE0_TRIM = LCD_ON_LINE1_TRIM = 0` (`gb.nim`).
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
- Ships: `CGB_BOOT_PHASE = 165` (`ppu.nim`).
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
- Cross-check (gambatte-core `initstate.cpp`, read for facts): its post-boot
  state puts the CGB at frame cycle `144 * 456 + 164` and the DMG at
  `153 * 456 + 396`, both on the M-cycle grid; dingbat's dot index is one
  ahead of gambatte's line cycle on both machines (165 / 397), which 161 was
  not.

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
- Ships: `M3_PIPE_DELAY = 2`, `M3_THROWAWAY_DOTS = 4` (`fifo_ppu.nim`, `gb.nim`).
- Claim: Pan Docs, "Pixel FIFO": the fetcher's idle dots are at the tail
  (step 4 waits on the FIFO), so a push taken at Get-Tile-Data-High restarts
  the fetch rather than falling through Sleep/Push. The 172-dot line is the
  check: 12 dots of head + 160 pixels only adds up if the first push is
  immediate. The head splits 4 + 8: the discarded fetch is a `B0` and the
  first real cycle runs to its own push slot.
- Evidence: mealybug `m3_bgp_change` (no objects) pins the 2-dot lead;
  `m3_scy_change` reads the 4 + 8 split off directly
  (`docs/gb-mealybug-sources.md` §3.4); GBMicrotest `ppu_spritex_vs_scx`
  (read back with `tools/gbppu/objtab.py`) is exact in all 153 cells at this
  phase and a dot over in 79 of them at the next.
- Cost: the lead is arrangement, not work; the per-dot machinery is
  `when M3_PIPE_DELAY == 0`-guarded. See `docs/gb_oam_dma_cost.md` for how it
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
- Ships: `M3_PIPE_AHEAD = 1` (`fifo_ppu.nim`), `STAT_M2_LEAD = 1` (`ppu.nim`),
  `LY0_PIPE_MCYCLES = 0`.
- Evidence: daid `ppu_scanline_bgp.gbc` is exact only with this trio plus
  `--cgb-rev=D` (band-edge pairing shows the trio is worth exactly +4 dots
  and rev D exactly −1); gambatte `m2int_m3stat`, `m2int_m0stat`,
  `m2int_m2stat` and most of `window` want it. `STAT_M2_LEAD` and
  `LY0_PIPE_MCYCLES` are the compensation that keeps the M2-synced mealybug
  frames still while the pipeline moves; neither moves daid on its own.

### `M3_END_EARLY` is an instrument, not a fix
- Ships: `M3_END_EARLY = 0` (`fifo_ppu.nim`). It moves the mode 3 -> 0 edge
  uniformly, so a family that differs only in SCX (GBMicrotest
  `hblank_int_scx0..7`) samples one offset at eight residues through it.
- Refuted at 2: mooneye `hblank_ly_scx_timing-GS`, wilbertpol
  `intr_2_mode0_scx{1,2,5,6}_timing_nops` and 150 gambatte rows measure the
  same residues from the other side (`docs/gb-failure-triage.md`, "Refuted
  models"). GBMicrotest's own header states two overhead rows for the SCX
  family — `docs/gb-test-suite-sources.md`, "GBMicrotest".

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
- Ships: `stat_drop_arm` / `stat_drop_settle` (`ppu.nim`), at the existing
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
- The DMG's LYC write is the same disable through the comparator: `LYC_DROP_
  LATENCY_DMG = 1`, bracketed at the constant by `m0enable/lycdisable_
  ff45_*` and `m2enable/lyc1_m2irq_late_lyc255_*`. A DMG LYC write in the
  M-cycle of the line boundary does not drop the line
  (`LYC_DROP_BOUNDARY_SKIP`): the comparator meets the new LYC and the new
  LY together, so `lycEnable/ff45_enable_weirdpoint_3` and `lyc153_late_
  ff45_enable_3` [dmg] see no edge. The CGB's LYC write does not come
  through here: "CGB LYC write: a sampled comparator", section 7.

### CPU VRAM/OAM locks close on the live mode and open with the STAT bits
- Site: `cpu_vram_open` / `cpu_oam_open`, checked on the CPU bus
  (`mem_read`/`mem_write`), never in `ppu_read`/`ppu_write`, so the OAM DMA
  unit keeps its access.
- Evidence: mooneye `lcdon_write_timing-GS` (an OAM write lands in the last
  M-cycle of mode 2 while a read in that M-cycle is refused);
  `hblank_ly_scx_timing-GS` for the mode-0 quantisation.

## 2. Window

### WY is a level comparator behind a per-frame latch
- Claim: Pan Docs, "Window": "WY == LY at any point in the frame". The latch
  is set at the top of every visible line and on any WY write that makes the
  two equal; nothing re-reads WY afterwards.
- Evidence: gambatte `window/arg/late_wy_1` vs `_2` put the per-line sample at
  dot 0, not 80; `late_wy_1toFF_*` show a `ly >= wy` re-test retracting a
  window hardware keeps drawing.

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
- Ships: `WIN_REACT_PHASE = 7` (`fifo_ppu.nim`).
- Claim: the window does not restart; one colour-0, lowest-priority pixel is
  inserted behind the FIFO head and the rest of the line shifts right by one.
  Colour 0 is what lets an OBJ-behind-BG sprite show through it.
- Evidence: mealybug `m3_wx_4_change`, `m3_wx_4_change_sprites`,
  `m3_wx_5_change` — all three pixel-exact at phase 7 and at no other of the
  eight fetcher positions (`tools/gbppu/reactsweep.sh`). Which fetcher step
  swallows the edge is a property of this renderer's phase, hence a knob.

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

### Reading a mealybug `m3_*` frame as eighteen measurements
- `m3_scy_change`'s OAM table is Y = 16 + 8k, X = k, so each 8-line band is one
  object whose X sets the wait term; score per band, not per frame, or a
  constant gets fitted to a residual from another band. Method in
  `tools/gbppu/README.md` (`-d:gb_m3_trace -d:GB_TRACE_LY=-1`, `mbscore.py`).

## 4. CGB register write latency

### The CGB delays a mid-line write per register, not by one phase
- Ships (`gb.nim`): `CGB_SCY_LATENCY = 2`, `CGB_SCX_LATENCY = 2`,
  `CGB_WY_LATENCY = 4`, `CGB_WX_LATENCY = 0`, `CGB_WY_LATCH_LATENCY = 0`,
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
- WX 0: no instrument in the tree moves.
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
  `dma/hdma_m3halt_m1unhalt_hdma5`. The remaining `hdma_late_*` / `_unhalt_*`
  one-M-cycle pairs are the CPU-vs-PPU phase cluster; their bracketing
  constants (`HDMA_HALT_BLIND_LAG*`, `HDMA_WAKE_M0_MARGIN`) are documented at
  their declarations in `gb.nim`.
- Site: the check sits inside the halted branch of `cpu.tick` and is asked
  only on the M-cycle the halt ends (asking every halted M-cycle measured
  0.3 % of Pokemon Blue).

### A HALT parks a pending HBlank request for the wake; the wake pays it in any mode
- Claim: the HBlank request is a line the CPU samples at its hand-over
  points; HALT is not one. A request up when HALT executes (owed and not yet
  granted, or its mode-0 edge on the HALT's own dot) is held and the block
  runs at the wake, before any dispatch, whatever mode the PPU is then in. An
  edge falling while halted is not requested (the frozen detector above);
  one falling inside a running block is lost when the block acknowledges
  the request at its end.
- Evidence: gambatte `dma/hdma_late_m3halt_m2unhalt_scx1_{1,2}` (edge 4
  dots after the HALT: block at the next HBlank; edge on the HALT's dot:
  block at the mode-2 wake), `hdma_late_m3halt_m2unhalt_inc_scx2_2`,
  `hdma_transition_halt_late_unhalt_scx1_{1,2}` (the second line's edge falls
  inside the woken block and is not paid).
- Site: `HDMA_HALT_REQ_DOTS`, `HDMA_HALT_DEFERS_DUE`, `HDMA_BLOCK_SWALLOW`,
  `ppu_hdma_wake` (ppu.nim), the halted branch of `cpu.tick`.

### ... and that HALT has prefetched the next opcode without advancing PC
- Claim: the HALT that parks a request has fetched the following byte into
  the opcode latch without incrementing PC. At an IME-off wake that byte runs
  first and is then fetched again, so it runs twice (the halt-bug shape), and
  the latch fetch is the block's release M-cycle, not an extra one. It is the
  byte as it was at the HALT, before the block.
- Evidence: gambatte `dma/hdma_late_m3halt_m2unhalt_inc_scx1_2` (`HALT; INC A`
  prints 02), `hdma_transition_7fffhalt_inc_m3unhalt` (HALT at $7FFF, the next
  byte is the block's destination $8000 and the pre-block byte runs),
  `hdma_late_m3halt_m2unhalt_ly_scx1_3` (no extra M-cycle: LY read unchanged).
- Site: `HDMA_HALT_REQ_BUG`.

### The KEY1 switch's stall is that HALT, and STOP's operand is the latch
- Claim: Pan Docs' STOP chart puts the switch leaf in HALT mode. The HBlank
  detector freezes across the 2^17-cycle stall as across any halt; a request
  up at the STOP (for 2 dots, or its edge on the STOP's dot) is found by it.
  Into double speed the block runs inside the stall and the transfer ends with
  its length register unchanged (FF55 reads length | $80); into single speed
  it is paid at the stall's end. Either way the operand byte STOP fetched is
  in the opcode latch and runs as the first instruction after the stall.
- Evidence: gambatte `dma/hdma_m0speedchange_late_m3wakeup_scx{1,2}_{1,2}`
  (an edge in the stall's last dots is not seen), `hdma_late_m3speedchange_
  hdma5_scx2_{1,2,3}` (00 / 80 / FF), `_read_hdmadst00_*` (the block's byte
  in VRAM), `_inc_scx1_2` and `hdma_late_speedchange_inc_scx1_ds_2` (the ROMs
  write `stop, 3c`; A reads 02), `_tima_scx1_ds_{1..4}` (the age bracket).
- Site: `HDMA_SWITCH_HALTS`, `HDMA_SWITCH_REQ`, `HDMA_SWITCH_REQ_AGE`,
  `HDMA_STOP_OPERAND_RUNS`, `stop_instr` (memory.nim).

### An HBlank request beats a dispatch that starts on its dot
- Claim: when the mode-0 edge and an interrupt dispatch fall on the same
  boundary, the block goes first (its source may be the stack the dispatch
  pushes onto).
- Evidence: gambatte `irq_precedence/late_hdma_vs_tima_scx1_{1,2}` (one
  M-cycle apart: 1234 then 11E9), `hdma_vs_m0_scx1`, `late_hdma_vs_{ei,ie}_
  scx1_2`, the `_halt` variants at a wake.
- Site: `HDMA_EDGE_BEATS_DISPATCH`, `HDMA_WAKE_DEBT_RECHECK`.

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
- Ships: `GDMA_SETUP_MCYCLES = 0` (`gb.nim`). gambatte `dma/gdma_cycles_*` say
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
  `docs/gb_oam_dma_cost.md`.

## 7. CPU

### The eleven undefined opcodes lock the CPU until reset
- Claim: Pan Docs, "CPU Instruction Set": D3/DB/DD/E3/E4/EB/EC/ED/F4/FC/FD
  hang the SM83. Modelled as `halted` plus a sticky `locked` so the PPU,
  timer, OAM DMA and scheduler keep ticking (the frame keeps drawing) and no
  interrupt clears it. PC stays on the opcode. GB payload rev 4.
- Evidence: gambatte `undef_ops/*` (20 ROMs).

### The KEY1 speed switch resets DIV and stalls the CPU for 2^16 + 12 T-cycles
- Ships: `SPEED_SWITCH_STALL_T = 65548` (`memory.nim`), with
  `SPEED_SWITCH_PPU_EXTRA_DOTS` splitting the 12 into to-double 8 and
  to-single 3.
- Claim: Pan Docs, "Reducing Power Consumption" has STOP resetting DIV; the
  reset goes through the FF04 write path so the APU frame sequencer, serial
  and TIMA see it as any DIV write. Pan Docs, "CGB Registers" → "FF4D — KEY1"
  says the CPU stops for 2050 M-cycles (8200 T); hardware stalls for about
  2^16 dots. Dingbat disagrees with Pan Docs here (`docs/pandocs-upstream.md`).
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
  The gambatte rows pin the region; the exact 2^16 + 4 within it is not
  ROM-pinned (`docs/oracles.md`, `SPEED_SWITCH_STALL_T`).
- Open: the `lcd_offset` family wants A + B ≡ 0 (mod 4) where the ladder says
  11, and contradicts itself at that resolution (`offset1_lyc99int_m0stat_*`
  vs `_m0irq_*`): the known one-dot-early mode-0 STAT raise seen from inside
  the instrument.

### HALT with an interrupt already pending, and the DMG's two-M-cycle HALT
- Claim: a HALT that finds IME on and IF & IE != 0 does not halt; the
  dispatch pushes the HALT's own address (the next opcode's fetch is
  undone), so the handler returns to the HALT and it halts again. A DMG HALT
  answers an interrupt no earlier than the end of its second M-cycle.
- Evidence: gambatte `halt/late_m0int_halt_m0stat_scx{2,3}_3a` (both
  devices) and `_scx3_3b` [dmg] push the HALT's address; `halt/late_m0{int,
  irq}_halt_m0stat_scx3_2b` [dmg] (an interrupt raised in the HALT's first
  M-cycle, dispatched one M-cycle later than the next opcode would have).
- Site: `HALT_IME_PENDING_REDO`, `DMG_HALT_MIN_MCYCLES` (cpu.nim).

### The halted CPU samples the interrupt line at the end of its M-cycle
- Ships: `HALT_IF_SAMPLE_T = 4` (`cpu.nim`); 2 is the alternative arm.
- Open: at 2, GBMicrotest `int_hblank_halt_scx{0,3,4,7}` and wilbertpol
  `hblank_ly_scx_timing-C` go green and mooneye `hblank_ly_scx_timing-GS`
  (both copies) goes red; no value passes both, and `int_hblank_nops_scx0`
  (the non-halt sled endpoint) is green at either. The 2 arm splits every
  halted M-cycle's PPU tick and costs +5 % retired instructions on Pokemon
  Blue; the untried reduction is to skip the split when the PPU's idle-skip
  target is past the M-cycle's end.

### The dispatch clears IF inside its fifth M-cycle
- Ships: `IRQ_SAMPLE_T = 18`, `IRQ_SAMPLE_T_DS = 16` (`cpu.nim`).
- Claim: the taken line's IF bit is cleared after the two waits and two
  pushes (Pan Docs, "Interrupt Handling"), 2 T into the fifth M-cycle in
  single speed.
- Evidence: gambatte `*_late_retrigger` (six STAT sources and the timer):
  the handler's IF re-request moves one M-cycle per member and the second
  dispatch's read of IF says whether the clear beat the source's next rise.
  16 loses the `_2` arms of `ly0/lycint152_lyc0irq` and
  `irq_precedence/late_m0irq_retrigger` (sources that rise mid-M-cycle), 17
  takes the first pair, 18 both (+4, nothing lost, 2026-09-22), 19 loses
  `late_m0irq_retrigger_scx1_1`, 20 also `m2int_m2irq_late_retrigger_1`.
  Double speed keeps 16: an odd value is off the dot grid and 20 flips every
  `_ds_1` arm.
- Open: the LYC-, mode-1- and timer-first families' `_2` arms (12 rows) want
  20 where the mode-2-first families want below 19 — a per-source phase
  question, `docs/gb-failure-triage.md` A2.

### The comparator steps two dots before the line boundary

gambatte-core schedules its LYC interrupt event at frame cycle
`LYC * 456 - 2` (`lyc_irq.cpp`) and its mode-1 event at `144 * 456 - 2`:
both sources rise two dots before the LY increment. dingbat's LY steps on
the boundary and its STAT sources rose there too, which the ordinary CPU
grid cannot tell apart (the boundary is the last dot of an M-cycle, both
are seen at the same instruction end). A KEY1 speed-switch round trip
leaves the CPU grid three dots behind the PPU's (E1), and there the two
differ by a whole M-cycle: every gambatte `*_lcdoffset1_1` row on the LYC
and mode-1 sources is one dispatch late until the comparator's LY steps at
dot 454 (`STAT_LYC_LY_LEAD_DOTS`). Single speed only; the double-speed
grid's constants are a coupled set and move together or not at all.

### ... and the mode-1 source and the vblank request rise with it
- Claim: entering vblank is the same event: at dot 454 of line 143 the
  comparator's LY steps to 144, line 143's LYC match lets go, the mode-1 STAT
  source rises after it (so a match on 143 still hands the edge detector an
  edge) and the vblank request goes up. A STAT write still in flight that
  clears the mode-1 enable is already the enable the rise sees.
- Evidence: gambatte `m1/lycint143_m1irq_late_retrigger_2` and
  `m1/lycint_vblankirq_late_retrigger_2` (both devices: the retriggered
  dispatch's IF clear takes back a request raised at 454, not one at 456),
  `m1irq_m0disable_2`, `m1irq_m2disable_lycdisable_2`, `m1irq_disable_1`
  [cgb], `lcd_offset/offset2_lyc8fint_m1irq_2` [cgb]; without the order
  (LYC falls, then mode 1 rises) the `lycint143_m1irq_*` family loses 15.
- Site: `STAT_M1_LEAD`, `VBLANK_IRQ_LEAD`, `fifo_lyc_ly_lead` (fifo_ppu.nim).
- The same lead ends line 153: line 0's OAM pulse rises at 153:454
  (`STAT_M2_LY0_LEAD`; gambatte `lyc153int_m2irq_late_retrigger_2`,
  `m2enable/late_m1disable_ly0_2`, `lcd_offset/offset{1,2}_lyc99int_m2irq_
  count_2`), and a vblank line's boundary opens no second blind window for a
  comparator that already stepped (`LY_BLIND_SKIP_LED`;
  `ly0/lycint152_lyc153irq_late_retrigger_2`). A rendered line's window
  stays: skipping it loses 12 `lcdirq_precedence`/`miscmstatirq` rows.

### CGB LYC write: a sampled comparator
- Ships: `CGB_LYC_CMP_LATCH = true`, `CGB_LYC_LAND_T = 2`,
  `CGB_LYC_LATCH_PHASE = 0`, `CGB_LYC_BRIDGE = 1` (`gb.nim`); `GB.lyc_cmp`,
  `lyc_cmp_write` / `lyc_cmp_land` / `lyc_cmp_settle` (`ppu.nim`),
  `fifo_tick_lyc_land` (`fifo_ppu.nim`).
- Claim: on a CGB the LY = LYC STAT source does not read the LYC register
  the CPU reads back. (1) A write reaches the comparator's input half a CPU
  M-cycle after the top of the write's M-cycle: 2 dots at single speed, 1 at
  double. (2) The comparator's answer reaches the STAT line only on a 4-dot
  grid of the PPU's own clock, the grid its LY step is on (dot 454 of a
  line at single speed, `STAT_LYC_LY_LEAD_DOTS`; the line boundary at
  double speed, where that lead is 0). So the line moves, up or down, on
  the first grid dot at or after the landing: 2..5 dots after the top of
  the write's M-cycle at single speed (5 on the power-on CPU grid, 2 on the
  grid a KEY1 round trip leaves), 1..4 at double. (3) The sample is one
  event with whatever else the PPU does on its dot: a mode source rising or
  falling there, or the comparator's own LY changing (the step before the
  boundary, line 153's snap to 0), meets the new LYC, and the line sees one
  change, not two. (4) A write whose sample is the LY step itself, moving a
  match on the line ending onto the line starting, is therefore never seen
  low, and the line boundary's comparator window (`ly_advance_open`) stays
  shut for it; if the old LYC did not match the line ending, the window
  opens as on any line and a mode-0 source hands the line to the new match
  with an edge. The readable register and STAT bit 2 keep their own timing
  (`CGB_LYC_WRITE_DEFER`, `CGB_LYC_EDGE_DEFER`).
- Evidence, single speed (W = the first dot of the write's M-cycle; every
  row is gambatte, [cgb]):
  - `lycEnable/ff45_enable_weirdpoint_{1,2,3,4}` and `_lcdoffset1_{1,2,3}`
    hold LYC = LY = 5 and write LYC = 6 around the 5 -> 6 boundary. W = 445
    and 448 request (the old match drops on the sample before the step, the
    new one rises at 454), W = 449 and 452 do not (both inputs move under
    the sample at 454), W = 453, 456 and 457 request again (the line is low
    from 454 until the next sample finds the new LYC). The quiet window is
    exactly one grid period, W in 449..452, across both CPU grids, so the
    grid is the PPU's and not the CPU's.
  - `lycEnable/late_ff45_enable_{1,2,3}` and `_lcdoffset1_{1,2}` turn a match
    on late in the matching line: W = 445 and 448 request, 449, 452 and 453
    do not (the first sample that holds the new LYC is the one LY leaves on).
  - `lycEnable/lyc153_late_ff45_enable_{1..5}` and `_lcdoffset1_{1,2}` do the
    same across 152 -> 153, where the comparator's LY is 153 for two
    samples only (454 and dot 2; it is 0 from dot 6): W = 445 requests, 449
    is the carried match, 453 and 456 request (sample on dot 2), dot 1, dot
    4 and dot 5 do not (their sample is dot 6, the snap's own).
  - `lycEnable/lyc0_ff45_disable_{1,2,3}` take LYC = 0 away around the snap:
    W = dot 1 is quiet (sampled on dot 6 together with the snap), dots 5
    and 9 request.
  - `m0enable/lycdisable_ff45_{1..4}` and `_scx{1,2,3}_{1,2,3}` break a
    match ahead of the mode-0 rise at dot 250 + SCX: W = 241 (sample 246)
    and W = 245 with the rise on 251..253 (sample 250) dip and request;
    W = 245 with the rise on 250 itself does not (one event), nor does
    W = 249 (sample 254).
  - `lycEnable/lycwirq_trigger_ly00_stat50_{1,2,3}` and `_lcdoffset1_{1,2}`
    (mode-1 source up through line 153, LYC 255 -> 0): W = 449 and 452 are
    quiet (LYC is up at 454, before mode 1 lets go at the boundary), 453,
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
  `_ds_lcdoffset1_{1,2}` (the comparator's LY is 153 on the samples at the
  boundary and dot 4, 0 from dot 8); `lyc0_ff45_disable_ds_{1,2}`;
  `m0enable/lycdisable_ff45_ds_1`, `_scx1_ds_{1,2}`;
  `lycwirq_trigger_ly00_stat50_ds_{1,2}`, `_ds_lcdoffset1_{1,2}` (W = 454
  and 455 land on the boundary's sample with the mode-1 source's fall: one
  event, quiet; 456 and dot 1 request); `miscmstatirq/
  lycwirq_trigger_m0_late_ly44_lyc45_ds_{1..4}`.
- Brackets (gambatte hex rows, 4,302 scored; this model is 4,285):
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
  `lyc0_ff45_disable_{1,ds_1}`. `CGB_LYC_CMP_LATCH = false` is the tree
  before this entry, row for row.
- Rows taken (12, nothing lost anywhere in `tests/results*.md`):
  `lycEnable/ff45_enable_weirdpoint_{2, ds_2, ds_lcdoffset1_2,
  ds_lcdoffset1_3, ds_lcdoffset1_4, lcdoffset1_2}`,
  `late_ff45_enable_{ds_2, ds_lcdoffset1_2}`,
  `lyc153_late_ff45_enable_{ds_2, lcdoffset1_1}`,
  `lycwirq_trigger_ly00_stat50_ds_lcdoffset1_2`,
  `miscmstatirq/lycwirq_trigger_m0_late_ly44_lyc45_ds_3`.
- Supersedes, on the CGB's STAT line only: `LYC_DROP_LATENCY_CGB`,
  `LYC_DROP_LATENCY_CGB_DS` (the fall is the sample's) and the line half of
  `CGB_LYC_EDGE_DEFER` (the rise is too; its event still times the readable
  bit for wilbertpol `ly_lyc*_write-C`).
- Not serialized: the write is in flight for at most five dots, and
  `step_frame` runs an instruction past a frame edge that would cut one.
- Open: why the double-speed grid sits on the boundary's phase rather than
  two dots ahead of it is the existing `STAT_LYC_LY_LEAD_DS = 0` question,
  not a new one; the grid is anchored to whatever dot the comparator's LY
  steps on. The DMG's LYC write keeps its own spelling
  (`LYC_DROP_LATENCY_DMG`, `LYC_DROP_BOUNDARY_SKIP`, `DMG_LYC_BOUNDARY_OPEN`);
  its quiet arm (`ff45_enable_weirdpoint_3`, W = 453) is consistent with
  the same grid and a later landing, but nothing was moved there.
- Clean-room: derived from test ROM sources/outputs and black-box runs; no
  emulator source consulted. (Black-box runs: none were needed; every
  figure above is a gambatte test ROM's own filename verdict against
  dingbat's trace of the write's dot.)

### CGB STAT/LYC write timing
- The LYC-write (FF45) half: removed 2026-11-12 pending a clean-room
  re-derivation. Rows red meanwhile: gambatte `lycEnable` (11),
  `miscmstatirq` (1). The STAT-write (FF41) half is the five entries below.

### A CGB STAT write across a line's end: what its enables find (single speed)
- Clean-room: derived from test ROM sources/outputs and black-box runs; no
  emulator source consulted. (No black-box emulator was run: every figure
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
  as before, and inside dot 454 -- the comparator's lead dot -- the CGB's
  sources change in a fixed order, the edge detector seeing each step:
  (1) enables landing on 454 take hold; (2) the comparator lets go of the
  line's match, and on line 143 the mode-1 source rises; (3) the mode-0
  source falls; (4) the comparator answers for the next line; (5) line 143's
  OAM pulse ends. Mode 0 therefore ends two dots before the boundary on a
  CGB, where a write from 453 (landing 455) no longer finds it and the DMG
  (whose write acts on its own dot) still does; a mode-0-to-LYC hand-over is
  an edge (3 before 4) that enables about to be cleared still see; and a
  write from 452 finds the old line's match and mode 0 both still up (1).
- Evidence, two-sided per step (each "moved" build loses exactly the rows
  named): no step 1, `lycEnable/late_ff41_enable_lcdoffset1_1`; step 1 for
  LYC writes too, `late_ff45_enable_2` and `lyc0_late_ff45_enable_2`; step 3
  ahead of 2, `lcdirq_precedence/m1irq_lcdstat18` and
  `m1/m1irq_m0disable_{2,3}`; 3 and 4 swapped, `lycEnable/ff41_disable_2`;
  step 5 with step 3, `lcdirq_precedence/lcdirqprecedence_lycirq_ly90_
  lcdstat68`. The whole rule off loses seven rows (listed at the constant).
- With the hand-over done on 454, the 143 -> 144 boundary has no comparator
  dip left for a CGB at single speed (`ly_advance_vblank_entry`).
- Site: `CGB_LINE_END_STEPS` (gb.nim), `fifo_cgb_line_end` (fifo_ppu.nim),
  `m0_source`, `m2_line144` (ppu.nim).

### The CGB's OAM pulse is narrower for a landing enable
- Clean-room: derived from test ROM sources/outputs and black-box runs; no
  emulator source consulted.
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
- Clean-room: derived from test ROM sources/outputs and black-box runs; no
  emulator source consulted.
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
- Clean-room: derived from test ROM sources/outputs and black-box runs; no
  emulator source consulted.
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
- Clean-room: derived from test ROM sources/outputs and black-box runs; no
  emulator source consulted.
- Claim: LY reads 0 from dot 5 of line 153 and nothing else sees the
  LYC = 153 match past it, but a CGB STAT write that sets the LYC enable
  still finds it until the dot the source relatches for LY = 0 (6 at single
  speed, 8 at double), inclusive.
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

### An IF write lands one dot into its M-cycle
- Claim: a request raised in the first dot of the M-cycle that writes IF is
  overwritten by the write (single speed). The LYC = 0 match on line 153
  rises on dot 6, one later than the source relatch had it.
- Evidence: gambatte `m2int_m0irq/m2int_m0irq_scx3_ifw_{2,4}` (both
  devices) against `ly0/lycint152_lyc0irq_ifw_1`; gambatte-core stores IF
  after catching its sources up to the write's cycle + 1.
- Site: `IF_WRITE_LAND_DOTS` (memory.nim), `LYC_SRC_RELATCH_ADJ` (ppu.nim).

### A CGB dispatch clears a timer or serial request 2 T later
- Claim: the dispatch acknowledges the LCD lines 18 T in and the timer and
  serial lines later on CGB, so a timer or serial request rising in the
  dispatch's last T-cycles is still taken back there.
- Evidence: gambatte `tima/tc00_irq_late_retrigger_3` [cgb],
  `serial/start_wait_trigger_int8_read_if_2` [cgb]; gambatte-core's
  acknowledge looks ahead 2 T for the LCD, 2 + CGB for the timer and 3 + CGB
  for serial (`Memory::ackIrq`).
- Site: `IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD` (cpu.nim).

### The window's WY comparator samples five dots after a CGB write

gambatte `window/arg/late_wy_FFto0_ly2` and `late_enable_afterVblank` flip
between commits 445 and 449 of line 0 on the CGB (449 and 453 on the DMG),
`late_wy_1toFF` between 449 and 453: a WY write or an LCDC.5 enable that
lands before the boundary arms the window for the next line only if the
comparator sees the match with the OLD line number, and it samples one CPU
M-cycle after the write lands (`WIN_CHECK_DEFER_CGB`). Mid-line writes
(`late_wy_FFto2_ly2_*`, 85 -> 89) bracket the same deferral from above.
Line 0's own check runs at dot 4 (`WIN_LINE0_CHECK_DOT_CGB`): `late_wy_1`
(commit 453 of line 153, lands 1) must be seen and `late_wy_2` (commit 1,
lands 5) must not. SameBoy's model is the same shape -- the write lands at
the M-cycle start and the check runs at the next 4-dot grid tick.

### The CGB palette RAM lock trails the STAT edges

gambatte `cgbpal_m3/cgbpal_m3end_{1,3}` (single speed) and `_ds_{1,3}`:
BCPD/OCPD are still locked for a read at the first M-cycle of mode 0 and a
write one dot into it, and open two dots in at both speeds; `m3start_ds_1`
and `{read,write}_m3start_ds_1`: at double speed the lock engages two dots
after the mode-3 edge, at single speed one (`CRAM_LOCK_ON_LAT{,_DS}`,
`CRAM_LOCK_OFF_LAT`). `enable_display/ly0_late_cgbp{r,w}_2`: the LCD-on
first line locks four dots later still (`CRAM_LOCK_LINE0_EXTRA`), not never.

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

### VBK is locked outside CGB mode; FF4F reads $FE
- Claim: VBK leaves the register map with the rest of the CGB set when KEY0 is
  set, so bank 1 is unwritable and the attribute plane is all zero by
  construction; the fetcher reads it unconditionally (a branch there cost
  +0.8 % on Pokemon Crystal).
- Evidence: mooneye `misc/bits/unused_hwio-C` reads $FE from FF4F.

### Revision-dependent behaviour
- `docs/gb-hardware-revisions.md`: the `GbRevision` → `GbQuirks` axis, its
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
- Ships: `HBLANK_IRQ_SYNC_DELAY = 6` (`ppu.nim`); `IRQ_SYNC_DELAY = 3`
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
[`tools/gbppu/README.md`](../tools/gbppu/README.md); runner hazards (shared
`TMPDIR`, one binary pair per world) in [`tests/README.md`](../tests/README.md),
"Exit code, baselines, hazards"; the retired-instruction A/B rules in
`docs/gb_oam_dma_cost.md`.
