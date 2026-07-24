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

proc visit_cpu[S](cpu: GbCpu; s: var S) =
  s.visit_tag GB_SEC_CPU
  s.visit_u16 cpu.af
  s.visit_u16 cpu.bc
  s.visit_u16 cpu.de
  s.visit_u16 cpu.hl
  s.visit_u16 cpu.pc
  s.visit_u16 cpu.sp
  s.visit_bool cpu.ime
  s.visit_bool cpu.halted
  s.visit_bool cpu.halt_bug
  when S is Reader:
    cpu.cached_hl = -1  # per-instruction scratch

# ---- Interrupts / Timer / Joypad ----

proc visit_irq[S](irq: GbInterrupts; s: var S) =
  # IF/IE are spread across individual bool fields, so they round-trip through
  # the same MMIO accessors the CPU uses rather than as plain fields.
  s.visit_tag GB_SEC_IRQ
  when S is Reader:
    irq_write(irq, 0xFF0F, s.read_u8())
    irq_write(irq, 0xFFFF, s.read_u8())
  else:
    s.write_u8(irq_read(irq, 0xFF0F))
    s.write_u8(irq_read(irq, 0xFFFF))

proc visit_timer[S](t: GbTimer; s: var S) =
  s.visit_tag GB_SEC_TIMER
  s.visit_u16  t.tdiv
  s.visit_u8   t.tima
  s.visit_u8   t.tma
  s.visit_bool t.enabled
  s.visit_u8   t.clock_select
  s.visit_i32  t.bit_for_tima
  s.visit_bool t.previous_bit
  s.visit_i32  t.countdown

proc visit_serial[S](ser: GbSerial; s: var S) =
  # The driver (link cable binding) is not serialized; see set_serial_driver
  s.visit_tag GB_SEC_SER
  s.visit_u8   ser.sb
  s.visit_u8   ser.sc
  s.visit_u8   ser.out_latch
  s.visit_u8   ser.bits_remaining
  s.visit_u8   ser.clock_history
  s.visit_bool ser.shifting

proc visit_joypad[S](j: GbJoypad; s: var S) =
  # Only the select lines (written by the game); pressed-key state stays
  # live since it reflects currently held host keys
  s.visit_tag GB_SEC_JOY
  s.visit_bool j.button_keys
  s.visit_bool j.direction_keys

# ---- Memory ----

proc visit_mem[S](mem: GbMemory; s: var S) =
  s.visit_tag GB_SEC_MEM
  for i in 0 ..< 8: s.visit_bytes mem.wram[i]
  s.visit_u8    mem.wram_bank
  s.visit_bytes mem.hram
  # Length-prefixed and resized on load, so it can't use visit_bytes
  when S is Reader: mem.bootrom = s.read_seq_u8()
  else:             s.write_seq_u8(mem.bootrom)
  s.visit_u8   mem.ff72
  s.visit_u8   mem.ff73
  s.visit_u8   mem.ff74
  s.visit_u8   mem.ff75
  s.visit_u8   mem.dma
  s.visit_u16  mem.current_dma_source
  s.visit_i32  mem.internal_dma_timer
  s.visit_i32  mem.dma_position
  s.visit_bool mem.requested_oam_dma
  s.visit_u8   mem.next_dma_counter
  s.visit_bool mem.requested_speed_switch
  s.visit_u8   mem.current_speed
  when S is Reader:
    mem.cycle_tick_count = 0  # per-instruction scratch, zero between frames

# ---- PPU (renderer-agnostic base state only, see file comment) ----

proc visit_ppu[S](ppu: GbPpu; s: var S) =
  s.visit_tag GB_SEC_PPU
  s.visit_u8    ppu.lcd_control
  s.visit_u8    ppu.lcd_status
  s.visit_u8    ppu.scy
  s.visit_u8    ppu.scx
  s.visit_u8    ppu.ly
  s.visit_u8    ppu.lyc
  s.visit_bytes ppu.bgp
  s.visit_bytes ppu.obp0
  s.visit_bytes ppu.obp1
  s.visit_u8    ppu.wy
  s.visit_u8    ppu.wx
  s.visit_u8    ppu.vram_bank
  s.visit_bytes ppu.pram
  s.visit_u8    ppu.palette_index
  s.visit_bool  ppu.auto_increment
  s.visit_bytes ppu.obj_pram
  s.visit_u8    ppu.obj_palette_index
  s.visit_bool  ppu.obj_auto_increment
  s.visit_bytes ppu.vram[0]
  s.visit_bytes ppu.vram[1]
  s.visit_bytes ppu.oam
  s.visit_u8    ppu.hdma1
  s.visit_u8    ppu.hdma2
  s.visit_u8    ppu.hdma3
  s.visit_u8    ppu.hdma4
  s.visit_u8    ppu.hdma5
  s.visit_u16   ppu.hdma_src
  s.visit_u16   ppu.hdma_dst
  s.visit_u16   ppu.hdma_pos
  s.visit_bool  ppu.hdma_active
  s.visit_bool  ppu.window_trigger
  s.visit_i32   ppu.current_window_line
  s.visit_bool  ppu.old_stat_flag
  s.visit_bool  ppu.first_line
  s.visit_i32   ppu.cycle_counter
  s.visit_bool  ppu.ran_bios
  s.visit_seq_u16 ppu.framebuffer
  when S is Reader:
    ppu.frame = false
    # Renderer scratch isn't serialized; clear it so a load onto a running
    # core (rollback) can't inherit stale per-line fetch state.
    ppu.reset_render_scratch()

# ---- APU ----

proc visit_channel_base[S](ch: GbSoundChannel; s: var S) =
  s.visit_bool ch.enabled
  s.visit_bool ch.dac_enabled
  s.visit_i32  ch.length_counter
  s.visit_bool ch.length_enable

proc visit_channel_env[S](ch: GbVolumeEnvChannel; s: var S) =
  visit_channel_base(ch, s)
  s.visit_u8   ch.starting_volume
  s.visit_bool ch.envelope_add_mode
  s.visit_u8   ch.envelope_period
  s.visit_u8   ch.envelope_timer
  s.visit_u8   ch.current_volume
  s.visit_bool ch.envelope_is_updating

proc visit_apu[S](apu: GbApu; s: var S) =
  s.visit_tag GB_SEC_APU
  s.visit_bool apu.sound_enabled
  s.visit_u8   apu.frame_sequencer_stage
  s.visit_bool apu.first_half_of_length_period
  s.visit_bool apu.left_enable
  s.visit_u8   apu.left_volume
  s.visit_bool apu.right_enable
  s.visit_u8   apu.right_volume
  s.visit_u8   apu.nr51
  block:
    let ch = apu.channel1
    visit_channel_env(ch, s)
    s.visit_i32  ch.wave_duty_position
    s.visit_u8   ch.sweep_period
    s.visit_bool ch.negate
    s.visit_u8   ch.shift
    s.visit_u8   ch.sweep_timer
    s.visit_u16  ch.frequency_shadow
    s.visit_bool ch.sweep_enabled
    s.visit_bool ch.negate_used
    s.visit_u8   ch.duty
    s.visit_u8   ch.length_load
    s.visit_u16  ch.frequency
  block:
    let ch = apu.channel2
    visit_channel_env(ch, s)
    s.visit_i32 ch.wave_duty_position
    s.visit_u8  ch.duty
    s.visit_u8  ch.length_load
    s.visit_u16 ch.frequency
  block:
    let ch = apu.channel3
    visit_channel_base(ch, s)
    s.visit_bytes ch.wave_ram
    s.visit_u8    ch.wave_ram_position
    s.visit_u8    ch.wave_ram_sample_buffer
    s.visit_u8    ch.length_load
    s.visit_u8    ch.volume_code
    s.visit_u8    ch.volume_code_shift
    s.visit_u16   ch.frequency
  block:
    let ch = apu.channel4
    visit_channel_env(ch, s)
    s.visit_u16 ch.lfsr
    s.visit_u8  ch.length_load
    s.visit_u8  ch.clock_shift
    s.visit_u8  ch.width_mode
    s.visit_u8  ch.divisor_code
  when S is Reader:
    # Restart audio pacing cleanly (see the GBA visit_apu)
    apu.buffer_pos = 0
    when not defined(test_harness) and not defined(emscripten):
      if apu.audio_dev != 0:
        sdl_clear_queued_audio(apu.audio_dev)

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
  visit_cpu(gb.cpu, w)
  visit_irq(gb.interrupts, w)
  visit_timer(gb.timer, w)
  visit_serial(gb.serial, w)
  visit_joypad(gb.joypad, w)
  visit_mem(gb.memory, w)
  w.write_bool(gb.cgb_enabled)
  w.write_tag(GB_SEC_SCHED)
  gb.scheduler.save_to(w)
  visit_ppu(gb.ppu, w)
  visit_apu(gb.apu, w)
  save_mbc_state(gb.cartridge, w)   # asymmetric: see the section comment
  w.write_tag(GB_SEC_END)
  w.buf

proc gb_apply_state(gb: GB; payload: string) =
  var r = Reader(buf: payload)
  visit_cpu(gb.cpu, r)
  visit_irq(gb.interrupts, r)
  visit_timer(gb.timer, r)
  visit_serial(gb.serial, r)
  visit_joypad(gb.joypad, r)
  visit_mem(gb.memory, r)
  gb.cgb_enabled = r.read_bool()
  r.expect_tag(GB_SEC_SCHED)
  gb.scheduler.load_from(r)
  visit_ppu(gb.ppu, r)
  visit_apu(gb.apu, r)
  load_mbc_state(gb.cartridge, r)   # asymmetric: see the section comment
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
