# DMA implementation (included by gba.nim)

const
  DMA_SRC_MASK = [0x07FFFFFF'u32, 0x0FFFFFFF'u32, 0x0FFFFFFF'u32, 0x0FFFFFFF'u32]
  DMA_DST_MASK = [0x07FFFFFF'u32, 0x07FFFFFF'u32, 0x07FFFFFF'u32, 0x0FFFFFFF'u32]
  DMA_LEN_MASK = [0x3FFF'u16,     0x3FFF'u16,     0x3FFF'u16,     0xFFFF'u16    ]

proc dma_addr_delta(ctrl: int; word_size: int): int =
  # ctrl: 0=Increment, 1=Decrement, 2=Fixed, 3=IncrementReload
  case ctrl
  of 0, 3: word_size    # Increment / IncrementReload
  of 1:   -word_size    # Decrement
  else:    0            # Fixed

proc make_dma_irq_flag(gba: GBA; num: int): proc() {.closure.} =
  case num
  of 0: result = proc() {.closure.} = gba.interrupts.reg_if.dma0 = true
  of 1: result = proc() {.closure.} = gba.interrupts.reg_if.dma1 = true
  of 2: result = proc() {.closure.} = gba.interrupts.reg_if.dma2 = true
  of 3: result = proc() {.closure.} = gba.interrupts.reg_if.dma3 = true
  else: result = proc() {.closure.} = discard

proc new_dma*(gba: GBA): DMA =
  result = DMA(gba: gba)
  for i in 0..3:
    result.dmasad[i]  = 0
    result.dmadad[i]  = 0
    result.dmacnt_l[i] = 0
    result.dmacnt_h[i] = DMACNT()
    result.src[i]     = 0
    result.dst[i]     = 0
    result.interrupt_flags[i] = make_dma_irq_flag(gba, i)

proc trigger*(dma: DMA; channel: int)

proc `[]`*(dma: DMA; io_addr: uint32): uint8 =
  let channel = int((io_addr - 0xB0'u32) div 12)
  let reg     = int((io_addr - 0xB0'u32) mod 12)
  case reg
  of 8, 9: 0'u8  # dmacnt_l is write-only
  of 10, 11:
    var val = read(dma.dmacnt_h[channel], io_addr and 1)
    if io_addr == 0xDF'u32 and dma.dmacnt_h[3].game_pak:
      val = val or 0b1000'u8
    val
  else: dma.gba.bus.read_open_bus_value(io_addr)

proc `[]=`*(dma: DMA; io_addr: uint32; value: uint8) =
  let channel = int((io_addr - 0xB0'u32) div 12)
  let reg     = int((io_addr - 0xB0'u32) mod 12)
  case reg
  of 0, 1, 2, 3:  # dmasad
    let mask = 0xFF'u32 shl (8 * reg)
    let v32  = uint32(value) shl (8 * reg)
    dma.dmasad[channel] = ((dma.dmasad[channel] and not mask) or v32) and DMA_SRC_MASK[channel]
  of 4, 5, 6, 7:  # dmadad
    let r2   = reg - 4
    let mask = 0xFF'u32 shl (8 * r2)
    let v32  = uint32(value) shl (8 * r2)
    dma.dmadad[channel] = ((dma.dmadad[channel] and not mask) or v32) and DMA_DST_MASK[channel]
  of 8, 9:  # dmacnt_l
    let r2   = reg - 8
    let mask = 0xFF'u16 shl (8 * r2)
    let v16  = uint16(value) shl (8 * r2)
    dma.dmacnt_l[channel] = ((dma.dmacnt_l[channel] and not mask) or v16) and DMA_LEN_MASK[channel]
  of 10, 11:  # dmacnt_h
    let enabled = dma.dmacnt_h[channel].enable
    write(dma.dmacnt_h[channel], value, io_addr and 1)
    if dma.dmacnt_h[channel].enable and not enabled:
      dma.src[channel] = dma.dmasad[channel]
      dma.dst[channel] = dma.dmadad[channel]
      if dma.dmacnt_h[channel].start_timing == 0:  # Immediate
        dma.trigger(channel)
  else:
    echo "Unmapped DMA write addr: ", hex_str(uint8(io_addr)), " val: ", value

proc trigger_hdma*(dma: DMA) =
  for channel in 0..3:
    if dma.dmacnt_h[channel].enable and dma.dmacnt_h[channel].start_timing == 2:  # HBlank
      dma.trigger(channel)

proc trigger_vdma*(dma: DMA) =
  for channel in 0..3:
    if dma.dmacnt_h[channel].enable and dma.dmacnt_h[channel].start_timing == 1:  # VBlank
      dma.trigger(channel)

proc trigger_fifo*(dma: DMA; fifo_channel: int) =
  let ch = fifo_channel + 1
  if dma.dmacnt_h[ch].enable and dma.dmacnt_h[ch].start_timing == 3:  # Special
    dma.trigger(ch)

proc trigger*(dma: DMA; channel: int) =
  let start_timing   = int(dma.dmacnt_h[channel].start_timing)
  let source_control = int(dma.dmacnt_h[channel].source_control)
  let dest_control   = int(dma.dmacnt_h[channel].dest_control)
  var word_size      = 2 shl int(dma.dmacnt_h[channel].xfer_type)  # 2 or 4
  var len            = int(dma.dmacnt_l[channel])
  var dest_ctrl      = dest_control

  if source_control == 3:  # IncrementReload - prohibited
    echo "Prohibited source address control"

  if start_timing == 3:  # Special
    if channel == 1 or channel == 2:  # FIFO
      len = 4
      word_size = 4
      dest_ctrl = 2  # Fixed
    elif channel == 3:
      echo "todo: video capture dma"
    else:
      echo "Prohibited special dma"

  let delta_source = dma_addr_delta(source_control, word_size)
  let delta_dest   = dma_addr_delta(dest_ctrl,  word_size)

  for _ in 0 ..< len:
    if word_size == 4:
      dma.gba.bus.write_word(dma.dst[channel], dma.gba.bus.read_word(dma.src[channel]))
    else:
      dma.gba.bus.write_half(dma.dst[channel], dma.gba.bus.read_half(dma.src[channel]))
    dma.src[channel] = uint32(int(dma.src[channel]) + delta_source)
    dma.dst[channel] = uint32(int(dma.dst[channel]) + delta_dest)

  if dest_ctrl == 3:  # IncrementReload
    dma.dst[channel] = dma.dmadad[channel]

  if not dma.dmacnt_h[channel].repeat or start_timing == 0:  # not (repeat && not Immediate)
    dma.dmacnt_h[channel].enable = false

  if dma.dmacnt_h[channel].irq_enable:
    dma.interrupt_flags[channel]()
    dma.gba.interrupts.schedule_interrupt_check()
