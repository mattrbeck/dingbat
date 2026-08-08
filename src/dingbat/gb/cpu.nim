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
  # The same three OAM-bug M-cycles PUSH has (cpu_push16); Pan Docs lists
  # interrupt handling with it.
  oam_bug_if(gb, cpu.sp, obWrite)
  cpu.sp = cpu.sp - 1
  oam_bug_if(gb, cpu.sp, obWrite)
  mem_write(gb.memory, gb, int(cpu.sp), uint8(cpu.pc shr 8))
  let interrupt = highest_priority(gb.interrupts)
  cpu.sp = cpu.sp - 1
  oam_bug_if(gb, cpu.sp, obWrite)
  mem_write(gb.memory, gb, int(cpu.sp), uint8(cpu.pc and 0xFF))
  cpu.pc = interrupt
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
