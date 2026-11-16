# MMM01 cartridge (included by gb.nim)
#
# Pan Docs "MMM01". Cart types 0x0B-0x0D. Powers up "unmapped" with the last
# 32 KiB (the menu) over 0x0000-0x7FFF. The menu sets the game's high bank
# bits, write-lock masks and Mapping Enable; then it acts as an MBC1 (Bank Low
# registers), and set mask bits block writes.
#
# ROM address bits (16 KiB bank = bits 22-14):
#
#   22-21  ROM Bank High     (game select, 2 bits)
#   20-19  ROM Bank Mid      (game select, 2 bits)   } swapped by multiplex
#   18-14  ROM Bank Low      (the MBC1 register)     }
#
# RAM (8 KiB bank = bits 16-13):
#
#   16-15  RAM Bank High     (game select, 2 bits)
#   14-13  RAM Bank Low      (the MBC1 register)     } swapped by multiplex
#
# Multiplex swaps ROM Bank Mid with RAM Bank Low (like MBC1's large-ROM
# wiring). No released cartridge uses it.

proc mmm01_rom_offset(cart: Mmm01; bank: int): int =
  ## Byte offset in the ROM *file* of a 16 KiB cartridge bank.
  # Some dumps put the menu first; rom_rotate is applied here, not by
  # shuffling the buffer, so checksum and header match the file on disk.
  var o = (bank * 0x4000) mod cart.rom.len + cart.rom_rotate
  if o >= cart.rom.len: o -= cart.rom.len
  o

proc mmm01_menu_bank(cart: Mmm01): int =
  ## First of the two 16 KiB banks the menu lives in.
  cart.rom.len div 0x4000 - 2

proc mmm01_low_bank(cart: Mmm01): int =
  ## Cartridge bank visible at 0x0000-0x3FFF while mapped.
  # Only masked bits of ROM Bank Low reach here: bank 0 of the game.
  let low = int(cart.rom_bank_low and cart.rom_bank_mask)
  let mid = if cart.multiplex:
              # Mode 0: masked RAM Bank Low; mode 1: all of it (as MBC1).
              if cart.mbc1_mode: int(cart.ram_bank_low)
              else: int(cart.ram_bank_low and cart.ram_bank_mask)
            else:
              int(cart.rom_bank_mid)
  low or (mid shl 5) or (int(cart.rom_bank_high) shl 7)

proc mmm01_high_bank(cart: Mmm01): int =
  ## Cartridge bank visible at 0x4000-0x7FFF while mapped.
  # Unmasked bits all zero -> | 1 (Pan Docs); the register is unchanged.
  var low = int(cart.rom_bank_low)
  if (low and not int(cart.rom_bank_mask) and 0x1F) == 0: low = low or 1
  let mid = if cart.multiplex: int(cart.ram_bank_low)
            else: int(cart.rom_bank_mid)
  low or (mid shl 5) or (int(cart.rom_bank_high) shl 7)

proc mmm01_ram_bank(cart: Mmm01): int =
  if cart.multiplex:
    # ROM Bank Mid stands in for the borrowed RAM Bank Low.
    int(cart.rom_bank_mid) or (int(cart.ram_bank_high) shl 2)
  elif cart.mbc1_mode:
    int(cart.ram_bank_low) or (int(cart.ram_bank_high) shl 2)
  else:
    # Mode 0: unmasked bits of RAM Bank Low read as 0.
    int(cart.ram_bank_low and cart.ram_bank_mask) or (int(cart.ram_bank_high) shl 2)

method mbc_rom_map*(cart: Mmm01): (int, int) =
  ## Unmapped: the two halves of the menu.
  (mmm01_rom_offset(cart, (if cart.mapped: mmm01_low_bank(cart)
                           else: mmm01_menu_bank(cart))),
   mmm01_rom_offset(cart, (if cart.mapped: mmm01_high_bank(cart)
                           else: mmm01_menu_bank(cart) + 1)))

method mbc_read*(cart: Mmm01; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF:
    let bank = if cart.mapped: mmm01_low_bank(cart) else: mmm01_menu_bank(cart)
    cart.rom[mmm01_rom_offset(cart, bank) + idx]
  of 0x4000..0x7FFF:
    # Unmapped: fixed second half of the menu. Pan Docs: bit 0 of ROM Bank
    # Low may reach here ("TO BE VERIFIED").
    let bank = if cart.mapped: mmm01_high_bank(cart)
               else: mmm01_menu_bank(cart) + 1
    cart.rom[mmm01_rom_offset(cart, bank) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF:
    # RAM access while unmapped is unknown (Pan Docs); only the enable gates.
    if cart.ram_enabled and cart.ram.len > 0:
      cart.ram[mbc_ram_bank_offset(cart, mmm01_ram_bank(cart)) + mbc_ram_offset(cart, idx)]
    else: 0xFF'u8
  else: 0xFF'u8

method mbc_write*(cart: Mmm01; idx: int; val: uint8) =
  case idx
  of 0x0000..0x1FFF:
    let was_enabled = cart.ram_enabled
    cart.ram_enabled = (val and 0x0F) == 0x0A
    if was_enabled and not cart.ram_enabled: mbc_save(cart)
    if not cart.mapped:
      cart.ram_bank_mask = (val shr 4) and 0x03
      # Unknown whether the mapping write honours bits 4-5 (Pan Docs); the
      # mask is taken first.
      if (val and 0x40) != 0: cart.mapped = true
  of 0x2000..0x3FFF:
    if not cart.mapped: cart.rom_bank_mid = (val shr 5) and 0x03
    let m = cart.rom_bank_mask
    cart.rom_bank_low = (cart.rom_bank_low and m) or ((val and 0x1F) and not m)
  of 0x4000..0x5FFF:
    let m = cart.ram_bank_mask
    cart.ram_bank_low = (cart.ram_bank_low and m) or ((val and 0x03) and not m)
    if not cart.mapped:
      # Bits 2-3: Pan Docs' heading says 1-2, its diagrams 2-3 (typo).
      cart.ram_bank_high = (val shr 2) and 0x03
      cart.rom_bank_high = (val shr 4) and 0x03
      cart.mode_locked   = (val and 0x40) != 0
  of 0x6000..0x7FFF:
    # Mode Write Lock lets the menu boot a game that would scribble here.
    if not cart.mode_locked: cart.mbc1_mode = (val and 1) != 0
    if not cart.mapped:
      # Bit 0 of ROM Bank Low is always writable (Pan Docs).
      cart.rom_bank_mask = ((val shr 2) and 0x0F) shl 1
      cart.multiplex     = (val and 0x40) != 0
  of 0xA000..0xBFFF:
    if cart.ram_enabled and cart.ram.len > 0:
      cart.ram_dirty = true
      cart.ram[mbc_ram_bank_offset(cart, mmm01_ram_bank(cart)) + mbc_ram_offset(cart, idx)] = val
  else: discard
