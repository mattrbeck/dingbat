## Buttons, the touchscreen and the hinge. KEYINPUT 0x4000130 / KEYCNT
## 0x4000132 on both CPUs (as on the GBA, bits 0-9); EXTKEYIN 0x4000136 on
## the ARM7 only: bit 0 X, 1 Y, 3 debug, 6 pen down (0 = touching; the
## TSC's /PENIRQ, so only while the last control byte enabled it), 7 hinge
## closed. Opening the hinge raises the ARM7's IF.22 (GBATEK "DS Keypad",
## "DS Interrupts": "Screens unfolding").

import irq

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: on.}

type
  NdsButton* = enum
    nbA, nbB, nbSelect, nbStart, nbRight, nbLeft, nbUp, nbDown, nbR, nbL,
    nbX, nbY

  Input* = ref object
    held*: set[NdsButton]
    keycnt9*, keycnt7*: uint16
    touching*: bool
    touch_x*, touch_y*: int    ## screen pixels on the bottom screen
    lid_closed*: bool
    penirq_enabled*: bool = true  ## TSC power-down mode 0/2 (io/spi.nim)

proc keyinput*(inp: Input): uint16 =
  result = 0x3FF
  for b in nbA .. nbL:
    if b in inp.held: result = result and not (1'u16 shl ord(b))

proc extkeyin*(inp: Input): uint16 =
  result = 0x007F
  if nbX in inp.held: result = result and not 1'u16
  if nbY in inp.held: result = result and not 2'u16
  if inp.touching and inp.penirq_enabled: result = result and not 0x40'u16
  if inp.lid_closed: result = result or 0x80

proc check_keypad_irq*(inp: Input; keycnt: uint16; irq: IrqCtl) =
  ## KEYCNT bit 14 enable, bit 15: 0 = any of the selected, 1 = all of them.
  if (keycnt and 0x4000) == 0: return
  let sel = keycnt and 0x3FF
  let pressed = (not inp.keyinput()) and 0x3FF
  let hit = if (keycnt and 0x8000) != 0: (pressed and sel) == sel
            else: (pressed and sel) != 0
  if hit and sel != 0: irq.raise_irq(irqKeypad)

proc set_lid*(inp: Input; closed: bool; irq7: IrqCtl) =
  ## The hinge's magnetic sensor. The IRQ has no enable of its own; only IE
  ## masks it.
  if inp.lid_closed and not closed: irq7.raise_irq(irqLid)
  inp.lid_closed = closed

{.pop.}
