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
  TagCache* = object
    tags: seq[uint32]       ## sets * 4: line number + 1 (0 = empty)
    rr: seq[uint8]          ## round-robin victim per set
    set_mask: uint32
    last*: uint32           ## line known resident (fast path), or 0

  MemTiming* = object
    icache*, dcache*: TagCache
    ic_on*, dc_on*: bool
    icode: array[256, bool]   ## cachable for code, by address top byte
    idata: array[256, bool]   ## cachable for data
    ibuf: array[256, bool]    ## write-buffered
    mcode: array[4096, bool]  ## the same at 4 KB grain over 0x02000000-0x02FFFFFF
    mdata: array[4096, bool]
    mbuf: array[4096, bool]

const
  NO_ADDR* = 0xFFFF_FFF0'u32  ## "no previous access"

  # ARM9 code fetch (N32 + its 3-cycle penalty, already in GBATEK's table),
  # master cycles by address top byte
  CODE9_MAIN* = 18'i64
  CODE9_FAST* = 8'i64         ## WRAM, BIOS, I/O, OAM
  CODE9_VRAM* = 10'i64
  CODE9_GBA* = 38'i64
  FILL_MAIN* = 46'i64         ## cache line fill from main RAM
  FILL_BIOS* = 22'i64
  BRANCH9* = 2'i64
  WBUF_WRITE* = 2'i64

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

proc lookup*(c: var TagCache; a: uint32; allocate: bool): bool =
  ## Hit? On a miss with `allocate`, the line is filled (round robin).
  let tag = (a shr 5) + 1
  if tag == c.last: return true
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

proc update_regions*(t: var MemTiming; cp: Cp15) =
  ## Recompute cachability after a CP15 write (c1, c2, c3, c6).
  let pu = (cp.control and 1) != 0
  t.ic_on = pu and (cp.control and (1'u32 shl 12)) != 0
  t.dc_on = pu and (cp.control and (1'u32 shl 2)) != 0
  template classify(a: uint32; code, data, buf: var bool) =
    let r = cp.region_of(a)
    code = r >= 0 and ((cp.icache_cfg shr r) and 1) != 0
    data = r >= 0 and ((cp.dcache_cfg shr r) and 1) != 0
    buf = r >= 0 and ((cp.wbuf_cfg shr r) and 1) != 0
  for top in 0 ..< 256:
    let a = if top == 0xFF: 0xFFFF_0000'u32 else: uint32(top) shl 24
    classify(a, t.icode[top], t.idata[top], t.ibuf[top])
  for i in 0 ..< 4096:
    classify(0x0200_0000'u32 + (uint32(i) shl 12), t.mcode[i], t.mdata[i], t.mbuf[i])

template code_cachable*(t: MemTiming; a: uint32): bool =
  (if (a shr 24) == 2: t.mcode[(a shr 12) and 0xFFF] else: t.icode[a shr 24])
template data_cachable*(t: MemTiming; a: uint32): bool =
  (if (a shr 24) == 2: t.mdata[(a shr 12) and 0xFFF] else: t.idata[a shr 24])
template data_buffered*(t: MemTiming; a: uint32): bool =
  (if (a shr 24) == 2: t.mbuf[(a shr 12) and 0xFFF] else: t.ibuf[a shr 24])

proc code9_uncached*(top: uint32): int64 {.inline.} =
  case top
  of 0x02: CODE9_MAIN
  of 0x05, 0x06: CODE9_VRAM
  of 0x08, 0x09: CODE9_GBA
  else: CODE9_FAST

proc data9*(top: uint32; width: int; seq: bool): int64 {.inline.} =
  ## Uncached ARM9 data access (8-bit = 16-bit), master cycles.
  case top
  of 0x02:
    if width == 32: (if seq: 4 else: 20) else: (if seq: 2 else: 18)
  of 0x05, 0x06:
    if width == 32: (if seq: 4 else: 10) else: (if seq: 2 else: 8)
  of 0x08, 0x09:
    if width == 32: (if seq: 24 else: 38) else: (if seq: 12 else: 26)
  of 0x0A: (if seq: 20 else: 26)
  else: (if seq: 2 else: 8)

proc code7*(top: uint32; width: int; seq: bool): int64 {.inline.} =
  case top
  of 0x02:
    if width == 32: (if seq: 4 else: 18) else: (if seq: 2 else: 16)
  of 0x06: (if width == 32: 4 else: 2)
  of 0x08, 0x09:
    if width == 32: (if seq: 24 else: 32) else: (if seq: 12 else: 20)
  else: 2

proc data7*(top: uint32; width: int; seq: bool): int64 {.inline.} =
  case top
  of 0x02:
    if width == 32: (if seq: 4 else: 20) else: (if seq: 2 else: 18)
  of 0x06: (if width == 32 and seq: 4 else: 2)
  of 0x08, 0x09:
    if width == 32: (if seq: 24 else: 30) else: (if seq: 12 else: 18)
  of 0x0A: (if seq: 20 else: 18)
  else: 2
