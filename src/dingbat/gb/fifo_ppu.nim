# GB FIFO PPU renderer (included by gb.nim)

# `lx` runs -7..160, so this is unreachable: with win_lx parked here the
# shifter's per-dot compare against it is simply never true.
const WIN_LX_OFF = -128'i32

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
    win_lx: WIN_LX_OFF,
    old_stat_flag: base.old_stat_flag, first_line: base.first_line,
    cycle_counter: base.cycle_counter,
    framebuffer: base.framebuffer, frame: base.frame, ran_bios: base.ran_bios,
    sprites: @[],
  )
  when STAT_IRQ_SPLIT:
    result.irq_mode = base.irq_mode
    result.irq_ly   = base.irq_ly

proc fifo_arm_window*(ppu: GbFifoPpu) =
  ## Re-derive the one `lx` the shifter has to watch for on this line. Called
  ## from every write that can move one of the four inputs (LCDC, WX, the WY
  ## latch) and from fifo_reset_bg, which is where the fourth (fetching_window)
  ## moves. Nothing here is on a per-dot path.
  ppu.win_lx =
    if not window_enabled(ppu): WIN_LX_OFF
    elif ppu.fetching_window:   int32(ppu.wx) - 8
    elif ppu.window_trigger:    int32(ppu.wx) - 7
    else:                       WIN_LX_OFF

method reset_render_scratch*(ppu: GbFifoPpu) =
  ## Clear the FIFO/fetcher scratch to its clean pre-line state so a state
  ## load onto a running core can't leave a runaway lx or stale FIFO
  ## contents. Bit-identical to normal operation: none of this is read at
  ## vblank (where states are captured), and it is fully reset again on the
  ## next mode 2->3 transition.
  fifo_clear(ppu.fifo)
  fifo_clear(ppu.fifo_sprite)
  ppu.fetch_counter = 0
  ppu.fetcher_x = 0
  ppu.lx = 0
  ppu.smooth_scroll_sampled = false
  ppu.dropped_first_fetch = false
  ppu.fetching_window = false
  ppu.fetching_sprite = false
  ppu.win_lx = WIN_LX_OFF
  ppu.bg_pixels_pushed = false
  ppu.obj_penalty = 0
  ppu.obj_tile_fx = -1
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
  when defined(gb_m3_trace):
    echo "LATCH ly=", ppu.ly, " dot=", ppu.cycle_counter, " scx=", ppu.scx
  ppu.smooth_scroll_sampled = true
  if ppu.fetching_window:
    ppu.lx = int32(-max(0, 7 - int(ppu.wx)))
    if ppu.wx == 0 and (ppu.scx and 7) > 0:
      ppu.lx += 1
  else:
    ppu.lx = int32(-(7 and int(ppu.scx)))

# `-d:gb_win_trace` is the instrument the window model below was derived with:
# one line per WY/WX/LCDC write (line, dot within the line, mode, old and new
# value), one per window start and one per mode 3 end. A gambatte window family
# differs only in which M-cycle its write lands on, so printing that dot next to
# the filename's expected value turns the family into an equation for the dot
# the PPU samples that register on. Compiled out of every shipping build.
proc fifo_reset_bg*(ppu: GbFifoPpu; fetching_window: bool) =
  when defined(gb_win_trace):
    if fetching_window:
      echo "WINSTART ly=", ppu.ly, " dot=", ppu.cycle_counter, " lx=", ppu.lx,
           " wx=", ppu.wx, " scx=", ppu.scx
  fifo_clear(ppu.fifo)
  ppu.fetcher_x = 0
  ppu.fetch_counter = 0
  ppu.fetching_window = fetching_window
  ppu.bg_pixels_pushed = false
  # Whatever tile an object last paid the BG-fetch wait for is gone: this
  # restarts the fetch, so the next object is looking at a tile no object has
  # considered. fetcher_x restarting at 0 would otherwise alias the BG's first
  # tile onto the window's.
  ppu.obj_tile_fx = -1
  if fetching_window: inc ppu.current_window_line
  fifo_arm_window(ppu)

proc fifo_reset_sprite*(ppu: GbFifoPpu) =
  fifo_clear(ppu.fifo_sprite)
  ppu.fetching_sprite = false
  ppu.obj_penalty = 0

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
        # The fine scroll is the FETCHER's, not the shifter's: the throw-away
        # first fetch IS the mechanism that implements the SCX & 7 discard, so
        # SCX is latched when that fetch completes rather than several dots
        # later when the shifter first finds a pixel to look at. mealybug
        # m3_scx_low_3_bits brackets the latch with two SCX writes one M-cycle
        # apart -- one has to reach it and the other must not -- and only the
        # fetcher-side point sits between them.
        if not ppu.smooth_scroll_sampled: fifo_sample_smooth_scroll(ppu)
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

# ---- The OBJ penalty ------------------------------------------------------
#
# Pan Docs, Rendering / "OBJ penalty algorithm", on the object that is about to
# be drawn ("The Pixel" is its leftmost pixel, transparent or not):
#
#   1. Determine the tile (background or window) that The Pixel is within.
#   2. If that tile has NOT been considered by a previous OBJ yet:
#      1. Count how many of that tile's pixels are strictly to the right of
#         The Pixel.
#      2. Subtract 2.
#      3. Incur this many dots of penalty, or zero if negative (from waiting
#         for the BG fetch to finish).
#   3. Incur a flat, 6-dot penalty (from fetching the OBJ's tile).
#
# Both halves fall straight out of this renderer's own state:
#
#   * The BG FIFO holds exactly the not-yet-emitted pixels of the tile being
#     displayed, so at the trigger dot it holds The Pixel plus everything
#     strictly to its right. Step 2 is therefore `fifo.size - 1 - 2`, floored
#     at 0, with no register decode at all -- it is right through a mid-line
#     SCX change and through the window, both of which change which tile The
#     Pixel is in without changing what the FIFO holds.
#   * "That tile has not been considered yet" is `fetcher_x` (the fetcher's
#     tile counter) differing from the one the last wait was charged against.
#     fetcher_x only advances on a push, and a push cannot happen while an
#     object has the shifter stopped, so every object landing in one displayed
#     tile sees the same value.
#
# An object at OAM X 0..7 hangs off the left edge, so The Pixel is in the tile
# BEFORE the first on-screen one and the trigger dot is not its own dot; see the
# `lag` term at the trigger for how that is recovered. Pan Docs' X=0 exception
# ("always incurs an 11-dot penalty, regardless of SCX") then needs no special
# case: such an object triggers on the first dot the BG FIFO is non-empty, where
# the FIFO is a full 8 whatever SCX is, and 6 + (8-1-2) is 11. The older
# `pixel_fifo.md` rule -- lengthen by SCX&7 for an object at X=0 -- used to be
# spelled out as its own fetch phase; it is gone, because it double-counts that
# same dot budget.
#
# ---- Why these two numbers and not others ---------------------------------
# Both terms were swept independently against the whole of gambatte/sprites
# (476 rows), writing the penalty as `FETCH + max(0, fifo.size - SUB)`:
#
#   SUB        1     2     3     4     5
#   FETCH=4   306   256   254   256   254
#   FETCH=5   267   304   254   250   252
#   FETCH=6   263   269  [391]  266   262
#   FETCH=7   251   251   254   312   267
#   FETCH=8   250   251   251   254   286
#
# (6, 3) -- Pan Docs' flat 6 and its "minus 2" -- is the unique optimum and it
# is not close: the 9-diagonal (FETCH + 8 - SUB = 11, i.e. everything that gets
# the X=0 case right and the rest wrong) tops out at 312. The shipping value of
# the pre-existing OBJ model was a flat 8 with no wait at all, which is that
# table's bottom-right corner.
#
# What this does NOT model is the object fetch being CANCELLED mid-flight by
# clearing LCDC.1, which Pan Docs describes and gambatte's
# sprites/sprite_late_disable_* rows measure.
const OBJ_FETCH_DOTS {.intdefine.} = 6'i32
const OBJ_WAIT_SUB {.intdefine.} = 3'i32

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
    # A second object at the same X is in the same BG tile by construction, so
    # it never re-pays the wait (Pan Docs' "if that tile has not been considered
    # by a previous OBJ yet"). What it does pay is another whole object fetch:
    # 6 dots -- 2 to put the tile row address on the bus and 2 for each of the
    # two data bytes. mooneye acceptance/ppu/intr_2_mode0_timing_sprites stacks
    # 1..10 objects at X=0 and its expectations step by exactly 6 dots per
    # extra object.
    ppu.obj_penalty = OBJ_FETCH_DOTS

proc tick_sprite_fetcher*(ppu: GbFifoPpu; gb: GB) =
  ## One dot of an object fetch. The shifter is stopped for the whole of it, so
  ## the only thing that varies is how many dots it lasts -- see the trigger in
  ## tick_shifter for where that count comes from.
  #
  # The BG fetcher runs for the WAIT and is stopped for the object's own fetch.
  # That split is the two halves of the penalty read literally: the wait exists
  # because a BG fetch is in flight and has to finish, and the six dots after it
  # are the object's own VRAM reads, which the BG fetcher cannot overlap because
  # there is one address bus. Neither half can reach the BG FIFO -- the shifter
  # is stopped, so the FIFO cannot empty and try_push_bg_pixels cannot fire --
  # which is also what keeps fetcher_x (the tile identity the wait is charged
  # against) still for the duration; the fetcher parks on fsPushPixel instead and
  # re-locks to the FIFO on the next tile boundary, so mode 3's length is exactly
  # the penalty above with nothing added.
  #
  # Running it for the object's fetch as well is a real alternative and it was
  # measured, not assumed. It costs no dots either (the same park absorbs it),
  # but it advances the BG fetcher 6 steps further, which moves every later BG
  # VRAM read on the line -- and the mealybug references say that is wrong:
  # m3_scy_change 92.6% -> 78.3%, m3_lcdc_tile_sel_win_change 92.9% -> 91.4%,
  # m3_bgp_change_sprites 90.5% -> 89.1%, with eight more m3_* rows down and
  # none up. It buys 15 gambatte sprites/space rows (374 -> 389), all of them
  # `_2` rows one M-cycle from their boundary, i.e. inside the STAT-read model's
  # own known error (see STAT_MODE_HOLD in ppu.nim). Stopping the fetcher
  # entirely, the third option, costs a resync dot per object and breaks the
  # mode 3 length outright (172 + 11N becomes 172 + 11N + 1).
  if ppu.obj_penalty > OBJ_FETCH_DOTS: tick_bg_fetcher(ppu, gb)
  dec ppu.obj_penalty
  if ppu.obj_penalty <= 0:
    # The tile row lands on the last dot of the fetch. LCDC.2 and the OBP
    # registers are read here, so this is the dot the gambatte late_sizechange
    # family brackets.
    sprite_fetch_merge(ppu, gb)

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
# **This ships at 0 and is now a diagnostic, not a fix.** The M-cycle the
# measurement below found was real, but it was never the pipeline's to pay: it
# was the CPU write landing an M-cycle late. mem_write now commits a write's
# byte at the START of its M-cycle, which is where its own VRAM/OAM lock is
# already decided, and the residual this constant existed to absorb is gone.
# Turning it up now double-counts the same M-cycle. What follows is the
# derivation, kept because it is the instrument for re-deriving the fetch phase.
#
# ---- Why an M-cycle and not a dot count -----------------------------------
# A CPU write reaches the bus once per M-cycle, and dingbat USED TO run the
# M-cycle's worth of PPU dots BEFORE handing the byte to write_byte -- so a
# write committed at the END of its M-cycle. The VRAM/OAM locks disagreed with
# that: a write was admitted on the LATCHED mode (`read_mode`, the mode at the
# START of the M-cycle) where a read is admitted on the live one. The lock and
# the data are one event on hardware, so the data has to commit at the start of
# the M-cycle too, and the pipeline was one M-cycle behind what this renderer
# assumes purely because the write was.
#
# One M-cycle is 4 dots at normal speed and 2 in double speed (Pan Docs,
# "Dots": "4 dots per Normal Speed M-cycle, and 2 per Double Speed M-cycle"),
# which is why the lead below is latched per line from `current_speed` rather
# than being a constant. That factor of two is what identified the quantity --
# see the staircase measurement.
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
# ---- Why moving the PIPELINE was the wrong half of it ---------------------
# The lead is injected as idle dots at the HEAD of mode 3 and paid back by
# retiring the fetcher `m3_lead` pixels early at the tail, so mode 3's length is
# unchanged. That accounting is exact everywhere except the last `m3_lead`
# pixels of a line, where a sprite or window fetch can still stall the shifter:
# the flag then wants to go up mid-fetch, and neither "retire before the fetch"
# nor "retire after it" is that dot. Measured at 1 (2026-08-02, full runner):
# gambatte 3253 -> 3256 and thirteen mealybug/age rows up, but mealybug
# m3_scx_low_3_bits 100% -> 98.6% (a green row) and gambatte sprites 257 -> 255,
# window 258 -> 256, enable_display 131 -> 128, m0enable 143 -> 142 -- every one
# of them a WX=166 / OBJ X=166 / SCX-at-H-Blank row, i.e. the tail accounting.
#
# Moving the WRITE instead (mem_write) buys the same thirteen rows with none of
# that tail: the pipeline never moves, so there is nothing to account for.
# Same tree, same day: gambatte 3253 -> 3311, sprites 257 -> 260, window
# 258 -> 262, m0enable 143 -> 147, enable_display unmoved, and
# m3_scx_low_3_bits stays green (its own latch moved to the fetcher, see
# fifo_sample_smooth_scroll's caller). That is why this constant is 0 and the
# fix is a bus-layer one.
const M3_PIPE_MCYCLES {.intdefine.} = 0
const M3_PIPE_DELAY {.intdefine.} = 0

# Dots the mode 3 -> 0 edge comes early WITHOUT the pipeline moving with it: the
# fetcher retires this many pixels before the end of the line and the tail is
# burst on that dot, but nothing is injected at the head, so mode 3 gets SHORTER
# by exactly this many dots and every pixel is where it was. That is the one
# knob that expresses "mode 3's length is wrong" as opposed to "the pipeline's
# phase is wrong", which is why it is separate from the two above.
#
# **It ships at 0 and the measurement below is why it must.** GBMicrotest's
# hblank_int_scx0..7 splits by SCX & 3, which reads like a per-residue length
# error; it is not. The eight ROMs are byte-identical apart from the SCX they
# write, so each one exercises exactly one residue and a sweep of THIS constant
# reads out all eight windows at once -- a per-residue table would carry no
# extra information, which is the first thing that should have been suspicious
# about the per-residue reading. Sweeping -4..+4 (2026-08-03):
#
#   SCX&7          0      1      2      3      4      5      6      7
#   dingbat's L   172    173    174    175    176    177    178    179
#   accepts       -3..0  <=-1   <=-2   any    -3..0  <=-1   <=-2   -2..+1
#   i.e. L in    169-172 169-172 169-172  --  173-176 173-176 173-176 177-180
#
# (SCX&7 = 3's ROM writes verdict $01 unconditionally -- it is a dud and
# constrains nothing. The rest resolve to 4 dots because the ROM counts `INC A`s,
# one M-cycle each: the family can never do better than an M-cycle.) Solving
# `c + (SCX&7)` against those seven windows leaves exactly one c, and it is not
# 172: c = 170. A UNIFORM two dots, no residue-dependent term anywhere -- and
# directly confirmed, since a uniform -2 passes all eight while -1 and -3 each
# leave four failing. The SCX & 3 "split" is what a uniform 2-dot error looks
# like when a monotone ramp of eight lengths one dot apart is sampled on a 4-dot
# grid, and nothing about the fine-scroll discard is inconsistent per residue.
#
# What refuses the 2 dots is everything else that pins the same edge. Full
# runner, one build, uniform -2 (2026-08-03):
#
#   GBMicrotest      400 -> 420   (hblank_int_scx{1,2,5,6} and their _if_d and
#                                  _nops_a/b siblings, ppu_sprite0_scx{1,2,5,6}_b,
#                                  sprite4_4..7_b, win{1,2,8..15}_b)
#   ... minus        int_hblank_{nops,incs,halt}_scx{1,2,5,6} (12 rows, green
#                    at 0), win{0_scx3,5,6}_a
#   mooneye          112 -> 111   acceptance/ppu/hblank_ly_scx_timing-GS
#   mooneye-wilbert   82 -> 78    hblank_ly_scx_timing-GS + four
#                                 intr_2_mode0_scx{1,2,5,6}_timing_nops
#   gambatte        3534 -> 3384  (sprites -87, window -21, halt -18, m0enable
#                                  -11, m2int_m0irq -5, m2int_m3stat -4, ...)
#
# Note which rows those are: the four wilbertpol rows and the twelve GBMicrotest
# rows that go red are the SAME residues {1,2,5,6} that go green, measuring the
# same edge from the other side. The mode 3 length this file computes is right;
# the residual is somewhere else. See LCD_ON_LINE0_TRIM in gb.nim for the other
# two routes to the same 2 dots and what refuses each of them.
const M3_END_EARLY {.intdefine.} = 0
# Compiles the pipeline-lead machinery out entirely when all three terms are
# off, which is what the `-d:M3_PIPE_MCYCLES=0 -d:M3_PIPE_DELAY=0
# -d:M3_END_EARLY=0` control build for an A/B wants; every guard below is a
# compile-time short circuit at that setting, not a runtime test.
const M3_PIPE_LEAD_ANY = M3_PIPE_MCYCLES != 0 or M3_PIPE_DELAY != 0 or
                         M3_END_EARLY != 0

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
  ## The caller reaches this through the same cached `lx == win_lx` compare the
  ## window START uses (GbFifoPpu.win_lx), so neither rule costs the shifter a
  ## register decode on a dot it cannot fire on; the fetcher-position test is
  ## inside that branch, where it runs a handful of times a line.
  # Inserted BEHIND the head, not in front of it: the caller runs before this
  # dot's pixel leaves the shifter, and the pixel being displaced is the NEXT
  # one. Unshifting and then swapping the two front entries is that insert --
  # the head keeps the pixel this dot emits and the colour-0 entry lands one
  # place back, which is where an unshift at the end of the previous dot put
  # it. Depth is 16 and the FIFO never holds more than 8, so the extra entry
  # cannot collide with the tail.
  let h = (ppu.fifo.head - 1) and 15
  ppu.fifo.data[h] = ppu.fifo.data[ppu.fifo.head]
  ppu.fifo.data[ppu.fifo.head] =
    GbPixel(color: 0, palette: 0, oam_idx: 0, obj_to_bg: 0)
  ppu.fifo.head = h
  inc ppu.fifo.size

proc tick_shifter*(ppu: GbFifoPpu; gb: GB) =
  if ppu.fifo.size > 0:
    if not ppu.smooth_scroll_sampled: fifo_sample_smooth_scroll(ppu)
    # Check for sprite at current pixel BEFORE popping/rendering
    if sprite_enabled(ppu) and ppu.sprites.len > 0 and
       int(ppu.lx) + 8 >= int(ppu.sprites[0].x):
      ppu.fetching_sprite = true
      # Where The Pixel sits in the BG tile it belongs to. `lx` is the pixel the
      # shifter was about to emit and `8 - fifo.size` is its index inside the
      # tile the FIFO is holding; The Pixel is `lag` pixels to the LEFT of it,
      # which is zero for any object that starts on screen (the trigger is the
      # dot lx reaches it) and 1..8 for one hanging off the left edge, whose
      # first pixel was never a dot of its own. That is the whole difference
      # between the two, and it is why an object at OAM X 1..7 is charged
      # against the tile BEFORE the first one -- including X = 0, which is what
      # leaves the leftmost on-screen tile unconsidered for the next object
      # (gambatte sprites/10spritesPrLine_1xpos0 measures exactly that against
      # 10spritesPrLine: same ten objects, same mode 3).
      let lag = ppu.lx + 8 - int32(ppu.sprites[0].x)
      let idx = 8 - int32(ppu.fifo.size) - lag
      let tile = int32(ppu.fetcher_x) + (if idx < 0: -1'i32 else: 0'i32)
      # THIS dot is the first of the penalty -- the shifter has already decided
      # not to emit a pixel on it -- so the countdown is one short of the total.
      # See the OBJ penalty block above for where the two terms come from.
      var pen = OBJ_FETCH_DOTS - 1
      if ppu.obj_tile_fx != tile:
        ppu.obj_tile_fx = tile
        pen += max(0'i32, (7 - (idx and 7)) - (OBJ_WAIT_SUB - 1))
      ppu.obj_penalty = pen
      return
    # ---- The window's own trigger -----------------------------------------
    #
    # Pan Docs, "Window": the window is drawn from the pixel whose X coordinate
    # is WX - 7, on any line at or after the one where the WY condition
    # triggered, while LCDC.5 is set. Three things about this test are load
    # bearing and each is settled by a gambatte family that brackets it:
    #
    #  * It is an EQUALITY on the pixel about to be emitted, not `lx + 7 >= wx`.
    #    A `>=` cannot be un-satisfied, so anything that arms the window LATE --
    #    a WY write that lands mid-line, LCDC.5 going back up -- starts it at
    #    whatever pixel the shifter had reached, which hardware does not do.
    #    window/arg/late_wy_FFto2_ly2_1..3 write WY = LY at three consecutive
    #    M-cycles of the line and want the window on the first two and NOT on
    #    the third, and the dot that separates them moves with WX and with
    #    SCX & 7 -- i.e. it is this comparison's own dot, not a fixed one.
    #    (Measured DMG, the write dot the family brackets: WX 0 -> 83,
    #    WX 7 -> 90, WX 15 -> 98, and +1 per SCX & 7. That is
    #    `83 + WX + (SCX and 7)`, which is exactly the dot this line runs on.)
    #
    #  * It is asked BEFORE the pixel is emitted, not after `inc lx`. Same dot's
    #    worth of registers either way -- a CPU write commits at the top of its
    #    M-cycle, so both see it -- but the pre-emit form is the one that can
    #    fire at the FIRST pixel of a line, which is what a window at WX = 7
    #    (screen x = 0) needs. Post-emit, lx never takes the value 0 with
    #    SCX & 7 = 0 and WX = 7 could only be served by the mode-2 special case
    #    below, which starts the line as a window line and charges nothing for
    #    it (gambatte m2int_wx07_m3stat_1/2 measure that charge).
    #
    # The whole conjunction is precomputed into `win_lx` (see GbFifoPpu), so
    # what is left on the per-dot path is one compare, shared with the
    # re-trigger rule below it. That matters: this is the mode 3 dot loop, and
    # a SECOND per-dot branch here -- the shape this started as, with the two
    # rules on either side of the emit -- measured +1.7% of retired
    # instructions on blargg 01-special and +0.9% on Pokemon Blue.
    #
    #  * The restart resumes at fetcher step 1, not 0. Pan Docs counts the
    #    window's cost as 6 dots from the fetch restart; this renderer idles for
    #    the FIRST two steps of its eight where hardware idles for the last two
    #    (see the fetch-phase note in fifo_tick_slow), so a restart from step 0
    #    puts the window's first pixel one dot later than hardware does.
    #    gbmicrotest win0_a/_b .. win15_a/_b bracket that end-of-mode-3 dot per
    #    WX and want the 5 dots this gives; taking it from step 0 instead costs
    #    win10_scx3_b and win7_b (and buys 8 gambatte rows, all of them
    #    double-speed sprites/space rows -- the trade is documented in the
    #    commit rather than split, because the two suites disagree by exactly
    #    the one dot the fetch phase is out).
    if ppu.lx == ppu.win_lx:
      if not ppu.fetching_window:
        fifo_reset_bg(ppu, true)
        ppu.fetch_counter = 1
        return
      elif ppu.fetch_counter == WIN_REACT_PHASE and window_enabled(ppu):
        # The re-trigger edge, injected in front of the pixel this dot is about
        # to emit rather than behind the one it just emitted -- the same
        # displacement, one dot earlier, so it can share the compare above.
        window_reactivate(ppu)
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
  ##     There is deliberately no `ly >= wy` term next to `window_trigger`
  ##     here or at the trigger itself: the latch IS the WY condition (Pan
  ##     Docs' "at any point in the frame"), and re-testing the register
  ##     against LY makes a WY moved out of range mid-frame retract a window
  ##     hardware keeps drawing (gambatte window/arg/late_wy_1toFF_*).
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
       int(ppu.wx) <= GB_WIDTH + 6: return false
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

template fifo_skip_target(ppu: GbFifoPpu; gb: GB; m: uint8): int32 =
  ## The next dot of this line an idle mode (0, 1 or 2) has something to do on.
  ##
  ## This is on the hottest path in the PPU -- fifo_tick's lazy idle span asks
  ## it once per M-cycle of every memory access -- so the shipping build gets
  ## the plain three-way choice and nothing else. Mode 2 ends at dot 80 and
  ## every other idle mode runs to the end of the line, except line 143's mode
  ## 0, which has the CGB early mode-2 pulse to visit first (M2_144_EARLY_DOT,
  ## see m2_line144). `ppu.ly == 143` leads that test because it is false on 153
  ## of every 154 lines, which keeps its cost to one compare.
  ## A template, not a proc: `inline` is advice and this one is asked ~17,500
  ## times a frame from a body that is itself inlined into the bus path. Left
  ## as a proc it measured +1.0% of retired instructions on both a DMG and a
  ## CGB title -- the whole cost of a call, for three compares.
  when not STAT_IRQ_SPLIT:
    if m == 2: 80'i32
    elif ppu.ly == 143 and m == 0 and gb.cgb_enabled: M2_144_EARLY_DOT
    else: gb_line_end(ppu)
  else:
    # Every boundary is two stops in a STAT_IRQ_LEAD build, `lead` dots apart:
    # the interrupt line's copy of the mode turns over first, the mode flag
    # after it. The comparisons are `>=`, not `>`: a stop the counter is
    # already sitting on has not been *processed* yet (the skip that landed on
    # it returned before the loop body ran), so it is still the next thing to
    # do. At normal speed the lead's dot and M2_144_EARLY_DOT coincide; in
    # double speed they do not, hence three candidates rather than two.
    let boundary = if m == 2: 80'i32 else: gb_line_end(ppu)
    result = boundary
    let irq_dot = boundary - stat_irq_lead(gb)
    if irq_dot >= ppu.cycle_counter: result = irq_dot
    if ppu.ly == 143 and m == 0 and gb.cgb_enabled and
       M2_144_EARLY_DOT >= ppu.cycle_counter and M2_144_EARLY_DOT < result:
      result = M2_144_EARLY_DOT

when STAT_IRQ_SPLIT:
  proc fifo_irq_line_advance(ppu: GbFifoPpu; gb: GB) =
    ## The STAT interrupt line's own line boundary, STAT_IRQ_LEAD M-cycles
    ## before the flag domain's below. Mirrors it exactly, on irq_ly /
    ## irq_mode: LY advances, line 144 enters vblank, line 0 enters mode 2.
    ## What it must NOT do is anything the CPU reads back, or the vblank
    ## interrupt -- see the write-up at STAT_IRQ_LEAD.
    if ppu.irq_mode == 1:
      # Inside vblank LY only advances while it is nonzero: line 153 has
      # already snapped it back to 0 (below), and that 0 is line 0's.
      if ppu.irq_ly != 0: ppu.irq_ly += 1
      if ppu.irq_ly == 0: ppu.irq_mode = 2
    else:
      ppu.irq_ly += 1
      ppu.irq_mode = if int(ppu.irq_ly) == GB_HEIGHT: 1'u8 else: 2'u8
    ppu_handle_stat_interrupt(ppu, gb)

  proc fifo_irq_m0_ready(ppu: GbFifoPpu; lead: int32): bool {.inline.} =
    ## Will the fetcher have retired `lead` dots from now? That is when the
    ## STAT interrupt line's mode 0 rises, ahead of the flag's.
    ##
    ## The shifter takes one pixel per dot through the tail of a line, so "lx
    ## is within `lead` of the end" IS the lookahead -- except where an object
    ## or a not-yet-started window still owes the fetcher work, which holds
    ## mode 3 open past that point exactly as fetcher_retired describes.
    if ppu.lx < int32(GB_WIDTH) - lead: return false
    if ppu.lx >= GB_WIDTH: return true
    if ppu.fetching_sprite: return false
    if ppu.sprites.len > 0 and int(ppu.sprites[0].x) <= GB_WIDTH + 7: return false
    if not ppu.fetching_window and ppu.window_trigger and window_enabled(ppu) and
       int(ppu.wx) <= GB_WIDTH + 6: return false
    true

proc fifo_tick_slow(ppu: GbFifoPpu; gb: GB; cycles: int) =
  ## Everything the PPU can do in a span that is NOT a pure idle skip. Split
  ## out of fifo_tick so the idle case (below) inlines into the caller; the
  ## read_mode latch and the dots_since_frame counter are updated by fifo_tick
  ## on both paths before this runs.
  if lcd_enabled(ppu):
    var remaining = cycles
    when STAT_IRQ_SPLIT:
      # Dots the STAT interrupt line runs ahead of the mode flag. Read once: a
      # speed switch cannot land inside a tick, and `mode_flag=` re-syncs the
      # irq domain anyway if one ever stepped over a lead dot.
      let lead = stat_irq_lead(gb)
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
        let target = fifo_skip_target(ppu, gb, m)
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
        #    the instrument for that one. m3_bgp_change carries no objects at
        #    all and still wants its whole frame ~3 pixels to the left, so that
        #    residual is the palette write's own and nothing else's.
        #  * Lines carrying an object used to mismatch because this renderer
        #    charged a FLAT 8 dots for one; it now charges what Pan Docs'
        #    "OBJ penalty algorithm" says (see the OBJ penalty block above).
        #    What is left of that is the BG fetcher's own phase: hardware
        #    finishes a tile fetch six dots before that tile's first pixel and
        #    idles for the last two, where this fetcher idles for the FIRST
        #    two of the eight and finishes on the pixel itself. The two agree
        #    on the 8-dot cadence and on every VRAM read's dot, so nothing on
        #    an object-free line can see the difference -- but it is why the
        #    object wait has to be read off the FIFO's occupancy rather than
        #    off `fetch_counter`, and why an object whose wait is short leaves
        #    the fetcher one dot out of step (gbmicrotest sprite4_4..7_b:
        #    mode 3 comes out 201 where four objects at tile offset 4 want
        #    200). Re-phasing the fetcher would move every BG VRAM read by
        #    2-3 dots and re-open bgtiledata/bgtilemap/scx_during_m3, so it is
        #    a change of its own, not a tweak to this one.
        while remaining > 0 and not fetcher_retired(ppu):
          when STAT_IRQ_SPLIT:
            # The mode-0 STAT source rises `lead` dots before the flag does.
            # The flag's dot is the one this loop exits on, so asking at the
            # TOP of a dot puts this exactly `lead` dots ahead of it.
            if ppu.irq_mode == 3 and ppu.lx >= int32(GB_WIDTH) - lead and
               fifo_irq_m0_ready(ppu, lead):
              ppu_set_irq_mode(ppu, gb, 0'u8)
          fifo_pipeline_dot(ppu, gb)
          ppu.cycle_counter += 1
          dec remaining
        continue
      dec remaining
      case m
      of 2:  # OAM search
        when STAT_IRQ_SPLIT:
          # Mode 2 ends for the interrupt line a lead before it ends for the
          # mode bits. Nothing else about the boundary moves.
          if ppu.cycle_counter == 80 - lead: ppu_set_irq_mode(ppu, gb, 3'u8)
        if ppu.cycle_counter == 80:
          ppu.`mode_flag=`(3'u8, gb)
          # WX below 7 puts the window's first pixel LEFT of the screen, where
          # the shifter's equality above can never reach it (lx starts at
          # -(SCX and 7), which is 0..-7, and WX - 7 is -7..-1). Pan Docs calls
          # WX < 7 unreliable on hardware; what this renderer does with it is
          # start the line as a window line, with the window's own fine scroll
          # (see fifo_sample_smooth_scroll) and no restart to pay for --
          # gambatte m2int_wx00_m3stat_1/2 and gbmicrotest win0_scx3_a/_b pin
          # that. WX = 7 is NOT in here: that one is a perfectly ordinary
          # window start at screen x = 0 and pays the ordinary restart.
          fifo_reset_bg(ppu,
            window_enabled(ppu) and
            ppu.wx < 7 and ppu.window_trigger)
          fifo_reset_sprite(ppu)
          ppu.lx = 0
          when M3_PIPE_LEAD_ANY:
            # Latched per line, not a constant: the M-cycle half of the lead is
            # 4 dots at normal speed and 2 in double speed, and a ROM can switch
            # speed between two lines. `current_speed` is 0 or 1.
            ppu.m3_lead = int32(M3_PIPE_MCYCLES * (4 shr gb.memory.current_speed) +
                                M3_PIPE_DELAY + M3_END_EARLY)
            # Only the PIPE terms are paid back at the head. M3_END_EARLY's
            # share is not, which is the whole difference between "the pipeline
            # runs late" and "mode 3 is short".
            ppu.m3_delay = int(ppu.m3_lead) - M3_END_EARLY
          ppu.smooth_scroll_sampled = false
          ppu.dropped_first_fetch = false
          ppu.sprites = fifo_get_sprites(ppu, gb)
          when defined(gb_m3_len):
            if gb_m3_len_lines > 0:
              var xs = ""
              for s in ppu.sprites: xs.add($int(s.x) & ",")
              echo "M3IN ly=", ppu.ly, " scx=", int(ppu.scx), " wx=", int(ppu.wx),
                   " wy=", int(ppu.wy), " lcdc=", toHex(ppu.lcd_control, 2),
                   " objx=", xs
      of 3:  # Drawing
        # Mode 3 ends the dot AFTER the fetcher retires, not on the same dot.
        # Deferring the mode 0 transition by one dot makes mode 3 the
        # hardware-correct 172 dots for SCX=0 (was 171) without changing any
        # rendered pixel. With a nonzero lead the shifter is still `m3_lead`
        # pixels from the end of the line here; the burst below finishes them.
        if fetcher_retired(ppu):
          when defined(gb_win_trace):
            echo "M3END ly=", ppu.ly, " dot=", ppu.cycle_counter, " len=", ppu.cycle_counter-80
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
          when defined(gb_m3_len):
            if gb_m3_len_lines > 0:
              dec gb_m3_len_lines
              echo "M3LEN ly=", ppu.ly, " len=", ppu.cycle_counter - 80
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
        when STAT_IRQ_SPLIT:
          if ppu.cycle_counter == gb_line_end(ppu) - lead: fifo_irq_line_advance(ppu, gb)
        if ppu.cycle_counter == gb_line_end(ppu):
          when STAT_READ_HOLD: ppu.stat_hold_until -= ppu.cycle_counter
          when LCD_ON_TRIM_ANY:
            if ppu.lcdon_lines > 0: dec ppu.lcdon_lines
          ppu.cycle_counter = 0
          ppu.ly += 1
          # The irq domain got here a lead ago; this is its catch-up for the
          # unsplit build and for anything that stepped over that dot.
          when STAT_IRQ_SPLIT: ppu.irq_ly = ppu.ly
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
        when STAT_IRQ_SPLIT:
          if ppu.cycle_counter == 456 - lead: fifo_irq_line_advance(ppu, gb)
        if ppu.cycle_counter == 456:
          ppu.cycle_counter = 0
          when STAT_READ_HOLD: ppu.stat_hold_until -= 456
          if ppu.ly != 0:
            ppu.ly += 1
            ppu.read_mode = ppu.read_mode or LY_JUST_CHANGED
          when STAT_IRQ_SPLIT: ppu.irq_ly = ppu.ly
          ppu_handle_stat_interrupt(ppu, gb)
          if ppu.ly == 0:
            ppu.`mode_flag=`(2'u8, gb)
        when STAT_IRQ_SPLIT:
          # LY 153 snaps back to 0 partway through the line, and the LYC=0
          # source sees it a lead ahead of the readable LY -- one edge, two
          # clocks. The source is what gambatte lyc0int_* and lyc153int_* time;
          # the flag half below is what a STAT/LY read sees.
          if ppu.ly == 153 and ppu.irq_ly == 153 and
             ppu.cycle_counter > 4 - lead:
            ppu.irq_ly = 0
            ppu_handle_stat_interrupt(ppu, gb)
        if ppu.ly == 153 and ppu.cycle_counter > 4:
          ppu.ly = 0
          when STAT_IRQ_SPLIT: ppu.irq_ly = 0
      else: discard
      ppu.cycle_counter += 1
  else:
    ppu.cycle_counter = 0
    ppu.`mode_flag=`(0'u8, gb)
    ppu.ly = 0
    when STAT_IRQ_SPLIT: ppu.irq_ly = 0
    when STAT_READ_HOLD: ppu.stat_hold_until = 0
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
    let target = fifo_skip_target(ppu, gb, m)
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
