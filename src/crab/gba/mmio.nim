# MMIO implementation (included by gba.nim)

proc new_mmio*(gba: GBA): MMIO =
  result = MMIO(gba: gba)
  result.waitcnt = WAITCNT()

proc `[]`*(mmio: MMIO; address: uint32): uint8 =
  let io_addr = 0xFFFFFF'u32 and address
  case io_addr
  of 0x000..0x055: mmio.gba.ppu[io_addr]
  of 0x060..0x0A7: mmio.gba.apu[io_addr]
  of 0x0B0..0x0DF: mmio.gba.dma[io_addr]
  of 0x100..0x10F: mmio.gba.timer[io_addr]
  of 0x120..0x12B, 0x134..0x15B:
    if io_addr == 0x135: 0x80'u8
    else: 0'u8
  of 0x130..0x133: mmio.gba.keypad[io_addr]
  of 0x200..0x203, 0x208..0x209: mmio.gba.interrupts[io_addr]
  of 0x204..0x205: read(mmio.waitcnt, io_addr and 1)
  of 0x206..0x207, 0x20A..0x20B, 0x302..0x303: 0'u8
  else: mmio.gba.bus.read_open_bus_value(io_addr)

proc `[]=`*(mmio: MMIO; address: uint32; value: uint8) =
  let io_addr = 0xFFFFFF'u32 and address
  case io_addr
  of 0x000..0x055: mmio.gba.ppu[io_addr] = value
  of 0x060..0x0A7: mmio.gba.apu[io_addr] = value
  of 0x0B0..0x0DF: mmio.gba.dma[io_addr] = value
  of 0x100..0x10F: mmio.gba.timer[io_addr] = value
  of 0x120..0x12B, 0x134..0x15B: discard  # serial, todo
  of 0x130..0x133: mmio.gba.keypad[io_addr] = value
  of 0x200..0x203, 0x208..0x209: mmio.gba.interrupts[io_addr] = value
  of 0x204..0x205: write(mmio.waitcnt, value, io_addr and 1)
  of 0x301:
    if bit(value, 7):
      discard  # TODO: stop mode
    else:
      mmio.gba.cpu.halted = true
  else: discard
