## GBA cartridge backup chips, independent of the GBA core: which chip a ROM
## carries (by the library ID strings it links) and the FLASH chip's command
## state machine. The GBA core (gba.nim, storage/*.nim) wraps these in its
## Storage objects; the DS slot-2 cartridge (nds/io/slot2.nim) uses them
## directly, since a GBA cart in a DS reaches the same chips (GBATEK "DS
## Cartridge GBA Slot").

import std/strutils

type
  StorageType* = enum
    stEEPROM, stSRAM, stFLASH, stFLASH512, stFLASH1M,
    stNone   # no backup chip on the cart (find_storage_type)

  FlashStateFlag* = enum
    fsReady, fsCmd1, fsCmd2, fsIdentification, fsPrepareWrite, fsPrepareErase, fsSetBank

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

proc storage_bytes*(t: StorageType): int =
  case t
  of stEEPROM:   0  # handled by EEPROM class
  of stSRAM:     0x08000
  of stFLASH:    0x10000
  of stFLASH512: 0x10000
  of stFLASH1M:  0x20000
  of stNone:     0

proc find_storage_type*(content: string): StorageType =
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

proc rom_has_rtc*(content: string): bool =
  ## Carts with the Seiko S-3511A RTC link Nintendo's RTC library, whose ID
  ## string is "SIIRTC_V" (like "SRAM_V"/"FLASH1M_V" for backup chips). In
  ## the 7,906-ROM compatibility library it occurs in exactly the Pokemon
  ## Ruby/Sapphire/Emerald, Boktai 1-3, Rockman EXE 4.5, Sennen Kazoku and
  ## both Legendz families (and their hacks/translations), the same ten
  ## game-code families mGBA's override table fits with an RTC, and no others.
  content.contains("SIIRTC_V")

# ---------------------------------------------------------------------------
# FLASH (GBATEK "GBA Cart Backup Flash ROM"): JEDEC-style command sequences
# at 5555h/2AAAh, 64 KB banks.

const
  FLASH_CMD_ENTER_IDENT*:   uint8 = 0x90
  FLASH_CMD_EXIT_IDENT*:    uint8 = 0xF0
  FLASH_CMD_PREPARE_ERASE*: uint8 = 0x80
  FLASH_CMD_ERASE_ALL*:     uint8 = 0x10
  FLASH_CMD_ERASE_CHUNK*:   uint8 = 0x30
  FLASH_CMD_PREPARE_WRITE*: uint8 = 0xA0
  FLASH_CMD_SET_BANK*:      uint8 = 0xB0

proc flash_id*(t: StorageType): uint16 =
  case t
  of stFLASH1M: 0x1362'u16  # Sanyo
  else:         0x1B32'u16  # Panasonic

proc flash_read*(memory: seq[byte]; state: set[FlashStateFlag]; bank: uint8;
                 id: uint16; address: uint32): uint8 =
  let a = address and 0xFFFF'u32
  if fsIdentification in state and a <= 1:
    uint8((id shr (8 * a)) and 0xFF)
  else:
    memory[0x10000 * int(bank) + int(a)]

proc flash_write*(memory: var seq[byte]; state: var set[FlashStateFlag];
                  bank: var uint8; flash_type: StorageType; address: uint32;
                  value: uint8): bool =
  ## One byte written to the chip; true when it changed the stored data.
  let a = address and 0xFFFF'u32
  if fsPrepareWrite in state:
    memory[0x10000 * int(bank) + int(a)] = memory[0x10000 * int(bank) + int(a)] and value
    result = true
    state.excl(fsPrepareWrite)
  elif fsSetBank in state:
    bank = value and 1
    state.excl(fsSetBank)
  elif fsReady in state:
    if a == 0x5555 and value == 0xAA:
      state.excl(fsReady)
      state.incl(fsCmd1)
  elif fsCmd1 in state:
    if a == 0x2AAA and value == 0x55:
      state.excl(fsCmd1)
      state.incl(fsCmd2)
  elif fsCmd2 in state:
    if a == 0x5555:
      case value
      of FLASH_CMD_ENTER_IDENT:
        state.incl(fsIdentification)
      of FLASH_CMD_EXIT_IDENT:
        state.excl(fsIdentification)
      of FLASH_CMD_PREPARE_ERASE:
        state.incl(fsPrepareErase)
      of FLASH_CMD_ERASE_ALL:
        if fsPrepareErase in state:
          for i in 0 ..< memory.len:
            memory[i] = 0xFF
          result = true
          state.excl(fsPrepareErase)
      of FLASH_CMD_PREPARE_WRITE:
        state.incl(fsPrepareWrite)
      of FLASH_CMD_SET_BANK:
        if flash_type == stFLASH1M:
          state.incl(fsSetBank)
      else:
        echo "Unsupported flash command ", toHex(value)
    elif fsPrepareErase in state and (a and 0x0FFF'u32) == 0 and value == FLASH_CMD_ERASE_CHUNK:
      for i in 0 ..< 0x1000:
        memory[0x10000 * int(bank) + int(a) + i] = 0xFF
      result = true
      state.excl(fsPrepareErase)
    state.excl(fsCmd2)
    state.incl(fsReady)
