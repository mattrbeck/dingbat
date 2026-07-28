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

  # ---- Container version vs payload revision --------------------------------
  #
  # STATE_VERSION describes the HEADER, not the payloads. It stopped being a
  # "something changed somewhere" counter at v7.
  #
  # v1..v6 were exactly that counter, and it was a bad design: the reader
  # demanded equality, so every bump refused every state every user had, for
  # BOTH cores. All five bumps changed exactly one core's payload and threw the
  # other core's states away for nothing. v6 is the one that did it to Matt:
  # a single Game Boy PPU field invalidated every GBA state in existence, while
  # the GBA payload was byte-for-byte unchanged.
  #
  # From v7 the header carries a PER-CORE payload revision in byte 13 (the old
  # always-zero `slot` field), and each core accepts every revision it knows how
  # to read — see GBA_PAYLOAD_VERSION / GB_PAYLOAD_VERSION and the migrations in
  # the two savestate.nim files. A change to one core's payload now bumps only
  # that core's revision and leaves the other core's states alone.
  #
  # So: do NOT bump STATE_VERSION for a payload change. Bump the core's payload
  # revision and add its migration. STATE_VERSION moves only if this 32-byte
  # header itself changes shape, which also means older builds stop recognising
  # the file — a much bigger decision than it looks.
  STATE_VERSION* = 7'u32

  # Per-core payload revisions. Bump ONE of these when that core's field
  # sequence changes, and add the matching `if rev >= N` in its loader.
  #
  # GBA: 1 initial · 2 CPU halt-wake/deferred-return · 3 bus ROM burst trackers
  #      + deterministic RTC · 4 CPU halt_resume_pop
  # GB:  1 initial · 2 serial port section · 3 PPU dots_since_frame
  GBA_PAYLOAD_VERSION* = 4'u32
  GB_PAYLOAD_VERSION*  = 3'u32

  # magic(8) version(4) core(1) payload_version(1) flags(2) rom_checksum(4)
  # rom_size(4) payload_len(4) payload_hash(4)
  #
  # Byte 13 held `slot`, "reserved for future multi-slot support", and every
  # writer since v1 wrote a literal 0 there (multi-slot ended up in the file
  # NAME, not the header). 0 is therefore free as the "pre-v7, derive it"
  # marker, and revisions start at 1.
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

# ==================== Hashing ====================

proc fnv1a*(data: openArray[byte]): uint32 =
  result = 0x811C9DC5'u32
  for b in data:
    result = (result xor uint32(b)) * 0x01000193'u32

proc fnv1a*(data: string): uint32 =
  fnv1a(toOpenArrayByte(data, 0, data.high))

# ==================== State file header ====================

proc current_payload_version*(core: CoreKind): uint32 =
  ## The revision this build writes for `core`.
  case core
  of ckGBA: GBA_PAYLOAD_VERSION
  of ckGB:  GB_PAYLOAD_VERSION

proc legacy_payload_version*(core: CoreKind; container: uint32): uint32 =
  ## Which payload revision a pre-v7 file holds, derived from the old global
  ## counter. Every container version maps to exactly one layout per core,
  ## confirmed by walking every commit that touched either savestate.nim:
  ##
  ##   container | GBA | GB | what moved
  ##      1      |  1  | 1  | format introduced
  ##      2      |  2  | 1  | GBA CPU halt-wake fields
  ##      3      |  3  | 1  | GBA bus ROM trackers + RTC epoch
  ##      4      |  3  | 2  | GB serial section
  ##      5      |  4  | 2  | GBA CPU halt_resume_pop
  ##      6      |  4  | 3  | GB PPU dots_since_frame
  ##
  ## The one wrinkle: inside container 4 the GB serial section's 5th byte
  ## changed meaning (previous_bit -> clock_history, f678d02) at the same width,
  ## so the LAYOUT is single-valued but that byte's meaning is not. It is the
  ## serial shift-clock edge history, idle (0) in any state not taken mid-link
  ## transfer, and both readings of 0 mean the same thing.
  case core
  of ckGBA:
    if container <= 1: 1'u32
    elif container == 2: 2'u32
    elif container <= 4: 3'u32
    else: 4'u32
  of ckGB:
    if container <= 3: 1'u32
    elif container <= 5: 2'u32
    else: 3'u32

proc write_state_header(w: var Writer; core: CoreKind;
                        rom_checksum, rom_size: uint32;
                        payload: string; flags: uint16) =
  w.buf.add(STATE_MAGIC)
  w.write_u32(STATE_VERSION)
  w.write_u8(uint8(core))
  w.write_u8(uint8(current_payload_version(core)))
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
                          origin = "state data";
                          legacy_checksums: seq[uint32] = @[]):
                         tuple[payload: string; rev: uint32] =
  ## Validates the header of a full state image and returns the payload along
  ## with the payload revision it is written in; raises StateError with a
  ## human-readable message on any mismatch. The caller passes `rev` down to its
  ## per-subsystem loaders, which migrate older layouts (see the two
  ## savestate.nim files) rather than refusing them.
  ##
  ## `legacy_checksums` are ROM identities OLDER builds wrote for *this same
  ## cart* — a value the identity hash used to produce before it was corrected.
  ## They are accepted on read and never written, so a state taken by an older
  ## build keeps loading while everything written from here on carries the
  ## current identity. The caller derives them from the loaded ROM (see
  ## gba_legacy_rom_checksums); an empty seq means "this core's identity has
  ## never moved". Widening acceptance is the whole point: a legacy value is
  ## still a hash of THIS cart, so a state from a different ROM is refused
  ## exactly as before.
  if data.len < STATE_HEADER_SIZE or data[0 ..< STATE_MAGIC.len] != STATE_MAGIC:
    raise state_error("not a dingbat save state: " & origin)
  var r = Reader(buf: data, pos: STATE_MAGIC.len)
  let version = r.read_u32()
  if version > STATE_VERSION:
    # Only refuse the FUTURE. A newer build may have reshaped this 32-byte
    # header, so nothing past the magic can be trusted.
    raise state_error("save state was written by a newer version of dingbat " &
                      "(container " & $version & ", this build reads up to " &
                      $STATE_VERSION & ")")
  let file_core = r.read_u8()
  let file_rev = r.read_u8()
  discard r.read_u16()  # flags (read by parse_state_thumbnail)
  if file_core != uint8(core):
    raise state_error("save state was created by a different core (GBA/GB mismatch)")
  # Byte 13 was the always-zero `slot` field before v7; 0 means "derive".
  let rev = if file_rev == 0: legacy_payload_version(core, version)
            else: uint32(file_rev)
  if rev > current_payload_version(core):
    raise state_error("save state payload revision " & $rev &
                      " is newer than this build reads (" &
                      $current_payload_version(core) & ")")
  let file_checksum = r.read_u32()
  let file_rom_size = r.read_u32()
  if file_rom_size != rom_size or
     (file_checksum != rom_checksum and file_checksum notin legacy_checksums):
    raise state_error("save state belongs to a different ROM")
  let payload_len = int(r.read_u32())
  let payload_hash = r.read_u32()
  # `<`, not `!=`: an optional trailer (e.g. thumbnail) may follow the payload.
  if data.len - STATE_HEADER_SIZE < payload_len:
    raise state_error("save state is truncated or corrupt")
  result.payload = data[STATE_HEADER_SIZE ..< STATE_HEADER_SIZE + payload_len]
  result.rev = rev
  if fnv1a(result.payload) != payload_hash:
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
                         rom_checksum, rom_size: uint32;
                         legacy_checksums: seq[uint32] = @[]):
                        tuple[payload: string; rev: uint32] =
  if not fileExists(path):
    raise state_error("no save state found at " & path)
  parse_state_payload(readFile(path), core, rom_checksum, rom_size, path,
                      legacy_checksums)
