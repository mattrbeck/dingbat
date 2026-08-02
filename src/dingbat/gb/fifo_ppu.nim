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
  when STAT_MODE_HOLD:
    result.stat_mode      = base.stat_mode
    result.stat_prev_mode = base.stat_prev_mode
    result.stat_lag_cc    = base.stat_lag_cc

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

# How far the mode-3 pixel pipeline lags the CPU's view of the PPU registers,
# in CPU **M-cycles**. Injected as idle dots at the head of mode 3, which moves
# the whole fetch/shift pipeline later against the CPU clock without moving a
# single mode boundary (fetcher_retired below keeps the flag where it was).
#
# ---- Why an M-cycle and not a dot count -----------------------------------
# A CPU write reaches the bus once per M-cycle, and dingbat runs the M-cycle's
# worth of PPU dots BEFORE handing the byte to write_byte -- so a write commits
# at the END of its M-cycle here. The VRAM/OAM locks already disagree with that:
# a write is admitted on the LATCHED mode (`read_mode`, the mode at the START of
# the M-cycle) where a read is admitted on the live one, which is mooneye
# lcdon_write_timing-GS saying the write commits one M-cycle before a read in
# the same M-cycle samples. The lock and the data are one event on hardware, so
# the data has to commit at the start of the M-cycle too: the pipeline is one
# M-cycle behind what this renderer assumes.
#
# One M-cycle is 4 dots at normal speed and 2 in double speed (Pan Docs,
# "Dots": "4 dots per Normal Speed M-cycle, and 2 per Double Speed M-cycle"),
# which is why this is latched per line from `current_speed` rather than being
# a constant. That factor of two is the whole double-speed bug -- see the
# staircase measurement below.
#
# ---- The measurement ------------------------------------------------------
# gambatte/bgtiledata (34 rows) and gambatte/bgtilemap (40 rows) are four ROMs
# per SCX whose only difference is that a mid-line LCDC write moves one
# M-cycle, each with a reference PNG, so the boundary they draw IS the
# staircase `first affected tile = 8*ceil((write_dot - c)/8)`. Sweeping the
# pipeline lead in DOTS (M3_PIPE_DELAY, below) over 0..8 and scoring rows
# 16..143 of every row in both families:
#
#   lead (dots)   0      1      2      3      4      5..8
#   single speed  61440  28672  28672  0      0      61440
#   double speed  11264  0      0      11264  11264  17408+
#
# Two disjoint windows -- {3,4} dots at normal speed, {1,2} in double speed --
# so no constant number of dots can pass both, which is exactly the shape of a
# quantity that is one M-cycle long. Solving `{3,4} - k = {1,2} - k/2` for the
# write's commit point k (in CPU T-cycles, k dots at normal speed and k/2 in
# double speed) gives k = 4 and only 4: one M-cycle, the same answer the locks
# already give. Both windows then become {-1, 0} -- the same window -- and the
# residual dot term below is 0.
#
# M3_PIPE_DELAY is what is left of that sweep: an ADDITIONAL, speed-independent
# lead in dots, kept as the instrument for re-deriving the fetch phase. It ships
# at 0 because the M-cycle term above is the whole measured offset. (Its old
# per-value table was taken with the double-speed rows still broken, so the
# numbers in it do not survive this change; re-sweep rather than trusting it.)
#
# ---- Why it nevertheless ships at 0 ---------------------------------------
# The lead is injected as idle dots at the HEAD of mode 3 and paid back by
# retiring the fetcher `m3_lead` pixels early at the tail, so mode 3's length is
# unchanged. That accounting is exact everywhere except the last `m3_lead`
# pixels of a line, where a sprite or window fetch can still stall the shifter:
# the flag then wants to go up mid-fetch, and neither "retire before the fetch"
# nor "retire after it" is that dot. Measured at 1 (2026-08-02, full runner):
#
#   gambatte  3253 -> 3256   mooneye/GBMicrotest/blargg/mGBA/magen unchanged
#   results.md  615 -> 615   (age/m3-bg-lcdc-ds-cgbBCE goes GREEN)
#   mealybug  m3_scy_change        51.4% -> 83.5%   m3_bgp_change  74.8 -> 87.3
#             m3_bgp_change_sprites 75.9% -> 89.1%  m3_window_timing 92.1 -> 96.9
#             m3_lcdc_obj_en_change_variant 94.7 -> 97.6, +8 more rows up
#   age       m3-bg-lcdc-cgbBCE    88.9% -> 98.9%   m3-bg-lcdc-dmgC 83.3 -> 94.4
#   COSTS     mealybug m3_scx_low_3_bits 100% -> 98.6% (a green row),
#             m3_lcdc_bg_map_change 97.5 -> 97.3, m3_lcdc_obj_size_change
#             99.6 -> 99.5; gambatte sprites 257 -> 255 and window 258 -> 256
#             (the runner gates on those two counts, so it exits 1), plus
#             enable_display 131 -> 128 and m0enable 143 -> 142.
#
# Every one of those costs is a WX=166 / OBJ X=166 / SCX-at-H-Blank row, i.e.
# the tail accounting and not the M-cycle constant, and the project does not
# take a partial win that turns a green row red. Landing this properly means
# committing the write itself at the start of its M-cycle (defer the PPU tick
# inside mem_write) so the pipeline is never moved and there is no tail to
# account for; that is a bus-layer change, not a PPU one. Until then this is
# one flag: `-d:M3_PIPE_MCYCLES=1`.
const M3_PIPE_MCYCLES {.intdefine.} = 0
const M3_PIPE_DELAY {.intdefine.} = 0
# Compiles the pipeline-lead machinery out entirely when both terms are off,
# which is what the `-d:M3_PIPE_MCYCLES=0 -d:M3_PIPE_DELAY=0` control build for
# an A/B wants; every guard below is a compile-time short circuit at that
# setting, not a runtime test.
const M3_PIPE_LEAD_ANY = M3_PIPE_MCYCLES != 0 or M3_PIPE_DELAY != 0

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
  ## the CPU. At a zero lead the two coincide and this is exactly the
  ## `lx >= GB_WIDTH` test it replaces.
  ##
  ## The object and window terms are what make this a fetcher question rather
  ## than an lx one. Everything the fetcher still owes for the last `m3_lead`
  ## pixels has to hold mode 3 open exactly as it would anywhere else on the
  ## line, or the fetch silently disappears for the right-hand edge of the
  ## screen alone:
  ##
  ##   * a pending object: X in 160..167 is partly on screen, so it is a real
  ##     VRAM read (gambatte sprites/10spritesPrLine_10xposA6/A7_*);
  ##   * a window that has not started yet: WX up to 166 still reaches lx 159,
  ##     and starting it restarts the BG fetch (gambatte window/m2int_wxA6_*).
  ##
  ## Both are tested as `x <= 167` / `wx <= 166` rather than "does it trigger on
  ## THIS dot" because the shifter still has the rest of the lead to walk
  ## through: the trigger is in the future, and it is the future work that keeps
  ## the fetcher alive. Both are only asked once the shifter is inside the last
  ## `m3_lead` pixels, so they cost nothing on the other 152+.
  ##
  ## What is deliberately NOT here is "the FIFO does not yet hold the rest of
  ## the line". It is the tempting rule -- it is what would keep the fetcher
  ## alive across the FIFO flush a window start does at lx 159 -- but the BG
  ## fetcher pushes in whole 8-pixel tiles, so asking it inside the lead
  ## re-times the END of mode 3 on ordinary lines too: measured, it takes
  ## gambatte to 3263 and the rest of the suite from 615 to 594 passing
  ## (vramw_m3end -4, and mooneye/GBMicrotest hblank rows with it). The
  ## remaining WX=166 rows are worth less than that.
  when not M3_PIPE_LEAD_ANY:
    # Nothing below can be reached with a zero lead, and this is the mode 3
    # loop's condition -- spell the degenerate case out rather than trust the
    # optimiser to fold three branches back into the one compare it replaces.
    ppu.lx >= GB_WIDTH
  else:
    if ppu.lx < int32(GB_WIDTH) - ppu.m3_lead: return false
    if ppu.lx >= GB_WIDTH: return true
    if ppu.fetching_sprite: return false
    if ppu.sprites.len > 0 and int(ppu.sprites[0].x) <= GB_WIDTH + 7: return false
    if not ppu.fetching_window and ppu.window_trigger and window_enabled(ppu) and
       int(ppu.ly) >= int(ppu.wy) and int(ppu.wx) <= GB_WIDTH + 6: return false
    true

proc fifo_pipeline_dot(ppu: GbFifoPpu; gb: GB) {.inline.} =
  ## One dot of the fetch/shift pipeline. The first `m3_lead` calls of a line
  ## are the pipeline's lag behind the CPU's register view and do nothing at
  ## all; the tail those dots push past the end of the line is emitted in one
  ## burst when the fetcher retires (see the mode 3 case in fifo_tick_slow), so
  ## the fetcher never runs during H-Blank.
  when M3_PIPE_LEAD_ANY:
    if ppu.m3_delay > 0:
      dec ppu.m3_delay
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
        if ppu.cycle_counter < target and (m != 1 or ppu.ly != 153):
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
        # The pipeline runs `m3_lead` dots behind the CPU's view of the PPU
        # registers (M3_PIPE_MCYCLES, above: one CPU M-cycle, so 4 dots at
        # normal speed and 2 in double speed). Two structural notes on how that
        # is arranged so it moves pixels and nothing else:
        #
        #  * The flag and the pipeline are separate events. Mode 3 ends when
        #    the FETCHER retires (fetcher_retired), which is `m3_lead` pixels
        #    before the shifter finishes the line; those last pixels are emitted
        #    in one burst on that same dot. Mode 3's length is arithmetically
        #    unchanged -- the head delay and the early flag are the same n and
        #    cancel -- which is why blargg, mooneye, mooneye-wilbertpol,
        #    GBMicrotest, MagenTests and the mGBA suite are byte-for-byte
        #    identical at every lead from 0 to 8, where the old coupled version
        #    put ~40 rows red at any n > 0.
        #  * The CPU VRAM/OAM locks keep reading the LIVE mode, so they open
        #    with the flag, at the dot they always did. The fetcher never runs
        #    after that point -- that is exactly what "the fetcher retired"
        #    means. Letting it run on into H-Blank instead re-reads SCX and the
        #    LCDC selects for a tile the CPU is now free to move, which mealybug
        #    m3_scx_low_3_bits catches within one line.
        #  * An object overlapping the last columns (X 160..167) is a real
        #    fetch, so it holds mode 3 open exactly as an object anywhere else
        #    does; the flag waits for it. Without that term the object penalty
        #    would silently vanish for the right-hand edge of the screen.
        #
        # ---- Where the fetch phase now stands ----------------------------
        # Measured 2026-08-02 against gambatte/bgtiledata and bgtilemap (the
        # staircase in M3_PIPE_MCYCLES' comment). With the M-cycle lead in,
        # rows 16..143 of every ROM in both families -- single speed AND double
        # speed -- are pixel-exact with no extra dot term. The two remaining
        # known gaps in this model, neither addressed here:
        #
        #  * BGP is applied at the shifter, not the fetcher, so it need not
        #    share the fetcher's phase; the mealybug m3_bgp_* percentages are
        #    the instrument for that one.
        #  * Lines carrying an object still mismatch: for one object at screen
        #    x=0 this pipeline's fetch phase shifts by 6 dots where the
        #    references need 11-13. The object penalty's effect on the fetch
        #    phase is short even though mooneye's mode-3 LENGTH penalty passes,
        #    which is the same flag-vs-pipeline decoupling again, seen from the
        #    other end.
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
          when M3_PIPE_LEAD_ANY:
            # Latched per line, not a constant: the M-cycle half of the lead is
            # 4 dots at normal speed and 2 in double speed, and a ROM can switch
            # speed between two lines. `current_speed` is 0 or 1.
            ppu.m3_lead = int32(M3_PIPE_MCYCLES * (4 shr gb.memory.current_speed) +
                                M3_PIPE_DELAY)
            ppu.m3_delay = int(ppu.m3_lead)
          ppu.smooth_scroll_sampled = false
          ppu.dropped_first_fetch = false
          ppu.sprites = fifo_get_sprites(ppu, gb)
      of 3:  # Drawing
        # Mode 3 ends the dot AFTER the fetcher retires, not on the same dot.
        # Deferring the mode 0 transition by one dot makes mode 3 the
        # hardware-correct 172 dots for SCX=0 (was 171) without changing any
        # rendered pixel. With a nonzero lead the shifter is still `m3_lead`
        # pixels from the end of the line here; the burst below finishes them.
        if fetcher_retired(ppu):
          when M3_PIPE_LEAD_ANY:
            # The tail of the line, emitted on THIS dot rather than spread over
            # the first dots of H-Blank. "The fetcher retired" means every VRAM
            # read the line needs has happened, so the last `m3_lead` pixels are
            # already decided here and nothing the CPU does in H-Blank may reach
            # them -- mealybug m3_scx_low_3_bits rewrites SCX on exactly that
            # dot and sees the difference in the last pixels of every line.
            # Bursting them costs no dots (the lead was already paid at the head
            # of mode 3) and keeps the fetcher out of H-Blank entirely.
            var guard = 0
            while ppu.lx < GB_WIDTH and guard < 64:
              fifo_pipeline_dot(ppu, gb)
              inc guard
          ppu.`mode_flag=`(0'u8, gb)
        else:
          fifo_pipeline_dot(ppu, gb)
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
  when STAT_MODE_HOLD: ppu_latch_stat_mode(ppu, m)
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
