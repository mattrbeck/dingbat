# GB SM83 CPU (included by gb.nim)

proc new_gb_cpu*(): GbCpu =
  GbCpu(pc: 0, sp: 0, ime: false, halted: false, halt_bug: false,
        locked: false, stopped: false, cached_hl: -1)

proc skip_boot*(cpu: GbCpu; gb: GB) =
  # CPU registers at PC=0x100, per hardware model (mooneye boot_regs-* /
  # misc/boot_regs-*; Pan Docs "Power-Up Sequence"). SP=0xFFFE, PC=0x0100
  # for every model.
  cpu.pc = 0x0100
  cpu.sp = 0xFFFE
  case gb.boot_model
  of bmDmg0:
    cpu.af = 0x0100; cpu.bc = 0xFF13; cpu.de = 0x00C1; cpu.hl = 0x8403
  of bmDmgABC, bmMgb:
    # H and C at handoff carry the header-checksum compare's result: both set
    # unless $014D is $00 (Pan Docs Power-Up Sequence, [^dmg_c]). Every test
    # ROM has a nonzero checksum, so the suites only ever see $B0.
    let rom = gb.cartridge.rom
    let f = 0x80'u16 or (if rom.len > 0x014D and rom[0x014D] == 0: 0'u16
                         else: 0x30'u16)
    cpu.af = (if gb.boot_model == bmMgb: 0xFF00'u16 else: 0x0100'u16) or f
    cpu.bc = 0x0013; cpu.de = 0x00D8; cpu.hl = 0x014D
  of bmSgb:
    cpu.af = 0x0100; cpu.bc = 0x0014; cpu.de = 0x0000; cpu.hl = 0xC060
  of bmSgb2:
    cpu.af = 0xFF00; cpu.bc = 0x0014; cpu.de = 0x0000; cpu.hl = 0xC060
  of bmCgb0, bmCgbABCDE, bmAgb:
    # CGB family. A=0x11 always; the AGB boot ROM's extra `INC B` before
    # handoff makes B=0x01 (nonzero → Z cleared, so F=0x00) instead of the
    # CGB's B=0x00 / F=0x80. D/E/H/L depend on whether a native CGB cart or a
    # DMG-compatibility cart is inserted (mooneye misc/boot_regs-cgb vs -A run
    # a DMG-flagged cart on CGB/AGB hardware).
    if gb.cgb_flag != cgbNone:
      # Native CGB cart: fixed values.
      if gb.boot_model == bmAgb:
        cpu.af = 0x1100; cpu.bc = 0x0100
      else:
        cpu.af = 0x1180; cpu.bc = 0x0000
      cpu.de = 0xFF56; cpu.hl = 0x000D
    else:
      # DMG cart on CGB/AGB hardware: B, F and HL come from the HEADER (Pan
      # Docs Power-Up Sequence [^cgbdmg_b]/[^cgbdmg_hl]/[^agbdmg_f]). For a
      # Nintendo-licensee cart B is the 16 title bytes summed (the same value
      # the boot ROM's colorization hash leaves behind); the AGB's extra
      # `inc b` follows, and its Z/H land in F. HL = $991A marks the two
      # logo-animation palette IDs. Homebrew/test ROMs are non-Nintendo, so
      # the suites see the old fixed B=0/HL=$007C either way.
      let rom = gb.cartridge.rom
      var b = 0'u8
      if rom.len > 0x0145 and
         (rom[0x014B] == 0x01 or
          (rom[0x014B] == 0x33 and rom[0x0144] == 0x30 and rom[0x0145] == 0x31)):
        for i in 0x0134 .. 0x0143: b = b + rom[i]
      if gb.boot_model == bmAgb:
        let half = (b and 0x0F) == 0x0F
        b = b + 1
        cpu.af = 0x1100'u16 or (if b == 0: 0x80'u16 else: 0'u16) or
                               (if half:   0x20'u16 else: 0'u16)
        cpu.hl = if b in [0x44'u8, 0x59'u8]: 0x991A'u16 else: 0x007C'u16
      else:
        cpu.af = 0x1180
        cpu.hl = if b in [0x43'u8, 0x58'u8]: 0x991A'u16 else: 0x007C'u16
      cpu.bc = uint16(b) shl 8
      cpu.de = 0x0008

proc cpu_memory_at_hl*(cpu: GbCpu; gb: GB): uint8 =
  if cpu.cached_hl < 0:
    cpu.cached_hl = int(mem_read(gb.memory, gb, int(cpu.hl)))
  uint8(cpu.cached_hl)

proc `cpu_memory_at_hl=`*(cpu: GbCpu; gb: GB; val: uint8) =
  cpu.cached_hl = int(val)
  mem_write(gb.memory, gb, int(cpu.hl), val)

proc cpu_inc_pc*(cpu: GbCpu) =
  if cpu.halt_bug:
    cpu.halt_bug = false
  else:
    cpu.pc = cpu.pc + 1

proc cpu_halt*(cpu: GbCpu; gb: GB) =
  ## Pan Docs, "Halt Bug": with IME = 0 and `IF & IE != 0` the CPU does not
  ## halt, and the PC fails to increment for the instruction after the HALT.
  ##
  ## The IME that decides it is the one the HALT was FETCHED with, not the one
  ## it retires with. `EI` raises IME 4 T-cycles later (etIME), and for a
  ## one-M-cycle instruction that lands inside the next opcode's own fetch -- so
  ## on `EI; HALT` with an interrupt already pending the flag goes up during the
  ## HALT's fetch, and dingbat, reading it here, took the plain-halt branch.
  ## gambatte's `halt/ifandie_ei_halt_sra` reads the difference out directly: it
  ## sets IF = IE = $11 (VBlank + joypad), runs `EI; HALT; INC A` and prints A,
  ## with the VBlank vector `SRA A; RET`. Hardware prints $0A. Reading `ime` as
  ## it stands here halts plainly and prints $09; with the bug armed the run is
  ## the ROM's: the VBlank is dispatched (IME is up by then) and spends the bug
  ## by pushing the HALT's own address (dispatch_interrupt), `SRA A` makes A
  ## $08, and the `RET` lands back ON the HALT -- where IME is 0 again and the
  ## joypad bit is still pending, so the plain halt bug arms and runs `INC A`
  ## twice: $0A. SameSuite's `interrupt/ei_delay_halt` agrees and also passes
  ## only with this.
  ##
  ## The IME = 0 members (`noime_ifandie_halt_sra`, `noime_ifandie_halt_lda_3c`)
  ## never had a pending EI and are unmoved by the distinction.
  let ime_at_fetch = cpu.ime and
    cpu.ime_set_cycle + CycleCount(4) <= gb.scheduler.cycles
  if not ime_at_fetch and interrupt_ready(gb.interrupts):
    cpu.halt_bug = true
    cpu.halted   = false
  else:
    cpu.halted = true

proc cpu_lock*(cpu: GbCpu) =
  ## Enter the SM83's undefined-opcode lockup (opcodes.nim). Pan Docs, "CPU
  ## Instruction Set": the eleven unused opcodes "lock up the CPU" — the
  ## instruction decoder never reaches a state that fetches again, and no
  ## interrupt gets the CPU out of it; only a reset does.
  ##
  ## Modelled as `halted` plus a sticky `locked`. `halted` is what stops the
  ## fetch/dispatch and keeps the machine ticking 4 T-cycles at a time, so the
  ## PPU, timer, DMA and the scheduler go on running exactly as they do in
  ## HALT (which is what makes the frame the gambatte undef_ops ROMs read back
  ## a real frame, and what keeps a locked ROM from spinning the host).
  ## `locked` is only ever tested on that halted path, so the running CPU pays
  ## nothing for it; it is what stops handle_interrupts from clearing `halted`
  ## again. Nothing clears it FOR THE LOCKUP — a fresh GB (reset / load ROM)
  ## starts with a fresh GbCpu.
  ##
  ## STOP mode (stop_instr in memory.nim) sets the same two flags plus
  ## `stopped`, because it needs exactly this "halted, and no interrupt ends
  ## it" behaviour and reusing `locked` is what keeps the halted path's test
  ## count where it was. It DOES clear them, on its joypad wake; `locked` on
  ## its own still means the lockup, and only cpu_stop_tick ever clears it.
  cpu.halted = true
  cpu.locked = true

const IRQ_SAMPLE_T* {.intdefine.} = 16
  ## How far into the 5 M-cycle interrupt dispatch, in T-cycles, the IF bit of
  ## the line being taken is cleared.
  ##
  ## dingbat used to do both at T = 0 and then charge all 20 T-cycles, so every
  ## source that rose anywhere inside the dispatch survived the clear and was
  ## still set when the handler read IF back. gambatte has a family built to
  ## measure exactly that -- `*_late_retrigger`, which appears under five
  ## different STAT sources AND under the timer, so it is a property of the
  ## dispatch and not of the STAT line. Each ROM's handler re-requests its own
  ## interrupt with a `LDH ($0F),A` whose position moves by one M-cycle per
  ## family member, does `EI`, and reads IF back at the top of the second
  ## dispatch; the step the expected value flips on is where the clear falls.
  ##
  ## `m2int_m2irq_late_retrigger_{1,2}` reads it out directly. Its STAT source
  ## rises on the same dot either way (the next line's OAM pulse), and only the
  ## dispatch moves: at step 1 the dispatch starts 19 T before that rise and
  ## hardware still has the bit (out2); at step 2 it starts 15 T before it and
  ## hardware does not (out0). So the clear is later than 15 T and no later than
  ## 19 T into the dispatch, i.e. **at the start of the fifth M-cycle** -- the
  ## one Pan Docs' "Interrupt Handling" describes as setting PC to the handler,
  ## after the two wait states and the two push cycles. A rise during any of the
  ## first four is wiped; a rise during the fifth is not.
  ##
  ## Swept, whole gambatte suite, one build per cell, against `main` at ab0d7d6
  ## and with the LY=LYC blind window off, so this column is this constant alone:
  ##
  ##   IRQ_SAMPLE_T   gambatte   vs main
  ##        0           3856      the shipping model before this
  ##       12           3857     +1 / -0
  ##       16           3871     +16 / -1   <- ships
  ##       20           3869     +27 / -14
  ##
  ## A strict local maximum, and the two sides fail differently: at 12 nothing
  ## moves at all, at 20 the `_1` arm of every `*_late_retrigger` family goes red
  ## (m2int_m2irq, irq_precedence, tima, serial) while their `_2` arms go green,
  ## which is the whole family sliding one step. 16 is the only setting where
  ## both arms agree, on both devices and in double speed.
  ##
  ## The one row 16 costs is `irq_precedence/late_m0irq_retrigger_ds_1`, and it
  ## is not this constant: its SCX = 1 twin, the same ROM with one dot more of
  ## mode 3, is EXACT at 16 in the same build, and both single-speed arms are.
  ## Two ROMs that differ only in SCX bracketing the same edge from either side
  ## is the double-speed mode 3 -> 0 residual (bucket 15 of
  ## docs/gb-failure-triage.md) read through a newly sharpened instrument.
  ##
  ## Only the CLEAR moves. Which line is taken is decided earlier and stays
  ## where it was; the comment at `highest_priority` below is the pair of ROMs
  ## that separates the two instants, and folding them together costs those four
  ## rows. mooneye `acceptance/interrupts/ie_push` pins the same decision from
  ## the other side and is unaffected either way.
  ##
  ## Where the two PUSH M-cycles sit inside the dispatch was tried at the same
  ## time and left alone. Pan Docs puts them third and fourth, after two wait
  ## states; dingbat runs them first and charges the rest afterwards. Moving them
  ## to T = 8 (so the low byte's write ends exactly at this sample point) scores
  ## the same 3871 but trades differently -- +19 / -4, the four including three
  ## `late_hdma_vs_tima_*` rows that the current order gets right -- so the two
  ## orders are not distinguishable by score and the incumbent keeps the rows.
proc dispatch_interrupt(cpu: GbCpu; gb: GB) {.noinline.} =
  ## The taken half of handle_interrupts: push PC, vector, charge the 5 M-cycles.
  ##
  ## Split out, and forced out of line, because of what the OTHER half costs.
  ## handle_interrupts runs after every instruction — tens of millions of calls
  ## a second — and all but a handful of them fall straight out of
  ## `interrupt_ready`. Two `mem_write`s inlined into the same body (mem_write
  ## carries always_inline; see memory.nim) is enough register pressure to give
  ## the whole proc a real prologue, and that prologue is then paid on every one
  ## of those non-taken returns. Measured: +0.8% of ALL retired instructions on
  ## both a DMG and a CGB title, from a path that does nothing. Keeping the hot
  ## half a leaf is worth ~1% against `main` on both.
  cpu.ime = false
  # An armed halt bug is spent HERE when the dispatch is what follows the HALT
  # (`EI; HALT` with `IF & IE != 0`, cpu_halt): the CPU has not got past the
  # HALT, so the address pushed is the HALT's own and the bug happens again on
  # the RET rather than inside the handler. gambatte
  # `halt/ifandie_ei_halt_sra`'s $0A is the whole of the evidence -- see
  # cpu_halt -- and it is the reading that leaves the dispatch's TIMING alone:
  # holding the dispatch off for the doubled instruction instead prints the
  # same $0A but moves `ifandie_ei_halt_m2int_m0stat_1` a whole M-cycle and
  # takes its CGB row down.
  if cpu.halt_bug:
    cpu.halt_bug = false
    cpu.pc = cpu.pc - 1
  when defined(gb_irq_trace):
    # Diagnostic (tools only; compiled out of every shipping build). One line
    # per interrupt the CPU actually TAKES, with the PPU dot it was taken on --
    # the other half of `-d:gb_stat_read_trace`, which says when a STAT source
    # rose but not whether anything vectored off it. A ROM whose whole frame is
    # laid out by one interrupt's arrival (daid's ppu_scanline_bgp) is unreadable
    # without both: the dispatch dot plus a fixed handler prologue is the phase
    # every later cycle of the frame inherits.
    if gb.fifo_ppu != nil:
      echo "IRQ ly=", gb.fifo_ppu.ly, " dot=", gb.fifo_ppu.cycle_counter,
           " if=", toHex(irq_read(gb.interrupts, 0xFF0F), 2),
           " pc=", toHex(cpu.pc, 4)
  # The same three OAM-bug M-cycles PUSH has (cpu_push16); Pan Docs lists
  # interrupt handling with it.
  oam_bug_if(gb, cpu.sp, obWrite)
  cpu.sp = cpu.sp - 1
  oam_bug_if(gb, cpu.sp, obWrite)
  mem_write(gb.memory, gb, int(cpu.sp), uint8(cpu.pc shr 8))
  # WHICH line is taken is decided between the two push bytes, and that is not
  # the same instant as the clear below -- gambatte irq_precedence/
  # if_and_ie_0_vector is four ROMs that separate them. They push over $FFFF
  # from SP = $0000 and SP = $0001, so the byte that lands in IE is the high one
  # in the first pair and the low one in the second, and hardware vectors to
  # $0000 for the first (the new IE is seen) and to $0050 for the second (it is
  # not). So the decision sits after the high byte's write and ahead of the low
  # one's -- which is where it has always been here.
  let interrupt = highest_priority(gb.interrupts)
  cpu.sp = cpu.sp - 1
  oam_bug_if(gb, cpu.sp, obWrite)
  mem_write(gb.memory, gb, int(cpu.sp), uint8(cpu.pc and 0xFF))
  cpu.pc = interrupt
  # Run out to the sample point before clearing IF -- see IRQ_SAMPLE_T. The two
  # writes above have already charged 8 of it.
  when IRQ_SAMPLE_T > 8:
    # One call, not one per M-cycle: the PPU's dot loop and the timer are both
    # granular inside a multi-cycle tick, the two spellings score identically
    # over the whole gambatte suite, and the M-cycle-at-a-time version inlines
    # a second copy of the tick pair into this proc for nothing.
    mem_tick_components(gb.memory, gb, IRQ_SAMPLE_T - 8)
  clear_interrupt(gb.interrupts, interrupt)
  mem_tick_extra(gb.memory, gb, 20)

proc handle_interrupts*(cpu: GbCpu; gb: GB) =
  if interrupt_ready(gb.interrupts):
    # STOP mode is entered WITH an interrupt pending on one of its two leaves
    # (Pan Docs' STOP chart; it is the one daid's stop_instr.gb takes), and
    # nothing but a joypad line ends it -- the clock the interrupt logic runs
    # on is stopped too. So this cannot be allowed to un-halt the CPU the
    # M-cycle STOP retires. Tested inside `interrupt_ready`, which all but a
    # handful of calls fall straight out of, so the hot path is unchanged.
    if cpu.stopped: return
    cpu.halted = false
    if cpu.ime: dispatch_interrupt(cpu, gb)

# ---- Where inside an M-cycle a HALTED CPU latches the interrupt line --------
#
# A running CPU asks `interrupt_ready` after the last M-cycle of an instruction
# has been ticked -- i.e. at the M-cycle's END, with all four of its T-cycles
# and all of its PPU dots spent. This tree gives the halted CPU the same point,
# and that is wrong: the two paths differ by half an M-cycle, and GBMicrotest
# measures the difference directly.
#
# `int_hblank_nops_scx0..7` and `int_hblank_halt_scx0..7` are the bracket. Both
# halves wait for the same mode-0 STAT interrupt and report how far they got;
# the only difference between them is a NOP sled against `EI; HALT`. SCX moves
# the mode 3 -> 0 edge one dot at a time, so the eight pairs walk that edge
# across two whole M-cycles -- and hardware's halt half is one M-cycle later
# than its sled half for four of the eight and level with it for the other four:
#
#   scx                     0    1    2    3    4    5    6    7
#   dot of the mode 0 edge  252  253  254  255  256  257  258  259
#   T of the M-cycle        3    0    1    2    3    0    1    2
#   sled (`_nops_`)         $61  $62  $62  $62  $62  $63  $63  $63
#   halt (`_halt_`)         $62  $62  $62  $63  $63  $63  $63  $64
#   halt - sled             +1   0    0    +1   +1   0    0    +1
#
# The sled row is exact in this tree, so the dot grid and the M-cycle grid are
# both already right -- the sled's two steps (scx 0->1 and 4->5) are what put
# the M-cycle boundary between dots 252 and 253, and every dot's T below is read
# off that. Read the last row against it: the halted CPU misses the interrupt
# for a whole M-cycle exactly when the flag rises on T 2 or T 3, and catches it
# when it rises on T 0 or T 1. That is a threshold and it is two-sided -- the
# four level rows refuse any larger value and the four late ones refuse any
# smaller -- so the halted CPU's latch sits after T 1 and before T 2, i.e. at
# the MIDPOINT of the M-cycle, four rows either side of it.
#
# The other three sources are the cross-check, and they are why this is not
# "halt costs one more M-cycle" (which nine green rows refuse -- see the note at
# STAT_M2_LEAD in ppu.nim): `int_lyc_nops/_halt` are both $99 and
# `int_vblank1_nops/_halt` are both $42, because those sources rise in the first
# half of their M-cycle, while `int_oam_nops` $93 / `int_oam_halt` $94 differ by
# one because the OAM source rises in the second half of its own.
#
# Spent, not skipped: the M-cycle is still four T-cycles long either way. What
# moves is only WHERE in it the question is asked, so nothing here can cost or
# save time, which is what the `tima/*` rows demand of any halt change. That is
# also what separates this from "halt exit costs one more M-cycle". A uniform
# charge cannot produce the table above at all: it would move all eight
# `int_hblank_*_scx*` rows together, so it swaps which four are green for the
# other four and stays at 4/8, and it takes `int_lyc_halt`, `int_vblank1/2_halt`
# and all three `int_timer_halt*` with it -- and the timer has nothing to do
# with the PPU. Only a threshold on T reproduces four and four.
#
# ---- What the head/tail split says about the other sources -----------------
#
# With the latch pinned, every source is classified by which half of ITS
# M-cycle it rises in, and the halt rows read that classification out:
#
#   source          rises          halt vs sled   ROMs
#   -------------   ------------   ------------   ----------------------------
#   mode 0 (STAT)   T 0..3, by scx  +1 on T 2,3   int_hblank_{nops,halt}_scx0-7
#   OAM (mode 2)    tail            +1            int_oam_nops $93 / _halt $94
#   LYC             head            level         int_lyc_{nops,halt} both $99
#   vblank          head            level         int_vblank1_{nops,halt} $42
#   timer           head            level         int_timer_halt{,_div_a,_div_b}
#
# The OAM row is only a tail one once `STAT_M2_LEAD` is on: at 0 that source
# rises with the line boundary, which is a head, and the pair reads $94/$94.
# That is the whole of bucket 14's blocker -- see the halt paragraph at
# STAT_M2_LEAD in ppu.nim.
#
# Two of the head sources need saying in code rather than in a dot, because
# this tree does not spell their rise where the pairs put it; both are in
# cpu_halt_tick below. Neither is a free parameter: the halt rows are two-sided
# on the latch, and given the latch each source's half is read off, not fitted.
#
# ---- Measured, and it ships OFF --------------------------------------------
#
# Whole runner, one full pass per build, against 765/981 on main:
#
#   this alone (knobs off)                  766   gambatte 3851, GBMicrotest 433
#   + STAT_M2_LEAD=1 M3_PIPE_AHEAD=1
#     LY0_PIPE_MCYCLES=0                    786   gambatte 3972, GBMicrotest 439
#
# The second line is bucket 14 landing: +123 gambatte (`window` +80,
# `m2int_m3stat` 22/44 -> 44/44, `m2int_m0irq` +4, `halt` +12, `sprites` +4,
# `speedchange` +7 against `m2enable` -8, `irq_precedence` -4, `enable_display`
# -3), +10 GBMicrotest, and all five mooneye `intr_2_*` plus their wilbertpol
# copies stay green with the twelve `*_timing_nops` rows joining them.
#
# **It ships at 4 anyway, and the reason is a row this tree may not lose:**
# `mooneye acceptance/ppu/hblank_ly_scx_timing-GS` (and wilbertpol's copy) goes
# red -- with the latch alone, before any knob. It is the same measurement as
# `int_hblank_halt_scx0` at the same SCX on the same device, and the two
# disagree by exactly this M-cycle:
#
#   * GBMicrotest reads TIMA out of the handler, so it times the dispatch
#     against the timer, and says halt is one M-cycle after sled.
#   * mooneye reads LY out of the handler N M-cycles later, twice, one M-cycle
#     apart, so it times the dispatch against the LY ADVANCE -- and it puts the
#     halt-woken read on the near side of a boundary that +1 crosses.
#
# Both endpoints of mooneye's span are separately pinned against TIMA and both
# are green (`int_hblank_nops_scx0` for the mode-0 edge; `poweron_ly_*`,
# `lcdon_to_ly*`, `line_153_ly_*` for LY), so the arithmetic says the two should
# agree and they do not. **That is a new bucket, and it is the one thing between
# this constant and bucket 14** -- and it is already visible from the other side:
# the sled sibling of the mooneye row, `hblank_ly_scx_timing_nops`, is red on
# main, at 4 and at 2 alike, so that family carries an error of its own that the
# halt half was cancelling.
#
# A read-side lag was the obvious candidate for it and is FALSIFIED, not
# untried: giving `$FF44` the same sample point `STAT_READ_LAG` gives the mode
# bits (two dots before the M-cycle's end) does not fix the mooneye row and does
# take seven GBMicrotest LY rows with it -- `lcdon_to_ly{1,2,3}_b`,
# `line_153_ly_{b,f}`, `poweron_ly_{120,234}`. LY reads back where it is.
#
# The rest of the residue at 2, for whoever picks this up (all of it against
# main, with the three knobs on):
#
#   mooneye misc/ppu/vblank_stat_intr-C  x2   the CGB line-144 OAM pulse
#                                             (m2_line144) is a tail source here
#                                             and its wake then collides with
#                                             vblank's; its half is unmeasured
#   daid ppu_scanline_bgp-dmg                 100% -> 90.5%. Its phase is an
#                                             LYC=0 halt, i.e. a HEAD source, so
#                                             the latch leaves its dispatch
#                                             alone while M3_PIPE_AHEAD moves
#                                             the pixels under it
#   strikethrough dmg + cgb                   7 pixels each, same shape
#   gbmicrotest lcdon_to_if_oam_a,            IF *reads*, not halts: they want
#     oam_int_if_edge_a                       the OAM source's rise on the far
#                                             side of a read, which is the
#                                             read-side quantity above
#
# ---- Perf, which is a prerequisite for the flip and not an afterthought ----
#
# At 4 this costs nothing: the shipping build is within noise of the same tree
# without cpu_halt_tick at all (Pokemon Blue 24.0705 vs 24.0723 G retired
# instructions, Link's Awakening 24.2334 vs 24.2334 G, minimum of three).
#
# At 2 it is expensive, and it has to come down before anyone ships it: the
# split doubles the PPU tick calls of every halted M-cycle, which is Pokemon
# Blue's whole main loop -- **+4.79%** retired instructions there (24.076 ->
# 25.228 G) and +1.88% on Link's Awakening. The obvious way down is that most
# halted M-cycles cannot raise anything at all: the PPU's own idle-skip already
# knows the next dot on which something can happen, so a halted M-cycle that
# ends before it needs no split and no second call. That is untried.
const HALT_IF_SAMPLE_T* {.intdefine.} = 4
  ## T-cycles into a halted M-cycle at which the interrupt line is latched.
  ## 4 is the M-cycle's end -- the running CPU's point, and what this tree
  ## ships -- and compiles the split tick and both head rules out entirely.
  ## 2 is the measurement above.

proc cpu_halt_tick(gb: GB): bool {.inline.} =
  ## One halted M-cycle's worth of ticking, answering "does this M-cycle end
  ## with the CPU awake". The whole M-cycle is spent either way; the latch is
  ## just taken part way through it.
  when CGB_HALT_PPU_LEAD_ANY:
    # The head of a CGB halt: the bus half of this M-cycle runs and the PPU
    # half does not, so the PPU spends the rest of the halt one M-cycle of dots
    # behind the rest of the machine. The wake pays them back (`tick` below).
    # CGB_HALT_PPU_LEAD in gb.nim is the derivation and the bracket; the short
    # version is that this is what makes a STAT/LYC/vblank wake land one
    # M-cycle later in the PPU's line while a TIMER wake -- and TIMA with it --
    # does not move at all, which is what the two halves of that measurement
    # demand of each other.
    #
    # `halt_ppu_debt` is what says the head is over, so the test doubles as the
    # per-halt latch and no extra flag is needed. The whole block compiles out
    # at the shipping 0; with it on, a halted CPU pays one predictable
    # compare-and-branch per M-cycle, on the path a HALT-idling title spends
    # its main loop in.
    #
    # `cgb_enabled` is tested FIRST, and that ordering is worth a measurement:
    # a DMG title has to walk this block too, and asking the debt question
    # first makes it load `current_speed`, compute two shifts and take a
    # TAKEN branch on every halted M-cycle before finding out the answer is
    # no. Pokemon Blue idles its main loop in HALT and pays +1.30% of ALL
    # retired instructions for that (24.0593 -> 24.3718 G, min of three);
    # with the device test in front the same title pays +0.44% (24.1647 G).
    # The trade is not free on the other side -- Pokemon Crystal goes from
    # +0.56% to +0.77% (23.6967 -> 23.8299 -> 23.8783 G) for the redundant
    # test it now takes -- and it is still the right way round, because the
    # titles that idle hardest in HALT are the ones that get nothing back.
    # Neither ordering is free, which is the thing to know before the flip:
    # this is not a CGB-only cost, it is a cost on every HALT-idling title.
    # ---- The LY 153 -> 0 snapback does NOT carry the lead --------------------
    #
    # Measured on daid's `ppu_scanline_bgp`, which is the ideal instrument for
    # it: 91 lines of source, ONE STAT LYC interrupt taken out of `halt`, and
    # then a 114-M loop of BGP writes that stays scanline-locked for the whole
    # frame, so a single M-cycle at that wake moves all 1440 of its band edges.
    # Rebuilt byte-exact and swept over the LYC value alone -- same ROM, same
    # entry (in VBlank), same IME, same vector, only the line the wake lands on
    # changing -- against SameBoy in CGB compatibility mode, which reproduces
    # daid's own reference pixel-exactly (tools/gbppu/daidsweep.py):
    #
    #   LYC = 0   (the snapback)   dingbat WITHOUT the lead is exact; with it, 2304 px
    #   LYC = 1, 8, 40, 100        dingbat WITH the lead is exact; without it, 1920-2304 px
    #
    # So the quantity is real on every normal-line wake and absent on the
    # snapback, and that is what reconciles daid with `cgb-acid-hell` -- whose
    # own disputed pixels are on lines 68 and 69, both normal lines, and whose
    # line-0 block is insensitive either way. It is not IME, not whether a
    # vector is taken, and not LY0_PIPE_MCYCLES (swept 0/2/3 against the lead,
    # daid unmoved at 2304).
    #
    # Spelled at the HEAD rather than at the wake, because that is where the
    # dots are withheld: a halt that the snapback's LYC=0 match will wake must
    # never hold the PPU back in the first place, and asking here keeps the
    # repayment path exactly as conservative as it was.
    #
    # It is the LAST term of the conjunction on purpose, and that is the same
    # measurement the paragraph above is about: the debt test in front of it is
    # false for all but the first M-cycle of a halt, so these two extra loads
    # run once per halt rather than once per halted M-cycle. Put in front of
    # `cgb_enabled` -- where it was first written -- every DMG title idling in
    # HALT would pay them forever, which is exactly the +1.30% on Pokemon Blue
    # recorded above.
    if gb.cgb_enabled and
       gb.cpu.halt_ppu_debt < int32(CGB_HALT_PPU_LEAD_DOTS shr gb.memory.current_speed) and
       (when CGB_HALT_LEAD_SKIP_LYC0 != 0:
          not (gb.ppu.lyc == 0'u8 and (gb.ppu.lcd_status and 0x40'u8) != 0'u8)
        else: true) and
       (when CGB_HALT_LEAD_LYC_ONLY != 0:
          # EXPERIMENT, not a shipped rule: is the lead a property of the LYC
          # comparator's own wake, absent when a MODE-sourced STAT edge raises
          # it? gambatte's `halt/m0*_m0stat_scx*` read mode 2 where hardware
          # reads mode 0 under the flat lead, which is what that would look
          # like. STAT bit 6 is LYC, bits 3/4/5 are modes 0/1/2.
          (gb.ppu.lcd_status and 0x38'u8) == 0'u8
        else: true):
      let mdots = int32(4 shr gb.memory.current_speed)
      let lead  = int32(CGB_HALT_PPU_LEAD_DOTS shr gb.memory.current_speed)
      # A lag of a whole M-cycle takes the PPU half entirely; a lag of 1..3
      # dots takes part of it and the PPU gets the rest, on this M-cycle, in
      # its own half. Same conservation either way -- what the head holds back
      # is exactly what the wake pays.
      let take = min(mdots, lead - gb.cpu.halt_ppu_debt)
      gb.cpu.halt_ppu_debt += take
      mem_tick_bus(gb.memory, gb, 4)
      if take < mdots:
        mem_tick_ppu(gb.memory, gb, int(mdots - take), ignore_speed = true)
      mem_reset_cycle_count(gb.memory)
      return interrupt_ready(gb.interrupts)
  when HALT_IF_SAMPLE_T >= 4:
    mem_tick_extra(gb.memory, gb, 4)
    interrupt_ready(gb.interrupts)
  else:
    # The bus half whole, the PPU half split. The timer is the reason: its IRQ
    # is one of the sources the halt pairs put in the HEAD of the M-cycle (see
    # HALT_IF_SAMPLE_T), and this tree runs the timer's four T-cycles as one
    # step, so the only place the head can be is in front of the latch. That is
    # not a shortcut around the split -- the timer's tap periods are all
    # multiples of 4 T and its phase against the M-cycle grid is fixed, so a
    # timer IRQ is ALWAYS in the same half, and the halt rows say which one.
    mem_tick_bus(gb.memory, gb, 4)
    let ly0 = gb.ppu.ly
    mem_tick_ppu(gb.memory, gb, HALT_IF_SAMPLE_T)
    result = interrupt_ready(gb.interrupts)
    mem_tick_ppu(gb.memory, gb, 4 - HALT_IF_SAMPLE_T)
    mem_reset_cycle_count(gb.memory)
    # ...and the LY-derived sources are head sources too, for the same reason
    # and on the same evidence: `int_lyc_nops/_halt` are both $99 and
    # `int_vblank1_nops/_halt` are both $42. This tree runs the WHOLE line
    # boundary -- LY, the coincidence comparator, the vblank IF and the mode 1
    # source -- on the line's last dot, which is the M-cycle's last dot, so the
    # latch above cannot see them where they belong. An LY change in the tail is
    # exactly that case, and it is the only one: the OAM source rises a whole
    # M-cycle before the boundary (STAT_M2_LEAD) and the mode-0 source rises
    # mid-line, so neither is ever in an M-cycle that changed LY.
    if not result and gb.ppu.ly != ly0:
      result = interrupt_ready(gb.interrupts)

proc cpu_stop_tick(cpu: GbCpu; gb: GB) {.noinline.} =
  ## One step of STOP mode (stop_instr in memory.nim): the one halt where the
  ## rest of the machine is stopped with the CPU, so nothing is ticked and
  ## mem_tick_stopped only keeps the frontend's frames coming.
  ##
  ## Pan Docs: "STOP is terminated by one of the P10 to P13 lines going low",
  ## which is what joypad_lines reports as a zero bit — a key held on a group
  ## selected in P1. The same edge sets the joypad interrupt, so a CPU with IME
  ## set vectors on its way out through tick's ordinary path, on the M-cycle
  ## after this one.
  ##
  ## `noinline` for the same reason dispatch_interrupt carries it: this body
  ## has no business in `tick`, which a halt-heavy title runs tens of millions
  ## of times a second.
  mem_tick_stopped(gb.memory, gb)
  if joypad_lines(gb.joypad) != 0x0F'u8:
    cpu.stopped = false
    cpu.locked  = false
    cpu.halted  = false

when defined(gbfuzz_trace):
  # Instruction trace for cross-emulator divergence hunting (tools/gbfuzz).
  # Compiled out of every normal build; see gbfuzz_trace_hook.
  var gbfuzz_trace_hook*: proc(pc: uint16; opcode: uint8) {.closure.}

proc tick*(cpu: GbCpu; gb: GB) =
  # The halted case is split out rather than folded into a `cycles_taken`
  # expression so the `locked` test costs the *running* CPU nothing: the
  # `cpu.halted` branch was already here, and `locked` is only reachable
  # behind it (cpu_lock sets both).
  if cpu.halted:
    cpu.cached_hl = -1
    # The two halts no interrupt can end: the undefined-opcode lockup, which is
    # still a running machine, and STOP mode, which is not. `locked` is set by
    # both (cpu_lock, stop_instr), so this is the SAME test that used to be the
    # `not cpu.locked` half of the condition below -- just hoisted above the
    # tick, because STOP mode must not tick. That hoist is not free: it costs
    # 0.17% of ALL retired instructions on Pokemon Blue, which idles in HALT
    # (0.03% on Link's Awakening, unmeasurable on Shantae). It is the cheapest
    # of the shapes tried -- testing `stopped` on its own here instead costs
    # 0.5% on the same title, and moving the whole halted body out of line
    # costs 0.7-1.2% on the two titles that halt less.
    if cpu.locked:
      if cpu.stopped: cpu_stop_tick(cpu, gb)
      else:           mem_tick_extra(gb.memory, gb, 4)
      return
    # handle_interrupts, opened up. The halt ends on IF & IE whether or not IME
    # lets an interrupt be taken, and that is the exact M-cycle the question
    # below has to be asked on -- asking it on every halted M-cycle instead
    # costs a real 0.3% of a title that spends its main loop halted. WHERE in
    # the M-cycle it is asked is HALT_IF_SAMPLE_T, above.
    if cpu_halt_tick(gb):
      when defined(gb_halt_trace):
        # Diagnostic (tools only; compiled out of every shipping build). One
        # line per halt EXIT, with the PPU dot the CPU resumed on. That dot is
        # what every `halt/` row's expected value is a function of -- the ROMs
        # read STAT or LY a fixed number of M-cycles after it -- and it is the
        # only quantity in this file no other trace reports: `gb_irq_trace`
        # prints the DISPATCH, which the IME = 0 members never reach.
        if gb.fifo_ppu != nil:
          echo "HALTWAKE ly=", gb.fifo_ppu.ly, " dot=", gb.fifo_ppu.cycle_counter,
               " mode=", (gb.ppu.lcd_status and 3'u8),
               " if=", toHex(irq_read(gb.interrupts, 0xFF0F), 2),
               " ime=", (if cpu.ime: 1 else: 0)
      # The CGB leaves this state LATER than the DMG does -- ten gambatte
      # `halt/` rows state it, one boundary each -- but not by spending time,
      # which is what 42 `tima/*` rows refuse. CGB_HALT_EXIT_MCYCLES in gb.nim
      # is that measurement and it ships at 0, so this compiles away; the hook
      # is here rather than at the dispatch below because the `_irq_` members
      # (IME clear, no vector) want the cost too. Charged ahead of the HBlank
      # DMA block, i.e. before the CPU is back on the bus.
      when CGB_HALT_EXIT_MCYCLES != 0:
        if gb.cgb_enabled:
          mem_tick_extra(gb.memory, gb, 4 * CGB_HALT_EXIT_MCYCLES)
      # A HBlank VRAM DMA block that came due while the CPU was halted (see the
      # mode-0 edge in `mode_flag=`) is transferred the moment the CPU is back
      # on the bus, which is this one. The DMA takes the bus before the CPU's
      # own next cycle, so it goes ahead of the dispatch below.
      #
      # Only if the HBlank that owed it is still running, though -- the debt is
      # to a mode 0, not to the transfer. Waking outside one drops it, and the
      # next mode 0 arms the flag again.
      #
      # Copied at the boundary rather than inside a CPU access's dots (the wake
      # is not one), so nothing here holds the bytes back: see
      # HDMA_VISIBLE_DOTS and `in_cpu_cycle`.
      if gb.ppu.hdma_block_due:
        if gb.ppu.hdma_active and (gb.ppu.lcd_status and 3'u8) == 0'u8:
          ppu_step_hdma(gb.ppu, gb)
        else:
          gb.ppu.hdma_block_due = false
      when CGB_HALT_PPU_LEAD_ANY:
        # ...and the dots the head of this halt held back from the PPU, paid
        # with no bus half, which is what makes the whole thing a phase and not
        # a charge: no scheduler, no timer, no OAM DMA, no time.
        if gb.cpu.halt_ppu_debt != 0:
          mem_tick_ppu(gb.memory, gb, int(gb.cpu.halt_ppu_debt),
                       ignore_speed = true)
          gb.cpu.halt_ppu_debt = 0
      cpu.halted = false
      if cpu.ime: dispatch_interrupt(cpu, gb)
    return
  when defined(gbfuzz_trace):
    if gbfuzz_trace_hook != nil:
      gbfuzz_trace_hook(cpu.pc, read_byte(gb.memory, gb, int(cpu.pc)))
  let opcode = mem_read(gb.memory, gb, int(cpu.pc))
  when STAT_M0_TAIL_MAX_MC != 0:
    # The instruction an IO read belongs to, so stat_read_mode can tell a read
    # on its instruction's second M-cycle from one on its third. Guarded, so a
    # default build does not carry a store per instruction.
    cpu.cur_opcode = opcode
  let cycles_taken = UNPREFIXED[opcode](cpu, gb)
  cpu.cached_hl = -1
  mem_tick_extra(gb.memory, gb, cycles_taken)
  handle_interrupts(cpu, gb)
