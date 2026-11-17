# Link sync checks: the fingerprint two peers compare to know their copies of
# both games are still the same (gba/rollback.nim, gb/rollback.nim), and the
# id of the emulation core a build runs (sent in the rollback HELLO).
#
# The fingerprint is over the portable state image (state_bytes), not the
# in-process snapshot: that one pads the scheduler's cycle counters to the
# host's width (uint32 under wasm, uint64 natively), so web and iOS would
# never agree on it. A hash reads the image 8 bytes at a time as
# little-endian words, which every target here is (wasm, arm64, x86-64).

import std/[os, strutils]

proc rotl(x: uint64; r: int): uint64 {.inline.} = (x shl r) or (x shr (64 - r))

proc fmix(h: uint64): uint64 {.inline.} =
  var k = h
  k = k xor (k shr 33)
  k = k * 0xFF51AFD7ED558CCD'u64
  k = k xor (k shr 33)
  k = k * 0xC4CEB9FE1A85EC53'u64
  k xor (k shr 33)

proc sync_hash*(data: string; seed: uint64 = 0): uint64 =
  ## A 64-bit fingerprint of `data`, chained through `seed` (one call per core).
  ## Not cryptographic: it only has to tell two simulations apart.
  const k1 = 0x87C37B91114253D5'u64
  const k2 = 0x4CF5AD432745937F'u64
  var h = seed xor (uint64(data.len) * 0x9E3779B97F4A7C15'u64)
  let n = data.len
  var i = 0
  while i + 8 <= n:
    var w: uint64
    copyMem(addr w, unsafeAddr data[i], 8)
    w = rotl(w * k1, 31) * k2
    h = rotl(h xor w, 27) * 5 + 0x52DCE729'u64
    inc i, 8
  var tail = 0'u64
  var shift = 0
  while i < n:
    tail = tail or (uint64(ord(data[i])) shl shift)
    inc shift, 8
    inc i
  h = h xor (rotl(tail * k1, 31) * k2)
  fmix(h)

proc fnv64(s: string): uint64 =
  result = 0xCBF29CE484222325'u64
  for c in s:
    result = (result xor uint64(ord(c))) * 0x100000001B3'u64

const dingbatCoreId {.strdefine.} = ""

const CORE_ID* = block:
  ## The git trees of the emulation core (gba/, gb/, common/) this build was
  ## made from, as one 64-bit id: equal on two builds of the same core
  ## whatever else changed between them (the web app ships the UI daily,
  ## the iPhone app far less often). 0 when git can't say (no checkout):
  ## unknown, so a mismatch is only ever reported as "falls out of sync".
  ## -d:dingbatCoreId=<text> overrides it.
  var id = 0'u64
  if dingbatCoreId.len > 0:
    id = fnv64(dingbatCoreId)
  else:
    let root = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
    let trees = staticExec("git -C \"" & root & "\" rev-parse " &
      "HEAD:src/dingbat/gba HEAD:src/dingbat/gb HEAD:src/dingbat/common")
    let lines = trees.strip().splitLines()
    var ok = lines.len == 3
    for l in lines:
      if l.len != 40 or not l.allCharsInSet(HexDigits): ok = false
    if ok: id = fnv64(trees.strip())
  id

const BUILD_TIME* = block:
  ## The commit this build was made from, unix seconds (the web's
  ## dingbat-build-time and iOS's DingbatBuildTime are the same commit time):
  ## sent in the HELLO so a friend can tell which of two cores is older. 0
  ## when git can't say.
  let root = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
  let t = staticExec("git -C \"" & root & "\" show -s --format=%ct HEAD").strip()
  var v = 0'u32
  if t.len > 0 and t.allCharsInSet(Digits): v = uint32(parseBiggestInt(t))
  v

proc bios_identity*(path: string; mode: int): tuple[mode: uint8; hash: uint32] =
  ## The GBA BIOS a link session's cores run, as the HELLO says it: mode (0
  ## HLE, 1 the real BIOS, 2 HLE after it) and the image's FNV-1a (0: none,
  ## and then HLE, as the cores fall back to it). Two sides that differ run
  ## different code on every BIOS call and drift apart at once.
  if path.len == 0 or not fileExists(path): return (0'u8, 0'u32)
  var h = 0x811C9DC5'u32
  for c in readFile(path):
    h = (h xor uint32(ord(c))) * 0x01000193'u32
  (uint8(clamp(mode, 0, 2)), h)

proc bios_force_hle*(mine, theirs: tuple[mode: uint8; hash: uint32]): bool =
  ## Both sides' session cores on HLE without an image unless both run the
  ## same mode on the same image: the same answer on both sides. Without the
  ## image too: HLE hands some calls to an image when there is one (Golden
  ## Sun with and without one differ from the first frame).
  mine != theirs
