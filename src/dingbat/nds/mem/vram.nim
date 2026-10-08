## The nine VRAM banks (A-I, 656 KB) and their VRAMCNT_x mappings
## (0x4000240-0x4000249). Each mappable region is a table of 16 KB pages
## holding a bitmask of the banks mapped there: several banks on one page
## read OR'd together and a write lands in all of them (GBATEK, "DS Memory
## Control - VRAM"). Engines read through `view` + rd8/rd16/rd32; the CPUs
## through read*/write*.
##
## Fast path: next to each page's bank mask, `fast` holds a direct pointer
## to the page's bytes when exactly one bank is mapped there (or a shared
## zero page when none is), and nil when several banks overlap; only nil
## pages take the bank-mask loop. `wfast` is the same for writes, nil for
## unmapped pages too. Both are rebuilt with the masks on every VRAMCNT write.
##
## Line reuse (gpu/engine2d.nim): `vgen` counts, per 1 KB block of `mem`,
## the stores that changed a byte there, and `remap_gen` the remaps; a
## view given a `Touch` set marks every block it reads in it (`pbase`: each
## page's start in `mem`), so a line knows which blocks it depends on.

import std/bitops
import ../quirky

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: nds_quirky.}

const
  VRAM_TOTAL = 656 * 1024
  BLOCK_SHIFT = 10                     ## line reuse tracks 1 KB blocks
  ZERO_BASE = VRAM_TOTAL               ## the zero page's block: never changes
  VRAM_BLOCKS* = (VRAM_TOTAL shr BLOCK_SHIFT) + 1
  TOUCH_WORDS* = (VRAM_BLOCKS + 63) div 64
  TOUCH_ALL* = TOUCH_WORDS * 64 - 1    ## marked when a read took the overlapping-banks path

type
  Touch* = array[TOUCH_WORDS, uint64]  ## a set of blocks (bit b: block b)

type
  VramBank* = enum vbA, vbB, vbC, vbD, vbE, vbF, vbG, vbH, vbI

  VramRegion* = enum
    vrLcdc        ## 0x06800000 plain bank view
    vrABg         ## 0x06000000, 512 KB
    vrAObj        ## 0x06400000, 256 KB
    vrBBg         ## 0x06200000, 128 KB
    vrBObj        ## 0x06600000, 128 KB
    vrArm7        ## ARM7 0x06000000, 256 KB
    vrTexture     ## 3D texture image slots, 512 KB
    vrTexPal      ## 3D texture palette slots, 96 KB (6 pages)
    vrABgExtPal   ## engine A BG extended palettes, 32 KB
    vrAObjExtPal  ## engine A OBJ extended palette, 8 KB (one page)
    vrBBgExtPal   ## engine B BG extended palettes, 32 KB
    vrBObjExtPal  ## engine B OBJ extended palette, 8 KB

  PagePtr* = ptr UncheckedArray[uint8]

  Vram* = ref object
    mem*: seq[uint8]                       ## all banks back to back
    cnt*: array[VramBank, uint8]
    pages: array[VramRegion, seq[uint16]]  ## bank bitmask per 16 KB page
    fast: array[VramRegion, seq[PagePtr]]  ## read pointer per page (see above)
    wfast: array[VramRegion, seq[PagePtr]] ## write pointer per page
    zero: seq[uint8]                       ## one page of zeros: unmapped reads
    vramstat*: uint8                       ## 0x4000240 read on ARM7: C/D as WRAM
    tex_gen*: uint64                       ## bumped by every remap and every write
                                           ## through the texture/palette slots (not saved)
    vgen*: array[VRAM_BLOCKS, uint32]      ## per 1 KB block of `mem`: stores that
                                           ## changed it (line reuse; not saved)
    remap_gen*: uint64                     ## remaps so far (not saved)
    pbase: array[VramRegion, seq[int32]]   ## per page: its first byte's index in
                                           ## `mem`, ZERO_BASE for the zero page,
                                           ## -1 where banks overlap

const
  PAGE_SHIFT = 14
  PAGE_SIZE = 1 shl PAGE_SHIFT
  BANK_SIZE*: array[VramBank, int] = [128 * 1024, 128 * 1024, 128 * 1024, 128 * 1024,
                                      64 * 1024, 16 * 1024, 16 * 1024, 32 * 1024, 16 * 1024]
  BANK_LCDC*: array[VramBank, uint32] = [0x06800000'u32, 0x06820000, 0x06840000, 0x06860000,
                                         0x06880000, 0x06890000, 0x06894000, 0x06898000, 0x068A0000]
  REGION_SIZE: array[VramRegion, int] = [656 * 1024, 512 * 1024, 256 * 1024, 128 * 1024,
                                         128 * 1024, 256 * 1024, 512 * 1024, 96 * 1024,
                                         32 * 1024, 16 * 1024, 32 * 1024, 16 * 1024]

proc bank_offsets(): array[VramBank, int] =
  var acc = 0
  for b in VramBank:
    result[b] = acc
    acc += BANK_SIZE[b]

const BANK_OFFSET*: array[VramBank, int] = bank_offsets()

template bank_offset(b: VramBank): int = BANK_OFFSET[b]

proc rebuild_fast(v: Vram)

proc new_vram*(): Vram =
  result = Vram(mem: newSeq[uint8](VRAM_TOTAL), zero: newSeq[uint8](PAGE_SIZE))
  for r in VramRegion:
    let n = REGION_SIZE[r] shr PAGE_SHIFT
    result.pages[r] = newSeq[uint16](n)
    result.fast[r] = newSeq[PagePtr](n)
    result.wfast[r] = newSeq[PagePtr](n)
    result.pbase[r] = newSeq[int32](n)
  result.rebuild_fast()
  # LCDC pages never change: bank b's LCDC window is fixed. (Present only
  # while the bank's MST is 0, so the mask is rebuilt in remap.)

proc map_bank(v: Vram; r: VramRegion; offset: int; b: VramBank) =
  let first = offset shr PAGE_SHIFT
  let n = max(1, BANK_SIZE[b] shr PAGE_SHIFT)
  for i in 0 ..< n:
    let p = first + i
    if p < v.pages[r].len:
      v.pages[r][p] = v.pages[r][p] or (1'u16 shl ord(b))

proc remap*(v: Vram) =
  ## Rebuild every region's page table from the nine VRAMCNT bytes.
  for r in VramRegion:
    for p in v.pages[r].mitems: p = 0
  v.vramstat = 0
  # A bank in a texture or texture-palette slot has no CPU address (GBATEK
  # "DS Memory Control - VRAM": MST 3; display capture writes only LCDC
  # banks), so its contents change only after a remap, or through writes to
  # the slot regions themselves (test harnesses): the 3D renderer reuses
  # its last frame while tex_gen stands (gpu3d.nim render_frame).
  inc v.tex_gen
  for b in VramBank:
    let c = v.cnt[b]
    if (c and 0x80) == 0: continue
    let mst = int(c and 7)
    let ofs = int((c shr 3) and 3)
    template fg_slot(): int = (ofs and 1) * 0x4000 + (ofs shr 1) * 0x10000
    case b
    of vbA, vbB, vbC, vbD:
      case mst
      of 0: v.map_bank(vrLcdc, int(BANK_LCDC[b] - 0x06800000'u32), b)
      of 1: v.map_bank(vrABg, ofs * 0x20000, b)
      of 2:
        if b in {vbA, vbB}: v.map_bank(vrAObj, (ofs and 1) * 0x20000, b)
        else:
          v.map_bank(vrArm7, (ofs and 1) * 0x20000, b)
          v.vramstat = v.vramstat or (if b == vbC: 1'u8 else: 2'u8)
      of 3: v.map_bank(vrTexture, ofs * 0x20000, b)
      of 4:
        if b == vbC: v.map_bank(vrBBg, 0, b)
        elif b == vbD: v.map_bank(vrBObj, 0, b)
      else: discard
    of vbE:
      case mst
      of 0: v.map_bank(vrLcdc, int(BANK_LCDC[b] - 0x06800000'u32), b)
      of 1: v.map_bank(vrABg, 0, b)
      of 2: v.map_bank(vrAObj, 0, b)
      of 3: v.map_bank(vrTexPal, 0, b)
      of 4: v.map_bank(vrABgExtPal, 0, b)
      else: discard
    of vbF, vbG:
      case mst
      of 0: v.map_bank(vrLcdc, int(BANK_LCDC[b] - 0x06800000'u32), b)
      of 1: v.map_bank(vrABg, fg_slot(), b)
      of 2: v.map_bank(vrAObj, fg_slot(), b)
      of 3: v.map_bank(vrTexPal, (ofs and 1) * 0x4000 + (ofs shr 1) * 0x10000, b)
      of 4: v.map_bank(vrABgExtPal, (ofs and 1) * 0x4000, b)
      of 5: v.map_bank(vrAObjExtPal, 0, b)
      else: discard
    of vbH:
      case mst
      of 0: v.map_bank(vrLcdc, int(BANK_LCDC[b] - 0x06800000'u32), b)
      of 1: v.map_bank(vrBBg, 0, b)
      of 2: v.map_bank(vrBBgExtPal, 0, b)
      else: discard
    of vbI:
      case mst
      of 0: v.map_bank(vrLcdc, int(BANK_LCDC[b] - 0x06800000'u32), b)
      of 1: v.map_bank(vrBBg, 0x8000, b)
      of 2: v.map_bank(vrBObj, 0, b)
      of 3: v.map_bank(vrBObjExtPal, 0, b)
      else: discard
  v.rebuild_fast()

proc write_cnt*(v: Vram; b: VramBank; value: uint8) =
  if v.cnt[b] == value: return
  v.cnt[b] = value
  v.remap()

proc locate(v: Vram; r: VramRegion; offset: int; b: VramBank): int {.inline.} =
  ## Byte index into `mem` of `offset` within region r for bank b.
  ## A bank smaller than a page (none are) or larger (A-D, E, H) repeats
  ## its pages; the offset within the bank is offset mod bank size.
  bank_offset(b) + (offset and (BANK_SIZE[b] - 1))

proc rebuild_fast(v: Vram) =
  let zp = cast[PagePtr](addr v.zero[0])
  inc v.remap_gen
  for r in VramRegion:
    for p in 0 ..< v.pages[r].len:
      let m = v.pages[r][p]
      if m == 0:
        v.fast[r][p] = zp
        v.wfast[r][p] = nil
        v.pbase[r][p] = ZERO_BASE
      elif (m and (m - 1)) == 0:
        var b = vbA
        while (m and (1'u16 shl ord(b))) == 0: inc b
        let i = v.locate(r, p shl PAGE_SHIFT, b)
        let q = cast[PagePtr](addr v.mem[i])
        v.fast[r][p] = q
        v.wfast[r][p] = q
        v.pbase[r][p] = int32(i)
      else:
        v.fast[r][p] = nil
        v.wfast[r][p] = nil
        v.pbase[r][p] = -1

proc read8*(v: Vram; r: VramRegion; offset: int): uint8 =
  let o = offset mod REGION_SIZE[r]
  let mask = v.pages[r][o shr PAGE_SHIFT]
  if mask == 0: return 0
  for b in VramBank:
    if (mask and (1'u16 shl ord(b))) != 0:
      result = result or v.mem[v.locate(r, o, b)]

proc read16*(v: Vram; r: VramRegion; offset: int): uint16 {.inline.} =
  let o = offset mod REGION_SIZE[r]
  let q = v.fast[r][o shr PAGE_SHIFT]
  if q != nil:
    let i = o and (PAGE_SIZE - 2)
    return uint16(q[i]) or (uint16(q[i + 1]) shl 8)
  let mask = v.pages[r][o shr PAGE_SHIFT]
  if mask == 0: return 0
  if (mask and (mask - 1)) == 0:
    # one bank: the common case
    for b in VramBank:
      if (mask and (1'u16 shl ord(b))) != 0:
        let i = v.locate(r, o, b)
        return uint16(v.mem[i]) or (uint16(v.mem[i + 1]) shl 8)
  for b in VramBank:
    if (mask and (1'u16 shl ord(b))) != 0:
      let i = v.locate(r, o, b)
      result = result or uint16(v.mem[i]) or (uint16(v.mem[i + 1]) shl 8)

proc read32*(v: Vram; r: VramRegion; offset: int): uint32 {.inline.} =
  uint32(v.read16(r, offset)) or (uint32(v.read16(r, offset + 2)) shl 16)

proc write8*(v: Vram; r: VramRegion; offset: int; value: uint8) =
  if r in {vrTexture, vrTexPal}: inc v.tex_gen
  let o = offset mod REGION_SIZE[r]
  let mask = v.pages[r][o shr PAGE_SHIFT]
  if mask == 0: return
  for b in VramBank:
    if (mask and (1'u16 shl ord(b))) != 0:
      let i = v.locate(r, o, b)
      if v.mem[i] != value:
        inc v.vgen[i shr BLOCK_SHIFT]
        v.mem[i] = value

proc write16*(v: Vram; r: VramRegion; offset: int; value: uint16) =
  if r in {vrTexture, vrTexPal}: inc v.tex_gen
  let o = offset mod REGION_SIZE[r]
  let q = v.wfast[r][o shr PAGE_SHIFT]
  if q != nil:
    let p = cast[ptr uint16](addr q[o and (PAGE_SIZE - 2)])
    if p[] != value:
      inc v.vgen[(int(v.pbase[r][o shr PAGE_SHIFT]) + (o and (PAGE_SIZE - 2))) shr BLOCK_SHIFT]
      p[] = value
    return
  v.write8(r, offset, uint8(value))
  v.write8(r, offset + 1, uint8(value shr 8))

proc write32*(v: Vram; r: VramRegion; offset: int; value: uint32) =
  v.write16(r, offset, uint16(value))
  v.write16(r, offset + 2, uint16(value shr 16))

proc arm9_region*(a: uint32; offset: var int): VramRegion =
  ## The region an ARM9 address in 0x06000000-0x06FFFFFF hits.
  case (a shr 20) and 0xE
  of 0x0: offset = int(a and 0x7FFFF); vrABg
  of 0x2: offset = int(a and 0x1FFFF); vrBBg
  of 0x4: offset = int(a and 0x3FFFF); vrAObj
  of 0x6: offset = int(a and 0x1FFFF); vrBObj
  else:   offset = int(a and 0xFFFFF) mod (656 * 1024); vrLcdc

proc page_banks*(v: Vram; r: VramRegion; page: int): uint16 {.inline.} =
  ## Bitmask of the banks mapped at 16 KB page `page` of region r (the 3D
  ## renderer builds its texture/palette page tables from this per frame).
  v.pages[r][page]

proc bank_ptr*(v: Vram; b: VramBank): ptr UncheckedArray[uint8] =
  ## Raw bank memory (display capture, VRAM display mode).
  cast[ptr UncheckedArray[uint8]](addr v.mem[bank_offset(b)])

# ---------------------------------------------------------------------------
# Renderer access: a view of one power-of-two region, read through the page
# pointers (rd8/rd16/rd32 wrap the offset within the region, as the engines'
# address counters do).

type
  RegionView* = object
    pages*: ptr UncheckedArray[PagePtr]
    pbase: ptr UncheckedArray[int32]
    touch: ptr Touch          ## blocks read go here
    mask*: int
    region*: VramRegion
    vram* {.cursor.}: Vram

proc view*(v: Vram; r: VramRegion; touch: ptr Touch): RegionView {.inline.} =
  RegionView(pages: cast[ptr UncheckedArray[PagePtr]](addr v.fast[r][0]),
             pbase: cast[ptr UncheckedArray[int32]](addr v.pbase[r][0]), touch: touch,
             mask: REGION_SIZE[r] - 1, region: r, vram: v)

template mark(w: RegionView; o: int) =
  ## The block holding byte `o` of a single-bank (or zero) page was read.
  let b = (int(w.pbase[o shr PAGE_SHIFT]) + (o and (PAGE_SIZE - 1))) shr BLOCK_SHIFT
  w.touch[b shr 6] = w.touch[b shr 6] or (1'u64 shl (b and 63))

template mark_all(w: RegionView) =
  ## A read through overlapping banks: the reader cannot be reused.
  w.touch[TOUCH_ALL shr 6] = w.touch[TOUCH_ALL shr 6] or (1'u64 shl (TOUCH_ALL and 63))

proc rd8*(w: RegionView; offset: int): uint8 {.inline.} =
  let o = offset and w.mask
  let q = w.pages[o shr PAGE_SHIFT]
  if likely(q != nil):
    w.mark(o)
    q[o and (PAGE_SIZE - 1)]
  else:
    w.mark_all()
    w.vram.read8(w.region, o)

proc rd16*(w: RegionView; offset: int): uint16 {.inline.} =
  ## Halfword at an even offset.
  let o = offset and w.mask
  let q = w.pages[o shr PAGE_SHIFT]
  if likely(q != nil):
    w.mark(o)
    cast[ptr uint16](addr q[o and (PAGE_SIZE - 2)])[]
  else:
    w.mark_all()
    w.vram.read16(w.region, o)

proc rd32*(w: RegionView; offset: int): uint32 {.inline.} =
  ## Word at a 4-aligned offset.
  let o = offset and w.mask
  let q = w.pages[o shr PAGE_SHIFT]
  if likely(q != nil):
    w.mark(o)
    cast[ptr uint32](addr q[o and (PAGE_SIZE - 4)])[]
  else:
    w.mark_all()
    uint32(w.vram.read16(w.region, o)) or (uint32(w.vram.read16(w.region, o + 2)) shl 16)

proc fetch8*(w: RegionView; offset: int; dst: var array[8, uint8]) {.inline.} =
  ## Eight bytes from an 8-aligned offset (one 8bpp tile row).
  let o = offset and w.mask
  let q = w.pages[o shr PAGE_SHIFT]
  if likely(q != nil):
    w.mark(o)
    copyMem(addr dst[0], addr q[o and (PAGE_SIZE - 8)], 8)
  else:
    w.mark_all()
    for k in 0..7: dst[k] = w.vram.read8(w.region, o + k)

proc touched_sum*(v: Vram; t: Touch): uint64 =
  ## How many changes the blocks in `t` have seen: the same sum later means
  ## none of them changed since.
  for wi in 0 ..< TOUCH_WORDS:
    var m = t[wi]
    while m != 0:
      let b = wi * 64 + countTrailingZeroBits(m)
      if b < VRAM_BLOCKS: result += uint64(v.vgen[b])
      m = m and (m - 1)

proc lcdc_mapped*(v: Vram; b: VramBank): bool =
  ## Bank enabled with MST 0 (its LCDC window): display capture's target.
  (v.cnt[b] and 0x87) == 0x80

{.pop.}
