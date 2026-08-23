# PPU implementation (included by gba.nim)

const SPRITE_PIXEL_DEFAULT* = SpritePixel(priority: 4, palette: 0, blends: false, window: false)

# Flag bit OR'd into a layer-walk index to record that the OBJ layer has
# already been consumed, so resuming the walk for a blend bottom skips it.
const SPRITE_TAKEN = 0x40

# SIZES[shape][size] = (width, height)
const SIZES*: array[3, array[4, array[2, int]]] = [
  [[8,8],   [16,16], [32,32], [64,64]],  # square
  [[16,8],  [32,8],  [32,16], [64,32]],  # horizontal rectangle
  [[8,16],  [8,32],  [16,32], [32,64]],  # vertical rectangle
]

proc new_ppu*(gba: GBA): PPU =
  result = PPU(gba: gba)
  result.framebuffer    = newSeq[uint16](0x9600)
  result.frame          = 0
  result.pram           = newSeq[byte](0x400)
  result.vram           = newSeq[byte](0x18000)
  result.oam            = newSeq[byte](0x400)
  result.obj_list_dirty = true  # nothing has built the per-line OBJ list yet
  result.dispcnt        = DISPCNT()
  result.dispstat       = DISPSTAT()
  result.vcount         = 0
  for i in 0..3:
    result.bgcnt[i]  = BGCNT()
    result.bghofs[i] = BGOFS()
    result.bgvofs[i] = BGOFS()
  for i in 0..1:
    # PA/PD reset to 1.0 (0x100), the identity transform; Doom relies on it
    # in mode 4 without writing the affine registers. Assumed; no ROM pins
    # this.
    result.bgaff[i][0] = cast[BGAFF](0x100'u16)
    result.bgaff[i][1] = BGAFF()
    result.bgaff[i][2] = BGAFF()
    result.bgaff[i][3] = cast[BGAFF](0x100'u16)
    result.bgref[i][0] = BGREF()
    result.bgref[i][1] = BGREF()
    result.bgref_int[i][0] = 0
    result.bgref_int[i][1] = 0
  result.win0h   = WINH()
  result.win1h   = WINH()
  result.win0v   = WINV()
  result.win1v   = WINV()
  result.winin   = WININ()
  result.winout  = WINOUT()
  result.mosaic  = MOSAIC()
  result.bldcnt  = BLDCNT()
  result.bldalpha = BLDALPHA()
  result.bldy    = BLDY()
  for i in 0..239:
    result.sprite_pixels[i] = SPRITE_PIXEL_DEFAULT
  result.render_dirty = true
  result.debug_layer_mask = 0x1F
  result.start_line()

proc bitmap*(ppu: PPU): bool =
  ppu.dispcnt.bg_mode >= 3

proc start_line*(ppu: PPU) =
  ppu.gba.scheduler.schedule(960, etPPUStartHBlank)

# GBATEK: "the H-Blank flag is '0' for a total of 1006 cycles", so the flag
# (and the IRQ it enables) rises 46 cycles after drawing ends at 960.
const HBLANK_FLAG_DELAY = 46

# Cycles from the H-blank signal to IRQ recognition; longer than the timers'
# IRQ_SYNC_DELAY (3). Pinned by mGBA suite "H-blank bit start / Flip 1",
# which admits recognition at 1010..1014; 1012 is the middle.
const HBLANK_IRQ_SYNC_DELAY = 6

proc start_hblank*(ppu: PPU) =
  ppu.gba.scheduler.schedule(272, etPPUEndHBlank)
  ppu.gba.scheduler.schedule(HBLANK_FLAG_DELAY, etPPUSetHBlankFlag)
  if ppu.vcount < 160:
    ppu.scanline()
    for bg_num in 0..1:
      ppu.bgref_int[bg_num][0] += ppu.bgaff[bg_num][1].num  # bgx += dmx
      ppu.bgref_int[bg_num][1] += ppu.bgaff[bg_num][3].num  # bgy += dmy
    ppu.gba.dma.trigger_hdma()

proc set_hblank_flag*(ppu: PPU) =
  ppu.dispstat.hblank = true
  # Flag and IRQ are the same signal (bit 4 enables an interrupt on the bit-1
  # condition), so they rise together (mGBA suite Flip 1).
  if ppu.dispstat.hblank_irq_enable:
    ppu.gba.interrupts.reg_if.hblank = true
    ppu.gba.interrupts.schedule_interrupt_check(HBLANK_IRQ_SYNC_DELAY)

proc end_hblank*(ppu: PPU) =
  # Zero-delay event rather than a direct call: schedule's tie-break (newest
  # same-cycle event pops first) makes it the next dispatch, after the
  # post-dispatch DMA pump has granted the vblank / video-capture requests
  # latched below, so the next line anchors at the same cycle but strictly
  # after this line's deferred DMA work.
  ppu.gba.scheduler.schedule(0, etPPUStartLine)
  ppu.dispstat.hblank = false
  ppu.vcount = uint16((int(ppu.vcount) + 1) mod 228)
  ppu.gba.dma.trigger_video_capture(ppu.vcount)
  ppu.dispstat.vcounter = (ppu.vcount == uint16(ppu.dispstat.vcount_setting))
  var raised_if = false
  if ppu.dispstat.vcounter_irq_enable and ppu.dispstat.vcounter:
    ppu.gba.interrupts.reg_if.vcounter = true
    raised_if = true
  if ppu.vcount == 227:
    ppu.dispstat.vblank = false
  elif ppu.vcount == 160:
    ppu.dispstat.vblank = true
    ppu.gba.dma.trigger_vdma()
    if ppu.dispstat.vblank_irq_enable:
      ppu.gba.interrupts.reg_if.vblank = true
      raised_if = true
    for bg_num in 0..1:
      for ref_num in 0..1:
        ppu.bgref_int[bg_num][ref_num] = ppu.bgref[bg_num][ref_num].num
    ppu.draw()
  # Only a flag that rose here reaches the interrupt controller: an
  # unconditional check would re-evaluate all of IE&IF at rise+1 for a bit
  # another peripheral raised inside its own IRQ_SYNC_DELAY window (GBATEK:
  # IF bits 0-2 are driven by the DISPSTAT conditions; nothing re-evaluates
  # periodically). mGBA suite Timer count-up "0b, 0x000C 1xv 1d 4i".
  if raised_if:
    ppu.gba.interrupts.schedule_interrupt_check(IRQ_SYNC_DELAY)

proc draw*(ppu: PPU) =
  inc ppu.frame
  # True only when every scanline was skipped (framebuffer unchanged), so
  # frontends can skip the texture upload
  ppu.frame_static = ppu.skip_render or ppu.forced_skip

proc se_address*(ppu: PPU; tx, ty, screen_size: int): int {.inline.} =
  var n = tx + ty * 32
  if tx >= 32: n += 0x03E0
  if ty >= 32 and screen_size == 0b11: n += 0x0400
  n

# BGR16 procs (types declared in gba.nim)
proc bgr16_blue*(v: uint16):  uint16 = bits_range(v, 0xA, 0xE)
proc bgr16_green*(v: uint16): uint16 = bits_range(v, 0x5, 0x9)
proc bgr16_red*(v: uint16):   uint16 = bits_range(v, 0x0, 0x4)

proc new_bgr16*(blue, green, red: int): uint16 =
  let b: uint16 = if blue  <= 0x1F: uint16(blue)  else: 0x1F'u16
  let g: uint16 = if green <= 0x1F: uint16(green) else: 0x1F'u16
  let r: uint16 = if red   <= 0x1F: uint16(red)   else: 0x1F'u16
  (b shl 10) or (g shl 5) or r

proc bgr16_add*(a, b: uint16): uint16 =
  new_bgr16(int(bgr16_blue(a))  + int(bgr16_blue(b)),
            int(bgr16_green(a)) + int(bgr16_green(b)),
            int(bgr16_red(a))   + int(bgr16_red(b)))

proc bgr16_sub*(a, b: uint16): uint16 =
  new_bgr16(int(bgr16_blue(a))  - int(bgr16_blue(b)),
            int(bgr16_green(a)) - int(bgr16_green(b)),
            int(bgr16_red(a))   - int(bgr16_red(b)))

proc bgr16_mul*(a: uint16; coeff: int): uint16 =
  ## Multiply each channel by coeff/16 using integer math. coeff is 0..16.
  new_bgr16((int(bgr16_blue(a))  * coeff) shr 4,
            (int(bgr16_green(a)) * coeff) shr 4,
            (int(bgr16_red(a))   * coeff) shr 4)

proc sprites_ptr*(ppu: PPU): ptr UncheckedArray[Sprite] =
  cast[ptr UncheckedArray[Sprite]](addr ppu.oam[0])

# 4bpp tile-row unpacking. `unpack_bg4_span_scalar` is the per-pixel form and
# the real path for partial spans (the line edges); `unpack_bg4_span` adds a
# SWAR whole-tile case for the aligned 8-pixel span. Both are exported so
# tests/ppubgunpack_test.nim can compare them over the whole input space.
# Domain (enforced by the caller): x_in_tile in 0..7, 1 <= span <= 8 -
# x_in_tile, flip_x_mask 0 or 7, bank already shifted into the high nibble.
# A wider span would shift `row` by more than 28 and read outside the row.
proc unpack_bg4_span_scalar*(dst: ptr UncheckedArray[uint8]; col: int;
                             row: uint32; x_in_tile, span, flip_x_mask: int;
                             bank: uint8) {.inline.} =
  for k in 0 ..< span:
    let x = (x_in_tile + k) xor flip_x_mask
    let p = uint8((row shr (uint32(x) * 4)) and 0xF)
    # Palette index 0 is transparent in every bank: no bank offset
    dst[col + k] = p or (if p != 0: bank else: 0'u8)

proc unpack_bg4_span*(dst: ptr UncheckedArray[uint8]; col: int; row: uint32;
                      x_in_tile, span, flip_x_mask: int; bank: uint8) {.inline.} =
  ## Whole-tile SWAR expansion, falling back to the scalar loop otherwise.
  ## The three `((v shl s) or v) and M` steps scatter the eight nibbles of
  ## `row` into eight bytes, low nibble to low byte; each step is shl/or/and
  ## only, so it is OR-linear and carry-free (a permutation of 32 bits).
  ## Flip is then a byte reverse. The bank is OR'd in without touching index
  ## 0: `v + 0x0F0F..` cannot carry between bytes (each is <= 0x0F) and the
  ## 0xF0F0.. mask leaves 0x10 per non-zero byte; times the bank nibble that
  ## is at most 0xF0, so no carry there either.
  const little = cpuEndian == littleEndian
  if little and x_in_tile == 0 and span == 8:
    var v = uint64(row)
    v = ((v shl 16) or v) and 0x0000FFFF0000FFFF'u64
    v = ((v shl 8)  or v) and 0x00FF00FF00FF00FF'u64
    v = ((v shl 4)  or v) and 0x0F0F0F0F0F0F0F0F'u64
    if flip_x_mask != 0:
      # bswap64 written out: Nim has no portable byte-swap intrinsic (clang
      # folds it to a nibble-aware swap; wasm has no byte-swap anyway)
      v = ((v and 0x00FF00FF00FF00FF'u64) shl 8) or
          ((v shr 8) and 0x00FF00FF00FF00FF'u64)
      v = ((v and 0x0000FFFF0000FFFF'u64) shl 16) or
          ((v shr 16) and 0x0000FFFF0000FFFF'u64)
      v = (v shl 32) or (v shr 32)
    let nz = (v + 0x0F0F0F0F0F0F0F0F'u64) and 0xF0F0F0F0F0F0F0F0'u64
    v = v or (nz * (uint64(bank) shr 4))
    # copyMem, not a ptr-uint64 store: `col` is only 8-aligned when BGHOFS
    # is, so this store is frequently unaligned
    copyMem(addr dst[col], addr v, 8)
  else:
    unpack_bg4_span_scalar(dst, col, row, x_in_tile, span, flip_x_mask, bank)

proc render_reg_bg_impl(ppu: PPU; bg: int; swar: static bool) =
  if not bit(uint16(ppu.dispcnt), 8 + bg): return
  let bgcnt  = ppu.bgcnt[bg]
  let bghofs = ppu.bghofs[bg]
  let bgvofs = ppu.bgvofs[bg]
  let (bg_width, bg_height) = case bgcnt.screen_size
    of 0b00: (0x0FF, 0x0FF)
    of 0b01: (0x1FF, 0x0FF)
    of 0b10: (0x0FF, 0x1FF)
    of 0b11: (0x1FF, 0x1FF)
    else: raise newException(Exception, "Impossible bgcnt screen size: " & $bgcnt.screen_size)
  let screen_base     = 0x800'u32 * uint32(bgcnt.screen_base_block)
  let character_base  = 0x4000'u32 * uint32(bgcnt.character_base_block)
  var vc = uint32(ppu.vcount)
  if bgcnt.mosaic:
    vc -= vc mod (uint32(ppu.mosaic.bg_mosiac_v_size) + 1)
  let effective_row   = (vc + uint32(bgvofs.offset)) and uint32(bg_height)
  let tile_y          = effective_row shr 3
  let is_8bpp         = bgcnt.color_mode_8bpp
  # Precompute tile_y contribution to se_address
  let ty_base         = int(tile_y) * 32
  let ty_extra        = if int(tile_y) >= 32 and bgcnt.screen_size == 0b11: 0x0400 else: 0
  let row_in_tile     = effective_row and 7
  # Walk the scanline one tile span at a time: a span never crosses a tile
  # boundary (and never wraps, since bg_width+1 is a multiple of 8), so the
  # screen entry, tile row base, flip mask and palette bank are computed once
  # per tile.
  let dst = cast[ptr UncheckedArray[uint8]](addr ppu.layer_palettes[bg][0])
  let vram = cast[ptr UncheckedArray[uint8]](addr ppu.vram[0])
  var col = 0
  while col < 240:
    let effective_col = (uint32(col) + uint32(bghofs.offset)) and uint32(bg_width)
    let tile_x        = effective_col shr 3
    let x_in_tile     = int(effective_col and 7)
    let span          = min(8 - x_in_tile, 240 - col)
    let se_idx = ty_base + int(tile_x) + (if int(tile_x) >= 32: 0x03E0 else: 0) + ty_extra
    let screen_entry = uint16(vram[screen_base + uint32(se_idx) * 2 + 1]) shl 8 or
                       uint16(vram[screen_base + uint32(se_idx) * 2])
    let tile_id     = bits_range(screen_entry, 0, 9)
    let flip_x_mask = 7 * int(screen_entry shr 10 and 1)
    let y           = int(row_in_tile) xor (7 * int(screen_entry shr 11 and 1))
    if is_8bpp:
      let tile_base = character_base + uint32(tile_id) * 0x40 + uint32(y) * 8
      # The BG unit can't fetch character data from OBJ VRAM; such tiles
      # render transparent
      if tile_base >= 0x10000'u32:
        for k in 0 ..< span: dst[col + k] = 0
      else:
        for k in 0 ..< span:
          dst[col + k] = vram[tile_base + uint32((x_in_tile + k) xor flip_x_mask)]
    else:
      let tile_base = character_base + uint32(tile_id) * 0x20 + uint32(y) * 4
      let bank = uint8(bits_range(screen_entry, 12, 15) shl 4)
      if tile_base >= 0x10000'u32:
        for k in 0 ..< span: dst[col + k] = 0
      else:
        # A 4bpp tile row is 4 bytes = 8 nibbles and tile_base is 4-byte
        # aligned, so pull the row as one word (see unpack_bg4_span)
        let row = cast[ptr uint32](addr vram[tile_base])[]
        when swar:
          unpack_bg4_span(dst, col, row, x_in_tile, span, flip_x_mask, bank)
        else:
          unpack_bg4_span_scalar(dst, col, row, x_in_tile, span, flip_x_mask, bank)
    col += span
  if bgcnt.mosaic:
    let h = int(ppu.mosaic.bg_mosiac_h_size) + 1
    if h > 1:
      for col in 0..239:
        ppu.layer_palettes[bg][col] = ppu.layer_palettes[bg][col - col mod h]

proc render_reg_bg*(ppu: PPU; bg: int) {.inline.} =
  render_reg_bg_impl(ppu, bg, true)

when defined(test_harness):
  proc render_reg_bg_scalar*(ppu: PPU; bg: int) =
    ## The renderer with the SWAR case compiled out, for
    ## tests/ppubgunpack_test.nim. Only under -d:test_harness.
    render_reg_bg_impl(ppu, bg, false)

proc render_aff_bg*(ppu: PPU; bg: int) =
  if not bit(uint16(ppu.dispcnt), 8 + bg): return
  let bgcnt = ppu.bgcnt[bg]
  let bg_idx = bg - 2
  let dx = ppu.bgaff[bg_idx][0].num
  let dy = ppu.bgaff[bg_idx][2].num
  var int_x = ppu.bgref_int[bg_idx][0]
  var int_y = ppu.bgref_int[bg_idx][1]
  if bgcnt.mosaic:
    # Vertical mosaic: reuse the internal coordinates latched on the first
    # line of the mosaic block
    let v = uint16(ppu.mosaic.bg_mosiac_v_size) + 1
    if ppu.vcount mod v == 0:
      ppu.mosaic_bgref_int[bg_idx] = [int_x, int_y]
    else:
      int_x = ppu.mosaic_bgref_int[bg_idx][0]
      int_y = ppu.mosaic_bgref_int[bg_idx][1]
  let size_tiles  = 16 shl bgcnt.screen_size
  let size_pixels = size_tiles shl 3
  let screen_base    = 0x800'u32 * uint32(bgcnt.screen_base_block)
  let character_base = 0x4000'u32 * uint32(bgcnt.character_base_block)
  for col in 0..239:
    var px = int_x shr 8
    var py = int_y shr 8
    int_x += dx
    int_y += dy
    if bgcnt.affine_wrap:
      let sp = int32(size_pixels)
      px = ((px mod sp) + sp) mod sp
      py = ((py mod sp) + sp) mod sp
    if not (px >= 0 and px < size_pixels and py >= 0 and py < size_pixels):
      continue
    let tile_id = ppu.vram[screen_base + uint32(py shr 3) * uint32(size_tiles) + uint32(px shr 3)]
    let pal_idx = ppu.vram[character_base + 0x40'u32 * uint32(tile_id) + uint32(8 * (py and 7)) + uint32(px and 7)]
    ppu.layer_palettes[bg][col] = pal_idx
  if bgcnt.mosaic:
    let h = int(ppu.mosaic.bg_mosiac_h_size) + 1
    if h > 1:
      for col in 0..239:
        ppu.layer_palettes[bg][col] = ppu.layer_palettes[bg][col - col mod h]

proc render_bitmap*(ppu: PPU) =
  ## Fill the BG2 line buffers for the bitmap modes (3/4/5). Modes 3/5 are
  ## direct BGR555; mode 4 is paletted. BG2 is an affine layer here: PA/PC
  ## and the internal reference point apply as in modes 1/2, sampling the
  ## bitmap as a texture (out of range = transparent; the wrap bit has no
  ## effect). DBZ Legacy of Goku's intro FMV upscales with PD < 1.0.
  let mode = int(ppu.dispcnt.bg_mode)
  ppu.bitmap_direct = mode != 4
  for col in 0..239: ppu.bg2_direct_opaque[col] = false
  if not bit(uint16(ppu.dispcnt), 10): return  # BG2 disabled
  let dx = ppu.bgaff[0][0].num
  let dy = ppu.bgaff[0][2].num
  var int_x = ppu.bgref_int[0][0]
  var int_y = ppu.bgref_int[0][1]
  if ppu.bgcnt[2].mosaic:
    # Vertical mosaic: same scheme as render_aff_bg
    let v = uint16(ppu.mosaic.bg_mosiac_v_size) + 1
    if ppu.vcount mod v == 0:
      ppu.mosaic_bgref_int[0] = [int_x, int_y]
    else:
      int_x = ppu.mosaic_bgref_int[0][0]
      int_y = ppu.mosaic_bgref_int[0][1]
  let (width, height) = if mode == 5: (160'i32, 128'i32) else: (240'i32, 160'i32)
  let base: uint32 =
    if mode != 3 and ppu.dispcnt.display_frame_select: 0xA000'u32 else: 0
  case mode
  of 3, 5:
    let vram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.vram[base])
    for col in 0..239:
      let px = int_x shr 8
      let py = int_y shr 8
      int_x += dx
      int_y += dy
      if px >= 0 and px < width and py >= 0 and py < height:
        ppu.bg2_direct[col] = vram_u16[uint32(py) * uint32(width) + uint32(px)]
        ppu.bg2_direct_opaque[col] = true
  of 4:
    for col in 0..239:
      let px = int_x shr 8
      let py = int_y shr 8
      int_x += dx
      int_y += dy
      if px >= 0 and px < width and py >= 0 and py < height:
        ppu.layer_palettes[2][col] = ppu.vram[base + uint32(py) * 240 + uint32(px)]
  else: discard
  if ppu.bgcnt[2].mosaic:
    let h = int(ppu.mosaic.bg_mosiac_h_size) + 1
    if h > 1:
      for col in 0..239:
        let src = col - col mod h
        if mode == 4:
          ppu.layer_palettes[2][col] = ppu.layer_palettes[2][src]
        else:
          ppu.bg2_direct[col] = ppu.bg2_direct[src]
          ppu.bg2_direct_opaque[col] = ppu.bg2_direct_opaque[src]

# Past this many OBJ-list rebuilds in one frame the rest of the frame uses
# the straight 128-entry scan: a guard for a game that rewrites OAM every
# H-blank. A rebuild costs about one line-scan, so the limit is generous.
const OBJ_LIST_REBUILD_LIMIT* = 16

type ObjGeometry = tuple[x, y, ow, oh, w, h: int]

proc obj_geometry(s: Sprite): ObjGeometry {.inline.} =
  ## Screen-space geometry of one OAM entry, shared by the per-line scan and
  ## the candidate-list rebuild so the two cannot drift apart. `x`/`y` are
  ## the signed top-left corner: OBJ X (9 bits) and Y (8 bits) wrap negative
  ## past the screen, so a sprite at Y=250 hangs off the top. This differs
  ## from a true mod-256 wrap only for a 64-tall double-size sprite at Y in
  ## 129..159; assumed, no ROM pins it. `ow`/`oh` are the texture footprint,
  ## `w`/`h` the drawn one (double for affine double-size, so the candidate
  ## test must use `h`). attr0.9 means double-size only with affine set;
  ## otherwise it disables the sprite. Prohibited shape 3 has no footprint.
  let shape3 = s.obj_shape == 3
  var x = int(cast[int16](bits_range(s.attr1, 0, 8)))
  var y = int(cast[int16](bits_range(s.attr0, 0, 7)))
  if x > 239: x -= 512
  if y > 159: y -= 256
  let ow = if shape3: 0 else: SIZES[s.obj_shape][s.obj_size][0]
  let oh = if shape3: 0 else: SIZES[s.obj_shape][s.obj_size][1]
  var w = ow
  var h = oh
  if bit(s.attr0, 8) and bit(s.attr0, 9):  # affine + double-size
    w = w shl 1
    h = h shl 1
  (x, y, ow, oh, w, h)

proc rebuild_obj_lines*(ppu: PPU) =
  ## Rebuild the 160-line candidate bitmap from OAM. An entry is a candidate
  ## for line L exactly when render_sprites' reject tests would pass it; the
  ## list changes only which entries are looked at, never what happens to one.
  zeroMem(addr ppu.obj_line_mask[0][0], sizeof(ppu.obj_line_mask))
  let sprites = ppu.sprites_ptr()
  for s_idx in 0 ..< 128:
    let sprite = sprites[s_idx]
    if sprite.affine_mode == 0b10: continue  # rot/scale off + double-size = disabled
    let g = obj_geometry(sprite)
    if g.x + g.w < 0: continue               # fully off the left edge
    let lo = max(0, g.y)
    let hi = min(160, g.y + g.h)             # h = 0 for shape 3, so hi <= lo
    if lo >= hi: continue
    let word = s_idx shr 6
    let mbit = 1'u64 shl uint(s_idx and 63)
    for line in lo ..< hi:
      ppu.obj_line_mask[line][word] = ppu.obj_line_mask[line][word] or mbit
  ppu.obj_list_dirty = false
  inc ppu.obj_list_rebuilds

proc oam_touched*(ppu: PPU) {.inline.} =
  ## Invalidate the per-line OBJ candidate list. MUST be called by every path
  ## that mutates ppu.oam: bus.write_half_internal / write_word_internal
  ## (byte writes to OAM are discarded; DMA and cheats funnel through these),
  ## load_ppu_state (covers rewind, rollback and link restores), and the HLE
  ## RegisterRamReset OAM clear. Test code seeding ppu.oam must call it too.
  ## Backstops: scanline() force-rebuilds once per frame, and -d:objListVerify
  ## cross-checks the list against a full scan every line.
  ppu.obj_list_dirty = true

proc render_sprites_impl(ppu: PPU; force_scan: bool) =
  if not bit(uint16(ppu.dispcnt), 12): return
  let base = 0x10000'u32
  let sprites = ppu.sprites_ptr()
  let bitmap_mode = ppu.dispcnt.bg_mode >= 3
  # Per-line OBJ cycle budget: 1210 cycles, or 954 with DISPCNT's H-Blank
  # Interval Free bit (GBATEK "LCD OBJ Overview"). A regular sprite costs
  # `width` cycles, an affine one 10 + 2*width over its drawn footprint; once
  # the budget is spent, later OAM entries do not render. Model: the sprite
  # that exhausts the budget still draws fully; hardware likely truncates it
  # (docs/hwprobe-questions.md row 26, open). The Famicom Mini FDS carts
  # park full-width masking sprites at the end of OAM that hardware has no
  # time to draw.
  var obj_cycles = if ppu.dispcnt.hblank_interval_free: 954 else: 1210
  let vc = int(ppu.vcount)

  # One copy of the per-entry work for both the candidate-list walk and the
  # straight scan; the budget check sits in each loop header.
  template obj_entry(s_idx: int) =
    block one_sprite:
      let sprite = sprites[s_idx]
      if sprite.affine_mode == 0b10: break one_sprite
      let g = obj_geometry(sprite)
      let orig_width  = g.ow
      let orig_height = g.oh
      let width  = g.w
      let height = g.h
      let x_coord = g.x
      # Re-tested on the candidate path too: the list may only narrow what
      # is looked at, never make a sprite appear
      if not (g.y <= vc and vc < g.y + height): break one_sprite
      # Sprites fully outside the 240px window never enter the OBJ pipeline:
      # no pixels and no time charged
      if x_coord + width < 0: break one_sprite
      # center_{x,y} is the middle of the *drawn* box
      let center_x = x_coord + (width shr 1)
      let center_y = g.y + (height shr 1)
      let affine = bit(sprite.attr0, 8)
      var pa, pb, pc, pd: int
      if affine:
        let oam_affine_entry = int(bits_range(sprite.attr1, 9, 13))
        pa = int(sprites[oam_affine_entry * 4    ].aff_param)
        pb = int(sprites[oam_affine_entry * 4 + 1].aff_param)
        pc = int(sprites[oam_affine_entry * 4 + 2].aff_param)
        pd = int(sprites[oam_affine_entry * 4 + 3].aff_param)
      else:
        pa = 0x100; pb = 0; pc = 0; pd = 0x100
      # On-line sprite: charge its OBJ rendering time
      obj_cycles -= (if affine: 10 + 2 * width else: width)
      # Prohibited shape 3: unreachable (h=0, rejected above); kept so charge precedes skip as on hardware
      if orig_width == 0: break one_sprite
      # In bitmap modes the lower 16K of OBJ VRAM holds the bitmap, so tiles
      # below 512 don't render (but the sprite still occupies OBJ time)
      if bitmap_mode and int(bits_range(sprite.attr2, 0, 9)) < 512: break one_sprite
      # Mosaic sprites sample from the first pixel of each screen-space block
      let obj_mosaic = bit(sprite.attr0, 12)
      let mosaic_h = if obj_mosaic: int(ppu.mosaic.obj_mosiac_h_size) + 1 else: 1
      let vc_m = if obj_mosaic: vc - vc mod (int(ppu.mosaic.obj_mosiac_v_size) + 1) else: vc
      let iy     = vc_m - center_y
      let flip_x = bit(sprite.attr1, 12) and not affine
      let flip_y = bit(sprite.attr1, 13) and not affine
      let min_x  = max(0, x_coord)
      let max_x  = min(240, x_coord + width)
      for ix in (-(width div 2)) ..< (width div 2):
        let col = center_x + ix
        if col < min_x or col >= max_x: continue
        let ix_m = if mosaic_h > 1: (col - col mod mosaic_h) - center_x else: ix
        var tex_x = (pa * ix_m + pb * iy) shr 8
        var tex_y = (pc * ix_m + pd * iy) shr 8
        tex_x += orig_width div 2
        tex_y += orig_height div 2
        if tex_x < 0 or tex_x >= orig_width or tex_y < 0 or tex_y >= orig_height: continue
        if flip_x: tex_x = orig_width  - tex_x - 1
        if flip_y: tex_y = orig_height - tex_y - 1
        let tile_x = tex_x and 7
        let tile_y = tex_y and 7
        var tile_id = int(bits_range(sprite.attr2, 0, 9))
        var offset = tex_y shr 3
        if ppu.dispcnt.obj_mapping_1d:
          offset *= orig_width shr 3
        else:
          if bit(sprite.attr0, 13):  # 8bpp
            offset *= 0x10
          else:
            offset *= 0x20
        offset += tex_x shr 3
        var pal_idx: uint32
        # OBJ character fetches wrap within the 32K of OBJ VRAM. Assumed; no
        # ROM pins this.
        if bit(sprite.attr0, 13):  # 8bpp
          # The attr2 character name counts 32-byte units: in 1D mapping an
          # odd name starts half a tile in, only 2D mapping clears the low
          # bit (GBATEK says bit 0 is ignored in 256-colour mode). Assumed;
          # no ROM pins this.
          if not ppu.dispcnt.obj_mapping_1d:
            tile_id = tile_id and not 1
          pal_idx = uint32(ppu.vram[base + ((uint32(tile_id) * 0x20 + uint32(offset) * 0x40 + uint32(tile_y) * 8 + uint32(tile_x)) and 0x7FFF)])
        else:
          tile_id += offset
          let palettes = ppu.vram[base + ((uint32(tile_id) * 0x20 + uint32(tile_y) * 4 + (uint32(tile_x) shr 1)) and 0x7FFF)]
          pal_idx = uint32((palettes shr (uint32(tile_x and 1) * 4)) and 0xF)
          if pal_idx > 0:
            pal_idx += uint32(bits_range(sprite.attr2, 12, 15)) shl 4
        let obj_mode = int(bits_range(sprite.attr0, 10, 11))
        let spr_priority = int(bits_range(sprite.attr2, 10, 11))
        if obj_mode == 0b10:  # object window
          if pal_idx > 0:
            ppu.sprite_pixels[col].window = true
            ppu.line_obj_window = true
        elif spr_priority < int(ppu.sprite_pixels[col].priority) or ppu.sprite_pixels[col].palette == 0:
          ppu.sprite_pixels[col].priority = uint16(spr_priority)
          if pal_idx > 0:
            ppu.sprite_pixels[col].palette = uint16(pal_idx)
            ppu.sprite_pixels[col].blends  = obj_mode == 0b01
            if obj_mode == 0b01: ppu.line_sprite_blend = true

  # Use the candidate list unless the caller asked for the reference scan or
  # this frame has burned its rebuild budget (the mask is then stale)
  var use_list = (not force_scan) and vc >= 0 and vc < 160
  if use_list and ppu.obj_list_dirty:
    if ppu.obj_list_rebuilds < OBJ_LIST_REBUILD_LIMIT:
      ppu.rebuild_obj_lines()
    else:
      use_list = false

  if use_list:
    # Visit in OAM order (word 0 then word 1, low bit first): priority ties
    # break on the lower OAM index
    var m = ppu.obj_line_mask[vc][0]
    while m != 0:
      if obj_cycles <= 0: return
      let s_idx = countTrailingZeroBits(m)
      m = m and (m - 1)
      obj_entry(s_idx)
    m = ppu.obj_line_mask[vc][1]
    while m != 0:
      if obj_cycles <= 0: return
      let s_idx = 64 + countTrailingZeroBits(m)
      m = m and (m - 1)
      obj_entry(s_idx)
  else:
    for s_idx in 0 ..< 128:  # OAM has 128 sprites
      if obj_cycles <= 0: return
      obj_entry(s_idx)

when defined(objListVerify):
  # Self-checking build: every scanline renders the OBJ layer via the
  # candidate list and via the reference scan and aborts on a difference.
  # Catches an OAM mutation path that forgot oam_touched; run real ROMs.
  var objVerifyLines*: int = 0
  proc render_sprites*(ppu: PPU; force_scan = false) =
    let before_pixels = ppu.sprite_pixels
    let before_window = ppu.line_obj_window
    let before_blend  = ppu.line_sprite_blend
    ppu.render_sprites_impl(force_scan)
    let list_pixels = ppu.sprite_pixels
    let list_window = ppu.line_obj_window
    let list_blend  = ppu.line_sprite_blend
    ppu.sprite_pixels = before_pixels
    ppu.line_obj_window = before_window
    ppu.line_sprite_blend = before_blend
    ppu.render_sprites_impl(true)
    inc objVerifyLines
    if list_window != ppu.line_obj_window or list_blend != ppu.line_sprite_blend:
      quit("objListVerify: line flags differ at vcount " & $ppu.vcount, 3)
    for c in 0 .. 239:
      if list_pixels[c] != ppu.sprite_pixels[c]:
        quit("objListVerify: sprite pixel " & $c & " differs at vcount " &
             $ppu.vcount & " frame " & $ppu.frame, 3)
else:
  proc render_sprites*(ppu: PPU; force_scan = false) {.inline.} =
    ppu.render_sprites_impl(force_scan)

proc window_contains(v, lo, hi: uint16): bool {.inline.} =
  # Hardware windows are comparators: when the start is past the end the
  # window wraps around the screen edge (flashlight/tunnel effects)
  if lo <= hi: v >= lo and v < hi
  else: v >= lo or v < hi

proc fill_window_cols(ppu: PPU; winh: WINH; bits: uint16; effect: bool) =
  # Fill columns [x1, x2); when x1 > x2 the window wraps around the screen edge
  let x1 = int(winh.x1)
  let x2 = int(winh.x2)
  if x1 <= x2:
    for col in x1 ..< min(x2, 240):
      ppu.line_enables[col] = bits
      ppu.line_effects[col] = effect
  else:
    for col in 0 ..< min(x2, 240):
      ppu.line_enables[col] = bits
      ppu.line_effects[col] = effect
    for col in min(x1, 240) ..< 240:
      ppu.line_enables[col] = bits
      ppu.line_effects[col] = effect

type WinCover* = enum
  ## How much of the 240-column line `fill_window_cols` would write.
  wcEmpty, wcPartial, wcFull

proc window_cover*(winh: WINH): WinCover {.inline.} =
  ## Reduce a WINH to none / all / some of the line. Must mirror
  ## `fill_window_cols` exactly, clamps included: it models that loop, not
  ## the hardware. Both x1 and x2 are 8-bit, so either can exceed 240.
  let x1 = int(winh.x1)
  let x2 = int(winh.x2)
  let a  = min(x2, 240)
  if x1 <= x2:
    # One run, [x1, a)
    if x1 == 0 and a == 240: wcFull
    elif x1 >= a: wcEmpty
    else: wcPartial
  else:
    # Wrapped: [0, a) plus [b, 240); full when the runs meet or overlap
    let b = min(x1, 240)
    if a >= b: wcFull
    elif a == 0 and b == 240: wcEmpty
    else: wcPartial

proc line_window_flags*(ppu: PPU): tuple[win0, win1, objwin: bool] {.inline.} =
  ## Which window sources can affect this scanline: win0/win1 only inside
  ## their vertical range (y1 > y2 wraps like x1 > x2), the OBJ window only
  ## when render_sprites wrote an OBJ-window pixel on this line.
  let vc = ppu.vcount
  result.win0 = ppu.dispcnt.window_0_display and
                window_contains(vc, uint16(ppu.win0v.y1), uint16(ppu.win0v.y2))
  result.win1 = ppu.dispcnt.window_1_display and
                window_contains(vc, uint16(ppu.win1v.y1), uint16(ppu.win1v.y2))
  result.objwin = ppu.dispcnt.obj_window_display and ppu.line_obj_window

proc uniform_window_state*(ppu: PPU; win0_on, win1_on, objwin_on: bool;
                           ubits: var uint16; ueff: var bool): bool {.inline.} =
  ## True only when all 240 columns provably receive the same (enable mask,
  ## effect flag) pair from compute_line_enables, returned in ubits/ueff.
  ## Reproduces its painter's algorithm at whole-line granularity: base
  ## (outside, or outside/OBJ-window mixed), then win1, then win0; a partial
  ## overlay keeps uniformity only if it paints what is already there.
  let dbg_mask = ppu.debug_layer_mask
  ubits = uint16(ppu.winout.outside_enable_bits) and dbg_mask
  ueff  = ppu.winout.outside_color_special_effect
  # The base is uniform if no OBJ-window pixel exists on this line or the
  # OBJ-window state equals the outside state
  var uni = (not objwin_on) or
            ((uint16(ppu.winout.obj_window_enable_bits) and dbg_mask) == ubits and
             ppu.winout.obj_window_color_special_effect == ueff)
  if win1_on:
    let bits = uint16(ppu.winin.window_1_enable_bits) and dbg_mask
    let eff  = ppu.winin.window_1_color_special_effect
    case window_cover(ppu.win1h)
    of wcFull:    uni = true; ubits = bits; ueff = eff
    of wcPartial: uni = uni and bits == ubits and eff == ueff
    of wcEmpty:   discard
  if win0_on:
    let bits = uint16(ppu.winin.window_0_enable_bits) and dbg_mask
    let eff  = ppu.winin.window_0_color_special_effect
    case window_cover(ppu.win0h)
    of wcFull:    uni = true; ubits = bits; ueff = eff
    of wcPartial: uni = uni and bits == ubits and eff == ueff
    of wcEmpty:   discard
  uni

proc compute_line_enables*(ppu: PPU) =
  # Same per-pixel result as checking win0 -> win1 -> obj window -> outside:
  # paint the lowest-priority source first, then overlay win1, then win0
  let dbg_mask = ppu.debug_layer_mask
  let obj_active = ppu.dispcnt.obj_window_display
  # Shared with composite()'s uniformity test so the two cannot disagree
  let flags = ppu.line_window_flags()
  let out_bits = uint16(ppu.winout.outside_enable_bits) and dbg_mask
  let out_eff  = ppu.winout.outside_color_special_effect
  let obj_bits = uint16(ppu.winout.obj_window_enable_bits) and dbg_mask
  let obj_eff  = ppu.winout.obj_window_color_special_effect
  for col in 0 .. 239:
    if obj_active and ppu.sprite_pixels[col].window:
      ppu.line_enables[col] = obj_bits
      ppu.line_effects[col] = obj_eff
    else:
      ppu.line_enables[col] = out_bits
      ppu.line_effects[col] = out_eff
  if flags.win1:
    ppu.fill_window_cols(ppu.win1h,
                         uint16(ppu.winin.window_1_enable_bits) and dbg_mask,
                         ppu.winin.window_1_color_special_effect)
  if flags.win0:
    ppu.fill_window_cols(ppu.win0h,
                         uint16(ppu.winin.window_0_enable_bits) and dbg_mask,
                         ppu.winin.window_0_color_special_effect)

proc compute_layer_walk*(ppu: PPU) =
  # Contributing BGs in compositing order: priority first, then BG index
  # (the lower BG number wins at equal priority). Sprites are merged into the
  # walk by comparing their per-pixel priority against each entry's.
  var n = 0
  for p in 0 .. 3:
    for bg in 0 .. 3:
      if int(ppu.bgcnt[bg].priority) == p and
         bit(uint16(ppu.dispcnt), 8 + bg) and bit(ppu.debug_layer_mask, bg):
        ppu.walk_bgs[n]   = int8(bg)
        ppu.walk_prios[n] = int8(p)
        inc n
  ppu.walk_n = n

# SWAR helpers: spread the three 5-bit BGR555 channels into separate 16-bit
# lanes of a uint64 so all three can be scaled/added/saturated at once
proc bgr16_spread*(c: uint16): uint64 {.inline.} =
  uint64(c and 0x1F) or (uint64(c and 0x3E0) shl 11) or (uint64(c and 0x7C00) shl 22)

const BGR_LANE_MASK* = 0xFF'u64 or (0xFF'u64 shl 16) or (0xFF'u64 shl 32)

# Exported with bgr16_pack so tests/ppucomposite_test.nim can prove the two
# agree, which is what licenses brighten/darken to skip saturation
proc bgr16_pack_sat*(v: uint64): uint16 {.inline.} =
  # Saturate each lane at 0x1F, then pack back to BGR555
  var r = v and 0xFFFF'u64
  var g = (v shr 16) and 0xFFFF'u64
  var b = (v shr 32) and 0xFFFF'u64
  if r > 0x1F: r = 0x1F
  if g > 0x1F: g = 0x1F
  if b > 0x1F: b = 0x1F
  uint16(r or (g shl 5) or (b shl 10))

proc bgr16_pack*(v: uint64): uint16 {.inline.} =
  ## Pack three 5-bit lanes back to BGR555 WITHOUT saturating. Valid only
  ## where each lane is already <= 0x1F: with EVY clamped to 16, darken gives
  ## s - (s*evy)/16 >= 0 and brighten s + ((31-s)*evy)/16 <= 31. EVY = 17
  ## does overflow, so the `min(16, ...)` on every evy_coefficient read is
  ## load-bearing; tests/ppucomposite_test.nim drives EVY = 16, 17, 31.
  uint16((v and 0x1F'u64) or
         (((v shr 16) and 0x1F'u64) shl 5) or
         (((v shr 32) and 0x1F'u64) shl 10))

proc blend_colors*(ppu: PPU; top_u16, bot_u16: uint16; blend_mode: int): uint16 =
  case blend_mode
  of 0: top_u16  # None
  of 1:          # Blend
    let eva = uint64(min(16, int(ppu.bldalpha.eva_coefficient)))
    let evb = uint64(min(16, int(ppu.bldalpha.evb_coefficient)))
    let t = ((bgr16_spread(top_u16) * eva) shr 4) and BGR_LANE_MASK
    let b = ((bgr16_spread(bot_u16) * evb) shr 4) and BGR_LANE_MASK
    bgr16_pack_sat(t + b)
  of 2:          # Brighten
    let evy = uint64(min(16, int(ppu.bldy.evy_coefficient)))
    let s = bgr16_spread(top_u16)
    let d = (((bgr16_spread(0x7FFF'u16) - s) * evy) shr 4) and BGR_LANE_MASK
    bgr16_pack_sat(s + d)
  of 3:          # Darken
    let evy = uint64(min(16, int(ppu.bldy.evy_coefficient)))
    let s = bgr16_spread(top_u16)
    bgr16_pack_sat(s - (((s * evy) shr 4) and BGR_LANE_MASK))
  else: top_u16

# Compositing runs per span of columns that share one window configuration.
# Everything constant over a span (enabled layers, priority order, row
# pointers, whether colour math can apply) is resolved once in
# composite_span; the inner loops then only walk opaque pixels. The
# no-effect loop ("first opaque pixel in priority order wins") is what most
# real columns take.

type SpanWalk = object
  ## The layer walk filtered down to one span's enabled layers, with
  ## everything that is constant across the span resolved up front.
  n:      int
  prio:   array[4, int32]
  layer:  array[4, int32]
  direct: array[4, bool]                        # bitmap direct-colour BG2
  sel1:   array[4, bool]                        # BLDCNT 1st-target
  sel2:   array[4, bool]                        # BLDCNT 2nd-target
  row:    array[4, ptr UncheckedArray[uint8]]   # layer_palettes[bg] for this line

proc composite_span_opaque(ppu: PPU; w: SpanWalk; row_base: uint32;
                           lo, hi: int; obj_enable: bool) =
  ## Span where no colour math can apply: the first opaque pixel in priority
  ## order wins. Instantiated per walk length so the loop unrolls and each
  ## layer's priority and row pointer stays in a register; the bitmap
  ## direct-colour test is hoisted the same way.
  let pram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.pram[0])
  let fb       = cast[ptr UncheckedArray[uint16]](addr ppu.framebuffer[0])
  let sprites  = cast[ptr UncheckedArray[SpritePixel]](addr ppu.sprite_pixels[0])
  let bg2d     = cast[ptr UncheckedArray[uint16]](addr ppu.bg2_direct[0])
  let bg2o     = cast[ptr UncheckedArray[bool]](addr ppu.bg2_direct_opaque[0])
  let backdrop = pram_u16[0]
  template opaque_loop(NN: static int; DIRECT: static bool) =
    for col in lo ..< hi:
      let sp = sprites[col]
      let spal = int(sp.palette)
      var sprio = 4'i32
      if obj_enable and spal != 0: sprio = int32(sp.priority)
      var color = backdrop
      block found:
        for i in 0 ..< NN:
          if sprio <= w.prio[i]:
            color = pram_u16[0x100 + spal]
            break found
          when DIRECT:
            if w.direct[i]:
              if bg2o[col]:
                color = bg2d[col]
                break found
              continue
          let palette = int(w.row[i][col])
          if palette != 0:
            color = pram_u16[palette]
            break found
        # Every enabled BG was transparent: a sprite below all of them still
        # beats the backdrop
        if sprio < 4:
          color = pram_u16[0x100 + spal]
      fb[row_base + uint32(col)] = color
  if ppu.bitmap_direct:
    case w.n
    of 0: opaque_loop(0, true)
    of 1: opaque_loop(1, true)
    of 2: opaque_loop(2, true)
    of 3: opaque_loop(3, true)
    else: opaque_loop(4, true)
  else:
    case w.n
    of 0: opaque_loop(0, false)
    of 1: opaque_loop(1, false)
    of 2: opaque_loop(2, false)
    of 3: opaque_loop(3, false)
    else: opaque_loop(4, false)

proc composite_span_shade(ppu: PPU; w: SpanWalk; row_base: uint32;
                          lo, hi: int; obj_enable: bool) =
  ## Span whose only reachable colour effect is brighten or darken: no
  ## semi-transparent OBJ pixel and no alpha, so the layer under the top one
  ## never matters. The opaque walk plus one shade of the winning colour.
  let pram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.pram[0])
  let fb       = cast[ptr UncheckedArray[uint16]](addr ppu.framebuffer[0])
  let sprites  = cast[ptr UncheckedArray[SpritePixel]](addr ppu.sprite_pixels[0])
  let bg2d     = cast[ptr UncheckedArray[uint16]](addr ppu.bg2_direct[0])
  let bg2o     = cast[ptr UncheckedArray[bool]](addr ppu.bg2_direct_opaque[0])
  let bld      = uint16(ppu.bldcnt)
  let backdrop = pram_u16[0]
  let sel_obj  = bit(bld, 4)
  let sel_bd   = bit(bld, 5)
  let evy      = uint64(min(16, int(ppu.bldy.evy_coefficient)))
  let brighten = ppu.bldcnt.blend_mode == 2
  let white    = bgr16_spread(0x7FFF'u16)
  template shade(c: uint16): uint16 =
    let s = bgr16_spread(c)
    let d = (((if brighten: white - s else: s) * evy) shr 4) and BGR_LANE_MASK
    if brighten: bgr16_pack(s + d) else: bgr16_pack(s - d)
  template shade_loop(NN: static int; DIRECT: static bool) =
    for col in lo ..< hi:
      let sp = sprites[col]
      let spal = int(sp.palette)
      var sprio = 4'i32
      if obj_enable and spal != 0: sprio = int32(sp.priority)
      var color = backdrop
      var sel = sel_bd
      block found:
        for i in 0 ..< NN:
          if sprio <= w.prio[i]:
            color = pram_u16[0x100 + spal]
            sel = sel_obj
            break found
          when DIRECT:
            if w.direct[i]:
              if bg2o[col]:
                color = bg2d[col]
                sel = w.sel1[i]
                break found
              continue
          let palette = int(w.row[i][col])
          if palette != 0:
            color = pram_u16[palette]
            sel = w.sel1[i]
            break found
        if sprio < 4:
          color = pram_u16[0x100 + spal]
          sel = sel_obj
      if sel: color = shade(color)
      fb[row_base + uint32(col)] = color
  if ppu.bitmap_direct:
    case w.n
    of 0: shade_loop(0, true)
    of 1: shade_loop(1, true)
    of 2: shade_loop(2, true)
    of 3: shade_loop(3, true)
    else: shade_loop(4, true)
  else:
    case w.n
    of 0: shade_loop(0, false)
    of 1: shade_loop(1, false)
    of 2: shade_loop(2, false)
    of 3: shade_loop(3, false)
    else: shade_loop(4, false)

proc composite_span(ppu: PPU; row_base: uint32; lo, hi: int;
                    enable_bits: uint16; effects: bool) =
  let obj_enable = bit(enable_bits, 4)
  var w: SpanWalk
  # Layers that can end up on top in this span: the backdrop always, OBJ
  # only when the window enables it
  var appear = 0x20'u16
  if obj_enable: appear = appear or 0x10'u16
  for i in 0 ..< ppu.walk_n:
    let bg = int(ppu.walk_bgs[i])
    if bit(enable_bits, bg):
      let k = w.n
      w.prio[k]   = int32(ppu.walk_prios[i])
      w.layer[k]  = int32(bg)
      w.direct[k] = ppu.bitmap_direct and bg == 2
      w.sel1[k]   = bit(uint16(ppu.bldcnt), bg)
      w.sel2[k]   = bit(uint16(ppu.bldcnt), bg + 8)
      w.row[k]    = cast[ptr UncheckedArray[uint8]](addr ppu.layer_palettes[bg][0])
      appear = appear or (1'u16 shl bg)
      w.n = k + 1

  # Colour math needs the top layer to be a BLDCNT 1st target, or a
  # semi-transparent OBJ pixel (which forces alpha regardless of mode); if
  # neither is reachable the effects apparatus is dead for this span
  let can_blend = effects and
    ((obj_enable and ppu.line_sprite_blend) or
     (ppu.bldcnt.blend_mode != 0 and
      (uint16(ppu.bldcnt) and 0x3F'u16 and appear) != 0))
  if not can_blend:
    ppu.composite_span_opaque(w, row_base, lo, hi, obj_enable)
    return
  # Brighten/darken with no semi-transparent OBJ pixel never needs the layer
  # below the top one
  if ppu.bldcnt.blend_mode != 1 and not (obj_enable and ppu.line_sprite_blend):
    ppu.composite_span_shade(w, row_base, lo, hi, obj_enable)
    return

  # Colour math is reachable: find the top layer, then the layer under it
  # only when the result can depend on it. Kept in this proc so the walk
  # stays a plain local the compiler can keep in registers.
  let pram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.pram[0])
  let fb       = cast[ptr UncheckedArray[uint16]](addr ppu.framebuffer[0])
  let sprites  = cast[ptr UncheckedArray[SpritePixel]](addr ppu.sprite_pixels[0])
  let bg2d     = cast[ptr UncheckedArray[uint16]](addr ppu.bg2_direct[0])
  let bg2o     = cast[ptr UncheckedArray[bool]](addr ppu.bg2_direct_opaque[0])
  let bld        = uint16(ppu.bldcnt)
  let blend_mode = int(ppu.bldcnt.blend_mode)
  let backdrop   = pram_u16[0]
  # BLDALPHA/BLDY are constant for the span
  let eva = uint64(min(16, int(ppu.bldalpha.eva_coefficient)))
  let evb = uint64(min(16, int(ppu.bldalpha.evb_coefficient)))
  let evy = uint64(min(16, int(ppu.bldy.evy_coefficient)))
  let white = bgr16_spread(0x7FFF'u16)

  template alpha(top_u16, bot_u16: uint16): uint16 =
    let t = ((bgr16_spread(top_u16) * eva) shr 4) and BGR_LANE_MASK
    let b = ((bgr16_spread(bot_u16) * evb) shr 4) and BGR_LANE_MASK
    bgr16_pack_sat(t + b)

  template brighten_darken(top_u16: uint16): uint16 =
    # blend_mode is 2 (brighten toward white) or 3 (darken toward black);
    # mode 0/1 reach here only through the semi-transparent-OBJ fallback,
    # where the hardware result is the unmodified top layer.
    let s = bgr16_spread(top_u16)
    let d = (((if blend_mode == 2: white - s else: s) * evy) shr 4) and BGR_LANE_MASK
    if blend_mode == 2:   bgr16_pack(s + d)
    elif blend_mode == 3: bgr16_pack(s - d)
    else:                 top_u16

  let sel1_obj = bit(bld, 4)
  let sel1_bd  = bit(bld, 5)
  let sel2_obj = bit(bld, 4 + 8)
  let sel2_bd  = bit(bld, 5 + 8)

  # The top-layer search runs on every pixel, so it is instantiated per walk
  # length; the bottom search starts at a runtime position and stays general
  template blend_loop(NN: static int; DIRECT: static bool) =
    for col in lo ..< hi:
      let sp = sprites[col]
      let spal = int(sp.palette)
      var sprio = 4'i32
      if obj_enable and spal != 0: sprio = int32(sp.priority)
      # `idx` carries the walk position plus an "OBJ already taken" flag so
      # the bottom search resumes where the top left off
      var idx = NN or SPRITE_TAKEN
      var top_color = backdrop
      var top_blends = false
      var top_selected = sel1_bd
      block found:
        for i in 0 ..< NN:
          if sprio <= w.prio[i]:
            top_color = pram_u16[0x100 + spal]
            top_blends = sp.blends
            top_selected = sel1_obj
            idx = i or SPRITE_TAKEN
            break found
          when DIRECT:
            if w.direct[i]:
              if bg2o[col]:
                top_color = bg2d[col]
                top_selected = w.sel1[i]
                idx = i + 1
                break found
              continue
          let palette = int(w.row[i][col])
          if palette != 0:
            top_color = pram_u16[palette]
            top_selected = w.sel1[i]
            idx = i + 1
            break found
        if sprio < 4:
          top_color = pram_u16[0x100 + spal]
          top_blends = sp.blends
          top_selected = sel1_obj
      var color = top_color
      # The second layer is searched only when the result can depend on it:
      # a semi-transparent OBJ on top, or alpha blending with a selected top
      if top_blends or (top_selected and blend_mode == 1):
        var bsprio = 4'i32
        if (idx and SPRITE_TAKEN) == 0 and obj_enable and spal != 0:
          bsprio = int32(sp.priority)
        var bidx = idx and not SPRITE_TAKEN
        var bot_selected = sel2_bd
        var bot_color = backdrop
        block bfound:
          while bidx < NN:
            if bsprio <= w.prio[bidx]:
              bot_color = pram_u16[0x100 + spal]
              bot_selected = sel2_obj
              break bfound
            when DIRECT:
              if w.direct[bidx]:
                if bg2o[col]:
                  bot_color = bg2d[col]
                  bot_selected = w.sel2[bidx]
                  break bfound
                inc bidx
                continue
            let palette = int(w.row[bidx][col])
            if palette != 0:
              bot_color = pram_u16[palette]
              bot_selected = w.sel2[bidx]
              break bfound
            inc bidx
          if bsprio < 4:
            bot_color = pram_u16[0x100 + spal]
            bot_selected = sel2_obj
        if bot_selected:
          color = alpha(top_color, bot_color)
        elif top_blends and top_selected and blend_mode != 1:
          color = brighten_darken(top_color)
      elif top_selected and blend_mode != 0:
        color = brighten_darken(top_color)
      fb[row_base + uint32(col)] = color

  if ppu.bitmap_direct:
    case w.n
    of 0: blend_loop(0, true)
    of 1: blend_loop(1, true)
    of 2: blend_loop(2, true)
    of 3: blend_loop(3, true)
    else: blend_loop(4, true)
  else:
    case w.n
    of 0: blend_loop(0, false)
    of 1: blend_loop(1, false)
    of 2: blend_loop(2, false)
    of 3: blend_loop(3, false)
    else: blend_loop(4, false)

proc composite*(ppu: PPU; row_base: uint32) =
  ppu.compute_layer_walk()
  let dbg_mask = ppu.debug_layer_mask
  # When no window source applies to this line, every column shares one
  # enable mask and the per-column tables are not needed
  let (win0_on, win1_on, objwin_on) = ppu.line_window_flags()
  if not (win0_on or win1_on or objwin_on):
    let any_window = ppu.dispcnt.window_0_display or
                     ppu.dispcnt.window_1_display or
                     ppu.dispcnt.obj_window_display
    if any_window:
      ppu.composite_span(row_base, 0, 240,
                         uint16(ppu.winout.outside_enable_bits) and dbg_mask,
                         ppu.winout.outside_color_special_effect)
    else:
      ppu.composite_span(row_base, 0, 240,
                         uint16(ppu.dispcnt.default_enable_bits) and dbg_mask,
                         true)
    return
  # A live window can still resolve to one enable mask (a full-width WIN0 is
  # the common case). tests/ppucomposite_test.nim fuzzes this decision against
  # compute_line_enables via disable_uniform_window.
  var ubits: uint16
  var ueff:  bool
  if not ppu.disable_uniform_window and
     ppu.uniform_window_state(win0_on, win1_on, objwin_on, ubits, ueff):
    ppu.composite_span(row_base, 0, 240, ubits, ueff)
    return
  ppu.compute_line_enables()
  # Composite each run of identical window state with its mask hoisted
  var col = 0
  while col < 240:
    let bits = ppu.line_enables[col]
    let eff  = ppu.line_effects[col]
    var e = col + 1
    while e < 240 and ppu.line_enables[e] == bits and ppu.line_effects[e] == eff:
      inc e
    ppu.composite_span(row_base, col, e, bits, eff)
    col = e

proc scanline*(ppu: PPU) =
  # Render skipping: after a full frame with no change to VRAM/PRAM/OAM/PPU
  # registers the framebuffer already holds every line, so skip until
  # something changes (a mid-frame change only affects lines below it)
  if ppu.vcount == 0:
    # Speed-mode frameskip: render_dirty is NOT consumed on a skipped frame,
    # so the next rendered frame repaints everything that changed
    if ppu.frameskip > 0:
      # fs_counter == 0 renders, the next `frameskip` frames are skipped
      ppu.forced_skip = ppu.fs_counter != 0
      inc ppu.fs_counter
      if ppu.fs_counter > ppu.frameskip:
        ppu.fs_counter = 0
    else:
      ppu.forced_skip = false
    if not ppu.forced_skip:
      ppu.skip_render = not ppu.render_dirty
      ppu.render_dirty = false
    # New frame: rebuild budget comes back, plus one forced rebuild as the
    # missed-oam_touched backstop
    ppu.obj_list_rebuilds = 0
    ppu.obj_list_dirty = true
  if ppu.forced_skip:
    return
  if ppu.skip_render:
    if ppu.render_dirty:
      ppu.skip_render = false
    else:
      return
  let row      = uint32(ppu.vcount)
  let row_base = 240'u32 * row
  if ppu.gba.cpu.stopped:
    # Stop mode powers down the LCD; present black
    for c in 0..239: ppu.framebuffer[row_base + uint32(c)] = 0
    return
  if ppu.dispcnt.forced_blank:
    for c in 0..239: ppu.framebuffer[row_base + uint32(c)] = 0x7FFF'u16
    return
  # Only the BGs DISPCNT enables need clearing: a disabled BG is never
  # written (renderers return on the same bit) nor read (compute_layer_walk
  # skips it)
  for bg in 0..3:
    if bit(uint16(ppu.dispcnt), 8 + bg):
      for c in 0..239: ppu.layer_palettes[bg][c] = 0
  for c in 0..239: ppu.sprite_pixels[c] = SPRITE_PIXEL_DEFAULT
  ppu.bitmap_direct = false
  ppu.line_sprite_blend = false
  ppu.line_obj_window = false
  case ppu.dispcnt.bg_mode
  of 0:
    ppu.render_reg_bg(0); ppu.render_reg_bg(1)
    ppu.render_reg_bg(2); ppu.render_reg_bg(3)
    ppu.render_sprites()
    ppu.composite(row_base)
  of 1:
    ppu.render_reg_bg(0); ppu.render_reg_bg(1)
    ppu.render_aff_bg(2)
    ppu.render_sprites()
    ppu.composite(row_base)
  of 2:
    ppu.render_aff_bg(2); ppu.render_aff_bg(3)
    ppu.render_sprites()
    ppu.composite(row_base)
  of 3, 4, 5:
    ppu.render_bitmap()
    ppu.render_sprites()
    ppu.composite(row_base)
  else:
    # Prohibited modes 6/7: no background layers; show the backdrop
    ppu.composite(row_base)

proc rerender_frame*(ppu: PPU) =
  ## Re-run the visible scanline pipeline against the current PPU state
  ## without advancing emulation, so a paused frame reflects a
  ## debug_layer_mask change. Frames with mid-frame HBlank effects re-render
  ## from the final line's registers. Non-destructive: affine internal
  ## references and vcount are restored.
  let saved_vcount = ppu.vcount
  var saved_bgref_int = ppu.bgref_int
  # Affine references at their line-0 values (the vblank latch)
  for bg in 0..1:
    for r in 0..1:
      ppu.bgref_int[bg][r] = ppu.bgref[bg][r].num
  # Force the render-skip logic to actually draw every line this pass.
  ppu.render_dirty = true
  for row in 0'u16 .. 159'u16:
    ppu.vcount = row
    ppu.scanline()
    for bg in 0..1:
      ppu.bgref_int[bg][0] += ppu.bgaff[bg][1].num  # bgx += dmx
      ppu.bgref_int[bg][1] += ppu.bgaff[bg][3].num  # bgy += dmy
  ppu.vcount = saved_vcount
  ppu.bgref_int = saved_bgref_int
  # Make the next real frame render and the frontend re-upload
  ppu.render_dirty = true
  ppu.skip_render = false
  ppu.frame_static = false

proc `[]`*(ppu: PPU; io_addr: uint32): uint8 =
  case io_addr
  of 0x000..0x001: read(ppu.dispcnt, io_addr and 1)
  of 0x002..0x003: 0'u8  # green swap
  of 0x004..0x005: read(ppu.dispstat, io_addr and 1)
  of 0x006..0x007: read(ppu.vcount, io_addr and 1)
  of 0x008, 0x00A, 0x00C, 0x00E:  # BGxCNT low byte
    read(ppu.bgcnt[int((io_addr - 0x008) shr 1)], 0)
  of 0x009, 0x00B:  # BG0/BG1 CNT high byte — bit 13 (affine_wrap) not readable
    read(ppu.bgcnt[int((io_addr - 0x008) shr 1)], 1) and 0xDF'u8
  of 0x00D, 0x00F:  # BG2/BG3 CNT high byte
    read(ppu.bgcnt[int((io_addr - 0x008) shr 1)], 1)
  of 0x048..0x049: read(ppu.winin, io_addr and 1) and 0x3F'u8
  of 0x04A..0x04B: read(ppu.winout, io_addr and 1) and 0x3F'u8
  of 0x050: read(ppu.bldcnt, 0)
  of 0x051: read(ppu.bldcnt, 1) and 0x3F'u8  # bits 14-15 not readable
  of 0x052..0x053: read(ppu.bldalpha, io_addr and 1) and 0x1F'u8
  else: ppu.gba.bus.read_open_bus_value(io_addr)

proc `[]=`*(ppu: PPU; io_addr: uint32; value: uint8) =
  ppu.render_dirty = true
  case io_addr
  of 0x000..0x001: write(ppu.dispcnt, value, io_addr and 1)
  of 0x002..0x003: discard  # green swap
  of 0x004:
    # Writable low-byte bits are 3-5 (the IRQ enables): bits 0-2 are the
    # live flags and bits 6-7 do not latch (gbaedge IOBYTE page: strb 0x44
    # reads back as just the flags)
    let preserved = uint8(toU16(ppu.dispstat)) and 0x07'u8
    write(ppu.dispstat, (value and 0x38'u8) or preserved, 0)
  of 0x005: write(ppu.dispstat, value, 1)
  of 0x006..0x007: discard  # vcount
  of 0x008..0x00F: write(ppu.bgcnt[int((io_addr - 0x008) shr 1)], value, io_addr and 1)
  of 0x010..0x01F:
    let bg_num = int((io_addr - 0x010) shr 2)
    if bit(io_addr, 1):
      write(ppu.bgvofs[bg_num], value, io_addr and 1)
    else:
      write(ppu.bghofs[bg_num], value, io_addr and 1)
  of 0x020..0x03F:
    let bg_num = int((io_addr and 0x10) shr 4)
    let offs   = int(io_addr and 0xF)
    if offs >= 8:
      let o = offs - 8
      write(ppu.bgref[bg_num][o shr 2], value, o and 3)
      ppu.bgref_int[bg_num][o shr 2] = ppu.bgref[bg_num][o shr 2].num
    else:
      write(ppu.bgaff[bg_num][offs shr 1], value, offs and 1)
  of 0x040..0x041: write(ppu.win0h, value, io_addr and 1)
  of 0x042..0x043: write(ppu.win1h, value, io_addr and 1)
  of 0x044..0x045: write(ppu.win0v, value, io_addr and 1)
  of 0x046..0x047: write(ppu.win1v, value, io_addr and 1)
  of 0x048..0x049: write(ppu.winin, value, io_addr and 1)
  of 0x04A..0x04B: write(ppu.winout, value, io_addr and 1)
  of 0x04C..0x04D: write(ppu.mosaic, value, io_addr and 1)
  of 0x050..0x051: write(ppu.bldcnt, value, io_addr and 1)
  of 0x052..0x053: write(ppu.bldalpha, value, io_addr and 1)
  of 0x054..0x055: write(ppu.bldy, value, io_addr and 1)
  else: discard
