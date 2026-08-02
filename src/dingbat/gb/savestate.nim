# GB/GBC save-state serialization (included by gb.nim).
#
# States are only written at frame boundaries (right after step_frame
# returns), i.e. at the start of vblank. Renderer-specific state (the FIFO
# renderer's fetcher/FIFO machinery, the scanline renderer's per-line
# scratch) is deliberately NOT serialized: both renderers fully re-initialize
# their per-line fetch state on the mode 2 -> 3 transition, and no such state
# survives vblank. This also makes states renderer-agnostic — a state saved
# with the FIFO renderer loads fine under the scanline renderer and vice
# versa. The ROM is not stored; the header carries a checksum + size.

const
  GB_SEC_CPU   = 0xB1'u8
  GB_SEC_IRQ   = 0xB2'u8
  GB_SEC_TIMER = 0xB3'u8
  GB_SEC_JOY   = 0xB4'u8
  GB_SEC_MEM   = 0xB5'u8
  GB_SEC_SCHED = 0xB6'u8
  GB_SEC_PPU   = 0xB7'u8
  GB_SEC_APU   = 0xB8'u8
  GB_SEC_MBC   = 0xB9'u8
  GB_SEC_SER   = 0xBA'u8
  GB_SEC_END   = 0xBF'u8

# ---- CPU ----

proc save_cpu_state(cpu: GbCpu; w: var Writer) =
  w.write_tag(GB_SEC_CPU)
  w.write_u16(cpu.af)
  w.write_u16(cpu.bc)
  w.write_u16(cpu.de)
  w.write_u16(cpu.hl)
  w.write_u16(cpu.pc)
  w.write_u16(cpu.sp)
  w.write_bool(cpu.ime)
  w.write_bool(cpu.halted)
  w.write_bool(cpu.halt_bug)
  w.write_bool(cpu.locked)

proc load_cpu_state(cpu: GbCpu; r: var Reader; rev: uint32) =
  r.expect_tag(GB_SEC_CPU)
  cpu.af = r.read_u16()
  cpu.bc = r.read_u16()
  cpu.de = r.read_u16()
  cpu.hl = r.read_u16()
  cpu.pc = r.read_u16()
  cpu.sp = r.read_u16()
  cpu.ime = r.read_bool()
  cpu.halted = r.read_bool()
  cpu.halt_bug = r.read_bool()
  # rev 4 added the undefined-opcode lockup flag. Older states can only have
  # been written by a build where those opcodes were 4-cycle no-ops, so a
  # missing field means "not locked".
  cpu.locked = if rev >= 4: r.read_bool() else: false
  cpu.cached_hl = -1  # per-instruction scratch

# ---- Interrupts / Timer / Joypad ----

proc save_irq_state(irq: GbInterrupts; w: var Writer) =
  w.write_tag(GB_SEC_IRQ)
  w.write_u8(irq_read(irq, 0xFF0F))
  w.write_u8(irq_read(irq, 0xFFFF))

proc load_irq_state(irq: GbInterrupts; r: var Reader) =
  r.expect_tag(GB_SEC_IRQ)
  irq_write(irq, 0xFF0F, r.read_u8())
  irq_write(irq, 0xFFFF, r.read_u8())

proc save_timer_state(t: GbTimer; w: var Writer) =
  w.write_tag(GB_SEC_TIMER)
  w.write_u16(t.tdiv)
  w.write_u8(t.tima)
  w.write_u8(t.tma)
  w.write_bool(t.enabled)
  w.write_u8(t.clock_select)
  w.write_i32(int32(t.bit_for_tima))
  w.write_bool(t.previous_bit)
  w.write_i32(int32(t.countdown))

proc load_timer_state(t: GbTimer; r: var Reader) =
  r.expect_tag(GB_SEC_TIMER)
  t.tdiv = r.read_u16()
  t.tima = r.read_u8()
  t.tma = r.read_u8()
  t.enabled = r.read_bool()
  t.clock_select = r.read_u8()
  t.bit_for_tima = int(r.read_i32())
  t.previous_bit = r.read_bool()
  t.countdown = int(r.read_i32())

proc save_serial_state(s: GbSerial; w: var Writer) =
  # The driver (link cable binding) is not serialized; see set_serial_driver
  w.write_tag(GB_SEC_SER)
  w.write_u8(s.sb)
  w.write_u8(s.sc)
  w.write_u8(s.out_latch)
  w.write_u8(uint8(s.bits_remaining))
  w.write_u8(s.clock_history)
  w.write_bool(s.shifting)

proc load_serial_state(s: GbSerial; r: var Reader; rev: uint32) =
  if rev < 2:
    # rev 1 has no serial section at all: the port was a stub then (SB captured
    # for test output, SC ignored), so no transfer could ever be in flight.
    # Idle is not a fallback here, it is the only state the writing build could
    # represent.
    s.sb = 0
    s.sc = 0
    s.out_latch = 0
    s.bits_remaining = 0
    s.clock_history = 0
    s.shifting = false
    return
  r.expect_tag(GB_SEC_SER)
  s.sb = r.read_u8()
  s.sc = r.read_u8()
  s.out_latch = r.read_u8()
  s.bits_remaining = int(r.read_u8())
  # rev 2 wrote a bool `previous_bit` in this byte for its first few hours
  # (0956322 -> f678d02) before it became the clock_history shift register.
  # Same width, and 0 — the value in any state not taken mid-transfer — means
  # "clock low" under both readings.
  s.clock_history = r.read_u8()
  s.shifting = r.read_bool()

proc save_joypad_state(j: GbJoypad; w: var Writer) =
  # Only the select lines (written by the game); pressed-key state stays
  # live since it reflects currently held host keys
  w.write_tag(GB_SEC_JOY)
  w.write_bool(j.button_keys)
  w.write_bool(j.direction_keys)

proc load_joypad_state(j: GbJoypad; r: var Reader) =
  r.expect_tag(GB_SEC_JOY)
  j.button_keys = r.read_bool()
  j.direction_keys = r.read_bool()
  # Key presses are live input rather than saved state, so re-seed the
  # joypad-interrupt edge detector from whatever is held now. Keeping the
  # pre-load value could otherwise manufacture a phantom press interrupt.
  joypad_sync(j)

# ---- Memory ----

proc save_mem_state(mem: GbMemory; w: var Writer) =
  w.write_tag(GB_SEC_MEM)
  for i in 0 ..< 8: w.write_bytes(mem.wram[i])
  w.write_u8(mem.wram_bank)
  w.write_bytes(mem.hram)
  w.write_seq_u8(mem.bootrom)
  w.write_u8(mem.ff72)
  w.write_u8(mem.ff73)
  w.write_u8(mem.ff74)
  w.write_u8(mem.ff75)
  w.write_u8(mem.dma)
  w.write_u16(mem.current_dma_source)
  w.write_i32(int32(mem.internal_dma_timer))
  w.write_i32(int32(mem.dma_position))
  w.write_bool(mem.requested_oam_dma)
  w.write_u8(mem.next_dma_counter)
  w.write_bool(mem.requested_speed_switch)
  w.write_u8(mem.current_speed)

proc load_mem_state(mem: GbMemory; r: var Reader) =
  r.expect_tag(GB_SEC_MEM)
  for i in 0 ..< 8: r.read_bytes(mem.wram[i])
  mem.wram_bank = r.read_u8()
  r.read_bytes(mem.hram)
  mem.bootrom = r.read_seq_u8()
  mem.ff72 = r.read_u8()
  mem.ff73 = r.read_u8()
  mem.ff74 = r.read_u8()
  mem.ff75 = r.read_u8()
  mem.dma = r.read_u8()
  mem.current_dma_source = r.read_u16()
  mem.internal_dma_timer = int(r.read_i32())
  mem.dma_position = int(r.read_i32())
  mem.requested_oam_dma = r.read_bool()
  mem.next_dma_counter = r.read_u8()
  mem.requested_speed_switch = r.read_bool()
  mem.current_speed = r.read_u8()
  mem.cycle_tick_count = 0  # per-instruction scratch, zero between frames
  # Derived caches, not payload: re-deriving them costs nothing and keeps the
  # section byte-for-byte what it was, so no payload-revision bump.
  mem.dma_busy = mem.dma_position > 0 and mem.dma_position <= 0xA0
  # dma_bus / dma_drive / dma_latch are re-derived once the cartridge and PPU
  # sections have landed, in gb_apply_state.

# ---- PPU (renderer-agnostic base state only, see file comment) ----

proc save_ppu_state(ppu: GbPpu; w: var Writer) =
  w.write_tag(GB_SEC_PPU)
  w.write_u8(ppu.lcd_control)
  w.write_u8(ppu.lcd_status)
  w.write_u8(ppu.scy)
  w.write_u8(ppu.scx)
  w.write_u8(ppu.ly)
  w.write_u8(ppu.lyc)
  w.write_bytes(ppu.bgp)
  w.write_bytes(ppu.obp0)
  w.write_bytes(ppu.obp1)
  w.write_u8(ppu.wy)
  w.write_u8(ppu.wx)
  w.write_u8(ppu.vram_bank)
  w.write_bytes(ppu.pram)
  w.write_u8(ppu.palette_index)
  w.write_bool(ppu.auto_increment)
  w.write_bytes(ppu.obj_pram)
  w.write_u8(ppu.obj_palette_index)
  w.write_bool(ppu.obj_auto_increment)
  w.write_bytes(ppu.vram[0])
  w.write_bytes(ppu.vram[1])
  w.write_bytes(ppu.sprite_table)
  w.write_u8(ppu.hdma1)
  w.write_u8(ppu.hdma2)
  w.write_u8(ppu.hdma3)
  w.write_u8(ppu.hdma4)
  w.write_u8(ppu.hdma5)
  w.write_u16(ppu.hdma_src)
  w.write_u16(ppu.hdma_dst)
  w.write_u16(ppu.hdma_pos)
  w.write_bool(ppu.hdma_active)
  w.write_i32(ppu.dots_since_frame)
  w.write_bool(ppu.window_trigger)
  w.write_i32(int32(ppu.current_window_line))
  w.write_bool(ppu.old_stat_flag)
  w.write_bool(ppu.first_line)
  w.write_i32(ppu.cycle_counter)
  w.write_bool(ppu.ran_bios)
  w.write_seq_u16(ppu.framebuffer)

proc load_ppu_state(ppu: GbPpu; r: var Reader; rev: uint32) =
  r.expect_tag(GB_SEC_PPU)
  ppu.lcd_control = r.read_u8()
  ppu.lcd_status = r.read_u8()
  ppu.scy = r.read_u8()
  ppu.scx = r.read_u8()
  ppu.ly = r.read_u8()
  ppu.lyc = r.read_u8()
  r.read_bytes(ppu.bgp)
  r.read_bytes(ppu.obp0)
  r.read_bytes(ppu.obp1)
  ppu.wy = r.read_u8()
  ppu.wx = r.read_u8()
  ppu.vram_bank = r.read_u8()
  r.read_bytes(ppu.pram)
  ppu.palette_index = r.read_u8()
  ppu.auto_increment = r.read_bool()
  r.read_bytes(ppu.obj_pram)
  ppu.obj_palette_index = r.read_u8()
  ppu.obj_auto_increment = r.read_bool()
  r.read_bytes(ppu.vram[0])
  r.read_bytes(ppu.vram[1])
  r.read_bytes(ppu.sprite_table)
  ppu.hdma1 = r.read_u8()
  ppu.hdma2 = r.read_u8()
  ppu.hdma3 = r.read_u8()
  ppu.hdma4 = r.read_u8()
  ppu.hdma5 = r.read_u8()
  ppu.hdma_src = r.read_u16()
  ppu.hdma_dst = r.read_u16()
  ppu.hdma_pos = r.read_u16()
  ppu.hdma_active = r.read_bool()
  if rev >= 3:
    ppu.dots_since_frame = r.read_i32()
  else:
    # The panel's refresh clock, reset to 0 at every frame push — both the
    # normal one at LY=144 and the blank one lcd_off_frame pushes. States are
    # only ever written at a frame boundary, so this counter is 0 there give or
    # take the dots left in the instruction that tripped the boundary (tens of
    # dots against a 70224-dot frame). It is only ever compared against
    # whole-frame thresholds, so 0 is right to well within a scanline.
    ppu.dots_since_frame = 0
  ppu.window_trigger = r.read_bool()
  ppu.current_window_line = int(r.read_i32())
  ppu.old_stat_flag = r.read_bool()
  ppu.first_line = r.read_bool()
  ppu.cycle_counter = r.read_i32()
  ppu.ran_bios = r.read_bool()
  r.read_seq_u16_into(ppu.framebuffer)
  ppu.frame = false
  # Renderer scratch isn't serialized; clear it so a load onto a running
  # core (rollback) can't inherit stale per-line fetch state.
  ppu.reset_render_scratch()

# ---- APU ----

proc save_channel_base(ch: GbSoundChannel; w: var Writer) =
  w.write_bool(ch.enabled)
  w.write_bool(ch.dac_enabled)
  w.write_i32(int32(ch.length_counter))
  w.write_bool(ch.length_enable)

proc load_channel_base(ch: GbSoundChannel; r: var Reader) =
  ch.enabled = r.read_bool()
  ch.dac_enabled = r.read_bool()
  ch.length_counter = int(r.read_i32())
  ch.length_enable = r.read_bool()

proc save_channel_env(ch: GbVolumeEnvChannel; w: var Writer) =
  save_channel_base(ch, w)
  w.write_u8(ch.starting_volume)
  w.write_bool(ch.envelope_add_mode)
  w.write_u8(ch.period)
  w.write_u8(ch.volume_envelope_timer)
  w.write_u8(ch.current_volume)
  w.write_bool(ch.vol_env_is_updating)

proc load_channel_env(ch: GbVolumeEnvChannel; r: var Reader) =
  load_channel_base(ch, r)
  ch.starting_volume = r.read_u8()
  ch.envelope_add_mode = r.read_bool()
  ch.period = r.read_u8()
  ch.volume_envelope_timer = r.read_u8()
  ch.current_volume = r.read_u8()
  ch.vol_env_is_updating = r.read_bool()

proc save_apu_state(apu: GbApu; w: var Writer) =
  w.write_tag(GB_SEC_APU)
  w.write_bool(apu.sound_enabled)
  w.write_u8(uint8(apu.frame_sequencer_stage))
  w.write_bool(apu.first_half_of_length_period)
  w.write_bool(apu.left_enable)
  w.write_u8(apu.left_volume)
  w.write_bool(apu.right_enable)
  w.write_u8(apu.right_volume)
  w.write_u8(apu.nr51)
  block:
    let ch = apu.channel1
    save_channel_env(ch, w)
    w.write_i32(int32(ch.wave_duty_position))
    w.write_u8(ch.sweep_period)
    w.write_bool(ch.negate)
    w.write_u8(ch.shift)
    w.write_u8(ch.sweep_timer)
    w.write_u16(ch.frequency_shadow)
    w.write_bool(ch.sweep_enabled)
    w.write_bool(ch.negate_used)
    w.write_u8(ch.duty)
    w.write_u8(ch.length_load)
    w.write_u16(ch.frequency)
  block:
    let ch = apu.channel2
    save_channel_env(ch, w)
    w.write_i32(int32(ch.wave_duty_position))
    w.write_u8(ch.duty)
    w.write_u8(ch.length_load)
    w.write_u16(ch.frequency)
  block:
    let ch = apu.channel3
    save_channel_base(ch, w)
    w.write_bytes(ch.wave_ram)
    w.write_u8(ch.wave_ram_position)
    w.write_u8(ch.wave_ram_sample_buffer)
    w.write_u8(ch.length_load)
    w.write_u8(ch.volume_code)
    w.write_u8(ch.volume_code_shift)
    w.write_u16(ch.frequency)
  block:
    let ch = apu.channel4
    save_channel_env(ch, w)
    w.write_u16(ch.lfsr)
    w.write_u8(ch.length_load)
    w.write_u8(ch.clock_shift)
    w.write_u8(ch.width_mode)
    w.write_u8(ch.divisor_code)

proc load_apu_state(apu: GbApu; r: var Reader) =
  r.expect_tag(GB_SEC_APU)
  apu.sound_enabled = r.read_bool()
  apu.frame_sequencer_stage = int(r.read_u8())
  apu.first_half_of_length_period = r.read_bool()
  apu.left_enable = r.read_bool()
  # Masked to the register's 3 bits because they index GB_MASTER_VOLUME. The
  # writer can only ever have stored 0-7; a truncated or hand-edited state
  # must not turn into an out-of-bounds read.
  apu.left_volume = r.read_u8() and 0x07
  apu.right_enable = r.read_bool()
  apu.right_volume = r.read_u8() and 0x07
  apu.nr51 = r.read_u8()
  block:
    let ch = apu.channel1
    load_channel_env(ch, r)
    ch.wave_duty_position = int(r.read_i32())
    ch.sweep_period = r.read_u8()
    ch.negate = r.read_bool()
    ch.shift = r.read_u8()
    ch.sweep_timer = r.read_u8()
    ch.frequency_shadow = r.read_u16()
    ch.sweep_enabled = r.read_bool()
    ch.negate_used = r.read_bool()
    ch.duty = r.read_u8()
    ch.length_load = r.read_u8()
    ch.frequency = r.read_u16()
  block:
    let ch = apu.channel2
    load_channel_env(ch, r)
    ch.wave_duty_position = int(r.read_i32())
    ch.duty = r.read_u8()
    ch.length_load = r.read_u8()
    ch.frequency = r.read_u16()
  block:
    let ch = apu.channel3
    load_channel_base(ch, r)
    r.read_bytes(ch.wave_ram)
    ch.wave_ram_position = r.read_u8()
    ch.wave_ram_sample_buffer = r.read_u8()
    ch.length_load = r.read_u8()
    ch.volume_code = r.read_u8()
    ch.volume_code_shift = r.read_u8()
    ch.frequency = r.read_u16()
  block:
    let ch = apu.channel4
    load_channel_env(ch, r)
    ch.lfsr = r.read_u16()
    ch.length_load = r.read_u8()
    ch.clock_shift = r.read_u8()
    ch.width_mode = r.read_u8()
    ch.divisor_code = r.read_u8()
  # Restart audio pacing cleanly (see GBA load_apu_state)
  apu.buffer_pos = 0
  when not defined(test_harness) and not defined(emscripten):
    if apu.audio_dev != 0:
      sdl_clear_queued_audio_gb(apu.audio_dev)

# ---- Cartridge / MBC ----

proc mbc_kind_tag(cart: Mbc): uint8 =
  if cart of Mbc1: 1'u8
  elif cart of Mbc2: 2'u8
  elif cart of Mbc3: 3'u8
  elif cart of Mbc5: 5'u8
  elif cart of Mbc6: 6'u8
  elif cart of Mbc7: 7'u8
  # The mappers with no MBC number use their cartridge-type bytes instead
  elif cart of Mmm01: 0x0B'u8
  elif cart of PocketCamera: 0xFC'u8
  elif cart of Tama5: 0xFD'u8
  elif cart of Huc1: 0xFF'u8
  elif cart of Huc3: 0xFE'u8
  else: 0'u8

proc save_mbc_state(cart: Mbc; w: var Writer) =
  w.write_tag(GB_SEC_MBC)
  w.write_u8(mbc_kind_tag(cart))
  w.write_seq_u8(cart.ram)
  if cart of Mbc1:
    let c = Mbc1(cart)
    w.write_bool(c.ram_enabled)
    w.write_u8(c.mode)
    w.write_u8(c.reg1)
    w.write_u8(c.reg2)
  elif cart of Mbc2:
    let c = Mbc2(cart)
    w.write_bool(c.ram_enabled)
    w.write_u8(c.rom_bank)
  elif cart of Mbc3:
    let c = Mbc3(cart)
    w.write_bool(c.ram_enabled)
    w.write_u8(c.rom_bank_num)
    w.write_u8(c.ram_bank_num)
    for i in 0 .. 4: w.write_u8(c.rtc_live[i])
    for i in 0 .. 4: w.write_u8(c.rtc_latched[i])
    w.write_u8(c.rtc_latch_prev)
    w.write_int(c.rtc_halt_remaining)
  elif cart of Mbc5:
    let c = Mbc5(cart)
    w.write_bool(c.ram_enabled)
    w.write_u16(c.rom_bank_num)
    w.write_u8(c.ram_bank_num)
  elif cart of Mbc7:
    let c = Mbc7(cart)
    w.write_bool(c.ram_enabled)
    w.write_bool(c.secondary_enable)
    w.write_u8(c.rom_bank_num)
    w.write_u16(c.x_latch)
    w.write_u16(c.y_latch)
    w.write_bool(c.latch_ready)
    # The EEPROM port has to go too: a state taken mid-command would otherwise
    # resume with a half-shifted command and corrupt the save. accel_x/accel_y
    # are live input and are not part of the state (see Mbc5Rumble.rumble).
    w.write_bool(c.eeprom_do)
    w.write_bool(c.eeprom_di)
    w.write_bool(c.eeprom_clk)
    w.write_bool(c.eeprom_cs)
    w.write_u16(c.eeprom_command)
    w.write_u16(c.read_bits)
    w.write_u8(uint8(c.argument_bits_left))
    w.write_bool(c.eeprom_write_enabled)
  elif cart of Mmm01:
    let c = Mmm01(cart)
    # rom_rotate is derived from the ROM file, not from anything the running
    # program did, so it is rebuilt at load and left out here.
    w.write_bool(c.ram_enabled)
    w.write_bool(c.mapped)
    w.write_u8(c.rom_bank_low)
    w.write_u8(c.rom_bank_mid)
    w.write_u8(c.rom_bank_high)
    w.write_u8(c.ram_bank_low)
    w.write_u8(c.ram_bank_high)
    w.write_u8(c.rom_bank_mask)
    w.write_u8(c.ram_bank_mask)
    w.write_bool(c.mbc1_mode)
    w.write_bool(c.mode_locked)
    w.write_bool(c.multiplex)
  elif cart of Mbc6:
    let c = Mbc6(cart)
    w.write_bool(c.ram_enabled)
    w.write_u8(c.ram_bank_a)
    w.write_u8(c.ram_bank_b)
    w.write_u8(c.rom_bank_a)
    w.write_u8(c.rom_bank_b)
    w.write_bool(c.flash_select_a)
    w.write_bool(c.flash_select_b)
    w.write_bool(c.flash_enabled)
    w.write_bool(c.flash_write_enabled)
    # The flash array is half of what the battery keeps — it is the minigames
    # the player downloaded — so a state without it would restore a cartridge
    # that had forgotten them. The command state goes too: a state taken between
    # the unlock writes and the command byte would otherwise resume mid-sequence.
    w.write_seq_u8(c.flash)
    w.write_seq_u8(c.flash_hidden)
    w.write_bool(c.flash_sector0_protected)
    w.write_u8(c.flash_read_mode)
    w.write_u8(c.flash_status)
    w.write_int(c.flash_cmd_step)
    w.write_u8(c.flash_setup)
    w.write_int(c.flash_program_addr)
    w.write_bool(c.flash_program_hidden)
  elif cart of PocketCamera:
    let c = PocketCamera(cart)
    w.write_bool(c.ram_enabled)
    w.write_u8(c.rom_bank_num)
    w.write_u8(c.ram_bank_num)
    w.write_bool(c.regs_mapped)
    # All 54 registers: the 4x4 threshold matrix is as much live configuration
    # as the exposure is. capture_cycles_left carries a paused capture across;
    # a running one is already in the scheduler's own state. `sensor` is live
    # input and is left out, as Mbc7.accel_x is.
    for v in c.regs: w.write_u8(v)
    w.write_int(c.capture_cycles_left)
  elif cart of Tama5:
    let c = Tama5(cart)
    # The nibble register file has to go whole: a command is several writes long
    # and a state taken between them would resume with half of one staged.
    w.write_u8(c.reg_index)
    for v in c.regs: w.write_u8(v)
    for p in 0 .. 3:
      for i in 0 .. 12: w.write_u8(c.rtc_pages[p][i])
    w.write_u8(c.page_reg)
    w.write_u64(uint64(c.last_second))
  elif cart of Huc1:
    let c = Huc1(cart)
    w.write_u8(c.bank_low)
    w.write_u8(c.bank_high)
    w.write_bool(c.ir_mode)
  elif cart of Huc3:
    let c = Huc3(cart)
    w.write_u8(c.rom_bank_num)
    w.write_u8(c.ram_bank_num)
    w.write_u8(c.mode)
    # The microcontroller's register window carries the clock, so it goes in
    # whole. So does the mailbox: issuing a command takes several writes across
    # two window modes, and a state taken between them would resume with a
    # half-built command. cart_ir is live emitter drive and is left out, as
    # Mbc5Rumble.rumble is.
    for v in c.regs: w.write_u8(v)
    w.write_u8(c.access_addr)
    w.write_u8(c.mailbox)
    w.write_u8(c.response)
    w.write_u64(uint64(c.last_second))

proc load_mbc_state(cart: Mbc; r: var Reader) =
  r.expect_tag(GB_SEC_MBC)
  if r.read_u8() != mbc_kind_tag(cart):
    raise newException(StateError, "save state MBC type mismatch")
  let ram = r.read_seq_u8()
  if ram.len != cart.ram.len:
    raise newException(StateError, "save state cart RAM size mismatch")
  cart.ram = ram
  if cart of Mbc1:
    let c = Mbc1(cart)
    c.ram_enabled = r.read_bool()
    c.mode = r.read_u8()
    c.reg1 = r.read_u8()
    c.reg2 = r.read_u8()
  elif cart of Mbc2:
    let c = Mbc2(cart)
    c.ram_enabled = r.read_bool()
    c.rom_bank = r.read_u8()
  elif cart of Mbc3:
    let c = Mbc3(cart)
    c.ram_enabled = r.read_bool()
    c.rom_bank_num = r.read_u8()
    c.ram_bank_num = r.read_u8()
    for i in 0 .. 4: c.rtc_live[i] = r.read_u8()
    for i in 0 .. 4: c.rtc_latched[i] = r.read_u8()
    c.rtc_latch_prev = r.read_u8()
    c.rtc_halt_remaining = r.read_int()
  elif cart of Mbc5:
    let c = Mbc5(cart)
    c.ram_enabled = r.read_bool()
    c.rom_bank_num = r.read_u16()
    c.ram_bank_num = r.read_u8()
  elif cart of Mbc7:
    let c = Mbc7(cart)
    c.ram_enabled = r.read_bool()
    c.secondary_enable = r.read_bool()
    c.rom_bank_num = r.read_u8()
    c.x_latch = r.read_u16()
    c.y_latch = r.read_u16()
    c.latch_ready = r.read_bool()
    c.eeprom_do = r.read_bool()
    c.eeprom_di = r.read_bool()
    c.eeprom_clk = r.read_bool()
    c.eeprom_cs = r.read_bool()
    c.eeprom_command = r.read_u16()
    c.read_bits = r.read_u16()
    c.argument_bits_left = int(r.read_u8())
    c.eeprom_write_enabled = r.read_bool()
  elif cart of Mmm01:
    let c = Mmm01(cart)
    c.ram_enabled   = r.read_bool()
    c.mapped        = r.read_bool()
    c.rom_bank_low  = r.read_u8()
    c.rom_bank_mid  = r.read_u8()
    c.rom_bank_high = r.read_u8()
    c.ram_bank_low  = r.read_u8()
    c.ram_bank_high = r.read_u8()
    c.rom_bank_mask = r.read_u8()
    c.ram_bank_mask = r.read_u8()
    c.mbc1_mode     = r.read_bool()
    c.mode_locked   = r.read_bool()
    c.multiplex     = r.read_bool()
  elif cart of Mbc6:
    let c = Mbc6(cart)
    c.ram_enabled = r.read_bool()
    c.ram_bank_a  = r.read_u8()
    c.ram_bank_b  = r.read_u8()
    c.rom_bank_a  = r.read_u8()
    c.rom_bank_b  = r.read_u8()
    c.flash_select_a = r.read_bool()
    c.flash_select_b = r.read_bool()
    c.flash_enabled  = r.read_bool()
    c.flash_write_enabled = r.read_bool()
    let fl = r.read_seq_u8()
    if fl.len != c.flash.len:
      raise newException(StateError, "save state MBC6 flash size mismatch")
    c.flash = fl
    let hid = r.read_seq_u8()
    if hid.len != c.flash_hidden.len:
      raise newException(StateError, "save state MBC6 hidden region size mismatch")
    c.flash_hidden = hid
    c.flash_sector0_protected = r.read_bool()
    c.flash_read_mode      = r.read_u8()
    c.flash_status         = r.read_u8()
    c.flash_cmd_step       = r.read_int()
    c.flash_setup          = r.read_u8()
    c.flash_program_addr   = r.read_int()
    c.flash_program_hidden = r.read_bool()
  elif cart of PocketCamera:
    let c = PocketCamera(cart)
    c.ram_enabled  = r.read_bool()
    c.rom_bank_num = r.read_u8()
    c.ram_bank_num = r.read_u8()
    c.regs_mapped  = r.read_bool()
    for i in 0 ..< c.regs.len: c.regs[i] = r.read_u8()
    c.capture_cycles_left = r.read_int()
  elif cart of Tama5:
    let c = Tama5(cart)
    c.reg_index = r.read_u8()
    for i in 0 ..< c.regs.len: c.regs[i] = r.read_u8()
    for p in 0 .. 3:
      for i in 0 .. 12: c.rtc_pages[p][i] = r.read_u8()
    c.page_reg    = r.read_u8()
    c.last_second = int64(r.read_u64())
  elif cart of Huc1:
    let c = Huc1(cart)
    c.bank_low = r.read_u8()
    c.bank_high = r.read_u8()
    c.ir_mode = r.read_bool()
  elif cart of Huc3:
    let c = Huc3(cart)
    c.rom_bank_num = r.read_u8()
    c.ram_bank_num = r.read_u8()
    c.mode = r.read_u8()
    for i in 0 ..< c.regs.len: c.regs[i] = r.read_u8()
    c.access_addr = r.read_u8()
    c.mailbox = r.read_u8()
    c.response = r.read_u8()
    c.last_second = int64(r.read_u64())
  # Resync point 3 of 3: the banking registers above were written directly,
  # not through mbc_write, so the flat-ROM cache is stale until now. Missing
  # this would leave a loaded state (and every rollback restore) reading the
  # pre-load ROM bank.
  mbc_sync_rom_map(cart)
  # Persist the restored cart RAM to the .sav on the next flush
  if cart.has_battery and cart.ram.len > 0:
    cart.ram_dirty = true

# ---- Top level ----

# ---- APU waveform deadlines <-> scheduler events ----
#
# The channels' next_step deadlines replaced one etAPUChannel<N> scheduler event
# per armed channel (see gb/apu.nim). Rather than append four new fields to a
# positional, unversioned state format, round-trip them through the events they
# replaced: the payload stays byte-identical to the pre-catch-up format, so a
# state written here still loads in an older build and vice versa -- which also
# keeps rollback/netplay snapshots interchangeable across the change.

proc apu_arm_state_events(gb: GB) =
  # Deadlines are in scheduler cycles, which is exactly what schedule() takes;
  # the catch-up guarantees each one is in the future so the delay is positive.
  gb.apu.apu_catchup_all(gb)
  template arm(ch: untyped; et: EventType) =
    if ch.next_step != GB_NO_STEP:
      gb.scheduler.schedule(int(ch.next_step - gb.scheduler.cycles), et)
  arm(gb.apu.channel1, etAPUChannel1)
  arm(gb.apu.channel2, etAPUChannel2)
  arm(gb.apu.channel3, etAPUChannel3)
  arm(gb.apu.channel4, etAPUChannel4)

proc apu_disarm_state_events(gb: GB) =
  gb.scheduler.clear(etAPUChannel1)
  gb.scheduler.clear(etAPUChannel2)
  gb.scheduler.clear(etAPUChannel3)
  gb.scheduler.clear(etAPUChannel4)

proc apu_extract_state_events(gb: GB) =
  # `et` rather than `kind`: a template parameter named `kind` would be
  # substituted into `ev.kind` too and turn it into a bogus field access.
  template take(ch: untyped; et: EventType) =
    ch.next_step = GB_NO_STEP
    for ev in gb.scheduler.events:
      if ev.kind == et: ch.next_step = ev.cycles
    gb.scheduler.clear(et)
  take(gb.apu.channel1, etAPUChannel1)
  take(gb.apu.channel2, etAPUChannel2)
  take(gb.apu.channel3, etAPUChannel3)
  take(gb.apu.channel4, etAPUChannel4)

proc gb_state_payload(gb: GB): string =
  var w = Writer()
  save_cpu_state(gb.cpu, w)
  save_irq_state(gb.interrupts, w)
  save_timer_state(gb.timer, w)
  save_serial_state(gb.serial, w)
  save_joypad_state(gb.joypad, w)
  save_mem_state(gb.memory, w)
  w.write_bool(gb.cgb_enabled)
  w.write_tag(GB_SEC_SCHED)
  gb.apu_arm_state_events()
  gb.scheduler.save_to(w)
  gb.apu_disarm_state_events()
  save_ppu_state(gb.ppu, w)
  save_apu_state(gb.apu, w)
  save_mbc_state(gb.cartridge, w)
  w.write_tag(GB_SEC_END)
  w.buf

proc gb_apply_state(gb: GB; payload: string; rev: uint32) =
  var r = Reader(buf: payload)
  load_cpu_state(gb.cpu, r, rev)
  load_irq_state(gb.interrupts, r)
  load_timer_state(gb.timer, r)
  load_serial_state(gb.serial, r, rev)
  load_joypad_state(gb.joypad, r)
  load_mem_state(gb.memory, r)
  gb.cgb_enabled = r.read_bool()
  r.expect_tag(GB_SEC_SCHED)
  gb.scheduler.load_from(r)
  load_ppu_state(gb.ppu, r, rev)
  load_apu_state(gb.apu, r)
  gb.apu_extract_state_events()
  load_mbc_state(gb.cartridge, r)
  r.expect_tag(GB_SEC_END)
  # Derived OAM-DMA bus state. Neither field is serialized: both are functions
  # of state that already is (current_dma_source, dma_position, and the source
  # memory), so re-deriving them here keeps the payload byte-for-byte what it
  # was before bus conflicts existed. Must run after the MBC/PPU sections, or
  # the latch would be read out of a half-restored cartridge.
  let mem = gb.memory
  if mem.dma_busy:
    var src = int(mem.current_dma_source)
    if src >= 0xE000: src = src and not 0x2000
    if int(mem.current_dma_source) >= 0xE000 and console_is_cgb(gb):
      mem.dma_bus = uint8(dbExternal)
      mem.dma_drive = DriveTristate
      mem.dma_openbus = true
      mem.dma_latch = 0xFF'u8
    else:
      mem.dma_bus = dma_bus_of(gb, src)
      mem.dma_drive = dma_drive_of(gb, src)
      mem.dma_openbus = false
      var latch_src = int(mem.current_dma_source) + mem.dma_position - 1
      if latch_src >= 0xE000: latch_src = latch_src and not 0x2000
      mem.dma_latch = read_byte(mem, gb, latch_src)
  else:
    mem.dma_bus = uint8(dbNone)
    mem.dma_drive = DriveTristate
    mem.dma_openbus = false
    mem.dma_latch = 0

proc gb_rom_checksum(gb: GB): uint32 =
  ## The whole ROM file. load_cartridge allocates the buffer at exactly the
  ## file's length — no padding, no mirroring — so unlike the GBA (see
  ## gba_rom_checksum) this identity has never depended on an allocation rule
  ## and has no legacy variants to accept. Keep it that way: if a GB mapper
  ## ever needs a padded buffer, hash the file length explicitly.
  ## From the cache taken at load (Mbc.rom_identity), not the live buffer --
  ## cheats patch that in place. See the GBA side.
  gb.cartridge.rom_identity

proc state_payload*(gb: GB): string =
  ## Raw serialized state, no header/validation. For trusted in-process uses
  ## (the rewind ring buffer). Frame boundaries only.
  gb.gb_state_payload()

proc apply_state_payload*(gb: GB; payload: string) =
  ## Apply a raw payload produced by state_payload. Raises StateError on
  ## corrupt input; no rollback — trusted callers only. Always this build's
  ## revision: the rewind ring and rollback snapshots never outlive the process.
  gb.gb_apply_state(payload, GB_PAYLOAD_VERSION)

proc apply_state_payload*(gb: GB; payload: string; rev: uint32) =
  ## As above, for a payload known to be in an OLDER revision. Exists so the
  ## format tests can exercise a migration without a whole state image; normal
  ## load paths get their revision from the header.
  gb.gb_apply_state(payload, rev)

const GB_THUMB_W = 120
const GB_THUMB_H = GB_THUMB_W * 144 div 160   # preserve 10:9 → 120x108

proc gb_thumbnail(gb: GB): seq[byte] =
  downscale_bgr555(gb.ppu.framebuffer, 160, 144, GB_THUMB_W, GB_THUMB_H)

proc state_bytes*(gb: GB; thumbnail = false): string =
  ## Full validated state image (header + payload) for in-memory transports
  ## (web IndexedDB / downloads). Same format as .state files. With thumbnail,
  ## a downscaled BGR555 screenshot trailer is appended (ignored by old readers).
  let payload = gb.gb_state_payload()
  if thumbnail:
    make_state_bytes(ckGB, gb.gb_rom_checksum(), uint32(gb.cartridge.rom.len),
                     payload, gb.gb_thumbnail(), uint16(GB_THUMB_W), uint16(GB_THUMB_H))
  else:
    make_state_bytes(ckGB, gb.gb_rom_checksum(),
                     uint32(gb.cartridge.rom.len), payload)

proc parse_state_image*(gb: GB; data: string; origin = "state data"):
                       tuple[payload: string; rev: uint32] =
  ## Header validation for a full state image against THIS cart — the mirror
  ## of the GBA proc of the same name, so the format test can ask both cores
  ## the same question instead of assembling a ROM identity itself.
  parse_state_payload(data, ckGB, gb.gb_rom_checksum(),
                      uint32(gb.cartridge.rom.len), origin)

proc load_state_bytes*(gb: GB; data: string): bool =
  ## Validate and apply a full state image. Mirrors load_state's rollback.
  var image: tuple[payload: string; rev: uint32]
  try:
    image = gb.parse_state_image(data)
  except CatchableError:
    last_state_error = getCurrentExceptionMsg()
    echo "Load state failed: ", last_state_error
    return false
  let backup = gb.gb_state_payload()
  try:
    gb.gb_apply_state(image.payload, image.rev)
    true
  except CatchableError:
    last_state_error = getCurrentExceptionMsg()
    echo "Load state failed: ", last_state_error
    gb.gb_apply_state(backup, GB_PAYLOAD_VERSION)
    false

proc save_state*(gb: GB; path: string; thumbnail = false): bool =
  ## Serialize the full emulator state to path. Must only be called at a
  ## frame boundary (right after step_frame returns). Returns false and
  ## echoes a message on failure.
  try:
    if thumbnail:
      write_state_file(path, ckGB, gb.gb_rom_checksum(), uint32(gb.cartridge.rom.len),
                       gb.gb_state_payload(), gb.gb_thumbnail(),
                       uint16(GB_THUMB_W), uint16(GB_THUMB_H))
    else:
      write_state_file(path, ckGB, gb.gb_rom_checksum(),
                       uint32(gb.cartridge.rom.len), gb.gb_state_payload())
    true
  except CatchableError:
    echo "Save state failed: ", getCurrentExceptionMsg()
    false

proc load_state*(gb: GB; path: string): bool =
  ## Restore emulator state from path. Must only be called at a frame
  ## boundary. On any validation error the emulator is left untouched; if
  ## applying fails midway the pre-load state is restored.
  var image: tuple[payload: string; rev: uint32]
  try:
    image = read_state_payload(path, ckGB, gb.gb_rom_checksum(),
                               uint32(gb.cartridge.rom.len))
  except CatchableError:
    last_state_error = getCurrentExceptionMsg()
    echo "Load state failed: ", last_state_error
    return false
  let backup = gb.gb_state_payload()
  try:
    gb.gb_apply_state(image.payload, image.rev)
    true
  except CatchableError:
    last_state_error = getCurrentExceptionMsg()
    echo "Load state failed: ", last_state_error
    gb.gb_apply_state(backup, GB_PAYLOAD_VERSION)
    false
