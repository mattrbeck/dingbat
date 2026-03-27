# DMA sound channels (included by gba.nim)

var dbg_fifo_nonzero_write_count: array[2, int]  # DBG: track first non-zero FIFO writes

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

proc dma_channels_read*(dc: DMAChannels; address: uint32): uint8 =
  dc.gba.bus.read_open_bus_value(address)

proc dma_channels_write*(dc: DMAChannels; address: uint32; value: uint8) =
  let channel = int(bit(address, 2))
  if dc.sizes[channel] < 32:
    if value != 0 and dbg_fifo_nonzero_write_count[channel] < 5:
      echo "DBG FIFO", channel, " write #", dbg_fifo_nonzero_write_count[channel],
           ": val=0x", toHex(value, 2), " (", cast[int8](value), ") addr=0x",
           toHex(address, 8), " size=", dc.sizes[channel], " pos=", dc.positions[channel]
      dbg_fifo_nonzero_write_count[channel] += 1
    dc.fifos[channel][(dc.positions[channel] + dc.sizes[channel]) mod 32] = cast[int8](value)
    dc.sizes[channel] += 1
  else:
    log("Writing " & hex_str(value) & " to fifo " & $channel & " but it's already full")

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
        dc.latches[channel] = int16(dc.fifos[channel][dc.positions[channel]]) shl 1
        dc.positions[channel] = (dc.positions[channel] + 1) mod 32
        dc.sizes[channel] -= 1
      else:
        log("Timer overflow but empty; channel:" & $channel & ", timer:" & $timer)
        dc.latches[channel] = 0
    if dc.sizes[channel] < 16:
      dc.gba.dma.trigger_fifo(channel)

proc dma_channels_get_amplitude*(dc: DMAChannels): tuple[a: int16, b: int16] =
  (dc.latches[0], dc.latches[1])
