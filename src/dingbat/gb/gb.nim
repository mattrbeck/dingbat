# GB/GBC emulator main file
# All types are declared here; implementation files are `include`d.

import std/[bitops, os, strutils, times]
import ../common/[input, scheduler, emu, resampler, serialize, timestretch, cheats]
import ../common/lut_macros
when defined(test_harness):
  import ../common/test_output

const LY_BLIND_SCOPE* {.intdefine.} = 1
  ## Which LY advances open the LY=LYC comparator's blind window (see
  ## `ly_advance_close` in ppu.nim): -1 none, 0 rendered line boundaries only,
  ## 1 also vblank-to-vblank, 2 also the mode 0 -> 1 entry on line 144.
  ## Swept whole-suite: -1 3871, 0 3885, 1 3887 (ships), 2 3899.
  ## 2 scores higher but its 12 losses are all `m1` handover rows that depend on
  ## bucket 18 of docs/gb-failure-triage.md (mode-1 STAT source vs the vblank IF
  ## bit); it cannot be scored at line 144 until that settles. Worth +24 then.

# STAT knobs live here rather than beside their write-ups in ppu.nim because the
# GbPpu fields they gate are in the type block below. See ppu.nim for meanings
# and the ROMs that bracket each.
const STAT_IRQ_LEAD* {.intdefine.} = 0
const STAT_LYC_LEAD* {.intdefine.} = 0
  ## STAT_IRQ_LEAD applied to the LYC source alone (STAT_IRQ_LEAD moves LYC,
  ## mode 0 and mode 1 together, so it cannot answer a per-source question).
  ## Ships at 0 -- two-sided bracket, see ppu.nim and docs/gb-failure-triage.md.
const STAT_IRQ_SPLIT* = STAT_IRQ_LEAD != 0 or STAT_LYC_LEAD != 0
static:
  # Both drive one early-advancing domain (irq_ly / irq_mode), so they cannot
  # ask for different leads at once. Either may be 0.
  doAssert STAT_IRQ_LEAD == 0 or STAT_LYC_LEAD == 0 or
           STAT_IRQ_LEAD == STAT_LYC_LEAD,
    "STAT_IRQ_LEAD and STAT_LYC_LEAD drive one domain: set one, or set both equal"
const STAT_DOMAIN_LEAD* = max(STAT_IRQ_LEAD, STAT_LYC_LEAD)

# Where a CPU STAT read samples the mode bits: dot `cc - STAT_READ_SAMPLE`, so a
# read at `cc` sees a mode change on dot X iff `cc - X >= STAT_READ_SAMPLE`.
# Bracketed on both sides at each speed; derivation at stat_read_mode.
const STAT_READ_SAMPLE*     {.intdefine.} = 2
# Double-speed addend, kept separate so the read stays branchless:
# `T = SAMPLE + DS_ADD * speed`.
const STAT_READ_SAMPLE_DS_ADD* {.intdefine.} = 1

const STAT_M0_FIELD_TAIL* {.intdefine.} = 3
  ## Dots the STAT mode FIELD keeps reading 3 after the PPU enters mode 0, on
  ## DMG, on a line with no object fetch. The field only -- the mode-0 STAT
  ## source, HBlank DMA trigger, VRAM/OAM unlock and pixel pipeline all switch on
  ## the PPU's own dot. Spent on `stat_chg_dot`.
  ##
  ## Three row groups measure the same 3 -> 0 edge and disagree; what separates
  ## them is the observable and whether the line carries an object:
  ##
  ##   interrupt, no objects  m0enable/disable_scx*        edge is RIGHT
  ##   field,     no objects  m2int_scx{2,3,5}_m3stat_1    3-4 dots EARLY
  ##   field,     objects     sprites/*_m3stat_2 (63 rows) edge is RIGHT
  ##
  ## So the dots are paid at the FIELD (moving the edge costs m0enable -24) and
  ## absorbed by an object fetch (an unabsorbed lag costs sprites -63).
  ## Measured, not fitted: the m2int_m3stat SCX ladder brackets the length to one
  ## M-cycle per residue, leaving K = 3 or 4; whole-suite sweep makes 3 a strict
  ## local max (2: +30/-3, 3: +46/-6, 4: +57/-27). Worth gambatte 4004 -> 4044,
  ## 42 of the gains in `window`, which the derivation never used.
  ##
  ## Must be charged at the READ, not the mode change -- see STAT_M0_TAIL_MAX_MC.

const STAT_M0_FIELD_TAIL_CGB* {.intdefine.} = 0
  ## STAT_M0_FIELD_TAIL on CGB: zero, both derived and shipping. Bracketed from
  ## above -- at 1 the `m2int_m3stat` `_2` members go red on CGB (4015 vs 4044),
  ## at 2 it reads 3979. The device split is independently predicted by the
  ## `scx_m3_extend` brackets, themselves split by one M-cycle.

const STAT_M0_TAIL_MAX_MC* {.intdefine.} = 2
  ## Last M-cycle of its own instruction on which an IO read still sees
  ## STAT_M0_FIELD_TAIL. 0 disables the gate; 2 ships.
  ##
  ## The three suites that disagree about the field report do not read it with
  ## the same instruction, and the correlation is exact across them:
  ##
  ##   GBMicrotest win*      LDH A,($41)  IO on M3 of 3  no tail  (24 rows)
  ##   gambatte m3stat       LD A,(C)     IO on M2 of 2  tail     (45 rows)
  ##   mooneye-wilbertpol    LD A,(HL)    IO on M2 of 2  tail     (6 rows)
  ##
  ## Two-sided on the structural quantity: runner 1 -> 773 (mechanism off),
  ## 2 -> 779, 3 -> 755 (where LDH starts seeing it and GBMicrotest goes red).

const STAT_M0_FIELD_TAIL_ABSORB* {.booldefine.} = true
  ## Whether an object fetch absorbs the field tail:
  ## `max(0, tail - object dots on this line)`. false is refused by `sprites` at
  ## every value. Specifically objects, not "whatever lengthened mode 3":
  ## absorbing the whole excess over `172 + SCX and 7` (which counts the window
  ## penalty too) scores 4008 vs 4044 and gives back all 42 `window` rows.

const STAT_MODE3_LAG* {.intdefine.} = 0
  ## Dots the STAT mode field keeps reading 2 after the PPU enters mode 3.
  ## Device-independent, must stay 0: `m2int_m2stat*` read STAT expecting mode 3
  ## immediately after that edge and refuse any positive value (+1 / -4).

const STAT_MODE3_LAG_CGB* {.intdefine.} = 0
  ## Dots added to STAT_MODE3_LAG on CGB only; meant to be negative (CGB
  ## reporting mode 3 before its own mode-3 dot). REFUSED, ships at 0.
  ##
  ## `halt/lycirq_m2stat_2` splits the devices in its filename
  ## (`dmg08_out2_cgb04c_out3`) and goes green at -1, but five rows on the same
  ## device read the same edge and want it where it is (m2int_m2stat_1,
  ## sprites/10spritesPrLine_m2stat_1, ly0/lycint152_m2stat_1,
  ## enable_display/nextstat_1, enable_display/frame{0,1}_m3stat_count_1):
  ## net +3 / -6. Object absorption does not separate them -- both
  ## `m2int_m2stat_1` and `lycirq_m2stat_2` are object-free.

# True when any field tail is set. The object accumulator and the whole
# absorption path hang off this, not off STAT_M0_FIELD_TAIL_ABSORB, so a default
# build carries neither the field nor the add in the object-fetch path.
const STAT_M0_TAIL_ANY* = STAT_M0_FIELD_TAIL != 0 or STAT_M0_FIELD_TAIL_CGB != 0

const STAT_MODE_LAG_ANY* = STAT_M0_TAIL_ANY or
                           STAT_MODE3_LAG != 0 or STAT_MODE3_LAG_CGB != 0

# `stat_chg_dot` for "no mode change is inside any read's sampling window". A
# line is 456 dots and the counter rebases at every wrap, so this can never come
# within STAT_READ_SAMPLE of the counter again.
const STAT_NO_HOLD* = -1024'i32

# Fixed setup cost of a CGB general-purpose VRAM DMA, in M-cycles, on top of the
# 8 M-cycles per $10 bytes for the blocks themselves (ppu_start_hdma).
#
# Ships at 0 because NO value works -- that is what the knob records.
# gambatte's 18 `gdma_cycles_*` rows are nine pairs one NOP apart that bracket
# the mode 3 -> 0 edge between their two members; dingbat answers 3 to both
# members of all nine. Sweeping (tools/gbdiff/gdma_sweep.sh) leaves some failing
# at every setting: 0 -> 9/18, 1 -> 9/18, 2 -> 13/18 (best, and contradictory --
# long_scx{2,3,5}_2 still short while 2xshort_ds_1 has gone past its edge),
# 3 -> 12/18, 4+ -> 9/18. At the best setting the residual tracks SCX, and a
# constant cannot depend on SCX, so the missing time is not setup -- it is where
# the transfer leaves the PPU relative to the mode 3 -> 0 edge. Needs a model.
const GDMA_SETUP_MCYCLES* {.intdefine.} = 0

# How long an HBlank DMA block's BYTES take to appear in VRAM after the last one
# transfers, in DOTS. Data only: the 8 M-cycles per $10 bytes, the address
# counters and the FF55 length readback are all charged where they were. Held
# bytes land lazily wherever VRAM can be observed (ppu_land_hdma_if_due).
#
# gambatte's 14 `hdma_start` rows are the only ones that read the transferred
# DATA. Each `_1`/`_2` pair differs by one inserted NOP before the `LD A,(HL)`,
# so they sample one M-cycle apart and their expected 0/1 bracket the arrival.
# `-d:gb_dma_trace` turns the family into seven inequalities that intersect at
# K = 36 dots from the block start; a block is 32 dots, so this is 4. Swept
# whole-suite (hdma_start rows / gambatte total): 0 -> 7/14 4131, 3 -> 11/14
# 4135, 4 -> 13/14 4137 (ships), 5 -> 11/14 4135, 8 -> 6/14 4130. Strict
# two-sided maximum.
#
# DOTS, not bus M-cycles: the two coincide only at normal speed with a block
# starting on an M-cycle boundary. `hdma_start_ds_1` and `hdma_start_scx5_2` are
# the rows that separate them -- an M-cycle-counting version scores 4135 and
# misses one whichever way it rounds. Same thing `ignore_speed` says in
# ppu_copy_hdma_block.
#
# The one row left, `hdma_start_scx5_1`, reads VRAM 4 dots BEFORE the block and
# is refused by the mode-3 lock, not answered early: that is the SCX residual on
# the mode 3 -> 0 edge (bucket 15, docs/gb-failure-triage.md).
#
# Why the bytes and not the block: delaying the block itself by one M-cycle was
# tried and refused -- gambatte 4131 -> 4126, breaking `hdma_late_disable_2`,
# `_scx2_2`, `_scx3_2` and sliding the `hdma_late_m3speedchange_*` ladder. Those
# rows read FF55/LY/TIMA, so they time the block's bus occupancy and say it
# starts where it does today.
#
# The read that sees stale bytes is inside the block's own dots -- the copy ticks
# the PPU 8 M-cycles while the triggering CPU access is still in flight, which is
# also why that access finds VRAM unlocked. Hence the hold is only taken for a
# block the mode-0 edge starts (`in_cpu_cycle`); extending it to FF55-started
# blocks costs `hdma_disabled_display_1` and gains nothing.
#
# HDMA_VISIBLE_DOTS is declared further down, next to CGB_HALT_PPU_LEAD, whose
# value it carries a term of.

# ---- Serial shift clock tap offset, per device ------------------------------
#
# The serial unit watches a bit of (divider + tap); its falling edge shifts one
# bit. The tap is a phase in T-cycles on a free-running counter -- not a
# countdown started by SC -- because the serial unit's divider copy sits a few T
# ahead of what a DIV read returns. Raising it makes every edge land earlier.
#
# Two-sided contradiction, quarantined at the DMG value gambatte refuses.
# Swept against gambatte's 82-row `serial` bucket with CGB held at 2, the DMG tap
# plateaus at 53 rows across [0,3] and drops to 50 outside it -- a strict local
# max, 4 T wide, which says the tap is an M-cycle-quantised phase and not a
# duration. The CGB column has the same shape and already sits inside it.
#
# But `mooneye/acceptance/serial/boot_sclk_align-dmgABCmgb` pins 4 and is
# hardware-verified on DMG/MGB, so it wins: the tap ships at 4 and three gambatte
# rows stay red deliberately.
#
# Re-partitioning the tap against the boot divider seed does not reconcile them:
# `boot_div-dmgABCmgb` reads DIV (`tdiv shr 8`) so it cannot see a 4 T seed
# change at all, and both suites' ROMs start from the same boot state and write
# no DIV, so each sees only (seed + tap). The disagreement is in something both
# traverse before the SC.7 write.
const SERIAL_TAP_DMG* {.intdefine.} = 4
const SERIAL_TAP_CGB* {.intdefine.} = 2

# ---- The residual `start_wait_*` cluster -------------------------------------
#
# Twelve rows (`start_wait_read_if`, `_read_sb`, `_read_sc`,
# `start_wait_clear_if_read_if`, and their `_ds` arms) report one defect through
# three registers: at family step 1 hardware has done seven shifts and dingbat
# eight. `_read_sb` counts them directly (SB seeds $00 and shifts in ones:
# `exp=7F,FF got=FF,FF`), and SC.7 and the serial IF flip on the same M-cycle --
# so it is the eighth shift EDGE that is early, not the interrupt's visibility.
#
# Two candidates, both refused from opposite sides:
#  * Not the tap. These rows do not move by a single verdict at any tap in
#    [-8, +8], while `div_write_start_wait_read_if` next door flips cleanly at 0.
#    So the error exceeds 8 T and the clock's phase cannot reach it.
#  * Not a whole missed period. SERIAL_START_ARM spends the first falling edge
#    after SC.7 rises on arming (+512 T): step 1 lands on all six families and
#    step 2 goes out on all six -- the error changes sign. Whole suite +24 / -32.
#
# The quantity is strictly between 8 T and one bit period, which no edge-phase
# constant expresses (a tap moves the start sample with the edges, leaving the
# edge count invariant). The next instrument must move the START against a
# stationary clock -- when SC.7's write commits relative to the divider -- which
# is a bus question, not a serial one.
const SERIAL_START_ARM* {.intdefine.} = 0

# ---- The M-cycle a CGB spends leaving HALT that a DMG does not ---------------
#
# CGB_HALT_EXIT_MCYCLES charges it as TIME; CGB_HALT_PPU_LEAD below spends it as
# PHASE. The phase is the one that ships -- see there. This charge stays at 0.
#
# What asks for the M-cycle: ten `halt/` ROMs name a different expected value per
# device in their filename, each a read a fixed number of M-cycles after an
# interrupt ended a halt (m0{int,irq}_m0stat_scx{3,4}_2, late_m0*_halt_*,
# lycirq_m2stat_2, m1int_ly_2). All ten say the CGB read lands later in the PPU's
# line, across three unrelated boundaries. At 1 all ten flip green plus 11 more.
#
# What refuses the CHARGE: 42 `tima/*` rows, all with one expected value for both
# devices. An extra M-cycle at the exit is extra time, so DIV and TIMA advance
# through it; hardware says they do not. Net -37 gambatte. Whatever the CGB does
# here, it is not spending time -- which is what makes it a phase.
#
# A further 11 rows are the same family at a different SCX, where SCX 3/4 want
# the M-cycle and SCX 2/5 refuse it. A halt cost cannot depend on SCX, so part of
# what those ten measure is the CGB's mode 3 length against SCX (bucket
# `scx_during_m3`), not this.
const CGB_HALT_EXIT_MCYCLES* {.intdefine.} = 0
const CGB_HALT_LEAD_LYC_ONLY* {.intdefine.} = 0
  ## EXPERIMENT. Restrict CGB_HALT_PPU_LEAD to halts where the LYC comparator is
  ## the only armed STAT source. 0 ships; see the test it gates in cpu.nim.
const CGB_HALT_LEAD_SKIP_LYC0* {.intdefine.} = 1
  ## Whether a halt woken by the LY 153 -> 0 snapback's `LYC = 0` match is exempt
  ## from CGB_HALT_PPU_LEAD. 1 ships; 0 is the control (lead on every wake).
  ## Derived by a LYC sweep of daid's `ppu_scanline_bgp` against SameBoy -- same
  ## ROM and entry, only the wake line changing. See the test in cpu.nim.
const CGB_HALT_PPU_LEAD* {.intdefine.} = 1
  ## While a CGB CPU is halted the PPU runs one M-cycle of dots behind the rest
  ## of the machine, and gets them back on the way out. The first halted M-cycle
  ## ticks the bus half only (scheduler, timer, serial, OAM DMA); the wake ticks
  ## those dots into the PPU with no bus half (cpu_halt_tick and `tick` in
  ## cpu.nim). Nothing is created or destroyed -- a k-M-cycle halt still gives the
  ## PPU k M-cycles of dots. `halt_ppu_debt` is the memo, reconstructed on state
  ## load rather than serialized (savestate.nim) since it is constant per halt.
  ##
  ## Phase, not charge, because the 42 `tima/*` rows pick: both models put the
  ## post-wake read one M-cycle later in the PPU's line, but a charge also
  ## advances TIMA and a phase does not. See CGB_HALT_EXIT_MCYCLES.
  ##
  ## ---- Exactly one M-cycle, bracketed from both sides -----------------------
  ##
  ## Two `halt/` families of three ROMs each, differing only by one NOP before
  ## the read:
  ##
  ##   lycirq_m2stat   _1 out 2     _2 dmg 2 / cgb 3     _3 out 3
  ##   m1int_ly        _1 out $90   _2 dmg $90 / cgb $91 _3 out $91
  ##
  ## At 0 the `_2` members answer the DMG value on CGB; at 1 both flip green with
  ## `_1`/`_3` still green; at 2 the `_1` members go red -- under phase and charge
  ## alike, so the bracket belongs to the quantity. Neither family carries SCX.
  ## `lycirq_*` is the IME-clear path, `m1int_*` the IME-set one, so it is on
  ## both.
  ##
  ## Independent confirmation from a family that shares no ROM, register or edge:
  ## gambatte's `speedchange*_ly44_m3_*` ladder, in which nothing halts, derives
  ## the KEY1 switch's PPU re-alignment alone (8 dots into double, 3 back into
  ## single, 55/55 rows). daid's `speed_switch_timing` pair does halt once each
  ## and pins halt-lead + switch-extra at 12. 12 - 8 = 4 dots = this constant.
  ##
  ## ---- 2026-08-18: on, with the snapback exempt -----------------------------
  ##
  ## Turning it on flat takes `cgb-acid-hell` to 0 px but `daid/ppu_scanline_bgp`
  ## (GBC) from 0 to 2304 px at every CGB revision -- a shootout row this tree
  ## did not gate. It is wired now (`daid/ppu_scanline_bgp-gbc`).
  ##
  ## The ROMs are not in conflict. daid's is one STAT LYC interrupt out of `halt`
  ## followed by a scanline-locked 114-M BGP loop. Rebuilt byte-exact and swept
  ## over the LYC value alone -- same ROM, entry, IME and vector, only the wake
  ## line changing -- against SameBoy (which reproduces daid's reference
  ## pixel-exactly):
  ##
  ##   LYC = 0 (the LY 153 -> 0 snapback)  exact WITHOUT the lead, 2304 px with
  ##   LYC = 1, 8, 40, 100 (normal lines)  exact WITH the lead, 1920-2304 without
  ##
  ## So the M-cycle is real on every normal-line wake and absent on the snapback;
  ## acid-hell's disputed pixels are on lines 68-69, normal lines. Hence
  ## CGB_HALT_LEAD_SKIP_LYC0. Sweep: tools/gbppu/daidsweep.py.
  ##
  ## Refuted on the way, so nobody re-runs them: not IME or whether a vector is
  ## taken (the LYC sweep holds both constant), and not LY0_PIPE_MCYCLES (0/2/3
  ## against the lead leaves daid at 2304).
  ##
  ## Ledger: runner 885 -> 887, gambatte 4201 -> 4246; cgb-acid-hell, both
  ## `strikethrough` frames and both daid frames all 23040/23040. All 260
  ## shootout ROMs were rendered under both builds in both device modes and only
  ## cgb-acid-hell moves. Shootout: 261 scored, 261 PASS. Still red and
  ## unexplained: gambatte `dma` -7, `lcd_offset` -6, `window` -1, against +54.
  ##
  ## `strikethrough` was the long-standing objection and is resolved rather than
  ## overridden: that frame witnesses the SUM of the pipeline advance and the
  ## object fetch's lead over the OAM DMA bus, not the advance alone. The advance
  ## is summed into OBJ_DMA_BUS_LEAD (fifo_ppu.nim), CGB-only, exactly as
  ## CGB_PIPE_MCYCLES already was, and both frames are byte-identical across the
  ## change.
  ##
  ## ---- Cost -----------------------------------------------------------------
  ##
  ## The `cpu_halt_tick` block no longer compiles out, so every HALT-idling title
  ## pays it -- DMG ones pay the `cgb_enabled` test and nothing else. Retired
  ## instructions, min of 3, on `cgb-acid-hell` (144 halts/frame, near worst
  ## case): 6.0804 G -> 6.1610 G, +1.33%. Real titles are smaller (+0.44% Pokemon
  ## Blue, +0.56..0.77% Crystal). To pay it back, decide at halt ENTRY rather than
  ## per halted M-cycle -- the debt field is already the per-halt latch.
const CGB_OAM_DMA_START_T* {.intdefine.} = 8
  ## T-cycles between the FF46 write and the OAM DMA unit taking the bus, on CGB.
  ## 8 is what both devices ship with (mem_dma_tick). The knob exists only
  ## because `strikethrough` at a nonzero CGB_HALT_PPU_LEAD wanted 4 T taken out
  ## of here; that is on record as refused. See docs/gb-failure-triage.md.
const GB_POWERUP_WRAM_PATTERN* {.intdefine.} = 1
  ## Fill WRAM with a fixed pseudo-random pattern at power-up instead of zeroes.
  ## Pan Docs (Power_Up_Sequence) says WRAM/HRAM are random on power-up and names
  ## a constant fill as an emulator shortcut. BullyGB's InitRAMTest catches that
  ## shortcut and is the FIRST of its nine tests, so the other eight had never
  ## run here; with this on, bully prints "All tests OK!" and is pixel-exact.
  ##
  ## Measured on a GBA SP (flashcart-kit/9, `wramscan.gb`, booted direct so the
  ## cart menu could not overwrite): 369 bytes $00, 221 $FF, 7602 neither, of
  ## 8192. Not uniform noise either (uniform would give ~32 each), so this is an
  ## honest approximation, not a claim about silicon.
  ##
  ## Cost: gambatte `oamdma` 771 -> 766. All five are `oamdma_src{FE,FF}00_*` and
  ## all five stop producing a verdict rather than a wrong one, because a DMA
  ## source >= $E000 fetches through the echo, so $FE00/$FF00 read $DE00/$DF00.
  ## Proven: randomising all WRAM EXCEPT $DE00-$DFFF restores gambatte to 4274
  ## and oamdma to 771, bully still passing. Those rows read uninitialised WRAM
  ## and encode whatever the capture rig left there; zeroing just those two pages
  ## would buy all five back and is deliberately NOT done -- it fits gambatte's
  ## rig, and the AGS scan puts its zero run near $D600.
  ##
  ## Net: runner 1015 -> 1016 with zero runner rows lost, gambatte 4274 -> 4269.
  ##
  ## Fixed xorshift, never a seeded RNG: byte-identical screenshot gates,
  ## save-state round-trips and rollback netplay all need two runs of the same
  ## ROM to start from the same bytes.
  ##
  ## `wrambands.gb` on two machines (2026-08-20): set bits per 256-byte block,
  ## of 2048, excluding the loader region -- AGB 1007.6 (49.2%), MGB 1089.2
  ## (53.2%); byte counts 369/221 on AGB against 834/333 on MGB. There is NO
  ## 256-byte banding on either machine, so the alternating-band shapes some
  ## emulators model are not what these consoles do. Uniform is a good AGB model
  ## and slightly under-biased for MGB; deliberately not chasing the 4%, since no
  ## row distinguishes them and one console is not a population. Recorded in
  ## docs/flashcart-runbook.md.
const HDMA_STEAL_DELAY_M* {.intdefine.} = 1
  ## CPU instruction boundaries an HBlank DMA block waits after the mode-0 edge
  ## before taking the bus. 0 = on the edge itself, which dingbat always did.
  ##
  ## mealybug `dma/hdma_timing-C` says the edge is too early. Its `sub_test`
  ## macro arms a one-block transfer then reads a register after N nops, one run
  ## per N. At SCX=1 hardware answers `00 ff ff ff` for nops 46-49, and $00 is
  ## "armed, zero blocks left, NOT YET TRANSFERRED", while the STAT samples put
  ## the mode-0 edge between nops 44 and 45 -- so the block starts about two
  ## M-cycles after the edge with the CPU stalled through it. At SCX=2 the longer
  ## mode 3 moves the edge one M-cycle later and the answer becomes `00 00 ff ff`.
  ##
  ## Paid at INSTRUCTION boundaries, not on a dot counter: a per-dot deadline
  ## measured +1.36% retired instructions and was declined; this is one
  ## not-taken branch per instruction and measures free.
  ##
  ## Paid BEFORE handle_interrupts, and that ordering matters as much as the
  ## delay -- the DMA takes the bus ahead of the dispatch. Paying at the top of
  ## the next instruction instead is the same instant on the wrong side of the
  ## dispatch and costs the whole gambatte `irq_precedence` hdma_vs_m0 /
  ## late_hdma_vs_{ei,ie} family; paying before it gains three of those rows.
  ##
  ##   HDMA_STEAL_DELAY_M      0      1 (ship)   2      3      4
  ##   hdma_timing-C wrong    8/48    2/48     4/48   8/48  10/48
  ##
  ## Whole suite: gambatte 4263 -> 4274, dma 126 -> 134, irq_precedence 44 -> 47,
  ## zero rows lost. The `dma` gain is the entire `hdma_late_disable` family --
  ## the set HDMA_VISIBLE_DOTS was swept over and could not recover at any value.
const HDMA_BLOCK_OVERHEAD_BUS* {.intdefine.} = 4
  ## CPU-clock cycles an HBlank DMA block costs beyond its sixteen byte copies:
  ## the bus acquire/release either side. NOT the per-byte cost -- two dots per
  ## byte at either speed is pinned by gambatte `hdma_start_ds_*` and agrees with
  ## SameBoy's GB_hdma_run.
  ##
  ## Unscaled, and that is the measured part. The copies are `2 shl
  ## current_speed` because they are PPU dots; this is not. Shipped first as a
  ## single `2 shl speed` term, that made the double-speed DIV-duration group
  ## exact while leaving the single-speed one 4 wrong. A flat 4 makes both exact:
  ##
  ##   unscaled bus cycles     2      4 (ship)    6      8
  ##   hdma_timing-C wrong   16/48    8/48     12/48  16/48
  ##
  ## (Dots swept separately at bus=4: 0 -> 12, 2 -> 8, 4 -> 10. Charging before
  ## the copies instead of after scores identically, so the instrument does not
  ## distinguish acquire from release -- do not read the placement as evidence.)
const HDMA_BLOCK_OVERHEAD_DOTS* {.intdefine.} = 2
  ## PPU dots for the same overhead; separate from the bus term because they are
  ## separate clocks. See HDMA_BLOCK_OVERHEAD_BUS for the sweep.
  ##
  ## hdma_timing-C: 20/48 wrong -> 12 -> 8, and 6 more fixed by HDMA_STEAL_DELAY_M.
  ## Both DIV-duration groups and the mode-2 entry after the block are exact.
  ## SameBoy scores 2/48; so do we. The 2 remaining cells point OPPOSITE ways,
  ## which is why no scalar closes them: SCX=1 single speed wants the block ~1 M
  ## EARLIER, SCX=2 double speed wants it LATER.
  ##
  ## A dot-granular delay was tried 2026-08-20 and does NOT help -- do not
  ## re-derive it. The reasoning was sound (an instruction boundary is 4 dots at
  ## single speed and 2 at double, exactly the asymmetry above, so a fixed dot
  ## delay between them should satisfy both), but implemented as an `etHdmaSteal`
  ## scheduler event at the mode-0 edge it plateaus at 2/48 across dots 5-8 --
  ## what the boundary path already achieves with no new machinery -- and is
  ## worse everywhere else (1-4 -> 6, 10 -> 4, 16 -> 8, 32 -> 10). The predicted
  ## 3 dots is 6/48. At 5 dots both survivors are too EARLY in the SAME
  ## direction, and more delay makes it monotonically worse, so the residual is
  ## not a placement question at any granularity. Reverted rather than shipped.
const HDMA_VISIBLE_DOTS* {.intdefine.} = 4 + 4 * CGB_HALT_PPU_LEAD
  ## Dots an HBlank DMA block's bytes take to become visible in VRAM.
  ##
  ## The `4 * CGB_HALT_PPU_LEAD` term is the argument OBJ_DMA_BUS_LEAD makes for
  ## the OAM DMA unit: the DMA engine runs on machine time and this window is
  ## measured against the pipeline, so advancing the pipeline moves the window.
  ## Declared here rather than with the other memory timings because it reads a
  ## const defined above.
  ##
  ## Whole gambatte suite with the lead on: `dma` is 116/229 at 4, 121 at 8,
  ## 116 at 12 -- a local max bracketed on both sides, and 8 is 4 plus the
  ## advance. Partial account only: seven `hdma_late_disable_*` rows stay red and
  ## this term does not explain them.
const CGB_HALT_PPU_LEAD_DOTS* {.intdefine.} = 4 * CGB_HALT_PPU_LEAD
  ## The same lag in DOTS, which is the unit the code reads. CGB_HALT_PPU_LEAD
  ## sets it in whole M-cycles, so `=1` means 4 dots; setting THIS directly is
  ## what reaches the three values between them.
  ##
  ## Sub-M-cycle values are not a finer knob on the same thing: the halt exit is
  ## sampled on the M-cycle grid (`cpu_halt_tick`), so a lag of 1-3 dots moves
  ## the wake by a WHOLE M-cycle for a source whose rise dot is within `DOTS` of
  ## the next boundary, and by nothing for every other source. One quantity, a
  ## per-source answer. Sweep: docs/gb-failure-triage.md (2026-08-10).
const CGB_HALT_PPU_LEAD_ANY* = CGB_HALT_PPU_LEAD_DOTS != 0

# ---- CGB per-register PPU write latency -------------------------------------
#
# Dots into its own M-cycle that a CPU write to a pipeline register lands on CGB,
# over and above where DMG puts it. Here rather than beside their write-up in
# memory.nim only because the GbMemory fields they gate are in the type block
# below; mechanism and sources are at mem_tick_ppu_latched.
#
# DMG is the zero of this scale, not the origin: dingbat commits a write's byte
# at the top of its M-cycle and every DMG family that brackets one of these
# agrees, so what is modelled is the CGB *delta* alone -- invariant to whatever
# constant offset dingbat's dot grid carries against anyone else's.
#
# SCY and SCX ship at the documented 2; the other five ship at 0 because every
# nonzero value is refused by some family. The CGB PPU really does take these
# writes late (mealybug's PPU document states 2 T-cycles for SCY, and Pan Docs'
# "Mid-frame behavior" carries the same split), but only the scroll pair has an
# instrument here that agrees.
#
# Swept alone against two instruments, one build per cell (cgbsweep.sh forces the
# other six to 0). Baselines: gambatte 3567/5005, mealybug CGB 1794023 px.
# Every moved row is a `[cgb]` row; the DMG side never moves, as it must not.
#
#   setting                    gambatte   mealybug CGB   what moved
#   all 0 (control)              3567        1794023     row for row main
#   CGB_SCY_LATENCY=1            3566        1803344     scy -1
#   CGB_SCY_LATENCY=2            3566        1795140     scy -1
#   CGB_SCY_LATENCY=3            3566        1791068     scy -1
#   CGB_SCX_LATENCY=1            3567        1793878     nothing
#   CGB_SCX_LATENCY=2            3566        1792812     scx_during_m3 -1
#   CGB_WX_LATENCY=1 / =2        3566        1794023     window -1
#   CGB_WY_LATENCY / WY_LATCH    3567        1794023     nothing at all
#   CGB_LCDC_LATENCY=1           3564        1792077     window -3
#   CGB_LCDC_LATENCY=2           3563        1789728     window -4
#   CGB_LCDC_TDSEL_LATENCY=1     3563        1789555     window -3, bgtiledata -1
#   CGB_LCDC_TDSEL_LATENCY=2     3562        1784962     window -4, bgtiledata -1
#
# The shortfall is not systematic -- SCY is the only register whose instruments
# move at all -- so there is no reason to look for a global absorber (such as a
# late mode 3 start) first. Whatever ate the SCY dot had to be visible to SCY's
# own ROMs and on DMG too, and it was: see the SCY note below.
#
# SCROLL is two constants because Pan Docs documents the two registers
# differently ("Mid-frame behavior" gives SCY a per-model sample point; the SCX
# split -- high 5 bits per tile fetch, low 3 latched at line start -- carries no
# model qualifier), and the split shows up here.
#
# Per register:
#  * SCY. The documented 2 is right; the whole-frame score's earlier preference
#    for 1 was an artefact of the OBJ fetch phase, not of this constant.
#    m3_scy_change is eighteen measurements, not one: its OAM table is
#    `Y = 16 + 8k, X = k`, so each 8-line band carries one object whose X advances
#    down the screen, and that object is the RULER -- the OBJ penalty sets the
#    phase between the ROM's write burst and the fetcher's three SCY reads.
#    Scored per band, the bands with NO object wait term were pixel-exact at 2
#    and wrong at 1, while the bands WITH a wait term collapsed at 2 -- and those
#    were exactly the bands whose DMG reference was already wrong with no CGB
#    constant involved. So the missing dot was the BG fetcher's phase across an
#    OBJ fetch: device-independent, a function of the object's X, and the very
#    thing this ROM measures with. Fixed 2026-08-03 (tick_sprite_fetcher in
#    fifo_ppu.nim), after which the prediction held -- every band comes up, the
#    whole ROM goes 82.0% -> 97.7%, the CGB suite 1794023 -> 1812603, and
#    gambatte no longer moves between 0 and 2. 1 and 3 are both worse on mealybug
#    CGB (1802113 and 1809324 against 1814216).
#    One refusal stands and is unrelated: gambatte loses
#    scy/scy_during_m3_spx08_ds_4 at any nonzero value. At 2 dots per M-cycle a
#    1-dot latency lands on the cap boundary, so that row is reading the CGB
#    CPU-to-PPU phase axis through a register latency -- the confusion
#    CGB_LATENCY_CAP exists to prevent and cannot at this width.
#  * SCX. Also 2, for the same reason: the row that used to refuse it was reading
#    the OBJ fetch phase. The clean DMG-neutral per-device row a scroll latency
#    fixes is enable_display/ly0_late_scx7_m3stat_scx0_274 (DMG expects $87, CGB
#    $84); at 2 dots both are right. On the fixed fetcher the mealybug m3_scx_*
#    rows come back monotonically -- m3_scx_high_5_bits 99.5 / 99.7 / 100.0% and
#    _change2 99.7 / 99.8 / 100.0% at 0 / 1 / 2 -- while gambatte adds
#    scx_during_m3/scx_0060c0 and _0063c0 `_3` on the CGB side (30 -> 32).
#    Three instruments, one value, and it is the documented one. The `_scx1` rows
#    are still red on both devices; that residual is elsewhere.
#  * LCDC (whole register). Four of its bits now carry their own per-reader delay
#    instead -- CGB_OBJ_SIZE_LATENCY (bit 2), CGB_TDSEL_LATENCY (bit 4),
#    CGB_MAP_LATENCY (bits 3 and 6) -- each derived on a family the whole-register
#    form cannot separate. CGB_MAP_LATENCY takes gambatte `bgtilemap` 28/40 ->
#    40/40, a family this table never moved at any setting, so they measure
#    different things.
#    Every window row the whole-register form costs is a late_disable /
#    late_reenable row -- the family SameBoy gives a CGB-only fetcher-abort path
#    (a window disable part way through the fetch aborts it), which moves them the
#    other way. The +2 dots is not separable from the abort here, and adding it
#    alone is strictly worse. Implement the abort first, then re-run.
#    Re-measured 2026-08-03: CGB_LCDC_LATENCY=1 scores 3616, +3 / -5, and the
#    latency shifts the whole late_disable family by one step rather than moving
#    where inside it the answer flips -- the signature of a missing mechanism,
#    not a wrong constant. Ceiling if the abort lands is ~10 gambatte plus 2
#    mealybug rows, and those two are wrong on BOTH devices, so a CGB-only abort
#    will not collect all of it.
#  * WX / WY / the WY latch. The split is in the ROMs' OWN EXPECTED VALUES, not
#    in a latch dot. Of the 14 late_wy families scored on both devices, 13 expect
#    different values per device, every one the same one-M-cycle shift in the
#    same direction (late_wy_FFto2_ly2 dmg 3,3,0 / cgb 3,0,0; late_wy_1toFF dmg
#    0,0,3 / cgb 0,3,3; and 11 more). dingbat answers the same value on both
#    devices in 11 of the 14 -- it models no device difference at all, which is
#    the defect, worth ~26 rows.
#    Note the SIGN before reaching for a latency: the CGB expectation flips one
#    step EARLIER, so CGB samples WY sooner, not later. Every constant here is a
#    positive delay, which moves CGB the wrong way -- that, not a missing
#    instrument, is why WY shows "nothing at all" in the table. The mechanism is
#    probably not a write latency at all.
const CGB_WX_LATENCY*         {.intdefine.} = 0
const CGB_WY_LATENCY*         {.intdefine.} = 0
const CGB_SCY_LATENCY*        {.intdefine.} = 2
const CGB_SCX_LATENCY*        {.intdefine.} = 2
const CGB_LCDC_LATENCY*       {.intdefine.} = 0
const CGB_LCDC_TDSEL_LATENCY* {.intdefine.} = 0
const CGB_OBJ_SIZE_LATENCY*   {.intdefine.} = 3
  ## Dots LCDC.2 takes to reach the OBJECT FETCH on CGB over DMG -- the same
  ## shape as CGB_MIXER_LATENCY, for the one bit of LCDC an object fetch reads.
  ## Separate from CGB_LCDC_LATENCY because that moves the whole register for
  ## every reader and every nonzero setting costs gambatte rows.
  ##
  ## Derived and swept at OBJ_PLANE1_LAG in fifo_ppu.nim: the two
  ## `m3_lcdc_obj_size_change` ROMs disagree between their DMG and CGB references
  ## on which bands come out mixed, by a clean three dots in the same direction
  ## on all six bands that separate them.
const CGB_OBJ_SCAN_LEAD*      {.intdefine.} = 2
  ## Dots before its own sample dot that a CGB's OAM SCAN takes a second look at
  ## LCDC.2, keeping the object if either look puts it on the line. A different
  ## reader from CGB_OBJ_SIZE_LATENCY (that is the mode-3 object fetch, this is
  ## the mode-2 range comparator), measured by a different family. Derived at
  ## fifo_get_sprites off gambatte `sprites/late_sizechange*`, where objects 1, 9
  ## and 39 each have a CGB cell that comes out 8x16 whichever way the write moved
  ## the bit -- which no single sample dot can produce.
  ##
  ## Its sign agrees with CGB_OBJ_SIZE_LATENCY: the bit reaches the object logic
  ## later on CGB than on DMG.
const CGB_MAP_LATENCY*        {.intdefine.} = 2
  ## Dots LCDC.3 / LCDC.6 (the tile MAP select bits) take to reach the background
  ## fetcher's MAP ADDRESS read on CGB over DMG. Fourth member of the per-reader
  ## family, not the whole-register CGB_LCDC_LATENCY.
  ##
  ## Derived, not fitted, from the four mealybug `*map_change*` rows, with the DMG
  ## side pinning the phase so the whole delta is the console.
  ## `m3_lcdc_{bg,win}_map_change` are 23040/23040 against `_dmg_blob` and were
  ## 384 and 182 px out against `_cgb_c` at every revision alike (the `_cgb_c` and
  ## `_cgb_d` captures are byte-identical, so this is not a revision axis).
  ##
  ## Both ROMs invert completely: map $9800 is all tile 0 (all-$00), $9C00 all
  ## tile 1 (all-$FF), BGP identity, SCX 0 -- so every 8-pixel tile column is one
  ## bit, which map the fetcher's B-stage read used, and the handler raises that
  ## bit for exactly 8 dots. Eighteen objects at `Y = $10 + 8k, X = k` sweep the
  ## pulse across the fetch grid one dot per band (docs/gb-mealybug-sources.md
  ## 1.3), so one frame is eighteen readings. Reading the black column per band:
  ##
  ##   m3_lcdc_bg_map_change     DMG blob            CGB C and D
  ##     tile 1 black            X = 0, 1, 2         X = 0
  ##     tile 2 black            X = 3 .. 7          X = 1 .. 7
  ##     nothing black           X = 8, 9, 10        X = 8
  ##     tile 2 black            X = 11 .. 15        X = 9 .. 15
  ##
  ##   m3_lcdc_win_map_change    DMG blob            CGB C and D
  ##     tile 0 black            X = 0, 1, 2         X = 0
  ##     tile 1 black            X = 1 .. 7          X = 0 .. 7
  ##
  ## Four independent edges, all four moving the same two bands in the same
  ## direction. A band is a dot, so the pulse arrives at the map read two dots
  ## later on CGB. (The `win_map` tile-1 entry edge reads as one band only because
  ## X cannot go below 0.) dingbat previously answered the DMG schedule on both
  ## consoles -- exactly the four bands that were wrong.
  ##
  ## Two dots is also the magnitude mealybug's PPU document gives for the one CGB
  ## write latency it states outright (SCY, shipping next door as
  ## CGB_SCY_LATENCY = 2). Bracketed on both instruments rather than assumed:
  ##
  ##   CGB_MAP_LATENCY        0      1      2 (ship)    3
  ##   gambatte bgtilemap    28/40  32/40   40/40     32/40
  ##   mealybug CGB pixels  1863574 1865000 1866240  1864988  (of 1866240)
  ##   gambatte total        4246   4250    4258      4250   (of 5005)
  ##   runner Pass            919    919     924       916   (of 1106)
  ##
  ## One unique maximum with symmetric fall-off; at 3 it is worse than turning the
  ## rule off entirely. gambatte's `bgtilemap` is 40 rows of exactly this write and
  ## was not consulted while the value was derived; all twelve of its gains are
  ## `[cgb]` rows. At 2 the whole 27-row mealybug CGB set and 24-row DMG set are
  ## pixel-exact at `--cgb-rev=` C, D and E against both captures.
  ##
  ## Re-measuring is a trap worth naming: dingbat_test_runner SHELLS OUT to
  ## ./dingbat_test, so `-d:CGB_MAP_LATENCY=N` has to go into THAT binary.
  ## Rebuilding only the runner scores every arm identically, control included.
  ##
  ## The latency is CPU-clock, proven by the double-speed rows rather than
  ## assumed. Spent at the write (ppu_store_lcdc) as
  ## `max(0, CGB_MAP_LATENCY - current_speed)`, so a double-speed M-cycle spends
  ## the delay inside itself. Without the speed term `bgtilemap` drops to 36/40
  ## and all four losses are `_ds_` rows. Same shape as CGB_TDSEL_LATENCY.
  ##
  ## Confined to the map-address read because that is the only reader the
  ## instrument sees; LCDC.3/.6 have no other consumer in the fetcher, and gating
  ## here rather than in the register keeps the whole-register `late_disable`
  ## question untouched.
  ##
  ## Cost: +0.20% of retired instructions, and it is the one compare in
  ## `fsGetTile`, not the fields (the control arm still carries `map_dot` and
  ## `map_old`, so none of it is layout). DMG pays it too -- the compare is gated
  ## at compile time, and a runtime `ppu.cgb` test is one more load off the same
  ## cache line. Buys 4 mealybug and 12 gambatte rows.
const CGB_TDSEL_LATENCY*      {.intdefine.} = 1
  ## Dots LCDC.4 takes to reach the BACKGROUND FETCHER on CGB over DMG -- the one
  ## bit of LCDC a background bitplane read consults. Separate from
  ## CGB_LCDC_TDSEL_LATENCY, which is a WRITE latency and drags the other six bits
  ## with it (the `run` chain in mem_apply_pipeline is monotonic); every nonzero
  ## setting of that costs three gambatte `window` rows.
  ##
  ## The DMG is exactly right, so this is a real CGB delta and not an absorbed
  ## phase error: `m3_lcdc_tile_sel_change` and `_win_change` are 23040/23040
  ## against `_dmg_blob`, each eighteen independent measurements of this
  ## register's write dot against the fetch cycle.
  ##
  ## Derived off `m3_lcdc_tile_sel_change2`'s CGB reference, which reads out the
  ## bytes: background `ABCDEFGH...` on map rows 0..7 with LCDC.4 = 0, only $9490
  ## initialised, so every 8 aligned pixels invert through BGP = $E4 into one
  ## (plane 0, plane 1) pair naming the tile and plane hardware read. Reading
  ## column 2 per band, fetch reads at p0 and p0 + 2:
  ##
  ##   band   hardware              dingbat at latency 0
  ##   0..2   C.0 / C.1             C.0 / C.1        write at or before p0
  ##   3      <glitch> / C.1        C.0 / C.1        write ON p0 (hardware)
  ##   4      $00 / C.1             C.0 / C.1        write at p0 + 1
  ##   5      $00 / <glitch>        $00 / C.1        write ON p1 (hardware)
  ##   6      $00 / $00             $00 / C.1
  ##   7      $00 / $00             $00 / $00
  ##
  ## The bands step the write one dot each, and hardware's write reaches the
  ## fetcher one band later than dingbat's throughout. One dot, bracketed both
  ## sides, on a row whose DMG twin is pixel-exact.
  ##
  ## Independently: it is the only value that puts `cgb-acid-hell`'s anomaly on
  ## the plane it is observed on -- that ROM writes LCDC every 8 dots at 8n+1 with
  ## bitplane reads at 8n+0 and 8n+2, so 0 puts the change between the reads, -1
  ## on the low plane, and only +1 on the high one.
  ##
  ## The one quantity CGB_PIPE_MCYCLES does not resolve: advancing the CGB
  ## pipeline one M-cycle moves this write four dots around the 8-dot fetch
  ## lattice, so the compensated value would be 5. It is not takeable, because
  ## the two witnesses do not share an anchor -- the four mealybug `tile_sel`
  ## frames sync on mode 2, which moves with the pipeline, so they still want 1;
  ## `cgb-acid-hell` syncs on LYC, which does not move, so it wants 5. A strict
  ## two-sided bracket, measured world against world with no reference image in
  ## the loop:
  ##
  ##   value   mealybug tile_sel CGB (4 frames)      cgb-acid-hell
  ##   1 ship  byte-identical to the pre-advance     23038/23040
  ##   5       3859 wrong px (1468 + 1525 + 866)     byte-identical
  ##
  ## 1 ships because it costs 2 pixels and 5 costs 3859. The four mealybug frames
  ## score identically before and after the advance, so the cell alignment did not
  ## move. The residue is the phase moving acid-hell's write off the read dot;
  ## CGB_TDSEL_IDX_DOTS carries the read-level bracket showing no refinement
  ## recovers it without costing 64 mealybug reads.
  ##
  ## Note `cgb-acid-hell`'s reference is a C/E-class capture (exact at
  ## `--cgb-rev=C` and `=E`, 22864/23040 at `=D` pre-advance), where daid's
  ## `.gbc.png` is D-class. Two ROMs, two machines.
const CGB_TDSEL_GLITCH*       {.booldefine.} = true
  ## Whether an LCDC.4 change landing ON a background bitplane read glitches it,
  ## and with what. mealybug's PPU notes describe the effect; what the
  ## `m3_lcdc_tile_sel_change2` decode adds is which branch fires when, because
  ## that frame names the byte. Glitched cells of the six affected columns
  ## (`IDX` = tile index, `X.p` = tile X's plane p):
  ##
  ##   band   col2 SET   col3 RST   col5 SET   col6 RST   col8 SET   col9 RST
  ##   3      '3'.1      IDX        D.0        IDX        G.0        IDX
  ##   5      '5'.1      IDX        D.1        IDX        G.1        IDX
  ##
  ## Two rules, neither with a free parameter:
  ##
  ##  * a RESET on the read dot delivers the TILE INDEX as that bitplane's byte
  ##    (columns 3, 6, 9 hold $44, $47, $4A constant down the band, which no
  ##    tile-data read can be). This is the notes' wording verbatim.
  ##  * a SET on the read dot delivers the byte at the address of the most recent
  ##    $8000-REGION tile-data read. The object fetch's last read is its bitplane
  ##    1, which is why the first glitch of a line reports the object's plane 1 at
  ##    EITHER plane; after that the RESET-glitched read has driven its own
  ##    address, which is why col 5 reports `D` and col 8 reports `G`, each at the
  ##    glitch's plane. The notes list both as alternatives without saying which
  ##    fires; an address latch is the one mechanism producing both.
  ##
  ## What writes the latch and when it clears: `*_change2` cannot see either
  ## question (every SET glitch there is preceded on its line by an object fetch
  ## or a RESET-glitched read). The plain `m3_lcdc_tile_sel_change` and
  ## `_win_change` on CGB can, and were this pair's whole residual (232 and 1422
  ## wrong subpixels; both 23040/23040 now). Scoring the four CGB references'
  ## glitched reads by the byte each pins:
  ##
  ##   latch written by                     cleared per line   SET cells right
  ##   obj + RESET-glitched reads           yes                 133 / 161
  ##   + every unglitched LCDC.4 = 1 read   yes                 133 / 161
  ##   obj + RESET-glitched reads           no                  158 / 161
  ##   + every unglitched LCDC.4 = 1 read   no                  159 / 161
  ##
  ## Both arms are forced by a whole band, not a cell: the latch is a bus register
  ## that H-Blank does NOT clear (`m3_lcdc_tile_sel_change` writes LCDC at dot 105
  ## with its object at 112, so its first glitched read per line precedes anything
  ## driving an $8000 address, and hardware still substitutes -- with the byte the
  ## line above left), and an unglitched LCDC.4 = 1 read leaves its address here
  ## too (the last 8 pixels of `_win_change`).
  ##
  ## A plain DATA latch (last byte rather than last address) is refuted by a whole
  ## band: 89/161, because `*_change2`'s two bands glitch on different PLANES and
  ## hardware answers with the same tile at the glitch's plane. Only an address
  ## does that -- worth knowing, since a data latch is cheaper and is what the
  ## notes' wording suggests.
  ##
  ## `cgb-acid-hell`'s two pixels are the one exception: CGB_TDSEL_IDX_DOTS below.
const CGB_TDSEL_IDX_DOTS*     {.intdefine.} = 8
  ## How long a RESET glitch leaves the INDEX path armed, in dots. A SET glitch
  ## inside that window delivers the CURRENT tile's index instead of the address
  ## latch. 0 is the control build, where a SET is always the latch.
  ##
  ## ---- What the corpus proves ----------------------------------------------
  ##
  ## Scored over every glitched bitplane read of the four CGB `tile_sel`
  ## references plus `cgb-acid-hell` whose bits the reference PNG pins (192 RESET
  ## / 223 SET cells, 2026-08-12). Cells, not pixels:
  ##
  ##   SET-branch trigger for "deliver the index"        SET cells right
  ##   never (the address-latch rule alone)                 221 / 223
  ##   always                                               125 / 223
  ##   the latch was written by a RESET glitch, any age     158 / 223
  ##   the IMMEDIATELY preceding read was RESET-glitched    221 / 223
  ##   the latch is <= 8 dots old, whatever wrote it        215 / 223
  ##   a RESET glitch landed <= 8 dots ago                  223 / 223
  ##   ...and it wrote the latch, i.e. nothing since  <--   223 / 223
  ##
  ## Both halves of the trigger are forced by a whole band: not recency alone
  ## (`*_change2`'s first glitch per line has an object fetch 8 dots behind it and
  ## wants the LATCH -- 8 cells), not provenance alone (its columns 5 and 8 have
  ## latches written by the RESET glitch two tile columns back and want the LATCH
  ## -- 64 cells), and not "the immediately preceding read" (acid-hell's RESET
  ## glitch is the previous FETCH's read of the same plane, with an unglitched
  ## signed read between; that spelling misses the two pixels it was written for).
  ##
  ## Bracketed to 8..15 dots and no narrower: 7 loses acid-hell (its RESET glitch
  ## is exactly 8 dots back), 16 breaks `*_change2`'s 64 (theirs is exactly 16).
  ## 8 is the fetch cycle's own pitch, so the rule reads "the RESET glitch was in
  ## this fetch or the one before it". In dots, not reads: the two agree wherever
  ## the fetcher runs at pitch, and dots need no counter.
  ##
  ## The shipping row is the last one because the PACKING gives it free -- the
  ## arming rides `tdsel_addr` above the bank (TDSEL_IDX_SHIFT), so anything
  ## writing the latch disarms it. No cell separates it from the looser row.
  ##
  ## ---- What the corpus does NOT prove --------------------------------------
  ##
  ## The distinguishing bucket is populated by ONE ROM. At every setting in 8..15
  ## the trigger fires on exactly seven cells, all `cgb-acid-hell`'s, changing no
  ## other pixel in the tree. Five of the seven have index and latch holding the
  ## same byte, so the arbitrating evidence is two pixels -- `(80, 68)` and
  ## `(80, 69)`, hardware-photo-verified against `img/photo.jpg`.
  ##
  ## The settling experiment does not exist: it needs a hardware capture of
  ## `*_change2` with its LCDC writes on an 8-dot lattice, or any second ROM
  ## putting a SET glitch one fetch behind a RESET one. `*_change2` are the only
  ## ROMs with the readout and their handler writes on a 16-dot pitch.
  ##
  ## The corpus does not arbitrate against the one alternative either: one M-cycle
  ## of CGB halt phase. At `CGB_HALT_PPU_LEAD=2` this ROM's glitching write becomes
  ## the RESET one 8 dots earlier, the seven cells move to the RESET column, and
  ## `CGB_TDSEL_IDX_DOTS=0` scores 216/216 SET and 199/199 RESET with acid-hell at
  ## 23040 -- strictly simpler. The shipping rule rests on the halt bracket, not
  ## the corpus: `halt/lycirq_m2stat_{1,2}` and `halt/m1int_ly_{1,2}` are green
  ## together only at LEAD 0 or 1, and `lycirq_*` is this ROM's own IME-clear path.
  ## The CelestialAmber disassembly reads the ROM the other way and says the reset
  ## rule is the whole trick; its own dot arithmetic lands on the SET once the
  ## 6-dot object delay it documents is applied. Both sides:
  ## docs/gb-failure-triage.md (2026-08-13) -- read it before changing anything.
  ##
  ## ---- The shipping world: this constant has no live evidence in it ---------
  ##
  ## `CGB_PIPE_MCYCLES = 1` and `CGB_HALT_PPU_LEAD = 1` both move this ROM's write
  ## lattice 4 dots into the tile-MAP slot, where NO bitplane read of the frame has
  ## an LCDC.4 change on its dot. The census drops to 408 cells (216 SET / 192
  ## RESET, still 216/216 and 192/192), this constant fires on nothing at any
  ## window in 0..19, and the row is 23038 whatever it is set to. Every trigger
  ## hypothesis above -- including `never`, i.e. deleting this constant -- scores
  ## the same 216/216. The rule is still believed (it is what the 223/223 world
  ## measured) but nothing in the tree can now falsify it: do NOT read 216/216 as
  ## support.
  ##
  ## The trade if the lattice is put back is bounded and small:
  ## `CGB_TDSEL_LATENCY = 5` takes acid-hell to 23040 and costs the four mealybug
  ## frames 3859 pixels, because their writes DID move with their mode-2 anchor.
  ##
  ## A rule firing in the map slot instead is refused by 48 `*_change2` cells in
  ## the identical bucket. The read-level bracket a refinement would have to beat
  ## (`tools/gbppu/tdselphase.py`, splitting the one bucket that could fix the row
  ## -- mapoff=0, read offset +4, RESET, 71 reads -- by the change before last):
  ##
  ##   prev2off   reads   hardware wants INDEX   hardware wants SGN   ROM
  ##   -32            7                      7                    5   acid-hell
  ##   -24           32                      0                   32   mealybug
  ##   None          24                      8                   24   mealybug
  ##   (prevdir -1)   8                      8                    8   mealybug
  ##
  ## Firing on the whole bucket buys acid-hell's 2 and costs 64 mealybug reads.
  ## The only feature separating acid-hell's seven from the 32 hard refusers is
  ## `prev2off = -32` against `-24` -- one ROM's fingerprint, on a context no
  ## second ROM populates. So the 2 pixels are an integration decision, not a
  ## modelling one, and 4 dots (not this constant) is what stands between the tree
  ## and `LEAD=1`.
  ##
  ## A revision split is excluded, not merely unsupported: acid-hell picks its tile
  ## data off a `$FEA0` readback and dingbat takes the branch the bundled reference
  ## was captured on, a CGB-C, as is every `*_change2` reference. `$FEA0..$FEFF` is
  ## modelled per revision now (GbUnusableRegion) and the row is 23040/23040 on
  ## 0/A/B/C/E and the default, 22864 on D alone -- the ROM refusing CGB-D on
  ## purpose. The default branch is unchanged; it is now taken because a C-class
  ## machine reads `$44` back, rather than because the region was unmodelled.
  ##
  ## Assumed beyond the two pixels, deliberately minimally: the window is not
  ## consumed by the SET glitch that uses it (no cell has two SET glitches behind
  ## one RESET), the substituted byte is the CURRENT tile's index and not the
  ## RESET-glitched tile's (line 68's tile is $55 and hardware's byte is $55, while
  ## the RESET-glitched tile one fetch back is $59), and the address latch is left
  ## as the rule above leaves it.
  ##
  ## Cost: +0.05..0.08% Pokemon Crystal, +0.02% blargg cpu_instrs, +0.05% Link's
  ## Awakening DX retired instructions -- effectively the one guarded compare per
  ## line in fifo_reset_sprite, since the arming rides a store the RESET branch
  ## already did and the dot loop never sees the rule. The unpacked shape, same
  ## behaviour, was +0.30 / +0.21 / +0.22%; see TDSEL_IDX_SHIFT.
const CGB_TDSEL_ANY* = CGB_TDSEL_LATENCY != 0 or CGB_TDSEL_GLITCH
const CGB_MAP_ANY* = CGB_MAP_LATENCY != 0
  ## Whether anything records the map-select bits' change dot. `-d:CGB_MAP_LATENCY=0`
  ## is the control build and reproduces the pre-2026-08-19 numbers exactly.
const CGB_WY_LATCH_LATENCY*   {.intdefine.} = 0
const WIN_EN_ABORT*           {.intdefine.} = 1
  ## Whether clearing LCDC.5 mid-mode-3 returns the fetcher to background tiles on
  ## this line. 1 ships; 0 restores the old behaviour, where `fetching_window`
  ## could not be cleared before the next line. Rule and citation at
  ## tick_bg_fetcher.
  ##
  ## DMG behaviour, not CGB: mealybug documents it in its PPU notes and measures
  ## it with two ROMs whose scored references are `_dmg_blob`. dingbat used to file
  ## it as SameBoy's CGB-only fetcher abort and not model it. Worth
  ## m3_lcdc_win_en_change_multiple 8874 wrong pixels -> 0 (both devices),
  ## `_wx` 4215 -> 343, DMG total +12746 and CGB +25758, plus three gambatte
  ## window/on_screen rows.
const WIN_EN_HOLD*            {.intdefine.} = 2
  ## Dots a WX match that LCDC.5 refused stays live, waiting for the bit. 0 is the
  ## control build and the pre-2026-08-09 behaviour (the match is dropped).
  ##
  ## mealybug `m3_lcdc_win_en_change_multiple_wx` is the ruler: it writes WX = LY,
  ## then clears LCDC.5 over dots 97..104 of every line and again over 125..132, so
  ## the trigger pixel `t = LY - 7` walks one dot per line through both pulses and
  ## the frame reads out what a match at each offset does. Its reference:
  ##
  ##   t (band 1)      0    1  2  3..7    8      9     10     11
  ##   match dot      94   95 96 97..101 102    103    104    105
  ##   reference     x=0   -- -- --      one    x=10   x=10   x=11
  ##                                     white
  ##
  ## Band 2 repeats it at t = 28..39. The two obvious readings are refused by the
  ## two ends of that table. Sampling the bit at the match dot alone
  ## (`WIN_EN_HOLD = 0`) draws nothing at t = 9 and 10 where hardware draws a whole
  ## window -- 296 wrong pixels. Sampling at the fetcher's tile-map read two dots
  ## later gets every band edge right but must RESTART the fetch before it knows
  ## the answer, which gambatte refuses from the other side: `window/late_disable_*`,
  ## `late_reenable_*` and 36 `sprites/space/*` read STAT expecting mode 0 and get
  ## mode 3, because the restart still costs the line six dots (3827 -> 3750,
  ## window -40). Hardware pays nothing for a match it refuses.
  ##
  ## So the match is not dropped and not committed: it WAITS. Two dots is what the
  ## table brackets from both ends of both bands -- t = 9's match waits two dots
  ## for the bit and t = 8's, one dot earlier, expires unserved (three would serve
  ## t = 8). And the window starts on the dot the bit ARRIVES, not the dot it
  ## matched, which is why t = 9 and t = 10 both draw from x = 10 (band 2: t = 37
  ## and 38 both from x = 38). That coincidence is the sharpest thing in the row --
  ## two adjacent scanlines whose windows begin at the same x, which no rule
  ## starting the window at its own match pixel can produce.
  ##
  ## Worth 296 wrong pixels -> 4. Nothing else in mealybug moves and no gambatte
  ## row does: a refused match costs no dots, so every family keeps its length.
const CGB_WIN_EN_HOLD*        {.intdefine.} = 0
  ## WIN_EN_HOLD on CGB, which is not the same number. The evidence is thin on
  ## purpose: mealybug's `_cgb_c` reference for the row above is pixel-exact with
  ## and without the hold, so it says nothing. The only instrument separating the
  ## devices is gambatte `window/late_reenable_scx5_2`, whose DMG half wants mode 3
  ## still running at the read (the hold) and whose CGB half wants mode 0 (no
  ## hold); `late_reenable_scx2_2` says the same one SCX apart, and
  ## `window/late_enable_ly0_ds_2` refuses a CGB hold from the other direction.
  ## DMG holds, CGB does not. This is the constant that moves if a CGB ruler turns up.
  ## Whether a match that WAITED starts the window one pixel left of the pixel
  ## the shifter has reached (1, shipping) or at that pixel (0). The ruler
  ## above pins it: at 0, `t = 9` and `t = 10` both draw from x = 11 where the
  ## reference has x = 10, and band 2's pair from x = 39 against x = 38 -- 10
  ## wrong pixels against 4.
  ##
  ## It is the SAME slot the comparator sits in -- "its counter runs one lower
  ## than the emitted-pixel index" (WIN_START_PRE_PIXEL) -- and it is what makes
  ## two adjacent scanlines of the ruler begin their windows at the same x,
  ## which is the part of that reference no rule anchored to the match pixel
  ## can produce. The pixel it takes back has already been written as
  ## background and the window's first push writes over it.
  ##
  ## Two gambatte rows bracket the dot it costs, and they are the two halves of
  ## one family: `window/late_reenable_scx2_2` [dmg] wants mode 3 still running
  ## at its read, which needs the served restart to be one dot later than the
  ## drawn-through hold makes it (this rule, green), and
  ## `window/late_disable_scx2_0` [dmg] wants mode 0 on a line whose match is
  ## refused and never served, which needs an UNSERVED hold to cost nothing
  ## (also this rule, green -- the dot is taken at the serve, not at the
  ## match). Spending the dot at the match instead costs the second row.
const WIN_EN_HOLD_BACK*       {.intdefine.} = 1
  ## Whether a match that WAITED starts the window one pixel left of the pixel
  ## the shifter has reached (1, shipping) or at that pixel (0). The ruler above
  ## pins it: at 0, `t = 9` and `t = 10` both draw from x = 11 where the reference
  ## has x = 10, and band 2's pair from x = 39 against x = 38 -- 10 wrong pixels
  ## against 4.
  ##
  ## Same slot the comparator sits in (WIN_START_PRE_PIXEL: its counter runs one
  ## lower than the emitted-pixel index), and it is what makes two adjacent
  ## scanlines of the ruler begin their windows at the same x. The pixel it takes
  ## back has already been written as background and the window's first push
  ## overwrites it.
  ##
  ## Two halves of one gambatte family bracket the dot it costs:
  ## `window/late_reenable_scx2_2` [dmg] wants mode 3 still running at its read,
  ## which needs the served restart one dot later than the drawn-through hold
  ## makes it; `window/late_disable_scx2_0` [dmg] wants mode 0 on a line whose
  ## match is refused and never served, which needs an UNSERVED hold to cost
  ## nothing. Both green -- the dot is taken at the serve, not at the match.
  ## Spending it at the match instead costs the second row.
const WIN_EN_HOLD_ZERO*       {.intdefine.} = 1
  ## Whether a refused match that lands on the fetcher's PUSH dot puts one
  ## pixel of colour 0 on the front of the FIFO (1, shipping) or leaves it
  ## alone (0).
  ##
  ## The ruler carries exactly two of these and they are its last two wrong
  ## pixels: `t = 8` and `t = 32`, the only refused matches in either band whose
  ## pixel is a multiple of 8, i.e. the only two the fetcher pushes on. Both
  ## read out as a single WHITE pixel at the match column with the background
  ## unshifted either side of it -- no window, no stall, one colour-0 pixel.
  ## Every other refused match in the frame is at a phase where the FIFO
  ## already holds pixels and hardware shows nothing at all, and the two
  ## SERVED matches on push dots (`t = 16`, `t = 24`) show the window's own
  ## black at that column, so it is the collision of a refused start with the
  ## push, and not the push or the start on its own.
  ##
  ## Costs nothing: the entry is replaced rather than dropped, so the shifter
  ## does not stall and mode 3 does not move. Worth 2 wrong pixels; no other
  ## mealybug row and no gambatte row has a refused match on a push dot.
  ##
  ## Gated on `window_trigger_en` (a WY match seen while LCDC.5 was SET this
  ## frame): a game that never enables its window must not glitch. Pokemon
  ## Blue rests at WX = 7 / WY = 0 with the window off, its refused match
  ## lands on the line's initial fill (also `size == 8`) every line, and
  ## silicon draws no white column through its intro. This is the well-known
  ## Star Trek 25th Anniversary insertion glitch (Pan Docs "Window", SameBoy
  ## issue #278): nitro2k01's SGB logic traces condition it on the window
  ## having been activated first, and SameBoy (wy_check) and DocBoy
  ## (w.active_for_frame) both put the enable term inside the frame latch.
  ## Where this model still differs from both of them — a hardware question
  ## for the flashcart, see docs/hwprobe-questions.md: they INSERT the pixel
  ## into an empty FIFO and delay the line by a dot; the mealybug reference
  ## reads back unshifted either side, so this model REPLACES.
const WIN_LINE_START_WX*      {.intdefine.} = 6
  ## The WX below which a line STARTS as a window line instead of reaching the
  ## window through the shifter's equality. See the mode 2 -> 3 edge in
  ## fifo_tick_slow for what the two spellings mean; this is the boundary
  ## between them and mealybug is its only oracle.
  ##
  ## gambatte brackets WX = 0 (m2int_wx00_*) and WX = 7 (m2int_wx07_*) and has
  ## NOTHING at 4, 5 or 6, so the three m3_wx_{4,5,6}_change ROMs are the whole
  ## evidence for where in that gap the boundary falls. Swept 2026-08-07, wrong
  ## pixels of 23040 on the DMG references, and the mealybug DMG total of
  ## 3,317,760 next to it:
  ##
  ##   threshold   wx_4   wx_5    wx_6   window_timing   mealybug DMG
  ##       5          0  13768    4611        30            515691
  ##       6 (ship)   0      0    4611        29            529314
  ##       7          0      0   13810        35            520109
  ##       8          0      0   13810        41            517392
  ##
  ## Three ROMs, one boundary, and only 6 satisfies all of them: 5 breaks WX = 5
  ## outright and 7 and 8 leave WX = 6 at three times its error. It is worth
  ## +9205 DMG pixels on its own, the largest single move in the mealybug set,
  ## and it moves nothing in gambatte -- WX = 6 is the only value whose
  ## treatment changes, and no gambatte ROM writes it.
  ##
  ## What it does NOT do is make m3_wx_6_change pass: 4611 pixels remain, and
  ## they are a different mechanism (the window line advancing on a mid-line
  ## re-activation -- see docs/gb-failure-triage.md). This constant is pinned
  ## from both sides regardless of that residual, which is why it ships without
  ## it.
const WIN_HEAD_ABSORB*        {.intdefine.} = 1
  ## Whether a line that STARTS as a window line pays its `7 - WX` fine-scroll
  ## discard OUT OF the window's own six-dot startup fetch (1, shipping) or on
  ## top of it (0, the pre-2026-08-09 behaviour). With it, mode 3 is `172 + 6`
  ## for every WX below WIN_LINE_START_WX -- the same length a WX >= 7 window
  ## start has, which is what mealybug m3_window_timing's flat reference says.
  ##
  ## The derivation and the ruler it is read off are at the head latch in
  ## fifo_ppu.nim.
const WIN_WX0_PHASE*          {.intdefine.} = 1
  ## Where WX = 0's line-start window puts its FIRST TILE, and where the extra
  ## dot that goes with SCX > 0 is spent. 1 ships: the discard is `7 - WX` at
  ## every WX (so seven at WX = 0) and the head's idle term is `WX - 1`
  ## unclamped, which at WX = 0 is *minus one* -- a startup fetch one dot
  ## shorter, taken by skipping one of FETCHER_ORDER's sleeps so the push
  ## arrives a dot early. 0 is the control build and the pre-2026-08-09
  ## spelling: a six-pixel discard at WX = 0 with `SCX & 7 = 0` and zero idle
  ## dots.
  ##
  ## Both spend the same DOTS -- `idle + discard = 6`, which is what every
  ## length instrument in the tree measures and none of them moves. What they
  ## disagree about is the window's tile PHASE, one pixel, and exactly one ROM
  ## can see it: mealybug `m3_lcdc_win_en_change_multiple_wx` turns the window
  ## off again partway across every line, and the background resumes on the
  ## WINDOW's tile boundary ("it will always display a multiple of 8 pixels,
  ## except when the window begins off the left edge of the screen" --
  ## `m3_lcdc_win_en_change_multiple.asm:21`). So the boundary reads the phase
  ## straight off the reference, per line, with WX = LY:
  ##
  ##   WX (= LY)      0    1    2    3    4    5    6    7
  ##   black run      9   10    3    4    5    6    7    8
  ##   first tile   -7..0 -6..1 -5..2 -4..3 -3..4 -2..5 -1..6  0..7
  ##
  ## Every WX from 1 up is `first tile = (WX - 7) .. WX`, the window's own
  ## first pixel; WX = 0 is the same formula and NOT the six-pixel exception
  ## (its run is 9 = one tile boundary at x = 1, plus the eight pixels of the
  ## tile after it, the same "one tile later" WX = 1's 10 is).
  ##
  ## The dot it hands back is the one the sampler used to pay: "window
  ## activating one T-cycle later when WX = 0 and SCX > 0"
  ## (`m3_window_timing_wx_0.asm:21`) is now the ABSENCE of that skip, which is
  ## what "activating later" says, instead of a ninth discarded pixel. The test
  ## is taken at the dot SCX is latched on, because that is the first dot the
  ## answer exists on -- see fifo_sample_smooth_scroll.
const WIN_LINE_START_LATCH*   {.intdefine.} = 1
  ## Which dot WX is read on to decide whether a line STARTS as a window line:
  ## the last dot of the throw-away fetch at the head of mode 3 (1, shipping),
  ## or the mode 2 -> 3 edge six dots earlier (0, the pre-2026-08-09
  ## behaviour). Bracketed from both sides by two mealybug ROMs; see the head
  ## latch in fifo_ppu.nim.
const WIN_START_PRE_PIXEL*    {.intdefine.} = 1
  ## Whether the window's WX comparator can match one pixel slot to the LEFT of
  ## the shifter's first pixel -- screen x = -1 when SCX & 7 = 0, i.e. WX = 6.
  ## 1 ships; 0 is the control build and compiles the clamp out.
  ##
  ## Derivation, and the two-sided bracket that fixes it to exactly one slot,
  ## at `fifo_arm_window` in gb/fifo_ppu.nim. It is a different mechanism from
  ## WIN_LINE_START_WX below, and the two do not overlap: that one reads WX at
  ## the mode 2 -> 3 edge and starts the whole line as a window line, this one
  ## reads WX at the shifter's first dot and reaches the same place through the
  ## ordinary equality. m3_wx_6_change needs both and distinguishes them,
  ## because it writes WX = 6 at dot 49 (mode 2) and WX = LY at dot 93: the
  ## mode-2 value is 6 on every line and the reference draws no window on
  ## LY 4 or 5, which refuses WIN_LINE_START_WX = 7 outright.
const WIN_PRE_PX_PHASE*       {.intdefine.} = 1
  ## What a match on the comparator's PRE-PIXEL slot (WIN_START_PRE_PIXEL) does
  ## with the window's TILE. 1 ships: the tile keeps its own first pixel, so it
  ## covers `WX - 7 .. WX` exactly as at every other WX, and the startup fetch
  ## is one dot shorter because one of its six dots was spent before the shifter
  ## got to its first pixel. 0 is the control build and the pre-2026-08-09
  ## spelling, where the clamp moved the tile with the match and the window's
  ## first tile covered `0 .. 7`.
  ##
  ## The mode 3 LENGTH is identical either way, by construction -- five dots of
  ## fetch plus the pixel at x = -1 is six dots plus the pixel at x = 0 -- so
  ## every length instrument that pinned the clamp (GBMicrotest `win6_a/_b` at
  ## 178, gambatte's WX = 3 families) reads exactly what it read before. What
  ## moves is one pixel of phase, and mealybug
  ## `m3_lcdc_win_en_change_multiple_wx` is again the only ROM that can see it:
  ## on its WX = 6 line the background resumes at x = 7, i.e. on the boundary of
  ## a window tile that covers `-1 .. 6`, where the clamped tile would put it at
  ## x = 8. That is the same reading as WIN_WX0_PHASE at the other end of the
  ## same table, and the same conclusion -- the window's tile sits where its own
  ## first pixel is, and the clamp is only about which dot our shifter can
  ## notice it on.
const WIN_RESTART_COUNTER*    {.intdefine.} = 0
const CGB_WIN_RESTART_COUNTER* {.intdefine.} = 0
  ## Which fetcher step a WINDOW start's restarted fetch resumes at, per model.
  ## 0 is fetch_counter 0, the first of the two dots step 1 lasts, which makes
  ## the startup fetch six dots and takes the early push (Pan Docs' "6 dots";
  ## see fifo_reset_bg). 1 makes it five.
  ##
  ## Separate from the LINE-START reset, which shares fifo_reset_bg but is not
  ## a restart at all -- it is the head cycle, and the discarded fetch it begins
  ## has to start at 0 whatever these say. Probe (f) is the instrument that can
  ## tell them apart: it brings the window up mid-line at WX = 15 and reads the
  ## fetch grid after it, where the line-start path never runs.
  ##
  ## They are two knobs because probe (f) says the two models disagree, and it
  ## says so on both sides of the same instrument. Scored by BASE equivalence
  ## (tools/gbprobe/probe_f_base.sh: sweep the probe's write position in dingbat
  ## and ask which single value reproduces the oracle's columns exactly):
  ##
  ##   DMG, counter 0 : 8/8 residues            <- already right, do not touch
  ##   CGB, counter 0 : 2/8 residues, no common BASE
  ##   CGB, counter 1 : 7/8 residues, ALL at BASE 24
  ##
  ## That last row is the shape of the claim: at counter 1 the CGB's windowed
  ## staircase differs from silicon by ONE uniform phase offset and nothing
  ## else, and that offset is the same 8 dots the window-less arm carries
  ## (probe (e)), i.e. a bug this knob is not about. At counter 0 there is no
  ## offset that works at all. The DMG column is why this is not the global
  ## knob: counter 0 against 1 was worth mealybug DMG +361 pixels when the
  ## fetcher's padding was moved in 2026-08-03, and probe (f) agrees with those
  ## pixels -- the DMG's startup fetch really is six dots. The CGB's is five.
const WIN_TAIL_FETCH*         {.intdefine.} = 1
  ## Whether a window START holds mode 3 open for the fetch it restarts, when
  ## the start lands inside the last pixels of the line. 1 ships; 0 is the
  ## control build and restores the pre-2026-08-09 behaviour, where the restart
  ## was absorbed by the pipeline's tail burst and cost nothing.
  ##
  ## That was an accident of `fetcher_retired`'s shape rather than a rule: the
  ## term that keeps mode 3 open for a window which has not started yet is
  ## written `not fetching_window and ...`, so the instant the window DOES
  ## start the term goes false and, with nothing else owing, the fetcher
  ## retires on that same dot -- restart, push and pixel all in one burst.
  ## Nothing about hardware says a window start is free: it empties the BG FIFO
  ## and the pixel it starts on cannot be drawn until the refetch pushes.
  ##
  ## Bracketed by `window/m2int_wxA5_m3stat` (WX = 165, first window pixel
  ## x = 158, so the restart lands one pixel inside the tail), which is red on
  ## BOTH devices without this -- `_1` wants 3 and gets 0, i.e. mode 3 ends too
  ## early -- and green on both with it. See CGB_WIN_TAIL_LAST for WX = 166,
  ## which needs this AND the device split before either device's rows are
  ## right, and `fetch_work_pending` in gb/fifo_ppu.nim for the code.
const DMG_WIN_START_LAST_PX* {.intdefine.} = 0
  ## The same device split as `CGB_WIN_TAIL_LAST` next door, carried to the
  ## SHIFTER instead of to mode 3's length: on a DMG a window START on the
  ## line's last pixel (only WX = 166 can produce one) does not happen at all.
  ##
  ## **Ships OFF: this exact spelling is refused by the frames.** See
  ## `win_start_reaches_pixels` in fifo_ppu.nim for the oracle, which is
  ## unusually strong -- 14 ROMs whose two device references differ, where
  ## dingbat's DMG output matches the CGB reference to the pixel -- and for
  ## which half of the rule survives.
  ##
  ## Superseded by `DMG_WIN_LAST_PX_CARRY` below, which is the half that DOES
  ## survive: the start happens, its first pixel does not reach the screen, and
  ## the start is still owed on the NEXT line.

const DMG_WIN_LAST_PX_CARRY* {.intdefine.} = 1
  ## **The DMG's window start on the line's LAST pixel is not lost -- it is
  ## owed to the next line.** The pixel-path half of `CGB_WIN_TAIL_LAST`, and
  ## the whole of `window/on_screen`. 1 ships; 0 is the control build and the
  ## pre-2026-08-13 behaviour, where the restart's tile was shifted out on the
  ## last pixel of the same line and nothing carried.
  ##
  ## `CGB_WIN_TAIL_LAST` says the DMG's mode 3 ends with the last PIXEL and the
  ## CGB's with the last FETCH. Read that as a statement about WHEN the line's
  ## end-of-line cleanup runs and the rest follows on its own: hardware's
  ## "the window has started" latch is set by the WX comparator and cleared when
  ## the line ends, so on a DMG a match on the last pixel lands on the same dot
  ## as the clear and survives it, while on a CGB the extra fetch pushes the
  ## clear past the match and it does not. Only WX = 166 can put a match there,
  ## which is why the whole affected set is `window/on_screen/wxA6_*`.
  ##
  ## Three consequences, all measured against gambatte's reference PAIRS (every
  ## `on_screen` ROM ships a `_dmg08` and a `_cgb04c` PNG, and the 14 whose two
  ## references differ were exactly the 14 failing rows):
  ##
  ##   * the restart's first pixel is never shifted out, so x = 159 keeps the
  ##     BACKGROUND pixel the FIFO was already holding. `wxA6_late_we_reenable_4`
  ##     is that alone -- 120 lines, one pixel each, at x = 159;
  ##   * the latch is still set at the head of the NEXT line, so that line is a
  ##     window line from x = 0 with no WX match of its own. `wxA6_wy8F` is that
  ##     alone: its only window match is on LY 143 and its only wrong line is
  ##     LY 0 of the frame after, so the latch crosses the frame boundary;
  ##   * the latch is consumed at the head only if LCDC.5 is set THERE, and it
  ##     is not cleared if it is not -- `wxA6_wy01_weoff_ly02` sets it on LY 1,
  ##     spends the rest of the frame with LCDC.5 clear, and still draws LY 0 of
  ##     the next frame as a window line.
  ##
  ## ---- Where the head consumes it, bracketed to one dot ---------------------
  ##
  ## `wxA6_late_we_reenable_1..4` clear LCDC.5 in mode 2 and set it again at dot
  ## 77, 81, 85 and 89 of the same line, every line. 77/81/85 are consumed (the
  ## next line is a window line, ~14.5k wrong pixels without this) and 89 is not
  ## (120 wrong pixels, the x = 159 half alone). Mode 3 starts at dot 80 and the
  ## throw-away fetch at its head ends at dot 86, which is where
  ## `fifo_head_window` already reads WX for `WIN_LINE_START_LATCH` -- the same
  ## dot, from the same ROM family shape. So the carry is consumed there and
  ## nowhere else.
  ##
  ## ---- What the carried line draws -----------------------------------------
  ##
  ## The window's own line counter is not special-cased: the head consumption
  ## counts as a start and increments it exactly as `fifo_head_window`'s WX < 7
  ## case does, and the aborted start on the previous line incremented it too.
  ## That makes it equal to LY on `wxA6_wy00` (a match on every line) and LY on
  ## `wxA6_wy01` as well (LY 1's aborted start, then one per carried line),
  ## which is what both references want to the pixel.
  ##
  ## The tile COLUMN is where the carried line differs from an ordinary window
  ## line: it starts at `WIN_CARRY_TILE`, not at 0. See that constant.
  ##
  ## ---- What it costs ------------------------------------------------------
  ##
  ## +0.29% of retired instructions on cgb-acid-hell and +0.20% on blargg
  ## cpu_instrs, against `-d:DMG_WIN_LAST_PX_CARRY=0` (which reproduces the
  ## pre-2026-08-13 gambatte score row for row, 4145/5005). Every per-dot term
  ## it adds is behind `not ppu.cgb`, so a CGB pays the branch and nothing else;
  ## the rest is once a line. The shape matters far more than the terms do --
  ## see the inline-cliff note on `fifo_emit_pixel` in fifo_ppu.nim, where the
  ## same rule written with an `{.inline.}` proc instead of a template measured
  ## **+3.63%**.
  ##
  ## ---- What is still red --------------------------------------------------
  ##
  ## `window/on_screen` is 34 of its 36 rows with this. What is left is
  ## `wxA6_late_we_reenable_3 [dmg]` (916 wrong pixels): its rows are one line
  ## early for the whole frame, i.e. ONE window line too many across 127 lines,
  ## and its only difference from `_1`/`_2` (both green) is that it puts LCDC.5
  ## back at dot 85 instead of 77 or 81. Suppressing the WIN_CARRY_REACT_LINES
  ## credit for it wholesale is refused -- that takes it to 6520 -- so the extra
  ## line is being taken on ONE line and not on all of them, which is a rule
  ## about the first reactivated line that this constant does not carry. (The
  ## other red row, `wx17_weoff_wxA5_weon [cgb]`, is a CGB row and predates all
  ## of this.)

const WIN_CARRY_TILE*        {.intdefine.} = 1
  ## The window tile column a carried start (DMG_WIN_LAST_PX_CARRY) draws first.
  ##
  ## 1, not 0: the aborted start on the previous line ran the map read for
  ## column 0 and the counter moved with it, so the first column the carried
  ## line can push is column 1. The `on_screen` window maps are a DIAGONAL --
  ## row `r` holds the one black tile at column `r` -- so this is worth a whole
  ## tile of the staircase, and every one of `wxA6_wy00`, `wxA6_wy01` and
  ## `wxA6_weoff_at_xposA6` puts the black tile one column LEFT of where the
  ## window row index alone would: LY 8..15 draw window row 1 with its black
  ## tile at screen x 0..7, not at 8..15. (A diagonal cannot tell a column shift
  ## from a row shift on its own; what fixes it as the column is that the row
  ## index is `current_window_line shr 3` and that counter is pinned
  ## independently by the CGB references, which draw window row 0 on LY 0..7.)

const WIN_CARRY_REACT_LINES* {.intdefine.} = 1
  ## Extra window LINES a carried start (DMG_WIN_LAST_PX_CARRY) counts when it
  ## has to REACTIVATE the window -- i.e. when LCDC.5 went low between the match
  ## that owed the start and the head that spends it. 0 is the control build.
  ##
  ## The counter is otherwise one per line the window draws, which is what
  ## `wxA6_wy00` and `wxA6_wy01` want (LCDC.5 never moves in either, and their
  ## window rows change every EIGHT lines). The two families that do move it
  ## want the rows every FOUR: `wxA6_late_we_reenable_1..3` clear LCDC.5 in
  ## mode 2 and set it again before the head, and `wxA6_weoff_at_xposA6` clears
  ## it mid-line at x = 96 and sets it again in H-Blank -- both once per line,
  ## both twice the counter. `wxA6_wy01_weoff_ly02_weon_ly60` is the same rule
  ## with ONE toggle in the frame instead of 144: its rows are one line late
  ## without this and exact with it.

const CGB_WIN_TAIL_LAST*      {.intdefine.} = 1
  ## Whether a window restart issued on the LINE'S LAST PIXEL holds mode 3
  ## open, which only the CGB does. 1 ships; 0 is the control build, where
  ## neither device waits for it and the two are identical again.
  ##
  ## Narrows WIN_TAIL_FETCH, and requires it. In one sentence: **the DMG's
  ## mode 3 ends with the last PIXEL and the CGB's with the last FETCH.**
  ## Everywhere else on a line the two coincide, because the fetcher runs ahead
  ## of the shifter and any restart it is handed has pixels after it to fill;
  ## the one place they can come apart is a restart whose own first pixel is
  ## x = 159, and only WX = 166 puts one there. That is exactly where gambatte
  ## splits the two devices.
  ##
  ## ---- What differs is the mode 3 END, and it is bracketed to 5..7 dots ----
  ##
  ## Every `window/m2int_wx*_m3stat` family in gambatte has IDENTICAL DMG and
  ## CGB expectations -- wx00, wx03, wx07, wxA5, wx17_wxA5, with and without
  ## SCX -- except at WX = 166, where all of them differ and the CGB is always
  ## the longer one. Each family is a ladder of ROMs `_1.._n` that read STAT
  ## one CPU M-cycle apart, so "the last `_n` that still reads mode 3" brackets
  ## the end of mode 3 to within 4 dots, and the DMG-CGB DIFFERENCE to within
  ## a window of 8 dots centred on 4 * (n_cgb - n_dmg):
  ##
  ##   family (all `window/m2int_wxA6_`)  last _n reading 3   difference
  ##                                        DMG      CGB      is inside
  ##   m3stat                                1        2       ( 0,  8)
  ##   scx2_m3stat                           1        3       ( 4, 12)
  ##   scx3_m3stat                           1        3       ( 4, 12)
  ##   scx5_m3stat                           1        2       ( 0,  8)
  ##
  ## (SCX moves the end of mode 3 by SCX & 7 dots, which slides the boundary
  ## across the M-cycle grid the ROMs sample on; that is why two of these
  ## families see one step and two see two, and it is what makes the four of
  ## them a two-sided bracket rather than four copies of one measurement.)
  ##
  ## The four intersect at **5..7 dots**, and a BG fetch is six -- Pan Docs'
  ## "6 dots from the fetch restart", and this fetcher's counter 0 -> push.
  ## `-d:gb_m3_len` on the wxA6 line reads 174 dots when the restart is issued
  ## and not waited for and 180 when it is waited for, against 172 for a plain
  ## line, so DMG = 174 / CGB = 180 is the only assignment the bracket allows
  ## and the split needs no constant of its own: it is one fetch, waited for on
  ## one device. `wxA6_oambusyread` and `wxA6_vrambusyread` carry the same
  ## split from the bus side (CGB `_2` reads 0 where DMG reads 5), so it is the
  ## END of mode 3 that moves and not the STAT read model.
  ##
  ## ---- What this is NOT, measured -----------------------------------------
  ##
  ## The tempting unification is that the DMG's window comparator runs one
  ## slot lower than the emitted-pixel index -- which is already forced at the
  ## LEFT end of the line, where a DMG starts a window at WX = 6, screen
  ## x = -1, and no reference says the CGB does (WIN_START_PRE_PIXEL). One
  ## offset would also stop the DMG one slot short of the LAST pixel, i.e.
  ## draw no window at all at WX = 166.
  ##
  ## **Refused, built and scored 2026-08-09.** It gives the DMG 172 dots where
  ## the bracket wants 174, and takes `window/m2int_wxA6_m3stat_1`,
  ## `_firstline_m3stat_1`, `_oambusyread_1` and `_vrambusyread_1` red on DMG.
  ## The DMG does reach the slot and does restart the fetch there -- those two
  ## dots are that slot. What it does not do is wait for the fetch. So the two
  ## ends of the line are two mechanisms and WIN_START_PRE_PIXEL stays
  ## device-independent.
  ##
  ## ---- An object on the same pixel is the SAME fetch slot, not a second ----
  ##
  ## The one place a fetch can already be in flight when the restart is issued
  ## is an object whose trigger pixel is also x = 159, i.e. WX = 166 with an
  ## object at X = 167. There the CGB's extra six is NOT charged again, which
  ## is what `obj_last_px` carries into fetch_work_pending: both devices come
  ## out at 180 dots, the plain 174 plus the object's own six.
  ##
  ## Four mode-0 INTERRUPT rows bracket that, and they are the ones to trust
  ## here because they read the flag's own dot rather than a STAT read three
  ## dots behind it (STAT_READ_LAG): `window/m2int_wxA6_spxA7_m0irq_1/_2` on
  ## both devices, and `m0enable/enable_wxA6_2x_spxA7_ds_1.._3` on the CGB in
  ## double speed, which sample it every two dots. All four want mode 0 open by
  ## the 180 mark on the CGB; charging the restart on top (186) takes all four
  ## red, and so does deferring the object behind the restart (190).
  ##
  ## The two rows that ask for a longer CGB here -- `_spxA7_m3stat_2` and `_4`,
  ## `dmg08_out0_cgb04c_out3` -- cannot arbitrate it, and that is measurable
  ## rather than a preference: swept over a tail hold of 0..16 dots, `_4` is
  ## red at EVERY length on the CGB, including the 190 at which it is green
  ## when the object is deferred instead. A row whose verdict is not monotone
  ## in the quantity is not measuring that quantity. `_2` is left red, as it is
  ## on main.
  ##
  ## ---- The one row this costs, and why it is not fitted away --------------
  ##
  ## `window/m2int_wxA6_scx5_m3stat_3` goes red on the CGB (it is green on
  ## main), and its own family's double-speed sibling
  ## `window/m2int_wxA6_scx5_m3stat_ds_1` goes green with it. The two are one
  ## dot apart and cannot both be satisfied: same device, same WX, same SCX,
  ## same measured mode 3 (185 dots) -- only the sampling grid differs, 4 dots
  ## single speed against 2 in double. Swept, `_3` needs the CGB's extra to be
  ## at most 5 dots and `_ds_1` needs at least 6.
  ##
  ## **Six ships, because six is a fetch.** Five is available -- it scores the
  ## same net, trading `_ds_1` back for `_3` -- and is refused as a fit: no
  ## mechanism makes a BG fetch five dots long, and the SCX = 0, 2 and 3
  ## families are two-sided at six with nothing to say against it. The
  ## disagreement is one dot on ONE double-speed row and belongs to whatever
  ## puts the double-speed sampling grid a dot off, not to this constant.
const OBJ_BG_RUN*             {.intdefine.} = 4
  ## Which dots of an object penalty the BG fetcher is allowed to run on:
  ## 0 = none, 1 = the wait dots only, 2 = all of them, 3 = the wait dots but
  ## only to finish a fetch already under way, 4 = the tile-boundary rule
  ## (shipping) -- all of them when the fetch the object is waiting for is still
  ## in flight, none of them plus one when it is already done. The derivation,
  ## the eighteen-band measurement behind it and the sweep that cannot separate
  ## 0..3 are at tick_sprite_fetcher in fifo_ppu.nim; this exists so that sweep
  ## is a command line rather than an edit to the dot loop.
const M3_THROWAWAY_DOTS*      {.intdefine.} = 4
  ## Dots the DISCARDED fetch at the head of mode 3 lasts: 4 (`B0`, shipping) or
  ## 6 (`B01`, the control build and what this tree did until 2026-08-09). The
  ## head budget is 12 dots either way -- see the derivation at
  ## `M3_THROWAWAY_DOTS` in gb/fifo_ppu.nim -- so this constant does not change
  ## mode 3's length; it only says where inside those 12 dots the first real
  ## tile's three VRAM reads fall.
const OBJ_ABORT*              {.intdefine.} = 1
  ## Whether clearing LCDC.1 in the middle of an object's stall CANCELS the
  ## fetch (1, shipping) or lets it run to completion (0, the pre-2026-08-09
  ## behaviour). Pan Docs describes the cancel; the derivation, the dot the
  ## shifter resumes on and the ROMs that bracket it are at `fifo_obj_abort`
  ## in fifo_ppu.nim.
const CGB_OBJ_ABORT*          {.intdefine.} = 0
  ## Whether the CGB cancels an object fetch the way the DMG does (1) or lets
  ## it run (0, shipping). One row measures it and it is the same cart on both
  ## consoles: mealybug m3_lcdc_obj_en_change_variant is pixel-exact against
  ## its `_cgb_c` reference with the cancel OFF and 288 pixels out with it on,
  ## while against its DMG reference it is 96 out without and 0 with. See
  ## `fifo_obj_abort` for what that one row cannot separate.
const OBJ_ABORT_LEAD*         {.intdefine.} = 2
  ## Dots by which the object FETCHER's view of LCDC.1 leads the CPU's write
  ## dot, when the write cancels a fetch (OBJ_ABORT). The SHIFTER comes back on
  ## dot `W - OBJ_ABORT_LEAD`, paid as that many catch-up pipeline dots on the
  ## write's own dot; it is the same two dots M3_PIPE_DELAY already charges the
  ## rest of the line. What the shifter gets and the FETCHER does not is
  ## OBJ_ABORT_FLAG_HOLD below; the bracket that pins the pair is at
  ## `fifo_obj_abort` in fifo_ppu.nim.
const OBJ_ABORT_FLAG_HOLD*    {.intdefine.} = 1
  ## Dots the mode 3 -> 0 FLAG keeps after an aborted object fetch that the
  ## shifter does not: the cancelled VRAM cycle still owns the bus for its last
  ## dot, so the fetcher retires one dot behind the pixels. It is what makes the
  ## two instruments agree -- mealybug reads the PIXELS and gambatte's
  ## sprite_late_disable rows read the FLAG -- and both are exact with the pair
  ## (2, 1) where no single refund satisfies either pair of rows. See
  ## `fifo_obj_abort`.
const MIXER_PRIORITY_BACK*    {.intdefine.} = 1
  ## Stages of the mixer tail LCDC's priority bits are read at the far end of.
const BG_EN_AT_MIX*           {.intdefine.} = 1
  ## Where LCDC.0 (BG enable, DMG meaning) is sampled: at the MIXER, once per
  ## emitted pixel (1, shipping), or at the FIFO PUSH, once per eight (0, the
  ## pre-2026-08-08 behaviour). It is a mixer read like the rest of LCDC's
  ## priority half, so it carries MIXER_PRIORITY_BACK with them.
  ##
  ## mealybug m3_lcdc_bg_en_change is the ruler and it is not a fit: its handler
  ## clears LCDC.0 for exactly 12 dots, sets it for 8, clears it for 8 and
  ## leaves it set (`ld [hl],c / nop / ld [hl],b / ld [hl],c / ld [hl],b`, 8
  ## cycles each), and the DMG reference answers with white runs of exactly 12
  ## and 8 pixels -- at x = -1..10 and 19..26, neither of them on a tile
  ## boundary, over a background whose glyphs are otherwise in their normal
  ## columns. Sampling at the push can only ever blank whole tiles, which is
  ## what the 2193-pixel residual on that row was.
const MIXER_PALETTE_BACK*     {.intdefine.} = 2
  ## Stages of the mixer tail BGP/OBP0/OBP1 are read at the far end of. One
  ## more than the priority bits: the mixer resolves BG-vs-OBJ first and looks
  ## the shade up after, so a palette write reaches one pixel further back than
  ## an LCDC write does. m3_obp0_change is what separates them -- it goes to
  ## pixel-exact at 2 and is 42 pixels out at 1, on a frame where
  ## m3_lcdc_obj_en_change is 60 out at 0 and 2 out at 1.
  ##
  ## m3_bgp_change and m3_bgp_change_sprites used to be the two rows that argued
  ## for ONE stage, by 22 and 136 pixels. MIXER_PALETTE_OR below is what they
  ## were really measuring: with the transition pixel modelled they prefer TWO
  ## by 806 and 624, and the vote across all six palette rows is unanimous (the
  ## table is in docs/gb-failure-triage.md). The constant never moved.
const MIXER_PALETTE_OR*       {.intdefine.} = 1
  ## Whether a DMG palette write puts ONE pixel of `old or new` at the far end
  ## of the mixer tail (1, shipping) or a clean edge (0, the pre-2026-08-08
  ## behaviour). mealybug m3_bgp_change is the instrument and the derivation is
  ## at the FF47..FF49 write in ppu.nim -- its frame is BGP's low two bits
  ## sampled once per dot, so the three-valued edge is read straight off it.
const MIXER_DOT_LAG*          {.intdefine.} = 1
  ## Whether the pixel mixer runs a dot behind the FIFO pop. 1 ships; 0 is the
  ## control build and compiles the whole mechanism out. See
  ## fifo_recompose_last in fifo_ppu.nim for what it buys and how it was
  ## measured -- it is not a sweepable dot count, only on or off, because a
  ## second dot is refused by the same rows the first is required by.
const MIXER_TAIL_HBLANK*      {.intdefine.} = 1
  ## Whether the mixer keeps CLOCKING after the mode 3 -> 0 edge, so that a
  ## register write on the first dots of H-Blank still reaches the pixels whose
  ## shade the tail has not latched yet. 1 ships; 0 is the pre-2026-08-09
  ## behaviour, where every recompose was guarded on mode 3.
  ##
  ## It is not a second lag and it moves no edge: the mode 3 -> 0 dot, the
  ## VRAM/OAM locks and the STAT model are all untouched (bucket 15 in
  ## docs/gb-failure-triage.md pins that dot from a dozen directions). What it
  ## fixes is an ACCOUNTING error of ours. The shifter emits one pixel per dot
  ## and the tail latches its shade MIXER_PALETTE_BACK dots later, so the last
  ## pixels of a line are still in the tail when the fetcher retires -- but
  ## `fifo_burst_tail` emits them all on the retire dot, which is the only dot
  ## in the line where dingbat's shifter is not one pixel per dot. See
  ## fifo_recompose_last in fifo_ppu.nim for the derivation off m3_bgp_change's
  ## seventh write.
const NO_LCDC2_FLIP*          = int32.low
  ## `GbPpu.lcdc2_flip` entry meaning "LCDC.2 has not changed since this mode 3
  ## began". A dot in the far PAST, so `flip > dot` is false for every dot an
  ## object fetch can ask about -- including one in the future, which is how the
  ## merge asks for a read that has not happened yet -- and the empty history
  ## costs no branch of its own.
const OBJ_FIX_OFF*            = int32.high
  ## `GbFifoPpu.obj_fix_from` meaning "no object fetch is still reachable by an
  ## LCDC.2 write". Same shape as above: the window test is one compare either
  ## way.
const NO_TDSEL_CHANGE*        = int32.low
  ## `GbFifoPpu.tdsel_dot` meaning "LCDC.4 has not changed on this line". A dot
  ## in the far past, so the fetcher's `cycle_counter - tdsel_dot` is a large
  ## positive that is neither inside the latency nor on the glitch dot, and the
  ## empty case costs no branch of its own -- the same shape as NO_LCDC2_FLIP.
  ## It is also what a DMG carries all frame, since only a CGB records a change.
const NO_MAP_CHANGE*          = int32.low
  ## `GbFifoPpu.map_dot` meaning "neither tile-map select bit has changed on
  ## this line". Same shape as NO_TDSEL_CHANGE above: a dot in the far past, so
  ## the fetcher's single `cycle_counter < map_dot` never takes and the empty
  ## case -- which is every line of every DMG frame -- costs no branch of its
  ## own. See CGB_MAP_LATENCY.
const TDSEL_ADDR_OFF*         = -1'i32
  ## `GbFifoPpu.tdsel_addr` meaning "nothing has driven an $8000-region
  ## tile-data address yet". A SET-glitched read falls back to its own read
  ## there. Only reachable before the first such read of a frame now that the
  ## latch survives H-Blank, and no reference in this tree reaches it.
const TDSEL_ADDR_BANK*        = 13
  ## Bit `tdsel_addr` carries the VRAM bank in. Offsets are 13 bits, so the
  ## bank rides above them and the whole latch is one store on the fetch path.
const TDSEL_IDX_SHIFT*        = 14
  ## Bit `tdsel_addr` carries the INDEX path's arming in, as the first dot PAST
  ## the window (see CGB_TDSEL_IDX_DOTS). Above the bank at bit 13, so a dot
  ## needs nine bits and the whole word stays positive. One-past rather than the
  ## last dot so that zero up there means "not armed" for every dot including 0,
  ## and the whole test is `(latch shr 14) > cycle_counter` -- one compare, with
  ## the unarmed case and the negative TDSEL_ADDR_OFF sentinel both answered by
  ## it and neither costing a branch of its own.
  ##
  ## It rides `tdsel_addr` rather than living in a field because a field of its
  ## own is not free: GbFifoPpu is 632 bytes and every offset above the latch is
  ## the fetch path's, so one more int32 grows it to 640 and moves `tile_num`,
  ## the tile attributes and both bitplane bytes with it. That measured
  ## **+0.22% of retired instructions on Pokemon Crystal with the rule compiled
  ## out** -- pure layout, more than the rule itself costs. Packed, the arming
  ## is written by the store the RESET branch already does.
  ##
  ## The packing also decides one thing the corpus leaves open, in the direction
  ## of less mechanism: because every write of the latch clears these bits, an
  ## object fetch or a plain unsigned read between the RESET glitch and the SET
  ## one disarms it. That is the "the latch is <= 8 dots old AND a RESET glitch
  ## wrote it" spelling, which scores the same 223/223 as the looser "a RESET
  ## glitch landed <= 8 dots ago" -- no cell in the tree separates them.
const MIXER_TAIL_DOTS*        {.intdefine.} = 1
  ## Whether the mixer tail is clocked in DOTS (1, shipping) or in emitted
  ## PIXELS (0, the pre-2026-08-10 behaviour, where the reach was counted back
  ## from `lx`).
  ##
  ## The two agree everywhere the shifter runs one pixel per dot, which is all
  ## of a line except an object fetch and the tail burst. Where they differ,
  ## mealybug says dots. `m3_bgp_change_sprites` is the ruler: its object stalls
  ## the shifter at the head of each band and its handler writes BGP on a fixed
  ## dot, so each band asks "how far back does a write reach while the shifter
  ## is stopped". The DMG reference answers ZERO pixels back for a stall older
  ## than the tail (bands 8..12, the edge sits exactly on the stalled `lx`), ONE
  ## for a stall one dot old (band 13) and the full two for an unstalled shifter
  ## (bands 14..17) -- i.e. the write reaches a pixel iff that pixel LEFT THE
  ## FIFO within MIXER_PALETTE_BACK dots, stall or no stall. A pixel-clocked
  ## tail holds the last two pixels for the whole of a 6..11 dot object fetch
  ## and repaints them; that was 104 of that row's wrong pixels and 59 of
  ## `m3_lcdc_bg_en_change`'s, on the same three bands' worth of arithmetic.
  ##
  ## Implementation: GbFifoPpu.tail_dot0 is the dot pixel 0 of the current
  ## unbroken run of emissions would have left on, so the shifter's position on
  ## any later dot reads back as `cycle_counter - tail_dot0` whether or not `lx`
  ## has moved since. It subsumes the tail-burst latch MIXER_TAIL_HBLANK needed.
const MIXER_HEAD_LINGER*      {.intdefine.} = 1
  ## Whether the line's FIRST pixel holds the SHALLOW stages of the mixer tail
  ## open until the deepest one is read (1, shipping; 0 is the pre-2026-08-10
  ## behaviour, where every pixel of the line was the same depth).
  ##
  ## Pixel 0 alone, and only for a register read at a stage shallower than the
  ## palettes': LCDC's priority bits reach it for MIXER_PALETTE_BACK dots after
  ## it leaves the FIFO rather than MIXER_PRIORITY_BACK.
  ##
  ## mealybug `m3_lcdc_bg_en_change` is the whole of the measurement, and it is
  ## a ±1 step and not a fit. Its object's OAM X advances one per 8-line band,
  ## which moves the dot pixel 0 leaves the FIFO on -- dots 105, 104, 103, 102,
  ## 101, 100 for bands 0..5 by `-d:gb_px_trace` -- while the handler's LCDC
  ## write stays on dot 105 for every band. The DMG reference blanks x = 0 in
  ## bands 0, 1 and 2 and leaves it alone in bands 3..7, i.e. pixel 0 is still
  ## reachable exactly TWO dots after it leaves, where MIXER_PRIORITY_BACK is
  ## one and every other pixel of the same bands obeys it.
  ##
  ## The palettes are NOT extended, and the same suite says so: `m3_bgp_change`
  ## writes BGP on dot 97 with pixel 0 leaving on dot 94, and its reference puts
  ## the `old or new` pixel at x = 1 -- a two-dot reach for pixel 0, the same as
  ## for every other pixel. So this is not "pixel 0 lingers a dot"; it is the
  ## two stages COINCIDING for the line's first pixel, which is why it is
  ## written as `back < head` and not as a lag.
  ##
  ## Note the DMG references are the only oracle here. gambatte's
  ## `dmgpalette_during_m3` family looks like a second one and is not: its PNGs
  ## carry no `old or new` pixel at all (MIXER_PALETTE_OR's named cost), so
  ## every disagreement with them in this area is already that one.
const MIX_HOLD*               {.intdefine.} = 4
  ## Entries in the mixer's held-pair ring (GbFifoPpu.mix), a power of two so
  ## the shifter's store indexes with an `and`. It has to cover every pixel a
  ## write can still reach: the deepest mixer stage, plus the pixels the tail
  ## burst decided ahead of their own dot (the pipeline lead). fifo_ppu.nim
  ## static-asserts that sum against this.
  ##
  ## Overridable only so a sweep of the pipeline lead can build at all -- a
  ## whole M-cycle of M3_PIPE_MCYCLES needs 8. Depth alone changes no pixel;
  ## it is a bound, not a model.
const CGB_MIXER_LATENCY*      {.intdefine.} = 1
  ## Dots a **C-class CGB**'s write to a register the MIXER reads takes to
  ## arrive over the DMG's. Subtracted from every mixer stage below, so a
  ## register the DMG reads one stage down is not repainted on CGB at all.
  ##
  ## This is the QUANTITY only. Whether a given machine is charged it is a
  ## runtime question as of 2026-08-10 -- `quirks.mixer_write_immediate` says
  ## CGB D and later are not -- and `gb_mixer_latency` is the one place the two
  ## meet. The constant stays an `intdefine` so a sweep of the quantity still
  ## builds; overriding it moves the C-class machine and leaves D and E at 0.
  ##
  ## Two rows pin it, and each is exact on BOTH consoles at these settings and
  ## on neither at any other. mealybug m3_lcdc_obj_en_change (priority, one
  ## stage) is pixel-exact on the CGB references with no repaint and 60 pixels
  ## out with one, and 2 out on the DMG references with one repaint and 60 with
  ## none. m3_obp0_change (palette, two stages) is pixel-exact on the DMG
  ## references at two and on the CGB references at one; it is 32 pixels out on
  ## DMG at one and 126 out on CGB at two. Same cart, same write, same objects;
  ## only the console differs, and the same single dot separates them at both
  ## stages.
  ##
  ## Shaped as a write latency because that is what every other per-register
  ## CGB/DMG difference in this block is (the mealybug PPU notes' "writes take
  ## effect immediately on the DMG. On CGB and AGB devices, writes appear to
  ## take effect 2 T-cycles later" for SCY is the documented instance, and
  ## CGB_SCY_LATENCY above is it). It is SEPARATE from CGB_LCDC_LATENCY, which
  ## is LCDC's latency at the FETCHER: different rows measure them and they come
  ## out different, and that one ships at 0.

const CGB_LCDC_MIXER_LATENCY* {.intdefine.} = 1
  ## Dots the CGB's LCDC write takes to reach the pixel MIXER over the DMG's.
  ##
  ## The mixer runs one dot behind the FIFO pop (fifo_recompose_last in
  ## fifo_ppu.nim), so a mid-mode-3 write to a register it reads still reaches
  ## the pixel already emitted -- on DMG. On CGB it does not, and one row says
  ## so on its own: mealybug m3_lcdc_obj_en_change is pixel-exact on the CGB
  ## references WITHOUT the extra dot and 174 pixels out WITH it, while on the
  ## DMG references it is 60 pixels out without and 2 with. Same cart, same
  ## write, same objects; only the console differs.
  ##
  ## Expressed as a one-dot CGB write latency because that is the shape every
  ## other per-register CGB/DMG difference in this block has (the mealybug PPU
  ## notes' "writes take effect immediately on the DMG, 2 T-cycles later on CGB"
  ## for SCY is the documented instance, and CGB_SCY_LATENCY above is it): one
  ## dot of CGB latency cancels the mixer's one dot exactly, which is why the
  ## repaint is simply skipped rather than delayed. It is a SEPARATE constant
  ## from CGB_LCDC_LATENCY, which is the same register's latency at the
  ## FETCHER, because the two are measured by different rows and come out
  ## different -- that one ships at 0.
  ##
  ## Only LCDC. The three DMG palettes take the mixer's dot on both consoles
  ## (mealybug m3_obp0_change goes 96 wrong pixels -> 0 on the CGB references
  ## with the repaint on, and m3_bgp_change 96.1% -> 98.9%), so whatever this
  ## dot is, it is not shared by every mixer input.
const CGB_LATENCY_CAP*        {.intdefine.} = 1
  ## Dots at the end of the M-cycle no latency may reach into. Inert while the
  ## six above are 0. Only DOUBLE SPEED can tell 0 from 1 -- its M-cycle is two
  ## dots long, so a 2-dot latency either lands on the boundary (0) or one dot
  ## short of it (1) -- and it is worth 8 rows: at CGB_SCROLL_LATENCY=2 the
  ## uncapped form is 3551 and the capped one 3559, the whole difference being
  ## `_ds_` rows in scy/scx_during_m3/sprites. Those rows are the CGB
  ## CPU-to-PPU phase axis (see the lcd_offset note at mem_tick_ppu_latched),
  ## not this one, so the cap is what keeps a register latency from being
  ## scored against them.
const CGB_LCDC_LATENCY_ANY* = CGB_LCDC_LATENCY != 0 or CGB_LCDC_TDSEL_LATENCY != 0
const CGB_WY_LATENCY_ANY*   = CGB_WY_LATENCY != 0 or CGB_WY_LATCH_LATENCY != 0
const CGB_WRITE_LATENCY_ANY* = CGB_WX_LATENCY != 0 or CGB_SCY_LATENCY != 0 or
                               CGB_SCX_LATENCY != 0 or
                               CGB_LCDC_LATENCY_ANY or CGB_WY_LATENCY_ANY

# ---- The 2 dots at the mode 3 -> 0 edge, and the three ways to spend them ---
#
# Dots the first and second line after an LCD enable are short of a normal 456.
# Here for the same reason as the pair above: the field they need is in the type
# block. Both ship at 0, which compiles the field and every branch out.
#
# They exist because three unrelated families of ROMs want the mode 3 -> 0 edge
# TWO DOTS earlier than this tree puts it, and each of the three constants that
# could give it to them is refused by a fourth family. Measured 2026-08-03, one
# full runner per cell, from 5edfe2d (934 / 672, gambatte 3534, GBMicrotest 400,
# mooneye 112, wilbertpol 82):
#
#   route                            buys                       loses
#   M3_END_EARLY=2 (fifo_ppu.nim)    GBMicrotest +20            mooneye -1,
#     mode 3 is 2 dots shorter,      (hblank_int_scx*, the      wilbertpol -4,
#     every line, every SCX          sprite*_b and win*_b rows) gambatte -150
#   LCD_ON_HEAD_START=7 (ppu.nim)    GBMicrotest +9,            enable_display -10,
#     the PPU is 2 dots further      gambatte sprites +15       scx_during_m3 -3,
#     into line 0 at the enable                                 age -1, mealybug -1
#   LCD_ON_LINE0_TRIM=2              GBMicrotest +21,           enable_display -7,
#     line 0 after an enable is      gambatte +10 net           scx_during_m3 -3,
#     454 dots, so line 1 lands 2                               dma -1, age -1,
#     dots earlier and line 0's                                 mealybug -1
#     own edges do not move
#   LCD_ON_LINE0_TRIM=2 plus         GBMicrotest +20 net        gbmicrotest
#     LCD_ON_LINE1_TRIM=-2           (+23: hblank_int_scx*,     win{0_scx3,5,6}_a,
#     line 0 ends 2 dots early and   ppu_sprite0_scx*_b,        age/ly/ly-cgbE,
#     line 1 gives them back, so     sprite4_4..7_b, sprite_1_b, gambatte
#     the skew is confined to the    win{1,2,8..15}_b)          enable_display -1
#     first two lines                gambatte +13 net           (frame0_ly_count_ds_1)
#                                    (sprites 374 -> 388)
#
# That last row is much the closest anything has come: mooneye 112, wilbertpol
# 82, Blargg, Mealybug, mGBA, scx_during_m3, dma and every other gambatte
# subdirectory are untouched, and it is +33 rows for -5. It is NOT shipped, for
# one reason: nothing derives it. A line is 456 dots and hardware has no
# mechanism that makes one 454 and the next 458; the shape was reached by
# noticing which ROMs disagree and splitting the difference, which is the fit
# this project has declined four times before. If a mechanism turns up -- the
# obvious candidate is the sub-M-cycle phase mooneye's notes describe at
# LCD_ON_HEAD_START, which this would be the whole-dot rounding of -- this is
# the setting to re-measure first.
#
# Which family a ROM belongs to is decided by ONE thing -- which line after the
# LCD enable it measures -- and the three answers do not agree:
#
#   * GBMicrotest int_hblank_{nops,incs,halt}_scx0..7 switch the LCD off and on
#     and take the very next H-Blank, so they time LINE 0 against the enable
#     write. All eight pass here and all eight break at M3_END_EARLY=2.
#   * GBMicrotest hblank_int_scx0..7 do the same thing, then burn 114 NOPs -- one
#     whole line -- before enabling the STAT source, so they time LINE 1. Four of
#     the eight fail here, and only 2 dots fixes them (see M3_END_EARLY's table).
#   * GBMicrotest hblank_int_scx*_if_* / _nops_* never touch the LCD; they run
#     from the boot hand-off. They want the same 2 dots, which is the same thing
#     DMG_BOOT_PHASE = 399 buys (see skip_boot) and the same thing it is refused
#     for. Note that they are NOT reachable from these two trims, and that is
#     load-bearing: the HLE hand-off writes LCDC = $91 through write_byte
#     (memory.nim's skip_boot), so the LCD-enable branch fires there too, and
#     ppu.skip_boot has to clear the window it opens exactly as it already
#     clears `first_line`. Without that reset a trim silently retimes the first
#     two lines after the BOOT hand-off as well, which reads as these rows going
#     green for the wrong reason -- it is a DMG_BOOT_PHASE change wearing the
#     LCD-on constant's clothes.
#   * gambatte enable_display (frame0/frame1/frame2 m0irq_count_scx2*,
#     ly0_late_scx7_m3stat_scx*) and the scx_during_m3 reference PNGs also enable
#     the LCD and then measure later lines and later frames, and they say the
#     phase is already right.
#
# So line 0 says 0, line 1 says -2, the steady state says -2, and later frames
# say 0. No single constant of any of these three shapes can be all four, and
# the pairs that each row brackets are one M-cycle wide, so nothing here is a
# rounding artefact of the measurement. The 2 dots are real and their carrier is
# still unidentified; what is now excluded is that they live in mode 3's length
# as a function of SCX & 7.
#
# Both trims are wired into the FIFO renderer only (`gb_line_end` in ppu.nim,
# used by fifo_ppu's line-end and idle-skip). The scanline renderer is not the
# shipping default and none of the ROMs above are scored against it.
const LCD_ON_LINE0_TRIM* {.intdefine.} = 0'i32
const LCD_ON_LINE1_TRIM* {.intdefine.} = 0'i32
const LCD_ON_TRIM_ANY* = LCD_ON_LINE0_TRIM != 0 or LCD_ON_LINE1_TRIM != 0

const SCX_FINE_LATCH_LIVE* {.booldefine.} = true
  ## A store to SCX joins the line's fine-scroll discard for as long as the
  ## discard still has pixels to throw away, instead of being measured against
  ## a value sampled on one dot. Declared here, with the other pipeline
  ## constants, because `GbFifoPpu` below grows a field only when it is on --
  ## the field costs 0.21% of retired instructions on its own through object
  ## layout, so `false` has to be byte-identical to not having built it.
  ## Ships ON since 2026-08-11: its original -0.446% price was remeasured at
  ## +0.027% in the tree that ships STAT_M0_FIELD_TAIL, which removed the
  ## reason it was parked; +6/-1 on the suite, and SCX_FINE_LATCH_WRAP below
  ## rides inside its window for +7 more.
  ##
  ## The derivation, the two-sided evidence and the price are all at this
  ## constant's note in gb/fifo_ppu.nim.

const SCX_FINE_LATCH_WRAP* {.intdefine.} = 8'i32
  ## Dots the fine-scroll discard costs when a mid-line SCX store lands AFTER
  ## the discard has already walked past the new `SCX and 7`. 0 is off; 8 is
  ## one whole pass of the eight-slot window. Requires `SCX_FINE_LATCH_LIVE`,
  ## whose window this rides inside, and grows a field of its own.
  ## Ships at 8 since 2026-08-11: the discard is a three-bit SLOT COUNTER
  ## compared each dot against the live `SCX and 7`, and a slot-7 miss wraps
  ## into a whole further pass -- which is what "SCX banging" abuses. Bracketed
  ## as a strict local maximum by whole-suite sweep (6/7/8/9/10 ->
  ## 4049/4050/4051/4050/4050) and by scx_m3_extend's `_ds` pair, a
  ## twelve-store banging ROM whose 3->0 edge lands in (329, 331] with this
  ## rule producing 330.
  ##
  ## The derivation is at this constant's note in gb/fifo_ppu.nim.

const SCX_STORE_STALL_DOTS* {.intdefine.} = 0'i32
  ## Dots the pixel pipeline stalls when a mid-line store to SCX LOWERS
  ## `SCX and 7`. 0 is off. Declared here for the same reason as
  ## `SCX_FINE_LATCH_LIVE`: `GbFifoPpu` grows a field only when it is on.
  ##
  ## The derivation is at this constant's note in gb/fifo_ppu.nim; the short
  ## form is that `gambatte/scx_m3_extend` says hardware's mode 3 is longer
  ## after such a store, and its `_ds` member -- twelve stores on one line,
  ## which is what SCX "banging" means -- prices one store at 8 dots.

# ==================== TYPE DECLARATIONS ====================
# All GB types in one block for forward-reference support.

type
  # ---- Cartridge / MBC ----
  CgbFlag* = enum
    cgbNone, cgbSupport, cgbExclusive

  # Boot-state model. Selects the per-hardware-revision CPU register / DIV
  # seed table applied at the boot-ROM handoff (skip_boot). Real users only
  # ever get bmDmgABC (any DMG/SGB cart) or bmCgbABCDE (any CGB cart) — those
  # reproduce the values dingbat has always used. The other variants exist so
  # the mooneye boot_regs-*/boot_div-* acceptance ROMs (which each target one
  # specific hardware revision) can be driven by the test harness via --model.
  # Sources: mooneye-test-suite acceptance/misc boot_regs-*.s / boot_div-*.s
  # asserts, and Pan Docs "Power-Up Sequence".
  # The three buses an OAM DMA can own, and that a CPU access can collide with.
  # Pan Docs "OAM DMA bus conflicts" states the separation for the CGB
  # ("the cartridge and WRAM are on separate buses"), and the memory map plus
  # the PPU's dedicated video bus (Pan Docs "Accessing VRAM and OAM") give the
  # third. On DMG, WRAM hangs off the same external bus as the cartridge, which
  # is why the DMG advice degenerates to "the CPU can access only HRAM".
  GbDmaBus* = enum
    dbNone      # OAM / unusable / IO / HRAM / IE — never conflicts
    dbExternal  # cartridge ROM $0000-$7FFF and cartridge SRAM $A000-$BFFF
    dbVideo     # VRAM $8000-$9FFF
    dbWram      # WRAM + echo $C000-$FDFF (CGB only; DMG folds it into dbExternal)

  GbBootModel* = enum
    bmDmg0       # original DMG (no serial number)
    bmDmgABC     # DMG rev A/B/C  (dingbat default DMG)
    bmMgb        # Game Boy Pocket / Light
    bmSgb        # Super Game Boy
    bmSgb2       # Super Game Boy 2
    bmCgb0       # original CGB
    bmCgbABCDE   # CGB rev A..E   (dingbat default CGB)
    bmAgb        # Game Boy Advance / SP running a GB(C) cart

  GbRevision* = enum
    ## The silicon revision the machine is. This is FINER than GbBootModel,
    ## which is a boot-handoff *table* selector: mooneye ships one
    ## `boot_regs-cgbABCDE` and one `boot_regs-dmgABC`, so five CGB revisions
    ## and three DMG revisions hand off identical registers while behaving
    ## differently once running (SameSuite's extra-length-clocking split at CGB
    ## C, mooneye `stat_irq_blocking`'s "pass: DMG ABC / fail: DMG 0"). Every
    ## GbBootModel value is reachable from some revision, so the two are not
    ## independent axes -- gb_set_revision derives the boot model, and nothing
    ## sets the boot model to something the revision disagrees with.
    ##
    ## Do not branch on this in emulation code. Resolve it once, at
    ## construction, into GbQuirks; see gb_quirks_for.
    grDmg0, grDmgABC, grMgb, grSgb, grSgb2
    grCgb0, grCgbAB, grCgbC, grCgbD, grCgbE
    grAgb

  GbUnusableRegion* = enum
    ## What `$FEA0..$FEFF` -- the "prohibited" tail of the OAM page -- answers
    ## a CPU read, and whether a CPU write to it is kept. Pan Docs' "FEA0-FEFF
    ## range" splits this three ways and this enum is that split, one member
    ## per bullet:
    ##
    ##   "This area returns $FF when OAM is blocked, and otherwise the
    ##    behavior depends on the hardware revision.
    ##    - On DMG, MGB, SGB, and SGB2, reads during OAM block trigger OAM
    ##      corruption. Reads otherwise return $00.
    ##    - On CGB revisions 0-D, this area is a unique RAM area, but is masked
    ##      with a revision-specific value.
    ##    - On CGB revision E, AGB, AGS, and GBP, it returns the high nibble of
    ##      the lower address byte twice, e.g. FFAx returns $AA, FFBx returns
    ##      $BB, and so forth."
    ##
    ## (Pan Docs' `FFAx`/`FFBx` there is a typo for `FEAx`/`FEBx`; the formula
    ## in the same sentence is unambiguous.)
    urZero
      ## DMG / MGB / SGB / SGB2: reads answer `$00`, writes are dropped. This
      ## is also what dingbat answered on *every* model before the split, so it
      ## is what a DMG machine keeps bit for bit.
    urRamMasked
      ## CGB 0 / A / B / C: real RAM, with address bits 3 and 4 masked off, so
      ## the 96 addresses fold onto 24 distinct cells, each reachable from four
      ## of them.
      ##
      ## Pan Docs states the RAM and states that the mask is
      ## "revision-specific" without giving any mask value, so the quantity is
      ## sourced from the ROM that measures it rather than from the book:
      ## `cgb-acid-hell` writes `$55` to `$FEA0` and `$44` to `$FEB8`, reads
      ## `$FEA0` back, and draws a *different picture* depending on whether it
      ## sees `$55`. Two hardware captures bracket it -- the author's bundled
      ## reference (and dingbat's scored PNG) is the not-`$55` branch, and the
      ## repo's issue tracker carries a photo of a real device taking the
      ## `$55` branch. So on the reference device the `$FEB8` store must land
      ## on `$FEA0`, which is exactly `addr and not 0x18`. SameBoy agrees, and
      ## was checked after the fact, not copied; see docs/gb-failure-triage.md
      ## "the CGB-D gate, with the semantics spelled out".
    urRamPlain
      ## CGB D: the same RAM with no mask, so `$FEA0` and `$FEB8` are distinct
      ## cells and the readback above is `$55`. This is the one revision
      ## `cgb-acid-hell` refuses outright ("the bugs in the PPU this test
      ## relies on work differently on CGB-D"): it draws its SORRY YOU CAN'T
      ## GET TO PLAY screen instead of the test pattern, which is CORRECT
      ## behaviour for the machine and not a dingbat failure.
    urNibbleEcho
      ## CGB E / AGB / AGS / GBP: not RAM at all. Reads answer the high nibble
      ## of the low address byte, doubled (`$FEAx` -> `$AA`), and writes are
      ## dropped. Pan Docs gives this one outright, formula included.

  GbQuirks* = object
    ## Per-revision behaviour, resolved from GbRevision once by gb_quirks_for
    ## and thereafter read as a plain bool off the GB the caller already has.
    ##
    ## Flags, not a revision comparison, for three reasons: a flag names the
    ## behaviour at the site that implements it (`if gb.quirks.x` reads as an
    ## assertion about hardware, `if gb.revision <= grCgbAB` reads as trivia);
    ## two revisions that share a behaviour share a flag instead of repeating a
    ## set literal; and a comparison in a hot path is a range check where a
    ## flag is a load. Every flag is FALSE on the default revisions
    ## (grCgbC / grDmgABC), so the default machine is byte-identical to the one
    ## dingbat shipped before revisions existed. `unusable_region` is the one
    ## member that is not a bool, because the behaviour it names has three
    ## states and no natural "off". It is also the one member whose default is
    ## NOT what dingbat did before revisions existed: the CGB default moved
    ## from `urZero` (the region unmodelled) to `urRamMasked` (the region
    ## modelled, on the revision the tree is scored against), which is a
    ## deliberate, measured change -- see docs/gb-failure-triage.md.
    length_clock_any_nrx4*: bool
      ## CGB 0 and CGB A/B. SameSuite `*_extra_length_clocking-cgb0B.asm`:
      ## "Extra length clocking occurs when writing to NRx4 when the frame
      ## sequencer's next step is one that doesn't clock the length counter.
      ## In this case, if the length counter was PREVIOUSLY disabled and now
      ## enabled and the length counter is not zero, it is decremented. On
      ## revisions <= CPU CGB B, the length counter only has to have been
      ## disabled before; the current length enable state doesn't matter. This
      ## breaks at least one game (Prehistorik Man), and was fixed on CPU CGB
      ## C." So the extra clock drops its `and len_enable` term: the ROMs write
      ## NRx4 = $00 (CH3: $03), with bit 6 clear, and still expect the counter
      ## to move.
    mixer_write_immediate*: bool
    scy_fetch_latch*: bool
      ## CGB-D and later latch SCY ONCE per BG fetch, at the map read, and both
      ## bitplane reads of that tile use the latched value. CGB-C and earlier
      ## sample it live on each of the three read dots.
      ##
      ## Derived two-sided from mealybug `m3_scy_change`, whose two captures
      ## invert exactly (docs/gb-mealybug-sources.md 3.4 -- each tile IS the
      ## triple (SCY at B, SCY at 0, SCY at 1), because the map is
      ## `65 + row + col`, BGP is identity and SCX is 0). Live-per-read is
      ## pixel-exact on `_cgb_c` and 6217 px wrong on `_cgb_d`; the per-fetch
      ## latch is pixel-exact on `_cgb_d` and the same 6217 px wrong on
      ## `_cgb_c`. Two models, two captures, no overlap and no fitted constant.
      ## CGB D and later. The CGB takes a mid-mode-3 write to a PALETTE
      ## register one dot later than the DMG does -- that dot is
      ## `CGB_MIXER_LATENCY`, and this flag is the revision that stops taking
      ## it, so the write reaches the mixer at the DMG's phase again.
      ##
      ## Palettes only. LCDC is read by the same mixer and keeps its dot on
      ## every revision; mealybug's `_cgb_c` and `_cgb_d` captures of the LCDC
      ## ROMs are byte-identical to each other, and that is the whole argument.
      ## See gb_lcdc_mixer_latency, which is the other half.
      ##
      ## The evidence is one pair of mealybug reference captures of the same
      ## ROM on two devices. `m3_bgp_change` is pixel-exact against
      ## `m3_bgp_change_cgb_c.png` with the dot and against
      ## `m3_bgp_change_cgb_d.png` without it; the two PNGs differ by exactly
      ## one pixel per write edge, which is the dot. So C-class keeps it, D
      ## drops it, and mealybug shipped both pictures because both devices
      ## exist. See CGB_MIXER_LATENCY for what the dot is and which rows pin
      ## its value on the C side.
      ##
      ## `grAgb` is deliberately NOT in this set even though AGB is silicon
      ## later than CGB-E. Nothing has measured an AGB against these captures
      ## -- mealybug ships no `_agb` reference for this ROM -- and the tree's
      ## AGE `agb` rows are scored against the current behaviour. A guess that
      ## moves scored rows is worse than an honest gap.
    unusable_region*: GbUnusableRegion
      ## What `$FEA0..$FEFF` does on this machine; see GbUnusableRegion, which
      ## carries the Pan Docs quote and the per-member evidence.

  Mbc* = ref object of RootObj
    gb_ref* {.cursor.}: GB   # back-ref to the owning GB; non-owning to avoid a
                             # reference cycle (the GB owns the cartridge)
    rom_identity*: uint32    # FNV-1a of the ROM as loaded, taken once. The
                             # save-state identity reads this, not `rom`,
                             # which cheats patch in place. See
                             # gb_rom_checksum.
    rom*:          seq[uint8]
    ram*:          seq[uint8]
    sav_path*:     string
    has_battery*:  bool
    ram_dirty*:    bool
    save_error_reported*: bool
    # Flat-ROM window cache -- see mbc_sync_rom_map in mbc/mbc.nim. Derived
    # state, never serialized: it is recomputed from the banking registers
    # after every cartridge write and after a state load. `flat_rom` defaults
    # to false so an Mbc that has not been synced falls back to the method.
    flat_rom*:     bool
    rom_lo_base*:  int   # byte offset in `rom` that address 0x0000 maps to
    rom_hi_base*:  int   # byte offset in `rom` that address 0x4000 maps to

  MbcRom* = ref object of Mbc

  Mbc1* = ref object of Mbc
    ram_enabled*: bool
    mode*:        uint8
    reg1*:        uint8   # 5-bit rom bank lo
    reg2*:        uint8   # 2-bit secondary
    multicart*:   bool    # MBC1M: only 4 bits of reg1 are wired; reg2 shifts by 4

  Mbc2* = ref object of Mbc
    ram_enabled*: bool
    rom_bank*:    uint8

  Mbc3* = ref object of Mbc
    ram_enabled*:    bool
    rom_bank_num*:   uint8
    ram_bank_num*:   uint8
    # MBC3 real-time clock
    has_rtc*:            bool
    rtc_live*:           array[5, uint8]  # S, M, H, DL, DH
    rtc_latched*:        array[5, uint8]
    rtc_latch_prev*:     uint8  # DEAD: the latch fires on any write (see
                                # mbc3.nim), so nothing reads this. It is still
                                # written and still serialized so the GB
                                # save-state payload keeps its current layout.
    rtc_halt_remaining*: int  # scheduler cycles left on the pending tick while halted

  Mbc5* = ref object of Mbc
    ram_enabled*:    bool
    rom_bank_num*:   uint16
    ram_bank_num*:   uint8

  Mbc7* = ref object of Mbc
    # Cart type 0x22 (Kirby Tilt 'n' Tumble, Command Master). There is no cart
    # RAM: 0xA000-0xAFFF is a register file exposing a two-axis accelerometer
    # and the serial port of a 93LC56 EEPROM, and that EEPROM (128 words =
    # 256 bytes, held in `ram`) is what the battery backs up.
    ram_enabled*:      bool  # 0x0A written to 0x0000-0x1FFF
    secondary_enable*: bool  # 0x40 written to 0x4000-0x5FFF; BOTH must be set
    rom_bank_num*:     uint8
    # Accelerometer. accel_x/accel_y are the frontend's tilt in the range
    # -1.0 .. 1.0, 0.0 = level; they are live input, not saved state.
    accel_x*, accel_y*: float
    x_latch*, y_latch*: uint16  # sampled by the 0x55/0xAA latch sequence
    latch_ready*:       bool     # a 0x55 has armed the latch; the 0xAA only
                                 # samples when it has (Pan Docs: re-latching
                                 # without erasing first yields no change)
    # 93LC56 serial EEPROM port. One bit is shifted per rising clock edge;
    # eeprom_command is an 11-bit shift register (start bit, 2 opcode bits,
    # 8 address bits) and read_bits shifts data back out on DO.
    eeprom_do*, eeprom_di*, eeprom_clk*, eeprom_cs*: bool
    eeprom_command*:       uint16
    read_bits*:            uint16
    argument_bits_left*:   int
    eeprom_write_enabled*: bool

  Huc1* = ref object of Mbc
    # Cart type 0xFF (Hudson HuC1). Not the MBC1 relative it is usually said to
    # be: cart RAM has no enable line, and the register that would be MBC1's RAM
    # enable instead chooses whether 0xA000-0xBFFF sees RAM or the cartridge's
    # infrared transceiver. See mbc/huc1.nim.
    bank_low*:  uint8  # 0x4000-0x7FFF bank; NOT remapped away from 0
    bank_high*: uint8  # RAM bank (it never reaches the ROM)
    ir_mode*:   bool   # 0x0E written to 0x0000-0x1FFF maps IR in at 0xA000
    cart_ir*:   bool   # emitter drive; transient, like Mbc5Rumble.rumble

  Huc3* = ref object of Mbc
    # Cart type 0xFE (Hudson HuC3). MBC5-shaped banking plus a 4-bit
    # microcontroller — clock, alarm and tone generator — reached through a
    # mailbox at 0xA000-0xBFFF. See mbc/huc3.nim for the protocol.
    rom_bank_num*: uint8
    ram_bank_num*: uint8
    mode*:         uint8   # what 0xA000-0xBFFF currently decodes to
    regs*:         array[256, uint8]  # the MCU's memory window, one nibble each
    access_addr*:  uint8   # nibble the next read/write command targets
    mailbox*:      uint8   # last value written to the command window (7 bits)
    response*:     uint8   # nibble the last executed command produced
    last_second*:  int64   # unix second the clock has been advanced through
    cart_ir*:      bool

  Mmm01* = ref object of Mbc
    # Cart types 0x0B-0x0D (Taito Variety Pack, Momotarou Collection 2 and the
    # other multi-game compilations). Powers up showing a menu program held in
    # the last 32 KiB of the cartridge, then turns into an MBC1 for whichever
    # contained game the menu selected. See mbc/mmm01.nim.
    ram_enabled*:   bool
    mapped*:        bool   # Mapping Enable: the menu has handed over to a game
    rom_bank_low*:  uint8  # 5 bits; the MBC1 bank register
    rom_bank_mid*:  uint8  # 2 bits; game select (swaps with ram_bank_low when
                           # multiplex is on)
    rom_bank_high*: uint8  # 2 bits; game select
    ram_bank_low*:  uint8  # 2 bits; the MBC1 RAM bank register
    ram_bank_high*: uint8  # 2 bits; game select
    rom_bank_mask*: uint8  # write-lock over rom_bank_low; bit 0 is always clear
    ram_bank_mask*: uint8  # write-lock over ram_bank_low
    mbc1_mode*:     bool
    mode_locked*:   bool   # MBC1 Mode Write Lock
    multiplex*:     bool
    rom_rotate*:    int    # dump-order fix-up; see mbc/mmm01.nim

  Mbc6* = ref object of Mbc
    # Cart type 0x20 (Net de Get - Minigame @ 100). Two independently banked
    # 8 KiB ROM windows and two independently banked 4 KiB RAM windows, either
    # ROM window switchable onto an 8 Mbit flash chip that the game downloads
    # minigames into over the Mobile Adapter. See mbc/mbc6.nim.
    ram_enabled*: bool
    ram_bank_a*, ram_bank_b*: uint8         # 3 bits each; 4 KiB banks
    rom_bank_a*, rom_bank_b*: uint8         # 7 bits each; 8 KiB banks
    flash_select_a*, flash_select_b*: bool  # window shows flash rather than ROM
    flash_enabled*:       bool   # /CE to the flash chip
    flash_write_enabled*: bool   # /WP; guards sector 0 and the hidden region
    flash*:        seq[uint8]    # 1 MiB main array, battery-backed
    flash_hidden*: seq[uint8]    # the 256 bytes behind the hidden-region commands
    flash_sector0_protected*: bool  # set by the Protect Sector 0 command;
                                    # non-volatile on the real chip
    flash_read_mode*:      uint8 # array / JEDEC ID / status / hidden region
    flash_status*:         uint8
    flash_cmd_step*:       int   # position in the JEDEC unlock sequence
    flash_setup*:          uint8 # command byte awaiting its second unlock
    flash_program_addr*:   int   # last address programmed; a repeat commits it
    flash_program_hidden*: bool

  PocketCamera* = ref object of Mbc
    # Cart type 0xFC (Game Boy Camera / Pocket Camera). MBC3-shaped banking plus
    # 54 registers that take over 0xA000-0xBFFF when bit 4 of the RAM bank
    # register is set: a shutter, five of the M64282FP image sensor's own
    # registers, and a 4x4x3 threshold matrix. See mbc/camera.nim.
    ram_enabled*:   bool
    rom_bank_num*:  uint8
    ram_bank_num*:  uint8
    regs_mapped*:   bool
    regs*:          array[0x36, uint8]
    capture_cycles_left*: int  # non-zero while a capture is running or paused
    # The image source. nil means the built-in synthetic scene; a frontend with
    # a real camera installs its own through set_camera_source. Live input, not
    # state, so it is left out of save states as Mbc7.accel_x is.
    sensor*: proc(x, y: int): uint8

  Tama5* = ref object of Mbc
    # Cart type 0xFD (Game de Hakken!! Tamagotchi Osutchi to Mesutchi). A
    # nibble-at-a-time port onto a 4-bit microcontroller that owns 32 bytes of
    # SRAM and a TC8521AM real-time clock. See mbc/tama5.nim.
    reg_index*:   uint8                      # last write to 0xA001
    regs*:        array[16, uint8]           # the nibble register file
    rtc_pages*:   array[4, array[13, uint8]] # timer, alarm, two free pages
    page_reg*:    uint8   # the PAGE register, shared across all four pages
    last_second*: int64   # unix second the clock has been advanced through

  # ---- CPU ----
  GbCpu* = ref object
    af*:         uint16
    bc*:         uint16
    de*:         uint16
    hl*:         uint16
    pc*:         uint16
    sp*:         uint16
    ime*:        bool
    halted*:     bool
    halt_bug*:   bool
    # Set by the eleven undefined opcodes (see opcodes.nim). Distinct from
    # `halted`: nothing short of a reset clears it, not even an interrupt.
    # `locked` always implies `halted`, so the fetch/dispatch path never has
    # to test it.
    locked*:     bool
    # Set by STOP when it enters STOP mode (see stop_instr in memory.nim), on
    # top of `halted` and `locked`. What it adds to those two is that the rest
    # of the machine is stopped as well, and that this halt IS exitable: a
    # joypad line going low clears all three.
    #
    # NOT serialized. savestate.nim writes `halted` and `locked` as the states
    # they mean without it, so a state captured inside STOP mode loads as a
    # running CPU at the instruction after the STOP. Carrying it properly would
    # be a GB CPU payload revision, and the value of one is close to zero: no
    # licensed ROM uses STOP for anything but a speed switch (Pan Docs, "Using
    # the STOP Instruction"), and a speed switch never survives an instruction
    # boundary, let alone a state boundary.
    stopped*:    bool
    # Dots of PPU time a HALTED CGB CPU is holding back from the PPU; see
    # CGB_HALT_PPU_LEAD in this file and cpu_halt_tick. Nonzero only while
    # `halted` is set on a CGB, and always the same value for a whole halt, so
    # it is NOT serialized: load_cpu_state reconstructs it from `halted` and
    # the speed, which is exact for every state a halt can be captured in bar
    # the single M-cycle between the HALT fetch and the first halted tick.
    halt_ppu_debt*: int32
    # Scheduler cycle EI's delayed IME actually landed on (etIME), so an
    # instruction can ask what IME was at its own fetch rather than what it is
    # now. Only HALT reads it (cpu_halt) and only over the 4 T-cycles of that
    # fetch, so like `cached_hl` it is scratch: it is NOT serialized, and a
    # state loaded with it at 0 answers "IME was not set during this fetch",
    # which is the right answer for every instruction boundary a state can be
    # captured on.
    ime_set_cycle*: CycleCount
    cached_hl*:  int   # -1 = invalid
    # The opcode currently executing, kept only when STAT_M0_TAIL_IDIOM needs
    # it: an IO read has to be able to say which M-cycle of its own instruction
    # it is. Guarded so a default build carries neither the field nor the store.
    when STAT_M0_TAIL_MAX_MC != 0:
      cur_opcode*: uint8

  # ---- Interrupts ----
  GbInterrupts* = ref object
    vblank_interrupt*:   bool
    lcd_stat_interrupt*: bool
    timer_interrupt*:    bool
    serial_interrupt*:   bool
    joypad_interrupt*:   bool
    vblank_enabled*:     bool
    lcd_stat_enabled*:   bool
    timer_enabled*:      bool
    serial_enabled*:     bool
    joypad_enabled*:     bool
    top_3_ie_bits*:      uint8

  # ---- Serial ----
  GbSerialDriver* = ref object of RootObj
    ## Whatever is plugged into the link port (see serial.nim). The base
    ## instance is the no-cable default; a link coordinator subclasses it.

  GbSerial* = ref object
    sb*:             uint8   # 0xFF01 shift register
    sc*:             uint8   # 0xFF02 control (bits 7, 1 [CGB], 0)
    out_latch*:      uint8   # outgoing byte latched at transfer start
    bits_remaining*: int     # 8..1 while a started transfer has bits left
    clock_history*:  uint8   # per-cycle samples of the DIV clock bit; bit 0
                             # = newest (see serial.nim: the shift clock is
                             # the divider tap delayed by 4 cycles)
    shifting*:       bool    # cached: internal-clock transfer in progress
    driver*:         GbSerialDriver

  # ---- Timer ----
  GbTimer* = ref object
    tdiv*:         uint16
    tima*:         uint8
    tma*:          uint8
    enabled*:      bool
    clock_select*: uint8
    bit_for_tima*: int
    previous_bit*: bool
    countdown*:    int

  # ---- Joypad ----
  GbJoypad* = ref object
    button_keys*:    bool
    direction_keys*: bool
    down*:           bool
    up*:             bool
    left*:           bool
    right*:          bool
    start*:          bool
    jselect*:        bool
    b*:              bool
    a*:              bool
    prev_lines*:     uint8  # last P1 low nibble, for joypad-interrupt edges

  # ---- Super Game Boy ----
  # Everything the ICD2 + SNES side of an SGB holds on the Game Boy's behalf.
  # nil on every machine whose cart header does not unlock SGB functions, which
  # is what keeps the hooks in the renderer and the joypad free. See sgb.nim.
  SgbState* = ref object
    # Command-packet receiver (P1 pulse decode)
    prev_lines*:  uint8              # last (P15,P14) pair written to P1
    receiving*:   bool
    # A low pulse is in flight: one select line went low FROM both-high, and
    # the release back to both-high will latch a bit. Not serialized — it is
    # reconstructed from prev_lines on load, which is exact for every pulse a
    # program actually sends (see load_sgb_state).
    pending*:     bool
    bit_count*:   int
    packet*:      array[16, uint8]   # the packet being clocked in
    group*:       array[7 * 16, uint8]  # packets 1..7 of one command
    pkt_index*:   int
    pkt_total*:   int
    # Game-screen colour: 4 palettes x 4 colours, and the 20x18 attribute map
    # that says which palette each character cell of the GB screen uses.
    pal*:         array[4 * 4, uint16]
    attr*:        array[20 * 18, uint8]
    # SNES-side stores filled by the _TRN commands
    syspal*:      array[512 * 4, uint16]   # PAL_TRN system colour palettes
    atf*:         array[45 * 90, uint8]    # ATTR_TRN attribute files
    chr*:         array[256 * 32, uint8]   # CHR_TRN border tiles (4bpp SNES)
    map*:         array[32 * 28, uint16]   # PCT_TRN border tilemap
    border_pal*:  array[3 * 16, uint16]    # PCT_TRN border palettes 4-6
    # Decoded 256x224 border image; bit 15 of each word is "opaque".
    border*:      seq[uint16]
    border_valid*: bool
    border_dirty*: bool
    # Bumped every time `border` is re-rendered. A frontend uploads its border
    # texture only when this moves -- the image changes a handful of times in
    # a whole session, and it is 112 KiB.
    border_gen*:   uint32
    # MASK_EN, and the frame it freezes
    mask*:        uint8
    frozen*:      seq[uint16]
    # ICON_EN bit 2: "suppress all further packets/commands" (Pan Docs,
    # SGB_Command_System). Multi-game paks set it before chain-loading so a
    # game's stray P1 traffic cannot re-program the SNES side. Nothing in the
    # documented command set clears it.
    packets_locked*: bool
    # MLT_REQ
    players*:     uint8
    cur_player*:  uint8
    when defined(sgb_trace):
      trace_watch*: int

  # ---- PPU pixel types ----
  GbPixel* = object
    color*:     uint8
    palette*:   uint8
    oam_idx*:   uint8
    obj_to_bg*: uint8

  # One mixer stage's worth of held FIFO output: the BG entry and the OBJ entry
  # popped on the same dot. Kept as a PAIR rather than as two parallel arrays so
  # the shifter's store is one eight-byte store at a computed offset rather than
  # two four-byte ones eight bytes apart -- worth 0.37% of retired instructions
  # on the mode 3 dot loop, measured, which is half of what the whole mechanism
  # costs.
  GbMixHold* = object
    bg*: GbPixel
    sp*: GbPixel

  GbPixelFifo* = object
    data: array[16, GbPixel]
    head: int
    tail: int
    size: int

  GbSprite* = object
    y*:          uint8
    x*:          uint8
    tile_num*:   uint8
    attributes*: uint8
    oam_idx*:    uint8

  # ---- PPU (base + subclasses) ----
  GbPpu* = ref object of RootObj
    # registers
    lcd_control*:   uint8   # 0xFF40
    lcd_status*:    uint8   # 0xFF41
    scy*:           uint8   # 0xFF42
    scx*:           uint8   # 0xFF43
    ly*:            uint8   # 0xFF44
    lyc*:           uint8   # 0xFF45
    bgp*:           array[4, uint8]   # 0xFF47
    obp0*:          array[4, uint8]   # 0xFF48
    obp1*:          array[4, uint8]   # 0xFF49
    wy*:            uint8   # 0xFF4A
    wx*:            uint8   # 0xFF4B
    vram_bank*:     uint8
    # CGB palette RAM
    pram*:              array[64, uint8]
    palette_index*:     uint8
    auto_increment*:    bool
    obj_pram*:          array[64, uint8]
    obj_palette_index*: uint8
    obj_auto_increment*: bool
    # VRAM (2 banks)
    vram*:          array[2, seq[uint8]]
    sprite_table*:  seq[uint8]         # OAM 160 bytes
    # HDMA. HDMA1-4 are not registers the transfer merely reads at its start:
    # they ARE the transfer's address counters, which is why a second transfer
    # started without rewriting them continues where the first one stopped
    # (same-suite dma/gbc_dma_cont) and why a write to one of them part way
    # through moves the remaining blocks. So the source/destination pair below
    # is the whole of HDMA1-4 -- a write to any of the four edits one byte of
    # it, and each copied block advances it.
    hdma5*:         uint8
    hdma_src*:      uint16  # HDMA1:HDMA2, low nibble always 0
    hdma_dst*:      uint16  # HDMA3:HDMA4, masked into VRAM only where it is used
    hdma_active*:   bool
    hdma_copying*:  bool   # re-entrancy guard; see ppu_step_hdma
    # A block this HBlank owes an armed transfer, which only a halted CPU can
    # leave unpaid (see the mode-0 edge in `mode_flag=`). Cleared on the way out
    # of mode 0, so it is never set at a frame boundary — where every state,
    # rewind snapshot and rollback snapshot is captured — and is not serialized.
    hdma_block_due*: bool
    # CPU instruction boundaries still owed before a due HBlank DMA block may
    # take the bus. See HDMA_STEAL_DELAY_M.
    hdma_due_delay*: int8
    # A copied block whose bytes have not reached VRAM yet: they land
    # HDMA_VISIBLE_DOTS dots after the block's last byte (see that constant).
    # The window is 4 dots inside an HBlank and the next PPU tick closes it, so
    # like hdma_block_due none of this can be live at a frame boundary — where
    # every state, rewind snapshot and rollback snapshot is captured — and none
    # of it is serialized.
    hdma_bytes_held*: bool
    hdma_hold_from*:  int32   # dot the hold was armed on (a smaller dot = the
                              # line wrapped, i.e. the hold is long expired)
    hdma_hold_until*: int32   # dot the bytes land on
    hdma_held_dst*:   int32   # VRAM address the held block starts at
    hdma_held*:       array[16, uint8]
    # The frame the PPU draws right after LCDC.7 goes high is not shown: the
    # panel stays blank until the first vblank (Pan Docs LCDC; SameBoy
    # GB_FRAMESKIP_LCD_TURNED_ON paints it white). Not on SGB, where the TV
    # keeps showing the frozen picture instead. Transient (one frame), not
    # serialized.
    lcd_on_first_frame*: bool
    # window state
    window_trigger*:     bool
    window_trigger_en*:  bool # window_trigger's stricter sibling: a WY match
                              # SEEN WITH LCDC.5 SET this frame. Gates the
                              # WIN_EN_HOLD_ZERO pixel void only — a frame whose
                              # window was never enabled must not glitch (WX=7 +
                              # window-off is Pokemon Blue's resting state, and
                              # its intro proves silicon draws nothing).
                              # SameBoy wy_check / DocBoy w.active_for_frame
                              # carry the same enable term. Not serialized:
                              # cleared every VBlank, and a mid-frame load only
                              # re-arms it a frame late in the rare
                              # window-then-disabled scene.
    current_window_line*: int
    old_stat_flag*:      bool
    # A CPU write to LCDC/STAT/LYC changed one of the STAT interrupt line's
    # inputs and the line has not been re-evaluated yet. The byte itself lands
    # at the top of its M-cycle (mem_write), because that is where the pixel
    # pipeline has to see it; the interrupt line is part of the mode machinery,
    # which was never out of phase with the CPU, so its edge is still taken at
    # the M-cycle boundary. Never set across an instruction boundary -- mem_write
    # consumes it in the same M-cycle -- so it is not serialized.
    stat_write_pending*: bool
    # The dots of the last two mid-mode-3 changes of LCDC.2 (the OBJ size bit),
    # most recent first, or NO_LCDC2_FLIP for "no change since mode 3 began".
    # An object fetch reads that bit ONCE PER BITPLANE and the two reads are
    # OBJ_PLANE_GAP dots apart, so the merge -- which happens on one dot -- has
    # to be able to ask what the bit was a few dots ago; see obj_height_at and
    # sprite_fetch_merge in fifo_ppu. Two entries is exact for the window it is
    # asked over: the lookback never exceeds OBJ_FETCH_DOTS dots and a CPU
    # cannot store to $FF40 more often than every 8 dots (4 in double speed).
    # Per-line scratch, cleared at every mode 2 -> 3 edge; not serialized.
    lcdc2_flip*:         array[2, int32]
    first_line*:         bool
    when LCD_ON_TRIM_ANY:
      lcdon_lines*:      uint8   # lines left in the LCD-on trim window
    cycle_counter*:      int32
    # The mode as it stood when this M-cycle's dots began, snapshotted at each
    # tick entry because the emulator ticks the PPU forward by the whole
    # M-cycle before read_byte runs. This is what the CPU's VRAM/OAM locks are
    # decided on (cpu_vram_open / cpu_oam_open); the mode bits a STAT READ
    # returns are NOT this -- they come off stat_chg_dot below, which is a
    # different dot. It was this latch until 2026-08-09, and the dot it lands on
    # (one before the M-cycle's first) is where the "one unaccounted-for dot" in
    # docs/gb-failure-triage.md's bucket 15 was hiding.
    #
    # Bit 7 (LY_JUST_CHANGED) rides along in the same byte: it is set by an LY
    # advance and cleared by the next tick's snapshot, i.e. it marks "LY changed
    # during the M-cycle this read belongs to". Packing it here rather than into
    # its own field keeps the per-M-cycle cost at the one store the latch
    # already paid. See ppu_read 0xFF41 for what it suppresses.
    read_mode*:          uint8
    # ---- What a STAT read's mode bits are sampled from ---------------------
    # The dot the mode last changed on and what it changed away from, which is
    # everything stat_read_mode needs: a read at dot `cc` reports the new mode
    # once `cc - stat_chg_dot >= STAT_READ_SAMPLE` and `stat_prev_mode` until
    # then. Written only by `mode_flag=` (three times a line) and rebased by
    # the line wrap, so nothing per-dot or per-M-cycle maintains it. Not
    # serialized: a state is captured at VBlank, where no mode change is inside
    # a read's sampling window, so load_ppu_state just retires the hold.
    stat_chg_dot*:       int32
    stat_prev_mode*:     uint8
    # ---- Sweep scratch: the STAT interrupt line's own phase ----------------
    # Gone from the shipping build -- the knob that gates it ships at the value
    # that needs neither field, so GbPpu's layout is untouched by its existing.
    # See the write-up at STAT_IRQ_LEAD in ppu.nim.
    when STAT_IRQ_SPLIT:
      # The mode and LY the STAT interrupt SOURCES compare against, as opposed
      # to the ones the CPU reads back out of lcd_status/LY. Not serialized:
      # re-derived from the flag domain on load (load_ppu_state), which is
      # exact at the VBlank a state is captured at.
      irq_mode*:         uint8
      irq_ly*:           uint8
    # Dots since the last frame was pushed, counted whether or not the PPU is
    # driving the panel. The panel refreshes at a fixed rate regardless, so
    # this is what keeps frame output steady across an LCD that switches off
    # and on again — see lcd_off_frame and ppu_lcd_enabled.
    dots_since_frame*:   int32
    # ---- Super Game Boy colorization hooks ----
    # Both nil on every non-SGB machine. When they are set, the emitted pixel
    # takes its colour from sgb_pal[attr * 4 + shade] instead of PRAM, where
    # `attr` is the SGB attribute of the 8x8 SCREEN cell the pixel lands in.
    # That is the whole of SGB screen colour: the SNES sees the composited
    # 2-bit GB video signal, so background and objects share one palette per
    # cell. See sgb.nim and docs/research_sgb.md.
    sgb_pal*:       ptr UncheckedArray[uint16]
    sgb_attr*:      ptr UncheckedArray[uint8]
    # output
    framebuffer*:   seq[uint16]   # 160×144 BGR555
    frame*:         bool
    ran_bios*:      bool
    # Speed-mode frameskip: render only every (frameskip+1)th frame. Honored
    # ONLY by the scanline renderer — its mode/LY/STAT timing is analytic, so
    # skipping do_scanline's pixel work is timing-neutral by construction. The
    # FIFO renderer ignores these: its mode-3 length comes from actually
    # running the pixel pipeline, so its rendering cannot be skipped. Decided
    # once per frame at LY 0 (whole frames only — do_scanline's cross-line
    # window state resets there); not serialized (render scratch). 0 = off.
    frameskip*:     int
    fs_counter*:    int
    forced_skip*:   bool

  GbScanlinePpu* = ref object of GbPpu
    scanline_color_vals*: array[160, tuple[color: uint8, priority: bool]]

  FetchStage* = enum
    fsSleep, fsGetTile, fsGetTileDataLow, fsGetTileDataHigh, fsPushPixel

  GbFifoPpu* = ref object of GbPpu
    fifo*:                GbPixelFifo
    fifo_sprite*:         GbPixelFifo
    fetch_counter*:       int
    fetcher_x*:           int
    # `SCX and 7` as it stood when this line's fine scroll was latched
    # (fifo_sample_smooth_scroll). The BG fetcher's map column is formed from
    # the line's SCREEN position plus the LIVE SCX, not from a tile index plus
    # a scroll, so the low three bits take part in the carry into the tile
    # address -- see SCX_FINE_BORROW in fifo_ppu.nim, which is where the whole
    # gambatte `scx_during_m3` family derives it. Per-line scratch, like
    # `dropped_first_fetch`: none of this block is serialized, because states
    # are captured at vblank and `reset_render_scratch` re-establishes it.
    scx_fine*:            int
    # The whole SCX term the BG fetcher adds to `fetcher_x`, borrow included:
    # `(SCX shr 3) - borrow`. Derived state kept by `fifo_arm_scx`, exactly as
    # `win_lx` is kept by `fifo_arm_window` and for the same reason -- SCX is
    # written a handful of times a line and read at every tile-map fetch, so
    # deciding the borrow at the write leaves the mode 3 dot loop the single
    # add it already was. It may be -1, which `and 0x1F` wraps to column 31,
    # which is what a borrow off column 0 means.
    scx_tile*:            int
    lx*:                  int32
    # The one `lx` on this line either window rule can fire on -- the start
    # (WX - 7) while the window is not running, the re-trigger edge (WX - 8,
    # which is the same dot one pixel earlier in the shifter) while it is -- or
    # WIN_LX_OFF when neither can. Derived state, kept by fifo_arm_window from
    # the four inputs that decide it (LCDC.5, WX, the WY latch,
    # fetching_window), none of which moves outside a register write or a fetch
    # restart. It exists so the shifter spends ONE compare per mode 3 dot on
    # the window instead of two conjunctions: measured on blargg 01-special,
    # the second per-dot branch alone is +1.7% of retired instructions.
    # Next to `lx` on purpose -- the two are compared on every mode 3 dot, and
    # putting it after the bool block instead measured +0.6% on its own.
    win_lx*:              int32
    smooth_scroll_sampled*: bool
    dropped_first_fetch*: bool
    # The line's FIRST `B01s` cycle -- the one that follows the discarded fetch
    # at the head of mode 3 -- is running. It is the one fetch on a line that
    # may not push early: see M3_THROWAWAY_DOTS in fifo_ppu, where the 12-dot
    # head budget forces it to run all the way to its push slot. Set when the
    # discarded fetch is aborted, cleared by that push. Per-line scratch, like
    # dropped_first_fetch next to it.
    head_cycle*:          bool
    fetching_window*:     bool
    fetching_sprite*:     bool
    # The CONSOLE, cached off GB.cgb_enabled when the FIFO PPU is built. The
    # end of mode 3 is per-device for one window start (CGB_WIN_TAIL_LAST) and
    # the two procs that decide it -- fetcher_retired and fifo_irq_m0_ready --
    # are reached from the dot loop with no `gb` in hand; a bool inside the
    # bool block costs the object nothing. Not serialized: a machine cannot
    # change model under a running core, so a loaded state re-derives it the
    # same way GB.cgb_enabled does.
    cgb*:                 bool
    # An object was fetched on the LINE'S LAST PIXEL. Per-line scratch, like
    # dropped_first_fetch: set at the object trigger, cleared at the mode 2 ->
    # 3 edge. Read only by fetch_work_pending, and only on a CGB, where a
    # window restart on that pixel and an object's fetch on it are one fetch
    # slot and not two -- see CGB_WIN_TAIL_LAST.
    obj_last_px*:         bool
    # A window START is owed to the next line: the WX comparator matched on the
    # line's LAST pixel, where a DMG's end-of-line cleanup cannot clear it
    # (DMG_WIN_LAST_PX_CARRY). Set at the end of mode 3, consumed at the head of
    # the next line whose LCDC.5 is set -- which may be several lines later, or
    # in the next FRAME, so unlike its neighbours here it is NOT per-line
    # scratch. Cleared with the rest of the render scratch, and never set on a
    # CGB.
    #
    # NOT serialized: see the deferred-payload note on the GB save state. A
    # state captured at vblank can only carry this from LY 143's own match, and
    # loading one without it costs at most the first line of one frame.
    win_carry*:           bool
    # LCDC.5 has been low since the carry above was owed, so spending it has to
    # REACTIVATE the window and not merely continue it -- worth
    # WIN_CARRY_REACT_LINES on the window line counter. Same lifetime as
    # win_carry and not serialized for the same reason.
    win_carry_gap*:       bool
    # Dots of WIN_EN_HOLD left on a WX match that LCDC.5 refused. Zero means
    # no match is waiting, which is every dot of almost every line; while it is
    # nonzero `win_lx` is the hold's own retry pixel and fifo_arm_window leaves
    # it alone. Per-line scratch.
    #
    # DOWN HERE, in the bool block, and not next to `win_lx` where it is read:
    # inserting a byte between `lx` and `win_lx` splits the pair the shifter
    # compares on every mode 3 dot and measured **+0.6% of retired
    # instructions** on Pokemon Blue, Pokemon Crystal and Link's Awakening DX
    # -- the same 0.6% the note on `win_lx` above records for moving `win_lx`
    # itself. This field is touched a handful of times a line and pays nothing
    # for sitting with the flags.
    win_hold*:            uint8
    # The last dot on which a store to SCX still moves this line's fine
    # scroll, or -1 outside that window. Only `SCX_FINE_LATCH_LIVE` reads it,
    # and it exists only when that is on: an unconditional field here measured
    # +0.21% of retired instructions with the mechanism itself compiled out,
    # which is the object-layout cliff `win_lx` and `win_hold` both record.
    when SCX_FINE_LATCH_LIVE:
      scx_latch_until*:   int32
    # The LOW THREE BITS of the dot the line latched its fine scroll on. The
    # wrap needs how many of the window's eight slots the discard has already
    # walked, and that is a slot index, so three bits are the whole of it --
    # `scx_latch_until` cannot supply them once a store has moved the window's
    # end. A byte because three bits is honestly all it is -- NOT for layout:
    # as an `int32` it benches the same to within the noise (0.232% against
    # 0.246%), so the mechanism's price is the branch in `fifo_arm_scx` and not
    # this field, which is the one thing the `win_lx` layout cliff would have
    # predicted and does not happen here.
    when SCX_FINE_LATCH_WRAP != 0:
      scx_latch_slot*:    uint8
    # Dots left in the stall a mid-line SCX store armed. Same layout argument
    # as the field above: it exists only when the mechanism is on.
    when SCX_STORE_STALL_DOTS != 0:
      scx_stall*:         int32
    # Dots left in the object fetch the shifter is stalled on, and which BG
    # tile last paid the "wait for the BG fetch" half of an object's penalty.
    # Both are the OBJ penalty algorithm's state; see tick_shifter's trigger.
    obj_penalty*:         int32
    obj_tile_fx*:         int32
    # Dots of OBJ penalty charged on this line so far. Only the field tail
    # reads it; per-line scratch, cleared at the mode 2 -> 3 edge. Present only
    # when that mechanism is on, and DOWN HERE with the rest of the object
    # scratch rather than up beside `scx_tile`: a word between the fields the
    # fetch reads costs more than the mechanism itself does, which is the same
    # layout cliff `win_lx` and `win_hold` each record.
    when STAT_M0_TAIL_ANY:
      obj_dots_line*:     int32
    # ---- The object fetch's two bitplane reads, as dots ---------------------
    #
    # `sprite_fetch_merge` runs on one dot, but the fetch it stands for reads
    # the two bitplanes OBJ_PLANE_GAP dots apart and reads LCDC.2 separately for
    # each of them. `obj_hi_dot` is the dot the HIGH plane's read samples that
    # bit on, latched at the trigger because it depends on which end of the
    # penalty the fetch sits at (see OBJ_PLANE1_LAG in fifo_ppu). The low
    # plane's is always OBJ_PLANE_GAP dots before it, and always in the past.
    #
    # The high plane's can be in the FUTURE -- up to OBJ_PLANE1_LAG dots after
    # the merge -- so the merge uses the bit as it stands and the write path
    # redoes the plane if a later write moves it, exactly as fifo_recompose_last
    # redoes the mixer's tail. `obj_fix_from` is the first dot such a write can
    # land on (the merge dot + 1) and is OBJ_FIX_OFF when nothing is in flight;
    # the rest is the whole of what a redo needs -- the low byte the merge kept,
    # the height the high plane used, its VRAM bank and the object. No snapshot
    # of the FIFO goes with them: the merge is undoable from the entries
    # themselves, see fifo_obj_size_write. All per-line scratch, live for at most
    # OBJ_PLANE1_LAG dots, and not serialized.
    obj_hi_dot*:          int32
    obj_fix_from*:        int32
    obj_fix_bank*:        int32
    obj_fix_lo*:          uint8
    obj_fix_h*:           uint8
    obj_fix_s*:           GbSprite
    # Idle dots left at the head of mode 3 (the pipeline's lead over the CPU's
    # register view; see M3_PIPE_DELAY in fifo_ppu). A byte, not an int, and
    # for one reason: the mode 3 branch of fifo_tick_slow's dot loop asks
    # "is the head spent?" once per M-cycle of mode 3 -- ~6,200 times a frame
    # -- and a byte answers it in `ldrb`+`cbz` where a signed int needs
    # `ldr`+`cmp`+`b.le`. The value is 0..12 by construction (M3_PIPE_MCYCLES
    # * 4 + M3_PIPE_DELAY).
    m3_delay*:            uint8
    # Dots the mode 3 -> 0 FLAG still owes after the fetcher has retired, so
    # that a line whose pipeline started early (LY0_PIPE_MCYCLES in fifo_ppu:
    # line 0, and only line 0) still leaves mode 3 on the dot every other line
    # does. Zero on every other line, and a byte for the same reason m3_delay
    # is one. Transient per-line state, like m3_delay and m3_lead: not
    # serialized.
    m3_hold*:             uint8
    # How far the pipeline lags the CPU's view of the PPU registers on THIS
    # line, in dots. Latched at the mode 2 -> 3 edge because the CPU M-cycle it
    # is derived from is 4 dots at normal speed and 2 in double speed. See
    # M3_PIPE_MCYCLES in fifo_ppu.
    m3_lead*:             int32
    # ---- LCDC.4 against the two bitplane reads (CGB only) -------------------
    #
    # `tdsel_dot` is the dot LCDC.4 last CHANGED on, NO_TDSEL_CHANGE when it
    # has not changed on this line. The fetcher reads the bit
    # CGB_TDSEL_LATENCY dots later than the CPU wrote it and glitches a read
    # that lands on that dot exactly; both need the dot, and nothing else does.
    # Only a CGB records it, which is what keeps the DMG path at one compare.
    #
    # `tdsel_addr` is the most recent $8000-region tile-data read's VRAM
    # address -- an object bitplane, an LCDC.4 = 1 background bitplane, or a
    # RESET-glitched read, which drove its $8000-region address before the
    # reset arrived. A SET-glitched read delivers the byte there.
    # TDSEL_ADDR_OFF when nothing has driven one yet.
    #
    # BANK IS PACKED IN, at bit 13, rather than kept in a field of its own:
    # this is written by EVERY unsigned bitplane read of every frame, and the
    # second store cost +0.20% of retired instructions on blargg cpu_instrs
    # where the packed one costs +0.20% for the whole rule. Unpacking happens
    # once per glitched read, which is a handful of dots a frame at most.
    #
    # THE INDEX PATH'S ARMING IS PACKED IN TOO, at bit 14 and above: the last
    # dot a SET-glitched read may still answer with the tile INDEX rather than
    # the byte at the address (CGB_TDSEL_IDX_DOTS, TDSEL_IDX_SHIFT). A field of
    # its own costs 8 bytes of object and moves the whole fetch path's offsets,
    # which measured more than the rule does.
    #
    # `tdsel_dot` is per-line scratch cleared at the mode 2 -> 3 edge, and so
    # are the arming bits -- they are a dot on this line's clock. The ADDRESS
    # deliberately is NOT, because H-Blank does not clear the bus register it
    # stands for (see CGB_TDSEL_GLITCH). Neither field is serialized: a state is
    # captured in vblank.
    tdsel_dot*:           int32
    tdsel_addr*:          int32
    # ---- LCDC.3 / LCDC.6 against the map address read (CGB only) ------------
    #
    # `map_dot` is the dot the last change to either TILE MAP select bit goes
    # LIVE on at the fetcher -- the dot it was written on plus
    # CGB_MAP_LATENCY -- and NO_MAP_CHANGE when neither has moved on this line.
    # `map_old` is bits 3 and 6 as they stood before that write, which is what
    # a map read before `map_dot` uses. One dot and one byte covers both bits
    # because the writes that move them are the same store; when a later write
    # lands inside an earlier one's latency the newest wins, which is the same
    # corner (and the same resolution) `tdsel_dot` has.
    #
    # Per-line scratch cleared at the mode 2 -> 3 edge, and not serialized: a
    # state is captured in vblank. Only a CGB ever records a change.
    map_dot*:             int32
    map_old*:             uint8
    tile_num*:            uint8
    tile_attrs*:          uint8
    fetch_scy*:           uint8   ## SCY as of this fetch's map read; read
                                  ## back only when quirks.scy_fetch_latch
    tile_data_low*:       uint8
    tile_data_high*:      uint8
    # The FIFO entries the mixer is still holding: the pairs popped on the last
    # MIX_HOLD dots that emitted a pixel, indexed by the pixel's own low bits.
    # The mixer stage runs one dot behind the
    # pop (see fifo_recompose_last in fifo_ppu), so a mid-mode-3 write to a
    # register the mixer reads -- the palettes, LCDC's OBJ-enable and
    # BG-priority bits -- still reaches the pixel already written out. Kept
    # here rather than re-read from the ring because the BG ring is rewound and
    # overwritten by the next push and the OBJ ring is only popped when it is
    # non-empty, so neither can be indexed backwards safely.
    #
    # The ring is MIX_HOLD deep rather than as deep as the deepest stage
    # because the tail burst emits the last `m3_lead` pixels of a line ahead of
    # their own dots, and a write on the first dots of H-Blank still reaches
    # them (MIXER_TAIL_HBLANK).
    mix*:                 array[MIX_HOLD, GbMixHold]
    # Which dot this line's pixel 0 would have left the shifter on, if the
    # shifter's current unbroken run of one-pixel-per-dot emissions had started
    # there: `cycle_counter - lx`, written at each of the three places the
    # shifter STOPS (mixer_note_stop), which is everywhere that quantity can
    # change. While a stall is in progress it therefore still describes the run
    # the stall interrupted, and the shifter's position reads back as
    # `cycle_counter - tail_dot0` -- which keeps counting through an object
    # fetch and through the tail burst, where `lx` does not.
    # That is the whole of MIXER_TAIL_DOTS; see fifo_recompose_last.
    tail_dot0*:           int32
    # The first `lx` of that run, i.e. the `lx` the NEXT run starts at once the
    # stall clears. Pixels before it left the FIFO at least one dot further back
    # than `tail_dot0` says, so nothing may reach them -- the stall that broke
    # the run is 6..11 dots long (an object fetch) and the deepest mixer stage
    # is two.
    mix_run*:             int32
    sprites*:             seq[GbSprite]
    # The mode-2 OAM scan's progress: the index of the next OAM entry the scan
    # will examine, and the line the partial result in `sprites` belongs to.
    # The scan normally runs as one burst at the end of mode 2 (nothing can
    # change OAM while it is in progress, so where in mode 2 it runs is
    # unobservable) -- these two only carry it when an OAM DMA *is* changing
    # OAM underneath it, and the scan then has to be walked forward to the
    # dot of each transferred byte. See oam_scan_advance in fifo_ppu.nim.
    # Per-line scratch like everything above: not serialized, and rebuilt by
    # the burst on the next mode 2 -> 3 transition.
    scan_next*:           int32
    scan_line*:           int32

  # ---- APU Channels (base types) ----
  GbSoundChannel* = ref object of RootObj
    enabled*:        bool
    dac_enabled*:    bool
    length_counter*: int
    length_enable*:  bool

  GbVolumeEnvChannel* = ref object of GbSoundChannel
    starting_volume*:        uint8
    envelope_add_mode*:      bool
    period*:                 uint8
    volume_envelope_timer*:  uint8
    current_volume*:         uint8
    vol_env_is_updating*:    bool
    # "Enabling the envelope triggers an APU bug - in the next *even* DIV-APU
    # tick, the APU will tick the volume envelope of that appropriate channel,
    # even if it would not tick volume envelope at that tick otherwise"
    # (SameSuite channel_1_nrx2_speed_change). Set by an NRx2 write that takes
    # the envelope period from zero to non-zero, consumed by the next even
    # frame-sequencer step. See write_NRx2 and tick_frame_sequencer.
    #
    # Deliberately NOT serialized, like GbApu.tick_phase: it lives for at most
    # one 512 Hz step (~2 ms) and it is set only by a register write, so a
    # rollback that replays that write reconstructs it.
    env_extra_tick*:         bool

  GbChannel1* = ref object of GbVolumeEnvChannel
    wave_duty_position*: int
    # The square channel's LATCHED duty output (0 or 1). Hardware does not read
    # the duty table continuously: it samples it once per duty step and holds
    # that bit until the next one, so a mid-sample NR11 duty change is not
    # audible until the step after it (SameSuite channel_1_duty_delay: "Changing
    # the duty becomes effective only after the current sample finishes"), and a
    # trigger keeps emitting the PREVIOUS sample -- zero, if the channel was off
    # -- for the whole startup delay (channel_1_duty / channel_1_align). See
    # ch1_catchup_slow, which is the only place that refreshes it.
    #
    # Deliberately NOT serialized, for the same reason as GbApu.tick_phase: it
    # is refreshed by the next duty step, so a loaded state is at most one duty
    # period (4 us to 2 ms) of one channel's sample away from exact, and it
    # errs towards silence rather than towards a wrong level.
    sample_bit*:         uint8
    # Absolute scheduler cycle of the next duty step, or GB_NO_STEP when the
    # channel has never been triggered. Replaces a per-period scheduler event:
    # the duty counter is advanced in closed form when something observes it
    # (see ch1_catchup). NOT serialized as a field -- savestate.nim converts
    # it to/from an etAPUChannel1 event so the state format is unchanged.
    next_step*:          CycleCount
    sweep_period*:       uint8
    negate*:             bool
    shift*:              uint8
    sweep_timer*:        uint8
    frequency_shadow*:   uint16
    sweep_enabled*:      bool
    negate_used*:        bool
    # Absolute scheduler cycle at which the sweep's SECOND overflow check falls
    # due, or GB_NO_STEP when none is pending. The check trails the frequency
    # writeback by 7 M-cycles and re-reads NR10 when it runs; see
    # GB_SWEEP_CHECK_DELAY for the three SameSuite sources that say so.
    #
    # Deliberately NOT serialized, like GbApu.tick_phase: it is pending for 8
    # M-cycles at most (2 us) once per sweep period, it is written only by a
    # sweep step, and a rollback snapshot that replays that step reconstructs
    # it. A state loaded from disk mid-window loses one overflow check, which
    # can at worst leave a channel audible until the next sweep step re-arms it.
    # Serializing it would cost a GB payload revision bump. The three sweep-unit
    # deadlines below are unserialized for exactly the same reason and are part
    # of the same deferred batch.
    sweep_check_at*:     CycleCount
    # Absolute scheduler cycle at which a sweep overflow STOP reaches NR52, or
    # GB_NO_STEP when none is in flight. Every sweep calculation's stop is one
    # APU tick behind the calculation itself; see GB_SWEEP_STOP_DELAY.
    sweep_stop_at*:      CycleCount
    # A trigger's frequency-shadow load in flight: the value NR13/NR14 held when
    # the channel was triggered, and the absolute scheduler cycle it reaches the
    # sweep unit's shadow register (GB_NO_STEP when none is pending). The load
    # does NOT happen on the write; see GB_SWEEP_SHADOW_DELAY.
    sweep_load_at*:      CycleCount
    sweep_load_value*:   uint16
    # Absolute scheduler cycle of the most recent duty step, or GB_NO_STEP when
    # none has happened since the last trigger. Only ch1_reload_is_now reads it,
    # and only to tell "the frequency timer is reloading on this very cycle"
    # apart from "the trigger's start delay happens to be one period away",
    # which next_step alone cannot distinguish.
    #
    # Deliberately NOT serialized, like GbApu.tick_phase: it decides a one-cycle
    # tie on an NR13/NR14 write and is rewritten by the next duty step, i.e.
    # within one sample. Serializing it would cost a GB payload revision bump.
    # GbChannel2 carries its own copy for the same reason.
    last_step_at*:       CycleCount
    duty*:               uint8
    length_load*:        uint8
    frequency*:          uint16

  GbChannel2* = ref object of GbVolumeEnvChannel
    wave_duty_position*: int
    sample_bit*:         uint8        # see GbChannel1.sample_bit
    next_step*:          CycleCount   # see GbChannel1.next_step
    last_step_at*:       CycleCount   # see GbChannel1.last_step_at; unserialized
    duty*:               uint8
    length_load*:        uint8
    frequency*:          uint16

  GbChannel3* = ref object of GbSoundChannel
    next_step*:              CycleCount   # see GbChannel1.next_step
    wave_ram*:               array[16, uint8]
    wave_ram_position*:      uint8
    # Whether CH3 has fetched a byte since its last trigger. A trigger reloads
    # the frequency timer with period + 6 (Pan Docs: "triggering does not
    # immediately start playing wave RAM"), so for that whole window there is no
    # "byte CH3 is currently reading" -- which on DMG means a CPU access to wave
    # RAM has nothing to land on. See ch3_wave_open; it is the only thing that
    # separates "the pointer is at 0 because we just triggered" from "the
    # pointer is at 0 because it just wrapped".
    #
    # Deliberately NOT serialized, like GbApu.tick_phase: it is false only
    # inside a startup window a few T-cycles long, and it defaults to the value
    # a running channel has.
    wave_fetched*:           bool
    wave_ram_sample_buffer*: uint8
    length_load*:            uint8
    volume_code*:            uint8
    volume_code_shift*:      uint8
    frequency*:              uint16

  GbChannel4* = ref object of GbVolumeEnvChannel
    next_step*:    CycleCount   # see GbChannel1.next_step
    lfsr*:         uint16
    length_load*:  uint8
    clock_shift*:  uint8
    width_mode*:   uint8
    divisor_code*: uint8
    # The noise channel's frequency timer is not one counter, it is two, and
    # NR43 selects a different view of BOTH without restarting either. See
    # ch4_steps_to_rise: `div_counter` is a free-running counter clocked by the
    # divisor stage, and `clock_shift` picks which of its bits clocks the LFSR;
    # `div_next` is the divisor stage itself, the absolute cycle of the next
    # increment. `next_step` stays the derived "next LFSR shift" deadline so the
    # catch-up guard is still one comparison.
    #
    # Deliberately NOT serialized, and joining the batch of GB fields already
    # waiting on one payload-revision bump rather than spending a bump each.
    # A state is loaded with both re-derived from `next_step` (gb_apply_state,
    # ch4_resync_divisor), which reproduces the LFSR schedule exactly and can
    # only differ if the game writes NR43 inside the first period after a load.
    div_counter*:  uint16
    div_next*:     CycleCount

  GbApu* = ref object
    sound_enabled*:       bool
    buffer*:              seq[float32]
    buffer_pos*:          int
    frame_sequencer_stage*: int
    # Phase of the APU's own 1 MHz tick grid, in scheduler cycles: a tick edge
    # lands on every cycle congruent to this modulo (4 shl speed). The square
    # channels' frequency timers are clocked by that grid, not by the CPU, so a
    # trigger written between two edges does not start counting until the next
    # one -- which is what SameSuite channel_1_align_cpu measures ("Channel 1 is
    # aligned to the APU's enable time, not the CPU's start time"): inserting
    # nops BEFORE the NR52 power-on moves the whole grid with the write and
    # changes nothing, while the nops between power-on and trigger in
    # channel_1_align shift the result by one CPU cycle. Reset by an APU
    # power-on; see apu_write and gb_trigger_deadline.
    #
    # Deliberately NOT serialized. It is only ever written by a power-on, so a
    # rollback snapshot that replays one reconstructs it exactly; a state loaded
    # from disk falls back to the scheduler's own grid, which costs at most half
    # an APU tick (~0.25 us) of pulse phase and is inaudible. Serializing it
    # would cost a GB payload revision bump, which is worth spending on a batch
    # of fields rather than on this one.
    tick_phase*:          CycleCount
    # Phase of the HALF-rate grid the noise channel's divisor stage is clocked
    # by, in scheduler cycles: this is the power-on cycle taken modulo
    # (8 shl speed), and an edge of that 512 kHz grid lands on every cycle
    # congruent to `noise_phase + (4 shl speed)` -- i.e. on the ODD 1 MHz ticks
    # counted from the power-on. NR43's divisor field counts on this grid and a
    # trigger cannot reset it, which is what SameSuite
    # channel_4_frequency_alignment measures; see gb_noise_deadline for the
    # derivation and the cross-checks. Reset by an APU power-on, exactly like
    # tick_phase.
    #
    # Deliberately NOT serialized, for the same reasons as tick_phase: written
    # only by a power-on, worth at most one 1 MHz tick of noise phase, and
    # serializing it would cost a GB payload revision bump.
    noise_phase*:         CycleCount
    # "The first DIV-APU event after a power-on is skipped when DIV's tap bit
    # was already high" (SameSuite div_write_trigger_10). The divider is what
    # actually clocks the sequencer, so powering the APU on part-way through a
    # tap period leaves the divider half a step ahead of the sequencer: the
    # edge that ends that period has already been accounted for and produces no
    # step. See apu_write's NR52 arm and tick_frame_sequencer.
    #
    # Deliberately NOT serialized, like tick_phase: it is true only between an
    # APU power-on and the next 512 Hz edge (under 2 ms), it is written only by
    # a power-on, and a rollback that replays one reconstructs it exactly.
    div_skip*:            bool
    # Whether the sequencer's NEXT step is one that does NOT clock the length
    # counter -- the "extra length clocking" gate on an NRx4 write. Note it is
    # a property of the DIVIDER's phase, not of frame_sequencer_stage: while
    # div_skip is pending the two disagree, and div_write_trigger_10 is exactly
    # the test that can tell.
    first_half_of_length_period*: bool
    left_enable*:         bool
    left_volume*:         uint8
    right_enable*:        bool
    right_volume*:        uint8
    nr51*:                uint8
    sync*:                bool
    channel_mask*:        array[4, bool]  # pulse 1/2, wave, noise; true = enabled
    # Master volume as a precomputed factor (1.0 = unity), applied per
    # buffer at the queue point
    master_volume_factor*: float32
    master_muted*:        bool
    # 2x speed: drop every other stereo frame at the queue point so
    # audio-driven pacing runs emulation twice as fast
    turbo*:               bool
    turbo_parity:         bool  # emscripten per-sample decimation state
    # Pitch-correct fast-forward (WSOLA); presentation-only, see the GBA APU.
    pitch_correct_ff*:    bool
    stretch:              TimeStretch
    stretch_engaged:      bool
    audio_dev*:           uint32
    channel1*:            GbChannel1
    channel2*:            GbChannel2
    channel3*:            GbChannel3
    channel4*:            GbChannel4
    # Output-stage DC blocker (see GB_DC_CHARGE and get_sample). Charge held on
    # the coupling capacitor, one per stereo side. Deliberately NOT serialized:
    # it is presentation state, not emulated state, and the filter re-converges
    # within ~6 ms of a state load — inaudible, and a state that restores it
    # would only be restoring the tail of a filter, not anything about the
    # machine. (It would no longer be expensive to add: since v7 the container
    # version describes only the header and each core carries its own payload
    # revision, so a GB field costs a GB migration and nothing on the GBA side.
    # It is left out because it does not belong in the file, not because the
    # format makes it costly.)
    dc_cap_left*:         float32
    dc_cap_right*:        float32
    left_resampler*:      Resampler[float32]
    right_resampler*:     Resampler[float32]
    resample_freq*:       int
    output_freq*:         int

  # ---- Memory ----
  GbMemory* = ref object
    wram*:                 array[8, seq[uint8]]
    wram_bank*:            uint8
    rp*:                   uint8 # RP ($FF56) stored bits 0/6/7 — the LED and
                                 # the read-enable pair. Readback ORs $3E:
                                 # bits 2-5 read set and bit 1 is "no IR
                                 # signal", which is all this models (no IR
                                 # link). An AGS with no IR window still
                                 # carries the register and reads $3E at boot
                                 # (gbedge p00, 2026-08-17). Not serialized —
                                 # cosmetic readback state.
    svbk_raw*:             uint8 # the bits the SVBK write actually carried:
                                 # readback is raw, only the MAPPING aliases
                                 # 0 -> 1 (SameBoy stores `value | ~7`, DocBoy
                                 # reads the stored bank; a written 0 reads
                                 # back $F8, not $F9). Not serialized — the
                                 # payload keeps wram_bank, and a post-load
                                 # readback of an explicitly-written 0 is the
                                 # only divergence.
    hram*:                 array[0x7F, uint8]
    # $FEA0-$FEFF, the "prohibited" tail of the OAM page. On CGB revisions 0-D
    # it is real RAM (Pan Docs, "FEA0-FEFF range": "On CGB revisions 0-D, this
    # area is a unique RAM area"); on DMG and on CGB-E and later nothing here
    # is read. Which of the three models applies is GbQuirks.unusable_region.
    #
    # NOT SERIALIZED, deliberately, and for the same reason `revision` is not:
    # a byte-array in GB_SEC_MEM costs a GB payload revision bump, which is
    # being taken once for a batch (notes/samesuite-apu.md, "Unserialized
    # state"). The consequence is bounded -- a state saved after a ROM seeded
    # this region loads with it zeroed -- and the only ROMs known to seed it
    # do so once during setup, before any state a user would take.
    # IF A GB PAYLOAD BUMP HAPPENS FOR ANY OTHER REASON, ADD THIS ONE.
    unusable*:             array[0x60, uint8]
    bootrom*:              seq[uint8]
    cycle_tick_count*:     int
    # A CPU write this M-cycle has left something for the M-cycle boundary to
    # do (an IF store, a STAT interrupt-line edge). mem_write applies the byte
    # BEFORE the M-cycle's PPU dots, because that is the phase the pixel
    # pipeline needs; the interrupt machinery was never out of phase with the
    # CPU, so the half of a write that feeds IT stays on the boundary. One flag
    # for both so the write path pays a single test. See mem_flush_deferred.
    write_deferred*:       bool
    # The register write that flag stands for, when it is a whole store and not
    # just a STAT edge: FF41 or FF55, the two that GATE a PPU event (see
    # ppu_write_machinery). 0 = none. One slot is enough -- the CPU
    # writes one byte per M-cycle -- and it is drained before a second one can
    # be recorded, so the non-M-cycle callers cannot lose one either. Never live
    # across an instruction boundary, so it is not serialized.
    deferred_reg*:         uint16
    deferred_val*:         uint8
    when CGB_WRITE_LATENCY_ANY:
      # The other direction: a CGB pipeline-register store that lands PART WAY
      # THROUGH this M-cycle's PPU dots rather than at either end of them. Same
      # one-slot, drained-before-refilled discipline as the pair above, and for
      # the same reason. 0 = none. See mem_tick_ppu_latched.
      pipe_reg*:           uint16
      pipe_val*:           uint8
    ff72*, ff73*, ff74*, ff75*: uint8
    dma*:                  uint8
    current_dma_source*:   uint16
    internal_dma_timer*:   int
    dma_position*:         int
    requested_oam_dma*:    bool
    next_dma_counter*:     uint8
    # Derived from dma_position, maintained by mem_dma_tick: true for exactly
    # the M-cycles in `dma_position in 1 .. 0xA0`, i.e. while the OAM DMA unit
    # owns a bus. Every CPU read and write tests it, so it is one bool load
    # instead of the pair of range compares that used to sit on that path; it
    # is a cache of existing state, not new state (see gb_recompute_dma_derived).
    dma_busy*:             bool
    # Which bus the running OAM DMA owns (a GbDmaBus ordinal), the byte it last
    # put on that bus, and what the source memory does to the data lines when
    # the CPU writes over them (a Drive* constant). All three are derived: the
    # bus and drive class from current_dma_source, the latch from the source
    # memory at dma_position-1.
    dma_bus*:              uint8
    dma_latch*:            uint8
    dma_drive*:            uint8
    dma_openbus*:          bool
    requested_speed_switch*: bool
    current_speed*:        uint8

  # ---- Main GB type ----
  GB* = ref object of EmuObj
    bootrom_path*:   string
    rom_path*:       string
    # The two model axes, and they are NOT the same question.
    #
    # `cgb_enabled` is the CONSOLE: a CGB (or AGB) is in front of you. It
    # decides timing and the hardware quirks that belong to the SoC — the DMG
    # STAT-write glitch, the OAM bus release inside mode 2, the serial tap, the
    # line-144 STAT lead. None of those care what cartridge is inserted.
    #
    # `cgb_native` is the MODE: the CGB's own graphics and register set are in
    # use. A DMG cart on CGB hardware runs in DMG-compatibility mode — the boot
    # ROM sets KEY0 at handoff — where KEY1/HDMA/SVBK/VBK/BCPD/OCPD/PCM12/PCM34
    # read as unmapped (mooneye misc/bits/unused_hwio-C), BG map attributes and
    # the OBJ attribute's palette/bank nibble are not decoded, LCDC.0 is DMG's
    # "BG on/off" rather than the CGB's master priority, objects are ordered by
    # X again, and every pixel goes through BGP/OBP before it indexes palette 0.
    # The boot ROM itself always runs native, which is how it writes the
    # compatibility palettes it is about to hand over.
    #
    # A DMG-compatibility CGB is therefore CGB timing with a DMG picture, and
    # collapsing either axis onto the other gets one half of that wrong. This is
    # a cached derivation of `cgb_enabled and (cgb_flag != cgbNone or the boot
    # ROM is still mapped)` and not a proc because it is read per pixel; keep it
    # in step via `gb_sync_cgb_native` at every point those three inputs move.
    #
    # ---- What hardware splits by model and this tree still does NOT --------
    #
    # Audited 2026-08-03 against Pan Docs, the mealybug PPU document and the
    # per-model expectations mooneye/AGE/gambatte carry in their own filenames.
    # Everything below is documented behaviour that dingbat currently emulates
    # identically on both consoles. Ordered by how measurable it is here.
    #
    # Measurable today, unfixed:
    #  * LCDC.1 mid-mode-3. On DMG, clearing OBJ enable part way through an
    #    object fetch CANCELS it, so mode 3 does not lengthen; on CGB the fetch
    #    runs regardless and the bit is only consulted when the pixel is popped
    #    (Pan Docs, Pixel FIFO -> Mode 3 Operation -> Sprites: "this condition
    #    is ignored on CGB"). dingbat models neither the cancel nor the split;
    #    see OBJ_FETCH_DOTS in fifo_ppu.nim. gambatte's 56 DMG-only
    #    sprites/late_disable_* rows and mealybug m3_lcdc_obj_en_change on both
    #    devices are the instrument.
    #  * LCDC.4 mid-fetch (the TILE_SEL glitch). CGB-only: changing the tile
    #    data select on a bitplane-read dot substitutes stale data rather than
    #    doing the read. mealybug m3_lcdc_tile_sel_change is 95.5% on the CGB
    #    side and m3_lcdc_tile_sel_change2 is a CGB-only ROM for exactly this.
    #  * LCDC.5 clear resets the window's Y condition on CGB, so WY must be met
    #    again in the same frame; on DMG the latch persists (Pan Docs, Window
    #    behavior -> Window rendering criteria). ppu_latch_wy has no such reset.
    #  * WX = 166 is a monochrome-only bug (the window spans the screen offset
    #    by one line), and the DMG-only WX+1 late trigger with it. Both are in
    #    the window family this tree scores 295/476 on.
    #  * $FEA0-$FEFF. read_byte answers 0x00 for every model. That is right for
    #    DMG only: a CGB has real RAM there with a revision-specific address
    #    fold, and CGB-E and AGB answer the high nibble of the low address byte
    #    twice (Pan Docs, Memory Map -> FEA0-FEFF range).
    #  * OAM DMA source above $DFFF folds down into $C000-$DFFF on DMG and
    #    fills OAM with $FF on CGB (mooneye acceptance/oam_dma/sources-GS,
    #    "fail: CGB/AGB/AGS").
    #  * OPRI ($FF6C) is not implemented at all. It only matters for a cart
    #    that writes it while the boot ROM is mapped, which no test ROM here
    #    does, but the register reads as unmapped rather than as itself.
    #  * The APU has no model branch anywhere, and three are documented: wave
    #    RAM is only accessible on the dot CH3 reads it on monochrome consoles
    #    (elsewhere the CPU gets the byte CH3 is on), retriggering CH3 corrupts
    #    wave RAM on monochrome only, and NRx1 length timers stay writable with
    #    the APU off on monochrome only (Pan Docs, Audio Registers, all three).
    #
    # Not measurable by anything this tree runs:
    #  * HALT entry/wake granularity (2 T-cycles on DMG, 4 on CGB, plus a CGB
    #    termination M-cycle) — mooneye halt_ime1_timing2-GS is "fail: CGB".
    #  * DI's delay on CGB. mooneye acceptance/di_timing-GS asserts one
    #    outright; Pan Docs describes DI as immediate with no model note. Left
    #    alone deliberately: the sources disagree and nothing here can arbitrate.
    #  * The joypad line-switch settling delay (DMG/MGB only) and contact
    #    bounce, neither of which dingbat models on any device.
    #  * The IR port ($FF56) — CGB-only hardware, unimplemented.
    #  * STOP outside a speed switch: a DMG keeps drawing a black line, a CGB
    #    blanks unless it is in mode 3.
    #
    # Deliberately out of scope: everything that splits CGB revisions rather
    # than consoles (SCY bitplane caching from CGB-D, the LY=153 and OAM-read
    # boundaries, the $FEA0 fold, half the APU). dingbat models ONE CGB, and
    # the references it is scored against are CPU CGB C.
    #
    # The SCY entry in that list is the one that keeps being re-opened, so:
    # reading SCY LIVE at each of a tile fetch's three VRAM reads -- the map
    # row, then again per bitplane -- is not an omission here, it is the
    # specified behaviour of every device this tree models. Pan Docs,
    # "Mid-frame behavior": "The scroll registers are re-read on each tile
    # fetch" and "All models before the CGB-D read the Y coordinate once for
    # each bitplane (so a very precisely timed SCY write allows 'desyncing'
    # them), but CGB-D and later use the same Y coordinate for both no matter
    # what." Caching them into one per-fetch latch would be the CGB-D
    # behaviour, i.e. wrong for CPU CGB C and wrong for DMG. It is also
    # confirmed rather than merely documented: decoded per tile, the mealybug
    # m3_scy_change DMG reference has the map fetch and the low bitplane on one
    # write and the high bitplane on the NEXT one wherever a write lands
    # between them, and fifo_ppu's live reads reproduce that band exactly (see
    # the SCY bullet at CGB_SCY_LATENCY).
    cgb_enabled*:    bool
    cgb_native*:     bool
    # Frontend opt-in for Super Game Boy emulation. Default OFF, and off for
    # every caller that does not say otherwise -- the test harnesses, the
    # benchmark and the ROM sweeps all build a GB directly, and stock DMG
    # behaviour is what they are scoring against. Only ever consulted at
    # post_init; the cart header still has the final say after that.
    sgb_requested*:  bool
    fifo*:           bool
    headless*:       bool
    run_bios*:       bool
    cartridge*:      Mbc
    rom_size*:       uint32
    ram_size*:       int
    cgb_flag*:       CgbFlag
    boot_model*:     GbBootModel
    # The silicon revision, and the behaviour resolved from it. Set once by
    # gb_set_revision (new_gb, then any --model= override) and never touched
    # again, which is why the emulation code can read `quirks` without a
    # dispatch and why neither field is in the save state.
    #
    # NOT SERIALIZED, deliberately, and the same is true of `boot_model` next
    # door: both are construction-time properties of the *machine*, and a
    # state is loaded into a machine that was already constructed. The
    # consequence is real but narrow -- a state saved on `--model=cgb0` and
    # loaded by a default-revision process runs the loaded state on a CGB E,
    # silently. Nothing in the shipping frontends can reach a non-default
    # revision (there is no UI for it), so today this is only reachable from
    # the test harness. Serializing `revision` (one byte, next to
    # `cgb_enabled` in GB_SEC_MEM, with older states reading back the default)
    # costs a GB payload revision bump, which is being taken once for a batch;
    # see notes/samesuite-apu.md "Unserialized state". IF A GB PAYLOAD BUMP
    # HAPPENS FOR ANY OTHER REASON, ADD THIS ONE.
    revision*:       GbRevision
    quirks*:         GbQuirks
    rom_title*:      string
    scheduler*:      Scheduler
    cpu*:            GbCpu
    interrupts*:     GbInterrupts
    joypad*:         GbJoypad
    ppu*:            GbPpu
    # The same object as `ppu` when the FIFO renderer is selected, nil for the
    # scanline one. Lets the per-M-cycle component tick reach the shipping
    # renderer as a direct call instead of a method dispatch (which showed up
    # as ~2-3% of a profile in chckNilDisp alone). Non-owning: `ppu` owns it.
    fifo_ppu* {.cursor.}: GbFifoPpu
    timer*:          GbTimer
    serial*:         GbSerial
    memory*:         GbMemory
    apu*:            GbApu
    # Non-nil only when the cart header unlocks SGB functions and the machine
    # is not in CGB mode; every SGB hook tests it. See sgb.nim.
    sgb*:            SgbState
    cheats*:         CheatEngine
    cheat_hooks:     MemHooks       # built once, reused each frame
    when defined(test_harness):
      test_output*:  TestOutput

# ==================== FETCHER ORDER ====================
const FETCHER_ORDER*: array[-5 .. 7, FetchStage] = [
  # Steps -5..-1 are the window startup fetch's IDLE HEAD, and only a line that
  # starts as a window line ever enters there (WIN_HEAD_ABSORB in fifo_ppu):
  # the head is six dots whatever WX is, the `7 - WX` fine-scroll discard eats
  # that many of them at the shifter, and the fetcher waits out the other
  # `WX - 1`. Spelling it as negative steps of the fetcher's own order costs
  # the mode 3 dot loop nothing -- the `case` on it is dispatched every dot
  # already, and fsSleep's `inc` walks the counter back up to 0 on its own.
  # WX < WIN_LINE_START_WX, so five entries covers every threshold up to 7.
  fsSleep, fsSleep, fsSleep, fsSleep, fsSleep,
  fsSleep, fsGetTile, fsSleep, fsGetTileDataLow,
  fsSleep, fsGetTileDataHigh, fsSleep, fsPushPixel,
]
static: doAssert WIN_LINE_START_WX - 2 <= 5,
  "WIN_HEAD_ABSORB idles WX - 1 dots; FETCHER_ORDER's negative head must cover it"

# DMG default colors (BGR555)
const DMG_COLORS*: array[4, uint16] = [0x6BDF'u16, 0x3ABF'u16, 0x35BD'u16, 0x2CEF'u16]

# The CGB's DMG-compatibility palettes, shade 0 (lightest) to shade 3.
#
# A DMG cart on CGB hardware still produces a 2-bit shade per pixel; what the
# CGB adds is that BGP/OBP0/OBP1 then index a real colour palette, which the
# boot ROM loads before handoff. Which one it loads depends on the cart header:
# Nintendo-published titles get a themed palette picked by the header checksum,
# and everything else — every homebrew and every test ROM — gets the fallback
# below. That fallback is what the bundled test suites specify as "LCD shades
# for CGB compatibility mode" (game-boy-test-roms' mealybug howto, and the same
# six colours appear in the AGE `ncm*` and mbc3-tester-cgb references):
#
#   background  #000000  #0063C6  #7BFF31  #FFFFFF   (shade 3 -> 0)
#   objects     #000000  #943939  #FF8484  #FFFFFF
#
# converted to BGR555 by the inverse of the (X shl 3) or (X shr 2) expansion
# those same suites specify, which is exact for all six.
#
# Only the fallback is here. Reproducing the per-title table would mean lifting
# Nintendo's boot ROM data, and it buys nothing measurable: it changes the
# colours of thirty-odd licensed monochrome carts and nothing else — not one
# test ROM, since none of them carry a Nintendo licensee code.
const CGB_COMPAT_BG_COLORS*:  array[4, uint16] =
  [0x7FFF'u16, 0x1BEF'u16, 0x6180'u16, 0x0000'u16]
const CGB_COMPAT_OBJ_COLORS*: array[4, uint16] =
  [0x7FFF'u16, 0x421F'u16, 0x1CF2'u16, 0x0000'u16]

const GB_WIDTH*  = 160
const GB_HEIGHT* = 144
const GB_CLOCK_SPEED* = 4194304

# Queue-push block, in float32s (128 stereo frames = 3.9 ms); small so
# audio-sync pacing sees a fine-grained queue level (see gba/apu.nim)
const GB_APU_BUFFER_SIZE* = 256
# Audio-sync pacing levels in bytes of queued f32 stereo (8 bytes/frame);
# fixed rather than derived from the push block: 4096 B = 512 frames ≈ 15.6 ms.
# The backstop is runaway protection only — far above the normal operating
# range so it never blocks emulation mid-frame (see gba/apu.nim)
const GB_SYNC_AHEAD_BYTES*    = 4096'u32
const GB_SYNC_BACKSTOP_BYTES* = 32768'u32
const GB_SAMPLE_RATE*     = 32768
const GB_SAMPLE_PERIOD*   = GB_CLOCK_SPEED div GB_SAMPLE_RATE

# The share of the output's -1..1 range given to one channel's DAC (get_sample).
#
# The mixer adds up to four DAC outputs, each spanning -1..1, so one side of the
# mix spans -4..4 (Pan Docs, Audio Details: "the analog range of those outputs
# is 4x that of each channel"). Nothing in the hardware pins that to a host's
# full scale -- there is an amplifier and a volume knob in between -- so this is
# a headroom decision, and it is made by the DC blocker downstream.
#
# The blocker emits `mix - cap`, where the stored charge tracks the mix's local
# MEAN. Both terms are independently bounded by the mixer range, so the output
# can reach twice it. That is not a corner case here: a channel that is switched
# off but whose DAC is still powered parks at analog +1 (see GB_DAC_LUT), so the
# mean genuinely does sit near a rail for long stretches, and a waveform
# excursion to the other rail then spans the full 2x. At 1/4 -- what the mixer
# used before the DC blocker existed, where a full-scale mix was exactly
# full-scale output -- that clips. 1/8 makes overflow arithmetically impossible:
# |mix| <= 1/2 and |cap| <= 1/2, so |out| <= 1.
#
# 1/8 is also exactly SameBoy's level (its MAX_CH_AMP is 0xFF0, so its four
# channels sum to half of int16 range), which means its dumps and ours are
# directly comparable without renormalising.
const GB_MIX_SCALE* = 1.0'f32 / 8.0'f32

# NR50 master volume, indexed by the register's 3-bit field, already folded
# together with GB_MIX_SCALE.
#
# Pan Docs, NR50: "A value of 0 is treated as a volume of 1 (very quiet), and a
# value of 7 is treated as a volume of 8 (no volume reduction). Importantly, the
# amplifier NEVER MUTES a non-silent input." So the scale is (V+1)/8, not V/7:
# volume 0 is one eighth of full, and a driver that fades NR50 down to 0 does
# not reach silence on hardware.
const GB_MASTER_VOLUME* = block:
  var t: array[8, float32]
  for v in 0 .. 7: t[v] = float32(float64(v + 1) / 8.0) * GB_MIX_SCALE
  t

# Output-stage DC blocker.
#
# A Game Boy channel's DAC does not idle at the middle of its range: the 4-bit
# digital value 0 is one RAIL, not silence (see GB_DAC_LUT). A 12.5%-duty square
# therefore sits at the top of its swing seven eighths of the time, and a
# channel that is switched off but still has its DAC powered sits there
# permanently. So the mixer's output carries a large DC component that moves
# every time a DAC is powered up or down, or panning or master volume changes.
# Measured on 60 s of in-game audio, the raw mix sits at 0.85 full scale in
# Link's Awakening DX and pins against a rail for a quarter of all samples.
#
# The hardware couples the mixer to the output jack through a capacitor, which
# removes that offset. Without it every one of those DC shifts reaches the
# speaker as a step, and a step is what a listener hears as a click. This is the
# standard one-pole model: the capacitor charges toward the input, and only the
# difference is passed on.
#
#     out = in - cap;   cap = in - out * charge
#
# `charge` is per output sample, so it is the per-T-cycle constant raised to the
# number of T-cycles between samples: 0.999958 ** (GB_CLOCK_SPEED / rate). At
# 32768 Hz that is 0.9946383, a 28 Hz corner with a 5.7 ms time constant --
# below anything the APU can play, so it removes offset and nothing else.
#
# Verified against SameBoy on identical 60 s in-game runs (tools/popscan.py, the
# same threshold on both sides since the two now share an output level): the DC
# trajectory matches to within a few per cent on every title measured. Pokemon
# Crystal 16 steps / 5969 per-second total variation / 195 DC rms against
# SameBoy's 20 / 5934 / 195; Link's Awakening DX 12 / 4859 / 167 against 10 /
# 4832 / 165; Prehistorik Man 150 / 9620 / 339 against 178 / 9877 / 345.
const GB_DC_CHARGE* = 0.9946383125'f32
const GB_FRAME_SEQ_RATE*  = 512
const GB_FRAME_SEQ_PERIOD* = GB_CLOCK_SPEED div GB_FRAME_SEQ_RATE

# Post-boot VRAM tile data ($8000-$819F): blank tile $00, the Nintendo logo
# ($01-$18), and the ® trademark tile ($19). Several Mealybug PPU tests place
# these on screen without loading them, relying on the boot ROM having left them
# in VRAM (the reference images were captured on hardware that ran the boot ROM).
#
# We deliberately do NOT hardcode Nintendo's logo here — reproducing their
# trademark logo as source data is avoidable. Instead we decompress it at boot
# from the LOADED cartridge's own header (every valid GB ROM carries it at
# 0x104-0x133; the real boot ROM verifies it), exactly as the boot ROM does.
# This ships no Nintendo logo data and is more faithful (a ROM with a corrupted
# header logo renders the corrupted logo, like real hardware). The ® tile is a
# generic registered-trademark glyph (circle-R), not Nintendo-specific IP.
const POST_BOOT_RA_TILE*: array[16, uint8] = [
  0x3C'u8, 0x00, 0x42, 0x00, 0xB9, 0x00, 0xA5, 0x00,
  0xB9, 0x00, 0xA5, 0x00, 0x42, 0x00, 0x3C, 0x00,
]

proc write_boot_logo*(rom: openArray[byte]; vram: var openArray[uint8]) =
  ## Expand the 48-byte header logo (rom[0x104..0x133]) into the 384 bytes of
  ## tile data at tiles $01-$18 (vram[16..399]), mirroring the DMG boot ROM's
  ## nibble-doubling decompressor: each header byte's two nibbles are each
  ## spread to a full 8-pixel row (bit i -> pixels 2i,2i+1) and written to two
  ## consecutive tile rows (2x vertical), low bitplane only.
  if rom.len < 0x134 or vram.len < 400: return
  proc double_bits(n: uint8): uint8 =
    for i in 0 ..< 4:
      if (n and (1'u8 shl i)) != 0:
        result = result or (0b11'u8 shl (i * 2))
  var pos = 16  # tile $01, byte 0
  for k in 0 ..< 48:
    let v = rom[0x104 + k]
    for nib in [v shr 4, v and 0x0F]:
      let e = double_bits(nib)
      vram[pos] = e; pos += 2   # low plane, row N (high plane stays 0)
      vram[pos] = e; pos += 2   # low plane, row N+1 (2x vertical)

# ==================== PIXEL FIFO HELPERS ====================

proc fifo_push*(f: var GbPixelFifo; p: GbPixel) {.inline.} =
  f.data[f.tail] = p
  f.tail = (f.tail + 1) and 15
  inc f.size

proc fifo_shift*(f: var GbPixelFifo): GbPixel {.inline.} =
  result = f.data[f.head]
  f.head = (f.head + 1) and 15
  dec f.size

proc fifo_clear*(f: var GbPixelFifo) {.inline.} =
  f.head = 0; f.tail = 0; f.size = 0

proc fifo_get*(f: var GbPixelFifo; idx: int): GbPixel {.inline.} =
  f.data[(f.head + idx) and 15]

proc fifo_set*(f: var GbPixelFifo; idx: int; p: GbPixel) {.inline.} =
  f.data[(f.head + idx) and 15] = p

# ==================== CPU REGISTER ACCESSORS ====================

proc a*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.af shr 8)
proc `a=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.af = (cpu.af and 0x00FF'u16) or (uint16(v) shl 8)
proc f*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.af and 0xF0)
proc `f=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.af = (cpu.af and 0xFF00'u16) or uint16(v and 0xF0)
proc b*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.bc shr 8)
proc `b=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.bc = (cpu.bc and 0x00FF'u16) or (uint16(v) shl 8)
proc c*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.bc and 0xFF)
proc `c=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.bc = (cpu.bc and 0xFF00'u16) or uint16(v)
proc d*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.de shr 8)
proc `d=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.de = (cpu.de and 0x00FF'u16) or (uint16(v) shl 8)
proc e*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.de and 0xFF)
proc `e=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.de = (cpu.de and 0xFF00'u16) or uint16(v)
proc h*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.hl shr 8)
proc `h=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.hl = (cpu.hl and 0x00FF'u16) or (uint16(v) shl 8)
proc l*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.hl and 0xFF)
proc `l=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.hl = (cpu.hl and 0xFF00'u16) or uint16(v)

# Flags: Z=bit7, N=bit6, H=bit5, C=bit4
proc fz*(cpu: GbCpu): bool {.inline.} = (cpu.af and 0x0080'u16) != 0
proc `fz=`*(cpu: GbCpu; v: bool) {.inline.} =
  if v: cpu.af = cpu.af or 0x0080'u16
  else: cpu.af = cpu.af and not 0x0080'u16
proc fn*(cpu: GbCpu): bool {.inline.} = (cpu.af and 0x0040'u16) != 0
proc `fn=`*(cpu: GbCpu; v: bool) {.inline.} =
  if v: cpu.af = cpu.af or 0x0040'u16
  else: cpu.af = cpu.af and not 0x0040'u16
proc fh*(cpu: GbCpu): bool {.inline.} = (cpu.af and 0x0020'u16) != 0
proc `fh=`*(cpu: GbCpu; v: bool) {.inline.} =
  if v: cpu.af = cpu.af or 0x0020'u16
  else: cpu.af = cpu.af and not 0x0020'u16
proc fc*(cpu: GbCpu): bool {.inline.} = (cpu.af and 0x0010'u16) != 0
proc `fc=`*(cpu: GbCpu; v: bool) {.inline.} =
  if v: cpu.af = cpu.af or 0x0010'u16
  else: cpu.af = cpu.af and not 0x0010'u16

# ==================== MBC HELPERS (shared) ====================

proc mbc_rom_bank_offset*(cart: Mbc; bank_num: int): int =
  (bank_num * 0x4000) mod int(cart.rom.len)

proc mbc_rom_offset*(idx: int): int = idx - 0x4000

proc mbc_ram_bank_offset*(cart: Mbc; bank_num: int): int =
  if cart.ram.len == 0: return 0
  (bank_num * 0x2000) mod cart.ram.len

proc mbc_ram_offset*(cart: Mbc; idx: int): int =
  ## Offset inside the selected 8 KiB RAM window. RAM smaller than the window
  ## (header code $01, 2 KiB — "PD" ROMs use it) has its high address lines
  ## unwired, so the window mirrors the array (Pan Docs, MBCs: accesses wrap)
  ## instead of indexing past it.
  if cart.ram.len >= 0x2000 or cart.ram.len == 0: idx - 0xA000
  else: (idx - 0xA000) mod cart.ram.len

const
  RTC_SECOND_CYCLES* = 4194304  # one RTC tick per emulated second
  MINUTES_PER_DAY*   = 60 * 24

# Deterministic-RTC override for lockstep/rollback netplay. With two peers the
# MBC3 clock must NOT read the local wall clock (it would differ between peers)
# and must NOT free-run (the tick count differs between a straight run and its
# rollback re-simulation — a determinism gap that diverges Crystal's DIV/RTC-
# seeded RNG). When set >= 0 it is the shared "now" (unix seconds) both peers
# pass at connect: the load-time catch-up uses it, and the clock is then FROZEN
# (no ticks). Mirrors the GBA core's enable_deterministic_rtc. -1 = real clock,
# free-running (single-player default).
var gbRtcNowOverride*: int64 = -1

proc enable_deterministic_gb_rtc*(epoch: int64) =
  ## Freeze the MBC3 RTC to a shared epoch. Both peers must pass the SAME
  ## value. Call before loading the cartridge/state.
  gbRtcNowOverride = epoch

proc gb_rtc_now(): int64 {.inline.} =
  if gbRtcNowOverride >= 0: gbRtcNowOverride else: getTime().toUnix()

proc gb_rtc_frozen(): bool {.inline.} = gbRtcNowOverride >= 0

proc rtc_halted*(cart: Mbc3): bool =
  (cart.rtc_live[4] and 0x40) != 0

proc rtc_schedule_full*(cart: Mbc3) =
  if gb_rtc_frozen(): return  # deterministic mode: clock frozen, never ticks
  cart.gb_ref.scheduler.clear(etRtcSecond)
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)

proc rtc_remaining*(cart: Mbc3): int =
  ## Scheduler cycles until the pending RTC tick
  let s = cart.gb_ref.scheduler
  for ev in s.events:
    if ev.kind == etRtcSecond:
      return int(ev.cycles - s.cycles)
  RTC_SECOND_CYCLES

proc rtc_increment(cart: Mbc3) =
  # Hardware counters roll over at their natural boundaries with carry, but
  # out-of-range values (writable because registers are wider than needed)
  # count up to the register limit and wrap without carrying
  let s = cart.rtc_live[0] and 0x3F
  if s != 59:
    cart.rtc_live[0] = if s == 63: 0'u8 else: s + 1
    return
  cart.rtc_live[0] = 0
  let m = cart.rtc_live[1] and 0x3F
  if m != 59:
    cart.rtc_live[1] = if m == 63: 0'u8 else: m + 1
    return
  cart.rtc_live[1] = 0
  let h = cart.rtc_live[2] and 0x1F
  if h != 23:
    cart.rtc_live[2] = if h == 31: 0'u8 else: h + 1
    return
  cart.rtc_live[2] = 0
  let day = (uint16(cart.rtc_live[4] and 1) shl 8) or uint16(cart.rtc_live[3])
  let new_day = (day + 1) and 0x1FF
  cart.rtc_live[3] = uint8(new_day and 0xFF)
  cart.rtc_live[4] = (cart.rtc_live[4] and 0xC0) or uint8(new_day shr 8)
  if day == 511:  # day counter overflow: sticky carry flag
    cart.rtc_live[4] = cart.rtc_live[4] or 0x80

proc rtc_tick*(cart: Mbc3) =
  if gb_rtc_frozen(): return  # deterministic mode: clock frozen
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)
  cart.rtc_increment()

proc rtc_catch_up(cart: Mbc3; elapsed: int64) =
  ## Advance the clock by wall time that passed while the emulator was off
  if cart.rtc_halted() or elapsed <= 0: return
  let secs  = int64(cart.rtc_live[0] and 0x3F) + elapsed
  cart.rtc_live[0] = uint8(secs mod 60)
  let mins  = int64(cart.rtc_live[1] and 0x3F) + secs div 60
  cart.rtc_live[1] = uint8(mins mod 60)
  let hours = int64(cart.rtc_live[2] and 0x1F) + mins div 60
  cart.rtc_live[2] = uint8(hours mod 24)
  let days  = (int64(cart.rtc_live[4] and 1) shl 8) + int64(cart.rtc_live[3]) + hours div 24
  cart.rtc_live[3] = uint8(days and 0xFF)
  cart.rtc_live[4] = (cart.rtc_live[4] and 0xC0) or uint8((days shr 8) and 1)
  if days > 511:
    cart.rtc_live[4] = cart.rtc_live[4] or 0x80

proc rtc_footer(cart: Mbc3): string =
  ## BGB/VBA-compatible .sav footer: live regs, latched regs, unix timestamp
  proc add_u32(s: var string; v: uint32) =
    for i in 0 .. 3: s.add(char((v shr (8 * i)) and 0xFF))
  result = ""
  for i in 0 .. 4: result.add_u32(uint32(cart.rtc_live[i]))
  for i in 0 .. 4: result.add_u32(uint32(cart.rtc_latched[i]))
  let ts = uint64(gb_rtc_now())
  for i in 0 .. 7: result.add(char((ts shr (8 * i)) and 0xFF))

proc rtc_load_footer(cart: Mbc3; data: string) =
  ## BGB, mGBA and 64-bit VBA builds all write exactly RAM + 48 bytes, and old
  ## 32-bit VBA builds RAM + 44 (32-bit timestamp). Any other tail is NOT a
  ## clock — typically a forum download padded out to a power of two — and
  ## parsing padding as a footer scrambles the RTC (an all-zero tail reads as
  ## "saved January 1970" and catch-up then walks the day counter through five
  ## decades), so only the two exact lengths are accepted.
  proc get_u32(data: string; off: int): uint32 =
    for i in 0 .. 3: result = result or (uint32(data[off + i]) shl (8 * i))
  let base = cart.ram.len
  let extra = data.len - base
  if extra != 44 and extra != 48: return  # no footer, or a tail that isn't one
  for i in 0 .. 4: cart.rtc_live[i]    = uint8(get_u32(data, base + i * 4) and 0xFF)
  for i in 0 .. 4: cart.rtc_latched[i] = uint8(get_u32(data, base + 20 + i * 4) and 0xFF)
  var ts: int64 = int64(get_u32(data, base + 40))
  if extra == 48:
    ts = ts or (int64(get_u32(data, base + 44)) shl 32)
  # A timestamp before 2000 cannot be a real dump time (the footer format and
  # every RTC cartridge postdate it): the field is zeroed or garbage. Keep the
  # register values the footer states, but skip the decades of "catch-up" the
  # bogus timestamp implies. Future timestamps already no-op inside catch-up.
  if ts >= 946684800:
    cart.rtc_catch_up(gb_rtc_now() - ts)

# HuC3's clock lives inside the cartridge's microcontroller, in the same nibble
# window its other registers do: a minute-of-day counter at 0x10-0x12 and a day
# counter at 0x13-0x15, both little-endian nibble triples. Everything below
# knows that layout; mbc/huc3.nim knows the protocol that reaches it.

const
  # Nibble addresses inside that window. Only these have been pinned down; the
  # games use plenty more that nobody has identified.
  HUC3_SNAPSHOT*  = 0x00  # 0x00-0x06, where the clock is copied to be read
  HUC3_CLOCK*     = 0x10  # 0x10-0x12 minute of day, 0x13-0x15 days, 0x16 unknown
  HUC3_CLOCK_LEN* = 7     # a cartridge dump shows 0x10-0x16 copied across whole
  HUC3_EVENT*     = 0x58  # 0x58-0x5A event minutes, 0x5B-0x5D event days
  HUC3_DAY_WRAP*  = 0x1000  # the day counter is three nibbles and no more

proc nyb3*(cart: Huc3; at: int): int =
  int(cart.regs[at]) or (int(cart.regs[at + 1]) shl 4) or (int(cart.regs[at + 2]) shl 8)

proc set_nyb3*(cart: Huc3; at, v: int) =
  cart.regs[at]     = uint8(v and 0xF)
  cart.regs[at + 1] = uint8((v shr 4) and 0xF)
  cart.regs[at + 2] = uint8((v shr 8) and 0xF)

proc huc3_now_minutes*(cart: Huc3): int =
  ## The clock as one number, for arithmetic that has to cross a day boundary
  cart.nyb3(HUC3_CLOCK + 3) * MINUTES_PER_DAY + cart.nyb3(HUC3_CLOCK)

proc huc3_advance_minutes(cart: Huc3; count: int) =
  if count <= 0: return
  let minutes = cart.nyb3(HUC3_CLOCK) + count
  cart.set_nyb3(HUC3_CLOCK, minutes mod MINUTES_PER_DAY)
  cart.set_nyb3(HUC3_CLOCK + 3,
                (cart.nyb3(HUC3_CLOCK + 3) + minutes div MINUTES_PER_DAY) mod HUC3_DAY_WRAP)

proc huc3_advance_to(cart: Huc3; now: int64) =
  ## Step the clock over every whole minute between last_second and now. Keeping
  ## last_second rather than resetting it means the minute ticks stay on the
  ## host's minute boundaries across a save and reload, instead of restarting
  ## the minute every time the game is launched.
  let elapsed = now div 60 - cart.last_second div 60
  if elapsed <= 0: return
  cart.last_second += elapsed * 60
  # A whole day-counter cycle is as far as the clock can meaningfully move, and
  # capping there also keeps a nonsense timestamp out of a 32-bit int (the web
  # build's) on the way into the nibble arithmetic.
  cart.huc3_advance_minutes(int(min(elapsed, HUC3_DAY_WRAP * MINUTES_PER_DAY)))

proc huc3_rtc_schedule*(cart: Huc3) =
  if gb_rtc_frozen(): return  # deterministic mode: clock frozen, never ticks
  cart.gb_ref.scheduler.clear(etRtcSecond)
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)

proc huc3_rtc_tick*(cart: Huc3) =
  if gb_rtc_frozen(): return
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)
  cart.huc3_advance_to(cart.last_second + 1)

# Battery footer: the unix second the clock was last stepped through, then the
# whole 256-nibble register window packed two nibbles to a byte. The window is
# the state — clock, event time, tone selection and whatever else that
# cartridge's microcontroller keeps there — so saving a hand-picked subset of it
# would lose whatever a given game happens to use. This is dingbat's own layout;
# no other emulator writes it, because no other emulator keeps the window whole.
const HUC3_FOOTER_LEN = 8 + 128

proc huc3_footer(cart: Huc3): string =
  result = newStringOfCap(HUC3_FOOTER_LEN)
  let ts = uint64(cart.last_second)
  for i in 0 .. 7: result.add(char((ts shr (8 * i)) and 0xFF))
  for i in 0 ..< 128:
    result.add(char(cart.regs[i * 2] or (cart.regs[i * 2 + 1] shl 4)))

proc huc3_load_footer(cart: Huc3; data: string) =
  let base = cart.ram.len
  # Exact length only: this is dingbat's own layout, so any other tail is a
  # padded download or another emulator's footer, not this one.
  if data.len - base != HUC3_FOOTER_LEN: return  # RAM-only save: keep the power-on clock
  var ts: int64 = 0
  for i in 0 .. 7: ts = ts or (int64(uint8(data[base + i])) shl (8 * i))
  for i in 0 ..< 128:
    let b = uint8(data[base + 8 + i])
    cart.regs[i * 2]     = b and 0x0F
    cart.regs[i * 2 + 1] = b shr 4
  cart.last_second = ts
  let now = gb_rtc_now()
  if ts > now:
    # Saved in the future: the clock would sit still until the host caught up,
    # so treat the host as authoritative and carry on from here instead.
    cart.last_second = now
  else:
    cart.huc3_advance_to(now)

# TAMA5's clock is a TC8521AM reached through the cartridge's microcontroller.
# Its layout is four pages of thirteen 4-bit registers plus three registers
# shared between the pages, all from endrift's tables in the gbdev thread
# (https://gbdev.gg8.se/forums/viewtopic.php?id=469, post #1). mbc/tama5.nim
# knows the protocol that reaches them; what is here is the clock itself.
#
#   page 0, TIMER   0 sec 1s   1 sec 10s  2 min 1s  3 min 10s  4 hour 1s
#                   5 hour 10s 6 weekday  7 day 1s  8 day 10s  9 month 1s
#                   A month 10s          B year 1s  C year 10s
#   page 1, ALARM   same fields where an alarm has one, plus A = 24-hour mode
#                   and B = the leap-year counter
#   pages 2 and 3   "free pages, which are effectively just 13 4-bit RAM
#                   addresses each"

const
  # Per-register wired-bit widths: "RTC registers only have a certain number of
  # bits wired up, so writing to bits that aren't used during normal function
  # won't do anything and will read out as zero" (endrift, post #1).
  TAMA5_RTC_MASK*: array[4, array[13, uint8]] = [
    [0xF'u8, 0x7, 0xF, 0x7, 0xF, 0x3, 0x7, 0xF, 0x3, 0xF, 0x1, 0xF, 0xF],
    # Alarm page: registers 0, 1, 9 and C have no bits at all; A is the 1-bit
    # 24-hour mode flag and B the 2-bit leap-year counter.
    [0x0'u8, 0x0, 0xF, 0x7, 0xF, 0x3, 0x7, 0xF, 0x3, 0x0, 0x1, 0x3, 0x0],
    [0xF'u8, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF],
    [0xF'u8, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF]]

  # A cartridge that has been in a drawer for a decade should not spend that
  # long in a catch-up loop, and the Tamagotchi has nothing useful to say about
  # a gap this size anyway.
  TAMA5_MAX_CATCHUP_DAYS = 4000

proc tama5_24h(cart: Tama5): bool =
  ## Alarm page register A. endrift, post #1: "A: 24-hour mode when set (1-bit)"
  (cart.rtc_pages[1][0x0A] and 1) != 0

proc tama5_get_minutes*(cart: Tama5): int =
  int(cart.rtc_pages[0][3]) * 10 + int(cart.rtc_pages[0][2])

proc tama5_set_minutes*(cart: Tama5; v: int) =
  cart.rtc_pages[0][3] = uint8((v div 10) and 0x7)
  cart.rtc_pages[0][2] = uint8(v mod 10)

proc tama5_get_hours*(cart: Tama5): int =
  ## The register pair as the game wrote it, which in 12-hour mode carries the
  ## PM flag in the tens digit rather than being a plain number.
  int(cart.rtc_pages[0][5]) * 10 + int(cart.rtc_pages[0][4])

proc tama5_set_hours*(cart: Tama5; v: int) =
  cart.rtc_pages[0][5] = uint8((v div 10) and 0x3)
  cart.rtc_pages[0][4] = uint8(v mod 10)

proc tama5_hour24(cart: Tama5): int =
  ## The hour as a 0-23 number, for arithmetic that has to cross midnight.
  let t = cart.rtc_pages[0]
  if cart.tama5_24h(): (int(t[5] and 3) * 10 + int(t[4])) mod 24
  else:
    # endrift, post #1: "in 12 hour mode, the high bit signals PM, so 11 PM/23
    # 10s digit would be 0b10 in 24 hour mode, but 0b11 in 12 hour mode, as it's
    # 1X:XX PM". So bit 0 of the tens digit is the digit and bit 1 is PM.
    let h12 = int(t[5] and 1) * 10 + int(t[4])
    ((h12 mod 12) + (if (t[5] and 2) != 0: 12 else: 0)) mod 24

proc tama5_set_hour24(cart: Tama5; h: int) =
  if cart.tama5_24h():
    cart.rtc_pages[0][5] = uint8((h div 10) and 3)
    cart.rtc_pages[0][4] = uint8(h mod 10)
  else:
    var h12 = h mod 12
    if h12 == 0: h12 = 12
    cart.rtc_pages[0][5] = uint8((h12 div 10) or (if h >= 12: 2 else: 0))
    cart.rtc_pages[0][4] = uint8(h12 mod 10)

proc tama5_days_in_month(month, leap_counter: int): int =
  # endrift, post #1: the alarm page's register B is a 2-bit counter and "the
  # year is treated as a leap year if 0". It is separate from the year so that
  # software can still call year 00 a common year, as 2100 will be.
  case month
  of 2:                      (if leap_counter == 0: 29 else: 28)
  of 4, 6, 9, 11:            30
  else:                      31

proc tama5_advance*(cart: Tama5; seconds: int64) =
  ## Step the clock forward. Written as arithmetic rather than a per-second loop
  ## so that catching up after the emulator has been closed for a month costs
  ## the same as one tick.
  if seconds <= 0: return
  var total = int64(int(cart.rtc_pages[0][1]) * 10 + int(cart.rtc_pages[0][0])) +
              int64(cart.tama5_get_minutes()) * 60 +
              int64(cart.tama5_hour24()) * 3600 + seconds
  var days = int(min(total div 86400, int64(TAMA5_MAX_CATCHUP_DAYS)))
  let tod = int(total mod 86400)

  cart.rtc_pages[0][0] = uint8((tod mod 60) mod 10)
  cart.rtc_pages[0][1] = uint8((tod mod 60) div 10)
  cart.tama5_set_minutes((tod div 60) mod 60)
  cart.tama5_set_hour24(tod div 3600)
  if days <= 0: return

  var t = addr cart.rtc_pages[0]
  var dow   = int(t[6]) mod 7
  var day   = max(int(t[8]) * 10 + int(t[7]), 1)
  var month = clamp(int(t[0x0A]) * 10 + int(t[9]), 1, 12)
  var year  = int(t[0x0C]) * 10 + int(t[0x0B])
  var leap  = int(cart.rtc_pages[1][0x0B] and 3)
  while days > 0:
    dec days
    inc day
    dow = (dow + 1) mod 7
    if day > tama5_days_in_month(month, leap):
      day = 1
      inc month
      if month > 12:
        month = 1
        year = (year + 1) mod 100
        # The leap counter has to move with the year or February would be 29
        # days long forever. Nobody has published what the TC8521AM does with it
        # on rollover; counting it up is the only reading that keeps the "0 means
        # leap" rule meaningful.
        leap = (leap + 1) and 3
  t[6]      = uint8(dow)
  t[7]      = uint8(day mod 10)
  t[8]      = uint8(day div 10)
  t[9]      = uint8(month mod 10)
  t[0x0A]   = uint8(month div 10)
  t[0x0B]   = uint8(year mod 10)
  t[0x0C]   = uint8(year div 10)
  cart.rtc_pages[1][0x0B] = uint8(leap)

proc tama5_seed_clock*(cart: Tama5) =
  ## Power-on state when there is no battery file. The TC8521AM runs off its own
  ## cell whether or not the Game Boy is on, so a cartridge always has *some*
  ## time in it; seeding from the host clock is the same choice HuC3 makes here,
  ## and spares the player setting a date the host already knows. UTC rather
  ## than local time so that the deterministic-RTC override gives both netplay
  ## peers the same answer.
  let now = utc(fromUnix(gb_rtc_now()))
  cart.rtc_pages[1][0x0A] = 1   # 24-hour mode, so the seeded hour reads plainly
  cart.tama5_set_hour24(now.hour)
  cart.tama5_set_minutes(now.minute)
  cart.rtc_pages[0][0] = uint8(now.second mod 10)
  cart.rtc_pages[0][1] = uint8(now.second div 10)
  cart.rtc_pages[0][6] = uint8(ord(now.weekday) mod 7)
  cart.rtc_pages[0][7] = uint8(now.monthday mod 10)
  cart.rtc_pages[0][8] = uint8(now.monthday div 10)
  cart.rtc_pages[0][9] = uint8(ord(now.month) mod 10)
  cart.rtc_pages[0][0x0A] = uint8(ord(now.month) div 10)
  cart.rtc_pages[0][0x0B] = uint8((now.year mod 100) mod 10)
  cart.rtc_pages[0][0x0C] = uint8((now.year mod 100) div 10)
  cart.rtc_pages[1][0x0B] = uint8(now.year mod 4)   # 0 = this year is a leap year
  cart.last_second = gb_rtc_now()

proc tama5_rtc_schedule*(cart: Tama5) =
  if gb_rtc_frozen(): return  # deterministic mode: clock frozen, never ticks
  cart.gb_ref.scheduler.clear(etRtcSecond)
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)

proc tama5_rtc_tick*(cart: Tama5) =
  if gb_rtc_frozen(): return
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)
  # PAGE register bit 3 is TIMER ENABLE (endrift, post #1); with it clear the
  # counters stand still, which is the state a cartridge powers up in until the
  # game issues TAMA6 command 0x41.
  if (cart.page_reg and 0x08) != 0:
    cart.tama5_advance(1)
    cart.ram_dirty = true
  cart.last_second += 1

# Battery footer. Unlike HuC3's, this layout is not dingbat's own: FlashGBX (a
# cartridge reader/writer) and mGBA both write a TAMA5 .sav as 32 bytes of SRAM
# followed by four pages of sixteen nibbles packed low-nibble-first, then a
# 64-bit little-endian unix timestamp. No document specifies it — the clock
# lives in the TC8521AM, not in a file — but matching those two means a save can
# move between dingbat, mGBA and a real cartridge.
const TAMA5_FOOTER_LEN = 4 * 8 + 8

proc tama5_page_nibble(cart: Tama5; page, reg: int): uint8 =
  if reg <= 0x0C: cart.rtc_pages[page][reg]
  elif reg == 0x0D: cart.page_reg and 0x0F   # shared across pages; stored in each
  else: 0'u8                                 # E and F read back as zeros

proc tama5_footer(cart: Tama5): string =
  result = newStringOfCap(TAMA5_FOOTER_LEN)
  for p in 0 .. 3:
    for i in 0 .. 7:
      result.add(char(cart.tama5_page_nibble(p, i * 2) or
                      (cart.tama5_page_nibble(p, i * 2 + 1) shl 4)))
  let ts = uint64(cart.last_second)
  for i in 0 .. 7: result.add(char((ts shr (8 * i)) and 0xFF))

proc tama5_load_footer(cart: Tama5; data: string) =
  let base = cart.ram.len
  # Exact length only: FlashGBX and mGBA write exactly this and nothing more,
  # so a longer tail is padding, not a footer with extras.
  if data.len - base != TAMA5_FOOTER_LEN: return  # RAM-only save: keep the seeded clock
  for p in 0 .. 3:
    for i in 0 .. 7:
      let b = uint8(data[base + p * 8 + i])
      if i * 2 <= 0x0C: cart.rtc_pages[p][i * 2] = b and 0x0F
      if i * 2 + 1 <= 0x0C: cart.rtc_pages[p][i * 2 + 1] = b shr 4
      if i * 2 + 1 == 0x0D and p == 0: cart.page_reg = b shr 4
  var ts: int64 = 0
  for i in 0 .. 7: ts = ts or (int64(uint8(data[base + 32 + i])) shl (8 * i))
  let now = gb_rtc_now()
  # Saved in the future (or with no timestamp at all): treat the host as
  # authoritative and carry on from here, as the HuC3 loader does.
  if ts <= 0 or ts > now:
    cart.last_second = now
  else:
    cart.last_second = now
    if (cart.page_reg and 0x08) != 0: cart.tama5_advance(now - ts)

# MBC6's flash is as much a part of the save as its SRAM is — it is what the
# game downloaded — so it rides along in the same file. dingbat's own layout;
# no other emulator implements MBC6 at all.
const MBC6_FOOTER_LEN = 0x100000 + 0x100 + 1

proc mbc6_footer(cart: Mbc6): string =
  result = newStringOfCap(MBC6_FOOTER_LEN)
  for b in cart.flash: result.add(char(b))
  for b in cart.flash_hidden: result.add(char(b))
  result.add(char(if cart.flash_sector0_protected: 1 else: 0))

proc mbc6_load_footer(cart: Mbc6; data: string) =
  let base = cart.ram.len
  # Exact length only, same reasoning as the RTC footers: nobody else writes
  # an MBC6 footer at all, so any other tail length is not this layout.
  if data.len - base != MBC6_FOOTER_LEN: return  # RAM-only save: keep blank flash
  for i in 0 ..< cart.flash.len: cart.flash[i] = uint8(data[base + i])
  for i in 0 ..< cart.flash_hidden.len:
    cart.flash_hidden[i] = uint8(data[base + cart.flash.len + i])
  cart.flash_sector0_protected =
    data[base + cart.flash.len + cart.flash_hidden.len] != '\0'

proc mbc_save*(cart: Mbc) =
  if cart.ram_dirty and cart.has_battery and cart.sav_path.len > 0 and cart.ram.len > 0:
    try:
      var data = cast[string](cart.ram)
      if cart of Mbc3 and Mbc3(cart).has_rtc:
        data.add(rtc_footer(Mbc3(cart)))
      elif cart of Huc3:
        data.add(huc3_footer(Huc3(cart)))
      elif cart of Tama5:
        data.add(tama5_footer(Tama5(cart)))
      elif cart of Mbc6:
        data.add(mbc6_footer(Mbc6(cart)))
      writeFile(cart.sav_path, data)
      cart.ram_dirty = false
    except IOError, OSError:
      if not cart.save_error_reported:
        cart.save_error_reported = true
        echo "Failed to write save file: ", cart.sav_path

proc mbc_load*(cart: Mbc) =
  if cart.has_battery and cart.sav_path.len > 0 and fileExists(cart.sav_path):
    let data = readFile(cart.sav_path)
    for i in 0 ..< min(data.len, cart.ram.len):
      cart.ram[i] = uint8(data[i])
    if cart of Mbc3 and Mbc3(cart).has_rtc:
      rtc_load_footer(Mbc3(cart), data)
    elif cart of Huc3:
      huc3_load_footer(Huc3(cart), data)
    elif cart of Tama5:
      tama5_load_footer(Tama5(cart), data)
    elif cart of Mbc6:
      mbc6_load_footer(Mbc6(cart), data)

proc gb_mixer_latency*(gb: GB): int32 {.inline.} =
  ## Dots this machine's write to a PALETTE register arrives at the mixer after
  ## the DMG's. The one reader of `CGB_MIXER_LATENCY` outside its own
  ## declaration, so the compile-time constant stays the C-class QUANTITY and
  ## the revision decides only whether it is charged.
  ##
  ## Here rather than beside gb_quirks_for, its natural neighbour, because the
  ## PPU files are INCLUDED below and Nim needs the declaration first.
  if gb.cgb_enabled and not gb.quirks.mixer_write_immediate:
    int32(CGB_MIXER_LATENCY)
  else:
    0'i32

proc gb_lcdc_mixer_latency*(gb: GB): int32 {.inline.} =
  ## The same dot for LCDC, which the mixer also reads -- and which CGB-D does
  ## NOT drop. Not revision-gated, and mealybug's two CGB reference sets are
  ## why: run every ROM that ships both a `_cgb_c` and a `_cgb_d` capture and
  ## the two sets disagree on the palette rows and agree on the LCDC ones.
  ##
  ##   ROM                        _cgb_c vs _cgb_d
  ##   ------------------------   ----------------------------------
  ##   m3_bgp_change              differ  (864 px)   <- palette
  ##   m3_bgp_change_sprites      differ  (716 px)   <- palette
  ##   m3_obp0_change             differ  (42 px)    <- palette
  ##   m3_lcdc_bg_en_change       IDENTICAL          <- LCDC
  ##   m3_lcdc_obj_en_change      IDENTICAL          <- LCDC
  ##
  ## A reference pair that is identical on two devices is hardware saying the
  ## behaviour did not change between them, so gating LCDC on the revision
  ## would be inventing a difference the captures deny. Measured: gating it
  ## anyway takes `m3_lcdc_bg_en_change` 23040 -> 22637 and
  ## `m3_lcdc_obj_en_change` 23040 -> 22980 on BOTH references at once, which
  ## is the signature of moving a stage no reference wanted moved.
  ##
  ## This is also what `CGB_LCDC_MIXER_LATENCY` was declared for. It sat unread
  ## while both stages shared `CGB_MIXER_LATENCY` -- the two constants are both
  ## 1, so nothing showed -- and the C/D split is the first thing that tells
  ## them apart.
  if gb.cgb_enabled: int32(CGB_LCDC_MIXER_LATENCY) else: 0'i32

# ==================== INCLUDES ====================
# Textual includes, not imports: the whole GB core compiles as this one
# module (a single C translation unit), so the files below share one
# namespace and the C compiler inlines across them without LTO — see
# notes/architecture.md. Ordering is mostly freed by the forward
# declarations interleaved below; the one hard constraint is noted at the
# CPU group.

# Cartridge mappers: base methods + factory + the flat-ROM window fast path
# (mbc/mbc), then one file per mapper overriding them
include mbc/mbc
include mbc/rom
include mbc/mbc1
include mbc/mbc2
include mbc/mbc3
include mbc/mbc5
include mbc/mbc7
include mbc/huc1
include mbc/huc3
include mbc/mmm01
include mbc/mbc6
include mbc/camera
include mbc/tama5
# Audio: the four PSG channels, then the mixer
include apu/abstract_channels
include apu/channel1
include apu/channel2
include apu/channel3
include apu/channel4
include apu
# Peripherals: interrupt controller, link port, timer, input
proc gb_sync_cgb_native*(gb: GB) {.inline.} =
  ## Recompute GB.cgb_native. Three inputs: the console, the cart header, and
  ## whether the boot ROM is still mapped — so this belongs after construction,
  ## after the FF50 unmap, and after a state load.
  gb.cgb_native = gb.cgb_enabled and
    (gb.cgb_flag != cgbNone or (gb.memory != nil and gb.memory.bootrom.len > 0))
include interrupts
include serial
include timer
include sgb
include joypad
# Video: shared PPU base + the two interchangeable renderers
# Forward declarations needed by ppu.nim (defined in memory.nim included later).
# hot_bus_inline is defined here rather than in memory.nim because the forward
# declarations below must carry the same pragma as their implementations: on
# non-clang targets it expands to `inline`, and Nim rejects an implementation
# whose pragmas the forward declaration lacks (the clang codegenDecl form
# happens to slip through, which is why only the gcc/mingw CI builds broke).
# The rationale for the pragma itself lives with mem_tick_bus in memory.nim.
when defined(clang):
  {.pragma: hot_bus_inline,
    codegenDecl: "__attribute__((always_inline)) inline $# $#$#".}
else:
  {.pragma: hot_bus_inline, inline.}
proc mem_tick_components*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true; ignore_speed = false) {.inline.}
proc mem_tick_bus*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true) {.hot_bus_inline.}
proc mem_tick_ppu*(mem: GbMemory; gb: GB; cycles: int; ignore_speed = false) {.hot_bus_inline.}
proc mem_dma_tick*(mem: GbMemory; gb: GB; cycles: int)
proc read_byte*(mem: GbMemory; gb: GB; idx: int): uint8
proc write_byte*(mem: GbMemory; gb: GB; idx: int; val: uint8)
include ppu
include scanline_ppu
include fifo_ppu
# Memory bus (mem_read/mem_write dispatch, DMA/HDMA, I/O registers)
include memory
# CPU decode/execute. One hard ordering constraint: cb_opcodes before
# opcodes — the 0xCB handler in opcodes.nim indexes the CB_PREFIXED const
# (built at compile time in cb_opcodes.nim), and a const cannot be
# forward-declared.
# Forward declarations needed by opcodes.nim (defined in cpu.nim included later)
proc cpu_memory_at_hl*(cpu: GbCpu; gb: GB): uint8
proc `cpu_memory_at_hl=`*(cpu: GbCpu; gb: GB; val: uint8)
proc cpu_inc_pc*(cpu: GbCpu)
proc cpu_halt*(cpu: GbCpu; gb: GB)
proc cpu_lock*(cpu: GbCpu)
include cb_opcodes
include opcodes
include cpu

# ==================== HARDWARE REVISION ====================

const GB_UNUSABLE_ZERO* = defined(gb_unusable_zero)
  ## Control arm: answer `$00` for `$FEA0..$FEFF` on every revision, the way
  ## dingbat did before the region was modelled at all.
  ##
  ## It exists because it is the arm that PROVES the revision axis is otherwise
  ## behaviour-neutral, and re-establishing that later is a two-run experiment.
  ## Measured 2026-08-10 on the full local runner: `-d:gb_unusable_zero` is
  ## byte-identical to the pre-revision tree (981 rows, 769 pass, gambatte
  ## 3850/5005, results.md identical but for its timestamp), and without it the
  ## only thing that moves anywhere is gambatte `oamdma` at 3850 -> 3876. So
  ## every row the revision work moved, the `$FEA0` model moved.

proc gb_quirks_for*(rev: GbRevision): GbQuirks =
  ## The whole revision -> behaviour table, in one place. A revision that names
  ## no flag here behaves exactly like the default machine; adding a revision
  ## therefore costs nothing until some test ROM proves it differs.
  GbQuirks(
    length_clock_any_nrx4: rev in {grCgb0, grCgbAB},
    mixer_write_immediate: rev in {grCgbD, grCgbE},
    scy_fetch_latch: rev in {grCgbD, grCgbE},
    unusable_region:
      if GB_UNUSABLE_ZERO: urZero
      else:
        case rev
        of grCgb0, grCgbAB, grCgbC: urRamMasked
        of grCgbD:                  urRamPlain
        of grCgbE, grAgb:           urNibbleEcho
        else:                       urZero,   # DMG / MGB / SGB / SGB2
  )

proc gb_boot_model_for*(rev: GbRevision): GbBootModel =
  ## Which boot-handoff table a revision uses. Many-to-one on purpose: mooneye
  ## ships one `boot_regs-` ROM per group of revisions that hand off the same
  ## registers, and this is that grouping.
  case rev
  of grDmg0:  bmDmg0
  of grDmgABC: bmDmgABC
  of grMgb:   bmMgb
  of grSgb:   bmSgb
  of grSgb2:  bmSgb2
  of grCgb0:  bmCgb0
  of grCgbAB, grCgbC, grCgbD, grCgbE: bmCgbABCDE
  of grAgb:   bmAgb

proc gb_set_revision*(gb: GB; rev: GbRevision) =
  ## The only way to change the machine's identity. Call before post_init:
  ## skip_boot reads boot_model, and the quirks are read from the first
  ## register write onward.
  gb.revision   = rev
  gb.boot_model = gb_boot_model_for(rev)
  gb.quirks     = gb_quirks_for(rev)

proc gb_revision_from_name*(name: string): (GbRevision, bool) =
  ## Parse a `--model=` / test-row token. Returns (revision, ok). Accepts the
  ## names the suites themselves use: mooneye's filename suffixes (`dmg0`,
  ## `mgb`, `S`, `A`, `cgb0`), AGE's device tokens and SameSuite's
  ## `-cgb0B` / `-cgbDE` style ranges. A range resolves to its HIGHEST member:
  ## the newest silicon that still shows the behaviour is the strongest claim
  ## the ROM makes, and it is what keeps a `-cgb0` / `-cgbB` pair (SameSuite
  ## ships both for CH3) resolving to two different revisions instead of
  ## collapsing onto grCgb0.
  case name.toLowerAscii()
  of "dmg0":                         (grDmg0, true)
  of "dmg", "dmga", "dmgb", "dmgc", "dmgabc", "dmgabcmgb": (grDmgABC, true)
  of "mgb":                          (grMgb, true)
  of "sgb", "s":                     (grSgb, true)
  of "sgb2":                         (grSgb2, true)
  of "cgb0":                         (grCgb0, true)
  of "cgb0b", "cgba", "cgbab", "cgbb": (grCgbAB, true)
  of "cgbc", "cgb0bc", "cgbbc":      (grCgbC, true)
  of "cgbd", "cgbcd":                (grCgbD, true)
  of "cgb", "cgbe", "cgbde", "cgbcde", "cgbabcde", "c": (grCgbE, true)
  of "agb", "ags", "a":              (grAgb, true)
  else:                              (grCgbE, false)

# ==================== NEW_GB + POST_INIT ====================

proc new_gb*(bootrom_path: string; rom_path: string; fifo: bool; headless: bool; run_bios: bool; force_cgb = false; force_dmg = false): GB =
  ## force_cgb runs a DMG-flagged cart in CGB mode (a DMG cart inserted in a
  ## Game Boy Color) — mooneye's misc/ tests assert that hardware's behavior.
  ## force_dmg is the other direction: run a CGB-flagged cart as a DMG. No
  ## real console does that, but gambatte's test suite selects the device from
  ## the *runner* (its `CGB_MODE` load flag), not the cart header, and most of
  ## its ROMs carry a CGB header while still shipping a `dmg08` expectation —
  ## so scoring the DMG half of that suite needs it (tests/dingbat_test.nim,
  ## --mode=gambatte). force_cgb wins if both are set.
  result = GB(
    bootrom_path: bootrom_path,
    rom_path:     rom_path,
    fifo:         fifo,
    headless:     headless,
    run_bios:     run_bios,
    sgb_requested: false,
  )
  result.cartridge = load_cartridge(rom_path)
  result.cheats = new_cheat_engine(cpGB)
  let cgb_byte = result.cartridge.rom[0x0143]
  result.cgb_flag = case cgb_byte
    of 0x80'u8: cgbSupport
    of 0xC0'u8: cgbExclusive
    else:       cgbNone
  # A boot ROM only implies CGB mode when it *is* a CGB boot ROM: the DMG one
  # is 256 bytes, the CGB one 0x900. Sizing it (rather than assuming CGB for
  # any boot ROM) lets a DMG boot ROM boot a DMG cart as a DMG.
  let cgb_bootrom = bootrom_path.len > 0 and run_bios and
                    fileExists(bootrom_path) and getFileSize(bootrom_path) > 0x100
  result.cgb_enabled = force_cgb or
    ((cgb_bootrom or result.cgb_flag != cgbNone) and not force_dmg)
  # Default revision, which fixes both the boot model and the quirk set. The
  # test harness may override this (via --model) before post_init to drive the
  # model-specific mooneye boot_regs/boot_div rows and SameSuite's
  # per-revision APU ROMs.
  #
  # CGB C and DMG ABC are not arbitrary: they are the revisions dingbat is
  # already scored against, and on the CGB side the tree now says so in three
  # places at once.
  #
  #  * The mealybug PPU references this tree scores are the `_cgb_c` set, and
  #    mealybug ships a `_cgb_d` set beside it that differs. `m3_bgp_change` is
  #    pixel-exact on `_cgb_c` at `CGB_MIXER_LATENCY = 1`, which is the value
  #    that ships -- so the pixel pipeline has been a C-class machine all
  #    along, and `quirks.mixer_write_immediate` is now where that is written
  #    down.
  #  * `cgb-acid-hell` picks its tile data off a `$FEA0` readback, dingbat is
  #    scored against the branch a C-class device takes, and
  #    `quirks.unusable_region` is now what takes it (see GbUnusableRegion).
  #  * docs/gb-derivations.md has said "every reference it is scored against is
  #    CPU CGB C" since before this axis existed.
  #
  # This default was `grCgbE` when the axis was introduced, on the strength of
  # SameSuite's `apu/README.md` ("CPU-CGB-E -- passes all tests"). That reading
  # does not survive contact with the pixel references above, and it never
  # bound anything: SameSuite's nine per-revision APU ROMs each carry their own
  # `--model=` token, so they never ran on the default in the first place. The
  # move from E to C changes no behaviour by itself -- both resolve to
  # `bmCgbABCDE` and to the same `length_clock_any_nrx4 = false` -- it only
  # stops the default from claiming to be a machine the tree does not model.
  # DMG: mooneye's `boot_regs-dmgABC` / `boot_div-dmgABCmgb` are green and
  # `stat_irq_blocking.s` reads "pass: DMG ABC, MGB, CGB, AGB, AGS / fail:
  # DMG 0".
  result.gb_set_revision(if result.cgb_enabled: grCgbC else: grDmgABC)
  result.rom_title = block:
    var s = ""
    for i in 0x0134 ..< 0x013F:
      let ch = result.cartridge.rom[i]
      if ch >= 0x20'u8 and ch <= 0x7E'u8: s.add(char(ch))
    s.strip()
  result.rom_size = 0x8000'u32 shl result.cartridge.rom[0x0148]
  result.ram_size = case result.cartridge.rom[0x0149]
    of 0x01: 0x0800
    of 0x02: 0x2000
    of 0x03: 0x2000 * 4
    of 0x04: 0x2000 * 16
    of 0x05: 0x2000 * 8
    else:    0

proc gb_skip_boot(gb: GB) =
  # IF reads 0xE1 at PC=0x100 on DMG and CGB (gambatte
  # display_startstate/irq): the boot ROM leaves a VBlank interrupt pending
  gb.interrupts.vblank_interrupt = true
  gb.cpu.skip_boot(gb)
  gb.memory.skip_boot(gb)
  gb.ppu.skip_boot(gb)
  gb.timer.skip_boot(gb)

proc handle_saves*(gb: GB) =
  ## Flush battery-backed cart RAM once per frame (when dirty) so progress
  ## isn't lost if the emulator exits without the game disabling cart RAM
  gb.scheduler.schedule_gb(70224, etSaves)
  gb.cartridge.mbc_save()

proc gb_dispatch(gb: GB): proc(kind: EventType) {.closure.} =
  # Non-owning capture: this closure is stored on the GB's scheduler, so an
  # owning capture would form a reference cycle back to the GB.
  let gb {.cursor.} = gb
  result = proc(kind: EventType) =
    case kind
    of etAPUFrameSeq:
      # Models the falling edge of the divider's APU tap. Free-running at the
      # tap's own period; a DIV write re-aims it (timer.nim).
      tick_frame_sequencer(gb.apu, gb)
      gb.scheduler.schedule(apu_div_period(gb), etAPUFrameSeq)
    of etAPUSample:    get_sample(gb.apu, gb)
    # The GB core no longer schedules per-waveform-period channel events --
    # each channel carries a next_step deadline advanced in closed form at the
    # points that can observe it (see gb/apu/channel1.nim). These arms stay
    # reachable only for a state saved by an older build, whose etAPUChannel*
    # events gb_apply_state drains into next_step before the first tick; if one
    # ever slips through, dropping it is strictly better than restarting a
    # 4-cycle event chain that nothing reads.
    of etAPUChannel1, etAPUChannel2, etAPUChannel3, etAPUChannel4: discard
    of etIME:
      # Stamp the cycle a delayed EI actually raises IME on, so the instruction
      # it lands inside can still see the IME it was fetched with (cpu_halt).
      # Only a false -> true transition is stamped: a second EI while IME is
      # already set changes nothing an instruction could observe.
      if not gb.cpu.ime:
        gb.cpu.ime = true
        gb.cpu.ime_set_cycle = gb.scheduler.cycles
    of etSaves:        gb.handle_saves()
    of etRtcSecond:
      if gb.cartridge of Mbc3: Mbc3(gb.cartridge).rtc_tick()
      elif gb.cartridge of Huc3: Huc3(gb.cartridge).huc3_rtc_tick()
      elif gb.cartridge of Tama5: Tama5(gb.cartridge).tama5_rtc_tick()
    of etCameraDone:
      if gb.cartridge of PocketCamera: PocketCamera(gb.cartridge).camera_done()
    else: discard

proc post_init*(gb: GB) =
  gb.scheduler  = new_scheduler()
  gb.interrupts = new_gb_interrupts()
  gb.apu        = new_gb_apu(gb, gb.headless)
  gb.joypad     = new_gb_joypad()
  if gb.fifo:
    let p = new_gb_fifo_ppu(gb)
    gb.ppu = p
    gb.fifo_ppu = p
  else:
    gb.ppu = new_gb_scanline_ppu(gb)
    gb.fifo_ppu = nil
  gb.timer  = new_gb_timer()
  gb.serial = new_gb_serial()
  gb.memory = new_gb_memory(gb)
  # Needs the memory: whether the boot ROM is mapped is one of its three inputs.
  gb_sync_cgb_native(gb)
  gb.cpu    = new_gb_cpu()
  # Super Game Boy. A cart that unlocks SGB functions and is NOT being run as
  # a CGB gets the adapter: the two are mutually exclusive on hardware (an SGB
  # has no CGB in it, and a CGB ignores the packet stream), so a CGB-flagged
  # cart that also carries the SGB flag runs as a CGB here, which is what
  # happens when you put one in a Game Boy Color.
  if gb.sgb_requested and not gb.cgb_enabled and sgb_unlocked(gb.cartridge.rom):
    gb.sgb = new_sgb_state()
    # The GB in an SGB reports itself through the boot handoff registers
    # (C = 0x14); a cart that probes for SGB that way has to see it.
    if gb.boot_model == bmDmgABC: gb.boot_model = bmSgb
    sgb_attach(gb)
  gb.scheduler.dispatch = gb_dispatch(gb)
  gb.cartridge.gb_ref = gb
  if gb.cartridge of Mbc3:
    let c = Mbc3(gb.cartridge)
    if c.has_rtc and not c.rtc_halted():
      c.rtc_schedule_full()
  elif gb.cartridge of Huc3:
    Huc3(gb.cartridge).huc3_rtc_schedule()
  elif gb.cartridge of Tama5:
    Tama5(gb.cartridge).tama5_rtc_schedule()
  gb.handle_saves()
  if gb.bootrom_path.len == 0 or not gb.run_bios:
    gb_skip_boot(gb)
  # Align the frame sequencer to the divider's phase. It models the falling
  # edge of DIV bit 4 (5 in double speed), so where it lands depends on tdiv,
  # which gb_skip_boot has just seeded per hardware model.
  gb.scheduler.clear(etAPUFrameSeq)
  gb.scheduler.schedule(apu_div_phase(gb.timer, gb), etAPUFrameSeq)

proc apply_cheats*(gb: GB) =
  ## Push every enabled RAM-write cheat into memory. Run once per frame.
  if gb.cheats == nil or gb.cheats.cheats.len == 0: return
  if gb.cheat_hooks.read8 == nil:    # build the capturing closures once
    let mem = gb.memory
    let gb {.cursor.} = gb   # non-owning: the closures live on gb.cheat_hooks
    gb.cheat_hooks = MemHooks(
      read8: proc(a: uint32): uint8 =
        read_byte(mem, gb, int(a and 0xFFFF)),
      read16: proc(a: uint32): uint16 =
        uint16(read_byte(mem, gb, int(a and 0xFFFF))) or
        (uint16(read_byte(mem, gb, int((a + 1) and 0xFFFF))) shl 8),
      read32: proc(a: uint32): uint32 =
        var v = 0'u32
        for i in 0u32 ..< 4u32:
          v = v or (uint32(read_byte(mem, gb, int((a + i) and 0xFFFF))) shl (i * 8))
        v,
      write8: proc(a: uint32; v: uint8) =
        # A GameShark code's SRAM bank rides bits 16-23 (parse_gb_gameshark).
        # An external-RAM target writes THAT bank's storage directly: going
        # through the MBC would need the bank latch flipped mid-frame, which
        # the game would observe. The MBC's own modular bank math reproduces
        # the hardware masking (a $91 code lands in bank 1 on any cart).
        let idx = int(a and 0xFFFF)
        let cart = gb.cartridge
        if idx in 0xA000..0xBFFF and cart != nil and cart.ram.len > 0:
          cart.ram[mbc_ram_bank_offset(cart, int((a shr 16) and 0xFF)) +
                   mbc_ram_offset(cart, idx)] = v
          cart.ram_dirty = true
        else:
          write_byte(mem, gb, idx, v),
      write16: proc(a: uint32; v: uint16) =
        write_byte(mem, gb, int(a and 0xFFFF), uint8(v))
        write_byte(mem, gb, int((a + 1) and 0xFFFF), uint8(v shr 8)),
      write32: proc(a: uint32; v: uint32) =
        for i in 0u32 ..< 4u32:
          write_byte(mem, gb, int((a + i) and 0xFFFF), uint8(v shr (i * 8))),
    )
  gb.cheats.apply_ram(gb.cheat_hooks)
  # A poke into IF or LCDC/STAT/LYC leaves something deferred and is not a CPU
  # M-cycle, so nothing else would apply it (see mem_flush_deferred).
  mem_flush_deferred(gb.memory, gb)

proc refresh_cheat_rom_patches*(gb: GB) =
  ## Apply (or re-apply) Game Genie ROM edits. Call at load and whenever the
  ## cheat set changes.
  if gb.cheats != nil:
    gb.cheats.apply_rom(gb.cartridge.rom)

proc step_frame*(gb: GB) =
  gb.apply_cheats()
  while not gb.ppu.frame:
    gb.cpu.tick(gb)
  gb.ppu.frame = false
  if gb.sgb != nil: sgb_frame_end(gb)
  gb.gb_rebase()

method run_until_frame*(gb: GB) = gb.step_frame()

method handle_input*(gb: GB; inp: Input; pressed: bool) {.base.} =
  gb.joypad.handle_input(gb, inp, pressed)

method toggle_sync*(gb: GB) =
  gb.apu.toggle_sync()

# Save-state visitor over every component above (also serves rewind/rollback)
include savestate
