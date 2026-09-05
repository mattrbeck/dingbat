# GB PPU shared base (included by gb.nim)

# Dots the re-enabled PPU is already into line 0 when the LCDC write retires;
# see the LCDC-enable path in ppu_write.
const LCD_ON_HEAD_START* {.intdefine.} = 5'i32

# Dots past the start of VBlank at which the CGB boot ROM hands off (skip_boot).
const CGB_BOOT_PHASE* {.intdefine.} = 161

# Dot of line 153 at which the DMG/MGB boot ROM hands off (skip_boot).
const DMG_BOOT_PHASE* {.intdefine.} = 397

# STAT_IRQ_LEAD (gb.nim) lets the STAT interrupt line's copy of the mode and LY
# run D CPU M-cycles ahead of what the CPU reads back. It ships at 0 and
# compiles out; the per-source leads (STAT_M2_LEAD here, STAT_M0_LEAD_T in
# gb.nim) are what ship.

when STAT_IRQ_SPLIT:
  # The STAT line is a level OR of the enabled sources into one edge detector
  # (Pan Docs, "STAT interrupt"), so a source may read a clock distinct from
  # the bits the CPU reads back. Each template picks which clock its source
  # reads; a source only moves when its own lead constant is on.
  template irq_mode_of(ppu: GbPpu): uint8 =
    when STAT_IRQ_LEAD != 0: ppu.irq_mode else: ppu.mode_flag
  # Mode 0 reads the irq clock when either lead is on. The 2 -> 3 hook needs no
  # gate: no term reads `irq_mode == 3`.
  template irq_m0_of(ppu: GbPpu): uint8 =
    when STAT_IRQ_LEAD != 0 or STAT_M0_LEAD_T != 0: ppu.irq_mode
    else: ppu.mode_flag
  template irq_m1_of(ppu: GbPpu): uint8 =
    when STAT_IRQ_LEAD != 0: ppu.irq_mode else: ppu.mode_flag
  template irq_ly_of(ppu: GbPpu): uint8 =
    when STAT_IRQ_LEAD != 0 or STAT_LYC_LEAD != 0: ppu.irq_ly else: ppu.ly
else:
  template irq_mode_of(ppu: GbPpu): uint8 = ppu.mode_flag
  template irq_m0_of(ppu: GbPpu): uint8 = ppu.mode_flag
  template irq_m1_of(ppu: GbPpu): uint8 = ppu.mode_flag
  template irq_ly_of(ppu: GbPpu): uint8 = ppu.ly

when not LCD_ON_TRIM_ANY:
  template gb_line_end*(ppu: GbPpu): int32 = 456'i32
else:
  template gb_line_end*(ppu: GbPpu): int32 =
    (case ppu.lcdon_lines
     of 2'u8: 456'i32 - LCD_ON_LINE0_TRIM
     of 1'u8: 456'i32 - LCD_ON_LINE1_TRIM
     else: 456'i32)

proc new_ppu_base(cgb: bool): GbPpu =
  result = GbPpu(
    lcd_control:  0x00,
    lcd_status:   0x80,
    first_line:   true,
    current_window_line: 0,
  )
  result.vram[0] = newSeq[uint8](0x2000)
  result.vram[1] = newSeq[uint8](0x2000)
  result.sprite_table = newSeq[uint8](0xA0)
  result.framebuffer  = newSeq[uint16](GB_WIDTH * GB_HEIGHT)
  result.bgp  = [0'u8, 0, 0, 0]
  result.obp0 = [0'u8, 0, 0, 0]
  result.obp1 = [0'u8, 0, 0, 0]
  if not cgb:
    cast[ptr uint16](addr result.pram[0])[]    = DMG_COLORS[0]
    cast[ptr uint16](addr result.pram[2])[]    = DMG_COLORS[1]
    cast[ptr uint16](addr result.pram[4])[]    = DMG_COLORS[2]
    cast[ptr uint16](addr result.pram[6])[]    = DMG_COLORS[3]
    cast[ptr uint16](addr result.obj_pram[0])[] = DMG_COLORS[0]
    cast[ptr uint16](addr result.obj_pram[2])[] = DMG_COLORS[1]
    cast[ptr uint16](addr result.obj_pram[4])[] = DMG_COLORS[2]
    cast[ptr uint16](addr result.obj_pram[6])[] = DMG_COLORS[3]
    cast[ptr uint16](addr result.obj_pram[8])[] = DMG_COLORS[0]
    cast[ptr uint16](addr result.obj_pram[10])[] = DMG_COLORS[1]
    cast[ptr uint16](addr result.obj_pram[12])[] = DMG_COLORS[2]
    cast[ptr uint16](addr result.obj_pram[14])[] = DMG_COLORS[3]
  # HDMA1-5 read back as $FF; the address counters hold the $FF the registers
  # would have been written with.
  result.hdma5    = 0xFF
  result.hdma_kill_from = -1
  # Anything non-zero: the first mode-0 edge after power-up is a real edge.
  result.hdma_seen_mode = 2
  result.hdma_src = 0xFFF0'u16
  result.hdma_dst = 0xFFF0'u16
  result.ran_bios = cgb

method reset_render_scratch*(ppu: GbPpu) {.base.} =
  ## Reset the renderer's per-line scratch. Save states do not serialize it
  ## (it is rebuilt at every mode 2 -> 3 edge and never read at vblank), so a
  ## rollback restore onto a RUNNING core must clear it here. The scanline
  ## renderer rebuilds per line and needs nothing.
  discard

method skip_boot*(ppu: GbPpu; gb: GB) {.base.} =
  # The HLE hand-off writes LCDC = $91 with LY still 0, which latches
  # window_trigger against WY = 0 and carries it into the first drawn frame
  # (gambatte window/*). The boot ROM ends in VBlank with the latch clear.
  ppu.window_trigger = false
  ppu.current_window_line = -1
  # Post-boot VRAM tiles: blank $00, the Nintendo logo $01-$18 decompressed
  # from the cart's own header, and the (R) tile $19.
  write_boot_logo(gb.cartridge.rom, ppu.vram[0])
  for i in 0 ..< POST_BOOT_RA_TILE.len:
    ppu.vram[0][0x190 + i] = POST_BOOT_RA_TILE[i]  # tile $19 = byte offset 400
  if not gb.cgb_enabled:
    # The DMG boot ROM's tile map: $9910 = tile $19, $992F..$9924 = $18..$0D,
    # $990F..$9904 = $0C..$01 (BullyGB initmap reads it back). The CGB map is
    # not seeded; nothing measures it.
    ppu.vram[0][0x1910] = 0x19
    for i in 0 ..< 12:
      ppu.vram[0][0x1904 + i] = uint8(0x01 + i)
      ppu.vram[0][0x1924 + i] = uint8(0x0D + i)
  if gb.cgb_enabled:
    # The CGB boot ROM hands off mid-VBlank. 161 is pinned by gambatte
    # display_startstate/stat_* (159..162) and by phase == 1 (mod 4), the same
    # PPU-dot-to-M-cycle offset the DMG's LCD_ON_HEAD_START gives.
    const phase = CGB_BOOT_PHASE
    ppu.ly = uint8(144 + phase div 456)
    ppu.cycle_counter = int32(phase mod 456)
    ppu.lcd_status = (ppu.lcd_status and not 3'u8) or 1'u8  # mode 1
    when STAT_IRQ_SPLIT:
      ppu.irq_mode = 1
      ppu.irq_ly = ppu.ly
    ppu.first_line = false
    when LCD_ON_TRIM_ANY: ppu.lcdon_lines = 0
    if not gb.cgb_native:
      # DMG cart on a CGB: the boot ROM fills palette 0 through BCPD/OCPD before
      # KEY0 locks the ports, and the cart can never write a colour again.
      for i in 0 ..< 4:
        cast[ptr uint16](addr ppu.pram[i * 2])[]      = CGB_COMPAT_BG_COLORS[i]
        cast[ptr uint16](addr ppu.obj_pram[i * 2])[]  = CGB_COMPAT_OBJ_COLORS[i]
        cast[ptr uint16](addr ppu.obj_pram[8 + i * 2])[] = CGB_COMPAT_OBJ_COLORS[i]
    else:
      # Pan Docs, "Console state after boot ROM hand-off": all BG colours are
      # white, and $FF bytes are equivalent to $7FFF. OBJ colours are
      # unspecified on hardware and get the same fill so states reproduce.
      # BullyGB leans on the boot ROM for BG palette 0 colours 0-2.
      for i in 0 ..< ppu.pram.len: ppu.pram[i] = 0xFF
      for i in 0 ..< ppu.obj_pram.len: ppu.obj_pram[i] = 0xFF
  elif gb.boot_model in {bmDmgABC, bmMgb}:
    # Pan Docs, "Console state after boot ROM hand-off": DMG/MGB hand off with
    # STAT = $85, LY = $00, i.e. inside line 153 after the LY snapback. The dot
    # is pinned to 397..400 by GBMicrotest poweron_* and to 1 mod 4 by mooneye
    # acceptance/ppu/hblank_ly_scx_timing-GS. GBMicrotest hblank_int_scx0..7
    # ask for 399 instead; 397 wins on the whole runner.
    ppu.ly = 0             # line 153, past the LY snapback
    ppu.cycle_counter = int32(DMG_BOOT_PHASE)
    ppu.lcd_status = (ppu.lcd_status and not 3'u8) or 1'u8  # mode 1
    when STAT_IRQ_SPLIT:
      ppu.irq_mode = 1
      ppu.irq_ly = ppu.ly
    ppu.first_line = false
    when LCD_ON_TRIM_ANY: ppu.lcdon_lines = 0
  elif gb.boot_model == bmDmg0:
    # DMG0 hands off mid-VBlank: the centre of mooneye boot_hwio-dmg0's passing
    # window (540..708).
    const phase = 624  # dots past the start of VBlank (line 144)
    ppu.ly = uint8(144 + phase div 456)
    ppu.cycle_counter = int32(phase mod 456)
    ppu.lcd_status = (ppu.lcd_status and not 3'u8) or 1'u8  # mode 1
    when STAT_IRQ_SPLIT:
      ppu.irq_mode = 1
      ppu.irq_ly = ppu.ly
    ppu.first_line = false
    when LCD_ON_TRIM_ANY: ppu.lcdon_lines = 0

# Bit 7 of GbPpu.read_mode: LY advanced during the M-cycle a read belongs to.
const LY_JUST_CHANGED* = 0x80'u8

# ---- LCDC helpers ----
proc lcd_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_control and 0x80) != 0

const DOTS_PER_FRAME* = 70224   # 154 lines x 456 dots
# Frontend pacing, not hardware: with the LCD off there is no refresh, and a
# re-enable restarts at line 0 so the next VBlank is 65664 dots away. Push a
# frame at the enable once this much time has passed since the last present,
# so a frame-paced frontend does not see a dropped frame on every toggle. No
# hardware quantity corresponds to the threshold (nothing is displayed while
# the LCD is off); any value up to one frame period paces the same, and ten
# lines is an arbitrary choice. No test ROM scores it.
const LCD_ON_FRAME_DOTS* = 10 * 456

when defined(gb_dot_counter):
  # Diagnostic frame-pacing instrumentation (tools only). gb_total_dots is the
  # panel's dot clock, 4194304 Hz, never scaled by double speed.
  var gb_total_dots*: uint64
  var gb_frame_normal*: uint64    # pushed at LY=144, PPU drew it
  var gb_frame_lcd_off*: uint64   # pushed by lcd_off_frame while LCD disabled
  var gb_frame_lcd_on*: uint64    # pushed by the LCDC-enable catch-up

when defined(gb_m3_trace) or defined(gb_px_trace):
  # Diagnostic mode-3 trace (tools only). Guarded on BOTH defines because
  # gb_traced/GB_TRACE_LY are shared with gb_px_trace. `-d:GB_TRACE_LY=-1`
  # traces every drawn line (a mealybug m3_* ROM sweeps one object down the
  # screen, so its reference is one measurement per 8-line band).
  const GB_TRACE_LY* {.intdefine.} = 20
  template gb_traced*(ly: untyped): bool = GB_TRACE_LY < 0 or int(ly) == GB_TRACE_LY

when defined(gb_m3_len):
  # Diagnostic (tools only): per-line mode 3 length next to the inputs Pan Docs
  # "Mode 3 length" says decide it.
  var gb_m3_len_lines*: int = 1_000_000

proc ppu_blank_frame*(ppu: GbPpu; gb: GB) =
  ## Push a frame the PPU did not draw: the panel shows white with the PPU
  ## switched off.
  let blank = if gb.cgb_enabled: 0x7FFF'u16 else: DMG_COLORS[0]
  for i in 0 ..< ppu.framebuffer.len: ppu.framebuffer[i] = blank
  ppu.frame = true
  ppu.dots_since_frame = 0

proc lcd_off_frame*(ppu: GbPpu; gb: GB) {.inline.} =
  ## Keep frames coming while the LCD is off: step_frame runs until ppu.frame
  ## is set, so a game that idles with the LCD off would otherwise never return.
  if ppu.dots_since_frame >= DOTS_PER_FRAME:
    when defined(gb_dot_counter): inc gb_frame_lcd_off
    if gb.sgb != nil:
      # SGB: the SNES side freezes the picture when the GB LCD turns off (Pan
      # Docs, SGB MASK_EN); keep presenting the last frame instead of white.
      ppu.frame = true
      ppu.dots_since_frame = 0
    else:
      ppu_blank_frame(ppu, gb)
proc window_tile_map*(ppu: GbPpu): uint8 {.inline.} = ppu.lcd_control and 0x40
proc window_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_control and 0x20) != 0

# Forward declarations; the bodies are in fifo_ppu.nim, which gb.nim includes
# after this file.
proc fifo_arm_window*(ppu: GbFifoPpu)

proc fifo_arm_scx*(ppu: GbFifoPpu)

when SCX_STORE_STALL_DOTS != 0:
  proc fifo_scx_store_stall*(ppu: GbFifoPpu; old_scx: uint8)

proc fifo_recompose_last*(ppu: GbFifoPpu; gb: GB; back: int32;
                          skip: int32 = 0) {.noinline.}
proc fifo_recompose_at*(ppu: GbFifoPpu; gb: GB; back: int32) {.noinline.}

proc fifo_obj_size_write*(ppu: GbFifoPpu; gb: GB) {.noinline.}

proc fifo_obj_abort*(ppu: GbFifoPpu; gb: GB)
when OBJ_ABORT != 0 and OBJ_ABORT_LATE:
  proc fifo_obj_abort_late*(ppu: GbFifoPpu; gb: GB)

template mixer_write_repaint(gb: GB; back: int32; latency: int32;
                             skip: int32 = 0'i32) =
  ## Tail of every register write the mixer reads. `back` = mixer-tail stages
  ## the register is read at (fifo_recompose_last), `latency` = the CGB's dot
  ## of write latency for that register, `skip` = pixels the caller already
  ## painted. `-d:MIXER_DOT_LAG=0` compiles the mixer's dot out (A/B control).
  when MIXER_DOT_LAG != 0:
    if gb.fifo_ppu != nil:
      let n = back - latency
      if n > 0: fifo_recompose_last(gb.fifo_ppu, gb, n, skip)

proc bg_window_tile_data*(ppu: GbPpu): uint8 {.inline.} = ppu.lcd_control and 0x10
proc bg_tile_map*(ppu: GbPpu): uint8 {.inline.} = ppu.lcd_control and 0x08
proc sprite_height*(ppu: GbPpu): int {.inline.} =
  if (ppu.lcd_control and 0x04) != 0: 16 else: 8
proc obj_height_at*(ppu: GbPpu; dot: int32): int {.inline.} =
  ## `sprite_height` as it stood on `dot`: lcdc2_flip holds the dots LCDC.2
  ## last changed on, so undoing every change later than `dot` walks it back.
  ## A future dot answers with the current value (see fifo_obj_size_write).
  var b = ppu.lcd_control and 0x04'u8
  if ppu.lcdc2_flip[0] > dot:
    b = b xor 0x04'u8
    if ppu.lcdc2_flip[1] > dot: b = b xor 0x04'u8
  if b != 0: 16 else: 8
proc sprite_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_control and 0x02) != 0
proc bg_display*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_control and 0x01) != 0

# ---- CPU access windows for VRAM and OAM ----
#
# VRAM is the PPU's for mode 3, OAM for modes 2 and 3; a blocked read answers
# $FF and a blocked write is dropped. The edges (mooneye acceptance/ppu/
# lcdon_timing-GS, lcdon_write_timing-GS): locks CLOSE on the live mode, one
# M-cycle before STAT reads the new mode, and OPEN with the `read_mode` latch.
# A write asks with the mode at the start of its M-cycle (mem_write applies it
# before the dots); a read asks both the latched and the live mode. On the
# first line after LCD-on every edge rounds to the STAT M-cycle (`first_line`).
const VRAM_READ_LIVE_LOCK* {.intdefine.} = 2
  ## Whether a CPU VRAM read also asks the LIVE mode: 1 everywhere, 0 never,
  ## 2 (ships) on a DMG only. See cpu_vram_open.

const LCD_ON_LINE0_LOCK_LEAD* {.intdefine.} = 2'i32
  ## Dots by which every mode edge on the LCD-enable line sits LATER, as the
  ## CPU's VRAM and OAM locks see it, than this renderer's counter puts it.
  ## Pinned to 2 by AGE vram/vram-read-* and oam/oam-read-*, which sample the
  ## same instant on line 0 and line 1 and differ by exactly 2 dots. Spent in
  ## the locks only: moving the geometry (LCD_ON_LINE0_TRIM, gb.nim) is refused
  ## by the STAT-read, interrupt and pixel families. 0 restores the old locks.

const VRAM_READ_M0_OPEN_DOTS* {.intdefine.} = 2
const VRAM_READ_M0_OPEN_DOTS_DS* {.intdefine.} = 3
  ## The VRAM read lock's OPEN edge, in PPU dots after the mode 3 -> 0 flag
  ## edge (`_DS` in double speed). 0 restores the pure `read_mode` snapshot,
  ## which opens a whole M-cycle late whenever the edge lands on a boundary.
  ## 2 at single speed: AGE vram/vram-read-* brackets it two-sided across SCX
  ## 0..7 and ten gambatte oam_access/vram_m3 postread rows agree. Double
  ## speed: gambatte vram_m3/postread_scx5_ds_1 (shut) and _ds_2 (open).

template lcdon_latched_mode(ppu: GbPpu; ds: bool): uint8 =
  ## `read_mode` on the LCD-on line with LCD_ON_LINE0_LOCK_LEAD undone at the
  ## 3 -> 0 edge: the snapshot flips on the first M-cycle past the flag edge,
  ## but on that line mode 3 has not really ended for LEAD more dots.
  block:
    var m = ppu.read_mode and 3'u8
    when LCD_ON_LINE0_LOCK_LEAD != 0:
      if ppu.first_line and m != 3'u8 and ppu.stat_prev_mode == 3'u8 and
         (ppu.lcd_status and 3'u8) == 0'u8 and
         ppu.cycle_counter - ppu.stat_chg_dot <
           (if ds: 2'i32 else: 4'i32) + 1 + LCD_ON_LINE0_LOCK_LEAD:
        m = 3'u8
    m

proc cpu_vram_open*(ppu: GbPpu; is_write: bool; cgb = false;
                    ds = false): bool {.inline.} =
  if not lcd_enabled(ppu): return true
  if is_write:
    # A write is applied before its M-cycle's dots (mem_write), so the live
    # mode is the mode at the start of that M-cycle.
    return (ppu.lcd_status and 3'u8) != 3
  if lcdon_latched_mode(ppu, ds) == 3:
    when VRAM_READ_M0_OPEN_DOTS != 0 or VRAM_READ_M0_OPEN_DOTS_DS != 0:
      var want = if ds: int32(VRAM_READ_M0_OPEN_DOTS_DS)
                 else: int32(VRAM_READ_M0_OPEN_DOTS)
      when LCD_ON_LINE0_LOCK_LEAD != 0:
        if ppu.first_line: want += LCD_ON_LINE0_LOCK_LEAD
      if want != 0 and (ppu.lcd_status and 3'u8) == 0'u8 and
         ppu.stat_prev_mode == 3'u8 and
         ppu.cycle_counter - ppu.stat_chg_dot >= want:
        return true
    when LCD_ON_LINE0_LOCK_LEAD != 0 and VRAM_READ_LIVE_LOCK != 0:
      # The CLOSE edge with the same lead: the CGB's close is the latched mode,
      # which flips the first M-cycle past dot 80, and on the LCD-on line mode
      # 3 has not really started for LEAD more dots (AGE vram-read-cgbBCE,
      # both speeds). The DMG's close is the live mode and nothing samples
      # inside its 2 dots.
      if cgb and ppu.first_line and (ppu.lcd_status and 3'u8) == 3'u8 and
         ppu.stat_prev_mode == 2'u8 and
         ppu.cycle_counter - ppu.stat_chg_dot <
           (if ds: 2'i32 else: 4'i32) + 1 + LCD_ON_LINE0_LOCK_LEAD:
        return true
    return false
  if ppu.first_line: return true
  # Both clauses are load-bearing. Dropping the live clause costs mooneye
  # lcdon_timing-GS on every DMG/SGB arm and GBMicrotest poweron_vram_{026,140}
  # and vram_read_l1_b; keeping it on a CGB costs gambatte dma/hdma_late_enable_1
  # and vram_m3/preread_2_dmg08_out3_cgb04c_out0, whose filename states the
  # device split. `cgb` is the console (gb.cgb_enabled), not the mode.
  when VRAM_READ_LIVE_LOCK == 0:
    true
  else:
    when VRAM_READ_LIVE_LOCK == 2:
      if cgb: return true
    (ppu.lcd_status and 3'u8) != 3

const CRAM_LOCK_R {.intdefine.} = 3
const CRAM_LOCK_W {.intdefine.} = 0
  ## Which edges the CGB palette-RAM (BCPD/OCPD) mode-3 lock asks on. R=3
  ## ships: the latched mode (one M-cycle later than the VRAM lock on the read
  ## side) plus the LCD-on line-0 exemption. Scored by gambatte cgbpal_m3 and
  ## enable_display/ly0_late_cgbp*. The write knob is inert on every cgbpal row.

proc cpu_cram_open*(ppu: GbPpu; is_write: bool): bool {.inline.} =
  ## CGB palette RAM belongs to the PPU during mode 3 (Pan Docs, Palettes):
  ## reads answer $FF, writes are dropped with the auto-increment still firing.
  ## Its edges are one M-cycle later than the VRAM lock's (gambatte cgbpal_m3).
  if not lcd_enabled(ppu): return true
  if is_write:
    when CRAM_LOCK_W == 0:
      # Line 0 after LCD-on does not lock (same exemption as the read side;
      # enable_display ly0_late_cgbpw_1 lands its write there).
      if ppu.first_line: return true
      return (ppu.lcd_status and 3'u8) != 3
    elif CRAM_LOCK_W == 1:
      return (ppu.read_mode and 3'u8) != 3
    else:
      return not ((ppu.read_mode and 3'u8) == 3 and
                  (ppu.lcd_status and 3'u8) == 3)
  when CRAM_LOCK_R == 0:
    if (ppu.read_mode and 3'u8) == 3: return false
    if ppu.first_line: return true
    return (ppu.lcd_status and 3'u8) != 3
  elif CRAM_LOCK_R == 1:
    return (ppu.read_mode and 3'u8) != 3
  elif CRAM_LOCK_R == 3:
    # The latched edge plus the LCD-on line-0 exemption (enable_display ly0_late_cgbp*).
    if ppu.first_line: return true
    return (ppu.read_mode and 3'u8) != 3
  else:
    return (ppu.lcd_status and 3'u8) != 3

const OAM_READ_M0_OPEN_DOTS* {.intdefine.} = 2
const OAM_READ_M0_OPEN_DOTS_DS* {.intdefine.} = 3
  ## The OAM read lock's OPEN edge, in PPU dots after the mode 3 -> 0 flag
  ## edge; the same quantity and value as VRAM_READ_M0_OPEN_DOTS. AGE
  ## oam/oam-read-* and vram/vram-read-* are one ROM with one address changed
  ## and give the same step function of SCX for both locks. CGB-E's lock opens
  ## one dot later (oam-read-cgbE; GbQuirks.oam_read_open_late, added at the
  ## use site); CGB-D is unmeasured and gets the C behaviour.

const OAM_READ_M3_CLOSE_DOTS* {.intdefine.} = 5'i32
  ## The OAM read lock's CLOSE edge at the start of mode 3, in dots after the
  ## 2 -> 3 flag edge; only reachable on the LCD-enable line (every other line
  ## has mode 2 holding OAM shut already). AGE oam/oam-read-* puts it at gap 5
  ## at both speeds; the `read_mode` snapshot gave 3 in double speed. 0
  ## restores the snapshot rule.

const OAM_WRITE_M2_TAIL {.intdefine.} = 1
  ## Whether an OAM write is still admitted on the M-cycle mode 2 ends in. Pan
  ## Docs says OAM is the PPU's for all of mode 2; mooneye lcdon_write_timing-GS
  ## and GBMicrotest oam_write_l1_c say the last M-cycle still takes a write.

proc cpu_oam_open*(ppu: GbPpu; is_write: bool; mcycle_dots: int32 = 0;
                   open_late = false; ds = false): bool {.inline.} =
  if not lcd_enabled(ppu): return true
  let live = ppu.lcd_status and 3'u8
  if is_write:
    # Same sample point as the VRAM write above: the live mode here is the mode
    # at the start of the write's own M-cycle.
    if live == 3: return false
    # The first line's OAM scan does not lock OAM at all (it is also the mode
    # that STAT reports as 0 -- see ppu_read 0xFF41).
    if ppu.first_line: return true
    when OAM_WRITE_M2_TAIL != 0:
      if live == 2:
        # Mode 2 always ends at dot 80 and the OAM scan releases the bus before
        # the CPU's write strobe, so "does this M-cycle span dot 80" is the
        # test. mcycle_dots is 4, or 2 in double speed. Exact for the FIFO
        # renderer; the scanline renderer can answer an M-cycle early here.
        return ppu.cycle_counter + mcycle_dots > 80
      return true
    else:
      return live != 2
  let lag = lcdon_latched_mode(ppu, ds)
  if lag == 3:
    when OAM_READ_M3_CLOSE_DOTS != 0:
      # Mode 3's own close edge, which only the LCD-on line reaches: on any
      # other line `live` has been 2 since dot 1.
      if ppu.first_line and live == 3'u8 and ppu.stat_prev_mode == 2'u8 and
         ppu.cycle_counter - ppu.stat_chg_dot < OAM_READ_M3_CLOSE_DOTS:
        return true
    when OAM_READ_M0_OPEN_DOTS != 0 or OAM_READ_M0_OPEN_DOTS_DS != 0:
      # The mode-0 open edge in dots off the flag edge (OAM_READ_M0_OPEN_DOTS).
      # `open_late` is CGB-E's extra dot, which makes this clause inert there.
      var want = (if ds: int32(OAM_READ_M0_OPEN_DOTS_DS)
                  else: int32(OAM_READ_M0_OPEN_DOTS)) + int32(ord(open_late))
      when LCD_ON_LINE0_LOCK_LEAD != 0:
        if ppu.first_line: want += LCD_ON_LINE0_LOCK_LEAD
      if live == 0'u8 and ppu.stat_prev_mode == 3'u8 and
         ppu.cycle_counter - ppu.stat_chg_dot >= want:
        return true
    return false
  if ppu.first_line: return true
  lag != 2 and live != 2 and live != 3

# ---- The DMG OAM corruption bug -------------------------------------------
# ---- The DMG OAM corruption bug (Pan Docs, "OAM Corruption Bug") ----------
#
# An `inc rr`/`dec rr` puts its operand on the address bus with no read or
# write asserted; in $FE00-$FEFF while the PPU owns OAM it scrambles the row
# the scan is on. Driven from the instructions, not the memory path: every
# instruction that can do it knows the address and which of its M-cycles each
# access falls on, so the CPU's OAM lock (cpu_oam_open) and mem_read/mem_write
# stay untouched. Per Pan Docs "Affected Operations":
#
#   inc/dec rr        M2: write, operand rr
#   ld [hl+/-],a      M2: write, address hl
#   ld a,[hl+/-]      M2: read+write, address hl
#   push/call/rst/int M2: write sp; M3: write sp-1; M4: write sp-2
#   pop rr, ret       M2: read+write sp; M3: read sp+1
#
# POP's lost glitched write is put on the second SP step: blargg 2-causes,
# 3-non_causes and 8-instr_effect leave no other assignment. PC in OAM is not
# modelled (hooking cpu_inc_pc buys a case nothing reaches).
#
# OAM is 20 rows of 8 bytes and mode 2 reads one row per M-cycle. The three
# patterns below are Pan Docs' formulas applied byte by byte.
type OamBugKind* = enum
  obWrite      ## a write, or a write and an IDU step in the same M-cycle
               ## ("this case behaves just like a single write")
  obRead       ## a read with no IDU step in the same M-cycle
  obReadWrite  ## a read and an IDU step in the same M-cycle

proc oam_bug_write_corrupt(ppu: GbPpu; row: int) =
  ## "Write Corruption": the first word of the row becomes
  ## `((a ^ c) & (b ^ c)) ^ c` where a is that word, b the first word and c the
  ## THIRD word of the preceding row; the other three words are copied from the
  ## preceding row.
  let dst = row shl 3
  let src = dst - 8
  for i in 0 .. 1:
    let a = ppu.sprite_table[dst + i]
    let b = ppu.sprite_table[src + i]
    let c = ppu.sprite_table[src + 4 + i]
    ppu.sprite_table[dst + i] = ((a xor c) and (b xor c)) xor c
  for i in 2 .. 7:
    ppu.sprite_table[dst + i] = ppu.sprite_table[src + i]

proc oam_bug_read_corrupt(ppu: GbPpu; row: int) =
  ## "Read Corruption": as the write corruption, with `b | (a & c)` for the
  ## first word instead.
  let dst = row shl 3
  let src = dst - 8
  for i in 0 .. 1:
    let a = ppu.sprite_table[dst + i]
    let b = ppu.sprite_table[src + i]
    let c = ppu.sprite_table[src + 4 + i]
    ppu.sprite_table[dst + i] = b or (a and c)
  for i in 2 .. 7:
    ppu.sprite_table[dst + i] = ppu.sprite_table[src + i]

proc oam_bug_read_write_corrupt(ppu: GbPpu; row: int) =
  ## "Read During Increase/Decrease": nothing for the first four rows or the
  ## last; otherwise the first word of the PRECEDING row becomes
  ## `(b & (a | c | d)) | (a & c & d)` (a: two rows before, b: preceding row,
  ## c: accessed row, d: third word of the preceding row) and the preceding
  ## row is then copied onto the accessed row and the one two before. The
  ## caller applies a normal read corruption on top.
  if row < 4 or row >= 19: return
  let cur = row shl 3
  let pre = cur - 8
  let two = cur - 16
  for i in 0 .. 1:
    let a = ppu.sprite_table[two + i]
    let b = ppu.sprite_table[pre + i]
    let c = ppu.sprite_table[cur + i]
    let d = ppu.sprite_table[pre + 4 + i]
    ppu.sprite_table[pre + i] = (b and (a or c or d)) or (a and c and d)
  for i in 0 .. 7:
    let v = ppu.sprite_table[pre + i]
    ppu.sprite_table[cur + i] = v
    ppu.sprite_table[two + i] = v

proc oam_bug_access*(gb: GB; kind: OamBugKind) {.noinline.} =
  ## One CPU-side access into the OAM page; the caller has checked the address.
  ## DMG family only (Pan Docs: CGB and AGB are not affected, even running
  ## monochrome software), so the test is on the console, not cgb_enabled.
  if gb.boot_model in {bmCgb0, bmCgbABCDE, bmAgb}: return
  let ppu = gb.ppu
  if not lcd_enabled(ppu): return
  when defined(gb_oam_trace):
    # -d:gb_oam_trace prints every OAM-address bus event while the LCD is on.
    echo "OAMBUG ly=", ppu.ly, " cc=", ppu.cycle_counter,
         " mode=", ppu.lcd_status and 3'u8, " fl=", ppu.first_line,
         " row=", (int(ppu.cycle_counter) + 3) shr 2, " kind=", kind
  if (ppu.lcd_status and 3'u8) != 2'u8: return
  # The LCD-on line's mode 2 does not lock OAM (cpu_oam_open); whether it
  # corrupts is not pinned by any blargg row, so follow the lock.
  if ppu.first_line: return
  # cycle_counter is the dot this M-cycle starts on (1-based in the FIFO
  # renderer) and the scan reads one row per four dots, so this M-cycle is on
  # row ceil(cc / 4). Rows 1..19 only: row 20 reaches dot 80, where the scan
  # has let go (blargg 4-scanline_timing test 5), and row 0 is Pan Docs'
  # "objects 0 and 1 are not affected". The absolute row assignment is pinned
  # by blargg 7-timing_effect's CRC ($7D792E7C). The scanline renderer's
  # counter restarts per mode, so there the window is one M-cycle out of phase.
  let row = (int(ppu.cycle_counter) + 3) shr 2
  if row <= 0 or row >= 20: return
  when defined(gb_oam_trace): echo "  -> corrupt row ", row
  case kind
  of obWrite: oam_bug_write_corrupt(ppu, row)
  of obRead:  oam_bug_read_corrupt(ppu, row)
  of obReadWrite:
    oam_bug_read_write_corrupt(ppu, row)
    oam_bug_read_corrupt(ppu, row)

template oam_bug_if*(gb: GB; address: uint16; kind: OamBugKind) =
  ## The inlined half: does this M-cycle put an OAM address on the bus?
  if (address and 0xFF00'u16) == 0xFE00'u16: oam_bug_access(gb, kind)

# ---- STAT helpers ----
proc coincidence_interrupt_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x40) != 0
proc oam_interrupt_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x20) != 0
proc vblank_stat_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x10) != 0
proc hblank_interrupt_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x08) != 0

# A STAT write's source-enable bits reach the interrupt line at the top of the
# write's M-cycle on DMG and two dots into it on CGB (STAT_ENABLE_LATENCY,
# gb.nim), while the rest of the store waits for the boundary. Spelled as a
# preview of the parked byte (deferred_reg/deferred_val) rather than an early
# store, so the readback, the DMG write glitch and FF55's slot are untouched.
when STAT_ENABLE_EARLY:
  proc stat_enables_leading(ppu: GbPpu; gb: GB): uint8 {.noinline.} =
    ## `lcd_status` with the parked STAT write's enable bits already in it, for
    ## the dots past this device's latency. `noinline` behind the caller's
    ## inlined `deferred_reg` test: a STAT write is parked once in thousands.
    let lat = int32(if gb.cgb_enabled: CGB_STAT_ENABLE_LATENCY
                    else: STAT_ENABLE_LATENCY) shr gb.memory.current_speed
    # One M-cycle's dots can straddle a line boundary, where `cycle_counter`
    # restarts at 0; one wrap is the whole correction.
    var elapsed = ppu.cycle_counter - int32(ppu.stat_wr_dot)
    if elapsed < 0: elapsed += ppu.gb_line_end
    if elapsed >= lat:
      (ppu.lcd_status and 0b1000_0111'u8) or
        (gb.memory.deferred_val and 0b0111_1000'u8)
    else:
      ppu.lcd_status

  template stat_enables_now(ppu: GbPpu; gb: GB): uint8 =
    (if gb.memory.deferred_reg == 0xFF41'u16: ppu.stat_enables_leading(gb)
     else: ppu.lcd_status)
else:
  template stat_enables_now(ppu: GbPpu; gb: GB): uint8 = ppu.lcd_status

proc coincidence_flag*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x04) != 0
proc `coincidence_flag=`*(ppu: GbPpu; on: bool) {.inline.} =
  if on: ppu.lcd_status = ppu.lcd_status or 0x04
  else:  ppu.lcd_status = ppu.lcd_status and not 0x04'u8
proc mode_flag*(ppu: GbPpu): uint8 {.inline.} = ppu.lcd_status and 0x03

const STAT_M0_LEAD_DS_D {.intdefine: "STAT_M0_LEAD_DS".} = STAT_M0_LEAD_T shr 1
const STAT_M0_LEAD_DS* = int32(STAT_M0_LEAD_DS_D)
  ## The mode-0 source's lead in double speed, in dots. Ships at the identity
  ## `STAT_M0_LEAD_T shr 1` (a double-speed T-cycle is half a dot). 0 turns
  ## AGE stat-interrupt/stat-int's double-speed odd-SCX cells green but moves
  ## the mode 3 -> 0 edge two gambatte `_ds_` rows measure; the defect is the
  ## double-speed dispatch grid sitting one dot late (CGB_LATENCY_CAP, gb.nim).

proc stat_irq_lead*(gb: GB): int32 {.inline.} =
  ## How far ahead of the mode flag the STAT interrupt line runs, in dots.
  ## STAT_IRQ_LEAD is in CPU M-cycles (4 dots, 2 in double speed); STAT_M0_LEAD_T
  ## is in T-cycles. The static assert says the two are never on at once.
  when STAT_IRQ_SPLIT:
    int32(STAT_DOMAIN_LEAD) * int32(4 shr gb.memory.current_speed) +
      (if gb.memory.current_speed == 1'u8: STAT_M0_LEAD_DS
       else: int32(STAT_M0_LEAD_T))
  else: 0'i32
static:
  doAssert STAT_M0_LEAD_T == 0 or (STAT_IRQ_LEAD == 0 and STAT_LYC_LEAD == 0),
    "STAT_M0_LEAD_T shares the irq domain's one lead: it cannot ride with " &
    "STAT_IRQ_LEAD or STAT_LYC_LEAD"

# ---- Where STAT's mode bits are sampled ------------------------------------
#
# mem_read ticks the M-cycle's dots and THEN reads, so the dot counter `cc` is
# where the read's M-cycle left it. With `m0` the first mode-0 dot, the read
# returns mode 0 iff `cc - m0 >= T`. T is bracketed two-sided at both speeds
# by ROMs that take no interrupt:
#
#   1x  GBMicrotest ppu_sprite0_scx0_a (T >= 2),
#       gambatte sprites/1spritesPrLine_m3stat_2 (T <= 2)
#   2x  gambatte sprites/1spritesPrLine_m3stat_ds_1 (T >= 3),
#       gambatte sprites/10spritesPrLine_m3stat_ds_2 (T <= 3)
#
# T goes UP one dot in double speed, so it is not a CPU T-cycle count: it is
# the half-dot a double-speed M-cycle boundary sits at against the PPU's dot
# grid, which `cycles shr current_speed` rounds away. Sweep with
# -d:STAT_READ_SAMPLE and -d:STAT_READ_SAMPLE_DS_ADD.

# On the first line after LCDC.7 goes high a STAT read returns the mode from
# two dots further back than on every other line. A read-path rule: AGE
# stat-mode/* reads line 0 at SCX 2, 3, 6, 7 as $83 where other lines read
# $80, and stat-mode-ds sees the other edge two dots late. Moving mode 3
# itself instead (-d:LCD_ON_M3_LATE=2) costs the line-0 access windows
# (GBMicrotest oam/vram_{read,write}_l0_*, mooneye lcdon_*_timing-GS) and the
# line-0 mode-0 source (GBMicrotest int_hblank_*).
const LCD_ON_STAT_READ_LAG* {.intdefine.}: int32 = 2
  ## Dots of extra STAT-read lag on the LCD-enable line; 0 compiles it out.

proc stat_m0_tail(ppu: GbPpu; gb: GB): int32 {.noinline.} =
  ## The 3 -> 0 field tail (STAT_M0_FIELD_TAIL) as this read sees it, charged
  ## at the read because an object fetch on the line and the read's own IO
  ## M-cycle both consume it. `noinline`: inlined into stat_read_mode it
  ## measured +0.25% of retired instructions on blargg cpu_instrs.
  if (ppu.lcd_status and 3'u8) != 0'u8 or ppu.stat_prev_mode != 3'u8:
    return 0'i32
  var tail = if gb.cgb_enabled: int32(STAT_M0_FIELD_TAIL_CGB)
             else: int32(STAT_M0_FIELD_TAIL)
  when STAT_M0_TAIL_SPEED_SCALED:
    # A CPU-clock quantity when it pays back a mode-3 end that moved with it
    # (gambatte sprites/*_m3stat_ds_1). Off by default; the shipping tail is 0.
    tail = tail shr gb.memory.current_speed
  when STAT_M0_TAIL_ANY and STAT_M0_FIELD_TAIL_ABSORB:
    if gb.fifo_ppu != nil:
      tail = max(0'i32, tail - gb.fifo_ppu.obj_dots_line)
  when STAT_M0_TAIL_MAX_MC != 0:
    # Which M-cycle of its own instruction this read is. Only the forms that
    # can address $FF41 need distinguishing; nothing else can be reading STAT.
    let io_mc = case gb.cpu.cur_opcode
                of 0xF0'u8: 3'i32          # LDH A,(n)
                of 0xFA'u8: 4'i32          # LD  A,(nn)
                else:       2'i32          # LD A,(C) / LD A,(HL)
    if io_mc > int32(STAT_M0_TAIL_MAX_MC): return 0'i32
  tail

proc stat_read_mode*(ppu: GbPpu; gb: GB): uint8 {.inline.} =
  ## The mode bits a CPU read of STAT returns: the mode in effect STAT_READ_SAMPLE
  ## dots back from where the read's M-cycle leaves the dot counter. Kept as a
  ## hold on the previous mode so nothing per-dot has to maintain it.
  var t = int32(STAT_READ_SAMPLE) +
          int32(STAT_READ_SAMPLE_DS_ADD) * int32(gb.memory.current_speed)
  when LCD_ON_STAT_READ_LAG != 0:
    if ppu.first_line: t += LCD_ON_STAT_READ_LAG
  when STAT_M0_TAIL_ANY:
    t += stat_m0_tail(ppu, gb)
  if ppu.cycle_counter - ppu.stat_chg_dot < t: ppu.stat_prev_mode
  else: ppu.lcd_status and 3'u8


# The dot within line 143 at which CGB raises the line-144 mode 2 STAT source.
# See m2_line144 below: 456 - 4 dots, i.e. one M-cycle before the line ends.
const M2_144_EARLY_DOT* = 452'i32

const M2_144_EARLY_DMG* {.booldefine.} = true
  ## Whether the DMG raises the line-144 OAM STAT source one M-cycle before the
  ## line ends, as the CGB does, FOR A RUNNING CPU. See m2_line144.

const M2_144_EARLY_DMG_HALT* {.booldefine.} = true
  ## ...and whether a HALTED DMG is blind to it, so its wake lands on the line
  ## boundary with the vblank interrupt. Inert at M2_144_EARLY_DMG = false.

template m2_144_early_active*(gb: GB): bool =
  ## Which consoles raise the line-144 OAM STAT source before the line ends.
  ## The skip target and the dot loop ask this WITHOUT the halt test so the
  ## rising dot is visited whatever the CPU is doing.
  when M2_144_EARLY_DMG: true
  else: gb.cgb_enabled

# ---- The OAM (mode 2) STAT source is a pulse, not a level -------------------
#
# High for the first few dots of a line, not for all of mode 2: the same
# source asserts entering vblank on line 144 where there is no mode 2
# (m2_line144), and GBMicrotest stat_write_glitch_l{0_c,1_d,154_c} un-mask it
# one M-cycle into mode 2 and hardware stays silent. gambatte m2enable and
# miscmstatirq sample it part-way through mode 2.
const STAT_M2_PULSE* {.intdefine.} = 3
  ## Last dot of a line on which the OAM STAT source is still high. -1 is the
  ## level-over-mode-2 model, -2 one CPU M-cycle instead of a dot count. 3 is
  ## pinned by gambatte m2enable/miscmstatirq and GBMicrotest oam_int_*; 4 is
  ## indistinguishable (nothing samples dot 4). Dots rather than an M-cycle
  ## because the PPU's clock does not change with the CPU's (Pan Docs, "Dots").

# ---- ...and it rises one CPU M-cycle before the line it belongs to --------
#
# GBMicrotest's sleds (int_oam_nops $94 vs $93, int_oam_incs, oam_int_nops_a,
# oam_int_inc_sled, lcdon_to_oam_int_l0/l1/l2) each read one M-cycle over while
# the LYC, vblank and hblank sleds are exact, and oam_int_if_edge_{a,b,c,d}
# bracket the rising edge two-sided. STAT_LYC_LEAD (gb.nim), the same question
# for the LYC source, is refused by the same instrument: int_lyc_nops,
# int_lyc_incs, int_lyc_halt and lcdon_to_lyc*_int are exact at 0.
const STAT_M2_LEAD* {.intdefine.} = 1
  ## CPU M-cycles the OAM STAT source comes up before the line boundary; 0
  ## compiles the mechanism out. One quantity spelled with M3_PIPE_AHEAD and
  ## LY0_PIPE_MCYCLES (fifo_ppu.nim), STAT_M0_FIELD_TAIL (gb.nim),
  ## M2_LEAD_HALT_BLIND (cpu.nim) and LYC_SETTLE_HALT_SKIP (gb.nim); none of
  ## them scores alone. M-cycles, not dots: a fixed dot 452 is two M-cycles
  ## early in double speed and every gambatte `_ds_` row says so. A halted CPU
  ## is blind to the lead (M2_LEAD_HALT_BLIND): mooneye intr_2_* wait with
  ## EI; HALT and their wilbertpol `_nops` twins do not.
const STAT_M2_EARLY_LY0* {.booldefine.} = false
  ## Line 0's pulse does not lead (line 153 scans no OAM): mooneye
  ## acceptance/ppu/intr_1_2_timing-GS.
const STAT_M2_LEAD_CGB* {.intdefine.} = 0
  ## CGB-only addition to STAT_M2_LEAD. The source's M-cycle is
  ## device-independent (GBMicrotest oam_int_if_edge_* put the CGB exact and
  ## the DMG one late); kept as the control for CGB_PIPE_MCYCLES, with which
  ## it is a matched pair on the mealybug corpus.
const STAT_M2_EARLY* = STAT_M2_LEAD != 0 or STAT_M2_LEAD_CGB != 0

template m2_lead_console_cgb*(gb: GB): bool =
  ## The console the lead is gated on; must match CGB_PIPE_MCYCLES's gate.
  ## Read off `gb`, not `fifo_ppu`: the scanline renderer reaches these readers
  ## with `gb.fifo_ppu == nil` (ppu_handle_stat_interrupt runs during
  ## skip_boot), and a nil guard in the dot loop costs +0.67% of retired
  ## instructions on cgb-acid-hell.
  gb.cgb_enabled

template m2_lead_mcycles*(gb: GB): int32 =
  ## The lead this console gets, in CPU M-cycles. Read through `gb` rather than
  ## latched on the PPU: a new GbPpu field shifts GbFifoPpu's hot state and
  ## measured +2.2% of retired instructions on cgb-acid-hell.
  when STAT_M2_LEAD_CGB == 0:
    int32(STAT_M2_LEAD)
  else:
    int32(STAT_M2_LEAD) +
      (if m2_lead_console_cgb(gb): int32(STAT_M2_LEAD_CGB) else: 0'i32)

template m2_early_dot*(ppu: GbPpu; gb: GB): int32 =
  ## The dot of the outgoing line the source comes up on.
  gb_line_end(ppu) - m2_lead_mcycles(gb) * int32(4 shr gb.memory.current_speed)

proc m2_early*(ppu: GbPpu): bool {.inline.} =
  ## Is this line's tail handing over to a line that scans OAM? Mode 0 on
  ## 0..142, and mode 1 with LY already 0 (line 153). Line 143 -> 144 is
  ## m2_line144's, on its own measurement.
  let m = ppu.lcd_status and 3'u8
  (m == 0'u8 and ppu.ly < 143'u8) or
    (STAT_M2_EARLY_LY0 and m == 1'u8 and ppu.ly == 0'u8)

template m2_lead_active*(gb: GB): bool =
  ## Is the lead nonzero for THIS console? At a lead of 0 the rising dot is
  ## gb_line_end, so without this `m2_source` would answer off `m2_early` on
  ## the last dot of every DMG line (moves GBMicrotest lyc1_write_timing_d).
  when STAT_M2_LEAD != 0: true
  elif STAT_M2_LEAD_CGB != 0: m2_lead_console_cgb(gb)
  else: false

template m2_early_stop*(ppu: GbPpu; gb: GB): bool =
  ## The skip target's half of the same question, so the dot loop visits the
  ## rising dot. Folds to `false` when the rise is on the boundary.
  when STAT_M2_EARLY: m2_lead_active(gb) and ppu.m2_early
  else: false

proc m2_source*(ppu: GbPpu; gb: GB): bool {.inline.} =
  when STAT_M2_EARLY:
    if m2_lead_active(gb) and ppu.cycle_counter >= ppu.m2_early_dot(gb):
      return ppu.m2_early
  when STAT_M2_PULSE == -1: ppu.irq_mode_of == 2
  elif STAT_M2_PULSE == -2:
    ppu.irq_mode_of == 2 and ppu.cycle_counter < int32(4 shr gb.memory.current_speed)
  else: ppu.irq_mode_of == 2 and ppu.cycle_counter <= int32(STAT_M2_PULSE)

const M2_144_PULSE* {.booldefine.} = true
  ## Whether the line-144 assertion of the OAM source is a pulse of width
  ## STAT_M2_PULSE rather than a level held for the line. wilbertpol
  ## acceptance/gpu/stat_write_if samples it part-way through line 144 (-C
  ## subtests 9, 29, 68; -GS 66-70) and wants the line low again.
proc m2_144_within_pulse(ppu: GbPpu; gb: GB): bool {.inline.} =
  when not M2_144_PULSE: true
  elif STAT_M2_PULSE == -1: true
  elif STAT_M2_PULSE == -2:
    ppu.cycle_counter < int32(4 shr gb.memory.current_speed)
  else: ppu.cycle_counter <= int32(STAT_M2_PULSE)

template m2_144_fall_dot*(gb: GB): int32 =
  ## The first dot of line 144 the source is low again. Nothing else happens
  ## on it, so the renderer runs the edge detector there explicitly; the idle
  ## skip already stops inside the first LYC_RELATCH_DOT dots of a mode-1 line.
  when STAT_M2_PULSE == -2: int32(4 shr gb.memory.current_speed)
  else: int32(STAT_M2_PULSE) + 1

proc m2_line144*(ppu: GbPpu; gb: GB): bool {.inline.} =
  ## Is the OAM STAT source asserted by the start of vblank? It goes high once
  ## more per frame entering line 144: with the vblank interrupt on DMG
  ## (mooneye vblank_stat_intr-GS), one M-cycle earlier on CGB (-C). The DMG
  ## reading is a HALTED one: GBMicrotest line_144_oam_int_{a..d} read IF off a
  ## running sled and see the source up the M-cycle before, so the early dot is
  ## a running-CPU rule and a halted DMG is blind to it (M2_144_EARLY_DMG_HALT).
  ## Asked in the flag domain: the pulse is pinned to the vblank interrupt,
  ## which does not lead.
  if ppu.ly == 144:
    ppu.mode_flag == 1 and m2_144_within_pulse(ppu, gb)
  elif ppu.ly == 143:
    ppu.mode_flag == 0 and ppu.cycle_counter >= M2_144_EARLY_DOT and
      (when M2_144_EARLY_DMG and M2_144_EARLY_DMG_HALT:
         gb.cgb_enabled or not gb.cpu.halted
       else: m2_144_early_active(gb))
  else:
    false

# ---- The LY 153 -> 0 snapback, and the comparator's blind window -----------
#
# Both are dots into line 153. LY153_SNAP_DOT is LY's own edge. LYC_SETTLE_DOTS
# is the read path's LY_JUST_CHANGED rule applied to the same edge: the
# comparator is blind for one M-cycle after any LY change (mooneye
# lcdon_timing-GS wants bit 2 clear at the line 0 -> 1 advance for LYC=1 AND
# LYC=0), and the snapback is an LY change like any other. Pinned by
# GBMicrotest line_153_lyc153_stat_timing_* (near side) and
# line_153_lyc0_stat_timing_* (far side), gambatte ly0/lycint152_lyc0{flag,irq}_*
# on both devices and in double speed, and daid ppu_scanline_bgp (pixel-exact
# only with SNAP + SETTLE = 9). A fixed dot count, not `4 shr current_speed`:
# the comparator is on the PPU's clock (Pan Docs, "Dots"). daid is halted where
# the others run a sled; LYC_SETTLE_HALT_SKIP (gb.nim) reconciles them. Not
# device-split: gambatte's `_dmg08_cgb04c_` ly0 filenames carry one value, and
# a sweep breaks `[cgb]` ly0 rows on both sides of 9.
const LY153_SNAP_DOT_D {.intdefine: "LY153_SNAP_DOT".} = 5
const LYC_SETTLE_DOTS_D {.intdefine: "LYC_SETTLE_DOTS".} = 4
const LY153_SNAP_DOT* = int32(LY153_SNAP_DOT_D)
const LYC_SETTLE_DOTS* = int32(LYC_SETTLE_DOTS_D)
const LYC_RELATCH_DOT* = LY153_SNAP_DOT + LYC_SETTLE_DOTS
# The dot from which a $FF44 read sees the snapback, where that differs from
# the dot the comparator and the STAT source see it on. `cycle_counter` is the
# NEXT dot to be processed, so the identity is LY153_SNAP_DOT + 1, not
# LY153_SNAP_DOT.
const LY153_READ_SNAP_D {.intdefine: "LY153_READ_SNAP".} = LY153_SNAP_DOT_D
const LY153_READ_SNAP_CGB_D {.intdefine: "LY153_READ_SNAP_CGB".} =
  LY153_SNAP_DOT_D + 1
const LY153_READ_SNAP* = int32(LY153_READ_SNAP_D)
const LY153_READ_SNAP_CGB* = int32(LY153_READ_SNAP_CGB_D)
const LY153_READ_SPLIT* = LY153_READ_SNAP != LY153_SNAP_DOT + 1 or
                          LY153_READ_SNAP_CGB != LY153_SNAP_DOT + 1
  ## DMG 5 / CGB 6 (the identity). GBMicrotest line_153_ly_{a,b,c,d} read LY
  ## off a sled through the 152 -> 153 -> 0 turn; the DMG's readable LY sat at
  ## 153 one M-cycle too long. 2..5 is one flat M-cycle; 1 collapses the
  ## LY = 153 window (wilbertpol ly00_* poll with `cp 153`). CGB 0/A/B/C take
  ## the DMG value at single speed only; D/E/AGB, and every CGB in double
  ## speed, keep the identity (GbQuirks.ly_read_edge_late, gb.nim; AGE
  ## ly/ly-dmgC-cgbBC's double-speed half wants the late edge).

# ---- LY is read while it ripples: $FF44 on the advance dot = old AND new ----
#
# AGE lcd-align-ly.inc: "glitch: LY & (LY + 1)". Invisible on even LY; 1 -> 2
# and 153 -> 0 read $00, 143 -> 144 reads $80. The window is the single dot
# `cycle_counter == gb_line_end`, plus the dot before on CGB 0/A/B/C at single
# speed only (lcd-align-ly-cgbBC and -cgbE differ in exactly that row), the
# same early-silicon shape as LY153_READ_SNAP_CGB.
const LY_EDGE_AND_D {.intdefine: "LY_EDGE_AND".} = 1
const LY_EDGE_AND* = LY_EDGE_AND_D != 0
  ## Compile the ripple out for an A/B. At 0 the four `lcd-align-ly` glitch
  ## cells come back and nothing else in the tree moves.

proc ly_edge_rippling*(ppu: GbPpu; gb: GB): bool {.inline.} =
  ## Is this $FF44 read landing on the dot LY advances on? Branch-light: every
  ## LY poll comes through here and the common answer is one compare.
  when not LY_EDGE_AND: false
  else:
    ppu.cycle_counter >= gb_line_end(ppu) - 1'i32 and
      (ppu.cycle_counter == gb_line_end(ppu) or
       not (gb.cgb_enabled and (gb.quirks.ly_read_edge_late or
                                gb.memory.current_speed == 1'u8)))

proc lyc_settling*(ppu: GbPpu): bool {.noinline.} =
  ## Is the comparator inside the snapback's blind window? Stateless on
  ## purpose: a save state in the window would need a field nothing else can
  ## rebuild. `noinline`, with the caller leading on `ly == 0`: three compares
  ## inlined into `mode_flag=` put the mode-3 dot loop over clang's inline
  ## threshold (0.29% of retired instructions on Pokemon Crystal).
  ppu.mode_flag == 1'u8 and ppu.ly == 0'u8 and
    ppu.cycle_counter >= LY153_SNAP_DOT and
    ppu.cycle_counter < LYC_RELATCH_DOT

# ---- The snapback's blind window is a READ rule; the SOURCE leaves it early --
#
# The readable coincidence bit and the STAT source do not come back together:
# the source returns one CPU M-cycle before the bit. GBMicrotest
# line_153_lyc0_int_inc_sled (1122 `inc a` after `ei`) reads it out. One
# M-cycle, not four dots: gambatte's `_ds_` ly0/lycEnable arms step by exactly
# the M-cycle a flat four overshoots them by.
const LYC_SRC_RELATCH_LEAD* {.intdefine.} = 1
  ## CPU M-cycles by which the LY = LYC STAT source leaves the snapback's blind
  ## window before the readable bit does; 0 compiles the split out.

proc lyc_src_relatch_dot*(gb: GB): int32 {.inline.} =
  ## The dot of line 153 the LY = LYC STAT source relatches on; folds to
  ## LYC_RELATCH_DOT at a lead of 0.
  when LYC_SRC_RELATCH_LEAD == 0: LYC_RELATCH_DOT
  else:
    LYC_RELATCH_DOT -
      int32(LYC_SRC_RELATCH_LEAD) * int32(4 shr gb.memory.current_speed)

proc lyc_settle_halt_skip(gb: GB): bool {.inline.} =
  ## Is this CPU one the snapback's blind window does not defer? See
  ## LYC_SETTLE_HALT_SKIP in gb.nim. Folds to `false` at the shipping default.
  when LYC_SETTLE_HALT_SKIP: gb.cpu.halted
  else: false

# ---- The MODE 0 source's rise is invisible to a HALTED CPU for 2 T-cycles ---
#
# GBMicrotest ships the halted and running arm of one ROM: int_hblank_nops_scx*
# steps at SCX 1 and 5, int_hblank_halt_scx* at 3 and 7, so the halted wake is
# 2 dots behind the running dispatch. Half an M-cycle, i.e. a latch position
# (HALT_IF_SAMPLE_T = 2, cpu.nim), scaled by the CPU's clock. It only cancels
# correctly with STAT_M0_LEAD_T = 2 (the mode-0 SOURCE 2 dots ahead of the
# flag, carried in the retire -> flag hand-off in fifo_ppu.nim): mooneye
# acceptance/ppu/hblank_ly_scx_timing-GS is halted and lives where the two
# cancel, while GBMicrotest hblank_int_scx* and friends READ STAT and refuse
# any move of the readable 3 -> 0 edge (M3_END_EARLY).
#
# The window is measured from the source's own `irq_chg_dot`, not the field's
# `stat_chg_dot`; measured from the field it lands two dots late and
# hblank_ly_scx_timing-GS goes red on all eight arms.
#
# A DMG rule. wilbertpol's -C / -GS pair asks the same 32 questions of both
# devices with different expected tables: the CGB's halted latch is not blind
# at single speed (the staircase drops at SCX 3 and 7, not 1 and 5) and is
# blind for one dot in double speed (gambatte halt/m0{int,irq}_m0stat_scx3_ds_2,
# two-sided). gambatte irq_precedence/hdma_vs_m0_scx2_halt goes red with it:
# that family needs a halted/running split in the HDMA-vs-mode-0 arbitration
# this does not reach.
const M0_HALT_BLIND_DOTS* {.intdefine.} = 2
  ## T-cycles of a halted M-cycle's tail in which the mode-0 STAT source's
  ## rise is invisible to the halted CPU's latch; 0 compiles it out. DMG only.
const CGB_M0_HALT_BLIND_DOTS* {.intdefine.} = 0
  ## The CGB's single-speed value, in DOTS (not scaled). Saturates at 0.
const CGB_M0_HALT_BLIND_DS_DOTS* {.intdefine.} = 1
  ## And the CGB's double-speed value, in DOTS. Bracketed on both sides at 1.

when M0_HALT_BLIND_DOTS > 0 or CGB_M0_HALT_BLIND_DOTS > 0 or
     CGB_M0_HALT_BLIND_DS_DOTS > 0:
  proc halt_m0_tail_blind*(gb: GB): bool {.noinline.} =
    ## Is the interrupt line up ONLY because the mode-0 STAT source rose in the
    ## tail of this halted M-cycle? `noinline`, reached only from behind
    ## `result` in cpu_halt_tick. Same approximation as halt_m2_lead_blind: a
    ## STAT bit raised earlier and re-masked by an IE write would defer too.
    let irq = gb.interrupts
    if not (irq.lcd_stat_interrupt and irq.lcd_stat_enabled): return false
    if (irq.vblank_interrupt and irq.vblank_enabled) or
       (irq.timer_interrupt  and irq.timer_enabled)  or
       (irq.serial_interrupt and irq.serial_enabled) or
       (irq.joypad_interrupt and irq.joypad_enabled): return false
    let ppu = gb.ppu
    if not (ppu.lcd_enabled and ppu.hblank_interrupt_enabled): return false
    # With STAT_M0_LEAD_T on the line can be up on the source's mode 0 while
    # the readable field is still 3, and it is the SOURCE this rule is about.
    when STAT_M0_LEAD_T != 0:
      if ppu.irq_m0_of != 0'u8: return false
    else:
      if (ppu.lcd_status and 3'u8) != 0'u8: return false
    # The comparator would be holding the line up on its own.
    if ppu.coincidence_interrupt_enabled and ppu.irq_ly_of == ppu.lyc:
      return false
    # Ages 1..N, not 0..N-1: the halted M-cycle's dots run before this latch,
    # so cycle_counter is one past them (GBMicrotest int_hblank_halt_scx{3,7}
    # place it). With STAT_M0_LEAD_T on the source rose `lead` dots before the
    # field did, so the age is measured from irq_chg_dot.
    when STAT_M0_LEAD_T != 0:
      let age = ppu.cycle_counter - int32(ppu.irq_chg_dot)
    else:
      let age = ppu.cycle_counter - ppu.stat_chg_dot
    let blind =
      if gb.cgb_enabled:
        if gb.memory.current_speed != 0: int32(CGB_M0_HALT_BLIND_DS_DOTS)
        else: int32(CGB_M0_HALT_BLIND_DOTS)
      else: int32(M0_HALT_BLIND_DOTS shr gb.memory.current_speed)
    age >= 1'i32 and age <= blind

proc ppu_handle_stat_interrupt*(ppu: GbPpu; gb: GB) =
  # With the PPU off the comparator is stopped: the coincidence bit freezes and
  # no STAT interrupt fires (mooneye stat_lyc_onoff).
  if not ppu.lcd_enabled:
    return
  # The comparator is blind for the M-cycle the LY 153 -> 0 snapback falls in,
  # on both sides of the comparison (lyc_settling). Blind, not held: holding
  # the pre-snap value costs three gambatte rows. Every other LY advance opens
  # the same window, spelled at ly_advance_open.
  # `ly == 0` first, in line; the rest behind the call (see lyc_settling).
  let settling = ppu.ly == 0'u8 and ppu.lyc_settling and
                 not lyc_settle_halt_skip(gb)
  # The readable bit follows the readable LY; the SOURCE below follows irq_ly,
  # one M-cycle ahead of it (gambatte lycint_lycflag times the two apart).
  ppu.coincidence_flag = ppu.ly == ppu.lyc and not settling
  # CGB D and later HOLD the comparison the window is leaving (LYC == 153)
  # instead of clearing it: wilbertpol ly_lyc_153-C reads STAT on that M-cycle
  # (quirks.lyc_compare_hold). `settling` first so no field read sits in front
  # of the branch the mode-3 dot loop pays for.
  if settling and ppu.lyc == 153'u8 and gb.quirks.lyc_compare_hold:
    ppu.coincidence_flag = true
  # The SOURCE leaves the blind window LYC_SRC_RELATCH_LEAD M-cycles early.
  # Spelled as `not settling or <dot>` so nothing extra is live across the
  # source terms: this is inlined into `mode_flag=`, inside the mode-3 dot loop.
  template src_settled(): bool =
    when LYC_SRC_RELATCH_LEAD == 0: not settling
    else: not settling or ppu.cycle_counter >= lyc_src_relatch_dot(gb)
  let en = ppu.stat_enables_now(gb)
  let stat_flag =
    (ppu.irq_ly_of == ppu.lyc and (en and 0x40'u8) != 0 and
     src_settled()) or
    (ppu.m2_source(gb)        and (en and 0x20'u8) != 0) or
    # The OAM source also asserts entering vblank; see m2_line144.
    ((en and 0x20'u8) != 0    and ppu.m2_line144(gb)) or
    (ppu.irq_m0_of == 0       and (en and 0x08'u8) != 0) or
    (ppu.irq_m1_of == 1       and (en and 0x10'u8) != 0)
  if not ppu.old_stat_flag and stat_flag:
    when defined(gb_stat_read_trace):
      echo "STATIRQ ly=", ppu.ly, " cc=", ppu.cycle_counter,
           " mode=", ppu.mode_flag
    when defined(gb_phase_trace):
      echo "STATIRQ ly=", ppu.ly, " cc=", ppu.cycle_counter,
           " t=", gb_phase, "/", gb_ticklen, " mode=", ppu.mode_flag
    when defined(gb_stat_src_trace):
      # Diagnostic (tools only): which of the terms above took the line high.
      # Printed as a set, because a handover can raise two at once.
      echo "STATSRC ly=", ppu.ly, " cc=", ppu.cycle_counter,
           " lyc=", (if ppu.irq_ly_of == ppu.lyc and
                        ppu.coincidence_interrupt_enabled and src_settled(): 1
                     else: 0),
           " m2=", (if ppu.m2_source(gb) and ppu.oam_interrupt_enabled: 1
                    else: 0),
           " m2v=", (if ppu.oam_interrupt_enabled and ppu.m2_line144(gb): 1
                     else: 0),
           " m0=", (if ppu.irq_mode_of == 0 and ppu.hblank_interrupt_enabled: 1
                    else: 0),
           " m1=", (if ppu.irq_mode_of == 1 and ppu.vblank_stat_enabled: 1
                    else: 0),
           " stat=", toHex(ppu.lcd_status, 2), " lycreg=", ppu.lyc
    gb.interrupts.lcd_stat_interrupt = true
  ppu.old_stat_flag = stat_flag

# ---- An ordinary LY advance is an edge the STAT line has to see too ---------
#
# The line boundary moves LY and the mode at once; a level OR asked once after
# both moved cannot see one source hand the line to another. gambatte's
# lcdirq_precedence family (31 ROMs) and m2enable/enable_after_lycint_1 fix the
# order: the LY=LYC comparator answers nothing while LY is changing -- it
# drops before LY moves and comes back after the mode has moved -- and the OAM
# pulse sits INSIDE that window (a rendered line starting is the instant the
# comparator lets go) while the mode 1 source and m2_line144's pulse land
# after it. The window lives inside the boundary dot, so no interrupt's
# arrival moves (gambatte lycEnable/lycm2int and mooneye intr_2_* refuse a
# one-M-cycle window). It can only ADD an edge, never lose one.
#
# A CPU write to LYC/STAT/LCDC parked in the same M-cycle already has its own
# instant at the boundary (mem_flush_deferred); running the glitch as well
# counts one input change twice (gambatte lycEnable/ff45_enable_weirdpoint).
#
# Spelled as the LYC enable bit rather than a `ly_changing` flag: the flag's
# extra field read reaches the mode-3 dot loop through `mode_flag=` and costs
# +1.19% of retired instructions on Pokemon Crystal; the enable bit is already
# loaded. The readable coincidence bit does not dip (that is LY_JUST_CHANGED).
proc ly_advance_open*(ppu: GbPpu): uint8 {.inline.} =
  ## The comparator lets go; returns what to put back. Zero if a CPU write to
  ## LYC/STAT/LCDC is parked for this M-cycle (see above).
  if ppu.stat_write_pending: return 0'u8
  result = ppu.lcd_status and 0x40'u8
  ppu.lcd_status = ppu.lcd_status and 0b1011_1111'u8

proc ly_advance_close*(ppu: GbPpu; gb: GB; lyc_en: uint8) {.inline.} =
  ## The far side: the mode has moved, so the comparator answers again and a
  ## match that has just become true raises the line here.
  ppu.lcd_status = ppu.lcd_status or lyc_en
  ppu_handle_stat_interrupt(ppu, gb)

proc ppu_stat_write_glitch*(ppu: GbPpu; gb: GB) =
  ## The DMG STAT-write bug (Pan Docs, "Spurious STAT interrupts"): the write
  ## behaves as if $FF were written for one M-cycle, un-masking whichever
  ## source the PPU is in. Console-gated: the GBC in DMG mode does not have it.
  ## The window sits at the write's commit point, not the M-cycle boundary:
  ## GBMicrotest stat_write_glitch_l1_a/l143_a write on the M-cycle the 3 -> 0
  ## edge falls in and stay silent. The OAM source is deliberately not in the
  ## set: l0_c, l1_d, l154_c write one M-cycle into mode 2 and stay silent,
  ## while adding m2_source here costs eleven gambatte m2enable rows.
  if not ppu.lcd_enabled: return
  if ppu.old_stat_flag: return
  if ppu.ly == ppu.lyc or ppu.mode_flag == 0 or ppu.mode_flag == 1:
    when defined(gb_stat_read_trace):
      echo "STATGLITCH ly=", ppu.ly, " cc=", ppu.cycle_counter,
           " mode=", ppu.mode_flag
    gb.interrupts.lcd_stat_interrupt = true
    ppu.old_stat_flag = true

proc ppu_flush_stat_write*(ppu: GbPpu; gb: GB) =
  ## Take the STAT edge a CPU write to LCDC/STAT/LYC left pending. mem_write
  ## calls this on the following M-cycle boundary; the write_byte callers that
  ## are not an M-cycle (post-boot table, cheat pokes) call it directly.
  if ppu.stat_write_pending:
    ppu.stat_write_pending = false
    ppu_handle_stat_interrupt(ppu, gb)

proc ppu_flush_hdma_bytes*(ppu: GbPpu; gb: GB) =
  ## Land a block whose bytes were held back (HDMA_VISIBLE_DOTS), whether or
  ## not its dots have run.
  if not ppu.hdma_bytes_held: return
  ppu.hdma_bytes_held = false
  for byte in 0 ..< 0x10:
    gb.memory.write_byte(gb, int(ppu.hdma_held_dst) + byte, ppu.hdma_held[byte])

proc ppu_land_hdma_if_due*(ppu: GbPpu; gb: GB) {.noinline.} =
  ## Land a held block if its dots have run. Checked at the points VRAM can be
  ## observed (CPU VRAM access, next mode change) rather than counted per tick:
  ## nothing else can see VRAM in between, and a per-tick test is +1.36% of
  ## retired instructions on Pokemon Crystal.
  let cc = ppu.cycle_counter
  # `cc < hold_from` is the line having wrapped under the hold; no HBlank block
  # can reach it, but it must expire the hold rather than strand it.
  if cc >= ppu.hdma_hold_until or cc < ppu.hdma_hold_from:
    ppu_flush_hdma_bytes(ppu, gb)

proc ppu_charge_hdma_overhead(ppu: GbPpu; gb: GB) {.inline.} =
  ## The bus acquire/release either side of a VRAM DMA: once per TRANSFER, on
  ## the CPU's clock. See HDMA_BLOCK_OVERHEAD_BUS in gb.nim.
  when HDMA_BLOCK_OVERHEAD_BUS != 0:
    mem_tick_components(gb.memory, gb, HDMA_BLOCK_OVERHEAD_BUS, from_cpu = false)

proc ppu_copy_hdma_block*(ppu: GbPpu; gb: GB; in_cpu_cycle = false;
                          charge_overhead = true): bool =
  ## One $10-byte block from where the address counters stand. Returns false
  ## if the destination counter overflowed. `in_cpu_cycle` says the copy runs
  ## inside the dots of a CPU access that has not sampled its byte yet, so the
  ## bytes are held back HDMA_VISIBLE_DOTS dots; nothing else moves with them.
  #
  # Pan Docs, FF53-FF54: only bits 12-4 of the destination are respected. That
  # is a mask on the address the counter drives, not on the counter: gambatte
  # dma/dma_dst_wrap's pair differ only in a bit VRAM cannot see, and the one
  # whose counter would step off $FFF0 stops instead of wrapping. Both ends
  # are resolved once per block (a block is 16 aligned bytes).
  let src_base = int(ppu.hdma_src)
  let dst_base = 0x8000 or int(ppu.hdma_dst and 0x1FF0'u16)
  # Pan Docs, FF51-FF52: the source is $0000-$7FF0 or $A000-$DFF0. Outside
  # that the transfer moves $FF (gambatte dma/dma_hiram_read_result). Decided
  # per block: a block cannot straddle a region boundary.
  let src_legal = src_base < 0x8000 or (src_base >= 0xA000 and src_base < 0xE000)
  let hold = HDMA_VISIBLE_DOTS != 0 and in_cpu_cycle
  # Never two blocks in the buffer at once; defensive only.
  if hold: ppu_flush_hdma_bytes(ppu, gb)
  # The external bus is the VRAM DMA's for the whole copy: an OAM DMA slot
  # inside it stores the VRAM DMA's byte (VDMA_OAM_BUS_CAPTURE, gb.nim).
  when VDMA_OAM_BUS_CAPTURE != 0:
    let vdma_bus_was = gb.memory.vdma_bus_hold
    gb.memory.vdma_bus_hold = true
  when HDMA_OVERHEAD_LEADS != 0:
    if charge_overhead: ppu_charge_hdma_overhead(ppu, gb)
  for byte in 0 ..< 0x10:
    let val = if src_legal: gb.memory.read_byte(gb, src_base + byte) else: 0xFF'u8
    if hold: ppu.hdma_held[byte] = val
    else:    gb.memory.write_byte(gb, dst_base + byte, val)
    # Two dots per byte on the PPU axis at either speed (gambatte
    # dma/hdma_start_ds_*), i.e. four CPU-clock cycles per byte in double
    # speed (Pan Docs, CGB Registers): a block stalls 8 M-cycles at normal
    # speed and 16 fast M-cycles in double.
    mem_tick_bus(gb.memory, gb, 2 shl int(gb.memory.current_speed),
                 from_cpu = false)
    mem_tick_ppu(gb.memory, gb, 2, ignore_speed = true)
    # An in-flight OAM DMA latches the external bus at the end of each machine
    # M-cycle, four scheduler cycles at either speed. Read off the scheduler
    # because internal_dma_timer stops with the CPU and this does not.
    when VDMA_OAM_BUS_CAPTURE != 0:
      if (gb.scheduler.cycles and 3) == 0:
        mem_vdma_bus_capture(gb.memory, gb, uint8((src_base + byte) and 0xFF),
                             val)
  # The acquire/release overhead is per TRANSFER, charged after the copies so
  # the hold deadline below is measured from the last byte. `charge_overhead`
  # is false for every block of a GDMA burst but its last.
  when HDMA_OVERHEAD_LEADS == 0:
    if charge_overhead: ppu_charge_hdma_overhead(ppu, gb)
  when VDMA_OAM_BUS_CAPTURE != 0:
    # Released only after the overhead: that M-cycle is the VRAM DMA's too
    # (gambatte dma/hdma_transition_oamdma_2 counts the ninth M-cycle).
    gb.memory.vdma_bus_hold = vdma_bus_was
  if hold:
    # Armed only now the block's own dots have run, so the deadline is measured
    # from the last byte. A PPU dot, not a bus M-cycle count: gambatte
    # hdma_start_ds_1 / hdma_start_scx5_2 are where the two part company.
    ppu.hdma_held_dst   = int32(dst_base)
    ppu.hdma_hold_from  = ppu.cycle_counter
    ppu.hdma_hold_until = ppu.cycle_counter + HDMA_VISIBLE_DOTS
    ppu.hdma_bytes_held = true
  # The source is the one that wraps rather than stops (dma/dma_src_wrap copies
  # its second block from $0000 after the first read $FFF0).
  ppu.hdma_src = ppu.hdma_src + 0x10
  let dst_overflow = ppu.hdma_dst == 0xFFF0'u16
  ppu.hdma_dst = ppu.hdma_dst + 0x10
  ppu.hdma5 = ppu.hdma5 - 1
  not dst_overflow

proc ppu_step_hdma*(ppu: GbPpu; gb: GB; in_cpu_cycle = false) =
  # The block copy ticks the PPU, which can drive another mode change; without
  # this guard a nested transition into mode 0 recurses until the stack overflows.
  if ppu.hdma_copying: return
  when defined(gb_dma_trace):
    echo "HDMABLOCK ly=", ppu.ly, " dot=", ppu.cycle_counter,
         " mode=", (ppu.lcd_status and 3'u8), " hdma5=", toHex(ppu.hdma5, 2)
  ppu.hdma_copying   = true
  ppu.hdma_block_due = false
  let may_continue = ppu_copy_hdma_block(ppu, gb, in_cpu_cycle)
  if ppu.hdma5 == 0xFF or not may_continue: ppu.hdma_active = false
  ppu.hdma_copying = false

when STAT_IRQ_SPLIT:
  proc ppu_set_irq_mode*(ppu: GbPpu; gb: GB; mode: uint8) {.inline.} =
    ## Move the STAT interrupt line's copy of the mode STAT_IRQ_LEAD M-cycles
    ## before the flag follows; nothing the CPU reads back moves.
    if ppu.irq_mode != mode:
      ppu.irq_mode = mode
      # The source's own change dot: halt_m0_tail_blind measures from THIS dot,
      # not from stat_chg_dot.
      ppu.irq_chg_dot = int16(ppu.cycle_counter)
      ppu_handle_stat_interrupt(ppu, gb)

proc `mode_flag=`*(ppu: GbPpu; mode: uint8; gb: GB) =
  let prev_mode = ppu.mode_flag
  # Backstop for a held HBlank DMA block (HDMA_VISIBLE_DOTS): a mode change is
  # always a whole mode 0 later than the hold.
  when HDMA_VISIBLE_DOTS != 0:
    if ppu.hdma_bytes_held: ppu_flush_hdma_bytes(ppu, gb)
  when defined(gb_dma_trace):
    if prev_mode != mode:
      echo "MODE ", prev_mode, "->", mode, " ly=", ppu.ly,
           " dot=", ppu.cycle_counter
  if ppu.first_line and ppu.mode_flag == 0 and mode == 2: ppu.first_line = false
  if mode == 1:
    ppu.window_trigger = false
  # Pan Docs: the window is drawn once "WY == LY at any point in the frame", so
  # the latch is per frame: cleared entering VBlank, set at the top of every
  # visible line, and by the WY write itself (ppu_latch_wy). Tested here and
  # not at the 2 -> 3 edge: gambatte window/arg/late_wy_1 vs late_wy_2. The
  # match counts only with LCDC.5 set: enabling the window on a later line
  # of the frame draws nothing (hardware: gbprobe probe_g_wy1 on AGB SP,
  # docs/hwprobe-questions.md row 19).
  elif mode == 2 and ppu.ly == ppu.wy and window_enabled(ppu):
    when defined(gb_win_trace):
      echo "WYLATCH ly=", ppu.ly, " wy=", ppu.wy, " dot=", ppu.cycle_counter
    ppu.window_trigger = true
    if gb.fifo_ppu != nil: fifo_arm_window(gb.fifo_ppu)
  if mode != prev_mode:
    # The one write the STAT readback needs: `cycle_counter` is the FIRST dot
    # of the new mode, which stat_read_mode's threshold is measured from.
    ppu.stat_prev_mode = prev_mode
    when STAT_MODE3_LAG != 0 or STAT_MODE3_LAG_CGB != 0:
      # The 2 -> 3 half goes on the field's timestamp; the 3 -> 0 half is
      # spent at the read (stat_read_mode), which knows the instruction.
      ppu.stat_chg_dot = ppu.cycle_counter +
        (if mode == 3:
           int32(STAT_MODE3_LAG) +
           (if gb.cgb_enabled: int32(STAT_MODE3_LAG_CGB) else: 0'i32)
         else: 0'i32)
    else:
      ppu.stat_chg_dot   = ppu.cycle_counter
  ppu.lcd_status = (ppu.lcd_status and 0b1111_1100'u8) or mode
  when STAT_IRQ_SPLIT:
    # Catch-up for the paths that do not lead the irq domain (the LCD-on line,
    # the LCD-off tick, a speed switch over the lead's dot). irq_chg_dot must
    # be stamped here too: halt_m0_tail_blind measures the halted CPU's blind
    # window from it, and a stale one made the LCD-on line's wake an M-cycle
    # early.
    if ppu.irq_mode != mode:
      ppu.irq_mode = mode
      ppu.irq_chg_dot = int16(ppu.cycle_counter)
  ppu_handle_stat_interrupt(ppu, gb)
  # The HBlank DMA step runs AFTER lcd_status reflects mode 0: the block copy
  # ticks the PPU, and a nested tick still seeing mode 3 re-enters the FIFO
  # renderer's mode-0 transition and recurses (Pokemon Crystal crashed at
  # boot). One block per ENTRY into mode 0 and only with the LCD driving the
  # modes: the LCD-off path re-asserts mode 0 every tick (Kirby Tilt 'n'
  # Tumble hung on a level-triggered step).
  #
  # "Upon halting the CPU, the transfer will also be halted and resumed only
  # when the CPU resumes" (Pan Docs, FF55): while halted the block only becomes
  # DUE and cpu.tick pays it at the wake if still in that mode 0 (gambatte
  # dma/hdma_m3halt_m1unhalt_hdma5). `in_cpu_cycle`: the edge lands inside a
  # CPU access still on the bus, so the bytes are held HDMA_VISIBLE_DOTS dots.
  when HDMA_HALT_M0_BLIND != 0:
    # The edge detector's registered mode, clocked by the CPU: read before this
    # change updates it, and not updated while halted (HDMA_HALT_M0_BLIND).
    let hdma_seen_was = ppu.hdma_seen_mode
    var hdma_since_halt = ppu.cycle_counter - ppu.hdma_halt_dot
    if hdma_since_halt < 0: hdma_since_halt += gb_line_end(ppu)
    let hdma_blind_lag = int32(if gb.memory.current_speed != 0'u8:
                                 HDMA_HALT_BLIND_LAG_DS
                               else: HDMA_HALT_BLIND_LAG)
    if (not gb.cpu.halted) or hdma_since_halt <= hdma_blind_lag:
      ppu.hdma_seen_mode = mode
  if mode == 0 and prev_mode != 0 and ppu.hdma_active and ppu.lcd_enabled:
    when HDMA_SPEEDSWITCH_KILL_W != 0:
      # A speed switch in the last dots of mode 3 destroys the armed transfer
      # outright (HDMA_SPEEDSWITCH_KILL_W, gb.nim).
      if ppu.hdma_kill_from >= 0:
        let d = ppu.cycle_counter - ppu.hdma_kill_from
        when defined(gb_dma_trace):
          echo "KILLWIN ly=", ppu.ly, " dot=", ppu.cycle_counter,
               " stopdot=", ppu.hdma_kill_from, " d=", d
        ppu.hdma_kill_from = -1
        if d >= 0 and d < HDMA_SPEEDSWITCH_KILL_W:
          ppu.hdma_active    = false
          ppu.hdma_block_due = false
          return
    when HDMA_DISABLE_GRACE_DOTS != 0:
      ppu.hdma_due_dot = ppu.cycle_counter
    when defined(gb_dma_trace):
      echo "M0DUE ly=", ppu.ly, " dot=", ppu.cycle_counter,
           " halted=", (if gb.cpu.halted: 1 else: 0),
           " seenwas=", hdma_seen_was
    if gb.cpu.halted:
      when HDMA_HALT_M0_BLIND != 0:
        # Halted inside a mode 0 the detector still registers: no edge to see.
        if hdma_seen_was == 0'u8: return
      ppu.hdma_block_due = true
      ppu.hdma_due_delay = 0
      when HDMA_GRANT_FETCH_DOTS >= 0:
        # A halted CPU has no opcode fetch to hand the bus over on: the debt is
        # paid at the wake (cpu.nim), so park the deadline out of reach.
        # `high(int32)` is also the flag hdma_grant reads as "waiting for a wake
        # that already happened". A dot deadline here is refused by gambatte
        # dma/hdma_*_m0unhalt and hdma_transition_*_late_unhalt.
        ppu.hdma_due_deadline = high(int32)
      when HDMA_STEAL_LEAD_DOTS >= 0:
        # Same: paid at the wake, deadline parked so mem_tick_bus cannot take
        # the block early (gambatte dma/hdma_*_m0unhalt).
        ppu.hdma_due_deadline = high(int32)
    else:
      when HDMA_GRANT_FETCH_DOTS >= 0:
        # The request goes up HDMA_GRANT_FETCH_DOTS dots from here and the CPU
        # hands the bus over at the end of its next opcode fetch; cpu.tick pays
        # it. See HDMA_GRANT_FETCH_DOTS in gb.nim.
        ppu.hdma_block_due = true
        ppu.hdma_due_delay = 0
        var dl = ppu.cycle_counter + int32(HDMA_GRANT_FETCH_DOTS)
        # The counter wraps at the line end and a deadline past it would never
        # be met; clamp so the block is dropped leaving mode 0 instead.
        let le = gb_line_end(ppu)
        if dl >= le: dl = le - 1
        ppu.hdma_due_deadline = dl
      elif HDMA_STEAL_LEAD_DOTS >= 0:
        # The request goes up HDMA_STEAL_LEAD_DOTS dots from here and the CPU
        # hands the bus over on its next M-cycle boundary; mem_tick_bus pays it.
        ppu.hdma_block_due    = true
        ppu.hdma_due_delay    = 0
        ppu.hdma_due_deadline = ppu.cycle_counter +
          int32(HDMA_STEAL_LEAD_DOTS) + int32(4 shr gb.memory.current_speed)
      elif HDMA_STEAL_DELAY_M != 0:
        # Owed, but the CPU keeps the bus for HDMA_STEAL_DELAY_M more instruction
        # boundaries; cpu.tick pays it.
        ppu.hdma_block_due = true
        # 1 = the first instruction boundary after the edge.
        ppu.hdma_due_delay = int8(HDMA_STEAL_DELAY_M - 1)
      else:
        ppu_step_hdma(ppu, gb, in_cpu_cycle = true)

proc ly_advance_line*(ppu: GbPpu; gb: GB) {.noinline.} =
  ## A rendered line starting, with the comparator's blind window around it
  ## (ly_advance_open); the mode change is INSIDE the window. One `noinline`
  ## call rather than open/`mode_flag=`/close at the call site: spelled inline
  ## in fifo_tick_slow's dot loop it costs +1.19% of retired instructions on
  ## Pokemon Crystal.
  let lyc_en = ly_advance_open(ppu)
  ppu.`mode_flag=`(2'u8, gb)
  ly_advance_close(ppu, gb, lyc_en)

proc ly_advance_vblank*(ppu: GbPpu; gb: GB) {.noinline.} =
  ## A vblank line starting: the same window with no mode change inside it.
  ## `noinline` for the reason above.
  let lyc_en = ly_advance_open(ppu)
  ppu_handle_stat_interrupt(ppu, gb)
  ly_advance_close(ppu, gb, lyc_en)

proc ly_advance_vblank_entry*(ppu: GbPpu; gb: GB) {.noinline.} =
  ## Line 143 -> 144: entering vblank is not a line start, so the mode 1 source
  ## and m2_line144's pulse arrive AFTER the comparator's drop. Only reachable
  ## at LY_BLIND_SCOPE >= 2 (gb.nim), which does not ship.
  let lyc_en = ly_advance_open(ppu)
  ppu_handle_stat_interrupt(ppu, gb)
  ppu.`mode_flag=`(1'u8, gb)
  ly_advance_close(ppu, gb, lyc_en)

proc ppu_update_palette*(palette: var array[4, uint8]; val: uint8) =
  palette[0] = val and 0x3
  palette[1] = (val shr 2) and 0x3
  palette[2] = (val shr 4) and 0x3
  palette[3] = (val shr 6) and 0x3

proc ppu_palette_from_array*(palette: array[4, uint8]): uint8 =
  palette[0] or (palette[1] shl 2) or (palette[2] shl 4) or (palette[3] shl 6)

proc ppu_start_hdma*(ppu: GbPpu; gb: GB; val: uint8) =
  ## A write to FF55. The length register takes the low 7 bits whether the
  ## write starts or stops a transfer (SameSuite dma/hdma_lcd_off reads back
  ## $80, not $82). The address counters are not reloaded.
  when defined(gb_dma_trace):
    echo "FF55 v=", toHex(val, 2), " ly=", ppu.ly, " dot=", ppu.cycle_counter,
         " mode=", (ppu.lcd_status and 3'u8),
         " active=", (if ppu.hdma_active: 1 else: 0), " hdma5=", toHex(ppu.hdma5, 2)
  ppu.hdma5 = val and 0x7F
  when HDMA_SPEEDSWITCH_KILL_W != 0:
    # A fresh transfer is never the one a pending speed switch is racing.
    ppu.hdma_kill_from = -1
  if (val and 0x80) != 0:
    ppu.hdma_active = true
    # Arming an HBlank transfer while already in HBlank starts it right away.
    # With the LCD off the mode reads 0 forever, so an armed transfer copies
    # exactly one block and no more (SameSuite dma/hdma_lcd_off).
    if ppu.mode_flag == 0 or not ppu.lcd_enabled:
      ppu_step_hdma(ppu, gb)
  else:
    if not ppu.hdma_active:
      # One acquire and one release for the whole burst: a GDMA never hands the
      # bus back in between.
      when HDMA_OVERHEAD_LEADS != 0: ppu_charge_hdma_overhead(ppu, gb)
      for _ in 0 .. int(ppu.hdma5):
        if not ppu_copy_hdma_block(ppu, gb, charge_overhead = false): break
      when HDMA_OVERHEAD_LEADS == 0: ppu_charge_hdma_overhead(ppu, gb)
      # GDMA is short of the hardware by some amount and ships at zero; see
      # GDMA_SETUP_MCYCLES in gb.nim.
      when GDMA_SETUP_MCYCLES != 0:
        mem_tick_components(gb.memory, gb, 4 * GDMA_SETUP_MCYCLES, from_cpu = false)
    else:
      # Terminating an armed HBlank transfer: the block this HBlank owed is owed
      # no longer, unless the write is too late to catch it -- the block takes
      # the bus a fixed moment after the mode-0 edge (HDMA_DISABLE_GRACE_DOTS).
      when HDMA_DISABLE_GRACE_DOTS != 0:
        if ppu.hdma_block_due and ppu.hdma_active and
           ppu.cycle_counter - ppu.hdma_due_dot >= HDMA_DISABLE_GRACE_DOTS:
          ppu_step_hdma(ppu, gb, in_cpu_cycle = true)
      ppu.hdma_block_due = false
    ppu.hdma_active = false

# ---- Which half of a CPU write moves, and which does not --------------------
#
# mem_write commits a write's byte at the top of its M-cycle because the mode-3
# pipeline runs an M-cycle ahead of the CPU. Pipeline registers (SCX, SCY, WX,
# WY, palettes, VBK, VRAM, OAM) move with it (gambatte bgtiledata/bgtilemap,
# mealybug m3_*). Registers that GATE a PPU event -- STAT's enable bits and
# FF55 -- wait for the boundary (gambatte m0enable/disable_*,
# dma/hdma_late_disable_*). LYC and IF move (wilbertpol ly_lyc_write-GS,
# GBMicrotest vblank_int_if_c, lyc1_int_if_edge_c). LCDC's byte moves and only
# its STAT effect is held back (stat_write_pending).
proc ppu_write_machinery*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
  case idx
  of 0xFF41:
    ppu.lcd_status = (ppu.lcd_status and 0b1000_0111'u8) or (val and 0b0111_1000'u8)
    ppu_handle_stat_interrupt(ppu, gb)
  of 0xFF55:
    ppu_start_hdma(ppu, gb, val)
  of 0xFF45:
    # CGB only, reachable only with CGB_LYC_WRITE_DEFER. With CGB_LYC_EDGE_DEFER
    # the STAT edge is one M-cycle further on again, booked as a scheduler
    # event rather than a per-M-cycle poll (CGB_LYC_EDGE_SCHED_T, gb.nim).
    when CGB_LYC_WRITE_DEFER:
      ppu.lyc = val
      when CGB_LYC_EDGE_DEFER:
        when CGB_LYC_EDGE_POLL: gb.memory.lyc_edge_owed = true
        else: gb.scheduler.schedule(CGB_LYC_EDGE_SCHED_T, etGbLycEdge)
  else: discard

proc ppu_defer_machinery_write*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
  ## Park one of the two above until the M-cycle boundary (mem_flush_deferred).
  ## Drained first: write_byte callers that are not an M-cycle (post-boot
  ## table, cheat pokes) can fill the slot twice and must not lose a store.
  if gb.memory.deferred_reg != 0:
    ppu_write_machinery(ppu, gb, int(gb.memory.deferred_reg), gb.memory.deferred_val)
  gb.memory.deferred_reg = uint16(idx)
  gb.memory.deferred_val = val
  gb.memory.write_deferred = true

# The pipeline registers' stores, split out so a CGB write can land late
# (mem_tick_ppu_latched). Each is only what the write does to the pixel
# pipeline; the parts that do not move stay in ppu_write.
proc ppu_store_scy*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  ppu.scy = val

proc ppu_store_scx*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  when SCX_STORE_STALL_DOTS != 0:
    let old_scx = ppu.scx
  ppu.scx = val
  # The fetcher's SCX term carries a borrow off the line's latched fine scroll
  # (SCX_FINE_BORROW, fifo_ppu); re-derived here, not at every fetch.
  if gb.fifo_ppu != nil:
    fifo_arm_scx(gb.fifo_ppu)
    when SCX_STORE_STALL_DOTS != 0:
      fifo_scx_store_stall(gb.fifo_ppu, old_scx)

proc ppu_store_wx*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  ppu.wx = val
  if gb.fifo_ppu != nil: fifo_arm_window(gb.fifo_ppu)

proc ppu_store_wy*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  ppu.wy = val

proc ppu_latch_wy*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  ## The other half of the WY level comparator at `mode_flag=`: a write that
  ## makes WY equal the line being drawn latches the window for the frame
  ## (gambatte window/arg/late_wy_*). VBlank is excluded because the latch is
  ## cleared entering it. Split from ppu_store_wy because the CGB takes the
  ## register and the latch at different latencies (CGB_WY_LATENCY,
  ## CGB_WY_LATCH_LATENCY); `ppu.ly` is read here for that reason.
  if ppu.ly == val and (ppu.lcd_status and 3'u8) != 1'u8 and ppu.lcd_enabled and
     window_enabled(ppu):
    ppu.window_trigger = true
    if gb.fifo_ppu != nil: fifo_arm_window(gb.fifo_ppu)

proc ppu_store_lcdc*(ppu: GbPpu; gb: GB; val: uint8) {.inline.} =
  # LCDC.2 is read twice by an object fetch, once per bitplane: the change's
  # dot goes into the history obj_height_at walks, and a fetch whose high
  # plane is not read yet is redone. LCDC.4 is read by a background bitplane
  # fetch and on a CGB gets there a dot late (tdsel_dot; NO_TDSEL_CHANGE on DMG).
  let moved = ppu.lcd_control xor val
  let flip2 = (moved and 0x04'u8) != 0
  when defined(gb_lcdc2_trace):
    if flip2:
      echo "LCDC2 ly=", ppu.ly, " dot=", ppu.cycle_counter,
           " mode=", (ppu.lcd_status and 3'u8), " val=", toHex(val, 2)
  ppu.lcd_control = val
  # LCDC.5 turning on is the third event that can make "WY match while
  # enabled" newly true: set mid-line on the WY line the window starts on
  # that same line (hardware: gbprobe probe_g_wy0 on AGB SP). Pan Docs
  # states the WY condition per line only.
  if (moved and val and 0x20'u8) != 0 and ppu.ly == ppu.wy and
     (ppu.lcd_status and 3'u8) != 1'u8 and ppu.lcd_enabled:
    ppu.window_trigger = true
  if gb.fifo_ppu != nil:
    fifo_arm_window(gb.fifo_ppu)
    when CGB_TDSEL_ANY:
      if (moved and 0x10'u8) != 0 and gb.fifo_ppu.cgb:
        # The dot the fetcher sees it on. A CPU-clock delay, so a double-speed
        # M-cycle spends it inside itself (gambatte bgtiledata brackets it;
        # CGB_TDSEL_LATENCY, gb.nim).
        gb.fifo_ppu.tdsel_dot = ppu.cycle_counter +
          int32(max(0, CGB_TDSEL_LATENCY - int(gb.memory.current_speed)))
    when CGB_MAP_ANY:
      # LCDC.3 and LCDC.6 at the fetcher's map-address read; same shape.
      # `map_old` is the pair BEFORE this write, which a read still inside the
      # latency uses (CGB_MAP_LATENCY, gb.nim).
      if (moved and 0x48'u8) != 0 and gb.fifo_ppu.cgb:
        gb.fifo_ppu.map_old = (val xor moved) and 0x48'u8
        gb.fifo_ppu.map_dot = ppu.cycle_counter +
          int32(max(0, CGB_MAP_LATENCY - int(gb.memory.current_speed)))
    if flip2:
      ppu.lcdc2_flip[1] = ppu.lcdc2_flip[0]
      ppu.lcdc2_flip[0] = ppu.cycle_counter
      if gb.fifo_ppu.obj_fix_from <= ppu.cycle_counter:
        fifo_obj_size_write(gb.fifo_ppu, gb)

when CGB_WRITE_LATENCY_ANY:
  proc ppu_apply_pipeline_write*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
    ## Every stage of a parked store at once, for the callers that have no dots
    ## left to spread them over.
    case idx
    of 0xFF40: ppu_store_lcdc(ppu, gb, val)
    of 0xFF42: ppu_store_scy(ppu, gb, val)
    of 0xFF43: ppu_store_scx(ppu, gb, val)
    of 0xFF4A:
      ppu_store_wy(ppu, gb, val)
      ppu_latch_wy(ppu, gb, val)
    of 0xFF4B: ppu_store_wx(ppu, gb, val)
    else: discard

  proc ppu_park_pipeline_write*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
    ## Park a CGB pipeline-register store for mem_write to apply part way
    ## through this M-cycle's dots. Same drain-before-refill discipline as
    ## ppu_defer_machinery_write; mem_flush_deferred applies any leftover.
    if gb.memory.pipe_reg != 0:
      ppu_apply_pipeline_write(ppu, gb, int(gb.memory.pipe_reg), gb.memory.pipe_val)
    gb.memory.pipe_reg = uint16(idx)
    gb.memory.pipe_val = val
    gb.memory.write_deferred = true

# Sprite helpers
proc sprite_on_line*(s: GbSprite; line: uint8; sprite_height: int): bool =
  int(s.y) <= int(line) + 16 and int(line) + 16 < int(s.y) + sprite_height

proc sprite_priority*(s: GbSprite): uint8 = (s.attributes shr 7) and 0x1
proc sprite_y_flip*(s: GbSprite): bool = ((s.attributes shr 6) and 0x1) == 1
proc sprite_x_flip*(s: GbSprite): bool = ((s.attributes shr 5) and 0x1) == 1
proc sprite_dmg_palette*(s: GbSprite): uint8 = (s.attributes shr 4) and 0x1
proc sprite_bank_num*(s: GbSprite): uint8 = (s.attributes shr 3) and 0x1
proc sprite_cgb_palette*(s: GbSprite): uint8 = s.attributes and 0b111

proc sprite_tile_bytes*(s: GbSprite; line: uint8; sprite_height: int): tuple[lo: uint16; hi: uint16] =
  let actual_y = int(s.y) - 16
  var tile_ptr: uint16
  if sprite_height == 8:
    tile_ptr = uint16(s.tile_num) * 16
  else:
    if (actual_y + 8 <= int(line)) xor sprite_y_flip(s):
      tile_ptr = uint16(s.tile_num or 0x01) * 16
    else:
      tile_ptr = uint16(s.tile_num and 0xFE) * 16
  let sprite_row = (int(line) - actual_y) and 7
  if sprite_y_flip(s):
    result = (tile_ptr + uint16(7 - sprite_row) * 2,
              tile_ptr + uint16(7 - sprite_row) * 2 + 1)
  else:
    result = (tile_ptr + uint16(sprite_row) * 2,
              tile_ptr + uint16(sprite_row) * 2 + 1)

# PPU register read/write
proc ppu_read*(ppu: GbPpu; gb: GB; idx: int): uint8 =
  case idx
  of 0x8000..0x9FFF: ppu.vram[ppu.vram_bank][idx - 0x8000]
  of 0xFE00..0xFE9F:
    # OAM is the PPU's during modes 2 and 3; reads answer $FF. See cpu_oam_open
    # (mooneye intr_2_oam_ok_timing, lcdon_timing-GS).
    if cpu_oam_open(ppu, is_write = false,
                    open_late = gb.quirks.oam_read_open_late,
                    ds = gb.memory.current_speed != 0):
      ppu.sprite_table[idx - 0xFE00]
    else: 0xFF'u8
  of 0xFF40:         ppu.lcd_control
  of 0xFF41:
    # The mode bits are sampled STAT_READ_SAMPLE dots back from where this
    # read's M-cycle leaves the dot counter; see stat_read_mode.
    let rm = stat_read_mode(ppu, gb)
    when defined(gb_stat_read_trace):
      # Diagnostic (tools only). `latch` is the VRAM/OAM-lock latch, a different dot.
      echo "STATRD ly=", ppu.ly, " cc=", ppu.cycle_counter,
           " rm=", rm, " chg=", ppu.stat_chg_dot,
           " latch=", ppu.read_mode and 3'u8, " live=", ppu.lcd_status and 3'u8
    var live = (ppu.lcd_status and 0b1111_1100'u8) or rm
    # The comparator does not follow LY instantaneously: the M-cycle LY
    # advances in reads bit 2 CLEAR whatever LYC holds (mooneye
    # acceptance/ppu/lcdon_timing-GS wants it clear for LYC=1 and LYC=0 alike).
    if (ppu.read_mode and LY_JUST_CHANGED) != 0:
      live = live and not 0b0000_0100'u8
      # CGB D and later HOLD the comparison against the LY being left instead
      # of clearing it (quirks.lyc_compare_hold, gb.nim).
      if gb.quirks.lyc_compare_hold and
         ppu.lyc == (if ppu.ly == 0'u8: 153'u8 else: ppu.ly - 1'u8):
        live = live or 0b0000_0100'u8
    # Leaving vblank the two mode bits do not move together: bit 0 drops as
    # mode 1 ends and bit 1 comes up an M-cycle later, so that M-cycle reads
    # mode 0 (GBMicrotest poweron_stat_006, wilbertpol ly00_mode0_2-GS,
    # ly00_mode1_0-GS). Early silicon only: CGB 0/A/B/C do it too, D/E/AGB do
    # not (quirks.m1_end_no_mode0, gb.nim).
    if (ppu.first_line and rm == 2) or
       (rm == 1 and (ppu.lcd_status and 3'u8) == 2 and
        not (gb.quirks.m1_end_no_mode0 or gb.memory.current_speed == 1'u8)):
      live and 0b1111_1100'u8
    else:
      live
  of 0xFF42: ppu.scy
  of 0xFF43: ppu.scx
  of 0xFF44:
    # Diagnostics (tools only).
    when defined(gb_ly153_probe):
      if ppu.ly == 153'u8 and ppu.cycle_counter >= LY153_SNAP_DOT:
        echo "LY153READ cc=", ppu.cycle_counter, " ly=", ppu.ly,
             " cgb=", gb.cgb_enabled, " spd=", gb.memory.current_speed
    when defined(gb_lyread_probe):
      if ppu.cycle_counter < 12'i32 or
         ppu.cycle_counter > gb_line_end(ppu) - 12'i32:
        echo "LYREAD cc=", ppu.cycle_counter, " ly=", ppu.ly,
             " jc=", (ppu.read_mode and LY_JUST_CHANGED) != 0,
             " spd=", gb.memory.current_speed
    when LY153_READ_SPLIT:
      # `ly == 153` first and the device pick inside the `and`: every LY poll
      # comes through here; hoisting the pick cost +0.041% retired instructions.
      if ppu.ly == 153'u8 and ppu.cycle_counter >=
           (if gb.cgb_enabled and (gb.quirks.ly_read_edge_late or
                                   gb.memory.current_speed == 1'u8):
              LY153_READ_SNAP_CGB
            else: LY153_READ_SNAP): 0'u8
      elif ly_edge_rippling(ppu, gb): ppu.ly and (ppu.ly + 1'u8)
      else: ppu.ly
    elif ly_edge_rippling(ppu, gb): ppu.ly and (ppu.ly + 1'u8)
    else: ppu.ly
  of 0xFF45: ppu.lyc
  of 0xFF46: 0xFF'u8  # DMA (write-only, return 0xFF)
  of 0xFF47: ppu_palette_from_array(ppu.bgp)
  of 0xFF48: ppu_palette_from_array(ppu.obp0)
  of 0xFF49: ppu_palette_from_array(ppu.obp1)
  of 0xFF4A: ppu.wy
  of 0xFF4B: ppu.wx
  of 0xFF4F: (if gb.cgb_enabled: 0xFE'u8 or ppu.vram_bank else: 0xFF'u8)
  # HDMA1-4 are write-only (Pan Docs, CGB Registers); gambatte ff51_bits..
  # ff54_bits pin the read at $FF. The counters still hold what was written.
  of 0xFF51..0xFF54: 0xFF'u8
  # Pan Docs, FF55: bit 7 reads 1 when no transfer is active, under any
  # circumstances. The low 7 bits are the length register, which a completed
  # transfer leaves at $7F, so a finished transfer reads $FF.
  of 0xFF55:
    if gb.cgb_native:
      (ppu.hdma5 and 0x7F) or (if ppu.hdma_active: 0x00'u8 else: 0x80'u8)
    else: 0xFF'u8
  of 0xFF68:
    if gb.cgb_enabled:
      0x40'u8 or (if ppu.auto_increment: 0x80'u8 else: 0'u8) or ppu.palette_index
    else: 0xFF'u8
  of 0xFF69:
    # CGB palette RAM is the PPU's during mode 3 (Pan Docs, Palettes); the
    # index ports stay open throughout.
    if gb.cgb_native and cpu_cram_open(ppu, false): ppu.pram[ppu.palette_index]
    else: 0xFF'u8
  of 0xFF6A:
    if gb.cgb_enabled:
      0x40'u8 or (if ppu.obj_auto_increment: 0x80'u8 else: 0'u8) or ppu.obj_palette_index
    else: 0xFF'u8
  of 0xFF6B:
    if gb.cgb_native and cpu_cram_open(ppu, false):
      ppu.obj_pram[ppu.obj_palette_index]
    else: 0xFF'u8
  else: 0xFF'u8

proc ppu_write*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
  case idx
  of 0x8000..0x9FFF: ppu.vram[ppu.vram_bank][idx - 0x8000] = val
  of 0xFE00..0xFE9F: ppu.sprite_table[idx - 0xFE00] = val
  of 0xFF40:
    if (val and 0x80) != 0 and not ppu.lcd_enabled:
      # The PPU restarts at the top of the frame; if enough time has passed
      # since the last present, push one now rather than let the gap stretch
      # (LCD_ON_FRAME_DOTS: a pacing rule, not a hardware one).
      if ppu.dots_since_frame > LCD_ON_FRAME_DOTS:
        when defined(gb_dot_counter): inc gb_frame_lcd_on
        if gb.sgb != nil:
          # SGB freeze, same as lcd_off_frame: re-present the held picture.
          ppu.frame = true
          ppu.dots_since_frame = 0
        else:
          ppu_blank_frame(ppu, gb)
      ppu.ly = 0
      # The re-enabled PPU is already part-way into line 0 when the LCDC write
      # retires, and because every line is a multiple of 4 dots this seed is
      # also the PPU's dot phase against the CPU's M-cycle grid for the run.
      # mooneye acceptance/ppu/lcdon_timing-GS fixes it to 5..8; gambatte
      # enable_display and scx_during_m3 refuse 7 (GBMicrotest hblank_int_scx*
      # ask for 7; see LCD_ON_LINE0_TRIM in gb.nim). The M-cycle is backed out
      # because the counter has to read 5 once this M-cycle's dots have run
      # (mem_write applies the byte before the dots); seeding flat restarts the
      # PPU a double-speed M-cycle late (gambatte enable_display/*_ds_*).
      ppu.cycle_counter = int32(int(LCD_ON_HEAD_START) - (4 shr gb.memory.current_speed))
      when STAT_IRQ_SPLIT:
        # The irq domain restarts with the flag domain.
        ppu.irq_ly = 0
      # stat_chg_dot was expressed in a counter that has just restarted; retire
      # the hold, the `mode_flag=` below stamps the new one.
      ppu.stat_chg_dot = STAT_NO_HOLD
      ppu.`mode_flag=`(2'u8, gb)
      ppu.first_line = true
      # See GbPpu.lcd_on_first_frame: the frame this restart draws stays blank
      # on a handheld panel; the SGB's TV shows the frozen picture instead.
      if gb.sgb == nil: ppu.lcd_on_first_frame = true
      when LCD_ON_TRIM_ANY: ppu.lcdon_lines = 2
    when defined(gb_m3_trace):
      if gb_traced(ppu.ly) and (ppu.lcd_status and 3) == 3:
        let fp = if ppu of GbFifoPpu: $GbFifoPpu(ppu).fetch_counter &
                    " lx=" & $GbFifoPpu(ppu).lx & " fx=" & $GbFifoPpu(ppu).fetcher_x
                 else: "?"
        echo "LCDC ly=", ppu.ly, " dot=", ppu.cycle_counter, " old=",
             toHex(ppu.lcd_control, 2), " new=", toHex(val, 2), " fc=", fp
    when defined(gb_win_trace):
      echo "LCDC ly=", ppu.ly, " dot=", ppu.cycle_counter, " mode=",
           (ppu.lcd_status and 3), " old=", toHex(ppu.lcd_control,2), " new=", toHex(val,2)
    # Only the six bits the pipeline reads are late on CGB; the enable bit has
    # already restarted the mode machinery above on this dot.
    when CGB_LCDC_LATENCY_ANY:
      if gb.cgb_enabled and ((ppu.lcd_control xor val) and 0x80'u8) == 0:
        ppu_park_pipeline_write(ppu, gb, idx, val)
      else:
        ppu_store_lcdc(ppu, gb, val)
    else:
      ppu_store_lcdc(ppu, gb, val)
    # Deferred to the end of this M-cycle (stat_write_pending). LCDC.1 and, in
    # CGB mode, LCDC.0 are mixer reads (mealybug m3_lcdc_obj_en_change; see
    # fifo_recompose_last).
    mixer_write_repaint(gb, MIXER_PRIORITY_BACK, gb_lcdc_mixer_latency(gb))
    # LCDC.1 is also a FETCHER read: the mixer's copy decides pixels already
    # emitted, this decides whether the object's remaining stall dots are still
    # owed (fifo_obj_abort). `obj_penalty > 0` = not merged yet; on the tail
    # dot after the merge LCDC.1 is a mixer question (mealybug
    # m3_lcdc_obj_en_change_variant band 0).
    when OBJ_ABORT != 0:
      if (val and 0x02'u8) == 0 and
         (CGB_OBJ_ABORT != 0 or not gb.cgb_enabled) and
         gb.fifo_ppu != nil:
        if gb.fifo_ppu.fetching_sprite and gb.fifo_ppu.obj_penalty > 0:
          fifo_obj_abort(gb.fifo_ppu, gb)
        else:
          # The stall is over but the fetcher saw the bit OBJ_ABORT_LEAD dots
          # ago, and those dots can still be inside the fetch (fifo_obj_abort_late).
          when OBJ_ABORT_LATE:
            let last = gb.fifo_ppu.obj_abort_last
            if gb.fifo_ppu.cycle_counter > last and
               gb.fifo_ppu.cycle_counter <= last + OBJ_ABORT_LEAD:
              fifo_obj_abort_late(gb.fifo_ppu, gb)
    ppu.stat_write_pending = true
    gb.memory.write_deferred = true
  of 0xFF41:
    # DMG only. The $FF phase of the write acts here at the commit point; only
    # the real value waits for the M-cycle boundary (ppu_stat_write_glitch).
    if not gb.cgb_enabled: ppu_stat_write_glitch(ppu, gb)
    when STAT_ENABLE_EARLY:
      # Where the M-cycle's PPU dots start. mem_write applies the byte between
      # mem_tick_bus and mem_tick_ppu, so the dot counter has not moved yet.
      ppu.stat_wr_dot = int16(ppu.cycle_counter)
    ppu_defer_machinery_write(ppu, gb, idx, val)
  of 0xFF42:
    when defined(gb_m3_trace):
      # Diagnostic (tools only): the dot each mid-mode-3 SCY write lands on.
      echo "SCY ly=", ppu.ly, " dot=", ppu.cycle_counter,
           " mode=", (ppu.lcd_status and 3), " old=", ppu.scy, " new=", val
    when CGB_SCY_LATENCY != 0:
      if gb.cgb_enabled: ppu_park_pipeline_write(ppu, gb, idx, val)
      else:              ppu_store_scy(ppu, gb, val)
    else:
      ppu_store_scy(ppu, gb, val)
  of 0xFF43:
    when defined(gb_m3_trace):
      # Diagnostic (tools only): the dot each SCX write lands on.
      echo "SCX ly=", ppu.ly, " dot=", ppu.cycle_counter,
           " mode=", (ppu.lcd_status and 3), " old=", ppu.scx, " new=", val
    when CGB_SCX_LATENCY != 0:
      if gb.cgb_enabled: ppu_park_pipeline_write(ppu, gb, idx, val)
      else:              ppu_store_scx(ppu, gb, val)
    else:
      ppu_store_scx(ppu, gb, val)
  of 0xFF44: discard  # read-only
  of 0xFF45:
    # NOT deferred on a DMG: LYC is the comparator's other input and wilbertpol
    # acceptance/gpu/ly_lyc_write-GS wants the new value inside its own
    # M-cycle; only the STAT edge is held back. On CGB see CGB_LYC_WRITE_DEFER.
    var edge_here = true
    when CGB_LYC_WRITE_DEFER:
      if gb.cgb_enabled and (CGB_LYC_WRITE_DEFER_DS or gb.memory.current_speed == 0):
        ppu_defer_machinery_write(ppu, gb, idx, val)
        # With CGB_LYC_EDGE_DEFER the edge is armed when the byte lands.
        when CGB_LYC_EDGE_DEFER: edge_here = false
      else: ppu.lyc = val
    else:
      ppu.lyc = val
    if edge_here: ppu.stat_write_pending = true
    gb.memory.write_deferred = true
  of 0xFF46: discard  # handled by memory DMA
  # The three DMG palettes are pure mixer reads -- nothing else in the PPU looks
  # at them -- so each one carries the mixer's extra dot (fifo_recompose_last).
  of 0xFF47, 0xFF48, 0xFF49:
    when defined(gb_px_trace):
      # Diagnostic (tools only): the dot each mid-mode-3 palette write lands on.
      echo "PAL ly=", ppu.ly, " dot=", ppu.cycle_counter, " reg=", toHex(idx, 4),
           " mode=", (ppu.lcd_status and 3), " new=", toHex(val, 2)
    # The transition pixel: a DMG palette write is not a clean edge at the
    # mixer. mealybug m3_bgp_change's DMG reference shows one pixel of
    # `old or new` at the far end of the mixer tail (MIXER_PALETTE_BACK) at
    # every write; its `_cgb_c` reference wants a clean edge, and the CGB's
    # write latency (CGB_MIXER_LATENCY) puts that pixel out of reach.
    var or_pixel = false
    when MIXER_PALETTE_OR != 0:
      or_pixel = MIXER_DOT_LAG != 0 and gb.fifo_ppu != nil and
                 not gb.cgb_enabled and MIXER_PALETTE_BACK > 0
      if or_pixel:
        let cur = case idx
                  of 0xFF47: addr ppu.bgp
                  of 0xFF48: addr ppu.obp0
                  else:      addr ppu.obp1
        ppu_update_palette(cur[], ppu_palette_from_array(cur[]) or val)
        fifo_recompose_at(gb.fifo_ppu, gb, int32(MIXER_PALETTE_BACK))
    case idx
    of 0xFF47: ppu_update_palette(ppu.bgp,  val)
    of 0xFF48: ppu_update_palette(ppu.obp0, val)
    else:      ppu_update_palette(ppu.obp1, val)
    mixer_write_repaint(gb, int32(MIXER_PALETTE_BACK), gb_mixer_latency(gb),
                        if or_pixel: 1'i32 else: 0'i32)

  of 0xFF4A:
    when defined(gb_win_trace):
      echo "WY ly=", ppu.ly, " dot=", ppu.cycle_counter, " mode=",
           (ppu.lcd_status and 3), " old=", ppu.wy, " new=", val
    when CGB_WY_LATENCY_ANY:
      if gb.cgb_enabled:
        ppu_park_pipeline_write(ppu, gb, idx, val)
      else:
        ppu_store_wy(ppu, gb, val)
        ppu_latch_wy(ppu, gb, val)
    else:
      ppu_store_wy(ppu, gb, val)
      ppu_latch_wy(ppu, gb, val)
  of 0xFF4B:
    when defined(gb_win_trace):
      echo "WX ly=", ppu.ly, " dot=", ppu.cycle_counter, " mode=",
           (ppu.lcd_status and 3), " old=", ppu.wx, " new=", val
    when CGB_WX_LATENCY != 0:
      if gb.cgb_enabled: ppu_park_pipeline_write(ppu, gb, idx, val)
      else:              ppu_store_wx(ppu, gb, val)
    else:
      ppu_store_wx(ppu, gb, val)
  of 0xFF4F:
    # The register, not the console: VBK goes with the CGB set when the boot
    # ROM sets KEY0, so a compatibility cart is stuck on bank 0. The read stays
    # on cgb_enabled (mooneye misc/bits/unused_hwio-C reads $FE).
    if gb.cgb_native: ppu.vram_bank = val and 0x1
  # Each edits one byte of the live address counter. The low four bits are
  # ignored (Pan Docs, FF51-FF54); the destination's upper bits are dropped
  # where the counter becomes an address (ppu_copy_hdma_block).
  of 0xFF51:
    if gb.cgb_native:
      ppu.hdma_src = (uint16(val) shl 8) or (ppu.hdma_src and 0x00F0'u16)
  of 0xFF52:
    if gb.cgb_native:
      ppu.hdma_src = (ppu.hdma_src and 0xFF00'u16) or uint16(val and 0xF0)
  of 0xFF53:
    if gb.cgb_native:
      ppu.hdma_dst = (uint16(val) shl 8) or (ppu.hdma_dst and 0x00F0'u16)
  of 0xFF54:
    if gb.cgb_native:
      ppu.hdma_dst = (ppu.hdma_dst and 0xFF00'u16) or uint16(val and 0xF0)
  of 0xFF55:
    if gb.cgb_native: ppu_defer_machinery_write(ppu, gb, idx, val)
  of 0xFF68:
    if gb.cgb_enabled:
      ppu.palette_index  = val and 0x3F
      ppu.auto_increment = (val and 0x80) != 0
  of 0xFF69:
    if gb.cgb_native:
      # A mode-3 write is dropped but the auto-increment still fires: it lives
      # in the index port, not in CRAM (Pan Docs, Palettes).
      if cpu_cram_open(ppu, true):
        ppu.pram[ppu.palette_index] = val
      if ppu.auto_increment:
        ppu.palette_index = (ppu.palette_index + 1) and 0x3F
  of 0xFF6A:
    if gb.cgb_enabled:
      ppu.obj_palette_index  = val and 0x3F
      ppu.obj_auto_increment = (val and 0x80) != 0
  of 0xFF6B:
    if gb.cgb_native:
      if cpu_cram_open(ppu, true):
        ppu.obj_pram[ppu.obj_palette_index] = val
      if ppu.obj_auto_increment:
        ppu.obj_palette_index = (ppu.obj_palette_index + 1) and 0x3F
  else: discard

method tick*(ppu: GbPpu; gb: GB; cycles: int) {.base.} = discard
