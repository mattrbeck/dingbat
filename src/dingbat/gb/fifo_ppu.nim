# GB FIFO PPU renderer (included by gb.nim)

# ---- -d:gb_px_trace --------------------------------------------------------
#
# Diagnostic pipeline trace (tools only; compiled out of every shipping build).
# Where `-d:gb_m3_trace` prints one line per mode 3 DOT -- the fetcher's state
# machine as it steps -- this prints one line per pipeline EVENT, which is what
# turns a reference frame into an equation for the byte behind a pixel:
#
#   FTILE   the tile-map read: address, tile number, LCDC at that dot
#   FDATA   each bitplane read: address, row, byte, LCDC at that dot
#   PUSH    the eight pixels entering the BG FIFO, with the `lx` they show at
#   SPR     an object's two bitplane bytes as they are merged
#   PX      each emitted pixel: the BG and OBJ FIFO entries and LCDC
#
# Shares `-d:GB_TRACE_LY` with gb_m3_trace (-1 traces every drawn line). What
# it is for: PUSH plus the reference frame gives the bitplane bytes hardware
# used, so a wrong pixel becomes a wrong BYTE with an address next to it, and
# PX plus the LCDC write dots gives the register the mixer read against the dot
# the pixel left the FIFO. The mixer's dot (fifo_recompose_last) and the
# cgb-acid-hell residual in docs/gb-failure-triage.md were both read off this.

# `lx` runs -7..160, so this is unreachable: with win_lx parked here the
# shifter's per-dot compare against it is simply never true.
const WIN_LX_OFF = -128'i32

# `tail_dot0` parked out of reach. The H-Blank recompose reads the shifter's
# position back as `cycle_counter - tail_dot0`, so a large NEGATIVE park puts
# that position a million pixels past the end of the line, where every span it
# can ask for is empty. It is what "no tail is in flight" means -- see
# fifo_recompose_last.
const TAIL_DOT0_OFF = -(1'i32 shl 20)

proc mixer_note_stop(ppu: GbFifoPpu) {.inline.} =
  ## The shifter is about to STOP on this dot: note the dot base the run it is
  ## interrupting was on, and the `lx` the next run will start at. Two stores,
  ## on a path that runs once per object fetch and once per FIFO reset -- never
  ## in the dot loop, which is the whole point. The derivation and the three
  ## sites are at MIXER_TAIL_DOTS in gb.nim and above fifo_recompose_span.
  when MIXER_DOT_LAG != 0:
    ppu.tail_dot0 = ppu.cycle_counter - ppu.lx
    ppu.mix_run = ppu.lx

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
    hdma5: base.hdma5,
    hdma_src: base.hdma_src, hdma_dst: base.hdma_dst,
    hdma_active: base.hdma_active,
    window_trigger: base.window_trigger,
    current_window_line: -1,
    win_lx: WIN_LX_OFF,
    obj_fix_from: OBJ_FIX_OFF,
    lcdc2_flip: [NO_LCDC2_FLIP, NO_LCDC2_FLIP],
    old_stat_flag: base.old_stat_flag, first_line: base.first_line,
    cycle_counter: base.cycle_counter,
    framebuffer: base.framebuffer, frame: base.frame, ran_bios: base.ran_bios,
    sprites: @[],
    cgb: gb.cgb_enabled,
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
    elif ppu.window_trigger:
      # ---- The comparator has ONE slot left of the shifter's first pixel ----
      #
      # `WX - 7` is the SCREEN x the window starts at, and this shifter's `lx`
      # starts at `-(SCX and 7)` -- so with SCX = 0 the target `-1` (WX = 6) is
      # one slot to the left of anything `lx` ever takes, and the equality can
      # never fire. On hardware it does, and mealybug m3_wx_6_change brackets it
      # on three CONSECUTIVE SCANLINES of one frame, which is as tight as this
      # suite gets.
      #
      # That ROM writes WX = 6 in mode 2 (dot 49), WX = LY at dot 93, and
      # WX = 80 at dot 189, with WY = 4 and SCX = 0. The shifter's first dot is
      # 94, so the value the comparator sees at its first slot is LY:
      #
      #   LY   WX at dot 94   WX - 7   hardware (photos/DMG-blob + expected/)
      #    4        4           -3     background, no window
      #    5        5           -2     background, no window
      #    6        6           -1     WINDOW, whole line (W row 0)
      #    7        7            0     WINDOW, whole line (W row 1)
      #
      # -1 fires and -2 does not, on adjacent lines of the same frame with
      # everything else identical. That is a two-sided bracket on a single slot,
      # not a fitted constant. Decoding the frame's tiles confirms the
      # consequence: hardware's window-line counter is one ahead of ours for the
      # whole frame, so from LY 8 down every window row we draw is the row above
      # the one hardware draws -- which is the entire 4611-pixel residual this
      # row had, and it is the row's LAST residual (it goes to 0).
      #
      # This is not `>=`. The comparator is an equality (see the three gambatte
      # brackets at the shifter's own test); what the evidence adds is that its
      # counter runs one lower than the emitted-pixel index, which is exactly
      # what "the window's first pixel is at screen x = -1" means physically.
      # A `>=` would fire at WX = 4 and WX = 5 too, and the table above says
      # hardware does not.
      #
      # Expressed as a clamp rather than a second compare because the compare is
      # in the mode 3 dot loop, where one extra branch measured +1.7% of retired
      # instructions (see M3_END_EARLY); `fifo_arm_window` runs on register
      # writes only, so the whole rule is free.
      #
      # NOT applied to the re-trigger branch above (`fetching_window`): the
      # window is already the fetch source there, nothing restarts, and no ROM
      # in the tree measures a re-trigger one slot left of the first pixel.
      let target = int32(ppu.wx) - 7
      let first  = -int32(7 and int(ppu.scx))
      when WIN_START_PRE_PIXEL != 0:
        if target == first - 1: first else: target
      else:
        target
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
  ppu.head_cycle = false
  ppu.fetching_window = false
  ppu.fetching_sprite = false
  ppu.win_lx = WIN_LX_OFF
  ppu.obj_penalty = 0
  ppu.obj_tile_fx = -1
  ppu.obj_fix_from = OBJ_FIX_OFF
  ppu.lcdc2_flip[0] = NO_LCDC2_FLIP
  ppu.lcdc2_flip[1] = NO_LCDC2_FLIP
  ppu.m3_delay = 0'u8
  ppu.tile_num = 0
  ppu.tile_attrs = 0
  ppu.tile_data_low = 0
  ppu.tile_data_high = 0
  # The mixer's held pairs, same category as the FIFOs and the fetch latches
  # above: per-line scratch that the save-state payload deliberately does not
  # carry (see this method's doc comment). It is only ever read by
  # fifo_recompose_last, which is guarded on mode 3 and on `lx >= 1`, or on
  # mode 0 behind a `tail_dot0` that only the tail burst sets, so the earliest
  # a loaded state can reach it is the first pixel of the first mode 3 after
  # the load -- which has already written it.
  ppu.mix = default(array[MIX_HOLD, GbMixHold])
  ppu.tail_dot0 = TAIL_DOT0_OFF
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
    # ---- A line that STARTS as a window line still pays SCX & 7 ------------
    #
    # `lx` starting negative is this renderer's discard: those pixels are
    # shifted out and not drawn, so each one is a dot. A line that starts as a
    # window line (WX < WIN_LINE_START_WX) discards `7 - WX` for the window's
    # own fine scroll -- and, until 2026-08-07, nothing at all for SCX, which
    # made mode 3 independent of SCX & 7 on exactly those lines.
    #
    # mealybug m3_window_timing_wx_0 is the instrument, and it is a ruler: WX =
    # 0, `SCX = LY`, and BGP driven black at a fixed dot of every line, so the
    # x at which black begins IS the count of dots consumed before x = 0, read
    # off once per scanline for all eight residues. Reference against ours,
    # SCX & 7 = 0..7:
    #
    #   SCX & 7      0   1   2   3   4   5   6   7
    #   reference   11   9   8   7   6   5   4   3
    #   was         11  11  11  11  11  11  11  11     (no SCX term at all)
    #   is          11   9   8   7   6   5   4   3
    #
    # The photograph backs the reference here (tools/gbphoto: 94.2% of the 652
    # disputed cells, one region, residual ratio 7.6x), and so does the ROM's
    # own header: "The stair pattern is visible due to the delay from the
    # lowest 3 bits of SCX, and due to window activating one T-cycle later when
    # WX = 0 and SCX > 0." Both terms are in that sentence; the second one was
    # already here with the WRONG SIGN (it read `+= 1`, i.e. one dot EARLIER),
    # which is invisible without the first because nothing else in the tree
    # moves SCX on a WX = 0 line.
    #
    # So the discard for a window line is `(7 - WX) + (SCX and 7)`, plus the
    # documented extra T-cycle when WX = 0 and SCX & 7 > 0. The WX = 0 case
    # discards SIX for its own fine scroll rather than seven -- Pan Docs calls
    # WX = 0 unreliable and this renderer already carried both 6 and 7 for it;
    # what the stair adds is which of them goes with SCX & 7 = 0.
    #
    # Cross-checks, all three of them independent of the row above:
    #  * gambatte window/m2int_wx03_scx5_m3stat_1 goes green on BOTH devices --
    #    a direct mode-3-length bracket at WX < 7 with SCX > 0, and the only
    #    gambatte family that holds one.
    #  * gambatte sprites/space/10spritesPrLine_wx0_m3stat_ds_2 goes green.
    #  * GBMicrotest win0_scx3_a/_b bracket it. `_a` reads STAT at cc = 261 and
    #    expects mode 3, `_b` at cc = 265 and expects mode 0, and hardware
    #    samples the mode bits at cc - 2 (see STAT_READ_LAG), so mode 0 starts
    #    in [260, 263] and mode 3 is 180..183 dots. This makes it 183 -- INSIDE
    #    the bracket, where the old 178 was outside it on the short side.
    #
    # What it costs: win0_scx3_b itself goes red, at `0x83` against `0x80`.
    # That is not this rule being wrong -- it is the readback lag catalogued as
    # bucket 15 in docs/gb-failure-triage.md (we sample no earlier than cc - 5
    # where hardware samples cc - 2) becoming visible on one more row, because
    # the mode-3 end moved to where that defect shows. Same shape, same
    # signature and the same twenty siblings as win6_b next door.
    ppu.lx = int32(-max(0, 7 - int(ppu.wx))) - int32(7 and int(ppu.scx))
    if ppu.wx == 0:
      ppu.lx += 1
      if (ppu.scx and 7) > 0: ppu.lx -= 1
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
  # The shifter has nothing to emit until the restarted fetch pushes again, so
  # this is a stop like an object fetch is (mixer_note_stop; the line's own
  # mode 3 entry parks the base over the top of this one).
  mixer_note_stop(ppu)
  ppu.fetcher_x = 0
  ppu.fetch_counter = 0
  # A restart is never the line's head cycle: either it IS the head (called at
  # the mode 2 -> 3 edge, before the discarded fetch has even started) or it is a
  # window start, whose own startup fetch is six dots and takes the early push
  # (mealybug m3_window_timing's "6 T-cycle window startup fetch").
  ppu.head_cycle = false
  ppu.fetching_window = fetching_window
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
  # Both halves of the object fetch's LCDC.2 read are per-line: no object fetch
  # is in flight across a mode 2 -> 3 edge, and a change of the bit on an
  # earlier line is already folded into `lcd_control`. See obj_height_at.
  ppu.obj_fix_from = OBJ_FIX_OFF
  ppu.lcdc2_flip[0] = NO_LCDC2_FLIP
  ppu.lcdc2_flip[1] = NO_LCDC2_FLIP

proc try_push_bg_pixels(ppu: GbFifoPpu; gb: GB): bool =
  ## Attempt to push 8 pixels to the BG FIFO. Returns true if successful.
  if ppu.fifo.size == 0:
    # LCDC.0 is read at the MIXER, one pixel at a time -- see BG_EN_AT_MIX in
    # gb.nim and the sample in fifo_mix. It is NOT read here: the push covers
    # eight pixels at once, so anything sampled on this dot can only blank a
    # whole tile, and mealybug m3_lcdc_bg_en_change's 12- and 8-pixel white runs
    # sit at x = -1 and 19. The control build keeps the old push-time sample.
    when BG_EN_AT_MIX == 0:
      # LCDC.0 is the one bit whose MEANING changes with the mode: "BG and
      # window enable" in DMG and DMG-compatibility mode, "BG and window master
      # priority" in CGB mode, where the layer is drawn either way (Pan Docs,
      # LCDC.0). gambatte's m2int_m3stat/nobg/*_cgb04c rows are a DMG cart on a
      # CGB with LCDC.0 clear, so they read the compatibility meaning.
      let bg_en = bg_display(ppu) or gb.cgb_native
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
    when defined(gb_px_trace):
      if gb_traced(ppu.ly):
        echo "PUSH ly=", ppu.ly, " dot=", ppu.cycle_counter, " lx=", ppu.lx,
             " fx=", ppu.fetcher_x, " num=", toHex(ppu.tile_num, 2),
             " lo=", toHex(lo, 2), " hi=", toHex(hi, 2),
             " attr=", toHex(attrs, 2)
    for col in 0 ..< 8:
      let shift = if flip: col else: 7 - col
      let color = uint8((((hi shr shift) and 0x1) shl 1) or ((lo shr shift) and 0x1))
      ppu.fifo.data[col] = GbPixel(
        color:     when BG_EN_AT_MIX == 0: (if bg_en: color else: 0'u8)
                   else: color,
        palette:   palette,
        oam_idx:   0,
        obj_to_bg: obj_to_bg,
      )
    return true
  return false

# ---- The head of a line that starts as a WINDOW line -----------------------
#
# WX below WIN_LINE_START_WX puts the window's first pixel left of the screen,
# where the shifter's equality can never reach it, so the whole line is fetched
# from the window map from its first tile (the note at the mode 2 -> 3 edge has
# that half). Two things about that start were wrong, and mealybug
# `m3_window_timing` measures both. It is a ruler, not a picture: WX = LY, WY =
# 0, SCX = 0, and BGP driven black at a fixed dot of every line, so the x at
# which black begins IS the count of dots the head consumed before x = 0. Its
# reference reads
#
#   WX (= LY)     0   1   2   3   4   5   6 ..  10   11  12 .. 16  17+
#   reference     3   3   3   3   3   3   3 ..   3    4   5 ..   9    9
#   was           9   3   4   5   6   7   8 ..   3    4   5 ..   9    9
#
# and the 17+ tail is the control: there the window starts right of everything
# the write can reach, so 9 is what a line with no window head at all reads.
#
# ---- 1. WHERE WX is read (WIN_LINE_START_LATCH) ---------------------------
#
# This ROM writes WX inside mode 3 -- dingbat's trace puts the write on dot 85
# of every line, and on dot 81 of LY 0, whose handler is one M-cycle shorter
# (`line_0_fix`). Reading WX at the mode 2 -> 3 edge therefore reads the
# PREVIOUS line's value, which for LY 0 is the 144 left from the bottom of the
# frame: dingbat drew no window on LY 0 at all and read 9 where the reference
# reads 3. So the read is AFTER dot 85.
#
# The other side is `m3_wx_6_change`, which writes WX = 6 in mode 2 and
# WX = LY at dot 93, with WY = 4: its reference draws NO window on LY 4 and
# LY 5, so the value the line-start decision sees on those lines is still 6 and
# the read is BEFORE dot 93. This latch -- the last dot of the throw-away fetch
# at the head of mode 3, dot 86, or 82 on LY 0 -- is the fetcher event inside
# that bracket, and it is the same event that already latches the fine scroll
# two dots later at the `B`. Nothing about the decision changes, only its dot;
# the throw-away fetch that just ended read the BACKGROUND map, and every byte
# of it is overwritten by the fetch this restarts.
#
# ---- 2. The window's OWN discard is absorbed (WIN_HEAD_ABSORB) -------------
#
# `fifo_sample_smooth_scroll` seeds `lx` at `-(7 - WX)` so the window's first
# tile lands on the right pixel, and this shifter charges a dot for every one
# of those discarded pixels. Hardware does not. The reference above is FLAT at
# 3 across WX = 0..6, and 3 is also what WX = 7..10 read -- lines whose window
# starts on screen and pays the ordinary six-dot startup fetch. So the head
# costs the same six dots whether the window starts at screen x = WX - 7 or off
# the left edge, which is the ROM's own header sentence: it accounts for the
# entire WX-dependence of the frame with "the 6 T-cycle window startup fetch"
# moving relative to a fixed write, and names no other per-WX term. (The
# hardware photograph backs the reference: 86.2% of the disputed cells and 100%
# of the cells above 2 sigma -- tools/gbphoto.)
#
# It cannot be spelled as a smaller discard. Seeding `lx` at a flat -6 gets
# m3_window_timing to 0 the same way and COLLAPSES three other rows that are
# pixel-exact today -- `m3_wx_4_change` 23040 -> 12809, `m3_wx_5_change`
# -> 14731, `m3_window_timing_wx_0` -> 22914 -- because the discard is what
# ALIGNS the window's glyphs and carries the SCX term. So the discard stays
# where it is and only the DOTS move: they come back as
# `6 - (7 - WX)` = `WX - 1` idle dots at the head of the window's own fetch --
# the negative steps of FETCHER_ORDER -- which leaves mode 3 at 172 + 6 for
# every WX in 0..6, exactly the length WX = 7 already had.
#
# WX = 0 needs no idle dot and gets none: its discard is already six (the
# `+= 1` in the sampler, from `m3_window_timing_wx_0`'s stair), and
# `max(0, WX - 1)` is that. The SCX term is deliberately NOT absorbed -- it is
# the throw-away fetch's own discard, not the window's, and
# `m3_window_timing_wx_0` is pixel-exact with it charged in full.
#
# ---- Two suites that never see a pixel say the same thing ------------------
#
# The consequence is a MODE 3 LENGTH, so it is measurable without any
# reference frame at all, and both length instruments agree:
#
#   * GBMicrotest `win<WX>_a` reads STAT at cc = 257 wanting mode 3 and
#     `win<WX>_b` at cc = 261 wanting mode 0. Hardware samples the mode bits at
#     `cc - 2`, so mode 0 starts in [256, 259] and mode 3 is 176..179 dots --
#     for every WX in 0..15, the whole family answering the same bracket.
#     Charging the discard on top put WX = 4 at 175 and WX = 5 at 174, OUTSIDE
#     it on the short side, and `-d:gb_stat_read_trace` shows both `_a` rows
#     passing on a mode flag that was already 0 when the ROM read it. At 178
#     every WX is inside the bracket and `live` is 3 where the ROM wants 3.
#   * gambatte's WX = 3 length brackets go green with it, six rows on both
#     devices: `window/m2int_wx03_m3stat_1`, `window/m2int_wx03_scx3_m3stat_1`,
#     `window/late_wx_wx03_2` and `sprites/space/10spritesPrLine_wx{3,4,5}
#     _m3stat_ds_1`. Nothing anywhere in that suite goes the other way.
proc fifo_head_window(ppu: GbFifoPpu) =
  ## The head of mode 3 reading WX: does this line start as a window line, and
  ## how many of the window startup fetch's six dots are left over once its
  ## fine-scroll discard has taken its share. Called once per line, from the
  ## dot the throw-away fetch ends on.
  when WIN_LINE_START_LATCH != 0:
    if not ppu.fetching_window and window_enabled(ppu) and ppu.window_trigger and
       ppu.wx < uint8(WIN_LINE_START_WX):
      # `fifo_reset_bg`'s window half, without the reset: the FIFO is empty,
      # `fetcher_x` is 0 and `obj_tile_fx` is -1 already, because nothing has
      # pushed yet and the caller has just rewound `fetch_counter` itself.
      ppu.fetching_window = true
      inc ppu.current_window_line
      fifo_arm_window(ppu)
  when WIN_HEAD_ABSORB != 0:
    if ppu.fetching_window:
      ppu.fetch_counter = -int(max(0, int32(ppu.wx) - 1))

# ---- M3_THROWAWAY_DOTS: how long the discarded head fetch lasts -----------
#
# The head of mode 3 is a discarded fetch followed by the first real one, and
# the two together are 12 dots: mode 3 is 172 at SCX & 7 = 0 and 160 of those
# are pixels. What the 12 dots do NOT say is how they split, and the split
# decides which dot the first on-screen tile's map read lands on. Writing the
# fetcher's first dot as `d` and its 8-step cycle as
# `s B s 0 s 1 s push` (FETCHER_ORDER, and kevtris' `B01s`), a discarded fetch
# of `n` dots puts the first real cycle's reads at `d+n+1`, `d+n+3`, `d+n+5`
# and its push at `d+n+7`; the push has to be at `d+11`, so `n = 4` and the
# cycle runs to its push slot, or `n = 6` and the push is taken early at the
# `1` read. Both spend 12 dots. mealybug separates them:
#
#   * `m3_scy_change` writes SCY every 8 dots from dot 81 of every line, so the
#     value each of a tile's three reads saw is recoverable from the reference
#     (map[row][col] = 65 + row + col, BGP identity, SCX 0, blank objects -- the
#     decode is in docs/gb-mealybug-sources.md §3.4). All eighteen bands demand
#     the first tile's `B` read take the value written at dot 81 and both its
#     bitplane reads take the one written at dot 89: with d = 83, `B` must land
#     in dots 82..89 and `0`/`1` after 89. n = 6 puts `B` at 90 -- one slot too
#     late, and the whole of this ROM's residual. n = 4 puts it at 88, `0` at 90
#     and `1` at 92.
#   * n = 2 is refused twice over: `B` at 86 is early enough but `0` lands at 88
#     and must not, and the remaining 10 dots cannot reach a push at d+11.
#
# n = 4 then makes `m3_scx_low_3_bits`' header true as written -- "the lowest 3
# bits appear to be read at the start of the 'B' of the first 'B01s' read
# cycle" -- because the discarded `B0` is not a `B01s` cycle and the first one
# is the first real tile's, whose `B` is dot 88. That is the dot this tree
# already latched SCX on (it called it "when the throw-away fetch completes"),
# so the ROM's two-sided bracket -- a write completing at dot 88 must reach the
# latch, one at dot 92 must not -- is unmoved. The latch simply moves to the
# step the ROM names.
#
# Everything from the second tile on is unmoved as well: its cycle starts on
# the dot after the first push either way.
proc tick_bg_fetcher*(ppu: GbFifoPpu; gb: GB) =
  case FETCHER_ORDER[ppu.fetch_counter]
  of fsGetTile:
    when M3_THROWAWAY_DOTS == 4:
      # "Read at the start of the 'B' of the first 'B01s' read cycle", and this
      # is that B: the discarded `B0` above ended one step ago. Before the map
      # offset below, which reads SCX itself.
      if ppu.head_cycle and not ppu.smooth_scroll_sampled:
        fifo_sample_smooth_scroll(ppu)
    when WIN_EN_ABORT != 0:
      # LCDC.5 cleared while the window is the active fetch source. mealybug's
      # PPU notes: "WIN_EN can be disabled during mode 3. The disabling will
      # take effect at the end of the current window tile being drawn. When the
      # current window tile has finished being drawn, the PPU will start drawing
      # background tiles again", and "when the background resumes drawing it is
      # on a tile boundary. The low 3 bits of SCX have no effect."
      #
      # This is the next tile-map read after the write, which IS the end of the
      # tile being drawn: the fetcher runs a tile ahead of the shifter, so the
      # tile whose map read this is, is the one displayed after the one the FIFO
      # is holding. Two things fall out of the second sentence. The BG column is
      # taken from the SCREEN position the fetch will land at rather than
      # continued from the window's own tile counter -- `lx + fifo.size` is the
      # first pixel this fetch will show -- and the fine scroll is NOT re-paid:
      # `dropped_first_fetch` stays set, so there is no throw-away fetch and no
      # SCX & 7 discard, which is that sentence exactly.
      if ppu.fetching_window and not window_enabled(ppu):
        ppu.fetching_window = false
        ppu.fetcher_x = int((ppu.lx + int32(ppu.fifo.size)) div 8)
        fifo_arm_window(ppu)
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
    when defined(gb_px_trace):
      if gb_traced(ppu.ly):
        echo "FTILE ly=", ppu.ly, " dot=", ppu.cycle_counter, " lx=", ppu.lx,
             " fx=", ppu.fetcher_x, " addr=", toHex(0x8000 + map + offset, 4),
             " num=", toHex(ppu.vram[0][map + offset], 2),
             " lcdc=", toHex(ppu.lcd_control, 2)
    ppu.tile_num   = ppu.vram[0][map + offset]
    # Unconditional, and it has to stay that way -- this is the mode 3 dot
    # loop, and one more branch here measured +0.8% of retired instructions on
    # Pokemon Crystal. What keeps the attribute plane at zero outside CGB mode
    # is that VBK is not in the register map there, so nothing can ever write
    # bank 1 (see FF4F in ppu_write_machinery).
    ppu.tile_attrs = ppu.vram[1][map + offset]
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
    when defined(gb_px_trace):
      if gb_traced(ppu.ly):
        let off = (if FETCHER_ORDER[ppu.fetch_counter] == fsGetTileDataLow: 0 else: 1)
        echo "FDATA ly=", ppu.ly, " dot=", ppu.cycle_counter, " lx=", ppu.lx,
             " fx=", ppu.fetcher_x,
             " plane=", off, " num=", toHex(ppu.tile_num, 2),
             " row=", tile_row,
             " addr=", toHex(0x8000 + tile_ptr + tile_row * 2 + off, 4),
             " byte=", toHex(ppu.vram[bank_num][tile_ptr + tile_row * 2 + off], 2),
             " lcdc=", toHex(ppu.lcd_control, 2)
    if FETCHER_ORDER[ppu.fetch_counter] == fsGetTileDataLow:
      ppu.tile_data_low = ppu.vram[bank_num][tile_ptr + tile_row * 2]
      inc ppu.fetch_counter
      when M3_THROWAWAY_DOTS == 4:
        # The discarded head fetch is `B0` and ends here -- four dots, and the
        # byte just read is thrown away with it. See M3_THROWAWAY_DOTS above for
        # why it is four and not six. The fine scroll is NOT latched here: it is
        # latched at the `B` of the cycle this restart begins, which is the step
        # m3_scx_low_3_bits names and the same dot this used to use.
        if not ppu.dropped_first_fetch:
          ppu.dropped_first_fetch = true
          ppu.head_cycle = true
          ppu.fetch_counter = 0
          fifo_head_window(ppu)
    else:
      ppu.tile_data_high = ppu.vram[bank_num][tile_ptr + tile_row * 2 + 1]
      inc ppu.fetch_counter
      when M3_THROWAWAY_DOTS == 4:
        # The push landed on the dot the tile data arrived, so step 4 has
        # already been served and the next fetch starts on the NEXT dot -- Pan
        # Docs' fetcher goes back to step 1 the moment a push succeeds.
        # Falling through the Sleep/Push steps instead -- which is what this did
        # until 2026-08-03 -- leaves every later fetch on the line reading VRAM
        # two dots late, which is the phase the OBJ penalty is measured against.
        # See the fetch-phase note at tick_sprite_fetcher.
        #
        # The line's first `B01s` cycle is the one fetch that may NOT take it:
        # its push is the dot that makes the head 12 dots, so it has to wait for
        # its own push step two dots later. See M3_THROWAWAY_DOTS.
        if not ppu.head_cycle and try_push_bg_pixels(ppu, gb):
          ppu.fetch_counter = 0
      else:
        if not ppu.dropped_first_fetch:
          ppu.dropped_first_fetch = true
          ppu.fetch_counter = 0
          fifo_head_window(ppu)
          # The fine scroll is the FETCHER's, not the shifter's: the throw-away
          # first fetch IS the mechanism that implements the SCX & 7 discard, so
          # SCX is latched when that fetch completes rather than several dots
          # later when the shifter first finds a pixel to look at. mealybug
          # m3_scx_low_3_bits brackets the latch with two SCX writes one M-cycle
          # apart -- one has to reach it and the other must not -- and only the
          # fetcher-side point sits between them.
          if not ppu.smooth_scroll_sampled: fifo_sample_smooth_scroll(ppu)
        elif try_push_bg_pixels(ppu, gb):
          # The 172-dot line only adds up if the line's first push is immediate
          # (6 dots of throw-away fetch + 6 of the real one + 160 pixels).
          ppu.fetch_counter = 0

  of fsPushPixel:
    # Step 7 is the last of the order, so this is the wrap -- and it is the
    # ONLY one. Every other `inc` above starts from a step whose successor is
    # still inside the order (the three reads sit at 1, 3 and 5, and fsSleep is
    # never step 7), so 8 was only ever reachable from here. It used to be an
    # `and 7` on the way out of this proc, which is a dot-loop instruction this
    # does not need -- and which would silently fold the window head's negative
    # steps (WIN_HEAD_ABSORB, above) back into the positive ones, `-3 and 7`
    # being 5.
    if try_push_bg_pixels(ppu, gb):
      when M3_THROWAWAY_DOTS == 4: ppu.head_cycle = false
      ppu.fetch_counter = 0

  of fsSleep:
    inc ppu.fetch_counter

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
# `lag` term at the trigger for how that is recovered.
#
# Pan Docs' X=0 exception -- "always incurs an 11-dot penalty, regardless of
# SCX" -- IS a special case and is spelled out as one below. It used to be
# claimed here that it fell out for free (an X=0 object triggers on the first
# dot the BG FIFO is non-empty, where the FIFO is a full 8), and that is only
# true at SCX & 7 = 0: the FIFO is full there, but The Pixel sits at index
# SCX & 7 of the tile before the first on-screen one, so the derived wait is
# 5 - (SCX & 7) and the derived penalty ramps 11, 10, 9, 8, 7, 6, 6, 6 over the
# eight residues. Hardware does not: see the table at the trigger.
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
# ---- The whole table, from hardware ---------------------------------------
# GBMicrotest's `ppu_spritex_vs_scx.gb` is 306 assertions -- one object at OAM
# X 0..16 crossed with SCX 0..8, two per cell bracketing the end of mode 3 to
# one M-cycle -- and it never writes $FF82, so the runner cannot score it. Its
# expectations are the table, though, and `tools/gbppu/objtab.py` reads them
# back out of this tree as dots by differencing against the same build's
# no-object line, which cancels whatever constant offset the mode 3 edge
# carries. Hardware, penalty in dots (X >= 1 is period 8 in X; X = 0 is not):
#
#   X \ SCX&7   0   1   2   3   4   5   6   7
#      0       11  11  11  11  11  11  11  11
#      1       10   9   8   7   6   6   6  11
#      2        9   8   7   6   6   6  11  10
#      ...      (each row the one above rotated right)
#
# i.e. `6 + max(0, 5 - ((X + SCX) mod 8))` for X >= 1 and a flat 11 for X = 0,
# which is Pan Docs' algorithm plus Pan Docs' X = 0 exception and nothing else.
# All 153 cells match this file as of 2026-08-03 (79 of them did not before).
#
# What this does NOT model is the object fetch being CANCELLED mid-flight by
# clearing LCDC.1, which Pan Docs describes and gambatte's
# sprites/sprite_late_disable_* rows measure.
const OBJ_FETCH_DOTS {.intdefine.} = 6'i32
const OBJ_WAIT_SUB {.intdefine.} = 3'i32

# ---- LCDC.2 is read ONCE PER BITPLANE, and where the fetch sits in the
# ---- penalty decides which dots those two reads land on --------------------
#
# `sprite_fetch_merge` runs on ONE dot and used to take the object's height from
# LCDC.2 as it stood on that dot, for both bitplanes at once. mealybug
# `m3_lcdc_obj_size_change` and `m3_lcdc_obj_size_change_scx` refuse that, and
# they are unusually direct instruments for it: BGP = $00 makes the whole
# background white, every object is tile $4C with OBP0 = $E4, and the objects
# are stacked at Y = $10, $20 .. $90 so each 16-line band is one object read out
# as eight columns of raw bitplane. Both ROMs pulse LCDC.2 four times across
# mode 3 (8x8, 8x16, 8x8, 8x16), the first at a fixed dot and `_scx` also
# driving SCX = (LY >> 4) & 7 so each band meets the pulse at a different fetch
# phase. Decoding the reference frames back into "which height did the low
# plane use, and which did the high" (tile $4C is even, so the two heights
# differ only in the `or 1` for the lower tile of an 8x16 object, and the
# reference names the pair exactly) gives, against this tree's own merge dot M:
#
#   ROM              band  object  M     reference  needs
#   _scx             0, 8  X = 32  135   (16, 8)    lo <= 136, hi >= 137
#   m3_..._change    0     X = 16  123   ( 8, 16)   lo in [101,125), hi >= 125
#   m3_..._change    1     X = 33  148   ( 8, 16)   lo in [137,149), hi >= 149
#   m3_..._change    1..3  X = 1..3 103/102/101  (16, 16)  BOTH reads < 101
#   m3_..._change    8     X = 8   104   ( 8,  8)   both in [101,125)
#
# With the two reads OBJ_PLANE_GAP = 2 dots apart the first three rows have a
# UNIQUE solution -- low plane on M, high plane on M + 2 -- and it is forced
# from both sides: band 0 of `m3_lcdc_obj_size_change` needs the high read at
# least 2 dots after M, band 1's X = 33 needs the low read no later than M.
#
# The fourth row cannot be that, and the fifth says why. X = 1..3 hang off the
# left edge of the screen and are the `idx < 0` arm of the penalty (see
# OBJ_BG_RUN above): the trigger dot is the BG fetch's own last read, so the
# object takes the bus from the very next dot and its six dots are the FIRST six
# of the penalty, not the last. All three of them trigger on dot 94 and all
# three want both reads before dot 101, which `t + OBJ_FETCH_DOTS` gives exactly
# -- at any X, because the wait is spent AFTER the fetch on that arm rather than
# before it, so the penalty's length changes and the read dots do not.
#
# X = 8 is the same measurement from the other side and it is what makes the
# boundary a measurement rather than a choice: it is the first object that does
# NOT hang off the left edge, and it wants the tail arm's dots (reads at 104 and
# 106, i.e. 8x8) where the head arm's (100, i.e. 8x16) would draw the other
# tile. So the split is exactly `idx < 0`, which is the split OBJ_BG_RUN = 4
# already derived from `m3_lcdc_tile_sel_change` -- two unrelated ROMs, the same
# line.
#
# ---- The CGB reads the bit three dots later, and says so on six bands ------
#
# The same two ROMs run as DMG carts on CGB hardware are the suite's own
# `_cgb_c` references, and they are the COMPLEMENT of the DMG ones here: `_scx`
# band 0 (merge 135) is mixed on DMG and pure 8x16 on CGB, and its bands 4..7
# (merge 138/139) are pure 8x8 on DMG and MIXED on CGB. Solving those six bands
# the same way gives one offset -- three dots earlier than the DMG's, on every
# one of them, with the write dots and the merge dots identical between the two
# devices under `-d:gb_m3_trace`. That is CGB_OBJ_SIZE_LATENCY, the same shape
# as CGB_MIXER_LATENCY for the mixer's registers: the bit reaches this reader
# later on CGB. The head arm is insensitive to it (both settings put the read
# before the ROM's first write), so it is applied to the dot rather than to
# either arm.
#
# ---- What is left over, and what these ROMs cannot say ---------------------
#
#  * On the tail arm the six dots come out as M-3 .. M+2, which is one dot later
#    than "the wait, then the fetch" places them (M-4 .. M+1). That one dot is
#    the same lead of the pipeline over the CPU's register view that
#    M3_PIPE_DELAY and OBJ_DMA_BUS_LEAD each carry a share of elsewhere in this
#    file; it is measured here and not derived, which is why OBJ_PLANE1_LAG is
#    a constant with a sweep rather than an expression.
#  * Nothing here separates "the tile index's low bit is masked at the OAM read"
#    from "at each bitplane read": every object in both ROMs is on tile $4C,
#    which is even, so `tile and $FE` is a no-op and only the `or 1` for the
#    lower tile is visible. The whole address is recomputed per plane below,
#    which is the simpler of the two and matches everything either ROM can see.
#  * A second object at the same X re-arms the stall for a bare OBJ_FETCH_DOTS
#    (see the chain at the end of sprite_fetch_merge). Its six dots ARE its
#    penalty, so it takes the tail arm's offset whichever arm the first object
#    took; no ROM in the tree puts an LCDC.2 write inside a chained fetch.
#
# ---- The sweeps, mealybug matching pixels, one build per cell --------------
#
# DMG is 552,188 of 552,960 at the shipping settings and CGB 1,856,315 of
# 1,866,240; both columns move ONLY the two obj_size rows at every cell below.
#
#   OBJ_PLANE1_LAG      0        1        2 (ship)   3        4
#   DMG            552068   552143   552188     552098   552068
#   CGB           1855880  1855955  1856315    1856285  1856110
#
#   OBJ_PLANE_GAP            1        2 (ship)   3
#   DMG                 552188   552188     552188
#   CGB                1856285  1856315    1856135
#
#   CGB_OBJ_SIZE_LATENCY     0        1        2        3 (ship)   4        5
#   CGB                1855975  1856110  1856285  1856315    1855955  1855880
#
#   OBJ_PLANE1_HEAD          4        5        6 (ship)   7        8
#   DMG                 552188   552188     552188     552110   552110
#
# Each of the first three is a strict optimum pinned from both sides. The fourth
# is not: the head arm's read only has to be before dot 101 and 4, 5 and 6 all
# are, so the ROMs bound it from above at 6 and say nothing below. 6 is the
# structural value -- the six-dot fetch starting on the dot after the trigger --
# and the two dots below it are the same fetch with the OAM read left out.
const OBJ_PLANE_GAP {.intdefine.} = 2'i32
  ## Dots between an object fetch's two bitplane reads. Two dots per VRAM
  ## access, which is the same spacing the six-dot fetch is built out of.
const OBJ_PLANE1_LAG {.intdefine.} = 2'i32
  ## Dots after the merge dot at which the HIGH bitplane's read samples LCDC.2,
  ## on the `idx >= 0` arm. The low plane's is OBJ_PLANE_GAP earlier, i.e. the
  ## merge dot itself.
const OBJ_PLANE1_HEAD {.intdefine.} = 6'i32
  ## The same read on the `idx < 0` arm, in dots after the object's TRIGGER: the
  ## fetch sits at the head of the penalty there, so it does not move with the
  ## wait.

# ---- The object's OAM read, and the one thing that can see it -------------
#
# This renderer's mode-2 scan snapshots all four of an object's OAM bytes
# (fifo_get_sprites) and mode 3 uses that snapshot. Hardware splits the two:
# the scan latches Y and X -- they are all it decides with -- and the object's
# TILE NUMBER and ATTRIBUTES are read out of OAM again during mode 3, at the
# object's own fetch. With OAM quiet the two readings agree and the split is
# invisible, which is why nothing in this tree had to model it.
#
# An OAM DMA is where it stops being invisible. While the unit owns OAM the
# PPU's read does not reach the array; what it gets is the byte the unit has on
# its bus, the same byte a colliding CPU read latches (mem_read_busy). So the
# object renders with a tile number the DMA is only passing through, which need
# not be anywhere near the object's own OAM slot. Pan Docs ("OAM DMA Transfer")
# says only that the PPU cannot read OAM properly during the transfer; which
# byte it does get is Hacktix's strikethrough.gb's own finding, and that ROM is
# the whole of the evidence below.
#
# ---- What the ROM does ----------------------------------------------------
# It fills OAM with forty objects at Y $54 (LY 68) and X $17, $1F, ... -- tile
# 0, a solid bar -- eight pixels apart, so every object is one bar's width from
# the next. On LY 67 a STAT LYC interrupt waits for mode 0, idles 28 NOPs and
# starts an OAM DMA whose 160-byte source is $01 (a blank tile) everywhere
# except ONE $00 at offset 46. The transfer then spans the whole of LY 68.
# Hardware draws exactly ONE eight-pixel bar: one object's fetch lands on the
# M-cycle carrying that $00 and every other object on the line reads a $01.
# Off the mode-2 snapshot this renderer drew all ten.
#
# ---- Which M-cycle, and how the ROM pins it -------------------------------
# The transfer is one byte per M-cycle, so the ROM resolves the fetch's OAM read
# to four dots and no finer -- but it does resolve it to four dots, because the
# bar it draws names the object. On LY 68 the DMA has already overwritten
# objects 0-5 by the time mode 2 ends, so the ten objects drawn are 6..15
# (screen x 63..135) and the bar is object 7's, at screen x 71. This renderer's
# six-dot fetch for that object is dots 171-176 of the line and it merges the
# tile row on 176; the M-cycle carrying source byte 46 is dots 177-180. So the
# read is one M-cycle AHEAD of the fetch's own dots -- OBJ_DMA_BUS_LEAD.
#
# That is a phase between the pipeline and the bus half of an M-cycle, and it is
# the same quantity M3_PIPE_MCYCLES names for the CPU: exactly one M-cycle,
# measured. M3_PIPE_MCYCLES ships at 0 only because the CPU's half of it is paid
# on the write side instead (mem_write commits a byte at the top of its
# M-cycle); the OAM DMA unit writes through its own path and was never given
# that compensation, so the term is still owed here and this is where it lands.
#
# ---- Two readings that are NOT it -----------------------------------------
#  * "The DMA starts earlier." Moving the unit's own start is the other way to
#    put the $00 under object 7's fetch, and it is refuted outright: one M-cycle
#    earlier (the `next_dma_counter == 8` threshold at 4) does take
#    strikethrough to 0 wrong pixels, and it costs sixteen mooneye acceptance
#    rows -- oam_dma_start, oam_dma_timing, oam_dma_restart and the whole
#    call/ret/push/rst timing family -- and gambatte/oamdma 681 -> 350.
#  * "The read is somewhere inside the fetch." Swept over all six dots of the
#    fetch (and out to eleven, into the wait): every one of them reads a $01 and
#    the ROM draws no bar at all. The window the ROM leaves is four dots wide
#    and it does not overlap the fetch.
#
# ---- Why scanline_ppu does not mirror this --------------------------------
# It cannot. That renderer draws a whole line in one step at the mode 2 -> 3
# boundary, so every object on the line would take the same DMA byte and the
# picture would be ten bars or none -- the answer this change exists to avoid.
# The distinction only exists for a renderer with a dot per object fetch. The
# FIFO renderer is the shipping and scored one either way (config `gb_fifo`
# defaults true; every harness in tests/ passes `fifo = true`).
const OBJ_DMA_BUS_LEAD {.intdefine.} = 1
  ## M-cycles the object fetch leads the OAM DMA unit's bus by. 0 is "the byte
  ## the unit is driving on the fetch's own M-cycle" (mem.dma_latch).

proc obj_oam_dma_read(ppu: GbFifoPpu; gb: GB) {.noinline.} =
  ## The object's mode-3 OAM read while an OAM DMA owns OAM. Cold: `dma_busy`
  ## is false for all but ~160 of the ~17,500 M-cycles of a frame, and only for
  ## the frames that run a transfer at all.
  let mem = gb.memory
  var b: uint8
  if mem.dma_openbus:
    b = 0xFF'u8
  else:
    # `dma_position` is the index of the byte the unit moves NEXT, so a lead of
    # one M-cycle is exactly that byte. The unit drives nothing past 0xA0, so
    # the last M-cycle of a transfer keeps what it has rather than reading off
    # the end of the source.
    var src = int(mem.current_dma_source) +
              min(mem.dma_position + OBJ_DMA_BUS_LEAD - 1, 0x9F)
    # Same echo fold as the unit itself (mooneye oam_dma/sources-GS).
    if src >= 0xE000: src = src and not 0x2000
    b = read_byte(mem, gb, src)
  ppu.sprites[0].tile_num   = b
  ppu.sprites[0].attributes = b

proc sprite_merge_planes(ppu: GbFifoPpu; gb: GB; s: GbSprite; lo, hi: uint8;
                         lx: int32) =
  ## Merge one object's eight pixels into the sprite FIFO, given the two
  ## bitplane BYTES rather than their addresses. Split out of the fetch so
  ## fifo_obj_size_write can redo it against a different high plane without
  ## re-deriving the priority rule.
  let palette = if gb.cgb_native: sprite_cgb_palette(s) else: sprite_dmg_palette(s)
  for col in 0 ..< 8:
    let shift = if sprite_x_flip(s): col else: 7 - col
    let lsb = (lo shr shift) and 0x1
    let msb = (hi shr shift) and 0x1
    let color = uint8((msb shl 1) or lsb)
    let px = GbPixel(color: color, palette: palette, oam_idx: s.oam_idx, obj_to_bg: sprite_priority(s))
    let fifo_col = col + int(s.x) - 8 - int(lx)
    if fifo_col >= 0:
      if fifo_col >= ppu.fifo_sprite.size:
        fifo_push(ppu.fifo_sprite, px)
      elif (px.color != 0 and fifo_get(ppu.fifo_sprite, fifo_col).color == 0) or
           (gb.cgb_native and px.oam_idx <= fifo_get(ppu.fifo_sprite, fifo_col).oam_idx and px.color != 0):
        fifo_set(ppu.fifo_sprite, fifo_col, px)

proc sprite_fetch_merge*(ppu: GbFifoPpu; gb: GB) =
  ## Read sprite tile data and merge into the sprite FIFO.
  # The object's own OAM read lands on this dot, with everything else the fetch
  # takes here (the OBP registers, the tile row). One predictable not-taken
  # branch per object fetch when no transfer is running.
  if gb.memory.dma_busy: obj_oam_dma_read(ppu, gb)
  let s = ppu.sprites[0]
  ppu.sprites.delete(0)
  # LCDC.2 is read once per bitplane, on two dots that are not this one -- see
  # OBJ_PLANE1_LAG above. The low plane's dot is always in the past, so
  # obj_height_at answers it outright; the high plane's can still be ahead, and
  # then obj_height_at gives the bit as it stands and the write path takes over.
  #
  # The two planes DISAGREE only if the bit moved between the low plane's dot
  # and now, which is one compare against the newest entry of the history --
  # and everything after that compare is address arithmetic this used to do
  # once. Doing it twice unconditionally costs +0.09% of retired instructions on
  # dmg-acid2 (23,474,243,550 -> 23,453,456,528, min of three; it has objects on
  # nearly every line), all of it on frames where the answer is the same twice.
  # NO_LCDC2_FLIP is int32.low, so a line with no LCDC.2 write at all takes the
  # fast arm without a second test.
  let hi_dot = ppu.obj_hi_dot
  var h_hi = sprite_height(ppu)
  var b_lo, b_hi: uint16
  if likely(ppu.lcdc2_flip[0] <= hi_dot - OBJ_PLANE_GAP):
    (b_lo, b_hi) = sprite_tile_bytes(s, ppu.ly, h_hi)
  else:
    h_hi = obj_height_at(ppu, hi_dot)
    b_lo = sprite_tile_bytes(s, ppu.ly, obj_height_at(ppu, hi_dot - OBJ_PLANE_GAP)).lo
    b_hi = sprite_tile_bytes(s, ppu.ly, h_hi).hi
  let bank = if gb.cgb_native: int(sprite_bank_num(s)) else: 0
  when defined(gb_px_trace):
    if gb_traced(ppu.ly):
      echo "SPR ly=", ppu.ly, " dot=", ppu.cycle_counter, " x=", s.x,
           " tile=", toHex(s.tile_num, 2),
           " lo=", toHex(ppu.vram[bank][b_lo], 2),
           " hi=", toHex(ppu.vram[bank][b_hi], 2)
  # Pad OAM FIFO to at least 8 pixels with transparent lowest-priority pixels
  while ppu.fifo_sprite.size < 8:
    fifo_push(ppu.fifo_sprite, GbPixel(color: 0, palette: 0, oam_idx: 0xFF, obj_to_bg: 0))
  # If the high plane's read has not happened yet, keep what a redo needs. No
  # snapshot of the FIFO goes with it: see fifo_obj_size_write for why the merge
  # is exactly undoable from the entries themselves.
  if hi_dot > ppu.cycle_counter:
    ppu.obj_fix_from = ppu.cycle_counter + 1
    ppu.obj_fix_bank = int32(bank)
    ppu.obj_fix_lo   = ppu.vram[bank][b_lo]
    ppu.obj_fix_h    = uint8(h_hi)
    ppu.obj_fix_s    = s
  else:
    ppu.obj_fix_from = OBJ_FIX_OFF
  sprite_merge_planes(ppu, gb, s, ppu.vram[bank][b_lo], ppu.vram[bank][b_hi], ppu.lx)
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
    # Its six dots ARE its penalty, so its high plane sits at the tail arm's
    # offset from its own merge dot whichever arm the first object took.
    ppu.obj_hi_dot = ppu.cycle_counter + OBJ_FETCH_DOTS + OBJ_PLANE1_LAG -
      (if gb.cgb_enabled: int32(CGB_OBJ_SIZE_LATENCY) else: 0'i32)

proc tick_sprite_fetcher*(ppu: GbFifoPpu; gb: GB): bool =
  ## One dot of an object fetch. Returns true if this dot was the object's --
  ## the shifter is stopped for the whole of it -- and false for the one tail
  ## dot the shifter has back but the BG fetcher does not (see OBJ_BG_RUN = 4).
  ## A return value and not a call to tick_shifter from in here: tick_shifter is
  ## the mode 3 dot loop's body and a SECOND call site stops clang inlining it
  ## into fifo_pipeline_dot, which measured +0.9% of retired instructions on
  ## Pokemon Blue for a dot that happens at most once per object.
  ##
  ## Only the number of dots it lasts varies -- see the trigger in tick_shifter
  ## for where that count comes from.
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
  # ---- This line was accused of the object families' residual. It is clear ---
  #
  # Until 2026-08-03 there was a KNOWN RESIDUAL note here saying these wait dots
  # should not be run at all: mealybug m3_scy_change's eighteen per-object bands
  # were pixel-exact wherever the wait term was 0 and ~960/1280 wherever it was
  # not, on DMG as well as CGB, and the only thing that moves the fetcher during
  # a penalty is this line. The reading was wrong, and the way it was settled is
  # worth keeping because a whole-frame percentage cannot do it.
  #
  # GBMicrotest's ppu_spritex_vs_scx.gb is the instrument. It is 153 cells of
  # "how many dots does one object at OAM X cost at this SCX", asserted against
  # hardware, and `tools/gbppu/objtab.py` reads them back out of this tree as
  # dots -- differenced against the same build's no-object line, so the constant
  # offset the mode 3 edge carries cancels and only the penalty is compared.
  # 79 of the 153 were wrong, and the shape was `+1 dot wherever
  # (X + SCX) mod 8 >= 4`: a STALL. The fetcher was coming out of the penalty
  # too late to have the next tile ready, and the shifter spent a dot waiting.
  #
  # That is the opposite sign to what the picture wanted -- the bands wanted the
  # fetcher frozen harder, the dots wanted it frozen less -- and the reason is
  # that both were reading a third thing: the fetch cycle's own phase. A push
  # taken at Get-Tile-Data-High used to fall through the Sleep/Push steps it had
  # already served, which put the two idle dots at the HEAD of the next cycle
  # where hardware has them at the tail, and left every VRAM read two dots late.
  # Those two dots were exactly cancelling a real two-dot lead of the pipeline
  # over the CPU's register view. Fix the push (see tick_bg_fetcher), charge the
  # lead where it belongs (M3_PIPE_DELAY = 2), and the object families come right
  # WITHOUT this line changing: objtab.py goes 79 -> 0 mismatched cells,
  # m3_scy_change 92.6% -> 98.3% DMG and 81.4% -> 97.2% CGB, and its four broken
  # bands (X = 3, 4, 11, 12) go from ~960/1280 to 1261-1279.
  #
  # Re-measured on the fixed phase, the four candidate rules for this line are
  # indistinguishable -- all four give objtab.py 0/153, and on the scored suites
  # (gambatte / mealybug DMG pixels / mealybug CGB pixels):
  #
  #   run for the wait dots (this)   3614  517987  1814452
  #   run for the whole penalty      3614  518293  1815437
  #   freeze completely              3615  517786  1813590
  #   step 4 only                    3615  517541  1813120
  #
  # A quarter of a percent apart on 23,040-pixel frames and one row apart on
  # 5,005. Nothing in the tree separates them any more, so the one written down
  # is the one Pan Docs writes down, and "run for the whole penalty" stays out
  # because it puts the BG fetch and the object fetch on the address bus at the
  # same time whatever it scores.
  #
  # ---- What DOES separate them, and why none of them is it ------------------
  #
  # Re-swept 2026-08-08 through `-d:OBJ_BG_RUN` (mealybug DMG pixels, whole set,
  # so the sweep is a command line rather than an edit to this line):
  #
  #   0  freeze completely          550072
  #   1  run for the wait (this)    550274
  #   2  run for the whole penalty  550590
  #   3  finish the fetch in flight 550513
  #
  # Still a quarter of a percent, and every one of them trades rows: 0 and 3 buy
  # m3_lcdc_tile_sel_change ~250 pixels and give back m3_lcdc_tile_sel_win_change
  # and m3_lcdc_win_map_change. What the mealybug sources say the answer has to
  # look like is sharper than any of the four, and is written up in
  # docs/gb-mealybug-sources.md: on hardware an object fetch NEVER lands between
  # a background tile's two bitplane reads. m3_lcdc_tile_sel_change is a direct
  # readout of that -- its LCDC pulse is 8 dots wide and its 18 bands each move
  # the fetch phase, so every band reports the pair (TILE_SEL at plane 0,
  # TILE_SEL at plane 1) as a shade, and the reference never once reports a pair
  # more than 2 dots apart. Here the two reads come out 8 dots apart on 13 of
  # the 18 bands, because the wait dots let a NEW fetch start and then freeze it
  # mid-tile. Rule 3 is the literal reading of "waiting for the BG fetch to
  # finish" and does not fix it either, because on the bands that fail the
  # fetcher had just pushed and there is no fetch in flight to finish. So the
  # split is real and none of these four is where it comes from; the remaining
  # candidate is the phase of the penalty itself against the fetch cycle.
  #
  # ---- Rule 4: the object fetch goes at a TILE boundary, and which one is
  # ---- decided by the object, not by the fetcher's phase -------------------
  #
  # `m3_lcdc_tile_sel_change` answers this outright. Its LCDC pulse is 8 dots
  # wide, its tile data is all-$00 at $9000 and all-$FF at $8000, so every tile
  # of the frame reports the pair (TILE_SEL at the plane-0 read, TILE_SEL at the
  # plane-1 read) as one of four shades; its eighteen objects sit at OAM X = k
  # in band k, so each 8-line band is an independent measurement of where the
  # penalty falls against the fetch cycle. Reading the DMG reference off as a
  # shade per band, and writing the pulse as the dot window W = [105, 112] and
  # the object-free fetch schedule as tile n's B/0/1 reads on dots 8n+88, 8n+90,
  # 8n+92 (n >= 1; tile 0's are 90/92/94), the whole frame is:
  #
  #   X = 0..7    the pulse falls on the fetch of the tile displayed at x=8..15
  #   X = 8..15   ...on the fetch of the tile at x=16..23, undisturbed
  #   X = 16, 17  ...on the fetch of the tile at x=16..23, undisturbed
  #
  # i.e. the penalty is inserted after the fetch of tile `floor(X / 8)`, and
  # The Pixel of an object at OAM X sits in tile `floor(X / 8) - 1`. So the
  # boundary the object takes is the one at the END of the fetch that was in
  # flight while The Pixel's own tile was being displayed -- the fetcher runs a
  # tile ahead, and Pan Docs' "waiting for the BG fetch to finish" is that fetch.
  # A background tile's three reads are never split by it, which is the finding
  # `docs/gb-mealybug-sources.md` states and none of rules 0..3 can produce.
  #
  # Two objects can be in identical FETCHER states at the trigger and still take
  # different boundaries, which is why no rule phrased on `fetch_counter` can
  # work: X = 0 and X = 8 both trigger on the dot the first push fills the FIFO,
  # both cost 11 dots, and both leave the fetcher at counter 0 -- yet the
  # reference gives band 0 shade 3 (both planes read inside W) and band 8 shade 0
  # (neither). The one thing that differs is the tile The Pixel is in, and that
  # is exactly `idx` at the trigger:
  #
  #   idx >= 0  The Pixel is in the tile the FIFO is displaying, so the fetch of
  #             the tile after it is the one in flight. It runs, inside the
  #             penalty, to completion -- and then parks, because the shifter is
  #             stopped and the FIFO cannot drain, so it cannot start another.
  #   idx < 0   The Pixel is in the tile BEFORE it (an object hanging off the
  #             left edge, OAM X < 8). The fetch the object waits for is the one
  #             that has just this dot finished -- the trigger dot IS its
  #             plane-1 read, which is what filled the FIFO and let the shifter
  #             ask the question. So the object takes the bus from the NEXT dot
  #             for the whole penalty and the fetcher gets none of it, including
  #             one dot past the end of the shifter's stall: the stall runs
  #             t .. t+P-1 and the object's accesses t+1 .. t+P, offset by the
  #             one dot the BG fetch had already taken. That last dot is the
  #             `obj_penalty <= 0` tail below, and it is not free padding --
  #             band 4 (OAM X = 4, P = 7) is shade 3 with it and shade 2
  #             without, and it is the only band that separates the two.
  #
  # Mode 3's length does not move either way, and that is checked rather than
  # hoped: neither arm can make the fetcher LATE for a push. In the hold arm the
  # shifter resumes on t+P with a full FIFO and empties it on t+P+8, while the
  # fetch resumes on t+P+1 and has its plane-1 read on t+P+6, two dots clear; in
  # the run arm the fetch finishes earlier than rule 1 left it, and an earlier
  # fetch can only remove a stall, never add one. GBMicrotest
  # ppu_spritex_vs_scx stays 0/153 through tools/gbppu/objtab.py, and 1660
  # ROM/device runs over gambatte sprites, oam_access, vram_m3, scx_during_m3,
  # GBMicrotest and mealybug are line-for-line identical under -d:gb_m3_len.
  #
  # What it does cost is the run arm's dots: the fetch happens inside the
  # object's stall instead of after it, so tick_bg_fetcher is called on up to
  # six dots per object that rule 1 skipped (the same stages, moved, plus the
  # call overhead). Pokemon Blue, retired instructions, +0.76%; Shantae +0.41%;
  # Pokemon Crystal +0.01%. All of it is the rule and none of it is the
  # plumbing -- this file's shape with rule 1 forced back on measures -0.06%
  # against the revision before it.
  #
  # `idx < 0` needs no state of its own. `obj_tile_fx` is the tile the wait was
  # charged against -- `fetcher_x - 1` when idx is negative and `fetcher_x` when
  # it is not -- and neither it nor `fetcher_x` can move for the duration of the
  # stall, because fetcher_x only advances on a push and a push needs an empty
  # FIFO, which a stopped shifter cannot produce. So the two fields the penalty
  # algorithm already keeps ARE the question, and this costs one compare on a
  # path no object-free line ever visits.
  when OBJ_BG_RUN == 4:
    let bg_hold = ppu.obj_tile_fx != int32(ppu.fetcher_x)
    if ppu.obj_penalty <= 0:
      # The tail dot. The shifter has its dot back; the fetcher does not.
      ppu.fetching_sprite = false
      return false
    # `fetch_counter == 7` is the park, and a park is where the run arm always
    # ends up: the fetch it was allowed to finish cannot push, because a stopped
    # shifter never empties the FIFO. Skipping the call there is not a rule, it
    # is the same nothing done without a call -- and it is most of the arm's
    # dots, so it is worth the compare: Pokemon Blue against the previous rule,
    # retired instructions, +1.06% without it and +0.76% with.
    if not bg_hold and ppu.fetch_counter != 7: tick_bg_fetcher(ppu, gb)
  elif OBJ_BG_RUN == 1:
    if ppu.obj_penalty > OBJ_FETCH_DOTS: tick_bg_fetcher(ppu, gb)
  elif OBJ_BG_RUN == 2:
    tick_bg_fetcher(ppu, gb)
  elif OBJ_BG_RUN == 3:
    if ppu.obj_penalty > OBJ_FETCH_DOTS and ppu.fetch_counter != 0:
      tick_bg_fetcher(ppu, gb)
  dec ppu.obj_penalty
  if ppu.obj_penalty <= 0:
    # The tile row lands on the last dot of the fetch. LCDC.2 and the OBP
    # registers are read here, so this is the dot the gambatte late_sizechange
    # family brackets.
    sprite_fetch_merge(ppu, gb)
    when OBJ_BG_RUN == 4:
      # A second object at the same X re-armed the stall; the tail belongs to
      # the end of the whole chain, not to each link of it.
      if bg_hold and not ppu.fetching_sprite:
        ppu.fetching_sprite = true
        ppu.obj_penalty = 0
  true

proc sprite_wins*(ppu: GbFifoPpu; gb: GB; bg_color, bg_obj_to_bg: uint8;
                  sp_px: GbPixel): bool =
  ## The BG colour comes in as a value rather than as the FIFO entry: the mixer
  ## masks it with LCDC.0 before asking (see fifo_mix), and passing the whole
  ## entry would mean copying it to do that.
  if sprite_enabled(ppu) and sp_px.color > 0:
    if gb.cgb_native:
      not bg_display(ppu) or bg_color == 0 or
        (bg_obj_to_bg == 0 and sp_px.obj_to_bg == 0)
    else:
      sp_px.obj_to_bg == 0 or bg_color == 0
  else: false

# Which of the eight fetcher positions the window's re-trigger edge survives
# on. See window_reactivate; overridable so the sweep that picked it can be
# re-run against the three m3_wx_*_change ROMs.
const WIN_REACT_PHASE {.intdefine.} = 7

proc win_react_last_park(ppu: GbFifoPpu): bool {.inline.} =
  ## Is this the LAST dot the fetcher spends at the shipping WIN_REACT_PHASE?
  ##
  ## Only `fsPushPixel` can be reached on more than one dot of a fetch cycle --
  ## every other step increments the counter unconditionally -- so this is a
  ## question about position 7 alone, and it folds to a constant `true` at any
  ## other setting of the sweep. There, the park ends on the dot the FIFO is
  ## down to its last pixel: the shifter emits that pixel here and
  ## `try_push_bg_pixels` finds the FIFO empty on the next dot. See the
  ## anchoring argument in window_reactivate for why the END of the park is the
  ## dot that stands in for the hardware fetcher's nametable read.
  when WIN_REACT_PHASE == 7: ppu.fifo.size == 1
  else: true

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
# lead in dots. **It ships at 2 as of 2026-08-03**, where it used to ship at 0
# on the reasoning that the M-cycle term above was the whole measured offset.
# It was not: the other two dots were being absorbed by the BG fetcher's step 4
# sitting at the head of its cycle instead of the tail (see the early push in
# tick_bg_fetcher), which put every VRAM read two dots late and hid a pipeline
# that was two dots early. Fix the fetcher and the two dots have nowhere to go.
#
# What pins it to 2 rather than to whatever scores best: it is exactly the two
# dots the fetcher's padding moved, and the row that reads it back is one with
# no objects on it at all -- mealybug m3_bgp_change is BGP written across mode 3
# and applied at the SHIFTER, so it sees the pipeline's phase against the CPU
# and nothing else: 87.3% -> 93.5% DMG, 90.6% -> 96.1% CGB, on the lead alone.
# m3_window_timing (96.9% -> 98.7%) agrees. Swept 0..4 on the fixed fetcher:
#
#   lead     0      1      2      3      4
#   gambatte 3576   3591   3587   3560   3550
#   mb DMG   504845 512369 516637 517664 515428
#   mb CGB   1803036 1800695 1801757 1802795 1789657
#
# 1 and 3 each buy something (gambatte at 1, mealybug DMG at 3) and neither is
# the derived number; 2 is, and it is the one that makes GBMicrotest's
# ppu_spritex_vs_scx table come out 153/153.
#
# The tail accounting below is still approximate, and it is what the change
# costs -- but **the cost is smaller than this note used to claim, and the
# "bus-layer change" it pointed at has already landed.** Re-measured 2026-08-03,
# one build per cell, whole gambatte suite:
#
#   M3_PIPE_DELAY   2 (ship)   0
#   total             3618     3596
#   window             322      303
#   scy                  9        3
#   sprites            393      397
#   bgtilemap            2        4
#   bgtiledata           2        1
#   m0enable           153      151
#
# So 2 is worth **+22 net**: it buys window +19, scy +6, bgtiledata +1 and
# m0enable +2, and it costs bgtilemap 4 -> 2 and sprites 397 -> 393. The
# "scx_during_m3 34 -> 31" half of the old claim does NOT reproduce -- that
# family scores 31/141 at BOTH settings and does not move by a single row, so
# it was never this constant's to pay. The write-side half of the fix (mem_write
# committing a write's byte at the START of its M-cycle) is already in the tree,
# which is why there is no bus-layer move left to make here; what remains is the
# six bgtilemap/sprites rows whose mid-line write lands in the two pixels the
# tail burst decides early.
#
# ---- What turning the lead machinery on costs -----------------------------
# A nonzero lead compiles in a per-line head delay and turns fetcher_retired
# from one compare into five, on the mode 3 dot loop -- ~25,000 dots a frame,
# inside a proc that mem_read and mem_write are in turn inlined into. Done
# naively it measured **+5.51%** of retired instructions on Pokemon Crystal
# (tools/gbppu/counters.sh, 2400 frames), most of it not the branches at all but
# 52 generated opcode bodies crossing clang's inline threshold in one direction
# or the other -- the cliff docs/gb_oam_dma_cost.md describes.
#
# It shipped at +0.83% / +0.72% (Link's Awakening DMG / Pokemon Crystal, against
# the same tree built with `-d:M3_PIPE_DELAY=0`, which compiles the whole
# mechanism out). Four changes on 2026-08-03 take it to **+0.22% / +0.12%**, and
# each is marked at its site:
#   * fetcher_retired's early-out folds the lead to an immediate whenever the
#     M-cycle term is off, instead of loading `m3_lead`. Splitting its other
#     four terms out of line was measured too, and is worse -- see there;
#   * the head delay is spent in ONE step above the dot loop rather than tested
#     inside it, behind a byte test and with no `continue` behind it (the four
#     spellings that were measured are tabulated at the site);
#   * the tail burst is {.inline.} -- it was {.noinline.} for the cliff above,
#     and with the mode 3 branch settled it no longer needs to be. Worth
#     -0.11%, see fifo_burst_tail;
#   * `m3_delay` is a uint8, so that once-per-mode-3-M-cycle test is
#     `ldrb`+`cbz` rather than `ldr`+`cmp`+`b.le`. Worth -0.08%.
# fifo_tick and mem_tick_components stay byte-identical in size across the pair,
# and the whole-binary per-function size diff against 151b952 has three rows:
# fifo_burst_tail (gone, inlined), fifo_tick_slow (-36) and sprite_fetch_merge
# (-24, the field-offset shift). Nothing in the opcode bodies moved, which is
# the check that matters -- if more than the functions you edited change size,
# you measured an inlining decision (docs/gb_oam_dma_cost.md).
#
# What is left is a floor rather than slack, and the arithmetic says so: the
# +0.22% that remains on DMG is ~0.19% of byte test (one `ldrb` and one `cbz`
# per mode 3 M-cycle, ~6,200 a frame) and essentially nothing else. An
# object-free line otherwise pays one compare per dot -- fetcher_retired's
# early-out, against an immediate, which clang folds into the dot loop's own
# `lx` test so it is not even a second branch -- and a two-dot burst per line;
# lines with objects pay nothing on top. The reason the byte test cannot be
# deleted is at its site.
#
# Two notes for whoever measures this next, both of which cost this change a
# wrong answer before they were understood:
#
#  * `ri_instructions` from proc_pid_rusage includes kernel work charged to the
#    process, so a run on a loaded machine reads HIGH -- 0.5% high at load
#    average 100, correlated with the run's own fps, which is bigger than every
#    number in this block. docs/gb_oam_dma_cost.md's "reproduces to 0.002%"
#    holds on an idle machine and not otherwise. Take the MINIMUM of four or
#    more runs per arm and check the minima agree to ~0.01%.
#  * Two builds of the SAME source in different directories differ by up to
#    0.25% of retired instructions (nimcache path length reaches the generated
#    C, and `_uNNNN` renumbering with it). Both arms of an A/B have to be built
#    the same way -- two gbgate slots, or two `bslot`-style trees -- and a
#    number carried over from a differently-built arm is not comparable.
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
const M3_PIPE_DELAY {.intdefine.} = 2

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

# CPU M-cycles by which the pixel pipeline runs AHEAD on line 0, and only on
# line 0, of where it runs on lines 1..143 -- with every mode flag, every STAT
# source and the mode 3 length left exactly where they are. It is the one term
# here that is per-line rather than per-frame, and the only one whose head is
# paid back at both ends: the head delay is `LY0_PIPE_MCYCLES` M-cycles shorter
# and the mode 3 -> 0 flag is held for the same number of dots, so the pixels
# move and nothing else does.
#
# ---- What measures it -------------------------------------------------------
# Two suites, neither of which was written with the other in mind, and they
# agree to the dot:
#
#   * mealybug `inc/utils.asm`'s `line_0_fix` macro burns 24 T-cycles on LY 0
#     against 28 on every other line -- "line 0 timing is different by 4
#     cycles", its own comment. Every `m3_*` ROM writes its register out of a
#     mode 2 STAT handler, so what the macro cancels is that the line-0 handler
#     reaches its write 4 T-cycles FURTHER INTO the drawn line than it does on
#     lines 1..143.
#   * gambatte's `scy`, `bgtilemap`, `bgtiledata`, `scx_during_m3` and `bgen`
#     reference-PNG families say it without a macro: the ROM takes a mode 2
#     STAT interrupt on every line and writes SCY/SCX/LCDC a counted number of
#     M-cycles into the handler (`scy/scy_during_m3_2.asm` is the shortest one
#     to read). 125 of those rows were pixel-exact on lines 1..143 and wrong
#     ONLY on LY 0, and a family's steps are one M-cycle each, so the step the
#     expected value flips on IS the measurement: `scy_during_m3_1..6`'s
#     reference moves its boundary at steps 2, 4, 6 where this tree moved it at
#     3, 5, 7.
#
# ---- Why it is here and not in the STAT source or the mode edges ------------
# "The line-0 mode 2 interrupt is one M-cycle late" is the obvious reading of
# both and it is FALSE. Built and scored 2026-08-09, it buys the same five
# families (gambatte 3658 -> 3762) and is refused from three directions:
#
#   * mooneye `acceptance/ppu/intr_1_2_timing-GS` (and wilbertpol's copy) times
#     the line-144 mode 1 STAT interrupt to the line-0 mode 2 one directly, by
#     counting `inc b` between them, and wants 20 then 21. Moving the pulse
#     makes it 21/22. It is verified on DMG/MGB/SGB/SGB2 hardware.
#   * gambatte `m2enable/late_enable_ly0_{1,2}` and eight siblings enable the
#     mode 2 source one M-cycle apart across the top of line 0 and want an
#     interrupt at the first offset and NONE at the second, which brackets the
#     pulse's own window where it already is.
#   * `lcdirq_precedence/m2irq_ly00_lcdstat30` and `lyc153int_m2irq_ifw_2`
#     bracket the same edge from the vblank side.
#
# The mode EDGES are pinned just as hard, and from the other side. Making line
# 0's mode 2 four dots short instead (mode 3 flag and pipeline both starting at
# dot 76, gambatte 3658 -> 3714) moves the mode 3 -> 0 flag with them and costs
# `m0enable` -18, `vramw_m3end` -8, `lcd_offset` -7, `enable_display` -7 and
# `m0int_m3stat` -2; and `ly0/lycint152_m2stat_1` refuses the mode 2 -> 3 edge
# moving on its own. So every flag on line 0 is where it is, the STAT sources
# are where they are, and what is one M-cycle out is only the phase at which
# the pipeline samples the registers -- which is exactly what M3_PIPE_MCYCLES
# above is the whole-frame version of, and why this is spelled in the same
# units it is. That is also what the `_ds` rows say: in double speed the same
# five families want 2 dots, not 4, so the quantity is a CPU M-cycle and not a
# count of PPU dots (a fixed 4 costs 14 `_ds` rows that one M-cycle keeps).
const LY0_PIPE_MCYCLES {.intdefine.} = 1

# Compiles the pipeline-lead machinery out entirely when all the terms are
# off, which is what the `-d:M3_PIPE_MCYCLES=0 -d:M3_PIPE_DELAY=0
# -d:M3_END_EARLY=0 -d:LY0_PIPE_MCYCLES=0` control build for an A/B wants;
# every guard below is a compile-time short circuit at that setting, not a
# runtime test.
const M3_PIPE_LEAD_ANY = M3_PIPE_MCYCLES != 0 or M3_PIPE_DELAY != 0 or
                         M3_END_EARLY != 0 or LY0_PIPE_MCYCLES != 0

# The held-pair ring has to name every pixel a register write can still reach:
# the deepest mixer stage, plus the pixels the tail burst decided ahead of
# their own dot. Both are compile-time here, so this is a compile-time check --
# a sweep of any of the four constants that overflows the ring would otherwise
# read a pixel four columns older than the one it means. See MIX_HOLD in gb.nim
# and fifo_recompose_span.
static:
  doAssert M3_PIPE_MCYCLES * 4 + M3_PIPE_DELAY + M3_END_EARLY +
           max(MIXER_PALETTE_BACK, MIXER_PRIORITY_BACK) <= MIX_HOLD,
           "MIX_HOLD is too shallow for this lead + mixer tail"

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
  ## THE POSITION IS A DOT, NOT A STATE, and the two are only the same thing on
  ## a line with no objects on it. `fsPushPixel` is where this fetcher PARKS:
  ## `try_push_bg_pixels` refuses while the BG FIFO still holds pixels, so the
  ## counter sits at 7 for as many dots as the FIFO takes to drain. An
  ## object-free line drains it in one -- the fetcher and the shifter are in
  ## lockstep, eight pixels per eight dots -- but an object stops the shifter
  ## without stopping the fetcher's wait dots, and the park stretches to three.
  ## The read the ROM names does NOT stretch: it is one VRAM cycle wherever the
  ## fetch cycle is long. So the proxy has to be anchored to the fetch RESTART,
  ## which is the last dot of the park (the push lands on the next dot and the
  ## nametable read a fixed two after that), and not to its first -- anchored at
  ## the first, the distance from the proxy to the real read grows with the
  ## park and the artifact smears across as many lines as the park is long.
  ##
  ## m3_wx_4_change_sprites measures exactly that, and the reference is
  ## unambiguous: its zero pixels sit at x = 5, 13, 21, 29, 37, 45 ... -- one
  ## lattice, x mod 8 = 5, running straight through the two 8-line bands that
  ## carry ten objects each. Objects do not move the surviving phase by a dot.
  ## dingbat drew the artifact on three consecutive lines inside the object
  ## band (34, 35, 36 -- the three dots of the park) where hardware draws it on
  ## one (36, the last of them), which is the whole of that row's 2-pixel diff.
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

proc obj_yields_to_window(ppu: GbFifoPpu): bool {.inline.} =
  ## Does the object the shifter has just found have to wait for the window's
  ## start, instead of the other way round?
  ##
  ## ---- The two triggers are ordered by COORDINATE, not by the dot ----------
  ##
  ## The window starts at the pixel `WX - 7` and an object's own trigger pixel
  ## is `X - 8` -- the screen x of its leftmost column. Every event in the
  ## shifter happens in coordinate order, so an object whose column is to the
  ## LEFT of the window's first column is fetched before the window starts and
  ## one to the right after it. What is special about this renderer is that the
  ## object test above is a `>=`, not an equality: an object at OAM X 1..7 has
  ## a trigger pixel of -7..-1, which `lx` never takes, and it is noticed on
  ## the first dot the shifter runs instead -- the same dot a WX = 7 window is
  ## noticed on. That collision is a modelling artifact of the clamp, and the
  ## tie it creates is decided the wrong way by the object-first order.
  ##
  ## `lag` (below, in the branch this guards) is exactly that displacement:
  ## `lx + 8 - X` is 0 for an object whose column IS this pixel and 1..8 for
  ## one whose column already went past. So the ordering rule is
  ##
  ##   lag > 0   the object's column is left of the window's  -> object first
  ##   lag == 0  same column                                  -> window first
  ##
  ## and only the second line changes anything: at `lag > 0` the object is
  ## already pending when the window's pixel arrives, which is what the current
  ## order does. Resolving the tie the other way round for BOTH cases is not
  ## this rule and is refused by hardware -- it takes m3_lcdc_win_map_change
  ## from 34 wrong pixels to 318, because it moves the seven left-hanging
  ## objects too (see docs/gb-failure-triage.md).
  ##
  ## ---- What pins the `lag == 0` line ---------------------------------------
  ##
  ## mealybug m3_lcdc_win_map_change and m3_lcdc_tile_sel_win_change both run
  ## WY = 0 / WX = 7 with one object per 8-line band at OAM X = band, so band 8
  ## is the one line group where an object's column is the window's column.
  ## Both ROMs toggle one LCDC bit for 8 dots at a fixed dot of every line
  ## (105..112 here), so each band's reference reads out WHICH fetch phase the
  ## PPU was in across those dots -- and band 8's says the window went first:
  ##
  ##   * win_map_change (WIN_MAP, read at the tile-map fetch). Band 8's
  ##     reference has NO black tile anywhere on the line, and bands 9..15 --
  ##     where the object is unambiguously after the window -- have none
  ##     either, because the object fetch stalls the fetcher across the whole
  ##     write. Object-first put our first window map read at dot 107, inside
  ##     the write, and painted x = 0..7 black over the object.
  ##   * tile_sel_win_change (TILE_SEL, read at the two bitplane fetches) is
  ##     the sharper one, because it resolves the write to a single dot. Band
  ##     8's reference is a WHITE window tile at x = 0..7 and colour 2 at
  ##     x = 8..15 -- one tile whose low bitplane came from $9000 and whose
  ##     high bitplane came from $8000. Window-first puts window tile 1's two
  ##     bitplane reads on dots 104 and 106 with the write at 105, which is
  ##     that mix exactly; object-first has no fetch there at all.
  ##
  ## Both rows go to 0 wrong pixels on this rule and no other mealybug row
  ## moves: `X == WX + 1` on the line the window starts is the whole of it.
  ##
  ## ---- The two neighbouring spellings, both measured out --------------------
  ##
  ## The tile_sel row pins this to ONE dot, and the two variants either side of
  ## it are refused by it, which is what says the deferral is a real edge and
  ## not a knob:
  ##
  ##   * "the object still pays no wait, because it was pending before the
  ##     window restarted" (pre-charge `obj_tile_fx` over the restart, penalty
  ##     6 dots instead of 11). Mealybug does not move -- it does not measure
  ##     the penalty here -- but gambatte loses the three OTHER window/object
  ##     ties it fixes (window/late_disable_spx10_wx0f_2 on both devices,
  ##     sprites/space/1pos8_8pos9_wx08_m3stat_ds_1 and
  ##     10spritesPrLine_wx7_m3stat_ds_1). The object DOES re-pay the wait.
  ##   * "the object starts its stall on the tie dot, concurrently with the
  ##     window's restart" (reset the fetch here and fall straight into the
  ##     trigger, so the wait term covers the restart). Refused by the pixels:
  ##     win_map_change 34 -> 64 and tile_sel_win_change 98 -> 64. The BG
  ##     fetcher only runs for the WAIT dots (see tick_sprite_fetcher), so
  ##     starting the stall on the tie dot freezes the window's FIRST fetch
  ##     half-done and pushes its second tile's map read into the write window,
  ##     painting x = 8..15. The window's first tile has to be pushed before
  ##     the object's stall begins, which is this rule.
  ##
  ## Physically the pipeline says the same thing. An object is merged onto the
  ## BG FIFO entry it will be drawn over; a window start empties that FIFO and
  ## refetches it. At the same pixel the fetch is upstream of the merge, so the
  ## window's refetch has to happen before the object has anything to merge
  ## onto. A left-hanging object was merged a pixel or more earlier, onto the
  ## background entries the window start then discards -- and it survives that,
  ## because the window start does not clear the OBJ FIFO, which is why the
  ## glyph is still drawn over the window in bands 1..7 of both references.
  ##
  ## ---- What it costs, named ------------------------------------------------
  ##
  ## Ordering the two fetches this way makes mode 3 longer whenever the object
  ## would have been charged against the tile the window discards: it is now
  ## charged at column 0 of the window's first tile, which is Pan Docs' 11-dot
  ## case. On the mealybug lines that is a no-op (the object was already at
  ## column 0), and gambatte's three mid-line ties above go GREEN on it. At
  ## `WX = 166` -- the window's first pixel is the LAST pixel of the line -- it
  ## is +10 dots, and that is where the rule is bought: eight gambatte rows go
  ## red (gambatte/m0enable 153 -> 147, and window/m2int_wxA6_spxA7_m0irq_2 on
  ## both devices) against five green, net 3781 -> 3776.
  ##
  ## That corner is a device split this tree does not carry, not this rule
  ## misfiring: hardware wants 180 dots on DMG and 190 on CGB for the same
  ## frame, and 190 is what this produces -- window/m2int_wxA6_spxA7_m3stat's
  ## CGB rows go green as its DMG rows go red. The split is already there
  ## WITHOUT an object: window/m2int_wxA6_m3stat and _scx2_/_scx5_ have DMG and
  ## CGB expectations one and two M-cycles apart and this tree gives the DMG
  ## number to both. Until the window-start cost at the last pixel is modelled
  ## per device, every wxA6 row is decided by which side that one number sits
  ## on, and there is no setting of THIS rule that moves it.
  ##
  ## Restricted to the window's START. `win_lx` also carries the re-trigger
  ## point while the window is already the fetch source, and that branch can
  ## decline to do anything (it is gated on the fetcher's phase); yielding to
  ## an edge that then does not fire would park the shifter on this pixel for
  ## the rest of the line.
  ##
  ## And restricted to a pixel that HAS a pixel after it. On x = 159 there is
  ## nothing left for the object to queue behind: the line's last fetch is the
  ## window's restart (CGB_WIN_TAIL_LAST), so an object deferred there is
  ## deferred past the end of the line. gambatte measures that corner directly
  ## -- WX = 166 with an object at X = 167, `window/m2int_wxA6_spxA7_*` and
  ## `m0enable/enable_wxA6_2x_spxA7_*` -- and its four mode-0 INTERRUPT rows
  ## want 180 dots on both devices, which is 174 (the window start alone) plus
  ## the object's own six, charged where the object is: on this pixel, in front
  ## of the restart. Deferring here instead charges it on the far side and
  ## gives 190, which takes six of those rows red. See CGB_WIN_TAIL_LAST for
  ## why the CGB's extra fetch is not ALSO added here.
  ppu.lx == ppu.win_lx and not ppu.fetching_window and
    ppu.lx + 8 == int32(ppu.sprites[0].x) and
    ppu.lx < int32(GB_WIDTH) - 1

proc fifo_mix*(ppu: GbFifoPpu; gb: GB; bg_px, sp_px: GbPixel;
               x: int32): uint16 {.inline.} =
  ## The mixer: one BG FIFO entry and one OBJ FIFO entry in, one panel colour
  ## out. Split out of the shifter because the SAME pair is mixed twice -- once
  ## when it is popped, and again for every register write that lands on the
  ## dot after (fifo_recompose_last).
  ##
  ## `x` is the screen column the result is being written to. The shifter and
  ## the recompose pass disagree about it (the latter re-colours lx-1 or lx-2),
  ## and the Super Game Boy path needs the real one to pick an attribute cell.
  ## LCDC.0's DMG meaning ("BG and window enable": the layer reads as colour 0
  ## everywhere) is sampled HERE, per pixel, not at the push that produced the
  ## FIFO entry -- see BG_EN_AT_MIX in gb.nim for the ROM that measures it. In
  ## CGB mode the bit means master priority instead, the layer is drawn either
  ## way, and sprite_wins is where it is read; hence the `cgb_native` term,
  ## which is the same one this test carried at the push.
  ##
  ## The masked colour is threaded through as a value rather than written back
  ## into a copy of the FIFO entry -- this runs once per emitted pixel plus once
  ## per repaint, and the copy-and-store form measured +1.22% of retired
  ## instructions on blargg cpu_instrs and +1.73% on cgb-acid-hell against
  ## `-d:BG_EN_AT_MIX=0`, where this one is under half of that. (A branchless
  ## `and 0 - (LCDC and 1)` mask was tried and is WORSE than either, +1.59% and
  ## +2.07%: the branch is predictable and skips the store outright.)
  let bg_color =
    when BG_EN_AT_MIX != 0:
      if bg_display(ppu): bg_px.color        # the bit is set on almost every
      elif gb.cgb_native: bg_px.color        # pixel of almost every frame, so
      else: 0'u8                             # nothing else is reached at all
    else: bg_px.color
  let use_sprite = sprite_wins(ppu, gb, bg_color, bg_px.obj_to_bg, sp_px)
  let (px_color, px_palette, arr_pram) =
    if use_sprite: (sp_px.color, sp_px.palette, addr ppu.obj_pram[0])
    else:          (bg_color,    bg_px.palette, addr ppu.pram[0])
  let final_color =
    if gb.cgb_native: int(px_color)
    else:
      let p = if use_sprite: (if sp_px.palette == 0: ppu.obp0 else: ppu.obp1)
              else: ppu.bgp
      int(p[px_color])
  if ppu.sgb_attr != nil:
    # Super Game Boy. The SNES colorizes the composited 2-bit video signal per
    # 8x8 SCREEN cell, so the cell's attribute -- not the GB's own BG/OBJ
    # palette selector -- picks the palette, and objects share it with the
    # background underneath them. See sgb.nim.
    let cell = (int(ppu.ly) shr 3) * SGB_ATTR_W + (int(x) shr 3)
    return ppu.sgb_pal[int(ppu.sgb_attr[cell]) * 4 + final_color]
  let pal_offset = (int(px_palette) * 4 + final_color) * 2
  cast[ptr uint16](cast[int](arr_pram) + pal_offset)[]

# ---- The mixer is a TAIL, and it runs behind the FIFO pop -------------------
#
# A register the FETCHER reads is sampled on the dot of the VRAM read that uses
# it. A register the MIXER reads is not: it is sampled one or two dots LATER
# than the dot on which the pixel it colours left the FIFO, and which of the
# two depends on how far down the tail it is read. Only the fetcher's half of
# that was modelled here before.
#
# Two stages, and the rows that separate them are 8 apart in the same suite:
#
#   +1  LCDC's priority bits -- OBJ enable, and BG priority in CGB mode.
#       The BG-vs-OBJ decision (sprite_wins).
#   +2  BGP / OBP0 / OBP1. The shade lookup, one stage after the decision that
#       picks which of them to look in.
#
# **m3_lcdc_obj_en_change gives the first stage exactly**, and it is the
# cleanest instrument in the suite: nineteen objects, one per 8-line band, each
# hanging off the left edge at OAM X = 1..18, and a single LCDC write clearing
# OBJ enable a few dots into mode 3. Each band therefore asks "which is the
# last object pixel the write does NOT suppress", against a write dot the ROM
# itself moves by an M-cycle at LY 64. All 60 of the frame's wrong pixels were
# one answer: the object pixel emitted on the dot immediately before the
# write's own dot survived here and does not on hardware -- at both write dots
# (105 for LY < 64, 109 for LY >= 64) and across all nineteen bands.
#
# **m3_obp0_change gives the second**, the same nineteen objects against two
# OBP0 writes instead. Its write lands on dot 109 of every band, and with the
# priority stage's one dot the pixel emitted on 108 comes right and the one on
# 107 does not -- uniformly, every band. At two it is pixel-exact.
#
# Later at the mixer is what makes a write's effect appear EARLIER on screen,
# which reads backwards until the stages are drawn out: the pixel popped on dot
# D is coloured on D + n, so it sees every write live by D + n, i.e. n more
# writes than the pop dot did.
#
# The whole of that is expressible without adding stages to the dot loop.
# Registers only change at a CPU M-cycle boundary, so "the mixer is n dots
# late" differs from "the mixer is on the pop's dot" in exactly one place: a
# write also reaches the n pixels emitted before it. Redoing those from the
# WRITE path costs the mode 3 loop one eight-byte store per pixel (the FIFO
# entries the mixer is still holding, two dots of them, indexed by the pixel's
# parity so two stages cost what one does) and nothing else -- where real
# holding stages would put another mix and a tail flush on it, and the tail
# accounting at M3_PIPE_DELAY is exactly what a moved shifter has to pay.
# Measured, min of four runs per arm, both arms built in the same directory
# against `-d:MIXER_DOT_LAG=0`: +0.35% of retired instructions on blargg
# cpu_instrs and +0.51% on cgb-acid-hell, which writes LCDC every eight dots
# and is the worst case in the tree.
#
# Why not M3_PIPE_DELAY = 3, which reaches the first stage's dot: because it
# moves the FETCHER too, and the fetcher is already where hardware has it.
# Measured on the mealybug DMG set, one build per arm, wrong pixels of 23040:
#
#   row                          before    PIPE_DELAY=3
#   m3_lcdc_obj_en_change          60         2     mixer-read rows, all better
#   m3_obp0_change                 74        42
#   m3_bgp_change                1508       798
#   m3_bgp_change_sprites        1044       344
#   m3_lcdc_obj_en_change_variant 380       212
#   m3_scx_high_5_bits              0        41     fetcher-read rows, all worse
#   m3_scx_low_3_bits               0       324
#   m3_scy_change                 417      2157
#   m3_lcdc_tile_sel_win_change   106      1028
#   m3_lcdc_bg_map_change         192       444
#
# The split IS the result: every row whose register is read at the mixer wants
# the extra dot and every row whose register is read at the fetcher refuses it,
# which is what says the two stages are a dot apart rather than the pipeline
# being a dot out.
#
# The two stages used to ship on the structure alone -- m3_bgp_change and
# m3_bgp_change_sprites preferred ONE by 22 and 136 pixels where
# m3_window_timing preferred two by 130 and m3_lcdc_obj_en_change_variant by
# 110 -- because the ~800 pixels those two rows had left were a second
# mechanism and an unnamed residual is not a vote. Both names have since been
# found, and both are in this file's neighbourhood rather than in the stage
# count: MIXER_PALETTE_OR (the transition pixel) and MIXER_TAIL_HBLANK (the
# line end, below). With them the two rows prefer TWO by 806 and 624 and the
# vote across the palette rows is unanimous. See docs/gb-failure-triage.md.
#
# ---- The tail does not stop at the mode 3 -> 0 edge ------------------------
#
# The guard below used to be "mode 3, or nothing". It is one dot too strict,
# and m3_bgp_change's own handler is what says so. That ROM writes BGP seven
# times per line at `ld [c],a`, and dingbat's own trace puts the writes on dots
# 81, 97, 109, 169, 181, 241 and **253**; the reference's run-lengths put the
# edge each write draws at exactly `dot - 96`, at all six of the writes that
# land inside mode 3. Mode 3 ends on dot 252 here, so the seventh write is on
# the FIRST DOT OF MODE 0 -- and the reference draws its edge at x = 157 all
# the same, three-valued, with 158 and 159 taking the new value cleanly.
#
# So the rule the six inside-mode-3 writes measure -- a write on dot D reaches
# every pixel from `D - MIXER_PALETTE_BACK - 94` up -- simply does not stop at
# the mode flag. It cannot: the shifter emits one pixel per dot and the tail
# latches a pixel's shade two dots after it leaves the FIFO, so on dot 252
# there are still two pixels inside the tail and one (159) not yet emitted.
# The mode flag is a statement about the FETCHER (fetcher_retired), and the
# fetcher being done is exactly why those last pixels are safe to keep
# clocking: no VRAM read decides them any more.
#
# What has to change is OURS, not the model's. `lx` is the shifter's position
# and stands in for the dot through the whole of mode 3 -- one pixel per dot,
# stalls included -- but `fifo_burst_tail` emits the last `m3_lead` pixels of
# the line ALL ON THE RETIRE DOT, which is the one dot of the line where it
# does not. Two consequences, and both are accounting:
#
#   * the position has to keep counting after `lx` has stopped. `tail_dot0` is
#     latched at the burst as `cycle_counter - lx`, so the shifter's position
#     on any later dot of the line reads back as `cycle_counter - tail_dot0`.
#     Nothing about the edge, the locks or the STAT model moves -- this is a
#     subtraction on a register write, not a dot;
#   * the pixels the burst decided EARLY are in the write's future, not its
#     past, so a write in the tail has to reach FORWARD to them as well. On
#     dot 253 the shifter's position is 159: 157 is the far end of the tail
#     (the `old or new` pixel), 158 is inside it, and 159 has not been emitted
#     at all -- on hardware it takes the new palette because it is emitted
#     after the write, and here it takes it because the recompose sweeps up to
#     the end of the line. That is why this is a span and not a countdown.
#
# The ring of held pairs is MIX_HOLD deep for the same reason: the deepest
# stage plus the lead, which is exactly the four columns 156..159 that a write
# on dot 252 or 253 can name.
#
# ---- The tail is clocked in dots, not in pixels ----------------------------
#
# Everything above counts the reach back from `lx`, which is right for as long
# as the shifter takes one pixel per dot -- and that is every dot of a line
# except an object fetch and the tail burst. mealybug's two `_sprites` rows are
# the ones that stop the shifter under a write and they say DOTS: a write
# reaches a pixel iff that pixel left the FIFO within `back` DOTS of it, so an
# object fetch drains the tail rather than freezing it. The bands and the
# arithmetic are at MIXER_TAIL_DOTS in gb.nim.
#
# ---- and it is written where the shifter STOPS, not where it runs -----------
#
# The obvious implementation is to note `cycle_counter - lx` on every emitted
# pixel, and it costs **+5.02% of retired instructions** on Pokemon Crystal
# (measured, `tools/gbppu/counters.sh`, minimum of four runs a side). The dot
# loop sits on clang's inline threshold -- docs/gb_oam_dma_cost.md's cliff, the
# same one that makes ONE extra branch in tick_shifter +1.7% -- so nothing new
# may go in it.
#
# Nothing has to. `cycle_counter - lx` cannot change while the shifter takes one
# pixel per dot, so it only needs writing where the shifter STOPS, and every
# place it stops is already a cold branch that runs once per stall:
#
#   * an object fetch (mixer_note_stop at the trigger in tick_shifter),
#   * a BG FIFO reset -- the line's own start, and a window restart mid-line
#     (fifo_reset_bg),
#   * the tail burst, at the retire dot.
#
# Each notes the dot base the run it interrupts was on, which is `cycle_counter
# - lx` there, plus the `lx` the next run will start at. Between them the
# recompose can answer both questions it has: while the shifter is stopped the
# position is `cycle_counter - tail_dot0` and the tail drains under it, and
# while it is running the position is `lx` and nothing older than `mix_run` is
# reachable, because a stall stands between.
#
# The price of writing it at the stop rather than at the emit is that
# mixer_tail_front has to TEST for the stall instead of reading it off the
# arithmetic, and one of the three is not a flag -- see the guard there.

proc mixer_head_back(gb: GB): int32 {.inline.} =
  ## The DEEPEST stage of the mixer tail on this console, in dots -- the one
  ## the palettes are read at, less the CGB's own dot of write latency. It is
  ## what MIXER_HEAD_LINGER measures the shallower stages against.
  int32(MIXER_PALETTE_BACK) -
    (if gb.cgb_enabled: int32(CGB_MIXER_LATENCY) else: 0'i32)

proc fifo_recompose_span(ppu: GbFifoPpu; gb: GB; front, back, top, run: int32) =
  ## Re-colour `[front - back, top]`, clipped to the screen, to the pixels the
  ## held ring still has, and to `run` -- the first pixel of the shifter's
  ## current run. `front` is where the shifter stands and `run` where its run
  ## began (both from mixer_tail_front); `back` is how many stages down the tail
  ## the register being written is read.
  var x = max(max(front - back, ppu.lx - MIX_HOLD), run)
  if x < 0: x = 0
  let hi = min(top, ppu.lx - 1)
  while x <= hi:
    let h = ppu.mix[x and (MIX_HOLD - 1)]
    ppu.framebuffer[GB_WIDTH * int(ppu.ly) + int(x)] = fifo_mix(ppu, gb, h.bg, h.sp, x)
    inc x

proc mixer_tail_front(ppu: GbFifoPpu; back, head: int32): (int32, int32, int32)
                     {.inline.} =
  ## `(front, top, run)` for the two recompose procs: where the shifter stands
  ## on this dot, the last column a write may still reach, and the first column
  ## of the shifter's current run.
  ##
  ## While the shifter is RUNNING the position is `lx` -- it is one pixel per
  ## dot, so `lx` and the dot count agree -- and the run bound is what keeps a
  ## write off the pixels on the far side of the stall it has just come out of.
  ## While it is STOPPED, by an object fetch or by the tail burst having run
  ## `lx` to the end of the line, the position is `cycle_counter - tail_dot0`
  ## instead: it keeps counting, so the tail drains under the write exactly as
  ## it does on hardware, and the run bound goes away because the pixels the
  ## drain is still reaching are the ones BEFORE the stall.
  ##
  ## Any other mode has no tail: the values returned there make every span empty
  ## rather than costing a branch, which is also what the park at mode 3 entry
  ## does for a line whose shifter has not emitted anything yet.
  ##
  ## The three stalls of the list above, in the order of the guard below. Two of
  ## them are a flag and a bound; the third -- a BG FIFO reset, i.e. a mid-line
  ## window restart -- has no state of its own, and the empty FIFO alone will
  ## not do, because the FIFO also empties for a dot at an ordinary tile
  ## boundary and `tail_dot0` is only refreshed at a stop. `lx == mix_run` is
  ## what separates them: the reset wrote `mix_run = lx` and the shifter has not
  ## moved since, where a tile boundary is always at least one emission past the
  ## start of its run. mealybug m3_window_timing's line 17 is the measurement --
  ## one pixel, at x = 9, the write reaching two pixels back into a tail that a
  ## six-dot restart had already drained.
  let m = ppu.lcd_status and 3'u8
  if m == 3'u8 or (MIXER_TAIL_HBLANK != 0 and m == 0'u8):
    var front = ppu.lx
    var run = 0'i32
    when MIXER_TAIL_DOTS != 0:
      run = ppu.mix_run
      if ppu.fetching_sprite or ppu.lx >= int32(GB_WIDTH) or
         (ppu.fifo.size == 0 and ppu.lx == ppu.mix_run):
        front = ppu.cycle_counter - ppu.tail_dot0
        run = 0'i32
    elif MIXER_TAIL_HBLANK != 0:
      # The control arm: the position is `lx` through mode 3, nothing drains,
      # and only the H-Blank tail comes off the dot counter.
      if m == 0'u8: front = ppu.cycle_counter - ppu.tail_dot0
    when MIXER_HEAD_LINGER != 0:
      # The line's FIRST pixel keeps every stage of the tail live until the
      # deepest one is read, so a register read at a shallower stage (`back <
      # head`: LCDC's priority bits, against the palettes') still reaches pixel
      # 0 one dot after it has stopped reaching pixel 1. See MIXER_HEAD_LINGER
      # in gb.nim. `front == back + 1` is "the reach stops at pixel 1", the only
      # place the two rules can differ, and `run == 0` is pixel 0 being on this
      # side of every stall the line has had -- with an object at screen x = 2
      # it is not, and its band says so.
      if back < head and front - back == 1'i32 and run == 0'i32:
        dec front
    (front, int32(GB_WIDTH) - 1, run)
  else: (int32(GB_WIDTH) + MIX_HOLD, -1'i32, 0'i32)

proc fifo_recompose_last*(ppu: GbFifoPpu; gb: GB; back: int32;
                          skip: int32 = 0) {.noinline.} =
  ## Re-colour every pixel this write still reaches with the registers as they
  ## stand after it. See the notes above; the caller is ppu_write, on the four
  ## registers the mixer reads.
  ##
  ## `back` is the register's own depth in the tail and `skip` how many pixels
  ## at the far end of it the caller has already painted itself -- one, for a
  ## DMG palette write, whose oldest pixel takes `old or new` (MIXER_PALETTE_OR)
  ## and is done by fifo_recompose_at. Passing `back - 1` instead would work out
  ## the same everywhere but at the head of the line, where MIXER_HEAD_LINGER
  ## makes the reach a function of `back` and the two calls have to agree on
  ## which register they are talking about.
  let (front, top, run) = mixer_tail_front(ppu, back, mixer_head_back(gb))
  fifo_recompose_span(ppu, gb, front, back - skip, top, run)

proc fifo_recompose_at*(ppu: GbFifoPpu; gb: GB; back: int32) {.noinline.} =
  ## Re-colour EXACTLY the pixel `back` stages down the tail, where
  ## fifo_recompose_last re-colours the whole span from there forward. Same
  ## position, same held pairs; the caller is the palette write's transition
  ## dot (see MIXER_PALETTE_OR in gb.nim), which needs the far end of the tail
  ## to take a different value from the rest of it.
  let (front, top, run) = mixer_tail_front(ppu, back, mixer_head_back(gb))
  fifo_recompose_span(ppu, gb, front, back, min(top, front - back), run)

proc fifo_obj_size_write*(ppu: GbFifoPpu; gb: GB) {.noinline.} =
  ## An LCDC.2 write landed after an object was merged and before its HIGH
  ## bitplane was read. Redo that plane, and only that plane: the low one was
  ## read OBJ_PLANE_GAP dots earlier and this write cannot reach it.
  ##
  ## Cold, and off the dot loop entirely -- ppu_store_lcdc reaches it only when
  ## the write actually moves bit 2 AND lands inside the one-or-two dot window
  ## `obj_fix_from` opens. The same shape as fifo_recompose_last next door: the
  ## pipeline's read is later than the dot dingbat does the work on, so the
  ## write path redoes the work rather than the dot loop carrying a stage.
  ##
  ## ---- Why no snapshot of the FIFO is needed --------------------------------
  ##
  ## The merge is undoable from the entries themselves. It only ever overwrote a
  ## slot whose colour was 0 (Pan Docs' "the OBJ pixel is drawn only where the
  ## one already in the FIFO is transparent"), so at each of the object's eight
  ## columns exactly one of three things is true now, and each says what to do:
  ##
  ##   the slot carries THIS object (its `oam_idx`, colour != 0)
  ##       the object won it. Give it the new colour, or -- if the new colour is
  ##       0 -- hand the slot back as a transparent one, which is what it was.
  ##   the slot's colour is 0
  ##       nothing has claimed it. The object takes it if the new colour is not 0.
  ##   anything else
  ##       another object won it and still does; a different high plane cannot
  ##       change that, because the test it lost is on the OTHER pixel's colour.
  ##
  ## The one thing that round trip does not preserve is the `oam_idx` of a
  ## TRANSPARENT entry the object covered, and nothing on DMG reads it: a
  ## colour-0 OBJ pixel loses at sprite_wins before any other field is looked at,
  ## and the only reader of a held entry's index is the CGB merge rule -- which
  ## this path cannot reach at the shipping CGB_OBJ_SIZE_LATENCY, since that puts
  ## the high plane's read a dot BEFORE the merge on CGB.
  if ppu.cycle_counter > ppu.obj_hi_dot: return
  let h = sprite_height(ppu)
  if uint8(h) == ppu.obj_fix_h: return
  ppu.obj_fix_h = uint8(h)
  let s = ppu.obj_fix_s
  let lo = ppu.obj_fix_lo
  let hi = ppu.vram[ppu.obj_fix_bank][sprite_tile_bytes(s, ppu.ly, h).hi]
  let palette = if gb.cgb_native: sprite_cgb_palette(s) else: sprite_dmg_palette(s)
  let clear = GbPixel(color: 0, palette: 0, oam_idx: 0xFF, obj_to_bg: 0)
  for col in 0 ..< 8:
    let shift = if sprite_x_flip(s): col else: 7 - col
    let color = uint8((((hi shr shift) and 0x1) shl 1) or ((lo shr shift) and 0x1))
    let px = GbPixel(color: color, palette: palette, oam_idx: s.oam_idx,
                     obj_to_bg: sprite_priority(s))
    let x = int32(col) + int32(s.x) - 8
    let k = x - ppu.lx
    if k >= 0:
      # Still in the FIFO.
      if k < int32(ppu.fifo_sprite.size):
        let cur = fifo_get(ppu.fifo_sprite, int(k))
        if cur.oam_idx == s.oam_idx and cur.color != 0:
          fifo_set(ppu.fifo_sprite, int(k), if color != 0: px else: clear)
        elif cur.color == 0 and color != 0:
          fifo_set(ppu.fifo_sprite, int(k), px)
    elif x >= 0:
      # Already emitted, so it belongs to the mixer's held pairs -- the same
      # place a palette write reaches back into (fifo_recompose_last). `k` is
      # never further back than OBJ_PLANE1_LAG, which is inside the ring.
      when MIXER_DOT_LAG != 0:
        if x >= ppu.lx - MIX_HOLD:
          var held = ppu.mix[x and (MIX_HOLD - 1)]
          let owns = held.sp.oam_idx == s.oam_idx and held.sp.color != 0
          if owns or (held.sp.color == 0 and color != 0):
            held.sp = (if color != 0: px else: clear)
            ppu.mix[x and (MIX_HOLD - 1)] = held
            ppu.framebuffer[GB_WIDTH * int(ppu.ly) + int(x)] =
              fifo_mix(ppu, gb, held.bg, held.sp, x)

proc tick_shifter*(ppu: GbFifoPpu; gb: GB) =
  if ppu.fifo.size > 0:
    if not ppu.smooth_scroll_sampled: fifo_sample_smooth_scroll(ppu)
    # Check for sprite at current pixel BEFORE popping/rendering
    if sprite_enabled(ppu) and ppu.sprites.len > 0 and
       int(ppu.lx) + 8 >= int(ppu.sprites[0].x) and
       # Last, and only reachable once the three tests above have already
       # passed -- an object trigger is a handful of dots a line, so the whole
       # tie-break sits off the dot loop's hot path. See obj_yields_to_window.
       not obj_yields_to_window(ppu):
      ppu.fetching_sprite = true
      when CGB_WIN_TAIL_LAST != 0:
        # One store, on the object trigger and nowhere else (a handful of dots
        # a line). See fetch_work_pending: on the last pixel this fetch and a
        # window restart at the same pixel are the same slot.
        if ppu.lx == int32(GB_WIDTH) - 1: ppu.obj_last_px = true
      # The shifter stops here for the whole of the object's penalty, and the
      # mixer tail drains under it. See MIXER_TAIL_DOTS -- this is the one of
      # the three stop sites that the mealybug `_sprites` rows measure.
      mixer_note_stop(ppu)
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
        # Pan Docs' exception, and the only place in the algorithm that reads the
        # object's X rather than the FIFO: "an object with an OAM X of 0 always
        # incurs an 11-dot penalty, regardless of SCX". Charging it as index 0 of
        # its tile is that sentence -- 6 + (7 - 0) - 2 = 11 -- where the derived
        # index would be SCX & 7 and would ramp the penalty down to 6 across the
        # residues. GBMicrotest ppu_spritex_vs_scx asserts the flat 11 for all
        # eight of them (see the table at OBJ_FETCH_DOTS); it is also the one row
        # of that table which is not periodic in X, so it cannot be anything but
        # a special case.
        let sub = if ppu.sprites[0].x == 0: 0'i32 else: idx and 7
        pen += max(0'i32, (7 - sub) - (OBJ_WAIT_SUB - 1))
      ppu.obj_penalty = pen
      # Which dot the fetch's HIGH bitplane reads LCDC.2 on. The two arms are
      # the two ends of the penalty -- see OBJ_PLANE1_LAG for the reference
      # frames that separate them -- and this is the only place both `idx` and
      # the penalty are in hand, so it is latched rather than re-derived at the
      # merge. `cycle_counter + pen` is the merge dot.
      ppu.obj_hi_dot =
        (if idx < 0: ppu.cycle_counter + OBJ_PLANE1_HEAD
         else:       ppu.cycle_counter + pen + OBJ_PLANE1_LAG) -
        (if gb.cgb_enabled: int32(CGB_OBJ_SIZE_LATENCY) else: 0'i32)
      when defined(gb_m3_trace):
        if gb_traced(ppu.ly):
          echo "OBJTRIG ly=", ppu.ly, " dot=", ppu.cycle_counter,
               " x=", ppu.sprites[0].x, " lx=", ppu.lx, " fifo=", ppu.fifo.size,
               " lag=", lag, " idx=", idx, " tile=", tile, " pen=", pen
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
    #  * The restart resumes at fetcher step 1 -- fetch_counter 0, the first of
    #    the two dots that step lasts. Pan Docs counts the window's cost as 6
    #    dots from the fetch restart, and from counter 0 that is exactly what it
    #    is: the three reads land on counters 1, 3 and 5 and counter 5 takes the
    #    push, six dots in. It used to start from counter 1 instead, one dot
    #    short, because until 2026-08-03 this renderer idled for the FIRST two
    #    steps of its eight where hardware idles for the last two and the
    #    off-by-one cancelled; that padding now sits where hardware has it (see
    #    the early push in tick_bg_fetcher) and the compensation has to go.
    #    Measured on the fixed fetcher, counter 0 against 1: gambatte 3587 ->
    #    3609 (window +22) and mealybug DMG +361 pixels, against one GBMicrotest
    #    row (win10_scx3_b, which is one M-cycle from its boundary).
    if ppu.lx == ppu.win_lx:
      when defined(gb_m3_trace):
        # Diagnostic only. Every dot the window's WX equality is reached, with
        # the fetcher position and FIFO depth that decide whether the re-trigger
        # survives it -- the instrument the park-anchoring above was measured
        # with, since a mealybug m3_wx_* frame carries one of these per line.
        if gb_traced(ppu.ly):
          echo "WINHIT ly=", ppu.ly, " dot=", ppu.cycle_counter, " lx=", ppu.lx,
               " fc=", ppu.fetch_counter, " fw=", ppu.fetching_window,
               " fifo=", ppu.fifo.size
      if not ppu.fetching_window:
        fifo_reset_bg(ppu, true)
        return
      elif ppu.fetch_counter == WIN_REACT_PHASE and win_react_last_park(ppu) and
           window_enabled(ppu):
        # The re-trigger edge, injected in front of the pixel this dot is about
        # to emit rather than behind the one it just emitted -- the same
        # displacement, one dot earlier, so it can share the compare above.
        window_reactivate(ppu)
    let bg_px = fifo_shift(ppu.fifo)
    let has_sprite = ppu.fifo_sprite.size > 0
    let sp_px = if has_sprite: fifo_shift(ppu.fifo_sprite) else: GbPixel()
    if ppu.lx >= 0:
      when defined(gb_px_trace):
        if gb_traced(ppu.ly):
          echo "PX ly=", ppu.ly, " lx=", ppu.lx, " dot=", ppu.cycle_counter,
               " bg=", bg_px.color, "/", bg_px.palette, "/", bg_px.obj_to_bg,
               " hs=", has_sprite, " sp=", sp_px.color, "/", sp_px.palette,
               "/", sp_px.obj_to_bg, " lcdc=", toHex(ppu.lcd_control, 2),
               " fc=", ppu.fetch_counter, " fx=", ppu.fetcher_x,
               " fifo=", ppu.fifo.size
      # Held for the mixer's extra dot -- see fifo_recompose_last. `has_sprite`
      # is deliberately not kept with them: an empty OBJ FIFO leaves sp_px at
      # colour 0, and sprite_wins already refuses colour 0, so the flag is
      # redundant inside the mix. This and the two guards in ppu_write are the
      # WHOLE cost of the mixer's dot on the shipping build, which is what
      # `-d:MIXER_DOT_LAG=0` exists to A/B against.
      when MIXER_DOT_LAG != 0:
        # Indexed by the pixel's own low bits rather than shifted down, so
        # MIX_HOLD dots of history cost the dot loop the same one store that a
        # single dot of it does.
        ppu.mix[ppu.lx and (MIX_HOLD - 1)] = GbMixHold(bg: bg_px, sp: sp_px)
      ppu.framebuffer[GB_WIDTH * int(ppu.ly) + int(ppu.lx)] =
        fifo_mix(ppu, gb, bg_px, sp_px, ppu.lx)
    inc ppu.lx

proc fetch_work_pending(ppu: GbFifoPpu): bool {.inline.} =
  ## What the fetcher still owes for the last `m3_lead` pixels of a line,
  ## shared by fetcher_retired and (under STAT_IRQ_SPLIT) fifo_irq_m0_ready,
  ## which ask the same question a fixed number of dots apart. Only reached
  ## once the shifter is inside the tail, so it costs the other 150-odd pixels
  ## of a line nothing. See fetcher_retired for what each term is for.
  if ppu.fetching_sprite: return true
  if sprite_enabled(ppu) and ppu.sprites.len > 0 and
     int(ppu.sprites[0].x) <= GB_WIDTH + 7: return true
  when WIN_TAIL_FETCH != 0:
    # A window that HAS started, whose restart has not pushed yet. Without this
    # the term below stops holding mode 3 open the instant the window starts,
    # and the restart, its push and the pixel all fall into the tail burst for
    # nothing -- see WIN_TAIL_FETCH in gb.nim for the gambatte bracket.
    # `fetcher_x == 0` is "the restart still owes its first push": a window
    # fetch has no discarded fetch in front of it (dropped_first_fetch is a
    # line-start flag and stays set), so the counter leaves 0 on that push and
    # cannot return to it on this line. Nor can it alias the head of a line
    # that STARTS as a window line -- that has fetcher_x = 0 at lx = -7..0, and
    # nothing below the lead reaches here.
    #
    # A restart issued on the LAST pixel is the one place the devices part
    # (CGB_WIN_TAIL_LAST): the CGB waits for it and the DMG does not, so the
    # DMG's mode 3 ends with the last PIXEL and the CGB's with the last FETCH.
    # Everywhere else on the line the two coincide, because the fetcher is
    # always ahead of the shifter; only WX = 166 can put a restart here.
    #
    # `obj_last_px` is the exception to the exception: an object whose trigger
    # pixel is also this one has already been fetched in front of the restart,
    # and the CGB does not pay for the slot twice. Six dots either way, once.
    if ppu.fetching_window and ppu.fetcher_x == 0 and
       (ppu.lx < int32(GB_WIDTH) - 1 or
        (CGB_WIN_TAIL_LAST != 0 and ppu.cgb and not ppu.obj_last_px)):
      return true
  if not ppu.fetching_window and ppu.window_trigger and window_enabled(ppu) and
     int(ppu.wx) <= GB_WIDTH + 6: return true
  false

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
  ##     VRAM read (gambatte sprites/10spritesPrLine_10xposA6/A7_*). It is
  ##     conditioned on LCDC.1 for the same reason the window term below is
  ##     conditioned on LCDC.5: an object the mode-2 scan left in the list but
  ##     that the shifter will never trigger (tick_shifter asks
  ##     `sprite_enabled` before anything else) owes the fetcher nothing, so it
  ##     must not hold mode 3 open. Without the gate, clearing LCDC.1 anywhere
  ##     before an object's trigger still bought that line the whole pipeline
  ##     lead -- `-d:gb_m3_len` reads 174 against 172 on every such line, and
  ##     four gambatte DMG rows measure exactly that from the mode 3 -> 0 edge
  ##     (sprites/late_disable_1 and sprite_late_disable_spx18/19/1B_1, whose
  ##     write lands one dot BEFORE the object's trigger so no fetch happens at
  ##     all);
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
  ##
  ## Splitting the four terms below into a `{.noinline.}` tail behind the first
  ## compare -- the shape that would make this one instruction on the dot loop
  ## -- was measured on 2026-08-03 and is NOT worth it. The whole conjunction
  ## costs about +0.04% of retired instructions over the degenerate
  ## `lx >= GB_WIDTH` form, and hoisting it out of line costs MORE than it
  ## saves, because clang already folds the first compare into the dot loop's
  ## own `lx` test (`cmp w8, #0x9d` / `b.gt`, one branch for both questions) and
  ## the split takes that away. Leave it inline.
  when not M3_PIPE_LEAD_ANY:
    # Nothing below can be reached with a zero lead, and this is the mode 3
    # loop's condition -- spell the degenerate case out rather than trust the
    # optimiser to fold three branches back into the one compare it replaces.
    ppu.lx >= GB_WIDTH
  else:
    # The lead is only speed-dependent through its M-cycle term; with that term
    # off it is a compile-time constant, and this test is on the mode 3 dot loop
    # (it runs for every one of a line's ~170 dots), so spell the constant case
    # out rather than load the field: the field form loads and subtracts where
    # this one folds to an immediate.
    when M3_PIPE_MCYCLES == 0:
      if ppu.lx < int32(GB_WIDTH - M3_PIPE_DELAY - M3_END_EARLY): return false
    else:
      if ppu.lx < int32(GB_WIDTH) - ppu.m3_lead: return false
    if ppu.lx >= GB_WIDTH: return true
    not fetch_work_pending(ppu)

proc fifo_pipeline_dot(ppu: GbFifoPpu; gb: GB) {.inline.} =
  ## One dot of the fetch/shift pipeline. The first `m3_lead` dots of a line do
  ## not reach here at all -- the caller skips them in one step, see `m3_delay`
  ## in fifo_tick_slow's mode 3 branch -- and the tail they push past the end of
  ## the line is emitted in one burst when the fetcher retires, so the fetcher
  ## never runs during H-Blank.
  ##
  ## The skip is the caller's and not a test here because this is the mode 3 dot
  ## loop, where a branch taken twice a line and not taken the other ~170 times
  ## is still ~25,000 branches a frame.
  when defined(gb_m3_trace):
    if gb_traced(ppu.ly):
      echo "DOT ", ppu.cycle_counter, " stage=",
           FETCHER_ORDER[ppu.fetch_counter], " lx=", ppu.lx,
           " fx=", ppu.fetcher_x, " lcdc=", toHex(ppu.lcd_control, 2),
           " fifo=", ppu.fifo.size, " spr=", ppu.fetching_sprite,
           " tn=", toHex(ppu.tile_num, 2), " mode=", ppu.mode_flag
  # One call site for tick_shifter, deliberately: it is this loop's body, and a
  # second one costs the inlining (see tick_sprite_fetcher's result). The
  # object's tail dot is the only way through here with neither fetcher run.
  if ppu.fetching_sprite:
    if tick_sprite_fetcher(ppu, gb): return
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
    not fetch_work_pending(ppu)

when M3_PIPE_LEAD_ANY:
  proc fifo_burst_tail(ppu: GbFifoPpu; gb: GB) {.inline.} =
    ## The last `m3_lead` pixels of a line, emitted on the retire dot rather
    ## than spread over the first dots of H-Blank. See the caller.
    ##
    ## This shipped `{.noinline.}` when the lead was first turned on, because
    ## inlining it put a SECOND copy of fifo_pipeline_dot inside
    ## fifo_tick_slow's mode 3 case and that was enough to push
    ## mem_read/mem_write over clang's inline threshold in an arbitrary subset
    ## of the generated opcode bodies -- the cliff docs/gb_oam_dma_cost.md
    ## describes. Re-measured 2026-08-03 with the mode 3 branch settled, that
    ## is no longer true: inlining costs fifo_tick_slow +172 bytes, changes the
    ## size of NOTHING else in the binary (the whole-binary per-function size
    ## diff has exactly two rows), and is worth -0.04% of retired instructions,
    ## because the call and its argument setup were the larger half of what a
    ## two-dot burst costs. Re-run that size diff before changing it back.
    var guard = 0
    while ppu.lx < GB_WIDTH and guard < 64:
      fifo_pipeline_dot(ppu, gb)
      inc guard

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
        # The two bullets that used to stand here have both been resolved, and
        # in the same change (2026-08-03), because they were the same error:
        #
        #  * "The fetcher idles for the FIRST two of its eight steps where
        #    hardware idles for the last two, but the two agree on every VRAM
        #    read's dot so nothing on an object-free line can see it." The
        #    second half was wrong. They do NOT agree: a push taken at
        #    Get-Tile-Data-High used to fall through the two idle steps it had
        #    already served, which put every later read on the line two dots
        #    late. It now restarts the fetch on the push, as Pan Docs' step 4
        #    -> step 1 does. See tick_bg_fetcher.
        #  * "m3_bgp_change carries no objects at all and still wants its whole
        #    frame ~3 pixels to the left, so that residual is the palette
        #    write's own." It is not the palette write's: it is the pipeline's,
        #    it is 2 dots, and the fetcher's misplaced idle was cancelling it.
        #    M3_PIPE_DELAY carries it and the row goes 87.3% -> 93.5%.
        #
        # What is left of the object families is in the OBJ penalty block above:
        # GBMicrotest's ppu_spritex_vs_scx table is 153/153 and the wait-dot rule
        # is untouched.
        when M3_PIPE_LEAD_ANY:
          # The pipeline's head delay, spent in one step rather than as a test
          # inside the loop below. Nothing else in the PPU happens on these
          # dots, so they collapse exactly the way an idle mode's do.
          #
          # What is NOT here, deliberately, is the `continue` this shipped with:
          # falling into the dot loop below is the same sequence of actions --
          # the loop's own `remaining > 0` exits when the head ate the whole
          # tick, and fetcher_retired cannot have changed across dots on which
          # nothing ran -- and it saves the outer loop a back edge. Measured
          # against the same build with the head removed outright (Link's
          # Awakening DMG, retired instructions, minimum of four runs):
          #
          #   this                                       +0.162%
          #   with the `continue` (as shipped 151b952)    +0.187%
          #   a {.noinline.} call instead of the `min`    +0.255%
          #   a two-dot `while` loop                      +0.318%
          #
          # The floor is the `if ppu.m3_delay != 0` alone -- ~0.19%, one `ldrb`
          # and one `cbz` per mode 3 M-cycle, ~6,200 a frame -- so this spelling
          # is at it and the other three are not. Deleting the test needs the
          # head dots to be spendable where mode 3 begins, and they are not: a
          # double-speed M-cycle is two dots and the mode 2 -> 3 transition is
          # one of them, so a lead of 2 always leaves a dot for the next tick.
          if ppu.m3_delay != 0:
            let skip = min(remaining, int(ppu.m3_delay))
            ppu.m3_delay -= uint8(skip)
            ppu.cycle_counter += int32(skip)
            remaining -= skip
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
          #
          # WHICH WX decides it is not read here any more -- it is read at the
          # end of the throw-away fetch six dots from now, where the fine
          # scroll that implements the decision is read too (fifo_head_window,
          # and WIN_LINE_START_LATCH). This edge only has to start the line as
          # a background line so that fetch has a source.
          when WIN_LINE_START_LATCH != 0:
            fifo_reset_bg(ppu, false)
          else:
            fifo_reset_bg(ppu,
              window_enabled(ppu) and
              ppu.wx < uint8(WIN_LINE_START_WX) and ppu.window_trigger)
          fifo_reset_sprite(ppu)
          when CGB_WIN_TAIL_LAST != 0: ppu.obj_last_px = false
          ppu.lx = 0
          when MIXER_DOT_LAG != 0:
            # No tail is in flight until this line's shifter emits something.
            # The park matters for the one path that reaches mode 0 without
            # passing the retire dot -- the LCD being switched off in the middle
            # of mode 3 -- where the previous line's base would otherwise still
            # answer, and for the dots of mode 3 before the first pixel.
            ppu.tail_dot0 = TAIL_DOT0_OFF
            ppu.mix_run = 0
          when M3_PIPE_LEAD_ANY:
            # Latched per line, not a constant: the M-cycle half of the lead is
            # 4 dots at normal speed and 2 in double speed, and a ROM can switch
            # speed between two lines. `current_speed` is 0 or 1.
            ppu.m3_lead = int32(M3_PIPE_MCYCLES * (4 shr gb.memory.current_speed) +
                                M3_PIPE_DELAY + M3_END_EARLY)
            # Only the PIPE terms are paid back at the head. M3_END_EARLY's
            # share is not, which is the whole difference between "the pipeline
            # runs late" and "mode 3 is short".
            ppu.m3_delay = uint8(int(ppu.m3_lead) - M3_END_EARLY)
            ppu.m3_hold = 0
          ppu.smooth_scroll_sampled = false
          ppu.dropped_first_fetch = false
          ppu.sprites = fifo_get_sprites(ppu, gb)
          when LY0_PIPE_MCYCLES != 0:
            # Line 0's pipeline runs LY0_PIPE_MCYCLES CPU M-cycles ahead of
            # where every other line's does, with the flags left alone. Two
            # halves, and both are paid here:
            #
            #  * the head. The advance is larger than the head delay this line
            #    had to give (4 dots against M3_PIPE_DELAY's 2 at normal
            #    speed), so the delay goes to zero and the rest is spent as
            #    pipeline dots on this dot -- the same "the dots are already
            #    decided, emit them here" step fifo_burst_tail makes at the
            #    other end of the line.
            #  * the tail. The fetcher will now retire `adv` dots early, so the
            #    mode 3 -> 0 flag is held for `adv` dots (m3_hold, below) and
            #    lands on the dot it lands on for every other line.
            #
            # `first_line` is excluded: the line 0 that follows an LCD enable
            # was never in vblank, and it has a model of its own already (the
            # whole-line mode-2-reads-as-0 rule in ppu_read, LCD_ON_LINE0_TRIM).
            if ppu.ly == 0 and not ppu.first_line:
              let adv = LY0_PIPE_MCYCLES * (4 shr gb.memory.current_speed)
              let head = int(ppu.m3_delay)
              ppu.m3_delay = uint8(max(0, head - adv))
              ppu.m3_hold  = uint8(adv)
              for _ in 0 ..< adv - min(head, adv): fifo_pipeline_dot(ppu, gb)
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
          when MIXER_TAIL_HBLANK != 0:
            # The third stop site. The burst below emits the last `m3_lead`
            # pixels of the line on THIS dot, where hardware clocks them out one
            # per dot from here -- so the base noted here is what the recompose
            # keeps counting from through the first dots of H-Blank, once `lx`
            # has stopped at 160. `lx < GB_WIDTH` is the guard for line 0
            # (LY0_PIPE_MCYCLES), which revisits the retire dot while m3_hold
            # keeps the flag in mode 3: only the first visit is the burst's.
            if ppu.lx < int32(GB_WIDTH): mixer_note_stop(ppu)
          when M3_PIPE_LEAD_ANY:
            # The tail of the line, emitted on THIS dot rather than spread over
            # the first dots of H-Blank. "The fetcher retired" means every VRAM
            # read the line needs has happened, so the last `m3_lead` pixels are
            # already decided here and nothing the CPU does in H-Blank may reach
            # them -- mealybug m3_scx_low_3_bits rewrites SCX on exactly that
            # dot and sees the difference in the last pixels of every line.
            # Bursting them costs no dots (the lead was already paid at the head
            # of mode 3) and keeps the fetcher out of H-Blank entirely.
            fifo_burst_tail(ppu, gb)
          # A line whose pipeline started early (LY0_PIPE_MCYCLES) retires that
          # many dots early too; the FLAG still leaves mode 3 on the dot every
          # other line does. The burst above is on the retire dot deliberately
          # -- that is where the pixels are decided -- and only the flag waits.
          when LY0_PIPE_MCYCLES != 0:
            if ppu.m3_hold != 0:
              dec ppu.m3_hold
              ppu.cycle_counter += 1
              continue
          when defined(gb_win_trace):
            echo "M3END ly=", ppu.ly, " dot=", ppu.cycle_counter, " len=", ppu.cycle_counter-80
          when defined(gb_m3_len):
            if gb_m3_len_lines > 0:
              dec gb_m3_len_lines
              echo "M3LEN ly=", ppu.ly, " len=", ppu.cycle_counter - 80
          ppu.`mode_flag=`(0'u8, gb)
        else:
          when M3_PIPE_LEAD_ANY:
            if ppu.m3_delay != 0: dec ppu.m3_delay
            else: fifo_pipeline_dot(ppu, gb)
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
