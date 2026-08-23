# GB FIFO PPU renderer (included by gb.nim)

# -d:gb_px_trace prints one line per pipeline event (FTILE, FDATA, PUSH, SPR,
# PX) for the line -d:GB_TRACE_LY selects (-1 = every line); -d:gb_m3_trace
# prints one per mode 3 dot. Tools only; compiled out of shipping builds.

# Unreachable `lx` (it runs -7..160): parks the shifter's window compare.
const WIN_LX_OFF = -128'i32

# "No tail in flight": puts `cycle_counter - tail_dot0` far past the line end
# so every recompose span is empty (fifo_recompose_last).
const TAIL_DOT0_OFF = -(1'i32 shl 20)

const M3_AHEAD_HOLD* {.booldefine.} = true
  ## Hold the mode 3 -> 0 flag for the pipeline's advance so it lands on the
  ## dot it would with no advance (true, ships). `false` moves the flag with
  ## the pixels and shortens mode 3; refused by gambatte sprites, window and
  ## speedchange, which pin the flag edge.

const M3_GRID_EARLY* {.intdefine.} = 0
  ## CPU M-cycles the whole mode 2 -> 3 -> 0 dot grid (flags, STAT sources,
  ## OAM scan and pipeline together) runs ahead of LY, with mode 3's length
  ## untouched. 0 ships; 1 is refused by gambatte sprites, window and vram_m3,
  ## which pin both flag edges to the dot.

const M3_PIPE_AHEAD* {.intdefine.} = 1
  ## CPU M-cycles the mode 3 pipeline runs ahead of machine time on every
  ## device (CGB_PIPE_MCYCLES is added). 1 ships, pinned together with
  ## STAT_M2_LEAD (ppu.nim) by the gambatte scy, bgtiledata, bgtilemap and
  ## scx_during_m3 families; see the note above LY0_PIPE_ANY. Declared up here
  ## because obj_oam_dma_read sums it into the OAM DMA bus lead.

const CGB_PIPE_MCYCLES* {.intdefine.} = 0
  ## CGB-only extra M-cycles of the same advance. 0 ships: what looked like a
  ## device split was the DMG's mode-2 STAT source (STAT_M2_LEAD) and snapback
  ## halt wake (LYC_SETTLE_HALT_SKIP, gb.nim) each cancelling part of a
  ## device-independent advance. OBJ_DMA_BUS_LEAD and LY0_PIPE_MCYCLES are
  ## functions of this phase and move with it.

when defined(gb_px_trace):
  # Trace-only state for the FDATA candidate columns (one GB per harness).
  var px_prev_data: uint8
  var px_prev_uns:  uint8

proc mixer_note_stop(ppu: GbFifoPpu) {.inline.} =
  ## The shifter is about to stop on this dot: note the dot base of the run it
  ## interrupts and the `lx` the next run starts at. Never on the dot loop;
  ## see fifo_recompose_span.
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
    obj_abort_last: OBJ_ABORT_LAST_OFF,
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
  when defined(gb_win_trace):
    # Every write that can move the window comparator, with its four inputs.
    echo "ARM ly=", ppu.ly, " dot=", ppu.cycle_counter,
         " lcdc=", toHex(ppu.lcd_control, 2), " wx=", ppu.wx, " scx=", ppu.scx,
         " fw=", ppu.fetching_window, " lx=", ppu.lx
  when WIN_EN_REVOKE_ANY:
    # LCDC.5 went low while a CGB window start is still inside its restart:
    # schedule the undo CGB_WIN_REVOKE_LAG dots out (CGB_WIN_EN_DEFER, gb.nim).
    # Once only: WIN_EN_ABORT re-enters here on the fetcher's next map read.
    if ppu.win_defer > 0'u8 and not ppu.win_revoking and
       not window_enabled(ppu):
      ppu.win_revoking = true
      ppu.win_defer = uint8(CGB_WIN_REVOKE_LAG)
  # Re-derive the one `lx` the shifter watches for on this line. Called from
  # every write that can move an input and from fifo_reset_bg; never per dot.
  when DMG_WIN_LAST_PX_CARRY != 0:
    # LCDC.5 low deactivates the window; an owed start that reactivates it
    # costs the window line counter one more (WIN_CARRY_REACT_LINES).
    if not ppu.cgb and not window_enabled(ppu): ppu.win_carry_gap = true
  when WIN_EN_HOLD > 0:
    # A refused match owns the comparator until its hold runs out (WIN_EN_HOLD).
    if ppu.win_hold > 0'u8: return
  ppu.win_lx =
    if ppu.fetching_window:
      # Re-trigger edge: only reached while the window is the fetch source, and
      # nothing holds a re-trigger.
      if window_enabled(ppu): int32(ppu.wx) - 8 else: WIN_LX_OFF
    elif not window_enabled(ppu) and WIN_EN_HOLD == 0: WIN_LX_OFF
    elif ppu.window_trigger:
      # The comparator sits one slot LEFT of the shifter's first pixel: with
      # SCX & 7 = 0 the target WX - 7 = -1 (WX = 6) is below anything `lx`
      # takes, yet hardware fires it. mealybug m3_wx_6_change brackets it on
      # adjacent lines of one frame (WX - 7 = -2: no window; -1: whole-line
      # window), and its window line counter is one ahead of ours without
      # this. Spelled as a clamp here rather than a `>=` in the dot loop (one
      # extra branch there measured +1.7% of retired instructions; a `>=` would
      # also fire at WX = 4 and 5, which that ROM refuses). win_start_reset
      # reads the clamp back to put the tile at its true pixel. Not applied to
      # the re-trigger branch: no ROM measures it there.
      let target = int32(ppu.wx) - 7
      let first  = -int32(7 and int(ppu.scx))
      when WIN_START_PRE_PIXEL != 0:
        # The clamp is about the dot of the match; the tile still belongs at
        # `target` (WIN_PRE_PX_PHASE, win_start_reset).
        if target == first - 1: first else: target
      else:
        target
    else:                       WIN_LX_OFF

method reset_render_scratch*(ppu: GbFifoPpu) =
  ## Clear the FIFO/fetcher scratch to its pre-line state so a state load onto
  ## a running core cannot leave a runaway lx or stale FIFO contents. None of
  ## this is read at vblank (where states are captured) and all of it is reset
  ## again at the next mode 2 -> 3 edge.
  fifo_clear(ppu.fifo)
  fifo_clear(ppu.fifo_sprite)
  ppu.fetch_counter = 0
  ppu.fetcher_x = 0
  ppu.scx_fine = 0
  when SCX_FINE_LATCH_LIVE:
    ppu.scx_latch_until = -1'i32
    ppu.scx_live_fine = 0'i32
  when SCX_STORE_STALL_DOTS != 0:
    # Per-line: a stall armed at the end of one line must not hold the next.
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
  when WIN_EN_REVOKE_ANY:
    # Per-line: a start taken on one line must not be revoked on the next.
    ppu.win_defer = 0'u8
    ppu.win_revoking = false
  ppu.obj_penalty = 0
  ppu.obj_tile_fx = -1
  ppu.obj_fix_from = OBJ_FIX_OFF
  ppu.obj_abort_last = OBJ_ABORT_LAST_OFF
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
  # The mixer's held pairs are per-line scratch too: the earliest a loaded
  # state can reach fifo_recompose_last is the first pixel of the next mode 3,
  # which has already written them.
  ppu.mix = default(array[MIX_HOLD, GbMixHold])
  ppu.tail_dot0 = TAIL_DOT0_OFF
  ppu.sprites = @[]
  # The scan's progress goes with the list it fills.
  ppu.scan_next = 0
  ppu.scan_line = -1

const OAM_SCAN_DMA_HOLD* {.intdefine.} = 1
  ## A running OAM DMA's span is a bus HOLD on the mode-2 comparator: the scan
  ## keeps stepping and comparing but gets no new Y/X, so every entry inside
  ## the span is compared against the last Y/X the bus latched. 1 ships; 0 is
  ## the drop-the-entry control. Needs OAM_SCAN_DMA_LOCK. Pinned by gambatte
  ## oamdma/late_sp* together with strikethrough staying pixel-exact (a lock
  ## that drops entries loses that ROM's object 39 on LY 68).
const OAM_SCAN_DMA_LOCK* {.intdefine.} = 1
  ## An OAM DMA owns the OAM bus for its whole transfer and the mode-2 scan
  ## (one entry per two dots) reads nothing off it meanwhile. 1 ships; 0 is
  ## the one-burst scan with the transfer ignored. The transfer moves one
  ## entry per 16 dots (8 in double speed) against the scan's one per 2, which
  ## is why no constant start latency (CGB_OAM_DMA_START_T) could fix these
  ## rows. Pinned by gambatte oamdma/late_sp{00,01,02,39}{x,y}: sixteen
  ## one-M-cycle brackets putting object N's dot at 2N (OBJ_SCAN_DOT_ADJ).
  ## Open: the six late_sp*_ds_* rows read as object N at 2N + 2 in double
  ## speed, which late_sp02x refuses at single speed.

# The OAM scan compares each object's Y against LCDC.2 as it stands in that
# object's own two-dot slot (object N on dot 2N), since the CPU can move the
# bit under the scan. gambatte sprites/late_sizechange*_sp{00,01,02,39}
# brackets the DMG's sample dot into {2N - 1, 2N}. On CGB the same rows keep
# the object if EITHER that dot or the one M-cycle before it reads 8x16
# (CGB_OBJ_SCAN_LEAD, gb.nim): the bit arrives at the scan later on CGB.
const OAM_SCAN_DOTS = 80'i32
  ## Dots of mode 2. Also the discriminator for `lcdc2_flip`: an entry below it
  ## is one of this line's mode-2 writes, one at or above it belongs to the
  ## previous line and is already folded into lcd_control.
const OBJ_SCAN_DOT_ADJ* {.intdefine.} = 0'i32
  ## Dots to shift every object's scan sample by. 0 ships (object N on dot 2N);
  ## -1 is the other cell that gambatte sprites/late_sizechange* and
  ## oamdma/late_sp* both cannot separate from it.

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
  ## Did the scan's comparator keep object `s` on its own dot `d`? Shared by
  ## the LCDC.2 scan and oam_scan_advance so the CGB rule lives in one place.
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
  ## Did LCDC.2 move during this line's mode 2? `[1]` is older than `[0]`, so
  ## `[0]` alone decides it.
  ppu.lcdc2_flip[0] >= 0'i32 and ppu.lcdc2_flip[0] < OAM_SCAN_DOTS

proc fifo_scan_sprites_lcdc2(ppu: GbFifoPpu; gb: GB): seq[GbSprite] {.noinline.} =
  ## The scan with a per-object LCDC.2 sample. Not inlined: the fast scan runs
  ## on every rendered line and a mid-mode-2 LCDC.2 write is a test ROM.
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
  ## The scan as one burst on the dot mode 2 ends (the CPU cannot write OAM in
  ## mode 2, so where inside it each entry is read is unobservable). LCDC.2
  ## moving under the scan and an OAM DMA holding the bus each get their own
  ## body (fifo_scan_sprites_lcdc2, oam_scan_advance). Kept separate from
  ## oam_scan_advance, which it is equivalent to: routing this path through it
  ## costs +2.07% of retired instructions on dmg-acid2. Last reader of this
  ## line's LCDC.2 history, so it retires it; moving the call above
  ## fifo_reset_sprite instead costs +1.11% from code placement alone.
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

# An OAM DMA frozen by HALT (OAMDMA_HALT_PAUSE) stops mid-write with its
# address on OAM and WR asserted, so the OAM bus is DRIVEN with one word:
# every entry the mode-2 comparator steps over latches it, and the mode-3
# object fetch reads it too. The word is the destination word (address bit 0
# ignored) wired-OR with the held byte, the low two bits of the 16-bit word
# undriven -- mooneye madness/mgb_oam_dma_halt_sprites' own rule
# (Y = (existing | incoming) & $FC, X = next_existing | incoming), whose
# reference pins the mask pixel-exactly: its 18 dark pixels at x 83..88,
# y 42..47 are tile $38 at Y=$38/X=$5A with flags $5A, and the unmasked Y=$3A
# draws something else.
const OAMDMA_FREEZE_BUS* {.intdefine.} = 1
  ## Model the frozen transfer's held write as a driven OAM bus (1 ships; 0:
  ## a frozen transfer holds the bus like a running one). DMG family only: the
  ## ROM's own header says the CGB answer is a checkerboard with no object.
const OAMDMA_FREEZE_DEST_LEAD {.intdefine.} = 1
  ## M-cycles the frozen write's destination leads `dma_position` by. The
  ## freeze returns before that M-cycle's write, so the naive reading is 0;
  ## hardware is one further on (mooneye-test-suite issue #1 puts the
  ## in-flight write at $FE02 where dma_position is 1). 1 ships.

proc oam_dma_frozen*(gb: GB): bool {.inline.} =
  ## Is an OAM DMA frozen mid-write with its address and data on OAM? That is
  ## `dma_busy` with the CPU halted (OAMDMA_HALT_PAUSE). The console test is
  ## spelled out because memory.nim is included after this file.
  when OAMDMA_FREEZE_BUS == 0: false
  else:
    gb.memory.dma_busy and gb.cpu.halted and
      gb.boot_model notin {bmCgb0, bmCgbABCDE, bmAgb}

proc oam_dma_frozen_bus(ppu: GbFifoPpu; gb: GB): (uint8, uint8) {.noinline.} =
  ## The (even, odd) bytes on the OAM data bus while a transfer is frozen:
  ## (Y, X) to the mode-2 comparator and (tile, flags) to the mode-3 fetch.
  let mem = gb.memory
  var dst = mem.dma_position + OAMDMA_FREEZE_DEST_LEAD
  if dst > 0x9F: dst = 0x9F
  dst = dst and not 1
  var drv: uint8
  if mem.dma_openbus:
    drv = 0xFF'u8
  else:
    # The byte in flight is the source byte for the destination the write
    # stands on, not `dma_latch` (the last completed write). Same echo fold as
    # the unit (mooneye oam_dma/sources-GS).
    var src = int(mem.current_dma_source) + dst
    if src >= 0xE000: src = src and not 0x2000
    drv = read_byte(mem, gb, src)
  # One 16-bit word, even byte low, wired-OR, low two bits undriven.
  let w = (uint16(ppu.sprite_table[dst + 1]) shl 8) or uint16(ppu.sprite_table[dst])
  let v = (w or (uint16(drv) * 0x0101'u16)) and 0xFFFC'u16
  result = (uint8(v and 0xFF'u16), uint8(v shr 8))

proc oam_scan_advance*(ppu: GbFifoPpu; gb: GB; upto: int32; blocked = false) =
  ## Run the mode-2 scan forward through every entry whose dot is before
  ## `upto`, against OAM as it stands now; `blocked` means an OAM DMA owns the
  ## bus. Called on the dot a transfer takes OAM, the dot it gives it back and
  ## at the mode 2 -> 3 edge; between those dots neither input moves. Compiled
  ## in only with OAM_SCAN_DMA_LOCK; the shipping scan is fifo_get_sprites.
  if ppu.scan_line != int32(ppu.ly):
    # A fresh line: the partial result belongs to some earlier one.
    ppu.sprites.setLen(0)
    ppu.scan_next = 0
    ppu.scan_line = int32(ppu.ly)
  while ppu.scan_next < 40 and 2 * ppu.scan_next + OBJ_SCAN_DOT_ADJ < upto:
    let sprite_addr = int(ppu.scan_next) * 4
    let dot = 2 * ppu.scan_next + OBJ_SCAN_DOT_ADJ
    inc ppu.scan_next
    # Control arm: an entry read with the bus off the scan is not considered
    # (a Y of $FF would never be on the line either).
    when OAM_SCAN_DMA_HOLD == 0:
      if blocked: continue
      ppu.scan_y_bus = ppu.sprite_table[sprite_addr]
      ppu.scan_x_bus = ppu.sprite_table[sprite_addr + 1]
    else:
      # Bus hold: keep stepping and comparing with no new Y/X.
      if not blocked:
        ppu.scan_y_bus = ppu.sprite_table[sprite_addr]
        ppu.scan_x_bus = ppu.sprite_table[sprite_addr + 1]
      elif oam_dma_frozen(gb):
        # A frozen transfer drives the bus instead (OAMDMA_FREEZE_BUS).
        let (y, x) = oam_dma_frozen_bus(ppu, gb)
        ppu.scan_y_bus = y
        ppu.scan_x_bus = x
    let s = GbSprite(
      y:          ppu.scan_y_bus,
      x:          ppu.scan_x_bus,
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
        # Ten is the line's limit.
        ppu.scan_next = 40
  if upto >= OAM_SCAN_DOTS:
    # End of mode 2: last reader of the LCDC.2 history retires it.
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
  ## An OAM DMA has just taken OAM, or is about to give it back: walk an
  ## in-progress mode-2 scan up to this dot under the OLD state first.
  ## `cycle_counter` is the dot the M-cycle carrying the edge starts on (the
  ## bus half of an M-cycle runs before its PPU dots).
  if ppu.mode_flag == 2:
    oam_scan_advance(ppu, gb, ppu.cycle_counter, blocked = not taking)

const SCX_FINE_BORROW* {.intdefine.} = 1
  ## Tiles the BG fetcher's map column drops when a mid-line SCX write lowers
  ## SCX & 7 below the fine scroll the line latched. The fetcher is addressed
  ## by screen position plus the live SCX, `column = ((SCX + 8k - F) shr 3)
  ## and 31`, so lowering the low bits mid-line borrows one tile for the rest
  ## of the line while the emitted residue stays the old one. 1 ships; 0 is
  ## the control. Derived from gambatte scx_during_m3 read as a displacement
  ## ruler (tools/gbscx): every failing span follows a write that lowers
  ## SCX & 7 and is displaced by exactly 8, never 1..7. Not applied to the
  ## window fetch, which has no SCX term. An `ord` term, not an `if`: this is
  ## the mode 3 dot loop.

# SCX_LIVE_BORROW_LATCHED (gb.nim): the borrow above is measured against the
# fine scroll the LINE latched (`scx_fine`), not the running discard target
# SCX_FINE_LATCH_LIVE moves (`scx_live_fine`). With one shared field a store
# inside the discard moved the borrow's reference and it could never fire
# again on that line; gambatte scx_0360c0 and scx_0761c0 measure both halves.
# Open: scx_0761c0's CGB arm wants the borrow's reference to MOVE between the
# $61 and $C0 stores (tile 11, then 24) where the DMG's does not -- the shape
# of a CGB write latency (CGB_SCX_LATENCY, gb.nim), not of this carry; making
# the CGB wrap like the DMG (`want <= consumed` in SCX_FINE_LATCH_WRAP) does
# not reach it.

const SCX_FINE_BORROW_DMG_LEAD* {.intdefine.} = 1
  ## Pixels the DMG fetcher's position leads the CGB's by inside the borrow
  ## compare. Bracketed both sides by gambatte scx{1,2}_scx{0,1}_during_m3_1,
  ## the only rows that move SCX's low bits alone: the DMG borrows on a drop
  ## of 2 but not of 1, the CGB on either. Subtracted into `scx_fine` at the
  ## latch so the dot loop never sees it.

# SCX_FINE_LATCH_LIVE (gb.nim): a store to SCX joins the fine-scroll discard
# for as long as the discard has pixels left, moving the line's fine scroll
# and its length with it (true ships). The window is the discard's own
# length, not a fixed number of dots: gambatte scx_during_m3's dot-89 store
# is refused at F = 0 (scx_0063c0) and taken at F = 3 and 7 (scx_0367c0,
# scx_0360c0, scx_0761c0); a capped `min(N, F)` saturates only at N = 7.
# Costs enable_display/ly0_late_scx7_m3stat_scx1_2 [dmg], a line-0 row (line
# 0's latch is dot 84, not 88); widening the window on line 0 alone loses
# eleven scx_during_m3 rows, so that row is left red.

# SCX_FINE_LATCH_WRAP (gb.nim): the discard is a three-bit SLOT COUNTER that
# compares its slot against the live SCX & 7 every dot. A store that puts the
# target below the slot already reached cannot match on this pass, so the
# counter runs to 7, wraps and matches on the next: eight more dots. gambatte
# scx_m3_extend brackets it -- its _ds pair writes SCX twelve times on one
# line (4,2,0,6,... against a latched 7) and wants mode 3 71-72 dots longer,
# which nine wraps give. Open: scx_m3_extend_1 [dmg] wants its edge 3-6 dots
# later still, a sub-M-cycle question about where the DMG's store lands.

proc fifo_arm_scx*(ppu: GbFifoPpu) =
  ## Recompute the fetcher's SCX term. Called from ppu_store_scx and from the
  ## fine-scroll latch, the only two events that change an input.
  when SCX_FINE_LATCH_LIVE:
    # The discard still has pixels to throw away, so this store joins it: the
    # fine scroll moves, `lx` moves by the difference, mode 3 with it.
    if ppu.scx_latch_until >= 0'i32 and ppu.cycle_counter <= ppu.scx_latch_until:
      let want = int(ppu.scx and 7) -
                 (if ppu.cgb: 0 else: SCX_FINE_BORROW_DMG_LEAD)
      var extra = 0'i32
      when SCX_FINE_LATCH_WRAP != 0:
        # Slot counter: `consumed` slots of this pass are gone and a target
        # below them wraps. `and 7` because every pass is eight slots; without
        # it every later store wraps and mode 3 never ends (the _ds banging
        # row reads 355 against hardware's 331).
        let consumed = (ppu.cycle_counter - int32(ppu.scx_latch_slot)) and 7'i32
        # `want` carries the DMG's one-pixel lead, as SCX_FINE_BORROW's compare
        # does (the DMG arm of scx_m3_extend needs it).
        if int32(want) < consumed:
          extra = SCX_FINE_LATCH_WRAP
          ppu.scx_latch_until += SCX_FINE_LATCH_WRAP
      # The running discard target, not the borrow's reference
      # (SCX_LIVE_BORROW_LATCHED).
      when SCX_LIVE_BORROW_LATCHED:
        ppu.lx -= int32(want - int(ppu.scx_live_fine)) + extra
        ppu.scx_live_fine = int32(want)
      else:
        ppu.lx -= int32(want - ppu.scx_fine) + extra
        ppu.scx_fine = want
  ppu.scx_tile = (int(ppu.scx) shr 3) -
                 SCX_FINE_BORROW * ord((int(ppu.scx) and 7) < ppu.scx_fine)

# SCX_STORE_STALL_DOTS (gb.nim, ships 0): a mid-line SCX store that lowers
# SCX & 7 stalls fetcher and shifter for one BG fetch. Content-identical to
# SCX_FINE_BORROW's displacement (the same tile, charged as dots rather than
# as a column), so the two must not both be on. gambatte scx_m3_extend's _ds
# pair prices one store at 8 dots on both devices.
proc fifo_scx_store_stall*(ppu: GbFifoPpu; old_scx: uint8) =
  when SCX_STORE_STALL_DOTS != 0:
    if ppu.mode_flag == 3'u8 and ppu.smooth_scroll_sampled and
       (int(ppu.scx) and 7) < (int(old_scx) and 7):
      ppu.scx_stall += SCX_STORE_STALL_DOTS

proc fifo_sample_smooth_scroll*(ppu: GbFifoPpu) =
  when defined(gb_m3_trace):
    echo "LATCH ly=", ppu.ly, " dot=", ppu.cycle_counter, " scx=", ppu.scx
  when defined(gb_px_trace):
    # One VRAM dump per frame for offline decoding.
    if ppu.ly == 0:
      for b in 0 .. 1:
        var s = newStringOfCap(2 * ppu.vram[b].len + 8)
        for v in ppu.vram[b]: s.add toHex(v, 2)
        echo "VRAM", b, " ", s
  ppu.smooth_scroll_sampled = true
  # The fine scroll the line started with, less the DMG's one-pixel lead
  # (SCX_FINE_BORROW_DMG_LEAD), kept as a number for the fetcher's map column.
  ppu.scx_fine = int(ppu.scx and 7) -
                 (if ppu.cgb: 0 else: SCX_FINE_BORROW_DMG_LEAD)
  when SCX_FINE_LATCH_LIVE and SCX_LIVE_BORROW_LATCHED:
    # Second copy: this one follows the discard (SCX_LIVE_BORROW_LATCHED).
    ppu.scx_live_fine = int32(ppu.scx_fine)
  fifo_arm_scx(ppu)
  when SCX_FINE_LATCH_LIVE:
    # The window is the discard's own length, in raw SCX & 7 (a count, not a
    # threshold). Not read off `lx`: the head's throw-away fetch parks the
    # shifter, so `lx` stays negative long after the discard is spent.
    ppu.scx_latch_until = ppu.cycle_counter + int32(ppu.scx and 7)
    when SCX_FINE_LATCH_WRAP != 0:
      ppu.scx_latch_slot = uint8(ppu.cycle_counter and 7'i32)
  if ppu.fetching_window:
    # A line that starts as a window line discards `7 - WX` for the window's
    # fine scroll AND `SCX & 7`: mealybug m3_window_timing_wx_0 (WX = 0,
    # SCX = LY, BGP driven black at a fixed dot) reads 11,9,8,7,6,5,4,3 across
    # SCX & 7 = 0..7, and its header names both terms. Cross-checked by
    # gambatte window/m2int_wx03_scx5_m3stat_1 and GBMicrotest win0_scx3_a/_b.
    # The discard is `7 - WX` at WX = 0 too (WIN_WX0_PHASE, gb.nim): six puts
    # the window's first tile one pixel right, visible only in mealybug
    # m3_lcdc_win_en_change_multiple_wx.
    ppu.lx = int32(-max(0, 7 - int(ppu.wx))) - int32(7 and int(ppu.scx))
    when WIN_WX0_PHASE == 0:
      if ppu.wx == 0:
        ppu.lx += 1
        if (ppu.scx and 7) > 0: ppu.lx -= 1
    else:
      # WX = 0's startup fetch is one dot shorter ("window activating one
      # T-cycle later when WX = 0 and SCX > 0", m3_window_timing_wx_0's
      # header), spent out of the fetch's sleep step so the map read and the
      # SCX latch riding on it (mealybug m3_scx_low_3_bits) do not move. Spent
      # here, the dot SCX is latched on, because two dots earlier at the head
      # SCX is still the previous line's. An add, not a branch (+0.03%).
      ppu.fetch_counter += ord(ppu.wx == 0'u8 and (ppu.scx and 7) == 0'u8)
  else:
    ppu.lx = int32(-(7 and int(ppu.scx)))

# -d:gb_win_trace: one line per WY/WX/LCDC write, window start and mode 3 end.
proc fifo_reset_bg*(ppu: GbFifoPpu; fetching_window: bool) =
  when defined(gb_win_trace):
    if fetching_window:
      echo "WINSTART ly=", ppu.ly, " dot=", ppu.cycle_counter, " lx=", ppu.lx,
           " wx=", ppu.wx, " scx=", ppu.scx
  fifo_clear(ppu.fifo)
  # A stop like an object fetch is (mixer_note_stop).
  mixer_note_stop(ppu)
  ppu.fetcher_x = 0
  # A `when`, so the shipping build (both knobs 0) keeps the single store.
  when WIN_RESTART_COUNTER == 0 and CGB_WIN_RESTART_COUNTER == 0:
    ppu.fetch_counter = 0
  else:
    ppu.fetch_counter =
      if not fetching_window: 0
      elif ppu.cgb: int32(CGB_WIN_RESTART_COUNTER)
      else: int32(WIN_RESTART_COUNTER)
  # A restart is never the head cycle: a window start's own six-dot fetch
  # takes the early push (mealybug m3_window_timing).
  ppu.head_cycle = false
  ppu.fetching_window = fetching_window
  # The tile the last object wait was charged to is gone with the restart;
  # fetcher_x restarting at 0 would otherwise alias the BG's first tile.
  ppu.obj_tile_fx = -1
  if fetching_window: inc ppu.current_window_line
  when WIN_EN_HOLD > 0: ppu.win_hold = 0'u8
  fifo_arm_window(ppu)

proc win_start_reset(ppu: GbFifoPpu) {.inline.} =
  ## A window START served by the shifter's equality, including the match on
  ## the comparator's pre-pixel slot (WX = 6, SCX & 7 = 0): win_lx was clamped
  ## up to the shifter's first pixel so the match is noticed at all, but the
  ## tile belongs at WX - 7, so step the shifter back onto it (off-screen) and
  ## enter FETCHER_ORDER at the map read -- six dots, no extra pixel, so mode
  ## 3's length is unchanged. The clamp is read back off `lx` rather than
  ## stored (a store on every register write measured +0.07%). A held match
  ## is excluded: WIN_EN_HOLD_BACK has already moved its `lx`.
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
  # The object fetch's LCDC.2 read is per-line (obj_height_at).
  ppu.obj_fix_from = OBJ_FIX_OFF
  # `lcdc2_flip` is NOT cleared here: the OAM scan reads it a few statements
  # later on this dot and retires it (fifo_get_sprites). LCDC.4's dot is
  # per-line too; its ADDRESS latch is a bus register and survives
  # (CGB_TDSEL_GLITCH, gb.nim).
  ppu.tdsel_dot = NO_TDSEL_CHANGE
  # LCDC.3 / LCDC.6 likewise (CGB_MAP_LATENCY, gb.nim).
  when CGB_MAP_ANY: ppu.map_dot = NO_MAP_CHANGE
  when CGB_TDSEL_IDX_DOTS > 0:
    if ppu.tdsel_addr > 0:
      ppu.tdsel_addr = ppu.tdsel_addr and ((1'i32 shl TDSEL_IDX_SHIFT) - 1)

proc try_push_bg_pixels(ppu: GbFifoPpu; gb: GB): bool =
  ## Attempt to push 8 pixels to the BG FIFO. Returns true if successful.
  if ppu.fifo.size == 0:
    # LCDC.0 is read at the mixer per pixel (BG_EN_AT_MIX, gb.nim; mealybug
    # m3_lcdc_bg_en_change), not here per tile. Control arm below.
    when BG_EN_AT_MIX == 0:
      # In CGB mode LCDC.0 is master priority and the layer is drawn either
      # way (Pan Docs, LCDC.0); gambatte m2int_m3stat/nobg/*_cgb04c are DMG
      # carts on a CGB and read the compatibility meaning.
      let bg_en = bg_display(ppu) or gb.cgb_native
    inc ppu.fetcher_x
    # The FIFO is empty, so rewinding head/tail to 0 makes the eight pushes
    # contiguous stores with no wrap mask.
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

# A line whose WX < WIN_LINE_START_WX starts as a window line from its first
# tile. mealybug m3_window_timing (WX = LY, BGP black at a fixed dot) reads a
# flat 3 across WX = 0..10 and 4..9 across 11..16, and pins two things:
#  * WIN_LINE_START_LATCH: WX is read at the end of the throw-away fetch (dot
#    86; 82 on LY 0), after that ROM's dot-85 write and before
#    m3_wx_6_change's dot-93 one.
#  * WIN_HEAD_ABSORB: the window's own `7 - WX` discard costs no dots -- the
#    head is the same six-dot startup fetch at every WX in 0..6, spelled as
#    `WX - 1` idle dots (FETCHER_ORDER's negative steps). Seeding lx at a flat
#    -6 instead collapses m3_wx_4/5_change and m3_window_timing_wx_0. Length
#    cross-checks: GBMicrotest win<WX>_a/_b and gambatte window/m2int_wx03_*.
proc fifo_head_window(ppu: GbFifoPpu) =
  ## The head of mode 3 reading WX: does this line start as a window line, and
  ## how many of the startup fetch's six dots are left once its discard has
  ## taken its share. Once per line, from the dot the throw-away fetch ends.
  when DMG_WIN_LAST_PX_CARRY != 0:
    # A start owed from the previous line (DMG_WIN_LAST_PX_CARRY), asked first
    # because it is not a WX match. gambatte wxA6_late_we_reenable_1..4
    # bracket its dot to this one (LCDC.5 back on at dots 77/81/85 taken, 89
    # not). LCDC.5 clear does not cancel it, only defers spending it.
    if ppu.win_carry and window_enabled(ppu):
      ppu.win_carry = false
      ppu.fetching_window = true
      # Nothing else of fifo_reset_bg to repeat; fetcher_x is NOT reset.
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
      # fifo_reset_bg's window half without the reset (nothing has pushed).
      ppu.fetching_window = true
      inc ppu.current_window_line
      fifo_arm_window(ppu)
  when defined(gb_m3_trace):
    if gb_traced(ppu.ly):
      echo "HEAD ly=", ppu.ly, " dot=", ppu.cycle_counter, " wx=", ppu.wx,
           " scx=", ppu.scx, " fw=", ppu.fetching_window
  when WIN_HEAD_ABSORB != 0:
    if ppu.fetching_window:
      # `WX - 1` idle dots, clamped at 0; WX = 0's missing dot is spent at the
      # SCX latch instead (WIN_WX0_PHASE, fifo_sample_smooth_scroll).
      ppu.fetch_counter = -int(max(0, int32(ppu.wx) - 1))

# M3_THROWAWAY_DOTS (gb.nim): the discarded head fetch is `B0`, four dots,
# and the first real cycle runs to its own push slot (12 dots together).
# mealybug m3_scy_change separates 4 from 6: the first tile's B read must take
# the SCY written at dot 81 and its bitplanes the one written at 89, which
# puts B on dot 88 (n = 4), not 90. That also makes m3_scx_low_3_bits' header
# literal: SCX is latched "at the start of the B of the first B01s cycle".
proc tick_bg_fetcher*(ppu: GbFifoPpu; gb: GB) =
  case FETCHER_ORDER[ppu.fetch_counter]
  of fsGetTile:
    when M3_THROWAWAY_DOTS == 4:
      # The B of the first B01s cycle: latch SCX before the map offset reads it.
      if ppu.head_cycle and not ppu.smooth_scroll_sampled:
        fifo_sample_smooth_scroll(ppu)
    # A CGB window start is revocable (CGB_WIN_EN_DEFER, gb.nim): LCDC.5 going
    # low during the six-dot startup fetch abandons the start and the line
    # pays only the dots the fetch had run. A gambatte late_disable* row's
    # geometry is three dots (WX match, LCDC.5 write, STAT read); only a pair
    # at the same match and write dots with different read dots brackets
    # mode 3's length.
    when WIN_EN_ABORT != 0:
      # LCDC.5 cleared while the window is the fetch source: the switch takes
      # effect at this, the next map read (mealybug PPU notes: "at the end of
      # the current window tile"); the BG column is taken from the screen
      # position this fetch lands at and the fine scroll is not re-paid.
      if ppu.fetching_window and not window_enabled(ppu):
        ppu.fetching_window = false
        ppu.fetcher_x = int((ppu.lx + int32(ppu.fifo.size)) div 8)
        fifo_arm_window(ppu)
        when WIN_EN_HOLD > 0:
          # `lx` has not moved since the start this undoes; re-arming WX - 7
          # on it would fire the start again on the same slot.
          if ppu.win_lx == ppu.lx: ppu.win_lx = WIN_LX_OFF
    # The map-select bits as they stood CGB_MAP_LATENCY dots ago on a CGB
    # (gb.nim; the DMG is pixel-exact on both mealybug m3_lcdc_*_map_change).
    var map_bits = ppu.lcd_control and 0x48'u8
    when CGB_MAP_ANY:
      if unlikely(ppu.cycle_counter < ppu.map_dot): map_bits = ppu.map_old
    let (map, offset) =
      if ppu.fetching_window:
        # Masked like the BG fetch: The Fish Files ran fetcher_x off VRAM.
        let m = if (map_bits and 0x40'u8) == 0: 0x1800 else: 0x1C00
        let o = (ppu.fetcher_x and 0x1F) +
                ((((ppu.current_window_line shr 3) * 32)) and 0x3FF)
        (m, o)
      else:
        let m = if (map_bits and 0x08'u8) == 0: 0x1800 else: 0x1C00
        # Latched unconditionally: gating the store on scy_fetch_latch costs
        # more than the store (+0.56% on cgb-acid-hell). Only the read is gated.
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
    # Unconditional (a branch here measured +0.8%); outside CGB mode VBK is
    # not mapped, so bank 1 is never written and the attribute plane stays 0.
    ppu.tile_attrs = ppu.vram[1][map + offset]
    inc ppu.fetch_counter

  of fsGetTileDataLow, fsGetTileDataHigh:
    # `sel` is LCDC.4 as it stood CGB_TDSEL_LATENCY dots ago on a CGB (gb.nim;
    # the DMG is pixel-exact on both mealybug m3_lcdc_tile_sel_*); `glitch` is
    # set on the one dot the change lands on a read (CGB_TDSEL_GLITCH).
    var sel = bg_window_tile_data(ppu) != 0
    var glitch = 0
    when CGB_TDSEL_ANY:
      # `tdsel_dot` is the dot the change goes live on (latency paid at the
      # write, where the speed is known). A compare, so NO_TDSEL_CHANGE can be
      # int32.low.
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
          # RESET on the read dot: the tile index is the byte, and the $8000
          # address the read drove is what the next SET-glitched read returns.
          data = ppu.tile_num
          # ...and arms the index path for CGB_TDSEL_IDX_DOTS, packed above the
          # bank in the same store (TDSEL_IDX_SHIFT, gb.nim) as the first dot
          # past the window, so 0 means "not armed".
          ppu.tdsel_addr = int32((16 * int(ppu.tile_num) + tile_row * 2 +
                                  (if low_plane: 0 else: 1)) or
                                 (bank_num shl TDSEL_ADDR_BANK) or
                                 (when CGB_TDSEL_IDX_DOTS > 0:
                                    (int(ppu.cycle_counter) +
                                     CGB_TDSEL_IDX_DOTS + 1) shl TDSEL_IDX_SHIFT
                                  else: 0))
        elif CGB_TDSEL_IDX_DOTS > 0 and
             (ppu.tdsel_addr shr TDSEL_IDX_SHIFT) > ppu.cycle_counter:
          # SET on the read dot with the index path armed: it answers first,
          # with THIS tile's index (only cgb-acid-hell reaches here; see
          # CGB_TDSEL_IDX_DOTS in gb.nim). TDSEL_ADDR_OFF stays negative under
          # the arithmetic shift, so the sentinel cannot arm anything.
          data = ppu.tile_num
        elif ppu.tdsel_addr != TDSEL_ADDR_OFF:
          # SET on the read dot: the address never advanced, so the byte comes
          # from wherever the last $8000-region read left it.
          data = ppu.vram[(ppu.tdsel_addr shr TDSEL_ADDR_BANK) and 1][
                          ppu.tdsel_addr and ((1 shl TDSEL_ADDR_BANK) - 1)]
      elif sel:
        # An unglitched LCDC.4 = 1 read leaves its address here too (mealybug
        # m3_lcdc_tile_sel_change and its window twin separate this from the
        # objects-only form). One store, bank packed in: every unsigned read.
        ppu.tdsel_addr = int32(off or (bank_num shl TDSEL_ADDR_BANK))
    when defined(gb_px_trace):
      if gb_traced(ppu.ly):
        # Every candidate byte this read could have delivered (uns/sgn: the two
        # addressing modes; latch: the address-latch byte; prevd/prevu: the
        # previous bitplane / $8000-region read).
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
             # The dot the latest LCDC.4 change went live on.
             " chg=", (when CGB_TDSEL_ANY: $ppu.tdsel_dot else: "-2147483648")
        px_prev_data = data
        if sel: px_prev_uns = data
    if low_plane:
      ppu.tile_data_low = data
      inc ppu.fetch_counter
      when M3_THROWAWAY_DOTS == 4:
        # The discarded head fetch `B0` ends here (M3_THROWAWAY_DOTS); the
        # fine scroll is latched at the next cycle's B, not here.
        if not ppu.dropped_first_fetch:
          ppu.dropped_first_fetch = true
          ppu.head_cycle = true
          ppu.fetch_counter = 0
          fifo_head_window(ppu)
    else:
      ppu.tile_data_high = data
      inc ppu.fetch_counter
      when M3_THROWAWAY_DOTS == 4:
        # The push lands on the dot the data arrives and the next fetch starts
        # on the next dot (Pan Docs: step 4 -> step 1 on a push); falling
        # through Sleep/Push instead left every later VRAM read two dots late.
        # The line's first B01s cycle waits for its own push step (that push is
        # what makes the head 12 dots).
        if not ppu.head_cycle and try_push_bg_pixels(ppu, gb):
          ppu.fetch_counter = 0
      else:
        if not ppu.dropped_first_fetch:
          ppu.dropped_first_fetch = true
          ppu.fetch_counter = 0
          fifo_head_window(ppu)
          # Control arm: SCX latched when the throw-away fetch completes
          # (mealybug m3_scx_low_3_bits brackets the latch to one M-cycle).
          if not ppu.smooth_scroll_sampled: fifo_sample_smooth_scroll(ppu)
        elif try_push_bg_pixels(ppu, gb):
          # The first push is immediate (6 + 6 + 160 = 172).
          ppu.fetch_counter = 0

  of fsPushPixel:
    # The only wrap of the counter. Not an `and 7` on the way out: that would
    # fold the window head's negative steps (WIN_HEAD_ABSORB) into positive
    # ones.
    if try_push_bg_pixels(ppu, gb):
      when M3_THROWAWAY_DOTS == 4: ppu.head_cycle = false
      ppu.fetch_counter = 0

  of fsSleep:
    inc ppu.fetch_counter

# The OBJ penalty (Pan Docs, "OBJ penalty algorithm"): for the tile The Pixel
# (the object's leftmost column) is in, if no previous object considered it,
# pay that tile's pixels strictly right of The Pixel minus 2 (floored at 0),
# then a flat 6 for the object fetch. Here the BG FIFO holds exactly The Pixel
# and everything right of it, so the wait is `fifo.size - 1 - 2`, and
# "considered" is `fetcher_x` differing from the tile the last wait was
# charged to. (6, 3) is the unique optimum of a sweep over gambatte/sprites,
# and GBMicrotest ppu_spritex_vs_scx's 153 cells all match
# (tools/gbppu/objtab.py): `6 + max(0, 5 - ((X + SCX) mod 8))` for X >= 1 and
# Pan Docs' flat 11 at X = 0, a real special case. Cancelling the fetch by
# clearing LCDC.1 is a separate rule (fifo_obj_abort).
const OBJ_FETCH_DOTS {.intdefine.} = 6'i32
const OBJ_WAIT_SUB {.intdefine.} = 3'i32

# An object at OAM X = 167 triggers on lx = 159, past the retire point, and
# the dots the shifter walks into the tail burst to reach it were already
# paid at the head (m3_delay): refund them, once a line (gated on
# obj_last_px). wilbertpol acceptance/gpu/intr_2_mode0_timing_sprites_scx1_nops
# test $55 and tools/gbppu/objtab2.py (X = 150..167, every SCX) pin it. The
# window's walk into the tail is NOT refunded (CGB_WIN_TAIL_LAST,
# DMG_WIN_LAST_PX_CARRY). The CGB's WX = 166 + X = 167 shared slot stays one
# dot short either way (window/m2int_wxA6_spxA7_m3stat_{2,4} [cgb]); both
# spellings of giving it its dot back trade the same rows and are net zero.
const OBJ_TAIL_WALK_REFUND {.intdefine.} = 1

# LCDC.2 is read once per bitplane, OBJ_PLANE_GAP dots apart. mealybug
# m3_lcdc_obj_size_change and _scx (tile $4C, one object per band, LCDC.2
# pulsed four times across mode 3) decode to: low plane on the merge dot M,
# high plane on M + 2, on the tail arm; both planes before dot 101 on the
# idx < 0 head arm, whose six dots are the FIRST of the penalty (X = 8 is the
# first object that takes the tail arm's dots). The CGB reads the bit three
# dots later on six bands (CGB_OBJ_SIZE_LATENCY, gb.nim). The tile index's
# low-bit mask is recomputed per plane; no ROM separates that from a mask at
# the OAM read. A chained same-X object takes the tail arm's offset.
const OBJ_PLANE_GAP {.intdefine.} = 2'i32
  ## Dots between an object fetch's two bitplane reads (one VRAM access each).
const OBJ_PLANE1_LAG {.intdefine.} = 2'i32
  ## Dots after the merge dot at which the high plane samples LCDC.2 on the
  ## `idx >= 0` arm; the low plane's is OBJ_PLANE_GAP earlier. 2 ships
  ## (mealybug m3_lcdc_obj_size_change, strict optimum).
const OBJ_PLANE1_HEAD {.intdefine.} = 6'i32
  ## The same read on the `idx < 0` arm, in dots after the trigger (the fetch
  ## sits at the head of the penalty there). 6 is the structural value; the
  ## ROMs only bound it from above.

# Hardware re-reads an object's tile and attributes from OAM at its mode-3
# fetch; while an OAM DMA owns OAM that read gets the byte the unit has on its
# bus (Pan Docs, "OAM DMA Transfer", says only that the PPU cannot read OAM
# properly). Hacktix's strikethrough.gb pins which byte: forty objects, a
# transfer spanning LY 68 whose source is $01 everywhere but one $00, and
# hardware draws exactly one bar (object 7, screen x 71). The read lands one
# M-cycle AHEAD of the fetch's own dots. Moving the DMA's start instead costs
# sixteen mooneye oam_dma rows; the read is not inside the fetch (swept all
# six dots and out to eleven). scanline_ppu draws a whole line at once and
# cannot model this.
const OBJ_DMA_BUS_LEAD {.intdefine.} = 1
  ## M-cycles the object fetch's OAM read leads the DMA unit's bus by on a
  ## console whose pipeline is not advanced (0 = the byte the unit drives on
  ## the fetch's own M-cycle, mem.dma_latch). The effective lead adds every
  ## pipeline advance, since the unit runs on machine time. strikethrough pins
  ## 1 on DMG and the sum on CGB by the same 7 pixels.

proc obj_oam_dma_read(ppu: GbFifoPpu; gb: GB) {.noinline.} =
  ## The object's mode-3 OAM read while an OAM DMA owns OAM. Cold.
  let mem = gb.memory
  if oam_dma_frozen(gb):
    # A frozen transfer drives the destination word (OAMDMA_FREEZE_BUS).
    let (tile, flags) = oam_dma_frozen_bus(ppu, gb)
    ppu.sprites[0].tile_num   = tile
    ppu.sprites[0].attributes = flags
    return
  var b: uint8
  if mem.dma_openbus:
    b = 0xFF'u8
  else:
    # `dma_position` is the byte the unit moves NEXT; the unit drives nothing
    # past $A0. The lead moves with every pipeline advance (M3_PIPE_AHEAD,
    # CGB_PIPE_MCYCLES, CGB_HALT_PPU_LEAD): the unit is on machine time, so an
    # advanced fetch must look further ahead to land on the same source byte.
    # Both strikethrough frames witness the SUM, not the phase.
    let lead = OBJ_DMA_BUS_LEAD + M3_PIPE_AHEAD +
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
  ## Merge one object's eight pixels into the sprite FIFO from its two
  ## bitplane bytes; fifo_obj_size_write redoes it against another high plane.
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
  # The object's own OAM read lands on this dot.
  if gb.memory.dma_busy: obj_oam_dma_read(ppu, gb)
  when OAM_SCAN_DMA_HOLD != 0:
    # The tile byte crosses the OAM data bus the mode-2 comparator latches
    # from, so the next line's held Y is a tile number (OAM_SCAN_DMA_HOLD).
    ppu.scan_y_bus = ppu.sprites[0].tile_num
  let s = ppu.sprites[0]
  ppu.sprites.delete(0)
  # LCDC.2 per bitplane (OBJ_PLANE1_LAG): the low plane's dot is past; the
  # high plane's may still be ahead, and then the write path redoes it
  # (fifo_obj_size_write). Fast arm when the bit did not move in between:
  # computing both unconditionally costs +0.09% on dmg-acid2.
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
    # An object fetch's last read is plane 1 in the $8000 region, which a
    # following SET-glitched BG read reports (CGB_TDSEL_GLITCH, gb.nim).
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
  # If the high plane's read is still ahead, keep what a redo needs.
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
    # A second object at the same X shares the tile and pays only another
    # six-dot fetch (mooneye acceptance/ppu/intr_2_mode0_timing_sprites steps
    # by exactly 6 per extra object at X = 0).
    ppu.obj_penalty = OBJ_FETCH_DOTS
    when OBJ_ABORT_LATE:
      # Its six dots are its stall: a tail-arm object for the late abort.
      ppu.obj_abort_last = ppu.cycle_counter + OBJ_FETCH_DOTS - 1
    # Its high plane sits at the tail arm's offset whichever arm came first.
    ppu.obj_hi_dot = ppu.cycle_counter + OBJ_FETCH_DOTS + OBJ_PLANE1_LAG -
      (if gb.cgb_enabled: int32(CGB_OBJ_SIZE_LATENCY) else: 0'i32)

proc tick_sprite_fetcher*(ppu: GbFifoPpu; gb: GB): bool =
  ## One dot of an object fetch. True if the dot was the object's (the shifter
  ## is stopped), false for the one tail dot the shifter has back but the BG
  ## fetcher does not (OBJ_BG_RUN = 4). A return value rather than a call to
  ## tick_shifter: a second call site stops clang inlining it into
  ## fifo_pipeline_dot (+0.9% on Pokemon Blue).
  #
  # The BG fetcher runs for the WAIT and is stopped for the object's own six
  # dots (one address bus). OBJ_BG_RUN = 4: the object fetch goes at a tile
  # boundary chosen by the OBJECT, not the fetcher's phase -- mealybug
  # m3_lcdc_tile_sel_change's 18 bands show a BG tile's reads are never split
  # by an object fetch, and X = 0 and X = 8 trigger in identical fetcher
  # states yet take different boundaries. idx >= 0: The Pixel is in the
  # displayed tile; the fetch of the next one runs to completion inside the
  # penalty and parks. idx < 0 (OAM X < 8): the fetch it waits for finished on
  # the trigger dot, so the object owns the bus from the next dot for the
  # whole penalty plus one tail dot (band 4 separates the two). Mode 3's
  # length does not move (GBMicrotest ppu_spritex_vs_scx stays 0/153). Arms
  # 0..3 are control spellings a quarter of a percent apart on mealybug
  # pixels; 2 puts both fetches on the bus at once. Cost: up to six
  # tick_bg_fetcher calls per object (+0.76% Pokemon Blue).
  when OBJ_BG_RUN == 4:
    let bg_hold = ppu.obj_tile_fx != int32(ppu.fetcher_x)
    if ppu.obj_penalty <= 0:
      # The tail dot: the shifter has it back, the fetcher does not.
      ppu.fetching_sprite = false
      return false
    # 7 is the park (a stopped shifter never empties the FIFO, so the finished
    # fetch cannot push); skipping the call there is worth 0.3%.
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
    # The tile row lands on the last dot of the fetch (the dot gambatte
    # late_sizechange brackets).
    sprite_fetch_merge(ppu, gb)
    when OBJ_BG_RUN == 4:
      # A chained same-X object re-armed the stall; the tail belongs to the
      # end of the chain.
      if bg_hold and not ppu.fetching_sprite:
        ppu.fetching_sprite = true
        ppu.obj_penalty = 0
  true

proc sprite_wins*(ppu: GbFifoPpu; gb: GB; bg_color, bg_obj_to_bg: uint8;
                  sp_px: GbPixel): bool =
  ## The BG colour comes in as a value: the mixer masks it with LCDC.0 first
  ## (fifo_mix), and passing the entry would mean copying it.
  if sprite_enabled(ppu) and sp_px.color > 0:
    if gb.cgb_native:
      not bg_display(ppu) or bg_color == 0 or
        (bg_obj_to_bg == 0 and sp_px.obj_to_bg == 0)
    else:
      sp_px.obj_to_bg == 0 or bg_color == 0
  else: false

# The fetcher position the window's re-trigger edge survives on; see
# window_reactivate.
const WIN_REACT_PHASE {.intdefine.} = 7

proc win_react_last_park(ppu: GbFifoPpu): bool {.inline.} =
  ## Is this the LAST dot of the fsPushPixel park (FIFO down to one pixel)?
  ## Only position 7 can last more than one dot, so this folds to `true` at
  ## any other WIN_REACT_PHASE. See window_reactivate.
  when WIN_REACT_PHASE == 7: ppu.fifo.size == 1
  else: true

# M3_PIPE_MCYCLES: CPU M-cycles the mode 3 pipeline lags the CPU's register
# view, injected as idle dots at the head of mode 3 and paid back by retiring
# the fetcher early (no mode boundary moves; 4 dots at normal speed, 2 in
# double, so it is latched per line). 0 ships: the M-cycle gambatte
# bgtiledata/bgtilemap measure (two disjoint dot windows at the two speeds)
# was the CPU write committing an M-cycle late, which mem_write now fixes.
# M3_PIPE_DELAY: the additional speed-independent lead in dots. 2 ships,
# pinned by mealybug m3_bgp_change (BGP applied at the shifter, no objects)
# and GBMicrotest ppu_spritex_vs_scx 153/153 once the fetcher's idle steps
# sit at the tail of its cycle. The tail burst's accounting is approximate in
# the last m3_lead pixels (six gambatte bgtilemap/sprites rows).
# Cost (~+0.2%): fetcher_retired folds the lead to an immediate with the
# M-cycle term off; the head delay is spent in one step above the dot loop;
# m3_delay is a uint8. Measure with DINGBAT_BENCH_COUNTERS on an idle machine
# with both arms built in the same directory -- nimcache paths alone move
# retired instructions by 0.25%.
const M3_PIPE_MCYCLES {.intdefine.} = 0
const M3_PIPE_DELAY {.intdefine.} = 2

# Dots the mode 3 -> 0 edge comes early with the pipeline left alone: mode 3
# gets shorter, no pixel moves. 0 ships. GBMicrotest hblank_int_scx0..7 solve
# to a uniform 2 (not the per-residue split they look like), but a uniform
# -2 costs mooneye hblank_ly_scx_timing-GS, wilbertpol
# intr_2_mode0_scx*_timing_nops and ~150 gambatte rows that pin the same edge
# from the other side; see LCD_ON_LINE0_TRIM in gb.nim.
const M3_END_EARLY {.intdefine.} = 0

# CPU M-cycles line 0's pipeline runs ahead of lines 1..143, with every flag
# and STAT source left alone (head delay shorter, flag held the same dots).
# mealybug's line_0_fix (24 vs 28 T-cycles, "line 0 timing is different by 4
# cycles") and gambatte scy/bgtilemap/bgtiledata/scx_during_m3/bgen's line-0
# steps both measure it, and the _ds rows say it is an M-cycle, not 4 dots.
# It is not a late line-0 mode 2 interrupt (mooneye intr_1_2_timing-GS,
# gambatte m2enable/late_enable_ly0_*) and not a short mode 2 (gambatte
# m0enable, vramw_m3end, ly0/lycint152_m2stat_1).
const LY0_PIPE_MCYCLES {.intdefine.} = 0
  ## 0 ships: this is a DIFFERENCE between line 0 and its neighbours, and
  ## M3_PIPE_AHEAD now carries the same M-cycle on every line; adding both
  ## puts line 0 two M-cycles out.

# M3_PIPE_AHEAD's derivation: every gambatte family that writes a PPU register
# out of the mode 2 handler (scy, bgtiledata, bgtilemap, scx_during_m3,
# dmgpalette_during_m3, the mealybug m3_* frames) measures the dispatch
# against the pipeline, so STAT_M2_LEAD (ppu.nim) and this advance are one
# unknown to them and neither scores without the other. daid ppu_scanline_bgp
# refuses the advance on the DMG only on its LY 153 -> 0 snapback anchor;
# re-anchoring it on an ordinary line (a one-byte patch arming LYC = 2 or 4)
# flips its answer to the CGB's, so the four dots belong to the snapback halt
# wake (LYC_SETTLE_HALT_SKIP, gb.nim). Assumed; no ROM pins the re-anchored
# reading. Not the DMG BGP selector (MIXER_PALETTE_OR) and not the DMG model;
# LYC_SETTLE_DOTS = 0 (ppu.nim) moves the same wake for a running CPU too and
# costs eleven gambatte ly0/lycEnable rows.
const LY0_PIPE_ANY = LY0_PIPE_MCYCLES != 0 or M3_PIPE_AHEAD != 0 or
                     CGB_PIPE_MCYCLES != 0

# With every term off the pipeline-lead machinery compiles out (the
# `-d:M3_PIPE_MCYCLES=0 -d:M3_PIPE_DELAY=0 -d:M3_END_EARLY=0
# -d:LY0_PIPE_MCYCLES=0` control build).
const M3_PIPE_LEAD_ANY = M3_PIPE_MCYCLES != 0 or M3_PIPE_DELAY != 0 or
                         M3_END_EARLY != 0 or LY0_PIPE_ANY

template m3_retire_lx(ppu: GbFifoPpu): int32 =
  ## The first `lx` at which the BG fetcher can be retired -- `m3_lead` pixels
  ## short of the last one, which fifo_burst_tail emits on the retire dot.
  ## Shared with the mode-0 STAT lookahead (fifo_irq_m0_ready). The constant
  ## case is spelled out: this is on the mode 3 dot loop.
  when M3_PIPE_MCYCLES == 0: int32(GB_WIDTH - M3_PIPE_DELAY - M3_END_EARLY)
  else: int32(GB_WIDTH) - ppu.m3_lead


# The held-pair ring must name every pixel a write can still reach: the
# deepest mixer stage plus the pixels the tail burst decided early.
static:
  doAssert M3_PIPE_MCYCLES * 4 + M3_PIPE_DELAY + M3_END_EARLY +
           max(MIXER_PALETTE_BACK, MIXER_PRIORITY_BACK) <= MIX_HOLD,
           "MIX_HOLD is too shallow for this lead + mixer tail"

proc window_reactivate(ppu: GbFifoPpu) =
  ## WX re-reached while the window is already the fetch source: nothing
  ## restarts; one colour-0, lowest-priority pixel is injected in front of the
  ## BG FIFO, displacing the rest of the line right by one (mealybug
  ## m3_wx_4_change; _sprites shows an OBJ-behind-BG sprite through it). The
  ## edge survives on one fetcher position of eight (WIN_REACT_PHASE, swept
  ## against m3_wx_4_change, _sprites and m3_wx_5_change) and is anchored to
  ## the END of the fsPushPixel park: an object stretches the park and the
  ## real nametable read does not move with it (m3_wx_4_change_sprites' zero
  ## pixels stay on one lattice through the object bands). Reached through
  ## the same cached `lx == win_lx` compare as the window start.
  # Inserted behind the head: the pixel being displaced is the NEXT one.
  # Depth is 16 and the FIFO never holds more than 8.
  let h = (ppu.fifo.head - 1) and 15
  ppu.fifo.data[h] = ppu.fifo.data[ppu.fifo.head]
  ppu.fifo.data[ppu.fifo.head] =
    GbPixel(color: 0, palette: 0, oam_idx: 0, obj_to_bg: 0)
  ppu.fifo.head = h
  inc ppu.fifo.size

proc window_refuse_start(ppu: GbFifoPpu) =
  ## The WX comparator matched with LCDC.5 low (WIN_EN_HOLD): the match holds
  ## the comparator on the next pixel for WIN_EN_HOLD dots while the shifter
  ## goes on drawing.
  let hold = if ppu.cgb: uint8(CGB_WIN_EN_HOLD) else: uint8(WIN_EN_HOLD)
  if hold == 0'u8:
    ppu.win_lx = WIN_LX_OFF
  elif ppu.win_hold == 0'u8:
    when WIN_EN_HOLD_ZERO != 0:
      # The refused match collides with the fetcher's push (`size == 8`); the
      # line's initial fill satisfies that too, so also require a WY match with
      # the window enabled, or Pokemon Blue (WX = 7, window off) draws a white
      # column at x = 0. See WIN_EN_HOLD_ZERO.
      if ppu.fifo.size == 8 and ppu.window_trigger_en:
        ppu.fifo.data[ppu.fifo.head] =
          GbPixel(color: 0, palette: 0, oam_idx: 0, obj_to_bg: 0)
    ppu.win_hold = hold
    ppu.win_lx = ppu.lx + 1
  else:
    dec ppu.win_hold
    ppu.win_lx = if ppu.win_hold == 0'u8: WIN_LX_OFF else: ppu.lx + 1

proc obj_yields_to_window(ppu: GbFifoPpu): bool {.inline.} =
  ## Does the object the shifter just found wait for the window start? The
  ## two are ordered by COORDINATE: an object whose column is the window's
  ## first column (`lag == 0`) waits, one to the left goes first. mealybug
  ## m3_lcdc_win_map_change and m3_lcdc_tile_sel_win_change band 8 (object at
  ## X = WX + 1) pin it -- the window's first tile's bitplane reads land on
  ## dots 104/106 around the dot-105 write. Resolving both cases window-first
  ## takes win_map_change 34 -> 318 wrong pixels. The object re-pays the wait
  ## (gambatte window/late_disable_spx10_wx0f_2 and two sprites/space ties).
  ## Not on the re-trigger (it may decline, parking the shifter) and not on
  ## x = 159, where gambatte window/m2int_wxA6_spxA7_* wants the object
  ## charged in front of the restart. The WX = 166 DMG/CGB split
  ## (m2int_wxA6_m3stat, 180 vs 190 dots) is not this rule's.
  ppu.lx == ppu.win_lx and not ppu.fetching_window and
    ppu.lx + 8 == int32(ppu.sprites[0].x) and
    ppu.lx < int32(GB_WIDTH) - 1

proc win_start_reaches_pixels(ppu: GbFifoPpu): bool {.inline.} =
  ## DMG_WIN_START_LAST_PX (off): refuse a DMG window START on x = 159. The
  ## DMG renders the CGB reference pixel-exactly on gambatte
  ## window/on_screen/wxA6_*, but does not simply decline the match (wxA6_3
  ## gets worse with this on); what it does is DMG_WIN_LAST_PX_CARRY. Kept as
  ## a control only. Keyed on WX: the comparator sits one slot left of
  ## the first pixel.
  when DMG_WIN_START_LAST_PX == 0: true
  else:
    ppu.cgb or ppu.fetching_window or int(ppu.wx) != GB_WIDTH + 6

proc fifo_mix*(ppu: GbFifoPpu; gb: GB; bg_px, sp_px: GbPixel;
               x: int32): uint16 {.inline.} =
  ## One BG entry and one OBJ entry in, one panel colour out; mixed once at
  ## the pop and again by fifo_recompose_last for a write on the next dots.
  ## `x` is the real screen column (SGB attribute cell). LCDC.0's DMG meaning
  ## is sampled here per pixel (BG_EN_AT_MIX, gb.nim); in CGB mode it is
  ## master priority and sprite_wins reads it. The masked colour is threaded
  ## as a value: copying the entry measured +1.2-1.7%, a branchless mask
  ## worse.
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
    # Super Game Boy: the SNES colourises per 8x8 screen cell, objects
    # included (sgb.nim).
    let cell = (int(ppu.ly) shr 3) * SGB_ATTR_W + (int(x) shr 3)
    return ppu.sgb_pal[int(ppu.sgb_attr[cell]) * 4 + final_color]
  let pal_offset = (int(px_palette) * 4 + final_color) * 2
  cast[ptr uint16](cast[int](arr_pram) + pal_offset)[]

# The mixer is a TAIL behind the FIFO pop: LCDC's priority bits are read one
# dot after the pixel leaves the FIFO (mealybug m3_lcdc_obj_en_change, all
# nineteen bands), BGP/OBP0/OBP1 two dots after (m3_obp0_change). Registers
# only change on M-cycle boundaries, so instead of holding stages in the dot
# loop the write path re-mixes the pixels already emitted (fifo_recompose_*)
# from a ring of held pairs, one store per pixel (+0.35-0.51%). Moving the
# fetcher with M3_PIPE_DELAY = 3 instead helps every mixer row and hurts every
# fetcher row. The tail does not stop at the mode 3 -> 0 edge
# (m3_bgp_change's seventh write lands on the first dot of mode 0 and still
# draws its edge at x = 157): the burst emits the last m3_lead pixels on the
# retire dot, so the shifter's position afterwards is `cycle_counter -
# tail_dot0` and a tail write reaches FORWARD to the burst's pixels too
# (MIXER_TAIL_HBLANK). The tail is clocked in dots, so an object fetch drains
# it rather than freezing it (MIXER_TAIL_DOTS, gb.nim; the mealybug _sprites
# rows). Noting `cycle_counter - lx` per emitted pixel costs +5.02%, so it is
# written only where the shifter STOPS -- object trigger, BG FIFO reset, tail
# burst (mixer_note_stop) -- and mixer_tail_front tests for the stall.

proc mixer_head_back(gb: GB): int32 {.inline.} =
  ## The deepest mixer stage on this console, in dots (the palettes' read,
  ## less the CGB's dot of write latency); MIXER_HEAD_LINGER measures against it.
  int32(MIXER_PALETTE_BACK) - gb_mixer_latency(gb)

proc fifo_recompose_span(ppu: GbFifoPpu; gb: GB; front, back, top, run: int32) =
  ## Re-colour `[front - back, top]`, clipped to the screen, the held ring and
  ## `run` (the first pixel of the shifter's current run). `back` is the
  ## register's depth in the tail.
  var x = max(max(front - back, ppu.lx - MIX_HOLD), run)
  if x < 0: x = 0
  let hi = min(top, ppu.lx - 1)
  while x <= hi:
    let h = ppu.mix[x and (MIX_HOLD - 1)]
    ppu.framebuffer[GB_WIDTH * int(ppu.ly) + int(x)] = fifo_mix(ppu, gb, h.bg, h.sp, x)
    inc x

proc mixer_tail_front(ppu: GbFifoPpu; back, head: int32): (int32, int32, int32)
                     {.inline.} =
  ## `(front, top, run)` for the recompose: the shifter's position on this
  ## dot, the last column a write may reach, the first column of the current
  ## run. Running: position is `lx` and `run` keeps a write off the far side
  ## of the last stall. Stopped -- object fetch, tail burst, or a BG FIFO reset
  ## (`fifo.size == 0 and lx == mix_run`, which a tile boundary never
  ## satisfies) -- position is `cycle_counter - tail_dot0` and the tail drains
  ## under the write (mealybug m3_window_timing line 17, x = 9). Other modes
  ## return an empty span.
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
      # Control arm: nothing drains inside mode 3.
      if m == 0'u8: front = ppu.cycle_counter - ppu.tail_dot0
    when MIXER_HEAD_LINGER != 0:
      # The line's first pixel keeps every tail stage live until the deepest
      # is read (MIXER_HEAD_LINGER, gb.nim); `run == 0` excludes a line with
      # an object at screen x = 2.
      if back < head and front - back == 1'i32 and run == 0'i32:
        dec front
    (front, int32(GB_WIDTH) - 1, run)
  else: (int32(GB_WIDTH) + MIX_HOLD, -1'i32, 0'i32)

proc fifo_recompose_last*(ppu: GbFifoPpu; gb: GB; back: int32;
                          skip: int32 = 0) {.noinline.} =
  ## Re-colour every pixel this write still reaches; caller is ppu_write on
  ## the four mixer registers. `back` is the register's depth, `skip` how many
  ## pixels at the far end the caller painted itself (the DMG palette write's
  ## `old or new` pixel, fifo_recompose_at). Not `back - 1`: MIXER_HEAD_LINGER
  ## makes the reach a function of `back` at the head of the line.
  let (front, top, run) = mixer_tail_front(ppu, back, mixer_head_back(gb))
  fifo_recompose_span(ppu, gb, front, back - skip, top, run)

proc fifo_recompose_at*(ppu: GbFifoPpu; gb: GB; back: int32) {.noinline.} =
  ## Re-colour exactly the pixel `back` stages down the tail (the palette
  ## write's transition pixel, MIXER_PALETTE_OR in gb.nim).
  let (front, top, run) = mixer_tail_front(ppu, back, mixer_head_back(gb))
  fifo_recompose_span(ppu, gb, front, back, min(top, front - back), run)

proc fifo_obj_size_write*(ppu: GbFifoPpu; gb: GB) {.noinline.} =
  ## LCDC.2 written after an object merged and before its high plane was
  ## read: redo that plane only. Cold (ppu_store_lcdc, inside the obj_fix_from
  ## window). No FIFO snapshot: the merge only ever overwrote colour-0 slots,
  ## so a slot carrying this object is re-coloured (or handed back as
  ## transparent), a colour-0 slot is taken if the new colour is not 0, and any
  ## other slot stays with the object that won it. The oam_idx of a covered
  ## transparent entry is lost; only the CGB merge rule reads it, and this
  ## path cannot reach it at the shipping CGB_OBJ_SIZE_LATENCY.
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
      # Already emitted: it is in the mixer's held pairs (`k` is never
      # further back than OBJ_PLANE1_LAG).
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
  ## One pixel out of the shifter. A template, not an inline proc: with two
  ## call sites (the second is DMG_WIN_LAST_PX_CARRY's) clang stopped inlining
  ## it into the dot loop, +3.63% on cgb-acid-hell.
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
    # Held for the mixer's tail (fifo_recompose_last). `has_sprite` is not
    # kept: an empty OBJ FIFO leaves colour 0, which sprite_wins refuses.
    when MIXER_DOT_LAG != 0:
      # Indexed by the pixel's low bits so MIX_HOLD dots cost one store.
      ppu.mix[ppu.lx and (MIX_HOLD - 1)] = GbMixHold(bg: bg_px, sp: sp_px)
    ppu.framebuffer[GB_WIDTH * int(ppu.ly) + int(ppu.lx)] =
      fifo_mix(ppu, gb, bg_px, sp_px, ppu.lx)
  inc ppu.lx

proc fifo_obj_walked_past(ppu: GbFifoPpu): bool {.noinline.} =
  ## Did the shifter walk past this object while LCDC.1 was low? Then it is
  ## gone for the line. Asked at the trigger, not per dot: a first trigger
  ## lands on `lx + 8 == x`, so `lx + 8 > x` means the comparator was blocked
  ## on its dot, and a window yield blocks one dot, which OBJ_ABORT_LEAD = 2
  ## does not reach (a per-dot prune measured +0.69%). OAM X < 8 is excluded:
  ## its trigger is the line's first shifter dot, and testing it retires
  ## left-edge objects never passed (costs gambatte scx_during_m3 and sprites
  ## rows). noinline: `delete` in the dot loop is the inline cliff.
  let x = int32(ppu.sprites[0].x)
  if x < 8'i32 or ppu.lx - (x - 8'i32) < OBJ_ABORT_LEAD: return false
  ppu.sprites.delete(0)
  true

proc win_start_carries(ppu: GbFifoPpu): bool {.inline.} =
  ## Is this the window START a DMG cannot draw, the match on the last pixel
  ## (DMG_WIN_LAST_PX_CARRY)? Only WX = 166 reaches x = 159.
  when DMG_WIN_LAST_PX_CARRY == 0: false
  else: not ppu.cgb and ppu.lx == int32(GB_WIDTH) - 1


when WIN_EN_REVOKE_ANY:
  proc win_defer_arm(ppu: GbFifoPpu) {.noinline.} =
    ## A CGB window start has just been taken and is revocable for
    ## CGB_WIN_EN_DEFER dots: record what win_start_reset overwrites. Nothing
    ## pushes to the BG FIFO during those dots, so head/tail/size are the whole
    ## FIFO undo. noinline: eleven stores in the dot loop's window branch.
    ppu.win_defer =
      if ppu.cgb: uint8(CGB_WIN_EN_DEFER) else: uint8(DMG_WIN_EN_REVOKE)
    if ppu.win_defer == 0'u8: return
    ppu.win_revoking     = false
    ppu.wd_dot           = ppu.cycle_counter
    ppu.wd_win_hold      = ppu.win_hold
    ppu.wd_head          = ppu.fifo.head
    ppu.wd_tail          = ppu.fifo.tail
    ppu.wd_size          = ppu.fifo.size
    ppu.wd_fetcher_x     = ppu.fetcher_x
    ppu.wd_fetch_counter = ppu.fetch_counter
    ppu.wd_obj_tile_fx   = ppu.obj_tile_fx
    ppu.wd_lx            = ppu.lx
    ppu.wd_head_cycle    = ppu.head_cycle
    when MIXER_DOT_LAG != 0:
      ppu.wd_tail_dot0 = ppu.tail_dot0
      ppu.wd_mix_run   = ppu.mix_run

  proc win_defer_undo(ppu: GbFifoPpu; gb: GB) {.noinline.}
    ## Forward declaration (the undo replays tick_shifter); the pragmas must
    ## match the implementation's, which gcc checks and clang does not.

proc tick_shifter*(ppu: GbFifoPpu; gb: GB) =
  if ppu.fifo.size > 0:
    if not ppu.smooth_scroll_sampled: fifo_sample_smooth_scroll(ppu)
    # Object trigger, before the pop. Not gated on `ppu.cgb` (Pan Docs says
    # the CGB pays the fetch with objects off): tried, it phase-swaps the
    # gambatte oamdma/late_sp* family.
    if sprite_enabled(ppu) and ppu.sprites.len > 0 and
       int(ppu.lx) + 8 >= int(ppu.sprites[0].x) and
       # Off the hot path: reached only once the three tests above passed.
       not obj_yields_to_window(ppu) and
       # An object the shifter walked past with LCDC.1 low is gone: gambatte
       # sprites/sprite_late_enable_spx{18,19,1A,1B}_{1,2} bracket the flip at
       # W - T = +2 (the +2 row itself is unscored), which is OBJ_ABORT_LEAD
       # spent on the rising edge.
       not fifo_obj_walked_past(ppu):
      ppu.fetching_sprite = true
      # First object of the line inside the tail burst? (OBJ_TAIL_WALK_REFUND;
      # read before the store below sets the flag.)
      when OBJ_TAIL_WALK_REFUND != 0:
        let tail_walk =
          if ppu.obj_last_px: 0'i32 else: max(0'i32, ppu.lx - ppu.m3_retire_lx)
      when CGB_WIN_TAIL_LAST != 0:
        # On the last pixel this fetch and a window restart share a slot
        # (fetch_work_pending).
        if ppu.lx == int32(GB_WIDTH) - 1: ppu.obj_last_px = true
      # The shifter stops for the whole penalty; the mixer tail drains under it.
      mixer_note_stop(ppu)
      # The Pixel's index in the BG tile the FIFO holds; `lag` is 0 for an
      # object starting on screen and 1..8 for one hanging off the left edge,
      # which is charged against the tile BEFORE the first (gambatte
      # sprites/10spritesPrLine_1xpos0: X = 0 leaves that tile unconsidered).
      let lag = ppu.lx + 8 - int32(ppu.sprites[0].x)
      let idx = 8 - int32(ppu.fifo.size) - lag
      let tile = int32(ppu.fetcher_x) + (if idx < 0: -1'i32 else: 0'i32)
      # This dot is the first of the penalty, so the countdown is one short.
      var pen = OBJ_FETCH_DOTS - 1
      if ppu.obj_tile_fx != tile:
        ppu.obj_tile_fx = tile
        # Pan Docs' X = 0 exception: a flat 11 regardless of SCX, charged as
        # index 0 of its tile (GBMicrotest ppu_spritex_vs_scx asserts it for
        # all eight residues).
        let sub = if ppu.sprites[0].x == 0: 0'i32 else: idx and 7
        pen += max(0'i32, (7 - sub) - (OBJ_WAIT_SUB - 1))
      when OBJ_TAIL_WALK_REFUND != 0:
        # The walk into the tail burst was paid at the head (OBJ_TAIL_WALK_REFUND).
        pen -= tail_walk
      ppu.obj_penalty = pen
      when OBJ_ABORT_LATE:
        # Last dot of the object's FETCH, for an abort arriving after the
        # stall (OBJ_ABORT_LATE): the tail arm ends with the stall, the head
        # arm's whole abort window is inside it (sentinel).
        ppu.obj_abort_last =
          if idx < 0: OBJ_ABORT_LAST_OFF else: ppu.cycle_counter + pen
      when STAT_M0_TAIL_ANY and STAT_M0_FIELD_TAIL_ABSORB:
        ppu.obj_dots_line += pen
      # The dot the high bitplane reads LCDC.2 on, per arm (OBJ_PLANE1_LAG);
      # `cycle_counter + pen` is the merge dot.
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
    # The window start (Pan Docs, "Window"): an EQUALITY on the pixel about to
    # be emitted, asked before the pop. gambatte window/arg/late_wy_FFto2_ly2_*
    # pin the dot (`83 + WX + (SCX and 7)`); a `>=` could not be un-satisfied
    # by a late WY write. Pre-emit so a WX = 7 window fires on the first
    # pixel. Precomputed into win_lx: a second per-dot branch here measured
    # +1.7%. The restart enters FETCHER_ORDER at counter 0, six dots to the
    # push (Pan Docs' window cost), now that the fetcher idles at the tail of
    # its cycle.
    if ppu.lx == ppu.win_lx and win_start_reaches_pixels(ppu):
      when defined(gb_m3_trace):
        # Every dot the WX equality is reached, with the fetcher position.
        if gb_traced(ppu.ly):
          echo "WINHIT ly=", ppu.ly, " dot=", ppu.cycle_counter, " lx=", ppu.lx,
               " fc=", ppu.fetch_counter, " fw=", ppu.fetching_window,
               " fifo=", ppu.fifo.size
      if not ppu.fetching_window:
        when WIN_EN_HOLD > 0:
          # The match waits for LCDC.5 rather than being dropped (WIN_EN_HOLD):
          # `window_enabled` is asked here, not in fifo_arm_window, so a
          # refused match is still seen. Costs a window-less line nothing.
          if not window_enabled(ppu):
            window_refuse_start(ppu)
          else:
            when WIN_EN_REVOKE_ANY:
              # Revocable start: record before WIN_EN_HOLD_BACK moves `lx`.
              win_defer_arm(ppu)
            when WIN_EN_HOLD_BACK != 0:
              # A match that waited starts one pixel left (WIN_EN_HOLD_BACK);
              # the window's first push overwrites that background pixel.
              if ppu.win_hold > 0'u8: dec ppu.lx
            # The DMG's start on the last pixel keeps that pixel (mode 3 ends
            # with it); emitted before the restart empties the FIFO
            # (DMG_WIN_LAST_PX_CARRY).
            if win_start_carries(ppu):
              when WIN_EN_REVOKE_ANY:
                # Not revocable: the pixel is emitted and the start is owed to
                # the next line (gambatte window/on_screen/wxA6_late_we_reenable_*).
                ppu.win_defer = 0'u8
              fifo_emit_pixel(ppu, gb)
              # Not win_start_reset: its clamp would rewind onto the pixel
              # just emitted.
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
          when WIN_EN_REVOKE_ANY: win_defer_arm(ppu)
          win_start_reset(ppu)
          return
      elif ppu.fetch_counter == WIN_REACT_PHASE and win_react_last_park(ppu) and
           window_enabled(ppu):
        # The re-trigger edge, sharing the compare above.
        window_reactivate(ppu)
    fifo_emit_pixel(ppu, gb)
  else:
    when WIN_EN_REVOKE_ANY:
      # A revocable window start's dots are counted here (CGB_WIN_EN_DEFER):
      # they are the restart's first five, all of which land in this
      # empty-FIFO arm, where a byte test at the top of fifo_pipeline_dot
      # measured +0.6%.
      if ppu.win_defer > 0'u8:
        dec ppu.win_defer
        if ppu.win_defer == 0'u8 and ppu.win_revoking:
          win_defer_undo(ppu, gb)

proc fetch_work_pending(ppu: GbFifoPpu): bool {.inline.} =
  ## What the fetcher still owes for the last `m3_lead` pixels of a line;
  ## shared by fetcher_retired and fifo_irq_m0_ready. Only reached inside the
  ## tail. See fetcher_retired for the terms.
  if ppu.fetching_sprite: return true
  if sprite_enabled(ppu) and ppu.sprites.len > 0 and
     int(ppu.sprites[0].x) <= GB_WIDTH + 7: return true
  when WIN_TAIL_FETCH != 0:
    # A started window whose restart has not pushed yet (`fetcher_x == 0`)
    # still owes the fetcher (WIN_TAIL_FETCH, gb.nim). On the last pixel the
    # devices part (CGB_WIN_TAIL_LAST): the CGB waits for the fetch, the DMG
    # ends with the pixel; an object already fetched on that pixel
    # (obj_last_px) is not charged twice.
    if ppu.fetching_window and ppu.fetcher_x == 0 and
       (ppu.lx < int32(GB_WIDTH) - 1 or
        (CGB_WIN_TAIL_LAST != 0 and ppu.cgb and not ppu.obj_last_px)):
      return true
  if not ppu.fetching_window and ppu.window_trigger and window_enabled(ppu) and
     int(ppu.wx) <= GB_WIDTH + 6: return true
  when DMG_WIN_LAST_PX_CARRY != 0:
    # A DMG line carried out of the previous one starts with the window
    # already fetching and its WX = 166 match still ahead, and owes that
    # restart like an ordinary one (gambatte window/m2int_wxA6_m3stat_1 and
    # siblings read 174 dots, not 172).
    if not ppu.cgb and ppu.fetching_window and
       (ppu.lx < int32(GB_WIDTH) - 1 or
        (ppu.obj_last_px and ppu.lx < int32(GB_WIDTH))) and
       ppu.window_trigger and window_enabled(ppu) and
       int(ppu.wx) == GB_WIDTH + 6: return true
  false

proc fetcher_retired(ppu: GbFifoPpu): bool {.inline.} =
  ## Has the BG fetcher run out of work for this line? That, not the last
  ## pixel leaving the shifter, ends mode 3. Inside the last m3_lead pixels a
  ## pending object (X <= 167 with LCDC.1 on: gambatte sprites/
  ## 10spritesPrLine_10xposA6/A7 and sprite_late_disable_*) or an unstarted
  ## window (WX <= 166: gambatte window/m2int_wxA6_*; no `ly >= wy` term, the
  ## latch IS the WY condition, window/arg/late_wy_1toFF_*) holds it open.
  ## "The FIFO does not yet hold the rest of the line" is deliberately not a
  ## term: it re-times the end of mode 3 on ordinary lines. Left inline: clang
  ## folds the first compare into the loop's `lx` test.
  when not M3_PIPE_LEAD_ANY:
    # The degenerate case, spelled out for the mode 3 loop condition.
    ppu.lx >= GB_WIDTH
  else:
    # See `m3_retire_lx` for why the constant case is spelled out there.
    if ppu.lx < ppu.m3_retire_lx: return false
    if ppu.lx >= GB_WIDTH: return true
    not fetch_work_pending(ppu)

proc fifo_pipeline_dot(ppu: GbFifoPpu; gb: GB) {.inline.} =
  ## One dot of the fetch/shift pipeline. The first `m3_lead` dots of a line
  ## are skipped by the caller in one step (`m3_delay`) rather than tested
  ## here, and the tail is burst when the fetcher retires.
  when defined(gb_m3_trace):
    if gb_traced(ppu.ly):
      echo "DOT ", ppu.cycle_counter, " stage=",
           FETCHER_ORDER[ppu.fetch_counter], " lx=", ppu.lx,
           " fx=", ppu.fetcher_x, " lcdc=", toHex(ppu.lcd_control, 2),
           " fifo=", ppu.fifo.size, " spr=", ppu.fetching_sprite,
           " pen=", ppu.obj_penalty,
           " tn=", toHex(ppu.tile_num, 2), " mode=", ppu.mode_flag
  when SCX_STORE_STALL_DOTS != 0:
    # A mid-line SCX store stalls the whole pipeline (SCX_STORE_STALL_DOTS).
    if ppu.scx_stall > 0:
      dec ppu.scx_stall
      return
  # One call site for tick_shifter (tick_sprite_fetcher's result).
  if ppu.fetching_sprite:
    if tick_sprite_fetcher(ppu, gb): return
  else:
    tick_bg_fetcher(ppu, gb)
  tick_shifter(ppu, gb)

when WIN_EN_REVOKE_ANY:
  proc win_defer_undo(ppu: GbFifoPpu; gb: GB) {.noinline.} =
    ## LCDC.5 went low inside a revocable CGB window start: restore the match
    ## dot's state and replay its shifter step. The charge is where this
    ## lands: an undo on dot X leaves the line X - D dots behind
    ## (CGB_WIN_REVOKE_LAG). The BG FIFO is empty for every revocable dot, so
    ## nothing else happened in them.
    ppu.win_defer     = 0'u8          # before the replay: it must not re-enter
    ppu.win_revoking  = false
    ppu.fifo.head     = ppu.wd_head
    ppu.fifo.tail     = ppu.wd_tail
    ppu.fifo.size     = ppu.wd_size
    ppu.fetcher_x     = ppu.wd_fetcher_x
    ppu.fetch_counter = ppu.wd_fetch_counter
    ppu.obj_tile_fx   = ppu.wd_obj_tile_fx
    ppu.lx            = ppu.wd_lx
    ppu.head_cycle    = ppu.wd_head_cycle
    ppu.win_hold      = ppu.wd_win_hold
    ppu.fetching_window = false
    dec ppu.current_window_line
    when MIXER_DOT_LAG != 0:
      ppu.tail_dot0 = ppu.wd_tail_dot0
      ppu.mix_run   = ppu.wd_mix_run
    # Re-derived: WIN_LX_OFF with the bit low; the window cannot restart on
    # this line.
    fifo_arm_window(ppu)
    when defined(gb_win_trace):
      echo "WINUNDO ly=", ppu.ly, " dot=", ppu.cycle_counter, " lx=", ppu.lx,
           " fifo=", ppu.fifo.size
    tick_shifter(ppu, gb)
    # `extra` dots are given back: CGB single speed 0 (charge W - D), double
    # speed CGB_WIN_REVOKE_DS_TRIM, DMG the whole W - D (DMG_WIN_EN_REVOKE,
    # all or nothing).
    var extra = 0
    if ppu.cgb:
      when CGB_WIN_REVOKE_DS_TRIM != 0:
        if gb.memory.current_speed != 0: extra = CGB_WIN_REVOKE_DS_TRIM
    else:
      when DMG_WIN_EN_REVOKE != 0:
        extra = int(ppu.cycle_counter - ppu.wd_dot)
    for _ in 0 ..< extra: fifo_pipeline_dot(ppu, gb)

proc fifo_obj_abort*(ppu: GbFifoPpu; gb: GB) =
  ## LCDC.1 went low during an object's stall: the fetch is abandoned, the
  ## object dropped (it would re-trigger when the bit returns; gambatte
  ## sprite_late_enable_spx18..1B set it back on this line), and the rest of
  ## the penalty refunded to shifter and flag alike. charge = min(W -
  ## OBJ_ABORT_LEAD - T, P): gambatte sprites/sprite_late_disable_spx{18,19,
  ## 1A,1B}_{1,2} (STAT read at 257) and sprite_late_late_disable_* (read at
  ## 261) fit k = 2 from both sides, and the _1 rows say the WAIT half is
  ## abortable too. mealybug m3_lcdc_obj_en_change_variant bands 16/17 (a
  ## BGP-black ruler) give the same k, so OBJ_ABORT_FLAG_HOLD is 0. A table of
  ## trigger dots is only valid for the pipeline phase it was taken on. The
  ## CGB does not cancel (CGB_OBJ_ABORT = 0): the variant's _cgb_c reference
  ## keeps the full penalty, though a CGB LCDC.1 latency of 4+ dots would look
  ## the same there.
  ppu.fetching_sprite = false
  ppu.obj_penalty = 0
  if ppu.sprites.len > 0: ppu.sprites.delete(0)
  # The lead, spent as catch-up dots (fifo_tick catches up behind ppu_write):
  # the shifter's first dot back is W - OBJ_ABORT_LEAD. It cannot over-run:
  # the trigger dot is itself stalled.
  for _ in 0 ..< OBJ_ABORT_LEAD: fifo_pipeline_dot(ppu, gb)
  # The dot only the flag sees.
  when OBJ_ABORT_FLAG_HOLD != 0:
    ppu.m3_hold = ppu.m3_hold + uint8(OBJ_ABORT_FLAG_HOLD)

when OBJ_ABORT != 0 and OBJ_ABORT_LATE:
  proc fifo_obj_abort_late*(ppu: GbFifoPpu; gb: GB) =
    ## LCDC.1 went low on a dot the stall has already finished but which still
    ## reaches the fetcher at W - OBJ_ABORT_LEAD (gambatte sprite_late_late_
    ## disable_spx{1A,1B}_1, W = T + P): refund the dots still owed as catch-up
    ## pipeline dots. Nothing else of the abort applies (the fetch has merged;
    ## its pixels are the mixer's question). obj_abort_last is a sentinel on
    ## the idx < 0 arm, where mealybug m3_lcdc_obj_en_change_variant band 0
    ## wants no refund.
    let refund = ppu.obj_abort_last + 1 + OBJ_ABORT_LEAD - ppu.cycle_counter
    ppu.obj_abort_last = OBJ_ABORT_LAST_OFF
    for _ in 0 ..< refund: fifo_pipeline_dot(ppu, gb)

template m3_start_dot(gb: GB): int32 =
  ## The dot the mode 2 -> 3 boundary lands on. Must be the same expression
  ## the idle skip jumps to, or the loop never visits the boundary.
  when M3_GRID_EARLY != 0:
    80'i32 - int32(M3_GRID_EARLY * (4 shr gb.memory.current_speed))
  else:
    80'i32

template fifo_skip_target(ppu: GbFifoPpu; gb: GB; m: uint8): int32 =
  ## The next dot of this line an idle mode has something to do on. On the
  ## hottest path in the PPU (once per M-cycle of every memory access), so a
  ## template: as a proc it measured +1.0%. Line 143's mode 0 has the CGB
  ## early mode-2 pulse to visit first (M2_144_EARLY_DOT); `ly == 143` leads
  ## because it is false on 153 of 154 lines.
  when not STAT_M0_LEAD_DOMAIN:
    # STAT_M0_LEAD_T alone moves one edge inside mode 3 and compiles the
    # domain's boundary hooks out; only a domain lead needs the branch below.
    if m == 2: m3_start_dot(gb)
    elif ppu.ly == 143 and m == 0 and m2_144_early_active(gb): M2_144_EARLY_DOT
    elif ppu.m2_early_stop(gb): ppu.m2_early_dot(gb)
    else: gb_line_end(ppu)
  else:
    # A STAT_IRQ_LEAD build stops twice per boundary, `lead` dots apart
    # (`>=`: a stop the counter sits on is not processed yet).
    block:
      let boundary = if m == 2: m3_start_dot(gb) else: gb_line_end(ppu)
      var tgt = boundary
      let irq_dot = boundary - stat_irq_lead(gb)
      if irq_dot >= ppu.cycle_counter: tgt = irq_dot
      # The OAM source's early dot (STAT_M2_LEAD) is a third stop, distinct
      # from irq_dot except at a one-M-cycle lead; without it the skip jumps
      # over the rising dot and STAT_M2_LEAD silently turns off.
      when STAT_M2_EARLY:
        if ppu.m2_early_stop(gb):
          let m2_dot = ppu.m2_early_dot(gb)
          if m2_dot >= ppu.cycle_counter and m2_dot < tgt: tgt = m2_dot
      if ppu.ly == 143 and m == 0 and m2_144_early_active(gb) and
         M2_144_EARLY_DOT >= ppu.cycle_counter and M2_144_EARLY_DOT < tgt:
        tgt = M2_144_EARLY_DOT
      tgt

when STAT_M2_EARLY:
  proc fifo_m2_early_edge(ppu: GbFifoPpu; gb: GB) {.noinline.} =
    ## The OAM STAT source comes up one M-cycle (STAT_M2_LEAD) before the line
    ## that scans OAM starts; nothing else happens on that dot, so the edge
    ## detector runs here explicitly. noinline: the caller is inlined into the
    ## bus path.
    if ppu.m2_early: ppu_handle_stat_interrupt(ppu, gb)

proc fifo_line153_edge(ppu: GbFifoPpu; gb: GB) {.noinline.} =
  ## The LY 153 -> 0 snapback is an edge the STAT line has to see inside line
  ## 153 (daid ppu_scanline_bgp resyncs on it every frame): LY changes on the
  ## near side and the comparator re-latches LYC_SETTLE_DOTS later. noinline:
  ## the caller is inlined into the bus path; in line this measured +0.37%.
  if ppu.ly == 153:
    # Near side: LY changes; the comparator is blind for LYC_SETTLE_DOTS.
    ppu.ly = 0
    when STAT_IRQ_SPLIT: ppu.irq_ly = 0
    ppu_handle_stat_interrupt(ppu, gb)
  elif ppu.ly == 0 and (ppu.cycle_counter == LYC_RELATCH_DOT or
                        ppu.cycle_counter == lyc_src_relatch_dot(gb)):
    # Far side: the comparator re-latches (`mode 1 with LY 0` is line 153).
    # Two dots in a double-speed build: the SOURCE relatches an M-cycle before
    # the readable bit (LYC_SRC_RELATCH_LEAD, ppu.nim); at normal speed the
    # the two compares fold to one; at a lead of 0 they are the same dot.
    ppu_handle_stat_interrupt(ppu, gb)

# Can the mode-0 source's lead exceed the retire -> flag hand-off (m3_hold)?
# Both scale with current_speed, so it is decided here; where the lead fits
# inside the hold the dot-loop hook compiles out (worth 1.3% of retired
# instructions).
const M0_LOOKAHEAD_REACHABLE* = STAT_DOMAIN_LEAD != 0 or not M3_AHEAD_HOLD or
                                STAT_M0_LEAD_T > 4 * M3_PIPE_AHEAD

when STAT_IRQ_SPLIT:
  template m0_source_lead(ppu: GbFifoPpu; lead: int32): int32 =
    ## The mode-0 source's share of the domain's lead: zero on the first line
    ## after an LCD enable (tools/gbppu/gam_dispatch.py: exact there, 2 dots
    ## late on every later line; M0_HALT_BLIND_DOTS in ppu.nim). Only the
    ## mode-0 source is gated; STAT_IRQ_LEAD's sources are unmeasured there.
    when STAT_M0_LEAD_T != 0 and not STAT_M0_LEAD_FIRST_LINE:
      (if ppu.first_line: 0'i32 else: lead)
    else:
      lead

  proc fifo_irq_line_advance(ppu: GbFifoPpu; gb: GB) =
    ## The STAT interrupt line's own line boundary, STAT_IRQ_LEAD M-cycles
    ## before the flag domain's, on irq_ly / irq_mode. Nothing the CPU reads
    ## back, and not the vblank interrupt.
    if ppu.irq_mode == 1:
      # Line 153 has already snapped irq_ly to 0.
      if ppu.irq_ly != 0: ppu.irq_ly += 1
      if ppu.irq_ly == 0: ppu.irq_mode = 2
    else:
      ppu.irq_ly += 1
      ppu.irq_mode = if int(ppu.irq_ly) == GB_HEIGHT: 1'u8 else: 2'u8
    ppu_handle_stat_interrupt(ppu, gb)

  proc fifo_irq_m0_ready(ppu: GbFifoPpu; lead: int32): bool {.noinline.} =
    ## Will the fetcher have retired `lead` dots from now (when the STAT
    ## line's mode 0 rises)? Measured from m3_retire_lx, not GB_WIDTH: the
    ## loop exits on the retire dot, so counting from GB_WIDTH never fires for
    ## a lead inside M3_PIPE_DELAY + M3_END_EARLY. noinline: a second copy of
    ## fetch_work_pending in the mode 3 branch is the inline cliff, and the
    ## caller's guard never calls this where it ships.
    if ppu.lx < ppu.m3_retire_lx - lead: return false
    if ppu.lx >= int32(GB_WIDTH) - lead: return true
    not fetch_work_pending(ppu)

when M3_PIPE_LEAD_ANY:
  proc fifo_burst_tail(ppu: GbFifoPpu; gb: GB) {.inline.} =
    ## The last `m3_lead` pixels of a line, emitted on the retire dot rather
    ## than over the first dots of H-Blank. inline (only fifo_tick_slow changes
    ## size, -0.04%); re-run the per-function size diff before changing it.
    var guard = 0
    while ppu.lx < GB_WIDTH and guard < 64:
      fifo_pipeline_dot(ppu, gb)
      inc guard

proc fifo_tick_slow(ppu: GbFifoPpu; gb: GB; cycles: int) =
  ## Everything the PPU can do in a span that is not a pure idle skip; the
  ## idle case inlines into fifo_tick.
  if lcd_enabled(ppu):
    var remaining = cycles
    when STAT_IRQ_SPLIT and (STAT_M0_LEAD_DOMAIN or M0_LOOKAHEAD_REACHABLE):
      # Dots the STAT interrupt line runs ahead of the mode flag, read once per
      # tick (a speed switch cannot land inside one). Hoisted only where the
      # loop reads it every tick; the shipping STAT_M0_LEAD_T reads it once a
      # line. `mode_flag=` catches irq_mode up at every boundary the domain
      # hooks are compiled out of.
      let lead = stat_irq_lead(gb)
    while remaining > 0:
      # Modes 0, 1 and 2 have no per-dot work: jump to the next dot that does.
      # Mode 1 below LYC_RELATCH_DOT opts out so LY153_SNAP_DOT and the
      # comparator re-latch are visited (90 no-op iterations a frame).
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
        # Mode 3 is the only mode with per-dot work. The flag and the pipeline
        # are separate events: mode 3 ends when the FETCHER retires, m3_lead
        # pixels before the shifter finishes, and those pixels are burst on
        # that dot; the CPU VRAM/OAM locks open with the flag; the fetcher
        # never runs into H-Blank (mealybug m3_scx_low_3_bits catches it
        # re-reading SCX there). An object at X 160..167 holds mode 3 open.
        when M3_PIPE_LEAD_ANY:
          # The head delay, spent in one step. No `continue`: falling into the
          # loop is the same sequence and saves a back edge. The byte test is
          # the ~0.19% floor and cannot go: a double-speed lead of 2 always
          # leaves a dot for the next tick.
          if ppu.m3_delay != 0:
            let skip = min(remaining, int(ppu.m3_delay))
            ppu.m3_delay -= uint8(skip)
            ppu.cycle_counter += int32(skip)
            remaining -= skip
        when STAT_IRQ_SPLIT and M0_LOOKAHEAD_REACHABLE:
          # The mode-0 source rises `lead` dots before the flag; the first
          # m3_hold of them are spent past the hand-off (hold branch below), so
          # only the remainder is a fetcher lookahead. Hoisted: neither term
          # changes inside this loop. Threshold from m3_retire_lx, as
          # fifo_irq_m0_ready's is.
          let px_lead = ppu.m0_source_lead(lead) - int32(ppu.m3_hold)
          let m0_hook_lx = if px_lead > 0: ppu.m3_retire_lx - px_lead
                           else: high(int32)
        while remaining > 0 and not fetcher_retired(ppu):
          when STAT_IRQ_SPLIT and M0_LOOKAHEAD_REACHABLE:
            if ppu.lx >= m0_hook_lx and ppu.irq_mode == 3 and
               fifo_irq_m0_ready(ppu, px_lead):
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
        # The whole boundary moves M3_GRID_EARLY early.
        let m3_dot = m3_start_dot(gb)
        when STAT_IRQ_SPLIT:
          # Mode 2 ends for the interrupt line a lead before the mode bits.
          when STAT_M0_LEAD_DOMAIN:
            if ppu.cycle_counter == m3_dot - lead: ppu_set_irq_mode(ppu, gb, 3'u8)
        if ppu.cycle_counter == m3_dot:
          ppu.`mode_flag=`(3'u8, gb)
          # WX < 7 puts the window's first pixel left of the screen, where the
          # equality cannot reach it: the line starts as a window line with the
          # window's own fine scroll and no restart (gambatte
          # m2int_wx00_m3stat_1/2, GBMicrotest win0_scx3_a/b). WX = 7 is an
          # ordinary start. Which WX decides it is read at the end of the
          # throw-away fetch (fifo_head_window, WIN_LINE_START_LATCH).
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
            # No tail in flight until this line emits (the LCD switched off
            # mid-mode-3 reaches mode 0 without passing the retire dot).
            ppu.tail_dot0 = TAIL_DOT0_OFF
            ppu.mix_run = 0
          when M3_PIPE_LEAD_ANY:
            # Per line: the M-cycle half is 4 dots at normal speed, 2 in double.
            ppu.m3_lead = int32(M3_PIPE_MCYCLES * (4 shr gb.memory.current_speed) +
                                M3_PIPE_DELAY + M3_END_EARLY)
            # M3_END_EARLY's share is not paid back at the head.
            ppu.m3_delay = uint8(int(ppu.m3_lead) - M3_END_EARLY)
            ppu.m3_hold = 0
          ppu.smooth_scroll_sampled = false
          when STAT_M0_TAIL_ANY and STAT_M0_FIELD_TAIL_ABSORB:
            ppu.obj_dots_line = 0'i32
          when SCX_FINE_LATCH_LIVE:
            ppu.scx_latch_until = -1'i32
          ppu.dropped_first_fetch = false
          # Finish the line's OAM scan.
          when OAM_SCAN_DMA_LOCK != 0:
            # The incremental body only on a line a transfer touched; the burst
            # is +2.07% cheaper everywhere else (fifo_get_sprites).
            if unlikely(ppu.scan_line == int32(ppu.ly) or gb.memory.dma_busy):
              oam_scan_advance(ppu, gb, OAM_SCAN_DOTS,
                               blocked = gb.memory.dma_busy)
            else:
              ppu.sprites = fifo_get_sprites(ppu, gb)
              when OAM_SCAN_DMA_HOLD != 0:
                # An undisturbed line ends holding the last entry's Y/X.
                ppu.scan_y_bus = ppu.sprite_table[0x9C]
                ppu.scan_x_bus = ppu.sprite_table[0x9D]
          else:
            ppu.sprites = fifo_get_sprites(ppu, gb)
          when LY0_PIPE_ANY:
            # The pipeline advance (M3_PIPE_AHEAD + the CGB term), both halves
            # paid here: the head delay shrinks and the rest is spent as
            # pipeline dots now; the flag is held `adv` dots at the retire
            # (m3_hold). first_line is excluded (LCD_ON_LINE0_TRIM).
            let base = M3_PIPE_AHEAD +
                       (when CGB_PIPE_MCYCLES != 0:
                          (if ppu.cgb: CGB_PIPE_MCYCLES else: 0)
                        else: 0)
            # LY0_PIPE_MCYCLES is a DIFFERENCE, so line 0 takes the max of the
            # two, not the sum (the sum puts thirteen CGB mealybug rows wrong on
            # line 0 alone; mealybug's own line_0_fix compensates a difference).
            let mc = if ppu.ly == 0 and not ppu.first_line:
                       max(base, LY0_PIPE_MCYCLES)
                     else: base
            if mc != 0:
              let adv = mc * (4 shr gb.memory.current_speed)
              let head = int(ppu.m3_delay)
              ppu.m3_delay = uint8(max(0, head - adv))
              ppu.m3_hold  = when M3_AHEAD_HOLD: uint8(adv) else: 0'u8
              for _ in 0 ..< adv - min(head, adv): fifo_pipeline_dot(ppu, gb)
          when defined(gb_m3_len):
            if gb_m3_len_lines > 0:
              var xs = ""
              for s in ppu.sprites: xs.add($int(s.x) & ",")
              echo "M3IN ly=", ppu.ly, " scx=", int(ppu.scx), " wx=", int(ppu.wx),
                   " wy=", int(ppu.wy), " lcdc=", toHex(ppu.lcd_control, 2),
                   " objx=", xs
      of 3:  # Drawing
        # Mode 3 ends the dot after the fetcher retires (172 dots at SCX = 0).
        if fetcher_retired(ppu):
          when MIXER_TAIL_HBLANK != 0:
            # Third stop site: the base the recompose counts from through
            # H-Blank. `lx < GB_WIDTH` guards line 0's revisit of the retire dot.
            if ppu.lx < int32(GB_WIDTH): mixer_note_stop(ppu)
          when M3_PIPE_LEAD_ANY:
            # The tail, burst on this dot: every VRAM read is done, so nothing
            # the CPU does in H-Blank may reach these pixels (mealybug
            # m3_scx_low_3_bits rewrites SCX on exactly that dot).
            fifo_burst_tail(ppu, gb)
          when DMG_WIN_LAST_PX_CARRY != 0:
            # Hardware clears "the window has started" at the end of the line;
            # on a DMG that is also the dot a WX = 166 match fires on, so the
            # match survives into the next line (gambatte wxA6_wy00 carries
            # every line; wxA6_wy01 does not carry out of LY 0 because the WY
            # latch is clear). LCDC.5 is not tested: wxA6_weoff_at_xposA6
            # clears it at x = 96 and still carries.
            if not ppu.cgb and int(ppu.wx) == GB_WIDTH + 6 and
               ppu.window_trigger:
              ppu.win_carry = true
          # The flag waits out the pipeline's advance; the burst above stays
          # on the retire dot.
          when LY0_PIPE_ANY:
            if ppu.m3_hold != 0:
              when STAT_IRQ_SPLIT:
                # The far side of the hand-off: the dot with m3_hold == lead is
                # `lead` dots before the flag, for any lead in 0..m3_hold,
                # moving nothing else (not the double-speed mode 3 end the
                # gambatte sprites/*_m3stat_ds_1 rows read).
                if ppu.irq_mode == 3 and
                   int32(ppu.m3_hold) <=
                     ppu.m0_source_lead(stat_irq_lead(gb)):
                  ppu_set_irq_mode(ppu, gb, 0'u8)
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
        # Gating the four line-end events behind one `cycle_counter >=
        # line_end - 4` compare was tried: +2.2% on cgb-acid-hell and nothing
        # for the DMG, because fifo_skip_target already jumps straight to
        # these dots. CGB raises the line-144 mode 2 STAT source one M-cycle
        # early (m2_line144); nothing else happens on that dot, so run the
        # edge detector explicitly.
        if ppu.cycle_counter == M2_144_EARLY_DOT and ppu.ly == 143 and
           m2_144_early_active(gb):
          ppu_handle_stat_interrupt(ppu, gb)
        # The next line's OAM source comes up in this line's last M-cycle
        # (STAT_M2_LEAD).
        when STAT_M2_EARLY:
          if m2_lead_active(gb) and ppu.cycle_counter == ppu.m2_early_dot(gb):
            fifo_m2_early_edge(ppu, gb)
        when STAT_IRQ_SPLIT:
          when STAT_M0_LEAD_DOMAIN:
            if ppu.cycle_counter == gb_line_end(ppu) - lead:
              fifo_irq_line_advance(ppu, gb)
        if ppu.cycle_counter == gb_line_end(ppu):
          ppu.stat_chg_dot -= ppu.cycle_counter
          when LCD_ON_TRIM_ANY:
            if ppu.lcdon_lines > 0: dec ppu.lcdon_lines
          ppu.cycle_counter = 0
          ppu.ly += 1
          # Catch-up for the unsplit build.
          when STAT_IRQ_SPLIT: ppu.irq_ly = ppu.ly
          ppu.read_mode = ppu.read_mode or LY_JUST_CHANGED
          # The comparator lets go here and answers again in ly_advance_close;
          # a rendered line's mode change goes inside that window, entering
          # vblank is outside it.
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
              # Drawn but not displayed (GbPpu.lcd_on_first_frame).
              ppu.lcd_on_first_frame = false
              ppu_blank_frame(ppu, gb)
          else:
            when LY_BLIND_SCOPE >= 0: ly_advance_line(ppu, gb)
            else:                     ppu.`mode_flag=`(2'u8, gb)
      of 1:  # V-Blank
        # The line-144 OAM pulse's falling edge (M2_144_PULSE, ppu.nim): run
        # the edge detector explicitly or the STAT line stays latched high.
        when M2_144_PULSE:
          if ppu.ly == 144'u8 and ppu.cycle_counter == m2_144_fall_dot(gb):
            ppu_handle_stat_interrupt(ppu, gb)
        # Line 0's pulse does not lead unless STAT_M2_EARLY_LY0 is on.
        when STAT_M2_EARLY:
          if m2_lead_active(gb) and ppu.cycle_counter == ppu.m2_early_dot(gb):
            fifo_m2_early_edge(ppu, gb)
        when STAT_IRQ_SPLIT:
          when STAT_M0_LEAD_DOMAIN:
            if ppu.cycle_counter == 456 - lead: fifo_irq_line_advance(ppu, gb)
        if ppu.cycle_counter == 456:
          ppu.cycle_counter = 0
          ppu.stat_chg_dot -= 456
          # Line 153's advance to 0 already ran in fifo_line153_edge; the
          # `ly == 0` branch is that snap's mode 1 -> 2.
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
          # The LYC=0 source sees the snapback a lead ahead of the readable LY
          # (gambatte lyc0int_* / lyc153int_*). Not re-derived against the
          # settling window below; the shipping LEAD = 0 compiles this out.
          when STAT_M0_LEAD_DOMAIN:
            if ppu.ly == 153 and ppu.irq_ly == 153 and
               ppu.cycle_counter >= LY153_SNAP_DOT - lead:
              ppu.irq_ly = 0
              ppu_handle_stat_interrupt(ppu, gb)
        # Snapback and re-latch: fifo_line153_edge.
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
  # The mode a CPU read in this M-cycle observes (GbPpu.read_mode). Written
  # on the idle path too: a preceding slow tick may have changed it.
  let m = ppu.lcd_status and 3'u8
  ppu.read_mode = m
  # The panel's refresh clock runs whether or not the PPU drives it.
  ppu.dots_since_frame += int32(cycles)
  when defined(gb_dot_counter): gb_total_dots += uint64(cycles)
  # Lazy idle span: the first iteration of fifo_tick_slow's skip, hoisted so
  # the ~11,000 idle ticks a frame cost one compare. Nothing is observable
  # while the span stays inside an idle stretch; mode 3, mode 1 below
  # LYC_RELATCH_DOT and an LCD that is off fall through.
  if m != 3 and (ppu.lcd_control and 0x80'u8) != 0:
    let target = fifo_skip_target(ppu, gb, m)
    let next = ppu.cycle_counter + int32(cycles)
    # `<=`: landing exactly on the target leaves the transition for the next
    # entry, as the loop does.
    if next <= target and
       (m != 1 or ppu.cycle_counter > LYC_RELATCH_DOT):
      ppu.cycle_counter = next
      return
  fifo_tick_slow(ppu, gb, cycles)

method tick*(ppu: GbFifoPpu; gb: GB; cycles: int) =
  ## Polymorphic entry point; the hot path calls fifo_tick directly.
  fifo_tick(ppu, gb, cycles)
