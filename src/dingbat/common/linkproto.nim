# Wire protocol for the dingbat network link. Transport-agnostic byte
# conversion: length-prefixed little-endian frames with fixed field layouts
# (`u32le payload_length`, then the payload; first payload byte is the message
# type), so any transport and any language produces the same bytes. Field
# layout is documented in docs/multiplayer.md; keep the two in sync.
#
# Clock discipline: CLOCK, TRANSFER and REPLY carry the sender's emulated
# clock (u64le cycles since link start). Each side free-runs but never more
# than LEAD cycles ahead of the newest peer clock it has heard, stalling until
# a newer one arrives; transfers are anchored to explicit emulated cycles, so
# latency slows emulation but never desyncs it.
#
# Must stay compilable under emscripten; only gba/netlink.nim is native-only.

type
  LinkProtoError* = object of CatchableError

  LinkMsgKind* = enum
    lmHello    = 1
    lmClock    = 2
    lmTransfer = 3
    lmReply    = 4
    lmBye      = 5

  LinkMsg* = object
    ## Decoded message, flat rather than a case-object; which fields are
    ## meaningful depends on `kind` (see the encoders).
    kind*: LinkMsgKind
    version*: uint8   # HELLO
    system*: uint8    # HELLO: 0 = GBA, 1 = GB
    unit*: uint8      # HELLO: 0 = listener (multi-mode unit 0), 1 = connector
    rom_crc*: uint32  # HELLO: CRC-32 of the ROM file
    clock*: int64     # CLOCK/TRANSFER/REPLY: sender's emulated clock (cycles)
    mode*: uint8      # CLOCK: sender's SIO mode; TRANSFER/REPLY: transfer mode
    flags*: uint8     # CLOCK: bit0 SO level, bit1 blocked; REPLY: bit0
                      # listening; BYE: reason
    duration*: uint32 # TRANSFER: transfer length in cycles
    cycle*: int64     # REPLY: echo of the TRANSFER's start clock
    data*: uint32     # TRANSFER: initiator's word; REPLY: responder's word

const
  LINKPROTO_VERSION* = 1'u8
  LINK_SYSTEM_GBA* = 0'u8
  LINK_SYSTEM_GB* = 1'u8

  # SIO mode encoding for CLOCK's mode and TRANSFER/REPLY's transfer kind
  # (independent of any core's enum ordering)
  LINK_MODE_NORMAL8* = 0'u8
  LINK_MODE_NORMAL32* = 1'u8
  LINK_MODE_MULTI* = 2'u8
  LINK_MODE_UART* = 3'u8
  LINK_MODE_GPIO* = 4'u8
  LINK_MODE_JOYBUS* = 5'u8

  # CLOCK `flags`
  LINK_CLOCK_SO* = 0x01'u8       # sender's SO output level (SIOCNT bit 3)
  LINK_CLOCK_BLOCKED* = 0x02'u8  # sender's emulated clock is stalled on us

  # REPLY `flags`
  LINK_REPLY_LISTENING* = 0x01'u8  # responder was in a compatible SIO mode

  # BYE `flags` (reason)
  LINK_BYE_FINISHED* = 0'u8  # orderly end (e.g. test ROM completed)
  LINK_BYE_SHUTDOWN* = 1'u8  # session torn down
  LINK_BYE_MISMATCH* = 2'u8  # HELLO rejected (version/system/ROM mismatch)

  # Largest legal payload; anything bigger is a corrupt or foreign stream.
  LINK_MAX_PAYLOAD = 64

# ---------------- little-endian primitives ----------------

proc put_u8(s: var string; v: uint8) =
  s.add char(v)

proc put_u32(s: var string; v: uint32) =
  for i in 0 ..< 4:
    s.add char(uint8(v shr (8 * i)))

proc put_u64(s: var string; v: uint64) =
  for i in 0 ..< 8:
    s.add char(uint8(v shr (8 * i)))

proc get_u8(s: string; pos: int): uint8 =
  uint8(s[pos])

proc get_u32(s: string; pos: int): uint32 =
  for i in 0 ..< 4:
    result = result or (uint32(uint8(s[pos + i])) shl (8 * i))

proc get_u64(s: string; pos: int): uint64 =
  for i in 0 ..< 8:
    result = result or (uint64(uint8(s[pos + i])) shl (8 * i))

proc frame(payload: string): string =
  result = newStringOfCap(payload.len + 4)
  result.put_u32(uint32(payload.len))
  result.add payload

# ---------------- encoders ----------------

proc encode_hello*(system, unit: uint8; rom_crc: uint32): string =
  ## HELLO: first message in each direction. Both sides validate version,
  ## system, unit (must differ), and ROM checksum before emulating.
  var p = ""
  p.put_u8(uint8(lmHello))
  p.put_u8(LINKPROTO_VERSION)
  p.put_u8(system)
  p.put_u8(unit)
  p.put_u8(0)  # reserved
  p.put_u32(rom_crc)
  frame(p)

proc encode_clock*(clock: int64; mode: uint8; flags: uint8): string =
  ## CLOCK: periodic beacon of the sender's emulated clock plus the SIO
  ## state the peer needs for status bits (mode for multi SD, SO for normal
  ## SI). Sent at least once per frame and immediately when blocked.
  var p = ""
  p.put_u8(uint8(lmClock))
  p.put_u64(uint64(clock))
  p.put_u8(mode)
  p.put_u8(flags)
  frame(p)

proc encode_transfer*(clock: int64; duration: uint32; mode: uint8;
                      data: uint32): string =
  ## TRANSFER: the initiating (clock-driving) unit opens an exchange at
  ## emulated cycle `clock`, completing `duration` cycles later. `data` is
  ## its outgoing word (SIOMLT_SEND / SIODATA8 / SIODATA32).
  var p = ""
  p.put_u8(uint8(lmTransfer))
  p.put_u64(uint64(clock))
  p.put_u32(duration)
  p.put_u8(mode)
  p.put_u8(0)  # reserved
  p.put_u32(data)
  frame(p)

proc encode_reply*(clock: int64; cycle: int64; mode: uint8; flags: uint8;
                   data: uint32): string =
  ## REPLY: the responding unit's word for the TRANSFER whose start clock
  ## was `cycle`. `clock` is the responder's own clock when it responded.
  var p = ""
  p.put_u8(uint8(lmReply))
  p.put_u64(uint64(clock))
  p.put_u64(uint64(cycle))
  p.put_u8(mode)
  p.put_u8(flags)
  p.put_u32(data)
  frame(p)

proc encode_bye*(reason: uint8): string =
  ## BYE: orderly notification; reason in `flags`.
  var p = ""
  p.put_u8(uint8(lmBye))
  p.put_u8(reason)
  frame(p)

# ---------------- decoder ----------------

type
  LinkDecoder* = object
    ## Byte-stream accumulator: feed arbitrary chunks (TCP has no message
    ## boundaries), pull complete messages out.
    buf: string
    pos: int  # consumed prefix; compacted lazily

proc feed*(d: var LinkDecoder; data: openArray[char]) =
  for c in data:
    d.buf.add c

proc feed*(d: var LinkDecoder; data: string) =
  d.buf.add data

proc payload_len(d: LinkDecoder; kind: LinkMsgKind): int =
  case kind
  of lmHello: 9
  of lmClock: 11
  of lmTransfer: 19
  of lmReply: 23
  of lmBye: 2

proc next*(d: var LinkDecoder; msg: var LinkMsg): bool =
  ## Decode the next complete message, if a full frame has arrived.
  ## Raises LinkProtoError on a malformed stream.
  let avail = d.buf.len - d.pos
  if avail < 4: return false
  let plen = int(get_u32(d.buf, d.pos))
  if plen < 1 or plen > LINK_MAX_PAYLOAD:
    raise newException(LinkProtoError, "bad frame length " & $plen)
  if avail < 4 + plen: return false
  let p = d.pos + 4
  let type_byte = get_u8(d.buf, p)
  if type_byte < uint8(low(LinkMsgKind)) or type_byte > uint8(high(LinkMsgKind)):
    raise newException(LinkProtoError, "unknown message type " & $type_byte)
  let kind = LinkMsgKind(type_byte)
  if plen != d.payload_len(kind):
    raise newException(LinkProtoError,
      "bad payload length " & $plen & " for message type " & $type_byte)
  msg = LinkMsg(kind: kind)
  case kind
  of lmHello:
    msg.version = get_u8(d.buf, p + 1)
    msg.system = get_u8(d.buf, p + 2)
    msg.unit = get_u8(d.buf, p + 3)
    msg.rom_crc = get_u32(d.buf, p + 5)
  of lmClock:
    msg.clock = int64(get_u64(d.buf, p + 1))
    msg.mode = get_u8(d.buf, p + 9)
    msg.flags = get_u8(d.buf, p + 10)
  of lmTransfer:
    msg.clock = int64(get_u64(d.buf, p + 1))
    msg.duration = get_u32(d.buf, p + 9)
    msg.mode = get_u8(d.buf, p + 13)
    msg.data = get_u32(d.buf, p + 15)
  of lmReply:
    msg.clock = int64(get_u64(d.buf, p + 1))
    msg.cycle = int64(get_u64(d.buf, p + 9))
    msg.mode = get_u8(d.buf, p + 17)
    msg.flags = get_u8(d.buf, p + 18)
    msg.data = get_u32(d.buf, p + 19)
  of lmBye:
    msg.flags = get_u8(d.buf, p + 1)
  d.pos += 4 + plen
  # Compact once the consumed prefix dominates; keeps feed() amortized O(1).
  if d.pos > 4096 and d.pos * 2 > d.buf.len:
    d.buf = d.buf[d.pos .. ^1]
    d.pos = 0
  true

# ---------------- ROM checksum ----------------
#
# A WIRE VALUE compared in HELLO, so its definition is frozen: CRC-32 over the
# ROM file (crc32(readFile(rom)) natively, crc32(rom[0 ..< rom_size]) in wasm).
# Distinct from the save-state ROM identity (gba_rom_checksum: FNV-1a over the
# first 1 MB, with a legacy accept-list). If this one ever moves, bump
# LINKPROTO_VERSION and accept both values for a transition.

const CRC32_TABLE = block:
  var t: array[256, uint32]
  for i in 0 ..< 256:
    var c = uint32(i)
    for _ in 0 ..< 8:
      c = if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
    t[i] = c
  t

proc crc32*(data: openArray[char]): uint32 =
  ## Standard CRC-32 (IEEE 802.3, the zlib/PNG polynomial): every language a
  ## bridge might use has it.
  result = 0xFFFFFFFF'u32
  for c in data:
    result = CRC32_TABLE[int((result xor uint32(uint8(c))) and 0xFF)] xor (result shr 8)
  result = not result
