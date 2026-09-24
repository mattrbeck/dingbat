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

proc find_storage_type(content: string): StorageType =
  ## Scan the ROM image for backup type identifiers.
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
  # SRAM and one flash library (Rockman EXE 4.5, One Piece - Mezase! King of
  # Paris): the game sends the flash ID command before anything else. Rockman
  # waits on a flash answer and never saves to SRAM; One Piece falls back to
  # SRAM only when no flash answers.
  if content.contains("SRAM_V") and not content.contains("EEPROM_V"):
    for t in [stFLASH512, stFLASH1M, stFLASH]:
      if content.contains(match_str(t)):
        return t
  for t in StorageType:
    if t != stNone and content.contains(match_str(t)):
      return t
  echo "Backup type could not be identified."
  stSRAM  # fallback

method `[]`*(st: Storage; address: uint32): uint8 {.base.} =
  quit "Storage.[] not implemented for " & $st.type

method `[]=`*(st: Storage; address: uint32; value: uint8) {.base.} =
  quit "Storage.[]= not implemented for " & $st.type

proc rom_has_rtc(content: string): bool =
  ## Carts with the Seiko S-3511A RTC link Nintendo's RTC library, whose ID
  ## string is "SIIRTC_V" (like "SRAM_V"/"FLASH1M_V" for backup chips). In
  ## the 7,906-ROM compatibility library it occurs in exactly the Pokemon
  ## Ruby/Sapphire/Emerald, Boktai 1-3, Rockman EXE 4.5, Sennen Kazoku and
  ## both Legendz families (and their hacks/translations), the same ten
  ## game-code families mGBA's override table fits with an RTC, and no others.
  content.contains("SIIRTC_V")

proc rtc_trailer_bytes(rtc: RTC): array[16, byte]  # rtc.nim

proc battery_file_bytes*(st: Storage): string =
  ## What write_save puts on disk: the chip bytes, then on an RTC cart the
  ## clock trailer (rtc_calendar.nim). A trailer read from a cart dingbat does
  ## not treat as an RTC cart is kept verbatim: RTC detection is a ROM-string
  ## heuristic, and a clock another tool recorded must not be lost to a cart
  ## (a hack, a stripped ROM) the heuristic misses.
  result = newString(st.memory.len)
  if st.memory.len > 0:
    copyMem(addr result[0], unsafeAddr st.memory[0], st.memory.len)
  if st.rtc != nil:
    let t = rtc_trailer_bytes(st.rtc)
    for b in t: result.add(char(b))
  elif st.has_trailer:
    for b in st.trailer: result.add(char(b))

proc write_save*(st: Storage) =
  # Empty save_path = no battery file (web build persists itself; harnesses
  # detach it so a run leaves no .sav). dirty stays set so a rebind flushes.
  if st.dirty and st.save_path.len > 0:
    try:
      writeFile(st.save_path, st.battery_file_bytes())
      st.dirty = false
      st.save_error = ""
    except IOError, OSError:
      # A read-only folder, a full disk, a file another program holds: the
      # game plays on with its RAM still dirty, so every frame retries.
      # Said once per run of failures; the frontend shows `save_error`.
      if st.save_error.len == 0:
        st.save_error_new = true
        echo "Failed to write save file: ", st.save_path
      st.save_error = getCurrentExceptionMsg()

proc read_half*(st: Storage; address: uint32): uint16 =
  0x0101'u16 * uint16(st[address])

proc read_word*(st: Storage; address: uint32): uint32 =
  0x01010101'u32 * uint32(st[address])

proc eeprom_at*(st: Storage; address: uint32): bool =
  st of EEPROM and (address >= 0x0D000000'u32 and address <= 0x0DFFFFFF'u32)

