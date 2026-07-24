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
  STATE_VERSION* = 5'u32  # v5: HLE BIOS IntrWait/Halt keep the dispatcher's
                          # System-stack frame live (sp sits 16/8 bytes lower
                          # while halted); v4 mid-halt states would resume with
                          # a mis-restored sp, so they are refused instead.
                          # (v4: GB serial port state, link cable support)
  # magic(8) version(4) core(1) slot(1) flags(2) rom_checksum(4)
  # rom_size(4) payload_len(4) payload_hash(4)
  STATE_HEADER_SIZE* = 32
  # Optional trailer after the payload, flagged in the header's flags field.
  # It lives OUTSIDE the hash-validated payload so the per-subsystem serializers
  # are untouched; readers that don't know about it slice by payload_len and
  # ignore the extra bytes. Layout: thumb_w(2) thumb_h(2) len(4) BGR555 pixels.
  STATE_FLAG_THUMBNAIL* = 0x0001'u16

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

# ==================== Bidirectional visitors ====================
#
# Each subsystem's save and load used to be two hand-mirrored procs listing
# every field twice. That is the shape where a field added to save but not to
# load silently corrupts states, so instead a subsystem now describes its
# layout ONCE as a generic `visit_x[S](obj; s: var S)` and is instantiated
# with S = Writer to save and S = Reader to load. The overload pairs below are
# what makes one body do both; they are exact inverses by construction, and
# the wire bytes are unchanged from the hand-written versions.
#
# Naming:
#   visit_u8/u16/u32/u64/i32  store through that wire width, CONVERTING (use
#                             when the field's in-memory type is wider, e.g.
#                             an `int` field stored as i32)
#   visit_bits16/bits32       store a same-sized value by CAST, for packed
#                             register objects and for signed fields whose
#                             bit pattern must survive round-tripping
#   visit_bool/bytes/seq_u16/tag  as their write_*/read_* counterparts
#
# Load-only fixups (invalidating caches, resetting per-frame scratch) go in
# the shared body under `when S is Reader:`.

proc visit_bool*(w: var Writer; v: var bool) {.inline.} = w.write_bool(v)
proc visit_bool*(r: var Reader; v: var bool) {.inline.} = v = r.read_bool()

proc visit_u8*[T](w: var Writer; v: var T) {.inline.} = w.write_u8(uint8(v))
proc visit_u8*[T](r: var Reader; v: var T) {.inline.} = v = T(r.read_u8())

proc visit_u16*[T](w: var Writer; v: var T) {.inline.} = w.write_u16(uint16(v))
proc visit_u16*[T](r: var Reader; v: var T) {.inline.} = v = T(r.read_u16())

proc visit_u32*[T](w: var Writer; v: var T) {.inline.} = w.write_u32(uint32(v))
proc visit_u32*[T](r: var Reader; v: var T) {.inline.} = v = T(r.read_u32())

proc visit_u64*[T](w: var Writer; v: var T) {.inline.} = w.write_u64(uint64(v))
proc visit_u64*[T](r: var Reader; v: var T) {.inline.} = v = T(r.read_u64())

proc visit_i32*[T](w: var Writer; v: var T) {.inline.} = w.write_i32(int32(v))
proc visit_i32*[T](r: var Reader; v: var T) {.inline.} = v = T(r.read_i32())

proc visit_i8*(w: var Writer; v: var int8) {.inline.} = w.write_i8(v)
proc visit_i8*(r: var Reader; v: var int8) {.inline.} = v = r.read_i8()

proc visit_i16*(w: var Writer; v: var int16) {.inline.} = w.write_i16(v)
proc visit_i16*(r: var Reader; v: var int16) {.inline.} = v = r.read_i16()

# bits16/bits32 reinterpret rather than convert, so T must genuinely be that
# width — every caller passes a {.packed.} 16/32-bit register object or a
# same-width signed scalar. (sizeof(T) can't be asserted here: Nim won't
# evaluate it at compile time for a packed object behind a generic param.)
proc visit_bits16*[T](w: var Writer; v: var T) {.inline.} = w.write_u16(cast[uint16](v))
proc visit_bits16*[T](r: var Reader; v: var T) {.inline.} = v = cast[T](r.read_u16())

proc visit_bits32*[T](w: var Writer; v: var T) {.inline.} = w.write_u32(cast[uint32](v))
proc visit_bits32*[T](r: var Reader; v: var T) {.inline.} = v = cast[T](r.read_u32())

proc visit_bytes*(w: var Writer; d: var openArray[byte]) {.inline.} = w.write_bytes(d)
proc visit_bytes*(r: var Reader; d: var openArray[byte]) {.inline.} = r.read_bytes(d)

proc visit_seq_u16*(w: var Writer; d: var openArray[uint16]) {.inline.} = w.write_seq_u16(d)
proc visit_seq_u16*(r: var Reader; d: var openArray[uint16]) {.inline.} = r.read_seq_u16_into(d)

proc visit_tag*(w: var Writer; tag: uint8) {.inline.} = w.write_tag(tag)
proc visit_tag*(r: var Reader; tag: uint8) {.inline.} = r.expect_tag(tag)

# ==================== Hashing ====================

proc fnv1a*(data: openArray[byte]): uint32 =
  result = 0x811C9DC5'u32
  for b in data:
    result = (result xor uint32(b)) * 0x01000193'u32

proc fnv1a*(data: string): uint32 =
  fnv1a(toOpenArrayByte(data, 0, data.high))

# ==================== State file header ====================

proc write_state_header(w: var Writer; core: CoreKind;
                        rom_checksum, rom_size: uint32;
                        payload: string; flags: uint16) =
  w.buf.add(STATE_MAGIC)
  w.write_u32(STATE_VERSION)
  w.write_u8(uint8(core))
  w.write_u8(0'u8)   # slot (reserved for future multi-slot support)
  w.write_u16(flags)
  w.write_u32(rom_checksum)
  w.write_u32(rom_size)
  w.write_u32(uint32(payload.len))
  w.write_u32(fnv1a(payload))
  w.buf.add(payload)

proc make_state_bytes*(core: CoreKind; rom_checksum, rom_size: uint32;
                       payload: string): string =
  ## Full state-file image (header + payload) as bytes, for file storage or
  ## in-memory transports (web IndexedDB, downloads)
  var w = Writer()
  write_state_header(w, core, rom_checksum, rom_size, payload, 0'u16)
  w.buf

proc make_state_bytes*(core: CoreKind; rom_checksum, rom_size: uint32;
                       payload: string; thumbnail: openArray[byte];
                       thumb_w, thumb_h: uint16): string =
  ## As above, plus a thumbnail trailer (BGR555 pixels, thumb_w*thumb_h) after
  ## the payload. The trailer is outside the hash-validated payload; old readers
  ## ignore it. Falls back to a plain image if the thumbnail is empty/degenerate.
  let has_thumb = thumbnail.len == int(thumb_w) * int(thumb_h) * 2 and
                  thumb_w > 0'u16 and thumb_h > 0'u16
  let flags = if has_thumb: STATE_FLAG_THUMBNAIL else: 0'u16
  var w = Writer()
  write_state_header(w, core, rom_checksum, rom_size, payload, flags)
  if has_thumb:
    w.write_u16(thumb_w)
    w.write_u16(thumb_h)
    w.write_seq_u8(thumbnail)   # u32 length prefix + raw BGR555 bytes
  w.buf

proc write_state_file*(path: string; core: CoreKind;
                       rom_checksum, rom_size: uint32; payload: string) =
  let parent = path.parentDir
  if parent.len > 0:
    createDir(parent)
  writeFile(path, make_state_bytes(core, rom_checksum, rom_size, payload))

proc write_state_file*(path: string; core: CoreKind;
                       rom_checksum, rom_size: uint32; payload: string;
                       thumbnail: openArray[byte]; thumb_w, thumb_h: uint16) =
  let parent = path.parentDir
  if parent.len > 0:
    createDir(parent)
  writeFile(path, make_state_bytes(core, rom_checksum, rom_size, payload,
                                   thumbnail, thumb_w, thumb_h))

proc downscale_bgr555*(src: openArray[uint16]; src_w, src_h, dst_w, dst_h: int): seq[byte] =
  ## Nearest-neighbor downscale of a BGR555 framebuffer, returned as
  ## little-endian BGR555 bytes (2 per pixel) — the same pixel format the
  ## thumbnail trailer stores. Cheap and on-demand (never on the hot path).
  result = newSeq[byte](dst_w * dst_h * 2)
  if src_w <= 0 or src_h <= 0 or dst_w <= 0 or dst_h <= 0: return
  for y in 0 ..< dst_h:
    let sy = y * src_h div dst_h
    for x in 0 ..< dst_w:
      let sx = x * src_w div dst_w
      let px = src[sy * src_w + sx]
      let o = (y * dst_w + x) * 2
      result[o]     = byte(px and 0xFF)
      result[o + 1] = byte((px shr 8) and 0xFF)

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
  # `<`, not `!=`: an optional trailer (e.g. thumbnail) may follow the payload.
  if data.len - STATE_HEADER_SIZE < payload_len:
    raise state_error("save state is truncated or corrupt")
  result = data[STATE_HEADER_SIZE ..< STATE_HEADER_SIZE + payload_len]
  if fnv1a(result) != payload_hash:
    raise state_error("save state payload hash mismatch (corrupt file)")

proc parse_state_thumbnail*(data: string): tuple[w, h: int; pixels: seq[byte]] =
  ## Extracts the optional thumbnail trailer (BGR555 pixels). Returns (0,0,@[])
  ## if absent, and is fully defensive — it never raises, so a malformed trailer
  ## can't break state loading or a thumbnail grid.
  result = (0, 0, @[])
  if data.len < STATE_HEADER_SIZE or data[0 ..< STATE_MAGIC.len] != STATE_MAGIC:
    return
  let flags = uint16(byte(data[14])) or (uint16(byte(data[15])) shl 8)
  if (flags and STATE_FLAG_THUMBNAIL) == 0:
    return
  try:
    var hr = Reader(buf: data, pos: 24)   # payload_len field
    let payload_len = int(hr.read_u32())
    var r = Reader(buf: data, pos: STATE_HEADER_SIZE + payload_len)
    let tw = int(r.read_u16())
    let th = int(r.read_u16())
    let pixels = r.read_seq_u8()
    if tw > 0 and th > 0 and pixels.len == tw * th * 2:
      result = (tw, th, pixels)
  except CatchableError:
    result = (0, 0, @[])

proc read_state_payload*(path: string; core: CoreKind;
                         rom_checksum, rom_size: uint32): string =
  if not fileExists(path):
    raise state_error("no save state found at " & path)
  parse_state_payload(readFile(path), core, rom_checksum, rom_size, path)
