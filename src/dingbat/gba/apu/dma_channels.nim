# DMA sound channels (included by gba.nim)

const DMA_CHANNELS_RANGE_LOW*  = 0xA0'u32
const DMA_CHANNELS_RANGE_HIGH* = 0xA7'u32
const FIFO_MASTER_RESET {.booldefine.} = true
  ## Both FIFOs are held empty while SOUNDCNT_X's master enable is off:
  ## clearing it empties them, writes are dropped (apu `[]=`), and timer
  ## overflows neither play nor request a DMA. Pinned by alyosha
  ## fifo_dma/fifo and fifo_2 (without the gate an armed sound DMA refills a
  ## FIFO that cannot fill, every overflow, and fifo never draws a verdict).
  ## AGB SP, tests/roms/payloads/fifoslot.s w = 1: words stored with the
  ## master off, then the master on: the first overflow asks for a refill
  ## exactly as for an empty FIFO.
const FIFO_REQ_BEFORE_POP {.booldefine.} = true
  ## A FIFO asks for a refill on its timer's overflow when it held fewer than
  ## 16 bytes before the sample was taken, not after: alyosha fifo_dma/fifo_4
  ## preloads exactly 16 and the first overflow requests nothing, the second
  ## does (after the pop fails fifo_4).
const FIFO_DMA_REQUEST_DELAY {.intdefine.} = 4
  ## The refill DMA is requested this many cycles after the overflow.
  ## Pinned by alyosha fifo_dma/fifo_2 (3 and 5 each fail a case). At most
  ## one request per overflow per FIFO; a grant re-checks the FIFO level
  ## (dma.run_pending).

const FIFO_LEVEL_AT_OVERFLOW {.booldefine.} = true
  ## A timer overflow that lands inside a refill burst of the FIFO it drives
  ## decides on the words that burst had written by its cycle, not on the
  ## whole burst (events dispatch after a burst, so the burst's word stamps,
  ## DMA.fifo_word_at, say which came later; a word written on the
  ## overflow's own cycle counts). AGB SP, tests/roms/payloads/fifoslot.s:
  ## FIFO A on TM0 at period k, an empty FIFO, a 4-word burst from EWRAM
  ## (30 cycles, words in at +8, +15, +22, +29 from the grant): the second overflow
  ## at +28 (k = 32) asks for another refill, at +29 (k = 33) it does not;
  ## from the gamepak slot (32 cycles, words in at +10 .. +31) the edge is
  ## between k = 34 and 35.
const FIFO_DROP_BUSY {.booldefine.} = true
  ## A refill request that arrives while the channel's own burst still holds
  ## the bus is lost, as an H-blank one is (dma.nim HDMA_DROP_BUSY); the
  ## FIFO asks again at its next overflow. fifoslot.s: the second
  ## overflow's request (4 cycles after it) lands inside the first burst
  ## for k = 26..28 (EWRAM) and 26..30 (slot) and costs the CPU nothing; on
  ## or after the burst's end it gets a second burst, back to back at
  ## k = 30 / 32 and a cycle or two later at k = 31..32 / 33..34; on the
  ## burst's last cycle see FIFO_HANDBACK_CHAIN. Also matches fifospk.s
  ## (DMA0 armed, k = 20).
const FIFO_HANDBACK_CHAIN {.booldefine.} = true
  ## A refill request that lands on the burst's last cycle, the hand-back,
  ## is granted there: the channel keeps the bus for the next burst's first
  ## read (its write waits), lets the bus go, and holds that word until the
  ## FIFO's next request, whose burst writes it and reads the other three,
  ## without a lead cycle. fifoslot.s, EWRAM at k = 29: the first refill
  ## costs the CPU 36 cycles (the burst less its hand-back, a 6-cycle read,
  ## the hand-back) and the next one 23 (a write, three transfers, the
  ## hand-back), where two plain bursts cost 30 and 30; from the slot at
  ## k = 31, 38 and 25 (the chained read continues the burst's sequential
  ## gamepak stream; the resumed one starts nonsequential). fifoffff.s
  ## (tools/hwlink/open-agb.json, IWRAM bursts of 10 at k = 3) reads 11 then
  ## 19 cycles, the same shape.

const FIFO_CART_CHAIN_LATE {.booldefine.} = true
  ## With the CPU fetching from the gamepak (prefetcher off), a refill
  ## request on the cycle after the burst's hand-back is chained as one on
  ## the hand-back is (FIFO_HANDBACK_CHAIN), a cycle later than with the CPU
  ## in RAM. The chained read comes before the CPU's fetch on that cycle,
  ## whose gamepak stream goes on behind it (dma.run_pending). AGB SP and a
  ## flashcart: alyosha fifo_dma/fifo.gba run from the cartridge (FIFO A on
  ## TM0 at period 32, DMA1 from the cartridge, WAITCNT 0; variants in
  ## tests/roms/alyfifo.py): the second overflow's request, on the cycle
  ## after the first burst, takes a 6-cycle read there and the rest of that
  ## burst (25 cycles) comes at the third overflow. Without this, a
  ## back-to-back second burst, and fifo.gba fails. With the CPU in RAM the
  ## same request gets a back-to-back burst (fifoslot.s, the slot at k = 32).

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

const FIFO_RESET_KEEPS_WORD {.booldefine.} = false
  ## The reference emulators' FIFO reset, REFUTED by the console; off by
  ## default, on only to reproduce them. AGB SP, tests/roms/payloads/
  ## fiforeset.s reads 2 in all 18 cells: a reset by SOUNDCNT_H bit 11/15 or
  ## by the master enable empties the FIFO, the playing word included
  ## (frozen in tests/roms/cyclelaws/fiforeset.gba).
  ## On: a bit-11/15 reset drops the queued words but not the rest of the
  ## playing word, whose 1-3 samples still come out first (fiforeset.s v = 0
  ## reads 2 5 4 3 on them). With it Kingdom Hearts - Chain of Memories'
  ## FIFO B runs 29 output samples behind FIFO A after its sound restart (the
  ## restart resets FIFO A three bytes short of a word boundary; m4a's resync
  ## keeps the offset). The master enable going off clears the word either
  ## way: keeping it there reads one refill burst short in the console's
  ## fifomap cells after a part-played cell (r0-agb.json, 0x1428) and fails
  ## dbsuite fifodma "spike" cells (docs/playtest-bugs.md section 30).

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

proc fifo_reset*(dc: DMAChannels; channel: int; by_bit = false) =
  ## `by_bit`: SOUNDCNT_H's reset bit, not the master enable going off.
  when FIFO_RESET_KEEPS_WORD:
    # The FIFO fills a word at a time from position 0, so the head word has
    # played `positions mod 4` of its bytes; one not yet started goes with
    # the rest. The next word is stored right after the kept bytes.
    let played = dc.positions[channel] mod 4
    if by_bit and played != 0 and dc.sizes[channel] > 0:
      dc.sizes[channel] = min(4 - played, dc.sizes[channel])
      dc.latches[channel] = 0
      dc.hist[channel] = [0'i16, 0, 0, 0]
      dc.inv_period[channel] = 0.0'f32
      return
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
  # MP2K HLE (mp2k.nim on_frame): the m4a driver feeds the FIFOs only via
  # DMA1/2 in FIFO timing; bytes arriving any other way mean the game streams
  # its own audio and must not be substituted.
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
  ## broadband noise.
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
    # FIFO_MASTER_RESET: with the master off, no sample and no DMA request
    if not dc.gba.apu.sound_enabled: return
  for channel in 0..1:
    let ch_timer = if channel == 0:
      int(dc.gba.apu.soundcnt_h.dma_sound_a_timer)
    else:
      int(dc.gba.apu.soundcnt_h.dma_sound_b_timer)
    if timer == ch_timer:
      var level = dc.sizes[channel]
      when FIFO_LEVEL_AT_OVERFLOW:
        # Words of the burst just run that it wrote after this overflow's
        # cycle were not in the FIFO yet (the count wraps at 32 bytes, as
        # FIFO_WORD_WRAP has it). A burst's stamps rise, so its last says
        # whether any did.
        let now = dc.gba.scheduler.cycles
        if dc.gba.dma.fifo_word_at[channel][3] > now:
          for t in dc.gba.dma.fifo_word_at[channel]:
            if t > now: level = (level + 28) and 31
      let want = level < 16
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
      # Only the FIFO this timer drives asks for a refill.
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
  ## FIFO_DMA_WINDOW, at an overflow that booked nothing with the window
  ## open: close it unless a request is on its way for a FIFO with a sound
  ## DMA armed (a granted one is closed by the internal cycles after it).
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
