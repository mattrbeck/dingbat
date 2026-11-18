# The inflated size of a zlib stream, found without inflating it: zippy's
# uncompress grows its output to whatever the stream asks for, and a deflate
# stream can ask for about 1032 times its own size. The stream is walked as
# RFC 1951 lays it out, counting the bytes each symbol would produce.

const
  MAX_BITS = 15
  LEN_BASE: array[29, uint16] = [3'u16, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17,
    19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  LEN_EXTRA: array[29, uint8] = [0'u8, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2,
    2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  DIST_EXTRA: array[30, uint8] = [0'u8, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5,
    6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  CLEN_ORDER: array[19, uint8] = [16'u8, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4,
    12, 3, 13, 2, 14, 1, 15]

const FAST_BITS = 10

type
  Bits = object
    src: ptr UncheckedArray[uint8]
    len, pos: int
    acc: uint64
    n: int        # bits held in acc
    bad: bool     # ran off the end

  Huff = object
    count: array[MAX_BITS + 1, uint16]  # codes of each length
    symbol: array[288, uint16]          # symbols in canonical order
    # The next FAST_BITS of the stream -> (symbol shl 4) or code length,
    # for the codes that short; 0 sends the decode to the bit-by-bit walk.
    fast: array[1 shl FAST_BITS, uint16]

proc fill(b: var Bits) {.inline.} =
  while b.n <= 56 and b.pos < b.len:
    b.acc = b.acc or (uint64(b.src[b.pos]) shl b.n)
    inc b.pos
    b.n += 8

proc take(b: var Bits; k: int): int {.inline.} =
  if k == 0: return 0
  if b.n < k:
    b.fill()
    if b.n < k:
      b.bad = true
      return 0
  result = int(b.acc and ((1'u64 shl k) - 1))
  b.acc = b.acc shr k
  b.n -= k

proc build(h: var Huff; lengths: openArray[uint8]): bool =
  ## False for an over-subscribed set of lengths.
  for i in 0 .. MAX_BITS: h.count[i] = 0
  for l in lengths: inc h.count[l]
  h.count[0] = 0
  var left = 1
  for i in 1 .. MAX_BITS:
    left = left * 2 - int(h.count[i])
    if left < 0: return false
  var offs: array[MAX_BITS + 2, int]
  for i in 1 .. MAX_BITS: offs[i + 1] = offs[i] + int(h.count[i])
  for s in 0 ..< lengths.len:
    if lengths[s] != 0:
      h.symbol[offs[lengths[s]]] = uint16(s)
      inc offs[lengths[s]]
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

proc decode(b: var Bits; h: var Huff): int =
  ## The next symbol, or -1 for a code the table does not hold.
  if b.n < MAX_BITS: b.fill()
  let e = int(h.fast[int(b.acc and ((1 shl FAST_BITS) - 1))])
  if e != 0 and (e and 15) <= b.n:
    b.acc = b.acc shr (e and 15)
    b.n -= e and 15
    return e shr 4
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

proc fixed_tables(lit, dist: var Huff) =
  var l: array[288, uint8]
  for i in 0 .. 143: l[i] = 8
  for i in 144 .. 255: l[i] = 9
  for i in 256 .. 279: l[i] = 7
  for i in 280 .. 287: l[i] = 8
  discard lit.build(l)
  var d: array[30, uint8]
  for i in 0 .. 29: d[i] = 5
  discard dist.build(d)

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
    if sym < 0: return false
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

proc zlib_inflated_len*(src: pointer; len: int; limit: int): int =
  ## How many bytes the zlib stream at `src` inflates to: -1 for a stream
  ## that is not well formed, and `limit + 1` as soon as it passes `limit`.
  if len < 6: return -1
  var b = Bits(src: cast[ptr UncheckedArray[uint8]](src), len: len - 4, pos: 2)
  var total = 0
  var lit, dist: Huff
  while true:
    let final = b.take(1)
    let kind = b.take(2)
    if b.bad: return -1
    case kind
    of 0:
      b.pos -= b.n div 8   # whole bytes read ahead go back;
      b.acc = 0            # the rest of this one is padding
      b.n = 0
      if b.pos + 4 > b.len: return -1
      let n = int(b.src[b.pos]) or (int(b.src[b.pos + 1]) shl 8)
      let inv = int(b.src[b.pos + 2]) or (int(b.src[b.pos + 3]) shl 8)
      if (n xor inv) != 0xFFFF or b.pos + 4 + n > b.len: return -1
      b.pos += 4 + n
      total += n
      if total > limit: return limit + 1
    of 1, 2:
      if kind == 1: fixed_tables(lit, dist)
      elif not b.dynamic_tables(lit, dist): return -1
      while true:
        let sym = b.decode(lit)
        if sym < 0: return -1
        if sym < 256: inc total
        elif sym == 256: break
        else:
          let li = sym - 257
          if li >= 29: return -1
          total += int(LEN_BASE[li]) + b.take(int(LEN_EXTRA[li]))
          let ds = b.decode(dist)
          if ds < 0 or ds >= 30: return -1
          discard b.take(int(DIST_EXTRA[ds]))
          if b.bad: return -1
        if total > limit: return limit + 1
    else:
      return -1
    if final == 1: break
  total
