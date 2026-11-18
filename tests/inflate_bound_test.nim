# zlib_inflated_len against zippy: the same length for every stream zippy
# inflates, the limit honoured, and damaged streams refused without a fault.
import std/[os, random, times]
import zippy
import dingbat/common/inflate_bound

var checked = 0

proc agree(plain: string; level: int) =
  let z = compress(plain, level, dfZlib)
  let n = zlib_inflated_len(unsafeAddr z[0], z.len, high(int32))
  doAssert n == plain.len, "level " & $level & ": " & $n & " != " & $plain.len
  if plain.len > 0:
    doAssert zlib_inflated_len(unsafeAddr z[0], z.len, plain.len - 1) == plain.len
  inc checked

var rng = initRand(0x51A7E)
for level in [0, 1, 6, 9]:      # 0 = stored blocks, 1 = fixed-table heavy
  agree("", level)
  agree("a", level)
  for size in [1, 100, 65535, 65536, 300_000]:
    var noise = newString(size)
    for c in noise.mitems: c = char(rng.rand(255))
    agree(noise, level)
    var runs = newString(size)   # long matches: the bomb's shape
    for i in 0 ..< size: runs[i] = char((i div 4000) and 0xFF)
    agree(runs, level)
    var mixed = newString(size)
    for i in 0 ..< size:
      mixed[i] = if (i shr 9) mod 3 == 0: char(rng.rand(255)) else: char(i and 7)
    agree(mixed, level)

# The packed state fixtures: bodies a real build wrote.
const HEADER = 32
var fixtures = 0
for path in walkFiles(currentSourcePath().parentDir / "states" / "*.state"):
  let data = readFile(path)
  if data.len <= HEADER or (uint8(data[15]) and 0x80) == 0: continue
  var body: string
  try: body = uncompress(unsafeAddr data[HEADER], data.len - HEADER, dfZlib)
  except ZippyError: continue
  let n = zlib_inflated_len(unsafeAddr data[HEADER], data.len - HEADER, high(int32))
  doAssert n == body.len, path & ": " & $n & " != " & $body.len
  inc fixtures
doAssert fixtures > 0, "no packed state fixture was read"

# A 64 MiB run packs to about 64 KiB; the walk stops at the limit.
block:
  let bomb = compress(newString(64 * 1024 * 1024), 9, dfZlib)
  doAssert bomb.len < 100_000
  doAssert zlib_inflated_len(unsafeAddr bomb[0], bomb.len, 1 shl 20) == (1 shl 20) + 1

# Damage: no fault, and the same length wherever zippy reads the stream
# through (zippy also checks the header and the Adler-32).
block:
  var plain = newString(20_000)
  for i in 0 ..< plain.len:
    plain[i] = char(if i mod 5 == 0: rng.rand(255) else: i and 31)
  let z = compress(plain, 6, dfZlib)
  for trial in 0 ..< 4000:
    var m = z
    if trial mod 4 == 0: m.setLen(rng.rand(z.len))
    else:
      for _ in 0 .. rng.rand(3): m[rng.rand(m.len - 1)] = char(rng.rand(255))
    if m.len == 0: continue
    let n = zlib_inflated_len(unsafeAddr m[0], m.len, 1 shl 24)
    var got = -1
    try: got = uncompress(m, dfZlib).len
    except ZippyError: discard
    if got >= 0: doAssert n == got, "trial " & $trial & ": " & $n & " != " & $got

block:
  var plain = newString(8 * 1024 * 1024)
  for i in 0 ..< plain.len:
    plain[i] = char(if (i shr 8) mod 4 == 0: rng.rand(255) else: i and 15)
  let z = compress(plain, 6, dfZlib)
  let t0 = cpuTime()
  doAssert zlib_inflated_len(unsafeAddr z[0], z.len, high(int32)) == plain.len
  let t1 = cpuTime()
  discard uncompress(z, dfZlib)
  let t2 = cpuTime()
  echo "8 MiB (", z.len div 1024, " KiB packed): walk ", int((t1 - t0) * 1000),
       " ms, zippy inflate ", int((t2 - t1) * 1000), " ms"

echo "inflate_bound: ", checked, " streams and ", fixtures,
     " state fixtures agree with zippy"
