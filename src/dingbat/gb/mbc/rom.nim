# ROM (no MBC) cartridge (included by gb.nim via mbc.nim chain)

method mbc_rom_map*(cart: MbcRom): (int, int) = (0, 0x4000)
  ## Both windows are the identity: mbc_read indexes rom[idx] for either.

method mbc_read*(cart: MbcRom; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF: cart.rom[idx]
  of 0x4000..0x7FFF: cart.rom[idx]
  of 0xA000..0xBFFF:
    let off = idx - 0xA000
    if off < cart.ram.len: cart.ram[off] else: 0xFF'u8
  else: 0xFF'u8

method mbc_write*(cart: MbcRom; idx: int; val: uint8) =
  case idx
  of 0xA000..0xBFFF:
    let off = idx - 0xA000
    if off < cart.ram.len:
      cart.ram_dirty = true
      cart.ram[off] = val
  else: discard
