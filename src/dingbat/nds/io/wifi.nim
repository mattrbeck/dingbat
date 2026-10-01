## ARM7 wifi block at 0x04800000-0x0480FFFF (registers + 8 KB packet RAM at
## 0x04804000). STUB: storage only, enough that the SDK's init doesn't wedge.
## TODO(wifi): W_ID, BB/RF init handshake, timers; no networking planned.

type
  Wifi* = ref object
    regs*: array[0x1000, uint16]    ## register window, mirrored
    ram*: array[0x1000, uint16]     ## 0x04804000 packet RAM

proc read16*(w: Wifi; a: uint32): uint16 =
  let o = int((a and 0x7FFF) shr 1)
  if (a and 0xE000) == 0x4000: return w.ram[o and 0xFFF]
  if (a and 0x0FFF) == 0: return 0x1440   # W_ID (DS)
  w.regs[o and 0xFFF]

proc write16*(w: Wifi; a: uint32; v: uint16) =
  let o = int((a and 0x7FFF) shr 1)
  if (a and 0xE000) == 0x4000: w.ram[o and 0xFFF] = v
  else: w.regs[o and 0xFFF] = v
