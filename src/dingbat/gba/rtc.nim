# RTC implementation (included by gba.nim; std/times comes from its imports)
#
# Seiko S-3511A on the cartridge GPIO port. Sources: GBATEK "GBA Cart
# Real-Time Clock (RTC)" (register map, strobes, AM/PM on hour bit 7) and the
# S-3511A datasheet Rev. 1.4 (status register bits, reset values, validation
# of written data). Calendar rules and the battery-save trailer live in
# rtc_calendar.nim.
#
# Clock model. The chip counts seconds from whatever it was last set to; it
# has no notion of a time zone. dingbat keeps that count as
#   calendar seconds = source seconds + bias
# where the source is the host's unix clock, or the frozen `epoch` in
# deterministic mode. A game writing DATE_TIME/TIME moves `bias`; so does a
# battery-file trailer at boot that records a set clock (bias = saved
# date/time - latch time, which is "saved + (now - latch)"). Otherwise
# (`bias_set` false) the RTC shows host LOCAL time, tracking the host zone, or
# UTC in deterministic mode (a zone would make peers in different zones
# disagree); RESET returns it there. Once set, the clock counts real seconds
# like the chip and no longer follows host daylight-saving changes.
# Why host time rather than the chip's 2000-01-01 reset: docs/gba-rtc.md.

# Per-minute IRQ poll interval: one emulated second. The S-3511A asserts /INT
# at second 00 of every minute; this RTC reads a live clock, so a once-per-
# second poll comparing whole minutes (not `second == 0`) finds the boundary
# even when emulated time drifts from the wall clock (turbo / slowdown).
const RTC_IRQ_POLL_CYCLES = 1 shl 24

const RTC_STATUS_DEFAULT = S3511_STATUS_24H
  ## Status with no battery-file record: 24-hour mode, interrupts off. The
  ## chip powers on at 82h (datasheet 3.1) and every RTC game seen resets and
  ## selects 24-hour mode on a POWER flag, leaving 40h; a battery that never
  ## failed reads that.

proc rtc_source_seconds(rtc: RTC): int64 =
  ## Unix seconds the clock runs from: the frozen epoch, or the host clock.
  if rtc.deterministic: rtc.epoch else: getTime().toUnix

proc rtc_bias_at(rtc: RTC; source: int64): int64 =
  ## A trailer that recorded host time keeps tracking the host zone on a live
  ## clock; a deterministic session always uses the stored offset, which comes
  ## from bytes every peer shares.
  if rtc.bias_set:
    if rtc.bias_host and not rtc.deterministic: local_zone_offset(source)
    else: rtc.bias
  elif rtc.deterministic: 0'i64
  else: local_zone_offset(source)

proc rtc_calendar_now*(rtc: RTC): int64 =
  ## The date/time the chip holds right now, as calendar seconds.
  let src = rtc_source_seconds(rtc)
  src + rtc_bias_at(rtc, src)

proc rtc_weekday_of(rtc: RTC; cal: int64): int =
  (calendar_weekday(cal) + rtc.wday_bias) mod 7

proc rtc_minutes(rtc: RTC): int64 =
  ## Whole minutes on the RTC's own clock, the boundary the per-minute
  ## interrupt fires on.
  floorDiv(rtc_calendar_now(rtc), 60'i64)

proc rtc_irq_poll*(gba: GBA) =
  ## etRtcSecond handler: scheduled only while the control register's
  ## per-minute IRQ bit is set; raises the Game Pak IRQ once per minute
  ## boundary. In deterministic mode the clock is frozen, so no IRQ fires.
  let rtc = gba.bus.gpio.rtc
  if not rtc.irq: return  # disabled since scheduling; drop the poll chain
  let m = rtc_minutes(rtc)
  if m != rtc.irq_minute:
    rtc.irq_minute = m
    gba.interrupts.reg_if.game_pak = true
    gba.interrupts.schedule_interrupt_check()
  gba.scheduler.schedule(RTC_IRQ_POLL_CYCLES, etRtcSecond)

proc enable_deterministic_rtc*(gba: GBA; epoch: int64) =
  ## Freeze the RTC's source clock to a shared unix epoch for a linked or
  ## replayed session. Both peers must pass the SAME epoch (exchange one
  ## peer's value at connect). A clock the game set, or one read from the
  ## battery file, is kept as an offset from that epoch: it comes from bytes
  ## (state or .sav) the peers already share, so they still agree.
  gba.bus.gpio.rtc.deterministic = true
  gba.bus.gpio.rtc.epoch = epoch

proc rtc_set_status(rtc: RTC; value: uint8) =
  ## Store the R/W status bits and (re)arm the per-minute IRQ poll.
  let was_irq = rtc.irq
  rtc.status = value and S3511_STATUS_RW_BITS
  rtc.irq = (rtc.status and 0x08'u8) != 0
  if rtc.irq != was_irq and rtc.gba != nil and rtc.gba.scheduler != nil:
    rtc.gba.scheduler.clear(etRtcSecond)
    if rtc.irq:
      # Enabled mid-minute: the chip fires at second 00, so latch the
      # current minute — the first IRQ comes at the NEXT boundary
      rtc.irq_minute = rtc_minutes(rtc)
      rtc.gba.scheduler.schedule(RTC_IRQ_POLL_CYCLES, etRtcSecond)

proc rtc_mark_battery_dirty(rtc: RTC) =
  ## The clock is battery-backed cart state: persist the new trailer.
  if rtc.gba != nil and rtc.gba.storage != nil and rtc.gba.storage.rtc == rtc:
    rtc.gba.storage.dirty = true

proc rtc_set_clock(rtc: RTC; cal: int64; weekday: int) =
  ## The chip now holds `cal` with weekday counter `weekday`.
  let src = rtc_source_seconds(rtc)
  let new_bias = cal - src
  let new_wday = ((weekday - calendar_weekday(cal)) mod 7 + 7) mod 7
  let changed = not rtc.bias_set or new_bias != rtc.bias or new_wday != rtc.wday_bias
  rtc.bias = new_bias
  rtc.bias_set = true
  rtc.bias_host = false
  rtc.wday_bias = new_wday
  rtc.irq_minute = rtc_minutes(rtc)  # a set is not a minute carry
  if changed: rtc_mark_battery_dirty(rtc)

proc rtc_follow_host(rtc: RTC) =
  ## Back to the source clock: host local time (UTC when deterministic). The
  ## chip-level RESET lands here instead of 2000-01-01; docs/gba-rtc.md.
  let changed = rtc.bias_set or rtc.wday_bias != 0
  rtc.bias = 0
  rtc.bias_set = false
  rtc.bias_host = false
  rtc.wday_bias = 0
  rtc.irq_minute = rtc_minutes(rtc)
  if changed: rtc_mark_battery_dirty(rtc)

const RTC_HOST_TRAILER_SLACK = 2'i64
  ## Seconds a trailer's clock may sit from the source clock's own reading at
  ## its latch instant and still count as "was following the host".

proc rtc_apply_trailer*(rtc: RTC; t: openArray[byte]): bool =
  ## Resume the clock from a battery-file trailer. False if the bytes are not
  ## a clock reading (rtc_calendar.parse_trailer); the RTC is then untouched.
  ## A trailer that only records host time (what a host-clock emulator, or
  ## dingbat with no game-set clock, writes) keeps the clock following the
  ## host, so it still tracks zone and daylight-saving changes; any other
  ## trailer is a set clock and resumes as saved + (now - latch).
  var clock: TrailerClock
  if not parse_trailer(t, clock): return false
  rtc.bias = clock.seconds - clock.latch
  rtc.bias_set = true
  rtc.wday_bias = ((clock.weekday - calendar_weekday(clock.seconds)) mod 7 + 7) mod 7
  # The zone test only steers a live host clock (rtc_bias_at), so peers in
  # different zones that load the same file still agree when deterministic.
  rtc.bias_host = rtc.wday_bias == 0 and
    abs(rtc.bias - local_zone_offset(clock.latch)) <= RTC_HOST_TRAILER_SLACK
  if clock.has_status: rtc_set_status(rtc, clock.status)
  true

proc rtc_trailer_bytes(rtc: RTC): array[16, byte] =
  ## The trailer for the clock as it stands now, latched at the source clock
  ## (the epoch in deterministic mode, so a replay writes identical bytes).
  let src = rtc_source_seconds(rtc)
  let cal = src + rtc_bias_at(rtc, src)
  encode_trailer(cal, rtc_weekday_of(rtc, cal), rtc.status, src)

proc rtc_register_bytes(reg: int): int =
  case reg
  of 1: 1  # CONTROL
  of 2: 7  # DATE_TIME
  of 3: 3  # TIME
  else: 0

proc push_bool*(buf: var RtcBuffer; value: bool) =
  inc buf.size
  buf.value = (buf.value shl 1) or (if value: 1'u64 else: 0'u64)

proc push_byte*(buf: var RtcBuffer; value: uint8) =
  for b in 0..7:
    buf.push_bool(bit(value, b))

proc shift_bit*(buf: var RtcBuffer): bool =
  doAssert buf.size > 0, "Invalid RTC buffer size " & $buf.size
  dec buf.size
  ((buf.value shr buf.size) and 1) == 1

proc shift_byte*(buf: var RtcBuffer): uint8 =
  result = 0
  for b in 0..7:
    if buf.shift_bit():
      result = result or (1'u8 shl b)

proc clear*(buf: var RtcBuffer) =
  buf.size = 0
  buf.value = 0

proc rtc_prepare_read(rtc: RTC) =
  case rtc.reg
  of 1:  # CONTROL
    rtc.buffer.push_byte(rtc.status)
  of 2:  # DATE_TIME
    let cal = rtc_calendar_now(rtc)
    for b in datetime_registers(cal, rtc_weekday_of(rtc, cal), rtc.status):
      rtc.buffer.push_byte(b)
  of 3:  # TIME
    let cal = rtc_calendar_now(rtc)
    let r = datetime_registers(cal, rtc_weekday_of(rtc, cal), rtc.status)
    for i in 4 .. 6:
      rtc.buffer.push_byte(r[i])
  else:
    # GBATEK: the alarm/free registers read "always FFh". One byte is
    # Assumed; SIO stays high after it.
    rtc.buffer.push_byte(0xFF'u8)

proc reverse_bits(b: uint8): uint8 =
  result = 0
  for i in 0..7:
    if bit(b, 7 - i):
      result = result or (1'u8 shl i)

proc rtc_read_command(full_cmd: uint8): tuple[state: RtcState, reg: int] =
  let cmd_bits =
    if (full_cmd and 0xF'u8) == 0b0110'u8:
      reverse_bits(full_cmd) and 0xF'u8
    else:
      full_cmd and 0xF'u8
  let is_read = bit(cmd_bits, 0)
  let reg_code = int(cmd_bits shr 1)
  let state = if is_read: rtcReading else: rtcWriting
  (state: state, reg: reg_code)

proc rtc_strobe(rtc: RTC): bool =
  ## GBATEK: the force-reset and force-IRQ registers "are strobed by ANY
  ## access to them, ie. by both writing to, as well as reading from"; the
  ## datasheet's command list says the same of reset ("Don't care the R/W bit
  ## of this command"). True if `reg` was one of them.
  case rtc.reg
  of 0:  # RESET: datasheet 3.3 status 00h. The chip also loads 2000-01-01
         # 00:00:00; dingbat returns to the host clock instead so a new game
         # shows today's date, as other emulators do (docs/gba-rtc.md)
    let before = rtc.status
    rtc_set_status(rtc, 0'u8)
    rtc_follow_host(rtc)
    if before != 0: rtc_mark_battery_dirty(rtc)
    true
  of 6:  # IRQ
    rtc.gba.interrupts.reg_if.game_pak = true
    rtc.gba.interrupts.schedule_interrupt_check()
    true
  else: false

proc rtc_execute_write(rtc: RTC) =
  case rtc.reg
  of 1:  # CONTROL
    let before = rtc.status
    rtc_set_status(rtc, rtc.buffer.shift_byte())
    if rtc.status != before: rtc_mark_battery_dirty(rtc)
  of 2:  # DATE_TIME: year, month, day, weekday, hour, minute, second
    var b: array[7, uint8]
    for i in 0 .. 6: b[i] = rtc.buffer.shift_byte()
    let (cal, wday) = normalize_datetime(b[0], b[1], b[2],
                                         uint8(written_hour(b[4], rtc.status)),
                                         b[5], b[6], b[3])
    rtc_set_clock(rtc, cal, wday)
  of 3:  # TIME: hour, minute, second on the current date
    var b: array[3, uint8]
    for i in 0 .. 2: b[i] = rtc.buffer.shift_byte()
    let now = rtc_calendar_now(rtc)
    let c = from_calendar_seconds(now)
    let (cal, _) = normalize_datetime(bcd(c.year mod 100), bcd(c.month), bcd(c.day),
                                      uint8(written_hour(b[0], rtc.status)),
                                      b[1], b[2], 0'u8)
    # The weekday counter is not part of a TIME write; the date is unchanged
    rtc_set_clock(rtc, cal, rtc_weekday_of(rtc, now))
  else:
    discard rtc_strobe(rtc)
  rtc.buffer.clear()
  rtc.state = rtcWaiting
  rtc.cs = false

proc new_rtc*(gba: GBA): RTC =
  result = RTC(
    gba: gba,
    sck: false,
    sio: false,
    cs: false,
    state: rtcWaiting,
    reg: 1,  # CONTROL default
    status: RTC_STATUS_DEFAULT,
    irq: false,
  )

proc rtc_read*(rtc: RTC): uint8 =
  uint8(rtc.sck) or (uint8(rtc.sio) shl 1) or (uint8(rtc.cs) shl 2)

proc rtc_write*(rtc: RTC; value: uint8; prev: uint8) =
  ## `value` is the pin levels now, `prev` the levels before this port write.
  let sck = bit(value, 0)
  let sio = bit(value, 1)
  let cs  = bit(value, 2)
  case rtc.state
  of rtcWaiting:
    # A command starts when CS rises while SCK is high (datasheet 1.3: data
    # is clocked "after turning the CS pin to H"). SCK may rise in the same
    # port write: the library's first transaction enables SCK and CS as
    # outputs together (gpio.nim).
    if sck and cs and not bit(prev, 2) and not rtc.cs:
      rtc.state = rtcCommand
      rtc.cs = true
    rtc.sck = sck
    rtc.sio = sio
  of rtcCommand:
    if not rtc.sck and sck:
      rtc.buffer.push_bool(sio)
      if rtc.buffer.size == 8:
        let (new_state, new_reg) = rtc_read_command(rtc.buffer.shift_byte())
        rtc.state = new_state
        rtc.reg   = new_reg
        if rtc.reg == 0 or rtc.reg == 6:
          # Strobes take no parameter in either direction
          rtc_execute_write(rtc)
        elif rtc.state == rtcReading:
          rtc_prepare_read(rtc)
        else:
          if rtc_register_bytes(rtc.reg) == 0:
            rtc_execute_write(rtc)
    rtc.sck = sck
    rtc.sio = sio
  of rtcReading:
    if not rtc.sck and sck:
      rtc.sio = rtc.buffer.shift_bit()
      if rtc.buffer.size == 0:
        rtc.state = rtcWaiting
        rtc.cs = false
    rtc.sck = sck
  of rtcWriting:
    if not rtc.sck and sck:
      rtc.buffer.push_bool(sio)
      if rtc.buffer.size == rtc_register_bytes(rtc.reg) * 8:
        rtc_execute_write(rtc)
    rtc.sck = sck
    rtc.sio = sio
