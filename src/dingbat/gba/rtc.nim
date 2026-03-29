# RTC implementation (included by gba.nim)
import std/times

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

proc bcd(i: int): uint8 =
  uint8((i div 10) shl 4) or uint8(i mod 10)

proc rtc_prepare_read(rtc: RTC) =
  case rtc.reg
  of 1:  # CONTROL
    let control = 0b10'u8 or (if rtc.irq: 0x08'u8 else: 0) or (if rtc.m24: 0x40'u8 else: 0)
    rtc.buffer.push_byte(control)
  of 2:  # DATE_TIME
    let now = local(now())
    var hour = now.hour
    if not rtc.m24:
      let pm = hour >= 12
      hour = hour mod 12
      if pm: hour = hour or 0x80
    rtc.buffer.push_byte(bcd(now.year mod 100))
    rtc.buffer.push_byte(bcd(now.month.int))
    rtc.buffer.push_byte(bcd(now.monthday))
    rtc.buffer.push_byte(bcd((now.weekday.int + 1) mod 7))
    if not rtc.m24 and (hour and 0x80) != 0:
      rtc.buffer.push_byte(bcd(hour and 0x7F) or 0x80'u8)
    else:
      rtc.buffer.push_byte(bcd(hour))
    rtc.buffer.push_byte(bcd(now.minute))
    rtc.buffer.push_byte(bcd(now.second))
  of 3:  # TIME
    let now = local(now())
    var hour = now.hour
    if not rtc.m24:
      let pm = hour >= 12
      hour = hour mod 12
      if pm: hour = hour or 0x80
    if not rtc.m24 and (hour and 0x80) != 0:
      rtc.buffer.push_byte(bcd(hour and 0x7F) or 0x80'u8)
    else:
      rtc.buffer.push_byte(bcd(hour))
    rtc.buffer.push_byte(bcd(now.minute))
    rtc.buffer.push_byte(bcd(now.second))
  else: discard

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

proc rtc_execute_write(rtc: RTC) =
  case rtc.reg
  of 1:  # CONTROL
    let b = rtc.buffer.shift_byte()
    rtc.irq = bit(b, 3)
    rtc.m24 = bit(b, 6)
    if rtc.irq: echo "TODO: implement rtc irq"
  of 0:  # RESET
    rtc.irq = false
    rtc.m24 = false
  of 6:  # IRQ
    rtc.gba.interrupts.reg_if.game_pak = true
    rtc.gba.interrupts.schedule_interrupt_check()
  else: discard
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
    irq: false,
    m24: true,
  )

proc rtc_read*(rtc: RTC): uint8 =
  uint8(rtc.sck) or (uint8(rtc.sio) shl 1) or (uint8(rtc.cs) shl 2)

proc rtc_write*(rtc: RTC; value: uint8) =
  let sck = bit(value, 0)
  let sio = bit(value, 1)
  let cs  = bit(value, 2)
  case rtc.state
  of rtcWaiting:
    if rtc.sck and sck and not rtc.cs and cs:
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
        if rtc.state == rtcReading:
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
