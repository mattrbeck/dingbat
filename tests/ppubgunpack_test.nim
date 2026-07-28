## Equivalence tests for the SWAR 4bpp BG tile-row unpacker.
##
## `render_reg_bg` used to shift eight nibbles out of a 4bpp tile row one at a
## time. It now expands all eight at once into a uint64 and stores them with a
## single 8-byte store (`unpack_bg4_span`), falling back to the old per-pixel
## loop (`unpack_bg4_span_scalar`) for the partial spans at the two line edges.
##
## The point of this file is that "byte-identical on the ROMs we happened to
## test" is not good enough for a change to the pixel path. The transformation
## is pure and its input space is small enough to enumerate, so it is enumerated
## here.
##
## THE INPUT SPACE, AND WHY THE ENUMERATION BELOW IS COMPLETE
## ----------------------------------------------------------
## `unpack_bg4_span(dst, col, row, x_in_tile, span, flip_x_mask, bank)` is a
## pure function of five values (dst/col only select where the result lands):
##
##   * `row`      — the 4bpp tile row, one aligned uint32 = 8 nibbles. 2^32.
##   * `bank`     — the palette bank already shifted into the high nibble, so
##                  16 values: 0x00, 0x10, ... 0xF0. `screen_entry` bits 12..15
##                  can be anything, so all 16 are reachable.
##   * `flip_x_mask` — `7 * bit`, so exactly TWO values: 0 and 7. No other value
##                  is constructible at the call site.
##   * `x_in_tile` — `effective_col and 7`, so 0..7.
##   * `span`     — `min(8 - x_in_tile, 240 - col)`, so 1 <= span <= 8-x_in_tile.
##                  Pairs outside that triangle are unreachable AND would be
##                  out of contract: the nibble index (x_in_tile + k) would
##                  leave 0..7 and shift `row` by more than 28.
##
## Vertical flip, tile_id, screen_size, the screen-entry fetch and the BG
## wraparound all resolve BEFORE this function — they only choose which `row`,
## `bank` and `flip_x_mask` it sees, and every combination of those is covered
## below. That is why this decomposition loses nothing.
##
## The remaining inputs live one level up, in `render_reg_bg` itself: the
## `tile_base >= 0x10000` case (the BG unit cannot fetch character data from
## OBJ VRAM, so such tiles render transparent), 8bpp, horizontal mosaic, BG
## wraparound at the 256/512 boundary, and the four `screen_size` values. Part 2
## covers those by rendering real scanlines three ways and diffing.
##
## WHAT IS EXHAUSTIVE AND WHAT IS SAMPLED — read this before quoting coverage
## --------------------------------------------------------------------------
## EXHAUSTIVE (every value, no sampling):
##   1.1 flip x bank x (x_in_tile, span) shape        — all 2 x 16 x 36 shapes
##   1.2 single-nibble sweep: all 8 positions x 16 values x 16 banks x 2 flips,
##       against 14 fixed contexts for the other seven nibbles
##   1.3 adjacent-pair sweep: all 7 adjacencies x 256 pair values x 16 banks
##       x 2 flips, against 6 contexts — this is the carry-propagation test
##   1.4 half-word sweep: all 65536 values of each 16-bit half x 16 banks
##       x 2 flips x 3 contexts for the other half
##   2.1 the renderer sweep is exhaustive over screen_size (4), colour depth
##       (2), character_base_block (4) and BGHOFS (all 512 values, i.e. every
##       tile alignment and both sides of both wrap boundaries)
##   3   the FULL 2^32 x 16 x 2 sweep, opt-in via DINGBAT_BG4_EXHAUSTIVE=1
##       (too slow for CI at ~20 min single-threaded; DINGBAT_BG4_SHARD lets it
##       be split across cores)
##
## SAMPLED (a random or fixed subset, NOT exhaustive — do not describe as such):
##   1.5 whole-word fuzz — random (row, bank, flip) triples
##   2.x the tile MAPS and CHARACTER data behind the renderer sweep are PRNG
##       fill, and vcount/BGVOFS/screen_base_block are sampled, not enumerated
##
## The oracle is `unpack_bg4_span_scalar` itself — the shipping fallback, not a
## copy of it — so part 1 compares against real behaviour. Part 2 adds a third,
## independent model written from the register layout rather than from the
## renderer's structure, so a shared misreading of the tile format would still
## have to survive two disagreeing implementations.
##
## Run with: nimble test_ppubgunpack

import std/[os, strutils]
import dingbat/gba/gba

var failures = 0

proc check(cond: bool; name: string; detail = "") =
  if cond:
    echo "  [PASS] ", name
  else:
    echo "  [FAIL] ", name, (if detail.len > 0: "  " & detail else: "")
    inc failures

# --- deterministic RNG --------------------------------------------------------
var rng: uint64 = 0x243F6A8885A308D3'u64
proc nxt(): uint32 =
  rng = rng xor (rng shl 13)
  rng = rng xor (rng shr 7)
  rng = rng xor (rng shl 17)
  uint32(rng shr 32)
proc reseed(s: uint64) = rng = s

# =============================================================================
# PART 1 — the span unpacker, against its own scalar fallback
# =============================================================================

const SENTINEL = 0xCC'u8

# Both buffers are 16 bytes with the span written at offset 4, so an unpacker
# that wrote outside [4, 4+span) — before it, after it, or 8 bytes when it was
# asked for 3 — leaves the sentinel disturbed and is caught. That matters: the
# SWAR path always stores 8 bytes, and the whole reason it is gated on span == 8
# is that layer_palettes rows are exactly 240 bytes and sit next to each other.
const OFS = 4

var buf_fast: array[16, uint8]
var buf_ref:  array[16, uint8]

proc compare_span(row: uint32; x_in_tile, span, flip: int; bank: uint8): bool =
  for i in 0 ..< 16:
    buf_fast[i] = SENTINEL
    buf_ref[i]  = SENTINEL
  let pf = cast[ptr UncheckedArray[uint8]](addr buf_fast[0])
  let pr = cast[ptr UncheckedArray[uint8]](addr buf_ref[0])
  unpack_bg4_span(pf, OFS, row, x_in_tile, span, flip, bank)
  unpack_bg4_span_scalar(pr, OFS, row, x_in_tile, span, flip, bank)
  buf_fast == buf_ref

proc describe(row: uint32; x_in_tile, span, flip: int; bank: uint8): string =
  "row=" & toHex(row) & " x=" & $x_in_tile & " span=" & $span &
  " flip=" & $flip & " bank=" & toHex(bank, 2) &
  "\n    fast=" & $buf_fast & "\n    ref =" & $buf_ref

# --- 1.1 every reachable (x_in_tile, span) shape ------------------------------
# EXHAUSTIVE over shapes and over bank/flip; the rows are a fixed adversarial
# set plus PRNG. This is the test that says the fast path fires only where it is
# allowed to and that the fallback dispatch is not off by one.
proc test_shapes() =
  echo "every reachable (x_in_tile, span) shape, both flips, all 16 banks"
  reseed(0x9E3779B97F4A7C15'u64)
  var rows = @[0x00000000'u32, 0xFFFFFFFF'u32, 0x0F0F0F0F'u32, 0xF0F0F0F0'u32,
               0x01234567'u32, 0x89ABCDEF'u32, 0x11111111'u32, 0x88888888'u32]
  for _ in 0 ..< 120: rows.add nxt()
  var bad = ""
  var shapes = 0
  for x_in_tile in 0 .. 7:
    for span in 1 .. (8 - x_in_tile):
      inc shapes
      for flip in [0, 7]:
        for b in 0'u8 .. 15'u8:
          for row in rows:
            if not compare_span(row, x_in_tile, span, flip, b shl 4):
              if bad.len == 0: bad = describe(row, x_in_tile, span, flip, b shl 4)
  check(shapes == 36, "36 reachable shapes enumerated", "got " & $shapes)
  check(bad.len == 0, "all shapes agree with the scalar fallback", bad)

# --- contexts -----------------------------------------------------------------
# The "context" is what the OTHER nibbles hold while one nibble is swept. It is
# fixed rather than random because the interesting failures are carry-driven:
# 0xFFFFFFFF is the maximum-carry input for `v + 0x0F0F..`, 0x00000000 the
# minimum, and the alternating patterns put a maximal nibble next to a zero one
# in both phases.
const CONTEXTS: array[6, uint32] = [
  0x00000000'u32, 0xFFFFFFFF'u32, 0x0F0F0F0F'u32,
  0xF0F0F0F0'u32, 0x88888888'u32, 0x11111111'u32]

proc nib_mask(i: int): uint32 = 0xF'u32 shl (4 * i)

# --- 1.2 single-nibble sweep --------------------------------------------------
# EXHAUSTIVE over (nibble position 0..7) x (nibble value 0..15) x (bank 0..15)
# x (flip 0/7), against 14 contexts (the 6 fixed ones plus 8 PRNG words).
#
# This is the enumeration that pins the transparency rule: palette index 0 must
# NOT take the bank offset, in every bank, at every position, under both flips.
# n = 0 is a value in the sweep like any other, so a SWAR path that OR'd the
# bank in unconditionally fails 8 x 15 x 2 of these cases.
proc test_single_nibble() =
  echo "every nibble value at every position, all banks, both flips"
  reseed(0xBB67AE8584CAA73B'u64)
  var ctxs: seq[uint32] = @[]
  for c in CONTEXTS: ctxs.add c
  for _ in 0 ..< 8: ctxs.add nxt()
  var bad = ""
  var cases = 0
  for i in 0 .. 7:
    for n in 0'u32 .. 15'u32:
      for ctx in ctxs:
        let row = (ctx and not nib_mask(i)) or (n shl (4 * i))
        for flip in [0, 7]:
          for b in 0'u8 .. 15'u8:
            inc cases
            if not compare_span(row, 0, 8, flip, b shl 4):
              if bad.len == 0: bad = describe(row, 0, 8, flip, b shl 4)
  check(bad.len == 0, "all " & $cases & " single-nibble cases agree", bad)

# --- 1.3 adjacent-pair sweep --------------------------------------------------
# EXHAUSTIVE over (adjacency 0..6) x (all 256 pair values) x (bank) x (flip),
# against 6 contexts.
#
# This is the carry test, and it is the one that would fail if the SWAR
# arithmetic were wrong. Only two operations in the fast path can move
# information between byte lanes: `v + 0x0F0F0F0F0F0F0F0F` and `nz * bank`.
# Both are claimed carry-free — every byte of `v` is 0x00..0x0F so the sum is at
# most 0x1E, and `nz` is 0x00 or 0x10 per byte so the product is at most
# 0x10 * 15 = 0xF0. Carries out of a byte can only reach the byte immediately
# above it, so sweeping every adjacent pair exhaustively is what falsifies that
# claim if it is false.
proc test_adjacent_pairs() =
  echo "every adjacent nibble pair, all banks, both flips (carry propagation)"
  var bad = ""
  var cases = 0
  for i in 0 .. 6:
    for pair in 0'u32 .. 255'u32:
      let m = nib_mask(i) or nib_mask(i + 1)
      let v = pair shl (4 * i)
      for ctx in CONTEXTS:
        let row = (ctx and not m) or v
        for flip in [0, 7]:
          for b in 0'u8 .. 15'u8:
            inc cases
            if not compare_span(row, 0, 8, flip, b shl 4):
              if bad.len == 0: bad = describe(row, 0, 8, flip, b shl 4)
  check(bad.len == 0, "all " & $cases & " adjacent-pair cases agree", bad)

# --- 1.4 half-word sweep ------------------------------------------------------
# EXHAUSTIVE over all 65536 values of each 16-bit half (i.e. every combination
# of four consecutive nibbles) x 16 banks x 2 flips, with the other half held
# at three contexts. Four-nibble interactions are covered completely; only
# interactions that need SPECIFIC values in BOTH halves at once fall outside it,
# and part 3 closes that gap for anyone who wants it closed by machine rather
# than by the carry argument above.
proc test_halfword_sweep() =
  echo "all 65536 values of each 16-bit half, all banks, both flips"
  var bad = ""
  var cases = 0
  for high_half in [false, true]:
    for other in [0x0000'u32, 0xFFFF'u32, 0xA5A5'u32]:
      for h in 0'u32 .. 0xFFFF'u32:
        let row = if high_half: (h shl 16) or other else: h or (other shl 16)
        for flip in [0, 7]:
          for b in 0'u8 .. 15'u8:
            inc cases
            if not compare_span(row, 0, 8, flip, b shl 4):
              if bad.len == 0: bad = describe(row, 0, 8, flip, b shl 4)
  check(bad.len == 0, "all " & $cases & " half-word cases agree", bad)

# --- 1.5 whole-word fuzz — SAMPLED, not exhaustive ---------------------------
proc test_fuzz(iters: int) =
  echo "randomized whole-word differential fuzz (SAMPLED)"
  reseed(0x3C6EF372FE94F82B'u64)
  var bad = ""
  for _ in 0 ..< iters:
    let row  = nxt()
    let bank = uint8((nxt() and 0xF) shl 4)
    let flip = if (nxt() and 1) == 0: 0 else: 7
    let x    = int(nxt() and 7)
    let span = 1 + int(nxt() mod uint32(8 - x))
    if not compare_span(row, x, span, flip, bank):
      if bad.len == 0: bad = describe(row, x, span, flip, bank)
    # and the same row through the fast path proper
    if not compare_span(row, 0, 8, flip, bank):
      if bad.len == 0: bad = describe(row, 0, 8, flip, bank)
  check(bad.len == 0, $iters & " random (row, bank, flip, shape) draws agree", bad)

# =============================================================================
# PART 2 — the whole renderer: SWAR vs scalar vs an independent model
# =============================================================================
#
# Part 1 cannot see anything above the span unpacker. This part renders real
# scanlines with `render_reg_bg` (SWAR) and `render_reg_bg_scalar` (the same
# renderer with the fast path compiled out — a `static bool` instantiation, so
# it is the SAME source, not a copy), and also against `model_render_reg_bg`
# below, which is written from the register layout rather than from the
# renderer's span structure.
#
# It is what covers: tile_base >= 0x10000, 8bpp, horizontal mosaic, BG
# wraparound at the 256/512 boundary, and all four screen_size values.

proc model_render_reg_bg(ppu: PPU; bg: int; dst: var array[240, uint8]) =
  ## Independent per-pixel model. Deliberately written the naive way — one
  ## pixel at a time, no spans, no hoisting — from GBATEK's text-BG layout.
  let bgcnt = ppu.bgcnt[bg]
  let (bg_width, bg_height) = case bgcnt.screen_size
    of 0b00: (0x0FF, 0x0FF)
    of 0b01: (0x1FF, 0x0FF)
    of 0b10: (0x0FF, 0x1FF)
    else:    (0x1FF, 0x1FF)
  let screen_base    = 0x800 * int(bgcnt.screen_base_block)
  let character_base = 0x4000 * int(bgcnt.character_base_block)
  var vc = int(ppu.vcount)
  if bgcnt.mosaic:
    vc -= vc mod (int(ppu.mosaic.bg_mosiac_v_size) + 1)
  let row_y = (vc + int(ppu.bgvofs[bg].offset)) and bg_height
  for col in 0 .. 239:
    let ec = (col + int(ppu.bghofs[bg].offset)) and bg_width
    let tx = ec shr 3
    let ty = row_y shr 3
    var se = tx + ty * 32
    if tx >= 32: se += 0x03E0
    if ty >= 32 and bgcnt.screen_size == 0b11: se += 0x0400
    let a = screen_base + se * 2
    let entry = uint16(ppu.vram[a]) or (uint16(ppu.vram[a + 1]) shl 8)
    let tile_id = int(entry and 0x3FF)
    let px = (ec and 7) xor (if (entry and 0x0400) != 0: 7 else: 0)
    let py = (row_y and 7) xor (if (entry and 0x0800) != 0: 7 else: 0)
    if bgcnt.color_mode_8bpp:
      let base = character_base + tile_id * 0x40 + py * 8
      # The renderer tests the ROW base, not the byte address, so the model
      # must too or it would disagree on a row that straddles 0x10000. (Row
      # bases are 4-byte aligned, so nothing actually straddles it.)
      dst[col] = if base >= 0x10000: 0'u8 else: ppu.vram[base + px]
    else:
      let base = character_base + tile_id * 0x20 + py * 4
      if base >= 0x10000:
        dst[col] = 0
      else:
        let byt = ppu.vram[base + (px shr 1)]
        let p = if (px and 1) == 1: byt shr 4 else: byt and 0x0F
        dst[col] = if p != 0: p or uint8(int(entry shr 12) shl 4) else: 0'u8
  if bgcnt.mosaic:
    let h = int(ppu.mosaic.bg_mosiac_h_size) + 1
    if h > 1:
      for col in 0 .. 239:
        dst[col] = dst[col - col mod h]

proc make_emu(): GBA =
  let rom_path = getTempDir() / "dingbat_ppubgunpack_synthetic.gba"
  if not fileExists(rom_path):
    var rom = newString(0x8000)
    for i in 0 ..< rom.len: rom[i] = char((i * 7 + 13) and 0xFF)
    writeFile(rom_path, rom)
  result = new_gba("", rom_path, run_bios = false, use_hle = true)
  result.post_init()

# Coverage counters, so the claim about what part 2 exercised is measured
# rather than asserted.
type Coverage = object
  spans_whole, spans_partial: int
  flipped_tiles, transparent_tiles: int
  banks_seen: set[0 .. 15]
  screen_sizes_seen: set[0 .. 3]
  wrapped_lines: int

proc tally(ppu: PPU; bg: int; cov: var Coverage) =
  let bgcnt = ppu.bgcnt[bg]
  cov.screen_sizes_seen.incl int(bgcnt.screen_size)
  let bg_width = if bgcnt.screen_size in [0b01'u16, 0b11'u16]: 0x1FF else: 0x0FF
  let screen_base    = 0x800 * int(bgcnt.screen_base_block)
  let character_base = 0x4000 * int(bgcnt.character_base_block)
  var vc = int(ppu.vcount)
  if bgcnt.mosaic: vc -= vc mod (int(ppu.mosaic.bg_mosiac_v_size) + 1)
  let bg_height = if bgcnt.screen_size in [0b10'u16, 0b11'u16]: 0x1FF else: 0x0FF
  let row_y = (vc + int(ppu.bgvofs[bg].offset)) and bg_height
  var col = 0
  var wrapped = false
  var prev = -1
  while col < 240:
    let ec = (col + int(ppu.bghofs[bg].offset)) and bg_width
    if prev >= 0 and ec < prev: wrapped = true
    prev = ec
    let x_in_tile = ec and 7
    let span = min(8 - x_in_tile, 240 - col)
    if span == 8: inc cov.spans_whole else: inc cov.spans_partial
    let tx = ec shr 3
    let ty = row_y shr 3
    var se = tx + ty * 32
    if tx >= 32: se += 0x03E0
    if ty >= 32 and bgcnt.screen_size == 0b11: se += 0x0400
    let a = screen_base + se * 2
    let entry = uint16(ppu.vram[a]) or (uint16(ppu.vram[a + 1]) shl 8)
    if (entry and 0x0400) != 0: inc cov.flipped_tiles
    cov.banks_seen.incl int(entry shr 12)
    let py = (row_y and 7) xor (if (entry and 0x0800) != 0: 7 else: 0)
    let stride = if bgcnt.color_mode_8bpp: 0x40 else: 0x20
    let rowsz  = if bgcnt.color_mode_8bpp: 8 else: 4
    if character_base + int(entry and 0x3FF) * stride + py * rowsz >= 0x10000:
      inc cov.transparent_tiles
    col += span
  if wrapped: inc cov.wrapped_lines

proc render_three_ways(emu: GBA; bg: int; cov: var Coverage;
                       mismatch_fast, mismatch_model: var string) =
  let ppu = emu.ppu
  var model: array[240, uint8]
  model_render_reg_bg(ppu, bg, model)
  tally(ppu, bg, cov)
  # Canary in the NEXT bg's line buffer: layer_palettes rows are adjacent, so a
  # whole-tile store that ran one span too far would land here.
  const CANARY = 0x5A'u8
  if bg < 3:
    for i in 0 ..< 16: ppu.layer_palettes[bg + 1][i] = CANARY
  for i in 0 ..< 240: ppu.layer_palettes[bg][i] = 0xE7
  ppu.render_reg_bg(bg)
  let fast = ppu.layer_palettes[bg]
  var canary_ok = true
  if bg < 3:
    for i in 0 ..< 16:
      if ppu.layer_palettes[bg + 1][i] != CANARY: canary_ok = false
  for i in 0 ..< 240: ppu.layer_palettes[bg][i] = 0xE7
  ppu.render_reg_bg_scalar(bg)
  let slow = ppu.layer_palettes[bg]

  proc ctx(): string =
    let b = ppu.bgcnt[bg]
    " bg=" & $bg & " size=" & $b.screen_size & " 8bpp=" & $b.color_mode_8bpp &
    " cbb=" & $b.character_base_block & " sbb=" & $b.screen_base_block &
    " mosaic=" & $b.mosaic & " hofs=" & $ppu.bghofs[bg].offset &
    " vofs=" & $ppu.bgvofs[bg].offset & " vcount=" & $ppu.vcount

  if fast != slow and mismatch_fast.len == 0:
    for i in 0 ..< 240:
      if fast[i] != slow[i]:
        mismatch_fast = ctx() & " col=" & $i & " fast=" & toHex(fast[i], 2) &
                        " scalar=" & toHex(slow[i], 2)
        break
  if not canary_ok and mismatch_fast.len == 0:
    mismatch_fast = ctx() & " — the SWAR store overran into the next BG's buffer"
  if slow != model and mismatch_model.len == 0:
    for i in 0 ..< 240:
      if slow[i] != model[i]:
        mismatch_model = ctx() & " col=" & $i & " renderer=" & toHex(slow[i], 2) &
                         " model=" & toHex(model[i], 2)
        break

proc seed_vram(ppu: PPU) =
  for i in 0 ..< ppu.vram.len: ppu.vram[i] = uint8(nxt())

proc test_renderer(emu: GBA) =
  echo "render_reg_bg (SWAR) == render_reg_bg_scalar == independent model"
  let ppu = emu.ppu
  ppu[0x000] = 0        # mode 0
  ppu[0x001] = 0x0F     # BG0-3 enabled
  var cov = Coverage()
  var bad_fast, bad_model = ""
  reseed(0x510E527FADE682D1'u64)
  seed_vram(ppu)

  # EXHAUSTIVE over screen_size x colour depth x character_base_block x every
  # BGHOFS value 0..511. BGHOFS is swept whole because it is what selects
  # x_in_tile for the leading partial span AND where the 256/512 wrap lands
  # inside the line; 0..511 covers both wrap boundaries from both sides and
  # every one of the eight tile alignments.
  #
  # character_base_block is swept because block 3 (0xC000) plus a high tile_id
  # pushes tile_base past 0x10000 — that is how the "BG cannot fetch from OBJ
  # VRAM, render transparent" path gets exercised, in both depths.
  for size in 0'u16 .. 3'u16:
    for eight in [false, true]:
      for cbb in 0'u16 .. 3'u16:
        for hofs in 0'u16 .. 511'u16:
          let bg = int(nxt() and 3)
          var b = BGCNT()
          b.screen_size = size
          b.color_mode_8bpp = eight
          b.character_base_block = cbb
          b.screen_base_block = uint16(nxt() mod 16)
          b.mosaic = false
          ppu.bgcnt[bg] = b
          ppu.bghofs[bg] = cast[BGOFS](hofs)
          ppu.bgvofs[bg] = cast[BGOFS](uint16(nxt() and 0x1FF))
          ppu.vcount = uint16(nxt() mod 160)
          render_three_ways(emu, bg, cov, bad_fast, bad_model)

  # Mosaic. The horizontal mosaic pass runs AFTER the span loop and rewrites the
  # line from its own output, so it can only be broken by the fast path writing
  # the wrong bytes — but it is the interaction the change is most likely to be
  # accused of, so it is swept: all 16 horizontal sizes x all 16 vertical sizes
  # (EXHAUSTIVE over the MOSAIC register's BG fields), both depths.
  for h in 0'u16 .. 15'u16:
    for v in 0'u16 .. 15'u16:
      for eight in [false, true]:
        let bg = int(nxt() and 3)
        var b = BGCNT()
        b.screen_size = uint16(nxt() and 3)
        b.color_mode_8bpp = eight
        b.character_base_block = uint16(nxt() and 3)
        b.screen_base_block = uint16(nxt() mod 16)
        b.mosaic = true
        ppu.bgcnt[bg] = b
        var m = MOSAIC()
        m.bg_mosiac_h_size = h
        m.bg_mosiac_v_size = v
        ppu.mosaic = m
        ppu.bghofs[bg] = cast[BGOFS](uint16(nxt() and 0x1FF))
        ppu.bgvofs[bg] = cast[BGOFS](uint16(nxt() and 0x1FF))
        ppu.vcount = uint16(nxt() mod 160)
        render_three_ways(emu, bg, cov, bad_fast, bad_model)
  ppu.mosaic = MOSAIC()

  # And a broad random sweep on top, re-seeding VRAM so the tile maps and
  # character data are not the single fill used above. SAMPLED.
  for iter in 0 ..< 3000:
    if (iter mod 250) == 0: seed_vram(ppu)
    let bg = int(nxt() and 3)
    var b = cast[BGCNT](uint16(nxt()))
    b.character_base_block = uint16(nxt() and 3)
    b.screen_base_block = uint16(nxt() mod 16)
    ppu.bgcnt[bg] = b
    var m = MOSAIC()
    m.bg_mosiac_h_size = uint16(nxt() and 0xF)
    m.bg_mosiac_v_size = uint16(nxt() and 0xF)
    ppu.mosaic = m
    ppu.bghofs[bg] = cast[BGOFS](uint16(nxt() and 0x1FF))
    ppu.bgvofs[bg] = cast[BGOFS](uint16(nxt() and 0x1FF))
    ppu.vcount = uint16(nxt() mod 160)
    render_three_ways(emu, bg, cov, bad_fast, bad_model)
  ppu.mosaic = MOSAIC()

  check(bad_fast.len == 0, "SWAR renderer == scalar renderer, every line", bad_fast)
  check(bad_model.len == 0, "renderer == independent per-pixel model", bad_model)

  # The coverage claim, measured. A sweep that never hit a flipped tile or never
  # took the transparent path would pass vacuously, so assert it did not.
  echo "  coverage: whole spans=", cov.spans_whole, " partial spans=",
       cov.spans_partial, " flipped tiles=", cov.flipped_tiles,
       " transparent tiles=", cov.transparent_tiles,
       " wrapped lines=", cov.wrapped_lines,
       " banks=", card(cov.banks_seen), "/16 sizes=", card(cov.screen_sizes_seen), "/4"
  check(cov.spans_whole > 0 and cov.spans_partial > 0,
        "both whole and partial spans were exercised")
  check(cov.flipped_tiles > 0, "horizontally flipped tiles were exercised")
  check(cov.transparent_tiles > 0,
        "the tile_base >= 0x10000 transparent path was exercised")
  check(cov.wrapped_lines > 0,
        "lines that wrap at the 256/512 BG boundary were exercised")
  check(card(cov.banks_seen) == 16, "all 16 palette banks were exercised")
  check(card(cov.screen_sizes_seen) == 4, "all four screen_size values were exercised")

# --- 8bpp is untouched --------------------------------------------------------
# The 8bpp branch of render_reg_bg is not modified by this change, so the
# SWAR-vs-scalar diff above is necessarily vacuous for it — the two
# instantiations share that source. What is NOT vacuous is 8bpp against the
# independent model, which is what this asserts separately so a regression there
# cannot hide inside the combined counters above.
proc test_8bpp_unchanged(emu: GBA) =
  echo "8bpp output is unchanged (checked against the independent model)"
  let ppu = emu.ppu
  ppu[0x000] = 0
  ppu[0x001] = 0x0F
  reseed(0x1F83D9ABFB41BD6B'u64)
  seed_vram(ppu)
  var cov = Coverage()
  var bad_fast, bad_model = ""
  var lines = 0
  for size in 0'u16 .. 3'u16:
    for cbb in 0'u16 .. 3'u16:
      for hofs in 0'u16 .. 511'u16:
        let bg = int(nxt() and 3)
        var b = BGCNT()
        b.screen_size = size
        b.color_mode_8bpp = true
        b.character_base_block = cbb
        b.screen_base_block = uint16(nxt() mod 16)
        ppu.bgcnt[bg] = b
        ppu.bghofs[bg] = cast[BGOFS](hofs)
        ppu.bgvofs[bg] = cast[BGOFS](uint16(nxt() and 0x1FF))
        ppu.vcount = uint16(nxt() mod 160)
        render_three_ways(emu, bg, cov, bad_fast, bad_model)
        inc lines
  check(bad_fast.len == 0, "8bpp: SWAR build == scalar build", bad_fast)
  check(bad_model.len == 0, "8bpp: renderer == independent model over " &
        $lines & " lines", bad_model)
  check(cov.transparent_tiles > 0, "8bpp: the transparent path was exercised")

# =============================================================================
# PART 3 — the full 2^32 sweep, opt-in
# =============================================================================
#
# DINGBAT_BG4_EXHAUSTIVE=1 sweeps EVERY 32-bit tile row against EVERY palette
# bank and both flips: 2^32 x 16 x 2 = 1.37e11 comparisons. That is the entire
# reachable input space of the fast path with nothing sampled and no appeal to
# the carry argument. It takes roughly 20 minutes single-threaded on an M2 at
# -d:danger, which is why it is not in CI.
#
# DINGBAT_BG4_SHARDS=n / DINGBAT_BG4_SHARD=i split the row space into n
# contiguous ranges so it can be run across cores.
proc test_exhaustive() =
  let shards = parseInt(getEnv("DINGBAT_BG4_SHARDS", "1"))
  let shard  = parseInt(getEnv("DINGBAT_BG4_SHARD", "0"))
  let total  = 0x1_0000_0000'u64
  let lo = total * uint64(shard) div uint64(shards)
  let hi = total * uint64(shard + 1) div uint64(shards)
  echo "EXHAUSTIVE 2^32 x 16 banks x 2 flips, shard ", shard, "/", shards,
       " rows [", toHex(lo, 9), ", ", toHex(hi, 9), ")"
  var bad = ""
  var r = lo
  while r < hi:
    let row = uint32(r)
    for flip in [0, 7]:
      for b in 0'u8 .. 15'u8:
        if not compare_span(row, 0, 8, flip, b shl 4):
          if bad.len == 0:
            bad = describe(row, 0, 8, flip, b shl 4)
            echo "  MISMATCH: ", bad
            failures.inc
            return
    if (r and 0x0FFFFFFF'u64) == 0:
      echo "    ... ", toHex(r, 9)
    inc r
  check(bad.len == 0, "every 32-bit tile row x every bank x both flips agrees")

when isMainModule:
  if getEnv("DINGBAT_BG4_EXHAUSTIVE") == "1":
    test_exhaustive()
  else:
    test_shapes()
    test_single_nibble()
    test_adjacent_pairs()
    test_halfword_sweep()
    test_fuzz(if getEnv("DINGBAT_BG4_FUZZ").len > 0:
                parseInt(getEnv("DINGBAT_BG4_FUZZ")) else: 20_000_000)
    let emu = make_emu()
    test_renderer(emu)
    test_8bpp_unchanged(emu)
  echo ""
  if failures == 0:
    echo "ppubgunpack: all checks passed"
  else:
    echo "ppubgunpack: ", failures, " check(s) FAILED"
    quit(1)
