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

echo failures, " failure(s)"
if failures > 0: quit(1)
