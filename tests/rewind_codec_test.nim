## Rewind delta characterisation + codec bake-off.
##
## Build: nim c -d:test_harness -d:release -d:deltachar --path:src \
##          -o:rewind_codec tests/rewind_codec_test.nim
## Usage: rewind_codec <rom> [frames] [warmup] [state] [input_script]
##
## Runs a real game, snapshots every REWIND_INTERVAL frames as
## common/rewind.nim does, and for every consecutive pair reports the XOR
## delta's shape (zero fraction, run lengths, dirty pages/blocks, which
## payload SECTION the non-zero bytes live in via -d:deltachar's offset
## table) and every candidate codec's size and encode/decode time. A codec
## that does not round-trip byte for byte aborts the run.
import std/[os, strutils, times, monotimes, algorithm, math, bitops]
import zippy
import dingbat/gba/gba
import dingbat/gb/gb
import dingbat/common/input
import dingbat/common/test_output
import dingbat/common/rewind
import dingbat/common/scheduler
import dingbat/common/lz4

# ---------------------------------------------------------------- helpers

proc xor_delta(prev, cur: string): string =
  ## Exactly what rewind.encode_delta builds before it compresses.
  result = prev
  let k = min(prev.len, cur.len)
  let words = k div 8
  if words > 0:
    let d = cast[ptr UncheckedArray[uint64]](addr result[0])
    let s = cast[ptr UncheckedArray[uint64]](unsafeAddr cur[0])
    for i in 0 ..< words: d[i] = d[i] xor s[i]
  for i in (words * 8) ..< k:
    result[i] = char(uint8(result[i]) xor uint8(cur[i]))

type Stat = object
  n: int
  total: float
  worst: float

proc add(s: var Stat; v: float) =
  s.n.inc; s.total += v
  if v > s.worst: s.worst = v

proc mean(s: Stat): float = (if s.n > 0: s.total / s.n.float else: 0.0)

# ---------------------------------------------------------------- codecs
# Every codec is (name, encode, decode); sizes are encoded bytes.
type Codec = object
  name: string
  enc: proc(src: string): string {.nimcall.}
  dec: proc(src: string; hint: int): string {.nimcall.}

proc encZlib(src: string): string = compress(src, BestSpeed, dfZlib)
proc decZlib(src: string; hint: int): string = uncompress(src, dfZlib)

proc encZlibNone(src: string): string = compress(src, NoCompression, dfZlib)
proc decZlibNone(src: string; hint: int): string = uncompress(src, dfZlib)

proc encDeflate(src: string): string = compress(src, BestSpeed, dfDeflate)
proc decDeflate(src: string; hint: int): string = uncompress(src, dfDeflate)

# --- sparse block codec -------------------------------------------------
# The delta is an XOR, so "unchanged" is a zero byte: a bitmap of which
# fixed-size blocks contain ANY non-zero byte, then those blocks raw.
# Format: u32 original length, u32 block size, ceil(nblocks/8) bitmap bytes,
# then the payload of each set block back to back (the final block may be
# short; its length falls out of the original length).
proc sparseEncode(src: string; bs: int): string =
  let n = src.len
  let nblocks = (n + bs - 1) div bs
  let bitmapBytes = (nblocks + 7) div 8
  var bitmap = newString(bitmapBytes)
  var body = newStringOfCap(n div 4 + 64)
  for b in 0 ..< nblocks:
    let lo = b * bs
    let hi = min(lo + bs, n)
    var any = false
    # word-at-a-time scan: the whole point is not to touch zeros byte by byte
    var i = lo
    while i + 8 <= hi:
      if cast[ptr uint64](unsafeAddr src[i])[] != 0: any = true; break
      i += 8
    if not any:
      while i < hi:
        if src[i] != '\0': any = true; break
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

proc sparseDecode(src: string): string =
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

proc encSparse64(s: string): string = sparseEncode(s, 64)
proc decSparse64(s: string; hint: int): string = sparseDecode(s)
proc encSparse256(s: string): string = sparseEncode(s, 256)
proc decSparse256(s: string; hint: int): string = sparseDecode(s)
proc encSparse16(s: string): string = sparseEncode(s, 16)
proc decSparse16(s: string; hint: int): string = sparseDecode(s)
proc encSparse32(s: string): string = sparseEncode(s, 32)
proc decSparse32(s: string; hint: int): string = sparseDecode(s)
proc encSparse32Zlib(s: string): string = compress(sparseEncode(s, 32), BestSpeed, dfZlib)
proc decSparse32Zlib(s: string; hint: int): string = sparseDecode(uncompress(s, dfZlib))
proc encSparse64ZlibD(s: string): string = compress(sparseEncode(s, 64), DefaultCompression, dfZlib)
proc decSparse64ZlibD(s: string; hint: int): string = sparseDecode(uncompress(s, dfZlib))
proc encZlibDefault(s: string): string = compress(s, DefaultCompression, dfZlib)
proc decZlibDefault(s: string; hint: int): string = uncompress(s, dfZlib)
proc encSparse4k(s: string): string = sparseEncode(s, 4096)
proc decSparse4k(s: string; hint: int): string = sparseDecode(s)

# --- sparse block, then zlib on the packed body -------------------------
proc encSparse64Zlib(s: string): string = compress(sparseEncode(s, 64), BestSpeed, dfZlib)
proc decSparse64Zlib(s: string; hint: int): string = sparseDecode(uncompress(s, dfZlib))
proc encSparse256Zlib(s: string): string = compress(sparseEncode(s, 256), BestSpeed, dfZlib)
proc decSparse256Zlib(s: string; hint: int): string = sparseDecode(uncompress(s, dfZlib))

# --- sparse block, then LZ4 on the packed body --------------------------
proc encSparse64Lz4(s: string): string = lz4Compress(sparseEncode(s, 64))
proc decSparse64Lz4(s: string; hint: int): string = sparseDecode(lz4Decompress(s))
proc encSparse256Lz4(s: string): string = lz4Compress(sparseEncode(s, 256))
proc decSparse256Lz4(s: string; hint: int): string = sparseDecode(lz4Decompress(s))

# --- plain LZ4 ----------------------------------------------------------
proc encLz4(s: string): string = lz4Compress(s)
proc decLz4(s: string; hint: int): string = lz4Decompress(s, hint)

proc codecs(): seq[Codec] =
  @[Codec(name: "zlib:BestSpeed (SHIPPED)", enc: encZlib, dec: decZlib),
    Codec(name: "zlib:store", enc: encZlibNone, dec: decZlibNone),
    Codec(name: "raw deflate:BestSpeed", enc: encDeflate, dec: decDeflate),
    Codec(name: "lz4", enc: encLz4, dec: decLz4),
    Codec(name: "zlib:Default", enc: encZlibDefault, dec: decZlibDefault),
    Codec(name: "sparse16", enc: encSparse16, dec: decSparse16),
    Codec(name: "sparse32", enc: encSparse32, dec: decSparse32),
    Codec(name: "sparse64", enc: encSparse64, dec: decSparse64),
    Codec(name: "sparse256", enc: encSparse256, dec: decSparse256),
    Codec(name: "sparse4k", enc: encSparse4k, dec: decSparse4k),
    Codec(name: "sparse64+zlib", enc: encSparse64Zlib, dec: decSparse64Zlib),
    Codec(name: "sparse256+zlib", enc: encSparse256Zlib, dec: decSparse256Zlib),
    Codec(name: "sparse32+zlib", enc: encSparse32Zlib, dec: decSparse32Zlib),
    Codec(name: "sparse64+zlibDef", enc: encSparse64ZlibD, dec: decSparse64ZlibD),
    Codec(name: "sparse64+lz4", enc: encSparse64Lz4, dec: decSparse64Lz4),
    Codec(name: "sparse256+lz4", enc: encSparse256Lz4, dec: decSparse256Lz4)]

# ---------------------------------------------------------------- main

type InputEvent = tuple[frame: int, key: Input, pressed: bool]

proc parse_script(script: string): seq[InputEvent] =
  for entry in script.split(','):
    if entry.len == 0: continue
    let parts = entry.split(':')
    let frame = parseInt(parts[0])
    let key = parseEnum[Input](parts[1].toUpperAscii())
    let hold = if parts.len > 2: parseInt(parts[2]) else: 10
    result.add((frame, key, true))
    result.add((frame + hold, key, false))

proc main() =
  let args = commandLineParams()
  if args.len < 1:
    echo "usage: rewind_codec <rom> [frames] [warmup] [state] [script]"
    quit(1)
  let rom = args[0]
  let frames = if args.len > 1: parseInt(args[1]) else: 1200
  let warmup = if args.len > 2: parseInt(args[2]) else: 120
  let statePath = if args.len > 3: args[3] else: ""
  let script = if args.len > 4: parse_script(args[4]) else: @[]

  let isGb = rom.splitFile.ext.toLowerAscii() in [".gb", ".gbc"]
  var emu: GBA = nil
  var gbEmu: GB = nil
  if isGb:
    gbEmu = new_gb("", rom, fifo = true, headless = true, run_bios = false)
    gbEmu.test_output = new_test_output()
    gbEmu.post_init()
    if statePath.len > 0 and not gbEmu.load_state_bytes(readFile(statePath)):
      echo "state REJECTED: ", statePath; quit(1)
  else:
    emu = new_gba("", rom, run_bios = false, use_hle = true)
    emu.test_output = new_test_output()
    emu.post_init()
    if statePath.len > 0 and not emu.load_state_bytes(readFile(statePath)):
      echo "state REJECTED: ", statePath; quit(1)

  template step(f: int) =
    if isGb:
      for ev in script:
        if ev.frame == f: gbEmu.handle_input(ev.key, ev.pressed)
      gbEmu.step_frame()
    else:
      for ev in script:
        if ev.frame == f: emu.handle_input(ev.key, ev.pressed)
      emu.step_frame()

  template payload_now(): string =
    (if isGb: gbEmu.state_payload() else: emu.state_payload())

  for f in 0 ..< warmup: step(f)

  var cs = codecs()
  var encT = newSeq[Stat](cs.len)
  var decT = newSeq[Stat](cs.len)
  var size = newSeq[Stat](cs.len)

  # delta shape
  var zeroFrac, dirty64, dirty256, dirty4k: Stat
  var runHist: array[24, int]     # log2 buckets of zero-run length
  var sectionNz: seq[Stat]
  var sectionNames: seq[string]
  var sectionSpans: seq[(int, int)]
  var deltaLen: Stat
  var prev = ""
  var pushes = 0
  var lenMin = high(int)
  var lenMax = 0
  var lenChanges = 0
  var serT: Stat

  for i in 0 ..< frames:
    step(warmup + i)
    if (i + 1) mod REWIND_INTERVAL != 0: continue
    let t0 = getMonoTime()
    let cur = payload_now()
    serT.add((getMonoTime() - t0).inNanoseconds.float / 1e6)
    when defined(deltachar):
      if sectionNames.len == 0:
        for k in 0 ..< payloadSections.len:
          let (nm, off) = payloadSections[k]
          let nxt = if k + 1 < payloadSections.len:
                      payloadSections[k + 1][1] else: cur.len
          sectionNames.add(nm & " [" & $(nxt - off) & "B]")
          sectionSpans.add((off, nxt))
        sectionNz = newSeq[Stat](sectionNames.len)
    lenMin = min(lenMin, cur.len)
    lenMax = max(lenMax, cur.len)
    if prev.len > 0 and prev.len != cur.len: lenChanges.inc
    if prev.len == 0:
      prev = cur
      continue
    let d = xor_delta(prev, cur)
    prev = cur
    pushes.inc
    deltaLen.add(d.len.float)

    # --- shape ---
    var nz = 0
    var run = 0
    for k in 0 ..< d.len:
      if d[k] == '\0': run.inc
      else:
        nz.inc
        if run > 0:
          runHist[min(23, fastLog2(uint32(max(1, run))))].inc
          run = 0
    if run > 0: runHist[min(23, fastLog2(uint32(max(1, run))))].inc
    zeroFrac.add((d.len - nz).float * 100.0 / d.len.float)

    proc dirtyPct(bs: int): float =
      let nb = (d.len + bs - 1) div bs
      var hit = 0
      for b in 0 ..< nb:
        let lo = b * bs
        let hi = min(lo + bs, d.len)
        var any = false
        var j = lo
        while j + 8 <= hi:
          if cast[ptr uint64](unsafeAddr d[j])[] != 0: any = true; break
          j += 8
        if not any:
          while j < hi:
            if d[j] != '\0': any = true; break
            j.inc
        if any: hit.inc
      hit.float * 100.0 / nb.float
    dirty64.add(dirtyPct(64))
    dirty256.add(dirtyPct(256))
    dirty4k.add(dirtyPct(4096))

    var perPush = ""
    for k in 0 ..< sectionSpans.len:
      let (lo, hi0) = sectionSpans[k]
      let hi = min(hi0, d.len)
      var c = 0
      for j in lo ..< hi:
        if d[j] != '\0': c.inc
      sectionNz[k].add(c.float)
      if getEnv("DELTA_TRACE") == "1" and (hi - lo) > 4096:
        perPush.add(" " & sectionNames[k].split(' ')[0] & "=" & $c)
    if getEnv("DELTA_TRACE") == "1":
      echo "  push ", align($pushes, 4), " len=", cur.len, " (dlen=", d.len, ")", perPush

    # --- codecs, with a bit-exactness gate on every delta ---
    for c in 0 ..< cs.len:
      let e0 = getMonoTime()
      let packed = cs[c].enc(d)
      encT[c].add((getMonoTime() - e0).inNanoseconds.float / 1e6)
      size[c].add(packed.len.float)
      let d0 = getMonoTime()
      let back = cs[c].dec(packed, d.len)
      decT[c].add((getMonoTime() - d0).inNanoseconds.float / 1e6)
      if back != d:
        echo "ROUND-TRIP FAILURE in ", cs[c].name, " at push ", pushes,
             " (", back.len, " vs ", d.len, " bytes)"
        quit(1)

  echo "ROM: ", rom.splitFile.name, "   pushes: ", pushes,
       "   payload: ", int(prev.len), " B   delta(raw): ",
       formatFloat(deltaLen.mean, ffDecimal, 0), " B"
  echo "  serialize: ", formatFloat(serT.mean, ffDecimal, 4), " ms/push"
  echo ""
  echo "  payload length: min ", lenMin, " max ", lenMax,
       "  (changed on ", lenChanges, " of ", pushes, " pushes",
       (if lenChanges == 0: " — FIXED LENGTH" else: " — VARIABLE, deltas will misalign"), ")"
  echo "  --- delta shape (mean over pushes) ---"
  echo "    zero bytes:        ", formatFloat(zeroFrac.mean, ffDecimal, 2), "%"
  echo "    dirty 64 B blocks: ", formatFloat(dirty64.mean, ffDecimal, 2),
       "%   (worst push ", formatFloat(dirty64.worst, ffDecimal, 2), "%)"
  echo "    dirty 256 B blocks:", formatFloat(dirty256.mean, ffDecimal, 2),
       "%   (worst push ", formatFloat(dirty256.worst, ffDecimal, 2), "%)"
  echo "    dirty 4 KB pages:  ", formatFloat(dirty4k.mean, ffDecimal, 2),
       "%   (worst push ", formatFloat(dirty4k.worst, ffDecimal, 2), "%)"
  echo "    zero-run length histogram (log2 bucket: count over the whole run)"
  for b in 0 ..< 24:
    if runHist[b] > 0:
      echo "      2^", align($b, 2), " (", align($(1 shl b), 8), " B): ", runHist[b]
  if sectionNames.len > 0:
    echo "  --- where the changed bytes are (mean non-zero bytes per push) ---"
    for k in 0 ..< sectionNames.len:
      if sectionNz[k].mean >= 1.0:
        echo "    ", sectionNames[k].alignLeft(30),
             align(formatFloat(sectionNz[k].mean, ffDecimal, 0), 9), " B"
  echo ""
  echo "  --- codecs (all round-trip verified on every delta) ---"
  echo "    ", "codec".alignLeft(26), align("bytes", 9), align("ratio", 8),
       align("enc ms", 9), align("dec ms", 9)
  let baseSize = size[0].mean
  for c in 0 ..< cs.len:
    echo "    ", cs[c].name.alignLeft(26),
         align(formatFloat(size[c].mean, ffDecimal, 0), 9),
         align(formatFloat(size[c].mean * 100.0 / baseSize, ffDecimal, 1) & "%", 8),
         align(formatFloat(encT[c].mean, ffDecimal, 4), 9),
         align(formatFloat(decT[c].mean, ffDecimal, 4), 9)

main()
