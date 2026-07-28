## Differential fuzz for the GBA per-line OBJ candidate list.
##
## Why this exists: `render_sprites` used to look at all 128 OAM entries on
## every scanline. It now walks a per-line 128-bit candidate bitmap instead
## (`ppu.obj_line_mask`), rebuilt only when OAM has changed. That is a pure
## performance change and MUST be pixel-for-pixel invisible.
##
## Its failure mode is a sprite configuration no real ROM happens to produce:
## a double-size affine sprite whose base box misses the line but whose drawn
## box covers it, a sprite parked past Y=160 that wraps to the top of the
## screen, an OBJ-window sprite that contributes only to the window mask, a
## sprite dropped by the per-line OBJ cycle budget. A boot sweep of commercial
## games is a bad instrument for those, so this file attacks them directly:
## thousands of randomized OAM tables, biased hard towards the boundaries,
## rendered BOTH ways and compared byte for byte.
##
## Two comparisons run on every table:
##
##  1. `render_sprites(force_scan = true)` (the reference 128-entry scan, still
##     compiled in as the rebuild-storm fallback) vs the candidate-list path.
##     All 240 `sprite_pixels` -- priority, palette, blend flag AND the OBJ
##     window flag -- plus the two per-line flags must match on all 160 lines.
##
##  2. The candidate bitmap against an independently written predicate. This is
##     tighter than (1): the scan body re-tests the y/x rejects, so an
##     over-inclusive mask is invisible to (1) even though it is a real
##     performance bug, and this catches it. The predicate below is derived
##     from the register layout, not by calling `obj_geometry`, so it is a
##     genuine second opinion rather than a restatement.
##
## Plus: mid-frame OAM writes through the real bus paths (the invalidation
## story), the rebuild-storm fallback, and coverage counters that FAIL if a
## hazard class never fired -- a fuzz that never generates an OBJ-window
## sprite proves nothing about OBJ-window sprites.
##
## And a negative control: the comparison is deliberately fed a corrupted mask
## and asserted to notice. Without that, "all tests pass" could just mean the
## harness is comparing nothing.
##
## Run with: nimble test_ppuobjlist

import std/[os, strutils]
import dingbat/gba/gba

var failures = 0

proc check(cond: bool; name: string; detail = "") =
  if cond:
    echo "  [PASS] ", name
  else:
    echo "  [FAIL] ", name, (if detail.len > 0: "  " & detail else: "")
    inc failures

# --- deterministic RNG, independent of emulator state ------------------------
var rng: uint64 = 0x9E3779B97F4A7C15'u64
proc nxt(): uint32 =
  rng = rng xor (rng shl 13)
  rng = rng xor (rng shr 7)
  rng = rng xor (rng shl 17)
  uint32(rng shr 32)

proc below(n: int): int = int(nxt() mod uint32(n))
proc pick[T](xs: openArray[T]): T = xs[below(xs.len)]
proc reseed(s: uint64) = rng = s

# ---------------------------------------------------------------------------
# Emulator under test. The OBJ renderer reads OAM, OBJ VRAM (0x10000 up) and
# DISPCNT/MOSAIC only, all of which the tests overwrite, so the ROM contents
# are irrelevant -- it exists purely so new_cartridge has a file to open.
# ---------------------------------------------------------------------------
proc make_emu(): GBA =
  let rom_path = getTempDir() / "dingbat_ppuobjlist_synthetic.gba"
  if not fileExists(rom_path):
    var rom = newString(0x8000)
    for i in 0 ..< rom.len: rom[i] = char((i * 11 + 5) and 0xFF)
    writeFile(rom_path, rom)
  result = new_gba("", rom_path, run_bios = false, use_hle = true)
  result.post_init()

# ---------------------------------------------------------------------------
# The independent predicate.
#
# Written from the register layout rather than from obj_geometry, so that a
# wrong sign extension or a forgotten double-size doubling shows up as a
# disagreement instead of being copied into both sides.
#
# attr0: bits 0-7 Y, bit 8 rot/scale, bit 9 double-size (or "disabled" when
#        bit 8 is clear), bits 14-15 shape
# attr1: bits 0-8 X, bits 14-15 size
# ---------------------------------------------------------------------------
proc expected_covers(oam: seq[byte]; s_idx, line: int): bool =
  let o = s_idx * 8
  let attr0 = uint16(oam[o]) or (uint16(oam[o + 1]) shl 8)
  let attr1 = uint16(oam[o + 2]) or (uint16(oam[o + 3]) shl 8)
  let rot_scale = (attr0 and 0x0100'u16) != 0
  let dbl_or_off = (attr0 and 0x0200'u16) != 0
  if (not rot_scale) and dbl_or_off: return false   # explicitly disabled
  let shape = int(attr0 shr 14)
  if shape == 3: return false                       # prohibited: no footprint
  let size = int(attr1 shr 14)
  const W = [[8, 16, 32, 64], [16, 32, 32, 64], [8, 8, 16, 32]]
  const H = [[8, 16, 32, 64], [8, 8, 16, 32], [16, 32, 32, 64]]
  var w = W[shape][size]
  var h = H[shape][size]
  if rot_scale and dbl_or_off:                      # double-size bounding box
    w *= 2
    h *= 2
  var y = int(attr0 and 0xFF'u16)
  if y > 159: y -= 256                              # wraps off the top
  var x = int(attr1 and 0x1FF'u16)
  if x > 239: x -= 512                              # wraps off the left
  if x + w < 0: return false                        # entirely off the left edge
  y <= line and line < y + h

# ---------------------------------------------------------------------------
# OAM generators. Each returns the name of the hazard class it emphasises so
# the coverage assertions can prove the class was actually produced.
# ---------------------------------------------------------------------------

# Y values that sit on every boundary the wrap logic has: 0, the last visible
# line, the 159/160 signed-model threshold, and the region that wraps to the
# top of the screen.
const HOT_Y = [0, 1, 7, 8, 63, 64, 128, 129, 152, 153, 158, 159, 160, 161,
               168, 191, 192, 200, 224, 240, 248, 250, 252, 254, 255]
# X values around 0, the right edge, the 239/240 signed threshold, and the
# far-left wrap where a 64-wide sprite is partly on screen.
const HOT_X = [0, 1, 8, 232, 239, 240, 241, 248, 256, 320, 383, 384, 448,
               456, 480, 496, 504, 505, 508, 511]

proc rand_attr0(class: string): uint16 =
  let y = uint16(pick(HOT_Y))
  var a0 = y and 0xFF'u16
  case class
  of "affine-double":
    a0 = a0 or 0x0300'u16                      # rot/scale + double-size
  of "affine":
    a0 = a0 or 0x0100'u16
  of "disabled":
    a0 = a0 or 0x0200'u16                      # rot/scale clear + bit 9 = off
  of "objwindow":
    a0 = a0 or 0x0800'u16                      # OBJ mode 2
    if below(2) == 0: a0 = a0 or 0x0100'u16
    if below(4) == 0: a0 = a0 or 0x0200'u16
  of "shape3":
    a0 = a0 or 0xC000'u16
  else:
    a0 = a0 or (uint16(below(4)) shl 8)        # any rot/scale + bit-9 combo
  if class != "objwindow":
    a0 = a0 or (uint16(below(3)) shl 10)       # OBJ mode 0/1/2
  if below(3) == 0: a0 = a0 or 0x1000'u16      # mosaic
  if below(2) == 0: a0 = a0 or 0x2000'u16      # 8bpp
  if class != "shape3":
    a0 = a0 or (uint16(below(3)) shl 14)       # shape 0/1/2
  a0

proc rand_attr1(): uint16 =
  var a1 = uint16(pick(HOT_X)) and 0x1FF'u16
  a1 = a1 or (uint16(below(32)) shl 9)         # affine index / flip bits
  a1 = a1 or (uint16(below(4)) shl 14)         # size
  a1

proc rand_attr2(): uint16 =
  uint16(below(1024)) or (uint16(below(4)) shl 10) or (uint16(below(16)) shl 12)

proc fill_oam(oam: var seq[byte]; class: string) =
  for s in 0 ..< 128:
    let o = s * 8
    let a0 = (if class == "uniform": uint16(nxt() and 0xFFFF) else: rand_attr0(class))
    let a1 = (if class == "uniform": uint16(nxt() and 0xFFFF) else: rand_attr1())
    let a2 = (if class == "uniform": uint16(nxt() and 0xFFFF) else: rand_attr2())
    oam[o + 0] = uint8(a0 and 0xFF); oam[o + 1] = uint8(a0 shr 8)
    oam[o + 2] = uint8(a1 and 0xFF); oam[o + 3] = uint8(a1 shr 8)
    oam[o + 4] = uint8(a2 and 0xFF); oam[o + 5] = uint8(a2 shr 8)
    # bytes 6-7 are the affine parameter for this slot; always randomised so
    # affine sprites get real (often degenerate) transforms
    oam[o + 6] = uint8(nxt() and 0xFF); oam[o + 7] = uint8(nxt() and 0xFF)

proc fill_oam_crowd(oam: var seq[byte]; line: int) =
  ## 128 sprites all covering one line, most of them 64 wide, so the per-line
  ## OBJ cycle budget runs out partway down OAM and later entries are dropped.
  ## This is the Famicom Mini masking-sprite behaviour; the candidate list must
  ## reproduce the identical cutoff point.
  for s in 0 ..< 128:
    let o = s * 8
    var a0 = uint16(max(0, line - below(8))) and 0xFF'u16
    if below(4) == 0: a0 = a0 or 0x0300'u16    # some affine (2x the charge)
    a0 = a0 or (uint16(below(3)) shl 10)
    let a1 = uint16(below(240)) or 0xC000'u16  # size 3 => 64 wide
    let a2 = rand_attr2()
    oam[o + 0] = uint8(a0 and 0xFF); oam[o + 1] = uint8(a0 shr 8)
    oam[o + 2] = uint8(a1 and 0xFF); oam[o + 3] = uint8(a1 shr 8)
    oam[o + 4] = uint8(a2 and 0xFF); oam[o + 5] = uint8(a2 shr 8)
    oam[o + 6] = uint8(nxt() and 0xFF); oam[o + 7] = uint8(nxt() and 0xFF)

proc rand_dispcnt(): uint16 =
  ## OBJ always enabled (bit 12); mode, 1D/2D mapping, frame select and the
  ## H-blank-interval-free bit (which halves the OBJ cycle budget) all vary.
  var d = uint16(below(6))                     # bg_mode 0-5
  d = d or 0x1000'u16                          # OBJ enable
  if below(2) == 0: d = d or 0x0020'u16        # hblank_interval_free
  if below(2) == 0: d = d or 0x0040'u16        # obj_mapping_1d
  if below(4) == 0: d = d or 0x0010'u16        # display_frame_select
  d

# ---------------------------------------------------------------------------
# Rendering one line each way and comparing.
# ---------------------------------------------------------------------------
type LineResult = object
  pixels: array[240, SpritePixel]
  objwin: bool
  blend:  bool

proc render_line(ppu: PPU; line: int; force_scan: bool): LineResult =
  ppu.vcount = uint16(line)
  for c in 0 .. 239: ppu.sprite_pixels[c] = SPRITE_PIXEL_DEFAULT
  ppu.line_obj_window = false
  ppu.line_sprite_blend = false
  ppu.render_sprites(force_scan)
  result.pixels = ppu.sprite_pixels
  result.objwin = ppu.line_obj_window
  result.blend  = ppu.line_sprite_blend

proc diff(a, b: LineResult): string =
  if a.objwin != b.objwin: return "line_obj_window " & $a.objwin & " vs " & $b.objwin
  if a.blend != b.blend: return "line_sprite_blend " & $a.blend & " vs " & $b.blend
  for c in 0 .. 239:
    if a.pixels[c] != b.pixels[c]:
      return "col " & $c & ": " & $a.pixels[c] & " vs " & $b.pixels[c]
  ""

# Coverage: how many times each interesting situation was actually rendered.
var cov_sprite_px = 0     # a coloured OBJ pixel landed
var cov_window_px = 0     # an OBJ-window pixel landed
var cov_blend_px  = 0     # a semi-transparent OBJ pixel landed
var cov_budget    = 0     # the OBJ cycle budget cut the list short
var cov_dbl_only  = 0     # a line covered ONLY because of double-size doubling
var cov_wrap_y    = 0     # a line covered by a sprite whose raw Y is > 159
var cov_wrap_x    = 0     # an on-line sprite whose raw X is > 239
var cov_candidates = 0    # total candidate bits set
var cov_lines      = 0    # lines rendered

proc note_coverage(oam: seq[byte]; line: int; r: LineResult) =
  inc cov_lines
  for c in 0 .. 239:
    if r.pixels[c].palette != 0: inc cov_sprite_px
    if r.pixels[c].window: inc cov_window_px
    if r.pixels[c].blends: inc cov_blend_px
  for s in 0 ..< 128:
    if not expected_covers(oam, s, line): continue
    inc cov_candidates
    let o = s * 8
    let attr0 = uint16(oam[o]) or (uint16(oam[o + 1]) shl 8)
    let attr1 = uint16(oam[o + 2]) or (uint16(oam[o + 3]) shl 8)
    if int(attr0 and 0xFF'u16) > 159: inc cov_wrap_y
    if int(attr1 and 0x1FF'u16) > 239: inc cov_wrap_x
    if (attr0 and 0x0300'u16) == 0x0300'u16:
      # covered now; would the un-doubled box have covered it?
      let shape = int(attr0 shr 14)
      if shape != 3:
        let size = int(attr1 shr 14)
        const H = [[8, 16, 32, 64], [8, 8, 16, 32], [16, 32, 32, 64]]
        let h = H[shape][size]
        var y = int(attr0 and 0xFF'u16)
        if y > 159: y -= 256
        if not (y <= line and line < y + h): inc cov_dbl_only

proc obj_budget_exhausted(ppu: PPU; oam: seq[byte]; line: int): bool =
  ## Recompute the budget walk to tell whether the cutoff actually fired.
  var budget = if ppu.dispcnt.hblank_interval_free: 954 else: 1210
  for s in 0 ..< 128:
    if budget <= 0: return true
    if not expected_covers(oam, s, line): continue
    let o = s * 8
    let attr0 = uint16(oam[o]) or (uint16(oam[o + 1]) shl 8)
    let attr1 = uint16(oam[o + 2]) or (uint16(oam[o + 3]) shl 8)
    let shape = int(attr0 shr 14)
    let size = int(attr1 shr 14)
    const W = [[8, 16, 32, 64], [16, 32, 32, 64], [8, 8, 16, 32]]
    var w = W[shape][size]
    if (attr0 and 0x0300'u16) == 0x0300'u16: w *= 2
    if (attr0 and 0x0100'u16) != 0: budget -= 10 + 2 * w
    else: budget -= w
  false

# ---------------------------------------------------------------------------
# 1. The main differential sweep.
# ---------------------------------------------------------------------------
proc test_differential(emu: GBA; tables: int) =
  echo "Differential: candidate list vs full 128-entry scan"
  let ppu = emu.ppu
  const CLASSES = ["uniform", "mixed", "affine", "affine-double", "disabled",
                   "objwindow", "shape3"]
  var mismatches = 0
  var mask_mismatches = 0
  var first_detail = ""
  var first_mask_detail = ""
  for t in 0 ..< tables:
    let class = CLASSES[t mod CLASSES.len]
    fill_oam(ppu.oam, class)
    ppu.dispcnt = cast[DISPCNT](rand_dispcnt())
    ppu.mosaic = cast[MOSAIC](uint16(nxt() and 0xFFFF))
    ppu.oam_touched()
    ppu.obj_list_rebuilds = 0
    for line in 0 .. 159:
      let listed = render_line(ppu, line, false)
      let scanned = render_line(ppu, line, true)
      let d = diff(listed, scanned)
      if d.len > 0:
        inc mismatches
        if first_detail.len == 0:
          first_detail = "table " & $t & " (" & class & ") line " & $line & ": " & d
      note_coverage(ppu.oam, line, scanned)
      if obj_budget_exhausted(ppu, ppu.oam, line): inc cov_budget
      # (2) the mask itself, against the independent predicate
      for s in 0 ..< 128:
        let bit_set = (ppu.obj_line_mask[line][s shr 6] and
                       (1'u64 shl uint(s and 63))) != 0
        if bit_set != expected_covers(ppu.oam, s, line):
          inc mask_mismatches
          if first_mask_detail.len == 0:
            first_mask_detail = "table " & $t & " (" & class & ") line " &
              $line & " entry " & $s & ": mask=" & $bit_set &
              " expected=" & $(not bit_set)
  check(mismatches == 0,
        "pixel-identical over " & $tables & " OAM tables x 160 lines",
        (if mismatches > 0: $mismatches & " mismatching lines; first: " &
                            first_detail else: ""))
  check(mask_mismatches == 0,
        "candidate bitmap matches the independent coverage predicate",
        first_mask_detail)

# ---------------------------------------------------------------------------
# 2. The OBJ cycle budget cutoff.
# ---------------------------------------------------------------------------
proc test_budget(emu: GBA; tables: int) =
  echo "OBJ cycle budget: the drop point must be identical"
  let ppu = emu.ppu
  var mismatches = 0
  var exhausted = 0
  var detail = ""
  for t in 0 ..< tables:
    let line = below(160)
    fill_oam_crowd(ppu.oam, line)
    ppu.dispcnt = cast[DISPCNT](rand_dispcnt())
    ppu.mosaic = cast[MOSAIC](uint16(nxt() and 0xFFFF))
    ppu.oam_touched()
    ppu.obj_list_rebuilds = 0
    for l in max(0, line - 4) .. min(159, line + 4):
      let listed = render_line(ppu, l, false)
      let scanned = render_line(ppu, l, true)
      let d = diff(listed, scanned)
      if d.len > 0:
        inc mismatches
        if detail.len == 0: detail = "table " & $t & " line " & $l & ": " & d
      if obj_budget_exhausted(ppu, ppu.oam, l): inc exhausted
  check(mismatches == 0, "128 crowded sprites, budget exhausted: identical", detail)
  check(exhausted > tables div 4,
        "the budget cutoff actually fired (" & $exhausted & " lines)",
        "the crowding generator is not crowding")

# ---------------------------------------------------------------------------
# 3. Mid-frame OAM writes through the real bus paths.
#
# This is the invalidation story. OAM byte writes are discarded by hardware,
# so halfword and word writes are the only two entries -- and DMA and the
# cheat engine both funnel through them. Writing through
# write_half_internal/write_word_internal here means the test exercises the
# same hook a game does, not a direct poke into the seq.
# ---------------------------------------------------------------------------
proc test_midframe(emu: GBA; frames: int) =
  echo "Mid-frame OAM writes: invalidation via the bus write paths"
  let ppu = emu.ppu
  let bus = emu.bus
  var mismatches = 0
  var writes = 0
  var detail = ""
  for f in 0 ..< frames:
    fill_oam(ppu.oam, "mixed")
    ppu.dispcnt = cast[DISPCNT](rand_dispcnt())
    ppu.mosaic = cast[MOSAIC](uint16(nxt() and 0xFFFF))
    ppu.oam_touched()
    ppu.obj_list_rebuilds = 0
    for line in 0 .. 159:
      # A burst of OAM traffic before this line renders, the way an H-blank
      # DMA or a sprite-disable-midline routine does it.
      let n = below(4)
      for _ in 0 ..< n:
        let s = below(128)
        let attr = below(3)
        let addr32 = 0x07000000'u32 + uint32(s * 8 + attr * 2)
        if below(2) == 0:
          let v = (if attr == 0: rand_attr0("mixed")
                   elif attr == 1: rand_attr1() else: rand_attr2())
          bus.write_half_internal(addr32, v)
        else:
          let lo = (if attr == 0: rand_attr0("mixed")
                    elif attr == 1: rand_attr1() else: rand_attr2())
          let hi = rand_attr2()
          bus.write_word_internal(addr32 and not 3'u32,
                                  uint32(lo) or (uint32(hi) shl 16))
        inc writes
      # The candidate path runs FIRST, so it sees whatever mask state the
      # writes left behind. force_scan never touches the mask, so the
      # reference cannot repair a stale one.
      let listed = render_line(ppu, line, false)
      let scanned = render_line(ppu, line, true)
      let d = diff(listed, scanned)
      if d.len > 0:
        inc mismatches
        if detail.len == 0: detail = "frame " & $f & " line " & $line & ": " & d
  check(mismatches == 0,
        "OAM rewritten between scanlines (" & $writes & " writes): identical",
        detail)

# ---------------------------------------------------------------------------
# 4. The rebuild-storm fallback.
#
# Past OBJ_LIST_REBUILD_LIMIT rebuilds in one frame the renderer stops
# trusting the mask and scans. That path must be (a) correct and (b) actually
# reachable -- a guard that never engages is a guard that was never tested.
# ---------------------------------------------------------------------------
proc test_rebuild_guard(emu: GBA) =
  echo "Rebuild-storm fallback"
  let ppu = emu.ppu
  let bus = emu.bus
  var mismatches = 0
  var rebuilds_seen = 0
  var detail = ""
  for f in 0 ..< 8:
    fill_oam(ppu.oam, "mixed")
    ppu.dispcnt = cast[DISPCNT](rand_dispcnt())
    ppu.oam_touched()
    ppu.obj_list_rebuilds = 0
    for line in 0 .. 159:
      # Dirty EVERY line, which is the pathological case the guard exists for
      bus.write_half_internal(0x07000000'u32 + uint32(below(128) * 8),
                              rand_attr0("mixed"))
      let listed = render_line(ppu, line, false)
      let scanned = render_line(ppu, line, true)
      let d = diff(listed, scanned)
      if d.len > 0:
        inc mismatches
        if detail.len == 0: detail = "frame " & $f & " line " & $line & ": " & d
    rebuilds_seen = ppu.obj_list_rebuilds
  check(mismatches == 0, "OAM dirtied on all 160 lines: identical", detail)
  check(rebuilds_seen == OBJ_LIST_REBUILD_LIMIT,
        "rebuilds capped at OBJ_LIST_REBUILD_LIMIT (" & $rebuilds_seen & ")",
        "guard did not engage")

# ---------------------------------------------------------------------------
# 4b. The two OAM mutation paths that are NOT bus writes.
#
# Reading the code turns up two more writers besides write_half_internal and
# write_word_internal: the HLE RegisterRamReset SWI's OAM clear phase, and
# save-state load. Neither is reachable from a bus write, and -- measured --
# NEITHER IS EXERCISED by any of 71 local ROMs booted for 120 frames under the
# -d:objListVerify cross-check, so nothing else in the tree would notice if
# their hooks were dropped. Hence these.
#
# The assertion in both cases: after the mutation the cached mask must either
# still be marked dirty, or agree with a fresh rebuild. A missing hook leaves
# it clean AND stale, which is exactly what fails here.
# ---------------------------------------------------------------------------
proc mask_is_consistent(ppu: PPU): bool =
  if ppu.obj_list_dirty: return true
  let cached = ppu.obj_line_mask
  ppu.rebuild_obj_lines()
  cached == ppu.obj_line_mask

proc test_nonbus_writers(emu: GBA) =
  echo "OAM writers that are not bus writes"
  let ppu = emu.ppu
  # --- HLE RegisterRamReset (SWI 0x01) with the OAM bit set ---
  fill_oam(ppu.oam, "mixed")
  ppu.dispcnt = cast[DISPCNT](0x1000'u16)
  ppu.oam_touched()
  ppu.obj_list_rebuilds = 0
  ppu.rebuild_obj_lines()                 # cache a mask of the pre-reset OAM
  var pre_nonempty = false
  for line in 0 .. 159:
    if ppu.obj_line_mask[line][0] != 0 or ppu.obj_line_mask[line][1] != 0:
      pre_nonempty = true
  emu.cpu.r[0] = 0x10'u32                 # bit 4 = OAM
  emu.cpu.hle_swi(0x01'u32)
  var oam_cleared = true
  for b in ppu.oam:
    if b != 0: oam_cleared = false
  check(oam_cleared and pre_nonempty,
        "RegisterRamReset(OAM) cleared OAM behind the bus",
        "the SWI did not run, so the check below is vacuous")
  check(ppu.mask_is_consistent(),
        "RegisterRamReset(OAM) invalidated the candidate list",
        "stale mask survived an OAM clear")

  # --- save-state load ---
  ppu.obj_list_rebuilds = 0
  fill_oam(ppu.oam, "mixed")
  ppu.oam_touched()
  ppu.rebuild_obj_lines()
  let state_path = getTempDir() / "dingbat_ppuobjlist.state"
  let saved = emu.save_state(state_path)  # a state whose OAM is this table
  check(saved, "save state written")
  fill_oam(ppu.oam, "affine-double")      # now make the live OAM different
  ppu.oam_touched()
  ppu.rebuild_obj_lines()                 # ...and cache a mask matching THAT
  let loaded = emu.load_state_bytes(readFile(state_path))
  check(loaded, "save state loaded")
  check(ppu.mask_is_consistent(),
        "save-state load invalidated the candidate list",
        "stale mask survived a state load")

# ---------------------------------------------------------------------------
# 5. Negative control.
#
# Everything above is a comparison, and a comparison that cannot fail proves
# nothing. Corrupt the mask by hand and confirm both detectors notice: the
# pixel diff (a dropped sprite) and the predicate check (a wrong bit).
# ---------------------------------------------------------------------------
proc test_negative_control(emu: GBA) =
  echo "Negative control: a deliberately broken mask must be caught"
  let ppu = emu.ppu
  var caught_pixels = false
  var caught_predicate = false
  for attempt in 0 ..< 400:
    fill_oam(ppu.oam, "mixed")
    ppu.dispcnt = cast[DISPCNT](0x1000'u16)   # mode 0, OBJ on
    ppu.mosaic = cast[MOSAIC](0'u16)
    ppu.oam_touched()
    ppu.obj_list_rebuilds = 0
    ppu.rebuild_obj_lines()
    for line in 0 .. 159:
      # Find a set bit and clear it: that is exactly "a sprite the list forgot"
      var victim = -1
      for s in 0 ..< 128:
        if (ppu.obj_line_mask[line][s shr 6] and (1'u64 shl uint(s and 63))) != 0:
          victim = s
          break
      if victim < 0: continue
      let saved = ppu.obj_line_mask[line]
      ppu.obj_line_mask[line][victim shr 6] =
        ppu.obj_line_mask[line][victim shr 6] and
        not (1'u64 shl uint(victim and 63))
      if expected_covers(ppu.oam, victim, line): caught_predicate = true
      ppu.obj_list_dirty = false             # stop the renderer repairing it
      let listed = render_line(ppu, line, false)
      let scanned = render_line(ppu, line, true)
      if diff(listed, scanned).len > 0: caught_pixels = true
      ppu.obj_line_mask[line] = saved
      if caught_pixels and caught_predicate: break
    if caught_pixels and caught_predicate: break
  check(caught_pixels,
        "clearing a candidate bit changes the rendered line",
        "the pixel comparison is vacuous")
  check(caught_predicate,
        "clearing a candidate bit disagrees with the predicate",
        "the mask comparison is vacuous")

# ---------------------------------------------------------------------------
# 6. Coverage assertions.
# ---------------------------------------------------------------------------
proc test_coverage() =
  echo "Hazard-class coverage (a fuzz that never hits a case proves nothing)"
  check(cov_candidates > 100000,
        "candidates rendered: " & $cov_candidates)
  check(cov_sprite_px > 10000, "coloured OBJ pixels drawn: " & $cov_sprite_px)
  check(cov_window_px > 1000, "OBJ-window pixels drawn: " & $cov_window_px)
  check(cov_blend_px > 1000, "semi-transparent OBJ pixels drawn: " & $cov_blend_px)
  check(cov_dbl_only > 100,
        "lines covered ONLY by the double-size box: " & $cov_dbl_only,
        "double-size bounding box never mattered")
  check(cov_wrap_y > 1000, "on-line sprites with raw Y > 159: " & $cov_wrap_y)
  check(cov_wrap_x > 1000, "on-line sprites with raw X > 239: " & $cov_wrap_x)
  check(cov_budget > 100, "lines where the OBJ budget ran out: " & $cov_budget)

when isMainModule:
  let heavy = getEnv("OBJLIST_HEAVY") == "1"
  # 5000 tables x 160 lines is ~3.4 s and ~800k compared scanlines -- cheap
  # enough for every CI run. OBJLIST_HEAVY=1 raises it to 20000 (~14 s, 3.2M
  # scanlines), which is what a change to the geometry or invalidation logic
  # should be run under locally.
  let tables = if heavy: 20000 else: 5000
  let emu = make_emu()
  # OBJ character data: 32K of OBJ VRAM at 0x10000. Random, then biased so a
  # good share of 4bpp nibbles are index 0 (transparent) and the priority /
  # first-writer-wins logic in sprite_pixels is actually exercised rather than
  # every sprite being fully opaque.
  reseed(0x243F6A8885A308D3'u64)
  for i in 0 ..< emu.ppu.vram.len: emu.ppu.vram[i] = uint8(nxt())
  for i in 0x10000 ..< emu.ppu.vram.len:
    if (nxt() and 3) == 0: emu.ppu.vram[i] = 0

  reseed(0xB5026F5AA96619E9'u64)
  test_differential(emu, tables)
  test_budget(emu, tables div 4)
  test_midframe(emu, max(4, tables div 100))
  test_rebuild_guard(emu)
  test_nonbus_writers(emu)
  test_negative_control(emu)
  test_coverage()

  echo ""
  if failures == 0:
    echo "ppuobjlist: all checks passed"
    quit(0)
  else:
    echo "ppuobjlist: ", failures, " FAILED"
    quit(1)
