# Binary save-state serialization: a little-endian Writer/Reader pair plus the
# .state file header. Every field is written explicitly (no std/marshal: JSON +
# refs, not stable across builds).

import std/[os, strutils]

type
  StateError* = object of CatchableError

  StateRejectKind* = enum
    ## Why a state was refused, coarse enough for a frontend to pick a sentence
    ## without parsing the detail string (`last_state_error`).
    srkNone            ## nothing was refused
    srkNotAState       ## no DGBSTATE magic — not one of our files at all
    srkWrongCore       ## a Game Boy state offered to the GBA core, or vice versa
    srkWrongRom        ## a real state, for a different cartridge
    srkTooNew          ## written by a newer dingbat than this one
    srkTruncated       ## the file is short — a partial download or copy
    srkCorrupt         ## hash/marker/range checks failed: the bytes are damaged
    ## APPEND new causes: the ordinals cross into JS (web/index.js's SRK table).
    srkNoFile          ## nothing there to load — an empty slot, a missing path

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

  # STATE_VERSION describes the HEADER only. A payload change bumps that core's
  # payload revision (header byte 13) and adds a migration in its savestate.nim;
  # STATE_VERSION moves only if this 32-byte header changes shape, which also
  # stops older builds recognising the file.
  STATE_VERSION* = 7'u32

  # Per-core payload revisions. Bump ONE of these when that core's field
  # sequence changes, and add the matching `if rev >= N` in its loader.
  #
  # GBA: 1 initial · 2 CPU halt-wake/deferred-return · 3 bus ROM burst trackers
  #      + deterministic RTC · 4 CPU halt_resume_pop · 5 DMA latched word count
  # GB:  1 initial · 2 serial port section · 3 PPU dots_since_frame
  #      · 4 CPU undefined-opcode lockup flag · 5 Super Game Boy section
  GBA_PAYLOAD_VERSION* = 5'u32
  GB_PAYLOAD_VERSION*  = 5'u32

  # magic(8) version(4) core(1) payload_version(1) flags(2) rom_checksum(4)
  # rom_size(4) payload_len(4) payload_hash(4). Byte 13 was an always-zero
  # `slot` before v7, so 0 is the "pre-v7, derive it" marker and revisions
  # start at 1.
  STATE_HEADER_SIZE* = 32
  # Optional trailer after the payload, flagged in `flags`; outside the
  # hash-validated payload, so old readers ignore it. Layout: thumb_w(2)
  # thumb_h(2) len(4) BGR555 pixels.
  STATE_FLAG_THUMBNAIL* = 0x0001'u16

var last_state_reject_kind*: StateRejectKind = srkNone
  ## Set beside `last_state_error` by every refusal. Assigned only from procs
  ## the frontends call (see last_state_error on wasm module-scope globals).

proc state_error*(msg: string; kind = srkCorrupt): ref StateError =
  ## Default srkCorrupt: an unqualified refusal from a subsystem reader means
  ## the bytes did not describe a machine.
  last_state_reject_kind = kind
  newException(StateError, msg)

# ==================== Field range guards ====================
#
# A shared state is a stranger's file: every field later used as an index, a
# length, or an operand of unchecked arithmetic gets a range check at load time
# (a wild value otherwise raises a Defect on the next step_frame, which is not
# a CatchableError and escapes the loaders). These raise StateError, which the
# loaders already restore from.

proc check_range*(v, lo, hi: int; field: string) =
  ## `field` names the thing for the log; user-facing text comes from the kind.
  if v < lo or v > hi:
    raise state_error("save state field '" & field & "' is out of range (" &
                      $v & " not in " & $lo & ".." & $hi & ")")

proc check_one_of*(v: int; allowed: openArray[int]; field: string) =
  ## Raise unless `v` is one of a small set of legal values (buffer sizes).
  for a in allowed:
    if v == a: return
  raise state_error("save state field '" & field & "' has an impossible value (" &
                    $v & ")")

proc check_no_undefined_bits*(v: uint32; width: int; field: string) =
  ## Raise if any bit at or above `width` is set, for the `cast[set[...]]`
  ## reads where a bit with no enumerator makes iteration yield a value that
  ## does not exist. Not named `check_bits`: Nim identifiers ignore case and
  ## underscores, so that IS the `checkBits` macro lut_macros exports, and the
  ## collision surfaces as "invalid expression" inside every LUT builder.
  if width < 32 and (v shr width) != 0:
    raise state_error("save state field '" & field &
                      "' has undefined bits set (0x" & toHex(v, 8) & ")")

template restore_backup*(apply: untyped) =
  ## Put the pre-load machine back after a refused load. `apply` re-applies a
  ## payload the core serialized moments ago, so it cannot fail -- but the field
  ## guards run on the way back in too, and a raise here would leave the
  ## emulator half restored; contain it and say so.
  try:
    apply
  except CatchableError, Defect:
    echo "Load state failed AND the pre-load state could not be restored — " &
         "that is a dingbat bug, please report it: ",
         getCurrentExceptionMsg()

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
    raise state_error("truncated state data", srkTruncated)

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

proc peek_tag*(r: Reader): uint8 =
  ## Next section marker without consuming it, 0 at end of payload: lets a
  ## reader skip a conditionally present section (written only when the machine
  ## has that hardware).
  if r.remaining < 1: 0'u8 else: uint8(r.buf[r.pos])

proc expect_tag*(r: var Reader; tag: uint8) =
  let got = r.read_u8()
  if got != tag:
    raise state_error("state section marker mismatch (corrupt or incompatible state)")

# ==================== Hashing ====================

var last_state_error*: string = ""
  ## Why the most recent state load was refused, in parse_state_payload's
  ## words; every caller of load_state_bytes collapses the result to a bool.
  ## Assigned only from procs the frontends call: heap globals initialised at
  ## module scope dangle in the wasm build once main() has returned.

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
  ## counter (one layout per core per container version):
  ##
  ##   container | GBA | GB | what moved
  ##      1      |  1  | 1  | format introduced
  ##      2      |  2  | 1  | GBA CPU halt-wake fields
  ##      3      |  3  | 1  | GBA bus ROM trackers + RTC epoch
  ##      4      |  3  | 2  | GB serial section
  ##      5      |  4  | 2  | GBA CPU halt_resume_pop
  ##      6      |  4  | 3  | GB PPU dots_since_frame
  ##
  ## Inside container 4 the GB serial section's 5th byte changed meaning at
  ## the same width (previous_bit -> clock_history, f678d02); it is 0 in any
  ## state not taken mid-transfer and both readings of 0 agree.
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
  ## Full state-file image (header + payload) as bytes.
  var w = Writer()
  write_state_header(w, core, rom_checksum, rom_size, payload, 0'u16)
  w.buf

proc make_state_bytes*(core: CoreKind; rom_checksum, rom_size: uint32;
                       payload: string; thumbnail: openArray[byte];
                       thumb_w, thumb_h: uint16): string =
  ## As above, plus a thumbnail trailer (BGR555, thumb_w*thumb_h) after the
  ## payload. Falls back to a plain image if the thumbnail is empty/degenerate.
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
  ## Nearest-neighbour downscale of a BGR555 framebuffer to little-endian
  ## BGR555 bytes, the thumbnail trailer's format.
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
  ## Validates the header of a full state image and returns the payload and
  ## its payload revision (the caller's per-subsystem loaders migrate older
  ## layouts); raises StateError on any mismatch. `legacy_checksums` are ROM
  ## identities older builds wrote for this same cart, accepted on read and
  ## never written (the caller derives them from the loaded ROM, see
  ## gba_legacy_rom_checksums); a state from a different ROM is still refused.
  if data.len < STATE_HEADER_SIZE or data[0 ..< STATE_MAGIC.len] != STATE_MAGIC:
    raise state_error("not a dingbat save state: " & origin, srkNotAState)
  var r = Reader(buf: data, pos: STATE_MAGIC.len)
  let version = r.read_u32()
  if version > STATE_VERSION:
    # Only refuse the future: a newer build may have reshaped the header.
    raise state_error("save state was written by a newer version of dingbat " &
                      "(container " & $version & ", this build reads up to " &
                      $STATE_VERSION & ")", srkTooNew)
  let file_core = r.read_u8()
  let file_rev = r.read_u8()
  discard r.read_u16()  # flags (read by parse_state_thumbnail)
  if file_core != uint8(core):
    raise state_error("save state was created by a different core (GBA/GB mismatch)",
                      srkWrongCore)
  # Byte 13 was the always-zero `slot` field before v7; 0 means "derive".
  let rev = if file_rev == 0: legacy_payload_version(core, version)
            else: uint32(file_rev)
  if rev > current_payload_version(core):
    raise state_error("save state payload revision " & $rev &
                      " is newer than this build reads (" &
                      $current_payload_version(core) & ")", srkTooNew)
  let file_checksum = r.read_u32()
  let file_rom_size = r.read_u32()
  if file_rom_size != rom_size or
     (file_checksum != rom_checksum and file_checksum notin legacy_checksums):
    raise state_error("save state belongs to a different ROM", srkWrongRom)
  let payload_len = int(r.read_u32())
  let payload_hash = r.read_u32()
  # `<`, not `!=`: an optional trailer (e.g. thumbnail) may follow the payload.
  if data.len - STATE_HEADER_SIZE < payload_len:
    raise state_error("save state is truncated or corrupt", srkTruncated)
  result.payload = data[STATE_HEADER_SIZE ..< STATE_HEADER_SIZE + payload_len]
  result.rev = rev
  if fnv1a(result.payload) != payload_hash:
    raise state_error("save state payload hash mismatch (corrupt file)")

proc parse_state_thumbnail*(data: string): tuple[w, h: int; pixels: seq[byte]] =
  ## The optional thumbnail trailer (BGR555), (0,0,@[]) if absent. Never
  ## raises, so a malformed trailer cannot break state loading.
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
    # Its own kind, not srkCorrupt: "nothing saved here" and "damaged" are
    # opposite things to tell someone.
    raise state_error("no save state found at " & path, srkNoFile)
  parse_state_payload(readFile(path), core, rom_checksum, rom_size, path,
                      legacy_checksums)
