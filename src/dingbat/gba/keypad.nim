# Keypad implementation (included by gba.nim)

proc new_keypad*(gba: GBA): Keypad =
  result = Keypad(gba: gba)
  # Bits 10-15 read as 0 (GBATEK, KEYINPUT): idle is 0x03FF, not 0xFFFF. Games
  # computing pressed keys as KEYINPUT ^ 0x03FF would otherwise see phantoms.
  result.keyinput = cast[KEYINPUT](0x03FF'u16)
  result.keycnt   = cast[KEYCNT](0x0000'u16)

# The KEYCNT condition reaches IF only once it has held for KEYPAD_IRQ_HOLD
# cycles, and only on its rising edge (AGB SP, tests/roms/payloads/keyirq2.s;
# docs/playtest-bugs.md §61):
# after an acknowledge it never comes again while the condition holds; a
# true condition of up to ~40 cycles is never caught, ~68 always is. So a
# byte-wise KEYCNT rewrite passing through a matching value raises nothing.
const KEYPAD_IRQ_HOLD* {.intdefine.} = 64

proc keypad_condition(kp: Keypad): bool =
  let mask    = toU16(kp.keycnt) and 0x03FF'u16
  let pressed = not toU16(kp.keyinput) and 0x03FF'u16
  kp.keycnt.irq_enable and
    (if kp.keycnt.irq_condition: (pressed and mask) == mask  # AND: all selected
     else: (pressed and mask) != 0)                          # OR: any selected

proc check_keypad_irq(kp: Keypad) =
  ## A change to KEYCNT or the keys: a condition that turns true starts its
  ## hold (etKeypadIrq), one that turns false ends the hold and the edge.
  ## `prev_irq_condition` is the held condition: true once IF was raised for
  ## it, until the condition next turns false.
  let s = kp.gba.scheduler
  if not kp.keypad_condition():
    if s.has_event(etKeypadIrq): s.clear(etKeypadIrq)
    kp.prev_irq_condition = false
  elif not kp.prev_irq_condition and not s.has_event(etKeypadIrq):
    s.schedule(KEYPAD_IRQ_HOLD, etKeypadIrq)

proc keypad_irq_event*(kp: Keypad) =
  ## The hold is over and the condition never turned false in it (that
  ## would have cleared this event): raise the keypad IRQ.
  if kp.keypad_condition() and not kp.prev_irq_condition:
    kp.prev_irq_condition = true
    kp.gba.interrupts.reg_if.keypad = true
    kp.gba.interrupts.schedule_interrupt_check(IRQ_SYNC_DELAY)

proc stop_key_condition(kp: Keypad): bool =
  ## What ends Stop mode from the keypad: KEYCNT's key condition (AND: every
  ## selected key held, vacuously true with none selected; OR: any), with
  ## its IRQ enable (bit 14) ignored, as a level. Puyo Pop Fever sleeps with
  ## KEYCNT 0x8304 (enable clear) and wakes on the keys; Ghost Rider Stops
  ## again under 0xC000 (no key) with the first wake's IF acknowledged, and
  ## must return. Pinned on the console by tests/roms/payloads/keyirq.s.
  let mask    = toU16(kp.keycnt) and 0x03FF'u16
  let pressed = not toU16(kp.keyinput) and 0x03FF'u16
  if kp.keycnt.irq_condition: (pressed and mask) == mask
  else: (pressed and mask) != 0

when defined(test_harness):
  # Latency-probe instrumentation: records every KEYINPUT read (low byte)
  var keyinput_reads*: int = 0
  var keyinput_last_read*: uint16 = 0xFFFF'u16

proc `[]`*(kp: Keypad; io_addr: uint32): uint8 =
  case io_addr
  of 0x130..0x131:
    when defined(test_harness):
      if (io_addr and 1) == 0:
        inc keyinput_reads
        keyinput_last_read = toU16(kp.keyinput)
    read(kp.keyinput, io_addr and 1)
  of 0x132..0x133: read(kp.keycnt, io_addr and 1)
  else: raise newException(Exception, "Unreachable keypad read " & hex_str(uint32(io_addr)))

proc write_keycnt16*(kp: Keypad; value: uint16) =
  ## Atomic 16-bit KEYCNT store: commit the whole value, then one IRQ check.
  ## Two byte writes would pass 0xC00F -> 0x0000 through 0xC000, which
  ## matches vacuously (GBA Video carts boot-loop on it). The bus routes
  ## 16/32-bit stores here.
  kp.keycnt = cast[KEYCNT](value)
  kp.keycnt.not_used = 0
  kp.check_keypad_irq()

proc `[]=`*(kp: Keypad; io_addr: uint32; value: uint8) =
  # Genuine 8-bit stores: one commit of the merged value, one check.
  case io_addr
  of 0x132:
    write(kp.keycnt, value, 0)
    kp.keycnt.not_used = 0
    kp.check_keypad_irq()
  of 0x133:
    write(kp.keycnt, value, 1)
    kp.keycnt.not_used = 0
    kp.check_keypad_irq()
  else: discard  # KEYINPUT is read-only

proc handle_input*(kp: Keypad; input: Input; pressed: bool) =
  case input
  of UP:     kp.keyinput.up     = not pressed
  of DOWN:   kp.keyinput.down   = not pressed
  of LEFT:   kp.keyinput.left   = not pressed
  of RIGHT:  kp.keyinput.right  = not pressed
  of A:      kp.keyinput.a      = not pressed
  of B:      kp.keyinput.b      = not pressed
  of SELECT: kp.keyinput.select = not pressed
  of START:  kp.keyinput.start  = not pressed
  of L:      kp.keyinput.l      = not pressed
  of R:      kp.keyinput.r      = not pressed
  kp.check_keypad_irq()
  if kp.gba.cpu.stopped:
    kp.gba.interrupts.schedule_interrupt_check()  # stop_key_condition
