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
  ppu.m3_delay = 0
  ppu.m3_draining = false
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

# Idle dots injected at the head of mode 3, moving the whole fetch/shift
# pipeline later against the CPU clock. 0 -- the shipping value -- compiles the
# pipeline half of it out.
#
# It USED to be a measuring instrument only, because it also deferred the mode
# 0 flag by the same n and that put ~40 mooneye/GBMicrotest hblank-timing rows
# red at any n > 0. It no longer does: the flag and the pipeline are separate
# now (fetcher_retired / m3_draining below), so this knob moves the pixels
# without moving a single mode boundary. Measured over n = 0..8 on 2026-08-02,
# blargg 23/28, mooneye 112/115, mooneye-wilbertpol 79/117, GBMicrotest
# 347/513, magen 6/7 and mGBA 6967/7008 do not move at ANY n. That is the
# structural blocker gone, and it is what this commit is for.
#
# It still ships at 0, because turning it up is not yet a net win. What the
# sweep says the phase itself costs, per value (gambatte total, then the rows
# that move):
#
#   n  gambatte  results.md  notable
#   0  3253      615 pass    (main)
#   1  3247      615         age/m3-bg-lcdc-ds PASSES; window -7
#   2  3250      615         bgtilemap 0->4, bgtiledata 0->1, m0enable +2
#   3  3253      614         as n=2 plus scx_during_m3 +3, scy +5, sprites -2;
#                            m3_scy_change 51.4->83.5, m3_bgp_change
#                            74.8->84.2, m3_window_timing 92.1->95.7;
#                            costs m3_scx_low_3_bits (the only row that goes
#                            from green to a percentage)
#   4  3250      614         indistinguishable from 3 on hardware grounds
#   5+ 3228      614         m3_wx_4/5_change collapse (WIN_REACT_PHASE moves
#                            with the phase; re-swept, 5 is still its best)
#
# n = 3 is where the gambatte total is exactly level with main and the mealybug
# percentages are well up, and it is the value the bgtiledata/bgtilemap
# staircase measurement asks for -- but it trades one green row for those, and
# the two families it is aimed at still cannot pass while the double-speed
# alignment (below) is unfixed. Not worth a real regression for a partial win,
# so: structure now, phase when the rest of the fetch model is ready.
const M3_PIPE_DELAY {.intdefine.} = 0

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

proc fetcher_retired(ppu: GbFifoPpu): bool {.inline.} =
  ## Has the BG fetcher run out of work for this line? That -- not the last
  ## pixel leaving the shifter -- is what ends mode 3 and hands VRAM back to
  ## the CPU. At M3_PIPE_DELAY = 0 the two coincide and this is exactly the
  ## `lx >= GB_WIDTH` test it replaces.
  ##
  ## The object terms are what make this a fetcher question rather than an lx
  ## one: an object overlapping the last columns (X in 160..167 is partly on
  ## screen, so it is a real fetch) still has to be read out of VRAM, and mode
  ## 3 has to stretch to cover it exactly as it does for an object anywhere
  ## else on the line. They are only asked once the shifter is inside the last
  ## M3_PIPE_DELAY pixels, so they cost nothing on the other 152.
  when M3_PIPE_DELAY == 0:
    # Nothing below can be reached with a zero lead, and this is the mode 3
    # loop's condition -- spell the degenerate case out rather than trust the
    # optimiser to fold three branches back into the one compare it replaces.
    ppu.lx >= GB_WIDTH
  else:
    if ppu.lx < GB_WIDTH - M3_PIPE_DELAY: return false
    if ppu.lx >= GB_WIDTH: return true
    not ppu.fetching_sprite and
      (ppu.sprites.len == 0 or int(ppu.lx) + 8 < int(ppu.sprites[0].x))

proc fifo_pipeline_dot(ppu: GbFifoPpu; gb: GB; drained = false) {.inline.} =
  ## One dot of the fetch/shift pipeline, wherever in the line it falls --
  ## mode 3, or the tail of the line that runs on into H-Blank.
  ##
  ## `drained` says the fetcher has already retired, which is the whole
  ## content of the mode 0 flag: from here the shifter runs on what is already
  ## in the FIFO and the fetcher does NOT touch VRAM again. Letting it keep
  ## fetching instead is not a detail -- it re-reads SCX and the LCDC selects
  ## for a tile the CPU is now free to move under it, and mealybug
  ## m3_scx_low_3_bits (which rewrites SCX the moment H-Blank starts) sees the
  ## difference immediately. The fetcher is only woken again if the FIFO turns
  ## out not to cover the rest of the line, which the line-end rule makes rare
  ## but does not forbid.
  when M3_PIPE_DELAY > 0:
    if ppu.m3_delay > 0:
      dec ppu.m3_delay
      return
    if drained and ppu.fifo.size > 0:
      tick_shifter(ppu, gb)
      return
  when defined(gb_m3_trace):
    if int(ppu.ly) == GB_TRACE_LY:
      echo "DOT ", ppu.cycle_counter, " stage=",
           FETCHER_ORDER[ppu.fetch_counter], " lx=", ppu.lx,
           " fx=", ppu.fetcher_x, " lcdc=", toHex(ppu.lcd_control, 2),
           " fifo=", ppu.fifo.size, " spr=", ppu.fetching_sprite,
           " tn=", toHex(ppu.tile_num, 2), " mode=", ppu.mode_flag
  if ppu.fetching_sprite: tick_sprite_fetcher(ppu, gb)
  else:
    tick_bg_fetcher(ppu, gb)
    tick_shifter(ppu, gb)

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
        if ppu.cycle_counter < target and (m != 1 or ppu.ly != 153) and
           (M3_PIPE_DELAY == 0 or not ppu.m3_draining):
          let skip = min(remaining, int(target - ppu.cycle_counter))
          ppu.cycle_counter += int32(skip)
          remaining -= skip
          continue
      elif not fetcher_retired(ppu):
        # Mode 3 is the one mode with genuine per-dot work, so it cannot be
        # collapsed the way the skip above collapses the other three — but it
        # does not need the mode re-decoded on every one of its ~26,000 dots a
        # frame either. Nothing inside the pipeline changes the mode: only the
        # `lx >= GB_WIDTH` test does, and that is the loop condition. Same
        # actions on the same dots as the generic path below, which still
        # handles the dot that ends mode 3.
        #
        # KNOWN RESIDUAL, measured 2026-08-01 and deliberately not fixed here.
        # This pipeline runs 8 dots AHEAD of hardware relative to the CPU
        # clock. Trace a mealybug ROM's register writes against lx and the
        # picture is unambiguous: a write landing at line dot D changes the
        # pixel at lx = D - 92, where hardware changes the pixel at D - 100.
        # It is one constant, not a per-register effect -- BGP, LCDC.3/.4/.6,
        # SCY and WX all land 8 dots early by the same amount.
        #
        # Injecting exactly 8 idle dots at the head of mode 3 (a throwaway
        # `m3_delay` counter decremented here, mode 0 still driven by lx) was
        # measured against the whole suite and buys a lot:
        #   m3_bgp_change          74.8% -> 97.8%   m3_scy_change   51.4 -> 90.4
        #   m3_bgp_change_sprites  75.9% -> 95.0%   m3_bg_en_change 84.3 -> 94.7
        #   m3_lcdc_win_map_change 92.3% -> 97.2%   m3_tile_sel_win 89.8 -> 94.7
        # and costs four rows that pass today, because deferring the pixels
        # that way also defers the mode 0 flag by 8 dots: intr_2_0_timing,
        # intr_2_mode0_timing, intr_2_oam_ok_timing and m3_scx_low_3_bits all
        # go red, and m3_wx_4/5_change collapse (the re-trigger phase moves
        # with lx). So the offset is real but the crude fix is not shippable.
        #
        # ---- That decoupling is DONE, 2026-08-02 -------------------------
        # The flag and the pipeline are no longer the same event. Mode 3 now
        # ends when the FETCHER retires (fetcher_retired), which is
        # M3_PIPE_DELAY pixels before the shifter finishes the line; those last
        # pixels come out during H-Blank, off the FIFO, with the fetcher
        # already parked (m3_draining). Mode 3's length is arithmetically
        # unchanged -- the head delay and the early flag are the same n and
        # cancel -- which is why blargg, mooneye, mooneye-wilbertpol,
        # GBMicrotest, MagenTests and the mGBA suite are byte-for-byte
        # identical at every n from 0 to 8, where the old coupled version put
        # ~40 rows red at any n > 0.
        #
        # Two deliberate choices inside it:
        #  * The CPU VRAM/OAM locks keep reading the LIVE mode, so they open
        #    with the flag, at the dot they always did. The pixels still being
        #    shifted out after that point never touch VRAM again -- that is
        #    exactly what "the fetcher retired" means, and it is enforced
        #    (fifo_pipeline_dot's `drained`) rather than assumed. Letting the
        #    fetcher run on into H-Blank instead re-reads SCX and the LCDC
        #    selects for a tile the CPU is now free to move, which mealybug
        #    m3_scx_low_3_bits catches within one line.
        #  * An object overlapping the last columns (X 160..167) is a real
        #    fetch, so it holds mode 3 open exactly as an object anywhere else
        #    does; the flag waits for it. Without that term the object penalty
        #    would silently vanish for the right-hand edge of the screen.
        #
        # What is NOT done is the phase itself: M3_PIPE_DELAY still ships at 0.
        # See its declaration for the per-value cost table and why.
        #
        # ---- The constant is 3-4 dots for the FETCHER, not 8 -------------
        # Re-measured 2026-08-02 against gambatte/bgtiledata (0/34) and
        # gambatte/bgtilemap (0/40), which are a far sharper instrument than
        # mealybug: each family is four ROMs whose only difference is that the
        # mid-line LCDC write moves one M-cycle, and each ships a reference
        # PNG, so the boundary they draw IS the staircase
        # `first affected tile = 8*ceil((write_dot - c)/8)`. Solving it for c
        # (`-d:gb_m3_trace` gives the write dot; `DINGBAT_GAM_DUMP` the frame):
        #
        #                        this renderer      DMG/CGB hardware
        #   LCDC.3, tile map        lx + 88            lx + 89 .. 92
        #   LCDC.4, tile data low   lx + 90            lx + 93 .. 96
        #   LCDC.4, tile data high  lx + 92            (low + 2, confirmed by
        #                                              the mixed-shade tiles
        #                                              the _ds_ ROMs draw)
        #
        # Both families are ONE bug: the map read and the data read are 2 dots
        # apart here and 2 dots apart on hardware, so the relative phase inside
        # a fetch is already right and only the fetch's phase against the CPU
        # is wrong. Confirming that, M3_PIPE_DELAY (below) makes rows 16..143
        # of every single-speed ROM in both families pixel-exact at N=3 and at
        # N=4 -- 1400 mismatching pixels -> 240 -- and at no other N. 3 and 4
        # are indistinguishable here because a single-speed CPU can only place
        # the write on a 4-dot grid.
        #
        # Note this is 3-4, not the 8 measured off mealybug above, and it is
        # the same lever. Whoever lands the restructure should re-derive the
        # constant from these two families rather than from mealybug, and
        # should expect BGP (applied at the shifter, not the fetcher) to want
        # its own value -- "one constant for every register" is what the
        # mealybug reading assumed, and this measurement does not support it.
        #
        # Two further bugs hide behind this one and only become visible once
        # the phase is corrected; neither is fixed here:
        #  * The _ds_ (CGB double-speed) rows want N in {1,2} where the
        #    single-speed rows want {3,4}, i.e. a CPU-write-to-PPU alignment
        #    that differs by 2 dots between normal and double speed. No single
        #    pipeline phase can pass both, so the 14 _ds_ rows of these two
        #    families need that fixed as well.
        #  * Lines carrying an object still mismatch at the best N: for one
        #    object at screen x=0 this pipeline's fetch phase shifts by 6 dots
        #    where the references need 11-13. The object penalty's effect on
        #    the fetch phase is short even though mooneye's mode-3 LENGTH
        #    penalty passes, which is the same flag-vs-pipeline decoupling
        #    again, seen from the other end.
        while remaining > 0 and not fetcher_retired(ppu):
          fifo_pipeline_dot(ppu, gb)
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
          ppu.m3_delay = M3_PIPE_DELAY
          ppu.smooth_scroll_sampled = false
          ppu.dropped_first_fetch = false
          ppu.sprites = fifo_get_sprites(ppu, gb)
      of 3:  # Drawing
        # Mode 3 ends the dot AFTER the fetcher retires, not on the same dot.
        # Deferring the mode 0 transition by one dot makes mode 3 the
        # hardware-correct 172 dots for SCX=0 (was 171) without changing any
        # rendered pixel. At M3_PIPE_DELAY > 0 the shifter is still M3_PIPE_
        # DELAY pixels from the end of the line here; they come out during
        # H-Blank (see m3_draining).
        if fetcher_retired(ppu):
          # Armed before the flag, not after: `mode_flag=` runs an HBlank HDMA
          # block inline and that block ticks the PPU, and those nested ticks
          # are real dots that have to drain the pipeline like any other.
          when M3_PIPE_DELAY > 0:
            ppu.m3_draining = ppu.lx < GB_WIDTH
          ppu.`mode_flag=`(0'u8, gb)
        else:
          fifo_pipeline_dot(ppu, gb)
      of 0:  # H-Blank
        # The tail of the line: the mode 0 flag went up when the FETCHER
        # retired, and the shifter is still M3_PIPE_DELAY pixels behind it.
        # Those pixels are emitted here, in the first dots of H-Blank.
        when M3_PIPE_DELAY > 0:
          if ppu.m3_draining:
            fifo_pipeline_dot(ppu, gb, drained = true)
            if ppu.lx >= GB_WIDTH: ppu.m3_draining = false
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
    # An LCD switched off mid-line drops the tail with everything else; the
    # flag has to go with it or the idle-span fast path stays disabled for the
    # rest of the run (see fifo_tick).
    ppu.m3_draining = false
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
    # `M3_PIPE_DELAY == 0 or` is a compile-time short circuit, not a runtime
    # test: with no lead there is never a tail to protect, and this guard is on
    # the single hottest path in the PPU (see the comment above).
    if next <= target and (m != 1 or ppu.ly != 153) and
       (M3_PIPE_DELAY == 0 or not ppu.m3_draining):
      ppu.cycle_counter = next
      return
  fifo_tick_slow(ppu, gb, cycles)

method tick*(ppu: GbFifoPpu; gb: GB; cycles: int) =
  ## Polymorphic entry point. The hot path (mem_tick_components) calls
  ## fifo_tick directly through GB.fifo_ppu and never reaches this.
  fifo_tick(ppu, gb, cycles)
