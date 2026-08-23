# GBA save-state serialization (included by gba.nim).
#
# States are written at frame boundaries only, so no mid-instruction CPU
# state exists. Deterministic caches (waitloop sets, the fetch-page fast
# path) are rebuilt, not serialized. The ROM is not stored; the header
# carries its identity.

const
  GBA_SEC_CPU     = 0xC1'u8
  GBA_SEC_BUS     = 0xC2'u8
  GBA_SEC_SCHED   = 0xC3'u8
  GBA_SEC_IRQ     = 0xC4'u8
  GBA_SEC_MMIO    = 0xC5'u8
  GBA_SEC_KEYPAD  = 0xC6'u8
  GBA_SEC_TIMER   = 0xC7'u8
  GBA_SEC_SERIAL  = 0xC8'u8
  GBA_SEC_DMA     = 0xC9'u8
  GBA_SEC_GPIO    = 0xCA'u8
  GBA_SEC_PPU     = 0xCB'u8
  GBA_SEC_APU     = 0xCC'u8
  GBA_SEC_STORAGE = 0xCD'u8
  GBA_SEC_END     = 0xCF'u8

# ---- CPU ----

proc save_cpu_state(cpu: CPU; w: var Writer) =
  w.write_tag(GBA_SEC_CPU)
  for i in 0 .. 15: w.write_u32(cpu.r[i])
  w.write_u32(cast[uint32](cpu.cpsr))
  w.write_u32(cast[uint32](cpu.spsr))
  for bank in 0 .. 5:
    for reg in 0 .. 6: w.write_u32(cpu.reg_banks[bank][reg])
  for bank in 0 .. 5: w.write_u32(cpu.spsr_banks[bank])
  w.write_u32(cpu.pipeline.buffer[0])
  w.write_u32(cpu.pipeline.buffer[1])
  w.write_u8(uint8(cpu.pipeline.pos))
  w.write_u8(uint8(cpu.pipeline.size))
  w.write_bool(cpu.halted)
  w.write_bool(cpu.stopped)
  w.write_bool(cpu.intr_wait_active)
  w.write_u16(cpu.intr_wait_mask)
  w.write_u32(cpu.intr_wait_resume_addr)
  w.write_bool(cpu.halt_wake)
  w.write_u32(cast[uint32](cpu.halt_resume_charge))
  w.write_u32(cpu.halt_resume_addr)
  w.write_bool(cpu.halt_resume_pop)  # v5

proc load_cpu_state(cpu: CPU; r: var Reader; rev: uint32) =
  r.expect_tag(GBA_SEC_CPU)
  for i in 0 .. 15: cpu.r[i] = r.read_u32()
  cpu.cpsr = cast[PSR](r.read_u32())
  cpu.spsr = cast[PSR](r.read_u32())
  for bank in 0 .. 5:
    for reg in 0 .. 6: cpu.reg_banks[bank][reg] = r.read_u32()
  for bank in 0 .. 5: cpu.spsr_banks[bank] = r.read_u32()
  cpu.pipeline.buffer[0] = r.read_u32()
  cpu.pipeline.buffer[1] = r.read_u32()
  cpu.pipeline.pos  = int(r.read_u8())
  cpu.pipeline.size = int(r.read_u8())
  cpu.halted  = r.read_bool()
  cpu.stopped = r.read_bool()
  cpu.intr_wait_active      = r.read_bool()
  cpu.intr_wait_mask        = r.read_u16()
  cpu.intr_wait_resume_addr = r.read_u32()
  if rev >= 2:
    cpu.halt_wake          = r.read_bool()
    cpu.halt_resume_charge = cast[int32](r.read_u32())
    cpu.halt_resume_addr   = r.read_u32()
  else:
    # rev 1 charged the post-wake return path up front, so nothing is
    # deferred; halt_wake is a transient consumed at the next instruction.
    cpu.halt_wake = false
    cpu.halt_resume_charge = 0
    cpu.halt_resume_addr = 0
  if rev >= 4:
    cpu.halt_resume_pop = r.read_bool()
  else:
    # rev <= 3 Halt/Stop never lowered the System sp, so there is nothing to
    # pop. IntrWait's resume pops unconditionally; gba_apply_state retrofits
    # its frame (migrate_intr_wait_frame) where that is safe.
    cpu.halt_resume_pop = false
  cpu.entered_waitloop = false

# ---- Bus ----

proc save_bus_state(bus: Bus; w: var Writer) =
  w.write_tag(GBA_SEC_BUS)
  w.write_i32(int32(bus.cycles))
  w.write_u32(bus.bios_latch)
  w.write_bytes(bus.wram_board)
  w.write_bytes(bus.wram_chip)
  # ROM burst / prefetch trackers persist across frame boundaries; omitting
  # them mistimes the first ROM access by a few cycles, which breaks
  # bit-exact rollback replay.
  w.write_u32(bus.rom_next_addr)
  w.write_u32(bus.rom_next_addr2)
  w.write_u64(uint64(bus.rom_free_since))
  w.write_bool(bus.rom_hot)
  w.write_bool(bus.dma_active)

proc load_bus_state(bus: Bus; r: var Reader; rev: uint32) =
  r.expect_tag(GBA_SEC_BUS)
  # `bus.now` converts this to unsigned, so a negative value is a defect and
  # a huge one overflows. The web build can serialize mid-instruction, so
  # allow one scanline's worth.
  bus.cycles = int(r.read_i32())
  check_range(bus.cycles, 0, 1_232, "bus.cycles")
  bus.bios_latch = r.read_u32()
  r.read_bytes(bus.wram_board)
  r.read_bytes(bus.wram_chip)
  if rev >= 3:
    bus.rom_next_addr = r.read_u32()
    bus.rom_next_addr2 = r.read_u32()
    bus.rom_free_since = CycleCount(r.read_u64())
    bus.rom_hot = r.read_bool()
    bus.dma_active = r.read_bool()
  else:
    # Start the trackers cold: rom_next_addr = 1 is the "no prior access"
    # sentinel (never matches a halfword-aligned address).
    bus.rom_next_addr = 1
    bus.rom_next_addr2 = 1
    bus.rom_free_since = 0
    bus.rom_hot = false
    bus.dma_active = false
  bus.fetch_page = 0xFFFFFFFF'u32  # invalidate the fetch fast path

# ---- Interrupts / MMIO / Keypad ----

proc save_irq_state(intr: Interrupts; w: var Writer) =
  w.write_tag(GBA_SEC_IRQ)
  w.write_u16(cast[uint16](intr.reg_ie))
  w.write_u16(cast[uint16](intr.reg_if))
  w.write_bool(intr.ime)

proc load_irq_state(intr: Interrupts; r: var Reader) =
  r.expect_tag(GBA_SEC_IRQ)
  intr.reg_ie = cast[InterruptReg](r.read_u16())
  intr.reg_if = cast[InterruptReg](r.read_u16())
  intr.ime = r.read_bool()

proc save_mmio_state(mmio: MMIO; w: var Writer) =
  w.write_tag(GBA_SEC_MMIO)
  w.write_u16(cast[uint16](mmio.waitcnt))

proc load_mmio_state(mmio: MMIO; r: var Reader) =
  r.expect_tag(GBA_SEC_MMIO)
  mmio.waitcnt = cast[WAITCNT](r.read_u16())

proc save_keypad_state(kp: Keypad; w: var Writer) =
  # keyinput stays live: it reflects currently held host keys
  w.write_tag(GBA_SEC_KEYPAD)
  w.write_u16(cast[uint16](kp.keycnt))
  w.write_bool(kp.prev_irq_condition)

proc load_keypad_state(kp: Keypad; r: var Reader) =
  r.expect_tag(GBA_SEC_KEYPAD)
  kp.keycnt = cast[KEYCNT](r.read_u16())
  kp.prev_irq_condition = r.read_bool()

# ---- Timer / Serial / DMA ----

proc save_timer_state(tim: Timer; w: var Writer) =
  w.write_tag(GBA_SEC_TIMER)
  for i in 0 .. 3:
    w.write_u16(cast[uint16](tim.tmcnt[i]))
    w.write_u16(tim.tmd[i])
    w.write_u16(tim.tm[i])
    w.write_u64(uint64(tim.cycle_enabled[i]))

proc load_timer_state(tim: Timer; r: var Reader) =
  r.expect_tag(GBA_SEC_TIMER)
  for i in 0 .. 3:
    tim.tmcnt[i] = cast[TMCNT](r.read_u16())
    tim.tmd[i] = r.read_u16()
    tim.tm[i] = r.read_u16()
    tim.cycle_enabled[i] = CycleCount(r.read_u64())

proc save_serial_state(serial: Serial; w: var Writer) =
  w.write_tag(GBA_SEC_SERIAL)
  w.write_u16(serial.siocnt)
  w.write_u16(serial.rcnt)
  w.write_u16(serial.siodata8)
  w.write_u32(serial.siodata32)
  w.write_u16(serial.siomulti2)
  w.write_u16(serial.siomulti3)
  w.write_u16(serial.joycnt)
  w.write_u32(serial.joy_recv)
  w.write_u32(serial.joy_trans)
  w.write_u16(serial.joystat)

proc load_serial_state(serial: Serial; r: var Reader) =
  r.expect_tag(GBA_SEC_SERIAL)
  serial.siocnt    = r.read_u16()
  serial.rcnt      = r.read_u16()
  serial.siodata8  = r.read_u16()
  serial.siodata32 = r.read_u32()
  serial.siomulti2 = r.read_u16()
  serial.siomulti3 = r.read_u16()
  serial.joycnt    = r.read_u16()
  serial.joy_recv  = r.read_u32()
  serial.joy_trans = r.read_u32()
  serial.joystat   = r.read_u16()

proc save_dma_state(dma: DMA; w: var Writer) =
  w.write_tag(GBA_SEC_DMA)
  for i in 0 .. 3:
    w.write_u32(dma.dmasad[i])
    w.write_u32(dma.dmadad[i])
    w.write_u32(dma.src[i])
    w.write_u32(dma.dst[i])
    w.write_u16(dma.dmacnt_l[i])
    w.write_u16(cast[uint16](dma.dmacnt_h[i]))
    w.write_u32(dma.latch[i])
    w.write_u16(dma.count[i])  # v5

proc load_dma_state(dma: DMA; r: var Reader; rev: uint32) =
  r.expect_tag(GBA_SEC_DMA)
  for i in 0 .. 3:
    dma.dmasad[i] = r.read_u32()
    dma.dmadad[i] = r.read_u32()
    dma.src[i] = r.read_u32()
    dma.dst[i] = r.read_u32()
    dma.dmacnt_l[i] = r.read_u16()
    dma.dmacnt_h[i] = cast[DMACNT](r.read_u16())
    dma.latch[i] = r.read_u32()
    # Pre-v5 states have no latched count; the user register is what those
    # builds ran on.
    dma.count[i] = if rev >= 5: r.read_u16() else: dma.dmacnt_l[i]
  # Arbitration state is idle at frame boundaries; not serialized
  dma.pending = 0
  dma.current_priority = 4

# ---- GPIO + RTC ----

proc save_gpio_state(gpio: GPIO; w: var Writer) =
  w.write_tag(GBA_SEC_GPIO)
  w.write_u8(gpio.data)
  w.write_u8(gpio.direction)
  w.write_bool(gpio.allow_reads)
  let rtc = gpio.rtc
  w.write_bool(rtc.sck)
  w.write_bool(rtc.sio)
  w.write_bool(rtc.cs)
  w.write_u8(uint8(ord(rtc.state)))
  w.write_i32(int32(rtc.reg))
  w.write_i32(int32(rtc.buffer.size))
  w.write_u64(rtc.buffer.value)
  w.write_bool(rtc.irq)
  w.write_bool(rtc.m24)
  w.write_bool(rtc.deterministic)
  w.write_u64(uint64(rtc.epoch))

proc load_gpio_state(gpio: GPIO; r: var Reader; rev: uint32) =
  r.expect_tag(GBA_SEC_GPIO)
  gpio.data = r.read_u8()
  gpio.direction = r.read_u8()
  gpio.allow_reads = r.read_bool()
  let rtc = gpio.rtc
  rtc.sck = r.read_bool()
  rtc.sio = r.read_bool()
  rtc.cs  = r.read_bool()
  let st = r.read_u8()
  if int(st) > int(high(RtcState)):
    raise newException(StateError, "invalid RTC state in save state")
  rtc.state = RtcState(st)
  rtc.reg = int(r.read_i32())
  rtc.buffer.size = int(r.read_i32())
  rtc.buffer.value = r.read_u64()
  rtc.irq = r.read_bool()
  rtc.m24 = r.read_bool()
  if rev >= 3:
    rtc.deterministic = r.read_bool()
    rtc.epoch = int64(r.read_u64())
  else:
    # rev <= 2 had no deterministic RTC mode; epoch is ignored while off.
    rtc.deterministic = false
    rtc.epoch = 0

# ---- PPU ----

proc save_ppu_state(ppu: PPU; w: var Writer) =
  w.write_tag(GBA_SEC_PPU)
  w.write_u16(cast[uint16](ppu.dispcnt))
  w.write_u16(cast[uint16](ppu.dispstat))
  w.write_u16(ppu.vcount)
  for i in 0 .. 3:
    w.write_u16(cast[uint16](ppu.bgcnt[i]))
    w.write_u16(cast[uint16](ppu.bghofs[i]))
    w.write_u16(cast[uint16](ppu.bgvofs[i]))
  for bg in 0 .. 1:
    for i in 0 .. 3: w.write_u16(cast[uint16](ppu.bgaff[bg][i]))
    for i in 0 .. 1:
      w.write_u32(cast[uint32](ppu.bgref[bg][i]))
      w.write_i32(ppu.bgref_int[bg][i])
      w.write_i32(ppu.mosaic_bgref_int[bg][i])
  w.write_u16(cast[uint16](ppu.win0h))
  w.write_u16(cast[uint16](ppu.win1h))
  w.write_u16(cast[uint16](ppu.win0v))
  w.write_u16(cast[uint16](ppu.win1v))
  w.write_u16(cast[uint16](ppu.winin))
  w.write_u16(cast[uint16](ppu.winout))
  w.write_u16(cast[uint16](ppu.mosaic))
  w.write_u16(cast[uint16](ppu.bldcnt))
  w.write_u16(cast[uint16](ppu.bldalpha))
  w.write_u16(cast[uint16](ppu.bldy))
  w.write_bytes(ppu.pram)
  w.write_bytes(ppu.vram)
  w.write_bytes(ppu.oam)
  w.write_seq_u16(ppu.framebuffer)

proc load_ppu_state(ppu: PPU; r: var Reader) =
  r.expect_tag(GBA_SEC_PPU)
  ppu.dispcnt  = cast[DISPCNT](r.read_u16())
  ppu.dispstat = cast[DISPSTAT](r.read_u16())
  ppu.vcount   = r.read_u16()
  for i in 0 .. 3:
    ppu.bgcnt[i]  = cast[BGCNT](r.read_u16())
    ppu.bghofs[i] = cast[BGOFS](r.read_u16())
    ppu.bgvofs[i] = cast[BGOFS](r.read_u16())
  for bg in 0 .. 1:
    for i in 0 .. 3: ppu.bgaff[bg][i] = cast[BGAFF](r.read_u16())
    for i in 0 .. 1:
      ppu.bgref[bg][i] = cast[BGREF](r.read_u32())
      ppu.bgref_int[bg][i] = r.read_i32()
      ppu.mosaic_bgref_int[bg][i] = r.read_i32()
  ppu.win0h  = cast[WINH](r.read_u16())
  ppu.win1h  = cast[WINH](r.read_u16())
  ppu.win0v  = cast[WINV](r.read_u16())
  ppu.win1v  = cast[WINV](r.read_u16())
  ppu.winin  = cast[WININ](r.read_u16())
  ppu.winout = cast[WINOUT](r.read_u16())
  ppu.mosaic = cast[MOSAIC](r.read_u16())
  ppu.bldcnt = cast[BLDCNT](r.read_u16())
  ppu.bldalpha = cast[BLDALPHA](r.read_u16())
  ppu.bldy   = cast[BLDY](r.read_u16())
  r.read_bytes(ppu.pram)
  r.read_bytes(ppu.vram)
  r.read_bytes(ppu.oam)
  r.read_seq_u16_into(ppu.framebuffer)
  # Force a full re-render so render-skip cannot show stale pre-load pixels
  ppu.frame = 0
  ppu.render_dirty = true
  ppu.skip_render = false
  ppu.frame_static = false
  # The per-line OBJ candidate list is derived scratch, not in the payload
  ppu.oam_touched()
  ppu.obj_list_rebuilds = 0

# ---- APU ----

proc save_channel_base(ch: SoundChannel; w: var Writer) =
  w.write_bool(ch.enabled)
  w.write_bool(ch.dac_enabled)
  w.write_i32(int32(ch.length_counter))
  w.write_bool(ch.length_enable)

proc load_channel_base(ch: SoundChannel; r: var Reader) =
  ch.enabled = r.read_bool()
  ch.dac_enabled = r.read_bool()
  ch.length_counter = int(r.read_i32())
  ch.length_enable = r.read_bool()

proc save_channel_env(ch: VolumeEnvelopeChannel; w: var Writer) =
  save_channel_base(ch, w)
  w.write_u8(ch.starting_volume)
  w.write_bool(ch.envelope_add_mode)
  w.write_u8(ch.period_ve)
  w.write_u8(ch.volume_envelope_timer)
  w.write_u8(ch.current_volume)
  w.write_bool(ch.volume_envelope_is_updating)

proc load_channel_env(ch: VolumeEnvelopeChannel; r: var Reader) =
  load_channel_base(ch, r)
  ch.starting_volume = r.read_u8()
  ch.envelope_add_mode = r.read_bool()
  ch.period_ve = r.read_u8()
  ch.volume_envelope_timer = r.read_u8()
  ch.current_volume = r.read_u8()
  ch.volume_envelope_is_updating = r.read_bool()

proc save_apu_state(apu: APU; w: var Writer) =
  w.write_tag(GBA_SEC_APU)
  w.write_u16(cast[uint16](apu.soundcnt_l))
  w.write_u16(cast[uint16](apu.soundcnt_h))
  w.write_bool(apu.sound_enabled)
  w.write_u16(cast[uint16](apu.soundbias))
  w.write_u8(uint8(apu.frame_sequencer_stage))
  w.write_bool(apu.first_half_of_length_period)
  block:
    let ch = apu.channel1
    save_channel_env(ch, w)
    w.write_i32(int32(ch.wave_duty_position))
    w.write_u8(ch.sweep_period)
    w.write_bool(ch.negate)
    w.write_u8(ch.shift_ch1)
    w.write_u8(ch.sweep_timer)
    w.write_u16(ch.frequency_shadow)
    w.write_bool(ch.sweep_enabled)
    w.write_bool(ch.negate_has_been_used)
    w.write_u8(ch.duty)
    w.write_u8(ch.length_load)
    w.write_u16(ch.frequency_ch1)
  block:
    let ch = apu.channel2
    save_channel_env(ch, w)
    w.write_i32(int32(ch.wave_duty_position))
    w.write_u8(ch.duty)
    w.write_u8(ch.length_load)
    w.write_u16(ch.frequency_ch2)
  block:
    let ch = apu.channel3
    save_channel_base(ch, w)
    w.write_bytes(ch.wave_ram[0])
    w.write_bytes(ch.wave_ram[1])
    w.write_u8(ch.wave_ram_position)
    w.write_u8(ch.wave_ram_sample_buffer)
    w.write_bool(ch.wave_ram_dimension)
    w.write_u8(ch.wave_ram_bank)
    w.write_u8(ch.length_load_ch3)
    w.write_u8(ch.volume_code)
    w.write_bool(ch.volume_force)
    w.write_u16(ch.frequency_ch3)
  block:
    let ch = apu.channel4
    save_channel_env(ch, w)
    w.write_u16(ch.lfsr)
    w.write_u8(ch.length_load_ch4)
    w.write_u8(ch.clock_shift)
    w.write_u8(ch.width_mode)
    w.write_u8(ch.divisor_code)
  block:
    let dc = apu.dma_channels
    for f in 0 .. 1:
      for i in 0 .. 31: w.write_i8(dc.fifos[f][i])
      w.write_i32(int32(dc.positions[f]))
      w.write_i32(int32(dc.sizes[f]))
      w.write_i16(dc.latches[f])

proc load_apu_state(apu: APU; r: var Reader) =
  r.expect_tag(GBA_SEC_APU)
  apu.soundcnt_l = cast[SOUNDCNT_L](r.read_u16())
  apu.soundcnt_h = cast[SOUNDCNT_H](r.read_u16())
  apu.sound_enabled = r.read_bool()
  apu.soundbias = cast[SOUNDBIAS](r.read_u16())
  apu.frame_sequencer_stage = int(r.read_u8())
  apu.first_half_of_length_period = r.read_bool()
  block:
    let ch = apu.channel1
    load_channel_env(ch, r)
    ch.wave_duty_position = int(r.read_i32())
    ch.sweep_period = r.read_u8()
    ch.negate = r.read_bool()
    ch.shift_ch1 = r.read_u8()
    ch.sweep_timer = r.read_u8()
    ch.frequency_shadow = r.read_u16()
    ch.sweep_enabled = r.read_bool()
    ch.negate_has_been_used = r.read_bool()
    ch.duty = r.read_u8()
    ch.length_load = r.read_u8()
    ch.frequency_ch1 = r.read_u16()
  block:
    let ch = apu.channel2
    load_channel_env(ch, r)
    ch.wave_duty_position = int(r.read_i32())
    ch.duty = r.read_u8()
    ch.length_load = r.read_u8()
    ch.frequency_ch2 = r.read_u16()
  block:
    let ch = apu.channel3
    load_channel_base(ch, r)
    r.read_bytes(ch.wave_ram[0])
    r.read_bytes(ch.wave_ram[1])
    ch.wave_ram_position = r.read_u8()
    ch.wave_ram_sample_buffer = r.read_u8()
    ch.wave_ram_dimension = r.read_bool()
    ch.wave_ram_bank = r.read_u8()
    ch.length_load_ch3 = r.read_u8()
    ch.volume_code = r.read_u8()
    ch.volume_force = r.read_bool()
    ch.frequency_ch3 = r.read_u16()
  block:
    let ch = apu.channel4
    load_channel_env(ch, r)
    ch.lfsr = r.read_u16()
    ch.length_load_ch4 = r.read_u8()
    ch.clock_shift = r.read_u8()
    ch.width_mode = r.read_u8()
    ch.divisor_code = r.read_u8()
  block:
    let dc = apu.dma_channels
    for f in 0 .. 1:
      for i in 0 .. 31: dc.fifos[f][i] = r.read_i8()
      dc.positions[f] = int(r.read_i32())
      dc.sizes[f] = int(r.read_i32())
      dc.latches[f] = r.read_i16()
  # Drop the half-filled sample buffer and the pre-load SDL queue backlog
  apu.buffer_pos = 0
  when not defined(test_harness) and not defined(emscripten):
    if apu.audio_dev != 0:
      sdl_clear_queued_audio(apu.audio_dev)

# ---- Backup storage ----

proc storage_kind_tag(st: Storage): uint8 =
  if st of EEPROM: 2'u8
  elif st of Flash: 1'u8
  else: 0'u8

proc save_storage_state(st: Storage; w: var Writer) =
  w.write_tag(GBA_SEC_STORAGE)
  w.write_u8(storage_kind_tag(st))
  w.write_seq_u8(st.memory)
  if st of Flash:
    let fl = Flash(st)
    w.write_u8(uint8(ord(fl.flash_type)))
    w.write_u8(cast[uint8](fl.state))
    w.write_u8(fl.bank)
  elif st of EEPROM:
    let ep = EEPROM(st)
    w.write_u8(if ep.eeprom_size.isNone: 0'u8
               elif ep.eeprom_size.get == eeprom4k: 1'u8
               else: 2'u8)
    w.write_u16(cast[uint16](ep.state))
    w.write_i32(int32(ep.buffer.size))
    w.write_u64(ep.buffer.value)
    w.write_u32(ep.address)
    w.write_i32(int32(ep.ignored_reads))
    w.write_i32(int32(ep.read_bits))
    w.write_i32(int32(ep.wrote_bits))

proc load_storage_state(st: Storage; r: var Reader) =
  r.expect_tag(GBA_SEC_STORAGE)
  let kind = r.read_u8()
  if kind != storage_kind_tag(st):
    raise newException(StateError, "save state backup type mismatch")
  let mem = r.read_seq_u8()
  if st of EEPROM:
    # EEPROM buffers are sized lazily, so the file chooses the length. The
    # write path indexes an UncheckedArray over `memory`, so an undersized
    # buffer is a heap write primitive: only the two legal sizes pass.
    check_one_of(mem.len, [0x200, 0x2000], "eeprom.memory.len")
    st.memory = mem
  else:
    if mem.len != st.memory.len:
      raise state_error("save state backup size mismatch")
    st.memory = mem
  if st of Flash:
    let fl = Flash(st)
    let ft = r.read_u8()
    if int(ft) > int(high(StorageType)):
      raise state_error("invalid flash type in save state")
    fl.flash_type = StorageType(ft)
    let fst = r.read_u8()
    check_no_undefined_bits(uint32(fst), FlashStateFlag.high.int + 1, "flash.state")
    fl.state = cast[set[FlashStateFlag]](fst)
    fl.bank = r.read_u8()
  elif st of EEPROM:
    let ep = EEPROM(st)
    let sz = r.read_u8()
    ep.eeprom_size = case sz
      of 0'u8: none(EepromSize)
      of 1'u8: some(eeprom4k)
      else:    some(eeprom64k)
    let est = r.read_u16()
    check_no_undefined_bits(uint32(est), EepromStateFlag.high.int + 1, "eeprom.state")
    ep.state = cast[set[EepromStateFlag]](est)
    ep.buffer.size = int(r.read_i32())
    check_range(ep.buffer.size, 0, 64, "eeprom.buffer.size")  # bits into a u64
    ep.buffer.value = r.read_u64()
    ep.address = r.read_u32()
    # The address reaches the UncheckedArray write before the next 10-bit mask
    check_range(int(ep.address), 0, 0x3FF, "eeprom.address")
    ep.ignored_reads = int(r.read_i32())
    ep.read_bits = int(r.read_i32())
    ep.wrote_bits = int(r.read_i32())
    # address * 8 + wrote_bits div 8 indexes `memory` directly
    check_range(ep.ignored_reads, 0, 4, "eeprom.ignored_reads")
    check_range(ep.read_bits, 0, 64, "eeprom.read_bits")
    check_range(ep.wrote_bits, 0, 64, "eeprom.wrote_bits")
    # A 10-bit address can exceed a 4 Kbit part
    if int(ep.address) * 8 + 8 > ep.memory.len:
      raise state_error("eeprom address " & $ep.address & " is past the end of a " &
                        $ep.memory.len & "-byte EEPROM")
    # busy_until is not in the format: treat in-flight programming as settled
    ep.busy_until = 0
  st.dirty = true  # persist to the .sav on the next flush

# ---- PSG waveform deadlines <-> scheduler events ----
#
# The channels' next_step deadlines replaced one etAPUChannel<N> event per
# armed channel (gba/apu.nim). They round-trip through those events so the
# payload stays byte-identical to the older format in both directions.

proc apu_arm_state_events(gba: GBA) =
  # The catch-up guarantees each deadline is in the future (positive delay)
  gba.apu.apu_catchup_all()
  template arm(ch: untyped; et: EventType) =
    if ch.next_step != GBA_NO_STEP:
      gba.scheduler.schedule(int(ch.next_step - gba.scheduler.cycles), et)
  arm(gba.apu.channel1, etAPUChannel1)
  arm(gba.apu.channel2, etAPUChannel2)
  arm(gba.apu.channel3, etAPUChannel3)
  arm(gba.apu.channel4, etAPUChannel4)

proc apu_disarm_state_events(gba: GBA) =
  gba.scheduler.clear(etAPUChannel1)
  gba.scheduler.clear(etAPUChannel2)
  gba.scheduler.clear(etAPUChannel3)
  gba.scheduler.clear(etAPUChannel4)

proc apu_extract_state_events(gba: GBA) =
  # `et` rather than `kind`: a template parameter named `kind` would be
  # substituted into `ev.kind` too.
  template take(ch: untyped; et: EventType; arm: uint32) =
    ch.next_step = GBA_NO_STEP
    for ev in gba.scheduler.events:
      if ev.kind == et: ch.next_step = ev.cycles
    gba.scheduler.clear(et)
    # arm_delay is not recoverable from an event's target; the current
    # period is right except across an unstepped frequency write, and it
    # only breaks an exact-cycle tie (one sample off, once, after a load).
    ch.arm_delay = arm
  take(gba.apu.channel1, etAPUChannel1, gba.apu.channel1.ch1_frequency_timer())
  take(gba.apu.channel2, etAPUChannel2, gba.apu.channel2.ch2_frequency_timer())
  take(gba.apu.channel3, etAPUChannel3, gba.apu.channel3.ch3_frequency_timer())
  take(gba.apu.channel4, etAPUChannel4, gba.apu.channel4.ch4_frequency_timer())

when defined(deltachar):
  # -d:deltachar: byte offset of each payload section for delta histograms
  var payloadSections*: seq[(string, int)] = @[]

# ---- The in-process / file boundary ----
#
# `in_process` = true pads the scheduler section to a fixed length (see
# PAD_RATIONALE in common/scheduler.nim) so the rewind ring's XOR delta
# aligns. It must be true for payloads that stay in this process (rewind
# ring, rollback snapshots) and false for anything that can reach a file:
# padded bytes are not the .state format. The public state_payload /
# apply_state_payload family is in-process; state_bytes / save_state /
# load_state_bytes / state_image are unpadded. A mismatch trips expect_tag
# on the next section (tests/savestate_compat_test.nim covers it).

proc gba_state_payload(gba: GBA; in_process = false): string =
  var w = Writer()
  when defined(deltachar):
    payloadSections.setLen(0)
    template mark(name: string) = payloadSections.add((name, w.buf.len))
  else:
    template mark(name: string) = discard
  mark("cpu")
  save_cpu_state(gba.cpu, w)
  mark("bus(+ewram+iwram)")
  save_bus_state(gba.bus, w)
  mark("sched")
  w.write_tag(GBA_SEC_SCHED)
  gba.apu_arm_state_events()
  gba.scheduler.save_to(w, pad = in_process)
  gba.apu_disarm_state_events()
  mark("irq")
  save_irq_state(gba.interrupts, w)
  mark("mmio")
  save_mmio_state(gba.mmio, w)
  mark("keypad")
  save_keypad_state(gba.keypad, w)
  mark("timer")
  save_timer_state(gba.timer, w)
  mark("serial")
  save_serial_state(gba.serial, w)
  mark("dma")
  save_dma_state(gba.dma, w)
  mark("gpio")
  save_gpio_state(gba.bus.gpio, w)
  mark("ppu(vram+pram+oam+fb)")
  save_ppu_state(gba.ppu, w)
  mark("apu")
  save_apu_state(gba.apu, w)
  mark("storage(sram)")
  save_storage_state(gba.storage, w)
  mark("end")
  w.write_tag(GBA_SEC_END)
  w.buf

# ---- rev <= 3 -> 4: retrofit the HLE IntrWait System-stack frames ----
#
# The HLE IntrWait pushes {r2, lr} (dispatcher) + {r4, lr} (routine) onto
# the System stack and pops all four unconditionally on resume. A rev <= 3
# state parked in IntrWait has no frame and an unshifted sp, but its
# registers still hold the caller's r2/r4/lr_sys (the old build never
# overwrote them while waiting), so writing them where the pop expects them
# reproduces the old caller-visible outcome exactly.
#
# Safe only while the CPU is halted in the wait loop: with the user IRQ
# handler mid-flight on the same stack, lowering sp would move the base its
# pushes already used, so those states are refused in gba_apply_state.
proc migrate_intr_wait_frame(gba: GBA) =
  let cpu = gba.cpu
  let usp = cpu.sys_sp()
  # Layout check_intr_wait pops: [usp-16] r4, [usp-12] 0x170, [usp-8] r2,
  # [usp-4] lr.
  gba.bus.write_word_internal(usp - 4,  cpu.sys_lr())
  gba.bus.write_word_internal(usp - 8,  cpu.r[2])
  gba.bus.write_word_internal(usp - 12, 0x170'u32)
  gba.bus.write_word_internal(usp - 16, cpu.r[4])
  cpu.set_sys_sp(usp - 16)
  # The halt loop's register convention (see hle_intr_wait)
  cpu.r[4] = 1
  cpu.r[2] = uint32(cpu.read_intr_mirror())
  cpu.set_sys_lr(0x34C'u32)

proc gba_apply_state(gba: GBA; payload: string; rev: uint32;
                          in_process = false) =
  var r = Reader(buf: payload)
  load_cpu_state(gba.cpu, r, rev)
  if rev < 4 and gba.cpu.intr_wait_active and not gba.cpu.halted:
    raise newException(StateError,
      "this save state was taken inside a BIOS IntrWait with the interrupt " &
      "handler still running, under an older HLE stack model that cannot be " &
      "reconstructed — it would resume with a corrupted stack pointer")
  load_bus_state(gba.bus, r, rev)
  r.expect_tag(GBA_SEC_SCHED)
  gba.scheduler.load_from(r, pad = in_process)
  # Only the PPU event chain increments ppu.frame, and a running machine
  # always carries exactly one of its events. A state with none (a corrupt
  # event kind is still a legal enum value) would hang step_frame forever.
  # "At least one of the chain" so this holds if the capture phase changes.
  block:
    var has_ppu_event = false
    for ev in gba.scheduler.events:
      if ev.kind in {etPPUStartLine, etPPUStartHBlank, etPPUSetHBlankFlag,
                     etPPUEndHBlank}:
        has_ppu_event = true
        break
    if not has_ppu_event:
      raise state_error("save state has no pending PPU event, so its display " &
                        "could never advance")
  load_irq_state(gba.interrupts, r)
  load_mmio_state(gba.mmio, r)
  load_keypad_state(gba.keypad, r)
  load_timer_state(gba.timer, r)
  load_serial_state(gba.serial, r)
  load_dma_state(gba.dma, r, rev)
  load_gpio_state(gba.bus.gpio, r, rev)
  load_ppu_state(gba.ppu, r)
  load_apu_state(gba.apu, r)
  gba.apu_extract_state_events()
  load_storage_state(gba.storage, r)
  r.expect_tag(GBA_SEC_END)
  # After the payload, so the stack it writes into is the restored WRAM
  if rev < 4 and gba.cpu.intr_wait_active:
    gba.migrate_intr_wait_frame()
  # irq_line and the WAITCNT timing tables are derived, not serialized.
  # check_interrupts also resolves the halt, and a frame-boundary state is
  # written the instant vblank raises IF, so it nearly always carries a
  # pending etInterrupts event: letting the recompute wake the CPU here
  # fires that event IRQ_SYNC_DELAY cycles early (save -> load -> save was
  # not idempotent). Every path that raises IF schedules the check, so the
  # event owns the wake: keep halted/halt_wake/stopped. Likewise irq_line is
  # the result of the last check, so with a check pending it must stay
  # false or the IRQ moves one instruction (Golden Sun drifted lr_irq and
  # the user sp on every restore). With no check pending the recompute is
  # exact: IF only gains bits between checks.
  let checkPending = gba.scheduler.has_event(etInterrupts)
  let halted  = gba.cpu.halted
  let wake    = gba.cpu.halt_wake
  let stopped = gba.cpu.stopped
  gba.interrupts.check_interrupts()
  gba.cpu.halted    = halted
  gba.cpu.halt_wake = wake
  gba.cpu.stopped   = stopped
  if checkPending: gba.cpu.irq_line = false
  gba.bus.update_waitcnt(gba.mmio.waitcnt)
  # The audio HLE shadow mixers are not serialized (state files are
  # byte-identical with the HLE on or off); they re-latch from restored RAM.
  if gba.mp2k != nil:
    gba.mp2k.mp2k_state_loaded()
  if gba.gs_bon != nil:
    gba.gs_bon.gs_state_loaded()

# Header "ROM size" slot: a validation tag only, kept at the historical
# 32 MB constant across buffer-sizing changes. ROM identity is gba_rom_checksum.
const GBA_STATE_ROM_TAG = 0x02000000'u32

proc gba_rom_checksum(gba: GBA): uint32 =
  ## ROM identity: hash of the first 1 MB of the ROM file, cached at load
  ## (Cartridge.rom_identity). Hashing the file rather than the padded
  ## buffer keeps the identity independent of the allocation rule; reading
  ## the cache rather than the live buffer keeps cheat patches from
  ## re-identifying the cart. Not on any wire: netplay's `LinkMsg.rom_crc`
  ## is a separate quantity.
  gba.cartridge.rom_identity

proc gba_legacy_rom_checksums(gba: GBA): seq[uint32] =
  ## Identities older builds computed for this cart, accepted on read only.
  ## Both variants hashed the 1 MB window of the padded buffer, so they
  ## differ from the current value only for carts under 1 MB.
  let sz = gba.cartridge.rom_size
  if sz <= 0 or sz >= 0x100000: return @[]
  let current = gba.gba_rom_checksum()

  proc add_legacy(s: var seq[uint32]; v: uint32) =
    if v != current and v notin s: s.add(v)

  # (a) next_pow2 buffer with a 32 KB floor, zero-filled past the file.
  #     Reconstructed from that rule, not from cartridge.rom.len: the live
  #     floor has since changed, and using it would orphan the states those
  #     builds wrote (tests/savestate_compat).
  block:
    var pad = 0x8000
    while pad < sz: pad = pad shl 1
    let n = min(pad, 0x100000)
    var h = 0x811C9DC5'u32
    for a in 0 ..< n:
      let b = if a < sz: gba.cartridge.rom[a] else: 0'u8
      h = (h xor uint32(b)) * 0x01000193'u32
    result.add_legacy(h)

  # (b) a flat 32 MB buffer pre-filled with the open-bus pattern, the file at
  #     the front, [sz, next_pow2) zeroed (empty when sz is a power of two).
  var pow2 = 1
  while pow2 < sz: pow2 = pow2 shl 1
  var h = 0x811C9DC5'u32
  for a in 0 ..< 0x100000:
    let b = if a < sz: gba.cartridge.rom[a]
            elif a < pow2: 0'u8
            else: rom_open_bus(uint32(a))
    h = (h xor uint32(b)) * 0x01000193'u32
  result.add_legacy(h)

proc state_payload*(gba: GBA): string =
  ## Raw in-process payload (padded, no header); frame boundaries only.
  gba.gba_state_payload(in_process = true)

proc apply_state_payload*(gba: GBA; payload: string) =
  ## Apply a state_payload. Raises StateError on corrupt input, no rollback.
  gba.gba_apply_state(payload, GBA_PAYLOAD_VERSION, in_process = true)

proc apply_state_payload*(gba: GBA; payload: string; rev: uint32) =
  ## As above for an older revision (format tests exercise migrations).
  gba.gba_apply_state(payload, rev, in_process = true)

const GBA_THUMB_W = 120
const GBA_THUMB_H = GBA_THUMB_W * 160 div 240   # preserve 3:2 → 120x80

proc gba_thumbnail(gba: GBA): seq[byte] =
  downscale_bgr555(gba.ppu.framebuffer, 240, 160, GBA_THUMB_W, GBA_THUMB_H)

proc state_bytes*(gba: GBA; thumbnail = false): string =
  ## Full state image (header + payload), the .state file format. With
  ## thumbnail, a BGR555 screenshot trailer is appended (old readers ignore it).
  let payload = gba.gba_state_payload()
  if thumbnail:
    make_state_bytes(ckGBA, gba.gba_rom_checksum(), GBA_STATE_ROM_TAG, payload,
                     gba.gba_thumbnail(), uint16(GBA_THUMB_W), uint16(GBA_THUMB_H))
  else:
    make_state_bytes(ckGBA, gba.gba_rom_checksum(), GBA_STATE_ROM_TAG, payload)

proc gba_apply_checked(gba: GBA; payload: string; rev: uint32): bool =
  ## Apply a validated payload, restoring the live machine if it fails midway.
  let backup = gba.gba_state_payload()
  try:
    gba.gba_apply_state(payload, rev)
    last_state_reject_kind = srkNone
    return true
  except CatchableError:
    last_state_error = getCurrentExceptionMsg()
    echo "Load state failed: ", last_state_error
  except Defect as d:
    # Backstop for a field no reader has bounded yet (the fix is a range
    # guard in the reader; tools/statefuzz.nim's byte sweep fails on a
    # reachable one). Continuing is safe only because the next line restores
    # a payload this build serialized moments ago; an uncaught Defect would
    # abort the wasm module over a stranger's file.
    last_state_error = "this save state is damaged"
    last_state_reject_kind = srkCorrupt
    echo "Load state failed: an unbounded field reached a ", d.name,
         " — that is a dingbat bug, please report it: ", d.msg
  restore_backup(gba.gba_apply_state(backup, GBA_PAYLOAD_VERSION))
  false

proc parse_state_image*(gba: GBA; data: string; origin = "state data"):
                       tuple[payload: string; rev: uint32] =
  ## Header validation against this cart, including legacy ROM identities.
  ## load_state passes the same values to read_state_payload instead (it
  ## needs the file-not-found path).
  parse_state_payload(data, ckGBA, gba.gba_rom_checksum(), GBA_STATE_ROM_TAG,
                      origin, gba.gba_legacy_rom_checksums())

proc load_state_bytes*(gba: GBA; data: string): bool =
  ## Validate and apply a full state image. Mirrors load_state's rollback.
  last_state_reject_kind = srkNone
  var image: tuple[payload: string; rev: uint32]
  try:
    image = gba.parse_state_image(data)
  except CatchableError:
    last_state_error = getCurrentExceptionMsg()
    echo "Load state failed: ", last_state_error
    return false
  gba.gba_apply_checked(image.payload, image.rev)

proc save_state*(gba: GBA; path: string; thumbnail = false): bool =
  ## Write the full state to path; frame boundary only. False on failure.
  try:
    if thumbnail:
      write_state_file(path, ckGBA, gba.gba_rom_checksum(), GBA_STATE_ROM_TAG,
                       gba.gba_state_payload(), gba.gba_thumbnail(),
                       uint16(GBA_THUMB_W), uint16(GBA_THUMB_H))
    else:
      write_state_file(path, ckGBA, gba.gba_rom_checksum(),
                       GBA_STATE_ROM_TAG, gba.gba_state_payload())
    true
  except CatchableError:
    echo "Save state failed: ", getCurrentExceptionMsg()
    false

proc load_state*(gba: GBA; path: string): bool =
  ## Restore state from path; frame boundary only. On a validation error the
  ## emulator is untouched; if applying fails midway the prior state is restored.
  last_state_reject_kind = srkNone
  var image: tuple[payload: string; rev: uint32]
  try:
    image = read_state_payload(path, ckGBA, gba.gba_rom_checksum(),
                               GBA_STATE_ROM_TAG,
                               gba.gba_legacy_rom_checksums())
  except CatchableError:
    last_state_error = getCurrentExceptionMsg()
    echo "Load state failed: ", last_state_error
    return false
  gba.gba_apply_checked(image.payload, image.rev)
