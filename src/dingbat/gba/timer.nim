# Timer implementation (included by gba.nim)

const
  TIMER_PERIODS   = [1, 64, 256, 1024]
  TIMER_EVENT_TYPES* = [etTimer0, etTimer1, etTimer2, etTimer3]
  # Hardware starts counting 2 cycles after the enable write
  TIMER_START_DELAY = 2

# The prescaler is free-running: a timer with period P ticks at absolute
# cycles divisible by P, regardless of when it was enabled. Ticks are counted
# over the half-open interval (anchor, now], so a tick landing exactly on the
# anchor cycle (enable+delay or the overflow itself) is excluded.
proc ticks_between(anchor, now: CycleCount; period: int): uint32 {.inline.} =
  uint32(now div CycleCount(period) - anchor div CycleCount(period))

proc cycles_until_overflow(tim: Timer; num: int): int =
  # From the anchor cycle: overflow fires on the (0x10000 - tm)-th tick
  let period = TIMER_PERIODS[tim.tmcnt[num].prescaler]
  let anchor = tim.cycle_enabled[num]
  let target = CycleCount(period) * (anchor div CycleCount(period) + CycleCount(0x10000 - int(tim.tm[num])))
  int(target - tim.gba.scheduler.cycles)

proc effective_reload(tim: Timer; num: int): uint16 {.inline.} =
  # A reload write on the cycle immediately before (or the same cycle as)
  # this overflow isn't visible to the reload yet
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
    # Include un-ticked bus cycles: normally catch_up has just drained them
    # (so this adds zero), but a DMA reading the timer runs inside event
    # dispatch where catch_up is suppressed — each transfer must still see
    # the live count (the AGS aging cartridge DMA-captures consecutive timer
    # values to verify bus timing).
    let now = tim.gba.scheduler.cycles + CycleCount(tim.gba.bus.cycles)
    # cycle_enabled can sit up to TIMER_START_DELAY in the future right after
    # an enable write; the counter hasn't started yet
    if now <= tim.cycle_enabled[num]: return tim.tm[num]
    tim.tm[num] + uint16(ticks_between(tim.cycle_enabled[num], now,
                                       TIMER_PERIODS[tim.tmcnt[num].prescaler]))
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
    read(tim.get_current_tm(num), io_addr and 1)

proc `[]=`*(tim: Timer; io_addr: uint32; value: uint8) =
  let num = int((io_addr and 0xF) div 4)
  if bit(io_addr, 1):
    if not bit(io_addr, 0):  # TMCNT low byte only triggers side-effects
      tim.update_tm(num)
      let was_enabled = tim.tmcnt[num].enable
      let was_cascade = tim.tmcnt[num].cascade
      write(tim.tmcnt[num], value, 0)
      if num == 0:
        tim.tmcnt[0].cascade = false
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
