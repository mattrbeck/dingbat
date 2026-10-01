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

# ---------------------------------------------------------------------------
# ARM9 protection unit aborts (nds-examples exceptionTest: a store to
# 0x2000, outside every region, must reach libnds's data-abort handler)

block protection_unit:
  echo "protection unit"
  const
    STR_R1_R0 = 0xE580_1000'u32       # str r1, [r0]
    LDR_R2_R0 = 0xE590_2000'u32       # ldr r2, [r0]
    LDM_USER = 0xE8D0_0006'u32        # ldmia r0, {r1, r2}^
    BX_R0 = 0xE12F_FF10'u32           # bx r0
  proc setup(n: NDS; ap_main: uint32) =
    ## Region 0: everything at AP 3 except what region 1 overrides;
    ## region 1: palette 0x05000000-0x0500FFFF at `ap_main`; region 2:
    ## 0x05010000-0x0501FFFF (palette mirrors), no access (AP 0);
    ## 0x0C000000+ is outside region 0 (0x00000000-0x07FFFFFF) and so
    ## background. (Data accesses to main RAM and DTCM are not checked:
    ## bus9.nim pu_check9.)
    let b = Arm9Bus(nds: n)
    b.cp15_write(0, 9, 1, 1, 0)              # ITCM off the low addresses
    b.cp15_write(0, 6, 0, 0, 0x0000_0035'u32)  # 0, 2^27 = 128 MB
    b.cp15_write(0, 6, 1, 0, 0x0500_001F'u32)  # 0x05000000, 2^16
    b.cp15_write(0, 6, 2, 0, 0x0501_001F'u32)  # 0x05010000, 2^16
    b.cp15_write(0, 6, 7, 0, 0xFFFF_0017'u32)  # BIOS 4 KB, for the vectors
    b.cp15_write(0, 5, 0, 2, 0x3000_0003'u32 or (ap_main shl 4))
    b.cp15_write(0, 5, 0, 3, 0x3000_0003'u32)
    b.cp15_write(0, 1, 0, 0, n.cp15.control or 1)   # PU on
    n.arm9.set_cpsr(uint32(mSYS))

  block:
    let n = machine()
    n.setup(5)                               # palette privileged read-only
    n.gpu.palette[0x80] = 0x78
    n.arm9.r[0] = 0x0500_0100; n.arm9.r[1] = 0xAABB_CCDD'u32
    n.run9(STR_R1_R0)
    check (n.arm9.cpsr and 0x1F) == uint32(mABT), "store to a read-only region: data abort (ABT mode)"
    check n.arm9.next_pc == 0xFFFF_0010'u32, "vector 0x10 at the high vector base",
          "pc=" & $n.arm9.next_pc
    check n.arm9.r[14] == 0x0200_0108'u32, "lr_abt = opcode + 8"
    check n.gpu.palette[0x80] == 0x78, "the refused store wrote nothing"
    check (n.arm9.spsr and 0x1F) == uint32(mSYS), "SPSR_abt holds the caller's mode"

  block:
    let n = machine()
    n.setup(5)
    n.arm9.r[0] = 0x0500_0100
    n.gpu.palette[0x80] = 0x5A
    n.run9(LDR_R2_R0)
    check (n.arm9.cpsr and 0x1F) == uint32(mSYS) and n.arm9.r[2] == 0x5A,
          "load from a privileged read-only region: no abort"

  block:
    let n = machine()
    n.setup(3)
    n.arm9.r[0] = 0x0C00_0000
    n.run9(STR_R1_R0)
    check (n.arm9.cpsr and 0x1F) == uint32(mABT), "store to the background region: data abort"

  block:
    let n = machine()
    n.setup(3)
    n.arm9.r[0] = 0x0501_0000
    n.run9(LDR_R2_R0)
    check (n.arm9.cpsr and 0x1F) == uint32(mABT), "load from an AP 0 region: data abort"

  block:
    let n = machine()
    n.setup(2)                               # privileged R/W, user read-only
    n.arm9.set_cpsr(uint32(mUSR))
    n.arm9.r[0] = 0x0500_0100
    n.run9(LDR_R2_R0)
    check (n.arm9.cpsr and 0x1F) == uint32(mUSR), "AP 2: user-mode load allowed"
    n.run9(STR_R1_R0)
    check (n.arm9.cpsr and 0x1F) == uint32(mABT), "AP 2: user-mode store aborts"

  block:
    # SoulSilver: its scheduler's ldmia rX, {..}^ runs in a privileged mode
    # over AP 1 (privileged-only) RAM; the user-bank transfer must not
    # count as a user-mode access
    let n = machine()
    n.setup(1)
    n.arm9.set_cpsr(uint32(mIRQ))
    n.arm9.r[0] = 0x0500_0100
    n.run9(LDM_USER)
    check (n.arm9.cpsr and 0x1F) == uint32(mIRQ), "LDM^ (user bank) from IRQ mode over AP 1: no abort"

  block:
    let n = machine()
    n.setup(3)
    n.arm9.r[0] = 0x0C00_0000
    n.run9(BX_R0)
    n.arm9.step()                            # the fetch at 0x0C000000
    check (n.arm9.cpsr and 0x1F) == uint32(mABT) and n.arm9.next_pc == 0xFFFF_000C'u32,
          "fetch from the background region: prefetch abort (vector 0x0C)"
    check n.arm9.r[14] == 0x0C00_0004'u32, "lr_abt = opcode + 4"

  block:
    let n = machine()                        # PU off: nothing aborts
    n.arm9.r[0] = 0x0C00_0000
    n.arm9.set_cpsr(uint32(mSYS))
    n.run9(STR_R1_R0)
    check (n.arm9.cpsr and 0x1F) == uint32(mSYS), "protection unit off: no abort"

if failures > 0:
  echo failures, " failed"
  quit(1)
echo "all passed"
