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
  of 0x120..0x12B, 0x134..0x15B: mmio.gba.serial[io_addr]
  of 0x130..0x133: mmio.gba.keypad[io_addr]
  of 0x200..0x203, 0x208..0x209: mmio.gba.interrupts[io_addr]
  of 0x204..0x205: read(mmio.waitcnt, io_addr and 1)
  of 0x206..0x207, 0x20A..0x20B, 0x302..0x303: 0'u8
  else:
    when defined(test_harness):
      if mmio.gba.test_output != nil and mmio.gba.test_output.mgba_debug_enable == 0xC0DE'u16:
        if io_addr == 0xFFF780'u32: return 0xEA'u8  # low byte of 0x1DEA
        elif io_addr == 0xFFF781'u32: return 0x1D'u8  # high byte
    mmio.gba.bus.read_open_bus_value(io_addr)

proc `[]=`*(mmio: MMIO; address: uint32; value: uint8) =
  let io_addr = 0xFFFFFF'u32 and address
  case io_addr
  of 0x000..0x055: mmio.gba.ppu[io_addr] = value
  of 0x060..0x0A7: mmio.gba.apu[io_addr] = value
  of 0x0B0..0x0DF: mmio.gba.dma[io_addr] = value
  of 0x100..0x10F: mmio.gba.timer[io_addr] = value
  of 0x120..0x12B, 0x134..0x15B: mmio.gba.serial[io_addr] = value
  of 0x130..0x133: mmio.gba.keypad[io_addr] = value
  of 0x200..0x203, 0x208..0x209: mmio.gba.interrupts[io_addr] = value
  of 0x204..0x205: write(mmio.waitcnt, value, io_addr and 1)
  of 0x301:
    if bit(value, 7):
      discard  # TODO: stop mode
    else:
      mmio.gba.cpu.halted = true
  else:
    when defined(test_harness):
      if mmio.gba.test_output != nil:
        if io_addr == 0xFFF780'u32:
          mmio.gba.test_output.mgba_debug_enable =
            (mmio.gba.test_output.mgba_debug_enable and 0xFF00'u16) or uint16(value)
        elif io_addr == 0xFFF781'u32:
          mmio.gba.test_output.mgba_debug_enable =
            (mmio.gba.test_output.mgba_debug_enable and 0x00FF'u16) or (uint16(value) shl 8)
        elif io_addr >= 0xFFF600'u32 and io_addr <= 0xFFF6FF'u32:
          let off = int(io_addr - 0xFFF600'u32)
          mmio.gba.test_output.mgba_debug_buffer[off] = value
        elif io_addr >= 0xFFF700'u32 and io_addr <= 0xFFF701'u32:
          var s = ""
          for b in mmio.gba.test_output.mgba_debug_buffer:
            if b == 0: break
            s.add(char(b))
          mmio.gba.test_output.mgba_debug_output.add(s & "\n")
          mmio.gba.test_output.mgba_debug_buffer = default(array[256, uint8])
          mmio.gba.test_output.mgba_debug_pos = 0
