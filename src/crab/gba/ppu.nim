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
  result.dispcnt        = DISPCNT(value: 0)
  result.dispstat       = DISPSTAT(value: 0)
  result.vcount         = 0
  for i in 0..3:
    result.bgcnt[i]  = BGCNT(value: 0)
    result.bghofs[i] = BGOFS(value: 0)
    result.bgvofs[i] = BGOFS(value: 0)
  for i in 0..1:
    result.bgaff[i][0] = BGAFF(value: 0)
    result.bgaff[i][1] = BGAFF(value: 0)
    result.bgaff[i][2] = BGAFF(value: 0)
    result.bgaff[i][3] = BGAFF(value: 0)
    result.bgref[i][0] = BGREF(value: 0)
    result.bgref[i][1] = BGREF(value: 0)
    result.bgref_int[i][0] = 0
    result.bgref_int[i][1] = 0
  result.win0h   = WINH(value: 0)
  result.win1h   = WINH(value: 0)
  result.win0v   = WINV(value: 0)
  result.win1v   = WINV(value: 0)
  result.winin   = WININ(value: 0)
  result.winout  = WINOUT(value: 0)
  result.mosaic  = MOSAIC(value: 0)
  result.bldcnt  = BLDCNT(value: 0)
  result.bldalpha = BLDALPHA(value: 0)
  result.bldy    = BLDY(value: 0)
  for i in 0..3:
    result.layer_palettes[i] = newSeq[byte](240)
  for i in 0..239:
    result.sprite_pixels[i] = SPRITE_PIXEL_DEFAULT
  result.start_line()

proc bitmap*(ppu: PPU): bool =
  ppu.dispcnt.bg_mode >= 3

proc start_line*(ppu: PPU) =
  let g = ppu.gba
  g.scheduler.schedule(960, proc() {.closure.} = ppu.start_hblank(), etPPU)

proc start_hblank*(ppu: PPU) =
  let g = ppu.gba
  g.scheduler.schedule(272, proc() {.closure.} = ppu.end_hblank(), etPPU)
  ppu.dispstat.hblank = true
  if ppu.dispstat.hblank_irq_enable:
    ppu.gba.interrupts.reg_if.hblank = true
    ppu.gba.interrupts.schedule_interrupt_check()
  if ppu.vcount < 160:
    ppu.scanline()
    for bg_num in 0..1:
      ppu.bgref_int[bg_num][0] += ppu.bgaff[bg_num][1].num  # bgx += dmx
      ppu.bgref_int[bg_num][1] += ppu.bgaff[bg_num][3].num  # bgy += dmy
    g.dma.trigger_hdma()

proc end_hblank*(ppu: PPU) =
  let g = ppu.gba
  g.scheduler.schedule(0, proc() {.closure.} = ppu.start_line(), etPPU)
  ppu.dispstat.hblank = false
  ppu.vcount = uint16((int(ppu.vcount) + 1) mod 228)
  ppu.dispstat.vcounter = (ppu.vcount == uint16(ppu.dispstat.vcount_setting))
  if ppu.dispstat.vcounter_irq_enable and ppu.dispstat.vcounter:
    ppu.gba.interrupts.reg_if.vcounter = true
  if ppu.vcount == 227:
    ppu.dispstat.vblank = false
  elif ppu.vcount == 160:
    ppu.dispstat.vblank = true
    g.dma.trigger_vdma()
    if ppu.dispstat.vblank_irq_enable:
      ppu.gba.interrupts.reg_if.vblank = true
    for bg_num in 0..1:
      for ref_num in 0..1:
        ppu.bgref_int[bg_num][ref_num] = ppu.bgref[bg_num][ref_num].num
    ppu.draw()
  g.interrupts.schedule_interrupt_check()

proc draw*(ppu: PPU) =
  ppu.frame = true

proc se_address*(ppu: PPU; tx, ty, screen_size: int): int =
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

proc bgr16_mul*(a: uint16; f: float): uint16 =
  new_bgr16(int(float(bgr16_blue(a))  * f),
            int(float(bgr16_green(a)) * f),
            int(float(bgr16_red(a))   * f))

proc sprites_ptr*(ppu: PPU): ptr UncheckedArray[Sprite] =
  cast[ptr UncheckedArray[Sprite]](addr ppu.oam[0])

proc render_reg_bg*(ppu: PPU; bg: int) =
  if not bit(ppu.dispcnt.value, 8 + bg): return
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
  let effective_row   = (uint32(ppu.vcount) + uint32(bgvofs.offset)) and uint32(bg_height)
  let tile_y          = effective_row shr 3
  for col in 0..239:
    let effective_col = (uint32(col) + uint32(bghofs.offset)) and uint32(bg_width)
    let tile_x        = effective_col shr 3
    let se_idx        = ppu.se_address(int(tile_x), int(tile_y), int(bgcnt.screen_size))
    let screen_entry  = uint16(ppu.vram[screen_base + uint32(se_idx) * 2 + 1]) shl 8 or
                        uint16(ppu.vram[screen_base + uint32(se_idx) * 2])
    let tile_id       = bits_range(screen_entry, 0, 9)
    let y             = int(effective_row and 7) xor (7 * int(screen_entry shr 11 and 1))
    let x             = int(effective_col and 7) xor (7 * int(screen_entry shr 10 and 1))
    var pal_idx: uint32
    if bgcnt.color_mode_8bpp:
      pal_idx = uint32(ppu.vram[character_base + uint32(tile_id) * 0x40 + uint32(y) * 8 + uint32(x)])
    else:
      let palette_bank = bits_range(screen_entry, 12, 15)
      let palettes     = ppu.vram[character_base + uint32(tile_id) * 0x20 + uint32(y) * 4 + (uint32(x) shr 1)]
      pal_idx = uint32((palettes shr (uint32(x and 1) * 4)) and 0xF)
      if pal_idx > 0: pal_idx += uint32(palette_bank) shl 4
    ppu.layer_palettes[bg][col] = uint8(pal_idx)

proc render_aff_bg*(ppu: PPU; bg: int) =
  if not bit(ppu.dispcnt.value, 8 + bg): return
  let bgcnt = ppu.bgcnt[bg]
  let bg_idx = bg - 2
  let dx = ppu.bgaff[bg_idx][0].num
  let dy = ppu.bgaff[bg_idx][2].num
  var int_x = ppu.bgref_int[bg_idx][0]
  var int_y = ppu.bgref_int[bg_idx][1]
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

proc render_sprites*(ppu: PPU) =
  if not bit(ppu.dispcnt.value, 12): return
  let base = 0x10000'u32
  let sprites = ppu.sprites_ptr()
  let num_sprites = 128  # OAM has 128 sprites
  for s_idx in 0 ..< num_sprites:
    let sprite = sprites[s_idx]
    if sprite.obj_shape == 3: continue
    if sprite.affine_mode == 0b10: continue
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
    let iy     = vc - center_y
    let flip_x = bit(sprite.attr1, 12) and not bit(sprite.attr0, 8)
    let flip_y = bit(sprite.attr1, 13) and not bit(sprite.attr0, 8)
    let min_x  = max(0, int(x_coord))
    let max_x  = min(240, int(x_coord) + width)
    for ix in (-(width div 2)) ..< (width div 2):
      let col = center_x + ix
      if col < min_x or col >= max_x: continue
      var tex_x = (pa * ix + pb * iy) shr 8
      var tex_y = (pc * ix + pd * iy) shr 8
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
      if bit(sprite.attr0, 13):  # 8bpp
        tile_id = tile_id shr 1
        tile_id += offset
        pal_idx = uint32(ppu.vram[base + uint32(tile_id) * 0x40 + uint32(tile_y) * 8 + uint32(tile_x)])
      else:
        tile_id += offset
        let palettes = ppu.vram[base + uint32(tile_id) * 0x20 + uint32(tile_y) * 4 + (uint32(tile_x) shr 1)]
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

proc get_enables*(ppu: PPU; col: int): tuple[enable_bits: uint16, effects_enabled: bool] =
  let vc = ppu.vcount
  if ppu.dispcnt.window_0_display and
     uint16(col) >= ppu.win0h.x1 and uint16(col) < ppu.win0h.x2 and
     vc >= uint16(ppu.win0v.y1) and vc < uint16(ppu.win0v.y2):
    (uint16(ppu.winin.window_0_enable_bits), ppu.winin.window_0_color_special_effect)
  elif ppu.dispcnt.window_1_display and
       uint16(col) >= ppu.win1h.x1 and uint16(col) < ppu.win1h.x2 and
       vc >= uint16(ppu.win1v.y1) and vc < uint16(ppu.win1v.y2):
    (uint16(ppu.winin.window_1_enable_bits), ppu.winin.window_1_color_special_effect)
  elif ppu.dispcnt.obj_window_display and ppu.sprite_pixels[col].window:
    (uint16(ppu.winout.obj_window_enable_bits), ppu.winout.obj_window_color_special_effect)
  elif ppu.dispcnt.window_0_display or ppu.dispcnt.window_1_display or ppu.dispcnt.obj_window_display:
    (uint16(ppu.winout.outside_enable_bits), ppu.winout.outside_color_special_effect)
  else:
    (uint16(ppu.dispcnt.default_enable_bits), true)

proc blend_colors*(ppu: PPU; top_u16, bot_u16: uint16; blend_mode: int): uint16 =
  case blend_mode
  of 0: top_u16  # None
  of 1:          # Blend
    let eva = float(min(16, int(ppu.bldalpha.eva_coefficient))) / 16.0
    let evb = float(min(16, int(ppu.bldalpha.evb_coefficient))) / 16.0
    bgr16_add(bgr16_mul(top_u16, eva), bgr16_mul(bot_u16, evb))
  of 2:          # Brighten
    let evy = float(min(16, int(ppu.bldy.evy_coefficient))) / 16.0
    bgr16_add(top_u16, bgr16_mul(bgr16_sub(0xFFFF'u16, top_u16), evy))
  of 3:          # Darken
    let evy = float(min(16, int(ppu.bldy.evy_coefficient))) / 16.0
    bgr16_sub(top_u16, bgr16_mul(top_u16, evy))
  else: top_u16

proc blend_top_bot*(ppu: PPU; top: GbaColor; bot: GbaColor; effects_enabled: bool): uint16 =
  let pram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.pram[0])
  let top_u16 = pram_u16[top.palette]
  if effects_enabled:
    let bot_u16 = pram_u16[bot.palette]
    let top_selected = ppu.bldcnt.layer_target(top.layer, 1)
    let bot_selected = ppu.bldcnt.layer_target(bot.layer, 2)
    let blend_mode   = ppu.bldcnt.blend_mode
    if top.special_handling and bot_selected:
      return ppu.blend_colors(top_u16, bot_u16, 1)  # Blend
    elif top_selected and (bot_selected or blend_mode != 1):
      return ppu.blend_colors(top_u16, bot_u16, int(blend_mode))
  top_u16

proc select_top_colors*(ppu: PPU; enable_bits: uint16; col: int): tuple[top: GbaColor, bot: GbaColor] =
  let sprite = ppu.sprite_pixels[col]
  let backdrop = GbaColor(palette: 0, layer: 5, special_handling: false)
  var top_color: GbaColor = GbaColor(palette: -1, layer: 0, special_handling: false)
  var found_top = false
  for priority in 0..3:
    if bit(enable_bits, 4) and int(sprite.priority) == priority and sprite.palette != 0:
      let color = GbaColor(palette: int(sprite.palette) + 0x100, layer: 4, special_handling: sprite.blends)
      if not found_top:
        top_color = color; found_top = true
      else:
        return (top_color, color)
    for bg in 0..3:
      if bit(enable_bits, bg) and int(ppu.bgcnt[bg].priority) == priority:
        let palette = int(ppu.layer_palettes[bg][col])
        if palette == 0: continue
        let color = GbaColor(palette: palette, layer: bg, special_handling: false)
        if not found_top:
          top_color = color; found_top = true
        else:
          return (top_color, color)
  if found_top:
    (top_color, backdrop)
  else:
    (backdrop, backdrop)

proc calculate_color*(ppu: PPU; col: int): uint16 =
  let (enable_bits, effects_enabled) = ppu.get_enables(col)
  let (top, bot) = ppu.select_top_colors(enable_bits, col)
  ppu.blend_top_bot(top, bot, effects_enabled)

proc composite*(ppu: PPU; row_base: uint32) =
  for col in 0..239:
    ppu.framebuffer[row_base + uint32(col)] = ppu.calculate_color(col)

proc scanline*(ppu: PPU) =
  let row      = uint32(ppu.vcount)
  let row_base = 240'u32 * row
  # clear scanline
  for c in 0..239: ppu.framebuffer[row_base + uint32(c)] = 0
  for bg in 0..3:
    for c in 0..239: ppu.layer_palettes[bg][c] = 0
  for c in 0..239: ppu.sprite_pixels[c] = SPRITE_PIXEL_DEFAULT
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
  of 3:
    let vram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.vram[0])
    for col in 0..239:
      ppu.framebuffer[row_base + uint32(col)] = vram_u16[row_base + uint32(col)]
  of 4:
    let base: uint32 = if ppu.dispcnt.display_frame_select: 0xA000'u32 else: 0
    let pram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.pram[0])
    for col in 0..239:
      let pal_idx = ppu.vram[base + row_base + uint32(col)]
      ppu.framebuffer[row_base + uint32(col)] = pram_u16[pal_idx]
  of 5:
    let base: uint32 = if ppu.dispcnt.display_frame_select: 0xA000'u32 else: 0
    let pram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.pram[0])
    let background_color = pram_u16[0]
    if ppu.vcount < 128:
      for col in 0..159:
        let vram_u16 = cast[ptr UncheckedArray[uint16]](addr ppu.vram[base])
        ppu.framebuffer[row_base + uint32(col)] = vram_u16[row * 160 + uint32(col)]
      for col in 160..239:
        ppu.framebuffer[row_base + uint32(col)] = background_color
    else:
      for col in 0..239:
        ppu.framebuffer[row_base + uint32(col)] = background_color
  else:
    raise newException(Exception, "Invalid background mode: " & $ppu.dispcnt.bg_mode)

proc `[]`*(ppu: PPU; io_addr: uint32): uint8 =
  case io_addr
  of 0x000..0x001: ppu.dispcnt.read_byte(io_addr and 1)
  of 0x002..0x003: 0'u8  # green swap
  of 0x004..0x005: ppu.dispstat.read_byte(io_addr and 1)
  of 0x006..0x007: uint8(ppu.vcount shr (8 * (io_addr and 1)))
  of 0x008..0x00F:
    let bg_num = int((io_addr - 0x008) shr 1)
    var val = ppu.bgcnt[bg_num].read_byte(io_addr and 1)
    if (io_addr == 0xD or io_addr == 0xF) and ppu.bgcnt[bg_num].affine_wrap:
      val = val or 0x20'u8
    val
  of 0x048..0x049: ppu.winin.read_byte(io_addr and 1)
  of 0x04A..0x04B: ppu.winout.read_byte(io_addr and 1)
  of 0x050..0x051: ppu.bldcnt.read_byte(io_addr and 1)
  of 0x052..0x053: ppu.bldalpha.read_byte(io_addr and 1)
  else: ppu.gba.bus.read_open_bus_value(io_addr)

proc `[]=`*(ppu: PPU; io_addr: uint32; value: uint8) =
  case io_addr
  of 0x000..0x001: ppu.dispcnt.write_byte(io_addr and 1, value)
  of 0x002..0x003: discard  # green swap
  of 0x004..0x005: ppu.dispstat.write_byte(io_addr and 1, value)
  of 0x006..0x007: discard  # vcount
  of 0x008..0x00F: ppu.bgcnt[int((io_addr - 0x008) shr 1)].write_byte(io_addr and 1, value)
  of 0x010..0x01F:
    let bg_num = int((io_addr - 0x010) shr 2)
    if bit(io_addr, 1):
      ppu.bgvofs[bg_num].write_byte(io_addr and 1, value)
    else:
      ppu.bghofs[bg_num].write_byte(io_addr and 1, value)
  of 0x020..0x03F:
    let bg_num = int((io_addr and 0x10) shr 4)
    let offs   = int(io_addr and 0xF)
    if offs >= 8:
      let o = offs - 8
      ppu.bgref[bg_num][o shr 2].write_byte(uint32(o and 3), value)
      ppu.bgref_int[bg_num][o shr 2] = ppu.bgref[bg_num][o shr 2].num
    else:
      ppu.bgaff[bg_num][offs shr 1].write_byte(uint32(offs and 1), value)
  of 0x040..0x041: ppu.win0h.write_byte(io_addr and 1, value)
  of 0x042..0x043: ppu.win1h.write_byte(io_addr and 1, value)
  of 0x044..0x045: ppu.win0v.write_byte(io_addr and 1, value)
  of 0x046..0x047: ppu.win1v.write_byte(io_addr and 1, value)
  of 0x048..0x049: ppu.winin.write_byte(io_addr and 1, value)
  of 0x04A..0x04B: ppu.winout.write_byte(io_addr and 1, value)
  of 0x04C..0x04D: ppu.mosaic.write_byte(io_addr and 1, value)
  of 0x050..0x051: ppu.bldcnt.write_byte(io_addr and 1, value)
  of 0x052..0x053: ppu.bldalpha.write_byte(io_addr and 1, value)
  of 0x054..0x055: ppu.bldy.write_byte(io_addr and 1, value)
  else: discard
