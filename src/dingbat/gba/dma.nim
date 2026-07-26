# DMA implementation (included by gba.nim)

const
  DMA_START_DELAY = 3
  DMA_SRC_MASK = [0x07FFFFFF'u32, 0x0FFFFFFF'u32, 0x0FFFFFFF'u32, 0x0FFFFFFF'u32]
  # DAD keeps all 28 bits on every channel. Channels 0-2 cannot drive the
  # gamepak bus as a destination: such writes are DROPPED at transfer time
  # (see run_channel), NOT redirected to the 27-bit-masked internal address.
  # Evidence (mGBA suite, hardware-captured expected values): the Memory
  # sub-suite's testStoreSRAM does DMA0/1/2 pattern writes to 0x0E000000;
  # a 27-bit mask would land them at VRAM 0x06000000 (BG1 screen base),
  # yet the DMA sub-suite's "0 Imm/HBl W -SRAM" and "R+0x10" rows later
  # observe 0x00000000 there via DMA0's genuinely-27-bit SAD (masked reads
  # DO hit VRAM: the passing "+SRAM" rows read live text-map data).
  DMA_DST_MASK = [0x0FFFFFFF'u32, 0x0FFFFFFF'u32, 0x0FFFFFFF'u32, 0x0FFFFFFF'u32]
  DMA_LEN_MASK = [0x3FFF'u16,     0x3FFF'u16,     0x3FFF'u16,     0xFFFF'u16    ]

proc dma_addr_delta(ctrl: int; word_size: int): int =
  # ctrl: 0=Increment, 1=Decrement, 2=Fixed, 3=IncrementReload
  case ctrl
  of 0, 3: word_size    # Increment / IncrementReload
  of 1:   -word_size    # Decrement
  else:    0            # Fixed

proc new_dma*(gba: GBA): DMA =
  result = DMA(gba: gba, current_priority: 4)
  for i in 0..3:
    result.dmasad[i]  = 0
    result.dmadad[i]  = 0
    result.dmacnt_l[i] = 0
    result.dmacnt_h[i] = DMACNT()
    result.src[i]     = 0
    result.dst[i]     = 0

proc run_pending*(dma: DMA)

proc request(dma: DMA; channel: int) {.inline.} =
  ## Latch a transfer request; run_pending (the scheduler's post-dispatch
  ## pump) grants it in priority order.
  dma.pending = dma.pending or uint8(1 shl channel)
  dma.gba.scheduler.pump_requested = true

proc `[]`*(dma: DMA; io_addr: uint32): uint8 =
  let channel = int((io_addr - 0xB0'u32) div 12)
  let reg     = int((io_addr - 0xB0'u32) mod 12)
  case reg
  of 8, 9: 0'u8  # dmacnt_l is write-only
  of 10: read(dma.dmacnt_h[channel], 0) and 0xE0'u8  # bits 0-4 not readable
  of 11:  # game_pak (bit 11) not readable for DMA0-2
    let mask = if channel < 3: 0xF7'u8 else: 0xFF'u8
    read(dma.dmacnt_h[channel], 1) and mask
  else: dma.gba.bus.read_open_bus_value(io_addr)

proc write_reg_byte(reg: var uint32; byte_idx: int; value: uint8; mask: uint32) {.inline.} =
  let shift = 8 * byte_idx
  let m = 0xFF'u32 shl shift
  reg = ((reg and not m) or (uint32(value) shl shift)) and mask

proc write_reg_byte16(reg: var uint16; byte_idx: int; value: uint8; mask: uint16) {.inline.} =
  let shift = 8 * byte_idx
  let m = 0xFF'u16 shl shift
  reg = ((reg and not m) or (uint16(value) shl shift)) and mask

proc `[]=`*(dma: DMA; io_addr: uint32; value: uint8) =
  let channel = int((io_addr - 0xB0'u32) div 12)
  let reg     = int((io_addr - 0xB0'u32) mod 12)
  case reg
  of 0, 1, 2, 3:  # dmasad
    write_reg_byte(dma.dmasad[channel], reg, value, DMA_SRC_MASK[channel])
  of 4, 5, 6, 7:  # dmadad
    write_reg_byte(dma.dmadad[channel], reg - 4, value, DMA_DST_MASK[channel])
  of 8, 9:  # dmacnt_l
    write_reg_byte16(dma.dmacnt_l[channel], reg - 8, value, DMA_LEN_MASK[channel])
  of 10, 11:  # dmacnt_h
    let enabled = dma.dmacnt_h[channel].enable
    write(dma.dmacnt_h[channel], value, io_addr and 1)
    if dma.dmacnt_h[channel].enable and not enabled:
      # Hardware force-aligns DMA addresses to the transfer size
      let align = if dma.dmacnt_h[channel].xfer_type != 0: not 3'u32 else: not 1'u32
      dma.src[channel] = dma.dmasad[channel] and align
      dma.dst[channel] = dma.dmadad[channel] and align
      if dma.dmacnt_h[channel].start_timing == 0:  # Immediate
        # Hardware starts an immediate DMA ~3 cycles after the enable write;
        # the CPU keeps executing until then (mGBA suite "Trivial DMA").
        # The event handler re-checks enable, so no pending state is needed:
        # an immediate DMA always clears its enable bit when it runs.
        dma.gba.bus.dma_pending = true
        dma.gba.scheduler.schedule(DMA_START_DELAY, etDMA)
  else:
    echo "Unmapped DMA write addr: ", hex_str(uint8(io_addr)), " val: ", value

proc request_immediate*(dma: DMA) =
  dma.gba.bus.dma_pending = false
  for channel in 0..3:
    if dma.dmacnt_h[channel].enable and dma.dmacnt_h[channel].start_timing == 0:
      dma.request(channel)

proc trigger_hdma*(dma: DMA) =
  for channel in 0..3:
    if dma.dmacnt_h[channel].enable and dma.dmacnt_h[channel].start_timing == 2:  # HBlank
      dma.request(channel)

proc trigger_vdma*(dma: DMA) =
  for channel in 0..3:
    if dma.dmacnt_h[channel].enable and dma.dmacnt_h[channel].start_timing == 1:  # VBlank
      dma.request(channel)

proc trigger_video_capture*(dma: DMA; vcount: uint16) =
  ## DMA3 special timing = video capture: one transfer per scanline for
  ## VCOUNT 2..161, then the channel disables itself at line 162. The AGS
  ## aging cartridge verifies this by capturing VCOUNT itself each line.
  if dma.dmacnt_h[3].enable and dma.dmacnt_h[3].start_timing == 3:
    if vcount >= 2 and vcount < 162:
      dma.request(3)
    elif vcount == 162:
      dma.dmacnt_h[3].enable = false

proc trigger_fifo*(dma: DMA; fifo_channel: int) =
  let ch = fifo_channel + 1
  if dma.dmacnt_h[ch].enable and dma.dmacnt_h[ch].start_timing == 3:  # Special
    dma.request(ch)

proc run_channel(dma: DMA; channel: int; nested: bool) =
  let start_timing   = int(dma.dmacnt_h[channel].start_timing)
  let source_control = int(dma.dmacnt_h[channel].source_control)
  let dest_control   = int(dma.dmacnt_h[channel].dest_control)
  var word_size      = 2 shl int(dma.dmacnt_h[channel].xfer_type)  # 2 or 4
  var len            = int(dma.dmacnt_l[channel])
  if len == 0:
    len = int(DMA_LEN_MASK[channel]) + 1
  var dest_ctrl      = dest_control

  if source_control == 3:  # IncrementReload - prohibited
    echo "Prohibited source address control"

  if start_timing == 3:  # Special
    if channel == 1 or channel == 2:  # FIFO
      len = 4
      word_size = 4
      dest_ctrl = 2  # Fixed
    elif channel == 3:
      discard  # video capture: programmed length/size, one burst per line
    else:
      echo "Prohibited special dma"

  # Gamepak ROM sources always increment regardless of the source control
  # bits (SRAM is not affected)
  let src_page = bits_range(dma.src[channel], 24, 27)
  let src_in_rom = src_page >= 0x8 and src_page <= 0xD
  let delta_source = if src_in_rom: word_size
                     else: dma_addr_delta(source_control, word_size)
  let delta_dest   = dma_addr_delta(dest_ctrl,  word_size)

  # DMA internal cycles for the CPU->DMA bus handoff (calibrated against the
  # mGBA suite DMA timing tests; ROM-to-ROM needs no extra I cycles once its
  # write is sequential-timed). A channel that preempts another mid-burst
  # pays nothing: the bus never returns to the CPU, and the AGS aging
  # cartridge's DMA priority test verifies the switch is seamless (its
  # timer-capture cadence must continue exactly across both channel
  # boundaries).
  if not nested:
    dma.gba.bus.add_cycles(2)

  dma.gba.bus.dma_active = true
  dma.gba.bus.rom_next_addr = 1  # start both burst trackers cold
  dma.gba.bus.rom_next_addr2 = 1

  # Preemption is only possible while a higher-priority channel is armed on
  # a hardware trigger (hblank/vblank/special). Only then is the burst run
  # with mid-burst event drains; otherwise events keep dispatching after the
  # burst as a whole (identical to the pre-preemption behavior, which the
  # mGBA suite timing baselines are calibrated against).
  var preemptible = false
  for ch2 in 0 ..< channel:
    if dma.dmacnt_h[ch2].enable and dma.dmacnt_h[ch2].start_timing != 0:
      preemptible = true
      break

  for _ in 0 ..< len:
    # Preemption point, checked between transfers (a transfer is atomic on
    # hardware: its read/write pair completes before the bus changes hands).
    # Drain the accumulated stall cycles so any scheduler event that came due
    # during the burst dispatches (we run outside `dispatching`, so the drain
    # is safe). Handlers only latch DMA requests — the pump defers while
    # dma_active — so a higher-priority request is granted HERE, at the
    # fully-drained transfer boundary, not at the event's own (earlier)
    # cycle. Recursion via run_pending implements pause/resume: this loop's
    # locals hold our progress while the higher-priority burst runs.
    if preemptible:
      let bus = dma.gba.bus
      # The PSG's waveform deadlines are events in all but name (gba/apu.nim),
      # so they gate this drain exactly as they did when they sat in evbuf —
      # without them the drain fires less often, scheduler.cycles lags the
      # burst's true position, and anything the burst reaches that calls
      # scheduler.schedule anchors its delay early.
      dma.gba.apu.apu_catchup_all()
      if bus.sched.cycles + CycleCount(bus.cycles) >=
         min(bus.sched.next_event, dma.gba.apu.apu_next_step()):
        bus.catch_up()
      if dma.pending != 0:
        dma.run_pending()
    # TODO: This accessibility check is a deny-list and may miss unmapped gaps
    # (e.g. 0x00004000-0x01FFFFFF). Should be replaced with an allow-list of
    # known-valid regions (0x2-0x7, 0x8-0xD, 0xE-0xF).
    let src_region = bits_range(dma.src[channel], 24, 27)
    let src_accessible = src_region != 0x0 and src_region != 0x1 and dma.src[channel] < 0x10000000'u32
    # Only DMA3 can write to the gamepak bus (pages 8-F); channels 0-2 drop
    # such writes entirely (no bus access, no redirect). See DMA_DST_MASK.
    let dst_writable = channel == 3 or dma.dst[channel] < 0x08000000'u32
    if word_size == 4:
      if src_accessible:
        dma.latch[channel] = dma.gba.bus.read_word(dma.src[channel])
      if dst_writable:
        dma.gba.bus.write_word(dma.dst[channel], dma.latch[channel])
    else:
      if src_accessible:
        let half = uint32(dma.gba.bus.read_half(dma.src[channel]))
        dma.latch[channel] = half or (half shl 16)
      if dst_writable:
        dma.gba.bus.write_half(dma.dst[channel], uint16(dma.latch[channel]))
    # The moved word stays latched on the data bus (open-bus reads see it
    # until the CPU's own activity replaces it — see Bus.dma_open_bus)
    dma.gba.bus.dma_open_bus = dma.latch[channel]
    dma.src[channel] = uint32(int(dma.src[channel]) + delta_source)
    dma.dst[channel] = uint32(int(dma.dst[channel]) + delta_dest)

  if dest_ctrl == 3:  # IncrementReload
    dma.dst[channel] = dma.dmadad[channel]

  if not dma.dmacnt_h[channel].repeat or start_timing == 0:  # not (repeat && not Immediate)
    dma.dmacnt_h[channel].enable = false

  if dma.dmacnt_h[channel].irq_enable:
    dma.gba.interrupts.set_interrupt_flag(IRQ_DMA_BIT_BASE + channel)
    dma.gba.interrupts.schedule_interrupt_check(IRQ_SYNC_DELAY)

proc run_pending*(dma: DMA) =
  ## DMA arbitration pump: grants latched requests strictly in priority order
  ## (channel 0 highest). Invoked from two places, always with `dispatching`
  ## false so bursts can advance the clock and dispatch further events:
  ## - the scheduler, after each event dispatch, when no burst is running
  ##   (bus.dma_active gates this so mid-burst grants happen below instead);
  ## - a running burst's transfer loop, right after its drain, so a
  ##   higher-priority request is granted at the fully-drained transfer
  ##   boundary and runs nested to completion (preemption; the outer loop's
  ##   locals hold its progress).
  ## A request for a channel numbered >= the burst in progress stays latched
  ## until the run_pending level that granted that burst loops back around.
  while dma.pending != 0:
    let ch = countTrailingZeroBits(dma.pending)
    if ch >= dma.current_priority:
      break  # waits for the equal/higher-priority burst in progress
    dma.pending = dma.pending and not uint8(1 shl ch)
    # Re-check enable: a burst that ran between request and grant may have
    # written this channel's control register
    if not dma.dmacnt_h[ch].enable: continue
    # Sound FIFO DMA requests are LEVEL-conditioned on the FIFO state, not
    # edge-latched: a timer overflow that lands inside this channel's own
    # in-flight burst (the drain dispatches at a transfer boundary while the
    # refill is still short of 16 bytes) would latch a second request that
    # survives the burst — and the extra grant then pushes 16 bytes into an
    # almost-full FIFO, dropping most of them, i.e. the audio stream skips
    # forward. Real hardware deasserts the request once the FIFO is refilled,
    # so re-check the level at grant time. (Observed: ~2% of drains at
    # 21 kHz vintages — Densetsu no Sutafi 3 lost ~4% of its stream bytes to
    # these skips, splattering broadband noise over the real FIFO audio.)
    if (ch == 1 or ch == 2) and dma.dmacnt_h[ch].start_timing == 3:
      if dma.gba.apu.dma_channels.sizes[ch - 1] >= 16: continue
    let saved = dma.current_priority
    dma.current_priority = ch
    dma.run_channel(ch, nested = saved < 4)
    dma.current_priority = saved
    let bus = dma.gba.bus
    # The bus changed masters: the CPU (or a paused outer DMA burst)
    # continues with a nonsequential access
    bus.dma_active = saved < 4
    if saved == 4:
      # Bus handed back to the CPU: the first instruction it executes still
      # sees the DMA's last word on open-bus reads (cleared in cpu.tick)
      bus.dma_open_bus_armed = true
    bus.rom_next_addr = 1
    bus.rom_next_addr2 = 1
