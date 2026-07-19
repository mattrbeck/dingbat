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
  for i in 0 ..< POST_BOOT_VRAM.len:
    ppu.vram[0][i] = POST_BOOT_VRAM[i]
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

proc ppu_handle_stat_interrupt*(ppu: GbPpu; gb: GB) =
  ppu.coincidence_flag = ppu.ly == ppu.lyc
  let stat_flag =
    (ppu.coincidence_flag   and ppu.coincidence_interrupt_enabled) or
    (ppu.mode_flag == 2     and ppu.oam_interrupt_enabled) or
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
  ppu_copy_hdma_block(ppu, gb, int(ppu.hdma_pos))
  ppu.hdma_pos += 1
  if ppu.hdma5 == 0xFF: ppu.hdma_active = false

proc `mode_flag=`*(ppu: GbPpu; mode: uint8; gb: GB) =
  if mode == 0 and ppu.hdma_active: ppu_step_hdma(ppu, gb)
  if ppu.first_line and ppu.mode_flag == 0 and mode == 2: ppu.first_line = false
  if mode == 1: ppu.window_trigger = false
  ppu.lcd_status = (ppu.lcd_status and 0b1111_1100'u8) or mode
  ppu_handle_stat_interrupt(ppu, gb)

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
  of 0xFE00..0xFE9F: ppu.sprite_table[idx - 0xFE00]
  of 0xFF40:         ppu.lcd_control
  of 0xFF41:
    if ppu.first_line and ppu.mode_flag == 2:
      ppu.lcd_status and 0b1111_1100'u8
    else:
      ppu.lcd_status
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
