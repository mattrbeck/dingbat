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

### The CGB boot hand-off lands on the M-cycle grid at phase 161
- Ships: `CGB_BOOT_PHASE = 161` (`ppu.nim`).
- Claim: the CPU and PPU share one clock, so the dot-grid-to-M-cycle offset is
  a property of the machine, not of the boot ROM. DMG's 5-dot head start
  leaves 452 = 113 × 4 dots to the line end; the CGB seed must also satisfy
  `457 − phase ≡ 0 (mod 4)`.
- Evidence: gambatte `display_startstate/stat_1` + `stat_2` leave 159..162
  open and 161 is the only `1 mod 4` value in it; 157/161/165 score alike and
  160 scores lowest. The `m2int_*` families, whose DMG and CGB twins expect
  the same value, all missed by one M-cycle on CGB at 160.

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
  (read back with `tools/gbppu/objtab.py`) was a dot over in 79/153 cells on
  the old phase.
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
  `m2int_m2stat` reach 100 % and `window` gains 80 rows. `STAT_M2_LEAD` and
  `LY0_PIPE_MCYCLES` are the compensation that keeps the M2-synced mealybug
  frames still while the pipeline moves; neither moves daid on its own.

### The SCX&3 split in GBMicrotest `hblank_int_scx0..7` is one uniform 2-dot error
- Ships: `M3_END_EARLY = 0` (`fifo_ppu.nim`) — the instrument, not a fix.
- Claim: the eight ROMs differ only in SCX, so they sample one uniform offset
  at eight residues; `c + (SCX&7)` fits all eight at c = 170, not 172. A
  per-residue table cannot carry more information than that.
- Open: at `M3_END_EARLY = 2` GBMicrotest gains 20 rows and mooneye
  `hblank_ly_scx_timing-GS`, wilbertpol `intr_2_mode0_scx{1,2,5,6}_timing_nops`
  and 150 gambatte rows break: the same residues measured from the other
  side. The suite's own header is also built against two overhead rows (DMG
  `0 1 1 1 1 2 2 2`, AGS `0 0 0 1 1 1 1 2`) — see
  `docs/gb-hardware-revisions.md` §4.

### STAT reads the coincidence bit clear in the M-cycle LY advances
- Site: bit 7 of the `read_mode` latch (`ppu.nim`).
- Evidence: mooneye `lcdon_timing-GS`: true for a comparison that has just
  become true and one that has just become false.

### CGB raises the line-144 mode-2 STAT source one M-cycle before vblank
- Site: `m2_line144` (`ppu.nim`): high on line 144 in mode 1, and on CGB also
  for the last 4 dots of line 143. Which CGB revisions keep the mode-0
  M-cycle at the end of mode 1 is `GbQuirks.m1_end_no_mode0`.
- Evidence: mooneye `misc/ppu/vblank_stat_intr-C` vs `-GS`: the DIV-reset
  bracket is 54/55 NOPs for vblank on every model and for STAT on DMG, but
  53/54 for STAT on CGB.

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
  refuse it (`m3_scy_change` 92.6 % → 78.3 %).

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
  it once the object-fetch phase (§3) is right. Before that fix the same rows
  measured 1, which was the fetch phase being absorbed.
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
  The 2^16 + 4 seed was first taken by comparison; the gambatte rows pin the
  region.
- Open: the `lcd_offset` family wants A + B ≡ 0 (mod 4) where the ladder says
  11, and contradicts itself at that resolution (`offset1_lyc99int_m0stat_*`
  vs `_m0irq_*`): the known one-dot-early mode-0 STAT raise seen from inside
  the instrument.

### The halted CPU samples the interrupt line at the end of its M-cycle
- Ships: `HALT_IF_SAMPLE_T = 4` (`cpu.nim`); 2 is the alternative arm.
- Open: at 2, GBMicrotest `int_hblank_halt_scx{0,3,4,7}` and wilbertpol
  `hblank_ly_scx_timing-C` go green and mooneye `hblank_ly_scx_timing-GS`
  (both copies) goes red; no value passes both, and `int_hblank_nops_scx0`
  (the non-halt sled endpoint) is green at either. The 2 arm splits every
  halted M-cycle's PPU tick and costs +5 % retired instructions on Pokemon
  Blue; the untried reduction is to skip the split when the PPU's idle-skip
  target is past the M-cycle's end.

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

All compiled out or off by default.

- `-d:gb_m3_trace -d:GB_TRACE_LY=n` (−1 = every line): per-dot mode-3 trace
  with register writes and the object trigger's penalty terms.
- `-d:gb_win_trace`: window start/re-trigger dots and the `WYLATCH` level;
  `tools/gbppu/windot.py` prints the dot each ROM's write lands on next to
  the filename's expected value.
- `-d:gb_stat_read_trace`: STAT read dots for the `m2int_*` families.
- `DINGBAT_GAM_DUMP=<dir>`: gambatte frames as PPM in the comparison's colour
  space (the staircase method for `bgtiledata`/`bgtilemap`).
- `tools/gbppu/objtab.py`: reads all 153 cells of GBMicrotest
  `ppu_spritex_vs_scx` back as dots (the ROM never writes $FF82, so the runner
  cannot score it).
- `tools/gbppu/cgbsweep.sh`, `famflip.py`, `reactsweep.sh`, `counters.sh`:
  knob sweeps against a baseline row file, per-family flip points with both
  devices side by side, the `WIN_REACT_PHASE` re-pin, and the retired-
  instruction A/B (rules in `docs/gb_oam_dma_cost.md`).
- Two concurrent runner passes must not share `TMPDIR`: `run_sharded_batch`
  removes `getTempDir()/dingbat-gambatte` on entry, and the loser reports
  every gambatte row as "no verdict". Each world also needs its own
  directory holding both `dingbat_test` and `dingbat_test_runner`.
