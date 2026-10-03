## The GBA slot (slot 2) in DS mode: what sits in it and what its two
## regions read and write. GBATEK "DS Memory Control - Cartridges and Main
## RAM" (EXMEMCNT, open bus), "DS Cartridge GBA Slot", "DS Cart Rumble Pak",
## "DS Cart Expansion RAM". docs/nds/slot2.md is the write-up.
##
##   0x08000000-0x09FFFFFF  ROM region: 16-bit bus, address/data on AD0-15
##   0x0A000000-0x0AFFFFFF  SRAM region: 8-bit bus (/CS2), every 64 KB
##
## Which CPU owns the slot (EXMEMCNT.7) and the access times are bus-side
## (nds.nim, timing.nim); this module is the device side. Reads that no
## device drives are open bus: ROM halfwords read address/2 (the address the
## DS put on AD0-15 stays on the lines), garbage ORed in at the 10-cycle
## first-access time and High-Z FFFFh at 18 cycles; SRAM bytes read FFh.
##
## Devices:
## - GBA cartridge: the ROM image at 0x08000000, its backup chip as a GBA
##   sees it but moved from 0x0E000000 to 0x0A000000 (SRAM, FLASH; the chip
##   type comes from the GBA core's ROM-string scan, gba/storage_chip.nim)
##   or, for EEPROM carts, the serial chip in the top of the ROM region
##   (0x09000000+ for ROMs up to 16 MB, 0x09FFFF00+ for 32 MB), and the GPIO
##   port at 0x080000C4 (the rumble motor on bit 3; no RTC or sensors).
## - Rumble Pak (NTR-008 / USG-006): no ROM; AD1 is pulled low on reads, so
##   ROM halfwords read (address/2) AND FFFDh, which is how games detect it;
##   a write latches AD1, and each change of the latch kicks the actuator.
## - Memory Expansion Pak (NTR-011 / USG-007): 8 MB of RAM at 0x09000000,
##   STRH 1 to 0x08240000 unlocks it, 0 locks it (GBATEK). Locked, the RAM
##   reads FFFFh and ignores writes; it starts unlocked; byte stores do
##   nothing; the rest of the ROM region reads FFFFh except an ID in header
##   bytes B0h-BFh. GBATEK leaves all of that open: it is what the reference
##   runs show (docs/oracles.md, NDS core), and GBATEK's detection (a write
##   that sticks only while unlocked) works on it.

import ../../gba/storage_chip

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: on.}

type
  Slot2Kind* = enum
    s2Empty, s2GbaCart, s2RumblePak, s2ExpansionPak

  Slot2* = ref object
    kind*: Slot2Kind
    rom*: seq[uint8]            ## GBA cart ROM image (as loaded)
    save_type*: StorageType     ## GBA cart backup chip (stNone without one)
    save*: seq[uint8]           ## its contents (SRAM / FLASH / EEPROM bytes)
    dirty*: bool                ## save written since the frontend last took it
    has_rtc*: bool              ## the ROM links the RTC library (not modelled)
    flash_state: set[FlashStateFlag]
    flash_bank: uint8
    ee_in: array[81, uint8]     ## EEPROM: bits written since the last read
    ee_bits: int
    ee_sized: bool             ## EEPROM: size fixed by a first command
    ee_out: uint64              ## EEPROM: bits a read command left to read
    ee_out_left: int            ## 68 after a read command (4 dummy + 64)
    gpio_data, gpio_dir, gpio_ctl: uint8
    rumble_latch*: bool         ## Rumble Pak: the AD1 value last written
    rumble_edges: int           ## latch changes this frame
    rumble_last*: int           ## latch changes in the last whole frame
    exp_ram*: seq[uint8]        ## Expansion Pak: 8 MB
    exp_unlocked*: bool

const
  EXP_HEADER: array[8, uint16] = [  ## halfwords at 0x080000B0-BF (reference runs)
    0xFFFF'u16, 0x0000, 0x2400, 0x2424, 0xFFFF, 0xFFFF, 0xFFFF, 0x7FFF]
  EXP_RAM_BASE = 0x0100_0000'u32  ## offset in the ROM region (0x09000000)
  EXP_RAM_SIZE = 8 * 1024 * 1024
  EXP_LOCK = 0x0024_0000'u32      ## 0x08240000
  EEPROM_READ_BITS = 68           ## GBATEK "GBA Cart Backup EEPROM"

proc new_slot2*(): Slot2 = Slot2(kind: s2Empty, save_type: stNone)

proc eject*(s: Slot2) =
  s.kind = s2Empty
  s.rom = @[]
  s.save = @[]
  s.save_type = stNone
  s.exp_ram = @[]
  s.dirty = false
  s.rumble_latch = false
  s.rumble_edges = 0
  s.rumble_last = 0

proc insert_gba*(s: Slot2; rom: seq[uint8]; save: seq[uint8] = @[]) =
  ## A GBA cartridge: `save` (a GBA emulator's .sav, chip bytes first) is
  ## copied over the erased chip; its length does not pick the chip.
  s.eject()
  s.kind = s2GbaCart
  s.rom = rom
  var content = newString(rom.len)
  if rom.len > 0: copyMem(addr content[0], unsafeAddr rom[0], rom.len)
  s.save_type = find_storage_type(content)
  s.has_rtc = rom_has_rtc(content)
  let size = case s.save_type
    of stEEPROM:
      # 4 Kbit or 64 Kbit: the chip answers either address width (below);
      # a 512-byte save file says which the game used
      if save.len == 0x200: 0x200 else: 0x2000
    else: storage_bytes(s.save_type)
  s.save = newSeq[uint8](size)
  for b in s.save.mitems: b = 0xFF
  for i in 0 ..< min(size, save.len): s.save[i] = save[i]
  s.flash_state = {fsReady}
  s.flash_bank = 0
  s.ee_bits = 0
  s.ee_sized = false
  s.ee_out_left = 0
  s.gpio_data = 0; s.gpio_dir = 0; s.gpio_ctl = 0

proc insert_rumble_pak*(s: Slot2) =
  s.eject()
  s.kind = s2RumblePak

proc insert_expansion_pak*(s: Slot2) =
  s.eject()
  s.kind = s2ExpansionPak
  s.exp_ram = newSeq[uint8](EXP_RAM_SIZE)
  for b in s.exp_ram.mitems: b = 0xFF     # Assumed (the reference's RAM reads FFh)
  s.exp_unlocked = true

# ---------------------------------------------------------------------------
# Open bus

proc open_bus16*(a: uint32; rom_n: int): uint32 {.inline.} =
  ## An undriven ROM halfword (GBATEK "GBA Slot"): address/2, with garbage
  ## ORed in at the 10-cycle first access time (GBATEK: "Addr/2 OR FE08h (or
  ## similar garbage)"; FE08h is taken as the value) and High-Z FFFFh at 18.
  ## 6 and 8 cycles return the address alone.
  case rom_n
  of 10: ((a shr 1) and 0xFFFF) or 0xFE08
  of 18: 0xFFFF
  else: (a shr 1) and 0xFFFF

# ---------------------------------------------------------------------------
# GBA cartridge EEPROM (GBATEK "GBA Cart Backup EEPROM"): a serial chip on
# bit 0, driven by DMA. A command is "11" (read) or "10" (write), the
# address (6 bits for 4 Kbit, 14 for 64 Kbit), for writes 64 data bits, then
# a 0 bit. Reads return 4 dummy bits then 64 data bits, else 1 (ready).
# The chip size is known from the command's length when the first read
# after it arrives: 9 / 17 bits = read setup, 73 / 81 = write.

proc eeprom_at(s: Slot2; off: uint32): bool {.inline.} =
  s.save_type == stEEPROM and
    (if s.rom.len > 0x100_0000: off >= 0x01FF_FF00'u32 else: off >= 0x0100_0000'u32)

proc eeprom_command(s: Slot2) =
  ## The bits written since the last read form a whole command.
  let n = s.ee_bits
  s.ee_bits = 0
  proc bits(s: Slot2; first, count: int): uint64 =
    for i in first ..< first + count: result = (result shl 1) or uint64(s.ee_in[i])
  if n in [9, 17, 73, 81] and not s.ee_sized:
    # the first command's address width sizes the chip (bytes kept)
    let size = if n == 9 or n == 73: 0x200 else: 0x2000
    let old = s.save.len
    s.save.setLen(size)
    for i in old ..< size: s.save[i] = 0xFF
    s.ee_sized = true
  case n
  of 9, 17:     # read setup: 11, address, 0
    let abits = n - 3
    if s.bits(0, 2) != 3: return
    let base = (int(s.bits(2, abits)) * 8) mod s.save.len
    var d = 0'u64
    for i in 0..7: d = (d shl 8) or uint64(s.save[base + i])
    s.ee_out = d
    s.ee_out_left = EEPROM_READ_BITS
  of 73, 81:    # write: 10, address, 64 data bits, 0
    let abits = n - 67
    if s.bits(0, 2) != 2: return
    let base = (int(s.bits(2, abits)) * 8) mod s.save.len
    let d = s.bits(2 + abits, 64)
    for i in 0..7: s.save[base + i] = uint8(d shr (56 - 8 * i))
    s.dirty = true
  else: discard

proc eeprom_read(s: Slot2): uint32 =
  if s.ee_bits > 0: s.eeprom_command()
  if s.ee_out_left == 0: return 1        # ready (writes finish at once: Assumed)
  dec s.ee_out_left
  if s.ee_out_left >= 64: return 0       # the 4 dummy bits
  uint32((s.ee_out shr s.ee_out_left) and 1)

proc eeprom_write(s: Slot2; v: uint32) =
  if s.ee_out_left > 0: s.ee_out_left = 0  # a new command abandons a read
  if s.ee_bits < s.ee_in.len: s.ee_in[s.ee_bits] = uint8(v and 1)
  inc s.ee_bits

# ---------------------------------------------------------------------------
# ROM region (16-bit)

proc rom_read16*(s: Slot2; a: uint32; rom_n: int): uint32 =
  ## The halfword at `a` (0x08000000-0x09FFFFFF), seen by the owning CPU.
  let off = a and 0x01FF_FFFE'u32
  case s.kind
  of s2Empty: open_bus16(a, rom_n)
  of s2GbaCart:
    if s.eeprom_at(off): return s.eeprom_read()
    if off >= 0xC4 and off <= 0xC8 and (s.gpio_ctl and 1) != 0:
      # GPIO readable (GBATEK "GBA Cart I/O Port (GPIO)"): output pins read
      # back what was written; no input device is modelled (reads 0)
      return case off
        of 0xC4: uint32(s.gpio_data and s.gpio_dir and 0xF)
        of 0xC6: uint32(s.gpio_dir and 0xF)
        else: uint32(s.gpio_ctl and 1)
    if int(off) + 1 < s.rom.len:
      uint32(s.rom[off]) or (uint32(s.rom[off + 1]) shl 8)
    else: open_bus16(a, rom_n)     # past the ROM: Assumed as an empty slot
  of s2RumblePak: open_bus16(a, rom_n) and 0xFFFD
  of s2ExpansionPak:
    if off >= EXP_RAM_BASE and off < EXP_RAM_BASE + EXP_RAM_SIZE:
      if not s.exp_unlocked: return 0xFFFF
      let i = int(off - EXP_RAM_BASE)
      uint32(s.exp_ram[i]) or (uint32(s.exp_ram[i + 1]) shl 8)
    elif off >= 0xB0 and off < 0xC0: uint32(EXP_HEADER[(off - 0xB0) shr 1])
    else: 0xFFFF

proc rom_write*(s: Slot2; a: uint32; v: uint32; width: int) =
  ## A write of `width` bits (32-bit writes arrive as two halfwords). On the
  ## 16-bit bus a byte store drives its byte on both halves (Assumed, as
  ## the GBA's 8-bit SRAM bus does).
  let off = a and 0x01FF_FFFF'u32
  let h = if width == 8: (v and 0xFF) * 0x0101 else: v and 0xFFFF
  case s.kind
  of s2Empty: discard
  of s2GbaCart:
    if s.eeprom_at(off): s.eeprom_write(h)
    elif off >= 0xC4 and off <= 0xC9:
      case off and not 1'u32
      of 0xC4: s.gpio_data = uint8(h and 0xF)
      of 0xC6: s.gpio_dir = uint8(h and 0xF)
      else: s.gpio_ctl = uint8(h and 1)
  of s2RumblePak:
    let latch = (h and 2) != 0
    if latch != s.rumble_latch:
      s.rumble_latch = latch
      inc s.rumble_edges
  of s2ExpansionPak:
    if width == 8: return     # no byte lane selects on the bus (reference runs)
    if (off and not 1'u32) == EXP_LOCK:
      s.exp_unlocked = h == 1
    elif s.exp_unlocked and off >= EXP_RAM_BASE and off < EXP_RAM_BASE + EXP_RAM_SIZE:
      let j = int(off - EXP_RAM_BASE) and not 1
      s.exp_ram[j] = uint8(h); s.exp_ram[j + 1] = uint8(h shr 8)

# ---------------------------------------------------------------------------
# SRAM region (8-bit, /CS2)

proc ram_read8*(s: Slot2; a: uint32): uint32 =
  if s.kind != s2GbaCart: return 0xFF
  let off = a and 0xFFFF'u32
  case s.save_type
  of stSRAM: uint32(s.save[off and 0x7FFF])
  of stFLASH, stFLASH512, stFLASH1M:
    uint32(flash_read(s.save, s.flash_state, s.flash_bank, flash_id(s.save_type), off))
  else: 0xFF   # EEPROM or no chip: nothing on /CS2

proc ram_write8*(s: Slot2; a: uint32; v: uint8) =
  if s.kind != s2GbaCart: return
  let off = a and 0xFFFF'u32
  case s.save_type
  of stSRAM:
    s.save[off and 0x7FFF] = v
    s.dirty = true
  of stFLASH, stFLASH512, stFLASH1M:
    if flash_write(s.save, s.flash_state, s.flash_bank, s.save_type, off, v):
      s.dirty = true
  else: discard

# ---------------------------------------------------------------------------
# Rumble

proc end_frame*(s: Slot2) =
  s.rumble_last = s.rumble_edges
  s.rumble_edges = 0

proc rumble*(s: Slot2): int =
  ## Rumble strength for the frontend, 0 (still) .. 255. The Rumble Pak's
  ## actuator moves on each change of its latch, so the strength follows how
  ## many changes the last frame had (one a frame is a light buzz; a game
  ## toggling from a timer gets full strength). A GBA cart's GPIO motor
  ## (bit 3 an output, driven high) is simply on.
  case s.kind
  of s2RumblePak: min(255, s.rumble_last * 64)
  of s2GbaCart:
    if (s.gpio_dir and 8) != 0 and (s.gpio_data and 8) != 0: 255 else: 0
  else: 0

proc gba_header_info*(s: Slot2): array[12, uint8] =
  ## What the firmware leaves at 0x027FFC30 about the GBA slot (GBATEK "DS
  ## Firmware ... boot"): header bytes BEh-BFh, B5h-B7h, a flags byte,
  ## B0h-B1h (maker), ACh-AFh (game code). An empty slot leaves FFh, the
  ## flags byte 00h (the real firmware, --boot firmware with the dumps).
  for b in result.mitems: b = 0xFF
  result[5] = 0
  if s.kind != s2GbaCart or s.rom.len < 0xC0: return
  let r = s.rom
  result[0] = r[0xBE]; result[1] = r[0xBF]
  result[2] = r[0xB5]; result[3] = r[0xB6]; result[4] = r[0xB7]
  result[5] = 0    # "whatever flags": Assumed 0
  result[6] = r[0xB0]; result[7] = r[0xB1]
  for i in 0..3: result[8 + i] = r[0xAC + i]

{.pop.}
