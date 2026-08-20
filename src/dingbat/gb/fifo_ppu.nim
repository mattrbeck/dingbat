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

const CGB_PIPE_MCYCLES* {.intdefine.} = 1
  ## CPU M-cycles the CGB's mode-3 pipeline runs AHEAD of machine time, over the
  ## DMG's. Declared here, at the top of the file, rather than beside
  ## `M3_PIPE_AHEAD` where it is spent, because two consumers below need it and
  ## a const cannot be read before it is declared: `obj_oam_dma_read` (the OAM
  ## DMA bus lead) and `CGB_TDSEL_LATENCY`'s note in gb.nim. That it has
  ## consumers at all is the point of this constant -- see below.
  ##
  ## ---- What pins it ---------------------------------------------------------
  ##
  ## daid `ppu_scanline_bgp`, which is the one instrument in the tree that pins
  ## the pipeline's phase against something other than the mode 2 interrupt: it
  ## takes ONE STAT LYC=0 interrupt out of `halt` on the LY 153 -> 0 snapback,
  ## pops its return address and never returns, then free-runs a loop of
  ## 10x(`ld a,[hl+]` + `ld [c],a`) + 70 `nop` + `jp` -- 114 M-cycles, exactly
  ## one scanline -- for the whole frame. One anchor, 144 lines of ruler.
  ##
  ## The same cart on the two consoles wants two different values, which is why
  ## this is a device split and not a change to `M3_PIPE_AHEAD`:
  ##
  ##   * DMG: pixel-exact against `ppu_scanline_bgp_1.dmg.png` at 0, and 90.5%
  ##     at 1. The DMG pipeline does not move.
  ##   * CGB: 2130/2130 band edges exact at 1 with `--cgb-rev=D`, and three dots
  ##     early at 0. Measured by pairing colour-transition columns row by row
  ##     (tools/gbedge/bandedge.py), not by a whole-frame shift metric, which
  ##     understates a uniform dot error on a banded frame.
  ##
  ## ---- Why it took three constants to land ---------------------------------
  ##
  ## Because three OTHER constants in this tree silently encode this phase, and
  ## the 2026-08-10 sweep that declared this axis contradictory held all three
  ## fixed while moving the phase. Each is `f(phase) + a real hardware delta`,
  ## and each has to move with it or its witness goes red for a reason that has
  ## nothing to do with the phase being wrong:
  ##
  ##   * `OBJ_DMA_BUS_LEAD` (below) -- `strikethrough`. Derived: the DMA unit is
  ##     on machine time, so an earlier fetch must look an M-cycle further ahead.
  ##   * `LY0_PIPE_MCYCLES` (below) -- the whole CGB mealybug corpus, on LINE 0
  ##     ALONE. Derived: that constant is a DIFFERENCE between line 0 and its
  ##     neighbours, so it must not stack with a term every line already has.
  ##   * `CGB_TDSEL_LATENCY` (gb.nim) -- `cgb-acid-hell` against the mealybug
  ##     `tile_sel` set. This one does NOT resolve; see that constant.
  ##
  ## `STAT_M2_LEAD_CGB` (ppu.nim) is the fourth term and is not a compensation:
  ## it is the mode-2 anchor's own M-cycle, independently measured, and the
  ## corpus needs it because the corpus anchors there.

when defined(gb_px_trace):
  # Trace-only running state for the FDATA candidate columns; the harness runs
  # one GB, so module scope is enough and nothing here reaches a shipping build.
  var px_prev_data: uint8
  var px_prev_uns:  uint8

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
    window_trigger_en: base.window_trigger_en,
    current_window_line: -1,
    win_lx: WIN_LX_OFF,
    stat_chg_dot: STAT_NO_HOLD,
    obj_fix_from: OBJ_FIX_OFF,
    lcdc2_flip: [NO_LCDC2_FLIP, NO_LCDC2_FLIP],
    tdsel_dot: NO_TDSEL_CHANGE,
    tdsel_addr: TDSEL_ADDR_OFF,
    map_dot: NO_MAP_CHANGE,
    old_stat_flag: base.old_stat_flag, first_line: base.first_line,
    cycle_counter: base.cycle_counter,
    framebuffer: base.framebuffer, frame: base.frame, ran_bios: base.ran_bios,
    sprites: @[],
    scan_line: -1,
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
  when DMG_WIN_LAST_PX_CARRY != 0:
    # LCDC.5 low DEACTIVATES the window, and an owed start (win_carry) that has
    # to reactivate it costs the window line counter one more than one that
    # never lost it. See WIN_CARRY_REACT_LINES; this is the only place that
    # every write which can clear the bit passes through.
    if not ppu.cgb and not window_enabled(ppu): ppu.win_carry_gap = true
  when WIN_EN_HOLD > 0:
    # A refused match owns the comparator until its hold runs out: `win_lx` is
    # the dot it is waiting on, not a function of WX any more, and the LCDC
    # write that ENDS the hold is one of the writes that lands here. See
    # WIN_EN_HOLD.
    if ppu.win_hold > 0'u8: return
  ppu.win_lx =
    if ppu.fetching_window:
      # The re-trigger edge does need the bit here: window_reactivate is only
      # reached while the window IS the fetch source, and nothing holds a
      # re-trigger (WIN_EN_HOLD is about the START).
      if window_enabled(ppu): int32(ppu.wx) - 8 else: WIN_LX_OFF
    elif not window_enabled(ppu) and WIN_EN_HOLD == 0: WIN_LX_OFF
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
        # The clamp is about the DOT the shifter can notice the match on. The
        # window's TILE still belongs at `target`, one pixel to the left, and
        # win_start_reset puts it there -- it recognises this case by reading
        # the clamp back off `lx` (WIN_PRE_PX_PHASE).
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
  ppu.scx_fine = 0
  when SCX_FINE_LATCH_LIVE:
    ppu.scx_latch_until = -1'i32
  when SCX_STORE_STALL_DOTS != 0:
    # Per-line, like the object penalty below: a stall armed near the end of
    # one line must not hold the next one's head.
    ppu.scx_stall = 0'i32
  fifo_arm_scx(ppu)
  ppu.lx = 0
  ppu.smooth_scroll_sampled = false
  ppu.dropped_first_fetch = false
  ppu.head_cycle = false
  ppu.fetching_window = false
  ppu.fetching_sprite = false
  when DMG_WIN_LAST_PX_CARRY != 0:
    ppu.win_carry = false
    ppu.win_carry_gap = false
  ppu.win_lx = WIN_LX_OFF
  ppu.win_hold = 0'u8
  ppu.obj_penalty = 0
  ppu.obj_tile_fx = -1
  ppu.obj_fix_from = OBJ_FIX_OFF
  ppu.lcdc2_flip[0] = NO_LCDC2_FLIP
  ppu.lcdc2_flip[1] = NO_LCDC2_FLIP
  ppu.tdsel_dot = NO_TDSEL_CHANGE
  ppu.tdsel_addr = TDSEL_ADDR_OFF
  ppu.map_dot = NO_MAP_CHANGE
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
  # The scan's own progress goes with the list it fills: a load onto a running
  # core must not leave it half way through some other line.
  ppu.scan_next = 0
  ppu.scan_line = -1

const OAM_SCAN_DMA_LOCK* {.intdefine.} = 0
  ## An OAM DMA owns OAM for the whole of its transfer, and the mode-2 scan gets
  ## nothing out of the entries it reaches while that lasts. Off; the model is the
  ## scan as one burst at dot 80 against whatever OAM holds by then.
  ##
  ## The scan reads one entry every two dots, and which dot is normally
  ## unobservable -- an OAM DMA is the exception, because it owns OAM from the CPU
  ## clock domain straight through mode 2. That clock crossing is why no constant
  ## offset could ever fix the `oamdma/late_sp*` families.
  ##
  ## Worth +16 / -0 gambatte, but `strikethrough` goes from pixel-exact to 23033
  ## on both devices: its reference still draws an OAM entry a whole-transfer lock
  ## cannot leave readable. So the shape is right and the DURATION is not, and it
  ## stays off until that is derived rather than fitted. (LIJI32's REDIRECT
  ## reading was built and does not help at any offset; a DMG-family-only gate
  ## does recover strikethrough-cgb, if this is ever revisited.)

# ---- The OAM scan reads LCDC.2 FORTY TIMES, two dots apart -----------------
#
# The scan runs in one go on the dot mode 2 ends, which is fine for OAM (the CPU
# cannot reach it during mode 2) but NOT for LCDC.2: the height is a register the
# CPU can move under the scan, and hardware compares each object's Y against the
# height as it stands in THAT object's own two-dot slot -- dot `2N` for object N.
#
# A CGB samples each object at BOTH that dot and the one an M-cycle earlier,
# keeping the object if either says it is on the line. `sprite_on_line` is
# monotone in the height, so that is exactly "either sample says 8x16". As a
# latency it is the bit arriving LATER on CGB, the same direction as
# CGB_OBJ_SIZE_LATENCY at the object fetch. See CGB_OBJ_SCAN_LEAD in gb.nim.
const OAM_SCAN_DOTS = 80'i32
  ## Dots of mode 2, and also the discriminator below: `lcdc2_flip` is cleared on
  ## the dot this scan runs on, so an entry still in it BELOW this is one of this
  ## line's mode-2 writes and one at or above it belongs to the previous line and
  ## is already folded into `lcd_control`.
const OBJ_SCAN_DOT_ADJ* {.intdefine.} = 0'i32
  ## Dots to shift every object's scan sample by. 0 ships (object N samples on
  ## dot 2N); -1 is the other cell the ROMs above cannot separate from it.
  ##
  ## The `oamdma/late_sp*` families derive the same `2N` independently, through an
  ## OAM DMA rather than through LCDC.2 (see OAM_SCAN_DMA_LOCK). Swept over them
  ## with the lock on, `adj` of -3 / -2 / -1 / 0 / 1 / 2 / 3 scores
  ## 34 / 34 / 42 / 42 / 34 / 30 / 26 of 52 -- a two-value plateau falling off on
  ## both sides. Two suites, two mechanisms, one answer.

proc obj_scan_height(ppu: GbFifoPpu; dot: int32): int {.inline.} =
  ## `sprite_height` as the OAM scan's comparator saw it on `dot`. The same walk
  ## back over `lcdc2_flip` as obj_height_at, restricted to this line's mode 2.
  var b = ppu.lcd_control and 0x04'u8
  if ppu.lcdc2_flip[0] > dot and ppu.lcdc2_flip[0] < OAM_SCAN_DOTS:
    b = b xor 0x04'u8
    if ppu.lcdc2_flip[1] > dot and ppu.lcdc2_flip[1] < OAM_SCAN_DOTS:
      b = b xor 0x04'u8
  if b != 0: 16 else: 8

proc obj_scan_on_line(ppu: GbFifoPpu; gb: GB; s: GbSprite; d: int32): bool {.inline.} =
  ## Did the OAM scan's comparator keep object `s` when it read it, on the
  ## object's own dot `d`? Shared by the two scans that have to ask per object
  ## -- the LCDC.2 one below and `oam_scan_advance`, which walks the same dots
  ## for a different reason -- so the CGB rule lives in exactly one place.
  result = sprite_on_line(s, ppu.ly, obj_scan_height(ppu, d))
  when CGB_OBJ_SCAN_LEAD != 0:
    if gb.cgb_enabled:
      const L = int32(CGB_OBJ_SCAN_LEAD)
      if gb.memory.current_speed == 0:
        # The bit arrives L dots late and the comparator glitches for the
        # dots in between: either height may keep the object.
        result = result or sprite_on_line(s, ppu.ly, obj_scan_height(ppu, d - L))
      else:
        # A double-speed M-cycle spends the whole of it inside itself and
        # then some: no glitch, and the arrival is L dots EARLY.
        result = sprite_on_line(s, ppu.ly, obj_scan_height(ppu, d + L))

proc fifo_scan_lcdc2_live(ppu: GbFifoPpu): bool {.inline.} =
  ## Did LCDC.2 move during THIS line's mode 2? One test for the whole scan:
  ## if it did not, every object's sample is the register as it stands and the
  ## loop below is the one it always was. `lcdc2_flip[1]` is older than `[0]`,
  ## so `[0]` alone decides it -- a `[0]` from the previous line cannot be
  ## sitting above a `[1]` from this one.
  ppu.lcdc2_flip[0] >= 0'i32 and ppu.lcdc2_flip[0] < OAM_SCAN_DOTS

proc fifo_scan_sprites_lcdc2(ppu: GbFifoPpu; gb: GB): seq[GbSprite] {.noinline.} =
  ## The scan with a per-object LCDC.2 sample. Split out and NOT inlined: the
  ## fast scan next door is on every rendered line of every frame and a mid-mode
  ## 2 LCDC.2 write is a test ROM, so the two share nothing but the shape.
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
    # `sprite_addr shr 1` is 2N: four bytes per object, two dots per object.
    let d = int32(sprite_addr shr 1) + OBJ_SCAN_DOT_ADJ
    if obj_scan_on_line(ppu, gb, s, d):
      var idx = 0
      while idx < result.len and s.x >= result[idx].x: inc idx
      result.insert(s, idx)
      if result.len >= 10: break
    sprite_addr += 4
  ppu.lcdc2_flip[0] = NO_LCDC2_FLIP
  ppu.lcdc2_flip[1] = NO_LCDC2_FLIP

proc fifo_get_sprites*(ppu: GbFifoPpu; gb: GB): seq[GbSprite] =
  ## The scan as ONE burst on the dot mode 2 ends, which is what ships. Nothing
  ## can write OAM while it runs (the CPU is locked out of OAM for all of mode
  ## 2), so where inside mode 2 each entry is READ is unobservable and the whole
  ## thing may as well happen here. The two things that DO make an entry's own
  ## dot observable each have their own body: LCDC.2 moving under the scan
  ## (fifo_scan_sprites_lcdc2, below the block above) and an OAM DMA holding OAM
  ## (oam_scan_advance, next door, compiled in only with OAM_SCAN_DMA_LOCK).
  ##
  ## Keeping this burst rather than routing it through `oam_scan_advance(ppu,
  ## gb, OAM_SCAN_DOTS)`, which it is exactly equivalent to, is a measured
  ## decision: this is the ~17,500-M-cycle-a-frame path and the two differ by an
  ## allocation pattern -- this builds a fresh seq the caller moves into place,
  ## the incremental one refills the field's own buffer entry by entry across
  ## several calls. On dmg-acid2 with DINGBAT_BENCH_COUNTERS (min of five,
  ## `cycles=` equal on both arms) routing the shipping path through the
  ## incremental body costs **+2.07% of retired instructions** (23,817,092,336
  ## -> 24,310,605,440) against a +0.13% precedent for accepted work here.
  ##
  ## Called on the dot mode 2 ends, and the LAST reader of this line's mode-2
  ## LCDC.2 history -- so it is also what retires it, in place of
  ## fifo_reset_sprite a few statements earlier on the same dot. Moving the CALL
  ## up to sit before that reset instead is what the history wants and it is not
  ## free: it costs +1.11% of retired instructions on Pokemon Blue (24.28e9 ->
  ## 24.55e9) for no change of work at all, purely from where clang then puts
  ## this proc relative to the mode 2 -> 3 block. Retiring the history here costs
  ## nothing and says the same thing.
  if unlikely(fifo_scan_lcdc2_live(ppu)):
    return fifo_scan_sprites_lcdc2(ppu, gb)   # retires the history itself
  ppu.lcdc2_flip[0] = NO_LCDC2_FLIP
  ppu.lcdc2_flip[1] = NO_LCDC2_FLIP
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

proc oam_scan_advance*(ppu: GbFifoPpu; gb: GB; upto: int32; blocked = false) =
  ## Run the mode-2 OAM scan forward through every entry whose own dot is
  ## before `upto`, against OAM as it stands NOW. `blocked` is for the span an
  ## OAM DMA has the OAM bus off the scan: the entries it covers are stepped
  ## over rather than read.
  ##
  ## Called on the two dots either input can change on -- the dot a transfer
  ## takes OAM and the dot it gives it back, so an entry the scan has already
  ## read keeps what it read -- and once at the mode 2 -> 3 edge, which
  ## finishes the line. Between those dots neither input moves, so walking the
  ## entries in one go there is exact.
  ##
  ## Compiled in only with OAM_SCAN_DMA_LOCK on; the shipping scan is
  ## fifo_get_sprites, and that proc's comment says why the two bodies are not
  ## one. The per-object dot and the per-object comparator are NOT a second
  ## copy: `OBJ_SCAN_DOT_ADJ` and `obj_scan_on_line` are the LCDC.2 scan's, and
  ## the two suites that pin them are cross-checks on each other.
  if ppu.scan_line != int32(ppu.ly):
    # A fresh line: the partial result belongs to some earlier one.
    ppu.sprites.setLen(0)
    ppu.scan_next = 0
    ppu.scan_line = int32(ppu.ly)
  while ppu.scan_next < 40 and 2 * ppu.scan_next + OBJ_SCAN_DOT_ADJ < upto:
    let sprite_addr = int(ppu.scan_next) * 4
    let dot = 2 * ppu.scan_next + OBJ_SCAN_DOT_ADJ
    inc ppu.scan_next
    # An entry read while the bus is off the scan is not read at all. Modelled
    # as "not considered" rather than as a read of $FF: for every line the scan
    # runs on, a Y of $FF puts the object at lines 239..246 and is not on it, so
    # the two are the same rule and this one does not have to claim a value it
    # cannot measure.
    if blocked: continue
    let s = GbSprite(
      y:          ppu.sprite_table[sprite_addr],
      x:          ppu.sprite_table[sprite_addr + 1],
      tile_num:   ppu.sprite_table[sprite_addr + 2],
      attributes: ppu.sprite_table[sprite_addr + 3],
      oam_idx:    uint8(sprite_addr),
    )
    if obj_scan_on_line(ppu, gb, s, dot):
      # Sort ascending by X
      var idx = 0
      while idx < ppu.sprites.len and s.x >= ppu.sprites[idx].x: inc idx
      ppu.sprites.insert(s, idx)
      if ppu.sprites.len >= 10:
        # Ten is the line's limit; the scan stops considering entries here
        # exactly as the burst's `break` did.
        ppu.scan_next = 40
  if upto >= OAM_SCAN_DOTS:
    # End of the line's mode 2. This is the last reader of the LCDC.2 history,
    # so it retires it -- the same job, on the same dot, that fifo_get_sprites
    # does on the arm where the lock is off.
    ppu.lcdc2_flip[0] = NO_LCDC2_FLIP
    ppu.lcdc2_flip[1] = NO_LCDC2_FLIP
  when defined(gb_dma_trace):
    if upto >= OAM_SCAN_DOTS:
      echo "OAMSCAN ly=", ppu.ly, " dot=", ppu.cycle_counter,
           " n=", ppu.sprites.len,
           " lcdc=", toHex(ppu.lcd_control, 2),
           " b0=", toHex(ppu.sprite_table[0], 2), toHex(ppu.sprite_table[1], 2),
           toHex(ppu.sprite_table[2], 2), toHex(ppu.sprite_table[3], 2),
           " b9c=", toHex(ppu.sprite_table[0x9C], 2), toHex(ppu.sprite_table[0x9D], 2),
           toHex(ppu.sprite_table[0x9E], 2), toHex(ppu.sprite_table[0x9F], 2)

proc fifo_oam_lock_change*(ppu: GbFifoPpu; gb: GB; taking: bool) =
  ## An OAM DMA has just taken OAM, or is about to give it back, on this dot.
  ## If a mode-2 scan is in progress, walk it up to here under the OLD state
  ## first: everything before this dot was read (or missed) under that, and
  ## everything after it belongs to the new one.
  ##
  ## `cycle_counter` is the dot the M-cycle carrying the edge STARTS on: the
  ## bus half of an M-cycle (where mem_dma_tick lives) runs before the PPU's
  ## dots for the same M-cycle.
  ##
  ## Cold -- twice per transfer, and it does nothing at all outside a mode 2.
  if ppu.mode_flag == 2:
    oam_scan_advance(ppu, gb, ppu.cycle_counter, blocked = not taking)

const SCX_FINE_BORROW* {.intdefine.} = 1
  ## Tiles the BG fetcher's map column drops when a mid-line SCX write lowers
  ## `SCX and 7` below the fine scroll the line latched. 0 is the old model.
  ##
  ## The fetcher is addressed by a SCREEN POSITION with the live SCX added, so
  ## SCX's low three bits take part in the carry into the tile-address bits:
  ## `column = ((SCX + 8*k - F) shr 3) and 31`, where `F` is the latched
  ## `SCX and 7`. That equals the old `k + (SCX shr 3)` except when
  ## `SCX and 7 < F`, where it is one lower -- so only a write that LOWERS the low
  ## bits moves anything, and it moves the column by exactly one tile whatever the
  ## size of the drop. A carry, not a count. The fine scroll itself does not move:
  ## the line keeps emitting on the OLD residue.
  ##
  ## Written as an `ord` term rather than an `if` because this is the mode 3 dot
  ## loop. The window's own fetch has no SCX term and cannot borrow.

const SCX_FINE_BORROW_DMG_LEAD* {.intdefine.} = 1
  ## Pixels the DMG's fetcher position leads the CGB's by inside that comparison:
  ## DMG borrows on `(SCX and 7) + 1 < F`, CGB on `(SCX and 7) < F`. Subtracted
  ## into `scx_fine` at the latch so the dot loop never sees it.

# ---- SCX_FINE_LATCH_LIVE ------------------------------------------------
#
# Declared in gb.nim beside the type it grows a field on. A store to SCX joins the
# line's fine-scroll discard for as long as the discard still has pixels to throw
# away, moving the line's fine scroll and its own length with it. The window is
# the DISCARD, not a fixed number of dots -- so the condition is just `lx < 0`,
# and there is no constant here at all.

# ---- SCX_FINE_LATCH_WRAP -------------------------------------------------
#
# SCX_FINE_LATCH_LIVE's window is not the whole comparator. The discard is a
# three-bit SLOT COUNTER compared each dot against the live `SCX and 7`, so a
# store that lands AFTER the counter has walked past the new value misses its
# slot and wraps into a whole further pass of eight -- which is what "SCX banging"
# abuses, and what makes hardware's mode 3 longer after such a store
# (`gambatte/scx_m3_extend`).

proc fifo_arm_scx*(ppu: GbFifoPpu) =
  ## Recompute the fetcher's SCX term. Called from the one place SCX is stored
  ## (`ppu_store_scx`) and from the fine-scroll latch, which are the only two
  ## events that can change either input.
  when SCX_FINE_LATCH_LIVE:
    # The discard has pixels left to throw away, so this store joins it rather
    # than being measured against it: the fine scroll moves, `lx` moves by the
    # difference, and mode 3 lengthens or shortens with it.
    if ppu.scx_latch_until >= 0'i32 and ppu.cycle_counter <= ppu.scx_latch_until:
      let want = int(ppu.scx and 7) -
                 (if ppu.cgb: 0 else: SCX_FINE_BORROW_DMG_LEAD)
      var extra = 0'i32
      when SCX_FINE_LATCH_WRAP != 0:
        # The discard is a slot counter, not a countdown: it has already walked
        # `consumed` of its eight slots, and a store that puts the target BELOW
        # that cannot be matched on this pass. The window runs to its end, wraps
        # and matches on the next one, which is the whole of the extension.
        # `and 7` and not a plain subtraction: the counter is three bits wide
        # and every pass is eight slots, so what a store is measured against is
        # the slot of the CURRENT pass. Without the mask a line that has already
        # wrapped once measures every later store against an ever-growing
        # number, every one of them wraps, and mode 3 never ends -- which is
        # the runaway the `_ds` banging row catches (it reads 355 against
        # hardware's 331, where the masked form reads 331).
        let consumed = (ppu.cycle_counter - int32(ppu.scx_latch_slot)) and 7'i32
        # `want` and not the raw `SCX and 7`, so the comparison carries the
        # DMG's one-pixel lead exactly as SCX_FINE_BORROW's does -- same sum,
        # same device term. It is what the DMG arm of scx_m3_extend needs and
        # it costs nothing on a CGB, where the lead is zero.
        if int32(want) < consumed:
          extra = SCX_FINE_LATCH_WRAP
          ppu.scx_latch_until += SCX_FINE_LATCH_WRAP
      ppu.lx -= int32(want - ppu.scx_fine) + extra
      ppu.scx_fine = want
  ppu.scx_tile = (int(ppu.scx) shr 3) -
                 SCX_FINE_BORROW * ord((int(ppu.scx) and 7) < ppu.scx_fine)

# ---- SCX_STORE_STALL_DOTS ------------------------------------------------
#
# `gambatte/scx_m3_extend` is the family, and it is the one bracket four
# rounds of the mode-3 campaign left unexplained: a mid-line store to SCX
# lengthens mode 3, and dingbat lengthened it by nothing.
#
# ---- What prices it, and why it is a per-STORE event ----------------------
#
# The family has four members and the `_ds` pair is the whole derivation.
# Read with `tools/gbscx/edgemap.sh`, `_ds_1`/`_ds_2` write SCX TWELVE times
# on one line, every six dots, cycling the low bits 4,2,0,6,4,2,0,6,4,2,0,6
# against a latched fine scroll of 7 -- which is what "SCX banging" names.
# The pair brackets hardware's 3 -> 0 edge to (329, 331] where ours is at
# 259, so hardware's mode 3 is **71 or 72 dots longer** on that one line.
#
# Nine of those twelve stores lower `SCX and 7` against the value standing
# when they land; three raise it (0 -> 6). `9 * 8 = 72`, and no other
# division of that line's stores lands in the bracket: twelve stores would
# need 6 dots each, and the LEVEL predicate the borrow above uses -- every
# one of the twelve is below the latched 7, so it fires once -- gives 8.
# **The banging ROM is what separates a per-store EVENT from a level, and it
# separates them by a factor of nine.**
#
# The single-store members then agree, once the field tail is taken off the
# DMG's reading. `_1`/`_2` bracket hardware's edge at (267, 271] on DMG with
# ours at 259 and `STAT_M0_FIELD_TAIL` already paying 3 of it, and at
# (263, 267] on CGB with ours at 259 and no tail. As extensions those are
# 6..9 dots and 5..8 dots, and **8 is the only value in both** -- so one
# store costs one BG fetch, on both devices, and the DMG/CGB difference
# round 2 measured (11-14 against 7-10) was the field tail all along rather
# than anything about SCX.
#
# ---- Why it is a STALL and not a longer line -----------------------------
#
# A stall of exactly one fetch is content-identical to the borrow above.
# Hold the fetcher and the shifter for 8 dots and no pixel is emitted, so
# every pixel after the stall lands 8 screen columns later -- i.e. screen x
# shows what x - 8 would have shown, the background one tile LOWER. That is
# the same displacement `SCX_FINE_BORROW` produces by subtracting one from
# the map column, and it is why that constant scored +64 on pixels while
# leaving mode 3's length alone: it is the right displacement charged in the
# wrong currency. The two must therefore not both be on -- together they
# displace by two tiles -- which is what `SCX_FINE_BORROW=0` is for here.
proc fifo_scx_store_stall*(ppu: GbFifoPpu; old_scx: uint8) =
  when SCX_STORE_STALL_DOTS != 0:
    if ppu.mode_flag == 3'u8 and ppu.smooth_scroll_sampled and
       (int(ppu.scx) and 7) < (int(old_scx) and 7):
      ppu.scx_stall += SCX_STORE_STALL_DOTS

proc fifo_sample_smooth_scroll*(ppu: GbFifoPpu) =
  when defined(gb_m3_trace):
    echo "LATCH ly=", ppu.ly, " dot=", ppu.cycle_counter, " scx=", ppu.scx
  when defined(gb_px_trace):
    # One VRAM dump per frame, so an offline decode can evaluate any address
    # formula against the reference without another rebuild.
    if ppu.ly == 0:
      for b in 0 .. 1:
        var s = newStringOfCap(2 * ppu.vram[b].len + 8)
        for v in ppu.vram[b]: s.add toHex(v, 2)
        echo "VRAM", b, " ", s
  ppu.smooth_scroll_sampled = true
  # The fine scroll this line started with, less the DMG's one-pixel lead. `lx`
  # below spends the fine scroll as a discard; the fetcher needs it as a NUMBER
  # for the rest of the line, because its map column is formed by adding the
  # live SCX to a screen position that carries this offset. Folding the device
  # term in here rather than at the compare keeps the mode 3 dot loop the exact
  # shape it was. See SCX_FINE_BORROW above.
  ppu.scx_fine = int(ppu.scx and 7) -
                 (if ppu.cgb: 0 else: SCX_FINE_BORROW_DMG_LEAD)
  fifo_arm_scx(ppu)
  when SCX_FINE_LATCH_LIVE:
    # The window is the discard's own length. `SCX and 7` here is the RAW fine
    # scroll, before the DMG lead `scx_fine` carries, because it is a count of
    # discard pixels and not a comparison threshold. It cannot be read off `lx`
    # instead: the head's throw-away fetch parks the shifter, so `lx` stays
    # negative long after the discard is spent, and that spelling opens the
    # window on the `_4` steps hardware shuts it on (measured, 3992/5005).
    ppu.scx_latch_until = ppu.cycle_counter + int32(ppu.scx and 7)
    when SCX_FINE_LATCH_WRAP != 0:
      ppu.scx_latch_slot = uint8(ppu.cycle_counter and 7'i32)
  if ppu.fetching_window:
    # ---- A line that STARTS as a window line still pays SCX & 7 ------------
    #
    # `lx` starting negative is this renderer's discard: those pixels are shifted
    # out and not drawn, so each one is a dot. A line that starts as a window line
    # discards `7 - WX` for the window's own alignment AND `SCX & 7` for the
    # background the throw-away fetch already read -- the two are separate fetches
    # and both are charged. Only the window's half is absorbed into the startup
    # fetch (WIN_HEAD_ABSORB); the SCX half is not.
    ppu.lx = int32(-max(0, 7 - int(ppu.wx))) - int32(7 and int(ppu.scx))
    when WIN_WX0_PHASE == 0:
      if ppu.wx == 0:
        ppu.lx += 1
        if (ppu.scx and 7) > 0: ppu.lx -= 1
    else:
      # The dot the old spelling paid for with that missing seventh pixel. The
      # head budget is `idle + discard = 6` (WIN_HEAD_ABSORB), and at WX = 0 the
      # idle term is `WX - 1` = MINUS one: the window's startup fetch is one dot
      # shorter than everyone else's, which is the other half of
      # `m3_window_timing_wx_0`'s "window activating one T-cycle later when
      # WX = 0 and SCX > 0" -- with SCX > 0 there is no such shortening and the
      # head is the ordinary `6 + SCX & 7` plus that documented dot.
      #
      # Spent HERE and not at the head, for two reasons that are the same
      # reason: this is the dot SCX is latched on, so it is the first dot on
      # which `SCX & 7 = 0` is even known (at the head, two dots earlier, SCX is
      # still the value the previous line's write left -- and a ROM that writes
      # SCX = LY reads one line stale there, which is 105 CGB pixels of
      # `m3_window_timing_wx_0`); and the dot comes out of the fetch's own
      # SLEEP rather than off its front, so the map read this dot is making --
      # and the SCX latch riding on it, which mealybug m3_scx_low_3_bits
      # brackets to one M-cycle -- does not move. The caller's `inc` takes the
      # counter from here, so stepping it once skips FETCHER_ORDER's sleep at 2
      # and the push arrives one dot early, exactly cancelling the extra pixel.
      #
      # Written as an add rather than a branch: this proc is reached from the
      # fetcher's map-read step, and the `if` form measured +0.03% of retired
      # instructions on Pokemon Crystal where this form measures -0.03% (both
      # against the same control build, `cycles=` identical) -- the same
      # inlining cliff the rest of this file's perf notes keep running into.
      ppu.fetch_counter += ord(ppu.wx == 0'u8 and (ppu.scx and 7) == 0'u8)
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
  # Spelled as a `when` so the shipping build is the single store it always was:
  # both knobs are 0 there, and a per-restart `ppu.cgb` test on this path would
  # be a branch bought for a control build nobody ships. See
  # CGB_WIN_RESTART_COUNTER in gb.nim for what the control build is for.
  when WIN_RESTART_COUNTER == 0 and CGB_WIN_RESTART_COUNTER == 0:
    ppu.fetch_counter = 0
  else:
    ppu.fetch_counter =
      if not fetching_window: 0
      elif ppu.cgb: int32(CGB_WIN_RESTART_COUNTER)
      else: int32(WIN_RESTART_COUNTER)
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
  when WIN_EN_HOLD > 0: ppu.win_hold = 0'u8
  fifo_arm_window(ppu)

proc win_start_reset(ppu: GbFifoPpu) {.inline.} =
  ## A window START served by the shifter's equality, with the one case the
  ## equality cannot express folded in: a match on the comparator's PRE-PIXEL
  ## slot (WIN_START_PRE_PIXEL, i.e. WX = 6 with SCX & 7 = 0).
  ##
  ## `win_lx` was clamped UP to the shifter's first pixel so the match could be
  ## noticed at all, and that is right for the dot -- the window is noticed one
  ## dot after hardware notices it, and the fetch it starts is one dot shorter
  ## because of it. It is not right for the TILE: hardware's window tile begins
  ## at the window's own first pixel, `WX - 7`, whatever the shifter can reach.
  ## So take the shifter back onto that pixel (it is off the left edge, so the
  ## framebuffer never sees it) and enter FETCHER_ORDER one step in, at the map
  ## read. Five dots of fetch and the extra pixel is six dots and no extra pixel:
  ## the line's first drawn pixel lands on the same dot it lands on today, which
  ## is what leaves every mode 3 length instrument reading what it read before.
  ## See WIN_PRE_PX_PHASE.
  ##
  ## The test is the clamp, read back: `win_lx` equals `lx` on this dot, so
  ## "the window's own first pixel is one to the left of the pixel the match
  ## fired on" IS `WX - 7 == lx - 1`, and an unclamped match (where `win_lx` is
  ## the target itself) fails it. No flag is kept for it -- fifo_arm_window
  ## re-derives `win_lx` from WX on every write that can move it, so the two
  ## cannot disagree, and asking here rather than storing there keeps a store
  ## off every register write (+0.07% of retired instructions on Pokemon
  ## Crystal, measured).
  ##
  ## A HELD match is excluded explicitly and not by arithmetic: it has walked
  ## `win_lx` up to two pixels right of the match it is retrying and taken one
  ## of them back again (WIN_EN_HOLD_BACK), so its second retry lands on this
  ## test by coincidence -- worth 3 wrong pixels of the same ruler ROM. The two
  ## rules are about different pixels: the hold's is a match the shifter has
  ## already passed, this one a match it has not reached.
  when WIN_PRE_PX_PHASE != 0:
    if ppu.win_hold == 0'u8 and int32(ppu.wx) - 7 == ppu.lx - 1:
      dec ppu.lx
      fifo_reset_bg(ppu, true)
      ppu.fetch_counter = 1
      return
  fifo_reset_bg(ppu, true)

proc fifo_reset_sprite*(ppu: GbFifoPpu) =
  fifo_clear(ppu.fifo_sprite)
  ppu.fetching_sprite = false
  ppu.obj_penalty = 0
  # The object fetch's LCDC.2 read is per-line: no object fetch is in flight
  # across a mode 2 -> 3 edge. See obj_height_at.
  ppu.obj_fix_from = OBJ_FIX_OFF
  # `lcdc2_flip` itself is NOT cleared here. It has a second reader now -- the
  # OAM scan, which asks what the bit was on each object's own mode-2 dot -- and
  # that reader runs a few statements after this one on the same dot 80. It
  # clears the history on its way out instead; see fifo_get_sprites.
  # LCDC.4's is per-line for the same reason: it only ever answers a fetch on
  # THIS line's dots. The ADDRESS latch is not reset with it -- see
  # CGB_TDSEL_GLITCH in gb.nim: it is a bus register, and the first glitched
  # read of a line reports the address the line before it left there. The
  # arming packed ABOVE the address does go with the dot: it is a dot on this
  # line's clock, and a stale one would compare live against the next line's.
  ppu.tdsel_dot = NO_TDSEL_CHANGE
  # LCDC.3 / LCDC.6 at the map read, for the same reason: the dot is on this
  # line's clock and no map read of this line can be answered by the line
  # before it. See CGB_MAP_LATENCY in gb.nim.
  when CGB_MAP_ANY: ppu.map_dot = NO_MAP_CHANGE
  when CGB_TDSEL_IDX_DOTS > 0:
    if ppu.tdsel_addr > 0:
      ppu.tdsel_addr = ppu.tdsel_addr and ((1'i32 shl TDSEL_IDX_SHIFT) - 1)

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

# A line whose WX is below WIN_LINE_START_WX starts as a WINDOW line: the window's
# first pixel is left of the screen, where the shifter's equality can never reach
# it, so the whole line is fetched from the window map from its first tile.
#
# WX is read at the last dot of the head's throw-away fetch (WIN_LINE_START_LATCH),
# not at the mode 2 -> 3 edge -- the same event that latches the fine scroll two
# dots later. The window's own `7 - WX` discard is paid OUT OF its six-dot startup
# fetch (WIN_HEAD_ABSORB), so mode 3 is `172 + 6` for every WX in 0..6, the same
# length a WX >= 7 start has. The dots come back as `max(0, WX - 1)` idle dots at
# the head of the window's fetch -- FETCHER_ORDER's negative steps. The SCX term is
# deliberately not absorbed: it belongs to the throw-away fetch, not the window.
proc fifo_head_window(ppu: GbFifoPpu) =
  ## The head of mode 3 reading WX: does this line start as a window line, and
  ## how many of the window startup fetch's six dots are left over once its
  ## fine-scroll discard has taken its share. Called once per line, from the
  ## dot the throw-away fetch ends on.
  when DMG_WIN_LAST_PX_CARRY != 0:
    # A start the previous line could not draw, owed to this one. Same dot as
    # the WX latch below because the same ROM family brackets both to it
    # (`wxA6_late_we_reenable_1..4`, LCDC.5 back on at dots 77/81/85/89: the
    # first three are taken here and the fourth is not) -- and it is asked
    # FIRST, because the carried start is not a WX match and does not want the
    # WX < 7 head absorb underneath it. LCDC.5 clear does not cancel it, it just
    # does not get to spend it: the latch is still owed on the next line, and on
    # `wxA6_wy01_weoff_ly02` it waits out the whole rest of the frame.
    if ppu.win_carry and window_enabled(ppu):
      ppu.win_carry = false
      ppu.fetching_window = true
      # The counter moves on a carried start exactly as it does on the WX < 7
      # head start below. The FIFO is already empty and fetch_counter has just
      # been rewound by the caller, so there is nothing else of fifo_reset_bg to
      # repeat -- except fetcher_x, which is the one thing a carried start does
      # NOT put back to zero.
      inc ppu.current_window_line
      when WIN_CARRY_REACT_LINES != 0:
        if ppu.win_carry_gap: ppu.current_window_line += WIN_CARRY_REACT_LINES
      ppu.win_carry_gap = false
      ppu.fetcher_x = WIN_CARRY_TILE
      fifo_arm_window(ppu)
      return
  when WIN_LINE_START_LATCH != 0:
    if not ppu.fetching_window and window_enabled(ppu) and ppu.window_trigger and
       ppu.wx < uint8(WIN_LINE_START_WX):
      # `fifo_reset_bg`'s window half, without the reset: the FIFO is empty,
      # `fetcher_x` is 0 and `obj_tile_fx` is -1 already, because nothing has
      # pushed yet and the caller has just rewound `fetch_counter` itself.
      ppu.fetching_window = true
      inc ppu.current_window_line
      fifo_arm_window(ppu)
  when defined(gb_m3_trace):
    # Diagnostic only: the dot the line-start decision is taken on, with the two
    # registers it is taken from. WX is what decides it; SCX is printed next to
    # it because this dot is TWO before SCX's own latch (the `B` two steps on),
    # and a ROM that writes SCX per line is still showing the previous line's
    # value here -- which is why the WX = 0 head dot is spent at the latch and
    # not here (WIN_WX0_PHASE).
    if gb_traced(ppu.ly):
      echo "HEAD ly=", ppu.ly, " dot=", ppu.cycle_counter, " wx=", ppu.wx,
           " scx=", ppu.scx, " fw=", ppu.fetching_window
  when WIN_HEAD_ABSORB != 0:
    if ppu.fetching_window:
      # `WX - 1` idle dots, clamped at 0 because FETCHER_ORDER cannot be entered
      # above its first sleep from here. WX = 0's missing `-1` is spent in the
      # fetch instead, at the dot SCX is latched on -- see WIN_WX0_PHASE in
      # fifo_sample_smooth_scroll, which is where the `7 - WX` discard it goes
      # with is written.
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
        when WIN_EN_HOLD > 0:
          # The comparator is an edge on a counter that only counts up, and
          # `lx` has not moved since the start this read is undoing -- the
          # restart parked the shifter on that very pixel. Re-arming WX - 7 on
          # it would fire the START a second time on the same slot (and, with
          # the bit low, arm a hold nothing can serve). A genuine second start
          # needs a pixel the shifter has not reached.
          if ppu.win_lx == ppu.lx: ppu.win_lx = WIN_LX_OFF
    # ---- LCDC.3 / LCDC.6, as the MAP ADDRESS sees them ----------------------
    #
    # The two map-select bits as they stood CGB_MAP_LATENCY dots ago on a CGB
    # (see that constant in gb.nim: the DMG is pixel-exact on both
    # `m3_lcdc_*_map_change` rows, so those dots are a CGB delta and nothing
    # else). `map_dot` is already the dot the change goes live on, so this is
    # one compare that never takes on a DMG or on any line without a write.
    var map_bits = ppu.lcd_control and 0x48'u8
    when CGB_MAP_ANY:
      if unlikely(ppu.cycle_counter < ppu.map_dot): map_bits = ppu.map_old
    let (map, offset) =
      if ppu.fetching_window:
        # Wraps inside the 32x32 tile map exactly as the background fetch
        # below does. Without the mask a long enough line runs fetcher_x past
        # the end of the map and then off the end of VRAM itself — an
        # out-of-bounds read (The Fish Files crashed the emulator here).
        let m = if (map_bits and 0x40'u8) == 0: 0x1800 else: 0x1C00
        let o = (ppu.fetcher_x and 0x1F) +
                ((((ppu.current_window_line shr 3) * 32)) and 0x3FF)
        (m, o)
      else:
        let m = if (map_bits and 0x08'u8) == 0: 0x1800 else: 0x1C00
        # Latched UNCONDITIONALLY: one store, no branch. Guarding it on
        # quirks.scy_fetch_latch so DMG and CGB-C skip the store was tried and
        # is WORSE -- 6.2069 G -> 6.2415 G retired instructions on
        # cgb-acid-hell, i.e. the branch costs more than the store it saves.
        # Only the READ BACK is gated (see scy_fetch_latch).
        ppu.fetch_scy = ppu.scy
        let o = ((ppu.fetcher_x + ppu.scx_tile) and 0x1F) +
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
    # ---- LCDC.4, as the FETCHER sees it, and the CGB glitch ----------------
    #
    # `sel` is the bit the address is formed from, which on a CGB is the bit as
    # it stood CGB_TDSEL_LATENCY dots ago (see that constant in gb.nim: the
    # DMG's own phase is pixel-exact on both `m3_lcdc_tile_sel_*` rows, so the
    # dot is a CGB delta). `glitch` is set on the one dot the change lands on a
    # read; what each direction delivers is derived at CGB_TDSEL_GLITCH.
    var sel = bg_window_tile_data(ppu) != 0
    var glitch = 0
    when CGB_TDSEL_ANY:
      # `tdsel_dot` is already the dot the change goes LIVE on -- the latency is
      # paid at the write, which is where the speed it is measured in is known.
      # A compare against it rather than a subtraction, so NO_TDSEL_CHANGE can
      # be int32.low without overflowing.
      if unlikely(ppu.cycle_counter <= ppu.tdsel_dot):
        if ppu.cycle_counter < ppu.tdsel_dot: sel = not sel
        else:
          when CGB_TDSEL_GLITCH: glitch = if sel: 1 else: -1
    let tile_num = if sel: int(ppu.tile_num)
                   else: int(cast[int8](ppu.tile_num))
    let tile_data_tbl = if sel: 0x0000 else: 0x1000
    let tile_ptr = tile_data_tbl + 16 * tile_num
    let bank_num = int((ppu.tile_attrs and 0b0000_1000) shr 3)
    var tile_row = if ppu.fetching_window:
                     ppu.current_window_line and 7
                   elif gb.quirks.scy_fetch_latch:
                     (int(ppu.ly) + int(ppu.fetch_scy)) and 7
                   else:
                     (int(ppu.ly) + int(ppu.scy)) and 7
    if (ppu.tile_attrs and 0b0100_0000) != 0: tile_row = 7 - tile_row
    let low_plane = FETCHER_ORDER[ppu.fetch_counter] == fsGetTileDataLow
    let off = tile_ptr + tile_row * 2 + (if low_plane: 0 else: 1)
    var data = ppu.vram[bank_num][off]
    when CGB_TDSEL_GLITCH:
      if unlikely(glitch != 0):
        if glitch < 0:
          # RESET on the read dot: the tile index is the byte. The address the
          # read had already driven is the $8000-region one -- the reset had not
          # reached the address path either -- so it is that address the next
          # SET-glitched read comes back to.
          data = ppu.tile_num
          # ...and it leaves the INDEX path armed for one fetch cycle, which is
          # the whole of CGB_TDSEL_IDX_DOTS. The window rides the same store
          # above the bank, so this is still one store and no wider a field --
          # see TDSEL_IDX_SHIFT in gb.nim for why that mattered. What is stored
          # is the FIRST dot past the window, so that zero up there means "not
          # armed" for every dot including 0.
          ppu.tdsel_addr = int32((16 * int(ppu.tile_num) + tile_row * 2 +
                                  (if low_plane: 0 else: 1)) or
                                 (bank_num shl TDSEL_ADDR_BANK) or
                                 (when CGB_TDSEL_IDX_DOTS > 0:
                                    (int(ppu.cycle_counter) +
                                     CGB_TDSEL_IDX_DOTS + 1) shl TDSEL_IDX_SHIFT
                                  else: 0))
        elif CGB_TDSEL_IDX_DOTS > 0 and
             (ppu.tdsel_addr shr TDSEL_IDX_SHIFT) > ppu.cycle_counter:
          # SET on the read dot with the index path still armed: it answers
          # first, and with THIS tile's index rather than the RESET-glitched
          # one's. `cgb-acid-hell` is the only ROM in the tree that reaches
          # here -- see CGB_TDSEL_IDX_DOTS in gb.nim for what that does and
          # does not establish. TDSEL_ADDR_OFF is -1, so the arithmetic shift
          # keeps it negative and the sentinel cannot arm anything either.
          data = ppu.tile_num
        elif ppu.tdsel_addr != TDSEL_ADDR_OFF:
          # SET on the read dot: the address never advanced, so the byte comes
          # from wherever the last $8000-region read left it. The bank needs a
          # mask now that the arming sits above it.
          data = ppu.vram[(ppu.tdsel_addr shr TDSEL_ADDR_BANK) and 1][
                          ppu.tdsel_addr and ((1 shl TDSEL_ADDR_BANK) - 1)]
      elif sel:
        # An UNGLITCHED LCDC.4 = 1 read is an $8000-region access too, and it
        # leaves its address here like any other. `m3_lcdc_tile_sel_change` and
        # its window twin are the ROMs that separate this from the narrower
        # form (object fetches and RESET-glitched reads only) -- see
        # CGB_TDSEL_GLITCH in gb.nim for the two references' arithmetic. ONE
        # store, which is why the bank is packed in: this line runs on every
        # unsigned bitplane read of every frame.
        ppu.tdsel_addr = int32(off or (bank_num shl TDSEL_ADDR_BANK))
    when defined(gb_px_trace):
      if gb_traced(ppu.ly):
        # Every candidate substitution source this read could have delivered,
        # so a reference frame can arbitrate between them without a rebuild:
        #   uns/sgn  the two addressing modes' bytes for THIS tile+row+plane
        #   latch    the address-latch byte (what the landed SET rule delivers)
        #   prevd    the previous bitplane read's data, whatever mode
        #   prevu    the previous $8000-region read's data (objects included)
        let unsO = 16 * int(ppu.tile_num) + tile_row * 2 + (if low_plane: 0 else: 1)
        let sgnO = 0x1000 + 16 * int(cast[int8](ppu.tile_num)) +
                   tile_row * 2 + (if low_plane: 0 else: 1)
        echo "FDATA ly=", ppu.ly, " dot=", ppu.cycle_counter, " lx=", ppu.lx,
             " fx=", ppu.fetcher_x,
             " plane=", (if low_plane: 0 else: 1), " num=", toHex(ppu.tile_num, 2),
             " row=", tile_row,
             " addr=", toHex(0x8000 + off, 4),
             " byte=", toHex(data, 2),
             " glitch=", glitch,
             " uns=", toHex(ppu.vram[bank_num][unsO], 2),
             " sgn=", toHex(ppu.vram[bank_num][sgnO], 2),
             " latch=", (if ppu.tdsel_addr == TDSEL_ADDR_OFF: "--"
                         else: toHex(ppu.vram[(ppu.tdsel_addr shr
                                               TDSEL_ADDR_BANK) and 1][
                           ppu.tdsel_addr and ((1 shl TDSEL_ADDR_BANK) - 1)], 2)),
             " prevd=", toHex(px_prev_data, 2),
             " prevu=", toHex(px_prev_uns, 2),
             " lcdc=", toHex(ppu.lcd_control, 2),
             # The dot the most recent LCDC.4 change went live on, whether or
             # not it landed on THIS read. `glitch` above is only the delta = 0
             # case; a scorer that has to ask what a change one or two fetcher
             # STEPS earlier does needs the dot itself. NO_TDSEL_CHANGE prints
             # as a large negative, which every delta test then fails.
             " chg=", (when CGB_TDSEL_ANY: $ppu.tdsel_dot else: "-2147483648")
        px_prev_data = data
        if sel: px_prev_uns = data
    if low_plane:
      ppu.tile_data_low = data
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
      ppu.tile_data_high = data
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

# The OBJ penalty, Pan Docs "OBJ penalty algorithm": if the tile The Pixel is in
# has not been considered by a previous object, wait (that tile's pixels strictly
# right of The Pixel) - 2 dots; then a flat 6 for the object's own fetch. Both
# halves fall out of state this renderer already has -- the BG FIFO holds exactly
# The Pixel plus everything right of it, so the wait is `fifo.size - 1 - 2` floored
# at 0 with no register decode, and "not considered yet" is `fetcher_x` differing
# from the tile the last wait was charged against.
#
# Pan Docs' X = 0 exception (a flat 11 regardless of SCX) IS a special case and is
# spelled out as one below; it does not fall out for free at any SCX but 0.
const OBJ_FETCH_DOTS {.intdefine.} = 6'i32
const OBJ_WAIT_SUB {.intdefine.} = 3'i32

# LCDC.2 is read ONCE PER BITPLANE, and where the fetch sits in the penalty
# decides which dots those two reads land on. `sprite_fetch_merge` runs on one
# dot; the two reads are OBJ_PLANE_GAP apart, at OBJ_PLANE1_LAG after the merge
# dot on the `idx >= 0` arm and OBJ_PLANE1_HEAD after the trigger on the `idx < 0`
# arm, where the fetch sits at the head of the penalty and does not move with the
# wait. That split is the same `idx < 0` OBJ_BG_RUN derives from an unrelated ROM.
const OBJ_PLANE_GAP {.intdefine.} = 2'i32
  ## Dots between an object fetch's two bitplane reads: two dots per VRAM access,
  ## the spacing the six-dot fetch is built out of.
const OBJ_PLANE1_LAG {.intdefine.} = 2'i32
  ## Dots after the merge dot at which the HIGH bitplane's read samples LCDC.2, on
  ## the `idx >= 0` arm. The low plane's is OBJ_PLANE_GAP earlier, i.e. the merge
  ## dot itself.
const OBJ_PLANE1_HEAD {.intdefine.} = 6'i32
  ## The same read on the `idx < 0` arm, in dots after the object's TRIGGER: the
  ## fetch sits at the head of the penalty there, so it does not move with the wait.
# ---- The object's OAM read, and the one thing that can see it -------------
#
# This renderer's mode-2 scan snapshots all four of an object's OAM bytes
# (fifo_get_sprites) and mode 3 uses that snapshot. Hardware splits the two: the
# scan latches Y and X -- all it decides with -- and the TILE NUMBER and
# ATTRIBUTES are read out of OAM again during mode 3, at the object's own fetch.
# With OAM quiet the two agree and the split is invisible.
#
# An OAM DMA is where it stops being invisible. While the unit owns OAM the PPU's
# read does not reach the array; it gets the byte the unit has on its bus, the
# same byte a colliding CPU read latches (mem_read_busy). So the object renders
# with a tile number the DMA is only passing through. Pan Docs says only that the
# PPU cannot read OAM properly during the transfer; WHICH byte it gets is
# Hacktix's strikethrough.gb's finding, and that ROM is the whole of the evidence.
#
# The ROM fills OAM with forty objects at Y $54 (LY 68) and X $17, $1F, ... --
# tile 0, a solid bar -- eight pixels apart. On LY 67 a STAT LYC interrupt waits
# for mode 0, idles 28 NOPs and starts an OAM DMA whose 160-byte source is $01 (a
# blank tile) everywhere except ONE $00 at offset 46; the transfer spans the whole
# of LY 68. Hardware draws exactly ONE eight-pixel bar: one object's fetch lands
# on the M-cycle carrying that $00. Off the mode-2 snapshot this renderer drew all
# ten.
#
# The transfer is one byte per M-cycle, so the ROM resolves the fetch's OAM read
# to four dots -- and it does resolve it, because the bar names the object. On
# LY 68 the DMA has overwritten objects 0-5 by the time mode 2 ends, so the ten
# drawn are 6..15 (screen x 63..135) and the bar is object 7's at x 71. This
# renderer's six-dot fetch for that object is dots 171-176 and it merges the tile
# row on 176; the M-cycle carrying source byte 46 is dots 177-180. So the read is
# one M-cycle AHEAD of the fetch's own dots -- OBJ_DMA_BUS_LEAD.
#
# That is a phase between the pipeline and the bus half of an M-cycle, the same
# quantity M3_PIPE_MCYCLES names for the CPU. M3_PIPE_MCYCLES ships at 0 only
# because the CPU's half is paid on the write side instead (mem_write commits at
# the top of its M-cycle); the OAM DMA unit writes through its own path and never
# got that compensation, so the term is still owed and lands here.
#
# Two readings that are NOT it:
#  * "the DMA starts earlier". Moving the unit's start is the other way to put
#    the $00 under object 7's fetch, and it is refuted: one M-cycle earlier (the
#    `next_dma_counter == 8` threshold at 4) does take strikethrough to 0 wrong
#    pixels, and costs sixteen mooneye acceptance rows -- oam_dma_start,
#    oam_dma_timing, oam_dma_restart and the call/ret/push/rst timing family --
#    plus gambatte/oamdma 681 -> 350.
#  * "the read is somewhere inside the fetch". Swept over all six dots of the
#    fetch and out to eleven, into the wait: every one reads $01 and the ROM draws
#    no bar. The window the ROM leaves is four dots wide and does not overlap the
#    fetch.
#
# scanline_ppu cannot mirror this: it draws a whole line in one step at the
# mode 2 -> 3 boundary, so every object would take the same DMA byte and the
# picture would be ten bars or none. The distinction only exists for a renderer
# with a dot per object fetch, and the FIFO renderer is the shipping and scored
# one either way.
const OBJ_DMA_BUS_LEAD {.intdefine.} = 1
  ## M-cycles the object fetch leads the OAM DMA unit's bus by, on a console whose
  ## mode-3 pipeline is not advanced. 0 is "the byte the unit is driving on the
  ## fetch's own M-cycle" (mem.dma_latch).
  ##
  ## It is a phase, so it MOVES WITH THE PHASE. The DMA unit runs on machine time
  ## and the fetch on the pipeline, so advancing the pipeline by an M-cycle moves
  ## the fetch an M-cycle EARLIER against the unit's bus and the fetch must look
  ## one M-cycle FURTHER AHEAD to land on the same source byte. The effective lead
  ## is `OBJ_DMA_BUS_LEAD + CGB_PIPE_MCYCLES`: 2 on CGB, 1 on DMG.
  ##
  ## This was the whole of `strikethrough`'s objection to a moved pipeline, and it
  ## was never a witness of the phase -- it witnesses the SUM. The 2026-08-10
  ## sweep that bracketed the phase two-sidedly held this constant fixed while
  ## moving the phase, so it read the sum move and attributed it to the phase.
  ## With the sum held, `strikethrough-cgb` is byte-identical to its pre-advance
  ## frame, all 23040 pixels.
  ##
  ## Bracketed from both sides, with the DMG arm as one of them: the base is
  ## device-independent and the ADDITION is CGB-only, because the DMG pipeline
  ## does not move. Charge the DMG the extra M-cycle and `strikethrough-dmg`
  ## breaks by the same 7 pixels the CGB arm was breaking by. One ROM, two
  ## consoles, two values, no fit.
  ##
  ## Nothing else reads it: `dma_openbus` and the `0xE000` echo fold are
  ## untouched, and the sweep above still says the read is not inside the fetch.
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
    # The lead moves with the pipeline's phase against the bus -- see the
    # constant. `CGB_PIPE_MCYCLES` is the pipeline's own advance and this is the
    # same M-cycle seen from the DMA unit's side.
    #
    # `CGB_HALT_PPU_LEAD` is the SECOND such advance and is summed here for the
    # identical reason. It advances the PPU by an M-cycle at a STAT/LYC wake and
    # never gives it back, so from the DMA unit -- which runs on machine time --
    # the object fetch has moved an M-cycle earlier and has to look one further
    # ahead to land on the same source byte. Leaving it out is precisely what
    # made `strikethrough-cgb` look like a refutation of the advance: that frame
    # witnesses the SUM, not the phase (see the constant's own derivation), and
    # with the sum held it is byte-identical across the advance. The term is
    # CGB-only because the DMG pipeline does not move -- charging the DMG the
    # extra M-cycle breaks `strikethrough-dmg` by the same 7 pixels, measured.
    let lead = OBJ_DMA_BUS_LEAD +
               (when CGB_PIPE_MCYCLES != 0 or CGB_HALT_PPU_LEAD != 0:
                  (if ppu.cgb: CGB_PIPE_MCYCLES + CGB_HALT_PPU_LEAD else: 0)
                else: 0)
    var src = int(mem.current_dma_source) +
              min(mem.dma_position + lead - 1, 0x9F)
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
  when CGB_TDSEL_GLITCH:
    # An object fetch always addresses the $8000 region, and its LAST read is
    # bitplane 1 -- which is why a SET-glitched background read that follows one
    # reports the object's plane 1 whichever plane it is itself on. See
    # CGB_TDSEL_GLITCH in gb.nim for the band-3 / band-5 pair that says so.
    if ppu.cgb:
      ppu.tdsel_addr = int32(int(b_hi) or (bank shl TDSEL_ADDR_BANK))
  when defined(gb_px_trace):
    if gb_traced(ppu.ly):
      echo "SPR ly=", ppu.ly, " dot=", ppu.cycle_counter, " x=", s.x,
           " tile=", toHex(s.tile_num, 2),
           " lo=", toHex(ppu.vram[bank][b_lo], 2),
           " hi=", toHex(ppu.vram[bank][b_hi], 2)
      px_prev_data = ppu.vram[bank][b_hi]
      px_prev_uns  = ppu.vram[bank][b_hi]
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
  ## One dot of an object fetch. Returns true if this dot was the object's -- the
  ## shifter is stopped for the whole of it -- and false for the one tail dot the
  ## shifter has back but the BG fetcher does not (OBJ_BG_RUN = 4).
  ##
  ## A return value rather than a call to tick_shifter from here: tick_shifter is
  ## the mode 3 dot loop's body, and a SECOND call site stops clang inlining it
  ## into fifo_pipeline_dot -- +0.9% of retired instructions for a dot that
  ## happens at most once per object.
  #
  # The object fetch goes at a TILE BOUNDARY, and the object decides which one,
  # not the fetcher's phase: the boundary at the END of the fetch that was in
  # flight while The Pixel's own tile was being displayed. Two objects can be in
  # identical FETCHER states and still take different boundaries, so no rule
  # phrased on `fetch_counter` works. The discriminator is `idx` at the trigger:
  #
  #   idx >= 0  The Pixel is in the tile the FIFO is displaying, so the fetch of
  #             the tile after it is in flight. It runs inside the penalty to
  #             completion, then parks -- the shifter is stopped, the FIFO cannot
  #             drain, so it cannot start another.
  #   idx < 0   The Pixel is in the tile BEFORE it (OAM X < 8, hanging off the
  #             left edge). The trigger dot IS the previous fetch's plane-1 read,
  #             so the object takes the bus from the NEXT dot for the whole
  #             penalty, one dot past the end of the shifter's stall -- which is
  #             the `obj_penalty <= 0` tail below, not padding.
  #
  # Mode 3's length does not move either way: neither arm can make the fetcher
  # late for a push. Costs +0.76% retired instructions on Pokemon Blue, all of it
  # the rule -- `idx < 0` needs no state, since `obj_tile_fx` and `fetcher_x`
  # cannot move while the shifter is stopped.
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

const M3_PIPE_MCYCLES {.intdefine.} = 0
  ## How far the mode-3 pipeline lags the CPU's view of the PPU registers, in CPU
  ## M-cycles, injected as idle dots at the head of mode 3 -- so the whole
  ## fetch/shift pipeline moves against the CPU clock without a mode boundary
  ## moving (fetcher_retired keeps the flag where it was).
  ##
  ## A diagnostic, not a fix. The M-cycle it was built for is real but was never
  ## the pipeline's to pay: it was the CPU write landing an M-cycle late, and
  ## mem_write now commits at the START of its M-cycle, where the write's own
  ## VRAM/OAM lock is already decided. Turning this up double-counts it.
  ##
  ## A nonzero lead compiles in a per-line head delay and turns fetcher_retired
  ## from one compare into five, on the mode 3 dot loop. Done naively that is
  ## +5.51% of retired instructions; the shipping shape is +0.22%, and what is
  ## left is a floor rather than slack.
const M3_PIPE_DELAY {.intdefine.} = 2
  ## The speed-independent remainder of the same measurement, in dots. It is
  ## exactly the two dots the BG fetcher's padding moved when step 4 went from the
  ## head of its cycle to the tail (the early push in tick_bg_fetcher), which had
  ## been putting every VRAM read two dots late and hiding a pipeline two dots
  ## early.

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
# The same mechanism on EVERY line -- the second axis of bucket 14, and it only
# means anything alongside `STAT_M2_LEAD` in ppu.nim.
#
# Every gambatte family that writes a PPU register out of the mode 2 handler
# measures the dispatch against the pipeline and NOTHING else: `scy`,
# `bgtiledata`, `bgtilemap`, `scx_during_m3`, `dmgpalette_during_m3`, and the
# mealybug `m3_*` frames with them. So the OAM dispatch and the pipeline's phase
# are one unknown to those 180-odd rows, and moving the dispatch four dots early on
# its own costs every one of them (`scy` 67/67 -> 0/67). One M-cycle here gives them
# all back exactly, which is the cancellation bucket 14 predicted: with
# `STAT_M2_LEAD = 1` this is 3963 gambatte against 3743 at 0 and 3716 at 2, and with
# the LEAD at 0 it is 3671 -- neither term scores without the other.
#
# It ships at 0 because the LEAD does; see the halt/sled paragraph at STAT_M2_LEAD
# for what blocks the pair. `LY0_PIPE_MCYCLES` must go to 0 at the same time (3964
# against 3819): line 0's four dots and this lead are the same four dots seen from
# the two ends, and mealybug's `line_0_fix` reads either way round.
const M3_PIPE_AHEAD {.intdefine.} = 0
  ## The device-INDEPENDENT advance. Still 0: nothing measured here asks the DMG
  ## pipeline to move, and daid's DMG arm refuses it outright (pixel-exact at 0,
  ## 90.5% at 1). The CGB's M-cycle is `CGB_PIPE_MCYCLES`, at the head of this file,
  ## and the two are added.
  ##
  ## daid `ppu_scanline_bgp` is the one instrument that pins the pipeline's phase
  ## against something OTHER than the mode 2 interrupt -- it syncs on the LYC = 0
  ## relatch of line 153 (`ly=0 cc=9 mode=1`). It goes 100% -> 90.5% here, which is
  ## four dots. Those four dots are NOT the halt bucket's, which is what an earlier
  ## reading of this had: daid needed this file to stop double-counting the phase
  ## into three other constants. See `CGB_PIPE_MCYCLES`.
const LY0_PIPE_ANY = LY0_PIPE_MCYCLES != 0 or M3_PIPE_AHEAD != 0 or
                     CGB_PIPE_MCYCLES != 0

# Compiles the pipeline-lead machinery out entirely when all the terms are
# off, which is what the `-d:M3_PIPE_MCYCLES=0 -d:M3_PIPE_DELAY=0
# -d:M3_END_EARLY=0 -d:LY0_PIPE_MCYCLES=0` control build for an A/B wants;
# every guard below is a compile-time short circuit at that setting, not a
# runtime test.
const M3_PIPE_LEAD_ANY = M3_PIPE_MCYCLES != 0 or M3_PIPE_DELAY != 0 or
                         M3_END_EARLY != 0 or LY0_PIPE_ANY

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

proc window_refuse_start(ppu: GbFifoPpu) =
  ## The WX comparator matched and LCDC.5 was low. See WIN_EN_HOLD: the match
  ## is neither dropped nor committed -- it holds the comparator on the next
  ## pixel for `WIN_EN_HOLD` dots, and the shifter goes on drawing meanwhile,
  ## so a line whose match is never served pays nothing for it.
  ##
  ## Split out of tick_shifter for the reading, not for the speed: it runs at
  ## most three times a line and only on lines that toggle LCDC.5 mid-mode-3,
  ## and `{.noinline.}` on it measures the same as leaving the compiler to it.
  ## What DID cost 0.6% was the field's position -- see win_hold in gb.nim.
  let hold = if ppu.cgb: uint8(CGB_WIN_EN_HOLD) else: uint8(WIN_EN_HOLD)
  if hold == 0'u8:
    ppu.win_lx = WIN_LX_OFF
  elif ppu.win_hold == 0'u8:
    when WIN_EN_HOLD_ZERO != 0:
      # The refused match and the fetcher's PUSH on the same dot. `size == 8`
      # is that collision -- but the line's INITIAL fill satisfies it too, so
      # the frame must additionally have seen a WY match with the window
      # ENABLED (`window_trigger_en`): a never-enabled window must not glitch,
      # or Pokemon Blue (parked at WX = 7, window off) draws a white column at
      # x = 0 through every frame. See WIN_EN_HOLD_ZERO. The MATCH's own dot,
      # not the hold's retries -- a retry is a comparator that has already
      # fired.
      if ppu.fifo.size == 8 and ppu.window_trigger_en:
        ppu.fifo.data[ppu.fifo.head] =
          GbPixel(color: 0, palette: 0, oam_idx: 0, obj_to_bg: 0)
    ppu.win_hold = hold
    ppu.win_lx = ppu.lx + 1
  else:
    dec ppu.win_hold
    ppu.win_lx = if ppu.win_hold == 0'u8: WIN_LX_OFF else: ppu.lx + 1

proc obj_yields_to_window(ppu: GbFifoPpu): bool {.inline.} =
  ## Does the object the shifter has just found have to wait for the window's
  ## start, instead of the other way round?
  ##
  ## Events happen in COORDINATE order, so an object whose column is left of the
  ## window's first column is fetched first and one to the right after. `lag`
  ## below (`lx + 8 - X`) is that displacement, and only the tie matters:
  ##
  ##   lag > 0   object's column is left of the window's  -> object first
  ##   lag == 0  same column                              -> window first
  ##
  ## The window's refetch must happen before the object has anything to merge
  ## onto: a window start empties the BG FIFO, and at the same pixel the fetch is
  ## upstream of the merge. A left-hanging object was merged a pixel earlier and
  ## survives, because a window start does not clear the OBJ FIFO.
  ##
  ## Restricted to the window's START (the re-trigger branch can decline to fire,
  ## and yielding to an edge that then does nothing parks the shifter for the rest
  ## of the line), and to a pixel that HAS a pixel after it (on x = 159 there is
  ## nothing to queue behind, so the object would be deferred past the line end).
  ppu.lx == ppu.win_lx and not ppu.fetching_window and
    ppu.lx + 8 == int32(ppu.sprites[0].x) and
    ppu.lx < int32(GB_WIDTH) - 1

proc win_start_reaches_pixels(ppu: GbFifoPpu): bool {.inline.} =
  ## **The pixel-path twin of `CGB_WIN_TAIL_LAST`, and the reason 15
  ## `window/on_screen` rows render the wrong device's reference exactly.**
  ##
  ## `CGB_WIN_TAIL_LAST` already says the devices part on a window restart
  ## issued on the line's LAST pixel: the CGB waits for that fetch and the DMG
  ## does not. That split was landed for mode-3 LENGTH only -- it is read in
  ## `fetch_work_pending` and nowhere else -- so the shifter took the restart on
  ## both devices and the DMG drew a window it never draws.
  ##
  ## Only WX = 166 can put a window START on x = 159, which is why the whole
  ## affected set is `window/on_screen/wxA6_*`.
  ##
  ## The oracle here needs no bracketing, because every one of these ROMs ships
  ## BOTH a `_dmg08` and a `_cgb04c` reference and the two differ. Of the 18
  ## `on_screen` ROMs, the 4 whose references are pixel-identical all passed;
  ## the 14 whose references differ were exactly the failing rows, and in every
  ## case the count of pixels dingbat got wrong equalled the count by which the
  ## two references differ -- to the pixel, on all 14 (21816, 21657, 14624,
  ## 14468, 10992, 10780, 8832, 7303, and 120/160 on the rest). dingbat was
  ## rendering the CGB reference bit-exactly on the DMG rows. So the frames
  ## themselves say the behaviour is right for one device and applied to both.
  ##
  ## **What is refuted: refusing the START is not the DMG's rule.** Turning this
  ## on moves the DMG frames, but not onto their reference -- `wxA6_3 [dmg]`
  ## goes 10780 -> 10844 wrong pixels, i.e. further away, and the whole suite
  ## nets +1. So the DMG does not simply decline the match.
  ##
  ## What the two facts together leave is a narrower rule, and it is the obvious
  ## reading of `CGB_WIN_TAIL_LAST` transposed: the DMG **does** start the
  ## window at WX = 166 -- the trigger latches and the window's internal line
  ## counter advances, which is what the later lines of these ROMs depend on --
  ## but its mode 3 ends with the last PIXEL, so the restart's first pixel is
  ## never shifted out. The CGB waits for that fetch and shows it. Separating
  ## "the window started" from "the window's first pixel reached the screen" is
  ## the next step here; this flag conflates them, which is why it is off.
  ##
  ## **That next step landed 2026-08-13 as `DMG_WIN_LAST_PX_CARRY`, and it is
  ## bigger than the sentence above.** Keeping the pixel is only one of its
  ## three halves, and on its own it is worth ONE row: the start is not merely
  ## undrawn, it is still OWED, and the next line the window is enabled on
  ## renders from the window map end to end. 13 of the 14 rows are that. This
  ## flag stays at 0 and stays here as the falsified reading it was.
  ## Keyed on WX rather than on `lx`: the comparator sits one slot LEFT of the
  ## window's first pixel (WIN_START_PRE_PIXEL), so the start that would put
  ## that first pixel on x = 159 is matched at lx = 158, and WX = 166 names it
  ## without depending on which of the pre-pixel rules is in force.
  when DMG_WIN_START_LAST_PX == 0: true
  else:
    ppu.cgb or ppu.fetching_window or int(ppu.wx) != GB_WIDTH + 6

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
# it. A register the MIXER reads is sampled one or two dots LATER than the dot the
# pixel it colours left the FIFO: +1 for LCDC's priority bits (the BG-vs-OBJ
# decision), +2 for BGP/OBP0/OBP1 (the shade lookup, one stage after the decision
# that picks which of them to look in).
#
# That adds no stages to the dot loop. Registers only change at an M-cycle
# boundary, so "the mixer is n dots late" differs from "the mixer is on the pop's
# dot" in one place: a write also reaches the n pixels emitted before it. Redoing
# those from the WRITE path costs one eight-byte store per pixel and nothing else.
#
# The tail does not stop at the mode 3 -> 0 edge, and `tail_dot0` is why: the
# shifter emits one pixel per dot and the tail latches a shade two dots after it
# leaves the FIFO, so pixels are still inside the tail when the fetcher retires.
# The mode flag is a statement about the FETCHER, and its being done is exactly
# why those pixels are safe to keep clocking. `fifo_burst_tail` emits them all on
# the retire dot -- the one dot of the line where `lx` is not the position -- so
# the position is read back as `cycle_counter - tail_dot0` instead, and a write in
# the tail reaches FORWARD to the pixels the burst decided early as well as back.
#
# Clocked in DOTS, not pixels: the two agree except across an object fetch and the
# tail burst, and mealybug says dots, so an object fetch drains the tail rather
# than freezing it (MIXER_TAIL_DOTS).
#
# `cycle_counter - lx` is written only where the shifter STOPS -- an object fetch,
# a BG FIFO reset, the tail burst -- each already a cold branch. Noting it on
# every emitted pixel instead costs +5.02% of retired instructions: the dot loop
# sits on clang's inline threshold (docs/gb_oam_dma_cost.md). The price is that
# mixer_tail_front must TEST for the stall rather than read it off the arithmetic.

proc mixer_head_back(gb: GB): int32 {.inline.} =
  ## The DEEPEST stage of the mixer tail on this console, in dots -- the one
  ## the palettes are read at, less the CGB's own dot of write latency. It is
  ## what MIXER_HEAD_LINGER measures the shallower stages against.
  int32(MIXER_PALETTE_BACK) - gb_mixer_latency(gb)

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

template fifo_emit_pixel(ppu: GbFifoPpu; gb: GB) =
  ## One pixel out of the shifter: pop the two FIFOs, mix, store, advance `lx`.
  ##
  ## Split out of tick_shifter for its SECOND caller, the DMG's window start on
  ## the line's last pixel (DMG_WIN_LAST_PX_CARRY), which has to emit the pixel
  ## the BG FIFO is already holding BEFORE the restart empties it -- everywhere
  ## else the restart happens instead of the pixel and the refetch supplies it.
  ##
  ## A TEMPLATE and not an `{.inline.}` proc, which is not a free choice: as a
  ## proc with two call sites clang stopped inlining it into the mode 3 dot
  ## loop and cgb-acid-hell measured **+3.63% of retired instructions** -- the
  ## inline cliff docs/gb_oam_dma_cost.md describes, on a change that emulates
  ## nothing new on a CGB at all. Expanded at both sites the WHOLE of
  ## DMG_WIN_LAST_PX_CARRY is +0.29% there and +0.20% on blargg cpu_instrs.
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

proc win_start_carries(ppu: GbFifoPpu): bool {.inline.} =
  ## Is this window START the one a DMG cannot draw -- the match on the line's
  ## LAST pixel? See DMG_WIN_LAST_PX_CARRY. Only WX = 166 reaches x = 159, and
  ## only on a DMG, whose mode 3 ends with that pixel.
  when DMG_WIN_LAST_PX_CARRY == 0: false
  else: not ppu.cgb and ppu.lx == int32(GB_WIDTH) - 1

proc tick_shifter*(ppu: GbFifoPpu; gb: GB) =
  if ppu.fifo.size > 0:
    if not ppu.smooth_scroll_sampled: fifo_sample_smooth_scroll(ppu)
    # Check for sprite at current pixel BEFORE popping/rendering.
    #
    # NOT taken (2026-08-14): on CGB the LCDC.1 gate is said to move to the
    # pixel pop — the fetch happens and mode 3 pays even with objects
    # disabled (Pan Docs pixel_fifo "ignored on CGB"; SameBoy display.c
    # fetches on CGB and gates at the pop). Adding `or ppu.cgb` here (with
    # the emit's sprite_enabled already gating display) gains gambatte
    # sprites 461->463 and enable_display +1 — but PHASE-SWAPS the
    # oamdma/late_sp family: every previously-green *_ds_2 / *_4 row trades
    # places with its red *_ds_1 / *_3 sibling, and
    # oamdma_late_speedchange_stat_1 goes red outright (771->770). The
    # mechanism is likely real and the phase off by one fast M-cycle;
    # docs/pandocs-upstream.md section 2 holds the flashcart question.
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
      when STAT_M0_TAIL_ANY and STAT_M0_FIELD_TAIL_ABSORB:
        ppu.obj_dots_line += pen
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
    if ppu.lx == ppu.win_lx and win_start_reaches_pixels(ppu):
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
        when WIN_EN_HOLD > 0:
          # ---- The match waits for LCDC.5; it is not dropped by it ---------
          #
          # See WIN_EN_HOLD. `window_enabled` is asked HERE rather than in
          # fifo_arm_window so that a match the bit refuses is still seen, and
          # the hold below is what keeps the comparator on it for the two dots
          # the bit has left to arrive in. Nothing on this path costs a
          # window-less line anything: with the bit low and no match armed,
          # `win_lx` is WIN_LX_OFF exactly as before and the branch is never
          # reached.
          if not window_enabled(ppu):
            window_refuse_start(ppu)
          else:
            when WIN_EN_HOLD_BACK != 0:
              # A match that WAITED starts the window one pixel left of the
              # pixel the shifter has reached -- the same slot the comparator
              # itself sits in (WIN_START_PRE_PIXEL), and the reason two
              # adjacent scanlines of the ruler ROM begin their windows at the
              # same x. The pixel it takes back has already been written to the
              # framebuffer as background; the window's own first push writes
              # over it. See WIN_EN_HOLD_BACK.
              if ppu.win_hold > 0'u8: dec ppu.lx
            # The DMG's start on the LAST pixel keeps that pixel: mode 3 ends
            # with it, so the restart's own first pixel never reaches the panel
            # and the background entry the FIFO is already holding is what is
            # shown. Emitted BEFORE the restart because the restart empties the
            # FIFO it comes out of. See DMG_WIN_LAST_PX_CARRY; everything else
            # about the start is unchanged, including the window line counter.
            if win_start_carries(ppu):
              fifo_emit_pixel(ppu, gb)
              # fifo_reset_bg and not win_start_reset: the pre-pixel clamp that
              # one reads back off `lx` would see the pixel just emitted and
              # rewind the shifter onto it, painting the window over the
              # background entry this whole branch exists to keep.
              fifo_reset_bg(ppu, true)
              return
            # fifo_reset_bg clears the hold on its way through.
            win_start_reset(ppu)
            return
        else:
          if win_start_carries(ppu):
            fifo_emit_pixel(ppu, gb)
            fifo_reset_bg(ppu, true)
            return
          win_start_reset(ppu)
          return
      elif ppu.fetch_counter == WIN_REACT_PHASE and win_react_last_park(ppu) and
           window_enabled(ppu):
        # The re-trigger edge, injected in front of the pixel this dot is about
        # to emit rather than behind the one it just emitted -- the same
        # displacement, one dot earlier, so it can share the compare above.
        window_reactivate(ppu)
    fifo_emit_pixel(ppu, gb)

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
  when DMG_WIN_LAST_PX_CARRY != 0:
    # A match the window being ALREADY the fetch source does not excuse. The
    # term above is written `not fetching_window` because everywhere else a
    # window that has started has consumed its match -- but a DMG line carried
    # out of the previous one (DMG_WIN_LAST_PX_CARRY) starts with the window
    # already fetching and its WX = 166 match still ahead of the shifter, and
    # the fetcher owes that restart exactly as it owes an ordinary one. Without
    # this the carried line retires `m3_lead` pixels early and reads 172 dots
    # where hardware reads 174, which is what `window/m2int_wxA6_m3stat_1`,
    # `_spxA7_m3stat_1`, `_oambusyread_1` and `_vrambusyread_1` measure: their
    # frame is 144 consecutive carried lines and they sample one of them.
    if not ppu.cgb and ppu.fetching_window and
       (ppu.lx < int32(GB_WIDTH) - 1 or
        (ppu.obj_last_px and ppu.lx < int32(GB_WIDTH))) and
       ppu.window_trigger and window_enabled(ppu) and
       int(ppu.wx) == GB_WIDTH + 6: return true
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
  when SCX_STORE_STALL_DOTS != 0:
    # A mid-line SCX store holds the whole pipeline, fetcher and shifter both,
    # for one BG fetch. See SCX_STORE_STALL_DOTS above.
    if ppu.scx_stall > 0:
      dec ppu.scx_stall
      return
  # One call site for tick_shifter, deliberately: it is this loop's body, and a
  # second one costs the inlining (see tick_sprite_fetcher's result). The
  # object's tail dot is the only way through here with neither fetcher run.
  if ppu.fetching_sprite:
    if tick_sprite_fetcher(ppu, gb): return
  else:
    tick_bg_fetcher(ppu, gb)
  tick_shifter(ppu, gb)

proc fifo_obj_abort*(ppu: GbFifoPpu; gb: GB) =
  ## LCDC.1 has just gone low while an object's stall is running: the fetch is
  ## abandoned, the object dropped, and the rest of the penalty comes back.
  ##
  ## The SHIFTER gets both dots back (OBJ_ABORT_LEAD) and the FETCHER only one
  ## (OBJ_ABORT_FLAG_HOLD) -- the cancelled VRAM cycle still owns the bus for its
  ## last dot, so the fetcher retires a dot behind the pixels and only the mode
  ## 3 -> 0 flag can see it. That split is what makes gambatte (which reads the
  ## flag through STAT) and mealybug (which reads the pixels) agree; no single
  ## refund satisfies both. The WAIT half is abortable too, not just the object's
  ## own six dots. The CGB does not do this at all (CGB_OBJ_ABORT).
  ##
  ## The object is dropped rather than re-armed because `lx` has not moved:
  ## leaving it in the list would re-trigger it the instant LCDC.1 came back.
  ppu.fetching_sprite = false
  ppu.obj_penalty = 0
  if ppu.sprites.len > 0: ppu.sprites.delete(0)
  # The lead, spent here. The write's own dot still runs its pipeline step
  # after this returns (ppu_write is called from the CPU's memory access and
  # fifo_tick catches up behind it), so `OBJ_ABORT_LEAD` extra steps here make
  # the shifter's first dot back `W - OBJ_ABORT_LEAD` -- the same "the dots are
  # already decided, emit them here" step LY0_PIPE_MCYCLES makes at the head of
  # line 0 and fifo_burst_tail makes at the end of every line. It can never
  # over-run: the trigger dot is itself stalled, so a write that reaches here
  # is at least one dot past it.
  for _ in 0 ..< OBJ_ABORT_LEAD: fifo_pipeline_dot(ppu, gb)
  # ... and the dot the FETCHER does not get back, which only the mode 3 -> 0
  # flag can see. See the two-part account above.
  when OBJ_ABORT_FLAG_HOLD != 0:
    ppu.m3_hold = ppu.m3_hold + uint8(OBJ_ABORT_FLAG_HOLD)

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
    elif ppu.m2_early_stop(gb): ppu.m2_early_dot(gb)
    else: gb_line_end(ppu)
  else:
    # Every boundary is two stops in a STAT_IRQ_LEAD build, `lead` dots apart:
    # the interrupt line's copy of the mode turns over first, the mode flag
    # after it. The comparisons are `>=`, not `>`: a stop the counter is
    # already sitting on has not been *processed* yet (the skip that landed on
    # it returned before the loop body ran), so it is still the next thing to
    # do. At normal speed the lead's dot and M2_144_EARLY_DOT coincide; in
    # double speed they do not, hence three candidates rather than two.
    block:
      let boundary = if m == 2: 80'i32 else: gb_line_end(ppu)
      var tgt = boundary
      let irq_dot = boundary - stat_irq_lead(gb)
      if irq_dot >= ppu.cycle_counter: tgt = irq_dot
      if ppu.ly == 143 and m == 0 and gb.cgb_enabled and
         M2_144_EARLY_DOT >= ppu.cycle_counter and M2_144_EARLY_DOT < tgt:
        tgt = M2_144_EARLY_DOT
      tgt

when STAT_M2_EARLY:
  proc fifo_m2_early_edge(ppu: GbFifoPpu; gb: GB) {.noinline.} =
    ## The OAM STAT source comes up one CPU M-cycle (STAT_M2_LEAD) before the
    ## line that scans OAM starts, and nothing else happens on that dot -- so
    ## the edge detector has to be run here explicitly, exactly the way
    ## m2_line144's CGB pulse is four dots ahead of the vblank boundary. The
    ## skip target stops on the dot so the loop visits it at all.
    ##
    ## `noinline` for the reason fifo_line153_edge and lyc_settling are: the
    ## caller is the dot loop, it is inlined into the bus path, and its body
    ## sits on clang's inline threshold (docs/gb_oam_dma_cost.md).
    if ppu.m2_early: ppu_handle_stat_interrupt(ppu, gb)

proc fifo_line153_edge(ppu: GbFifoPpu; gb: GB) {.noinline.} =
  ## ---- The LY 153 -> 0 snapback is an edge the STAT line has to see --------
  ##
  ## It never was: LY was assigned in the vblank branch and the edge detector
  ## was left for the line boundary 451 dots later, so a LYC=0 STAT interrupt
  ## fired at the top of line 0 instead of inside line 153, and a LYC=153 one
  ## was never taken back down at all. Everything the comparator drives moved
  ## with it -- the readable coincidence bit as much as the interrupt.
  ##
  ## daid's ppu_scanline_bgp is what made that visible rather than merely late.
  ## Its whole frame is one BGP write every four M-cycles, resynced once per
  ## frame by exactly this interrupt and free-running at 114 M-cycles a line
  ## afterwards, so the frame is a picture of where the handler started and a
  ## whole line of error puts every pixel of it 456 dots out of place.
  ## 68.8% -> 90.5% with the first branch below, and the 4 dots left over are
  ## the settling window at LYC_SETTLE_DOTS, which the second one closes.
  ##
  ## `noinline`, and one call site rather than the two branches spelled out at
  ## the two dots they fire on, because the caller is fifo_tick_slow's dot loop:
  ## it is inlined into the bus path and its body sits on clang's inline
  ## threshold (docs/gb_oam_dma_cost.md). In line it measured **+0.37% of ALL
  ## retired instructions** on Pokemon Crystal and on Pokemon Blue, for work
  ## that decides two dots a frame. `lyc_settling` carries the same warning and
  ## for the same reason; between them they are most of what this change would
  ## otherwise have cost.
  if ppu.ly == 153:
    # The near side: LY changes, and with it any match it had. The new one does
    # not arrive yet -- the comparator is blind for LYC_SETTLE_DOTS, which
    # lyc_settling reads back off this same LY and dot.
    ppu.ly = 0
    when STAT_IRQ_SPLIT: ppu.irq_ly = 0
    ppu_handle_stat_interrupt(ppu, gb)
  elif ppu.ly == 0 and ppu.cycle_counter == LYC_RELATCH_DOT:
    # The far side: the comparator re-latches, so with LYC = 0 this is the dot
    # the match -- and its interrupt -- appears on. `mode 1 with LY 0` is line
    # 153 and nothing else; line 0 is already in mode 2 by the time its own LY
    # reads 0.
    ppu_handle_stat_interrupt(ppu, gb)

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
      # are collapsed. The level-triggered rules in the set opt out of the jump
      # so they still fire on exactly the dots they used to: LY 153 snapping
      # back to 0 at LY153_SNAP_DOT, and the LY=LYC comparator re-latching at
      # LYC_RELATCH_DOT after it. One bound on the counter covers both, at the
      # price of walking the first ten dots of the other nine vblank lines as
      # well -- 90 no-op iterations a frame.
      let m = ppu.mode_flag
      if m != 3:
        let target = fifo_skip_target(ppu, gb, m)
        if ppu.cycle_counter < target and
           (m != 1 or ppu.cycle_counter > LYC_RELATCH_DOT):
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
      when defined(gb_phase_trace):
        gb_phase = int32(cycles - remaining - 1)
        gb_ticklen = int32(cycles)
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
          when STAT_M0_TAIL_ANY and STAT_M0_FIELD_TAIL_ABSORB:
            ppu.obj_dots_line = 0'i32
          when SCX_FINE_LATCH_LIVE:
            ppu.scx_latch_until = -1'i32
          ppu.dropped_first_fetch = false
          # Finishes the line's OAM scan at the dot mode 2 ends on. With the
          # lock off that is the whole scan, in one burst; with it on, every
          # entry a transfer's edge has not already forced it past -- and a
          # transfer still in flight has held OAM off the scan since that edge,
          # so the tail of the line is blind.
          when OAM_SCAN_DMA_LOCK != 0:
            oam_scan_advance(ppu, gb, OAM_SCAN_DOTS,
                             blocked = gb.memory.dma_busy)
          else:
            ppu.sprites = fifo_get_sprites(ppu, gb)
          when LY0_PIPE_ANY:
            # Line 0's pipeline runs LY0_PIPE_MCYCLES CPU M-cycles ahead of
            # where every other line's does (and M3_PIPE_AHEAD, if it is on,
            # runs EVERY line's ahead by that much again), with the flags left
            # alone. Two
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
            # The device-independent term plus the CGB one; `base` is what EVERY
            # line of this frame gets.
            let base = M3_PIPE_AHEAD +
                       (when CGB_PIPE_MCYCLES != 0:
                          (if ppu.cgb: CGB_PIPE_MCYCLES else: 0)
                        else: 0)
            # ---- Line 0 does not get a second helping ---------------------
            #
            # `LY0_PIPE_MCYCLES` says line 0's pipeline runs one M-cycle ahead
            # of every OTHER line's. That is a statement about the DIFFERENCE
            # between line 0 and its neighbours, not an extra M-cycle line 0
            # owns outright -- so once `base` has advanced every line by an
            # M-cycle there is nothing left for line 0 to be ahead OF, and
            # adding the two puts line 0 two M-cycles out on its own.
            #
            # Measured, and it is the whole of the CGB mealybug residue this
            # spelling was found by: with the terms ADDED, thirteen CGB rows
            # come back wrong on LINE 0 ALONE and nowhere else (m3_bgp_change
            # 22 wrong pixels, all at y = 0; m3_lcdc_tile_sel_change 16, all at
            # y = 0), which is exactly what one M-cycle of double-count on one
            # line looks like and is nothing like the whole-frame band shift a
            # wrong phase gives. Taking the MAX instead returns every one of
            # them to byte-identity with the pre-advance frame.
            #
            # mealybug's own ROMs are the outside confirmation that the term is
            # a difference: `m3_bgp_change.asm` opens its handler with
            # `ldh a,[rLY] / and a / jr nz,.line_0` -- a deliberate one-M-cycle
            # swing on line 0 only, commented "line 0 timing is different by 4
            # cycles". A difference is what the ROM compensates and a difference
            # is what this models.
            # On DMG `base` is 0, so line 0 keeps exactly the M-cycle it always
            # had; on CGB `base` is already that M-cycle and line 0 shares it.
            let mc = if ppu.ly == 0 and not ppu.first_line:
                       max(base, LY0_PIPE_MCYCLES)
                     else: base
            if mc != 0:
              let adv = mc * (4 shr gb.memory.current_speed)
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
          when DMG_WIN_LAST_PX_CARRY != 0:
            # The end of the line, which is where hardware clears "the window
            # has started" -- and on a DMG that is the same dot the comparator
            # can still match on, so a match on the LAST pixel survives into the
            # next line. Asked here, once a line, rather than at the match:
            # the match is not reachable at all once the window is already the
            # fetch source, and the whole point is that a carried line carries
            # again (`wxA6_wy00` is a window line from LY 0 to LY 143 off one
            # match per line). The WY latch is what separates it from "the
            # window happens to be on": `wxA6_wy01` draws LY 0 as a window line
            # from LY 143's match and does NOT carry out of it, because on LY 0
            # the latch is clear again.
            #
            # LCDC.5 is deliberately NOT in here, and that is measured, not an
            # omission: `wxA6_weoff_at_xposA6` clears the bit at x = 96 of every
            # line and still draws the NEXT line as a window line, so the
            # comparator sets the latch with the bit low. The bit gates spending
            # the latch (fifo_head_window), not owing it. See
            # DMG_WIN_LAST_PX_CARRY.
            if not ppu.cgb and int(ppu.wx) == GB_WIDTH + 6 and
               ppu.window_trigger:
              ppu.win_carry = true
          # A line whose pipeline started early (LY0_PIPE_MCYCLES) retires that
          # many dots early too; the FLAG still leaves mode 3 on the dot every
          # other line does. The burst above is on the retire dot deliberately
          # -- that is where the pixels are decided -- and only the flag waits.
          when LY0_PIPE_ANY:
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
        # ---- The line-tail gate was TRIED HERE and is REFUSED ---------------
        #
        # Four boundary events live in this branch and all four are at dots in
        # `[line_end - 4, line_end]` -- the CGB line-144 pulse, the OAM source's
        # lead, the split IRQ domain's lead, the line advance -- so gating them
        # behind one `cycle_counter >= line_end - 4` compare looks like it must
        # be free money, and it is the obvious way to stop the DMG paying for a
        # CGB-only OAM lead.
        #
        # It costs **+2.2% on cgb-acid-hell and buys the DMG exactly nothing**
        # (25.03e9 against 24.50e9 retired instructions; dmg-acid2 unmoved at
        # 23.79e9), with the line-end load hoisted into a local so the gate is
        # not paying for a repeated `case` either. The premise is simply wrong:
        # `fifo_skip_target` already jumps the dot loop STRAIGHT to these dots
        # and never visits H-Blank's other ~50, so there is no per-dot cost here
        # to fold away -- the gate is a compare added to dots that were all
        # going to do the work anyway.
        #
        # Which also relocates the DMG's residual cost: it is not in this
        # branch. What the DMG pays for a compiled-in `STAT_M2_EARLY` is the
        # extra stop in `fifo_skip_target` (once per skip) and the extra compare
        # in `m2_source` (once per STAT evaluation), neither of which a gate
        # here can reach.
        #
        # CGB raises the line-144 mode 2 STAT source one M-cycle before the
        # line ends (see m2_line144). The source is level-triggered off the
        # dot counter, but nothing else happens on this dot, so the edge
        # detector has to be run here explicitly; the skip target above stops
        # the idle jump on it so this dot is actually visited.
        if ppu.cycle_counter == M2_144_EARLY_DOT and ppu.ly == 143 and
           gb.cgb_enabled:
          ppu_handle_stat_interrupt(ppu, gb)
        # ...and the OAM source of the line about to START comes up in this
        # line's last M-cycle, on every line that scans OAM. Same shape, same
        # reason the skip target stops here. See STAT_M2_LEAD.
        when STAT_M2_EARLY:
          if m2_lead_active(gb) and ppu.cycle_counter == ppu.m2_early_dot(gb):
            fifo_m2_early_edge(ppu, gb)
        when STAT_IRQ_SPLIT:
          if ppu.cycle_counter == gb_line_end(ppu) - lead:
            fifo_irq_line_advance(ppu, gb)
        if ppu.cycle_counter == gb_line_end(ppu):
          ppu.stat_chg_dot -= ppu.cycle_counter
          when LCD_ON_TRIM_ANY:
            if ppu.lcdon_lines > 0: dec ppu.lcdon_lines
          ppu.cycle_counter = 0
          ppu.ly += 1
          # The irq domain got here a lead ago; this is its catch-up for the
          # unsplit build and for anything that stepped over that dot.
          when STAT_IRQ_SPLIT: ppu.irq_ly = ppu.ly
          ppu.read_mode = ppu.read_mode or LY_JUST_CHANGED
          # The comparator lets go here and answers again in ly_advance_close. A
          # rendered line starting happens INSIDE that window -- mode 2 and the
          # OAM pulse ARE the line start -- so the mode change goes between the
          # two. Entering vblank is not a line start and is outside the window's
          # scope entirely; see the write-up above ly_advance_close.
          if int(ppu.ly) == GB_HEIGHT:
            when LY_BLIND_SCOPE >= 2: ly_advance_vblank_entry(ppu, gb)
            else:                     ppu.`mode_flag=`(1'u8, gb)
            gb.interrupts.vblank_interrupt = true
            when defined(gb_phase_trace):
              echo "VBLIRQ ly=", ppu.ly, " t=", gb_phase, "/", gb_ticklen
            ppu.frame = true
            when defined(gb_dot_counter): inc gb_frame_normal
            ppu.dots_since_frame = 0
            ppu.current_window_line = -1
            if ppu.lcd_on_first_frame:
              # This frame was drawn but is not displayed — see
              # GbPpu.lcd_on_first_frame. ppu_blank_frame re-marks the same
              # present, so pacing is untouched.
              ppu.lcd_on_first_frame = false
              ppu_blank_frame(ppu, gb)
          else:
            when LY_BLIND_SCOPE >= 0: ly_advance_line(ppu, gb)
            else:                     ppu.`mode_flag=`(2'u8, gb)
      of 1:  # V-Blank
        # The one vblank line whose successor scans OAM is 153, handing over
        # to line 0 -- and the suite says line 0's pulse does NOT lead, so
        # m2_early answers false here unless STAT_M2_EARLY_LY0 is on. The stop
        # is spelled anyway, because that is the knob's whole point.
        when STAT_M2_EARLY:
          if m2_lead_active(gb) and ppu.cycle_counter == ppu.m2_early_dot(gb):
            fifo_m2_early_edge(ppu, gb)
        when STAT_IRQ_SPLIT:
          if ppu.cycle_counter == 456 - lead: fifo_irq_line_advance(ppu, gb)
        if ppu.cycle_counter == 456:
          ppu.cycle_counter = 0
          ppu.stat_chg_dot -= 456
          # Same window as the visible boundary above, with no mode change
          # inside it: vblank line to vblank line. Line 153's own advance to 0 is
          # not here -- fifo_line153_edge already ran it, with the wider
          # LYC_SETTLE_DOTS window it is measured to have -- and the `ly == 0`
          # branch is that snap's mode 1 -> 2, not an LY change.
          if ppu.ly == 0:
            when STAT_IRQ_SPLIT: ppu.irq_ly = ppu.ly
            ppu_handle_stat_interrupt(ppu, gb)
            ppu.`mode_flag=`(2'u8, gb)
          else:
            ppu.ly += 1
            ppu.read_mode = ppu.read_mode or LY_JUST_CHANGED
            when STAT_IRQ_SPLIT: ppu.irq_ly = ppu.ly
            when LY_BLIND_SCOPE >= 1: ly_advance_vblank(ppu, gb)
            else:                     ppu_handle_stat_interrupt(ppu, gb)
        when STAT_IRQ_SPLIT:
          # LY 153 snaps back to 0 partway through the line, and the LYC=0
          # source sees it a lead ahead of the readable LY -- one edge, two
          # clocks. The source is what gambatte lyc0int_* and lyc153int_* time;
          # the flag half below is what a STAT/LY read sees.
          #
          # A STAT_IRQ_LEAD build has NOT been re-derived against the settling
          # window below: `lyc_settling` is written in the flag domain, so in
          # this build the source would come out of the snap without one. The
          # shipping build is LEAD = 0, where this whole block is compiled out
          # and the snap below is the only edge; anyone reviving the axis has to
          # answer that question first.
          if ppu.ly == 153 and ppu.irq_ly == 153 and
             ppu.cycle_counter >= LY153_SNAP_DOT - lead:
            ppu.irq_ly = 0
            ppu_handle_stat_interrupt(ppu, gb)
        # The LY 153 -> 0 snapback and the comparator re-latch after it: see
        # fifo_line153_edge, which is where both live and why they are not
        # written out here. Same two compares this branch has always had -- the
        # field is still 153 through the window, which is also what holds the
        # idle jump above open across it.
        if ppu.cycle_counter >= LY153_SNAP_DOT and
           ppu.cycle_counter <= LYC_RELATCH_DOT:
          fifo_line153_edge(ppu, gb)
      else: discard
      ppu.cycle_counter += 1
  else:
    ppu.cycle_counter = 0
    ppu.`mode_flag=`(0'u8, gb)
    ppu.ly = 0
    when STAT_IRQ_SPLIT: ppu.irq_ly = 0
    ppu.stat_chg_dot = STAT_NO_HOLD
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
  #   * mode 1 below LYC_RELATCH_DOT -- LY 153 snaps back to 0 at
  #     LY153_SNAP_DOT and the LY=LYC comparator re-latches an M-cycle after
  #     it, and neither dot may be stepped over.
  # An LCD that is off also falls through -- that path re-asserts mode 0 and
  # drives the blank-frame clock every tick.
  if m != 3 and (ppu.lcd_control and 0x80'u8) != 0:
    let target = fifo_skip_target(ppu, gb, m)
    let next = ppu.cycle_counter + int32(cycles)
    # `<=` not `<`: landing exactly on the target is what the loop did too --
    # it consumed the whole span in one skip and left the transition for the
    # next entry, where cycle_counter == target fails `cycle_counter < target`.
    if next <= target and
       (m != 1 or ppu.cycle_counter > LYC_RELATCH_DOT):
      ppu.cycle_counter = next
      return
  fifo_tick_slow(ppu, gb, cycles)

method tick*(ppu: GbFifoPpu; gb: GB; cycles: int) =
  ## Polymorphic entry point. The hot path (mem_tick_components) calls
  ## fifo_tick directly through GB.fifo_ppu and never reaches this.
  fifo_tick(ppu, gb, cycles)
