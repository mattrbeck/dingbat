## ARM9 maths unit: DIVCNT 0x4000280, DIV_NUMER 0x4000290, DIV_DENOM
## 0x4000298, DIV_RESULT 0x40002A0, DIVREM_RESULT 0x40002A8; SQRTCNT
## 0x40002B0, SQRT_RESULT 0x40002B4, SQRT_PARAM 0x40002B8.
## Results are computed at once; the busy bit (and its 18/34/34 and 13
## cycle latencies) is TODO.

import std/math

type
  DivSqrt* = ref object
    divcnt*: uint32
    numer*, denom*: int64
    quot*, rem*: int64
    sqrtcnt*: uint32
    sqrt_param*: uint64
    sqrt_result*: uint32

proc compute_div(d: DivSqrt) =
  let mode = d.divcnt and 3
  var n, m: int64
  case mode
  of 0: n = int64(cast[int32](uint32(d.numer))); m = int64(cast[int32](uint32(d.denom)))
  of 1: n = d.numer; m = int64(cast[int32](uint32(d.denom)))
  else: n = d.numer; m = d.denom
  d.divcnt = d.divcnt and not 0x4000'u32
  if d.denom == 0: d.divcnt = d.divcnt or 0x4000   # div-by-zero flag (64-bit denom)
  if m == 0:
    d.quot = if n < 0: 1 else: -1
    d.rem = n
    if mode == 0: d.quot = d.quot xor (0xFFFF_FFFF'i64 shl 32)  # GBATEK quirk
  elif n == low(int64) and m == -1:
    d.quot = n
    d.rem = 0
  else:
    d.quot = n div m
    d.rem = n mod m

proc compute_sqrt(d: DivSqrt) =
  let v = if (d.sqrtcnt and 1) != 0: d.sqrt_param else: d.sqrt_param and 0xFFFF_FFFF'u64
  var r = uint64(sqrt(float64(v)))
  while r * r > v: dec r
  while (r + 1) * (r + 1) <= v: inc r
  d.sqrt_result = uint32(r)

proc read_reg*(d: DivSqrt; offset: uint32): uint32 =
  case offset
  of 0x280: d.divcnt
  of 0x290: uint32(cast[uint64](d.numer))
  of 0x294: uint32(cast[uint64](d.numer) shr 32)
  of 0x298: uint32(cast[uint64](d.denom))
  of 0x29C: uint32(cast[uint64](d.denom) shr 32)
  of 0x2A0: uint32(cast[uint64](d.quot))
  of 0x2A4: uint32(cast[uint64](d.quot) shr 32)
  of 0x2A8: uint32(cast[uint64](d.rem))
  of 0x2AC: uint32(cast[uint64](d.rem) shr 32)
  of 0x2B0: d.sqrtcnt
  of 0x2B4: d.sqrt_result
  of 0x2B8: uint32(d.sqrt_param)
  of 0x2BC: uint32(d.sqrt_param shr 32)
  else: 0

proc set_lo(x: var int64; v, mask: uint32) =
  let u = cast[uint64](x)
  x = cast[int64]((u and not uint64(mask)) or uint64(v and mask))

proc set_hi(x: var int64; v, mask: uint32) =
  let u = cast[uint64](x)
  x = cast[int64]((u and not (uint64(mask) shl 32)) or (uint64(v and mask) shl 32))

proc write_reg*(d: DivSqrt; offset: uint32; v, mask: uint32) =
  case offset
  of 0x280: d.divcnt = (d.divcnt and not (mask and 3)) or (v and mask and 3); d.compute_div()
  of 0x290: set_lo(d.numer, v, mask); d.compute_div()
  of 0x294: set_hi(d.numer, v, mask); d.compute_div()
  of 0x298: set_lo(d.denom, v, mask); d.compute_div()
  of 0x29C: set_hi(d.denom, v, mask); d.compute_div()
  of 0x2B0: d.sqrtcnt = (d.sqrtcnt and not (mask and 1)) or (v and mask and 1); d.compute_sqrt()
  of 0x2B8:
    d.sqrt_param = (d.sqrt_param and not uint64(mask)) or uint64(v and mask); d.compute_sqrt()
  of 0x2BC:
    d.sqrt_param = (d.sqrt_param and not (uint64(mask) shl 32)) or (uint64(v and mask) shl 32)
    d.compute_sqrt()
  else: discard
