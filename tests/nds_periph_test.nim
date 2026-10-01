## DS system peripherals (src/dingbat/nds/io/{rtc,spi,mic,input}.nim and
## sleep in nds.nim): RTC interrupts through RCNT/SI, the clock adjustment,
## SPI transfer timing, the power manager, the touchscreen controller's
## channels and microphone, firmware flash busy times, sleep and the lid --
## each driven through its registers as the ARM7 would, checked against
## GBATEK, the Seiko S-35190A and TI TSC2046 datasheets, or the values
## docs/nds/peripherals.md marks Assumed.
##
## Run with: nimble test_ndsperiph

import std/math
import dingbat/nds/[sched, nds]
import dingbat/nds/io/[irq, rtc, spi, input, mic]
import dingbat/gba/rtc_calendar

var failures = 0

proc check(cond: bool; msg: string; detail = "") =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
    failures.inc

const
  IRQ_SIO = 1'u32 shl 7
  IRQ_KEY = 1'u32 shl 12
  IRQ_LID = 1'u32 shl 22
  IRQ_SPI = 1'u32 shl 23
  SEC = int64(MASTER_HZ)

# ---------------------------------------------------------------------------
# RTC: bit-banged as the ARM7 does (LSB-first commands)

const
  CS = 4'u16
  SCK = 2'u16
  DIR = 0x70'u16
  DIR_IN = 0x60'u16

proc rtc_cmd(r: Rtc; cmd: uint8; params: openArray[uint8]) =
  r.write_reg(DIR or SCK)
  r.write_reg(DIR or SCK or CS)
  for b in @[cmd] & @params:
    for i in 0..7:
      let bit = uint16((b shr i) and 1)
      r.write_reg(DIR or CS or bit)
      r.write_reg(DIR or CS or SCK or bit)
  r.write_reg(DIR or SCK)

proc rtc_read(r: Rtc; cmd: uint8; n: int): seq[uint8] =
  r.write_reg(DIR or SCK)
  r.write_reg(DIR or SCK or CS)
  for i in 0..7:
    let bit = uint16((cmd shr i) and 1)
    r.write_reg(DIR or CS or bit)
    r.write_reg(DIR or CS or SCK or bit)
  for k in 0 ..< n:
    var v = 0'u8
    for i in 0..7:
      r.write_reg(DIR_IN or CS)
      r.write_reg(DIR_IN or CS or SCK)
      v = v or (uint8(r.read_reg() and 1) shl i)
    result.add v
  r.write_reg(DIR or SCK)

# command bytes: 0110 ccc r, LSB first
proc wcmd(reg: int): uint8 = uint8(0x06 or (reg shl 4))
proc rcmd(reg: int): uint8 = wcmd(reg) or 0x80

proc run_to(s: NdsScheduler; r: Rtc; t: int64) =
  ## Advance the timeline to `t`, dispatching the RTC's events.
  var ev: NdsEvent
  var at: int64
  while s.next_at() <= t:
    s.now = s.next_at()
    while s.pop_due(ev, at):
      if ev == evRtc: r.on_event()
  s.now = t

proc new_test_rtc(s: NdsScheduler; i: IrqCtl; start: int64): Rtc =
  result = new_rtc()
  result.sched = s
  result.irq = i
  result.set_fixed_clock(s, start)

block rtc_freq:
  echo "RTC: selected-frequency interrupt"
  let s = new_nds_scheduler()
  let i = IrqCtl()
  let r = new_test_rtc(s, i, to_calendar_seconds(2024, 5, 6, 12, 0, 0))
  r.write_rcnt(0x8100, 0xFFFF)                 # GP mode, SI IRQ on
  r.rtc_cmd(wcmd(1), [0x01'u8])                # INT1 frequency register: 1 Hz
  r.rtc_cmd(wcmd(4), [0x01'u8])                # stat2: frequency steady interrupt
  # 1 Hz is low for the first half of each second: the next fall is 12:00:01
  var edges = 0
  var t = s.now
  for k in 1..4:
    t = int64(k) * SEC + 10_000
    s.run_to(r, t)
    if (i.iff and IRQ_SIO) != 0:
      inc edges
      i.iff = 0
  check edges == 4, "1 Hz: one SI fall (IF.7) per second", $edges
  check (r.read_rcnt() and 4) == 0, "SI reads low just after the second turns"
  s.run_to(r, t + SEC div 2)
  check (r.read_rcnt() and 4) != 0, "SI reads high in the second half-second"
  # 2 Hz + 8 Hz ANDed: low while either is low -> falls at 0, 1/8, ..
  r.rtc_cmd(wcmd(1), [0x0A'u8])
  i.iff = 0
  let base = (s.now div SEC + 1) * SEC
  s.run_to(r, base - 100)
  i.iff = 0
  var falls = 0
  for k in 0 ..< 64:
    s.run_to(r, base + int64(k) * SEC div 64 + 2000)
    if (i.iff and IRQ_SIO) != 0:
      inc falls
      i.iff = 0
  # 8 Hz falls 8 times a second; 2 Hz's falls coincide with 8 Hz ones, and
  # while 2 Hz is low the 8 Hz falls don't show: 2 + 2 visible falls
  check falls == 4, "2 Hz AND 8 Hz: four falls a second (datasheet Figure 19)", $falls
  r.rtc_cmd(wcmd(4), [0x00'u8])
  check not s.is_scheduled(evRtc), "no event with no interrupt selected"

block rtc_alarm:
  echo "RTC: alarms and per-minute interrupts"
  let s = new_nds_scheduler()
  let i = IrqCtl()
  let r = new_test_rtc(s, i, to_calendar_seconds(2024, 5, 6, 12, 34, 58))
  r.write_rcnt(0x8100, 0xFFFF)
  r.rtc_cmd(wcmd(4), [0x04'u8])                         # alarm 1
  r.rtc_cmd(wcmd(1), [0x00'u8, 0x80 or 0x52, 0x80 or 0x35])  # any day, 12 PM, :35
  check r.read_rcnt() == 0x8105 or (r.read_rcnt() and 4) != 0, "SI high before the alarm"
  s.run_to(r, s.now + SEC)
  check (i.iff and IRQ_SIO) == 0, "no IRQ at 12:34:59"
  s.run_to(r, s.now + SEC + 1000)
  check (i.iff and IRQ_SIO) != 0, "alarm 1 at 12:35:00 raises IF.7"
  let st = r.rtc_read(rcmd(0), 1)[0]
  check (st and 0x10) != 0, "status 1 INT1 flag set", $st
  check (r.rtc_read(rcmd(0), 1)[0] and 0x10) == 0, "INT1 flag clears on read"
  check (r.read_rcnt() and 4) == 0, "/INT stays low after the flag is read"
  r.rtc_cmd(wcmd(4), [0x00'u8])
  check (r.read_rcnt() and 4) != 0, "clearing INT1AE releases /INT"
  # alarm 2 with the hour compare off: every :36
  i.iff = 0
  r.rtc_cmd(wcmd(4), [0x40'u8])
  r.rtc_cmd(wcmd(5), [0x00'u8, 0x00, 0x80 or 0x36])
  s.run_to(r, s.now + 61 * SEC)
  check (i.iff and IRQ_SIO) != 0 and (r.rtc_read(rcmd(0), 1)[0] and 0x20) != 0,
        "alarm 2 (minute only) raises IF.7 and the INT2 flag"
  r.rtc_cmd(wcmd(4), [0x00'u8])
  # per-minute edge: low from the next minute carry until the mode is left
  i.iff = 0
  r.rtc_cmd(wcmd(4), [0x02'u8])
  s.run_to(r, s.now + 61 * SEC)
  check (i.iff and IRQ_SIO) != 0 and (r.read_rcnt() and 4) == 0, "per-minute edge: low after the carry"
  r.rtc_cmd(wcmd(4), [0x00'u8])
  # minute-periodical 2: 7.81 ms pulse at each carry
  r.rtc_cmd(wcmd(4), [0x07'u8])
  i.iff = 0
  let carry = ((r.now_ticks() div (60 * TICK_HZ)) + 1) * 60 * TICK_HZ
  let to_carry = (carry - r.now_ticks()) * SEC div TICK_HZ
  s.run_to(r, s.now + to_carry + SEC div 1000)    # 1 ms into the minute
  check (i.iff and IRQ_SIO) != 0 and (r.read_rcnt() and 4) == 0, "minute-periodical 2: low at the carry"
  s.run_to(r, s.now + SEC div 100)                 # 11 ms in
  check (r.read_rcnt() and 4) != 0, "minute-periodical 2: high again after 7.81 ms"
  # RCNT.8 off: the line still moves, no IRQ
  r.write_rcnt(0x8000, 0xFFFF)
  i.iff = 0
  s.run_to(r, s.now + 60 * SEC)
  check (i.iff and IRQ_SIO) == 0, "RCNT.8 = 0: no IRQ"

block rtc_rcnt_adjust:
  echo "RTC: RCNT lines, clock adjustment, reset"
  let s = new_nds_scheduler()
  let i = IrqCtl()
  let r = new_test_rtc(s, i, to_calendar_seconds(2030, 1, 1, 0, 0, 0))
  r.write_rcnt(0x8000, 0xFFFF)
  check r.read_rcnt() == 0x800F, "GP mode, all inputs: pulled-up lines read 1"
  r.write_rcnt(0x80F2, 0xFFFF)
  check r.read_rcnt() == 0x80F2, "outputs read what they drive"
  r.write_rcnt(0x0123, 0xFFFF)
  check r.read_rcnt() == 0x0123, "outside GP mode RCNT reads back"
  # adjust: N = 63 every 20 s -> +63 * 3.052 ppm
  let t0 = r.now_ticks()
  r.rtc_cmd(wcmd(3), [63'u8])
  s.run_to(r, s.now + 1000 * SEC)
  let gained = r.now_ticks() - t0 - 1000 * TICK_HZ
  check abs(gained - 6300) <= 2, "adjust 63: +192.3 ppm (6300 ticks in 1000 s)", $gained
  r.rtc_cmd(wcmd(3), [0x80'u8 or 127])            # every 60 s, N = 127: -1.017 ppm
  let t1 = r.now_ticks()
  s.run_to(r, s.now + 10_000 * SEC)
  let lost = r.now_ticks() - t1 - 10_000 * TICK_HZ
  check abs(lost + 333) <= 2, "adjust FFh: -1.017 ppm", $lost
  check r.rtc_read(rcmd(3), 1)[0] == 0xFF, "adjust register reads back"
  # reset: 2000-01-01, 24-hour bit from the reset write
  r.rtc_cmd(wcmd(0), [0x03'u8])
  let d = r.rtc_read(rcmd(2), 7)
  check d[0] == 0 and d[1] == 1 and d[2] == 1 and d[4] == 0 and d[5] == 0,
        "reset: 2000-01-01 00:00", $d
  check r.rtc_read(rcmd(3), 1)[0] == 0, "reset clears the adjust register"

# ---------------------------------------------------------------------------
# SPI bus

proc new_test_spi(s: NdsScheduler; i: IrqCtl; inp: Input; lite = false): Spi =
  var fw = newSeq[uint8](256 * 1024)
  fw[0x1D] = if lite: 0x20 else: 0xFF
  # user settings at 0x3FE00 with the synthesized calibration
  fw[0x20] = uint8((0x3FE00 div 8) and 0xFF); fw[0x21] = uint8((0x3FE00 div 8) shr 8)
  let u = 0x3FE00
  fw[u + 0x58] = 0x00; fw[u + 0x59] = 0x02; fw[u + 0x5A] = 0x00; fw[u + 0x5B] = 0x02
  fw[u + 0x5C] = 1; fw[u + 0x5D] = 1
  fw[u + 0x5E] = 0x00; fw[u + 0x5F] = 0x0E; fw[u + 0x60] = 0x00; fw[u + 0x61] = 0x0A
  fw[u + 0x62] = 255; fw[u + 0x63] = 191
  fw[u + 0x64] = 0x21                           # backlight level 2
  fw[u + 0x170] = 0x7F                          # copy 2 older
  result = new_spi(fw, i, inp)
  result.set_sched(s)

proc xfer(sp: Spi; s: NdsScheduler; cnt: uint16; v: uint8): uint8 =
  sp.write_cnt(cnt, 0xFFFF)
  sp.write_data(v)
  while (sp.read_reg(0x1C0) and 0x80) != 0: s.now += 2
  uint8(sp.read_reg(0x1C0) shr 16)

const
  PM = 0x8802'u16       # power manager, hold, 1 MHz
  PM_LAST = 0x8002'u16
  TSC = 0x8A01'u16      # touchscreen, hold, 2 MHz
  TSC_LAST = 0x8201'u16
  FL = 0x8900'u16       # firmware, hold, 4 MHz
  FL_LAST = 0x8100'u16

proc pm_read(sp: Spi; s: NdsScheduler; reg: int): uint8 =
  discard sp.xfer(s, PM, uint8(0x80 or reg))
  sp.xfer(s, PM_LAST, 0)

proc pm_write(sp: Spi; s: NdsScheduler; reg: int; v: uint8) =
  discard sp.xfer(s, PM, uint8(reg))
  discard sp.xfer(s, PM_LAST, v)

proc tsc_read(sp: Spi; s: NdsScheduler; control: uint8): int =
  discard sp.xfer(s, TSC, control)
  let hi = sp.xfer(s, TSC, 0)
  let lo = sp.xfer(s, TSC_LAST, 0)
  if (control and 8) != 0: (int(hi) shl 1 or int(lo) shr 7) and 0xFF
  else: (int(hi) shl 5 or int(lo) shr 3) and 0xFFF

block spi_timing:
  echo "SPI transfer timing"
  let s = new_nds_scheduler()
  let i = IrqCtl()
  let sp = new_test_spi(s, i, Input())
  for (baud, hz) in [(0, 4_000_000'i64), (1, 2_000_000), (2, 1_000_000), (3, 524_288)]:
    let t = 1000 + int64(baud) * 10_000
    s.now = t
    sp.write_cnt(0xC000'u16 or uint16(baud), 0xFFFF)   # PM, IRQ on
    sp.write_data(0x80)
    let want = (8 * int64(MASTER_HZ) + hz - 1) div hz
    s.now = t + want - 1
    let busy_before = (sp.read_reg(0x1C0) and 0x80) != 0
    let irq_before = (i.iff and IRQ_SPI) != 0
    s.now = t + want
    let busy_after = (sp.read_reg(0x1C0) and 0x80) != 0
    check busy_before and not irq_before and not busy_after and (i.iff and IRQ_SPI) != 0,
          "baud " & $baud & ": busy " & $want & " cycles, IF.23 at the end"
    i.iff = 0
  # the reply shows at the end, not the start
  s.now += 50_000
  discard sp.pm_read(s, 0)
  sp.write_cnt(0x8802, 0xFFFF); sp.write_data(0x80)
  s.now += 1000
  sp.write_cnt(0x8002, 0xFFFF); sp.write_data(0)
  s.now += 10
  let mid = uint8(sp.read_reg(0x1C0) shr 16)
  s.now += 1000
  let fin = uint8(sp.read_reg(0x1C0) shr 16)
  check mid == 0 and fin == 0x0D, "SPIDATA keeps the old byte until the transfer ends", $mid & "/" & $fin
  # 16-bit mode takes 16 bits
  let w0 = s.now + 10_000
  s.now = w0
  sp.write_cnt(0x8402, 0xFFFF); sp.write_data(0x80)
  s.now = w0 + 1000
  check (sp.read_reg(0x1C0) and 0x80) != 0, "16-bit mode: still busy after 8 bits"
  s.now = w0 + 1073
  check (sp.read_reg(0x1C0) and 0x80) == 0, "16-bit mode: done after 16 bits"

block power_manager:
  echo "power manager"
  let s = new_nds_scheduler()
  let i = IrqCtl()
  var sp = new_test_spi(s, i, Input())
  check sp.pm_read(s, 0) == 0x0D and sp.pm_read(s, 4) == 0x0D and sp.pm_read(s, 0x7C) == 0x0D,
        "old DS: register 0, mirrored at 4 and 7Ch"
  sp.pm_write(s, 0, 0xFF)
  check sp.pm_read(s, 0) == 0x7F, "old DS: bit 7 reads 0 (mute bit kept)"
  sp = new_test_spi(s, i, Input())
  sp.pm_write(s, 2, 0xFF); sp.pm_write(s, 3, 0xFF)
  check sp.pm_read(s, 2) == 1 and sp.pm_read(s, 3) == 3, "mic amp / gain keep bits 0 / 0-1"
  check sp.pm_read(s, 1) == 0, "battery good"
  sp.battery_low = true
  sp.pm_write(s, 1, 0)
  check sp.pm_read(s, 1) == 1, "battery low reads 1, register 1 read-only"
  sp.pm_write(s, 0, 0x0C or 0x40)
  check sp.power_off, "register 0 bit 6 shuts the DS down"
  let lite = new_test_spi(s, i, Input(), lite = true)
  check lite.pm_read(s, 4) == 0x42 and lite.pm_read(s, 7) == 0x42,
        "DS-Lite: register 4 = 40h + firmware backlight level, mirrored at 5-7"
  check lite.pm_read(s, 8) == 0x0D, "DS-Lite: 8 mirrors 0"
  lite.pm_write(s, 0, 0x0F)
  check lite.pm_read(s, 0) == 0x0D, "DS-Lite: no mute bit"
  lite.pm_write(s, 4, 0x05)
  check lite.pm_read(s, 4) == 0x45, "level 1, force-max without external power"
  lite.ext_power = true
  check lite.pm_read(s, 4) == 0x4F, "force-max on external power reads level 3 and bit 3"
  check lite.backlight(true) and lite.backlight(false), "both backlights on"

block touchscreen:
  echo "touchscreen controller"
  let s = new_nds_scheduler()
  let i = IrqCtl()
  let inp = Input()
  let sp = new_test_spi(s, i, inp)
  check sp.tsc_read(s, 0x84) == 738 and sp.tsc_read(s, 0xF4) == 881,
        "temperatures TEMP0 / TEMP1 at 25 C"
  let t0 = sp.tsc_read(s, 0x84)
  let t1 = sp.tsc_read(s, 0xF4)
  let kelvin = (t1 - t0) * 8568 div 4096
  check kelvin in 295..302, "GBATEK's TP1-TP0 formula gives room temperature", $kelvin
  check sp.tsc_read(s, 0xA4) == 0, "battery input grounded"
  check sp.tsc_read(s, 0x8C) == 738 shr 4, "8-bit conversion"
  check sp.tsc_read(s, 0x90) == 0xFFF and sp.tsc_read(s, 0xD0) == 0, "released: Y FFFh, X 0"
  check sp.tsc_read(s, 0xB0) == 0 and sp.tsc_read(s, 0xC0) == 0xFFF, "released: Z1 0, Z2 FFFh"
  inp.touching = true; inp.touch_x = 128; inp.touch_y = 96
  let x = sp.tsc_read(s, 0xD0)
  let y = sp.tsc_read(s, 0x90)
  let z1 = sp.tsc_read(s, 0xB0)
  let z2 = sp.tsc_read(s, 0xC0)
  check (x - 0x200) * 254 div (0xE00 - 0x200) == 128 and (y - 0x200) * 190 div (0xA00 - 0x200) == 96,
        "X/Y convert back to the pixel (GBATEK formula)", $x & " " & $y
  check ((x - 0x200) * 254 * 2 + 0xC00) div (2 * 0xC00) == 128, "and rounding", $x
  check z1 > 0 and z2 > z1 and z2 < 0xFFF, "pressed: 0 < Z1 < Z2 < FFFh", $z1 & " " & $z2
  # GBATEK formula 1 recovers R_TOUCH (1000 ohm) with Rx_plate = 400
  let rt = 400.0 * float(x) / 4096 * (float(z2) / float(z1) - 1)
  check abs(rt - 1000) < 20, "Rtouch from X, Z1, Z2 ~ 1000 ohm", $rt
  check (inp.extkeyin() and 0x40) == 0, "pen down in EXTKEYIN (PENIRQ enabled, mode 0)"
  discard sp.tsc_read(s, 0xD1)                    # power-down mode 1
  check (inp.extkeyin() and 0x40) != 0, "power-down mode 1 disables PENIRQ"
  discard sp.tsc_read(s, 0x84)
  check (inp.extkeyin() and 0x40) == 0, "mode 0 enables it again"
  check sp.tsc_read(s, 0x60 or 0x80) == 0, "AUX in differential mode reads 0"

block microphone:
  echo "microphone"
  let s = new_nds_scheduler()
  let i = IrqCtl()
  let sp = new_test_spi(s, i, Input())
  check sp.tsc_read(s, 0xE4) == 0x800, "amp off: mid-scale"
  sp.pm_write(s, 2, 1); sp.pm_write(s, 3, 3)
  check sp.tsc_read(s, 0xE4) == 0x800 and sp.tsc_read(s, 0xEC) == 0x80,
        "nothing queued: silence (12-bit 800h, 8-bit 80h)"
  # 1 kHz sine at 16 kHz, full scale
  var wave: seq[int16]
  for k in 0 ..< 16000: wave.add int16(round(32767 * sin(2 * PI * float(k) / 16)))
  s.now = 100_000
  sp.mic.push(wave, 16000)
  var lo = 0xFFF
  var hi = 0
  var prev = -1
  var crossings = 0
  let start = s.now
  while s.now < start + SEC div 10:               # 100 ms, sampled at 32 kHz
    let v = sp.tsc_read(s, 0xE4)
    lo = min(lo, v); hi = max(hi, v)
    if prev >= 0 and prev < 0x800 and v >= 0x800: inc crossings
    prev = v
    s.now = max(s.now, start) + SEC div 32000 - (s.now - start) mod (SEC div 32000)
  check lo < 0x40 and hi > 0xFC0, "gain 160: full-scale input swings the full 12 bits", $lo & ".." & $hi
  check crossings in 99..101, "1 kHz played against emulated time", $crossings
  sp.pm_write(s, 3, 0)
  let v = sp.tsc_read(s, 0xE4)
  check abs(v - 0x800) <= 0x100, "gain 20: an eighth of the swing", $v
  s.now += 2 * SEC
  check sp.tsc_read(s, 0xE4) == 0x800 and sp.mic.queued() == 0, "run dry: silence again"

block flash:
  echo "firmware flash"
  let s = new_nds_scheduler()
  let i = IrqCtl()
  let sp = new_test_spi(s, i, Input())
  proc status(): uint8 =
    discard sp.xfer(s, FL, 0x05)
    sp.xfer(s, FL_LAST, 0)
  discard sp.xfer(s, FL_LAST, 0x06)                 # WREN
  check status() == 2, "WREN sets WEL"
  for b in [0x02'u8, 0x03, 0xFD, 0x00]: discard sp.xfer(s, FL, b)  # PP 3FD00
  discard sp.xfer(s, FL_LAST, 0x5A)
  let t0 = s.now
  check status() == 3, "page program: WIP and WEL while it runs"
  var t = s.now
  while (status() and 1) != 0: t = s.now
  let ms = float(t - t0) * 1000 / float(MASTER_HZ)
  check abs(ms - 1.2) < 0.05, "page program busy 1.2 ms", $ms
  check status() == 0, "WEL clears when it finishes"
  discard sp.xfer(s, FL_LAST, 0x06)
  for b in [0xDB'u8, 0x03, 0xFD]: discard sp.xfer(s, FL, b)
  discard sp.xfer(s, FL_LAST, 0x00)                 # PE 3FD00
  let e0 = s.now
  for b in [0x03'u8, 0x03, 0xFD]: discard sp.xfer(s, FL, b)
  let during = sp.xfer(s, FL_LAST, 0x00)
  check during == 0, "a read while erasing is ignored"
  while (status() and 1) != 0: discard
  let ems = float(s.now - e0) * 1000 / float(MASTER_HZ)
  check abs(ems - 10) < 0.1, "page erase busy 10 ms", $ems
  check sp.firmware[0x3FD00] == 0xFF, "page erased"
  discard sp.xfer(s, FL_LAST, 0xB9)                 # deep power-down
  discard sp.xfer(s, FL, 0x9F)
  check sp.xfer(s, FL_LAST, 0) == 0, "deep power-down: RDID ignored"
  discard sp.xfer(s, FL_LAST, 0xAB)
  discard sp.xfer(s, FL, 0x9F)
  check sp.xfer(s, FL_LAST, 0) == 0x20, "released: RDID answers 20h"

# ---------------------------------------------------------------------------
# Sleep and the lid, on a whole machine (no ROM: the CPUs idle)

block sleep_lid:
  echo "sleep and lid"
  let n = new_nds(newSeq[uint8](0x200), @[], @[], @[], force_hle = true)
  n.rtc.set_fixed_clock(n.sched, to_calendar_seconds(2024, 1, 1, 0, 0, 0))
  n.run_frame()
  n.irq7.ie = IRQ_LID
  n.arm7.halted = true
  n.sleeping = true
  n.irq7.iff = 0
  let t0 = n.sched.now
  let f0 = n.gpu.frame_count
  for k in 0..9: n.run_frame()
  check n.sleeping and n.sched.now == t0 and n.gpu.frame_count == f0,
        "asleep: the master clock and video stand still"
  n.irq7.iff = 1                                     # a V-blank flag doesn't wake
  n.irq7.ie = n.irq7.ie or 1
  n.run_frame()
  check n.sleeping, "a pending non-wake IRQ doesn't end sleep"
  n.set_lid(true)
  check (n.input.extkeyin() and 0x80) != 0, "lid closed: EXTKEYIN bit 7"
  n.run_frame()
  check n.sleeping, "closing the lid doesn't wake"
  n.set_lid(false)
  check (n.irq7.iff and IRQ_LID) != 0, "opening raises IF.22"
  n.run_frame()
  check not n.sleeping and n.sched.now > t0, "opening the lid ends sleep"
  # keypad wake
  n.irq7.ie = IRQ_KEY
  n.input.keycnt7 = 0x4001                           # A, IRQ on
  n.irq7.iff = 0
  n.sleeping = true
  n.arm7.halted = true
  n.run_frame()
  n.set_button(nbA, true)
  n.run_frame()
  check not n.sleeping, "a KEYCNT keypad IRQ ends sleep"
  n.set_button(nbA, false)
  # RTC alarm wake: the RTC's time runs on while asleep
  n.irq7.ie = IRQ_SIO
  n.irq7.iff = 0
  n.rtc.write_rcnt(0x8100, 0xFFFF)
  n.rtc.rtc_cmd(wcmd(4), [0x02'u8])                  # per-minute edge
  let ticks0 = n.rtc.now_ticks()
  n.sleeping = true
  n.arm7.halted = true
  let t1 = n.sched.now
  var frames = 0
  while n.sleeping and frames < 5000:
    n.run_frame()
    inc frames
  let slept = float(n.rtc.now_ticks() - ticks0) / float(TICK_HZ)
  check not n.sleeping and n.sched.now >= t1, "the minute carry's SI IRQ ends sleep"
  check slept > 1.0 and slept < 61.0 and frames > 50, "the RTC counted the sleep", $slept & " s"
  # power off
  n.spi.power_off = true
  let t2 = n.sched.now
  n.run_frame()
  check n.sched.now == t2, "powered off: nothing runs"

if failures > 0:
  echo failures, " failure(s)"
  quit(1)
echo "all passed"
