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
  of bmDmgABC:
    cpu.af = 0x01B0; cpu.bc = 0x0013; cpu.de = 0x00D8; cpu.hl = 0x014D
  of bmMgb:
    cpu.af = 0xFFB0; cpu.bc = 0x0013; cpu.de = 0x00D8; cpu.hl = 0x014D
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
    if gb.boot_model == bmAgb:
      cpu.af = 0x1100; cpu.bc = 0x0100
    else:
      cpu.af = 0x1180; cpu.bc = 0x0000
    if gb.cgb_flag != cgbNone:
      cpu.de = 0xFF56; cpu.hl = 0x000D   # native CGB cart
    else:
      cpu.de = 0x0008; cpu.hl = 0x007C   # DMG cart on CGB/AGB hardware

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
  if not cpu.ime and interrupt_ready(gb.interrupts):
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
    mem_tick_extra(gb.memory, gb, 4)
    # handle_interrupts, opened up. The halt ends on IF & IE whether or not IME
    # lets an interrupt be taken, and that is the exact M-cycle the question
    # below has to be asked on -- asking it on every halted M-cycle instead
    # costs a real 0.3% of a title that spends its main loop halted.
    if interrupt_ready(gb.interrupts):
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
      if gb.ppu.hdma_block_due:
        if gb.ppu.hdma_active and (gb.ppu.lcd_status and 3'u8) == 0'u8:
          ppu_step_hdma(gb.ppu, gb)
        else:
          gb.ppu.hdma_block_due = false
      cpu.halted = false
      if cpu.ime: dispatch_interrupt(cpu, gb)
    return
  when defined(gbfuzz_trace):
    if gbfuzz_trace_hook != nil:
      gbfuzz_trace_hook(cpu.pc, read_byte(gb.memory, gb, int(cpu.pc)))
  let opcode = mem_read(gb.memory, gb, int(cpu.pc))
  let cycles_taken = UNPREFIXED[opcode](cpu, gb)
  cpu.cached_hl = -1
  mem_tick_extra(gb.memory, gb, cycles_taken)
  handle_interrupts(cpu, gb)
