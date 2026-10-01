# ARM9 bus map (included by nds.nim). GBATEK "DS Memory Map":
#   ITCM (CP15 9,1,1; data + code) / DTCM (CP15 9,1,0; data only)
#   0x02 main RAM 4 MB   0x03 shared WRAM (WRAMCNT)   0x04 I/O
#   0x05 palette 2 KB    0x06 VRAM (bank-mapped)      0x07 OAM 2 KB
#   0x08-0x0A GBA slot   0xFFFF0000 BIOS 4 KB
# Byte writes to palette, VRAM and OAM are ignored on the ARM9.
#
# I/O registers are reached as aligned 32-bit words with a byte mask
# (io9_read / io9_write); 8- and 16-bit accesses shift and mask into that.

template armv5*(_: typedesc[Arm9Bus]): bool = true

# Forward declarations: DMA's generic transfer is instantiated in the I/O
# code below and binds these at that point.
proc read8*(b: Arm9Bus; a: uint32): uint32 {.inline.}
proc read16*(b: Arm9Bus; a: uint32): uint32 {.inline.}
proc read32*(b: Arm9Bus; a: uint32): uint32 {.inline.}
proc write8*(b: Arm9Bus; a: uint32; v: uint8) {.inline.}
proc write16*(b: Arm9Bus; a: uint32; v: uint16) {.inline.}
proc write32*(b: Arm9Bus; a: uint32; v: uint32) {.inline.}

proc dma_stall*(b: Arm9Bus; cycles: int64) =
  ## A DMA held the bus: the CPU resumes `cycles` after the later of its own
  ## clock and the transfer's start.
  let n {.cursor.} = b.nds
  n.arm9.cycles = max(n.arm9.cycles, n.sched.now) + cycles

# --- I/O ---------------------------------------------------------------

proc gx_dma(n: NDS)

proc write_vcount(n: NDS; v: uint32) =
  ## VCOUNT is writable (GBATEK "DS Video", for syncing linked consoles):
  ## only while the line is 202..212 and to a value in 202..212. The new
  ## line number applies from the next line start.
  let v = int(v and 0x1FF)
  if n.gpu.vcount in 202..212 and v in 202..212: n.vcount_write = v

template sync9(n: NDS) =
  ## Bring the timeline to this CPU's clock before a register access, so
  ## timers, busy flags and new events see the access's time. A DMA started
  ## by an event keeps the event's time.
  if not n.dma9.dma_access: n.sched.now = n.arm9.cycles


proc io9_read(n: NDS; a: uint32): uint32 =
  let o = a and 0x00FF_FFFC'u32
  if (a and 0x00F0_0000'u32) == 0x0010_0000'u32:
    case a and 0x00FF_FFFC'u32
    of 0x10_0000: return n.ipc.recv(true)
    of 0x10_0010: return (if n.cart.owner_arm7: 0'u32 else: n.cart.read_data())
    else: return 0
  case o
  of 0x000: n.gpu.engine_a.read_reg(o)
  of 0x004: uint32(n.gpu.dispstat_read(n.gpu.stat9)) or (uint32(n.gpu.vcount) shl 16)
  of 0x008 .. 0x05C, 0x064 .. 0x06C:
    if o == 0x060: n.gpu3d.read_reg(o) else: n.gpu.engine_a.read_reg(o)
  of 0x060: n.gpu3d.read_reg(o)
  of 0x0B0 .. 0x0EC: n.dma9.read_reg(o)
  of 0x100 .. 0x10C: n.timers9.read_reg(o)
  of 0x130: uint32(n.input.keyinput()) or (uint32(n.input.keycnt9) shl 16)
  of 0x180: n.ipc.read_sync(true)
  of 0x184: n.ipc.read_fifocnt(true)
  of 0x1A0 .. 0x1AC: (if n.cart.owner_arm7: 0'u32 else: n.cart.read_reg(o))
  of 0x204: uint32(n.exmemcnt)
  of 0x208, 0x210, 0x214: n.irq9.read_reg(o)
  of 0x240:
    uint32(n.gpu.vram.cnt[vbA]) or (uint32(n.gpu.vram.cnt[vbB]) shl 8) or
      (uint32(n.gpu.vram.cnt[vbC]) shl 16) or (uint32(n.gpu.vram.cnt[vbD]) shl 24)
  of 0x244:
    uint32(n.gpu.vram.cnt[vbE]) or (uint32(n.gpu.vram.cnt[vbF]) shl 8) or
      (uint32(n.gpu.vram.cnt[vbG]) shl 16) or (uint32(n.wramcnt) shl 24)
  of 0x248: uint32(n.gpu.vram.cnt[vbH]) or (uint32(n.gpu.vram.cnt[vbI]) shl 8)
  of 0x280 .. 0x2BC: n.divsqrt.read_reg(o)
  of 0x300: uint32(n.postflg9)
  of 0x304: uint32(n.gpu.powcnt1)
  of 0x320 .. 0x6A0: n.gpu3d.read_reg(o)
  of 0x1000 .. 0x106C: n.gpu.engine_b.read_reg(o - 0x1000)
  of 0x4000 .. 0x4FFC: 0   # DSi SCFG/NDMA block: absent on a DS (runtimes probe it)
  else:
    n.note_unmapped("arm9 io", a, false)
    0

proc io9_write(n: NDS; a: uint32; v, mask: uint32) =
  let o = a and 0x00FF_FFFC'u32
  case o
  of 0x000, 0x008 .. 0x05C, 0x064 .. 0x06C: n.gpu.engine_a.write_reg(o, v, mask)
  of 0x004:
    n.gpu.stat9.dispstat_write(uint16(v), uint16(mask))
    if (mask and 0xFFFF_0000'u32) != 0: n.write_vcount(v shr 16)
  of 0x060: n.gpu3d.write_reg(o, v, mask)
  of 0x0B0 .. 0x0EC:
    n.dma9.write_reg(Arm9Bus(nds: n), o, v, mask)
    n.gx_dma()
  of 0x100 .. 0x10C: n.timers9.write_reg(o, v, mask)
  of 0x130:
    if (mask and 0xFFFF_0000'u32) != 0:
      n.input.keycnt9 = uint16(v shr 16)
      n.input.check_keypad_irq(n.input.keycnt9, n.irq9)
  of 0x180: n.ipc.write_sync(true, v, mask)
  of 0x184: n.ipc.write_fifocnt(true, v, mask)
  of 0x188: n.ipc.send(true, v)
  of 0x1A0 .. 0x1AC: (if not n.cart.owner_arm7: n.cart.write_reg(o, v, mask))
  of 0x204:
    if (mask and 0xFFFF) != 0:
      # bits 8-10 and 12 read zero, bit 13 reads set (GBATEK)
      let m = uint16(mask) and 0xC8FF'u16
      n.exmemcnt = (n.exmemcnt and not m) or (uint16(v) and m) or 0x2000
      n.cart.owner_arm7 = (n.exmemcnt and 0x800) != 0
  of 0x208, 0x210, 0x214:
    n.irq9.write_reg(o, v, mask)
    if o == 0x214: n.gpu3d.update_irq()   # IF.21 is level-triggered
  of 0x240, 0x244, 0x248:
    for i in 0..3:
      if ((mask shr (8 * i)) and 0xFF) != 0:
        let b = uint8((v shr (8 * i)) and 0xFF)
        let idx = int(o - 0x240) + i
        case idx
        of 0..6: n.gpu.vram.write_cnt(VramBank(idx), b)
        of 7: n.wramcnt = b and 3
        of 8: n.gpu.vram.write_cnt(vbH, b)
        of 9: n.gpu.vram.write_cnt(vbI, b)
        else: discard
  of 0x280 .. 0x2BC: n.divsqrt.write_reg(o, v, mask)
  of 0x300:
    if (mask and 0xFF) != 0: n.postflg9 = (n.postflg9 and 1) or uint8(v and 3)
  of 0x304:
    if (mask and 0xFFFF) != 0: n.gpu.write_powcnt1(uint16(v))
  of 0x320 .. 0x6A0: n.gpu3d.write_reg(o, v, mask)
  of 0x1000 .. 0x106C: n.gpu.engine_b.write_reg(o - 0x1000, v, mask)
  else: n.note_unmapped("arm9 io", a, true)

# --- Memory ------------------------------------------------------------

proc in_itcm(n: NDS; a: uint32; write: bool): bool {.inline.} =
  ## Load mode (CP15 control bit 19) makes the TCM write-only for data:
  ## reads fall through to the memory behind it.
  n.cp15.itcm_enabled and a < n.cp15.itcm_size and not n.dma9.dma_access and
    (write or not n.cp15.itcm_load_mode)

proc in_dtcm(n: NDS; a: uint32; write: bool): bool {.inline.} =
  n.cp15.dtcm_enabled and a >= n.cp15.dtcm_base and
    a - n.cp15.dtcm_base < n.cp15.dtcm_size and not n.dma9.dma_access and
    (write or not n.cp15.dtcm_load_mode)

proc shared_wram9(n: NDS; a: uint32; ok: var bool): int {.inline.} =
  ok = true
  case n.wramcnt
  of 0: int(a and 0x7FFF)
  of 1: 0x4000 + int(a and 0x3FFF)
  of 2: int(a and 0x3FFF)
  else: ok = false; 0

proc read9(n: NDS; a: uint32; width: static int): uint32 =
  template rd(s: seq[uint8]; i: int): uint32 =
    when width == 32: rd32(s, i)
    elif width == 16: rd16(s, i)
    else: uint32(s[i])
  if n.in_itcm(a, false): return rd(n.itcm, int(a and 0x7FFF))
  if n.in_dtcm(a, false): return rd(n.dtcm, int((a - n.cp15.dtcm_base) and 0x3FFF))
  case a shr 24
  of 0x02: rd(n.main_ram, int(a and 0x3FFFFF))
  of 0x03:
    var ok: bool
    let i = n.shared_wram9(a, ok)
    if ok: rd(n.shared_wram, i) else: 0'u32
  of 0x04:
    n.sync9()
    let w = n.io9_read(a and not 3'u32)
    when defined(ndsdebug):
      if n.iolog: n.log_io("9", a, w, 0xFFFF_FFFF'u32, false)
    when width == 32: w
    elif width == 16: (w shr ((a and 2) * 8)) and 0xFFFF
    else: (w shr ((a and 3) * 8)) and 0xFF
  of 0x05:
    let p = cast[ptr UncheckedArray[uint8]](addr n.gpu.palette[0])
    let i = int(a and 0x7FF)
    when width == 32: uint32(p[i]) or (uint32(p[i+1]) shl 8) or (uint32(p[i+2]) shl 16) or (uint32(p[i+3]) shl 24)
    elif width == 16: uint32(p[i]) or (uint32(p[i+1]) shl 8)
    else: uint32(p[i])
  of 0x06:
    var off: int
    let r = arm9_region(a, off)
    when width == 32: n.gpu.vram.read32(r, off)
    elif width == 16: uint32(n.gpu.vram.read16(r, off))
    else: uint32(n.gpu.vram.read8(r, off))
  of 0x07:
    let p = cast[ptr UncheckedArray[uint8]](addr n.gpu.oam[0])
    let i = int(a and 0x7FF)
    when width == 32: uint32(p[i]) or (uint32(p[i+1]) shl 8) or (uint32(p[i+2]) shl 16) or (uint32(p[i+3]) shl 24)
    elif width == 16: uint32(p[i]) or (uint32(p[i+1]) shl 8)
    else: uint32(p[i])
  of 0x08, 0x09, 0x0A: n.slot2_read(a, true, width)
  of 0xFF:
    if a >= 0xFFFF0000'u32: rd(n.bios9, int(a and 0xFFF)) else: 0'u32
  else:
    n.note_unmapped("arm9", a, false)
    0'u32

proc write9(n: NDS; a: uint32; v: uint32; width: static int) =
  watch_write(n, "9", n.arm9, a, v)
  template wr(s: var seq[uint8]; i: int) =
    when width == 32: wr32(s, i, v)
    elif width == 16: wr16(s, i, v)
    else: s[i] = uint8(v)
  if n.in_itcm(a, true): wr(n.itcm, int(a and 0x7FFF)); return
  if n.in_dtcm(a, true): wr(n.dtcm, int((a - n.cp15.dtcm_base) and 0x3FFF)); return
  case a shr 24
  of 0x02: wr(n.main_ram, int(a and 0x3FFFFF))
  of 0x03:
    var ok: bool
    let i = n.shared_wram9(a, ok)
    if ok: wr(n.shared_wram, i)
  of 0x04:
    let sh = (a and 3) * 8
    let mask = when width == 32: 0xFFFF_FFFF'u32
               elif width == 16: 0xFFFF'u32 shl sh
               else: 0xFF'u32 shl sh
    when defined(ndsdebug):
      if n.iolog: n.log_io("9", a and not 3'u32, v shl sh, mask, true)
    n.io9_write(a and not 3'u32, v shl sh, mask)
  of 0x05, 0x07:
    when width != 8:
      let p = cast[ptr UncheckedArray[uint8]](
        if (a shr 24) == 5: addr n.gpu.palette[0] else: addr n.gpu.oam[0])
      let i = int(a and 0x7FF)
      p[i] = uint8(v); p[i + 1] = uint8(v shr 8)
      when width == 32:
        p[i + 2] = uint8(v shr 16); p[i + 3] = uint8(v shr 24)
  of 0x06:
    when width != 8:
      var off: int
      let r = arm9_region(a, off)
      when width == 32: n.gpu.vram.write32(r, off, v)
      else: n.gpu.vram.write16(r, off, uint16(v))
  of 0x08, 0x09, 0x0A: discard
  else: n.note_unmapped("arm9", a, true)

# --- CPU mixins --------------------------------------------------------

proc read8*(b: Arm9Bus; a: uint32): uint32 {.inline.} = b.nds.read9(a, 8)
proc read16*(b: Arm9Bus; a: uint32): uint32 {.inline.} = b.nds.read9(a, 16)
proc read32*(b: Arm9Bus; a: uint32): uint32 {.inline.} = b.nds.read9(a, 32)

proc write8*(b: Arm9Bus; a: uint32; v: uint8) {.inline.} =
  b.nds.sync9()
  b.nds.write9(a, uint32(v), 8)
proc write16*(b: Arm9Bus; a: uint32; v: uint16) {.inline.} =
  b.nds.sync9()
  b.nds.write9(a, uint32(v), 16)
proc write32*(b: Arm9Bus; a: uint32; v: uint32) {.inline.} =
  b.nds.sync9()
  b.nds.write9(a, v, 32)

proc fetch32*(b: Arm9Bus; a: uint32): uint32 {.inline.} =
  let n {.cursor.} = b.nds
  if n.cp15.itcm_enabled and a < n.cp15.itcm_size: return rd32(n.itcm, int(a and 0x7FFF))
  if (a shr 24) == 0x02: return rd32(n.main_ram, int(a and 0x3FFFFF))
  if a >= 0xFFFF0000'u32: return rd32(n.bios9, int(a and 0xFFF))
  n.read9(a, 32)

proc fetch16*(b: Arm9Bus; a: uint32): uint32 {.inline.} =
  let n {.cursor.} = b.nds
  if n.cp15.itcm_enabled and a < n.cp15.itcm_size: return rd16(n.itcm, int(a and 0x7FFF))
  if (a shr 24) == 0x02: return rd16(n.main_ram, int(a and 0x3FFFFF))
  if a >= 0xFFFF0000'u32: return rd16(n.bios9, int(a and 0xFFF))
  n.read9(a, 16)

proc irq_line*(b: Arm9Bus): bool {.inline.} = b.nds.irq9.line()
proc irq_wake*(b: Arm9Bus): bool {.inline.} = b.nds.irq9.wake()
proc access_cycles*(b: Arm9Bus): int64 {.inline.} = 0   # TODO(timing)

proc cp15_read*(b: Arm9Bus; op1, cn, cm, op2: uint32): uint32 =
  b.nds.cp15.read(op1, cn, cm, op2)

proc cp15_write*(b: Arm9Bus; op1, cn, cm, op2, v: uint32) =
  let n {.cursor.} = b.nds
  n.cp15.write(op1, cn, cm, op2, v)
  n.arm9.vector_base = n.cp15.vector_base()
  n.arm9.no_load_interwork = (n.cp15.control and 0x8000) != 0
  if n.cp15.halt_request:
    n.cp15.halt_request = false
    n.arm9.halted = true

proc swi_hook*(b: Arm9Bus; comment: uint32): bool =
  ## HLE BIOS: true = the SWI ran in Nim (hle_bios.nim), skip the vector.
  b.nds.hle_bios9 and b.nds.arm9.hle_swi(comment)
