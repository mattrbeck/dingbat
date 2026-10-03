# The BIOS's routines, run as BIOS code (included by hle_bios.nim)
#
# RegisterRamReset, IntrWait, VBlankIntrWait, Div, DivArm, Sqrt, ArcTan,
# ArcTan2, CpuSet, CpuFastSet, GetBiosChecksum, BgAffineSet, ObjAffineSet,
# the decompression and unpack family, SoundBias and MidiKey2Freq (unc_takes).
#
# LZ77UnCompWram/Vram, RLUnCompWram/Vram, HuffUnComp, BitUnPack and the Diff
# filters used to run as one HLE step: their output written up front, a cost
# model charged as routine time that stopped on the cycle an interrupt line
# rose, the remainder parked on the halt-resume path. A handler or the
# renderer saw the finished output mid-call (Top Gun - Combat Zones' fade
# drew tiles a long LZ77UnCompVram had not written yet on the console), an
# interrupt was taken up to an instruction early, and a DMA burst inside one
# stopped the whole model where the console grants it between the routine's
# own accesses and runs part of it under the routine's internal cycles
# (Castlevania - Circle of the Moon's sound FIFO bursts inside its
# cartridge LZ77UnCompWrams moved each call a cycle or two).
#
# Now each routine runs as instructions of its own in the stub BIOS. Every
# instruction is a `swi 0` at an address of its own (bus.nim UNC_ARM_LO ..,
# ARM, and UNC_THUMB_LO .., Thumb), and the HLE executes it by that address:
# the CPU fetches it (one BIOS cycle), and its body makes the console
# instruction's accesses and internal cycles through the same bus calls the
# core's ARM and Thumb handlers make, in the same order -- a load its
# access then an internal cycle, a store its access, a taken branch the
# refill -- and steps or branches to the next. So the CPU's own loop runs
# them: interrupts are taken at their boundaries (the stub's IRQ vector
# returns into the routine), DMA requests are granted between their accesses
# and under their internal cycles, renderer contention meets each access when
# it is made, the frame loop stops between two of them, and a save state
# holds a routine in progress in its registers, its stack frames and r15.
#
# The instruction sequence of each path is the console's: the playtest
# driver's per-instruction `trace` and tools/biosdrv/steptrace.nim of the
# official BIOS in this core give each step's cycles and accesses, and each
# label below is one such step (a store, a load, a one-cycle operation, a
# branch). The data each step works on is kept in registers chosen here,
# within the registers the console's routine is free to use (the ones it
# pushes, r0-r2 and r12; r3 where it hands it back changed), so the values a
# routine leaves in r0-r3 are the console's. The SWI's dispatch and return
# run the same way (the vector, the dispatcher's pushes on the SVC and System
# stacks, its read of the swi's comment byte in the caller's region, the
# `msr` into System mode with the caller's I bit, the pops, `movs pc, lr`),
# so an interrupt arriving between the dispatcher's `msr` and the routine is
# taken there too.
#
# Labels are this file's own numbering: nothing of the console's code or
# its addresses is in it, only each step's kind and timing.

type
  UA = enum
    ## ARM steps, at UNC_ARM_LO + 4 * ord. Execution falls through to the
    ## next label unless the body branches.
    # The SWI vector and the dispatcher
    uaVector, uaDPush3, uaDComment, uaD3, uaDTable, uaD5, uaDPushSpsr, uaD7,
    uaD8, uaDMsr, uaDPush2, uaDLr, uaDBx,
    # The dispatcher's return
    uaXPop2, uaX1, uaXMsr, uaXPopSpsr, uaXSpsr, uaXPop3, uaXMovs,
    # The source check every routine calls (Thumb ones through utV0)
    uaChk0, uaChk1, uaChk2, uaChk3, uaChk4, uaChk5, uaChkRet,
    # LZ77UnCompWram
    lwPush, lwHdr, lwA1, lwA2, lwBl, lwSkip, lwG0, lwG1, lwFlags, lwG3,
    lwT0, lwT1, lwT2, lwT3, lwLit, lwLitSt, lwL2, lwL3,
    lwB0, lwB1, lwB2, lwB3, lwB4, lwB5, lwB6, lwB7, lwB8, lwB9,
    lwCp, lwCpSt, lwCp2, lwCp3, lwC0, lwC1, lwC2, lwC3, lwPop, lwRet,
    # LZ77UnCompVram
    lvPush, lvA0, lvHdr, lvA1, lvA2, lvA3, lvBl, lvSkip, lvG0, lvG1, lvFlags,
    lvG3, lvT0, lvT1, lvT2, lvT3, lvLit, lvL1, lvL2, lvL3, lvLSt, lvL5, lvL6,
    lvB0, lvB1, lvB2, lvB3, lvB4, lvB5, lvB6, lvB7, lvB8, lvB9, lvB10, lvB11,
    lvB12, lvCp0, lvCp1, lvCp2, lvCp3, lvCp4, lvCpLd, lvCp6, lvCp7, lvCp8,
    lvCp9, lvCp10, lvCpSt, lvCp12, lvCp13, lvCp14, lvC0, lvC1, lvC2, lvC3,
    lvPop, lvRet,
    # HuffUnComp
    hfPush, hfA1, hfA2, hfBl, hfSkip, hfA4, hfA5, hfSize, hfA6, hfA7, hfA8,
    hfA9, hfA10, hfSpill, hfHdr, hfA11, hfTree, hfA12, hfA13, hfA14, hfW0,
    hfW1, hfW2, hfWord, hfB0, hfB1, hfB2, hfB3, hfNode1, hfB4, hfB5, hfB6,
    hfNode2, hfB7, hfB8, hfB9, hfB10, hfB11, hfBLeaf, hfL0, hfSym, hfL1,
    hfL2, hfL3, hfL4, hfRe, hfL5, hfSt, hfL6, hfL7, hfB16, hfB17, hfBLoop,
    hfWB, hfExit, hfPop, hfRet,
    # BitUnPack
    bpPush, bpA1, bpLen, bpA2, bpBl, bpSkip, bpSw, bpA3, bpA4, bpOff1, bpA5,
    bpOff2, bpA6, bpA7, bpSpill, bpDw, bpA8, bpY0, bpY1, bpY2, bpY3, bpByte,
    bpY4, bpU0, bpU1, bpU2, bpU3, bpU4, bpUZ, bpRe, bpU6, bpU7, bpU8, bpU9,
    bpUW, bpSt, bpU11, bpU12, bpU13, bpU14, bpUB, bpExit, bpPop, bpRet,
    # CpuFastSet
    fsPush, fsA1, fsA2, fsBl, fsSkip, fsA3, fsA4, fsBr, fsFillLd, fsF1, fsF2,
    fsF3, fsF4, fsF5, fsF6, fsF7, fsF8, fsFSt, fsF10, fsF11, fsC0, fsCLd,
    fsCSt, fsC3, fsPop, fsRet,
    # VBlankIntrWait, IntrWait and the check they halt round
    iwVbl0, iwVbl1, iwPush, iwA1, iwA2, iwA3, iwBl, iwHalt, iwBl2, iwLoop,
    iwPop, iwRet, icA, icIme0, icLd, icB, icC, icSt, icIme1, icRet,
    # DivArm (three swaps) and Div
    daS0, daS1, daS2, dvA0, dvA1, dvA2, dvA3, dvA4, dvL0, dvL1, dvL2,
    dvD0, dvD1, dvD2, dvD3, dvD4, dvD5, dvT0, dvT1, dvT2, dvT3, dvT4, dvRet,
    # BgAffineSet
    bgPush, bgL0, bgL1, bgAng, bgA1, bgA2, bgA3, bgA4, bgA5, bgSin, bgA6,
    bgCos, bgSx, bgSy, bgM1, bgA7, bgM2, bgA8, bgM3, bgA9, bgM4, bgA10,
    bgLdm, bgA11, bgA12, bgA13, bgA14, bgM5, bgM6, bgStX, bgA15, bgM7,
    bgA16, bgM8, bgStY, bgSt1, bgA17, bgSt2, bgSt3, bgSt4, bgA18, bgA19,
    bgB, bgPop, bgRet,
    # ObjAffineSet
    oaPush, oaL0, oaL1, oaAng, oaA1, oaA2, oaA3, oaA4, oaA5, oaSin, oaA6,
    oaCos, oaSx, oaSy, oaM1, oaA7, oaSt1, oaM2, oaA8, oaA9, oaSt2, oaM3,
    oaA10, oaSt3, oaM4, oaA11, oaSt4, oaA12, oaB, oaPop, oaRet,
    # GetBiosChecksum
    ckA0, ckA1, ckL0, ckLd, ckL2, ckL3, ckL4, ckBr, ckRet,
    # The long multiply MidiKey2Freq calls (through mvV0)
    muU, muA, muRet,
    # Sqrt
    sqPush, sqA0, sqA1, sqN0, sqN1, sqN2, sqN3, sqP0, sqP1, sqP2, sqP3, sqG0,
    sqG1, sqG2, sqD0, sqD1, sqD2, sqD3, sqD4, sqD5, sqE0, sqE1, sqE2, sqE3,
    sqX0, sqPop, sqRet,
    # ArcTan
    atM0, atA1, atA2, atA3, atM1, atA4, atA5, atM2, atA6, atA7, atA8, atM3,
    atA9, atA10, atA11, atM4, atA12, atA13, atA14, atM5, atA15, atA16, atA17,
    atM6, atA18, atA19, atA20, atM7, atA21, atA22, atA23, atM8, atA24, atRet

  UT = enum
    ## Thumb steps, at UNC_THUMB_LO + 2 * ord
    # The veneer the Thumb routines call the source check through
    utV0, utV1, utVBx,
    # RLUnCompWram
    rwPush, rwHdr, rwA1, rwA2, rwBl1, rwBl2, rwSkip, rwG0, rwG1, rwFlag,
    rwF1, rwF2, rwF3, rwF4, rwFBr, rwL0, rwL1, rwLLd, rwLSt, rwL4, rwL5, rwL6,
    rwLBr, rwLB, rwR0, rwR1, rwRLd, rwR3, rwRSt, rwR5, rwR6, rwRBr, rwRB,
    rwPop, rwPop3, rwBx,
    # RLUnCompVram
    rvPush, rvSub, rvA1, rvHdr, rvA2, rvA3, rvBl1, rvBl2, rvSkip, rvA4, rvG0,
    rvG1, rvFlag, rvFSt, rvF1, rvFLd1, rvF2, rvF3, rvFLd2, rvF4, rvFBr, rvL0,
    rvL1, rvLLd, rvL2, rvL3, rvL4, rvL5, rvL6, rvLBr, rvLSt, rvL8, rvL9,
    rvL10, rvLLoop, rvLB, rvR0, rvR1, rvRLd, rvRSt, rvR2, rvRRe, rvR3, rvR4,
    rvR5, rvR6, rvRBr, rvRSth, rvR8, rvR9, rvR10, rvRLoop, rvRB, rvExit,
    rvPop, rvPop3, rvBx,
    # Diff8bitUnFilterWram
    dwPush, dwHdr, dwA1, dwBl1, dwBl2, dwSkip, dwFirst, dwF1, dwFSt, dwF3,
    dwL0, dwL1, dwLd, dwL3, dwL4, dwSt, dwL6, dwLB, dwPop, dwPop3, dwBx,
    # Diff8bitUnFilterVram
    dvPush, dvHdr, dvA1, dvA2, dvBl1, dvBl2, dvSkip, dvA3, dvFirst, dvF1,
    dvF2, dvL0, dvL1, dvLd, dvL3, dvL4, dvL5, dvL6, dvL7, dvL8, dvL9, dvL10,
    dvL11, dvSt, dvL13, dvL14, dvLB, dvPop, dvPop3, dvBx,
    # Diff16bitUnFilter
    dhPush, dhHdr, dhA1, dhBl1, dhBl2, dhSkip, dhFirst, dhF1, dhFSt, dhF3,
    dhL0, dhL1, dhLd, dhL3, dhL4, dhSt, dhL6, dhLB, dhPop, dhPop2, dhBx,
    # CpuSet
    csPush, csA1, csA2, csBl1, csBl2, csSkip, csA3, csA4, csHBr, csA5, csA6,
    csWBr, csWFLd, csWF0, csWF1, csWFSt, csWF3, csWC0, csWC1, csWCLd, csWCSt,
    csWC4, csH0, csH1, csHBr2, csHFLd, csHF0, csHF1, csHFSt, csHF3, csHF4,
    csHC0, csHC1, csHCLd, csHCSt, csHC4, csHC5, csPop, csPop3, csBx,
    # SoundBias
    sbL0, sbL1, sbL2, sbLit1, sbLd, sbLit2, sbA1, sbA2, sbA3, sbDir, sbU0,
    sbUBr, sbU2, sbUB, sbF0, sbFBr, sbF2, sbSt, sbA4, sbD0, sbD1, sbB, sbRet,
    # MidiKey2Freq, and the veneer into its multiply
    mkPush, mkA1, mkA2, mkA3, mkBr, mkC1, mkC2, mkT1, mkT2, mkA4, mkA5, mkA6,
    mkA7, mkA8, mkT3, mkA9, mkS1, mkA10, mkT4, mkA11, mkA12, mkA13, mkT5,
    mkA14, mkS2, mkA15, mkA16, mkBl1a, mkBl1b, mkR1, mkWave, mkA17, mkBl2,
    mkPop, mkPop3, mkBx, mvV0, mvV1,
    # ArcTan2, and the veneers into Div and ArcTan
    a2Push, a2A0, a2Y0, a2Z0, a2Z1, a2Z2, a2Z3, a2Z4, a2Z5, a2Z6, a2X0, a2X1,
    a2X2, a2X3, a2X4, a2X5, a2X6, a2X7, a2X8, a2X9, a2G0, a2G1, a2G2, a2G3,
    a2G4, a2G5, a2G6, a2G7, a2G8, a2G9, a2G10, a2G11, a2G12, a2G13, a2G14,
    a2F0, a2F1, a2F2, a2F3, a2F4, a2F5, a2F6, a2S0, a2S1, a2S2, a2S3, a2S4,
    a2S5, a2S6, a2Q2, a2Q2b, a2R0, a2R1, a2R2, a2R3, a2R4, a2R5, a2R6, a2R7,
    a2N0, a2N1, a2N2, a2N3, a2T0, a2T1, a2T2, a2T3, a2T4, a2T5, a2T6, a2T7,
    a2P0, a2P1, a2U0, a2U1, a2U2, a2U3, a2U4, a2U5, a2U6, a2U7, a2Pop,
    a2Pop3, a2Bx, avD0, avD1, avA0, avA1,
    # RegisterRamReset, the helper it clears each group through (a tail call
    # into CpuFastSet), and the veneer into CpuFastSet
    rrPush, rrA1, rrA2, rrLit1, rrA3, rrA4, rrA5, rrZ, rrA6, rrDisp, rrA7,
    rrA8, rrB7, rrI0, rrI1, rrI2, rrI3, rrIBl, rrI4, rrI5, rrIF, rrI6, rrI7,
    rrI410, rrI8, rrI9, rrI10, rrIBl2, rrI11, rrI12, rrI13, rrIBl3, rrI14,
    rrI15, rrI16, rrI17, rrIBl4, rrKey, rrI18, rrPA2, rrPA3, rrPD2, rrPD3,
    rrS0, rrSLit, rrS1, rrS2, rrSBl, rrS3, rrSR, rrS4, rrS5, rrSJ, rrS6,
    rrSBl2, rrN0, rrN1, rrNB, rrN2, rrN3, rrNLit, rrN84a, rrN84b, rrN80,
    rrN88r, rrN4, rrN5, rrN88, rrN6, rrN70, rrN7, rrN8, rrN9, rrNBl, rrN10,
    rrN70b, rrN11, rrN12, rrN13, rrNBl2, rrN14, rrN15, rrN16, rrN84c, rrM0,
    rrM1, rrM2, rrM3, rrMBl, rrM4, rrM5, rrM6, rrM7, rrM8, rrMBl2, rrM9,
    rrM10, rrM11, rrM12, rrM13, rrMBl3, rrM14, rrM15, rrM16, rrM17, rrM18,
    rrMBl4, rrM19, rrM20, rrM21, rrMLit, rrM22, rrMBl5, rrM23, rrPop, rrPop3,
    rrBx, rhA, rhB, rhRet, rhC, rhD, rhE, rfV0, rfV1

static:
  # each label needs its own address in the stub's room for them
  doAssert 4 * (ord(high(UA)) + 1) <= int(UNC_ARM_HI - UNC_ARM_LO)
  doAssert 2 * (ord(high(UT)) + 1) <= int(UNC_THUMB_HI - UNC_THUMB_LO)

template ua_addr(l: UA): uint32 = UNC_ARM_LO + 4'u32 * uint32(ord(l))
template ut_addr(l: UT): uint32 = UNC_THUMB_LO + 2'u32 * uint32(ord(l)) + 1'u32

const M2F_TOP = [2147483648'u64, 2275179671'u64, 2410468894'u64, 2553802834'u64,
                 2705659852'u64, 2866546760'u64, 3037000500'u64, 3217589947'u64,
                 3408917802'u64, 3611622603'u64, 3826380858'u64, 4053909304'u64]
  ## MidiKey2Freq's top-octave multipliers (hle_bios.nim's derivation)

proc unc_takes(swi_num: uint32): bool {.inline.} =
  ## The SWIs that run here (with the stub BIOS mapped)
  case swi_num
  of 0x01, 0x04 .. 0x19, 0x1F: true
  else: false

proc unc_entry(swi_num: uint32): uint32 =
  ## The routine's first step (bit 0: Thumb)
  case swi_num
  of 0x01: ut_addr(rrPush)
  of 0x04: ua_addr(iwPush)
  of 0x05: ua_addr(iwVbl0)
  of 0x06: ua_addr(dvA0)
  of 0x07: ua_addr(daS0)
  of 0x08: ua_addr(sqPush)
  of 0x09: ua_addr(atM0)
  of 0x0A: ut_addr(a2Push)
  of 0x0B: ut_addr(csPush)
  of 0x0C: ua_addr(fsPush)
  of 0x0D: ua_addr(ckA0)
  of 0x0E: ua_addr(bgPush)
  of 0x0F: ua_addr(oaPush)
  of 0x10: ua_addr(bpPush)
  of 0x11: ua_addr(lwPush)
  of 0x12: ua_addr(lvPush)
  of 0x13: ua_addr(hfPush)
  of 0x14: ut_addr(rwPush)
  of 0x15: ut_addr(rvPush)
  of 0x16: ut_addr(dwPush)
  of 0x17: ut_addr(dvPush)
  of 0x18: ut_addr(dhPush)
  of 0x19: ut_addr(sbL0)
  of 0x1F: ut_addr(mkPush)
  else: ua_addr(uaXPop2)

# --- The steps' accesses, as the core's handlers make them ---

proc u_ldrb(cpu: CPU; a: uint32): uint32 {.inline.} =
  result = uint32(cpu.gba.bus[a])
  cpu.idle(1)

proc u_ldrh(cpu: CPU; a: uint32): uint32 {.inline.} =
  result = cpu.gba.bus.read_half_rotate(a)
  cpu.idle(1)

proc u_ldr(cpu: CPU; a: uint32): uint32 {.inline.} =
  result = cpu.gba.bus.read_word_rotate(a)
  cpu.idle(1)

proc u_strb(cpu: CPU; a, v: uint32) {.inline.} = cpu.gba.bus[a] = uint8(v and 0xFF)
proc u_strh(cpu: CPU; a, v: uint32) {.inline.} = cpu.gba.bus.write_half(a, uint16(v and 0xFFFF))
proc u_str(cpu: CPU; a, v: uint32) {.inline.} = cpu.gba.bus.write_word(a, v)

proc u_stmfd(cpu: CPU; regs: openArray[int]) =
  ## ARM stmfd sp!, {...}: the lowest register at the lowest address, first
  var a = cpu.r[13] - uint32(4 * regs.len)
  cpu.r[13] = a
  for r in regs:
    cpu.gba.bus.write_word(a, cpu.r[r])
    a += 4

proc u_ldmfd(cpu: CPU; regs: openArray[int]) =
  ## ARM ldmfd sp!, {...} (no r15): the reads, then an internal cycle
  var a = cpu.r[13]
  for r in regs:
    cpu.r[r] = cpu.gba.bus.read_word(a)
    a += 4
  cpu.r[13] = a
  cpu.idle(1)

proc u_ldmia(cpu: CPU; base: int; regs: openArray[int]) =
  ## ldmia rb!, {...}: the reads (aligned, unrotated), then an internal cycle
  var a = cpu.r[base]
  cpu.r[base] = a + uint32(4 * regs.len)
  for r in regs:
    cpu.r[r] = cpu.gba.bus.read_word(a)
    a += 4
  cpu.idle(1)

proc u_stmia(cpu: CPU; base: int; regs: openArray[int]) =
  ## stmia rb!, {...}
  var a = cpu.r[base]
  for r in regs:
    cpu.gba.bus.write_word(a, cpu.r[r])
    a += 4
  cpu.r[base] = a

proc u_tpush(cpu: CPU; regs: openArray[int]) =
  ## Thumb push {..., lr}: lr first at the top, then the registers downwards
  ## (thumb_push_pop_registers)
  var a = cpu.r[13] - 4
  cpu.gba.bus.write_word(a, cpu.r[14])
  for i in countdown(regs.high, 0):
    a -= 4
    cpu.gba.bus.write_word(a, cpu.r[regs[i]])
  cpu.r[13] = a

proc u_tpop(cpu: CPU; regs: openArray[int]) =
  ## Thumb pop {...} (no pc): the reads upwards, then an internal cycle
  var a = cpu.r[13]
  for r in regs:
    cpu.r[r] = cpu.gba.bus.read_word(a)
    a += 4
  cpu.r[13] = a
  cpu.idle(1)

proc u_jump(cpu: CPU; target: uint32) =
  ## A taken branch (or bx) to `target` (bit 0: Thumb) from the step being
  ## executed: the refill, as set_reg makes it, with r15 put where the trap's
  ## SWI handler, stepping past it in the step's own state, leaves it on the
  ## target.
  let step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
  cpu.cpsr.thumb = (target and 1) != 0
  discard cpu.set_reg(15, target and not 1'u32)
  cpu.r[15] -= step

template ujump(cpu: CPU; l: UA) = cpu.u_jump(ua_addr(l))
proc u_cmp(cpu: CPU; a, b: uint32) {.inline.} =
  ## The flags an ARM cmp a, b leaves (the console's routines test them in
  ## later steps; across an interrupt they travel in the SPSR)
  let d = a - b
  cpu.cpsr.negative = (d and 0x80000000'u32) != 0
  cpu.cpsr.zero = d == 0
  cpu.cpsr.carry = a >= b
  cpu.cpsr.overflow = ((a xor b) and (a xor d) and 0x80000000'u32) != 0

proc u_ret(cpu: CPU) =
  ## bx lr from a routine the dispatcher called (lr = 0x170: the return) or
  ## another routine did (lr = its next step)
  if cpu.r[14] == 0x170'u32: cpu.u_jump(ua_addr(uaXPop2))
  else: cpu.u_jump(cpu.r[14])

proc u_sext16(v: uint32): uint32 {.inline.} =
  ## a halfword's sign extended to the word
  cast[uint32](int32(cast[int16](uint16(v and 0xFFFF'u32))))
template tjump(cpu: CPU; l: UT) = cpu.u_jump(ut_addr(l))

# --- Entry and return ---

proc unc_enter(cpu: CPU) =
  ## The swi itself, as the core takes the exception to the BIOS vector
  ## (arm_software_interrupt): SVC mode, the return address in lr, the
  ## caller's CPSR in the SPSR, I set, ARM state, the refill at the vector.
  let step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
  let lr = cpu.r[15] - step
  let old = cpu.cpsr
  cpu.switch_mode(modeSVC)
  cpu.spsr = old
  discard cpu.set_reg(14, lr)
  cpu.cpsr.irq_disable = true
  cpu.cpsr.thumb = false
  discard cpu.set_reg(15, ua_addr(uaVector))
  cpu.r[15] -= step     # the SWI handler steps past the swi

# --- The steps ---

proc lz_check(src, len: uint32): bool {.inline.} = bios_addr_check(src, len)

proc unc_arm(cpu: CPU; l: UA) =
  let bus = cpu.gba.bus
  template r(i: int): untyped = cpu.r[i]
  case l
  # The vector: a branch to the dispatcher
  of uaVector: cpu.ujump(uaDPush3)
  # SVC stack: r11, r12, lr; the comment byte from the caller's code; the
  # routine's address from the table (a BIOS read); the SPSR pushed; then
  # System mode with the caller's I bit
  of uaDPush3: cpu.u_stmfd([11, 12, 14])
  of uaDComment: r(12) = cpu.u_ldrb(r(14) - 2)
  of uaD3: discard
  of uaDTable:
    discard cpu.u_ldr(ua_addr(uaVector))
    r(12) = unc_entry(r(12))
  of uaD5: r(11) = uint32(cpu.spsr)
  of uaDPushSpsr: cpu.u_stmfd([11])
  of uaD7: r(11) = r(11) and 0x80'u32
  of uaD8: r(11) = r(11) or 0x1F'u32
  of uaDMsr:
    # msr cpsr, r11 (arm_psr_transfer): an I bit that clears opens the gate
    cpu.switch_mode(modeSYS)
    cpu.cpsr = cast[PSR](r(11))
    if not cpu.cpsr.irq_disable:
      if cpu.gba.interrupts.irq_deliverable: cpu.gba.interrupts.gate_opened()
      else: cpu.gba.interrupts.schedule_interrupt_check()
  # System stack: r2, lr; lr = the return, 0x170 on the console; bx ip
  of uaDPush2: cpu.u_stmfd([2, 14])
  of uaDLr: r(14) = 0x170'u32
  of uaDBx: cpu.u_jump(r(12))
  # The return: pop {r2, lr}; SVC mode, I set; the SPSR and r11, r12, lr
  # back off the SVC stack; movs pc, lr
  of uaXPop2: cpu.u_ldmfd([2, 14])
  of uaX1: discard
  of uaXMsr:
    cpu.switch_mode(modeSVC)
    cpu.cpsr = cast[PSR](uint32(modeSVC) or 0xC0'u32)
  of uaXPopSpsr: cpu.u_ldmfd([11])
  of uaXSpsr: cpu.spsr = cast[PSR](r(11))
  of uaXPop3: cpu.u_ldmfd([11, 12, 14])
  of uaXMovs:
    discard cpu.set_reg(15, r(14))       # refills in the caller's region
    cpu.exception_return_restore()
    cpu.r[15] -= 4                       # the trap's SWI handler steps
    bus.bios_latch = 0xE3A02004'u32      # as every HLE return leaves it
  # The source check: seven one-cycle steps, the last a return through lr,
  # but a zero length (r2) returns from the second. Whether it passes is the
  # caller's next step (bios_addr_check)
  of uaChk1:
    if r(2) == 0: cpu.ujump(uaChkRet)
  of uaChk0, uaChk2, uaChk3, uaChk4, uaChk5: discard
  of uaChkRet: cpu.u_jump(r(14))
  # LZ77UnCompWram. The registers are the console's (an interrupt finds
  # them as there, and the routine leaves r3 as there): r0 source, r1
  # destination, r2 bytes still to write (the header's length, less each
  # token's count as it starts: a back-reference longer than what is left is
  # copied whole), r3 the reference's bytes left, r4 the tokens left in the
  # group, r5 the byte between its load and its store, r6 the reference's
  # distance field, r12 the distance, lr the flag byte, shifted up a bit per
  # token (its bit 7 the token's)
  of lwPush: cpu.u_stmfd([4, 5, 6, 14])
  of lwHdr: r(2) = cpu.u_ldr(r(0))
  of lwA1: r(0) += 4
  of lwA2: r(2) = r(2) shr 8
  of lwBl:
    r(14) = ua_addr(lwSkip)
    cpu.ujump(uaChk0)
  of lwSkip:
    if not lz_check(r(0), r(2)): cpu.ujump(lwPop)
  of lwG0: discard
  of lwG1:
    if cast[int32](r(2)) <= 0: cpu.ujump(lwPop)
  of lwFlags:
    r(14) = cpu.u_ldrb(r(0))
    r(0) += 1
  of lwG3: r(4) = 8
  of lwT0: r(4) -= 1
  of lwT1:
    if cast[int32](r(4)) < 0: cpu.ujump(lwG0)
  of lwT2: discard
  of lwT3:
    if (r(14) and 0x80'u32) != 0: cpu.ujump(lwB0)
  of lwLit:
    r(5) = cpu.u_ldrb(r(0))
    r(0) += 1
  of lwLitSt:
    cpu.u_strb(r(1), r(5))
    r(1) += 1
  of lwL2: r(2) -= 1
  of lwL3: cpu.ujump(lwC0)
  of lwB0: r(3) = (cpu.u_ldrb(r(0)) shr 4) + 3
  of lwB1, lwB2, lwB4, lwB5, lwB7: discard
  of lwB3:
    r(6) = (cpu.u_ldrb(r(0)) and 0xF'u32) shl 8
    r(0) += 1
  of lwB6:
    r(6) = r(6) or cpu.u_ldrb(r(0))
    r(0) += 1
  of lwB8: r(12) = r(6) + 1
  of lwB9: r(2) -= r(3)
  of lwCp: r(5) = cpu.u_ldrb(r(1) - r(12))
  of lwCpSt:
    cpu.u_strb(r(1), r(5))
    r(1) += 1
  of lwCp2: r(3) -= 1
  of lwCp3:
    if cast[int32](r(3)) > 0: cpu.ujump(lwCp)
  of lwC0: discard
  of lwC1: r(14) = r(14) shl 1
  of lwC2:
    if cast[int32](r(2)) > 0: cpu.ujump(lwT0)
  of lwC3: cpu.ujump(lwG0)
  of lwPop: cpu.u_ldmfd([4, 5, 6, 14])
  of lwRet: cpu.ujump(uaXPop2)
  # LZ77UnCompVram. As the Wram form, but the bytes pair into halfwords
  # before their store and a reference reads its byte back out of the
  # destination with a halfword load. The console's registers: r0 source,
  # r1 the next halfword's address, r2 the header's length, then where the
  # next byte goes in the halfword (0 or 8), r3 the halfword being built
  # (what the routine leaves there), r4 the reference's distance, r5 its
  # bytes left, r6 the flag byte shifted up a bit per token, r7 the tokens
  # left in the group, r8 the byte, r9 the halfword loaded, r10 the bytes
  # still to write; r12 the byte a reference reads, as an offset from r1
  of lvPush: cpu.u_stmfd([4, 5, 6, 7, 8, 9, 10, 14])
  of lvA0: discard
  of lvHdr: r(2) = cpu.u_ldr(r(0))
  of lvA1: r(0) += 4
  of lvA2: r(2) = r(2) shr 8
  of lvA3:
    r(10) = r(2)
    r(3) = 0
  of lvBl:
    r(14) = ua_addr(lvSkip)
    cpu.ujump(uaChk0)
  of lvSkip:
    if not lz_check(r(0), r(2)): cpu.ujump(lvPop)
    else: r(2) = 0
  of lvG0: discard
  of lvG1:
    if cast[int32](r(10)) <= 0: cpu.ujump(lvPop)
  of lvFlags:
    r(6) = cpu.u_ldrb(r(0))
    r(0) += 1
  of lvG3: r(7) = 8
  of lvT0: r(7) -= 1
  of lvT1:
    if cast[int32](r(7)) < 0: cpu.ujump(lvG0)
  of lvT2: discard
  of lvT3:
    if (r(6) and 0x80'u32) != 0: cpu.ujump(lvB0)
  of lvLit:
    r(8) = cpu.u_ldrb(r(0))
    r(0) += 1
  of lvL1:
    cpu.idle(1)
    r(3) = r(3) or (r(8) shl r(2))
  of lvL2: r(2) = r(2) xor 8
  of lvL3: r(10) -= 1
  of lvLSt:
    if r(2) == 0:
      cpu.u_strh(r(1), r(3))
      r(1) += 2
  of lvL5:
    if r(2) == 0: r(3) = 0
  of lvL6: cpu.ujump(lvC0)
  of lvB0: r(5) = (cpu.u_ldrb(r(0)) shr 4) + 3
  of lvB1, lvB2, lvB4, lvB5, lvB9, lvB10, lvB11, lvB12: discard
  of lvB3:
    r(4) = (cpu.u_ldrb(r(0)) and 0xF'u32) shl 8
    r(0) += 1
  of lvB6:
    r(4) = r(4) or cpu.u_ldrb(r(0))
    r(0) += 1
  of lvB7: r(4) += 1
  of lvB8: r(10) -= r(5)
  of lvCp0: r(12) = (r(2) shr 3) - r(4)
  of lvCp1, lvCp2, lvCp3, lvCp4, lvCp6: discard
  # (the halfword the byte is in, as an even distance from the destination
  # pointer: from an odd destination the load rotates -- uncalign.c)
  of lvCpLd: r(9) = cpu.u_ldrh(r(1) + (r(12) and not 1'u32))
  of lvCp7:
    cpu.idle(1)
    r(8) = r(9) shr ((r(12) and 1'u32) shl 3)
  of lvCp8:
    cpu.idle(1)
    r(8) = r(8) and 0xFF'u32
  of lvCp9:
    cpu.idle(1)
    r(3) = r(3) or (r(8) shl r(2))
  of lvCp10: r(2) = r(2) xor 8
  of lvCpSt:
    if r(2) == 0:
      cpu.u_strh(r(1), r(3))
      r(1) += 2
  of lvCp12:
    if r(2) == 0: r(3) = 0
  of lvCp13: r(5) -= 1
  of lvCp14:
    if cast[int32](r(5)) > 0: cpu.ujump(lvCp0)
  of lvC0: discard
  of lvC1: r(6) = r(6) shl 1
  of lvC2:
    if cast[int32](r(10)) > 0: cpu.ujump(lvT0)
  of lvC3: cpu.ujump(lvG0)
  of lvPop: cpu.u_ldmfd([4, 5, 6, 7, 8, 9, 10, 14])
  of lvRet: cpu.ujump(uaXPop2)
  # HuffUnComp. The source check comes first (with a fixed 0x02000000 as the
  # length), then the header. Each leaf's symbol is shifted in at the top of
  # the output word (the word shifts down by the symbol size, the symbol goes
  # in at 32 less the size: a 4-bit leaf keeps its low four bits), and the
  # word is stored, and kept shifting, every (size & 7) + 4 leaves -- 4 for
  # 8-bit symbols, 8 for 4-bit ones; that count is spilled to the stack (two
  # words below the frame, sp past them) and reloaded at every leaf (tools/biosdrv/huffsz.c, every size nibble). r0
  # the header, then the next bitstream word's address (off a word boundary
  # as the tree size puts it: the load rotates, uncedge.c); r1 destination,
  # r2 bytes still to write, r3 the output word (what the routine leaves
  # there: the last one stored), r4 the tree's root, r5 the node, r6 the
  # bitstream word, r7 its bits left, r8 the leaves to the next store, r9 the
  # symbol size, r10 the node byte, then the reloaded count, r12 the child's
  # address, then the symbol
  of hfPush: cpu.u_stmfd([4, 5, 6, 7, 8, 9, 10, 11, 14])
  of hfA1:
    r(2) = 0x02000000'u32
    r(13) -= 8
  of hfA2, hfA4, hfA5, hfA7, hfA8, hfA9, hfA10, hfW0,
     hfB2, hfB3, hfB5, hfB6, hfB8, hfB9, hfB10, hfB11, hfL1, hfL4, hfL5,
     hfB16, hfB17: discard
  of hfExit: r(13) += 8
  of hfBl:
    r(14) = ua_addr(hfSkip)
    cpu.ujump(uaChk0)
  of hfSkip:
    if not lz_check(r(0), r(2)): cpu.ujump(hfExit)
  of hfSize: r(10) = cpu.u_ldrb(r(0))
  of hfA6: r(9) = r(10) and 0xF'u32
  of hfSpill: cpu.u_str(r(13) + 4, (r(9) and 7'u32) + 4)
  of hfHdr: r(2) = cpu.u_ldr(r(0))
  of hfA11: r(2) = r(2) shr 8
  of hfTree: r(10) = cpu.u_ldrb(r(0) + 4)
  of hfA12: r(4) = r(0) + 5
  # (the bitstream's address as the tree size gives it: off a word
  # boundary, its loads rotate -- tools/biosdrv/uncedge.c)
  of hfA13: r(0) = r(0) + 4 + (r(10) + 1) * 2
  of hfA14:
    r(3) = 0
    r(5) = r(4)
    r(8) = (r(9) and 7'u32) + 4
  of hfW1:
    if cast[int32](r(2)) <= 0: cpu.ujump(hfExit)
  of hfW2: r(7) = 32
  of hfWord:
    r(6) = cpu.u_ldr(r(0))
    r(0) += 4
  of hfB0: r(7) -= 1
  of hfB1:
    if cast[int32](r(7)) < 0: cpu.ujump(hfW0)
  of hfNode1: r(10) = cpu.u_ldrb(r(5))
  of hfB4: cpu.idle(1)
  of hfNode2: r(10) = cpu.u_ldrb(r(5))
  of hfB7: r(12) = (r(5) and not 1'u32) + ((r(10) and 0x3F'u32) + 1) * 2 + (r(6) shr 31)
  of hfBLeaf:
    let leaf = if (r(6) shr 31) != 0: (r(10) and 0x40'u32) != 0
               else: (r(10) and 0x80'u32) != 0
    r(6) = r(6) shl 1
    if not leaf:
      r(5) = r(12)
      cpu.ujump(hfB16)
  of hfL0: cpu.idle(1)
  of hfSym: r(12) = cpu.u_ldrb(r(12))
  of hfL2:
    cpu.idle(1)
    let up = 32'u32 - r(9)   # (a shift of 32 leaves nothing)
    r(3) = (r(3) shr r(9)) or (if up >= 32: 0'u32 else: r(12) shl up)
  of hfL3: r(8) -= 1
  of hfRe: r(10) = cpu.u_ldr(r(13) + 4)
  of hfSt:
    if r(8) == 0:
      cpu.u_str(r(1), r(3))
      r(1) += 4
      r(2) -= 4
  of hfL6:
    if r(8) == 0: r(8) = r(10)
  of hfL7: r(5) = r(4)
  of hfBLoop:
    if cast[int32](r(2)) > 0: cpu.ujump(hfB0)
  of hfWB: cpu.ujump(hfW0)
  of hfPop: cpu.u_ldmfd([4, 5, 6, 7, 8, 9, 10, 11, 14])
  of hfRet: cpu.ujump(uaXPop2)
  # BitUnPack. The info block's length, the check, its widths and offset (the
  # offset spilled to the stack, two words below the frame with sp past
  # them, and reloaded for every unit it is added to). r0
  # source, r1 destination, r2 source bytes left, r3 the source byte being
  # unpacked (0 once it is used up), r4 the source width, r5 the destination
  # width, r6 the zero-data flag, r7 the info block, r8 the byte's bits
  # left, r9 the word being built, r10 its bits so far, r12 the unit
  of bpPush: cpu.u_stmfd([4, 5, 6, 7, 8, 9, 10, 11, 14])
  of bpA1: r(13) -= 8
  of bpExit: r(13) += 8
  of bpA2, bpA3, bpA4, bpA5, bpY2, bpU2, bpU4, bpU6, bpU9, bpU14: discard
  of bpLen:
    r(7) = r(2)
    r(2) = cpu.u_ldrh(r(7))
  of bpBl:
    r(14) = ua_addr(bpSkip)
    cpu.ujump(uaChk0)
  of bpSkip:
    if not lz_check(r(0), r(2)): cpu.ujump(bpExit)
  of bpSw: r(4) = cpu.u_ldrb(r(7) + 2)
  of bpOff1: r(6) = cpu.u_ldr(r(7) + 4)
  of bpOff2: r(12) = cpu.u_ldr(r(7) + 4)
  of bpA6: r(12) = r(12) and 0x7FFFFFFF'u32
  of bpA7: r(6) = r(6) shr 31
  of bpSpill: cpu.u_str(r(13) + 4, r(12))
  of bpDw: r(5) = cpu.u_ldrb(r(7) + 3)
  of bpA8:
    r(9) = 0
    r(10) = 0
  of bpY0: r(2) -= 1
  of bpY1:
    if cast[int32](r(2)) < 0: cpu.ujump(bpExit)
  of bpY3: cpu.idle(1)
  of bpByte:
    r(3) = cpu.u_ldrb(r(0))
    r(0) += 1
  of bpY4: r(8) = 8
  of bpU0: r(8) -= r(4)
  of bpU1:
    if cast[int32](r(8)) < 0: cpu.ujump(bpY0)
  of bpU3:
    cpu.idle(1)
    r(12) = if r(4) >= 32: r(3) else: r(3) and ((1'u32 shl r(4)) - 1)
  of bpUZ:
    if r(12) == 0 and r(6) == 0: cpu.ujump(bpU7)
  of bpRe: r(12) += cpu.u_ldr(r(13) + 4)
  of bpU7:
    cpu.idle(1)
    # (not masked to the destination width: an offset that overflows it
    # carries into the next unit -- uncedge.c)
    if r(10) < 32: r(9) = r(9) or (r(12) shl r(10))
  of bpU8: r(10) += r(5)
  of bpUW:
    if r(10) < 32: cpu.ujump(bpU13)
  of bpSt:
    cpu.u_str(r(1), r(9))
    r(1) += 4
  of bpU11: r(9) = 0
  of bpU12: r(10) = 0
  of bpU13:
    cpu.idle(1)
    r(3) = if r(4) >= 32: 0'u32 else: r(3) shr r(4)
  of bpUB: cpu.ujump(bpU0)
  of bpPop: cpu.u_ldmfd([4, 5, 6, 7, 8, 9, 10, 11, 14])
  of bpRet: cpu.ujump(uaXPop2)
  # CpuFastSet. The check on the length as given; the count rounded up to
  # whole 8-word bursts; the fill word loaded once and copied into the eight
  # burst registers. r0 source, r1 destination, r2-r9 the burst (r3 is what
  # the routine leaves there: the last burst's second word), r10 the words
  # left, r12 the control word. Each pass subtracts 8 and bursts while the
  # count stays non-negative, so the loop ends with one pass that does not
  of fsPush: cpu.u_stmfd([4, 5, 6, 7, 8, 9, 10, 14])
  of fsA1: r(12) = r(2)
  of fsA2: r(2) = (r(12) and 0x1FFFFF'u32) shl 2
  of fsBl:
    r(14) = ua_addr(fsSkip)
    cpu.ujump(uaChk0)
  of fsSkip:
    if not lz_check(r(0), r(2)): cpu.ujump(fsPop)
  of fsA3: r(10) = r(12) and 0x1FFFFF'u32
  of fsA4: r(10) = (r(10) + 7) and not 7'u32
  of fsBr:
    if (r(12) and 0x01000000'u32) == 0: cpu.ujump(fsC0)
  of fsFillLd: r(2) = cpu.u_ldr(r(0))
  of fsF1: r(3) = r(2)
  of fsF2: r(4) = r(2)
  of fsF3: r(5) = r(2)
  of fsF4: r(6) = r(2)
  of fsF5: r(7) = r(2)
  of fsF6: r(8) = r(2)
  of fsF7: r(9) = r(2)
  of fsF8: r(10) -= 8
  of fsFSt:
    if cast[int32](r(10)) >= 0: cpu.u_stmia(1, [2, 3, 4, 5, 6, 7, 8, 9])
  of fsF10:
    if cast[int32](r(10)) >= 0: cpu.ujump(fsF8)
  of fsF11: cpu.ujump(fsPop)
  of fsC0: r(10) -= 8
  of fsCLd:
    if cast[int32](r(10)) >= 0: cpu.u_ldmia(0, [2, 3, 4, 5, 6, 7, 8, 9])
  of fsCSt:
    if cast[int32](r(10)) >= 0: cpu.u_stmia(1, [2, 3, 4, 5, 6, 7, 8, 9])
  of fsC3:
    if cast[int32](r(10)) >= 0: cpu.ujump(fsC0)
  of fsPop: cpu.u_ldmfd([4, 5, 6, 7, 8, 9, 10, 14])
  of fsRet: cpu.u_ret()
  # VBlankIntrWait (r0 = r1 = 1) and IntrWait. With old flags to discard the
  # check runs first and its result is dropped; either way the routine then
  # halts (a store to HALTCNT through r12) and checks after every wake,
  # until a flag in r1 is in the BIOS's mirror at 0x03007FF8. The check
  # clears IME, reads the mirror, acknowledges the bits it finds there and
  # sets IME again; it sets r12 to the I/O base, so the first halt without
  # the discard goes through what the dispatcher left in r12 (the routine's
  # address: a store into the BIOS, no halt -- iwait.c's preset flags, as on
  # the console). r0 the bits found, r1 the mask, r2 the mirror, r3 = 0 (the
  # IME clear and the halt store), r4 = 1 (the IME set), r12 the I/O base;
  # lr the console's own return addresses of the two calls (0x344, 0x34C),
  # which nested IRQ dispatchers push and a game can read back (Prince of
  # Tennis 2004)
  of iwVbl0: r(0) = 1
  of iwVbl1: r(1) = 1
  of iwPush: cpu.u_stmfd([4, 14])
  of iwA1: r(3) = 0
  of iwA2: r(4) = 1
  of iwA3: discard
  of iwBl:
    if r(0) != 0:
      r(14) = 0x344'u32
      cpu.ujump(icA)
  of iwHalt: cpu.u_strb(r(12) + 0x301'u32, r(3))
  of iwBl2:
    r(14) = 0x34C'u32
    cpu.ujump(icA)
  of iwLoop:
    if r(0) == 0: cpu.ujump(iwHalt)
  of iwPop: cpu.u_ldmfd([4, 14])
  of iwRet: cpu.ujump(uaXPop2)
  of icA: r(12) = 0x04000000'u32
  of icIme0: cpu.u_strb(r(12) + 0x208'u32, r(3))
  of icLd: r(2) = cpu.u_ldrh(r(12) - 8)
  of icB: r(0) = r(1) and r(2)
  of icC:
    if r(0) != 0: r(2) = r(2) xor r(0)
  of icSt:
    if r(0) != 0: cpu.u_strh(r(12) - 8, r(2))
  of icIme1: cpu.u_strb(r(12) + 0x208'u32, r(4))
  of icRet: cpu.ujump(if r(14) == 0x344'u32: iwHalt else: iwLoop)
  # Div (DivArm swaps its operands first). Nothing but one-cycle steps and
  # branches: five steps for the signs, an alignment loop doubling the
  # divisor while it is below half the dividend (two steps and a branch
  # back per shift, one pass that falls through), the shift-subtract loop
  # (five steps and a branch back per pass, one more falling through) and
  # five steps for the result's signs (hle_bios.nim div_body_cycles: the
  # counts). The results go in at the start; r12 counts the two loops'
  # passes (alignment in bits 0-15, division above). A zero divisor with a
  # dividend of 2 or more hangs the console in the alignment loop; here it
  # ends as for a dividend of 1 (hle_div)
  of daS0, daS1: discard
  of daS2: swap(cpu.r[0], cpu.r[1])
  of dvA0:
    let n = uint32(abs(int64(cast[int32](r(0)))) and 0xFFFFFFFF)
    let d = uint32(abs(int64(cast[int32](r(1)))) and 0xFFFFFFFF)
    var t = 0
    var p = 0
    if d != 0:
      t = div_align_shifts(n, d)
      p = t + (if (d shl t) == (n shr 1): 1 else: 0)
    discard cpu.hle_div(0, 1)
    r(12) = uint32(t) or (uint32(p) shl 16)
  of dvA1, dvA2, dvA3, dvA4, dvL0, dvL1, dvD0, dvD1, dvD2, dvD3, dvD4,
     dvT0, dvT1, dvT2, dvT3, dvT4: discard
  of dvL2:
    if (r(12) and 0xFFFF'u32) != 0:
      r(12) -= 1
      cpu.ujump(dvL0)
  of dvD5:
    if (r(12) shr 16) != 0:
      r(12) -= 0x10000'u32
      cpu.ujump(dvD0)
  of dvRet: cpu.u_ret()
  # BgAffineSet. Per entry: the angle, its sine and cosine out of the BIOS's
  # table, the scales, four multiplies taking the scales as the multiplier
  # (x, x, y, y), the centre and the display offset (one ldmia of three
  # words), four multiply-accumulates taking -cx, cy, -cx and -cy
  # (tools/biosdrv/affset.c: each multiply's internal cycles follow that
  # operand), the two start words, the four matrix halfwords. r0 source, r1
  # destination, r2 entries left, r3 the last entry's pa (what the routine
  # leaves there), r4 pa | pb << 16, r5 pc | pd << 16, r6 and r7 the
  # starts, r8 the scales, r9 the display offsets, r10 the angle
  of bgPush: cpu.u_stmfd([4, 5, 6, 7, 8, 9, 10, 11])
  of bgL0: r(2) -= 1
  of bgL1:
    if cast[int32](r(2)) < 0: cpu.ujump(bgPop)
  of bgAng: r(10) = cpu.u_ldrh(r(0) + 16)
  of bgA1, bgA2, bgA3, bgA4, bgA5, bgA6, bgA7, bgA8, bgA9, bgA10, bgA11,
     bgA12, bgA13, bgA14, bgA15, bgA16, bgA17: discard
  of bgSin, bgCos: discard cpu.u_ldrh(ua_addr(uaVector))   # the BIOS's table
  of bgSx: r(8) = cpu.u_ldrh(r(0) + 12) and 0xFFFF'u32
  of bgSy: r(8) = r(8) or (cpu.u_ldrh(r(0) + 14) shl 16)
  of bgM1, bgM2: cpu.idle(mul_i_cycles(u_sext16(r(8)), true))
  of bgM3, bgM4: cpu.idle(mul_i_cycles(u_sext16(r(8) shr 16), true))
  of bgLdm:
    cpu.u_ldmia(0, [6, 7, 9])
    let (pa, pb, pc, pd) = affine_params(cast[int32](u_sext16(r(8))),
                                         cast[int32](u_sext16(r(8) shr 16)), uint16(r(10)))
    let cx = int64(cast[int32](u_sext16(r(9))))
    let cy = int64(cast[int32](u_sext16(r(9) shr 16)))
    # 32-bit wrapping, as the routine computes it
    r(6) = uint32((int64(cast[int32](r(6))) - (int64(pa) * cx + int64(pb) * cy)) and 0xFFFFFFFF)
    r(7) = uint32((int64(cast[int32](r(7))) - (int64(pc) * cx + int64(pd) * cy)) and 0xFFFFFFFF)
    r(4) = uint32(cast[uint16](pa)) or (uint32(cast[uint16](pb)) shl 16)
    r(5) = uint32(cast[uint16](pc)) or (uint32(cast[uint16](pd)) shl 16)
    r(3) = cast[uint32](int32(pa))
  of bgM5, bgM7: cpu.idle(mul_i_cycles(0'u32 - u_sext16(r(9)), true) + 1)
  of bgM6: cpu.idle(mul_i_cycles(u_sext16(r(9) shr 16), true) + 1)
  of bgM8: cpu.idle(mul_i_cycles(0'u32 - u_sext16(r(9) shr 16), true) + 1)
  of bgStX: cpu.u_str(r(1) + 8, r(6))
  of bgStY: cpu.u_str(r(1) + 12, r(7))
  of bgSt1: cpu.u_strh(r(1), r(4))
  of bgSt2: cpu.u_strh(r(1) + 2, r(4) shr 16)
  of bgSt3: cpu.u_strh(r(1) + 4, r(5))
  of bgSt4: cpu.u_strh(r(1) + 6, r(5) shr 16)
  of bgA18: r(0) += 8
  of bgA19: r(1) += 16
  of bgB: cpu.ujump(bgL0)
  of bgPop: cpu.u_ldmfd([4, 5, 6, 7, 8, 9, 10, 11])
  of bgRet: cpu.ujump(uaXPop2)
  # ObjAffineSet. Per entry: the angle, its sine and cosine, the scales,
  # then each of the four halfwords after a multiply taking the scale as the
  # multiplier (x, x, y, y), the destination stepping by r3. r0 source, r1
  # destination, r2 entries left, r8 pa | pb << 16, r9 pc | pd << 16, r10
  # the scales, r11 the angle
  of oaPush: cpu.u_stmfd([8, 9, 10, 11])
  of oaL0: r(2) -= 1
  of oaL1:
    if cast[int32](r(2)) < 0: cpu.ujump(oaPop)
  of oaAng: r(11) = cpu.u_ldrh(r(0) + 4)
  of oaA1, oaA2, oaA3, oaA4, oaA5, oaA6, oaA7, oaA8, oaA9, oaA10, oaA11: discard
  of oaSin, oaCos: discard cpu.u_ldrh(ua_addr(uaVector))   # the BIOS's table
  of oaSx: r(10) = cpu.u_ldrh(r(0)) and 0xFFFF'u32
  of oaSy:
    r(10) = r(10) or (cpu.u_ldrh(r(0) + 2) shl 16)
    let (pa, pb, pc, pd) = affine_params(cast[int32](u_sext16(r(10))),
                                         cast[int32](u_sext16(r(10) shr 16)), uint16(r(11)))
    r(8) = uint32(cast[uint16](pa)) or (uint32(cast[uint16](pb)) shl 16)
    r(9) = uint32(cast[uint16](pc)) or (uint32(cast[uint16](pd)) shl 16)
  of oaM1, oaM2: cpu.idle(mul_i_cycles(u_sext16(r(10)), true))
  of oaM3, oaM4: cpu.idle(mul_i_cycles(u_sext16(r(10) shr 16), true))
  of oaSt1:
    cpu.u_strh(r(1), r(8))
    r(1) += r(3)
  of oaSt2:
    cpu.u_strh(r(1), r(8) shr 16)
    r(1) += r(3)
  of oaSt3:
    cpu.u_strh(r(1), r(9))
    r(1) += r(3)
  of oaSt4:
    cpu.u_strh(r(1), r(9) shr 16)
    r(1) += r(3)
  of oaA12: r(0) += 8
  of oaB: cpu.ujump(oaL0)
  of oaPop: cpu.u_ldmfd([8, 9, 10, 11])
  of oaRet: cpu.ujump(uaXPop2)
  # GetBiosChecksum: one load of each BIOS word (and three steps and a
  # branch back for each). The sum it would make of the stub is not the
  # official image's, so the result goes in at the start; r1 and r3 end as
  # the console leaves them (tools/biosdrv/swiregs.c)
  of ckA0:
    r(0) = 0xBAAE187F'u32
    r(1) = 1
    r(3) = 0
  of ckA1, ckL0, ckL2, ckL3, ckL4: discard
  of ckLd:
    discard cpu.u_ldr(r(3))
    r(3) += 4
  of ckBr:
    if r(3) < 0x4000'u32: cpu.ujump(ckL0)
  of ckRet: cpu.ujump(uaXPop2)
  # The long multiply (umull) MidiKey2Freq calls twice: its internal cycles
  # follow the multiplier the caller left in r12 (the HLE's; the product is
  # the caller's to compute)
  of muU: cpu.idle(mul_i_cycles(r(12), false) + 1)
  of muA: discard
  of muRet: cpu.u_jump(r(14))
  # Sqrt: Newton from above with a restoring divide (hle_bios.nim's account
  # of the algorithm and its results), as the console's steps: the
  # normalising loop (a compare, two conditional shifts, a branch back), and
  # per pass four steps, the divisor's alignment loop (a compare, a
  # conditional doubling, a branch back while it was below half the input)
  # and the divide loop (a compare, a conditional subtract, the quotient's
  # shift with the carry, a compare with the estimate, a conditional halving
  # and a branch back), three steps for the new estimate and a branch back
  # to another pass while it falls. The flags carry each compare to the steps
  # that test it. r0 the input, then the remainder, then the root; r1 the
  # estimate, r2 the divisor, r3 the quotient, r4 the pass's root, r12 the
  # input
  of sqPush: cpu.u_stmfd([4])
  of sqA0: r(12) = r(0)
  of sqA1: r(1) = 1
  of sqN0: cpu.u_cmp(r(0), r(1))
  of sqN1:
    if cpu.cpsr.carry and not cpu.cpsr.zero: r(0) = r(0) shr 1
  of sqN2:
    if cpu.cpsr.carry and not cpu.cpsr.zero: r(1) = r(1) shl 1
  of sqN3:
    if cpu.cpsr.carry and not cpu.cpsr.zero: cpu.ujump(sqN0)
  of sqP0: r(4) = r(1)
  of sqP1: r(0) = r(12)
  of sqP2: r(2) = r(1)
  of sqP3: r(3) = 0
  of sqG0: cpu.u_cmp(r(2), r(12) shr 1)
  of sqG1:
    if not cpu.cpsr.carry or cpu.cpsr.zero: r(2) = r(2) shl 1
  of sqG2:
    if not cpu.cpsr.carry: cpu.ujump(sqG0)
  of sqD0: cpu.u_cmp(r(0), r(2))
  of sqD1:
    if cpu.cpsr.carry: r(0) -= r(2)
  of sqD2: r(3) = (r(3) shl 1) or (if cpu.cpsr.carry: 1'u32 else: 0'u32)
  of sqD3: cpu.u_cmp(r(2), r(1))
  of sqD4:
    if not cpu.cpsr.zero: r(2) = r(2) shr 1
  of sqD5:
    if not cpu.cpsr.zero: cpu.ujump(sqD0)
  of sqE0: r(1) = r(1) + r(3)
  of sqE1: r(1) = r(1) shr 1
  of sqE2: cpu.u_cmp(r(1), r(4))
  of sqE3:
    if not cpu.cpsr.carry: cpu.ujump(sqP0)
  of sqX0: r(0) = r(4)
  of sqPop: cpu.u_ldmfd([4])
  of sqRet: cpu.u_ret()
  # ArcTan: r1 = -(x^2 >> 14), then Horner's rule over the coefficients
  # 0xA9, 0x390, 0x91C, 0xFB6, 0x16AA, 0x2081, 0x3651, 0xA2F9 (each product
  # by r1 shifted down 14, arithmetically, in 32-bit wrapping arithmetic),
  # the angle the sum times x shifted down 16 -- exact against the console on
  # 285 inputs before (TM0) and on mathset.c's. A step at a time: the square
  # and the final scale take the input as the multiplier, the first Horner
  # step the constant 0xA9, the six others the accumulator after its
  # coefficient is added (each added in two steps). r0 the input, then the
  # angle; r1 -(input^2 >> 14), r3 the accumulator (both left as the
  # routine leaves them)
  of atM0:
    cpu.idle(mul_i_cycles(r(0), true))
    r(1) = r(0) * r(0)
  of atA1: r(1) = cast[uint32](ashr(cast[int32](r(1)), 14))
  of atA2: r(1) = 0'u32 - r(1)
  of atA3: r(3) = 0xA9
  of atM1, atM2, atM3, atM4, atM5, atM6, atM7:
    cpu.idle(mul_i_cycles(r(3), true))
    r(3) = r(3) * r(1)
  of atA4, atA6, atA9, atA12, atA15, atA18, atA21:
    r(3) = cast[uint32](ashr(cast[int32](r(3)), 14))
  of atA7, atA10, atA13, atA16, atA19, atA22: discard
  of atA5: r(3) += 0x0390
  of atA8: r(3) += 0x091C
  of atA11: r(3) += 0x0FB6
  of atA14: r(3) += 0x16AA
  of atA17: r(3) += 0x2081
  of atA20: r(3) += 0x3651
  of atA23: r(3) += 0xA2F9
  of atM8:
    cpu.idle(mul_i_cycles(r(0), true))
    r(0) = r(3) * r(0)
  of atA24: r(0) = cast[uint32](ashr(cast[int32](r(0)), 16))
  of atRet: cpu.u_ret()

proc unc_thumb(cpu: CPU; l: UT) =
  template r(i: int): untyped = cpu.r[i]
  case l
  # The veneer: two steps (r3 left at 0xBA4) and a bx into the ARM check
  of utV0: discard
  of utV1: r(3) = 0xBA4'u32
  of utVBx: cpu.ujump(uaChk0)
  # RLUnCompWram. r0 source, r1 destination, r2 bytes still to write (less
  # each run's count as it starts: a run longer than what is left is written
  # whole), r4 the flag byte, r5 the run's bytes left, r3 the byte
  of rwPush: cpu.u_tpush([4, 5, 6, 7])
  of rwHdr: cpu.u_ldmia(0, [2])
  of rwA1: discard
  of rwA2: r(2) = r(2) shr 8
  of rwBl1, rwF4, rwL0, rwL1, rwR0, rwR1, rwG0: discard
  of rwBl2:
    r(14) = ut_addr(rwSkip)
    cpu.tjump(utV0)
  of rwSkip:
    if not lz_check(r(0), r(2)): cpu.tjump(rwPop)
  of rwG1:
    if cast[int32](r(2)) <= 0: cpu.tjump(rwPop)
  of rwFlag: r(4) = cpu.u_ldrb(r(0))
  of rwF1: r(0) += 1
  of rwF2: r(5) = (r(4) and 0x7F'u32) + (if (r(4) and 0x80'u32) != 0: 3'u32 else: 1'u32)
  of rwF3: r(2) -= r(5)
  of rwFBr:
    if (r(4) and 0x80'u32) != 0: cpu.tjump(rwR0)
  of rwLLd: r(3) = cpu.u_ldrb(r(0))
  of rwLSt: cpu.u_strb(r(1), r(3))
  of rwL4: r(0) += 1
  of rwL5: r(1) += 1
  of rwL6: r(5) -= 1
  of rwLBr:
    if cast[int32](r(5)) > 0: cpu.tjump(rwLLd)
  of rwLB: cpu.tjump(rwG0)
  of rwRLd: r(3) = cpu.u_ldrb(r(0))
  of rwR3: r(0) += 1
  of rwRSt: cpu.u_strb(r(1), r(3))
  of rwR5: r(1) += 1
  of rwR6: r(5) -= 1
  of rwRBr:
    if cast[int32](r(5)) > 0: cpu.tjump(rwRSt)
  of rwRB: cpu.tjump(rwG0)
  of rwPop: cpu.u_tpop([4, 5, 6, 7])
  of rwPop3: cpu.u_tpop([3])
  of rwBx: cpu.ujump(uaXPop2)
  # RLUnCompVram. Three words below the frame (sp past them): the flag byte
  # (reloaded twice) and a run's byte (reloaded for every byte of the run). r0, r1 (the next
  # halfword's address), r2 as the Wram form; r4 the run's bytes left, r5 the
  # halfword being built, r6 where the next byte goes in it, r7 the byte,
  # r12 the flag byte
  of rvPush: cpu.u_tpush([4, 5, 6, 7])
  of rvSub: r(13) -= 12
  of rvA1, rvA4, rvG0, rvF2, rvF3, rvL0, rvL1, rvL6, rvR0, rvR1, rvR6: discard
  of rvHdr: cpu.u_ldmia(0, [2])
  of rvA2: discard
  of rvA3: r(2) = r(2) shr 8
  of rvBl1:
    r(5) = 0
    r(6) = 0
  of rvBl2:
    r(14) = ut_addr(rvSkip)
    cpu.tjump(utV0)
  of rvSkip:
    if not lz_check(r(0), r(2)): cpu.tjump(rvExit)
  of rvG1:
    if cast[int32](r(2)) <= 0: cpu.tjump(rvExit)
  of rvFlag: r(12) = cpu.u_ldrb(r(0))
  of rvFSt: cpu.u_str(r(13) + 4, r(12))
  of rvF1: r(0) += 1
  of rvFLd1: r(4) = cpu.u_ldr(r(13) + 4)
  of rvFLd2: r(12) = cpu.u_ldr(r(13) + 4)
  of rvF4:
    r(4) = (r(4) and 0x7F'u32) + (if (r(12) and 0x80'u32) != 0: 3'u32 else: 1'u32)
    r(2) -= r(4)
  of rvFBr:
    if (r(12) and 0x80'u32) != 0: cpu.tjump(rvR0)
  of rvLLd: r(7) = cpu.u_ldrb(r(0))
  of rvL2:
    cpu.idle(1)
    r(7) = r(7) shl r(6)
  of rvL3: r(5) = r(5) or r(7)
  of rvL4: r(0) += 1
  of rvL5: r(6) = r(6) xor 8
  of rvLBr:
    if r(6) != 0: cpu.tjump(rvL10)
  of rvLSt: cpu.u_strh(r(1), r(5))
  of rvL8: r(1) += 2
  of rvL9: r(5) = 0
  of rvL10: r(4) -= 1
  of rvLLoop:
    if cast[int32](r(4)) > 0: cpu.tjump(rvLLd)
  of rvLB: cpu.tjump(rvG0)
  of rvRLd: r(7) = cpu.u_ldrb(r(0))
  of rvRSt: cpu.u_str(r(13) + 8, r(7))
  of rvR2: r(0) += 1
  of rvRRe: r(7) = cpu.u_ldr(r(13) + 8)
  of rvR3:
    cpu.idle(1)
    r(7) = r(7) shl r(6)
  of rvR4: r(5) = r(5) or r(7)
  of rvR5: r(6) = r(6) xor 8
  of rvRBr:
    if r(6) != 0: cpu.tjump(rvR10)
  of rvRSth: cpu.u_strh(r(1), r(5))
  of rvR8: r(1) += 2
  of rvR9: r(5) = 0
  of rvR10: r(4) -= 1
  of rvRLoop:
    if cast[int32](r(4)) > 0: cpu.tjump(rvRRe)
  of rvRB: cpu.tjump(rvG0)
  of rvExit: r(13) += 12
  of rvPop: cpu.u_tpop([4, 5, 6, 7])
  of rvPop3: cpu.u_tpop([3])
  of rvBx: cpu.ujump(uaXPop2)
  # Diff8bitUnFilterWram. r0 source, r1 destination, r2 bytes still to
  # write, r4 the running byte, r12 the difference
  of dwPush: cpu.u_tpush([4])
  of dwHdr: cpu.u_ldmia(0, [2])
  of dwA1: discard
  of dwBl1: r(2) = r(2) shr 8
  of dwBl2:
    r(14) = ut_addr(dwSkip)
    cpu.tjump(utV0)
  of dwSkip:
    if not lz_check(r(0), r(2)): cpu.tjump(dwPop)
  of dwFirst: r(4) = cpu.u_ldrb(r(0))
  of dwF1: r(0) += 1
  of dwFSt: cpu.u_strb(r(1), r(4))
  of dwF3:
    r(1) += 1
    r(2) -= 1
  of dwL0: discard
  of dwL1:
    if cast[int32](r(2)) <= 0: cpu.tjump(dwPop)
  of dwLd: r(12) = cpu.u_ldrb(r(0))
  of dwL3: r(4) = (r(4) + r(12)) and 0xFF'u32
  of dwL4: r(0) += 1
  of dwSt: cpu.u_strb(r(1), r(4))
  of dwL6:
    r(1) += 1
    r(2) -= 1
  of dwLB: cpu.tjump(dwL0)
  of dwPop: cpu.u_tpop([4])
  of dwPop3: cpu.u_tpop([3])
  of dwBx: cpu.ujump(uaXPop2)
  # Diff8bitUnFilterVram. r0, r2 as the Wram form, r1 the next halfword's
  # address, r4 the running byte, r5 the halfword being built, r6 where the
  # next byte goes in it, r7 the difference
  of dvPush: cpu.u_tpush([4, 5, 6, 7])
  of dvHdr: cpu.u_ldmia(0, [2])
  of dvA1: discard
  of dvA2: r(2) = r(2) shr 8
  of dvBl1, dvA3, dvL0, dvL6, dvL10: discard
  of dvBl2:
    r(14) = ut_addr(dvSkip)
    cpu.tjump(utV0)
  of dvSkip:
    if not lz_check(r(0), r(2)): cpu.tjump(dvPop)
  of dvFirst: r(4) = cpu.u_ldrb(r(0))
  of dvF1:
    r(0) += 1
    r(5) = r(4)
    r(6) = 8
  of dvF2: r(2) -= 1
  of dvL1:
    if cast[int32](r(2)) <= 0: cpu.tjump(dvPop)
  of dvLd: r(7) = cpu.u_ldrb(r(0))
  of dvL3: r(4) = (r(4) + r(7)) and 0xFF'u32
  of dvL4: r(0) += 1
  of dvL5: r(2) -= 1
  of dvL7:
    cpu.idle(1)
    r(7) = r(4) shl r(6)
  of dvL8: r(5) = r(5) or r(7)
  of dvL9: r(6) = r(6) xor 8
  of dvL11:
    if r(6) != 0: cpu.tjump(dvL0)
  of dvSt: cpu.u_strh(r(1), r(5))
  of dvL13: r(1) += 2
  of dvL14: r(5) = 0
  of dvLB: cpu.tjump(dvL0)
  of dvPop: cpu.u_tpop([4, 5, 6, 7])
  of dvPop3: cpu.u_tpop([3])
  of dvBx: cpu.ujump(uaXPop2)
  # Diff16bitUnFilter. r0 source, r1 destination, r2 bytes still to write,
  # r3 the halfword read (the last one is what the routine leaves there),
  # r4 the running halfword; the return pops into r2, which the dispatcher
  # restores
  of dhPush: cpu.u_tpush([4])
  of dhHdr: cpu.u_ldmia(0, [2])
  of dhA1: discard
  of dhBl1: r(2) = r(2) shr 8
  of dhBl2:
    r(14) = ut_addr(dhSkip)
    cpu.tjump(utV0)
  of dhSkip:
    if not lz_check(r(0), r(2)): cpu.tjump(dhPop)
  of dhFirst: r(3) = cpu.u_ldrh(r(0))
  of dhF1:
    r(0) += 2
    r(4) = r(3)
  of dhFSt: cpu.u_strh(r(1), r(4))
  of dhF3:
    r(1) += 2
    r(2) -= 2
  of dhL0: discard
  of dhL1:
    if cast[int32](r(2)) <= 0: cpu.tjump(dhPop)
  of dhLd: r(3) = cpu.u_ldrh(r(0))
  of dhL3: r(4) = (r(4) + r(3)) and 0xFFFF'u32
  of dhL4: r(0) += 2
  of dhSt: cpu.u_strh(r(1), r(4))
  of dhL6:
    r(1) += 2
    r(2) -= 2
  of dhLB: cpu.tjump(dhL0)
  of dhPop: cpu.u_tpop([4])
  of dhPop2: cpu.u_tpop([2])
  of dhBx: cpu.ujump(uaXPop2)
  # CpuSet. The check on count * 4 whatever the unit; then the four loops:
  # words through the destination's end address (the fill word loaded once
  # with an ldmia), halfwords through an offset into both (the fill
  # halfword once, with an ldrh: r0 and r1 stay as passed). r2 the end (the
  # destination's, or the offset's), r4 the unit, r5 the offset, r12 the
  # control word
  of csPush: cpu.u_tpush([4, 5])
  of csA1: r(12) = r(2)
  of csA2: r(2) = (r(12) and 0x1FFFFF'u32) shl 2
  of csBl1, csA4, csA6, csH1, csWF0, csWC0, csHF0, csHC0: discard
  of csBl2:
    r(14) = ut_addr(csSkip)
    cpu.tjump(utV0)
  of csSkip:
    if not lz_check(r(0), r(2)): cpu.tjump(csPop)
  of csA3: r(2) = r(12) and 0x1FFFFF'u32
  of csHBr:
    if (r(12) and 0x04000000'u32) == 0: cpu.tjump(csH0)
  of csA5: r(2) = r(1) + r(2) * 4
  of csWBr:
    if (r(12) and 0x01000000'u32) == 0: cpu.tjump(csWC0)
  of csWFLd: cpu.u_ldmia(0, [4])
  of csWF1:
    if r(1) >= r(2): cpu.tjump(csPop)
  of csWFSt: cpu.u_stmia(1, [4])
  of csWF3: cpu.tjump(csWF0)
  of csWC1:
    if r(1) >= r(2): cpu.tjump(csPop)
  of csWCLd: cpu.u_ldmia(0, [4])
  of csWCSt: cpu.u_stmia(1, [4])
  of csWC4: cpu.tjump(csWC0)
  of csH0:
    r(2) = r(2) * 2
    r(5) = 0
  of csHBr2:
    if (r(12) and 0x01000000'u32) == 0: cpu.tjump(csHC0)
  of csHFLd: r(4) = cpu.u_ldrh(r(0))
  of csHF1:
    if r(5) >= r(2): cpu.tjump(csPop)
  of csHFSt: cpu.u_strh(r(1) + r(5), r(4))
  of csHF3: r(5) += 2
  of csHF4: cpu.tjump(csHF0)
  of csHC1:
    if r(5) >= r(2): cpu.tjump(csPop)
  of csHCLd: r(4) = cpu.u_ldrh(r(0) + r(5))
  of csHCSt: cpu.u_strh(r(1) + r(5), r(4))
  of csHC4: r(5) += 2
  of csHC5: cpu.tjump(csHC0)
  of csPop: cpu.u_tpop([4, 5])
  of csPop3: cpu.u_tpop([3])
  of csBx: cpu.ujump(uaXPop2)
  # SoundBias: one step of the level (SOUNDBIAS bits 1-9) at a time, up to
  # 0x200 (r0 nonzero; a level above it stays) or down to 0, each store
  # followed by a delay loop of nine passes; two literal loads from the BIOS
  # in every pass. r1 the level read (what the routine leaves there), r2 the
  # register's value, then the delay count, r3 its address
  of sbL0, sbL1, sbL2, sbA2, sbA3, sbU0, sbF0: discard
  of sbLit1:
    discard cpu.u_ldr(ua_addr(uaVector))   # a literal
    r(3) = 0x04000088'u32
  of sbLd: r(2) = cpu.u_ldrh(r(3))
  of sbLit2: discard cpu.u_ldr(ua_addr(uaVector))
  of sbA1: r(1) = r(2) and 0x3FE'u32
  of sbDir:
    if r(0) == 0: cpu.tjump(sbF0)
  of sbUBr:
    if r(1) >= 0x200'u32: cpu.tjump(sbRet)
  of sbU2: r(2) += 2
  of sbUB: cpu.tjump(sbSt)
  of sbFBr:
    if r(1) == 0: cpu.tjump(sbRet)
  of sbF2: r(2) -= 2
  of sbSt: cpu.u_strh(r(3), r(2))
  of sbA4: r(2) = 9
  of sbD0: r(2) -= 1
  of sbD1:
    if r(2) != 0: cpu.tjump(sbD0)
  of sbB: cpu.tjump(sbL0)
  of sbRet: cpu.ujump(uaXPop2)
  # MidiKey2Freq. A key above 178 takes two more steps (the clamp); five
  # loads from the BIOS's tables; two long multiplies: the fine pitch's
  # interpolation, whose multiplier is the pitch in the top byte (any
  # nonzero pitch is a slow one), and the WaveData frequency times the
  # interpolated multiplier M, which is its multiplier (a key in the top
  # octaves the slowest) -- tools/biosdrv/m2ftime.c. The values are
  # hle_bios.nim's (midikey.c): r4 M, r5 and r6 the two multipliers, r7
  # the frequency; the routine leaves r0 the result, r1 M
  of mkPush: cpu.u_tpush([4, 5, 6, 7])
  of mkA1:
    var key = r(1)
    var pitch = r(2) and 0xFF'u32
    var mult: uint64
    if key > 178:
      mult = 4053020522'u64
      pitch = 255
    else:
      template m0(k: uint32): uint64 = M2F_TOP[int(k mod 12)] shr (14 - int(k div 12))
      let lo = m0(key)
      let hi = m0(key + 1)
      mult = lo + uint64((int64(hi - lo) * int64(pitch)) shr 8)
    r(4) = uint32(mult and 0xFFFFFFFF'u64)
    r(5) = pitch shl 24
    r(6) = r(4)
  of mkA2, mkA3, mkC2, mkA4, mkA5, mkA6, mkA7, mkA8, mkA9, mkA10, mkA11,
     mkA12, mkA13, mkA14, mkA15, mkA16, mkBl1a, mkR1: discard
  of mkBr:
    if r(1) <= 178'u32: cpu.tjump(mkT1)
  of mkC1, mkT1, mkT2, mkT3, mkT4, mkT5: discard cpu.u_ldr(ua_addr(uaVector))
  of mkS1, mkS2: cpu.idle(1)
  of mkBl1b:
    r(14) = ut_addr(mkR1)
    r(12) = r(5)
    cpu.tjump(mvV0)
  of mkWave: r(7) = cpu.u_ldr(r(0) + 4)
  of mkA17:
    r(0) = uint32((uint64(r(7)) * uint64(r(4))) shr 32)
    r(1) = r(4)
  of mkBl2:
    r(14) = ut_addr(mkPop)
    r(12) = r(6)
    cpu.tjump(mvV0)
  of mkPop: cpu.u_tpop([4, 5, 6, 7])
  of mkPop3: cpu.u_tpop([3])
  of mkBx: cpu.ujump(uaXPop2)
  of mvV0: discard
  of mvV1: cpu.ujump(muU)
  # ArcTan2 (tools/biosdrv/atan2.c: every path). y = 0 and x = 0 end at once
  # (0 or 0x8000; 0x4000 or 0xC000). Otherwise ten steps, then a branch by
  # quadrant and, within it, by which coordinate is the larger -- `flat`
  # as hle_bios.nim has it, ties going to y / x except in the third quadrant
  # and -2^31 always the smaller -- into one of five tails, each of which
  # calls Div on the smaller over the larger (shifted up 14) and ArcTan on
  # the ratio, through their veneers, and turns the angle into the result:
  # t, 0x4000 - t, t + 0x8000, 0xC000 - t or t + 0x10000. r4 x, r5 y, r6
  # flat; Div and ArcTan leave r0, r1 and r3 as they leave them
  of a2Push: cpu.u_tpush([4, 5, 6, 7])
  of a2A0:
    r(4) = r(0)
    r(5) = r(1)
    let x = cast[int32](r(0))
    let y = cast[int32](r(1))
    let ax = if x < 0: cast[int32](0'u32 - r(0)) else: x
    let ay = if y < 0: cast[int32](0'u32 - r(1)) else: y
    r(6) = (if (if x < 0 and y < 0: ax > ay else: ax >= ay): 1'u32 else: 0'u32)
  of a2Y0:
    if r(5) != 0: cpu.tjump(a2X0)
  of a2Z0, a2Z2, a2Z4, a2X0, a2X2, a2X4, a2X7, a2G0, a2G1, a2G2, a2G3, a2G4,
     a2G5, a2G6, a2G7, a2G8, a2G9, a2G11, a2G13, a2F0, a2F2, a2F4, a2S1,
     a2S3, a2Q2, a2R0, a2R2, a2R4, a2N0, a2N2, a2T1, a2T3, a2T6, a2P0, a2U0,
     a2U2, a2U4, a2U7, avD0, avA0: discard
  of a2Z1:
    if cast[int32](r(4)) < 0: cpu.tjump(a2Z4)
  of a2Z3:
    r(0) = 0
    cpu.tjump(a2Pop)
  of a2Z5: r(0) = 0x8000
  of a2Z6: cpu.tjump(a2Pop)
  of a2X1:
    if r(4) != 0: cpu.tjump(a2G0)
  of a2X3:
    if cast[int32](r(5)) < 0: cpu.tjump(a2X7)
  of a2X5: r(0) = 0x4000
  of a2X6: cpu.tjump(a2Pop)
  of a2X8: r(0) = 0xC000
  of a2X9: cpu.tjump(a2Pop)
  of a2G10:
    if cast[int32](r(5)) < 0: cpu.tjump(a2N0)
  of a2G12:
    if cast[int32](r(4)) < 0: cpu.tjump(a2Q2)
  of a2G14:
    if r(6) == 0: cpu.tjump(a2S0)
  of a2Q2b:
    if r(6) == 0: cpu.tjump(a2S0)
  of a2N1:
    if cast[int32](r(4)) > 0: cpu.tjump(a2P0)
  of a2N3:
    if r(6) != 0: cpu.tjump(a2R0)
  of a2P1:
    if r(6) == 0: cpu.tjump(a2T0)
  # the Div operands: flat, y << 14 over x; else x << 14 over y
  of a2F1, a2S0, a2R1, a2T0, a2U1:
    if r(6) != 0:
      r(0) = r(5) shl 14
      r(1) = r(4)
    else:
      r(0) = r(4) shl 14
      r(1) = r(5)
  of a2F3:
    r(14) = ut_addr(a2F4)
    cpu.tjump(avD0)
  of a2F5:
    r(14) = ut_addr(a2F6)
    cpu.tjump(avA0)
  of a2F6: cpu.tjump(a2Pop)
  of a2S2:
    r(14) = ut_addr(a2S3)
    cpu.tjump(avD0)
  of a2S4:
    r(14) = ut_addr(a2S5)
    cpu.tjump(avA0)
  of a2S5: r(0) = 0x4000'u32 - r(0)
  of a2S6: cpu.tjump(a2Pop)
  of a2R3:
    r(14) = ut_addr(a2R4)
    cpu.tjump(avD0)
  of a2R5:
    r(14) = ut_addr(a2R6)
    cpu.tjump(avA0)
  of a2R6: r(0) = r(0) + 0x8000'u32
  of a2R7: cpu.tjump(a2Pop)
  of a2T2:
    r(14) = ut_addr(a2T3)
    cpu.tjump(avD0)
  of a2T4:
    r(14) = ut_addr(a2T5)
    cpu.tjump(avA0)
  of a2T5: r(0) = 0xC000'u32 - r(0)
  of a2T7: cpu.tjump(a2Pop)
  of a2U3:
    r(14) = ut_addr(a2U4)
    cpu.tjump(avD0)
  of a2U5:
    r(14) = ut_addr(a2U6)
    cpu.tjump(avA0)
  of a2U6: r(0) = r(0) + 0x10000'u32
  of a2Pop: cpu.u_tpop([4, 5, 6, 7])
  of a2Pop3: cpu.u_tpop([3])
  of a2Bx: cpu.ujump(uaXPop2)
  of avD1: cpu.ujump(dvA0)
  of avA1: cpu.ujump(atM0)
  # RegisterRamReset (tools/biosdrv/rrr.c, rrr2.c, rrr4.c, rrr5.c,
  # rrrregs.c, rrrsb.c). A zero word below the frame; DISPCNT forced blank;
  # then each group in turn: other I/O (bit 7: IE to IME and the rest cleared
  # by fills, IF acknowledged, a byte to 0x04000410, KEYCNT's word, the
  # affine PA/PD set to 0x100), SIO (RCNT 0x8000 and JOYCNT 7 at 0x134 and
  # 0x140 with bit 5, at 0x114 and 0x120 without; the registers cleared with
  # it), sound (bit 6: the master enable off and on, SOUNDCNT_H 0x880E,
  # SOUNDBIAS kept to its level bits, both wave RAM banks cleared with the
  # eight words from 0x90 -- FIFO A and B among them -- the master off), then
  # EWRAM, VRAM, OAM, palette RAM and IWRAM below 0x03007E00. Each clear is
  # the helper: a group whose bit is clear returns at once, else it tail
  # calls CpuFastSet to fill from the zero word. The registers are the
  # console's: r0 the flags, then the zero word's address (what a clear
  # leaves; 0x100 if only bit 7 ran), r1 the clear's destination, r2 its
  # count, r4 the I/O base, r5 0x85000000, r6 the group's bit, r7 the flags
  of rrPush: cpu.u_tpush([4, 5, 6, 7])
  of rrA1: r(13) -= 4
  of rrA2: r(7) = r(0)
  of rrLit1, rrSLit, rrNLit, rrMLit: discard cpu.u_ldr(ua_addr(uaVector))  # literals
  of rrA3: r(4) = 0x04000000'u32
  of rrA4: r(5) = 0x85000000'u32
  of rrA5: r(2) = 0
  of rrZ: cpu.u_str(r(13), r(2))
  of rrA6: r(2) = 0x80
  of rrDisp: cpu.u_strh(r(4), r(2))
  of rrA7, rrA8, rrI0, rrI4, rrI6, rrI8, rrI11, rrI14, rrI15, rrS0, rrS3,
     rrS4, rrN0, rrN1, rrN2, rrN6, rrN7, rrN10, rrN11, rrN14, rrN15, rrM0,
     rrM4, rrM5, rrM9, rrM10, rrM14, rrM15, rrM19, rrM20, rfV0: discard
  of rrB7:
    if (r(7) and 0x80'u32) == 0: cpu.tjump(rrS0)
  # the I/O group's four clears
  of rrI1: r(6) = 0x80
  of rrI2:
    r(1) = r(4) + 0x200
    r(2) = 8
  of rrI3, rrI10, rrI13, rrI17, rrS2, rrS6, rrN9, rrN13, rrM3, rrM8, rrM13,
     rrM18, rrM22: discard   # (bl, first half)
  of rrIBl:
    r(14) = ut_addr(rrI4)
    cpu.tjump(rhA)
  of rrI5: r(2) = 0xFFFF
  of rrIF: cpu.u_strh(r(4) + 0x202, r(2))
  of rrI7: r(2) = 0xFF
  of rrI410: cpu.u_strb(r(4) + 0x410, r(2))
  of rrI9:
    r(1) = r(4) + 0x004
    r(2) = 8
  of rrIBl2:
    r(14) = ut_addr(rrI11)
    cpu.tjump(rhA)
  of rrI12:
    r(1) = r(4) + 0x020
    r(2) = 16
  of rrIBl3:
    r(14) = ut_addr(rrI14)
    cpu.tjump(rhA)
  of rrI16:
    r(1) = r(4) + 0x0B0
    r(2) = 24
  of rrIBl4:
    r(14) = ut_addr(rrKey)
    cpu.tjump(rhA)
  of rrKey:
    r(2) = 0
    cpu.u_str(r(4) + 0x130, r(2))
  of rrI18: r(0) = 0x100
  of rrPA2: cpu.u_strh(r(4) + 0x20, r(0))
  of rrPA3: cpu.u_strh(r(4) + 0x30, r(0))
  of rrPD2: cpu.u_strh(r(4) + 0x26, r(0))
  of rrPD3: cpu.u_strh(r(4) + 0x36, r(0))
  # SIO: the registers at 0x110 (bit 5 set: and 0x140) cleared, RCNT and JOYCNT
  of rrS1:
    r(6) = 0x20
    r(1) = r(4) + 0x110
    r(2) = 8
  of rrSBl:
    r(14) = ut_addr(rrS3)
    cpu.tjump(rhA)
  of rrSR:
    r(12) = r(4) + 0x110 + (if (r(7) and 0x20'u32) != 0: 0x20'u32 else: 0'u32)
    cpu.u_strh(r(12) + 4, 0x8000)
  of rrS5: r(2) = 7
  of rrSJ: cpu.u_strb(r(12) + 0x10, r(2))
  of rrSBl2:
    r(1) = r(4) + 0x140
    r(2) = 8
    r(14) = ut_addr(rrN0)
    cpu.tjump(rhA)
  # sound
  of rrNB:
    if (r(7) and 0x40'u32) == 0: cpu.tjump(rrM0)
  of rrN3: r(2) = 0
  of rrN84a: cpu.u_strb(r(4) + 0x84, r(2))
  of rrN84b: cpu.u_strb(r(4) + 0x84, 0x80)
  of rrN80: cpu.u_str(r(4) + 0x80, 0x880E0000'u32)
  of rrN88r: r(2) = cpu.u_ldrh(r(4) + 0x88)
  of rrN4: r(2) = r(2) shl 22
  of rrN5: r(2) = r(2) shr 22
  of rrN88: cpu.u_strh(r(4) + 0x88, r(2))
  of rrN70: cpu.u_strb(r(4) + 0x70, 0x70)
  of rrN8:
    r(6) = 0x40
    r(1) = r(4) + 0x090
    r(2) = 8
  of rrNBl:
    r(14) = ut_addr(rrN10)
    cpu.tjump(rhA)
  of rrN70b: cpu.u_strb(r(4) + 0x70, 0)
  of rrN12:
    r(1) = r(4) + 0x090
    r(2) = 8
  of rrNBl2:
    r(14) = ut_addr(rrN14)
    cpu.tjump(rhA)
  of rrN16: r(2) = 0
  of rrN84c: cpu.u_strb(r(4) + 0x84, r(2))
  # the memories: EWRAM, VRAM, OAM, palette RAM, IWRAM
  of rrM1: r(6) = 0x01
  of rrM2:
    r(1) = 0x02000000'u32
    r(2) = 0x10000
  of rrMBl:
    r(14) = ut_addr(rrM4)
    cpu.tjump(rhA)
  of rrM6: r(6) = 0x08
  of rrM7:
    r(1) = 0x06000000'u32
    r(2) = 0x6000
  of rrMBl2:
    r(14) = ut_addr(rrM9)
    cpu.tjump(rhA)
  of rrM11: r(6) = 0x10
  of rrM12:
    r(1) = 0x07000000'u32
    r(2) = 0x100
  of rrMBl3:
    r(14) = ut_addr(rrM14)
    cpu.tjump(rhA)
  of rrM16: r(6) = 0x04
  of rrM17:
    r(1) = 0x05000000'u32
    r(2) = 0x100
  of rrMBl4:
    r(14) = ut_addr(rrM19)
    cpu.tjump(rhA)
  of rrM21:
    r(6) = 0x02
    r(1) = 0x03000000'u32
  of rrMBl5:
    r(2) = 0x1F80
    r(14) = ut_addr(rrM23)
    cpu.tjump(rhA)
  of rrM23: r(13) += 4
  of rrPop: cpu.u_tpop([4, 5, 6, 7])
  of rrPop3: cpu.u_tpop([3])
  of rrBx: cpu.ujump(uaXPop2)
  # the helper: return at once if the group's bit is clear, else CpuFastSet
  # filling r2 words from the zero word to r1
  of rhA: discard
  of rhB:
    if (r(7) and r(6)) != 0: cpu.tjump(rhC)
  of rhRet: cpu.u_jump(r(14))
  of rhC: r(0) = r(13)
  of rhD: r(2) = r(2) or 0x01000000'u32
  of rhE: cpu.tjump(rfV0)
  of rfV1: cpu.ujump(fsPush)

proc unc_step(cpu: CPU): bool {.inline.} =
  ## The trap at r15 is one of the routines' steps: execute it.
  if cpu.cpsr.thumb:
    let pc = cpu.r[15] - 4
    if pc < UNC_THUMB_LO or pc >= UNC_THUMB_HI: return false
    let i = int((pc - UNC_THUMB_LO) shr 1)
    if i > ord(high(UT)): return false
    cpu.unc_thumb(UT(i))
  else:
    let pc = cpu.r[15] - 8
    if pc < UNC_ARM_LO or pc >= UNC_ARM_HI: return false
    let i = int((pc - UNC_ARM_LO) shr 2)
    if i > ord(high(UA)): return false
    cpu.unc_arm(UA(i))
  true
