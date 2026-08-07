# GB/GBC emulator main file
# All types are declared here; implementation files are `include`d.

import std/[bitops, os, strutils, times]
import ../common/[input, scheduler, emu, resampler, serialize, timestretch, cheats]
import ../common/lut_macros
when defined(test_harness):
  import ../common/test_output

# The two open axes of the STAT model, declared here rather than next to their
# write-up in gb/ppu.nim only because the GbPpu fields they gate are in the type
# block below. Both ship at the value that needs no field and no branch, so the
# shipping build is exactly the tree without them. See ppu.nim for what they
# mean, the equation that motivated them, and the measured table that rejected
# every setting but this one.
const STAT_IRQ_LEAD* {.intdefine.} = 0
const STAT_READ_LAG* {.intdefine.} = 3
const STAT_IRQ_SPLIT* = STAT_IRQ_LEAD != 0
const STAT_READ_HOLD* = STAT_READ_LAG != 3

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
#  * LCDC. All the window rows it costs are late_disable / late_reenable rows.
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
const CGB_WY_LATCH_LATENCY*   {.intdefine.} = 0
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
    rtc_latch_prev*:     uint8
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
    cached_hl*:  int   # -1 = invalid

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
    # window state
    window_trigger*:     bool
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
    first_line*:         bool
    when LCD_ON_TRIM_ANY:
      lcdon_lines*:      uint8   # lines left in the LCD-on trim window
    cycle_counter*:      int32
    # STAT mode bits as observed by a CPU read. A read M-cycle samples the bus
    # value at the START of the cycle, but the emulator ticks the PPU forward by
    # the whole M-cycle before read_byte runs; this latch snapshots the mode at
    # each tick entry so STAT reads see the pre-advance mode (mooneye
    # intr_2_mode0/mode3_timing, which read STAT one M-cycle after the mode-2
    # interrupt and must still observe the old mode).
    #
    # Bit 7 (LY_JUST_CHANGED) rides along in the same byte: it is set by an LY
    # advance and cleared by the next tick's snapshot, i.e. it marks "LY changed
    # during the M-cycle this read belongs to". Packing it here rather than into
    # its own field keeps the per-M-cycle cost at the one store the latch
    # already paid. See ppu_read 0xFF41 for what it suppresses.
    read_mode*:          uint8
    # ---- Sweep scratch: the STAT model's two open axes ---------------------
    # Both groups are gone from the shipping build -- the knobs that gate them
    # ship at the values that need neither, so GbPpu's layout is untouched by
    # their existing. See the write-up at STAT_IRQ_LEAD in ppu.nim, which is
    # also where the measurements that rejected both live.
    when STAT_IRQ_SPLIT:
      # The mode and LY the STAT interrupt SOURCES compare against, as opposed
      # to the ones the CPU reads back out of lcd_status/LY. Not serialized:
      # re-derived from the flag domain on load (load_ppu_state), which is
      # exact at the VBlank a state is captured at.
      irq_mode*:         uint8
      irq_ly*:           uint8
    when STAT_READ_HOLD:
      # How long a mode change stays invisible to a STAT read: the dot up to
      # which `stat_hold_mode` is still what a read returns, or 0 for none.
      # Rebased by the line wrap rather than maintained per tick.
      stat_hold_until*:  int32
      stat_hold_mode*:   uint8
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

  GbScanlinePpu* = ref object of GbPpu
    scanline_color_vals*: array[160, tuple[color: uint8, priority: bool]]

  FetchStage* = enum
    fsSleep, fsGetTile, fsGetTileDataLow, fsGetTileDataHigh, fsPushPixel

  GbFifoPpu* = ref object of GbPpu
    fifo*:                GbPixelFifo
    fifo_sprite*:         GbPixelFifo
    fetch_counter*:       int
    fetcher_x*:           int
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
    fetching_window*:     bool
    fetching_sprite*:     bool
    # Dots left in the object fetch the shifter is stalled on, and which BG
    # tile last paid the "wait for the BG fetch" half of an object's penalty.
    # Both are the OBJ penalty algorithm's state; see tick_shifter's trigger.
    obj_penalty*:         int32
    obj_tile_fx*:         int32
    # Idle dots left at the head of mode 3 (the pipeline's lead over the CPU's
    # register view; see M3_PIPE_DELAY in fifo_ppu). A byte, not an int, and
    # for one reason: the mode 3 branch of fifo_tick_slow's dot loop asks
    # "is the head spent?" once per M-cycle of mode 3 -- ~6,200 times a frame
    # -- and a byte answers it in `ldrb`+`cbz` where a signed int needs
    # `ldr`+`cmp`+`b.le`. The value is 0..12 by construction (M3_PIPE_MCYCLES
    # * 4 + M3_PIPE_DELAY).
    m3_delay*:            uint8
    # How far the pipeline lags the CPU's view of the PPU registers on THIS
    # line, in dots. Latched at the mode 2 -> 3 edge because the CPU M-cycle it
    # is derived from is 4 dots at normal speed and 2 in double speed. See
    # M3_PIPE_MCYCLES in fifo_ppu.
    m3_lead*:             int32
    tile_num*:            uint8
    tile_attrs*:          uint8
    tile_data_low*:       uint8
    tile_data_high*:      uint8
    sprites*:             seq[GbSprite]

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

  GbChannel1* = ref object of GbVolumeEnvChannel
    wave_duty_position*: int
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
    duty*:               uint8
    length_load*:        uint8
    frequency*:          uint16

  GbChannel2* = ref object of GbVolumeEnvChannel
    wave_duty_position*: int
    next_step*:          CycleCount   # see GbChannel1.next_step
    duty*:               uint8
    length_load*:        uint8
    frequency*:          uint16

  GbChannel3* = ref object of GbSoundChannel
    next_step*:              CycleCount   # see GbChannel1.next_step
    wave_ram*:               array[16, uint8]
    wave_ram_position*:      uint8
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

  GbApu* = ref object
    sound_enabled*:       bool
    buffer*:              seq[float32]
    buffer_pos*:          int
    frame_sequencer_stage*: int
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
    hram*:                 array[0x7F, uint8]
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
const FETCHER_ORDER*: array[8, FetchStage] = [
  fsSleep, fsGetTile, fsSleep, fsGetTileDataLow,
  fsSleep, fsGetTileDataHigh, fsSleep, fsPushPixel,
]

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

proc mbc_ram_offset*(idx: int): int = idx - 0xA000

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
  proc get_u32(data: string; off: int): uint32 =
    for i in 0 .. 3: result = result or (uint32(data[off + i]) shl (8 * i))
  let base = cart.ram.len
  let extra = data.len - base
  if extra < 44: return  # no footer
  for i in 0 .. 4: cart.rtc_live[i]    = uint8(get_u32(data, base + i * 4) and 0xFF)
  for i in 0 .. 4: cart.rtc_latched[i] = uint8(get_u32(data, base + 20 + i * 4) and 0xFF)
  var ts: int64 = int64(get_u32(data, base + 40))
  if extra >= 48:
    ts = ts or (int64(get_u32(data, base + 44)) shl 32)
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
  if data.len - base < HUC3_FOOTER_LEN: return  # RAM-only save: keep the power-on clock
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
  if data.len - base < TAMA5_FOOTER_LEN: return  # RAM-only save: keep the seeded clock
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
  if data.len - base < MBC6_FOOTER_LEN: return  # RAM-only save: keep blank flash
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
# Forward declarations needed by ppu.nim (defined in memory.nim included later)
proc mem_tick_components*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true; ignore_speed = false) {.inline.}
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
  # Default boot model reproduces dingbat's long-standing DMG/CGB boot values.
  # The test harness may override this (via --model) before post_init to drive
  # the model-specific mooneye boot_regs/boot_div acceptance ROMs.
  result.boot_model = if result.cgb_enabled: bmCgbABCDE else: bmDmgABC
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
    of etIME:          gb.cpu.ime = true
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
        write_byte(mem, gb, int(a and 0xFFFF), v),
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
