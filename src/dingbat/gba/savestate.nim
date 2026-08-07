# GBA save-state serialization (included by gba.nim).
#
# States are only ever written at frame boundaries (right after step_frame
# returns), so no mid-instruction CPU state exists: bus.cycles has just been
# reset, frame progress is derived from the scheduler, and entered_waitloop is transient
# within a tick. Deterministic caches (waitloop detection sets, the fetch-page
# fast path) are rebuilt instead of serialized. The ROM itself is not stored;
# the header carries a checksum + size so the right ROM must already be loaded.

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
  # HLE BIOS IntrWait state (the only persistent HLE SWI state)
  w.write_bool(cpu.intr_wait_active)
  w.write_u16(cpu.intr_wait_mask)
  w.write_u32(cpu.intr_wait_resume_addr)
  # Halt-wake IRQ entry discount + deferred HLE Halt/Stop return charge
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
    # rev 1 charged the BIOS's post-wake return path up front, at SWI call
    # time, so there is never anything deferred in a rev-1 state: 0 is the
    # value, not a guess. halt_wake is a transient consumed at the next
    # instruction boundary; false costs the 2-cycle entry discount on at most
    # one IRQ, and halt_resume_addr is only read when the charge is nonzero.
    cpu.halt_wake = false
    cpu.halt_resume_charge = 0
    cpu.halt_resume_addr = 0
  if rev >= 4:
    cpu.halt_resume_pop = r.read_bool()
  else:
    # rev <= 3 predates the HLE dispatcher's System-stack frames: its Halt/Stop
    # never lowered the System sp, so there is nothing for the resume path to
    # pop. false is exactly right, and it makes the resume leave r2/lr/sp live
    # — which is precisely what the build that wrote the file did.
    #
    # IntrWait is the case that does NOT fall out for free: its resume pops 16
    # bytes unconditionally, with no flag to switch off. gba_apply_state
    # retrofits the frame afterwards (see migrate_intr_wait_frame) for the
    # states where that is provably safe, and refuses the rest.
    cpu.halt_resume_pop = false
  cpu.entered_waitloop = false

# ---- Bus ----

proc save_bus_state(bus: Bus; w: var Writer) =
  w.write_tag(GBA_SEC_BUS)
  w.write_i32(int32(bus.cycles))
  w.write_u32(bus.bios_latch)
  w.write_bytes(bus.wram_board)
  w.write_bytes(bus.wram_chip)
  # ROM burst / prefetch timing trackers. These PERSIST across frame boundaries
  # (the CPU keeps fetching from ROM), so unlike the rebuilt fast-path caches
  # they must be serialized: the first ROM access after a load reads them to
  # judge sequential-vs-nonsequential and prefetch credit. Omitting them
  # mistimes that access by a few cycles — invisible in a one-shot load, but it
  # breaks bit-exact rollback replay (the frame ends a few cycles off).
  w.write_u32(bus.rom_next_addr)
  w.write_u32(bus.rom_next_addr2)
  w.write_u64(uint64(bus.rom_free_since))
  w.write_bool(bus.rom_hot)
  w.write_bool(bus.dma_active)

proc load_bus_state(bus: Bus; r: var Reader; rev: uint32) =
  r.expect_tag(GBA_SEC_BUS)
  # Un-synced cycle debt for the instruction in flight. `catchup` drains it to
  # 0 constantly, and `bus.now` does `sched.cycles + CycleCount(bus.cycles)` —
  # an unsigned conversion, so a NEGATIVE value here is an immediate defect,
  # and a huge positive one overflows the same sum. States are written at
  # frame boundaries where this is a handful of cycles; the web build can
  # serialize mid-instruction, so allow a whole scanline's worth and no more.
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
    # rev <= 2 didn't carry the burst trackers, so a load left whatever the
    # live machine happened to hold — i.e. nothing meaningful. Start them cold
    # instead: rom_next_addr = 1 is the sentinel the DMA and UND paths already
    # use for "no prior access" (it can never match a halfword-aligned
    # address), so the first ROM access after the load is judged
    # non-sequential with no prefetch credit. Costs a few cycles once, which
    # is exactly what 66a3c42 described as "invisible in a one-shot load".
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
  # keyinput deliberately stays live: it reflects currently held host keys,
  # not emulated machine state
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
    # Pre-v5 states have no latched count, so reconstruct it as the user
    # register — which IS what those builds ran on, so the state loads into
    # exactly the machine that wrote it. The two values diverge only for a
    # channel armed on a hardware trigger whose DMACNT_L was rewritten before
    # its first burst; a repeat channel reloads the count after every burst,
    # so between bursts the two always agree.
    dma.count[i] = if rev >= 5: r.read_u16() else: dma.dmacnt_l[i]
  # Arbitration state is always idle at frame boundaries (where states are
  # taken), so it is not serialized — just reset it
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
    # Deterministic RTC arrived with rev 3 and exists only to freeze the clock
    # across a linked session (enable_deterministic_rtc). A rev <= 2 state was
    # written by a build that had no such mode, so "off, real local time" is
    # the state it was in; epoch is ignored while off.
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
  # Per-scanline compositing scratch is recomputed; force a full re-render so
  # the render-skip optimization can't display stale pre-load pixels
  ppu.frame = 0
  ppu.render_dirty = true
  ppu.skip_render = false
  ppu.frame_static = false
  # OAM was just replaced wholesale, and the per-line OBJ candidate list is
  # derived scratch that is deliberately not in the payload (so old states
  # still load) -- rebuild it before the next scanline reads it.
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
  # Restart audio pacing cleanly: drop any half-filled sample buffer and the
  # SDL queue backlog that belongs to the pre-load timeline
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
    # EEPROM buffers are sized lazily (from the first command's DMA length),
    # so this is the one backup whose length is not fixed by the cart — which
    # made it the one place a state file could choose it. It cannot be free:
    # `eeprom.nim`'s write path does
    #   cast[ptr UncheckedArray[uint64]](unsafeAddr ep.memory[0])[ep.address]
    # and an UncheckedArray is unchecked at EVERY optimisation level, so an
    # undersized buffer here is a heap write primitive, and an empty one makes
    # `unsafeAddr ep.memory[0]` undefined before that. There are exactly two
    # legal sizes (EepromSize.file_size: 4 Kbit = 0x200, 64 Kbit = 0x2000).
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
    # The command shift register is at most a 64-bit-wide word plus its
    # address bits; `buffer.value` is a uint64 and `size` counts bits into it.
    check_range(ep.buffer.size, 0, 64, "eeprom.buffer.size")
    ep.buffer.value = r.read_u64()
    ep.address = r.read_u32()
    # The runtime masks the address to 10 bits on every command, so a state
    # may only carry what that mask can produce. Without this the address
    # reaches the UncheckedArray write above before the next mask does.
    check_range(int(ep.address), 0, 0x3FF, "eeprom.address")
    ep.ignored_reads = int(r.read_i32())
    ep.read_bits = int(r.read_i32())
    ep.wrote_bits = int(r.read_i32())
    # read_bits/wrote_bits index a 64-bit word: `base = address * 8 +
    # wrote_bits div 8` indexes `memory` directly, so an unbounded value walks
    # off the end of the backup.
    check_range(ep.ignored_reads, 0, 4, "eeprom.ignored_reads")
    check_range(ep.read_bits, 0, 64, "eeprom.read_bits")
    check_range(ep.wrote_bits, 0, 64, "eeprom.wrote_bits")
    # The address is masked to 0x3FF, i.e. up to 0x3FF*8+7 = 8191 bytes, which
    # a 4 Kbit (0x200-byte) part cannot hold. Reject the combination rather
    # than let the write land past the end of a legally-sized buffer.
    if int(ep.address) * 8 + 8 > ep.memory.len:
      raise state_error("eeprom address " & $ep.address & " is past the end of a " &
                        $ep.memory.len & "-byte EEPROM")
    # busy_until (write-settle window, <=115000 cycles) is not in the format;
    # treat any in-flight programming as settled. States are frame-boundary
    # only, so at worst a ready-poll observes ready ~0.4 frames early.
    ep.busy_until = 0
  # Persist the restored backup memory to the .sav on the next flush
  st.dirty = true

# ---- Top level ----

# ---- PSG waveform deadlines <-> scheduler events ----
#
# The channels' next_step deadlines replaced one etAPUChannel<N> scheduler event
# per armed channel (see gba/apu.nim). Rather than append four new fields to a
# positional, unversioned state format, round-trip them through the events they
# replaced: the payload stays byte-identical to the pre-catch-up format, so a
# state written here still loads in an older build and vice versa — which is
# also what keeps rollback and netplay snapshots (link.nim's LinkSnapshot is
# built from state_payload) carrying the deadlines across a restore.

proc apu_arm_state_events(gba: GBA) =
  # Deadlines are absolute scheduler cycles, which is what schedule() takes as
  # a delay from scheduler.cycles; the catch-up guarantees each one is in the
  # future, so the delay is positive.
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
  # substituted into `ev.kind` too and turn it into a bogus field access.
  template take(ch: untyped; et: EventType; arm: uint32) =
    ch.next_step = GBA_NO_STEP
    for ev in gba.scheduler.events:
      if ev.kind == et: ch.next_step = ev.cycles
    gba.scheduler.clear(et)
    # arm_delay is the delay the pending step was armed with; a scheduler event
    # only ever stored its TARGET, so neither this build nor the pre-catch-up
    # one can recover it from a state file. Rebuilt as the current period, which
    # is what it is except across a frequency write that has not been followed
    # by a step. It is read only to break an exact-cycle tie between a waveform
    # step and the sample/frame-sequencer event, so the worst case is one
    # channel stepping one sample early or late, once, after a load.
    ch.arm_delay = arm
  take(gba.apu.channel1, etAPUChannel1, gba.apu.channel1.ch1_frequency_timer())
  take(gba.apu.channel2, etAPUChannel2, gba.apu.channel2.ch2_frequency_timer())
  take(gba.apu.channel3, etAPUChannel3, gba.apu.channel3.ch3_frequency_timer())
  take(gba.apu.channel4, etAPUChannel4, gba.apu.channel4.ch4_frequency_timer())

when defined(deltachar):
  # EXPLORATORY (-d:deltachar): byte offset of each payload section, so a delta
  # histogram can be attributed to EWRAM / IWRAM / VRAM / framebuffer / save
  # rather than reported as one 604 KB blob.
  var payloadSections*: seq[(string, int)] = @[]

# ---- The in-process / file boundary -----------------------------------------
#
# `in_process` = true pads the scheduler section so the payload has a FIXED
# length (see PAD_RATIONALE in common/scheduler.nim). It is what makes the
# rewind ring's XOR delta align, and it is worth 8.5x on the delta size.
#
# It must be TRUE for payloads that stay in this process (the rewind ring,
# rollback snapshots) and FALSE for anything that can reach a file, because
# padded bytes are not the .state format and an older build could not read
# them. The rule is enforced three ways:
#
#   1. The rule is drawn at the API, not per call site: the public
#      state_payload / apply_state_payload family is ENTIRELY in-process and
#      passes true. The file family — state_bytes, save_state,
#      load_state_bytes, state_image — is entirely unpadded and reaches the
#      private *_state_payload / *_apply_state with the default false. If you
#      are adding a call and cannot tell which you want, ask whether the bytes
#      can outlive the process.
#   2. The default is false, so a new call site is unpadded unless it opts in.
#   3. A mismatch cannot pass silently: the padding sits immediately before a
#      section tag, so reading padded bytes as unpadded (or the reverse) trips
#      expect_tag on the very next section and raises StateError. There is a
#      dedicated regression test for the boundary in
#      tests/savestate_compat_test.nim.

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

# ---- rev <= 3 -> 4: retrofit the HLE IntrWait System-stack frames ----------
#
# 32dd8bb taught the HLE BIOS to model the real dispatcher's stack footprint.
# Its IntrWait now pushes {r2, lr} (dispatcher) + {r4, lr} (routine) onto the
# System stack, keeps sp 16 bytes lower for the whole wait, and pops all four
# words on resume — UNCONDITIONALLY, with no flag to turn off. A rev <= 3 state
# parked inside IntrWait has an unshifted sp and no frame in memory, so that
# resume would pop four words of the game's own stack into r4/r2/lr and hand sp
# back 16 too high. That is why the v5 bump refused old states outright.
#
# It does not have to. The old build never overwrote r2/r4/lr_sys while waiting,
# so a rev <= 3 state still holds the CALLER's values in those registers — which
# is exactly what the frame is supposed to contain. Writing them where the pop
# expects them makes the new resume restore the caller's r2/r4/lr and the
# original sp: byte for byte the same caller-visible outcome the old build's
# resume produced (it restored nothing and left them live).
#
# The 16 bytes land below the System sp, which is dead stack the new build
# clobbers on every IntrWait anyway — and putting BIOS residue there is the
# hardware behaviour 32dd8bb added, not a departure from it.
#
# Safe only while the CPU is HALTED in the wait loop. If the state was taken
# with intr_wait_active but not halted, the user IRQ handler is mid-flight on
# that same System stack: lowering sp under it would move the base its own
# pushes already used. There is no way to reconstruct that, so those states are
# refused (see the check in gba_apply_state) rather than silently mis-resumed.
proc migrate_intr_wait_frame(gba: GBA) =
  let cpu = gba.cpu
  let usp = cpu.sys_sp()
  # Dispatcher frame {r2, lr} then routine frame {r4, lr = 0x170}, in the
  # layout check_intr_wait pops: [usp-16] r4, [usp-12] 0x170, [usp-8] r2,
  # [usp-4] lr.
  gba.bus.write_word_internal(usp - 4,  cpu.sys_lr())
  gba.bus.write_word_internal(usp - 8,  cpu.r[2])
  gba.bus.write_word_internal(usp - 12, 0x170'u32)
  gba.bus.write_word_internal(usp - 16, cpu.r[4])
  cpu.set_sys_sp(usp - 16)
  # ...and put the live registers into the halt loop's convention, which is what
  # this build would be holding had it entered the wait itself (r4 = 1, r2 = the
  # last mirror read, lr_sys = 0x34C, the bl-return inside the loop).
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
  # irq_line is derived from IE/IF/IME and not serialized; recompute it so a
  # pending-but-untaken IRQ at the save point isn't lost. Same for the
  # WAITCNT-derived bus timing tables.
  #
  # check_interrupts is not a pure recompute: it also RESOLVES the halt, and
  # doing that here runs it early. A peripheral that raises IF schedules the
  # recognition check IRQ_SYNC_DELAY cycles later (see interrupts.nim), and a
  # state written at a frame boundary is written the instant vblank raises its
  # flag — so nearly every state of a game that idles in HALT/IntrWait carries
  # a pending etInterrupts event that has not fired yet. Calling this
  # unconditionally fired it, clearing `halted` and setting `halt_wake` three
  # cycles ahead of the schedule the state itself preserves; the event then
  # fires on time and does the same work again. The visible symptom was that
  # save -> load -> save was not idempotent (two payload bytes plus the header
  # hash), and the same two bytes drifted on every rewind pop, rollback restore
  # and run-ahead frame, which all reload a payload through here. Take the
  # derived value and leave the halt to the event that owns it.
  #
  # Safe because every path that raises IF schedules that check in the same
  # breath (dma/keypad/timer/ppu/serial/rtc/hle_bios, and the IE/IF/IME writes
  # in mmio), so a state with a pending interrupt always carries the event that
  # will resolve the halt. Nothing else can wake a halted CPU, and nothing else
  # runs while it is halted, so the pending set cannot change in between.
  #
  # irq_line has the same shape of problem and the same answer. It is not a
  # function of IE/IF/IME alone — it is the RESULT of the last recognition
  # check, and a raise that has not been checked yet must not show up in it.
  # Recomputing unconditionally recognised the interrupt up to IRQ_SYNC_DELAY
  # cycles early, which for a game still executing at the frame boundary (as
  # opposed to idling in HALT) moves the IRQ one instruction: Golden Sun 1 and
  # 2 drifted lr_irq, the word the handler pushes at 0x03007F9C, and the user
  # stack pointer on every restore. So only recompute when no check is in
  # flight; when one is, the event carries the answer and will deliver it on
  # schedule.
  #
  # The recompute is exact in that case. IF only GAINS bits between checks (the
  # only way to clear one is a CPU write to IF, which schedules a check), so
  # "IE & IF != 0 and IME" holding now and no check pending means it held at
  # the last check too.
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
  # The MP2K HLE shadow mixer's state is deliberately not serialized (state
  # files stay byte-identical with the HLE on or off); it is rebuilt from the
  # restored RAM instead. Reset it and re-latch on the next mixer-pass hook.
  # gba_apply_state is the single funnel for every load path (load_state,
  # load_state_bytes, apply_state_payload/rollback), so this covers them all.
  if gba.mp2k != nil:
    gba.mp2k.mp2k_state_loaded()
  if gba.gs_bon != nil:
    gba.gs_bon.gs_state_loaded()

# Canonical value stored in the state-file header's "ROM size" slot. The ROM
# buffer is now sized to the cart's next power of two (not a flat 32 MB), but
# this field is only a validation tag; keeping the old 32 MB constant keeps
# state files backward/forward compatible across the resize. ROM identity comes
# from gba_rom_checksum, not this field.
const GBA_STATE_ROM_TAG = 0x02000000'u32

proc gba_rom_checksum(gba: GBA): uint32 =
  ## ROM identity: the first 1 MB of the ROM FILE, hashed (cheap, and every
  ## real cart is larger than the cap so nothing collides on the cap alone).
  ##
  ## `rom_size`, NOT `rom.len`. The buffer is padded — up to the next power of
  ## two, with a small floor, and out to 4 MB for the 1 MB Classic NES carts
  ## whose image is mirrored 4x (see cartridge.nim). Hashing `rom.len` folds
  ## that padding into the cart's identity, so any change to the padding RULE
  ## silently re-identifies every cart smaller than the cap and refuses its
  ## existing states as "a different ROM". That is exactly what 2dfd27e did
  ## when it replaced the flat 32 MB open-bus-filled buffer with next_pow2:
  ## see gba_legacy_rom_checksums, which is what keeps those states loading.
  ## Hashing the file bytes makes the identity independent of how we allocate.
  ##
  ## This value is NOT on any wire. The peer/ROM check netplay does is a
  ## different quantity with a similar name: `LinkMsg.rom_crc`, a CRC-32 of the
  ## ROM file sent in HELLO (common/linkproto.nim). Changing this proc cannot
  ## reject a peer; changing that one can. Keep them separate.
  ## Read from the cache taken at load (Cartridge.rom_identity), never from the
  ## live buffer: the cheat engine patches `rom` in place, so hashing it here
  ## meant toggling a ROM-patching code re-identified the cart and refused
  ## every state for it.
  gba.cartridge.rom_identity

proc gba_legacy_rom_checksums(gba: GBA): seq[uint32] =
  ## The identities OLDER builds computed for this same cart, accepted on read
  ## (never written) so that no user loses a state to the fix above. Both
  ## variants hashed the same 1 MB window of the ROM *buffer*, so they only
  ## differ from the current value for carts smaller than 1 MB — every cart
  ## >= 1 MB, Classic NES included, has an unchanged identity and doesn't even
  ## reach this code.
  ##
  ## Cost is one extra ≤1 MB hash on the load path of a sub-1 MB cart, i.e.
  ## homebrew and test ROMs; commercial carts return early.
  let sz = gba.cartridge.rom_size
  if sz <= 0 or sz >= 0x100000: return @[]
  let current = gba.gba_rom_checksum()

  proc add_legacy(s: var seq[uint32]; v: uint32) =
    # A cart whose file length is already a power of two >= 32 KB has no
    # padding in variant (a), so that variant lands on the current value;
    # don't list it twice.
    if v != current and v notin s: s.add(v)

  # (a) 2dfd27e .. the commit that added this: next_pow2 buffer (32 KB floor),
  #     zero-filled past the file.
  #
  #     Reconstructed from that RULE, not from cartridge.rom.len. The live
  #     allocation rule has changed again since (the floor is 0x100 now, so
  #     that reads back the open-bus pattern at the right address for a tiny
  #     cart), and reading the current buffer length here would have quietly
  #     re-derived a *different* "legacy" identity and orphaned every state a
  #     32 KB-floor build wrote for a sub-32 KB ROM. tests/savestate_compat
  #     catches exactly this.
  block:
    var pad = 0x8000
    while pad < sz: pad = pad shl 1
    let n = min(pad, 0x100000)
    var h = 0x811C9DC5'u32
    for a in 0 ..< n:
      let b = if a < sz: gba.cartridge.rom[a] else: 0'u8
      h = (h xor uint32(b)) * 0x01000193'u32
    result.add_legacy(h)

  # (b) before 2dfd27e: a flat 32 MB buffer pre-filled with the open-bus
  #     address pattern, the file written over the front, and [sz, next_pow2)
  #     re-zeroed — only when sz was not already a power of two, which is why
  #     the zero run below is empty in that case. Reconstructed by streaming
  #     rather than rebuilding the buffer; rom_open_bus is the same generator
  #     bus.nim uses today, so the two revisions cannot drift apart.
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
  ## Raw serialized state, no header/validation. For trusted in-process uses
  ## (the rewind ring buffer). Frame boundaries only.
  ##
  ## in_process = true: this payload never reaches a file, so it is padded to
  ## a fixed length. See the boundary note above.
  gba.gba_state_payload(in_process = true)

proc apply_state_payload*(gba: GBA; payload: string) =
  ## Apply a raw payload produced by state_payload. Raises StateError on
  ## corrupt input; no rollback — trusted callers only. Always this build's
  ## revision: the rewind ring and rollback snapshots never outlive the process.
  gba.gba_apply_state(payload, GBA_PAYLOAD_VERSION, in_process = true)

proc apply_state_payload*(gba: GBA; payload: string; rev: uint32) =
  ## As above, for a payload known to be in an OLDER revision. Exists so the
  ## format tests can exercise a migration without a whole state image; normal
  ## load paths get their revision from the header. In-process like the other
  ## overload: its callers hand it payloads produced by state_payload.
  gba.gba_apply_state(payload, rev, in_process = true)

const GBA_THUMB_W = 120
const GBA_THUMB_H = GBA_THUMB_W * 160 div 240   # preserve 3:2 → 120x80

proc gba_thumbnail(gba: GBA): seq[byte] =
  downscale_bgr555(gba.ppu.framebuffer, 240, 160, GBA_THUMB_W, GBA_THUMB_H)

proc state_bytes*(gba: GBA; thumbnail = false): string =
  ## Full validated state image (header + payload) for in-memory transports
  ## (web IndexedDB / downloads). Same format as .state files. With thumbnail,
  ## a downscaled BGR555 screenshot trailer is appended (ignored by old readers).
  let payload = gba.gba_state_payload()
  if thumbnail:
    make_state_bytes(ckGBA, gba.gba_rom_checksum(), GBA_STATE_ROM_TAG, payload,
                     gba.gba_thumbnail(), uint16(GBA_THUMB_W), uint16(GBA_THUMB_H))
  else:
    make_state_bytes(ckGBA, gba.gba_rom_checksum(), GBA_STATE_ROM_TAG, payload)

proc gba_apply_checked(gba: GBA; payload: string; rev: uint32): bool =
  ## Apply a validated payload, restoring the live machine if it fails midway.
  ## Both load paths go through here so the containment is written once.
  let backup = gba.gba_state_payload()
  try:
    gba.gba_apply_state(payload, rev)
    last_state_reject_kind = srkNone
    return true
  except CatchableError:
    last_state_error = getCurrentExceptionMsg()
    echo "Load state failed: ", last_state_error
  except Defect as d:
    # BACKSTOP, not the fix. The fix is the range guards in the readers above
    # (check_range / check_one_of / check_no_undefined_bits). This catches the
    # field nobody has bounded yet, and it is here on purpose rather than by
    # default:
    #
    #  - Catching Defect broadly is a bad habit: it hides real bugs. The
    #    mitigations are that this handler wraps ONE call, that it says in the
    #    log that reaching it is a bug in dingbat rather than in the file, and
    #    that tools/statefuzz.nim's byte sweep is a regression gate which
    #    FAILS on a reachable one instead of letting it be swallowed quietly.
    #  - Continuing after a Defect is normally indefensible, because the
    #    program is in an unknown state. It is defensible here, and only here,
    #    because the next line puts the machine back to a payload this build
    #    serialized itself moments ago. Nothing half-applied survives.
    #  - The alternative is worse than the bug it hides. A state file now
    #    travels — it gets shared, mailed, dropped in a chat — so it can be a
    #    stranger's, and an uncaught Defect takes the process down: in the wasm
    #    build it aborts the module, costing the player the game they were
    #    actually in the middle of, to punish them for opening someone's file.
    last_state_error = "this save state is damaged"
    last_state_reject_kind = srkCorrupt
    echo "Load state failed: an unbounded field reached a ", d.name,
         " — that is a dingbat bug, please report it: ", d.msg
  restore_backup(gba.gba_apply_state(backup, GBA_PAYLOAD_VERSION))
  false

proc parse_state_image*(gba: GBA; data: string; origin = "state data"):
                       tuple[payload: string; rev: uint32] =
  ## Header validation for a full state image against THIS cart, including the
  ## legacy ROM identities older builds wrote for it. Anything that has to ask
  ## "does this state belong to this ROM" goes through here (load_state_bytes,
  ## and the format test) rather than assembling the identity itself — the one
  ## exception is load_state, which needs the file-not-found path and so passes
  ## the same two values to read_state_payload.
  parse_state_payload(data, ckGBA, gba.gba_rom_checksum(), GBA_STATE_ROM_TAG,
                      origin, gba.gba_legacy_rom_checksums())

proc load_state_bytes*(gba: GBA; data: string): bool =
  ## Validate and apply a full state image. Mirrors load_state's rollback.
  var image: tuple[payload: string; rev: uint32]
  try:
    image = gba.parse_state_image(data)
  except CatchableError:
    last_state_error = getCurrentExceptionMsg()
    echo "Load state failed: ", last_state_error
    return false
  gba.gba_apply_checked(image.payload, image.rev)

proc save_state*(gba: GBA; path: string; thumbnail = false): bool =
  ## Serialize the full emulator state to path. Must only be called at a
  ## frame boundary (right after step_frame returns). Returns false and
  ## echoes a message on failure.
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
  ## Restore emulator state from path. Must only be called at a frame
  ## boundary. On any validation error the emulator is left untouched; if
  ## applying fails midway the pre-load state is restored.
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
