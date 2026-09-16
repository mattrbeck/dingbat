# Storage base class (included by gba.nim)

proc `$`*(t: StorageType): string =
  case t
  of stEEPROM:   "EEPROM"
  of stSRAM:     "SRAM"
  of stFLASH:    "FLASH"
  of stFLASH512: "FLASH512"
  of stFLASH1M:  "FLASH1M"
  of stNone:     "none"

proc match_str(t: StorageType): string =
  case t
  of stEEPROM:  "EEPROM_V"
  of stSRAM:    "SRAM_V"
  of stFLASH:   "FLASH_V"
  of stFLASH512: "FLASH512_V"
  of stFLASH1M: "FLASH1M_V"
  of stNone:    ""

proc storage_bytes(t: StorageType): int =
  case t
  of stEEPROM:   0  # handled by EEPROM class
  of stSRAM:     0x08000
  of stFLASH:    0x10000
  of stFLASH512: 0x10000
  of stFLASH1M:  0x20000
  of stNone:     0

proc find_storage_type(rom_path: string): StorageType =
  ## Scan the ROM file for backup type identifiers.
  let content = readFile(rom_path)
  # A cart that names every non-EEPROM library carries no chip at all: the
  # game probes SRAM (write/verify) and two flash ID routines at boot and
  # disables its own menu if any of them answers -- anti-copier protection on
  # a password-only game whose retail board has no backup memory (TCRF, "Top
  # Gun: Combat Zones (Game Boy Advance)"). Measured by tracing its check
  # value: 0x33 (menu works) with no chip or EEPROM, 0x22 with SRAM, 0x1122 /
  # 0x1133 with any flash ID it knows. Of the 7,906 ROMs in the compatibility
  # library only that game (and its patched dumps) has this combination;
  # pairs of these strings (Rockman EXE 4.5, One Piece) are real chips.
  if content.contains("SRAM_V") and content.contains("FLASH512_V") and
     content.contains("FLASH1M_V"):
    return stNone
  for t in StorageType:
    if t != stNone and content.contains(match_str(t)):
      return t
  echo "Backup type could not be identified."
  stSRAM  # fallback

method `[]`*(st: Storage; address: uint32): uint8 {.base.} =
  quit "Storage.[] not implemented for " & $st.type

method `[]=`*(st: Storage; address: uint32; value: uint8) {.base.} =
  quit "Storage.[]= not implemented for " & $st.type

proc write_save*(st: Storage) =
  # Empty save_path = no battery file (web build persists itself; harnesses
  # detach it so a run leaves no .sav). dirty stays set so a rebind flushes.
  if st.dirty and st.save_path.len > 0:
    writeFile(st.save_path, st.memory)
    st.dirty = false

proc read_half*(st: Storage; address: uint32): uint16 =
  0x0101'u16 * uint16(st[address])

proc read_word*(st: Storage; address: uint32): uint32 =
  0x01010101'u32 * uint32(st[address])

proc eeprom_at*(st: Storage; address: uint32): bool =
  st of EEPROM and (address >= 0x0D000000'u32 and address <= 0x0DFFFFFF'u32)

