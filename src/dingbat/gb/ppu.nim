# GB PPU shared base (included by gb.nim)

# `stat_lag_cc` holds no pending mode change. Above every legal cycle_counter
# (0..456) so the "has the tick reached it" test is a single compare.
const STAT_LAG_NONE* = high(int32)

# Dots the re-enabled PPU is already into line 0 by the time the LCDC write
# retires. See the LCDC-enable path in ppu_write for the derivation; it is
# overridable because both ROMs that pin it read STAT, so the sweep has to be
# re-run whenever the STAT read model moves (see STAT_MODE_HOLD).
const LCD_ON_HEAD_START* {.intdefine.} = 5'i32

# Dots past the start of VBlank at which the CGB boot ROM hands off. See
# skip_boot for the derivation; overridable so the sweep can be re-run.
const CGB_BOOT_PHASE* {.intdefine.} = 161

# Dot of line 153 at which the DMG/MGB boot ROM hands off. See skip_boot for the
# derivation; overridable so the sweep can be re-run.
const DMG_BOOT_PHASE* {.intdefine.} = 397

# ---- Sweep knob: one more M-cycle of lag on STAT's mode bits ----------------
#
# `STAT_MODE_HOLD` itself is declared at the top of gb.nim, because the GbPpu
# fields it gates live in that file's type block; it ships OFF, and the latch,
# its scratch fields and the branch that reads them all compile out with it.
# What it is, why it is here, and why it is not on:
#
# The gambatte m2int_* families bracket each mode boundary with pairs of ROMs
# whose STAT read moves by exactly one M-cycle, all anchored on the mode-2 STAT
# interrupt: m2int_m2stat_{1,2} at the 2->3 edge, m2int_m3stat plus its
# scx/{0,2,3,5} sweep at the 3->0 edge, m2int_m0stat_{1,2} at 0->2, and
# m2int_m0irq_{1,2} on the interrupt itself. Writing the STAT value a read
# returns as "the internal mode in effect during dot (last dot of the read's
# M-cycle) - L", and letting the whole STAT interrupt line sit D M-cycles
# earlier than dingbat puts it, every one of those ROMs is satisfied by exactly
# one equation:
#
#     4*D + L = 4        (dingbat today is D = 0, L = 3 -- one dot short)
#
# The scx sweep is what makes it an equation rather than an inequality: at
# SCX&7 = 3 the mode-0 edge lands on the last dot of an M-cycle, which pins the
# sum from below, and the 2->3 edge pins it from above. Two integer solutions
# fit:
#
#   (a) D = 0, L = 4 -- the mode bits are a copy of the internal mode taken one
#       M-cycle ago, and the interrupt line is already right. THIS KNOB.
#   (b) D = 1, L = 0 -- the mode bits are not delayed at all beyond the CPU
#       latching the bus on the last T-cycle of its read, and the STAT
#       interrupt line leads dingbat's mode flag by one M-cycle.
#
# (a) is what this knob implements, and on its own it takes the m2int_* groups
# from 24/44+4/8+3/6 to 36/44+8/8+6/6. It is nonetheless WRONG, and mooneye
# says so: acceptance/ppu/intr_2_mode3_timing and intr_2_mode0_timing are
# anchored on the same mode-2 interrupt and land their STAT read on the same
# dot as gambatte's m2int_m2stat_1 (traced: both at cycle_counter 85, both
# dispatched from cycle_counter 1), and they want the OTHER answer. Under (b)
# both suites are satisfied at once -- the gambatte read moves an M-cycle
# earlier with the interrupt and sees the old mode, mooneye's later reads see
# the new one -- so (b) is the model, and (a) only looks right because the two
# differ by a single dot at the 2->3 edge.
#
# (b) is not implemented here because it means giving the STAT interrupt line
# its own copy of the mode, asserted 4 dots before the flag, without moving the
# flag itself (the CPU's VRAM/OAM lock edges hang off the flag and are pinned
# by lcdon_timing-GS / intr_2_oam_ok_timing) and without moving LY or the
# vblank interrupt (hblank_ly_scx_timing-GS and vblank_stat_intr-GS measure
# STAT against both). That is a restructure, not a constant.

proc new_ppu_base(cgb: bool): GbPpu =
  result = GbPpu(
    lcd_control:  0x00,
    lcd_status:   0x80,
    first_line:   true,
    current_window_line: 0,
  )
  when STAT_MODE_HOLD: result.stat_lag_cc = STAT_LAG_NONE
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
  result.hdma1 = 0xFF; result.hdma2 = 0xFF; result.hdma3 = 0xFF
  result.hdma4 = 0xFF; result.hdma5 = 0xFF
  result.ran_bios = cgb

method reset_render_scratch*(ppu: GbPpu) {.base.} =
  ## Reset the renderer's per-line scratch to a clean pre-line state. The
  ## savestate is renderer-agnostic and does NOT serialize this scratch
  ## (it is fully rebuilt on every mode 2->3 transition and never read at
  ## vblank, where states are captured). Loading a state onto a FRESH core
  ## is therefore fine, but a rollback restore onto a RUNNING core would
  ## otherwise leave stale scratch (e.g. a FIFO lx past 160 that never hits
  ## its `== 160` line-end and runs off the framebuffer). Called after every
  ## state load; the base (scanline) renderer rebuilds its scratch per line,
  ## so it is a no-op here.
  discard

method skip_boot*(ppu: GbPpu; gb: GB) {.base.} =
  # Reproduce the post-boot VRAM tiles: blank tile $00 (VRAM inits to zero), the
  # Nintendo logo $01-$18 decompressed from the cart's OWN header (so no Nintendo
  # logo data lives in our source), and the generic ® tile $19.
  write_boot_logo(gb.cartridge.rom, ppu.vram[0])
  for i in 0 ..< POST_BOOT_RA_TILE.len:
    ppu.vram[0][0x190 + i] = POST_BOOT_RA_TILE[i]  # tile $19 = byte offset 400
  if gb.cgb_enabled:
    # The CGB boot ROM hands off mid-VBlank (gambatte display_startstate/ly
    # reads LY=0x90); the sub-frame phase is calibrated against gambatte
    # display_startstate/stat_*, div/ and serial/ tests.
    # 159..162 is the window gambatte display_startstate/stat_1+stat_2 leaves
    # open; 161 is the only member of it with the right sub-M-cycle phase.
    # The CPU and the PPU are driven from one clock and every instruction is a
    # whole number of M-cycles, so the offset between the PPU's dot grid and
    # the CPU's M-cycle grid is a fixed property of the machine, identical on
    # DMG and CGB — the boot ROM's handoff only says WHERE in the frame the
    # handoff lands, not where inside an M-cycle. On DMG that offset comes out
    # of the LCDC-enable seed of 5 (mooneye lcdon_timing-GS /
    # hblank_ly_scx_timing-GS): the line ends 457-5 = 452 dots later, a whole
    # number of M-cycles. Matching it here means 457 - phase ≡ 0 (mod 4), i.e.
    # phase ≡ 1 (mod 4). At 160 every CGB row of the gambatte m2int_* families
    # missed its DMG twin by exactly one M-cycle while the DMG rows passed.
    const phase = CGB_BOOT_PHASE
    ppu.ly = uint8(144 + phase div 456)
    ppu.cycle_counter = int32(phase mod 456)
    ppu.lcd_status = (ppu.lcd_status and not 3'u8) or 1'u8  # mode 1
    ppu.first_line = false
  elif gb.boot_model in {bmDmgABC, bmMgb}:
    # Pan Docs, "Console state after boot ROM hand-off" (values recorded at
    # PC = $0100): DMG/MGB hand off with STAT = $85 and LY = $00. Mode 1 with
    # LY reading 0 happens exactly once per frame — on line 153, where LY snaps
    # back to 0 four dots in — so the handoff is inside VBlank's last line, not
    # at the top of line 0, and the LCD has been on since the boot logo (so no
    # first_line quirk). $85's bit 2 is the LYC=LY that seeds from LYC = 0.
    #
    # WHICH dot of line 153 is a property of the boot ROM's length, and it is
    # calibrated the same way the two phases above are — by the ROMs that read
    # the PPU a known number of M-cycles after $0100. Two GBMicrotest families
    # are exactly that instrument, and between them the answer is one dot wide:
    #
    #  * poweron_* — 45 ROMs that pad with N NOPs and then read STAT / LY / OAM
    #    / VRAM. One seed has to satisfy all of them at once: line 0's first
    #    mode-2 M-cycle lands 7 NOPs in (poweron_stat_007 = $86), the line 0->1
    #    advance 114 M-cycles later (poweron_ly_119/_120), and the OAM and VRAM
    #    locks bracket both of mode 3's edges (poweron_oam_069/_070,
    #    poweron_vram_025/_026). They resolve the seed to the M-cycle: 397..400.
    #  * mooneye acceptance/ppu/hblank_ly_scx_timing-GS closes it mod 4. The
    #    PPU's dot grid sits at a fixed offset against the CPU's M-cycle grid
    #    (one clock drives both), and that ROM is what fixes the offset — it is
    #    also what fixes LCD_ON_HEAD_START at 1 mod 4. 397 is the member of the
    #    window that carries it, so the seed and the LCD-enable seed describe
    #    the same machine rather than two.
    #
    # The GBMicrotest hblank_int_scx0..7 family measures the same thing at DOT
    # resolution (sweeping SCX walks the mode 3 -> 0 edge across an M-cycle a
    # dot at a time) and asks for 399 instead: 12 of its rows want the PPU two
    # dots later against the CPU than 397 puts it. That is not this constant's
    # to give. Seeding 399 does buy those 12 and costs hblank_ly_scx_timing-GS
    # itself, its wilbertpol twin, four intr_2_mode0_scx*_timing_nops rows and
    # 28 gambatte rows (halt, m0enable, oam_access, vram_m3, window) — the same
    # single-dot residual STAT_MODE_HOLD is about, moved onto the boot seed.
    # Where the two families disagree, the phase that reproduces both suites'
    # steady-state timing wins over the one that reproduces this ROM's.
    ppu.ly = 0             # line 153, past the LY snapback
    ppu.cycle_counter = int32(DMG_BOOT_PHASE)
    ppu.lcd_status = (ppu.lcd_status and not 3'u8) or 1'u8  # mode 1
    ppu.first_line = false
  elif gb.boot_model == bmDmg0:
    # The DMG0 boot ROM hands off at a different LCD phase than DMG-ABC
    # (which uses the ly=0/cc=0 default above): mooneye boot_hwio-dmg0 reads
    # STAT mid-mode-3 of line 1 / LY=1 shortly after handoff, which places
    # the handoff itself mid-VBlank. Seed found by sweeping that ROM's
    # passing window, 540..708, and taking the center (same method as the
    # per-model DIV seeds in timer.nim).
    const phase = 624  # dots past the start of VBlank (line 144)
    ppu.ly = uint8(144 + phase div 456)
    ppu.cycle_counter = int32(phase mod 456)
    ppu.lcd_status = (ppu.lcd_status and not 3'u8) or 1'u8  # mode 1
    ppu.first_line = false

# Bit 7 of GbPpu.read_mode: LY advanced during the M-cycle a read belongs to.
const LY_JUST_CHANGED* = 0x80'u8

# ---- LCDC helpers ----
proc lcd_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_control and 0x80) != 0

const DOTS_PER_FRAME* = 70224   # 154 lines x 456 dots
# Turning the LCD back on pushes a frame straight away once this much time has
# gone by since the last one, so the panel's output rate survives the gap.
#
# This threshold is a frontend-pacing rule, not a hardware one, and it is worth
# being precise about which: with the PPU off there is no LCD refresh at all
# (the panel just relaxes to white), so hardware has no "frame" to emit and Pan
# Docs defines none. What hardware does define is what happens on re-enable —
# the PPU restarts at the top of line 0, so the next drawn frame's VBlank is
# 144*456 = 65664 dots away — and left alone that stretches the gap between two
# consecutive presents past one frame period, which a frame-paced frontend sees
# as a dropped frame forever after. SameBoy solves it the same way and with the
# same number (Core/memory.c, GB_IO_LCDC: `cycles_since_vblank_callback >
# 10 * 456` -> GB_VBLANK_TYPE_ARTIFICIAL), which is what makes the two agree
# frame-for-frame across LCD toggling; see tools/gbfuzz/sameboy_fps.c. mGBA
# picks the other option and lets the frame run long instead.
const LCD_ON_FRAME_DOTS* = 10 * 456

when defined(gb_dot_counter):
  # Diagnostic frame-pacing instrumentation (tools only; compiled out of every
  # shipping build). gb_total_dots is the panel's dot clock — 4194304 Hz, never
  # scaled by CGB double speed — so frames-per-emulated-second is
  # presents / (gb_total_dots / 4194304).
  var gb_total_dots*: uint64
  var gb_frame_normal*: uint64    # pushed at LY=144, PPU drew it
  var gb_frame_lcd_off*: uint64   # pushed by lcd_off_frame while LCD disabled
  var gb_frame_lcd_on*: uint64    # pushed by the LCDC-enable catch-up

when defined(gb_m3_trace):
  # Diagnostic mode-3 trace (tools only; compiled out of every shipping build).
  # `-d:gb_m3_trace -d:GB_TRACE_LY=n` prints one line per mode-3 dot of line n
  # plus every LCDC write that lands inside that line's mode 3, which is what
  # turns a mid-scanline-write reference image into a solvable equation: the
  # write's dot on one side, the fetcher step that consumed it on the other.
  # See the KNOWN RESIDUAL note in fifo_ppu.nim for the measurement it produced.
  const GB_TRACE_LY* {.intdefine.} = 20

when defined(gb_m3_len):
  # Diagnostic mode-3 LENGTH trace (tools only; compiled out of every shipping
  # build). One line per drawn scanline: the measured mode 3 duration in dots
  # next to the inputs Pan Docs' "Mode 3 length" section says decide it (SCX,
  # WX/WY, and the OBJ X list in fetch order). Scoring the two against each
  # other offline is what turns the gambatte sprites m3stat rows -- which only
  # bracket the end of mode 3 to one M-cycle -- into a per-object dot count.
  var gb_m3_len_lines*: int = 1_000_000

proc ppu_blank_frame*(ppu: GbPpu; gb: GB) =
  ## Push a frame the PPU did not draw: the panel shows white with the PPU
  ## switched off.
  let blank = if gb.cgb_enabled: 0x7FFF'u16 else: DMG_COLORS[0]
  for i in 0 ..< ppu.framebuffer.len: ppu.framebuffer[i] = blank
  ppu.frame = true
  ppu.dots_since_frame = 0

proc lcd_off_frame*(ppu: GbPpu; gb: GB) {.inline.} =
  ## Drive frame output while the LCD is disabled. The panel shows white with
  ## the PPU switched off, but the frontend still needs frames at the usual
  ## rate to keep running; a game that turns the LCD off
  ## to bulk-load VRAM must not stop producing frames. Without this, step_frame
  ## (which runs until ppu.frame is set) makes no progress for as long as the
  ## LCD is off — the emulator drops those frames and, for a game that idles
  ## with the LCD off, never returns at all.
  if ppu.dots_since_frame >= DOTS_PER_FRAME:
    when defined(gb_dot_counter): inc gb_frame_lcd_off
    ppu_blank_frame(ppu, gb)
proc window_tile_map*(ppu: GbPpu): uint8 {.inline.} = ppu.lcd_control and 0x40
proc window_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_control and 0x20) != 0
proc bg_window_tile_data*(ppu: GbPpu): uint8 {.inline.} = ppu.lcd_control and 0x10
proc bg_tile_map*(ppu: GbPpu): uint8 {.inline.} = ppu.lcd_control and 0x08
proc sprite_height*(ppu: GbPpu): int {.inline.} =
  if (ppu.lcd_control and 0x04) != 0: 16 else: 8
proc sprite_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_control and 0x02) != 0
proc bg_display*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_control and 0x01) != 0

# ---- CPU access windows for VRAM and OAM ----
#
# The PPU takes VRAM away from the CPU for the whole of mode 3 and OAM for
# modes 2 and 3; a blocked read returns 0xFF and a blocked write is dropped.
# WHEN each edge lands, to the M-cycle, is what mooneye
# acceptance/ppu/lcdon_timing-GS and lcdon_write_timing-GS pin, and the three
# edges do not all line up with the STAT mode bits:
#
#   * The locks CLOSE on the live mode -- OAM one M-cycle before STAT reads
#     back mode 2 at the top of a line, VRAM one M-cycle before STAT reads back
#     mode 3 -- because it is the STAT mode bits that are late, not the locks.
#   * They OPEN with the STAT bits (the `read_mode` latch), one M-cycle after
#     mode 3 really ends.
#   * A write and a read in the same M-cycle are NOT asked at the same point.
#     A write's byte is applied before that M-cycle's PPU dots (mem_write), so
#     it asks with the mode at the START of the M-cycle -- the live mode as of
#     the call. A read is answered after the dots, so it asks with both the
#     latched mode (`read_mode`, again the mode at the start) and the live one,
#     and any lock closed at either end refuses it. That is what makes an OAM
#     write land on the last M-cycle of mode 2 while an OAM read in the same
#     M-cycle is refused.
#
#     The one thing a write still cannot answer from the start of its M-cycle
#     is whether mode 2 ENDS inside it, and mooneye lcdon_write_timing-GS says
#     that M-cycle's OAM write lands. Mode 2 always ends at dot 80, so the
#     M-cycle's own dot span answers it -- see cpu_oam_open.
#   * On the first line after the LCD is switched on the PPU's dot grid sits
#     2 T-cycles off the CPU's M-cycle grid (see the LCDC-enable write), so
#     every edge on that line rounds to the same M-cycle as the STAT bits do.
#     One line, one flag: `first_line` selects the latched mode for both.
proc cpu_vram_open*(ppu: GbPpu; is_write: bool): bool {.inline.} =
  if not lcd_enabled(ppu): return true
  if is_write:
    # A write is applied BEFORE its M-cycle's dots (see mem_write), so the live
    # mode here already IS the mode at the start of that M-cycle -- the same
    # value read_mode carries once the dots have run. Byte for byte the rule
    # this used to spell as `read_mode != 3`, evaluated at the write's own
    # commit point instead of one M-cycle after it.
    return (ppu.lcd_status and 3'u8) != 3
  if (ppu.read_mode and 3'u8) == 3: return false
  if ppu.first_line: return true
  (ppu.lcd_status and 3'u8) != 3

const OAM_WRITE_M2_TAIL {.intdefine.} = 1
  ## Whether an OAM write is still admitted on the M-cycle mode 2 ends in.
  ##
  ## Pan Docs says OAM belongs to the PPU for the whole of modes 2 and 3, which
  ## is what 0 spells; the exception is a measured one and it is not optional.
  ## Turning it off costs mooneye acceptance/ppu/lcdon_write_timing-GS outright
  ## and takes GBMicrotest 349 -> 347 (oam_write_l1_c and two others), so the
  ## last M-cycle of mode 2 really does still take an OAM write.

proc cpu_oam_open*(ppu: GbPpu; is_write: bool; mcycle_dots: int32 = 0): bool {.inline.} =
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
        # The one place a write still outlives the mode it starts in, and the
        # only thing in either lock that the start of an M-cycle cannot answer
        # on its own. The OAM scan releases the bus at dot 80 while the CPU's
        # write strobe is still to come, so the write lands; mode 2 ALWAYS ends
        # at dot 80, so "does this M-cycle span dot 80" is the same question,
        # and it is what the old post-tick rule was reading off the mode when
        # it asked `live != 2` after the dots had run. mcycle_dots is 4, or 2 in
        # double speed -- the caller has the speed, this does not.
        #
        # Exact for the FIFO renderer, whose dot counter runs 1..80 across mode
        # 2 and stops at 80 on the M-cycle that ends it. The scanline renderer
        # subtracts 80 on that same M-cycle instead, so it can answer one
        # M-cycle early at the boundary; it is the opt-in fast path (GB.fifo)
        # and does not model this edge at dot resolution anyway.
        return ppu.cycle_counter + mcycle_dots > 80
      return true
    else:
      return live != 2
  let lag = ppu.read_mode and 3'u8
  if lag == 3: return false
  if ppu.first_line: return true
  lag != 2 and live != 2 and live != 3

# ---- STAT helpers ----
proc coincidence_interrupt_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x40) != 0
proc oam_interrupt_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x20) != 0
proc vblank_stat_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x10) != 0
proc hblank_interrupt_enabled*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x08) != 0
proc coincidence_flag*(ppu: GbPpu): bool {.inline.} = (ppu.lcd_status and 0x04) != 0
proc `coincidence_flag=`*(ppu: GbPpu; on: bool) {.inline.} =
  if on: ppu.lcd_status = ppu.lcd_status or 0x04
  else:  ppu.lcd_status = ppu.lcd_status and not 0x04'u8
proc mode_flag*(ppu: GbPpu): uint8 {.inline.} = ppu.lcd_status and 0x03

when STAT_MODE_HOLD:
  proc ppu_latch_stat_mode*(ppu: GbPpu; m: uint8) {.inline.} =
    ## Model (a) of STAT_MODE_HOLD: the mode bits a CPU read sees are the
    ## internal mode in effect during the LAST DOT OF THE PREVIOUS TICK,
    ## before whatever transition that dot applied.
    ##
    ## `read_mode`, which is what the shipping build returns, is one dot newer
    ## than that -- it is the mode after the previous tick's last dot,
    ## transitions included. The two therefore differ on exactly one tick per
    ## boundary, and only for boundaries that land on an M-cycle grid line:
    ## mode 2->3 always, mode 3->0 when SCX&7 leaves it there.
    ##
    ## Recording the dot of the change rather than running a countdown is what
    ## keeps this off the per-dot path: this runs once per tick and only ever
    ## compares.
    if ppu.stat_lag_cc <= ppu.cycle_counter:
      ppu.stat_mode = if ppu.stat_lag_cc == ppu.cycle_counter: ppu.stat_prev_mode
                      else: m
      ppu.stat_lag_cc = STAT_LAG_NONE
    else:
      ppu.stat_mode = m

proc stat_read_mode*(ppu: GbPpu): uint8 {.inline.} =
  ## The mode bits a CPU read of STAT returns.
  when STAT_MODE_HOLD: ppu.stat_mode and 3'u8
  else:                ppu.read_mode and 3'u8

# The dot within line 143 at which CGB raises the line-144 mode 2 STAT source.
# See m2_line144 below: 456 - 4 dots, i.e. one M-cycle before the line ends.
const M2_144_EARLY_DOT* = 452'i32

proc m2_line144*(ppu: GbPpu; gb: GB): bool {.inline.} =
  ## Is the mode 2 (OAM) STAT source asserted by the *start of vblank*?
  ##
  ## Besides mode 2 itself, the OAM STAT source goes high once more per frame,
  ## when the PPU enters vblank on line 144 (mooneye vblank_stat_intr). The two
  ## hardware families disagree on exactly when:
  ##
  ##   * DMG/MGB/SGB (vblank_stat_intr-GS): together with the vblank interrupt.
  ##   * CGB/AGB/AGS (misc/ppu/vblank_stat_intr-C): one M-cycle earlier.
  ##
  ## Both ROMs time the interrupt by resetting DIV a fixed number of NOPs into
  ## line 143 and reading it back in the handler. The vblank rounds bracket the
  ## DIV tick at 54/55 NOPs on every model; the STAT rounds bracket it at the
  ## same 54/55 on -GS but at 53/54 on -C, which places the CGB STAT exactly one
  ## M-cycle (4 dots) ahead of the vblank interrupt. So on CGB the source is
  ## already high for the last M-cycle of line 143, while the PPU is still in
  ## mode 0.
  if ppu.ly == 144:
    ppu.mode_flag == 1
  elif ppu.ly == 143:
    gb.cgb_enabled and ppu.mode_flag == 0 and
      ppu.cycle_counter >= M2_144_EARLY_DOT
  else:
    false

proc ppu_handle_stat_interrupt*(ppu: GbPpu; gb: GB) =
  # While the PPU is off the LY=LYC comparison clock is stopped: the coincidence
  # bit freezes at its last value and no STAT interrupt fires (mooneye
  # stat_lyc_onoff — LYC writes while off must not change the retained bit).
  if not ppu.lcd_enabled:
    return
  ppu.coincidence_flag = ppu.ly == ppu.lyc
  let stat_flag =
    (ppu.coincidence_flag   and ppu.coincidence_interrupt_enabled) or
    (ppu.mode_flag == 2     and ppu.oam_interrupt_enabled) or
    # The OAM (mode 2) STAT source also asserts at the start of vblank
    # (line 144) — simultaneously with the vblank interrupt on DMG, one
    # M-cycle earlier on CGB. See m2_line144.
    (ppu.oam_interrupt_enabled and ppu.m2_line144(gb)) or
    (ppu.mode_flag == 0     and ppu.hblank_interrupt_enabled) or
    (ppu.mode_flag == 1     and ppu.vblank_stat_enabled)
  if not ppu.old_stat_flag and stat_flag:
    when defined(gb_stat_read_trace):
      echo "STATIRQ ly=", ppu.ly, " cc=", ppu.cycle_counter,
           " mode=", ppu.mode_flag
    gb.interrupts.lcd_stat_interrupt = true
  ppu.old_stat_flag = stat_flag

proc ppu_stat_write_glitch*(ppu: GbPpu; gb: GB) =
  ## The DMG STAT-write bug. Pan Docs, "Spurious STAT interrupts": "A hardware
  ## quirk in the monochrome Game Boy makes the LCD interrupt sometimes trigger
  ## when writing to STAT (including writing $00) during OAM scan, HBlank,
  ## VBlank, or LY=LYC. It behaves as if $FF were written for one M-cycle, and
  ## then the written value were written the next M-cycle. Because the GBC in
  ## DMG mode does not have this quirk, two games that depend on this quirk
  ## (Ocean's Road Rash and Vic Tokai's Xerd no Densetsu) will not run on a
  ## GBC." The hardware decides, not the cartridge, so the caller gates this on
  ## cgb_enabled and not cgb_native.
  ##
  ## $FF in the enable bits selects every source at once, so the quirk does not
  ## invent a condition — it un-masks whichever one the PPU is already in, and
  ## the STAT line goes high for that one M-cycle. An edge out of it is an
  ## interrupt; holding old_stat_flag high for the rest of the M-cycle is the
  ## other half of the same statement (a source that comes up inside the window
  ## finds the line already high, so it is not a second edge).
  ##
  ## WHERE the window sits is what GBMicrotest's stat_write_glitch_l* rows
  ## measure, and they put it at the write's own commit point rather than at the
  ## M-cycle boundary the store lands on: l1_a and l143_a write on the M-cycle
  ## the mode 3 -> 0 edge falls inside, and hardware stays silent, so the mask
  ## was already gone before mode 0 arrived. That is where every other CPU write
  ## commits (mem_write), and it is also exactly Pan Docs' "one M-cycle, and
  ## then the written value the next": the $FF is the write's data on the bus,
  ## and the deferred store (ppu_defer_machinery_write) is the M-cycle behind it.
  ##
  ## The OAM source is deliberately not in the set. Pan Docs lists OAM scan, but
  ## three of these ROMs write one M-cycle into mode 2 (l0_c, l1_d, l154_c, all
  ## at dot 1 of a line with LY != LYC) and hardware stays silent, while the
  ## siblings one M-cycle earlier — whose M-cycle starts in the previous line's
  ## mode 0 — fire. The OAM source is not a level over mode 2 on hardware: it is
  ## a pulse at the top of a line, which is why it also asserts entering vblank
  ## on line 144, where there is no mode 2 at all (see m2_line144, mooneye
  ## vblank_stat_intr-GS/-C). dingbat models it as a level because the enable
  ## path only ever sees its rising edge; this is the one instrument that samples
  ## the source mid-mode, and it says the pulse is over by dot 1.
  if not ppu.lcd_enabled: return
  if ppu.old_stat_flag: return
  if ppu.ly == ppu.lyc or ppu.mode_flag == 0 or ppu.mode_flag == 1:
    when defined(gb_stat_read_trace):
      echo "STATGLITCH ly=", ppu.ly, " cc=", ppu.cycle_counter,
           " mode=", ppu.mode_flag
    gb.interrupts.lcd_stat_interrupt = true
    ppu.old_stat_flag = true

proc ppu_flush_stat_write*(ppu: GbPpu; gb: GB) =
  ## Take the STAT interrupt edge a CPU write to LCDC/STAT/LYC left pending.
  ## mem_write calls this on the M-cycle boundary that follows the write; the
  ## handful of write_byte callers that are not a CPU M-cycle at all (the
  ## post-boot register table, the cheat engine's RAM pokes) call it directly
  ## so nothing can carry a pending edge into an unrelated M-cycle.
  if ppu.stat_write_pending:
    ppu.stat_write_pending = false
    ppu_handle_stat_interrupt(ppu, gb)

proc ppu_copy_hdma_block*(ppu: GbPpu; gb: GB; block_number: int) =
  for byte in 0 ..< 0x10:
    let offset = 0x10 * block_number + byte
    let src = int(ppu.hdma_src) + offset
    let dst = int(ppu.hdma_dst) + offset
    gb.memory.write_byte(gb, dst, gb.memory.read_byte(gb, src))
    mem_tick_components(gb.memory, gb, 2, from_cpu = false, ignore_speed = true)
  ppu.hdma5 = ppu.hdma5 - 1

proc ppu_step_hdma*(ppu: GbPpu; gb: GB) =
  # The block copy ticks the PPU, which can drive another mode change; without
  # this guard a nested transition back into mode 0 re-enters the copy and
  # recurses until the stack overflows.
  if ppu.hdma_copying: return
  ppu.hdma_copying = true
  ppu_copy_hdma_block(ppu, gb, int(ppu.hdma_pos))
  ppu.hdma_pos += 1
  if ppu.hdma5 == 0xFF: ppu.hdma_active = false
  ppu.hdma_copying = false

proc `mode_flag=`*(ppu: GbPpu; mode: uint8; gb: GB) =
  let prev_mode = ppu.mode_flag
  if ppu.first_line and ppu.mode_flag == 0 and mode == 2: ppu.first_line = false
  if mode == 1: ppu.window_trigger = false
  when STAT_MODE_HOLD:
    if mode != prev_mode:
      # The transition applies from the NEXT dot, so the tick that begins
      # there is the last one whose STAT read still reports the old mode.
      ppu.stat_prev_mode = prev_mode
      ppu.stat_lag_cc    = ppu.cycle_counter + 1
  ppu.lcd_status = (ppu.lcd_status and 0b1111_1100'u8) or mode
  ppu_handle_stat_interrupt(ppu, gb)
  # The HBlank DMA step must run AFTER lcd_status reflects mode 0: the block
  # copy ticks the PPU (mem_tick_components in ppu_copy_hdma_block), and a
  # nested tick that still observes mode 3 re-enters the FIFO renderer's
  # level-triggered `lx >= GB_WIDTH` mode-0 transition and recurses until the
  # stack overflows (Pokemon Crystal crashed at boot). With the status updated
  # first, nested ticks dispatch to the mode-0 branch and simply advance the
  # HBlank dot counter while the copy is in flight.
  #
  # One block per *entry* into HBlank, and only while the LCD is driving the
  # modes. The disabled-LCD path re-asserts mode 0 on every tick, so a
  # level-triggered step ran a block per tick and never terminated (Kirby
  # Tilt 'n' Tumble crashed the process this way); with the LCD off there are
  # no HBlank periods for an armed transfer to advance on.
  if mode == 0 and prev_mode != 0 and ppu.hdma_active and ppu.lcd_enabled:
    ppu_step_hdma(ppu, gb)

proc ppu_update_palette*(palette: var array[4, uint8]; val: uint8) =
  palette[0] = val and 0x3
  palette[1] = (val shr 2) and 0x3
  palette[2] = (val shr 4) and 0x3
  palette[3] = (val shr 6) and 0x3

proc ppu_palette_from_array*(palette: array[4, uint8]): uint8 =
  palette[0] or (palette[1] shl 2) or (palette[2] shl 4) or (palette[3] shl 6)

proc ppu_start_hdma*(ppu: GbPpu; gb: GB; val: uint8) =
  ppu.hdma_src = (uint16(ppu.hdma1) shl 8 or uint16(ppu.hdma2)) and 0xFFF0'u16
  ppu.hdma_dst = 0x8000'u16 + ((uint16(ppu.hdma3) shl 8 or uint16(ppu.hdma4)) and 0x1FF0'u16)
  ppu.hdma5    = val and 0x7F
  if (val and 0x80) != 0:
    ppu.hdma_active = true
    ppu.hdma_pos    = 0
    # Arming an HBlank transfer while the PPU is *already* in HBlank starts it
    # right away — the edge into mode 0 has passed, so waiting for the next one
    # would lose a block per transfer. With the LCD off the mode reads 0
    # forever, which is why an armed transfer still makes exactly this much
    # progress and no more.
    if ppu.mode_flag == 0 or not ppu.lcd_enabled:
      ppu_step_hdma(ppu, gb)
  else:
    if not ppu.hdma_active:
      for bn in 0 .. int(ppu.hdma5):
        ppu_copy_hdma_block(ppu, gb, bn)
    ppu.hdma_active = false

# ---- Which half of a CPU write moves, and which does not --------------------
#
# mem_write commits a write's byte at the top of its M-cycle because the mode-3
# pixel pipeline was running an M-cycle ahead of the CPU. That compensation is
# only correct for what the PIPELINE reads; everything else in the PPU was
# already in phase and must keep the commit point it had. Three cases, each
# settled by the ROMs that isolate it rather than by the rule:
#
#   * Pipeline registers -- SCX, SCY, WX, WY, the palettes, VBK, VRAM and OAM.
#     The byte moves. That is the whole point (gambatte bgtiledata/bgtilemap,
#     mealybug m3_*).
#   * Registers that GATE a PPU event -- STAT's source-enable bits and FF55.
#     The whole store waits for the M-cycle boundary, so a mode edge inside
#     those dots is still gated by the value the CPU has not replaced yet.
#     gambatte m0enable/disable_* (16 ROMs sweeping SCX across the mode 3->0
#     edge) and dma/hdma_late_disable_* exist to time exactly this; committing
#     early lets the CPU suppress an interrupt, or a HBlank block, that hardware
#     still delivers. With the store held back, every STAT-write family --
#     m0enable, m1, m2enable -- is byte-for-byte what it was before the reorder.
#   * Registers the PPU itself updates or compares against -- LYC and IF. The
#     byte moves, and the ROMs say so: ly_lyc_write-GS times an LYC write
#     against the LY advance, and gbmicrotest vblank_int_if_c / vblank2_int_if_c
#     / lyc1_int_if_edge_c time an IF clear against the flag the PPU raises.
#     Both want the CPU's store to win inside its own M-cycle.
#
# LCDC straddles the first and second cases -- the pipeline reads six of its
# bits and the mode machinery reads bit 7 -- so its byte moves and only its
# effect on the STAT line is held back (stat_write_pending).
proc ppu_write_machinery*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
  case idx
  of 0xFF41:
    ppu.lcd_status = (ppu.lcd_status and 0b1000_0111'u8) or (val and 0b0111_1000'u8)
    ppu_handle_stat_interrupt(ppu, gb)
  of 0xFF55:
    ppu_start_hdma(ppu, gb, val)
  else: discard

proc ppu_defer_machinery_write*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
  ## Park one of the two above until the M-cycle boundary (mem_flush_deferred).
  ## The slot is drained first: the bus path can only fill it once per M-cycle,
  ## but the write_byte callers that are not an M-cycle at all (the post-boot
  ## register table, cheat pokes) can, and none of them may lose a store.
  if gb.memory.deferred_reg != 0:
    ppu_write_machinery(ppu, gb, int(gb.memory.deferred_reg), gb.memory.deferred_val)
  gb.memory.deferred_reg = uint16(idx)
  gb.memory.deferred_val = val
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
    # OAM is inaccessible to the CPU during OAM scan (mode 2) and drawing
    # (mode 3): reads return 0xFF. See cpu_oam_open for where the two edges sit
    # (mooneye intr_2_oam_ok_timing, lcdon_timing-GS).
    if cpu_oam_open(ppu, is_write = false): ppu.sprite_table[idx - 0xFE00]
    else: 0xFF'u8
  of 0xFF40:         ppu.lcd_control
  of 0xFF41:
    when defined(gb_stat_read_trace):
      # Diagnostic only (tools; compiled out of every shipping build). What
      # the m2int_* derivation in STAT_MODE_HOLD was traced with.
      echo "STATRD ly=", ppu.ly, " cc=", ppu.cycle_counter,
           " rm=", ppu.read_mode and 3'u8, " live=", ppu.lcd_status and 3'u8
    # The mode bits (0-1) lag one read M-cycle behind the internal mode: use the
    # snapshot taken at the start of this read's PPU tick (see GbPpu.read_mode).
    # STAT_MODE_HOLD is the open question about whether that lag is one dot
    # short; it ships off, and stat_read_mode is then exactly `read_mode`.
    let rm = stat_read_mode(ppu)
    var live = (ppu.lcd_status and 0b1111_1100'u8) or rm
    # The LY=LYC comparator does not follow LY instantaneously: the M-cycle in
    # which LY advances reads back with the coincidence bit CLEAR whatever LYC
    # holds, and the comparison re-appears one M-cycle later. mooneye
    # acceptance/ppu/lcdon_timing-GS pins both halves of that -- at the M-cycle
    # of the line 0->1 advance it wants bit 2 clear for LYC=1 (a comparison that
    # has just become true) *and* for LYC=0 (one that has just become false), so
    # this is a suppression window, not a one-M-cycle-stale copy of the bit.
    if (ppu.read_mode and LY_JUST_CHANGED) != 0:
      live = live and not 0b0000_0100'u8
    # Leaving vblank, DMG's two mode bits do not move together: bit 0 drops as
    # mode 1 ends and bit 1 only comes up an M-cycle later, so the M-cycle the
    # 1 -> 2 transition falls inside reads back as mode 0. Nothing else in the
    # frame shows it -- every other line enters mode 2 out of mode 0, where the
    # bits are already 00 -- and it is the same shape as the `first_line` rule
    # above, which is mode 2 read as 0 for a whole line after an LCD enable.
    #
    # Three ROMs from two suites pin it, and they also pin it to DMG:
    # gbmicrotest poweron_stat_006 (STAT read on exactly that M-cycle, $84 not
    # $85) and mooneye-wilbertpol ly00_mode0_2-GS and ly00_mode1_0-GS. Its
    # CGB sibling ly00_mode1_2-C wants the plain lagged value, which is why the
    # hardware test is here rather than in `live` unconditionally.
    if (ppu.first_line and rm == 2) or
       (rm == 1 and not gb.cgb_enabled and (ppu.lcd_status and 3'u8) == 2):
      live and 0b1111_1100'u8
    else:
      live
  of 0xFF42: ppu.scy
  of 0xFF43: ppu.scx
  of 0xFF44: ppu.ly
  of 0xFF45: ppu.lyc
  of 0xFF46: 0xFF'u8  # DMA (write-only, return 0xFF)
  of 0xFF47: ppu_palette_from_array(ppu.bgp)
  of 0xFF48: ppu_palette_from_array(ppu.obp0)
  of 0xFF49: ppu_palette_from_array(ppu.obp1)
  of 0xFF4A: ppu.wy
  of 0xFF4B: ppu.wx
  of 0xFF4F: (if gb.cgb_enabled: 0xFE'u8 or ppu.vram_bank else: 0xFF'u8)
  of 0xFF51: (if gb.cgb_native: ppu.hdma1 else: 0xFF'u8)
  of 0xFF52: (if gb.cgb_native: ppu.hdma2 else: 0xFF'u8)
  of 0xFF53: (if gb.cgb_native: ppu.hdma3 else: 0xFF'u8)
  of 0xFF54: (if gb.cgb_native: ppu.hdma4 else: 0xFF'u8)
  of 0xFF55: (if gb.cgb_native: ppu.hdma5 else: 0xFF'u8)
  of 0xFF68:
    if gb.cgb_enabled:
      0x40'u8 or (if ppu.auto_increment: 0x80'u8 else: 0'u8) or ppu.palette_index
    else: 0xFF'u8
  of 0xFF69: (if gb.cgb_native: ppu.pram[ppu.palette_index] else: 0xFF'u8)
  of 0xFF6A:
    if gb.cgb_enabled:
      0x40'u8 or (if ppu.obj_auto_increment: 0x80'u8 else: 0'u8) or ppu.obj_palette_index
    else: 0xFF'u8
  of 0xFF6B: (if gb.cgb_native: ppu.obj_pram[ppu.obj_palette_index] else: 0xFF'u8)
  else: 0xFF'u8

proc ppu_write*(ppu: GbPpu; gb: GB; idx: int; val: uint8) =
  case idx
  of 0x8000..0x9FFF: ppu.vram[ppu.vram_bank][idx - 0x8000] = val
  of 0xFE00..0xFE9F: ppu.sprite_table[idx - 0xFE00] = val
  of 0xFF40:
    if (val and 0x80) != 0 and not ppu.lcd_enabled:
      # The PPU restarts at the top of the frame, so the next frame it draws is
      # 65664 dots away. If enough time has already passed since the last
      # present, push one now rather than let the gap stretch — skipping it
      # leaves the emulator one frame ahead of the panel for the rest of the
      # run, and games toggle the LCD constantly. See LCD_ON_FRAME_DOTS for why
      # this is a pacing rule rather than a hardware one.
      if ppu.dots_since_frame > LCD_ON_FRAME_DOTS:
        when defined(gb_dot_counter): inc gb_frame_lcd_on
        ppu_blank_frame(ppu, gb)
      ppu.ly = 0
      # The re-enabled PPU is already part-way into its first line by the time
      # the LCDC write retires -- it does not start at dot 0 there. This seed is
      # the whole of that head start, and because every line is a multiple of
      # 4 dots long it is also the PPU's dot phase against the CPU's M-cycle
      # grid for the rest of the run. Two tests pin it, and between them there
      # is exactly one answer:
      #
      #  * mooneye acceptance/ppu/lcdon_timing-GS reads LY and STAT at known
      #    M-cycle offsets from the write and pins all three of line 0's
      #    boundaries (mode 2->3, mode 3->0, and LY 0->1); the line-1 and line-2
      #    boundaries it also samples are a plain 456 dots apart, so only line 0
      #    is special. Those three fix the head start to 5..8 dots.
      #  * mooneye acceptance/ppu/hblank_ly_scx_timing-GS then fixes it mod 4.
      #    It measures the gap from the mode-0 STAT interrupt to the LY advance
      #    with SCX&7 = 0..7, which walks the mode-3 end across one M-cycle a
      #    dot at a time, and the gap has to shorten between SCX&7 = 0 and 1 --
      #    i.e. the M-cycle boundary sits immediately after the SCX&7 = 0 end
      #    dot, not three dots later. That is a head start of 1 mod 4.
      #
      # 5 is the only value satisfying both. Physically it is the 2-T-cycle
      # skew mooneye's own notes describe (the PPU restarts mid-M-cycle, so
      # line 0 ends 2 T-cycles off the grid and the next line lands back on it),
      # rounded into this renderer's whole-dot counter. No rendered pixel moves:
      # mode 3 is still driven to 160 pixels by the shifter, not by this counter.
      #
      # Both of those ROMs measure the head start from an M-cycle BOUNDARY, and
      # this is the one write whose effect is a restart of the PPU's own clock:
      # the counter has to read 5 once this M-cycle's dots have run, not when
      # the byte lands at the top of it (mem_write applies CPU writes before the
      # dots). Backing the M-cycle out is what keeps the constant the one those
      # two ROMs pin at BOTH speeds -- an M-cycle is 2 dots in double speed, and
      # seeding 5 flat there restarts the PPU one double-speed M-cycle late
      # (gambatte enable_display/frame0_m2stat_count_ds_*, m2enable/disable_ds_*).
      ppu.cycle_counter = int32(int(LCD_ON_HEAD_START) - (4 shr gb.memory.current_speed))
      ppu.`mode_flag=`(2'u8, gb)
      ppu.first_line = true
    when defined(gb_m3_trace):
      if int(ppu.ly) == GB_TRACE_LY and (ppu.lcd_status and 3) == 3:
        let fp = if ppu of GbFifoPpu: $GbFifoPpu(ppu).fetch_counter &
                    " lx=" & $GbFifoPpu(ppu).lx & " fx=" & $GbFifoPpu(ppu).fetcher_x
                 else: "?"
        echo "LCDC ly=", ppu.ly, " dot=", ppu.cycle_counter, " old=",
             toHex(ppu.lcd_control, 2), " new=", toHex(val, 2), " fc=", fp
    ppu.lcd_control = val
    # Deferred to the end of this M-cycle -- see GbPpu.stat_write_pending and
    # the consume in mem_write. The LCD-enable branch above is NOT deferred:
    # that one restarts the mode machinery itself rather than feeding it.
    ppu.stat_write_pending = true
    gb.memory.write_deferred = true
  of 0xFF41:
    # DMG only, and paid for by one predictable branch on a register write that
    # is already doing more than this. See ppu_stat_write_glitch: the $FF phase
    # of the write acts here, at the write's commit point, and only the real
    # value waits for the M-cycle boundary.
    if not gb.cgb_enabled: ppu_stat_write_glitch(ppu, gb)
    ppu_defer_machinery_write(ppu, gb, idx, val)
  of 0xFF42: ppu.scy = val
  of 0xFF43:
    when defined(gb_m3_trace):
      # Same instrument as the LCDC line above, for the scroll register: which
      # dot of which line an SCX write lands on is what pins the fine-scroll
      # latch against it (see fifo_sample_smooth_scroll's caller).
      echo "SCX ly=", ppu.ly, " dot=", ppu.cycle_counter,
           " mode=", (ppu.lcd_status and 3), " old=", ppu.scx, " new=", val
    ppu.scx = val
  of 0xFF44: discard  # read-only
  of 0xFF45:
    # NOT deferred, unlike STAT and FF55 next door: LYC is the LY comparator's
    # other input, and mooneye-wilbertpol acceptance/gpu/ly_lyc_write-GS times an
    # LYC write against the LY advance and wants the new value to win inside its
    # own M-cycle. That row is RED on main and green with the byte committed at
    # the top of the M-cycle; deferring it puts it back to red and takes
    # gambatte lycEnable 166 -> 163. Only the STAT edge is held back.
    ppu.lyc = val
    ppu.stat_write_pending = true
    gb.memory.write_deferred = true
  of 0xFF46: discard  # handled by memory DMA
  of 0xFF47: ppu_update_palette(ppu.bgp,  val)
  of 0xFF48: ppu_update_palette(ppu.obp0, val)
  of 0xFF49: ppu_update_palette(ppu.obp1, val)
  of 0xFF4A: ppu.wy = val
  of 0xFF4B: ppu.wx = val
  of 0xFF4F:
    if gb.cgb_enabled: ppu.vram_bank = val and 0x1
  of 0xFF51:
    if gb.cgb_native: ppu.hdma1 = val
  of 0xFF52:
    if gb.cgb_native: ppu.hdma2 = val
  of 0xFF53:
    if gb.cgb_native: ppu.hdma3 = val
  of 0xFF54:
    if gb.cgb_native: ppu.hdma4 = val
  of 0xFF55:
    if gb.cgb_native: ppu_defer_machinery_write(ppu, gb, idx, val)
  of 0xFF68:
    if gb.cgb_enabled:
      ppu.palette_index  = val and 0x3F
      ppu.auto_increment = (val and 0x80) != 0
  of 0xFF69:
    if gb.cgb_native:
      ppu.pram[ppu.palette_index] = val
      if ppu.auto_increment:
        ppu.palette_index = (ppu.palette_index + 1) and 0x3F
  of 0xFF6A:
    if gb.cgb_enabled:
      ppu.obj_palette_index  = val and 0x3F
      ppu.obj_auto_increment = (val and 0x80) != 0
  of 0xFF6B:
    if gb.cgb_native:
      ppu.obj_pram[ppu.obj_palette_index] = val
      if ppu.obj_auto_increment:
        ppu.obj_palette_index = (ppu.obj_palette_index + 1) and 0x3F
  else: discard

method tick*(ppu: GbPpu; gb: GB; cycles: int) {.base.} = discard
