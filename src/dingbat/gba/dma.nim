# DMA implementation (included by gba.nim)

const DMA_PREEMPT_AFTER_READ {.booldefine.} = true
  ## A higher-priority request preempts a burst between a transfer's read and
  ## its write, and only there: not between one transfer's write and the
  ## next one's read (alyosha DMA_pause_timing_*: an H-blank DMA0 landing on
  ## an immediate DMA1's read is granted before its write, one landing on
  ## its write waits for the next read). False (between transfers, as
  ## before) reds _mid_1 and _mid_2; both points reds _mid_2; neither reds
  ## _mid_1 and _end_1.._end_3.
const DMA_STALL_FROM_CPU_STOP {.booldefine.} = true
const DMA_IRQ_FROM_BUS_END {.booldefine.} = true
  ## A burst's end-of-transfer interrupt is recognised IRQ_SYNC_DELAY cycles
  ## after the burst lets go of the bus, even when the CPU ran internal
  ## cycles under it (tests/roms/payloads/dmairq.s on an AGB SP: DMA3, 1 to
  ## 64 words, the CPU polling a flag -- the load's internal cycle under the
  ## burst -- takes the interrupt one cycle and one instruction later than
  ## a check booked from the CPU's clock gives; with NOPs, where nothing
  ## overlaps, the two agree).
const DMA_ROM_BOUNDARY_HOLD {.booldefine.} = true
  ## A gamepak ROM source whose address does not move (fixed or decrement
  ## control; the data still comes from successive addresses) and sits on
  ## the last unit before a 0x20000 boundary is read nonsequentially on
  ## every transfer: the burst decides N or S from its own address, and
  ## that address is always next to the boundary (alyosha DMA/readme.txt).
  ## DMA_ROM_Fixed, 32 words from 0x0801FFFC, reads 62 cycles long without
  ## it (31 S reads that are N); applied to every non-moving ROM source,
  ## DMA_pause_timing_ROM_to_IWRAM goes red.
const DMA_START_DELAY {.intdefine.} = (if IMM_IDLE_GRANT: 2 else: 3)
const
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
        # Requests the bus DMA_START_DELAY cycles after the enable write; the
        # CPU keeps executing until then, and until the third cycle unless it
        # is idle (IMM_IDLE_GRANT; mGBA suite "Trivial DMA"), or later while
        # a CPU access it lands in finishes (IMM_ACCESS_WAIT). Each channel
        # requests at its own time (imm_due, request_immediate).
        let due = dma.gba.scheduler.cycles + CycleCount(dma.gba.bus.cycles) +
                  CycleCount(DMA_START_DELAY)
        dma.imm_due[channel] = due
        when IMM_IDLE_GRANT:
          # Another channel armed a moment earlier keeps its own request.
          if (dma.gba.bus.sync_bits and 1) == 0 or dma.gba.bus.imm_at < due - CycleCount(DMA_START_DELAY):
            dma.gba.bus.imm_at = due
        dma.gba.bus.sync_bits = dma.gba.bus.sync_bits or 1
        dma.gba.scheduler.schedule(DMA_START_DELAY, etDMA)
  else:
    echo "Unmapped DMA write addr: ", hex_str(uint8(io_addr)), " val: ", value

proc request_immediate*(dma: DMA; reschedule = false) =
  ## Requests the armed immediate channels whose DMA_START_DELAY is up: one
  ## armed after them requests at its own time (tests/roms/payloads/tmrdma.s
  ## on an AGB SP: DMA1 armed, DMA0 armed by the next store, and DMA1 still
  ## runs first). `reschedule`: the caller cleared the pending etDMA events.
  let now = dma.gba.scheduler.cycles + CycleCount(dma.gba.bus.cycles)
  var later = CycleCount(0)
  var waiting = false
  for channel in 0..3:
    if dma.dmacnt_h[channel].enable and dma.dmacnt_h[channel].start_timing == 0:
      if dma.imm_due[channel] <= now:
        dma.request(channel)
      elif not waiting or dma.imm_due[channel] < later:
        later = dma.imm_due[channel]
        waiting = true
  if waiting:
    when IMM_IDLE_GRANT: dma.gba.bus.imm_at = later
    if reschedule:
      dma.gba.scheduler.schedule(int(later - dma.gba.scheduler.cycles), etDMA)
  else:
    dma.gba.bus.sync_bits = dma.gba.bus.sync_bits and not 1'u8

proc chain_next(dma: DMA; channel: int): bool =
  ## DMA_CHAIN: at the end of `channel`'s burst, request every armed
  ## immediate channel whose request has come due under it.
  let bus = dma.gba.bus
  let now = bus.sched.cycles + CycleCount(bus.cycles)
  var waiting = false
  var later = CycleCount(0)
  for ch in 0..3:
    if ch != channel and dma.dmacnt_h[ch].enable and dma.dmacnt_h[ch].start_timing == 0:
      if dma.imm_due[ch] <= now:
        dma.request(ch)
        result = true
      elif not waiting or dma.imm_due[ch] < later:
        waiting = true
        later = dma.imm_due[ch]
  if result:
    dma.chained = true
    # Their etDMA events are spent; keep one for a channel still to come.
    bus.sched.clear(etDMA)
    bus.sync_bits = bus.sync_bits and not 4'u8
    bus.imm_post = false
    if waiting:
      when IMM_IDLE_GRANT: bus.imm_at = later
      bus.sched.schedule(int(later - bus.sched.cycles), etDMA)
    else:
      bus.sync_bits = bus.sync_bits and not 1'u8

proc armed*(dma: DMA; timing: int): bool =
  for channel in 0..3:
    if dma.dmacnt_h[channel].enable and int(dma.dmacnt_h[channel].start_timing) == timing:
      return true

proc close_access_window(dma: DMA) {.inline.} =
  # Not yet: the burst this request starts, and the internal cycles that may
  # run under it, still need the window. The next opcode fetch closes it.
  if (dma.gba.bus.sync_bits and 2) != 0: dma.gba.bus.window_closing = true

proc trigger_hdma*(dma: DMA) =
  # Line 159's window stays open for the V-blank DMA behind it.
  if not (dma.gba.ppu.vcount == 159 and dma.armed(1)): dma.close_access_window()
  for channel in 0..3:
    if dma.dmacnt_h[channel].enable and dma.dmacnt_h[channel].start_timing == 2:  # HBlank
      dma.request(channel)

proc trigger_vdma*(dma: DMA) =
  dma.close_access_window()
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
  when defined(dmacount):
    if start_timing == 2: hdma_grants[channel] += 1
  when defined(hdmalog):
    if start_timing == 2:
      stderr.writeLine("HDMA ch" & $channel & " vcount=" & $dma.gba.ppu.vcount &
        " cyc=" & $dma.gba.bus.sched.cycles & " pc=" & toHex(dma.gba.cpu.r[15], 8))
  # Handlers and catch-up run an event at its own cycle, so this is the
  # cycle the burst was requested at (read_open_bus_value).
  dma.gba.bus.dma_request_at =
    if dma.gba.bus.dma_deferred: dma.gba.bus.dma_deferred_from
    else: dma.gba.bus.sched.cycles
  dma.gba.bus.dma_deferred = false
  dma.gba.bus.dma_has_run = true
  when DMA_READS_CPU_BUS:
    # A load that began after the request came second: the burst went first
    dma.gba.bus.dma_bus_req =
      if start_timing == 0 and IMM_IDLE_GRANT: min(dma.gba.bus.dma_request_at, dma.gba.bus.imm_at)
      else: dma.gba.bus.dma_request_at
    # and one the CPU has moved on from (its internal cycle is the most a
    # load leaves between its data and the next fetch) is not on the bus
    if not nested and dma.gba.bus.load_size != 0 and
       dma.gba.bus.sched.cycles + CycleCount(dma.gba.bus.cycles) > dma.gba.bus.load_end + 1:
      dma.gba.bus.load_size = 0
  # The prefetch hand-off phase (bus.rom_access_cycles) was pinned with two
  # lead cycles; keep its origin where those rows put it.
  dma.gba.bus.dma_grant_now =
    dma.gba.bus.sched.cycles + CycleCount(dma.gba.bus.cycles) - CycleCount(2 - DMA_LEAD_CYCLES)
  dma.gba.bus.dma_first_rom = true

  # CPU->DMA bus hand-off cost (mGBA suite DMA timing rows). A channel that
  # preempts another mid-burst pays nothing: the bus never returns to the
  # CPU (AGS aging cartridge DMA priority test).
  if not nested:
    if dma.chained: dma.chained = false
    else: dma.gba.bus.add_cycles(DMA_LEAD_CYCLES)

  dma.gba.bus.dma_active = true
  when DMA_READS_CPU_BUS:
    # A nested burst finds the outer one's word on the bus
    if not nested: dma.gba.bus.dma_bus_fresh = true
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

  template preempt_point() =
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

  when DMA_READS_CPU_BUS:
    let touches_iwram = bits_range(dma.src[channel], 24, 27) == 3 or
                        bits_range(dma.dst[channel], 24, 27) == 3
  let rom_src_held = DMA_ROM_BOUNDARY_HOLD and src_in_rom and
                     (source_control == 1 or source_control == 2) and
                     (dma.src[channel] and 0x1FFFF'u32) >= uint32(0x20000 - word_size)
  var first = true
  for _ in 0 ..< len:
    when not DMA_PREEMPT_AFTER_READ: preempt_point()
    if rom_src_held and not first:
      let bus = dma.gba.bus
      if bus.rom_next_addr == dma.src[channel]: bus.rom_next_addr = 1
      elif bus.rom_next_addr2 == dma.src[channel]: bus.rom_next_addr2 = 1
    first = false
    # TODO: deny-list; misses unmapped gaps such as 0x00004000-0x01FFFFFF.
    let src_region = bits_range(dma.src[channel], 24, 27)
    let src_accessible = src_region != 0x0 and src_region != 0x1 and dma.src[channel] < 0x10000000'u32
    # Only DMA3 can write the gamepak bus; channels 0-2 drop such writes
    # (no bus access, no redirect). See DMA_DST_MASK.
    let dst_writable = channel == 3 or dma.dst[channel] < 0x08000000'u32
    # A source the DMA cannot read (BIOS, unmapped) still costs its read
    # cycle; the latch just keeps its value. alyosha Interactions: with 0,
    # Internal_Cycle_DMA_Mul, _IRQ_br1_IWRAM and _IRQ_nop_IWRAM fail; with 2,
    # _DMA_Mul and _IRQ_Br_pre_tim.
    if not src_accessible: dma.gba.bus.add_cycles(1)
    if word_size == 4:
      if src_accessible:
        dma.latch[channel] = dma.gba.bus.read_word(dma.src[channel])
        if dma.gba.bus.sd_tw_active and start_timing == 3:
          # a sound FIFO DMA during an HLE SoundDriverMain pass (bus.nim)
          dma.latch[channel] = dma.gba.bus.sd_tw_word(dma.src[channel], dma.latch[channel])
      when DMA_PREEMPT_AFTER_READ: preempt_point()
      if dst_writable:
        dma.gba.bus.write_word(dma.dst[channel], dma.latch[channel])
    else:
      if src_accessible:
        let half = uint32(dma.gba.bus.read_half(dma.src[channel]))
        dma.latch[channel] = half or (half shl 16)
      when DMA_PREEMPT_AFTER_READ: preempt_point()
      if dst_writable:
        dma.gba.bus.write_half(dma.dst[channel], uint16(dma.latch[channel]))
    # The moved word stays on the data bus for open-bus reads (Bus.dma_open_bus).
    dma.gba.bus.dma_open_bus = dma.latch[channel]
    when DMA_READS_CPU_BUS:
      dma.gba.bus.dma_bus_fresh = false
      if touches_iwram: dma.gba.bus.iwram_latch = dma.latch[channel]
    dma.src[channel] = uint32(int(dma.src[channel]) + delta_source)
    dma.dst[channel] = uint32(int(dma.dst[channel]) + delta_dest)

  if not nested and DMA_LEAD_CYCLES < 2:
    if not (DMA_CHAIN and dma.chain_next(channel)):
      dma.gba.bus.add_cycles(2 - DMA_LEAD_CYCLES)   # the hand-back

  if start_timing == 3 and (channel == 1 or channel == 2):
    dma.fifo_xfer_cycle[channel] = int64(dma.gba.scheduler.cycles)

  if dest_ctrl == 3:  # IncrementReload
    dma.dst[channel] = dma.dmadad[channel]

  if not dma.dmacnt_h[channel].repeat or start_timing == 0:  # not (repeat && not Immediate)
    dma.dmacnt_h[channel].enable = false
  else:
    # Repeat reloads the count from DMACNT_L.
    dma.count[channel] = dma.dmacnt_l[channel]

  if dma.dmacnt_h[channel].irq_enable:
    dma.gba.interrupts.set_interrupt_flag(IRQ_DMA_BIT_BASE + channel)
    when DMA_IRQ_FROM_BUS_END:
      # run_pending books the check from where the burst let go of the bus
      # when the CPU was running under it; anything else books it here.
      if nested or dma.gba.cpu.halted:
        dma.gba.interrupts.schedule_interrupt_check(IRQ_SYNC_DELAY)
      else:
        dma.irq_after_burst = true
    else:
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
    let bus = dma.gba.bus
    let granted_at = bus.sched.cycles + CycleCount(bus.cycles)
    when DMA_KEEPS_PREFETCH:
      if saved == 4: bus.rom_cool()
      let cpu_stream = bus.rom_next_addr
      let cpu_free = bus.rom_free_since
    dma.run_channel(ch, nested = saved < 4)
    dma.current_priority = saved
    when DMA_STALLS_IRQ_SYNC:
      # The CPU's interrupt synchroniser runs on the CPU's clock, and that
      # stops while a DMA has the bus: an interrupt raised but not yet
      # recognised when the burst began is recognised that much later.
      # tests/roms/payloads/breakram.s, AGB SP: a running CPU takes an H-blank
      # interrupt exactly four cycles later when a one-word H-blank DMA
      # (requested two cycles after the same flag) is armed than when it is
      # not. A wall-clock delay loses one cycle to it, not four.
      # A halted CPU has no clock to stop; its wake is cpu.nim's business.
      if saved == 4 and not dma.gba.cpu.halted:
        # where the burst let go of the bus, before any cycles the CPU ran
        # under it are taken back out of the clock below
        let burst_end = bus.sched.cycles + CycleCount(bus.cycles)
        var held = burst_end - granted_at
        # When the CPU stopped and started again, if not as the burst did
        var cpu_back = CycleCount(0)
        var cpu_ran = false
        when DMA_ACCESS_WINDOW:
          if (bus.sync_bits and 2) != 0:
            if bus.idle_until > granted_at:
              # Granted inside a run of internal cycles: the rest of them ran
              # under the burst (bus.idle_window).
              let free = min(held, bus.idle_until - granted_at)
              bus.cycles -= int(free)
              held -= free
              bus.dma_held = 0
            else:
              bus.dma_held = int(held)
            bus.dma_end_at = bus.sched.cycles + CycleCount(bus.cycles)
          elif IMM_IDLE_GRANT and dma.dmacnt_h[ch].start_timing == 0 and
               bus.imm_idle_from <= granted_at and granted_at < bus.imm_idle_until:
            # An immediate burst granted inside internal cycles: they ran
            # under it, and the CPU was stopped only from their end.
            let free = min(held, bus.imm_idle_until - granted_at)
            cpu_back = bus.sched.cycles + CycleCount(bus.cycles)
            cpu_ran = true
            bus.cycles -= int(free)
            held -= free
        let intr = dma.gba.interrupts
        # And one raised under the burst counts from its end (raise_synced).
        intr.stall_to = if cpu_ran: cpu_back else: bus.sched.cycles + CycleCount(bus.cycles)
        intr.stall_from = intr.stall_to - held
        # A recognition due before the CPU stopped -- inside internal cycles
        # it ran under the burst -- is not held back
        # (tests/roms/payloads/dmamulirq.s on an AGB SP: a timer interrupt
        # raised in the multiply the burst was granted in, due before its
        # last internal cycle, is taken after that multiply).
        let stall_start = if DMA_STALL_FROM_CPU_STOP: intr.stall_from else: granted_at
        intr.stall_pushed = bus.sched.delay_pending(etInterrupts, stall_start, held)
        if intr.pipe_raised != 0 and intr.pipe_due > stall_start:
          intr.pipe_due += held
        when DMA_IRQ_FROM_BUS_END:
          if dma.irq_after_burst:
            dma.irq_after_burst = false
            let ahead = if burst_end > bus.sched.cycles: int(burst_end - bus.sched.cycles) else: 0
            intr.schedule_interrupt_check(ahead + IRQ_SYNC_DELAY)
    when DMA_IRQ_FROM_BUS_END:
      if dma.irq_after_burst:
        dma.irq_after_burst = false
        dma.gba.interrupts.schedule_interrupt_check(IRQ_SYNC_DELAY)
    # The CPU (or a paused outer burst) resumes with a nonsequential access.
    bus.dma_active = saved < 4
    when defined(pftrace):
      pft("DMA" & $ch & " END sched=" & $bus.sched.cycles & " busc=" & $bus.cycles &
          " rfs=" & $bus.rom_free_since & " hot=" & $bus.rom_hot)
    bus.rom_next_addr = 1
    bus.rom_next_addr2 = 1
    when DMA_KEEPS_PREFETCH:
      if saved == 4 and bus.prefetch_on and bus.dma_first_rom and cpu_stream != 1:
        bus.rom_next_addr = cpu_stream
        bus.rom_free_since = cpu_free
