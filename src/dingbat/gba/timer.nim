# Timer implementation (included by gba.nim)

const
  TIMER_PERIODS   = [1, 64, 256, 1024]
  TIMER_EVENT_TYPES* = [etTimer0, etTimer1, etTimer2, etTimer3]

proc cycles_until_overflow(tim: Timer; num: int): int =
  TIMER_PERIODS[tim.tmcnt[num].frequency] * (0x10000 - int(tim.tm[num]))

proc timer_overflow_event*(tim: Timer; num: int) =
  tim.tm[num] = tim.tmd[num]
  tim.cycle_enabled[num] = tim.gba.scheduler.cycles
  if num < 3 and tim.tmcnt[num + 1].cascade and tim.tmcnt[num + 1].enable:
    tim.tm[num + 1] += 1
    if tim.tm[num + 1] == 0:
      tim.timer_overflow_event(num + 1)
  if num <= 1:
    tim.gba.apu.timer_overflow(num)
  if tim.tmcnt[num].irq_enable:
    case num
    of 0: tim.gba.interrupts.reg_if.timer0 = true
    of 1: tim.gba.interrupts.reg_if.timer1 = true
    of 2: tim.gba.interrupts.reg_if.timer2 = true
    of 3: tim.gba.interrupts.reg_if.timer3 = true
    else: discard
    tim.gba.interrupts.schedule_interrupt_check()
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
    let elapsed = tim.gba.scheduler.cycles - tim.cycle_enabled[num]
    tim.tm[num] + uint16(elapsed div CycleCount(TIMER_PERIODS[tim.tmcnt[num].frequency]))
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
      if tim.tmcnt[num].enable:
        if not was_enabled:
          tim.tm[num] = tim.tmd[num]
        if tim.tmcnt[num].cascade:
          tim.gba.scheduler.clear(TIMER_EVENT_TYPES[num])
        elif not was_enabled or was_cascade:
          tim.cycle_enabled[num] = tim.gba.scheduler.cycles
          tim.gba.scheduler.schedule(tim.cycles_until_overflow(num), TIMER_EVENT_TYPES[num])
      elif was_enabled:
        tim.gba.scheduler.clear(TIMER_EVENT_TYPES[num])
  else:
    write(tim.tmd[num], value, io_addr and 1)
