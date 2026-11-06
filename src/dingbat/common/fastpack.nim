## In-memory packing for data that never leaves the process (the rewind
## ring's deltas, keyframes and thumbnails): Apple's Compression framework
## on macOS and iOS (libcompression, tuned for these chips), zlib elsewhere
## (zippy: the web, Linux, Windows).
##
## The packed form is private to the process and its build: 4 bytes of
## raw length (little-endian), then the codec's bytes. Nothing written to
## disk or sent anywhere uses it (states use serialize.pack_state).
##
## -d:fastpackCodec=lz4|lzfse|zlib picks the codec on Apple platforms (lz4 by
## default); other platforms are always zlib.

import zippy

const fastpackCodec {.strdefine.} = "lz4"
const useApple = (defined(macosx) or defined(ios)) and not defined(emscripten) and fastpackCodec != "zlib"

when useApple:
  {.passL: "-lcompression".}
  const algo = when fastpackCodec == "lzfse": 0x801.cint else: 0x100.cint  # COMPRESSION_LZFSE / _LZ4
  proc compression_encode_buffer(dst: ptr uint8; dst_size: csize_t; src: ptr uint8; src_size: csize_t;
                                 scratch: pointer; algorithm: cint): csize_t {.importc, header: "<compression.h>".}
  proc compression_decode_buffer(dst: ptr uint8; dst_size: csize_t; src: ptr uint8; src_size: csize_t;
                                 scratch: pointer; algorithm: cint): csize_t {.importc, header: "<compression.h>".}

proc fast_pack*(s: string): string =
  let n = s.len
  when useApple:
    # LZ4 / LZFSE can grow incompressible data a little: room for that, and
    # a plain copy if the codec gives up
    result = newString(4 + n + n div 16 + 64)
    for i in 0 ..< 4: result[i] = char((n shr (8 * i)) and 0xFF)
    if n == 0: result.setLen(4); return
    let w = compression_encode_buffer(cast[ptr uint8](addr result[4]), csize_t(result.len - 4),
                                      cast[ptr uint8](unsafeAddr s[0]), csize_t(n), nil, algo)
    if w == 0:
      result.setLen(4 + 1 + n)
      result[4] = '\0'          # (stored: a leading 0 byte, then the bytes)
      copyMem(addr result[5], unsafeAddr s[0], n)
    else:
      result.setLen(4 + 1 + int(w))
      moveMem(addr result[5], addr result[4], int(w))
      result[4] = '\1'
  else:
    result = newString(4)
    for i in 0 ..< 4: result[i] = char((n shr (8 * i)) and 0xFF)
    result.add compress(s, BestSpeed, dfZlib)

proc fast_unpack*(p: string): string =
  if p.len < 4: raise newException(ValueError, "fastpack: truncated")
  var n = 0
  for i in 0 ..< 4: n = n or (int(uint8(p[i])) shl (8 * i))
  when useApple:
    result = newString(n)
    if n == 0: return
    if p.len < 5: raise newException(ValueError, "fastpack: truncated")
    if p[4] == '\0':
      if p.len != 5 + n: raise newException(ValueError, "fastpack: bad stored length")
      copyMem(addr result[0], unsafeAddr p[5], n)
      return
    let r = compression_decode_buffer(cast[ptr uint8](addr result[0]), csize_t(n),
                                      cast[ptr uint8](unsafeAddr p[5]), csize_t(p.len - 5), nil, algo)
    if int(r) != n: raise newException(ValueError, "fastpack: corrupt")
  else:
    result = uncompress(p.substr(4), dfZlib)
    if result.len != n: raise newException(ValueError, "fastpack: corrupt")

proc fast_pack_bytes*(b: openArray[byte]): string =
  var s = newString(b.len)
  if b.len > 0: copyMem(addr s[0], unsafeAddr b[0], b.len)
  fast_pack(s)

proc fast_unpack_bytes*(p: string): seq[byte] =
  let s = fast_unpack(p)
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)
