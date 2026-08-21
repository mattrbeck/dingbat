# GB/GBC emulator main file
# All types are declared here; implementation files are `include`d.

import std/[bitops, os, strutils, times]
import ../common/[input, scheduler, emu, resampler, serialize, timestretch, cheats]
import ../common/lut_macros
when defined(test_harness):
  import ../common/test_output

const LY_BLIND_SCOPE* {.intdefine.} = 2
  ## Which LY advances open the LY=LYC comparator's blind window (the write-up
  ## is above `ly_advance_close` in ppu.nim): -1 none, 0 rendered line
  ## boundaries only, 1 also vblank line to vblank line, 2 also the mode 0 -> 1
  ## entry into vblank on line 144.
  ##
  ## Whole gambatte suite, one build per cell, against `main` at ab0d7d6 and
  ## with IRQ_SAMPLE_T = 16 throughout (its own 16 rows are in every cell):
  ##
  ##   scope   gambatte   vs main
  ##     -1      3871     +16 / -1
  ##      0      3885     +31 / -2
  ##      1      3887     +33 / -2   was shipping
  ##      2      3899     +57 / -14  <- ships
  ##
  ## ---- Why 2 ships now (2026-08-20) -----------------------------------------
  ##
  ## 2 used to be held back because the twelve rows it costs are all in `m1`,
  ## all a handover between the mode 1 source and something else at the top of
  ## line 144, and they read as placing that source and the vblank IF bit one
  ## M-cycle apart -- bucket 18 of docs/gb-failure-triage.md. Two measurements
  ## settle it in 2's favour:
  ##
  ##  * The overlap the twelve rows were read as reporting was NOT the mode-1
  ##    source against the vblank flag. It was `IF_READ_SAMPLE_T` -- a $FF0F
  ##    read seeing a bit that rose on its own M-cycle's last dot. With that
  ##    fixed the trade is unchanged at +24 / -12 (measured on both trees), so
  ##    the twelve are not evidence about the window at all.
  ##  * **SameBoy fails ten of the twelve too**, with dingbat's exact answers:
  ##    `m1irq_m2enable_lyc_{1,2}`, `m1irq_m2disable_lycdisable_{2,3}`,
  ##    `m2m1irq_ifw_2` and their `_ds` arms all want 1 and both emulators say
  ##    3. Only `lycint143_m1irq_late_retrigger_2` (two device rows) is a row
  ##    SameBoy gets right and this does not. So the block was a bucket nobody
  ##    in reach models, being paid for with 24 rows that are plainly the
  ##    comparator handover this window is about.
  ##
  ## On the tree this ships in: runner 1042 -> 1043, gambatte 4322 -> 4334,
  ## nothing outside `m1` and `lcdirq_precedence` moving in either direction.
# The STAT model's knobs, declared here rather than next to their write-up in
# gb/ppu.nim only because the GbPpu fields they gate are in the type block
# below. See ppu.nim for what they mean and for the ROMs that bracket each.
#
# STAT_IRQ_LEAD still ships at the value that needs no field and no branch, so
# the shipping build is exactly the tree without it.
# Where inside its own M-cycle a CPU read of $FF0F latches the byte, counted in
# T-cycles from the start of the M-cycle's PPU dots (so it is dots, and it
# scales with double speed). 4 is the M-cycle's end -- what this tree did before
# the constant existed -- and compiles the field, the store and the split tick
# out entirely. The write-up and the ROMs that bracket it are above `irq_read`
# in interrupts.nim; it is declared here only because the GbInterrupts field it
# gates is in the type block below.
const IF_READ_SAMPLE_T* {.intdefine.} = 2

const STAT_IRQ_LEAD* {.intdefine.} = 0
const STAT_LYC_LEAD* {.intdefine.} = 0
  ## The same lead as STAT_IRQ_LEAD, applied to the **LYC source alone** --
  ## the per-source split that STAT_M2_LEAD is for the OAM source. It exists
  ## because STAT_IRQ_LEAD moves three sources at once (LYC, mode 0, mode 1;
  ## the OAM pulse is on the flag clock and stays put either way), so it cannot
  ## answer a question about one of them, and `cgb-acid-hell` asks exactly that
  ## question: its halt is woken by the LYC source and nothing else, while the
  ## four mealybug `tile_sel` ROMs are woken by the OAM one.
  ##
  ## **It ships at 0, and the reason is a two-sided bracket, not caution.** See
  ## STAT_LYC_LEAD's write-up next to STAT_M2_LEAD in ppu.nim and the 2026-08-14
  ## entry in docs/gb-failure-triage.md.
const STAT_IRQ_SPLIT* = STAT_IRQ_LEAD != 0 or STAT_LYC_LEAD != 0
static:
  # The two share one early-advancing domain (irq_ly / irq_mode), so they cannot
  # ask for different amounts of lead at once. Either is free to be 0.
  doAssert STAT_IRQ_LEAD == 0 or STAT_LYC_LEAD == 0 or
           STAT_IRQ_LEAD == STAT_LYC_LEAD,
    "STAT_IRQ_LEAD and STAT_LYC_LEAD drive one domain: set one, or set both equal"
const STAT_DOMAIN_LEAD* = max(STAT_IRQ_LEAD, STAT_LYC_LEAD)

# Where the mode bits a CPU STAT read returns are sampled: a read whose M-cycle
# leaves the PPU dot counter at `cc` sees the mode the PPU changed to on dot X
# if and only if `cc - X >= STAT_READ_SAMPLE`, i.e. it samples dot
# `cc - STAT_READ_SAMPLE`. Bracketed on both sides by different ROMs at each
# speed; the derivation, the brackets and the sweep are at stat_read_mode.
const STAT_READ_SAMPLE*     {.intdefine.} = 2
# The extra dots in double speed, kept as an addend rather than a second
# absolute value so the read stays branchless: `T = SAMPLE + DS_ADD * speed`.
const STAT_READ_SAMPLE_DS_ADD* {.intdefine.} = 1

const STAT_M0_FIELD_TAIL* {.intdefine.} = 3
  ## Dots by which the STAT register's MODE FIELD keeps reading 3 after the PPU
  ## has internally entered mode 0, on a DMG, on a line with no object fetch --
  ## and only the field. The mode-0 STAT source, the HBlank DMA trigger, the
  ## VRAM/OAM unlock and the pixel pipeline all still turn on the PPU's own dot.
  ## Spent on `stat_chg_dot`, the field's own timestamp, and nothing else can
  ## see it. `STAT_M0_FIELD_TAIL_CGB` is the same thing on a CGB, and
  ## `STAT_M0_FIELD_TAIL_ABSORB` is what makes it survive.
  ##
  ## ---- The three-way split that derives it ---------------------------------
  ##
  ## Three sets of rows measure the SAME 3 -> 0 edge and they do not agree, and
  ## what separates them is (a) which observable they use and (b) whether their
  ## line carries an object. Every row below is object-classified by running it
  ## under `-d:gb_m3_len` and reading the `objx=` list (`tools/gbscx/hasobj.sh`),
  ## not by its family name:
  ##
  ##   observable   objects   rows                              says our edge is
  ##   interrupt    none      m0enable/disable_scx{1,2,3,5,7}   RIGHT
  ##   field        none      m2int_scx{2,3,5}_m3stat_1 [dmg]   3-4 dots EARLY
  ##   field        yes       sprites/*_m3stat_2 (63 rows)      RIGHT
  ##
  ## Rows 1 and 2 differ only in the observable, so the dots have to be paid at
  ## the FIELD -- an edge move is refused by `m0enable`, which is object-free and
  ## reads the interrupt (measured: `M3_END_EARLY = -1` is +41 / -138, with
  ## `m0enable` -24). Rows 2 and 3 differ only in the objects, so the field's
  ## payment has to be ABSORBED by an object fetch -- an unabsorbed field lag is
  ## refused by `sprites` (measured, round 2: `STAT_MODE0_LAG = 1` was
  ## +16 / -98, of which `sprites` was -63). Both halves are two-sided.
  ##
  ## ---- Where the number comes from -----------------------------------------
  ##
  ## Not fitted. `m2int_m3stat/scx/m2int_scxN_m3stat_{1,2}` brackets the edge to
  ## one M-cycle per residue with no mid-line store at all, and the STAT read
  ## samples at `cc - STAT_READ_SAMPLE`, so each pair is an inequality on the
  ## length. On DMG:
  ##
  ##   SCX   our len   our edge   hardware's edge   hardware's length
  ##    2      174       254       (255, 259]        (175, 179]
  ##    3      175       255       (255, 259]        (175, 179]
  ##    5      177       257       (259, 263]        (179, 183]
  ##
  ## Solving `172 + s + K` against all three leaves K = 3 or 4, and 3 is the
  ## value that survives the rest of the suite: swept whole-suite, 2 is
  ## +30 / -3, **3 is +46 / -6**, 4 is +57 / -27 -- a strict local maximum,
  ## bracketed from both sides.
  ##
  ## ---- What it buys, and the shape of the confirmation ---------------------
  ##
  ## gambatte 4004 -> 4044. Four of the gains are the rows the constant was
  ## derived from (`m2int_scx{2,3,5}_m3stat_1 [dmg]` and
  ## `enable_display/ly0_late_scx7_m3stat_scx3_1 [dmg]`). **The other 42 are
  ## `window`**, which was not used in the derivation at all and which moves
  ## +42 / -5. A third suite agrees independently: mooneye-wilbertpol's
  ## `intr_2_mode0_scx{1,2,3,5,6,7}_timing_nops` -- six rows, one per residue --
  ## all go from red to green.
  ##
  ## ---- The wall, and what got over it --------------------------------------
  ##
  ## Charged at the mode CHANGE (round 3's spelling) this is refused outright.
  ## GBMicrotest's `win{0..15}_{a,b}`, `win{0,10}_scx3_{a,b}` and
  ## `ppu_sprite0_scx{1,2,3,5,6,7}_{a,b}` are PAIRS bracketing the same field
  ## report to one M-cycle, both halves green on the pre-round-4 tree, and all
  ## 24 `_b` halves go red with `actual = 0x83` against `expected = 0x80`.
  ## Ledger then: gambatte +46 / -6, mooneye-wilbertpol +6 / -0, GBMicrotest
  ## +0 / -24, local runner 773 -> 755.
  ##
  ## What breaks the tie is that the three parties do not read STAT with the
  ## same INSTRUCTION -- see `STAT_M0_TAIL_MAX_MC`, which is why this term is
  ## charged at the read instead. With that gate the same K keeps every gain and
  ## loses nothing: **local runner 773 -> 779, gambatte 4004 -> 4044, and no row
  ## anywhere goes the other way.**
  ##
  ## ---- 2026-08-20: this term may be the OAM lead, one level down -----------
  ##
  ## The note below calls the DMG/CGB difference here "independently predicted
  ## by the `scx_m3_extend` brackets, which are themselves device-split by one
  ## M-cycle". That one M-cycle is now bracketed two-sided somewhere else, and
  ## on the other device: GBMicrotest's `oam_int_if_edge` sled says the DMG's
  ## OAM STAT source is one M-cycle late and the CGB's is exact (see
  ## `STAT_M2_LEAD` in ppu.nim). Move the DMG source onto the CGB's phase and
  ## THIS term wants 0 as well -- swept on f8811ba on top of that re-spelling,
  ## runner / gambatte:
  ##
  ##   K   -1     0     1     2     3 (ships)
  ##      1048  1048  1044  1042  1040
  ##      4410  4410  4370  4351  4344
  ##
  ## -1 and 0 are indistinguishable (nothing samples between them, the same
  ## ambiguity the "K = 3 or 4" solve below has), and 0 is the value the CGB
  ## already carries. So all three of the tree's DMG/CGB splits in this bucket
  ## -- this one, `STAT_M2_LEAD`/`_CGB`, and `M3_PIPE_AHEAD`/`CGB_PIPE_MCYCLES`
  ## -- collapse to one device-independent value at once, and no `[cgb]` row
  ## moves when they do.
  ##
  ## It is NOT flipped on its own: alone on the shipping tree 3 is still the
  ## strict local maximum the sweep below found. It only wants 0 in company.

const STAT_M0_FIELD_TAIL_CGB* {.intdefine.} = 0
  ## `STAT_M0_FIELD_TAIL` on a CGB. Zero is both the shipping value and the
  ## derived one -- read the note below as "if the DMG term is ever paid, the
  ## CGB's is still zero". It is ZERO: the CGB's mode field owes
  ## nothing. Bracketed from above rather than assumed -- at 1 the whole
  ## `m2int_m3stat` ladder's `_2` members go red on CGB and the suite reads
  ## 4015 against 4044, and at 2 it reads 3979. That the two devices differ here
  ## is independently predicted by the `scx_m3_extend` brackets, which are
  ## themselves device-split by one M-cycle ((269, 273] on DMG against
  ## (265, 269] on CGB).

const STAT_M0_TAIL_MAX_MC* {.intdefine.} = 2
  ## The last M-cycle OF ITS OWN INSTRUCTION on which an IO read still sees the
  ## `STAT_M0_FIELD_TAIL`. 0 disables the gate entirely (every read sees the
  ## tail, which is round 3's spelling); 2 ships.
  ##
  ## An SM83 IO read happens on a different M-cycle of its instruction
  ## depending on the addressing form, and the reads in these suites are:
  ##
  ##   LD A,(C)     F2        2 M-cycles, IO on M2
  ##   LD A,(HL)    7E        2 M-cycles, IO on M2
  ##   LDH A,(n)    F0 nn     3 M-cycles, IO on M3
  ##   LD A,(nn)    FA nn nn  4 M-cycles, IO on M4
  ##
  ## Round 4's hypothesis, and it is a hypothesis about the ROMS before it is
  ## one about hardware. The three suites that disagree about the field report
  ## do not read it with the same instruction (`tools/gbscx/readidiom.py`):
  ##
  ##   party                        idiom          IO cycle   wants the tail?
  ##   GBMicrotest win*_{a,b} etc   LDH A,($41)    M3 of 3    NO  (24 rows)
  ##   gambatte m3stat/window       LD A,(C)       M2 of 2    YES (45 rows)
  ##   mooneye-wilbertpol intr_2_*  LD A,(HL)      M2 of 2    YES (6 rows)
  ##
  ## The correlation is exact ACROSS the parties, which is what makes it worth
  ## building rather than dismissing -- and it holds up: at 2 the field tail
  ## keeps all 45 gambatte gains and all 6 wilbertpol gains AND leaves every one
  ## of GBMicrotest's 24 `LDH` rows green.
  ##
  ## Bracketed from both sides on the structural quantity rather than on an
  ## opcode list. Local runner: 1 is 773 (nothing sees the tail, the mechanism
  ## is off), **2 is 779**, 3 is 755 and 4 is 755 -- 3 is where `LDH A,(n)`
  ## starts seeing it and where GBMicrotest's 24 rows go red. So the boundary
  ## sits strictly between an IO read on its instruction's second M-cycle and
  ## one on its third, which is the whole claim.

const STAT_M0_FIELD_TAIL_ABSORB* {.booldefine.} = true
  ## Whether an object fetch ABSORBS the field's tail: the lag becomes
  ## `max(0, tail - the object dots charged on this line)`. `false` is the
  ## round-2 spelling, which is refused by `sprites` at every value.
  ##
  ## The absorption is specifically by OBJECTS and not by "whatever made mode 3
  ## longer", and that was measured rather than assumed: absorbing by the whole
  ## excess over `172 + SCX and 7` -- which also counts the window's penalty --
  ## scores **4008** against 4044 and gives back all 42 `window` rows. Only the
  ## object fetch drains this tail, which is the same thing `MIXER_TAIL_DOTS`
  ## records about the mixer's tail one stage upstream.

const STAT_MODE3_LAG* {.intdefine.} = 0
  ## Dots by which the STAT mode field keeps reading 2 after the PPU has
  ## entered mode 3. Device-independent, and it has to stay 0:
  ## `m2int_m2stat/m2int_{,scx4_}m2stat_ds_2` read STAT expecting mode 3
  ## immediately after that edge and refuse any positive value (+1 / -4).

const STAT_MODE3_LAG_CGB* {.intdefine.} = 0
  ## Dots added to `STAT_MODE3_LAG` on a CGB only, meant to be NEGATIVE: the
  ## CGB reporting mode 3 EARLIER than its own mode-3 dot.
  ##
  ## The witness is `halt/lycirq_m2stat_2`, whose filename splits the devices
  ## outright (`dmg08_out2_cgb04c_out3`): out of the same halt wake, same line,
  ## same dot, a DMG reads mode 2 and a CGB reads mode 3, and dingbat reads 2 on
  ## both. At -1 that row goes green and `speedchange` gains two.
  ##
  ## **Refused, and the object split does not rescue it.** Five rows on the same
  ## device read the same edge and want it where it is
  ## (`m2int_m2stat/m2int_m2stat_1`, `sprites/10spritesPrLine_m2stat_1`,
  ## `ly0/lycint152_m2stat_1`, `enable_display/nextstat_1`,
  ## `enable_display/frame{0,1}_m3stat_count_1`), net +3 / -6. Round 3 asked
  ## whether the object-absorption above separates them and it does not:
  ## `m2int_m2stat_1` is object-FREE (`hasobj.sh`, 0 object lines) and refuses
  ## anyway, so no rule keyed on objects can hold it still while moving
  ## `lycirq_m2stat_2`, which is object-free too.

# True when any field tail is actually set. The object accumulator below and
# the whole absorption path hang off this and not off
# STAT_M0_FIELD_TAIL_ABSORB, so a default build carries neither the field nor
# the add in the object-fetch path -- the object-layout cliff `win_lx` and
# `win_hold` record is real and a disabled mechanism must not pay it.
const STAT_M0_TAIL_ANY* = STAT_M0_FIELD_TAIL != 0 or STAT_M0_FIELD_TAIL_CGB != 0

const STAT_MODE_LAG_ANY* = STAT_M0_TAIL_ANY or
                           STAT_MODE3_LAG != 0 or STAT_MODE3_LAG_CGB != 0

# `stat_chg_dot` for "no mode change is inside any read's sampling window".
# A line is 456 dots and the counter is rebased at every wrap, so anything this
# far back can never come within STAT_READ_SAMPLE of the counter again.
const STAT_NO_HOLD* = -1024'i32

# Fixed setup cost of a CGB general-purpose VRAM DMA, in CPU M-cycles, charged
# once per transfer on top of the 8 M-cycles per $10 bytes Pan Docs specifies
# for the blocks themselves (see ppu_start_hdma).
#
# **It ships at 0, and the point of the knob is to record that no value works.**
#
# gambatte's gdma_cycles_* family says dingbat is short here. Each pair differs
# by a single inserted NOP ahead of `LDH A,($41)` -- cmp -l of
# gdma_cycles_long_1 against _2 is a one-byte $00 insertion -- so the two
# members read STAT one M-cycle apart, and their expected values, 3 then 0, put
# the mode 3 -> 0 edge between them. dingbat answers 3 to BOTH members of all
# nine pairs, i.e. it reaches the read short of where the hardware is.
#
# A fixed setup cost is the obvious explanation and it is WRONG.
# tools/gbdiff/gdma_sweep.sh rebuilds at each setting and reads out all nine
# pairs; the whole family is 18 rows, and every setting leaves some of them
# failing:
#
#     0  9/18   every `_2` member short
#     1  9/18   unchanged -- one M-cycle does not reach any flip point
#     2  13/18  best, and still contradictory: long_scx{2,3,5}_2 are STILL
#                short, while 2xshort_ds_1 and 2xshort_scx5_ds_1 have already
#                gone PAST their edge and now answer 0 where 3 is wanted
#     3  12/18  the `_1` members break widely
#     4+ 9/18   every `_1` member past its edge
#
# There is no value where every pair sits on the right side of its own flip
# point, and at the best one the residual tracks SCX: long_scx2_2, long_scx3_2
# and long_scx5_2 want more than plain long_2 does. A constant cannot depend on
# SCX, so the missing time is not setup -- it is something about where the
# transfer leaves the PPU relative to the mode 3 -> 0 edge, and SCX moves that
# edge. Settling it needs a model, not a number, so nothing is charged until
# there is one. Turning this up to 2 would buy 4 net rows by breaking 2 that
# pass today; that is fitting, not measuring.
const GDMA_SETUP_MCYCLES* {.intdefine.} = 0

# How long an HBlank DMA block's BYTES take to appear in VRAM after its last one
# is transferred, in DOTS. Only the data moves: the 8 M-cycles per $10 bytes are
# charged where they always were, and so are the address counters and the FF55
# length the CPU reads back. This is therefore neither GDMA_SETUP_MCYCLES (time
# charged after the copy loop, which cannot move when bytes appear) nor a delay
# on the block itself -- deferring the whole block is measured and refused
# below. Held bytes are landed lazily, at the points VRAM can be observed; see
# ppu_land_hdma_if_due for that and for what it costs.
#
# **Where the ROMs put it.** gambatte's 14 `hdma_start` rows are the only ones in
# the suite that read the transferred DATA. Each `_1` and its `_2` partner differ
# by one inserted NOP ahead of the `LD A,(HL)` that reads the destination
# (`cmp -l hdma_start_1 hdma_start_2` is a one-byte $00 insertion at $1033), so
# each pair samples it one M-cycle apart, and the expected values -- 0 then 1 --
# bracket the arrival between the two reads. `-d:gb_dma_trace` prints each ROM's
# HDMABLOCK dot next to its VRAMRD dot, which turns the family into seven
# inequalities on one number; they intersect at exactly one value:
#
#   ROM              block at   read answered on   byte visible?
#   hdma_start_1        252            285              no      -> K > 33
#   hdma_start_2        252            289              yes     -> K <= 37
#   hdma_start_ds_1     252            287              no      -> K > 35
#   hdma_start_ds_2     252            289              yes     -> K <= 37
#   hdma_start_scx5_2   257            293              yes     -> K <= 36
#   hdma_start_scx5_ds_1 257           291              no      -> K > 34
#   hdma_start_scx5_ds_2 257           293              yes     -> K <= 36
#
# K is dots from the START of the block, and a block is 32 dots long at either
# speed, so K = 36 is this constant at 4. Swept anyway, whole suite rebuilt per
# value (tools/gbppu/gamall.sh, `hdma_start` rows / gambatte total):
#
#     0   7/14   4131   every `_1` member sees the byte early
#     2   9/14   4133
#     3  11/14   4135   `_ds_1` and `_scx2_1` still early
#     4  13/14   4137   <- ships
#     5  11/14   4135   the `_2` members start going short
#     6   8/14   4132
#     8   6/14   4130   every `_2` member short -- worse than not modelling it
#
# A strict two-sided maximum. **Dots and not bus M-cycles**: the two are the same
# thing only at normal speed and only when a block starts on an M-cycle boundary,
# and `hdma_start_ds_1` (double speed, where an M-cycle is 2 dots) and
# `hdma_start_scx5_2` (a block starting 1 dot into its M-cycle) are the rows that
# separate them -- an M-cycle-counting version of this same fix scores 4135 and
# misses one of the two whichever way it rounds. The transfer being dot-clocked
# is the same thing `ignore_speed` says in ppu_copy_hdma_block.
#
# The one row left is `hdma_start_scx5_1`, and it is not this: it reads VRAM 4
# dots BEFORE the block, gets $FF where hardware gets a byte, and so is refused
# by the mode-3 lock rather than answered early. That is the SCX residual on the
# mode 3 -> 0 edge (bucket 15 of docs/gb-failure-triage.md) seen through this
# family, and no setting of a visibility delay can reach it.
#
# **Why the bytes and not the block.** Delaying the block itself by one M-cycle
# (the copy, its dots and its register writes together) was tried first and the
# neighbours refuse it: gambatte goes 4131 -> 4126, with `hdma_late_disable_2`,
# `_scx2_2` and `_scx3_2` breaking and the whole `hdma_late_m3speedchange_*`
# ladder sliding one step. Those rows read FF55, LY and TIMA rather than the
# destination, so they time the block's BUS OCCUPANCY, and they say it starts
# exactly where it does today.
#
# The read that sees the old bytes is inside the block's own dots -- the copy
# ticks the PPU 8 M-cycles while the CPU access that triggered it is still in
# flight -- which is also why that access finds VRAM unlocked even though its
# M-cycle began in mode 3: by the time its strobe lands, mode 0 is 8 M-cycles
# old. Both halves are the same picture of a stretched CPU cycle, which is why
# the hold is only taken for a block the mode-0 edge starts (`in_cpu_cycle`).
# Extending it to the blocks an FF55 write starts costs `hdma_disabled_display_1`
# and gains nothing: that write's own byte has already committed, so there is no
# access in flight for the hold to protect.
# HDMA_VISIBLE_DOTS is declared further down, next to CGB_HALT_PPU_LEAD, whose
# value it carries a term of -- a const cannot be read before it is declared.

# ---- The serial shift clock's tap offset, per device -------------------------
#
# The serial unit watches a bit of (divider + tap); its falling edge TOGGLES the
# half-rate shift clock, and every second toggle shifts a bit (serial.nim). The
# tap exists because the serial unit's copy of the divider sits a few T-cycles
# ahead of the value a DIV read returns, so it is a phase, in T-cycles, on a
# free-running counter -- not a countdown started by SC.
#
# Raising the tap makes every edge land EARLIER in real time (the sum reaches
# the bit boundary sooner); lowering it makes them land later.
# **A two-sided contradiction, quarantined at the DMG value gambatte refuses.**
#
# Swept against the 82-row gambatte `serial` bucket, whole suite rebuilt per
# value, BOTH taps moved together (the DMG-only column, CGB held at 2, is
# 4 -> 53 and 2 -> 58, so each SoC contributes its own half of the step):
#
#   SERIAL_TAP       -8  -4  -2 | 0   1   2   3 | 4   5   6 | 8   12
#   serial rows      48  46  46 | 58  58  58  58| 46  46  46| 48  46
#
# so gambatte puts both taps in [0,3]: a strict local maximum bracketed on BOTH
# sides, with no collateral row in any of the other 46 buckets. The plateau is
# exactly 4 T wide, which is what says the tap is a phase quantised to the
# M-cycle and not a duration.
#
# Only FIVE of those rows are really the tap's: `div_write_start_wait_read_if_1`,
# its `nopx1` arm and `start_late_div_write_wait_read_if_{1a,2a,3a}`, all DMG.
# They reset DIV immediately before the transfer, so they are the only ones in
# the bucket that see the tap without the boot seed. Everything else in the
# step is CGB-side arithmetic on the same phase.
#
# **`mooneye/acceptance/serial/boot_sclk_align-dmgABCmgb` refuses [0,3] and pins
# 4.** It is hardware-verified on DMG/MGB, so it wins and the tap ships at 4 --
# those five gambatte rows stay red deliberately, and flipping the default is a
# suite-wide call (the local runner is not a superset of the shootout).
#
# The two cannot be reconciled by re-partitioning the tap against the boot
# divider seed. `boot_div-dmgABCmgb` reads DIV, which is `tdiv shr 8`, so it
# cannot see a 4 T change in the seed at all -- but the gbmicrotest
# `timer_tima_phase_*` set, gambatte `div` and parts of `sound`/`tima` can, and
# do: 0xABC8 -> 0xABCC lands boot_sclk_align at tap 2 and takes thirteen of
# those rows down. Measured, not assumed.
#
# What DOES reconcile them is one M-cycle on the READ side of the bus, not
# anything in this constant -- see the `start_wait_*` block below, which needs
# the same change for its own 24 rows.
const SERIAL_TAP_DMG* {.intdefine.} = 4
const SERIAL_TAP_CGB* {.intdefine.} = 2

# ---- The residual `start_wait_*` cluster, and what it actually needs ---------
#
# Twenty-four rows (`start_wait_read_if`, `_read_sb`, `_read_sc`,
# `start_wait_clear_if_read_if`, `_restart`, `_sc80`, `_stop`, the `nopx*` arms
# and their `_ds` siblings) report the SAME defect through three registers: at
# family step 1 hardware has done seven shifts and dingbat has done eight.
# `_read_sb` is the clearest -- SB seeds at $00 and shifts in ones, so
# `exp=7F got=FF` counts the shifts directly -- and `_read_sc` (SC.7 still set)
# and `_read_if` flip on the same M-cycle. All three observables move together,
# so it is the eighth shift EDGE that is early, not the interrupt.
#
# **These rows cannot be moved by anything on the serial side, and the algebra
# says so exactly.** Every one of them starts its measured transfer from inside
# the serial handler of a PREVIOUS transfer, so the boot divider seed and the
# tap both cancel: the whole verdict is a function of Delta, the T-cycles from
# transfer 1's eighth shift edge to transfer 2's SC write. Writing `a_r` for
# where inside its own M-cycle a CPU READ samples the divider (dingbat charges
# the M-cycle first, so a_r = 4) and `m` for how far the dispatch boundary sits
# past the shift edge, the observable comes out as
#
#     (transfer 2's completion) - (the IF/SB/SC read) = 4 - m - a_r
#
# and the ROMs need that in (0, 4]. `m = (tap mod 4)` is in [0,3] because the
# dispatch is the first instruction boundary at or after the edge, so **no tap
# reaches these rows** -- confirmed by sweep, they do not move at any tap in
# [-8, 8]. Nor does leading the serial IF: the same lead moves transfer 2's IF
# observable by the same amount and cancels itself out (it would land `_read_sb`
# and `_read_sc` while leaving `_read_if` exactly where it was, and the family
# has all three). Nor does moving where SC.7's write reseeds the shift clock
# inside its own M-cycle: that is a 256 T jump inside a 4 T window of divider
# phase, and none of these ROMs sits in that window.
#
# What IS left is `a_r`, and it wants 0 -- a read sampling the divider at the
# TOP of its M-cycle rather than after it. Two independent checks agree:
#
#  * `div_write_start_wait_*` and `start_late_div_write_*` reset DIV just
#    before the transfer, so the seed cancels and they pin `tap + (a_r - a_w)`
#    (a_w = the write's own offset, 4 here) to [0,3]. At a_r = 4 that is
#    tap in [0,3]; at a_r = 0 it is tap in [4,7].
#  * mooneye `boot_sclk_align-dmgABCmgb` never writes DIV, so it sees the boot
#    seed and pins the tap alone -- to [4,7].
#
# So at a_r = 4 those two contradict each other by exactly one M-cycle (the
# disagreement this file has carried since the tap was first swept, and why
# SERIAL_TAP_DMG ships at 4 and five gambatte rows stay red), and at a_r = 0
# they AGREE, at the tap that already ships. One change, three families: the
# `start_wait` cluster, the `div_write` cluster and boot_sclk_align all land
# together, and nothing else in the serial family is sensitive to it.
#
# It is not taken here because it is not a serial change: `mem_read` charges
# the whole M-cycle to bus and PPU alike before returning a byte
# (`mem_tick_components(mem, gb, 4)`), and moving the bus half after the read
# re-times every IF, DIV, TIMA, LY and STAT read in the emulator. That is a
# memory.nim question with the `tima`, `halt` and `irq_precedence` families on
# the other side of it, and it wants its own round.
#
# Refuted alongside, so they are not re-run: the DMG boot seed cannot absorb
# the tap disagreement either -- 0xABC8 -> 0xABCC does land boot_sclk_align at
# tap 2, and costs nine gbmicrotest `timer_tima_phase` rows, all of gambatte
# `div`, two `sound` and one `tima`.

# ---- The M-cycle a CGB spends leaving HALT that a DMG does not ---------------
#
# Charged once, on the M-cycle the pending interrupt is seen, before the CPU is
# back on the bus -- so ahead of an HBlank DMA block that came due while it
# slept, and ahead of any dispatch. DMG is the zero of this scale; only the
# delta would be modelled.
#
# **It ships at 0, and the point of the knob is to record what one M-cycle buys
# and what refuses it.** Both halves are large and neither is ignorable.
#
# What ASKS for it. gambatte names a different expected value per device in the
# file name of ten `halt/` ROMs, and every one of the ten is a read taken a
# fixed number of M-cycles after a halt an interrupt ended:
#
#   m0{int,irq}_m0stat_scx{3,4}_2                     DMG 0 (mode 0)  CGB 2
#   late_m0int_halt_m0stat_scx3_{1b,3b,4b}            DMG 0           CGB 2
#   late_m0irq_halt_m0stat_scx3_1b                    DMG 0           CGB 2
#   lycirq_m2stat_2                                   DMG 2 (mode 2)  CGB 3
#   m1int_ly_2                                        DMG $90 (144)   CGB $91
#
# All ten say the same thing in the same direction -- the CGB's read lands LATER
# in the PPU's line than the DMG's, by enough to cross the next boundary and by
# no more than that -- and they say it across three unrelated boundaries: mode 0
# -> 2 (the line end), mode 2 -> 3 (dot 80) and LY 144 -> 145. dingbat answers
# the DMG value on the CGB arm of all ten, and the DMG arm of all ten passes at
# both settings, so the DMG side is pinned and this is purely the difference
# from it. At 1 all ten flip green, and so do three CGB-only `_ds_` members
# (`m0{int,irq}_m0stat_scx{2,3}_ds_2`) and eight `dma/hdma_late_*` rows: 22
# gambatte rows in.
#
# What REFUSES it, and this is the larger half: 60 rows out, for a net of -37
# gambatte and -3 in the whole runner (743 -> 740, measured, one full pass per
# setting). Two disjoint groups:
#
#   * 42 `tima/*` rows, all with ONE expected value for both devices. They halt,
#     a timer interrupt wakes them and they read TIMA or IF a fixed number of
#     M-cycles later. An extra M-cycle at the exit is extra TIME, so DIV and
#     TIMA advance through it too, and hardware says they do not. That is not a
#     bracket that can be argued with: whatever the CGB is doing here, it is
#     not spending an M-cycle.
#   * 11 rows that are the SAME family as the ten above at a different SCX --
#     `m0{int,irq}_m0stat_scx{2,5}_1`, `late_m0{int,irq}_halt_m0stat_scx2_*`,
#     `noime_m2irq_m0stat_1`, and 7 `dma/hdma_late_disable_*`. Their SCX 3 and 4
#     siblings want the M-cycle and their SCX 2 and 5 siblings refuse it, on the
#     same ladder of one-NOP-apart reads. A halt cost cannot depend on SCX, so
#     part of what the ten measure is really the CGB's mode 3 length against
#     SCX (bucket: gambatte scx_during_m3, 49/141) and not this at all.
#
# So the CGB is later than the DMG out of a halt in a way that costs no time.
# That shape is a CPU-to-PPU PHASE offset, not a charge -- see the lcd_offset
# note at mem_tick_ppu_latched, which is where this belongs and where a whole
# M-cycle of it is refused by the same SCX ladder. Nothing ships until the SCX
# half is separated out; turning this to 1 would buy 22 rows by breaking 60.
#
# **That phase was built and measured on 2026-08-10: it is CGB_HALT_PPU_LEAD
# below.** It keeps all 42 `tima/*` rows (no time is spent anywhere), the
# quantity is bracketed to exactly one M-cycle from both sides by two clean
# `halt/` families, and the SCX ladder above is 10 of the 17 rows it still
# costs. It also ships at 0, and for one row rather than sixty. Read that
# constant, not this one, for where the measurement now stands.
#
# daid's `ppu_scanline_bgp.gb` on CGB is the frame that raised the question and
# it is worth stating what it does and does not pin. Its whole picture is ONE
# phase, set by an LYC=0 STAT interrupt that finds the CPU halted in the VBlank
# handler's `ei / halt`, and against the shootout's `ppu_scanline_bgp.gbc.png`
# every band of it is 3 pixels early. Exactly one M-cycle here plus exactly one
# dot of the CGB-C -> CGB-D palette step (CGB_MIXER_LATENCY, which is 1 for the
# `_cgb_c` references this tree scores and 0 for the `_cgb_d` ones daid's
# capture matches) accounts for all three, pixel for pixel -- but the same
# M-cycle is what the 60 rows above refuse, and the palette step is what 27
# mealybug CGB rows refuse. See docs/gb-failure-triage.md for the decomposition.
const CGB_HALT_EXIT_MCYCLES* {.intdefine.} = 0
const CGB_HALT_LEAD_LYC_ONLY* {.intdefine.} = 0
  ## EXPERIMENT. Restrict CGB_HALT_PPU_LEAD to halts where the LYC comparator is
  ## the only armed STAT source. 0 ships; see the test it gates in cpu.nim.
const CGB_HALT_LEAD_SKIP_LYC0* {.intdefine.} = 1
  ## Whether a halt that the LY 153 -> 0 snapback's `LYC = 0` match will wake is
  ## exempt from CGB_HALT_PPU_LEAD below. 1 ships (and is inert while the lead
  ## is 0); 0 is the control build, i.e. the lead applied to every wake alike.
  ## The derivation -- a LYC sweep of daid's `ppu_scanline_bgp` against SameBoy,
  ## same ROM and same entry with only the wake line changing -- is at the test
  ## in cpu.nim, next to the code it gates.
const CGB_HALT_PPU_LEAD* {.intdefine.} = 1
  ## The same M-cycle as CGB_HALT_EXIT_MCYCLES above, spent as PHASE instead of
  ## as time -- which is the shape the two halves of that measurement demand.
  ##
  ## ---- 2026-08-18: ON, with the snapback exempt ------------------------------
  ##
  ## It took three passes to get here and the middle one was wrong, so both the
  ## result and the correction are worth having.
  ##
  ## Turning it on flat takes `cgb-acid-hell` to 0 px and `daid/ppu_scanline_bgp`
  ## "(GBC)" from 0 px to **2304** at every one of the six CGB revisions. That
  ## row is a silicon reference the GBEmulatorShootout scores and this tree did
  ## not gate, so the first attempt passed a clean local suite and still broke
  ## it. It is wired now (`daid/ppu_scanline_bgp-gbc`).
  ##
  ## The two ROMs are not actually in conflict. daid's is the ideal instrument
  ## for saying so: 91 lines of source, ONE STAT LYC interrupt out of `halt`,
  ## then a 114-M loop of BGP writes that stays scanline-locked for the frame.
  ## Rebuilt byte-exact and swept over the LYC value ALONE -- same ROM, same
  ## entry in VBlank, same IME, same vector, only the line the wake lands on
  ## changing -- against SameBoy in CGB compatibility mode, which reproduces
  ## daid's own reference pixel-exactly:
  ##
  ##   LYC = 0  (the LY 153 -> 0 snapback)   without the lead exact, with it 2304 px
  ##   LYC = 1, 8, 40, 100 (normal lines)    WITH the lead exact, without it 1920-2304
  ##
  ## So the M-cycle is real on every normal-line wake and absent on the
  ## snapback, and `cgb-acid-hell`'s disputed pixels are on lines 68 and 69 --
  ## normal lines. See CGB_HALT_LEAD_SKIP_LYC0, which is the gate that falls out
  ## of it, and tools/gbppu/daidsweep.py, which is the sweep.
  ##
  ## Refuted on the way, so nobody re-runs them: it is NOT IME or whether a
  ## vector is taken (acid-hell continues inline after `halt`, IME 0, no vector;
  ## daid's handler IS entered -- and the LYC sweep above holds both constant
  ## while separating the cases), and NOT LY0_PIPE_MCYCLES (0/2/3 against the
  ## lead, daid unmoved at 2304).
  ##
  ## **Confirmed by the shootout itself, not just by this tree: 261 scored, 261
  ## PASS, 0 FAIL** (2026-08-18, `main.py --emulator dingbat`).
  ##
  ## ---- What turning it on COSTS ----------------------------------------------
  ##
  ## The block in `cpu_halt_tick` no longer compiles out, so every HALT-idling
  ## title pays for it -- including DMG ones, which pay the `cgb_enabled` test
  ## and nothing else. Measured here, retired instructions, min of 3, on
  ## `cgb-acid-hell` (144 halts per frame, i.e. about the worst case there is):
  ## **6.0804 G -> 6.1610 G, +1.33%**. The numbers in the ordering note further
  ## down are the ones for real titles and are smaller (+0.44% Pokemon Blue,
  ## +0.56..0.77% Crystal). If that ever needs paying back, the shape is to
  ## decide at halt ENTRY rather than per halted M-cycle -- the debt field is
  ## already the per-halt latch, so what is left on the inner path is one bool
  ## test that a two-loop entry split would remove.
  ##
  ## Ledger: runner 885 -> 887, gambatte 4201 -> 4246, and `cgb-acid-hell`,
  ## both `strikethrough` frames and both `daid/ppu_scanline_bgp` frames are all
  ## 23040/23040. Every one of the shootout's 260 ROMs was rendered under the
  ## old and new builds in both device modes: the ONLY one whose frame moves is
  ## cgb-acid-hell. What is still red and unexplained: gambatte `dma` -7 (seven
  ## `hdma_late_disable_*`), `lcd_offset` -6 and `window` -1, against +54
  ## elsewhere, most of it bucket 13's speed-switch model, whose defaults are
  ## tied to this knob and which lands with it.
  ##
  ## ---- The measurement that started it ---------------------------------------
  ##
  ## Until 2026-08-18 the only thing pointed at this quantity was
  ## `strikethrough-cgb` going 7 pixels wrong under it, with no ROM measuring it
  ## from the other side. There is now a measurement, and separately that
  ## strikethrough objection turns out not to have been one.
  ##
  ## `cgb-acid-hell` measures it, and does so on the ROM's own source rather
  ## than by knob-fitting. The ROM is fully unrolled -- one block per scanline,
  ## each anchored by its own `halt` on the STAT LYC interrupt, then 16 LCDC
  ## writes two M-cycles apart -- so a byte-preserving delay can be inserted in
  ## every block and the frame re-read (tools/gbppu/hellsrc.py, and the source
  ## is rebuilt byte-exact: md5 cdf25d29ff8504d28a87bb8d20f7f698). Delay every
  ## line's writes by exactly ONE M-cycle and dingbat reproduces SameBoy's
  ## undelayed frame on all 144 lines, 23040/23040 pixels, where undelayed it is
  ## 2 pixels out. The residual was never a glitch rule, a window or an object:
  ## it is this M-cycle, invisible on 142 of the 144 lines only because the
  ## ROM's writes sit on an 8-dot lattice and the phase is 4 dots.
  ##
  ## And `strikethrough` was never refuting it. See OBJ_DMA_BUS_LEAD in
  ## fifo_ppu.nim: that frame witnesses the SUM of the pipeline's advance and
  ## the object fetch's lead over the OAM DMA unit's bus, not the advance alone.
  ## The advance is now summed into that lead, CGB-only, exactly as
  ## CGB_PIPE_MCYCLES already was -- at which point BOTH strikethrough frames
  ## are byte-identical across the change and acid-hell is 0.
  ##
  ## The advance is summed into that lead unconditionally (it is a no-op at the
  ## shipping 0), so if this knob is ever turned on, strikethrough comes with it
  ## for free and only the daid row above is in the way.
  ## **It ships at 0 as well**, and for a narrower reason than the charge does:
  ## the quantity is now bracketed from both sides and the mechanism is settled,
  ## and what is left between it and shipping is ONE ROW. See the last section.
  ##
  ## The model, in one sentence: **while a CGB CPU is halted, the PPU runs one
  ## M-cycle of dots behind the rest of the machine, and gets them back on the
  ## way out.** The first halted M-cycle ticks the bus half only (the scheduler,
  ## the timer, the serial shifter, OAM DMA); the wake ticks those dots into the
  ## PPU with no bus half at all (cpu_halt_tick and `tick` in cpu.nim). Nothing
  ## is created or destroyed: a halt of k M-cycles still gives the PPU exactly
  ## k M-cycles of dots, and the CPU still spends exactly the T-cycles it slept.
  ## `halt_ppu_debt` is the memo, and it is reconstructed on a state load rather
  ## than serialized (savestate.nim) because it is the same value for the whole
  ## of any one halt.
  ##
  ## ---- Why a phase and not a charge: the tima rows pick -----------------
  ##
  ## Both models put the CPU's post-wake reads one M-cycle later IN THE PPU'S
  ## LINE, so both flip the ten `halt/` rows whose file names name a different
  ## expected value per device. They differ on every other consumer, and that
  ## difference is the whole measurement:
  ##
  ##   wake source   charge (EXIT_MCYCLES)      phase (this)
  ##   -----------   -----------------------    --------------------------
  ##   STAT / LYC /  read is 1 M-cycle later     the source itself rose one
  ##   vblank        in the line  (right)        M-cycle later in machine time,
  ##                                             so the read is 1 M-cycle later
  ##                                             in the line  (right)
  ##   timer         TIMA has advanced one       the timer never stopped and the
  ##                 more M-cycle  (WRONG)       wake is where it was  (right)
  ##
  ## The 42 `tima/*` rows are exactly the second line of that table -- they
  ## halt, a TIMER interrupt wakes them, and they read TIMA or IF a fixed number
  ## of M-cycles later, with ONE expected value for both devices. A charge moves
  ## all 42; the phase moves none of them, because the timer half of the halted
  ## M-cycle is never the half that is held back. Whole gambatte suite, one
  ## build per setting, baseline 3850/5005 (2026-08-10):
  ##
  ##   setting                          total   what moved
  ##   (control, all off)                3850   --
  ##   CGB_HALT_EXIT_MCYCLES=1           3813   halt +14 -10, dma +8 -7,
  ##                                            irq_precedence +1 -1, tima -42
  ##   CGB_HALT_EXIT_MCYCLES=2           3815   halt +14 -24, dma +37 -18,
  ##                                            tima -43
  ##   CGB_HALT_PPU_LEAD=1               3850   halt +14 -10, dma +3 -7
  ##   ..and SPEED_SWITCH_STALL_T=65544  3853   ..plus speedchange +11 -7
  ##
  ## A third mechanism was built and measured and is NOT kept, because it buys
  ## nothing over the phase: charging the M-cycle only when the ready set is
  ## LCD-only (so the timer wake is exempt by construction rather than by
  ## consequence) scores the same 3850 and the same rows as the phase does.
  ## The tima half does not separate the two; only the model does, and the
  ## phase is the one that costs no time anywhere.
  ##
  ## ---- It is ONE M-cycle, bracketed from both sides ---------------------
  ##
  ## Two `halt/` families are three ROMs each whose only difference is one NOP
  ## before the read, so they bracket the wake to a single M-cycle on the CGB:
  ##
  ##   family              _1        _2                 _3
  ##   ----------------    -------   ----------------   -------
  ##   lycirq_m2stat       out 2     dmg 2 / cgb 3      out 3
  ##   m1int_ly            out $90   dmg $90 / cgb $91  out $91
  ##
  ## At 0 the `_2` members answer the DMG value on a CGB; at 1 both flip green
  ## and `_1` and `_3` stay green; at 2 the `_1` members go red as well -- under
  ## the phase and the charge alike, so the bracket is a property of the
  ## quantity and not of either mechanism. Neither family carries an SCX, so
  ## neither is in the `scx_during_m3` bucket the ten SCX-laddered rows are.
  ## `lycirq_*` is the IME-clear path (the halt ends with no vector taken) and
  ## `m1int_*` the IME-set one, so the M-cycle is on both.
  ##
  ## Two more witnesses, neither of them a gambatte row:
  ##
  ##  * **daid `ppu_scanline_bgp.gb` on CGB.** Its whole frame is one phase, set
  ##    by an LYC=0 STAT interrupt that finds the CPU halted, and on `main` every
  ##    band of it is 3 pixels early against the shootout's `.gbc.png`. Turning
  ##    this on moves every band of that frame by exactly 4 pixels (measured as
  ##    the best whole-frame shift between the two builds), which leaves the 1
  ##    pixel that is the CGB-C -> CGB-D palette step (`CGB_MIXER_LATENCY`, 1 for
  ##    the `_cgb_c` references this tree scores and 0 for the `_cgb_d` ones
  ##    daid captured). 4 - 1 = 3, pixel for pixel, and it is a whole-frame band
  ##    measurement rather than one boundary crossing.
  ##  * **`SPEED_SWITCH_STALL_T` was carrying this M-cycle.** daid's
  ##    `speed_switch_timing_ly.gbc` / `_stat.gbc` sample the PPU every 8 dots
  ##    from the instruction after a STOP, and their phase is set by the single
  ##    halt each ROM takes at LY 144 -- so what they really pin is the total
  ##    PPU advance from that wake to the reads, stall included. On `main` the
  ##    two-dot window that puts both buffers where hardware has them is
  ##    65548..65549; with this constant at 1 it is 65544..65545, the same
  ##    window moved by exactly this M-cycle, and both rows are pixel-exact
  ##    again at 65544. That also takes the residual "switch countdown" the
  ##    stall's own note is left holding from 8 dots to 4, i.e. TOWARDS
  ##    SameBoy's independently sourced 65540 rather than away from it, and it
  ##    is worth 4 net gambatte `speedchange` rows on its own. See
  ##    SPEED_SWITCH_STALL_T in memory.nim.
  ##
  ## ---- What is left between this and shipping: one row ------------------
  ##
  ## `strikethrough/strikethrough-cgb` is pixel-exact on `main` and goes to
  ## 23033/23040 here -- 7 pixels, all on line 68, and the same 7 under the
  ## charge, so it refuses the QUANTITY and not the mechanism. The ROM is an
  ## OAM DMA test: it halts once a frame (LY 67, LYC STAT, IME set), starts a
  ## DMA in the handler, and the DMA is still running when the PPU's mode 2
  ## scans line 68, so the row is a knife edge on which OAM bytes are in place
  ## when that scan reads them. It is also the only row in the tree whose DMG
  ## and CGB references are structurally identical -- the CGB one is the DMG
  ## one inverted through the palette, pixel for pixel -- so it says hardware
  ## puts the two devices' DMA at the same place against that scan, and 4 dots
  ## crosses it. That is one 7-pixel row against five supports, but it is a
  ## green pixel-exact shootout row and this tree does not trade those for
  ## +3 gambatte, so the flag stays off until it is understood.
  ##
  ## The other 17 rows this costs are already accounted for elsewhere: 10 are
  ## the SCX ladder the note above attributes to `scx_during_m3` (49/141) --
  ## `m0{int,irq}_m0stat_scx{2,5}_1`, the `late_*_scx2_*a` members and
  ## `noime_m2irq_m0stat_1` -- and 7 are `dma/hdma_late_disable_*`, which that
  ## note lists in the same group.
  ##
  ## ---- 2026-08-10: it is not one row, and it is not the quantity ---------
  ##
  ## `dma/hdma_late_disable_*` does NOT belong in the SCX group above, and
  ## putting it there is what hid the real objection. `hdma_late_disable_1`
  ## and `_2` carry no SCX at all: they halt a CGB on `LYC = 1`, write FF55 48
  ## and 49 M-cycles after the wake, and bracket that write against line 1's
  ## mode 3 -> 0 edge to a single M-cycle. `halt/lycirq_m2stat_2` is the SAME
  ## WAKE -- the same LYC = 1 STAT source, the same line -- read 20 M-cycles
  ## on and bracketed against that line's mode 2 -> 3 edge. The first pair
  ## says the post-halt CPU is where this tree already puts it; the second
  ## says it is one M-cycle later. A halt phase answers one or the other and
  ## the rows differ only in IME, which `m1int_ly_2` and daid (both `EI` /
  ## `halt`, both vectored, both NEEDING the M-cycle) rule out as the split.
  ##
  ## So `strikethrough` is not one stubborn row against five supports: it is
  ## the third witness on a side that already has two clean gambatte rows, and
  ## the measurement is a contradiction rather than a missing refinement.
  ## Sub-M-cycle values do not reach between the two -- see
  ## CGB_HALT_PPU_LEAD_DOTS below, and the 2026-08-10 section of
  ## docs/gb-failure-triage.md for the sweep, the trace dots and the four other
  ## candidates that were built and refused (including a CGB OAM DMA start
  ## latency, which makes both strikethrough rows green and costs 103
  ## `oamdma` rows). **If this is revisited, `CGB_HALT_PPU_LEAD_DOTS=2` is a
  ## better setting of this same knob than the 4 that `=1` spells: gambatte
  ## 3860 against 3853. It is not shippable either -- it loses daid.**
  ##
  ## ---- 2026-08-13: a sixth witness, and it costs this flag nothing ------
  ##
  ## The 4 dots are now measured a way that does not go through `halt/` at all.
  ## gambatte's `speedchange{,2..5}_ly44_m3_*` family is a ladder in SWITCH
  ## COUNT and **none of its ROMs halts**, so it sees a KEY1 switch's PPU
  ## re-alignment on its own: it derives 8 dots into double speed and 3 back
  ## into single, two-sided and exact (55/55 rows). daid's `speed_switch_timing`
  ## pair DOES halt -- once each, `halt` at `$019B`, waiting for the first
  ## vblank after an LCD enable -- and pins halt-lead + switch-extra together at
  ## 12. 12 - 8 = 4, i.e. **exactly this constant, from a family that shares no
  ## ROM, no register and no edge with the five witnesses above.** And the halt
  ## is the only carrier those 4 dots can have: `LCD_ON_HEAD_START` at 1 and at
  ## 9 moves daid by zero pixels, because a halt re-anchors the CPU to a PPU
  ## event and a whole-M-cycle shift of the PPU before the wake cancels out.
  ##
  ## That does not unblock `strikethrough`, but it changes what this flag is
  ## worth: composed with the pair (`-d:SPEED_SWITCH_PPU_EXTRA_DOTS=8
  ## -d:SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE=3`) it is gambatte **4183 -> 4224**
  ## with all three daid frames green, where this flag ALONE is 4180 today. Both
  ## speed-switch constants default off this one (memory.nim), so flipping this
  ## to 1 is the whole change. See docs/gb-failure-triage.md, 2026-08-13
  ## (second).
  ##
  ## ---- What it does NOT close, which is why it was written ---------------
  ##
  ## `acid/cgb-acid-hell` needs the CPU's write burst TWO M-cycles later against
  ## the PPU, not one. Its LCDC writes and the fetcher's reads are both on an
  ## 8-dot lattice, so only a whole 8 dots changes which of the sixteen written
  ## bytes lands on the observable bitplane read; 4 dots moves the write into
  ## the tile-MAP slot, where no read is on the change's dot at all. At 2 the
  ## row is 23040/23040 -- and the bracket above refuses 2 outright. See the
  ## acid-hell section of docs/gb-failure-triage.md.
  ##
  ## **At 1 the row is 23038/23040 and there is no rule that fixes it.** (The
  ## sentence this replaces said the frame came out BIT-IDENTICAL to `main`
  ## here; that predates `CGB_TDSEL_IDX_DOTS`, which fires at 0 and on nothing
  ## at 1, so the two builds differ by exactly the two famous pixels.) The
  ## whole question -- what the CGB TILE_SEL glitch rule must be in THIS world
  ## -- was measured on 2026-08-14 with `tools/gbppu/tdselphase.py`, which
  ## buckets every pinned background bitplane read of the five reference frames
  ## by how far the last LCDC.4 change is from it. Hardware disturbs a read on
  ## exactly ONE offset, zero, and 6352 mealybug reads at every other offset
  ## from -8 to +40 dots are undisturbed. At 1 acid-hell's changes sit 4 dots
  ## off its observable reads, in a bucket 56 mealybug reads share and 48 of
  ## them refuse the index in. Full account, including the two-sided bracket
  ## that kills the last spelling, in docs/gb-failure-triage.md's 2026-08-14
  ## entry. **What the 4 dots are is now answered and it is not this knob:**
  ## `M3_PIPE_AHEAD` supplies them from the consumer side, and the same entry
  ## carries the bundle world's numbers.
const CGB_OAM_DMA_START_T* {.intdefine.} = 8
  ## T-cycles between the write to FF46 and the OAM DMA unit taking the bus, on
  ## CGB. 8 is what both devices ship with (mem_dma_tick) and what this tree
  ## measures; the knob exists only because `strikethrough` at a nonzero
  ## CGB_HALT_PPU_LEAD wants exactly 4 T taken out of here, and it is worth
  ## having the row that refuses it on record. See docs/gb-failure-triage.md
  ## (2026-08-10).
const GB_POWERUP_WRAM_PATTERN* {.intdefine.} = 1
  ## Fill WRAM with a fixed pseudo-random pattern at power-up instead of zeroes.
  ##
  ## **Pan Docs is explicit** (Power_Up_Sequence): *"The console's WRAM and HRAM
  ## are random on power-up"*, and it names filling with a constant as an
  ## emulator shortcut rather than behaviour. An all-zero fill was therefore
  ## wrong by this tree's own spec authority, and BullyGB's InitRAMTest exists
  ## to catch exactly that shortcut — it walks $C000-$DFFF, reports
  ## "Uninitialized RAM not randomized" when every byte is $00, and since it is
  ## the FIRST of that ROM's nine tests, the other eight had never run here.
  ## With this on, bully prints **"All tests OK!"** and the row is pixel-exact.
  ##
  ## **Measured on a GBA SP** (flashcart-kit/9, `wramscan.gb`, booted directly
  ## to the ROM so the cart menu could not overwrite it): 369 bytes of $00, 221
  ## of $FF, **7602 of neither**, out of 8192. Real WRAM is overwhelmingly
  ## non-uniform values, so zeroes are not close and a fill is not merely
  ## defensible but the better model. It is not uniform noise either — uniform
  ## would give ~32 each of $00 and $FF, not 369 and 221 — which is why this is
  ## an honest approximation and not a claim about the silicon.
  ##
  ## **The bill, and why it is paid.** gambatte `oamdma` goes 771 -> 766. All
  ## five are `oamdma_srcFE00_*` / `srcFF00_*` and all five stop producing a
  ## readable verdict at all ("got ?") rather than a wrong one. That is not
  ## incidental: an OAM DMA source at or above $E000 fetches through the echo,
  ## so $FE00 and $FF00 read **$DE00 and $DF00** (the mapping mooneye
  ## `oam_dma/sources-GS` pins, and which passes). Proven rather than argued:
  ## randomising all of WRAM EXCEPT $DE00-$DFFF restores gambatte to 4274 and
  ## oamdma to 771 exactly, with bully still passing.
  ##
  ## So those five rows read UNINITIALISED WRAM, and their expected values
  ## encode whatever the capture rig happened to leave at $DE00. Pan Docs says
  ## not to rely on that; a spec-correct emulator cannot score them. Zeroing
  ## just those two pages would buy all five back and is deliberately NOT done —
  ## it fits gambatte's rig rather than hardware, and the AGS scan puts its zero
  ## run near $D600, nowhere near $DE00.
  ##
  ## Net: runner Pass 1015 -> 1016 with **zero runner rows lost** (the oamdma
  ## group was already failing), gambatte 4274 -> 4269.
  ##
  ## **Fixed xorshift, never a seeded RNG.** Every determinism guarantee here —
  ## the byte-identical screenshot gates, save-state round-trips, the rollback
  ## netplay core — needs two runs of the same ROM to start from the same bytes.
  ##
  ## **`wrambands.gb` has now been run on two machines (2026-08-20), and the
  ## answer is: uniform is right for AGB, mildly wrong for MGB.** Set bits per
  ## 256-byte block, out of 2048, excluding the flashcart loader's region:
  ##
  ##     AGB (GBA SP)     mean 1007.6 / 2048 = 49.2% of bits set
  ##     MGB (GB Pocket)  mean 1089.2 / 2048 = 53.2% of bits set
  ##
  ## with byte counts of 369 `$00` / 221 `$FF` on the AGB against 834 / 333 on
  ## the MGB. **There is NO 256-byte banding on either machine** — the even and
  ## odd halves of every row track each other — so the alternating-band shapes
  ## some emulators model are not what these consoles do at that period.
  ##
  ## The uniform fill here is therefore a good model of an AGB and slightly
  ## under-biased for an MGB. Deliberately NOT chasing that 4%: no row in the
  ## tree distinguishes them, one console is not a population, and fitting a
  ## per-model bias to a single sample would be exactly the overfitting this
  ## constant's history is already a lesson about. The measurement is recorded
  ## in docs/flashcart-runbook.md if a test ever needs it.
const HDMA_SPEEDSWITCH_KILL_W* {.intdefine.} = 1
  ## Dots before the mode 3 -> 0 edge within which a CGB speed switch DESTROYS
  ## an armed HBlank VRAM DMA outright. 0 disables the mechanism; **1 ships,
  ## and 1 means the switch and the edge land on the SAME DOT.**
  ##
  ## A STOP that switches speed does not normally disturb a transfer -- a
  ## halted CPU simply owes the block ("the transfer will also be halted and
  ## will be resumed only when the CPU resumes execution", Pan Docs FF55), and
  ## `hdma_m3halt_m1unhalt_hdma5` proves an ordinary HALT can miss a whole
  ## frame of HBlanks and leave the transfer armed with its length untouched.
  ## What this models is a RACE: the block becomes due on the very dot the
  ## clock changes underneath it, and it is lost together with the arming.
  ##
  ## **The dot is measured, not fitted.** `-d:gb_dma_trace` prints the STOP's
  ## dot beside the mode-0 edge's, and across the nine speed-switch ROMs that
  ## disagreed the two quantities separate the outcomes exactly:
  ##
  ##   ROM                                     STOP  edge   d   FF55  killed?
  ##   transition_speedchange_hdmalen00_scx1    253   253    0    80    yes
  ##   transition_speedchange_hdmalen7f_scx1    253   253    0    FF    yes
  ##   late_m3speedchange_hdma5_scx1_2          253   253    0    80    yes
  ##   late_m3speedchange_hdma5_scx2_1          253   254    1    00    NO
  ##   late_m3speedchange_hdma5_scx1_1          249   253    4    00    NO
  ##   m3speedchange_late_m0wakeup_2            121   252  131    00    NO
  ##   m0speedchange_late_m3wakeup_scx1_1       373   253 -120    FF    NO
  ##
  ## Every `d = 0` row wants the transfer gone and every other row wants it
  ## kept, including `scx2_1` one single dot away -- which is why the window is
  ## a strict `d < W` and why widening it costs rather than gains:
  ##
  ##   W (dots)      0     1 (ship)    2      3      5
  ##   gambatte dma 156      165      164    164    163
  ##
  ## (re-swept at HEAD with HDMA_DISABLE_GRACE_DOTS shipping; it was
  ## 150/159/158/158/157 before that constant existed, same shape.)
  ##
  ## An unconditional abort at every speed switch was tried first and is
  ## REFUSED: +10 / -7 for a net +3, and the seven it breaks
  ## (`m3speedchange_late_m0wakeup_{1,2}`, `m0speedchange_late_m3wakeup_*`,
  ## `late_m3speedchange_hdma5_*_1`) are exactly the rows whose switch is
  ## nowhere near the edge. SameBoy models none of this -- it answers the same
  ## values dingbat did before this landed on all five
  ## `transition_speedchange_hdmalen*` rows -- so gambatte's hardware capture
  ## is the only witness here and there is no oracle to cross-check against.
const HDMA_DISABLE_GRACE_DOTS* {.intdefine.} = 4
  ## Dots after the mode 3 -> 0 edge at which an owed HBlank DMA block has
  ## COMMITTED, i.e. after which an FF55 write with bit 7 clear is too late to
  ## suppress it. 0 disables the rule (every disable suppresses, which is what
  ## dingbat did).
  ##
  ## Distinct from HDMA_STEAL_DELAY_M, and both are needed. That constant says
  ## WHEN the block runs -- at the CPU's next instruction boundary, because the
  ## CPU finishes what it is doing before the DMA gets the bus. This one says
  ## when the block became UNCANCELLABLE, which is earlier: the arbitration is
  ## settled a fixed moment after the edge and the CPU can no longer take it
  ## back, even though the transfer itself has not started.
  ##
  ## **gambatte `dma/hdma_late_disable_*` measures it directly, and dingbat had
  ## it at zero.** Each ROM arms a one-block HBlank transfer, writes $00 to FF55
  ## near the mode-0 edge to stop it, and reads the destination byte back; the
  ## `_1` and `_2` members put that write one M-cycle either side of the answer.
  ## `-d:gb_dma_trace` on the plain pair:
  ##
  ##   ROM                    m0 edge   FF55=$00 at   d   byte   dingbat was
  ##   hdma_late_disable_1      252         253       1    00       00  ok
  ##   hdma_late_disable_2      252         257       5    01       00  WRONG
  ##
  ## So the block is still cancellable one dot after the edge and gone five dots
  ## after it, and the boundary is swept two-sided over the whole 229-ROM group:
  ##
  ##   dots          0     2     3    4 (ship)   5     6     8
  ##   gambatte dma 159   161   163     165     163   161   159
  ##
  ## **Four dots flat, not one CPU M-cycle.** `hdma_late_disable_ds_2` and
  ## `_scx5_ds_2` are double speed, where an M-cycle is two dots, and they go
  ## green at the same 4 as the single-speed rows -- so this is real time on the
  ## PPU's clock, the way the block's own copies are, and not a count of the
  ## CPU's cycles the way HDMA_BLOCK_OVERHEAD_BUS is. The peak is +6 / -0 and
  ## the six are exactly the `hdma_late_disable` `_2` members at every SCX and
  ## both speeds; nothing else in the tree moves.
  ##
  ## **Separating the two did NOT free HDMA_STEAL_DELAY_M**, which was the
  ## obvious follow-up and is worth recording as refused. The surviving
  ## `irq_precedence/late_hdma_vs_{ei,ie,tima}` rows answer their own `_2`
  ## sibling's value, which reads like the block taking the bus one M-cycle
  ## early, and with the commit point now modelled separately the steal delay
  ## was free to move. Re-swept with this constant at 4:
  ##
  ##   HDMA_STEAL_DELAY_M      0      1 (ship)    2      3
  ##   gambatte dma           150       165      151    148
  ##   gambatte irq_precedence 44        47       43     43
  ##
  ## One instruction boundary is still the unique optimum on BOTH groups, so
  ## those rows are not a steal-delay offset and want something else.
const HDMA_STEAL_DELAY_M* {.intdefine.} = 1
  ## CPU instruction boundaries an HBlank DMA block waits after the mode-0 edge
  ## before it takes the bus. 0 = take it on the edge itself, which is what
  ## dingbat has always done.
  ##
  ## mealybug `dma/hdma_timing-C` says the edge is too early. Its `sub_test`
  ## macro arms a one-block transfer and then reads a register after a given
  ## number of nops, one fresh run per nop count, so the four HDMA5 samples are
  ## independent. At SCX=1 hardware answers `00 ff ff ff` for nops 46-49, and
  ## `$00` is "armed, zero blocks left, NOT YET TRANSFERRED" -- so at nop 46 the
  ## CPU is still running and hardware's block has not started. The STAT samples
  ## in the same test put the mode-0 edge between nops 44 and 45. The block
  ## therefore starts about TWO M-cycles after the edge, and the CPU is stalled
  ## through it (which is why nops 47-49 all read `$FF`: they land after the
  ## stall, not before it). At SCX=2 the longer mode 3 moves the edge one
  ## M-cycle later and the answer becomes `00 00 ff ff`, one sample further
  ## along -- the same story shifted, which is the ROM's own "HDMA is delayed
  ## due to longer mode 3".
  ##
  ## Paid at INSTRUCTION boundaries, not on a dot counter. A per-dot deadline is
  ## what ppu_land_hdma_if_due measured at +1.36% of retired instructions and
  ## declined; this is one not-taken branch per instruction instead, and it
  ## measures FREE -- 23712879357 -> 23704099110 retired instructions on
  ## dmg-acid2, i.e. marginally faster, min of 3.
  ##
  ## **Paid BEFORE handle_interrupts, and that ordering is worth as much as the
  ## delay.** "The DMA takes the bus before the CPU's own next cycle, so it goes
  ## ahead of the dispatch" -- the halt-exit path in cpu.nim already said so.
  ## Paying at the TOP of the next instruction instead is the same instant on
  ## the wrong side of the dispatch, and costs the whole gambatte
  ## `irq_precedence` hdma_vs_m0 / late_hdma_vs_ei / late_hdma_vs_ie family;
  ## paying it before the dispatch GAINS three of those rows over the old
  ## edge-triggered behaviour.
  ##
  ##   HDMA_STEAL_DELAY_M      0      1 (ship)   2      3      4
  ##   hdma_timing-C wrong    8/48    2/48     4/48   8/48  10/48
  ##
  ## Whole suite: **gambatte 4263 -> 4274, dma 126 -> 134, irq_precedence
  ## 44 -> 47, zero rows lost.** The `dma` gain is the entire
  ## `hdma_late_disable` family, which is exactly the set HDMA_VISIBLE_DOTS was
  ## swept over and could not recover at any value -- the strongest evidence
  ## that the mechanism, not the constant, was what was missing.
const HDMA_BLOCK_OVERHEAD_BUS* {.intdefine.} = 4
  ## CPU-clock cycles a VRAM DMA costs beyond its sixteen-byte-per-block copies:
  ## the bus acquire/release either side of the TRANSFER, which dingbat charged
  ## as zero. NOT the per-byte cost -- two dots per byte at either speed is
  ## pinned by gambatte's `hdma_start_ds_*` and agrees with SameBoy's
  ## GB_hdma_run.
  ##
  ## **Per transfer, not per block, and `gdma_cycles_long` is what says so.**
  ## Charged once per BLOCK it is right for every one-block transfer in the
  ## suite and catastrophically wrong for the long ones. `gdma_cycles_long*`
  ## writes `LD A,$7F` to FF55 -- 128 blocks in one general-purpose burst -- so
  ## a per-block charge added 128 * 4 = 512 CPU cycles and 128 * 2 = 256 dots,
  ## more than half a scanline, and pushed the family's STAT read clean past
  ## mode 0 into the NEXT line's mode 2. Both members of every `long` pair
  ## answered 2 where hardware answers 3 then 0. Making it per transfer:
  ##
  ##   gambatte dma   134 -> 144/229     (whole suite 4269 -> 4279, 0 lost)
  ##
  ## and the ten rows are exactly the `gdma_cycles_long` family bar its SCX 2
  ## and SCX 3 members, which are the separate mode-3-length residual that also
  ## holds `gdma_cycles_short_scx{2,3}_2` and `hdma_cycles_scx{2,3}_2` red at
  ## every value of this constant.
  ##
  ## The mechanism is the reason, not the fit: a GDMA stops the CPU and holds
  ## the bus for the whole burst, so there is nothing to re-acquire between its
  ## blocks. An HBlank DMA hands the bus back after every block -- that is the
  ## whole of what makes it an HBlank DMA -- so it pays this once per block, and
  ## a one-block transfer of either kind is timed identically either way, which
  ## is why the sweep below is unaffected.
  ##
  ## **Four CPU-clock cycles: it is ONE M-CYCLE, and its dot cost therefore
  ## halves in double speed.** This shipped first as a flat count of DOTS,
  ## `ignore_speed = true`, on the argument that the copies scale because they
  ## are two PPU dots whatever the CPU is doing. The copies do; this does not,
  ## and the whole `*_cycles` family is a two-sided bracket that says so.
  ##
  ## Those 40 rows are pairs one M-cycle apart whose expected values (3 then 0)
  ## straddle the mode 3 -> 0 edge, so each pair is an interval on the dots this
  ## term contributes. Swept a dot at a time, the flip points give:
  ##
  ##     ROM family                    dots that satisfy it
  ##     hdma/gdma_cycles (scx 0)      [1, 5)
  ##     ..._scx2                      [3, 7)
  ##     ..._scx3                      [4, 8)
  ##     ..._scx5                      [2, 6)
  ##     ..._ds, _2xshort_ds           [2, 4)  /  [2, 3)
  ##     ..._scx5_ds                   [1, 3)
  ##
  ## The four single-speed intervals intersect at **4** and the double-speed
  ## ones at **2**, and no flat dot count is both -- which is exactly why every
  ## setting of the old `..._DOTS` knob left some of the family red, and why
  ## GDMA_SETUP_MCYCLES was written up as "no constant works". 4 dots at normal
  ## speed and 2 at double IS one CPU M-cycle, so the term is charged with
  ## `mem_tick_components(4, ignore_speed = false)` and the family goes
  ## **34/40 -> 40/40 with no contradiction left in it.**
  ##
  ## (Charging it BEFORE the copies instead of after scores identically -- the
  ## copies end at the same dot either way -- so the placement is not evidence
  ## about acquire versus release.)
  ##
  ## **What it costs, and why that is kept.** Two rows go the other way:
  ## `hdma_late_enable_1` and `_lcdoffset3_1`. Both arm an HBlank transfer on
  ## the LAST dot of a line and then read $8000, and the two extra dots land
  ## that read one dot INTO mode 3 with the latched mode still 2, where
  ## `cpu_vram_open` refuses it and the ROM prints `$FF and $07` = 7. SameBoy
  ## answers both with the byte, so the read lock and not the transfer cost is
  ## what is wrong there; the note at `cpu_vram_open` has the bracket and the
  ## seven rows that refuse the obvious fix. Net on the family: +6 / -2.
  ##
  ## Earlier sweep, kept because it is what fixed the DIV-duration groups and
  ## it is still the bracket on the CPU-cycle count itself:
  ##
  ##   CPU-clock cycles        2      4 (ship)    6      8
  ##   hdma_timing-C wrong   16/48    8/48     12/48  16/48
  ##
  ## **Where hdma_timing-C stands: 20/48 wrong -> 12 -> 8. SameBoy gets 2/48.**
  ## Both DIV-duration groups are now exact and so is the mode-2 entry after the
  ## block. The remaining 8 are two separable defects, in
  ## `tools/gbppu/hdmaresults.nim` terms:
  ##
  ##   * **6 cells: FIXED 2026-08-19 by HDMA_STEAL_DELAY_M.** The block was
  ##     taking the bus on the mode-0 edge itself; hardware lets the CPU finish
  ##     its instruction first. See that constant.
  ##   * **2 cells remain, and they point OPPOSITE WAYS**, which is why no
  ##     scalar closes them: SCX=1 single speed wants the block ~1 M EARLIER
  ##     (sample 47 reads $00 where hardware says $FF) and SCX=2 double speed
  ##     wants it LATER (sample 47 reads $FF where hardware says $00).
  ##     **SameBoy also scores 2/48 here** (its two are both late, in groups 0
  ##     and 3).
  ##
  ##     **A dot-granular delay was tried on 2026-08-20 and does NOT help — do
  ##     not re-derive it.** The reasoning was sound and the measurement refused
  ##     it: an instruction boundary is 4 dots at single speed and only 2 at
  ##     double, which is exactly the asymmetry above, so a FIXED dot delay
  ##     between those two numbers should have satisfied both directions at
  ##     once. Implemented as an `etHdmaSteal` scheduler event armed at the
  ##     mode-0 edge with `schedule_gb` — constant in real time, hence constant
  ##     in DOTS at either speed, at no per-tick cost — and swept whole:
  ##
  ##       dots      1   2   3   4   5   6   8  10  12  16  20  24  32
  ##       wrong/48  6   6   6   6   2   2   2   4   6   8  10  10  10
  ##
  ##     It PLATEAUS at 2/48 across dots 5-8, exactly what the boundary path
  ##     already achieves with no new machinery, and is worse everywhere else;
  ##     the predicted 3 dots is 6/48. At 5 dots both survivors are `FF != 00`,
  ##     i.e. both too EARLY and in the SAME direction, which looked like more
  ##     delay would close them — and more delay makes it monotonically worse.
  ##     So the residual is not a placement question at ANY granularity. The
  ##     scheduler version was reverted rather than shipped: it ties the simpler
  ##     code while adding an event type and a save-state surface.
const HDMA_VISIBLE_DOTS* {.intdefine.} = 4 + 4 * CGB_HALT_PPU_LEAD
  ## Dots an HBlank DMA block's bytes take to become visible in VRAM.
  ##
  ## The `4 * CGB_HALT_PPU_LEAD` term is the same argument OBJ_DMA_BUS_LEAD
  ## makes for the OAM DMA unit, and it is here for the same reason: the DMA
  ## engine runs on machine time and this window is measured against the
  ## pipeline, so advancing the pipeline by an M-cycle moves the window with it.
  ## Inert at the shipping `CGB_HALT_PPU_LEAD = 0`, which is why the constant is
  ## declared down here rather than up with the other memory timings.
  ##
  ## Measured, whole gambatte suite, with the lead on: `dma` is 116/229 at 4,
  ## **121 at 8**, and 116 again at 12 -- a local maximum bracketed on both
  ## sides, and 8 is exactly 4 plus the advance. It is only a PARTIAL account:
  ## seven `hdma_late_disable_*` rows stay red and this term does not explain
  ## them, so the bracket is not the whole story.
const CGB_HALT_PPU_LEAD_DOTS* {.intdefine.} = 4 * CGB_HALT_PPU_LEAD
  ## The same lag in DOTS rather than in M-cycles, which is the unit the
  ## measurement above never actually had. `CGB_HALT_PPU_LEAD` sets it in whole
  ## M-cycles and this is what the code reads, so `=1` still means 4 dots and
  ## the shipping 0 is bit-identical either way; setting THIS directly is what
  ## reaches the three values between them.
  ##
  ## Why the sub-M-cycle values are not a finer knob on the same thing: the
  ## halt's exit is sampled on the M-cycle grid (`cpu_halt_tick`), so a lag of
  ## 1, 2 or 3 dots does not move the wake by 1, 2 or 3 dots. It moves it by a
  ## WHOLE M-cycle for a source whose rise dot is within `DOTS` of the next
  ## M-cycle boundary, and by nothing at all for every other source. One
  ## quantity, a per-source answer -- which is the shape the rows below need,
  ## and the reason this knob exists at all. The sweep that measured it is in
  ## docs/gb-failure-triage.md (2026-08-10).
const CGB_HALT_PPU_LEAD_ANY* = CGB_HALT_PPU_LEAD_DOTS != 0

# ---- CGB per-register PPU write latency -------------------------------------
#
# How many dots into its own M-cycle a CPU write to a pipeline register lands
# on CGB, over and above where DMG puts it. Here rather than next to their
# write-up in memory.nim only because the GbMemory fields they gate are in the
# type block below; the mechanism, what it is not, and the sources cross-checked
# are all at mem_tick_ppu_latched.
#
# DMG is the zero of this scale, not the origin: dingbat commits a write's byte
# at the top of its M-cycle (see mem_write) and every DMG family that brackets
# one of these already agrees with that, so what is modelled here is the CGB
# *delta* and nothing else -- which makes it invariant to whatever constant
# offset dingbat's dot grid carries against anyone else's.
#
# **Six of the seven ship at 0; SCY ships at the documented 2 as of 2026-08-03,
# once the OBJ fetch phase it was being measured through was fixed (see the
# SCY bullet below and tick_sprite_fetcher in fifo_ppu.nim).** For the other six
# the reason is still a measurement. The CGB PPU really does take these
# writes late -- the mealybug PPU document states a 2-T-cycle CGB delay for SCY
# outright, and Pan Docs' "Mid-frame behavior" carries the same split -- but
# every one of them is refused by this tree today. Whole gambatte suite per
# setting, one build each, baseline 3561/5005 (2026-08-03; 3563 from the
# DMG-compatibility-mode commit onward, which moved no row in this table):
#
#   setting                                     total   what moved
#   (all 0, the control)                         3561   nothing; row for row main
#   CGB_WX_LATENCY=1                             3560   window -1
#   CGB_WY_LATENCY=1                             3561   nothing at all
#   CGB_WY_LATCH_LATENCY=2                       3561   nothing at all
#   CGB_WY_LATCH_LATENCY=4                       3560   window -1
#   CGB_SCY+SCX_LATENCY=1                        3560   scy -1
#   CGB_SCY+SCX_LATENCY=2                        3551   scy -6, scx_during_m3 -3,
#                                                       sprites -1, enable_display +1 -1
#   CGB_SCY+SCX_LATENCY=2, CAP=1                 3559   enable_display +1 -1,
#                                                       scx_during_m3 -1, scy -1
#   CGB_LCDC_LATENCY=1                           3557   window -3, bgtiledata -1
#   CGB_LCDC_LATENCY=2 (tdsel 1)                 3553   window -5, sprites -2,
#                                                       bgtiledata -1
#   all of them at the documented values, CAP=1  3553   window -5, scy -1,
#                                                       scx_during_m3 -1,
#                                                       bgtiledata -1, e_d +1 -1
#   a UNIFORM 4 on all seven (the phase model)   3539   window -9+1, scy -6,
#                                                       sprites -4+1, scx_during_m3 -4
#
# Every moved row is a `[cgb]` row -- the DMG side is untouched, as it must be.
#
# ---- The second instrument, and what it says -------------------------------
#
# gambatte was the whole instrument when the table above was taken, because
# Mealybug was scored against its DMG references only. It is not any more: the
# suite's `_cgb_c` references are wired up as 27 rows of their own, and they
# are mid-mode-3 register writes read as a picture rather than as a glyph.
# Scored as matching bytes over all 27 (mbscore.py, device cgb; DMG total is
# 510167 and does not move for any setting here, as it must not).
#
# ---- Every knob against both instruments, one build per cell ---------------
#
# Re-taken 2026-08-03 with each constant swept ALONE (cgbsweep.sh forces the
# other six to 0, so the flag on the line is the whole setting), to answer one
# question: is the SCY shortfall below systematic across the register file --
# which is what a single global absorber such as a late mode 3 start would look
# like -- or is it SCY's alone? Baselines: gambatte 3567/5005, mealybug CGB
# 1794023.
#
#   setting                    gambatte   mealybug CGB   what moved
#   all 0 (the control)          3567        1794023     row for row main
#   CGB_SCY_LATENCY=1            3566        1803344     scy -1; m3_scy_change
#                                                        82.0 -> 95.9
#   CGB_SCY_LATENCY=2            3566        1795140     scy -1; m3_scy_change
#                                                        82.0 -> 84.6,
#                                                        m3_scy_change2 -> 99.0
#   CGB_SCY_LATENCY=3            3566        1791068     scy -1
#   CGB_SCX_LATENCY=1            3567        1793878     nothing
#   CGB_SCX_LATENCY=2            3566        1792812     enable_display +1 -1,
#                                                        scx_during_m3 -1
#   CGB_WX_LATENCY=1             3566        1794023     window -1
#   CGB_WX_LATENCY=2             3566        1794047     window -1
#   CGB_WY_LATENCY=1 / =2        3567        1794023     nothing at all
#   CGB_WY_LATCH_LATENCY=2/3/4   3567        1794023     nothing at all
#   CGB_LCDC_LATENCY=1           3564        1792077     window -3
#   CGB_LCDC_LATENCY=2           3563        1789728     window -4
#   CGB_LCDC_TDSEL_LATENCY=1     3563        1789555     window -3, bgtiledata -1
#   CGB_LCDC_TDSEL_LATENCY=2     3562        1784962     window -4, bgtiledata -1
#
# **The shortfall is not systematic: SCY is the only register in the file whose
# instruments move at all.** Nothing here is one dot short of its documented
# value in the way a global absorber would make all seven -- LCDC and SCX are
# refused monotonically all the way down to 0, and WY and the WY latch have no
# instrument in this tree at any value. That is not proof against a global
# absorber (a one-dot move is invisible to a family that cannot see any dot at
# all), but it removes the reason to look for one first: whatever is eating the
# SCY dot has to be something SCY's own ROMs can see, and the DMG side can see
# it too -- m3_scy_change is 92.6% on DMG, where none of these constants exists.
# See the SCY bullet below for where it went.
#
# That is why SCROLL is now two constants. Pan Docs documents the two registers
# differently -- "Mid-frame behavior" gives SCY a per-model sample point and
# says the SCX split (high 5 bits per tile fetch, low 3 latched at line start)
# with no model qualifier at all -- and the split is visible here: SCX at 1
# costs two rows that are otherwise pixel-perfect, SCY at 1 does not touch
# them.
#
# ---- Why each value is refused, family by family ---------------------------
#  * SCY. **The documented 2 is right, the whole-frame score's preference for 1
#    is an artefact, and the value still ships at 0.** All three of those are
#    measurements; here is the one that decides them.
#
#    m3_scy_change is not one measurement, it is eighteen. Its OAM table is
#    `Y = 16 + 8k, X = k` for k = 0..17, so each 8-line band of the frame
#    carries exactly one object and that object's X advances down the screen --
#    and the object is not scenery, it is the RULER. Its sibling says so in its
#    own header: "Sprites are positioned to cause the write to occur on
#    different T-cycles of the background tile fetch, showing when the change to
#    the bit takes effect." The OBJ penalty is what sets the phase between the
#    ROM's write burst (one SCY write every 2 M-cycles, values 0,1,2,3,4,3,2,1)
#    and the BG fetcher's three SCY reads, and Pan Docs' penalty for an object
#    at X is `6 + max(0, 5 - X)` dots -- so the wait term the bands sweep is
#    5,4,3,2,1,0,0,0 for X = 0..7 and again for X = 8..15.
#
#    Scored per band instead of per frame (differing columns out of 8 lines x
#    160; tools/gbppu is the kit, and `-d:gb_m3_trace -d:GB_TRACE_LY=-1` plus
#    the glyph table from the ROM with its 24 writes NOPped out is what turns
#    the picture back into "which write did each of the three reads see"):
#
#      band  objX  OBJ wait   L=0    L=1    L=2
#       5     5       0       626     16      0
#       6     6       0       626     16      0
#       7     7       0       614     16      0
#      14    14       0       617     33      0
#      15    15       0       608     31      0
#       3     3       2        16     16    621
#       4     4       1        18     18    609
#      11    11       2        48     48    585
#      12    12       1        53     53    575
#
#    Read the two halves separately. In every band whose object has NO wait
#    term, the CGB reference is PIXEL-EXACT at 2 and wrong at 1 -- and those are
#    exactly the bands where this tree's own phase is provably right, because
#    the DMG reference is pixel-exact there at 0. In every band with a wait
#    term, 0 and 1 score identically and 2 collapses -- and those are exactly
#    the bands where the DMG reference says this tree is ALREADY wrong with no
#    CGB constant involved at all (bands 3, 4, 11, 12 are ~960/1280 matching
#    against the DMG blob at any setting).
#
#    So the missing dot is not in this constant and not in the CGB pipeline: it
#    is the BG fetcher's phase across an OBJ fetch, which is device-independent,
#    is a function of the object's X, and is the very thing this ROM measures
#    with. Sweeping the reference against dingbat's own traced read dots puts
#    hardware's post-object fetch grid `wait` dots behind this tree's, i.e.
#    dingbat advances the BG fetcher during the penalty's wait dots where the
#    references say it stands still. That is written up, with the table and with
#    what the naive fix costs, at tick_sprite_fetcher in fifo_ppu.nim.
#
#    **Which leaves the shipping value, and it is now 2.** With the fetcher
#    phase unfixed, 2 cost more than it bought (gambatte 3567 -> 3566 and
#    mealybug m3_scy_change2 100.0 -> 99.0, both of them rows whose own ruler is
#    the same OBJ phase). The fetcher phase was fixed on 2026-08-03 and the band
#    table was re-run; the prediction above -- that every band comes up, not just
#    the five with no wait term -- held. Per band on the fixed fetcher,
#    m3_scy_change against its `_cgb_c` reference, matching pixels out of 3840:
#
#      band (objX)   0     1..3    4    5..7   8..12   13..15   16,17
#      at 0        3658   ~3800  3702  3808   ~3700   3808    ~3700
#      at 2        3658   ~3800  3702  3808   ~3700   3808    ~3700
#      whole ROM   82.0% -> 97.7%, and the CGB suite 1794023 -> 1812603 pixels
#
#    The wait > 0 bands no longer collapse at 2 -- that collapse WAS the fetcher
#    phase -- and gambatte does not move at all between 0 and 2 now (3613 both),
#    so the row this used to cost is gone with it. 1 and 3 are both worse on
#    mealybug CGB (1802113 and 1809324 against 1814216 for the whole suite with
#    the rest of the file at its shipping values), which is the first time this
#    constant's two instruments have agreed on the documented value.
#    The third refusal is unrelated to all of this and stands: gambatte loses
#    scy/scy_during_m3_spx08_ds_4, a DOUBLE SPEED row, at any nonzero value. At
#    2 dots per M-cycle a 1-dot latency lands on the cap boundary, so that row
#    is the CGB CPU-to-PPU phase axis reading a register latency, which is the
#    confusion CGB_LATENCY_CAP exists to prevent and cannot at this width.
#  * SCX. **Also 2 as of 2026-08-03, and for the same reason SCY is: the row
#    that used to refuse it was reading the OBJ fetch phase.** The one clean,
#    DMG-neutral, per-device row that a scroll latency fixes is
#    enable_display/ly0_late_scx7_m3stat_scx0_274, whose DMG sibling expects $87
#    and whose CGB row expects $84; at 2 dots dingbat gets both right. What used
#    to refuse it was mealybug: both m3_scx_* CGB rows were pixel-perfect at 0
#    and any nonzero value broke them. On the fixed fetcher they are not
#    pixel-perfect at 0 any more, and they come back monotonically --
#    m3_scx_high_5_bits 99.5% / 99.7% / 100.0% and m3_scx_high_5_bits_change2
#    99.7% / 99.8% / 100.0% at 0 / 1 / 2 -- while gambatte adds
#    scx_during_m3/scx_0060c0 and _0063c0's `_3` rows on the CGB side (30 -> 32,
#    +517 mealybug CGB pixels, DMG untouched as it must be). Three instruments,
#    one value, and it is the documented one.
#    Its _scx1 rows are still red on both devices; that residual is elsewhere.
#  * LCDC. **Read this bullet as being about the WHOLE-REGISTER latency only.**
#    Four of LCDC's bits now carry their own per-reader delay instead --
#    CGB_OBJ_SIZE_LATENCY (bit 2, the object fetch), CGB_TDSEL_LATENCY (bit 4,
#    the bitplane reads) and CGB_MAP_LATENCY (bits 3 and 6, the map address) --
#    and each of those was derived on a family the whole-register form cannot
#    separate. CGB_MAP_LATENCY in particular takes gambatte's `bgtilemap`
#    28/40 -> 40/40, which is a family this table never moved at any setting of
#    the constant below, so the two are measuring different things.
#
#    All the window rows the whole-register form costs are late_disable /
#    late_reenable rows.
#    Those are the family SameBoy gives a CGB-ONLY fetcher-abort path (a window
#    disable part way through the fetch aborts it), which moves them the other
#    way; the +2 dots is not separable from the abort here, and adding it alone
#    is strictly worse. Implement the abort first, then re-run this table.
#
#    Re-measured 2026-08-03 (baseline 3618 with the HDMA source fix in):
#    CGB_LCDC_LATENCY=1 scores **3616, +3 / -5**. Every loss is a
#    `late_disable*` row and the gains are `late_reenable_scx3_2` plus two
#    `bgtilemap_spx08_ds` rows -- i.e. the latency shifts the WHOLE late_disable
#    family by one step rather than changing where inside it the answer flips,
#    which is the signature of a missing mechanism rather than a wrong constant,
#    and is the strongest evidence yet that the abort is the missing piece.
#    Ceiling if the abort lands is roughly ten gambatte rows plus two mealybug
#    rows -- and those two mealybug rows are wrong on BOTH devices, so the abort
#    is not purely a CGB behaviour and modelling it as CGB-only will not collect
#    all of it.
#  * WX / WY / the WY latch. **The "one whole FRAME" reading that used to be
#    here was WRONG, and it was measured out on 2026-08-03.** It said the
#    window/arg late_wy_* rows are not decided by the latch dot at all, because
#    the WY write and the window start land on the same dots on both devices,
#    and that dingbat's CGB run therefore reaches the ROM's vblank setup a frame
#    before its DMG run. The first half is true and the conclusion does not
#    follow from it: the split is in the ROMs' OWN EXPECTED VALUES.
#
#    Collapse the family with tools/gbppu/famflip.py and read the two devices
#    side by side. Of the 14 late_wy families scored on both devices, **13 have
#    different expectations per device**, and every one of the 13 is the same
#    one-M-cycle shift in the same direction:
#
#      late_wy_FFto2_ly2   dmg exp=3,3,0   cgb exp=3,0,0
#      late_wy_1toFF       dmg exp=0,0,3   cgb exp=0,3,3
#      ... and 11 more, including every FFto{0,1,2}_ly{0,2} and both 10to{0,1}
#
#    So HARDWARE differs by one M-cycle here and there is no frame-level mystery
#    to explain first. dingbat answers the SAME value on both devices in 11 of
#    the 14 -- it models no device difference at all -- which is the actual
#    defect and is worth ~26 rows.
#
#    Note the SIGN before reaching for a latency: the CGB expectation flips one
#    step EARLIER than the DMG one, so CGB samples WY sooner, not later. Every
#    constant in this block is a positive delay, which moves CGB the wrong way --
#    that, not the absence of an instrument, is why "WY / WY latch: nothing at
#    all" appears against every setting in the sweep table above. A negative
#    latency is not expressible here and the mechanism is probably not a write
#    latency at all.
const CGB_WX_LATENCY*         {.intdefine.} = 0
const CGB_WY_LATENCY*         {.intdefine.} = 0
const CGB_SCY_LATENCY*        {.intdefine.} = 2
const CGB_SCX_LATENCY*        {.intdefine.} = 2
const CGB_LCDC_LATENCY*       {.intdefine.} = 0
const CGB_LCDC_TDSEL_LATENCY* {.intdefine.} = 0
const CGB_OBJ_SIZE_LATENCY*   {.intdefine.} = 3
  ## Dots LCDC.2 takes to reach the OBJECT FETCH on CGB over the DMG -- the same
  ## shape as CGB_MIXER_LATENCY next door, for the one bit of LCDC an object
  ## fetch reads rather than the mixer. It is separate from CGB_LCDC_LATENCY
  ## because that one moves the whole register for every reader, and every
  ## nonzero setting of it costs gambatte rows (the table above).
  ##
  ## Derived and swept at OBJ_PLANE1_LAG in fifo_ppu.nim: the two
  ## `m3_lcdc_obj_size_change` ROMs disagree between their DMG and their CGB
  ## references on which bands come out mixed, and the disagreement is a clean
  ## three dots in the same direction on all six bands that separate them.
const CGB_OBJ_SCAN_LEAD*      {.intdefine.} = 2
  ## Dots before its own sample dot that a CGB's OAM SCAN takes a SECOND look at
  ## LCDC.2, keeping the object if either look puts it on the line. A different
  ## reader from CGB_OBJ_SIZE_LATENCY above -- that one is the object FETCH in
  ## mode 3, this one is the mode-2 range comparator -- and the two are measured
  ## by different families. Derived at fifo_get_sprites in fifo_ppu.nim off
  ## gambatte's `sprites/late_sizechange*`, where three objects (1, 9 and 39)
  ## each have a CGB cell that comes out 8x16 whichever way the write moved the
  ## bit, which no single sample dot can produce.
  ##
  ## Its SIGN agrees with CGB_OBJ_SIZE_LATENCY: both say the bit reaches the
  ## object logic later on a CGB than on a DMG.
const CGB_MAP_LATENCY*        {.intdefine.} = 2
  ## Dots LCDC.3 / LCDC.6 -- the two TILE MAP select bits -- take to reach the
  ## background fetcher's MAP ADDRESS read on a CGB over a DMG.
  ##
  ## The fourth member of the family above (CGB_OBJ_SIZE_LATENCY for LCDC.2 at
  ## the object fetch, CGB_TDSEL_LATENCY for LCDC.4 at the bitplane reads,
  ## CGB_LCDC_MIXER_LATENCY for the whole register at the mixer), and the same
  ## shape: a per-READER delay, not the whole-register write latency
  ## CGB_LCDC_LATENCY, which ships at 0 because every nonzero setting of it
  ## costs gambatte `window/late_disable*` rows that are a missing mechanism
  ## rather than a wrong dot.
  ##
  ## **Derived, not fitted, from the four mealybug `*map_change*` rows, and the
  ## DMG side pins the phase so the whole delta is the console.**
  ## `m3_lcdc_bg_map_change` and `m3_lcdc_win_map_change` are 23040/23040
  ## against their `_dmg_blob` references and were 384 and 182 pixels out
  ## against `_cgb_c`, at every revision C/D/E alike (the suite ships `_cgb_c`
  ## and `_cgb_d` captures for both and they are byte-identical, so this is not
  ## a revision axis).
  ##
  ## Both ROMs invert completely. Map `$9800` is filled with tile 0 and map
  ## `$9C00` with tile 1; tile 0 is all-`$00` and tile 1 all-`$FF`; BGP is the
  ## identity and SCX is 0. So **every 8-pixel tile column of the frame is one
  ## bit: which map the fetcher's B-stage read used**, and the handler
  ## (`line_0_fix`, 9 `nop`s, `ld [hl],c`, `ld [hl],b`) raises the bit for
  ## exactly 8 dots. Eighteen objects at `Y = $10 + 8k, X = k` sweep that pulse
  ## across the fetch grid one dot per 8-line band (see docs/gb-mealybug-
  ## sources.md §1.3), so one frame is eighteen readings of "which tile's map
  ## read fell inside the pulse". Reading the black column off both references
  ## per band, `X` = the band's OAM X:
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
  ## **Four independent edges and all four move by the same two bands in the
  ## same direction.** A band is a dot, so the pulse arrives at the map read
  ## two dots later on a CGB: at a given X the CGB catches a map read the DMG
  ## needs two more bands of object penalty to reach. (The `win_map` tile-1
  ## entry edge reads as one band only because X cannot go below 0 -- +2 puts
  ## it at X = -1, off the instrument, and nothing there contradicts +2.)
  ## dingbat before this constant answered the DMG schedule on both consoles,
  ## which is exactly the four bands that were wrong.
  ##
  ## Two dots is also the magnitude mealybug's own PPU documentation gives for
  ## the one CGB write latency it states outright -- *"writes will take effect
  ## immediately on the DMG. On CGB and AGB devices, writes appear to take
  ## effect 2 T-cycles later"* for SCY, which ships next door as
  ## CGB_SCY_LATENCY = 2. Bracketed on the instrument rather than assumed:
  ## 1 dot moves each edge one band and closes exactly half of each row
  ## (`m3_lcdc_bg_map_change` 384 -> 192 wrong pixels), 3 dots overshoots every
  ## edge by a band, and 2 is the only value that is pixel-exact on all four.
  ##
  ## **A second instrument, unconsulted while the value was derived, agrees on
  ## the same dot.** gambatte's `bgtilemap` family is 40 rows of exactly this
  ## write -- LCDC.3 moved inside mode 3 at SCX 8, 9 and $0A, four write dots
  ## each -- scored against reference images, and it went **28/40 -> 40/40**.
  ## Every one of the twelve it gained is a `[cgb]` row; the DMG half was
  ## already green and does not move. The bracket on that instrument matches
  ## mealybug's exactly:
  ##
  ##   CGB_MAP_LATENCY        0      1      2 (ship)    3
  ##   gambatte bgtilemap    28/40  32/40   40/40     32/40
  ##   mealybug CGB pixels  1863574 1865000 1866240  1864988  (of 1866240)
  ##
  ## Two instruments, one unique maximum, symmetric fall-off on both sides.
  ## At 2 the whole 27-row mealybug CGB set and the whole 24-row DMG set are
  ## pixel-exact, and every one of the four rows is exact at `--cgb-rev=` C, D
  ## and E against BOTH the `_cgb_c` and the `_cgb_d` capture.
  ##
  ## The same bracket at the level of the WHOLE runner, re-measured
  ## independently, which is the strongest form of it -- 3 is not merely worse
  ## than 2, it is worse than turning the rule off entirely:
  ##
  ##   CGB_MAP_LATENCY        0      1      2 (ship)    3
  ##   gambatte total        4246   4250    4258      4250   (of 5005)
  ##   runner Pass            919    919     924       916   (of 1106)
  ##
  ## Re-measuring that is a trap worth naming: dingbat_test_runner SHELLS OUT
  ## to ./dingbat_test, so `-d:CGB_MAP_LATENCY=N` has to go into THAT binary.
  ## Rebuilding only the runner scores every arm identically -- including the
  ## control -- and looks exactly like a knob that does nothing.
  ##
  ## **The latency is CPU-clock, and the double-speed rows prove it rather than
  ## assume it.** It is spent at the write (in ppu_store_lcdc), where the CPU's
  ## speed is known, as `max(0, CGB_MAP_LATENCY - current_speed)` -- so a
  ## double-speed M-cycle spends the delay inside itself. Built without the
  ## speed term, `bgtilemap` drops 40/40 -> 36/40 and all four losses are
  ## `_ds_` rows (`spx08_ds_1`, `spx08_ds_4`, `spx09_ds_1`, `spx09_ds_4`, each
  ## ~1000 pixels out). Same shape and same reason as CGB_TDSEL_LATENCY.
  ##
  ## Confined to the map-address read because that is the only reader the
  ## instrument sees. LCDC.3 and LCDC.6 have no other consumer in the fetcher,
  ## and gating them here rather than in the register keeps the whole-register
  ## `late_disable` question (CGB_LCDC_LATENCY, above) untouched.
  ##
  ## **Cost, named: +0.20% of retired instructions**, and it is the one compare
  ## in `fsGetTile`, not the fields. 23664502699 -> 23711427313 on dmg-acid2
  ## and 23782526967 -> 23829504665 on cgb-acid2, 2400 frames each, `cycles=`
  ## identical in both arms; the control arm is `-d:CGB_MAP_LATENCY=0`, which
  ## still carries `map_dot` and `map_old` in the object, so none of it is
  ## layout. A DMG pays it too -- the compare is gated at compile time, not at
  ## run time, and a runtime `ppu.cgb` test is one more load off the same cache
  ## line. That is the same bill CGB_TDSEL_LATENCY's rule pays for the same
  ## kind of per-fetch sample, and it buys 4 mealybug rows and 12 gambatte
  ## rows.
const CGB_TDSEL_LATENCY*      {.intdefine.} = 1
  ## Dots LCDC.4 takes to reach the BACKGROUND FETCHER on CGB over the DMG --
  ## the same shape as CGB_OBJ_SIZE_LATENCY above, for the one bit of LCDC a
  ## background bitplane read consults. Separate from CGB_LCDC_TDSEL_LATENCY
  ## for the same reason: that one is a WRITE latency and delays the whole
  ## register (the `run` chain in mem_apply_pipeline is monotonic, so a
  ## nonzero TDSEL latency drags the other six bits with it), and every nonzero
  ## setting of THAT costs three gambatte `window` rows.
  ##
  ## **The DMG is exactly right, so this is a real CGB delta and not a phase
  ## error being absorbed.** `m3_lcdc_tile_sel_change` and
  ## `m3_lcdc_tile_sel_win_change` are 23040/23040 against their `_dmg_blob`
  ## references, and each is eighteen independent measurements of this
  ## register's write dot against the fetch cycle (their objects sweep OAM
  ## X = 0..17 down the screen, one band each, so each band moves the write by
  ## a dot inside the fetch).
  ##
  ## Derived off `m3_lcdc_tile_sel_change2`'s CGB reference, which is the same
  ## instrument with a picture that reads out the bytes: its background is
  ## `ABCDEFGH...` on map rows 0..7 with LCDC.4 = 0, and only $9490 (where `I`
  ## lives in the $8800 region) is initialised -- so every 8 aligned pixels of
  ## the frame invert through BGP = $E4 into one (plane 0, plane 1) pair and
  ## name the tile and plane hardware read. Its handler is
  ## `ld [hl],c / ld [hl],b` three times over, so LCDC.4 goes up and down on a
  ## 8-dot lattice and the tile columns it lands on are 2/3, 5/6 and 8/9.
  ## Reading column 2 (the first SET) per band, with the fetch's two reads at
  ## p0 and p0 + 2:
  ##
  ##   band   hardware              dingbat at latency 0
  ##   0..2   C.0 / C.1             C.0 / C.1        write at or before p0
  ##   3      <glitch> / C.1        C.0 / C.1        write ON p0 (hardware)
  ##   4      $00 / C.1             C.0 / C.1        write at p0 + 1
  ##   5      $00 / <glitch>        $00 / C.1        write ON p1 (hardware)
  ##   6      $00 / $00             $00 / C.1
  ##   7      $00 / $00             $00 / $00
  ##
  ## The bands step the write by exactly one dot each (the ROM's own comment:
  ## "sprites are positioned to cause the write to occur on different T-cycles
  ## of the background tile fetch"), and hardware's write reaches the fetcher
  ## one band later than dingbat's throughout. One dot, bracketed from both
  ## sides, on a row whose DMG twin is pixel-exact.
  ##
  ## Independently: it is also the only value that puts `cgb-acid-hell`'s
  ## anomaly on the plane it is observed on. That ROM writes LCDC every 8 dots
  ## at dot 8n+1 with the bitplane reads at 8n+0 and 8n+2, so 0 puts the change
  ## between the two reads, -1 on the low plane, and only +1 on the high one.
  ##
  ## ---- 2026-08-10: the one quantity `CGB_PIPE_MCYCLES` does NOT resolve -----
  ##
  ## Advancing the CGB pipeline one M-cycle moves this register's write four
  ## dots around the ROM's own 8-dot fetch lattice, so the arithmetic above says
  ## the compensated value is 1 + 4 = **5**. It is not takeable, and the reason
  ## is that this constant's two witnesses do not share an anchor:
  ##
  ##   * the four mealybug `tile_sel` frames sync on **mode 2**, which moves with
  ##     the pipeline (`STAT_M2_LEAD_CGB`), so their write lands where it always
  ##     did and they want **1**;
  ##   * `cgb-acid-hell` syncs on **LYC**, which does not move, so its write
  ##     lands four dots later on the lattice and it wants **5**.
  ##
  ## Both are CGB, both are this register, and one constant cannot be both. It
  ## is a strict two-sided bracket and it is measured, world against world, with
  ## no reference image in the loop:
  ##
  ##   value   mealybug tile_sel CGB (4 frames)      cgb-acid-hell
  ##   1 ship  byte-identical to the pre-advance     23038/23040
  ##   5       3859 wrong px (1468 + 1525 + 866)     byte-identical
  ##
  ## **1 ships because it costs 2 pixels and 5 costs 3859.**
  ##
  ## *(Correction, 2026-08-10: an earlier revision of this note claimed the
  ## shipping SET rule "already scores 221/223 on the pre-advance tree", i.e.
  ## that these two cells were a standing rule gap. That misread the corpus
  ## table. On the pre-advance tree the SHIPPING rule scores **223/223**; the
  ## 221/223 row is `never`, the rule with `CGB_TDSEL_IDX_DOTS` deleted, and its
  ## two misses are precisely the cells that PROVE that constant. There is no
  ## SET-rule gap. The residue is the phase moving acid-hell's write off the
  ## read dot, and `CGB_TDSEL_IDX_DOTS`'s note carries the read-level bracket
  ## showing no refinement recovers it without costing 64 mealybug reads.)*
  ##
  ## The four mealybug frames score identically before and after the advance
  ## (48/64, 48/48, 72/32, 48/48, all with 0 self-check mismatches), so the cell
  ## alignment did not move.
  ##
  ## Note also that `cgb-acid-hell`'s reference is a **C/E-class** capture: it is
  ## exact at `--cgb-rev=C` and `=E` and 22864/23040 at `=D` on the pre-advance
  ## tree, where daid's `.gbc.png` is a D-class capture. Two ROMs, two machines.
const CGB_TDSEL_GLITCH*       {.booldefine.} = true
  ## Whether an LCDC.4 change that lands ON a background bitplane read glitches
  ## it, and with what. mealybug's PPU notes describe the effect; what the
  ## `m3_lcdc_tile_sel_change2` decode above adds is which branch fires when,
  ## because the frame names the byte. Reading all six affected columns of that
  ## reference, glitched cells only (`IDX` = the tile index, `spr.1` = the
  ## object's bitplane 1, `X.p` = tile X's plane p):
  ##
  ##   band   col2 SET   col3 RST   col5 SET   col6 RST   col8 SET   col9 RST
  ##   3      '3'.1      IDX        D.0        IDX        G.0        IDX
  ##   5      '5'.1      IDX        D.1        IDX        G.1        IDX
  ##
  ## Two rules, and neither has a free parameter:
  ##
  ##  * a RESET on the read dot delivers the TILE INDEX as that bitplane's
  ##    byte. Columns 3, 6 and 9 hold `D`, `G` and `J`, and the bytes are $44,
  ##    $47 and $4A down the whole band -- constant against the row, which no
  ##    tile-data read can be. This is the notes' "resetting TILE_SEL on the
  ##    same T-cycle as a bitplane data read will cause the tile index to be
  ##    instead used as the data for that bitplane", verbatim.
  ##  * a SET on the read dot delivers the byte at the address of the most
  ##    recent $8000-REGION tile-data read. The object fetch's last read is its
  ##    bitplane 1, which is why the first glitch of a line reports the
  ##    object's plane 1 at EITHER plane (band 3 is a plane-0 glitch and band 5
  ##    a plane-1 one, and both give the digit's plane 1); after that the
  ##    RESET-glitched read has driven its own $8000-region address, which is
  ##    why col 5 reports `D` -- column 3's tile -- and col 8 reports `G`,
  ##    column 6's, each at the plane the glitch is on. The notes list both as
  ##    alternatives ("bitplane 1 data from the most recently drawn sprite, if
  ##    any, or bitplane 1 data from the most recently drawn tile as when
  ##    TILE_SEL was last reset, if any") without saying which fires; the
  ##    address latch is the one mechanism that produces both.
  ##
  ## ---- What writes the address latch, and when it is cleared (2026-08-11) ---
  ##
  ## `*_change2` cannot see either question: every SET glitch in those two
  ## frames is preceded, on its own line, by an object fetch or a RESET-glitched
  ## read. The two ROMs that CAN see them are the plain `m3_lcdc_tile_sel_change`
  ## and `m3_lcdc_tile_sel_win_change` on CGB, and they were this pair's whole
  ## residual (232 and 1422 wrong subpixels; both are 23040/23040 now). Scoring
  ## the four CGB references' glitched reads by the byte each one pins -- 188
  ## RESET cells and 161 SET cells, all eight bits of every one fixed by its
  ## tile's eight pixels:
  ##
  ##   latch written by                     cleared per line   SET cells right
  ##   obj + RESET-glitched reads           yes                 133 / 161
  ##   + every unglitched LCDC.4 = 1 read   yes                 133 / 161
  ##   obj + RESET-glitched reads           no                  158 / 161
  ##   + every unglitched LCDC.4 = 1 read   no                  159 / 161
  ##
  ## So both arms are separately forced, and neither is a fitted number:
  ##
  ##  * the latch is a bus register and H-Blank does not clear it.
  ##    `m3_lcdc_tile_sel_change` puts its LCDC write at dot 105 and its object
  ##    at 112, so the first glitched read of each of its lines happens before
  ##    anything on that line has driven an $8000-region address, and hardware
  ##    still substitutes -- with the byte the line ABOVE left there. That is
  ##    the 133 -> 158, and it is both rows' entire residual bar 8 pixels.
  ##  * an UNGLITCHED LCDC.4 = 1 read is an $8000-region access like any other
  ##    and leaves its address here too. That is the last cell, 158 -> 159:
  ##    `m3_lcdc_tile_sel_win_change`'s 8 remaining pixels, one glitched tile
  ##    whose line has a plain unsigned read after its object and before its
  ##    glitch.
  ##
  ## A plain DATA latch (the last $8000-region BYTE rather than its address) is
  ## refuted, and by a whole band rather than a cell: it scores 89/161, because
  ## `*_change2`'s two bands glitch on different PLANES and hardware answers
  ## with the same tile at the plane the glitch is on (`D.0` in band 3 and `D.1`
  ## in band 5, above). Only an address can do that. It is worth knowing that
  ## this is where the two disagree, because a data latch is the cheaper thing
  ## to implement and it is what the notes' wording suggests.
  ##
  ## `cgb-acid-hell`'s two pixels are the ONE exception, and they are
  ## CGB_TDSEL_IDX_DOTS below: a SET glitch close behind a RESET one delivers
  ## the index instead. Every other SET cell in the tree is this rule.
const CGB_TDSEL_IDX_DOTS*     {.intdefine.} = 8
  ## How long a RESET glitch leaves the INDEX path armed, in dots. A SET glitch
  ## that lands inside that window delivers the CURRENT tile's index -- the same
  ## byte a RESET glitch delivers -- instead of the address latch above. 0 is
  ## the control build, where a SET is always the latch.
  ##
  ## This is the whole of `cgb-acid-hell`'s residual and it is the only thing in
  ## the tree that fires it. What follows is what the corpus proves and what it
  ## does not, because those are different sizes.
  ##
  ## ---- What the corpus proves ---------------------------------------------
  ##
  ## Scored over the same instrument as the SET rule above -- every glitched
  ## bitplane read of the four CGB `tile_sel` references and `cgb-acid-hell`
  ## whose bits the reference PNG pins, rebuilt 2026-08-12 as 192 RESET cells
  ## and 223 SET cells (184 / 151 of them with all eight bits pinned; the
  ## earlier 188 / 161 census used a pinning convention that was not written
  ## down, and this one is a superset of it either way). Cells, not pixels, so
  ## a rule that is wrong under an object or in a four-shades-of-white palette
  ## is still counted wrong:
  ##
  ##   SET-branch trigger for "deliver the index"        SET cells right
  ##   never (the rule above, alone)                        221 / 223
  ##   always                                               125 / 223
  ##   the latch was written by a RESET glitch, any age     158 / 223
  ##   the IMMEDIATELY preceding read was RESET-glitched    221 / 223
  ##   the latch is <= 8 dots old, whatever wrote it        215 / 223
  ##   a RESET glitch landed <= 8 dots ago                  223 / 223
  ##   ...and it wrote the latch, i.e. nothing since  <--   223 / 223
  ##
  ## So the trigger has two halves and the corpus forces both, each by a whole
  ## band rather than a cell:
  ##
  ##  * **It is not recency alone.** `*_change2`'s first glitch of a line has an
  ##    OBJECT fetch 8 dots behind it and wants the LATCH (the object's bitplane
  ##    1). 8 cells, and they are why the window is armed by a RESET GLITCH and
  ##    not by the last $8000-region read.
  ##  * **It is not provenance alone.** `*_change2`'s columns 5 and 8 are SET
  ##    glitches whose latch was written by the RESET glitch two tile columns
  ##    back, and they want the LATCH. 64 cells, and they are why the window is
  ##    short.
  ##  * **It is not "the immediately preceding read".** `cgb-acid-hell` toggles
  ##    LCDC.4 every 8 dots, so its RESET glitch is the previous FETCH's read of
  ##    the same plane and an unglitched signed read sits between the two. That
  ##    spelling scores 221/223 -- it misses the two pixels it was written for.
  ##
  ## The window is bracketed to **8..15 dots** and nothing narrows it further:
  ## 7 loses `cgb-acid-hell`'s cells (its RESET glitch is exactly 8 dots back)
  ## and 16 breaks `*_change2`'s 64 (theirs is exactly 16). 8 is the fetch
  ## cycle's own pitch, which is the only number in that range the hardware has
  ## a name for, so the rule reads "the RESET glitch was in this fetch or the
  ## one before it". Measured in dots and not in reads deliberately: the two
  ## agree wherever the fetcher runs at pitch and the corpus scores 223/223
  ## either way, and dots need no counter.
  ##
  ## The last row of the table is what ships, and it is the last row because it
  ## is what the PACKING gives for free -- the arming rides `tdsel_addr` above
  ## the bank (TDSEL_IDX_SHIFT), so anything that writes the latch disarms it.
  ## The looser row is the same 223/223 and no cell separates the two.
  ##
  ## ---- What the corpus does NOT prove -------------------------------------
  ##
  ## **The distinguishing bucket is populated by one ROM.** At every setting in
  ## 8..15 the trigger fires on exactly seven cells, all of them
  ## `cgb-acid-hell`'s, and it changes no other pixel of any frame in this tree.
  ## The other 216 SET cells prove the rule is CONSISTENT with everything else
  ## measured; they do not vote on the trigger's shape, because none of them is
  ## in the bucket. Five of the seven are cells where the index and the latch
  ## happen to hold the same byte, so the ROM's own arbitrating evidence is two
  ## pixels -- `(80, 68)` and `(80, 69)`, both hardware-photo-verified against
  ## the repo's `img/photo.jpg` as well as the bundled PNG.
  ##
  ## **The experiment that would settle it does not exist.** It is a hardware
  ## capture of `m3_lcdc_tile_sel_change2` with its LCDC writes moved onto an
  ## 8-dot lattice, or equivalently any second ROM that puts a SET glitch one
  ## fetch behind a RESET one. mealybug's `*_change2` pair are the only ROMs
  ## with the readout and their handler writes on a 16-dot pitch, which is why
  ## the corpus has a gap exactly where the trigger lives.
  ##
  ## **And the corpus does not arbitrate against the one alternative, either.**
  ## The alternative is not another substitution source, it is one M-cycle of
  ## CGB halt phase: put the CPU 8 dots later (`CGB_HALT_PPU_LEAD=2`) and this
  ## ROM's glitching write becomes the RESET one 8 dots earlier, the seven cells
  ## move to the RESET column, and `CGB_TDSEL_IDX_DOTS=0` scores **216/216 SET
  ## and 199/199 RESET with `cgb-acid-hell` at 23040/23040** -- a strictly
  ## simpler model that needs nothing on this line at all. Measured 2026-08-13,
  ## and it is why the shipping rule rests on the halt bracket and not on the
  ## corpus: `halt/lycirq_m2stat_{1,2}` and `halt/m1int_ly_{1,2}` are green
  ## together only at `LEAD` 0 or 1 and the `_1` members go red at 2, and
  ## `lycirq_*` is this ROM's own IME-clear path. The commented disassembly at
  ## github.com/CelestialAmber/cgb-acid-hell reads the ROM the other way and
  ## says the reset rule is the whole trick; its own dot arithmetic lands on the
  ## SET once the 6-dot object delay it documents is applied, and that 6 dots is
  ## `objtab.py`'s hardware table (153/153 cells). Full account, both sides, in
  ## docs/gb-failure-triage.md's 2026-08-13 entry -- read it before changing
  ## anything here.
  ##
  ## **The world in between was measured on 2026-08-14 and has no rule at all.**
  ## At `CGB_HALT_PPU_LEAD=1` -- the value the halt bracket actually wants --
  ## this ROM's write lattice moves 4 dots, into the tile-MAP slot, and NO
  ## bitplane read of the frame has an LCDC.4 change on its dot: the census
  ## drops to 408 cells (216 SET / 192 RESET, still 216/216 and 192/192 under
  ## the rules above), this constant fires on nothing at any window in 0..19,
  ## and the row is 23038 whatever it is set to. A rule that fired in the map
  ## slot instead is refused by 48 `*_change2` cells in the identical bucket,
  ## and the one context that separates them is bracketed from both sides.
  ## `tools/gbppu/tdselphase.py` is that instrument -- every pinned bitplane
  ## read by its offset from the last change, where hardware disturbs exactly
  ## one offset out of the 6352 measured. So this constant is not what stands
  ## between the tree and `LEAD=1`; 4 dots are.
  ##
  ## ---- 2026-08-10: `CGB_PIPE_MCYCLES = 1` lands in that same world ---------
  ##
  ## The shipped CGB pipeline advance moves this ROM's write lattice by the same
  ## 4 dots `CGB_HALT_PPU_LEAD=1` did, for the same reason: `cgb-acid-hell` and
  ## daid `ppu_scanline_bgp` are both anchored on the LYC=0 STAT taken out of
  ## `halt` (read both ROMs' sources -- acid-hell sets `rSTAT=$40`, `rLYC=0`,
  ## `rIE=$02` and halts), so an advance that moves the FETCH GRID leaves both
  ## ROMs' writes where they were. The census reproduces the 2026-08-14 entry
  ## above **exactly**: 408 cells, 216 SET / 192 RESET, 216/216 and 192/192, and
  ## the row at 23038 whatever this constant is set to.
  ##
  ## **Two consequences, and the second one is the one to carry forward.**
  ##
  ## First, the trade is bounded and small. `CGB_TDSEL_LATENCY = 5` puts the
  ## lattice back and takes `cgb-acid-hell` to 23040 -- and costs the four
  ## mealybug frames 3859 pixels, because their writes DID move with their
  ## mode-2 anchor. 1 ships. Two pixels against 3859.
  ##
  ## Second, **this constant now has no evidence at all in the shipping world**,
  ## and that is a fact about the corpus rather than about the rule. With
  ## acid-hell's seven cells gone, every trigger hypothesis in the table above
  ## -- including `never`, i.e. deleting this constant outright -- scores the
  ## same 216/216. The rule is still believed (it is what the 223/223 world
  ## measured, and the 2026-08-14 offset sweep is unchanged) but nothing in the
  ## tree can now falsify it. Do not read "216/216" as support.
  ##
  ## **And the read-level bracket, which is what a refinement would have to
  ## beat.** `tools/gbppu/tdselphase.py` in this world splits the one bucket
  ## that could fix the row -- `mapoff=0`, read offset +4, RESET, 71 reads -- by
  ## the change BEFORE the previous one:
  ##
  ##   prev2off   reads   hardware wants INDEX   hardware wants SGN   ROM
  ##   -32            7                      7                    5   acid-hell
  ##   -24           32                      0                   32   mealybug
  ##   None          24                      8                   24   mealybug
  ##   (prevdir -1)   8                      8                    8   mealybug
  ##
  ## Firing on the whole bucket buys acid-hell's 2 and costs **64 mealybug
  ## reads**. The only feature that separates acid-hell's seven from the 32 hard
  ## refusers is `prev2off = -32` against `-24` -- one ROM's own fingerprint, on
  ## a context no second ROM populates. So there is no refinement here that is
  ## not a fit, and the 2 pixels are an integration decision, not a modelling
  ## one.
  ##
  ## **A revision split is excluded, not merely unsupported.** `cgb-acid-hell`
  ## picks its tile data off a `$FEA0` readback and dingbat takes the same
  ## branch the bundled reference was captured on, which is a CGB-C -- the same
  ## device every `*_change2` reference is. See the 2026-08-10 entry in
  ## docs/gb-failure-triage.md.
  ##
  ## `$FEA0..$FEFF` IS now modelled per revision (GbUnusableRegion), and the
  ## re-score this note used to ask for was done in that commit: the row is
  ## 23040/23040 on revisions 0/A/B/C/E and on the default, and 22864/23040 on
  ## D alone, which is the ROM refusing CGB-D on purpose. The branch dingbat
  ## takes by default is unchanged -- it is now taken because a C-class machine
  ## reads `$44` back, rather than because the region was not modelled -- so
  ## the exclusion above still holds, and now holds for a reason.
  ##
  ## What the rule assumes beyond the two pixels is deliberately as little as
  ## possible: the window is not consumed by the SET glitch that uses it (no
  ## cell has two SET glitches behind one RESET), the substituted byte is the
  ## CURRENT tile's index and not the RESET-glitched tile's (the reference says
  ## so: on line 68 the tile is `$55` and hardware's byte is `$55`, while the
  ## RESET-glitched tile one fetch back is `$59`), and the address latch is left
  ## exactly as the rule above leaves it.
  ##
  ## Cost, `tools/gbppu/counters.sh` against the commit before it, retired
  ## instructions over repeated runs: **+0.05..0.08% Pokemon Crystal, +0.02%
  ## blargg cpu_instrs, +0.05% Link's Awakening DX** -- effectively the one
  ## guarded compare per line in fifo_reset_sprite, since the arming rides a
  ## store the RESET branch already did and the dot loop never sees the rule at
  ## all. The unpacked shape, with the same behaviour, was +0.30% / +0.21% /
  ## +0.22%; see TDSEL_IDX_SHIFT for where that went.
const CGB_TDSEL_ANY* = CGB_TDSEL_LATENCY != 0 or CGB_TDSEL_GLITCH
const CGB_MAP_ANY* = CGB_MAP_LATENCY != 0
  ## Whether anything records the map-select bits' change dot. `-d:CGB_MAP_
  ## LATENCY=0` is the control build and reproduces the pre-2026-08-19 numbers
  ## exactly: the field is never written, the fetcher's compare never takes.
const CGB_WY_LATCH_LATENCY*   {.intdefine.} = 0
const WIN_EN_ABORT*           {.intdefine.} = 1
  ## Whether clearing LCDC.5 mid-mode-3 returns the fetcher to background
  ## tiles on this line. 1 ships; 0 is the control build and restores the old
  ## behaviour, where `fetching_window` could not be cleared before the next
  ## line. See the site in tick_bg_fetcher for the rule and the citation.
  ##
  ## It is DMG behaviour, not a CGB one. mealybug documents it in its PPU notes
  ## and measures it with two ROMs whose scored references are `_dmg_blob`, and
  ## dingbat used to file it as SameBoy's CGB-only fetcher abort and not model
  ## it at all. Worth, on its own: mealybug m3_lcdc_win_en_change_multiple
  ## 8874 wrong pixels -> 0 (DMG and CGB both), m3_lcdc_win_en_change_multiple_wx
  ## 4215 -> 343, DMG total +12746 and CGB +25758, and three gambatte
  ## window/on_screen rows -- weon_wx18_weoff_weon_wx80 on both devices and
  ## wx17_weoff_wxA5_weon on DMG, which are that mechanism by name.
const WIN_EN_HOLD*            {.intdefine.} = 2
  ## Dots a WX match that LCDC.5 refused stays live, waiting for the bit. 0 is
  ## the control build and the pre-2026-08-09 behaviour: a match with LCDC.5
  ## low is simply dropped and only a later match can start the window.
  ##
  ## ---- What refuses the two obvious readings ------------------------------
  ##
  ## mealybug `m3_lcdc_win_en_change_multiple_wx` is the ruler. It writes
  ## WX = LY, then clears LCDC.5 over dots 97..104 of every line and again over
  ## 125..132, so the window's trigger pixel `t = LY - 7` walks one dot per line
  ## straight through both pulses and the frame reads out, once per scanline,
  ## what a match at each offset from the pulse does. Its reference:
  ##
  ##   t (band 1)      0    1  2  3..7    8      9     10     11
  ##   match dot      94   95 96 97..101 102    103    104    105
  ##   reference     x=0   -- -- --      one    x=10   x=10   x=11
  ##                                     white
  ##
  ## and band 2 (pulse at 125..132) repeats it at t = 28..39. Two readings are
  ## refused outright by the two ends of that table. The bit sampled at the
  ## match dot alone (`WIN_EN_HOLD = 0`) draws nothing at t = 9 and t = 10,
  ## where hardware draws a whole window -- 296 wrong pixels. The bit sampled at
  ## the fetcher's tile-map read instead, two dots later, gets every band edge
  ## right but has to RESTART the fetch before it knows the answer, and that is
  ## refused from the other side: gambatte `window/late_disable_*`,
  ## `late_reenable_*` and 36 `sprites/space/*` rows read STAT expecting mode 0
  ## and get mode 3, because the restart the abort then undoes still costs the
  ## line six dots (measured: gambatte 3827 -> 3750, window -40). Hardware pays
  ## nothing for a match it refuses.
  ##
  ## ---- What the table says instead ----------------------------------------
  ##
  ## The match is not dropped and it is not committed: it WAITS. Two dots of
  ## wait is what the table brackets, from both ends of both bands at once --
  ## t = 9's match waits two dots for the bit and t = 8's, one dot earlier,
  ## expires unserved. Two, not three: t = 8 would be served at three. And the
  ## window then starts on the dot the bit arrives, not on the dot it matched,
  ## which is why t = 9 and t = 10 both draw from x = 10 (band 2: t = 37 and
  ## t = 38 both from x = 38) -- one pixel right of where t = 9's own match was.
  ## That coincidence is the sharpest thing in the row: two adjacent scanlines
  ## whose windows begin at the same x, which no rule that starts the window at
  ## its own match pixel can produce.
  ##
  ## Worth 296 wrong pixels -> 4 on that row. Nothing else in the mealybug set
  ## moves and no gambatte row does either: a refused match costs no dots (the
  ## shifter is not stalled while the hold runs), so every family above keeps
  ## the length it had.
const CGB_WIN_EN_HOLD*        {.intdefine.} = 0
  ## WIN_EN_HOLD on a CGB, which is not the same number. The evidence is thin
  ## on purpose: mealybug's `_cgb_c` reference for the row above is already
  ## pixel-exact with no hold at all and stays exact with one, so it says
  ## nothing, and the only instrument that separates the devices is gambatte
  ## `window/late_reenable_scx5_2` -- one ROM, whose DMG half wants mode 3 still
  ## running at the read (which is the hold, and which goes green with it) and
  ## whose CGB half wants mode 0 (which is no hold). `late_reenable_scx2_2` is
  ## the same pair one SCX apart and says the same thing, and
  ## `window/late_enable_ly0_ds_2` refuses a hold on CGB from the second
  ## direction. So: DMG holds, CGB does not, and this is the constant that
  ## would move if a CGB ruler ever turns up.
const WIN_EN_HOLD_BACK*       {.intdefine.} = 1
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

const SCX_LIVE_BORROW_LATCHED* {.booldefine.} = true
  ## Whether `SCX_FINE_BORROW`'s carry is measured against the fine scroll the
  ## LINE LATCHED even after `SCX_FINE_LATCH_LIVE` has moved the live discard
  ## target. `true` ships since 2026-08-20; `false` is the behaviour before it,
  ## where both mechanisms wrote and read one `scx_fine` and the carry could
  ## never fire again after any store that joined the discard. Declared here
  ## rather than in fifo_ppu.nim for the same reason its two neighbours are:
  ## `GbFifoPpu` grows a field only when it is on.
  ##
  ## Worth gambatte +16 / -0 -- every `scx_during_m3` row of the `scx_0360c0`
  ## and `scx_0761c0` directories, both devices and both speeds. The derivation
  ## and the per-row pixel counts are at this constant's note in gb/fifo_ppu.nim.

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
    when IF_READ_SAMPLE_T < 4:
      # $FF0F as it stood at this M-cycle's latch point. See IF_READ_SAMPLE_T
      # above and the write-up at irq_read in interrupts.nim.
      if_prev*:          uint8

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
    master_clock*:   bool    # the half-rate shift clock: the divider tap runs
                             # at 2x the bit rate and TOGGLES this; a bit is
                             # shifted only on its high->low half (serial.nim)
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
    # The dot the owed block's mode-0 edge fell on. See
    # HDMA_DISABLE_GRACE_DOTS. Live only alongside hdma_block_due, so like it
    # this is never set at a frame boundary and is not serialized.
    hdma_due_dot*: int32
    # A speed switch is in flight and the next mode-0 edge within
    # HDMA_SPEEDSWITCH_KILL_W dots of it destroys the armed transfer instead of
    # owing it a block. Live only across the STOP's own stall, so like
    # hdma_block_due it can never be set at a frame boundary and is not
    # serialized. -1 = no switch pending.
    hdma_kill_from*: int32
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
      # The discard target as the live window has MOVED it, which is not the
      # same quantity as `scx_fine` above even though the two start the line
      # equal: that one is the carry's reference and stands for the whole
      # line. They shared one field until 2026-08-20 and the carry could not
      # fire again after any store that joined the discard -- see
      # SCX_LIVE_BORROW_LATCHED in fifo_ppu.nim. Sits here, inside the same
      # `when` as the field it belongs to, so a build with the mechanism off
      # is byte-identical to not having it.
      when SCX_LIVE_BORROW_LATCHED:
        scx_live_fine*:   int32
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
