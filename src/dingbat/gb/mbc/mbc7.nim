# MBC7 cartridge (included by gb.nim)
#
# Written from Pan Docs (gbdev.io/pandocs/MBC7.html) and the 93LC56 datasheet
# it cites; SameBoy is used only as a behavioural cross-check to verify the
# result frame-for-frame. Two things about it are unlike every other GB
# cartridge:
#
#   * The 0xA000 window is gated twice. 0x0000-0x1FFF must see exactly 0x0A and
#     0x4000-0x5FFF exactly 0x40; either one alone leaves the window reading
#     0xFF. The games clear one of them between accesses, so honouring only the
#     first gate leaves the register file permanently live.
#   * There is no cart RAM behind the window at all — it is a register file.
#     The save data lives in a 93LC56 EEPROM reached one bit at a time through
#     register 0x8, so a "RAM write" there is a clock edge, not a store.

# Pan Docs: the 16-bit reading is "centered at the value 81D0" and "Earth's
# gravity affects the value by roughly $70". The centre matters beyond taste:
# Kirby integrates the difference from it, so a centre off by even a few units
# sends the ball drifting on its own.
const
  MBC7_ACCEL_CENTER = 0x81D0
  MBC7_ACCEL_SCALE  = 0x70

# 256 bytes as 128 16-bit words (Pan Docs: "data is addressed 16 bits at a
# time"). `ram` holds them little-endian, which also happens to match the
# battery files SameBoy writes, so .sav files interchange between the two.
proc ee_word(cart: Mbc7; index: int): uint16 =
  uint16(cart.ram[index * 2]) or (uint16(cart.ram[index * 2 + 1]) shl 8)

proc ee_set_word(cart: Mbc7; index: int; val: uint16) =
  cart.ram[index * 2]     = uint8(val and 0xFF)
  cart.ram[index * 2 + 1] = uint8(val shr 8)

proc ee_or_word(cart: Mbc7; index: int; bit: uint16) =
  cart.ram[index * 2]     = cart.ram[index * 2]     or uint8(bit and 0xFF)
  cart.ram[index * 2 + 1] = cart.ram[index * 2 + 1] or uint8(bit shr 8)

proc eeprom_clock(cart: Mbc7) =
  ## One rising clock edge with chip select asserted.
  # DO presents the top bit of the output shifter; the vacated bit shifts in as
  # 1, so a shifter that has run dry reads back as the idle all-ones bus.
  cart.eeprom_do = (cart.read_bits and 0x8000'u16) != 0
  cart.read_bits = (cart.read_bits shl 1) or 1'u16

  if cart.argument_bits_left == 0:
    # Shifting in a command. The register is 11 bits wide, so the leading start
    # bit reaches 0x400 exactly when the last address bit has arrived.
    cart.eeprom_command = ((cart.eeprom_command shl 1) or
                           (if cart.eeprom_di: 1'u16 else: 0'u16)) and 0x7FF'u16
    if (cart.eeprom_command and 0x400'u16) != 0:
      let address = int(cart.eeprom_command and 0x7F'u16)
      case int((cart.eeprom_command shr 6) and 0xF'u16)
      of 0x8, 0x9, 0xA, 0xB:  # READ
        cart.read_bits = cart.ee_word(address)
        cart.eeprom_command = 0
      of 0x3:                 # EWEN - write enable
        cart.eeprom_write_enabled = true
        cart.eeprom_command = 0
      of 0x0:                 # EWDS - write disable
        cart.eeprom_write_enabled = false
        cart.eeprom_command = 0
      of 0x4, 0x5, 0x6, 0x7:  # WRITE - clears the word, 16 data bits follow
        if cart.eeprom_write_enabled:
          cart.ee_set_word(address, 0)
          cart.ram_dirty = true
        cart.argument_bits_left = 16
        # eeprom_command is deliberately kept here: the argument phase needs its
        # address, and bit 0x100 to tell WRITE from WRAL.
      of 0xC, 0xD, 0xE, 0xF:  # ERASE
        if cart.eeprom_write_enabled:
          cart.ee_set_word(address, 0xFFFF)
          cart.ram_dirty = true
          cart.read_bits = 0x3FFF  # DO reads low for a while: write in progress
        cart.eeprom_command = 0
      of 0x2:                 # ERAL - erase all
        if cart.eeprom_write_enabled:
          for i in 0 ..< cart.ram.len: cart.ram[i] = 0xFF
          cart.ram_dirty = true
          cart.read_bits = 0xFF
        cart.eeprom_command = 0
      of 0x1:                 # WRAL - write all, 16 data bits follow
        if cart.eeprom_write_enabled:
          for i in 0 ..< cart.ram.len: cart.ram[i] = 0
          cart.ram_dirty = true
        cart.argument_bits_left = 16
      else: discard
  else:
    # Shifting in the 16 data bits of a WRITE or WRAL.
    dec cart.argument_bits_left
    cart.eeprom_do = true
    if cart.eeprom_di:
      let bit = 1'u16 shl cart.argument_bits_left
      if (cart.eeprom_command and 0x100'u16) != 0:
        cart.ee_or_word(int(cart.eeprom_command and 0x7F'u16), bit)
      else:
        # WRAL fills the whole chip, all 128 words (Pan Docs: "fill EEPROM with
        # value"). Neither game uses it for anything but blanking, so the last
        # word is not observable in them either way.
        for i in 0 ..< 0x80: cart.ee_or_word(i, bit)
      cart.ram_dirty = true
    if cart.argument_bits_left == 0:
      cart.eeprom_command = 0
      cart.read_bits = 0x3FFF  # settling time, as for ERASE

proc mbc7_reg_read(cart: Mbc7; idx: int): uint8 =
  if not (cart.ram_enabled and cart.secondary_enable): return 0xFF'u8
  if idx >= 0xB000: return 0xFF'u8   # only the low half of the window decodes
  case (idx shr 4) and 0xF
  of 2: uint8(cart.x_latch)
  of 3: uint8(cart.x_latch shr 8)
  of 4: uint8(cart.y_latch)
  of 5: uint8(cart.y_latch shr 8)
  of 6: 0'u8
  of 8:
    (if cart.eeprom_do: 0x01'u8 else: 0'u8) or
    (if cart.eeprom_di: 0x02'u8 else: 0'u8) or
    (if cart.eeprom_clk: 0x40'u8 else: 0'u8) or
    (if cart.eeprom_cs: 0x80'u8 else: 0'u8)
  else: 0xFF'u8

proc mbc7_reg_write(cart: Mbc7; idx: int; val: uint8) =
  if not (cart.ram_enabled and cart.secondary_enable): return
  if idx >= 0xB000: return
  case (idx shr 4) and 0xF
  of 0:
    # Arming the latch parks both axes at 0x8000, which reads as "no sample
    # yet" while the game waits for the 0xAA that takes the real one.
    if val == 0x55:
      cart.latch_ready = true
      cart.x_latch = 0x8000
      cart.y_latch = 0x8000
  of 1:
    if val == 0xAA:
      cart.latch_ready = false
      cart.x_latch = uint16((MBC7_ACCEL_CENTER +
                             int(MBC7_ACCEL_SCALE.float * cart.accel_x)) and 0xFFFF)
      cart.y_latch = uint16((MBC7_ACCEL_CENTER +
                             int(MBC7_ACCEL_SCALE.float * cart.accel_y)) and 0xFFFF)
  of 8:
    cart.eeprom_cs = (val and 0x80) != 0
    cart.eeprom_di = (val and 0x02) != 0
    # Everything happens on the rising clock edge, and only while selected
    if cart.eeprom_cs and not cart.eeprom_clk and (val and 0x40) != 0:
      cart.eeprom_clock()
    cart.eeprom_clk = (val and 0x40) != 0
  else: discard

method mbc_read*(cart: Mbc7; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF: cart.rom[idx]
  of 0x4000..0x7FFF:
    # Unlike the other mappers, bank 0 is not remapped to bank 1 here
    cart.rom[mbc_rom_bank_offset(cart, int(cart.rom_bank_num)) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF: mbc7_reg_read(cart, idx)
  else: 0xFF'u8

method mbc_write*(cart: Mbc7; idx: int; val: uint8) =
  case idx
  of 0x0000..0x1FFF: cart.ram_enabled = val == 0x0A  # exact, not a nibble test
  of 0x2000..0x3FFF: cart.rom_bank_num = val
  of 0x4000..0x5FFF: cart.secondary_enable = val == 0x40
  of 0xA000..0xBFFF: mbc7_reg_write(cart, idx, val)
  else: discard

proc set_accelerometer*(cart: Mbc; x, y: float) =
  ## Frontend tilt input, -1.0 .. 1.0 per axis with 0.0 level. A no-op on every
  ## other mapper, so callers need not check the cartridge type first.
  if cart of Mbc7:
    Mbc7(cart).accel_x = x
    Mbc7(cart).accel_y = y
