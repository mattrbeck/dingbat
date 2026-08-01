## Minimal PNG reader for test comparison.
## Supports greyscale (1/2/4/8-bit), indexed color (PLTE), 8-bit truecolor and
## 8-bit truecolor+alpha, non-interlaced only.
## Requires the 'zippy' nimble package for zlib decompression.

import std/streams
import zippy

type PngImage* = object
  width*, height*: int
  channels*: int              # 1 = greyscale, 3 = RGB
  pixels*: seq[uint8]         # greyscale: 1 byte/pixel; RGB: 3 bytes/pixel

proc read_u32_be(s: Stream): uint32 =
  var buf: array[4, uint8]
  discard s.readData(addr buf[0], 4)
  (uint32(buf[0]) shl 24) or (uint32(buf[1]) shl 16) or
  (uint32(buf[2]) shl 8) or uint32(buf[3])

proc paeth_predictor(a, b, c: int): int =
  let p = a + b - c
  let pa = abs(p - a)
  let pb = abs(p - b)
  let pc = abs(p - c)
  if pa <= pb and pa <= pc: a
  elif pb <= pc: b
  else: c

proc read_png*(path: string): PngImage =
  let s = newFileStream(path, fmRead)
  defer: s.close()

  # Skip PNG signature
  s.setPosition(8)

  var width, height: int
  var bit_depth, color_type: uint8
  var idat_data: string
  var palette: seq[array[3, uint8]]

  while not s.atEnd:
    let length = s.read_u32_be()
    var chunk_type: array[4, char]
    discard s.readData(addr chunk_type[0], 4)
    let ct = $chunk_type[0] & $chunk_type[1] & $chunk_type[2] & $chunk_type[3]

    if ct == "IHDR":
      width = int(s.read_u32_be())
      height = int(s.read_u32_be())
      bit_depth = s.readUint8()
      color_type = s.readUint8()
      discard s.readUint8()  # compression
      discard s.readUint8()  # filter
      discard s.readUint8()  # interlace
      let remaining = int(length) - 13
      if remaining > 0: s.setPosition(s.getPosition() + remaining)
    elif ct == "PLTE":
      let count = int(length) div 3
      palette = newSeq[array[3, uint8]](count)
      for i in 0 ..< count:
        palette[i][0] = s.readUint8()
        palette[i][1] = s.readUint8()
        palette[i][2] = s.readUint8()
    elif ct == "IDAT":
      let old_len = idat_data.len
      idat_data.setLen(old_len + int(length))
      discard s.readData(addr idat_data[old_len], int(length))
    elif ct == "IEND":
      s.setPosition(s.getPosition() + int(length))
      discard s.read_u32_be()  # CRC
      break
    else:
      s.setPosition(s.getPosition() + int(length))

    discard s.read_u32_be()  # CRC

  # Decompress IDAT
  let raw = uncompress(idat_data, dfZlib)

  let pixels_per_byte = 8 div int(bit_depth)
  let stride = (width + pixels_per_byte - 1) div pixels_per_byte
  let row_bytes = stride + 1  # +1 for filter byte

  result.width = width
  result.height = height

  var prev_row = newSeq[uint8](stride)
  var curr_row = newSeq[uint8](stride)

  if color_type == 2 or color_type == 6:
    # Truecolor, with (6) or without (2) an alpha channel; 8-bit only. The
    # filters operate on whole pixels, so the "left" neighbour is bpp bytes
    # back — 3 for RGB, 4 for RGBA. Alpha is dropped: every reference image
    # these tests compare against is fully opaque, and the callers all want
    # 3 bytes per pixel.
    doAssert bit_depth == 8, "truecolor PNG: only 8-bit supported"
    let bpp = if color_type == 6: 4 else: 3
    result.channels = 3
    result.pixels = newSeq[uint8](width * height * 3)
    let rgb_stride = width * bpp
    let rgb_row_bytes = rgb_stride + 1
    var prev = newSeq[uint8](rgb_stride)
    var curr = newSeq[uint8](rgb_stride)

    for y in 0 ..< height:
      let offset = y * rgb_row_bytes
      let filter_type = uint8(raw[offset])
      for i in 0 ..< rgb_stride:
        curr[i] = uint8(raw[offset + 1 + i])

      case filter_type
      of 0: discard
      of 1:
        for i in bpp ..< rgb_stride:
          curr[i] = uint8((int(curr[i]) + int(curr[i - bpp])) and 0xFF)
      of 2:
        for i in 0 ..< rgb_stride:
          curr[i] = uint8((int(curr[i]) + int(prev[i])) and 0xFF)
      of 3:
        for i in 0 ..< rgb_stride:
          let a = if i >= bpp: int(curr[i - bpp]) else: 0
          curr[i] = uint8((int(curr[i]) + (a + int(prev[i])) div 2) and 0xFF)
      of 4:
        for i in 0 ..< rgb_stride:
          let a = if i >= bpp: int(curr[i - bpp]) else: 0
          let c = if i >= bpp: int(prev[i - bpp]) else: 0
          curr[i] = uint8((int(curr[i]) + paeth_predictor(a, int(prev[i]), c)) and 0xFF)
      else: discard

      for x in 0 ..< width:
        for ch in 0 ..< 3:
          result.pixels[(y * width + x) * 3 + ch] = curr[x * bpp + ch]
      for i in 0 ..< rgb_stride:
        prev[i] = curr[i]
  elif color_type == 3:
    # Indexed color — expand palette to RGB
    result.channels = 3
    result.pixels = newSeq[uint8](width * height * 3)

    for y in 0 ..< height:
      let offset = y * row_bytes
      let filter_type = uint8(raw[offset])
      for i in 0 ..< stride:
        curr_row[i] = uint8(raw[offset + 1 + i])

      case filter_type
      of 0: discard
      of 1:
        for i in 1 ..< stride:
          curr_row[i] = uint8((int(curr_row[i]) + int(curr_row[i - 1])) and 0xFF)
      of 2:
        for i in 0 ..< stride:
          curr_row[i] = uint8((int(curr_row[i]) + int(prev_row[i])) and 0xFF)
      of 3:
        for i in 0 ..< stride:
          let a = if i > 0: int(curr_row[i - 1]) else: 0
          curr_row[i] = uint8((int(curr_row[i]) + (a + int(prev_row[i])) div 2) and 0xFF)
      of 4:
        for i in 0 ..< stride:
          let a = if i > 0: int(curr_row[i - 1]) else: 0
          let c = if i > 0: int(prev_row[i - 1]) else: 0
          curr_row[i] = uint8((int(curr_row[i]) + paeth_predictor(a, int(prev_row[i]), c)) and 0xFF)
      else: discard

      let mask = (1 shl int(bit_depth)) - 1
      for x in 0 ..< width:
        let byte_idx = x div pixels_per_byte
        let bit_offset = (pixels_per_byte - 1 - (x mod pixels_per_byte)) * int(bit_depth)
        let idx = int(curr_row[byte_idx] shr bit_offset) and mask
        let rgb = palette[idx]
        let base = (y * width + x) * 3
        result.pixels[base] = rgb[0]
        result.pixels[base + 1] = rgb[1]
        result.pixels[base + 2] = rgb[2]

      for i in 0 ..< stride:
        prev_row[i] = curr_row[i]
  else:
    # Greyscale
    result.channels = 1
    result.pixels = newSeq[uint8](width * height)

    for y in 0 ..< height:
      let offset = y * row_bytes
      let filter_type = uint8(raw[offset])
      for i in 0 ..< stride:
        curr_row[i] = uint8(raw[offset + 1 + i])

      case filter_type
      of 0: discard
      of 1:
        for i in 1 ..< stride:
          curr_row[i] = uint8((int(curr_row[i]) + int(curr_row[i - 1])) and 0xFF)
      of 2:
        for i in 0 ..< stride:
          curr_row[i] = uint8((int(curr_row[i]) + int(prev_row[i])) and 0xFF)
      of 3:
        for i in 0 ..< stride:
          let a = if i > 0: int(curr_row[i - 1]) else: 0
          curr_row[i] = uint8((int(curr_row[i]) + (a + int(prev_row[i])) div 2) and 0xFF)
      of 4:
        for i in 0 ..< stride:
          let a = if i > 0: int(curr_row[i - 1]) else: 0
          let c = if i > 0: int(prev_row[i - 1]) else: 0
          curr_row[i] = uint8((int(curr_row[i]) + paeth_predictor(a, int(prev_row[i]), c)) and 0xFF)
      else: discard

      let mask = (1 shl int(bit_depth)) - 1
      let scale = 255 div mask
      for x in 0 ..< width:
        let byte_idx = x div pixels_per_byte
        let bit_offset = (pixels_per_byte - 1 - (x mod pixels_per_byte)) * int(bit_depth)
        let val = int(curr_row[byte_idx] shr bit_offset) and mask
        result.pixels[y * width + x] = uint8(val * scale)

      for i in 0 ..< stride:
        prev_row[i] = curr_row[i]
