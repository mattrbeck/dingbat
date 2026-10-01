## ARM7 RTC port 0x4000138: a Seiko S-35180 driven bit-by-bit through three
## GPIO lines (data bit 0, clock bit 1, select bit 2; direction bits 4-6).
## Same family as the GBA cart RTC (gba/rtc.nim), different pins and
## register set. STUB: reads return the written value. TODO(rtc): command
## protocol (status regs, date/time from the host clock, alarms, IRQ).

type
  Rtc* = ref object
    reg*: uint16

proc read_reg*(r: Rtc): uint16 = r.reg
proc write_reg*(r: Rtc; v: uint16) = r.reg = v
