# MBC3 cartridge (included by gb.nim)

method mbc_read*(cart: Mbc3; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF: cart.rom[idx]
  of 0x4000..0x7FFF:
    cart.rom[mbc_rom_bank_offset(cart, int(cart.rom_bank_num)) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF:
    if cart.ram_bank_num <= 3:
      if cart.ram_enabled and cart.ram.len > 0:
        cart.ram[mbc_ram_bank_offset(cart, int(cart.ram_bank_num)) + mbc_ram_offset(idx)]
      else: 0xFF'u8
    elif cart.ram_bank_num <= 0x0C:
      0xFF'u8  # RTC registers (stub)
    else: 0xFF'u8
  else: 0xFF'u8

method mbc_write*(cart: Mbc3; idx: int; val: uint8) =
  case idx
  of 0x0000..0x1FFF:
    let enabling = (val and 0x0F) == 0x0A
    if cart.ram_enabled and not enabling: mbc_save(cart)
    cart.ram_enabled = enabling
  of 0x2000..0x3FFF:
    cart.rom_bank_num = val and 0x7F
    if cart.rom_bank_num == 0: cart.rom_bank_num = 1
  of 0x4000..0x5FFF:
    cart.ram_bank_num = val
  of 0x6000..0x7FFF:
    discard  # latch clock (stub)
  of 0xA000..0xBFFF:
    if cart.ram_bank_num <= 0x03:
      if cart.ram_enabled and cart.ram.len > 0:
        cart.ram_dirty = true
        cart.ram[mbc_ram_bank_offset(cart, int(cart.ram_bank_num)) + mbc_ram_offset(idx)] = val
    elif cart.ram_bank_num <= 0x0C:
      discard  # RTC write (stub)
  else: discard
