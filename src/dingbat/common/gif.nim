## Animated GIF (GIF89a) from the GB/GBA cores' BGR555 frames: "Clip that!"
## as a GIF, on iOS and the web. Fed every console frame of a replay, it
## keeps every other one (GIF delays are whole centiseconds and players
## slow anything under 2 to 10, so ~30 fps is the most a GIF holds), carries
## the delays in exact centiseconds of the console's 59.73 Hz, folds a
## picture that did not change into the one before, writes only the
## rectangle that changed with unchanged pixels transparent over it, and
## scales by whole pixels (nearest).
##
## Up to 255 colours a frame are kept exactly (a GB or GBC frame always is);
## a GBA frame with more (blends, fades) is cut to 255 by median cut over
## its own colours, no dither. Format: GIF89a specification (W3C/CompuServe
## 1990): logical screen, NETSCAPE2.0 loop, per frame a graphic control
## extension, an image descriptor with its own colour table, LZW data.

import std/algorithm

const
  FrameDots = 70224'i64        ## a GB/GBA frame, in 4 MiHz dots
  DotsPerSec = 4_194_304'i64
  MaxCodes = 4096
  NoCode = 0'u16

type GifWriter* = object
  w, h, scale: int
  lut: seq[uint32]             ## BGR555 -> 0xRRGGBB, a DMG game's shades applied
  data*: seq[byte]
  prev, pend: seq[uint16]      ## the last picture written; the one waiting for its delay
  hasPrev, hasPend: bool
  pendStart: int               ## console frame the waiting picture starts
  frames: int                  ## console frames fed
  slot: seq[int16]             ## colour -> palette index this frame, -1 unused
  count: seq[int32]            ## colour -> pixels this frame
  dict: seq[uint16]            ## LZW (prefix shl 8 or index) -> code
  dictUsed: seq[int32]

proc centis(frame: int): int =
  int((int64(frame) * FrameDots * 100 + DotsPerSec div 2) div DotsPerSec)

proc put16(d: var seq[byte]; v: int) =
  d.add byte(v and 0xFF)
  d.add byte((v shr 8) and 0xFF)

proc gifBegin*(g: var GifWriter; w, h, scale: int; shades: openArray[uint32] = []) =
  ## `shades`: a black-and-white game's four colours (0xRRGGBB, lightest
  ## first) for the core's greys, as on screen; empty for a colour game.
  g = GifWriter(w: w, h: h, scale: max(1, scale))
  g.lut = newSeq[uint32](32768)
  for v in 0 ..< 32768:
    let r = uint32(v and 31) * 255 div 31
    let gg = uint32((v shr 5) and 31) * 255 div 31
    let b = uint32((v shr 10) and 31) * 255 div 31
    g.lut[v] = (r shl 16) or (gg shl 8) or b
  if shades.len == 4:
    # The core's DMG greys (gb.nim DMG_COLORS), lightest first.
    for i, v in [0x7FFF, 0x56B5, 0x294A, 0x0000]: g.lut[v] = shades[i] and 0xFFFFFF
  g.prev = newSeq[uint16](w * h)
  g.pend = newSeq[uint16](w * h)
  g.slot = newSeq[int16](32768)
  for s in g.slot.mitems: s = -1
  g.count = newSeq[int32](32768)
  g.dict = newSeq[uint16](MaxCodes * 256)
  let sw = w * g.scale
  let sh = h * g.scale
  g.data.add "GIF89a".toOpenArrayByte(0, 5)
  g.data.put16 sw
  g.data.put16 sh
  g.data.add [0x00'u8, 0, 0]   # no global colour table; background 0; square pixels
  # NETSCAPE2.0: loop forever.
  g.data.add [0x21'u8, 0xFF, 0x0B]
  g.data.add "NETSCAPE2.0".toOpenArrayByte(0, 10)
  g.data.add [0x03'u8, 0x01, 0x00, 0x00, 0x00]

# --- LZW (variable-length codes, LSB first, in sub-blocks of <= 255) ---

type BitOut = object
  buf: seq[byte]
  acc: uint32
  nbits: int

proc emit(o: var BitOut; code, size: int) =
  o.acc = o.acc or (uint32(code) shl o.nbits)
  o.nbits += size
  while o.nbits >= 8:
    o.buf.add byte(o.acc and 0xFF)
    o.acc = o.acc shr 8
    o.nbits -= 8

proc lzw(g: var GifWriter; idx: openArray[uint8]; minSize: int) =
  let clear = 1 shl minSize
  let eoi = clear + 1
  var o: BitOut
  var next = clear + 2
  var size = minSize + 1
  template reset() =
    for k in g.dictUsed: g.dict[k] = NoCode
    g.dictUsed.setLen(0)
    next = clear + 2
    size = minSize + 1
  o.emit(clear, size)
  var prefix = int(idx[0])
  for i in 1 ..< idx.len:
    let c = int(idx[i])
    let k = (prefix shl 8) or c
    let hit = g.dict[k]
    if hit != NoCode:
      prefix = int(hit)
      continue
    o.emit(prefix, size)
    if next < MaxCodes:
      g.dict[k] = uint16(next)
      g.dictUsed.add int32(k)
      inc next
      # The decoder adds each code one step later, so it widens when its
      # next code passes 2^size: here, one past that.
      if next > (1 shl size) and size < 12: inc size
    else:
      o.emit(clear, size)
      reset()
    prefix = c
  o.emit(prefix, size)
  o.emit(eoi, size)
  if o.nbits > 0: o.buf.add byte(o.acc and 0xFF)
  reset()
  g.data.add byte(minSize)
  var p = 0
  while p < o.buf.len:
    let n = min(255, o.buf.len - p)
    g.data.add byte(n)
    g.data.add o.buf.toOpenArray(p, p + n - 1)
    p += n
  g.data.add 0'u8

# --- Colours ---

proc medianCut(g: var GifWriter; colours: seq[int]; palette: var seq[uint32]) =
  ## Up to 255 boxes over this frame's colours, split at the pixel-weighted
  ## median of the widest channel; each colour's slot is its box's average.
  type Box = tuple[lo, hi, ch, score: int]   # into `cs`, hi exclusive
  var cs = colours
  proc ch(g: GifWriter; v, c: int): int = int((g.lut[v] shr (16 - 8 * c)) and 0xFF)
  proc box(g: GifWriter; cs: seq[int]; lo, hi: int): Box =
    ## Its widest channel, and span x pixels: the box most worth splitting.
    var mn = [255, 255, 255]
    var mx = [0, 0, 0]
    var px = 0
    for i in lo ..< hi:
      px += int(g.count[cs[i]])
      for c in 0 .. 2:
        let x = g.ch(cs[i], c)
        mn[c] = min(mn[c], x)
        mx[c] = max(mx[c], x)
    var best = 0
    for c in 1 .. 2:
      if mx[c] - mn[c] > mx[best] - mn[best]: best = c
    (lo, hi, best, if hi - lo < 2: -1 else: (mx[best] - mn[best]) * px)
  var boxes: seq[Box] = @[g.box(cs, 0, cs.len)]
  while boxes.len < 255:
    var pick = -1
    for i, b in boxes:
      if b.score >= 0 and (pick < 0 or b.score > boxes[pick].score): pick = i
    if pick < 0: break
    let b = boxes[pick]
    var keyed = newSeq[(int, int)](b.hi - b.lo)
    for j in 0 ..< keyed.len: keyed[j] = (g.ch(cs[b.lo + j], b.ch), cs[b.lo + j])
    keyed.sort()
    var part = newSeq[int](keyed.len)
    for j, kv in keyed: part[j] = kv[1]
    var total = 0
    for v in part: total += int(g.count[v])
    var acc = 0
    var cut = 1
    for j, v in part:
      acc += int(g.count[v])
      if acc * 2 >= total:
        cut = clamp(j + 1, 1, part.len - 1)
        break
    for j, v in part: cs[b.lo + j] = v
    boxes[pick] = g.box(cs, b.lo, b.lo + cut)
    boxes.add g.box(cs, b.lo + cut, b.hi)
  palette.setLen(0)
  for bi, b in boxes:
    var sum = [0'i64, 0, 0]
    var n = 0'i64
    for i in b.lo ..< b.hi:
      let v = cs[i]
      let k = int64(g.count[v])
      for c in 0 .. 2: sum[c] += int64(g.ch(v, c)) * k
      n += k
      g.slot[v] = int16(bi)
    n = max(n, 1)
    palette.add (uint32(sum[0] div n) shl 16) or (uint32(sum[1] div n) shl 8) or uint32(sum[2] div n)
  # Each colour to the nearest average, which is not always its own box's.
  for v in cs:
    var best = int(g.slot[v])
    var bestD = high(int)
    for i, p in palette:
      var d = 0
      for c in 0 .. 2:
        let e = g.ch(v, c) - int((p shr (16 - 8 * c)) and 0xFF)
        d += e * e
      if d < bestD:
        bestD = d; best = i
    g.slot[v] = int16(best)

proc writeFrame(g: var GifWriter; px: openArray[uint16]; delay: int) =
  let w = g.w
  var x0 = 0
  var y0 = 0
  var x1 = w - 1
  var y1 = g.h - 1
  if g.hasPrev:
    x0 = w; y0 = g.h; x1 = -1; y1 = -1
    for y in 0 ..< g.h:
      for x in 0 ..< w:
        if px[y * w + x] != g.prev[y * w + x]:
          x0 = min(x0, x); x1 = max(x1, x)
          y0 = min(y0, y); y1 = max(y1, y)
    if x1 < 0:
      # Nothing changed (only a caller's last picture can be): a 1x1
      # transparent frame keeps the time.
      x0 = 0; y0 = 0; x1 = 0; y1 = 0
  # The colours of the changed pixels.
  var colours: seq[int] = @[]
  var transparent = false
  for y in y0 .. y1:
    for x in x0 .. x1:
      let i = y * w + x
      if g.hasPrev and px[i] == g.prev[i]:
        transparent = true
        continue
      let v = int(px[i] and 0x7FFF)
      if g.count[v] == 0: colours.add v
      inc g.count[v]
  var palette: seq[uint32] = @[]
  if colours.len <= 255:
    for i, v in colours:
      g.slot[v] = int16(i)
      palette.add g.lut[v]
  else:
    g.medianCut(colours, palette)
  let tIndex = palette.len
  if transparent or palette.len == 0: palette.add 0
  var bits = 1
  while (1 shl bits) < palette.len: inc bits
  # Graphic control: disposal 1 (leave in place), the transparent index.
  g.data.add [0x21'u8, 0xF9, 0x04, byte((1 shl 2) or (if transparent: 1 else: 0))]
  g.data.put16 clamp(delay, 2, 65535)
  g.data.add byte(if transparent: tIndex else: 0)
  g.data.add 0'u8
  # Image descriptor and its colour table, at scale.
  let s = g.scale
  let fw = (x1 - x0 + 1) * s
  let fh = (y1 - y0 + 1) * s
  g.data.add 0x2C'u8
  g.data.put16 x0 * s
  g.data.put16 y0 * s
  g.data.put16 fw
  g.data.put16 fh
  g.data.add byte(0x80 or (bits - 1))
  for i in 0 ..< (1 shl bits):
    let c = if i < palette.len: palette[i] else: 0'u32
    g.data.add [byte(c shr 16), byte((c shr 8) and 0xFF), byte(c and 0xFF)]
  var idx = newSeq[uint8](fw * fh)
  var o = 0
  for y in y0 .. y1:
    let rowStart = o
    for x in x0 .. x1:
      let i = y * w + x
      let k = if g.hasPrev and px[i] == g.prev[i]: uint8(tIndex)
              else: uint8(g.slot[int(px[i] and 0x7FFF)])
      for _ in 0 ..< s:
        idx[o] = k
        inc o
    for _ in 1 ..< s:
      for j in 0 ..< fw: idx[o + j] = idx[rowStart + j]
      o += fw
  g.lzw(idx, max(2, bits))
  for v in colours:
    g.count[v] = 0
    g.slot[v] = -1
  for i in 0 ..< px.len: g.prev[i] = px[i]
  g.hasPrev = true

proc gifFrame*(g: var GifWriter; fb: openArray[uint16]) =
  ## One console frame (w*h BGR555), every frame of the replay in order.
  if g.frames mod 2 == 0:
    var same = g.hasPend
    if same:
      for i in 0 ..< g.pend.len:
        if (fb[i] and 0x7FFF) != g.pend[i]:
          same = false
          break
    if not same:
      if g.hasPend:
        g.writeFrame(g.pend, centis(g.frames) - centis(g.pendStart))
      for i in 0 ..< g.pend.len: g.pend[i] = fb[i] and 0x7FFF
      g.pendStart = g.frames
      g.hasPend = true
  inc g.frames

proc gifFinish*(g: var GifWriter) =
  ## The last picture and the trailer: `data` is the whole file.
  if g.hasPend:
    g.writeFrame(g.pend, centis(g.frames) - centis(g.pendStart))
    g.hasPend = false
  g.data.add 0x3B'u8
  g.prev = @[]
  g.pend = @[]
  g.slot = @[]
  g.count = @[]
  g.dict = @[]
  g.lut = @[]

proc gifFrames*(g: GifWriter): int = g.frames
