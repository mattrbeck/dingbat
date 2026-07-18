# GB Timer (included by gb.nim)

proc new_gb_timer*(): GbTimer =
  GbTimer(tdiv: 0, tima: 0, tma: 0, enabled: false, clock_select: 0,
          bit_for_tima: 9, previous_bit: false, countdown: -1)

proc skip_boot*(t: GbTimer; gb: GB) =
  # Internal 16-bit divider at PC=0x100, per hardware model. The mooneye
  # boot_div-* ROMs read DIV six times at fixed cycle offsets and assert the
  # six high-byte values, which pins both the base (high byte) and the phase
  # (low byte) of the 16-bit counter at handoff. The value differs per model
  # because each boot ROM runs a different number of cycles. Each seed below
  # was found by sweeping for the (narrow, ~4-wide) window that satisfies that
  # model's boot_div ROM; DMG-ABC 0xABC8 additionally pins boot_sclk_align
  # (serial tap, serial.nim); native CGB 0x1E9C is gambatte div/start_inc (the
  # real CGB gameplay path).
  let native = gb.cgb_flag != cgbNone
  t.tdiv = case gb.boot_model
    of bmDmg0:          0x182C'u16   # boot_div-dmg0
    of bmDmgABC, bmMgb: 0xABC8'u16   # boot_div-dmgABCmgb
    of bmSgb, bmSgb2:   0xD85C'u16   # boot_div-S / boot_div2-S
    of bmCgb0:          0x2880'u16   # misc/boot_div-cgb0
    of bmAgb:           0x2678'u16   # misc/boot_div-A
    of bmCgbABCDE:
      if native: 0x1E9C'u16 else: 0x2674'u16  # misc/boot_div-cgbABCDE

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
