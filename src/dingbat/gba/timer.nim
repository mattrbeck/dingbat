# Timer implementation (included by gba.nim)

const
  TIMER_PERIODS   = [1, 64, 256, 1024]
  TIMER_EVENT_TYPES* = [etTimer0, etTimer1, etTimer2, etTimer3]
  # Counting starts 2 cycles after the enable write.
  TIMER_START_DELAY = 2

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

proc timer_overflow_event*(tim: Timer; num: int) =
  tim.tm[num] = tim.effective_reload(num)
  tim.cycle_enabled[num] = tim.gba.scheduler.cycles
  if num < 3 and tim.tmcnt[num + 1].cascade and tim.tmcnt[num + 1].enable:
    tim.tm[num + 1] += 1
    if tim.tm[num + 1] == 0:
      tim.timer_overflow_event(num + 1)
  if num <= 1:
    tim.gba.apu.timer_overflow(num)
  if tim.tmcnt[num].irq_enable:
    tim.gba.interrupts.set_interrupt_flag(IRQ_TIMER_BIT_BASE + num)
    tim.gba.interrupts.schedule_interrupt_check(IRQ_SYNC_DELAY)
  if not tim.tmcnt[num].cascade:
    tim.gba.scheduler.schedule(tim.cycles_until_overflow(num), TIMER_EVENT_TYPES[num])

proc new_timer*(gba: GBA): Timer =
  result = Timer(gba: gba)
  for i in 0..3:
    result.tmcnt[i] = TMCNT()
    result.tmd[i] = 0
    result.tm[i] = 0
    result.cycle_enabled[i] = 0

proc get_current_tm(tim: Timer; num: int): uint16 =
  if tim.tmcnt[num].enable and not tim.tmcnt[num].cascade:
    # Include un-ticked bus cycles: a DMA reading the timer runs inside event
    # dispatch, where catch_up is suppressed, and each transfer must see the
    # live count (AGS aging cartridge DMA-captures consecutive timer values).
    let now = tim.gba.scheduler.cycles + CycleCount(tim.gba.bus.cycles)
    # cycle_enabled sits up to TIMER_START_DELAY in the future after an enable.
    if now <= tim.cycle_enabled[num]: return tim.tm[num]
    tim.tm[num] + uint16(ticks_between(tim.cycle_enabled[num], now,
                                       TIMER_PERIODS[tim.tmcnt[num].frequency]))
  else:
    tim.tm[num]

proc update_tm(tim: Timer; num: int) =
  tim.tm[num] = tim.get_current_tm(num)
  tim.cycle_enabled[num] = tim.gba.scheduler.cycles

proc `[]`*(tim: Timer; io_addr: uint32): uint8 =
  let num = int((io_addr and 0xF) div 4)
  if bit(io_addr, 1):
    read(tim.tmcnt[num], io_addr and 1)
  else:
    let v = tim.get_current_tm(num)
    when defined(pftrace):
      if num == 0 and (io_addr and 1) == 0:
        pft("TMREAD raw=" & $v & " sched=" & $tim.gba.scheduler.cycles &
            " busc=" & $tim.gba.bus.cycles)
    read(v, io_addr and 1)

proc `[]=`*(tim: Timer; io_addr: uint32; value: uint8) =
  let num = int((io_addr and 0xF) div 4)
  if bit(io_addr, 1):
    if not bit(io_addr, 0):  # TMCNT low byte only triggers side-effects
      tim.update_tm(num)
      let was_enabled = tim.tmcnt[num].enable
      let was_cascade = tim.tmcnt[num].cascade
      write(tim.tmcnt[num], value, 0)
      if num == 0:
        # TM0CNT_H's count-up bit is unimplemented and reads back 0 (GBATEK,
        # "Timer Control").
        tim.tmcnt[0].cascade = false
      # The count was snapshotted by update_tm; the transitions below only
      # move the anchor and the overflow event. Cascade mode has no event
      # (the timer below advances it); a cold enable anchors
      # TIMER_START_DELAY ahead, cascade->prescaler anchors at the current cycle.
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
            if pft_dma:
              for l in pft_lines: echo "PFT ", l
              echo "PFT ----"
            pft_on = false
      if tim.tmcnt[num].enable:
        if not was_enabled:
          tim.tm[num] = tim.tmd[num]
        if tim.tmcnt[num].cascade:
          tim.gba.scheduler.clear(TIMER_EVENT_TYPES[num])
        elif not was_enabled or was_cascade:
          let delay = if was_enabled: 0 else: TIMER_START_DELAY
          tim.cycle_enabled[num] = tim.gba.scheduler.cycles + CycleCount(delay)
          tim.gba.scheduler.schedule(tim.cycles_until_overflow(num), TIMER_EVENT_TYPES[num])
      elif was_enabled:
        tim.gba.scheduler.clear(TIMER_EVENT_TYPES[num])
  else:
    let now = tim.gba.scheduler.cycles
    if tim.tmd_write_cycle[num] != now:
      tim.tmd_prev[num] = tim.tmd[num]
      tim.tmd_write_cycle[num] = now
    write(tim.tmd[num], value, io_addr and 1)
