# HuC1 cartridge (included by gb.nim)
#
# Hudson's own mapper, documented in Pan Docs "HuC1" and in jrra's teardown that
# Pan Docs cites (https://jrra.zone/blog/huc1.html). The received wisdom that it
# is "MBC1-like" is wrong in the two places that matter:
#
#   * There is no RAM enable. 0xA000-0xBFFF is live from power-on for reads and
#     writes alike, so gating it the way MBC1 does leaves a game's save RAM
#     reading 0xFF forever. Games do still write 0x0A and 0x00 to 0x0000-0x1FFF
#     as if it were an enable; those writes simply select RAM, which is where
#     the window already was.
#   * 0x0000-0x1FFF is a window selector instead: writing 0x0E routes
#     0xA000-0xBFFF to the cartridge's infrared transceiver, and any other value
#     routes it back to RAM.
#
# Neither bank register is masked here. Pan Docs pins them only as "at least 6
# bits" (ROM) and "at least 2 bits" (RAM), so the true widths are unknown; every
# candidate width behaves identically once the shared bank helpers wrap the
# result over a power-of-two ROM or RAM, which is every real cartridge.

method mbc_read*(cart: Huc1; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF: cart.rom[idx]
  of 0x4000..0x7FFF:
    # No bank-0 remap: unlike MBC1, nothing documents one here
    cart.rom[mbc_rom_bank_offset(cart, int(cart.bank_low)) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF:
    if cart.ir_mode:
      # Pan Docs: 0xC1 when the receiver sees light, 0xC0 when it does not.
      # dingbat has no IR peer to see light from, so this is a constant.
      0xC0'u8
    elif cart.ram.len > 0:
      cart.ram[mbc_ram_bank_offset(cart, int(cart.bank_high)) + mbc_ram_offset(idx)]
    else: 0xFF'u8
  else: 0xFF'u8

method mbc_write*(cart: Huc1; idx: int; val: uint8) =
  case idx
  of 0x0000..0x1FFF: cart.ir_mode = val == 0x0E
  of 0x2000..0x3FFF: cart.bank_low  = val
  of 0x4000..0x5FFF: cart.bank_high = val
  of 0x6000..0x7FFF: discard  # documented as doing nothing; games write here anyway
  of 0xA000..0xBFFF:
    if cart.ir_mode:
      cart.cart_ir = (val and 1) != 0   # 0x01 emitter on, 0x00 off
    elif cart.ram.len > 0:
      cart.ram_dirty = true
      cart.ram[mbc_ram_bank_offset(cart, int(cart.bank_high)) + mbc_ram_offset(idx)] = val
  else: discard
