# Interrupts implementation (included by gba.nim)

proc new_interrupts*(gba: GBA): Interrupts =
  result = Interrupts(gba: gba)
  result.reg_ie = InterruptReg()
  result.reg_if = InterruptReg()
  result.ime = false

proc schedule_interrupt_check*(intr: Interrupts) =
  let g = intr.gba
  g.scheduler.schedule(0, proc() {.closure.} =
    if (uint16(intr.reg_ie) and uint16(intr.reg_if)) != 0:
      g.cpu.halted = false
      if intr.ime:
        g.cpu.irq()
  , etInterrupts)

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
