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


## `fifo_obj_abort` (OBJ_ABORT, OBJ_ABORT_LEAD, OBJ_ABORT_FLAG_HOLD, CGB_OBJ_ABORT)

LCDC.1 has just gone low while an object's stall is running: the fetch is
abandoned, the object dropped, and the rest of the penalty comes back. Pan
Docs' OBJ-penalty section names the case and stops there. Two dots come back
to the SHIFTER and one of those never reaches the FETCHER -- OBJ_ABORT_LEAD
and OBJ_ABORT_FLAG_HOLD, and the second section is why they differ.

---- Which dot the line gets back --------------------------------------

Four gambatte DMG families bracket it. Each is one ROM with ONE object at a
known OAM X, one mid-mode-3 `ld [c],a` moved by an M-cycle per step, and a
STAT read on a fixed dot -- so the step where the expected answer flips from
mode 0 to mode 3 names the dot the penalty stopped costing, to one M-cycle.

Traced with `-d:gb_m3_len -d:gb_m3_trace -d:gb_stat_read_trace`, LY 8 of each.
`T` is the object's trigger dot, `W` the write's, `R` the STAT read's; the
wait half runs T .. T+wait-1 and the object's own six dots T+wait .. T+wait+5.
The transducer is calibrated on this same set: the read at R reports mode 0
iff `len <= R - 85`.

  row (sprites/)                 OAM X   T   wait   W    R   wants
  late_disable_2                    8   94    5    97  257  charge >= 1
  sprite_late_disable_spx18_2      24  110    5   113  257  charge >= 1
  sprite_late_disable_spx19_2      25  111    4   113  257  charge >= 1
  sprite_late_disable_spx1A_1      26  112    3   113  257  charge <= 0
  sprite_late_disable_spx1A_2      26  112    3   117  257  charge >= 1
  sprite_late_disable_spx1B_2      27  113    2   117  257  charge >= 1
  sprite_late_late_disable_spx18_1 24  110    5   113  261  charge <= 4
  sprite_late_late_disable_spx18_2 24  110    5   117  261  charge >= 5
  sprite_late_late_disable_spx19_1 25  111    4   113  261  charge <= 4
  sprite_late_late_disable_spx19_2 25  111    4   117  261  charge >= 5
  sprite_late_late_disable_spx1A_1 26  112    3   117  261  charge <= 4
  sprite_late_late_disable_spx1B_1 27  113    2   117  261  charge <= 4

The FLAG's length is `charge = W - 1 - T`, the only offset the twelve accept,
pinned from both sides by a different pair on each side: `W - T` fails
spx1A_1 and late_late_spx1A_1 (one dot too much), `W - 2 - T` fails spx19_2
and late_late_spx19_2 (one too little), and at `W - 1 - T` no other row of
the 5,005 moves either way. The shipping pair (2, 1) reproduces the table
exactly, because 2 - 1 is the same 1.

spx1A_1 and the late_late `_1` rows are what say the WAIT half is abortable
too, not just the object's own six dots: spx1A_1's write lands ONE dot after
the trigger, three dots before that object's fetch would start, and the row
still wants the whole 9-dot penalty gone.

Both quantities are separate from the MIXER's copy of the same bit, which
reads it one stage the OTHER way (MIXER_PRIORITY_BACK).

---- Two instruments read different things -----------------------------

mealybug m3_lcdc_obj_en_change_variant measures the same abort with no STAT
read in the path: its handler pulses BGP black at a fixed dot near the end of
every line, so the x the black run starts at IS the shifter's position. Bands
8..15 calibrate the ruler exactly (run start = 161 - P for penalty P) and the
last two bands are the aborted ones:

  band  X   T    wait  W    run start   charge
   16  16  102    5   109      156         5      = W - 2 - T
   17  17  103    4   109      157         4      = W - 2 - T

One dot MORE refund than the twelve gambatte rows allow. As a function of
`W - T` alone, ten of the twelve accept either answer and the disagreement is
exactly one gambatte ROM (`spx19`, read at two STAT dots) against those two
bands, at configurations congruent to the dot:

  instrument                  X    T   wait  W    W-T   says
  gambatte late_late_spx19_2  25  111   4   117    6    charge >= 5
  mealybug variant band 17    17  103   4   109    6    charge  = 4

Same X mod 8, same wait, same offset into the object's fetch, opposite
answers -- no single refund satisfies both. What separates them is the
QUANTITY, not the number: gambatte reads the mode 3 -> 0 flag through STAT
and mealybug reads the pixels. So the shifter and fetcher get different
amounts, which is what `fetcher_retired` already says -- mode 3 ends when the
FETCHER is done, not when the last pixel leaves.

  * the SHIFTER gets both dots back (OBJ_ABORT_LEAD = 2). It needs only the
    BG FIFO, which is full, and 2 is not a new constant -- it is
    M3_PIPE_DELAY, the lead this file already charges the pipeline over the
    CPU's register view for the whole of every line.
  * the FETCHER gets one (OBJ_ABORT_FLAG_HOLD = 1). The VRAM cycle the object
    had already issued still owns the bus for its last dot, so the fetcher
    retires one dot behind the pixels and only the flag sees it. `m3_hold` is
    the field that already means this (added for LY0_PIPE_MCYCLES).

Each half is refused on its own, whole suites on this base:

  lead  hold   gambatte   mealybug DMG   what fails
     1     0     3818        552580      variant bands 16/17, 16 px
     2     0     3816        552596      spx19_2 and late_late_spx19_2
     2     1     3818        552596      nothing

At (2, 1) the whole gambatte suite is identical row for row to (1, 0) -- the
flag's length on an aborted line is `W - 1 - T` either way -- and the
variant's DMG row goes to 0 wrong pixels. The mealybug CGB set does not move.

Caveat: (2, 1) is two numbers against two instruments, and no third ROM
separates it from "one of the two instruments is a dot out". What would
settle it is a mealybug-style PIXEL ruler for the gambatte geometry -- the
`_2` rows re-cut with a BGP pulse instead of a STAT read. Until then the pair
is preferred because it is the only setting costing nothing on either side.

---- The CGB does not do this ------------------------------------------

Same cart, write and objects, different console: the variant's `_cgb_c`
reference gives those two bands the FULL 11- and 10-dot penalty, so it is
pixel-exact with the cancel compiled out and 288 px out with it in. Hence
CGB_OBJ_ABORT = 0.

That one row cannot separate "the CGB has no cancel" from "the CGB's LCDC.1
reaches the object fetcher four or more dots later than the DMG's" -- at
W = 109 those bands have three stall dots left, so any latency of 4+ hides
the cancel just as completely. Every other CGB row that could tell them apart
is double-speed, where this tree is already out for unrelated reasons.

The object is dropped rather than re-armed because `lx` has not moved:
leaving it in the list would re-trigger it the instant LCDC.1 came back, and
gambatte's sprite_late_enable_spx18..1B set it back a few M-cycles later on
exactly this line. One `delete` on a path at most one object per line reaches.

## The mixer tail (MIXER_PRIORITY_BACK, MIXER_PALETTE_BACK, MIXER_TAIL_DOTS, MIXER_TAIL_HBLANK, MIXER_DOT_LAG)

---- The mixer is a TAIL, and it runs behind the FIFO pop -------------------

A register the FETCHER reads is sampled on the dot of the VRAM read that uses
it. A register the MIXER reads is sampled one or two dots LATER than the dot
the pixel it colours left the FIFO, depending on how far down the tail it is
read. Two stages, and the rows separating them are 8 apart in the same suite:

  +1  LCDC's priority bits -- OBJ enable, BG priority in CGB mode; the
      BG-vs-OBJ decision (sprite_wins).
  +2  BGP / OBP0 / OBP1 -- the shade lookup, one stage after the decision that
      picks which of them to look in.

m3_lcdc_obj_en_change gives the first stage exactly, and is the cleanest
instrument in the suite: nineteen objects, one per 8-line band, each hanging
off the left edge at OAM X = 1..18, and a single LCDC write clearing OBJ enable
a few dots into mode 3. Each band asks "which is the last object pixel the
write does NOT suppress". All 60 of the frame's wrong pixels were one answer:
the object pixel emitted on the dot immediately before the write's own dot
survived here and does not on hardware -- at both write dots and all nineteen
bands. m3_obp0_change gives the second, the same objects against two OBP0
writes: its write lands on dot 109 of every band, and with the priority stage's
dot the pixel emitted on 108 comes right and the one on 107 does not. At two it
is pixel-exact.

Later at the mixer makes a write's effect appear EARLIER on screen, which reads
backwards until the stages are drawn out: the pixel popped on dot D is coloured
on D + n, so it sees every write live by D + n.

None of that adds stages to the dot loop. Registers only change at an M-cycle
boundary, so "the mixer is n dots late" differs from "the mixer is on the pop's
dot" in one place: a write also reaches the n pixels emitted before it. Redoing
those from the WRITE path costs the mode 3 loop one eight-byte store per pixel
(the FIFO entries the mixer still holds, indexed by the pixel's parity so two
stages cost what one does) and nothing else. Measured against
`-d:MIXER_DOT_LAG=0`, min of four runs: +0.35% retired instructions on blargg
cpu_instrs, +0.51% on cgb-acid-hell (LCDC every eight dots, the worst case).

Not M3_PIPE_DELAY = 3, which reaches the first stage's dot but moves the
FETCHER too, and the fetcher is already where hardware has it. Mealybug DMG,
wrong pixels of 23040:

  row                          before    PIPE_DELAY=3
  m3_lcdc_obj_en_change          60         2     mixer-read rows, all better
  m3_obp0_change                 74        42
  m3_bgp_change                1508       798
  m3_bgp_change_sprites        1044       344
  m3_lcdc_obj_en_change_variant 380       212
  m3_scx_high_5_bits              0        41     fetcher-read rows, all worse
  m3_scx_low_3_bits               0       324
  m3_scy_change                 417      2157
  m3_lcdc_tile_sel_win_change   106      1028
  m3_lcdc_bg_map_change         192       444

The split IS the result: every mixer-read row wants the extra dot and every
fetcher-read row refuses it, which says the two stages are a dot apart rather
than the pipeline being a dot out.

The two stages used to ship on structure alone, because the ~800 pixels
m3_bgp_change and m3_bgp_change_sprites had left were a second mechanism and an
unnamed residual is not a vote. Both names have since been found and both are
nearby rather than in the stage count: MIXER_PALETTE_OR (the transition pixel)
and MIXER_TAIL_HBLANK (the line end, below). With them those two rows prefer
TWO by 806 and 624 and the palette vote is unanimous.

---- The tail does not stop at the mode 3 -> 0 edge ------------------------

The guard below used to be "mode 3, or nothing", one dot too strict, and
m3_bgp_change's own handler says so. It writes BGP seven times per line and
dingbat's trace puts the writes on dots 81, 97, 109, 169, 181, 241 and 253; the
reference's run-lengths put the edge each write draws at exactly `dot - 96` for
all six that land inside mode 3. Mode 3 ends on dot 252, so the seventh write is
on the FIRST DOT OF MODE 0 -- and the reference draws its edge at x = 157 all
the same, three-valued, with 158 and 159 taking the new value cleanly.

So the rule the six measure -- a write on dot D reaches every pixel from
`D - MIXER_PALETTE_BACK - 94` up -- does not stop at the mode flag, and cannot:
the shifter emits one pixel per dot and the tail latches a shade two dots after
it leaves the FIFO, so on dot 252 two pixels are still inside the tail and one
(159) is not yet emitted. The mode flag is a statement about the FETCHER
(fetcher_retired), and the fetcher being done is exactly why those last pixels
are safe to keep clocking: no VRAM read decides them any more.

What changes is OURS, not the model's. `lx` stands in for the dot through the
whole of mode 3 -- one pixel per dot, stalls included -- but `fifo_burst_tail`
emits the last `m3_lead` pixels ALL ON THE RETIRE DOT, the one dot of the line
where it does not. Two accounting consequences:

  * the position must keep counting after `lx` has stopped. `tail_dot0` is
    latched at the burst as `cycle_counter - lx`, so the position on any later
    dot reads back as `cycle_counter - tail_dot0`. No edge, lock or STAT
    behaviour moves -- this is a subtraction on a register write, not a dot;
  * the pixels the burst decided EARLY are in the write's future, so a write in
    the tail must reach FORWARD too. On dot 253 the position is 159: 157 is the
    far end of the tail (the `old or new` pixel), 158 is inside it, and 159 has
    not been emitted at all -- on hardware it takes the new palette because it
    is emitted after the write, and here because the recompose sweeps to the end
    of the line. Hence a span, not a countdown.

The ring of held pairs is MIX_HOLD deep for the same reason: the deepest stage
plus the lead, exactly the four columns 156..159 a write on dot 252 or 253 can
name.

---- Clocked in dots, not pixels, and written where the shifter STOPS -------

Counting the reach back from `lx` is right for as long as the shifter takes one
pixel per dot, which is every dot except an object fetch and the tail burst.
mealybug's two `_sprites` rows stop the shifter under a write and say DOTS: a
write reaches a pixel iff that pixel left the FIFO within `back` DOTS, so an
object fetch drains the tail rather than freezing it. Bands and arithmetic at
MIXER_TAIL_DOTS in gb.nim.

The obvious implementation -- note `cycle_counter - lx` on every emitted pixel
-- costs +5.02% of retired instructions on Pokemon Crystal
(tools/gbppu/counters.sh, min of four a side). The dot loop sits on clang's
inline threshold (docs/gb_oam_dma_cost.md's cliff, the same one that makes ONE
extra branch in tick_shifter +1.7%), so nothing new may go in it.

Nothing has to. `cycle_counter - lx` cannot change while the shifter takes one
pixel per dot, so it only needs writing where the shifter STOPS, and every such
place is already a cold branch running once per stall: an object fetch
(mixer_note_stop in tick_shifter), a BG FIFO reset -- the line's start and a
mid-line window restart (fifo_reset_bg) -- and the tail burst at the retire dot.
Each notes the dot base of the run it interrupts plus the `lx` the next run
starts at, which answers both of the recompose's questions: while stopped the
position is `cycle_counter - tail_dot0` and the tail drains under it, and while
running it is `lx` with nothing older than `mix_run` reachable.

The price is that mixer_tail_front must TEST for the stall instead of reading it
off the arithmetic, and one of the three is not a flag -- see the guard there.

## `obj_yields_to_window` (the window/object tie)

Does the object the shifter has just found have to wait for the window's
start, instead of the other way round?

---- The two triggers are ordered by COORDINATE, not by the dot ----------

The window starts at pixel `WX - 7` and an object's trigger pixel is `X - 8`.
Every shifter event happens in coordinate order, so an object whose column is
LEFT of the window's first column is fetched before the window starts and one
to the right after. What is special here is that the object test above is a
`>=`, not an equality: an object at OAM X 1..7 has a trigger pixel of -7..-1,
which `lx` never takes, so it is noticed on the shifter's first dot -- the
same dot a WX = 7 window is noticed on. That collision is an artifact of the
clamp, and the object-first order decides the resulting tie the wrong way.

`lag` (below) is that displacement: `lx + 8 - X` is 0 for an object whose
column IS this pixel and 1..8 for one already past. So:

  lag > 0   object's column is left of the window's  -> object first
  lag == 0  same column                              -> window first

Only the second line changes anything. Resolving the tie the other way for
BOTH cases is refused by hardware -- m3_lcdc_win_map_change goes 34 wrong
pixels to 318, because it moves the seven left-hanging objects too.

---- What pins the `lag == 0` line ---------------------------------------

mealybug m3_lcdc_win_map_change and m3_lcdc_tile_sel_win_change both run
WY = 0 / WX = 7 with one object per 8-line band at OAM X = band, so band 8 is
the one line group where an object's column is the window's column. Both
toggle one LCDC bit for 8 dots at a fixed dot (105..112), so each band reads
out which fetch phase the PPU was in across those dots. Band 8 says the window
went first:

  * win_map_change (read at the tile-map fetch): band 8's reference has NO
    black tile on the line, as do bands 9..15 where the object is
    unambiguously after the window, because the object fetch stalls the
    fetcher across the whole write. Object-first put our first window map read
    at dot 107, inside the write, painting x = 0..7 black over the object.
  * tile_sel_win_change (read at the two bitplane fetches) is sharper because
    it resolves the write to a single dot. Band 8's reference is a WHITE
    window tile at x = 0..7 and colour 2 at x = 8..15 -- one tile whose low
    bitplane came from $9000 and whose high came from $8000. Window-first puts
    window tile 1's two bitplane reads on dots 104 and 106 with the write at
    105, exactly that mix; object-first has no fetch there at all.

Both rows go to 0 wrong pixels and no other mealybug row moves: `X == WX + 1`
on the line the window starts is the whole of it.

---- The two neighbouring spellings, both measured out --------------------

The tile_sel row pins this to ONE dot and refuses both variants either side,
which is what makes the deferral a real edge rather than a knob:

  * "the object pays no wait, having been pending before the window
    restarted" (pre-charge `obj_tile_fx` over the restart, 6 dots instead of
    11). Mealybug does not move -- it does not measure the penalty here -- but
    gambatte loses the three other window/object ties it fixes
    (window/late_disable_spx10_wx0f_2 on both devices,
    sprites/space/1pos8_8pos9_wx08_m3stat_ds_1,
    10spritesPrLine_wx7_m3stat_ds_1). The object DOES re-pay the wait.
  * "the object starts its stall on the tie dot, concurrently with the
    window's restart". Refused by the pixels: win_map_change 34 -> 64 and
    tile_sel_win_change 98 -> 64. The BG fetcher only runs for the WAIT dots
    (tick_sprite_fetcher), so starting the stall on the tie dot freezes the
    window's FIRST fetch half-done and pushes its second tile's map read into
    the write window, painting x = 8..15. The window's first tile must be
    pushed before the object's stall begins.

The pipeline says the same thing: an object is merged onto the BG FIFO entry
it will be drawn over, and a window start empties that FIFO and refetches it.
At the same pixel the fetch is upstream of the merge, so the refetch has to
happen before the object has anything to merge onto. A left-hanging object was
merged a pixel or more earlier and survives, because a window start does not
clear the OBJ FIFO -- which is why the glyph is still drawn over the window in
bands 1..7 of both references.

---- What it costs -------------------------------------------------------

Mode 3 gets longer whenever the object would have been charged against the
tile the window discards: it is now charged at column 0 of the window's first
tile, Pan Docs' 11-dot case. On the mealybug lines that is a no-op and
gambatte's three mid-line ties go green. At WX = 166 -- the window's first
pixel is the line's LAST -- it is +10 dots, and that is where the rule is
bought: eight gambatte rows red (m0enable 153 -> 147, and
window/m2int_wxA6_spxA7_m0irq_2 on both devices) against five green, net
3781 -> 3776.

That corner is a device split this tree does not carry, not this rule
misfiring: hardware wants 180 dots on DMG and 190 on CGB for the same frame,
and 190 is what this produces. The split is already there WITHOUT an object --
window/m2int_wxA6_m3stat and its `_scx2_`/`_scx5_` arms have DMG and CGB
expectations one and two M-cycles apart and this tree gives the DMG number to
both. Until the window-start cost at the last pixel is modelled per device,
every wxA6 row is decided by which side that one number sits on, and no
setting of THIS rule moves it.

Restricted to the window's START: `win_lx` also carries the re-trigger point
while the window is already the fetch source, and that branch can decline to
fire (it is gated on the fetcher's phase); yielding to an edge that then does
nothing would park the shifter on this pixel for the rest of the line.

And restricted to a pixel that HAS a pixel after it. On x = 159 there is
nothing for the object to queue behind -- the line's last fetch is the
window's restart (CGB_WIN_TAIL_LAST) -- so an object deferred there is
deferred past the end of the line. gambatte measures that corner directly
(`window/m2int_wxA6_spxA7_*`, `m0enable/enable_wxA6_2x_spxA7_*`) and its four
mode-0 interrupt rows want 180 dots on both devices: 174 for the window start
plus the object's own six, charged where the object is. Deferring here charges
it on the far side and gives 190, taking six of those rows red.

## `M3_PIPE_MCYCLES` / `M3_PIPE_DELAY`

How far the mode-3 pixel pipeline lags the CPU's view of the PPU registers, in
CPU M-cycles. Injected as idle dots at the head of mode 3, moving the whole
fetch/shift pipeline later against the CPU clock without moving a mode boundary
(fetcher_retired keeps the flag where it was).

M3_PIPE_MCYCLES ships at 0 and is now a diagnostic, not a fix. The M-cycle the
measurement below found was real but was never the pipeline's to pay: it was the
CPU write landing an M-cycle late. mem_write now commits a write's byte at the
START of its M-cycle, where its own VRAM/OAM lock is already decided, and the
residual this constant absorbed is gone -- turning it up double-counts. The
derivation is kept because it is the instrument for re-deriving the fetch phase.

---- Why an M-cycle and not a dot count -----------------------------------

A CPU write reaches the bus once per M-cycle, and dingbat used to run the
M-cycle's PPU dots BEFORE handing the byte to write_byte, so a write committed
at the END of its M-cycle. The locks disagreed: a write was admitted on the
LATCHED mode (the mode at the START of the M-cycle) where a read is admitted on
the live one. Lock and data are one event on hardware, so the data commits at
the start too, and the pipeline was one M-cycle behind purely because the write
was.

One M-cycle is 4 dots at normal speed and 2 in double (Pan Docs, "Dots"), which
is why the lead is latched per line from `current_speed` rather than being a
constant -- and that factor of two is what identified the quantity.

gambatte/bgtiledata (34 rows) and bgtilemap (40 rows) are four ROMs per SCX
whose only difference is a mid-line LCDC write moving one M-cycle, each with a
reference PNG, so the boundary they draw IS the staircase
`first affected tile = 8*ceil((write_dot - c)/8)`. Sweeping the lead in DOTS
over 0..8, scoring rows 16..143 of every row in both families:

  lead (dots)   0      1      2      3      4      5..8
  single speed  61440  28672  28672  0      0      61440
  double speed  11264  0      0      11264  11264  17408+

Two disjoint windows -- {3,4} dots single, {1,2} double -- so no constant dot
count passes both, which is the shape of a one-M-cycle quantity. Solving
`{3,4} - k = {1,2} - k/2` gives k = 4 and only 4, the same answer the locks
give. Both windows then become {-1, 0} and the residual dot term is 0.

---- M3_PIPE_DELAY: the speed-independent remainder, and it is 2 ----------

It used to ship at 0 on the reasoning that the M-cycle term was the whole
offset. It was not: the other two dots were absorbed by the BG fetcher's step 4
sitting at the head of its cycle instead of the tail (see the early push in
tick_bg_fetcher), which put every VRAM read two dots late and hid a pipeline two
dots early. Fix the fetcher and the two dots have nowhere to go.

What pins it to 2 rather than to whatever scores best: it is exactly the two
dots the fetcher's padding moved, and the row that reads it back has no objects
at all -- mealybug m3_bgp_change is BGP written across mode 3 and applied at the
SHIFTER, so it sees the pipeline's phase against the CPU and nothing else
(87.3% -> 93.5% DMG, 90.6% -> 96.1% CGB, on the lead alone). m3_window_timing
agrees (96.9% -> 98.7%). Swept 0..4 on the fixed fetcher:

  lead     0      1      2      3      4
  gambatte 3576   3591   3587   3560   3550
  mb DMG   504845 512369 516637 517664 515428
  mb CGB   1803036 1800695 1801757 1802795 1789657

1 and 3 each buy something and neither is the derived number; 2 is, and it is
what makes GBMicrotest's ppu_spritex_vs_scx table come out 153/153.

Whole gambatte suite, one build per cell:

  M3_PIPE_DELAY   2 (ship)   0
  total             3618     3596
  window             322      303
  scy                  9        3
  sprites            393      397
  bgtilemap            2        4
  bgtiledata           2        1
  m0enable           153      151

+22 net: window +19, scy +6, bgtiledata +1, m0enable +2, against bgtilemap -2
and sprites -4. (An earlier note claimed "scx_during_m3 34 -> 31" as well; that
does NOT reproduce -- the family scores 31/141 at both settings.) What remains
is the six bgtilemap/sprites rows whose mid-line write lands in the two pixels
the tail burst decides early.

---- What the lead machinery costs ----------------------------------------

A nonzero lead compiles in a per-line head delay and turns fetcher_retired from
one compare into five, on the mode 3 dot loop -- ~25,000 dots a frame, inside a
proc mem_read and mem_write are inlined into. Done naively that measured +5.51%
of retired instructions on Pokemon Crystal, most of it not the branches but 52
generated opcode bodies crossing clang's inline threshold (the cliff in
docs/gb_oam_dma_cost.md).

It shipped at +0.83% / +0.72% (Link's Awakening DMG / Pokemon Crystal against
`-d:M3_PIPE_DELAY=0`, which compiles the mechanism out). Four changes take it to
+0.22% / +0.12%, each marked at its site: fetcher_retired's early-out folds the
lead to an immediate when the M-cycle term is off; the head delay is spent in
ONE step above the dot loop rather than tested inside it; the tail burst is
{.inline.} again now the mode 3 branch is settled (-0.11%); and `m3_delay` is a
uint8 so its once-per-M-cycle test is `ldrb`+`cbz` (-0.08%).

What is left is a floor, not slack: the +0.22% on DMG is ~0.19% of byte test
(one `ldrb` and one `cbz` per mode 3 M-cycle, ~6,200 a frame) and essentially
nothing else. An object-free line otherwise pays one compare per dot --
fetcher_retired's early-out against an immediate, which clang folds into the dot
loop's own `lx` test -- plus a two-dot burst per line; lines with objects pay
nothing on top.

Two measurement traps, each of which cost this change a wrong answer before it
was understood (see docs/gb_oam_dma_cost.md):
 * `ri_instructions` includes kernel work charged to the process, so a run on a
   loaded machine reads HIGH -- 0.5% at load average 100, bigger than every
   number here. Take the MINIMUM of four or more runs per arm and check the
   minima agree to ~0.01%.
 * Two builds of the SAME source in different directories differ by up to 0.25%
   (the nimcache path reaches the generated C, and `_uNNNN` renumbering with
   it). Both arms of an A/B must be built the same way.

---- Why moving the PIPELINE was the wrong half --------------------------

The lead is injected at the HEAD of mode 3 and paid back by retiring the fetcher
`m3_lead` pixels early at the tail, so mode 3's length is unchanged. That is
exact everywhere except the last `m3_lead` pixels of a line, where a sprite or
window fetch can still stall the shifter: the flag then wants to go up mid-fetch
and neither "retire before the fetch" nor "retire after it" is that dot.
Measured at 1: gambatte 3253 -> 3256 and thirteen mealybug/age rows up, but
m3_scx_low_3_bits 100% -> 98.6% and gambatte sprites -2, window -2,
enable_display -3, m0enable -1 -- every one a WX=166 / OBJ X=166 /
SCX-at-H-Blank row, i.e. the tail accounting.

Moving the WRITE instead buys the same thirteen rows with none of that tail,
because the pipeline never moves. Same tree, same day: gambatte 3253 -> 3311,
sprites +3, window +4, m0enable +4, enable_display unmoved, and
m3_scx_low_3_bits stays green (its latch moved to the fetcher; see
fifo_sample_smooth_scroll's caller).
const M3_PIPE_MCYCLES {.intdefine.} = 0
const M3_PIPE_DELAY {.intdefine.} = 2

## `tick_sprite_fetcher` / `OBJ_BG_RUN` (which dots the BG fetcher may run on)

One dot of an object fetch. Returns true if this dot was the object's -- the
shifter is stopped for the whole of it -- and false for the one tail dot the
shifter has back but the BG fetcher does not (OBJ_BG_RUN = 4).

A return value rather than a call to tick_shifter from here: tick_shifter is
the mode 3 dot loop's body, and a SECOND call site stops clang inlining it
into fifo_pipeline_dot, which measured +0.9% of retired instructions on
Pokemon Blue for a dot that happens at most once per object.

Only the number of dots it lasts varies -- see the trigger in tick_shifter.

The BG fetcher runs for the WAIT and is stopped for the object's own fetch:
the two halves of the penalty read literally. The wait exists because a BG
fetch is in flight and must finish; the six dots after it are the object's own
VRAM reads, which the BG fetcher cannot overlap because there is one address
bus. Neither half reaches the BG FIFO -- the shifter is stopped, so the FIFO
cannot empty and try_push_bg_pixels cannot fire -- which also keeps `fetcher_x`
still. The fetcher parks on fsPushPixel and re-locks to the FIFO on the next
tile boundary, so mode 3's length is exactly the penalty with nothing added.

---- This line was accused of the object families' residual; it is clear ---

Until 2026-08-03 a note here said these wait dots should not run at all:
m3_scy_change's eighteen per-object bands were pixel-exact wherever the wait
term was 0 and ~960/1280 wherever it was not, and the only thing that moves
the fetcher during a penalty is this line. The reading was wrong, and how it
was settled is worth keeping, because a whole-frame percentage cannot do it.

GBMicrotest ppu_spritex_vs_scx.gb is the instrument: 153 cells of "how many
dots does one object at OAM X cost at this SCX", asserted against hardware,
read back as dots by `tools/gbppu/objtab.py` and differenced against the same
build's no-object line so the mode 3 edge's constant offset cancels. 79 of the
153 were wrong with the shape `+1 dot wherever (X + SCX) mod 8 >= 4`: a STALL.
The fetcher came out of the penalty too late to have the next tile ready.

That is the opposite sign to what the picture wanted -- the bands wanted the
fetcher frozen harder, the dots wanted it frozen less -- because both were
reading a third thing: the fetch cycle's own phase. A push taken at
Get-Tile-Data-High used to fall through the Sleep/Push steps it had already
served, putting the two idle dots at the HEAD of the next cycle where hardware
has them at the tail, leaving every VRAM read two dots late and exactly
cancelling a real two-dot lead of the pipeline over the CPU's register view.
Fix the push (tick_bg_fetcher), charge the lead where it belongs
(M3_PIPE_DELAY = 2), and the object families come right WITHOUT this line
changing: objtab.py 79 -> 0 mismatched cells, m3_scy_change 92.6% -> 98.3% DMG
and 81.4% -> 97.2% CGB, its four broken bands ~960 -> 1261-1279 of 1280.

---- The four candidate rules, and why none of them is the answer ---------

On the fixed phase all four give objtab.py 0/153 and are indistinguishable on
the scored suites (gambatte / mealybug DMG px / mealybug CGB px):

  run for the wait dots          3614  517987  1814452
  run for the whole penalty      3614  518293  1815437
  freeze completely              3615  517786  1813590
  step 4 only                    3615  517541  1813120

A quarter of a percent apart on 23,040-pixel frames, one row apart on 5,005.
("Run for the whole penalty" stays out whatever it scores, because it puts the
BG fetch and the object fetch on the address bus at once.)

What the mealybug SOURCES say is sharper than any of the four
(docs/gb-mealybug-sources.md): on hardware an object fetch NEVER lands between
a background tile's two bitplane reads. m3_lcdc_tile_sel_change reads that out
directly -- its LCDC pulse is 8 dots wide and its 18 bands each move the fetch
phase, so every band reports the pair (TILE_SEL at plane 0, TILE_SEL at plane
1) as a shade, and the reference never reports a pair more than 2 dots apart.
Under rule 1 the two reads come out 8 dots apart on 13 of the 18 bands,
because the wait dots let a NEW fetch start and then freeze it mid-tile. Rule
3 ("finish the fetch in flight") does not fix it either, because on the failing
bands the fetcher had just pushed and there is no fetch in flight.

---- Rule 4 (shipping): the object fetch goes at a TILE boundary, and the
---- object decides which one, not the fetcher's phase --------------------

Same ROM, read as a shade per band. With the pulse as the dot window
W = [105, 112] and the object-free schedule as tile n's B/0/1 reads on dots
8n+88, 8n+90, 8n+92 (n >= 1; tile 0's are 90/92/94):

  X = 0..7    the pulse falls on the fetch of the tile displayed at x=8..15
  X = 8..15   ...on the fetch of the tile at x=16..23, undisturbed
  X = 16, 17  ...on the fetch of the tile at x=16..23, undisturbed

So the penalty is inserted after the fetch of tile `floor(X / 8)`, while The
Pixel of an object at OAM X sits in tile `floor(X / 8) - 1`. The boundary the
object takes is the one at the END of the fetch that was in flight while The
Pixel's own tile was being displayed -- the fetcher runs a tile ahead, and Pan
Docs' "waiting for the BG fetch to finish" is that fetch. A background tile's
three reads are never split.

Two objects can be in identical FETCHER states at the trigger and still take
different boundaries, which is why no rule phrased on `fetch_counter` works:
X = 0 and X = 8 both trigger on the dot the first push fills the FIFO, both
cost 11 dots, and both leave the fetcher at counter 0 -- yet the reference
gives band 0 shade 3 (both planes read inside W) and band 8 shade 0 (neither).
The one thing that differs is the tile The Pixel is in, which is `idx` at the
trigger:

  idx >= 0  The Pixel is in the tile the FIFO is displaying, so the fetch of
            the tile after it is in flight. It runs inside the penalty to
            completion, then parks -- the shifter is stopped, the FIFO cannot
            drain, so it cannot start another.
  idx < 0   The Pixel is in the tile BEFORE it (an object hanging off the left
            edge, OAM X < 8). The fetch the object waits for has just this dot
            finished -- the trigger dot IS its plane-1 read, which filled the
            FIFO and let the shifter ask. So the object takes the bus from the
            NEXT dot for the whole penalty and the fetcher gets none of it,
            including one dot past the end of the shifter's stall: the stall
            runs t .. t+P-1 and the object's accesses t+1 .. t+P. That last dot
            is the `obj_penalty <= 0` tail below, and it is not padding --
            band 4 (OAM X = 4, P = 7) is shade 3 with it and shade 2 without,
            and is the only band separating the two.

Mode 3's length does not move either way, checked rather than hoped: neither
arm can make the fetcher LATE for a push. In the hold arm the shifter resumes
on t+P with a full FIFO and empties it on t+P+8, while the fetch resumes on
t+P+1 with its plane-1 read on t+P+6, two dots clear; in the run arm the fetch
finishes earlier than rule 1 left it, and an earlier fetch can only remove a
stall. ppu_spritex_vs_scx stays 0/153, and 1660 ROM/device runs over gambatte
sprites, oam_access, vram_m3, scx_during_m3, GBMicrotest and mealybug are
line-for-line identical under -d:gb_m3_len.

What it costs is the run arm's dots: the fetch happens inside the object's
stall instead of after it, so tick_bg_fetcher is called on up to six dots per
object that rule 1 skipped. Pokemon Blue +0.76% retired instructions, Shantae
+0.41%, Pokemon Crystal +0.01%. All of it is the rule and none the plumbing --
this file's shape with rule 1 forced back on measures -0.06%.

`idx < 0` needs no state of its own: `obj_tile_fx` is the tile the wait was
charged against (`fetcher_x - 1` when idx is negative, `fetcher_x` when not),
and neither can move for the duration of the stall, because fetcher_x only
advances on a push and a push needs an empty FIFO. So the two fields the
penalty algorithm already keeps ARE the question, at one compare on a path no
object-free line visits.

## `OBJ_PLANE_GAP` / `OBJ_PLANE1_LAG` / `OBJ_PLANE1_HEAD` / `CGB_OBJ_SIZE_LATENCY`

---- LCDC.2 is read ONCE PER BITPLANE, and the fetch's place in the penalty
---- decides which dots those two reads land on ---------------------------

`sprite_fetch_merge` runs on ONE dot and used to take the object's height from
LCDC.2 as it stood there, for both bitplanes at once. mealybug
`m3_lcdc_obj_size_change` and `_scx` refuse that, and are direct instruments:
BGP = $00 makes the background white, every object is tile $4C with OBP0 = $E4,
and objects stack at Y = $10, $20 .. $90 so each 16-line band is one object read
out as eight columns of raw bitplane. Both pulse LCDC.2 four times across mode 3
(8x8, 8x16, 8x8, 8x16), the first at a fixed dot, with `_scx` also driving
SCX = (LY >> 4) & 7 so each band meets the pulse at a different fetch phase.
Tile $4C is even, so the two heights differ only in the `or 1` for the lower
tile of an 8x16 object and the reference names the pair exactly. Against this
tree's merge dot M:

  ROM              band  object  M     reference  needs
  _scx             0, 8  X = 32  135   (16, 8)    lo <= 136, hi >= 137
  m3_..._change    0     X = 16  123   ( 8, 16)   lo in [101,125), hi >= 125
  m3_..._change    1     X = 33  148   ( 8, 16)   lo in [137,149), hi >= 149
  m3_..._change    1..3  X = 1..3 103/102/101  (16, 16)  BOTH reads < 101
  m3_..._change    8     X = 8   104   ( 8,  8)   both in [101,125)

With the reads OBJ_PLANE_GAP = 2 dots apart the first three rows have a UNIQUE
solution -- low plane on M, high plane on M + 2 -- forced from both sides.

The fourth row cannot be that and the fifth says why. X = 1..3 hang off the left
edge and are the `idx < 0` arm (OBJ_BG_RUN above): the trigger dot is the BG
fetch's own last read, so the object takes the bus from the next dot and its six
dots are the FIRST six of the penalty, not the last. All three trigger on dot 94
and want both reads before 101, which `t + OBJ_FETCH_DOTS` gives at any X --
the wait is spent AFTER the fetch on that arm, so the penalty's length changes
and the read dots do not. X = 8 is the same measurement from the other side and
makes the boundary a measurement rather than a choice: it is the first object
NOT hanging off the left edge and it wants the tail arm's dots (104 and 106,
8x8) where the head arm's (100, 8x16) would draw the other tile. So the split is
exactly `idx < 0` -- the split OBJ_BG_RUN = 4 derived from an unrelated ROM.

The CGB reads the bit three dots later. The same two ROMs as DMG carts on CGB
hardware are the suite's `_cgb_c` references and are the COMPLEMENT of the DMG
ones here: `_scx` band 0 (merge 135) is mixed on DMG and pure 8x16 on CGB, and
bands 4..7 (merge 138/139) are pure 8x8 on DMG and mixed on CGB. Solving those
six bands gives one offset -- three dots, on every one, with write and merge
dots identical between devices under `-d:gb_m3_trace`. That is
CGB_OBJ_SIZE_LATENCY. The head arm is insensitive to it (both settings put the
read before the ROM's first write), so it is applied to the dot, not the arm.

What is left over, and what these ROMs cannot say:
 * on the tail arm the six dots come out as M-3 .. M+2, one dot later than "the
   wait, then the fetch" places them. That dot is the same pipeline-over-CPU
   lead M3_PIPE_DELAY and OBJ_DMA_BUS_LEAD each carry a share of; it is measured
   here, not derived, which is why OBJ_PLANE1_LAG is a swept constant rather
   than an expression;
 * nothing here separates "the tile index's low bit is masked at the OAM read"
   from "at each bitplane read" -- every object in both ROMs is on the even tile
   $4C, so `tile and $FE` is a no-op. The whole address is recomputed per plane
   below, the simpler of the two and consistent with everything either ROM sees;
 * a second object at the same X re-arms the stall for a bare OBJ_FETCH_DOTS
   (the chain at the end of sprite_fetch_merge). Its six dots ARE its penalty,
   so it takes the tail arm's offset whichever arm the first object took; no ROM
   puts an LCDC.2 write inside a chained fetch.

Sweeps, mealybug matching pixels, one build per cell. DMG is 552,188 of 552,960
at the shipping settings and CGB 1,856,315 of 1,866,240; both columns move ONLY
the two obj_size rows at every cell.

  OBJ_PLANE1_LAG      0        1        2 (ship)   3        4
  DMG            552068   552143   552188     552098   552068
  CGB           1855880  1855955  1856315    1856285  1856110

  OBJ_PLANE_GAP            1        2 (ship)   3
  DMG                 552188   552188     552188
  CGB                1856285  1856315    1856135

  CGB_OBJ_SIZE_LATENCY     0        1        2        3 (ship)   4        5
  CGB                1855975  1856110  1856285  1856315    1855955  1855880

  OBJ_PLANE1_HEAD          4        5        6 (ship)   7        8
  DMG                 552188   552188     552188     552110   552110

The first three are strict optima pinned from both sides. The fourth is not:
the head arm's read only has to be before dot 101 and 4, 5 and 6 all are, so the
ROMs bound it from above at 6 and say nothing below. 6 is the structural value
-- the six-dot fetch starting on the dot after the trigger.

## `OBJ_FETCH_DOTS` / `OBJ_WAIT_SUB` (the OBJ penalty)

---- The OBJ penalty ------------------------------------------------------

Pan Docs, Rendering / "OBJ penalty algorithm", on the object about to be drawn
("The Pixel" is its leftmost pixel, transparent or not):

  1. Determine the tile (background or window) that The Pixel is within.
  2. If that tile has NOT been considered by a previous OBJ yet: count how many
     of that tile's pixels are strictly right of The Pixel, subtract 2, and
     incur that many dots (or zero if negative) waiting for the BG fetch.
  3. Incur a flat 6-dot penalty for fetching the OBJ's tile.

Both halves fall out of this renderer's own state:

  * the BG FIFO holds exactly the not-yet-emitted pixels of the tile being
    displayed, so at the trigger dot it holds The Pixel plus everything right
    of it. Step 2 is `fifo.size - 1 - 2` floored at 0, with no register decode
    -- right through a mid-line SCX change and through the window, both of
    which change which tile The Pixel is in without changing the FIFO;
  * "not considered yet" is `fetcher_x` differing from the tile the last wait
    was charged against. fetcher_x only advances on a push and a push cannot
    happen while an object has the shifter stopped, so every object landing in
    one displayed tile sees the same value.

An object at OAM X 0..7 hangs off the left edge, so The Pixel is in the tile
BEFORE the first on-screen one and the trigger dot is not its own; see the
`lag` term at the trigger.

Pan Docs' X = 0 exception ("always 11 dots regardless of SCX") IS a special
case and is spelled out as one below. It was once claimed to fall out for free,
which is true only at `SCX & 7 = 0`: The Pixel sits at index `SCX & 7` of the
tile before the first on-screen one, so the derived wait is `5 - (SCX & 7)` and
the derived penalty ramps 11, 10, 9, 8, 7, 6, 6, 6 over the residues. Hardware
does not.

Both terms swept independently against gambatte/sprites (476 rows), writing the
penalty as `FETCH + max(0, fifo.size - SUB)`:

  SUB        1     2     3     4     5
  FETCH=4   306   256   254   256   254
  FETCH=5   267   304   254   250   252
  FETCH=6   263   269  [391]  266   262
  FETCH=7   251   251   254   312   267
  FETCH=8   250   251   251   254   286

(6, 3) -- Pan Docs' flat 6 and its "minus 2" -- is the unique optimum and not
close: the 9-diagonal (everything that gets X = 0 right and the rest wrong)
tops out at 312. The pre-existing model was a flat 8 with no wait, the
bottom-right corner.

GBMicrotest `ppu_spritex_vs_scx.gb` is the hardware table: 306 assertions, one
object at OAM X 0..16 crossed with SCX 0..8, two per cell bracketing the end of
mode 3 to one M-cycle. It never writes $FF82 so the runner cannot score it, but
`tools/gbppu/objtab.py` reads its expectations back out of this tree as dots by
differencing against the same build's no-object line. Hardware:

  X \ SCX&7   0   1   2   3   4   5   6   7
     0       11  11  11  11  11  11  11  11
     1       10   9   8   7   6   6   6  11
     2        9   8   7   6   6   6  11  10
     ...      (each row the one above rotated right)

i.e. `6 + max(0, 5 - ((X + SCX) mod 8))` for X >= 1 and a flat 11 for X = 0 --
Pan Docs' algorithm plus its X = 0 exception and nothing else. All 153 cells
match as of 2026-08-03 (79 did not before).

Cancelling the object fetch mid-flight by clearing LCDC.1 is a separate rule
and NOT in this table (ppu_spritex_vs_scx never writes LCDC inside mode 3);
it is at fifo_obj_abort.

## `fifo_head_window` (WIN_LINE_START_LATCH, WIN_HEAD_ABSORB)

---- The head of a line that starts as a WINDOW line -----------------------

WX below WIN_LINE_START_WX puts the window's first pixel left of the screen, where
the shifter's equality can never reach it, so the whole line is fetched from the
window map from its first tile. Two things about that start were wrong, and
mealybug `m3_window_timing` measures both. It is a ruler, not a picture: WX = LY,
WY = 0, SCX = 0, BGP driven black at a fixed dot of every line, so the x at which
black begins IS the count of dots the head consumed before x = 0:

  WX (= LY)     0   1   2   3   4   5   6 ..  10   11  12 .. 16  17+
  reference     3   3   3   3   3   3   3 ..   3    4   5 ..   9    9
  was           9   3   4   5   6   7   8 ..   3    4   5 ..   9    9

The 17+ tail is the control: there the window starts right of everything the
write can reach, so 9 is what a line with no window head at all reads.

---- 1. WHERE WX is read (WIN_LINE_START_LATCH) ---------------------------

This ROM writes WX inside mode 3 -- the trace puts the write on dot 85 of every
line, and dot 81 of LY 0, whose handler is one M-cycle shorter (`line_0_fix`).
Reading WX at the mode 2 -> 3 edge therefore reads the PREVIOUS line's value,
which for LY 0 is the 144 left from the bottom of the frame: dingbat drew no
window on LY 0 and read 9 where the reference reads 3. So the read is AFTER 85.

The other side is `m3_wx_6_change`, which writes WX = 6 in mode 2 and WX = LY at
dot 93 with WY = 4: its reference draws NO window on LY 4 or 5, so the value the
decision sees there is still 6 and the read is BEFORE dot 93. The latch -- the
last dot of the throw-away fetch at the head of mode 3, dot 86, or 82 on LY 0 --
is the fetcher event inside that bracket, and the same event that already latches
the fine scroll two dots later. Only the dot changes: the throw-away fetch that
just ended read the BACKGROUND map, and every byte of it is overwritten by the
fetch this restarts.

---- 2. The window's OWN discard is absorbed (WIN_HEAD_ABSORB) -------------

`fifo_sample_smooth_scroll` seeds `lx` at `-(7 - WX)` so the window's first tile
lands on the right pixel, and this shifter charged a dot for every discarded
pixel. Hardware does not: the reference is FLAT at 3 across WX = 0..6, and 3 is
also what WX = 7..10 read -- lines whose window starts on screen and pays the
ordinary six-dot startup fetch. So the head costs the same six dots either way,
which is the ROM's own header sentence: it accounts for the entire WX-dependence
with "the 6 T-cycle window startup fetch" moving against a fixed write, and names
no other per-WX term. (The hardware photograph backs the reference: 86.2% of the
disputed cells and 100% of the cells above 2 sigma -- tools/gbphoto.)

It cannot be spelled as a smaller discard. Seeding `lx` at a flat -6 gets
m3_window_timing to 0 the same way and COLLAPSES three rows that are pixel-exact
today (`m3_wx_4_change` 23040 -> 12809, `m3_wx_5_change` -> 14731,
`m3_window_timing_wx_0` -> 22914), because the discard is what ALIGNS the
window's glyphs and carries the SCX term. So the discard stays and only the DOTS
move: they come back as `6 - (7 - WX)` = `WX - 1` idle dots at the head of the
window's own fetch -- FETCHER_ORDER's negative steps -- leaving mode 3 at 172 + 6
for every WX in 0..6, exactly the length WX = 7 already had.

WX = 0 needs no idle dot and gets none: its discard is already six (the `+= 1` in
the sampler, from `m3_window_timing_wx_0`'s stair), and `max(0, WX - 1)` is that.
The SCX term is deliberately NOT absorbed -- it is the throw-away fetch's own
discard, not the window's, and `m3_window_timing_wx_0` is pixel-exact with it
charged in full.

---- Two suites that never see a pixel say the same thing ------------------

The consequence is a MODE 3 LENGTH, so it is measurable with no reference frame,
and both length instruments agree:

  * GBMicrotest `win<WX>_a` reads STAT at cc = 257 wanting mode 3 and `win<WX>_b`
    at cc = 261 wanting mode 0. Hardware samples the mode bits at `cc - 2`, so
    mode 0 starts in [256, 259] and mode 3 is 176..179 dots -- for every WX in
    0..15, the whole family answering one bracket. Charging the discard on top put
    WX = 4 at 175 and WX = 5 at 174, outside it on the short side, with
    `-d:gb_stat_read_trace` showing both `_a` rows passing on a mode flag that was
    already 0 when the ROM read it. At 178 every WX is inside the bracket.
  * gambatte's WX = 3 length brackets go green, six rows on both devices:
    `window/m2int_wx03_m3stat_1`, `window/m2int_wx03_scx3_m3stat_1`,
    `window/late_wx_wx03_2` and `sprites/space/10spritesPrLine_wx{3,4,5}_m3stat_ds_1`.
    Nothing in that suite goes the other way.

## A window-start line still pays SCX & 7 (WIN_WX0_PHASE)

---- A line that STARTS as a window line still pays SCX & 7 ------------

`lx` starting negative is this renderer's discard: those pixels are
shifted out and not drawn, so each one is a dot. A line that starts as a
window line (WX < WIN_LINE_START_WX) discards `7 - WX` for the window's
own fine scroll -- and, until 2026-08-07, nothing at all for SCX, which
made mode 3 independent of SCX & 7 on exactly those lines.

mealybug m3_window_timing_wx_0 is the instrument, and it is a ruler: WX =
0, `SCX = LY`, and BGP driven black at a fixed dot of every line, so the
x at which black begins IS the count of dots consumed before x = 0, read
off once per scanline for all eight residues. Reference against ours,
SCX & 7 = 0..7:

  SCX & 7      0   1   2   3   4   5   6   7
  reference   11   9   8   7   6   5   4   3
  was         11  11  11  11  11  11  11  11     (no SCX term at all)
  is          11   9   8   7   6   5   4   3

The photograph backs the reference here (tools/gbphoto: 94.2% of the 652
disputed cells, one region, residual ratio 7.6x), and so does the ROM's
own header: "The stair pattern is visible due to the delay from the
lowest 3 bits of SCX, and due to window activating one T-cycle later when
WX = 0 and SCX > 0." Both terms are in that sentence; the second one was
already here with the WRONG SIGN (it read `+= 1`, i.e. one dot EARLIER),
which is invisible without the first because nothing else in the tree
moves SCX on a WX = 0 line.

So the discard for a window line is `(7 - WX) + (SCX and 7)`, plus the
documented extra T-cycle when WX = 0 and SCX & 7 > 0. The WX = 0 case
discards SIX for its own fine scroll rather than seven -- Pan Docs calls
WX = 0 unreliable and this renderer already carried both 6 and 7 for it;
what the stair adds is which of them goes with SCX & 7 = 0.

Cross-checks, all three of them independent of the row above:
 * gambatte window/m2int_wx03_scx5_m3stat_1 goes green on BOTH devices --
   a direct mode-3-length bracket at WX < 7 with SCX > 0, and the only
   gambatte family that holds one.
 * gambatte sprites/space/10spritesPrLine_wx0_m3stat_ds_2 goes green.
 * GBMicrotest win0_scx3_a/_b bracket it. `_a` reads STAT at cc = 261 and
   expects mode 3, `_b` at cc = 265 and expects mode 0, and hardware
   samples the mode bits at cc - 2 (see STAT_READ_LAG), so mode 0 starts
   in [260, 263] and mode 3 is 180..183 dots. This makes it 183 -- INSIDE
   the bracket, where the old 178 was outside it on the short side.

What it costs: win0_scx3_b itself goes red, at `0x83` against `0x80`.
That is not this rule being wrong -- it is the readback lag catalogued as
bucket 15 in docs/gb-failure-triage.md (we sample no earlier than cc - 5
where hardware samples cc - 2) becoming visible on one more row, because
the mode-3 end moved to where that defect shows. Same shape, same
signature and the same twenty siblings as win6_b next door.

---- The discard is `7 - WX` at EVERY WX, WX = 0 included (WIN_WX0_PHASE)

This used to carry a `+= 1 / -= 1` pair around `ppu.wx == 0`, which made
the WX = 0 discard six rather than seven when SCX & 7 was zero. That is
the right number of DOTS and the wrong PHASE: it puts the window's first
tile one pixel to the right of where hardware puts it, which is invisible
in every ruler ROM (they measure a black-x, i.e. a dot) and visible in
exactly one place -- a line whose window is turned OFF again partway
across, where the background resumes on the window's own tile boundary.
mealybug m3_lcdc_win_en_change_multiple_wx is that ROM (see
WIN_WX0_PHASE in gb.nim for the reading). The dot the pair was paying for
moves to the head, where the rest of the window's head budget already is.

## `SCX_FINE_LATCH_WRAP` / `SCX_STORE_STALL_DOTS`

---- SCX_FINE_LATCH_WRAP -------------------------------------------------

The window above is not the whole comparator. `gambatte/scx_m3_extend` --
the one bracket four rounds of the mode-3 campaign could not reach, and
which the window explicitly did NOT touch -- says a mid-line store can
make mode 3 LONGER, and this is the missing half.

---- The shape ----------------------------------------------------------

The discard is a three-bit SLOT COUNTER, not a countdown. It runs 0..7 from
the latch dot, and on each dot it compares its slot against the LIVE
`SCX and 7`. Equal -> the discard ends, which is the classic penalty and is
what the window above already models. Slot 7 with no match -> it WRAPS and
runs the eight slots again. So a store's effect depends on where it lands
against BOTH the old value and the new one:

  store's slot <= new F        the counter has not passed the new target,
                               it matches it -- the window above
  new F < slot <= old F        the counter has already walked past the new
                               target and can no longer match the old one:
                               it runs to 7, wraps, and matches on the
                               SECOND pass. Eight dots, and this constant
  slot > old F                 the match already happened; no effect

"The later the store, the bigger the extension" -- round 2's phrasing of
the bracket -- is the boundary between the first two regimes sweeping as
the store moves later.

---- What prices it, from our own rows ----------------------------------

`tools/gbscx/edgemap.sh` on the family, and the `_ds` pair is the whole of
it. Those two write SCX **twelve times on one line**, every six dots,
cycling the low bits 4,2,0,6,4,2,0,6,4,2,0,6 against a latched 7. They
bracket hardware's 3 -> 0 edge to (329, 331] where the shipping tree is at
259 -- **71 or 72 dots** -- and with this rule at 8 dingbat lands on
**330**, inside a two-dot window arrived at by twelve stores compounding.
Nine of the twelve wrap and three do not, which is what the mask is:

  * WITHOUT `and 7` every store after the first wrap measures against an
    ever-growing count, all twelve wrap, and mode 3 runs to 355 and off
    the end of the line. That is not a bug to hide -- it is exactly the
    runaway SameBoy's changelog calls "SCX banging", and hardware stops
    because a store that RAISES the target above the current slot can
    still be matched on the pass it lands in.

The single-store members then agree, and they are what brackets 8 rather
than merely admitting it. Swept whole-suite, one build per value:
6 -> 4049, 7 -> 4050, **8 -> 4051**, 9 -> 4050, 10 -> 4050. A strict local
maximum, and 8 is one whole pass of an eight-slot window rather than a
fitted number.

---- The one row it does not reach --------------------------------------

`scx_m3_extend_1 [dmg]`. Both CGB arms and the banging pair go green; the
DMG arm wants its 3 -> 0 edge 3-6 dots further still, and no wrap can
supply that (a second one is 8 and overshoots the bracket). It cannot be
paid by `STAT_M0_FIELD_TAIL` either, and that is settled rather than
assumed: `tools/gbscx/readidiom.py` says this ROM reads STAT with
`LDH A,($41)`, IO on its third M-cycle, so round 4's `STAT_M0_TAIL_MAX_MC`
rule excludes it by construction. The residual is therefore a DMG-only,
single-row, sub-M-cycle question about where that device's SCX store lands
against the latch -- which is a much smaller thing than the 11-14 dot
whole-family bracket it replaces.

## `SCX_FINE_BORROW` / `SCX_FINE_BORROW_DMG_LEAD` / `SCX_FINE_LATCH_LIVE`

const SCX_FINE_BORROW* {.intdefine.} = 1
Tiles the BG fetcher's map column drops when a mid-line SCX write lowers
`SCX and 7` below the fine scroll the line latched. 1 ships; 0 is the previous
model and the control arm.

---- The shape of the claim -----------------------------------------------

The BG fetcher is NOT addressed as "a tile index plus a scroll". It is
addressed by a SCREEN POSITION with the live SCX added, so SCX's low three
bits take part in the carry into the tile-address bits:

    column = ((SCX + 8*k - F) shr 3) and 31

where `k` is the fetch index on this line and `F` is `SCX and 7` as it stood
when the line latched its fine scroll (`scx_fine`, in
fifo_sample_smooth_scroll). `8*k - F` is the screen x the fetch is for.
Expanded, the two forms agree except in one case:

    SCX and 7 >= F   ->   k + (SCX shr 3)        the old model
    SCX and 7 <  F   ->   k + (SCX shr 3) - 1    the borrow

so nothing moves unless a write LOWERS the low three bits mid-line, and then
the column comes out one tile lower for the rest of the line. Spelled as the
difference rather than the sum, because the sum would have to re-derive
`8*k - F` from a counter this renderer keeps in tiles.

---- What derives it ------------------------------------------------------

gambatte's `scx_during_m3`, read as a displacement ruler rather than pass/fail
(tools/gbscx). Each ROM writes SCX three times per line off a mode-2 STAT
interrupt with the writes swept one M-cycle per step, and its background row
is aperiodic enough that the frame reads back as `screen x -> background X`.
The directory name is the three SCX values:

  dir          SCX and 7 per write   late writes that LOWER it   rows
  scx_0060c0        0, 0, 0                   none               all pass
  scx_0063c0        0, 3, 0             the third, when the      2 of 14
                                        second landed in the
                                        discard and raised F
  scx_0360c0        3, 0, 0                   the second         12 of 14
  scx_0363c0        3, 3, 0                   the third          14 of 14
  scx_0367c0        3, 7, 0                   the third          14 of 14
  scx_0761c0        7, 1, 0                   the second         12 of 14

The correlation is exact both ways: every failing row's disputed span follows
a write that lowers `SCX and 7`, every row with no such write passes, and
`scx_0060c0` -- the one directory that never changes the low bits -- is green
end to end. The error is always ONE TILE whatever the size of the drop (`3->0`
is minus three, `7->1` minus six, both exactly 8 pixels), which is what says
this is a carry and not a count.

The fine scroll itself does not move: after such a write hardware keeps
emitting on the OLD residue, so the disputed span is displaced by exactly 8 and
never by 1..7. That is the second half of the derivation -- `F` is a latch and
the borrow is taken against it, rather than the shifter re-discarding.

---- The device split, and the three rows that are all of it --------------

Three ROMs change ONLY the low bits, so they see the borrow with nothing else
moving, and they are the only rows in the tree that can separate the devices:

  ROM                     drop   DMG reference        CGB reference
  scx1_scx0_during_m3_1   1->0   no change at all     borrows at x = 63
  scx2_scx1_during_m3_1   2->1   no change at all     borrows at x = 62
  scx2_scx0_during_m3_1   2->0   borrows at x = 62    borrows at x = 62

Same ROM, dot and drop of one, and the consoles disagree; a drop of TWO borrows
on both. So the DMG's threshold is one pixel tighter and nothing else differs:
DMG borrows on `(SCX and 7) + 1 < F`, CGB on `(SCX and 7) < F`. That is
SCX_FINE_BORROW_DMG_LEAD, and as physics it says the DMG fetcher's screen
position sits ONE PIXEL further along at the moment the sum is taken.
Bracketed from both sides by this trio: at 0 the two `-1` rows go red on DMG,
at 2 the `2->0` row does, and the CGB arm is unmoved either way.

NOT `CGB_PIPE_MCYCLES` -- that is a whole M-cycle against MACHINE time; this is
one pixel inside the fetcher's own sum and invisible to every other row.

Two neighbouring shapes, each refused: "the discard re-arms and throws 8 more
pixels away" is refused by the residue (a re-armed discard would leave the line
emitting on the NEW `SCX and 7`, and every measured span keeps the old one);
"an extra tile is fetched" is refused by sign (the spans sit one tile LOWER,
i.e. the picture moves right, which is a borrow and not an insertion).

The window's own fetch is addressed from `current_window_line` and `fetcher_x`
with no SCX term, so it cannot borrow and is left alone. Written as an `ord`
term rather than an `if` because this is the mode 3 dot loop.

const SCX_FINE_BORROW_DMG_LEAD* {.intdefine.} = 1
Pixels the DMG's fetcher position leads the CGB's by inside the borrow
comparison above. Derived and bracketed there, off the three
`scxN_scxM_during_m3_1` ROMs. Subtracted into `scx_fine` at the latch so the
dot loop never sees it.

---- SCX_FINE_LATCH_LIVE ------------------------------------------------

Declared in gb.nim beside the type it grows a field on; this is its derivation.

The fine scroll is not sampled on ONE dot. A store to SCX joins the discard for
as long as the discard still has pixels to throw away, moving the line's fine
scroll and its own length with it. `false` is the old model, where the sample
and the discard shared a dot. Worth gambatte +6 / -1.

gambatte `scx_during_m3` sweeps one store across the head of mode 3 an M-cycle
at a time. Traced with `-d:gb_m3_trace`, dingbat latches at dot 88 on every line
but line 0, and the interesting stores land at dots 89 and 93. Whether hardware
lets them move the fine scroll depends on the fine scroll the line already had,
which is what says the window is the DISCARD rather than a fixed number of dots:

  family      F   store 89   store 93   hardware's residue after it
  scx_0063c0  0     no          no      keeps 0 -- there is no discard
  scx_0367c0  3     YES         no      takes 7, the whole of `$67`
  scx_0360c0  3     YES         no      takes 0, the whole of `$60`
  scx_0761c0  7     YES         YES     takes 1, the whole of `$61`

Read down the `store 89` column and a fixed window is refused outright: same dot,
same offset from the same latch, and `scx_0063c0` says no while the other three
say yes. The only thing separating them is `F`, which is exactly how many dots of
discard are left. Read across `scx_0761c0` and the window is at least 5 dots long
at `F = 7`, which no capped spelling reaches without also opening it at `F = 0`.

So there is no constant here: the condition is `lx < 0`, which is what a negative
`lx` already means. Swept as a capped `min(N, F)` first, the score saturates at
N = 3 while the residues keep falling to N = 7 (`scx_0761c0/scx_during_m3_4`,
6292 wrong pixels at N = 3 against 2145 at N = 7, with the DMG/CGB asymmetry
there vanishing) -- the data wanted the cap gone.

The one row it costs is `enable_display/ly0_late_scx7_m3stat_scx1_2 [dmg]`, a
mode-3 LENGTH row on line 0, where this tree already carries a one-M-cycle
difference (LY0_PIPE_MCYCLES, and a latch at dot 84 rather than 88). Its siblings
`_scx0_2` and `_scx0_3` stay green, so this is not the mechanism being wrong in
general. The obvious repair was built rather than argued away and is REFUSED:
widening the window by that M-cycle on line 0 alone -- the shape
LY0_PIPE_MCYCLES predicts -- scores 3998/5005 against 4009, losing eleven
`scx_during_m3` rows to buy the one back. So line 0's latch is early by something
that is not this window's length, and the row is left red with its cause named.

Price: the +0.446% this note was once parked on was an object-layout artefact of
a neighbouring field. Re-benched in the tree that ships STAT_M0_FIELD_TAIL --
whose `obj_dots_line` sits in the same object-scratch block -- the same flag on
the same ROM reads +0.027% (blargg cpu_instrs, 2400 frames after 300 warmup,
four interleaved runs, `cycles=` identical in all eight).

## `OAM_SCAN_DMA_LOCK` / `OBJ_SCAN_DOT_ADJ` / `CGB_OBJ_SCAN_LEAD`

const OAM_SCAN_DMA_LOCK* {.intdefine.} = 0
An OAM DMA owns OAM for the whole of its transfer, and the mode-2 OAM scan
gets nothing out of the entries it reaches while that lasts.

Measured and derived 2026-08-13, ships OFF at 0 -- the previous model is the
scan as one burst at dot 80 against whatever OAM holds by then, transfer
ignored. Full derivation in docs/gb-failure-triage.md.

---- The mechanism ---------------------------------------------------------

Mode 2 is 80 dots and there are 40 OAM entries: the scan reads one entry every
two dots. Which dot an entry is read on is normally unobservable -- the CPU is
locked out of OAM for all of mode 2 -- so the burst is exact. An OAM DMA is
the exception: it owns OAM from the CPU clock domain, one byte per CPU
M-cycle, straight through mode 2. That clock crossing is why no constant
offset could ever fix the `oamdma/late_sp*` families -- the transfer advances
one entry per 16 dots at normal speed and one per 8 in double, against a scan
that always does one per 2, so the entry the lock opens or closes on moves
with the speed. (The triage doc had these 27 rows down as a wrong clock domain
in `CGB_OAM_DMA_START_T`; falsified -- sweeping that latency from 4 T to 40 T
moves the `late_sp*` set by zero rows while moving the rest of `oamdma` by
hundreds.)

---- What pins it ----------------------------------------------------------

Eight families, sixteen one-M-cycle brackets, both devices. The `x` half steps
the transfer's START across one named entry's dot and the `y` half steps its
END across the same one, and both put the same entry at the same dot: `sp00`
in [-3, 1), `sp01`/`sp02` in [1, 5), `sp39` in [77, 81) -- i.e. `2n`, to two
dots. Same per-object dot the `sprites/late_sizechange*` ladder derives through
LCDC.2 instead of through a transfer: two suites, two mechanisms, the same two
surviving cells (see OBJ_SCAN_DOT_ADJ).

Turned on: gambatte 4183 -> 4199, +16 / -0, all sixteen `late_sp*`; mooneye
`oam_dma*` and all twelve `acceptance/ppu` rows byte-identical; dmg-acid2 and
cgb-acid2 byte-identical.

---- What refuses it, and it is one ROM ------------------------------------

`strikethrough` -- the one screenshot ROM in the bundle running an OAM DMA
mid-picture -- goes from pixel-exact to 23033/23040 on both devices. Its LY 68
has a transfer covering the whole of that line's mode 2, and its reference
still draws OAM entry 39 (screen x 71..78, exactly the 7 missing pixels). A
lock lasting the whole transfer cannot leave that entry readable, so the
DURATION is wrong even though both edges are pinned to the dot.

Two narrower durations were built and are worse: blocking only the entry the
write port is on scores 28/52 on the families (against 42 for this and 26 for
the burst), and blocking only the two M-cycles the OAM bus changes hands on
scores 38/52. Neither saves `strikethrough`, because the progressive read they
both need displaces entry 39 out of the ten-object cap on its own.

So the shape is right and the duration is not. Left at 0 until it is derived
rather than fitted.

---- 2026-08-20: the REDIRECT reading, tested and refused ------------------

LIJI32 (mooneye-test-suite issue #1) describes this span as a REDIRECT rather
than a lock: the PPU uses the DMA destination address, except for bit 0. That
looked like it dissolved `strikethrough`'s objection, since a redirected read
still yields an OBJECT where a blocked one yields nothing. Built both halves
(this scan and `obj_oam_dma_read`'s fetch) and swept the destination offset,
against a shipping baseline of Pass 1016 / gambatte 4269 / oamdma 771 / both
strikethrough rows exact:

  arm                              Pass  gambatte  oamdma  strike dmg / cgb
  lock, both devices               1014    4285      782     23033 / 23033
  + scan redirect                  1014    4281      778     23032 / 23033
  + object-fetch redirect too      1014    4281      778     23031 / 23033
  lock, DMG-family only            1015    4277      774     23033 / PASS
  that + redirect, off -1 / 0 / +1 1015  4273-4277 770-774   23033 / PASS

The redirect never helps: every redirect arm scores at or below its lock
counterpart and never better on `strikethrough`. So the +16 the lock buys is
not explained by "reads the wrong address".

One real finding, worth keeping if this is ever enabled: the span should be
DMG-FAMILY ONLY. Gating it off on CGB recovers `strikethrough-cgb` to a clean
pass while still gaining +8 gambatte over shipping, halving the lock's cost to
one runner row. That matches LIJI's split -- he has CGB-E and later reading
unmodified values -- although he puts CGB-0..D in the blocking camp and
dingbat scores this row at CPU CGB C, so either that reference was captured on
a CGB-E or the block is narrower than mode 2.

Nothing beats shipping at the runner level (1016). The blocker is unchanged
and is now known not to be an addressing question: `strikethrough-DMG` refuses
the lock's DURATION, and the redirect does not rescue it at any offset.

---- The OAM scan reads LCDC.2 FORTY TIMES, two dots apart -----------------

The scan runs in one go on the dot mode 2 ends, which is fine for OAM itself
(the CPU cannot reach OAM during mode 2) but NOT for LCDC.2: the height is a
register the CPU can move under the scan, and hardware compares each object's Y
against the height as it stands in THAT object's own two-dot slot. gambatte's
`sprites/late_sizechange*` is thirty-eight ROMs of exactly that, and it names
the object in the filename (`_sp00`, `_sp01`, `_sp02`, `_sp39`), which makes it
a ruler rather than a single boundary.

Each sets up an object on the line at 8x16 and off it at 8x8, moves LCDC.2 once
at a chosen dot of line 8, and prints 3 if the object was scanned in. Under
`-d:gb_lcdc2_trace` (4 dots per M-cycle, so each family brackets to one M-cycle):

  family / object   write dots        DMG says            CGB says
  _sp00   obj 0     453 of ly 7, 1    seen, NOT seen      same as DMG
  _sp01   obj 1     453, 1, 5         seen, seen, not     seen, MIXED, not
  _sp02   obj 2     1, 5              seen, not           same as DMG
  (none)  obj 9     13, 17, 21        seen, seen, not     seen, MIXED, not
  _sp39   obj 39    73, 77, 81        seen, seen, not     seen, MIXED, not

So the DMG's sample dot for object N is bracketed into `(2N - 4, 2N]` by the
`_sizechange` half and `[2N - 3, 2N + 2)` by `_sizechange2` -- intersection
`{2N - 1, 2N}`, the object's own slot and nothing else. 2N is the structural one
(the first dot of the slot, and the dot the scan's first OAM read is on) and
OBJ_SCAN_DOT_ADJ expresses the other. The ladder collapses to a single dot per
object because a write dot and a sample dot are compared directly -- no latency
to fit. Device-independent, and 24 gambatte rows on its own.

MIXED: the three CGB cells cannot be one sample dot at all. Object 1's write at
dot 1 is `not seen` when it CLEARS the bit (late_sizechange_sp01_2, the object
stays 8x16) and `seen` when it SETS it (late_sizechange2_sp01_1, the object
becomes 8x16). Same object, same dot, opposite conclusions: what is constant is
the ANSWER, 8x16. The same pair holds at object 9 (dot 17) and object 39 (dot
77), and in each the dot is `2N - 1`, one M-cycle before the DMG's.

So the CGB scans each object against BOTH the DMG's dot and the dot one M-cycle
earlier, keeping the object if either says it is on the line -- and
`sprite_on_line` is monotone in the height, so "either says on the line" is
exactly "either sample says 8x16". As a latency that is the bit arriving at the
scan LATER on CGB, the same direction as CGB_OBJ_SIZE_LATENCY at the object
fetch; the "opposite sign" this family used to be filed under came from reading
it as a fetch measurement. See CGB_OBJ_SCAN_LEAD in gb.nim.
