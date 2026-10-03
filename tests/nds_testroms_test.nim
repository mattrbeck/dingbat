## Fixes from the hardware test-ROM hunt (docs/nds/test-roms.md), each
## pinned on the whole machine: register/memory checks on a tiny
## synthesized cart (HLE BIOS), plus the test ROMs themselves where they
## are in the ROM cache (`$DINGBAT_NDS_ROMS`, default
## ~/.cache/dingbat-nds/roms; a missing ROM is skipped, not failed).
## Expected values cite GBATEK, the test ROM's own pass/fail, or the
## reference runs recorded in docs/oracles.md.
##
## Run with: nimble test_ndstestroms

import std/[os, strutils]
import dingbat/nds/[nds, savestate]
import dingbat/nds/io/input
import dingbat/nds/timing

var failures = 0

proc check(cond: bool; msg: string; detail = "") =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
    failures.inc

proc tiny_rom(): seq[uint8] =
  ## A header plus two "b ." loops: ARM9 at 0x02000000, ARM7 at 0x037F8000.
  result = newSeq[uint8](0x400)
  proc w32(r: var seq[uint8]; o: int; v: uint32) =
    for i in 0..3: r[o + i] = uint8(v shr (8 * i))
  result.w32(0x20, 0x200); result.w32(0x24, 0x0200_0000); result.w32(0x28, 0x0200_0000)
  result.w32(0x2C, 4)
  result.w32(0x30, 0x300); result.w32(0x34, 0x037F_8000); result.w32(0x38, 0x037F_8000)
  result.w32(0x3C, 4)
  result.w32(0x200, 0xEAFF_FFFE'u32)
  result.w32(0x300, 0xEAFF_FFFE'u32)

proc machine(): NDS = new_nds(tiny_rom(), @[], @[], @[])

proc roms_dir(): string =
  getEnv("DINGBAT_NDS_ROMS", getHomeDir() / ".cache/dingbat-nds/roms")

proc load_rom(rel: string; ok: var bool): NDS =
  let path = roms_dir() / rel
  ok = fileExists(path)
  if not ok:
    echo "  [SKIP] ", rel, " not in the ROM cache (tests/nds/README.md, Building)"
    return nil
  new_nds(cast[seq[uint8]](readFile(path)), @[], @[], @[])

const T3D_CHARS = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ.:-!_/,()+=><"

proc t3d_text(n: NDS): seq[string] =
  ## The bottom-screen text of a tests/nds/src/3d_common ROM: tile index =
  ## position in t3d.c's GLYPH_CHARS, map at 0x06207800 (engine B, bank H).
  let b = Arm9Bus(nds: n)
  for y in 0 ..< 24:
    var s = ""
    for x in 0 ..< 32:
      let t = int(b.read16(0x0620_7800'u32 + uint32(y * 32 + x) * 2) and 0x3FF)
      s.add(if t < T3D_CHARS.len: T3D_CHARS[t] else: '?')
    result.add s.strip(leading = false)

# ---------------------------------------------------------------------------
# POWCNT1 gating (GBATEK "DS Power Control": a disabled unit's ports are
# read-only and its palette reads zero; OAM and the kept contents from the
# reference runs of disp_powcnt, docs/oracles.md)

block powcnt_gating:
  echo "POWCNT1 gating"
  let n = machine()
  let b = Arm9Bus(nds: n)
  check n.gpu.powcnt1 == 0x820F, "direct boot leaves POWCNT1 = 0x820F (as the firmware does)",
        toHex(n.gpu.powcnt1, 4)
  for (name, base, bit) in [("engine A palette", 0x0500_0010'u32, 2'u32),
                            ("engine A OAM", 0x0700_0010'u32, 2'u32),
                            ("engine B palette", 0x0500_0410'u32, 0x200'u32),
                            ("engine B OAM", 0x0700_0410'u32, 0x200'u32)]:
    b.write32(base, 0x1111_2222'u32)
    b.write32(0x0400_0304'u32, 0x820F'u32 and not bit)
    let off = b.read32(base)
    b.write32(base, 0x3333_4444'u32)
    b.write32(0x0400_0304'u32, 0x820F)
    check off == 0 and b.read32(base) == 0x1111_2222'u32,
          name & ": reads zero while off, ignores writes, keeps its contents"
  b.write32(0x0500_0400'u32, 0x5555_6666'u32)
  b.write32(0x0400_0304'u32, 0x820F'u32 and not 2'u32)
  check b.read32(0x0500_0400'u32) == 0x5555_6666'u32,
        "engine B palette stays reachable with engine A off"
  b.write32(0x0400_0304'u32, 0x820F)
  for (name, reg, bit) in [("BG1CNT A", 0x0400_000A'u32, 2'u32),
                           ("BG1CNT B", 0x0400_100A'u32, 0x200'u32)]:
    b.write16(reg, 0x1234)
    b.write32(0x0400_0304'u32, 0x820F'u32 and not bit)
    b.write16(reg, 0x0567)
    let off = b.read16(reg)
    b.write32(0x0400_0304'u32, 0x820F)
    check off == 0x1234 and b.read16(reg) == 0x1234, name & ": read-only while its engine is off"
  # geometry off: commands are dropped (CLIPMTX_RESULT keeps the identity)
  b.write32(0x0400_0440'u32, 0)              # MTX_MODE projection
  b.write32(0x0400_0454'u32, 0)              # MTX_IDENTITY
  b.write32(0x0400_0440'u32, 1)
  b.write32(0x0400_0454'u32, 0)
  b.write32(0x0400_0304'u32, 0x820F'u32 and not 8'u32)
  for i in 0..2: b.write32(0x0400_046C'u32, 0x2000)   # MTX_SCALE 2.0
  b.write32(0x0400_0304'u32, 0x820F)
  check b.read32(0x0400_0640'u32) == 0x1000, "geometry engine off: MTX_SCALE is dropped"

block disp_powcnt_rom:
  echo "disp_powcnt (tests/nds/src/disp_powcnt)"
  var ok: bool
  let n = load_rom("3d/disp_powcnt.nds", ok)
  if ok:
    for f in 0 ..< 40: n.run_frame()
    let t = n.t3d_text()
    # the reference's rows (docs/oracles.md); RDR's RDLINES_COUNT is timing
    let want = [
      "PALA 11112222 00000000 00000000", "     11112222",
      "OAMA 11112222 00000000 00000000", "     11112222",
      "IOA  00001234 00001234 00001234", "     00001234 00010108",
      "XB   00007FFF",
      "PALB 11112222 00000000 00000000", "     11112222",
      "OAMB 11112222 00000000 00000000", "     11112222",
      "IOB  00001234 00001234 00001234", "     00001234 00010100",
      "GEO  00001000 00001000 00001000", "     00001000"]
    for i, w in want:
      check t[1 + i] == w, "row " & $(1 + i) & ": " & w, t[1 + i]
    check t[17] == "PWR  0000820F", "POWCNT1 at the entry point", t[17]

# ---------------------------------------------------------------------------
# ARM9 data cache contents (GBATEK "ARM CP15 Protection Unit" C3 write-back /
# write-through, "Cache Control" C7; the BlocksDS SDK test
# cache/data_cache_ops, whose source lists the hardware's screen)

proc cache_on(n: NDS; write_back: bool) =
  ## Region 0: I/O 64 MB; region 1: main RAM 0x02000000 4 MB, data-cached;
  ## region 2: its mirror 0x02400000, uncached. AP 3 everywhere.
  let b = Arm9Bus(nds: n)
  b.cp15_write(0, 6, 0, 0, 0x0400_0033'u32)
  b.cp15_write(0, 6, 1, 0, 0x0200_002B'u32)
  b.cp15_write(0, 6, 2, 0, 0x0240_002B'u32)
  for r in 3'u32 .. 7: b.cp15_write(0, 6, r, 0, 0)        # the firmware's others off
  b.cp15_write(0, 2, 0, 0, 0x02)                          # D-cachable: region 1
  b.cp15_write(0, 3, 0, 0, (if write_back: 0x02'u32 else: 0'u32))
  b.cp15_write(0, 5, 0, 2, 0x333)                         # data AP 3, regions 0-2
  b.cp15_write(0, 5, 0, 3, 0x333)
  b.cp15_write(0, 1, 0, 0, n.cp15.control or 1 or 4)      # PU + data cache on

block data_cache_contents:
  echo "ARM9 data cache contents"
  let n = machine()
  let b = Arm9Bus(nds: n)
  let b7 = Arm7Bus(nds: n)
  n.cache_on(write_back = true)
  const A = 0x0210_0000'u32
  b7.write32(A, 0)
  discard b.read32(A)                                     # line filled
  b.write32(A, 0x1111_1111'u32)
  check b.read32(A) == 0x1111_1111'u32 and b7.read32(A) == 0,
        "write-back: the CPU sees its store, memory (ARM7) does not"
  check b.read32(A + 0x40_0000) == 0, "the uncached mirror reads memory"
  b.cp15_write(0, 7, 10, 1, A)                            # clean line
  check b7.read32(A) == 0x1111_1111'u32, "clean writes the line back"
  b7.write32(A, 0x2222_2222'u32)
  check b.read32(A) == 0x1111_1111'u32, "a store behind the cache leaves the CPU's copy stale"
  b.cp15_write(0, 7, 6, 1, A)                             # invalidate line
  check b.read32(A) == 0x2222_2222'u32, "after invalidate the CPU reads memory"
  b.write32(A, 0x3333_3333'u32)
  b.cp15_write(0, 7, 6, 1, A)
  check b.read32(A) == 0x2222_2222'u32 and b7.read32(A) == 0x2222_2222'u32,
        "invalidating a dirty line loses the store"
  b.write32(A + 4, 0x4444_4444'u32)
  for way in 0'u32 .. 3:                                  # DC_FlushAll's loop
    for set in 0'u32 .. 31: b.cp15_write(0, 7, 14, 2, (way shl 30) or (set shl 5))
  check b7.read32(A + 4) == 0x4444_4444'u32, "clean and invalidate by set/index writes back"
  # eviction: 5 lines in one set (4 ways), the first written back
  discard b.read32(A + 0x2000)
  b.write32(A + 0x2000, 0x5555_5555'u32)
  for k in 1'u32 .. 4: discard b.read32(A + 0x2000 + k * 0x400)
  check b7.read32(A + 0x2000) == 0x5555_5555'u32, "an evicted dirty line is written back"
  let n2 = machine()
  let c = Arm9Bus(nds: n2)
  n2.cache_on(write_back = false)
  discard c.read32(A)
  c.write32(A, 0x6666_6666'u32)
  check Arm7Bus(nds: n2).read32(A) == 0x6666_6666'u32, "write-through updates memory too"

# ---------------------------------------------------------------------------
# ARM9 instruction cache contents (GBATEK "ARM CP15 Cache Control": C7,C5,0 /
# C7,C5,1 invalidate, C7,C13,1 prefetch; "DS Memory Control - Cache and
# TCM": 4-way, 32-byte lines; tests/nds/src/icache_stale)

block instruction_cache_contents:
  echo "ARM9 instruction cache contents"
  let n = machine()
  n.arm9.wl_on = false                                    # fetches outside a run
  let b = Arm9Bus(nds: n)
  let b7 = Arm7Bus(nds: n)
  n.cache_on(write_back = true)
  b.cp15_write(0, 2, 0, 1, 0x02)                          # I-cachable: region 1
  b.cp15_write(0, 1, 0, 0, n.cp15.control or (1'u32 shl 12))
  const A = 0x0210_0000'u32
  b7.write32(A, 0x1111_1111'u32)
  check b.fetch32(A) == 0x1111_1111'u32, "a miss fills from memory"
  b7.write32(A, 0x2222_2222'u32)
  check b.fetch32(A) == 0x1111_1111'u32, "code the ARM7 changed behind the cache runs stale"
  b.write32(A + 0x40_0000, 0x2323_2323'u32)               # the uncached mirror
  check b.fetch32(A) == 0x1111_1111'u32, "so does code changed through the uncached mirror"
  b.cp15_write(0, 7, 5, 1, A)
  check b.fetch32(A) == 0x2323_2323'u32, "C7,C5,1 drops the line: the next fetch reads memory"
  # through the write-back data cache: the I-cache fills from memory, not
  # from the CPU's dirty copy
  discard b.read32(A)                                     # D-cache line filled
  b.write32(A, 0x3333_3333'u32)
  b.cp15_write(0, 7, 5, 1, A)
  check b.fetch32(A) == 0x2323_2323'u32, "a dirty data-cache line is not code until cleaned"
  b.cp15_write(0, 7, 10, 1, A)                            # clean: memory 0x3333...
  check b.fetch32(A) == 0x2323_2323'u32, "cleaning reaches memory, not the instruction line"
  b.cp15_write(0, 7, 5, 0, 0)
  check b.fetch32(A) == 0x3333_3333'u32, "C7,C5,0 drops every line"
  # off and on again: the lines stay
  b7.write32(A, 0x4444_4444'u32)
  let ctl = n.cp15.control
  b.cp15_write(0, 1, 0, 0, ctl and not (1'u32 shl 12))
  check b.fetch32(A) == 0x4444_4444'u32, "with the cache off fetches read memory"
  b.cp15_write(0, 1, 0, 0, ctl)
  check b.fetch32(A) == 0x3333_3333'u32, "on again, the line still holds what it was filled with"
  # eviction: four more lines of the set (2 KB apart) replace it
  for k in 1'u32 .. 3: discard b.fetch32(A + k * 0x800)
  check b.fetch32(A) == 0x3333_3333'u32, "three other lines of the set: still held"
  discard b.fetch32(A + 4 * 0x800)
  check b.fetch32(A) == 0x4444_4444'u32, "a fourth evicts it (4 ways, round robin)"
  # Thumb halves of a kept word, and a save state holding a kept line
  b7.write32(A + 0x20, 0x2001_2002'u32)
  discard b.fetch16(A + 0x20)
  b7.write32(A + 0x20, 0x2003_2004'u32)
  check b.fetch16(A + 0x20) == 0x2002 and b.fetch16(A + 0x22) == 0x2001,
        "Thumb fetches read the kept halves"
  let n2 = machine()
  n2.arm9.wl_on = false
  check n2.load_state_bytes(n.state_bytes()), "state with a kept line loads"
  let c = Arm9Bus(nds: n2)
  check c.fetch16(A + 0x20) == 0x2002 and Arm7Bus(nds: n2).read32(A + 0x20) == 0x2003_2004'u32,
        "the loaded state runs the kept line, memory holds the new code"
  c.cp15_write(0, 7, 5, 1, A + 0x20)
  check c.fetch16(A + 0x20) == 0x2004, "and invalidating it there reads memory"
  # prefetch (C7,C13,1) fills without running
  b7.write32(A + 0x40, 0x5555_5555'u32)
  b.cp15_write(0, 7, 13, 1, A + 0x40)
  b7.write32(A + 0x40, 0x6666_6666'u32)
  check b.fetch32(A + 0x40) == 0x5555_5555'u32, "a prefetched line runs what it was filled with"

block fetch_fast_paths:
  # bus9.nim fetch_line9 / bus7.nim fetch_page7: sequential fetches inside
  # a line (ARM9) or page (ARM7) read memory directly; each change that
  # makes that wrong must turn the shortcut off mid-run
  echo "sequential fetch fast paths"
  let n = machine()
  n.arm9.wl_on = false
  n.arm7.wl_on = false
  let b = Arm9Bus(nds: n)
  let b7 = Arm7Bus(nds: n)
  n.cache_on(write_back = true)
  b.cp15_write(0, 2, 0, 1, 0x02)                          # I-cachable: region 1
  b.cp15_write(0, 1, 0, 0, n.cp15.control or (1'u32 shl 12))
  const A = 0x0220_0000'u32
  for k in 0'u32 ..< 8: b7.write32(A + 4 * k, 0x1000_0000'u32 + k)
  check b.fetch32(A) == 0x1000_0000'u32 and b.fetch32(A + 4) == 0x1000_0001'u32,
        "ARM9: a cached line, then a sequential fetch in it"
  b7.write32(A + 8, 0x2222_2222'u32)                      # memory changes under the line
  check b.fetch32(A + 8) == 0x1000_0002'u32, "ARM9: the next sequential fetch runs the line as filled"
  b.cp15_write(0, 7, 5, 0, 0)
  check b.fetch32(A + 12) == 0x1000_0003'u32 and b.fetch32(A + 16) == 0x1000_0004'u32,
        "ARM9: sequential after a C7 invalidate refills from memory"
  b7.write32(A + 20, 0x3333_3333'u32)
  check b.fetch32(A + 20) == 0x1000_0005'u32, "ARM9: ...and keeps the refilled line"
  # into the next line: not cached yet (a fill from memory), then cached
  # and changed behind the cache (the line as filled)
  b7.write32(A + 32, 0x1000_0008'u32)
  discard b.fetch32(A + 24)
  check b.fetch32(A + 28) == 0x1000_0007'u32 and b.fetch32(A + 32) == 0x1000_0008'u32,
        "ARM9: sequential into a line not cached fills it"
  discard b.fetch32(A)                                    # a branch back
  for k in 1'u32 .. 7: discard b.fetch32(A + 4 * k)
  b7.write32(A + 32, 0x4444_4444'u32)
  check b.fetch32(A + 32) == 0x1000_0008'u32, "ARM9: sequential into a cached line runs it as filled"
  # code in a page with a dirty data-cache line: clean lines run straight
  # from memory, the dirty line itself from memory's side (not the CPU's)
  const C = 0x0228_0000'u32
  for k in 0'u32 ..< 16: b7.write32(C + 4 * k, 0x5000_0000'u32 + k)
  discard b.read32(C + 32)                                # D-cache line C+32 filled...
  b.write32(C + 36, 0x6666_6666'u32)                      # ...and dirtied: the page is apart
  check b.fetch32(C) == 0x5000_0000'u32 and b.fetch32(C + 4) == 0x5000_0001'u32 and
        b.fetch32(C + 8) == 0x5000_0002'u32, "ARM9: sequential in a clean line of a page apart"
  discard b.fetch32(C + 28)
  check b.fetch32(C + 32) == 0x5000_0008'u32 and b.fetch32(C + 36) == 0x5000_0009'u32,
        "ARM9: sequential into the dirty line runs memory's side"
  # ARM7 in main RAM while the ARM9's write-back data cache dirties a line
  # of the same page: the ARM7 reads memory's side
  const B = 0x0230_0000'u32
  for k in 0'u32 ..< 8: b7.write32(B + 4 * k, 0x4000_0000'u32 + k)
  check b7.fetch32(B) == 0x4000_0000'u32 and b7.fetch32(B + 4) == 0x4000_0001'u32,
        "ARM7: sequential fetches in main RAM"
  discard b.read32(B + 8)                                 # ARM9 D-cache line filled
  b.write32(B + 8, 0x5555_5555'u32)                       # dirty: memory keeps its side
  check b7.fetch32(B + 8) == 0x4000_0002'u32, "ARM7: a dirty ARM9 data-cache line is not what it runs"
  # ARM7 in shared WRAM while WRAMCNT takes it away
  b.write8(0x0400_0247'u32, 3)                            # all 32 KB to the ARM7
  for k in 0'u32 ..< 8:
    b7.write32(0x0300_0000'u32 + 4 * k, 0x6000_0000'u32 + k)
    b7.write32(0x0380_0000'u32 + 4 * k, 0x7000_0000'u32 + k)
  check b7.fetch32(0x0300_0000'u32) == 0x6000_0000'u32 and
        b7.fetch32(0x0300_0004'u32) == 0x6000_0001'u32, "ARM7: sequential fetches in shared WRAM"
  b.write8(0x0400_0247'u32, 0)                            # all to the ARM9: the ARM7 sees its own WRAM
  check b7.fetch32(0x0300_0008'u32) == 0x7000_0002'u32, "ARM7: WRAMCNT moves the next sequential fetch"

block data_tlb:
  # bus9.nim dtlb_fill9 / read32 .. write32: DTCM pages and cached main RAM
  # pages take a short path (main RAM only on a tag hit, stores only into a
  # dirty line); every change that makes the short path wrong must drop it
  echo "ARM9 data TLB"
  let n = machine()
  let b = Arm9Bus(nds: n)
  let b7 = Arm7Bus(nds: n)
  n.cache_on(write_back = true)
  const A = 0x0210_0000'u32
  b7.write32(A, 0x1111_1111'u32)
  discard b.read32(A)                                     # line filled, page entered
  b.write32(A, 0x2222_2222'u32)                           # a clean line: dirtied the long way
  b.write32(A, 0x3333_3333'u32)                           # a dirty line: the short way
  check b.read32(A) == 0x3333_3333'u32 and b7.read32(A) == 0x1111_1111'u32,
        "stores into a dirty line: the CPU sees them, memory keeps its side"
  let ctl = n.cp15.control
  b.cp15_write(0, 1, 0, 0, ctl and not 4'u32)             # data cache off
  check b.read32(A) == 0x1111_1111'u32, "data cache switched off: loads read memory"
  b.cp15_write(0, 1, 0, 0, ctl)
  check b.read32(A) == 0x3333_3333'u32, "on again: the dirty line"
  b.cp15_write(0, 2, 0, 0, 0)                             # region 1 no longer cachable
  check b.read32(A) == 0x1111_1111'u32, "page made uncachable: loads read memory"
  b.cp15_write(0, 2, 0, 0, 0x02)
  # a clean line hit in a page the TLB holds for stores: memory keeps its side
  b7.write32(A + 0x40, 0x4444_4444'u32)
  discard b.read32(A + 0x40)
  b.write32(A + 0x80, 0)                                  # (a miss: enters the page for stores)
  b.write32(A + 0x40, 0x5555_5555'u32)
  check b7.read32(A + 0x40) == 0x4444_4444'u32, "a store into a clean line dirties it"
  # a dropped line: the next load misses and refills
  b.cp15_write(0, 7, 6, 1, A)
  check b.read32(A) == 0x1111_1111'u32 and n.tm.dcache.find_slot(A) >= 0,
        "a load after C7 invalidate misses and fills the line again"
  # the uncached mirror (region 2): pages with nothing apart are read as
  # memory is; one going apart (a dirty line through the cached mirror) must
  # be read the long way, memory's side
  const U = A + 0x40_0000
  b7.write32(A + 0x5400, 0x1212_1212'u32)               # (a page with nothing apart)
  discard b.read32(A + 0x5400)                            # cached through the other mirror
  check b.read32(U + 0x5400) == 0x1212_1212'u32, "uncached mirror"
  b7.write32(A + 0x5400, 0x1313_1313'u32)                 # behind the cache: the page is apart
  check b.read32(U + 0x5400) == 0x1313_1313'u32 and b.read32(A + 0x5400) == 0x1212_1212'u32,
        "uncached load of a line the cache keeps apart reads memory"
  # an uncached store to a line the cache holds reaches memory only
  b.write32(U + 0x800, 0)                                 # (enters the page for stores)
  b7.write32(A + 0x420, 0x1414_1414'u32)
  discard b.read32(A + 0x420)                             # clean, cached
  b.write32(U + 0x420, 0x1515_1515'u32)
  check b.read32(A + 0x420) == 0x1414_1414'u32 and b7.read32(A + 0x420) == 0x1515_1515'u32,
        "uncached store to a cached line: memory changes, the CPU's copy does not"
  # data cache off, a cachable page is loaded uncached; switched on, it fills
  b.cp15_write(0, 1, 0, 0, n.cp15.control and not 4'u32)
  discard b.read32(A + 0x3800)                            # a page with nothing apart
  b.cp15_write(0, 1, 0, 0, n.cp15.control or 4)
  discard b.read32(A + 0x3800)
  check n.tm.dcache.find_slot(A + 0x3800) >= 0, "a page loaded uncached while the cache was off is cached when it is on"
  # DTCM over main RAM: moved away, the window's old pages are main RAM again
  const D = 0x0230_0000'u32
  b7.write32(D + 0x10, 0x6666_6666'u32)
  b7.write32(D + 0x20, 0x6767_6767'u32)
  b.cp15_write(0, 9, 1, 0, D or 0x0A)                     # DTCM 16 KB at D
  b.write32(D + 0x10, 0x7777_7777'u32)
  b.write32(D + 0x20, 0x7878_7878'u32)
  check b.read32(D + 0x10) == 0x7777_7777'u32, "DTCM over main RAM"
  b.cp15_write(0, 1, 0, 0, n.cp15.control or (1'u32 shl 17))   # DTCM load mode
  check b.read32(D + 0x20) == 0x6767_6767'u32, "DTCM load mode: loads read main RAM"
  b.cp15_write(0, 1, 0, 0, n.cp15.control and not (1'u32 shl 17))
  check b.read32(D + 0x20) == 0x7878_7878'u32, "load mode off: DTCM"
  # DMA does not see the TCMs (GBATEK "DS Memory Control - Cache and TCM")
  b.write32(0x0400_00B0'u32, D + 0x20)                    # DMA0 SAD
  b.write32(0x0400_00B4'u32, 0x0231_0000'u32)             # DMA0 DAD
  b.write32(0x0400_00B8'u32, 0x8400_0001'u32)             # immediate, 32-bit, 1 unit
  check b7.read32(0x0231_0000'u32) == 0x6767_6767'u32, "DMA reads main RAM behind DTCM"
  let saved = n.state_bytes()
  b.write32(D + 0x14, 0x7979_7979'u32)                    # D entered as DTCM for stores...
  check b.read32(D + 0x10) == 0x7777_7777'u32, "DTCM again"   # ...and loads
  b.cp15_write(0, 9, 1, 0, 0x0080_000A'u32)               # DTCM back where direct boot put it
  check b.read32(D + 0x10) == 0x6666_6666'u32 and b.read32(0x0080_0010'u32) == 0x7777_7777'u32,
        "DTCM moved away: its old pages are main RAM again"
  b.write32(D + 0x30, 0x6868_6868'u32)
  let n2 = machine()
  let c = Arm9Bus(nds: n2)
  c.cp15_write(0, 9, 1, 0, D or 0x0A)
  discard c.read32(D + 0x30)                              # n2 enters D as DTCM...
  check n2.load_state_bytes(n.state_bytes()), "state loads"
  check c.read32(D + 0x30) == 0x6868_6868'u32, "...and a loaded state with DTCM elsewhere reads main RAM"
  check n2.load_state_bytes(saved) and c.read32(D + 0x10) == 0x7777_7777'u32,
        "a loaded state with DTCM at D reads DTCM"

block irq_at_next_opcode:
  # arm/cpu.nim run checks halt and the IRQ line only when `attn` says they
  # may have changed: an IRQ made takeable by the CPU's own store (IME
  # here; IE and IF alike) or CPSR write is taken before the next opcode.
  # The HLE BIOS's IRQ vector calls the handler at [DTCM+3FFCh] /
  # [0380FFFCh] with r3 untouched; the handler copies r3 (the opcodes run
  # after the store) to r4.
  echo "interrupts taken at the opcode after the write that allows them"
  const BY_IME = [0xE3A0_44FF'u32,     # MOV r4, #0xFF000000
                  0xE3A0_0301'u32,     # MOV r0, #0x04000000
                  0xE280_0F82'u32,     # ADD r0, r0, #0x208 (IME)
                  0xE3A0_1001'u32,     # MOV r1, #1
                  0xE3A0_3000'u32,     # MOV r3, #0
                  0xE580_1000'u32,     # STR r1, [r0]: IME = 1
                  0xE283_3001'u32,     # ADD r3, r3, #1
                  0xE283_3001'u32,     # ADD r3, r3, #1
                  0xEAFF_FFFE'u32]     # B .
  const BY_CPSR = [0xE3A0_44FF'u32,    # MOV r4, #0xFF000000
                   0xE3A0_3000'u32,    # MOV r3, #0
                   0xE321_F01F'u32,    # MSR CPSR_c, #0x1F: system mode, I clear
                   0xE283_3001'u32,    # ADD r3, r3, #1
                   0xE283_3001'u32,    # ADD r3, r3, #1
                   0xEAFF_FFFE'u32]    # B .
  const HANDLER = [0xE1A0_4003'u32,    # MOV r4, r3
                   0xEAFF_FFFE'u32]    # B .
  for arm9 in [true, false]:
    for by_ime in [true, false]:
      let n = machine()
      n.arm9.wl_on = false
      n.arm7.wl_on = false
      let code = if arm9: 0x0210_0000'u32 else: 0x0380_1000'u32
      let hand = code + 0x100
      let main = if by_ime: @BY_IME else: @BY_CPSR
      for i, w in main: Arm7Bus(nds: n).write32(code + uint32(4 * i), w)
      for i, w in HANDLER: Arm7Bus(nds: n).write32(hand + uint32(4 * i), w)
      let (me, other) = if arm9: (n.irq9, n.irq7) else: (n.irq7, n.irq9)
      me.ie = 1; me.iff = 1                             # V-blank pending
      me.ime = if by_ime: 0'u32 else: 1'u32
      other.ie = 0
      let cpsr = uint32(mSYS) or (if by_ime: 0'u32 else: FLAG_I)
      if arm9:
        Arm9Bus(nds: n).write32(0x0080_3FFC'u32, hand)  # DTCM + 3FFCh (direct boot's DTCM)
        n.arm9.set_cpsr(cpsr)
        n.arm9.next_pc = code
        n.arm7.halted = true
      else:
        Arm7Bus(nds: n).write32(0x0380_FFFC'u32, hand)
        n.arm7.set_cpsr(cpsr)
        n.arm7.next_pc = code
        n.arm9.halted = true
      n.run_until(n.sched.now + 4000)
      let r4 = if arm9: n.arm9.r[4] else: n.arm7.r[4]
      check r4 == 0, (if arm9: "ARM9" else: "ARM7") & ": the IRQ comes before the opcode after " &
            (if by_ime: "STR IME" else: "MSR clearing CPSR.I"), "r4 = " & toHex(r4)

block icache_stale_rom:
  echo "icache_stale (tests/nds/src/icache_stale)"
  var ok: bool
  let n = load_rom("3d/icache_stale.nds", ok)
  if ok:
    for f in 0 ..< 20: n.run_frame()
    let t = n.t3d_text()
    # GBATEK's semantics (the file's header); the reference runs model no
    # cache contents (docs/oracles.md)
    let want = ["STR   1 1 2", "MIR   1 1 2", "DMA   1 1 2", "THM   1 1 2",
                "OFF   1 2 1 2", "PRE   1 2", "WB    1 1 2", "EVI   1 2"]
    for i, w in want:
      check t[2 + i] == w, "row " & $(2 + i) & ": " & w, t[2 + i]
    check t[11] == "DONE", "every row ran", t[11]

proc blocksds_console(n: NDS): seq[string] =
  ## The BlocksDS console: engine B BG0, tile = character - 32.
  let b = Arm9Bus(nds: n)
  let base = 0x0620_0000'u32 + ((b.read16(0x0400_1008'u32) shr 8) and 0x1F) * 0x800
  for y in 0 ..< 24:
    var r = ""
    for x in 0 ..< 32:
      let t = int(b.read16(base + uint32(y * 32 + x) * 2) and 0x3FF) + 32
      r.add(if t in 32 .. 126: char(t) else: ' ')
    result.add r.strip(leading = false)

block data_cache_mirrors:
  echo "ARM9 data cache: mirrors are separate lines"
  let n = machine()
  let b = Arm9Bus(nds: n)
  n.cache_on(write_back = true)
  b.cp15_write(0, 6, 1, 0, 0x0200_002F'u32)              # main RAM and its mirrors, 16 MB
  const A = 0x0210_0000'u32
  b.write32(A, 0x1111_1111'u32)                          # write miss: memory
  discard b.read32(A)                                    # line filled under A
  b.write32(A + 0x40_0000, 0x7777_7777'u32)              # the mirror misses: memory
  check b.read32(A) == 0x1111_1111'u32, "a store through a mirror leaves the line under A stale"
  check Arm7Bus(nds: n).read32(A) == 0x7777_7777'u32, "memory holds the mirror's store"

block swi_calls_rom:
  echo "BlocksDS system/swi_calls (HLE BIOS)"
  var ok: bool
  let n = load_rom("blocksds/tests/system__swi_calls.nds", ok)
  if ok:
    for f in 0 ..< 60: n.run_frame()
    let rows = n.blocksds_console()
    check "swiIsDebugger(): 1" in rows,
          "swiIsDebugger() with the data cache on: 1 (GBATEK: \"always returns 8MB state\")"
    check "swiDivide(2000, 7): 285" in rows and "swiSqrt(3000): 54" in rows, "Divide, Sqrt"

block data_cache_ops_rom:
  echo "BlocksDS cache/data_cache_ops"
  var ok: bool
  let n = load_rom("blocksds/tests/cache__data_cache_ops.nds", ok)
  if ok:
    for f in 0 ..< 120: n.run_frame()
    let rows = n.blocksds_console()
    # the source's comment: the hardware's results
    let want = [(1, "Ones:    256    0    0"), (2, "Twoes:   256    0    0"),
                (5, "Ones:    128  128    0"), (6, "Twoes:   128    0  128"),
                (9, "Ones:    128  128    0"), (10, "Twoes:   128    0  128"),
                (13, "Ones:      0  256    0"), (14, "Twoes:     0    0  256"),
                (17, "Ones:    256    0    0"), (18, "Twoes:   256    0    0")]
    for (row, w) in want:
      check rows[row].strip == w, "row " & $row & ": " & w, rows[row]

proc libnds_console(n: NDS): string =
  ## The libnds demo console: engine B BG0, tile = character.
  let b = Arm9Bus(nds: n)
  let base = 0x0620_0000'u32 + ((b.read16(0x0400_1008'u32) shr 8) and 0x1F) * 0x800
  for i in 0 ..< 32 * 24:
    let t = int(b.read16(base + uint32(i) * 2) and 0x3FF)
    result.add(if t in 32 .. 126: char(t) else: ' ')

proc number_after(s, key: string): int =
  let k = s.find(key)
  if k < 0: return -1
  var j = k + key.len
  while j < s.len and s[j] in Digits:
    result = result * 10 + ord(s[j]) - ord('0')
    inc j

block polyrastertest_rom:
  # 77 one-polygon scenes compared span by span (and some colour by
  # colour) with data recorded on hardware (docs/nds/3d-edges.md). Manual
  # mode (SELECT held at boot) stops at every scene; A moves on.
  echo "polyrastertest v1.0.2-b (hardware-recorded spans)"
  var ok: bool
  let n = load_rom("polyrastertest/polyrastertest.nds", ok)
  if ok:
    n.set_button(nbSelect, true)
    var seen, passed = 0
    var fails: seq[int]
    var press, release = 0
    for f in 1 .. 3000:
      n.run_frame()
      if f == 20: n.set_button(nbSelect, false)
      if f == press: n.set_button(nbA, true)
      if f == release: n.set_button(nbA, false)
      # a scene's result: the ROM shows VRAM_A (display mode 2)
      if f < release + 2 or ((Arm9Bus(nds: n).read32(0x0400_0000'u32) shr 16) and 3) != 2: continue
      let text = n.libnds_console()
      let t = text.number_after("Viewing Test ")
      if t <= seen: continue
      let p = text.number_after("Tests Passed: ")
      if p == passed: fails.add t
      seen = t
      passed = p
      if seen == 77: break
      press = f + 1
      release = f + 4
    check seen == 77, "all 77 scenes ran", $seen
    # 50 before the edge rules of docs/nds/3d-edges.md ("Chains, facing
    # and swapped rows"), 73 before "Overlapping edges with edge marking"
    # and the swapped x-major coverage; the hardware passes 77
    check passed == 77, "77 of 77 pass", $passed
    check fails.len == 0, "none failing", fails.join(",")

echo failures, " failure(s)"
if failures > 0: quit(1)
