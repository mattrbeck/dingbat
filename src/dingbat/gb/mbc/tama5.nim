# TAMA5 cartridge (included by gb.nim)
#
# Cart type 0xFD, one game: Game de Hakken!! Tamagotchi Osutchi to Mesutchi.
#
# The only primary documentation is the gbdev forum thread "TAMA5 (WIP)"
# (https://gbdev.gg8.se/forums/viewtopic.php?id=469): endrift's register map
# and RTC tables (post #1), corrected by skaman (post #4, cart reader), plus
# Tauwasser (post #2), CasualPokePlayer (post #9) and Lesserkuma (post #11).
# Pan Docs has no TAMA5 page; every non-obvious behaviour cites a post.
#
# Four chips (Tauwasser, post #2): a TC8521AM RTC, a TMP47C243M 4-bit MCU with
# an undumped mask ROM ("TAMA6"), the TAMA5 interface chip (a shift register
# and address decoding), and the game ROM. The MCU owns the clock, the buzzer
# and the 32 bytes of SRAM.
#
# The Game Boy sees two addresses, mirrored across the whole 0xA000-0xBFFF
# window because only A0 is decoded (endrift, post #1):
#
#   0xA001  register number
#   0xA000  one nibble of data, in or out
#
# and nine registers behind them:
#
#   0  ROM bank, address lines 17-14      4  data in, low nibble
#   1  ROM bank, address line 18          5  data in, high nibble
#   6  address/command, high nibble       C  data out, low nibble
#   7  address/command, low nibble        D  data out, high nibble
#   A  status: reads 1 once the chip is awake
#
# Writing register 7 is what commits an operation; the byte ((6) << 4) | (7) is
# an address-or-command whose top bits pick what kind:
#
#   0x00-0x1F  write ram[cmd & 0x1F]      0x40-0x5F  TAMA6 command
#   0x20-0x3F  read  ram[cmd & 0x1F]      0x80-0xBF  RTC register access
#
# endrift's prose in post #1 has register 6's read/write polarity backwards
# relative to his own command-range table; skaman's post #4 confirms the table
# ("to read the RAM, you use 0x20-0x3F ... write ... 0x00-0x1F").

proc tama5_rom_bank(cart: Tama5): int =
  ## endrift, post #1: register 0 drives RA14-17 and register 1 drives RA18, so
  ## five bits — 32 banks, exactly the 512 KiB the one game occupies.
  int(cart.regs[0] and 0x0F) or (int(cart.regs[1] and 0x01) shl 4)

proc tama5_tama6(cart: Tama5; command: int) =
  ## The MCU's own command set (endrift, post #1: "The TAMA6 commands (OR'd
  ## with $40)"); the 0x80 range is transparent TC8521AM register access.
  case command
  of 0x00: cart.page_reg = cart.page_reg and not 0x08'u8   # TIMER ENABLE off
  of 0x01:
    cart.page_reg = cart.page_reg or 0x08'u8               # TIMER ENABLE on...
    cart.rtc_pages[0][0] = 0                               # ...and reset seconds
    cart.rtc_pages[0][1] = 0
  of 0x04: cart.tama5_set_minutes(int(cart.regs[5]) * 10 + int(cart.regs[4]))
  of 0x05: cart.tama5_set_hours(int(cart.regs[5]) * 10 + int(cart.regs[4]))
  of 0x06:
    # The read of command 0x44. endrift documents the argument convention but
    # not where the answer lands; every other read lands in C (low) and D
    # (high). Unverified: no capture of 0x46/0x47 has been published.
    let m = cart.tama5_get_minutes()
    cart.regs[0x0C] = uint8(m mod 10)
    cart.regs[0x0D] = uint8(m div 10)
  of 0x07:
    let h = cart.tama5_get_hours()
    cart.regs[0x0C] = uint8(h mod 10)
    cart.regs[0x0D] = uint8(h div 10)
  of 0x10: cart.page_reg = cart.page_reg and not 0x04'u8   # ALARM ENABLE off
  of 0x11: cart.page_reg = cart.page_reg or 0x04'u8        # ALARM ENABLE on
  else: discard
    # 0x03 is "observed, but unknown behavior currently" (endrift, post #1) and
    # the rest have never been seen at all.

proc tama5_rtc_access(cart: Tama5) =
  ## Transparent access to one 4-bit TC8521AM register. endrift, post #1: the
  ## register number comes from register 4, the value from register 5, and
  ## register 7 carries the operation — "Bit 0: Clear for write, set for read.
  ## Bits 1-2: Page to access (0 = Timer, 1 = Alarm, 2/3 = Free pages)".
  let page = (int(cart.regs[7]) shr 1) and 3
  let num  = int(cart.regs[4]) and 0x0F
  if num >= 0x0D:
    # D, E and F are shared across pages: "Writing to the shared registers
    # directly is filtered out by TAMA6" (endrift, post #1; CasualPokePlayer,
    # post #9). E and F read zero; D is the PAGE register.
    if (cart.regs[7] and 1) != 0:
      cart.regs[0x0C] = if num == 0x0D: cart.page_reg and 0x0F else: 0'u8
    return
  # "RTC registers only have a certain number of bits wired up, so writing to
  # bits that aren't used during normal function won't do anything and will read
  # out as zero" — hence the per-page width table in gb.nim.
  let mask = TAMA5_RTC_MASK[page][num]
  if (cart.regs[7] and 1) != 0:
    cart.regs[0x0C] = cart.rtc_pages[page][num] and mask
  else:
    cart.rtc_pages[page][num] = cart.regs[5] and mask
    cart.ram_dirty = true

proc tama5_execute(cart: Tama5) =
  ## Run the address-or-command that a write to register 7 just completed.
  let cmd = (int(cart.regs[6]) shl 4) or int(cart.regs[7])
  case cmd shr 5
  of 0:   # 0x00-0x1F: SRAM write. Value was staged in registers 4 (low) and 5.
    let a = cmd and 0x1F
    if a < cart.ram.len:
      cart.ram[a] = (cart.regs[4] and 0x0F) or ((cart.regs[5] and 0x0F) shl 4)
      cart.ram_dirty = true
  of 1:   # 0x20-0x3F: SRAM read, answered in registers C (low) and D (high)
    let a = cmd and 0x1F
    let v = if a < cart.ram.len: cart.ram[a] else: 0xFF'u8
    cart.regs[0x0C] = v and 0x0F
    cart.regs[0x0D] = v shr 4
  of 2:   # 0x40-0x5F: TAMA6 command, the low five bits being the command number
    cart.tama5_tama6(cmd and 0x1F)
  of 3: discard
    # 0x60-0x7F: "Open bus? Just echoes the address back at you" (endrift,
    # post #1, unconfirmed in post #10). C and D keep the last command's result.
  else:   # 0x80 and up: the real-time clock
    cart.tama5_rtc_access()

method mbc_read*(cart: Tama5; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF: cart.rom[idx]
  of 0x4000..0x7FFF:
    cart.rom[mbc_rom_bank_offset(cart, tama5_rom_bank(cart)) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF:
    # Only A0 is decoded, so the two-address port repeats across the window.
    if (idx and 1) != 0: return 0xFF'u8
    # The upper four bits are not driven (endrift saw 0xF1, skaman 0xA1;
    # Lesserkuma's reader masks with 3): a floating bus that sits high.
    case cart.reg_index
    of 0x0A: 0xF1'u8   # "Wait until $A000 replies with $F1" — the chip is awake
    else:    0xF0'u8 or (cart.regs[cart.reg_index] and 0x0F)
  else: 0xFF'u8

method mbc_write*(cart: Tama5; idx: int; val: uint8) =
  case idx
  of 0xA000..0xBFFF:
    if (idx and 1) != 0:
      cart.reg_index = val and 0x0F
    else:
      cart.regs[cart.reg_index] = val and 0x0F
      # Registers 0 and 1 are wired straight to the ROM's address lines and take
      # effect on the spot; everything else is staged until register 7 lands.
      if cart.reg_index == 0x07: cart.tama5_execute()
  else: discard
    # Nothing is documented at 0x0000-0x7FFF. endrift, post #1: "Some stuff
    # seems to write to low ROM areas, but I don't know what those do."
