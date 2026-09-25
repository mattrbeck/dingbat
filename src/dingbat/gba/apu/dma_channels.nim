# DMA sound channels (included by gba.nim)

const DMA_CHANNELS_RANGE_LOW*  = 0xA0'u32
const DMA_CHANNELS_RANGE_HIGH* = 0xA7'u32
const FIFO_MASTER_RESET {.booldefine.} = true
  ## Both FIFOs are held empty while SOUNDCNT_X's master enable is off:
  ## clearing it empties them, writes are dropped (apu `[]=`), and timer
  ## overflows neither play nor request a DMA. alyosha fifo_dma/fifo, test 2:
  ## 24 samples written with the sound off, and the first overflow after
  ## the enable requests a DMA; test 3: the same with the sound cycled off
  ## and on after the writes; without the gate an armed sound DMA refills a
  ## FIFO that cannot fill, every overflow, and the ROM never draws a
  ## verdict. fifo_2's eight rows each start that way (false: 051).
const FIFO_REQ_BEFORE_POP {.booldefine.} = true
  ## A FIFO asks for a refill on its timer's overflow when it held fewer than
  ## 16 bytes before the sample was taken, not after: alyosha fifo_dma/fifo_4
  ## preloads exactly 16 and the first overflow requests nothing, the second
  ## does. (After the pop: fifo_4 reads 111; fifo_3 alone prefers it, by one
  ## cycle -- 174 for 175 -- and it is red either way.)
const FIFO_DMA_REQUEST_DELAY {.intdefine.} = 4
  ## The refill DMA is requested this many cycles after the overflow.
  ## alyosha fifo_dma/fifo_2 reads a timer just after the first refill, for
  ## eight timer reloads: 3 puts the burst before the read in one row (081),
  ## 5 after it in another (051). fifo_4 and fifo_dma_disable_4 read green
  ## from 3 to 5. Bounded: at most one request per overflow per FIFO, and
  ## a grant re-checks the FIFO level (dma.run_pending).

const FIFO_WORD_WRAP {.booldefine.} = true
  ## The FIFO holds eight words, and the eighth written into it leaves it
  ## reading empty (its word count wraps): with the sound on, eight words
  ## stored and TM0 started, the first overflow requests a refill exactly as
  ## it does for an empty FIFO, where four, six or seven words request
  ## nothing (tests/roms/payloads/fifomap.s on an AGB SP; alyosha
  ## fifo_dma/fifo_5 stores eight and reads the burst, fifo_4 stores four).

const FIFO_DMA_WINDOW {.booldefine.} = true
  ## A refill request that lands inside a CPU data access is granted at the
  ## access's end, and internal cycles behind it run under the burst
  ## (defer_fifo_request, gba.nim): tests/roms/dbsuite fifodma on an AGB SP,
  ## an EWRAM load against the first request -- a load in flight costs the
  ## CPU the burst less its internal cycle (and alyosha fifo_dma/fifo_5's
  ## burst, landing in a ROM load, gives its read the console's count).
  ## Knowing where data accesses end takes a sync per access (Bus.sync_bits
  ## bit 4; instruction fetches stay on the fast path), paid from
  ## FIFO_WINDOW_LEAD cycles before a request the next overflow will make
  ## (a timer's overflows are known in advance) to the internal cycles after
  ## its grant, which may run under the burst.
const FIFO_WINDOW_LEAD {.intdefine.} = 16

proc dma_channels_in_range*(address: uint32): bool =
  address >= DMA_CHANNELS_RANGE_LOW and address <= DMA_CHANNELS_RANGE_HIGH

proc new_dma_channels*(gba: GBA): DMAChannels =
  result = DMAChannels(gba: gba)
  for ch in 0..1:
    for i in 0..31:
      result.fifos[ch][i] = 0
    result.positions[ch] = 0
    result.sizes[ch]     = 0
    result.latches[ch]   = 0
    result.hist[ch]      = [0'i16, 0, 0, 0]
    result.last_update_cycle[ch] = 0
    result.inv_period[ch]        = 0.0'f32
  # Cubic FIFO reconstruction defaults ON; off = the raw held latch, which is
  # what the hardware DAC outputs. DINGBAT_FIFO_INTERP=0 forces it off.
  result.fifo_interp = true
  when not defined(test_harness) and not defined(emscripten):
    if getEnv("DINGBAT_FIFO_INTERP") == "0":
      result.fifo_interp = false

proc fifo_reset*(dc: DMAChannels; channel: int) =
  for i in 0..31: dc.fifos[channel][i] = 0
  dc.positions[channel] = 0
  dc.sizes[channel] = 0
  dc.latches[channel] = 0
  dc.hist[channel] = [0'i16, 0, 0, 0]
  dc.inv_period[channel] = 0.0'f32

proc dma_channels_read*(dc: DMAChannels; address: uint32): uint8 =
  dc.gba.bus.read_open_bus_value(address)

proc dma_channels_write*(dc: DMAChannels; address: uint32; value: uint8) =
  let channel = int(bit(address, 2))
  # MP2K HLE provenance (mp2k.nim on_frame): the m4a driver feeds the FIFOs
  # only via DMA1/2 in FIFO timing; bytes arriving any other way mean the game
  # streams its own audio and must not be substituted.
  var tag = 0'u32
  if dc.gba.mp2k != nil:
    let d = dc.gba.dma
    let by_fifo_dma = dc.gba.bus.dma_active and
                      (d.current_priority == 1 or d.current_priority == 2) and
                      d.dmacnt_h[d.current_priority].start_timing == 3
    if not by_fifo_dma:
      inc dc.gba.mp2k.fifo_cpu_bytes
    else:
      tag = d.src[d.current_priority] + ((address - DMA_CHANNELS_RANGE_LOW) and 3'u32)
  when defined(mp2kwav): inc dbgFifoWrites[channel]
  if dc.sizes[channel] < 32:
    dc.tags[channel][(dc.positions[channel] + dc.sizes[channel]) mod 32] = tag
    dc.fifos[channel][(dc.positions[channel] + dc.sizes[channel]) mod 32] = cast[int8](value)
    dc.sizes[channel] += 1
    when FIFO_WORD_WRAP:
      if dc.sizes[channel] == 32: dc.sizes[channel] = 0
  else:
    when defined(mp2kwav): inc dbgFifoDrop[channel]
    log("Writing " & hex_str(value) & " to fifo " & $channel & " but it's already full")

proc push_fifo_sample(dc: DMAChannels; channel: int; sample: int16) {.inline.} =
  ## Record a newly latched FIFO sample for cubic reconstruction; called on
  ## every DAC-advancing timer overflow (including empty-FIFO 0s). The delta
  ## between overflow cycles is the phase denominator: counting 32768 Hz reads
  ## instead degenerates at FIFO rates near the output rate and injects
  ## broadband noise (tools/nbadiff/README.md).
  dc.hist[channel][0] = dc.hist[channel][1]
  dc.hist[channel][1] = dc.hist[channel][2]
  dc.hist[channel][2] = dc.hist[channel][3]
  dc.hist[channel][3] = sample
  let now = int64(dc.gba.scheduler.cycles)
  let delta = now - dc.last_update_cycle[channel]
  if delta > 0 and delta < 1 shl 20:
    dc.inv_period[channel] = 1.0'f32 / float32(delta)
  dc.last_update_cycle[channel] = now

proc timer_overflow*(dc: DMAChannels; timer: int): bool =
  ## Also whether a FIFO this timer drives will ask for a refill at its
  ## next overflow (FIFO_DMA_WINDOW books the window for it).
  when FIFO_MASTER_RESET:
    # With the master enable off both FIFOs are held empty and request no
    # DMA (alyosha fifo_dma/fifo: an armed sound DMA and a running timer
    # with the sound off do not stall the CPU)
    if not dc.gba.apu.sound_enabled: return
  for channel in 0..1:
    let ch_timer = if channel == 0:
      int(dc.gba.apu.soundcnt_h.dma_sound_a_timer)
    else:
      int(dc.gba.apu.soundcnt_h.dma_sound_b_timer)
    if timer == ch_timer:
      let want = dc.sizes[channel] < 16
      if dc.sizes[channel] > 0:
        when defined(mp2kwav):
          inc dbgFifoServed[channel]
          let dtg = dc.tags[channel][dc.positions[channel]]
          if dtg != 0'u32:
            var k = 0
            while k < dbgWatch.len:
              if dbgWatch[k].a == dtg:
                if dbgPassReal[dbgWatch[k].pass][dbgWatch[k].kind] < 0:
                  dbgPassReal[dbgWatch[k].pass][dbgWatch[k].kind] = realDmaCapture.len div 2
                dbgWatch.del(k)
              else:
                inc k
        log("Timer overflow good; channel:" & $channel & ", timer:" & $timer)
        let sample = int16(dc.fifos[channel][dc.positions[channel]]) shl 1
        let tg = dc.tags[channel][dc.positions[channel]]
        if tg != 0'u32:
          for k in 0 .. 3:
            if dc.watch_addr[k] == tg and dc.watch_clock[k] < 0:
              dc.watch_clock[k] = dc.gba.mp2k.apu_clock
              dc.watch_cyc[k] = int64(dc.gba.scheduler.cycles)
        dc.latches[channel] = sample
        dc.push_fifo_sample(channel, sample)
        dc.positions[channel] = (dc.positions[channel] + 1) mod 32
        dc.sizes[channel] -= 1
      else:
        when defined(mp2kwav): inc dbgFifoEmpty[channel]
        log("Timer overflow but empty; channel:" & $channel & ", timer:" & $timer)
        dc.latches[channel] = 0
        dc.push_fifo_sample(channel, 0)
      # Only the FIFO this timer drives asks for a refill (it used to be any
      # FIFO below the mark, on either sound timer)
      if (if FIFO_REQ_BEFORE_POP: want else: dc.sizes[channel] < 16):
        when FIFO_DMA_REQUEST_DELAY > 0:
          dc.gba.scheduler.schedule(FIFO_DMA_REQUEST_DELAY,
                                    if channel == 0: etFifoARequest else: etFifoBRequest)
        else:
          dc.gba.dma.trigger_fifo(channel)
      elif FIFO_DMA_WINDOW and dc.sizes[channel] < 16:
        let d = dc.gba.dma.dmacnt_h[channel + 1]
        if d.enable and d.start_timing == 3: result = true

proc fifo_window_open*(dc: DMAChannels) =
  ## etFifoWindow
  let bus = dc.gba.bus
  when WL_QUIET_EVENTS:
    if (bus.sync_bits and 48) != 16: dc.gba.wl_unsafe = true
  bus.sync_bits = (bus.sync_bits or 16) and not 32'u8

proc fifo_window_book*(dc: DMAChannels; overflow_in: int) =
  ## FIFO_DMA_WINDOW: a refill will be asked for at the overflow
  ## `overflow_in` cycles from now; open the window FIFO_WINDOW_LEAD cycles
  ## ahead of the request. The grant closes it (dma.run_pending).
  when FIFO_DMA_WINDOW:
    let s = dc.gba.scheduler
    let open_in = overflow_in + FIFO_DMA_REQUEST_DELAY - FIFO_WINDOW_LEAD
    if open_in <= 0: dc.fifo_window_open()
    else:
      let cur = s.pending_at(etFifoWindow)
      if s.cycles + CycleCount(open_in) < cur:
        if cur != high(CycleCount): s.clear(etFifoWindow)
        s.schedule(open_in, etFifoWindow)

proc fifo_window_stale*(dc: DMAChannels) =
  ## FIFO_DMA_WINDOW, at an overflow that booked nothing with the window open:
  ## one with no request on its way was not needed (a stopped timer's)
  ## (a request for a FIFO with no sound DMA armed on it books no burst; one
  ## granted is closed by the internal cycles after it, which may run under
  ## the burst)
  when FIFO_DMA_WINDOW:
    let s = dc.gba.scheduler
    if (dc.gba.bus.sync_bits and 32) != 0: return
    for channel in 0..1:
      let d = dc.gba.dma.dmacnt_h[channel + 1]
      if d.enable and d.start_timing == 3 and
         s.has_event(if channel == 0: etFifoARequest else: etFifoBRequest):
        return
    when WL_QUIET_EVENTS:
      if (dc.gba.bus.sync_bits and 48) != 0: dc.gba.wl_unsafe = true
    dc.gba.bus.sync_bits = dc.gba.bus.sync_bits and not 48'u8

proc fifo_window_at_start*(dc: DMAChannels; timer: int; overflow_in: int) =
  ## FIFO_DMA_WINDOW, at `timer`'s start: its first overflow asks for a
  ## refill if a FIFO it drives holds fewer than 16 bytes.
  when FIFO_DMA_WINDOW:
    if not dc.gba.apu.sound_enabled: return
    for channel in 0..1:
      let ch_timer = if channel == 0:
        int(dc.gba.apu.soundcnt_h.dma_sound_a_timer)
      else:
        int(dc.gba.apu.soundcnt_h.dma_sound_b_timer)
      let d = dc.gba.dma.dmacnt_h[channel + 1]
      if ch_timer == timer and d.enable and d.start_timing == 3 and dc.sizes[channel] < 16:
        dc.fifo_window_book(overflow_in)
        return

proc cubic4(y0, y1, y2, y3: int16; mu: float32): int16 {.inline.} =
  ## Four-point cubic through y1 and y2 at fraction mu (Paul Bourke, "Cubic
  ## Interpolation", https://paulbourke.net/miscellaneous/interpolation/).
  ## Interpolating y1/y2 rather than y2/y3 keeps the filter causal at a
  ## ~1.5-sample (~150 us) group delay.
  let
    f0 = float32(y0)
    f1 = float32(y1)
    f2 = float32(y2)
    f3 = float32(y3)
    a  = f3 - f2 - f0 + f1
    b  = f0 - f1 - a
    c  = f2 - f0
    d  = f1
    v  = ((a * mu + b) * mu + c) * mu + d
  int16(clamp(v, -32768.0'f32, 32767.0'f32))

proc dma_channels_get_amplitude*(dc: DMAChannels): tuple[a: int16, b: int16] =
  ## Once per 32768 Hz output sample: the cubic-interpolated FIFO value at the
  ## current phase between timer updates, or the raw held latch.
  if not dc.fifo_interp:
    return (dc.latches[0], dc.latches[1])
  var res: array[2, int16]
  let now = int64(dc.gba.scheduler.cycles)
  for ch in 0..1:
    if dc.inv_period[ch] == 0.0'f32:
      # No period measured yet: hold the latch.
      res[ch] = dc.latches[ch]
    else:
      let mu = clamp(float32(now - dc.last_update_cycle[ch]) *
                     dc.inv_period[ch], 0.0'f32, 1.0'f32)
      res[ch] = cubic4(dc.hist[ch][0], dc.hist[ch][1],
                            dc.hist[ch][2], dc.hist[ch][3], mu)
  (res[0], res[1])
