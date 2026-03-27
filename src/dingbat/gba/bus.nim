# Bus implementation (included by gba.nim)

const ACCESS_TIMING_TABLE: array[2, array[16, int]] = [
  [1, 1, 3, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2],  # 8-bit / 16-bit
  [1, 1, 6, 1, 1, 2, 2, 1, 4, 4, 4, 4, 4, 4, 4, 4],  # 32-bit
]

proc write_stub_u32(bios: var seq[byte]; offset: int; value: uint32) =
  bios[offset + 0] = byte(value)
  bios[offset + 1] = byte(value shr 8)
  bios[offset + 2] = byte(value shr 16)
  bios[offset + 3] = byte(value shr 24)

proc new_bus*(gba: GBA; bios_path: string): Bus =
  result = Bus(gba: gba)
  result.cycles = 0
  result.bios       = newSeq[byte](0x4000)
  result.wram_board = newSeq[byte](0x40000)
  result.wram_chip  = newSeq[byte](0x08000)
  if bios_path != "" and fileExists(bios_path):
    let f = open(bios_path, fmRead)
    discard f.readBytes(result.bios, 0, result.bios.len)
    f.close()
  else:
    # Minimal BIOS stub: IRQ handler at 0x18 dispatches to user handler at [0x03FFFFFC].
    #   0x18: stmfd sp!, {r0-r3, r12, lr}   E92D500F
    #   0x1C: mov   r0, #0x04000000          E3A00301
    #   0x20: add   lr, pc, #0               E28FE000
    #   0x24: ldr   pc, [r0, #-4]            E510F004
    #   0x28: ldmfd sp!, {r0-r3, r12, lr}    E8BD500F
    #   0x2C: subs  pc, lr, #4               E25EF004
    write_stub_u32(result.bios, 0x18, 0xE92D500F'u32)
    write_stub_u32(result.bios, 0x1C, 0xE3A00301'u32)
    write_stub_u32(result.bios, 0x20, 0xE28FE000'u32)
    write_stub_u32(result.bios, 0x24, 0xE510F004'u32)
    write_stub_u32(result.bios, 0x28, 0xE8BD500F'u32)
    write_stub_u32(result.bios, 0x2C, 0xE25EF004'u32)
  result.gpio = new_gpio(gba)

proc bus_page(address: uint32): int {.inline.} =
  int(bits_range(address, 24, 27))

# ---- low-level pointer reads ----

proc read_u16_ptr(buf: seq[byte]; offset: uint32): uint16 {.inline.} =
  cast[ptr uint16](unsafeAddr buf[offset])[]

proc read_u32_ptr(buf: seq[byte]; offset: uint32): uint32 {.inline.} =
  cast[ptr uint32](unsafeAddr buf[offset])[]

proc write_u16_ptr(buf: var seq[byte]; offset: uint32; val: uint16) {.inline.} =
  cast[ptr uint16](addr buf[offset])[] = val

proc write_u32_ptr(buf: var seq[byte]; offset: uint32; val: uint32) {.inline.} =
  cast[ptr uint32](addr buf[offset])[] = val

# ---- internal read implementations ----

proc read_byte_internal*(bus: Bus; address: uint32): uint8 {.inline.} =
  case bits_range(address, 24, 27)
  of 0x0: bus.bios[address and 0x3FFF'u32]
  of 0x1: 0'u8  # open bus todo
  of 0x2: bus.wram_board[address and 0x3FFFF'u32]
  of 0x3: bus.wram_chip[address and 0x7FFF'u32]
  of 0x4: bus.gba.mmio[address]
  of 0x5: bus.gba.ppu.pram[address and 0x3FF'u32]
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    bus.gba.ppu.vram[a]
  of 0x7: bus.gba.ppu.oam[address and 0x3FF'u32]
  of 0x8, 0x9, 0xA, 0xB, 0xC, 0xD:
    if address_in_gpio(address) and bus.gpio.allow_reads:
      bus.gpio[address]
    elif bus.gba.storage.eeprom_at(address):
      bus.gba.storage[address]
    else:
      bus.gba.cartridge.rom[address and 0x01FFFFFF'u32]
  of 0xE, 0xF: bus.gba.storage[address]
  else: raise newException(Exception, "Unmapped bus read: " & hex_str(address))

proc read_half_internal*(bus: Bus; address: uint32): uint16 {.inline.} =
  let address = address and not 1'u32
  case bits_range(address, 24, 27)
  of 0x0: read_u16_ptr(bus.bios, address and 0x3FFF'u32)
  of 0x1: 0'u16
  of 0x2: read_u16_ptr(bus.wram_board, address and 0x3FFFF'u32)
  of 0x3: read_u16_ptr(bus.wram_chip, address and 0x7FFF'u32)
  of 0x4:
    uint16(bus.read_byte_internal(address)) or
    (uint16(bus.read_byte_internal(address + 1)) shl 8)
  of 0x5: read_u16_ptr(bus.gba.ppu.pram, address and 0x3FF'u32)
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    read_u16_ptr(bus.gba.ppu.vram, a)
  of 0x7: read_u16_ptr(bus.gba.ppu.oam, address and 0x3FF'u32)
  of 0x8, 0x9, 0xA, 0xB, 0xC, 0xD:
    if address_in_gpio(address) and bus.gpio.allow_reads:
      uint16(bus.gpio[address])
    elif bus.gba.storage.eeprom_at(address):
      uint16(bus.gba.storage[address])
    else:
      read_u16_ptr(bus.gba.cartridge.rom, address and 0x01FFFFFF'u32)
  of 0xE, 0xF: bus.gba.storage.read_half(address)
  else: raise newException(Exception, "Unmapped bus read_half: " & hex_str(address))

proc read_word_internal*(bus: Bus; address: uint32): uint32 {.inline.} =
  let address = address and not 3'u32
  case bits_range(address, 24, 27)
  of 0x0: read_u32_ptr(bus.bios, address and 0x3FFF'u32)
  of 0x1: 0'u32
  of 0x2: read_u32_ptr(bus.wram_board, address and 0x3FFFF'u32)
  of 0x3: read_u32_ptr(bus.wram_chip, address and 0x7FFF'u32)
  of 0x4:
    uint32(bus.read_byte_internal(address)) or
    (uint32(bus.read_byte_internal(address + 1)) shl 8) or
    (uint32(bus.read_byte_internal(address + 2)) shl 16) or
    (uint32(bus.read_byte_internal(address + 3)) shl 24)
  of 0x5: read_u32_ptr(bus.gba.ppu.pram, address and 0x3FF'u32)
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    read_u32_ptr(bus.gba.ppu.vram, a)
  of 0x7: read_u32_ptr(bus.gba.ppu.oam, address and 0x3FF'u32)
  of 0x8, 0x9, 0xA, 0xB, 0xC, 0xD:
    if address_in_gpio(address) and bus.gpio.allow_reads:
      uint32(bus.gpio[address])
    elif bus.gba.storage.eeprom_at(address):
      uint32(bus.gba.storage[address])
    else:
      read_u32_ptr(bus.gba.cartridge.rom, address and 0x01FFFFFF'u32)
  of 0xE, 0xF: bus.gba.storage.read_word(address)
  else: raise newException(Exception, "Unmapped bus read_word: " & hex_str(address))

proc write_byte_internal*(bus: Bus; address: uint32; value: uint8) =
  if bits_range(address, 28, 31) > 0: return
  if address <= bus.gba.cpu.r[15] and address >= bus.gba.cpu.r[15] - 4:
    bus.gba.cpu.fill_pipeline()
  case bits_range(address, 24, 27)
  of 0x2: bus.wram_board[address and 0x3FFFF'u32] = value
  of 0x3: bus.wram_chip[address and 0x7FFF'u32] = value
  of 0x4: bus.gba.mmio[address] = value
  of 0x5:
    write_u16_ptr(bus.gba.ppu.pram, address and 0x3FE'u32, 0x0101'u16 * uint16(value))
  of 0x6:
    let limit: uint32 = if bus.gba.ppu.bitmap(): 0x13FFF'u32 else: 0x0FFFF'u32
    var a = 0x1FFFE'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    if a <= limit:
      write_u16_ptr(bus.gba.ppu.vram, a, 0x0101'u16 * uint16(value))
  of 0x7: discard  # can't write bytes to oam
  of 0x8, 0xD:
    if address_in_gpio(address):
      bus.gpio[address] = value
    elif bus.gba.storage.eeprom_at(address):
      discard bus.gba.storage[address]  # eeprom write check
  of 0xE, 0xF: bus.gba.storage[address] = value
  else: log("Unmapped write: " & hex_str(address))

proc write_half_internal*(bus: Bus; address: uint32; value: uint16) =
  if bits_range(address, 28, 31) > 0: return
  let address = address and not 1'u32
  if address <= bus.gba.cpu.r[15] and address >= bus.gba.cpu.r[15] - 4:
    bus.gba.cpu.fill_pipeline()
  case bits_range(address, 24, 27)
  of 0x2: write_u16_ptr(bus.wram_board, address and 0x3FFFF'u32, value)
  of 0x3: write_u16_ptr(bus.wram_chip, address and 0x7FFF'u32, value)
  of 0x4:
    bus.write_byte_internal(address, uint8(value))
    bus.write_byte_internal(address + 1, uint8(value shr 8))
  of 0x5: write_u16_ptr(bus.gba.ppu.pram, address and 0x3FF'u32, value)
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    write_u16_ptr(bus.gba.ppu.vram, a, value)
  of 0x7: write_u16_ptr(bus.gba.ppu.oam, address and 0x3FF'u32, value)
  of 0x8, 0xD:
    if address_in_gpio(address):
      bus.gpio[address] = uint8(value)
    elif bus.gba.storage.eeprom_at(address):
      bus.gba.storage[address] = uint8(value)
  of 0xE, 0xF:
    bus.write_byte_internal(address, uint8(value))
    bus.write_byte_internal(address + 1, uint8(value shr 8))
  else: log("Unmapped write half: " & hex_str(address))

proc write_word_internal*(bus: Bus; address: uint32; value: uint32) =
  if bits_range(address, 28, 31) > 0: return
  let address = address and not 3'u32
  if address <= bus.gba.cpu.r[15] and address >= bus.gba.cpu.r[15] - 4:
    bus.gba.cpu.fill_pipeline()
  case bits_range(address, 24, 27)
  of 0x2: write_u32_ptr(bus.wram_board, address and 0x3FFFF'u32, value)
  of 0x3: write_u32_ptr(bus.wram_chip, address and 0x7FFF'u32, value)
  of 0x4:
    bus.write_byte_internal(address,     uint8(value))
    bus.write_byte_internal(address + 1, uint8(value shr 8))
    bus.write_byte_internal(address + 2, uint8(value shr 16))
    bus.write_byte_internal(address + 3, uint8(value shr 24))
  of 0x5: write_u32_ptr(bus.gba.ppu.pram, address and 0x3FF'u32, value)
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    write_u32_ptr(bus.gba.ppu.vram, a, value)
  of 0x7: write_u32_ptr(bus.gba.ppu.oam, address and 0x3FF'u32, value)
  of 0x8, 0xD:
    if address_in_gpio(address):
      bus.gpio[address] = uint8(value)
    elif bus.gba.storage.eeprom_at(address):
      bus.gba.storage[address] = uint8(value)
  of 0xE, 0xF:
    bus.write_byte_internal(address,     uint8(value))
    bus.write_byte_internal(address + 1, uint8(value shr 8))
    bus.write_byte_internal(address + 2, uint8(value shr 16))
    bus.write_byte_internal(address + 3, uint8(value shr 24))
  else: log("Unmapped write word: " & hex_str(address))

# ---- Public read/write with cycle accounting ----

proc `[]`*(bus: Bus; address: uint32): uint8 =
  bus.cycles += ACCESS_TIMING_TABLE[0][bus_page(address)]
  bus.read_byte_internal(address)

proc read_half*(bus: Bus; address: uint32): uint16 =
  bus.cycles += ACCESS_TIMING_TABLE[0][bus_page(address)]
  bus.read_half_internal(address)

proc read_word*(bus: Bus; address: uint32): uint32 =
  bus.cycles += ACCESS_TIMING_TABLE[1][bus_page(address)]
  bus.read_word_internal(address)

proc `[]=`*(bus: Bus; address: uint32; value: uint8) =
  bus.cycles += ACCESS_TIMING_TABLE[0][bus_page(address)]
  bus.write_byte_internal(address, value)

proc write_half*(bus: Bus; address: uint32; value: uint16) =
  bus.cycles += ACCESS_TIMING_TABLE[0][bus_page(address)]
  bus.write_half_internal(address, value)

proc write_word*(bus: Bus; address: uint32; value: uint32) =
  bus.cycles += ACCESS_TIMING_TABLE[1][bus_page(address)]
  bus.write_word_internal(address, value)

# For DMA write-word via uint32 subscript
proc `[]=`*(bus: Bus; address: uint32; value: uint32) =
  bus.write_word(address, value)

proc read_half_rotate*(bus: Bus; address: uint32): uint32 =
  let half = uint32(bus.read_half(address))
  let bits = (address and 1) * 8
  (half shr bits) or (half shl (32 - bits))

proc read_half_signed*(bus: Bus; address: uint32): uint32 =
  if bit(address, 0):
    uint32(cast[int32](cast[int8](bus[address])))
  else:
    uint32(cast[int32](cast[int16](bus.read_half(address))))

proc read_word_rotate*(bus: Bus; address: uint32): uint32 =
  let word = bus.read_word(address)
  let bits = (address and 3) * 8
  (word shr bits) or (word shl (32 - bits))

proc read_open_bus_value*(bus: Bus; address: uint32): uint8 =
  log("Reading open bus at " & hex_str(address))
  let shift = (address and 3) * 8
  let pc = bus.gba.cpu.r[15]
  # Guard: if PC is in MMIO or otherwise unreadable, avoid infinite recursion
  let pc_region = bits_range(pc, 24, 27)
  if pc_region == 0x4 or pc_region > 0xD:
    return 0'u8
  let word: uint32 =
    if bus.gba.cpu.cpsr.thumb:
      let opcode = uint32(bus.read_half_internal(pc and not 1'u32))
      (opcode shl 16) or opcode
    else:
      bus.read_word_internal(pc and not 3'u32)
  uint8(word shr shift)
