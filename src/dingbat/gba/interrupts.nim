# Interrupts implementation (included by gba.nim)

proc new_interrupts*(gba: GBA): Interrupts =
  result = Interrupts(gba: gba)
  result.reg_ie = InterruptReg()
  result.reg_if = InterruptReg()
  result.ime = false

const
  IRQ_TIMER_BIT_BASE* = 3
  IRQ_DMA_BIT_BASE*   = 8
  # Stop mode wakes only on serial (7), keypad (12), and game pak (13)
  STOP_WAKE_MASK* = 0x3080'u16

proc set_interrupt_flag*(intr: Interrupts; bit: int) {.inline.} =
  intr.reg_if = cast[InterruptReg](uint16(intr.reg_if) or (1'u16 shl bit))

# Cycles from a peripheral raising IF to CPU recognition (mGBA suite Timer
# IRQ rows). Register writes (IE/IF/IME) re-evaluate with no delay.
const IRQ_SYNC_DELAY* = 3

# Cycles of continued execution after a register write (IME 0->1, IE unmask,
# msr clearing CPSR.I) releases an already-parked IF bit. The window is
# cycle-based, not instruction-based (hardware: gbaedge IRQWIN/IRQWIN2/
# IRQWIN3 on AGB SP, docs/hwprobe.md). The vector-entry cost itself is in
# cpu.irq.
const
  IRQ_GATE_DELAY* = 12

proc schedule_interrupt_check*(intr: Interrupts; delay: int = 0) =
  intr.gba.scheduler.schedule(delay, etInterrupts)

proc irq_deliverable*(intr: Interrupts): bool {.inline.} =
  intr.ime and (uint16(intr.reg_ie) and uint16(intr.reg_if)) != 0

proc gate_opened*(intr: Interrupts) =
  ## A register write made a parked interrupt deliverable: drop the
  ## recognized line and re-recognize IRQ_GATE_DELAY cycles out.
  intr.gba.cpu.irq_line = false
  intr.gate_open_at = intr.gba.scheduler.cycles + CycleCount(IRQ_GATE_DELAY)
  intr.schedule_interrupt_check(IRQ_GATE_DELAY)

proc check_interrupts*(intr: Interrupts) =
  let pending = uint16(intr.reg_ie) and uint16(intr.reg_if)
  intr.gba.cpu.irq_line = false
  if pending != 0:
    if intr.gba.cpu.stopped and (pending and STOP_WAKE_MASK) == 0:
      return  # Stop mode ignores other interrupt sources
    if intr.gba.cpu.stopped:
      # Waking from Stop turns the LCD back on without a memory write.
      intr.gba.ppu.render_dirty = true
    if intr.gba.cpu.halted:
      intr.gba.cpu.halt_wake = true
    intr.gba.cpu.stopped = false
    intr.gba.cpu.halted = false
    if intr.ime and intr.gba.scheduler.cycles >= intr.gate_open_at:
      intr.gba.cpu.irq_line = true

proc `[]`*(intr: Interrupts; io_addr: uint32): uint8 =
  case io_addr
  of 0x200..0x201: read(intr.reg_ie, io_addr and 1)
  of 0x202..0x203: read(intr.reg_if, io_addr and 1)
  of 0x208: (if intr.ime: 1'u8 else: 0'u8)
  of 0x209: 0'u8
  else: raise newException(Exception, "Unimplemented interrupts read addr: " & hex_str(uint8(io_addr)))

proc `[]=`*(intr: Interrupts; io_addr: uint32; value: uint8) =
  let was_deliverable = intr.irq_deliverable
  case io_addr
  of 0x200..0x201: write(intr.reg_ie, value, io_addr and 1)
  of 0x202..0x203:
    let v = uint16(value) shl (8 * (io_addr and 1))
    intr.reg_if = cast[InterruptReg](uint16(intr.reg_if) and not v)
  of 0x208: intr.ime = bit(value, 0)
  of 0x209: discard
  else: raise newException(Exception, "Unimplemented interrupts write addr: " & hex_str(uint8(io_addr)) & " val: " & hex_str(value))
  if intr.irq_deliverable and not was_deliverable and
     not intr.gba.cpu.cpsr.irq_disable:
    # Gate opened with CPSR.I clear: late recognition. With I set,
    # recognition waits on the exception return, which is fast (mGBA suite
    # multi-IRQ Timer count-up rows).
    intr.gate_opened()
  else:
    # Clears re-evaluate immediately; check_interrupts holds irq_line off
    # until gate_open_at, so the second byte of a halfword IME/IE store
    # cannot recognize early.
    intr.schedule_interrupt_check()
