# GB PPU shared base (included by gb.nim)

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
    const phase = 160  # gambatte display_startstate/stat_1+stat_2 (159..162)
    ppu.ly = uint8(144 + phase div 456)
    ppu.cycle_counter = int32(phase mod 456)
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
    gb.interrupts.lcd_stat_interrupt = true
  ppu.old_stat_flag = stat_flag

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
    # (mode 3): reads return 0xFF. Uses the read-latched mode so the accessible
    # window lines up one M-cycle late, matching STAT reads (mooneye
    # intr_2_oam_ok_timing). first_line mode 2 reads back as mode 0, and OAM is
    # accessible during it.
    if lcd_enabled(ppu) and not (ppu.first_line and ppu.read_mode == 2) and
       (ppu.read_mode == 2 or ppu.read_mode == 3):
      0xFF'u8
    else:
      ppu.sprite_table[idx - 0xFE00]
  of 0xFF40:         ppu.lcd_control
  of 0xFF41:
    # The mode bits (0-1) lag one read M-cycle behind the internal mode: use the
    # snapshot taken at the start of this read's PPU tick (see GbPpu.read_mode).
    let live = (ppu.lcd_status and 0b1111_1100'u8) or ppu.read_mode
    if ppu.first_line and ppu.read_mode == 2:
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
      ppu.`mode_flag=`(2'u8, gb)
      ppu.first_line = true
    ppu.lcd_control = val
    ppu_handle_stat_interrupt(ppu, gb)
  of 0xFF41:
    ppu.lcd_status = (ppu.lcd_status and 0b1000_0111'u8) or (val and 0b0111_1000'u8)
    ppu_handle_stat_interrupt(ppu, gb)
  of 0xFF42: ppu.scy = val
  of 0xFF43: ppu.scx = val
  of 0xFF44: discard  # read-only
  of 0xFF45:
    ppu.lyc = val
    ppu_handle_stat_interrupt(ppu, gb)
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
    if gb.cgb_native: ppu_start_hdma(ppu, gb, val)
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
