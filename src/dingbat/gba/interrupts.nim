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

proc schedule_interrupt_check*(intr: Interrupts) =
  intr.gba.scheduler.schedule(0, etInterrupts)

proc check_interrupts*(intr: Interrupts) =
  let pending = uint16(intr.reg_ie) and uint16(intr.reg_if)
  if pending != 0:
    if intr.gba.cpu.stopped and (pending and STOP_WAKE_MASK) == 0:
      return  # Stop mode ignores other interrupt sources
    if intr.gba.cpu.stopped:
      # Waking from Stop turns the LCD back on without any memory write
      intr.gba.ppu.render_dirty = true
    intr.gba.cpu.stopped = false
    intr.gba.cpu.halted = false
    if intr.ime:
      intr.gba.cpu.irq()

proc `[]`*(intr: Interrupts; io_addr: uint32): uint8 =
  case io_addr
  of 0x200..0x201: read(intr.reg_ie, io_addr and 1)
  of 0x202..0x203: read(intr.reg_if, io_addr and 1)
  of 0x208: (if intr.ime: 1'u8 else: 0'u8)
  of 0x209: 0'u8
  else: raise newException(Exception, "Unimplemented interrupts read addr: " & hex_str(uint8(io_addr)))

proc `[]=`*(intr: Interrupts; io_addr: uint32; value: uint8) =
  case io_addr
  of 0x200..0x201: write(intr.reg_ie, value, io_addr and 1)
  of 0x202..0x203:
    let v = uint16(value) shl (8 * (io_addr and 1))
    intr.reg_if = cast[InterruptReg](uint16(intr.reg_if) and not v)
  of 0x208: intr.ime = bit(value, 0)
  of 0x209: discard
  else: raise newException(Exception, "Unimplemented interrupts write addr: " & hex_str(uint8(io_addr)) & " val: " & hex_str(value))
  intr.schedule_interrupt_check()
