# MBC6 cartridge (included by gb.nim)
#
# Cart type 0x20, one game: Net de Get - Minigame @ 100, a Japan-only title that
# used the Mobile Adapter GB to download extra minigames into an on-cartridge
# flash chip. Written from Pan Docs "MBC6" (gbdev.io/pandocs/MBC6.html, sourced
# from endrift's thread https://gbdev.gg8.se/forums/viewtopic.php?id=544) and
# the Nintendo Power GB Memory documentation it points at for the flash part
# (https://iceboy.a-singer.de/doc/np_gb_memory.html), whose chip differs only in
# part number. The game was not obtainable: implemented from the documents and
# untested against a real title.
#
# Everything unusual about MBC6 follows from it having two of everything. The
# 0x4000-0x7FFF ROM region is split into two independently banked 8 KiB windows
# (A at 0x4000, B at 0x6000) and 0xA000-0xBFFF into two independently banked
# 4 KiB RAM windows (A at 0xA000, B at 0xB000). Either ROM window can be pointed
# at the mask ROM or at the 8 Mbit Macronix flash instead, and when it points at
# the flash it is a read/write window onto a chip that speaks the ordinary
# JEDEC command protocol.
#
# The register file is unusual too: instead of four 8 KiB blocks it is nine
# separate decodes inside the first 0x4000 bytes.

const
  MBC6_FLASH_LEN    = 0x100000   # 8 Mbit
  MBC6_HIDDEN_LEN   = 0x100      # the extra 256 bytes behind the hidden-region commands
  MBC6_SECTOR_LEN   = 0x20000    # eight 128 KiB sectors

  # What a flash window currently reads back.
  MBC6_READ_ARRAY  = 0'u8
  MBC6_READ_ID     = 1'u8
  MBC6_READ_STATUS = 2'u8
  MBC6_READ_HIDDEN = 3'u8

proc mbc6_rom_read(cart: Mbc6; bank: int; off: int): uint8 =
  cart.rom[((bank * 0x2000) + off) mod cart.rom.len]

proc mbc6_sector0(offset: int): bool = offset < MBC6_SECTOR_LEN

proc mbc6_may_write_sector0(cart: Mbc6): bool =
  ## Sector 0 sits behind two independent locks. Pan Docs: "The Flash Write
  ## Enable bit protects both, sector 0 and the hidden region. The Protect
  ## Sector 0 command only protects sector 0."
  cart.flash_write_enabled and not cart.flash_sector0_protected

proc mbc6_flash_read(cart: Mbc6; offset: int): uint8 =
  # With Flash Enable off the MBC6 never asserts /CE, so the chip is not driving
  # the bus at all.
  if not cart.flash_enabled: return 0xFF'u8
  case cart.flash_read_mode
  of MBC6_READ_ID:
    # "ID mode (reads out JEDEC ID (C2,81) at $XXX0,$XXX1)" — C2 is Macronix,
    # 81 the MX29F008TC device code.
    if (offset and 1) == 0: 0xC2'u8 else: 0x81'u8
  of MBC6_READ_STATUS: cart.flash_status
  of MBC6_READ_HIDDEN: cart.flash_hidden[offset and (MBC6_HIDDEN_LEN - 1)]
  else: cart.flash[offset and (MBC6_FLASH_LEN - 1)]

proc mbc6_erase(cart: Mbc6; first, last: int) =
  for i in first ..< last: cart.flash[i] = 0xFF
  cart.ram_dirty = true

proc mbc6_finish(cart: Mbc6; extra_status: uint8 = 0) =
  ## Every erase, program and protect command leaves the window reading status
  ## instead of data until an $F0 clears it. Bit 7 set means the operation has
  ## finished, which for an emulated chip is immediately; bit 4 would be a
  ## timeout and never happens here.
  cart.flash_read_mode = MBC6_READ_STATUS
  cart.flash_status = 0x80'u8 or extra_status
  cart.flash_cmd_step = 0
  cart.flash_setup = 0

proc mbc6_flash_command(cart: Mbc6; offset: int; val: uint8) =
  ## The two unlock addresses are 0x5555 and 0x2AAA *within the flash*, which is
  ## what Pan Docs' "2:Y555 / 1:XAAA" notation resolves to once the bank number
  ## and the window offset are folded together: bank 2 at Game Boy 0x5555 is
  ## flash 0x5555, and bank 1 at Game Boy 0x4AAA is flash 0x2AAA.
  if val == 0xF0:
    # "Exit any of the commands above" — from any address, at any point.
    cart.flash_read_mode = MBC6_READ_ARRAY
    cart.flash_cmd_step = 0
    cart.flash_setup = 0
    return

  if cart.flash_read_mode == MBC6_READ_ARRAY and cart.flash_setup == 0xA0'u8:
    # Program mode. Bits can only be cleared, never set — "The only way to set
    # the bits back to 1 is to erase the sector entirely" — so a program is an
    # AND, and a sector that was not erased first ends up with the old and new
    # values anded together, exactly as the page warns.
    if cart.flash_program_hidden:
      if cart.flash_write_enabled:
        cart.flash_hidden[offset and (MBC6_HIDDEN_LEN - 1)] =
          cart.flash_hidden[offset and (MBC6_HIDDEN_LEN - 1)] and val
        cart.ram_dirty = true
    elif not mbc6_sector0(offset) or cart.mbc6_may_write_sector0():
      cart.flash[offset and (MBC6_FLASH_LEN - 1)] =
        cart.flash[offset and (MBC6_FLASH_LEN - 1)] and val
      cart.ram_dirty = true
    if offset == cart.flash_program_addr:
      # "then writing any value (except $F0) to the final address again to
      # commit the write". A repeat of the previous address is that commit.
      cart.mbc6_finish()
      cart.flash_program_hidden = false
    else:
      cart.flash_program_addr = offset
    return

  case cart.flash_cmd_step
  of 0:
    if offset == 0x5555 and val == 0xAA: cart.flash_cmd_step = 1
  of 1:
    cart.flash_cmd_step = if offset == 0x2AAA and val == 0x55: 2 else: 0
  of 2:
    cart.flash_cmd_step = 0
    if offset != 0x5555: return
    case val
    of 0x90: cart.flash_read_mode = MBC6_READ_ID
    of 0xA0:
      cart.flash_setup = 0xA0
      cart.flash_program_addr = -1
      cart.flash_program_hidden = false
    of 0x80, 0x60, 0x77:
      cart.flash_setup = val      # three-more-writes commands
      cart.flash_cmd_step = 3
    else: discard
  of 3:
    cart.flash_cmd_step = if offset == 0x5555 and val == 0xAA: 4 else: 0
  of 4:
    cart.flash_cmd_step = if offset == 0x2AAA and val == 0x55: 5 else: 0
  else:
    let setup = cart.flash_setup
    cart.flash_cmd_step = 0
    cart.flash_setup = 0
    case setup
    of 0x80:
      if val == 0x30:
        # "The last byte of the erase sector command needs to be written to an
        # address that lies within the sector that you want to erase."
        let sector = (offset and (MBC6_FLASH_LEN - 1)) div MBC6_SECTOR_LEN
        if sector != 0 or cart.mbc6_may_write_sector0():
          cart.mbc6_erase(sector * MBC6_SECTOR_LEN, (sector + 1) * MBC6_SECTOR_LEN)
        cart.mbc6_finish()
      elif val == 0x10 and offset == 0x5555:
        # "The erase chip command erases the whole 1 MiB flash. The 256 byte
        # hidden region is not erased... If sector 0 is protected... only
        # sectors 1 to 7 are erased."
        let first = if cart.mbc6_may_write_sector0(): 0 else: MBC6_SECTOR_LEN
        cart.mbc6_erase(first, MBC6_FLASH_LEN)
        cart.mbc6_finish()
    of 0x60:
      if offset != 0x5555 and val != 0x04: return
      case val
      of 0x04:
        if cart.flash_write_enabled:
          for i in 0 ..< MBC6_HIDDEN_LEN: cart.flash_hidden[i] = 0xFF
          cart.ram_dirty = true
        cart.mbc6_finish()
      of 0xE0:
        cart.flash_setup = 0xA0        # program mode, aimed at the hidden region
        cart.flash_program_addr = -1
        cart.flash_program_hidden = true
      of 0x40:
        if cart.flash_write_enabled: cart.flash_sector0_protected = false
        cart.ram_dirty = true          # the protection bit is non-volatile
        cart.mbc6_finish()
      of 0x20:
        if cart.flash_write_enabled: cart.flash_sector0_protected = true
        cart.ram_dirty = true
        # "Status bit 1 (mask $02) is set when the sector 0 protection was
        # enabled by the Protect Sector 0 command."
        cart.mbc6_finish(if cart.flash_sector0_protected: 0x02'u8 else: 0'u8)
      else: discard
    of 0x77:
      if val == 0x77 and offset == 0x5555: cart.flash_read_mode = MBC6_READ_HIDDEN
    else: discard

method mbc_read*(cart: Mbc6; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF: cart.rom[idx]
  of 0x4000..0x5FFF:
    let off = idx - 0x4000
    if cart.flash_select_a: mbc6_flash_read(cart, int(cart.rom_bank_a) * 0x2000 + off)
    else:                   mbc6_rom_read(cart, int(cart.rom_bank_a), off)
  of 0x6000..0x7FFF:
    let off = idx - 0x6000
    if cart.flash_select_b: mbc6_flash_read(cart, int(cart.rom_bank_b) * 0x2000 + off)
    else:                   mbc6_rom_read(cart, int(cart.rom_bank_b), off)
  of 0xA000..0xAFFF:
    if cart.ram_enabled: cart.ram[int(cart.ram_bank_a) * 0x1000 + (idx - 0xA000)]
    else: 0xFF'u8
  of 0xB000..0xBFFF:
    if cart.ram_enabled: cart.ram[int(cart.ram_bank_b) * 0x1000 + (idx - 0xB000)]
    else: 0xFF'u8
  else: 0xFF'u8

method mbc_write*(cart: Mbc6; idx: int; val: uint8) =
  case idx
  # The register decode is by 0x400-byte block inside the first 0x4000 bytes,
  # not by the usual 0x2000-byte quarters.
  of 0x0000..0x03FF:
    let was_enabled = cart.ram_enabled
    cart.ram_enabled = val == 0x0A
    if was_enabled and not cart.ram_enabled: mbc_save(cart)
  of 0x0400..0x07FF: cart.ram_bank_a = val and 0x07
  of 0x0800..0x0BFF: cart.ram_bank_b = val and 0x07
  of 0x0C00..0x0FFF: cart.flash_enabled = (val and 1) != 0
  of 0x1000..0x1FFF:
    # Pan Docs gives a bare address ("1000 — Flash Write Enable"); nothing
    # documents a finer decode before 0x2000, so the whole block is it.
    cart.flash_write_enabled = (val and 1) != 0
  of 0x2000..0x27FF: cart.rom_bank_a = val and 0x7F
  of 0x2800..0x2FFF: cart.flash_select_a = val == 0x08   # "00 selects the ROM and 08 selects the flash"
  of 0x3000..0x37FF: cart.rom_bank_b = val and 0x7F
  of 0x3800..0x3FFF: cart.flash_select_b = val == 0x08
  of 0x4000..0x5FFF:
    if cart.flash_select_a and cart.flash_enabled:
      mbc6_flash_command(cart, int(cart.rom_bank_a) * 0x2000 + (idx - 0x4000), val)
  of 0x6000..0x7FFF:
    if cart.flash_select_b and cart.flash_enabled:
      mbc6_flash_command(cart, int(cart.rom_bank_b) * 0x2000 + (idx - 0x6000), val)
  of 0xA000..0xAFFF:
    if cart.ram_enabled:
      cart.ram_dirty = true
      cart.ram[int(cart.ram_bank_a) * 0x1000 + (idx - 0xA000)] = val
  of 0xB000..0xBFFF:
    if cart.ram_enabled:
      cart.ram_dirty = true
      cart.ram[int(cart.ram_bank_b) * 0x1000 + (idx - 0xB000)] = val
  else: discard
