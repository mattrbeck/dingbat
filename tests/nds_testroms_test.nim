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
import dingbat/nds/nds

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

block data_cache_ops_rom:
  echo "BlocksDS cache/data_cache_ops"
  var ok: bool
  let n = load_rom("blocksds/tests/cache__data_cache_ops.nds", ok)
  if ok:
    for f in 0 ..< 120: n.run_frame()
    # the BlocksDS console: engine B BG0, tile = character - 32
    let b = Arm9Bus(nds: n)
    let base = 0x0620_0000'u32 + ((b.read16(0x0400_100A'u32 - 2) shr 8) and 0x1F) * 0x800
    var rows: seq[string]
    for y in 0 ..< 24:
      var r = ""
      for x in 0 ..< 32:
        let t = int(b.read16(base + uint32(y * 32 + x) * 2) and 0x3FF) + 32
        r.add(if t in 32 .. 126: char(t) else: ' ')
      rows.add r.strip(leading = false)
    # the source's comment: the hardware's results
    let want = [(1, "Ones:    256    0    0"), (2, "Twoes:   256    0    0"),
                (5, "Ones:    128  128    0"), (6, "Twoes:   128    0  128"),
                (9, "Ones:    128  128    0"), (10, "Twoes:   128    0  128"),
                (13, "Ones:      0  256    0"), (14, "Twoes:     0    0  256"),
                (17, "Ones:    256    0    0"), (18, "Twoes:   256    0    0")]
    for (row, w) in want:
      check rows[row].strip == w, "row " & $row & ": " & w, rows[row]

echo failures, " failure(s)"
if failures > 0: quit(1)
