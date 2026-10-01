## ARM7 wifi block at 0x04800000-0x0480FFFF: MAC registers (0x4808000 +
## 0x000-0xFFF, mirrored), 8 KB of wifi RAM at 0x04804000, the baseband (BB)
## and RF chips behind their serial ports. GBATEK "DS Wifi ...".
##
## No radio: nothing is ever received and transmits go nowhere, but the
## parts software waits on behave -- register widths and reset values, the
## IRQ flags and their IF.24 edge, power-state requests, the microsecond
## counter with its compare / beacon-count / post-beacon interrupts, the BB
## and RF register files, the TX/RX buffer ports, and transmits that finish
## (IRQ07 then IRQ01, TXSTAT and the TX header status) after their air time.
## That is what the SDK's wireless manager checks before it reports that the
## hardware is up; games that scan for others see an empty channel.

import ../sched
import irq

const
  WIFI_REGS = 0x800            ## halfwords in 0x000-0xFFF

type
  Wifi* = ref object
    regs*: array[WIFI_REGS, uint16]   ## register window by halfword
    ram*: array[0x1000, uint16]       ## 0x04804000 packet RAM
    bb*: array[0x100, uint8]          ## baseband chip registers
    rf*: array[0x40, uint32]          ## RF chip registers (18-bit / 8-bit)
    sched* {.cursor.}: NdsScheduler
    irq* {.cursor.}: IrqCtl
    masks: array[WIFI_REGS, uint16]
    irq_active: bool              ## (W_IF and W_IE) != 0 last time it was looked at
    random: uint16                ## W_RANDOM generator state (11 bits)
    random_at: int64              ## master cycle `random` was taken at
    us_base: uint64               ## W_US_COUNT at `us_base_at` (or frozen value)
    us_base_at: int64
    us_running: bool
    next_ms: int64                ## master cycle of the next millisecond boundary
    irq15_at: int64               ## pending pre-beacon IRQ (-1 = none)
    tx_done_at: int64             ## running transmit ends (-1 = none)
    tx_loc: int                   ## 0 LOC1, 1 CMD, 2 LOC2, 3 LOC3 being sent

const
  # Writable bits per register (GBATEK "DS Wifi I/O Map", r/w column);
  # registers absent from the table keep every written bit.
  MASK_TABLE = [
    (0x004, 0x9FFF'u16), (0x006, 0x007F'u16), (0x028, 0x000F'u16), (0x02A, 0x07FF'u16),
    (0x02E, 0x0001'u16), (0x030, 0xFF0E'u16), (0x034, 0x0000'u16), (0x036, 0x0003'u16),
    (0x038, 0x0007'u16), (0x03C, 0x0002'u16), (0x040, 0x8001'u16), (0x044, 0x0000'u16),
    (0x048, 0x0003'u16), (0x054, 0x0000'u16), (0x056, 0x0FFF'u16), (0x058, 0x1FFE'u16),
    (0x05A, 0x0FFF'u16), (0x05C, 0x0FFF'u16), (0x062, 0x1FFE'u16), (0x064, 0x0FFF'u16),
    (0x068, 0x1FFE'u16), (0x06C, 0x0FFF'u16), (0x074, 0x1FFE'u16), (0x076, 0x0FFF'u16),
    (0x084, 0x00FF'u16), (0x088, 0x00FF'u16), (0x08C, 0x03FF'u16), (0x08E, 0x00FF'u16),
    (0x098, 0x0000'u16), (0x0B0, 0x0000'u16), (0x0B6, 0x0000'u16), (0x0B8, 0x0000'u16),
    (0x0BC, 0x0003'u16), (0x0D0, 0x1FFF'u16), (0x0D4, 0x0003'u16), (0x0D8, 0x0FFF'u16),
    (0x0E0, 0x000F'u16), (0x0E8, 0x0001'u16), (0x0EA, 0x0001'u16), (0x0EC, 0x3F1F'u16),
    (0x0EE, 0x0001'u16), (0x0F0, 0xFC00'u16), (0x120, 0x81FF'u16), (0x130, 0x0FFF'u16),
    (0x132, 0x8FFF'u16), (0x144, 0x00FF'u16), (0x146, 0x00FF'u16), (0x148, 0x00FF'u16),
    (0x14A, 0x00FF'u16), (0x150, 0xFF3F'u16), (0x154, 0x7A7F'u16), (0x15C, 0x0000'u16),
    (0x15E, 0x0000'u16), (0x160, 0x4100'u16), (0x168, 0x800F'u16), (0x180, 0x0000'u16),
    (0x184, 0x413F'u16), (0x194, 0x0007'u16), (0x198, 0x000F'u16), (0x19C, 0x0000'u16),
    (0x1A0, 0x0933'u16), (0x1A2, 0x0003'u16), (0x1A8, 0x0000'u16), (0x1AC, 0x0000'u16),
    (0x1B0, 0x00FF'u16), (0x1B8, 0x00FF'u16), (0x1BA, 0x00FF'u16), (0x1C0, 0x00FF'u16),
    (0x1C4, 0x0000'u16), (0x1D0, 0xFF00'u16), (0x1F0, 0x0003'u16), (0x210, 0x0000'u16),
    (0x214, 0x0000'u16), (0x224, 0x0003'u16), (0x230, 0x00FF'u16), (0x234, 0x0EFF'u16),
    (0x254, 0x0000'u16), (0x268, 0x0000'u16), (0x2C0, 0x0001'u16)]

  RESET_VALUES = [
    (0x02C, 0x0707'u16), (0x036, 0x0001'u16), (0x038, 0x0003'u16), (0x03C, 0x0200'u16),
    (0x050, 0x4000'u16), (0x052, 0x4800'u16), (0x08C, 0x0064'u16), (0x09C, 0x0050'u16),
    (0x0B0, 0x0010'u16), (0x0BC, 0x0001'u16), (0x0D0, 0x0401'u16), (0x0D4, 0x0001'u16),
    (0x0D8, 0x0004'u16), (0x0DA, 0x0602'u16), (0x0E0, 0x0008'u16), (0x0EC, 0x3F03'u16),
    (0x0EE, 0x0001'u16), (0x0F0, 0xFC00'u16), (0x0F2, 0xFFFF'u16), (0x0F4, 0xFFFF'u16),
    (0x0F6, 0xFFFF'u16), (0x120, 0x0048'u16), (0x122, 0x4840'u16), (0x130, 0x0142'u16),
    (0x132, 0x8064'u16), (0x134, 0xFFFF'u16), (0x142, 0x2443'u16), (0x144, 0x0042'u16),
    (0x146, 0x0016'u16), (0x148, 0x0016'u16), (0x14A, 0x0016'u16), (0x14C, 0x162C'u16),
    (0x150, 0x0204'u16), (0x154, 0x0058'u16), (0x15C, 0x00B5'u16), (0x160, 0x0100'u16),
    (0x168, 0x800D'u16), (0x17C, 0x0800'u16), (0x17E, 0xC008'u16), (0x184, 0x0018'u16),
    (0x19C, 0x0004'u16), (0x1A2, 0x0001'u16), (0x214, 0x0009'u16), (0x224, 0x0003'u16),
    (0x230, 0x0047'u16), (0x234, 0x0EFF'u16), (0x254, 0xFFFF'u16), (0x268, 0x0005'u16),
    (0x278, 0x000F'u16), (0x290, 0xFFFF'u16), (0x2A2, 0x7FFF'u16)]

  # W_MODE_RST bit 14 resets these to their reset values (GBATEK, Control)
  MODE_RST14 = [0x006, 0x008, 0x00A, 0x018, 0x01A, 0x01C, 0x020, 0x022, 0x024,
                0x028, 0x02A, 0x02C, 0x02E, 0x050, 0x052, 0x084, 0x0BC, 0x0D0,
                0x0D4, 0x0E0, 0x0EC, 0x194, 0x198, 0x1A2, 0x224, 0x230]

  US_PER_MS = 1024'i64          ## the "millisecond" of the beacon counters

template reg(w: Wifi; o: int): untyped = w.regs[o shr 1]

proc us_to_cycles(us: int64): int64 =
  ## Master cycles for `us` microseconds (the counter's 1 MHz is the RFU
  ## board's 22 MHz / 22, not derived from the system clock).
  (us * MASTER_HZ + 999_999) div 1_000_000

proc cycles_to_us(c: int64): int64 =
  (c div MASTER_HZ) * 1_000_000 + ((c mod MASTER_HZ) * 1_000_000) div MASTER_HZ

proc reset_value(o: int): uint16 =
  for (r, v) in RESET_VALUES:
    if r == o: return v

proc new_wifi*(sched: NdsScheduler; irq: IrqCtl): Wifi =
  result = Wifi(sched: sched, irq: irq, random: 1, irq15_at: -1, tx_done_at: -1)
  for i in 0 ..< WIFI_REGS: result.masks[i] = 0xFFFF
  for (o, m) in MASK_TABLE: result.masks[o shr 1] = m
  for (o, v) in RESET_VALUES: result.regs[o shr 1] = v
  # BB chip: reads the chip ID at 00h, 01h at 5Dh (GBATEK BB table); the
  # firmware bootcode's other settings are not reproduced (Assumed: 0)
  result.bb[0x00] = 0x6D
  result.bb[0x5D] = 0x01

# ---------------------------------------------------------------------------
# Interrupts

proc update_irq(w: Wifi) =
  ## IF.24 rises only when (W_IF and W_IE) goes from zero to non-zero.
  let active = (w.reg(0x010) and w.reg(0x012)) != 0
  if active and not w.irq_active: w.irq.raise_irq(irqWifi)
  w.irq_active = active

proc set_if(w: Wifi; bits: uint16) =
  w.reg(0x010) = w.reg(0x010) or (bits and 0xFBFF)
  w.update_irq()

# ---------------------------------------------------------------------------
# Microsecond counter and the beacon timers

proc us_now(w: Wifi): uint64 =
  if not w.us_running: return w.us_base
  w.us_base + uint64(cycles_to_us(w.sched.now) - cycles_to_us(w.us_base_at))

proc counter_on(w: Wifi): bool =
  (w.reg(0x0E8) and 1) != 0 and (w.reg(0x036) and 1) == 0

proc reschedule(w: Wifi) =
  var at = high(int64)
  if w.us_running: at = min(at, w.next_ms)
  if w.irq15_at >= 0: at = min(at, w.irq15_at)
  if w.tx_done_at >= 0: at = min(at, w.tx_done_at)
  if at == high(int64): w.sched.cancel(evWifi)
  else: w.sched.schedule(at, evWifi)

proc latch_counter(w: Wifi) =
  ## Re-derive the running state after a write that may start/stop it.
  let v = w.us_now()
  w.us_base = v
  w.us_base_at = w.sched.now
  w.us_running = w.counter_on()
  if w.us_running:
    # next boundary where the low 10 bits wrap
    let left = US_PER_MS - int64(v and 0x3FF)
    w.next_ms = w.sched.now + us_to_cycles(left)
  w.reschedule()

proc beacon_irq(w: Wifi; forced: bool) =
  ## IRQ14 (GBATEK "IRQ14 Notes").
  if not forced: w.reg(0x11C) = w.reg(0x08C)
  if (w.reg(0x0EA) and 1) != 0 or forced:
    w.reg(0x134) = 0xFFFF
    w.reg(0x0B0) = w.reg(0x0B0) and 0xFFF2'u16
    if w.reg(0x088) == 0: w.reg(0x088) = w.reg(0x08E)
    w.reg(0x088) = (w.reg(0x088) - 1) and 0xFF
    w.set_if(1'u16 shl 14)

proc post_beacon_irq(w: Wifi) =
  w.set_if(1'u16 shl 13)
  if (w.reg(0x038) and 2) == 0:
    # auto sleep (GBATEK "IRQ13 Notes")
    w.reg(0x034) = 2
    w.reg(0x03C) = w.reg(0x03C) or 0x0200
    w.reg(0x19C) = 0x0046
    w.reg(0x214) = 9

proc millisecond(w: Wifi) =
  ## One 1024-us boundary: the beacon and post-beacon counters step.
  let us = w.us_now()
  if (w.reg(0x0EA) and 1) != 0:
    let cmp = (uint64(w.reg(0x0F6)) shl 48) or (uint64(w.reg(0x0F4)) shl 32) or
              (uint64(w.reg(0x0F2)) shl 16) or uint64(w.reg(0x0F0) and 0xFC00)
    if (us and not 0x3FF'u64) == cmp: w.beacon_irq(false)
  if w.reg(0x11C) != 0:
    w.reg(0x11C) = w.reg(0x11C) - 1
    if w.reg(0x11C) == 0:
      if w.reg(0x110) == 0 and (w.reg(0x0EA) and 1) != 0: w.set_if(1'u16 shl 15)
      w.beacon_irq(false)
    elif w.reg(0x11C) == 1 and w.reg(0x110) != 0:
      # IRQ15 comes W_PRE_BEACON microseconds before the next boundary
      let lead = min(int64(w.reg(0x110)), US_PER_MS)
      w.irq15_at = w.next_ms + us_to_cycles(US_PER_MS - lead)
  if w.reg(0x134) != 0:
    w.reg(0x134) = w.reg(0x134) - 1
    if w.reg(0x134) == 0: w.post_beacon_irq()

# ---------------------------------------------------------------------------
# Transmit

proc loc_reg(i: int): int =
  case i
  of 0: 0x0A0
  of 1: 0x090
  of 2: 0x0A4
  else: 0x0A8

proc start_tx(w: Wifi) =
  ## Begin the next requested transfer (LOC3 first, LOC1 last), if idle.
  if w.tx_done_at >= 0: return
  if (w.reg(0x004) and 1) == 0 or (w.reg(0x03C) and 0x0200) != 0: return
  let req = w.reg(0x0B0)
  for i in [3, 2, 1, 0]:
    if (req and (1'u16 shl i)) != 0 and (w.reg(loc_reg(i)) and 0x8000) != 0:
      w.tx_loc = i
      let hdr = int(w.reg(loc_reg(i)) and 0xFFF)
      let len = int64(w.ram[(hdr + 5) and 0xFFF] and 0x3FFF)
      let rate = w.ram[(hdr + 4) and 0xFFF] and 0xFF
      # air time: 192-us long preamble, then the frame at 1 or 2 Mbit/s
      let us = 192 + (if rate == 0x14: len * 4 else: len * 8)
      w.tx_done_at = w.sched.now + us_to_cycles(us)
      w.reg(0x0B6) = w.reg(0x0B6) or (1'u16 shl i)
      w.reg(0x214) = 3
      w.reg(0x210) = (w.reg(0x210) + 1) and 0xFFF
      w.set_if(1'u16 shl 7)
      w.reschedule()
      return

proc finish_tx(w: Wifi) =
  ## IRQ01: the frame went out. Nobody answers, but frames to group
  ## addresses need no ACK, and the SDK's probes are broadcasts; a frame to
  ## a station is reported failed after its retries (TXHDR status 0003h).
  let i = w.tx_loc
  let lr = loc_reg(i)
  let hdr = int(w.reg(lr) and 0xFFF)
  let da0 = w.ram[(hdr + 6 + 2) and 0xFFF]       # IEEE addr1, first halfword
  let group = (da0 and 1) != 0
  w.ram[hdr and 0xFFF] = if group or i == 1: 0x0001'u16 else: 0x0003'u16
  w.ram[(hdr + 2) and 0xFFF] = w.ram[(hdr + 2) and 0xFFF] and 0x00FF'u16  # [05h] = 0
  var stat = 0x0001'u16 or (if group or i == 1: 0'u16 else: 2'u16)
  if i == 2: stat = stat or 0x1000
  elif i == 3: stat = stat or 0x2000
  if i != 1 and (w.reg(lr) and 0x1000) != 0: stat = stat or 0x0700
  if i == 1: stat = 0x0800
  w.reg(0x0B8) = stat
  w.reg(lr) = w.reg(lr) and 0x7FFF
  w.reg(0x0B6) = w.reg(0x0B6) and not (1'u16 shl i)
  w.reg(0x214) = 1
  w.tx_done_at = -1
  var bits = 1'u16 shl 1
  if not group and i != 1: bits = bits or (1'u16 shl 3)
  if i == 1: bits = bits or (1'u16 shl 12)
  w.set_if(bits)
  w.start_tx()

proc on_event*(w: Wifi) =
  ## evWifi: whatever of the millisecond tick, IRQ15 and TX end is due.
  let now = w.sched.now
  if w.tx_done_at >= 0 and w.tx_done_at <= now: w.finish_tx()
  if w.irq15_at >= 0 and w.irq15_at <= now:
    w.irq15_at = -1
    if (w.reg(0x0EA) and 1) != 0: w.set_if(1'u16 shl 15)
  while w.us_running and w.next_ms <= now:
    w.millisecond()
    w.next_ms += us_to_cycles(US_PER_MS)
  w.reschedule()

# ---------------------------------------------------------------------------
# Serial chips

proc bb_writable(i: int): bool =
  i in 0x01..0x0C or i in 0x13..0x15 or i in 0x1B..0x26 or i in 0x28..0x4C or
    i in 0x4E..0x5C or i in 0x62..0x63 or i == 0x65 or i in 0x67..0x68

proc bb_transfer(w: Wifi; cnt: uint16) =
  let i = int(cnt and 0xFF)
  case cnt shr 12
  of 5:
    if bb_writable(i): w.bb[i] = uint8(w.reg(0x15A))
  of 6: w.reg(0x15C) = uint16(w.bb[i])
  else: discard

proc rf_transfer(w: Wifi) =
  let d2 = w.reg(0x17C)
  let d1 = w.reg(0x17E)
  if (w.reg(0x184) and 0x100) != 0:
    # type 3: command in DATA2 bits 0-3, index/data in DATA1
    let i = int((d1 shr 8) and 0x3F)
    case d2 and 0xF
    of 5: w.rf[i] = uint32(d1 and 0xFF)
    of 6: w.reg(0x17E) = (d1 and 0xFF00) or uint16(w.rf[i] and 0xFF)
    else: discard
  else:
    let i = int((d2 shr 2) and 0x1F)
    if (d2 and 0x80) == 0:
      w.rf[i] = (uint32(d2 and 3) shl 16) or uint32(d1)
    else:
      w.reg(0x17E) = uint16(w.rf[i] and 0xFFFF)
      w.reg(0x17C) = (d2 and not 3'u16) or uint16((w.rf[i] shr 16) and 3)

# ---------------------------------------------------------------------------
# Register ports

proc step_random(w: Wifi) =
  ## X = (X and 1) xor (X rol 1) in 11 bits, at the bus clock; the read
  ## returns the value latched at the previous read (GBATEK W_RANDOM).
  let steps = ((w.sched.now - w.random_at) div 2) mod 0x5FD
  w.random_at = w.sched.now
  var x = w.random
  for _ in 0 ..< steps:
    x = (x and 1) xor (((x shl 1) or (x shr 10)) and 0x7FF)
  w.random = x

proc read16*(w: Wifi; a: uint32): uint16 =
  let r = a and 0x7FFF
  if r >= 0x4000:
    # 0x4000-0x5FFF: wifi RAM; 0x6000-0x7FFF unused (Assumed: reads FFFFh)
    return if r < 0x6000: w.ram[(r - 0x4000) shr 1] else: 0xFFFF
  let o = int(a and 0x0FFE)
  case o
  of 0x000: result = 0x1440              # W_ID (DS)
  of 0x044:
    result = w.random
    w.step_random()
  of 0x060:
    # W_RXBUF_RD_DATA: read and advance the RX read pointer
    let ra = int(w.reg(0x058))
    result = w.ram[(ra shr 1) and 0xFFF]
    var na = (ra + 2) and 0x1FFE
    if na == int(w.reg(0x062)): na = (na + 2 * int(w.reg(0x064))) and 0x1FFE
    w.reg(0x058) = uint16(na)
    if w.reg(0x05C) > 0:
      w.reg(0x05C) = w.reg(0x05C) - 1
      if w.reg(0x05C) == 0: w.set_if(1'u16 shl 9)
  of 0x078: result = w.reg(0x068)        # mirror of W_TXBUF_WR_ADDR
  of 0x0F8, 0x0FA, 0x0FC, 0x0FE:
    result = uint16((w.us_now() shr ((o - 0x0F8) * 8)) and 0xFFFF)
  else: result = w.reg(o)

proc write16*(w: Wifi; a: uint32; v: uint16) =
  let r = a and 0x7FFF
  if r >= 0x4000:
    if r < 0x6000: w.ram[(r - 0x4000) shr 1] = v
    return
  let o = int(a and 0x0FFE)
  let old = w.reg(o)
  case o
  of 0x004:
    w.reg(o) = (old and not 0x9FFF'u16) or (v and 0x9FFF)
    if (v and 1) != 0 and (old and 1) == 0:
      w.reg(0x034) = 2; w.reg(0x19C) = 0x0046; w.reg(0x214) = 9
      w.reg(0x27C) = 5
    elif (v and 1) == 0 and (old and 1) != 0:
      w.reg(0x27C) = 0x000A
    if (v and 0x2000) != 0:
      for r in [0x056, 0x0C0, 0x0C4, 0x1A4]: w.reg(r) = 0
      w.reg(0x278) = 0x000F
    if (v and 0x4000) != 0:
      for r in MODE_RST14: w.reg(r) = reset_value(r)
    w.start_tx()
  of 0x010:
    w.reg(o) = old and not v
    w.update_irq()
  of 0x012:
    w.reg(o) = v
    w.update_irq()
  of 0x21C: w.set_if(v)
  of 0x030:
    w.reg(o) = (old and not 0xFF0E'u16) or (v and 0xFF0E)
    if (v and 1) != 0: w.reg(0x054) = w.reg(0x056)
    if (v and 0x80) != 0:
      w.reg(0x098) = w.reg(0x094)
      w.reg(0x094) = 0
  of 0x036:
    w.reg(o) = v and 3
    w.latch_counter()
  of 0x03C:
    w.reg(o) = (old and not 2'u16) or (v and 2)
    if (v and 2) != 0 and (w.reg(0x036) and 1) == 0:
      # queued power-up; applied at once (Assumed: no measured delay)
      w.reg(o) = w.reg(o) and not 0x0302'u16
      w.reg(0x214) = 1
      w.set_if(1'u16 shl 11)
      w.start_tx()
  of 0x040:
    w.reg(o) = v and 0x8001
    if (v and 0x8000) != 0:
      if (v and 1) != 0:
        w.reg(0x03C) = w.reg(0x03C) or 0x0200
        w.reg(0x034) = 2; w.reg(0x0B0) = 0; w.reg(0x19C) = 0x0046; w.reg(0x214) = 9
      else:
        w.reg(0x03C) = w.reg(0x03C) and not 0x0200'u16
  of 0x070:
    # W_TXBUF_WR_DATA: store and advance
    let wa = int(w.reg(0x068))
    w.ram[(wa shr 1) and 0xFFF] = v
    var na = (wa + 2) and 0x1FFE
    if na == int(w.reg(0x074)): na = (na + 2 * int(w.reg(0x076))) and 0x1FFE
    w.reg(0x068) = uint16(na)
    if w.reg(0x06C) > 0:
      w.reg(0x06C) = w.reg(0x06C) - 1
      if w.reg(0x06C) == 0: w.set_if(1'u16 shl 8)
  of 0x0AC:
    w.reg(0x0B0) = w.reg(0x0B0) and not (v and 0xF)
  of 0x0AE:
    w.reg(0x0B0) = w.reg(0x0B0) or (v and 0xF)
    w.start_tx()
  of 0x0B4:
    for (bit, r) in [(0, 0x0A0), (1, 0x090), (2, 0x0A4), (3, 0x0A8), (6, 0x098), (7, 0x094)]:
      if (v and (1'u16 shl bit)) != 0: w.reg(r) = w.reg(r) and 0x7FFF
  of 0x0A0, 0x0A4, 0x0A8, 0x090:
    w.reg(o) = v
    w.start_tx()
  of 0x0BC:
    w.reg(o) = v and 3
  of 0x0E8:
    w.reg(o) = v and 1
    w.latch_counter()
  of 0x0EA:
    w.reg(o) = v and 1
    if (v and 2) != 0: w.beacon_irq(true)
  of 0x0F8, 0x0FA, 0x0FC, 0x0FE:
    let sh = uint64((o - 0x0F8) * 8)
    let cur = w.us_now()
    w.us_base = (cur and not (0xFFFF'u64 shl sh)) or (uint64(v) shl sh)
    w.us_base_at = w.sched.now
    w.latch_counter()
  of 0x158:
    w.reg(o) = v
    w.bb_transfer(v)
  of 0x17C:
    w.reg(o) = v
    w.rf_transfer()
  else:
    let m = w.masks[o shr 1]
    w.reg(o) = (old and not m) or (v and m)
