## Cartridge header titles, for both cores.
##
## Every shipped cartridge writes a short ASCII name into its header, and the
## frontends want it: the native window title and the web page/lock-screen
## "now playing" would otherwise say nothing about which game is running. The
## GB and GBA fields differ only in where they live and how long they are, so
## the sanitizer is shared and each core gets a thin wrapper.
##
## The result is deliberately allowed to be empty. Homebrew, raw `objcopy`
## output and this repo's own test ROMs frequently leave the field zeroed or
## fill it with code, and an empty string is what tells a caller to fall back
## to the filename (which is what both frontends prefer anyway — see the
## precedence note in src/dingbat.nim's `window_game_name`). NOTHING here is
## serialized into a save state: it is derived from ROM bytes that the state
## does not carry and cannot change.

import std/strutils

proc header_title(rom: openArray[byte]; first, limit: int): string =
  ## The title bytes in `[first, limit)`, sanitized.
  ##
  ## Rules, in order:
  ##  * stop at the first NUL — the field is a fixed-width, NUL-padded buffer,
  ##    and bytes after the terminator are padding or (on a CGB cart whose
  ##    title is short) part of the next header field;
  ##  * keep only printable ASCII (0x20..0x7E), dropping anything else rather
  ##    than emitting a replacement — a garbage file then yields "" or a short
  ##    fragment, never a control character in a window title;
  ##  * trim surrounding whitespace, since space is the other common padding.
  if first >= limit: return ""
  result = newStringOfCap(limit - first)
  for i in first ..< limit:
    if i >= rom.len: break
    let ch = rom[i]
    if ch == 0'u8: break
    if ch >= 0x20'u8 and ch <= 0x7E'u8: result.add(char(ch))
  result = result.strip()

proc gb_header_title*(rom: openArray[byte]): string =
  ## Game Boy / Game Boy Color cartridge title, header offset 0x134.
  ##
  ## The field was originally 16 bytes (0x134..0x143). The CGB era carved the
  ## tail up: 0x13F..0x142 became the 4-character manufacturer code and 0x143
  ## the CGB compatibility flag ($80 CGB-enhanced, $C0 CGB-only). So the window
  ## is 11 bytes on a cart that flags itself CGB-aware and the full 16
  ## otherwise — reading 16 unconditionally appends the manufacturer code to
  ## every CGB game's name ("POKEMON CRYSAXVE"). Pan Docs, "The Cartridge
  ## Header": 0134-0143 Title / 013F-0142 Manufacturer Code / 0143 CGB Flag.
  if rom.len < 0x144: return ""
  let cgb = rom[0x143] == 0x80'u8 or rom[0x143] == 0xC0'u8
  header_title(rom, 0x134, if cgb: 0x13F else: 0x144)

proc gba_header_title*(rom: openArray[byte]): string =
  ## Game Boy Advance cartridge title: 12 bytes at header offset 0xA0,
  ## uppercase ASCII, NUL-padded (GBATEK, "The Cartridge Header"). The 4-byte
  ## game code at 0xAC that follows it is a separate field with its own reader
  ## (`game_code` in gba/cartridge.nim) and is never folded in here.
  if rom.len < 0xAC: return ""
  header_title(rom, 0xA0, 0xAC)
