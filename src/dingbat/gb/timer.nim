# GB Timer (included by gb.nim)

proc new_gb_timer*(): GbTimer =
  GbTimer(tdiv: 0, tima: 0, tma: 0, enabled: false, clock_select: 0,
          bit_for_tima: 9, previous_bit: false, countdown: -1)

proc skip_boot*(t: GbTimer; cgb, native: bool) =
  # Internal divider at PC=0x100, per model. DMG-ABC: 0xABC8 (mooneye
  # boot_div-dmgABCmgb pins the phase of DIV reads; boot_sclk_align then
  # pins the serial shift clock tap — see serial.nim). CGB booting a CGB
  # cart: ~0x1Exx (gambatte div/start_inc). CGB booting a DMG cart: 0x2674
  # (mooneye misc/boot_div-cgbABCDE) — the boot ROM's compatibility-palette
  # work makes the DMG-cart handoff ~2000 cycles later.
  t.tdiv = if not cgb: 0xABC8'u16
           elif native: 0x1E9C'u16
           else: 0x2674'u16

proc timer_reload_tima(t: GbTimer; gb: GB) =
  gb.interrupts.timer_interrupt = true
  t.tima = t.tma

proc timer_check_edge(t: GbTimer; gb: GB; on_write = false) =
  let current_bit = t.enabled and ((t.tdiv and (1'u16 shl t.bit_for_tima)) != 0)
  if t.previous_bit and not current_bit:
    t.tima = t.tima + 1
    if t.tima == 0:
      if on_write:
        timer_reload_tima(t, gb)
      else:
        t.countdown = 4
  t.previous_bit = current_bit

proc timer_tick*(t: GbTimer; gb: GB; cycles: int) =
  let serial = gb.serial
  for _ in 0 ..< cycles:
    if t.countdown > -1: dec t.countdown
    if t.countdown == 0: timer_reload_tima(t, gb)
    t.tdiv = t.tdiv + 1
    timer_check_edge(t, gb)
    if serial.shifting: serial_tick(serial, gb)

proc timer_read*(t: GbTimer; idx: int): uint8 =
  case idx
  of 0xFF04: uint8(t.tdiv shr 8)
  of 0xFF05: t.tima
  of 0xFF06: t.tma
  of 0xFF07: 0xF8'u8 or (if t.enabled: 0b100'u8 else: 0'u8) or t.clock_select
  else:      0xFF'u8

proc timer_write*(t: GbTimer; gb: GB; idx: int; val: uint8) =
  case idx
  of 0xFF04:
    t.tdiv = 0
    timer_check_edge(t, gb, on_write = true)
    # The serial clock tap sees the reset too; a high->low transition of
    # the tapped bit shifts (gambatte start_late_div_write serial tests)
    if gb.serial.shifting: serial_tick(gb.serial, gb)
  of 0xFF05:
    if t.countdown != 0:
      t.tima     = val
      t.countdown = -1
  of 0xFF06:
    t.tma = val
    if t.countdown == 0: t.tima = t.tma
  of 0xFF07:
    t.enabled      = (val and 0b100) != 0
    t.clock_select = val and 0b011
    t.bit_for_tima = case t.clock_select
      of 0b00: 9
      of 0b01: 3
      of 0b10: 5
      else:    7
    timer_check_edge(t, gb, on_write = true)
  else: discard
