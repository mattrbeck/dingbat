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
## The NDS9/DATA values are whole load/store times: a single LDR/STR's
## access overlaps the opcode's own cycle (arm/cpu.nim single_access,
## bus9.nim overlap9). ARM7 accesses to the wifi regions take WIFIWAITCNT's
## times (wifi7); an ARM7 opcode fetch after a data access is
## nonsequential (bus7.nim break_fetch7).
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
## cachable bits, control bits 0/2/12). The instruction cache holds code
## (`IcLine`, bus9.nim ic_*): a hit runs what the line was filled with,
## so code changed in memory behind it (DMA, the ARM7, a data store, an
## uncached mirror) runs stale until the line is invalidated (C7,C5,0 /
## C7,C5,1) or evicted. For main RAM the line's bytes are copied only when
## memory under it is about to change (`kept`); until then memory still
## holds what the fill read, so a fetch reads memory. Lines from shared
## WRAM, palette, VRAM and OAM are copied at the fill; the BIOS is
## read-only, and I/O and the GBA slot are read live (Assumed: nothing
## runs cached code from them). The data cache also keeps what it holds for main
## RAM (`DcLine`, used by bus9.nim): `main_ram` is what the ARM9 sees
## through the cache, and a cached line whose memory side differs -- a
## write-back line the CPU has written (dirty), or a line DMA, the ARM7 or
## an uncached access wrote behind the cache's back -- keeps the memory
## side in `ram`. Other masters, uncached accesses and code fetches read
## that, and so does an access through another mirror of the line (a
## different cache line, which misses); a RAM line is cached under one
## mirror at a time (filling another writes the first back: Assumed).
## Cleaning a dirty line or evicting it writes the CPU's copy back
## (the whole line: per-half dirty bits are not modelled, Assumed),
## invalidating it discards the CPU's copy (GBATEK "ARM CP15 Protection
## Unit" C3 write-back / write-through, "Cache Control" C7 clean and
## invalidate; the BlocksDS SDK test cache/data_cache_ops).
##
## Assumed, with no GBATEK figure: a code-cache line fill costs what the
## data-cache one does; a write to cached/buffered main RAM costs one bus
## cycle (the write buffer absorbs it); a branch on the ARM9 costs two
## extra cycles for the pipeline refill; the ARM7's refill is one extra
## sequential fetch at the target (ARM7TDMI: branch = 2S + 1N).

import arm/cp15

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: on.}

type
  SlotTiming* = object
    ## GBA-slot access times in bus cycles, from EXMEMCNT bits 0-4
    rom_n*, rom_s*, ram*: int64

  TagCache* = object
    tags: seq[uint32]       ## sets * 4: line number + 1 (0 = empty)
    rr: seq[uint8]          ## round-robin victim per set
    set_mask: uint32
    last*: uint32           ## line known resident (fast path), or 0
    victim*: int            ## slot (set * 4 + way) the last fill replaced

  DcLine* = object
    ## A data-cache slot holding a main RAM line (bus9.nim dc_*)
    line1*: uint32          ## main RAM line index + 1 (0 = none)
    tag1*: uint32           ## the address line it is cached under + 1 (a mirror)
    dirty*: bool            ## written by the CPU in write-back mode
    shadowed*: bool         ## `ram` holds the memory side
    ram*: array[32, uint8]

  IcLine* = object
    ## An instruction-cache slot's contents (bus9.nim ic_*)
    line1*: uint32          ## main RAM line index + 1 (0 = none, or another region)
    kept*: bool             ## `code` holds the line as filled (memory has
                            ## changed since, or it was copied at the fill)
    code*: array[32, uint8]

  MemTiming* = object
    icache*, dcache*: TagCache
    dline*: array[128, DcLine]  ## data cache contents for main RAM, by slot
    iline*: array[256, IcLine]  ## instruction cache contents, by slot
    slot_of*: seq[uint16]       ## per main RAM line: bits 0-7 its data-cache
                                ## slot + 1 (or 0), bits 8-15 how many
                                ## instruction-cache slots hold it (IC_ONE each)
    shadows*: int               ## data-cache slots with `shadowed` set
    page_apart*: array[1024, uint16]  ## per 4 KB page of main RAM: those
                                ## slots plus instruction-cache slots `kept`
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
  IC_ONE* = 0x100'u16         ## one instruction-cache holder in `slot_of`

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

proc slot_tag*(c: TagCache; i: int): uint32 {.inline.} = c.tags[i]   ## line + 1, 0 = empty

proc clear_slot*(c: var TagCache; i: int) =
  if c.last == c.tags[i]: c.last = 0
  c.tags[i] = 0

proc find_slot*(c: TagCache; a: uint32): int =
  ## The slot holding address `a`'s line, or -1.
  let tag = (a shr 5) + 1
  let s = int((a shr 5) and c.set_mask) * 4
  for i in 0..3:
    if c.tags[s + i] == tag: return s + i
  -1

proc set_index_slot*(c: TagCache; v: uint32): int =
  ## A set/index operand (C7 Cm,2): bits 31-30 the way, bits 5.. the set.
  int((v shr 5) and c.set_mask) * 4 + int(v shr 30)

proc set_slots*(c: TagCache; line: uint32): int {.inline.} =
  ## The first of the four slots of address line `line`'s set. Every
  ## mirror of a main RAM line falls in one set (mirrors are 4 MB apart,
  ## the set index is address bits 5 and up below 8 KB / 4).
  int(line and c.set_mask) * 4

proc lookup_slow(c: var TagCache; a: uint32; allocate: bool): bool {.noinline.} =
  let tag = (a shr 5) + 1
  let set = int((a shr 5) and c.set_mask)
  let s = set * 4
  if c.tags[s] == tag or c.tags[s + 1] == tag or c.tags[s + 2] == tag or
     c.tags[s + 3] == tag:
    c.last = tag
    return true
  if allocate:
    c.victim = s + int(c.rr[set])
    c.tags[c.victim] = tag
    c.rr[set] = (c.rr[set] + 1) and 3
    c.last = tag
  false

proc hit_line*(c: var TagCache; a: uint32): bool {.inline.} =
  ## `lookup` for a line known not to be `last`, without allocating: on a
  ## hit it becomes `last`; a miss changes nothing (the caller then does
  ## the full lookup).
  let tag = (a shr 5) + 1
  let s = int((a shr 5) and c.set_mask) * 4
  if c.tags[s] == tag or c.tags[s + 1] == tag or c.tags[s + 2] == tag or
     c.tags[s + 3] == tag:
    c.last = tag
    return true
  false

template lookup*(c: var TagCache; a: uint32; allocate: bool): bool =
  ## Hit? On a miss with `allocate`, the line is filled (round robin). The
  ## line used last is checked inline.
  ((a shr 5) + 1 == c.last or c.lookup_slow(a, allocate))

proc init_timing*(t: var MemTiming) =
  t.icache.init_cache(8 * 1024)
  t.dcache.init_cache(4 * 1024)
  t.slot_of = newSeq[uint16](4 * 1024 * 1024 div 32)

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

proc wifi7*(cnt: uint16; a: uint32; width: int; seq: bool): int64 {.inline.} =
  ## ARM7 data access to the wifi regions, master cycles: WIFIWAITCNT's
  ## times per halfword (GBATEK "DS Wifi Unused Registers", WIFIWAITCNT):
  ## WS0 (4800000h-4807FFFh, the RAM) N = 10/8/6/18, S = 6/4; WS1
  ## (4808000h-480FFFFh, the registers) N = 10/8/6/18, S = 10/4; a word is
  ## two halfwords. The reference core measures the same (arm7_timing rows
  ## 22-28, docs/nds/accuracy.md). Above 4810000h the WS bit (address bit
  ## 15) is Assumed to pick the same way.
  const first = [10'i64, 8, 6, 18]
  let ws1 = (a and 0x8000'u32) != 0
  let n = if ws1: first[(cnt shr 3) and 3] else: first[cnt and 3]
  let s = if ws1: (if (cnt and 0x20) != 0: 4'i64 else: 10)
          else: (if (cnt and 0x04) != 0: 4'i64 else: 6)
  let one = if seq: s else: n
  2 * (if width == 32: one + s else: one)

proc data7*(top: uint32; width: int; seq: bool; st: SlotTiming): int64 {.inline.} =
  case top
  of 0x02:
    if width == 32: (if seq: 4 else: 20) else: (if seq: 2 else: 18)
  of 0x06: (if width == 32 and seq: 4 else: 2)
  of 0x08, 0x09: 2 * (slot_rom(st, width, seq) - (if seq: 0 else: 1))
  of 0x0A: 2 * (st.ram - (if seq: 0 else: 1))
  else: 2

{.pop.}
