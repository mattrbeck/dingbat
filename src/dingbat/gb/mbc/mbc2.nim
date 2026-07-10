# MBC2 cartridge (included by gb.nim)

method mbc_read*(cart: Mbc2; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF: cart.rom[idx]
  of 0x4000..0x7FFF:
    cart.rom[mbc_rom_bank_offset(cart, int(cart.rom_bank)) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF:
    if cart.ram_enabled:
      (cart.ram[mbc_ram_offset(idx) mod 0x0200]) or 0xF0'u8
    else: 0xFF'u8
  else: 0xFF'u8

method mbc_write*(cart: Mbc2; idx: int; val: uint8) =
  case idx
  of 0x0000..0x3FFF:
    if (idx and 0x0100) == 0:  # RAMG
      let enabling = (val and 0x0F) == 0b1010
      if cart.ram_enabled and not enabling: mbc_save(cart)
      cart.ram_enabled = enabling
    else:  # ROMB
      cart.rom_bank = val and 0x0F
      if cart.rom_bank == 0: cart.rom_bank = 1
  of 0xA000..0xBFFF:
    if cart.ram_enabled:
      cart.ram_dirty = true
      cart.ram[mbc_ram_offset(idx) mod 0x0200] = val and 0x0F
  else: discard
