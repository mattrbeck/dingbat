# GB SM83 CPU opcodes — unprefixed (included by gb.nim)

# Helper procs

proc cpu_add_a(cpu: GbCpu; val: uint8; with_carry: bool = false) {.inline.} =
  let carry = if with_carry and cpu.fc: 1'u8 else: 0'u8
  let result16 = uint16(cpu.a) + uint16(val) + uint16(carry)
  cpu.fh = (cpu.a and 0x0F) + (val and 0x0F) + carry > 0x0F
  cpu.fc = result16 > 0xFF
  cpu.a  = uint8(result16 and 0xFF)
  cpu.fz = cpu.a == 0
  cpu.fn = false

proc cpu_sub_a(cpu: GbCpu; val: uint8; with_carry: bool = false) {.inline.} =
  let carry = if with_carry and cpu.fc: 1'u8 else: 0'u8
  let result_i = int(cpu.a) - int(val) - int(carry)
  cpu.fh = (cpu.a and 0x0F) < (val and 0x0F) + carry
  cpu.fc = result_i < 0
  cpu.a  = uint8(result_i and 0xFF)
  cpu.fz = cpu.a == 0
  cpu.fn = true

proc cpu_and_a(cpu: GbCpu; val: uint8) {.inline.} =
  cpu.a = cpu.a and val
  cpu.fz = cpu.a == 0; cpu.fn = false; cpu.fh = true; cpu.fc = false

proc cpu_xor_a(cpu: GbCpu; val: uint8) {.inline.} =
  cpu.a = cpu.a xor val
  cpu.fz = cpu.a == 0; cpu.fn = false; cpu.fh = false; cpu.fc = false

proc cpu_or_a(cpu: GbCpu; val: uint8) {.inline.} =
  cpu.a = cpu.a or val
  cpu.fz = cpu.a == 0; cpu.fn = false; cpu.fh = false; cpu.fc = false

proc cpu_cp_a(cpu: GbCpu; val: uint8) {.inline.} =
  cpu.fz = cpu.a == val
  cpu.fh = (cpu.a and 0x0F) < (val and 0x0F)
  cpu.fc = cpu.a < val
  cpu.fn = true

proc cpu_inc8(cpu: GbCpu; val: uint8): uint8 {.inline.} =
  cpu.fh = (val and 0x0F) == 0x0F
  result = val + 1
  cpu.fz = result == 0
  cpu.fn = false

proc cpu_dec8(cpu: GbCpu; val: uint8): uint8 {.inline.} =
  result = val - 1
  cpu.fz = result == 0
  cpu.fh = (result and 0x0F) == 0x0F
  cpu.fn = true

proc cpu_add_hl(cpu: GbCpu; val: uint16) {.inline.} =
  cpu.fh = (uint32(cpu.hl and 0x0FFF) + uint32(val and 0x0FFF)) > 0x0FFF
  let old = cpu.hl
  cpu.hl = cpu.hl + val
  cpu.fc = cpu.hl < old
  cpu.fn = false

proc cpu_push16(cpu: GbCpu; gb: GB; val: uint16) {.inline.} =
  # Three OAM-bug M-cycles (oam_bug_access): the internal cycle with SP as the
  # IDU operand, then each write with its own destination on the bus. SP is
  # stepped one at a time so each check reads the value that M-cycle drove.
  oam_bug_if(gb, cpu.sp, obWrite)
  # Internal cycle before the writes.
  mem_tick_components(gb.memory, gb, 4)
  cpu.sp = cpu.sp - 1
  oam_bug_if(gb, cpu.sp, obWrite)
  mem_write(gb.memory, gb, int(cpu.sp), uint8(val shr 8))
  cpu.sp = cpu.sp - 1
  oam_bug_if(gb, cpu.sp, obWrite)
  mem_write(gb.memory, gb, int(cpu.sp), uint8(val and 0xFF))

proc cpu_pop16(cpu: GbCpu; gb: GB): uint16 {.inline.} =
  # Two OAM-bug M-cycles, one per read; the first carries the IDU step (Pan
  # Docs: "one read, one glitched write, and another read without a glitched
  # write"; oam_bug_access). Spelled out so each check sits on its own
  # M-cycle; the `+ 1'u16` wrap is mem_read_word's (gambatte
  # oamdma_src*_busypopFFFF).
  oam_bug_if(gb, cpu.sp, obReadWrite)
  let lo = mem_read(gb.memory, gb, int(cpu.sp))
  let hi_addr = cpu.sp + 1'u16
  oam_bug_if(gb, hi_addr, obRead)
  let hi = mem_read(gb.memory, gb, int(hi_addr))
  cpu.sp = cpu.sp + 2
  result = uint16(lo) or (uint16(hi) shl 8)

# Read two bytes (lo, hi) from PC and return as uint16, advancing PC twice.
proc cpu_read_u16(cpu: GbCpu; gb: GB): uint16 {.inline.} =
  let lo = uint16(mem_read(gb.memory, gb, int(cpu.pc))); cpu_inc_pc(cpu)
  let hi = uint16(mem_read(gb.memory, gb, int(cpu.pc))); cpu_inc_pc(cpu)
  result = (hi shl 8) or lo

# CB_PREFIXED is a const built in cb_opcodes.nim, which gb.nim must include
# before this file (a const cannot be forward-declared).

# Dispatch table

var UNPREFIXED* = [
  # 0x00 NOP
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    4,

  # 0x01 LD BC,u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.bc = cpu_read_u16(cpu, gb)
    12,

  # 0x02 LD (BC),A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    mem_write(gb.memory, gb, int(cpu.bc), cpu.a)
    8,

  # 0x03 INC BC
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    oam_bug_if(gb, cpu.bc, obWrite)
    cpu.bc = cpu.bc + 1
    8,

  # 0x04 INC B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.b = cpu_inc8(cpu, cpu.b)
    4,

  # 0x05 DEC B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.b = cpu_dec8(cpu, cpu.b)
    4,

  # 0x06 LD B,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.b = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    8,

  # 0x07 RLCA
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.a = (cpu.a shl 1) or (cpu.a shr 7)
    cpu.fc = (cpu.a and 0x01) != 0
    cpu.fz = false; cpu.fn = false; cpu.fh = false
    4,

  # 0x08 LD (u16),SP
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let u16 = cpu_read_u16(cpu, gb)
    mem_write_word(gb.memory, gb, int(u16), cpu.sp)
    20,

  # 0x09 ADD HL,BC
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_add_hl(cpu, cpu.bc)
    8,

  # 0x0A LD A,(BC)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.a = mem_read(gb.memory, gb, int(cpu.bc))
    8,

  # 0x0B DEC BC
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    oam_bug_if(gb, cpu.bc, obWrite)
    cpu.bc = cpu.bc - 1
    8,

  # 0x0C INC C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.c = cpu_inc8(cpu, cpu.c)
    4,

  # 0x0D DEC C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.c = cpu_dec8(cpu, cpu.c)
    4,

  # 0x0E LD C,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.c = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    8,

  # 0x0F RRCA
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.fc = (cpu.a and 0x01) != 0
    cpu.a = (cpu.a shr 1) or (cpu.a shl 7)
    cpu.fz = false; cpu.fn = false; cpu.fh = false
    4,

  # 0x10 STOP — one or two bytes; stop_instr decides which (Pan Docs' STOP
  # chart). The second increment is skipped on the leaves where the byte after
  # $10 is left to execute as an opcode of its own.
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    if stop_instr(gb.memory, gb): cpu_inc_pc(cpu)
    4,

  # 0x11 LD DE,u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.de = cpu_read_u16(cpu, gb)
    12,

  # 0x12 LD (DE),A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    mem_write(gb.memory, gb, int(cpu.de), cpu.a)
    8,

  # 0x13 INC DE
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    oam_bug_if(gb, cpu.de, obWrite)
    cpu.de = cpu.de + 1
    8,

  # 0x14 INC D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.d = cpu_inc8(cpu, cpu.d)
    4,

  # 0x15 DEC D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.d = cpu_dec8(cpu, cpu.d)
    4,

  # 0x16 LD D,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.d = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    8,

  # 0x17 RLA
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let old_carry = cpu.fc
    cpu.fc = (cpu.a and 0x80) != 0
    cpu.a = (cpu.a shl 1) or (if old_carry: 0x01'u8 else: 0x00'u8)
    cpu.fz = false; cpu.fn = false; cpu.fh = false
    4,

  # 0x18 JR i8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let offset = cast[int8](mem_read(gb.memory, gb, int(cpu.pc))); cpu_inc_pc(cpu)
    cpu.pc = uint16(int(cpu.pc) + int(offset))
    12,

  # 0x19 ADD HL,DE
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_add_hl(cpu, cpu.de)
    8,

  # 0x1A LD A,(DE)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.a = mem_read(gb.memory, gb, int(cpu.de))
    8,

  # 0x1B DEC DE
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    oam_bug_if(gb, cpu.de, obWrite)
    cpu.de = cpu.de - 1
    8,

  # 0x1C INC E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.e = cpu_inc8(cpu, cpu.e)
    4,

  # 0x1D DEC E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.e = cpu_dec8(cpu, cpu.e)
    4,

  # 0x1E LD E,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.e = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    8,

  # 0x1F RRA
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let old_carry = cpu.fc
    cpu.fc = (cpu.a and 0x01) != 0
    cpu.a = (cpu.a shr 1) or (if old_carry: 0x80'u8 else: 0x00'u8)
    cpu.fz = false; cpu.fn = false; cpu.fh = false
    4,

  # 0x20 JR NZ,i8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let offset = cast[int8](mem_read(gb.memory, gb, int(cpu.pc))); cpu_inc_pc(cpu)
    if not cpu.fz:
      cpu.pc = uint16(int(cpu.pc) + int(offset))
      return 12
    8,

  # 0x21 LD HL,u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.hl = cpu_read_u16(cpu, gb)
    12,

  # 0x22 LD (HL+),A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    oam_bug_if(gb, cpu.hl, obWrite)
    mem_write(gb.memory, gb, int(cpu.hl), cpu.a)
    cpu.hl = cpu.hl + 1
    8,

  # 0x23 INC HL
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    oam_bug_if(gb, cpu.hl, obWrite)
    cpu.hl = cpu.hl + 1
    8,

  # 0x24 INC H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.h = cpu_inc8(cpu, cpu.h)
    4,

  # 0x25 DEC H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.h = cpu_dec8(cpu, cpu.h)
    4,

  # 0x26 LD H,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.h = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    8,

  # 0x27 DAA
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    if not cpu.fn:
      if cpu.fc or cpu.a > 0x99:
        cpu.a = cpu.a + 0x60
        cpu.fc = true
      if cpu.fh or (cpu.a and 0x0F) > 0x09:
        cpu.a = cpu.a + 0x06
    else:
      if cpu.fc: cpu.a = cpu.a - 0x60
      if cpu.fh: cpu.a = cpu.a - 0x06
    cpu.fz = cpu.a == 0
    cpu.fh = false
    4,

  # 0x28 JR Z,i8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let offset = cast[int8](mem_read(gb.memory, gb, int(cpu.pc))); cpu_inc_pc(cpu)
    if cpu.fz:
      cpu.pc = uint16(int(cpu.pc) + int(offset))
      return 12
    8,

  # 0x29 ADD HL,HL
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.fh = (uint32(cpu.hl and 0x0FFF) + uint32(cpu.hl and 0x0FFF)) > 0x0FFF
    cpu.fc = cpu.hl > 0x7FFF
    cpu.hl = cpu.hl + cpu.hl
    cpu.fn = false
    8,

  # 0x2A LD A,(HL+)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    oam_bug_if(gb, cpu.hl, obReadWrite)
    cpu.a = mem_read(gb.memory, gb, int(cpu.hl))
    cpu.hl = cpu.hl + 1
    8,

  # 0x2B DEC HL
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    oam_bug_if(gb, cpu.hl, obWrite)
    cpu.hl = cpu.hl - 1
    8,

  # 0x2C INC L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.l = cpu_inc8(cpu, cpu.l)
    4,

  # 0x2D DEC L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.l = cpu_dec8(cpu, cpu.l)
    4,

  # 0x2E LD L,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.l = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    8,

  # 0x2F CPL
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.a = not cpu.a
    cpu.fn = true; cpu.fh = true
    4,

  # 0x30 JR NC,i8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let offset = cast[int8](mem_read(gb.memory, gb, int(cpu.pc))); cpu_inc_pc(cpu)
    if not cpu.fc:
      cpu.pc = uint16(int(cpu.pc) + int(offset))
      return 12
    8,

  # 0x31 LD SP,u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.sp = cpu_read_u16(cpu, gb)
    12,

  # 0x32 LD (HL-),A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    oam_bug_if(gb, cpu.hl, obWrite)
    mem_write(gb.memory, gb, int(cpu.hl), cpu.a)
    cpu.hl = cpu.hl - 1
    8,

  # 0x33 INC SP
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    oam_bug_if(gb, cpu.sp, obWrite)
    cpu.sp = cpu.sp + 1
    8,

  # 0x34 INC (HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let v = cpu_memory_at_hl(cpu, gb)
    let nv = cpu_inc8(cpu, v)
    `cpu_memory_at_hl=`(cpu, gb, nv)
    12,

  # 0x35 DEC (HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let v = cpu_memory_at_hl(cpu, gb)
    let nv = cpu_dec8(cpu, v)
    `cpu_memory_at_hl=`(cpu, gb, nv)
    12,

  # 0x36 LD (HL),u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let v = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    `cpu_memory_at_hl=`(cpu, gb, v)
    12,

  # 0x37 SCF
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.fc = true; cpu.fn = false; cpu.fh = false
    4,

  # 0x38 JR C,i8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let offset = cast[int8](mem_read(gb.memory, gb, int(cpu.pc))); cpu_inc_pc(cpu)
    if cpu.fc:
      cpu.pc = uint16(int(cpu.pc) + int(offset))
      return 12
    8,

  # 0x39 ADD HL,SP
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_add_hl(cpu, cpu.sp)
    8,

  # 0x3A LD A,(HL-)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    oam_bug_if(gb, cpu.hl, obReadWrite)
    cpu.a = mem_read(gb.memory, gb, int(cpu.hl))
    cpu.hl = cpu.hl - 1
    8,

  # 0x3B DEC SP
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    oam_bug_if(gb, cpu.sp, obWrite)
    cpu.sp = cpu.sp - 1
    8,

  # 0x3C INC A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.a = cpu_inc8(cpu, cpu.a)
    4,

  # 0x3D DEC A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.a = cpu_dec8(cpu, cpu.a)
    4,

  # 0x3E LD A,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.a = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    8,

  # 0x3F CCF
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.fc = not cpu.fc; cpu.fn = false; cpu.fh = false
    4,

  # 0x40 LD B,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.b = cpu.b
    when defined(test_harness):
      # mooneye's magic breakpoint: LD B,B ends a test, Fibonacci 3/5/8/13/21/34
      # in BCDEHL on pass, $42 in all six on failure. Only those two signatures
      # may finish the run (blargg executes LD B,B mid-test). A mooneye
      # ASSERTION failure matches neither (its quit tail leaves A = $42 and the
      # print routine's leftovers in BCDEHL) and shows up as a TIMEOUT; run the
      # ROM under --mode=screenshot to read the assertion.
      if gb.test_output != nil:
        if cpu.b == 3 and cpu.c == 5 and cpu.d == 8 and
           cpu.e == 13 and cpu.h == 21 and cpu.l == 34:
          gb.test_output.mooneye_result = 0
          gb.test_output.finished = true
        elif cpu.b == 0x42 and cpu.c == 0x42 and cpu.d == 0x42 and
             cpu.e == 0x42 and cpu.h == 0x42 and cpu.l == 0x42:
          gb.test_output.mooneye_result = 1
          gb.test_output.finished = true
        elif gb.test_output.bb_breakpoint:
          # Suites where LD B,B runs exactly once, at the end, and any
          # non-Fibonacci registers mean failure (AGE). Opt-in because of blargg.
          gb.test_output.mooneye_result = 1
          gb.test_output.finished = true
    4,

  # 0x41 LD B,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.b = cpu.c; 4,

  # 0x42 LD B,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.b = cpu.d; 4,

  # 0x43 LD B,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.b = cpu.e; 4,

  # 0x44 LD B,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.b = cpu.h; 4,

  # 0x45 LD B,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.b = cpu.l; 4,

  # 0x46 LD B,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.b = cpu_memory_at_hl(cpu, gb); 8,

  # 0x47 LD B,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.b = cpu.a; 4,

  # 0x48 LD C,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.c = cpu.b; 4,

  # 0x49 LD C,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.c = cpu.c; 4,

  # 0x4A LD C,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.c = cpu.d; 4,

  # 0x4B LD C,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.c = cpu.e; 4,

  # 0x4C LD C,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.c = cpu.h; 4,

  # 0x4D LD C,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.c = cpu.l; 4,

  # 0x4E LD C,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.c = cpu_memory_at_hl(cpu, gb); 8,

  # 0x4F LD C,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.c = cpu.a; 4,

  # 0x50 LD D,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.d = cpu.b; 4,

  # 0x51 LD D,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.d = cpu.c; 4,

  # 0x52 LD D,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.d = cpu.d; 4,

  # 0x53 LD D,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.d = cpu.e; 4,

  # 0x54 LD D,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.d = cpu.h; 4,

  # 0x55 LD D,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.d = cpu.l; 4,

  # 0x56 LD D,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.d = cpu_memory_at_hl(cpu, gb); 8,

  # 0x57 LD D,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.d = cpu.a; 4,

  # 0x58 LD E,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.e = cpu.b; 4,

  # 0x59 LD E,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.e = cpu.c; 4,

  # 0x5A LD E,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.e = cpu.d; 4,

  # 0x5B LD E,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.e = cpu.e; 4,

  # 0x5C LD E,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.e = cpu.h; 4,

  # 0x5D LD E,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.e = cpu.l; 4,

  # 0x5E LD E,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.e = cpu_memory_at_hl(cpu, gb); 8,

  # 0x5F LD E,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.e = cpu.a; 4,

  # 0x60 LD H,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.h = cpu.b; 4,

  # 0x61 LD H,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.h = cpu.c; 4,

  # 0x62 LD H,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.h = cpu.d; 4,

  # 0x63 LD H,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.h = cpu.e; 4,

  # 0x64 LD H,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.h = cpu.h; 4,

  # 0x65 LD H,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.h = cpu.l; 4,

  # 0x66 LD H,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.h = cpu_memory_at_hl(cpu, gb); 8,

  # 0x67 LD H,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.h = cpu.a; 4,

  # 0x68 LD L,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.l = cpu.b; 4,

  # 0x69 LD L,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.l = cpu.c; 4,

  # 0x6A LD L,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.l = cpu.d; 4,

  # 0x6B LD L,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.l = cpu.e; 4,

  # 0x6C LD L,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.l = cpu.h; 4,

  # 0x6D LD L,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.l = cpu.l; 4,

  # 0x6E LD L,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.l = cpu_memory_at_hl(cpu, gb); 8,

  # 0x6F LD L,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.l = cpu.a; 4,

  # 0x70 LD (HL),B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); `cpu_memory_at_hl=`(cpu, gb, cpu.b); 8,

  # 0x71 LD (HL),C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); `cpu_memory_at_hl=`(cpu, gb, cpu.c); 8,

  # 0x72 LD (HL),D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); `cpu_memory_at_hl=`(cpu, gb, cpu.d); 8,

  # 0x73 LD (HL),E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); `cpu_memory_at_hl=`(cpu, gb, cpu.e); 8,

  # 0x74 LD (HL),H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); `cpu_memory_at_hl=`(cpu, gb, cpu.h); 8,

  # 0x75 LD (HL),L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); `cpu_memory_at_hl=`(cpu, gb, cpu.l); 8,

  # 0x76 HALT
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_halt(cpu, gb)
    4,

  # 0x77 LD (HL),A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); `cpu_memory_at_hl=`(cpu, gb, cpu.a); 8,

  # 0x78 LD A,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.a = cpu.b; 4,

  # 0x79 LD A,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.a = cpu.c; 4,

  # 0x7A LD A,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.a = cpu.d; 4,

  # 0x7B LD A,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.a = cpu.e; 4,

  # 0x7C LD A,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.a = cpu.h; 4,

  # 0x7D LD A,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.a = cpu.l; 4,

  # 0x7E LD A,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.a = cpu_memory_at_hl(cpu, gb); 8,

  # 0x7F LD A,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu.a = cpu.a; 4,

  # 0x80 ADD A,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.b); 4,

  # 0x81 ADD A,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.c); 4,

  # 0x82 ADD A,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.d); 4,

  # 0x83 ADD A,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.e); 4,

  # 0x84 ADD A,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.h); 4,

  # 0x85 ADD A,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.l); 4,

  # 0x86 ADD A,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu_memory_at_hl(cpu, gb)); 8,

  # 0x87 ADD A,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.a); 4,

  # 0x88 ADC A,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.b, true); 4,

  # 0x89 ADC A,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.c, true); 4,

  # 0x8A ADC A,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.d, true); 4,

  # 0x8B ADC A,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.e, true); 4,

  # 0x8C ADC A,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.h, true); 4,

  # 0x8D ADC A,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.l, true); 4,

  # 0x8E ADC A,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu_memory_at_hl(cpu, gb), true); 8,

  # 0x8F ADC A,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_add_a(cpu, cpu.a, true); 4,

  # 0x90 SUB A,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.b); 4,

  # 0x91 SUB A,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.c); 4,

  # 0x92 SUB A,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.d); 4,

  # 0x93 SUB A,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.e); 4,

  # 0x94 SUB A,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.h); 4,

  # 0x95 SUB A,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.l); 4,

  # 0x96 SUB A,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu_memory_at_hl(cpu, gb)); 8,

  # 0x97 SUB A,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.a); 4,

  # 0x98 SBC A,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.b, true); 4,

  # 0x99 SBC A,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.c, true); 4,

  # 0x9A SBC A,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.d, true); 4,

  # 0x9B SBC A,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.e, true); 4,

  # 0x9C SBC A,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.h, true); 4,

  # 0x9D SBC A,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.l, true); 4,

  # 0x9E SBC A,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu_memory_at_hl(cpu, gb), true); 8,

  # 0x9F SBC A,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_sub_a(cpu, cpu.a, true); 4,

  # 0xA0 AND A,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_and_a(cpu, cpu.b); 4,

  # 0xA1 AND A,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_and_a(cpu, cpu.c); 4,

  # 0xA2 AND A,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_and_a(cpu, cpu.d); 4,

  # 0xA3 AND A,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_and_a(cpu, cpu.e); 4,

  # 0xA4 AND A,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_and_a(cpu, cpu.h); 4,

  # 0xA5 AND A,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_and_a(cpu, cpu.l); 4,

  # 0xA6 AND A,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_and_a(cpu, cpu_memory_at_hl(cpu, gb)); 8,

  # 0xA7 AND A,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_and_a(cpu, cpu.a); 4,

  # 0xA8 XOR A,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_xor_a(cpu, cpu.b); 4,

  # 0xA9 XOR A,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_xor_a(cpu, cpu.c); 4,

  # 0xAA XOR A,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_xor_a(cpu, cpu.d); 4,

  # 0xAB XOR A,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_xor_a(cpu, cpu.e); 4,

  # 0xAC XOR A,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_xor_a(cpu, cpu.h); 4,

  # 0xAD XOR A,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_xor_a(cpu, cpu.l); 4,

  # 0xAE XOR A,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_xor_a(cpu, cpu_memory_at_hl(cpu, gb)); 8,

  # 0xAF XOR A,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_xor_a(cpu, cpu.a); 4,

  # 0xB0 OR A,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_or_a(cpu, cpu.b); 4,

  # 0xB1 OR A,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_or_a(cpu, cpu.c); 4,

  # 0xB2 OR A,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_or_a(cpu, cpu.d); 4,

  # 0xB3 OR A,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_or_a(cpu, cpu.e); 4,

  # 0xB4 OR A,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_or_a(cpu, cpu.h); 4,

  # 0xB5 OR A,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_or_a(cpu, cpu.l); 4,

  # 0xB6 OR A,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_or_a(cpu, cpu_memory_at_hl(cpu, gb)); 8,

  # 0xB7 OR A,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_or_a(cpu, cpu.a); 4,

  # 0xB8 CP A,B
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_cp_a(cpu, cpu.b); 4,

  # 0xB9 CP A,C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_cp_a(cpu, cpu.c); 4,

  # 0xBA CP A,D
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_cp_a(cpu, cpu.d); 4,

  # 0xBB CP A,E
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_cp_a(cpu, cpu.e); 4,

  # 0xBC CP A,H
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_cp_a(cpu, cpu.h); 4,

  # 0xBD CP A,L
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_cp_a(cpu, cpu.l); 4,

  # 0xBE CP A,(HL)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_cp_a(cpu, cpu_memory_at_hl(cpu, gb)); 8,

  # 0xBF CP A,A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu); cpu_cp_a(cpu, cpu.a); 4,

  # 0xC0 RET NZ
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    if not cpu.fz:
      mem_tick_components(gb.memory, gb, 4)
      cpu.pc = cpu_pop16(cpu, gb)
      return 20
    8,

  # 0xC1 POP BC
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.bc = cpu_pop16(cpu, gb)
    12,

  # 0xC2 JP NZ,u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let u16 = cpu_read_u16(cpu, gb)
    if not cpu.fz:
      cpu.pc = u16
      return 16
    12,

  # 0xC3 JP u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.pc = cpu_read_u16(cpu, gb)
    16,

  # 0xC4 CALL NZ,u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let u16 = cpu_read_u16(cpu, gb)
    if not cpu.fz:
      cpu_push16(cpu, gb, cpu.pc)
      cpu.pc = u16
      return 24
    12,

  # 0xC5 PUSH BC
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_push16(cpu, gb, cpu.bc)
    16,

  # 0xC6 ADD A,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let v = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    cpu_add_a(cpu, v)
    8,

  # 0xC7 RST 0x00
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_push16(cpu, gb, cpu.pc)
    cpu.pc = 0x0000'u16
    16,

  # 0xC8 RET Z
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    if cpu.fz:
      mem_tick_components(gb.memory, gb, 4)
      cpu.pc = cpu_pop16(cpu, gb)
      return 20
    8,

  # 0xC9 RET
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.pc = cpu_pop16(cpu, gb)
    16,

  # 0xCA JP Z,u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let u16 = cpu_read_u16(cpu, gb)
    if cpu.fz:
      cpu.pc = u16
      return 16
    12,

  # 0xCB PREFIX CB
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let cb_op = mem_read(gb.memory, gb, int(cpu.pc))
    CB_PREFIXED[cb_op](cpu, gb),

  # 0xCC CALL Z,u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let u16 = cpu_read_u16(cpu, gb)
    if cpu.fz:
      cpu_push16(cpu, gb, cpu.pc)
      cpu.pc = u16
      return 24
    12,

  # 0xCD CALL u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let u16 = cpu_read_u16(cpu, gb)
    cpu_push16(cpu, gb, cpu.pc)
    cpu.pc = u16
    24,

  # 0xCE ADC A,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let v = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    cpu_add_a(cpu, v, true)
    8,

  # 0xCF RST 0x08
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_push16(cpu, gb, cpu.pc)
    cpu.pc = 0x0008'u16
    16,

  # 0xD0 RET NC
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    if not cpu.fc:
      mem_tick_components(gb.memory, gb, 4)
      cpu.pc = cpu_pop16(cpu, gb)
      return 20
    8,

  # 0xD1 POP DE
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.de = cpu_pop16(cpu, gb)
    12,

  # 0xD2 JP NC,u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let u16 = cpu_read_u16(cpu, gb)
    if not cpu.fc:
      cpu.pc = u16
      return 16
    12,

  # 0xD3 UNDEFINED — locks the CPU up (Pan Docs); see cpu_lock
  proc(cpu: GbCpu; gb: GB): int =
    cpu_lock(cpu); 4,

  # 0xD4 CALL NC,u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let u16 = cpu_read_u16(cpu, gb)
    if not cpu.fc:
      cpu_push16(cpu, gb, cpu.pc)
      cpu.pc = u16
      return 24
    12,

  # 0xD5 PUSH DE
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_push16(cpu, gb, cpu.de)
    16,

  # 0xD6 SUB A,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let v = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    cpu_sub_a(cpu, v)
    8,

  # 0xD7 RST 0x10
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_push16(cpu, gb, cpu.pc)
    cpu.pc = 0x0010'u16
    16,

  # 0xD8 RET C
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    if cpu.fc:
      mem_tick_components(gb.memory, gb, 4)
      cpu.pc = cpu_pop16(cpu, gb)
      return 20
    8,

  # 0xD9 RETI
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.ime = true
    cpu.pc = cpu_pop16(cpu, gb)
    16,

  # 0xDA JP C,u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let u16 = cpu_read_u16(cpu, gb)
    if cpu.fc:
      cpu.pc = u16
      return 16
    12,

  # 0xDB UNDEFINED — locks the CPU up (Pan Docs); see cpu_lock
  proc(cpu: GbCpu; gb: GB): int =
    cpu_lock(cpu); 4,

  # 0xDC CALL C,u16
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let u16 = cpu_read_u16(cpu, gb)
    if cpu.fc:
      cpu_push16(cpu, gb, cpu.pc)
      cpu.pc = u16
      return 24
    12,

  # 0xDD UNDEFINED — locks the CPU up (Pan Docs); see cpu_lock
  proc(cpu: GbCpu; gb: GB): int =
    cpu_lock(cpu); 4,

  # 0xDE SBC A,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let v = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    cpu_sub_a(cpu, v, true)
    8,

  # 0xDF RST 0x18
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_push16(cpu, gb, cpu.pc)
    cpu.pc = 0x0018'u16
    16,

  # 0xE0 LD (0xFF00+u8),A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let offset = uint16(mem_read(gb.memory, gb, int(cpu.pc))); cpu_inc_pc(cpu)
    mem_write(gb.memory, gb, int(0xFF00'u16 + offset), cpu.a)
    12,

  # 0xE1 POP HL
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.hl = cpu_pop16(cpu, gb)
    12,

  # 0xE2 LD (0xFF00+C),A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    mem_write(gb.memory, gb, int(0xFF00'u16 + uint16(cpu.c)), cpu.a)
    8,

  # 0xE3 UNDEFINED — locks the CPU up (Pan Docs); see cpu_lock
  proc(cpu: GbCpu; gb: GB): int =
    cpu_lock(cpu); 4,

  # 0xE4 UNDEFINED — locks the CPU up (Pan Docs); see cpu_lock
  proc(cpu: GbCpu; gb: GB): int =
    cpu_lock(cpu); 4,

  # 0xE5 PUSH HL
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_push16(cpu, gb, cpu.hl)
    16,

  # 0xE6 AND A,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let v = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    cpu_and_a(cpu, v)
    8,

  # 0xE7 RST 0x20
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_push16(cpu, gb, cpu.pc)
    cpu.pc = 0x0020'u16
    16,

  # 0xE8 ADD SP,i8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let raw = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    let offset = cast[int8](raw)
    let r = uint16(int(cpu.sp) + int(offset))
    # H/C use the UNSIGNED immediate byte (even though the sum is sign-extended).
    cpu.fh = ((cpu.sp and 0x000F'u16) + (uint16(raw) and 0x000F'u16)) > 0x000F'u16
    cpu.fc = ((cpu.sp and 0x00FF'u16) + (uint16(raw) and 0x00FF'u16)) > 0x00FF'u16
    cpu.sp = r
    cpu.fz = false; cpu.fn = false
    16,

  # 0xE9 JP HL
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.pc = cpu.hl
    4,

  # 0xEA LD (u16),A
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let u16 = cpu_read_u16(cpu, gb)
    mem_write(gb.memory, gb, int(u16), cpu.a)
    16,

  # 0xEB UNDEFINED — locks the CPU up (Pan Docs); see cpu_lock
  proc(cpu: GbCpu; gb: GB): int =
    cpu_lock(cpu); 4,

  # 0xEC UNDEFINED — locks the CPU up (Pan Docs); see cpu_lock
  proc(cpu: GbCpu; gb: GB): int =
    cpu_lock(cpu); 4,

  # 0xED UNDEFINED — locks the CPU up (Pan Docs); see cpu_lock
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    when defined(test_harness):
      # mooneye-wilbertpol's magic breakpoint is the undefined opcode 0xED
      # (2016 mooneye-gb), same Fibonacci verdict as LD B,B; anything else is
      # failure, since nothing but a breakpoint reaches an opcode that locks
      # hardware up. Opt-in (dingbat_test --ed-breakpoint).
      if gb.test_output != nil and gb.test_output.ed_breakpoint:
        if cpu.b == 3 and cpu.c == 5 and cpu.d == 8 and
           cpu.e == 13 and cpu.h == 21 and cpu.l == 34:
          gb.test_output.mooneye_result = 0
        else:
          gb.test_output.mooneye_result = 1
        gb.test_output.finished = true
    # Undefined on hardware: locks up unless the breakpoint above ended the run.
    cpu_lock(cpu); 4,

  # 0xEE XOR A,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let v = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    cpu_xor_a(cpu, v)
    8,

  # 0xEF RST 0x28
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_push16(cpu, gb, cpu.pc)
    cpu.pc = 0x0028'u16
    16,

  # 0xF0 LD A,(0xFF00+u8)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let offset = uint16(mem_read(gb.memory, gb, int(cpu.pc))); cpu_inc_pc(cpu)
    cpu.a = mem_read(gb.memory, gb, int(0xFF00'u16 + offset))
    12,

  # 0xF1 POP AF
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.af = cpu_pop16(cpu, gb) and 0xFFF0'u16
    12,

  # 0xF2 LD A,(0xFF00+C)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.a = mem_read(gb.memory, gb, int(0xFF00'u16 + uint16(cpu.c)))
    8,

  # 0xF3 DI
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.ime = false
    4,

  # 0xF4 UNDEFINED — locks the CPU up (Pan Docs); see cpu_lock
  proc(cpu: GbCpu; gb: GB): int =
    cpu_lock(cpu); 4,

  # 0xF5 PUSH AF
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_push16(cpu, gb, cpu.af)
    16,

  # 0xF6 OR A,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let v = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    cpu_or_a(cpu, v)
    8,

  # 0xF7 RST 0x30
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_push16(cpu, gb, cpu.pc)
    cpu.pc = 0x0030'u16
    16,

  # 0xF8 LD HL,SP+i8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let raw = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    let offset = cast[int8](raw)
    let r = uint16(int(cpu.sp) + int(offset))
    # H/C use the UNSIGNED immediate byte (even though the sum is sign-extended).
    cpu.fh = ((cpu.sp and 0x000F'u16) + (uint16(raw) and 0x000F'u16)) > 0x000F'u16
    cpu.fc = ((cpu.sp and 0x00FF'u16) + (uint16(raw) and 0x00FF'u16)) > 0x00FF'u16
    cpu.hl = r
    cpu.fz = false; cpu.fn = false
    12,

  # 0xF9 LD SP,HL
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu.sp = cpu.hl
    8,

  # 0xFA LD A,(u16)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let u16 = cpu_read_u16(cpu, gb)
    cpu.a = mem_read(gb.memory, gb, int(u16))
    16,

  # 0xFB EI (enable interrupts, delayed by one instruction via scheduler)
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    gb.scheduler.schedule_gb(4, etIME)
    4,

  # 0xFC UNDEFINED — locks the CPU up (Pan Docs); see cpu_lock
  proc(cpu: GbCpu; gb: GB): int =
    cpu_lock(cpu); 4,

  # 0xFD UNDEFINED — locks the CPU up (Pan Docs); see cpu_lock
  proc(cpu: GbCpu; gb: GB): int =
    cpu_lock(cpu); 4,

  # 0xFE CP A,u8
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    let v = mem_read(gb.memory, gb, int(cpu.pc)); cpu_inc_pc(cpu)
    cpu_cp_a(cpu, v)
    8,

  # 0xFF RST 0x38
  proc(cpu: GbCpu; gb: GB): int =
    cpu_inc_pc(cpu)
    cpu_push16(cpu, gb, cpu.pc)
    cpu.pc = 0x0038'u16
    16,
]
