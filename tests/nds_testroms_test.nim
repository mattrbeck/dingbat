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
    # and swapped rows"), 73 before the swapped x-major coverage; the
    # hardware passes 77
    check passed == 74, "74 of 77 pass", $passed
    check fails == @[38, 39, 43], "failing: 38, 39, 43 (edge marking)", fails.join(",")

echo failures, " failure(s)"
if failures > 0: quit(1)
