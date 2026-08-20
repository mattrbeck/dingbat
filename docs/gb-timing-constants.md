# GB timing constants: derivations

Every accuracy knob in `src/dingbat/gb/gb.nim` has a section here, keyed by its
name. The comment at the constant itself says what it *is*; this file says how
its value was arrived at — the ROMs that bracket it, the sweep tables, and the
alternatives that were built and refused.

Read the relevant section before changing a number. Almost every value below is
a two-sided bracket rather than a preference, and most of the refused
alternatives are things that look obviously right until they are measured.

Conventions used throughout:

- **gambatte NNNN** is the whole 5,005-row suite; **runner NNNN** is
  `dingbat_test_runner`'s total. One build per cell unless stated.
- **mealybug px** are matching pixels of 23,040 per frame against the suite's
  own reference captures, DMG and CGB scored separately.
- A **bracket** means two ROMs that differ by one inserted NOP, so the pair pins
  a quantity to one M-cycle.
- "Refused" means built and measured, not argued away.

Related: `docs/gb-failure-triage.md` (what is still failing and why),
`docs/gb-mealybug-sources.md` (how to read an `m3_*` frame as eighteen
measurements), `docs/gb-derivations.md` (the 2026-08 commit-message archive),
`docs/gb_oam_dma_cost.md` (the perf-measurement method and the inline cliff).

---

## `LY_BLIND_SCOPE`

Which LY advances open the LY=LYC comparator's blind window (see
`ly_advance_close` in ppu.nim): -1 none, 0 rendered line boundaries only,
1 also vblank-to-vblank, 2 also the mode 0 -> 1 entry on line 144.
Swept whole-suite: -1 3871, 0 3885, 1 3887 (ships), 2 3899.
2 scores higher but its 12 losses are all `m1` handover rows that depend on
bucket 18 of docs/gb-failure-triage.md (mode-1 STAT source vs the vblank IF
bit); it cannot be scored at line 144 until that settles. Worth +24 then.

## `STAT_IRQ_LEAD`

STAT knobs live here rather than beside their write-ups in ppu.nim because the
GbPpu fields they gate are in the type block below. See ppu.nim for meanings
and the ROMs that bracket each.

## `STAT_LYC_LEAD`

STAT_IRQ_LEAD applied to the LYC source alone (STAT_IRQ_LEAD moves LYC,
mode 0 and mode 1 together, so it cannot answer a per-source question).
Ships at 0 -- two-sided bracket, see ppu.nim and docs/gb-failure-triage.md.

## `STAT_IRQ_SPLIT` / `STAT_DOMAIN_LEAD`

Both drive one early-advancing domain (irq_ly / irq_mode), so they cannot
ask for different leads at once. Either may be 0.

## `STAT_READ_SAMPLE`

Where a CPU STAT read samples the mode bits: dot `cc - STAT_READ_SAMPLE`, so a
read at `cc` sees a mode change on dot X iff `cc - X >= STAT_READ_SAMPLE`.
Bracketed on both sides at each speed; derivation at stat_read_mode.

## `STAT_READ_SAMPLE_DS_ADD`

Double-speed addend, kept separate so the read stays branchless:
`T = SAMPLE + DS_ADD * speed`.

## `STAT_M0_FIELD_TAIL`

Dots the STAT mode FIELD keeps reading 3 after the PPU enters mode 0, on
DMG, on a line with no object fetch. The field only -- the mode-0 STAT
source, HBlank DMA trigger, VRAM/OAM unlock and pixel pipeline all switch on
the PPU's own dot. Spent on `stat_chg_dot`.

Three row groups measure the same 3 -> 0 edge and disagree; what separates
them is the observable and whether the line carries an object:

  interrupt, no objects  m0enable/disable_scx*        edge is RIGHT
  field,     no objects  m2int_scx{2,3,5}_m3stat_1    3-4 dots EARLY
  field,     objects     sprites/*_m3stat_2 (63 rows) edge is RIGHT

So the dots are paid at the FIELD (moving the edge costs m0enable -24) and
absorbed by an object fetch (an unabsorbed lag costs sprites -63).
Measured, not fitted: the m2int_m3stat SCX ladder brackets the length to one
M-cycle per residue, leaving K = 3 or 4; whole-suite sweep makes 3 a strict
local max (2: +30/-3, 3: +46/-6, 4: +57/-27). Worth gambatte 4004 -> 4044,
42 of the gains in `window`, which the derivation never used.

Must be charged at the READ, not the mode change -- see STAT_M0_TAIL_MAX_MC.

## `STAT_M0_FIELD_TAIL_CGB`

STAT_M0_FIELD_TAIL on CGB: zero, both derived and shipping. Bracketed from
above -- at 1 the `m2int_m3stat` `_2` members go red on CGB (4015 vs 4044),
at 2 it reads 3979. The device split is independently predicted by the
`scx_m3_extend` brackets, themselves split by one M-cycle.

## `STAT_M0_TAIL_MAX_MC`

Last M-cycle of its own instruction on which an IO read still sees
STAT_M0_FIELD_TAIL. 0 disables the gate; 2 ships.

The three suites that disagree about the field report do not read it with
the same instruction, and the correlation is exact across them:

  GBMicrotest win*      LDH A,($41)  IO on M3 of 3  no tail  (24 rows)
  gambatte m3stat       LD A,(C)     IO on M2 of 2  tail     (45 rows)
  mooneye-wilbertpol    LD A,(HL)    IO on M2 of 2  tail     (6 rows)

Two-sided on the structural quantity: runner 1 -> 773 (mechanism off),
2 -> 779, 3 -> 755 (where LDH starts seeing it and GBMicrotest goes red).

## `STAT_M0_FIELD_TAIL_ABSORB`

Whether an object fetch absorbs the field tail:
`max(0, tail - object dots on this line)`. false is refused by `sprites` at
every value. Specifically objects, not "whatever lengthened mode 3":
absorbing the whole excess over `172 + SCX and 7` (which counts the window
penalty too) scores 4008 vs 4044 and gives back all 42 `window` rows.

## `STAT_MODE3_LAG`

Dots the STAT mode field keeps reading 2 after the PPU enters mode 3.
Device-independent, must stay 0: `m2int_m2stat*` read STAT expecting mode 3
immediately after that edge and refuse any positive value (+1 / -4).

## `STAT_MODE3_LAG_CGB`

Dots added to STAT_MODE3_LAG on CGB only; meant to be negative (CGB
reporting mode 3 before its own mode-3 dot). REFUSED, ships at 0.

`halt/lycirq_m2stat_2` splits the devices in its filename
(`dmg08_out2_cgb04c_out3`) and goes green at -1, but five rows on the same
device read the same edge and want it where it is (m2int_m2stat_1,
sprites/10spritesPrLine_m2stat_1, ly0/lycint152_m2stat_1,
enable_display/nextstat_1, enable_display/frame{0,1}_m3stat_count_1):
net +3 / -6. Object absorption does not separate them -- both
`m2int_m2stat_1` and `lycirq_m2stat_2` are object-free.

## `STAT_M0_TAIL_ANY`

True when any field tail is set. The object accumulator and the whole
absorption path hang off this, not off STAT_M0_FIELD_TAIL_ABSORB, so a default
build carries neither the field nor the add in the object-fetch path.

## `STAT_MODE_LAG_ANY` / `STAT_NO_HOLD`

`stat_chg_dot` for "no mode change is inside any read's sampling window". A
line is 456 dots and the counter rebases at every wrap, so this can never come
within STAT_READ_SAMPLE of the counter again.

## `GDMA_SETUP_MCYCLES`

Fixed setup cost of a CGB general-purpose VRAM DMA, in M-cycles, on top of the
8 M-cycles per $10 bytes for the blocks themselves (ppu_start_hdma).

Ships at 0 because NO value works -- that is what the knob records.
gambatte's 18 `gdma_cycles_*` rows are nine pairs one NOP apart that bracket
the mode 3 -> 0 edge between their two members; dingbat answers 3 to both
members of all nine. Sweeping (tools/gbdiff/gdma_sweep.sh) leaves some failing
at every setting: 0 -> 9/18, 1 -> 9/18, 2 -> 13/18 (best, and contradictory --
long_scx{2,3,5}_2 still short while 2xshort_ds_1 has gone past its edge),
3 -> 12/18, 4+ -> 9/18. At the best setting the residual tracks SCX, and a
constant cannot depend on SCX, so the missing time is not setup -- it is where
the transfer leaves the PPU relative to the mode 3 -> 0 edge. Needs a model.

## `SERIAL_TAP_DMG`

How long an HBlank DMA block's BYTES take to appear in VRAM after the last one
transfers, in DOTS. Data only: the 8 M-cycles per $10 bytes, the address
counters and the FF55 length readback are all charged where they were. Held
bytes land lazily wherever VRAM can be observed (ppu_land_hdma_if_due).

gambatte's 14 `hdma_start` rows are the only ones that read the transferred
DATA. Each `_1`/`_2` pair differs by one inserted NOP before the `LD A,(HL)`,
so they sample one M-cycle apart and their expected 0/1 bracket the arrival.
`-d:gb_dma_trace` turns the family into seven inequalities that intersect at
K = 36 dots from the block start; a block is 32 dots, so this is 4. Swept
whole-suite (hdma_start rows / gambatte total): 0 -> 7/14 4131, 3 -> 11/14
4135, 4 -> 13/14 4137 (ships), 5 -> 11/14 4135, 8 -> 6/14 4130. Strict
two-sided maximum.

DOTS, not bus M-cycles: the two coincide only at normal speed with a block
starting on an M-cycle boundary. `hdma_start_ds_1` and `hdma_start_scx5_2` are
the rows that separate them -- an M-cycle-counting version scores 4135 and
misses one whichever way it rounds. Same thing `ignore_speed` says in
ppu_copy_hdma_block.

The one row left, `hdma_start_scx5_1`, reads VRAM 4 dots BEFORE the block and
is refused by the mode-3 lock, not answered early: that is the SCX residual on
the mode 3 -> 0 edge (bucket 15, docs/gb-failure-triage.md).

Why the bytes and not the block: delaying the block itself by one M-cycle was
tried and refused -- gambatte 4131 -> 4126, breaking `hdma_late_disable_2`,
`_scx2_2`, `_scx3_2` and sliding the `hdma_late_m3speedchange_*` ladder. Those
rows read FF55/LY/TIMA, so they time the block's bus occupancy and say it
starts where it does today.

The read that sees stale bytes is inside the block's own dots -- the copy ticks
the PPU 8 M-cycles while the triggering CPU access is still in flight, which is
also why that access finds VRAM unlocked. Hence the hold is only taken for a
block the mode-0 edge starts (`in_cpu_cycle`); extending it to FF55-started
blocks costs `hdma_disabled_display_1` and gains nothing.

HDMA_VISIBLE_DOTS is declared further down, next to CGB_HALT_PPU_LEAD, whose
value it carries a term of.
---- Serial shift clock tap offset, per device ------------------------------

The serial unit watches a bit of (divider + tap); its falling edge shifts one
bit. The tap is a phase in T-cycles on a free-running counter -- not a
countdown started by SC -- because the serial unit's divider copy sits a few T
ahead of what a DIV read returns. Raising it makes every edge land earlier.

Two-sided contradiction, quarantined at the DMG value gambatte refuses.
Swept against gambatte's 82-row `serial` bucket with CGB held at 2, the DMG tap
plateaus at 53 rows across [0,3] and drops to 50 outside it -- a strict local
max, 4 T wide, which says the tap is an M-cycle-quantised phase and not a
duration. The CGB column has the same shape and already sits inside it.

But `mooneye/acceptance/serial/boot_sclk_align-dmgABCmgb` pins 4 and is
hardware-verified on DMG/MGB, so it wins: the tap ships at 4 and three gambatte
rows stay red deliberately.

Re-partitioning the tap against the boot divider seed does not reconcile them:
`boot_div-dmgABCmgb` reads DIV (`tdiv shr 8`) so it cannot see a 4 T seed
change at all, and both suites' ROMs start from the same boot state and write
no DIV, so each sees only (seed + tap). The disagreement is in something both
traverse before the SC.7 write.

## `SERIAL_START_ARM` (the residual `start_wait_*` cluster)

---- The residual `start_wait_*` cluster -------------------------------------

Twelve rows (`start_wait_read_if`, `_read_sb`, `_read_sc`,
`start_wait_clear_if_read_if`, and their `_ds` arms) report one defect through
three registers: at family step 1 hardware has done seven shifts and dingbat
eight. `_read_sb` counts them directly (SB seeds $00 and shifts in ones:
`exp=7F,FF got=FF,FF`), and SC.7 and the serial IF flip on the same M-cycle --
so it is the eighth shift EDGE that is early, not the interrupt's visibility.

Two candidates, both refused from opposite sides:
 * Not the tap. These rows do not move by a single verdict at any tap in
   [-8, +8], while `div_write_start_wait_read_if` next door flips cleanly at 0.
   So the error exceeds 8 T and the clock's phase cannot reach it.
 * Not a whole missed period. SERIAL_START_ARM spends the first falling edge
   after SC.7 rises on arming (+512 T): step 1 lands on all six families and
   step 2 goes out on all six -- the error changes sign. Whole suite +24 / -32.

The quantity is strictly between 8 T and one bit period, which no edge-phase
constant expresses (a tap moves the start sample with the edges, leaving the
edge count invariant). The next instrument must move the START against a
stationary clock -- when SC.7's write commits relative to the divider -- which
is a bus question, not a serial one.

## `CGB_HALT_EXIT_MCYCLES`

---- The M-cycle a CGB spends leaving HALT that a DMG does not ---------------

CGB_HALT_EXIT_MCYCLES charges it as TIME; CGB_HALT_PPU_LEAD below spends it as
PHASE. The phase is the one that ships -- see there. This charge stays at 0.

What asks for the M-cycle: ten `halt/` ROMs name a different expected value per
device in their filename, each a read a fixed number of M-cycles after an
interrupt ended a halt (m0{int,irq}_m0stat_scx{3,4}_2, late_m0*_halt_*,
lycirq_m2stat_2, m1int_ly_2). All ten say the CGB read lands later in the PPU's
line, across three unrelated boundaries. At 1 all ten flip green plus 11 more.

What refuses the CHARGE: 42 `tima/*` rows, all with one expected value for both
devices. An extra M-cycle at the exit is extra time, so DIV and TIMA advance
through it; hardware says they do not. Net -37 gambatte. Whatever the CGB does
here, it is not spending time -- which is what makes it a phase.

A further 11 rows are the same family at a different SCX, where SCX 3/4 want
the M-cycle and SCX 2/5 refuse it. A halt cost cannot depend on SCX, so part of
what those ten measure is the CGB's mode 3 length against SCX (bucket
`scx_during_m3`), not this.

## `CGB_HALT_LEAD_LYC_ONLY`

EXPERIMENT. Restrict CGB_HALT_PPU_LEAD to halts where the LYC comparator is
the only armed STAT source. 0 ships; see the test it gates in cpu.nim.

## `CGB_HALT_LEAD_SKIP_LYC0`

Whether a halt woken by the LY 153 -> 0 snapback's `LYC = 0` match is exempt
from CGB_HALT_PPU_LEAD. 1 ships; 0 is the control (lead on every wake).
Derived by a LYC sweep of daid's `ppu_scanline_bgp` against SameBoy -- same
ROM and entry, only the wake line changing. See the test in cpu.nim.

## `CGB_HALT_PPU_LEAD`

While a CGB CPU is halted the PPU runs one M-cycle of dots behind the rest
of the machine, and gets them back on the way out. The first halted M-cycle
ticks the bus half only (scheduler, timer, serial, OAM DMA); the wake ticks
those dots into the PPU with no bus half (cpu_halt_tick and `tick` in
cpu.nim). Nothing is created or destroyed -- a k-M-cycle halt still gives the
PPU k M-cycles of dots. `halt_ppu_debt` is the memo, reconstructed on state
load rather than serialized (savestate.nim) since it is constant per halt.

Phase, not charge, because the 42 `tima/*` rows pick: both models put the
post-wake read one M-cycle later in the PPU's line, but a charge also
advances TIMA and a phase does not. See CGB_HALT_EXIT_MCYCLES.

---- Exactly one M-cycle, bracketed from both sides -----------------------

Two `halt/` families of three ROMs each, differing only by one NOP before
the read:

  lycirq_m2stat   _1 out 2     _2 dmg 2 / cgb 3     _3 out 3
  m1int_ly        _1 out $90   _2 dmg $90 / cgb $91 _3 out $91

At 0 the `_2` members answer the DMG value on CGB; at 1 both flip green with
`_1`/`_3` still green; at 2 the `_1` members go red -- under phase and charge
alike, so the bracket belongs to the quantity. Neither family carries SCX.
`lycirq_*` is the IME-clear path, `m1int_*` the IME-set one, so it is on
both.

Independent confirmation from a family that shares no ROM, register or edge:
gambatte's `speedchange*_ly44_m3_*` ladder, in which nothing halts, derives
the KEY1 switch's PPU re-alignment alone (8 dots into double, 3 back into
single, 55/55 rows). daid's `speed_switch_timing` pair does halt once each
and pins halt-lead + switch-extra at 12. 12 - 8 = 4 dots = this constant.

---- 2026-08-18: on, with the snapback exempt -----------------------------

Turning it on flat takes `cgb-acid-hell` to 0 px but `daid/ppu_scanline_bgp`
(GBC) from 0 to 2304 px at every CGB revision -- a shootout row this tree
did not gate. It is wired now (`daid/ppu_scanline_bgp-gbc`).

The ROMs are not in conflict. daid's is one STAT LYC interrupt out of `halt`
followed by a scanline-locked 114-M BGP loop. Rebuilt byte-exact and swept
over the LYC value alone -- same ROM, entry, IME and vector, only the wake
line changing -- against SameBoy (which reproduces daid's reference
pixel-exactly):

  LYC = 0 (the LY 153 -> 0 snapback)  exact WITHOUT the lead, 2304 px with
  LYC = 1, 8, 40, 100 (normal lines)  exact WITH the lead, 1920-2304 without

So the M-cycle is real on every normal-line wake and absent on the snapback;
acid-hell's disputed pixels are on lines 68-69, normal lines. Hence
CGB_HALT_LEAD_SKIP_LYC0. Sweep: tools/gbppu/daidsweep.py.

Refuted on the way, so nobody re-runs them: not IME or whether a vector is
taken (the LYC sweep holds both constant), and not LY0_PIPE_MCYCLES (0/2/3
against the lead leaves daid at 2304).

Ledger: runner 885 -> 887, gambatte 4201 -> 4246; cgb-acid-hell, both
`strikethrough` frames and both daid frames all 23040/23040. All 260
shootout ROMs were rendered under both builds in both device modes and only
cgb-acid-hell moves. Shootout: 261 scored, 261 PASS. Still red and
unexplained: gambatte `dma` -7, `lcd_offset` -6, `window` -1, against +54.

`strikethrough` was the long-standing objection and is resolved rather than
overridden: that frame witnesses the SUM of the pipeline advance and the
object fetch's lead over the OAM DMA bus, not the advance alone. The advance
is summed into OBJ_DMA_BUS_LEAD (fifo_ppu.nim), CGB-only, exactly as
CGB_PIPE_MCYCLES already was, and both frames are byte-identical across the
change.

---- Cost -----------------------------------------------------------------

The `cpu_halt_tick` block no longer compiles out, so every HALT-idling title
pays it -- DMG ones pay the `cgb_enabled` test and nothing else. Retired
instructions, min of 3, on `cgb-acid-hell` (144 halts/frame, near worst
case): 6.0804 G -> 6.1610 G, +1.33%. Real titles are smaller (+0.44% Pokemon
Blue, +0.56..0.77% Crystal). To pay it back, decide at halt ENTRY rather than
per halted M-cycle -- the debt field is already the per-halt latch.

## `CGB_OAM_DMA_START_T`

T-cycles between the FF46 write and the OAM DMA unit taking the bus, on CGB.
8 is what both devices ship with (mem_dma_tick). The knob exists only
because `strikethrough` at a nonzero CGB_HALT_PPU_LEAD wanted 4 T taken out
of here; that is on record as refused. See docs/gb-failure-triage.md.

## `GB_POWERUP_WRAM_PATTERN`

Fill WRAM with a fixed pseudo-random pattern at power-up instead of zeroes.
Pan Docs (Power_Up_Sequence) says WRAM/HRAM are random on power-up and names
a constant fill as an emulator shortcut. BullyGB's InitRAMTest catches that
shortcut and is the FIRST of its nine tests, so the other eight had never
run here; with this on, bully prints "All tests OK!" and is pixel-exact.

Measured on a GBA SP (flashcart-kit/9, `wramscan.gb`, booted direct so the
cart menu could not overwrite): 369 bytes $00, 221 $FF, 7602 neither, of
8192. Not uniform noise either (uniform would give ~32 each), so this is an
honest approximation, not a claim about silicon.

Cost: gambatte `oamdma` 771 -> 766. All five are `oamdma_src{FE,FF}00_*` and
all five stop producing a verdict rather than a wrong one, because a DMA
source >= $E000 fetches through the echo, so $FE00/$FF00 read $DE00/$DF00.
Proven: randomising all WRAM EXCEPT $DE00-$DFFF restores gambatte to 4274
and oamdma to 771, bully still passing. Those rows read uninitialised WRAM
and encode whatever the capture rig left there; zeroing just those two pages
would buy all five back and is deliberately NOT done -- it fits gambatte's
rig, and the AGS scan puts its zero run near $D600.

Net: runner 1015 -> 1016 with zero runner rows lost, gambatte 4274 -> 4269.

Fixed xorshift, never a seeded RNG: byte-identical screenshot gates,
save-state round-trips and rollback netplay all need two runs of the same
ROM to start from the same bytes.

`wrambands.gb` on two machines (2026-08-20): set bits per 256-byte block,
of 2048, excluding the loader region -- AGB 1007.6 (49.2%), MGB 1089.2
(53.2%); byte counts 369/221 on AGB against 834/333 on MGB. There is NO
256-byte banding on either machine, so the alternating-band shapes some
emulators model are not what these consoles do. Uniform is a good AGB model
and slightly under-biased for MGB; deliberately not chasing the 4%, since no
row distinguishes them and one console is not a population. Recorded in
docs/flashcart-runbook.md.

## `HDMA_STEAL_DELAY_M`

CPU instruction boundaries an HBlank DMA block waits after the mode-0 edge
before taking the bus. 0 = on the edge itself, which dingbat always did.

mealybug `dma/hdma_timing-C` says the edge is too early. Its `sub_test`
macro arms a one-block transfer then reads a register after N nops, one run
per N. At SCX=1 hardware answers `00 ff ff ff` for nops 46-49, and $00 is
"armed, zero blocks left, NOT YET TRANSFERRED", while the STAT samples put
the mode-0 edge between nops 44 and 45 -- so the block starts about two
M-cycles after the edge with the CPU stalled through it. At SCX=2 the longer
mode 3 moves the edge one M-cycle later and the answer becomes `00 00 ff ff`.

Paid at INSTRUCTION boundaries, not on a dot counter: a per-dot deadline
measured +1.36% retired instructions and was declined; this is one
not-taken branch per instruction and measures free.

Paid BEFORE handle_interrupts, and that ordering matters as much as the
delay -- the DMA takes the bus ahead of the dispatch. Paying at the top of
the next instruction instead is the same instant on the wrong side of the
dispatch and costs the whole gambatte `irq_precedence` hdma_vs_m0 /
late_hdma_vs_{ei,ie} family; paying before it gains three of those rows.

  HDMA_STEAL_DELAY_M      0      1 (ship)   2      3      4
  hdma_timing-C wrong    8/48    2/48     4/48   8/48  10/48

Whole suite: gambatte 4263 -> 4274, dma 126 -> 134, irq_precedence 44 -> 47,
zero rows lost. The `dma` gain is the entire `hdma_late_disable` family --
the set HDMA_VISIBLE_DOTS was swept over and could not recover at any value.

## `HDMA_BLOCK_OVERHEAD_BUS`

CPU-clock cycles an HBlank DMA block costs beyond its sixteen byte copies:
the bus acquire/release either side. NOT the per-byte cost -- two dots per
byte at either speed is pinned by gambatte `hdma_start_ds_*` and agrees with
SameBoy's GB_hdma_run.

Unscaled, and that is the measured part. The copies are `2 shl
current_speed` because they are PPU dots; this is not. Shipped first as a
single `2 shl speed` term, that made the double-speed DIV-duration group
exact while leaving the single-speed one 4 wrong. A flat 4 makes both exact:

  unscaled bus cycles     2      4 (ship)    6      8
  hdma_timing-C wrong   16/48    8/48     12/48  16/48

(Dots swept separately at bus=4: 0 -> 12, 2 -> 8, 4 -> 10. Charging before
the copies instead of after scores identically, so the instrument does not
distinguish acquire from release -- do not read the placement as evidence.)

## `HDMA_BLOCK_OVERHEAD_DOTS`

PPU dots for the same overhead; separate from the bus term because they are
separate clocks. See HDMA_BLOCK_OVERHEAD_BUS for the sweep.

hdma_timing-C: 20/48 wrong -> 12 -> 8, and 6 more fixed by HDMA_STEAL_DELAY_M.
Both DIV-duration groups and the mode-2 entry after the block are exact.
SameBoy scores 2/48; so do we. The 2 remaining cells point OPPOSITE ways,
which is why no scalar closes them: SCX=1 single speed wants the block ~1 M
EARLIER, SCX=2 double speed wants it LATER.

A dot-granular delay was tried 2026-08-20 and does NOT help -- do not
re-derive it. The reasoning was sound (an instruction boundary is 4 dots at
single speed and 2 at double, exactly the asymmetry above, so a fixed dot
delay between them should satisfy both), but implemented as an `etHdmaSteal`
scheduler event at the mode-0 edge it plateaus at 2/48 across dots 5-8 --
what the boundary path already achieves with no new machinery -- and is
worse everywhere else (1-4 -> 6, 10 -> 4, 16 -> 8, 32 -> 10). The predicted
3 dots is 6/48. At 5 dots both survivors are too EARLY in the SAME
direction, and more delay makes it monotonically worse, so the residual is
not a placement question at any granularity. Reverted rather than shipped.

## `HDMA_VISIBLE_DOTS`

Dots an HBlank DMA block's bytes take to become visible in VRAM.

The `4 * CGB_HALT_PPU_LEAD` term is the argument OBJ_DMA_BUS_LEAD makes for
the OAM DMA unit: the DMA engine runs on machine time and this window is
measured against the pipeline, so advancing the pipeline moves the window.
Declared here rather than with the other memory timings because it reads a
const defined above.

Whole gambatte suite with the lead on: `dma` is 116/229 at 4, 121 at 8,
116 at 12 -- a local max bracketed on both sides, and 8 is 4 plus the
advance. Partial account only: seven `hdma_late_disable_*` rows stay red and
this term does not explain them.

## `CGB_HALT_PPU_LEAD_DOTS`

The same lag in DOTS, which is the unit the code reads. CGB_HALT_PPU_LEAD
sets it in whole M-cycles, so `=1` means 4 dots; setting THIS directly is
what reaches the three values between them.

Sub-M-cycle values are not a finer knob on the same thing: the halt exit is
sampled on the M-cycle grid (`cpu_halt_tick`), so a lag of 1-3 dots moves
the wake by a WHOLE M-cycle for a source whose rise dot is within `DOTS` of
the next boundary, and by nothing for every other source. One quantity, a
per-source answer. Sweep: docs/gb-failure-triage.md (2026-08-10).

## CGB per-register PPU write latency

`CGB_WX_LATENCY` / `CGB_WY_LATENCY` / `CGB_SCY_LATENCY` / `CGB_SCX_LATENCY` /
`CGB_LCDC_LATENCY` / `CGB_LCDC_TDSEL_LATENCY` / `CGB_OBJ_SIZE_LATENCY`

---- CGB per-register PPU write latency -------------------------------------

Dots into its own M-cycle that a CPU write to a pipeline register lands on CGB,
over and above where DMG puts it. Here rather than beside their write-up in
memory.nim only because the GbMemory fields they gate are in the type block
below; mechanism and sources are at mem_tick_ppu_latched.

DMG is the zero of this scale, not the origin: dingbat commits a write's byte
at the top of its M-cycle and every DMG family that brackets one of these
agrees, so what is modelled is the CGB *delta* alone -- invariant to whatever
constant offset dingbat's dot grid carries against anyone else's.

SCY and SCX ship at the documented 2; the other five ship at 0 because every
nonzero value is refused by some family. The CGB PPU really does take these
writes late (mealybug's PPU document states 2 T-cycles for SCY, and Pan Docs'
"Mid-frame behavior" carries the same split), but only the scroll pair has an
instrument here that agrees.

Swept alone against two instruments, one build per cell (cgbsweep.sh forces the
other six to 0). Baselines: gambatte 3567/5005, mealybug CGB 1794023 px.
Every moved row is a `[cgb]` row; the DMG side never moves, as it must not.

  setting                    gambatte   mealybug CGB   what moved
  all 0 (control)              3567        1794023     row for row main
  CGB_SCY_LATENCY=1            3566        1803344     scy -1
  CGB_SCY_LATENCY=2            3566        1795140     scy -1
  CGB_SCY_LATENCY=3            3566        1791068     scy -1
  CGB_SCX_LATENCY=1            3567        1793878     nothing
  CGB_SCX_LATENCY=2            3566        1792812     scx_during_m3 -1
  CGB_WX_LATENCY=1 / =2        3566        1794023     window -1
  CGB_WY_LATENCY / WY_LATCH    3567        1794023     nothing at all
  CGB_LCDC_LATENCY=1           3564        1792077     window -3
  CGB_LCDC_LATENCY=2           3563        1789728     window -4
  CGB_LCDC_TDSEL_LATENCY=1     3563        1789555     window -3, bgtiledata -1
  CGB_LCDC_TDSEL_LATENCY=2     3562        1784962     window -4, bgtiledata -1

The shortfall is not systematic -- SCY is the only register whose instruments
move at all -- so there is no reason to look for a global absorber (such as a
late mode 3 start) first. Whatever ate the SCY dot had to be visible to SCY's
own ROMs and on DMG too, and it was: see the SCY note below.

SCROLL is two constants because Pan Docs documents the two registers
differently ("Mid-frame behavior" gives SCY a per-model sample point; the SCX
split -- high 5 bits per tile fetch, low 3 latched at line start -- carries no
model qualifier), and the split shows up here.

Per register:
 * SCY. The documented 2 is right; the whole-frame score's earlier preference
   for 1 was an artefact of the OBJ fetch phase, not of this constant.
   m3_scy_change is eighteen measurements, not one: its OAM table is
   `Y = 16 + 8k, X = k`, so each 8-line band carries one object whose X advances
   down the screen, and that object is the RULER -- the OBJ penalty sets the
   phase between the ROM's write burst and the fetcher's three SCY reads.
   Scored per band, the bands with NO object wait term were pixel-exact at 2
   and wrong at 1, while the bands WITH a wait term collapsed at 2 -- and those
   were exactly the bands whose DMG reference was already wrong with no CGB
   constant involved. So the missing dot was the BG fetcher's phase across an
   OBJ fetch: device-independent, a function of the object's X, and the very
   thing this ROM measures with. Fixed 2026-08-03 (tick_sprite_fetcher in
   fifo_ppu.nim), after which the prediction held -- every band comes up, the
   whole ROM goes 82.0% -> 97.7%, the CGB suite 1794023 -> 1812603, and
   gambatte no longer moves between 0 and 2. 1 and 3 are both worse on mealybug
   CGB (1802113 and 1809324 against 1814216).
   One refusal stands and is unrelated: gambatte loses
   scy/scy_during_m3_spx08_ds_4 at any nonzero value. At 2 dots per M-cycle a
   1-dot latency lands on the cap boundary, so that row is reading the CGB
   CPU-to-PPU phase axis through a register latency -- the confusion
   CGB_LATENCY_CAP exists to prevent and cannot at this width.
 * SCX. Also 2, for the same reason: the row that used to refuse it was reading
   the OBJ fetch phase. The clean DMG-neutral per-device row a scroll latency
   fixes is enable_display/ly0_late_scx7_m3stat_scx0_274 (DMG expects $87, CGB
   $84); at 2 dots both are right. On the fixed fetcher the mealybug m3_scx_*
   rows come back monotonically -- m3_scx_high_5_bits 99.5 / 99.7 / 100.0% and
   _change2 99.7 / 99.8 / 100.0% at 0 / 1 / 2 -- while gambatte adds
   scx_during_m3/scx_0060c0 and _0063c0 `_3` on the CGB side (30 -> 32).
   Three instruments, one value, and it is the documented one. The `_scx1` rows
   are still red on both devices; that residual is elsewhere.
 * LCDC (whole register). Four of its bits now carry their own per-reader delay
   instead -- CGB_OBJ_SIZE_LATENCY (bit 2), CGB_TDSEL_LATENCY (bit 4),
   CGB_MAP_LATENCY (bits 3 and 6) -- each derived on a family the whole-register
   form cannot separate. CGB_MAP_LATENCY takes gambatte `bgtilemap` 28/40 ->
   40/40, a family this table never moved at any setting, so they measure
   different things.
   Every window row the whole-register form costs is a late_disable /
   late_reenable row -- the family SameBoy gives a CGB-only fetcher-abort path
   (a window disable part way through the fetch aborts it), which moves them the
   other way. The +2 dots is not separable from the abort here, and adding it
   alone is strictly worse. Implement the abort first, then re-run.
   Re-measured 2026-08-03: CGB_LCDC_LATENCY=1 scores 3616, +3 / -5, and the
   latency shifts the whole late_disable family by one step rather than moving
   where inside it the answer flips -- the signature of a missing mechanism,
   not a wrong constant. Ceiling if the abort lands is ~10 gambatte plus 2
   mealybug rows, and those two are wrong on BOTH devices, so a CGB-only abort
   will not collect all of it.
 * WX / WY / the WY latch. The split is in the ROMs' OWN EXPECTED VALUES, not
   in a latch dot. Of the 14 late_wy families scored on both devices, 13 expect
   different values per device, every one the same one-M-cycle shift in the
   same direction (late_wy_FFto2_ly2 dmg 3,3,0 / cgb 3,0,0; late_wy_1toFF dmg
   0,0,3 / cgb 0,3,3; and 11 more). dingbat answers the same value on both
   devices in 11 of the 14 -- it models no device difference at all, which is
   the defect, worth ~26 rows.
   Note the SIGN before reaching for a latency: the CGB expectation flips one
   step EARLIER, so CGB samples WY sooner, not later. Every constant here is a
   positive delay, which moves CGB the wrong way -- that, not a missing
   instrument, is why WY shows "nothing at all" in the table. The mechanism is
   probably not a write latency at all.

### Per register

Dots LCDC.2 takes to reach the OBJECT FETCH on CGB over DMG -- the same
shape as CGB_MIXER_LATENCY, for the one bit of LCDC an object fetch reads.
Separate from CGB_LCDC_LATENCY because that moves the whole register for
every reader and every nonzero setting costs gambatte rows.

Derived and swept at OBJ_PLANE1_LAG in fifo_ppu.nim: the two
`m3_lcdc_obj_size_change` ROMs disagree between their DMG and CGB references
on which bands come out mixed, by a clean three dots in the same direction
on all six bands that separate them.

## `CGB_OBJ_SCAN_LEAD`

Dots before its own sample dot that a CGB's OAM SCAN takes a second look at
LCDC.2, keeping the object if either look puts it on the line. A different
reader from CGB_OBJ_SIZE_LATENCY (that is the mode-3 object fetch, this is
the mode-2 range comparator), measured by a different family. Derived at
fifo_get_sprites off gambatte `sprites/late_sizechange*`, where objects 1, 9
and 39 each have a CGB cell that comes out 8x16 whichever way the write moved
the bit -- which no single sample dot can produce.

Its sign agrees with CGB_OBJ_SIZE_LATENCY: the bit reaches the object logic
later on CGB than on DMG.

## `CGB_MAP_LATENCY`

Dots LCDC.3 / LCDC.6 (the tile MAP select bits) take to reach the background
fetcher's MAP ADDRESS read on CGB over DMG. Fourth member of the per-reader
family, not the whole-register CGB_LCDC_LATENCY.

Derived, not fitted, from the four mealybug `*map_change*` rows, with the DMG
side pinning the phase so the whole delta is the console.
`m3_lcdc_{bg,win}_map_change` are 23040/23040 against `_dmg_blob` and were
384 and 182 px out against `_cgb_c` at every revision alike (the `_cgb_c` and
`_cgb_d` captures are byte-identical, so this is not a revision axis).

Both ROMs invert completely: map $9800 is all tile 0 (all-$00), $9C00 all
tile 1 (all-$FF), BGP identity, SCX 0 -- so every 8-pixel tile column is one
bit, which map the fetcher's B-stage read used, and the handler raises that
bit for exactly 8 dots. Eighteen objects at `Y = $10 + 8k, X = k` sweep the
pulse across the fetch grid one dot per band (docs/gb-mealybug-sources.md
1.3), so one frame is eighteen readings. Reading the black column per band:

  m3_lcdc_bg_map_change     DMG blob            CGB C and D
    tile 1 black            X = 0, 1, 2         X = 0
    tile 2 black            X = 3 .. 7          X = 1 .. 7
    nothing black           X = 8, 9, 10        X = 8
    tile 2 black            X = 11 .. 15        X = 9 .. 15

  m3_lcdc_win_map_change    DMG blob            CGB C and D
    tile 0 black            X = 0, 1, 2         X = 0
    tile 1 black            X = 1 .. 7          X = 0 .. 7

Four independent edges, all four moving the same two bands in the same
direction. A band is a dot, so the pulse arrives at the map read two dots
later on CGB. (The `win_map` tile-1 entry edge reads as one band only because
X cannot go below 0.) dingbat previously answered the DMG schedule on both
consoles -- exactly the four bands that were wrong.

Two dots is also the magnitude mealybug's PPU document gives for the one CGB
write latency it states outright (SCY, shipping next door as
CGB_SCY_LATENCY = 2). Bracketed on both instruments rather than assumed:

  CGB_MAP_LATENCY        0      1      2 (ship)    3
  gambatte bgtilemap    28/40  32/40   40/40     32/40
  mealybug CGB pixels  1863574 1865000 1866240  1864988  (of 1866240)
  gambatte total        4246   4250    4258      4250   (of 5005)
  runner Pass            919    919     924       916   (of 1106)

One unique maximum with symmetric fall-off; at 3 it is worse than turning the
rule off entirely. gambatte's `bgtilemap` is 40 rows of exactly this write and
was not consulted while the value was derived; all twelve of its gains are
`[cgb]` rows. At 2 the whole 27-row mealybug CGB set and 24-row DMG set are
pixel-exact at `--cgb-rev=` C, D and E against both captures.

Re-measuring is a trap worth naming: dingbat_test_runner SHELLS OUT to
./dingbat_test, so `-d:CGB_MAP_LATENCY=N` has to go into THAT binary.
Rebuilding only the runner scores every arm identically, control included.

The latency is CPU-clock, proven by the double-speed rows rather than
assumed. Spent at the write (ppu_store_lcdc) as
`max(0, CGB_MAP_LATENCY - current_speed)`, so a double-speed M-cycle spends
the delay inside itself. Without the speed term `bgtilemap` drops to 36/40
and all four losses are `_ds_` rows. Same shape as CGB_TDSEL_LATENCY.

Confined to the map-address read because that is the only reader the
instrument sees; LCDC.3/.6 have no other consumer in the fetcher, and gating
here rather than in the register keeps the whole-register `late_disable`
question untouched.

Cost: +0.20% of retired instructions, and it is the one compare in
`fsGetTile`, not the fields (the control arm still carries `map_dot` and
`map_old`, so none of it is layout). DMG pays it too -- the compare is gated
at compile time, and a runtime `ppu.cgb` test is one more load off the same
cache line. Buys 4 mealybug and 12 gambatte rows.

## `CGB_TDSEL_LATENCY`

Dots LCDC.4 takes to reach the BACKGROUND FETCHER on CGB over DMG -- the one
bit of LCDC a background bitplane read consults. Separate from
CGB_LCDC_TDSEL_LATENCY, which is a WRITE latency and drags the other six bits
with it (the `run` chain in mem_apply_pipeline is monotonic); every nonzero
setting of that costs three gambatte `window` rows.

The DMG is exactly right, so this is a real CGB delta and not an absorbed
phase error: `m3_lcdc_tile_sel_change` and `_win_change` are 23040/23040
against `_dmg_blob`, each eighteen independent measurements of this
register's write dot against the fetch cycle.

Derived off `m3_lcdc_tile_sel_change2`'s CGB reference, which reads out the
bytes: background `ABCDEFGH...` on map rows 0..7 with LCDC.4 = 0, only $9490
initialised, so every 8 aligned pixels invert through BGP = $E4 into one
(plane 0, plane 1) pair naming the tile and plane hardware read. Reading
column 2 per band, fetch reads at p0 and p0 + 2:

  band   hardware              dingbat at latency 0
  0..2   C.0 / C.1             C.0 / C.1        write at or before p0
  3      <glitch> / C.1        C.0 / C.1        write ON p0 (hardware)
  4      $00 / C.1             C.0 / C.1        write at p0 + 1
  5      $00 / <glitch>        $00 / C.1        write ON p1 (hardware)
  6      $00 / $00             $00 / C.1
  7      $00 / $00             $00 / $00

The bands step the write one dot each, and hardware's write reaches the
fetcher one band later than dingbat's throughout. One dot, bracketed both
sides, on a row whose DMG twin is pixel-exact.

Independently: it is the only value that puts `cgb-acid-hell`'s anomaly on
the plane it is observed on -- that ROM writes LCDC every 8 dots at 8n+1 with
bitplane reads at 8n+0 and 8n+2, so 0 puts the change between the reads, -1
on the low plane, and only +1 on the high one.

The one quantity CGB_PIPE_MCYCLES does not resolve: advancing the CGB
pipeline one M-cycle moves this write four dots around the 8-dot fetch
lattice, so the compensated value would be 5. It is not takeable, because
the two witnesses do not share an anchor -- the four mealybug `tile_sel`
frames sync on mode 2, which moves with the pipeline, so they still want 1;
`cgb-acid-hell` syncs on LYC, which does not move, so it wants 5. A strict
two-sided bracket, measured world against world with no reference image in
the loop:

  value   mealybug tile_sel CGB (4 frames)      cgb-acid-hell
  1 ship  byte-identical to the pre-advance     23038/23040
  5       3859 wrong px (1468 + 1525 + 866)     byte-identical

1 ships because it costs 2 pixels and 5 costs 3859. The four mealybug frames
score identically before and after the advance, so the cell alignment did not
move. The residue is the phase moving acid-hell's write off the read dot;
CGB_TDSEL_IDX_DOTS carries the read-level bracket showing no refinement
recovers it without costing 64 mealybug reads.

Note `cgb-acid-hell`'s reference is a C/E-class capture (exact at
`--cgb-rev=C` and `=E`, 22864/23040 at `=D` pre-advance), where daid's
`.gbc.png` is D-class. Two ROMs, two machines.

## `CGB_TDSEL_GLITCH`

Whether an LCDC.4 change landing ON a background bitplane read glitches it,
and with what. mealybug's PPU notes describe the effect; what the
`m3_lcdc_tile_sel_change2` decode adds is which branch fires when, because
that frame names the byte. Glitched cells of the six affected columns
(`IDX` = tile index, `X.p` = tile X's plane p):

  band   col2 SET   col3 RST   col5 SET   col6 RST   col8 SET   col9 RST
  3      '3'.1      IDX        D.0        IDX        G.0        IDX
  5      '5'.1      IDX        D.1        IDX        G.1        IDX

Two rules, neither with a free parameter:

 * a RESET on the read dot delivers the TILE INDEX as that bitplane's byte
   (columns 3, 6, 9 hold $44, $47, $4A constant down the band, which no
   tile-data read can be). This is the notes' wording verbatim.
 * a SET on the read dot delivers the byte at the address of the most recent
   $8000-REGION tile-data read. The object fetch's last read is its bitplane
   1, which is why the first glitch of a line reports the object's plane 1 at
   EITHER plane; after that the RESET-glitched read has driven its own
   address, which is why col 5 reports `D` and col 8 reports `G`, each at the
   glitch's plane. The notes list both as alternatives without saying which
   fires; an address latch is the one mechanism producing both.

What writes the latch and when it clears: `*_change2` cannot see either
question (every SET glitch there is preceded on its line by an object fetch
or a RESET-glitched read). The plain `m3_lcdc_tile_sel_change` and
`_win_change` on CGB can, and were this pair's whole residual (232 and 1422
wrong subpixels; both 23040/23040 now). Scoring the four CGB references'
glitched reads by the byte each pins:

  latch written by                     cleared per line   SET cells right
  obj + RESET-glitched reads           yes                 133 / 161
  + every unglitched LCDC.4 = 1 read   yes                 133 / 161
  obj + RESET-glitched reads           no                  158 / 161
  + every unglitched LCDC.4 = 1 read   no                  159 / 161

Both arms are forced by a whole band, not a cell: the latch is a bus register
that H-Blank does NOT clear (`m3_lcdc_tile_sel_change` writes LCDC at dot 105
with its object at 112, so its first glitched read per line precedes anything
driving an $8000 address, and hardware still substitutes -- with the byte the
line above left), and an unglitched LCDC.4 = 1 read leaves its address here
too (the last 8 pixels of `_win_change`).

A plain DATA latch (last byte rather than last address) is refuted by a whole
band: 89/161, because `*_change2`'s two bands glitch on different PLANES and
hardware answers with the same tile at the glitch's plane. Only an address
does that -- worth knowing, since a data latch is cheaper and is what the
notes' wording suggests.

`cgb-acid-hell`'s two pixels are the one exception: CGB_TDSEL_IDX_DOTS below.

## `CGB_TDSEL_IDX_DOTS`

How long a RESET glitch leaves the INDEX path armed, in dots. A SET glitch
inside that window delivers the CURRENT tile's index instead of the address
latch. 0 is the control build, where a SET is always the latch.

---- What the corpus proves ----------------------------------------------

Scored over every glitched bitplane read of the four CGB `tile_sel`
references plus `cgb-acid-hell` whose bits the reference PNG pins (192 RESET
/ 223 SET cells, 2026-08-12). Cells, not pixels:

  SET-branch trigger for "deliver the index"        SET cells right
  never (the address-latch rule alone)                 221 / 223
  always                                               125 / 223
  the latch was written by a RESET glitch, any age     158 / 223
  the IMMEDIATELY preceding read was RESET-glitched    221 / 223
  the latch is <= 8 dots old, whatever wrote it        215 / 223
  a RESET glitch landed <= 8 dots ago                  223 / 223
  ...and it wrote the latch, i.e. nothing since  <--   223 / 223

Both halves of the trigger are forced by a whole band: not recency alone
(`*_change2`'s first glitch per line has an object fetch 8 dots behind it and
wants the LATCH -- 8 cells), not provenance alone (its columns 5 and 8 have
latches written by the RESET glitch two tile columns back and want the LATCH
-- 64 cells), and not "the immediately preceding read" (acid-hell's RESET
glitch is the previous FETCH's read of the same plane, with an unglitched
signed read between; that spelling misses the two pixels it was written for).

Bracketed to 8..15 dots and no narrower: 7 loses acid-hell (its RESET glitch
is exactly 8 dots back), 16 breaks `*_change2`'s 64 (theirs is exactly 16).
8 is the fetch cycle's own pitch, so the rule reads "the RESET glitch was in
this fetch or the one before it". In dots, not reads: the two agree wherever
the fetcher runs at pitch, and dots need no counter.

The shipping row is the last one because the PACKING gives it free -- the
arming rides `tdsel_addr` above the bank (TDSEL_IDX_SHIFT), so anything
writing the latch disarms it. No cell separates it from the looser row.

---- What the corpus does NOT prove --------------------------------------

The distinguishing bucket is populated by ONE ROM. At every setting in 8..15
the trigger fires on exactly seven cells, all `cgb-acid-hell`'s, changing no
other pixel in the tree. Five of the seven have index and latch holding the
same byte, so the arbitrating evidence is two pixels -- `(80, 68)` and
`(80, 69)`, hardware-photo-verified against `img/photo.jpg`.

The settling experiment does not exist: it needs a hardware capture of
`*_change2` with its LCDC writes on an 8-dot lattice, or any second ROM
putting a SET glitch one fetch behind a RESET one. `*_change2` are the only
ROMs with the readout and their handler writes on a 16-dot pitch.

The corpus does not arbitrate against the one alternative either: one M-cycle
of CGB halt phase. At `CGB_HALT_PPU_LEAD=2` this ROM's glitching write becomes
the RESET one 8 dots earlier, the seven cells move to the RESET column, and
`CGB_TDSEL_IDX_DOTS=0` scores 216/216 SET and 199/199 RESET with acid-hell at
23040 -- strictly simpler. The shipping rule rests on the halt bracket, not
the corpus: `halt/lycirq_m2stat_{1,2}` and `halt/m1int_ly_{1,2}` are green
together only at LEAD 0 or 1, and `lycirq_*` is this ROM's own IME-clear path.
The CelestialAmber disassembly reads the ROM the other way and says the reset
rule is the whole trick; its own dot arithmetic lands on the SET once the
6-dot object delay it documents is applied. Both sides:
docs/gb-failure-triage.md (2026-08-13) -- read it before changing anything.

---- The shipping world: this constant has no live evidence in it ---------

`CGB_PIPE_MCYCLES = 1` and `CGB_HALT_PPU_LEAD = 1` both move this ROM's write
lattice 4 dots into the tile-MAP slot, where NO bitplane read of the frame has
an LCDC.4 change on its dot. The census drops to 408 cells (216 SET / 192
RESET, still 216/216 and 192/192), this constant fires on nothing at any
window in 0..19, and the row is 23038 whatever it is set to. Every trigger
hypothesis above -- including `never`, i.e. deleting this constant -- scores
the same 216/216. The rule is still believed (it is what the 223/223 world
measured) but nothing in the tree can now falsify it: do NOT read 216/216 as
support.

The trade if the lattice is put back is bounded and small:
`CGB_TDSEL_LATENCY = 5` takes acid-hell to 23040 and costs the four mealybug
frames 3859 pixels, because their writes DID move with their mode-2 anchor.

A rule firing in the map slot instead is refused by 48 `*_change2` cells in
the identical bucket. The read-level bracket a refinement would have to beat
(`tools/gbppu/tdselphase.py`, splitting the one bucket that could fix the row
-- mapoff=0, read offset +4, RESET, 71 reads -- by the change before last):

  prev2off   reads   hardware wants INDEX   hardware wants SGN   ROM
  -32            7                      7                    5   acid-hell
  -24           32                      0                   32   mealybug
  None          24                      8                   24   mealybug
  (prevdir -1)   8                      8                    8   mealybug

Firing on the whole bucket buys acid-hell's 2 and costs 64 mealybug reads.
The only feature separating acid-hell's seven from the 32 hard refusers is
`prev2off = -32` against `-24` -- one ROM's fingerprint, on a context no
second ROM populates. So the 2 pixels are an integration decision, not a
modelling one, and 4 dots (not this constant) is what stands between the tree
and `LEAD=1`.

A revision split is excluded, not merely unsupported: acid-hell picks its tile
data off a `$FEA0` readback and dingbat takes the branch the bundled reference
was captured on, a CGB-C, as is every `*_change2` reference. `$FEA0..$FEFF` is
modelled per revision now (GbUnusableRegion) and the row is 23040/23040 on
0/A/B/C/E and the default, 22864 on D alone -- the ROM refusing CGB-D on
purpose. The default branch is unchanged; it is now taken because a C-class
machine reads `$44` back, rather than because the region was unmodelled.

Assumed beyond the two pixels, deliberately minimally: the window is not
consumed by the SET glitch that uses it (no cell has two SET glitches behind
one RESET), the substituted byte is the CURRENT tile's index and not the
RESET-glitched tile's (line 68's tile is $55 and hardware's byte is $55, while
the RESET-glitched tile one fetch back is $59), and the address latch is left
as the rule above leaves it.

Cost: +0.05..0.08% Pokemon Crystal, +0.02% blargg cpu_instrs, +0.05% Link's
Awakening DX retired instructions -- effectively the one guarded compare per
line in fifo_reset_sprite, since the arming rides a store the RESET branch
already did and the dot loop never sees the rule. The unpacked shape, same
behaviour, was +0.30 / +0.21 / +0.22%; see TDSEL_IDX_SHIFT.

## `CGB_TDSEL_ANY` / `CGB_MAP_ANY`

Whether anything records the map-select bits' change dot. `-d:CGB_MAP_LATENCY=0`
is the control build and reproduces the pre-2026-08-19 numbers exactly.

## `CGB_WY_LATCH_LATENCY` / `WIN_EN_ABORT`

Whether clearing LCDC.5 mid-mode-3 returns the fetcher to background tiles on
this line. 1 ships; 0 restores the old behaviour, where `fetching_window`
could not be cleared before the next line. Rule and citation at
tick_bg_fetcher.

DMG behaviour, not CGB: mealybug documents it in its PPU notes and measures
it with two ROMs whose scored references are `_dmg_blob`. dingbat used to file
it as SameBoy's CGB-only fetcher abort and not model it. Worth
m3_lcdc_win_en_change_multiple 8874 wrong pixels -> 0 (both devices),
`_wx` 4215 -> 343, DMG total +12746 and CGB +25758, plus three gambatte
window/on_screen rows.

## `WIN_EN_HOLD`

Dots a WX match that LCDC.5 refused stays live, waiting for the bit. 0 is the
control build and the pre-2026-08-09 behaviour (the match is dropped).

mealybug `m3_lcdc_win_en_change_multiple_wx` is the ruler: it writes WX = LY,
then clears LCDC.5 over dots 97..104 of every line and again over 125..132, so
the trigger pixel `t = LY - 7` walks one dot per line through both pulses and
the frame reads out what a match at each offset does. Its reference:

  t (band 1)      0    1  2  3..7    8      9     10     11
  match dot      94   95 96 97..101 102    103    104    105
  reference     x=0   -- -- --      one    x=10   x=10   x=11
                                    white

Band 2 repeats it at t = 28..39. The two obvious readings are refused by the
two ends of that table. Sampling the bit at the match dot alone
(`WIN_EN_HOLD = 0`) draws nothing at t = 9 and 10 where hardware draws a whole
window -- 296 wrong pixels. Sampling at the fetcher's tile-map read two dots
later gets every band edge right but must RESTART the fetch before it knows
the answer, which gambatte refuses from the other side: `window/late_disable_*`,
`late_reenable_*` and 36 `sprites/space/*` read STAT expecting mode 0 and get
mode 3, because the restart still costs the line six dots (3827 -> 3750,
window -40). Hardware pays nothing for a match it refuses.

So the match is not dropped and not committed: it WAITS. Two dots is what the
table brackets from both ends of both bands -- t = 9's match waits two dots
for the bit and t = 8's, one dot earlier, expires unserved (three would serve
t = 8). And the window starts on the dot the bit ARRIVES, not the dot it
matched, which is why t = 9 and t = 10 both draw from x = 10 (band 2: t = 37
and 38 both from x = 38). That coincidence is the sharpest thing in the row --
two adjacent scanlines whose windows begin at the same x, which no rule
starting the window at its own match pixel can produce.

Worth 296 wrong pixels -> 4. Nothing else in mealybug moves and no gambatte
row does: a refused match costs no dots, so every family keeps its length.

## `CGB_WIN_EN_HOLD`

WIN_EN_HOLD on CGB, which is not the same number. The evidence is thin on
purpose: mealybug's `_cgb_c` reference for the row above is pixel-exact with
and without the hold, so it says nothing. The only instrument separating the
devices is gambatte `window/late_reenable_scx5_2`, whose DMG half wants mode 3
still running at the read (the hold) and whose CGB half wants mode 0 (no
hold); `late_reenable_scx2_2` says the same one SCX apart, and
`window/late_enable_ly0_ds_2` refuses a CGB hold from the other direction.
DMG holds, CGB does not. This is the constant that moves if a CGB ruler turns up.
Whether a match that WAITED starts the window one pixel left of the pixel
the shifter has reached (1, shipping) or at that pixel (0). The ruler
above pins it: at 0, `t = 9` and `t = 10` both draw from x = 11 where the
reference has x = 10, and band 2's pair from x = 39 against x = 38 -- 10
wrong pixels against 4.

It is the SAME slot the comparator sits in -- "its counter runs one lower
than the emitted-pixel index" (WIN_START_PRE_PIXEL) -- and it is what makes
two adjacent scanlines of the ruler begin their windows at the same x,
which is the part of that reference no rule anchored to the match pixel
can produce. The pixel it takes back has already been written as
background and the window's first push writes over it.

Two gambatte rows bracket the dot it costs, and they are the two halves of
one family: `window/late_reenable_scx2_2` [dmg] wants mode 3 still running
at its read, which needs the served restart to be one dot later than the
drawn-through hold makes it (this rule, green), and
`window/late_disable_scx2_0` [dmg] wants mode 0 on a line whose match is
refused and never served, which needs an UNSERVED hold to cost nothing
(also this rule, green -- the dot is taken at the serve, not at the
match). Spending the dot at the match instead costs the second row.

## `WIN_EN_HOLD_BACK`

Whether a match that WAITED starts the window one pixel left of the pixel
the shifter has reached (1, shipping) or at that pixel (0). The ruler above
pins it: at 0, `t = 9` and `t = 10` both draw from x = 11 where the reference
has x = 10, and band 2's pair from x = 39 against x = 38 -- 10 wrong pixels
against 4.

Same slot the comparator sits in (WIN_START_PRE_PIXEL: its counter runs one
lower than the emitted-pixel index), and it is what makes two adjacent
scanlines of the ruler begin their windows at the same x. The pixel it takes
back has already been written as background and the window's first push
overwrites it.

Two halves of one gambatte family bracket the dot it costs:
`window/late_reenable_scx2_2` [dmg] wants mode 3 still running at its read,
which needs the served restart one dot later than the drawn-through hold
makes it; `window/late_disable_scx2_0` [dmg] wants mode 0 on a line whose
match is refused and never served, which needs an UNSERVED hold to cost
nothing. Both green -- the dot is taken at the serve, not at the match.
Spending it at the match instead costs the second row.

## `WIN_EN_HOLD_ZERO`

Whether a refused match landing on the fetcher's PUSH dot puts one pixel of
colour 0 on the front of the FIFO (1, shipping) or leaves it alone (0).

The ruler carries exactly two of these -- `t = 8` and `t = 32`, the only
refused matches in either band whose pixel is a multiple of 8 -- and they are
its last two wrong pixels. Both read out as a single WHITE pixel at the match
column with the background unshifted either side: no window, no stall.
Every other refused match sits at a phase where the FIFO already holds pixels
and hardware shows nothing, and the two SERVED matches on push dots
(`t = 16`, `t = 24`) show the window's own black there -- so it is the
collision of a refused start with the push, not either on its own.

Costs nothing: the entry is replaced rather than dropped, so the shifter does
not stall and mode 3 does not move. Worth 2 wrong pixels.

Gated on `window_trigger_en` (a WY match seen while LCDC.5 was SET this
frame), because a game that never enables its window must not glitch:
Pokemon Blue rests at WX = 7 / WY = 0 with the window off, its refused match
lands on the line's initial fill every line, and silicon draws no white
column through its intro. This is the Star Trek 25th Anniversary insertion
glitch (Pan Docs "Window", SameBoy #278); nitro2k01's SGB logic traces
condition it on the window having been activated first, and SameBoy
(wy_check) and DocBoy (w.active_for_frame) both put the enable term inside
the frame latch.

Where this model differs from both -- a hardware question, see
docs/hwprobe-questions.md: they INSERT the pixel into an empty FIFO and delay
the line by a dot; the mealybug reference reads back unshifted either side,
so this model REPLACES.

## `WIN_LINE_START_WX`

The WX below which a line STARTS as a window line instead of reaching the
window through the shifter's equality. See the mode 2 -> 3 edge in
fifo_tick_slow for what the two spellings mean.

gambatte brackets WX = 0 and WX = 7 and has nothing at 4, 5 or 6, so the
three m3_wx_{4,5,6}_change ROMs are the whole evidence. Wrong pixels of 23040
on the DMG references, with the mealybug DMG total (of 3,317,760):

  threshold   wx_4   wx_5    wx_6   window_timing   mealybug DMG
      5          0  13768    4611        30            515691
      6 (ship)   0      0    4611        29            529314
      7          0      0   13810        35            520109
      8          0      0   13810        41            517392

Only 6 satisfies all three: 5 breaks WX = 5 outright, 7 and 8 leave WX = 6 at
three times its error. Worth +9205 DMG pixels, the largest single move in the
mealybug set, and it moves nothing in gambatte (no gambatte ROM writes WX = 6).

It does NOT make m3_wx_6_change pass: 4611 pixels remain and are a different
mechanism (the window line advancing on a mid-line re-activation, see
docs/gb-failure-triage.md). This constant is pinned from both sides
regardless, which is why it ships without it.

## `WIN_HEAD_ABSORB`

Whether a line that STARTS as a window line pays its `7 - WX` fine-scroll
discard OUT OF the window's own six-dot startup fetch (1, shipping) or on top
of it (0). With it, mode 3 is `172 + 6` for every WX below
WIN_LINE_START_WX -- the same length a WX >= 7 window start has, which is
what mealybug m3_window_timing's flat reference says. Derivation at the head
latch in fifo_ppu.nim.

## `WIN_WX0_PHASE`

Where WX = 0's line-start window puts its FIRST TILE, and where the extra dot
that goes with SCX > 0 is spent. 1 ships: the discard is `7 - WX` at every WX
(seven at WX = 0) and the head's idle term is `WX - 1` unclamped, which at
WX = 0 is minus one -- a startup fetch one dot shorter, taken by skipping one
of FETCHER_ORDER's sleeps so the push arrives a dot early. 0 is the
pre-2026-08-09 spelling: a six-pixel discard at WX = 0 with `SCX & 7 = 0` and
zero idle dots.

Both spend the same DOTS (`idle + discard = 6`), so every length instrument
in the tree reads the same. What differs is the window's tile PHASE, one
pixel, and only mealybug `m3_lcdc_win_en_change_multiple_wx` can see it: it
turns the window off partway across every line and the background resumes on
the WINDOW's tile boundary (`m3_lcdc_win_en_change_multiple.asm:21`). With
WX = LY the reference reads the phase off per line:

  WX (= LY)      0    1    2    3    4    5    6    7
  black run      9   10    3    4    5    6    7    8
  first tile   -7..0 -6..1 -5..2 -4..3 -3..4 -2..5 -1..6  0..7

Every WX from 1 up is `first tile = (WX - 7) .. WX`; WX = 0 is the same
formula and NOT the six-pixel exception (its run of 9 is one tile boundary at
x = 1 plus the eight pixels after, the same "one tile later" WX = 1's 10 is).

The dot it hands back is the one the sampler used to pay: "window activating
one T-cycle later when WX = 0 and SCX > 0" (`m3_window_timing_wx_0.asm:21`)
is now the ABSENCE of that skip rather than a ninth discarded pixel. The test
is taken at the dot SCX is latched on, the first dot the answer exists on --
see fifo_sample_smooth_scroll.

## `WIN_LINE_START_LATCH`

Which dot WX is read on to decide whether a line STARTS as a window line: the
last dot of the throw-away fetch at the head of mode 3 (1, shipping), or the
mode 2 -> 3 edge six dots earlier (0). Bracketed from both sides by two
mealybug ROMs; see the head latch in fifo_ppu.nim.

## `WIN_START_PRE_PIXEL`

Whether the window's WX comparator can match one pixel slot LEFT of the
shifter's first pixel -- screen x = -1 when SCX & 7 = 0, i.e. WX = 6. 1 ships;
0 compiles the clamp out. Derivation and the two-sided bracket fixing it to
exactly one slot: `fifo_arm_window` in fifo_ppu.nim.

A different mechanism from WIN_LINE_START_WX and non-overlapping: that reads
WX at the mode 2 -> 3 edge and starts the whole line as a window line, this
reads WX at the shifter's first dot and reaches the same place through the
ordinary equality. m3_wx_6_change needs both and distinguishes them -- it
writes WX = 6 at dot 49 (mode 2) and WX = LY at dot 93, so the mode-2 value is
6 on every line while the reference draws no window on LY 4 or 5, which
refuses WIN_LINE_START_WX = 7 outright.

## `WIN_PRE_PX_PHASE`

What a match on the comparator's PRE-PIXEL slot does with the window's TILE.
1 ships: the tile keeps its own first pixel, covering `WX - 7 .. WX` as at
every other WX, and the startup fetch is one dot shorter because one of its
six dots was spent before the shifter reached its first pixel. 0 is the
pre-2026-08-09 spelling, where the clamp moved the tile with the match and the
first tile covered `0 .. 7`.

Mode 3 LENGTH is identical either way by construction (five dots of fetch plus
the pixel at x = -1 is six dots plus the pixel at x = 0), so every length
instrument that pinned the clamp reads what it read before. One pixel of phase
moves, and `m3_lcdc_win_en_change_multiple_wx` is again the only witness: on
its WX = 6 line the background resumes at x = 7, i.e. on the boundary of a
window tile covering `-1 .. 6`, where the clamped tile would put it at x = 8.
Same reading as WIN_WX0_PHASE at the other end of the same table.

## `WIN_RESTART_COUNTER` / `CGB_WIN_RESTART_COUNTER`

Which fetcher step a WINDOW start's restarted fetch resumes at, per model.
0 is fetch_counter 0, the first of the two dots step 1 lasts, making the
startup fetch six dots and taking the early push (Pan Docs' "6 dots"; see
fifo_reset_bg). 1 makes it five.

Separate from the LINE-START reset, which shares fifo_reset_bg but is the head
cycle rather than a restart -- its discarded fetch starts at 0 whatever these
say. Probe (f) tells them apart: it brings the window up mid-line at WX = 15
and reads the fetch grid after it, where the line-start path never runs.

Two knobs because probe (f) says the models disagree, on both sides of the
same instrument. Scored by BASE equivalence (tools/gbprobe/probe_f_base.sh):

  DMG, counter 0 : 8/8 residues            <- already right, do not touch
  CGB, counter 0 : 2/8 residues, no common BASE
  CGB, counter 1 : 7/8 residues, ALL at BASE 24

At counter 1 the CGB's windowed staircase differs from silicon by ONE uniform
phase offset -- the same 8 dots the window-less arm carries (probe (e)), a bug
this knob is not about. At counter 0 no offset works at all. The DMG column is
why this is not one global knob: counter 0 against 1 was worth mealybug DMG
+361 pixels when the fetcher's padding moved in 2026-08-03, and probe (f)
agrees. The DMG's startup fetch really is six dots; the CGB's is five.

## `WIN_TAIL_FETCH`

Whether a window START holds mode 3 open for the fetch it restarts, when the
start lands inside the last pixels of the line. 1 ships; 0 restores the
pre-2026-08-09 behaviour, where the restart was absorbed by the pipeline's
tail burst and cost nothing.

That was an accident of `fetcher_retired`'s shape, not a rule: the term
keeping mode 3 open for a not-yet-started window is written
`not fetching_window and ...`, so the instant the window starts the term goes
false and, with nothing else owing, the fetcher retires on that dot -- restart,
push and pixel in one burst. Nothing about hardware says a window start is
free: it empties the BG FIFO and the pixel it starts on cannot be drawn until
the refetch pushes.

Bracketed by `window/m2int_wxA5_m3stat` (WX = 165, first window pixel x = 158,
so the restart lands one pixel inside the tail): red on BOTH devices without
this (`_1` wants 3 and gets 0), green on both with it. See CGB_WIN_TAIL_LAST
for WX = 166 and `fetch_work_pending` in fifo_ppu.nim for the code.

## `DMG_WIN_START_LAST_PX`

The CGB_WIN_TAIL_LAST device split carried to the SHIFTER instead of to mode
3's length: on a DMG a window START on the line's last pixel (only WX = 166
produces one) does not happen at all.

Ships OFF -- this spelling is refused by the frames. See
`win_start_reaches_pixels` in fifo_ppu.nim for the oracle (14 ROMs whose two
device references differ, where dingbat's DMG output matches the CGB reference
to the pixel) and for which half survives. Superseded by
DMG_WIN_LAST_PX_CARRY: the start happens, its first pixel does not reach the
screen, and the start is still owed on the NEXT line.

## `DMG_WIN_LAST_PX_CARRY`

The DMG's window start on the line's LAST pixel is not lost -- it is owed to
the next line. The pixel-path half of CGB_WIN_TAIL_LAST, and the whole of
`window/on_screen`. 1 ships; 0 is the pre-2026-08-13 behaviour, where the
restart's tile was shifted out on the last pixel of the same line.

CGB_WIN_TAIL_LAST says the DMG's mode 3 ends with the last PIXEL and the
CGB's with the last FETCH. Read as a statement about when end-of-line cleanup
runs, the rest follows: hardware's "window has started" latch is set by the WX
comparator and cleared when the line ends, so on a DMG a match on the last
pixel lands on the same dot as the clear and survives it, while on a CGB the
extra fetch pushes the clear past the match. Only WX = 166 can put a match
there, which is why the affected set is `window/on_screen/wxA6_*`.

Three consequences, each measured against gambatte's reference PAIRS (the 14
ROMs whose `_dmg08` and `_cgb04c` PNGs differ were exactly the 14 failing rows):

  * the restart's first pixel is never shifted out, so x = 159 keeps the
    BACKGROUND pixel the FIFO held. `wxA6_late_we_reenable_4` is that alone --
    120 lines, one pixel each, at x = 159;
  * the latch is still set at the head of the NEXT line, so that line is a
    window line from x = 0 with no WX match of its own. `wxA6_wy8F` is that
    alone -- its only match is on LY 143 and its only wrong line is LY 0 of the
    next frame, so the latch crosses the frame boundary;
  * the latch is consumed at the head only if LCDC.5 is set THERE, and is not
    cleared if it is not -- `wxA6_wy01_weoff_ly02` sets it on LY 1, spends the
    frame with LCDC.5 clear, and still draws LY 0 of the next frame as a
    window line.

Where the head consumes it, bracketed to one dot: `wxA6_late_we_reenable_1..4`
clear LCDC.5 in mode 2 and set it again at dot 77, 81, 85 and 89 of every
line. 77/81/85 are consumed (~14.5k wrong pixels without this) and 89 is not
(120 wrong pixels, the x = 159 half alone). Mode 3 starts at dot 80 and the
head's throw-away fetch ends at 86, which is where `fifo_head_window` already
reads WX for WIN_LINE_START_LATCH.

The window's own line counter is not special-cased: head consumption counts as
a start and increments it exactly as `fifo_head_window`'s WX < 7 case does, and
the aborted start on the previous line incremented it too. That makes it equal
to LY on both `wxA6_wy00` and `wxA6_wy01`, which is what both references want
to the pixel. The tile COLUMN is where a carried line differs: it starts at
WIN_CARRY_TILE, not at 0.

Cost: +0.29% retired instructions on cgb-acid-hell, +0.20% on blargg
cpu_instrs, against `-d:DMG_WIN_LAST_PX_CARRY=0` (which reproduces the
pre-2026-08-13 gambatte score row for row, 4145/5005). Every per-dot term is
behind `not ppu.cgb`, so a CGB pays the branch and nothing else. The shape
matters more than the terms -- see the inline-cliff note on `fifo_emit_pixel`,
where the same rule as an `{.inline.}` proc instead of a template measured
+3.63%.

Still red: `window/on_screen` is 34 of 36. `wxA6_late_we_reenable_3 [dmg]`
(916 px) is one line early for the whole frame -- one window line too many
across 127 lines -- and differs from the green `_1`/`_2` only in putting
LCDC.5 back at dot 85 instead of 77 or 81. Suppressing its WIN_CARRY_REACT_LINES
credit wholesale is refused (6520 px), so the extra line is taken on ONE line,
which is a rule about the first reactivated line that this constant lacks.
(`wx17_weoff_wxA5_weon [cgb]` predates all of this.)

## `WIN_CARRY_TILE`

The window tile column a carried start (DMG_WIN_LAST_PX_CARRY) draws first.

1, not 0: the aborted start on the previous line ran the map read for column 0
and the counter moved with it, so the first column the carried line can push is
column 1. The `on_screen` window maps are a DIAGONAL (row `r` holds the one
black tile at column `r`), so this is worth a whole tile of the staircase, and
`wxA6_wy00`, `wxA6_wy01` and `wxA6_weoff_at_xposA6` all put the black tile one
column LEFT of where the window row index alone would. A diagonal cannot tell a
column shift from a row shift on its own; what fixes it as the column is that
the row index is `current_window_line shr 3`, pinned independently by the CGB
references (window row 0 on LY 0..7).

## `WIN_CARRY_REACT_LINES`

Extra window LINES a carried start counts when it has to REACTIVATE the window
-- i.e. when LCDC.5 went low between the match that owed the start and the head
that spends it. 0 is the control build.

The counter is otherwise one per line the window draws, which is what
`wxA6_wy00` and `wxA6_wy01` want (LCDC.5 never moves; their window rows change
every EIGHT lines). The two families that move it want rows every FOUR:
`wxA6_late_we_reenable_1..3` clear LCDC.5 in mode 2 and set it before the head,
and `wxA6_weoff_at_xposA6` clears it mid-line at x = 96 and sets it in H-Blank
-- both once per line, both twice the counter.
`wxA6_wy01_weoff_ly02_weon_ly60` is the same rule with one toggle per frame
instead of 144: one line late without this, exact with it.

## `CGB_WIN_TAIL_LAST`

Whether a window restart issued on the LINE'S LAST PIXEL holds mode 3 open,
which only the CGB does. 1 ships; 0 makes the two devices identical again.

Narrows WIN_TAIL_FETCH and requires it. The DMG's mode 3 ends with the last
PIXEL and the CGB's with the last FETCH. Everywhere else the two coincide,
because the fetcher runs ahead of the shifter and any restart has pixels after
it to fill; they can only come apart on a restart whose own first pixel is
x = 159, and only WX = 166 puts one there -- exactly where gambatte splits the
devices.

---- The mode 3 END differs, bracketed to 5..7 dots ----------------------

Every `window/m2int_wx*_m3stat` family has identical DMG and CGB expectations
except at WX = 166, where all differ and the CGB is always longer. Each family
is a ladder of ROMs reading STAT one M-cycle apart, so "the last `_n` still
reading mode 3" brackets the end to within 4 dots and the device DIFFERENCE to
an 8-dot window centred on `4 * (n_cgb - n_dmg)`:

  family (all `window/m2int_wxA6_`)  last _n reading 3   difference
                                       DMG      CGB      is inside
  m3stat                                1        2       ( 0,  8)
  scx2_m3stat                           1        3       ( 4, 12)
  scx3_m3stat                           1        3       ( 4, 12)
  scx5_m3stat                           1        2       ( 0,  8)

(SCX moves the end of mode 3 by `SCX & 7` dots, sliding the boundary across
the M-cycle grid these ROMs sample on -- which is why two families see one step
and two see two, and what makes the four a two-sided bracket rather than four
copies of one measurement.)

They intersect at 5..7 dots, and a BG fetch is six. `-d:gb_m3_len` on the wxA6
line reads 174 dots when the restart is not waited for and 180 when it is,
against 172 for a plain line, so DMG = 174 / CGB = 180 is the only assignment
the bracket allows and the split needs no constant of its own: one fetch,
waited for on one device. `wxA6_oambusyread` and `wxA6_vrambusyread` carry the
same split from the bus side, so it is the END of mode 3 that moves and not the
STAT read model.

Refused, built and scored 2026-08-09: unifying this with the DMG's comparator
running one slot lower than the emitted-pixel index (already forced at the LEFT
end by WIN_START_PRE_PIXEL) would also stop the DMG one slot short of the last
pixel, drawing no window at WX = 166. It gives the DMG 172 dots where the
bracket wants 174 and takes `m2int_wxA6_m3stat_1`, `_firstline_m3stat_1`,
`_oambusyread_1` and `_vrambusyread_1` red on DMG. The DMG does reach the slot
and does restart the fetch there -- those two dots are that slot. What it does
not do is wait for the fetch, so the two ends of the line are two mechanisms
and WIN_START_PRE_PIXEL stays device-independent.

An object on the same pixel is the SAME fetch slot, not a second one. The one
case is WX = 166 with an object at X = 167; there the CGB's extra six is NOT
charged again (`obj_last_px` into fetch_work_pending) and both devices come out
at 180 -- the plain 174 plus the object's own six. Four mode-0 INTERRUPT rows
bracket that, and they are the ones to trust because they read the flag's own
dot rather than a STAT read three dots behind it (STAT_READ_LAG):
`m2int_wxA6_spxA7_m0irq_1/_2` on both devices and
`m0enable/enable_wxA6_2x_spxA7_ds_1..3` on CGB in double speed. All four want
mode 0 open by 180; charging the restart on top (186) takes all four red, and
so does deferring the object behind the restart (190).

The two rows asking for a longer CGB (`_spxA7_m3stat_2` and `_4`) cannot
arbitrate it, measurably rather than by preference: swept over a tail hold of
0..16 dots, `_4` is red at EVERY length on CGB, including the 190 at which it
is green when the object is deferred instead. A row whose verdict is not
monotone in the quantity is not measuring it. `_2` is left red, as on main.

The one row this costs: `m2int_wxA6_scx5_m3stat_3` goes red on CGB and its
double-speed sibling `_ds_1` goes green with it. The two are one dot apart and
cannot both be satisfied -- same device, WX, SCX and measured mode 3 (185
dots), only the sampling grid differing (4 dots single, 2 double). `_3` needs
the CGB's extra to be at most 5 and `_ds_1` at least 6. Six ships because six
is a fetch: five scores the same net, trading `_ds_1` back for `_3`, and is
refused as a fit -- no mechanism makes a BG fetch five dots long, and the
SCX = 0, 2 and 3 families are two-sided at six. The disagreement belongs to
whatever puts the double-speed sampling grid a dot off.

## `OBJ_BG_RUN`

Which dots of an object penalty the BG fetcher is allowed to run on:
0 = none, 1 = the wait dots only, 2 = all of them, 3 = the wait dots but
only to finish a fetch already under way, 4 = the tile-boundary rule
(shipping) -- all of them when the fetch the object is waiting for is still
in flight, none of them plus one when it is already done. The derivation,
the eighteen-band measurement behind it and the sweep that cannot separate
0..3 are at tick_sprite_fetcher in fifo_ppu.nim; this exists so that sweep
is a command line rather than an edit to the dot loop.

## `M3_THROWAWAY_DOTS`

Dots the DISCARDED fetch at the head of mode 3 lasts: 4 (`B0`, shipping) or
6 (`B01`, the control build and what this tree did until 2026-08-09). The
head budget is 12 dots either way -- see the derivation at
`M3_THROWAWAY_DOTS` in gb/fifo_ppu.nim -- so this constant does not change
mode 3's length; it only says where inside those 12 dots the first real
tile's three VRAM reads fall.

## `OBJ_ABORT`

Whether clearing LCDC.1 in the middle of an object's stall CANCELS the
fetch (1, shipping) or lets it run to completion (0, the pre-2026-08-09
behaviour). Pan Docs describes the cancel; the derivation, the dot the
shifter resumes on and the ROMs that bracket it are at `fifo_obj_abort`
in fifo_ppu.nim.

## `CGB_OBJ_ABORT`

Whether the CGB cancels an object fetch the way the DMG does (1) or lets
it run (0, shipping). One row measures it and it is the same cart on both
consoles: mealybug m3_lcdc_obj_en_change_variant is pixel-exact against
its `_cgb_c` reference with the cancel OFF and 288 pixels out with it on,
while against its DMG reference it is 96 out without and 0 with. See
`fifo_obj_abort` for what that one row cannot separate.

## `OBJ_ABORT_LEAD`

Dots by which the object FETCHER's view of LCDC.1 leads the CPU's write
dot, when the write cancels a fetch (OBJ_ABORT). The SHIFTER comes back on
dot `W - OBJ_ABORT_LEAD`, paid as that many catch-up pipeline dots on the
write's own dot; it is the same two dots M3_PIPE_DELAY already charges the
rest of the line. What the shifter gets and the FETCHER does not is
OBJ_ABORT_FLAG_HOLD below; the bracket that pins the pair is at
`fifo_obj_abort` in fifo_ppu.nim.

## `OBJ_ABORT_FLAG_HOLD`

Dots the mode 3 -> 0 FLAG keeps after an aborted object fetch that the
shifter does not: the cancelled VRAM cycle still owns the bus for its last
dot, so the fetcher retires one dot behind the pixels. It is what makes the
two instruments agree -- mealybug reads the PIXELS and gambatte's
sprite_late_disable rows read the FLAG -- and both are exact with the pair
(2, 1) where no single refund satisfies either pair of rows. See
`fifo_obj_abort`.

## `MIXER_PRIORITY_BACK`

Stages of the mixer tail LCDC's priority bits are read at the far end of.

## `BG_EN_AT_MIX`

Where LCDC.0 (BG enable, DMG meaning) is sampled: at the MIXER, once per
emitted pixel (1, shipping), or at the FIFO PUSH, once per eight (0, the
pre-2026-08-08 behaviour). It is a mixer read like the rest of LCDC's
priority half, so it carries MIXER_PRIORITY_BACK with them.

mealybug m3_lcdc_bg_en_change is the ruler and it is not a fit: its handler
clears LCDC.0 for exactly 12 dots, sets it for 8, clears it for 8 and
leaves it set (`ld [hl],c / nop / ld [hl],b / ld [hl],c / ld [hl],b`, 8
cycles each), and the DMG reference answers with white runs of exactly 12
and 8 pixels -- at x = -1..10 and 19..26, neither of them on a tile
boundary, over a background whose glyphs are otherwise in their normal
columns. Sampling at the push can only ever blank whole tiles, which is
what the 2193-pixel residual on that row was.

## `MIXER_PALETTE_BACK`

Stages of the mixer tail BGP/OBP0/OBP1 are read at the far end of. One
more than the priority bits: the mixer resolves BG-vs-OBJ first and looks
the shade up after, so a palette write reaches one pixel further back than
an LCDC write does. m3_obp0_change is what separates them -- it goes to
pixel-exact at 2 and is 42 pixels out at 1, on a frame where
m3_lcdc_obj_en_change is 60 out at 0 and 2 out at 1.

m3_bgp_change and m3_bgp_change_sprites used to be the two rows that argued
for ONE stage, by 22 and 136 pixels. MIXER_PALETTE_OR below is what they
were really measuring: with the transition pixel modelled they prefer TWO
by 806 and 624, and the vote across all six palette rows is unanimous (the
table is in docs/gb-failure-triage.md). The constant never moved.

## `MIXER_PALETTE_OR`

Whether a DMG palette write puts ONE pixel of `old or new` at the far end
of the mixer tail (1, shipping) or a clean edge (0, the pre-2026-08-08
behaviour). mealybug m3_bgp_change is the instrument and the derivation is
at the FF47..FF49 write in ppu.nim -- its frame is BGP's low two bits
sampled once per dot, so the three-valued edge is read straight off it.

## `MIXER_DOT_LAG`

Whether the pixel mixer runs a dot behind the FIFO pop. 1 ships; 0 is the
control build and compiles the whole mechanism out. See
fifo_recompose_last in fifo_ppu.nim for what it buys and how it was
measured -- it is not a sweepable dot count, only on or off, because a
second dot is refused by the same rows the first is required by.

## `MIXER_TAIL_HBLANK`

Whether the mixer keeps CLOCKING after the mode 3 -> 0 edge, so that a
register write on the first dots of H-Blank still reaches the pixels whose
shade the tail has not latched yet. 1 ships; 0 is the pre-2026-08-09
behaviour, where every recompose was guarded on mode 3.

It is not a second lag and it moves no edge: the mode 3 -> 0 dot, the
VRAM/OAM locks and the STAT model are all untouched (bucket 15 in
docs/gb-failure-triage.md pins that dot from a dozen directions). What it
fixes is an ACCOUNTING error of ours. The shifter emits one pixel per dot
and the tail latches its shade MIXER_PALETTE_BACK dots later, so the last
pixels of a line are still in the tail when the fetcher retires -- but
`fifo_burst_tail` emits them all on the retire dot, which is the only dot
in the line where dingbat's shifter is not one pixel per dot. See
fifo_recompose_last in fifo_ppu.nim for the derivation off m3_bgp_change's
seventh write.

## `NO_LCDC2_FLIP`

`GbPpu.lcdc2_flip` entry meaning "LCDC.2 has not changed since this mode 3
began". A dot in the far PAST, so `flip > dot` is false for every dot an
object fetch can ask about -- including one in the future, which is how the
merge asks for a read that has not happened yet -- and the empty history
costs no branch of its own.

## `OBJ_FIX_OFF`

`GbFifoPpu.obj_fix_from` meaning "no object fetch is still reachable by an
LCDC.2 write". Same shape as above: the window test is one compare either
way.

## `NO_TDSEL_CHANGE`

`GbFifoPpu.tdsel_dot` meaning "LCDC.4 has not changed on this line". A dot
in the far past, so the fetcher's `cycle_counter - tdsel_dot` is a large
positive that is neither inside the latency nor on the glitch dot, and the
empty case costs no branch of its own -- the same shape as NO_LCDC2_FLIP.
It is also what a DMG carries all frame, since only a CGB records a change.

## `NO_MAP_CHANGE`

`GbFifoPpu.map_dot` meaning "neither tile-map select bit has changed on
this line". Same shape as NO_TDSEL_CHANGE above: a dot in the far past, so
the fetcher's single `cycle_counter < map_dot` never takes and the empty
case -- which is every line of every DMG frame -- costs no branch of its
own. See CGB_MAP_LATENCY.

## `TDSEL_ADDR_OFF`

`GbFifoPpu.tdsel_addr` meaning "nothing has driven an $8000-region
tile-data address yet". A SET-glitched read falls back to its own read
there. Only reachable before the first such read of a frame now that the
latch survives H-Blank, and no reference in this tree reaches it.

## `TDSEL_ADDR_BANK`

Bit `tdsel_addr` carries the VRAM bank in. Offsets are 13 bits, so the
bank rides above them and the whole latch is one store on the fetch path.

## `TDSEL_IDX_SHIFT`

Bit `tdsel_addr` carries the INDEX path's arming in, as the first dot PAST
the window (see CGB_TDSEL_IDX_DOTS). Above the bank at bit 13, so a dot needs
nine bits and the word stays positive. One-past rather than the last dot so
zero up there means "not armed" for every dot including 0, making the whole
test `(latch shr 14) > cycle_counter` -- one compare answering the unarmed
case and the negative TDSEL_ADDR_OFF sentinel alike.

It rides `tdsel_addr` rather than living in its own field because a field is
not free: GbFifoPpu is 632 bytes and every offset above the latch is on the
fetch path, so one more int32 grows it to 640 and moves `tile_num`, the tile
attributes and both bitplane bytes. That measured +0.22% of retired
instructions on Pokemon Crystal WITH THE RULE COMPILED OUT -- pure layout,
more than the rule itself costs. Packed, the arming is written by the store
the RESET branch already does.

The packing also settles one thing the corpus leaves open, in the direction of
less mechanism: every write of the latch clears these bits, so an object fetch
or a plain unsigned read between the RESET glitch and the SET one disarms it.
That is the "<= 8 dots old AND a RESET glitch wrote it" spelling, which scores
the same 223/223 as the looser one -- no cell separates them.

## `MIXER_TAIL_DOTS`

Whether the mixer tail is clocked in DOTS (1, shipping) or in emitted PIXELS
(0, pre-2026-08-10, where the reach was counted back from `lx`).

The two agree everywhere the shifter runs one pixel per dot, which is all of a
line except an object fetch and the tail burst. Where they differ, mealybug
says dots. `m3_bgp_change_sprites` is the ruler: its object stalls the shifter
at the head of each band and its handler writes BGP on a fixed dot, so each
band asks how far back a write reaches while the shifter is stopped. The DMG
reference answers ZERO pixels back for a stall older than the tail (bands
8..12), ONE for a stall one dot old (band 13) and the full two for an
unstalled shifter (bands 14..17) -- i.e. a write reaches a pixel iff that pixel
LEFT THE FIFO within MIXER_PALETTE_BACK dots, stall or no stall. A
pixel-clocked tail holds the last two pixels for the whole of a 6..11 dot
object fetch and repaints them; that was 104 of that row's wrong pixels and 59
of `m3_lcdc_bg_en_change`'s.

GbFifoPpu.tail_dot0 is the dot pixel 0 of the current unbroken run of
emissions would have left on, so the shifter's position on any later dot reads
back as `cycle_counter - tail_dot0` whether or not `lx` has moved. It subsumes
the tail-burst latch MIXER_TAIL_HBLANK needed.

## `MIXER_HEAD_LINGER`

Whether the line's FIRST pixel holds the SHALLOW stages of the mixer tail open
until the deepest one is read (1, shipping). Pixel 0 alone, and only for a
register read at a stage shallower than the palettes': LCDC's priority bits
reach it for MIXER_PALETTE_BACK dots after it leaves the FIFO rather than
MIXER_PRIORITY_BACK.

mealybug `m3_lcdc_bg_en_change` is the whole measurement, a +-1 step and not a
fit. Its object's OAM X advances one per 8-line band, moving the dot pixel 0
leaves the FIFO on (105, 104, 103, 102, 101, 100 for bands 0..5 by
`-d:gb_px_trace`) while the handler's LCDC write stays on dot 105. The DMG
reference blanks x = 0 in bands 0..2 and leaves it alone in bands 3..7 -- so
pixel 0 is reachable exactly TWO dots after it leaves, where
MIXER_PRIORITY_BACK is one and every other pixel of the same bands obeys it.

The palettes are NOT extended, and the same suite says so: `m3_bgp_change`
writes BGP on dot 97 with pixel 0 leaving on dot 94, and its reference puts the
`old or new` pixel at x = 1 -- a two-dot reach, same as every other pixel. So
this is not "pixel 0 lingers a dot"; it is the two stages COINCIDING for the
line's first pixel, which is why it is written as `back < head` and not a lag.

The DMG references are the only oracle. gambatte's `dmgpalette_during_m3`
looks like a second one and is not: its PNGs carry no `old or new` pixel at all
(MIXER_PALETTE_OR's named cost), so every disagreement with them here is
already that one.

## `MIX_HOLD`

Entries in the mixer's held-pair ring (GbFifoPpu.mix), a power of two so the
shifter's store indexes with an `and`. It must cover every pixel a write can
still reach: the deepest mixer stage plus the pixels the tail burst decided
ahead of their own dot (the pipeline lead). fifo_ppu.nim static-asserts that
sum against this.

Overridable only so a sweep of the pipeline lead can build at all -- a whole
M-cycle of M3_PIPE_MCYCLES needs 8. Depth alone changes no pixel.

## `CGB_MIXER_LATENCY`

Dots a C-class CGB's write to a register the MIXER reads takes to arrive over
the DMG's. Subtracted from every mixer stage, so a register the DMG reads one
stage down is not repainted on CGB at all.

This is the QUANTITY only. Whether a machine is charged it is a runtime
question (`quirks.mixer_write_immediate` says CGB D and later are not), and
`gb_mixer_latency` is where the two meet. It stays an `intdefine` so a sweep
still builds; overriding it moves the C-class machine and leaves D and E at 0.

Two rows pin it, each exact on BOTH consoles at these settings and on neither
at any other. m3_lcdc_obj_en_change (priority, one stage) is pixel-exact on the
CGB references with no repaint and 60 px out with one, and 2 out on DMG with
one repaint and 60 with none. m3_obp0_change (palette, two stages) is exact on
DMG at two and on CGB at one; 32 px out on DMG at one, 126 out on CGB at two.
Same cart, same write, same objects -- only the console differs, and the same
single dot separates them at both stages.

Shaped as a write latency because that is what every other per-register
CGB/DMG difference here is (mealybug's PPU notes document it for SCY; see
CGB_SCY_LATENCY). SEPARATE from CGB_LCDC_LATENCY, which is LCDC's latency at
the FETCHER -- different rows measure them, they come out different, and that
one ships at 0.

## `CGB_LCDC_MIXER_LATENCY`

CGB_MIXER_LATENCY for LCDC specifically.

The mixer runs one dot behind the FIFO pop (fifo_recompose_last), so a
mid-mode-3 write to a register it reads still reaches the pixel already
emitted -- on DMG. On CGB it does not, and one row says so alone: mealybug
m3_lcdc_obj_en_change is pixel-exact on the CGB references WITHOUT the extra
dot and 174 px out with it, while on DMG it is 60 px out without and 2 with.
One dot of CGB latency cancels the mixer's one dot exactly, which is why the
repaint is skipped rather than delayed.

Only LCDC. The three DMG palettes take the mixer's dot on both consoles
(m3_obp0_change goes 96 wrong px -> 0 on the CGB references with the repaint
on, and m3_bgp_change 96.1% -> 98.9%), so whatever this dot is, it is not
shared by every mixer input.

## `CGB_LATENCY_CAP`

Dots at the end of the M-cycle no latency may reach into. Inert while the six
above are 0. Only DOUBLE SPEED can tell 0 from 1 -- its M-cycle is two dots, so
a 2-dot latency either lands on the boundary (0) or one dot short (1) -- and it
is worth 8 rows: at CGB_SCROLL_LATENCY=2 the uncapped form is 3551 and the
capped one 3559, the whole difference being `_ds_` rows in
scy/scx_during_m3/sprites. Those rows are the CGB CPU-to-PPU phase axis (see
the lcd_offset note at mem_tick_ppu_latched), not this one, so the cap is what
keeps a register latency from being scored against them.

## `LCD_ON_LINE0_TRIM` / `LCD_ON_LINE1_TRIM`

---- The 2 dots at the mode 3 -> 0 edge, and the three ways to spend them ---

Dots the first and second line after an LCD enable are short of a normal 456.
Both ship at 0, which compiles the field and every branch out.

They exist because three unrelated ROM families want the mode 3 -> 0 edge TWO
DOTS earlier than this tree puts it, and each constant that could give it to
them is refused by a fourth family. Measured 2026-08-03, one full runner per
cell, from 5edfe2d (934 / 672, gambatte 3534, GBMicrotest 400, mooneye 112,
wilbertpol 82):

  route                            buys                       loses
  M3_END_EARLY=2 (fifo_ppu.nim)    GBMicrotest +20            mooneye -1,
    mode 3 2 dots shorter, every   (hblank_int_scx*, the      wilbertpol -4,
    line, every SCX                sprite*_b and win*_b rows) gambatte -150
  LCD_ON_HEAD_START=7 (ppu.nim)    GBMicrotest +9,            enable_display -10,
    PPU 2 dots further into        gambatte sprites +15       scx_during_m3 -3,
    line 0 at the enable                                      age -1, mealybug -1
  LCD_ON_LINE0_TRIM=2              GBMicrotest +21,           enable_display -7,
    line 0 is 454 dots, so line 1  gambatte +10 net           scx_during_m3 -3,
    lands 2 dots earlier and                                  dma -1, age -1,
    line 0's own edges do not move                            mealybug -1
  LCD_ON_LINE0_TRIM=2 plus         GBMicrotest +20 net        gbmicrotest
    LCD_ON_LINE1_TRIM=-2           (+23: hblank_int_scx*,     win{0_scx3,5,6}_a,
    line 0 ends 2 early and line 1 ppu_sprite0_scx*_b,        age/ly/ly-cgbE,
    gives them back, confining     sprite4_4..7_b, sprite_1_b, gambatte
    the skew to the first 2 lines  win{1,2,8..15}_b)          enable_display -1
                                   gambatte +13 net

That last row is by far the closest: mooneye 112, wilbertpol 82, Blargg,
Mealybug, mGBA, scx_during_m3, dma and every other gambatte subdirectory are
untouched, +33 rows for -5. NOT shipped, for one reason: nothing derives it. A
line is 456 dots and hardware has no mechanism making one 454 and the next 458;
the shape was reached by splitting the difference between disagreeing ROMs,
which is the fit this project has declined four times before. If a mechanism
turns up -- the obvious candidate is the sub-M-cycle phase mooneye's notes
describe at LCD_ON_HEAD_START, of which this would be the whole-dot rounding --
re-measure this setting first.

Which family a ROM belongs to is decided by WHICH LINE AFTER THE ENABLE it
measures, and the answers do not agree:

  * GBMicrotest int_hblank_{nops,incs,halt}_scx0..7 take the very next H-Blank,
    so they time LINE 0. All eight pass here and all eight break at
    M3_END_EARLY=2.
  * GBMicrotest hblank_int_scx0..7 burn 114 NOPs -- one whole line -- before
    enabling the STAT source, so they time LINE 1. Four of the eight fail here
    and only 2 dots fixes them.
  * GBMicrotest hblank_int_scx*_if_* / _nops_* never touch the LCD; they run
    from the boot hand-off and want the same 2 dots, which is what
    DMG_BOOT_PHASE = 399 buys and what it is refused for. They are NOT reachable
    from these two trims, and that is load-bearing: the HLE hand-off writes
    LCDC = $91 through write_byte (memory.nim's skip_boot), so the LCD-enable
    branch fires there too and ppu.skip_boot must clear the window it opens
    exactly as it clears `first_line`. Without that reset a trim silently
    retimes the first two lines after the BOOT hand-off as well, which reads as
    these rows going green for the wrong reason.
  * gambatte enable_display and the scx_during_m3 reference PNGs enable the LCD
    and then measure later lines and frames, and say the phase is already right.

So line 0 says 0, line 1 says -2, the steady state says -2, and later frames say
0. No single constant of these shapes can be all four, and the pairs each row
brackets are one M-cycle wide, so nothing here is a rounding artefact. The 2 dots
are real and their carrier is unidentified; what is excluded is that they live in
mode 3's length as a function of `SCX & 7`.

Both trims are wired into the FIFO renderer only (`gb_line_end` in ppu.nim). The
scanline renderer is not the shipping default and none of these ROMs score
against it.

## `SCX_FINE_LATCH_LIVE`

A store to SCX joins the line's fine-scroll discard for as long as the
discard still has pixels to throw away, instead of being measured against
a value sampled on one dot. Declared here, with the other pipeline
constants, because `GbFifoPpu` below grows a field only when it is on --
the field costs 0.21% of retired instructions on its own through object
layout, so `false` has to be byte-identical to not having built it.
Ships ON since 2026-08-11: its original -0.446% price was remeasured at
+0.027% in the tree that ships STAT_M0_FIELD_TAIL, which removed the
reason it was parked; +6/-1 on the suite, and SCX_FINE_LATCH_WRAP below
rides inside its window for +7 more.

The derivation, the two-sided evidence and the price are all at this
constant's note in gb/fifo_ppu.nim.

## `SCX_FINE_LATCH_WRAP`

Dots the fine-scroll discard costs when a mid-line SCX store lands AFTER
the discard has already walked past the new `SCX and 7`. 0 is off; 8 is
one whole pass of the eight-slot window. Requires `SCX_FINE_LATCH_LIVE`,
whose window this rides inside, and grows a field of its own.
Ships at 8 since 2026-08-11: the discard is a three-bit SLOT COUNTER
compared each dot against the live `SCX and 7`, and a slot-7 miss wraps
into a whole further pass -- which is what "SCX banging" abuses. Bracketed
as a strict local maximum by whole-suite sweep (6/7/8/9/10 ->
4049/4050/4051/4050/4050) and by scx_m3_extend's `_ds` pair, a
twelve-store banging ROM whose 3->0 edge lands in (329, 331] with this
rule producing 330.

The derivation is at this constant's note in gb/fifo_ppu.nim.

## `SCX_STORE_STALL_DOTS`

Dots the pixel pipeline stalls when a mid-line store to SCX LOWERS
`SCX and 7`. 0 is off. Declared here for the same reason as
`SCX_FINE_LATCH_LIVE`: `GbFifoPpu` grows a field only when it is on.

The derivation is at this constant's note in gb/fifo_ppu.nim; the short
form is that `gambatte/scx_m3_extend` says hardware's mode 3 is longer
after such a store, and its `_ds` member -- twelve stores on one line,
which is what SCX "banging" means -- prices one store at 8 dots.

