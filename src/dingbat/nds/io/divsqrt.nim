## ARM9 maths unit: DIVCNT 0x4000280, DIV_NUMER 0x4000290, DIV_DENOM
## 0x4000298, DIV_RESULT 0x40002A0, DIVREM_RESULT 0x40002A8; SQRTCNT
## 0x40002B0, SQRT_RESULT 0x40002B4, SQRT_PARAM 0x40002B8 (GBATEK "DS Maths").
## A write to a control or parameter register starts a new operation. The
## result registers hold the answer at once; the busy bit (15) stays set for
## the operation's time -- 18 bus cycles for 32/32, 34 for 64-bit division,
## 13 for a root -- counted on the scheduler's clock.

import ../sched
import ../quirky

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: nds_quirky.}

type
  DivSqrt* = ref object
    sched* {.cursor.}: NdsScheduler
    divcnt*: uint32
    numer*, denom*: int64
    quot*, rem*: int64
    div_done*: int64          ## master cycle the division's busy bit clears
    sqrtcnt*: uint32
    sqrt_param*: uint64
    sqrt_result*: uint32
    sqrt_done*: int64

const
  DIV32_CYCLES = 18 * 2       ## master cycles (2 per 33.51 MHz cycle)
  DIV64_CYCLES = 34 * 2
  SQRT_CYCLES = 13 * 2

proc new_divsqrt*(sched: NdsScheduler): DivSqrt = DivSqrt(sched: sched)

proc compute_div(d: DivSqrt) =
  let mode = d.divcnt and 3
  d.div_done = d.sched.now + (if mode == 0: DIV32_CYCLES else: DIV64_CYCLES)
  d.divcnt = d.divcnt and not 0x4000'u32
  if d.denom == 0: d.divcnt = d.divcnt or 0x4000   # DIV0: the full 64-bit denom
  if mode == 0:
    # 32/32: results sign-expanded; an overflow (div0, -MAX/-1) inverts the
    # upper half of the quotient.
    let n = cast[int32](uint32(cast[uint64](d.numer)))
    let m = cast[int32](uint32(cast[uint64](d.denom)))
    var q, r: int64
    var overflow = true
    if m == 0:
      q = if n < 0: 1 else: -1
      r = n
    elif n == low(int32) and m == -1:
      q = int64(low(int32))
      r = 0
    else:
      q = int64(n div m)
      r = int64(n mod m)
      overflow = false
    if overflow: q = cast[int64](cast[uint64](q) xor 0xFFFF_FFFF_0000_0000'u64)
    d.quot = q
    d.rem = r
  else:
    let n = d.numer
    let m = if mode == 2: d.denom else: int64(cast[int32](uint32(cast[uint64](d.denom))))
    if m == 0:
      d.quot = if n < 0: 1 else: -1
      d.rem = n
    elif n == low(int64) and m == -1:
      d.quot = n
      d.rem = 0
    else:
      d.quot = n div m
      d.rem = n mod m

proc isqrt(v: uint64): uint32 =
  ## floor(sqrt(v)), bit by bit.
  var rem = v
  var root = 0'u64
  var bit = 1'u64 shl 62
  while bit > rem: bit = bit shr 2
  while bit != 0:
    if rem >= root + bit:
      rem -= root + bit
      root = (root shr 1) + bit
    else:
      root = root shr 1
    bit = bit shr 2
  uint32(root)

proc compute_sqrt(d: DivSqrt) =
  d.sqrt_done = d.sched.now + SQRT_CYCLES
  let v = if (d.sqrtcnt and 1) != 0: d.sqrt_param else: d.sqrt_param and 0xFFFF_FFFF'u64
  d.sqrt_result = isqrt(v)

proc read_reg*(d: DivSqrt; offset: uint32): uint32 =
  case offset
  of 0x280: d.divcnt or (if d.sched.now < d.div_done: 0x8000'u32 else: 0)
  of 0x290: uint32(cast[uint64](d.numer))
  of 0x294: uint32(cast[uint64](d.numer) shr 32)
  of 0x298: uint32(cast[uint64](d.denom))
  of 0x29C: uint32(cast[uint64](d.denom) shr 32)
  of 0x2A0: uint32(cast[uint64](d.quot))
  of 0x2A4: uint32(cast[uint64](d.quot) shr 32)
  of 0x2A8: uint32(cast[uint64](d.rem))
  of 0x2AC: uint32(cast[uint64](d.rem) shr 32)
  of 0x2B0: d.sqrtcnt or (if d.sched.now < d.sqrt_done: 0x8000'u32 else: 0)
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

{.pop.}
