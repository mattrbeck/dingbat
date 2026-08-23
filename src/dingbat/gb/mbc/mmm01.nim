# MMM01 cartridge (included by gb.nim)
#
# Written from Pan Docs "MMM01" (gbdev.io/pandocs/MMM01.html, which credits
# tauwasser's wiki: https://wiki.tauwasser.eu/view/MMM01). Cart types 0x0B-0x0D.
#
# A compilation mapper: it powers up "unmapped" with the last 32 KiB (the
# menu) over the whole 0x0000-0x7FFF region. The menu sets the extended bank
# bits to pick a game, the write-lock masks to fence it in, and Mapping
# Enable, after which the mapper is an MBC1 for that game: ROM Bank Low and
# RAM Bank Low are the MBC1 registers, and each mask's set bits refuse writes.
#
# Bank composition, from the Pan Docs addressing diagrams (cartridge ROM
# address bits; the 16 KiB bank number is bits 22-14):
#
#   22-21  ROM Bank High     (game select, 2 bits)
#   20-19  ROM Bank Mid      (game select, 2 bits)   } swapped by multiplex
#   18-14  ROM Bank Low      (the MBC1 register)     }
#
# and for RAM (8 KiB bank number is bits 16-13):
#
#   16-15  RAM Bank High     (game select, 2 bits)
#   14-13  RAM Bank Low      (the MBC1 register)     } swapped by multiplex
#
# Multiplex mode swaps ROM Bank Mid with RAM Bank Low, handing the game two more
# ROM bank bits at the cost of its RAM — Pan Docs calls it "equivalent to the
# large ROM wiring of an MBC1 cartridge". No released cartridge uses it.

proc mmm01_rom_offset(cart: Mmm01; bank: int): int =
  ## Byte offset in the ROM *file* of a 16 KiB cartridge bank.
  # The mapper finds the menu in the last 32 KiB (Pan Docs), but common dumps
  # put it first. rom_rotate is the distance between the two orders, applied
  # here rather than by shuffling the buffer so the ROM checksum and header
  # still describe the file on disk.
  var o = (bank * 0x4000) mod cart.rom.len + cart.rom_rotate
  if o >= cart.rom.len: o -= cart.rom.len
  o

proc mmm01_menu_bank(cart: Mmm01): int =
  ## First of the two 16 KiB banks the menu lives in.
  cart.rom.len div 0x4000 - 2

proc mmm01_low_bank(cart: Mmm01): int =
  ## Cartridge bank visible at 0x0000-0x3FFF while mapped.
  # Only the masked bits of ROM Bank Low reach this region, pinning it to
  # bank 0 of the selected game.
  let low = int(cart.rom_bank_low and cart.rom_bank_mask)
  let mid = if cart.multiplex:
              # Multiplexed: mode 0 takes the masked RAM Bank Low, mode 1 the
              # whole register (MBC1's "mode 1 unlocks the low region").
              if cart.mbc1_mode: int(cart.ram_bank_low)
              else: int(cart.ram_bank_low and cart.ram_bank_mask)
            else:
              int(cart.rom_bank_mid)
  low or (mid shl 5) or (int(cart.rom_bank_high) shl 7)

proc mmm01_high_bank(cart: Mmm01): int =
  ## Cartridge bank visible at 0x4000-0x7FFF while mapped.
  # Pan Docs: "if (ROM Bank Low) & ~(ROM Bank Mask) is equal to $00 ...,
  # (ROM Bank Low) | 1 is used instead". The register itself does not change.
  var low = int(cart.rom_bank_low)
  if (low and not int(cart.rom_bank_mask) and 0x1F) == 0: low = low or 1
  let mid = if cart.multiplex: int(cart.ram_bank_low)
            else: int(cart.rom_bank_mid)
  low or (mid shl 5) or (int(cart.rom_bank_high) shl 7)

proc mmm01_ram_bank(cart: Mmm01): int =
  if cart.multiplex:
    # RAM Bank Low is borrowed by the ROM path; ROM Bank Mid stands in.
    int(cart.rom_bank_mid) or (int(cart.ram_bank_high) shl 2)
  elif cart.mbc1_mode:
    int(cart.ram_bank_low) or (int(cart.ram_bank_high) shl 2)
  else:
    # Mode 0: "The unmasked bits of RAM Bank Low are treated as 0".
    int(cart.ram_bank_low and cart.ram_bank_mask) or (int(cart.ram_bank_high) shl 2)

method mbc_rom_map*(cart: Mmm01): (int, int) =
  ## Both windows move: unmapped, they are the two halves of the menu.
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
    # Unmapped, the second half of the menu. Pan Docs flags as "TO BE VERIFIED"
    # that bit 0 of ROM Bank Low may still reach this region; a fixed window is
    # implemented.
    let bank = if cart.mapped: mmm01_high_bank(cart)
               else: mmm01_menu_bank(cart) + 1
    cart.rom[mmm01_rom_offset(cart, bank) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF:
    # Pan Docs: "It is currently unknown whether RAM access is possible while
    # in unmapped mode." Nothing gates it here beyond the enable.
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
      # Pan Docs: "It is unknown if setting bit 6 to enter mapped mode will
      # honor or ignore the value simultaneously being written to bits 4-5".
      # The mask is taken first.
      if (val and 0x40) != 0: cart.mapped = true
  of 0x2000..0x3FFF:
    if not cart.mapped: cart.rom_bank_mid = (val shr 5) and 0x03
    let m = cart.rom_bank_mask
    cart.rom_bank_low = (cart.rom_bank_low and m) or ((val and 0x1F) and not m)
  of 0x4000..0x5FFF:
    let m = cart.ram_bank_mask
    cart.ram_bank_low = (cart.ram_bank_low and m) or ((val and 0x03) and not m)
    if not cart.mapped:
      # Pan Docs' heading says "Bits 1-2: RAM Bank High", but its register
      # and addressing diagrams say bits 2-3; the heading is a typo.
      cart.ram_bank_high = (val shr 2) and 0x03
      cart.rom_bank_high = (val shr 4) and 0x03
      cart.mode_locked   = (val and 0x40) != 0
  of 0x6000..0x7FFF:
    # Mode Write Lock lets the menu boot a game that would scribble here.
    if not cart.mode_locked: cart.mbc1_mode = (val and 1) != 0
    if not cart.mapped:
      # Pan Docs: "the lowest bit of ROM Bank Low is always writeable", so
      # mask bit 0 is always zero.
      cart.rom_bank_mask = ((val shr 2) and 0x0F) shl 1
      cart.multiplex     = (val and 0x40) != 0
  of 0xA000..0xBFFF:
    if cart.ram_enabled and cart.ram.len > 0:
      cart.ram_dirty = true
      cart.ram[mbc_ram_bank_offset(cart, mmm01_ram_bank(cart)) + mbc_ram_offset(cart, idx)] = val
  else: discard
