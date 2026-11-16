# TAMA5 cartridge (included by gb.nim)
#
# Cart type 0xFD, one game: Game de Hakken!! Tamagotchi Osutchi to Mesutchi.
#
# Source: gbdev forum thread "TAMA5 (WIP)"
# (https://gbdev.gg8.se/forums/viewtopic.php?id=469); "post #N" below cites
# it (Pan Docs has no TAMA5 page). Chips (post #2): TC8521AM RTC, a TMP47C243M
# MCU ("TAMA6", undumped; owns clock, buzzer and 32 bytes of SRAM), the TAMA5
# interface, and the game ROM.
#
# Two addresses, mirrored over 0xA000-0xBFFF (only A0 decoded, post #1):
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
# Post #1's prose has register 6's read/write polarity backwards; its table
# (above) is right, confirmed by post #4.

proc tama5_rom_bank(cart: Tama5): int =
  ## Register 0 drives RA14-17, register 1 RA18 (post #1): 32 banks.
  int(cart.regs[0] and 0x0F) or (int(cart.regs[1] and 0x01) shl 4)

proc tama5_tama6(cart: Tama5; command: int) =
  ## The MCU's command set (post #1).
  case command
  of 0x00: cart.page_reg = cart.page_reg and not 0x08'u8   # TIMER ENABLE off
  of 0x01:
    cart.page_reg = cart.page_reg or 0x08'u8               # TIMER ENABLE on...
    cart.rtc_pages[0][0] = 0                               # ...and reset seconds
    cart.rtc_pages[0][1] = 0
  of 0x04: cart.tama5_set_minutes(int(cart.regs[5]) * 10 + int(cart.regs[4]))
  of 0x05: cart.tama5_set_hours(int(cart.regs[5]) * 10 + int(cart.regs[4]))
  of 0x06:
    # Reads back command 0x44's value. The answer is assumed to land in C/D
    # like every other read; unverified (no 0x46/0x47 capture published).
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
    # 0x03 is seen but unknown (post #1); the rest are never seen.

proc tama5_rtc_access(cart: Tama5) =
  ## One 4-bit TC8521AM register (post #1): number in register 4, value in 5;
  ## register 7 bit 0 = read, bits 1-2 = page (0 timer, 1 alarm, 2/3 free).
  let page = (int(cart.regs[7]) shr 1) and 3
  let num  = int(cart.regs[4]) and 0x0F
  if num >= 0x0D:
    # D, E, F are shared across pages and writes are filtered out (posts #1,
    # #9). E and F read zero; D is the PAGE register.
    if (cart.regs[7] and 1) != 0:
      cart.regs[0x0C] = if num == 0x0D: cart.page_reg and 0x0F else: 0'u8
    return
  # Unwired RTC bits ignore writes and read zero: TAMA5_RTC_MASK (gb.nim).
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
    # 0x60-0x7F: "Just echoes the address back" (post #1, unconfirmed in
    # post #10). C and D keep the last result.
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
    # Upper four bits undriven (0xF1 and 0xA1 both reported): read high.
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
      # Registers 0 and 1 act at once; the rest stage until register 7.
      if cart.reg_index == 0x07: cart.tama5_execute()
  else: discard
    # Writes to 0x0000-0x7FFF are undocumented (post #1).
