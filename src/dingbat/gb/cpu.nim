# GB SM83 CPU (included by gb.nim)

proc new_gb_cpu*(): GbCpu =
  GbCpu(pc: 0, sp: 0, ime: false, halted: false, halt_bug: false, cached_hl: -1)

proc skip_boot*(cpu: GbCpu; gb: GB) =
  # Registers at PC=0x100 (mooneye boot_regs-dmgABC / boot_regs-cgb /
  # misc/boot_regs-cgb): the CGB boot ROM leaves different values depending
  # on whether the cart runs in native CGB or DMG-compatibility mode.
  cpu.pc = 0x0100
  cpu.sp = 0xFFFE
  if gb.cgb_enabled:
    cpu.af = 0x1180
    cpu.bc = 0x0000
    if gb.cgb_flag != cgbNone:
      cpu.de = 0xFF56  # native CGB mode
      cpu.hl = 0x000D
    else:
      cpu.de = 0x0008  # DMG cart on CGB hardware
      cpu.hl = 0x007C
  else:
    cpu.af = 0x01B0    # DMG-ABC
    cpu.bc = 0x0013
    cpu.de = 0x00D8
    cpu.hl = 0x014D

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

proc tick*(cpu: GbCpu; gb: GB) =
  let cycles_taken =
    if cpu.halted:
      4
    else:
      let opcode = mem_read(gb.memory, gb, int(cpu.pc))
      UNPREFIXED[opcode](cpu, gb)
  cpu.cached_hl = -1
  mem_tick_extra(gb.memory, gb, cycles_taken)
  handle_interrupts(cpu, gb)
