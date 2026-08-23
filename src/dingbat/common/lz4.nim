## LZ4 block format, compressor and decompressor. The block format follows the
## LZ4 spec (lz4.org block format): no frame header, no checksum. Written for
## the rewind ring's XOR deltas: mostly zeros with the changed bytes clustered,
## which LZ4 emits as long matches and decodes with a memcpy loop.
##
## Sequence: token = (literal_len << 4) | match_len_code, each 15 meaning "add
## the following bytes until one is < 255"; literal_len literal bytes; a 2-byte
## little-endian match offset; match-length extension bytes (stored length is
## real length - 4). The final sequence is literals only. The last match must
## end at least 12 bytes before the end of the block and the final literal run
## be at least 5 bytes (MfLimit / LastLiterals).

const
  MinMatch = 4
  LastLiterals = 5
  MfLimit = 12          # last match must start this far before the end
  HashLog = 14          # 16 K entries — 64 KB of table, L2-resident
  HashSize = 1 shl HashLog
  MaxDistance = 65535

proc lz4CompressBound*(n: int): int =
  ## Worst case: incompressible input costs 1 token per 255 literals.
  n + (n div 255) + 16

proc readU32(p: ptr UncheckedArray[byte]; i: int): uint32 {.inline.} =
  cast[ptr uint32](addr p[i])[]

proc readU64(p: ptr UncheckedArray[byte]; i: int): uint64 {.inline.} =
  cast[ptr uint64](addr p[i])[]

proc hashPos(v: uint32): int {.inline.} =
  # Knuth multiplicative hash on the 4-byte sequence
  int((v * 2654435761'u32) shr (32 - HashLog))

var lz4Table {.threadvar.}: seq[int32]
  ## Reused across calls and deliberately not cleared: a stale position is
  ## rejected by the `cand < ip` and distance tests, and a 64 KB memset per
  ## call was a third of the encode time on the rewind ring's small inputs.

proc lz4Compress*(src: string): string =
  ## Always succeeds; worst case is slightly larger than the input.
  let n = src.len
  result = newString(lz4CompressBound(n))
  if n == 0:
    result.setLen(0)
    return
  let s = cast[ptr UncheckedArray[byte]](unsafeAddr src[0])
  let d = cast[ptr UncheckedArray[byte]](addr result[0])
  if lz4Table.len != HashSize: lz4Table = newSeq[int32](HashSize)
  let table = cast[ptr UncheckedArray[int32]](addr lz4Table[0])
  var ip = 0            # input cursor
  var anchor = 0        # start of the current literal run
  var op = 0            # output cursor

  template emitLen(v: int) =
    var rest = v
    while rest >= 255:
      d[op] = 255'u8; op.inc; rest -= 255
    d[op] = uint8(rest); op.inc

  if n >= MfLimit + MinMatch:
    let matchLimit = n - LastLiterals
    let searchLimit = n - MfLimit
    while ip < searchLimit:
      let h = hashPos(readU32(s, ip))
      let cand = int(table[h]) - 1
      table[h] = int32(ip + 1)
      if cand < 0 or cand >= ip or ip - cand > MaxDistance or
         readU32(s, cand) != readU32(s, ip):
        ip.inc
        continue
      # match found: back up over any identical bytes before the anchor
      var mStart = ip
      var mCand = cand
      while mStart > anchor and mCand > 0 and s[mStart - 1] == s[mCand - 1]:
        mStart.dec; mCand.dec
      let litLen = mStart - anchor
      # measure the match forward
      var mLen = MinMatch
      while mStart + mLen + 8 <= matchLimit and
            readU64(s, mCand + mLen) == readU64(s, mStart + mLen):
        mLen += 8
      while mStart + mLen < matchLimit and s[mCand + mLen] == s[mStart + mLen]:
        mLen.inc
      # token
      let tokenPos = op
      op.inc
      var tok = 0'u8
      if litLen >= 15:
        tok = 0xF0'u8
        d[tokenPos] = tok
        emitLen(litLen - 15)
      else:
        tok = uint8(litLen shl 4)
      if litLen > 0:
        copyMem(addr d[op], unsafeAddr s[anchor], litLen)
        op += litLen
      # offset
      let off = mStart - mCand
      d[op] = uint8(off and 0xFF); d[op + 1] = uint8((off shr 8) and 0xFF)
      op += 2
      # match length
      let mCode = mLen - MinMatch
      if mCode >= 15:
        tok = tok or 0x0F'u8
        d[tokenPos] = tok
        emitLen(mCode - 15)
      else:
        tok = tok or uint8(mCode)
        d[tokenPos] = tok
      ip = mStart + mLen
      anchor = ip
      # re-seed the table just past the match so the next sequence can chain
      if ip < searchLimit:
        table[hashPos(readU32(s, ip - 2))] = int32(ip - 2 + 1)

  # trailing literals
  let litLen = n - anchor
  if litLen >= 15:
    d[op] = 0xF0'u8; op.inc
    var rest = litLen - 15
    while rest >= 255:
      d[op] = 255'u8; op.inc; rest -= 255
    d[op] = uint8(rest); op.inc
  else:
    d[op] = uint8(litLen shl 4); op.inc
  if litLen > 0:
    copyMem(addr d[op], unsafeAddr s[anchor], litLen)
    op += litLen
  result.setLen(op)

proc lz4Decompress*(src: string; hint = 0): string =
  ## `hint` sizes the output buffer up front when the caller knows the original
  ## length; an allocation hint only, never trusted for bounds.
  let n = src.len
  if n == 0: return ""
  let s = cast[ptr UncheckedArray[byte]](unsafeAddr src[0])
  var outBuf = newString(if hint > 0: hint else: n * 4)
  var op = 0
  var ip = 0

  template ensure(extra: int) =
    if op + extra > outBuf.len:
      var grow = outBuf.len * 2
      while grow < op + extra: grow *= 2
      outBuf.setLen(grow)

  while ip < n:
    let token = s[ip]; ip.inc
    var litLen = int(token shr 4)
    if litLen == 15:
      while ip < n:
        let b = s[ip]; ip.inc
        litLen += int(b)
        if b != 255: break
    if litLen > 0:
      if ip + litLen > n:
        raise newException(ValueError, "lz4: literal run past end of block")
      ensure(litLen)
      copyMem(addr outBuf[op], unsafeAddr s[ip], litLen)
      op += litLen
      ip += litLen
    if ip >= n: break            # final literals-only sequence
    if ip + 2 > n:
      raise newException(ValueError, "lz4: truncated match offset")
    let off = int(s[ip]) or (int(s[ip + 1]) shl 8)
    ip += 2
    if off == 0 or off > op:
      raise newException(ValueError, "lz4: match offset outside output")
    var mLen = int(token and 0x0F)
    if mLen == 15:
      while ip < n:
        let b = s[ip]; ip.inc
        mLen += int(b)
        if b != 255: break
    mLen += MinMatch
    ensure(mLen)
    # Overlapping copies are how LZ4 encodes a run, so this cannot be
    # memcpy/memmove. With distance >= 8 the 8-byte windows cannot overlap;
    # below that the byte loop is the semantics.
    var m = op - off
    if off >= 8:
      var left = mLen
      while left >= 8:
        cast[ptr uint64](addr outBuf[op])[] = cast[ptr uint64](addr outBuf[m])[]
        op += 8; m += 8; left -= 8
      while left > 0:
        outBuf[op] = outBuf[m]; op.inc; m.inc; left.dec
    else:
      for _ in 0 ..< mLen:
        outBuf[op] = outBuf[m]
        op.inc; m.inc
  outBuf.setLen(op)
  outBuf
