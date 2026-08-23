# DMA implementation (included by gba.nim)

const
  DMA_START_DELAY = 3
  DMA_SRC_MASK = [0x07FFFFFF'u32, 0x0FFFFFFF'u32, 0x0FFFFFFF'u32, 0x0FFFFFFF'u32]
  # DAD keeps 28 bits on every channel; channels 0-2 DROP gamepak-bus
  # destinations at transfer time (run_channel) rather than masking them to
  # 27 bits, which would land them in VRAM (mGBA suite Memory/DMA ±SRAM rows).
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
    result.count[i]    = 0
    result.dmacnt_h[i] = DMACNT()
    result.src[i]     = 0
    result.dst[i]     = 0

proc run_pending*(dma: DMA)

proc request(dma: DMA; channel: int) {.inline.} =
  ## Latch a request; run_pending grants it in priority order.
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
    # Byte stores to CNT_H: an upper-byte store also copies its bit7 into
    # the low byte's bit7, and a low-byte store drops bit7. Halfword/word
    # writes are normal (hardware: gbaedge DMAEDGE/IOBYTE on AGB SP, measured
    # on DMA3, modelled for all channels; docs/hwprobe.md).
    if dma.gba.bus.byte_io_write:
      if (io_addr and 1) == 1:
        let lo = read(dma.dmacnt_h[channel], 0)
        write(dma.dmacnt_h[channel], (lo and 0x7F'u8) or (value and 0x80'u8), 0)
      else:
        write(dma.dmacnt_h[channel], value and 0x7F'u8, 0)
        return
    write(dma.dmacnt_h[channel], value, io_addr and 1)
    if dma.dmacnt_h[channel].enable and not enabled:
      # Addresses are force-aligned to the transfer size (GBATEK, "DMA Transfers").
      let align = if dma.dmacnt_h[channel].xfer_type != 0: not 3'u32 else: not 1'u32
      dma.src[channel] = dma.dmasad[channel] and align
      dma.dst[channel] = dma.dmadad[channel] and align
      dma.count[channel] = dma.dmacnt_l[channel]
      if dma.dmacnt_h[channel].start_timing == 0:  # Immediate
        # Starts DMA_START_DELAY cycles after the enable write; the CPU keeps
        # executing until then (mGBA suite "Trivial DMA"). The event re-checks
        # enable, so no per-channel pending state is needed.
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
  ## DMA3 special timing = video capture: one transfer per line for VCOUNT
  ## 2..161 of the frame in which line 2 found the channel armed, then the
  ## enable bit self-clears at line 162. A channel armed mid-frame waits for
  ## the next frame's line 2 (hardware: gbaedge CAPDMA on AGB SP,
  ## docs/hwprobe.md; the AGS aging cartridge pins the per-line cadence).
  if dma.dmacnt_h[3].enable and dma.dmacnt_h[3].start_timing == 3:
    if vcount == 2:
      dma.video_active = true
    if dma.video_active:
      if vcount >= 2 and vcount < 162:
        # Each line's trigger reloads the internal src from SAD; the
        # gamepak always-increment rule still applies within a line's burst
        # (CAPDMA: a fixed ROM source yields 160 lines of nonzero words).
        let align = if dma.dmacnt_h[3].xfer_type != 0: not 3'u32 else: not 1'u32
        dma.src[3] = dma.dmasad[3] and align
        dma.request(3)
      elif vcount == 162:
        dma.video_active = false
        dma.dmacnt_h[3].enable = false
  else:
    dma.video_active = false

proc trigger_fifo*(dma: DMA; fifo_channel: int) =
  let ch = fifo_channel + 1
  if dma.dmacnt_h[ch].enable and dma.dmacnt_h[ch].start_timing == 3:  # Special
    dma.request(ch)

proc run_channel(dma: DMA; channel: int; nested: bool) =
  let start_timing   = int(dma.dmacnt_h[channel].start_timing)
  let source_control = int(dma.dmacnt_h[channel].source_control)
  let dest_control   = int(dma.dmacnt_h[channel].dest_control)
  var word_size      = 2 shl int(dma.dmacnt_h[channel].xfer_type)  # 2 or 4
  var len            = int(dma.count[channel])
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
  # bits (GBATEK, "DMA Transfers"); SRAM is not affected.
  let src_page = bits_range(dma.src[channel], 24, 27)
  let src_in_rom = src_page >= 0x8 and src_page <= 0xD
  let delta_source = if src_in_rom: word_size
                     else: dma_addr_delta(source_control, word_size)
  let delta_dest   = dma_addr_delta(dest_ctrl,  word_size)

  when defined(pftrace):
    pft_dma = pft_dma or pft_on
    pft("DMA" & $channel & " GRANT sched=" & $dma.gba.scheduler.cycles &
        " busc=" & $dma.gba.bus.cycles & " rfs=" & $dma.gba.bus.rom_free_since &
        " hot=" & $dma.gba.bus.rom_hot & " src=" & toHex(dma.src[channel], 8) &
        " dst=" & toHex(dma.dst[channel], 8) & " len=" & $len & " ws=" & $word_size)

  # The cycle the ROM bus changes hands, before any burst cycles are charged;
  # the prefetch hand-off (bus.rom_access_cycles) counts forward from here.
  dma.gba.bus.dma_grant_now =
    dma.gba.bus.sched.cycles + CycleCount(dma.gba.bus.cycles)
  dma.gba.bus.dma_first_rom = true

  # CPU->DMA bus hand-off cost (mGBA suite DMA timing rows). A channel that
  # preempts another mid-burst pays nothing: the bus never returns to the
  # CPU (AGS aging cartridge DMA priority test).
  if not nested:
    dma.gba.bus.add_cycles(2)

  dma.gba.bus.dma_active = true
  dma.gba.bus.rom_next_addr = 1  # start both burst trackers cold
  dma.gba.bus.rom_next_addr2 = 1

  # Mid-burst event drains only when a higher-priority channel is armed on a
  # hardware trigger; otherwise events dispatch after the whole burst (the
  # timing the mGBA suite rows are calibrated against).
  var preemptible = false
  for ch2 in 0 ..< channel:
    if dma.dmacnt_h[ch2].enable and dma.dmacnt_h[ch2].start_timing != 0:
      preemptible = true
      break

  for _ in 0 ..< len:
    # Preemption point between transfers (a read/write pair is atomic).
    # Draining here dispatches events that came due during the burst;
    # handlers only latch requests, so a higher-priority channel is granted
    # at this drained boundary and runs nested via run_pending while this
    # loop's locals hold our progress.
    if preemptible:
      let bus = dma.gba.bus
      # The PSG waveform deadlines are not in evbuf (gba/apu.nim) but must
      # gate the drain, or scheduler.cycles lags and schedule() anchors early.
      dma.gba.apu.apu_catchup_all()
      if bus.sched.cycles + CycleCount(bus.cycles) >=
         min(bus.sched.next_event, dma.gba.apu.apu_next_step()):
        bus.catch_up()
      if dma.pending != 0:
        dma.run_pending()
    # TODO: deny-list; misses unmapped gaps such as 0x00004000-0x01FFFFFF.
    let src_region = bits_range(dma.src[channel], 24, 27)
    let src_accessible = src_region != 0x0 and src_region != 0x1 and dma.src[channel] < 0x10000000'u32
    # Only DMA3 can write the gamepak bus; channels 0-2 drop such writes
    # (no bus access, no redirect). See DMA_DST_MASK.
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
    # The moved word stays on the data bus for open-bus reads (Bus.dma_open_bus).
    dma.gba.bus.dma_open_bus = dma.latch[channel]
    dma.src[channel] = uint32(int(dma.src[channel]) + delta_source)
    dma.dst[channel] = uint32(int(dma.dst[channel]) + delta_dest)

  if dest_ctrl == 3:  # IncrementReload
    dma.dst[channel] = dma.dmadad[channel]

  if not dma.dmacnt_h[channel].repeat or start_timing == 0:  # not (repeat && not Immediate)
    dma.dmacnt_h[channel].enable = false
  else:
    # Repeat reloads the count from DMACNT_L.
    dma.count[channel] = dma.dmacnt_l[channel]

  if dma.dmacnt_h[channel].irq_enable:
    dma.gba.interrupts.set_interrupt_flag(IRQ_DMA_BIT_BASE + channel)
    dma.gba.interrupts.schedule_interrupt_check(IRQ_SYNC_DELAY)

proc run_pending*(dma: DMA) =
  ## Arbitration pump: grants latched requests in priority order (channel 0
  ## highest). Called with `dispatching` false, from the scheduler after an
  ## event dispatch (no burst running) or from a burst's transfer loop after
  ## its drain (nested preemption). A request for a channel >= the burst in
  ## progress waits for the level that granted that burst.
  while dma.pending != 0:
    let ch = countTrailingZeroBits(dma.pending)
    if ch >= dma.current_priority:
      break  # waits for the equal/higher-priority burst in progress
    dma.pending = dma.pending and not uint8(1 shl ch)
    # A burst between request and grant may have rewritten this channel's CNT_H.
    if not dma.dmacnt_h[ch].enable: continue
    # FIFO requests are level-conditioned on the FIFO, not edge-latched: a
    # timer overflow inside this channel's own burst would otherwise latch a
    # second grant that overfills the FIFO and skips the stream forward
    # (Densetsu no Sutafi 3 lost ~4% of its stream bytes). Assumed; no ROM
    # pins this.
    if (ch == 1 or ch == 2) and dma.dmacnt_h[ch].start_timing == 3:
      if dma.gba.apu.dma_channels.sizes[ch - 1] >= 16: continue
    let saved = dma.current_priority
    dma.current_priority = ch
    dma.run_channel(ch, nested = saved < 4)
    dma.current_priority = saved
    let bus = dma.gba.bus
    # The CPU (or a paused outer burst) resumes with a nonsequential access.
    bus.dma_active = saved < 4
    if saved == 4:
      # The CPU's next instruction still sees the DMA's last word on open-bus
      # reads (cleared in cpu.tick).
      bus.dma_open_bus_armed = true
    when defined(pftrace):
      pft("DMA" & $ch & " END sched=" & $bus.sched.cycles & " busc=" & $bus.cycles &
          " rfs=" & $bus.rom_free_since & " hot=" & $bus.rom_hot)
    bus.rom_next_addr = 1
    bus.rom_next_addr2 = 1
