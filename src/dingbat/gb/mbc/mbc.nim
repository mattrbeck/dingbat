# MBC base + factory (included by gb.nim)

type
  # MBC5+RUMBLE (cart types 0x1C-0x1E): bit 3 of the RAM-bank register drives
  # the motor, leaving only bits 0-2 for bank selection.
  Mbc5Rumble* = ref object of Mbc5
    rumble*: bool  # transient motor state; deliberately not serialized

const NintendoLogo = [
  0xCE'u8, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83,
  0x00, 0x0C, 0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E,
  0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63,
  0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E]

proc has_nintendo_logo(rom: seq[uint8]; base: int): bool =
  if base < 0 or base + NintendoLogo.len > rom.len: return false
  for i in 0 ..< NintendoLogo.len:
    if rom[base + i] != NintendoLogo[i]: return false
  true

proc is_mbc1_multicart(rom: seq[uint8]): bool =
  ## MBC1M multicarts (e.g. Mortal Kombat I&II, Bomberman Collection) are 8 Mbit
  ## carts wiring only 4 bits of the BANK1 register, with BANK2 driving ROM
  ## address lines 18-19. There is no header flag; like mooneye-gb, detect them
  ## by counting Nintendo logos at the 256 KiB game boundaries (>= 3 of 4).
  if rom.len != 0x100000: return false
  var logos = 0
  for page in 0 ..< 4:
    let base = page * 0x40000 + 0x104
    var match = true
    for i in 0 ..< NintendoLogo.len:
      if rom[base + i] != NintendoLogo[i]:
        match = false
        break
    if match: inc logos
  logos >= 3

method mbc_read*(cart: Mbc; idx: int): uint8 {.base.} = 0xFF'u8
method mbc_write*(cart: Mbc; idx: int; val: uint8) {.base.} = discard
# Frontends poll this each frame to drive controller/haptic rumble.
method mbc_rumble*(cart: Mbc): bool {.base.} = false

proc load_cartridge*(rom_path: string): Mbc =
  let raw = readFile(rom_path)
  var rom = newSeq[uint8](raw.len)
  for i in 0 ..< raw.len: rom[i] = uint8(raw[i])

  # MMM01 compilations put their real header in the last 32 KiB, where the menu
  # program lives: Pan Docs, "the correct ROM header (with Nintendo logo)
  # therefore needs to be located at offset (size - 32 KiB) + $100 in the ROM
  # rather than the usual $0000 + $100 (which contains the header of the first
  # game in the collection instead)". Dumps of the released cartridges disagree
  # about which end they store the menu at, so both orders have to be
  # recognised, and hdr_base then points at whichever header is the cartridge's
  # rather than a contained game's. rom_rotate is how far mbc/mmm01.nim has to
  # turn the file to get the menu back to the top.
  var cart_type   = rom[0x0147]
  var hdr_base    = 0
  var mmm01_rotate = 0
  if cart_type in [0x0B'u8, 0x0C, 0x0D]:
    mmm01_rotate = 0x8000
  elif rom.len > 0x8000 and rom[rom.len - 0x8000 + 0x0147] in [0x0B'u8, 0x0C, 0x0D] and
       has_nintendo_logo(rom, rom.len - 0x8000 + 0x0104):
    hdr_base  = rom.len - 0x8000
    cart_type = rom[hdr_base + 0x0147]

  let has_ram     = (cart_type in [0x02'u8, 0x03, 0x08, 0x09,
                                    0x0C, 0x0D, 0x10, 0x12, 0x13,
                                    0x1A, 0x1B, 0x1D, 0x1E, 0x20, 0x22,
                                    0xFC, 0xFD, 0xFE, 0xFF])
  let has_battery = (cart_type in [0x03'u8, 0x06, 0x09, 0x0D, 0x0F,
                                    0x10, 0x13, 0x1B, 0x1E, 0x20, 0x22,
                                    0xFC, 0xFD, 0xFE, 0xFF])

  let ram_sz = case rom[hdr_base + 0x0149]
    of 0x01: 0x0800
    of 0x02: 0x2000
    of 0x03: 0x2000 * 4
    of 0x04: 0x2000 * 16
    of 0x05: 0x2000 * 8
    else:    0

  let sav_path = rom_path[0 ..< rom_path.rfind('.')] & ".sav"

  var cart: Mbc
  case cart_type
  of 0x00, 0x08, 0x09:
    let c = MbcRom(rom: rom, ram: newSeq[uint8](ram_sz),
                   sav_path: sav_path, has_battery: has_battery)
    cart = c
  of 0x01, 0x02, 0x03:
    let actual_ram = if ram_sz == 0 and has_ram: 0x2000 else: ram_sz
    let c = Mbc1(rom: rom, ram: newSeq[uint8](actual_ram),
                 sav_path: sav_path, has_battery: has_battery,
                 reg1: 1, multicart: is_mbc1_multicart(rom))
    cart = c
  of 0x05, 0x06:
    let c = Mbc2(rom: rom, ram: newSeq[uint8](0x0200),
                 sav_path: sav_path, has_battery: has_battery,
                 rom_bank: 1)
    cart = c
  of 0x0B, 0x0C, 0x0D:
    let c = Mmm01(rom: rom, ram: newSeq[uint8](ram_sz),
                  sav_path: sav_path, has_battery: has_battery,
                  rom_rotate: mmm01_rotate)
    cart = c
  of 0x0F, 0x10, 0x11, 0x12, 0x13:
    let c = Mbc3(rom: rom, ram: newSeq[uint8](ram_sz),
                 sav_path: sav_path, has_battery: has_battery,
                 rom_bank_num: 1,
                 has_rtc: cart_type in [0x0F'u8, 0x10])
    cart = c
  of 0x19, 0x1A, 0x1B:
    let c = Mbc5(rom: rom, ram: newSeq[uint8](ram_sz),
                 sav_path: sav_path, has_battery: has_battery,
                 rom_bank_num: 1)
    cart = c
  of 0x1C, 0x1D, 0x1E:
    let c = Mbc5Rumble(rom: rom, ram: newSeq[uint8](ram_sz),
                       sav_path: sav_path, has_battery: has_battery,
                       rom_bank_num: 1)
    cart = c
  of 0x20:
    # The header's RAM-size code cannot express what MBC6 has: eight 4 KiB banks
    # (Pan Docs, "RAM Bank A 00-07"), which is 32 KiB reached through two 4 KiB
    # windows rather than the usual 8 KiB ones. The flash chip beside it powers
    # up erased, and erased flash reads all-ones.
    let c = Mbc6(rom: rom, ram: newSeq[uint8](0x8000),
                 sav_path: sav_path, has_battery: has_battery,
                 flash: newSeq[uint8](0x100000),
                 flash_hidden: newSeq[uint8](0x100))
    for i in 0 ..< c.flash.len: c.flash[i] = 0xFF
    for i in 0 ..< c.flash_hidden.len: c.flash_hidden[i] = 0xFF
    cart = c
  of 0x22:
    # The header's RAM-size byte is 0 on MBC7 carts; the save is the 256-byte
    # EEPROM. An erased EEPROM reads all-ones, and the games check for that to
    # decide whether the cartridge holds a save, so power-on has to be 0xFF and
    # not the zeroes newSeq would give.
    let c = Mbc7(rom: rom, ram: newSeq[uint8](0x100),
                 sav_path: sav_path, has_battery: has_battery,
                 x_latch: 0x8000, y_latch: 0x8000, latch_ready: true,
                 read_bits: 0xFFFF, eeprom_do: true)
    for i in 0 ..< c.ram.len: c.ram[i] = 0xFF
    cart = c
  of 0xFC:
    let c = PocketCamera(rom: rom, ram: newSeq[uint8](ram_sz),
                         sav_path: sav_path, has_battery: has_battery,
                         rom_bank_num: 1)  # "The initial mapped bank is 01"
    cart = c
  of 0xFD:
    # endrift, in the one thread that documents this part: "RAM is 32 bytes".
    # The header's RAM-size byte is 0. The clock is battery-backed too and runs
    # with the Game Boy switched off, so it needs a starting point even when no
    # .sav exists to load one from.
    let c = Tama5(rom: rom, ram: newSeq[uint8](0x20),
                  sav_path: sav_path, has_battery: has_battery)
    c.tama5_seed_clock()
    cart = c
  of 0xFE:
    # HuC3's battery backs the clock as well as the RAM, so the clock needs a
    # starting point even when there is no .sav to load one from: SameBoy powers
    # up with the counters at zero and the timestamp at the host's current
    # second, which is what makes the first minute tick land where it does.
    let c = Huc3(rom: rom, ram: newSeq[uint8](ram_sz),
                 sav_path: sav_path, has_battery: has_battery,
                 rom_bank_num: 1, last_second: gb_rtc_now())
    cart = c
  of 0xFF:
    # bank_low powers up at 1 like every other mapper's bank register, but
    # unlike them a later write of 0 is honoured and maps bank 0 twice.
    let c = Huc1(rom: rom, ram: newSeq[uint8](ram_sz),
                 sav_path: sav_path, has_battery: has_battery,
                 bank_low: 1)
    cart = c
  else:
    echo "Warning: unimplemented cartridge type 0x", toHex(cart_type, 2), ", treating as ROM"
    let c = MbcRom(rom: rom, ram: newSeq[uint8](ram_sz),
                   sav_path: sav_path, has_battery: has_battery)
    cart = c

  mbc_load(cart)
  result = cart
