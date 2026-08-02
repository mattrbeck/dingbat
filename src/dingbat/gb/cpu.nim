# GB SM83 CPU (included by gb.nim)

proc new_gb_cpu*(): GbCpu =
  GbCpu(pc: 0, sp: 0, ime: false, halted: false, halt_bug: false,
        locked: false, cached_hl: -1)

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
  ## again. Nothing clears it — a fresh GB (reset / load ROM) starts with a
  ## fresh GbCpu.
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
  cpu.sp = cpu.sp - 1
  mem_write(gb.memory, gb, int(cpu.sp), uint8(cpu.pc shr 8))
  let interrupt = highest_priority(gb.interrupts)
  cpu.sp = cpu.sp - 1
  mem_write(gb.memory, gb, int(cpu.sp), uint8(cpu.pc and 0xFF))
  cpu.pc = interrupt
  clear_interrupt(gb.interrupts, interrupt)
  mem_tick_extra(gb.memory, gb, 20)

proc handle_interrupts*(cpu: GbCpu; gb: GB) =
  if interrupt_ready(gb.interrupts):
    cpu.halted = false
    if cpu.ime: dispatch_interrupt(cpu, gb)

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
    mem_tick_extra(gb.memory, gb, 4)
    if not cpu.locked:
      handle_interrupts(cpu, gb)
    return
  when defined(gbfuzz_trace):
    if gbfuzz_trace_hook != nil:
      gbfuzz_trace_hook(cpu.pc, read_byte(gb.memory, gb, int(cpu.pc)))
  let opcode = mem_read(gb.memory, gb, int(cpu.pc))
  let cycles_taken = UNPREFIXED[opcode](cpu, gb)
  cpu.cached_hl = -1
  mem_tick_extra(gb.memory, gb, cycles_taken)
  handle_interrupts(cpu, gb)
