## Integration test: prove that an enabled cheat, once parsed, is written into
## live emulator memory by the per-frame apply_cheats hook on both cores.
##   nim c -r -d:release --path:src -o:/tmp/cheat_int tests/cheats_integration_test.nim

import dingbat/gb/gb
import dingbat/gba/gba
import dingbat/common/cheats

var failures = 0
template check(label: string; cond: untyped) =
  if cond: echo "  ok  ", label
  else:
    echo "  FAIL ", label
    inc failures

echo "== GB GameShark writes WRAM via apply_cheats =="
block:
  let gb = new_gb("", "tests/roms/gblinktest.gb", fifo = false, headless = true, run_bios = false)
  gb.post_init()
  # 014200C0 -> write 0x42 to 0xC000 (WRAM, byte-swapped address).
  var c = Cheat(name: "poke", codes: "014200C0", enabled: true)
  gb.cheats.reparse(c)
  check "parsed", c.error.len == 0 and c.ops.len == 1
  gb.cheats.cheats.add c
  gb.apply_cheats()
  check "0xC000 == 0x42", read_byte(gb.memory, gb, 0xC000) == 0x42'u8
  # Disable -> value no longer forced (write it away, re-apply, stays away).
  gb.cheats.cheats[0].enabled = false
  write_byte(gb.memory, gb, 0xC000, 0x00'u8)
  gb.apply_cheats()
  check "disabled cheat does nothing", read_byte(gb.memory, gb, 0xC000) == 0x00'u8

echo "== GBA raw code writes EWRAM via apply_cheats =="
block:
  let gba = new_gba("", "tests/roms/attachtest.gba", run_bios = false)
  gba.post_init()
  # raw PARv3 32-bit assign of 0x000000AB to 0x02002000 (EWRAM).
  var c = Cheat(name: "poke", codes: "04202000 000000AB", format: cfGbaRaw, enabled: true)
  gba.cheats.reparse(c)
  check "parsed", c.error.len == 0 and c.ops.len == 1
  check "is a 32-bit write", c.ops[0].action == caWrite32
  gba.cheats.cheats.add c
  gba.apply_cheats()
  check "0x02002000 == 0xAB", gba.bus.read_word_internal(0x02002000'u32) == 0xAB'u32

echo ""
if failures == 0: echo "ALL CHEAT INTEGRATION TESTS PASSED"
else:
  echo failures, " FAILURES"
  quit(1)
