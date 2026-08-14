# Cartridge implementation (included by gba.nim)

proc new_cartridge*(rom_path: string): Cartridge =
  result = Cartridge()
  let sz = int(getFileSize(rom_path))
  # Allocate only the next power of two >= the ROM size (was a flat 32 MB): a
  # 16 MB game now uses 16 MB, an 8 MB game 8 MB, etc. A power-of-two size lets
  # the instruction-fetch fast path mask the address (rom_mask) with no bounds
  # check, and reads past the ROM (which are rare) fall back to the open-bus
  # address pattern in bus.nim. The [sz, alloc) gap stays zero (newSeq default),
  # matching the previous non-power-of-two zero-pad behavior.
  # The floor only has to keep the header in range (game_code lives at 0xAC)
  # and give rom_ptr something to point at. It must NOT be set to a "typical"
  # cart size: rom.len is also the address at which reads start returning the
  # open-bus pattern, and a mask ROM decodes exactly its own power-of-two
  # window — so a 1.7 KB test ROM has to float from 2 KB up, not from 32 KB.
  # (GBATEK: the unused gamepak area reads back Address/2 AND FFFFh; jsmolka
  # unsafe test 2 checks the first 4 KB past next_pow2(rom size).) No real
  # cart is anywhere near the floor, so nothing about shipped games changes.
  var alloc = 0x100
  while alloc < sz: alloc = alloc shl 1
  # Classic NES Series / Famicom Mini carts are exactly 1 MiB and their mask
  # ROM decodes 4 MiB of address space: the image appears mirrored 4x, but not
  # beyond that (reads past 4 MiB float and return the address pattern, same
  # as any other cart). Metroid's anti-emulation check jumps into the mirrors
  # and shows "GAME PAK ERROR" if they aren't there. Materialize the mirrors
  # into the buffer at load time so the read fast path stays branch-free;
  # matches mGBA's GBALoadROM ("1 MiB ROMs all appear as 4x mirrored").
  if sz == 0x100000: alloc = 0x400000
  result.rom = newSeq[byte](alloc)
  result.rom_mask = uint32(alloc - 1)
  result.rom_size = sz
  let f = open(rom_path, fmRead)
  discard f.readBytes(result.rom, 0, sz)
  f.close()
  if sz == 0x100000:
    for i in 1 .. 3:
      copyMem(addr result.rom[i * sz], addr result.rom[0], sz)
  # Cart identity, taken once, here, from the bytes exactly as they came off
  # disk. Nothing may recompute it later: the cheat engine patches `rom` in
  # place, so a hash of the live buffer changes the moment a ROM-patching code
  # is toggled and every save state for the game stops loading. Same window as
  # before (the first 1 MB of the FILE), so the value is unchanged for every
  # cart -- this moves WHEN it is computed, not WHAT from.
  let idn = min(sz, 0x100000)
  result.rom_identity =
    if idn <= 0: fnv1a(toOpenArray(result.rom, 0, -1))
    else: fnv1a(toOpenArray(result.rom, 0, idn - 1))

proc rom_open_bus*(address: uint32): uint8 {.inline.} =
  ## Value returned when reading past the end of the ROM: the incrementing
  ## address on the cartridge bus, `(addr >> 1) & 0xFFFF`, split into bytes.
  uint8((0xFFFF'u32 and (address shr 1)) shr (8 * (address and 1)))

proc title*(cart: Cartridge): string =
  ## The raw 12 header bytes, NULs and all. Callers that want something to put
  ## in front of a human use `rom_title` below.
  result = newString(12)
  for i in 0 ..< 12:
    result[i] = char(cart.rom[0x0A0 + i])

proc rom_title*(cart: Cartridge): string =
  ## The header title as a display name: NUL-terminated, printable-ASCII only,
  ## trimmed (common/romtitle.nim, shared with the GB core). Empty for the
  ## headerless homebrew and test ROMs this emulator also runs, which is what
  ## tells a frontend to fall back to the filename.
  ##
  ## Not cached and not serialized: it is derived from ROM bytes, and the one
  ## thing that rewrites `rom` in place (the cheat engine) has no business
  ## renaming the game. Callers read it once at load time.
  gba_header_title(cart.rom)

proc game_code*(cart: Cartridge): string =
  ## The 4-character game code at header offset 0xAC (e.g. "KYGE"). Used to
  ## detect cart hardware that cannot be probed at runtime (tilt/gyro).
  result = newString(4)
  for i in 0 ..< 4:
    result[i] = char(cart.rom[0x0AC + i])
