# MBC1 cartridge (included by gb.nim)
#
# MBC1M multicarts wire the cart differently: BANK1 bit 4 is not connected
# (only 4 bits reach the ROM) and BANK2 drives ROM address lines 18-19, i.e.
# it shifts by 4 instead of 5. The BANK1 register itself is still 5 bits wide
# with the full-register zero check, so e.g. $10 stays $10 (wired bank 0).

proc mbc1_lo_bank(cart: Mbc1): int =
  if cart.multicart: int(cart.reg2) shl 4
  else:              int(cart.reg2) shl 5

proc mbc1_hi_bank(cart: Mbc1): int =
  if cart.multicart: (int(cart.reg2) shl 4) or (int(cart.reg1) and 0x0F)
  else:              (int(cart.reg2) shl 5) or int(cart.reg1)

method mbc_read*(cart: Mbc1; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF:
    if cart.mode == 0:
      cart.rom[idx]
    else:
      cart.rom[mbc_rom_bank_offset(cart, mbc1_lo_bank(cart)) + idx]
  of 0x4000..0x7FFF:
    cart.rom[mbc_rom_bank_offset(cart, mbc1_hi_bank(cart)) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF:
    if cart.ram_enabled and cart.ram.len > 0:
      if cart.mode == 0:
        cart.ram[mbc_ram_offset(idx)]
      else:
        cart.ram[mbc_ram_bank_offset(cart, int(cart.reg2)) + mbc_ram_offset(idx)]
    else: 0xFF'u8
  else: 0xFF'u8

method mbc_write*(cart: Mbc1; idx: int; val: uint8) =
  case idx
  of 0x0000..0x1FFF:
    let enabling = (val and 0x0F) == 0x0A
    if cart.ram_enabled and not enabling: mbc_save(cart)
    cart.ram_enabled = enabling
  of 0x2000..0x3FFF:
    cart.reg1 = val and 0b0001_1111
    if cart.reg1 == 0: cart.reg1 = 1
  of 0x4000..0x5FFF:
    cart.reg2 = val and 0b0000_0011
  of 0x6000..0x7FFF:
    cart.mode = val and 0x1
  of 0xA000..0xBFFF:
    if cart.ram_enabled and cart.ram.len > 0:
      cart.ram_dirty = true
      if cart.mode == 0:
        cart.ram[mbc_ram_offset(idx)] = val
      else:
        cart.ram[mbc_ram_bank_offset(cart, int(cart.reg2)) + mbc_ram_offset(idx)] = val
  else: discard
