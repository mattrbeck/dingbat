# GB test-suite failures: the open buckets

Game Boy tests grouped by the hardware mechanism they measure. For each
bucket: the tests, the behaviour under test and the evidence for it, what
dingbat models (the knob and its default value), and what would close it
if tests still fail. Scores live in `tests/results.md` (per suite) and
`tests/results_gambatte.md` (per test); this file explains them and is
updated when they move.

Buckets A to H are all closed: every test they name passes or is in the
not-scored ledger. They keep their derivation record, because knob comments
cite them by ID; the rules and the values tried on each side are in
docs/dev/gb-derivations.md. The tests that still fail are DocBoy's (section I).
Other closed buckets are one line each at the end. "Not recorded" below
means the test passes and this file does not say which change closed it.

Conventions: a knob is a `{.intdefine.}` in `src/dingbat/gb/` and its own
comment carries the derivation; `[dmg]`/`[cgb]` is the device a gambatte test
is scored on; `_ds_` is double speed; `@cgbc` etc. is the revision case of a
test whose ROM names several machines.

## Where the numbers and the instruments live

* Per-suite tallies: [`tests/results.md`](../../tests/results.md); per-test
  gambatte verdicts: [`tests/results_gambatte.md`](../../tests/results_gambatte.md).
  This file names buckets, not counts. The local runner scores CGB tests on
  CPU CGB C and the gbdev shootout adapter on CGB E; both are at the model's
  maximum for their revision ("The device each suite is scored on",
  [`tests/README.md`](../../tests/README.md)).
* Tests deliberately not scored: the runner's `NotScored` ledger, printed as
  "Deliberately not scored" at the end of `tests/results.md`. Bucket C3 (the
  three `spx2` tests) has an entry in it.
* Reading a test as a dot count — gambatte family ladders, AGE cell tables,
  wilbertpol sample dumps, PNG diffs, the `-d:gb_*` trace builds, sweeps and
  the retired-instruction A/B:
  [`tools/gbppu/README.md`](../../tools/gbppu/README.md). The gambatte
  filename convention is in `tests/README.md` ("The gambatte suite");
  runner hazards (shared `TMPDIR`, ROM cache, rewritten baselines) in its
  "Exit code, baselines, hazards".

---

## A. STAT and interrupt timing

### A1. The mode-0 dispatch grid at double speed

**Closed.** At double speed the mode-0 source rises with the mode flag
(`STAT_M0_LEAD_DS = 0`, ppu.nim), so no rise is ever one dot old at a
dispatch boundary and `STAT_DISPATCH_MIN_AGE_DS` stays 0 (gb.nim;
docs/dev/gb-derivations.md, "Double speed: the mode-0 source, the line-144
pulse, the LCD-on line").

Tests: AGE `stat-interrupt/stat-int-dmgC-cgbBCE@{cgbab,cgbc,cgbe}`, gambatte
`m0int_m0stat/m0int_m0stat_scx5_ds_2` and `m0enable/disable_scx5_ds_2`.

The `-d:gb_dispatch_trace` dots show what the tests measure. The
double-speed dispatch grid sits on odd dots; a source rising ahead of the
flag rose, for an odd SCX, one dot before a boundary and was taken there,
and for an even SCX two dots before one. AGE's staircase pairs SCX (1,2),
(3,4), (5,6). `m2int_m0irq_scx5_ds_1` and `enable_display/*_ds_1` did not move
either way.

### A2. The dispatch's IF clear against a source rising inside it

**Closed.** The dispatch clears IF 18 T in at both speeds, and the sources
reach it at different leads (`IRQ_SAMPLE_T`, `IRQ_SAMPLE_T_DS`, cpu.nim,
plus the per-source knobs below).

Tests: `ly0/lycint152_lyc153irq_late_retrigger_2` and
`lyc153int_m2irq_late_retrigger_2` (both devices),
`ly0/lycint152_lyc0irq_late_retrigger_2`,
`irq_precedence/late_m0irq_retrigger_2`,
`m1/lycint143_m1irq_late_retrigger_2` and
`m1/lycint_vblankirq_late_retrigger_2` (both devices),
`tima/tc00_irq_late_retrigger_{2 [cgb],3 [cgb],ds_2}` and
`serial/start_wait_trigger_int8_read_if_2` [cgb].

**Behaviour.** Each ROM's handler re-requests its own interrupt with an
`LDH ($0F),A` that moves one M-cycle per member, `EI`s, and reads IF inside
the second dispatch. The chain from the first dispatch to the second is
fixed by the handler bytes (m2int_m2irq: 436 T at `_1`, 4 more per member).
The source's next rise is one line (456 T) or one timer period (2048 T)
after its first. So each member asks whether the second dispatch's IF clear
lands before or after that next rise. Write the clear as `T` cycles into the
dispatch and the first rise's distance to the dispatch's M-cycle boundary as
`d` (0..3). The `_1`/`_2` flip of every family then puts `d + T` in a
4-cycle window: mode-2-first families (m2int_m2irq, late_m0irq_retrigger)
say 16 < d + T < 20; LYC-, mode-1- and timer-first families say
20 < d + T < 24. Pan Docs, "Interrupt Handling": the dispatch is five
M-cycles, the fifth setting PC.

**Modelled.** `IRQ_SAMPLE_T = 18` (cpu.nim; the bracket is at the constant:
16 loses the two mid-M-cycle sources, 19 loses
`late_m0irq_retrigger_scx1_1`, 20 also `m2int_m2irq_late_retrigger_1`).
`IRQ_SAMPLE_T_DS = 18` (the values on each side fail; at the constant).

One clear cannot sit in both windows. So the two groups of sources reach the
dispatch one M-cycle apart, relative to the instant their IF bit rises, with
the mode-2 source the early one. dingbat raises the mode-2 source one
M-cycle before the line boundary (`STAT_M2_LEAD`), the LYC and mode-1
sources on it, and dispatches the timer one M-cycle ahead of its IF bit
(`TIMER_IRQ_RUN_LEAD`). The retrigger tests wanted one M-cycle more between
rise and dispatch for the timer, LYC and mode-1 sources, or one less for the
mode-2 source, without moving where any of them is read back (the absolute
`m2int_*`, `lycint_*`, `tima/*` tests were already green).

The per-source knobs: `STAT_M2_LY0_LEAD`, `STAT_M1_LEAD` and
`VBLANK_IRQ_LEAD` = 1, the vblank-line rule `LYC_STEPPED_VBLANK_SHUT`
(docs/dev/gb-derivations.md, "The comparator's LY steps two dots before the
line boundary"), and the CGB's later clear of its timer and serial lines,
`IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD` = 2 (ibid., "A CGB clears a timer or
serial request at the end of the dispatch").

### A3. A STAT source enabled, disabled or handed over across a line edge

**Closed.** The STAT line is a level OR of four sources into one edge
detector, and a disable, an LYC write and each source's rise and fall are
evaluated on their own dots (`stat_drop_arm`, `STAT_LYC_LY_LEAD_DOTS`,
`M2_PULSE_END_EDGE`, `CGB_LINE_END_STEPS`, `M2_144_EARLY_DOT_DS`; ppu.nim,
gb.nim; docs/dev/gb-derivations.md sections 1 and 7).

**Behaviour.** An interrupt fires only when the OR rises from zero
(Pan Docs, "LCD Status Register", STAT blocking; mooneye
`acceptance/gpu/stat_irq_blocking` is green). These families write STAT or
LYC one M-cycle per member across a line boundary and ask whether the
enable, the disable or the hand-over from one source to another produced an
edge. No Pan Docs sentence gives these dots; the evidence is the families
themselves, read with `famflip.py` and `-d:gb_stat_src_trace` (it names the
source on every rising edge; its `STATW` line is each STAT write's commit
dot).

**Modelled.** The level-OR edge detector; `LY_BLIND_SCOPE = 2`; `STAT_M2_LEAD
= 1` (DMG and CGB alike — GBMicrotest `oam_int_if_edge_{a..d}` put the CGB
exact and the DMG a cycle late); `STAT_M2_PULSE = 3` and the line-144 OAM
pulse (`M2_144_PULSE`); `lyc_compare_hold` (CGB D+ hold the comparison the
blind window is leaving); `STAT_ENABLE_LATENCY = 0` and
`CGB_STAT_ENABLE_LATENCY = 2`.

The families, each a separate rule:

* `m2enable/late_enable_*_2`, `lyc1_m2irq_late_lyc255_*`,
  `late_{enable_,}m1disable_ly0_2`, `lyc0_late_m2enable_lycdisable_2` (9):
  the OAM source enabled one M-cycle across the line boundary it rises on.
  `STAT_M2_LEAD = 1` puts the rise one CPU M-cycle before the boundary.
* `m1/ly143_late_m{0,2}enable_*`, `m1irq_late_enable_*`,
  `m1irq_m0disable_2`, `m1irq_enable_after_lyc144_2`,
  `lycint143_m1irq_late_retrigger_2`, `lycint_vblankirq_late_retrigger_2`,
  and the CGB cases `m1irq_m2enable_lyc_2`,
  `lyc143_late_m2enable_lycdisable_ds_1`, `m2m1irq_ifw_ds_1` (13): the
  mode-1 / mode-2 / LYC hand-over at the top of line 144 (rule 4 below).
* `lycEnable/lyc153_late_*`, `lyc0_m1disable_*`, `lcdoff_lycirqen_*` (15):
  the LYC = 153 and LYC = 0 sources around the LY 153 -> 0 snapback
  (`LYC_SRC_RELATCH_LEAD = 1`, `LYC_SETTLE_DOTS`), and LYC armed while the
  LCD is off.
* `lycEnable/ff45_enable_weirdpoint_*`, `late_ff45_enable_*`,
  `late_ff41_enable_*` (14, all CGB but two): a CGB takes an LYC write one
  M-cycle later than a DMG (`CGB_LYC_WRITE_DEFER`, wilbertpol
  `ly_lyc*_write-C` vs `-GS`). The `lcdoffset1` members ask whether that is
  4 dots or 2. Neither: the write lands 2 dots in and is sampled on a 4-dot
  grid of the PPU's (docs/dev/gb-derivations.md, "CGB LYC write: a sampled
  comparator"). The `ff41` members are the CGB line end's (ibid., "A CGB
  STAT write across a line's end"). Closed 2026-11-12.
* `miscmstatirq/*wirq_trigger*` (7): a STAT write's enable bits reaching the
  line (`STAT_ENABLE_LATENCY = 0`, `CGB_STAT_ENABLE_LATENCY = 2`; the 2 is
  pinned by `m0enable/disable*_2 [cgb]` against `m0enable/disable_scx*_1`).
* `m2int_m0irq/m2int_m0irq_scx3_ifw_{2,4}` and
  `ly0/lycint152_lyc153flag_ds_3`: not recorded.

The rules that closed it:

1. *The coincidence bit's readback at a double-speed line edge.*
   `lycint_lycflag_ds_3`, `ly0/lycint152_lyc0flag_ds_3` and
   `enable_display/frame{0,1}_m2stat_count_ds_1` read STAT in the M-cycle LY
   steps in. At double speed how long the bit still compares against the
   line being left is `LYC_JUST_CHANGED_HOLD_DS` (dots, ppu.nim; 2).
   `lycint152_lyc153flag_ds_3` is `LYC153_HOLD_DS = 1`.

2. *A disable is an edge's other half.* The line used to be re-evaluated
   only at source changes and at the M-cycle boundary a STAT write's byte
   waits for. So a write whose cleared enable bits took the line low inside
   its own M-cycle, followed by another source rising before the boundary,
   gave no edge. `-d:gb_stat_read_trace` on `m2enable/m2_late_m0disable_1` shows the $28 ->
   $20 write committing on dot 449 and the mode-2 rise at 452 with no
   interrupt. Now a STAT write samples the line under its new enables at the
   commit, plus the CGB's 2-dot latency, and lets it fall there
   (`stat_drop_arm`, ppu.nim). A rise inside the latency window refreshes
   the sample. It took `m2enable/{m2_late_m0disable, late_enable_m0disable,
   late_enable_after_lycint_disable, lyc1_m2irq_late_lycdisable}_1` and
   their `_ds_1` twins, `m0enable/lycdisable_ff41_*` (7),
   `lycEnable/lyc{0,153}_late_{enable_,}m1disable_2 [dmg]` and
   `lyc153_m1disable_ds_1`. On its own it lost
   `lycEnable/lyc153_late_{enable_,}m1disable_2 [cgb]`: their LYC = 153 rise
   meets a mode-1 disable landing on the latency's last dot and still
   blocks. A strict `>` loses six other CGB tests instead, so that source's
   latency is one dot longer than the mode-0/2 sources', not the rule's
   edge. Both pass now.

3. *The same for LYC writes.* An LYC write that breaks the match is the same
   disable through the comparator (`LYC_DROP_LATENCY_DMG` = 1 dot and
   `LYC_DROP_BOUNDARY_SKIP` = 1, ppu.nim). The CGB's drop is the
   comparator's sample since 2026-11-12 (docs/dev/gb-derivations.md, "CGB LYC
   write: a sampled comparator"). Tests:
   `m0enable/lycdisable_ff45_{3, scx1_2, scx2_2} [dmg]`,
   `lycdisable_ff45_scx{1,2}_1 [cgb]`, `lycdisable_ff45_scx1_ds_1` [cgb],
   `m2enable/lyc1_m2irq_late_lyc255_{1 [cgb], 2 [dmg]}`.

4. *The line-144 OAM pulse holds through the boundary.* The pulse used to
   go low for the instant between the LY advance and the mode-1 set inside
   `ly_advance_vblank_entry`. The comparator's drop there was then a dip,
   and the mode-1 rise a false edge whenever LYC = 143 had held the line
   (`m1irq_m2enable_lyc_1`, `m2m1irq_ifw_2`, `m1irq_m2disable_lycdisable_3`,
   `lyc143_late_m2enable_lycdisable_2` and `_ds_2` twins, both devices).
   `m2_line144` now holds through the boundary. The three CGB cases left
   after it are the same tests one M-cycle later: the CGB write's enable
   lands 2 dots after its commit (`CGB_STAT_ENABLE_LATENCY`). They pass.

5. *The comparator's LY steps before the boundary*
   (`STAT_LYC_LY_LEAD_DOTS` = 2, `STAT_LYC_LY_LEAD_DS` = 0,
   `fifo_lyc_ly_lead`; docs/dev/gb-derivations.md, "The comparator's LY steps
   two dots before the line boundary", which lists the tests on each side).
   The CGB line end (`CGB_LINE_END_STEPS`, ibid., "A CGB STAT write across
   a line's end") runs at the comparator's step.

6. *The OAM pulse's falling edge* (`M2_PULSE_END_EDGE`; docs/dev/gb-derivations.md,
   "The STAT line falls where a line's OAM pulse ends"), taken at the next
   CPU write that looks at the line: `lycEnable/late_ff41_enable_after_m2int`
   and `_after_m2int_disable` (both devices).

7. *The CGB's last-M-cycle mode-2 enable*
   (`m2enable/late_enable_m0disable_2 [cgb]`): step 4 of the CGB line end
   (`CGB_LINE_END_STEPS`; docs/dev/gb-derivations.md, "A CGB STAT write across a
   line's end"). Closed 2026-11-12.

8. *The line-144 pulse at double speed.* The last test,
   `m1/ly143_late_m2enable_ds_lcdoffset1_1`, rests on the double-speed
   line-144 pulse's rise dot (`M2_144_EARLY_DOT_DS` = 454: one double-speed
   M-cycle before the line ends) and an IF read's tie with it
   (`IF_READ_M2_144_TIE_DS` = 0: `enable_display/frame{0,1}_m2irq_count_ds_2`
   pass without it).

Tried and rejected: the whole-suite joint moves of the double-speed grid
(`SPEED_SWITCH_PPU_EXTRA_DOTS` 7/9 with `STAT_READ_SAMPLE_DS_ADD` 0/2: -86
to -280) and of the to-single switch residual
(`SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE` -1, 0, 1, 2, 4, 5, 7: each loses
26..34 `speedchange*_ly44_m3*` ladder tests and takes no `lcd_offset`
test).

The knob sweep of 2026-09-22 tried `+-1` of every GB `{.intdefine.}` (206
knobs), failing tests first, with every hit validated on the full 5157-test
list from a snapshot build. It found no net-positive value. Re-run at 5176
(519 variants, all 5216 tests): only `MIXER_PALETTE_OR = 0` (C7) comes out
positive.

### A4. Mode-0 STAT interrupt against a timer interrupt

**Closed.** The dispatch writes PC in its fourth and fifth M-cycles and
picks the vector between the two (`DISPATCH_PUSH_MCYCLE`, cpu.nim;
docs/dev/gb-derivations.md, "The dispatch pushes in its fourth and fifth
M-cycles"). Tests: `irq_precedence/late_m0irq_vs_tima_*`, both devices.

### A5. Halt-woken readers of the mode-0 edge

**Closed.** A halted CPU latches the interrupt line at a different point of
its M-cycle from a running one; the rules are below (cpu.nim;
docs/dev/gb-derivations.md section 7).

Tests: `oamdma/oamdma_late_halt_stat_2` (both devices),
`oamdma_late_speedchange_stat_2`, the eight `halt/` tests
(`late_m0{int,irq}_halt_m0stat_scx{2,3}_*`) and `noime_m2irq_m0stat_1 [cgb]`.

**Behaviour.** The mode-0 source's rise sits mid-M-cycle at some SCX.
GBMicrotest's `int_hblank_{nops,halt}_scx*` pairs put the halt one M-cycle
after the sled for the two sources that do not rise on a line boundary (OAM,
hblank) and level for the two that do (LYC, vblank).

**Modelled.**

* `HALT_IF_SAMPLE_T = 4`: the running CPU's point. 2 was measured and is off
  by default; its cost is +4.8% of retired instructions on a halting main
  loop (cpu.nim).
* `M0_HALT_BLIND_DOTS = 2` (DMG): the last 2 T-cycles of a halted M-cycle
  cannot see the mode-0 rise (wilbertpol `hblank_ly_scx_timing-GS` vs `-C`).
* `CGB_HALT_PPU_LEAD = 1`: a halted CGB's PPU runs one M-cycle behind and
  gets it back at the wake (gambatte `halt/lycirq_m2stat_{1,2,3}`,
  `halt/m1int_ly_{1,2,3}`, `cgb-acid-hell`).
* `M2_LEAD_HALT_BLIND`: a halted CPU is blind to `STAT_M2_LEAD` (mooneye
  `intr_2_*` vs wilbertpol `*_nops`).
* `HALT_IME_PENDING_REDO`: a HALT with IME on and an interrupt already
  pending pushes the HALT's own address (the `halt/` `_3a`/`_3b` tests).
* `DMG_HALT_MIN_MCYCLES = 2`: the halted M-cycles a DMG spends before a
  pending interrupt can end the HALT (`_2b`).
* `M2_LEAD_HALT_BLIND_DMG_ONLY = 1`: the `M2_LEAD_HALT_BLIND` blindness is
  the DMG's alone (`noime_m2irq_m0stat_1 [cgb]`).
* `oamdma_late_speedchange_stat_2` takes two rules together: the OAM DMA
  unit is released under the stall (`OAMDMA_FROZEN_RELEASE`) and the CGB
  fetches objects with LCDC.1 clear (`CGB_OBJ_FETCH_OFF`, `obj_fetch_on`,
  fifo_ppu.nim). `oamdma_late_halt_stat_2`: not recorded.

Values tried: `CGB_HALT_PPU_LEAD_DOTS` 1..4, `CGB_HALT_EXIT_MCYCLES` and
`HALT_IF_SAMPLE_T` were swept, and none separates `scx2_3a` from `scx3_2b`.

One comparison, from a differential run of the GBMicrotest question through
`tools/gbppu/gam_dispatch.py` and `gam_haltwake.py` (a second-emulator
harness, so a comparison and not evidence — `docs/dev/oracles.md` policy):
dingbat's mode-0 edge reads 2 dots late on steady-state lines when running
and 2 dots early on the first post-LCD-on line when halted, two errors that
cancel in the halted steady state (`M0_HALT_BLIND_DOTS`). The hardware
questions for it are hwprobe rows 2 and 10 (`docs/dev/hwprobe-questions.md`).

---

## B. The line after an LCD enable, and the boot hand-off

### B1. Line 0's mode edges are 2 dots later than the counter says

**Closed.** After an LCD enable, line 0's mode-3 edges sit 2 dots later
against the CPU's grid than on any later line (`LCD_ON_LINE0_LOCK_LEAD = 2`,
`LCD_ON_STAT_READ_LAG = 2`; ppu.nim). AGE `oam/oam-write-dmgC` is scored
and passes (2026-11-16).

Tests: AGE `oam/oam-read-dmgC-cgbBC@dmgC`,
`oam-read-cgbE`, `vram/vram-read-{dmgC, cgbBCE@*}`; gambatte
`enable_display` 15 (`ly0_late_vram{r,w}_*`, `ly0_late_scx7_m3stat_*`,
`frame{0,1}_m{0,2}{irq,stat}_count_*_ds_1`,
`enable_display_ly0_sprites_m0stat_2`, `ly0_oambusy_read_ds_1`) and
`lcd_offset` 19 (all CGB). Where no rule below names a test: not recorded.

**Behaviour.** After `LCDC.7` goes high the first line starts in mode 0.
Four independent measurements in AGE's `oam-read`/`vram-read` pair
agree on the 2 dots: the mode-3 open and close edges, each on a DMG and a
CGB (table at `LCD_ON_LINE0_LOCK_LEAD`, ppu.nim). The pair is the same ROM
with one address changed, so every phase question cancels. mealybug's
harness says the same from the pixel side — `line_0_fix` burns 4 T-cycles
fewer on LY 0 (`docs/dev/gb-mealybug-sources.md` §1.2). `lcd_offset`'s
`*_count_*` families are a 1-dot-per-SCX coincidence ruler for the STAT
raise dot. Read them to ±1 dot only, because
`offset1_lyc99int_m0{stat,irq}_count_scx1_ds` — flag and IRQ of one edge —
demand opposite parities.

**Modelled.**

* `LCD_ON_HEAD_START = 5` (DMG) / `CGB_BOOT_PHASE = 165` (CGB; gambatte
  `display_startstate/stat_*`, all 12) seed the first line. `CGB_BOOT_PHASE`
  161 -> 165 closed `display_startstate/stat_*_2 [cgb]` (4), and no other
  test felt it.
* `LCD_ON_LINE0_LOCK_LEAD = 2` spends the 2 dots in the VRAM and OAM locks
  only. `LCD_ON_STAT_READ_LAG = 2` spends them in the STAT read.
* `LCD_ON_LINE0_TRIM` and `LCD_ON_LINE1_TRIM` (the geometry fix) default to
  0. `=2` moves the pixel tests, the mode-0 SOURCE tests and mooneye
  `lcdon_{,write_}timing-GS`, and is far worse whole-runner.
* The lock edges themselves: `VRAM_READ_M0_OPEN_DOTS = 2` (3 at DS),
  `OAM_READ_M0_OPEN_DOTS = 2`, `OAM_READ_M3_CLOSE_DOTS = 5`, and
  `oam_read_open_late` (CGB-E's OAM lock reopens a dot later; AGE
  `oam-read-cgbE` vs `-dmgC-cgbBC`).
* `LCD_ON_LINE_NO_SCAN`: the LCD-on line has no OAM scan and no objects
  (`enable_display_ly0_sprites_m0stat_2`, both devices;
  docs/dev/gb-derivations.md section 3).
* `SCX_LATCH_LCDON_EXTRA{,_CGB}` = 1 / 2: the LCD-on line takes an SCX store
  for longer (`ly0_late_scx7_m3stat_scx0_2` [dmg], `_scx1_1` [cgb]).
* `VRAM_WRITE_LINE0_CGB_GRACE = 1`: the CGB's VRAM write lock closes late on
  the LCD-on line (`ly0_late_vramw_2` [cgb]).
* `LCDON_M0_LAG_DS` (gb.nim) = 8 scheduler cycles, one double-speed M-cycle:
  at double speed the LCD-on line's mode-0 source trails its flag
  (`ly0_m0irq_scx{0,1}_ds_1`, `frame0_m0irq_count_scx{2,3}_ds_1`).

**The OAM write lock.** AGE `oam-write-cgbBCE@*` (3 cases) and gambatte
`oam_access/{mid,pre,post}write*` (5 tests) were not line 0 at all. A CPU
write to OAM asked the lock at the START of its M-cycle while a read asks
after the dots, and the lock's edges lag the mode flag. The edges were read
at 1-dot-per-SCX resolution off the ROM's 12-write ladder (WRAM `$C000`, one
byte per write; `tools/gbfuzz/sameboy_wram.c`'s dingbat twin). Sampled after
the dots, the open edge is flag + 2 (+3 double speed), exactly the read
side's. The LCD-on line adds its 2-dot lead, and the CGB's LCD-on close is
flag + 2..5. The DMG shares the open edge but locks later: a write sampled
at dot 1 of a line lands and one at dot 5 does not, and the lock lets go
again over the 2 -> 3 edge (dot 81 lands, 85 does not). Evidence: gambatte
`midwrite_2`/`prewrite_2` (`dmg08_out1_cgb04c_out0`), GBMicrotest
`oam_write_l0_e`/`l1_c`, mooneye `lcdon_write_timing-GS`. Knobs:
`OAM_WRITE_*` (gb.nim, ppu.nim).

`oam-write-dmgC` was in `NotScored` from 2026-09-21 (its delay-2 line,
which the ROM's author marks as depending on when the LCD was last switched
off, failed, and the AGE emulator's own runner blacklists the ROM); it
passes whole on DMG C and is scored again since 2026-11-16. Gambatte
`prewrite_lcdoffset1_1` [cgb] passed only because the start-of-cycle sample
cancelled the `lcdoffset1` phase error the `preread_lcdoffset1_1` row still
shows.

**The double-speed mode 2 read lock on CGB 0..C.**
`oam-read-dmgC-cgbBC@{cgbab,cgbc}` failed on one line. At double speed a
read sampled at dot 1 of a line is served on CGB B/C (`EFF` = $00 in that
ROM) and refused on CGB E (`EFF` = $FF in `oam-read-cgbE`); dot 3 is refused
everywhere. `OAM_READ_M2_LAG_DOTS_DS = 2` (ppu.nim), keyed off the same
revision split as `oam_read_open_late`. 3 loses gambatte
`preread_ds_lcdoffset1_2`, and 2 takes `preread_ds_1` [cgb].

### B2. The CGB palette-RAM lock's edges

**Closed.** The palette-RAM lock is a dot window around the mode-3 and
mode-0 edges (`CRAM_LOCK_DOTS`, `cpu_cram_open_dots`; ppu.nim;
docs/dev/gb-derivations.md, "The CGB palette RAM lock around the mode-3
edges").

Tests: `cgbpal_m3/cgbpal_m3end_{1,3}`, `_ds_{1,3}`, `_scx5_ds_{1,3}`,
`cgbpal_m3start_ds_1`, `cgbpal_{read,write}_m3start_{ds,lcdoffset1}_1`;
`enable_display/ly0_late_cgbp{r,w}{,_ds}_2`.

**Behaviour.** BCPD/OCPD belong to the PPU during mode 3: reads answer
`$FF`, writes are dropped with the auto-increment still taken (Pan Docs,
"Palettes", CGB). gambatte puts the lock's edges one M-cycle later than the
VRAM lock's on the read side. The `_ds_`/`lcdoffset1` members and the
`m3end_1/_3` pairs ask for the edge in dots, as C1 does for VRAM.

**Modelled.** `CRAM_LOCK_DOTS = true`
(`cpu_cram_open_dots`): the lock is a dot window, closed from
`CRAM_LOCK_ON_LAT{,_DS}` = 1 / 2 dots after the mode-3 edge until
`CRAM_LOCK_OFF_LAT{,_DS}` = 2 / 3 dots after the mode-0 edge (the VRAM read
lock's open edge), `CRAM_LOCK_LINE0_EXTRA` = 2 dots later on the LCD-on
line. Brackets per knob in docs/dev/gb-derivations.md section 7. The
single-speed close edge is one dot after the VRAM lock's: an M-cycle that
starts on mode 3's first dot still reads the palette
(`cgbpal_read_m3start_lcdoffset1_1`) and no longer reads VRAM
(`vram_m3/preread_lcdoffset1_2`).

---

## C. Mode 3: locks, window, scroll, objects, palettes

### C1. The VRAM and OAM locks at mode 3's two ends

**Closed.** The CPU's VRAM and OAM access windows open and close on PPU
dots, not on the CPU's M-cycle boundaries (the knobs under "Modelled";
memory.nim, ppu.nim).

Tests: `oam_access/{postread_scx{2,3,5}_2,
10spritesprline_postread_2, postwrite_2_scx3, midwrite_2,
prewrite_{2,ds_2,ds_lcdoffset1_2}, preread_{ds,lcdoffset1}_1}` and
`vram_m3/{postread_scx{2,3}_2, 10spritesprline_postread_2,
preread_lcdoffset2_1, prewrite_lcdoffset2_1}`. Some are named under B1 and
in docs/dev/gb-derivations.md, "The comparator's LY steps two dots before the
line boundary"; the rest: not recorded.

**Behaviour.** Pan Docs, "Accessing VRAM and OAM". The `postread_*_2` tests
read one M-cycle after the mode 3 -> 0 edge at SCX 2/3/5 or with ten objects
and want the lock open. `prewrite`/`preread` ask the close edge at mode 3's
start on CGB and in double speed.

**Modelled.**

* Open edge: `VRAM_READ_M0_OPEN_DOTS = 2` / `_DS = 3`,
  `OAM_READ_M0_OPEN_DOTS = 2` / `_DS = 3` (from AGE, B1).
* Close edge: `VRAM_READ_LIVE_LOCK = 2` (the DMG's read lock asks the live
  mode, the CGB's the latched one; gambatte
  `vram_m3/preread_2_dmg08_out3_cgb04c_out0`), `OAM_READ_M3_CLOSE_DOTS = 5`.
* Writes ask the live mode at their commit point (`OAM_WRITE_M2_TAIL = 1`:
  the last M-cycle of mode 2 still takes an OAM write; mooneye
  `lcdon_write_timing-GS`).
* A VRAM write issued in mode 3 asks the lock `VRAM_WRITE_M3_END_DOTS` = 3
  dots into its M-cycle (`_DS` = 0; memory.nim, both strict optima on
  `vramw_m3end/*`): `vramw_m3end_scx3_5` (both devices).
* On a CGB at single speed the close edge is in dots too: an M-cycle that
  starts on mode 3's first dot is locked for a read and for a write
  (`VRAM_READ_CGB_M3_EDGE_SS = 4`, `VRAM_WRITE_CGB_M3_EDGE_SS = 80`, ppu.nim;
  `vram_m3/{preread,prewrite}_lcdoffset{1,2}_{1,2}` pin both to the dot;
  docs/dev/gb-derivations.md section 1).

### C2. The window's mode-3 penalty near the right edge

**Closed.** Mode 3 ends `m3_lead` (2) dots before the last pixel would leave
the shifter, and a window restart delays that pixel by a fetch, so the flag
falls at hit + 5 + (159 - lx) wherever the match lands — a flat six dots
(`WIN_TAIL_FLAG_LEAD`, gb.nim).

**CGB and WX 165.** dingbat's tail waited for the restarted fetch's push
instead: +1 at WX 165, +2 at WX 166. The `-d:gb_m3_trace` dots at
246/248/249 for WX 163/165/166 all retire on 254 under the rule. Refuted: a
three-way conflict with AGE `stat-mode-window/*`. gambatte
`m2int_wxA6_m3stat_3` [cgb] wants mode 0 by its third read, so the CGB's
WX = 166 line is 178 dots there too; 180 was dingbat's number, not
hardware's. Tests: AGE `stat-mode-window-{cgbBCE,ds-cgbBCE}@*`; gambatte
`m2int_wxA5_m0irq_2` (both devices),
`m2int_wxA6_{,firstline_,scx5_}m3stat_3` [cgb],
`m2int_wxA6_{,scx5_}m3stat_ds_2`, `m2int_wxA6_vrambusyread_3` [cgb]. Nothing
lost.

**DMG WX 166.** AGE `stat-mode-window-dmgC` read the DMG's carried WX = 166
line (`DMG_WIN_LAST_PX_CARRY`) as 173 against AGE's 172, the same value as
WX 167. `fetch_work_pending` held mode 3 for the carried line's own match,
citing gambatte `m2int_wxA6_m3stat_1` [dmg] as wanting "174, not 172". With
the term deleted that test still passes, `m2int_wxA6_scx3_m3stat_2` [dmg]
joins it, and nothing in `window/`, mealybug or the `on_screen` frames
moves.

**The `spxA7` CGB tests.** `m2int_wxA6_spxA7_{m3stat_2,m3stat_4}`:
`CGB_OBJ_LAST_PX_YIELDS` (the CGB's last-pixel object waits for the window
start and holds only the mode flag; docs/dev/gb-derivations.md, "The last
pixel: object against window on a CGB"). `m2int_wxA6_spxA7_m0irq_2` [cgb]
and its object-less twin `m2int_wxA6_m0irq_2` [cgb]: the mode-0 request's
own rule, which does not wait for work that starts on the last pixel
(`M0_REQ_LAST_PX`, docs/dev/gb-derivations.md section 1).

### C3. Mid-line SCX stores

**Closed.** The map column's borrow is measured against the pixels the
discard threw away, a wrapped pass included (`SCX_WRAP_BORROW`,
docs/dev/gb-derivations.md section 4); the three `spx2` tests are not scored
(`gambatte_row_reads_powerup_objpal`).

Tests: the seven `scx_0761c0` tests [cgb]; `scx_during_m3_spx2{,_ds}` and
`scx_attrib_during_m3_spx2_ds` (8 px each, CGB; not timing, see below; in
NotScored since 2026-10-14).

**Behaviour.** The BG fetcher's map column is a live sum
`((SCX + 8k - F) shr 3) and 31`. A store that lowers `SCX and 7` below the
line's latched fine scroll borrows one tile (`SCX_FINE_BORROW`; the DMG
borrows one pixel tighter, `SCX_FINE_BORROW_DMG_LEAD`; AGE `m3-bg-scx` ×3
exact). The fine-scroll discard is a slot counter compared each dot against
the live `SCX and 7`. A store landing above the new value but at or below
the old one is matched only after the counter wraps and runs eight more
slots (`SCX_FINE_LATCH_WRAP = 8`; gambatte `scx_m3_extend_{ds_1,ds_2}` write
SCX twelve times on one line and pin the edge to two dots).

**Not modelled.** Each fetcher stage as two T-cycles with the address latched
in the first and the read in the second, and per-model visibility of an SCX
store inside its own M-cycle — `Assumed; no ROM in the tree pins either`,
and `CGB_SCX_LATENCY = 2` is the one term carried. The `scx_0761c0` tests
that were last to close are at `F = 7`, where every store lowers the target.
`spx2` is an object fetch under a store. Hardware experiment (b) below would
measure the extension law directly; `tools/gbppu/m3len.sh` / `-d:gb_m3_len`
give dingbat's side.

**The three `spx2` tests are not timing.** Pixel 0 is the object's column 6
in OBJ palette 0 colour 2, which the ROM never writes. dingbat fills `$FF`
there, and the reference's colour is a word no ROM write sets (the same
class as the `oamdma_src{FE00,FF00}` WRAM tests in NotScored).

Verified link by link 2026-10-14:
- *ROM.* Source and binary agree: one object (OAM 0: Y `$10`, X `$02`,
  tile 0, attribute `$00` = CGB palette 0, VRAM bank 0, no flip). Tile 0
  rows are `$00,$7E`, so column 6 is colour 2 and column 7 colour 0; X = 2
  puts column 6 at screen x = 0 on lines 0-7 (8 px). The only palette writes
  are BCPS `$80` and eight BCPD bytes (BG palette 0 = `$0000 $5294 $2108
  $7FFF`); no OCPS/OCPD store exists in any of the three binaries. `spx1`
  (column 7, transparent) and `spx0` show no object pixel and pass. The
  `attrib` twin leaves VBK = 1, which moves the BG map writes, not the object.
- *Frames.* The 8 differing pixels are exactly x = 0, y = 0..7. The
  reference has (33,146,108), which is `$4261` (r1 g19 b16) through the
  suite's CGB colour conversion and is no BG colour (all four are grey).
- *Geometry.* A scratch build that put `$4261` in that one word passes all
  three rows (9/9 of the spx family), so dingbat's object/SCX timing already
  matches the reference pixel for pixel. SameBoy (CGB C, its own boot ROM)
  draws x = 0 in its seeded-random OBJ palette 0 colour 2; forcing that word
  to `$7FFF` makes its frame identical to dingbat's on all three. Three cores
  agree on everything but the uninitialised word.
- *Boot ROM.* The CGB boot ROM disassembly (ISSOtm gb-bootroms `cgb.asm`)
  writes OBJ palette RAM only in two places: `CommitBGPalettes` writes byte 0
  alone (its own comment: the rest stay random on hardware), and the DMG-
  compat branch writes OBP0/OBP1's 16 bytes. These carts are CGB (`$143` =
  `$80`/`$C0`), so bytes 4-5 are untouched. Pan Docs, "Palettes": "In CGB
  mode, the boot ROM leaves all object colors uninitialized (and thus
  somewhat random/unreliable), aside from setting the first byte of OBJ0
  color #0 to $00". SameBoy's reimplemented boot ROM writes OBJ palettes
  only on its DMG-compat path, and its core randomises them at power-on.
- *dingbat.* gambatte tests run skip-boot (`run_bios = false`); the CGB
  hand-off fills all 64 OBJ bytes with `$FF` (`ppu.nim:148`, CGB-native branch of
  the boot phase). Byte 0 should be `$00` per the boot ROM; it is colour 0,
  never displayed, so no test can see it except through an OCPD read.
- *DMG half.* Its x = 0 pixel is the same object through OBP0, which no
  boot ROM writes either (Pan Docs lists OBP0/OBP1 as uninitialised, "most
  often $00 or $FF"). dingbat's DMG `$FF` (`memory.nim` skip-boot; see
  docs/dev/oracles.md) gives black, as the reference does, so that half passes;
  it leans on the same kind of byte, but one with a common value, where the
  CGB word is 15 bits of SRAM noise.

A hardware capture would settle it for that unit only: the word is power-on
SRAM content, so a second console would give a different colour. The tests
are in NotScored instead of seeding the table.

### C4. Objects: the X = 167 slot and the CGB's fetch cancel

**Closed.** A CGB fetches objects with LCDC.1 clear
(`CGB_OBJ_FETCH_OFF`, with `OAM_SCAN_DMA_EDGE_DS`; see D2), which closed
`sprites/late_disable_ds_1 [cgb]` and `sprites/enable/late_disable_ds_3
[cgb]`. `sprites/10spritesPrLine_10xposA7_m0irq_2` (both devices; ten
objects at OAM X = 167): not recorded.

**Behaviour.** An object at X = 167 triggers on the line's last pixel and
shares the fetch slot with the tail burst (`OBJ_TAIL_WALK_REFUND`, pinned by
the single-object `xposA7` tests). Clearing LCDC.1 while an object fetch is
in flight cancels it on the DMG (Pan Docs, "Mode 3 Length": the fetch is
abandoned; mealybug `m3_lcdc_obj_en_change_variant` and gambatte
`sprites/sprite_late_*_disable_*` pin the refund, `OBJ_ABORT_LEAD = 2`,
`OBJ_ABORT_FLAG_HOLD`). `CGB_OBJ_ABORT = 0`: the CGB reference of the same
mealybug ROM wants the full penalty. That one test cannot separate "no
cancel" from "LCDC.1 reaches the CGB fetcher later"; the two `_ds` tests
are the double-speed members that could.

### C5. Arming the window late through WY

**Closed.** The WY comparator is sampled, not a level: once per line and
a few dots after a WY write or an LCDC.5 enable, with a cut-off at the
line's end (`WIN_LINE_CHECK_DOT_SS`, `WIN_CHECK_DEFER_*`,
`WIN_CHECK_CUT_DOTS`, `WIN_HEAD_LATE_DOT`, `win_check_now`;
docs/dev/gb-derivations.md, "The window's WY comparator: when it samples").

Tests: every `window/arg/late_wy_*`, `late_scx_late_wy_*` and
`late_enable_afterVblank` test, the `lcdoffset1` ones included.

**Behaviour.** The WY condition is a latch set on the first line where
`LY == WY` while the window is enabled and held for the frame (Pan Docs,
"Window"; `docs/dev/gb-derivations.md`, "the window starts on an equality, and
the WY latch is a level"). On the DMG every test that failed was an "arm
late" ROM (WY written to LY in the handler, `FFto*`, `10to*`,
`late_enable_afterVblank`) and every "disarm late" ROM (`1toFF`, `2toFF`)
passed. So the arm deadline is a rule of its own and not a symmetric latch
dot. The CGB's deadline is one M-cycle earlier than the DMG's in 13 of 14
families.

**Modelled.** The level latch; `CGB_WY_LATENCY = 4` (one M-cycle, clipped to
3 dots by `CGB_LATENCY_CAP = 1`), `CGB_WY_LATCH_LATENCY = 0`.

**The sample points.** The comparator is sampled, not a level: once per
line, one dot into the line at single speed and on its first dot at double
speed (`WIN_LINE_CHECK_DOT_SS = 1`; dot 5 of line 0 on a CGB), and
`WIN_CHECK_DEFER_DMG = 1` / `_CGB = 5` / `_CGB_DS = 1` dots after a WY write
or an LCDC.5 enable, except from the dot the LY = LYC comparator's LY steps
to the next line (`WIN_CHECK_CUT_DOTS = 2`, dot 454; `_DS = 3`); a match up
to dot `WIN_HEAD_LATE_DOT = 85` (+ SCX & 7) still makes a WX < 6 line a
window line. Schedule, tests and the values on each side:
`docs/dev/gb-derivations.md`, "The window's WY comparator: when it samples".

### C6. Window disable and re-enable mid-line on the CGB

**Closed.** Clearing LCDC.5 mid-mode-3 returns the fetcher to the background
at its next map read, and a CGB window start is revocable for the dots it
has run (`WIN_EN_ABORT = 1`, `CGB_WIN_REVOKE_LAG = 1`, `CGB_WIN_EN_DEFER =
5`, `DMG_WIN_EN_REVOKE = 1`).

Tests: `window/late_disable_scx5_ds_1` (`WIN_REVOKE_DS_PUSH`),
`late_reenable_scx3_2` (`CGB_WE_ENABLE_LATE`), `late_wx_scx3_2`
(`CGB_WX_LATE_SS`), `window/on_screen/wx17_weoff_wxA5_weon [cgb]`
(`CGB_WE_DISABLE_LATE`), `window/on_screen/wxA6_late_we_reenable_3 [dmg]`
(`WIN_CARRY_HEAD_DROP`). docs/dev/gb-derivations.md, "LCDC.5 and WX reach a
CGB's window logic late" and "A carried window start against LCDC.5 low".

**Behaviour.** The LCDC.5 rule is from mealybug's PPU notes (DMG and
CGB). `wxA6_late_we_reenable_3`'s extra window line was not the line
counter's: the start carried over vblank met LCDC.5 low at line 0's head
(dot 82, bit back on dot 85) and was spent on line 1, where hardware has
lost it (`WIN_CARRY_HEAD_DROP = 1`).

### C7. The DMG BGP transition pixel

**Closed.** On gambatte's DMG png tests the scorer accepts the reference's
clean old or clean new colour at a pixel dingbat painted as a transition;
the model is unchanged (test-harness-only `GbRacePx` list, ppu.nim;
`gambatte_batch` in tests/dingbat_test.nim).

Tests (8): `dmgpalette_during_m3/dmgpalette_during_m3_{3,4,5,scx1_4}`,
`lycint_dmgpalette_during_m3_{3,4}`, `scx3/dmgpalette_during_m3_{4,5}` —
144 wrong pixels = one per line, or 1. Every one of those pixels was a
transition pixel holding a clean colour in gambatte's reference.

**Scoring (2026-10-14).** mealybug/AGE/daid stay exact. Every other pixel of
the frame is still compared exactly. Why: gambatte's DMG references are
framebuffer dumps of an emulator without the race (below), and a hardware
photo shows the OR outcome at the exact configuration of `_4`. So the
reference's clean edge is one emulator's choice at a pixel where the
hardware races, not a hardware result. The verdict line reports how many
pixels it accepted (`png match (144 transition pixels at the clean edge)`).

**Behaviour.** A DMG BGP write reaches the pixel two dots back as
`old or new` for one pixel (hardware photographs in SameBoy issue #65,
mattcurrie 2018; mealybug `m3_bgp_change` samples BGP once per dot and is
exact with it; daid `ppu_scanline_bgp_1.dmg.png`). It is
instance-dependent: daid ships three accepted DMG references (`_0` old
value, `_1` OR, `_2` new value — GBEmulatorShootout issue #9) and dingbat is
pixel-exact on exactly one per setting. gambatte's references encode the
clean edge.

**Modelled.** `MIXER_PALETTE_OR = 1`, `MIXER_PALETTE_BACK = 2` (DMG only; the
CGB's own write dot puts the pixel out of reach). Not a correctness constant
but a DMG-instance choice with no selector. The eight tests were the price
of the mealybug/daid side: `MIXER_PALETTE_OR = 0` takes all eight and loses
mealybug `m3_bgp_change{,_sprites}` [dmg] and AGE `m3-bg-bgp-dmgC`
(re-checked 2026-09-22). SameBoy on a DMG-B draws dingbat's frame to the
pixel. Hardware experiment (d) below.

**No selector exists in the data (re-tested 2026-10-14).** Every write in
the four suites is opcode `E2` on the same dot grid (dot = 1 mod 4). In all
of gambatte's tests the falling write (FF -> 00) is the first write of the
line, at dots 93/97/101, and its transition pixel is at x <= 9. The rising
writes there are OR = new, so they show nothing.
* Position/phase (T1) is refuted by identical configurations. AGE line 8
  and gambatte `_4` lines >= 1 are both dot 93, SCX 0, x = 1, colour 0
  3 -> 0. AGE line 16 and `_5` are both dot 97, SCX 0, x = 5. AGE's
  reference has `old or new` at both and gambatte's has the new value.
* Bitwise rules (T2) are refuted too. An ordered per-bit latch cannot give
  mealybug's 3 for both 01 -> 10 and 10 -> 01. "Only writes with a rising
  bit blend" is contradicted by mealybug's no-rise restores (01 -> 00 at dot
  105) and by AGE's FF -> E4.
* The one-pixel tests (T3) are the same pixel on line 0, whose pipeline runs
  4 dots ahead: `_3` (x = 1), `scx1_4` (x = 4), `scx3/_4` (x = 2). On
  lines >= 1 the pixel is off screen, or at x = 0 under
  MIXER_PALETTE_OR_HEAD.
* Provenance (T4): no DMG reference here is a capture. gambatte's
  `_dmg08.png` were committed in svn r246 (git 9dc2f7ec, 2011-07-23), a
  commit whose own log says gambatte then passed all 2755 tests. They are
  framebuffer dumps, compared exactly. mealybug's
  `expected/` are "screenshots from my Game Boy emulator", with blurry
  photos of a DMG-blob alongside. AGE's are its own renders, checked
  against a photo of a DMG-CPU-08 with a CPU C. daid's `_0`/`_1`/`_2` are
  bgb, SameBoy and gambatte behaviour (shootout e999f89d; gbdev
  GBEmulatorShootout issue #9). In that issue daid writes that his own DMG
  gives old or OR "depending on the position in the scanline", and the
  new-value case is reported from a GB Player in CGB-DMG mode.
* The photos settle the pixel-level question. In mealybug's DMG-blob photo
  (about 16 px per pixel), every mid-line transition at dots 105-237 reads
  as OR. At dot 93, x = 1 (gambatte `_4`'s configuration), 11 -> 00 reads
  as 3 on all 32 lines. 01 -> 10 at the same dot reads as 2 (new) on lines
  16-30 and 3 (OR) on lines 80-95: one unit, one frame, different
  outcomes. The AGE photo (about 7 px per pixel) reads OR mid-line and is
  ambiguous for x <= 9.

The pixel behaves like a timing race at the falling bits, not a rule.
The one deterministic selector that fits all references — blend only when
the old value was written within N dots, 60 < N < 316 — is contradicted by
mealybug's own photo, which shows lines 16-30, 16 dots after the previous
write. It was not implemented.

### C8. AGE `m3-bg-bgp-dmgC`, 2 pixels

**Closed.** The line's first pixel is never the transition pixel
(`MIXER_PALETTE_OR_HEAD = 0`, gb.nim).

Both pixels were x = 0 on a line whose BGP pulse's restoring write found
pixel 0 exactly MIXER_PALETTE_BACK stages down the mixer tail (SCX 1 in the
first band, SCX 5 in the second). The model painted it `old or new` (black);
hardware paints it the clean new shade. The band's run lengths, 10 - SCX,
put every other edge where the model has it. mealybug is unchanged, and
gambatte `dmgpalette_during_m3/dmgpalette_during_m3_scx1_4` goes from 144
wrong pixels to 1.

---

## D. DMA

### D1. HBlank DMA blocks owed across a halt or a speed switch

**Closed.** dma 229/229: the `dma/` and `irq_precedence/` tests that rest
on the HALT/STOP request rules all pass (the `HDMA_*` knobs below, gb.nim).

**Behaviour.** An HBlank DMA copies one 16-byte block per mode-0 edge while
the CPU is off the bus (Pan Docs, "LCD VRAM DMA Transfers"). The CPU hands
the bus over at its opcode fetch or an instruction boundary — never on an
operand M-cycle (`HDMA_GRANT_FETCH_DOTS`, `HDMA_GRANT_BOUNDARY_DOTS = 3`;
gambatte `dma/hdma_start*` and mealybug `dma/hdma_timing-C` parameterised by
the fetch). A halted CPU's edge detector holds a CPU-clocked copy of the
mode, so a mode-0 edge under a halt is invisible until the CPU runs again
(`HDMA_HALT_M0_BLIND = 1`, `HDMA_HALT_BLIND_LAG = 2`). The rules
(docs/dev/gb-derivations.md section 5, one entry each):

* An HBlank request inside a HALT's or a speed switch's own execute cycle
  is taken there and paid at the wake, the byte that cycle read executed
  from the latch (`HDMA_HALT_REQ`).
* The wake's margin and the edge detector's blind M-cycle
  (`HDMA_WAKE_M0_MARGIN = 4`, `HDMA_WAKE_BLIND_DOTS = 4`).
* A dispatch's first M-cycle is a hand-over point (`HDMA_DISPATCH_FETCH`).
* A general-purpose DMA and an FF55 write arming a transfer inside HBlank
  take the bus at the next opcode fetch (`GDMA_GRANT_FETCH`,
  `HDMA_START_GRANT_FETCH = 2`, `HDMA_START_REQ_LAG = 1`).
* The LCD switch-off moves one block (`HDMA_LCD_OFF_BLOCK`).

Its bytes land 4 dots after the block (`HDMA_VISIBLE_DOTS`;
`hdma_start_ds_1` and `hdma_start_scx5_2` separate dots from M-cycles).

### D2. OAM DMA against the mode-2 scan and the CPU

**Closed.** For a slot inside a running OAM DMA the mode-2 scan's comparator
compares the word its input latches last loaded, and at double speed the
transfer's take/give edge sits one dot earlier against the scan
(`OAM_SCAN_DMA_HOLD`, `OAM_SCAN_DMA_EDGE_DS`; docs/dev/gb-derivations.md
section 6).

What closed each test:

* `late_sp{00x,00y,01x,01y,39x,39y}_ds_*`, `late_sp39x_4`,
  `sprites/late_disable_ds_1`, `sprites/enable/late_disable_ds_3`: a CGB
  fetches objects with LCDC.1 clear (`CGB_OBJ_FETCH_OFF`), and at double
  speed `OAM_SCAN_DMA_EDGE_DS` = 1 (1 and 2 pass, 0 and 3 do not).
  `oamdma_late_speedchange_stat_2` came with it once the unit releases OAM
  when a speed switch stops it with its last byte written
  (`OAMDMA_FROZEN_RELEASE`).
* `oamdma_src0000_busyint0002` (both devices): the dispatch's push order
  (`DISPATCH_PUSH_MCYCLE`, A4).
* The `srcchange0000_busyinc` pair: the bus of a transfer restarted by FF46
  moves at once (`OAMDMA_RESTART_HANDOVER`, docs/dev/gb-derivations.md
  section 6).

The `busy*` families are value tests (which byte a colliding access sees).

**Behaviour.** The mode-2 scan reads OAM entry `n` on dot `2n` and reads
nothing while an OAM DMA owns the OAM bus. The transfer moves one entry per
16 dots (8 in double speed) against the scan's one per 2, so no start
latency can express the tests (Pan Docs, "OAM DMA Transfer"; gambatte
`oamdma/late_sp{00,01,02,39}{x,y}`, sixteen one-M-cycle brackets). For a
slot inside a running transfer the comparator compares the word its input
latches last loaded (`OAM_SCAN_DMA_HOLD`;
DocBoy `oam_scan_blocked_by_dma_nops*`, strikethrough,
`mgb_oam_dma_halt_sprites`; docs/dev/gb-derivations.md section 6).

**Modelled.** `OAM_SCAN_DMA_LOCK = 1`,
`OBJ_SCAN_DOT_ADJ = 0`, `CGB_OAM_DMA_START_T = 8`, `OAMDMA_HALT_PAUSE = 1`,
`OAMDMA_FREEZE_BUS = 1`, `OAMDMA_WRAM_A12 = 1`, `OBJ_DMA_BUS_LEAD`.

---

## E. The KEY1 speed switch

### E1. What the switch does to the divider, the APU tap and interrupts

**Closed.** The switch's stall is a HALT, not a STOP leaf (the
`SPEED_SWITCH_*` knobs below; `APU_SPSW_EXTRA_DOTS`, section H).

Tests: AGE `speed-switch/spsw-tima-{cgbBC@*,cgbE}` (3),
`spsw-ch2-lc-delay-cgbBCE@*` (3),
`caution/spsw-interrupts-{cgbBC@*,cgbE}` (3), and gambatte
`speedchange/speedchange{,2,5}_ch2_nr52_{1a,2a}{,_ds}` (6). Not recorded.
`sound/ch2_late_reset_nr52_2b{,_ds}` (3) closed with the APU's own share of
the stall (`APU_SPSW_EXTRA_DOTS`, section H).

**Behaviour.** A switch armed by KEY1 and taken by `STOP` resets DIV and
stalls the CPU for 2^17 cycles of the NEW CPU clock while the timer, serial
and OAM DMA keep running — a HALT, not a STOP leaf (Pan Docs, "CGB
Registers", KEY1; gambatte `speedchange_tima00_*` count 128 ticks through
it, `speedchange2_*` twice the real time on the way back). The PPU comes out
8 dots ahead of the CPU clock into double speed and 3 back into single
(`speedchange{,2,3,4,5}_ly44_m3_*`, a ladder in switch count). An interrupt
arriving during the stall ends it. A switch whose HALT is skipped because
one is already pending stops the divider for the oscillator restart
(c-sp's `speed-switch/caution/WARNING.md`). The DIV reset reaches the
divider's slow taps one M-cycle before the fast ones, and CGB-E one tap
lower. After an odd number of switches into double speed the DIV-APU tap
edge arrives one M-cycle late until the APU is powered off.

**Modelled.** `SPEED_SWITCH_STALL_CPU = 131072`,
`SPEED_SWITCH_STALL_RUNS_CPU_CLOCK`, `SPEED_SWITCH_PPU_EXTRA_DOTS = 8` /
`_SINGLE = 3`, `SPEED_SWITCH_STALL_ENDS_ON_IRQ = 1`,
`SPEED_SWITCH_IRQ_LEAF_HOLD_T = 8` (CGB-E half:
`spsw_irq_leaf_hold_short`), `SPEED_SWITCH_DIV_RESET_T = 8` / `_SLOW = 4` /
`SLOW_BIT = 9` (CGB-E: `spsw_div_mid_taps_slow`), `APU_SPSW_TAP_LAG_T = 4`.
The stall as a halt (I7, 2026-10-14): `SPEED_SWITCH_HALT_PPU_LEAD`,
`SPEED_SWITCH_ENTRY_IRQ_CHECK`, `SERIAL_HALT_TAIL_BLIND`,
`SPSW_DIV_RESET_RELOAD_LATE`; the IME-clear leaf's
`SPEED_SWITCH_IME0_LEAF_HOLD_T = 8`.

**Measured before it closed.** Channel 2's length counter expired one
M-cycle early in three of seven switch configurations (`sc`, `sc2_ds`,
`sc5`: ends in double speed, odd switch count) and was exact in the other
four, including `sc3`. That refutes a flat delay (the duty-pointer ladder in
H2 has the same shape). The `speedchange_tima0x` family could not be
satisfied by any stall length: the failures were one tick low, so the
question is which cycles the timer sees around the reset.

---

## F. Serial and timer

### F1. The eighth shift edge against a CPU access

**Closed.** An SC store samples the serial tap `SERIAL_SC_WRITE_LEAD_T` = 4
T-cycles before the divider's count at its commit, i.e. the top of the
store's M-cycle (serial.nim; 1..4 are one value, and the values on each side
are at the constant). serial 82/82.

Tests: `serial/nopx1_start{,83}_wait_read_if_2`,
`start83_late_div_write_wait_read_if_{1b,2b}` (CGB),
`nopx2_start_wait_read_if_1`.

Refuted:

* A one-M-cycle serial lead on a running CPU's dispatch, as
  `TIMER_IRQ_RUN_LEAD`. With any `SERIAL_TAP_*` it loses the
  `start_wait_read_{sb,sc}_2` family, which pins the dispatch where it is.
* Every `SERIAL_TAP_*` from 0 to 16 on its own. None turns
  `nopx1_start_wait_read_if_2`.

### F2. TIMA reload against a read

**Closed.** Both divider taps are judged at the end of the TAC write's
M-cycle (`TAC_SELECT_LEAD_T = 0`, timer.nim). Tests: `tc00_late_tc01_{5,7}`
(1..4 lose them on both devices).

---

## G. Revision-vocabulary rows, closed by scoring the right machine

**Closed.** The fork's Color (`-C`) tests are scored on CGB E
(`WilbertpolCgbRep`, the runner).

Tests: wilbertpol `acceptance/gpu/ly00_mode1_2-C`, `ly_new_frame-C` and
`ly_lyc{,_0,_144,_153}-C`. They failed (two scored) or were skipped (four)
while the runner stood the fork's `-C` on CPU CGB C.

**Behaviour.** Three behaviours split at CGB C/D, and AGE ships each as a
ROM pair with per-unit hardware records in the headers:

* The readable LY 153 -> 0 edge is one M-cycle later on D/E/AGB at single
  speed (`ly_read_edge_late`; `ly/ly-dmgC-cgbBC` vs `ly-cgbE`, one byte
  apart).
* The M-cycle of mode 0 between mode 1 ending and line 0's mode 2 exists on
  every DMG and CGB <= C and not on D+ (`m1_end_no_mode0`;
  `stat-mode-dmgC-cgbBC` vs `stat-mode-cgbE`, the `M1E` byte).
* CGB D+ hold the LY=LYC comparison the blind window is leaving
  (`lyc_compare_hold`).

gambatte's CPU-CGB-C tests say the same at one-NOP resolution
(`ly0/lycint152_ly153_{1,2,3}` read 152, 153, 0;
`lycint152_ly0stat_{1,2,3}` read $C1, $C0, $C2). wilbertpol's `-C` is the
2016 fork's hardware GROUP `cgb+agb+ags` with no revision axis, its sources
say only "pass: CGB, AGS", and its six ROMs on these edges assert the D+
values -- no machine passes them and the gambatte/AGE C tests together.
Every `-C`/`-cgb` ROM in the fork passes on CGB D and E (182/182 serial
tests); SameBoy, which claims the whole fork, tests it on CGB E. Upstream
mooneye never carried these gpu ROMs: they were written for the fork after
its author's one upstream PR.

**Still open on hardware.** Whether a CPU CGB C also holds the LY=LYC
comparison (`lyc_compare_hold`, `docs/dev/oracles.md`): no ROM in the tree pins
the C/D placement of `ly_lyc*`, and the fork's CGB E score does not ask.

---

## H. The APU as heard: gambatte's `_outaudio` rows

gambatte scores 220 of its ROMs on sound, not pixels:
after the run, `audio0` iff all 35,112 samples of the final frame are equal,
`audio1` otherwise, on the raw 2 MHz mix with no output filter. The harness
reproduces the rule with a probe on the mixer (`GbApu.probe_*`, armed by
`--mode=gambatte` for the last frame; `tests/README.md`). The ROMs are
one-NOP ladders around a square channel's duty pointer, envelope or sweep, so
they read the APU at a resolution nothing else in the tree does. Scored since
2026-09-21; all 220 green since 2026-10-14 (`sound` 184/184, `speedchange`
36/36).

**Knobs they pin** (values on both sides of each fail; the comments and
docs/dev/gb-derivations.md section 11 carry them):

* `BOOT_CH1_PHASE_{DMG,CGB}_T` (memory.nim): the boot beep's second note is
  still stepping at the hand-off (NR52 = $F1), frequency $7C1, and
  `ch1_init_pos_{1..8}` pin where in its 2016-cycle duty cycle each boot ROM
  leaves it (728 / 1612, one value of 504).
* `BOOT_FS_STAGE_{DMG,CGB}`: the frame sequencer's step at the hand-off
  (1 / 0, `ch2_init_env_counter_timing`).
* A trigger against the next envelope clock (`psg_env_trigger_extra`: Pan
  Docs' extra clock when step 7 is next, judged `ENV_TRIGGER_LEAD_T` = 4
  cycles ahead of step 6; `ch2_init_reset_env_counter_timing_{9..16}`).
* `SWEEP_TRIGGER_LEAD_T_{DMG,CGB}` = 4 / 8: scheduler cycles before a sweep
  clock within which a trigger misses it
  (`ch1_init_reset_sweep_counter_timing_{1..12}`).
* `APU_POWERON_TAP_LEAD` = 4 (apu.nim): counts ahead of the NR52 power-on
  write at which the DIV-APU tap bit is sampled
  (`ch2_init_reset_env_counter_timing_{1..8}`, `ch2_late_reset_nr52_*2b`).
* `APU_SPSW_EXTRA_DOTS` = 8 / `_SINGLE` = 3: the APU's share of the KEY1
  stall's oscillator restart, the PPU's 8 / 3 exactly, with
  `APU_SPSW_REPHASE_{LEAD,GRID}_T` = 3 / 1 at the first switch after an APU
  power-on (H2).

### H1. A double-speed trigger's grid edge

**Closed.** CPU CGB D/E pick a square trigger up on the next 1 MHz edge
(`gb_apu_edge`; SameSuite `channel_{1,2}_align{,_cpu}`, DocBoy). On CPU CGB C
and older at double speed the trigger acts in the write's own M-cycle
(`gb_trigger_pickup`), and a channel started from off begins its first period
on the first odd tick of the APU's 512 kHz clock at least one tick after the
write (`SQ_START_HALF_RATE_LEAD_T` = 4; gb/apu/psg_host.nim,
docs/dev/gb-derivations.md section 11). Tests: gambatte
`sound/ch1_duty0_pos6_to_pos7_timing_ds_{1..6}` (`_ds_{1,3,6}` red without
it), the 36-test `speedchange` ladder (five red without it), SameSuite
`channel_1_freq_change_timing-cgb0BC`.

### H2. The switch ladder: one re-phase per power-on

**Closed.** The first KEY1 switch after an APU power-on re-phases the APU
clock once; later switches move the APU by the PPU's extras alone
(`apu_spsw_rephase`, apu.nim).

Tests (13): `speedchange{2,3,4,5}*_ch1_duty0_pos6_to_pos7_timing_*` (12) and
`speedchange_ch1_nr4init_duty0_pos6_to_pos7_timing_2`. Closed 2026-10-14.

**The model (apu.nim, all CPU CGB revisions).** The APU runs through the KEY1
stall on the same oscillator restart as the PPU: `APU_SPSW_EXTRA_DOTS` = 8
going up, `_SINGLE` = 3 going down, the PPU's `SPEED_SWITCH_PPU_EXTRA_DOTS`
pair exactly. On top of that, the FIRST switch after an APU power-on
re-phases the APU clock once (`apu_spsw_rephase`): its tick grid (the 1 MHz
square grid) comes out `APU_SPSW_REPHASE_GRID_T` = 1 T later, and a running
square's next step `APU_SPSW_REPHASE_LEAD_T` = 3 T earlier, i.e. onto the
re-phased grid's previous edge. Later switches move the APU by the extras
alone.

**Why it is the unified rule.** The extras were pinned to the PPU's 8 / 3
and a one-off shift was swept. Every ladder test whose channel runs across a
switch (one switch or five, up-first or down-first, triggered before the
first switch or after a power-on that followed one) wants the same 3 T on
top, once. That is on CPU CGB C, the ladder's machine. CGB E puts the step
on the 2 MHz grid's previous edge instead, 1 T, as the wave channel does on
every revision (2026-10-14: `GbQuirks.spsw_apu_rephase_2mhz`,
`APU_SPSW_REPHASE_LEAD3_T`, from DocBoy's CGB-E speed-switch tests, I8). The
grid-only test (`nr4init`: power-on, switch, then the first trigger) wants
the grid 1..2 T later. The non-additive sums the 2026-09-22 pass measured
(two switches 14..16, three 24, four 22..26, five ~32 against 10 / 7) are
8 / 3 per switch plus that one-off, read through the default model's
re-anchored grid. A trigger after a power-on with no switch since sees no
re-phase. So SameSuite `channel_1_freq_change_timing-cgb0BC` (both halves:
single speed after the boot, double speed after a switch AND a power-on) and
the no-switch `sound/` tests keep the default trigger rule.

Values tried (each a full 220-test run):

* `EXTRA_DOTS` 7 / 9 lose 11 / 10 tests.
* `_SINGLE` 2 / 4 lose 12 / 4.
* `LEAD_T` 2 / 4 lose 8 / 6.
* `GRID_T` 0 / 3 lose `nr4init_2` (2 also passes; 1 is the value that puts
  the step on the re-phased grid's edge).
* Both re-phase terms at 0 lose 17.
* Tying the one-off to the boot hand-off instead of the power-on loses the
  five `_ds_2` tests, whose power-on follows a switch.

With all of it, SameSuite APU 70/70 and blargg `dmg_sound` / `cgb_sound`
stay green, and `freq_change_timing-cgb0BC` passes on CPU CGB C.

**The 2026-09-22/23 conflict, for the record.** An alternative APU clock
model (refuted, kept compiled out) greened all 13 and turned
`freq_change_timing-cgb0BC` red, one NOP early in BOTH halves, by charging
the re-phase's 3 T to the first trigger after a single-speed power-on
instead of to the switch; it was removed 2026-11-12. Stock gambatte (built 2026-10-14 from upstream master, run
headless) passes all 36 `speedchange` audio rows and FAILS the SameSuite
row: `00 00 0F 0F FF FF F0 F0` / `0F 0F 0F 0F 0F FF FF FF` against
`00 00 00 0F 0F FF FF F0` / `00 00 0F 0F 0F 0F 0F 0F`, with the real CGB
boot ROM and from its post-boot state alike. The boot hand-off is not a
hidden variable either: at single speed the APU's grids are locked to the
M-cycle grid (a 1 MHz edge is one M-cycle), so SameSuite's first half and
every ladder's first trigger (both 25 M-cycles after a single-speed
power-on) see the same edge. The measurement and revision checks of
2026-09-23 stand: the audio verdict is gambatte's runner rule verbatim, the
PCM12/34 sample point is pinned by 48 SameSuite rows, and both records are
CPU CGB C.

SameBoy (2026-09-23): on CGB C it passes the SameSuite row and 32/46 of
gambatte's duty ladder (its fourteen misses are `audio1` members, including
the no-switch `sound/*_ds_{2,4,6}`); on E it is the mirror image (22/46).

---

## I. DocBoy (`docboy/*`, first scored 2026-10-14)

DocBoy's own suite, scored by its own runner's rules on DMG ABC and CPU CGB E
(`tests/README.md`, "The DocBoy suite"): 8,767 / 9,186 at `DocboyRev` (49
more not scored, `DocboyNotScored`). Every failing ROM is in
[`tests/results_docboy.md`](../../tests/results_docboy.md); every group that is
not scored is in the "Deliberately not scored" ledger at the end of
`tests/results.md`. The 419 failing tests are I1 79, I2 11, I3 180, I5 6,
I6 49, I9 20, I11 15, I12 36, I13 10 and "Small" 13. I4's scored rows all
pass; I7, I8 and I10 are closed. The 9,186 include DocBoy's rebuilds of 7 SameSuite channel 1 ROMs
(`cgb/samesuite/apu/channel_1/*-cgbE`), which pass; the eighth,
`channel_1_sweep_restart_2-cgbE`, is not scored (its expectation and
SameSuite's both claim CGB E).

A test is left out only when it is broken or conflicts with an equal-standing
source in a way nothing in hand resolves; that SameBoy fails it too is no
reason. Nine families (195 rows) left out before on weaker grounds, mostly
SameBoy agreeing with dingbat, are scored again (2026-11-16) and appear below
as open, failing families.

Its expectations come from one emulator's model of the maintainer's own DMG
and CGB-E, so a failing test is a lead, not a verdict. "Second opinion" below
is SameBoy (DMG B / CGB E, real boot ROMs) on six sampled failing tests per
section. Where SameBoy agrees with DocBoy, the family is probably dingbat's.
Where it fails too, the test encodes something only DocBoy models, or a
hardware question. Families:

* **I1. CH4 retrigger and NR43 changes (79 left).** The tests read PCM34 one
  M-cycle either side of the LFSR's 15th clock after the last write. The
  rules are in `psg_channels.nim` (notes above `ch4_lfsr_frozen`,
  `psg_noise_first_inc`, `psg_noise_slow_restart`). Each was checked against
  SameBoy run as a black box on the same ROMs and against tools/gbprobe probe
  (l) timelines (PCM34 every M-cycle) on DocBoy and SameBoy:
  * A trigger restarts the divisor stage but not the counter: a retrigger of
    a running channel waits for the tap bit's next rising edge from wherever
    the counter stands (shift 0: half a period from an even count, a full one
    from an odd count; "always a full period" is only the odd case).
    SameBoy agrees on every code-3 cell of probe (m)'s sweep.
  * The count in progress finishes on the divisor it was loaded with: an NR43
    write is a reload only when an increment lands on its cycle
    (`change_divider3_to_{0,5}`).
  * The LFSR clock is the tap's rising edge, so an NR43 write moving the tap
    from a 0 bit to a 1 bit clocks the LFSR at once (`change_shift*`; SameBoy
    passes all 82).
  * Divisor code 0: a retrigger whose increment at the trigger's 1 MHz edge
    (or the pending first one a tick later) lands off the 512 kHz grid takes
    a whole 3-bit turn of the stage first, 8 grid periods, so the LFSR
    restarts 28 M-cycles (14 us) later at double speed (40 double-speed tests
    and the 3 single-speed `ch4_retrigger_delay16_*_nops{0,2,4}`; SameBoy
    restarts as late in the running-stage case, passes 31 of the 40, and
    differs only before the first increment).
  * Divisor code 1 rounds a trigger off the grid up to the next grid edge
    only from a zero counter (SameSuite channel_4_frequency_alignment);
    once the counter has counted it rounds down like codes >= 2 (10 tests,
    all passed by SameBoy too).
  * One rule SameBoy does not share: a code-0 count left pending off the
    512 kHz grid by a write selecting code >= 1 finishes on the next grid
    edge (`change_divider0_to_3`, 12 tests SameBoy fails; probe (m)
    `c03_nr43` shows it 2 M-cycles early).

  Left (79, all in `double_speed/apu/ch4`): every one has its last trigger
  1 to 4 us after the previous one.
  * 52 `double_retrigger_*` and 7 `retrigger_*` code-3 tests, where DocBoy
    merges a retrigger one tick after an off-grid trigger with it and defers
    one two ticks after by one grid step (SameBoy fails all 59 and matches
    dingbat in probe (m) `c3_absorb`/`c3_defer`; DocBoy's own model has no
    such window after an on-grid first trigger).
  * 20 code-0/1 `retrigger_*` tests: 12 with a retrigger one tick after the
    trigger, 8 with a code-1 retrigger a tick before the first increment of
    an off-grid trigger (SameBoy passes 7 of the 20, DocBoy and SameBoy
    disagree on the rest).

  What would close it: hardware. The `probe_m_*` photograph builds
  (tools/gbprobe/README.md, "probe (m)") split DocBoy from SameBoy at each of
  these. Proposed NotScored until then.

  DocBoy disables 640 `double_retrigger_*` tests (codes 0 and 1); its own
  build, run as a black box, fails 84 of them (SameBoy passes 37 of those
  84), so those expectations are not DocBoy's output; dingbat passes 484.
* **I2. CH1 frequency sweep (11 left of 380).**
  `period_sweep_*` on DMG, CGB and double speed. Second opinion: SameBoy
  (black box, DMG B / CGB E) passed 301 of the 380 tests dingbat failed, so
  the family was dingbat's. Probe ROMs built from DocBoy's own code
  (straight-line writes and one NR52/PCM12 read) settled on SameBoy the
  rules the tests left open. The model is in `psg_channels.nim`, "Channel
  1's sweep unit":
  * The calculation shifts one bit per 1 MHz APU tick. A trigger's check stops
    the channel step + 3 M-cycles after the NR14 write (`disable_on_trigger_
    step1..7`), step + 2 when it restarts a calculation already running
    (`disable_on_double_trigger_*`; SameSuite `channel_1_sweep_restart`
    round 2's nine M-cycles at step 7); a clock's second check stops it step
    + 1 after the clock (`step1..7`, SameSuite's eight at step 7). The check
    lands half a tick past the 1 MHz edge, which double speed's reads see
    (`double_speed_*_disable_on_trigger_step4_a1..d2`).
  * The shifted operand is held between calculations and the adder is live:
    a clock writes back the operand its last calculation made with that
    calculation's step (`change_step_6_to_5_period154`), the direction is
    the one NR10 holds at the check (`change_direction_*_during_recalc`), a
    clock's calculation takes NR10's step and NR13/NR14 as they stand after
    the clock's M-cycle (`change_step_during_recalc_*_round1`,
    `change_period_nr13_during_recalc_round2_*`), and a frequency written
    during a calculation moves the adder's base but not the shifter
    (`double_speed ... no_retrigger_*`).
  * A trigger at step 0 runs no calculation (Pan Docs); a clock at a non-zero
    step with no calculation ended since the trigger writes 0 to the
    frequency and does nothing else, so the note never stops (`change_step_
    0_to_1_*`, `change_step_during_recalc_0_to_{4,6}_round0`; the PCM12 test
    `change_step_0_to_1_after_recalc` shows the 2048-cycle period).
  * NR10: step 0 written during a calculation freezes its tick counter until
    a step is given back, whatever step (SameBoy probes: the stop follows the
    new step 6, 6, 5, 4 M-cycles later for a freeze 0..3 ticks in; `change_
    step_7_to_0_during_recalc_then_*`, one M-cycle later on the CGB); a pace
    given while the timer stands at 0 runs an iteration at once (`change_
    pace_0_to_2_*`; Pan Docs' "reloaded as soon as it's set" holds only
    there: after a clock the 8-count runs out first, `_delayed_more`); no
    enabled flag is latched at the trigger; an add-mode write after
    subtraction (both machines), or any write over a non-zero step (DMG),
    lets the adder's carry through, so an adder at $7FF stops the channel
    (`write_nr10_overflow_*`, `change_direction_twice_period_overflow_
    round2`, `change_step_6_to_{4,5}_period32`, `change_pace_1_to_0_during_
    recalc`).
  * Double speed: the clock's own check lands 3 M-cycles after the DIV-APU
    event whichever 1 MHz phase the APU was powered on in (`step0_a..d`; the
    envelope's 2 T lag on CGB E, I8, is the same shape); the CGB's trigger
    lead before a clock is `SWEEP_TRIGGER_LEAD_T_CGB` (`..._delay12240`);
    a trigger written while an earlier one's calculation has not started
    rides on it (`double_trigger_*`); a clock's write-back reaches NR13/NR14
    on the 1 MHz edge after it, undoing a CPU write in between
    (`..._delay12243`).
  * A clock takes NR10 as it stands after its own M-cycle in all three
    things it does: the calculation it starts (above), the pace its timer
    reloads with (`change_pace_4_to_6_during_recalc_round{0,1}_*` stop
    alike; `_round2_*`, one M-cycle later, reload at pace 4 once and stop
    two clocks earlier), and whether it writes
    back: a step given on a step-0 clock's M-cycle makes it write the
    adder, 0 if the adder holds nothing (`change_step_during_recalc_0_to_4_
    alt_round{0,1}_*` alike; `_0_to_{4,6}_round1`). A step of 0 given on a
    writing clock's M-cycle does not undo its write (`6_to_0_round2_*`).
    Closed 2026-11-17 (CGB `..._alt_round1_2`, `..._pace_4_to_6_..._round1_1`);
    SameBoy fails both, no hardware suite reaches the M-cycle.
  * DocBoy-only rules taken with the rest (SameBoy differs; they fall out of
    the same model): a trigger one tick into a calculation waits a tick, a
    trigger on its way holds the channel on, and a clock cuts a running
    calculation short (`change_period_nr14_during_recalc_delay14279..14284`:
    the frequency becomes 0 and the note plays on).
  * Left (11):
    * CGB `change_period_nr14_during_recalc{,_step0}_delay14284` (2; scored
      again 2026-11-16): a retrigger 8 cycles (2 M-cycles) before a sweep
      clock, which DocBoy has the clock take, i.e. a CGB trigger lead of 4
      where `SWEEP_TRIGGER_LEAD_T_CGB` is 8. Conflict with hardware, not
      adopted (2026-11-17). `..._step0_delay14284_round1` is SameSuite
      `channel_1_sweep_restart_2`'s subtest (`\2` = 1, `\1` = 1) with the
      same registers (NR10 $10, NR13 $FF, $83 then $87), the same distance
      to the clock (8 cycles), the same 512 kHz phase of write and clock
      (both on the power-on grid, `GbApu.noise_phase`) and the same read
      3 M-cycles after the write: SameSuite (CGB E hardware) reads $F1 there
      and in all 16 columns, DocBoy wants $F0. gambatte `_10` [cgb] (CGB C
      hardware) sits at the same 8 cycles. What still differs: the clock is
      the frame sequencer's step 6 in DocBoy, step 2 in SameSuite and
      gambatte, and SameSuite resets DIV between its two triggers. DocBoy's
      own CGB rows all fit one lead of one 1 MHz tick at both speeds (4 at
      single speed, 8 at double; an audit build of 2026-11-17, not kept,
      passes the pair and fails no other DocBoy CH1 row), which is the DMG's lead: its model does not
      split the machines here. That build fails SameSuite `channel_1_sweep_
      restart_2` and gambatte `_10` [cgb]. A step-6-only lead of 4 passes
      everything but has no mechanism (step 2 and step 6 are the same
      DIV-APU edge pattern, bit 1 rising); only a CGB E run of DocBoy's
      `step0_delay14284_round1` can settle it.
    * DMG `step6_period93_round2`, `step7_period247`, `change_step_6_to_5_
      period152_round2`, `change_direction_twice_period_overflow_round1_2`
      (4): DocBoy's DMG stops the channel when a clock's second calculation
      lands exactly on $7FF (period 247: 2032 + 15; period 93: 2016 + 31),
      where its CGB twins (`step7_period247` expects the period-248 count on
      the CGB) and SameBoy do not. A trigger's check at $7FF does not stop
      it (`disable_on_trigger_step6_period2016_round1_1`, `write_nr10_
      overflow_period16_step7_round1`), so it would be a clock-only carry:
      "the clock's second calculation overflows at $7FF on the DMG" passes
      all four and breaks nothing (2026-11-17 audit build). Not adopted:
      Pan Docs (Audio Details, "Obscure Behavior") runs the second check as
      the same overflow check, "greater than 2047", and no mechanism gives
      the clock's second calculation a carry the trigger's lacks. One DMG
      run settles it (DocBoy's own ROMs on a DMG or GBP).
    * Double speed `delay12243_period_round2/4` (2: the duty phase after a
      trigger the clock's write-back overwrites; dingbat and SameBoy sit on
      opposite sides of DocBoy's edge).
    * Double speed `disable_on_triple_trigger_step4_delay4_{2,3}_round1`
      (2): the third trigger arrives 2 ticks into the second one's
      restarted calculation (arrival at 13 M-cycles after the first write,
      the restart at 9); DocBoy has it restart at 15, as `delay4_{4,5}` do,
      while 2 ticks into the FIRST trigger's calculation (the second
      trigger, at 9 after a start at 5) restarts at once. A rule keyed on a
      restarted calculation has no mechanism behind it; SameBoy fails both.
    * Double speed `change_step_7_to_0_during_recalc_delay16_after_trigger`
      (1): step 0 written 18 M-cycles after the trigger, before the 7th
      tick (19) and the check (20); dingbat freezes the calculation, DocBoy
      wants the stop. SameBoy fails it.

  The 14 double-speed CH1 tests outside the sweep are closed
  (`psg_channels.nim`: `sq_trigger`, `sq_starting`, `sq_reload_step`). Each
  family walks a write across one APU tick in half-tick steps, so a pair of
  tests one M-cycle apart that DocBoy answers alike and dingbat did not names
  the rule. SameBoy (CGB E, black box) fails all 14, so these are DocBoy's
  rules. Each is stated on dingbat's own grid (a write takes effect on the
  next 1 MHz edge) and does nothing at single speed or on CGB C:
  * A trigger written half a tick before a duty step is picked up on the
    step's edge, and the step still happens (`retrigger_same_period_75_
    {8,16}_*` against `_{9,17}_*`; `retrigger_square_wave_duty_75_alt_
    delay{4,5,8}` and `_b_delay8`, period 1). Double speed only: after a
    KEY1 switch dingbat's single-speed grid sits a few T off the CPU's
    (H2's re-phase, fitted to gambatte's CGB C ladder with the step
    dropped), and `speedchange{,4}_ch1_duty0_pos6_to_pos7_timing_nop_
    {ds_,}1` fail with the rule there.
  * A trigger picked up on or before the edge an earlier trigger loads the
    timer on (2 ticks after its own edge from off, 1 on a restart) starts
    the channel as from off, 2 ticks: every edge decides on the state
    before it (`retrigger_same_period_75_{0,1}_*`, 1.5 and 2 ticks after a
    trigger from off, step where `_75_{2,3}_*` do). `GbApu` keeps the edge
    (`PsgSquare.start_at`, GB payload rev 10). No `ldh` store pair reaches it.
  * CGB D/E reload the frequency timer half a tick after a step, so NR13 or
    NR14 written then sets the period counted from the step, the duty
    position kept (`change_period_nr1{3,4}_no_retrigger_75_16*`: as the
    write on the step, `_75_15`; `_75_17`, a tick later, does not). This
    replaces the old "undo the step" reading of SameSuite `channel_1_freq_
    change_timing-cgbDE` cell 10, which the reload also gives
    (`square_reload_halftick`; the undo came from a sweep against SameBoy,
    which keeps it, docs/dev/oracles.md).

  blargg, SameSuite APU 70/70, gambatte `sound`/`speedchange` and the GBA PSG
  tests are unchanged by these rules.
* **I3. CGB compatibility-mode picture (180 left of 233).**
  Three groups: the boot ROM's palette table, and two kinds of mid-mode-3
  LCDC write in compat mode, `m3_lcdc_win_en_change_multiple_wx_*` (timing
  tests closed, 51 frames left) and `change_{bg,win}_tile_data_glitch_*` (63
  left; their 10 CGB-mode twins are counted in I12).
  * Left (66, the palette table, which Matt keeps failing): 63
    `palettes_checksum_*`, `palettes_old_license_33_new_license_01_checksum_
    01`, and `change_bgp_or_bug_checksum_d1{,_first_dot}`, whose title
    "INCREDIBLE" picks a boot palette too. dingbat's skip-boot hand-off
    always loads the default compatibility palette, where the boot ROM picks
    one by the title checksum (Pan Docs, "Power Up Sequence", compatibility
    palettes). SameBoy, running the boot ROM, passes all three sampled
    `palettes_checksum_*` and both `change_bgp_or_bug` tests.
  * Closed: all 53 failing `m3_lcdc_win_en_change_multiple_wx_timing_*`
    (90/90 pass). Each ROM writes WX = LY, pulses LCDC.5 low twice in mode 3
    (a fall and a rise eight dots apart, three NOPs between the pulses) and
    times the HBlank interrupt with `inc a`, an object at X = 79..88 moving
    the count. The counts were fitted per line against the object penalty
    `11 - min(5, (x - origin) mod 8)` on the window's and on the
    background's tile grid. Two rules:
    1. A WX match that LCDC.5 turned down earlier on the line no longer
       holds mode 3's tail for an unstarted window (`WIN_TAIL_PASSED_MATCH`,
       fetch_work_pending: the line was 2 dots long; ly10/32/38 and nops6,
       +15, SameBoy CGB E agrees on all).
    2. A CGB window start revoked k = 1..5 dots after the match
       (`CGB_WIN_EN_DEFER`) keeps its first tile and the window's tile grid
       instead of being undone (`CGB_WIN_REVOKE_KEEP`, single speed): lines
       33..37 fit exactly W = k (gambatte's `window/late_disable*` charge)
       on the window grid and nothing on the background grid (+38). SameBoy
       keeps the window grid too but charges 6 at every k.

    Also `CGB_WE_ENABLE_FETCH_LATE` = 2: an LCDC.5 rise reaches the
    fetcher's abort two dots late, as the fall does. In the 51
    `visual/m3_lcdc_win_en_change_multiple_wx_*` frames the lines where the
    rise lands on a window map read (WX = 2, 3, 22, 23, 30, 31) end the
    window where DocBoy and SameBoy both end it. Those frames still do not
    match (next point).
  * Left (51; scored again 2026-11-16), the
    `visual/m3_lcdc_win_en_change_multiple_wx_*` frames: mealybug's ROM (WX =
    LY, LCDC.5 pulsed low twice in mode 3) with DocBoy's tile data, on a CPU
    CGB E with a DMG cart. Per line, dingbat matches SameBoy (CGB E) on all
    but 18 of the 51 x 144 rows; on about 520 DocBoy alone draws other bytes
    for a window tile cut short by LCDC.5 k <= 4 dots after the WX match (low
    plane fetched, high plane the tile index; k = 0: two tiles of colour 0),
    on 87 SameBoy alone differs. mealybug upstream ships CGB C and CGB D
    references for `m3_lcdc_win_en_change_multiple_wx` (the
    game-boy-test-roms bundle carries only the DMG ones) and none for CGB E;
    its README calls its references "screenshots from my Game Boy emulator
    (which I believe to be correct)", with blurry photos of real devices
    alongside. Not known: which bytes a CGB E fetches for the cut tile;
    checking dingbat against the CGB C/D references is the next step. One
    more difference, which no test scores: on a k = 0 line (the match on the
    fall's own dot, `ly10`/`ly38` timing: no charge, background grid) DocBoy
    and SameBoy both still count a window line (the `_wly` frame's window
    rows run one ahead of dingbat's from line 10), and SameBoy draws one
    window tile at the next background tile; dingbat does not take the match
    at all. DocBoy disables two signed-addressing variants itself ("glitch
    is different").
  * Left (63 here, 10 in I12; scored again 2026-11-16),
    `change_{bg,win}_tile_data_glitch_*` (63 compat + 10 CGB): LCDC.4 flipped
    across a bitplane read with objects and windows at other phases. Per line,
    of 73 frames, 1,562 rows are DocBoy's alone, 1,831 SameBoy's alone
    (SameBoy passes none), 954 three-way, 82 dingbat's alone
    (`mealybug_var42`). dingbat's LCDC.4 glitch (`CGB_TDSEL_GLITCH`) is fitted
    to mealybug's CGB C/D references of `m3_lcdc_tile_sel_change{,2}` and
    `m3_lcdc_tile_sel_win_change` (its emulator's screenshots, see above) and
    to cgb-acid-hell, all of which pass, as do the family's other 56 rows (26
    `mealybug_shift*`, 24 `mealybug_var*`, 6 `sprites_nops*`). Not known: the
    CGB E's glitch at the phases only DocBoy's variations reach; no capture
    from a console covers them.
* **I4. HDMA / GDMA (0 left; 3 not scored).** `cgb/hdma` is 640/640 and
  `double_speed/hdma` 50/50; the three not scored are marked below. The rules, by group:
  * The LCD-enable line (95 tests in this and the next three points; 89
    here, `gb.nim` knobs, and the six double-speed tests with I7). The
    LCD-enable line has no OAM scan, so the VRAM DMA's HBlank input sees the
    mode 0 STAT shows there (`HDMA_LCDON_LINE0_M0`: an HBlank transfer armed
    in those 80 dots starts at once) and its mode-3 -> 0 request trails by
    `LCD_ON_STAT_READ_LAG`, AGE's 2 dots; the eight ly0 round1/round2 tests
    fail with a value on either side (`HDMA_LCDON_LINE0_LAG`). This is the
    40 `hdma_remaining_length_ly0_*` and `double_speed_hdma_basic_transfer`.
    Switching the LCD off makes an HBlank edge only from outside HBlank
    (`HDMA_LCD_OFF_EDGE`): `hdma_ppu_on_turn_off_during_{ly0_hblank,
    ly1_oam_scan}` and four `hdma_halt_resume_with_timer_interrupt_*`.
    SameBoy passes all of those.
  * The 7 `hdma_transfer_write_*` write only some of HDMA1-4: the hand-off
    leaves the counters at $D430 / $99D0, where the CGB boot ROM's last GDMA
    ends (the boot ROM run to $0100 in dingbat, every cart alike).
  * 19 `*_source_*` tests (`gdma_source_{vram,vram_corruption,
    vram_jp_in_ram,hram,io,oam,not_usable,echo_ram,from_vram_to_ram,
    overflow_source_illegal,wram_dma_source_ram_c000_8000_source_overflow_
    illegal}`, `hdma_source_vram_scx0-7`): a source no bus answers reads $FF
    except the transfer's first byte, the cartridge bus's residue from the
    M-cycle before the hand-over -- the opcode the CPU fetched there from ROM
    or cartridge RAM (`$AF` after an `xor a`), or a running OAM DMA's byte;
    after a fetch from WRAM or HRAM, $FF (`VDMA_BUS_RESIDUE`; Pan Docs:
    separate cartridge and WRAM buses, VRAM source "garbage", the rest
    untested).
    SameBoy fails all 19 tests but its VRAM (a black-box dump through its
    direct-access API) holds the same $AF in byte 0, and in byte 1 too, where
    DocBoy has $FF: two references on the residue, one on its length.
    gambatte's CGB-C `dma_*_read` tests check bytes 1-7 only; hardware
    question 22, gbedge p21 `VDMABUS`.
  * 16 `hdma_source_wram_dma_source_ram_during_pixel_transfer_*` (an OAM DMA
    beside an HBlank block): the block's ninth M-cycle does not hold the
    external bus, so the OAM DMA stores its own byte there
    (`VDMA_OVERHEAD_FREES_BUS`), and it leads the bytes for a block granted
    at an instruction boundary, trails them for one granted after an opcode
    fetch (`HDMA_BOUNDARY_ACQUIRE`, the split `HDMA_OVERHEAD_LEADS` already
    records for gambatte `oamdmasrcC000_hdmasrc0000`); SameBoy passes 6 of
    the 16.
  * All 83 `gdma_ppu_on_pixel_transfer_conflict_relaxed_*`
    (`VDMA_M3_PORT`, gb.nim; `vdma_port_busy`, fifo_ppu.nim): a 128-byte
    GDMA (SCX 0..7), or 32..80 bytes beside a window (WX 16..23) or one or
    two objects (X 1..50), started 110 M-cycles after an LCD enable so it
    runs from line 1's OAM scan through mode 3; each ROM compares the bytes
    from 16 on with its own map. The fetcher owns the VRAM bus on its reads
    and a DMA byte that meets one is lost (Pan Docs: GDMA "blindly attempts
    to copy the data, even if the LCD controller is currently accessing
    VRAM", and says no more). Each read holds the bus for its two-dot step,
    ending on the dot dingbat already reads on: the BG/window fetcher's map,
    low and high steps (not the head's discarded fetch, and the fetcher
    steps once more on the dot after the last pixel, which is what ends SCX
    2/4/6 a byte later than SCX 1/3/5/7), and an object's two plane reads on
    the dots their LCDC.2 reads were already fixed to (mealybug
    `m3_lcdc_obj_size_change`: M and M + 2 in the tail case;
    `OBJ_PLANE1_HEAD`, bounded only from above there, is 4 for the head
    case's T + 2 and T + 4, where `_x01`..`_x06` put them). A byte whose
    slot starts on dot c meets the bus as it stands on pipeline dot c - 1;
    c - 2 keeps 37 tests (an odd object penalty moves the holes by a dot),
    c keeps 1. The DMA asks only between the two dots of a byte in a block
    that can reach mode 3; nothing runs on the dot loop (retired
    instructions -0.03..-0.16% on Crystal, LADX DX, Shantae, Pokemon Blue,
    frames and states identical). Three-way from byte 32 on: on 22 tests all
    agree (all 8 SCX, all 8 window, 6 object tests), on 60 object tests
    SameBoy differs from both around the object fetch, and on one SameBoy
    differs from DocBoy and dingbat now follows DocBoy:
    `..._64_bytes_sprite_y16_x07` (closed 2026-11-17, `OBJ_HEAD_SLIDE`). The
    head arm (X < 8) read its planes on T + 2 and T + 4 for every X; DocBoy's
    maps put X = 7's two dots later and X = 5, 6 where X = 1..4 have them.
    The tail arm has that shape already: its reads stay put while Pan Docs'
    wait `max(0, 5 - sub)` shrinks, then walk a dot per pixel with the
    trigger once the wait is clamped at sub 5, and DocBoy's own X = 13, 14,
    15 maps are X = 5, 6, 7's four bytes later (one tile). The head's first
    object now slides its reads `max(0, sub - 5)` dots; the stall is Pan
    Docs' as before, so no mode-3 length moves (X = 6's one dot is below the
    DMA's two-dot resolution). SameBoy (09674ebf) gives X = 7 the X = 6 map,
    the old model's. No spec text places the reads; hardware question 21
    (gbedge p21 bytes 00-0F) covers the background map, not this case.
  * 3 `gdma_source_wram_dma_source_ram_{160,256,480_bytes_overflow}`: the
    ROMs `Memcmp` all of `$FE00-$FEFF`; dingbat's OAM matches byte for byte
    and only the `$FEA0-$FEFF` readback differs (SameBoy fails all three).
    Not scored, with I10.
  * `hdma_start_during_oam_scan_with_dma_running`: armed in mode 2 under an
    OAM DMA, the block starts at once (DocBoy and SameBoy). The OAM scan
    already reads as mode 0 in STAT while an OAM DMA holds OAM
    (`STAT_M2_DMA_READS_0`, the DMG `dma_*_check_stat_*` tests, SameBoy on
    DMG B and CGB E), and the VRAM DMA's HBlank input follows the mode STAT
    shows, as on the LCD-enable line (`HDMA_LCDON_LINE0_M0`):
    `HDMA_M2_DMA_HBLANK`, ppu.nim. Hardware question 23 (gbedge p22
    `VDMAOAM`) checks it. `..._during_oam_scan` starts the same way and its
    OAM bytes match DocBoy's exactly; the VRAM bytes the block loses once
    mode 3 begins (6-8, 10-12, 14-15) are the mode-3 VRAM port above
    (`VDMA_M3_PORT`), and it passes with it (SameBoy fails it).
  * The six double-speed `speed_switch_to_{double,single}_during_hdma{,_div,
    _stat}_round2` pass with the speed-switch stall's halt model (I7): the
    HBlank STAT request ends the stall, as in
    `speed_switch_to_double_interrupt_stat_round2` without a DMA.
* **I5. DMG OAM corruption patterns (6 left of 268).** `dmg/oam_bug` is
  262/268; the 6 left are below. Each ROM fills OAM with a known pattern,
  turns the LCD on, waits `103 + n` M-cycles so its one OAM access lands on
  scan row `n - 3` of line 1 (round 3: the M-cycle ending on the scan's first
  dot; round 23: the one after its last row), turns the LCD off and compares
  all 160 bytes. The `_fe4x` tests move the CPU's address at round 22/23, the
  `_fe5x` tests sweep a 512-entry truth table (row 0 and row 11 bits, the
  written bit) at round 3. The maintainer runs the suite on his DMG; the
  `_noisy` suffix is not defined upstream. SameBoy (DMG B, black box, OAM
  dumped after each test) passes 246/268; every test it fails, dingbat failed
  too.

  The rules: plain CPU reads and writes of `$FE00-$FEFF` corrupt (Pan Docs,
  "OAM Corruption Bug": "Any memory access instruction, if it accesses OAM";
  `mem_read_data`/`mem_write`, fetches unhooked), and the patterns follow the
  tables, which refine Pan Docs' three formulas rather than replace them: a
  write is Pan Docs' write corruption; a read on an odd scan row leaves Pan
  Docs' read-corruption word in rows R-1 and R; a read on an even row is Pan
  Docs' "read during increase/decrease" pattern (rows 2 and 4 included),
  copied onto every row the scan's row address passes through (R-2; R-4 when
  R % 4 == 0; 0 when R % 8 == 0); an IDU step beside a read or write adds
  nothing (`ld a,[hli]` measures identical to `ld a,[hl]`, pop is two reads);
  at rounds 3 and 23 the CPU's own row and word join (ppu.nim, "The DMG OAM
  corruption bug"); a word-3 write at round 23 also corrupts word 2
  (docs/dev/gb-derivations.md, "DMG OAM bug: a word-3 write after the
  scan's last row"). Pan Docs' rules alone, plain accesses wired, match 107
  of the 259 pattern tests; the model matches DocBoy on 253 and SameBoy on
  243 (SameBoy fails the four round-23 word-3 writes), and every test
  matches one of the two. blargg `oam_bug` (singles and
  combined, test 7's CRC included) still passes; a line-offset probe (rounds
  2..24 on lines 1, 2, 6, 101, 142 and 143, plus the 143/144, 152/153 and
  153/0 line boundaries) matches SameBoy except at R = 8/16, where dingbat
  follows DocBoy.

  Two `dmg/ppu` tests pass with it: `oam_write_block_timing` (114
  `ld [hli],a` writes across line 1; the round-3/round-23 rules decide the
  scan's first and last M-cycles) and `oam_scan_blocked_by_idu_write_round2`
  (an access in mode 2 takes the OAM bus from the scan for its M-cycle, the
  entries read then compare the last Y/X held; `fifo_oam_bus_taken`). Its
  `cpu_write` twin needs the same rule now that a plain write corrupts: the
  object one row up is hidden, its corruption copy is found. SameBoy fails
  both `round2` tests.

  Closed 2026-11-17: `ld_{hl,hli}_a_round23_fe46/fe47`, a word-3 write at
  round 23 also corrupting word 2 (`$55` -> `$11`; the rule and its
  evidence are in docs/dev/gb-derivations.md).

  Left (6; scored again 2026-11-17), each a single unit's margin that no
  sibling test shows: `ld_{hl,hli}_a_round3_fe5c`, `_fe5e_noisy`, `_fe5f`.
  The ROM sets bit 0 of each byte of rows 0 and 11 from an 8-bit index
  (both bytes of a word equal), writes v = 0/1 to the byte, and records
  row 0's bit 0s, 512 entries. Every byte of row 0 matches the model but
  the written one; there, on DocBoy's DMG, `fe5f` (word 3, byte 1) gives
  v | old row 0 bit, `fe5e` (word 3, byte 0) v | (old & row 11 word 0), and
  `fe5c` (word 2, byte 0) v except in 8 entries with v = 1 (row 11 word 0
  clear, word 2 clear in both rows, words 1 and 3 equal in both). The
  `fe58`..`fe5b`/`fe5d` tables (the other byte lanes) and SameBoy (all eight)
  give v. No byte-symmetric rule fits both `fe5e` and `fe5f`: with both
  bytes of every word equal, a rule that treats the two lanes alike gives
  one function for both, and the tables give two; the same holds for
  `fe5c` against `fe5d`. So each needs a per-lane (per bit-column) term,
  which is a lookup of these tables rather than a rule. Not known: whether
  these are the DMG's columns or one unit's margin, since one console stands
  behind the tables. Hardware: the six ROMs on an MGB, pass/fail screens,
  with `ld_a_hl_round11` (row 0 at R = 8, DocBoy only) as a control.
* **I6. DMG window glitches (49 left of 120).**
  * Closed: `window_retrigger_pixel_glitch_*` (67) and
    `window_bg_reprise_wx{15,23}`. Each ROM turns the window off in the WY
    line's HBlank, so every later line has WX matching with LCDC.5 low.
    Where the match is on a tile boundary the reference draws a colour-0
    pixel and the rest of the line one pixel right: Pan Docs, "Window" ("a
    single pixel with ID 0 ... is inserted; this offsets the remainder of
    the scanline"), the Star Trek glitch. dingbat inserts the pixel rather
    than replacing one (`WIN_EN_HOLD_ZERO = 2`, gb.nim). SameBoy (DMG B)
    passes all 279 of the family. mealybug
    `m3_lcdc_win_en_change_multiple_wx`'s t = 8 / t = 32 pixels are
    identical under both (the window starts on the next pixel).
  * Closed: `window_bg_reprise_wx{14,22}`. The background tile the fetcher
    resumes with after LCDC.5 goes low (WIN_EN_ABORT) is the one under the
    pixel right of the push position on the DMG (`WIN_ABORT_COL_LEAD = 1`;
    values on both sides fail over the 18 WX of the family; DocBoy's and
    SameBoy's CGB keep 0).
  * Left (43; scored again 2026-11-16): `window_turn_off_*`. LCDC.5 is cleared
    during the window's first tile fetch on line 8, at 4-dot phases (an
    object's X shifts the fetch, `nops21..25` the write). On 40 tests the
    write lands between the window map read and its bitplane reads, and
    DocBoy's reference reads that tile's data from the BACKGROUND's row,
    `(LY + SCY) and 7`, where dingbat keeps the window row; SameBoy (DMG B)
    draws dingbat's frame pixel for pixel on all 40. On the other 3
    (`window_turn_off_nops22_sprite_x3_variation_{a,b}`,
    `_alt_nops22_sprite_x3`: the write right after the WX match) all three
    emulators differ, and SameBoy fails 17 further tests of the family that
    dingbat and DocBoy pass. A note in mealybug's repository says the
    disable "will take effect at the end of the current window tile", i.e.
    that tile is drawn as a window tile, but the document it comes from is
    based on mealybug's test ROMs and its emulator, not a console
    measurement. Not known: what the DMG draws; no spec text covers it. The
    decider is one photo on the MGB: `window_turn_off_nops22_sprite_x4`,
    line 8, x = 9..16 reads `32222222` (shades; DocBoy) or `00000222`
    (dingbat, SameBoy).
  * Left (6): `window_wx0_scx{1..6}`. WX = 0 with SCX & 7 = s: DocBoy and
    SameBoy draw the window's 9-pixel black head as 9, 7, 6, 5, 4, 3, 2, 2
    for s = 0..7; dingbat draws 9, 8, 7, 6, 5, 4, 3, 2, which is Pan Docs,
    "Window" ("shifted left by SCX % 8 pixels"). mealybug
    `m3_window_timing_wx_0` paints a uniform window, so it fixes the first
    pixel's dot, not which window pixel it is. Spec against two references:
    a hardware question, not changed. The decider: these ROMs on the MGB,
    the length of the black run at the left of line 0 for SCX = 1..6.
  * A rule no scored DocBoy test covers: the same ROM patched to WX = 0..8 x
    SCX = 0..7, DMG and CGB. SameBoy (DMG B and CGB E, black box) shifts
    the window by SCX & 7 only at WX = 0 (Pan Docs' WX = 0 paragraph: the
    window "is switched to before the initial fine scroll adjustment", so
    later WX are not). dingbat used to shift every line that starts as a
    window line at WX = 1..5 as well (the discard is `7 - WX + (SCX and
    7)`, fifo_sample_smooth_scroll) and not WX >= 6. Now the discard's first
    SCX & 7 pixels are the fine scroll's, not the window's (`WIN_FINE_PAD`,
    gb.nim; `fifo_pad_unpop`, fifo_ppu.nim): the same dots, so mode 3 keeps
    the length gambatte `window/m2int_wx03_scx{2,3,5}_*` and mealybug
    `m3_window_timing*` fix, and the window sits at WX - 7. All 64 cells at
    WX = 1..8 match SameBoy on each device, frame for frame; nothing else
    in the full runner changes; retired instructions within +0.01% on four
    games. `nimble test_gbwindowscx` (tests/gb_window_scx_test.nim) draws
    the grid from a program assembled in the test and asserts every cell but
    the WX = 0 hardware question above; SameBoy draws all 131 asserted cells
    the same way.
* **I7. Speed-switch interrupt and STOP timing (79; closed, 8 not scored).**
  Closed. `double_speed/interrupts` is 246/246 and `double_speed/interactive`
  67/67; the 8 not scored are the IME-set leaf (below).

  All 49 `double_speed/interrupts/speed_switch_to_*` and `*_serial_halted_*`
  tests and 10 of the non-input `double_speed/interactive/*stop_key*` tests:
  the switch's stall is the CGB HALT of the switch leaf (Pan Docs' STOP
  chart: "HALT mode will exit automatically after about 0x20000 T-cycles")
  and behaves as one:
  * It holds the PPU back one M-cycle as every CGB halt does
    (`SPEED_SWITCH_HALT_PPU_LEAD`, memory.nim: a STAT or VBlank request ends
    it one M-cycle later, a timer request does not move, c-sp's
    hardware-checked timer block included).
  * It asks for an interrupt before its first M-cycle, by when the PPU has
    run 6 of the switch's 8 extra dots (`SPEED_SWITCH_ENTRY_IRQ_CHECK`; the
    54 `*_aligned_with_stop_nops_*` tests walk the STOP across the mode-0
    and VBlank edges and fix it at 6: values on both sides fail).
  * Its latch misses a serial request raised on the M-cycle's last T-cycle,
    like every halt's (`SERIAL_HALT_TAIL_BLIND`, serial.nim, which also
    closed the DMG and CGB `serial_interrupt*_halted_round2` tests).
  * A TIMA overflow ticked by the switch's own DIV reset reloads one M-cycle
    later, through the ordinary window (`SPSW_DIV_RESET_RELOAD_LATE`,
    timer.nim).
  * The leaf the chart defines -- a request pending, IME clear: "STOP is a
    1-byte opcode, mode doesn't change, DIV is reset, CPU speed changes" --
    holds the divider two M-cycles of the new speed
    (`SPEED_SWITCH_IME0_LEAF_HOLD_T`, [5, 8] T).

  SameBoy (CGB E) passes every one of those tests but six (five aligned
  tests and `speed_switch_to_single_interrupt_vblank_d_round2`). The other
  20, all `double_speed/interactive`:
  * Not scored (8; `DocboyNotScored`, ledger "DocBoy: the KEY1 switch's
    IME-set leaf"): `{,double_speed_}stop_key1_joypad0_interrupt1_ime1_*_
    div_round1`, the IME-set leaf. DocBoy wants the same 8 T hold as with
    IME clear; AGE `speed-switch/caution/spsw-interrupts-cgbE` (source
    header: "Verified: 2022-02-11 pass: CPU CGB E - CPU-CGB-06"), scored and
    passing here, runs the same `EI; STOP` with a request pending and needs
    4 (`SPEED_SWITCH_IRQ_LEAF_HOLD_T`, `spsw_irq_leaf_hold_short`). With an
    8 T hold all eight DocBoy tests pass and exactly that AGE row breaks: the
    two ROMs disagree by one M-cycle. AGE's own runner blacklists
    `speed-switch/caution`, and its WARNING.md reports the author's CGB E
    unstable for a while after running those ROMs several times in a row.
    Pan Docs' STOP chart is no citation either way: the rendered
    `imgs/stop_diagram.svg` puts "The CPU glitches non-deterministically" on
    IME disabled, the older `imgs/gb_stop.png` in the same repo on IME
    enabled.
  * Closed: 12 PPU-phase tests of the IME-clear leaf,
    `stop_key1_joypad0_interrupt1_ime0_ly_round2` (into double speed) and
    `double_speed_stop_key1_joypad0_interrupt1_ime0_{ly,ly_b,stat,stat_scx*,
    serial_scx*}_round1` (into single). Each reads LY or STAT a fixed count
    of M-cycles after the leaf STOP. Sweeping that count on rebuilt ROMs puts
    every DocBoy edge exactly +4 dots (into double) and -5 dots (into single)
    from where dingbat's was; values on both sides fail (a PPU shift of
    +3/+5 or -4/-6 at the switch loses tests; nothing else in the 3,600
    double-speed, STOP and switch tests moves). SameBoy (CGB E) sits on
    DocBoy's edges into double and for STAT into single, and one M-cycle
    earlier for LY into single: it passes 9 of the 12 (not the two LY tests
    nor `serial_scx3`, the test that splits -5 from -4). The pair is the
    leaf's oscillator restart with no new number: the divider already sits
    out two M-cycles of the new clock there (`SPEED_SWITCH_IME0_LEAF_HOLD_T`,
    8 T), and the PPU sits out the same two (4 dots into double, 8 into
    single) after taking the switch's own extra dots, the stall's
    `SPEED_SWITCH_PPU_EXTRA_DOTS` 8 / `_SINGLE` 3: 8 - 4 = +4, 3 - 8 = -5
    (`SPEED_SWITCH_LEAF_PPU`, timer.nim; `GbMemory.ppu_mdot_shift`, GB
    payload rev 10, which also carries the divider's hold). The IME-set
    leaf takes the same rule with its own hold (`SPEED_SWITCH_LEAF_PPU_IME1`;
    no test reads the PPU after it).
* **I8. Other APU (146; closed).** Closed. No test of this item fails: the
  only failing APU tests are I1's 79 and I2's 11. Each rule was checked
  against the test source, with SameBoy (black box, CGB E) as the second
  witness and probe ROMs run on both where the tests left a rule open:
  * CH3 stopped by NR30 in the half-cycle before a sample read
    (`cgb/apu/ch3/ch3_disable_channel_while_sampling_*`, 30, and the 9
    double-speed `_period_4_round*`). The read is not cancelled, but the
    channel has let go of wave RAM's address, so the byte latched is the one
    at the low nibble of the CPU's next opcode fetch: the `_phaseN` tests
    (one `nop` more before the APU setup) and the `_round0b..g` tests (one
    more before the stop) move the byte read one per byte of code, and
    `round0a` changes only the wave byte that address names. Two more rules
    the family fixes: a stopped CH3 reads no samples (its timer freezes, as
    on the pulse channels), and the DAC does not clear the sample buffer (Pan
    Docs, NR34: only an APU power-off does). The old clear came from SameSuite
    `channel_3_restart_stop_delay`, whose first trigger runs with NR30 = $00
    left by its fill loop, so its channel never read a sample.
    `ch3_write` NR30, `ch3_catchup_at`.
  * The CGB restart of a running CH3 in that same half-cycle
    (`double_speed_apu_ch3_retrigger_period_{4,6}_*`, 7): the read in flight
    latches byte 0 (the pointer it now holds), the CGB's version of the DMG's
    restart corruption. `ch3_write` NR34.
  * The envelope with a period of 0 (`cgb/apu/ch1/ch1_change_volume_sweep_
    pace_*`, 39). The timer counts a period of 0 as 8 (Pan Docs, "Audio
    Details") instead of standing still, so `$A8` triggered and `$A9..$AF`
    written later steps on the trigger's eighth envelope clock; and the
    enable glitch (SameSuite `nrx2_speed_change`) lands on the first step
    after the DIV-APU tap bit next rises (next step if the bit is low at the
    write, else the one after), acts only on a timer that has not counted
    since a period-0 load, and then stands in for its expiry (step, reload,
    one more if step 7 is next). Thirteen probe ROMs (writes before and after
    the first clock, either side of a tap rise, decreasing, at the volume
    limit, enable/disable/enable) read the same on SameBoy and dingbat.
    `psg_volume_step`, `psg_write_nrx2`, `psg_seq_step` (GB only; the GBA
    keeps its model).
  * `dmg/apu/ch1_length_timer_delay{0,1024}` (2): the boot hand-off's
    length gate follows `BOOT_FS_STAGE_DMG` (`skip_boot`), so a length
    enable before the stage-1 step gets the extra clock.
  * The CGB E's double-speed envelope clock (`double_speed_apu_ch2_volume_
    sweep{,_b,_c}_round1`, 3): it lands 2 T after the divider's tap edge,
    so PCM12 on the step's M-cycle still reads the old volume, while a
    length clock lands on the edge. Probe ROMs: SameBoy CGB E shows the
    same with the DIV reset moved against the power-on and a length expiry
    on another step on time; SameBoy CGB C shows the step at once. Not on
    top of the KEY1 tap lag, which already makes the step that late.
    `GbQuirks.env_clock_ds_late`, `ENV_CLOCK_DS_LATE_T`, `apu_env_late_due`
    (GB payload rev 8 carries the pending step).
  * The KEY1 re-phase at the 2 MHz grid: `speed_switch_to_single_apu_ch3_
    period_1` (1; the wave channel lands on the re-phased 2 MHz grid's
    previous edge, `APU_SPSW_REPHASE_LEAD3_T`, all revisions) and
    `speed_switch_to_double_apu_ch2_volume_sweep_*_round2` (8; on CGB E the
    squares do too, `GbQuirks.spsw_apu_rephase_2mhz`, where dingbat read a
    zero duty sample one M-cycle early; SameBoy CGB E's duty window in a
    probe of the same code agrees, and CGB C keeps gambatte's 3 T, H2).
    SameBoy CGB E itself fails four of the `_round1` partners, which DocBoy
    and dingbat agree on.

  The 33 double-speed CH4 shift/divider tests closed with I1.
* **I9. Boot hand-off state (20 left of 46; 4 not scored).** Measured by
  running Matt's CGB and DMG boot ROMs through dingbat (a local instrument,
  never committed): the hand-off per header path, beside the skip-boot state.
  * Closed (22, and `cgb/ppu/turn_off_read_stat` with the STAT bit): DIV at
    `$0100` per licensee path (`cgb_boot_header_t`, timer.nim: every old
    licensee but $01/$33 one time, $33 with a new code not starting '0' 4 T
    earlier, '0x' 32 T later, a licensed cart 4,360 T later when its title
    checksum matches no palette entry, the same in CGB and compatibility
    mode; mooneye's own header is the -4 path, so `boot_div-cgbABCDE` keeps
    0x2674); the compatibility-mode PPU phase (LY 148, dot 353:
    `CGB_COMPAT_BOOT_PHASE`), its frame-sequencer step and CH1 duty phase;
    STAT's LY=LYC bit at a CGB hand-off ($81); the BG palettes as $7FFF
    words; BCPS/OCPS $C0/$C1 and SVBK $F8 for a CGB cart (`boot_regs_cgb`,
    which also needed OPRI, I11); the HRAM the boot ROMs leave (the cart's
    logo at `$FF80`, their stack residue). `cgb/boot/boot_regs_joypad`
    (P1 = $CF with a CGB cart) closed with I13's P1 hand-off.
    `cgb_dmg_mode` `boot_vram_nintendo_logo_checksum_{43,58}` (2026-11-17):
    the logo tile map over a Nintendo-licensed DMG cart with title checksum
    $43/$58, a two-value rule in Pan Docs that needs no table
    (docs/dev/gb-derivations.md section 8).
  * dingbat's own boot-ROM run handed off 4 T short of mooneye
    `boot_div-dmgABCmgb` and `boot_div-cgbABCDE` with the PPU phase already
    right, so the divider starts 4 T on when a boot ROM runs
    (`BOOT_ROM_DIV_START_T`). With Nintendo's boot ROMs the run then passes
    both mooneye tests and every DocBoy `boot` test, the table-dependent
    ones included, but `boot_hram` ($FFFE, below).
  * Left on the skip-boot (20): the `cgb/boot` `boot_div_title_*` tests whose
    DIV is set by WHERE the title checksum sits in Nintendo's
    compatibility-palette table (REDUCTIONS, checksum $00, is in it; so are
    16/46A/46E/46R/6F/BF/F4; the 4th-letter ones also by the letter table).
    All are Nintendo-licensed DMG-flagged carts (CGB flag $00), so the
    "cgb" rows run in compatibility mode. The index is an arbitrary order,
    so no formula stands in for the table, which is not carried (Matt,
    2026-10-14), as for I3's 63 palette tests.
  * Not scored (4; ledger "DocBoy: `boot_hram`"): three ROMs (the dmg
    manifest lists its ROM twice) match in every byte but `$FFFE`, which no
    boot ROM writes and they expect as $4C (dmg) or $C0 (cgb, cgb_dmg_mode);
    DocBoy's source: "FFFE seems to be hardcoded to C0 even before boot rom".
    Pan Docs ("Power Up Sequence"): "The console's WRAM and HRAM are random
    on power-up."
* **I10. `$FEA0-$FEFF` (closed; 29 not scored).** Closed. A read while OAM
  is blocked answers $FF on every model (Pan Docs, "FEA0-FEFF range"): the
  six `not_usable_read_{oam_scan,pixel_transfer}` tests (DMG, CGB, compat)
  pass.
  Not scored (`DocboyNotScored`, ledger "DocBoy: $FEA0-$FEFF as RAM on the
  CGB E"): 26 tests (13 in `cgb/memory`, 13 in `cgb_dmg_mode/memory`) that
  all write the area outside mode 2/3 and read it back, expecting RAM with
  `$FEC0-$FEFF` repeating 16 bytes. Pan Docs gives RAM only to CGB revisions
  0-D ("a unique RAM area, but is masked with a revision-specific value"; it
  describes no 16-byte repeat) and has CGB E, AGB, AGS and GBP return the
  high nibble of the low address byte twice, which dingbat follows
  (`urNibbleEcho`); under dingbat's CGB D model 14 of the 26 pass. With them,
  the three `hdma/gdma_source_wram_dma_source_ram_{160,256,480_bytes_
  overflow}` tests (I4), whose only miss is this readback. No CGB E has been
  measured; a flashcart answers for this range itself
  (docs/dev/hwprobe-questions.md), so it needs a CGB E with a real cart.
* **I11. CGB header modes (15 left).** `mode_cgb_flag_{81,82,83,90}` pass:
  the header read follows Pan Docs ("0143 — CGB flag", "Power Up Sequence",
  "FF4C — KEY0"): bit 7 picks the CGB and copies the byte to KEY0, so CGB
  mode unless KEY0 bit 2 or 3 is set.

  Left: the 15 `cgb_dmg_ext_mode` tests (`banks` 2, `ir` 1, `key1` 1, `mode`
  8, `ppu/opri_write_read`, `serial` 1, `undocumented/ff74_write_read`).
  They are PGB mode (`$0143 = $88..$8F`, KEY0 bit 3), which Pan Docs leaves
  unresearched and dingbat does not model (those carts stay on the
  compatibility path); DocBoy's "DMG ext mode" (SVBK, VBK, RP, KEY1, SC.1,
  FF74 and OPRI answer as in CGB mode, BCPD and HDMA do not) is its own model.
  Its sources name no hardware run, but these ROMs (and the KEY0 `mode`
  ones) alone end a failure with a beep, which reads like a verdict meant to
  be heard on a console whose LCD may be elsewhere. SameBoy CGB E, with its
  own boot ROM and with Nintendo's, fails the same 14 (it passes
  `opri_write_read`): a NotScored candidate until a console answers. The
  ROMs are their own probe: on a CGB or AGS from a flashcart, a beep is a
  failure, silence a pass (`mode_cgb_flag_88`, with `cgb_dmg_mode/mode/
  mode_cgb_flag_84` as the silent control).

  OPRI itself (`$FF6C` bit 0, Pan Docs "FF6C — OPRI") is a register in CGB
  mode, $FF in compatibility mode (`cgb/ppu/opri_write_read`,
  `boot_regs_cgb`; the AGS read $FE at hand-off).
* **I12. CGB pictures (36 left of 46), and CGB PPU timing.**
  * Left (13; scored again 2026-11-16): `ppu/visual/turn_off_y*`. The ROMs'
    own comment: "Depending on the timing, the next lines are either kept,
    rendered, or cleared": the references keep rows drawn before LCDC.7 went
    low and show later rows white or redrawn, where Pan Docs (LCDC.7) has
    "When the display is disabled the screen is blank" and, on re-enabling,
    "the screen will stay blank during the first frame", as dingbat draws.
    The three `_b` partners checked a frame later pass. Not known: what a
    CGB's panel holds across an LCD off/on; Pan Docs describes the screen,
    not the panel's retention. The 10 `change_{bg,win}_tile_data_glitch_*`
    CGB-mode tests are counted with I3's family.
  * Closed: `stop_during_hblank`, `stop_during_oam_scan`,
    `stop_ly42_during_hblank #2` (the `_b` reference). STOP with the LCD on
    blacks a CGB screen outside mode 3 (Pan Docs, "Using the STOP
    Instruction"), which stop_panel draws, but DocBoy's runner checks at the
    next mode-1 M-cycle and dingbat's PPU stays frozen in STOP; the harness
    takes the frame the panel presents during STOP as that VBlank
    (`docboy_run_one`, tests/README.md), which can only turn failing tests
    into passing ones. SameBoy (CGB E) passes all three.
  * Left (2), a hardware question: `stop_ly42_during_hblank` (the `_a`
    reference) and `stop_during_pixel_transfer_alt` STOP inside the first
    frame after LCDC.7 is set and want that frame's lines on the panel
    (lines 0..42, then black; the whole picture held for the mode-3 STOP).
    DocBoy and SameBoy draw the first frame; Pan Docs (LCDC.7) says "the
    screen will stay blank during the first frame", which dingbat follows.
    The decider: the same ROM on Matt's GBC, does the top of the screen show
    the coloured bars?
  * Left (8), a hardware question: `window_wx0_scx{1..7}` and
    `window_wx0_scx1_fancy_tile0`, the CGB twins of I6's DMG tests (WX = 0
    with SCX & 7 = s: DocBoy and SameBoy CGB E shift the window by s + 1,
    capped at 7, Pan Docs by s, dingbat by s). Same decider on the GBC.
  * `change_wx_glitch*` (9; 7 closed, 2 left). WX = 6, 7 or 8 written in
    mode 2 of each line and WX = I (0..127 down the frame) stored 85, 89 or
    93 dots in (`nops16/17/18`; 117 for the plain tests' 24 NOPs): inside or
    just after the head's first real fetch, where the comparator decides the
    line, and then re-reached while the window draws, at every fetcher phase
    in turn down the frame. Two mechanisms, each checked line by line against
    SameBoy (CGB E, black box), which draws every line they change as
    DocBoy does:
    * `WIN_HEAD_WX_SCAN` (gb.nim; `fifo_wx_store_head`): the comparator
      compares one position per dot through the head's first fetch,
      position `fetch_counter - SCX & 7`, the pre-pixel slot (WX = 6) on the
      dot before the first pixel, and a store reaches only the positions not
      yet compared. At 85 dots (position 3) WX = 3..5 still start the line as
      a window line and 1..2 do not; at 89 (position 7, the first pixel's
      dot) a stored 6 has missed its slot (the line drew no window and did
      not count, which put every later window row one behind), while an old
      6 replaced there has already matched (`wx6_nops17` line 8). The head
      latch is that scan seen before its
      first position: mealybug `m3_window_timing` (stores before it) and
      `m3_wx_6_change` (after it) decide as before. Closed `wx6_nops16`,
      `wx7_nops17`, `wx8_nops17`.
    * `CGB_WIN_RETRIG_LATCH` (gb.nim; `fifo_win_retrig_cgb`), the glitch the
      ROMs are named for ("depending on the fetcher phase make it either
      read an old tile data or do not read the tile number"): a CGB
      re-trigger on the dot of a push makes the next fetch keep the tile
      number just pushed for both planes; on the dot the tile number is read
      it leaves the low plane reading the previous tile's; the other six
      phases change nothing (111 lines across the six tests, every one
      DocBoy's and SameBoy's alike). Closed `wx6_nops17`, `wx7_nops18`,
      `change_wx_glitch{,_alt}`.

    Left (2): `wx8_nops18{,_alt}`, 4 pixels of line 17 each: the re-trigger
    lands on the window's first push, the startup fetch's (high plane and
    push on one dot), and both references draw that first tile as colour 0
    (the next tile already shows its data, by the push-dot rule). One line
    of one geometry; not modelled. SameBoy differs from DocBoy (and now
    dingbat) on 6 to 13 other lines of five of the tests.
  * Left (1; scored again 2026-11-16): `window_bg_reprise_wx25`, the window
    disabled on the WY line, the background resuming where the fetcher
    stood. On line 12 DocBoy draws x = 26..33 in colour 0 where dingbat draws
    BG tile $A3: the BG fetch for column 3 read its map byte at dot 108, the
    window starts at dot 110 and LCDC.5 aborts it at dot 115. The 17 CGB
    siblings (`_wx8`..`_wx24`) pass. Not known: whether a CGB keeps the
    aborted fetch's tile there; no spec text says.
  * Closed, `double_speed/ppu/double_speed_ppu_vram_write_block_
    timing_ly0_{1,3}_out_of_4` (2): VRAM writes one double-speed M-cycle
    apart across the LCD-on line's mode 3. The CGB write lock there closes
    one CPU M-cycle and a dot past the mode-3 flag edge (5 dots single
    speed, inside the 5..8 that gambatte `ly0_late_vramw_*` allows; 3
    double, where DocBoy's tests allow 2..3) and opens
    `LCD_ON_LINE0_LOCK_LEAD` dots past the mode-0 edge, as the read lock
    does (DocBoy's tests allow 2..3). SameBoy (CGB E) passes both; nothing
    else moves (`VRAM_WRITE_LINE0_CGB_GRACE`, `VRAM_WRITE_LINE0_OPEN_LEAD`,
    gb.nim).
* **I13. Rows with scripted input (10 left of 71; 3 not scored).** Through
  `--input`; 58 pass, every joypad picture and `stop_joypad*`/`stop_key*`
  interrupt test among them.
  * Not scored (3; ledger "DocBoy: a joypad interrupt on key release"): 2
    `joypad_{buttons,dpad}_interrupt_release` and DMG
    `stop_immediate_exit_joypad_interrupt`.
    DocBoy raises the joypad interrupt when the key is released; only
    `stop_immediate_exit_joypad_interrupt` names a cause ("even on button
    release, because of switch bouncing"). Pan Docs ("Joypad Input", "INT
    $60") raises it on a P10-P13 high-to-low edge and names bounce on the
    press ("one or more High to Low transitions are usually produced when
    pressing a button"); gambatte's hardware note (test/hwtests/jpadirq.txt)
    has transitions "multiple times per button press/release", so release
    bounce is real, but with a varying count. DocBoy's
    `joypad_keep_pressed_interrupt` asserts exactly one interrupt for a held
    press, so its model is bounce on release only, every time. A
    deterministic release interrupt would fire in every game on every key
    release; not modelled. Here the two release tests read the fail value and
    `stop_immediate_exit_joypad_interrupt` never reports ($FFF0 stays $00).
    In `stop_immediate_exit_joypad_interrupt` the key is held at the STOP
    with IE.4 set and nothing pending, so STOP is a HALT (Pan Docs' chart;
    dingbat takes it) and the ROM expects the release to end it (DocBoy's
    switch-bounce model, its comment says so). A second press wakes it
    (checked).
  * Left (10): the DMG tests that leave STOP with a key press and then read
    LY or STAT, or check an interrupt (`ppu/interactive/stop_read_ly{,_alt,
    _alt_alt}_round{1,2}`, `stop_read_stat_round{1,2,3}`,
    `stop_trigger_interrupt`): `$FFF0 = 2`, the wake happens but the phase
    after it disagrees. dingbat freezes the PPU through STOP (Pan Docs is
    silent); DocBoy's tests need the PPU to have run exactly 2^17 + 4 dots
    across the stop with the timer and DMA held -- `STOP_WAKE_PPU_DOTS =
    131076` (cpu.nim, default 0) passes all 15 DMG STOP tests and no
    neighbouring value does -- which is an oscillator restart on the way out
    (the switch HALT's 2^17), not a PPU running for as long as the key took,
    so a ROM meant for a hand on a real key can encode it. SameBoy (DMG B)
    fails all ten. Hardware question: tools/gbprobe/probe_l_stopwake.gb
    (MGB; press A within a second each time, since Pan Docs warns a DMG left
    in STOP with the LCD on can be damaged): six trials, `14 82 09 00 15`
    each is dingbat's frozen PPU, `00 85 09 00 01` is DocBoy's 2^17 + 4,
    TIMA `89` would be a timer that ran through the restart, and LY changing
    from trial to trial a PPU that runs through the whole stop.
  * Closed: the DMG `timers/interactive/stop_read_tima_*` and
    `dma_stop_during_transfer_timing_round2`, and 6 CGB tests that woke and
    then read TIMA one count low (`timers/interactive/stop_read_tima_*`,
    `double_speed/interactive/double_speed_stop_read_tima_*`). The two-byte
    STOP-mode STOP runs its operand M-cycle, the whole machine ticking,
    before the clock stops, and resets DIV at its end, where the switch leaf
    resets it too (`STOP_MODE_OPERAND_MCYCLE`, memory.nim; the 262 kHz tap
    is low at the fetch and high an M-cycle later, so only the later reset
    ticks TIMA, and the OAM DMA gets its byte). SameBoy passes all eight
    TIMA tests.
  * Closed: the P1 hand-off. Before it, those CGB tests and the three
    `hdma/interactive/*stop*` tests never woke: dingbat handed a CGB cart
    P1 = $FF (no group selected), so a key press pulled no P10-P13 line low
    and STOP (Pan Docs, "Using the STOP Instruction") never ended. The
    select lines power up low, and the CGB boot ROM writes P1 only in its
    DMG-cart palette key poll, so a CGB cart gets $CF (Pan Docs, "Power Up
    Sequence"; the boot ROM run over a CGB-flagged cart writes P1 nowhere;
    DocBoy's `cgb/boot/boot_regs_joypad` and `cgb_dmg_mode/boot/
    boot_regs_joypad` split $CF/$FF the same way) and a DMG cart keeps $FF
    (mooneye `misc/boot_hwio-C`). `skip_boot` in `memory.nim`. The three HDMA
    tests pass; SameBoy CGB E with the CGB boot ROM file passes all nine, and
    with its own boot ROM (which writes $FF) hangs on the same nine.
  * Closed: `mbc3_rtc_gb_stopped_recover` (1), the RTC across a STOP. The
    cartridge clock runs on its own crystal (Pan Docs, "MBC3": "an external
    32.768 kHz Quartz Oscillator, and an external battery"), so STOP mode
    moves its second on (`STOP_RTC_RUNS`, memory.nim).
* **Small (13 left of 40; 4 not scored):**
  * Left (6; contradicted by hardware, 2026-11-17): HuC3 commands,
    `dmg/mbc/huc3` `huc3_command_{3x,4x,5x,10,62}` and `huc3_scratchpad`.
    `$FFF0` is never written: every MCU wait in the six is `ld a,[$a000]` /
    `cp $01` in mode $D, so they need the semaphore to read exactly $01.
    dingbat reads $80 | mailbox bits 6-2 | ready, and the loop never ends.
    With that read forced to $01 (experiment only) all six pass and nothing
    else in them differs, so the command, address and scratchpad behaviour
    they check is already dingbat's. Forcing $03 or $81 still fails all six.
    Two hardware reports in Pan Docs' cited thread
    (gbdev.gg8.se/forums/viewtopic.php?id=744) contradict $01. endrift
    (2022): "The mode $D register bits 2-6 (I think) are directly leaked from
    the mode $B register. Bit 7 is again always high." CasualPokePlayer, on
    his Pocket Family GB2 cart (2024-12-17): "reading $D will just give you
    whatever is in $B's bits 2-6 ... bit 1 appears to always be high
    regardless". Pan Docs: D7 is not connected, so "the most significant bit
    of reads always returns an open bus value (usually high)", and the
    operand byte $A0 is last on the bus here. Not implemented; these rows
    cannot pass on a model that matches either report. Candidates for the
    not-scored ledger. (Unmodelled from the same posts, no scored row
    behind them: $D bit 1 high, mode $E reading $C's bits 6-2, and commands
    $0/$2 as $1/$3 without the address step.)
  * Left (6): the DMG STOP/HALT pictures `dmg/ppu/visual/halt_ppu_off`,
    `stop_during_{hblank,oam_scan,pixel_transfer,vblank}` and `stop_ppu_off`,
    whose reference is DocBoy's blank-panel colour (`$AD00`, Pan Docs'
    "whiter than color #0"), which dingbat draws as shade 0 or black. Those
    six are also never compared: DocBoy's runner checks a picture at the
    next mode-1 M-cycle, and dingbat's PPU, frozen through an un-woken STOP
    or off, never reaches one. Passing them needs a fifth DMG panel colour
    in the framebuffer (every frontend's palette) and a runner rule for a
    stopped or blank panel: a scoring and UI decision, not chased. (The CGB
    `ppu/visual/stop_*` pictures are in I12.)
  * Not scored (3; ledger "DocBoy: an MBC3 RTC latch on a bit-0 rising edge
    only"): `mbc3_rtc_latch_{0_to_2,1_to_0,1_to_1}`. DocBoy latches on a
    rising edge of bit 0 (0->1, 0->3 and 4->3 latch; 0->2, 1->0 and 1->1 do
    not). CasualPokePlayer's `latch-rtc-test`, scored in the Shootout suite,
    has low->low, high->low and high->high writes all latching in its
    reference; dingbat latches on any write (mbc3.nim), and a bit-0 rule
    passes DocBoy's three and fails that row. Its author states the capture
    was run on his own flashcart with a real MBC3+RTC chip; DocBoy's
    maintainer runs an Everdrive X7.
  * Not scored (1; `DocboyNotScored`, ledger "DocBoy: fresh cart RAM reading
    $FF"): `mbc1_initial_ram`, cart RAM read back as $FF before any write.
    Pan Docs ("Power Up Sequence"): "external RAM in the cartridge, when
    present, usually contains random garbage data when first powered on."
    dingbat starts a fresh cart at $00. No suite in the tree
    reads cart RAM it has not written -- mooneye `emulator-only/mbc1/ram_*`
    reads it disabled ($FF, open bus) and clears it before round 2 -- and
    $FF is an emulator convention (a fresh battery cart holds whatever its
    SRAM cells settled to; flash-erased $FF is real only for flash and
    EEPROM saves). dingbat keeps $00, and $FF stays Matt's choice of
    convention, which would move every new save's first boot.
  * Left (1; scored again 2026-11-16): the two-player `slave_sc_00` test
    wants a slave with SC = $00 to shift and interrupt (its source: "Serial
    transfer should start even with SC = 0"); Pan Docs has the externally
    clocked side "has to set SC's Bit 7 (that is, SC=$80) to enable the
    serial port", which dingbat follows, and Gekkio's SCLK experiment (an
    external-clock shift register counting 8 edges with the main clock
    stopped) does not say what SC bit 7 = 0 does. Letting the externally
    clocked side shift with SC bit 7 clear passes it and changes no other
    scored row; not adopted. Re-tried 2026-11-17 (link.nim: shift any
    SC.0 = 0 peer; the idle-skip guard in cpu.nim widened to match): the
    row passes, all GB suites otherwise unchanged, gblinktest and the GB
    rollback tests pass, and Crystal/Silver still reach the Trade Center
    — but a Crystal NOT at the Cable Club then answers Silver's clock
    ($FE) and sets its connection status. Against it, the one hardware
    report: gbdev/pandocs#558 (quinnyo, DMG/MGB/CGB on a cable, 2024-07)
    has the master read 0 from a connected peer with SC.7 = 0, its own
    caveat "limited", the peer's clock select not stated; a shifting peer
    would have sent its SB. That thread's DMG-CPU schematic reading
    (nitro2k01) has an SC.7 = 0 peer hold its last output bit (0 after
    reset), and dingbat's $FF for that case is a separate open item.
    Hardware question 24 still settles it. The SC = $80 pair passes.
  * Closed: the other two serial tests (serial.nim). An SC write that
    closes an open bit slot shifts that bit for the old transfer and the
    restarted byte still takes eight, `serial_abort_to_81_sc_round1`; a DIV
    reset in the M-cycle whose bus half already carried the tap's own fall
    makes no second falling edge,
    `serial_timing_reset_div_during_transfer_stall_alt_round1`, where
    SameBoy through Nintendo's DMG boot ROM agrees; gambatte `serial/*` is
    82/82 either way.
  * Closed: `cpu/halt_ime1_interrupt1_ret`. The HALT opcode tests IF & IE
    with the running CPU's view, `HALT_PENDING_RUN_VIEW`: a TIMA overflow on
    the HALT's own fetch is pending at it, as SameBoy also has it.
  * Closed: `write_tima_while_reloading_*` (2). The TIMA store lands in the
    M-cycle after the overflow, Pan Docs' cycle A, where a write stops the
    IF flag being set; dingbat's model already took the reload back, but the
    dispatch lead that sees the overflow one M-cycle ahead of IF,
    `TIMER_IRQ_RUN_LEAD`, still fired; the write now clears it, timer.nim.
    SameBoy fails both; mooneye `tima_write_reloading`/`tma_write_reloading`
    and gambatte `tima/*` did not move.
  * Closed: DMG `dma_*_check_stat_*` (8). The family's source: "When DMA is
    running, STAT mode is 0 either in HBlank or in OAM scan. This change
    shouldn't affect interrupts." A STAT read on the OAM scan with an OAM
    DMA running reads mode 0, and mode 2 again on the M-cycle the transfer
    ends (`..._finish_at_oam_scan_check_stat_round{1,2}`)
    (`STAT_M2_DMA_READS_0`, ppu.nim). SameBoy passes all 25 of the family on
    DMG B and on CGB E (the DMG carts in compatibility mode), so the rule is
    not device-gated; Pan Docs is silent.
  * Closed: `ly_144_stat_clears_irq`. Mode-0 and LYC sources enabled,
    LYC = 144, IF cleared in line 143's HBlank: line 144 must not request
    STAT (IF = $E1), where the same set-up one line earlier
    (`ly_143_stat_clears_irq`, LYC = 143) must ($E2). Entering vblank moves
    the mode after the comparator's blind window, so LYC takes the line over
    from mode 0 with no gap (`VBLANK_ENTRY_MODE_AFTER`, ppu.nim). SameBoy
    passes both; gambatte is unmoved on both devices.
  * Closed with I5's OAM-bug rules: `oam_write_block_timing` (`ld [hli], a`
    writes four dots apart across line 1; the reference has the first 24
    landing, dots 13..105, the same table as `oam_write_block_ly0_timing` on
    line 0; SameBoy passes it, yet SameBoy and DocBoy both block a plain
    `ld [hl], a` at that point, `memory/oam_write_oam_scan`, and SameBoy
    agrees with gambatte's DMG `oam_access/{pre,mid,post}write_*` tests) and
    `oam_scan_blocked_by_idu_write_round2` (the IDU's address on the OAM bus
    during the scan, an `inc hl` at `$FE40`, changes which object the scan
    reads; SameBoy fails round 2 too).

## Hardware experiments that would close buckets

The ROMs exist in `tools/gbprobe/` (raw values, no baked expectation,
on-screen hex); dingbat's prediction and the hardware status per probe are
in `docs/dev/gb-probe-oracle-results-2026-08-11.md`, and the catalogue of every
hardware question with its priority is `docs/dev/hwprobe-questions.md`. No
gambatte, wilbertpol, GBMicrotest, mealybug or AGE test fails today; these
settle which model is the hardware's. The DocBoy deciders are listed with
their items in section I.

* **(a)** Does the STAT mode field report differently to `LD A,(C)` and
  `LDH A,($41)` at the mode 3 -> 0 edge? Settles whether `STAT_M0_FIELD_TAIL`
  (default 0; gambatte and wilbertpol want a 3-dot field tail that
  GBMicrotest's `LDH` readers fail with, and idiom and suite are perfectly
  confounded) is silicon or an artefact. `probe_a_statidiom.gb`.
* **(b)** How much does a mid-line SCX store lengthen mode 3, as a function
  of where it lands? C3. `probe_b_scxm3.gb`.
* **(c)** `cgb-acid-hell`'s LCDC.4 toggle and daid's BGP band edge on ONE
  frame: does emission separate from the fetch grid by four dots?
  `probe_c_arbitrate*.gb`; the g1 session (`docs/dev/flashcart-runbook.md`,
  "g1, GBA SP") read the frame on a GBA SP.
* **(d)** The DMG BGP transition pixel on as many DMGs as can be borrowed,
  with mainboard/CPU markings per unit — C7. The sample size is the
  experiment; no single unit can answer it. Per unit, run gambatte
  `dmgpalette_during_m3_4` and mealybug `m3_bgp_change` on the same unit.
  Photograph x = 1 on every line at 10 or more px per pixel, over several
  short exposures, to catch frame-to-frame flicker. The mealybug photo
  already shows one unit disagreeing with itself between line bands. The
  decisive instrument is a logic-analyser capture of LD0/LD1 against CP on
  the LCD ribbon around the write: it shows the race directly.

---

## Refuted models (do not re-derive)

Each was built and scored. The tests that fail with it are named, so the
idea is not tried again as a knob.

* A uniform STAT-field lag at the mode 3 -> 0 edge (`STAT_MODE0_LAG`): every
  `_2` member of `sprites/*_m3stat` fails with it. At the 2 -> 3 edge
  (`STAT_MODE3_LAG`): `m2int_m2stat/*_ds_2` fail. A CGB-only 2 -> 3 lead
  (`STAT_MODE3_LAG_CGB = -1`) passes `halt/lycirq_m2stat_2 [cgb]`, and five
  object-free CGB field readers on the same edge fail with it.
* Paying the mode-0 field's 3 dots at the EDGE (`M3_END_EARLY`): `m0enable`
  (interrupt, object-free) and GBMicrotest `poweron_stat_*`, `win*_a` fail.
  Paying them at the field (`STAT_M0_FIELD_TAIL = 3`): 24 GBMicrotest
  `win*_b` / `ppu_sprite0_scx*_b` tests fail. Gating on the read idiom
  (`STAT_M0_TAIL_MAX_MC = 2`) reconciles all three suites and is unproven —
  experiment (a).
* The CGB's mode-0 boundary one M-cycle earlier than the DMG's: 40 gambatte
  families that probe the edge through four instruments are device-equal
  (`vramw_m3end_{1..6}` the sharpest); every family that does flip earlier
  on CGB is a register write racing an edge or a halt.
* A line-0 geometry trim (`LCD_ON_LINE0_TRIM = 2`, `LCD_ON_LINE1_TRIM = -2`):
  mooneye `intr_1_2_timing-GS`, gambatte `m2enable/late_enable_ly0_*`,
  `ly0/lycint152_m2stat_1` fail, and so do AGE `stat-mode-window`,
  `stat-mode`, `stat-int` and `ly` at cell resolution.
* Line 0's mode-2 STAT interrupt one M-cycle late, or line 0's mode 2 four
  dots short: the same mooneye test and `m0enable`, `vramw_m3end`,
  `lcd_offset` fail.
* A readable-LY / comparator split at line 153 (`LY153_SNAP_DOT`,
  `LYC_SETTLE_DOTS` moved apart): every gain reads LY and every loss is a
  LYC = 153 match ending early (`ly_lyc_153-GS`, `line_153_lyc153_stat_
  timing_b`). The CGB snapback relatch at dot 13 for daid:
  `ly0/lycint152_lyc0{flag,irq}_{1,2} [cgb]` fail; around dot 9, values on
  both sides fail.
* A second M-cycle of OAM-source lead (`STAT_M2_LEAD = 2`): GBMicrotest
  `int_oam_nops`/`int_oam_incs` read one M-cycle under. An LYC-source-only
  lead (`STAT_LYC_LEAD = 1`): six GBMicrotest LYC sleds go one M-cycle early.
* A CGB halt-exit charge (`CGB_HALT_EXIT_MCYCLES = 1`): 42 `tima/*` tests
  with one expected value for both devices fail with any time spent.
  Sub-M-cycle halt leads (`CGB_HALT_PPU_LEAD_DOTS` 1..3): the wake is latched
  on the M-cycle grid, so they are whole M-cycles for a source near a
  boundary and nothing otherwise.
* A CGB-specific OAM DMA start latency (`CGB_OAM_DMA_START_T = 4`): 103
  `oamdma` tests fix it at 8 T. The `late_sp*` tests as a start latency:
  unmoved from 4 T to 40 T.
* A per-block HDMA delay of one M-cycle (rather than 4 dots of data hold):
  `hdma_late_disable_{2,scx2_2,scx3_2}` and the `hdma_late_m3speedchange_*`
  ladder read the block's bus occupancy where it is.
* The SCX extension as a pipeline stall (`SCX_STORE_STALL_DOTS`): 65 PNG
  tests fail — a stall displaces pixels from the store's dot, the borrow
  from the next fetch boundary. Counting discard slots without `and 7`:
  mode 3 runs off the end of the line.
* `$D000-$DFFF` aliasing `$C000` as a banking rule: contradicted by the two
  SVBK ROMs; the 64 tests were the DMA driving A12 (`OAMDMA_WRAM_A12`).
* Mode 3's LENGTH as the cause of the `NspritesPrLine` family: the per-object
  cost is exactly Pan Docs' `6 + max(0, 5 - ((X + SCX) mod 8))`
  (`tools/gbppu/objtab.py` 153/153 against GBMicrotest `ppu_spritex_vs_scx`),
  and every double-speed member passes; the family measures the STAT
  readback.
* A frame-level mystery in `window/arg/late_wy_*`: 13 of 14 families have
  different expected values per device, shifted one M-cycle, and the CGB is
  EARLIER — a positive CGB delay moves it the wrong way.
* `m0enable` as a STAT-phase bucket: no test moves under any STAT
  experiment; it is the write-commit boundary and a DMG/CGB split of zero.
* `mgb_oam_dma_halt_sprites` as a unit-specific corruption pattern: the
  phantom sprite is a BUS value (`OAMDMA_FREEZE_BUS`), the `& $FC` is
  measured by the reference frame, and `OAMDMA_FREEZE_DEST_LEAD` is a
  one-word plateau.
* `rtc3test-1`/`-3` as an RTC defect: the local harness sampled at frame 570
  where the shootout's budget is 925.

---

## Closed buckets

One line each; the knob's own comment carries the derivation.

* Closed 2026-11-13 (docs/dev/gb-derivations.md has an entry for each, with
  its tests): HBlank DMA across HALT/STOP and against
  a same-dot dispatch, GDMA's hand-over point, the LCD-off HBlank block
  (section 5); OAM DMA across HALT and an FF46 restart's bus, the OAM
  scan's view inside a transfer (section 6); the HALT-with-IME-pending
  re-run, the dispatch's push order, vector choice and IF clear, the CGB's
  later clear of its timer and serial lines, the comparator's lead and the
  sources that ride it, the IF write's landing dot, the TAC and SC write
  sample points (section 7); the mode-0 request at the pixel end, the
  LCD-off STAT write, the DMG parked-LYC window, the vblank-line blind
  window, the OAM pulse's falling-edge evaluation, the VRAM and palette
  locks' edges (sections 1 and 7); the window's sampled WY comparator, its
  line-end cut-off and per-line sample, the DMG carried window start under
  LCDC.5 low, the CGB object at X = 167 against the window (section 2); the
  wrapped-discard borrow, the LCD-on line's object scan, the CGB fetcher
  with LCDC.1 clear (sections 3 and 4); the APU trigger/envelope rule, the
  sweep and power-on leads, CGB C's double-speed trigger and PCM12's
  channel 2 arm (H, H1; section 11); SVBK's readback and the printer's
  status sequence (section 8). Also closed:
  `oamdma_src0000_busyint0002`, `tima/tc00_late_tc01_{5,7}`, the gambatte
  `lcd_offset` and `lcdoffset` tests, `window/late_disable_scx5_ds_1`.
  `scx_during_m3/scx_0761c0` (C3) passes as well.

* Line 0's pipeline one M-cycle ahead (the PNG tests): `STAT_M2_LEAD = 1` +
  `M3_PIPE_AHEAD = 1` (the OAM source rises one CPU M-cycle before its line,
  and the pipeline with it); `LY0_PIPE_MCYCLES` is what it subsumed.
* `$FEA0-$FEFF` is RAM on CGB 0-D (`addr and not $18` on 0-C), nibble echo
  on E: `GbUnusableRegion`; `cgb-acid-hell`'s own readback gate fixes the
  mask.
* HDMA source outside cartridge/WRAM moves `$FF`: `dma_hiram_read_result`.
* The dispatch's IF clear inside its fifth M-cycle, T = 18: `IRQ_SAMPLE_T` (A2).
* The LY=LYC comparator blind while LY changes, at every line edge and the
  vblank entry: `ly_advance_close`, `LY_BLIND_SCOPE = 2`.
* A `$FF0F` read's sample point inside its M-cycle: `IF_READ_SAMPLE_T`
  (written in `irq_read`, interrupts.nim).
* The VRAM read lock's live-mode clause is DMG-only: `VRAM_READ_LIVE_LOCK = 2`.
* STAT readback samples the mode at `cc - 2` (`cc - 3` in double speed):
  `STAT_READ_SAMPLE`, `STAT_READ_SAMPLE_DS_ADD`; the `NspritesPrLine` family
  with it.
* The mode-0 STAT source's 2 dots in the retire -> flag hand-off:
  `STAT_M0_LEAD_T = 2`; AGE `halt-m0-interrupt` and `stat-int` (single speed)
  with it.
* The OAM scan against an OAM DMA: `OAM_SCAN_DMA_LOCK`; inside the transfer
  the comparator compares its held latches (`OAM_SCAN_DMA_HOLD`).
* The speed switch's two clocks and the PPU's 8/3 re-alignment:
  `SPEED_SWITCH_STALL_CPU`, `SPEED_SWITCH_PPU_EXTRA_DOTS{,_SINGLE}`; the DIV
  reset one M-cycle after the STOP fetch and its slow-tap split:
  `SPEED_SWITCH_DIV_RESET_T{,_SLOW}`.
* A halted CGB's PPU one M-cycle behind, given back at the wake, absent on
  the LY 153 -> 0 snapback: `CGB_HALT_PPU_LEAD = 1`, `CGB_HALT_LEAD_SKIP_LYC0`;
  `cgb-acid-hell` and daid `ppu_scanline_bgp` with it.
* The CGB OAM DMA drives the address bus (A12 into WRAM): `OAMDMA_WRAM_A12`,
  the `busypush`/`busypop` tests.
* HBlank DMA bytes land 4 dots late: `HDMA_VISIBLE_DOTS`; the hand-off at the
  fetch grant: `HDMA_GRANT_FETCH_DOTS` (mealybug `dma/*`); a halted CPU's
  blind mode-0 edge: `HDMA_HALT_M0_BLIND`.
* The LY 153 -> 0 snapback's LYC = 0 edge, blind window and read snap:
  `LYC_SETTLE_DOTS`, `LYC_SRC_RELATCH_LEAD`, `LY153_READ_SNAP`; the last
  GBMicrotest tests and daid `ppu_scanline_bgp` (DMG) with it.
* The readable LY edge splits at CGB C/D; `$FF44` on the advance dot reads
  `LY & (LY + 1)`; the mode-0 M-cycle at the end of mode 1 is CGB <= C too:
  `ly_read_edge_late`, `LY_EDGE_AND`, `m1_end_no_mode0`; AGE `ly`,
  `lcd-align-ly`, `stat-mode`.
* The line-144 OAM STAT source is a pulse; CGB D+ hold the LY=LYC
  comparison; the CGB takes an LYC write one M-cycle later: `M2_144_PULSE`,
  `lyc_compare_hold`, `CGB_LYC_WRITE_DEFER`; the wilbertpol `ly_lyc*` cluster.
* A halted OAM DMA drives the OAM bus: `OAMDMA_FREEZE_BUS`; the last mooneye
  test.
* SameSuite APU: `pcm_read_edge_zero` (CGB <= C), `square_reload_halftick`
  (CGB D/E), the suite scored on CGB E as its README says
  (`docs/dev/samesuite-apu.md`).
* The mealybug DMG set: `OBJ_BG_RUN = 4` (the object fetch takes a tile
  boundary the object picks), `M3_THROWAWAY_DOTS = 4`, `MIXER_PALETTE_OR`,
  `MIXER_TAIL_HBLANK`, `MIXER_TAIL_DOTS`, `MIXER_HEAD_LINGER`, `BG_EN_AT_MIX`,
  `WIN_LINE_START_WX = 6`, `WIN_START_PRE_PIXEL`, `WIN_HEAD_ABSORB`,
  `WIN_LINE_START_LATCH`, `WIN_WX0_PHASE`, `WIN_PRE_PX_PHASE`, `WIN_EN_ABORT`,
  `WIN_REACT_PHASE`, `obj_yields_to_window`, `OBJ_PLANE1_LAG` (LCDC.2 read
  once per bitplane), `fifo_obj_abort`. The CGB set: `CGB_TDSEL_LATENCY`,
  `CGB_TDSEL_GLITCH` (reset = tile index, set = the bus address latch),
  `CGB_TDSEL_IDX_DOTS`, `CGB_MAP_LATENCY = 2`, `CGB_OBJ_SIZE_LATENCY`,
  `CGB_MIXER_LATENCY` / `mixer_write_immediate` (the C/D palette dot).
  Per-test account: `docs/dev/gb-mealybug-sources.md`.
* Most of `scx_during_m3`: `SCX_FINE_BORROW{,_DMG_LEAD}`,
  `SCX_FINE_LATCH_WRAP` (C3 is the rest).
* The DMG's last-pixel window start owed to the next line:
  `DMG_WIN_LAST_PX_CARRY`, `WIN_CARRY_TILE`, `WIN_CARRY_REACT_LINES`
  (C6 is the rest of `window/on_screen`).
* The OAM scan reads LCDC.2 once per object, two dots apart, and the CGB
  takes a second look one M-cycle earlier: `OBJ_SCAN_DOT_ADJ`,
  `CGB_OBJ_SCAN_LEAD`; every `sprites/late_sizechange*`.
* `EI; HALT` with `IF & IE` arms the halt bug: `ime_set_cycle`. The TAC
  write's tap sample is `TAC_SELECT_LEAD_T` (0).
* A TIMA overflow reaches a running CPU one M-cycle before a halted one:
  `TIMER_IRQ_RUN_LEAD`.
* The serial shift clock is a half-rate toggle the SC write reseeds, and a
  CPU access meets it before its own tap edge: `SERIAL_TAP_*`,
  `SERIAL_CPU_SAMPLE_T`. The SC store's own sample point is
  `SERIAL_SC_WRITE_LEAD_T` (4).
* The CGB window start is revocable; the DMG revokes for one dot:
  `CGB_WIN_REVOKE_LAG`, `DMG_WIN_EN_REVOKE`.
* The OAM X = 167 object charged for the tail walk twice:
  `OBJ_TAIL_WALK_REFUND`.
* GBMicrotest's verdict-less ROMs and broken expectations, mooneye `utils/`,
  `bootrom_dumper`: skipped by name, in `NotScored`.
* AGE's DMG cases were running on a CGB (the cart header picked the machine):
  `dmg: not arm_cgb` in `build_age_tests`; blargg `oam_bug` needs `--dmg` for
  the same reason.
* `rtc3test-1`/`-3`: the local harness uses the shootout's own frame budget.
* `mooneye/misc/boot_hwio-C@agb`: the AGB boot table.
* The CGB revision axis at runtime (`--cgb-rev`, `GbQuirks`): design in
  `docs/dev/gb-hardware-revisions.md`.
