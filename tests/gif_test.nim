## The clip GIF encoder (src/dingbat/common/gif.nim), decoded back here frame
## by frame: every picture comes out as fed (scaled, the shades applied),
## ~30 fps with the delays adding up to the console's time, unchanged
## pictures folded, more than 255 colours cut close, and a small change
## costing a small frame.
## Run: nimble test_gif

import std/[strformat]
import dingbat/common/gif

var failures = 0
proc check(cond: bool; msg: string) =
  if not cond:
    echo "FAIL: ", msg
    inc failures

type Decoded = object
  w, h: int
  frames: seq[seq[uint32]]     # the canvas after each frame, 0xRRGGBB
  delays: seq[int]
  maxTable: int
  frameBytes: seq[int]         # LZW bytes per frame

proc u16(d: seq[byte]; p: int): int = int(d[p]) or (int(d[p + 1]) shl 8)

proc unlzw(data: seq[byte]; minSize, count: int): seq[int] =
  let clear = 1 shl minSize
  let eoi = clear + 1
  var prefix = newSeq[int](4096)
  var suffix = newSeq[int](4096)
  var lens = newSeq[int](4096)
  for i in 0 ..< clear: suffix[i] = i; lens[i] = 1; prefix[i] = -1
  var size = minSize + 1
  var avail = clear + 2
  var old = -1
  var acc = 0
  var nbits = 0
  var p = 0
  proc str(code: int): seq[int] =
    result = newSeq[int](lens[code])
    var c = code
    for i in countdown(lens[code] - 1, 0):
      result[i] = suffix[c]
      c = prefix[c]
  while true:
    while nbits < size:
      if p >= data.len: return
      acc = acc or (int(data[p]) shl nbits)
      inc p
      nbits += 8
    let code = acc and ((1 shl size) - 1)
    acc = acc shr size
    nbits -= size
    if code == clear:
      size = minSize + 1
      avail = clear + 2
      old = -1
      continue
    if code == eoi: return
    var s: seq[int]
    if old < 0:
      s = str(code)
    elif code < avail:
      s = str(code)
      if avail < 4096:
        prefix[avail] = old; suffix[avail] = s[0]; lens[avail] = lens[old] + 1
        inc avail
    else:
      let o = str(old)
      s = o & o[0]
      if avail < 4096:
        prefix[avail] = old; suffix[avail] = o[0]; lens[avail] = lens[old] + 1
        inc avail
    result.add s
    old = code
    if avail == (1 shl size) and size < 12: inc size
    if result.len > count: return

proc decode(d: seq[byte]): Decoded =
  doAssert d[0 .. 5] == @[byte('G'), byte('I'), byte('F'), byte('8'), byte('9'), byte('a')]
  result.w = d.u16(6)
  result.h = d.u16(8)
  doAssert (d[10] and 0x80) == 0, "no global table expected"
  var canvas = newSeq[uint32](result.w * result.h)
  var p = 13
  var delay = 0
  var transparent = -1
  while p < d.len:
    case d[p]
    of 0x21:
      let label = d[p + 1]
      p += 2
      if label == 0xF9:
        transparent = if (d[p + 1] and 1) != 0: int(d[p + 4]) else: -1
        delay = d.u16(p + 2)
      while d[p] != 0: p += int(d[p]) + 1
      inc p
    of 0x2C:
      let x0 = d.u16(p + 1)
      let y0 = d.u16(p + 3)
      let fw = d.u16(p + 5)
      let fh = d.u16(p + 7)
      let flags = d[p + 9]
      doAssert (flags and 0x80) != 0, "a local table"
      let n = 1 shl (int(flags and 7) + 1)
      result.maxTable = max(result.maxTable, n)
      p += 10
      var table = newSeq[uint32](n)
      for i in 0 ..< n:
        table[i] = (uint32(d[p]) shl 16) or (uint32(d[p + 1]) shl 8) or uint32(d[p + 2])
        p += 3
      let minSize = int(d[p])
      inc p
      var lz: seq[byte] = @[]
      while d[p] != 0:
        lz.add d[p + 1 .. p + int(d[p])]
        p += int(d[p]) + 1
      inc p
      result.frameBytes.add lz.len
      let idx = unlzw(lz, minSize, fw * fh)
      doAssert idx.len >= fw * fh, &"frame data short: {idx.len} of {fw * fh}"
      for y in 0 ..< fh:
        for x in 0 ..< fw:
          let k = idx[y * fw + x]
          if k != transparent: canvas[(y0 + y) * result.w + x0 + x] = table[k]
      result.frames.add canvas
      result.delays.add delay
    of 0x3B: break
    else: doAssert false, &"unexpected block {d[p]} at {p}"

proc rgb(v: uint16): uint32 =
  let r = uint32(v and 31) * 255 div 31
  let g = uint32((v shr 5) and 31) * 255 div 31
  let b = uint32((v shr 10) and 31) * 255 div 31
  (r shl 16) or (g shl 8) or b

proc scaled(src: seq[uint32]; w, h, s: int): seq[uint32] =
  result = newSeq[uint32](w * h * s * s)
  for y in 0 ..< h * s:
    for x in 0 ..< w * s: result[y * w * s + x] = src[(y div s) * w + x div s]

echo "A black-and-white game: shades, scale, frame rate, delays"
block:
  const W = 160
  const H = 144
  let greys = [0x7FFF'u16, 0x56B5, 0x294A, 0x0000]
  let shades = [0xE0F8D0'u32, 0x88C070, 0x346856, 0x081820]
  var g: GifWriter
  g.gifBegin(W, H, 3, shades)
  var want: seq[seq[uint32]] = @[]
  for f in 0 ..< 120:
    # A new picture every 4 frames: a bar that walks right.
    var fb = newSeq[uint16](W * H)
    let step = f div 4
    for y in 0 ..< H:
      for x in 0 ..< W:
        fb[y * W + x] = greys[if x div 8 == step mod 20: 3 else: (y div 36) mod 3]
    if f mod 4 == 0:
      var c = newSeq[uint32](W * H)
      for i, v in fb: c[i] = shades[[0x7FFF'u16, 0x56B5, 0x294A, 0x0000].find(v)]
      want.add scaled(c, W, H, 3)
    g.gifFrame(fb)
  g.gifFinish()
  let d = decode(g.data)
  check d.w == W * 3 and d.h == H * 3, &"canvas {d.w}x{d.h}"
  check d.frames.len == 30, &"a frame per new picture: {d.frames.len}"
  var same = d.frames.len == want.len
  for i in 0 ..< min(d.frames.len, want.len):
    if d.frames[i] != want[i]: same = false
  check same, "every picture decodes as fed, in the shades"
  var total = 0
  for t in d.delays: total += t
  check total == 201, &"the delays add up to 120 frames (201 cs): {total}"
  check d.delays[0] in 6 .. 7, &"4 frames is 6.7 cs: {d.delays[0]}"
  check d.maxTable <= 8, &"a few colours, a small table: {d.maxTable}"

echo "A still picture is one frame"
block:
  var g: GifWriter
  g.gifBegin(16, 16, 1)
  let fb = newSeq[uint16](256)
  for _ in 0 ..< 600: g.gifFrame(fb)
  g.gifFinish()
  let d = decode(g.data)
  check d.frames.len == 1, &"one frame: {d.frames.len}"
  check d.delays == @[1005], &"10 s: {d.delays}"

echo "A GBA picture over 255 colours, and a small change"
block:
  const W = 240
  const H = 160
  var base = newSeq[uint16](W * H)
  for y in 0 ..< H:
    for x in 0 ..< W:
      # Smooth gradients over all three channels: thousands of colours.
      let r = x * 31 div (W - 1)
      let gg = y * 31 div (H - 1)
      let b = ((x + y) * 31 div (W + H - 2))
      base[y * W + x] = uint16(r or (gg shl 5) or (b shl 10))
  var g: GifWriter
  g.gifBegin(W, H, 2)
  var fb = base
  g.gifFrame(fb); g.gifFrame(fb)
  # An 8x8 sprite moves 4 pixels.
  for y in 50 ..< 58:
    for x in 100 ..< 108: fb[y * W + x] = 0x001F
  g.gifFrame(fb); g.gifFrame(fb)
  g.gifFinish()
  let d = decode(g.data)
  check d.frames.len == 2, &"two pictures: {d.frames.len}"
  check d.maxTable == 256, &"cut to one table: {d.maxTable}"
  var err = 0'i64
  var worst = 0
  let want = scaled((var c = newSeq[uint32](W * H); for i, v in base: c[i] = rgb(v); c), W, H, 2)
  for i in 0 ..< want.len:
    let a = want[i]
    let b = d.frames[0][i]
    var e = 0
    for sh in [16, 8, 0]:
      e = max(e, abs(int((a shr sh) and 0xFF) - int((b shr sh) and 0xFF)))
    err += e
    worst = max(worst, e)
  let mean = float(err) / float(want.len)
  check mean < 6.0, &"close to the colours fed: mean {mean:.2f}"
  check worst < 40, &"and nowhere far off: worst {worst}"
  check d.frames[1][(54 * 2) * W * 2 + 104 * 2] == 0xFF0000, "the sprite"
  check d.frames[1][0] == d.frames[0][0], "the rest stays"
  check d.frameBytes[1] < 200, &"a small change, a small frame: {d.frameBytes[1]} bytes"

if failures > 0:
  echo &"{failures} failure(s)"
  quit 1
echo "gif: all passed"
