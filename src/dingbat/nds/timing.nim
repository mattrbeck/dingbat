## CPU memory timing: what each code fetch and data access costs, in master
## cycles (the 67 MHz ARM9 clock; one bus cycle is two). GBATEK "DS Memory
## Timings" gives the tables, in bus cycles:
##
##   NDS7/CODE          N32 S32 N16 S16     NDS9/CODE          N32  N16
##   Main RAM            9   2   8   1      Main RAM (uncached)  9   4.5
##   WRAM,BIOS,I/O,OAM   1   1   1   1      WRAM,BIOS,I/O,OAM    4   2
##   VRAM,Palette        2   2   1   1      VRAM,Palette         5   2.5
##   GBA ROM            16  12  10   6      GBA ROM             19   9.5
##                                          TCM, cache hit      0.5 0.5
##   NDS7/DATA                              NDS9/DATA          N32 S32 N16 S16
##   Main RAM           10   2   9   1      Main RAM            10   2   9   1
##   WRAM,BIOS,I/O,OAM   1   1   1   1      WRAM,BIOS,I/O,OAM    4   1   4   1
##   VRAM,Palette        1   2   1   1      VRAM,Palette         5   2   4   1
##   GBA ROM            15  12   9   6      GBA ROM             19  12  13   6
##   GBA RAM             9  10   9  10      GBA RAM             13  10  13  10
##                                          cache miss: BIOS 11, Main RAM 23
##
## ARM9 opcode fetches are always nonsequential 32-bit (a Thumb pair shares
## one fetch); data may be sequential (LDM/STM/LDRD after the first word).
##
## The GBA-slot rows are for EXMEMCNT's default access times (ROM 10 + 6,
## SRAM 10); each CPU's own EXMEMCNT bits 0-4 pick them (GBATEK "DS Memory
## Control - Cartridges and Main RAM": 10/8/6/18 first, 6/4 second, SRAM
## 10/8/6/18), so the rows are formulas over SlotTiming: a halfword is the
## first (N) or second (S) access time, a word two halfwords, ARM9
## nonsequential accesses add the 3-cycle penalty and ARM7 nonsequential
## data is 1 cycle faster (both as the table shows). SRAM is an 8-bit bus
## with one access per load or store whatever its width (the table's N32 =
## N16 for GBA RAM).
##
## The ARM946E-S caches (GBATEK "DS Memory Control - Cache and TCM"): 8 KB
## instruction / 4 KB data, 4-way, 32-byte lines, read-allocate; whether a
## region is cached comes from the protection unit (CP15 c6 regions, c2
## cachable bits, control bits 0/2/12). Only the tags are modelled -- the
## data always comes from memory, so the model can only get timing wrong,
## never contents.
##
## Assumed, with no GBATEK figure: a code-cache line fill costs what the
## data-cache one does; a write to cached/buffered main RAM costs one bus
## cycle (the write buffer absorbs it); a branch on the ARM9 costs two
## extra cycles for the pipeline refill; the ARM7's refill is one extra
## sequential fetch at the target (ARM7TDMI: branch = 2S + 1N).

import arm/cp15

type
  SlotTiming* = object
    ## GBA-slot access times in bus cycles, from EXMEMCNT bits 0-4
    rom_n*, rom_s*, ram*: int64

  TagCache* = object
    tags: seq[uint32]       ## sets * 4: line number + 1 (0 = empty)
    rr: seq[uint8]          ## round-robin victim per set
    set_mask: uint32
    last*: uint32           ## line known resident (fast path), or 0

  MemTiming* = object
    icache*, dcache*: TagCache
    ic_on*, dc_on*: bool
    pu_on*: bool              ## protection unit enabled (control bit 0)
    icode: array[256, bool]   ## cachable for code, by address top byte
    idata: array[256, bool]   ## cachable for data
    ibuf: array[256, bool]    ## write-buffered
    mcode: array[4096, bool]  ## the same at 4 KB grain over 0x02000000-0x02FFFFFF
    mdata: array[4096, bool]
    mbuf: array[4096, bool]
    # protection unit access rights (PERM_* bits) for data and code, by
    # address top byte (PERM_MIXED: a region edge inside, ask perm_slow) and
    # at 4 KB grain over main RAM
    dperm, cperm: array[256, uint8]
    mdperm, mcperm: array[4096, uint8]

const
  NO_ADDR* = 0xFFFF_FFF0'u32  ## "no previous access"

  # ARM9 code fetch (N32 + its 3-cycle penalty, already in GBATEK's table),
  # master cycles by address top byte
  CODE9_MAIN* = 18'i64
  CODE9_FAST* = 8'i64         ## WRAM, BIOS, I/O, OAM
  CODE9_VRAM* = 10'i64
  FILL_MAIN* = 46'i64         ## cache line fill from main RAM
  FILL_BIOS* = 22'i64
  BRANCH9* = 2'i64
  WBUF_WRITE* = 2'i64

proc slot_timing*(exmem: uint16): SlotTiming =
  const first = [10'i64, 8, 6, 18]
  SlotTiming(ram: first[exmem and 3], rom_n: first[(exmem shr 2) and 3],
             rom_s: if (exmem and 0x10) != 0: 4 else: 6)

proc slot_rom(st: SlotTiming; width: int; seq: bool): int64 {.inline.} =
  ## bus cycles for one ROM-region access
  if width == 32: (if seq: 2 * st.rom_s else: st.rom_n + st.rom_s)
  else: (if seq: st.rom_s else: st.rom_n)

proc init_cache(c: var TagCache; size: int) =
  let sets = size div (32 * 4)
  c.tags = newSeq[uint32](sets * 4)
  c.rr = newSeq[uint8](sets)
  c.set_mask = uint32(sets - 1)
  c.last = 0

proc invalidate*(c: var TagCache) =
  for t in c.tags.mitems: t = 0
  c.last = 0

proc invalidate_line*(c: var TagCache; a: uint32) =
  let line = a shr 5
  let s = int(line and c.set_mask) * 4
  for i in 0..3:
    if c.tags[s + i] == line + 1: c.tags[s + i] = 0
  if c.last == line + 1: c.last = 0

proc lookup_slow(c: var TagCache; a: uint32; allocate: bool): bool {.noinline.} =
  let tag = (a shr 5) + 1
  let set = int((a shr 5) and c.set_mask)
  let s = set * 4
  if c.tags[s] == tag or c.tags[s + 1] == tag or c.tags[s + 2] == tag or
     c.tags[s + 3] == tag:
    c.last = tag
    return true
  if allocate:
    c.tags[s + int(c.rr[set])] = tag
    c.rr[set] = (c.rr[set] + 1) and 3
    c.last = tag
  false

template lookup*(c: var TagCache; a: uint32; allocate: bool): bool =
  ## Hit? On a miss with `allocate`, the line is filled (round robin). The
  ## line used last is checked inline.
  ((a shr 5) + 1 == c.last or c.lookup_slow(a, allocate))

proc init_timing*(t: var MemTiming) =
  t.icache.init_cache(8 * 1024)
  t.dcache.init_cache(4 * 1024)

proc region_of(cp: Cp15; a: uint32): int =
  ## Highest-numbered enabled protection region containing `a`, or -1.
  result = -1
  for i in countdown(7, 0):
    let r = cp.prot_regions[i]
    if (r and 1) == 0: continue
    let bits = ((r shr 1) and 0x1F) + 1
    let size = if bits >= 32: 0'u64 else: 1'u64 shl bits
    let base = r and 0xFFFF_F000'u32
    if size == 0 or (uint64(a) >= uint64(base) and uint64(a) < uint64(base) + size):
      return i

const
  PERM_PRIV_R* = 1'u8
  PERM_PRIV_W* = 2'u8
  PERM_USER_R* = 4'u8
  PERM_USER_W* = 8'u8
  PERM_ALL = 15'u8
  PERM_MIXED* = 0x80'u8

proc ap_bits(ap: uint32): uint8 =
  ## GBATEK "ARM CP15 Protection Unit": AP 1 = privileged R/W, 2 = + user R,
  ## 3 = R/W for both, 5 = privileged R, 6 = R for both; 0 and the reserved
  ## values grant nothing.
  case ap
  of 1: PERM_PRIV_R or PERM_PRIV_W
  of 2: PERM_PRIV_R or PERM_PRIV_W or PERM_USER_R
  of 3: PERM_ALL
  of 5: PERM_PRIV_R
  of 6: PERM_PRIV_R or PERM_USER_R
  else: 0

proc perm_slow*(cp: Cp15; a: uint32; code: bool): uint8 =
  ## Access rights at `a` with the unit on: those of the highest enabled
  ## region holding it; outside every region (the background region) none
  ## (GBATEK).
  let r = cp.region_of(a)
  if r < 0: return 0
  ap_bits(((if code: cp.code_perm else: cp.data_perm) shr (r * 4)) and 15)

proc perm_span(cp: Cp15; lo, hi: uint64; code: bool): uint8 =
  ## One PERM value if no enabled region starts or ends inside (lo, hi).
  for i in 0..7:
    let r = cp.prot_regions[i]
    if (r and 1) == 0: continue
    let bits = ((r shr 1) and 0x1F) + 1
    if bits >= 32: continue
    let base = uint64(r and 0xFFFF_F000'u32)
    let stop = base + (1'u64 shl bits)
    if (base > lo and base < hi) or (stop > lo and stop < hi): return PERM_MIXED
  cp.perm_slow(uint32(lo), code)

proc update_control*(t: var MemTiming; cp: Cp15) =
  ## A control register (c1) write: only the enables. The ARM9 BIOS turns
  ## the protection unit off and on around each pass of some of its loops
  ## (thousands of times a frame in "The Strongest Demo"), so this must
  ## not rebuild the tables.
  t.pu_on = (cp.control and 1) != 0
  t.ic_on = t.pu_on and (cp.control and (1'u32 shl 12)) != 0
  t.dc_on = t.pu_on and (cp.control and (1'u32 shl 2)) != 0

proc update_regions*(t: var MemTiming; cp: Cp15) =
  ## Recompute cachability and access rights after a CP15 write (c2, c3,
  ## c5, c6; c1 too, through update_control). The tables hold the values
  ## with the protection unit on; update_control switches it. Main RAM's
  ## 4 KB pages are painted region by region, lowest priority first,
  ## instead of asking region_of per page.
  t.update_control(cp)
  template classify(a: uint32; code, data, buf: var bool) =
    let r = cp.region_of(a)
    code = r >= 0 and ((cp.icache_cfg shr r) and 1) != 0
    data = r >= 0 and ((cp.dcache_cfg shr r) and 1) != 0
    buf = r >= 0 and ((cp.wbuf_cfg shr r) and 1) != 0
  for top in 0 ..< 256:
    let a = if top == 0xFF: 0xFFFF_0000'u32 else: uint32(top) shl 24
    classify(a, t.icode[top], t.idata[top], t.ibuf[top])
    let lo = uint64(top) shl 24
    t.dperm[top] = cp.perm_span(lo, lo + 0x100_0000, false)
    t.cperm[top] = cp.perm_span(lo, lo + 0x100_0000, true)
  var page_region: array[4096, int8]
  for p in page_region.mitems: p = -1
  for i in 0..7:
    let r = cp.prot_regions[i]
    if (r and 1) == 0: continue
    let bits = ((r shr 1) and 0x1F) + 1
    let base = uint64(r and 0xFFFF_F000'u32)
    let stop = if bits >= 32: 0x1_0000_0000'u64 else: base + (1'u64 shl bits)
    let lo = max(base, 0x0200_0000'u64)
    let hi = min(stop, 0x0300_0000'u64)
    if lo >= hi: continue
    for p in int((lo - 0x0200_0000'u64) shr 12) ..< int((hi - 0x0200_0000'u64) shr 12):
      page_region[p] = int8(i)
  var rd, rc: array[-1..7, uint8]          # rights per region (-1: background)
  for i in -1..7:
    if i < 0: rd[i] = 0; rc[i] = 0
    else:
      rd[i] = ap_bits((cp.data_perm shr (i * 4)) and 15)
      rc[i] = ap_bits((cp.code_perm shr (i * 4)) and 15)
  for p in 0 ..< 4096:
    let r = int(page_region[p])
    t.mcode[p] = r >= 0 and ((cp.icache_cfg shr r) and 1) != 0
    t.mdata[p] = r >= 0 and ((cp.dcache_cfg shr r) and 1) != 0
    t.mbuf[p] = r >= 0 and ((cp.wbuf_cfg shr r) and 1) != 0
    t.mdperm[p] = rd[r]
    t.mcperm[p] = rc[r]

proc allowed*(t: MemTiming; cp: Cp15; a: uint32; need: uint8; code: bool): bool {.inline.} =
  ## Does the protection unit let this access through? `need` is one PERM_*
  ## bit (privileged/user, read/write; code fetches are reads).
  if not t.pu_on: return true
  var p = if (a shr 24) == 2: (if code: t.mcperm[(a shr 12) and 0xFFF] else: t.mdperm[(a shr 12) and 0xFFF])
          elif code: t.cperm[a shr 24] else: t.dperm[a shr 24]
  if p == PERM_MIXED: p = cp.perm_slow(a, code)
  (p and need) != 0

template code_cachable*(t: MemTiming; a: uint32): bool =
  (if (a shr 24) == 2: t.mcode[(a shr 12) and 0xFFF] else: t.icode[a shr 24])
template data_cachable*(t: MemTiming; a: uint32): bool =
  (if (a shr 24) == 2: t.mdata[(a shr 12) and 0xFFF] else: t.idata[a shr 24])
template data_buffered*(t: MemTiming; a: uint32): bool =
  (if (a shr 24) == 2: t.mbuf[(a shr 12) and 0xFFF] else: t.ibuf[a shr 24])

proc code9_uncached*(top: uint32; st: SlotTiming): int64 {.inline.} =
  case top
  of 0x02: CODE9_MAIN
  of 0x05, 0x06: CODE9_VRAM
  of 0x08, 0x09: 2 * (slot_rom(st, 32, false) + 3)
  of 0x0A: 2 * (st.ram + 3)
  else: CODE9_FAST

proc data9*(top: uint32; width: int; seq: bool; st: SlotTiming): int64 {.inline.} =
  ## Uncached ARM9 data access (8-bit = 16-bit), master cycles.
  case top
  of 0x02:
    if width == 32: (if seq: 4 else: 20) else: (if seq: 2 else: 18)
  of 0x05, 0x06:
    if width == 32: (if seq: 4 else: 10) else: (if seq: 2 else: 8)
  of 0x08, 0x09: 2 * (slot_rom(st, width, seq) + (if seq: 0 else: 3))
  of 0x0A: 2 * (st.ram + (if seq: 0 else: 3))
  else: (if seq: 2 else: 8)

proc code7*(top: uint32; width: int; seq: bool; st: SlotTiming): int64 {.inline.} =
  case top
  of 0x02:
    if width == 32: (if seq: 4 else: 18) else: (if seq: 2 else: 16)
  of 0x06: (if width == 32: 4 else: 2)
  of 0x08, 0x09: 2 * slot_rom(st, width, seq)
  of 0x0A: 2 * st.ram
  else: 2

proc data7*(top: uint32; width: int; seq: bool; st: SlotTiming): int64 {.inline.} =
  case top
  of 0x02:
    if width == 32: (if seq: 4 else: 20) else: (if seq: 2 else: 18)
  of 0x06: (if width == 32 and seq: 4 else: 2)
  of 0x08, 0x09: 2 * (slot_rom(st, width, seq) - (if seq: 0 else: 1))
  of 0x0A: 2 * (st.ram - (if seq: 0 else: 1))
  else: 2
