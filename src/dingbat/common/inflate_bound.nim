# Inflating a zlib stream to no more than a given size. zippy's uncompress
# grows its output to whatever the stream asks for, and a deflate stream can
# ask for about 1032 times its own size; a state from a link peer or an
# imported file is such a stream. Written from RFC 1950 and RFC 1951.
#
# Every read of the input and every write of the output is tested against
# its buffer here, by hand: the web build has no runtime checks, and the
# decode loop runs without them elsewhere for speed (as zippy's does).
# -d:inflate_checks puts them back; tests/inflate_bound_test.nim is built
# that way, so a missed test faults there.

type
  InflateError* = object of CatchableError
    too_big*: bool   ## well formed as far as it was read, but past the limit

const
  MAX_BITS = 15
  FAST_BITS = 10
  LEN_BASE: array[29, uint16] = [3'u16, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17,
    19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  LEN_EXTRA: array[29, uint8] = [0'u8, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2,
    2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  DIST_BASE: array[30, uint16] = [1'u16, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49,
    65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577]
  DIST_EXTRA: array[30, uint8] = [0'u8, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5,
    6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  CLEN_ORDER: array[19, uint8] = [16'u8, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4,
    12, 3, 13, 2, 14, 1, 15]

type
  Bits = object
    src: ptr UncheckedArray[uint8]
    len, pos: int
    acc: uint64
    n: int        # bits of acc that count
    bad: bool     # ran off the end

  Huff = object
    count: array[MAX_BITS + 1, uint16]  # codes of each length
    symbol: array[288, uint16]          # symbols in canonical order
    # The next FAST_BITS of the stream -> (symbol shl 4) or code length,
    # for the codes that short; 0 sends the decode to the bit-by-bit walk.
    fast: array[1 shl FAST_BITS, uint16]

proc c_memset(p: pointer; v: cint; n: csize_t): pointer {.
  importc: "memset", header: "<string.h>".}

proc fail(msg: string; too_big = false) {.noreturn, noinline.} =
  var e = newException(InflateError, msg)
  e.too_big = too_big
  raise e

proc build(h: var Huff; lengths: openArray[uint8]): bool =
  ## False for an over-subscribed set of lengths. Each length is under 16.
  for i in 0 .. MAX_BITS: h.count[i] = 0
  for l in lengths: inc h.count[l and 15]
  h.count[0] = 0
  var left = 1
  for i in 1 .. MAX_BITS:
    left = left * 2 - int(h.count[i])
    if left < 0: return false
  var offs: array[MAX_BITS + 2, int]
  for i in 1 .. MAX_BITS: offs[i + 1] = offs[i] + int(h.count[i])
  for s in 0 ..< lengths.len:
    let l = int(lengths[s] and 15)
    if l != 0:
      h.symbol[offs[l]] = uint16(s)
      inc offs[l]
  for e in h.fast.mitems: e = 0
  var code, index = 0
  for l in 1 .. FAST_BITS:
    for _ in 0 ..< int(h.count[l]):
      var rev = 0   # the stream carries a code's first bit lowest
      for bit in 0 ..< l:
        if ((code shr bit) and 1) != 0: rev = rev or (1 shl (l - 1 - bit))
      let entry = (h.symbol[index] shl 4) or uint16(l)
      var i = rev
      while i < (1 shl FAST_BITS):
        h.fast[i] = entry
        i += 1 shl l
      inc code
      inc index
    code = code shl 1
  true

when not defined(inflate_checks):
  {.push checks: off.}

proc fill(b: var Bits) {.inline.} =
  ## Top acc up to 56 bits or more while the input lasts.
  when cpuEndian == littleEndian:
    if b.pos + 8 <= b.len:
      var w: uint64
      copyMem(addr w, addr b.src[b.pos], 8)
      # The bytes past the ones counted are the stream's next bits, and the
      # next fill puts the same bits over them.
      b.acc = b.acc or (w shl b.n)
      let adv = (63 - b.n) shr 3
      b.pos += adv
      b.n += adv * 8
      return
  while b.n <= 56 and b.pos < b.len:
    b.acc = b.acc or (uint64(b.src[b.pos]) shl b.n)
    inc b.pos
    b.n += 8

proc take(b: var Bits; k: int): int {.inline.} =
  ## The next k bits, k under 16.
  if b.n < k:
    b.fill()
    if b.n < k:
      b.bad = true
      return 0
  result = int(b.acc and ((1'u64 shl k) - 1))
  b.acc = b.acc shr k
  b.n -= k

proc decode_slow(b: var Bits; h: var Huff): int {.noinline.} =
  var code, first, index = 0
  for l in 1 .. MAX_BITS:
    code = code or b.take(1)
    if b.bad: return -1
    let c = int(h.count[l])
    if code - c < first: return int(h.symbol[index + (code - first)])
    index += c
    first = (first + c) shl 1
    code = code shl 1
  -1

proc decode(b: var Bits; h: var Huff): int {.inline.} =
  ## The next symbol, or -1 for a code the table does not hold.
  if b.n < MAX_BITS: b.fill()
  let e = int(h.fast[int(b.acc and ((1 shl FAST_BITS) - 1))])
  if e != 0 and (e and 15) <= b.n:
    b.acc = b.acc shr (e and 15)
    b.n -= e and 15
    return e shr 4
  b.decode_slow(h)

proc dynamic_tables(b: var Bits; lit, dist: var Huff): bool =
  let nlen = b.take(5) + 257
  let ndist = b.take(5) + 1
  let ncode = b.take(4) + 4
  if b.bad or nlen > 286 or ndist > 30: return false
  var cl: array[19, uint8]
  for i in 0 ..< ncode: cl[CLEN_ORDER[i]] = uint8(b.take(3))
  if b.bad: return false
  var ch: Huff
  if not ch.build(cl): return false
  var lengths: array[286 + 30, uint8]
  var i = 0
  while i < nlen + ndist:
    let sym = b.decode(ch)
    if sym < 0 or sym > 18: return false
    if sym < 16:
      lengths[i] = uint8(sym)
      inc i
    else:
      var prev = 0'u8
      var rep: int
      if sym == 16:
        if i == 0: return false
        prev = lengths[i - 1]
        rep = 3 + b.take(2)
      elif sym == 17: rep = 3 + b.take(3)
      else: rep = 11 + b.take(7)
      if b.bad or i + rep > nlen + ndist: return false
      for _ in 0 ..< rep:
        lengths[i] = prev
        inc i
  if lengths[256] == 0: return false   # no end-of-block code
  lit.build(lengths.toOpenArray(0, nlen - 1)) and
    dist.build(lengths.toOpenArray(nlen, nlen + ndist - 1))

proc room(dst: var string; op, more, limit: int) {.inline.} =
  ## Make dst hold `more` bytes past op, or raise at the limit.
  if op + more > dst.len:
    if op + more > limit:
      fail("the stream inflates past " & $limit & " bytes", too_big = true)
    dst.setLen(min(limit, max(dst.len * 2, op + more)))

proc adler32(data: ptr UncheckedArray[uint8]; n: int): uint32 =
  var a = 1'u32
  var b = 0'u32
  var i = 0
  while i < n:
    let stop = min(n, i + 5552)   # the most additions before a 32-bit wrap
    while i < stop:
      a += uint32(data[i])
      b += a
      inc i
    a = a mod 65521
    b = b mod 65521
  (b shl 16) or a

proc zlib_inflate_capped*(src: pointer; len: int; limit: int; hint = 0): string =
  ## The zlib stream at `src`, inflated. Raises InflateError for a stream
  ## that is not well formed, and (too_big set) as soon as the output would
  ## pass `limit`, before the bytes that would are made. `hint` is the size
  ## expected, from whoever wrote the stream: where the buffer starts, held
  ## to what a stream this long could plausibly need.
  if len < 6: fail("the stream is too short")
  let s = cast[ptr UncheckedArray[uint8]](src)
  let cmf = uint32(s[0])
  let flg = uint32(s[1])
  if (cmf and 15) != 8 or (cmf shr 4) > 7 or ((cmf shl 8) or flg) mod 31 != 0 or
     (flg and 0x20) != 0:
    fail("not a zlib stream this reads")
  var b = Bits(src: s, len: len - 4, pos: 2)
  var dst = newString(max(0, min(limit, min(len * 16 + 4096,
                                            if hint > 0: hint else: len * 4))))
  # Written through a pointer, taken again after each resize: indexing the
  # string pays for a uniqueness test on every byte.
  var o = cast[ptr UncheckedArray[uint8]](if dst.len > 0: addr dst[0] else: nil)
  var cap = dst.len
  template grow(more: int) =
    if op + more > cap:
      dst.room(op, more, limit)
      o = cast[ptr UncheckedArray[uint8]](addr dst[0])
      cap = dst.len
  var op = 0
  var lit, dist: Huff
  var fixed_built = false
  while true:
    let final = b.take(1)
    let kind = b.take(2)
    if b.bad: fail("the stream ends early")
    case kind
    of 0:
      b.pos -= b.n div 8   # whole bytes read ahead go back;
      b.acc = 0            # the rest of this one is padding
      b.n = 0
      if b.pos + 4 > b.len: fail("the stream ends early")
      let n = int(b.src[b.pos]) or (int(b.src[b.pos + 1]) shl 8)
      let inv = int(b.src[b.pos + 2]) or (int(b.src[b.pos + 3]) shl 8)
      if (n xor inv) != 0xFFFF: fail("a stored block's length is damaged")
      if b.pos + 4 + n > b.len: fail("the stream ends early")
      if n > 0:
        grow(n)
        copyMem(addr o[op], addr b.src[b.pos + 4], n)
        op += n
      b.pos += 4 + n
    of 1, 2:
      if kind == 2:
        if not b.dynamic_tables(lit, dist): fail("a block's code tables are damaged")
        fixed_built = false
      elif not fixed_built:
        var l: array[288, uint8]
        for i in 0 .. 143: l[i] = 8
        for i in 144 .. 255: l[i] = 9
        for i in 256 .. 279: l[i] = 7
        for i in 280 .. 287: l[i] = 8
        discard lit.build(l)
        var d: array[30, uint8]
        for i in 0 .. 29: d[i] = 5
        discard dist.build(d)
        fixed_built = true
      while true:
        let sym = b.decode(lit)
        if sym < 0: fail("the stream is damaged")
        if sym < 256:
          grow(1)
          o[op] = uint8(sym)
          inc op
        elif sym == 256: break
        else:
          let li = sym - 257
          if li >= 29: fail("the stream is damaged")
          let n = int(LEN_BASE[li]) + b.take(int(LEN_EXTRA[li]))
          let ds = b.decode(dist)
          if ds < 0 or ds >= 30: fail("the stream is damaged")
          let d = int(DIST_BASE[ds]) + b.take(int(DIST_EXTRA[ds]))
          if b.bad: fail("the stream ends early")
          if d > op: fail("a match reaches back before the output's start")
          grow(n)
          if d >= n:
            copyMem(addr o[op], addr o[op - d], n)
          elif d == 1:
            discard c_memset(addr o[op], cint(o[op - 1]), csize_t(n))
          else:
            # The match overlaps what it writes: the d bytes before op,
            # over and over. Each copy doubles what there is to copy from.
            var done = 0
            var span = d
            while done < n:
              let k = min(span, n - done)
              copyMem(addr o[op + done], addr o[op - d], k)
              done += k
              span += k
          op += n
    else:
      fail("the stream is damaged")
    if final == 1: break
  let want = (uint32(s[len - 4]) shl 24) or (uint32(s[len - 3]) shl 16) or
             (uint32(s[len - 2]) shl 8) or uint32(s[len - 1])
  if adler32(o, op) != want: fail("the stream's checksum does not match")
  dst.setLen(op)
  dst

when not defined(inflate_checks):
  {.pop.}
