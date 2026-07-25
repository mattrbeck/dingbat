# GB SM83 CPU (included by gb.nim)

proc new_gb_cpu*(): GbCpu =
  GbCpu(pc: 0, sp: 0, ime: false, halted: false, halt_bug: false, cached_hl: -1)

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

proc handle_interrupts*(cpu: GbCpu; gb: GB) =
  if interrupt_ready(gb.interrupts):
    cpu.halted = false
    if cpu.ime:
      cpu.ime = false
      cpu.sp = cpu.sp - 1
      mem_write(gb.memory, gb, int(cpu.sp), uint8(cpu.pc shr 8))
      let interrupt = highest_priority(gb.interrupts)
      cpu.sp = cpu.sp - 1
      mem_write(gb.memory, gb, int(cpu.sp), uint8(cpu.pc and 0xFF))
      cpu.pc = interrupt
      clear_interrupt(gb.interrupts, interrupt)
      mem_tick_extra(gb.memory, gb, 20)

when defined(gbfuzz_trace):
  # Instruction trace for cross-emulator divergence hunting (tools/gbfuzz).
  # Compiled out of every normal build; see gbfuzz_trace_hook.
  var gbfuzz_trace_hook*: proc(pc: uint16; opcode: uint8) {.closure.}

proc tick*(cpu: GbCpu; gb: GB) =
  let cycles_taken =
    if cpu.halted:
      4
    else:
      when defined(gbfuzz_trace):
        if gbfuzz_trace_hook != nil:
          gbfuzz_trace_hook(cpu.pc, read_byte(gb.memory, gb, int(cpu.pc)))
      let opcode = mem_read(gb.memory, gb, int(cpu.pc))
      UNPREFIXED[opcode](cpu, gb)
  cpu.cached_hl = -1
  mem_tick_extra(gb.memory, gb, cycles_taken)
  handle_interrupts(cpu, gb)
