# Timer implementation (included by gba.nim)

const
  TIMER_PERIODS   = [1, 64, 256, 1024]
  TIMER_EVENT_TYPES* = [etTimer0, etTimer1, etTimer2, etTimer3]
  # Counting starts 2 cycles after the enable write.
  TIMER_START_DELAY = 2
# Compile-time knobs. TIMER_STOP_DELAY: cycles the count runs on after a stop
# (0 = stops at the write). TIMER_OLD_COUNT: reads before the start cycle see
# the pre-enable count (false = the reload).
const TIMER_STOP_DELAY {.intdefine.} = 1
const TIMER_OLD_COUNT {.booldefine.} = true
const TIMER_START_OVERFLOW {.booldefine.} = true
  ## Enabling over a count stopped at 0xFFFF overflows on the start cycle,
  ## and that is a whole overflow, not just its interrupt: a timer-driven
  ## sound FIFO takes a sample and may ask for a refill (a cascaded timer
  ## counts it too: assumed, unmeasured). AGB SP, payloads/fifospk.s: a FIFO
  ## run after one that froze TM0 at 0xFFFF reads two more refill bursts (60
  ## cycles); these are the "spikes" in dbsuite fifodma's n = 14 and 24 cases.
  ## false: interrupt only. Compile-time knob, default true.

# The prescaler is free-running: a timer with period P ticks at absolute
# cycles divisible by P regardless of when it was enabled. Ticks are counted
# over (anchor, now], so a tick on the anchor cycle itself is excluded.
proc ticks_between(anchor, now: CycleCount; period: int): uint32 {.inline.} =
  uint32(now div CycleCount(period) - anchor div CycleCount(period))

proc cycles_until_overflow(tim: Timer; num: int): int =
  let period = TIMER_PERIODS[tim.tmcnt[num].frequency]
  let anchor = tim.cycle_enabled[num]
  let target = CycleCount(period) * (anchor div CycleCount(period) + CycleCount(0x10000 - int(tim.tm[num])))
  int(target - tim.gba.scheduler.cycles)

proc effective_reload(tim: Timer; num: int): uint16 {.inline.} =
  # A reload written on the overflow cycle or the one before is not yet visible.
  if tim.gba.scheduler.cycles <= tim.tmd_write_cycle[num] + 1:
    tim.tmd_prev[num]
  else:
    tim.tmd[num]

proc timer_overflow_event*(tim: Timer; num: int; scheduled = true) =
  when defined(itrace):
    itl("TOVF " & $num & " t=" & $tim.gba.scheduler.cycles)
  # TIMER_START_OVERFLOW: on the start cycle the enable has already
  # reloaded the count and raised the interrupt.
  let at_start = TIMER_START_OVERFLOW and scheduled and
                 tim.gba.scheduler.cycles == tim.cycle_enabled[num]
  if not at_start:
    tim.tm[num] = tim.effective_reload(num)
    tim.cycle_enabled[num] = tim.gba.scheduler.cycles
  if num < 3 and tim.tmcnt[num + 1].cascade and tim.tmcnt[num + 1].enable:
    tim.tm[num + 1] += 1
    if tim.tm[num + 1] == 0:
      tim.timer_overflow_event(num + 1, scheduled = false)
  let fifo_next = num <= 1 and tim.gba.apu.timer_overflow(num)
  if tim.tmcnt[num].irq_enable and not at_start:
    tim.gba.interrupts.raise_synced(IRQ_TIMER_BIT_BASE + num)
  if not tim.tmcnt[num].cascade:
    tim.gba.scheduler.schedule(tim.cycles_until_overflow(num), TIMER_EVENT_TYPES[num])
    if tim.tmcnt[num].irq_enable:
      tim.gba.interrupts.window_ahead(tim.cycles_until_overflow(num))
    if fifo_next:
      tim.gba.apu.dma_channels.fifo_window_book(tim.cycles_until_overflow(num))
    elif num <= 1 and (tim.gba.bus.sync_bits and 16) != 0:
      tim.gba.apu.dma_channels.fifo_window_stale()

proc new_timer*(gba: GBA): Timer =
  result = Timer(gba: gba)
  for i in 0..3:
    result.tmcnt[i] = TMCNT()
    result.tmd[i] = 0
    result.tm[i] = 0
    result.cycle_enabled[i] = 0

proc get_current_tm(tim: Timer; num: int): uint16 =
  if tim.tmcnt[num].enable and not tim.tmcnt[num].cascade:
    tim.gba.bus.volatile_read = true  # counts without events
    tim.gba.bus.volatile_pc = tim.gba.cpu.r[15]
    tim.gba.bus.dyn_vol = true
    # Include un-ticked bus cycles: a DMA reads inside event dispatch, where
    # catch_up is suppressed, and each transfer must see the live count (AGS
    # aging cartridge DMA-captures consecutive timer values).
    let now = tim.gba.scheduler.cycles + CycleCount(tim.gba.bus.cycles)
    # Before the start cycle (cycle_enabled, up to TIMER_START_DELAY ahead)
    # the count is still the one the enable found; on it, the reload. AGB SP,
    # payloads/tmrdma.s: a DMA reading a cycle after another DMA's enable gets
    # the old count; pinned by alyosha timer/timer_reset.
    if now < tim.cycle_enabled[num]:
      return (if TIMER_OLD_COUNT: tim.tm_pre[num] else: tim.tm[num])
    if now == tim.cycle_enabled[num]: return tim.tm[num]
    tim.tm[num] + uint16(ticks_between(tim.cycle_enabled[num], now,
                                       TIMER_PERIODS[tim.tmcnt[num].frequency]))
  else:
    tim.tm[num]

proc write_now(tim: Timer): CycleCount {.inline.} =
  ## The cycle a register write lands on. A CPU store has synced the
  ## scheduler (bus.cycles is 0); a DMA store lands after the burst cycles
  ## still in bus.cycles (AGB SP, payloads/dmadur.s: a one-word DMA that
  ## starts TM1 has it counting two cycles after the grant).
  tim.gba.scheduler.cycles + CycleCount(tim.gba.bus.cycles)

proc update_tm(tim: Timer; num: int) =
  let now = tim.write_now()
  # Not started yet: the reload and the start cycle stand.
  if tim.tmcnt[num].enable and now < tim.cycle_enabled[num]: return
  tim.tm[num] = tim.get_current_tm(num)
  tim.cycle_enabled[num] = now

proc `[]`*(tim: Timer; io_addr: uint32): uint8 =
  let num = int((io_addr and 0xF) div 4)
  if bit(io_addr, 1):
    # Bits 3-5 and the high byte are unused and read 0 (png183
    # timer_check_count_up_presence)
    read(cast[uint16](tim.tmcnt[num]) and 0x00C7'u16, io_addr and 1)
  else:
    let v = tim.get_current_tm(num)
    when defined(itrace):
      if (io_addr and 1) == 0:
        itl("TREAD " & $num & " v=" & toHex(v, 4) & " t=" & $(tim.gba.scheduler.cycles + CycleCount(tim.gba.bus.cycles)))
    when defined(pftrace):
      if num == 0 and (io_addr and 1) == 0:
        pft("TMREAD raw=" & $v & " sched=" & $tim.gba.scheduler.cycles &
            " busc=" & $tim.gba.bus.cycles)
        when defined(pftrace_all):
          for l in pft_lines: echo "PFT ", l
          echo "PFT ---- (read)"
          pft_lines.setLen(0)
    read(v, io_addr and 1)

proc `[]=`*(tim: Timer; io_addr: uint32; value: uint8) =
  let num = int((io_addr and 0xF) div 4)
  if bit(io_addr, 1):
    if not bit(io_addr, 0):  # TMCNT low byte only triggers side-effects
      tim.update_tm(num)
      let was_enabled = tim.tmcnt[num].enable
      let was_cascade = tim.tmcnt[num].cascade
      let old_period = TIMER_PERIODS[tim.tmcnt[num].frequency]
      let old_ctrl = tim.tmcnt[num]
      write(tim.tmcnt[num], value, 0)
      when defined(itrace):
        itl("TCNT " & $num & " v=" & toHex(value, 2) & " t=" & $tim.write_now())
      if num == 0:
        # TM0CNT_H's count-up bit is unimplemented and reads back 0 (GBATEK,
        # "Timer Control").
        tim.tmcnt[0].cascade = false
      # update_tm has snapshotted the count; below only the anchor and the
      # overflow event move. Cascade has no event; a cold enable anchors
      # TIMER_START_DELAY ahead, cascade->prescaler at the current cycle.
      when defined(pftrace):
        if num == 0:
          if tim.tmcnt[0].enable and not was_enabled:
            pft_on = true
            pft_dma = false
            pft_lines.setLen(0)
            pft_lines.add("ENABLE sched=" & $tim.gba.scheduler.cycles &
              " busc=" & $tim.gba.bus.cycles &
              " rfs=" & $tim.gba.bus.rom_free_since &
              " hot=" & $tim.gba.bus.rom_hot &
              " s16=" & $tim.gba.bus.wait16_s[8] & " n16=" & $tim.gba.bus.wait16_n[8] &
              " pf=" & $tim.gba.bus.prefetch_on)
          elif (not tim.tmcnt[0].enable) and was_enabled:
            if pft_dma or defined(pftrace_all):
              for l in pft_lines: echo "PFT ", l
              echo "PFT ----"
            pft_on = false
      var start_ovf = false
      if tim.tmcnt[num].enable:
        if not was_enabled:
          # A count stopped at 0xFFFF ticks once more before the enable
          # reloads it, and that overflow raises the interrupt (alyosha
          # timer/timer_disable test 2). Only if the prescaler ticks on the
          # enable's cycle: the mGBA suite's /1024 count-up tests take none.
          # The tick lands on the start cycle, TIMER_START_DELAY after the
          # write (AGB SP, payloads/tmrffirq.s and tmrffff.s).
          let now = tim.write_now()
          if tim.tm[num] == 0xFFFF'u16 and not tim.tmcnt[num].cascade and
             ticks_between(now - 1, now, TIMER_PERIODS[tim.tmcnt[num].frequency]) > 0:
            start_ovf = TIMER_START_OVERFLOW
            if tim.tmcnt[num].irq_enable:
              tim.gba.interrupts.raise_synced(IRQ_TIMER_BIT_BASE + num,
                late = int(now - tim.gba.scheduler.cycles) + TIMER_START_DELAY)
          tim.tm_pre[num] = tim.tm[num]
          tim.tm[num] = tim.tmd[num]
        if tim.tmcnt[num].cascade:
          tim.gba.scheduler.clear(TIMER_EVENT_TYPES[num])
        elif not was_enabled or was_cascade:
          let delay = if was_enabled: 0 else: TIMER_START_DELAY
          tim.cycle_enabled[num] = tim.write_now() + CycleCount(delay)
          # TIMER_START_OVERFLOW: the extra tick's overflow is the first one
          let first = if start_ovf: int(tim.cycle_enabled[num] - tim.gba.scheduler.cycles)
                      else: tim.cycles_until_overflow(num)
          tim.gba.scheduler.schedule(first, TIMER_EVENT_TYPES[num])
          if tim.tmcnt[num].irq_enable and not start_ovf:
            tim.gba.interrupts.window_ahead(first)
          if num <= 1:
            tim.gba.apu.dma_channels.fifo_window_at_start(num, first)
      elif was_enabled:
        when TIMER_STOP_DELAY > 0:
          # The count goes on for a cycle after the stopping write (AGB SP,
          # payloads/tmrw.s: the frozen count is one higher than a stop at
          # the write gives).
          if not was_cascade:
            let now = tim.write_now()
            let extra = ticks_between(now, now + CycleCount(TIMER_STOP_DELAY), old_period)
            if extra > 0:
              if tim.tm[num] == 0xFFFF'u16:
                # That cycle runs under the old control bits: an overflow on
                # it still raises the interrupt (alyosha irq/IF_Timer).
                let new_ctrl = tim.tmcnt[num]
                tim.tmcnt[num] = old_ctrl
                tim.timer_overflow_event(num, scheduled = false)
                tim.tmcnt[num] = new_ctrl
              else: tim.tm[num] += uint16(extra)
        tim.gba.scheduler.clear(TIMER_EVENT_TYPES[num])
  else:
    let now = tim.write_now()
    if tim.tmd_write_cycle[num] != now:
      tim.tmd_prev[num] = tim.tmd[num]
      tim.tmd_write_cycle[num] = now
    write(tim.tmd[num], value, io_addr and 1)
