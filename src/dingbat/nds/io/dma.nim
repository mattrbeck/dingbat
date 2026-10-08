## Four DMA channels per CPU (0x40000B0 + 12n: SAD, DAD, CNT), all R/W on
## the DS. ARM9: 21-bit count, 3-bit start mode (bits 27-29) and the fill
## words at 0x40000E0. ARM7: GBA-style 2-bit start mode (bits 28-29), GBA
## count and address limits (GBATEK "DS DMA Transfers").
##
## A transfer runs to completion when it triggers (or in bursts: the
## geometry-FIFO and main-memory-display modes move a few words per
## request), and stalls the owning CPU for its bus time (`dma_stall`). The
## transfer is generic over the CPU's bus (mixin read16/read32/write16/
## write32), so it sees exactly what that CPU sees -- except TCM, which DMA
## cannot reach (bus9 checks `dma_access`).
##
## Bus time. ARM9 (the reference runs on tests/nds/src/disp_dmatime,
## docs/oracles.md; GBATEK gives no DMA timing beyond "main memory read
## cycles are performed simultaneously with write cycles to other memory"):
## a 32-bit unit costs its read (main RAM 1, VRAM/palette 2, the 32-bit-bus
## regions 1) plus its write (main RAM 2, VRAM/palette 2, others 1), a
## 16-bit unit 2, main RAM to main RAM 18 (32-bit) or 16 (16-bit); a block
## adds 1 cycle, 2 when it moves more than one unit. GBA-slot sides and the
## ARM7 keep the earlier estimate: one bus cycle per side on a 32-bit bus,
## one per halfword on a 16-bit one, plus 4 per block.

import irq
import ../quirky

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: nds_quirky.}

type
  DmaTiming* = enum
    dtImmediate, dtVBlank, dtHBlank, dtDisplayStart, dtMainMemDisplay,
    dtCart, dtGbaSlot, dtGxFifo, dtWifi, dtNone

  DmaChannel* = object
    sad*, dad*: uint32
    cnt*: uint32            ## count (low bits) + control (bits 16-31)
    cur_src*, cur_dst*: uint32
    cur_count*: uint32      ## units left in the running block
    enabled*: bool

  Dma* = ref object
    is9*: bool
    ch*: array[4, DmaChannel]
    fill*: array[4, uint32]  ## ARM9 0x40000E0-0x40000EF
    irq* {.cursor.}: IrqCtl
    dma_access*: bool        ## a transfer is on the bus (TCM invisible)

const BURST_CYCLES = 4'i64

proc new_dma*(is9: bool; irq: IrqCtl): Dma = Dma(is9: is9, irq: irq)

proc timing*(d: Dma; i: int): DmaTiming =
  let c = d.ch[i].cnt
  if d.is9:
    DmaTiming((c shr 27) and 7)
  else:
    case (c shr 28) and 3
    of 0: dtImmediate
    of 1: dtVBlank
    of 2: dtCart
    else: (if i == 0 or i == 2: dtWifi else: dtGbaSlot)

proc count_of(d: Dma; i: int): uint32 =
  let c = d.ch[i].cnt
  if d.is9:
    result = c and 0x1F_FFFF
    if result == 0: result = 0x20_0000
  else:
    let m = if i == 3: 0xFFFF'u32 else: 0x3FFF'u32
    result = c and m
    if result == 0: result = m + 1

proc waiting*(d: Dma; t: DmaTiming): bool =
  ## Some enabled channel starts on `t`.
  for i in 0..3:
    if d.ch[i].enabled and d.timing(i) == t: return true

proc side_cycles(a: uint32; word: bool): int64 {.inline.} =
  case a shr 24
  of 0x02, 0x05, 0x06, 0x08, 0x09, 0x0A: (if word: 2 else: 1)
  else: 1

proc unit_cycles9(src, dst: uint32; word: bool): int64 {.inline.} =
  ## ARM9 bus cycles per unit (see the module comment).
  let s = src shr 24
  let t = dst shr 24
  if s in 0x08'u32..0x0A'u32 or t in 0x08'u32..0x0A'u32:
    return side_cycles(src, word) + side_cycles(dst, word)
  if s == 0x02 and t == 0x02: return (if word: 18 else: 16)
  if not word: return 2
  let r = if s in 0x05'u32..0x06'u32: 2'i64 else: 1'i64
  let w = if t == 0x02 or t in 0x05'u32..0x06'u32: 2'i64 else: 1'i64
  r + w

proc transfer_units*[B](d: Dma; bus: B; i: int; units: uint32) =
  ## Move up to `units` of channel i's running block; the block ending
  ## raises the IRQ and reloads (repeat) or disables the channel.
  mixin read16, read32, write16, write32, dma_stall
  var c = addr d.ch[i]
  let n = min(units, c.cur_count)
  let word = (c.cnt and (1'u32 shl 26)) != 0
  let step = if word: 4'u32 else: 2'u32
  let dst_ctl = (c.cnt shr 21) and 3
  let src_ctl = (c.cnt shr 23) and 3
  let unit_cost = if d.is9: unit_cycles9(c.cur_src, c.cur_dst, word)
                  else: side_cycles(c.cur_src, word) + side_cycles(c.cur_dst, word)
  d.dma_access = true
  for _ in 0 ..< n:
    if word:
      write32(bus, c.cur_dst and not 3'u32, read32(bus, c.cur_src and not 3'u32))
    else:
      write16(bus, c.cur_dst and not 1'u32, uint16(read16(bus, c.cur_src and not 1'u32)))
    case src_ctl
    of 0: c.cur_src += step
    of 1: c.cur_src -= step
    else: discard
    case dst_ctl
    of 0, 3: c.cur_dst += step
    of 1: c.cur_dst -= step
    else: discard
  d.dma_access = false
  c.cur_count -= n
  let per_block = if not d.is9: BURST_CYCLES elif n > 1: 2'i64 else: 1'i64
  dma_stall(bus, 2 * (per_block + int64(n) * unit_cost))
  if c.cur_count > 0: return
  if (c.cnt and (1'u32 shl 30)) != 0:
    d.irq.raise_bit(ord(irqDma0) + i)
  let repeat = (c.cnt and (1'u32 shl 25)) != 0
  if repeat and d.timing(i) != dtImmediate:
    c.cur_count = d.count_of(i)
    if dst_ctl == 3: c.cur_dst = c.dad
  else:
    c.cnt = c.cnt and not 0x8000_0000'u32
    c.enabled = false

proc transfer*[B](d: Dma; bus: B; i: int) =
  ## Run channel i's whole block now.
  d.transfer_units(bus, i, d.ch[i].cur_count)

proc trigger*[B](d: Dma; bus: B; t: DmaTiming) =
  ## Start every enabled channel waiting on `t` (V-blank, H-blank, ...).
  for i in 0..3:
    if d.ch[i].enabled and d.timing(i) == t:
      d.transfer(bus, i)

proc read_reg*(d: Dma; offset: uint32): uint32 =
  if offset >= 0xE0:
    return if d.is9: d.fill[(offset - 0xE0) shr 2] else: 0
  let i = int((offset - 0xB0) div 12)
  case (offset - 0xB0) mod 12
  of 0: d.ch[i].sad
  of 4: d.ch[i].dad
  else: d.ch[i].cnt

proc write_reg*[B](d: Dma; bus: B; offset: uint32; v, mask: uint32) =
  if offset >= 0xE0:
    if d.is9:
      let i = (offset - 0xE0) shr 2
      d.fill[i] = (d.fill[i] and not mask) or (v and mask)
    return
  let i = int((offset - 0xB0) div 12)
  var c = addr d.ch[i]
  # ARM7 (GBA limits): SAD 27 bits on DMA0, DAD 27 bits on DMA0-2
  let src_mask = if not d.is9 and i == 0: 0x07FF_FFFF'u32 else: 0x0FFF_FFFF'u32
  let dst_mask = if not d.is9 and i < 3: 0x07FF_FFFF'u32 else: 0x0FFF_FFFF'u32
  case (offset - 0xB0) mod 12
  of 0: c.sad = ((c.sad and not mask) or (v and mask)) and src_mask
  of 4: c.dad = ((c.dad and not mask) or (v and mask)) and dst_mask
  else:
    let was = c.enabled
    c.cnt = (c.cnt and not mask) or (v and mask)
    c.enabled = (c.cnt and 0x8000_0000'u32) != 0
    if c.enabled and not was:
      c.cur_src = c.sad
      c.cur_dst = c.dad
      c.cur_count = d.count_of(i)
      if d.timing(i) == dtImmediate: d.transfer(bus, i)
      # Burst modes (dtGxFifo, dtMainMemDisplay) and slot-1 are started by
      # nds.nim when their source asks.

{.pop.}
