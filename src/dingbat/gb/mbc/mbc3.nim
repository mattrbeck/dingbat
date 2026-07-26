# MBC3 cartridge (included by gb.nim)

proc rtc_write(cart: Mbc3; reg: int; val: uint8) =
  cart.ram_dirty = true
  case reg
  of 0:
    cart.rtc_live[0] = val and 0x3F
    # Writing the seconds register resets the sub-second divider
    if cart.rtc_halted():
      cart.rtc_halt_remaining = RTC_SECOND_CYCLES
    else:
      cart.rtc_schedule_full()
  of 1: cart.rtc_live[1] = val and 0x3F
  of 2: cart.rtc_live[2] = val and 0x1F
  of 3: cart.rtc_live[3] = val
  of 4:
    # Halting freezes the sub-second remainder; resuming continues from it
    let was_halted = cart.rtc_halted()
    let now_halted = (val and 0x40) != 0
    if not was_halted and now_halted:
      cart.rtc_halt_remaining = cart.rtc_remaining()
      cart.gb_ref.scheduler.clear(etRtcSecond)
    elif was_halted and not now_halted:
      cart.gb_ref.scheduler.clear(etRtcSecond)
      cart.gb_ref.scheduler.schedule(cart.rtc_halt_remaining, etRtcSecond)
    cart.rtc_live[4] = val and 0xC1
  else: discard

method mbc_rom_map*(cart: Mbc3): (int, int) =
  ## The RTC lives behind 0xA000-0xBFFF and never moves the ROM window.
  (0, mbc_rom_bank_offset(cart, int(cart.rom_bank_num)))

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
    elif cart.ram_bank_num >= 0x08 and cart.ram_bank_num <= 0x0C:
      if cart.has_rtc and cart.ram_enabled:
        const masks = [0x3F'u8, 0x3F, 0x1F, 0xFF, 0xC1]
        let reg = int(cart.ram_bank_num) - 8
        cart.rtc_latched[reg] and masks[reg]
      else: 0xFF'u8
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
    # Writing 0x00 then 0x01 latches the live clock into the readable registers
    if cart.has_rtc:
      if cart.rtc_latch_prev == 0 and val == 1:
        cart.rtc_latched = cart.rtc_live
      cart.rtc_latch_prev = val
  of 0xA000..0xBFFF:
    if cart.ram_bank_num <= 0x03:
      if cart.ram_enabled and cart.ram.len > 0:
        cart.ram_dirty = true
        cart.ram[mbc_ram_bank_offset(cart, int(cart.ram_bank_num)) + mbc_ram_offset(idx)] = val
    elif cart.ram_bank_num >= 0x08 and cart.ram_bank_num <= 0x0C:
      if cart.has_rtc and cart.ram_enabled:
        cart.rtc_write(int(cart.ram_bank_num) - 8, val)
  else: discard
