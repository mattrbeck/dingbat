# Cartridge implementation (included by gba.nim)

proc new_cartridge*(rom_path: string): Cartridge =
  result = Cartridge()
  let sz = int(getFileSize(rom_path))
  # Allocate the next power of two >= the ROM size: the fetch fast path masks
  # with rom_mask, and reads from rom.len upward return the open-bus address
  # pattern (GBATEK: the unused gamepak area reads Address/2 AND FFFFh; jsmolka
  # unsafe test 2 checks the first 4 KB past next_pow2(rom size)). The floor
  # only keeps the header in range: a 1.7 KB test ROM must float from 2 KB.
  var alloc = 0x100
  while alloc < sz: alloc = alloc shl 1
  # 1 MiB carts (Classic NES Series / Famicom Mini) mirror the image: GBATEK
  # "GBA Cart Protections" lists "ROM mirrors (instead of the usual increasing
  # numbers in unused ROM area)" for them, and Classic NES Metroid jumps into
  # the mirrors ("GAME PAK ERROR" without). 4x in a 4 MiB window, then the
  # address pattern, is assumed. Materialised at load so the read path stays
  # branch-free.
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
  # Cart identity is hashed once, from the first 1 MB as loaded, never from the
  # live buffer: the cheat engine patches `rom` in place, and a changed hash
  # would stop every save state for the game from loading.
  let idn = min(sz, 0x100000)
  result.rom_identity =
    if idn <= 0: fnv1a(toOpenArray(result.rom, 0, -1))
    else: fnv1a(toOpenArray(result.rom, 0, idn - 1))

proc rom_open_bus*(address: uint32): uint8 {.inline.} =
  ## Value returned when reading past the end of the ROM: the incrementing
  ## address on the cartridge bus, `(addr >> 1) & 0xFFFF`, split into bytes.
  uint8((0xFFFF'u32 and (address shr 1)) shr (8 * (address and 1)))

proc title*(cart: Cartridge): string =
  result = newString(12)
  for i in 0 ..< 12:
    result[i] = char(cart.rom[0x0A0 + i])

proc game_code*(cart: Cartridge): string =
  ## The 4-character game code at header offset 0xAC (e.g. "KYGE"). Used to
  ## detect cart hardware that cannot be probed at runtime (tilt/gyro).
  result = newString(4)
  for i in 0 ..< 4:
    result[i] = char(cart.rom[0x0AC + i])
