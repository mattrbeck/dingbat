# zlib_inflate_capped against zippy: the same bytes for every stream zippy
# inflates, the limit honoured before the bytes past it are made, and damaged
# streams refused without a fault. Built with -d:inflate_checks, which keeps
# the runtime checks in the decode loop: an index the loop's own tests miss
# is a Defect here.
import std/[os, random, times]
import zippy
import dingbat/common/inflate_bound

when not defined(inflate_checks):
  {.error: "build with -d:inflate_checks".}

var checked = 0

proc capped(z: string; limit: int; hint = 0): string =
  zlib_inflate_capped(unsafeAddr z[0], z.len, limit, hint)

proc too_big(z: string; limit: int): bool =
  try: discard capped(z, limit)
  except InflateError as e: return e.too_big

proc agree(plain: string; level: int) =
  let z = compress(plain, level, dfZlib)
  doAssert capped(z, 1 shl 30) == plain, "level " & $level & ", " & $plain.len & " bytes"
  # The size it will be, a size too small and one far too large as the hint.
  doAssert capped(z, 1 shl 30, plain.len) == plain
  doAssert capped(z, 1 shl 30, 1) == plain
  doAssert capped(z, 1 shl 30, 1 shl 29) == plain
  doAssert capped(z, plain.len) == plain, "the limit is the size itself"
  if plain.len > 0: doAssert too_big(z, plain.len - 1)
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
    var near = newString(size)   # short distances: matches that overlap
    for i in 0 ..< size: near[i] = char(if rng.rand(40) == 0: rng.rand(255) else: i mod 3)
    agree(near, level)

# The packed state fixtures: bodies a real build wrote.
const HEADER = 32
var fixtures = 0
for path in walkFiles(currentSourcePath().parentDir / "states" / "*.state"):
  let data = readFile(path)
  if data.len <= HEADER or (uint8(data[15]) and 0x80) == 0: continue
  var body: string
  try: body = uncompress(unsafeAddr data[HEADER], data.len - HEADER, dfZlib)
  except ZippyError: continue
  doAssert zlib_inflate_capped(unsafeAddr data[HEADER], data.len - HEADER,
                               1 shl 30) == body, path
  inc fixtures
doAssert fixtures > 0, "no packed state fixture was read"

# A 64 MiB run packs to about 64 KiB; it stops at the limit, having held no
# more than the limit.
block:
  let bomb = compress(newString(64 * 1024 * 1024), 9, dfZlib)
  doAssert bomb.len < 100_000
  let before = getOccupiedMem()
  doAssert too_big(bomb, 1 shl 20)
  doAssert too_big(bomb, 64 * 1024 * 1024 - 1)
  doAssert getOccupiedMem() - before < (1 shl 20)

# Damage: no fault, and wherever zippy reads the stream through, the same
# bytes (both check the header and the Adler-32).
block:
  var plain = newString(20_000)
  for i in 0 ..< plain.len:
    plain[i] = char(if i mod 5 == 0: rng.rand(255) else: i and 31)
  for level in [1, 6]:
    let z = compress(plain, level, dfZlib)
    var both, neither = 0
    for trial in 0 ..< 20_000:
      var m = z
      if trial mod 4 == 0: m.setLen(rng.rand(z.len))
      else:
        for _ in 0 .. rng.rand(3): m[rng.rand(m.len - 1)] = char(rng.rand(255))
      if m.len == 0: continue
      var ours, theirs: string
      var ours_ok, theirs_ok = true
      try: ours = capped(m, 1 shl 24)
      except InflateError: ours_ok = false
      try: theirs = uncompress(m, dfZlib)
      except ZippyError: theirs_ok = false
      doAssert ours_ok == theirs_ok, "level " & $level & " trial " & $trial &
        ": ours " & $ours_ok & ", zippy " & $theirs_ok
      if ours_ok:
        doAssert ours == theirs, "trial " & $trial
        inc both
      else: inc neither
    doAssert both > 0 and neither > 0

block:
  var plain = newString(8 * 1024 * 1024)
  for i in 0 ..< plain.len:
    plain[i] = char(if (i shr 8) mod 4 == 0: rng.rand(255) else: i and 15)
  let z = compress(plain, 6, dfZlib)
  let t0 = cpuTime()
  doAssert capped(z, 1 shl 30, plain.len) == plain
  let t1 = cpuTime()
  discard uncompress(z, dfZlib)
  let t2 = cpuTime()
  echo "8 MiB (", z.len div 1024, " KiB packed), checks on: capped ",
       int((t1 - t0) * 1000), " ms, zippy ", int((t2 - t1) * 1000), " ms"

echo "inflate_bound: ", checked, " streams and ", fixtures,
     " state fixtures inflate to zippy's bytes"
