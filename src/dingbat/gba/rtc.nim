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

# ==================== Serial interface ====================
#
# The chip's side of the three GPIO pins (SCK = bit 0, SIO = bit 1, CS =
# bit 2), as the gba-rtc-test ROM (CasualPokePlayer, "RTC Basic Tests") pins
# it down on a real S-3511A:
#   * CS high starts a command and CS low ends whatever is running; no SCK
#     level is required at CS's rising edge.
#   * While CS is low the chip sees SCK as high, so CS rising with SCK high
#     is not a clock edge.
#   * A bit is taken on SCK's rising edge from the SIO level of the port
#     write BEFORE the edge (a write that raises SCK and changes SIO together
#     delivers the old SIO), not from a level seen at a falling edge.
#   * The command byte is MSB first; its top nibble must be 0110, or it is
#     dropped and the next eight bits are a new command.
#   * Read data comes out LSB first on SCK's falling edge, from a register
#     that rotates: reading past the end repeats it. Until the first falling
#     edge, and whenever the chip is not reading, SIO floats high.
#   * The CPU pulling SIO low while the chip reads clears, at the next falling
#     edge, the bit last shifted out (the register, not the status itself).
#   * A status write lands on the 8th bit, then on every 8k+1st (that bit
#     included: the byte is the last eight bits), or when CS drops after a
#     whole number of bytes past the first.
#
# Field use (also the save-state layout): `sck` / `cs` are the levels the
# chip sees, `sio` its own SIO output; `buffer.value` holds the command
# bits, the bits written so far, or the rotating read register, and
# `buffer.size` the bit count (for a status write it cycles 9..16 after the
# first byte; for a read it is the register's length).

proc clear*(buf: var RtcBuffer) =
  buf.size = 0
  buf.value = 0

proc rtc_load_read(rtc: RTC) =
  ## Latch the register the read command names into the rotating register.
  var bytes: seq[uint8]
  case rtc.reg
  of 1:  # CONTROL
    bytes.add(rtc.status)
  of 2:  # DATE_TIME
    let cal = rtc_calendar_now(rtc)
    for b in datetime_registers(cal, rtc_weekday_of(rtc, cal), rtc.status):
      bytes.add(b)
  of 3:  # TIME
    let cal = rtc_calendar_now(rtc)
    let r = datetime_registers(cal, rtc_weekday_of(rtc, cal), rtc.status)
    for i in 4 .. 6: bytes.add(r[i])
  else:
    # GBATEK: the alarm/free registers read "always FFh".
    bytes.add(0xFF'u8)
  rtc.buffer.value = 0
  for i, b in bytes:
    rtc.buffer.value = rtc.buffer.value or (uint64(b) shl (8 * i))
  rtc.buffer.size = 8 * bytes.len
  rtc.sio = true
  when defined(rtc_trace): echo "RTCREAD ", bytes

proc rtc_written_byte(rtc: RTC; i: int): uint8 =
  uint8((rtc.buffer.value shr (8 * i)) and 0xFF'u64)

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

proc rtc_commit_status(rtc: RTC; value: uint8) =
  when defined(rtc_trace): echo "RTCSTATUS ", value.toHex
  let before = rtc.status
  rtc_set_status(rtc, value)
  if rtc.status != before: rtc_mark_battery_dirty(rtc)

proc rtc_execute_write(rtc: RTC) =
  ## A DATE_TIME / TIME parameter block is complete.
  case rtc.reg
  of 2:  # DATE_TIME: year, month, day, weekday, hour, minute, second
    var b: array[7, uint8]
    for i in 0 .. 6: b[i] = rtc.rtc_written_byte(i)
    let (cal, wday) = normalize_datetime(b[0], b[1], b[2],
                                         uint8(written_hour(b[4], rtc.status)),
                                         b[5], b[6], b[3])
    rtc_set_clock(rtc, cal, wday)
  of 3:  # TIME: hour, minute, second on the current date
    var b: array[3, uint8]
    for i in 0 .. 2: b[i] = rtc.rtc_written_byte(i)
    let now = rtc_calendar_now(rtc)
    let c = from_calendar_seconds(now)
    let (cal, _) = normalize_datetime(bcd(c.year mod 100), bcd(c.month), bcd(c.day),
                                      uint8(written_hour(b[0], rtc.status)),
                                      b[1], b[2], 0'u8)
    # The weekday counter is not part of a TIME write; the date is unchanged
    rtc_set_clock(rtc, cal, rtc_weekday_of(rtc, now))
  else: discard

proc new_rtc*(gba: GBA): RTC =
  result = RTC(
    gba: gba,
    sck: true,   # CS low: the chip sees SCK high
    sio: true,
    cs: false,
    state: rtcWaiting,
    reg: 1,  # CONTROL default
    status: RTC_STATUS_DEFAULT,
    irq: false,
  )

proc rtc_sio_level*(rtc: RTC): bool =
  ## What the chip puts on SIO: its data bit while a read runs, else high.
  not rtc.cs or rtc.state != rtcReading or rtc.sio

proc rtc_command_byte(rtc: RTC) =
  ## Eight command bits are in: start the transfer they name.
  let cmd = uint8(rtc.buffer.value and 0xFF'u64)
  rtc.buffer.value = 0
  rtc.buffer.size = 0
  if (cmd shr 4) != 0b0110'u8:
    return  # not a command: the next eight bits are
  rtc.reg = int((cmd shr 1) and 7'u8)
  when defined(rtc_trace): echo "RTCCMD ", cmd.toHex
  if rtc.reg == 0 or rtc.reg == 6:
    # Strobes take no parameter in either direction
    discard rtc_strobe(rtc)
    rtc.state = rtcDone
  elif (cmd and 1'u8) != 0:
    rtc.state = rtcReading
    rtc_load_read(rtc)
  else:
    rtc.state = rtcWriting

proc rtc_rising(rtc: RTC; level: bool) =
  let b = if level: 1'u64 else: 0'u64
  case rtc.state
  of rtcCommand:
    rtc.buffer.value = (rtc.buffer.value shl 1) or b
    inc rtc.buffer.size
    if rtc.buffer.size == 8: rtc_command_byte(rtc)
  of rtcWriting:
    if rtc.reg == 1:
      # CONTROL: an 8-bit shift register, newest bit at the top
      rtc.buffer.value = ((rtc.buffer.value shr 1) or (b shl 7)) and 0xFF'u64
      rtc.buffer.size = if rtc.buffer.size == 16: 9 else: rtc.buffer.size + 1
      if rtc.buffer.size == 8 or rtc.buffer.size == 9:
        rtc_commit_status(rtc, uint8(rtc.buffer.value))
    elif rtc_register_bytes(rtc.reg) > 0:
      rtc.buffer.value = rtc.buffer.value or (b shl rtc.buffer.size)
      inc rtc.buffer.size
      if rtc.buffer.size == rtc_register_bytes(rtc.reg) * 8:
        rtc_execute_write(rtc)
        rtc.state = rtcDone
    # ALARM / command 5 / 7: the bits go nowhere and the command stays active
  else: discard

proc rtc_falling(rtc: RTC; pulled_low: bool) =
  if rtc.state != rtcReading: return
  let top = rtc.buffer.size - 1
  if pulled_low:
    rtc.buffer.value = rtc.buffer.value and not (1'u64 shl top)
  let o = rtc.buffer.value and 1'u64
  rtc.sio = o != 0
  rtc.buffer.value = (rtc.buffer.value shr 1) or (o shl top)

proc rtc_write*(rtc: RTC; value, prev, direction: uint8) =
  ## `value` is the pin levels the port drives now, `prev` before this port
  ## write; an input pin is not driven and reads as low here.
  let cs = bit(value, 2)
  if not cs:
    if rtc.cs and rtc.state == rtcWriting and rtc.reg == 1 and
       (rtc.buffer.size == 8 or rtc.buffer.size == 16):
      rtc_commit_status(rtc, uint8(rtc.buffer.value))
    rtc.cs = false
    rtc.sck = true
    rtc.sio = true
    rtc.state = rtcWaiting
    rtc.pulled_low = false
    rtc.buffer.clear()
    return
  if not rtc.cs:
    rtc.cs = true
    rtc.state = rtcCommand
    rtc.buffer.clear()
  # The CPU holding SIO low against a read, on this write or the one that
  # raised SCK before it; the next falling edge takes it.
  if rtc.state == rtcReading and bit(direction, 1) and not bit(value, 1):
    rtc.pulled_low = true
  let sck = bit(value, 0)
  if sck and not rtc.sck:
    rtc_rising(rtc, bit(prev, 1))
  elif rtc.sck and not sck:
    rtc_falling(rtc, rtc.pulled_low)
    rtc.pulled_low = false
  rtc.sck = sck
