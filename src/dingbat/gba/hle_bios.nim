# HLE BIOS implementation (included by gba.nim)

proc hle_busy(cpu: CPU; n: int) {.inline.} =
  ## Routine time: BIOS instructions, every one a bus access (a 1-cycle
  ## BIOS fetch at least). Not cpu.idle: internal cycles let a DMA burst
  ## run under them for free (Bus.idle_window), which the routine's
  ## fetches never do.
  cpu.gba.bus.add_cycles(n)

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

proc hle_div(cpu: CPU; numer_reg, denom_reg: int): int =
  ## Sets the results; returns the body cost (div_body_cycles) on top of the
  ## dispatch: mGBA suite "BIOS Division" timing rows plus the real-BIOS TM0
  ## measurements noted there.
  let numer = int64(cast[int32](cpu.r[numer_reg]))
  let denom = int64(cast[int32](cpu.r[denom_reg]))
  result = div_body_cycles(uint32(abs(numer) and 0xFFFFFFFF),
                           uint32(abs(denom) and 0xFFFFFFFF))
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

# --- System-stack wait states ---
#
# The routine-cost models below were fitted with the System stack in IWRAM,
# where a stack word costs one cycle like any BIOS access. The real BIOS
# pays the stack's region for every word: the dispatcher's push {r2, lr}
# and its pop, each routine's own frame, and the few routines that spill to
# the stack inside their loops. Games that run tasks on EWRAM stacks (Mario
# Party Advance) pay 5 more cycles a word there; the HLE charged none of it,
# so its copies ran 50-100 cycles short and the game's timer-seeded random
# numbers came out different. tools/biosdrv/swisp.c and swisp2.c: every
# timed SWI from both stacks, against the official BIOS in this core: the
# BIOS's stack accesses (BD_MEMTRACE/BD_MEMREAD) times the EWRAM premium
# account for every cycle of the difference, and the counts below are those
# accesses.

proc sys_stack_waits(cpu: CPU): (int, int) {.inline.} =
  ## What a nonsequential and a sequential System-stack word cost beyond the
  ## one cycle the fitted models already price (0 for IWRAM).
  let bus = cpu.gba.bus
  let page = int(bits_range(cpu.sys_sp(), 24, 27))
  (max(0, int(bus.wait32_n[page]) - 1), max(0, int(bus.wait32_s[page]) - 1))

proc stack_block(waits: (int, int); words: int): int {.inline.} =
  ## The premium on one push/pop of `words` words (an stm/ldm: the first
  ## access nonsequential, the rest sequential).
  if words <= 0: 0 else: waits[0] + (words - 1) * waits[1]

proc swi_frame(swi_num: uint32): (int, int, int) =
  ## A routine's own System-stack frame below the dispatcher's {r2, lr}:
  ## words pushed, then the pop as one or two ldm/pop blocks. Only what the
  ## HLE still prices this way needs it: an IntrWait, a CpuSet or a
  ## CpuFastSet an earlier build left parked (check_intr_wait, hle_copy.nim).
  ## The routines hle_unc.nim runs push and pop their frames as steps.
  case swi_num
  of 0x04, 0x05: (2, 2, 0)                  # IntrWait: push {r4, lr}
  of 0x0B: (3, 2, 1)                        # CpuSet: push {r4, r5, lr}
  of 0x0C: (8, 8, 0)                        # CpuFastSet: push {r4-r10, lr}
  else: (0, 0, 0)

proc swi_stack_entry(cpu: CPU; swi_num: uint32): int =
  ## The stack premium before the routine body: the dispatcher's push and
  ## the routine's.
  let w = cpu.sys_stack_waits()
  if w[0] == 0 and w[1] == 0: return 0
  w.stack_block(2) + w.stack_block(swi_frame(swi_num)[0])

proc swi_stack_exit(cpu: CPU; swi_num: uint32): int =
  ## The stack premium after it: the routine's pop and the dispatcher's.
  let w = cpu.sys_stack_waits()
  if w[0] == 0 and w[1] == 0: return 0
  let f = swi_frame(swi_num)
  w.stack_block(f[1]) + w.stack_block(f[2]) + w.stack_block(2)

proc set_sys_sp(cpu: CPU; v: uint32) {.inline.} =
  if mode_bank(cast[CpuMode](cpu.cpsr.mode)) == 0: cpu.r[13] = v
  else: cpu.reg_banks[0][5] = v

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
    # The two frame pops are System-stack loads: an EWRAM stack makes the
    # return later (tools/biosdrv/swisp.c: 20 cycles, 4 words).
    cpu.gba.bus.add_cycles(INTRWAIT_TUNE + cpu.swi_stack_exit(0x04) -
                           (when HALT_WAKE_RUNS_ONE: HALT_WAKE_INSTR_COST else: 0))
  else:
    # Re-halt with the check subroutine's register state: r0 = 0, r12 = the
    # I/O base, r2 = the mirror, r4 = 1, lr_sys = 0x34C
    cpu.r[0] = 0
    cpu.r[12] = 0x04000000'u32
    cpu.r[2] = uint32(cpu.read_intr_mirror())
    cpu.r[4] = 1
    cpu.set_sys_lr(0x34C'u32)
    if cpu.cpsr.irq_disable:
      # Waiting with IRQs masked in CPSR: the halt wakes at once on any
      # pending source, no handler can run to set the flags, and the BIOS
      # spins round its check loop for ever. That loop takes time; without
      # it the HLE re-halted and woke on the same cycle and never returned
      # from the frame (the state soak's random GBA program, once a stray DMA
      # had switched board WRAM off and the stack had gone astray).
      cpu.gba.bus.add_cycles(INTRWAIT_TUNE)
    cpu.halted = true
    cpu.gba.interrupts.schedule_interrupt_check()

# SWI entry/dispatch/return cost, excluding the caller-side pipeline refill
# charged per region in hle_swi. mGBA suite BIOS timing rows (IWRAM column).
const SWI_HLE_BASE = 48
# The part of it after the routine: the return path from 0x170, refill
# excluded (official BIOS in this core, as HALT_BIOS_RETURN)
const SWI_HLE_EXIT = 16

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

proc hle_body_start(cpu: CPU): int64 {.inline.} =
  int64(cpu.gba.scheduler.cycles) + int64(cpu.gba.bus.cycles)

proc hle_body_now(cpu: CPU): int64 {.inline.} =
  ## The routine-body clock: hle_body_start net of the time DMA bursts
  ## stopped the CPU. The real routine's instruction fetches and data
  ## accesses all need the bus, so a burst inside it delays it by the
  ## burst's full length; a model topped up against the plain clock let
  ## the burst eat into the routine instead (Top Gun - Combat Zones'
  ## LZ77UnCompWram returned ~58 cycles early when one landed in it).
  cpu.hle_body_start() - cpu.gba.bus.dma_stall_total

proc hle_charge_body(cpu: CPU; t0: int64; model: int) {.inline.} =
  ## Top up what the body charged since `t0` (an hle_body_now) to `model`.
  let charged = int(cpu.hle_body_now() - t0)
  if model > charged:
    cpu.hle_busy(model - charged)

proc bios_addr_check(address, length: uint32): bool {.inline.} =
  ## The BIOS source-region check (0xBA4) every copy/decompression SWI runs
  ## first. False = the BIOS silently skips the operation: zero length,
  ## source below 0x02000000, or source+length (length masked to 25 bits)
  ## leaving the 0x02000000-0x0FFFFFFF address bits. Games rely on the skip:
  ## Riviera's decompression queue ends with a src=0xFFFFFFFF entry.
  if length == 0: return false
  if (address and 0x0E000000'u32) == 0: return false
  ((address + (length and 0x01FFFFFF'u32)) and 0x0E000000'u32) != 0

# The copy, decompression and unpack SWIs run with the caller's IRQ mask, so
# any deliverable interrupt preempts them mid-loop. Card E-Reader boot-loads
# a 22 KB IWRAM program over its own live IRQ handler with one CpuSet and
# needs the vblank serviced through the old handler first. hle_unc.nim runs
# them as stub-BIOS code, so an interrupt is taken between two of their
# instructions as on the console.


proc hle_irq_now(cpu: CPU): bool {.inline.} =
  ## The CPU would take an interrupt at its next instruction boundary (what
  ## cpu.tick tests): IF raised, through the synchroniser, unmasked.
  cpu.irq_line and not cpu.cpsr.irq_disable

proc hle_step(cpu: CPU; remain: int): int =
  ## How much of `remain` cycles of routine time to charge before the next
  ## scheduler event (at least 1), with the scheduler caught up.
  let bus = cpu.gba.bus
  bus.catch_up()
  let now = int64(bus.sched.cycles) + int64(bus.cycles)
  let ev = min(uint64(bus.sched.next_event), 1'u64 shl 60).int64
  int(clamp(ev - now, 1'i64, int64(remain)))

proc hle_frame_ended(cpu: CPU): bool {.inline.} =
  ## The video frame ended inside the routine: the frontend's frame loop
  ## (gba.step_frame) would have stopped the real BIOS at its next
  ## instruction there.
  cpu.gba.ppu.frame != 0

proc hle_charge_units_interruptible(cpu: CPU; n: int): int =
  ## Charge `n` cycles of routine time with the scheduler caught up, up to
  ## each event in turn (only an event can raise the interrupt line), so the
  ## routine stops on the cycle the line rises, where the real routine,
  ## running with the caller's IRQ mask, is preempted at its next
  ## instruction. Returns the un-charged remainder when that happens, else
  ## 0. At least one cycle is charged per call, so a parked remainder always
  ## makes progress. (64-cycle chunks took an interrupt up to 78 cycles
  ## late: Castlevania - Circle of the Moon's timer handler then found its
  ## busy-wait loop at another phase every frame after f324's LZ77UnCompWram.)
  ## It stops at the end of a video frame too: run as one instruction, a
  ## routine longer than the time left in the frame carried the frame loop
  ## past its end, so the frame's last lines were drawn after the routine
  ## (and the next frame's first lines into the frame shown, when it ran on
  ## past them) and the keys for the next frame came in late. The remainder
  ## is the same parked charge an interrupt leaves (hle_park_frame_extra).
  var remain = n
  var first = true
  while remain > 0:
    let step = if first and cpu.hle_irq_now(): 1 else: cpu.hle_step(remain)
    first = false
    cpu.hle_busy(step)
    remain -= step
    if remain > 0:
      cpu.gba.bus.catch_up()
      if cpu.hle_irq_now() or cpu.hle_frame_ended():
        return remain
  0

proc hle_handler_refill_extra*(cpu: CPU; cur: uint32): int =
  ## A routine remainder an earlier build parked at `cur` (the old
  ## interruptible charge of the decompressors and math routines) is
  ## resumed after the preempting handler returns there, refilling the
  ## pipeline in the caller's region, where the real routine's handler
  ## returns into BIOS code (two 1-cycle fetches): the resume takes the
  ## difference back out of the remainder (cpu.tick).
  let bus = cpu.gba.bus
  let page = int(bits_range(cur, 24, 27))
  let refill = if cpu.cpsr.thumb: int(bus.wait16_n[page]) + int(bus.wait16_s[page])
               else: int(bus.wait32_n[page]) + int(bus.wait32_s[page])
  max(0, refill - (int(bus.wait32_n[0]) + int(bus.wait32_s[0])))

proc hle_park_frame_extra*(cpu: CPU; cur: uint32): int {.inline.} =
  ## What a remainder parked at a frame's end, with no interrupt to take,
  ## carries on top: no handler returns there, so nothing is to be taken
  ## back, and the resume's deduction must net out.
  if cpu.hle_irq_now(): 0 else: cpu.hle_handler_refill_extra(cur)

type HleCont = object
  ## Renderer contention for a routine body whose accesses are uncharged:
  ## each access to palette RAM, VRAM or OAM is priced by contention.nim for
  ## the cycle the real routine makes it at, which the body's model clock
  ## `clk` tracks, read with the display registers as they stand. The copies
  ## asked unit by unit as their time ran (hle_copy.nim, for a copy an
  ## earlier build parked).
  on: bool     # the routine touches palette RAM, VRAM or OAM
  t0: int64    # the body's start (hle_body_now), where `clk` counts from
  extra: int   # renderer waits so far

proc hle_cont_start(cpu: CPU; t0: int64; page_a, page_b: int): HleCont =
  HleCont(on: (page_a >= 5 and page_a <= 7) or (page_b >= 5 and page_b <= 7), t0: t0)

proc hle_cont_ahead(cpu: CPU; c: var HleCont; clk: int; address: uint32;
                    is32: bool) {.inline.} =
  ## An access the routine makes `clk` model cycles into its body (later by
  ## the waits before it).
  if c.on:
    c.extra += cpu.gba.bus.contend_wait_ahead(address, is32,
                                              int(c.t0 - cpu.hle_body_now()) + clk + c.extra)

# Halt (SWI 2) runs where Nintendo's does: parked on the `bx lr` after the
# routine's HALTCNT write (stub 0x1B4) in System mode, so a wake runs that
# instruction to the dispatcher's return at 0x170 and an interrupt is taken
# with the BIOS address the console's handlers find on the IRQ stack
# (alyosha irq/halt_pc, Interactions/Halt_IRQ, Halt_DMA_IRQ read it: lr 0x174
# after a sleep, 0x1B8 when the interrupt was recognised by the write). The
# return is a trap at 0x170 (cpu.hle_halt_return) that pops what this pushed:
# every piece of the halt is architectural, nothing rides in HLE fields.
#
# Cycles, measured against Nintendo's BIOS in this core (halt from ROM ARM,
# ROM Thumb and IWRAM, woken by a timer with and without IME, and ending at
# once on a pending flag): the dispatcher reads the swi's comment byte in the
# caller's region HALT_COMMENT_READ_AT cycles after the swi's dispatch
# starts, and the HALTCNT write lands HALT_WRITE_AT cycles after that read;
# after the wake, `bx lr` (3), then HALT_BIOS_RETURN cycles of BIOS code
# before the return's refill.
const HALT_COMMENT_READ_AT {.intdefine.} = 10
const HALT_WRITE_AT {.intdefine.} = 25
const HALT_BIOS_RETURN {.intdefine.} = 16

# Cycles from the comment read to the interrupt check after the dispatcher's
# `msr`. Measured against Nintendo's BIOS in this core: a Halt from IWRAM
# Thumb with an H-blank IRQ pending (the mGBA suite's `H-blank bit start`
# re-run from its results page) enters the vector 32 cycles after the swi,
# wakes 855 after it and is back 98 after the wake, on both.
const HALT_MSR_AT {.intdefine.} = 18

proc push_halt_svc_frame(cpu: CPU; ret: uint32) =
  ## The SWI's own state, on the SVC stack where each halt keeps its own:
  ## {caller CPSR, r12, return address} (r12 at [sp_svc - 8] as the
  ## console's dispatcher leaves it); hle_halt_return pops it. Leaves the CPU
  ## in the dispatcher's System mode with the caller's I bit.
  let bus = cpu.gba.bus
  let caller = cpu.cpsr
  cpu.switch_mode(modeSVC)
  cpu.r[13] -= 12
  bus.write_word_internal(cpu.r[13], uint32(caller))
  bus.write_word_internal(cpu.r[13] + 4, cpu.r[12])
  bus.write_word_internal(cpu.r[13] + 8, ret)
  cpu.switch_mode(modeSYS)
  cpu.cpsr = cast[PSR](uint32(modeSYS) or (uint32(caller) and 0x80'u32))

proc halt_from_dispatcher(cpu: CPU; ret, isa_step: uint32) =
  ## Hands a Halt over to the stub BIOS at 0x164, the instruction after the
  ## dispatcher's `msr`: push {r2, lr}; lr = 0x170; bx ip (ip = the table's
  ## 0x1A0); mov r2, #0; mov ip, #0x04000000; strb r2, [ip, #0x301]; bx lr.
  ## The {r2, lr} frame is the stub's own push, so sp stays where hle_swi
  ## left it.
  let bus = cpu.gba.bus
  cpu.push_halt_svc_frame(ret)
  cpu.r[12] = 0x1A0'u32
  let before = bus.cycles
  discard cpu.set_reg(15, 0x164'u32 - isa_step)  # the SWI handler steps isa_step
  bus.cycles = before

proc hle_halt(cpu: CPU; t_entry: int64; rfs_entry: CycleCount) =
  let bus = cpu.gba.bus
  let isa_step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
  let ret = cpu.r[15] - isa_step               # the instruction after the swi
  let caller_i = cpu.cpsr.irq_disable
  # Back to the dispatch start (hle_swi's generic charge is not this
  # routine's), then the dispatcher's own gamepak access: `ldrb [lr, #-2]`,
  # which the prefetcher and the burst see as the console's does.
  let charged = int(cpu.hle_body_start() - t_entry)
  if charged <= bus.cycles:
    bus.cycles -= charged
    bus.rom_free_since = rfs_entry
    bus.add_cycles(HALT_COMMENT_READ_AT)
    discard bus[ret - 2]
    bus.add_cycles(HALT_MSR_AT)
    bus.catch_up()
    if cpu.irq_line and not caller_i:
      # The dispatcher's `msr` (0x160) has just handed back the caller's I
      # bit with an interrupt already recognised: the console takes it
      # there, before the routine, and the routine's HALTCNT write then
      # sleeps. Park on the stub's copy of the code after the `msr` so the
      # interrupt, the write and the halt all run architecturally.
      cpu.halt_from_dispatcher(ret, isa_step)
      return
    # (the dispatcher's push {r2, lr} at 0x164 comes between: its stack
    # region's waits, swi_stack_entry)
    bus.add_cycles(HALT_WRITE_AT - HALT_MSR_AT + cpu.sys_stack_waits().stack_block(2))
  else:
    # Part of the dispatch already reached the scheduler (an armed DMA's
    # access window): keep it, and land on the write as near as it allows
    let page = int(bits_range(ret, 24, 27))
    let adj = HALT_COMMENT_READ_AT + int(bus.wait16_n[page]) + HALT_WRITE_AT +
              cpu.sys_stack_waits().stack_block(2) - charged
    bus.add_cycles(max(adj, -bus.cycles))
  bus.catch_up()
  # The write (mmio.nim, HALTCNT): an interrupt already recognised is taken
  # after the stall at the `bx lr`, without halting
  let seen = cpu.irq_line
  bus.add_cycles(HALT_ENTRY_STALL)
  # The SWI's frame, then the routine's handler-visible registers: ip =
  # 0x04000000, r2 = 0, lr = 0x170, the {r2, lr} frame hle_swi wrote live
  # below sp.
  cpu.push_halt_svc_frame(ret)
  cpu.r[12] = 0x04000000'u32
  cpu.r[2] = 0
  cpu.r[14] = 0x170'u32
  cpu.r[13] -= 8
  # PC on the `bx lr`. The pipeline the HALTCNT store left is already paid
  # for: take back the refill set_reg charges.
  let before = bus.cycles
  discard cpu.set_reg(15, 0x1B4'u32 - isa_step)  # the SWI handler steps isa_step
  bus.cycles = before
  if seen: return
  cpu.halted = true
  # Halt exits on IE & IF != 0 regardless of IME, including already-pending
  cpu.gba.interrupts.schedule_interrupt_check()
include hle_sound

when defined(biosdrvtrace):
  # tests/biosdrv_probe.nim: every SWI the CPU executes (HLE or real BIOS)
  var bdSwiHook*: proc(swi_num: uint32) {.closure.}
  # ... and the address of every instruction about to execute
  var bdPcHook*: proc(pc: uint32) {.closure.}

when defined(switrace):
  # -d:switrace: each SWI's entry and return cycle, to SWTRACE (a file)
  var swtStack: seq[(uint32, uint32, int64, uint32, uint32, uint32)]
  var swtFile: File
  var swtFrame* = 0
  var swtBase* = 0'i64
  proc swt_now(cpu: CPU): int64 =
    swtBase + int64(cpu.gba.scheduler.cycles) + int64(cpu.gba.bus.cycles)
  proc swt_swi*(cpu: CPU; num: uint32) =
    let ret = cpu.r[15] - (if cpu.cpsr.thumb: 2'u32 else: 4'u32)
    if ret < 0x4000'u32: return  # the stub BIOS's own traps
    if swtStack.len > 0 and swtStack[^1][0] == ret: return  # a continuation
    swtStack.add (ret, num, cpu.swt_now(), cpu.r[0], cpu.r[1], cpu.r[2])
  proc swt_pc*(cpu: CPU; pc: uint32) =
    if swtStack.len == 0 or pc != swtStack[^1][0]: return
    if cpu.halt_resume_charge != 0: return
    let e = swtStack.pop()
    if swtFile == nil:
      discard swtFile.open(getEnv("SWTRACE", "/tmp/swtrace.txt"), fmWrite)
    swtFile.writeLine("f" & $swtFrame & " swi " & toHex(e[1], 2) & " t0=" & $e[2] &
      " dur=" & $(cpu.swt_now() - e[2]) & " r0=" & toHex(e[3], 8) & " r1=" &
      toHex(e[4], 8) & " r2=" & toHex(e[5], 8) & " ret=" & toHex(e[0], 8))
    swtFile.flushFile()

include hle_unc

proc hle_takes*(cpu: CPU; swi_num: uint32): bool {.inline.} =
  ## With a real BIOS image mapped (hle_after_bios) the sound-driver SWIs run
  ## the image's own driver: their HLE continues through stub-BIOS code. The
  ## routines hle_unc.nim runs as stub-BIOS code run as the image's own.
  if cpu.gba.bus.stub_bios: return true
  case swi_num
  of 0x1A'u32..0x1E'u32, 0x20'u32..0x24'u32, 0x28'u32, 0x29'u32: false
  else: not unc_takes(swi_num)

include hle_copy

proc hle_swi*(cpu: CPU; swi_num: uint32) =
  ## HLE BIOS SWI dispatch; used when no BIOS image is provided.
  if cpu.r[15] == 0x178'u32 and swi_num == 0 and not cpu.cpsr.thumb:
    cpu.hle_halt_return()   # the stub's trap at 0x170 (ARM)
    return
  if cpu.r[15] == COPY_TRAP + 8 and swi_num == 0 and not cpu.cpsr.thumb and
     cpu.gba.bus.stub_bios:
    cpu.copy_resume()       # a copy an earlier build parked (hle_copy.nim)
    return
  if cpu.gba.bus.stub_bios:
    # The decompression and unpack routines run as stub-BIOS code
    # (hle_unc.nim): one of their steps, or a call into them
    if swi_num == 0 and cpu.unc_step(): return
    if unc_takes(swi_num):
      cpu.unc_enter()
      return
  let t_entry = cpu.hle_body_start()
  sd_swi_t0 = t_entry   # the sound driver places its register writes from here
  let rfs_entry = cpu.gba.bus.rom_free_since
  # (A CpuSet / CpuFastSet an interrupt preempted no longer rewinds onto the
  # SWI: it parks in BIOS code, hle_copy.nim. The fields that carried the old
  # continuation stay in save states, cleared.)
  cpu.copy_cont_pc = 0
  # Init, Mode, VSync and VSyncOff write registers sooner into the SWI than
  # the whole dispatch charge: they pay it themselves (hle_sound.nim sd_owed)
  if swi_num in [0x1A'u32, 0x1B, 0x1D, 0x28] and cpu.gba.bus.stub_bios:
    sd_owed = SWI_HLE_BASE
  else: cpu.hle_busy(SWI_HLE_BASE)
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
  # The BIOS's return path -- its code from 0x170 (SWI_HLE_EXIT) and the
  # caller's refill above -- is charged up front for what is left here (the
  # routines with timed effects run as stub-BIOS code: hle_unc.nim).
  # The System stack's wait states (swi_stack_entry): the pushes before the
  # routine, the pops with the return path. Halt prices its own (hle_halt,
  # hle_halt_return); the sound-driver routines' frames are not modeled.
  let stk_on = swi_num == 0x03
  let stk_exit = if stk_on: cpu.swi_stack_exit(swi_num) else: 0
  if stk_on:
    cpu.hle_busy(cpu.swi_stack_entry(swi_num))
  # Anchor for the routine-body cost models
  let body_t0 = cpu.hle_body_now()
  # The BIOS dispatch (0x140) switches to System mode and pushes {r2, lr}
  # on the System stack before every routine; the words stay in memory below
  # sp as residue games read (Prince of Tennis 2004).
  if swi_num != 0x00:  # SoftReset wipes this RAM anyway
    let usp = cpu.sys_sp()
    cpu.gba.bus.write_word_internal(usp - 4, cpu.sys_lr())
    cpu.gba.bus.write_word_internal(usp - 8, cpu.r[2])
  case swi_num
  of 0x00:  # SoftReset, or the stub BIOS's boot traps
    # The SWI handler steps the PC by the caller's ISA after we return:
    # set_reg(15, target - step) lands on `target`. Capture before any CPSR change.
    let isa_step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
    if cpu.gba.bus.stub_bios and cpu.sd_trap():
      discard  # a sound-driver routine's stub continuation (hle_sound.nim)
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
    cpu.hle_halt(t_entry, rfs_entry)
  of 0x03:  # Stop
    # Peripherals keep running (hardware stops sound/video/timers); the wake
    # sources are only keypad/cartridge/SIO as on hardware
    cpu.gba.bus.add_cycles(-HALT_RETURN_COST)
    cpu.halt_resume_charge = HALT_RETURN_COST + int32(stk_exit)
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
  # RegisterRamReset and 0x04-0x18 (IntrWait, VBlankIntrWait, the math
  # routines, the copies, GetBiosChecksum, the affine sets, the
  # decompression and unpack family), SoundBias and MidiKey2Freq run as
  # stub-BIOS code: hle_unc.nim
  of 0x1A: cpu.sd_init()
  of 0x1B: cpu.sd_mode()
  of 0x1D: cpu.sd_vsync()
  of 0x1E: cpu.sd_channel_clear()
  of 0x28: cpu.sd_vsync_off()
  of 0x29: cpu.sd_vsync_on()
  of 0x20, 0x21, 0x22, 0x23, 0x24:
    discard  # MusicPlayer stubs (not timed: their cost follows the player)
  of 0x1C: cpu.sd_main()  # SoundDriverMain: hle_sound.nim
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
  of 0x25:  # MultiBoot
    cpu.r[0] = 1'u32  # failure: multiboot is not emulated
  else:
    echo "unimplemented SWI: 0x", toHex(swi_num, 2)
