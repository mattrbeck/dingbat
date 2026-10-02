## Fixes from the homebrew compatibility sweep (docs/nds/compat.md), each
## pinned on the whole machine: a tiny synthesized cart boots (HLE BIOS),
## then single instructions run on the ARM9 / ARM7 through the real bus
## maps, or registers are driven as the CPUs would. Expected values cite
## GBATEK or the test ROM that showed the bug.
##
## Run with: nimble test_ndscompat

import std/os
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
    # control-only writes switch the unit without rebuilding the tables
    # (the BIOS toggles it in a loop): off lets the store through, on
    # refuses it again
    let n = machine()
    n.setup(5)
    let b = Arm9Bus(nds: n)
    n.arm9.r[0] = 0x0500_0100; n.arm9.r[1] = 0x1111
    b.cp15_write(0, 1, 0, 0, n.cp15.control and not 1'u32)
    n.run9(STR_R1_R0)
    check (n.arm9.cpsr and 0x1F) == uint32(mSYS) and n.gpu.palette[0x80] == 0x1111,
          "PU switched off by a control write: the store goes through"
    b.cp15_write(0, 1, 0, 0, n.cp15.control or 1)
    n.run9(STR_R1_R0)
    check (n.arm9.cpsr and 0x1F) == uint32(mABT), "switched back on: the store aborts again"

  block:
    let n = machine()                        # PU off: nothing aborts
    n.arm9.r[0] = 0x0C00_0000
    n.arm9.set_cpsr(uint32(mSYS))
    n.run9(STR_R1_R0)
    check (n.arm9.cpsr and 0x1F) == uint32(mSYS), "protection unit off: no abort"

# ---------------------------------------------------------------------------
# ARM9 branch refill also for a jump back into the word just fetched: a
# two-opcode Thumb loop (SUB/BGT, WaitByLoop's) costs 4 cycles a pass with
# the code cached (GBATEK "WaitByLoop": 20BAh*2 passes per ms at 67 MHz)

block branch_refill:
  echo "ARM9 branch refill"
  proc loop_cycles(passes: uint32): int64 =
    let n = machine()
    Arm9Bus(nds: n).cp15_write(0, 1, 0, 0, n.cp15.control or 0x1005)  # PU + caches
    for (a, v) in [(0x100, 0x3801'u16), (0x102, 0xDCFD'u16), (0x104, 0xE7FE'u16)]:
      n.main_ram[a] = uint8(v); n.main_ram[a + 1] = uint8(v shr 8)
    n.arm9.set_cpsr(uint32(mSYS) or FLAG_T)
    n.arm9.r[0] = passes
    n.arm9.next_pc = 0x0200_0100
    var k = 0
    while n.arm9.next_pc != 0x0200_0104'u32 and k < 100_000:
      n.arm9.step(); inc k
    n.arm9.cycles
  let per = (loop_cycles(300) - loop_cycles(100)) div 200
  check per == 4, "Thumb SUB/BGT loop: 4 ARM9 cycles a pass", $per & " cycles"

# ---------------------------------------------------------------------------
# HLE BIOS SWIs cost what the BIOS's own code costs in this core (an HLE
# run of nds-examples allocation_test ran a frame ahead of the real BIOS)

block hle_swi_cost:
  echo "HLE SWI cycles"
  let dir = getEnv("DINGBAT_NDS_BIOS")
  if dir.len == 0 or not fileExists(dir / "bios9.bin"):
    echo "  (skipped: no BIOS dumps in $DINGBAT_NDS_BIOS)"
  else:
    let bios9 = cast[seq[uint8]](readFile(dir / "bios9.bin"))
    let bios7 = cast[seq[uint8]](readFile(dir / "bios7.bin"))
    proc cost(hle, arm9: bool; num: uint32; regs: openArray[uint32]): int64 =
      let n = new_nds(tiny_rom(), bios9, bios7, @[], force_hle = hle)
      let code = if arm9: 0x0200_0100'u32 else: 0x0380_0100'u32
      if arm9:   # protection unit and caches on, as programs run
        Arm9Bus(nds: n).cp15_write(0, 1, 0, 0, n.cp15.control or 0x1005)
      template go(cpu: untyped; B: typedesc) =
        let b = B(nds: n)
        b.write32(code, 0xEF000000'u32 or (num shl 16))
        cpu.set_mode_sp(mSVC, (if arm9: 0x0080_3F00'u32 else: 0x0380_FF00'u32))
        cpu.set_mode_sp(mSYS, (if arm9: 0x0080_3D00'u32 else: 0x0380_F000'u32))
        cpu.set_cpsr(uint32(mSYS) or FLAG_I or FLAG_F)
        for i, v in regs: cpu.r[i] = v
        cpu.next_pc = code
        let t0 = cpu.cycles
        var k = 0
        while cpu.next_pc != code + 4 and k < 1_000_000:
          cpu.step(); inc k
        result = cpu.cycles - t0
      if arm9: go(n.arm9, Arm9Bus) else: go(n.arm7, Arm7Bus)
    for arm9 in [true, false]:
      for (name, num, r2) in [("CpuSet copy 16", 0x0B'u32, 200'u32),
                              ("CpuSet fill 32", 0x0B'u32, 200'u32 or (5'u32 shl 24)),
                              ("CpuFastSet copy", 0x0C'u32, 200'u32),
                              ("GetCRC16", 0x0E'u32, 300'u32)]:
        let regs = if num == 0x0E: @[0xFFFF'u32, 0x0200_1000'u32, r2]
                   else: @[0x0200_1000'u32, 0x0200_8000'u32, r2]
        let real = cost(false, arm9, num, regs)
        let hle = cost(true, arm9, num, regs)
        check abs(hle - real) * 50 <= real,
              (if arm9: "ARM9 " else: "ARM7 ") & name & ": HLE within 2% of the BIOS's cycles",
              "real " & $real & " hle " & $hle

# ---------------------------------------------------------------------------
# ARM7 memory timing (tests/nds/src/arm7_timing, built by
# tests/nds/tools/build_arm7_timing.sh): 256 passes of each loop, in bus
# cycles. Main-RAM data accesses follow GBATEK's "DS Memory Timings" NDS7/DATA
# row (N16 9, N32 10, S32 2: the reference runs are 3 cycles cheaper per
# nonsequential access, docs/oracles.md); branches cost 3 cycles where
# GBATEK's WaitByLoop table implies 4 (docs/nds/accuracy.md, open).

block arm7_timing:
  echo "ARM7 timing (arm7_timing ROM)"
  let path = getEnv("DINGBAT_NDS_ROMS", getHomeDir() / ".cache/dingbat-nds/roms") / "arm7_timing.nds"
  if not fileExists(path):
    echo "  (skipped: build it with tests/nds/tools/build_arm7_timing.sh)"
  else:
    let n = load_nds(path)
    for f in 0 ..< 10: n.run_frame()
    let b = Arm9Bus(nds: n)
    proc res(k: int): uint32 = b.read32(0x0220_0000'u32 + uint32(4 * k)) div 256
    check b.read32(0x0220_0000'u32) == 0x4952_4550'u32, "the ARM7 finished"
    check res(4) == 27, "8 LDRH from ARM7 WRAM + loop: 8 x 3 + 3", $res(4)
    check res(5) == 91, "8 LDRH from main RAM: 1S + N16 (9) + 1I each", $res(5)
    check res(6) == 99, "8 LDR from main RAM: 1S + N32 (10) + 1I each", $res(6)
    check res(7) == 91, "8 STR to main RAM: 1N code + N32 (10) each", $res(7)
    check res(8) == 29, "LDMIA 8 from main RAM: N32 + 7 S32 (2) + 1S + 1I", $res(8)
    check res(9) == 19, "8 MUL (one I each) + loop", $res(9)
    echo "  (info: Thumb SUB/BGT pass ", res(1), " cycles, BIOS WaitByLoop pass ", res(13),
         "; GBATEK's table: 4)"

# ---------------------------------------------------------------------------
# Power-off (ColecoDS, StellaDS, ... exit through libnds's shutdown: the ARM7
# writes power manager register 0 bit 6; GBATEK "DS Power Management
# Device": "DS System Power (0=Normal, 1=Shut Down)")

block power_off:
  echo "power-off"
  let n = machine()
  for f in 0..2: n.run_frame()
  for i in 0 ..< 256 * 192:
    n.gpu.top[i] = 0x7FFF; n.gpu.bottom[i] = 0x001F   # something on screen
  let b = Arm7Bus(nds: n)
  proc spi(v: uint16; hold: bool) =
    b.write16(0x0400_01C0'u32, 0x8002'u16 or (if hold: 0x800'u16 else: 0))  # PM, 1 MHz
    b.write16(0x0400_01C2'u32, v)
    n.run_until(n.sched.now + 2000)                  # the byte's time
  spi(0x00, true)                                    # register 0, write
  check not n.powered_off(), "the index byte alone doesn't power off"
  spi(0x40 or 0x0C, false)                           # backlights + shut down
  check n.powered_off(), "register 0 bit 6 powers the DS off"
  let t0 = n.sched.now
  let i9 = n.arm9.instr_count
  let i7 = n.arm7.instr_count
  let f0 = n.gpu.frame_count
  discard n.spu.take_samples()
  for f in 0..4: n.run_frame()
  check n.sched.now == t0 and n.arm9.instr_count == i9 and n.arm7.instr_count == i7,
        "both CPUs and the clock stop"
  check n.gpu.frame_count == f0 and n.spu.sample_count == 0, "no frames, no sound"
  var lit = 0
  for i in 0 ..< 256 * 192:
    if n.gpu.top[i] != 0 or n.gpu.bottom[i] != 0: inc lit
  check lit == 0, "both screens black", $lit & " lit pixels"
  n.set_button(nbA, true)
  n.set_touch(100, 100, true)
  n.run_frame()
  check n.powered_off() and n.sched.now == t0, "input doesn't turn it back on"

if failures > 0:
  echo failures, " failed"
  quit(1)
echo "all passed"
