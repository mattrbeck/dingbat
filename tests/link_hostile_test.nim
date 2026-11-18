## What an online-link peer chooses, turned hostile: the frame number on an
## input, fields of the state it sends, and that state's compressed size. Each
## is refused or ignored and the session carries on.

import std/[os, strutils]
import zippy
import dingbat/common/serialize
import dingbat/gb/gb
import dingbat/gb/link as gblink
import dingbat/gb/rollback as gbrb
import dingbat/gba/[gba, link, rollback]

var failures = 0

proc check(ok: bool; what: string) =
  echo "  [", (if ok: "PASS" else: "FAIL"), "] ", what
  if not ok: inc failures

# ---------------- input frame numbers ----------------

const FAR = [int(high(int32)) - 1, int(high(int32)), 1_000_000, 12 + 600 + 1]

block:
  proc mk(): GB =
    result = new_gb("", "tests/roms/gblinktest.gb", headless = true, run_bios = false)
    result.post_init()
  let s = new_gb_rollback_session(new_gb_link(@[mk(), mk()]), 0, 12)
  let before = getOccupiedMem()
  for f in FAR: s.feed_remote(f, 0x3FF)
  s.feed_remote(-1, 0x3FF)
  check getOccupiedMem() - before < 1 shl 20, "GB: far-off input frames allocate nothing"
  # The session still runs and still takes the frames it should.
  for f in 0 ..< 30:
    discard s.tick(0)
    s.feed_remote(f, 0)
  s.feed_remote(s.head + 12, 0)   # a peer at the far edge of its window
  check s.head == 30 and s.confirmed == 29, "GB: the session carries on (head " &
        $s.head & ", confirmed " & $s.confirmed & ")"

block:
  proc mk(): GBA =
    result = new_gba("", "tests/roms/linktest.gba", run_bios = false, use_hle = true)
    result.post_init()
  let s = new_rollback_session(new_link(@[mk(), mk()]), 0, 12)
  let before = getOccupiedMem()
  for f in FAR: s.feed_remote(f, 0x3FF)
  s.feed_remote(-1, 0x3FF)
  check getOccupiedMem() - before < 1 shl 20, "GBA: far-off input frames allocate nothing"
  for f in 0 ..< 30:
    discard s.tick(0)
    s.feed_remote(f, 0)
  check s.head == 30 and s.confirmed == 29, "GBA: the session carries on (head " &
        $s.head & ", confirmed " & $s.confirmed & ")"

# ---------------- state fields ----------------

proc reseal(image: var string) =
  let n = image.len - STATE_HEADER_SIZE
  for i in 0 .. 3: image[24 + i] = char(uint8(uint32(n) shr (8 * i)))
  let h = fnv1a(image[STATE_HEADER_SIZE ..< image.len])
  for i in 0 .. 3: image[28 + i] = char(uint8(h shr (8 * i)))

proc field_at(a, b: string): int =
  ## Where two images of one machine differ: the field set between them.
  doAssert a.len == b.len
  result = -1
  for i in STATE_HEADER_SIZE ..< a.len:
    if a[i] != b[i]:
      doAssert result < 0, "the images differ in more than one byte"
      result = i

proc synth_rom(cart_type: uint8): string =
  ## A blank 64 KiB cartridge of the given type.
  var rom = newString(0x10000)
  rom[0x147] = char(cart_type)
  rom[0x148] = char(1)
  result = getTempDir() / ("dingbat_hostile_" & toHex(cart_type) & ".gb")
  writeFile(result, rom)

proc refuses(g: GB; image: string; field: string): bool =
  var img = image
  reseal(img)
  let before = g.state_bytes()
  result = not g.load_state_bytes(img) and field in last_state_error and
           g.state_bytes() == before

block:
  let path = synth_rom(0x20)
  let g = new_gb("", path, headless = true, run_bios = false)
  g.post_init()
  doAssert g.cartridge of Mbc6
  let c = Mbc6(g.cartridge)
  c.ram_bank_a = 1
  let a = g.state_bytes()
  c.ram_bank_a = 2
  var b = g.state_bytes()
  let at = field_at(a, b)
  var ok = g.load_state_bytes(b)
  b[at] = char(7)
  var top = b
  reseal(top)
  ok = ok and g.load_state_bytes(top)
  check ok, "MBC6: RAM banks 0..7 load"
  b[at] = char(8)
  check g.refuses(b, "mbc6.ram_bank_a"), "MBC6: RAM bank A of 8 is refused"
  b[at] = char(255)
  check g.refuses(b, "mbc6.ram_bank_a"), "MBC6: RAM bank A of 255 is refused"
  b[at] = char(2)
  b[at + 1] = char(200)
  check g.refuses(b, "mbc6.ram_bank_b"), "MBC6: RAM bank B of 200 is refused"
  removeFile(path)

block:
  let path = synth_rom(0xFD)
  let g = new_gb("", path, headless = true, run_bios = false)
  g.post_init()
  doAssert g.cartridge of Tama5
  let c = Tama5(g.cartridge)
  c.reg_index = 1
  let a = g.state_bytes()
  c.reg_index = 15
  var b = g.state_bytes()
  let at = field_at(a, b)
  check g.load_state_bytes(b), "TAMA5: register index 15 loads"
  b[at] = char(16)
  check g.refuses(b, "tama5.reg_index"), "TAMA5: register index 16 is refused"
  b[at] = char(255)
  check g.refuses(b, "tama5.reg_index"), "TAMA5: register index 255 is refused"
  removeFile(path)

block:
  let g = new_gb("", "tests/roms/gblinktest.gb", headless = true, run_bios = false)
  g.post_init()
  # Idle, so the position is the only thing the two images differ in.
  doAssert g.memory.dma_position == 0xA1
  let a = g.state_bytes()
  g.memory.dma_position = 0xA2
  var b = g.state_bytes()
  g.memory.dma_position = 0xA1
  let at = field_at(a, b)
  check g.refuses(b, "mem.dma_position"), "OAM DMA position past the end is refused"
  for i in 0 .. 3: b[at + i] = char(0xFF)   # -1
  check g.refuses(b, "mem.dma_position"), "a negative OAM DMA position is refused"
  for i in 0 .. 3: b[at + i] = char(if i == 3: 0x80 else: 0)   # low(int32)
  check g.refuses(b, "mem.dma_position"), "the most negative OAM DMA position is refused"

# ---------------- compressed size ----------------

block:
  let g = new_gb("", "tests/roms/gblinktest.gb", headless = true, run_bios = false)
  g.post_init()
  let plain = g.state_bytes()
  let packed = pack_state(plain)
  check is_packed_state(packed) and unpack_state(packed) == plain,
        "a real packed state still unpacks to itself"

  # The same header on a body that inflates to twice the limit, from under
  # 300 KiB: what a peer could send inside the 8 MiB state cap.
  var bomb = packed[0 ..< STATE_HEADER_SIZE]
  bomb.add compress(newString(2 * STATE_PLAIN_MAX), 9, dfZlib)
  let before = getOccupiedMem()
  var refused = false
  try: discard unpack_state(bomb)
  except StateError: refused = true
  check refused and bomb.len < 512 * 1024 and getOccupiedMem() - before < (1 shl 20),
        "a " & $(bomb.len div 1024) & " KiB body that inflates to " &
        $(2 * STATE_PLAIN_MAX shr 20) & " MiB is refused before it is inflated"
  check not g.load_state_bytes(bomb) and g.state_bytes() == plain,
        "and the core it was sent to is untouched"

if failures > 0:
  echo "link_hostile: ", failures, " FAILED"
  quit(1)
echo "link_hostile: all passed"
