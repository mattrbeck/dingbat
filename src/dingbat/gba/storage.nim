# Storage base class (included by gba.nim)

method `[]`*(st: Storage; address: uint32): uint8 {.base.} =
  quit "Storage.[] not implemented for " & $st.type

method `[]=`*(st: Storage; address: uint32; value: uint8) {.base.} =
  quit "Storage.[]= not implemented for " & $st.type

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
  # A 4 Kbit EEPROM loaded from a longer file (eeprom_file_tail): the file
  # keeps its length and its bytes past the chip, as they were.
  if st.memory.len == 0x200:
    for b in st.eeprom_file_tail: result.add(char(b))
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
      # Temp file, fsync, rename: a crash, full disk or power cut mid-write
      # leaves the previous save, never a short one that loads as valid.
      # Synced although it can run every frame: only frames that changed the
      # RAM write, and 128 KB costs ~0.3 ms on an SSD.
      write_file_atomic(st.save_path, st.battery_file_bytes())
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

