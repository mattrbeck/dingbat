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
    of bmSgb, bmSgb2:
      # The real SGB boot duration depends on the header byte VALUES the DMG
      # side transfers to the SNES: mooneye's boot_div2-S exists purely to
      # expose hardcoded durations (its source: "This test uses a different
      # checksum bytes than the other one to expose hard-coded boot ROM
      # durations"). The two -S ROMs differ ONLY in the global-checksum bytes
      # at 0x14E/0x14F, whose popcount is 4 higher in boot_div2-S, and its
      # passing DIV window sits exactly 16 T-cycles lower — i.e. each set bit
      # in the transferred header shortens the boot by 4 T-cycles (a
      # value-dependent branch in the bit-banged ICD2 transfer loop). Model
      # the seed as 0xD85C (swept with boot_div-S, header popcount 273)
      # minus 4 per extra set bit in 0x100..0x14F. Only the harness ever
      # selects bmSgb/bmSgb2, so real carts are unaffected.
      var bits = 0
      for i in 0x100 .. 0x14F:
        if i < gb.cartridge.rom.len: bits += countSetBits(gb.cartridge.rom[i])
      uint16(0xD85C - 4 * (bits - 273))
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

proc apu_div_bit(gb: GB): int {.inline.} =
  ## Which bit of the internal divider clocks the APU frame sequencer.
  ##
  ## Pan Docs: the DIV-APU counter steps on a FALLING edge of DIV bit 4 (bit 5
  ## in double speed). DIV is the divider's high byte, so DIV bit 4 is internal
  ## bit 12: it toggles every 4096 counts, i.e. a 8192-count period = 512 Hz at
  ## 4.194304 MHz. In double speed the divider runs twice as fast, so the tap
  ## moves up one bit to keep the sequencer at 512 Hz.
  12 + int(gb.memory.current_speed)

proc timer_tick*(t: GbTimer; gb: GB; cycles: int) =
  let serial = gb.serial
  for _ in 0 ..< cycles:
    if t.countdown > -1: dec t.countdown
    if t.countdown == 0: timer_reload_tima(t, gb)
    t.tdiv = t.tdiv + 1
    timer_check_edge(t, gb)
    if serial.shifting: serial_tick(serial, gb)

proc apu_div_period*(gb: GB): int {.inline.} =
  ## Divider counts between APU-tap falling edges (8192 single / 16384 double
  ## speed — 512 Hz either way). These are raw scheduler cycles, so schedule
  ## them with `schedule`, not `schedule_gb` (which would scale them again).
  2 shl apu_div_bit(gb)

proc apu_div_phase*(t: GbTimer; gb: GB): int =
  ## Raw cycles until the divider's APU tap next falls. Equals the full period
  ## when the divider sits exactly on an edge boundary.
  let period = apu_div_period(gb)
  period - (int(t.tdiv) and (period - 1))

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
    # Resetting DIV drops every divider bit at once. If the APU tap was high,
    # that is a falling edge and the frame sequencer steps EARLY — this is what
    # SameSuite's apu/div_* tests check, and games use to phase-lock audio.
    # The sequencer is otherwise a scheduled event, so re-aim it at the new
    # phase. This costs ~0.8% on Crystal because games write DIV often; a lazy
    # re-aim (letting the stale event notice when it fires) is cheaper but NOT
    # equivalent — it can skip an edge falling before the stale target, and
    # measurably loses a SameSuite test.
    let apu_before = (t.tdiv shr apu_div_bit(gb)) and 1
    t.tdiv = 0
    if apu_before == 1: tick_frame_sequencer(gb.apu, gb)
    gb.scheduler.clear(etAPUFrameSeq)
    gb.scheduler.schedule(apu_div_phase(t, gb), etAPUFrameSeq)
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
