# DMA sound channels (included by gba.nim)

const DMA_CHANNELS_RANGE_LOW*  = 0xA0'u32
const DMA_CHANNELS_RANGE_HIGH* = 0xA7'u32

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
    result.samples_since[ch]   = 0
    # Seed the phase denominator with the typical FIFO/output ratio
    # (32768 / ~13379 Hz) so the very first update period interpolates
    # sanely before a real interval has been measured.
    result.update_interval[ch] = 2.45'f32
  # Cubic FIFO reconstruction defaults ON (hardware faithfulness — see the
  # DMAChannels comment). DINGBAT_FIFO_INTERP=0 forces the legacy zero-order-
  # hold read, used for before/after A/B captures on a single binary.
  result.fifo_interp = true
  when not defined(test_harness) and not defined(emscripten):
    if getEnv("DINGBAT_FIFO_INTERP") == "0":
      result.fifo_interp = false

proc dma_channels_read*(dc: DMAChannels; address: uint32): uint8 =
  dc.gba.bus.read_open_bus_value(address)

proc dma_channels_write*(dc: DMAChannels; address: uint32; value: uint8) =
  let channel = int(bit(address, 2))
  # MP2K HLE foreign-feeder provenance (see mp2k.nim on_frame): the m4a driver
  # only feeds the FIFOs via DMA1/2 in special (FIFO) timing. Count bytes
  # arriving any other way (CPU stores, immediate/other DMA) so the HLE can
  # tell when a game streams its own audio and must not be substituted.
  if dc.gba.mp2k != nil:
    let d = dc.gba.dma
    let by_fifo_dma = dc.gba.bus.dma_active and
                      (d.current_priority == 1 or d.current_priority == 2) and
                      d.dmacnt_h[d.current_priority].start_timing == 3
    if not by_fifo_dma:
      inc dc.gba.mp2k.fifo_cpu_bytes
  if dc.sizes[channel] < 32:
    dc.fifos[channel][(dc.positions[channel] + dc.sizes[channel]) mod 32] = cast[int8](value)
    dc.sizes[channel] += 1
  else:
    log("Writing " & hex_str(value) & " to fifo " & $channel & " but it's already full")

proc push_fifo_sample(dc: DMAChannels; channel: int; sample: int16) {.inline.} =
  ## Record a newly latched FIFO sample for cubic reconstruction. Called on
  ## every timer overflow that advances the DAC (including empty-FIFO 0s), so
  ## the history reflects the true update cadence. update_interval captures
  ## how many 32768 Hz reads spanned the period just ended — the denominator
  ## for the fractional phase between updates.
  dc.hist[channel][0] = dc.hist[channel][1]
  dc.hist[channel][1] = dc.hist[channel][2]
  dc.hist[channel][2] = dc.hist[channel][3]
  dc.hist[channel][3] = sample
  dc.update_interval[channel] = max(1.0'f32, float32(dc.samples_since[channel]))
  dc.samples_since[channel] = 0

proc timer_overflow*(dc: DMAChannels; timer: int) =
  for channel in 0..1:
    # Access soundcnt_h via gba.apu
    let ch_timer = if channel == 0:
      int(dc.gba.apu.soundcnt_h.dma_sound_a_timer)
    else:
      int(dc.gba.apu.soundcnt_h.dma_sound_b_timer)
    if timer == ch_timer:
      if dc.sizes[channel] > 0:
        log("Timer overflow good; channel:" & $channel & ", timer:" & $timer)
        let sample = int16(dc.fifos[channel][dc.positions[channel]]) shl 1
        dc.latches[channel] = sample
        dc.push_fifo_sample(channel, sample)
        dc.positions[channel] = (dc.positions[channel] + 1) mod 32
        dc.sizes[channel] -= 1
      else:
        log("Timer overflow but empty; channel:" & $channel & ", timer:" & $timer)
        dc.latches[channel] = 0
        dc.push_fifo_sample(channel, 0)
    if dc.sizes[channel] < 16:
      dc.gba.dma.trigger_fifo(channel)

proc catmull_rom(y0, y1, y2, y3: int16; mu: float32): int16 {.inline.} =
  ## Cubic (Catmull-Rom) interpolation between y1 and y2 at fraction mu in
  ## [0,1], using the neighbours y0 and y3 for the tangents. Formulation
  ## follows Paul Bourke, "Cubic Interpolation"
  ## (https://paulbourke.net/miscellaneous/interpolation/). Interpolating the
  ## y1/y2 segment (rather than the newest pair y2/y3) keeps the filter
  ## strictly causal — it needs one sample of look-ahead — at the cost of a
  ## ~1.5-sample (~150 us) group delay, which is inaudible.
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
  ## Called once per 32768 Hz output sample. With reconstruction on, returns
  ## the cubic-interpolated FIFO value at the current fractional phase between
  ## timer-driven updates; otherwise the raw held latch (zero-order hold).
  if not dc.fifo_interp:
    return (dc.latches[0], dc.latches[1])
  var res: array[2, int16]
  for ch in 0..1:
    # Phase within the current update period. samples_since is advanced AFTER
    # sampling so the read immediately following an update sits at phase 0.
    let denom = dc.update_interval[ch]
    if denom <= 1.0'f32:
      # FIFO updating at or above the output rate: nothing to reconstruct
      # between updates, so hold the latest latch.
      res[ch] = dc.latches[ch]
    else:
      let mu = clamp(float32(dc.samples_since[ch]) / denom, 0.0'f32, 1.0'f32)
      res[ch] = catmull_rom(dc.hist[ch][0], dc.hist[ch][1],
                            dc.hist[ch][2], dc.hist[ch][3], mu)
    dc.samples_since[ch] += 1
  (res[0], res[1])
