## Per-CPU interrupt controller: IME 0x4000208, IE 0x4000210, IF 0x4000214
## (both 32-bit on the DS). The GBA's bits 0-13 keep their meaning; the DS
## adds IPC/cart/GX/lid/SPI/wifi lines (docs/nds/gbatek-notes.md).

import ../quirky

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: nds_quirky.}

type
  IrqSource* = enum
    irqVBlank = 0, irqHBlank = 1, irqVCount = 2,
    irqTimer0 = 3, irqTimer1 = 4, irqTimer2 = 5, irqTimer3 = 6,
    irqSerial = 7,                ## ARM7: RTC/SIO
    irqDma0 = 8, irqDma1 = 9, irqDma2 = 10, irqDma3 = 11,
    irqKeypad = 12, irqGbaSlot = 13,
    irqIpcSync = 16, irqIpcSendEmpty = 17, irqIpcRecvNotEmpty = 18,
    irqCartDone = 19, irqCartIreq = 20,
    irqGxFifo = 21,               ## ARM9 only
    irqLid = 22,                  ## ARM7 only
    irqSpi = 23,                  ## ARM7 only
    irqWifi = 24                  ## ARM7 only

  IrqCtl* = ref object
    ime*: uint32
    ie*: uint32
    iff*: uint32

proc raise_irq*(c: IrqCtl; src: IrqSource) {.inline.} =
  c.iff = c.iff or (1'u32 shl ord(src))

proc raise_bit*(c: IrqCtl; bit: int) {.inline.} =
  c.iff = c.iff or (1'u32 shl bit)

proc line*(c: IrqCtl): bool {.inline.} =
  (c.ime and 1) != 0 and (c.ie and c.iff) != 0

proc wake*(c: IrqCtl): bool {.inline.} = (c.ie and c.iff) != 0

proc read_reg*(c: IrqCtl; offset: uint32): uint32 =
  case offset
  of 0x208: c.ime
  of 0x210: c.ie
  of 0x214: c.iff
  else: 0

proc write_reg*(c: IrqCtl; offset: uint32; v, mask: uint32) =
  case offset
  of 0x208: c.ime = (c.ime and not mask) or (v and mask and 1)
  of 0x210: c.ie = (c.ie and not mask) or (v and mask)
  of 0x214: c.iff = c.iff and not (v and mask)   # write 1 to acknowledge
  else: discard

{.pop.}
