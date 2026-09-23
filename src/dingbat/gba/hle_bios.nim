# HLE BIOS implementation (included by gba.nim)

proc mul32(a, b: int32): int32 {.inline.} =
  ## Wrapping 32-bit multiply matching ARM `mul` instruction (low 32 bits).
  cast[int32](cast[uint32](cast[int64](a) * cast[int64](b)))

# The affine SWIs' sine table: 256 steps per turn in 1.14 fixed point,
# truncated toward zero. Derived, not copied: trunc(sin(i * pi / 128) *
# 0x4000) reproduces the real BIOS's pa/pb/pc/pd for all 256 angles at
# scale 0x4000 (ObjAffineSet under LLE), and cos is the table a quarter
# turn on. The closest a non-quadrant entry comes to an integer is 0.003,
# so no libm rounding can flip one.
const AFFINE_SINE = block:
  var t: array[256, int32]
  for i in 0 ..< 256:
    t[i] = int32(trunc(sin(float64(i) * PI / 128.0) * 16384.0))
  t

proc affine_params(sx, sy: int32; angle: uint16): (int16, int16, int16, int16) =
  ## BgAffineSet/ObjAffineSet matrix: only the angle's high byte is used
  ## (the low byte never moves the result), each product is shifted down
  ## arithmetically, and pb negates the shifted product. Exact against the
  ## real BIOS on 1024 ObjAffineSet entries (scales 0x100, 0x7FFF/-0x8000,
  ## 0x1234/-1, -0x100/3) and 144 BgAffineSet entries (random scales,
  ## centres, offsets). The float version this replaces was off by one in
  ## most entries (PeterLemon BIOSBGAFFINESET/BIOSOBJAFFINESET data).
  let a = int(angle shr 8)
  let s = AFFINE_SINE[a]
  let c = AFFINE_SINE[(a + 64) and 255]
  template h(x: int32): int16 = cast[int16](uint16(cast[uint32](x) and 0xFFFF))
  (h(ashr(sx * c, 14)), h(-ashr(sx * s, 14)), h(ashr(sy * s, 14)), h(ashr(sy * c, 14)))

proc bios_arctan(cpu: CPU): int =
  ## ArcTan (SWI 0x09): the BIOS polynomial with 32-bit wrapping arithmetic
  ## and ASR shifts. r0 = tan in 1.14 -> r0 = angle (0x4000 = pi/2);
  ## r1 = -(input^2 >> 14), r3 = polynomial accumulator, as the routine leaves them.
  ## Returns the body cost: fixed, plus the multiplies' early-termination
  ## cycles. Two take the input as the multiplier (the square and the final
  ## scale); the six middle Horner steps take the running accumulator (the
  ## sum before each multiply). Fitted against the real BIOS with TM0 around
  ## the swi on 285 inputs (every width 8..32 bits, both signs): exact on
  ## all. The previous fixed 46 + 2 * mul(input) is this model whenever the
  ## accumulator stays within 16 bits (inputs up to 0xFFFF), and was 1-4
  ## cycles off beyond (PeterLemon BIOSARCTAN's 0xFEDCBA98 by 1).
  let a = cast[int32](cpu.r[0])
  var r1 = mul32(a, a)
  r1 = ashr(r1, 14)
  r1 = -r1
  const ARCTAN_COEFFS = [0xA9'i32, 0x0390, 0x091C, 0x0FB6, 0x16AA, 0x2081, 0x3651, 0xA2F9]
  var r3 = mul32(ARCTAN_COEFFS[0], r1)
  r3 = ashr(r3, 14)
  result = 34 + 2 * mul_i_cycles(cast[uint32](a), true)
  for i in 1 ..< ARCTAN_COEFFS.len - 1:
    r3 = r3 + ARCTAN_COEFFS[i]
    result += mul_i_cycles(cast[uint32](r3), true)
    r3 = mul32(r3, r1); r3 = ashr(r3, 14)
  r3 = r3 + ARCTAN_COEFFS[^1]
  cpu.r[0] = cast[uint32](ashr(mul32(r3, a), 16))
  cpu.r[1] = cast[uint32](r1)
  cpu.r[3] = cast[uint32](r3)

proc div_align_shifts(n, d: uint32): int {.inline.} =
  ## Taken-branch count of the BIOS divide's alignment loop (0x3C8): r2
  ## starts at |denom| and doubles while r2 < |numer| >> 1; the unwind loop
  ## runs one more pass, so the input-dependent cost is 13 cycles per shift.
  ## Closed form hb(n)-hb(d), minus one when d << (s-1) >= n >> 1 stops the
  ## loop early.
  if n shr 1 <= d: return 0
  let s = countLeadingZeroBits(d) - countLeadingZeroBits(n)  # >= 1 here
  if (d shl (s - 1)) >= (n shr 1): s - 1 else: s

proc div_body_cycles(n, d: uint32): int {.inline.} =
  ## Cycles of the BIOS divide body (0x3B4) for |numer| n, |denom| d, beyond
  ## the fixed dispatch. 19 + 13 per alignment shift; +8 when the last
  ## alignment compare lands exactly equal (the loop's `lslls` doubles r2
  ## once more without branching back, so the unwind runs one extra pass).
  ## d = 0 exits the alignment loop at once (only reachable for |n| <= 1;
  ## see hle_div). Measured against the real BIOS with TM0 around the swi:
  ## Div(2,1) 106, Div(-2^31,-1) 496, Div(2^31,2^30) 483 vs 98/488/475 for
  ## the neighbouring inputs; 33 more pairs cycle-exact.
  if d == 0: return 19
  let t = div_align_shifts(n, d)
  result = 19 + t * 13
  if (d shl t) == (n shr 1): result += 8

proc hle_div(cpu: CPU; numer_reg, denom_reg: int) =
  let numer = int64(cast[int32](cpu.r[numer_reg]))
  let denom = int64(cast[int32](cpu.r[denom_reg]))
  # Body cost (div_body_cycles) on top of the dispatch: mGBA suite "BIOS
  # Division" timing rows plus the real-BIOS TM0 measurements noted there
  cpu.idle(div_body_cycles(uint32(abs(numer) and 0xFFFFFFFF),
                           uint32(abs(denom) and 0xFFFFFFFF)))
  if denom == 0:
    # Div by zero. The real BIOS's alignment loop (0x3C8: r2 = |denom| = 0
    # doubles "while r2 < |numer| >> 1") exits at once when |numer| <= 1 and
    # never when |numer| >= 2. When it exits, the unwind pass with r2 = 0
    # yields quotient 1 (signed like the numerator), remainder = numerator,
    # |quotient| = 1 — measured under the real BIOS for numerators 0, 1, -1
    # (Div and DivArm): r0 = +1/+1/-1, r1 = 0/1/-1, r3 = 1, 98 cycles. For
    # |numer| >= 2 the real BIOS hangs; the HLE returns the same
    # (+-1, numerator, 1) so the game keeps running (Assumed).
    cpu.r[0] = if numer < 0: 0xFFFFFFFF'u32 else: 1'u32
    cpu.r[1] = uint32(numer and 0xFFFFFFFF)
    cpu.r[3] = 1'u32
  else:
    let quot = numer div denom
    let rem = numer mod denom
    cpu.r[0] = cast[uint32](uint32(quot and 0xFFFFFFFF))
    cpu.r[1] = cast[uint32](uint32(rem and 0xFFFFFFFF))
    cpu.r[3] = uint32(abs(quot) and 0xFFFFFFFF)

# BIOS interrupt flags mirror at 0x03007FF8. User IRQ handlers OR the
# interrupts they service into this halfword; IntrWait consumes it.
proc read_intr_mirror(cpu: CPU): uint16 {.inline.} =
  uint16(cpu.gba.bus.wram_chip[0x7FF8]) or (uint16(cpu.gba.bus.wram_chip[0x7FF9]) shl 8)

proc write_intr_mirror(cpu: CPU; value: uint16) {.inline.} =
  cpu.gba.bus.wram_chip[0x7FF8] = uint8(value)
  cpu.gba.bus.wram_chip[0x7FF9] = uint8(value shr 8)

proc svc_sp(cpu: CPU): uint32 {.inline.} =
  ## The SVC-mode sp (live or banked), where the BIOS SWI dispatcher keeps
  ## its register frame.
  if cast[CpuMode](cpu.cpsr.mode) == modeSVC: cpu.r[13]
  else: cpu.reg_banks[mode_bank(modeSVC)][5]

proc sys_sp(cpu: CPU): uint32 {.inline.} =
  ## The System/User-mode sp (live or banked). The BIOS dispatcher switches
  ## to System mode before every routine, so routine stack traffic goes here.
  if mode_bank(cast[CpuMode](cpu.cpsr.mode)) == 0: cpu.r[13]
  else: cpu.reg_banks[0][5]

proc sys_lr(cpu: CPU): uint32 {.inline.} =
  if mode_bank(cast[CpuMode](cpu.cpsr.mode)) == 0: cpu.r[14]
  else: cpu.reg_banks[0][6]

proc set_sys_lr(cpu: CPU; v: uint32) {.inline.} =
  if mode_bank(cast[CpuMode](cpu.cpsr.mode)) == 0: cpu.r[14] = v
  else: cpu.reg_banks[0][6] = v

proc set_sys_sp(cpu: CPU; v: uint32) {.inline.} =
  if mode_bank(cast[CpuMode](cpu.cpsr.mode)) == 0: cpu.r[13] = v
  else: cpu.reg_banks[0][5] = v

proc hle_intr_wait(cpu: CPU; discard_old: bool; mask: uint16) =
  ## IntrWait (GBATEK): sets IME=1, then halts until the user IRQ handler
  ## ORs a masked flag into the BIOS mirror at 0x03007FF8; with
  ## discard_old=false returns at once if one is already set. Matched flags
  ## are acknowledged on return.
  ##
  ## Register protocol of the routine (0x330, check subroutine 0x358): while
  ## halted r12 = 0x04000000, which user IRQ dispatchers rely on (devkitARM
  ## crt0 acknowledges the mirror with `strh r0, [ip, #-8]`; without it
  ## IntrWait never returns: Bubble Bobble Old & New, Card E-Reader). On
  ## return the caller's r12 comes back, r0 = matched bits, r3 = 0.
  cpu.gba.interrupts.ime = true
  # Routine frame (ARM 0x330, System stack): push {r4, lr = 0x170} below
  # the dispatcher's {r2, lr} pair (written by hle_swi)
  block:
    let usp = cpu.sys_sp()
    cpu.gba.bus.write_word_internal(usp - 12, 0x170'u32)
    cpu.gba.bus.write_word_internal(usp - 16, cpu.r[4])
  let mirror = cpu.read_intr_mirror()
  if discard_old:
    cpu.write_intr_mirror(mirror and not mask)
  else:
    let hit = mirror and mask
    if hit != 0:
      cpu.write_intr_mirror(mirror and not hit)
      cpu.r[0] = uint32(hit)
      cpu.r[3] = 0
      # The no-halt path still runs the check subroutine, the acknowledge
      # and both frame pops: 192 cycles from the caller's swi to its next
      # instruction on the real BIOS (hardware: gbaedge IWCYCLE on AGB SP,
      # docs/hwprobe-results-agb.md), 32 beyond the dispatch cost.
      cpu.gba.bus.add_cycles(32)
      return
  # The caller's r12 goes in the dispatcher's SVC-stack slot (push {fp, ip,
  # lr} at 0x140 puts ip at [sp_svc - 8]); it survives the wait and travels
  # inside save states for free.
  cpu.gba.bus.write_word_internal(cpu.svc_sp() - 8, cpu.r[12])
  cpu.r[12] = 0x04000000'u32
  cpu.r[3] = 0
  # Handler-visible state of the halt loop (0x344-0x34C): r4 = 1, r2 = the
  # last mirror read, lr_sys = 0x34C (the `bl 0x358` return). Nested user
  # IRQ dispatchers push this lr, and games read the residue (Prince of
  # Tennis 2004's sound engine wedges without it).
  cpu.r[4] = 1
  cpu.r[2] = uint32(cpu.read_intr_mirror())
  cpu.set_sys_lr(0x34C'u32)
  # Both frames stay live for the whole wait so nested IRQ frames land below
  # them; check_intr_wait pops them (+16) on resume.
  cpu.set_sys_sp(cpu.sys_sp() - 16)
  # While halted r0 holds the last check's matched bits
  if discard_old: cpu.r[0] = uint32(mirror and mask)
  cpu.intr_wait_active = true
  cpu.intr_wait_mask = mask
  cpu.intr_wait_resume_addr = if cpu.cpsr.thumb: cpu.r[15] - 2 else: cpu.r[15] - 4
  cpu.halted = true
  cpu.gba.interrupts.schedule_interrupt_check()  # may already be pending

const INTRWAIT_TUNE {.intdefine.} = 44

proc check_intr_wait*(cpu: CPU) =
  ## Execution reached the instruction after an IntrWait SWI (the user IRQ
  ## handler returned): re-halt unless a requested flag is in the mirror.
  let hit = cpu.read_intr_mirror() and cpu.intr_wait_mask
  # The check subroutine re-enables IME on every pass (0x370)
  cpu.gba.interrupts.ime = true
  if hit != 0:
    cpu.write_intr_mirror(cpu.read_intr_mirror() and not hit)
    cpu.intr_wait_active = false
    # Return protocol: r0 = matched bits, r3 = 0, r12 from the SVC-stack
    # slot, r2/r4/lr popped from the System-stack frames. Read memory rather
    # than shadow copies: a handler that scribbled on the slots is observed.
    cpu.r[0] = uint32(hit)
    cpu.r[3] = 0
    cpu.r[12] = cpu.gba.bus.read_word_internal(cpu.svc_sp() - 8)
    block:
      let usp = cpu.sys_sp() + 16  # pop the routine + dispatcher frames
      cpu.r[4] = cpu.gba.bus.read_word_internal(usp - 16)
      cpu.r[2] = cpu.gba.bus.read_word_internal(usp - 8)
      cpu.set_sys_lr(cpu.gba.bus.read_word_internal(usp - 4))
      cpu.set_sys_sp(usp)
    # The IntrWait exit path leaves this opcode in the BIOS open-bus latch
    cpu.gba.bus.bios_latch = 0xE3A02004'u32
    # Wake-path cost: the check/acknowledge subroutine, its return, the
    # routine's frame pop and the dispatcher's restore, instruction-counted
    # from the real BIOS. Keeps code after IntrWait phase-aligned with the
    # timer prescaler (mGBA suite Timer count-up rows).
    # Checked against Nintendo's BIOS on an AGB SP (tests/roms/payloads/
    # vbwait.s): with this the return lands on the console's cycle for a
    # V-blank wait and a V-count wait alike, behind a minimal handler and a
    # table-walking one. A one-cycle miss that page first showed here was
    # HALT_RETURN_COST's (below), which moved the page's own clocks.
    cpu.gba.bus.add_cycles(INTRWAIT_TUNE - (when HALT_WAKE_RUNS_ONE: HALT_WAKE_INSTR_COST else: 0))
  else:
    # Re-halt with the check subroutine's register state (see hle_intr_wait)
    cpu.r[0] = 0
    cpu.r[12] = 0x04000000'u32
    cpu.r[2] = uint32(cpu.read_intr_mirror())
    cpu.r[4] = 1
    cpu.set_sys_lr(0x34C'u32)
    cpu.halted = true
    cpu.gba.interrupts.schedule_interrupt_check()

# SWI entry/dispatch/return cost, excluding the caller-side pipeline refill
# charged per region in hle_swi. mGBA suite BIOS timing rows (IWRAM column).
const SWI_HLE_BASE = 48

# The part of a Halt/Stop SWI the BIOS executes after the wake IRQ is
# serviced (bx lr, pop {r2, lr}, mode restore, pop {fp, ip, lr}, movs pc, lr
# with refill = 21), less the cycle the IRQ exception return charges on the
# vector side. A deferral, not an extra cost: post-wake measurements see it
# (mGBA suite SIO timing rows).
# 21, not the 20 instruction-counted above: vbwait.s stamps IntrWait's return
# against a Halt wake, and at 20 every stamp on the page sat one cycle from
# the real BIOS in our own core -- which is itself on the console's cycle.
# halthb.s could not see it: a Halt return cancels out of that page's
# difference. The mGBA suite does not constrain it either.
const HALT_RETURN_COST {.intdefine.} = 21

# --- Routine-body cost models ---
#
# The copy/decompression SWIs top up what the HLE's own bus accesses charged
# to the instruction-counted cost of the BIOS routine, verified cycle-exact
# against real-BIOS execution on calibration streams at two waitstate
# settings. Fixed constants are the body cost beyond SWI_HLE_BASE and the
# caller refill. Per-unit terms use nonsequential waitstates: the BIOS loops
# interleave instruction fetches with the data accesses, so no burst survives.

proc rom_pf_seq16(bus: Bus; page: int): int {.inline.} =
  ## What a ROM halfword data read saves when it lands on the address after
  ## the previous ROM access with the prefetch buffer on: the bus then
  ## prices it sequential even with BIOS instructions in between (with the
  ## buffer off those break the burst). Zero outside the cartridge bus.
  if bus.prefetch_on and page >= 0x8 and page <= 0xD:
    int(bus.wait16_n[page]) - int(bus.wait16_s[page])
  else: 0

proc hle_body_start(cpu: CPU): int64 {.inline.} =
  int64(cpu.gba.scheduler.cycles) + int64(cpu.gba.bus.cycles)

proc hle_charge_body(cpu: CPU; t0: int64; model: int) {.inline.} =
  ## Top up what the body charged since `t0` to `model`.
  let charged = int(cpu.hle_body_start() - t0)
  if model > charged:
    cpu.idle(model - charged)

proc bios_addr_check(address, length: uint32): bool {.inline.} =
  ## The BIOS source-region check (0xBA4) every copy/decompression SWI runs
  ## first. False = the BIOS silently skips the operation: zero length,
  ## source below 0x02000000, or source+length (length masked to 25 bits)
  ## leaving the 0x02000000-0x0FFFFFFF address bits. Games rely on the skip:
  ## Riviera's decompression queue ends with a src=0xFFFFFFFF entry.
  if length == 0: return false
  if (address and 0x0E000000'u32) == 0: return false
  ((address + (length and 0x01FFFFFF'u32)) and 0x0E000000'u32) != 0

# Body cost of a validation-skipped copy/decompression SWI (entry push,
# header ldr, the 0xBA4 check, early-out), instruction-counted.
const BIOS_CHECK_SKIP_COST = 26

# The BIOS copy SWIs run with the caller's IRQ mask, so a long CpuSet /
# CpuFastSet is preempted mid-loop by any deliverable interrupt. Card
# E-Reader boot-loads a 22 KB IWRAM program over its own live IRQ handler
# with one CpuSet and needs the vblank serviced through the old handler
# first. So every HLE_COPY_IRQ_CHECK units the HLE checks for a deliverable
# interrupt; if one is pending it winds r0/r1/r2 forward to the remaining
# span and rewinds the PC onto the SWI, which re-executes after the IRQ.
# All continuation state is architectural, so save states need nothing.
# Deviations on the interrupted path only: the halfword forms advance r0/r1
# (the routine indexes with an offset register) and the re-dispatch
# re-charges the entry overhead (~50 cycles).
const HLE_COPY_IRQ_CHECK = 32

# RegisterRamReset's "other I/O" phase: cycles from the phase start to the
# timer-register clear (see the bit-7 phase)
const RRR_TIMER_STOP {.intdefine.} = 376

proc hle_irq_deliverable(cpu: CPU): bool {.inline.} =
  let intr = cpu.gba.interrupts
  intr.ime and not cpu.cpsr.irq_disable and
    ((uint16(intr.reg_ie) and uint16(intr.reg_if)) != 0)

proc hle_swi_rewind(cpu: CPU) =
  ## Rewind the PC onto the SWI being handled so it re-executes after the
  ## pending IRQ. The arm/thumb SWI handler still steps the PC after hle_swi
  ## returns, so aim one instruction short.
  if cpu.cpsr.thumb:
    discard cpu.set_reg(15, cpu.r[15] - 6)
  else:
    discard cpu.set_reg(15, cpu.r[15] - 12)

proc hle_charge_units_interruptible(cpu: CPU; n: int): int =
  ## Charge `n` idle cycles in chunks with the scheduler caught up. Returns
  ## the un-charged remainder if an IRQ became deliverable first, else 0.
  var remain = n
  const CHUNK = 64
  while remain > 0:
    let step = min(remain, CHUNK)
    cpu.idle(step)
    remain -= step
    if remain > 0:
      cpu.gba.bus.catch_up()
      if cpu.hle_irq_deliverable():
        return remain
  0

proc hle_charge_body_interruptible(cpu: CPU; t0: int64; model: int) =
  ## hle_charge_body for SWIs the BIOS runs with the caller's IRQ mask: the
  ## remaining routine time is charged in chunks so a mid-routine interrupt
  ## lands at its true cycle instead of an end-of-SWI lump (a >1-frame
  ## LZ77UnCompVram otherwise merges two vblanks into one IF bit; Muppets On
  ## With The Show wedges on that). An un-charged remainder is parked on the
  ## halt-resume mechanism and paid at the instruction after the SWI; the
  ## caller's r12 is staged in the dispatcher's SVC-stack slot the resume
  ## pops. Deviation (docs/hle-bios-shortcomings.md): the memory effects
  ## have completed before the handler runs.
  let remain = cpu.hle_charge_units_interruptible(model - int(cpu.hle_body_start() - t0))
  if remain > 0:
    cpu.gba.bus.write_word_internal(cpu.svc_sp() - 8, cpu.r[12])
    cpu.halt_resume_charge = int32(remain)
    cpu.halt_resume_addr = if cpu.cpsr.thumb: cpu.r[15] - 2 else: cpu.r[15] - 4
    # The System sp was not shifted for this park: pay the charge only
    cpu.halt_resume_pop = false

proc hle_div_body_cost(numer, denom: int32): int {.inline.} =
  ## The divide loop cost from hle_div, separate so ArcTan2 can price its
  ## internal Div.
  div_body_cycles(uint32(abs(int64(numer)) and 0xFFFFFFFF),
                  uint32(abs(int64(denom)) and 0xFFFFFFFF))

proc hle_swi*(cpu: CPU; swi_num: uint32) =
  ## HLE BIOS SWI dispatch; used when no BIOS image is provided.
  cpu.idle(SWI_HLE_BASE)
  # BIOS open-bus latch: the last opcode the BIOS fetches before returning
  # (GBATEK "Reading from BIOS memory"; mGBA suite checks it after VBlankIntrWait)
  cpu.gba.bus.bios_latch = 0xE3A02004'u32
  # The return refills the caller's pipeline: N + S fetch in its region,
  # plus one more sequential halfword slot (S16 - 1, the residual every
  # non-IWRAM mGBA suite column shows)
  block:
    let bus = cpu.gba.bus
    let page = int(bits_range(cpu.r[15], 24, 27))
    if cpu.cpsr.thumb:
      bus.add_cycles(int(bus.wait16_n[page]) + int(bus.wait16_s[page]))
    else:
      bus.add_cycles(int(bus.wait32_n[page]) + int(bus.wait32_s[page]))
    bus.add_cycles(int(bus.wait16_s[page]) - 1)
    # The swi flushed the ROM fetch stream; forget burst/prefetch state
    bus.rom_hot = false
    bus.rom_next_addr = 1  # never matches (halfword-aligned addresses)
    bus.rom_free_since = bus.gba.scheduler.cycles + CycleCount(bus.cycles)
  # Anchor for the routine-body cost models
  let body_t0 = cpu.hle_body_start()
  # The BIOS dispatch (0x140) switches to System mode and pushes {r2, lr}
  # on the System stack before every routine; the words stay in memory below
  # sp as residue games read (Prince of Tennis 2004, see hle_intr_wait).
  if swi_num != 0x00:  # SoftReset wipes this RAM anyway
    let usp = cpu.sys_sp()
    cpu.gba.bus.write_word_internal(usp - 4, cpu.sys_lr())
    cpu.gba.bus.write_word_internal(usp - 8, cpu.r[2])
  case swi_num
  of 0x00:  # SoftReset, or the stub BIOS's boot traps
    # The SWI handler steps the PC by the caller's ISA after we return:
    # set_reg(15, target - step) lands on `target`. Capture before any CPSR change.
    let isa_step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
    if cpu.r[15] == 0x1DFE'u32 or cpu.r[15] == 0x1E02'u32:
      # SoundMain stub epilogue (see 0x1C / new_bus): the dispatcher's
      # `movs pc, lr`, restoring CPSR from SPSR_svc and returning to lr_svc
      let target = cpu.r[14] and not 1'u32
      let spsr = cpu.spsr
      # The trap's own swi and dispatch are an artifact of the stub: take
      # them back. Net 57 puts the no-driver path on the real BIOS's 80
      # cycles around the swi (PeterLemon BIOSSoundDriverMain; 56 and 58
      # miss by one either way).
      cpu.gba.bus.add_cycles(-57)
      cpu.switch_mode(cast[CpuMode](spsr.mode))
      cpu.cpsr = spsr
      discard cpu.set_reg(15, target - 2)  # the stub is thumb
    elif cpu.r[15] == 8'u32:
      # Boot trap #1: the game jumped to the reset vector. The BIOS re-runs
      # its boot (display blanked, peripherals silenced, work RAM cleared,
      # ~271-frame logo, ROM re-entry at scanline 126). The I/O deltas below
      # were diffed from real-BIOS execution in dingbat (Earthworm Jim 2
      # relies on this reboot). Not modeled: the logo in VRAM and the jingle.
      let bus = cpu.gba.bus
      bus.write_half(0x04000000'u32, 0x0080'u16)  # DISPCNT: forced blank
      bus.write_half(0x04000004'u32, 0x0000'u16)  # DISPSTAT
      for a in countup(0x04000008'u32, 0x0400001E'u32, 2):  # BGxCNT, scrolls
        bus.write_half(a, 0)
      # BG2/BG3 affine left at the identity transform (like RegisterRamReset)
      for base in [0x04000020'u32, 0x04000030'u32]:
        bus.write_half(base, 0x0100'u16)          # PA
        bus.write_half(base + 2, 0)               # PB
        bus.write_half(base + 4, 0)               # PC
        bus.write_half(base + 6, 0x0100'u16)      # PD
        bus.write_word(base + 8, 0)               # X
        bus.write_word(base + 12, 0)              # Y
      for a in countup(0x04000040'u32, 0x04000054'u32, 2):  # WIN/MOSAIC/BLD
        bus.write_half(a, 0)
      # Sound: channel registers cleared while the master enable is on (they
      # are write-protected when it is off), FIFOs reset, master off
      bus.write_half(0x04000084'u32, 0x0080'u16)
      for a in countup(0x04000060'u32, 0x04000080'u32, 2):
        bus.write_half(a, 0)
      bus.write_half(0x04000082'u32, 0x880E'u16)
      bus.write_half(0x04000084'u32, 0x0000'u16)
      bus.write_half(0x04000088'u32, 0x0200'u16)  # SOUNDBIAS
      # DMA + timers off (counters stay frozen)
      for a in [0x040000BA'u32, 0x040000C6'u32, 0x040000D2'u32, 0x040000DE'u32,
                0x04000102'u32, 0x04000106'u32, 0x0400010A'u32, 0x0400010E'u32]:
        bus.write_half(a, 0)
      bus.write_half(0x04000132'u32, 0x0000'u16)  # KEYCNT
      bus.write_half(0x04000134'u32, 0x800F'u16)  # RCNT (boot's multiboot probe)
      bus.write_half(0x04000200'u32, 0x0000'u16)  # IE
      bus.write_half(0x04000202'u32, 0xFFFF'u16)  # IF: acknowledge everything
      bus.write_half(0x04000204'u32, 0x0000'u16)  # WAITCNT
      bus.write_half(0x04000208'u32, 0x0000'u16)  # IME
      for i in 0x7E00 ..< 0x8000:                 # BIOS work RAM
        bus.wram_chip[i] = 0
      cpu.intr_wait_active = false
      # Park in the stub's wait loop (r0/r2 are its inputs); the
      # continuation is architectural
      cpu.r[0] = 0x04000000'u32
      cpu.r[2] = 270  # vblank starts between vector entry and ROM re-entry
      discard cpu.set_reg(15, 0x200'u32 - isa_step)
    elif cpu.r[15] == 0x234'u32:
      # Boot trap #2: the wait loop finished; hand the ROM the post-boot
      # register file
      cpu.switch_mode(modeSYS)
      cpu.cpsr = cast[PSR](uint32(modeSYS))
      for i in 0 .. 12:
        cpu.r[i] = 0
      cpu.r[13] = 0x03007F00'u32
      cpu.r[14] = 0x08000000'u32
      cpu.reg_banks[mode_bank(modeUSR)][5] = 0x03007F00'u32
      cpu.reg_banks[mode_bank(modeIRQ)][5] = 0x03007FA0'u32
      cpu.reg_banks[mode_bank(modeIRQ)][6] = 0
      cpu.reg_banks[mode_bank(modeSVC)][5] = 0x03007FE0'u32
      cpu.reg_banks[mode_bank(modeSVC)][6] = 0
      cpu.gba.bus.bios_latch = 0xE129F000'u32  # boot exit leaves its msr
      discard cpu.set_reg(15, 0x08000000'u32 - isa_step)
    else:
      let return_flag = cpu.gba.bus.wram_chip[0x7FFA]
      for i in 0x7E00 ..< 0x8000:
        cpu.gba.bus.wram_chip[i] = 0
      # switch_mode so the live r13/r14 rebank (a direct CPSR write would not)
      cpu.switch_mode(modeSYS)
      cpu.cpsr = cast[PSR](uint32(modeSYS))
      for i in 0 .. 12:
        cpu.r[i] = 0
      cpu.r[13] = 0x03007F00'u32
      cpu.r[14] = 0
      cpu.reg_banks[mode_bank(modeUSR)][5] = 0x03007F00'u32
      cpu.reg_banks[mode_bank(modeIRQ)][5] = 0x03007FA0'u32
      cpu.reg_banks[mode_bank(modeIRQ)][6] = 0
      cpu.reg_banks[mode_bank(modeSVC)][5] = 0x03007FE0'u32
      cpu.reg_banks[mode_bank(modeSVC)][6] = 0
      cpu.intr_wait_active = false
      let reset_addr = if return_flag == 0: 0x08000000'u32 else: 0x02000000'u32
      discard cpu.set_reg(15, reset_addr - isa_step)  # see isa_step
  of 0x02:  # Halt
    # Defer the post-wake return cost to the resume boundary (HALT_RETURN_COST)
    cpu.gba.bus.add_cycles(-HALT_RETURN_COST)
    cpu.halt_resume_charge = HALT_RETURN_COST
    cpu.halt_resume_addr = if cpu.cpsr.thumb: cpu.r[15] - 2 else: cpu.r[15] - 4
    # The routine (0x1A0) halts with ip = 0x04000000, r2 = 0, lr_sys = 0x170
    # (the dispatcher trampoline), observable by user IRQ dispatchers (see
    # hle_intr_wait); r12/r2/lr come back from the stack slots on resume
    cpu.gba.bus.write_word_internal(cpu.svc_sp() - 8, cpu.r[12])
    cpu.r[12] = 0x04000000'u32
    cpu.r[2] = 0
    cpu.set_sys_lr(0x170'u32)
    cpu.set_sys_sp(cpu.sys_sp() - 8)  # dispatcher {r2, lr} frame stays live
    cpu.halt_resume_pop = true        # ...and the resume pops it back
    cpu.halted = true
    # Halt exits on IE & IF != 0 regardless of IME, including already-pending
    cpu.gba.interrupts.schedule_interrupt_check()
  of 0x03:  # Stop
    # Peripherals keep running (hardware stops sound/video/timers); the wake
    # sources are only keypad/cartridge/SIO as on hardware
    cpu.gba.bus.add_cycles(-HALT_RETURN_COST)
    cpu.halt_resume_charge = HALT_RETURN_COST
    cpu.halt_resume_addr = if cpu.cpsr.thumb: cpu.r[15] - 2 else: cpu.r[15] - 4
    # As Halt (routine 0x1A8 shares 0x1AC); r2 holds the 0x80 it wrote to HALTCNT
    cpu.gba.bus.write_word_internal(cpu.svc_sp() - 8, cpu.r[12])
    cpu.r[12] = 0x04000000'u32
    cpu.r[2] = 0x80
    cpu.set_sys_lr(0x170'u32)
    cpu.set_sys_sp(cpu.sys_sp() - 8)  # dispatcher {r2, lr} frame stays live
    cpu.halt_resume_pop = true        # ...and the resume pops it back
    cpu.halted = true
    cpu.stopped = true
    cpu.gba.ppu.render_dirty = true  # Stop blanks the LCD with no memory write
    cpu.gba.interrupts.schedule_interrupt_check()
  of 0x06: hle_div(cpu, 0, 1)  # Div
  of 0x07:  # DivArm: three `mov`s (0x3A8) swapping the inputs, then Div
    cpu.idle(3)  # real BIOS: +3 cycles over Div on every input measured
    hle_div(cpu, 1, 0)
  of 0x04:  # IntrWait(discard_flags, intr_flags)
    cpu.hle_intr_wait(cpu.r[0] != 0, uint16(cpu.r[1]))
  of 0x05:  # VBlankIntrWait = IntrWait(1, 1)
    # The entry point (0x328) loads r0/r1; r1 survives to the caller
    cpu.r[0] = 1
    cpu.r[1] = 1
    cpu.hle_intr_wait(true, 1'u16)
  of 0x08:  # Sqrt
    # The BIOS routine (0x404) is Newton from above: start from the power
    # of two at or above sqrt(x), take x_next = (x_n + x / x_n) / 2 with a
    # restoring shift-subtract divide whose divisor is first doubled while
    # below x / 2 (an exact hit still doubles once), and stop at the first
    # step that fails to decrease. GBATEK SWI 08h documents only the 16-bit
    # result. The scratch stays in the caller's registers: r1 = the
    # rejected average, r3 = the last quotient. For x = 0 the first pass
    # averages to 0 < 1, so a second pass runs and its 0/0 step yields
    # quotient 1: r0 = 0, r1 = 0, r3 = 1.
    #
    # Cycles from GBATEK "ARM CPU Instruction Cycle Times" (BIOS is 32-bit,
    # zero-wait: S = N = 1; taken branch 3, not-taken 1): a normalize
    # iteration 6; a pass 17 + 5 per divisor doubling + 8 per continuing
    # divide step + 2 when it loops back; a fixed 12 net of the return that
    # SWI_HLE_BASE covers (the datasheet formulas give 10; x = 0 and x = 1
    # measure 2 more, and every other input follows). Hardware anchors:
    # gbaedge SWIREGION (0x10/0x1000/0x100000/0x40000000 -> 0x00CC/0x0118/
    # 0x0164/0x01C3), SWITIME (0x7FFFFFFF -> 0x0519), the mGBA suite's
    # three Sqrt timing rows (0, 0xFF, 0x12345678); r0/r1/r3 and TM0
    # cycle-exact against the real BIOS on 37 inputs (0..4, 15, 16, 0xFF,
    # 0xFFFF, 0x10000, the gbaedge points, 0x7FFFFFFF, 0xFFFFFFFF, 20
    # randoms).
    block:
      let x = cpu.r[0]
      let half = x shr 1
      var cycles = 12
      # halve the input and double the estimate until they cross
      var estimate = 1'u32          # r1
      var scaled = x                # r0 during normalization
      while scaled > estimate:
        scaled = scaled shr 1
        estimate = estimate shl 1
        cycles += 6
      var root = estimate           # r4: the candidate this pass tests
      var quotient = 0'u32          # r3
      while true:                   # one Newton pass
        root = estimate
        var remainder = x           # r0
        var divisor = estimate      # r2
        quotient = 0
        cycles += 17
        while true:                 # align the divisor
          let again = divisor < half
          if divisor <= half: divisor = divisor shl 1
          if not again: break
          cycles += 5
        while true:                 # restoring divide
          quotient = quotient shl 1
          if remainder >= divisor:
            remainder -= divisor
            quotient += 1
          if divisor == estimate: break
          divisor = divisor shr 1
          cycles += 8
        estimate = (estimate + quotient) shr 1
        if estimate >= root: break
        cycles += 2
      cpu.idle(cycles)
      cpu.r[0] = root
      cpu.r[1] = estimate
      cpu.r[3] = quotient
  of 0x09:  # ArcTan
    cpu.idle(bios_arctan(cpu))
  of 0x0A:  # ArcTan2(x, y) -> angle, 0x10000 = 2 pi
    # Behaviour taken from the real BIOS under LLE (77 inputs, values exact):
    # the ratio handed to ArcTan is the smaller coordinate over the larger,
    # so it stays inside the polynomial's 1.14 range; ties take the y/x form
    # except in the third quadrant. Magnitudes come from a 32-bit negate, so
    # -2^31 stays negative and always counts as the smaller. The numerator is
    # shifted in 32 bits and wraps for |coordinate| >= 2^17. The result is not
    # masked: the fourth quadrant's y/x form adds a full turn, so r0 can read
    # 0x10000 there.
    let x = cast[int32](cpu.r[0])
    let y = cast[int32](cpu.r[1])
    var model: int
    if y == 0:
      cpu.r[0] = if x >= 0: 0'u32 else: 0x8000'u32
      model = if x >= 0: 23 else: 26
    elif x == 0:
      cpu.r[0] = if y >= 0: 0x4000'u32 else: 0xC000'u32
      model = if y >= 0: 28 else: 30
    else:
      let ax = if x < 0: cast[int32](0'u32 - cpu.r[0]) else: x
      let ay = if y < 0: cast[int32](0'u32 - cpu.r[1]) else: y
      let flat = if x < 0 and y < 0: ax > ay else: ax >= ay
      let num = cast[int32](cast[uint32](if flat: y else: x) shl 14)
      let den = if flat: x else: y
      let ratio = cast[uint32](uint32((int64(num) div int64(den)) and 0xFFFFFFFF))
      cpu.r[0] = ratio
      let poly_cycles = bios_arctan(cpu)
      let t = cpu.r[0]
      # Per-octant fixed cost (real-BIOS TM0 readings around the swi, net of
      # the divide and polynomial): the quadrant branches differ in length.
      if flat:
        if x > 0:
          if y > 0: (cpu.r[0] = t; model = 65)
          else: (cpu.r[0] = t + 0x10000'u32; model = 68)
        else:
          cpu.r[0] = t + 0x8000'u32
          model = if y > 0: 68 else: 70
      else:
        if y > 0: (cpu.r[0] = 0x4000'u32 - t; model = if x > 0: 67 else: 69)
        else: (cpu.r[0] = 0xC000'u32 - t; model = if x > 0: 72 else: 68)
      model += hle_div_body_cost(num, den) + poly_cycles
    cpu.r[3] = 0x170'u32
    cpu.hle_charge_body(body_t0, model)
  of 0x0B:  # CpuSet
    # Routine frame (thumb 0xB4C): push {r4, r5, lr}; the exit pops lr into
    # r3, so r3 = 0x170 on every path (validation-skip too).
    block:
      let usp = cpu.sys_sp()
      cpu.gba.bus.write_word_internal(usp - 12, 0x170'u32)
      cpu.gba.bus.write_word_internal(usp - 16, cpu.r[5])
      cpu.gba.bus.write_word_internal(usp - 20, cpu.r[4])
    cpu.r[3] = 0x170'u32
    var src = cpu.r[0]
    var dst = cpu.r[1]
    let ctrl = cpu.r[2]
    let count = bits_range(ctrl, 0, 20)
    let fill = bit(ctrl, 24)
    let word_mode = bit(ctrl, 26)
    # Validation uses byte length count*4 even in halfword mode (the check
    # runs before the halving)
    if not bios_addr_check(src, count shl 2):
      cpu.idle(BIOS_CHECK_SKIP_COST)
    else:
      # Addresses are not aligned: the bus aligns normal memory, and SRAM
      # genuinely sees the unaligned byte address.
      let src_page = int(bits_range(src, 24, 27))
      let dst_page = int(bits_range(dst, 24, 27))
      # Fixed/per-unit routine costs (model block below), topped up per chunk
      # so mid-copy events and IRQs land at faithful cycle positions.
      let model_fixed = block:
        let bus = cpu.gba.bus
        if word_mode:
          if fill: 44 + int(bus.wait32_n[src_page]) else: 44
        else:
          if fill: 46 + int(bus.wait16_n[src_page]) else: 46
      let model_unit = block:
        let bus = cpu.gba.bus
        if word_mode:
          if fill: 6 + int(bus.wait32_n[dst_page])
          else:    8 + int(bus.wait32_n[src_page]) + int(bus.wait32_n[dst_page])
        else:
          if fill: 7 + int(bus.wait16_n[dst_page])
          else:    9 + int(bus.wait16_n[src_page]) + int(bus.wait16_n[dst_page])
      var done = 0'u32
      var interrupted = false
      if word_mode:
        # ldmia r0!/stmia r1!: r0/r1 come back advanced (fill pops one word)
        let fill_val = cpu.gba.bus.read_word(src)
        if fill: src += 4
        while done < count:
          let val = if fill: fill_val
                    else: cpu.gba.bus.read_word(src)
          cpu.gba.bus.write_word(dst, val)
          if not fill: src += 4
          dst += 4
          inc done
          if (done and (HLE_COPY_IRQ_CHECK - 1)) == 0 and done < count:
            let target = model_fixed + model_unit * int(done)
            let charged = int(cpu.hle_body_start() - body_t0)
            if target > charged: cpu.idle(target - charged)
            cpu.gba.bus.catch_up()
            if cpu.hle_irq_deliverable():
              interrupted = true
              break
        # The continuation re-reads its fill word from r0, so the fill's
        # source pop waits for the last leg
        cpu.r[0] = if interrupted and fill: src - 4 else: src
        cpu.r[1] = dst
      else:
        # ldrh from an odd source reads rotated, so the stored halfword is
        # the addressed byte. The halfword paths index with an offset
        # register and leave r0/r1 unmodified.
        let fill_val = uint16(cpu.gba.bus.read_half_rotate(src))
        while done < count:
          let val = if fill: fill_val
                    else: uint16(cpu.gba.bus.read_half_rotate(src))
          cpu.gba.bus.write_half(dst, val)
          if not fill: src += 2
          dst += 2
          inc done
          if (done and (HLE_COPY_IRQ_CHECK - 1)) == 0 and done < count:
            let target = model_fixed + model_unit * int(done)
            let charged = int(cpu.hle_body_start() - body_t0)
            if target > charged: cpu.idle(target - charged)
            cpu.gba.bus.catch_up()
            if cpu.hle_irq_deliverable():
              interrupted = true
              break
        if interrupted:
          # Continuation state (deviation, see HLE_COPY_IRQ_CHECK)
          cpu.r[0] = src
          cpu.r[1] = dst
      # Loop cost (routine 0xB4C) for the units performed: loop instructions
      # + N-cost of the src read + N-cost of the dst write; fills read src
      # once (in the fixed part).
      cpu.hle_charge_body(body_t0, model_fixed + model_unit * int(done))
      if interrupted:
        cpu.r[2] = (ctrl and not 0x1FFFFF'u32) or (count - done)
        cpu.hle_swi_rewind()
  of 0x01:  # RegisterRamReset
    # The routine (0x9C2) handles the flag groups in this order: other I/O
    # (bit 7), SIO (5), sound (6), EWRAM (0), VRAM (3), OAM (4), palette
    # (2), IWRAM last (1), with the caller's IRQ mask, so its RAM clears are
    # preempted mid-loop. Robot Wars - Advanced Destruction calls it with
    # EWRAM|IWRAM and vblank live: the IRQ must dispatch through the IWRAM
    # handler table before IWRAM is wiped, or the game wedges.
    #
    # Each phase is charged in chunks with the RAM cleared progressively
    # (ascending, like the stmia memset). On preemption the PC rewinds onto
    # the SWI with a continuation in r0: bit 31 marker, un-charged remainder
    # of the current phase in bits 8-29, pending flags in the low byte (the
    # interrupted phase's bit stays set; the clear offset derives from the
    # remainder). A remainder outside the phase-cost range (> 434375) is
    # treated as a fresh call.
    block ram_reset:
      var flags = cpu.r[0] and 0xFF'u32
      var resume = 0
      if (cpu.r[0] and 0x80000000'u32) != 0:
        let r = int((cpu.r[0] shr 8) and 0x3FFFFF)
        if r > 0 and r <= 434375:
          resume = r
      # (bit, phase cost, region size for progressive RAM clears; 0 = I/O)
      const PHASES = [(7, 549, 0), (5, 289, 0), (6, 338, 0),
                      (0, 434375, 0x40000), (3, 64711, 0x18000),
                      (4, 615, 0x400), (2, 871, 0x400), (1, 13303, 0x7E00)]
      template park(remaining_flags: uint32; remain: int) =
        cpu.r[0] = 0x80000000'u32 or (uint32(remain) shl 8) or remaining_flags
        cpu.hle_swi_rewind()
        break ram_reset
      template clear_ram(bit_idx: int; lo, hi: int) =
        ## Clear bytes [lo, hi) of the region selected by bit_idx
        case bit_idx
        of 0:
          for i in lo ..< hi: cpu.gba.bus.wram_board[i] = 0
        of 3:
          for i in lo ..< hi: cpu.gba.ppu.vram[i] = 0
        of 4:
          cpu.gba.ppu.oam_touched()  # bypasses the bus write paths
          for i in lo ..< hi: cpu.gba.ppu.oam[i] = 0
        of 2:
          for i in lo ..< hi: cpu.gba.ppu.pram[i] = 0
        else:
          for i in lo ..< hi: cpu.gba.bus.wram_chip[i] = 0
      for (bit_idx, phase_cost, region_size) in PHASES:
        if not bit(flags, bit_idx): continue
        let continuing = resume > 0
        var charge = phase_cost
        if continuing:
          charge = resume
          resume = 0
        if region_size == 0:
          # I/O phases: the writes are idempotent, so they run up front (again
          # on a resume), then the phase time is charged. Re-acknowledging IF
          # on a resumed bit-7 phase cannot swallow the preempting IRQ:
          # IE/IME = 0 made the later phases non-preemptible.
          let phase_t0 = cpu.hle_body_start()
          case bit_idx
          of 5:  # Reset SIO
            cpu.gba.serial.siocnt = 0
            cpu.gba.serial.rcnt = 0
          of 6:  # Reset sound (0x4000060-0x4000084)
            # Park the PSG waveform deadlines (gba/apu.nim); not a catch-up,
            # the pending steps are discarded
            cpu.gba.apu.apu_park_steps()
            cpu.gba.scheduler.clear(etAPUFrameSeq)
            cpu.gba.scheduler.clear(etAPUSample)
            cpu.gba.apu.sound_enabled = true
            # GBATEK: clears 0x60-0xAF, including wave RAM at 0x90-0x9F
            for offset in 0x60'u32..0x84'u32:
              cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
            for offset in 0x90'u32..0x9F'u32:
              cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
            for ch in 0..1:
              for i in 0..31: cpu.gba.apu.dma_channels.fifos[ch][i] = 0
              cpu.gba.apu.dma_channels.positions[ch] = 0
              cpu.gba.apu.dma_channels.sizes[ch]     = 0
              cpu.gba.apu.dma_channels.latches[ch]   = 0
            cpu.gba.apu.soundcnt_h = SOUNDCNT_H()
            # Re-schedule before any preemption so a park never leaves them cleared
            cpu.gba.apu.tick_frame_sequencer()
            cpu.gba.apu.get_sample()
          else:  # bit 7: reset all other I/O (except SIO and sound)
            for offset in 0x000'u32..0x05F'u32:
              cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
            for offset in 0x0B0'u32..0x0FF'u32:
              cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
            # The timers stop RRR_TIMER_STOP cycles into the phase on the
            # real BIOS, one word store per timer (TM0 started before the
            # swi reads 431 there, TM2 433; PeterLemon
            # BIOSRegisterRamReset's "other" row); the HLE's byte writes
            # above are quicker, so wait before the timer block.
            block:
              let early = RRR_TIMER_STOP - int(cpu.hle_body_start() - phase_t0)
              if early > 0 and not continuing: cpu.idle(early)
            for offset in countup(0x100'u32, 0x11C'u32, 4):
              cpu.gba.bus.write_word(0x04000000'u32 + offset, 0)
            for offset in 0x130'u32..0x133'u32:
              cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
            for offset in 0x15C'u32..0x1FF'u32:
              cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
            # The "other registers" group clears IE, acknowledges all IF bits,
            # resets WAITCNT and clears IME. Pokemon Pinball R/S calls this
            # while the previous program's sound-DMA IRQs still fire; without
            # the clear a stale IRQ dispatches through an unbuilt handler table.
            cpu.gba.bus.write_half(0x04000200'u32, 0x0000'u16)  # IE
            cpu.gba.bus.write_half(0x04000202'u32, 0xFFFF'u16)  # IF (ack all)
            cpu.gba.bus.write_half(0x04000204'u32, 0x0000'u16)  # WAITCNT
            cpu.gba.bus.write_half(0x04000208'u32, 0x0000'u16)  # IME
            # The display is left in forced blank, not zeroed
            cpu.gba.bus.write_half(0x04000000'u32, 0x0080'u16)
            # The affine parameters are left at the identity, not zero
            # (real BIOS under LLE: BG2PA/PD and BG3PA/PD read 0x100 after
            # the call); Spider-Man: Mysterio's Menace never writes them.
            cpu.gba.bus.write_half(0x04000020'u32, 0x0100'u16)  # BG2PA
            cpu.gba.bus.write_half(0x04000026'u32, 0x0100'u16)  # BG2PD
            cpu.gba.bus.write_half(0x04000030'u32, 0x0100'u16)  # BG3PA
            cpu.gba.bus.write_half(0x04000036'u32, 0x0100'u16)  # BG3PD
          # Top up to the phase cost in preemptible chunks
          if not continuing:
            charge = max(0, phase_cost - int(cpu.hle_body_start() - phase_t0))
          let remain = cpu.hle_charge_units_interruptible(charge)
          if remain > 0:
            park(flags and not (1'u32 shl bit_idx), remain)
        else:
          # RAM phases: clear ascending in step with the charged time (offset
          # derived from the remaining charge, so park/resume agree)
          template offset_at(rem: int): int =
            region_size - int(int64(region_size) * int64(rem) div int64(phase_cost))
          var remain = charge
          const CHUNK = 64
          while remain > 0:
            let step = min(remain, CHUNK)
            clear_ram(bit_idx, offset_at(remain), offset_at(remain - step))
            cpu.idle(step)
            remain -= step
            if remain > 0:
              cpu.gba.bus.catch_up()
              if cpu.hle_irq_deliverable():
                park(flags, remain)
        flags = flags and not (1'u32 shl bit_idx)
  of 0x0C:  # CpuFastSet
    # Routine frame (ARM 0xBC4): push {r4-r10, lr}, lr = 0x170
    block:
      let usp = cpu.sys_sp()
      cpu.gba.bus.write_word_internal(usp - 12, 0x170'u32)
      for i in 0 .. 6:  # r10 at usp-16 down to r4 at usp-40
        cpu.gba.bus.write_word_internal(usp - 16 - uint32(i * 4), cpu.r[10 - i])
    var src = cpu.r[0]
    var dst = cpu.r[1]
    let ctrl = cpu.r[2]
    let raw_count = bits_range(ctrl, 0, 20)
    # Validation uses the unrounded byte length; the 8-word rounding is later
    if not bios_addr_check(src, raw_count shl 2):
      cpu.idle(BIOS_CHECK_SKIP_COST)
    else:
      let count = (raw_count + 7) and not 7'u32  # round up to multiple of 8
      let fill = bit(ctrl, 24)
      # Routine cost (0xBC4): a fixed part, then per 8-word burst the loop
      # instructions plus an ldmia (copy only) and an stmia, each one
      # nonsequential access and seven sequential ones in its region. Fill:
      # 52 + the fill word's read, 5 + the stmia per burst; copy: 43, 7 +
      # both bursts per burst. Fitted to real-BIOS TM0 around the swi on 300
      # calls (1..256 words; sources IWRAM/EWRAM/VRAM/palette/ROM,
      # destinations IWRAM/EWRAM/VRAM; WAITCNT 0x0000 and 0x4317): exact on
      # all. The old per-word overhead (8 per burst, one too many for a copy
      # and three for a fill) and an uncharged fixed part put PeterLemon
      # BIOSCPUFASTSET 91 and 337 cycles out.
      let bus = cpu.gba.bus
      let sp = int(bits_range(src, 24, 27))
      let dp = int(bits_range(dst, 24, 27))
      let burst_s = int(bus.wait32_n[sp]) + 7 * int(bus.wait32_s[sp])
      let burst_d = int(bus.wait32_n[dp]) + 7 * int(bus.wait32_s[dp])
      let model_fixed = if fill: 52 + int(bus.wait32_n[sp]) else: 43
      let model_burst = if fill: 5 + burst_d else: 7 + burst_s + burst_d
      # Cartridge-bus sources are read uncharged: the bus would price every
      # word as the HLE interleaves them with the writes, not as the ldmia's
      # sequential burst the model charges. Everywhere else N == S and the
      # charged access is the model's own.
      let rom_src = sp >= 0x8 and sp <= 0xD
      let fill_val = if fill: bus.read_word(src) else: 0'u32
      var done = 0'u32
      var interrupted = false
      while done < count:
        let val = if fill: fill_val
                  elif rom_src: bus.read_word_internal(src)
                  else: bus.read_word(src)
        bus.write_word(dst, val)
        if not fill: src += 4
        dst += 4
        inc done
        # The check interval is a multiple of the 8-word burst so the
        # remaining count stays one too; the routine time is topped up per
        # chunk so mid-copy events and IRQs land at faithful positions.
        if (done and (HLE_COPY_IRQ_CHECK - 1)) == 0 and done < count:
          cpu.hle_charge_body(body_t0, model_fixed + model_burst * int(done div 8))
          bus.catch_up()
          if cpu.hle_irq_deliverable():
            interrupted = true
            break
      cpu.hle_charge_body(body_t0, model_fixed + model_burst * int(done div 8))
      cpu.r[0] = src
      cpu.r[1] = dst
      # The stm bursts go through r2-r9; r3 keeps the last word stored
      if done > 0:
        cpu.r[3] = if fill: fill_val
                   else: cpu.gba.bus.read_word_internal(dst - 4)
      if interrupted:
        cpu.r[2] = (ctrl and not 0x1FFFFF'u32) or (count - done)
        cpu.hle_swi_rewind()
  of 0x0D:  # GetBiosChecksum
    cpu.r[0] = 0xBAAE187F'u32
    # The routine sums the whole 16 KB image: a fixed 40960 cycles on the
    # real BIOS (TM0 around the swi, PeterLemon BIOSCHECKSUM's 0xA033), 10
    # per word. Charged preemptibly like the other long bodies.
    cpu.hle_charge_body_interruptible(body_t0, 40960)
  of 0x0E:  # BgAffineSet
    var src = cpu.r[0]
    var dst = cpu.r[1]
    let count = cpu.r[2]
    # Per entry: the accesses (a 3-word ldm, 3 halfwords read, 4 halfwords
    # + 2 words written, all else nonsequential; from ROM with the prefetch
    # buffer on one of the halfword reads is sequential, see rom_pf_seq16),
    # eight multiplies taking the scales and the display offsets as the
    # multiplier (two each), and 56 cycles besides; 23 fixed. Fitted to
    # real-BIOS TM0 around the swi: 300 single entries with random scales,
    # offsets and angles (the multiplier set is the only one of the
    # candidate operands that fits all), counts 0..5 with IWRAM/EWRAM
    # sources and destinations, ROM sources at WAITCNT 0x0000/0x0014/0x4317:
    # exact on all; gbaedge SWITIME's hardware 0x0146 (1 entry, ROM ->
    # EWRAM) is the ldm's two sequential words.
    let affine_model = block:
      let bus = cpu.gba.bus
      let sp = int(bits_range(src, 24, 27))
      let dp = int(bits_range(dst, 24, 27))
      23 + int(count) * (56 + int(bus.wait32_n[sp]) + 2 * int(bus.wait32_s[sp]) +
                         3 * int(bus.wait16_n[sp]) - bus.rom_pf_seq16(sp) +
                         4 * int(bus.wait16_n[dp]) + 2 * int(bus.wait32_n[dp]))
    var mul_cycles = 0
    for i in 0'u32 ..< count:
      let center_org_x = cast[int32](cpu.gba.bus.read_word(src))
      let center_org_y = cast[int32](cpu.gba.bus.read_word(src + 4))
      let display_cx = int32(cast[int16](cpu.gba.bus.read_half(src + 8)))
      let display_cy = int32(cast[int16](cpu.gba.bus.read_half(src + 10)))
      let scale_x = int32(cast[int16](cpu.gba.bus.read_half(src + 12)))
      let scale_y = int32(cast[int16](cpu.gba.bus.read_half(src + 14)))
      let angle = cpu.gba.bus.read_half(src + 16)
      let (pa, pb, pc, pd) = affine_params(scale_x, scale_y, angle)
      mul_cycles += 2 * (mul_i_cycles(cast[uint32](scale_x), true) +
                         mul_i_cycles(cast[uint32](scale_y), true) +
                         mul_i_cycles(cast[uint32](display_cx), true) +
                         mul_i_cycles(cast[uint32](display_cy), true))
      # 32-bit wrapping, as the routine computes it
      let start_x = cast[int32](uint32((int64(center_org_x) -
        (int64(pa) * display_cx + int64(pb) * display_cy)) and 0xFFFFFFFF))
      let start_y = cast[int32](uint32((int64(center_org_y) -
        (int64(pc) * display_cx + int64(pd) * display_cy)) and 0xFFFFFFFF))
      cpu.gba.bus.write_half(dst, cast[uint16](pa))
      cpu.gba.bus.write_half(dst + 2, cast[uint16](pb))
      cpu.gba.bus.write_half(dst + 4, cast[uint16](pc))
      cpu.gba.bus.write_half(dst + 6, cast[uint16](pd))
      cpu.gba.bus.write_word(dst + 8, cast[uint32](start_x))
      cpu.gba.bus.write_word(dst + 12, cast[uint32](start_y))
      src += 20
      dst += 16
    # Interruptible: a per-scanline table (count=160) is ~12k cycles, which
    # atomically would starve per-frame IRQ work such as SIO rounds.
    cpu.hle_charge_body_interruptible(body_t0, affine_model + mul_cycles)
  of 0x0F:  # ObjAffineSet
    var src = cpu.r[0]
    var dst = cpu.r[1]
    var count = cpu.r[2]
    let dst_stride = cpu.r[3]
    # Per entry: 3 halfword reads and 4 halfword writes, all nonsequential
    # (stride 2 and 8 cost the same), four multiplies taking the scales as
    # the multiplier (two each), 37 besides; 15 fixed. Real-BIOS TM0 around
    # the swi: exact on 32-entry runs with scales 0x100/0x7FFF/-0x8000/
    # 0x1234/-1/-0x100/3 and counts 0..5 into IWRAM/EWRAM/OAM, ROM sources
    # at WAITCNT 0x0000/0x0014/0x4317 (one read sequential with the prefetch
    # buffer on, as BgAffineSet).
    let affine_model = block:
      let bus = cpu.gba.bus
      let sp = int(bits_range(src, 24, 27))
      let dp = int(bits_range(dst, 24, 27))
      15 + int(count) * (37 + 3 * int(bus.wait16_n[sp]) - bus.rom_pf_seq16(sp) +
                         4 * int(bus.wait16_n[dp]))
    var mul_cycles = 0
    while count > 0:
      let sx = cast[int32](cast[int16](cpu.gba.bus.read_half(src)))
      let sy = cast[int32](cast[int16](cpu.gba.bus.read_half(src + 2)))
      let angle = cpu.gba.bus.read_half(src + 4)
      src += 8
      let (pa, pb, pc, pd) = affine_params(sx, sy, angle)
      mul_cycles += 2 * (mul_i_cycles(cast[uint32](sx), true) +
                         mul_i_cycles(cast[uint32](sy), true))
      cpu.gba.bus.write_half(dst, cast[uint16](pa)); dst += dst_stride
      cpu.gba.bus.write_half(dst, cast[uint16](pb)); dst += dst_stride
      cpu.gba.bus.write_half(dst, cast[uint16](pc)); dst += dst_stride
      cpu.gba.bus.write_half(dst, cast[uint16](pd)); dst += dst_stride
      count -= 1
    cpu.hle_charge_body_interruptible(body_t0, affine_model + mul_cycles)  # as BgAffineSet
  of 0x11:  # LZ77UnCompWram (8-bit writes)
    var src = cpu.r[0]
    let src_page = int(bits_range(src, 24, 27))
    let dst_page = int(bits_range(cpu.r[1], 24, 27))
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    # Header read first, then the post-increment source is validated
    if not bios_addr_check(src, decomp_len):
      cpu.idle(BIOS_CHECK_SKIP_COST)
      return
    var dst = cpu.r[1]
    var remaining = decomp_len
    var n_flags, n_lit, n_tok, n_runb = 0
    while remaining > 0:
      let flags = cpu.gba.bus[src]; src += 1; n_flags += 1
      for i in 0 ..< 8:
        if remaining == 0: break
        if bit(flags, 7 - i):
          # Compressed block
          let b1 = uint32(cpu.gba.bus[src]); src += 1
          let b2 = uint32(cpu.gba.bus[src]); src += 1
          let length = (b1 shr 4) + 3
          let offset = ((b1 and 0xF) shl 8) or b2
          n_tok += 1
          for j in 0'u32 ..< length:
            if remaining == 0: break
            cpu.gba.bus[dst] = cpu.gba.bus[dst - offset - 1]
            dst += 1; remaining -= 1; n_runb += 1
        else:
          # Uncompressed byte
          cpu.gba.bus[dst] = cpu.gba.bus[src]
          src += 1; dst += 1; remaining -= 1; n_lit += 1
    # Loop cost (routine 0x10FC) per token kind; rn/db = nonsequential byte
    # access at the src/dst pages. Run bytes: ldrb dst-offset + strb + loop.
    block:
      let bus = cpu.gba.bus
      let rn = int(bus.wait16_n[src_page])
      let db = int(bus.wait16_n[dst_page])
      cpu.hle_charge_body_interruptible(body_t0, 29 + int(bus.wait32_n[src_page]) +
        n_flags * (9 + rn) + n_lit * (16 + rn + db) +
        n_tok * (22 + 3 * rn) + n_runb * (7 + 2 * db))
  of 0x12:  # LZ77UnCompVram (16-bit writes)
    # Decompress into a local buffer, then copy out as halfwords: direct
    # VRAM decompression breaks back-references into an unflushed byte.
    var src = cpu.r[0]
    let src_page = int(bits_range(src, 24, 27))
    let dst_page = int(bits_range(cpu.r[1], 24, 27))
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    if not bios_addr_check(src, decomp_len):
      cpu.idle(BIOS_CHECK_SKIP_COST)
      return
    var buf = newSeq[uint8](decomp_len)
    var buf_pos: uint32 = 0
    var n_flags, n_lit, n_tok, n_runb = 0
    while buf_pos < decomp_len:
      let flags = cpu.gba.bus[src]; src += 1; n_flags += 1
      for i in 0 ..< 8:
        if buf_pos >= decomp_len: break
        if bit(flags, 7 - i):
          let b1 = uint32(cpu.gba.bus[src]); src += 1
          let b2 = uint32(cpu.gba.bus[src]); src += 1
          let length = (b1 shr 4) + 3
          let offset = ((b1 and 0xF) shl 8) or b2
          n_tok += 1
          for j in 0'u32 ..< length:
            if buf_pos >= decomp_len: break
            buf[buf_pos] = buf[buf_pos - offset - 1]
            buf_pos += 1; n_runb += 1
        else:
          buf[buf_pos] = cpu.gba.bus[src]
          src += 1; buf_pos += 1; n_lit += 1
    var dst = cpu.r[1]
    var idx: uint32 = 0
    while idx < decomp_len:
      if idx + 1 < decomp_len:
        cpu.gba.bus.write_half(dst, uint16(buf[idx]) or (uint16(buf[idx + 1]) shl 8))
        dst += 2; idx += 2
      else:
        cpu.gba.bus.write_half(dst, uint16(buf[idx]))
        dst += 2; idx += 1
    # Loop cost (routine 0x1194): heavier than the Wram variant, it buffers
    # bytes into halfwords and reads back-references with ldrh; each
    # completed output halfword adds one strh (+dh).
    block:
      let bus = cpu.gba.bus
      let rn = int(bus.wait16_n[src_page])
      let dh = int(bus.wait16_n[dst_page])
      cpu.hle_charge_body_interruptible(body_t0, 39 + int(bus.wait32_n[src_page]) +
        n_flags * (9 + rn) + n_lit * (20 + rn) + n_tok * (25 + 3 * rn) +
        n_runb * (21 + dh) + dh * int(decomp_len div 2))
  of 0x10:  # BitUnPack
    var src = cpu.r[0]
    let src_page = int(bits_range(src, 24, 27))
    let dst_page = int(bits_range(cpu.r[1], 24, 27))
    let info_page = int(bits_range(cpu.r[2], 24, 27))
    var dst = cpu.r[1]
    let info = cpu.r[2]
    let src_len = uint32(cpu.gba.bus.read_half(info))
    # The source length comes from the info block, then the region check
    if not bios_addr_check(src, src_len):
      cpu.idle(BIOS_CHECK_SKIP_COST)
      return
    let src_width = uint32(cpu.gba.bus[info + 2])
    let dest_width = uint32(cpu.gba.bus[info + 3])
    let data_offset = cpu.gba.bus.read_word(info + 4)
    let offset_val = data_offset and 0x7FFFFFFF'u32
    let zero_flag = bit(data_offset, 31)
    var out_word: uint32 = 0
    var out_bits: uint32 = 0
    let src_mask = (1'u32 shl src_width) - 1
    # dest_width may be 32, where a plain shift would be undefined
    let dest_mask = if dest_width >= 32: 0xFFFFFFFF'u32
                    else: (1'u32 shl dest_width) - 1
    var n_units, n_offset, n_words = 0
    for i in 0'u32 ..< src_len:
      let byte_val = uint32(cpu.gba.bus[src]); src += 1
      var bit_pos: uint32 = 0
      while bit_pos < 8:
        let val = (byte_val shr bit_pos) and src_mask
        var expanded: uint32
        inc n_units
        if val != 0 or zero_flag:
          expanded = val + offset_val
          inc n_offset
        else:
          expanded = 0
        out_word = out_word or ((expanded and dest_mask) shl out_bits)
        out_bits += dest_width
        if out_bits >= 32:
          cpu.gba.bus.write_word(dst, out_word)
          dst += 4
          out_word = 0
          out_bits = 0
          inc n_words
        bit_pos += src_width
    # Routine cost: a fixed 59 and the info block's reads (two words and
    # three halfword/byte accesses, by the region they cost); per source
    # byte 12 + its ldrb; per unit 22, +2 when the offset is added (nonzero
    # unit, or the zero flag); per full output word 1 + its str. Fitted to
    # real-BIOS TM0 around the swi on 918 calls (every source and
    # destination width, 1..33 bytes, zero/random/all-ones data, offset and
    # zero-flag combinations; IWRAM/EWRAM sources, IWRAM/EWRAM/VRAM
    # destinations) and the info block in IWRAM/EWRAM/ROM (one of its reads
    # sequential from ROM with the prefetch buffer on): exact on all.
    block:
      let bus = cpu.gba.bus
      cpu.hle_charge_body_interruptible(body_t0, 59 +
        3 * int(bus.wait16_n[info_page]) + 2 * int(bus.wait32_n[info_page]) -
        bus.rom_pf_seq16(info_page) +
        int(src_len) * (12 + int(bus.wait16_n[src_page])) +
        n_units * 22 + n_offset * 2 +
        n_words * (1 + int(bus.wait32_n[dst_page])))
  of 0x13:  # HuffUnComp
    var src = cpu.r[0]
    let src_page = int(bits_range(src, 24, 27))
    let dst_page = int(bits_range(cpu.r[1], 24, 27))
    # The routine (0x1014) validates the raw source with a constant
    # 0x02000000 "length", which adds no bits to the end-address test
    if not bios_addr_check(src, 0x02000000'u32):
      cpu.idle(BIOS_CHECK_SKIP_COST)
      return
    let header = cpu.gba.bus.read_word(src)
    let data_size = header and 0xF  # 4 or 8 bits
    let decomp_len = header shr 8
    src += 4
    let tree_size = uint32(cpu.gba.bus[src])
    let tree_start = src + 1
    let data_start = src + (tree_size * 2) + 2
    var data_pos = (data_start + 3) and not 3'u32
    var dst = cpu.r[1]
    var written: uint32 = 0
    var out_word: uint32 = 0
    var out_bits: uint32 = 0
    var cur_node = tree_start
    var cur_word: uint32 = 0
    var bits_left: int = 0
    var n_node, n_leaf, n_leaf_seq, n_words, n_outw = 0
    while written < decomp_len:
      if bits_left == 0:
        cur_word = cpu.gba.bus.read_word(data_pos)
        data_pos += 4
        bits_left = 32
        n_words += 1
      let cur_bit = (cur_word shr 31) and 1
      cur_word = cur_word shl 1
      bits_left -= 1
      let node_val = uint32(cpu.gba.bus[cur_node])
      let child_offset = node_val and 0x3F
      let right_is_leaf = bit(node_val, 6)
      let left_is_leaf = bit(node_val, 7)
      let next_addr = (cur_node and not 1'u32) + (child_offset + 1) * 2
      let is_right = cur_bit == 1
      let child_addr = next_addr + (if is_right: 1'u32 else: 0'u32)
      let is_leaf = if is_right: right_is_leaf else: left_is_leaf
      if is_leaf:
        n_leaf += 1
        # The symbol read lands on the node's address + 2 (offset 0, the
        # child on the node's own parity): sequential from ROM with the
        # prefetch buffer on (rom_pf_seq16)
        if child_addr == cur_node + 2: n_leaf_seq += 1
        let leaf_val = uint32(cpu.gba.bus[child_addr])
        if data_size == 4:
          out_word = out_word or (leaf_val shl out_bits)
          out_bits += 4
        else:
          out_word = out_word or (leaf_val shl out_bits)
          out_bits += 8
        if out_bits >= 32:
          cpu.gba.bus.write_word(dst, out_word)
          dst += 4
          written += 4
          out_word = 0
          out_bits = 0
          n_outw += 1
        cur_node = tree_start
      else:
        n_node += 1
        cur_node = child_addr
    # Tree-walk cost (routine 0x1014): per input bit, a fixed budget plus two
    # ldrb tree reads (the node byte is re-read for the leaf flags); a leaf
    # adds the symbol ldrb, a stack reload and the root reset; each output
    # word one str, each bitstream refill one ldr. Real-BIOS TM0 around the
    # swi: exact on 204 streams (4- and 8-bit, 2..9 symbols, 4..256 bytes;
    # IWRAM/EWRAM/ROM sources at WAITCNT 0x0000/0x0014/0x4014/0x4317,
    # IWRAM/EWRAM/VRAM destinations).
    block:
      let bus = cpu.gba.bus
      let b = int(bus.wait16_n[src_page])   # nonseq byte read at src
      let w = int(bus.wait32_n[src_page])   # nonseq word read at src
      let d = int(bus.wait32_n[dst_page])   # nonseq word write at dst
      # (the tree-size byte after the header word is the fixed part's
      # sequential read)
      cpu.hle_charge_body_interruptible(body_t0, 57 + 2 * b + w +
        n_node * (25 + 2 * b) + n_leaf * (39 + 3 * b) -
        (1 + n_leaf_seq) * bus.rom_pf_seq16(src_page) +
        n_outw * d + n_words * (9 + w))
  of 0x14:  # RLUnCompWram (8-bit writes)
    var src = cpu.r[0]
    let src_page = int(bits_range(src, 24, 27))
    let dst_page = int(bits_range(cpu.r[1], 24, 27))
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    if not bios_addr_check(src, decomp_len):
      cpu.idle(BIOS_CHECK_SKIP_COST)
      return
    var dst = cpu.r[1]
    var written: uint32 = 0
    var n_flags, n_lit, n_rruns, n_runb = 0
    while written < decomp_len:
      let flag = uint32(cpu.gba.bus[src]); src += 1; n_flags += 1
      if bit(flag, 7):
        # Compressed run
        let length = (flag and 0x7F) + 3
        let val = cpu.gba.bus[src]; src += 1
        n_rruns += 1
        for j in 0'u32 ..< length:
          if written >= decomp_len: break
          cpu.gba.bus[dst] = val
          dst += 1; written += 1; n_runb += 1
      else:
        # Uncompressed run
        let length = (flag and 0x7F) + 1
        for j in 0'u32 ..< length:
          if written >= decomp_len: break
          cpu.gba.bus[dst] = cpu.gba.bus[src]
          src += 1; dst += 1; written += 1; n_lit += 1
    # Loop cost (Thumb routine 0x1278): flag decode, literal ldrb+strb,
    # run fill byte read once then strb per output byte. Fitted to
    # real-BIOS TM0 around the swi on 44 streams (1..8 random tokens and
    # single literals/runs of 1..128 bytes; IWRAM/EWRAM sources and
    # destinations): exact on all (the old 40/10/11/9/7 put PeterLemon
    # BIOSRLE 5849 cycles slow, and the Vram form 4550 fast).
    block:
      let bus = cpu.gba.bus
      let rn = int(bus.wait16_n[src_page])
      let db = int(bus.wait16_n[dst_page])
      cpu.hle_charge_body_interruptible(body_t0, 42 + int(bus.wait32_n[src_page]) +
        n_flags * (12 + rn) + n_lit * (9 + rn + db) +
        n_rruns * (5 + rn) + n_runb * (6 + db))
  of 0x15:  # RLUnCompVram (16-bit writes)
    var src = cpu.r[0]
    let src_page = int(bits_range(src, 24, 27))
    let dst_page = int(bits_range(cpu.r[1], 24, 27))
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    if not bios_addr_check(src, decomp_len):
      cpu.idle(BIOS_CHECK_SKIP_COST)
      return
    var dst = cpu.r[1]
    var written: uint32 = 0
    var out_buf: uint16 = 0
    var out_idx: uint32 = 0
    var n_flags, n_lit, n_rruns, n_runb, n_halves = 0
    while written < decomp_len:
      let flag = uint32(cpu.gba.bus[src]); src += 1; n_flags += 1
      if bit(flag, 7):
        # Compressed run
        let length = (flag and 0x7F) + 3
        let val = cpu.gba.bus[src]; src += 1
        n_rruns += 1
        for j in 0'u32 ..< length:
          if written >= decomp_len: break
          if (out_idx and 1) == 0:
            out_buf = uint16(val)
          else:
            out_buf = out_buf or (uint16(val) shl 8)
            cpu.gba.bus.write_half(dst and not 1'u32, out_buf)
            n_halves += 1
          dst += 1; written += 1; out_idx += 1; n_runb += 1
      else:
        # Uncompressed run
        let length = (flag and 0x7F) + 1
        for j in 0'u32 ..< length:
          if written >= decomp_len: break
          let val = cpu.gba.bus[src]; src += 1
          if (out_idx and 1) == 0:
            out_buf = uint16(val)
          else:
            out_buf = out_buf or (uint16(val) shl 8)
            cpu.gba.bus.write_half(dst and not 1'u32, out_buf)
            n_halves += 1
          dst += 1; written += 1; out_idx += 1; n_lit += 1
    # Loop cost (Thumb routine 0x12C0): the flag decode spills through the
    # stack, literals buffer into halfwords, runs replay the spilled fill
    # byte, each completed output halfword is one strh. Fitted as the Wram
    # form above (58 streams, VRAM destinations too): exact on all.
    block:
      let bus = cpu.gba.bus
      let rn = int(bus.wait16_n[src_page])
      let dh = int(bus.wait16_n[dst_page])
      cpu.hle_charge_body_interruptible(body_t0, 46 + int(bus.wait32_n[src_page]) +
        n_flags * (20 + rn) + n_lit * (15 + rn) +
        n_rruns * (7 + rn) + n_runb * 15 + n_halves * (1 + dh))
  of 0x16:  # Diff8bitUnFilterWram (8-bit writes)
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    if not bios_addr_check(src, decomp_len):
      cpu.idle(BIOS_CHECK_SKIP_COST)
      return
    var dst = cpu.r[1]
    var written: uint32 = 0
    var prev = cpu.gba.bus[src]; src += 1
    cpu.gba.bus[dst] = prev
    dst += 1; written += 1
    while written < decomp_len:
      let diff = cpu.gba.bus[src]; src += 1
      prev = uint8((uint32(prev) + uint32(diff)) and 0xFF)
      cpu.gba.bus[dst] = prev
      dst += 1; written += 1
    # Loop cost: 29 + the header read, 11 + an ldrb and an strb per byte.
    # The three Diff filters are fitted to real-BIOS TM0 around the swi on
    # 36 calls each (2..200 bytes, IWRAM/EWRAM sources, IWRAM/EWRAM/VRAM
    # destinations): exact on all (PeterLemon BIOSDIFF).
    block:
      let bus = cpu.gba.bus
      let sp = int(bits_range(cpu.r[0], 24, 27))
      let dp = int(bits_range(cpu.r[1], 24, 27))
      cpu.hle_charge_body_interruptible(body_t0, 29 + int(bus.wait32_n[sp]) +
        int(decomp_len) * (11 + int(bus.wait16_n[sp]) + int(bus.wait16_n[dp])))
  of 0x17:  # Diff8bitUnFilterVram (16-bit writes)
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    if not bios_addr_check(src, decomp_len):
      cpu.idle(BIOS_CHECK_SKIP_COST)
      return
    var dst = cpu.r[1]
    var written: uint32 = 0
    var out_buf: uint16 = 0
    var out_idx: uint32 = 0
    var prev = cpu.gba.bus[src]; src += 1
    out_buf = uint16(prev)
    out_idx += 1
    dst += 1; written += 1
    while written < decomp_len:
      let diff = cpu.gba.bus[src]; src += 1
      prev = uint8((uint32(prev) + uint32(diff)) and 0xFF)
      if (out_idx and 1) == 0:
        out_buf = uint16(prev)
      else:
        out_buf = out_buf or (uint16(prev) shl 8)
        cpu.gba.bus.write_half(dst and not 1'u32, out_buf)
      dst += 1; written += 1; out_idx += 1
    # Loop cost: 31 + the header read, 18 + an ldrb per byte, an strh per
    # output halfword (fitted with 0x16)
    block:
      let bus = cpu.gba.bus
      let sp = int(bits_range(cpu.r[0], 24, 27))
      let dp = int(bits_range(cpu.r[1], 24, 27))
      cpu.hle_charge_body_interruptible(body_t0, 31 + int(bus.wait32_n[sp]) +
        int(decomp_len) * (18 + int(bus.wait16_n[sp])) +
        int(decomp_len div 2) * int(bus.wait16_n[dp]))
  of 0x18:  # Diff16bitUnFilter
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    if not bios_addr_check(src, decomp_len):
      cpu.idle(BIOS_CHECK_SKIP_COST)
      return
    var dst = cpu.r[1]
    var written: uint32 = 0
    var prev = cpu.gba.bus.read_half(src); src += 2
    cpu.gba.bus.write_half(dst, prev)
    dst += 2; written += 2
    while written < decomp_len:
      let diff = cpu.gba.bus.read_half(src); src += 2
      prev = uint16((uint32(prev) + uint32(diff)) and 0xFFFF)
      cpu.gba.bus.write_half(dst, prev)
      dst += 2; written += 2
    # Loop cost: 29 + the header read, 11 + an ldrh and an strh per
    # halfword (fitted with 0x16). From ROM with the prefetch buffer on the
    # first halfword, right after the header, reads sequential (the rest do
    # not: real-BIOS TM0 at WAITCNT 0x4317 is 2 cycles quicker, not 2 per
    # halfword).
    block:
      let bus = cpu.gba.bus
      let sp = int(bits_range(cpu.r[0], 24, 27))
      let dp = int(bits_range(cpu.r[1], 24, 27))
      cpu.hle_charge_body_interruptible(body_t0, 29 + int(bus.wait32_n[sp]) -
        bus.rom_pf_seq16(sp) +
        int(written div 2) * (11 + int(bus.wait16_n[sp]) + int(bus.wait16_n[dp])))
  of 0x19:  # SoundBias(r0): 0 -> SOUNDBIAS 0x000, else 0x200
    # The real BIOS ramps the level one step (register value 2) at a time:
    # r0 = 0 walks it down to 0, any other r0 walks it up to 0x200 and never
    # down (0x3FE stays 0x3FE). The ramp lands at once here, the time is
    # charged: 20 cycles, plus 61 per step and 2 once when falling, 62 per
    # step when rising (real-BIOS TM0 around the swi from 0x000, 0x002,
    # 0x100, 0x1FE, 0x200, 0x3FE, both directions: exact; PeterLemon
    # BIOSSoundBias's 0x200 -> 0x200 is the bare 20). The other SOUNDBIAS
    # bits are kept. bias_level is the 9-bit field at bits 1-9, so register
    # 0x200 = 0x100.
    let level = int(cpu.gba.apu.soundbias.bias_level)
    var model = 20
    if cpu.r[0] == 0:
      if level > 0: model += 2 + 61 * level
      cpu.gba.apu.soundbias.bias_level = 0
    elif level < 0x100:
      model += 62 * (0x100 - level)
      cpu.gba.apu.soundbias.bias_level = 0x100
    cpu.hle_charge_body_interruptible(body_t0, model)
  # Sound driver / music player stubs (games use their own engine). The
  # engine is not modeled, but the routines' time with no driver installed
  # is (real-BIOS TM0 around the swi, [0x03007FF0] null or pointing at a
  # non-driver area; PeterLemon BIOSSoundDriver*/ChannelClear rows).
  of 0x1A:  # SoundDriverInit
    # Not timed: the real routine spins until VCOUNT reads 159 (it returns
    # on line 159 from any phase, up to a frame later) and then programs
    # Timer 0, sound DMA 1/2 (CNT_H 0xB600), SOUNDCNT_H and the SoundArea
    # for the BIOS mixer, none of which the HLE models (PeterLemon
    # BIOSSoundDriverInit reads the reprogrammed Timer 0).
    discard
  of 0x1B: cpu.idle(29)  # SoundDriverMode
  of 0x1D: cpu.idle(16)  # SoundDriverVSync
  of 0x1E: cpu.idle(31)  # SoundChannelClear
  of 0x28: cpu.idle(30)  # SoundDriverVSyncOff
  of 0x29: cpu.idle(9)   # SoundDriverVSyncOn
  of 0x20, 0x21, 0x22, 0x23, 0x24:
    discard  # MusicPlayer stubs (not timed: their cost follows the player)
  of 0x1C:  # SoundDriverMain
    if not cpu.gba.bus.stub_bios:
      return  # a real BIOS image is mapped (hle_after_bios): no stub trampolines
    # Run the stub-BIOS SoundMain dispatch (thumb at the routine's address,
    # 0x1DC4): it checks the SoundInfo ident at [0x03007FF0], and if an
    # MP2K driver is installed locks the engine and calls the game's ROM
    # callbacks (Cyberdrive Zoids blocks its main loop on them). The BIOS
    # PCM mixer is not modeled. The stub runs in SVC mode like the
    # dispatcher; its closing `swi 0` is the `movs pc, lr` exit trap (0x00).
    let isa_step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
    let old_cpsr = cpu.cpsr
    let ret = cpu.r[15] - isa_step
    cpu.switch_mode(modeSVC)
    cpu.spsr = old_cpsr
    cpu.r[14] = ret
    cpu.cpsr.thumb = true
    discard cpu.set_reg(15, 0x1DC4'u32 - isa_step)
  of 0x2A:  # SoundGetJumpList
    # Copy the 36 sound-driver pointers from the BIOS table (0x3738) to
    # [r0]; the stub BIOS backs them with code (new_bus). Routine (0x2692)
    # protocol: r0 past the destination, r1 = 0, r2 past the table, r3 =
    # the last entry.
    block:
      var dst = cpu.r[0]
      var last = 0'u32
      for i in 0 ..< 36:
        # Direct read: the BIOS-protection latch does not apply to BIOS code
        let o = 0x3738 + i * 4
        last = uint32(cpu.gba.bus.bios[o]) or
               (uint32(cpu.gba.bus.bios[o + 1]) shl 8) or
               (uint32(cpu.gba.bus.bios[o + 2]) shl 16) or
               (uint32(cpu.gba.bus.bios[o + 3]) shl 24)
        cpu.gba.bus.write_word(dst, last)
        dst += 4
      cpu.r[0] = dst
      cpu.r[1] = 0
      cpu.r[2] = 0x37C8'u32
      cpu.r[3] = last
      # Per word: the table ldr, the validation subroutine and the stmia.
      # Real-BIOS TM0 around the swi, destination in IWRAM, EWRAM and VRAM:
      # 1257/1437/1293 cycles, the dispatch included (PeterLemon
      # BIOSSoundGetJumpList). The word count is fixed, so the split between
      # the fixed and per-word terms is not observable; 3 / 32 is one that fits.
      let dst_page = int(bits_range(cpu.r[0], 24, 27))
      cpu.hle_charge_body(body_t0, 3 + 36 * (32 + int(cpu.gba.bus.wait32_n[dst_page])))
  of 0x1F:  # MidiKey2Freq
    let base_freq = cpu.gba.bus.read_word(cpu.r[0] + 4)
    var key = cast[int32](cpu.r[1])
    var pitch = cast[int32](cpu.r[2])
    # Keys above 178 clamp to key 178 with fine pitch 255 (real BIOS under
    # LLE: every key 179..255 returns the same value). Body cost from
    # real-BIOS TM0 around the swi over keys 0..255 and pitches 0..255: 88,
    # +1 for a key in the top octaves (84 and up), +3 for a nonzero pitch;
    # a clamped key costs 94; plus the WaveData read. The multiply by the
    # base frequency does not move it (0x10 .. 0xFFFFFFFF alike).
    let wave_page = int(bits_range(cpu.r[0] + 4, 24, 27))
    var model = 88 + int(cpu.gba.bus.wait32_n[wave_page])
    if cast[uint32](key) > 178:
      key = 178
      pitch = 255
      model += 6
    else:
      if key >= 84: model += 1
      if pitch != 0: model += 3
    cpu.hle_charge_body(body_t0, model)
    # Reference key 180, not middle C: WaveData.freq stores the sample rate
    # scaled up 10 octaves (Metroid Fusion intro aliases with 60).
    let exponent = (float64(key) - 180.0 + float64(pitch) / 256.0) / 12.0
    let freq = float64(base_freq) * pow(2.0, exponent)
    cpu.r[0] = uint32(freq)
  of 0x25:  # MultiBoot
    cpu.r[0] = 1'u32  # failure: multiboot is not emulated
  else:
    echo "unimplemented SWI: 0x", toHex(swi_num, 2)
