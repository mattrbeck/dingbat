## Candidate codecs for the rewind ring's XOR delta, plus a bake-off reporting
## size and time for each. Shared by tests/rewind_codec_test.nim and, under
## -d:codecbench, by src/dingbat_wasm.nim so browsers run the identical code
## over the identical deltas: a codec ranking does not necessarily survive the
## move from native to JavaScriptCore, and Safari is the closest proxy for the
## oldest device that has to run this. Kept so "why not lz4?" can be re-run
## rather than trusted. The sparse codec duplicates rewind.nim's on purpose, so
## a changed codec can be A/B'd against the shipped one. Nothing here is on a
## shipping path.

import std/[strutils, times, monotimes]
import zippy
import ./lz4

# Sparse block codec (see rewind.nim for the shipped copy and the format): a
# bitmap of which blocks contain any non-zero byte, then those blocks raw.

proc sparseEncode*(src: string; bs: int): string =
  let n = src.len
  if n == 0: return ""
  let nblocks = (n + bs - 1) div bs
  let bitmapBytes = (nblocks + 7) div 8
  var bitmap = newString(bitmapBytes)
  var body = newStringOfCap(n div 4 + 64)
  let s = cast[ptr UncheckedArray[byte]](unsafeAddr src[0])
  for b in 0 ..< nblocks:
    let lo = b * bs
    let hi = min(lo + bs, n)
    var any = false
    var i = lo
    while i + 8 <= hi:
      if cast[ptr uint64](addr s[i])[] != 0: any = true; break
      i += 8
    if not any:
      while i < hi:
        if s[i] != 0: any = true; break
        i.inc
    if any:
      bitmap[b div 8] = char(uint8(bitmap[b div 8]) or (1'u8 shl (b mod 8)))
      body.add(src[lo ..< hi])
  result = newStringOfCap(8 + bitmapBytes + body.len)
  var hdr = newString(8)
  cast[ptr uint32](addr hdr[0])[] = uint32(n)
  cast[ptr uint32](addr hdr[4])[] = uint32(bs)
  result.add hdr
  result.add bitmap
  result.add body

proc sparseDecode*(src: string): string =
  if src.len == 0: return ""
  let n = int(cast[ptr uint32](unsafeAddr src[0])[])
  let bs = int(cast[ptr uint32](unsafeAddr src[4])[])
  let nblocks = (n + bs - 1) div bs
  let bitmapBytes = (nblocks + 7) div 8
  result = newString(n)          # zero-filled: unset blocks are already right
  var p = 8 + bitmapBytes
  for b in 0 ..< nblocks:
    if (uint8(src[8 + b div 8]) and (1'u8 shl (b mod 8))) != 0:
      let lo = b * bs
      let hi = min(lo + bs, n)
      copyMem(addr result[lo], unsafeAddr src[p], hi - lo)
      p += hi - lo

# ---------------------------------------------------------------------------

type Codec* = object
  name*: string
  enc*: proc(src: string): string {.nimcall.}
  dec*: proc(src: string): string {.nimcall.}

proc encZlib(s: string): string = compress(s, BestSpeed, dfZlib)
proc decZlib(s: string): string = uncompress(s, dfZlib)
proc encZlibDef(s: string): string = compress(s, DefaultCompression, dfZlib)
proc encLz4(s: string): string = lz4Compress(s)
proc decLz4(s: string): string = lz4Decompress(s)
proc encS32Z(s: string): string = compress(sparseEncode(s, 32), BestSpeed, dfZlib)
proc decS32Z(s: string): string = sparseDecode(uncompress(s, dfZlib))
proc encS64Z(s: string): string = compress(sparseEncode(s, 64), BestSpeed, dfZlib)
proc decS64Z(s: string): string = sparseDecode(uncompress(s, dfZlib))
proc encS256Z(s: string): string = compress(sparseEncode(s, 256), BestSpeed, dfZlib)
proc decS256Z(s: string): string = sparseDecode(uncompress(s, dfZlib))
proc encS64ZD(s: string): string = compress(sparseEncode(s, 64), DefaultCompression, dfZlib)
proc encS64L(s: string): string = lz4Compress(sparseEncode(s, 64))
proc decS64L(s: string): string = sparseDecode(lz4Decompress(s))
proc encS64(s: string): string = sparseEncode(s, 64)
proc decS64(s: string): string = sparseDecode(s)

proc rewindCodecs*(): seq[Codec] =
  @[Codec(name: "zlib:BestSpeed(SHIPPED)", enc: encZlib, dec: decZlib),
    Codec(name: "zlib:Default", enc: encZlibDef, dec: decZlib),
    Codec(name: "lz4", enc: encLz4, dec: decLz4),
    Codec(name: "sparse64", enc: encS64, dec: decS64),
    Codec(name: "sparse32+zlib", enc: encS32Z, dec: decS32Z),
    Codec(name: "sparse64+zlib", enc: encS64Z, dec: decS64Z),
    Codec(name: "sparse256+zlib", enc: encS256Z, dec: decS256Z),
    Codec(name: "sparse64+zlib:Def", enc: encS64ZD, dec: decS64Z),
    Codec(name: "sparse64+lz4", enc: encS64L, dec: decS64L)]

proc bakeoff*(deltas: seq[string]; reps = 1): string =
  ## Run every candidate over `deltas`, verifying a bit-exact round trip on
  ## each, and return a plain-text table.
  var cs = rewindCodecs()
  var lines: seq[string]
  lines.add("deltas=" & $deltas.len & " rawBytes=" &
            $(if deltas.len > 0: deltas[0].len else: 0))
  lines.add("codec                     bytes  ratio   enc_ms   dec_ms")
  var baseSize = 0.0
  for c in 0 ..< cs.len:
    var totBytes = 0
    var encNs = 0'i64
    var decNs = 0'i64
    var bad = false
    for r in 0 ..< reps:
      for d in deltas:
        let t0 = getMonoTime()
        let packed = cs[c].enc(d)
        encNs += (getMonoTime() - t0).inNanoseconds
        if r == 0: totBytes += packed.len
        let t1 = getMonoTime()
        let back = cs[c].dec(packed)
        decNs += (getMonoTime() - t1).inNanoseconds
        if back != d: bad = true
    let n = deltas.len * reps
    let meanBytes = (if deltas.len > 0: totBytes.float / deltas.len.float else: 0.0)
    if c == 0: baseSize = meanBytes
    lines.add(cs[c].name.alignLeft(24) &
              align(formatFloat(meanBytes, ffDecimal, 0), 9) &
              align(formatFloat(
                (if baseSize > 0: meanBytes * 100.0 / baseSize else: 0.0),
                ffDecimal, 1) & "%", 7) &
              align(formatFloat(encNs.float / 1e6 / n.float, ffDecimal, 4), 9) &
              align(formatFloat(decNs.float / 1e6 / n.float, ffDecimal, 4), 9) &
              (if bad: "  *** ROUND-TRIP FAILED ***" else: ""))
  lines.join("\n")
