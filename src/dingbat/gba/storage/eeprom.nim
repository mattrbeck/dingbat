# EEPROM storage implementation (included by gba.nim)

const EEPROM_SETTLE_CYCLES = 115000
  ## Programming time after a write command (~6.9 ms; GBATEK gives ~6.5 ms
  ## max). While settling, the ready-poll read returns 0. Constant matches
  ## mGBA; NanoBoyAdvance uses 101400.

proc eeprom_now(ep: EEPROM): CycleCount {.inline.} =
  # Same expression as bus_now (bus.nim is included after this file)
  ep.gba_ref.bus.sched.cycles + CycleCount(ep.gba_ref.bus.cycles)

proc addr_bits*(sz: EepromSize): int =
  case sz
  of eeprom4k:  6
  of eeprom64k: 14

proc file_size*(sz: EepromSize): int =
  case sz
  of eeprom4k:  0x200
  of eeprom64k: 0x2000

proc eeprom_size_from_file_size*(size: int64): Option[EepromSize] =
  if size > 0:
    if size > 0x200: some(eeprom64k)
    else:            some(eeprom4k)
  else:
    none(EepromSize)

proc eeprom_size_from_dma_length*(length: int): EepromSize =
  ## The first EEPROM command DMA reveals the chip's address width via its
  ## programmed transfer count (each transfer clocks one serial bit):
  ##   4Kbit  (6-bit addr):  read-setup = 2+6+1  = 9,  write = 2+6+64+1  = 73
  ##   64Kbit (14-bit addr): read-setup = 2+14+1 = 17, write = 2+14+64+1 = 81
  ## (Same rule as mGBA/NanoBoyAdvance; anything unexpected defaults to 64Kbit.)
  if length == 9 or length == 73: eeprom4k else: eeprom64k

# EepromBuffer procs
proc push*(buf: var EepromBuffer; value: int) =
  inc buf.size
  buf.value = (buf.value shl 1) or (uint64(value) and 1)

proc shift*(buf: var EepromBuffer): uint64 =
  doAssert buf.size > 0, "Invalid buffer size " & $buf.size
  dec buf.size
  (buf.value shr buf.size) and 1

proc clear*(buf: var EepromBuffer) =
  buf.size = 0
  buf.value = 0

proc set_eeprom_size(ep: EEPROM; sz: Option[EepromSize]) =
  if sz.isSome:
    let s = sz.get
    ep.eeprom_size = sz
    ep.memory = newSeq[byte](s.file_size)
    for i in 0 ..< ep.memory.len:
      ep.memory[i] = 0xFF

proc new_eeprom*(gba: GBA; file_size: int64): EEPROM =
  result = EEPROM(
    state: {esReady},
    address: 0,
    ignored_reads: 0,
    read_bits: 0,
    wrote_bits: 0,
  )
  result.gba_ref = gba
  result.memory = newSeq[byte](0x2000)
  for i in 0 ..< result.memory.len:
    result.memory[i] = 0xFF
  result.set_eeprom_size(eeprom_size_from_file_size(file_size))

method `[]`*(ep: EEPROM; address: uint32): uint8 =
  if esReadIgnore in ep.state:
    ep.ignored_reads += 1
    if ep.ignored_reads == 4:
      ep.state.excl(esReadIgnore)
      ep.read_bits = 0
    return 1'u8
  elif ep.state == {esRead}:
    let base = int(ep.address) * 8 + ep.read_bits div 8
    let value = (ep.memory[base] shr (7 - ep.read_bits and 7)) and 1
    ep.read_bits += 1
    if ep.read_bits == 64:
      ep.state = {esReady}
      ep.buffer.clear()
      ep.read_bits = 0
    return value
  # Ready poll: 0 while a previous write command is still programming the
  # cell (~6.9 ms), 1 once settled (mGBA/NBA model the same busy window)
  return if ep.eeprom_now() < ep.busy_until: 0'u8 else: 1'u8

method `[]=`*(ep: EEPROM; address: uint32; value: uint8) =
  if ep.state == {esRead} or ep.state == {esReadIgnore}:
    return
  let v = int(value and 1)
  ep.buffer.push(v)
  if ep.state == {esReady}:
    if ep.buffer.size == 2:
      case ep.buffer.value
      of 0b10:
        ep.state = {esAddress, esWrite, esWriteFinalBit}
      of 0b11:
        ep.state = {esAddress, esRead, esReadIgnore, esWriteFinalBit}
        ep.ignored_reads = 0
      else: discard
      ep.address = 0
      ep.buffer.clear()
  elif esAddress in ep.state:
    if ep.eeprom_size.isNone:
      ep.set_eeprom_size(some(eeprom_size_from_dma_length(int(ep.gba_ref.dma.dmacnt_l[3]))))
    if ep.buffer.size == ep.eeprom_size.get.addr_bits:
      ep.address = uint32(ep.buffer.value) and 0x3FF'u32
      if esWrite in ep.state:
        cast[ptr UncheckedArray[uint64]](unsafeAddr ep.memory[0])[ep.address] = 0
      ep.state.excl(esAddress)
      ep.buffer.clear()
  elif esWrite in ep.state:
    let base = int(ep.address) * 8 + ep.wrote_bits div 8
    let bit_pos = 7 - (ep.wrote_bits and 7)
    let cur = ep.memory[base]
    let mask = 1'u8 shl bit_pos
    ep.memory[base] = (cur and not mask) or (uint8(v) shl bit_pos)
    ep.dirty = true
    # Each data bit restarts the programming window, so the chip reads busy
    # for EEPROM_SETTLE_CYCLES after the LAST bit (mirrors mGBA's dust timer)
    ep.busy_until = ep.eeprom_now() + EEPROM_SETTLE_CYCLES
    ep.wrote_bits += 1
    if ep.wrote_bits == 64:
      ep.buffer.clear()
      ep.wrote_bits = 0
      ep.state = {esReady, esWriteFinalBit}
  elif esWriteFinalBit in ep.state:
    ep.buffer.clear()
    ep.state.excl(esWriteFinalBit)
