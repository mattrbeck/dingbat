# MMM01 cartridge (included by gb.nim)
#
# Written from Pan Docs "MMM01" (gbdev.io/pandocs/MMM01.html, which credits
# tauwasser's wiki: https://wiki.tauwasser.eu/view/MMM01). Cart types 0x0B-0x0D.
#
# MMM01 is a compilation mapper. It powers up "unmapped", with the last 32 KiB
# of the cartridge — a menu program — hard-wired over the whole 0x0000-0x7FFF
# region no matter what the bank registers say. The menu writes the extended
# bits of the MMM01 registers to choose a game, to declare how large that game
# is, and finally to set Mapping Enable, at which point the extended bits become
# read-only and the mapper *is* an MBC1 for the game that was picked.
#
# The trick that makes one chip serve both roles is a pair of write-lock masks.
# ROM Bank Low and RAM Bank Low are the ordinary MBC1 bank registers, but each
# has a mask register whose set bits refuse writes. The menu parks the game's
# base address in the masked bits, locks them, and everything the game does
# afterwards moves only the bits below — so a 64 KiB game gets a 4-bank window
# wherever the menu put it, and cannot reach its neighbours.
#
# Bank composition, straight off the Pan Docs addressing diagrams (bit numbers
# are cartridge ROM address bits, so the 16 KiB bank number is bits 22-14):
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
  # Dumps disagree about where the menu goes. The mapper always finds it in the
  # last 32 KiB (Pan Docs: "the correct ROM header ... needs to be located at
  # offset (size - 32 KiB) + $100"), but the common dumps of the released carts
  # — Taito Variety Pack included — put it first instead, so the header a dumper
  # reads is the menu's. rom_rotate is the distance between the two orders; it
  # is applied here rather than by shuffling the buffer so that the ROM
  # checksum, the header the frontend shows and the save-state ROM length all
  # still describe the file on disk.
  var o = (bank * 0x4000) mod cart.rom.len + cart.rom_rotate
  if o >= cart.rom.len: o -= cart.rom.len
  o

proc mmm01_menu_bank(cart: Mmm01): int =
  ## First of the two 16 KiB banks the menu lives in.
  cart.rom.len div 0x4000 - 2

proc mmm01_low_bank(cart: Mmm01): int =
  ## Cartridge bank visible at 0x0000-0x3FFF while mapped.
  # Only the *masked* bits of ROM Bank Low reach this region: the unmasked ones
  # are the game's own, and zeroing them is what pins this region to bank 0 of
  # whichever game the menu selected.
  let low = int(cart.rom_bank_low and cart.rom_bank_mask)
  let mid = if cart.multiplex:
              # Multiplexed, mode 0 takes the masked RAM Bank Low and mode 1 the
              # whole register — the same "mode 1 unlocks the low region"
              # relationship MBC1 has, moved onto the swapped-in register.
              if cart.mbc1_mode: int(cart.ram_bank_low)
              else: int(cart.ram_bank_low and cart.ram_bank_mask)
            else:
              int(cart.rom_bank_mid)
  low or (mid shl 5) or (int(cart.rom_bank_high) shl 7)

proc mmm01_high_bank(cart: Mmm01): int =
  ## Cartridge bank visible at 0x4000-0x7FFF while mapped.
  # Pan Docs: "if (ROM Bank Low) & ~(ROM Bank Mask) is equal to $00 (indicating
  # bank $00 within the game ROM), (ROM Bank Low) | 1 is used instead". Note the
  # test is on the *unmasked* bits only, and that the register itself does not
  # change — moving the mask later can undo the remap.
  var low = int(cart.rom_bank_low)
  if (low and not int(cart.rom_bank_mask) and 0x1F) == 0: low = low or 1
  let mid = if cart.multiplex: int(cart.ram_bank_low)
            else: int(cart.rom_bank_mid)
  low or (mid shl 5) or (int(cart.rom_bank_high) shl 7)

proc mmm01_ram_bank(cart: Mmm01): int =
  if cart.multiplex:
    # RAM Bank Low has been borrowed by the ROM path, so ROM Bank Mid stands in
    # here and the game has a single fixed 8 KiB bank.
    int(cart.rom_bank_mid) or (int(cart.ram_bank_high) shl 2)
  elif cart.mbc1_mode:
    int(cart.ram_bank_low) or (int(cart.ram_bank_high) shl 2)
  else:
    # Mode 0: "The unmasked bits of RAM Bank Low are treated as 0", i.e. the
    # game is locked to its own RAM bank 0 while its game-select bits survive.
    int(cart.ram_bank_low and cart.ram_bank_mask) or (int(cart.ram_bank_high) shl 2)

method mbc_read*(cart: Mmm01; idx: int): uint8 =
  case idx
  of 0x0000..0x3FFF:
    let bank = if cart.mapped: mmm01_low_bank(cart) else: mmm01_menu_bank(cart)
    cart.rom[mmm01_rom_offset(cart, bank) + idx]
  of 0x4000..0x7FFF:
    # Unmapped, this is the second half of the menu. Pan Docs flags as "TO BE
    # VERIFIED" a suspicion that bit 0 of ROM Bank Low still reaches this region
    # even when unmapped, which would make the menu's own second half flicker
    # between two banks while it sets the game-select bits. Nothing attests it,
    # so the documented behaviour — a fixed window — is what is implemented.
    let bank = if cart.mapped: mmm01_high_bank(cart)
               else: mmm01_menu_bank(cart) + 1
    cart.rom[mmm01_rom_offset(cart, bank) + mbc_rom_offset(idx)]
  of 0xA000..0xBFFF:
    # Pan Docs: "It is currently unknown whether RAM access is possible while in
    # unmapped mode." Nothing gates it here beyond the enable, since the only
    # MMM01 cartridge with RAM at all is a mapped-mode game.
    if cart.ram_enabled and cart.ram.len > 0:
      cart.ram[mbc_ram_bank_offset(cart, mmm01_ram_bank(cart)) + mbc_ram_offset(idx)]
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
      # honor or ignore the value simultaneously being written to bits 4-5". The
      # released cartridge writes the same mask twice, so either answer boots
      # it; taking the mask first is the reading that needs no extra hardware.
      if (val and 0x40) != 0: cart.mapped = true
  of 0x2000..0x3FFF:
    if not cart.mapped: cart.rom_bank_mid = (val shr 5) and 0x03
    let m = cart.rom_bank_mask
    cart.rom_bank_low = (cart.rom_bank_low and m) or ((val and 0x1F) and not m)
  of 0x4000..0x5FFF:
    let m = cart.ram_bank_mask
    cart.ram_bank_low = (cart.ram_bank_low and m) or ((val and 0x03) and not m)
    if not cart.mapped:
      # The heading over this field in Pan Docs reads "Bits 1-2: RAM Bank High",
      # but its own register diagram, the addressing diagram it feeds (RAM
      # address bits 16-15, two places above RAM Bank Low) and the 4-bit total
      # RAM bank width all say bits 2-3. The heading is a typo.
      cart.ram_bank_high = (val shr 2) and 0x03
      cart.rom_bank_high = (val shr 4) and 0x03
      cart.mode_locked   = (val and 0x40) != 0
  of 0x6000..0x7FFF:
    # MBC1 Mode Write Lock exists so the menu can boot a game written for a
    # mapper that has no mode register and would scribble on this address.
    if not cart.mode_locked: cart.mbc1_mode = (val and 1) != 0
    if not cart.mapped:
      # Five mask bits, but "the value written to the lowest bit of the mask is
      # ignored, and treated as always zero. As a result, the lowest bit of ROM
      # Bank Low is always writeable" — so the register holds mask bits 4-1 and
      # the missing bit 0 is supplied here.
      cart.rom_bank_mask = ((val shr 2) and 0x0F) shl 1
      cart.multiplex     = (val and 0x40) != 0
  of 0xA000..0xBFFF:
    if cart.ram_enabled and cart.ram.len > 0:
      cart.ram_dirty = true
      cart.ram[mbc_ram_bank_offset(cart, mmm01_ram_bank(cart)) + mbc_ram_offset(idx)] = val
  else: discard
