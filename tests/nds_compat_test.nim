## Fixes from the homebrew compatibility sweep (docs/nds/compat.md), each
## pinned on the whole machine: a tiny synthesized cart boots (HLE BIOS),
## then single instructions run on the ARM9 / ARM7 through the real bus
## maps, or registers are driven as the CPUs would. Expected values cite
## GBATEK or the test ROM that showed the bug.
##
## Run with: nimble test_ndscompat

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

proc run9(n: NDS; instr: uint32; at = 0x0200_0100'u32) =
  ## One ARM instruction at `at` on the ARM9.
  for i in 0..3: n.main_ram[int(at and 0x3FFFFF) + i] = uint8(instr shr (8 * i))
  n.arm9.cpsr = n.arm9.cpsr and not FLAG_T
  n.arm9.next_pc = at
  n.arm9.step()

# ---------------------------------------------------------------------------
# Direct boot leaves the firmware's protection regions (scene_sd4k enables
# the PU after defining only its ITCM region and runs from main RAM)

block boot_regions:
  echo "direct boot CP15"
  let n = machine()
  check (n.cp15.control and 1) == 0, "protection unit off at the entry point"
  check n.cp15.prot_regions[1] == 0x0200_002B'u32, "region 1: main RAM 4 MB"
  check n.cp15.prot_regions[6] == 0xFFFF_001D'u32, "region 6: BIOS"
  check n.cp15.data_perm == 0x1511_1011'u32 and n.cp15.code_perm == 0x0510_0011'u32,
        "permissions as the firmware leaves them"
  # what sd4k's crt0 does: add region 5, turn the PU on, keep running
  let b = Arm9Bus(nds: n)
  b.cp15_write(0, 6, 5, 0, 0x0100_001D'u32)
  b.cp15_write(0, 1, 0, 0, n.cp15.control or 1)
  n.arm9.set_cpsr(uint32(mSYS))
  n.arm9.r[0] = 0x0200_0800
  n.run9(0xE590_2000'u32)                    # ldr r2, [r0]
  n.arm9.step()                              # b . at 0x02000104 (zeroed RAM: andeq)
  check (n.arm9.cpsr and 0x1F) == uint32(mSYS), "code and data in main RAM run with the PU on"

if failures > 0:
  echo failures, " failed"
  quit(1)
echo "all passed"
