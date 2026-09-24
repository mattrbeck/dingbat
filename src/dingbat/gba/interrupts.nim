# Interrupts implementation (included by gba.nim)

proc new_interrupts*(gba: GBA): Interrupts =
  result = Interrupts(gba: gba)
  result.reg_ie = InterruptReg()
  result.reg_if = InterruptReg()
  result.ime = false

const
  IRQ_TIMER_BIT_BASE* = 3
  IRQ_DMA_BIT_BASE*   = 8
  # Stop mode wakes only on serial (7), keypad (12), and game pak (13)
  STOP_WAKE_MASK* = 0x3080'u16

proc set_interrupt_flag*(intr: Interrupts; bit: int) {.inline.} =
  intr.reg_if = cast[InterruptReg](uint16(intr.reg_if) or (1'u16 shl bit))

# Cycles from a peripheral raising IF to CPU recognition (mGBA suite Timer
# IRQ rows). Register writes (IE/IF/IME) re-evaluate with no delay.
const IRQ_SYNC_DELAY* {.intdefine.} = 3
const UNDER_BURST_CREDIT {.intdefine.} = 1
  ## A timer interrupt raised while a burst holds the CPU off the bus is
  ## recognised IRQ_SYNC_DELAY - UNDER_BURST_CREDIT cycles after the CPU
  ## gets the bus back, or IRQ_SYNC_DELAY after the raise if that is later:
  ## one stage of the synchroniser keeps counting while the CPU is stopped.
  ## tests/roms/payloads/irqstorm.s on an AGB SP, TM0 every 16 cycles under
  ## a 1..4096-word EWRAM burst: 0 reads the five cells one cycle late, 2 four
  ## of them one cycle early.

# Cycles of continued execution after a register write (IME 0->1, IE unmask,
# msr clearing CPSR.I) releases an already-parked IF bit. The window is
# cycle-based, not instruction-based (hardware: gbaedge IRQWIN/IRQWIN2/
# IRQWIN3 on AGB SP, docs/hwprobe.md). The vector-entry cost itself is in
# cpu.irq.
const
  IRQ_GATE_DELAY* = 12

proc schedule_interrupt_check*(intr: Interrupts; delay: int = 0) =
  intr.gba.scheduler.schedule(delay, etInterrupts)

# A timer's interrupt goes through a synchroniser before the CPU sees it
# (alyosha irq/IF, irq/IE, both hardware-verified by their author):
# - the raising cycle's own register writes still count: an IF acknowledge
#   or an IE clear landing on it cancels the interrupt, one a cycle later
#   does not;
# - a read on that cycle still finds the IF bit clear;
# - what IE & IF held at the end of that cycle is taken IRQ_SYNC_DELAY
#   cycles later whatever IE and IF do in between.
# The synchroniser runs on the CPU's clock, so it stops while a DMA burst
# holds the CPU off the bus (DMA_STALLS_IRQ_SYNC), but not while the CPU
# runs internal cycles under the burst (alyosha Interactions ReadMe).
# Only timers go through here: the other sources' delays were fitted with
# no synchroniser in front of them (ppu.nim, IRQ_SYNC_DELAY's other users).

proc stalled_for(intr: Interrupts; now: CycleCount): int {.inline.} =
  ## Cycles until the CPU runs again when `now` falls inside the span the
  ## last burst stalled it. Catch-up dispatches an event raised under a
  ## burst after the burst, so this is where one learns it was stalled.
  if now >= intr.stall_from and now < intr.stall_to: int(intr.stall_to - now)
  else: 0

proc raise_synced*(intr: Interrupts; bit: int) =
  let now = intr.gba.scheduler.cycles
  if intr.pipe_raised == 0:
    let st = intr.stalled_for(now)
    let delay = if st == 0: IRQ_SYNC_DELAY
                else: max(IRQ_SYNC_DELAY, st + IRQ_SYNC_DELAY - UNDER_BURST_CREDIT)
    intr.pipe_bits = 0
    intr.pipe_sampled = false
    intr.pipe_at = now
    intr.pipe_due = now + CycleCount(delay)
    # Only a bit this raise sets is hidden from a read on its cycle.
    intr.pipe_new = (1'u16 shl bit) and not uint16(intr.reg_if)
    intr.schedule_interrupt_check(delay)
  # A raise while another is in flight rides with it, on that one's check:
  # a timer overflowing every cycle would otherwise push the recognition out
  # forever, and under a long burst (every raise waiting for its end) book
  # one check per raise until the event queue overflows.
  intr.pipe_raised = intr.pipe_raised or (1'u16 shl bit)
  intr.set_interrupt_flag(bit)

proc pipe_sample(intr: Interrupts; now: CycleCount) {.inline.} =
  ## Take IE & IF into the synchroniser once the raising cycle is over (before
  ## the first register write after it, or at the recognition itself).
  if intr.pipe_raised != 0 and not intr.pipe_sampled and now > intr.pipe_at:
    intr.pipe_bits = uint16(intr.reg_ie) and uint16(intr.reg_if)
    intr.pipe_sampled = true

proc unstall*(intr: Interrupts; ran: int) =
  ## The CPU ran `ran` internal cycles under the last burst, from its start
  ## (bus.idle_window): the synchroniser was not stopped for them.
  when DMA_STALLS_IRQ_SYNC:
    if ran <= 0: return
    let now = intr.gba.scheduler.cycles + CycleCount(intr.gba.bus.cycles)
    let new_from = min(intr.stall_to, intr.stall_from + CycleCount(ran))
    if intr.stall_pushed:
      # A recognition the burst pushed back gets those cycles back
      # (Internal_Cycle_DMA_IRQ_ldr_IWRAM, _IRQ_7).
      intr.gba.scheduler.advance_pending(etInterrupts, now, CycleCount(ran))
      if intr.pipe_raised != 0 and intr.pipe_due > now:
        intr.pipe_due = max(now + 1, intr.pipe_due - CycleCount(ran))
    elif intr.pipe_raised != 0 and intr.pipe_at >= intr.stall_from and
         intr.pipe_at < new_from:
      # Raised while those cycles ran: it counted until the CPU stopped, and
      # only the rest waits for the burst's end. Recognised before the burst
      # ends, it is taken at the next boundary (Internal_Cycle_DMA_MUL_IRQ:
      # a timer overflowing inside a multiply's internal cycles under an
      # H-blank DMA interrupts the instruction after the multiply).
      let k = new_from - intr.pipe_at
      let due = if k >= CycleCount(IRQ_SYNC_DELAY): intr.pipe_at + CycleCount(IRQ_SYNC_DELAY)
                else: intr.stall_to + CycleCount(IRQ_SYNC_DELAY) - k
      if due < intr.pipe_due:
        intr.gba.scheduler.advance_pending(etInterrupts, now - 1,
                                           intr.pipe_due - due)
        intr.pipe_due = max(now, due)
    intr.stall_from = new_from

proc stall_tail*(intr: Interrupts; access_end: CycleCount; cost: int) =
  ## The CPU's first access after a burst, `cost` cycles ending at
  ## `access_end`. It is the access the CPU was waiting to make, so its wait
  ## states stall the synchroniser as the burst did (alyosha
  ## Internal_Cycle_DMA_IRQ, _ST, _ST_p3, _br: after an H-blank DMA that
  ## stopped a gamepak load or store, the timer interrupt is taken two
  ## instructions later, not one; a 4-cycle ROM fetch there delays it by 3).
  intr.stall_open = false
  if cost > 1 and access_end == intr.stall_to + CycleCount(cost):
    let waits = CycleCount(cost - 1)
    intr.gba.scheduler.delay_pending(etInterrupts, intr.stall_to, waits)
    if intr.pipe_raised != 0 and intr.pipe_due > intr.stall_to:
      intr.pipe_due += waits
    intr.stall_to += waits

proc irq_deliverable*(intr: Interrupts): bool {.inline.} =
  intr.ime and (uint16(intr.reg_ie) and uint16(intr.reg_if)) != 0

proc gate_opened*(intr: Interrupts) =
  ## A register write made a parked interrupt deliverable: drop the
  ## recognized line and re-recognize IRQ_GATE_DELAY cycles out.
  intr.gba.cpu.irq_line = false
  intr.gate_open_at = intr.gba.scheduler.cycles + CycleCount(IRQ_GATE_DELAY)
  intr.schedule_interrupt_check(IRQ_GATE_DELAY)

proc check_interrupts*(intr: Interrupts) =
  var pending = uint16(intr.reg_ie) and uint16(intr.reg_if)
  if intr.pipe_raised != 0:
    let now = intr.gba.scheduler.cycles
    intr.pipe_sample(now)
    if now >= intr.pipe_due:
      pending = pending or intr.pipe_bits
      intr.pipe_raised = 0
  intr.gba.cpu.irq_line = false
  if pending != 0:
    if intr.gba.cpu.stopped and (pending and STOP_WAKE_MASK) == 0:
      return  # Stop mode ignores other interrupt sources
    if intr.gba.cpu.stopped:
      # Waking from Stop turns the LCD back on without a memory write.
      intr.gba.ppu.render_dirty = true
    if intr.gba.cpu.halted:
      intr.gba.cpu.halt_wake = true
    intr.gba.cpu.stopped = false
    intr.gba.cpu.halted = false
    if intr.ime and intr.gba.scheduler.cycles >= intr.gate_open_at:
      intr.gba.cpu.irq_line = true

proc `[]`*(intr: Interrupts; io_addr: uint32): uint8 =
  case io_addr
  of 0x200..0x201: read(intr.reg_ie, io_addr and 1)
  of 0x202..0x203:
    var v = uint16(intr.reg_if)
    if intr.pipe_raised != 0 and
       intr.gba.scheduler.cycles + CycleCount(intr.gba.bus.cycles) <= intr.pipe_at:
      v = v and not intr.pipe_new
    read(cast[InterruptReg](v), io_addr and 1)
  of 0x208: (if intr.ime: 1'u8 else: 0'u8)
  of 0x209: 0'u8
  else: raise newException(Exception, "Unimplemented interrupts read addr: " & hex_str(uint8(io_addr)))

proc `[]=`*(intr: Interrupts; io_addr: uint32; value: uint8) =
  intr.pipe_sample(intr.gba.scheduler.cycles + CycleCount(intr.gba.bus.cycles))
  let was_deliverable = intr.irq_deliverable
  case io_addr
  of 0x200..0x201: write(intr.reg_ie, value, io_addr and 1)
  of 0x202..0x203:
    let v = uint16(value) shl (8 * (io_addr and 1))
    intr.reg_if = cast[InterruptReg](uint16(intr.reg_if) and not v)
  of 0x208: intr.ime = bit(value, 0)
  of 0x209: discard
  else: raise newException(Exception, "Unimplemented interrupts write addr: " & hex_str(uint8(io_addr)) & " val: " & hex_str(value))
  if intr.irq_deliverable and not was_deliverable and
     not intr.gba.cpu.cpsr.irq_disable:
    # Gate opened with CPSR.I clear: late recognition. With I set,
    # recognition waits on the exception return, which is fast (mGBA suite
    # multi-IRQ Timer count-up rows).
    intr.gate_opened()
  else:
    # Clears re-evaluate immediately; check_interrupts holds irq_line off
    # until gate_open_at, so the second byte of a halfword IME/IE store
    # cannot recognize early.
    intr.schedule_interrupt_check()
