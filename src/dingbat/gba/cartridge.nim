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
  var alloc = 0x8000  # a small floor; every real cart is far larger
  while alloc < sz: alloc = alloc shl 1
  result.rom = newSeq[byte](alloc)
  result.rom_mask = uint32(alloc - 1)
  let f = open(rom_path, fmRead)
  discard f.readBytes(result.rom, 0, sz)
  f.close()

proc rom_open_bus*(address: uint32): uint8 {.inline.} =
  ## Value returned when reading past the end of the ROM: the incrementing
  ## address on the cartridge bus, `(addr >> 1) & 0xFFFF`, split into bytes.
  uint8((0xFFFF'u32 and (address shr 1)) shr (8 * (address and 1)))

proc title*(cart: Cartridge): string =
  result = newString(12)
  for i in 0 ..< 12:
    result[i] = char(cart.rom[0x0A0 + i])
