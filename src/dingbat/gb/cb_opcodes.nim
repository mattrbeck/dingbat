# GB SM83 CPU CB-prefixed opcodes (included by gb.nim)
#
# The 256-entry dispatch table is generated at compile time (cbLutBuilder at
# the bottom) from the SM83 CB decode grid: every sub-opcode splits into a
# 2-bit quadrant, a 3-bit op/bit index, and a 3-bit operand:
#
#   00 ooo rrr   rot/shift op ooo on rrr  (RLC RRC RL RR SLA SRA SWAP SRL)
#   01 bbb rrr   BIT bbb,rrr
#   10 bbb rrr   RES bbb,rrr
#   11 bbb rrr   SET bbb,rrr
#
# with operand rrr = B C D E H L (HL) A.

# Rotate/shift helpers

proc cb_rlc(cpu: GbCpu; val: uint8): uint8 =
  cpu.fc = (val shr 7) != 0
  result = (val shl 1) or (val shr 7)
  cpu.fz = result == 0; cpu.fn = false; cpu.fh = false

proc cb_rrc(cpu: GbCpu; val: uint8): uint8 =
  cpu.fc = (val and 1) != 0
  result = (val shr 1) or (val shl 7)
  cpu.fz = result == 0; cpu.fn = false; cpu.fh = false

proc cb_rl(cpu: GbCpu; val: uint8): uint8 =
  let old_c = cpu.fc
  cpu.fc = (val shr 7) != 0
  result = (val shl 1) or (if old_c: 1'u8 else: 0'u8)
  cpu.fz = result == 0; cpu.fn = false; cpu.fh = false

proc cb_rr(cpu: GbCpu; val: uint8): uint8 =
  let old_c = cpu.fc
  cpu.fc = (val and 1) != 0
  result = (val shr 1) or (if old_c: 0x80'u8 else: 0'u8)
  cpu.fz = result == 0; cpu.fn = false; cpu.fh = false

proc cb_sla(cpu: GbCpu; val: uint8): uint8 =
  cpu.fc = (val shr 7) != 0
  result = val shl 1
  cpu.fz = result == 0; cpu.fn = false; cpu.fh = false

proc cb_sra(cpu: GbCpu; val: uint8): uint8 =
  cpu.fc = (val and 1) != 0
  result = (val shr 1) or (val and 0x80)
  cpu.fz = result == 0; cpu.fn = false; cpu.fh = false

proc cb_swap(cpu: GbCpu; val: uint8): uint8 =
  result = ((val and 0xF) shl 4) or (val shr 4)
  cpu.fz = result == 0; cpu.fc = false; cpu.fn = false; cpu.fh = false

proc cb_srl(cpu: GbCpu; val: uint8): uint8 =
  cpu.fc = (val and 1) != 0
  result = val shr 1
  cpu.fz = result == 0; cpu.fn = false; cpu.fh = false

# Generic handlers on the decode-grid fields. Cycles: register ops 8 (CB fetch
# + sub-opcode fetch), (HL) BIT 12 (+ read), (HL) read-modify-write 16
# (+ read + write). Each handler advances PC past the sub-opcode byte.

template operand(cpu: GbCpu; gb: GB; r: static int): uint8 =
  when r == 0: cpu.b
  elif r == 1: cpu.c
  elif r == 2: cpu.d
  elif r == 3: cpu.e
  elif r == 4: cpu.h
  elif r == 5: cpu.l
  elif r == 6: cpu_memory_at_hl(cpu, gb)
  else:        cpu.a

template `operand=`(cpu: GbCpu; gb: GB; r: static int; val: uint8) =
  when r == 0: cpu.b = val
  elif r == 1: cpu.c = val
  elif r == 2: cpu.d = val
  elif r == 3: cpu.e = val
  elif r == 4: cpu.h = val
  elif r == 5: cpu.l = val
  elif r == 6: `cpu_memory_at_hl=`(cpu, gb, val)
  else:        cpu.a = val

proc cb_rot[op, r: static int](cpu: GbCpu; gb: GB): int =
  cpu_inc_pc(cpu)
  let res =
    when op == 0: cb_rlc(cpu, operand(cpu, gb, r))
    elif op == 1: cb_rrc(cpu, operand(cpu, gb, r))
    elif op == 2: cb_rl(cpu, operand(cpu, gb, r))
    elif op == 3: cb_rr(cpu, operand(cpu, gb, r))
    elif op == 4: cb_sla(cpu, operand(cpu, gb, r))
    elif op == 5: cb_sra(cpu, operand(cpu, gb, r))
    elif op == 6: cb_swap(cpu, operand(cpu, gb, r))
    else:         cb_srl(cpu, operand(cpu, gb, r))
  `operand=`(cpu, gb, r, res)
  when r == 6: 16 else: 8

proc cb_bit[n, r: static int](cpu: GbCpu; gb: GB): int =
  cpu_inc_pc(cpu)
  cpu.fz = (operand(cpu, gb, r) and (1'u8 shl n)) == 0
  cpu.fn = false; cpu.fh = true
  when r == 6: 12 else: 8

proc cb_res[n, r: static int](cpu: GbCpu; gb: GB): int =
  cpu_inc_pc(cpu)
  `operand=`(cpu, gb, r, operand(cpu, gb, r) and not (1'u8 shl n))
  when r == 6: 16 else: 8

proc cb_set[n, r: static int](cpu: GbCpu; gb: GB): int =
  cpu_inc_pc(cpu)
  `operand=`(cpu, gb, r, operand(cpu, gb, r) or (1'u8 shl n))
  when r == 6: 16 else: 8

# Dispatch table

macro cbLutBuilder(): untyped =
  result = newTree(nnkBracket)
  for i in 0'u32 ..< 256'u32:
    let n = int(i shr 3 and 7)   # rot/shift op in quadrant 00, bit index elsewhere
    let r = int(i and 7)         # operand: B C D E H L (HL) A
    result.add:
      checkBits i:
      of "00......": call("cb_rot", n, r)
      of "01......": call("cb_bit", n, r)
      of "10......": call("cb_res", n, r)
      else:          call("cb_set", n, r)

const CB_PREFIXED* = cbLutBuilder()
