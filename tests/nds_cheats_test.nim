## DS cheat codes (nds/cheats.nim) against a flat test memory: every Action
## Replay DS and CodeBreaker DS code type GBATEK lists that the engine runs,
## and the refusals. The core's side (nds.nim cheat_read / cheat_write) is
## the web e2e's (web/e2e/nds.e2e.mjs, cheat_probe).
##
##   nimble test_ndscheats

import std/[strutils, tables]
import dingbat/nds/cheats

type Mem = ref object
  b: Table[uint32, uint8]

proc rd(m: Mem; a: uint32; n: int): uint32 =
  for i in 0 ..< n: result = result or (uint32(m.b.getOrDefault(a + uint32(i))) shl (8 * i))
proc wr(m: Mem; a, v: uint32; n: int) =
  for i in 0 ..< n: m.b[a + uint32(i)] = uint8((v shr (8 * i)) and 0xFF)

proc hooks(m: Mem): DsCheatMem =
  DsCheatMem(
    read8: proc(a: uint32): uint32 = m.rd(a, 1),
    read16: proc(a: uint32): uint32 = m.rd(a and not 1'u32, 2),
    read32: proc(a: uint32): uint32 = m.rd(a and not 3'u32, 4),
    write8: proc(a, v: uint32) = m.wr(a, v, 1),
    write16: proc(a, v: uint32) = m.wr(a and not 1'u32, v, 2),
    write32: proc(a, v: uint32) = m.wr(a and not 3'u32, v, 4))

var failures = 0
template check(cond: bool; what: string) =
  if not cond:
    inc failures
    echo "FAIL: ", what

proc run1(codes: string; m: Mem; frames = 1; gamecode = 0'u32): DsCheats =
  result = DsCheats(gamecode: gamecode)
  result.load("[x] t\n" & codes & "\n")
  check(result.errors() == "", "parses: " & result.errors())
  for _ in 0 ..< frames: result.run(m.hooks)

proc refused(codes: string; gamecode = 0'u32): string =
  let e = DsCheats(gamecode: gamecode)
  e.load("[x] t\n" & codes & "\n")
  e.errors()

block writes:
  let m = Mem()
  discard run1("02000000 11223344\n12000010 0000AABB\n22000020 000000CC", m)
  check(m.rd(0x02000000, 4) == 0x11223344, "AR 0: word")
  check(m.rd(0x02000010, 2) == 0xAABB, "AR 1: half")
  check(m.rd(0x02000020, 1) == 0xCC and m.rd(0x02000021, 1) == 0, "AR 2: byte only")

block conditions:
  let m = Mem()
  m.wr(0x02000100, 5, 4)
  # 3: IF Y > word; 4: Y < word; 5: =; 6: <>; each guarding a byte write
  discard run1("""
32000100 00000006
22000200 00000001
D0000000 00000000
42000100 00000006
22000201 00000001
D0000000 00000000
52000100 00000005
22000202 00000001
D0000000 00000000
62000100 00000005
22000203 00000001
D0000000 00000000""", m)
  check(m.rd(0x02000200, 1) == 1, "AR 3: 6 > 5")
  check(m.rd(0x02000201, 1) == 0, "AR 4: not 6 < 5")
  check(m.rd(0x02000202, 1) == 1, "AR 5: 5 = 5")
  check(m.rd(0x02000203, 1) == 0, "AR 6: not 5 <> 5")
  # 7-A: masked halfword, (not ZZZZ) and half
  m.wr(0x02000300, 0xFF34, 2)
  discard run1("""
92000300 FF000034
22000210 00000001
D0000000 00000000
A2000300 FF000034
22000211 00000001
D0000000 00000000
72000300 FF000035
22000212 00000001
D0000000 00000000
82000300 FF000033
22000213 00000001
D0000000 00000000""", m)
  check(m.rd(0x02000210, 1) == 1, "AR 9: masked equal")
  check(m.rd(0x02000211, 1) == 0, "AR A: not unequal")
  check(m.rd(0x02000212, 1) == 1, "AR 7: 35 > 34")
  check(m.rd(0x02000213, 1) == 1, "AR 8: 33 < 34")

block nesting:
  # a false outer IF keeps an inner true one from running; ENDIF restores
  let m = Mem()
  m.wr(0x02000000, 1, 4)
  discard run1("""
52000000 00000002
52000000 00000001
22000400 00000001
D0000000 00000000
22000401 00000001
D0000000 00000000
22000402 00000001""", m)
  check(m.rd(0x02000400, 1) == 0, "inner true IF under a false one")
  check(m.rd(0x02000401, 1) == 0, "after the inner ENDIF, still the outer false")
  check(m.rd(0x02000402, 1) == 1, "after both ENDIFs")

block registers:
  let m = Mem()
  m.wr(0x02000500, 0x02000600, 4)      # a pointer
  m.wr(0x02000710, 0xDEAD0001'u32, 4)
  discard run1("""
B2000500 00000000
00000010 CAFEBABE
D2000000 00000000
D3000000 02000700
D5000000 12345678
D6000000 00000000
D4000000 00000001
D6000000 00000000
D7000000 00000000
D8000000 00000000
DC000000 00000005
D9000000 00000000
D3000000 00000000
D6000000 02000720""", m)
  check(m.rd(0x02000610, 4) == 0xCAFEBABE'u32, "B: offset from a pointer, then a write at it")
  check(m.rd(0x02000700, 4) == 0x12345678, "D6 then offset + 4")
  check(m.rd(0x02000704, 4) == 0x12345679, "D4 add, D6 at the moved offset")
  check(m.rd(0x02000708, 2) == 0x5679, "D7 then offset + 2")
  check(m.rd(0x0200070A, 1) == 0x79, "D8 then offset + 1")
  check(m.rd(0x02000720, 4) == 0xDEAD0001'u32, "DC 70Bh + 5, D9 reads [710h], D6 writes it")

block loop:
  # FOR 4 passes of: datareg += 1; byte at offset; offset + 1 (D8)
  let m = Mem()
  discard run1("""
D3000000 02000800
D5000000 00000000
C0000000 00000003
D4000000 00000001
D8000000 00000000
D1000000 00000000
D3000000 00000000
22000900 000000EE""", m)
  for i in 0 .. 3: check(m.rd(0x02000800 + uint32(i), 1) == uint32(i + 1), "loop pass " & $i)
  check(m.rd(0x02000804, 1) == 0, "four passes, not five")
  check(m.rd(0x02000900, 1) == 0xEE, "after NEXT the list goes on")
  # D2: NEXT, then FLUSH clears offset and datareg
  let m2 = Mem()
  m2.wr(0x02000A00, 0xFFFF, 2)
  discard run1("""
D3000000 02000000
C0000000 00000001
D1000000 00000000
D5000000 00000077
C0000000 00000000
D2000000 00000000
D7000000 02000A00""", m2)
  check(m2.rd(0x02000A00, 2) == 0, "D2 flushed datareg and offset")

block counter:
  # C5: counter + 1, IF (counter and 3) = 0 -> every fourth frame
  let m = Mem()
  let e = DsCheats()
  e.load("[x] c\nC5000000 00000003\nD4000000 00000000\n12000B00 00000001\nD0000000 00000000\n")
  var hits = 0
  for f in 0 ..< 12:
    m.wr(0x02000B00, 0, 2)
    e.run(m.hooks)
    if m.rd(0x02000B00, 2) == 1: inc hits
  check(hits == 3, "C5 every fourth of 12 frames: " & $hits)

block copies:
  let m = Mem()
  # E: 10 parameter bytes to 0x02000C00; then F copies 8 bytes from offset
  discard run1("""
E2000C00 0000000A
44332211 88776655
0000AA99 00000000
D3000000 02000C00
F2000D00 00000008""", m)
  for i, b in [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA]:
    check(m.rd(0x02000C00 + uint32(i), 1) == uint32(b), "E byte " & $i)
  check(m.rd(0x02000C0A, 1) == 0, "E wrote 10 bytes only")
  check(m.rd(0x02000D00, 4) == 0x44332211 and m.rd(0x02000D04, 4) == 0x88776655'u32, "F copy")

block runaway:
  # A loop of 2^32 passes stops at the step limit
  let m = Mem()
  discard run1("C0000000 FFFFFFFF\nD4000000 00000001\nD1000000 00000000", m)
  check(true, "returns")

block refusals:
  check("C4" in refused("C4000000 00000000"), "C4 refused")
  check("hex" in refused("0200000G 00000000"), "not hex")
  check("two 8-digit" in refused("0200000 00000000"), "short word")
  check("E code" in refused("E2000000 00000010\n00000000 00000000"), "E short of parameter lines")
  check("unknown" in refused("C1000000 00000000"), "C1 unknown")
  check(refused("ABCD-12345678\n02000000 00000001") == "", "a game ID line is skipped")

const GAME = 0x4B504945'u32   # "EIPK" as the header's bytes read little-endian

block codebreaker:
  let be = (GAME shr 24) or ((GAME shr 8) and 0xFF00) or ((GAME shl 8) and 0xFF0000) or (GAME shl 24)
  let hdr = "8000ABCD " & toHex(be, 8) & "\n"
  let m = Mem()
  m.wr(0x02000010, 10, 2)
  m.wr(0x02000020, 0x0F, 1)
  m.wr(0x02000030, 0x02000100, 4)
  m.wr(0x02000040, 0x1234, 2)
  discard run1(hdr & """
02000000 000000AB
12000002 0000CDEF
22000004 01234567
32000010 00010005
3A000014 00000003
72000020 000000F0
72000021 001000FF
62000030 000000EE
00000004 00000000
42000200 20030002
00000001 00000002
D2000040 0100ABCD
02000300 00000001
D2000040 01001234
02000301 00000001""", m, gamecode = GAME)
  check(m.rd(0x02000000, 1) == 0xAB, "CB 0: byte")
  check(m.rd(0x02000002, 2) == 0xCDEF, "CB 1: half")
  check(m.rd(0x02000004, 4) == 0x01234567, "CB 2: word")
  check(m.rd(0x02000010, 2) == 15, "CB 3: half add")
  check(m.rd(0x02000014, 4) == 3, "CB 38: word add")
  check(m.rd(0x02000020, 1) == 0xFF, "CB 7: OR")
  check(m.rd(0x02000021, 1) == 0, "CB 7: AND")
  check(m.rd(0x02000104, 1) == 0xEE, "CB 6: [[X]+Z] = YY")
  check(m.rd(0x02000200, 1) == 1 and m.rd(0x02000202, 1) == 3 and m.rd(0x02000204, 1) == 5,
        "CB 4: byte fill, step 2, value + 2")
  check(m.rd(0x02000300, 1) == 0, "CB D: false skips its line")
  check(m.rd(0x02000301, 1) == 1, "CB D: true runs it")
  check("another game" in refused("8000ABCD 11111111\n02000000 00000001", GAME), "CB other game")
  check("encrypted" in refused("0000ABCD " & toHex(be, 8) & "\n02000000 00000001", GAME),
        "CB encrypted refused")
  check("hook" in refused(hdr & "A0000000 00000000", GAME), "CB hooks refused")
  check("BEEFC0DE" in refused(hdr & "BEEFC0DE 00000000", GAME), "CB key change refused")

if failures > 0:
  echo failures, " failed"
  quit 1
echo "nds_cheats_test: all passed"
