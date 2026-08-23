import std/strutils

proc hex_str*(n: uint8,  prefix = true): string = (if prefix: "0x" else: "") & toHex(int(n),  2)
proc hex_str*(n: uint16, prefix = true): string = (if prefix: "0x" else: "") & toHex(int(n),  4)
proc hex_str*(n: uint32, prefix = true): string = (if prefix: "0x" else: "") & toHex(int(n),  8)
proc hex_str*(n: uint64, prefix = true): string = (if prefix: "0x" else: "") & toHex(int(n), 16)

template bit*(value: untyped, bit: int): bool =
  ((value shr bit) and 1) != 0

template bit*(value: untyped, bit: uint32): bool =
  ((value shr bit) and 1) != 0

template bits*(value: typed, lo: int, len: int): untyped =
  (value shr lo) and (type(value)((1 shl len) - 1))

# Range-based extract: bits_range(value, lo, hi) => hi-lo+1 bits from lo
template bits_range*(value: typed, lo, hi: int): untyped =
  (value shr lo) and (type(value)((1 shl (hi - lo + 1)) - 1))

proc count_set_bits*(n: SomeInteger): int =
  var x = n
  while x != 0:
    inc result
    x = x and (x - 1)

proc first_set_bit*(n: SomeInteger): int =
  for i in 0 ..< 8 * sizeof(n):
    if bit(n, i): return i
  8 * sizeof(n)

proc last_set_bit*(n: SomeInteger): int =
  result = 8 * sizeof(n)
  for i in countdown(8 * sizeof(n) - 1, 0):
    if bit(n, i): return i

# Compile-time trace/log flags
when defined(trace):
  template trace_log*(value: string) = echo value
  template log*(value: string) = discard
elif defined(log):
  template trace_log*(value: string) = discard
  template log*(value: string) = echo value
else:
  template trace_log*(value: string) = discard
  template log*(value: string) = discard
