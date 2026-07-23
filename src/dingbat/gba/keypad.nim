# Keypad implementation (included by gba.nim)

proc new_keypad*(gba: GBA): Keypad =
  result = Keypad(gba: gba)
  # Unused bits 10-15 read as 0 on hardware: idle KEYINPUT is 0x03FF, not
  # 0xFFFF (mGBA stores 0x3FF ^ keys). Games that compute pressed keys as
  # KEYINPUT ^ 0x03FF would otherwise see bits 10-15 as phantom presses.
  result.keyinput = cast[KEYINPUT](0x03FF'u16)
  result.keycnt   = cast[KEYCNT](0x0000'u16)

proc check_keypad_irq(kp: Keypad) =
  ## Evaluate the KEYCNT interrupt condition and raise the keypad IRQ on a
  ## rising edge, so a held combination doesn't repeatedly set IF.
  let mask    = toU16(kp.keycnt) and 0x03FF'u16
  let pressed = not toU16(kp.keyinput) and 0x03FF'u16
  let cond = kp.keycnt.irq_enable and
             (if kp.keycnt.irq_condition: (pressed and mask) == mask  # AND: all selected
              else: (pressed and mask) != 0)                          # OR: any selected
  if cond and not kp.prev_irq_condition:
    kp.gba.interrupts.reg_if.keypad = true
    kp.gba.interrupts.schedule_interrupt_check(IRQ_SYNC_DELAY)
  kp.prev_irq_condition = cond

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
  ## Atomic 16-bit KEYCNT store: commit the whole value, then run a single
  ## IRQ-condition check (hardware/mGBA semantics). Decomposing into two
  ## byte writes with a check after each would observe a transient the
  ## hardware never has: KEYCNT 0xC00F -> 0x0000 passes through 0xC000 =
  ## IRQ enabled, AND condition, empty mask, which matches vacuously with
  ## no keys held and latches a phantom keypad IRQ. GBA Video carts arm
  ## KEYCNT=0xC00F (A+B+Select+Start) as a soft-reset combo and boot-loop
  ## forever on that phantom IRQ. The bus routes 16/32-bit stores covering
  ## KEYCNT here instead of through the byte path.
  kp.keycnt = cast[KEYCNT](value)
  kp.keycnt.not_used = 0
  kp.check_keypad_irq()

proc `[]=`*(kp: Keypad; io_addr: uint32; value: uint8) =
  # Genuine 8-bit stores: one commit of the merged value, one check —
  # same as hardware's continuous evaluation of the committed register.
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
