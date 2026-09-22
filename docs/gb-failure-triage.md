# GB test-suite failures: the open buckets

Every Game Boy row the runner scores red, grouped by the hardware mechanism
the row measures. For each bucket: the rows, the behaviour under test and the
evidence for it, what dingbat models today (the knob and its shipping value),
and what would close it. Scores live in `tests/results.md` (per suite) and
`tests/results_gambatte.md` (per row); this file explains them and is updated
when they move. Closed buckets are one line each at the end.

Conventions: a knob is a `{.intdefine.}` in `src/dingbat/gb/` and its own
comment carries the derivation; `[dmg]`/`[cgb]` is the device a gambatte row
is scored on; `_ds_` is double speed; `@cgbc` etc. is the revision arm of a
row whose ROM names several machines.

## Where the numbers and the instruments live

* Per-suite tallies: [`tests/results.md`](../tests/results.md); per-row
  gambatte verdicts: [`tests/results_gambatte.md`](../tests/results_gambatte.md).
  This file names buckets, not counts. The local runner scores CGB rows on
  CPU CGB C and the gbdev shootout adapter on CGB E; both are at the model's
  maximum for their revision ("The device each suite is scored on",
  [`tests/README.md`](../tests/README.md)).
* Rows deliberately not scored: the runner's `NotScored` ledger, printed as
  "Deliberately not scored" at the end of `tests/results.md`. Bucket G below
  is the one skip with a mechanism story.
* Reading a row as a dot count — gambatte family ladders, AGE cell tables,
  wilbertpol sample dumps, PNG diffs, the `-d:gb_*` trace builds, sweeps and
  the retired-instruction A/B:
  [`tools/gbppu/README.md`](../tools/gbppu/README.md). The gambatte
  filename convention is in `tests/README.md` ("The gambatte suite");
  runner hazards (shared `TMPDIR`, ROM cache, rewritten baselines) in its
  "Exit code, baselines, hazards".

---

## A. STAT and interrupt timing

### A1. The mode-0 dispatch grid at double speed

**Closed 2026-09-21.** AGE `stat-interrupt/stat-int-dmgC-cgbBCE@{cgbab,
cgbc,cgbe}`, gambatte `m0int_m0stat/m0int_m0stat_scx5_ds_2` and
`m0enable/disable_scx5_ds_2` (the whole `m0int_m0stat` directory is green).
The `-d:gb_dispatch_trace` dots said it outright: the double-speed dispatch
grid sits on odd dots, the mode-0 source rises at flag - 1 (STAT_M0_LEAD_DS,
which the IF-write rows pin), so for an odd SCX it rose one dot before a
boundary and was taken there, while for an even SCX it rose two dots before
one. AGE's staircase pairs SCX (1,2), (3,4), (5,6): a mode-0 rise one dot old
at the boundary waits for the next. `STAT_DISPATCH_MIN_AGE_DS = 2` (gb.nim),
gated to the mode-0 source's own edge: applied to every STAT rise it breaks
the same ROM's mode 2 and mode 1 cells (those sources rise on the boundary
dot and are taken), and to CPU-written enables gambatte `m2int_m0irq/*_ds_1`.
The remaining `_ds_` rows (`m2int_m0irq_scx5_ds_1`, `enable_display/*_ds_1`)
did not move either way.

### A2. The dispatch's IF clear against a source rising inside it

**Rows (2).** `tima/tc00_irq_late_retrigger_{2 [cgb],ds_2}`. Closed
2026-09-22: `ly0/lycint152_lyc153irq_late_retrigger_2` and
`lyc153int_m2irq_late_retrigger_2` (both devices; `LY_BLIND_SKIP_LED`,
`STAT_M2_LY0_LEAD`),
`ly0/lycint152_lyc0irq_late_retrigger_2`, `irq_precedence/
late_m0irq_retrigger_2`, then `m1/lycint143_m1irq_late_retrigger_2` and
`m1/lycint_vblankirq_late_retrigger_2` (both devices; the mode-1 source and
the vblank request rise with the comparator's 2-dot lead, `STAT_M1_LEAD`,
`VBLANK_IRQ_LEAD`), `tc00_irq_late_retrigger_3` [cgb] and
`serial/start_wait_trigger_int8_read_if_2` [cgb] (a CGB dispatch clears a
timer or serial request 2 T later, `IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD`).

**Behaviour.** Each ROM's handler re-requests its own interrupt with an
`LDH ($0F),A` that moves one M-cycle per member, `EI`s, and reads IF inside
the second dispatch. The whole chain from the first dispatch to the second
is fixed by the handler bytes (m2int_m2irq: 436 T at `_1`, 4 more per
member) and the source's next rise is one line (456 T) or one timer period
(2048 T) after its first, so each member asks whether the second dispatch's
IF clear lands before or after that next rise. Writing the clear as `T`
cycles into the dispatch and the first rise's distance to the dispatch's
M-cycle boundary as `d` (0..3), the `_1`/`_2` flip of every family brackets
`d + T` to a 4-cycle window: mode-2-first families (m2int_m2irq,
late_m0irq_retrigger) say 16 < d + T < 20; LYC-, mode-1- and timer-first
families say 20 < d + T < 24. Pan Docs, "Interrupt Handling": the dispatch is
five M-cycles, the fifth setting PC.

**Modelled.** `IRQ_SAMPLE_T = 18`, `IRQ_SAMPLE_T_DS = 16` (cpu.nim; the
bracket is at the constant: 16 loses the two mid-M-cycle sources, 19 loses
`late_m0irq_retrigger_scx1_1`, 20 also `m2int_m2irq_late_retrigger_1`,
`20 / 16` is +15 / -5 over the suite).

**To close.** One clear cannot sit in both windows, so the two groups of
sources reach the dispatch one M-cycle apart, relative to the instant their
IF bit rises, with the mode-2 source the early one. dingbat raises the
mode-2 source one M-cycle before the line boundary (`STAT_M2_LEAD`), the
LYC and mode-1 sources on it, and dispatches the timer one M-cycle ahead of
its IF bit (`TIMER_IRQ_RUN_LEAD`): the retrigger rows say the timer, LYC and
mode-1 sources need one M-cycle more between rise and dispatch than that,
or the mode-2 source one less, without moving where any of them is read
back (the absolute `m2int_*`, `lycint_*`, `tima/*` rows are green). Second-
emulator cross-check (gambatte-core `video.cpp`, `lyc_irq.cpp`, `tima.cpp`,
`interrupter.cpp`, read for facts): it flags the mode-2 source 4 cycles
before the LY increment, LYC and mode 1 2 cycles before it, LYC = 0 6
cycles into line 153, the timer 3 cycles after its tap edge, dispatches at
the first instruction boundary at or after the flag, and clears IF 16
cycles into the dispatch — the same shape, the sources' phases differing,
not the clear. The instrument is `-d:gb_stat_src_trace` against these
seven families (A3's per-source table); `tools/gbppu/gam_dispatch.py`
already reads the mode-0 side.

### A3. A STAT source enabled, disabled or handed over across a line edge

**Rows (71).** `lycEnable` 31, `m2enable` 7, `m1` 13, `m0enable` 5,
`miscmstatirq` 7, `m2int_m0irq/m2int_m0irq_scx3_ifw_{2,4}` (4),
`ly0/lycint152_lyc{0,153}flag_ds_3`, `lycint_lycflag/lycint_lycflag_ds_3`.
Heavily CGB, and a third of them `lcdoffset1` or `_ds_` members.

**Closed 2026-09-22: the coincidence bit's readback at a double-speed line
edge (+4).** `lycint_lycflag_ds_3`, `ly0/lycint152_lyc0flag_ds_3` and
`enable_display/frame{0,1}_m2stat_count_ds_1` read STAT in the M-cycle LY
steps in. At double speed the bit still compares against the line being
left while the dot counter is below 2, and clears from dot 2
(`LYC_JUST_CHANGED_HOLD_DS`, ppu.nim; the `lcd_offset1` twin pins the upper
side). `lycint152_lyc153flag_ds_3` stays red.

**Closed 2026-09-22: a disable is an edge's other half (+20).** The STAT
line is a level OR into an edge detector, and dingbat only re-evaluated it
at source changes and at the M-cycle boundary a STAT write's byte waits
for. A write whose cleared enable bits took the line low inside its own
M-cycle, followed by another source rising before the boundary, was a
handover with no edge: the detector still held the old level.
`-d:gb_stat_read_trace` on `m2enable/m2_late_m0disable_1` shows the $28 ->
$20 write committing on dot 449 and the mode-2 rise at 452 with no
interrupt. Now a STAT write samples the line under its new enables at the
commit, plus the CGB's 2-dot latency, and lets it fall there
(`stat_drop_arm`, ppu.nim); a rise inside the latency window refreshes the
sample. Took `m2enable/{m2_late_m0disable, late_enable_m0disable,
late_enable_after_lycint_disable, lyc1_m2irq_late_lycdisable}_1` and their
`_ds_1` twins, `m0enable/lycdisable_ff41_*` (7), `lycEnable/lyc{0,153}_
late_{enable_,}m1disable_2 [dmg]`, `lyc153_m1disable_ds_1`; lost
`lycEnable/lyc153_late_{enable_,}m1disable_2 [cgb]`, whose LYC = 153 rise
meets a mode-1 disable landing on the latency's last dot and still blocks
(a strict `>` loses six other CGB rows instead: that source's latency is
one dot longer than the mode-0/2 sources', not the rule's edge). Second-
emulator cross-check (gambatte-core `mstat_irq.h`, `lyc_irq.cpp`, read for
facts): each source event reads a copy of STAT that a write updates only
when it lands more than 2 cycles (CGB) before the event, i.e. the same
window, spelled per source.

**Closed 2026-09-22: the same for LYC writes (+7).** An LYC write that
breaks the match is the same disable through the comparator
(`LYC_DROP_LATENCY_DMG = 1`, `_CGB = 6` = the CGB's deferred byte plus its
2-dot latency, `LYC_DROP_BOUNDARY_SKIP`, ppu.nim, brackets at the
constants). Took `m0enable/lycdisable_ff45_{3, scx1_2, scx2_2} [dmg]`,
`lycdisable_ff45_scx{1,2}_1 [cgb]`, `m2enable/lyc1_m2irq_late_lyc255_{1
[cgb], 2 [dmg]}`; nothing lost. `lycdisable_ff45_scx1_ds_1` [cgb] is the
family's residue (double speed halves the 6 to 3 dots; the row wants the
single-speed count).

**Behaviour.** The STAT interrupt line is a level OR of four sources into
one edge detector, so an interrupt fires only when the OR rises from zero
(Pan Docs, "LCD Status Register", STAT blocking; mooneye
`acceptance/gpu/stat_irq_blocking` is green). These families write STAT or
LYC one M-cycle per member across a line boundary and ask whether the
enable, the disable or the hand-over from one source to another produced an
edge. Sub-shapes, each a separate rule:

* `m0enable/lycdisable_ff45_scx1_ds_1` (1; the rest closed above): the
  LYC-write drop at double speed, where the 6-dot CGB latency is spent as
  3.
* `m2enable/late_enable_*_2`, `lyc1_m2irq_late_lyc255_*`,
  `late_{enable_,}m1disable_ly0_2`, `lyc0_late_m2enable_lycdisable_2` (9):
  the OAM source enabled one M-cycle across the line boundary it rises on.
  `STAT_M2_LEAD = 1` puts the rise one CPU M-cycle before the boundary;
  these say the enable window around it is still a cycle out, mostly on CGB.
* `m1/ly143_late_m{0,2}enable_*`, `m1irq_late_enable_*`,
  `m1irq_m0disable_2`, `m1irq_enable_after_lyc144_2`, `lycint143_m1irq_
  late_retrigger_2`, `lycint_vblankirq_late_retrigger_2`, and the CGB arms
  `m1irq_m2enable_lyc_2`, `lyc143_late_m2enable_lycdisable_ds_1`,
  `m2m1irq_ifw_ds_1` (13): the mode-1 / mode-2 / LYC hand-over at the top of
  line 144. **Closed 2026-09-22 (+10):** the line-144 OAM pulse went low for
  the instant between the LY advance and the mode-1 set inside
  `ly_advance_vblank_entry`, so the comparator's drop there was a dip and
  the mode-1 rise a false edge whenever LYC = 143 had held the line
  (`m1irq_m2enable_lyc_1`, `m2m1irq_ifw_2`, `m1irq_m2disable_lycdisable_3`,
  `lyc143_late_m2enable_lycdisable_2` and `_ds_2` twins, both devices);
  `m2_line144` now holds through the boundary. The three CGB arms left are
  the same rows one M-cycle later: the CGB write's enable lands 2 dots after
  its commit, one dot BEFORE dingbat's boundary events, where gambatte-core's
  model (read for facts: `mstat_irq.h`, the mode-1 event 2 cycles before the
  LY increment, a write latched only if `cc + 2 < event`) has it tie with
  them and lose. The vblank-entry sources sit 2 dots earlier against the CPU
  grid than the mode-0 source, whose rows bracket `CGB_STAT_ENABLE_LATENCY`
  at 2; a per-source spelling is the next step.
* `lycEnable/lyc153_late_*`, `lyc0_m1disable_*`, `lcdoff_lycirqen_*` (15):
  the LYC = 153 and LYC = 0 sources around the LY 153 -> 0 snapback
  (`LYC_SRC_RELATCH_LEAD = 1`, `LYC_SETTLE_DOTS`), and LYC armed while the
  LCD is off.
* `lycEnable/ff45_enable_weirdpoint_*`, `late_ff45_enable_*`,
  `late_ff41_enable_*` (14, all CGB but two): a CGB takes an LYC write one
  M-cycle later than a DMG (`CGB_LYC_WRITE_DEFER`, wilbertpol
  `ly_lyc*_write-C` vs `-GS`); the `lcdoffset1` members ask whether that is
  4 dots or 2, which a boundary spelling cannot answer.
* `miscmstatirq/*wirq_trigger*` (7): a STAT write's enable bits reaching the
  line (`STAT_ENABLE_LATENCY = 0`, `CGB_STAT_ENABLE_LATENCY = 2`, bracketed by
  `m0enable/disable*_2 [cgb]` against `m0enable/disable_scx*_1`).

**Modelled.** The level-OR edge detector; `LY_BLIND_SCOPE = 2`; `STAT_M2_LEAD
= 1` (DMG and CGB alike — GBMicrotest `oam_int_if_edge_{a..d}` put the CGB
exact and the DMG a cycle late); `STAT_M2_PULSE = 3` and the line-144 OAM
pulse (`M2_144_PULSE`); `lyc_compare_hold` (CGB D+ hold the comparison the
blind window is leaving); the CGB enable latency above.

**To close.** Read each sub-shape at cell resolution with `famflip.py` and
`-d:gb_stat_src_trace` (which names the source on every rising edge; the
`STATW` line is each STAT write's commit dot) against one statement of when
each source's level rises and falls relative to the line boundary. No Pan
Docs sentence gives these dots; the evidence is the families themselves.
Closed 2026-09-22 (second round), three rules, each bracketed two-sided on
the full 5157-row list:

* *The comparator's LY steps 2 dots before the boundary, single speed*
  (`STAT_LYC_LY_LEAD_DOTS = 2`, `fifo_lyc_ly_lead`): irq_ly becomes the next
  line at dot 454 and the edge detector runs there. 1 takes 8 and loses 3, 2
  takes 15 and loses 6, 3 takes 15 and loses 9. The winners are every
  single-speed `*_lcdoffset1_1` row (the speed-switch round trip leaves the
  CPU grid 3 dots behind the PPU's, so a source rising on the boundary is
  sampled one M-cycle late: `cgbpal_m3/cgbpal_{read,write}_m3start_
  lcdoffset1_1`, `lcd_offset/offset{1,2}_lyc8fint_m1stat_1`, `lycEnable/
  late_ff45_enable_lcdoffset1_1`, `m0enable/late_enable_lcdoffset1_1`,
  `m1/ly143_late_m0enable_lcdoffset1_1`, `oam_access/pre{read,write}_
  lcdoffset1_1`, `vram_m3/pre{read,write}_lcdoffset2_1`) plus the LYC-held
  enables (`m2enable/late_enable_after_lycint{,_disable}_2`, `lyc1_late_
  m2enable_lycdisable_1`, `m1/m1irq_m2enable_lyc_2`). gambatte-core's LYC
  event sits at line cycle 454 (`lyc_irq.cpp`, `lycReg * 456 - 2`), the same
  dot. The six it loses (`m1/lyc143_late_m{0,2}enable_lycdisable_2`,
  `offset2_lyc8fint_m1irq_2`, `m2enable/late_enable_lcdoffset2_2`, `vram_m3/
  pre{read,write}_lcdoffset1_2`) are rows where the ending line's match must
  NOT dip before a same-M-cycle enable lands: gambatte's `lycperiod` (a match
  with more than 2 cycles to the step) blocks any STAT write from triggering.
  Double speed is left at 0 (`STAT_LYC_LY_LEAD_DS`): every `_ds_` sibling
  moves the other way, and the double-speed constants are a coupled set
  (see below).
* *The OAM pulse's falling edge is evaluated* (`STAT_M2_PULSE_END_EVAL`,
  dot `STAT_M2_PULSE + 1` on every line): +4, no losses. `lycEnable/
  late_ff41_enable_after_m2int{,_disable}` enable LYC inside the mode-2
  handler with LYC == LY; the line had fallen at dot 4 and nothing ran the
  detector, so the enable found `old_stat_flag` still high.
* *The CGB's last-M-cycle mode-2 enable* (`STAT_M2_ENABLE_WINDOW_CGB`):
  gambatte-core's `statChangeTriggersM2IrqCgb` as a rule of its own -- a
  CGB STAT write committing in the line's last M-cycle (lines 0..142) that
  newly sets the OAM enable with mode 0 off, while the LYC source is not
  holding the line, requests the interrupt at once; line 143 has no window
  at single speed and line 153 a one-dot window at double speed only. +1
  (`m2enable/late_enable_m0disable_2 [cgb]`); the level model cannot spell
  it because the mode-0 source is still up at the commit on both devices
  and the DMG must not fire.

Measured and refused the same day (all on top of the three): the STAT
drop sampled with `old and new` enables (`STAT_DROP_OLD_LEVEL`, -33: the
`miscmstatirq/*_08_40`, `*_40_08` swaps of two high sources want no dip);
the CGB mode-0 source ending at dot 452 where the OAM source begins
(`STAT_M0_FALL_AT_M2_CGB`, SameBoy's single `mode_for_interrupt`, -1 alone
and -7 with an evaluation on the dot the set bits land, `STAT_SET_LANDING_
EVAL`, because `m2enable/late_enable_*_3` -- the enable committed on dot 1,
landing on 3 with the pulse still high -- must not fire); the whole-suite
joint moves of the double-speed grid (`SPEED_SWITCH_PPU_EXTRA_DOTS` 7/9
with `STAT_READ_SAMPLE_DS_ADD` 0/2: -86 to -280) and of the to-single
switch residual (`SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE` -1, 0, 1, 2, 4, 5, 7:
each loses 26..34 `speedchange*_ly44_m3*` ladder rows and takes no
`lcd_offset` row).

**Remaining (A3).** The `_ds_` and `_lcdoffset*_2` siblings above, the
`lyc143` pair and `late_enable_lcdoffset{2,3}_2`: one statement of the
comparator's step and the pulse's width on the double-speed grid, derived
with the double-speed constants together rather than one at a time.

The knob sweep of 2026-09-22 (`+-1` of every GB `{.intdefine.}`, 206 knobs,
red rows first and every hit validated on the full 5157-row list from a
snapshot build) found no net-positive value: the remaining 300 rows are
mechanism rows, not phase rows.

### A4. Mode-0 STAT interrupt against a timer interrupt

Closed 2026-09-22: the dispatch chooses its vector 16 T in, after the high
push (`IRQ_VECTOR_T`), so a mode-0 request rising in the dispatch's fourth
M-cycle beats the timer request that started it
(`irq_precedence/late_m0irq_vs_tima_*`, both devices).

### A5. Halt-woken readers of the mode-0 edge

**Rows (3).** `oamdma/oamdma_late_halt_stat_2` (both),
`oamdma_late_speedchange_stat_2`. The eight `halt/` rows closed 2026-09-22:
a HALT with IME on and an interrupt already pending re-runs after the
handler (`HALT_IME_PENDING_REDO`: the `_3a`/`_3b` rows, which were never an
SCX question), a DMG HALT answers no earlier than its second M-cycle
(`DMG_HALT_MIN_MCYCLES`: `_2b`), and `M2_LEAD_HALT_BLIND` is DMG-only
(`noime_m2irq_m0stat_1 [cgb]`; mooneye `intr_2_*` then pass on CGB C and E
too, which the both-devices rule failed).

**Behaviour.** A halted CPU latches the interrupt line at a different point
of its M-cycle from a running one, and the mode-0 source's rise sits
mid-M-cycle at some SCX. GBMicrotest's `int_hblank_{nops,halt}_scx*` pairs
put the halt one M-cycle after the sled for the two sources that do not rise
on a line boundary (OAM, hblank) and level for the two that do (LYC, vblank).

**Modelled.** `HALT_IF_SAMPLE_T = 4` (the running CPU's point; 2 was
measured and ships off — its cost is +4.8% of retired instructions on a
halting main loop, cpu.nim), `M0_HALT_BLIND_DOTS = 2` (DMG: the last 2
T-cycles of a halted M-cycle cannot see the mode-0 rise; wilbertpol
`hblank_ly_scx_timing-GS` vs `-C`), `CGB_HALT_PPU_LEAD = 1` (a halted CGB's
PPU runs one M-cycle behind and gets it back at the wake; gambatte
`halt/lycirq_m2stat_{1,2,3}`, `halt/m1int_ly_{1,2,3}`, `cgb-acid-hell`),
`M2_LEAD_HALT_BLIND` (a halted CPU is blind to `STAT_M2_LEAD`; mooneye
`intr_2_*` vs wilbertpol `*_nops`). `noime_m2irq_m0stat_1 [cgb]` is the one
row `M2_LEAD_HALT_BLIND` costs on its own and is the open question at that
rule: DMG-only, or doubled up with the CGB halt lead.

**To close.** The residual is the SCX-dependent mode-0 edge (A1) read through
a halt, not a halt constant: every scalar here has been swept
(`CGB_HALT_PPU_LEAD_DOTS` 1..4, `CGB_HALT_EXIT_MCYCLES`, `HALT_IF_SAMPLE_T`)
and none separates `scx2_3a` from `scx3_2b`. One lead, from a differential
run of the GBMicrotest question through `tools/gbppu/gam_dispatch.py` and
`gam_haltwake.py` (a second-emulator harness, so a comparison and not
evidence — `docs/oracles.md` policy): dingbat's mode-0 edge reads 2 dots late
on steady-state lines when running and 2 dots early on the first post-LCD-on
line when halted, two errors that cancel in the halted steady state
(`M0_HALT_BLIND_DOTS`). Hardware arbitration is hwprobe rows 2 and 10
(`docs/hwprobe-questions.md`).

---

## B. The line after an LCD enable, and the boot hand-off

### B1. Line 0's mode edges are 2 dots later than the counter says

**Rows (45).** AGE `oam/oam-read-dmgC-cgbBC@dmgC`, `oam-read-cgbE`,
`oam/oam-write-dmgC`, `vram/vram-read-{dmgC, cgbBCE@*}` (7 arms;
`oam-write-cgbBCE@*` and `oam-read-dmgC-cgbBC@{cgbab,cgbc}` closed
2026-09-21, below); gambatte `enable_display` 15 (`ly0_late_vram{r,w}_*`,
`ly0_late_scx7_m3stat_*`, `frame{0,1}_m{0,2}{irq,stat}_count_*_ds_1`,
`enable_display_ly0_sprites_m0stat_2`, `ly0_oambusy_read_ds_1`),
`lcd_offset` 19 (all CGB). `display_startstate/stat_*_2 [cgb]` (4) closed
2026-09-22: `CGB_BOOT_PHASE` 161 -> 165, which no other row felt.
`enable_display_ly0_sprites_m0stat_2` (both devices) closed 2026-09-22: the
LCD-on line has no OAM scan and finds no objects (`LCDON_NO_OAM_SCAN`).
`ly0_m0irq_scx{0,1}_ds_1` and `frame0_m0irq_count_scx{2,3}_ds_1` closed
2026-09-22: at double speed the LCD-on line's mode-0 source trails its flag
by the same 2 dots the single-speed source spends as a lost lead
(`LCDON_M0_LAG_DS`, gb.nim).

**Behaviour.** After `LCDC.7` goes high the first line starts in mode 0 and
its mode-3 edges sit 2 dots later against the CPU's grid than on any later
line. Four independent brackets in AGE's `oam-read`/`vram-read` pair (the
same ROM with one address changed, so every phase question cancels) agree on
the 2 dots: the mode-3 open and close edges, each on a DMG and a CGB (table
at `LCD_ON_LINE0_LOCK_LEAD`, ppu.nim). mealybug's harness says the same from
the pixel side — `line_0_fix` burns 4 T-cycles fewer on LY 0
(`docs/gb-mealybug-sources.md` §1.2). `lcd_offset`'s `*_count_*` families
are a 1-dot-per-SCX coincidence ruler for the STAT raise dot; read to ±1 dot
only, because `offset1_lyc99int_m0{stat,irq}_count_scx1_ds` — flag and IRQ
of one edge — demand opposite parities.

**Modelled.** `LCD_ON_HEAD_START = 5` (DMG) / `CGB_BOOT_PHASE = 165` (CGB;
gambatte `display_startstate/stat_*`, all 12) seed the first line.
`LCD_ON_LINE0_LOCK_LEAD = 2` spends the 2 dots in the VRAM and OAM locks
only; `LCD_ON_STAT_READ_LAG = 2` spends them in the STAT read. `LCD_ON_LINE0_
TRIM` and `LCD_ON_LINE1_TRIM` (the geometry fix) ship 0: `=2` moves the
pixel rows, the mode-0 SOURCE rows and mooneye `lcdon_{,write_}timing-GS`
and is far worse whole-runner. `VRAM_READ_M0_OPEN_DOTS = 2` (3 at DS),
`OAM_READ_M0_OPEN_DOTS = 2`, `OAM_READ_M3_CLOSE_DOTS = 5`, and
`oam_read_open_late` (CGB-E's OAM lock reopens a dot later; AGE
`oam-read-cgbE` vs `-dmgC-cgbBC`) are the lock edges themselves.

**Closed 2026-09-21: the OAM write lock.** `oam-write-cgbBCE@*` (3 arms)
and gambatte `oam_access/{mid,pre,post}write*` (+5) were not line 0 at all:
a CPU write to OAM asked the lock at the START of its M-cycle while a read
asks after the dots, and the lock's edges lag the mode flag. Read at
1-dot-per-SCX resolution off the ROM's 12-write ladder (WRAM `$C000`, one
byte per write; `tools/gbfuzz/sameboy_wram.c`'s dingbat twin): sampled
after the dots the open edge is flag + 2 (+3 double speed), exactly the
read side's, the LCD-on line adds its 2-dot lead, and the CGB's LCD-on
close is flag + 2..5. The DMG shares the open edge but locks later: a
write sampled at dot 1 of a line lands and one at dot 5 does not, and the
lock lets go again over the 2 -> 3 edge (dot 81 lands, 85 does not) --
gambatte `midwrite_2`/`prewrite_2` (`dmg08_out1_cgb04c_out0`), GBMicrotest
`oam_write_l0_e`/`l1_c`, mooneye `lcdon_write_timing-GS`. `OAM_WRITE_*`
(gb.nim, ppu.nim). `oam-write-dmgC` is in `NotScored` since 2026-09-21: its delay-2 line,
which the ROM's author marks as depending on when the LCD was last switched
off, contradicts gambatte `postwrite_2_scx3` [dmg] on the open edge, and
the AGE emulator's own runner blacklists the ROM. SameBoy's DMG model does
reproduce the line, so it is modellable; the thread to pull is a
slot-by-slot diff of SameBoy's bytes against dingbat's on that line;
gambatte `prewrite_lcdoffset1_1` [cgb], which passed only because the
start-of-cycle sample cancelled the `lcdoffset1` phase error the
`preread_lcdoffset1_1` row still shows.

**Closed 2026-09-21: the double-speed mode 2 read lock on CGB 0..C.**
`oam-read-dmgC-cgbBC@{cgbab,cgbc}` failed on one line: at double speed a
read sampled at dot 1 of a line is served on CGB B/C (`EFF` = $00 in that
ROM) and refused on CGB E (`EFF` = $FF in `oam-read-cgbE`); dot 3 is refused
everywhere. `OAM_READ_M2_LAG_DOTS_DS = 2` (ppu.nim), keyed off the same
revision split as `oam_read_open_late`; 3 loses gambatte
`preread_ds_lcdoffset1_2`, and 2 takes `preread_ds_1` [cgb].

**To close (the rest).** One spelling of line 0's 2 dots that the lock
rows, the STAT rows, the interrupt rows and the pixel rows accept together.
The AGE cells are the instrument (`agediff.py`).

### B2. The CGB palette-RAM lock's edges

**Rows (15).** `cgbpal_m3/cgbpal_m3end_{1,3}`, `_ds_{1,3}`, `_scx5_ds_{1,3}`,
`cgbpal_m3start_ds_1`, `cgbpal_{read,write}_m3start_{ds,lcdoffset1}_1`;
`enable_display/ly0_late_cgbp{r,w}{,_ds}_2`.

**Behaviour.** BCPD/OCPD belong to the PPU during mode 3: reads answer
`$FF`, writes are dropped with the auto-increment still taken (Pan Docs,
"Palettes", CGB). gambatte brackets the lock's edges one M-cycle later than
the VRAM lock's on the read side; the `_ds_`/`lcdoffset1` members and the
`m3end_1/_3` pairs ask for the edge in dots, as C1 does for VRAM.

**Closed 2026-09-22** (`CRAM_LOCK_DOTS`, `cpu_cram_open_dots`): the lock is
a dot window around the mode-3 edges, a write asked at its commit and a read
at the start of its M-cycle. It engages `CRAM_LOCK_ON_LAT = 1` dot after
the mode-3 edge at single speed and 2 at double (`_DS`; 3 and 4 lose the
`_ds_lcdoffset1_2` pair, 2 loses nothing), releases `CRAM_LOCK_OFF_LAT = 2`
dots after the mode-0 edge at both speeds (3 loses `m3end_scx3_{2,4}`, whose
mode 3 ends 3 dots later than `m3end_{2,4}`'s under the same sled; 4 loses
nine), and the LCD-on first line engages `CRAM_LOCK_LINE0_EXTRA = 4` dots
later instead of not at all (`enable_display/ly0_late_cgbp{r,w}_2`). +11
rows, none lost; the `_ds_` members of ly0_late_cgbp* and the B1 residue
remain. SameBoy reaches the same window (`cgb_palettes_blocked` 3 dots into
its mode 3 and 4 dots into its mode 0, with its line 3 dots ahead of ours).

---

## C. Mode 3: locks, window, scroll, objects, palettes

### C1. The VRAM and OAM locks at mode 3's two ends

**Rows (27).** `oam_access/{postread_scx{2,3,5}_2, 10spritesprline_postread_2,
postwrite_2_scx3, midwrite_2, prewrite_{2,ds_2,ds_lcdoffset1_2},
preread_{ds,lcdoffset1}_1}`, `vram_m3/{postread_scx{2,3}_2,
10spritesprline_postread_2, preread_lcdoffset2_1, prewrite_lcdoffset2_1}`.
`vramw_m3end_scx3_5` (both devices) closed 2026-09-22: a VRAM write issued
in mode 3 asks the lock 3 dots into its M-cycle (`VRAM_WRITE_M3_END_DOTS`,
memory.nim; 0 at double speed).

**Behaviour.** The CPU's VRAM and OAM access windows open and close on PPU
dots, not on the CPU's M-cycle boundaries (Pan Docs, "Accessing VRAM and
OAM"). The `postread_*_2` rows read one M-cycle after the mode 3 -> 0 edge at
SCX 2/3/5 or with ten objects and want the lock open; `prewrite`/`preread`
ask the close edge at mode 3's start on CGB and in double speed.

**Modelled.** Open edge: `VRAM_READ_M0_OPEN_DOTS = 2` / `_DS = 3`,
`OAM_READ_M0_OPEN_DOTS = 2` / `_DS = 3` (AGE-bracketed, B1). Close edge:
`VRAM_READ_LIVE_LOCK = 2` (the DMG's read lock asks the live mode, the
CGB's the latched one; gambatte `vram_m3/preread_2_dmg08_out3_cgb04c_out0`),
`OAM_READ_M3_CLOSE_DOTS = 5`. Writes ask the live mode at their commit point
(`OAM_WRITE_M2_TAIL = 1`: the last M-cycle of mode 2 still takes an OAM
write; mooneye `lcdon_write_timing-GS`).

**To close.** The `postread_*_2` rows are single-speed `_dmg08_cgb04c_out0`
rows that `VRAM_READ_M0_OPEN_DOTS = 2` was expected to take and did not; the
AGE-derived 2 dots and gambatte's read M-cycle have not been reconciled on
them (`-d:gb_dma_trace` prints both). The CGB/DS close-edge rows need the
close in dots, as the open now is.

### C2. The window's mode-3 penalty near the right edge

**Closed 2026-09-21 (CGB and WX 165).** AGE `stat-mode-window/*` was a
reading error in the triage, not a three-way conflict: gambatte
`m2int_wxA6_m3stat_3` [cgb] wants mode 0 by its third read, i.e. the CGB's
WX = 166 line is 178 dots there too, and 180 was dingbat's number, not
hardware's. The mechanism: mode 3 ends `m3_lead` (2) dots before the last
pixel would leave the shifter, and a window restart delays that pixel by a
fetch, so the flag falls at hit + 5 + (159 - lx) wherever the match lands
-- a flat six dots. dingbat's tail waited for the restarted fetch's push
instead: +1 at WX 165, +2 at WX 166 (`WIN_TAIL_FLAG_LEAD`, gb.nim; the
`-d:gb_m3_trace` dots at 246/248/249 for WX 163/165/166 all retire on 254
under the rule). AGE 75 -> 81 (`stat-mode-window-{cgbBCE,ds-cgbBCE}@*`),
gambatte window 426 -> 434 (`m2int_wxA5_m0irq_2` both devices,
`m2int_wxA6_{,firstline_,scx5_}m3stat_3` [cgb], `m2int_wxA6_{,scx5_}
m3stat_ds_2`, `m2int_wxA6_vrambusyread_3` [cgb]), nothing lost.

**Closed later the same day (DMG WX 166).** `stat-mode-window-dmgC` read
the DMG's carried WX = 166 line (`DMG_WIN_LAST_PX_CARRY`) as 173 against
AGE's 172, the same row as WX 167. `fetch_work_pending` held mode 3 for
the carried line's own match, citing gambatte `m2int_wxA6_m3stat_1` [dmg]
as wanting "174, not 172"; with the term deleted that row still passes,
`m2int_wxA6_scx3_m3stat_2` [dmg] joins it, and nothing in `window/`,
mealybug or the `on_screen` frames moves. The claim was stale. AGE 87 ->
88. The `spxA7` CGB rows (`m2int_wxA6_spxA7_{m0irq_2,m3stat_2,m3stat_4}`)
closed 2026-09-22: the CGB's object at the window's first column yields to
the window start on the last pixel too, where the DMG charges it first
(`CGB_OBJ_YIELD_LAST`). The remaining `window/` rows are the `m0irq`,
`oambusyread` and `on_screen` families.

### C3. Mid-line SCX stores

**Rows (10).** `scx_during_m3/scx_0761c0/scx_during_m3_{2,3,4,ds_2..ds_5}`
(the `_3`/`_4`/`_ds_*` members at ~2400 wrong pixels, `_2`/`_ds_2` at 9),
`scx_during_m3_spx2{,_ds}`, `scx_attrib_during_m3_spx2_ds` (8 px each,
CGB, an object case).

**Behaviour.** The BG fetcher's map column is a live sum
`((SCX + 8k - F) shr 3) and 31` — a store that lowers `SCX and 7` below the
line's latched fine scroll borrows one tile (`SCX_FINE_BORROW`; the DMG
borrows one pixel tighter, `SCX_FINE_BORROW_DMG_LEAD`; AGE `m3-bg-scx` ×3
exact). The fine-scroll discard is a slot counter compared each dot against
the live `SCX and 7`; a store landing above the new value but at or below
the old one is matched only after the counter wraps and runs eight more
slots (`SCX_FINE_LATCH_WRAP = 8`; gambatte `scx_m3_extend_{ds_1,ds_2}` write
SCX twelve times on one line and bracket the edge to two dots).

**Not modelled.** Each fetcher stage as two T-cycles with the address latched
in the first and the read in the second, and per-model visibility of an SCX
store inside its own M-cycle — `Assumed; no ROM in the tree pins either`,
and `CGB_SCX_LATENCY = 2` is the one term carried. The `scx_0761c0` residue
is at `F = 7`, where every store lowers the target; `spx2` is an object
fetch under a store.

**To close.** Hardware experiment (b) below measures the extension law
directly. `tools/gbppu/m3len.sh` / `-d:gb_m3_len` give dingbat's side.

### C4. Objects: the X = 167 slot and the CGB's fetch cancel

**Rows (4).** `sprites/10spritesPrLine_10xposA7_m0irq_2` (both devices; ten
objects at OAM X = 167), `sprites/late_disable_ds_1 [cgb]`,
`sprites/enable/late_disable_ds_3 [cgb]`.

**Behaviour.** An object at X = 167 triggers on the line's last pixel and
shares the fetch slot with the tail burst (`OBJ_TAIL_WALK_REFUND`, pinned by
the single-object `xposA7` rows). Clearing LCDC.1 while an object fetch is
in flight cancels it on the DMG (Pan Docs, "Mode 3 Length": the fetch is
abandoned; mealybug `m3_lcdc_obj_en_change_variant` and gambatte
`sprites/sprite_late_*_disable_*` bracket the refund, `OBJ_ABORT_LEAD = 2`,
`OBJ_ABORT_FLAG_HOLD`). `CGB_OBJ_ABORT = 0`: the CGB reference of the same
mealybug ROM wants the full penalty, and the one row cannot separate "no
cancel" from "LCDC.1 reaches the CGB fetcher later"; the two `_ds` rows are
the double-speed members that could.

### C5. Arming the window late through WY

**Rows (10).** `window/arg/late_wy_{1toFF,2toFF}_2`, `late_wy_2`,
`window/late_wy_2`, `late_wy_lcdoffset1_2` [cgb] (the disarm and line-0
cases), `late_scx_late_wy_FFto4_ly4_wx00_{1 [cgb],2 [dmg]}`, and the double-
speed `late_wy_FFto2_ly2_ds_1`, `late_wy_ds_1`, `late_enable_ly0_ds_1`.
Closed 2026-09-22 (second pass): the late-line cutoff and the DMG's one-dot
check below took 14 rows.

**Behaviour.** The WY condition is a latch set on the first line where
`LY == WY` while the window is enabled and held for the frame (Pan Docs,
"Window"; `docs/gb-derivations.md`, "the window starts on an equality, and
the WY latch is a level"). On the DMG every failing row is an "arm late"
ROM (WY written to LY in the handler, `FFto*`, `10to*`,
`late_enable_afterVblank`) and every "disarm late" ROM (`1toFF`, `2toFF`)
passes, so the arm deadline is a rule of its own and not a symmetric latch
dot. The CGB's deadline is one M-cycle earlier than the DMG's in 13 of 14
families.

**Modelled.** The level latch; `CGB_WY_LATENCY = 4` (one M-cycle, clipped to
3 dots by `CGB_LATENCY_CAP = 1`), `CGB_WY_LATCH_LATENCY = 0`.

**Closed 2026-09-22 on the CGB** (`WIN_CHECK_DEFER_CGB = 5`,
`WIN_LINE0_CHECK_DOT_CGB = 4`, `win_check_now`): a WY write or an LCDC.5
enable no longer arms the latch at its landing; the comparator samples 5
dots after the commit (4 and 5 equal at +28/+29, 6..8 lose the mid-line
`late_wy_FFto2_ly2_*_1` writes, whose window must still start on the same
line; 8 takes two more boundary rows and loses six), reading the LY of that
dot, and line 0's per-line check runs at dot 4 rather than the boundary
(`late_wy_{1,2}` against `late_wy_lcdoffset1_{1,2}`: the boundary check sees
the WY value a write committed in the boundary M-cycle lands 4 dots later).
+27 with the A3 lead in place, +2 without it. The DMG (`WIN_CHECK_DEFER_DMG`,
4 loses 3) and the `_ds_` members keep the immediate latch; `window/late_wy_2`
and `late_wy_10to1_ly1_1 [cgb]` are the two single-speed rows the rule
still misses.

**Closed 2026-09-22, second pass** (`WIN_LATCH_END_DMG = 451`,
`WIN_LATCH_END_CGB = 454`, `WIN_CHECK_DEFER_DMG = 1`): a WY == LY match seen
at or after that dot no longer latches the window, because the per-line check
that carries it has already run (gambatte-core checks LY == WY at line cycle
450 and LY + 1 == WY at 454); the DMG's comparator samples one dot after the
write (its WY copy lags 2 cycles there). +14: the `_3` DMG arms of
`late_wy_{10to0_ly1,FFto0_ly2,FFto1_ly2,FFto2_ly2_scx3}` and
`late_enable_afterVblank`, the CGB `_2` arms and `_ds_2`/`ds_lcdoffset1_2`
members of the same families. Each constant is bracketed at its declaration.

### C6. Window disable and re-enable mid-line on the CGB

**Rows (5).** `window/late_disable_scx5_ds_1`, `late_reenable_scx3_2`,
`late_wx_scx3_2` (CGB), `window/on_screen/wx17_weoff_wxA5_weon [cgb]`
(960 px), `window/on_screen/wxA6_late_we_reenable_3 [dmg]` (916 px).

**Behaviour.** Clearing LCDC.5 mid-mode-3 returns the fetcher to the
background at its next map read (mealybug's PPU notes; `WIN_EN_ABORT = 1`,
DMG and CGB); a CGB window start is revocable for the dots it has run
(`CGB_WIN_REVOKE_LAG = 1`, `CGB_WIN_EN_DEFER = 5`, `DMG_WIN_EN_REVOKE = 1`).
`wxA6_late_we_reenable_3` is the one DMG carry row left: its re-enable at
dot 85 counts one window line too many on the first reactivated line only
(`WIN_CARRY_REACT_LINES = 1` is right on 126 lines and wrong on one).

### C7. The DMG BGP transition pixel

**Rows (8).** `dmgpalette_during_m3/dmgpalette_during_m3_{3,4,5,scx1_4}`,
`lycint_dmgpalette_during_m3_{3,4}`, `scx3/dmgpalette_during_m3_{4,5}` —
144 wrong pixels = one per line, or 1.

**Behaviour.** A DMG BGP write reaches the pixel two dots back as
`old or new` for one pixel (hardware photographs in SameBoy issue #65,
mattcurrie 2018;
mealybug `m3_bgp_change` samples BGP once per dot and is exact with it;
daid `ppu_scanline_bgp_1.dmg.png`). It is instance-dependent: daid ships
three accepted DMG references (`_0` old value, `_1` OR, `_2` new value —
GBEmulatorShootout issue #9) and dingbat is pixel-exact on exactly one per
setting. gambatte's references encode the clean edge.

**Modelled.** `MIXER_PALETTE_OR = 1`, `MIXER_PALETTE_BACK = 2` (DMG only; the
CGB's own write dot puts the pixel out of reach). Not a correctness constant
but a DMG-instance choice with no selector; these eight rows are the price
of the mealybug/daid side. Hardware experiment (d) below.

### C8. AGE `m3-bg-bgp-dmgC`, 2 pixels

**Closed 2026-09-21.** Both pixels were x = 0 on a line whose BGP pulse's
restoring write found pixel 0 exactly MIXER_PALETTE_BACK stages down the
mixer tail (SCX 1 in the first band, SCX 5 in the second): the model
painted it `old or new` (black), hardware paints it the clean new shade.
The band's run lengths, 10 - SCX, put every other edge where the model
has it. `MIXER_PALETTE_OR_HEAD = 0` (gb.nim): the line's first pixel is
never the transition pixel. mealybug is unchanged and gambatte
`dmgpalette_during_m3/dmgpalette_during_m3_scx1_4` goes from 144 wrong
pixels to 1.

---

## D. DMA

### D1. HBlank DMA blocks owed across a halt or a speed switch

**Rows (7).** `dma/hdma_transition_ei_halt_late_unhalt_ldaaimm_hdma_scx1_1`
(IME-on wake of a "requested" block), `hdma_transition_speedchange_7fffstop_inc`
(STOP at $7FFF, its operand byte in VRAM), `hdma_pc_7ffe`, `late_gdma_pc_7ffe_1`
(a transfer while the CPU fetches across $7FFF/$8000),
`hdma_late_enable_{ds_lcdoffset1,lcdoffset3}_2` (the lcdoffset grid, A1/E1),
`hdma_disable_display_1`. 32 rows of this bucket and 7 of
`irq_precedence/hdma_vs_*` closed 2026-09-22 (below).

**Behaviour.** An HBlank DMA copies one 16-byte block per mode-0 edge while
the CPU is off the bus (Pan Docs, "LCD VRAM DMA Transfers"). The CPU hands
the bus over at its opcode fetch or an instruction boundary — never on an
operand M-cycle (`HDMA_GRANT_FETCH_DOTS`, `HDMA_GRANT_BOUNDARY_DOTS = 3`;
gambatte `dma/hdma_start*` and mealybug `dma/hdma_timing-C` parameterised by
the fetch). A halted CPU's edge detector holds a CPU-clocked copy of the
mode, so a mode-0 edge under a halt is invisible until the CPU runs again
(`HDMA_HALT_M0_BLIND = 1`, `HDMA_HALT_BLIND_LAG = 2`). The HALT itself is a
request state, not a hand-over point:

* A request up when the HALT executes (owed and not granted, or its edge on
  the HALT's own dot) is parked and paid at the wake whatever the mode then
  is (`HDMA_HALT_DEFERS_DUE`, `HDMA_HALT_REQ_DOTS = 0`). That HALT has already
  fetched the next opcode without moving PC past it: with IME off the wake
  runs the prefetched byte, then fetches it again (`HDMA_HALT_REQ_BUG`; the
  `inc` rows count it, the `7fffhalt` row proves the byte was read before
  the block rewrote it), and the block's release M-cycle is that fetch.
* An edge that falls inside a running block is lost — the block
  acknowledges the request as it ends (`HDMA_BLOCK_SWALLOW`).
* A wake from a halt entered in mode 0 is blind for its own M-cycle
  (`HDMA_WAKE_BLIND_DOTS = 4`); a wake in mode 0 takes the block only if the
  request window, which closes a few dots before the line end, is still open
  (`HDMA_WAKE_M0_MARGIN = 4`).
* The KEY1 switch's stall is the same HALT (`HDMA_SWITCH_HALTS`): a request
  it finds pending (up for `HDMA_SWITCH_REQ_AGE = 2` dots, or its edge on the
  STOP's dot, `HDMA_SPEEDSWITCH_KILL_W`) runs its block inside the stall and
  ends the transfer with the length unchanged when switching to double speed,
  and is paid at the stall's end when switching to single (`HDMA_SWITCH_REQ`);
  either way STOP's operand byte, already in the opcode latch, runs as the
  first opcode after the stall (`HDMA_STOP_OPERAND_RUNS`; the ROMs write
  `stop, 3c`).
* A block whose request rises on the dot an interrupt dispatch would begin
  takes the bus first (`HDMA_EDGE_BEATS_DISPATCH`, `HDMA_WAKE_DEBT_RECHECK`;
  `irq_precedence/hdma_vs_*`, the dispatch's stack push being the DMA's
  source).

Its bytes land 4 dots after the block (`HDMA_VISIBLE_DOTS`;
`hdma_start_ds_1` and `hdma_start_scx5_2` separate dots from M-cycles).
Every one of these knobs is bracketed two-sided or has its one-sided bracket
at the declaration in `gb.nim`.

**To close.** The IME-on requested wake (`ei_halt_..._1`): the dispatch
pushes the PC after the HALT and 12 dots later than dingbat's; `7fffstop`
wants the stall's prefetched operand read from VRAM before the block, as
`7fffhalt` does; the `pc_7ffe` pair is the CPU's fetch from locked VRAM
during a transfer. How the rules were read: the gambatte oracle trace in
`tools/gbppu/README.md` ("Side-by-side event traces").

### D2. OAM DMA against the mode-2 scan and the CPU

**Rows (4).** `oamdma_src0000_busyint0002` (both devices),
`oamdma_src8000_srcchange0000_busyinc` (both).

**Closed 2026-09-22 (+9).** `late_sp{00x,00y,01x,01y,39x,39y}_ds_*`,
`late_sp39x_4`, `sprites/late_disable_ds_1`, `sprites/enable/late_disable_
ds_3`: the `_ds` ROMs run with LCDC.1 clear, and the CGB fetcher stops for
objects anyway (`CGB_OBJ_FETCH_OFF`; alone it phase-swapped the family),
while at double speed the transfer's edge sits two dots earlier against the
scan, object N at 2N + 2 (`OAM_SCAN_DMA_EDGE_DS`, the write offset's +3
against single speed's +1).

**Behaviour.** The mode-2 scan reads OAM entry `n` on dot `2n` and reads
nothing while an OAM DMA owns the OAM bus; the transfer moves one entry per
16 dots (8 in double speed) against the scan's one per 2, so no start
latency can express the rows (Pan Docs, "OAM DMA Transfer"; gambatte
`oamdma/late_sp{00,01,02,39}{x,y}`, sixteen one-M-cycle brackets). A running
transfer is a bus HOLD on the comparator — entries inside the span compare
against the last Y/X latched (`strikethrough` keeps its object 39).

**Modelled.** `OAM_SCAN_DMA_LOCK = 1`, `OAM_SCAN_DMA_HOLD = 1`,
`OBJ_SCAN_DOT_ADJ = 0`, `CGB_OAM_DMA_START_T = 8`, `OAMDMA_HALT_PAUSE = 1`,
`OAMDMA_FREEZE_BUS = 1`, `OAMDMA_WRAM_A12 = 1`, `OBJ_DMA_BUS_LEAD`.

**To close.** The two `busy*` families are value rows (which byte a
colliding access sees) and are undiagnosed.

---

## E. The KEY1 speed switch

### E1. What the switch does to the divider, the APU tap and interrupts

**Rows (18).** AGE `speed-switch/spsw-tima-{cgbBC@*,cgbE}` (3),
`spsw-ch2-lc-delay-cgbBCE@*` (3), `caution/spsw-interrupts-{cgbBC@*,cgbE}`
(3); gambatte `speedchange/speedchange{,2,5}_ch2_nr52_{1a,2a}{,_ds}` (6).
`sound/ch2_late_reset_nr52_2b{,_ds}` (3) went green on 2026-09-22 with the
APU's own share of the stall (`APU_SPSW_EXTRA_DOTS`, section H).

**Behaviour.** A switch armed by KEY1 and taken by `STOP` resets DIV and
stalls the CPU for 2^17 cycles of the NEW CPU clock while the timer, serial
and OAM DMA keep running — a HALT, not a STOP leaf (Pan Docs, "CGB
Registers", KEY1; gambatte `speedchange_tima00_*` count 128 ticks through
it, `speedchange2_*` twice the real time on the way back). The PPU comes out
8 dots ahead of the CPU clock into double speed and 3 back into single
(`speedchange{,2,3,4,5}_ly44_m3_*`, a ladder in switch count). An interrupt
arriving during the stall ends it; a switch whose HALT is skipped because
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

**Residue.** Channel 2's length counter expires one M-cycle early in three
of seven switch configurations (`sc`, `sc2_ds`, `sc5`: ends in double
speed, odd switch count) and is exact in the other four, including `sc3`,
which refutes a flat delay (the duty-pointer ladder in H2 has the same
shape); the `speedchange_tima0x` family is internally
unsatisfiable by any stall length (the failures are one tick low, so it is
which cycles the timer sees around the reset). The AGE tables are readable
at cell resolution and have not all been read since the DIV-reset split
landed.

---

## F. Serial and timer

### F1. The eighth shift edge against a CPU access

**Rows (7).** `serial/nopx1_start{,83}_wait_read_if_2`,
`start83_late_div_write_wait_read_if_{1b,2b}` (CGB),
`start_wait_trigger_int8_read_if_{2,ds_2}` (CGB).

**Behaviour.** The shift clock is a falling edge of a divider bit
(Pan Docs, "Serial Data Transfer"); a CPU access meets the shifter before
its own M-cycle's tap edge (`SERIAL_CPU_SAMPLE_T = 0`; gambatte
`serial/start_wait_read_{sb,sc,if}_*`, `nopx1_*`). `SERIAL_TAP_DMG = 4` and
`SERIAL_TAP_CGB = 4`: a 4-T-wide plateau on each SoC, mooneye
`boot_sclk_align-dmgABCmgb` pinning the DMG. Re-seeding the boot divider
instead is refused by GBMicrotest `timer_tima_phase_*` and gambatte `div`.

**Residue.** The CGB's fast-clock arms and the `trigger_int8` ordering; no
point of the tap/sample space (`SERIAL_TAP_*` × `SERIAL_CPU_SAMPLE_T`)
reaches them, so it is not a phase.

### F2. TIMA reload against a read

**Rows (4).** `tima/tc00_late_tc01_{5,7}` (both devices).

**Behaviour.** Switching TAC's tap reads the newly selected divider bit one
M-cycle before the byte lands and leaves the old tap at the value latched at
the end of the write (`TAC_SELECT_LEAD_T = 4`; `tc00_late_tc01` and
`tc00_tc01_late_tc00_of_2` pin the two halves in opposite directions). `_5`
reads TIMA on the M-cycle dingbat's 4-cycle reload countdown expires and
gets the pre-reload value where hardware has reloaded: the reload window's
interior (Pan Docs, "Timer Obscure Behaviour") is not modelled —
`docs/pandocs-audit.md` A6. Arming the countdown at 5 instead halves the
family.

---

## G. Revision-vocabulary rows, closed by scoring the right machine

**Rows (0).** wilbertpol `acceptance/gpu/ly00_mode1_2-C`, `ly_new_frame-C`
and `ly_lyc{,_0,_144,_153}-C` were red (two scored) or skipped (four) while
the runner stood the fork's `-C` on CPU CGB C. They are green since the
fork's Color rows moved to CGB E (`WilbertpolCgbRep`, the runner).

**Behaviour.** Three behaviours split at CGB C/D, and AGE ships each as a
ROM pair with per-unit hardware records in the headers: the readable LY 153
-> 0 edge is one M-cycle later on D/E/AGB at single speed
(`ly_read_edge_late`; `ly/ly-dmgC-cgbBC` vs `ly-cgbE`, one byte apart); the
M-cycle of mode 0 between mode 1 ending and line 0's mode 2 exists on every
DMG and CGB <= C and not on D+ (`m1_end_no_mode0`; `stat-mode-dmgC-cgbBC`
vs `stat-mode-cgbE`, the `M1E` byte); CGB D+ hold the LY=LYC comparison the
blind window is leaving (`lyc_compare_hold`). gambatte's CPU-CGB-C rows say
the same at one-NOP resolution (`ly0/lycint152_ly153_{1,2,3}` read 152, 153,
0; `lycint152_ly0stat_{1,2,3}` read $C1, $C0, $C2). wilbertpol's `-C` is the
2016 fork's hardware GROUP `cgb+agb+ags` with no revision axis, its sources
say only "pass: CGB, AGS", and its six ROMs on these edges assert the D+
values -- no machine passes them and the gambatte/AGE C rows together.
Every `-C`/`-cgb` ROM in the fork passes on CGB D and E (182/182 serial
rows); SameBoy, which claims the whole fork, tests it on CGB E. Upstream
mooneye never carried these gpu ROMs: they were written for the fork after
its author's one upstream PR.

**Still open on hardware.** Whether a CPU CGB C also holds the LY=LYC
comparison (`lyc_compare_hold`, `docs/oracles.md`): no ROM in the tree pins
the C/D placement of `ly_lyc*`, and the fork's CGB E score does not ask.

---

## H. The APU as heard: gambatte's `_outaudio` rows

gambatte scores 220 of its ROMs on sound, not pixels (`test/testrunner.cpp`):
after the run, `audio0` iff all 35,112 samples of the final frame are equal,
`audio1` otherwise, on the raw 2 MHz mix with no output filter. The harness
reproduces the rule with a probe on the mixer (`GbApu.probe_*`, armed by
`--mode=gambatte` for the last frame; `tests/README.md`). The ROMs are
one-NOP ladders around a square channel's duty pointer, envelope or sweep, so
they read the APU at a resolution nothing else in the tree does. Scored since
2026-09-21: 207 of 220 (`sound` 184/184, `speedchange` 23/36).

**Closed by them (all knobs two-sided, comments carry the brackets).**
`BOOT_CH1_PHASE_{DMG,CGB}_T` (memory.nim): the boot beep's second note is
still stepping at the hand-off (NR52 = $F1), frequency $7C1, and
`ch1_init_pos_{1..8}` pin where in its 2016-cycle duty cycle each boot ROM
leaves it (728 / 1612, one value of 504). `BOOT_FS_STAGE_{DMG,CGB}`: the
frame sequencer's step at the hand-off (1 / 0, `ch2_init_env_counter_timing`).
`ENV_TRIGGER_PRECLOCK_SKIP` (abstract_channels.nim): a trigger inside the
sequencer step before the envelope clock, taken 4 T early, misses that clock.
`SWEEP_TRIGGER_LEAD_T_{DMG,CGB}` = 4 / 8: a trigger that close before a sweep
clock misses it. `APU_POWERON_TAP_LEAD` = 4 (apu.nim): the tap bit that
decides the skipped first DIV-APU edge is sampled 4 counts ahead of the NR52
write. `APU_SPSW_EXTRA_DOTS` = 10 / `_SINGLE` = 7: the APU's share of the
KEY1 stall's oscillator restart, the PPU's 8 / 3 by another clock.

### H1. A double-speed trigger's grid edge

**Rows (2).** `sound/ch1_duty0_pos6_to_pos7_timing_ds_6` and
`speedchange_ch1_duty0_pos6_to_pos7_timing_nop_ds_2`.

**Behaviour.** At double speed a CPU write can land half a 1 MHz tick off
the APU's grid. gambatte's ladder `_ds_1..6` says a first trigger one NOP
later still counts from the SAME edge (the edge before the write); SameSuite
`channel_{1,2}_align{,_cpu}` and `channel_1_freq_change_timing-*` (7 rows,
all green) say a write between edges waits for the next. Both are hardware
records on CPU CGB C. `APU_TRIGGER_EDGE_BEFORE = 1` takes the two and loses
the seven; it ships 0.

**Refuted.** A half-tick shift of the grid's anchor at power-on or at the
switch (`tick_phase` + 4 CPU cycles): breaks `_ds_2`/`_ds_4` and fixes
nothing.

### H2. The switch ladder is not additive

**Rows (13).** `speedchange{2,3,4,5}*_ch1_duty0_pos6_to_pos7_timing_*` (12)
and `speedchange_ch1_nr4init_duty0_pos6_to_pos7_timing_2`.

**Measured.** With the single-switch values pinned (to double 10, back 7, each
two-sided at a NOP), the multi-switch ROMs want sums no constant pair gives:
two switches (up, down) 14..16; three (up, down, up) exactly 24; four 22..26;
five about 32. A fourth switch adds nothing where a second added 5, so the
extra depends on the state the switch finds (divider phase after its reset,
most likely), the same open residual as the PPU's `lcd_offset` rows (E1).
(8, 6) scores three more rows than (10, 7) and is two-sided on nothing; it is
not shipped.

---

## Hardware experiments that would close buckets

The ROMs exist in `tools/gbprobe/` (raw values, no baked expectation,
on-screen hex); dingbat's prediction and the hardware status per probe are
in `docs/gb-probe-oracle-results-2026-08-11.md`, and the catalogue of every
hardware question with its priority is `docs/hwprobe-questions.md`.

* **(a)** Does the STAT mode field report differently to `LD A,(C)` and
  `LDH A,($41)` at the mode 3 -> 0 edge? Settles whether `STAT_M0_FIELD_TAIL`
  (ships 0; gambatte and wilbertpol want a 3-dot field tail that GBMicrotest's
  `LDH` readers refuse, and idiom and suite are perfectly confounded) is
  silicon or an artefact. `probe_a_statidiom.gb`.
* **(b)** How much does a mid-line SCX store lengthen mode 3, as a function
  of where it lands? C3. `probe_b_scxm3.gb`.
* **(c)** `cgb-acid-hell`'s LCDC.4 toggle and daid's BGP band edge on ONE
  frame: does emission separate from the fetch grid by four dots?
  `probe_c_arbitrate*.gb`; the g1 session (`docs/flashcart-runbook.md`,
  "g1, GBA SP") read the frame on a GBA SP.
* **(d)** The DMG BGP transition pixel on as many DMGs as can be borrowed,
  with mainboard/CPU markings per unit — C7. The sample size is the
  experiment; no single unit can answer it.

---

## Refuted models (do not re-derive)

Each was built and scored; the refusing ROMs are named so the idea is not
tried again as a knob.

* A uniform STAT-field lag at the mode 3 -> 0 edge (`STAT_MODE0_LAG`): every
  `_2` member of `sprites/*_m3stat` refuses it. At the 2 -> 3 edge
  (`STAT_MODE3_LAG`): `m2int_m2stat/*_ds_2`. A CGB-only 2 -> 3 lead
  (`STAT_MODE3_LAG_CGB = -1`) takes `halt/lycirq_m2stat_2 [cgb]` and is
  refused by five object-free CGB field readers on the same edge.
* Paying the mode-0 field's 3 dots at the EDGE (`M3_END_EARLY`): refused by
  `m0enable` (interrupt, object-free) and GBMicrotest `poweron_stat_*`,
  `win*_a`. Paying them at the field (`STAT_M0_FIELD_TAIL = 3`): refused by
  24 GBMicrotest `win*_b` / `ppu_sprite0_scx*_b` rows. Gating on the read
  idiom (`STAT_M0_TAIL_MAX_MC = 2`) reconciles all three suites and is
  unproven — experiment (a).
* The CGB's mode-0 boundary one M-cycle earlier than the DMG's: 40 gambatte
  families that probe the edge through four instruments are device-equal
  (`vramw_m3end_{1..6}` the sharpest); every family that does flip earlier
  on CGB is a register write racing an edge or a halt.
* A line-0 geometry trim (`LCD_ON_LINE0_TRIM = 2`, `LCD_ON_LINE1_TRIM = -2`):
  refused by mooneye `intr_1_2_timing-GS`, gambatte `m2enable/late_enable_
  ly0_*`, `ly0/lycint152_m2stat_1` and, at cell resolution, by AGE
  `stat-mode-window`, `stat-mode`, `stat-int` and `ly`.
* Line 0's mode-2 STAT interrupt one M-cycle late, or line 0's mode 2 four
  dots short: refused by the same mooneye row and by `m0enable`,
  `vramw_m3end`, `lcd_offset`.
* A readable-LY / comparator split at line 153 (`LY153_SNAP_DOT`,
  `LYC_SETTLE_DOTS` moved apart): every gain reads LY and every loss is a
  LYC = 153 match ending early (`ly_lyc_153-GS`, `line_153_lyc153_stat_
  timing_b`). The CGB snapback relatch at dot 13 for daid: refused by
  `ly0/lycint152_lyc0{flag,irq}_{1,2} [cgb]`, dot 9 bracketed both sides.
* A second M-cycle of OAM-source lead (`STAT_M2_LEAD = 2`): GBMicrotest
  `int_oam_nops`/`int_oam_incs` read one M-cycle under. An LYC-source-only
  lead (`STAT_LYC_LEAD = 1`): six GBMicrotest LYC sleds go one M-cycle early.
* A CGB halt-exit charge (`CGB_HALT_EXIT_MCYCLES = 1`): 42 `tima/*` rows with
  one expected value for both devices refuse any time spent. Sub-M-cycle
  halt leads (`CGB_HALT_PPU_LEAD_DOTS` 1..3): the wake is latched on the
  M-cycle grid, so they are whole M-cycles for a source near a boundary and
  nothing otherwise.
* A CGB-specific OAM DMA start latency (`CGB_OAM_DMA_START_T = 4`): 103
  `oamdma` rows pin 8 T. The `late_sp*` rows as a start latency: unmoved
  from 4 T to 40 T.
* A per-block HDMA delay of one M-cycle (rather than 4 dots of data hold):
  `hdma_late_disable_{2,scx2_2,scx3_2}` and the `hdma_late_m3speedchange_*`
  ladder read the block's bus occupancy where it is.
* The SCX extension as a pipeline stall (`SCX_STORE_STALL_DOTS`): 65 PNG
  rows — a stall displaces pixels from the store's dot, the borrow from the
  next fetch boundary. Counting discard slots without `and 7`: mode 3 runs
  off the end of the line.
* `$D000-$DFFF` aliasing `$C000` as a banking rule: contradicted by the two
  SVBK ROMs; the 64 rows were the DMA driving A12 (`OAMDMA_WRAM_A12`).
* Mode 3's LENGTH as the cause of the `NspritesPrLine` family: the per-object
  cost is exactly Pan Docs' `6 + max(0, 5 - ((X + SCX) mod 8))`
  (`tools/gbppu/objtab.py` 153/153 against GBMicrotest `ppu_spritex_vs_scx`),
  and every double-speed member passes; the family measures the STAT
  readback.
* A frame-level mystery in `window/arg/late_wy_*`: 13 of 14 families have
  different expected values per device, shifted one M-cycle, and the CGB is
  EARLIER — a positive CGB delay moves it the wrong way.
* `m0enable` as a STAT-phase bucket: zero rows move under any STAT
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

* Line 0's pipeline one M-cycle ahead (the PNG rows): `STAT_M2_LEAD = 1` +
  `M3_PIPE_AHEAD = 1` (the OAM source rises one CPU M-cycle before its line,
  and the pipeline with it); `LY0_PIPE_MCYCLES` is what it subsumed.
* `$FEA0-$FEFF` is RAM on CGB 0-D (`addr and not $18` on 0-C), nibble echo
  on E: `GbUnusableRegion`; `cgb-acid-hell`'s own readback gate pins the mask.
* HDMA source outside cartridge/WRAM moves `$FF`: `dma_hiram_read_result`.
* The dispatch's IF clear at T = 16: `IRQ_SAMPLE_T` (A2 is what it left).
* The LY=LYC comparator blind while LY changes, at every line edge and the
  vblank entry: `ly_advance_close`, `LY_BLIND_SCOPE = 2`.
* A `$FF0F` read's sample point inside its M-cycle: `IF_READ_SAMPLE_T`
  (spelled in `irq_read`, interrupts.nim).
* The VRAM read lock's live-mode clause is DMG-only: `VRAM_READ_LIVE_LOCK = 2`.
* STAT readback samples the mode at `cc - 2` (`cc - 3` in double speed):
  `STAT_READ_SAMPLE`, `STAT_READ_SAMPLE_DS_ADD`; the `NspritesPrLine` family
  with it.
* The mode-0 STAT source's 2 dots in the retire -> flag hand-off:
  `STAT_M0_LEAD_T = 2`; AGE `halt-m0-interrupt` and `stat-int` (single speed)
  with it.
* The OAM scan against an OAM DMA: `OAM_SCAN_DMA_LOCK`, `OAM_SCAN_DMA_HOLD`;
  `strikethrough` kept.
* The speed switch's two clocks and the PPU's 8/3 re-alignment:
  `SPEED_SWITCH_STALL_CPU`, `SPEED_SWITCH_PPU_EXTRA_DOTS{,_SINGLE}`; the DIV
  reset one M-cycle after the STOP fetch and its slow-tap split:
  `SPEED_SWITCH_DIV_RESET_T{,_SLOW}`.
* A halted CGB's PPU one M-cycle behind, given back at the wake, absent on
  the LY 153 -> 0 snapback: `CGB_HALT_PPU_LEAD = 1`, `CGB_HALT_LEAD_SKIP_LYC0`;
  `cgb-acid-hell` and daid `ppu_scanline_bgp` with it.
* The CGB OAM DMA drives the address bus (A12 into WRAM): `OAMDMA_WRAM_A12`,
  the `busypush`/`busypop` rows.
* HBlank DMA bytes land 4 dots late: `HDMA_VISIBLE_DOTS`; the hand-off at the
  fetch grant: `HDMA_GRANT_FETCH_DOTS` (mealybug `dma/*`); a halted CPU's
  blind mode-0 edge: `HDMA_HALT_M0_BLIND`.
* The LY 153 -> 0 snapback's LYC = 0 edge, blind window and read snap:
  `LYC_SETTLE_DOTS`, `LYC_SRC_RELATCH_LEAD`, `LY153_READ_SNAP`; the last
  GBMicrotest rows and daid `ppu_scanline_bgp` (DMG) with it.
* The readable LY edge splits at CGB C/D; `$FF44` on the advance dot reads
  `LY & (LY + 1)`; the mode-0 M-cycle at the end of mode 1 is CGB <= C too:
  `ly_read_edge_late`, `LY_EDGE_AND`, `m1_end_no_mode0`; AGE `ly`,
  `lcd-align-ly`, `stat-mode`.
* The line-144 OAM STAT source is a pulse; CGB D+ hold the LY=LYC
  comparison; the CGB takes an LYC write one M-cycle later: `M2_144_PULSE`,
  `lyc_compare_hold`, `CGB_LYC_WRITE_DEFER`; the wilbertpol `ly_lyc*` cluster.
* A halted OAM DMA drives the OAM bus: `OAMDMA_FREEZE_BUS`; the last mooneye
  row.
* SameSuite APU: `pcm_read_edge_zero` (CGB <= C), `square_freq_backstep_
  halftick` (CGB D/E), the suite scored on CGB E as its README says
  (`docs/samesuite-apu.md`).
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
  Per-test account: `docs/gb-mealybug-sources.md`.
* Most of `scx_during_m3`: `SCX_FINE_BORROW{,_DMG_LEAD}`,
  `SCX_FINE_LATCH_WRAP` (C3 is the rest).
* The DMG's last-pixel window start owed to the next line:
  `DMG_WIN_LAST_PX_CARRY`, `WIN_CARRY_TILE`, `WIN_CARRY_REACT_LINES`
  (C6 is the rest of `window/on_screen`).
* The OAM scan reads LCDC.2 once per object, two dots apart, and the CGB
  takes a second look one M-cycle earlier: `OBJ_SCAN_DOT_ADJ`,
  `CGB_OBJ_SCAN_LEAD`; every `sprites/late_sizechange*`.
* The arriving TAC tap read a cycle early; `EI; HALT` with `IF & IE` arms
  the halt bug: `TAC_SELECT_LEAD_T`, `ime_set_cycle`.
* A TIMA overflow reaches a running CPU one M-cycle before a halted one:
  `TIMER_IRQ_RUN_LEAD`.
* The serial shift clock is a half-rate toggle the SC write reseeds, and a
  CPU access meets it before its own tap edge: `SERIAL_TAP_*`,
  `SERIAL_CPU_SAMPLE_T`.
* The CGB window start is revocable; the DMG revokes for one dot:
  `CGB_WIN_REVOKE_LAG`, `DMG_WIN_EN_REVOKE`.
* The OAM X = 167 object charged for the tail walk twice:
  `OBJ_TAIL_WALK_REFUND`.
* GBMicrotest's verdict-less ROMs and broken expectations, mooneye `utils/`,
  `bootrom_dumper`: skipped by name, in `NotScored`.
* AGE's DMG arms were running on a CGB (the cart header picked the machine):
  `dmg: not arm_cgb` in `build_age_tests`; blargg `oam_bug` needs `--dmg` for
  the same reason.
* `rtc3test-1`/`-3`: the local harness uses the shootout's own frame budget.
* `mooneye/misc/boot_hwio-C@agb`: the AGB boot table.
* The CGB revision axis at runtime (`--cgb-rev`, `GbQuirks`): design in
  `docs/gb-hardware-revisions.md`.
