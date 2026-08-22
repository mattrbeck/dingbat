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
  ##
  ## ---- REFUTED 2026-08-21: it is NOT a $FF05 read-sample point -------------
  ##
  ## The serial unit turned out to have exactly this shape and the fix was a
  ## per-unit read latch (SERIAL_CPU_SAMPLE_T in gb.nim): the serial tap edge
  ## lands on the LAST T-cycle of its M-cycle, dingbat runs the whole bus half
  ## at the TOP of the M-cycle, and a CPU access in that M-cycle is entitled to
  ## the PRE-edge state. `-d:gb_phase_trace` says the timer's own events land on
  ## the same T-cycle -- `TIMIRQ t=3/4` for the reload, and every TAC tap edge
  ## is at `tdiv = 0 mod 2^s` with `2^s` a multiple of 4, i.e. the M-cycle's
  ## last T -- so the same latch was built for $FF05 and measured over the 440
  ## `tima` + `speedchange` rows:
  ##
  ##   shipping (the read sees its own M-cycle's change)   416 / 440
  ##   $FF05 reads the value before ANY change this M-cycle 331   (-85)
  ##   $FF05 reads the value before the RELOAD only         398   (-18)
  ##
  ## So the two units are genuinely asymmetric on the same T-cycle: hardware's
  ## TIMA read DOES see an increment (and a reload) that landed inside its own
  ## M-cycle, and hardware's SB/SC/IF read does NOT see the shift that landed
  ## inside its own. That asymmetry is also why `IF_READ_SAMPLE_T = -1` (the
  ## latch in front of the whole M-cycle, timer included) costs thirteen `tima`
  ## rows while the serial-only version costs none. Do not re-run either cell.

const SPEED_SWITCH_IRQ_LEAF_HOLD_T* {.intdefine.} = 8
  ## **The aborted-halt leaf leaves the divider two M-cycles behind the CPU**
  ## -- the oscillator restart the halt exists to wait out, seen through a ROM
  ## that refuses to wait. T-cycles the divider owes before it counts again
  ## (`GbTimer.hold_t`); CGB E owes half
  ## (`GbQuirks.spsw_irq_leaf_hold_short`). 0 compiles it out.
  ##
  ## It has to be the DIVIDER that stops and not the CPU: inserting real time
  ## with the whole CPU-clock domain frozen was tried first and is exactly a
  ## no-op here, because every quantity these ROMs read is counted in CPU
  ## M-cycles between the reset and the read, and frozen time adds none.
  ##
  ## **It costs 0.34% of the GB core**, and that is the whole reason the
  ## compile-out exists. `timer_tick`'s fast-path guard is on the hottest path
  ## in the emulator (~16% of a CGB profile) and this adds one load and one
  ## test to it: measured with `tools/gbgate/build.sh HEAD HEAD` +
  ## `tools/gbppu/counters.sh` on Pokemon Crystal, 2400 frames, identical
  ## `cycles=` on both arms, 24,739,466,028 retired instructions at
  ## `-d:SPEED_SWITCH_IRQ_LEAF_HOLD_T=0` against 24,822,560,287 shipping.
  ## Folding `hold_t` into `countdown`'s sign to get the test back for free was
  ## considered and rejected: `countdown` is serialized and a $FF05 write
  ## clears it, so the hold would inherit both.
  ##
  ## This is the leaf where an interrupt is ALREADY pending when STOP is
  ## fetched, so the switch's halt never starts. c-sp's own
  ## `speed-switch/caution/WARNING.md` is the mechanism: "The roms in this
  ## folder prematurely terminate the HALT mode period that follows STOP when
  ## switching the CPU speed. Purpose of that HALT mode period is to allow for
  ## oscillation stabilization before returning control to the CPU", and he
  ## records his own CPU CGB E going unstable for a while after running them.
  ## So the quantity here is not a tuning constant looking for a home: it is
  ## how much divider the oscillator loses when the wait is skipped, and the
  ## revision split is the same silicon difference the ROM's own `OFS_B`
  ## encodes.
  ##
  ## Measured off `spsw-interrupts`' second and third blocks, which are
  ## anchored on the STOP itself rather than on a divider event, with a
  ## `-d:gb_div_read_trace` build printing the divider at each `$FF04`/`$FF05`
  ## read:
  ##
  ##   CGB B/C, `IMMEDIATE_INTERRUPT_DIV` at DELAY $31 / $32
  ##       hardware  DIV = $00 / $01   => divider < 256 then >= 256
  ##       dingbat   260 / 264         => 5..8 T too high, i.e. 2 M-cycles
  ##   CGB E, the same test at DELAY $30 / $31
  ##       dingbat   256 / 260         => 1..4 T too high, i.e. 1 M-cycle
  ##
  ## and the `IMMEDIATE_INTERRUPT_TIMA` block agrees cell for cell on both,
  ## with no freedom left: it reads TIMA off a 16 KHz tap, so the same shift
  ## has to move the reads across a 256-count boundary in the same direction.
  ##
  ## **Why this is invisible on the stall leaf.** Everything `spsw-interrupts`'
  ## FIRST block reads is anchored on a TIMA overflow -- a divider event -- so
  ## holding the divider moves the whole chain in real time and leaves every
  ## reading at the same divider value. `spsw-div` is anchored on the
  ## instruction stream and WOULD see it, which is why the hold is on this leaf
  ## only and `spsw-div` stays green either way.

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
        when TIMER_IRQ_RUN_LEAD != 0:
          # The overflow edge, one M-cycle in front of the reload the countdown
          # arms. Only handle_interrupts reads it. See TIMER_IRQ_RUN_LEAD.
          gb.interrupts.timer_interrupt_early = true
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
  var cycles = cycles
  when SPEED_SWITCH_IRQ_LEAF_HOLD_T != 0:
    if t.hold_t > 0:
      # The divider owes time (SPEED_SWITCH_IRQ_LEAF_HOLD_T): the CPU clock is
      # running for the caller but not yet for this unit, so consume the span
      # without counting, serial shifter included.
      let n = min(t.hold_t, cycles)
      t.hold_t -= n
      cycles   -= n
      if cycles == 0: return
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
  const no_hold = SPEED_SWITCH_IRQ_LEAF_HOLD_T == 0
  if t.countdown < 0 and (no_hold or t.hold_t == 0) and not serial.shifting:
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
  result = period - (int(t.tdiv) and (period - 1))
  when APU_SPSW_TAP_LAG_T != 0:
    # Double speed only -- the lag rides the DOUBLE-speed tap (bit 13), and a
    # switch back to single speed leaves it behind. gambatte's
    # `speedchange2_ch2_nr52_{1,2}b` are what say so: they end in SINGLE speed
    # after one switch each way, so `spsw_fs_lag` is set, and hardware's `F0`
    # is the UNDELAYED length clock. Ungated they were the only two rows in
    # the 208-row family this mechanism got wrong (and it fixes six).
    if gb.apu.spsw_fs_lag and gb.memory.current_speed == 1:
      result += APU_SPSW_TAP_LAG_T

const SPEED_SWITCH_DIV_RESET_T_SLOW* {.intdefine.} = 4
  ## **The switch reset reaches the divider's SLOW taps one M-cycle before it
  ## reaches the fast ones.** T-cycles of divider between the STOP fetch and
  ## the point the slow taps are judged at; SPEED_SWITCH_DIV_RESET_T is the
  ## same thing for the fast ones. Setting the two equal compiles the split
  ## out entirely and restores the single-sample-point spelling.
  ##
  ## This is the "second mechanism" SPEED_SWITCH_DIV_RESET_T's own write-up
  ## below says is needed, and it only became measurable once the running
  ## CPU's TIMA dispatch moved (`TIMER_IRQ_RUN_LEAD`): these ROMs are anchored
  ## on a timer IRQ, so the whole family's ruler shifted one M-cycle and the
  ## old sweep table went stale with it. Re-swept over all 208 `speedchange`
  ## rows, one build per cell, with the lead on:
  ##
  ##   fast (SPEED_SWITCH_DIV_RESET_T), slow held at 4:
  ##      T      7   *8    9   10   11*  12
  ##      rows 188  202  202  202  202  190
  ##   slow (this), fast held at 8:
  ##      T    0..3  *4    5    6    7*   8 (= no split)
  ##      rows 194  202  202  202  202  194
  ##   SPEED_SWITCH_DIV_SLOW_BIT, at fast 8 / slow 4:
  ##      bit    4    6   *8    9*   10   16
  ##      rows 194  198  202  202  198  198
  ##
  ## Three strict two-sided maxima, and both T plateaus are exactly one
  ## M-cycle wide -- the ROMs saying the quantity is M-cycle quantised rather
  ## than the sweep being flat. 202/208 against 192 for the best single
  ## sample point that was reachable before.
  ##
  ## **What "slow" means, and why the threshold is where it is.** The gambatte
  ## family walks four TAC settings across the switch -- `tima00` = TAC $04
  ## (tap bit 9), `tima01` = $05 (bit 3), `tima02` = $06 (bit 5), `tima03` =
  ## $07 (bit 7) -- and the APU's frame sequencer rides the same reset off bit
  ## 12 (13 in double speed), which is what the `ch2_nr52` arms read out
  ## through NR52's channel-2 bit. Bits 3, 5 and 7 all want 8; bit 9 and the
  ## APU's bit both want 4, and the bit sweep above is two-sided on that
  ## boundary from either side (putting bit 7 in the slow group costs four
  ## rows, taking bit 9 out of it costs four). The two halves are independent
  ## and additive: the APU tap alone (`SLOW_BIT = 16`) is worth the four
  ## `*_ch2_nr52_1a` rows and bit 9 the four `*_tima00_1{a,b}` rows.
  ##
  ## So the split is monotone in the tap's height, which is what a ripple
  ## divider would give: a high bit's rise lags the count that causes it, so a
  ## reset arriving where that bit is nominally about to go high finds it still
  ## low and produces no falling edge, while a low bit has long since settled.
  ## That reading is a hypothesis; the three sweeps are the result. What it is
  ## NOT is one lead for everything -- the previous write-up's
  ## `tima00_1a`-vs-`tima02_2a` contradiction (same offset from the tap,
  ## opposite answers) is exactly this split seen through a single constant,
  ## and it dissolves once the two domains are allowed to differ.
const SPEED_SWITCH_DIV_SLOW_BIT* {.intdefine.} = 9
  ## The lowest TIMA tap bit judged at the SLOW point. The APU tap (12 / 13)
  ## is always slow. See SPEED_SWITCH_DIV_RESET_T_SLOW for the sweep.
const SPEED_SWITCH_DIV_RESET_T* {.intdefine.} = 8
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
  ##     T      0    1    2    3    4    5    6    7   *8    9   10   11*  12
  ##     rows 176  176  176  176  188  188  188  188  194  194  194  194  182
  ##
  ## A strict two-sided maximum, and the plateau is exactly one M-cycle wide —
  ## which is the ROMs saying the quantity is M-cycle quantised rather than the
  ## sweep being flat. 8 is the round value in it.
  ##
  ## **This table was re-swept on 2026-08-21 and the maximum MOVED, from the
  ## [4,7] plateau to [8,11].** Nothing about the divider changed; the ROMs'
  ## own ruler did. Every one of them is anchored on a timer IRQ, and the
  ## running CPU's dispatch of a TIMA overflow moved one M-cycle earlier
  ## (`TIMER_IRQ_RUN_LEAD`), so the whole family's timeline shifted with it.
  ## The old table (182/192/186/182 across the same range) is what this sweep
  ## reads on the old anchor, and the constant's own last paragraph predicted
  ## the move: "this constant would have to become 8 to keep the same ten
  ## rows". Do not reuse a measured table across a phase change — re-derive.
  ##
  ## **The contradiction that used to stop it here is now a SECOND SAMPLE
  ## POINT**, and it is measured: see SPEED_SWITCH_DIV_RESET_T_SLOW above.
  ## `speedchange_tima00_1a` (TAC = $04, tap bit 9) sits four counts below its
  ## tap's half-period at the reset, exactly where `speedchange_tima02_2a`
  ## (TAC = $06, tap bit 5) sits below its own, and hardware clocks TIMA on
  ## the tap-5 one and not the tap-9 one — so no single lead can satisfy both.
  ## Letting the slow taps (bit 9, and the APU's bit 12/13) be judged one
  ## M-cycle before the fast ones (bits 3, 5, 7) satisfies all of them, and
  ## takes 208-row `speedchange` from 194 to **202**.
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
  when defined(gb_div_read_trace):
    # Diagnostic (tools only; compiled out of every shipping build). The full
    # 16-bit divider behind each DIV/TIMA read, which is what turns a ROM that
    # prints one byte per measurement into a ruler with T-cycle resolution:
    # DIV only shows the high byte and TIMA only shows the tap's edge count,
    # so a row that is one M-cycle wrong and a row that is 255 counts wrong
    # look identical on screen. This is how SPEED_SWITCH_IRQ_LEAF_HOLD_T's
    # 5..8 T bracket was read off c-sp's spsw-interrupts.
    if idx == 0xFF04: echo "DIVREAD tdiv=", t.tdiv
    if idx == 0xFF05: echo "TIMAREAD tima=", t.tima, " tdiv=", t.tdiv
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
    let old_tdiv = t.tdiv
    t.tdiv = 0
    if apu_before == 1: tick_frame_sequencer(gb.apu, gb)
    gb.scheduler.clear(etAPUFrameSeq)
    gb.scheduler.schedule(apu_div_phase(t, gb), etAPUFrameSeq)
    timer_check_edge(t, gb, on_write = true)
    # The serial clock tap sees the reset too; a high->low transition of
    # the tapped bit shifts (gambatte start_late_div_write serial tests).
    # `old_tdiv` rather than the (already zeroed) counter because the level the
    # store is compared against is the one at the TOP of its M-cycle, not after
    # mem_write's bus half has run the divider through it: SERIAL_DIV_WRITE_LEAD_T
    # in serial.nim carries the two-sided measurement.
    if gb.serial.shifting: serial_div_write_edge(gb.serial, gb, old_tdiv)
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


proc timer_speed_switch_div_reset_split(t: GbTimer; gb: GB) =
  ## The switch reset when the slow taps are judged at a different point from
  ## the fast ones -- see SPEED_SWITCH_DIV_RESET_T_SLOW. `timer_write`'s $FF04
  ## body, opened up so the two domains can be handed different pre-levels.
  timer_tick(t, gb, SPEED_SWITCH_DIV_RESET_T_SLOW)
  let apu_slow  = ((t.tdiv shr apu_div_bit(gb)) and 1) == 1
  let tima_slow = t.enabled and ((t.tdiv and (1'u16 shl t.bit_for_tima)) != 0)
  # CGB E moves the boundary down to the 65 KHz tap; see
  # `GbQuirks.spsw_div_mid_taps_slow`.
  let slow_bit  = if gb.quirks.spsw_div_mid_taps_slow: 5
                  else: SPEED_SWITCH_DIV_SLOW_BIT
  let slow_tap  = t.bit_for_tima >= slow_bit
  # A slow tap is LATCHED at the slow point: the divider's own crossing of that
  # tap between here and the reset is the ripple lag itself and so is invisible
  # to it. Gating the tap off for the remaining T-cycles is what says that.
  #
  # Restoring `previous_bit = tima_slow` afterwards without gating -- which is
  # what this did until 2026-08-22 -- lets the SAME fall be counted twice when
  # it lands in the window: once by the tick, and again by the reset, whose
  # pre-level has just been forced back up. The window is exactly one M-cycle
  # wide, so it is one delay value in an AGE sweep and nothing else in the
  # tree reaches it: c-sp `speed-switch/spsw-tima-cgbBC`'s "right on the 1->0
  # edge of the respective DIV bit" cell (TEST_INC_EDGE 238, TAC $04, tap 9)
  # read $82/$83 for hardware's $81/$82, while 237 and 239 either side were
  # already exact. See SPEED_SWITCH_DIV_RESET_T_SLOW.
  let was_enabled = t.enabled
  if slow_tap:
    t.enabled      = false
    t.previous_bit = false
  timer_tick(t, gb, SPEED_SWITCH_DIV_RESET_T - SPEED_SWITCH_DIV_RESET_T_SLOW)
  if slow_tap:
    t.enabled      = was_enabled
    t.previous_bit = tima_slow
  let old_tdiv = t.tdiv
  t.tdiv = 0
  if apu_slow: tick_frame_sequencer(gb.apu, gb)
  gb.scheduler.clear(etAPUFrameSeq)
  gb.scheduler.schedule(apu_div_phase(t, gb), etAPUFrameSeq)
  timer_check_edge(t, gb, on_write = true)
  if gb.serial.shifting: serial_div_write_edge(gb.serial, gb, old_tdiv)

proc timer_speed_switch_div_reset*(t: GbTimer; gb: GB) =
  ## The DIV reset a KEY1 speed switch performs (memory.nim's stop_instr).
  ##
  ## Ordinary `timer_write($FF04, 0)`, one M-cycle of divider later than the
  ## STOP fetch dingbat charges the opcode as -- see SPEED_SWITCH_DIV_RESET_T.
  when APU_SPSW_TAP_LAG_T != 0:
    # Called before memory.nim flips `current_speed`, so "still single" IS
    # "about to enter double". See APU_SPSW_TAP_LAG_T for why this toggles.
    if gb.memory.current_speed == 0: gb.apu.spsw_fs_lag = not gb.apu.spsw_fs_lag
  when SPEED_SWITCH_DIV_RESET_T_SLOW != SPEED_SWITCH_DIV_RESET_T:
    timer_speed_switch_div_reset_split(t, gb)
  else:
    when SPEED_SWITCH_DIV_RESET_T != 0:
      timer_tick(t, gb, SPEED_SWITCH_DIV_RESET_T)
    when defined(gb_ss_trace):
      # Diagnostic (tools only; compiled out of every shipping build). One line
      # per speed switch, printed at the instant the reset happens, with the
      # divider phase the reset is about to be judged against. That phase is
      # the whole content of the `speedchange*_tima0N_*` family and nothing
      # else reports it; pair it with the TIMAIRQ / IRQDISP lines the same
      # define turns on above and in cpu.nim, which give the anchor those ROMs
      # hang their timeline off.
      echo "SSWITCH pc=", toHex(int(gb.cpu.pc), 4),
           " tdiv=", t.tdiv, " (mod64=", int(t.tdiv) mod 64,
           " mod256=", int(t.tdiv) mod 256, " mod1024=", int(t.tdiv) mod 1024,
           ") tima=", toHex(int(t.tima), 2),
           " tap=", t.bit_for_tima, " spd=", gb.memory.current_speed
    timer_write(t, gb, 0xFF04, 0)
