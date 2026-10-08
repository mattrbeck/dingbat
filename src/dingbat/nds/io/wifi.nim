## ARM7 wifi block at 0x04800000-0x0480FFFF: MAC registers (0x4808000 +
## 0x000-0xFFF, mirrored), 8 KB of wifi RAM at 0x04804000, the baseband (BB)
## and RF chips behind their serial ports. GBATEK "DS Wifi ...";
## docs/nds/wifi.md is the map of what is modelled and why.
##
## The parts software waits on: register widths and reset values, the IRQ
## flags and their IF.24 edge, power-state requests, the microsecond counter
## with its compare / beacon-count / post-beacon interrupts, the BB and RF
## register files, the TX/RX buffer ports. On top of that a transmitter
## (LOC1-3, beacons, the multiplay CMD -> REPLY -> ACK round) that puts
## frames on an `Air`, and a receiver that takes frames off it through the
## address/BSSID filters into the RX ring with the hardware RX header.
##
## The `Air` is the radio: the consoles of one process that share one, each
## running on its own scheduler in lockstep (nds/air.nim), with frames
## carried by air time. A frame is posted when its preamble starts and acts
## on a receiver only after its preamble (96 us at the least), so consoles
## stepped in quanta shorter than that see each other's frames at their
## exact times. Without an Air nothing is received and unicast frames run out
## of retries, as on a console alone.

import std/bitops
import ../sched
import irq
import ../quirky

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: nds_quirky.}
when defined(wifilog): import std/strutils

const
  WIFI_REGS = 0x800            ## halfwords in 0x000-0xFFF

type
  FrameKind* = enum
    fkLoc        ## W_TXBUF_LOC1-3: whatever software built
    fkBeacon     ## W_TXBUF_BEACON, timestamp filled in by the hardware
    fkCmd        ## multiplay CMD (W_TXBUF_CMD)
    fkCmdAck     ## multiplay ACK, built by the host's hardware
    fkReply      ## multiplay REPLY (W_TXBUF_REPLY2, or the hardware's empty one)

  AirFrame* = ref object
    ## One transmission, as every receiver on the channel sees it.
    sender*: int                    ## station index on the Air
    serial*: int                    ## sender's transmit number (ACK matching)
    kind*: FrameKind
    channel*: int                   ## 1-14; 0 = unknown, heard on every channel
    rate*: uint16                   ## TX header rate: 14h = 2 Mbit/s, else 1 Mbit/s
    aid*: int                       ## REPLY: the sender's W_AID_LOW
    start*, data_at*, stop*: int64  ## air clock: carrier on, data after the preamble, end
    bytes*: seq[uint8]              ## IEEE header + body as received (no FCS)

  Air* = ref object
    ## The radio medium shared by the consoles of one process.
    stations*: seq[Wifi]
    frames*: int                    ## frames put on the air
    late*: int                      ## frames that reached a receiver already past them

  RxSlot = object
    f: AirFrame
    start_at, end_at: int64         ## local cycles: data starts (IRQ06), frame ends
    started: bool

  TxStage = enum
    tsIdle, tsPreamble, tsData, tsAckWait, tsReplies

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
    cmd_count_at: int64           ## W_CMD_COUNT was last latched here
    short_preamble: bool          ## W_PREAMBLE bit 2 (write-only)
    # transmitter: one frame at a time
    tx_src: int                   ## -1 idle; 0 LOC1, 1 CMD, 2 LOC2, 3 LOC3 (W_TXREQ
                                  ## bit order), 4 beacon, 5 REPLY, 6 multiplay ACK
    tx_stage: TxStage
    tx_at: int64                  ## local cycle the stage ends
    tx_hdr: int                   ## TX header halfword address (-1: hardware-built frame)
    tx_frame: AirFrame
    tx_serial: int
    tx_acked: bool
    beacon_due: bool              ## IRQ14 asked for a beacon, not sent yet
    mp_mask, mp_replied: uint16   ## host: slaves a CMD addressed / heard from
    reply_at: int64               ## slave: its REPLY slot starts (-1 = none)
    reply_bssid: array[6, uint8]  ## slave: the host that sent the CMD
    # receiver
    rx: seq[RxSlot]
    # the radio
    air* {.cursor.}: Air
    station*: int
    air_offset*: int64            ## air clock = local master clock + offset
    channel*: int                 ## from the RF channel registers (0 = unknown)
    tx_frames*, rx_frames*: int   ## frames sent / stored in the RX ring (diagnostics)
    firmware*: seq[uint8]         ## firmware image: channel table (attach)
    when defined(wifilog):
      log_last: string
      log_repeat: int

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

  # W_RXSTAT counter n (W_RXSTAT_INC_IF bit n) lives at this byte address
  # (GBATEK "DS Wifi Receive Statistics")
  RXSTAT_BYTES = [0x1B0, 0x1B2, 0x1B3, 0x1B4, 0x1B5, 0x1B6, 0x1B7, 0x1B8, 0x1BA,
                  0x1BC, 0x1BD, 0x1BE, 0x1BF]
  STAT_RXBUF_FULL = 3
  STAT_RX_OK = 6

  US_PER_MS = 1024'i64          ## the "millisecond" of the beacon counters

  # Air timing in microseconds. The preambles and bit rates are GBATEK's
  # (W_PREAMBLE, TX header rate); 802.11b's 10-us SIFS spaces an ACK or a
  # multiplay reply from the frame before it (Assumed: GBATEK gives no gap).
  LONG_PREAMBLE_US = 192'i64
  SHORT_PREAMBLE_US = 96'i64
  SIFS_US = 10'i64
  ACK_BYTES = 14                ## 802.11 ACK: FC, duration, RA, FCS
  # Multiplay host: replies are awaited 16 + (10 + W_CMD_REPLYTIME) us per
  # slave after the CMD (GBATEK "DS Wifi Multiplay Master").
  MP_REPLY_LEAD_US = 16'i64
  MP_REPLY_GAP_US = 10'i64
  # RX header RSSI bytes (max, min). Assumed: a strong, steady signal.
  RX_RSSI = 0x30C1'u16

  MP_CMD_ACK_DA = [0x03'u8, 0x09, 0xBF, 0x00, 0x00, 0x03]  ## GBATEK, Download Play
  MP_REPLY_DA = [0x03'u8, 0x09, 0xBF, 0x00, 0x00, 0x10]

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
  result = Wifi(sched: sched, irq: irq, random: 1, irq15_at: -1, tx_src: -1,
                reply_at: -1)
  for i in 0 ..< WIFI_REGS: result.masks[i] = 0xFFFF
  for (o, m) in MASK_TABLE: result.masks[o shr 1] = m
  for (o, v) in RESET_VALUES: result.regs[o shr 1] = v
  # BB chip: reads the chip ID at 00h, 01h at 5Dh (GBATEK BB table); the
  # firmware bootcode's other settings are not reproduced (Assumed: 0)
  result.bb[0x00] = 0x6D
  result.bb[0x5D] = 0x01

# ---------------------------------------------------------------------------
# Wifi RAM and addresses

proc ram8(w: Wifi; b: int): uint8 =
  let h = w.ram[(b shr 1) and 0xFFF]
  uint8(if (b and 1) == 0: h and 0xFF else: h shr 8)

proc set_ram8(w: Wifi; b: int; v: uint8) =
  let i = (b shr 1) and 0xFFF
  w.ram[i] = if (b and 1) == 0: (w.ram[i] and 0xFF00) or uint16(v)
             else: (w.ram[i] and 0x00FF) or (uint16(v) shl 8)

proc reg_mac(w: Wifi; o: int): array[6, uint8] =
  ## W_MACADDR / W_BSSID: three halfwords, first byte in the low half.
  for i in 0..2:
    let h = w.reg(o + 2 * i)
    result[2 * i] = uint8(h and 0xFF)
    result[2 * i + 1] = uint8(h shr 8)

proc addr_is(b: openArray[uint8]; at: int; a: openArray[uint8]): bool =
  if b.len < at + 6: return false
  for i in 0..5:
    if b[at + i] != a[i]: return false
  true

proc put_addr(b: var seq[uint8]; at: int; a: openArray[uint8]) =
  for i in 0..5: b[at + i] = a[i]

proc put16(b: var seq[uint8]; at: int; v: uint16) =
  b[at] = uint8(v and 0xFF)
  b[at + 1] = uint8(v shr 8)

proc get16(b: openArray[uint8]; at: int): uint16 =
  if b.len < at + 2: 0'u16 else: uint16(b[at]) or (uint16(b[at + 1]) shl 8)

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

proc stat_inc(w: Wifi; n: int) =
  ## One W_RXSTAT event: its 8-bit counter, the increment flag (IRQ02 when
  ## enabled), and the half-overflow flag at bit 7 (IRQ04).
  let a = RXSTAT_BYTES[n]
  let sh = (a and 1) * 8
  var v = (w.reg(a and not 1) shr sh) and 0xFF
  if v < 0xFF: inc v
  w.reg(a and not 1) = (w.reg(a and not 1) and not (0xFF'u16 shl sh)) or (v shl sh)
  let bit = 1'u16 shl n
  w.reg(0x1A8) = w.reg(0x1A8) or bit
  if (w.reg(0x1AA) and bit) != 0: w.set_if(1'u16 shl 2)
  if v >= 0x80:
    w.reg(0x1AC) = w.reg(0x1AC) or bit
    if (w.reg(0x1AE) and bit) != 0: w.set_if(1'u16 shl 4)

proc tx_error(w: Wifi) =
  ## W_TX_ERR_COUNT: IRQ03 per increment, IRQ05 past 7Fh (GBATEK, Transmit Errors)
  if w.reg(0x1C0) < 0xFF: w.reg(0x1C0) = w.reg(0x1C0) + 1
  var bits = 1'u16 shl 3
  if w.reg(0x1C0) > 0x7F: bits = bits or (1'u16 shl 5)
  w.set_if(bits)

# ---------------------------------------------------------------------------
# Microsecond counter, the beacon timers and W_CMD_COUNT

proc us_now(w: Wifi): uint64 =
  if not w.us_running: return w.us_base
  w.us_base + uint64(cycles_to_us(w.sched.now) - cycles_to_us(w.us_base_at))

proc counter_on(w: Wifi): bool =
  (w.reg(0x0E8) and 1) != 0 and (w.reg(0x036) and 1) == 0

proc reschedule(w: Wifi) =
  var at = high(int64)
  if w.us_running: at = min(at, w.next_ms)
  if w.irq15_at >= 0: at = min(at, w.irq15_at)
  if w.tx_stage != tsIdle: at = min(at, w.tx_at)
  if w.reply_at >= 0: at = min(at, w.reply_at)
  for s in w.rx:
    at = min(at, if s.started: s.end_at else: s.start_at)
  if at == high(int64): w.sched.cancel(evWifi)
  else: w.sched.schedule(max(at, w.sched.now), evWifi)

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

proc cmd_count(w: Wifi): uint16 =
  ## W_CMD_COUNT: down one every 10 us while W_CMD_COUNTCNT is set, stopping
  ## at zero (GBATEK "DS Wifi Multiplay Master").
  let v = w.reg(0x118)
  if (w.reg(0x0EE) and 1) == 0 or v == 0: return v
  let steps = (cycles_to_us(w.sched.now) - cycles_to_us(w.cmd_count_at)) div 10
  uint16(max(0'i64, int64(v) - steps))

proc latch_cmd_count(w: Wifi) =
  w.reg(0x118) = w.cmd_count()
  w.cmd_count_at = w.sched.now

proc start_tx(w: Wifi)

proc wake_rx(w: Wifi) =
  ## RF on and listening: W_RF_PINS RX.ON (bit 7; bit 2 reads high) and
  ## W_RF_STATUS 1 (GBATEK "DS Wifi Status", IRQ01 notes).
  w.reg(0x19C) = 0x0084
  w.reg(0x214) = 1

proc beacon_irq(w: Wifi; forced: bool) =
  ## IRQ14 (GBATEK "IRQ14 Notes").
  if not forced: w.reg(0x11C) = w.reg(0x08C)
  if (w.reg(0x0EA) and 1) != 0 or forced:
    w.reg(0x134) = 0xFFFF
    w.reg(0x0B0) = w.reg(0x0B0) and 0xFFF2'u16
    if w.reg(0x088) == 0: w.reg(0x088) = w.reg(0x08E)
    w.reg(0x088) = (w.reg(0x088) - 1) and 0xFF
    w.set_if(1'u16 shl 14)
    if (w.reg(0x080) and 0x8000) != 0:
      # the beacon goes out in this timeslot
      w.reg(0x0B6) = w.reg(0x0B6) or 0x0010
      w.beacon_due = true
      w.start_tx()

proc post_beacon_irq(w: Wifi) =
  w.set_if(1'u16 shl 13)
  if (w.reg(0x038) and 2) == 0:
    # auto sleep (GBATEK "IRQ13 Notes")
    w.reg(0x034) = 2
    w.reg(0x03C) = w.reg(0x03C) or 0x0200
    w.reg(0x19C) = 0x0046
    w.reg(0x214) = 9

proc pre_beacon_irq(w: Wifi) =
  ## IRQ15 (GBATEK "IRQ15 Notes"): with W_POWER_TX bit 0 the RF also wakes
  ## to receive the coming beacon (Assumed: at once, and the power state
  ## with it).
  if (w.reg(0x0EA) and 1) != 0: w.set_if(1'u16 shl 15)
  if (w.reg(0x038) and 1) != 0 and (w.reg(0x004) and 1) != 0 and
     (w.reg(0x036) and 1) == 0 and w.tx_src < 0:
    w.reg(0x03C) = w.reg(0x03C) and not 0x0300'u16
    w.wake_rx()

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
      if w.reg(0x110) == 0: w.pre_beacon_irq()
      w.beacon_irq(false)
    elif w.reg(0x11C) == 1 and w.reg(0x110) != 0:
      # IRQ15 comes W_PRE_BEACON microseconds before the next boundary
      let lead = min(int64(w.reg(0x110)), US_PER_MS)
      w.irq15_at = w.next_ms + us_to_cycles(US_PER_MS - lead)
  if w.reg(0x134) != 0:
    w.reg(0x134) = w.reg(0x134) - 1
    if w.reg(0x134) == 0: w.post_beacon_irq()

# ---------------------------------------------------------------------------
# The Air

proc new_air*(): Air = Air()

proc air_now(w: Wifi): int64 = w.sched.now + w.air_offset

proc attach*(w: Wifi; air: Air; firmware: seq[uint8]; offset = 0'i64) =
  ## Put this console on `air`. `firmware` gives the RF channel table;
  ## `offset` maps its master clock to the air clock.
  w.air = air
  w.station = air.stations.len
  w.air_offset = offset
  w.firmware = firmware
  air.stations.add w

proc queue_rx(w: Wifi; f: AirFrame) =
  ## A frame starts on the air: if this console is on its channel, its
  ## preamble end and its end become receiver events.
  if f.channel != 0 and w.channel != 0 and f.channel != w.channel: return
  var s = RxSlot(f: f, start_at: f.data_at - w.air_offset, end_at: f.stop - w.air_offset)
  if s.start_at < w.sched.now:
    inc w.air.late
    s.start_at = w.sched.now
    s.end_at = max(s.end_at, s.start_at)
  w.rx.add s
  w.reschedule()

proc post(air: Air; f: AirFrame) =
  inc air.frames
  for s in air.stations:
    if s.station != f.sender: s.queue_rx(f)

proc got_ack(w: Wifi; serial: int) =
  if w.tx_frame != nil and w.tx_frame.serial == serial: w.tx_acked = true

# ---------------------------------------------------------------------------
# Transmit

proc loc_reg(i: int): int =
  case i
  of 0: 0x0A0
  of 1: 0x090
  of 2: 0x0A4
  else: 0x0A8

proc air_us(rate: uint16; nbytes: int): int64 =
  ## Data time at the TX header's rate (GBATEK: 14h = 2 Mbit/s, anything
  ## else 1 Mbit/s).
  if rate == 0x14: int64(nbytes) * 4 else: int64(nbytes) * 8

proc preamble_us(w: Wifi; rate: uint16): int64 =
  ## Short preamble only at 2 Mbit/s with W_PREAMBLE bit 2 (GBATEK).
  if rate == 0x14 and w.short_preamble: SHORT_PREAMBLE_US else: LONG_PREAMBLE_US

proc frame_at(w: Wifi; hdr: int): tuple[bytes: seq[uint8], rate: uint16] =
  ## The IEEE frame behind TX header `hdr` (halfword address): header
  ## [08h] rate, [0Ah] length including the 4-byte FCS (GBATEK "DS Wifi
  ## Hardware Headers"). The FCS is the hardware's; receivers get the rest.
  let base = hdr * 2
  result.rate = uint16(w.ram8(base + 8))
  let n = max(0, int(w.ram[(hdr + 5) and 0xFFF] and 0x3FFF) - 4)
  result.bytes = newSeq[uint8](n)
  for k in 0 ..< n: result.bytes[k] = w.ram8(base + 12 + k)

proc next_seqno(w: Wifi): uint16 =
  ## W_TX_SEQNO * 10h for the IEEE sequence control, then increment.
  result = (w.reg(0x210) and 0xFFF) shl 4
  w.reg(0x210) = (w.reg(0x210) + 1) and 0xFFF

proc begin_tx(w: Wifi; src, hdr: int; bytes: sink seq[uint8]; rate: uint16; kind: FrameKind) =
  ## The carrier goes on: preamble, then data (IRQ07), then the stage the
  ## source needs. The frame is on the air from now.
  let now = w.sched.now
  let pre = w.preamble_us(rate)
  inc w.tx_serial
  var b = bytes
  if b.len >= 1: b[0] = b[0] and 0xFC   # protocol version forced to 0 (GBATEK, IEEE Header)
  let f = AirFrame(sender: w.station, serial: w.tx_serial, kind: kind, channel: w.channel,
                   rate: rate, aid: int(w.reg(0x028) and 0xF), bytes: b)
  f.start = now + w.air_offset
  f.data_at = f.start + us_to_cycles(pre)
  f.stop = f.data_at + us_to_cycles(air_us(rate, b.len + 4))
  w.tx_src = src
  w.tx_hdr = hdr
  w.tx_frame = f
  w.tx_acked = false
  w.tx_stage = tsPreamble
  w.tx_at = f.data_at - w.air_offset
  inc w.tx_frames
  w.reg(0x214) = 3                      # W_RF_STATUS: TX
  w.reg(0x19C) = 0x0044                 # TX.ON, RX.ON low (data phase not yet)
  if w.air != nil: w.air.post(f)
  w.reschedule()

proc start_tx(w: Wifi) =
  ## Begin the next transfer, if idle: a beacon in its timeslot first, then
  ## the requested LOC3, LOC2, CMD, LOC1 (GBATEK W_TXREQ_READ).
  if w.tx_src >= 0: return
  if (w.reg(0x004) and 1) == 0 or (w.reg(0x03C) and 0x0200) != 0: return
  if w.beacon_due:
    w.beacon_due = false
    if (w.reg(0x080) and 0x8000) != 0:
      let hdr = int(w.reg(0x080) and 0xFFF)
      var (b, rate) = w.frame_at(hdr)
      if b.len >= 24:
        let s = w.next_seqno()
        w.set_ram8(hdr * 2 + 12 + 22, uint8(s and 0xFF))
        w.set_ram8(hdr * 2 + 12 + 23, uint8(s shr 8))
        b.put16(22, s)
      if b.len >= 32:
        # the 64-bit timestamp: the sender's W_US_COUNT, in the sent copy
        # only (GBATEK, IEEE Header 3). Assumed: as the data starts.
        let ts = w.us_now() + uint64(w.preamble_us(rate))
        for k in 0..7: b[24 + k] = uint8((ts shr (8 * k)) and 0xFF)
      w.begin_tx(4, hdr, b, rate, fkBeacon)
      return
    w.reg(0x0B6) = w.reg(0x0B6) and not 0x0010'u16
  let req = w.reg(0x0B0)
  for i in [3, 2, 1, 0]:
    let lr = loc_reg(i)
    if (req and (1'u16 shl i)) == 0 or (w.reg(lr) and 0x8000) == 0: continue
    if i == 1 and w.cmd_count() == 0: continue
    let hdr = int(w.reg(lr) and 0xFFF)
    var (b, rate) = w.frame_at(hdr)
    # sequence control from W_TX_SEQNO unless LOCn bit 13, TXHDR[04h] or
    # W_TX_HDR_CNT bit 2 say otherwise (GBATEK W_TX_SEQNO)
    if b.len >= 24 and (w.reg(lr) and 0x2000) == 0 and w.ram8(hdr * 2 + 4) == 0 and
       (w.reg(0x194) and 4) == 0:
      let s = w.next_seqno()
      w.set_ram8(hdr * 2 + 12 + 22, uint8(s and 0xFF))
      w.set_ram8(hdr * 2 + 12 + 23, uint8(s shr 8))
      b.put16(22, s)
    w.reg(0x0B6) = w.reg(0x0B6) or (1'u16 shl i)
    w.begin_tx(i, hdr, b, rate, if i == 1: fkCmd else: fkLoc)
    return

proc tx_idle(w: Wifi) =
  ## The transmitter is free again: back to receiving (GBATEK IRQ01 notes).
  w.tx_src = -1
  w.tx_stage = tsIdle
  w.wake_rx()
  w.start_tx()

proc needs_ack(f: AirFrame): bool =
  ## Frames to a station (not a group address) wait for its ACK, control
  ## frames excepted (GBATEK "DS Wifi Transmit Errors").
  f.bytes.len >= 10 and (f.bytes[4] and 1) == 0 and ((f.bytes[0] shr 2) and 3) != 1

proc loc_done(w: Wifi; ok: bool) =
  ## End of a LOC transfer attempt: retried on a missing ACK while
  ## W_TX_RETRYLIMIT lasts, else IRQ01 with W_TXSTAT and TX header status
  ## (0001h okay, 0003h failed).
  let i = w.tx_src
  let lr = loc_reg(i)
  let hdr = w.tx_hdr
  if not ok:
    w.tx_error()
    let left = w.reg(0x02C) and 0xFF
    if left > 0:
      w.reg(0x02C) = (w.reg(0x02C) and 0xFF00) or (left - 1)
      w.set_if(1'u16 shl 1)               # IRQ01 for every attempt
      let f = w.tx_frame
      w.tx_src = -1
      w.begin_tx(i, hdr, f.bytes, f.rate, fkLoc)
      return
  w.ram[hdr and 0xFFF] = if ok: 0x0001'u16 else: 0x0003'u16
  w.ram[(hdr + 2) and 0xFFF] = w.ram[(hdr + 2) and 0xFFF] and 0x00FF'u16  # [05h] = 0
  var stat = 0x0001'u16 or (if ok: 0'u16 else: 2'u16)
  if i == 2: stat = stat or 0x1000
  elif i == 3: stat = stat or 0x2000
  if (w.reg(lr) and 0x1000) != 0: stat = stat or 0x0700
  w.reg(0x0B8) = stat
  w.reg(lr) = w.reg(lr) and 0x7FFF
  w.reg(0x0B6) = w.reg(0x0B6) and not (1'u16 shl i)
  w.set_if(1'u16 shl 1)
  w.tx_idle()

proc send_mp_ack(w: Wifi) =
  ## Multiplay host, the replies' time is up: the hardware's ACK frame to
  ## 03:09:BF:00:00:03, body [02h] = slaves that did not answer (GBATEK
  ## "CMD ACK"; body [00h] Assumed 0).
  let mac = w.reg_mac(0x018)
  var b = newSeq[uint8](28)
  b.put16(0, 0x0218)
  b.put_addr(4, MP_CMD_ACK_DA)
  b.put_addr(10, mac)
  b.put_addr(16, mac)
  b.put16(22, (w.reg(0x210) and 0xFFF) shl 4)
  b.put16(26, w.mp_mask and not w.mp_replied)
  let rate = w.tx_frame.rate
  w.tx_src = -1
  w.begin_tx(6, w.tx_hdr, b, rate, fkCmdAck)

proc tx_data_done(w: Wifi) =
  ## The last bit is out (IRQ01 notes: TX.ON drops).
  let f = w.tx_frame
  let stat_cnt = w.reg(0x008)
  case w.tx_src
  of 0, 2, 3:
    if needs_ack(f):
      # the ACK would come a SIFS later at this rate (long preamble)
      w.tx_stage = tsAckWait
      w.tx_at = w.sched.now + us_to_cycles(SIFS_US + LONG_PREAMBLE_US + air_us(f.rate, ACK_BYTES))
      w.wake_rx()
      w.reschedule()
    else:
      w.loc_done(true)
  of 1:
    # multiplay CMD (GBATEK "Multiplay Master" flowchart): optional IRQ01,
    # then the replies' time, slaves from the frame body's second halfword
    if (stat_cnt and 0x4000) != 0:
      w.reg(0x0B8) = 0x0800
      w.set_if(1'u16 shl 1)
    w.mp_mask = get16(f.bytes, 26) and 0xFFFE
    w.mp_replied = 0
    let n = int64(countSetBits(w.mp_mask))
    w.wake_rx()
    w.reg(0x214) = 5
    w.tx_stage = tsReplies
    w.tx_at = w.sched.now + us_to_cycles(MP_REPLY_LEAD_US +
                                         (MP_REPLY_GAP_US + int64(w.reg(0x0C4))) * n)
    w.reschedule()
  of 4:
    w.ram[w.tx_hdr and 0xFFF] = 0x0001
    if (stat_cnt and 0x8000) != 0:
      w.reg(0x0B8) = 0x0301
      w.set_if(1'u16 shl 1)
    w.reg(0x0B6) = w.reg(0x0B6) and not 0x0010'u16
    w.tx_idle()
  of 5:
    let r2 = w.reg(0x098)
    if (stat_cnt and 0x1000) != 0 and (r2 and 0x8000) != 0:
      w.reg(0x0B8) = 0x0401
      w.set_if(1'u16 shl 1)
    if (r2 and 0x8000) == 0: discard w.next_seqno()
    w.tx_idle()
  of 6:
    # the round is over: IRQ01 (optional), CMD header status, IRQ12
    if (stat_cnt and 0x2000) != 0:
      w.reg(0x0B8) = 0x0B01
      w.set_if(1'u16 shl 1)
    let errors = w.mp_mask and not w.mp_replied
    let hdr = w.tx_hdr
    w.ram[hdr and 0xFFF] = if errors == 0: 0x0001'u16 else: 0x0005'u16
    w.ram[(hdr + 1) and 0xFFF] = errors
    for slave in 1..15:
      if (errors and (1'u16 shl slave)) != 0:
        # W_CMD_STAT: per-slave missing-reply counters at 1D0h + slave
        let a = 0x1D0 + slave
        let sh = (a and 1) * 8
        let v = (w.reg(a and not 1) shr sh) and 0xFF
        if v < 0xFF:
          w.reg(a and not 1) = (w.reg(a and not 1) and not (0xFF'u16 shl sh)) or ((v + 1) shl sh)
    w.reg(0x090) = w.reg(0x090) and 0x7FFF
    w.reg(0x0B6) = w.reg(0x0B6) and not 0x0002'u16
    discard w.next_seqno()
    w.set_if(1'u16 shl 12)
    w.tx_idle()
  else:
    w.tx_idle()

proc tx_step(w: Wifi) =
  case w.tx_stage
  of tsPreamble:
    # IRQ07: the preamble is out, data starts (TX.MAIN)
    w.reg(0x19C) = 0x0046
    w.set_if(1'u16 shl 7)
    w.tx_stage = tsData
    w.tx_at = w.tx_frame.stop - w.air_offset
  of tsData: w.tx_data_done()
  of tsAckWait: w.loc_done(w.tx_acked)
  of tsReplies: w.send_mp_ack()
  of tsIdle: discard

proc send_reply(w: Wifi) =
  ## Multiplay slave, its slot: REPLY2's frame, or the hardware's empty
  ## reply (FC 0158h) when there is none (GBATEK "Multiplay Slave").
  ## Assumed: a slot that finds the transmitter busy is missed.
  w.reply_at = -1
  if w.tx_src >= 0: return
  let r2 = w.reg(0x098)
  if (r2 and 0x8000) != 0:
    let hdr = int(r2 and 0xFFF)
    var (b, rate) = w.frame_at(hdr)
    if b.len >= 24: b.put16(22, (w.reg(0x210) and 0xFFF) shl 4)
    w.begin_tx(5, hdr, b, rate, fkReply)
  else:
    var b = newSeq[uint8](24)
    b.put16(0, 0x0158)
    b.put_addr(4, w.reply_bssid)
    b.put_addr(10, w.reg_mac(0x018))
    b.put_addr(16, MP_REPLY_DA)
    b.put16(22, (w.reg(0x210) and 0xFFF) shl 4)
    w.begin_tx(5, -1, b, 0x14, fkReply)

# ---------------------------------------------------------------------------
# Receive

proc rx_on(w: Wifi): bool =
  ## Receiving: RF on in RX mode (W_RF_PINS RX.ON) with W_RXCNT bit 15.
  (w.reg(0x19C) and 0x80) != 0 and (w.reg(0x030) and 0x8000) != 0

proc rx_store(w: Wifi; f: AirFrame; flags: uint16): bool =
  ## Write RX header + frame at W_RXBUF_WRCSR, wrapping END -> BEGIN, then
  ## move WRCSR past it (4-byte aligned). A frame that would reach
  ## W_RXBUF_READCSR is dropped (GBATEK "DS Wifi Receive Buffer"); one
  ## halfword stays free so a full ring never reads as empty (Assumed).
  let lo = int((w.reg(0x050) shr 1) and 0xFFF)
  let hi = int((w.reg(0x052) shr 1) and 0xFFF)
  if hi <= lo: return false
  var wr = int(w.reg(0x054) and 0xFFF)
  let rd = int(w.reg(0x05A) and 0xFFF)
  let n = f.bytes.len
  let total = (12 + ((n + 3) and not 3)) div 2
  let size = hi - lo
  let used = if wr >= rd: wr - rd else: size - (rd - wr)
  if total >= size - used:
    w.stat_inc(STAT_RXBUF_FULL)
    return false
  template put(v: uint16) =
    w.ram[wr and 0xFFF] = v
    inc wr
    if wr == hi: wr = lo
  put(flags)
  put(0x0040)                     # [02h]: 0040h normal (GBATEK RXHDR)
  inc wr                          # [04h]: not written by the hardware
  if wr == hi: wr = lo
  put(f.rate)                     # [06h]: rate in 100 kbit/s units
  put(uint16(n))                  # [08h]: IEEE header + body, no FCS
  put(RX_RSSI)                    # [0Ah] max RSSI, [0Bh] min RSSI
  var k = 0
  while k < n:
    let hi8 = if k + 1 < n: uint16(f.bytes[k + 1]) else: 0'u16
    put(uint16(f.bytes[k]) or (hi8 shl 8))
    k += 2
  if ((n + 1) div 2) mod 2 == 1:   # pad to a word
    inc wr
    if wr == hi: wr = lo
  w.reg(0x054) = uint16(wr)
  true

proc mp_slave_cmd(w: Wifi; f: AirFrame; at: int64) =
  ## A multiplay CMD arrived at a slave (W_AID_LOW != 0): REPLY1 moves to
  ## REPLY2 and the reply is sent in this slave's slot (GBATEK "Multiplay
  ## Slave" flowchart). Slot k (k = slaves with a lower number in the CMD's
  ## mask) starts SIFS + k * (per-slave time + 10 us) after the CMD
  ## (Assumed: the host's wait, 16 + (10 + time) * n, leaves room for it).
  w.reg(0x214) = 5
  let old2 = w.reg(0x098)
  if (old2 and 0x8000) != 0:
    let h = int(old2 and 0xFFF)
    w.ram[h] = ((w.ram[h] and 0xFF) shl 8) or 0x01   # TXHDR[1] = TXHDR[0], [0] = 01h
  let r1 = w.reg(0x094)
  w.reg(0x098) = r1
  w.reg(0x094) = 0
  if (r1 and 0x8000) != 0:
    let h = (int(r1 and 0xFFF) + 2) and 0xFFF
    w.ram[h] = min(0xFF'u16, (w.ram[h] and 0xFF) + 1)  # [04h] + 1, [05h] = 0
    discard w.next_seqno()
  let b = f.bytes
  if b.len < 28: return
  let aid = int(w.reg(0x028) and 0xF)
  let mask = get16(b, 26)
  if (mask and (1'u16 shl aid)) == 0: return
  let per = int64(get16(b, 24))
  let k = int64(countSetBits(mask and ((1'u16 shl aid) - 1) and 0xFFFE))
  for i in 0..5: w.reply_bssid[i] = b[10 + i]
  w.reply_at = at + us_to_cycles(SIFS_US + k * (per + MP_REPLY_GAP_US))
  w.reschedule()

proc deliver(w: Wifi; f: AirFrame; at: int64) =
  ## A frame ended at this receiver: address and BSSID filters, the RX ring,
  ## IRQ00, the ACK a station frame earns, multiplay bookkeeping.
  let b = f.bytes
  if b.len < 10 or not w.rx_on(): return
  let fc = get16(b, 0)
  let ftype = int((fc shr 2) and 3)
  let sub = int((fc shr 4) and 0xF)
  let tods = (fc and 0x0100) != 0
  let fromds = (fc and 0x0200) != 0
  # receiver address: own MAC, or a group address (GBATEK W_MACADDR)
  let own = addr_is(b, 4, w.reg_mac(0x018))
  let group = (b[4] and 1) != 0
  if not own and not group: return
  if own and f.kind == fkReply and w.tx_src == 1 and w.tx_stage == tsReplies:
    w.mp_replied = w.mp_replied or ((1'u16 shl f.aid) and w.mp_mask)
  # RXHDR[00h] frame type (GBATEK "Hardware RX Header")
  var t: uint16
  case ftype
  of 0: t = if sub == 8: 1 else: 0
  of 1:
    if sub != 0xA: return          # only PS-poll is stored; ACKs and the like are not
    t = 5
  of 2:
    case fc and 0x03FC
    of 0x0228: t = 0xC              # CMD
    of 0x0218: t = 0xD              # CMD ACK
    of 0x0118: t = 0xE              # REPLY
    of 0x0158: t = 0xF              # empty REPLY
    else: t = if b.len <= 24: 0xF else: 8
  else: return
  # BSSID by the DS bits: none set addr3, FromDS addr2, ToDS addr1
  let bss_at = if ftype == 1: 4
               elif not tods and not fromds: 16
               elif fromds and not tods: 10
               elif tods and not fromds: 4
               else: -1
  let bss_match = bss_at >= 0 and addr_is(b, bss_at, w.reg_mac(0x020))
  let filt = w.reg(0x0D0)
  if group and not bss_match:
    # another BSS's broadcast: W_RXFILTER bit 0 (GBATEK), or the per-type
    # bits 9/10 (management) and 11 (control/data) of dswifi's registers.h
    let typebit = if ftype == 0: (if sub == 8: 0'u16 else: 0x0600'u16) else: 0x0800'u16
    if (filt and (1'u16 or typebit)) == 0: return
  if t == 0xD and (filt and 0x0080) == 0: return
  if t == 0xF and (filt and 0x0100) == 0: return
  if ftype == 2:
    # W_RXFILTER2: drop data frames by their DS direction (dswifi registers.h)
    let bit = if tods and fromds: 8'u16 elif fromds: 4'u16 elif tods: 2'u16 else: 1'u16
    if (w.reg(0x0E0) and bit) != 0: return
  if t == 0xC and (w.reg(0x028) and 0xF) != 0: w.mp_slave_cmd(f, at)
  var flags = t or 0x0010
  if bss_match: flags = flags or 0x8000
  if (get16(b, 22) and 0xF) != 0 or (fc and 0x0400) != 0: flags = flags or 0x0200
  if (fc and 0x0400) != 0: flags = flags or 0x0100
  if not w.rx_store(f, flags): return
  inc w.rx_frames
  w.stat_inc(STAT_RX_OK)
  w.reg(0x1C4) = (w.reg(0x1C4) and 0xFF00) or min(0xFF'u16, (w.reg(0x1C4) and 0xFF) + 1)
  if (w.reg(0x220) and 0x20) == 0:
    # the hardware's log at 5F6Eh..5F77h (GBATEK, Wifi RAM)
    w.ram[0xFB7] = 0x0F01
    for i in 0..2: w.ram[0xFB8 + i] = get16(b, 10 + 2 * i)
    w.ram[0xFBB] = get16(b, 22)
  w.set_if(1'u16 shl 0)
  if own and ftype != 1 and t notin [0xC'u16, 0xD, 0xE, 0xF] and w.air != nil and
     f.sender < w.air.stations.len:
    # the hardware ACKs a station frame by itself
    w.air.stations[f.sender].got_ack(f.serial)

# ---------------------------------------------------------------------------
# Events

proc on_event*(w: Wifi) =
  ## evWifi: receptions due, the reply slot, the transmit stage, IRQ15 and
  ## the millisecond ticks, in that order.
  let now = w.sched.now
  var i = 0
  while i < w.rx.len:
    if not w.rx[i].started and w.rx[i].start_at <= now:
      w.rx[i].started = true
      if w.rx_on(): w.set_if(1'u16 shl 6)      # IRQ06: receive starts
    if w.rx[i].started and w.rx[i].end_at <= now:
      let s = w.rx[i]
      w.rx.delete(i)
      w.deliver(s.f, s.end_at)
    else:
      inc i
  if w.reply_at >= 0 and w.reply_at <= now: w.send_reply()
  if w.tx_stage != tsIdle and w.tx_at <= now: w.tx_step()
  if w.irq15_at >= 0 and w.irq15_at <= now:
    w.irq15_at = -1
    w.pre_beacon_irq()
  while w.us_running and w.next_ms <= now:
    w.millisecond()
    w.next_ms += us_to_cycles(US_PER_MS)
  w.reschedule()

# ---------------------------------------------------------------------------
# Serial chips

proc fw24(fw: seq[uint8]; o: int): uint32 =
  uint32(fw[o]) or (uint32(fw[o + 1]) shl 8) or (uint32(fw[o + 2]) shl 16)

proc note_rf_write(w: Wifi; index: int; data: uint32) =
  ## Which channel the RF is on: a type-2 RF (firmware[040h] != 3) gets two
  ## writes per channel from firmware[0F2h + (ch-1)*6] (GBATEK "Change
  ## Channels"); the first, RF[05h], differs on every channel.
  if w.firmware.len < 0x200 or w.firmware[0x40] == 3: return
  for ch in 1..14:
    let e = fw24(w.firmware, 0xF2 + (ch - 1) * 6)
    if e != 0 and e != 0xFFFFFF and int(e shr 18) == index and (e and 0x3FFFF) == data:
      w.channel = ch
      return

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
      w.note_rf_write(i, w.rf[i])
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

proc trace(w: Wifi; what: string; o: int; v: uint16) =
  ## -d:wifilog: every register access with its frame.line time, repeats
  ## folded (the investigation log of docs/nds/wifi.md).
  when defined(wifilog):
    let line = what & " " & toHex(o, 3) & " " & toHex(v, 4)
    if line == w.log_last:
      inc w.log_repeat
      return
    if w.log_repeat > 0: stderr.writeLine("wifi" & $w.station & "   (x" & $(w.log_repeat + 1) & ")")
    w.log_last = line
    w.log_repeat = 0
    let t = w.sched.now
    stderr.writeLine("wifi" & $w.station & " f" & $(t div FRAME_CYCLES) & "." &
                     $((t mod FRAME_CYCLES) div LINE_CYCLES) & " " & line)

proc read16_raw(w: Wifi; a: uint32): uint16 =
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
    # W_RXBUF_RD_DATA: read and advance, wrapping END -> BEGIN, then the gap
    # (GBATEK W_RXBUF_GAP)
    let ra = int(w.reg(0x058))
    result = w.ram[(ra shr 1) and 0xFFF]
    var na = (ra + 2) and 0x1FFE
    if na == int(w.reg(0x052) and 0x1FFE): na = int(w.reg(0x050) and 0x1FFE)
    if na == int(w.reg(0x062)): na = (na + 2 * int(w.reg(0x064))) and 0x1FFE
    w.reg(0x058) = uint16(na)
    if w.reg(0x05C) > 0:
      w.reg(0x05C) = w.reg(0x05C) - 1
      if w.reg(0x05C) == 0: w.set_if(1'u16 shl 9)
  of 0x078: result = w.reg(0x068)        # mirror of W_TXBUF_WR_ADDR
  of 0x0F8, 0x0FA, 0x0FC, 0x0FE:
    result = uint16((w.us_now() shr ((o - 0x0F8) * 8)) and 0xFFFF)
  of 0x118: result = w.cmd_count()
  of 0x1B0 .. 0x1BE, 0x1C0, 0x1C4, 0x1D0 .. 0x1DE:
    # statistics and multiplay error counters clear when read (GBATEK)
    result = w.reg(o)
    w.reg(o) = 0
    if o <= 0x1BE:
      for n, ba in RXSTAT_BYTES:
        if (ba and not 1) == o: w.reg(0x1AC) = w.reg(0x1AC) and not (1'u16 shl n)
  else: result = w.reg(o)

proc read16*(w: Wifi; a: uint32): uint16 =
  result = w.read16_raw(a)
  when defined(wifilog):
    if (a and 0x7FFF) < 0x4000: w.trace("R", int(a and 0xFFE), result)

proc write16*(w: Wifi; a: uint32; v: uint16) =
  let r = a and 0x7FFF
  when defined(wifilog):
    if r < 0x4000: w.trace("W", int(a and 0xFFE), v)
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
      w.short_preamble = false
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
      # queued power-up; applied at once (Assumed: no measured delay), the
      # RF then listening (Assumed: RX.ON, which drivers wait for)
      w.reg(o) = w.reg(o) and not 0x0302'u16
      if w.tx_src < 0: w.wake_rx()
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
  of 0x090:
    # bit 15 only sticks while W_CMD_COUNT is running (GBATEK W_TXBUF_CMD)
    w.reg(o) = if w.cmd_count() == 0: v and 0x7FFF else: v
    w.start_tx()
  of 0x0A0, 0x0A4, 0x0A8:
    w.reg(o) = v
    w.start_tx()
  of 0x0BC:
    w.reg(o) = v and 3
    w.short_preamble = (v and 4) != 0
  of 0x0E8:
    w.reg(o) = v and 1
    w.latch_counter()
  of 0x0EA:
    w.reg(o) = v and 1
    if (v and 2) != 0: w.beacon_irq(true)
  of 0x0EE:
    w.latch_cmd_count()
    w.reg(o) = v and 1
  of 0x118:
    w.reg(o) = v
    w.cmd_count_at = w.sched.now
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

{.pop.}
