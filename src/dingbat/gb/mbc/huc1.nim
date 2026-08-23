# HuC1 cartridge (included by gb.nim)
#
# Pan Docs "HuC1" and jrra's teardown (https://jrra.zone/blog/huc1.html).
# Unlike MBC1 there is no RAM enable: 0xA000-0xBFFF is live from power-on, and
# 0x0000-0x1FFF is a window selector (0x0E routes the window to the IR
# transceiver, anything else back to RAM). Gating RAM like MBC1 leaves save
# RAM reading 0xFF. Bank registers are unmasked: Pan Docs gives only minimum
# widths, and the shared helpers wrap over the real ROM/RAM size anyway.

method mbc_rom_map*(cart: Huc1): (int, int) =
  (0, mbc_rom_bank_offset(cart, int(cart.bank_low)))

method mbc_read*(cart: Huc1; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF: cart.rom[idx]
  of 0x4000..0x7FFF:
    # No bank-0 remap: unlike MBC1, nothing documents one here
    cart.rom[mbc_rom_bank_offset(cart, int(cart.bank_low)) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF:
    if cart.ir_mode:
      # Pan Docs: 0xC1 with light, 0xC0 without; there is no IR peer.
      0xC0'u8
    elif cart.ram.len > 0:
      cart.ram[mbc_ram_bank_offset(cart, int(cart.bank_high)) + mbc_ram_offset(cart, idx)]
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
      cart.ram[mbc_ram_bank_offset(cart, int(cart.bank_high)) + mbc_ram_offset(cart, idx)] = val
  else: discard
