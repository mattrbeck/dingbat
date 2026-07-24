# GBA save-state serialization (included by gba.nim).
#
# States are only ever written at frame boundaries (right after step_frame
# returns), so no mid-instruction CPU state exists: bus.cycles has just been
# reset, count_cycles is per-frame scratch, and entered_waitloop is transient
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

proc visit_cpu[S](cpu: CPU; s: var S) =
  s.visit_tag GBA_SEC_CPU
  for i in 0 .. 15: s.visit_u32 cpu.r[i]
  s.visit_bits32 cpu.cpsr
  s.visit_bits32 cpu.spsr
  for bank in 0 .. 5:
    for reg in 0 .. 6: s.visit_u32 cpu.reg_banks[bank][reg]
  for bank in 0 .. 5: s.visit_u32 cpu.spsr_banks[bank]
  s.visit_u32 cpu.pipeline.buffer[0]
  s.visit_u32 cpu.pipeline.buffer[1]
  s.visit_u8  cpu.pipeline.pos
  s.visit_u8  cpu.pipeline.size
  s.visit_bool cpu.halted
  s.visit_bool cpu.stopped
  # HLE BIOS IntrWait state (the only persistent HLE SWI state)
  s.visit_bool cpu.intr_wait_active
  s.visit_u16  cpu.intr_wait_mask
  s.visit_u32  cpu.intr_wait_resume_addr
  # Halt-wake IRQ entry discount + deferred HLE Halt/Stop return charge
  s.visit_bool   cpu.halt_wake
  s.visit_bits32 cpu.halt_resume_charge
  s.visit_u32    cpu.halt_resume_addr
  s.visit_bool   cpu.halt_resume_pop  # v5
  when S is Reader:
    cpu.count_cycles = 0
    cpu.entered_waitloop = false

# ---- Bus ----

proc visit_bus[S](bus: Bus; s: var S) =
  s.visit_tag GBA_SEC_BUS
  s.visit_i32 bus.cycles
  s.visit_u32 bus.bios_latch
  s.visit_bytes bus.wram_board
  s.visit_bytes bus.wram_chip
  # ROM burst / prefetch timing trackers. These PERSIST across frame boundaries
  # (the CPU keeps fetching from ROM), so unlike the rebuilt fast-path caches
  # they must be serialized: the first ROM access after a load reads them to
  # judge sequential-vs-nonsequential and prefetch credit. Omitting them
  # mistimes that access by a few cycles — invisible in a one-shot load, but it
  # breaks bit-exact rollback replay (the frame ends a few cycles off).
  s.visit_u32  bus.rom_next_addr
  s.visit_u32  bus.rom_next_addr2
  s.visit_u64  bus.rom_free_since
  s.visit_bool bus.rom_hot
  s.visit_bool bus.dma_active
  when S is Reader:
    bus.fetch_page = 0xFFFFFFFF'u32  # invalidate the fetch fast path

# ---- Interrupts / MMIO / Keypad ----

proc visit_irq[S](intr: Interrupts; s: var S) =
  s.visit_tag GBA_SEC_IRQ
  s.visit_bits16 intr.reg_ie
  s.visit_bits16 intr.reg_if
  s.visit_bool   intr.ime

proc visit_mmio[S](mmio: MMIO; s: var S) =
  s.visit_tag GBA_SEC_MMIO
  s.visit_bits16 mmio.waitcnt

proc visit_keypad[S](kp: Keypad; s: var S) =
  # keyinput deliberately stays live: it reflects currently held host keys,
  # not emulated machine state
  s.visit_tag GBA_SEC_KEYPAD
  s.visit_bits16 kp.keycnt
  s.visit_bool   kp.prev_irq_condition

# ---- Timer / Serial / DMA ----

proc visit_timer[S](tim: Timer; s: var S) =
  s.visit_tag GBA_SEC_TIMER
  for i in 0 .. 3:
    s.visit_bits16 tim.tmcnt[i]
    s.visit_u16    tim.tmd[i]
    s.visit_u16    tim.tm[i]
    s.visit_u64    tim.cycle_enabled[i]

proc visit_serial[S](serial: Serial; s: var S) =
  s.visit_tag GBA_SEC_SERIAL
  s.visit_u16 serial.siocnt
  s.visit_u16 serial.rcnt
  s.visit_u16 serial.siodata8
  s.visit_u32 serial.siodata32
  s.visit_u16 serial.siomulti2
  s.visit_u16 serial.siomulti3
  s.visit_u16 serial.joycnt
  s.visit_u32 serial.joy_recv
  s.visit_u32 serial.joy_trans
  s.visit_u16 serial.joystat

proc visit_dma[S](dma: DMA; s: var S) =
  s.visit_tag GBA_SEC_DMA
  for i in 0 .. 3:
    s.visit_u32    dma.dmasad[i]
    s.visit_u32    dma.dmadad[i]
    s.visit_u32    dma.src[i]
    s.visit_u32    dma.dst[i]
    s.visit_u16    dma.dmacnt_l[i]
    s.visit_bits16 dma.dmacnt_h[i]
    s.visit_u32    dma.latch[i]
  when S is Reader:
    # Arbitration state is always idle at frame boundaries (where states are
    # taken), so it is not serialized — just reset it
    dma.pending = 0
    dma.current_priority = 4

# ---- GPIO + RTC ----

proc visit_gpio[S](gpio: GPIO; s: var S) =
  s.visit_tag GBA_SEC_GPIO
  s.visit_u8   gpio.data
  s.visit_u8   gpio.direction
  s.visit_bool gpio.allow_reads
  let rtc = gpio.rtc
  s.visit_bool rtc.sck
  s.visit_bool rtc.sio
  s.visit_bool rtc.cs
  # Enum, so the value is range-checked on the way in rather than cast blind
  when S is Reader:
    let st = s.read_u8()
    if int(st) > int(high(RtcState)):
      raise newException(StateError, "invalid RTC state in save state")
    rtc.state = RtcState(st)
  else:
    s.write_u8(uint8(ord(rtc.state)))
  s.visit_i32  rtc.reg
  s.visit_i32  rtc.buffer.size
  s.visit_u64  rtc.buffer.value
  s.visit_bool rtc.irq
  s.visit_bool rtc.m24
  s.visit_bool rtc.deterministic
  s.visit_u64  rtc.epoch

# ---- PPU ----

proc visit_ppu[S](ppu: PPU; s: var S) =
  s.visit_tag GBA_SEC_PPU
  s.visit_bits16 ppu.dispcnt
  s.visit_bits16 ppu.dispstat
  s.visit_u16    ppu.vcount
  for i in 0 .. 3:
    s.visit_bits16 ppu.bgcnt[i]
    s.visit_bits16 ppu.bghofs[i]
    s.visit_bits16 ppu.bgvofs[i]
  for bg in 0 .. 1:
    for i in 0 .. 3: s.visit_bits16 ppu.bgaff[bg][i]
    for i in 0 .. 1:
      s.visit_bits32 ppu.bgref[bg][i]
      s.visit_i32    ppu.bgref_int[bg][i]
      s.visit_i32    ppu.mosaic_bgref_int[bg][i]
  s.visit_bits16 ppu.win0h
  s.visit_bits16 ppu.win1h
  s.visit_bits16 ppu.win0v
  s.visit_bits16 ppu.win1v
  s.visit_bits16 ppu.winin
  s.visit_bits16 ppu.winout
  s.visit_bits16 ppu.mosaic
  s.visit_bits16 ppu.bldcnt
  s.visit_bits16 ppu.bldalpha
  s.visit_bits16 ppu.bldy
  s.visit_bytes  ppu.pram
  s.visit_bytes  ppu.vram
  s.visit_bytes  ppu.oam
  s.visit_seq_u16 ppu.framebuffer
  when S is Reader:
    # Per-scanline compositing scratch is recomputed; force a full re-render so
    # the render-skip optimization can't display stale pre-load pixels
    ppu.frame = 0
    ppu.render_dirty = true
    ppu.skip_render = false
    ppu.frame_static = false

# ---- APU ----

proc visit_channel_base[S](ch: SoundChannel; s: var S) =
  s.visit_bool ch.enabled
  s.visit_bool ch.dac_enabled
  s.visit_i32  ch.length_counter
  s.visit_bool ch.length_enable

proc visit_channel_env[S](ch: VolumeEnvelopeChannel; s: var S) =
  visit_channel_base(ch, s)
  s.visit_u8   ch.starting_volume
  s.visit_bool ch.envelope_add_mode
  s.visit_u8   ch.envelope_period
  s.visit_u8   ch.envelope_timer
  s.visit_u8   ch.current_volume
  s.visit_bool ch.envelope_is_updating

proc visit_apu[S](apu: APU; s: var S) =
  s.visit_tag GBA_SEC_APU
  s.visit_bits16 apu.soundcnt_l
  s.visit_bits16 apu.soundcnt_h
  s.visit_bool   apu.sound_enabled
  s.visit_bits16 apu.soundbias
  s.visit_u8     apu.frame_sequencer_stage
  s.visit_bool   apu.first_half_of_length_period
  block:
    let ch = apu.channel1
    visit_channel_env(ch, s)
    s.visit_i32  ch.wave_duty_position
    s.visit_u8   ch.sweep_period
    s.visit_bool ch.negate
    s.visit_u8   ch.shift_ch1
    s.visit_u8   ch.sweep_timer
    s.visit_u16  ch.frequency_shadow
    s.visit_bool ch.sweep_enabled
    s.visit_bool ch.negate_has_been_used
    s.visit_u8   ch.duty
    s.visit_u8   ch.length_load
    s.visit_u16  ch.frequency_ch1
  block:
    let ch = apu.channel2
    visit_channel_env(ch, s)
    s.visit_i32 ch.wave_duty_position
    s.visit_u8  ch.duty
    s.visit_u8  ch.length_load
    s.visit_u16 ch.frequency_ch2
  block:
    let ch = apu.channel3
    visit_channel_base(ch, s)
    s.visit_bytes ch.wave_ram[0]
    s.visit_bytes ch.wave_ram[1]
    s.visit_u8    ch.wave_ram_position
    s.visit_u8    ch.wave_ram_sample_buffer
    s.visit_bool  ch.wave_ram_dimension
    s.visit_u8    ch.wave_ram_bank
    s.visit_u8    ch.length_load_ch3
    s.visit_u8    ch.volume_code
    s.visit_bool  ch.volume_force
    s.visit_u16   ch.frequency_ch3
  block:
    let ch = apu.channel4
    visit_channel_env(ch, s)
    s.visit_u16 ch.lfsr
    s.visit_u8  ch.length_load_ch4
    s.visit_u8  ch.clock_shift
    s.visit_u8  ch.width_mode
    s.visit_u8  ch.divisor_code
  block:
    let dc = apu.dma_channels
    for f in 0 .. 1:
      for i in 0 .. 31: s.visit_i8 dc.fifos[f][i]
      s.visit_i32 dc.positions[f]
      s.visit_i32 dc.sizes[f]
      s.visit_i16 dc.latches[f]
  when S is Reader:
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
    # EEPROM buffers are sized lazily (from the first command's DMA length)
    st.memory = mem
  else:
    if mem.len != st.memory.len:
      raise newException(StateError, "save state backup size mismatch")
    st.memory = mem
  if st of Flash:
    let fl = Flash(st)
    let ft = r.read_u8()
    if int(ft) > int(high(StorageType)):
      raise newException(StateError, "invalid flash type in save state")
    fl.flash_type = StorageType(ft)
    fl.state = cast[set[FlashStateFlag]](r.read_u8())
    fl.bank = r.read_u8()
  elif st of EEPROM:
    let ep = EEPROM(st)
    let sz = r.read_u8()
    ep.eeprom_size = case sz
      of 0'u8: none(EepromSize)
      of 1'u8: some(eeprom4k)
      else:    some(eeprom64k)
    ep.state = cast[set[EepromStateFlag]](r.read_u16())
    ep.buffer.size = int(r.read_i32())
    ep.buffer.value = r.read_u64()
    ep.address = r.read_u32()
    ep.ignored_reads = int(r.read_i32())
    ep.read_bits = int(r.read_i32())
    ep.wrote_bits = int(r.read_i32())
    # busy_until (write-settle window, <=115000 cycles) is not in the format;
    # treat any in-flight programming as settled. States are frame-boundary
    # only, so at worst a ready-poll observes ready ~0.4 frames early.
    ep.busy_until = 0
  # Persist the restored backup memory to the .sav on the next flush
  st.dirty = true

# ---- Top level ----

proc gba_state_payload(gba: GBA): string =
  var w = Writer()
  visit_cpu(gba.cpu, w)
  visit_bus(gba.bus, w)
  w.write_tag(GBA_SEC_SCHED)
  gba.scheduler.save_to(w)
  visit_irq(gba.interrupts, w)
  visit_mmio(gba.mmio, w)
  visit_keypad(gba.keypad, w)
  visit_timer(gba.timer, w)
  visit_serial(gba.serial, w)
  visit_dma(gba.dma, w)
  visit_gpio(gba.bus.gpio, w)
  visit_ppu(gba.ppu, w)
  visit_apu(gba.apu, w)
  save_storage_state(gba.storage, w)   # asymmetric: see the section comment
  w.write_tag(GBA_SEC_END)
  w.buf

proc gba_apply_state(gba: GBA; payload: string) =
  var r = Reader(buf: payload)
  visit_cpu(gba.cpu, r)
  visit_bus(gba.bus, r)
  r.expect_tag(GBA_SEC_SCHED)
  gba.scheduler.load_from(r)
  visit_irq(gba.interrupts, r)
  visit_mmio(gba.mmio, r)
  visit_keypad(gba.keypad, r)
  visit_timer(gba.timer, r)
  visit_serial(gba.serial, r)
  visit_dma(gba.dma, r)
  visit_gpio(gba.bus.gpio, r)
  visit_ppu(gba.ppu, r)
  visit_apu(gba.apu, r)
  load_storage_state(gba.storage, r)   # asymmetric: see the section comment
  r.expect_tag(GBA_SEC_END)
  # irq_line is derived from IE/IF/IME and not serialized; recompute it so a
  # pending-but-untaken IRQ at the save point isn't lost. Same for the
  # WAITCNT-derived bus timing tables.
  gba.interrupts.check_interrupts()
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
  # Hash the first 1 MB to identify the ROM cheaply (every real cart is larger).
  let n = min(gba.cartridge.rom.len, 0x100000)
  fnv1a(toOpenArray(gba.cartridge.rom, 0, n - 1))

proc state_payload*(gba: GBA): string =
  ## Raw serialized state, no header/validation. For trusted in-process uses
  ## (the rewind ring buffer). Frame boundaries only.
  gba.gba_state_payload()

proc apply_state_payload*(gba: GBA; payload: string) =
  ## Apply a raw payload produced by state_payload. Raises StateError on
  ## corrupt input; no rollback — trusted callers only.
  gba.gba_apply_state(payload)

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

proc load_state_bytes*(gba: GBA; data: string): bool =
  ## Validate and apply a full state image. Mirrors load_state's rollback.
  var payload: string
  try:
    payload = parse_state_payload(data, ckGBA, gba.gba_rom_checksum(),
                                  GBA_STATE_ROM_TAG)
  except CatchableError:
    echo "Load state failed: ", getCurrentExceptionMsg()
    return false
  let backup = gba.gba_state_payload()
  try:
    gba.gba_apply_state(payload)
    true
  except CatchableError:
    echo "Load state failed: ", getCurrentExceptionMsg()
    gba.gba_apply_state(backup)
    false

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
  var payload: string
  try:
    payload = read_state_payload(path, ckGBA, gba.gba_rom_checksum(),
                                 GBA_STATE_ROM_TAG)
  except CatchableError:
    echo "Load state failed: ", getCurrentExceptionMsg()
    return false
  let backup = gba.gba_state_payload()
  try:
    gba.gba_apply_state(payload)
    true
  except CatchableError:
    echo "Load state failed: ", getCurrentExceptionMsg()
    gba.gba_apply_state(backup)
    false
