# EEPROM storage implementation (included by gba.nim)

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
  if length <= 6: eeprom4k else: eeprom64k

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
  return 1'u8

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
    ep.wrote_bits += 1
    if ep.wrote_bits == 64:
      ep.buffer.clear()
      ep.wrote_bits = 0
      ep.state = {esReady, esWriteFinalBit}
  elif esWriteFinalBit in ep.state:
    ep.buffer.clear()
    ep.state.excl(esWriteFinalBit)
