# ARM7 bus map (included by nds.nim). GBATEK "DS Memory Map":
#   0x00 BIOS 16 KB (readable only while executing inside it)
#   0x02 main RAM   0x03000000-0x037FFFFF shared WRAM (WRAMCNT) or WRAM mirror
#   0x03800000 ARM7 WRAM 64 KB   0x04 I/O (+ wifi at 0x04800000)
#   0x06 VRAM banks C/D mapped to the ARM7   0x08-0x0A GBA slot

template armv5*(_: typedesc[Arm7Bus]): bool = false

# Forward declarations: DMA's generic transfer is instantiated in the I/O
# code below and binds these at that point.
proc read8*(b: Arm7Bus; a: uint32): uint32 {.inline.}
proc read16*(b: Arm7Bus; a: uint32): uint32 {.inline.}
proc read32*(b: Arm7Bus; a: uint32): uint32 {.inline.}
proc write8*(b: Arm7Bus; a: uint32; v: uint8) {.inline.}
proc write16*(b: Arm7Bus; a: uint32; v: uint16) {.inline.}
proc write32*(b: Arm7Bus; a: uint32; v: uint32) {.inline.}

# Idle-loop skipping (arm/cpu.nim loop_edge): the epoch, and the timing
# state that decides what the next accesses cost.
proc idle_epoch*(b: Arm7Bus): uint64 {.inline.} = b.nds.idle_epoch + b.nds.idle_epoch7
proc ev_epoch*(b: Arm7Bus): uint64 {.inline.} = b.nds.ev_epoch
proc dev_read*(b: Arm7Bus): bool {.inline.} = b.nds.dev7
proc clear_dev*(b: Arm7Bus) {.inline.} = b.nds.dev7 = false
proc idle_sig*(b: Arm7Bus): IdleSig {.inline.} =
  [b.nds.last_fetch7, b.nds.last_data7, 0, 0, 0, 0, 0, 0]

proc dma_stall*(b: Arm7Bus; cycles: int64) =
  ## A DMA held the bus: the CPU resumes `cycles` after the later of its own
  ## clock and the transfer's start.
  let n {.cursor.} = b.nds
  n.arm7.cycles = max(n.arm7.cycles, n.sched.now) + cycles
  inc n.idle_epoch            # the CPU's clock moved (arm/cpu.nim loop_edge)

# --- I/O ---------------------------------------------------------------

template sync7(n: NDS) =
  ## Bring the timeline to this CPU's clock before a register access, so
  ## timers, busy flags and new events see the access's time. A DMA started
  ## by an event keeps the event's time.
  if not n.dma7.dma_access: n.sched.now = n.arm7.cycles


proc io7_steady(a: uint32): bool {.inline.} =
  ## As bus9.nim io9_steady: registers only writes and events change, read
  ## without a side effect (not wifi, timers, SPI/RTC, FIFOs).
  if (a and 0x00F0_0000'u32) != 0: return false
  case a and 0x00FF_FFFC'u32
  of 0x004, 0x0B0 .. 0x0DC, 0x130, 0x180, 0x184, 0x1A4, 0x204, 0x208 .. 0x214, 0x240,
     0x300 .. 0x308, 0x400 .. 0x51C: true
  else: false

proc io7_read(n: NDS; a: uint32): uint32 =
  if (a and 0x00F0_0000'u32) == 0x0010_0000'u32:
    case a and 0x00FF_FFFC'u32
    of 0x10_0000: return n.ipc.recv(false)
    of 0x10_0010: return (if n.cart.owner_arm7: n.cart.read_data() else: 0'u32)
    else: return 0
  if (a and 0x00FF_0000'u32) >= 0x0080_0000'u32:
    return uint32(n.wifi.read16(a)) or (uint32(n.wifi.read16(a + 2)) shl 16)
  let o = a and 0x00FF_FFFC'u32
  case o
  of 0x004: uint32(n.gpu.dispstat_read(n.gpu.stat7)) or (uint32(n.gpu.vcount) shl 16)
  of 0x0B0 .. 0x0DC: n.dma7.read_reg(o)
  of 0x100 .. 0x10C: n.timers7.read_reg(o)
  of 0x130: uint32(n.input.keyinput()) or (uint32(n.input.keycnt7) shl 16)
  of 0x134: uint32(n.rtc.read_rcnt()) or (uint32(n.input.extkeyin()) shl 16)  # RCNT | EXTKEYIN
  of 0x138: uint32(n.rtc.read_reg())
  of 0x180: n.ipc.read_sync(false)
  of 0x184: n.ipc.read_fifocnt(false)
  of 0x1A0 .. 0x1B8: (if n.cart.owner_arm7: n.cart.read_reg(o) else: 0'u32)
  of 0x1C0: n.spi.read_reg(o)
  of 0x204: uint32((n.exmemcnt and 0xFF80'u16) or n.exmem7_lo)
  of 0x208, 0x210, 0x214: n.irq7.read_reg(o)
  of 0x240: uint32(n.gpu.vram.vramstat) or (uint32(n.wramcnt) shl 8)
  of 0x300: uint32(n.postflg7)
  of 0x304: uint32(n.powcnt2)
  of 0x308: n.biosprot
  of 0x400 .. 0x51C: n.spu.read_reg(o)
  else:
    n.note_unmapped("arm7 io", a, false)
    0

proc io7_write(n: NDS; a: uint32; v, mask: uint32) =
  if (a and 0x00FF_0000'u32) >= 0x0080_0000'u32:
    # byte writes are ignored (GBATEK "DS Wifi I/O Map")
    if (mask and 0xFFFF) == 0xFFFF: n.wifi.write16(a, uint16(v))
    if (mask and 0xFFFF_0000'u32) == 0xFFFF_0000'u32: n.wifi.write16(a + 2, uint16(v shr 16))
    return
  let o = a and 0x00FF_FFFC'u32
  case o
  of 0x004:
    n.gpu.stat7.dispstat_write(uint16(v), uint16(mask))
    if (mask and 0xFFFF_0000'u32) != 0: n.write_vcount(v shr 16)
  of 0x204:
    # EXMEMSTAT: the ARM7 sets only its own bits 0-6
    if (mask and 0x7F) != 0:
      n.exmem7_lo = (n.exmem7_lo and not uint16(mask and 0x7F)) or uint16(v and mask and 0x7F)
      n.slot7_t = slot_timing(n.exmem7_lo)
  of 0x0B0 .. 0x0DC: n.dma7.write_reg(Arm7Bus(nds: n), o, v, mask)
  of 0x100 .. 0x10C: n.timers7.write_reg(o, v, mask)
  of 0x130:
    if (mask and 0xFFFF_0000'u32) != 0:
      n.input.keycnt7 = uint16(v shr 16)
      n.input.check_keypad_irq(n.input.keycnt7, n.irq7)
  of 0x134: (if (mask and 0xFFFF) != 0: n.rtc.write_rcnt(uint16(v), uint16(mask)))  # RCNT (io/rtc.nim)
  of 0x138: (if (mask and 0xFFFF) != 0: n.rtc.write_reg(uint16(v)))
  of 0x180: n.ipc.write_sync(false, v, mask)
  of 0x184: n.ipc.write_fifocnt(false, v, mask)
  of 0x188: n.ipc.send(false, v)
  of 0x1A0 .. 0x1B8:
    if n.cart.owner_arm7: n.cart.write_reg(o, v, mask, n.arm7.cur_pc, from7 = true)
  of 0x1C0:
    if (mask and 0xFFFF) != 0: n.spi.write_cnt(v, mask)
    if (mask and 0x00FF_0000'u32) != 0: n.spi.write_data(uint8(v shr 16))
  of 0x208, 0x210, 0x214: n.irq7.write_reg(o, v, mask)
  of 0x300:
    # POSTFLG: only BIOS code can set it, nothing can clear it
    if (mask and 0xFF) != 0 and n.arm7.cur_pc < 0x4000:
      n.postflg7 = n.postflg7 or uint8(v and 1)
    if (mask and 0xFF00) != 0:
      # HALTCNT: 2 = halt, 3 = sleep (nds.nim `sleep_for`); 1 (GBA mode)
      # is not supported and does nothing
      let mode = (v shr 14) and 3
      if mode >= 2: n.arm7.halted = true
      if mode == 3: n.sleeping = true
  of 0x304: (if (mask and 0xFFFF) != 0: n.powcnt2 = uint16(v) and 3)
  of 0x308:
    # write-once (the BIOS sets 0x1205; bit 0 is ignored)
    if n.biosprot == 0: n.biosprot = v and mask and 0x3FFE
  of 0x400 .. 0x51C: n.spu.write_reg(o, v, mask)
  else: n.note_unmapped("arm7 io", a, true)

# --- Memory ------------------------------------------------------------

proc wram7(n: NDS; a: uint32; shared: var bool): int {.inline.} =
  ## 0x03xxxxxx on the ARM7: the shared WRAM part it owns, or its own WRAM.
  if a < 0x03800000'u32:
    shared = true
    case n.wramcnt
    of 1: return int(a and 0x3FFF)
    of 2: return 0x4000 + int(a and 0x3FFF)
    of 3: return int(a and 0x7FFF)
    else: discard
  shared = false
  int(a and 0xFFFF)

proc read7(n: NDS; a: uint32; width: static int): uint32 =
  template rd(s: seq[uint8]; i: int): uint32 =
    when width == 32: rd32(s, i)
    elif width == 16: rd16(s, i)
    else: uint32(s[i])
  case a shr 24
  of 0x00:
    # BIOSPROT (GBATEK "DS Memory Control - BIOS"): only code inside the
    # BIOS reads it, and only code below BIOSPROT reads below BIOSPROT;
    # anything else reads 0xFF bytes. Fetches pass (pc is the address).
    if a >= 0x4000: 0'u32
    elif n.arm7.cur_pc < (if a < n.biosprot: n.biosprot else: 0x4000'u32):
      rd(n.bios7, int(a))
    else:
      when width == 32: 0xFFFF_FFFF'u32 elif width == 16: 0xFFFF'u32 else: 0xFF'u32
  of 0x02:
    # memory's side of anything the ARM9's data cache holds (bus9.nim dc_*)
    if unlikely(n.dc_apart(int(a and 0x3FFFFF))): n.dc_mem_read(int(a and 0x3FFFFF), width)
    else: rd(n.main_ram, int(a and 0x3FFFFF))
  of 0x03:
    var shared: bool
    let i = n.wram7(a, shared)
    if shared: rd(n.shared_wram, i) else: rd(n.arm7_wram, i)
  of 0x04:
    n.sync7()
    n.arm7.attn = true          # a read side effect may raise an IRQ (arm/cpu.nim run)
    n.dev7 = true               # a device: what an event may change (arm/cpu.nim loop_edge)
    if not io7_steady(a):
      # the IPC FIFO pop is seen by the ARM9 too; the rest only by this CPU
      if (a and 0x00FF_FFFC'u32) == 0x10_0000: inc n.idle_epoch else: inc n.idle_epoch7
    if (a and 0x00FF_0000'u32) >= 0x0080_0000'u32:
      # wifi: 16-bit ports with read side effects, so only the halfwords
      # actually accessed are read (a byte read reads its halfword)
      when width == 32:
        return uint32(n.wifi.read16(a)) or (uint32(n.wifi.read16(a + 2)) shl 16)
      elif width == 16:
        return uint32(n.wifi.read16(a))
      else:
        return (uint32(n.wifi.read16(a and not 1'u32)) shr ((a and 1) * 8)) and 0xFF
    let w = n.io7_read(a and not 3'u32)
    when defined(ndsdebug):
      if n.iolog: n.log_io("7", a, w, 0xFFFF_FFFF'u32, false, n.arm7.cur_pc)
    when width == 32: w
    elif width == 16: (w shr ((a and 2) * 8)) and 0xFFFF
    else: (w shr ((a and 3) * 8)) and 0xFF
  of 0x06:
    n.dev7 = true
    let off = int(a and 0x3FFFF)
    when width == 32: n.gpu.vram.read32(vrArm7, off)
    elif width == 16: uint32(n.gpu.vram.read16(vrArm7, off))
    else: uint32(n.gpu.vram.read8(vrArm7, off))
  of 0x08, 0x09, 0x0A:
    n.dev7 = true
    n.slot2_read(a, false, width)
  else:
    n.note_unmapped("arm7", a, false)
    0'u32

proc write7(n: NDS; a: uint32; v: uint32; width: static int) =
  watch_write(n, "7", n.arm7, a, v)
  template wr(s: var seq[uint8]; i: int; ep: untyped = n.idle_epoch) =
    # RAM: only a store that changes memory can end a polling loop (one
    # host load and store: `i` is aligned to the width, the host is
    # little-endian like the DS)
    let p = addr s[i]
    when width == 32:
      if cast[ptr uint32](p)[] != v: inc ep; cast[ptr uint32](p)[] = v
    elif width == 16:
      if cast[ptr uint16](p)[] != uint16(v): inc ep; cast[ptr uint16](p)[] = uint16(v)
    else:
      if p[] != uint8(v): inc ep; p[] = uint8(v)
  if (a shr 24) - 2 >= 2: inc n.idle_epoch   # I/O, VRAM, slot 2
  case a shr 24
  of 0x02:
    let i = int(a and 0x3FFFFF)
    let held = n.tm.slot_of[i shr 5]
    if unlikely(held != 0):
      # memory behind the ARM9's caches changes
      if held >= IC_ONE: n.ic_keep(i shr 5)
      if (held and 0xFF) != 0: n.dc_write(i, v, width, false, false)
      else: wr(n.main_ram, i)
      inc n.idle_epoch
    else: wr(n.main_ram, i)
  of 0x03:
    var shared: bool
    let i = n.wram7(a, shared)
    if shared: wr(n.shared_wram, i) else: wr(n.arm7_wram, i, n.idle_epoch7)
  of 0x04:
    let sh = (a and 3) * 8
    let mask = when width == 32: 0xFFFF_FFFF'u32
               elif width == 16: 0xFFFF'u32 shl sh
               else: 0xFF'u32 shl sh
    when defined(ndsdebug):
      if n.iolog: n.log_io("7", a and not 3'u32, v shl sh, mask, true, n.arm7.cur_pc)
    n.arm7.attn = true          # IE/IF/IME, HALTCNT, DMA, ... (arm/cpu.nim run)
    n.io7_write(a and not 3'u32, v shl sh, mask)
  of 0x06:
    let off = int(a and 0x3FFFF)
    when width == 32: n.gpu.vram.write32(vrArm7, off, v)
    elif width == 16: n.gpu.vram.write16(vrArm7, off, uint16(v))
    else: n.gpu.vram.write8(vrArm7, off, uint8(v))
  of 0x08, 0x09, 0x0A: n.slot2_write(a, v, false, width)
  of 0x00: discard
  else: n.note_unmapped("arm7", a, true)

# --- CPU mixins --------------------------------------------------------

proc data_cost7(n: NDS; a: uint32; width: static int) {.inline.} =
  ## Charge a CPU data access (timing.nim); DMA's own accesses are not.
  if n.dma7.dma_access: return
  let seq = a == n.last_data7 + (when width == 32: 4'u32 else: 2'u32)
  n.last_data7 = a
  n.wait7 += data7(a shr 24, width, seq, n.slot7_t)

proc fetch_cost7(n: NDS; a: uint32; width: static int) {.inline.} =
  ## A nonsequential fetch (a branch) also pays the refill's second fetch.
  n.last_data7 = NO_ADDR
  let seq = a == n.last_fetch7 + (when width == 32: 4'u32 else: 2'u32)
  # a backward branch's target: a loop head (arm/cpu.nim loop_edge)
  if not seq and a <= n.last_fetch7:
    if n.arm7.wl_cold > 0: dec n.arm7.wl_cold
    elif n.arm7.wl_on: n.arm7.loop_edge()
  n.last_fetch7 = a
  let top = a shr 24
  n.wait7 += code7(top, width, seq, n.slot7_t)
  if not seq: n.wait7 += code7(top, width, true, n.slot7_t)

template wram7_fast(a: uint32): bool =
  ## 0x03800000-0x03FFFFFF: the ARM7's own WRAM (and its mirrors), most of
  ## its data accesses. data_cost7 + read7/write7 there come to this: two
  ## master cycles whatever the width or sequence (timing.nim data7).
  (a shr 23) == 7

template wram7_charge(n: NDS; a: uint32) =
  if not n.dma7.dma_access:
    n.last_data7 = a
    n.wait7 += 2

template wram7_ptr(n: NDS; a: uint32; T: typedesc): ptr T =
  cast[ptr T](addr n.arm7_wram[int(a and 0xFFFF)])

proc read8*(b: Arm7Bus; a: uint32): uint32 {.inline.} =
  let n {.cursor.} = b.nds
  if wram7_fast(a):
    n.wram7_charge(a)
    return uint32(n.wram7_ptr(a, uint8)[])
  n.data_cost7(a, 8)
  n.read7(a, 8)
proc read16*(b: Arm7Bus; a: uint32): uint32 {.inline.} =
  let n {.cursor.} = b.nds
  if wram7_fast(a):
    n.wram7_charge(a)
    return uint32(n.wram7_ptr(a, uint16)[])
  n.data_cost7(a, 16)
  n.read7(a, 16)
proc read32*(b: Arm7Bus; a: uint32): uint32 {.inline.} =
  let n {.cursor.} = b.nds
  if wram7_fast(a):
    n.wram7_charge(a)
    return n.wram7_ptr(a, uint32)[]
  n.data_cost7(a, 32)
  n.read7(a, 32)

template wram7_store(n: NDS; a: uint32; v: typed; T: typedesc) =
  # write7's own-WRAM store: only a change can end a polling loop
  n.wram7_charge(a)
  n.sync7()
  watch_write(n, "7", n.arm7, a, uint32(v))
  let p = n.wram7_ptr(a, T)
  if p[] != v:
    inc n.idle_epoch7
    p[] = v

proc write8*(b: Arm7Bus; a: uint32; v: uint8) {.inline.} =
  let n {.cursor.} = b.nds
  if wram7_fast(a):
    n.wram7_store(a, v, uint8)
    return
  n.data_cost7(a, 8)
  n.sync7()
  n.write7(a, uint32(v), 8)
proc write16*(b: Arm7Bus; a: uint32; v: uint16) {.inline.} =
  let n {.cursor.} = b.nds
  if wram7_fast(a):
    n.wram7_store(a, v, uint16)
    return
  n.data_cost7(a, 16)
  n.sync7()
  n.write7(a, uint32(v), 16)
proc write32*(b: Arm7Bus; a: uint32; v: uint32) {.inline.} =
  let n {.cursor.} = b.nds
  if wram7_fast(a):
    n.wram7_store(a, v, uint32)
    return
  n.data_cost7(a, 32)
  n.sync7()
  n.write7(a, v, 32)

proc fetch_page7(n: NDS; a: uint32) =
  ## After a fetch from `a`: in the BIOS, main RAM with nothing apart from
  ## memory (bus9.nim dc_*) and WRAM, a sequential fetch reads memory at a
  ## fixed cost and changes nothing but the trackers, so the rest of the
  ## 4 KB page is read from `fptr7` (fetch32/fetch16). Fetches pass BIOSPROT
  ## (pc = address). WRAMCNT, a page going apart (page_apart_now) or a
  ## state load turns this off.
  n.fpage7 = NO_PAGE
  case a shr 24
  of 0x00:
    if a >= 0x4000: return
    n.fptr7 = cast[ptr UncheckedArray[uint8]](addr n.bios7[int(a and 0x3000)])
  of 0x02:
    let p = int((a and 0x3FFFFF) shr 12)
    if n.tm.page_apart[p] != 0: return
    n.fptr7 = cast[ptr UncheckedArray[uint8]](addr n.main_ram[p shl 12])
  of 0x03:
    var shared: bool
    let i = n.wram7(a and not 0xFFF'u32, shared)
    n.fptr7 = cast[ptr UncheckedArray[uint8]](
      if shared: addr n.shared_wram[i] else: addr n.arm7_wram[i])
  else: return
  n.fseq7 = [code7(a shr 24, 16, true, n.slot7_t), code7(a shr 24, 32, true, n.slot7_t)]
  n.fpage7 = a shr 12

proc fetch_slow7(n: NDS; a: uint32; width: static int): uint32 {.noinline.} =
  n.fetch_cost7(a, width)
  result = n.read7(a, width)
  if (a shr 12) != n.fpage7: n.fetch_page7(a)

proc fetch32*(b: Arm7Bus; a: uint32): uint32 {.inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".} =
  let n {.cursor.} = b.nds
  if likely((a shr 12) == n.fpage7 and a == n.last_fetch7 + 4):
    # fetch_cost7's sequential case, then read7
    n.last_data7 = NO_ADDR
    n.last_fetch7 = a
    n.wait7 += n.fseq7[1]
    return cast[ptr uint32](addr n.fptr7[a and 0xFFF])[]
  n.fetch_slow7(a, 32)
proc fetch16*(b: Arm7Bus; a: uint32): uint32 {.inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".} =
  let n {.cursor.} = b.nds
  if likely((a shr 12) == n.fpage7 and a == n.last_fetch7 + 2):
    n.last_data7 = NO_ADDR
    n.last_fetch7 = a
    n.wait7 += n.fseq7[0]
    return uint32(cast[ptr uint16](addr n.fptr7[a and 0xFFF])[])
  n.fetch_slow7(a, 16)

# Sound: channel sample fetch and capture stores (io/spu.nim). No CPU clock
# sync -- they run inside the evSpuSample dispatch.
proc spu_read32*(b: Arm7Bus; a: uint32): uint32 = b.nds.read7(a, 32)
proc spu_write32*(b: Arm7Bus; a: uint32; v: uint32) = b.nds.write7(a, v, 32)

proc irq_line*(b: Arm7Bus): bool {.inline.} = b.nds.irq7.line()
proc irq_wake*(b: Arm7Bus): bool {.inline.} =
  ## Halt ends on (IE and IF) != 0 whatever IME says; sleep only through
  ## `wake_from_sleep` (nds.nim).
  not b.nds.sleeping and b.nds.irq7.wake()
proc access_cycles*(b: Arm7Bus): int64 {.inline.} =
  result = b.nds.wait7
  b.nds.wait7 = 0
proc cp15_read*(b: Arm7Bus; op1, cn, cm, op2: uint32): uint32 = 0
proc cp15_write*(b: Arm7Bus; op1, cn, cm, op2, v: uint32) = discard
proc data_cached*(b: Arm7Bus; a: uint32): bool = false   ## no data cache on the ARM7

proc swi_hook*(b: Arm7Bus; comment: uint32): bool =
  ## HLE BIOS: true = the SWI ran in Nim (hle_bios.nim), skip the vector.
  b.nds.hle_bios7 and b.nds.arm7.hle_swi(comment)

# The dispatch tables (arm/cpu.nim): after every mixin their handlers use.
dispatch_tables(Arm7Bus)
