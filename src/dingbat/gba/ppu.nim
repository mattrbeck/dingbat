# PPU implementation (included by gba.nim)

const SPRITE_PIXEL_DEFAULT* = SpritePixel(priority: 4, palette: 0, blends: false, window: false)

# SIZES[shape][size] = (width, height)
const SIZES*: array[3, array[4, array[2, int]]] = [
  [[8,8],   [16,16], [32,32], [64,64]],  # square
  [[16,8],  [32,8],  [32,16], [64,32]],  # horizontal rectangle
  [[8,16],  [8,32],  [16,32], [32,64]],  # vertical rectangle
]

proc new_ppu*(gba: GBA): PPU =
  result = PPU(gba: gba)
  result.framebuffer    = newSeq[uint16](0x9600)
  result.frame          = false
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
    result.bgaff[i][0] = BGAFF()
    result.bgaff[i][1] = BGAFF()
    result.bgaff[i][2] = BGAFF()
    result.bgaff[i][3] = BGAFF()
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
  ppu.frame = true
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
  var prev_tile_x: uint32 = 0xFFFFFFFF'u32
  var screen_entry: uint16
  var tile_id: uint16
  var flip_x_mask: int
  var y: int
  var tile_base_8bpp: uint32
  var tile_base_4bpp: uint32
  var palette_bank_shift: uint32
  for col in 0..239:
    let effective_col = (uint32(col) + uint32(bghofs.offset)) and uint32(bg_width)
    let tile_x        = effective_col shr 3
    if tile_x != prev_tile_x:
      prev_tile_x = tile_x
      let se_idx = ty_base + int(tile_x) + (if int(tile_x) >= 32: 0x03E0 else: 0) + ty_extra
      screen_entry = uint16(ppu.vram[screen_base + uint32(se_idx) * 2 + 1]) shl 8 or
                     uint16(ppu.vram[screen_base + uint32(se_idx) * 2])
      tile_id = bits_range(screen_entry, 0, 9)
      flip_x_mask = 7 * int(screen_entry shr 10 and 1)
      y = int(row_in_tile) xor (7 * int(screen_entry shr 11 and 1))
      if is_8bpp:
        tile_base_8bpp = character_base + uint32(tile_id) * 0x40 + uint32(y) * 8
      else:
        tile_base_4bpp = character_base + uint32(tile_id) * 0x20 + uint32(y) * 4
        palette_bank_shift = uint32(bits_range(screen_entry, 12, 15)) shl 4
    let x = int(effective_col and 7) xor flip_x_mask
    var pal_idx: uint32
    if is_8bpp:
      # The BG unit can't fetch character data from OBJ VRAM; such tiles
      # render transparent (row bases are 4-byte aligned, so checking the
      # row start suffices)
      if tile_base_8bpp >= 0x10000'u32:
        pal_idx = 0
      else:
        pal_idx = uint32(ppu.vram[tile_base_8bpp + uint32(x)])
    else:
      if tile_base_4bpp >= 0x10000'u32:
        pal_idx = 0
      else:
        let palettes = ppu.vram[tile_base_4bpp + (uint32(x) shr 1)]
        pal_idx = uint32((palettes shr (uint32(x and 1) * 4)) and 0xF)
        if pal_idx > 0: pal_idx += palette_bank_shift
    ppu.layer_palettes[bg][col] = uint8(pal_idx)
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
  let mode = int(ppu.dispcnt.bg_mode)
  ppu.bitmap_direct = mode != 4
  for col in 0..239: ppu.bg2_direct_opaque[col] = false
  if not bit(uint16(ppu.dispcnt), 10): return  # BG2 disabled
  var row = uint32(ppu.vcount)
  if ppu.bgcnt[2].mosaic:
    row -= row mod (uint32(ppu.mosaic.bg_mosiac_v_size) + 1)
  case mode
  of 3:
    let vram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.vram[0])
    for col in 0..239:
      ppu.bg2_direct[col] = vram_u16[row * 240 + uint32(col)]
      ppu.bg2_direct_opaque[col] = true
  of 4:
    let base: uint32 = if ppu.dispcnt.display_frame_select: 0xA000'u32 else: 0
    for col in 0..239:
      ppu.layer_palettes[2][col] = ppu.vram[base + row * 240 + uint32(col)]
  of 5:
    if row < 128:
      let base: uint32 = if ppu.dispcnt.display_frame_select: 0xA000'u32 else: 0
      let vram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.vram[base])
      for col in 0..159:
        ppu.bg2_direct[col] = vram_u16[row * 160 + uint32(col)]
        ppu.bg2_direct_opaque[col] = true
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
  for s_idx in 0 ..< num_sprites:
    let sprite = sprites[s_idx]
    if sprite.obj_shape == 3: continue
    if sprite.affine_mode == 0b10: continue
    # In bitmap modes the lower 16K of OBJ VRAM holds the bitmap, so tiles
    # below 512 don't render
    if bitmap_mode and int(bits_range(sprite.attr2, 0, 9)) < 512: continue
    var x_coord = cast[int16](bits_range(sprite.attr1, 0, 8))
    var y_coord = cast[int16](bits_range(sprite.attr0, 0, 7))
    if x_coord > 239: x_coord -= 512
    if y_coord > 159: y_coord -= 256
    let orig_width  = SIZES[sprite.obj_shape][sprite.obj_size][0]
    let orig_height = SIZES[sprite.obj_shape][sprite.obj_size][1]
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
        tile_id = tile_id shr 1
        tile_id += offset
        pal_idx = uint32(ppu.vram[base + ((uint32(tile_id) * 0x40 + uint32(tile_y) * 8 + uint32(tile_x)) and 0x7FFF)])
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

proc next_layer(ppu: PPU; pram_u16: ptr UncheckedArray[uint16];
                enable_bits: uint16; col: int;
                pos: var int): tuple[layer: int, color: uint16, blends: bool] =
  ## Scan the flattened layer walk starting at `pos` and return the next
  ## opaque pixel; layer 5 is the backdrop. `pos` encodes the walk index in
  ## its upper bits and "sprite already taken" in bit 0, so a caller can
  ## resume the walk to find the second layer for blending. The sprite layer
  ## sits in front of the first walk entry whose priority is >= the sprite's
  ## (slot 0 of each priority on hardware).
  let sp = ppu.sprite_pixels[col]
  var sprio = 4
  if (pos and 1) == 0 and bit(enable_bits, 4) and sp.palette != 0:
    sprio = int(sp.priority)
  let taken = pos and 1
  var idx = pos shr 1
  while idx < ppu.walk_n:
    if sprio <= int(ppu.walk_prios[idx]):
      pos = (idx shl 1) or 1
      return (4, pram_u16[0x100 + int(sp.palette)], sp.blends)
    let bg = int(ppu.walk_bgs[idx])
    inc idx
    if bit(enable_bits, bg):
      if ppu.bitmap_direct and bg == 2:
        if ppu.bg2_direct_opaque[col]:
          pos = (idx shl 1) or taken
          return (2, ppu.bg2_direct[col], false)
      else:
        let palette = int(ppu.layer_palettes[bg][col])
        if palette != 0:
          pos = (idx shl 1) or taken
          return (bg, pram_u16[palette], false)
  pos = (idx shl 1) or 1
  if sprio < 4:
    return (4, pram_u16[0x100 + int(sp.palette)], sp.blends)
  (5, pram_u16[0], false)

proc composite*(ppu: PPU; row_base: uint32) =
  ppu.compute_layer_walk()
  let pram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.pram[0])
  let windows_active = ppu.dispcnt.window_0_display or
                       ppu.dispcnt.window_1_display or
                       ppu.dispcnt.obj_window_display
  let blending_possible = ppu.bldcnt.blend_mode != 0 or ppu.line_sprite_blend
  if not windows_active and not blending_possible:
    # Fast path (most scanlines): every layer is enabled screen-wide and no
    # color math can apply, so the first opaque pixel in priority order wins
    let obj_enable = bit(uint16(ppu.dispcnt.default_enable_bits), 4) and
                     bit(ppu.debug_layer_mask, 4)
    let walk_n = ppu.walk_n
    for col in 0 .. 239:
      let sp = ppu.sprite_pixels[col]
      var sprio = 4
      if obj_enable and sp.palette != 0: sprio = int(sp.priority)
      var color = pram_u16[0]
      block found:
        for i in 0 ..< walk_n:
          if sprio <= int(ppu.walk_prios[i]):
            color = pram_u16[0x100 + int(sp.palette)]
            break found
          let bg = int(ppu.walk_bgs[i])
          if ppu.bitmap_direct and bg == 2:
            if ppu.bg2_direct_opaque[col]:
              color = ppu.bg2_direct[col]
              break found
          else:
            let palette = int(ppu.layer_palettes[bg][col])
            if palette != 0:
              color = pram_u16[palette]
              break found
        if sprio < 4:
          color = pram_u16[0x100 + int(sp.palette)]
      ppu.framebuffer[row_base + uint32(col)] = color
  else:
    if windows_active:
      ppu.compute_line_enables()
    else:
      let bits = uint16(ppu.dispcnt.default_enable_bits) and ppu.debug_layer_mask
      for col in 0 .. 239:
        ppu.line_enables[col] = bits
        ppu.line_effects[col] = true
    let bld = uint16(ppu.bldcnt)
    let blend_mode = int(ppu.bldcnt.blend_mode)
    for col in 0 .. 239:
      let enable_bits = ppu.line_enables[col]
      var pos = 0
      let (top_layer, top_color, top_blends) =
        ppu.next_layer(pram_u16, enable_bits, col, pos)
      var color = top_color
      if ppu.line_effects[col]:
        # 1st-target = bldcnt bit `layer`, 2nd-target = bit `layer + 8`.
        # The second layer is only searched when the result can depend on it:
        # a semi-transparent sprite on top, or alpha blending with a selected
        # top layer.
        let top_selected = bit(bld, top_layer)
        if top_blends:
          let (bot_layer, bot_color, _) =
            ppu.next_layer(pram_u16, enable_bits, col, pos)
          if bit(bld, bot_layer + 8):
            color = ppu.blend_colors(top_color, bot_color, 1)
          elif top_selected and blend_mode != 1:
            color = ppu.blend_colors(top_color, 0, blend_mode)
        elif top_selected:
          if blend_mode == 1:
            let (bot_layer, bot_color, _) =
              ppu.next_layer(pram_u16, enable_bits, col, pos)
            if bit(bld, bot_layer + 8):
              color = ppu.blend_colors(top_color, bot_color, 1)
          elif blend_mode != 0:
            color = ppu.blend_colors(top_color, 0, blend_mode)
      ppu.framebuffer[row_base + uint32(col)] = color

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
  for bg in 0..3:
    for c in 0..239: ppu.layer_palettes[bg][c] = 0
  for c in 0..239: ppu.sprite_pixels[c] = SPRITE_PIXEL_DEFAULT
  ppu.bitmap_direct = false
  ppu.line_sprite_blend = false
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
