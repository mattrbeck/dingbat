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
proc read16*(b: Dma9Bus; a: uint32): uint32 {.inline.}
proc read32*(b: Dma9Bus; a: uint32): uint32 {.inline.}
proc write16*(b: Dma9Bus; a: uint32; v: uint16) {.inline.}
proc write32*(b: Dma9Bus; a: uint32; v: uint32) {.inline.}

# Idle-loop skipping (arm/cpu.nim loop_edge): the epoch, and the timing
# state that decides what the next accesses cost.
proc idle_epoch*(b: Arm9Bus): uint64 {.inline.} = b.nds.idle_epoch + b.nds.idle_epoch9
proc ev_epoch*(b: Arm9Bus): uint64 {.inline.} = b.nds.ev_epoch
proc dev_read*(b: Arm9Bus): bool {.inline.} = b.nds.dev9
proc clear_dev*(b: Arm9Bus) {.inline.} = b.nds.dev9 = false
proc idle_sig*(b: Arm9Bus): IdleSig {.inline.} =
  let n {.cursor.} = b.nds
  [n.last_fetch9, n.last_data9, n.last_pc9, n.pu_ok[0], n.pu_ok[1], n.pu_ok[2],
   n.tm.icache.last, n.tm.dcache.last]

proc dma_stall*(b: Dma9Bus; cycles: int64) =
  ## A DMA held the bus: the CPU resumes `cycles` after the later of its own
  ## clock and the transfer's start.
  let n {.cursor.} = b.nds
  n.arm9.cycles = max(n.arm9.cycles, n.sched.now) + cycles
  inc n.idle_epoch            # the CPU's clock moved (arm/cpu.nim loop_edge)

# --- I/O ---------------------------------------------------------------

proc gx_service(n: NDS; appended = false)

proc gx_write(n: NDS; o, v, mask: uint32) =
  ## A geometry engine write; a full FIFO holds the bus, so the writer and
  ## the ARM7 wait (GBATEK "DS 3D Geometry Commands": "the bus cannot be
  ## used even by DMA, interrupts, or by the NDS7 CPU").
  n.gpu3d.write_reg(o, v, mask)
  let t = n.gpu3d.stall_until
  if t > n.arm9.cycles:
    n.arm9.cycles = t
    n.arm7.cycles = max(n.arm7.cycles, t)
  if not n.dma9.dma_access and o >= 0x400: n.gx_service(appended = o < 0x600)

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


proc io9_steady(o: uint32): bool {.inline.} =
  ## Registers whose value only writes and events change, read without a
  ## side effect: a loop polling them may be skipped (arm/cpu.nim
  ## loop_edge). Timers, busy flags, GXSTAT, FIFOs and the rest are not.
  case o
  of 0x000 .. 0x05C, 0x064 .. 0x06C, 0x0B0 .. 0x0EC, 0x130, 0x180, 0x184, 0x1A4, 0x204,
     0x208 .. 0x214, 0x240 .. 0x248, 0x300, 0x304, 0x1000 .. 0x106C: true
  else: false

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
  of 0x1A0 .. 0x1B8: (if n.cart.owner_arm7: 0'u32 else: n.cart.read_reg(o))
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
  # A unit switched off in POWCNT1 leaves its ports read-only (GBATEK "DS
  # Power Control"; disp_powcnt in the reference runs, docs/oracles.md):
  # 2D A 008h-05Fh (bit 1), 3D rendering 320h-3FFh (bit 2), geometry
  # 400h-6FFh (bit 3, commands included), 2D B 1008h-105Fh (bit 9).
  let pw = n.gpu.powcnt1
  case o
  of 0x008 .. 0x05C:
    if (pw and 2) != 0: n.gpu.engine_a.write_reg(o, v, mask)
  of 0x320 .. 0x3FC:
    if (pw and 4) != 0: n.gx_write(o, v, mask)
  of 0x400 .. 0x6A0:
    if (pw and 8) != 0: n.gx_write(o, v, mask)
  of 0x1008 .. 0x105C:
    if (pw and 0x200) != 0: n.gpu.engine_b.write_reg(o - 0x1000, v, mask)
  of 0x000, 0x064 .. 0x06C: n.gpu.engine_a.write_reg(o, v, mask)
  of 0x004:
    n.gpu.stat9.dispstat_write(uint16(v), uint16(mask))
    if (mask and 0xFFFF_0000'u32) != 0: n.write_vcount(v shr 16)
  of 0x060: n.gpu3d.write_reg(o, v, mask)
  of 0x0B0 .. 0x0EC:
    var was: array[4, bool]
    for i in 0..3: was[i] = n.dma9.ch[i].enabled
    n.dma9.write_reg(Dma9Bus(nds: n), o, v, mask)
    # a channel (re)started mid-frame waits for the next frame in mode 4
    for i in 0..3:
      if n.dma9.ch[i].enabled and not was[i]: n.mmem_armed[i] = false
    n.gx_service()
  of 0x100 .. 0x10C: n.timers9.write_reg(o, v, mask)
  of 0x130:
    if (mask and 0xFFFF_0000'u32) != 0:
      n.input.keycnt9 = uint16(v shr 16)
      n.input.check_keypad_irq(n.input.keycnt9, n.irq9)
  of 0x180: n.ipc.write_sync(true, v, mask)
  of 0x184: n.ipc.write_fifocnt(true, v, mask)
  of 0x188: n.ipc.send(true, v)
  of 0x1A0 .. 0x1B8:
    if not n.cart.owner_arm7: n.cart.write_reg(o, v, mask, n.arm9.cur_pc)
  of 0x204:
    if (mask and 0xFFFF) != 0:
      # bits 8-10 and 12 read zero, bit 13 reads set (GBATEK); writes to
      # bit 14 are ignored (GBATEK "appear to be ignored?"; slot2_probe in
      # the reference runs, docs/oracles.md) and it stays set from boot
      let m = uint16(mask) and 0x88FF'u16
      n.exmemcnt = (n.exmemcnt and not m) or (uint16(v) and m) or 0x2000
      n.cart.owner_arm7 = (n.exmemcnt and 0x800) != 0
      n.slot9_t = slot_timing(n.exmemcnt)
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
        of 7:
          n.wramcnt = b and 3
          n.fetch_paths_off()
        of 8: n.gpu.vram.write_cnt(vbH, b)
        of 9: n.gpu.vram.write_cnt(vbI, b)
        else: discard
  of 0x280 .. 0x2BC: n.divsqrt.write_reg(o, v, mask)
  of 0x300:
    if (mask and 0xFF) != 0: n.postflg9 = (n.postflg9 and 1) or uint8(v and 3)
  of 0x304:
    if (mask and 0xFFFF) != 0: n.gpu.write_powcnt1(uint16(v))
  of 0x1000 .. 0x1004, 0x1060 .. 0x106C: n.gpu.engine_b.write_reg(o - 0x1000, v, mask)
  else: n.note_unmapped("arm9 io", a, true)

# --- Memory ------------------------------------------------------------

proc pal_oam_on(n: NDS; a: uint32): bool {.inline.} =
  ## An engine's palette (05000000h A, 05000400h B) and OAM (07000000h,
  ## 07000400h) while POWCNT1 has it off read zero and ignore writes,
  ## keeping their contents: GBATEK "DS Power Control" ("(palette-) memory
  ## becomes read-only-zero-filled"), OAM and the kept contents from
  ## disp_powcnt in the reference runs (docs/oracles.md).
  (n.gpu.powcnt1 and (if (a and 0x400) == 0: 2'u16 else: 0x200'u16)) != 0

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

# --- ARM9 data cache contents (timing.nim DcLine) ------------------------

template dc_through(n: NDS; a: uint32): bool =
  ## This ARM9 data access goes through the data cache (DMA and code
  ## fetches never do; uncached regions and a disabled cache neither).
  not n.dma9.dma_access and n.tm.dc_on and n.tm.data_cachable(a)

template dc_hit(n: NDS; a: uint32; slot: int): bool =
  ## The access goes through the cache and finds the line under this very
  ## address: another mirror of the same RAM line is a different cache line
  ## (GBATEK "IsDebugger": its mirror probe "fails on ARM9 when cache is
  ## enabled"), so it misses and reaches memory.
  n.dc_through(a) and n.tm.dline[slot].tag1 == (a shr 5) + 1

template dc_slot1(n: NDS; line: int): int =
  ## The data-cache slot + 1 holding main RAM line `line`, or 0.
  int(n.tm.slot_of[line] and 0xFF)

template dc_apart(n: NDS; i: int): bool =
  ## Main RAM byte `i`'s line has a memory side apart from the CPU's copy.
  n.tm.page_apart[i shr 12] != 0 and n.dc_slot1(i shr 5) != 0 and
    n.tm.dline[n.dc_slot1(i shr 5) - 1].shadowed

# --- ARM9 instruction cache contents (timing.nim IcLine) ------------------

proc ic_keep(n: NDS; line: int) {.noinline.} =
  ## Memory under main RAM line `line` is about to change: every
  ## instruction-cache slot holding it keeps the line as it was filled.
  ## Exact: a line not kept yet still has in memory what its fill read,
  ## since every change to memory's side comes here first (write9,
  ## write7, a data-cache write-back), so copying it now copies the fill.
  let s = n.tm.icache.set_slots(uint32(line))
  for i in s ..< s + 4:
    if n.tm.iline[i].line1 == uint32(line + 1) and not n.tm.iline[i].kept:
      let slot = n.dc_slot1(line) - 1
      if slot >= 0 and n.tm.dline[slot].shadowed:
        n.tm.iline[i].code = n.tm.dline[slot].ram      # memory's side
      else:
        copyMem(addr n.tm.iline[i].code[0], addr n.main_ram[line * 32], 32)
      n.tm.iline[i].kept = true
      n.page_apart_now(line shr 7)
      inc n.tm.page_apart[line shr 7]
      inc n.idle_epoch

proc ic_drop(n: NDS; slot: int) =
  ## The line leaves the instruction cache (tags are the caller's).
  let line1 = n.tm.iline[slot].line1
  if line1 != 0:
    n.tm.slot_of[line1 - 1] -= IC_ONE
    if n.tm.iline[slot].kept: dec n.tm.page_apart[int(line1 - 1) shr 7]
  n.tm.iline[slot].line1 = 0
  n.tm.iline[slot].kept = false

proc ic_invalidate_all(n: NDS) =
  for slot in 0 ..< n.tm.iline.len: n.ic_drop(slot)
  n.tm.icache.invalidate()

proc dc_shadow(n: NDS; slot: int) =
  ## Keep the memory side of a cached line apart from the CPU's copy.
  if not n.tm.dline[slot].shadowed:
    copyMem(addr n.tm.dline[slot].ram[0],
            addr n.main_ram[int(n.tm.dline[slot].line1 - 1) * 32], 32)
    n.tm.dline[slot].shadowed = true
    inc n.tm.shadows
    n.page_apart_now(int(n.tm.dline[slot].line1 - 1) shr 7)
    inc n.tm.page_apart[int(n.tm.dline[slot].line1 - 1) shr 7]

proc dc_drop(n: NDS; slot: int; write_back: bool) =
  ## The line leaves the data cache. Written back (eviction, clean and
  ## invalidate) a dirty line's CPU copy becomes memory; otherwise memory's
  ## side wins and the CPU's unwritten stores are lost (invalidate).
  let line1 = n.tm.dline[slot].line1
  if line1 == 0: return
  if write_back and n.tm.dline[slot].dirty and n.tm.slot_of[line1 - 1] >= IC_ONE:
    n.ic_keep(int(line1 - 1))   # the CPU's copy reaches memory
  if n.tm.dline[slot].shadowed:
    if not (write_back and n.tm.dline[slot].dirty):
      copyMem(addr n.main_ram[int(line1 - 1) * 32], addr n.tm.dline[slot].ram[0], 32)
    dec n.tm.shadows
    dec n.tm.page_apart[int(line1 - 1) shr 7]
  n.tm.slot_of[line1 - 1] = n.tm.slot_of[line1 - 1] and 0xFF00'u16
  n.tm.dline[slot] = DcLine()

proc dc_clean(n: NDS; slot: int) =
  ## Write a dirty line back; it stays cached.
  if n.tm.dline[slot].dirty:
    let line = int(n.tm.dline[slot].line1 - 1)
    if n.tm.slot_of[line] >= IC_ONE: n.ic_keep(line)   # the CPU's copy reaches memory
    n.tm.dline[slot].dirty = false
    if n.tm.dline[slot].shadowed:
      n.tm.dline[slot].shadowed = false
      dec n.tm.shadows
      dec n.tm.page_apart[int(n.tm.dline[slot].line1 - 1) shr 7]

proc dc_fill(n: NDS; a: uint32) =
  ## A data-cache line fill replaced slot `dcache.victim` with `a`'s line.
  let slot = n.tm.dcache.victim
  n.dc_drop(slot, true)
  if (a shr 24) == 2:
    let line = (a and 0x3FFFFF) shr 5
    let other = n.dc_slot1(int(line))
    if other != 0:
      # the same RAM line cached under another mirror: one copy kept (Assumed)
      n.dc_drop(other - 1, true)
      n.tm.dcache.clear_slot(other - 1)
    n.tm.dline[slot].line1 = line + 1
    n.tm.dline[slot].tag1 = (a shr 5) + 1
    n.tm.slot_of[line] = (n.tm.slot_of[line] and 0xFF00'u16) or uint16(slot + 1)

proc dc_mem_read(n: NDS; i: int; width: static int): uint32 =
  ## Main RAM as memory holds it (other masters, uncached accesses, code).
  let slot = n.dc_slot1(i shr 5) - 1
  if slot >= 0 and n.tm.dline[slot].shadowed:
    let j = i and 31
    when width == 32:
      uint32(n.tm.dline[slot].ram[j]) or (uint32(n.tm.dline[slot].ram[j + 1]) shl 8) or
        (uint32(n.tm.dline[slot].ram[j + 2]) shl 16) or (uint32(n.tm.dline[slot].ram[j + 3]) shl 24)
    elif width == 16:
      uint32(n.tm.dline[slot].ram[j]) or (uint32(n.tm.dline[slot].ram[j + 1]) shl 8)
    else: uint32(n.tm.dline[slot].ram[j])
  else:
    when width == 32: rd32(n.main_ram, i)
    elif width == 16: rd16(n.main_ram, i)
    else: uint32(n.main_ram[i])

proc dc_write(n: NDS; i: int; v: uint32; width: static int; through, write_back: bool) =
  ## A store to a main RAM line the data cache holds. Through the cache:
  ## write-back marks the line dirty (memory keeps its old side),
  ## write-through updates both sides. Past the cache (DMA, the ARM7, an
  ## uncached mirror, the cache off): memory's side only -- the CPU keeps
  ## reading its stale copy until the line is invalidated or evicted.
  let slot = n.dc_slot1(i shr 5) - 1
  template put(p: ptr UncheckedArray[uint8]) =
    p[0] = uint8(v)
    when width >= 16: p[1] = uint8(v shr 8)
    when width == 32:
      p[2] = uint8(v shr 16); p[3] = uint8(v shr 24)
  let cpu = cast[ptr UncheckedArray[uint8]](addr n.main_ram[i])
  if through:
    if write_back or n.tm.dline[slot].dirty:
      if not n.tm.dline[slot].dirty:
        n.dc_shadow(slot)
        n.tm.dline[slot].dirty = true
      put(cpu)
    else:
      put(cpu)
      if n.tm.dline[slot].shadowed:
        put(cast[ptr UncheckedArray[uint8]](addr n.tm.dline[slot].ram[i and 31]))
  else:
    n.dc_shadow(slot)
    put(cast[ptr UncheckedArray[uint8]](addr n.tm.dline[slot].ram[i and 31]))

proc dc_invalidate_all(n: NDS) =
  for slot in 0 ..< n.tm.dline.len: n.dc_drop(slot, false)
  n.tm.dcache.invalidate()

proc charge9(n: NDS; a: uint32; width: static int; write: bool) {.inline.} =
  ## Charge a CPU data access outside the TCMs (timing.nim); DMA's own
  ## accesses are not charged.
  if n.dma9.dma_access: return
  let seq = a == n.last_data9 + (when width == 32: 4'u32 else: 2'u32)
  n.last_data9 = a
  let top = a shr 24
  if n.tm.dc_on and n.tm.data_cachable(a):
    if write:
      if not n.tm.dcache.lookup(a, false):
        n.wait9 += (if n.tm.data_buffered(a): WBUF_WRITE else: data9(top, width, seq, n.slot9_t))
    elif not n.tm.dcache.lookup(a, true):
      n.wait9 += (if top == 0xFF: FILL_BIOS else: FILL_MAIN)
      n.dc_fill(a)
      inc n.idle_epoch          # tags change, and an evicted dirty line reaches memory
    return
  if write and top == 2 and n.tm.data_buffered(a):
    n.wait9 += WBUF_WRITE
    return
  n.wait9 += data9(top, width, seq, n.slot9_t)

template charge9_tcm(n: NDS; a: uint32; itcm: bool) =
  ## DTCM data is free; ITCM data costs a cycle (GBATEK: no parallel access)
  n.last_data9 = a
  if itcm: n.wait9 += 1

proc pu_refuse9(n: NDS; a: uint32; kind: int; key: uint32): bool {.noinline.} =
  let priv = (key and 0x8000_0000'u32) == 0
  let need = case kind
             of 2: (if priv: PERM_PRIV_W else: PERM_USER_W)
             else: (if priv: PERM_PRIV_R else: PERM_USER_R)
  if n.tm.allowed(n.cp15, a, need, kind == 0):
    n.pu_ok[kind] = key
    return false
  if n.dma9.dma_access: return false
  n.arm9.abort = if kind == 0: ABORT_PREFETCH else: ABORT_DATA
  true

template pu_check9(n: NDS; a: uint32; kind: static int): bool =
  ## The protection unit refuses the CPU's access (kind 0 fetch, 1 read,
  ## 2 write): flag the abort (the CPU takes it after the opcode,
  ## arm/cpu.nim). DMA is not checked. The last 4 KB page allowed per kind
  ## and privilege is remembered (cleared by CP15 writes). For speed, data
  ## accesses to main RAM and DTCM are not checked (read9/write9): what
  ## the sweep needed is ITCM (null pointers land there under libnds,
  ## which leaves 0-0x01FFFFFF outside every region) and the unmapped and
  ## I/O space; a guard region inside main RAM (the SDK's 0x023E0000 one)
  ## does not abort.
  let user = (n.arm9.cpsr and 0x1F) == 0x10 and not n.arm9.bank_xfer
  let key = (a shr 12) or (if user: 0x8000_0000'u32 else: 0'u32)
  if likely(key == n.pu_ok[kind]): false
  else: n.pu_refuse9(a, kind, key)

# --- ARM9 data TLB ----------------------------------------------------------
#
# Most ARM9 data accesses go to DTCM or to main RAM through the data cache
# (SoulSilver's overworld: 33 M of 47 M in 600 frames). What the general
# path decides for them depends on the page alone -- the TCM windows, the
# load modes, the data cache's enable and the page's cachability, all CP15
# state -- and, for main RAM, on the line: a tag hit costs nothing and
# reads or writes the CPU's copy in `main_ram` (`dc_hit`: a hit is the line
# under this very address, so `dc_apart` does not matter), a store into a
# hit dirty line just stores. So a page is entered in the TLB (`rtlb9` for
# loads, `wtlb9` for stores: load mode splits them) when the general path
# finds it DTCM or cached main RAM, and `read32` .. `write32` take the
# short path for it: DTCM always, main RAM on a tag hit (a dirty one for a
# store); everything else, misses included, goes the general way, which
# does the lookup, fill and charges itself. The CPU's accesses only: DMA
# goes through `Dma9Bus` (TCMs invisible, nothing charged). The entries
# follow CP15 state only, so they are dropped by a CP15 write that changes
# the TCMs, the protection unit's regions, the cache enables or
# cachability (`cp15_write`), WRAMCNT and a state load (`fetch_paths_off`);
# line state (fills, evictions, C7 clean / invalidate, DMA and the ARM7
# writing behind the cache) is checked at every access.

proc dtlb_fill9(n: NDS; a: uint32; write: bool; kind: uint32) =
  ## Enter `a`'s page, found DTCM or cached main RAM by the general path.
  ## TCM windows and protection regions are 4 KB multiples, so the page is
  ## all one or the other. (DTCM may lie over main RAM's addresses.)
  var e = DtlbEntry(tag: a shr 12, kind: kind)
  if kind == DT_DTCM:
    e.base = cast[ptr UncheckedArray[uint8]](addr n.dtcm[int((a - n.cp15.dtcm_base) and 0x3000)])
  else:
    e.base = cast[ptr UncheckedArray[uint8]](addr n.main_ram[int(a and 0x3FF000)])
  let i = int((a shr 12) and (DTLB_SIZE - 1))
  let li = uint16(i) or (if write: 0x8000'u16 else: 0'u16)
  if kind == DT_MAIN or (kind != DT_DTCM and n.tm.data_cachable(a)):
    if n.dtlb_dlogged < DTLB_LOG: n.dtlb_dlog[n.dtlb_dlogged] = li
    inc n.dtlb_dlogged
  else:
    if n.dtlb_logged < DTLB_LOG: n.dtlb_log[n.dtlb_logged] = li
    inc n.dtlb_logged
  if write: n.wtlb9[i] = e
  else: n.rtlb9[i] = e

template dtlb_hit9(n: NDS; a: uint32): bool =
  ## A data-cache hit on main RAM address `a` (`lookup` without allocating:
  ## a hit makes the line `last`, as the general path's lookup would).
  (a shr 5) + 1 == n.tm.dcache.last or n.tm.dcache.hit_line(a)

proc read9(n: NDS; a: uint32; width: static int; timed: static bool = false;
           cpu: static bool = false): uint32 =
  ## `timed`: a CPU or DMA access (charged, protection-checked); `cpu`: the
  ## CPU's own, which may enter the page in the data TLB.
  template rd(s: seq[uint8]; i: int): uint32 =
    when width == 32: rd32(s, i)
    elif width == 16: rd16(s, i)
    else: uint32(s[i])
  if n.in_itcm(a, false):
    when timed:
      if n.pu_check9(a, 1): return 0
      n.charge9_tcm(a, true)
    return rd(n.itcm, int(a and 0x7FFF))
  if n.in_dtcm(a, false):
    when cpu: n.dtlb_fill9(a, false, DT_DTCM)
    when timed: n.charge9_tcm(a, false)
    return rd(n.dtcm, int((a - n.cp15.dtcm_base) and 0x3FFF))
  when timed:
    if (a shr 24) != 0x02 and n.pu_check9(a, 1): return 0
    n.charge9(a, width, false)
  case a shr 24
  of 0x02:
    when cpu:
      if n.tm.dc_on and n.tm.data_cachable(a): n.dtlb_fill9(a, false, DT_MAIN)
      elif n.tm.page_apart[(a and 0x3FFFFF) shr 12] == 0: n.dtlb_fill9(a, false, DT_UNC)
    let i = int(a and 0x3FFFFF)
    if unlikely(n.dc_apart(i)) and not n.dc_hit(a, n.dc_slot1(i shr 5) - 1):
      n.dc_mem_read(i, width)
    else: rd(n.main_ram, i)
  of 0x03:
    var ok: bool
    let i = n.shared_wram9(a, ok)
    if ok: rd(n.shared_wram, i) else: 0'u32
  of 0x04:
    n.sync9()
    n.arm9.attn = true          # a read side effect may raise an IRQ (arm/cpu.nim run)
    when cpu: n.dev9 = true     # a device: what an event may change (arm/cpu.nim loop_edge)
    let w = n.io9_read(a and not 3'u32)
    let o = a and 0x00FF_FFFC'u32
    if not io9_steady(o):
      # the IPC FIFO pop is seen by the ARM7 too; the rest only by this CPU
      if o == 0x10_0000: inc n.idle_epoch else: inc n.idle_epoch9
    when defined(ndsdebug):
      if n.iolog: n.log_io("9", a, w, 0xFFFF_FFFF'u32, false, n.arm9.cur_pc)
    when width == 32: w
    elif width == 16: (w shr ((a and 2) * 8)) and 0xFFFF
    else: (w shr ((a and 3) * 8)) and 0xFF
  of 0x05:
    when cpu: n.dev9 = true
    if not n.pal_oam_on(a): return 0
    let p = cast[ptr UncheckedArray[uint8]](addr n.gpu.palette[0])
    let i = int(a and 0x7FF)
    when width == 32: uint32(p[i]) or (uint32(p[i+1]) shl 8) or (uint32(p[i+2]) shl 16) or (uint32(p[i+3]) shl 24)
    elif width == 16: uint32(p[i]) or (uint32(p[i+1]) shl 8)
    else: uint32(p[i])
  of 0x06:
    when cpu: n.dev9 = true
    var off: int
    let r = arm9_region(a, off)
    when width == 32: n.gpu.vram.read32(r, off)
    elif width == 16: uint32(n.gpu.vram.read16(r, off))
    else: uint32(n.gpu.vram.read8(r, off))
  of 0x07:
    when cpu: n.dev9 = true
    if not n.pal_oam_on(a): return 0
    let p = cast[ptr UncheckedArray[uint8]](addr n.gpu.oam[0])
    let i = int(a and 0x7FF)
    when width == 32: uint32(p[i]) or (uint32(p[i+1]) shl 8) or (uint32(p[i+2]) shl 16) or (uint32(p[i+3]) shl 24)
    elif width == 16: uint32(p[i]) or (uint32(p[i+1]) shl 8)
    else: uint32(p[i])
  of 0x08, 0x09, 0x0A:
    when cpu: n.dev9 = true
    n.slot2_read(a, true, width)
  of 0xFF:
    if a >= 0xFFFF0000'u32: rd(n.bios9, int(a and 0xFFF)) else: 0'u32
  else:
    n.note_unmapped("arm9", a, false)
    0'u32

proc write9(n: NDS; a: uint32; v: uint32; width: static int; timed: static bool = false;
            cpu: static bool = false) =
  watch_write(n, "9", n.arm9, a, v)
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
  if n.in_itcm(a, true):
    when timed:
      if n.pu_check9(a, 2): return
      n.charge9_tcm(a, true)
    wr(n.itcm, int(a and 0x7FFF), n.idle_epoch9); return
  if n.in_dtcm(a, true):
    when cpu: n.dtlb_fill9(a, true, DT_DTCM)
    when timed: n.charge9_tcm(a, false)
    wr(n.dtcm, int((a - n.cp15.dtcm_base) and 0x3FFF), n.idle_epoch9); return
  when timed:
    if (a shr 24) != 0x02 and n.pu_check9(a, 2): return
    n.charge9(a, width, true)
  if (a shr 24) - 2 >= 2: inc n.idle_epoch   # I/O, VRAM, palette, OAM, slot 2
  case a shr 24
  of 0x02:
    when cpu:
      if n.tm.dc_on and n.tm.data_cachable(a): n.dtlb_fill9(a, true, DT_MAIN)
      else: n.dtlb_fill9(a, true, if n.tm.data_buffered(a): DT_UNC_BUF else: DT_UNC)
    let i = int(a and 0x3FFFFF)
    let held = n.tm.slot_of[i shr 5]
    let slot = int(held and 0xFF)
    if likely(held == 0) or (slot != 0 and n.tm.dline[slot - 1].dirty and n.dc_hit(a, slot - 1)):
      wr(n.main_ram, i)       # uncached, or a store into an already dirty line
    elif slot == 0:
      n.ic_keep(i shr 5)      # only the instruction cache holds the line
      wr(n.main_ram, i)
    else:
      let through = n.dc_hit(a, slot - 1)
      let write_back = n.tm.data_buffered(a)
      # all but a store into the CPU's copy of a write-back line reach memory
      if held >= IC_ONE and not (through and write_back): n.ic_keep(i shr 5)
      n.dc_write(i, v, width, through, write_back)
      inc n.idle_epoch          # a cached store: either side may change (perf.md)
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
      if n.iolog: n.log_io("9", a and not 3'u32, v shl sh, mask, true, n.arm9.cur_pc)
    n.arm9.attn = true          # IE/IF/IME, HALTCNT, DMA, ... (arm/cpu.nim run)
    n.io9_write(a and not 3'u32, v shl sh, mask)
  of 0x05, 0x07:
    when width != 8:
      if not n.pal_oam_on(a): return
      let p = cast[ptr UncheckedArray[uint8]](
        if (a shr 24) == 5: addr n.gpu.palette[0] else: addr n.gpu.oam[0])
      let i = int(a and 0x7FF)
      # a change is seen by the engine owning this half (line reuse,
      # engine2d.nim): a palette change by all its lines, an OAM change by
      # the lines of the OBJs it moves
      let e {.cursor.} = if (a and 0x400) == 0: n.gpu.engine_a else: n.gpu.engine_b
      let q = addr p[i]
      if (a shr 24) == 7:
        e.oam_store((i and 0x3FF) shr 1, uint16(v))
        when width == 32: e.oam_store(((i and 0x3FF) shr 1) + 1, uint16(v shr 16))
      else:
        when width == 32:
          if cast[ptr uint32](q)[] != v:
            cast[ptr uint32](q)[] = v
            inc e.mem_gen
        else:
          if cast[ptr uint16](q)[] != uint16(v):
            cast[ptr uint16](q)[] = uint16(v)
            inc e.mem_gen
  of 0x06:
    when width != 8:
      var off: int
      let r = arm9_region(a, off)
      when width == 32: n.gpu.vram.write32(r, off, v)
      else: n.gpu.vram.write16(r, off, uint16(v))
  of 0x08, 0x09, 0x0A: n.slot2_write(a, v, true, width)
  else: n.note_unmapped("arm9", a, true)

proc ic_fill(n: NDS; a: uint32) =
  ## An instruction-cache line fill replaced slot `icache.victim` with
  ## `a`'s line (fetch_cost9, C7,C13,1 prefetch).
  let slot = n.tm.icache.victim
  n.ic_drop(slot)
  case a shr 24
  of 0x02:
    let line = (a and 0x3FFFFF) shr 5
    n.tm.iline[slot].line1 = line + 1
    n.tm.slot_of[line] += IC_ONE
  of 0x03, 0x05, 0x06, 0x07:
    # writable memory no store path watches: copy the line now, as a
    # fetch would read it
    let base = a and not 31'u32
    for k in 0'u32 .. 7:
      let w = n.read9(base + 4 * k, 32)
      for j in 0'u32 .. 3: n.tm.iline[slot].code[4 * k + j] = uint8(w shr (8 * j))
    n.tm.iline[slot].kept = true
  else: discard               # BIOS (read-only), I/O and the GBA slot: read live

proc ic_code(n: NDS; a: uint32; width: static int): uint32 {.noinline.} =
  ## A fetch the instruction cache may answer from a kept line; else
  ## memory's side (main RAM: what the data cache keeps apart).
  if n.tm.ic_on and n.tm.code_cachable(a):
    let slot = n.tm.icache.find_slot(a)
    if slot >= 0 and n.tm.iline[slot].kept:
      let j = int(a and 31)
      template c: untyped = n.tm.iline[slot].code
      when width == 32:
        return uint32(c[j]) or (uint32(c[j + 1]) shl 8) or
               (uint32(c[j + 2]) shl 16) or (uint32(c[j + 3]) shl 24)
      else:
        return uint32(c[j]) or (uint32(c[j + 1]) shl 8)
  if (a shr 24) == 0x02: n.dc_mem_read(int(a and 0x3FFFFF), width)
  else: n.read9(a, width)

# --- CPU mixins --------------------------------------------------------

proc fetch_cost9(n: NDS; a: uint32; size: static uint32): bool {.inline.} =
  ## One opcode fetch: always a nonsequential 32-bit access; a Thumb pair
  ## shares it. ITCM and I-cache hits fit in the instruction's own cycle.
  ## Any jump pays the refill, also one back into the word just fetched (a
  ## two-opcode Thumb loop, "B ." in ARM): GBATEK's WaitByLoop table, 4
  ## ARM9 cycles per SUB/BGT pass with the BIOS cached, takes it.
  ## True when the protection unit refuses the fetch: it sees a branch
  ## target or the first word of a 4 KB page; a run of sequential fetches
  ## inside a page (or a mode change without a branch, e.g. MSR to User) is
  ## not re-checked.
  n.last_data9 = NO_ADDR
  let w = a and not 3'u32
  let sequential = a == n.last_pc9 + size
  # a backward branch's target: a loop head (arm/cpu.nim loop_edge)
  if not sequential and a <= n.last_pc9:
    if n.arm9.wl_cold > 0: dec n.arm9.wl_cold
    elif n.arm9.wl_on: n.arm9.loop_edge()
  n.last_pc9 = a
  if sequential and w == n.last_fetch9: return false
  var c = 0'i64
  if not sequential or (w and 0xFFF'u32) == 0:
    if not sequential: c = BRANCH9
    if n.pu_check9(a, 0):
      n.last_fetch9 = NO_ADDR
      return true
  n.last_fetch9 = w
  if n.cp15.itcm_enabled and a < n.cp15.itcm_size: discard
  elif n.tm.ic_on and n.tm.code_cachable(a):
    if not n.tm.icache.lookup(a, true):
      c += (if (a shr 24) == 0xFF: FILL_BIOS else: FILL_MAIN)
      n.ic_fill(a)
      inc n.idle_epoch9         # a line fill changes the tags
  else:
    c += code9_uncached(a shr 24, n.slot9_t)
  n.wait9 += c

template dtlb_read9(n: NDS; a: uint32; T: typedesc) =
  ## The data TLB's load: DTCM, or cached main RAM on a tag hit, is free
  ## and reads the page (charge9_tcm / charge9 + read9 there); uncached main
  ## RAM (a page with nothing apart) pays the uncached charge and reads
  ## memory as it is.
  when not defined(ndsdebug):
    let e = addr n.rtlb9[int((a shr 12) and (DTLB_SIZE - 1))]
    if likely(e.tag == a shr 12):
      let p = cast[ptr T](addr e.base[a and 0xFFF])
      if e.kind == DT_DTCM or (e.kind == DT_MAIN and n.dtlb_hit9(a)):
        n.last_data9 = a
        return uint32(p[])
      if e.kind >= DT_UNC:
        let seq = a == n.last_data9 + (when sizeof(T) == 4: 4'u32 else: 2'u32)
        n.last_data9 = a
        n.wait9 += data9(0x02, sizeof(T) * 8, seq, n.slot9_t)
        return uint32(p[])

template dtlb_write9(n: NDS; a: uint32; v: typed; T: typedesc) =
  ## The data TLB's store: DTCM, or a tag hit on a dirty line of cached
  ## main RAM (write9's plain store; the hit makes the line `last`), costs
  ## nothing; uncached main RAM on a line no cache holds pays the uncached
  ## (or write-buffered) charge and stores. Only a change can end a polling
  ## loop. Not with -d:ndsdebug (write9 logs watched words).
  when not defined(ndsdebug):
    let e = addr n.wtlb9[int((a shr 12) and (DTLB_SIZE - 1))]
    if likely(e.tag == a shr 12):
      let p = cast[ptr T](addr e.base[a and 0xFFF])
      if e.kind == DT_DTCM:
        n.sched.now = n.arm9.cycles       # sync9
        n.last_data9 = a
        if p[] != v:
          inc n.idle_epoch9
          p[] = v
        return
      let held = n.tm.slot_of[int((a and 0x3FFFFF) shr 5)]
      let ds = int(held and 0xFF)
      if (e.kind == DT_MAIN and ds != 0 and n.tm.dline[ds - 1].tag1 == (a shr 5) + 1 and
          n.tm.dline[ds - 1].dirty) or (e.kind >= DT_UNC and held == 0):
        if e.kind == DT_MAIN: n.tm.dcache.last = (a shr 5) + 1
        else:
          let seq = a == n.last_data9 + (when sizeof(T) == 4: 4'u32 else: 2'u32)
          n.wait9 += (if e.kind == DT_UNC_BUF: WBUF_WRITE else: data9(0x02, sizeof(T) * 8, seq, n.slot9_t))
        n.sched.now = n.arm9.cycles
        n.last_data9 = a
        if p[] != v:
          inc n.idle_epoch
          p[] = v
        return

proc read8*(b: Arm9Bus; a: uint32): uint32 {.inline.} =
  let n {.cursor.} = b.nds
  n.dtlb_read9(a, uint8)
  n.read9(a, 8, true, true)
proc read16*(b: Arm9Bus; a: uint32): uint32 {.inline.} =
  let n {.cursor.} = b.nds
  n.dtlb_read9(a, uint16)
  n.read9(a, 16, true, true)
proc read32*(b: Arm9Bus; a: uint32): uint32 {.inline.} =
  let n {.cursor.} = b.nds
  n.dtlb_read9(a, uint32)
  n.read9(a, 32, true, true)

proc write8*(b: Arm9Bus; a: uint32; v: uint8) {.inline.} =
  let n {.cursor.} = b.nds
  n.dtlb_write9(a, v, uint8)
  n.sync9()
  n.write9(a, uint32(v), 8, true, true)
proc write16*(b: Arm9Bus; a: uint32; v: uint16) {.inline.} =
  let n {.cursor.} = b.nds
  n.dtlb_write9(a, v, uint16)
  n.sync9()
  n.write9(a, uint32(v), 16, true, true)
proc write32*(b: Arm9Bus; a: uint32; v: uint32) {.inline.} =
  let n {.cursor.} = b.nds
  n.dtlb_write9(a, v, uint32)
  n.sync9()
  n.write9(a, v, 32, true, true)

# The ARM9 DMA's accesses: the general path, without the data TLB.
proc read16*(b: Dma9Bus; a: uint32): uint32 {.inline.} = b.nds.read9(a, 16, true)
proc read32*(b: Dma9Bus; a: uint32): uint32 {.inline.} = b.nds.read9(a, 32, true)
proc write16*(b: Dma9Bus; a: uint32; v: uint16) {.inline.} =
  b.nds.sync9()
  b.nds.write9(a, uint32(v), 16, true)
proc write32*(b: Dma9Bus; a: uint32; v: uint32) {.inline.} =
  b.nds.sync9()
  b.nds.write9(a, v, 32, true)

proc line_clean9(n: NDS; a: uint32): bool {.noinline.} =
  ## Main RAM line `a` (cached for code, the instruction cache holding it)
  ## is read from memory as it is: no kept copy in its instruction-cache
  ## slot, no memory side kept apart by the data cache (ic_code).
  let line = int((a and 0x3FFFFF) shr 5)
  let ds = n.dc_slot1(line)
  if ds != 0 and n.tm.dline[ds - 1].shadowed: return false
  let slot = n.tm.icache.find_slot(a)
  slot < 0 or not n.tm.iline[slot].kept

proc fetch_line9(n: NDS; a: uint32) =
  ## After a fetch from `a` that did not abort: when it was an ITCM fetch
  ## or an instruction-cache hit (the line is now `icache.last`) whose bytes
  ## are memory's (ITCM, the BIOS, a main RAM line with no kept copy and no
  ## memory side apart), the rest of the line is sequential fetches that
  ## cost nothing and change nothing but the trackers: `fetch32`/`fetch16`
  ## read them from `fptr9`.
  ## A CP15 write, WRAMCNT, a page going apart (page_apart_now) or a state
  ## load turns this off; line fills and tag changes only come from fetches
  ## outside the line, and C7 commands, which are CP15 writes.
  n.fline9 = NO_PAGE
  n.fitcm9 = n.cp15.itcm_enabled and a < n.cp15.itcm_size
  if n.fitcm9:
    n.fptr9 = cast[ptr UncheckedArray[uint8]](addr n.itcm[int(a and 0x7FE0)])
  elif n.tm.ic_on and n.tm.code_cachable(a):
    if (a shr 24) == 0x02:
      if n.tm.page_apart[(a and 0x3FFFFF) shr 12] != 0 and not n.line_clean9(a): return
      n.fptr9 = cast[ptr UncheckedArray[uint8]](addr n.main_ram[int(a and 0x3FFFE0)])
    elif a >= 0xFFFF0000'u32:
      n.fptr9 = cast[ptr UncheckedArray[uint8]](addr n.bios9[int(a and 0xFE0)])
    else: return
  else: return
  n.fline9 = a shr 5

proc fetch_slow9(n: NDS; a: uint32; size: static uint32): uint32 {.noinline.} =
  n.fline9 = NO_PAGE
  if n.fetch_cost9(a, size): return 0
  n.fetch_line9(a)
  template rd(s: seq[uint8]; i: int): uint32 =
    when size == 4: rd32(s, i) else: rd16(s, i)
  if n.cp15.itcm_enabled and a < n.cp15.itcm_size: return rd(n.itcm, int(a and 0x7FFF))
  if (a shr 24) == 0x02:
    # code reads memory, not the data cache, or a line the instruction
    # cache kept (either makes the page `apart`)
    if unlikely(n.tm.page_apart[(a and 0x3FFFFF) shr 12] != 0): return n.ic_code(a, int(size) * 8)
    return rd(n.main_ram, int(a and 0x3FFFFF))
  if a >= 0xFFFF0000'u32: return rd(n.bios9, int(a and 0xFFF))
  n.dev9 = true                 # code in shared WRAM or a device (VRAM, ...)
  n.ic_code(a, int(size) * 8)

template fetch_fast9(n: NDS; a: uint32; size: static uint32): bool =
  ## A sequential fetch inside the line `fetch_line9` set up: what
  ## fetch_cost9 would do there (no cost, no tag change, no protection
  ## check: not a branch target nor a page's first word).
  (a shr 5) == n.fline9 and a == n.last_pc9 + size

template fetch_next9(n: NDS; a: uint32; size: static uint32): bool =
  ## A sequential fetch into the next line of the same 4 KB page (same
  ## region): ITCM again, or an instruction-cache hit, which makes it
  ## `last`: what fetch_cost9 would do, at no cost, when the line is read
  ## from memory as it is (a page with nothing apart, or `line_clean9`). A
  ## miss leaves the tags alone and takes the slow path, as does a line
  ## apart (whose lookup then finds it `last`, as it would have).
  (a shr 5) == n.fline9 + 1 and a == n.last_pc9 + size and (a and 0xFFF'u32) != 0 and
    (n.fitcm9 or (n.tm.icache.hit_line(a) and
      ((a shr 24) != 0x02 or n.tm.page_apart[(a and 0x3FFFFF) shr 12] == 0 or n.line_clean9(a))))

template fetch_jump9(n: NDS; a: uint32): bool =
  ## A jump (not to the next opcode) inside the 4 KB page of the line
  ## `fetch_line9` set up, in the page the protection unit allowed last
  ## (`pu_check9`'s remembered page and privilege): fetch_cost9 there only
  ## calls the loop head, charges the refill and, for another line, does
  ## the tag lookup -- when that line is ITCM, or an instruction-cache hit
  ## (which makes it `last`; a miss changes nothing and goes the long way)
  ## whose bytes are memory's (as `fetch_next9`). The same line is ITCM or
  ## `last` already.
  (a shr 12) == (n.fline9 shr 7) and
    ((a shr 12) or (if (n.arm9.cpsr and 0x1F) == 0x10 and not n.arm9.bank_xfer: 0x8000_0000'u32
                    else: 0'u32)) == n.pu_ok[0] and
    ((a shr 5) == n.fline9 or n.fitcm9 or
     (n.tm.icache.hit_line(a) and
      ((a shr 24) != 0x02 or n.tm.page_apart[(a and 0x3FFFFF) shr 12] == 0 or n.line_clean9(a))))

template fetch_jumped9(n: NDS; a: uint32) =
  n.last_data9 = NO_ADDR
  if a <= n.last_pc9:           # a backward branch's target: a loop head
    if n.arm9.wl_cold > 0: dec n.arm9.wl_cold
    elif n.arm9.wl_on: n.arm9.loop_edge()
  n.last_pc9 = a
  n.last_fetch9 = a and not 3'u32
  n.wait9 += BRANCH9
  # the line's bytes: the page is one block on the host (ITCM, main RAM, BIOS)
  n.fptr9 = cast[ptr UncheckedArray[uint8]](cast[int](n.fptr9) +
                                            (int(a shr 5) - int(n.fline9)) * 32)
  n.fline9 = a shr 5

proc fetch32*(b: Arm9Bus; a: uint32): uint32 {.inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".} =
  let n {.cursor.} = b.nds
  if likely(n.fetch_fast9(a, 4)):
    n.last_data9 = NO_ADDR
    n.last_pc9 = a
    n.last_fetch9 = a
    return cast[ptr uint32](addr n.fptr9[a and 31])[]
  if n.fetch_next9(a, 4):
    n.fline9 = a shr 5
    n.fptr9 = cast[ptr UncheckedArray[uint8]](addr n.fptr9[32])
    n.last_data9 = NO_ADDR
    n.last_pc9 = a
    n.last_fetch9 = a
    return cast[ptr uint32](addr n.fptr9[0])[]
  if n.fetch_jump9(a):
    n.fetch_jumped9(a)
    return cast[ptr uint32](addr n.fptr9[a and 31])[]
  n.fetch_slow9(a, 4)

proc fetch16*(b: Arm9Bus; a: uint32): uint32 {.inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".} =
  let n {.cursor.} = b.nds
  if likely(n.fetch_fast9(a, 2)):
    n.last_data9 = NO_ADDR
    n.last_pc9 = a
    n.last_fetch9 = a and not 3'u32
    return uint32(cast[ptr uint16](addr n.fptr9[a and 31])[])
  if n.fetch_next9(a, 2):
    n.fline9 = a shr 5
    n.fptr9 = cast[ptr UncheckedArray[uint8]](addr n.fptr9[32])
    n.last_data9 = NO_ADDR
    n.last_pc9 = a
    n.last_fetch9 = a
    return uint32(cast[ptr uint16](addr n.fptr9[0])[])
  if n.fetch_jump9(a):
    n.fetch_jumped9(a)
    return uint32(cast[ptr uint16](addr n.fptr9[a and 31])[])
  n.fetch_slow9(a, 2)

proc irq_line*(b: Arm9Bus): bool {.inline.} = b.nds.irq9.line()
proc irq_wake*(b: Arm9Bus): bool {.inline.} =
  ## The ARM9 halts through CP15 (wait for interrupt), which only the IRQ
  ## line ends: unlike the ARM7's HALTCNT it needs IME=1 (GBATEK "Halt": the
  ## opcode hangs if IME=0). The CPSR I bit doesn't matter.
  b.nds.irq9.line()
proc access_cycles*(b: Arm9Bus): int64 {.inline.} =
  result = b.nds.wait9
  b.nds.wait9 = 0

proc cp15_read*(b: Arm9Bus; op1, cn, cm, op2: uint32): uint32 =
  b.nds.cp15.read(op1, cn, cm, op2)

proc cp15_write*(b: Arm9Bus; op1, cn, cm, op2, v: uint32) =
  let n {.cursor.} = b.nds
  inc n.idle_epoch    # incl. cache clean/invalidate, which the ARM7 can see in memory
  n.fline9 = NO_PAGE  # TCMs, cache enables and contents, instruction-cache tags
  template tables(c: Cp15): untyped =
    (c.dcache_cfg, c.icache_cfg, c.wbuf_cfg, c.data_perm, c.code_perm, c.prot_regions)
  let ctl_before = n.cp15.control
  let before = tables(n.cp15)
  let dc_before = n.tm.dc_on
  n.cp15.write(op1, cn, cm, op2, v)
  case cn
  of 1, 2, 3, 5, 6:
    # rewriting a value changes nothing, and a control write only the
    # enables (the BIOS toggles the PU thousands of times a frame in "The
    # Strongest Demo"; timing.nim update_control)
    if tables(n.cp15) != before:
      n.tm.update_regions(n.cp15)
      n.pu_ok = [NO_PAGE, NO_PAGE, NO_PAGE]
      n.dtlb_off()              # cachability
    elif n.cp15.control != ctl_before:
      n.tm.update_control(n.cp15)
      n.pu_ok = [NO_PAGE, NO_PAGE, NO_PAGE]
      # the data TLB: TCM enables and load modes (bits 16-19) move pages
      # between DTCM, ITCM and memory; the data cache's enable (the PU's
      # included) decides cached main RAM
      if ((n.cp15.control xor ctl_before) and 0xF_0000'u32) != 0: n.dtlb_off()
      elif n.tm.dc_on != dc_before: n.dtlb_dc_switched()
  of 9: n.dtlb_off()            # TCM windows
  of 7:
    # cache maintenance (GBATEK "ARM CP15 Cache Control"): C5 invalidate
    # the instruction cache, whole (op2 0) or the line at an address
    # (op2 1; by set/index, op2 2, is not an ARM9 command: ignored), C13,1
    # prefetch an instruction line; data-cache lines by address (op2 1) or
    # set/index (op2 2): C6 invalidate, C10 clean, C14 clean and invalidate
    template dslot(): int =
      (if op2 == 1: n.tm.dcache.find_slot(v) elif op2 == 2: n.tm.dcache.set_index_slot(v) else: -1)
    case cm
    of 5:
      if op2 == 0: n.ic_invalidate_all()
      elif op2 == 1:
        let slot = n.tm.icache.find_slot(v)
        if slot >= 0:
          n.ic_drop(slot)
          n.tm.icache.clear_slot(slot)
    of 13:
      # fills as a fetch would (Assumed: whatever control bit 12 says,
      # for an address the protection unit makes cachable; no cycles)
      if op2 == 1 and n.tm.pu_on and n.tm.code_cachable(v) and
         not n.tm.icache.lookup(v, true):
        n.ic_fill(v)
    of 6:
      if op2 == 0: n.dc_invalidate_all()
      elif op2 == 1:
        let slot = dslot()
        if slot >= 0:
          n.dc_drop(slot, false)
          n.tm.dcache.clear_slot(slot)
    of 10:
      let slot = dslot()
      if slot >= 0: n.dc_clean(slot)
    of 14:
      let slot = dslot()
      if slot >= 0:
        n.dc_drop(slot, true)
        n.tm.dcache.clear_slot(slot)
    else: discard
  else: discard
  n.arm9.vector_base = n.cp15.vector_base()
  n.arm9.no_load_interwork = (n.cp15.control and 0x8000) != 0
  if n.cp15.halt_request:
    n.cp15.halt_request = false
    n.arm9.halted = true

proc data_cached*(b: Arm9Bus; a: uint32): bool =
  ## The data cache is on and covers `a` (HLE BIOS: IsDebugger).
  b.nds.tm.dc_on and b.nds.tm.data_cachable(a)

proc swi_hook*(b: Arm9Bus; comment: uint32): bool =
  ## HLE BIOS: true = the SWI ran in Nim (hle_bios.nim), skip the vector.
  b.nds.hle_bios9 and b.nds.arm9.hle_swi(comment)

# The dispatch tables (arm/cpu.nim): after every mixin their handlers use.
dispatch_tables(Arm9Bus)
