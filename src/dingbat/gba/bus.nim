# Bus implementation (included by gba.nim)

const ACCESS_TIMING_TABLE: array[2, array[16, int]] = [
  [1, 1, 3, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2],  # 8-bit / 16-bit
  [1, 1, 6, 1, 1, 2, 2, 1, 4, 4, 4, 4, 4, 4, 4, 4],  # 32-bit
]

# WAITCNT first-access (nonsequential) wait states and second-access
# (sequential) wait states, per GBATEK. Access cost = waits + 1.
const ROM_N_WAITS = [4, 3, 2, 8]
const ROM_S_WAITS = [[2, 1], [4, 1], [8, 1]]  # per wait-state region
const SRAM_WAITS  = [4, 3, 2, 8]

proc update_waitcnt*(bus: Bus; w: WAITCNT) =
  # Constant non-ROM timings
  for page in 0 .. 7:
    bus.wait16_n[page] = int8(ACCESS_TIMING_TABLE[0][page])
    bus.wait16_s[page] = int8(ACCESS_TIMING_TABLE[0][page])
    bus.wait32_n[page] = int8(ACCESS_TIMING_TABLE[1][page])
    bus.wait32_s[page] = int8(ACCESS_TIMING_TABLE[1][page])
  let n_first = [int(w.wait_state_0_first_access),
                 int(w.wait_state_1_first_access),
                 int(w.wait_state_2_first_access)]
  let n_second = [int(w.wait_state_0_second_access),
                  int(w.wait_state_1_second_access),
                  int(w.wait_state_2_second_access)]
  for ws in 0 .. 2:
    let n = ROM_N_WAITS[n_first[ws]] + 1
    let s = ROM_S_WAITS[ws][n_second[ws]] + 1
    for page in [8 + ws * 2, 9 + ws * 2]:
      bus.wait16_n[page] = int8(n)
      bus.wait16_s[page] = int8(s)
      bus.wait32_n[page] = int8(n + s)  # nonseq first half + seq second half
      bus.wait32_s[page] = int8(s + s)
  let sram = int8(SRAM_WAITS[int(w.sram_wait_control)] + 1)
  for page in [0xE, 0xF]:
    bus.wait16_n[page] = sram
    bus.wait16_s[page] = sram
    bus.wait32_n[page] = sram
    bus.wait32_s[page] = sram
  bus.prefetch_on = w.gamepack_prefetch_buffer

proc bus_now(bus: Bus): CycleCount {.inline.} =
  bus.sched.cycles + CycleCount(bus.cycles)

proc rom_cool*(bus: Bus) {.inline.} =
  # End an unbroken fetch stream: while hot, no cycles can have been added
  # by anything except the stream itself, so "now" is exactly when the ROM
  # bus went idle.
  if bus.rom_hot:
    bus.rom_hot = false
    bus.rom_free_since = bus.bus_now()

proc add_cycles*(bus: Bus; n: int) {.inline.} =
  ## All cycle consumers outside the bus (I-cycles, pipeline refills, HLE
  ## costs) must go through this so the ROM fetch-stream bookkeeping stays
  ## consistent.
  bus.rom_cool()
  bus.cycles += n

proc rom_access_cycles(bus: Bus; address: uint32; is32: bool; fetch: bool): int {.inline.} =
  ## Cycle cost of a ROM-region (pages 8-D) access, tracking burst
  ## sequentiality and the prefetch buffer. Sequential = the address
  ## continues the previous ROM access; with the prefetch buffer off the
  ## burst additionally breaks whenever the CPU spent cycles off the ROM bus.
  let page = int(bits_range(address, 24, 27))
  let now = bus.bus_now()
  let contiguous = now == bus.rom_free_since
  var seq: bool
  if bus.dma_active:
    # DMA: src and dst streams each keep their own burst; no back-to-back
    # requirement. LRU pair of trackers handles the interleaving. An access
    # immediately following another ROM access (e.g. the write of a
    # ROM-to-ROM transfer right after its read) is also sequential-timed:
    # the ROM bus is still hot.
    if address == bus.rom_next_addr:
      seq = true
    elif address == bus.rom_next_addr2:
      seq = true
      bus.rom_next_addr2 = bus.rom_next_addr
      bus.rom_next_addr = address  # promoted; advanced below
    elif contiguous:
      seq = true
      bus.rom_next_addr2 = bus.rom_next_addr
      bus.rom_next_addr = address
    else:
      seq = false
      bus.rom_next_addr2 = bus.rom_next_addr
      bus.rom_next_addr = address
  else:
    seq = address == bus.rom_next_addr and (bus.prefetch_on or contiguous)
  var cost: int
  var new_free_since: CycleCount
  if seq:
    if fetch and bus.prefetch_on and not contiguous:
      # Prefetch hit: the buffer worked ahead while the ROM bus was free,
      # one halfword per S-access time (buffer holds up to 8 halfwords).
      # Leftover credit carries over to the next fetch, so back-to-back
      # buffer hits stay cheap until the buffer drains.
      # rom_free_since can sit ahead of `now`: the waitloop fast-forward
      # discards a partial instruction's cycles after bookkeeping already
      # anticipated them. Unsigned subtraction would wrap (and crashed
      # Pokémon FireRed with a RangeDefect); treat it as zero credit.
      let s = int(bus.wait16_s[page])
      let credit = if now > bus.rom_free_since:
                     min(int(now - bus.rom_free_since), 8 * s)
                   else: 0
      let need = if is32: 2 * s else: s
      cost = max(1, need - credit)  # a full buffer serves even a 32-bit fetch in one cycle
      let done = now + CycleCount(cost)
      let floor = if done > CycleCount(8 * s): done - CycleCount(8 * s) else: 0
      new_free_since = max(bus.rom_free_since + CycleCount(need), floor)
    else:
      cost = int(if is32: bus.wait32_s[page] else: bus.wait16_s[page])
      new_free_since = now + CycleCount(cost)
  else:
    cost = int(if is32: bus.wait32_n[page] else: bus.wait16_n[page])
    new_free_since = now + CycleCount(cost)
  bus.rom_next_addr = address + (if is32: 4'u32 else: 2'u32)
  bus.rom_free_since = new_free_since
  cost

proc access_cycles(bus: Bus; address: uint32; is32: bool; fetch: bool): int {.inline.} =
  let page = int(bits_range(address, 24, 27))
  if page >= 0x8:
    if page <= 0xD:
      bus.rom_access_cycles(address, is32, fetch)
    else:
      int(bus.wait16_n[page])  # SRAM: 8-bit bus, same cost either way
  else:
    ACCESS_TIMING_TABLE[int(is32)][page]

proc write_stub_u32(bios: var seq[byte]; offset: int; value: uint32) =
  bios[offset + 0] = byte(value)
  bios[offset + 1] = byte(value shr 8)
  bios[offset + 2] = byte(value shr 16)
  bios[offset + 3] = byte(value shr 24)

proc new_bus*(gba: GBA; bios_path: string): Bus =
  result = Bus(gba: gba)
  result.sched = gba.scheduler
  result.cycles = 0
  result.fetch_page = 0xFFFFFFFF'u32  # no fetch page cached yet
  result.bios       = newSeq[byte](0x4000)
  result.wram_board = newSeq[byte](0x40000)
  result.wram_chip  = newSeq[byte](0x08000)
  if bios_path != "" and fileExists(bios_path):
    let f = open(bios_path, fmRead)
    discard f.readBytes(result.bios, 0, result.bios.len)
    f.close()
  else:
    # Minimal BIOS stub: IRQ vector at 0x18 branches to the handler at 0x128
    # (matching the real BIOS layout, so IRQ dispatch costs the same 3-cycle
    # branch) which dispatches to the user handler at [0x03FFFFFC].
    #   0x018: b 0x128                        EA000042
    #   0x128: stmfd sp!, {r0-r3, r12, lr}   E92D500F
    #   0x12C: mov   r0, #0x04000000          E3A00301
    #   0x130: add   lr, pc, #0               E28FE000
    #   0x134: ldr   pc, [r0, #-4]            E510F004
    #   0x138: ldmfd sp!, {r0-r3, r12, lr}    E8BD500F
    #   0x13C: subs  pc, lr, #4               E25EF004
    write_stub_u32(result.bios, 0x018, 0xEA000042'u32)
    write_stub_u32(result.bios, 0x128, 0xE92D500F'u32)
    write_stub_u32(result.bios, 0x12C, 0xE3A00301'u32)
    write_stub_u32(result.bios, 0x130, 0xE28FE000'u32)
    write_stub_u32(result.bios, 0x134, 0xE510F004'u32)
    write_stub_u32(result.bios, 0x138, 0xE8BD500F'u32)
    write_stub_u32(result.bios, 0x13C, 0xE25EF004'u32)
    # Never executed: the two words after the IRQ return, so the two-ahead
    # pipeline latch reads the same values as the real BIOS leaves
    write_stub_u32(result.bios, 0x140, 0xE92D5800'u32)
    write_stub_u32(result.bios, 0x144, 0xE55EC002'u32)
  result.gpio = new_gpio(gba)
  result.update_waitcnt(WAITCNT())  # reset-state waitstates

proc bus_page(address: uint32): int {.inline.} =
  int(bits_range(address, 24, 27))

# ---- low-level pointer reads ----

proc read_u16_ptr(buf: seq[byte]; offset: uint32): uint16 {.inline.} =
  cast[ptr uint16](unsafeAddr buf[offset])[]

proc read_u32_ptr(buf: seq[byte]; offset: uint32): uint32 {.inline.} =
  cast[ptr uint32](unsafeAddr buf[offset])[]

proc read_u16_ptr_raw(p: ptr UncheckedArray[byte]; offset: uint32): uint16 {.inline.} =
  cast[ptr uint16](addr p[offset])[]

proc read_u32_ptr_raw(p: ptr UncheckedArray[byte]; offset: uint32): uint32 {.inline.} =
  cast[ptr uint32](addr p[offset])[]

proc write_u16_ptr(buf: var seq[byte]; offset: uint32; val: uint16) {.inline.} =
  cast[ptr uint16](addr buf[offset])[] = val

proc write_u32_ptr(buf: var seq[byte]; offset: uint32; val: uint32) {.inline.} =
  cast[ptr uint32](addr buf[offset])[] = val

# ---- internal read implementations ----

proc read_byte_internal*(bus: Bus; address: uint32): uint8 {.inline.} =
  case bits_range(address, 24, 27)
  of 0x0:
    if bits_range(bus.gba.cpu.r[15], 24, 27) == 0:
      bus.bios[address and 0x3FFF'u32]
    else:
      # BIOS reads are latched to last successful read
      # https://rust-console.github.io/gbatek-gbaonly/#reading-from-bios-memory-00000000-00003fff
      let shift = (address and 3) * 8
      uint8(bus.bios_latch shr shift)
  of 0x1: bus.read_open_bus_value(address)
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
  let orig = address
  let address = address and not 1'u32
  case bits_range(address, 24, 27)
  of 0x0:
    if bits_range(bus.gba.cpu.r[15], 24, 27) == 0:
      read_u16_ptr(bus.bios, address and 0x3FFF'u32)
    else:
      # BIOS reads are latched to last successful read
      # https://rust-console.github.io/gbatek-gbaonly/#reading-from-bios-memory-00000000-00003fff
      let shift = (address and 2) * 8
      uint16(bus.bios_latch shr shift)
  of 0x1: uint16(bus.read_open_bus_value(address)) or (uint16(bus.read_open_bus_value(address or 1)) shl 8)
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
  of 0xE, 0xF: bus.gba.storage.read_half(orig)
  else: raise newException(Exception, "Unmapped bus read_half: " & hex_str(address))

proc read_word_internal*(bus: Bus; address: uint32): uint32 {.inline.} =
  let orig = address
  let address = address and not 3'u32
  case bits_range(address, 24, 27)
  of 0x0:
    if bits_range(bus.gba.cpu.r[15], 24, 27) == 0:
      read_u32_ptr(bus.bios, address and 0x3FFF'u32)
    else:
      # BIOS reads are latched to last successful read
      # https://rust-console.github.io/gbatek-gbaonly/#reading-from-bios-memory-00000000-00003fff
      bus.bios_latch
  of 0x1:
    let v = bus.read_open_bus_value(address)
    uint32(v) or (uint32(bus.read_open_bus_value(address or 1)) shl 8) or
    (uint32(bus.read_open_bus_value(address or 2)) shl 16) or
    (uint32(bus.read_open_bus_value(address or 3)) shl 24)
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
  of 0xE, 0xF: bus.gba.storage.read_word(orig)
  else: raise newException(Exception, "Unmapped bus read_word: " & hex_str(address))

when defined(linkTrace):
  # Debug watch (trade-repro harness, -d:linkTrace): fires on any IWRAM write
  # covering `wramWatchOff`. Compiled out entirely in normal builds.
  var onWramChipWrite*: proc(gba: GBA; off: int; val: uint32; width: int) = nil
  var wramWatchOff* = -1
  template chipWatch(bus: Bus; o: uint32; v: uint32; w: int) =
    if onWramChipWrite != nil and wramWatchOff >= 0 and
       int(o) <= wramWatchOff and wramWatchOff < int(o) + w:
      onWramChipWrite(bus.gba, int(o), v, w)
else:
  template chipWatch(bus: Bus; o: uint32; v: uint32; w: int) = discard

proc write_byte_internal*(bus: Bus; address: uint32; value: uint8) =
  if bits_range(address, 28, 31) > 0: return
  if address <= bus.gba.cpu.r[15] and address >= bus.gba.cpu.r[15] - 4:
    bus.gba.cpu.fill_pipeline()
  case bits_range(address, 24, 27)
  of 0x2: bus.wram_board[address and 0x3FFFF'u32] = value
  of 0x3:
    bus.wram_chip[address and 0x7FFF'u32] = value
    chipWatch(bus, address and 0x7FFF'u32, uint32(value), 1)
  of 0x4: bus.gba.mmio[address] = value
  of 0x5:
    bus.gba.ppu.render_dirty = true
    write_u16_ptr(bus.gba.ppu.pram, address and 0x3FE'u32, 0x0101'u16 * uint16(value))
  of 0x6:
    let limit: uint32 = if bus.gba.ppu.bitmap(): 0x13FFF'u32 else: 0x0FFFF'u32
    var a = 0x1FFFE'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    if a <= limit:
      bus.gba.ppu.render_dirty = true
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
  let orig = address
  let address = address and not 1'u32
  if address <= bus.gba.cpu.r[15] and address >= bus.gba.cpu.r[15] - 4:
    bus.gba.cpu.fill_pipeline()
  case bits_range(address, 24, 27)
  of 0x2: write_u16_ptr(bus.wram_board, address and 0x3FFFF'u32, value)
  of 0x3:
    write_u16_ptr(bus.wram_chip, address and 0x7FFF'u32, value)
    chipWatch(bus, address and 0x7FFF'u32, uint32(value), 2)
  of 0x4:
    bus.write_byte_internal(address, uint8(value))
    bus.write_byte_internal(address + 1, uint8(value shr 8))
  of 0x5:
    bus.gba.ppu.render_dirty = true
    write_u16_ptr(bus.gba.ppu.pram, address and 0x3FF'u32, value)
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    bus.gba.ppu.render_dirty = true
    write_u16_ptr(bus.gba.ppu.vram, a, value)
  of 0x7:
    bus.gba.ppu.render_dirty = true
    write_u16_ptr(bus.gba.ppu.oam, address and 0x3FF'u32, value)
  of 0x8, 0xD:
    if address_in_gpio(address):
      bus.gpio[address] = uint8(value)
    elif bus.gba.storage.eeprom_at(address):
      bus.gba.storage[address] = uint8(value)
  of 0xE, 0xF:
    bus.gba.storage[orig] = uint8(value)
  else: log("Unmapped write half: " & hex_str(address))

proc write_word_internal*(bus: Bus; address: uint32; value: uint32) =
  if bits_range(address, 28, 31) > 0: return
  let orig = address
  let address = address and not 3'u32
  if address <= bus.gba.cpu.r[15] and address >= bus.gba.cpu.r[15] - 4:
    bus.gba.cpu.fill_pipeline()
  case bits_range(address, 24, 27)
  of 0x2: write_u32_ptr(bus.wram_board, address and 0x3FFFF'u32, value)
  of 0x3:
    write_u32_ptr(bus.wram_chip, address and 0x7FFF'u32, value)
    chipWatch(bus, address and 0x7FFF'u32, value, 4)
  of 0x4:
    bus.write_byte_internal(address,     uint8(value))
    bus.write_byte_internal(address + 1, uint8(value shr 8))
    bus.write_byte_internal(address + 2, uint8(value shr 16))
    bus.write_byte_internal(address + 3, uint8(value shr 24))
  of 0x5:
    bus.gba.ppu.render_dirty = true
    write_u32_ptr(bus.gba.ppu.pram, address and 0x3FF'u32, value)
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    bus.gba.ppu.render_dirty = true
    write_u32_ptr(bus.gba.ppu.vram, a, value)
  of 0x7:
    bus.gba.ppu.render_dirty = true
    write_u32_ptr(bus.gba.ppu.oam, address and 0x3FF'u32, value)
  of 0x8, 0xD:
    if address_in_gpio(address):
      bus.gpio[address] = uint8(value)
    elif bus.gba.storage.eeprom_at(address):
      bus.gba.storage[address] = uint8(value)
  of 0xE, 0xF:
    bus.gba.storage[orig] = uint8(value)
  else: log("Unmapped write word: " & hex_str(address))

# ---- Instruction-fetch fast path ----

proc install_fetch_cache(bus: Bus; page: uint32): bool =
  # Only pages whose fetches are plain masked memory reads are cacheable.
  # BIOS (latch + PC checks), MMIO, open bus, and 0xD (possible EEPROM
  # mapping) always take the generic path.
  case page
  of 0x2:
    bus.fetch_ptr = cast[ptr UncheckedArray[byte]](addr bus.wram_board[0])
    bus.fetch_mask = 0x3FFFF'u32
  of 0x3:
    bus.fetch_ptr = cast[ptr UncheckedArray[byte]](addr bus.wram_chip[0])
    bus.fetch_mask = 0x7FFF'u32
  of 0x8, 0x9, 0xA, 0xB, 0xC:
    bus.fetch_ptr = cast[ptr UncheckedArray[byte]](addr bus.gba.cartridge.rom[0])
    bus.fetch_mask = 0x01FFFFFF'u32
  else:
    return false
  bus.fetch_page = page
  bus.fetch_c16 = ACCESS_TIMING_TABLE[0][int(page)]
  bus.fetch_c32 = ACCESS_TIMING_TABLE[1][int(page)]
  true

proc fetch_half*(bus: Bus; address: uint32): uint16 {.inline.} =
  let page = bits_range(address, 24, 27)
  if page == bus.fetch_page or bus.install_fetch_cache(page):
    if page >= 0x8:
      # Straight-line execution fast path: while the fetch stream is hot
      # (unbroken), a sequential fetch is a plain S access and needs no
      # absolute-time bookkeeping at all
      if bus.rom_hot and address == bus.rom_next_addr:
        bus.cycles += int(bus.wait16_s[page])
        bus.rom_next_addr = address + 2
      else:
        bus.rom_cool()
        bus.cycles += bus.rom_access_cycles(address, is32 = false, fetch = true)
        # Go hot only when no prefetch credit is left over; leftover credit
        # must keep flowing through the slow path to be consumed
        if bus.rom_free_since == bus.bus_now(): bus.rom_hot = true
    else:
      bus.cycles += bus.fetch_c16
    read_u16_ptr_raw(bus.fetch_ptr, (address and bus.fetch_mask) and not 1'u32)
  else:
    bus.read_half(address)

proc fetch_word*(bus: Bus; address: uint32): uint32 {.inline.} =
  let page = bits_range(address, 24, 27)
  if page == bus.fetch_page or bus.install_fetch_cache(page):
    if page >= 0x8:
      if bus.rom_hot and address == bus.rom_next_addr:
        bus.cycles += int(bus.wait32_s[page])
        bus.rom_next_addr = address + 4
      else:
        bus.rom_cool()
        bus.cycles += bus.rom_access_cycles(address, is32 = true, fetch = true)
        if bus.rom_free_since == bus.bus_now(): bus.rom_hot = true
    else:
      bus.cycles += bus.fetch_c32
    read_u32_ptr_raw(bus.fetch_ptr, (address and bus.fetch_mask) and not 3'u32)
  else:
    bus.read_word(address)

# ---- Public read/write with cycle accounting ----

proc catch_up_slow(bus: Bus) =
  # Loops because a fired event can itself consume bus time (a DMA stalling
  # the CPU) that must also be ticked before the access observes the clock.
  while bus.cycles > 0:
    let pending = bus.cycles
    bus.cycles = 0
    bus.synced += pending
    bus.gba.scheduler.tick(pending)

proc catch_up(bus: Bus) {.inline.} =
  # Advance the scheduler to the current mid-instruction cycle so MMIO
  # accesses observe/affect timers, IF flags, etc. at the exact cycle they
  # happen. Skipped while an event handler runs (handlers must stay pure so
  # the DMA pump, which runs after dispatch, arbitrates all deferred work).
  # The accessors below additionally skip it while a DMA burst runs
  # (dma_active): a transfer must not be preempted between its read and
  # write — the DMA loop drains due events at transfer boundaries instead
  # (timer reads stay exact regardless: get_current_tm includes bus.cycles).
  # The common no-event-due case stays inline; event dispatch takes the
  # slow path.
  let s = bus.sched
  if s.dispatching: return
  let target = s.cycles + CycleCount(bus.cycles)
  if target < s.next_event:
    s.cycles = target
    bus.synced += bus.cycles
    bus.cycles = 0
  else:
    bus.catch_up_slow()

proc `[]`*(bus: Bus; address: uint32): uint8 =
  bus.rom_cool()
  bus.cycles += bus.access_cycles(address, is32 = false, fetch = false)
  if (bus_page(address) == 0x4 or bus.dma_pending) and not bus.dma_active: bus.catch_up()
  bus.read_byte_internal(address)

proc read_half*(bus: Bus; address: uint32): uint16 =
  bus.rom_cool()
  bus.cycles += bus.access_cycles(address, is32 = false, fetch = false)
  if (bus_page(address) == 0x4 or bus.dma_pending) and not bus.dma_active: bus.catch_up()
  bus.read_half_internal(address)

proc read_word*(bus: Bus; address: uint32): uint32 =
  bus.rom_cool()
  bus.cycles += bus.access_cycles(address, is32 = true, fetch = false)
  if (bus_page(address) == 0x4 or bus.dma_pending) and not bus.dma_active: bus.catch_up()
  bus.read_word_internal(address)

proc `[]=`*(bus: Bus; address: uint32; value: uint8) =
  bus.rom_cool()
  bus.cycles += bus.access_cycles(address, is32 = false, fetch = false)
  if (bus_page(address) == 0x4 or bus.dma_pending) and not bus.dma_active: bus.catch_up()
  bus.write_byte_internal(address, value)

proc write_half*(bus: Bus; address: uint32; value: uint16) =
  bus.rom_cool()
  bus.cycles += bus.access_cycles(address, is32 = false, fetch = false)
  if (bus_page(address) == 0x4 or bus.dma_pending) and not bus.dma_active: bus.catch_up()
  bus.write_half_internal(address, value)

proc write_word*(bus: Bus; address: uint32; value: uint32) =
  bus.rom_cool()
  bus.cycles += bus.access_cycles(address, is32 = true, fetch = false)
  if (bus_page(address) == 0x4 or bus.dma_pending) and not bus.dma_active: bus.catch_up()
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
  # Guard: if PC is in MMIO, unmapped memory, or otherwise unreadable, avoid
  # infinite recursion (region 0x1 reads recurse back into this proc)
  let pc_region = bits_range(pc, 24, 27)
  if pc_region == 0x1 or pc_region == 0x4 or pc_region > 0xD:
    return 0'u8
  let word: uint32 =
    if bus.gba.cpu.cpsr.thumb:
      let opcode = uint32(bus.read_half_internal(pc and not 1'u32))
      (opcode shl 16) or opcode
    else:
      bus.read_word_internal(pc and not 3'u32)
  uint8(word shr shift)
