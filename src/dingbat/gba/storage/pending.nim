# A backup chip chosen by what the game does with save memory (included by
# gba.nim).
#
# A ROM that links the EEPROM library beside the SRAM or a flash library
# (storage_chip.nim storage_candidates) does not say which chip its board
# carries. With no battery file to go by, the game's accesses choose. In
# the 31 such ROMs in the library (docs/playtest-bugs.md §105) most send an EEPROM command DMA to 0x0D
# first; some probe 0x0E/0x0F first (write and read back, a flash ID
# command, a DMA into 0FFFFFFCh) and fall back to EEPROM when nothing
# answers; Breath of Fire (J) (EEPROM_V121, FLASH_V124, SRAM_V112) reads its
# settings block from SRAM 5,120 times before its first write, and freezes
# if SRAM never answers. A game reading back its own save is an SRAM game; a
# probe reads a handful of bytes, or never writes.
#
# So the region answers as no chip at all (writes dropped, reads FFh, as on
# an EEPROM board) until one of:
#
#   - any access to the EEPROM window (0x0D) -> EEPROM
#   - a CPU write to 0x0E/0x0F after SRAM_LOAD_READS CPU reads of the region
#     and no write -> SRAM, and the write lands
#
# A ROM that names no backup library at all (storage_chip.nim
# names_no_save_library) has no library probe to step round, so its first
# access chooses outright: the EEPROM window -> EEPROM (Famicom Mini Vol. 04
# Excitebike (J)), AAh written to 0E005555h -> a 64 KB flash, any other CPU
# access to 0x0E/0x0F -> SRAM. One that never touches save memory writes no
# battery file.
#
# DMA accesses to 0x0E/0x0F never decide (Super Monkey Ball Jr). Flash is
# chosen only by a battery file of a flash chip's size (gba.nim
# new_storage): answering a flash ID probe would invent a chip.

const SRAM_LOAD_READS = 256
  ## CPU reads of the SRAM region, with no write among them, that make the
  ## next write an SRAM game's: Breath of Fire (J) makes 5,120; probing games
  ## at most 16 (DiGi Communication).

proc chip_of(t: StorageType; gba: GBA): Storage =
  case t
  of stEEPROM:                        new_eeprom(gba)
  of stSRAM:                          new_sram()
  of stFLASH, stFLASH512, stFLASH1M:  new_flash(t)
  of stNone:                          NoBackup()

proc flash_candidate(c: set[StorageType]): StorageType =
  for t in [stFLASH512, stFLASH1M, stFLASH]:
    if t in c:
      return t
  stNone

proc new_pending_storage*(gba: GBA): PendingStorage =
  result = PendingStorage(gba_ref: gba)
  result.eeprom_floor =
    if gba.cartridge != nil and gba.cartridge.rom_size > 0x1000000: 0x0DFFFF00'u32
    else: 0x0D000000'u32

proc carry_storage_fields(dst, src: Storage) =
  ## What the cart and the frontend gave the storage object, rather than the
  ## chip's contents: kept across a change of chip object.
  dst.candidates = src.candidates
  dst.no_save_library = src.no_save_library
  dst.save_path = src.save_path
  dst.rtc_cart = src.rtc_cart
  dst.rtc = src.rtc
  dst.has_trailer = src.has_trailer
  dst.trailer = src.trailer
  dst.save_error = src.save_error
  dst.save_error_new = src.save_error_new

proc settle_storage*(gba: GBA; t: StorageType): Storage =
  ## Replace `gba.storage` with a blank chip of type `t` (stNone: an
  ## undecided one), keeping the cart's fields.
  let old = gba.storage
  result = if t == stNone: new_pending_storage(gba) else: chip_of(t, gba)
  if old != nil:
    carry_storage_fields(result, old)
  gba.storage = result

method `[]`*(p: PendingStorage; address: uint32): uint8 =
  if (address shr 24) == 0x0D'u32:
    return p.gba_ref.settle_storage(stEEPROM)[address]
  if p.no_save_library and not p.gba_ref.bus.dma_active:
    return p.gba_ref.settle_storage(stSRAM)[address]
  if not p.gba_ref.bus.dma_active and p.sram_reads >= 0:
    p.sram_reads = min(p.sram_reads + 1, SRAM_LOAD_READS)
  0xFF'u8

method `[]=`*(p: PendingStorage; address: uint32; value: uint8) =
  if (address shr 24) == 0x0D'u32:
    p.gba_ref.settle_storage(stEEPROM)[address] = value
    return
  if p.gba_ref.bus.dma_active:
    return
  if p.no_save_library:
    let flash = (address and 0xFFFF'u32) == 0x5555'u32 and value == 0xAA'u8
    p.gba_ref.settle_storage(if flash: stFLASH512 else: stSRAM)[address] = value
    return
  if p.sram_reads >= SRAM_LOAD_READS and stSRAM in p.candidates:
    p.gba_ref.settle_storage(stSRAM)[address] = value
  else:
    p.sram_reads = -1   # written before it was read back: a probe, not a load
