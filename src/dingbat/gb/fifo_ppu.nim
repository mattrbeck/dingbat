# GB FIFO PPU renderer (included by gb.nim)

proc new_gb_fifo_ppu*(gb: GB): GbFifoPpu =
  let base = new_ppu_base(gb.cgb_enabled)
  result = GbFifoPpu(
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
    current_window_line: -1,
    old_stat_flag: base.old_stat_flag, first_line: base.first_line,
    cycle_counter: base.cycle_counter,
    framebuffer: base.framebuffer, frame: base.frame, ran_bios: base.ran_bios,
    sprites: @[],
  )

method reset_render_scratch*(ppu: GbFifoPpu) =
  ## Clear the FIFO/fetcher scratch to its clean pre-line state so a state
  ## load onto a running core can't leave a runaway lx or stale FIFO
  ## contents. Bit-identical to normal operation: none of this is read at
  ## vblank (where states are captured), and it is fully reset again on the
  ## next mode 2->3 transition.
  fifo_clear(ppu.fifo)
  fifo_clear(ppu.fifo_sprite)
  ppu.fetch_counter = 0
  ppu.fetch_counter_sprite = 0
  ppu.fetcher_x = 0
  ppu.lx = 0
  ppu.smooth_scroll_sampled = false
  ppu.dropped_first_fetch = false
  ppu.fetching_window = false
  ppu.fetching_sprite = false
  ppu.sprite_fetch_phase = 0
  ppu.bg_pixels_pushed = false
  ppu.scx_penalty_remaining = 0
  ppu.tile_num = 0
  ppu.tile_attrs = 0
  ppu.tile_data_low = 0
  ppu.tile_data_high = 0
  ppu.sprites = @[]

proc fifo_get_sprites*(ppu: GbFifoPpu; gb: GB): seq[GbSprite] =
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
      # Sort ascending by X
      var idx = 0
      while idx < result.len and s.x >= result[idx].x: inc idx
      result.insert(s, idx)
      if result.len >= 10: break
    sprite_addr += 4

proc fifo_sample_smooth_scroll*(ppu: GbFifoPpu) =
  ppu.smooth_scroll_sampled = true
  if ppu.fetching_window:
    ppu.lx = int32(-max(0, 7 - int(ppu.wx)))
    if ppu.wx == 0 and (ppu.scx and 7) > 0:
      ppu.lx += 1
  else:
    ppu.lx = int32(-(7 and int(ppu.scx)))

proc fifo_reset_bg*(ppu: GbFifoPpu; fetching_window: bool) =
  fifo_clear(ppu.fifo)
  ppu.fetcher_x = 0
  ppu.fetch_counter = 0
  ppu.fetching_window = fetching_window
  ppu.bg_pixels_pushed = false
  if fetching_window: inc ppu.current_window_line

proc fifo_reset_sprite*(ppu: GbFifoPpu) =
  fifo_clear(ppu.fifo_sprite)
  ppu.fetch_counter_sprite = 0
  ppu.fetching_sprite = false
  ppu.sprite_fetch_phase = 0

proc try_push_bg_pixels(ppu: GbFifoPpu; gb: GB): bool =
  ## Attempt to push 8 pixels to the BG FIFO. Returns true if successful.
  if ppu.fifo.size == 0:
    let bg_en = bg_display(ppu) or gb.cgb_enabled
    inc ppu.fetcher_x
    # The FIFO is empty here, so where head/tail happen to sit in the ring is
    # not observable (nothing reads an empty BG FIFO, and only the sprite FIFO
    # is ever indexed). Rewinding them to 0 turns the eight pushes into eight
    # contiguous stores with no per-pixel wrap mask.
    ppu.fifo.head = 0
    ppu.fifo.tail = 8
    ppu.fifo.size = 8
    let attrs     = ppu.tile_attrs
    let flip      = (attrs and 0b0010_0000) != 0
    let palette   = attrs and 0x7
    let obj_to_bg = (attrs and 0x80) shr 7
    let lo = ppu.tile_data_low
    let hi = ppu.tile_data_high
    for col in 0 ..< 8:
      let shift = if flip: col else: 7 - col
      let color = uint8((((hi shr shift) and 0x1) shl 1) or ((lo shr shift) and 0x1))
      ppu.fifo.data[col] = GbPixel(
        color:     if bg_en: color else: 0'u8,
        palette:   palette,
        oam_idx:   0,
        obj_to_bg: obj_to_bg,
      )
    return true
  return false

proc tick_bg_fetcher*(ppu: GbFifoPpu; gb: GB) =
  case FETCHER_ORDER[ppu.fetch_counter]
  of fsGetTile:
    let (map, offset) =
      if ppu.fetching_window:
        # Wraps inside the 32x32 tile map exactly as the background fetch
        # below does. Without the mask a long enough line runs fetcher_x past
        # the end of the map and then off the end of VRAM itself — an
        # out-of-bounds read (The Fish Files crashed the emulator here).
        let m = if window_tile_map(ppu) == 0: 0x1800 else: 0x1C00
        let o = (ppu.fetcher_x and 0x1F) +
                ((((ppu.current_window_line shr 3) * 32)) and 0x3FF)
        (m, o)
      else:
        let m = if bg_tile_map(ppu) == 0: 0x1800 else: 0x1C00
        let o = ((ppu.fetcher_x + (int(ppu.scx) shr 3)) and 0x1F) +
                (((int(ppu.ly) + int(ppu.scy)) shr 3) * 32) and 0x3FF
        (m, o)
    ppu.tile_num   = ppu.vram[0][map + offset]
    ppu.tile_attrs = ppu.vram[1][map + offset]
    ppu.bg_pixels_pushed = false
    inc ppu.fetch_counter

  of fsGetTileDataLow, fsGetTileDataHigh:
    let tile_num = if bg_window_tile_data(ppu) != 0: int(ppu.tile_num)
                   else: int(cast[int8](ppu.tile_num))
    let tile_data_tbl = if bg_window_tile_data(ppu) != 0: 0x0000 else: 0x1000
    let tile_ptr = tile_data_tbl + 16 * tile_num
    let bank_num = int((ppu.tile_attrs and 0b0000_1000) shr 3)
    var tile_row = if ppu.fetching_window:
                     ppu.current_window_line and 7
                   else:
                     (int(ppu.ly) + int(ppu.scy)) and 7
    if (ppu.tile_attrs and 0b0100_0000) != 0: tile_row = 7 - tile_row
    if FETCHER_ORDER[ppu.fetch_counter] == fsGetTileDataLow:
      ppu.tile_data_low = ppu.vram[bank_num][tile_ptr + tile_row * 2]
      inc ppu.fetch_counter
    else:
      ppu.tile_data_high = ppu.vram[bank_num][tile_ptr + tile_row * 2 + 1]
      inc ppu.fetch_counter
      if not ppu.dropped_first_fetch:
        ppu.dropped_first_fetch = true
        ppu.fetch_counter = 0
      elif try_push_bg_pixels(ppu, gb):
        ppu.bg_pixels_pushed = true

  of fsPushPixel:
    if ppu.bg_pixels_pushed or try_push_bg_pixels(ppu, gb):
      ppu.bg_pixels_pushed = false
      inc ppu.fetch_counter

  of fsSleep:
    inc ppu.fetch_counter

  # Counter is never negative and never exceeds 8, so the mask is the `mod 8`
  # it replaces without the signed-remainder correction.
  ppu.fetch_counter = ppu.fetch_counter and 7

proc sprite_fetch_merge*(ppu: GbFifoPpu; gb: GB) =
  ## Read sprite tile data and merge into the sprite FIFO.
  let s = ppu.sprites[0]
  ppu.sprites.delete(0)
  let (b_lo, b_hi) = sprite_tile_bytes(s, ppu.ly, sprite_height(ppu))
  let bank = if gb.cgb_enabled: int(sprite_bank_num(s)) else: 0
  # Pad OAM FIFO to at least 8 pixels with transparent lowest-priority pixels
  while ppu.fifo_sprite.size < 8:
    fifo_push(ppu.fifo_sprite, GbPixel(color: 0, palette: 0, oam_idx: 0xFF, obj_to_bg: 0))
  for col in 0 ..< 8:
    let shift = if sprite_x_flip(s): col else: 7 - col
    let lsb = (ppu.vram[bank][b_lo] shr shift) and 0x1
    let msb = (ppu.vram[bank][b_hi] shr shift) and 0x1
    let color = uint8((msb shl 1) or lsb)
    let palette = if gb.cgb_enabled: sprite_cgb_palette(s) else: sprite_dmg_palette(s)
    let px = GbPixel(color: color, palette: palette, oam_idx: s.oam_idx, obj_to_bg: sprite_priority(s))
    let fifo_col = col + int(s.x) - 8 - int(ppu.lx)
    if fifo_col >= 0:
      if fifo_col >= ppu.fifo_sprite.size:
        fifo_push(ppu.fifo_sprite, px)
      elif (px.color != 0 and fifo_get(ppu.fifo_sprite, fifo_col).color == 0) or
           (gb.cgb_enabled and px.oam_idx <= fifo_get(ppu.fifo_sprite, fifo_col).oam_idx and px.color != 0):
        fifo_set(ppu.fifo_sprite, fifo_col, px)
  # Check if next sprite shares the same X coordinate
  ppu.fetching_sprite =
    ppu.sprites.len > 0 and ppu.sprites[0].x == s.x
  if ppu.fetching_sprite:
    # A second object at the same X does not re-run the BG-fetcher wait (the
    # fetcher is already parked), but it still pays its own full object fetch.
    # That fetch is 6 dots -- 2 to put the tile row address on the bus and 2 for
    # each of the two data bytes -- so the same-X repeat costs 6, not the 2 that
    # phases 3+4 alone would charge. mooneye
    # acceptance/ppu/intr_2_mode0_timing_sprites measures 1..10 objects stacked
    # at X=0 and its expectations step by exactly 6 dots per extra object.
    ppu.fetch_counter_sprite = 0
    ppu.sprite_fetch_phase = 7

proc tick_sprite_fetcher*(ppu: GbFifoPpu; gb: GB) =
  ## Multi-phase sprite fetch state machine.
  ## Phase 0: Advance BG fetcher until it reaches fsPushPixel or BG FIFO non-empty.
  ## Phase 1: One extra BG fetcher advance (1 cycle).
  ## Phase 2: Second extra BG fetcher advance + 2 idle cycles (3 cycles total).
  ## Phase 3: Lower sprite tile address (1 cycle).
  ## Phase 4: Upper sprite tile address + actual data fetch (0 extra cycles, instant).
  ## Phase 5: Exit penalty (1 cycle).
  case ppu.sprite_fetch_phase
  of 0:
    tick_bg_fetcher(ppu, gb)
    if FETCHER_ORDER[ppu.fetch_counter] == fsPushPixel or ppu.fifo.size > 0:
      # SCX penalty: when sprite is at X=0 and SCX & 7 > 0, burn extra cycles
      let scx_low = int(ppu.scx and 7)
      if ppu.sprites.len > 0 and ppu.sprites[0].x == 0 and scx_low > 0:
        ppu.scx_penalty_remaining = scx_low
        ppu.sprite_fetch_phase = 6
      else:
        ppu.sprite_fetch_phase = 1
  of 1:
    tick_bg_fetcher(ppu, gb)
    ppu.sprite_fetch_phase = 2
    ppu.fetch_counter_sprite = 0  # reuse as sub-counter for phase 2
  of 2:
    if ppu.fetch_counter_sprite == 0:
      tick_bg_fetcher(ppu, gb)
    inc ppu.fetch_counter_sprite
    if ppu.fetch_counter_sprite >= 3:
      ppu.sprite_fetch_phase = 3
  of 3:
    ppu.sprite_fetch_phase = 4
  of 4:
    sprite_fetch_merge(ppu, gb)
    if ppu.fetching_sprite:
      discard  # restarted at phase 0 by sprite_fetch_merge
    else:
      ppu.sprite_fetch_phase = 5
  of 5:
    ppu.fetching_sprite = false
  of 6:
    # SCX penalty phase: burn cycles for sprites at X=0 when SCX & 7 > 0
    dec ppu.scx_penalty_remaining
    if ppu.scx_penalty_remaining <= 0:
      ppu.sprite_fetch_phase = 1
  of 7:
    # Same-X repeat: the 4 dots that phases 3+4 do not cover (see
    # sprite_fetch_merge).
    inc ppu.fetch_counter_sprite
    if ppu.fetch_counter_sprite >= 4:
      ppu.sprite_fetch_phase = 3
  else:
    ppu.fetching_sprite = false

proc sprite_wins*(ppu: GbFifoPpu; gb: GB; bg_px: GbPixel; sp_px: GbPixel): bool =
  if sprite_enabled(ppu) and sp_px.color > 0:
    if gb.cgb_enabled:
      not bg_display(ppu) or bg_px.color == 0 or
        (bg_px.obj_to_bg == 0 and sp_px.obj_to_bg == 0)
    else:
      sp_px.obj_to_bg == 0 or bg_px.color == 0
  else: false

# Which of the eight fetcher positions the window's re-trigger edge survives
# on. See window_reactivate; overridable so the sweep that picked it can be
# re-run against the three m3_wx_*_change ROMs.
const WIN_REACT_PHASE {.intdefine.} = 5

proc window_reactivate(ppu: GbFifoPpu) =
  ## WX was re-reached while the window was ALREADY the active fetch source.
  ##
  ## The window does not restart here: the window tile position and
  ## current_window_line both carry on, and the rest of the line is the same
  ## pixels it would otherwise have been. What the re-trigger edge does is
  ## inject ONE pixel of colour 0 at the lowest priority in front of whatever
  ## the BG FIFO is holding, displacing the remainder of the line one pixel to
  ## the right. mealybug m3_wx_4_change's reference is exactly our old output
  ## with a single extra colour-0 pixel spliced in at WX-7, which is what
  ## fixes the position; that it is colour 0 rather than a shade is what lets
  ## an OBJ-behind-BG sprite show through it, which is what m3_wx_4_change
  ## _sprites checks (its reference shows the sprite's grey at that pixel, not
  ## the palette-0 shade).
  ##
  ## The edge is swallowed on seven fetcher steps out of eight -- mealybug
  ## drives WX from LY, so the re-trigger walks one pixel per line, and the
  ## artifact shows up on one line in eight. The ROM's own comment names the
  ## surviving step as the window tile-map (nametable) read. WHICH of this
  ## model's eight fetch_counter positions that read corresponds to is a
  ## property of this renderer's phase (the discarded first fetch and the
  ## extra Get-Tile-Data-High push both shift it), not something Pan Docs
  ## fixes, so it was settled by sweeping all eight against m3_wx_4_change,
  ## m3_wx_4_change_sprites and m3_wx_5_change: position 5 is the unique best
  ## on all three at once (229/10/638 mismatching pixels -> 53/4/142).
  ##
  ## That fetcher-position test is the CALLER's FIRST term rather than this
  ## proc's, because it is by far the most selective one -- true on one dot in
  ## eight, against a field the fetcher wrote on this same dot. Leading with it
  ## keeps seven eighths of the dots of an active window off the WX comparison
  ## altogether, which is what makes the whole rule free on a window-heavy
  ## screen (dmg-acid2 measured +1.3% with the WX compare leading, +0.2% --
  ## the noise floor -- with the position test leading).
  # Unshift, not push: the pixel is consumed by the very next dot, so it has to
  # go in front of the FIFO's head. Depth is 16 and the FIFO never holds more
  # than 8, so the extra entry cannot collide with the tail.
  ppu.fifo.head = (ppu.fifo.head - 1) and 15
  ppu.fifo.data[ppu.fifo.head] =
    GbPixel(color: 0, palette: 0, oam_idx: 0, obj_to_bg: 0)
  inc ppu.fifo.size

proc tick_shifter*(ppu: GbFifoPpu; gb: GB) =
  if ppu.fifo.size > 0:
    if not ppu.smooth_scroll_sampled: fifo_sample_smooth_scroll(ppu)
    # Check for sprite at current pixel BEFORE popping/rendering
    if sprite_enabled(ppu) and ppu.sprites.len > 0 and
       int(ppu.lx) + 8 >= int(ppu.sprites[0].x):
      ppu.fetching_sprite = true
      ppu.sprite_fetch_phase = 0
      ppu.fetch_counter_sprite = 0
      return
    let bg_px = fifo_shift(ppu.fifo)
    let has_sprite = ppu.fifo_sprite.size > 0
    let sp_px = if has_sprite: fifo_shift(ppu.fifo_sprite) else: GbPixel()
    if ppu.lx >= 0:
      let use_sprite = has_sprite and sprite_wins(ppu, gb, bg_px, sp_px)
      let (px, arr_pram) =
        if use_sprite: (sp_px, addr ppu.obj_pram[0])
        else:          (bg_px, addr ppu.pram[0])
      let final_color =
        if gb.cgb_enabled: int(px.color)
        else:
          let p = if use_sprite: (if sp_px.palette == 0: ppu.obp0 else: ppu.obp1)
                  else: ppu.bgp
          int(p[px.color])
      let pal_offset = (int(px.palette) * 4 + final_color) * 2
      ppu.framebuffer[GB_WIDTH * int(ppu.ly) + int(ppu.lx)] =
        cast[ptr uint16](cast[int](arr_pram) + pal_offset)[]
    inc ppu.lx
    # Same conjunction, cheapest and most selective terms first: two plain
    # bool fields reject almost every dot before any register decode or
    # comparison runs. All five terms are side-effect-free reads.
    if not ppu.fetching_window:
      if ppu.window_trigger and
         window_enabled(ppu) and int(ppu.ly) >= int(ppu.wy) and
         int(ppu.lx) + 7 >= int(ppu.wx):
        fifo_reset_bg(ppu, true)
    elif ppu.fetch_counter == WIN_REACT_PHASE and
         int(ppu.lx) + 7 == int(ppu.wx) and window_enabled(ppu):
      window_reactivate(ppu)

proc fifo_tick_slow(ppu: GbFifoPpu; gb: GB; cycles: int) =
  ## Everything the PPU can do in a span that is NOT a pure idle skip. Split
  ## out of fifo_tick so the idle case (below) inlines into the caller; the
  ## read_mode latch and the dots_since_frame counter are updated by fifo_tick
  ## on both paths before this runs.
  if lcd_enabled(ppu):
    var remaining = cycles
    while remaining > 0:
      # Modes 0, 1 and 2 do nothing at all until the dot counter reaches a
      # single trigger value — mode 3 is the only one that has per-dot work.
      # Those three account for roughly 60% of the dots in a frame, so the
      # loop below jumps straight to the next dot that can do something
      # instead of re-dispatching the mode switch for each one. Same
      # sequence of actions at the same dot counts; only the no-op iterations
      # are collapsed. The one level-triggered rule in the set (LY 153
      # snapping back to 0 once the counter passes 4) opts out of the jump,
      # so it still fires on exactly the dot it used to.
      let m = ppu.mode_flag
      if m != 3:
        let target =
          if m == 2: 80'i32
          elif ppu.ly == 143 and m == 0 and gb.cgb_enabled: M2_144_EARLY_DOT
          else: 456'i32
        if ppu.cycle_counter < target and (m != 1 or ppu.ly != 153):
          let skip = min(remaining, int(target - ppu.cycle_counter))
          ppu.cycle_counter += int32(skip)
          remaining -= skip
          continue
      elif ppu.lx < GB_WIDTH:
        # Mode 3 is the one mode with genuine per-dot work, so it cannot be
        # collapsed the way the skip above collapses the other three — but it
        # does not need the mode re-decoded on every one of its ~26,000 dots a
        # frame either. Nothing inside the pipeline changes the mode: only the
        # `lx >= GB_WIDTH` test does, and that is the loop condition. Same
        # actions on the same dots as the generic path below, which still
        # handles the dot that ends mode 3.
        while remaining > 0 and ppu.lx < GB_WIDTH:
          if ppu.fetching_sprite: tick_sprite_fetcher(ppu, gb)
          else:
            tick_bg_fetcher(ppu, gb)
            tick_shifter(ppu, gb)
          ppu.cycle_counter += 1
          dec remaining
        continue
      dec remaining
      case m
      of 2:  # OAM search
        if ppu.cycle_counter == 80:
          ppu.`mode_flag=`(3'u8, gb)
          if ppu.ly == ppu.wy: ppu.window_trigger = true
          fifo_reset_bg(ppu,
            window_enabled(ppu) and int(ppu.ly) >= int(ppu.wy) and
            ppu.wx <= 7 and ppu.window_trigger)
          fifo_reset_sprite(ppu)
          ppu.lx = 0
          ppu.smooth_scroll_sampled = false
          ppu.dropped_first_fetch = false
          ppu.sprites = fifo_get_sprites(ppu, gb)
      of 3:  # Drawing
        # Mode 3 ends the dot AFTER the 160th pixel is shifted out (lx reaches
        # GB_WIDTH), not on the same dot. Deferring the mode 0 transition by one
        # dot makes mode 3 the hardware-correct 172 dots for SCX=0 (was 171)
        # without changing any rendered pixel.
        if ppu.lx >= GB_WIDTH:
          ppu.`mode_flag=`(0'u8, gb)
        elif ppu.fetching_sprite:
          tick_sprite_fetcher(ppu, gb)
        else:
          tick_bg_fetcher(ppu, gb)
          tick_shifter(ppu, gb)
      of 0:  # H-Blank
        # CGB raises the line-144 mode 2 STAT source one M-cycle before the
        # line ends (see m2_line144). The source is level-triggered off the
        # dot counter, but nothing else happens on this dot, so the edge
        # detector has to be run here explicitly; the skip target above stops
        # the idle jump on it so this dot is actually visited.
        if ppu.cycle_counter == M2_144_EARLY_DOT and ppu.ly == 143 and
           gb.cgb_enabled:
          ppu_handle_stat_interrupt(ppu, gb)
        elif ppu.cycle_counter == 456:
          ppu.cycle_counter = 0
          ppu.ly += 1
          ppu.read_mode = ppu.read_mode or LY_JUST_CHANGED
          if int(ppu.ly) == GB_HEIGHT:
            ppu.`mode_flag=`(1'u8, gb)
            gb.interrupts.vblank_interrupt = true
            ppu.frame = true
            when defined(gb_dot_counter): inc gb_frame_normal
            ppu.dots_since_frame = 0
            ppu.current_window_line = -1
          else:
            ppu.`mode_flag=`(2'u8, gb)
      of 1:  # V-Blank
        if ppu.cycle_counter == 456:
          ppu.cycle_counter = 0
          if ppu.ly != 0:
            ppu.ly += 1
            ppu.read_mode = ppu.read_mode or LY_JUST_CHANGED
          ppu_handle_stat_interrupt(ppu, gb)
          if ppu.ly == 0:
            ppu.`mode_flag=`(2'u8, gb)
        if ppu.ly == 153 and ppu.cycle_counter > 4: ppu.ly = 0
      else: discard
      ppu.cycle_counter += 1
  else:
    ppu.cycle_counter = 0
    ppu.`mode_flag=`(0'u8, gb)
    ppu.ly = 0
    lcd_off_frame(ppu, gb)

proc fifo_tick*(ppu: GbFifoPpu; gb: GB; cycles: int) {.inline.} =
  # Snapshot the mode as observed by a CPU read that samples during this M-cycle
  # (read_byte runs after this whole tick advances the PPU). See GbPpu.read_mode.
  # Still written on the idle path: mode_flag cannot change there, but a
  # PRECEDING slow tick may have changed it, and read_mode would then be a
  # mode older than the start of this M-cycle (a STAT read would see the mode
  # from two M-cycles ago).
  let m = ppu.lcd_status and 3'u8
  ppu.read_mode = m
  # Counted on both paths: the panel's refresh clock runs whether or not the
  # PPU is driving it (see ppu_blank_frame).
  ppu.dots_since_frame += int32(cycles)
  when defined(gb_dot_counter): gb_total_dots += uint64(cycles)
  # ---- Lazy idle span -----------------------------------------------------
  # This is the first iteration of fifo_tick_slow's skip branch, hoisted out
  # of the call so the case it covers costs nothing but a compare. Modes 0, 1
  # and 2 do nothing at all until the dot counter reaches one trigger value,
  # and together they are ~65% of the 70,224 dots in a frame -- yet this proc
  # is entered once per 4 T-cycles of every memory access, so that call was
  # being paid ~11,000 times a frame to advance a counter.
  #
  # Nothing else in the PPU is observable while the span stays strictly inside
  # an idle stretch: no mode change, no LY change, no STAT/VBlank interrupt,
  # no HDMA block, no pixel. The two level-triggered rules opt out and fall
  # through to the loop, exactly as they did there:
  #   * mode 3 (a pixel per dot), and
  #   * mode 1 with LY 153 (LY snaps back to 0 once the counter passes 4).
  # An LCD that is off also falls through -- that path re-asserts mode 0 and
  # drives the blank-frame clock every tick.
  if m != 3 and (ppu.lcd_control and 0x80'u8) != 0:
    # Line 143's mode 0 is the one H-Blank with something to do before dot 456
    # (the CGB early mode 2 STAT, see m2_line144), so it gets the shorter
    # target. `ppu.ly == 143` is first because it is false on 153 of every 154
    # lines, which keeps the added cost of this case to one compare.
    let target =
      if m == 2: 80'i32
      elif ppu.ly == 143 and m == 0 and gb.cgb_enabled: M2_144_EARLY_DOT
      else: 456'i32
    let next = ppu.cycle_counter + int32(cycles)
    # `<=` not `<`: landing exactly on the target is what the loop did too --
    # it consumed the whole span in one skip and left the transition for the
    # next entry, where cycle_counter == target fails `cycle_counter < target`.
    if next <= target and (m != 1 or ppu.ly != 153):
      ppu.cycle_counter = next
      return
  fifo_tick_slow(ppu, gb, cycles)

method tick*(ppu: GbFifoPpu; gb: GB; cycles: int) =
  ## Polymorphic entry point. The hot path (mem_tick_components) calls
  ## fifo_tick directly through GB.fifo_ppu and never reaches this.
  fifo_tick(ppu, gb, cycles)
