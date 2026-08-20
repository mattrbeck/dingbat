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

const TAC_SELECT_LEAD_T* {.intdefine.} = 4
  ## How many T-cycles BEFORE the end of a TAC write's M-cycle the NEWLY
  ## selected divider bit is read, when TAC.1-0 changes which bit TIMA is
  ## tapped off.
  ##
  ## Writing a different clock select can tick TIMA on its own: the multiplexer
  ## output falls if the bit being left is high and the bit being taken is low,
  ## and the falling-edge detector counts that as an edge (Pan Docs, "Timer
  ## Obscure Behaviour": "changing the value of TAC ... can increase TIMA once,
  ## and can also reset the counter to 0"). dingbat commits a write's byte after
  ## that M-cycle's bus tick (mem_write), so both halves of the comparison used
  ## to be read at the END of the M-cycle. Two gambatte families disagree about
  ## which half that is right for, and between them they pin one lead on one
  ## half:
  ##
  ## * `tima/tc00_late_tc01_1..8` switches $04 -> $05 (bit 9 -> bit 3) one NOP
  ##   later per member and reads TIMA a fixed 20 T after the write. The write
  ##   lands right where bit 9 RISES ($B600), so the family is a ruler of when
  ##   the arriving tap is read against a bit that only the write's own M-cycle
  ##   moves. Hardware `FF,FF,FF,FF,00,FE,FF,FF`; reading the new tap at the end
  ##   of the M-cycle gave `FF,FF,FF,00,FE,FF,FF,00` -- the same ladder one
  ##   member early.
  ## * `tima/tc00_tc01_late_tc00_of_{1,2}` switches back, $05 -> $04, on the
  ##   other side of a bit-3 edge, and `_2`'s `F0` needs the tap being LEFT read
  ##   at the end of the M-cycle ($B528, bit 3 high): read 4 T earlier it is
  ##   low, no edge is generated, and the row goes red.
  ##
  ## So only the arriving tap is early; the departing one stays the latched
  ## `previous_bit` the tick left behind. Two-sided on the family that measures
  ## it: 0 (the old behaviour) fails 8 rows, 4 fails 2, 8 fails 4 -- at 8 the
  ## ladder overshoots and takes `_7` down while `_5` is still red.
  ##
  ## `tc00_late_tc01_5` is the one member this does not reach, and it is not
  ## about the tap: its second increment comes from an ordinary bit-3 edge at
  ## $B610 and the ROM reads TIMA at $B614, exactly where dingbat's 4-cycle
  ## reload countdown expires, so it sees `FE` where hardware still reads `00`.
  ## That is a reload-vs-read phase question, and the countdown is not free to
  ## move for it: arming it at 5 takes the whole family from 14/16 to 8/16.

proc timer_reload_tima(t: GbTimer; gb: GB) =
  when defined(gb_phase_trace):
    echo "TIMIRQ t=", gb_phase, "/", gb_ticklen
  when defined(gb_ss_trace):
    # Diagnostic (tools only). The divider value the TIMA overflow's reload
    # landed on: the anchor every gambatte `speedchange*_tima0N_*` ROM lays its
    # timeline out from. See SPEED_SWITCH_DIV_RESET_T below.
    echo "TIMAIRQ tdiv=", t.tdiv, " tap=", t.bit_for_tima
  gb.interrupts.timer_interrupt = true
  t.tima = t.tma

proc timer_check_edge(t: GbTimer; gb: GB; on_write = false) =
  ## `on_write` = the edge came from a register write (DIV reset, TAC change)
  ## rather than the divider counting. Hardware puts a glitch overflow through
  ## the same one-M-cycle reload window as a natural one (Pan Docs "Timer
  ## Obscure Behaviour"; SameBoy increase_tima, DocBoy inc_tima) — and the
  ## immediate reload here IS that window, expressed at dingbat's commit
  ## point: the write lands AFTER its M-cycle's ticks, so "reload now" sits
  ## exactly one M-cycle after the edge the instruction caused. Arming the
  ## 4-T countdown instead double-counts the delay: measured 2026-08-14, it
  ## fails mooneye acceptance/timer/rapid_toggle on BOTH runners. What this
  ## phase cannot express is the window's INTERIOR (TIMA reading $00, the
  ## cycle-B TIMA-write-ignore/TMA-follow rules, for the glitch case) —
  ## flashcart material, see docs/pandocs-audit.md A6.
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

proc timer_tick_slow(t: GbTimer; gb: GB; cycles: int) =
  let serial = gb.serial
  when defined(gb_phase_trace):
    gb_phase = -1
    gb_ticklen = int32(cycles)
  for _ in 0 ..< cycles:
    when defined(gb_phase_trace): inc gb_phase
    if t.countdown > -1: dec t.countdown
    if t.countdown == 0: timer_reload_tima(t, gb)
    t.tdiv = t.tdiv + 1
    timer_check_edge(t, gb)
    if serial.shifting: serial_tick(serial, gb)

proc timer_tick*(t: GbTimer; gb: GB; cycles: int) {.inline.} =
  let serial = gb.serial
  # Fast path. The per-cycle loop below is called for every 4 T-cycles of
  # every memory access — it was ~16% of a CGB profile and ~18% of a DMG one —
  # yet in the overwhelming majority of those calls nothing at all happens
  # except the 16-bit divider counting up.
  #
  # Everything the loop can do is driven by one of three things, all of which
  # can be decided for the whole span up front:
  #   * the pending-TIMA-reload countdown (only live for 4 cycles after an
  #     overflow, and it is < 0 the rest of the time),
  #   * a serial shift (only while an internally-clocked transfer runs),
  #   * a falling edge of the DIV bit TIMA is tapped off.
  # None of them can *start* inside the span: countdown and shifting are only
  # armed by register writes, which happen between ticks.
  #
  # The tapped bit falls exactly when the incremented counter crosses a
  # multiple of 2^(bit+1), so the number of edges in the span is a subtraction
  # of two shifts. previous_bit is invariably `enabled and bit(tdiv)` on
  # entry — every path that changes tdiv, TAC or the tap runs
  # timer_check_edge — so no edge means TIMA cannot move, and all that is left
  # is to advance the counter and re-latch the bit. Bit-identical to the loop.
  if t.countdown < 0 and not serial.shifting:
    let t0 = uint32(t.tdiv)
    let t1 = t0 + uint32(cycles)
    let cur = t.enabled and ((t.tdiv and (1'u16 shl t.bit_for_tima)) != 0)
    # `previous_bit == cur` re-establishes the invariant locally rather than
    # trusting it, so the fast path is correct even if some future caller
    # changes tdiv without running an edge check.
    if t.previous_bit == cur:
      if not t.enabled:
        # No tap, so no edge can occur and TIMA cannot move: all the loop did
        # was count the divider up and re-latch a bit that stays false.
        t.tdiv = uint16(t1 and 0xFFFF'u32)
        t.previous_bit = false
        return
      # Closed-form TIMA advance. The tapped bit falls exactly when the
      # incremented counter crosses a multiple of 2^(bit+1), so the number of
      # falling edges in (t0, t1] is floor(t1/2^s) - floor(t0/2^s). That count
      # is what the per-cycle loop would have added to TIMA -- previous_bit is
      # true at every one of those cycles by construction (the bit is high for
      # the whole half-period leading up to a fall). It stays exact across the
      # divider's 16-bit wrap because 65536 is a multiple of 2^s for every tap
      # (s <= 10), so t1 may be left unwrapped for the shift.
      #
      # An overflow is the one thing that is NOT closed form: it arms a
      # 4-cycle countdown whose expiry (reload from TMA + timer IRQ) has to
      # land on its own cycle, and the countdown can then expire INSIDE the
      # same span. That case falls through to the loop, which is where it was
      # always handled. TIMA can advance by at most one step per 2^s cycles,
      # so for the 4-cycle spans this is called with the fall-through is one
      # span in 2^s -- rare, and it is the only path that raises an interrupt.
      let shift = t.bit_for_tima + 1
      let edges = int((t1 shr shift) - (t0 shr shift))
      if int(t.tima) + edges <= 0xFF:
        t.tima = uint8(int(t.tima) + edges)
        t.tdiv = uint16(t1 and 0xFFFF'u32)
        t.previous_bit = (t.tdiv and (1'u16 shl t.bit_for_tima)) != 0
        return
  timer_tick_slow(t, gb, cycles)

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

const SPEED_SWITCH_DIV_RESET_T* {.intdefine.} = 4
  ## **The switch leaf's DIV reset is one M-cycle after the STOP fetch, not on
  ## it** — T-cycles the divider counts between the two.
  ##
  ## STOP is a TWO-byte opcode on this leaf (Pan Docs' chart: "2 bytes, HALT
  ## mode, DIV reset, speed changes"), and the reset goes with the second byte,
  ## not the first. dingbat charges the whole instruction as one fetch M-cycle
  ## plus the stall, so its reset landed a whole M-cycle early. SameBoy makes
  ## the same choice from the other side — `stop()` calls `enter_stop_mode`
  ## (which is where its DIV reset lives) *before* `cycle_read(gb->pc++)` — and
  ## misses the same rows.
  ##
  ## **A phase, not a charge.** Only the divider domain moves; no time is
  ## spent, because the M-cycle is already inside the instruction's total (the
  ## stall). Ticking the whole MACHINE here instead — either on top of the
  ## stall or taken back out of it — is a straight refutation:
  ## 208-row `speedchange` goes 182 -> **142** / **143**, because the ~50
  ## `ly44_m3*` rows measure the PPU's dot advance across the switch to the dot
  ## and this moves it by 2-4. The reset point is the only thing that may move.
  ##
  ## The family that pins it is `speedchange[2]_tima0N_{1a,1b,2a,2b}`: N
  ## back-to-back `LDH ($4D),A ; STOP` pairs anchored on a timer IRQ, with `1`
  ## and `2` one M-cycle apart in WHERE THE STOP IS and `a`/`b` one M-cycle
  ## apart in where TIMA is read. The `1`/`2` axis holds the post-reset
  ## interval fixed, so the only thing it can move is the divider's phase at
  ## the reset — i.e. whether the reset's own falling edge on the TAC tap
  ## clocks TIMA once more. Swept one build per T-cycle over all 208
  ## `speedchange` rows:
  ##
  ##     T      0    1    2    3   *4    5    6    7*   8    9   10   11   12
  ##     rows 182  182  182  182  192  192  192  192  186  186  186  186  182
  ##
  ## A strict two-sided maximum, and the plateau is exactly one M-cycle wide —
  ## which is the ROMs saying the quantity is M-cycle quantised rather than the
  ## sweep being flat. 4 is the round value in it. Worth +10 `speedchange` and
  ## +2 `dma` (the two `hdma_late_m3speedchange_tima_scx1_ds` rows), nothing
  ## else in the tree moving.
  ##
  ## **What it does NOT close, and the contradiction that stops it.** Six rows
  ## resist, and they are not a matter of one more T-cycle: they need the reset
  ## to be a *different* distance out per TAC setting.
  ## `speedchange_tima00_1a` (TAC = $04, tap bit 9) has the divider at 508 mod
  ## 1024 at dingbat's reset point — four counts below the tap's half-period,
  ## exactly where `speedchange_tima02_2a` (TAC = $06, tap bit 5) sits at 28
  ## mod 64 — and hardware clocks TIMA on the tap-5 one and NOT on the tap-9
  ## one. Same offset from the tap, opposite answers, so no single lead
  ## satisfies both: T = 4 buys tima01/02/03 and loses `tima00_1a`/`_1b`. The
  ## same split appears again on the second switch (`speedchange2`), where the
  ## other three taps want 8 and tap 9 wants 4 — tap 9 is consistently one
  ## M-cycle behind the rest, in both directions. Whatever explains that is a
  ## second mechanism, and SameBoy does not have it either: it fails 20 of
  ## these 208 rows, including 14 of the 16 that are left here.
  ##
  ## **This value is relative to `mem_read`'s access phase, and the residual is
  ## not.** dingbat charges an M-cycle's ticks BEFORE returning a read's byte,
  ## so the STOP fetch that anchors this lead lands at the END of its M-cycle;
  ## sampling reads at the TOP instead (the serial work's `a_r = 0`) moves the
  ## anchor 4 T earlier and this constant would have to become 8 to keep the
  ## same ten rows. The post-reset interval, and therefore the `a`/`b` bracket,
  ## is unmoved by that — both ends are reads. So these rows neither support
  ## nor refute `a_r = 0`; they only tie the two together. The six residual
  ## rows DO refute it as their explanation, because what they disagree about
  ## is one TAC setting against another and any read-phase change moves every
  ## TAC setting by the same amount.

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
    let select = val and 0b011
    let bit = case select
      of 0b00: 9
      of 0b01: 3
      of 0b10: 5
      else:    7
    when TAC_SELECT_LEAD_T != 0:
      if bit != t.bit_for_tima:
        # The NEWLY selected tap is read TAC_SELECT_LEAD_T T-cycles before the
        # byte lands here; the tap being left is the latched one dingbat
        # already carries (previous_bit, as of the end of this M-cycle). Rewind
        # the divider for the check to get the new tap's early sample...
        let now = t.tdiv
        t.tdiv         = now - uint16(TAC_SELECT_LEAD_T)
        t.enabled      = (val and 0b100) != 0
        t.clock_select = select
        t.bit_for_tima = bit
        timer_check_edge(t, gb, on_write = true)
        # ...then hand the counter back at the divider it really sits on, with
        # the new tap's output latched there. Only the mux's own edge moves:
        # REPLAYING the rewound cycles under the new tap as well is refused
        # (`tc00_late_tc01_4` switches at $B600 with bit 3 falling right there,
        # and hardware's `FF` says that fall is not counted).
        t.tdiv         = now
        t.previous_bit = t.enabled and ((now and (1'u16 shl bit)) != 0)
        return
    t.enabled      = (val and 0b100) != 0
    t.clock_select = select
    t.bit_for_tima = bit
    timer_check_edge(t, gb, on_write = true)
  else: discard


proc timer_speed_switch_div_reset*(t: GbTimer; gb: GB) =
  ## The DIV reset a KEY1 speed switch performs (memory.nim's stop_instr).
  ##
  ## Ordinary `timer_write($FF04, 0)`, one M-cycle of divider later than the
  ## STOP fetch dingbat charges the opcode as -- see SPEED_SWITCH_DIV_RESET_T.
  when SPEED_SWITCH_DIV_RESET_T != 0:
    timer_tick(t, gb, SPEED_SWITCH_DIV_RESET_T)
  when defined(gb_ss_trace):
    # Diagnostic (tools only; compiled out of every shipping build). One line
    # per speed switch, printed at the instant the reset happens, with the
    # divider phase the reset is about to be judged against. That phase is the
    # whole content of the `speedchange*_tima0N_*` family and nothing else
    # reports it; pair it with the TIMAIRQ / IRQDISP lines the same define
    # turns on above and in cpu.nim, which give the anchor those ROMs hang
    # their timeline off.
    echo "SSWITCH pc=", toHex(int(gb.cpu.pc), 4),
         " tdiv=", t.tdiv, " (mod64=", int(t.tdiv) mod 64,
         " mod256=", int(t.tdiv) mod 256, " mod1024=", int(t.tdiv) mod 1024,
         ") tima=", toHex(int(t.tima), 2),
         " tap=", t.bit_for_tima, " spd=", gb.memory.current_speed
  timer_write(t, gb, 0xFF04, 0)
