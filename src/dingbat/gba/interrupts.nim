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

# Cycles between a peripheral raising IF and the CPU recognizing the IRQ
# (hardware synchronization latency; calibrated against the mGBA suite's
# Timer IRQ tests). Register writes (IE/IF/IME) re-evaluate with no delay.
const IRQ_SYNC_DELAY* = 3

# A REGISTER write opening the last gate on an already-parked IF bit (IME
# 0->1, IE unmask, or an msr/SPSR-restore clearing CPSR.I) recognizes the
# IRQ late. Hardware-verified (gbaedge IRQWIN/IRQWIN2/IRQWIN3 pages, AGB SP
# sessions 2-4): with a parked TM2 IF, hardware runs 3 more single-cycle
# sled instructions after an IME/IE store (dingbat ran 1) but only 2 EWRAM
# loads, 2 muls or 2 ROM loads - the window is cycle-based, not
# instruction-based (IRQWIN3 matched byte-perfect with this constant).
# GATE_DELAY is the continued-execution window before recognition; the
# rest of the hardware store-to-handler-entry stamp deltas (0x81/0x81/
# 0x84, matched) is the universal 8-cycle vector-entry cost in cpu.irq,
# which every IRQ pays (gbaedge IRQLAT2, session 4). The peripheral
# IF-rise path (IRQ_SYNC_DELAY above) is deliberately untouched: the mGBA
# suite's Timer IRQ rows pin it.
const
  IRQ_GATE_DELAY* = 12

proc schedule_interrupt_check*(intr: Interrupts; delay: int = 0) =
  intr.gba.scheduler.schedule(delay, etInterrupts)

proc irq_deliverable*(intr: Interrupts): bool {.inline.} =
  intr.ime and (uint16(intr.reg_ie) and uint16(intr.reg_if)) != 0

proc gate_opened*(intr: Interrupts) =
  ## A register write just made a parked interrupt deliverable: suppress the
  ## already-recognized line and re-recognize IRQ_GATE_DELAY cycles out.
  intr.gba.cpu.irq_line = false
  intr.gate_open_at = intr.gba.scheduler.cycles + CycleCount(IRQ_GATE_DELAY)
  intr.schedule_interrupt_check(IRQ_GATE_DELAY)

proc check_interrupts*(intr: Interrupts) =
  let pending = uint16(intr.reg_ie) and uint16(intr.reg_if)
  intr.gba.cpu.irq_line = false
  if pending != 0:
    if intr.gba.cpu.stopped and (pending and STOP_WAKE_MASK) == 0:
      return  # Stop mode ignores other interrupt sources
    if intr.gba.cpu.stopped:
      # Waking from Stop turns the LCD back on without any memory write
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
  of 0x202..0x203: read(intr.reg_if, io_addr and 1)
  of 0x208: (if intr.ime: 1'u8 else: 0'u8)
  of 0x209: 0'u8
  else: raise newException(Exception, "Unimplemented interrupts read addr: " & hex_str(uint8(io_addr)))

proc `[]=`*(intr: Interrupts; io_addr: uint32; value: uint8) =
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
    # Newly-opened gate with CPSR.I clear: the IRQ becomes immediately
    # deliverable and recognizes late (hardware-verified). With I set (e.g.
    # the libgba dispatcher restoring IME inside a handler) recognition
    # waits on the exception return anyway, which re-recognizes fast - the
    # mGBA suite's multi-IRQ Timer count-up rows pin that path.
    intr.gate_opened()
  else:
    # Clears re-evaluate immediately. Within an open gate window this check
    # cannot recognize early (check_interrupts holds irq_line off until
    # gate_open_at), so the second byte of a halfword IME/IE store is
    # harmless here.
    intr.schedule_interrupt_check()
