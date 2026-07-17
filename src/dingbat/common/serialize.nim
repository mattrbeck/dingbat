# Hand-rolled binary save-state serialization: a little-endian Writer/Reader
# pair plus the .state file header. Every field is written explicitly per
# subsystem (no std/marshal — it's JSON + refs and not stable across builds).

import std/os

type
  StateError* = object of CatchableError

  CoreKind* = enum
    ckGBA = 0
    ckGB  = 1

  Writer* = object
    buf*: string

  Reader* = object
    buf*: string
    pos*: int

const
  STATE_MAGIC*   = "DGBSTATE"  # 8 bytes
  STATE_VERSION* = 4'u32  # v4: GB serial port state (link cable support)
  # magic(8) version(4) core(1) slot(1) reserved(2) rom_checksum(4)
  # rom_size(4) payload_len(4) payload_hash(4)
  STATE_HEADER_SIZE* = 32

proc state_error(msg: string): ref StateError =
  newException(StateError, msg)

# ==================== Writer ====================

proc write_u8*(w: var Writer; v: uint8) {.inline.} =
  w.buf.add(char(v))

proc write_bool*(w: var Writer; v: bool) {.inline.} =
  w.write_u8(if v: 1'u8 else: 0'u8)

proc write_u16*(w: var Writer; v: uint16) {.inline.} =
  w.write_u8(uint8(v))
  w.write_u8(uint8(v shr 8))

proc write_u32*(w: var Writer; v: uint32) {.inline.} =
  for i in 0 .. 3: w.write_u8(uint8(v shr (8 * i)))

proc write_u64*(w: var Writer; v: uint64) {.inline.} =
  for i in 0 .. 7: w.write_u8(uint8(v shr (8 * i)))

proc write_i8*(w: var Writer; v: int8) {.inline.} = w.write_u8(cast[uint8](v))
proc write_i16*(w: var Writer; v: int16) {.inline.} = w.write_u16(cast[uint16](v))
proc write_i32*(w: var Writer; v: int32) {.inline.} = w.write_u32(cast[uint32](v))
proc write_int*(w: var Writer; v: int) {.inline.} = w.write_u64(cast[uint64](int64(v)))

proc write_bytes*(w: var Writer; data: openArray[byte]) =
  ## Raw bytes, no length prefix (fixed-size buffers)
  if data.len > 0:
    let start = w.buf.len
    w.buf.setLen(start + data.len)
    copyMem(addr w.buf[start], unsafeAddr data[0], data.len)

proc write_seq_u8*(w: var Writer; data: openArray[byte]) =
  ## Length-prefixed bytes (variable-size buffers)
  w.write_u32(uint32(data.len))
  w.write_bytes(data)

proc write_seq_u16*(w: var Writer; data: openArray[uint16]) =
  w.write_u32(uint32(data.len))
  for v in data: w.write_u16(v)

proc write_tag*(w: var Writer; tag: uint8) {.inline.} =
  ## Section marker, validated on read to catch format desyncs early
  w.write_u8(tag)

# ==================== Reader ====================

proc remaining(r: Reader): int {.inline.} =
  r.buf.len - r.pos

proc need(r: Reader; n: int) {.inline.} =
  if r.remaining < n:
    raise state_error("truncated state data")

proc read_u8*(r: var Reader): uint8 =
  r.need(1)
  result = uint8(r.buf[r.pos])
  inc r.pos

proc read_bool*(r: var Reader): bool =
  r.read_u8() != 0

proc read_u16*(r: var Reader): uint16 =
  uint16(r.read_u8()) or (uint16(r.read_u8()) shl 8)

proc read_u32*(r: var Reader): uint32 =
  for i in 0 .. 3: result = result or (uint32(r.read_u8()) shl (8 * i))

proc read_u64*(r: var Reader): uint64 =
  for i in 0 .. 7: result = result or (uint64(r.read_u8()) shl (8 * i))

proc read_i8*(r: var Reader): int8 = cast[int8](r.read_u8())
proc read_i16*(r: var Reader): int16 = cast[int16](r.read_u16())
proc read_i32*(r: var Reader): int32 = cast[int32](r.read_u32())
proc read_int*(r: var Reader): int = int(cast[int64](r.read_u64()))

proc read_bytes*(r: var Reader; dest: var openArray[byte]) =
  ## Fills dest exactly (fixed-size buffers)
  if dest.len > 0:
    r.need(dest.len)
    copyMem(addr dest[0], unsafeAddr r.buf[r.pos], dest.len)
    r.pos += dest.len

proc read_seq_u8*(r: var Reader): seq[byte] =
  let n = int(r.read_u32())
  r.need(n)
  result = newSeq[byte](n)
  r.read_bytes(result)

proc read_seq_u16_into*(r: var Reader; dest: var openArray[uint16]) =
  let n = int(r.read_u32())
  if n != dest.len:
    raise state_error("state buffer size mismatch")
  for i in 0 ..< n: dest[i] = r.read_u16()

proc expect_tag*(r: var Reader; tag: uint8) =
  let got = r.read_u8()
  if got != tag:
    raise state_error("state section marker mismatch (corrupt or incompatible state)")

# ==================== Hashing ====================

proc fnv1a*(data: openArray[byte]): uint32 =
  result = 0x811C9DC5'u32
  for b in data:
    result = (result xor uint32(b)) * 0x01000193'u32

proc fnv1a*(data: string): uint32 =
  fnv1a(toOpenArrayByte(data, 0, data.high))

# ==================== State file header ====================

proc make_state_bytes*(core: CoreKind; rom_checksum, rom_size: uint32;
                       payload: string): string =
  ## Full state-file image (header + payload) as bytes, for file storage or
  ## in-memory transports (web IndexedDB, downloads)
  var w = Writer()
  w.buf.add(STATE_MAGIC)
  w.write_u32(STATE_VERSION)
  w.write_u8(uint8(core))
  w.write_u8(0'u8)   # slot (reserved for future multi-slot support)
  w.write_u16(0'u16) # reserved flags
  w.write_u32(rom_checksum)
  w.write_u32(rom_size)
  w.write_u32(uint32(payload.len))
  w.write_u32(fnv1a(payload))
  w.buf.add(payload)
  w.buf

proc write_state_file*(path: string; core: CoreKind;
                       rom_checksum, rom_size: uint32; payload: string) =
  let parent = path.parentDir
  if parent.len > 0:
    createDir(parent)
  writeFile(path, make_state_bytes(core, rom_checksum, rom_size, payload))

proc parse_state_payload*(data: string; core: CoreKind;
                          rom_checksum, rom_size: uint32;
                          origin = "state data"): string =
  ## Validates the header of a full state image and returns the payload;
  ## raises StateError with a human-readable message on any mismatch.
  if data.len < STATE_HEADER_SIZE or data[0 ..< STATE_MAGIC.len] != STATE_MAGIC:
    raise state_error("not a dingbat save state: " & origin)
  var r = Reader(buf: data, pos: STATE_MAGIC.len)
  let version = r.read_u32()
  if version != STATE_VERSION:
    raise state_error("save state format version " & $version &
                      " not supported (expected " & $STATE_VERSION & ")")
  let file_core = r.read_u8()
  discard r.read_u8()   # slot
  discard r.read_u16()  # reserved
  if file_core != uint8(core):
    raise state_error("save state was created by a different core (GBA/GB mismatch)")
  let file_checksum = r.read_u32()
  let file_rom_size = r.read_u32()
  if file_checksum != rom_checksum or file_rom_size != rom_size:
    raise state_error("save state belongs to a different ROM")
  let payload_len = int(r.read_u32())
  let payload_hash = r.read_u32()
  if data.len - STATE_HEADER_SIZE != payload_len:
    raise state_error("save state is truncated or corrupt")
  result = data[STATE_HEADER_SIZE ..< STATE_HEADER_SIZE + payload_len]
  if fnv1a(result) != payload_hash:
    raise state_error("save state payload hash mismatch (corrupt file)")

proc read_state_payload*(path: string; core: CoreKind;
                         rom_checksum, rom_size: uint32): string =
  if not fileExists(path):
    raise state_error("no save state found at " & path)
  parse_state_payload(readFile(path), core, rom_checksum, rom_size, path)
