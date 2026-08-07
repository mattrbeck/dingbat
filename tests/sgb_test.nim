# Super Game Boy acceptance test.
#
# Drives tests/roms/sgbtest.gb (built by tests/roms/sgbtest.py) and checks the
# whole SGB path end to end: the P1 packet receiver, PAL01/PAL23, ATTR_DIV,
# ATTR_BLK, the per-cell colorization of the Game Boy screen, and the two VRAM
# transfers that carry a border (CHR_TRN + PCT_TRN).
#
# Every expectation below is recomputed here from the same rules the ROM
# builder used, so the test fails if either side drifts.
#
# With DINGBAT_SGB_PNG=<dir> it also writes screen.png and border.png for
# eyeballing. That is not part of the assertions.

import std/[os, strformat, strutils]
import dingbat/gb/gb
import dingbat/common/serialize

when defined(sgb_png):
  import stb_image/write as stbiw

const ROM = "tests/roms/sgbtest.gb"

var failures = 0
proc check(cond: bool; msg: string) =
  if not cond:
    inc failures
    echo "FAIL: ", msg

proc rgb555(r, g, b: int): uint16 =
  uint16((r and 0x1F) or ((g and 0x1F) shl 5) or ((b and 0x1F) shl 10))

# ---- the palettes the ROM sends (mirror of sgbtest.py) ----
const BACKDROP = 0'u16                                   # colour 0, shared
let PAL_EXPECT = [
  [BACKDROP, rgb555(31, 0, 0), rgb555(0, 31, 0), rgb555(0, 0, 31)],
  [BACKDROP, rgb555(31, 31, 0), rgb555(31, 0, 31), rgb555(0, 31, 31)],
  [BACKDROP, rgb555(10, 10, 10), rgb555(20, 20, 20), rgb555(31, 31, 31)],
  [BACKDROP, rgb555(31, 16, 0), rgb555(16, 31, 0), rgb555(0, 16, 31)],
]

let BORDER_COLORS = [
  rgb555(0, 0, 0),
  rgb555(31, 0, 0), rgb555(0, 31, 0), rgb555(0, 0, 31),
  rgb555(31, 31, 0), rgb555(31, 0, 31), rgb555(0, 31, 31),
  rgb555(31, 31, 31), rgb555(16, 0, 0), rgb555(0, 16, 0),
  rgb555(0, 0, 16), rgb555(16, 16, 0), rgb555(16, 0, 16),
  rgb555(0, 16, 16), rgb555(16, 16, 16), rgb555(24, 12, 4),
]

proc expected_attr(x, y: int): uint8 =
  ## ATTR_DIV (horizontal split at row 9: above = 1, line = 3, below = 2)
  ## then ATTR_BLK (rect x 4..11, y 2..6, inside + its surrounding line = 0).
  result =
    if y < 9: 1'u8
    elif y == 9: 3'u8
    else: 2'u8
  let on_edge = ((x == 4 or x == 11) and y >= 2 and y <= 6) or
                ((y == 2 or y == 6) and x >= 4 and x <= 11)
  let inside = x > 4 and x < 11 and y > 2 and y < 6
  if on_edge or inside: result = 0'u8

proc expected_border_tile(tx, ty: int): int =
  if tx >= 6 and tx < 26 and ty >= 5 and ty < 23: 0
  else: 1 + ((tx + ty) mod 15)

# ---------------------------------------------------------------- run

if not fileExists(ROM):
  echo "missing ", ROM, " -- run `python3 tests/roms/sgbtest.py`"
  quit(1)

var m = new_gb("", ROM, fifo = true, headless = true, run_bios = false)
# Explicit: the core defaults to no adapter, so every consumer that has not
# asked for one (the test harnesses, the benchmark, the ROM sweeps) keeps
# stock Game Boy behaviour.
m.sgb_requested = true
m.post_init()
for _ in 0 ..< 20: m.step_frame()

check(m.sgb != nil, "SGB adapter not attached for an SGB-flagged cart")
if m.sgb == nil: quit(1)
check(m.boot_model == bmSgb, "boot model should be bmSgb (C = 0x14 detection)")

let s = m.sgb

# ---- palettes ----
for p in 0 ..< 4:
  for c in 0 ..< 4:
    check(s.pal[p * 4 + c] == PAL_EXPECT[p][c],
          &"palette {p} colour {c}: got {s.pal[p*4+c]:04X} " &
          &"want {PAL_EXPECT[p][c]:04X}")

# ---- attribute map ----
var attr_bad = 0
for y in 0 ..< 18:
  for x in 0 ..< 20:
    if s.attr[y * 20 + x] != expected_attr(x, y): inc attr_bad
check(attr_bad == 0, &"{attr_bad}/360 attribute cells wrong")

# ---- the colorized Game Boy screen ----
# The ROM draws vertical stripes: screen column c shows shade (c and 3).
var px_bad = 0
var first_bad = ""
for y in 0 ..< 144:
  for x in 0 ..< 160:
    let shade = (x div 8) and 3
    let pal = int(expected_attr(x div 8, y div 8))
    let want = PAL_EXPECT[pal][shade]
    let got = m.ppu.framebuffer[y * 160 + x]
    if got != want:
      inc px_bad
      if first_bad.len == 0:
        first_bad = &"({x},{y}) got {got:04X} want {want:04X} (pal {pal} shade {shade})"
check(px_bad == 0, &"{px_bad}/23040 screen pixels wrong; first {first_bad}")

# ---- the border ----
check(s.border_valid, "border was never rendered (CHR_TRN/PCT_TRN)")
var border_bad = 0
var border_first = ""
for py in 0 ..< 224:
  for px in 0 ..< 256:
    let tile = expected_border_tile(px div 8, py div 8)
    let ci = tile and 15
    let want = if ci == 0: 0'u16 else: BORDER_COLORS[ci] or 0x8000'u16
    let got = s.border[py * 256 + px]
    if got != want:
      inc border_bad
      if border_first.len == 0:
        border_first = &"({px},{py}) got {got:04X} want {want:04X} tile {tile}"
check(border_bad == 0, &"{border_bad}/57344 border pixels wrong; first {border_first}")

# The 20x18 hole the Game Boy window shows through must be fully transparent.
var hole_opaque = 0
for py in 40 ..< 184:
  for px in 48 ..< 208:
    if (s.border[py * 256 + px] and 0x8000'u16) != 0: inc hole_opaque
check(hole_opaque == 0, &"{hole_opaque} opaque pixels inside the GB window")

# ---- the scanline renderer must colorize identically ----
block:
  var sl = new_gb("", ROM, fifo = false, headless = true, run_bios = false)
  sl.sgb_requested = true
  sl.post_init()
  for _ in 0 ..< 20: sl.step_frame()
  check(sl.sgb != nil, "scanline renderer: no SGB adapter")
  var diff = 0
  for i in 0 ..< 160 * 144:
    if sl.ppu.framebuffer[i] != m.ppu.framebuffer[i]: inc diff
  check(diff == 0, &"scanline vs FIFO renderer disagree on {diff} SGB pixels")

# ---- a non-SGB cart must be untouched ----
block:
  var plain = new_gb("", "tests/roms/gblinktest.gb", fifo = true,
                     headless = true, run_bios = false)
  plain.sgb_requested = true
  plain.post_init()
  check(plain.sgb == nil, "a cart without the SGB header bits got an adapter")
  check(plain.ppu.sgb_attr == nil, "renderer SGB hook set on a non-SGB machine")

# ---- and the adapter is OPT-IN: an SGB cart gets nothing by default ----
block:
  var dflt = new_gb("", ROM, fifo = true, headless = true, run_bios = false)
  check(not dflt.sgb_requested, "sgb_requested must default to false")
  dflt.post_init()
  for _ in 0 ..< 20: dflt.step_frame()
  check(dflt.sgb == nil, "an SGB cart got an adapter without being asked")
  check(dflt.ppu.sgb_attr == nil, "renderer SGB hook set without an adapter")
  check(dflt.boot_model == bmDmgABC, "boot model promoted without an adapter")

# ---- save state round trip ----
block:
  let payload = m.state_payload()
  let pal_before = s.pal
  let attr_before = s.attr
  let chr_before = s.chr
  for _ in 0 ..< 3: m.step_frame()
  # Scribble over the live state, then restore it.
  for i in 0 ..< s.pal.len: s.pal[i] = 0x1234'u16
  for i in 0 ..< s.attr.len: s.attr[i] = 3'u8
  for i in 0 ..< s.chr.len: s.chr[i] = 0xAA'u8
  m.apply_state_payload(payload)
  check(s.pal == pal_before, "SGB palettes did not survive a state round trip")
  check(s.attr == attr_before, "SGB attribute map did not survive a state round trip")
  check(s.chr == chr_before, "SGB border tiles did not survive a state round trip")
  # The border image itself is derived, and re-rendered inline by the loader:
  # both frontends size the window from border_valid, so it must be true the
  # instant the load returns, not one frame later.
  check(s.border_valid, "border was not re-rendered by the state loader")
  var post_bad = 0
  for py in 0 ..< 224:
    for px in 0 ..< 256:
      let tile = expected_border_tile(px div 8, py div 8)
      let ci = tile and 15
      let want = if ci == 0: 0'u16 else: BORDER_COLORS[ci] or 0x8000'u16
      if s.border[py * 256 + px] != want: inc post_bad
  check(post_bad == 0, &"border image wrong after a state load: {post_bad} px")
  check(GB_PAYLOAD_VERSION == 5'u32, "GB payload revision should be 5 for the SGB section")

# ---- direct packet-injection tests --------------------------------------
# The synthetic ROM cannot reach every command shape (a 16-byte packet holds
# only so much), and Pokemon Blue happens to use PAL_TRN + PAL_SET + ATTR_BLK
# and nothing else. These drive the SAME receiver the cart does -- P1 writes,
# reset pulse, LSB-first bits, stop bit -- so nothing here bypasses the decode.

proc pulse(gb: GB; group: seq[uint8]) =
  ## Clock a whole command group down P1 the way a cart does.
  let packets = group.len div 16
  for p in 0 ..< packets:
    joypad_write(gb.joypad, gb, 0x00)          # reset pulse
    joypad_write(gb.joypad, gb, 0x30)
    for i in 0 ..< 16:
      let byt = group[p * 16 + i]
      for b in 0 ..< 8:
        # P15 low = a 1 bit, P14 low = a 0 bit; both high between.
        joypad_write(gb.joypad, gb, if ((byt shr b) and 1) != 0: 0x10 else: 0x20)
        joypad_write(gb.joypad, gb, 0x30)
    joypad_write(gb.joypad, gb, 0x20)          # stop bit (0)
    joypad_write(gb.joypad, gb, 0x30)

proc packet(cmd: int; total: int; data: openArray[uint8]): seq[uint8] =
  result = newSeq[uint8](16)
  result[0] = uint8(cmd shl 3) or uint8(total)
  for i in 0 ..< min(data.len, 15): result[i + 1] = data[i]

block multi_packet_attr_chr:
  # ATTR_CHR with 40 data sets, which needs two packets: 4 header/param bytes
  # plus 10 data bytes fit in packet 0, the rest continue in packet 1.
  var m2 = new_gb("", ROM, fifo = true, headless = true, run_bios = false)
  m2.sgb_requested = true
  m2.post_init()
  for _ in 0 ..< 20: m2.step_frame()
  let s2 = m2.sgb
  for i in 0 ..< s2.attr.len: s2.attr[i] = 0

  const N = 40
  var grp = newSeq[uint8](32)
  grp[0] = uint8(0x07 shl 3) or 2           # ATTR_CHR, 2 packets
  grp[1] = 0                                # start X
  grp[2] = 0                                # start Y
  grp[3] = uint8(N and 0xFF); grp[4] = uint8(N shr 8)
  grp[5] = 0                                # left to right
  # Data set i gets palette (i mod 4); four sets per byte, MSB pair first.
  for i in 0 ..< N:
    let o = 6 + (i div 4)
    grp[o] = grp[o] or (uint8(i mod 4) shl (6 - (i mod 4) * 2))
  m2.pulse(grp)
  var chr_bad = 0
  for i in 0 ..< N:
    let x = i mod 20
    let y = i div 20
    if s2.attr[y * 20 + x] != uint8(i mod 4): inc chr_bad
  check(chr_bad == 0, &"ATTR_CHR across two packets: {chr_bad}/{N} cells wrong")
  # Everything past the 40 sets must be untouched.
  check(s2.attr[N] == 0, "ATTR_CHR wrote past its data-set count")

  # ATTR_LIN: one horizontal line (row 5 -> palette 2) and one vertical
  # (column 3 -> palette 1).
  m2.pulse(packet(0x05, 1, [2'u8, 0x80'u8 or (2'u8 shl 5) or 5'u8,
                            (1'u8 shl 5) or 3'u8]))
  var lin_bad = 0
  for x in 0 ..< 20:
    if x != 3 and s2.attr[5 * 20 + x] != 2: inc lin_bad
  for y in 0 ..< 18:
    if s2.attr[y * 20 + 3] != 1: inc lin_bad
  check(lin_bad == 0, &"ATTR_LIN: {lin_bad} cells wrong")

  # PAL_SET pulls four palettes out of the system palette RAM PAL_TRN fills,
  # and can apply an attribute file in the same command. Seed both directly
  # (a real PAL_TRN/ATTR_TRN is a VRAM transfer, covered by the ROM above).
  for id in 0 ..< 512:
    for c in 0 ..< 4:
      s2.syspal[id * 4 + c] = uint16((id * 4 + c) and 0x7FFF)
  for i in 0 ..< s2.atf.len: s2.atf[i] = 0
  # ATF 3: every cell palette 2 (bit pairs 10 10 10 10 = 0xAA).
  for i in 0 ..< 90: s2.atf[3 * 90 + i] = 0xAA
  m2.pulse(packet(0x0A, 1, [
    0x07'u8, 0x00,        # palette 0 <- system palette 7
    0x40'u8, 0x01,        # palette 1 <- system palette 320
    0x02'u8, 0x00,        # palette 2 <- system palette 2
    0x09'u8, 0x00,        # palette 3 <- system palette 9
    0x80'u8 or 3'u8]))    # apply ATF 3
  check(s2.pal[1] == uint16(7 * 4 + 1) and s2.pal[3] == uint16(7 * 4 + 3),
        "PAL_SET did not copy system palette 7 into palette 0")
  check(s2.pal[4 * 1 + 2] == uint16(320 * 4 + 2),
        "PAL_SET did not copy system palette 320 into palette 1")
  # Colour 0 is one shared backdrop, taken from palette 0's.
  check(s2.pal[0] == s2.pal[4] and s2.pal[4] == s2.pal[8] and
        s2.pal[8] == s2.pal[12], "PAL_SET left the four colour 0s unshared")
  var atf_bad = 0
  for a in s2.attr:
    if a != 2: inc atf_bad
  check(atf_bad == 0, &"PAL_SET's Apply-ATF flag: {atf_bad}/360 cells wrong")

  # ATTR_SET on its own, with the cancel-mask bit.
  for i in 0 ..< 90: s2.atf[5 * 90 + i] = 0x55   # every cell palette 1
  s2.mask = 2
  m2.pulse(packet(0x16, 1, [0x40'u8 or 5'u8]))
  check(s2.attr[0] == 1 and s2.attr[359] == 1, "ATTR_SET did not apply ATF 5")
  check(s2.mask == 0, "ATTR_SET bit 6 did not cancel the mask")

block mask_en:
  var m3 = new_gb("", ROM, fifo = true, headless = true, run_bios = false)
  m3.sgb_requested = true
  m3.post_init()
  for _ in 0 ..< 30: m3.step_frame()
  let s3 = m3.sgb
  var live: seq[uint16] = @[]
  for v in m3.ppu.framebuffer: live.add(v)

  # MASK_EN 1 freezes the picture the SNES last stored.
  m3.pulse(packet(0x17, 1, [1'u8]))
  for _ in 0 ..< 5: m3.step_frame()
  var frozen_ok = true
  for i in 0 ..< live.len:
    if m3.ppu.framebuffer[i] != live[i]: frozen_ok = false
  check(frozen_ok, "MASK_EN 1 did not freeze the screen")

  # MASK_EN 2 blanks it black.
  m3.pulse(packet(0x17, 1, [2'u8]))
  m3.step_frame()
  var black = true
  for v in m3.ppu.framebuffer:
    if v != 0: black = false
  check(black, "MASK_EN 2 did not blank the screen to black")

  # MASK_EN 3 blanks it to the backdrop (colour 0).
  m3.pulse(packet(0x17, 1, [3'u8]))
  m3.step_frame()
  var backdrop_ok = true
  for v in m3.ppu.framebuffer:
    if v != s3.pal[0]: backdrop_ok = false
  check(backdrop_ok, "MASK_EN 3 did not blank the screen to the backdrop")

  # MASK_EN 0 hands the screen back.
  m3.pulse(packet(0x17, 1, [0'u8]))
  for _ in 0 ..< 3: m3.step_frame()
  var restored = false
  for v in m3.ppu.framebuffer:
    if v != 0 and v != s3.pal[0]: restored = true
  check(restored, "MASK_EN 0 did not release the screen")

block mlt_req:
  var m4 = new_gb("", ROM, fifo = true, headless = true, run_bios = false)
  m4.sgb_requested = true
  m4.post_init()
  for _ in 0 ..< 20: m4.step_frame()
  let s4 = m4.sgb
  check(s4.players == 1, "player count should start at 1")
  # Deselecting both groups reads a joypad ID: 0xF, 0xE, 0xD, 0xC for players
  # 1..4, advancing on each rising edge of P15.
  m4.pulse(packet(0x11, 1, [1'u8]))          # two players
  check(s4.players == 2, "MLT_REQ 1 should select two players")
  joypad_write(m4.joypad, m4, 0x30)
  var ids: seq[uint8] = @[]
  for _ in 0 ..< 4:
    ids.add(joypad_read(m4.joypad, m4) and 0x0F)
    joypad_write(m4.joypad, m4, 0x10)        # P15 low
    joypad_write(m4.joypad, m4, 0x30)        # rising edge -> next player
  check(ids == @[0x0F'u8, 0x0E'u8, 0x0F'u8, 0x0E'u8],
        &"two-player joypad IDs should alternate 0xF/0xE, got {ids}")
  m4.pulse(packet(0x11, 1, [0'u8]))          # back to one player
  check(s4.players == 1, "MLT_REQ 0 should return to one player")
  joypad_write(m4.joypad, m4, 0x30)
  joypad_write(m4.joypad, m4, 0x10)
  joypad_write(m4.joypad, m4, 0x30)
  check((joypad_read(m4.joypad, m4) and 0x0F) == 0x0F,
        "one-player mode must always read joypad ID 0xF")

# ---- a state written WITH the adapter must load WITHOUT it, and back ----
block cross_config_state:
  var withsgb = new_gb("", ROM, fifo = true, headless = true, run_bios = false)
  withsgb.sgb_requested = true
  withsgb.post_init()
  for _ in 0 ..< 20: withsgb.step_frame()
  check(withsgb.sgb != nil, "cross-config: setup machine has no adapter")
  let sgb_payload = withsgb.state_payload()

  # Super Game Boy is a frontend setting, so this is an ordinary thing for a
  # user to do: save with it on, turn it off, load.
  var without = new_gb("", ROM, fifo = true, headless = true, run_bios = false)
  without.post_init()
  check(without.sgb == nil, "cross-config: control machine got an adapter")
  var ok_off = true
  try: without.apply_state_payload(sgb_payload)
  except CatchableError as e:
    ok_off = false
    echo "  (", e.msg, ")"
  check(ok_off, "an SGB state must load into a machine with SGB turned off")
  if ok_off:
    without.step_frame()
    var mono = true
    for v in without.ppu.framebuffer:
      if v notin DMG_COLORS: mono = false
    check(mono, "after loading an SGB state with SGB off, the screen must be " &
                "plain DMG shades")

  # And the other way: a state written without the section into a machine
  # that has an adapter.
  let plain_payload = without.state_payload()
  var back = new_gb("", ROM, fifo = true, headless = true, run_bios = false)
  back.sgb_requested = true
  back.post_init()
  var ok_on = true
  try: back.apply_state_payload(plain_payload)
  except CatchableError as e:
    ok_on = false
    echo "  (", e.msg, ")"
  check(ok_on, "a non-SGB state must load into a machine with SGB turned on")

# ---- optional PNG dump ----
when defined(sgb_png):
  proc dump(path: string; src: openArray[uint16]; w, h: int; over: bool) =
    var rgb = newSeq[uint8](w * h * 3)
    for i in 0 ..< w * h:
      let v = src[i]
      rgb[i * 3]     = uint8(((v and 0x1F) * 255) div 31)
      rgb[i * 3 + 1] = uint8((((v shr 5) and 0x1F) * 255) div 31)
      rgb[i * 3 + 2] = uint8((((v shr 10) and 0x1F) * 255) div 31)
    discard stbiw.writePNG(path, w, h, 3, rgb)

  let outdir = getEnv("DINGBAT_SGB_PNG")
  if outdir.len > 0:
    createDir(outdir)
    dump(outdir / "screen.png", m.ppu.framebuffer, 160, 144, false)
    dump(outdir / "border.png", s.border, 256, 224, false)
    # The composite the frontend would show: border over the centred screen.
    var comp = newSeq[uint16](256 * 224)
    for i in 0 ..< comp.len: comp[i] = s.pal[0]
    for y in 0 ..< 144:
      for x in 0 ..< 160:
        comp[(y + 40) * 256 + (x + 48)] = m.ppu.framebuffer[y * 160 + x]
    for i in 0 ..< comp.len:
      if (s.border[i] and 0x8000'u16) != 0: comp[i] = s.border[i] and 0x7FFF'u16
    dump(outdir / "composite.png", comp, 256, 224, false)
    echo "wrote PNGs to ", outdir

if failures == 0:
  echo "sgb_test: all checks passed"
else:
  echo &"sgb_test: {failures} failure(s)"
  quit(1)
