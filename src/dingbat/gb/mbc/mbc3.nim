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

proc mbc3_ram_bank_top(cart: Mbc3): uint8 {.inline.} =
  ## MBC30 is an MBC3 with one more RAM address line: banks 0-7 all map RAM.
  ## Pan Docs (cartridge header): "MBC3 with 64 KiB of SRAM refers to MBC30"
  ## — the header's RAM size is the only signal the cart gives, and JP Pokemon
  ## Crystal (the one retail MBC30 title) is exactly the $10 type + $05 RAM
  ## combination. Its PC boxes live in banks 4-7. Plain MBC3 keeps the
  ## measured 0-3-else-open-bus map (rtc-invalid-banks capture, mbc_write).
  if cart.ram.len >= 0x2000 * 8: 0x07'u8 else: 0x03'u8

proc mbc3_rom_mask(cart: Mbc3): uint8 {.inline.} =
  ## Same line count on the ROM side: MBC30 drives 8 ROM-bank bits (4 MiB)
  ## where MBC3 drives 7. Keyed off the actual image so a 2 MiB MBC30 cart
  ## (JP Crystal) behaves identically either way.
  if cart.rom.len > 0x4000 * 128: 0xFF'u8 else: 0x7F'u8

method mbc_rom_map*(cart: Mbc3): (int, int) =
  ## The RTC lives behind 0xA000-0xBFFF and never moves the ROM window.
  (0, mbc_rom_bank_offset(cart, int(cart.rom_bank_num)))

method mbc_read*(cart: Mbc3; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF: cart.rom[idx]
  of 0x4000..0x7FFF:
    cart.rom[mbc_rom_bank_offset(cart, int(cart.rom_bank_num)) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF:
    if cart.ram_bank_num <= cart.mbc3_ram_bank_top():
      if cart.ram_enabled and cart.ram.len > 0:
        cart.ram[mbc_ram_bank_offset(cart, int(cart.ram_bank_num)) + mbc_ram_offset(cart, idx)]
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
    cart.rom_bank_num = val and cart.mbc3_rom_mask()
    if cart.rom_bank_num == 0: cart.rom_bank_num = 1
  of 0x4000..0x5FFF:
    # RAMB is FOUR bits wide, not eight. CasualPokePlayer's rtc-invalid-banks
    # README: "The RAMB register for MBC3+RTC is a 4 bit register. The upper 4
    # bits do not affect the bank selected. […] there are only 9 possible valid
    # combinations […] 'banks' 04-07 and 0D-0F never map to anything […] the
    # invalid banks appear to produce open bus behavior." Its capture is that
    # statement drawn: the 16-entry pattern 00 01 02 03 FF FF FF FF 08 09 0A 0B
    # 00 FF FF FF repeated sixteen times across e = $00..$FF. Without the mask
    # every e >= $10 falls through to the open-bus arm below instead of
    # aliasing, so only the first sixteen entries are right.
    cart.ram_bank_num = val and 0x0F
  of 0x6000..0x7FFF:
    # Latch Clock Data. Pan Docs documents the canonical "$00 then $01"
    # sequence, but that is how software is expected to drive the pin, not the
    # condition the MBC latches on: the latch is level-insensitive and fires on
    # ANY write to this range.
    #
    # The evidence is CasualPokePlayer's latch-rtc-test, which writes ONE
    # random byte per iteration (51 unrolled `call rand / ld [$6000],a` blocks
    # at $404F..$444B) and prints the latched registers each time. Its own PRNG
    # is a 32-bit adder chain at $00DF seeded to zero at $4005, so the byte
    # sequence is reproducible outside the emulator; replaying it against the
    # suite's hardware capture matches all 51 five-byte reports exactly under
    # "every write latches", and misses 28 of 51 under a bit-0 edge/level rule
    # and 51 of 51 under "reads are always live". An edge rule cannot be right
    # in any case: with uniformly random bytes it would re-latch about a
    # quarter of the time, and the capture shows 50 consecutive distinct
    # reports with no repeat at all.
    if cart.has_rtc:
      cart.rtc_latched = cart.rtc_live
      # Retained only so the save-state payload keeps its shape; nothing reads
      # it any more (see GB.Mbc3.rtc_latch_prev).
      cart.rtc_latch_prev = val and 1
  of 0xA000..0xBFFF:
    if cart.ram_bank_num <= cart.mbc3_ram_bank_top():
      if cart.ram_enabled and cart.ram.len > 0:
        cart.ram_dirty = true
        cart.ram[mbc_ram_bank_offset(cart, int(cart.ram_bank_num)) + mbc_ram_offset(cart, idx)] = val
    elif cart.ram_bank_num >= 0x08 and cart.ram_bank_num <= 0x0C:
      if cart.has_rtc and cart.ram_enabled:
        cart.rtc_write(int(cart.ram_bank_num) - 8, val)
  else: discard
