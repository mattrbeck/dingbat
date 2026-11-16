# GB/GBC emulator main file
# All types are declared here; implementation files are `include`d.

import std/[bitops, math, os, strutils, times]
import ../common/[input, scheduler, emu, resampler, serialize, timestretch, cheats, atomicfile, psg]
import ../common/lut_macros
when defined(test_harness):
  import ../common/test_output
elif not defined(emscripten):
  import ../common/audio_out

const LY_BLIND_SCOPE* {.intdefine.} = 2
  ## Which LY advances open the LY=LYC comparator's blind window
  ## (`ly_advance_close` in ppu.nim): -1 none, 0 rendered-line boundaries only,
  ## 1 also vblank line to vblank line, 2 also the mode 0 -> 1 entry on line
  ## 144. Pinned by gambatte `m1/*` and `lcdirq_precedence/*`.
# The STAT knobs live here, not in ppu.nim, because they gate GbPpu fields in
# the type block below. At 0, STAT_IRQ_LEAD needs no field and no branch.

# Dots into its M-cycle at which a CPU read of IF ($FF0F) samples the byte
# (scales with double speed). 4 = the M-cycle's end, which compiles the field
# and the split tick out. See `irq_read` in interrupts.nim.
const IF_READ_SAMPLE_T* {.intdefine.} = 0
const IF_READ_M2_144_TIE_DS* {.intdefine.} = 0
  ## Double speed: whether an IF read whose M-cycle starts on the line-144
  ## OAM pulse's dot (M2_144_EARLY_DOT_DS) sees the pulse (0 no, 1 yes).
  ## 1 fails gambatte `lcd_offset/offset1_lyc99int_m2irq_count_ds_1` [cgb].

const TIMER_IRQ_RUN_LEAD* {.intdefine.} = 1
  ## M-cycles by which a running CPU's dispatch sees a TIMA overflow before
  ## the reload raises IF bit 2 (0 = same instant). A lead on the source, so
  ## `irq_read`, the halted wake and `highest_priority` are untouched. Pinned
  ## by GBMicrotest `int_timer_*` and mooneye-wilbertpol `timer/timer_if`.
const STAT_IRQ_LEAD* {.intdefine.} = 0
const STAT_LYC_LEAD* {.intdefine.} = 0
  ## STAT_IRQ_LEAD for the LYC source only (STAT_M2_LEAD in ppu.nim does the
  ## same for the OAM source). Values on both sides of 0 fail; see ppu.nim at
  ## STAT_M2_LEAD.
const STAT_M0_TAIL_SPEED_SCALED* {.booldefine.} = false
  ## Whether STAT_M0_FIELD_TAIL counts CPU clock (`shr current_speed`) instead
  ## of dots. No effect while the tail is 0.

const STAT_M0_LEAD_T* {.intdefine.} = 2
  ## CPU T-cycles (not dots) by which the mode-0 STAT source leads the
  ## mode 3 -> 0 flag; the end of mode 3 itself does not move
  ## (`m0_source_lead` in fifo_ppu.nim, `M0_HALT_BLIND_DOTS` in ppu.nim).
  ## tools/gbppu/gam_dispatch.py reads the mode-0 dispatch 2 dots late from
  ## the second line after LCD enable on. A flat dot count fails gambatte
  ## `sprites/*_m3stat_ds_1`; `M3_END_EARLY` moves the readable field too and
  ## fails GBMicrotest `poweron_stat_*`.
const STAT_DISPATCH_MIN_AGE_DS* {.intdefine.} = 0
  ## Double speed only: dots the mode-0 source's rise must have been up at an
  ## instruction boundary before a running CPU dispatches it; 0 = any age
  ## (compiled out, the default, right while STAT_M0_LEAD_DS = 0). With a
  ## double-speed lead, 2 is the value AGE `stat-interrupt/stat-int` wants (the
  ## dispatch grid is on odd dots, so an odd SCX rises one dot before a
  ## boundary). Not for other STAT rises: that fails the same ROM's mode 2 and
  ## mode 1 cases.
const STAT_ENABLE_LATENCY* {.intdefine.} = 0
  ## DMG: dots (`shr current_speed`) from the top of its M-cycle until a STAT
  ## write's four source-enable bits reach the STAT interrupt line; 4 = the
  ## M-cycle boundary. All four bits move together: the line is a level OR
  ## into an edge detector, so bit 3 falling before bit 6 rises would make a
  ## false edge (gambatte `miscmstatirq/lycstatwirq_*` writes $40 over $48).
  ## Pinned by gambatte `m0enable/disable_scx*_1`. CGB: CGB_STAT_ENABLE_LATENCY.
const CGB_STAT_ENABLE_LATENCY* {.intdefine.} = 2
  ## STAT_ENABLE_LATENCY on CGB, in dots. 4 fails gambatte
  ## `m0enable/disable*_2` [cgb]; 0 fails `m0enable/disable_scx{1,2,5}_1`.

const CGB_LYC_WRITE_DEFER* {.booldefine.} = true
  ## On CGB a CPU write to LYC ($FF45) reaches the LY comparator at the
  ## M-cycle boundary, not at the top of its M-cycle as on DMG. wilbertpol
  ## `gpu/ly_lyc*_write` needs one NOP fewer on `-C` than on `-GS`; gambatte
  ## `lycEnable/ff45_enable_weirdpoint_*` agrees. A boundary cannot say
  ## whether the delay is 4 dots or 2 (the `lcdoffset1` tests ask that).
const CGB_LYC_EDGE_DEFER* {.booldefine.} = true
  ## Second stage of CGB_LYC_WRITE_DEFER: the CGB LYC write's STAT edge is
  ## taken at the boundary of the M-cycle AFTER its byte lands, as a one-shot
  ## `etGbLycEdge` scheduler event (the pending edge rides the serialized event
  ## array). With CGB_LYC_CMP_LATCH the STAT line is the comparator's own
  ## (GB.lyc_sampled) and has already moved; the event times the readable
  ## coincidence bit, which wilbertpol `ly_lyc*_write-C` reads. Do not write it
  ## as a per-M-cycle poll in `mem_tick_components`: the test destroys the
  ## `fifo_tick` tail call and costs ~1.2% of retired instructions on every
  ## machine, DMG included.
const CGB_LYC_EDGE_POLL* {.booldefine.} = false
  ## Control only, off: do the deferral above as a per-M-cycle poll in
  ## `mem_tick_ppu`. Same result on every test; brings back
  ## `GbMemory.lyc_edge_owed`.
const CGB_LYC_EDGE_SCHED_T* {.intdefine.} = 8
  ## The one-shot's delay in scheduler cycles (CPU T-cycles, 4 per M-cycle at
  ## either speed, hence `schedule` not `schedule_gb`). 8, not 4: the event is
  ## booked from `mem_flush_deferred` after `mem_tick_bus` has already advanced
  ## the scheduler to the next M-cycle, and dispatch is at the top of an M-cycle
  ## before its PPU dots.
const CGB_LYC_WRITE_DEFER_DS* {.booldefine.} = false
  ## Whether the deferral also applies in double speed. Off: the wilbertpol
  ## ROMs are single-speed and gambatte `lycEnable/*_ds_*` is worse with it.
  ## Unmeasured.

# ---- The line end as the CGB's STAT line sees it ----------------------------
#
# A CGB STAT write's enables reach the line CGB_STAT_ENABLE_LATENCY dots into
# its M-cycle. Stepped one dot at a time across a line's end (gambatte
# `_lcdoffsetN_` tests), the sources leave and arrive in a fixed order inside
# the comparator's lead dot (STAT_LYC_LY_LEAD_DOTS). The constants below are
# that order and its widths.
# Clean-room: derived from test ROM sources/outputs and dingbat's own
# trace runs; no emulator source consulted. docs/dev/gb-derivations.md has the tables.
const CGB_LINE_END_STEPS* {.booldefine.} = true
  ## Single speed: a rendered line's end is five steps on the comparator's
  ## lead dot, the edge detector run after each (fifo_cgb_line_end); dormant
  ## while that lead is 0 (CGB_LINE_END_ACTIVE). In order:
  ##  1. a STAT write's enables landing on this dot take hold, the line's
  ##     sources still standing (STAT writes only: an LYC write's edge is
  ##     later still);
  ##  2. the comparator lets go of this line's match; on line 143 the mode-1
  ##     source and the vblank request come up (STAT_M1_LEAD);
  ##  3. the mode-0 source falls (ahead of the DMG, which keeps it to the
  ##     boundary), after the mode-1 rise so vblank follows without a gap;
  ##  4. the comparator answers for the next line, so mode 0 handing over to
  ##     the next line's match IS an edge, seen by enables a write is about
  ##     to clear;
  ##  5. line 143's OAM pulse (m2_line144) ends.
  ## Exception to step 2: an LYC write sampled on this dot that moves the match
  ## from this line to the next leaves the answer as it was, so steps 2 and 4
  ## are one (GB.lyc_bridge, CGB_LYC_CMP_LATCH). With the hand-over here,
  ## entering vblank has no comparator dip at the boundary
  ## (ly_advance_vblank_entry). Per-step evidence: docs/dev/gb-derivations.md "A
  ## CGB STAT write across a line's end". false fails seven gambatte [cgb]
  ## tests (`lycEnable/ff41_disable_2`, `m1/ly143_late_m{0,2}enable_2`, ...).
const CGB_M2_PULSE_SS* {.intdefine.} = 2
  ## The CGB's STAT_M2_PULSE at single speed: the last dot of a line on which
  ## a STAT write's landing enable still finds the OAM source high. 3 (the
  ## DMG's) fails gambatte `m2enable/late_enable_lcdoffset2_2` [cgb]; -1 fails
  ## seven; 0..2 are indistinguishable. Double speed keeps STAT_M2_PULSE.
  ## docs/dev/gb-derivations.md "The CGB's OAM pulse is narrower".
const CGB_M2_144_PULSE_DS* {.intdefine.} = 1
  ## The last dot of line 144 on which the CGB's vblank-entry OAM pulse
  ## (m2_line144) is still high at double speed; at single speed it ends
  ## inside line 143 (CGB_LINE_END_STEPS step 5). 2 fails gambatte
  ## `m1/ly143_late_m2enable_ds_lcdoffset1_2` [cgb]; -1 fails four; 0 and 1
  ## are indistinguishable.
const CGB_M1_FALL_FIRST* {.booldefine.} = true
  ## Single speed: where line 153 hands over to line 0, the mode-1 source
  ## falls before a STAT write's enables landing on that dot take hold (the
  ## line dips). At double speed the landing is first. Pinned by gambatte
  ## `miscmstatirq/lycstatwirq_trigger_ly00_10_50_*` [cgb].
const CGB_M0_FALL_DS_FIRST* {.booldefine.} = true
  ## Double speed: at a rendered line's boundary the mode-0 source falls, then
  ## a STAT write's enables landing on that dot take hold, then the comparator
  ## lets go. Not on line 143, where mode 0 outlasts the landing. Pinned by
  ## gambatte `lycEnable/late_ff41_enable_ds_1` [cgb]; docs/dev/gb-derivations.md
  ## "Double speed: mode 0 falls, the enables land".
const CGB_LYC153_SRC_HOLD* {.booldefine.} = true
  ## Through line 153's snapback the CGB's LYC = 153 match is still there for
  ## a STAT write's landing enable until the source relatches for LY = 0
  ## (lyc_src_relatch_dot), though nothing else sees it past LY153_SNAP_DOT.
const CGB_LYC153_HOLD_PAST* {.intdefine.} = 0
  ## Dots past that relatch dot the landing still finds it. -1 fails gambatte
  ## `lycEnable/lyc153_late_ff41_enable_*` [cgb]. Positive values are inert: a
  ## later write's enables are next looked at when its M-cycle ends, past the
  ## snapback's window (LYC_RELATCH_DOT).
const
  # GB.stat_hold bits: what a step inside one dot still holds (scratch).
  STAT_HOLD_M0*     = 1'u8   # the mode-0 source, past its fall dot
  STAT_HOLD_M2_144* = 2'u8   # line 143's OAM pulse, past its fall dot
  STAT_LAND_AFTER*  = 4'u8   # a STAT write landing on this dot has not yet
  STAT_LYC153_HELD* = 8'u8   # the landing's view of the 153 match
  STAT_M0_GONE*     = 16'u8  # the mode-0 source, ahead of the mode flag
const CGB_LYC_CMP_LATCH* {.booldefine.} = true
  ## Whether the CGB's LY = LYC STAT source reads LYC through a sampled copy
  ## (GB.lyc_sampled) rather than the register: see "The CGB comparator samples
  ## LYC" in ppu.nim and docs/dev/gb-derivations.md. false = the source reads the
  ## readable register (CGB_LYC_WRITE_DEFER) and takes the old drop/edge path.
const CGB_LYC_LAND_T* {.intdefine.} = 2
  ## CPU T-cycles after the top of its M-cycle at which a CGB LYC write
  ## reaches the comparator's input: half an M-cycle, 2 dots at single speed
  ## and 1 at double (`shr current_speed`).
const CGB_LYC_LATCH_PHASE* {.intdefine.} = 0
  ## Dots by which the comparator's 4-dot sample grid is offset from the dot
  ## its LY steps on (line end - STAT_LYC_LY_LEAD_DOTS / _DS). Default 0: the
  ## LY step is itself a sample.
const CGB_LYC_BRIDGE* {.intdefine.} = 1
  ## Whether a match that an LYC write carries across the comparator's LY
  ## step (old LYC = old LY, landing on the step's own sample) keeps the
  ## line boundary's comparator window shut (ly_advance_open). 0 = the
  ## window opens regardless; 2 = any write landing on the step's sample
  ## shuts it, matched before or not.

const STAT_ENABLE_EARLY* = STAT_ENABLE_LATENCY < 4 or CGB_STAT_ENABLE_LATENCY < 4
  ## Whether either device's enable bits land before the M-cycle boundary;
  ## at 4/4 the rule and its GbPpu field compile out.

const STAT_M0_LEAD_DOMAIN* {.booldefine.} = STAT_IRQ_LEAD != 0 or
                                            STAT_LYC_LEAD != 0
  ## Whether the irq domain's three boundary hooks (mode 2 -> 3, the line
  ## advance, the LY 153 snapback) also run ahead of the flag domain, or only
  ## the mode 3 -> 0 source edge does. The domain leads need it; STAT_M0_LEAD_T
  ## must not have it (it would drop the mode-0 source early at the line
  ## boundary: gambatte `m0enable/disable_scx*`).

const STAT_M0_LEAD_FIRST_LINE* {.booldefine.} = false
  ## Whether STAT_M0_LEAD_T applies on the first line after an LCD enable.
  ## Off: tools/gbppu/gam_dispatch.py reads that line's dispatch as exact.

const STAT_LYC_LY_LEAD_DOTS* {.intdefine.} = 2
  ## Dots before a line's boundary at which the LYC comparator's LY (irq_ly)
  ## steps to the next line in SINGLE speed, so its STAT source rises and
  ## falls ahead of the readable LY (fifo_lyc_ly_lead). 0 compiles it out
  ## (and with it CGB_LINE_END_ACTIVE). Default 2: dot 454, half a CPU M-cycle
  ## before the line ends. The CGB LYC write model reads the same dot
  ## independently: gambatte `lycEnable/ff45_enable_weirdpoint_*` [cgb] is
  ## quiet exactly for writes landing on 451..454, sampled on the step. 1 and 3
  ## each fail dozens of `lcd_offset/*` tests (the CPU on each dot phase).
  ## Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  ## runs; no emulator source consulted.
const STAT_LYC_LY_LEAD_DS* {.intdefine.} = 0
  ## The same in double speed, in dots. Default 0: the comparator steps on the
  ## boundary (the CGB LYC write model's double-speed grid is on that phase
  ## too). Every other value fails dozens to hundreds of `_ds_` tests
  ## (`lcd_offset/offset1_*_ds_*`). Half a CPU M-cycle is one dot here and the
  ## model has no half-dot; the single-speed lead is not a dot count carried
  ## over.
const VBLANK_IRQ_LEAD* {.intdefine.} = 1
  ## Whether the vblank request goes up with STAT_M1_LEAD's mode-1 source, on
  ## the comparator's lead dot before line 144 (dot 454 of line 143 at single
  ## speed), rather than on the boundary (0). 0 fails gambatte
  ## `m1/lycint_vblankirq_late_retrigger_2` and DocBoy
  ## `double_speed/interrupts/single_speed_interrupt_vblank_c`.
  ## docs/dev/gb-derivations.md "The comparator's LY steps two dots before".
  ## Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  ## runs; no emulator source consulted.
const LYC_STEPPED_VBLANK_SHUT* {.intdefine.} = 1
  ## Whether a vblank line's boundary leaves the comparator alone when its LY
  ## already stepped ahead (STAT_LYC_LY_LEAD_DOTS / _DS nonzero at this
  ## speed); 0 = the blind window (ly_advance_vblank) opens regardless.
  ## Between two vblank lines nothing happens on the boundary: the comparator
  ## moved on its lead dot. Opening the window too drops and re-raises the new
  ## match two dots after it rose, a second request. Pinned by gambatte
  ## `ly0/lycint152_lyc153irq_late_retrigger_2` (both devices).
  ## Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  ## runs; no emulator source consulted.
const LCDON_M0_LAG_DS* {.intdefine.} = 8
  ## Scheduler cycles (4 per CPU M-cycle) the mode-0 STAT source trails the
  ## mode flag on the first line after an LCD enable at double speed (0 =
  ## none). The source is raised by a scheduler event at the top of an
  ## M-cycle, so 5..8 are one value: one double-speed M-cycle (2 dots) behind
  ## the flag, where every later line leads it (STAT_M0_LEAD_DS). Bracketed by
  ## gambatte `enable_display/ly0_m0irq_scx*_ds_{1,2}` [cgb]: 0..4 fail the
  ## `_ds_1` tests, 9 and up the `_ds_2` tests.
  ## Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  ## runs; no emulator source consulted.
const VRAM_WRITE_LINE0_CGB_GRACE* {.intdefine.} = 1
  ## Whether a CGB VRAM write on the LCD-on line meets a late close edge
  ## (cpu_vram_open; 0 no, 1 yes): the lock shuts one CPU M-cycle and a dot
  ## past the mode-3 flag edge, 5 dots at single speed and 3 at double. Pinned
  ## by gambatte `enable_display/ly0_late_vramw_2` [cgb] (the DMG drops that
  ## write, the CGB takes it); the width by DocBoy
  ## `double_speed_ppu_vram_write_block_timing_ly0_1_out_of_4` (CPU CGB E).
const VRAM_WRITE_LINE0_OPEN_LEAD* {.intdefine.} = 1
  ## Whether a CGB VRAM write on the LCD-on line sees mode 3 end
  ## LCD_ON_LINE0_LOCK_LEAD dots late, as a read does (lcdon_latched_mode).
  ## Pinned only by DocBoy `double_speed_ppu_vram_write_block_timing_ly0_3_
  ## out_of_4` (lead 2..3 pass); no single-speed test reaches it, applied at
  ## both speeds as the lead is.
const STAT_WRITE_LCD_OFF* {.intdefine.} = 1
  ## Whether a STAT write with the LCD off is evaluated against the
  ## comparator's frozen answer (0 = nothing moves the STAT line while
  ## LCDC.7 is clear). The comparator is frozen, not running: a match set up
  ## after the LCD went off does not count. Pinned by gambatte
  ## `lycEnable/lcdoff_lycirqen_*`; docs/dev/gb-derivations.md "A STAT write with
  ## the LCD off meets the comparator's frozen answer".
  ## Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  ## runs; no emulator source consulted.
const LYC_PARK_OPEN_DMG* {.intdefine.} = 1
  ## Whether the line boundary's comparator window (ly_advance_open) still
  ## opens under a DMG LYC write whose M-cycle holds the boundary, when the
  ## LYC it replaced did not match the line ending (0 = any parked write keeps
  ## the window shut). Shut keeps a match carried across the step (LYC = LY,
  ## LYC + 1 written) one level: gambatte `lycEnable/ff45_enable_weirdpoint_3`
  ## [dmg]. With no match to carry the line start is the ordinary one:
  ## `miscmstatirq/lycwirq_trigger_m0_late_ly44_lyc45_4` [dmg]. The CGB's side
  ## is CGB_LYC_BRIDGE.
  ## Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  ## runs; no emulator source consulted.
const M0_REQ_LAST_PX* {.intdefine.} = 1
  ## Whether the mode-0 STAT request ignores work that begins on the line's
  ## last pixel (0 = it waits for the mode flag as on every other line). An
  ## object at X = 167 or a window at WX = 166 matches on pixel 159: its fetch
  ## holds the mode flag at 3 but the request rises where it does on a bare
  ## line. One pixel to the left it is ordinary work. Pinned by gambatte
  ## `sprites/10spritesPrLine_10xposA7_m0irq_*` and `window/m2int_wxA6_m0irq*`;
  ## docs/dev/gb-derivations.md "The mode-0 request does not wait".
  ## Clean-room: derived from test ROM sources/outputs and dingbat's own
  ## trace runs; no emulator source consulted.
const STAT_GLITCH_M0_LEAD* {.intdefine.} = 1
  ## Dots before the mode 3 -> 0 flag at which the DMG STAT-write bug's $FF
  ## phase already finds the mode-0 source (ppu_stat_write_glitch), measured
  ## from the source's own change dot (STAT_M0_LEAD_T ahead of the flag): a
  ## write committing on the flag's dot or the dot before finds it, one on the
  ## source's rise dot does not. Pinned by gambatte
  ## `miscmstatirq/m0statwirq_scx*_2` [dmg] and DocBoy
  ## `dmg/stat_write_bug/stat_write_bug_hblank_scx*`.
  ## Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  ## runs; no emulator source consulted.
const STAT_M1_LEAD* {.intdefine.} = 1
  ## Whether the mode-1 STAT source rises with the LYC comparator's lead
  ## (STAT_LYC_LY_LEAD_DOTS) at the end of line 143, ahead of the mode flag,
  ## rather than at line 144's first dot (0). 0 fails ten gambatte tests
  ## (`m1/lycint143_m1irq_late_retrigger_2`, `m1/m1irq_m0disable_*`, ...).
  ## Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  ## runs; no emulator source consulted.
const STAT_LYC_LY_LEAD_ANY* = STAT_LYC_LY_LEAD_DOTS != 0 or STAT_LYC_LY_LEAD_DS != 0
const STAT_IRQ_SPLIT* = STAT_IRQ_LEAD != 0 or STAT_LYC_LEAD != 0 or
                        STAT_M0_LEAD_T != 0 or STAT_LYC_LY_LEAD_ANY
static:
  # The two share one early-advancing domain (irq_ly / irq_mode), so they cannot
  # ask for different amounts of lead at once. Either is free to be 0.
  doAssert STAT_IRQ_LEAD == 0 or STAT_LYC_LEAD == 0 or
           STAT_IRQ_LEAD == STAT_LYC_LEAD,
    "STAT_IRQ_LEAD and STAT_LYC_LEAD drive one domain: set one, or set both equal"
const STAT_DOMAIN_LEAD* = max(STAT_IRQ_LEAD, STAT_LYC_LEAD)

# Dot a CPU STAT read samples the mode field at: `cc - STAT_READ_SAMPLE`, `cc`
# being the dot counter at the end of the read's M-cycle. Bracketed on both sides
# at each speed; see `stat_read_mode`.
const STAT_READ_SAMPLE*     {.intdefine.} = 2
# The extra dots in double speed, an addend rather than a second absolute
# value so the read stays branchless: `T = SAMPLE + DS_ADD * speed`.
const STAT_READ_SAMPLE_DS_ADD* {.intdefine.} = 1

const STAT_M0_FIELD_TAIL* {.intdefine.} = 0
  ## Dots by which the STAT mode FIELD alone (not the mode-0 source, the HBlank
  ## DMA trigger or the VRAM unlock) keeps reading 3 after a DMG PPU enters
  ## mode 0 on a line with no object fetch; spent on `stat_chg_dot`. Default 0:
  ## the effect is the DMG OAM STAT source arriving an M-cycle late
  ## (`STAT_M2_LEAD`, ppu.nim). Brackets if revisited: gambatte
  ## `m2int_m3stat/scx/*` (field, no objects) against `m0enable/disable_scx*`
  ## (interrupt) and `sprites/*_m3stat_2` (field, objects) -- hence `_ABSORB`
  ## and `_MAX_MC`.

const STAT_M0_FIELD_TAIL_CGB* {.intdefine.} = 0
  ## STAT_M0_FIELD_TAIL on a CGB. 0: at 1 the gambatte `m2int_m3stat` ladder's
  ## `_2` members fail on CGB.

const STAT_M0_TAIL_MAX_MC* {.intdefine.} = 2
  ## Last M-cycle of its own instruction on which an IO read still sees
  ## STAT_M0_FIELD_TAIL (0 = every read). 2: `LD A,(C)` / `LD A,(HL)` read IO
  ## on M2 and want the tail (gambatte `m3stat`); `LDH A,(n)` reads on M3 and
  ## must not (GBMicrotest `win*_{a,b}`).

const STAT_M0_FIELD_TAIL_ABSORB* {.booldefine.} = true
  ## Whether an object fetch absorbs the field tail: the lag becomes
  ## `max(0, tail - object dots charged on this line)`. Objects only, not the
  ## window's penalty: absorbing the whole mode-3 excess fails gambatte
  ## `window/*`.

const STAT_MODE3_LAG* {.intdefine.} = 0
  ## Dots by which the STAT mode field keeps reading 2 after the PPU enters
  ## mode 3. Must stay 0: gambatte `m2int_m2stat/m2int_{,scx4_}m2stat_ds_2`.

const STAT_MODE3_LAG_CGB* {.intdefine.} = 0
  ## Dots added to STAT_MODE3_LAG on CGB only (negative = CGB reports mode 3
  ## early). 0: gambatte `halt/lycirq_m2stat_2` asks for -1, but
  ## `m2int_m2stat_1` and others fail it, both sides object-free.

# True when any field tail is set. The object accumulator and the absorption
# path hang off this, not off STAT_M0_FIELD_TAIL_ABSORB, so a default build
# carries neither the field nor the add in the object-fetch path.
const STAT_M0_TAIL_ANY* = STAT_M0_FIELD_TAIL != 0 or STAT_M0_FIELD_TAIL_CGB != 0

const STAT_MODE_LAG_ANY* = STAT_M0_TAIL_ANY or
                           STAT_MODE3_LAG != 0 or STAT_MODE3_LAG_CGB != 0

# `stat_chg_dot` for "no mode change is inside any read's sampling window".
# A line is 456 dots and the counter is rebased at every wrap, so anything this
# far back can never come within STAT_READ_SAMPLE of the counter again.
const STAT_NO_HOLD* = -1024'i32

# Fixed setup cost of a CGB general-purpose VRAM DMA, in CPU M-cycles, on top
# of the 8 M-cycles per $10 bytes (Pan Docs; see ppu_start_hdma). Default 0 and
# no value works: gambatte `gdma_cycles_*` residuals track SCX, so they are the
# mode 3 -> 0 edge, not setup.
const GDMA_SETUP_MCYCLES* {.intdefine.} = 0

# Phase, in T-cycles, between the serial unit's copy of the divider and the
# value a DIV read returns: the shift clock toggles on the falling edge of a bit
# of (divider + tap); raising it lands every edge earlier. 4 on both SoCs, a
# plateau at [4,7] on each (gambatte `serial/*`, mooneye
# `boot_sclk_align-dmgABCmgb`). Re-seeding the boot divider instead fails
# GBMicrotest `timer_tima_phase_*` and gambatte `div`.
const SERIAL_TAP_DMG* {.intdefine.} = 4
const SERIAL_TAP_CGB* {.intdefine.} = 4

# The divider's count at power-on when a boot ROM runs, against the CPU's
# first fetch at cycle 0. With 0, the DMG and CGB boot ROMs hand off 4 T short
# of mooneye `boot_div-dmgABCmgb` (0xABC8) and `misc/boot_div-cgbABCDE`
# (0x2674, both hardware-verified), while the PPU phase they hand off with
# already matches the skip-boot's: the divider alone starts one M-cycle on.
# 0 and 8 both fail those two; the skip-boot hand-off is unaffected.
const BOOT_ROM_DIV_START_T* {.intdefine.} = 4

# Where in its M-cycle a CPU access meets the serial shifter: 0 = the bus
# transaction is ordered before the M-cycle's tap edge (default); 4 = after it,
# which compiles the capture and rollback out. The tap edge lands on the last
# T-cycle of its M-cycle while dingbat runs the bus half at the top, so without
# this every access sees the shifter post-edge. Pinned by gambatte
# `serial/start_wait_read_*` (reads) and `serial/nopx1_*` (writes);
# `serial_if_write_fixup` (an $FF0F write in the completing edge's M-cycle) by
# `serial/start_wait_clear_if_read_if_*`.
const SERIAL_CPU_SAMPLE_T* {.intdefine.} = 0

const OAM_WRITE_SAMPLE_END* {.intdefine.} = 1
  ## Where in its M-cycle a CPU write to OAM asks the OAM lock: 1 = after the
  ## cycle's PPU dots, where a read samples; 0 = before them, like every other
  ## write (mem_write). With OAM_WRITE_LOCK_LAG_DOTS (ppu.nim) it is the whole
  ## of AGE `oam/oam-write-cgbBCE` (writes against the mode 2 and mode 0 edges,
  ## CGB B, C, E, both speeds). Sampled at the start, both edges read 3 dots
  ## late at single speed and mode 2 a whole M-cycle late at double.

# M-cycles a CGB spends leaving HALT that a DMG does not, charged on the
# M-cycle the pending interrupt is seen. Default 0: the CGB is later than the
# DMG out of a halt (gambatte `halt/lycirq_m2stat_2`, `halt/m1int_ly_2`) but
# spends no time doing it -- gambatte `tima/*` fails with any charge. The
# shape is a phase, CGB_HALT_PPU_LEAD below.
const CGB_HALT_EXIT_MCYCLES* {.intdefine.} = 0
const CGB_HALT_LEAD_LYC_ONLY* {.intdefine.} = 0
  ## Restrict CGB_HALT_PPU_LEAD to halts where the LYC comparator is the only
  ## armed STAT source. Default 0; see the test it gates in cpu.nim.
const LYC_SETTLE_HALT_SKIP* {.booldefine.} = true
  ## Whether a HALTED CPU's wake is exempt from the LY 153 -> 0 snapback's
  ## `LYC_SETTLE_DOTS` blind window (ppu.nim), landing on its near side where
  ## a running dispatch lands on the far side. Pinned by daid
  ## `ppu_scanline_bgp` (DMG and GBC). At normal speed redundant with
  ## `LYC_SRC_RELATCH_LEAD` (ppu.nim); kept because it derives
  ## CGB_HALT_LEAD_SKIP_LYC0's default and the two differ in double speed,
  ## where no ROM distinguishes them.
const CGB_HALT_LEAD_SKIP_LYC0* {.intdefine.} =
  (if LYC_SETTLE_HALT_SKIP: 0 else: 1)
  ## Whether a halt that the LY 153 -> 0 snapback's LYC = 0 match wakes is
  ## exempt from CGB_HALT_PPU_LEAD. Follows LYC_SETTLE_HALT_SKIP: with that
  ## rule on, the snapback wake is already one M-cycle early and the lead puts
  ## it back, so exempting it too would move it twice. An explicit
  ## `-d:CGB_HALT_LEAD_SKIP_LYC0=` still overrides (the control build).
const CGB_HALT_PPU_LEAD* {.intdefine.} = 1
  ## While a CGB CPU is halted the PPU runs this many M-cycles of dots behind
  ## the rest of the machine and gets them back at the wake: the first halted
  ## M-cycle ticks the bus half only, the wake ticks those dots into the PPU
  ## with no bus half (`cpu_halt_tick`, cpu.nim; `halt_ppu_debt` is the memo,
  ## rebuilt on state load). A phase, not a charge, so gambatte `tima/*`
  ## (which fails CGB_HALT_EXIT_MCYCLES) does not move. Bracketed by gambatte
  ## `halt/lycirq_m2stat_*` and `halt/m1int_ly_*`; pixel-exact on
  ## `cgb-acid-hell` (tools/gbppu/hellsrc.py). `strikethrough` sees it summed
  ## into OBJ_DMA_BUS_LEAD (fifo_ppu.nim). Costs ~1.3% of retired
  ## instructions on a 144-halts-per-frame ROM; a cheaper form would decide at
  ## halt entry.
const OAMDMA_HALT_PAUSE* {.intdefine.} = 1
  ## The OAM DMA unit is clocked by the CPU's bus cycles, so it freezes while
  ## the CPU is halted (OAMDMA_HALT_GRACE says when). 0 runs the transfer
  ## through a HALT; 2 (pause, no hand-back) and 3 (pause, wake M-cycle does
  ## not clock) are controls. Pinned to the byte by gambatte
  ## `oamdma/oamdmasrc80_halt_*_read8000` ($81).
const OAMDMA_RESTART_HANDOVER* {.intdefine.} = 1
  ## An FF46 write while a transfer is running restarts it two M-cycles
  ## later (mem_dma_tick), and the bus the unit holds goes to the new source
  ## page with the write: a CPU access on the new source's bus conflicts from
  ## the next M-cycle on (Pan Docs, "OAM DMA bus conflicts"). Pinned by
  ## gambatte `oamdma/oamdma_src8000_srcchange0000_busyinc`. Only the bus is
  ## pinned: the old transfer's last two bytes stay on the old page (no test).
  ## 0 = the old source keeps its bus until the restart.
const OAMDMA_HALT_GRACE* {.intdefine.} = 1
  ## M-cycles the OAM DMA unit still clocks after the HALT's fetch before
  ## OAMDMA_HALT_PAUSE freezes it: one, the HALT's own execute cycle, a bus
  ## cycle like any other (it reads the byte after the HALT; HDMA_HALT_REQ).
  ## Its sum with OAMDMA_WAKE_EXTRA is pinned at one M-cycle by gambatte
  ## `oamdma/oamdmasrc80_halt_*_read8000`; `oamdma/oamdma_late_halt_stat_*`
  ## puts it all here. The speed switch's stall has the same M-cycle
  ## (SPEED_SWITCH_OAM_DMA_HANDBACK_T, memory.nim). docs/dev/gb-derivations.md
  ## "The OAM DMA unit under a HALT".
const OAMDMA_WAKE_EXTRA* {.intdefine.} = 0
  ## T-cycles of hand-back the OAM DMA unit is owed at the wake from a HALT
  ## that paused it: none, the M-cycle being the HALT's own (see
  ## OAMDMA_HALT_GRACE).
const OAMDMA_FROZEN_RELEASE* {.intdefine.} = 1
  ## A frozen OAM DMA unit that has moved its last byte gives OAM back
  ## without another bus cycle. Running, the unit holds OAM for one M-cycle
  ## after byte 159 (position $A0); that step moves nothing, so it is the
  ## trailing edge of the last byte's cycle, and a HALT or the speed switch's
  ## stall falling on it does not keep OAM locked. 0 = the release waits for
  ## the wake. Pinned by gambatte `oamdma/oamdma_late_halt_stat_2` and
  ## `oamdma_late_speedchange_stat_2` [cgb] (the latter only with CGB objects
  ## fetched under LCDC.1 clear, obj_fetch_on in fifo_ppu.nim).
const CGB_OAM_DMA_START_T* {.intdefine.} = 8
  ## T-cycles between the FF46 write and the OAM DMA unit taking the bus, on
  ## CGB. 8, the same as DMG (mem_dma_tick).
const GB_POWERUP_WRAM_PATTERN* {.intdefine.} = 1
  ## Fill WRAM with a fixed xorshift pattern at power-up instead of zeroes.
  ## Pan Docs, "Power-Up Sequence": WRAM and HRAM are random on power-up;
  ## BullyGB's InitRAMTest fails on all-zero WRAM. Hardware (flashcart-kit/9
  ## `wramscan.gb` / `wrambands.gb` on AGB and MGB, docs/dev/flashcart-runbook.md):
  ## non-uniform bytes, 49-53% of bits set, no 256-byte banding. Fixed seed,
  ## never an RNG: screenshot gates, save states and rollback need identical
  ## starts. Costs gambatte `oamdma_srcFE00_*`/`srcFF00_*`, which read
  ## uninitialised $DE00-$DFFF through the echo; zeroing those pages would fit
  ## the capture rig, not hardware.
const HDMA_SPEEDSWITCH_KILL_W* {.intdefine.} = 1
  ## Control builds only (HDMA_HALT_REQ = 0): dots from a CGB speed switch's
  ## STOP within which the mode 3 -> 0 edge destroys the armed transfer
  ## (0 = off). With HDMA_HALT_REQ on (the default) it is not consulted.
const HDMA_DISABLE_GRACE_DOTS* {.intdefine.} = 4
  ## Dots after the mode 3 -> 0 edge after which an owed HBlank block has
  ## committed and an FF55 write with bit 7 clear can no longer suppress it
  ## (0 = every disable suppresses). Distinct from the grant point: the block
  ## is uncancellable before it takes the bus. Flat dots at both speeds, not
  ## an M-cycle. Pinned by gambatte `dma/hdma_late_disable_*` (one dot after
  ## the edge cancels, five dots after does not).
const HDMA_STEAL_LEAD_DOTS* {.intdefine.} = -1
  ## Control only, off (-1; 0 is a real setting): dots after the mode-0 edge
  ## at which an owed HBlank block raises its bus request when the CPU may
  ## hand over at ANY M-cycle boundary (plus one M-cycle). Superseded by
  ## HDMA_GRANT_FETCH_DOTS: an M-granular grant takes mealybug
  ## `dma/hdma_timing-C`'s operand-fetch boundary, which hardware says runs.
const HDMA_GRANT_FETCH_DOTS* {.intdefine.} = 4
  ## Dots after the mode 3 -> 0 edge at which an owed HBlank block raises its
  ## bus request; the CPU hands the bus over at the end of its next OPCODE
  ## FETCH (the other hand-over point is the instruction boundary,
  ## HDMA_GRANT_BOUNDARY_DOTS; never an operand or data M-cycle). The end of a
  ## HALT's execute cycle and of a dispatch's first M-cycle hand over too
  ## (HDMA_HALT_REQ, HDMA_DISPATCH_FETCH). -1 = off, falls back to
  ## HDMA_STEAL_DELAY_M. Pinned two-sided at `edge + 4` at both speeds by
  ## gambatte `dma/hdma_start*` and mealybug `dma/hdma_timing-C`, counted from
  ## the fetch rather than the read.
const HDMA_GRANT_BOUNDARY_DOTS* {.intdefine.} = 3
  ## The request dot for the instruction-BOUNDARY hand-over point, one M-cycle
  ## ahead of the fetch grant. Bracketed [2, 3] by mealybug `hdma_timing-C`
  ## and gambatte `irq_precedence/late_hdma_vs_*_scx2_*`; 2 and 3 are
  ## indistinguishable. Why it is one dot smaller than the fetch's is unknown.
const HDMA_GRANT_FETCH_HOLD* {.booldefine.} = false
  ## Whether a block granted at a hand-over point still holds its bytes back
  ## HDMA_VISIBLE_DOTS (`in_cpu_cycle`). It does not: the grant is between two
  ## CPU accesses, so there is no half-sampled read to protect.
const HDMA_WRITE_DEFER_LO* {.intdefine.} = 0xFF00
const HDMA_WRITE_DEFER_HI* {.intdefine.} = 0xFFFF
  ## Address window in which a CPU WRITE beats an owed HBlank block to the bus
  ## when the write's M-cycle begins on the grant boundary (live only with
  ## HDMA_STEAL_LEAD_DOTS >= 0, the M-granular grant). gambatte
  ## `hdma_late_destl_1` says the block sees the new IO value; `hdma_start_*_2`
  ## says a VRAM read on the same boundary is pushed past the block.
  ## $FF00-$FFFF is IO and HRAM, internal to the CPU and never on the external
  ## bus the DMA has taken.
const HDMA_STEAL_DELAY_M* {.intdefine.} = 1
  ## CPU instruction boundaries an HBlank block waits after the mode-0 edge
  ## before taking the bus (0 = on the edge). Compiled out while
  ## HDMA_GRANT_FETCH_DOTS >= 0, which keeps this boundary as one of three
  ## hand-over points. Paid BEFORE handle_interrupts: the DMA takes the bus
  ## ahead of the dispatch (gambatte `irq_precedence/hdma_vs_m0*`). Paid per
  ## instruction, not on a dot counter: a per-dot deadline costs +1.4% of
  ## retired instructions.
const HDMA_BLOCK_OVERHEAD_BUS* {.intdefine.} = 4
  ## CPU-clock cycles a VRAM DMA costs beyond its two-dots-per-byte copies:
  ## the bus acquire/release. Per transfer for a GDMA, which holds the bus for
  ## the whole burst (per block fails gambatte `gdma_cycles_long*`), per block
  ## for an HBlank DMA. One M-cycle, charged with `ignore_speed = false`:
  ## gambatte `*_cycles` intersect at 4 dots single-speed and 2 double, which
  ## no flat dot count is. Costs `hdma_late_enable_1` (its $8000 read lands one
  ## dot into mode 3, see `cpu_vram_open`) and two mealybug `hdma_timing-C`
  ## cells that point opposite ways (a dot-granular delay does no better).
const VDMA_OAM_BUS_CAPTURE* {.intdefine.} = 1
  ## A VRAM DMA and an OAM DMA running at once share the external bus: the OAM
  ## DMA unit drives an address, samples the data lines an M-cycle later and
  ## stores, so during a VRAM DMA block it stores the VRAM DMA's byte at
  ## `hdma_src and 0xFF` into OAM and its own slot is consumed, not doubled.
  ## One block byte per OAM DMA slot in single speed, every byte in double,
  ## which falls out of `internal_dma_timer`. Pinned by gambatte
  ## `dma/hdma_transition_oamdma_1` and `oamdma/oamdmasrcC000_hdmasrc0000`.
const HDMA_HALT_M0_BLIND* {.intdefine.} = 1
  ## A halted CPU cannot hand a VRAM DMA a mode-0 edge it did not see: the
  ## HBlank trigger's edge detector holds a CPU-clocked copy of the mode, so a
  ## HALT freezes it. Halt in mode 0 and every edge underneath is invisible
  ## until the CPU runs, sees a non-zero mode and then the next mode 0; halt in
  ## mode 2 or 3 and the wake's mode 0 is an edge, taken at the wake. Pinned by
  ## gambatte `dma/hdma_m3halt_m0unhalt*` and `dma/hdma_late_m0halt_*`.
const HDMA_HALT_BLIND_LAG* {.intdefine.} = 2
  ## Dots past the CPU's halt that the edge detector goes on registering the
  ## mode for, normal speed. Bracketed 2 <= lag < 3 by gambatte
  ## `hdma_late_m0halt_1` and `_lcdoffset3_2`.
const HDMA_HALT_BLIND_LAG_DS* {.intdefine.} = 0
  ## The same lag in double speed: gambatte `hdma_late_m0halt_ds_1` fails
  ## with any nonzero value.
const HDMA_HALT_REQ* {.intdefine.} = 1
  ## An HBlank request that reaches the CPU inside the HALT's own execute
  ## cycle, an opcode fetch (the SM83 reads the byte after the HALT there) and
  ## so a hand-over point; but the CPU halts and a halted CPU's VRAM DMA does
  ## not run (Pan Docs, FF55). The block waits for the wake, then: its bytes go
  ## out (HBlank edges under them unseen); the latched byte runs without a
  ## second read or PC step, so the instruction after the HALT runs twice;
  ## then the waking interrupt is dispatched. The speed switch's stall is the
  ## same halt with STOP's second byte latched. 0 = the request is paid at the
  ## HALT. Pinned by gambatte `dma/hdma_late_m3halt_m2unhalt_*` and
  ## `dma/hdma_late_m3speedchange_*`; window, speed-switch cases and evidence:
  ## docs/dev/gb-derivations.md "A HALT's execute cycle is an opcode fetch".
const HDMA_WAKE_BLIND_DOTS* {.intdefine.} = 4
  ## Dots after an interrupt wake from HALT for which the HBlank edge
  ## detector is still frozen (normal-speed dots from the wake M-cycle's end
  ## on the PPU's held-back clock, CGB_HALT_PPU_LEAD; halved in double speed;
  ## 0 = none): the first M-cycle after the wake is what clocks the detector's
  ## copy again (HDMA_HALT_M0_BLIND). Bracketed [4, 7] by gambatte
  ## `dma/hdma_m0halt_late_m3unhalt_scx1_*`. A speed switch's stall that runs
  ## out its count has no wake M-cycle and no window.
const HDMA_WAKE_M0_MARGIN* {.intdefine.} = 4
  ## Normal-speed dots of the owing mode 0 that must remain at the wake, on
  ## the PPU's held-back clock, for a block that came due under the HALT to
  ## be taken there (halved in double speed; 0 = any). 4 is the PPU's lead
  ## itself (CGB_HALT_PPU_LEAD): the block is taken if the line has not ended
  ## once the held-back dots are paid. Bracketed [3, 5] by gambatte
  ## `dma/hdma_late_m0unhalt_*`. docs/dev/gb-derivations.md "A HALT wake and the
  ## HBlank edge detector".
const HDMA_OVERHEAD_LEADS* {.intdefine.} =
  (if HDMA_GRANT_FETCH_DOTS >= 0: 0 else: 1)
  ## Charge HDMA_BLOCK_OVERHEAD_BUS before the transfer's bytes rather than
  ## after. It sets the dot the block's first byte drives on relative to a
  ## concurrent OAM DMA (VDMA_OAM_BUS_CAPTURE, gambatte
  ## `oamdma/oamdmasrcC000_hdmasrc0000`): under the instruction-boundary grant
  ## the overhead must lead; under the fetch grant, one M-cycle later, the
  ## grant is the acquire -- hence the default.
const HDMA_VISIBLE_DOTS* {.intdefine.} = 4 + 4 * CGB_HALT_PPU_LEAD
  ## Dots after the START of an HBlank DMA block at which its bytes become
  ## visible in VRAM, less the block's 32 dots. Only the data is held: the bus
  ## M-cycles, counters and FF55 are charged as usual, and held bytes land
  ## lazily where VRAM can be observed (ppu_land_hdma_if_due). 4 is a
  ## two-sided bracket in dots from gambatte `dma/hdma_start*`. Held only for
  ## a block the mode-0 edge starts (`in_cpu_cycle`): the CPU access that
  ## triggered it is still in flight. Delaying the whole block instead fails
  ## `hdma_late_disable_*`. The `4 * CGB_HALT_PPU_LEAD` term: the DMA runs on
  ## machine time while this window is measured against the pipeline (as
  ## OBJ_DMA_BUS_LEAD).
const CGB_HALT_PPU_LEAD_DOTS* {.intdefine.} = 4 * CGB_HALT_PPU_LEAD
  ## CGB_HALT_PPU_LEAD in dots, which is what the code reads. Sub-M-cycle
  ## values are not a finer knob: the halt exit is sampled on the M-cycle grid
  ## (`cpu_halt_tick`), so 1-3 dots move the wake by a whole M-cycle for a
  ## source rising within that many dots of a boundary and not at all otherwise.
const CGB_HALT_PPU_LEAD_ANY* = CGB_HALT_PPU_LEAD_DOTS != 0

# CGB per-register PPU write latency: dots into its own M-cycle at which a CPU
# write to a pipeline register lands on CGB, over and above where DMG puts it
# (DMG commits at the top of the M-cycle, mem_write). Mechanism:
# `mem_tick_ppu_latched` in memory.nim; declared here because the GbMemory
# fields are in the type block below. Every latency is clipped to
# `mdots - CGB_LATENCY_CAP` (3 dots normal speed, 1 double).
# docs/dev/gb-derivations.md "The CGB delays a mid-line write per register".
#
# SCY/SCX 2: Pan Docs "Mid-frame behavior" and mealybug's PPU notes give CGB
#   SCY writes a 2-T-cycle delay; pinned by mealybug `m3_scy_change*` `_cgb_c`
#   frames once the OBJ fetch phase is right (tick_sprite_fetcher,
#   fifo_ppu.nim). Fails `scy/scy_during_m3_spx08_ds_4`, on the cap edge.
# LCDC / LCDC.4 0: any nonzero whole-register value fails gambatte
#   `window/late_disable*`, which want a CGB fetcher abort on a mid-fetch
#   window disable, not a dot. Per-bit readers carry their own delay instead
#   (CGB_OBJ_SIZE_LATENCY, CGB_TDSEL_LATENCY, CGB_MAP_LATENCY).
# WY 4: one M-cycle, clipped to 3; gambatte `window/arg/late_wy_*` expect the
#   CGB step one M-cycle earlier than the DMG.
# WX 1, AGB only (GbQuirks.wx_write_late): AGB SP photograph of tools/gbprobe
#   probe_h_wx (docs/dev/flashcart-runbook.md row 32) puts the first firing band
#   one later than 0 predicts. The CGB: CGB_WX_LATE_SS (its own pages are
#   unphotographed).
const CGB_WX_LATENCY*         {.intdefine.} = 1
const CGB_WE_ENABLE_LATE* {.intdefine.} = 1
  ## Whether a CGB LCDC.5 rise at single speed reaches the WX comparator a dot
  ## late, so a WX match on the write's own dot is missed (0 = on the write's
  ## dot). Pinned by gambatte `window/late_reenable_scx3_2` (DMG window, CGB
  ## none) and DocBoy `enable_win_during_pixel_transfer_round1`.
const WIN_LX_OFF_V* = -128'i32
  ## fifo_ppu.nim's WIN_LX_OFF (the comparator parked), here for ppu.nim.
const CGB_WX_LATE_SS* {.intdefine.} = 1
  ## Whether every CGB (not only the AGB, GbQuirks.wx_write_late) takes a WX
  ## store CGB_WX_LATENCY dots late at single speed (0 no, 1 yes). Pinned by
  ## gambatte `window/late_wx_scx3_2` (WX moved off its match on the match's
  ## dot: window on CGB, none on DMG) and DocBoy `cgb/ppu/visual/change_wx_glitch_*`.
const SCX_WRAP_BORROW* {.intdefine.} = 1
  ## What SCX_FINE_BORROW's carry is measured against once a store has moved
  ## the fine-scroll discard (SCX_FINE_LATCH_LIVE / _WRAP). The map column is
  ## `floor((SCX + 8k - D) / 8)` with D the pixels the line's discard threw
  ## away. 0: D stays the fine scroll the line latched. 1: D follows the
  ## discard on every store it takes, as `lx` does (fifo_arm_scx): the store's
  ## `SCX and 7`, plus eight for every wrapped pass. Pinned by gambatte
  ## `scx_during_m3/scx_0761c0` [cgb]; DMG passes at both (its one-pixel lead,
  ## SCX_FINE_BORROW_DMG_LEAD). No test separates moving D on every taken store
  ## from moving it only on a wrap. docs/dev/gb-derivations.md "The map column's
  ## borrow".
const WIN_REVOKE_DS_PUSH* {.intdefine.} = 1
  ## Whether, at CGB double speed, a window start is still revoked by an
  ## LCDC.5 fall landing on the dot its restart pushes the first tile (0 no,
  ## 1 yes). Only gambatte `window/late_disable_scx5_ds_1` pins it.
const WIN_CARRY_HEAD_DROP* {.intdefine.} = 1
  ## Whether a DMG window start owed from the previous line's last pixel
  ## (DMG_WIN_LAST_PX_CARRY) that meets LCDC.5 low at the head of mode 3 is
  ## lost there (1) or stays owed to a later line's head (0). Pinned by
  ## gambatte `window/on_screen/wxA6_late_we_reenable_3` [dmg].
  ## docs/dev/gb-derivations.md, "A carried window start against LCDC.5 low".
const CGB_WE_DISABLE_LATE* {.intdefine.} = 2
  ## Dots a CGB LCDC.5 fall takes to reach the fetcher's window abort
  ## (WIN_EN_ABORT; 0 = on the write's dot). Bracketed [2, 2] by DocBoy
  ## `cgb/ppu/visual/window_bg_reprise_wx*` and gambatte
  ## `window/on_screen/wx17_weoff_wxA5_weon` [cgb].
const WIN_TAIL_PASSED_MATCH* {.intdefine.} = 1
  ## Whether mode 3's tail stops waiting on a window whose WX match the
  ## shifter has already passed (a match LCDC.5 refused, the bit set again
  ## later on the line): that window cannot start on this line, so the line
  ## retires as a plain one (fetch_work_pending). 0 holds the tail for any
  ## unstarted enabled window with WX <= 166, two dots too long. Pinned by
  ## DocBoy `cgb_dmg_mode/ppu/m3_lcdc_win_en_change_multiple_wx_timing_*`.
  ## Device-neutral: a refused DMG match is the same refused match.
const CGB_WE_ENABLE_FETCH_LATE* {.intdefine.} = 2
  ## Dots a CGB LCDC.5 rise takes to reach the fetcher's window abort, the
  ## rise's side of CGB_WE_DISABLE_LATE: a window tile's map read on the
  ## rise's dot or the next still sees the bit low, so once the fall has
  ## landed the window ends there (WIN_EN_ABORT). Only evidence: DocBoy
  ## `cgb_dmg_mode/ppu/visual/m3_lcdc_win_en_change_multiple_wx_*` reference
  ## frames and a black-box SameBoy (CGB E) run agree the window ends at that
  ## tile; no test passes on it alone (the frames keep DocBoy's glitch
  ## pixels). 1 and 3 move fewer picture rows to the references.
const HDMA_START_GRANT_FETCH* {.intdefine.} = 2
  ## An FF55 write that arms an HBlank transfer inside mode 0 raises the
  ## request at once, this many dots past the write, and the CPU hands the
  ## bus over at the end of an opcode fetch (HDMA_GRANT_FETCH_DOTS' hand-over
  ## point), never at the write's own instruction boundary; 0 = the block runs
  ## on the write. Bracketed [2, 3] by gambatte `dma/hdma_pc_7ffe` and
  ## `dma/hdma_late_enable_ds_lcdoffset1_1`. How long the request stands is
  ## HDMA_START_REQ_LAG (ppu.nim). docs/dev/gb-derivations.md "An FF55 write
  ## arming an HBlank transfer inside HBlank".
const GDMA_GRANT_FETCH* {.intdefine.} = 1
  ## Where a general-purpose DMA takes the bus: not on the FF55 write but at
  ## the end of the CPU's next opcode fetch, the hand-over point an HBlank
  ## block uses (HDMA_GRANT_FETCH_DOTS). The instruction after the write is
  ## fetched from the old VRAM, the burst runs, and that instruction's
  ## operand and data M-cycles follow it. 0 = the burst runs on the write.
  ## Pinned by gambatte `dma/late_gdma_pc_7ffe_1` and DocBoy
  ## `cgb/hdma/gdma_*`; docs/dev/gb-derivations.md "A general-purpose DMA takes
  ## the bus at the next opcode fetch".
const HDMA_LCD_OFF_BLOCK* {.intdefine.} = 1
  ## Switching the LCD off under an armed HBlank transfer moves one block:
  ## with the LCD off the mode reads 0 (Pan Docs, FF41), so the switch-off
  ## is one last entry into HBlank for the transfer's edge detector, and no
  ## further one follows until the LCD is back on. The block runs on the
  ## LCDC write. Pinned by gambatte `dma/hdma_disable_display_*`. Which
  ## switch-offs count is HDMA_LCD_OFF_EDGE. 0 = no block.
const VDMA_OVERHEAD_FREES_BUS* {.intdefine.} = 1
  ## HDMA_BLOCK_OVERHEAD_BUS's M-cycle (the acquire before, or the release
  ## after, a block's bytes) does not drive the external bus: an OAM DMA slot
  ## that falls in it stores its own byte rather than nothing. DocBoy
  ## `cgb/hdma/hdma_source_wram_dma_source_ram_during_pixel_transfer_*` leave
  ## eight OAM bytes unwritten under a nine-M-cycle block, not nine. 0 = the
  ## VRAM DMA holds the bus through it.
const HDMA_BOUNDARY_ACQUIRE* {.intdefine.} = 1
  ## Where the overhead M-cycle sits for an HBlank block granted at an
  ## instruction boundary (hand-over point 2): before the bytes, the bus
  ## acquire, where a block granted at the end of an opcode fetch has its
  ## acquire inside that fetch and pays a release after (HDMA_OVERHEAD_LEADS).
  ## DocBoy `hdma_source_wram_dma_source_ram_during_pixel_transfer_*`: the
  ## free OAM slot falls after the block on the fetch-granted SCX values and
  ## before it on the boundary-granted ones.
const VDMA_BUS_RESIDUE* {.intdefine.} = 1
  ## The first byte a VRAM DMA reads from a source no bus answers (VRAM, OAM,
  ## $FEA0-$FFFF, $E000 echo: Pan Docs, "VRAM source copies garbage", the rest
  ## "untested") is what the cartridge bus still carries from the M-cycle
  ## before the hand-over: the opcode the CPU fetched there, if from ROM or
  ## cartridge RAM. After a fetch from WRAM or HRAM, and for every later byte,
  ## nothing drives that bus (Pan Docs, OAM DMA: "the cartridge and WRAM are on
  ## separate buses") and the pull-ups read $FF. 0 = every such byte $FF.
  ## Pinned by DocBoy `cgb/hdma/gdma_source_*`.
const VDMA_M3_PORT* {.intdefine.} = 1
  ## The VRAM DMA's write port while mode 3 draws: a DMA byte that meets a
  ## pixel-fetcher VRAM access is lost. Pan Docs (CGB Registers, General-Purpose
  ## DMA) says only that the transfer "blindly attempts to copy the data, even
  ## if the LCD controller is currently accessing VRAM". Each fetcher access
  ## holds the bus for its two-dot step, ending on the read dot: the BG/window
  ## tile-map, low- and high-plane steps (FETCHER_ORDER 0..5) of every fetch
  ## but the head's discarded one, plus one more step on the dot after the
  ## last pixel; and an object's two plane reads, on the dots its LCDC.2 reads
  ## sit on (OBJ_PLANE1_LAG: M and M + 2 on the tail arm, M the merge dot;
  ## OBJ_PLANE1_HEAD: T + 2 and T + 4 on the head arm, T the trigger). A byte
  ## whose slot starts on dot c meets the bus as it stands on pipeline dot
  ## c - 1 (vdma_port_busy, fifo_ppu.nim), bracketed on both sides. Pinned by
  ## DocBoy `cgb/hdma/gdma_ppu_on_pixel_transfer_conflict_relaxed_*` (82 of 83;
  ## a black-box SameBoy run sides with dingbat on `_sprite_y16_x07`). Hardware
  ## question 21 (gbedge p21 VDMABUS) photographs the SCX 0 map. 0 = every byte
  ## lands.
const HDMA_LCD_OFF_EDGE* {.intdefine.} = 1
  ## For HDMA_LCD_OFF_BLOCK: the LCD-off block is an HBlank EDGE, so only a PPU
  ## not already in HBlank makes one (mode 2, 3 or 1 dropping to the LCD-off
  ## mode 0); switched off inside HBlank, after that HBlank's block, nothing
  ## more moves. A block still owed when the write lands is paid. Pinned by
  ## DocBoy `cgb/hdma/hdma_ppu_on_turn_off_during_*`. 0 = every switch-off
  ## moves one.
const HDMA_LCDON_LINE0_M0* {.intdefine.} = 1
  ## The LCD-enable line has no OAM scan: STAT reads mode 0 until mode 3
  ## (mooneye acceptance/ppu/lcdon_timing-GS; dingbat keeps mode 2 internally
  ## there and masks the read), and the VRAM DMA's HBlank input sees the same
  ## mode 0. So an HBlank transfer armed in those first 80 dots starts at
  ## once, as one armed inside a real HBlank does, and an LCD switch-off there
  ## makes no edge (HDMA_LCD_OFF_EDGE). Pinned by DocBoy
  ## `cgb/hdma/hdma_remaining_length_ly0_*`.
const HDMA_LCDON_LINE0_LAG* {.intdefine.} = 1
  ## On the LCD-enable line the HBlank request follows the mode bits the STAT
  ## read sees there, LCD_ON_STAT_READ_LAG (ppu.nim, from AGE stat-mode) dots
  ## behind the mode 3 -> 0 edge the other lines share: no new constant.
  ## DocBoy `hdma_remaining_length_ly0_scx*` bracket the lag at 2 from both
  ## sides.
const IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD* {.intdefine.} = 2
  ## T-cycles past IRQ_SAMPLE_T at which a CGB dispatch clears a TIMER or
  ## SERIAL request (0 = with the LCD lines, as a DMG does). Both units are
  ## clocked by the CPU's clock and raise their request where two M-cycles
  ## meet (T 16, T 20, T 24 of the dispatch), so only which of those the
  ## clear is past matters: 2..5 are one value, the clear reaching T 20, the
  ## end of the dispatch. Pinned by gambatte `tima/tc00_irq_late_retrigger_*`
  ## and `serial/start_wait_trigger_int8_read_if_*` (a DMG keeps the requests
  ## on T 24 and 20, a CGB only T 24). See dispatch_interrupt (cpu.nim) and
  ## irq_clear_holds (interrupts.nim).
  ## Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  ## runs; no emulator source consulted.
const CGB_WY_LATENCY*         {.intdefine.} = 4
  ## One M-cycle, clipped to 3 dots by CGB_LATENCY_CAP; the whole of the
  ## gambatte `window/arg/late_wy_*` device split.
const CGB_SCY_LATENCY*        {.intdefine.} = 2
const CGB_SCX_LATENCY*        {.intdefine.} = 2
const CGB_LCDC_LATENCY*       {.intdefine.} = 0
const CGB_OBJ_SIZE_LATENCY*   {.intdefine.} = 3
  ## Dots LCDC.2 takes to reach the OBJECT FETCH on CGB over the DMG; separate
  ## from CGB_LCDC_LATENCY, which moves the whole register for every reader.
  ## Derived at OBJ_PLANE1_LAG in fifo_ppu.nim from the mealybug
  ## `m3_lcdc_obj_size_change` DMG/CGB references: three dots on all six bands.
const CGB_OBJ_SCAN_LEAD*      {.intdefine.} = 2
  ## Dots before its own sample dot that a CGB's OAM scan takes a second look
  ## at LCDC.2, keeping the object if either look puts it on the line (the
  ## mode-2 range comparator, a different reader from the mode-3 object fetch
  ## above). Derived at fifo_get_sprites from gambatte `sprites/late_sizechange*`.
const CGB_MAP_LATENCY*        {.intdefine.} = 2
  ## Dots LCDC.3 / LCDC.6 (the tile-map select bits) take to reach the
  ## background fetcher's map-address read on a CGB over a DMG; a per-reader
  ## delay like CGB_OBJ_SIZE_LATENCY and CGB_TDSEL_LATENCY. 2 is pixel-exact
  ## and two-sided on mealybug `m3_lcdc_bg_map_change` / `m3_lcdc_win_map_change`
  ## and on gambatte `bgtilemap`. CPU-clock, spent at the write in
  ## ppu_store_lcdc as `max(0, CGB_MAP_LATENCY - current_speed)`: a flat dot
  ## count fails `bgtilemap/*_ds_*`. Costs +0.2% of retired instructions (one
  ## compare in `fsGetTile`, DMG too). When re-sweeping, `-d:` must reach
  ## ./dingbat_test, not only the runner.
const CGB_TDSEL_LATENCY*      {.intdefine.} = 1
  ## Dots LCDC.4 takes to reach the background fetcher's bitplane reads on CGB
  ## over the DMG. Separate from CGB_LCDC_LATENCY (which drags the other bits
  ## with it through the monotonic `run` chain and fails gambatte `window`
  ## tests). 1, bracketed from both sides by the per-band decode of mealybug
  ## `m3_lcdc_tile_sel_change2`'s CGB reference; also the only value that puts
  ## `cgb-acid-hell`'s anomaly on the observed plane (writes at 8n+1, reads at
  ## 8n+0 and 8n+2). The mealybug frames sync on mode 2 and `cgb-acid-hell` on
  ## LYC, so an advanced pipeline (`CGB_PIPE_MCYCLES`) would want 1 and 5 at
  ## once.
const CGB_TDSEL_GLITCH*       {.booldefine.} = true
  ## Whether an LCDC.4 change landing ON a background bitplane read glitches
  ## it, and how (mealybug's PPU notes; the per-band decode of
  ## `m3_lcdc_tile_sel_change2`'s CGB reference names the byte). Two rules, no
  ## free parameter: a RESET on the read dot delivers the tile INDEX as that
  ## plane's byte; a SET delivers the byte at the ADDRESS of the most recent
  ## $8000-region read (an object's plane 1, a RESET-glitched read, or a plain
  ## unsigned read), at the plane the glitch is on. The latch is a bus register
  ## not cleared by H-Blank: `m3_lcdc_tile_sel_change` glitches before anything
  ## on its line has driven an $8000 address and still substitutes the line
  ## above's byte. A data latch (last byte, not address) fails because
  ## `*_change2` glitches the same tile at different planes.
const CGB_TDSEL_IDX_DOTS*     {.intdefine.} = 8
  ## Dots a RESET glitch leaves the index path armed: a SET glitch inside the
  ## window delivers the current tile's index instead of the address latch
  ## (0 = a SET is always the latch). Arming rides `tdsel_addr` above the bank
  ## (TDSEL_IDX_SHIFT), so anything that writes the latch disarms it. Bracketed
  ## to 8..15 on the mealybug `tile_sel` CGB references plus `cgb-acid-hell`
  ## (tools/gbppu/tdselphase.py); 8 is the fetch pitch. In the default
  ## pipeline phase the rule fires on nothing, so nothing in the tree can
  ## falsify it. Cost ~+0.05% retired instructions (one guarded compare in
  ## fifo_reset_sprite).
const CGB_TDSEL_ANY* = CGB_TDSEL_LATENCY != 0 or CGB_TDSEL_GLITCH
const CGB_MAP_ANY* = CGB_MAP_LATENCY != 0
  ## Whether anything records the map-select bits' change dot; at 0 the field
  ## is never written and the fetcher's compare never takes.
const CGB_WY_LATCH_LATENCY*   {.intdefine.} = 0
# WIN_CHECK_* and WIN_LINE*_CHECK_DOT_*: docs/dev/gb-derivations.md, "The window's
# WY comparator: when it samples", has the whole schedule; all pinned by
# gambatte `window/arg/late_wy_*` and `window/late_*`.
const WIN_CHECK_DEFER_CGB*    {.intdefine.} = 5
  ## Dots after the first dot of a WY write's (or an LCDC.5 enable's) M-cycle
  ## at which the window's WY == LY comparator samples on a CGB at single
  ## speed, and at which its copy of WY (`wy_cmp`) takes a written value;
  ## 0 = at the store (ppu_latch_wy). Bracketed [5, 5].
const WIN_CHECK_DEFER_CGB_DS* {.intdefine.} = 1
  ## WIN_CHECK_DEFER_CGB at double speed, in dots (-1 = the single-speed value
  ## halved; 0 = at the store, which then has no line-end cut-off). Bracketed
  ## [1, 1].
const WIN_CHECK_DEFER_DMG*    {.intdefine.} = 1
  ## The same on a DMG, in dots (0 = at the store, with no line-end cut-off).
  ## Bracketed [1, 1].
const WIN_LINE0_CHECK_DOT_CGB* {.intdefine.} = 5
  ## Dot of line 0 at which a CGB runs the per-line WY == LY sample, where
  ## every other line (and the DMG's line 0) runs it on the first dot; 0 = the
  ## first dot here too. 5..6 pass; 5 is the double-speed value.
const WIN_LINE0_CHECK_DOT_CGB_DS* {.intdefine.} = 5
  ## The same in double speed, in dots. Bracketed [5, 5].
const WIN_CHECK_CUT_DOTS* {.intdefine.} = 2
  ## Dots before the end of a line from which a write's sample of the WY == LY
  ## comparator (WIN_CHECK_DEFER_*) no longer latches the window for the line
  ## being drawn, at single speed (0 = a sample latches up to the boundary).
  ## Default 2 (dot 454 on), also the dot the LY = LYC comparator's LY steps
  ## (STAT_LYC_LY_LEAD_DOTS); the next line's own sample follows within three
  ## dots. Bracketed [2, 2] by gambatte `window/late_enable_afterVblank_*`.
const WIN_CHECK_CUT_DOTS_DS* {.intdefine.} = 3
  ## The same at double speed, in dots. Default 3 (dot 453 on), bracketed
  ## [3, 3]. The comparator's LY has no lead at double speed
  ## (STAT_LYC_LY_LEAD_DS), so this one is a figure of its own.
const WIN_LINE_CHECK_DOT_SS* {.intdefine.} = 1
  ## Dot of a line at which the per-line WY == LY sample runs at single speed
  ## (0 = the first dot, as at double speed); a write's sample due by then is
  ## ahead of it. Bracketed [1, 1] by gambatte `window/arg/late_wy_1toFF_*`
  ## [cgb]; the DMG's tests pass at 0..2. Line 0 on a CGB has
  ## WIN_LINE0_CHECK_DOT_CGB instead.
static: doAssert WIN_LINE_CHECK_DOT_SS in 0 .. 3
const WIN_CHECK_DEFER_ANY* = WIN_CHECK_DEFER_CGB != 0 or WIN_CHECK_DEFER_DMG != 0 or
                             WIN_LINE0_CHECK_DOT_CGB != 0
const WIN_EN_ABORT*           {.intdefine.} = 1
  ## Whether clearing LCDC.5 mid-mode-3 returns the fetcher to background tiles
  ## on this line (1). DMG behaviour, not CGB-only: mealybug's PPU notes and
  ## `m3_lcdc_win_en_change_multiple*` `_dmg_blob` references, plus gambatte
  ## `window/on_screen/*`. Rule and citation at the site in tick_bg_fetcher.
const WIN_ABORT_COL_LEAD*     {.intdefine.} = 1
  ## On the DMG, the background tile the fetcher resumes with after
  ## WIN_EN_ABORT is the one under the pixel this many to the right of where
  ## its push lands (the push still lands on the window's tile boundary;
  ## mealybug: "the low 3 bits of SCX have no effect"). Bracketed [1, 1] by
  ## DocBoy `dmg/ppu/visual/window_bg_reprise_wx*`. The CGB keeps 0: its
  ## `cgb/` twins abort one tile later (CGB_WE_DISABLE_LATE) and want the
  ## column 0 gives.
const WIN_EN_HOLD*            {.intdefine.} = 2
  ## Dots a WX match that LCDC.5 refused stays live waiting for the bit (0 =
  ## dropped). mealybug `m3_lcdc_win_en_change_multiple_wx` walks a match one
  ## dot per line through two LCDC.5-low pulses: t = 9's match waits two dots
  ## and is served, t = 8's expires, and the window then starts on the dot the
  ## bit arrives. Sampling the bit at the fetcher's map read instead has to
  ## restart before it knows, costing six dots a refused match does not pay
  ## (gambatte `window/late_disable_*`, `sprites/space/*`). A refused match
  ## stalls nothing.
const CGB_WIN_EN_HOLD*        {.intdefine.} = 0
  ## WIN_EN_HOLD on a CGB. 0: gambatte `window/late_reenable_scx{2,5}_2` want
  ## mode 3 still running on DMG (hold) and mode 0 on CGB (no hold);
  ## mealybug's `_cgb_c` reference is exact either way.
const WIN_EN_HOLD_BACK*       {.intdefine.} = 1
  ## Whether a match that waited starts the window one pixel left of the pixel
  ## the shifter has reached (1) -- the same slot WIN_START_PRE_PIXEL's
  ## comparator sits in; the pixel taken back was already written as
  ## background. mealybug `m3_lcdc_win_en_change_multiple_wx`: t = 9 and t = 10
  ## both start at x = 10. The dot is spent at the serve, not the match:
  ## gambatte `window/late_reenable_scx2_2` [dmg] against `late_disable_scx2_0`.
const WIN_EN_HOLD_ZERO*       {.intdefine.} = 2
  ## What a refused match that lands on the fetcher's push dot does to the
  ## line (0 = nothing, 1 = replaces the background pixel there with colour
  ## 0, 2 = inserts a colour-0 pixel there). Pan Docs, "Window": "On
  ## monochrome systems, if the Window is disabled via LCDC, but the other
  ## conditions are met and it would have started rendering exactly on a BG
  ## tile boundary, then where it would have started rendering, a single pixel
  ## with ID 0 ... is inserted; this offsets the remainder of the scanline."
  ## (the Star Trek 25th Anniversary glitch; nitro2k01's SGB logic-analyser
  ## trace, SameBoy issue #278, has the rest of the line delayed). Pinned by
  ## DocBoy `dmg/ppu/visual/window_retrigger_pixel_glitch_*` (1 fails them).
  ## Gated on `window_trigger` (a WY match seen with LCDC.5 set this frame):
  ## Pokemon Blue rests at WX = 7 / WY = 0 with the window off and draws no
  ## white column.
const CGB_WIN_EN_DEFER*       {.intdefine.} = 5
  ## Dots a CGB window start stays revocable: LCDC.5 going low inside them
  ## abandons the restart (single speed: CGB_WIN_REVOKE_KEEP; double speed:
  ## the BG FIFO and fetcher go back to the match dot) and charges only the
  ## dots the restart ran (0 = the start commits on the match dot and costs
  ## six). gambatte `window/late_disable*` [cgb] fit, with `k = W - D`,
  ## `charge = 0 (k <= 0) / k (1..5) / 6 (k >= 6)`; k = 5 is pinned both ways,
  ## the last dot before the restart's push. A fixed defer fails them, and no
  ## global phase serves this and CGB_WY_LATENCY (opposite signs). The undo is
  ## cheap because the FIFO is empty for all five dots (tick_shifter's
  ## FIFO-empty arm). Double speed's push dot: WIN_REVOKE_DS_PUSH.
const CGB_WIN_REVOKE_KEEP*    {.intdefine.} = 1
  ## What a revoked CGB window start (CGB_WIN_EN_DEFER) leaves at single
  ## speed: 1 = the restart is cut where the undo lands, its first window
  ## tile is pushed there (fetched in full) and the line keeps the window's
  ## tile grid, LCDC.5 low ending the window at the next map read; 0 = the
  ## undo restores the background FIFO and fetcher of the match dot. The
  ## charge is the same `W - D` either way. Pinned by DocBoy
  ## `cgb_dmg_mode/ppu/m3_lcdc_win_en_change_multiple_wx_timing_*` (the
  ## object's penalty fits only on the window's tile grid,
  ## `11 - min(5, (x - (WX - 7)) mod 8)`). Double speed keeps the undo (no
  ## test measures it).
const CGB_WIN_REVOKE_LAG*     {.intdefine.} = 1
  ## Shifter dots between the LCDC.5 write that revokes a CGB window start and
  ## the dot the undo lands on. Not free: the undo restores the match dot's
  ## state and replays it, so a landing on dot X charges `X - D`, and
  ## CGB_WIN_EN_DEFER's bracket wants `W - D`; one is dot W itself. 2 fails
  ## gambatte `window/late_disable_1`.
const CGB_WIN_REVOKE_DS_TRIM* {.intdefine.} = 1
  ## Dots taken off a revoked CGB window start's charge in double speed
  ## (`W - D - 1`): half a double-speed M-cycle, the same idiom as
  ## `CGB_MAP_LATENCY - current_speed`, written as one extra replayed dot since
  ## the undo cannot land before the write. Pinned by gambatte
  ## `window/late_disable*_ds_1`; at single speed too it fails
  ## `late_scx03_wx12_2`.
const DMG_WIN_EN_REVOKE*      {.intdefine.} = 1
  ## Dots a DMG window start stays revocable (CGB_WIN_EN_DEFER's other half).
  ## One dot, not five, and all-or-nothing (a revoked start costs the line
  ## nothing): gambatte `window/late_disable*` [dmg] need k = 1 revoked and
  ## k = 2 kept. The falling-edge counterpart of WIN_EN_HOLD; the refund sits
  ## in win_defer_undo.
const WIN_EN_REVOKE_ANY* = CGB_WIN_EN_DEFER != 0 or DMG_WIN_EN_REVOKE != 0
  ## Whether any device revokes, i.e. whether the record on GbFifoPpu and the
  ## counter in tick_shifter's FIFO-empty arm exist at all.
const WIN_LINE_START_WX*      {.intdefine.} = 6
  ## The WX below which a line starts as a window line instead of reaching the
  ## window through the shifter's equality (see the mode 2 -> 3 edge in
  ## fifo_tick_slow). Placed by mealybug `m3_wx_{4,5,6}_change`: 5 and 7 both
  ## fail. `m3_wx_6_change`'s remaining pixels are the window line advancing
  ## on a mid-line re-activation, a different mechanism.
const WIN_HEAD_ABSORB*        {.intdefine.} = 1
  ## Whether a line that starts as a window line pays its `7 - WX` fine-scroll
  ## discard out of the window's own six-dot startup fetch (1) or on top of
  ## it. Mode 3 is then `172 + 6` for every WX below WIN_LINE_START_WX, as
  ## mealybug `m3_window_timing`'s flat reference says. See the head latch in
  ## fifo_ppu.nim.
const WIN_WX0_PHASE*          {.intdefine.} = 1
  ## Where WX = 0's line-start window puts its first tile. 1: the discard is
  ## `7 - WX` at every WX and the head's idle term `WX - 1` unclamped, so at
  ## WX = 0 the startup fetch is one dot shorter (one FETCHER_ORDER sleep
  ## skipped); 0 = a six-pixel discard with zero idle dots. Same dots, one
  ## pixel of tile phase: mealybug `m3_lcdc_win_en_change_multiple_wx`'s WX = 0
  ## line reads `first tile = -7..0`, the same formula as every other WX. The
  ## skipped dot is what `m3_window_timing_wx_0.asm` calls "activating one
  ## T-cycle later when WX = 0 and SCX > 0"; tested at the SCX latch dot, see
  ## fifo_sample_smooth_scroll.
const WIN_FINE_PAD*           {.intdefine.} = 1
  ## On a line that starts as a window line at WX = 1..5, the fine-scroll
  ## discard's SCX & 7 pixels are not the window's (1): they are thrown away
  ## ahead of the window's first tile, then the window's own `7 - WX`, so the
  ## window sits at WX - 7. Pan Docs, "Window": only WX = 0's window "is
  ## switched to before the initial fine scroll adjustment". Mode 3 length is
  ## unchanged (`172 + 6 + SCX & 7`, gambatte `window/m2int_wx03_scx*`). 0
  ## shifts the window left by SCX & 7 at WX = 1..5 too. No test ROM pins the
  ## picture: a black-box SameBoy run draws it unshifted
  ## (docs/dev/gb-failure-triage.md I6). WX = 0: WIN_WX0_PHASE; WX >= 6 reaches
  ## the window through the shifter's equality, after the discard.
const WIN_LINE_START_LATCH*   {.intdefine.} = 1
  ## Which dot WX is read on to decide whether a line starts as a window line:
  ## the last dot of the throw-away fetch at the head of mode 3 (1) or the
  ## mode 2 -> 3 edge six dots earlier (0). Bracketed on both sides by two
  ## mealybug ROMs; see the head latch in fifo_ppu.nim.
const WIN_HEAD_LATE_DOT* {.intdefine.} = 85
  ## Line dot (plus SCX & 7) until which a WY match can still make the line a
  ## window line when WX is below WIN_LINE_START_WX, beyond the head
  ## (fifo_head_window_late); 0 compiles it out. 82..85 pass gambatte
  ## `window/arg/late_*_wx00_*` on both devices; 85 is the dot before the
  ## head's own read of WX.
const WIN_START_PRE_PIXEL*    {.intdefine.} = 1
  ## Whether the window's WX comparator can match one slot LEFT of the
  ## shifter's first pixel (screen x = -1 when SCX & 7 = 0, i.e. WX = 6).
  ## Bracketed to one slot at `fifo_arm_window` in fifo_ppu.nim. A different
  ## mechanism from WIN_LINE_START_WX: mealybug `m3_wx_6_change` writes WX = 6
  ## in mode 2 and WX = LY at dot 93 and draws no window on LY 4 or 5, which
  ## rules out WIN_LINE_START_WX = 7.
const WIN_HEAD_WX_SCAN*       {.intdefine.} = 1
  ## The WX comparator is not read once at the head: through the head's first
  ## real fetch it compares one position per dot, `fetch_counter - (SCX & 7)`,
  ## reaching the pre-pixel slot (WIN_START_PRE_PIXEL) on the dot before the
  ## first pixel leaves the shifter. A WX store there reaches only positions
  ## not yet compared (fifo_wx_store_head): a value below WIN_LINE_START_WX at
  ## or ahead of the position still makes the line a window line; a pre-pixel
  ## value stored on the first pixel's dot misses its slot; a pre-pixel match
  ## the old value made on the dot before stands, keeping its tile phase. The
  ## head latch (WIN_LINE_START_LATCH) is the scan before its first position.
  ## Pinned by DocBoy `cgb/ppu/visual/change_wx_glitch_*`. 0 = a store re-arms
  ## the comparator as if no position had passed.
const CGB_WIN_RETRIG_LATCH*   {.intdefine.} = 1
  ## A CGB's WX re-match while the window is being drawn (the re-trigger; the
  ## DMG's colour-0 pixel is window_reactivate) cuts the window fetcher's
  ## tile-number latch for the fetch in flight, by phase: on a push dot the
  ## next fetch never latches its tile number (both planes read the tile just
  ## pushed); on the tile-number read dot the low plane reads the previous
  ## tile's, the high plane the new one; other phases change nothing
  ## (fifo_win_retrig_cgb). DocBoy's ROM comment says the same. Pinned by
  ## DocBoy `cgb/ppu/visual/change_wx_glitch*`. 0 = no effect on a CGB.
const WIN_PRE_PX_PHASE*       {.intdefine.} = 1
  ## What a match on the pre-pixel slot (WIN_START_PRE_PIXEL) does with the
  ## window's tile. 1: the tile keeps its own first pixel, covering
  ## `WX - 7 .. WX`, and the startup fetch is one dot shorter; 0 moves the tile
  ## with the match to cover `0 .. 7`. Mode 3 length is identical either way
  ## (GBMicrotest `win6_a/_b`); mealybug `m3_lcdc_win_en_change_multiple_wx`'s
  ## WX = 6 line resumes the background at x = 7, which only 1 produces.
const WIN_RESTART_COUNTER*    {.intdefine.} = 0
const CGB_WIN_RESTART_COUNTER* {.intdefine.} = 0
  ## Which fetcher step a window start's restarted fetch resumes at, per
  ## model: 0 = fetch_counter 0, a six-dot startup fetch (Pan Docs; see
  ## fifo_reset_bg); 1 = five dots. Separate from the line-start reset, which
  ## always starts at 0. DMG 0 is pinned by mealybug's DMG set. A five-dot CGB
  ## restart is suggested by tools/gbprobe probe (f)
  ## (tools/gbprobe/probe_f_base.sh) but no ROM pins it; assumed equal to the
  ## DMG.
const WIN_TAIL_FETCH*         {.intdefine.} = 1
  ## Whether a window start inside the last pixels of the line holds mode 3
  ## open for the fetch it restarts (1). Without it `fetcher_retired`'s
  ## `not fetching_window` term lets the restart, push and pixel retire in one
  ## burst. Pinned by gambatte `window/m2int_wxA5_m3stat_1` (WX = 165). See
  ## CGB_WIN_TAIL_LAST and `fetch_work_pending`.
const DMG_WIN_START_LAST_PX* {.intdefine.} = 0
  ## A DMG window start on the line's last pixel does not happen at all.
  ## Default off: fails gambatte `window/on_screen/*` pairs whose device
  ## references differ (see `win_start_reaches_pixels`); DMG_WIN_LAST_PX_CARRY
  ## is the half that survives.
const DMG_WIN_LAST_PX_CARRY* {.intdefine.} = 1
  ## A DMG window start on the line's last pixel (only WX = 166) is owed to
  ## the next line, not lost: the "window started" latch is set by the WX
  ## comparator and cleared at line end, and on a DMG the match lands on the
  ## clear's dot and survives it (CGB_WIN_TAIL_LAST pushes the CGB's clear
  ## past it). x = 159 keeps its background pixel; the latch survives into the
  ## next line, even across a frame; it is consumed at dot 86 (the throw-away
  ## fetch's end, where `fifo_head_window` reads WX) if LCDC.5 is set there and
  ## lost otherwise (WIN_CARRY_HEAD_DROP), and counts as a start for the window
  ## line counter. Pinned by gambatte `window/on_screen/wxA6_*`. Per-dot terms
  ## are behind `not ppu.cgb`; a template because an `{.inline.}` proc here
  ## costs +3.6% (see `fifo_emit_pixel`).

const WIN_CARRY_TILE*        {.intdefine.} = 1
  ## The window tile column a carried start (DMG_WIN_LAST_PX_CARRY) draws
  ## first. 1: the aborted start on the previous line already ran column 0's
  ## map read. Pinned by gambatte `window/on_screen/wxA6_wy0*` (diagonal maps).

const WIN_CARRY_REACT_LINES* {.intdefine.} = 1
  ## Extra window lines a carried start (DMG_WIN_LAST_PX_CARRY) counts when it
  ## has to reactivate the window, i.e. LCDC.5 went low between the match that
  ## owed the start and the head that spends it. gambatte
  ## `window/on_screen/wxA6_late_we_reenable_*` want the rows every four lines,
  ## not eight.

const WIN_TAIL_FLAG_LEAD*     {.intdefine.} = 1
  ## A window restart inside the last `m3_lead` pixels ends mode 3 by the same
  ## rule as one anywhere else: the flag falls `m3_lead` dots before the last
  ## pixel would leave the shifter, and the restart delays that pixel by a
  ## fetch, so mode 3 ends at hit + 7 - m3_lead + (159 - lx) whatever `lx`
  ## the match landed on -- a flat six dots over the window-less line (Pan
  ## Docs, "Mode 3 Length"). Without it the tail waits for the restarted
  ## fetch's push, one dot more at WX = 165 and two at WX = 166. Pinned by AGE
  ## `stat-mode-window` (identical for WX 1..166 on CGB B/C/E and DMG C) and
  ## gambatte `window/m2int_wxA6_m3stat_3` [cgb]. A carried DMG start
  ## (DMG_WIN_LAST_PX_CARRY) is not a restart and is left alone.
const CGB_WIN_TAIL_LAST*      {.intdefine.} = 1
  ## Whether a window restart issued on the line's LAST pixel holds mode 3
  ## open, which only the CGB does: the DMG's mode 3 ends with the last pixel,
  ## the CGB's with the last fetch. Only WX = 166 can put a restart there;
  ## gambatte `window/m2int_wxA6_*_m3stat` bracket the device difference to
  ## 5..7 dots: one six-dot fetch. An object at X = 167 shares the fetch slot
  ## (`obj_last_px`). Making the DMG comparator one slot short at both ends of
  ## the line instead fails `m2int_wxA6_*_1`. Costs `m2int_wxA6_scx5_m3stat_3`
  ## [cgb] (wants <= 5) against its `_ds_1` sibling (wants >= 6); six because
  ## six is a fetch.
const OBJ_BG_RUN*             {.intdefine.} = 4
  ## Which dots of an object penalty the BG fetcher may run on: 0 none, 1 the
  ## wait dots only, 2 all, 3 the wait dots only to finish a fetch under way,
  ## 4 all of them while the fetch the object waits for is in flight, none
  ## plus one once it is done. Derivation at tick_sprite_fetcher in
  ## fifo_ppu.nim; no test separates 0..3.
const M3_THROWAWAY_DOTS*      {.intdefine.} = 4
  ## Dots the discarded fetch at the head of mode 3 lasts: 4 or 6. The head
  ## budget is 12 dots either way (derivation at `M3_THROWAWAY_DOTS` in
  ## fifo_ppu.nim); this only places the first real tile's three VRAM reads.
const OBJ_ABORT*              {.intdefine.} = 1
  ## Whether clearing LCDC.1 mid-stall cancels the object fetch (1) or lets it
  ## run (0). Pan Docs describes the cancel; the resume dot and the ROMs that
  ## bracket it are at `fifo_obj_abort` in fifo_ppu.nim.
const CGB_OBJ_ABORT*          {.intdefine.} = 0
  ## Whether the CGB cancels an object fetch the way the DMG does (1) or lets
  ## it run (0). mealybug `m3_lcdc_obj_en_change_variant` is pixel-exact
  ## against `_cgb_c` with the cancel off and against its DMG reference with it
  ## on. See `fifo_obj_abort` for what that one test cannot separate.
const OBJ_ABORT_LEAD*         {.intdefine.} = 2
  ## Dots by which the object fetcher's view of LCDC.1 leads the CPU's write
  ## dot when the write cancels a fetch (OBJ_ABORT); the shifter resumes on
  ## `W - OBJ_ABORT_LEAD`. Two-sided at `fifo_obj_abort`: mealybug's pixel
  ## ruler fails at 1 and 3, gambatte `sprite_late_enable` fails at 3 (the
  ## rising edge spends the same constant in tick_shifter's OBJ-off prune).
const OBJ_ABORT_FLAG_HOLD*    {.intdefine.} = 0
  ## Dots the mode 3 -> 0 flag keeps after an aborted object fetch that the
  ## shifter does not. 0: gambatte `sprite_late{,_late}_disable_spx*` want the
  ## flag charged `W - OBJ_ABORT_LEAD - T`, the same as mealybug's pixels.
  ## See `fifo_obj_abort`.
const OBJ_ABORT_LATE*         {.booldefine.} = true
  ## Whether the object abort is still effective for OBJ_ABORT_LEAD dots after
  ## the stall has ended: a write on the resume dot reaches the fetcher
  ## OBJ_ABORT_LEAD earlier, still inside the fetch, which `ppu_write` cannot
  ## see because `obj_penalty` is already 0 (`obj_abort_last` remembers the
  ## stall's end). Must not reach the `idx < 0` head arm (mealybug
  ## `m3_lcdc_obj_en_change_variant` band 0 wants no refund). Pinned by
  ## gambatte `sprites/sprite_late_late_disable_spx*_1`.
const MIXER_PRIORITY_BACK*    {.intdefine.} = 1
  ## Stages of the mixer tail LCDC's priority bits are read at the far end of.
const BG_EN_AT_MIX*           {.intdefine.} = 1
  ## Where LCDC.0 (BG enable, DMG meaning) is sampled: at the mixer per pixel
  ## (1) or at the FIFO push per eight (0). mealybug `m3_lcdc_bg_en_change`
  ## shows white runs of 12 and 8 pixels off tile boundaries, which a push-time
  ## sample cannot produce. Carries MIXER_PRIORITY_BACK like the rest of LCDC.
const MIXER_PALETTE_BACK*     {.intdefine.} = 2
  ## Stages of the mixer tail BGP/OBP0/OBP1 are read at the far end of: one
  ## more than the priority bits, since the mixer resolves BG-vs-OBJ first and
  ## looks the shade up after. mealybug `m3_obp0_change` is exact at 2, not 1.
const MIXER_PALETTE_OR*       {.intdefine.} = 1
  ## Whether a DMG palette write puts one pixel of `old or new` at the far end
  ## of the mixer tail (1) or a clean edge (0). mealybug `m3_bgp_change`
  ## samples BGP's low two bits once per dot; derivation at the FF47..FF49
  ## write in ppu.nim.
const MIXER_DOT_LAG*          {.intdefine.} = 1
  ## Whether the pixel mixer runs a dot behind the FIFO pop (1) or not (0,
  ## compiles the mechanism out). On/off only: a second dot fails the tests
  ## that need the first. See fifo_recompose_last in fifo_ppu.nim.
const MIXER_TAIL_HBLANK*      {.intdefine.} = 1
  ## Whether the mixer keeps clocking after the mode 3 -> 0 edge, so a write on
  ## the first dots of H-Blank still reaches pixels whose shade the tail has not
  ## latched. Moves no edge: `fifo_burst_tail` emits the last pixels on the
  ## retire dot, and their shades are latched MIXER_PALETTE_BACK dots later.
  ## Derived from mealybug `m3_bgp_change`'s seventh write (fifo_recompose_last).
const NO_LCDC2_FLIP*          = int32.low
  ## `GbPpu.lcdc2_flip` entry meaning "LCDC.2 has not changed since this mode 3
  ## began": a dot in the far past, so `flip > dot` is false for every dot an
  ## object fetch can ask about, including a future one.
const OBJ_FIX_OFF*            = int32.high
const OBJ_HI_DOT_OFF*         = -(1'i32 shl 20)
  ## `obj_hi_dot` before the line's first object fetch: far enough in the past
  ## that no dot of the line is within an object's plane reads of it.
const OBJ_ABORT_LAST_OFF*     = int32.low div 2
  ## `obj_abort_last` when no object's fetch is abortable (none in flight, or
  ## the `idx < 0` head arm); halved so `+ OBJ_ABORT_LEAD` cannot wrap.
  ## `GbFifoPpu.obj_fix_from` meaning "no object fetch is still reachable by an
  ## LCDC.2 write".
const NO_TDSEL_CHANGE*        = int32.low
  ## `GbFifoPpu.tdsel_dot` meaning "LCDC.4 has not changed on this line"; far
  ## past so the latency and glitch tests never take. A DMG carries it all frame.
const NO_MAP_CHANGE*          = int32.low
  ## `GbFifoPpu.map_dot` meaning "neither map-select bit has changed on this
  ## line"; far past so `cycle_counter < map_dot` never takes. See CGB_MAP_LATENCY.
const TDSEL_ADDR_OFF*         = -1'i32
  ## `GbFifoPpu.tdsel_addr` meaning "nothing has driven an $8000-region
  ## tile-data address yet"; a SET-glitched read then falls back to its own.
const TDSEL_ADDR_BANK*        = 13
  ## Bit `tdsel_addr` carries the VRAM bank in. Offsets are 13 bits, so the
  ## bank rides above them and the whole latch is one store on the fetch path.
const TDSEL_IDX_SHIFT*        = 14
  ## Bit `tdsel_addr` carries the index path's arming in, as the first dot PAST
  ## the window (CGB_TDSEL_IDX_DOTS): one-past so zero means "not armed" for
  ## every dot, and the whole test is `(latch shr 14) > cycle_counter`, which
  ## also answers the negative TDSEL_ADDR_OFF sentinel. Packed rather than a
  ## field because one more int32 on GbFifoPpu moves the fetch path's fields
  ## and measured +0.22% with the rule compiled out.
const MIXER_TAIL_DOTS*        {.intdefine.} = 1
  ## Whether the mixer tail is clocked in dots (1) or emitted pixels (0). They
  ## differ only across an object stall and the tail burst, and mealybug
  ## `m3_bgp_change_sprites` says dots: a write reaches a pixel iff it left the
  ## FIFO within MIXER_PALETTE_BACK dots, stall or no stall. `tail_dot0` is the
  ## dot pixel 0 of the current unbroken run left on, so position reads as
  ## `cycle_counter - tail_dot0` whether or not `lx` has moved.
const MIXER_HEAD_LINGER*      {.intdefine.} = 1
  ## Whether the line's first pixel holds the shallow mixer stages open until
  ## the deepest one is read: LCDC's priority bits reach pixel 0 for
  ## MIXER_PALETTE_BACK dots after it leaves the FIFO rather than
  ## MIXER_PRIORITY_BACK. mealybug `m3_lcdc_bg_en_change` bands 0-2 blank x = 0
  ## two dots after it leaves; `m3_bgp_change` says the palettes are not
  ## extended. Written as `back < head`, not a lag: the two stages coincide.
const MIXER_PALETTE_OR_HEAD*  {.intdefine.} = 0
  ## Whether the line's first pixel can be a DMG palette write's `old or new`
  ## transition pixel (1) or takes the clean new value (0). AGE
  ## m3-bg-bgp-dmgC: a BGP pulse whose restoring write finds pixel 0 exactly
  ## MIXER_PALETTE_BACK stages down the tail leaves it white on hardware where
  ## `old or new` is black; one pixel further on it blends as usual.
const MIX_HOLD*               {.intdefine.} = 4
  ## Entries in the mixer's held-pair ring (GbFifoPpu.mix), a power of two. Must
  ## cover the deepest mixer stage plus the pipeline lead (static-asserted in
  ## fifo_ppu.nim); a whole M-cycle of M3_PIPE_MCYCLES needs 8. A bound, not a
  ## model: depth changes no pixel.
const CGB_MIXER_LATENCY*      {.intdefine.} = 1
  ## Dots a C-class CGB's write to a register the mixer reads takes to arrive
  ## over the DMG's; subtracted from every mixer stage. The quantity only:
  ## `quirks.mixer_write_immediate` says CGB D and later are not charged it
  ## (gb_mixer_latency). mealybug `m3_lcdc_obj_en_change` (priority, one
  ## stage) and `m3_obp0_change` (palette, two stages) are each exact on both
  ## consoles only at this value. Separate from CGB_LCDC_LATENCY (the fetcher).

const CGB_LCDC_MIXER_LATENCY* {.intdefine.} = 1
  ## Dots the CGB's LCDC write takes to reach the pixel mixer over the DMG's.
  ## One dot cancels the mixer's one-dot lag (fifo_recompose_last), so the
  ## repaint of the already-emitted pixel is skipped on CGB: mealybug
  ## `m3_lcdc_obj_en_change` is pixel-exact on `_cgb_c` without the repaint
  ## and on the DMG references with it. LCDC only; the DMG palettes take the
  ## mixer's dot on both consoles (`m3_obp0_change`). Separate from
  ## CGB_LCDC_LATENCY, the same register's latency at the fetcher.
const CGB_LATENCY_CAP*        {.intdefine.} = 1
  ## Dots at the end of the M-cycle no CGB write latency may reach into. Only
  ## double speed (a two-dot M-cycle) can tell 0 from 1; the `_ds_` tests in
  ## gambatte scy/scx_during_m3/sprites are the CGB CPU-to-PPU phase axis, and
  ## the cap keeps a register latency from being scored against them.
const CGB_LCDC_LATENCY_ANY* = CGB_LCDC_LATENCY != 0
const CGB_WY_LATENCY_ANY*   = CGB_WY_LATENCY != 0 or CGB_WY_LATCH_LATENCY != 0
const CGB_WRITE_LATENCY_ANY* = CGB_WX_LATENCY != 0 or CGB_SCY_LATENCY != 0 or
                               CGB_SCX_LATENCY != 0 or
                               CGB_LCDC_LATENCY_ANY or CGB_WY_LATENCY_ANY

# Dots the first and second line after an LCD enable are short of 456. Both
# default 0 (field and branches compile out). No fit: GBMicrotest
# `int_hblank_*` (line 0) say 0, `hblank_int_scx*` (line 1) and the boot
# hand-off tests say -2, gambatte `enable_display` says 0;
# `LINE0_TRIM=2, LINE1_TRIM=-2` is closest but nothing derives it. ppu.skip_boot must clear
# the window these open, since the HLE hand-off's LCDC write fires the
# LCD-enable branch too.
const LCD_ON_LINE0_TRIM* {.intdefine.} = 0'i32
const LCD_ON_LINE1_TRIM* {.intdefine.} = 0'i32
const LCD_ON_TRIM_ANY* = LCD_ON_LINE0_TRIM != 0 or LCD_ON_LINE1_TRIM != 0

const SCX_FINE_LATCH_LIVE* {.booldefine.} = true
  ## A store to SCX joins the line's fine-scroll discard while the discard
  ## still has pixels to throw away, instead of being measured against a value
  ## sampled on one dot. Declared here because `GbFifoPpu` grows a field only
  ## when on (the field alone costs 0.2% through layout). Derivation in
  ## fifo_ppu.nim.

const SCX_LIVE_BORROW_LATCHED* {.booldefine.} = true
  ## Whether `SCX_FINE_BORROW`'s carry keeps a reference of its own once
  ## SCX_FINE_LATCH_LIVE has moved the live discard target (what that
  ## reference is: SCX_WRAP_BORROW). Pinned by gambatte
  ## `scx_during_m3/scx_0360c0` and `scx_0761c0`; derivation in fifo_ppu.nim.
  ## `GbFifoPpu` grows a field only when on.

const SCX_FINE_LATCH_WRAP* {.intdefine.} = 8'i32
  ## Dots the fine-scroll discard costs when a mid-line SCX store lands after
  ## the discard has walked past the new `SCX and 7`: the discard is a
  ## three-bit slot counter compared each dot against the live value, and a
  ## slot-7 miss wraps into a whole further pass ("SCX banging"). 0 = off.
  ## Requires SCX_FINE_LATCH_LIVE. Pinned by gambatte `scx_m3_extend`'s `_ds`
  ## pair; see fifo_ppu.nim.

const SCX_STORE_STALL_DOTS* {.intdefine.} = 0'i32
  ## Dots the pixel pipeline stalls when a mid-line SCX store lowers
  ## `SCX and 7`; 0 = off. `GbFifoPpu` grows a field only when on. gambatte
  ## `scx_m3_extend` says mode 3 is longer after such a store and its `_ds`
  ## member prices one at 8 dots; derivation in fifo_ppu.nim.

# ==================== TYPE DECLARATIONS ====================
# All GB types in one block for forward-reference support.

type
  # ---- Cartridge / MBC ----
  CgbFlag* = enum
    cgbNone, cgbSupport, cgbExclusive

  # The buses an OAM DMA can own and a CPU access can collide with. Pan Docs
  # "OAM DMA bus conflicts": cartridge and WRAM are separate buses on CGB; on
  # DMG WRAM hangs off the external bus, so only HRAM is safe there.
  GbDmaBus* = enum
    dbNone      # OAM / unusable / IO / HRAM / IE — never conflicts
    dbExternal  # cartridge ROM $0000-$7FFF and cartridge SRAM $A000-$BFFF
    dbVideo     # VRAM $8000-$9FFF
    dbWram      # WRAM + echo $C000-$FDFF (CGB only; DMG folds it into dbExternal)

  # Selects the per-revision CPU register / DIV seed table applied at the
  # boot-ROM hand-off (skip_boot). Sources: mooneye acceptance boot_regs-* /
  # boot_div-* and Pan Docs "Power-Up Sequence". Real carts get bmDmgABC or
  # bmCgbABCDE; the rest exist for the harness's --model.
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
    ## The silicon revision. Finer than GbBootModel, which only selects a boot
    ## hand-off table (mooneye ships one `boot_regs-cgbABCDE`); gb_set_revision
    ## derives the boot model. Do not branch on this in emulation code: resolve
    ## it once into GbQuirks (gb_quirks_for).
    grDmg0, grDmgABC, grMgb, grSgb, grSgb2
    grCgb0, grCgbAB, grCgbC, grCgbD, grCgbE
    grAgb

  GbUnusableRegion* = enum
    ## What `$FEA0..$FEFF` answers a CPU read and whether a write is kept.
    ## Pan Docs, "FEA0-FEFF range", split three ways: DMG-class reads return
    ## $00 (and corrupt OAM during OAM block); CGB 0-D is a unique RAM area
    ## masked with a revision-specific value; CGB E / AGB / AGS / GBP return
    ## the high nibble of the low address byte twice. (Pan Docs' `FFAx` there
    ## is a typo for `FEAx`.) `$FF` when OAM is blocked on all of them.
    urZero
      ## DMG / MGB / SGB / SGB2: reads answer `$00`, writes are dropped.
    urRamMasked
      ## CGB 0 / A / B / C: real RAM with address bits 3 and 4 masked
      ## (`addr and not 0x18`), 96 addresses onto 24 cells. Pan Docs gives no
      ## mask value; it is sourced from `cgb-acid-hell`, which writes `$55` to
      ## `$FEA0` and `$44` to `$FEB8`, reads `$FEA0` back, and whose bundled
      ## reference is the not-`$55` branch.
    urRamPlain
      ## CGB D: the same RAM with no mask, so `$FEA0` and `$FEB8` are distinct.
      ## `cgb-acid-hell` fails on CGB-D by design (its SORRY screen is correct
      ## behaviour there).
    urNibbleEcho
      ## CGB E / AGB / AGS / GBP: not RAM. Reads answer the high nibble of the
      ## low address byte doubled (`$FEAx` -> `$AA`); writes are dropped.

  GbQuirks* = object
    ## Per-revision behaviour, resolved from GbRevision once by gb_quirks_for.
    ## Flags rather than revision compares: a flag names the behaviour at its
    ## site, shared behaviours share a flag, and a load beats a range check in
    ## a hot path. `unusable_region` is the one non-bool member (three states,
    ## no natural "off"); its CGB default is `urRamMasked`, the revision the
    ## tree is scored against.
    length_clock_any_nrx4*: bool
      ## CGB 0 and CGB A/B: the NRx4 extra length clock fires whenever the
      ## length counter was previously disabled, whether or not the write
      ## enables it (drops the `and len_enable` term). SameSuite
      ## `*_extra_length_clocking-cgb0B`, whose source documents the CGB-C fix.
    mixer_write_immediate*: bool
      ## CGB D and later: a mid-mode-3 write to a palette register reaches the
      ## mixer at the DMG's phase, i.e. without `CGB_MIXER_LATENCY`'s dot
      ## (gb_mixer_latency). Palettes only: LCDC keeps its dot on every revision
      ## (see gb_lcdc_mixer_latency). mealybug `m3_bgp_change` is pixel-exact
      ## against `_cgb_c` with the dot and `_cgb_d` without. `grAgb` is
      ## deliberately not in the set: mealybug has no `_agb` capture and AGE's
      ## `agb` tests score the current behaviour.
    wx_write_late*: bool
      ## AGB: a WX write reaches the window comparator CGB_WX_LATENCY dots
      ## late. The AGB SP photograph of tools/gbprobe probe_h_wx fires one band
      ## later than an immediate write; the CGB pages are unphotographed.
    scy_fetch_latch*: bool
      ## CGB D and later latch SCY once per BG fetch, at the map read; CGB C and
      ## earlier sample it live on each of the three read dots. Two-sided from
      ## mealybug `m3_scy_change` `_cgb_c` against `_cgb_d`. AGB follows D: the
      ## AGB SP photograph of tools/gbprobe probe_h_scy is pixel-identical to
      ## the latched render (docs/dev/flashcart-runbook.md row 31).
    pcm_read_edge_zero*: bool
    cgb_c_or_older*: bool
      ## CGB 0 / A / B / C: where a double-speed square trigger lands
      ## (apu/psg_host.nim, SQ_START_HALF_RATE_LEAD_T, gb_trigger_pickup).
      ## pcm_read_edge_zero: a PCM12 read landing on the very cycle a square
      ## channel's duty step lands reads 0 for that channel if its output was 0
      ## before the step (the rising edge is invisible to a read taken on it).
      ## True on the default revision: SameSuite `channel_1_freq_change_timing`
      ## names its device list `-cgb0BC`, and cells 4 and 15 read `$0f` there
      ## where `-A` / `-cgbDE` read `$ff`. Not modelled: channel 4's arm of the
      ## same quirk (SameSuite apu/README.md) and the double-speed envelope-tick
      ## arm (`channel_{1,2}_nrx2_glitch`, `channel_1_volume`).
    square_reload_halftick*: bool
      ## CGB D / E. A square channel's frequency timer reloads on the 2 MHz
      ## half of the tick after a duty step, so an NR13/NR14 write landing
      ## half a tick after the step still sets the period counted from it;
      ## every other revision takes only a write on the step itself
      ## (sq_reload_step). Inert at single speed (writes and steps share the
      ## 4 T grid). Pinned by cell 10 of SameSuite `channel_1_freq_change_timing`
      ## (`-cgbDE`) and DocBoy `double_speed_apu_ch1_change_period_nr1*`.
      ## Undoing the step for an NR14 write instead moves the duty position,
      ## which DocBoy's tests see.
    lyc_compare_hold*: bool
      ## CGB D / E / AGB. On the M-cycle in which LY advances, STAT's LY=LYC bit
      ## holds the comparison against the previous LY instead of reading clear
      ## (the `LY_JUST_CHANGED` branch in `ppu_read`): a one-M-cycle-stale copy.
      ## wilbertpol `acceptance/gpu/ly_lyc*-C` (scored on CGB-E; the fork's
      ## `-C` is the Color group). CGB-C itself is unmeasured.
    oam_read_open_late*: bool
      ## CGB E. The CPU's OAM read lock reopens one dot later at the end of mode
      ## 3 than on DMG-C / CGB-B / CGB-C (5 dots after the flag edge, not 4).
      ## AGE `oam/oam-read-dmgC-cgbBC` vs `oam/oam-read-cgbE` (same source,
      ## `CGB_E` defined); `vram/vram-read-cgbBCE` says mode 3's length is
      ## revision-flat. See OAM_READ_M0_OPEN_DOTS in ppu.nim. CGB-D is
      ## unmeasured and keeps the C behaviour.
    spsw_apu_rephase_2mhz*: bool
      ## CGB E. The first KEY1 switch after an APU power-on puts a running
      ## square's next step on the re-phased 2 MHz grid's previous edge, as
      ## it does the wave channel's (`APU_SPSW_REPHASE_LEAD3_T`, 1 T), not
      ## the 1 MHz grid's (`APU_SPSW_REPHASE_LEAD_T`, 3 T): the square plays
      ## one double-speed M-cycle later after the switch. Pinned by DocBoy
      ## `double_speed/apu/ch2/speed_switch_to_double_apu_ch2_volume_sweep_*`
      ## (its CGB is an E; 2 T and 3 T fail). CGB C keeps 3 T: gambatte's
      ## `speedchange*` duty ladder (cgb04c) pins it (docs/gb-failure-
      ## triage.md H2). CGB D and AGB are unmeasured and keep the C rule.
    env_clock_ds_late*: bool
      ## CGB E. At double speed the DIV-APU step's envelope clock reaches the
      ## channels ENV_CLOCK_DS_LATE_T (apu.nim) after the step itself, so a
      ## PCM12 read on the step's M-cycle still sees the old volume; a length
      ## clock on a step lands at once. Pinned by DocBoy `double_speed/apu/ch2/
      ## double_speed_apu_ch2_volume_sweep*` (its CGB is an E); black-box probe
      ## runs agree for CGB E and show CGB C stepping at once. At single speed
      ## the read comes after it within the M-cycle (SameSuite
      ## channel_1_volume_div). CGB D and AGB are unmeasured and keep the C rule.
    spsw_irq_leaf_hold_short*: bool
      ## CGB E. Half the oscillator-restart hold on the aborted-halt speed
      ## switch leaf -- one M-cycle where CGB B and C lose two. See
      ## `SPEED_SWITCH_IRQ_LEAF_HOLD_T` in timer.nim for both measurements;
      ## it is the same silicon difference c-sp's `spsw-interrupts.inc`
      ## encodes as `OFS_B`, and CGB D and AGB are unmeasured.
    spsw_div_mid_taps_slow*: bool
      ## CGB E. The KEY1 speed switch's DIV reset reaches the divider's middle
      ## TIMA taps (bits 5 and 7) at the same early point as the high ones,
      ## instead of one M-cycle later with the low tap: `SPEED_SWITCH_DIV_SLOW_BIT`
      ## drops from 9 to 5 (timer.nim, `SPEED_SWITCH_DIV_RESET_T_SLOW`). AGE
      ## `speed-switch/spsw-tima-cgbBC` vs `spsw-tima-cgbE` (`DEF OFS EQU 1`);
      ## CGB D and AGB are unmeasured and keep the CGB-C rule.
    m1_end_no_mode0*: bool
      ## CGB D / E / AGB. Every earlier machine spends one M-cycle reading back
      ## mode 0 at the very end of mode 1 (STAT bit 0 drops as mode 1 ends, bit 1
      ## rises an M-cycle later); CGB D and later move them together, `$81` ->
      ## `$82`. AGE `stat-mode/stat-mode-dmgC-cgbBC` vs `stat-mode-cgbE` (the
      ## `M1E` byte), with per-unit hardware records in their headers. No other
      ## evidence.
    ly_read_edge_late*: bool
      ## CGB D / E / AGB. A CPU read of `$FF44` sees the LY 153 -> 0 snapback
      ## one CPU M-cycle later than on CGB 0/A/B/C and every DMG; single speed
      ## only (at double speed every CGB takes the late edge), so it is consulted
      ## at the read site together with the speed. `LY153_READ_SNAP_CGB` in
      ## ppu.nim is the dot it selects. AGE `ly/ly-dmgC-cgbBC` and `ly/ly-cgbE`
      ## are one program differing in one single-speed expected byte (`L99`).
    unusable_region*: GbUnusableRegion
      ## What `$FEA0..$FEFF` does on this machine; see GbUnusableRegion.

  Mbc* = ref object of RootObj
    gb_ref* {.cursor.}: GB   # back-ref to the owning GB; non-owning to avoid a
                             # reference cycle (the GB owns the cartridge)
    rom_identity*: uint32    # FNV-1a of the ROM as loaded, taken once. The
                             # save-state identity reads this, not `rom`,
                             # which cheats patch in place. See
                             # gb_rom_checksum.
    rom_file_size*: int      # the file's length; `rom` is padded past it
                             # (load_cartridge). State headers carry this.
    rom*:          seq[uint8]
    ram*:          seq[uint8]
    sav_path*:     string
    has_battery*:  bool
    ram_dirty*:    bool
    # Why the last battery write failed ("" once one lands), and whether the
    # frontend has yet to tell the player about this run of failures (it
    # clears the flag; mbc_save sets it again only after a success).
    save_error*:     string
    save_error_new*: bool
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
    ram_enable2*: bool  # 0x40 written to 0x4000-0x5FFF; BOTH must be set
    rom_bank_num*:     uint8
    # Accelerometer. accel_x/accel_y are the frontend's tilt in the range
    # -1.0 .. 1.0, 0.0 = level; they are live input, not saved state.
    accel_x*, accel_y*: float
    x_sample*, y_sample*: uint16  # sampled by the 0x55/0xAA latch sequence
    latch_armed*:       bool     # a 0x55 has armed the latch; the 0xAA only
                                 # samples when it has (Pan Docs: re-latching
                                 # without erasing first yields no change)
    # 93LC56 serial EEPROM port. One bit is shifted per rising clock edge;
    # instr_shift is an 11-bit shift register (start bit, 2 opcode bits,
    # 8 address bits) and data_reg shifts data back out on DO.
    pin_do*, pin_di*, pin_clk*, pin_cs*: bool
    instr_shift*:       uint16
    data_reg*:            uint16
    bits_to_shift*:   int
    write_enabled*: bool

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
    # Set by STOP entering STOP mode (stop_instr, memory.nim) on top of
    # `halted` and `locked`: the rest of the machine is stopped too, and a
    # joypad line going low clears all three. Serialized from GB payload rev
    # 6; an older state taken inside STOP loads as a running CPU after it.
    stopped*:    bool
    # Dots of PPU time a halted CGB CPU is holding back (CGB_HALT_PPU_LEAD,
    # cpu_halt_tick). The same value for a whole halt, so not serialized:
    # load_cpu_state reconstructs it from `halted` and the speed.
    halt_ppu_debt*: int32
    # Scheduler cycle EI's delayed IME landed on (etIME), so HALT can ask what
    # IME was at its own fetch (cpu_halt). Scratch like `cached_hl`, not
    # serialized: 0 answers "not set during this fetch", right at any boundary.
    ime_set_cycle*: CycleCount
    cached_hl*:  int   # -1 = invalid
    # Idle-loop skip (GB_IDLE_SKIP, cpu.nim). Scratch, not serialized: a
    # loaded state starts a fresh verdict. `wl_edge` is set by a taken
    # backward JR/JP (`wl_from` its address) and answered at the next fetch.
    wl_edge*:      bool
    wl_from*:      uint16
    wl_head*:      int32      # loop head the snapshot was taken at, -1 none
    wl_head_from*: uint16
    wl_snap*:      array[5, uint16]
    wl_stamp*:     CycleCount
    wl_writes*:    int
    # gb.wl_mark as of the last halted M-cycle that could not skip: nothing
    # the answer depends on moves until the mark does.
    wl_halt_fail*: CycleCount
    # That failure met a mode 3 the renderer was running dot by dot,
    # which moves the mark every M-cycle and has no horizon until it ends or
    # defers: no retry before then.
    wl_halt_m3*:   bool
    # The opcode executing, so an IO read can say which M-cycle of its own
    # instruction it is (STAT_M0_TAIL_MAX_MC). Guarded out of a default build.
    when STAT_M0_TAIL_MAX_MC != 0:
      cur_opcode*: uint8

  # ---- Interrupts ----
  GbInterrupts* = ref object
    vblank_interrupt*:   bool
    lcd_stat_interrupt*: bool
    timer_interrupt*:    bool
    # TIMER_IRQ_RUN_LEAD: the TIMA overflow itself, one M-cycle ahead of the
    # reload that raises `timer_interrupt`; only the running CPU's dispatch
    # test reads it. Not serialized: live for the 4 T of the reload countdown.
    timer_interrupt_early*: bool
    # IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD: the line a CGB dispatch is
    # still holding clear (INT_TIMER / INT_SERIAL, 0 = none) and the last
    # scheduler cycle it does so on (irq_clear_holds, interrupts.nim). Not
    # serialized: live for one M-cycle after the dispatch, and step_frame
    # runs an instruction past a frame edge that would cut it.
    clear_line*:  uint16
    clear_until*: CycleCount
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
    when SERIAL_CPU_SAMPLE_T < 4:
      # The shifter as it stood before the tap edge of `edge_cycle`, so a CPU
      # access in that M-cycle is served the pre-edge state (SERIAL_CPU_SAMPLE_T).
      # Scratch within one M-cycle; not serialized.
      edge_cycle*:   CycleCount
      pre_master*:   bool
      pre_sb*:       uint8
      pre_sc*:       uint8
      pre_bits*:     int
      pre_irq*:      bool

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
    hold_t*:       int
      ## T-cycles the divider owes before it counts again: the oscillator
      ## restart on the aborted-halt speed switch leaf (SPEED_SWITCH_IRQ_LEAF_HOLD_T,
      ## memory.nim). Not serialized: nonzero for at most two M-cycles.

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
    # A low pulse is in flight (one select line went low from both-high). Not
    # serialized: reconstructed from prev_lines on load (load_sgb_state).
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
    # ICON_EN bit 2: suppress all further packets (Pan Docs, SGB_Command_System);
    # multi-game paks set it before chain-loading. Nothing documented clears it.
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

  # One mixer stage's held FIFO output: the BG and OBJ entries popped on the
  # same dot, as a pair so the shifter's store is one eight-byte store
  # (measured 0.37% on the mode 3 dot loop against two four-byte ones).
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
    # HDMA1-4 ARE the transfer's address counters, not registers it reads at
    # its start: a second transfer without rewriting them continues where the
    # first stopped (SameSuite dma/gbc_dma_cont) and a mid-transfer write moves
    # the remaining blocks. Each copied block advances the pair below.
    hdma5*:         uint8
    hdma_src*:      uint16  # HDMA1:HDMA2, low nibble always 0
    hdma_dst*:      uint16  # HDMA3:HDMA4, masked into VRAM only where it is used
    hdma_active*:   bool
    hdma_copying*:  bool   # re-entrancy guard; see ppu_step_hdma
    # A block this HBlank owes an armed transfer (only a halted CPU leaves one
    # unpaid; see the mode-0 edge in `mode_flag=`). Cleared leaving mode 0, so
    # never set at a frame boundary; not serialized, nor are its siblings below.
    hdma_block_due*: bool
    # HDMA_HALT_M0_BLIND only: the HBlank edge detector's registered copy of
    # the mode. Updated on every mode change the CPU is awake for and frozen
    # across a HALT, which is the whole of what the constant models.
    hdma_seen_mode*: uint8
    # ...and the PPU dot the CPU halted on, so the freeze can carry
    # HDMA_HALT_BLIND_LAG dots past it. Scratch, like hdma_block_due.
    hdma_halt_dot*: int32
    # CPU instruction boundaries still owed before a due HBlank DMA block may
    # take the bus. See HDMA_STEAL_DELAY_M.
    hdma_due_delay*: int8
    # HDMA_STEAL_LEAD_DOTS: the dot at or after which the owed block may take
    # the bus on the next M-cycle boundary; `high(int32)` when the CPU was
    # halted at the edge (the debt is paid at the wake). Scratch.
    hdma_due_deadline*: int32
    # The dot the owed block's mode-0 edge fell on. See
    # HDMA_DISABLE_GRACE_DOTS. Live only alongside hdma_block_due, so like it
    # this is never set at a frame boundary and is not serialized.
    hdma_due_dot*: int32
    # A speed switch is in flight: the next mode-0 edge within
    # HDMA_SPEEDSWITCH_KILL_W dots destroys the armed transfer. -1 = none.
    # Live only across the STOP's stall; not serialized.
    hdma_kill_from*: int32
    # A copied block whose bytes land HDMA_VISIBLE_DOTS after its last byte.
    # Closed by the next PPU tick, so never live at a frame boundary; not
    # serialized.
    hdma_bytes_held*: bool
    hdma_hold_from*:  int32   # dot the hold was armed on (a smaller dot = the
                              # line wrapped, i.e. the hold is long expired)
    hdma_hold_until*: int32   # dot the bytes land on
    hdma_held_dst*:   int32   # VRAM address the held block starts at
    hdma_held*:       array[16, uint8]
    # The frame drawn right after LCDC.7 goes high is not shown: the panel
    # stays blank until the first vblank (Pan Docs, LCDC). Not on SGB, where
    # the TV keeps the frozen picture. Not serialized: false at every frame
    # boundary a state loads from, and gb_apply_state sets it so.
    lcd_on_first_frame*: bool
    # window state: a WY match seen with LCDC.5 set this frame (ppu.nim
    # `mode_flag=`, win_check_now, ppu_latch_wy, ppu_store_lcdc)
    window_trigger*:     bool
    current_window_line*: int
    old_stat_flag*:      bool
    win_check_dot*:      int32     # WIN_CHECK_DEFER: dot the comparator samples on, -1 none
    # A second sample queued behind that one (a WY write's against line 0's
    # own check on a CGB), -1 none; and which of the two take the written WY
    # with them (bit 0 the first, bit 1 the second). `wy_cmp` is WY as the
    # comparator has it: the register, WIN_CHECK_DEFER_* dots late. In flight
    # for a few dots after a write; not serialized (load_ppu_state re-derives).
    win_check_dot2*:     int32
    win_check_wr*:       uint8
    wy_cmp*:             uint8
    # A STAT write's cleared enable bits let the line DROP at the commit (+ the
    # CGB latency), ahead of the M-cycle boundary the rest of the byte waits
    # for (stat_drop_arm, ppu.nim). Settled lazily, at the next source change
    # past its dot, so it can still be set at a frame boundary; serialized
    # from GB payload rev 6. The dot is in cycle_counter's terms.
    stat_drop_pending*:  bool
    stat_drop_level*:    bool
    stat_drop_dot*:      int32
    # A CPU write to LCDC/STAT/LYC changed a STAT-line input not yet
    # re-evaluated: the byte lands at the top of its M-cycle (mem_write), the
    # edge is taken at the boundary. Consumed in the same M-cycle; not serialized.
    stat_write_pending*: bool
    # The dots of the last two mid-mode-3 changes of LCDC.2, newest first, or
    # NO_LCDC2_FLIP. An object fetch reads the bit once per bitplane,
    # OBJ_PLANE_GAP dots apart, and the merge happens on one dot (obj_height_at,
    # sprite_fetch_merge); two entries suffice since a store to $FF40 is at
    # most every 8 dots. Per-line scratch.
    lcdc2_flip*:         array[2, int32]
    first_line*:         bool
    when LCD_ON_TRIM_ANY:
      lcdon_lines*:      uint8   # lines left in the LCD-on trim window
    cycle_counter*:      int32
    # The mode as it stood when this M-cycle's dots began, snapshotted at tick
    # entry because the PPU is ticked a whole M-cycle before read_byte runs.
    # Decides the CPU's VRAM/OAM locks (cpu_vram_open / cpu_oam_open); a STAT
    # read's mode bits come off stat_chg_dot instead. Bit 7 (LY_JUST_CHANGED)
    # rides along: set by an LY advance, cleared by the next snapshot (ppu_read
    # $FF41).
    read_mode*:          uint8
    # The dot the mode last changed on and what it changed from: a read at `cc`
    # reports the new mode once `cc - stat_chg_dot >= STAT_READ_SAMPLE`
    # (stat_read_mode). Written only by `mode_flag=` and rebased at the line
    # wrap. Not serialized: load_ppu_state retires the hold.
    stat_chg_dot*:       int32
    # The dot a deferred STAT write was parked on, so STAT_ENABLE_LATENCY can
    # tell that M-cycle's dots apart. Transient; not serialized.
    when STAT_ENABLE_EARLY:
      stat_wr_dot*:      int16
    stat_prev_mode*:     uint8
    # Present whenever any STAT lead is on (STAT_IRQ_SPLIT; on by default
    # through STAT_M0_LEAD_T and STAT_LYC_LY_LEAD_DOTS).
    when STAT_IRQ_SPLIT:
      # The mode and LY the STAT sources compare against, as opposed to what the
      # CPU reads back. Not serialized: re-derived on load (load_ppu_state).
      irq_mode*:         uint8
      irq_ly*:           uint8
      # The source's own `stat_chg_dot`, a different dot from the flag's when a
      # lead is on. Per-line, not serialized.
      irq_chg_dot*:      int16
      stat_if_dot*:      int32   # STAT_DISPATCH_MIN_AGE_DS: dot the STAT request last rose
      stat_if_ly*:       uint8
      stat_if_m0*:       bool    # ... and whether the mode-0 source's own edge raised it
      stat_if_m0_rise*:  bool    # set around the mode-0 source's edge detector call
    # Dots since the last frame was pushed, counted whether or not the PPU is
    # driving the panel. The panel refreshes at a fixed rate regardless, so
    # this is what keeps frame output steady across an LCD that switches off
    # and on again — see lcd_off_frame and ppu_lcd_enabled.
    dots_since_frame*:   int32
    # SGB colourisation, nil on non-SGB machines: the emitted pixel takes
    # sgb_pal[attr * 4 + shade], `attr` being the SGB attribute of the 8x8
    # screen cell (BG and objects share one palette per cell). See sgb.nim.
    sgb_pal*:       ptr UncheckedArray[uint16]
    sgb_attr*:      ptr UncheckedArray[uint8]
    # output
    framebuffer*:   seq[uint16]   # 160×144 BGR555
    frame*:         bool
    ran_bios*:      bool

  FetchStage* = enum
    fsSleep, fsGetTile, fsGetTileDataLow, fsGetTileDataHigh, fsPushPixel

  GbFifoPpu* = ref object of GbPpu
    fifo*:                GbPixelFifo
    fifo_sprite*:         GbPixelFifo
    fetch_counter*:       int
    fetcher_x*:           int
    # `SCX and 7` when this line's fine scroll was latched
    # (fifo_sample_smooth_scroll): the map column is screen position plus the
    # live SCX, so the low bits take part in the carry (SCX_FINE_BORROW in
    # fifo_ppu.nim). Per-line scratch; none of this block is serialized.
    scx_fine*:            int
    # The whole SCX term the fetcher adds to `fetcher_x`, `(SCX shr 3) - borrow`,
    # kept by `fifo_arm_scx` so the dot loop stays a single add. May be -1,
    # which `and 0x1F` wraps to column 31 (a borrow off column 0).
    scx_tile*:            int
    lx*:                  int32
    # The one `lx` either window rule can fire on this line -- the start
    # (WX - 7) while the window is not running, the re-trigger edge (WX - 8)
    # while it is -- or WIN_LX_OFF. Kept by fifo_arm_window so the shifter
    # spends one compare per mode 3 dot (a second per-dot branch is +1.7%).
    # Next to `lx` on purpose: after the bool block it costs +0.6%.
    win_lx*:              int32
    smooth_scroll_sampled*: bool
    dropped_first_fetch*: bool
    # The line's first `B01s` cycle (after the discarded head fetch) is
    # running: the one fetch that may not push early (M3_THROWAWAY_DOTS). Set
    # when the discarded fetch is aborted, cleared by that push. Per-line scratch.
    head_cycle*:          bool
    fetching_window*:     bool
    fetching_sprite*:     bool
    # The console, cached off GB.cgb_enabled: fetcher_retired and
    # fifo_irq_m0_ready decide the end of mode 3 per device (CGB_WIN_TAIL_LAST)
    # from the dot loop with no `gb` in hand. Re-derived on load.
    cgb*:                 bool
    # An object was fetched on the line's last pixel. Per-line scratch; read
    # only by fetch_work_pending on a CGB, where a window restart and an object
    # fetch on that pixel are one fetch slot (CGB_WIN_TAIL_LAST).
    obj_last_px*:         bool
    win_tail_end*:        int32   # WIN_TAIL_FLAG_LEAD: the dot a tail restart retires on (0 = none)
    # A window start owed to the next line: the WX comparator matched on the
    # line's last pixel, which a DMG's end-of-line cleanup cannot clear
    # (DMG_WIN_LAST_PX_CARRY). Consumed at the head of the next line whose
    # LCDC.5 is set, possibly in the next frame, so not per-line scratch; never
    # set on a CGB. Serialized from GB payload rev 6.
    win_carry*:           bool
    # LCDC.5 has been low since the carry above was owed, so spending it has to
    # REACTIVATE the window and not merely continue it -- worth
    # WIN_CARRY_REACT_LINES on the window line counter. Same lifetime as
    # win_carry, and serialized with it.
    win_carry_gap*:       bool
    # Dots of WIN_EN_HOLD left on a WX match LCDC.5 refused; while nonzero
    # `win_lx` is the hold's retry pixel. Per-line scratch. Down here in the
    # bool block, not beside `win_lx`: a byte between `lx` and `win_lx`
    # measured +0.6% of retired instructions on three games.
    win_hold*:            uint8
    # The last dot on which an SCX store still moves this line's fine scroll,
    # or -1. Exists only with SCX_FINE_LATCH_LIVE: an unconditional field here
    # measured +0.21% with the mechanism compiled out (the `win_lx` cliff).
    when SCX_FINE_LATCH_LIVE:
      scx_latch_until*:   int32
      # The discard target as the live window has moved it; `scx_fine` above is
      # the carry's reference and stands for the whole line
      # (SCX_LIVE_BORROW_LATCHED). Inside the same `when` as its field.
      when SCX_LIVE_BORROW_LATCHED:
        scx_live_fine*:   int32
    # Low three bits of the dot the line latched its fine scroll on: the slot
    # index the wrap needs, which `scx_latch_until` cannot supply once a store
    # has moved the window's end. A byte because that is all it is (int32
    # benches the same).
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
    # Dots of OBJ penalty charged on this line (the field tail's absorber).
    # Per-line scratch; down here rather than beside `scx_tile` because a word
    # between the fetch's fields costs more than the mechanism (`win_lx` cliff).
    when STAT_M0_TAIL_ANY:
      obj_dots_line*:     int32
    # `sprite_fetch_merge` runs on one dot but stands for two bitplane reads
    # OBJ_PLANE_GAP apart, each reading LCDC.2. `obj_hi_dot` is the dot the
    # high plane samples the bit on, latched at the trigger (OBJ_PLANE1_LAG);
    # it can be in the future, so the merge uses the bit as it stands and the
    # write path redoes the plane (fifo_obj_size_write) from `obj_fix_*`, which
    # is the whole of what a redo needs. `obj_fix_from` is the first dot such a
    # write can land on, OBJ_FIX_OFF when nothing is in flight. Per-line scratch.
    obj_hi_dot*:          int32
    # The last dot of the object's own fetch, latched at the trigger; read by
    # OBJ_ABORT_LATE to decide whether a write after the stall still cancels
    # it. The head arm stores a far-past sentinel. Per-line scratch.
    obj_abort_last*:      int32
    obj_fix_from*:        int32
    obj_fix_bank*:        int32
    obj_fix_lo*:          uint8
    obj_fix_h*:           uint8
    obj_fix_s*:           GbSprite
    # Idle dots left at the head of mode 3 (M3_PIPE_DELAY). A byte: the mode 3
    # dot loop asks "is the head spent?" ~6,200 times a frame and a byte is
    # `ldrb`+`cbz` where an int is `ldr`+`cmp`+`b.le`. 0..12 by construction.
    m3_delay*:            uint8
    # Dots the mode 3 -> 0 flag still owes after the fetcher retires, so line 0
    # (LY0_PIPE_MCYCLES) leaves mode 3 on the same dot as every other line.
    # Per-line scratch; a byte for the same reason m3_delay is.
    m3_hold*:             uint8
    # How far the pipeline lags the CPU's view of the PPU registers on THIS
    # line, in dots. Latched at the mode 2 -> 3 edge because the CPU M-cycle it
    # is derived from is 4 dots at normal speed and 2 in double speed. See
    # M3_PIPE_MCYCLES in fifo_ppu.
    m3_lead*:             int32
    # CGB only. `tdsel_dot` is the dot LCDC.4 last changed on (NO_TDSEL_CHANGE
    # if none this line); the fetcher reads the bit CGB_TDSEL_LATENCY dots
    # later and glitches a read on that exact dot. `tdsel_addr` is the most
    # recent $8000-region tile-data read's VRAM address, bank packed at bit 13
    # (TDSEL_ADDR_BANK) and the index path's arming at bit 14 and up
    # (TDSEL_IDX_SHIFT): both written by every unsigned bitplane read, and a
    # second field measured more than the rule costs. `tdsel_dot` and the
    # arming bits are per-line scratch; the address survives H-Blank because
    # the bus register it models does (CGB_TDSEL_GLITCH), so the address is
    # serialized (GB payload rev 6).
    tdsel_dot*:           int32
    tdsel_addr*:          int32
    # CGB only. `map_dot` is the dot the last change to either tile-map select
    # bit goes live at the fetcher (write dot + CGB_MAP_LATENCY), NO_MAP_CHANGE
    # if none this line; `map_old` is bits 3 and 6 before that write. A later
    # write inside an earlier one's latency wins. Per-line scratch.
    map_dot*:             int32
    map_old*:             uint8
    tile_num*:            uint8
    tile_attrs*:          uint8
    fetch_scy*:           uint8   ## SCY as of this fetch's map read; read
                                  ## back only when quirks.scy_fetch_latch
    tile_data_low*:       uint8
    tile_data_high*:      uint8
    # The FIFO pairs popped on the last MIX_HOLD emitting dots, indexed by the
    # pixel's low bits, so a mid-mode-3 write to a mixer-read register still
    # reaches the pixel already written out (fifo_recompose_last). Kept here
    # because neither ring can be indexed backwards safely. MIX_HOLD deep
    # because the tail burst emits `m3_lead` pixels ahead of their dots.
    mix*:                 array[MIX_HOLD, GbMixHold]
    # Deferred mode 3 (PLAIN_LAZY, fifo_ppu): the pipeline stands at
    # `lazy_dot` while `cycle_counter` runs on, up to `lazy_end`; 0 = not
    # deferred. Never in a save state: every writer syncs first.
    lazy_dot*:            int32
    lazy_end*:            int32
    # With the LCD off, the memory write count as of the last tick that left
    # the switched-off state settled (counter, mode, LY and markers reset,
    # no store in flight); -1 = unsettled. Until the next write, a tick only
    # moves the panel clock (fifo_tick). Scratch, not serialized.
    off_wc*:              int
    # The dot this line's pixel 0 would have left the shifter on if the current
    # unbroken run had started there (`cycle_counter - lx`, written at each
    # place the shifter stops, mixer_note_stop). The shifter's position reads
    # as `cycle_counter - tail_dot0` through stalls and the tail burst, where
    # `lx` does not move (MIXER_TAIL_DOTS, fifo_recompose_last).
    tail_dot0*:           int32
    # The first `lx` of that run, i.e. where the next run starts once the stall
    # clears; pixels before it are beyond the mixer's reach.
    mix_run*:             int32
    sprites*:             seq[GbSprite]
    # The mode-2 OAM scan's progress: the next OAM index and the line the
    # partial `sprites` belongs to. The scan normally runs as one burst at the
    # end of mode 2; these carry it only while an OAM DMA is changing OAM
    # underneath it (oam_scan_advance). Per-line scratch.
    scan_next*:           int32
    scan_line*:           int32
    # The mode-2 comparator's two input latches: the Y and X of the last
    # entry the scan read; an object's mode-3 fetch then replaces the Y latch
    # with its tile byte. An OAM DMA takes the OAM bus away from the scan,
    # and the scan does not stop -- it keeps stepping and keeps comparing
    # whatever these last held. See OAM_SCAN_DMA_HOLD (fifo_ppu.nim).
    scan_y_latch*:          uint8
    scan_x_latch*:          uint8
    # The window start's undo record (CGB_WIN_EN_DEFER): `win_defer` counts the
    # dots left before the start becomes final; the rest is what
    # `win_start_reset` overwrote on the match dot (`fifo_clear` leaves `data`
    # alone). Per-line scratch, never touched on a DMG. Inside its own `when`
    # because of the object-layout cliff `win_lx` records.
    when WIN_EN_REVOKE_ANY:
      win_defer*:         uint8
      win_revoking*:      bool
      wd_dot*:            int32
      wd_win_hold*:       uint8
      wd_head*:           int
      wd_tail*:           int
      wd_size*:           int
      wd_fetcher_x*:      int
      wd_fetch_counter*:  int
      wd_obj_tile_fx*:    int32
      wd_lx*:             int32
      wd_head_cycle*:     bool
      wd_tail_dot0*:      int32
      wd_mix_run*:        int32
    # The VRAM DMA's write port (VDMA_M3_PORT). `vdma_lost` is whether the byte
    # due on dot `vdma_lost_dot` meets the fetcher on the bus, decided a dot
    # before it; `vdma_copying` marks a block copy that may meet mode 3, the
    # only time the tail burst records which of its dots held the bus
    # (`vdma_tail_busy`, bit i = dot `vdma_tail_dot0 + i`, the dot after the
    # last pixel included). `vdma_held_lost`: the bytes of a held block
    # (HDMA_VISIBLE_DOTS) the port refused. Scratch inside one transfer or one
    # line; not serialized.
    vdma_lost*:           bool
    vdma_copying*:        bool
    vdma_held_lost*:      uint16
    vdma_lost_dot*:       int32
    vdma_tail_dot0*:      int32
    vdma_tail_busy*:      uint32
    # A pre-pixel match made by the WX a store just replaced (WIN_HEAD_WX_SCAN):
    # the start it is served by keeps the pre-pixel tile phase. Per-line.
    win_pre_old*:         bool
    # WIN_FINE_PAD: the fine-scroll pixels a window-start line's discard still
    # owes (fifo_pad_unpop), and the `lx` it settles them on. Per-line.
    win_pad*:             int32
    win_pad_lx*:          int32

  # ---- APU channels: the shared PSG (common/psg.nim) ----
  GbSoundChannel* = PsgChannel
  GbVolumeEnvChannel* = PsgEnvChannel
  GbChannel1* = PsgSweepSquare
  GbChannel2* = PsgSquare
  GbChannel3* = PsgWave
  GbChannel4* = PsgNoise

  GbApu* = ref object
    sound_enabled*:       bool
    buffer*:              seq[float32]
    buffer_pos*:          int
    frame_sequencer_stage*: int
    # Phase of the APU's 1 MHz tick grid, in scheduler cycles (an edge on every
    # cycle congruent to this modulo (4 shl speed)). The square channels'
    # frequency timers are clocked by it, so a trigger between edges waits for
    # the next (SameSuite channel_1_align_cpu). Reset by an APU power-on.
    # Serialized from GB payload rev 6 (an older state keeps the running
    # machine's phase).
    tick_phase*:          CycleCount
    # Phase of the half-rate (512 kHz) grid the noise channel's divisor stage
    # is clocked by: the power-on cycle modulo (8 shl speed), edges on the odd
    # 1 MHz ticks. NR43's divisor counts on it and a trigger cannot reset it
    # (SameSuite channel_4_frequency_alignment; psg_noise_first_inc).
    # Serialized as tick_phase.
    noise_phase*:         CycleCount
    # The first DIV-APU event after a power-on is skipped when DIV's tap bit
    # was already high (SameSuite div_write_trigger_10): the divider clocks
    # the sequencer, and that edge has already been accounted for. Live under
    # 2 ms, written only by a power-on; serialized from GB payload rev 6.
    div_skip*:            bool
    # Whether the sequencer's next step does not clock the length counter (the
    # "extra length clocking" gate on NRx4). A property of the divider's phase,
    # not of frame_sequencer_stage: while div_skip is pending the two disagree.
    first_half_of_length_period*: bool
    # The DIV-APU tap runs one M-cycle behind after an ODD number of switches
    # into double speed (AGE `speed-switch/spsw-ch2-lc-delay`; see
    # APU_SPSW_TAP_LAG_T in apu.nim). Toggled on each KEY1 switch into
    # double speed, cleared by either APU power edge (apu_drop_spsw_lag).
    # Serialized from GB payload rev 6.
    spsw_fs_lag*:         bool
    # Set by an APU power-on (and the boot hand-off), consumed by the next KEY1
    # switch: the first oscillator restart after a power-on re-phases the
    # APU's tick grid (apu_spsw_rephase, APU_SPSW_REPHASE_*). Serialized from
    # GB payload rev 7.
    spsw_rephase_pending*: bool
    # A double-speed step 7 whose envelope work is still to come
    # (GbQuirks.env_clock_ds_late, apu_env_late_due). Serialized from GB
    # payload rev 8.
    env_late_pending*:    bool
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
    # Nobody hears this core: get_sample skips the catch-up and the mix
    # (set_audio_silent; see the GBA APU). Not serialized.
    silent*:              bool
    # 2x speed: drop every other stereo frame at the queue point so
    # audio-driven pacing runs emulation twice as fast
    turbo*:               bool
    turbo_parity:         bool  # emscripten per-sample decimation state
    # Pitch-correct fast-forward (WSOLA); presentation-only, see the GBA APU.
    pitch_correct_ff*:    bool
    stretch:              TimeStretch
    stretch_engaged:      bool
    owns_audio*:          bool  # this core holds the audio queue (audio_out)
    channel1*:            GbChannel1
    channel2*:            GbChannel2
    channel3*:            GbChannel3
    channel4*:            GbChannel4
    # DC blocker charge per stereo side (GB_DC_CHARGE, get_sample).
    # Presentation state, not serialized: it re-converges within ~6 ms.
    dc_cap_left*:         float32
    dc_cap_right*:        float32
    # Mixer probe (test harness): while probe_period is non-zero the sample
    # event runs every probe_period scheduler cycles instead of
    # GB_SAMPLE_PERIOD and each pre-DC-blocker mix is compared with the first
    # one seen since probe_reset. gambatte's `_outaudio0/1` verdict is "every
    # sample of the final frame, at 2 MHz, equals the first"; probe_period = 2
    # is that stream. Observation only: the channels' closed-form catch-up
    # gives the same amplitudes at any cadence. Not serialized.
    probe_period*:        uint32
    probe_armed*:         bool      # first sample since the reset recorded
    probe_left*:          float32
    probe_right*:         float32
    probe_constant*:      bool
    probe_samples*:       int       # compared so far (after the skip)
    probe_skip*:          int       # samples to ignore before arming
    probe_limit*:         int       # stop comparing after this many (0 = never)
    left_resampler*:      Resampler[float32]
    right_resampler*:     Resampler[float32]
    resample_freq*:       int
    output_freq*:         int

  # ---- Memory ----
  GbMemory* = ref object
    wram*:                 array[8, seq[uint8]]
    wram_bank*:            uint8
    # SVBK ($FF70) as written, bits 0-2. The register holds what was stored;
    # `wram_bank` is the bank that value maps at $D000 (0 maps bank 1). The
    # two differ only for a stored 0 (SVBK_READS_WRITTEN, memory.nim).
    svbk*:                 uint8
    # RP ($FF56): bits 0/6/7 are stored (LED and the read-enable pair);
    # readback ORs $3E -- bits 2-5 read set, bit 1 is "no IR signal", which
    # is all this models. hardware: gbedge p00 on AGS reads $3E at boot.
    rp*:                   uint8
    # OPRI ($FF6C) bit 0, readable and writable in CGB mode only (Pan Docs,
    # "FF6C — OPRI"). Storage only: Pan Docs has a write after the boot ROM
    # unmaps change nothing (TO BE VERIFIED there), and the priority the
    # renderer uses stays the one the operating mode picks. 0 at hand-off for
    # a CGB cart (AGS gbedge p00 reads $FE). Serialized from GB payload rev
    # 9 (an older state loads 0).
    opri*:                 uint8
    hram*:                 array[0x7F, uint8]
    # $FEA0-$FEFF: real RAM on CGB 0-D (Pan Docs, "FEA0-FEFF range"); which
    # model applies is GbQuirks.unusable_region. Serialized from GB payload
    # rev 6, with `rp`.
    unusable*:             array[0x60, uint8]
    bootrom*:              seq[uint8]
    cycle_tick_count*:     int
    ppu_mdot_shift*:       int
      # SPEED_SWITCH_LEAF_PPU: CPU clocks -> PPU dots in mem_tick_ppu, the
      # speed (`current_speed`), or PPU_SIT_OUT while the PPU sits out a leaf
      # switch's oscillator restart (the divider's GbTimer.hold_t).
    write_count*:          int   # every write_byte, for the idle-loop verdict
    # A CPU write this M-cycle left something for the M-cycle boundary (an IF
    # store, a STAT interrupt-line edge). The byte lands before the M-cycle's
    # PPU dots; the interrupt half stays on the boundary. See mem_flush_deferred.
    write_deferred*:       bool
    # The register write that flag stands for when it is a whole store: FF41
    # or FF55, the two that gate a PPU event (ppu_write_machinery). 0 = none;
    # one slot, drained before a second can be recorded. Not serialized.
    deferred_reg*:         uint16
    deferred_val*:         uint8
    when CGB_LYC_EDGE_DEFER and CGB_LYC_EDGE_POLL:
      # The POLL form of CGB_LYC_EDGE_DEFER (control only). On GbMemory
      # because `mem_tick_ppu` already has `mem` in hand and sits on clang's
      # inline threshold. Can be live across an instruction boundary, so this
      # form would need a GB payload rev; the default parks the edge in the
      # scheduler's serialized event array.
      lyc_edge_owed*:      bool
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
    # OAMDMA_HALT_PAUSE: the unit was frozen by a HALT on the previous M-cycle,
    # so the wake M-cycle can be charged for the bus hand-back. Scratch.
    dma_was_halted*:       bool
    # VDMA_OAM_BUS_CAPTURE: a VRAM DMA owns the external bus this M-cycle, so
    # an OAM DMA slot inside it gets nothing of its own done. Scratch inside
    # one ppu_copy_hdma_block; not serialized.
    vdma_bus_hold*:        bool
    next_dma_counter*:     uint8
    # Cache of `dma_position in 1 .. 0xA0` (the unit owns a bus), maintained
    # by mem_dma_tick; every CPU access tests it (gb_recompute_dma_derived).
    dma_busy*:             bool
    # Which bus the running OAM DMA owns (GbDmaBus ordinal), the byte it last
    # put on it, and the source's Drive* class. All derived from
    # current_dma_source and dma_position.
    dma_bus*:              uint8
    dma_latch*:            uint8
    dma_drive*:            uint8
    dma_openbus*:          bool
    requested_speed_switch*: bool
    current_speed*:        uint8

  # ---- Main GB type ----
  GB* = ref object of EmuObj
    # Idle-loop skip (cpu.nim): the scheduler cycle of the last point anything
    # a polling loop reads could have changed (a PPU stop, a non-APU event, the
    # timer's slow path, input, STOP). A skip needs the iteration it copies to
    # have started after it. Scratch.
    wl_mark*:        CycleCount
    bootrom_path*:   string
    rom_path*:       string
    # Two model axes. `cgb_enabled` is the CONSOLE: a CGB/AGB SoC, which decides
    # timing and SoC quirks whatever cart is inserted. `cgb_native` is the MODE:
    # the CGB register set and graphics are in use. A DMG cart on a CGB runs in
    # DMG-compatibility mode (KEY0 set at hand-off): KEY1/HDMA/SVBK/VBK/BCPD/
    # OCPD/PCM12/PCM34 read as unmapped (mooneye misc/bits/unused_hwio-C), map
    # attributes and the OBJ palette/bank nibble are not decoded, LCDC.0 is BG
    # on/off, objects are X-ordered, and BGP/OBP index palette 0. The boot ROM
    # itself always runs native. `cgb_native` is a cached derivation read per
    # pixel; keep it in step via gb_sync_cgb_native wherever its inputs move.
    cgb_enabled*:    bool
    cgb_native*:     bool
    # Frontend opt-in for Super Game Boy emulation; default off. Consulted only
    # at post_init, where the cart header has the final say.
    sgb_requested*:  bool
    headless*:       bool
    run_bios*:       bool
    cartridge*:      Mbc
    rom_size*:       uint32
    ram_size*:       int
    cgb_flag*:       CgbFlag
    boot_model*:     GbBootModel
    # Set by gb_set_revision (new_gb, then any --model= override). Serialized
    # from GB payload rev 6: a load re-resolves boot_model and the quirks
    # from it, so a --model=cgb0 state loads as that revision.
    revision*:       GbRevision
    quirks*:         GbQuirks
    rom_title*:      string
    scheduler*:      Scheduler
    cpu*:            GbCpu
    interrupts*:     GbInterrupts
    joypad*:         GbJoypad
    ppu*:            GbPpu
    # The same object as `ppu`, typed as the renderer that extends the shared
    # base. Non-owning: `ppu` owns it.
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
    # HBlank-DMA scratch (HDMA_WAKE_BLIND_DOTS). Kept here, at the end of the
    # machine object, and not in GbPpu: a field inserted into GbPpu moves
    # GbFifoPpu's hot state (+0.5% retired instructions measured). Live only
    # across a halt; not serialized.
    hdma_wake_dot*:    int32   # the dot the CPU last woke from a HALT on
    # The comparator-lead sources entering and leaving vblank (STAT_M1_LEAD,
    # VBLANK_IRQ_LEAD, STAT_M2_LY0_LEAD): up ahead of the boundary, cleared on
    # it, so never live at a frame edge. Here for the same layout reason.
    m1_early*:         bool
    vbl_early*:        bool
    m2_ly0_up*:        bool
    stat_hold*:        uint8   # STAT_HOLD_* / STAT_LAND_AFTER: live inside one dot's steps. Scratch.
    # DMG_HALT_MIN_MCYCLES: the scheduler cycle the CPU halted on. Scratch.
    halt_start*:       CycleCount
    m0_late_fire*:     bool    # LCDON_M0_LAG_DS: the LCD-on line's mode-0 source is owed
    dma_halt_grace*:   uint8   # OAMDMA_HALT_GRACE: the halted M-cycle the OAM DMA still gets
    hdma_start_req*:   bool    # HDMA_START_GRANT_FETCH: the owed block was raised by FF55
    gdma_req*:         bool    # GDMA_GRANT_FETCH: a general-purpose burst waits for the next opcode fetch
    # HDMA_HALT_REQ: an HBlank request the HALT's (or the speed switch's) own
    # execute cycle took. `hdma_halt_open` is live from the HALT to
    # the PPU's next mode change; `hdma_halt_taken` and `hdma_latch` across the
    # whole halt (serialized, GB_SEC_MACH); the rest inside one instruction.
    hdma_halt_open*:   bool
    hdma_halt_taken*:    bool
    hdma_latch*:       uint8   # the byte that execute cycle read
    hdma_latch_run*:   bool    # the stall's end owes the latched byte its execution
    hdma_absorb*:      bool    # the paid block and its hand-back are in progress
    hdma_switch_stall*: bool   # the speed switch's stall: a halt for the edge detector
    vdma_residue*:     int16   # VDMA_BUS_RESIDUE: the cartridge bus's byte at the hand-over (+1; 0 = none)
    hdma_boundary_grant*: bool # HDMA_BOUNDARY_ACQUIRE: the block now granted is at an instruction boundary
    we_off_dot*:       int32   # CGB_WE_DISABLE_LATE: dot a CGB LCDC.5 fall reaches the fetcher
    we_on_dot*:        int32   # CGB_WE_ENABLE_FETCH_LATE: dot a CGB LCDC.5 rise reaches it (per line)
    wd_fifo*:          GbPixelFifo  # WIN_REVOKE_DS_PUSH: the ring at a CGB double-speed window start
    wd_ds_push*:       bool
    wd_ds_ly*:         uint8
    # CGB_LYC_CMP_LATCH: the LYC the LY = LYC STAT source compares against
    # (equal to ppu.lyc except while a CGB write is in flight to it), the
    # write in flight (dots left until it lands, -1 = none; its value), and
    # whether the last landing carried a match across the LY step. In flight
    # for at most five dots; not serialized (load_ppu_state re-derives).
    lyc_sampled*:      uint8
    lyc_land_val*:     uint8
    lyc_land_left*:    int8
    lyc_bridge*:       bool
    # LYC_PARK_OPEN_DMG: the DMG LYC write parked over this M-cycle replaced
    # an LYC the line ending did not match. Scratch within one M-cycle.
    lyc_park_open*:    bool
    # M0_REQ_LAST_PX: the dot of this line from which only last-pixel work
    # holds mode 3 open, -1 = not yet. Scratch within one mode 3.
    m0_tail_dot*:      int32
    # LYC_STOP_FOLDED (fifo_ppu.nim): while that write is in flight the
    # window check's dot slot (ppu.win_check_dot) is on loan as a stop for
    # the idle skip; its own value waits here.
    lyc_stop_lent*:    bool
    lyc_stop_saved*:   int32
    when defined(test_harness):
      test_output*:  TestOutput

# ==================== FETCHER ORDER ====================
const FETCHER_ORDER*: array[-5 .. 23, FetchStage] = [
  # Steps -5..-1 are the window startup fetch's idle head, entered only by a
  # line that starts as a window line (WIN_HEAD_ABSORB): the fetcher waits out
  # `WX - 1` dots as negative steps, which costs the dot loop nothing since
  # fsSleep's `inc` walks the counter back to 0. Five entries cover WX < 7.
  fsSleep, fsSleep, fsSleep, fsSleep, fsSleep,
  fsSleep, fsGetTile, fsSleep, fsGetTileDataLow,
  fsSleep, fsGetTileDataHigh, fsSleep, fsPushPixel,
  # Steps 8..15 and 16..23 are fetches a CGB window re-trigger cut
  # (CGB_WIN_RETRIG_LATCH), entered only from fifo_win_retrig_cgb at the
  # matching step of 0..7 and left by the push like any other: 8..15 never
  # reads the tile number (the planes use the one still latched), 16..23 had
  # its low plane read at the re-trigger with the previous number.
  fsSleep, fsSleep, fsSleep, fsGetTileDataLow,
  fsSleep, fsGetTileDataHigh, fsSleep, fsPushPixel,
  fsSleep, fsGetTile, fsSleep, fsSleep,
  fsSleep, fsGetTileDataHigh, fsSleep, fsPushPixel,
]
static: doAssert WIN_LINE_START_WX - 2 <= 5,
  "WIN_HEAD_ABSORB idles WX - 1 dots; FETCHER_ORDER's negative head must cover it"

# The DMG's four shades, lightest first, as BGR555 greys: a code, not a look.
# Every picture of a black-and-white game (the screen, the glow, tiles,
# clips) translates them into the player's shade palette; tests read them as
# greys. Save states from before carry the old amber four (savestate.nim).
const DMG_COLORS*: array[4, uint16] = [0x7FFF'u16, 0x56B5'u16, 0x294A'u16, 0x0000'u16]

# The DMG shades before they were greys, lightest first: what states taken by
# earlier builds carry (savestate.nim regrey_dmg_shades).
const OLD_DMG_COLORS*: array[4, uint16] = [0x6BDF'u16, 0x3ABF'u16, 0x35BD'u16, 0x2CEF'u16]

func dmg_shade*(v: uint16): int =
  ## Which of DMG_COLORS a framebuffer pixel is (0..3), or -1.
  let c = v and 0x7FFF'u16
  for i, d in DMG_COLORS:
    if c == d: return i
  -1

# The CGB's DMG-compatibility palettes, shade 0 (lightest) to 3: the fallback
# the boot ROM loads for any cart without a Nintendo licensee code, i.e. every
# homebrew and test ROM (game-boy-test-roms' mealybug howto; AGE `ncm*`).
# BG #FFFFFF #7BFF31 #0063C6 #000000, OBJ #FFFFFF #FF8484 #943939 #000000, in
# BGR555. The per-title table is Nintendo's boot ROM data and is not
# reproduced; no test ROM reaches it.
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

# The share of the output's -1..1 range given to one channel's DAC
# (get_sample). Four DACs sum to -4..4 (Pan Docs, Audio Details); the DC
# blocker emits `mix - cap`, both bounded by the mixer range, so 1/4 clips
# (a powered-off DAC parks at +1 and the mean sits near a rail) and 1/8 makes
# overflow impossible: |mix| <= 1/2, |cap| <= 1/2, |out| <= 1.
const GB_MIX_SCALE* = 1.0'f32 / 8.0'f32

# NR50 master volume by the 3-bit field, folded with GB_MIX_SCALE. Pan Docs,
# NR50: value 0 is a volume of 1 and 7 a volume of 8, and the amplifier never
# mutes a non-silent input -- so (V+1)/8, not V/7.
const GB_MASTER_VOLUME* = block:
  var t: array[8, float32]
  for v in 0 .. 7: t[v] = float32(float64(v + 1) / 8.0) * GB_MIX_SCALE
  t

# Output-stage DC blocker. A channel's DAC idles at a rail, not mid-range
# (GB_DAC_LUT), so the mix carries a large DC offset that steps whenever a DAC
# powers up or down or panning/volume changes; hardware couples the mixer to
# the jack through a capacitor. One-pole model: `out = in - cap; cap = in -
# out * charge`, with charge per output sample = 0.999958 ** (GB_CLOCK_SPEED /
# rate): at 32768 Hz a 28 Hz corner, below anything the APU can play.
const GB_DC_CHARGE* = 0.9946383125'f32
const GB_FRAME_SEQ_RATE*  = 512
const GB_FRAME_SEQ_PERIOD* = GB_CLOCK_SPEED div GB_FRAME_SEQ_RATE

# Post-boot VRAM tile data: blank tile $00, the logo ($01-$18) and the (R)
# tile ($19). Several mealybug ROMs rely on the boot ROM having left them.
# The logo is not hardcoded: it is decompressed at boot from the loaded
# cartridge's own header ($104-$133), exactly as the boot ROM does, so a
# corrupted header logo renders corrupted as on hardware.
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

# Deterministic-RTC override for lockstep/rollback netplay: the MBC3 clock must
# neither read the local wall clock (differs between peers) nor free-run (tick
# count differs between a run and its rollback re-simulation). >= 0 is the
# shared "now" both peers pass at connect; the clock is then frozen. -1 = real,
# free-running clock. Mirrors the GBA core's enable_deterministic_rtc.
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
      # Never a half-written file: see gba storage.nim write_save.
      write_file_atomic(cart.sav_path, data)
      cart.ram_dirty = false
      cart.save_error = ""
    except IOError, OSError:
      if cart.save_error.len == 0:
        cart.save_error_new = true
        echo "Failed to write save file: ", cart.sav_path
      cart.save_error = getCurrentExceptionMsg()

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
  ## Dots this machine's write to a palette register arrives at the mixer
  ## after the DMG's: the revision decides whether CGB_MIXER_LATENCY is
  ## charged. Declared here because the PPU files are included below.
  if gb.cgb_enabled and not gb.quirks.mixer_write_immediate:
    int32(CGB_MIXER_LATENCY)
  else:
    0'i32

proc gb_lcdc_mixer_latency*(gb: GB): int32 {.inline.} =
  ## The same dot for LCDC, which CGB-D does NOT drop: mealybug's `_cgb_c` and
  ## `_cgb_d` captures differ on the palette ROMs (`m3_bgp_change`,
  ## `m3_obp0_change`) and are identical on the LCDC ones
  ## (`m3_lcdc_{bg,obj}_en_change`), so gating it costs both at once.
  if gb.cgb_enabled: int32(CGB_LCDC_MIXER_LATENCY) else: 0'i32

# ==================== INCLUDES ====================
# Textual includes, not imports: the whole GB core is one module (one C
# translation unit), so the files share a namespace and inline across each
# other without LTO (docs/dev/notes/architecture.md). Forward declarations below free
# most of the ordering; the one hard constraint is at the CPU group.

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
# Forward declaration needed by apu.nim (defined in timer.nim, included
# below): an APU power cycle re-aims the DIV-APU edge, because the lag a speed
# switch leaves on the tap does not survive the power. See APU_SPSW_TAP_LAG_T.
proc apu_div_phase*(t: GbTimer; gb: GB): int
include apu/psg_host
include ../common/psg_channels
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
# Deferred mode 3 (PLAIN_LAZY, fifo_ppu.nim): anything that reads the
# pipeline, or changes what it reads, runs the deferred dots first.
proc fifo_lazy_sync*(ppu: GbFifoPpu; gb: GB) {.noinline.}
template fifo_sync*(gb: GB) =
  if gb.fifo_ppu.lazy_end != 0:
    fifo_lazy_sync(gb.fifo_ppu, gb)
include sgb
include joypad
# Video: shared PPU base + the FIFO renderer
# Forward declarations needed by ppu.nim (defined in memory.nim included later).
# hot_bus_inline is defined here rather than in memory.nim because the forward
# declarations below must carry the same pragma as their implementations: on
# non-clang targets it expands to `inline`, and Nim rejects an implementation
# whose pragmas the forward declaration lacks (the clang codegenDecl form
# slips through, so only the gcc/mingw builds catch a mismatch).
# The rationale for the pragma itself lives with mem_tick_bus in memory.nim.
when defined(clang):
  {.pragma: hot_bus_inline,
    codegenDecl: "__attribute__((always_inline)) inline $# $#$#".}
else:
  {.pragma: hot_bus_inline, inline.}
proc mem_tick_components*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true; ignore_speed = false) {.inline.}
proc mem_tick_bus*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true;
                   defer_hdma = false) {.hot_bus_inline.}
proc mem_tick_ppu*(mem: GbMemory; gb: GB; cycles: int; ignore_speed = false) {.hot_bus_inline.}
proc mem_dma_tick*(mem: GbMemory; gb: GB; cycles: int)
proc mem_vdma_bus_capture*(mem: GbMemory; gb: GB; src_lo: uint8; val: uint8)
proc read_byte*(mem: GbMemory; gb: GB; idx: int): uint8
proc write_byte*(mem: GbMemory; gb: GB; idx: int; val: uint8)
proc fifo_oam_bus_taken*(ppu: GbFifoPpu; gb: GB)
proc vdma_port_busy*(gb: GB): bool {.noinline.}
proc fifo_wx_store_head*(ppu: GbFifoPpu; old_wx: uint8) {.noinline.}
const GB_IDLE_SKIP* {.intdefine.} = 1
  ## Idle loops and HALT skipped up to the next point they can observe
  ## (cpu.nim, wl_head_check / wl_halt_skip); 0 runs every M-cycle.
const GB_APU_EVENTS* = {etAPUFrameSeq, etAPUSample, etAPUChannel1,
                        etAPUChannel2, etAPUChannel3, etAPUChannel4}
  ## Events that change nothing but the APU: an idle skip runs through them.

include ppu
include fifo_ppu
when defined(cpu_testbus):
  # The single-instruction test build (tests/singlestep_test.nim): the CPU's
  # reads and writes go to a flat 64 KB test bus instead of the memory map.
  # The M-cycle is still ticked, so the driver can place each access in it.
  # Compiled out of every other build: nothing on the shipping path tests
  # for them.
  var gb_testbus_read*: proc(address: int): uint8 {.nimcall.}
  var gb_testbus_write*: proc(address: int; value: uint8) {.nimcall.}

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
when HDMA_HALT_REQ != 0:
  proc cpu_latched_op*(cpu: GbCpu; gb: GB): int
proc cpu_lock*(cpu: GbCpu)
include cb_opcodes
include opcodes
include cpu

# ==================== HARDWARE REVISION ====================

const GB_UNUSABLE_ZERO* = defined(gb_unusable_zero)
  ## Control arm: answer `$00` for `$FEA0..$FEFF` on every revision. With it
  ## the revision axis is behaviour-neutral row for row.

proc gb_quirks_for*(rev: GbRevision): GbQuirks =
  ## The whole revision -> behaviour table, in one place. A revision that names
  ## no flag here behaves exactly like the default machine; adding a revision
  ## therefore costs nothing until some test ROM proves it differs.
  GbQuirks(
    length_clock_any_nrx4: rev in {grCgb0, grCgbAB},
    mixer_write_immediate: rev in {grCgbD, grCgbE},
    wx_write_late: rev == grAgb,
    scy_fetch_latch: rev in {grCgbD, grCgbE, grAgb},
    pcm_read_edge_zero: rev in {grCgb0, grCgbAB, grCgbC},
    cgb_c_or_older: rev in {grCgb0, grCgbAB, grCgbC},
    square_reload_halftick: rev in {grCgbD, grCgbE},
    lyc_compare_hold: rev in {grCgbD, grCgbE, grAgb},
    oam_read_open_late: rev == grCgbE,
    spsw_div_mid_taps_slow: rev == grCgbE,
    spsw_irq_leaf_hold_short: rev == grCgbE,
    spsw_apu_rephase_2mhz: rev == grCgbE,
    env_clock_ds_late: rev == grCgbE,
    ly_read_edge_late: rev in {grCgbD, grCgbE, grAgb},
    m1_end_no_mode0: rev in {grCgbD, grCgbE, grAgb},
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
  ## Parse a `--model=` / test-row token: mooneye filename suffixes, AGE device
  ## tokens and SameSuite `-cgb0B` / `-cgbDE` ranges. A range resolves to its
  ## highest member, so a `-cgb0` / `-cgbB` pair resolves to two revisions.
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

proc new_gb*(bootrom_path: string; rom_path: string; headless: bool; run_bios: bool; force_cgb = false; force_dmg = false): GB =
  ## force_cgb runs a DMG-flagged cart in CGB mode (a DMG cart in a Game Boy
  ## Color; mooneye misc/ asserts it). force_dmg runs a CGB-flagged cart as a
  ## DMG, which no console does but gambatte's suite needs: it selects the
  ## device from the runner, not the header (--mode=gambatte). force_cgb wins.
  result = GB(
    bootrom_path: bootrom_path,
    rom_path:     rom_path,
    headless:     headless,
    run_bios:     run_bios,
    sgb_requested: false,
  )
  result.cartridge = load_cartridge(rom_path)
  result.cheats = new_cheat_engine(cpGB)
  # Pan Docs, "0143 — CGB flag" and "Power Up Sequence": the CGB boot ROM
  # tests bit 7 alone. Clear: it writes $04 to KEY0 (DMG compatibility mode).
  # Set: it copies the whole byte to KEY0, whose bit 2 is DMG compatibility
  # mode ("FF4C — KEY0"), so $81-$83, $90, $C0 ... are CGB carts and $84-$87
  # are not; bit 6 is ignored ($C0 runs as $80). Bit 3 is the "PGB" mode
  # ($88-$8F), which Pan Docs leaves unresearched and dingbat does not model:
  # those carts stay on the compatibility path.
  let cgb_byte = result.cartridge.rom[0x0143]
  let cgb_device = (cgb_byte and 0x80'u8) != 0   # the cart asks for a CGB
  result.cgb_flag =
    if (cgb_byte and 0x8C'u8) != 0x80'u8: cgbNone
    elif (cgb_byte and 0x40'u8) != 0:     cgbExclusive
    else:                                 cgbSupport
  # A boot ROM only implies CGB mode when it *is* a CGB boot ROM: the DMG one
  # is 256 bytes, the CGB one 0x900. Sizing it (rather than assuming CGB for
  # any boot ROM) lets a DMG boot ROM boot a DMG cart as a DMG.
  let cgb_bootrom = bootrom_path.len > 0 and run_bios and
                    fileExists(bootrom_path) and getFileSize(bootrom_path) > 0x100
  # Any bit-7 cart picks the CGB console, a KEY0 bit 2/3 one in compatibility
  # mode there (cgb_native, gb_sync_cgb_native).
  result.cgb_enabled = force_cgb or
    ((cgb_bootrom or cgb_device) and not force_dmg)
  when CGB_LYC_CMP_LATCH: result.lyc_land_left = -1
  # Default revision: the one the references are scored against. CGB C --
  # mealybug's `_cgb_c` set (`m3_bgp_change` exact at CGB_MIXER_LATENCY = 1),
  # `cgb-acid-hell`'s `$FEA0` branch. DMG ABC -- mooneye `boot_regs-dmgABC`,
  # `boot_div-dmgABCmgb`. The harness may override via --model before post_init.
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
  # The boot ROM powered the APU on and switched no speed.
  gb.apu.spsw_rephase_pending = true

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
    if kind notin GB_APU_EVENTS: gb.wl_mark = gb.scheduler.cycles
    case kind
    of etAPUFrameSeq:
      # Models the falling edge of the divider's APU tap. Free-running at the
      # tap's own period; a DIV write re-aims it (timer.nim).
      tick_frame_sequencer(gb.apu, gb)
      gb.scheduler.schedule(apu_div_period(gb), etAPUFrameSeq)
    of etAPUSample:    get_sample(gb.apu, gb)
    # Channels carry a closed-form next_step deadline instead of per-period
    # events (common/psg.nim PsgChannel.next_step); these arms are only reachable from a state
    # saved by an older build, and dropping the event is the right answer.
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
    of etGbLycEdge:
      # A CGB LYC write's STAT edge, one M-cycle past the boundary its byte
      # landed on (CGB_LYC_EDGE_DEFER).
      when CGB_LYC_EDGE_DEFER and not CGB_LYC_EDGE_POLL:
        when LCDON_M0_LAG_DS != 0:
          if gb.m0_late_fire:
            gb.m0_late_fire = false
            if gb.ppu.first_line and (gb.ppu.lcd_status and 3'u8) == 0'u8:
              ppu_set_irq_mode(gb.ppu, gb, 0'u8)
            return
        ppu_handle_stat_interrupt(gb.ppu, gb)
    of etHandleInput:
      # Booked only by the test harness's timed input (joypad.nim).
      when defined(test_harness):
        if gb_harness_input != nil: gb_harness_input(gb, false)
      else: discard
    else: discard

proc post_init*(gb: GB) =
  gb.scheduler  = new_scheduler()
  gb.interrupts = new_gb_interrupts()
  gb.apu        = new_gb_apu(gb, gb.headless)
  gb.joypad     = new_gb_joypad()
  let p = new_gb_fifo_ppu(gb)
  gb.ppu = p
  gb.fifo_ppu = p
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
  else:
    gb.timer.tdiv = uint16(BOOT_ROM_DIV_START_T)
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
  # A frame boundary is where every state is written (rewind, rollback, the
  # slots), so run on past anything the format does not hold; the machine runs
  # the same instructions either way, only the host's frame edge moves (by
  # under a line). A frame can end inside one long instruction: the speed
  # switch's stall (SPEED_SWITCH_STALL_CPU) runs the PPU past the V-blank that
  # set `frame`. Not in the format, in order: a VRAM DMA an FF55 write has
  # requested but the CPU has not granted (GDMA_GRANT_FETCH,
  # HDMA_START_GRANT_FETCH; the next opcode fetch answers it);
  if gb.gdma_req or gb.hdma_start_req: gb.cpu.tick(gb)
  # a CGB dispatch's hold on its timer or serial line (GbInterrupts.
  # clear_line, under 16 T-cycles), LCD on or off;
  while irq_clear_live(gb.interrupts, gb.scheduler.cycles): gb.cpu.tick(gb)
  # a DMG HALT inside its minimum window (DMG_HALT_MIN_MCYCLES; at most that
  # many halted M-cycles, a wake ends it);
  when DMG_HALT_MIN_MCYCLES > 1:
    while not gb.cgb_enabled and gb.cpu.halted and not gb.cpu.stopped and
          gb.scheduler.cycles - gb.halt_start <
            CycleCount(4 * DMG_HALT_MIN_MCYCLES):
      gb.cpu.tick(gb)
  # mode 3 (the renderer's per-line scratch, load_ppu_state); a CGB LYC write
  # in flight to the comparator (GB.lyc_sampled, at most two dots past its
  # instruction), or a dispatch hold met again. `settle` bounds all but mode
  # 3, so back-to-back writes cannot hold the frame. A CPU in STOP freezes the PPU (mem_tick_stopped) and is
  # left where it is.
  var settle = 4
  while gb.ppu.lcd_enabled and not gb.cpu.stopped:
    if (gb.ppu.lcd_status and 3'u8) == 3'u8: discard
    elif CGB_LYC_CMP_LATCH and gb.lyc_land_left >= 0 and settle > 0: dec settle
    elif IRQ_SAMPLE_CGB_TIMER_SERIAL_ADD != 0 and settle > 0 and
         irq_clear_live(gb.interrupts, gb.scheduler.cycles): dec settle
    else: break
    gb.cpu.tick(gb)
  gb.ppu.frame = false
  if gb.sgb != nil: sgb_frame_end(gb)
  let moved = gb.gb_rebase()
  # The HALT start is a scheduler time too (wrapping, so the age survives).
  when DMG_HALT_MIN_MCYCLES > 1: gb.halt_start -= moved
  # Times the rebase would leave pointing into the new frame: a dispatch's
  # line hold (settled above, so over) and the serial tap edge's M-cycle.
  gb.interrupts.clear_line = 0
  when SERIAL_CPU_SAMPLE_T < 4: gb.serial.edge_cycle = high(CycleCount)

method run_until_frame*(gb: GB) = gb.step_frame()

method handle_input*(gb: GB; inp: Input; pressed: bool) {.base.} =
  gb.joypad.handle_input(gb, inp, pressed)

method toggle_sync*(gb: GB) =
  gb.apu.toggle_sync()

# Save-state visitor over every component above (also serves rewind/rollback)
include savestate
