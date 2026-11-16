# MBC base + factory (included by gb.nim)

type
  # MBC5+RUMBLE (cart types 0x1C-0x1E): bit 3 of the RAM-bank register drives
  # the motor, leaving only bits 0-2 for bank selection.
  Mbc5Rumble* = ref object of Mbc5
    rumble*: bool  # transient motor state; deliberately not serialized

proc header_logo_ok(rom: seq[uint8]; base: int): bool =
  ## Does the header with its $0100 entry at `base` carry the boot logo
  ## ($0104-$0133), compared against the cart's own header? Weaker than a
  ## checksum on purpose: an older mooneye multicart_rom_8Mb has only the logo
  ## in its extra quarters.
  if base < 0 or base + 0x34 > rom.len: return false
  for i in 0x04 ..< 0x34:
    if rom[base + i] != rom[0x100 + i]: return false
  true

proc is_mbc1_multicart(rom: seq[uint8]): bool =
  ## MBC1M (Pan Docs): 8 Mbit, 4 bits of BANK1, BANK2 on address lines 18-19.
  ## No header flag, so count logos at the 256 KiB quarters (>= 3 of 4).
  if rom.len != 0x100000: return false
  var headers = 0
  for page in 0 ..< 4:
    if header_logo_ok(rom, page * 0x40000 + 0x100): inc headers
  headers >= 3

method mbc_read*(cart: Mbc; idx: int): uint8 {.base.} = 0xFF'u8
method mbc_write*(cart: Mbc; idx: int; val: uint8) {.base.} = discard

# ---------------------------------------------------------------------------
# Flat-ROM window cache
#
# `mbc_read` is a method (dynamic dispatch on every fetch). Most mappers' ROM
# window is two flat 16 KiB views: A < 0x4000 reads rom[lo + A], else
# rom[hi + A - 0x4000]. mbc_rom_map returns (lo, hi) so read_byte can index
# directly; (-1, -1) keeps the method call.
#
# The map changes only at these resync points:
#   1. A cartridge write below 0x8000: gb/memory.nim write_byte, after mbc_write.
#   2. Cartridge construction (MBC1 multicart, MMM01 rom_rotate): load_cartridge.
#   3. State / rollback load, which bypasses mbc_write: gb/savestate.nim
#      load_mbc_state.
#
# Opted out: MBC6 (two independent 8 KiB ROM/flash windows, no single `hi`)
# and TAMA5 (banks via 0xA000-0xBFFF writes, not a resync point; syncing on
# every cart-RAM write costs more than it saves).
# -d:mbc_map_check (off by default) cross-checks every ROM read against the
# method.
# ---------------------------------------------------------------------------

method mbc_rom_map*(cart: Mbc): (int, int) {.base.} = (-1, -1)
  ## Byte offsets into `rom` for the 0x0000 and 0x4000 windows, or (-1, -1)
  ## when this mapper's ROM window is not two flat views.

proc mbc_sync_rom_map*(cart: Mbc) =
  ## Recompute the cache at the three resync points above, never on a read.
  let (lo, hi) = mbc_rom_map(cart)
  cart.rom_lo_base = lo
  cart.rom_hi_base = hi
  cart.flat_rom = lo >= 0 and hi >= 0

when defined(mbc_map_check):
  proc mbc_map_fail(idx, got, want: int) {.noinline.} =
    echo "mbc_map_check: ROM read 0x", toHex(uint16(idx), 4),
         " fast=0x", toHex(uint8(got), 2), " method=0x", toHex(uint8(want), 2)
    quit(3)

proc mbc_read_rom_lo*(cart: Mbc; idx: int): uint8 {.inline.} =
  ## 0x0000-0x3FFF. Same index (and bounds check) as the method.
  when defined(mbc_map_check):
    let want = mbc_read(cart, idx)
    if cart.flat_rom:
      let got = cart.rom[cart.rom_lo_base + idx]
      if got != want: mbc_map_fail(idx, int(got), int(want))
    return want
  else:
    if cart.flat_rom: cart.rom[cart.rom_lo_base + idx]
    else: mbc_read(cart, idx)

proc mbc_read_rom_hi*(cart: Mbc; idx: int): uint8 {.inline.} =
  ## 0x4000-0x7FFF.
  when defined(mbc_map_check):
    let want = mbc_read(cart, idx)
    if cart.flat_rom:
      let got = cart.rom[cart.rom_hi_base + (idx - 0x4000)]
      if got != want: mbc_map_fail(idx, int(got), int(want))
    return want
  else:
    if cart.flat_rom: cart.rom[cart.rom_hi_base + (idx - 0x4000)]
    else: mbc_read(cart, idx)
# Frontends poll this each frame to drive controller/haptic rumble.
method mbc_rumble*(cart: Mbc): bool {.base.} = false

proc load_cartridge*(rom_path: string): Mbc =
  let raw = readFile(rom_path)
  # ROMs are a power of two >= 32 KiB (Pan Docs $0148). Short or odd-sized
  # files are padded with $FF (open bus): a jump past the end meets RST $38,
  # not an IndexDefect.
  var size = 0x8000
  while size < raw.len: size = size shl 1
  var rom = newSeq[uint8](size)
  for i in 0 ..< raw.len: rom[i] = uint8(raw[i])
  for i in raw.len ..< size: rom[i] = 0xFF

  # MMM01: the real header sits with the menu in the last 32 KiB (Pan Docs).
  # Dumps disagree on which end holds the menu, so both orders are recognised;
  # hdr_base points at the cartridge's header, and rom_rotate is how far
  # mbc/mmm01.nim turns the file to put the menu at the top.
  var cart_type   = rom[0x0147]
  var hdr_base    = 0
  var mmm01_rotate = 0
  if cart_type in [0x0B'u8, 0x0C, 0x0D]:
    mmm01_rotate = 0x8000
  elif rom.len > 0x8000 and rom[rom.len - 0x8000 + 0x0147] in [0x0B'u8, 0x0C, 0x0D] and
       header_logo_ok(rom, rom.len - 0x8000 + 0x0100):
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

  # changeFileExt: "up to the last dot" mis-names extensionless paths.
  let sav_path = rom_path.changeFileExt(".sav")

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
    # MBC6 RAM: eight 4 KiB banks (Pan Docs), which the header cannot express.
    # Flash powers up erased (all ones).
    let c = Mbc6(rom: rom, ram: newSeq[uint8](0x8000),
                 sav_path: sav_path, has_battery: has_battery,
                 flash: newSeq[uint8](0x100000),
                 flash_hidden: newSeq[uint8](0x100))
    for i in 0 ..< c.flash.len: c.flash[i] = 0xFF
    for i in 0 ..< c.flash_hidden.len: c.flash_hidden[i] = 0xFF
    cart = c
  of 0x22:
    # MBC7: header RAM size 0; the save is the 256-byte EEPROM. Erased reads
    # all ones and the games test for it, so power-on must be 0xFF.
    let c = Mbc7(rom: rom, ram: newSeq[uint8](0x100),
                 sav_path: sav_path, has_battery: has_battery,
                 x_sample: 0x8000, y_sample: 0x8000, latch_armed: true,
                 data_reg: 0xFFFF, pin_do: true)
    for i in 0 ..< c.ram.len: c.ram[i] = 0xFF
    cart = c
  of 0xFC:
    let c = PocketCamera(rom: rom, ram: newSeq[uint8](ram_sz),
                         sav_path: sav_path, has_battery: has_battery,
                         rom_bank_num: 1)  # "The initial mapped bank is 01"
    cart = c
  of 0xFD:
    # "RAM is 32 bytes" (endrift's TAMA5 notes); header RAM size is 0. The
    # battery-backed clock needs a start even with no .sav.
    let c = Tama5(rom: rom, ram: newSeq[uint8](0x20),
                  sav_path: sav_path, has_battery: has_battery)
    c.tama5_seed_clock()
    cart = c
  of 0xFE:
    # HuC3 clock: with no .sav it starts at zero, stamped with host time.
    let c = Huc3(rom: rom, ram: newSeq[uint8](ram_sz),
                 sav_path: sav_path, has_battery: has_battery,
                 rom_bank_num: 1, last_second: gb_rtc_now())
    cart = c
  of 0xFF:
    # bank_low powers up at 1; a later write of 0 maps bank 0 twice.
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
  # Resync point 2 of 3.
  mbc_sync_rom_map(cart)
  # Identity from the file's bytes without padding, so states saved before
  # padding existed still match; hashed once, since hashing the live buffer
  # lets a cheat code orphan save states.
  cart.rom_identity = fnv1a(cart.rom.toOpenArray(0, raw.len - 1))
  cart.rom_file_size = raw.len
  result = cart
