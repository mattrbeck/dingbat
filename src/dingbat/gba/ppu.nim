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
  result.dispcnt        = DISPCNT()
  result.dispstat       = DISPSTAT()
  result.vcount         = 0
  for i in 0..3:
    result.bgcnt[i]  = BGCNT()
    result.bghofs[i] = BGOFS()
    result.bgvofs[i] = BGOFS()
  for i in 0..1:
    # PA/PD reset to 1.0 (0x100) on hardware — identity transform (mGBA's
    # GBAIOInit does the same). Games like Doom rely on this in mode 4
    # without ever writing the affine registers.
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

proc start_hblank*(ppu: PPU) =
  ppu.gba.scheduler.schedule(272, etPPUEndHBlank)
  # DISPSTAT hblank flag sets 44 cycles into the h-blank gap (flag high for
  # 228 of the 1232-cycle scanline; mGBA suite "H-blank bit start")
  ppu.gba.scheduler.schedule(44, etPPUSetHBlankFlag)
  if ppu.dispstat.hblank_irq_enable:
    ppu.gba.interrupts.reg_if.hblank = true
    ppu.gba.interrupts.schedule_interrupt_check(IRQ_SYNC_DELAY)
  if ppu.vcount < 160:
    ppu.scanline()
    for bg_num in 0..1:
      ppu.bgref_int[bg_num][0] += ppu.bgaff[bg_num][1].num  # bgx += dmx
      ppu.bgref_int[bg_num][1] += ppu.bgaff[bg_num][3].num  # bgy += dmy
    ppu.gba.dma.trigger_hdma()

proc set_hblank_flag*(ppu: PPU) =
  ppu.dispstat.hblank = true

proc end_hblank*(ppu: PPU) =
  ppu.gba.scheduler.schedule(0, etPPUStartLine)
  ppu.dispstat.hblank = false
  ppu.vcount = uint16((int(ppu.vcount) + 1) mod 228)
  ppu.gba.dma.trigger_video_capture(ppu.vcount)
  ppu.dispstat.vcounter = (ppu.vcount == uint16(ppu.dispstat.vcount_setting))
  if ppu.dispstat.vcounter_irq_enable and ppu.dispstat.vcounter:
    ppu.gba.interrupts.reg_if.vcounter = true
  if ppu.vcount == 227:
    ppu.dispstat.vblank = false
  elif ppu.vcount == 160:
    ppu.dispstat.vblank = true
    ppu.gba.dma.trigger_vdma()
    if ppu.dispstat.vblank_irq_enable:
      ppu.gba.interrupts.reg_if.vblank = true
    for bg_num in 0..1:
      for ref_num in 0..1:
        ppu.bgref_int[bg_num][ref_num] = ppu.bgref[bg_num][ref_num].num
    ppu.draw()
  ppu.gba.interrupts.schedule_interrupt_check(IRQ_SYNC_DELAY)

proc draw*(ppu: PPU) =
  inc ppu.frame
  # True only when every scanline of this frame was skipped: the framebuffer
  # is bit-identical to the previous frame, so frontends can skip the
  # texture upload as well
  ppu.frame_static = ppu.skip_render

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

proc render_reg_bg*(ppu: PPU; bg: int) =
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
  # Walk the scanline one tile span at a time instead of one pixel at a time.
  # The old loop recomputed the effective column, re-derived tile_x and tested
  # it against the previous column's on all 240 pixels to catch the ~30 tile
  # boundaries that actually matter, then re-tested is_8bpp per pixel. Spans
  # hoist all of that: a span never crosses a tile boundary (and never wraps,
  # since bg_width+1 is 256 or 512 — both multiples of 8), so the screen entry,
  # tile row base, flip mask and palette bank are each computed once per tile.
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
      # render transparent (row bases are 4-byte aligned, so checking the
      # row start suffices)
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
        # A 4bpp tile row is exactly 4 bytes = 8 nibbles, and tile_base is
        # 4-byte aligned (character_base, tile stride and row stride are all
        # multiples of 4), so pull the whole row as one word and shift each
        # pixel out. That replaces span byte loads with a single load, and the
        # branchless bank add keeps the tail loop vectorizable.
        let row = cast[ptr uint32](addr vram[tile_base])[]
        for k in 0 ..< span:
          let x = (x_in_tile + k) xor flip_x_mask
          let p = uint8((row shr (uint32(x) * 4)) and 0xF)
          # Palette index 0 is transparent in every bank, so it must NOT take
          # the bank offset.
          dst[col + k] = p or (if p != 0: bank else: 0'u8)
    col += span
  if bgcnt.mosaic:
    let h = int(ppu.mosaic.bg_mosiac_h_size) + 1
    if h > 1:
      for col in 0..239:
        ppu.layer_palettes[bg][col] = ppu.layer_palettes[bg][col - col mod h]

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
  ## Fill the BG2 line buffers for the bitmap modes (3/4/5), honoring the
  ## BG2 enable bit and mosaic. Modes 3/5 produce direct BGR555 colors;
  ## mode 4 is paletted and uses the regular layer pipeline.
  ## BG2 is an AFFINE layer in the bitmap modes: PA/PC and the internal
  ## reference point apply exactly as in modes 1/2, sampling the bitmap as a
  ## texture (out-of-range = transparent; the wrap bit has no effect here).
  ## DBZ Legacy of Goku's intro FMV relies on this, upscaling reduced-height
  ## video cells to the full screen with PD < 1.0.
  let mode = int(ppu.dispcnt.bg_mode)
  ppu.bitmap_direct = mode != 4
  for col in 0..239: ppu.bg2_direct_opaque[col] = false
  if not bit(uint16(ppu.dispcnt), 10): return  # BG2 disabled
  let dx = ppu.bgaff[0][0].num
  let dy = ppu.bgaff[0][2].num
  var int_x = ppu.bgref_int[0][0]
  var int_y = ppu.bgref_int[0][1]
  if ppu.bgcnt[2].mosaic:
    # Vertical mosaic: reuse the internal coordinates latched on the first
    # line of the mosaic block (same scheme as render_aff_bg)
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

proc render_sprites*(ppu: PPU) =
  if not bit(uint16(ppu.dispcnt), 12): return
  let base = 0x10000'u32
  let sprites = ppu.sprites_ptr()
  let num_sprites = 128  # OAM has 128 sprites
  let bitmap_mode = ppu.dispcnt.bg_mode >= 3
  # Per-scanline OBJ rendering time budget (hardware sprite cycle limit):
  # the OBJ engine has 1210 cycles per line, or 954 when DISPCNT's H-Blank
  # Interval Free bit frees the h-blank gap for CPU OAM access. A regular
  # sprite on the line costs `width` cycles, an affine sprite 10 + 2*width
  # (over its double-size footprint); once the budget runs out, later OAM
  # entries do not render at all. The FDS-generation Famicom Mini carts rely
  # on this: they park full-width black masking sprites at the end of OAM
  # behind enough on-line sprites that real hardware never has time to draw
  # them. Costs and cutoff granularity match mGBA (GBAVideoRendererCleanOAM /
  # PreprocessSpriteLayer): the sprite that exhausts the budget still draws
  # fully, subsequent ones are dropped.
  var obj_cycles = if ppu.dispcnt.hblank_interval_free: 954 else: 1210
  for s_idx in 0 ..< num_sprites:
    if obj_cycles <= 0: break
    let sprite = sprites[s_idx]
    if sprite.affine_mode == 0b10: continue
    # Prohibited shape 3 draws nothing but still occupies OBJ time below
    let shape3 = sprite.obj_shape == 3
    var x_coord = cast[int16](bits_range(sprite.attr1, 0, 8))
    var y_coord = cast[int16](bits_range(sprite.attr0, 0, 7))
    if x_coord > 239: x_coord -= 512
    if y_coord > 159: y_coord -= 256
    let orig_width  = if shape3: 0 else: SIZES[sprite.obj_shape][sprite.obj_size][0]
    let orig_height = if shape3: 0 else: SIZES[sprite.obj_shape][sprite.obj_size][1]
    var width  = orig_width
    var height = orig_height
    var center_x = int(x_coord) + width div 2
    var center_y = int(y_coord) + height div 2
    var pa, pb, pc, pd: int
    if bit(sprite.attr0, 8):  # affine
      let oam_affine_entry = int(bits_range(sprite.attr1, 9, 13))
      pa = int(sprites[oam_affine_entry * 4    ].aff_param)
      pb = int(sprites[oam_affine_entry * 4 + 1].aff_param)
      pc = int(sprites[oam_affine_entry * 4 + 2].aff_param)
      pd = int(sprites[oam_affine_entry * 4 + 3].aff_param)
      if bit(sprite.attr0, 9):  # double-size
        center_x += width shr 1
        center_y += height shr 1
        width  = width  shl 1
        height = height shl 1
    else:
      pa = 0x100; pb = 0; pc = 0; pd = 0x100
    let vc = int(ppu.vcount)
    if not (int(y_coord) <= vc and vc < int(y_coord) + height): continue
    # Sprites fully outside the 240px window (raw x in [240, 512-width))
    # never enter the OBJ pipeline: no pixels and no time charged
    if int(x_coord) + width < 0: continue
    # On-line sprite: charge its OBJ rendering time
    obj_cycles -= (if bit(sprite.attr0, 8): 10 + 2 * width else: width)
    if shape3: continue
    # In bitmap modes the lower 16K of OBJ VRAM holds the bitmap, so tiles
    # below 512 don't render (but the sprite still occupies OBJ time)
    if bitmap_mode and int(bits_range(sprite.attr2, 0, 9)) < 512: continue
    # Mosaic sprites sample from the first pixel of each screen-space block
    let obj_mosaic = bit(sprite.attr0, 12)
    let mosaic_h = if obj_mosaic: int(ppu.mosaic.obj_mosiac_h_size) + 1 else: 1
    let vc_m = if obj_mosaic: vc - vc mod (int(ppu.mosaic.obj_mosiac_v_size) + 1) else: vc
    let iy     = vc_m - center_y
    let flip_x = bit(sprite.attr1, 12) and not bit(sprite.attr0, 8)
    let flip_y = bit(sprite.attr1, 13) and not bit(sprite.attr0, 8)
    let min_x  = max(0, int(x_coord))
    let max_x  = min(240, int(x_coord) + width)
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
      # OBJ character fetches wrap within the 32K of OBJ VRAM (matches
      # mGBA's offset mask and NanoBoyAdvance's tile index mask)
      if bit(sprite.attr0, 13):  # 8bpp
        # The attr2 character name always counts 32-byte units. In 1D mapping
        # an odd name starts fetches half a tile in (32 bytes); only 2D
        # mapping forces the low bit clear (matches mGBA's `align` mask and
        # NanoBoyAdvance's CalculateTileNumber8BPP)
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

proc compute_line_enables*(ppu: PPU) =
  # Same per-pixel result as checking win0 -> win1 -> obj window -> outside,
  # but computed once per scanline: paint the lowest-priority source first,
  # then overlay win1, then win0.
  let vc = ppu.vcount
  let dbg_mask = ppu.debug_layer_mask
  let obj_active = ppu.dispcnt.obj_window_display
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
  if ppu.dispcnt.window_1_display and
     window_contains(vc, uint16(ppu.win1v.y1), uint16(ppu.win1v.y2)):
    ppu.fill_window_cols(ppu.win1h,
                         uint16(ppu.winin.window_1_enable_bits) and dbg_mask,
                         ppu.winin.window_1_color_special_effect)
  if ppu.dispcnt.window_0_display and
     window_contains(vc, uint16(ppu.win0v.y1), uint16(ppu.win0v.y2)):
    ppu.fill_window_cols(ppu.win0h,
                         uint16(ppu.winin.window_0_enable_bits) and dbg_mask,
                         ppu.winin.window_0_color_special_effect)

proc compute_layer_walk*(ppu: PPU) =
  # BGs that can contribute this scanline, flattened into a single list in
  # compositing order: priority first, then BG index (hardware picks the
  # lower BG number at equal priority). BGs disabled in DISPCNT never render
  # (their layer_palettes stay 0), so skip them here. Sprites are merged into
  # the walk by comparing their per-pixel priority against each entry's.
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
proc bgr16_spread(c: uint16): uint64 {.inline.} =
  uint64(c and 0x1F) or (uint64(c and 0x3E0) shl 11) or (uint64(c and 0x7C00) shl 22)

const BGR_LANE_MASK = 0xFF'u64 or (0xFF'u64 shl 16) or (0xFF'u64 shl 32)

proc bgr16_pack_sat(v: uint64): uint16 {.inline.} =
  # Saturate each lane at 0x1F, then pack back to BGR555
  var r = v and 0xFFFF'u64
  var g = (v shr 16) and 0xFFFF'u64
  var b = (v shr 32) and 0xFFFF'u64
  if r > 0x1F: r = 0x1F
  if g > 0x1F: g = 0x1F
  if b > 0x1F: b = 0x1F
  uint16(r or (g shl 5) or (b shl 10))

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

# --- Compositing ---------------------------------------------------------
#
# Compositing runs per span of columns that share one window configuration,
# not per pixel. Everything a span holds constant -- which layers the window
# enables, their priority order, where each layer's line buffer starts, and
# whether any colour math can apply at all -- is resolved once at the top of
# `composite_span` and the inner loop then only walks opaque pixels.
#
# The two inner loops differ only in whether colour math is reachable. The
# no-effect loop is the same "first opaque pixel in priority order wins" logic
# the old fast path used, and it is what the great majority of real columns
# take: a window that turns effects off, or a blend configuration whose
# 1st-target set is empty for the layers this window enables, can never change
# a pixel, so searching for a second layer or testing BLDCNT per pixel is pure
# waste. Measured over nine titles, 52-100% of the columns that reach the
# windowed/blending path fall in that class (Emerald from an in-game save
# state: 100%).

type SpanWalk = object
  ## The layer walk filtered down to one span's enabled layers, with
  ## everything that is constant across the span resolved up front.
  n:      int
  prio:   array[4, int32]
  layer:  array[4, int32]
  direct: array[4, bool]                        # bitmap direct-colour BG2
  row:    array[4, ptr UncheckedArray[uint8]]   # layer_palettes[bg] for this line

proc composite_span_opaque(ppu: PPU; w: SpanWalk; row_base: uint32;
                           lo, hi: int; obj_enable: bool) =
  ## Span where no colour math can apply: the first opaque pixel in priority
  ## order is the answer. Instantiated per walk length -- the walk is at most
  ## four entries and its length is fixed for the span, so with the trip count
  ## constant the loop unrolls and each layer's priority and row pointer stays
  ## in a register instead of being re-loaded per pixel. The bitmap
  ## direct-colour test is hoisted the same way; it is false in every tile
  ## mode.
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

proc composite_span(ppu: PPU; row_base: uint32; lo, hi: int;
                    enable_bits: uint16; effects: bool) =
  let obj_enable = bit(enable_bits, 4)
  var w: SpanWalk
  # Layers that can end up on top somewhere in this span. The backdrop always
  # can (every layer may be transparent); OBJ only when the window enables it.
  var appear = 0x20'u16
  if obj_enable: appear = appear or 0x10'u16
  for i in 0 ..< ppu.walk_n:
    let bg = int(ppu.walk_bgs[i])
    if bit(enable_bits, bg):
      let k = w.n
      w.prio[k]   = int32(ppu.walk_prios[i])
      w.layer[k]  = int32(bg)
      w.direct[k] = ppu.bitmap_direct and bg == 2
      w.row[k]    = cast[ptr UncheckedArray[uint8]](addr ppu.layer_palettes[bg][0])
      appear = appear or (1'u16 shl bg)
      w.n = k + 1

  # Can colour math change any pixel in this span? Alpha/brighten/darken all
  # require the top layer to be a BLDCNT 1st target, and a semi-transparent
  # OBJ pixel forces alpha regardless of the blend mode -- so if neither is
  # reachable here, the whole effects apparatus is dead code for this span.
  let can_blend = effects and
    ((obj_enable and ppu.line_sprite_blend) or
     (ppu.bldcnt.blend_mode != 0 and
      (uint16(ppu.bldcnt) and 0x3F'u16 and appear) != 0))
  if not can_blend:
    ppu.composite_span_opaque(w, row_base, lo, hi, obj_enable)
    return

  # Colour math is reachable in this span: find the top layer, then the layer
  # under it when (and only when) the result can depend on it. Kept in this
  # proc rather than split out like the opaque loop, so that the walk stays a
  # plain local the compiler can keep in registers across the pixel loop.
  let pram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.pram[0])
  let fb       = cast[ptr UncheckedArray[uint16]](addr ppu.framebuffer[0])
  let sprites  = cast[ptr UncheckedArray[SpritePixel]](addr ppu.sprite_pixels[0])
  let bg2d     = cast[ptr UncheckedArray[uint16]](addr ppu.bg2_direct[0])
  let bg2o     = cast[ptr UncheckedArray[bool]](addr ppu.bg2_direct_opaque[0])
  let bld        = uint16(ppu.bldcnt)
  let blend_mode = int(ppu.bldcnt.blend_mode)
  let backdrop   = pram_u16[0]

  # Walk the layer list for column `col` starting at `idx`, stopping at the
  # first opaque pixel. `sprio` is the OBJ priority to merge in (4 = no OBJ
  # pixel here, or it was already taken as the layer above).
  template scan(col, idx, sprio, spal, out_layer, out_color, out_blends) =
    out_layer = 5
    out_color = backdrop
    out_blends = false
    block done:
      while idx < w.n:
        if sprio <= w.prio[idx]:
          out_layer = 4
          out_color = pram_u16[0x100 + spal]
          out_blends = sprites[col].blends
          idx = idx or SPRITE_TAKEN
          break done
        if w.direct[idx]:
          if bg2o[col]:
            out_layer = int(w.layer[idx])
            out_color = bg2d[col]
            inc idx
            break done
        else:
          let palette = int(w.row[idx][col])
          if palette != 0:
            out_layer = int(w.layer[idx])
            out_color = pram_u16[palette]
            inc idx
            break done
        inc idx
      # Off the end of the walk: an OBJ pixel behind every BG still beats the
      # backdrop.
      idx = idx or SPRITE_TAKEN
      if sprio < 4:
        out_layer = 4
        out_color = pram_u16[0x100 + spal]
        out_blends = sprites[col].blends

  for col in lo ..< hi:
    let sp = sprites[col]
    let spal = int(sp.palette)
    var sprio = 4'i32
    if obj_enable and spal != 0: sprio = int32(sp.priority)
    # `idx` carries the walk position plus a "OBJ already taken" flag in a
    # spare bit, so the search for the blend bottom resumes where the top left
    # off instead of restarting.
    var idx = 0
    var top_layer: int
    var top_color: uint16
    var top_blends: bool
    scan(col, idx, sprio, spal, top_layer, top_color, top_blends)
    var color = top_color
    # 1st-target = BLDCNT bit `layer`, 2nd-target = bit `layer + 8`. The
    # second layer is only searched when the result can depend on it: a
    # semi-transparent OBJ on top, or alpha blending with a selected top.
    let top_selected = bit(bld, top_layer)
    if top_blends or (top_selected and blend_mode == 1):
      var bsprio = 4'i32
      if (idx and SPRITE_TAKEN) == 0 and obj_enable and spal != 0:
        bsprio = int32(sp.priority)
      var bidx = idx and not SPRITE_TAKEN
      var bot_layer: int
      var bot_color: uint16
      var bot_blends: bool
      scan(col, bidx, bsprio, spal, bot_layer, bot_color, bot_blends)
      if bit(bld, bot_layer + 8):
        color = ppu.blend_colors(top_color, bot_color, 1)
      elif top_blends and top_selected and blend_mode != 1:
        color = ppu.blend_colors(top_color, 0, blend_mode)
    elif top_selected and blend_mode != 0:
      color = ppu.blend_colors(top_color, 0, blend_mode)
    fb[row_base + uint32(col)] = color


proc composite*(ppu: PPU; row_base: uint32) =
  ppu.compute_layer_walk()
  let vc = ppu.vcount
  let dbg_mask = ppu.debug_layer_mask
  # Which window sources actually apply to THIS line? win0/win1 only inside
  # their vertical range, the OBJ window only when a sprite wrote an
  # OBJ-window pixel (tracked in render_sprites, so no per-column scan). When
  # none of them do, every column shares one enable mask and there is no need
  # to build (or read back) the per-column tables at all.
  let win0_on = ppu.dispcnt.window_0_display and
                window_contains(vc, uint16(ppu.win0v.y1), uint16(ppu.win0v.y2))
  let win1_on = ppu.dispcnt.window_1_display and
                window_contains(vc, uint16(ppu.win1v.y1), uint16(ppu.win1v.y2))
  let objwin_on = ppu.dispcnt.obj_window_display and ppu.line_obj_window
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
  ppu.compute_line_enables()
  # Split the line into runs of identical window state and composite each one
  # with the enable mask hoisted out of the pixel loop.
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
  # Render skipping: when a full frame passes without any change to VRAM,
  # PRAM, OAM, or PPU registers, the framebuffer already contains exactly
  # what each scanline would produce, so skip rendering until something
  # changes. A mid-frame change only affects lines from that point down;
  # the untouched lines above still hold correct (identical) pixels.
  if ppu.vcount == 0:
    ppu.skip_render = not ppu.render_dirty
    ppu.render_dirty = false
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
  # Only the BGs DISPCNT enables are worth clearing. A disabled BG is never
  # written (every renderer returns on this same bit) and never read
  # (compute_layer_walk leaves it out of the walk), so its 240 bytes are
  # cleared purely to be ignored. Games leave 1-2 BGs off most of the time --
  # measured across nine titles, 0.5% (Mega Man Battle Network) to 57%
  # (FireRed) of these clears were for BGs not in the walk at all, with most
  # titles around half.
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
  ## Re-run the visible scanline pipeline against the current PPU memory and
  ## register state, without advancing emulation, so a paused frame reflects a
  ## debug_layer_mask change immediately. Faithful for frames whose PPU
  ## configuration was static all frame (the common paused case); frames that
  ## used mid-frame HBlank effects re-render from the final line's registers.
  ## Non-destructive: affine internal references and vcount are restored, so it
  ## is safe to call even while emulation is running.
  let saved_vcount = ppu.vcount
  var saved_bgref_int = ppu.bgref_int
  # Start the affine references at their line-0 values (matching the vblank
  # latch that runs when vcount reaches 160).
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
  # Prime the pipeline so the next real frame after unpause still renders, and
  # force the frontend to re-upload the (now changed) framebuffer.
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
    let preserved = uint8(toU16(ppu.dispstat)) and 0x07'u8
    write(ppu.dispstat, (value and 0xF8'u8) or preserved, 0)
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
