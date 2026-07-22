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

proc load_cpu_state(cpu: GbCpu; r: var Reader) =
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

proc load_serial_state(s: GbSerial; r: var Reader) =
  r.expect_tag(GB_SEC_SER)
  s.sb = r.read_u8()
  s.sc = r.read_u8()
  s.out_latch = r.read_u8()
  s.bits_remaining = int(r.read_u8())
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
  w.write_bool(ppu.window_trigger)
  w.write_i32(int32(ppu.current_window_line))
  w.write_bool(ppu.old_stat_flag)
  w.write_bool(ppu.first_line)
  w.write_i32(ppu.cycle_counter)
  w.write_bool(ppu.ran_bios)
  w.write_seq_u16(ppu.framebuffer)

proc load_ppu_state(ppu: GbPpu; r: var Reader) =
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
  apu.left_volume = r.read_u8()
  apu.right_enable = r.read_bool()
  apu.right_volume = r.read_u8()
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
  # Persist the restored cart RAM to the .sav on the next flush
  if cart.has_battery and cart.ram.len > 0:
    cart.ram_dirty = true

# ---- Top level ----

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
  gb.scheduler.save_to(w)
  save_ppu_state(gb.ppu, w)
  save_apu_state(gb.apu, w)
  save_mbc_state(gb.cartridge, w)
  w.write_tag(GB_SEC_END)
  w.buf

proc gb_apply_state(gb: GB; payload: string) =
  var r = Reader(buf: payload)
  load_cpu_state(gb.cpu, r)
  load_irq_state(gb.interrupts, r)
  load_timer_state(gb.timer, r)
  load_serial_state(gb.serial, r)
  load_joypad_state(gb.joypad, r)
  load_mem_state(gb.memory, r)
  gb.cgb_enabled = r.read_bool()
  r.expect_tag(GB_SEC_SCHED)
  gb.scheduler.load_from(r)
  load_ppu_state(gb.ppu, r)
  load_apu_state(gb.apu, r)
  load_mbc_state(gb.cartridge, r)
  r.expect_tag(GB_SEC_END)

proc gb_rom_checksum(gb: GB): uint32 =
  fnv1a(gb.cartridge.rom)

proc state_payload*(gb: GB): string =
  ## Raw serialized state, no header/validation. For trusted in-process uses
  ## (the rewind ring buffer). Frame boundaries only.
  gb.gb_state_payload()

proc apply_state_payload*(gb: GB; payload: string) =
  ## Apply a raw payload produced by state_payload. Raises StateError on
  ## corrupt input; no rollback — trusted callers only.
  gb.gb_apply_state(payload)

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

proc load_state_bytes*(gb: GB; data: string): bool =
  ## Validate and apply a full state image. Mirrors load_state's rollback.
  var payload: string
  try:
    payload = parse_state_payload(data, ckGB, gb.gb_rom_checksum(),
                                  uint32(gb.cartridge.rom.len))
  except CatchableError:
    echo "Load state failed: ", getCurrentExceptionMsg()
    return false
  let backup = gb.gb_state_payload()
  try:
    gb.gb_apply_state(payload)
    true
  except CatchableError:
    echo "Load state failed: ", getCurrentExceptionMsg()
    gb.gb_apply_state(backup)
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
  var payload: string
  try:
    payload = read_state_payload(path, ckGB, gb.gb_rom_checksum(),
                                 uint32(gb.cartridge.rom.len))
  except CatchableError:
    echo "Load state failed: ", getCurrentExceptionMsg()
    return false
  let backup = gb.gb_state_payload()
  try:
    gb.gb_apply_state(payload)
    true
  except CatchableError:
    echo "Load state failed: ", getCurrentExceptionMsg()
    gb.gb_apply_state(backup)
    false
