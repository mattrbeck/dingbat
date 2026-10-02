## The DS CPU interpreter's edge cases, one instruction at a time on a flat
## 64 KB test bus, for both instantiations (ARMv5TE = ARM9, ARMv4T = ARM7):
##
##   nim c -r -d:test_harness --path:src tests/nds_cpu_test.nim
##
## Expected values are GBATEK's ("ARM CPU" chapters: ARMv5 deltas, LDM/STM
## writeback, CP15) or hardware results the wrestler ROMs encode
## (armwrestler, arm7wrestler, rockwrestler; tests/nds/README.md). Encodings
## were assembled with `clang -target armv5te-none-eabi`.

import dingbat/nds/arm/cpu

type
  TestBus = ref object
    mem: array[0x10000, uint8]
    cp15_pid: uint32
  V5Bus = object
    t: TestBus
  V4Bus = object
    t: TestBus

template armv5(_: typedesc[V5Bus]): bool = true
template armv5(_: typedesc[V4Bus]): bool = false

template bus_procs(B: typedesc) =
  proc read8(b: B; a: uint32): uint32 = uint32(b.t.mem[a and 0xFFFF])
  proc read16(b: B; a: uint32): uint32 = read8(b, a) or (read8(b, a + 1) shl 8)
  proc read32(b: B; a: uint32): uint32 = read16(b, a) or (read16(b, a + 2) shl 16)
  proc write8(b: B; a: uint32; v: uint8) = b.t.mem[a and 0xFFFF] = v
  proc write16(b: B; a: uint32; v: uint16) =
    write8(b, a, uint8(v)); write8(b, a + 1, uint8(v shr 8))
  proc write32(b: B; a: uint32; v: uint32) =
    write16(b, a, uint16(v)); write16(b, a + 2, uint16(v shr 16))
  proc fetch16(b: B; a: uint32): uint32 = read16(b, a)
  proc fetch32(b: B; a: uint32): uint32 = read32(b, a)
  proc irq_line(b: B): bool = false
  proc irq_wake(b: B): bool = false
  proc access_cycles(b: B): int64 = 0
  proc swi_hook(b: B; comment: uint32): bool = false
  proc cp15_read(b: B; op1, cn, cm, op2: uint32): uint32 =
    if cn == 13: b.t.cp15_pid else: 0x41059461'u32
  proc cp15_write(b: B; op1, cn, cm, op2, v: uint32) =
    if cn == 13: b.t.cp15_pid = v

bus_procs(V5Bus)
bus_procs(V4Bus)
dispatch_tables(V5Bus)
dispatch_tables(V4Bus)

var failures = 0

template check(name: string; cond: bool) =
  if not cond:
    inc failures
    echo "FAIL ", name

proc v5(): ArmCpu[V5Bus] =
  result = new_arm_cpu(V5Bus(t: TestBus()), 2)
  result.set_cpsr(uint32(mSYS))
proc v4(): ArmCpu[V4Bus] =
  result = new_arm_cpu(V4Bus(t: TestBus()), 4)
  result.set_cpsr(uint32(mSYS))

proc run_arm[B](c: ArmCpu[B]; instr: uint32; at = 0x100'u32) =
  ## Execute one ARM instruction placed at `at`.
  write32(c.bus, at, instr)
  c.cpsr = c.cpsr and not FLAG_T
  c.next_pc = at
  c.step()

proc run_thumb[B](c: ArmCpu[B]; instr: uint16; at = 0x100'u32) =
  write16(c.bus, at, instr)
  c.cpsr = c.cpsr or FLAG_T
  c.next_pc = at
  c.step()

const DATA = 0x1000'u32

proc fill[B](c: ArmCpu[B]) =
  for i in 0'u32 .. 15: write32(c.bus, DATA + i * 4, 0xA0000000'u32 + i)

# --- LDM/STM writeback (GBATEK; rockwrestler ARMv5 "LDM / STM") ----------

block:
  # ldmia r1!, {r1}: ARMv5 writes back when Rb is the only register
  let c = v5(); c.fill(); c.r[1] = DATA
  c.run_arm(0xE8B10002'u32)
  check "v5 ldm rb only -> writeback", c.r[1] == DATA + 4
  let d = v4(); d.fill(); d.r[1] = DATA
  d.run_arm(0xE8B10002'u32)
  check "v4 ldm rb in list -> loaded", d.r[1] == 0xA0000000'u32
block:
  # ldmia r2!, {r1-r3}: Rb not last -> writeback (v5), loaded (v4)
  let c = v5(); c.fill(); c.r[2] = DATA
  c.run_arm(0xE8B2000E'u32)
  check "v5 ldm rb not last -> writeback", c.r[2] == DATA + 12 and c.r[3] == 0xA0000002'u32
  let d = v4(); d.fill(); d.r[2] = DATA
  d.run_arm(0xE8B2000E'u32)
  check "v4 ldm rb not last -> loaded", d.r[2] == 0xA0000001'u32
block:
  # ldmia r3!, {r1-r3}: Rb last -> loaded value on both
  let c = v5(); c.fill(); c.r[3] = DATA
  c.run_arm(0xE8B3000E'u32)
  check "v5 ldm rb last -> loaded", c.r[3] == 0xA0000002'u32
block:
  # stmia r1!, {r0,r1}: Rb not first -> v4 stores the new base, v5 the old
  let c = v5(); c.r[0] = 7; c.r[1] = DATA
  c.run_arm(0xE8A10003'u32)
  check "v5 stm rb not first -> old base", read32(c.bus, DATA + 4) == DATA
  let d = v4(); d.r[0] = 7; d.r[1] = DATA
  d.run_arm(0xE8A10003'u32)
  check "v4 stm rb not first -> new base", read32(d.bus, DATA + 4) == DATA + 8
block:
  # ldmia r0!, {}: v5 transfers nothing, base += 0x40; v4 loads r15
  let c = v5(); c.fill(); c.r[0] = DATA
  c.run_arm(0xE8B00000'u32)
  check "v5 empty ldm", c.r[0] == DATA + 0x40 and c.next_pc == 0x104
  let d = v4(); d.fill(); d.r[0] = DATA
  d.run_arm(0xE8B00000'u32)
  check "v4 empty ldm loads pc", d.r[0] == DATA + 0x40 and d.next_pc == 0xA0000000'u32
block:
  # IRQ mode ldmia r13!, {r14}^: r14_usr loaded, writeback to r13_irq
  let c = v5(); c.fill()
  c.r[13] = 0x5555; c.r[14] = 0
  c.set_cpsr(uint32(mIRQ))
  c.r[13] = DATA; c.r[14] = 0
  c.run_arm(0xE8FD4000'u32)
  check "ldm^ writeback in irq bank", c.r[13] == DATA + 4 and c.r[14] == 0
  c.set_cpsr(uint32(mSYS))
  check "ldm^ loads usr r14", c.r[14] == 0xA0000000'u32 and c.r[13] == 0x5555
block:
  # Thumb ldmia r1!, {r1,r2}: no writeback on either core
  let c = v5(); c.fill(); c.r[1] = DATA
  c.run_thumb(0xC906'u16)
  check "v5 thumb ldmia rb in list", c.r[1] == 0xA0000000'u32 and c.r[2] == 0xA0000001'u32

# --- Loads into r15 -----------------------------------------------------

block:
  let c = v5(); c.r[0] = DATA
  write32(c.bus, DATA, 0x2001'u32)
  c.run_arm(0xE590F000'u32)                    # ldr pc, [r0]
  check "v5 ldr pc interworks", c.thumb and c.next_pc == 0x2000
  let n = v5(); n.r[0] = DATA; n.no_load_interwork = true
  write32(n.bus, DATA, 0x2001'u32)
  n.run_arm(0xE590F000'u32)
  check "v5 ldr pc with CP15 bit 15", not n.thumb and n.next_pc == 0x2000
  let d = v4(); d.r[0] = DATA
  write32(d.bus, DATA, 0x2001'u32)
  d.run_arm(0xE590F000'u32)
  check "v4 ldr pc stays ARM", not d.thumb and d.next_pc == 0x2000
block:
  let c = v5(); c.r[13] = DATA
  write32(c.bus, DATA, 0x3000'u32)
  c.run_thumb(0xBD00'u16)                      # pop {pc}
  check "v5 pop pc to ARM", not c.thumb and c.next_pc == 0x3000 and c.r[13] == DATA + 4

# --- Halfword loads -----------------------------------------------------

block:
  let c = v5(); c.r[0] = DATA + 1
  write32(c.bus, DATA, 0x8899AABB'u32)
  c.run_arm(0xE1D010B0'u32)                    # ldrh r1, [r0]
  check "v5 misaligned ldrh forced align", c.r[1] == 0xAABB'u32
  c.run_arm(0xE1D010F0'u32)                    # ldrsh r1, [r0]
  check "v5 misaligned ldrsh", c.r[1] == 0xFFFFAABB'u32
  let d = v4(); d.r[0] = DATA + 1
  write32(d.bus, DATA, 0x8899AABB'u32)
  d.run_arm(0xE1D010B0'u32)
  check "v4 misaligned ldrh rotates", d.r[1] == 0xBB0000AA'u32
  d.run_arm(0xE1D010F0'u32)
  check "v4 misaligned ldrsh = ldrsb", d.r[1] == 0xFFFFFFAA'u32

# --- ARMv5TE arithmetic -------------------------------------------------

block:
  let c = v5()
  c.r[1] = 0x7000_0000'u32; c.r[2] = 0x2000_0000'u32
  c.run_arm(0xE1020051'u32)                    # qadd r0, r1, r2
  check "qadd saturates", c.r[0] == 0x7FFF_FFFF'u32 and (c.cpsr and FLAG_Q) != 0
  c.cpsr = c.cpsr and not FLAG_Q
  c.r[1] = 0; c.r[2] = 0xC000_0000'u32         # 2 * -2^30 = -2^31: no saturation
  c.run_arm(0xE1420051'u32)                    # qdadd r0, r1, r2
  check "qdadd exact -2^31", c.r[0] == 0x8000_0000'u32 and (c.cpsr and FLAG_Q) == 0
  c.r[2] = 0xBFFF_FFFF'u32                     # doubling saturates first
  c.run_arm(0xE1420051'u32)
  check "qdadd doubling saturates", c.r[0] == 0x8000_0000'u32 and (c.cpsr and FLAG_Q) != 0
block:
  let c = v5()
  c.r[1] = 0x0001_0000'u32; c.r[2] = 0x0000_FFFF'u32; c.r[3] = 5
  c.run_arm(0xE1203281'u32)                    # smlawb r0, r1, r2, r3: (0x10000 * -1) >> 16 + 5
  check "smlawb", c.r[0] == 4
  c.r[2] = 0x0002_0000'u32
  c.run_arm(0xE12002E1'u32)                    # smulwt r0, r1, r2: (0x10000 * 2) >> 16
  check "smulwt", c.r[0] == 2
  c.r[0] = 0xFFFF_FFFF'u32; c.r[1] = 0; c.r[2] = 2; c.r[3] = 3
  c.run_arm(0xE1410382'u32)                    # smlalbb r0, r1, r2, r3
  check "smlalbb carries into hi", c.r[0] == 5 and c.r[1] == 1
block:
  let c = v5()
  c.r[1] = 0x0000_4D33'u32
  c.run_arm(0xE16F0F11'u32)                    # clz r0, r1
  check "clz", c.r[0] == 17
  c.r[1] = 0
  c.run_arm(0xE16F0F11'u32)
  check "clz 0", c.r[0] == 32
block:
  let c = v5()
  c.run_arm(0xFA000040'u32)                    # blx #0x100 (at 0x100)
  check "blx imm", c.thumb and c.next_pc == 0x208 and c.r[14] == 0x104
  let h = v5()
  h.run_arm(0xFB000040'u32)                    # H = 1: +2
  check "blx imm H", h.thumb and h.next_pc == 0x20A
block:
  let c = v5(); c.r[0] = 0x400
  c.run_thumb(0x4780'u16)                      # blx r0
  check "thumb blx reg", not c.thumb and c.next_pc == 0x400 and c.r[14] == 0x103

# --- Coprocessors -------------------------------------------------------

block:
  let c = v5(); c.r[0] = 0x12345678
  c.run_arm(0xEE0D0F30'u32)                    # mcr p15, 0, r0, c13, c0, 1
  c.run_arm(0xEE1D1F30'u32)                    # mrc p15, 0, r1, c13, c0, 1
  check "cp15 c13 round trip via bus", c.r[1] == 0x12345678
block:
  # ARM7: MRC p14 does not trap (arm7wrestler), MRC p15 does
  let d = v4(); d.r[0] = 99
  d.run_arm(0xEE100E10'u32)                    # mrc p14, 0, r0, c0, c0, 0
  check "v4 mrc p14 no trap", d.mode == uint32(mSYS) and d.r[0] == 0
  d.run_arm(0xEE100F10'u32)                    # mrc p15
  check "v4 mrc p15 traps", d.mode == uint32(mUND) and d.next_pc == 0x04
  let c = v5()
  c.run_arm(0xEE100E10'u32)
  check "v5 mrc p14 traps", c.mode == uint32(mUND)

# --- ARMv5-only opcodes on the ARM7 (arm7wrestler) ----------------------

block:
  let d = v4(); d.r[0] = DATA; d.r[2] = 1; d.r[3] = 2
  d.run_arm(0xE04020D1'u32)                    # ldrd r2, [r0], #-1
  check "v4 ldrd: no load, base written back",
        d.r[2] == 1 and d.r[3] == 2 and d.r[0] == DATA - 1 and d.mode == uint32(mSYS)
  let e = v4(); e.r[0] = 5; e.r[1] = 0x7000; e.r[2] = 0x7000; e.r[3] = 0x5000_0000
  e.run_arm(0xE1410382'u32)                    # smlalbb: nothing happens
  check "v4 smlalbb is a no-op", e.r[0] == 5 and e.r[1] == 0x7000 and e.mode == uint32(mSYS)
  let f = v4(); f.r[1] = 1
  f.run_arm(0xE16F0F11'u32)                    # clz: undefined
  check "v4 clz undefined", f.mode == uint32(mUND)
  let g = v4()
  g.run_arm(0xFA000040'u32)                    # cond NV: undefined on v4
  check "v4 cond NV undefined", g.mode == uint32(mUND)

# --- PSR ----------------------------------------------------------------

block:
  let c = v5(); c.r[0] = 0xF800_0000'u32
  c.run_arm(0xE128F000'u32)                    # msr cpsr_f, r0
  check "v5 msr sets Q", (c.cpsr and 0xF800_0000'u32) == 0xF800_0000'u32
  let d = v4(); d.r[0] = 0xF800_0000'u32
  d.run_arm(0xE128F000'u32)
  check "v4 msr has no Q", (d.cpsr and 0xF800_0000'u32) == 0xF000_0000'u32

if failures > 0:
  echo failures, " failure(s)"
  quit(1)
echo "nds cpu: all passed"
