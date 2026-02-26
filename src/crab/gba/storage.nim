# Storage base class (included by gba.nim)

proc `$`*(t: StorageType): string =
  case t
  of stEEPROM:   "EEPROM"
  of stSRAM:     "SRAM"
  of stFLASH:    "FLASH"
  of stFLASH512: "FLASH512"
  of stFLASH1M:  "FLASH1M"

proc match_str(t: StorageType): string =
  case t
  of stEEPROM:  "EEPROM_V"
  of stSRAM:    "SRAM_V"
  of stFLASH:   "FLASH_V"
  of stFLASH512: "FLASH512_V"
  of stFLASH1M: "FLASH1M_V"

proc storage_bytes(t: StorageType): int =
  case t
  of stEEPROM:   0  # handled by EEPROM class
  of stSRAM:     0x08000
  of stFLASH:    0x10000
  of stFLASH512: 0x10000
  of stFLASH1M:  0x20000

proc find_storage_type(rom_path: string): StorageType =
  ## Scan the ROM file for backup type identifiers.
  let content = readFile(rom_path)
  for t in StorageType:
    if content.contains(match_str(t)):
      return t
  echo "Backup type could not be identified."
  stSRAM  # fallback

# --- Storage base methods ---

method `[]`*(st: Storage; address: uint32): uint8 {.base.} =
  quit "Storage.[] not implemented for " & $st.type

method `[]=`*(st: Storage; address: uint32; value: uint8) {.base.} =
  quit "Storage.[]= not implemented for " & $st.type

proc write_save*(st: Storage) =
  if st.dirty:
    writeFile(st.save_path, st.memory)
    st.dirty = false

proc read_half*(st: Storage; address: uint32): uint16 =
  0x0101'u16 * uint16(st[address and not 1'u32])

proc read_word*(st: Storage; address: uint32): uint32 =
  0x01010101'u32 * uint32(st[address and not 3'u32])

proc eeprom_at*(st: Storage; address: uint32): bool =
  st of EEPROM and (address >= 0x0D000000'u32 and address <= 0x0DFFFFFF'u32)

