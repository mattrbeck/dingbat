# GB Scanline PPU renderer (included by gb.nim)

proc new_gb_scanline_ppu*(gb: GB): GbScanlinePpu =
  let base = new_ppu_base(gb.cgb_enabled)
  result = GbScanlinePpu(
    lcd_control:  base.lcd_control, lcd_status: base.lcd_status,
    scy: base.scy, scx: base.scx, ly: base.ly, lyc: base.lyc,
    bgp: base.bgp, obp0: base.obp0, obp1: base.obp1, wy: base.wy, wx: base.wx,
    vram: base.vram, vram_bank: base.vram_bank,
    sprite_table: base.sprite_table,
    pram: base.pram, palette_index: base.palette_index, auto_increment: base.auto_increment,
    obj_pram: base.obj_pram, obj_palette_index: base.obj_palette_index,
    obj_auto_increment: base.obj_auto_increment,
    hdma1: base.hdma1, hdma2: base.hdma2, hdma3: base.hdma3,
    hdma4: base.hdma4, hdma5: base.hdma5,
    hdma_src: base.hdma_src, hdma_dst: base.hdma_dst,
    hdma_pos: base.hdma_pos, hdma_active: base.hdma_active,
    window_trigger: base.window_trigger,
    current_window_line: base.current_window_line,
    old_stat_flag: base.old_stat_flag, first_line: base.first_line,
    cycle_counter: base.cycle_counter,
    framebuffer: base.framebuffer, frame: base.frame, ran_bios: base.ran_bios,
  )

proc scanline_get_sprites*(ppu: GbScanlinePpu; gb: GB): seq[GbSprite] =
  result = @[]
  var sprite_addr = 0
  while sprite_addr <= 0x9C:
    let s = GbSprite(
      y:          ppu.sprite_table[sprite_addr],
      x:          ppu.sprite_table[sprite_addr + 1],
      tile_num:   ppu.sprite_table[sprite_addr + 2],
      attributes: ppu.sprite_table[sprite_addr + 3],
      oam_idx:    uint8(sprite_addr),
    )
    if sprite_on_line(s, ppu.ly, sprite_height(ppu)):
      if not gb.cgb_enabled:
        # DMG: sort by X (ascending), so first in array = lowest X = drawn last (on top)
        var idx = 0
        while idx < result.len and s.x >= result[idx].x:
          inc idx
        result.insert(s, idx)
      else:
        result.add(s)
      if result.len >= 10: break
    sprite_addr += 4

proc do_scanline*(ppu: GbScanlinePpu; gb: GB) =
  if ppu.ly == 0: ppu.current_window_line = 0
  var should_increment_window_line = false
  let window_map    = if window_tile_map(ppu) == 0: 0x1800 else: 0x1C00
  let bg_map        = if bg_tile_map(ppu) == 0:     0x1800 else: 0x1C00
  let tile_data_tbl = if bg_window_tile_data(ppu) == 0: 0x1000 else: 0x0000
  let tile_row_win  = ppu.current_window_line and 7
  let tile_row      = (int(ppu.ly) + int(ppu.scy)) and 7

  for x in 0 ..< GB_WIDTH:
    if window_enabled(ppu) and int(ppu.ly) >= int(ppu.wy) and
       x + 7 >= int(ppu.wx) and ppu.window_trigger:
      should_increment_window_line = true
      let tn_addr = window_map + ((x + 7 - int(ppu.wx)) shr 3) +
                    ((ppu.current_window_line shr 3) * 32)
      let raw_tile = ppu.vram[0][tn_addr]
      let tile_num = if bg_window_tile_data(ppu) == 0:
                       int(cast[int8](raw_tile))
                     else: int(raw_tile)
      let tile_ptr = tile_data_tbl + 16 * tile_num
      let bank_num = if gb.cgb_enabled: int((ppu.vram[1][tn_addr] and 0b0000_1000) shr 3) else: 0
      let y_row = if gb.cgb_enabled and (ppu.vram[1][tn_addr] and 0b0100_0000) != 0:
                    7 - tile_row_win else: tile_row_win
      let b1 = ppu.vram[bank_num][tile_ptr + y_row * 2]
      let b2 = ppu.vram[bank_num][tile_ptr + y_row * 2 + 1]
      let col_x = x + 7 - int(ppu.wx)
      let shift = if gb.cgb_enabled and (ppu.vram[1][tn_addr] and 0b0010_0000) != 0:
                    col_x and 7 else: 7 - (col_x and 7)
      let lsb = (b1 shr shift) and 0x1
      let msb = (b2 shr shift) and 0x1
      let color = uint8((msb shl 1) or lsb)
      ppu.scanline_color_vals[x] = (color, (ppu.vram[1][tn_addr] and 0x80) != 0)
      if gb.cgb_enabled:
        let pal_idx = int(ppu.vram[1][tn_addr] and 0b111) * 4 * 2 + int(color) * 2
        ppu.framebuffer[GB_WIDTH * int(ppu.ly) + x] =
          cast[ptr uint16](unsafeAddr ppu.pram[pal_idx])[]
      else:
        let pal_idx = ppu.bgp[color] * 2
        ppu.framebuffer[GB_WIDTH * int(ppu.ly) + x] =
          cast[ptr uint16](unsafeAddr ppu.pram[pal_idx])[]

    elif bg_display(ppu) or gb.cgb_enabled:
      let tn_addr = bg_map +
                    (((x + int(ppu.scx)) shr 3) and 0x1F) +
                    ((((int(ppu.ly) + int(ppu.scy)) shr 3) * 32) and 0x3FF)
      let raw_tile = ppu.vram[0][tn_addr]
      let tile_num = if bg_window_tile_data(ppu) == 0:
                       int(cast[int8](raw_tile))
                     else: int(raw_tile)
      let tile_ptr = tile_data_tbl + 16 * tile_num
      let bank_num = if gb.cgb_enabled: int((ppu.vram[1][tn_addr] and 0b0000_1000) shr 3) else: 0
      let y_row = if gb.cgb_enabled and (ppu.vram[1][tn_addr] and 0b0100_0000) != 0:
                    7 - tile_row else: tile_row
      let b1 = ppu.vram[bank_num][tile_ptr + y_row * 2]
      let b2 = ppu.vram[bank_num][tile_ptr + y_row * 2 + 1]
      let col_x = x + int(ppu.scx)
      let shift = if gb.cgb_enabled and (ppu.vram[1][tn_addr] and 0b0010_0000) != 0:
                    col_x and 7 else: 7 - (col_x and 7)
      let lsb = (b1 shr shift) and 0x1
      let msb = (b2 shr shift) and 0x1
      let color = uint8((msb shl 1) or lsb)
      ppu.scanline_color_vals[x] = (color, (ppu.vram[1][tn_addr] and 0x80) != 0)
      if gb.cgb_enabled:
        let pal_idx = int(ppu.vram[1][tn_addr] and 0b111) * 4 * 2 + int(color) * 2
        ppu.framebuffer[GB_WIDTH * int(ppu.ly) + x] =
          cast[ptr uint16](unsafeAddr ppu.pram[pal_idx])[]
      else:
        let pal_idx = ppu.bgp[color] * 2
        ppu.framebuffer[GB_WIDTH * int(ppu.ly) + x] =
          cast[ptr uint16](unsafeAddr ppu.pram[pal_idx])[]

  if should_increment_window_line: inc ppu.current_window_line

  if sprite_enabled(ppu):
    for s in scanline_get_sprites(ppu, gb):
      let (b_lo, b_hi) = sprite_tile_bytes(s, ppu.ly, sprite_height(ppu))
      let bank = if gb.cgb_enabled: int(sprite_bank_num(s)) else: 0
      for col in 0 ..< 8:
        let x = col + int(s.x) - 8
        if x < 0 or x >= GB_WIDTH: continue
        let shift = if sprite_x_flip(s): col else: 7 - col
        let lsb = (ppu.vram[bank][b_lo] shr shift) and 0x1
        let msb = (ppu.vram[bank][b_hi] shr shift) and 0x1
        let color = uint8((msb shl 1) or lsb)
        if color > 0:
          if gb.cgb_enabled:
            if not bg_display(ppu) or ppu.scanline_color_vals[x].color == 0 or
               (not ppu.scanline_color_vals[x].priority and sprite_priority(s) == 0):
              let pal_idx = int(sprite_cgb_palette(s)) * 4 * 2 + int(color) * 2
              ppu.framebuffer[GB_WIDTH * int(ppu.ly) + x] =
                cast[ptr uint16](unsafeAddr ppu.obj_pram[pal_idx])[]
          else:
            if sprite_priority(s) == 0 or ppu.scanline_color_vals[x].color == 0:
              let palette = if sprite_dmg_palette(s) == 0: ppu.obp0 else: ppu.obp1
              let pal_idx = palette[color] * 2
              ppu.framebuffer[GB_WIDTH * int(ppu.ly) + x] =
                cast[ptr uint16](unsafeAddr ppu.obj_pram[pal_idx])[]

method tick*(ppu: GbScanlinePpu; gb: GB; cycles: int) =
  # Snapshot the mode as observed by a CPU read that samples during this M-cycle
  # (read_byte runs after this whole tick advances the PPU). See GbPpu.read_mode.
  ppu.read_mode = ppu.mode_flag
  # See the FIFO renderer: the panel's refresh clock runs on both paths.
  ppu.dots_since_frame += int32(cycles)
  when defined(gb_dot_counter): gb_total_dots += uint64(cycles)
  ppu.cycle_counter += int32(cycles)
  if lcd_enabled(ppu):
    if ppu.mode_flag == 2:       # OAM search
      if ppu.cycle_counter >= 80:
        ppu.cycle_counter -= 80
        ppu.`mode_flag=`(3'u8, gb)
        if ppu.ly == ppu.wy: ppu.window_trigger = true
    elif ppu.mode_flag == 3:     # Drawing
      if ppu.cycle_counter >= 172:
        ppu.cycle_counter -= 172
        ppu.`mode_flag=`(0'u8, gb)
        do_scanline(ppu, gb)
    elif ppu.mode_flag == 0:     # H-Blank
      if ppu.cycle_counter >= 204:
        ppu.cycle_counter -= 204
        ppu.ly += 1
        if int(ppu.ly) == GB_HEIGHT:
          ppu.`mode_flag=`(1'u8, gb)
          gb.interrupts.vblank_interrupt = true
          ppu.frame = true
          when defined(gb_dot_counter): inc gb_frame_normal
          ppu.dots_since_frame = 0
        else:
          ppu.`mode_flag=`(2'u8, gb)
    elif ppu.mode_flag == 1:     # V-Blank
      if ppu.cycle_counter >= 456:
        ppu.cycle_counter -= 456
        if ppu.ly != 0: ppu.ly += 1
        ppu_handle_stat_interrupt(ppu, gb)
        if ppu.ly == 0:
          ppu.`mode_flag=`(2'u8, gb)
      if ppu.ly == 153 and ppu.cycle_counter > 4: ppu.ly = 0
  else:
    ppu.cycle_counter = 0
    ppu.`mode_flag=`(0'u8, gb)
    ppu.ly = 0
    lcd_off_frame(ppu, gb)
