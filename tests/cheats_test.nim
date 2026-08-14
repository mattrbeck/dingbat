## Unit tests for the cheat-code engine. Run standalone:
##   nim c -r -d:release --path:src -o:dingbat_cheat_test tests/cheats_test.nim

import std/[strformat, sequtils, tables]
import dingbat/common/cheats

# Address-keyed mock memory + hooks, for exercising apply_ram with arbitrary
# addresses (indirect pointers, KEYINPUT, etc.).
proc mock_mem(store: ref Table[uint32, uint8]): MemHooks =
  proc r8(a: uint32): uint8 = store[].getOrDefault(a, 0)
  MemHooks(
    read8: r8,
    read16: proc(a: uint32): uint16 = uint16(r8(a)) or (uint16(r8(a+1)) shl 8),
    read32: proc(a: uint32): uint32 =
      var v = 0'u32
      for i in 0u32..<4u32: v = v or (uint32(r8(a+i)) shl (i*8))
      v,
    write8: proc(a: uint32; v: uint8) = store[][a] = v,
    write16: proc(a: uint32; v: uint16) =
      store[][a] = uint8(v); store[][a+1] = uint8(v shr 8),
    write32: proc(a: uint32; v: uint32) =
      for i in 0u32..<4u32: store[][a+i] = uint8(v shr (i*8)))

var failures = 0
template check(label: string; cond: untyped) =
  if cond:
    echo "  ok  ", label
  else:
    echo "  FAIL ", label
    inc failures

echo "== GB GameShark =="
block:
  # Pokemon Red/Blue money: write 0x99 to 0xD347. Verified vector. The
  # leading digits are the SRAM bank (Pan Docs), carried in address bits
  # 16-23; only an $A000-BFFF target consults them (gb.nim apply_cheats).
  let (ops, err) = parse_cheat(cpGB, "019947D3")
  check "parses", err.len == 0 and ops.len == 1
  check "action write8", ops[0].action == caWrite8
  check &"address 0xD347 (got {ops[0].address and 0xFFFF:04X})",
    (ops[0].address and 0xFFFF) == 0xD347
  check &"bank 0x01 (got {ops[0].address shr 16:02X})",
    (ops[0].address shr 16) == 0x01
  check &"value 0x99 (got {ops[0].value:02X})", ops[0].value == 0x99

echo "== GB Game Genie =="
block:
  # Decode via the mGBA formula; op1=first3, op2=next3, op3=last3.
  # Code 010-178-CE1: op1=0x010 op2=0x178 op3=0xCE1
  #   value = op1>>4 = 0x01
  #   address = (op1&0xF)<<8 | (op2>>4)&0xFF | ((op2&0xF)^0xF)<<12
  #           = 0x000 | 0x17 | (0x8^0xF)<<12 = 0x17 | 0x7000 = 0x7017
  let (ops, err) = parse_cheat(cpGB, "010-178-CE1")
  check "parses", err.len == 0 and ops.len == 1
  check "action rompatch", ops[0].action == caRomPatch
  check &"value 0x01 (got {ops[0].value:02X})", ops[0].value == 0x01
  check &"address 0x7017 (got {ops[0].address:04X})", ops[0].address == 0x7017
  check "has compare byte", ops[0].compare >= 0

block:
  # 6-digit (no compare) form still parses.
  let (ops, err) = parse_cheat(cpGB, "010-178")
  check "6-digit parses", err.len == 0 and ops.len == 1
  check "no compare", ops[0].compare == -1
  check "same address", ops[0].address == 0x7017

echo "== GBA cipher round-trips (PARv3 seeds) =="
block:
  const seeds = [0x7AA9648F'u32, 0x7FAE6994'u32, 0xC0EFAAD5'u32, 0x42712C57'u32]
  var ok = true
  for a in [0x02000000'u32, 0x03001234'u32, 0xDEADBEEF'u32, 0x00000000'u32]:
    for b in [0x00000063'u32, 0xFFFFFFFF'u32, 0x12345678'u32]:
      var e1 = a
      var e2 = b
      gba_gs_encrypt(e1, e2, seeds)
      var d1 = e1
      var d2 = e2
      gba_gs_decrypt(d1, d2, seeds)
      if d1 != a or d2 != b: ok = false
  check "decrypt(encrypt(x)) == x for all samples", ok

echo "== GBA PARv3: real FireRed master decrypts to game id + marker =="
block:
  # The authentic Pokémon FireRed (USA) master code. Its second word must
  # decrypt to op1=0x45525042 ('BPRE' = FireRed game id) + op2=0x001DC0DE.
  let (ops, err) = parse_cheat(cpGBA, "72BC6DFB E9CA5465\nA47FB2DC 1AF3CA86")
  check "master parses with no error", err.len == 0
  # Both lines are verification/game-id -> recognised, no-op (not a write).
  check "master is inert (no writes)", ops.allIt(it.action == caUnsupported)

echo "== GBA PARv3 raw opcode interpretation =="
block:
  # 8-bit assign to 0x02001234 = 0x63.  op1 encodes region+offset via _parAddr.
  let (ops, err) = parse_cheat(cpGBA, "00201234 00000063", cfGbaRaw)
  check "8-bit parses", err.len == 0 and ops.len == 1
  check "action write8", ops[0].action == caWrite8
  check &"addr 0x02001234 (got {ops[0].address:08X})", ops[0].address == 0x02001234'u32
  check &"value 0x63 (got {ops[0].value:02X})", ops[0].value == 0x63

block:
  # 16-bit assign to 0x03001000 = 0x1234 (width bits = 01).
  let (ops, err) = parse_cheat(cpGBA, "02301000 00001234", cfGbaRaw)
  check "16-bit parses", err.len == 0 and ops.len == 1
  check "action write16", ops[0].action == caWrite16
  check &"addr 0x03001000 (got {ops[0].address:08X})", ops[0].address == 0x03001000'u32
  check &"value 0x1234 (got {ops[0].value:04X})", ops[0].value == 0x1234

block:
  # 32-bit assign to 0x02002000 = 0xDEADBEEF (width bits = 10).
  let (ops, err) = parse_cheat(cpGBA, "04202000 DEADBEEF", cfGbaRaw)
  check "32-bit parses", err.len == 0 and ops.len == 1
  check "action write32", ops[0].action == caWrite32
  check &"addr 0x02002000 (got {ops[0].address:08X})", ops[0].address == 0x02002000'u32
  check &"value 0xDEADBEEF (got {ops[0].value:08X})", ops[0].value == 0xDEADBEEF'u32

block:
  # Conditional: IF [0x02000000](16-bit) == 0x0005 then next op (NEXT), else skip.
  let (ops, err) = parse_cheat(cpGBA, "0A200000 00000005", cfGbaRaw)
  check "cond parses", err.len == 0 and ops.len == 1
  check "action cond", ops[0].action == caCond
  check "cmp eq", ops[0].cmp == ccEq
  check "width 2", ops[0].width == 2
  check "skip 1", ops[0].skip == 1
  check &"addr 0x02000000 (got {ops[0].address:08X})", ops[0].address == 0x02000000'u32

echo "== GBA auto-detect raw vs encrypted (no format hint) =="
block:
  # Encrypted PARv3 (real Metroid Fusion infinite-health) via plain cfAuto:
  # must auto-decrypt to a 16-bit IWRAM write, no 'raw' flag needed.
  let (ops, err) = parse_cheat(cpGBA, "C746328A 2787B50A")
  check "encrypted auto-parses", err.len == 0 and ops.len == 1
  check "auto -> write16", ops[0].action == caWrite16
  check &"auto addr 0x03001310 (got {ops[0].address:08X})", ops[0].address == 0x03001310'u32
block:
  # A raw (unencrypted) PARv3 assign via plain cfAuto: must be detected as raw
  # (decrypting it would give garbage) and decode directly.
  let (ops, err) = parse_cheat(cpGBA, "00201234 00000063")
  check "raw auto-parses", err.len == 0 and ops.len == 1
  check "auto -> write8", ops[0].action == caWrite8
  check &"raw auto addr 0x02001234 (got {ops[0].address:08X})", ops[0].address == 0x02001234'u32

echo "== GBA raw CodeBreaker (short GameShark) =="
block:
  # Real FireRed code: 99x Rare Candy in PC = write16 0x0044 to 0x02025840.
  let (ops, err) = parse_cheat(cpGBA, "82025840 0044")
  check "rare-candy parses", err.len == 0 and ops.len == 1
  check "action write16", ops[0].action == caWrite16
  check &"addr 0x02025840 (got {ops[0].address:08X})", ops[0].address == 0x02025840'u32
  check &"value 0x0044 (got {ops[0].value:04X})", ops[0].value == 0x0044
block:
  # 8-bit CodeBreaker assign (type 3).
  let (ops, err) = parse_cheat(cpGBA, "3202584C 0001")
  check "8-bit CB parses", err.len == 0 and ops[0].action == caWrite8
  check &"CB addr 0x0202584C (got {ops[0].address:08X})", ops[0].address == 0x0202584C'u32
  check "CB value 0x01", ops[0].value == 0x01

echo "== GBA PARv3 ROM patch (walk-through-walls, two-line) =="
block:
  # Real Pokémon FireRed WTW: an op1==0 PATCH line + a value line. Together they
  # patch 16-bit 0x2100 at ROM 0x08058E2E.
  let (ops, err) = parse_cheat(cpGBA, "509197D3 542975F4\n78DA95DF 44018CB4")
  check "WTW parses", err.len == 0
  let patches = ops.filterIt(it.action == caRomPatch)
  check "produces a ROM patch", patches.len == 1
  if patches.len == 1:
    check &"patch addr 0x08058E2E (got {patches[0].address:08X})",
          patches[0].address == 0x08058E2E'u32
    check &"patch value 0x2100 (got {patches[0].value:04X})", patches[0].value == 0x2100
    check "patch width 2", patches[0].width == 2
block:
  # Applying that patch to a ROM image writes the two little-endian bytes.
  let eng = new_cheat_engine(cpGBA)
  var c = Cheat(name: "wtw", codes: "509197D3 542975F4\n78DA95DF 44018CB4", enabled: true)
  eng.reparse(c)
  eng.cheats.add c
  var rom = newSeq[byte](0x0100000)
  eng.apply_rom(rom)
  check "byte@0x58E2E == 0x00", rom[0x58E2E] == 0x00'u8
  check "byte@0x58E2F == 0x21", rom[0x58E2F] == 0x21'u8
  eng.revert_rom(rom)
  check "reverted", rom[0x58E2E] == 0x00'u8 and rom[0x58E2F] == 0x00'u8

echo "== GBA CodeBreaker OR / AND / ADD parse =="
block:
  let (o1, _) = parse_cheat(cpGBA, "22025840 0001")
  check "OR type", o1.len == 1 and o1[0].action == caOr and o1[0].value == 0x0001
  let (o2, _) = parse_cheat(cpGBA, "62025840 00FE")
  check "AND type", o2.len == 1 and o2[0].action == caAnd and o2[0].value == 0x00FE
  let (o3, _) = parse_cheat(cpGBA, "E2025840 0001")
  check "ADD type", o3.len == 1 and o3[0].action == caAdd and o3[0].value == 0x0001

echo "== apply OR / AND / ADD / cond against a mock memory =="
block:
  var ram: array[0x100, uint8]
  proc rd(a: uint32): uint32 =
    uint32(ram[a and 0xFF]) or (uint32(ram[(a+1) and 0xFF]) shl 8)
  let hooks = MemHooks(
    read8:  proc(a: uint32): uint8 = ram[a and 0xFF],
    read16: proc(a: uint32): uint16 = uint16(rd(a)),
    read32: proc(a: uint32): uint32 = rd(a) or (rd(a+2) shl 16),
    write8: proc(a: uint32; v: uint8) = ram[a and 0xFF] = v,
    write16: proc(a: uint32; v: uint16) =
      ram[a and 0xFF] = uint8(v); ram[(a+1) and 0xFF] = uint8(v shr 8),
    write32: proc(a: uint32; v: uint32) =
      for i in 0u32..<4u32: ram[(a+i) and 0xFF] = uint8(v shr (i*8)))
  let eng = new_cheat_engine(cpGBA)
  # OR sets bits, AND clears bits, ADD increments (all 16-bit @ 0x10).
  ram[0x10] = 0x0F
  eng.cheats.add Cheat(enabled: true, ops: @[
    CheatOp(action: caOr, address: 0x10, value: 0xF0, width: 2)])
  eng.apply_ram(hooks)
  check "OR: 0x0F | 0xF0 = 0xFF", ram[0x10] == 0xFF
  eng.cheats[0].ops[0] = CheatOp(action: caAnd, address: 0x10, value: 0x0F, width: 2)
  eng.apply_ram(hooks)
  check "AND: 0xFF & 0x0F = 0x0F", ram[0x10] == 0x0F
  eng.cheats[0].ops[0] = CheatOp(action: caAdd, address: 0x10, value: 0x01, width: 1)
  eng.apply_ram(hooks)
  check "ADD: 0x0F + 1 = 0x10", ram[0x10] == 0x10
  # Conditional gates the following write.
  ram[0x20] = 0x05
  eng.cheats[0].ops = @[
    CheatOp(action: caCond, address: 0x20, value: 0x05, width: 1, cmp: ccEq, skip: 1),
    CheatOp(action: caWrite8, address: 0x21, value: 0x99)]
  ram[0x21] = 0
  eng.apply_ram(hooks)
  check "cond true -> write applied", ram[0x21] == 0x99
  ram[0x20] = 0x00; ram[0x21] = 0
  eng.apply_ram(hooks)
  check "cond false -> write skipped", ram[0x21] == 0x00

echo "== GBA PARv3 indirect (pointer) write =="
block:
  # Raw PARv3 indirect: write16 0x0063 to *[0x03005008] + 0.
  let (ops, err) = parse_cheat(cpGBA, "42305008 00000063", cfGbaRaw)
  check "indirect parses", err.len == 0 and ops.len == 1
  check "action indirect", ops[0].action == caIndirect
  check &"pointer addr 0x03005008 (got {ops[0].address:08X})", ops[0].address == 0x03005008'u32
  check "width 2", ops[0].width == 2
  check "value 0x63", ops[0].value == 0x63
  # Apply: pointer at 0x03005008 -> 0x02001000; the write must land there.
  let store = new(Table[uint32, uint8])
  store[][0x03005008'u32] = 0x00  # little-endian 0x02001000
  store[][0x03005009'u32] = 0x10
  store[][0x0300500A'u32] = 0x00
  store[][0x0300500B'u32] = 0x02
  let eng = new_cheat_engine(cpGBA)
  eng.cheats.add Cheat(enabled: true, ops: ops)
  eng.apply_ram(mock_mem(store))
  check "wrote to *ptr = 0x02001000", store[].getOrDefault(0x02001000'u32) == 0x63

echo "== GBA PARv3 button activator (hold L+R) =="
block:
  # Raw PARv3 BUTTON_2 (16-bit) writing 0x0063 to 0x02001000, gated on a combo.
  let (ops, err) = parse_cheat(cpGBA, "00000000 12201000\n00000063 00000000", cfGbaRaw)
  check "button parses", err.len == 0
  check "emits gate + write", ops.len == 2 and
        ops[0].action == caIfButtons and ops[1].action == caWrite16
  check &"write addr 0x02001000 (got {ops[1].address:08X})", ops[1].address == 0x02001000'u32
  let eng = new_cheat_engine(cpGBA)
  eng.cheats.add Cheat(enabled: true, ops: ops)
  # KEYINPUT 0x04000130 is active-low. L=bit9(0x200), R=bit8(0x100).
  let store = new(Table[uint32, uint8])
  # Nothing held (0x03FF): write must be gated out.
  store[][0x04000130'u32] = 0xFF; store[][0x04000131'u32] = 0x03
  eng.apply_ram(mock_mem(store))
  check "not held -> no write", store[].getOrDefault(0x02001000'u32) == 0x00
  # L+R held: clear bits 8 and 9 -> 0x00FF.
  store[][0x04000130'u32] = 0xFF; store[][0x04000131'u32] = 0x00
  eng.apply_ram(mock_mem(store))
  check "L+R held -> write applied", store[].getOrDefault(0x02001000'u32) == 0x63

echo "== ROM patch apply / revert (Game Genie) =="
block:
  let eng = new_cheat_engine(cpGB)
  # Build a fake 64 KB ROM (4 banks) with a marker byte we can patch.
  var rom = newSeq[byte](0x10000)
  for i in 0 ..< rom.len: rom[i] = byte(i and 0xFF)
  let before0150 = rom[0x0150]
  # A bank-0 ROM patch with a matching compare byte (mirrors what Game Genie
  # decode produces; decode itself is covered by the Game Genie block above).
  var c = Cheat(name: "patch", enabled: true)
  c.ops = @[CheatOp(action: caRomPatch, address: 0x0150'u32, value: 0xAB'u32,
                    compare: int(before0150))]
  eng.cheats.add c
  eng.apply_rom(rom)
  check "0x0150 patched to 0xAB", rom[0x0150] == 0xAB'u8
  # A non-matching compare must leave the byte alone.
  eng.cheats.add Cheat(name: "nomatch", enabled: true, ops: @[
    CheatOp(action: caRomPatch, address: 0x0151'u32, value: 0xEE'u32,
            compare: int(rom[0x0151]) xor 0xFF)])
  eng.apply_rom(rom)
  check "0x0151 untouched (compare mismatch)", rom[0x0151] == byte(0x0151 and 0xFF)
  eng.revert_rom(rom)
  var reverted = true
  for i in 0 ..< rom.len:
    if rom[i] != byte(i and 0xFF): reverted = false
  check "fully reverted after revert", reverted
  check "0x0150 restored", rom[0x0150] == before0150

echo "== serialize / deserialize round-trip =="
block:
  let eng = new_cheat_engine(cpGB)
  eng.cheats.add Cheat(name: "Money", codes: "019947D3", enabled: true)
  eng.cheats.add Cheat(name: "GG lives", codes: "010-178-CE1", enabled: false)
  let text = eng.serialize()
  let eng2 = new_cheat_engine(cpGB)
  eng2.deserialize(text)
  check "count preserved", eng2.cheats.len == 2
  check "name preserved", eng2.cheats[0].name == "Money"
  check "enabled preserved", eng2.cheats[0].enabled == true
  check "disabled preserved", eng2.cheats[1].enabled == false
  check "codes reparse ok", eng2.cheats[0].error.len == 0 and eng2.cheats[0].ops.len == 1

echo ""
if failures == 0:
  echo "ALL CHEAT TESTS PASSED"
else:
  echo failures, " FAILURES"
  quit(1)
