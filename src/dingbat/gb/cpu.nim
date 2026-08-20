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
# A running CPU asks `interrupt_ready` at its last M-cycle's END. A halted one
# latches at the MIDPOINT, so a source that rises in the M-cycle's second half
# wakes it one boundary later. Each source is then classified by which half of ITS
# M-cycle it rises in -- mode 0 varies with SCX, the OAM pulse is a tail, LYC,
# vblank and the timer are heads -- and the halt/sled ROM pairs read exactly that
# classification out.
#
# Spent, not skipped: the M-cycle is still four T-cycles either way, only the
# question's position moves. That is what separates this from "halt exit costs one
# more M-cycle", which cannot produce the per-SCX table at all and takes the timer
# rows with it.
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
    # The head of a CGB halt: the bus half of this M-cycle runs and the PPU half
    # does not, so the PPU spends the rest of the halt one M-cycle of dots behind
    # the machine, repaid at the wake (`tick` below). `halt_ppu_debt` is what says
    # the head is over, so the test doubles as the per-halt latch.
    #
    # The term ORDER is measured, not stylistic. `cgb_enabled` is tested FIRST
    # because a DMG title walks this block too, and asking the debt question first
    # makes it load `current_speed`, compute two shifts and take a TAKEN branch on
    # every halted M-cycle before finding out the answer is no: Pokemon Blue idles
    # its main loop in HALT and pays +1.30% of ALL retired instructions that way,
    # against +0.44% with the device test in front. The trade is not free the other
    # way (Crystal goes +0.56% -> +0.77% for the redundant test) and is still the
    # right way round. This is not a CGB-only cost -- it is a cost on every
    # HALT-idling title.
    #
    # The snapback exemption (CGB_HALT_LEAD_SKIP_LYC0) is the LAST term for the
    # same reason: the debt test in front of it is false for all but the first
    # M-cycle of a halt, so its two extra loads run once per halt rather than once
    # per halted M-cycle. It is spelled at the HEAD rather than at the wake because
    # that is where the dots are withheld -- a halt the snapback's LYC=0 match will
    # wake must never hold the PPU back in the first place.
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
  when HDMA_STEAL_DELAY_M != 0:
    # A block that came due on a mode-0 edge takes the bus at this instruction
    # boundary, once the CPU has had HDMA_STEAL_DELAY_M of them. `in_cpu_cycle`
    # stays true so the bytes are still held back HDMA_VISIBLE_DOTS dots, which
    # is what the gambatte dma rows pinned; only WHEN the block runs moves.
    #
    # BEFORE handle_interrupts, not after, and that ordering is load-bearing:
    # "the DMA takes the bus before the CPU's own next cycle, so it goes ahead
    # of the dispatch" (the halt-exit path above says the same). Paying it at
    # the TOP of the next instruction instead is the same instant but the wrong
    # side of the dispatch, and costs the whole gambatte `irq_precedence`
    # hdma_vs_m0 / late_hdma_vs_ei / late_hdma_vs_ie family.
    if unlikely(gb.ppu.hdma_block_due):
      if gb.ppu.hdma_active and (gb.ppu.lcd_status and 3'u8) == 0'u8:
        if gb.ppu.hdma_due_delay > 0'i8:
          dec gb.ppu.hdma_due_delay
        else:
          ppu_step_hdma(gb.ppu, gb, in_cpu_cycle = true)
      else:
        gb.ppu.hdma_block_due = false
  handle_interrupts(cpu, gb)
