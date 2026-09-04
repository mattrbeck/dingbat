# MBC base + factory (included by gb.nim)

type
  # MBC5+RUMBLE (cart types 0x1C-0x1E): bit 3 of the RAM-bank register drives
  # the motor, leaving only bits 0-2 for bank selection.
  Mbc5Rumble* = ref object of Mbc5
    rumble*: bool  # transient motor state; deliberately not serialized

proc header_logo_ok(rom: seq[uint8]; base: int): bool =
  ## Does a cartridge header whose $0100 entry point sits at `base` carry the
  ## boot logo (Pan Docs, "The Cartridge Header", $0104-$0133)? The reference
  ## is the cart's own header at $0104, which the boot ROM has already
  ## checked, so no copy of the bitmap is kept here. Weaker than a checksum
  ## on purpose: the older build of mooneye's multicart_rom_8Mb puts only
  ## the logo in its extra quarters.
  if base < 0 or base + 0x34 > rom.len: return false
  for i in 0x04 ..< 0x34:
    if rom[base + i] != rom[0x100 + i]: return false
  true

proc is_mbc1_multicart(rom: seq[uint8]): bool =
  ## MBC1M multicarts (Pan Docs, "MBC1M"): 8 Mbit carts wiring only 4 bits of
  ## BANK1, with BANK2 on ROM address lines 18-19. There is no header flag;
  ## each 256 KiB quarter holds a complete game with its own header, so count
  ## logos at the quarter boundaries (>= 3 of 4).
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
# `mbc_read` is a method, so every instruction fetch paid a dynamic dispatch, a
# chckNilDisp and the post-call error-flag test. For every mapper here except
# MBC6 the CPU's 0x0000-0x7FFF window is nothing but two flat 16 KiB views into
# `rom`: address A below 0x4000 reads rom[lo + A], and A at or above it reads
# rom[hi + A - 0x4000]. mbc_rom_map returns those two offsets so read_byte can
# index straight into the buffer; a mapper that cannot be described that way
# returns (-1, -1) and keeps the method call.
#
# The bases are a pure function of the banking registers, and the registers only
# move on a write into 0x0000-0x7FFF. The complete set of points that can change
# the map, and where each is resynced:
#
#   1. Any cartridge write below 0x8000 -- every banking register on every
#      mapper here is written through this window. gb/memory.nim write_byte,
#      immediately after mbc_write.
#   2. Cartridge construction, including MBC1's multicart detection and MMM01's
#      rom_rotate, both of which are decided from the ROM image at load time.
#      load_cartridge.
#   3. Save-state / rollback-snapshot load, which writes the banking registers
#      back directly rather than through mbc_write. gb/savestate.nim
#      load_mbc_state.
#
# Two mappers deliberately opt out by not overriding the base method:
#   * MBC6 splits 0x4000-0x7FFF into two independent 8 KiB windows that can each
#     be ROM or flash, so there is no single `hi`.
#   * TAMA5 selects its ROM bank from registers written through 0xA000-0xBFFF,
#     which is NOT one of the resync points above; giving it a map would need a
#     sync on every cart-RAM write, which costs more than the one cartridge it
#     would speed up is worth.
# Build with -d:mbc_map_check to have every ROM read cross-checked against the
# method at runtime (tools/gbfuzz sweep, see notes).
# ---------------------------------------------------------------------------

method mbc_rom_map*(cart: Mbc): (int, int) {.base.} = (-1, -1)
  ## Byte offsets into `rom` for the 0x0000 and 0x4000 windows, or (-1, -1)
  ## when this mapper's ROM window is not two flat views.

proc mbc_sync_rom_map*(cart: Mbc) =
  ## Recompute the cache. Cheap (one virtual call) and only on the three
  ## events enumerated above, never on a read.
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
  ## 0x0000-0x3FFF. Identical index (and therefore identical bounds check) to
  ## the `cart.rom[...]` the method would have run.
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
    # HuC3's battery backs the clock as well as the RAM, so with no .sav the
    # clock starts at zero, stamped with the host's current second.
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
  # Resync point 2 of 3: MBC1's multicart detection and MMM01's rom_rotate are
  # both decided from the ROM image here, so the map is only well defined once
  # the cartridge object exists.
  mbc_sync_rom_map(cart)
  # Identity from the bytes as loaded, once. See the GBA side: hashing the
  # live buffer let a Game Genie code orphan the player's save states.
  cart.rom_identity = fnv1a(cart.rom)
  result = cart
