# ARM instruction handlers (included by gba.nim)

proc mul32(a, b: int32): int32 {.inline.} =
  ## Wrapping 32-bit multiply matching ARM `mul` instruction (low 32 bits).
  cast[int32](cast[uint32](cast[int64](a) * cast[int64](b)))

proc bios_arctan(cpu: CPU) =
  ## GBA BIOS ArcTan (SWI 0x09) polynomial approximation.
  ## Matches the real BIOS: 32-bit wrapping arithmetic, ASR shifts.
  ## Input:  r0 = tan value in 1.14 fixed-point (signed).
  ## Output: r0 = arctan result (0x4000 = pi/2),
  ##         r1 = -(input^2 >> 14),  r3 = polynomial accumulator.
  let a = cast[int32](cpu.r[0])
  var r1 = mul32(a, a)
  r1 = ashr(r1, 14)
  r1 = -r1  # neg_a_sq
  const ARCTAN_COEFFS = [0xA9'i32, 0x0390, 0x091C, 0x0FB6, 0x16AA, 0x2081, 0x3651, 0xA2F9]
  var r3 = mul32(ARCTAN_COEFFS[0], r1)
  r3 = ashr(r3, 14)
  for i in 1 ..< ARCTAN_COEFFS.len - 1:
    r3 = r3 + ARCTAN_COEFFS[i]; r3 = mul32(r3, r1); r3 = ashr(r3, 14)
  r3 = r3 + ARCTAN_COEFFS[^1]
  cpu.r[0] = cast[uint32](ashr(mul32(r3, a), 16))
  cpu.r[1] = cast[uint32](r1)
  cpu.r[3] = cast[uint32](r3)

proc div_align_shifts(n, d: uint32): int {.inline.} =
  ## Iteration count of the real BIOS divide's alignment loop (0x3C8):
  ## r2 starts at |denom| and doubles while r2 < |numer| >> 1 (cmp r2,
  ## r0 lsr #1 / lslls / bcc). The unwind loop (0x3D4) then runs exactly one
  ## more pass than this, so the routine's input-dependent cost is 13 cycles
  ## per alignment shift. Closed form: hb(n)-hb(d), minus one when the
  ## mantissa comparison d << (s-1) >= n >> 1 stops the loop a step early
  ## (the old always-minus-one model undercharged inputs like 0x1FF00/0x200
  ## by 13 cycles; Muppets On With The Show accumulated that into a
  ## frame-timing race).
  if n shr 1 <= d: return 0
  let s = countLeadingZeroBits(d) - countLeadingZeroBits(n)  # >= 1 here
  if (d shl (s - 1)) >= (n shr 1): s - 1 else: s

proc hle_div(cpu: CPU; numer_reg, denom_reg: int) =
  let numer = int64(cast[int32](cpu.r[numer_reg]))
  let denom = int64(cast[int32](cpu.r[denom_reg]))
  # The real BIOS divide loops once per alignment shift; calibrated against
  # the mGBA suite's "BIOS Division" timing tests
  block:
    let n = uint32(abs(numer) and 0xFFFFFFFF)
    let d = uint32(abs(denom) and 0xFFFFFFFF)
    if d != 0:
      cpu.idle(19 + div_align_shifts(n, d) * 13)
  if denom == 0:
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
  ## The supervisor-mode stack pointer (live r13 when the caller is in SVC
  ## mode, the banked one otherwise) — where the real BIOS's SWI dispatcher
  ## keeps its register frame.
  if cast[CpuMode](cpu.cpsr.mode) == modeSVC: cpu.r[13]
  else: cpu.reg_banks[mode_bank(modeSVC)][5]

proc sys_sp(cpu: CPU): uint32 {.inline.} =
  ## The System/User-mode stack pointer (live r13 when the caller is in a
  ## bank-0 mode, the banked one otherwise). The real BIOS's SWI dispatcher
  ## switches to System mode before running every routine, so all routine
  ## stack traffic goes through this stack.
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
  ## IntrWait per GBATEK: forcefully sets IME=1, then halts until the user
  ## IRQ handler ORs a masked flag into the BIOS mirror at 0x03007FF8.
  ## With discard_old=false, returns immediately if a masked flag is already
  ## set. Matched mirror flags are acknowledged (cleared) on return.
  ##
  ## Register protocol of the real routine (0x330, check subroutine 0x358):
  ## while halted the handler-visible r12 is 0x04000000 — the check
  ## subroutine loads it (mov ip, 0x04000000) before every halt, and user
  ## IRQ dispatchers rely on it: devkitARM's crt0 acknowledges the IntrWait
  ## mirror with `strh r0, [ip, #-8]` (0x03FFFFF8, an IWRAM mirror of
  ## 0x03007FF8). Without it the handler's mirror write lands at [caller_r12
  ## - 8] and IntrWait never returns (Bubble Bobble Old & New, Card
  ## E-Reader: permanent black screen). On return the caller's r12 comes
  ## back (the dispatcher pops it), r0 holds the matched flag bits and r3 is
  ## 0 (routine scratch, mov r3, #0 at 0x334).
  cpu.gba.interrupts.ime = true
  # Routine frame (ARM 0x330, System stack): push {r4, lr} with lr = 0x170
  # below the dispatcher's {r2, lr} pair (written by hle_swi)
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
      return
  # Save the caller's r12 in the exact SVC-stack slot the real dispatcher
  # uses (push {fp, ip, lr} at 0x140 puts ip at [sp_svc - 8]). HLE SWIs
  # never touch memory below the SVC sp, so the slot survives the wait; it
  # also travels inside save states and rollback snapshots for free.
  cpu.gba.bus.write_word_internal(cpu.svc_sp() - 8, cpu.r[12])
  cpu.r[12] = 0x04000000'u32
  cpu.r[3] = 0
  # Handler-visible register state of the real halt loop (0x344-0x34C, System
  # mode): r4 = 1 (the IME re-enable constant), r2 = the mirror value the last
  # check subroutine pass read, and — critically — lr_sys = 0x34C, the `bl
  # 0x358` return address. Nested user IRQ dispatchers that run their
  # callbacks in System mode push this lr, so it becomes stack residue games
  # can (and do) observe; Prince of Tennis 2004's sound engine reads such a
  # word and wedges its mixer without it.
  cpu.r[4] = 1
  cpu.r[2] = uint32(cpu.read_intr_mirror())
  cpu.set_sys_lr(0x34C'u32)
  # The dispatcher + routine frames stay live for the whole wait: the System
  # sp sits 16 bytes down, so nested IRQ dispatch frames land below them the
  # way they do on hardware (instead of overwriting the saved r2/lr pair).
  # Restored (+16, the pops) on the resume path in check_intr_wait.
  cpu.set_sys_sp(cpu.sys_sp() - 16)
  # While halted r0 holds the last check's matched bits: the discarded old
  # flags on entry (0x358 runs before the first halt), 0 otherwise
  if discard_old: cpu.r[0] = uint32(mirror and mask)
  cpu.intr_wait_active = true
  cpu.intr_wait_mask = mask
  # Address of the instruction following the SWI (r15 is pipeline-ahead)
  cpu.intr_wait_resume_addr = if cpu.cpsr.thumb: cpu.r[15] - 2 else: cpu.r[15] - 4
  cpu.halted = true
  # Wake immediately if an enabled interrupt is already pending
  cpu.gba.interrupts.schedule_interrupt_check()

proc check_intr_wait*(cpu: CPU) =
  ## Called when execution reaches the instruction after an IntrWait SWI
  ## (i.e. the user IRQ handler has returned). Re-halts unless a requested
  ## flag has appeared in the BIOS interrupt flags mirror.
  let hit = cpu.read_intr_mirror() and cpu.intr_wait_mask
  # Every pass through the real check subroutine re-enables IME on its way
  # out (0x370), even if the user handler turned it off
  cpu.gba.interrupts.ime = true
  if hit != 0:
    cpu.write_intr_mirror(cpu.read_intr_mirror() and not hit)
    cpu.intr_wait_active = false
    # Real-routine return protocol: r0 = matched flag bits, r3 = 0, and the
    # caller's r12 comes back from the dispatcher's SVC-stack slot (see
    # hle_intr_wait). r2/r4/lr pop back from the System-stack frames the
    # entry wrote — normally the caller's own values, but if a handler
    # scribbled on those slots the real pops would fetch the scribbles, so
    # read the memory rather than keeping shadow copies.
    cpu.r[0] = uint32(hit)
    cpu.r[3] = 0
    cpu.r[12] = cpu.gba.bus.read_word_internal(cpu.svc_sp() - 8)
    block:
      let usp = cpu.sys_sp() + 16  # pop the routine + dispatcher frames
      cpu.r[4] = cpu.gba.bus.read_word_internal(usp - 16)
      cpu.r[2] = cpu.gba.bus.read_word_internal(usp - 8)
      cpu.set_sys_lr(cpu.gba.bus.read_word_internal(usp - 4))
      cpu.set_sys_sp(usp)
    # The IRQ handler ran through the (stub) BIOS and rewrote the open-bus
    # latch; the real BIOS's IntrWait exit path leaves 0xE3A02004
    cpu.gba.bus.bios_latch = 0xE3A02004'u32
    # Cost of the real BIOS's wake path (mirror check, register restore,
    # return to caller). Keeps code after IntrWait phase-aligned with the
    # free-running timer prescaler (mGBA suite Timer count-up tests).
    # 44 = exactly what the real BIOS executes from the IRQ handler's return
    # to the caller's first instruction: bl 0x358 (3) + flag check/ack
    # subroutine (15) + beq not taken (1) + pop {r4,lr} (4) + bx lr (3) +
    # dispatcher restore 0x170-0x184 (12) + movs pc, lr (3+refill 2, IWRAM)
    cpu.gba.bus.add_cycles(44)  # INTRWAIT_TUNE
  else:
    # Re-halt with the check subroutine's register state: r0 = 0 (no match),
    # r12 = 0x04000000, r2 = the mirror it just read, r4 = 1, and lr_sys back
    # on the halt loop's bl-return (see hle_intr_wait)
    cpu.r[0] = 0
    cpu.r[12] = 0x04000000'u32
    cpu.r[2] = uint32(cpu.read_intr_mirror())
    cpu.r[4] = 1
    cpu.set_sys_lr(0x34C'u32)
    cpu.halted = true
    # Wake immediately if an enabled interrupt is already pending
    cpu.gba.interrupts.schedule_interrupt_check()

# Cycle cost of the real BIOS's SWI entry/dispatch/return path (exception
# entry, register saves, jump-table dispatch, return), excluding the
# caller-side pipeline refill which is charged region-dependently below.
# Calibrated against the mGBA suite's BIOS timing tests (IWRAM column).
const SWI_HLE_BASE = 48

# The part of a Halt/Stop SWI the real BIOS executes AFTER the wake IRQ has
# been serviced: bx lr (3) + pop {r2, lr} (4) + mov (1) + msr (1) +
# ldm {fp} (3) + msr SPSR (1) + pop {fp, ip, lr} (5) + movs pc, lr with an
# IWRAM/BIOS-width refill (3). Deferring it keeps post-wake measurements
# (mGBA suite SIO timing tests) aligned with the real-BIOS execution order.
const HALT_RETURN_COST = 21

# --- Real-BIOS routine-body cost models -------------------------------------
#
# The copy/decompression SWIs below charge the difference between what the
# real BIOS routine costs and what the HLE implementation's own bus accesses
# already charged. The models were derived by instruction-cycle counting of
# the BIOS disassembly (routines at 0xB4C CpuSet, 0x10FC LZ77UnCompWram,
# 0x1194 LZ77UnCompVram) and verified cycle-exact against real-BIOS execution
# in dingbat on calibration streams (all-literal / min-run / max-run / mixed
# LZ77 payloads; copies and fills across IWRAM/EWRAM/VRAM/ROM at both default
# and 3,1 ROM waitstates). Fixed constants are the routine body cost beyond
# the shared dispatch (SWI_HLE_BASE) and caller refill, which are charged
# separately above and match the real dispatch/refill region-for-region.
# Per-unit terms scale with the waitstates of the source/destination pages,
# using nonsequential costs: the BIOS loops interleave their (0-wait BIOS)
# instruction fetches with the data accesses, so no data burst survives.

proc hle_body_start(cpu: CPU): int64 {.inline.} =
  int64(cpu.gba.scheduler.cycles) + int64(cpu.gba.bus.cycles)

proc hle_charge_body(cpu: CPU; t0: int64; model: int) {.inline.} =
  ## Top up whatever the HLE body has charged since `t0` (its actual bus
  ## accesses) to `model`, the cost of the real BIOS routine body. O(1):
  ## one subtraction and one idle block per call.
  let charged = int(cpu.hle_body_start() - t0)
  if model > charged:
    cpu.idle(model - charged)

proc bios_addr_check(address, length: uint32): bool {.inline.} =
  ## The real BIOS's source-region validation subroutine (BIOS 0xBA4), called
  ## by every copy/decompression SWI (CpuSet, CpuFastSet, BitUnPack,
  ## HuffUnComp, LZ77/RL/Diff) before touching memory. Returns false when the
  ## real BIOS silently skips the whole operation: zero length, source below
  ## 0x02000000 (BIOS dump protection), or source+length reaching outside
  ## the 0x02000000-0x0FFFFFFF address bits. Faithful to the routine's exact
  ## arithmetic: length is masked to 25 bits before the end-address test, and
  ## "valid" means (addr & 0x0E000000) != 0 at both ends. Games rely on the
  ## skip: Riviera's decompression queue ends with a src=0xFFFFFFFF entry
  ## that must be a no-op (decompressing the open-bus "header" instead
  ## overwrites all of EWRAM and blackscreens the game).
  if length == 0: return false
  if (address and 0x0E000000'u32) == 0: return false
  ((address + (length and 0x01FFFFFF'u32)) and 0x0E000000'u32) != 0

# Routine-body cost of a validation-skipped copy/decompression SWI: entry
# push, (for the LZ77/RL/Diff shapes) the header ldr, the 0xBA4 check and the
# early-out epilogue. Instruction-counted from the BIOS disassembly; the
# handful of cycles' spread between the ARM and thumb routine shapes doesn't
# matter for a path that does no work.
const BIOS_CHECK_SKIP_COST = 26

# The real BIOS's copy SWIs run with the caller's IRQ mask (the dispatcher
# restores the I bit before jumping to the routine), so a long CpuSet /
# CpuFastSet is preempted mid-loop by any deliverable interrupt and resumes
# afterwards. Games rely on this: Card E-Reader boot-loads a 22 KB IWRAM
# program over its own live IRQ handler with one CpuSet call, counting on
# the vblank IRQ being serviced (through the OLD handler) before the copy
# reaches and replaces it — an atomic HLE copy defers that IRQ into the
# half-overwritten handler and wedges the game. The HLE therefore checks
# every HLE_COPY_IRQ_CHECK units whether an interrupt has become
# deliverable; if so it stops, winds r0/r1/r2 forward to describe the
# remaining span and rewinds the PC onto the SWI instruction itself, so the
# pending IRQ is taken and the re-executed SWI continues the copy. All
# continuation state lives in the architectural registers (like the real
# routine's), so save states and rollback snapshots need nothing extra.
#
# Known deviations from the real routine, only on the interrupted path: the
# halfword forms' r0/r1 advance (the real routine indexes with an offset
# register and leaves them untouched) and r2's count field counts down; the
# re-dispatch also re-charges the SWI entry/validation overhead (~50
# cycles per interruption). The decompression SWIs stay atomic.
const HLE_COPY_IRQ_CHECK = 32

proc hle_irq_deliverable(cpu: CPU): bool {.inline.} =
  let intr = cpu.gba.interrupts
  intr.ime and not cpu.cpsr.irq_disable and
    ((uint16(intr.reg_ie) and uint16(intr.reg_if)) != 0)

proc hle_swi_rewind(cpu: CPU) =
  ## Rewind the PC onto the SWI instruction currently being handled, so it
  ## re-executes after the pending IRQ is serviced. The caller (arm/thumb
  ## software-interrupt handler) still steps the PC after hle_swi returns,
  ## so aim one instruction short of the SWI itself.
  if cpu.cpsr.thumb:
    discard cpu.set_reg(15, cpu.r[15] - 6)
  else:
    discard cpu.set_reg(15, cpu.r[15] - 12)

proc hle_charge_units_interruptible(cpu: CPU; n: int): int =
  ## Charge `n` idle cycles in chunks with the scheduler kept caught up.
  ## Returns 0 when fully charged, or the un-charged remainder if an IRQ
  ## became deliverable first (the caller parks/encodes it).
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
  ## hle_charge_body for the decompression SWIs, which the real BIOS runs
  ## with the caller's IRQ mask: the remaining routine time is charged in
  ## chunks with the scheduler kept caught up, so an interrupt that fires
  ## mid-routine is delivered at its faithful cycle position instead of one
  ## end-of-SWI lump (a >1-frame LZ77UnCompVram otherwise swallows a whole
  ## vblank: two vblanks merge into one IF bit and the game's per-frame IRQ
  ## work runs once too few — Muppets On With The Show wedges its scene
  ## loader on exactly that). When an IRQ becomes deliverable before the
  ## routine time is exhausted, the un-charged remainder is parked on the
  ## halt-resume mechanism (already serialized in save states) and is paid
  ## when execution returns to the instruction after the SWI; the caller's
  ## r12 is staged in the dispatcher's SVC-stack slot, which the resume path
  ## pops back — exactly the slot the real dispatcher's push {fp, ip, lr}
  ## uses, so the restore is faithful and a no-op value-wise.
  ##
  ## Deviation (documented in docs/hle-bios-shortcomings.md): the memory
  ## effects of the decompression completed before the handler runs, so a
  ## handler that inspects the destination mid-call sees finished output
  ## where the real BIOS would show a partial one. Total cost is unchanged;
  ## no re-dispatch is paid (the real routine resumes mid-body).
  let remain = cpu.hle_charge_units_interruptible(model - int(cpu.hle_body_start() - t0))
  if remain > 0:
    cpu.gba.bus.write_word_internal(cpu.svc_sp() - 8, cpu.r[12])
    cpu.halt_resume_charge = int32(remain)
    cpu.halt_resume_addr = if cpu.cpsr.thumb: cpu.r[15] - 2 else: cpu.r[15] - 4
    # Unlike Halt/Stop, the System sp was not shifted for this park: the
    # resume must only pay the charge, not pop the dispatcher frame
    cpu.halt_resume_pop = false

proc hle_div_body_cost(numer, denom: int32): int {.inline.} =
  ## Input-dependent cost of the real BIOS divide loop (same shape as the
  ## charge in hle_div; kept separate so ArcTan2 can price its internal Div).
  let n = uint32(abs(int64(numer)) and 0xFFFFFFFF)
  let d = uint32(abs(int64(denom)) and 0xFFFFFFFF)
  if d == 0: return 19
  19 + div_align_shifts(n, d) * 13

proc hle_swi*(cpu: CPU; swi_num: uint32) =
  ## HLE BIOS dispatch for the most common GBA SWI calls.
  ## Only used when no real BIOS file is provided.
  cpu.idle(SWI_HLE_BASE)
  # BIOS open-bus latch: the last opcode the real BIOS fetches before
  # returning (GBATEK "Reading from BIOS memory"; the mGBA suite verifies
  # 0xE3A02004 after VBlankIntrWait on hardware)
  cpu.gba.bus.bios_latch = 0xE3A02004'u32
  # The return refills the caller's pipeline: one nonsequential + one
  # sequential fetch in the caller's region
  block:
    let bus = cpu.gba.bus
    let page = int(bits_range(cpu.r[15], 24, 27))
    if cpu.cpsr.thumb:
      bus.add_cycles(int(bus.wait16_n[page]) + int(bus.wait16_s[page]))
    else:
      bus.add_cycles(int(bus.wait32_n[page]) + int(bus.wait32_s[page]))
    # Plus one more sequential halfword slot; the residual every non-IWRAM
    # column showed against hardware (exactly S16 - 1)
    bus.add_cycles(int(bus.wait16_s[page]) - 1)
    # The swi flushed the ROM fetch stream; forget burst/prefetch state
    bus.rom_hot = false
    bus.rom_next_addr = 1  # never matches (halfword-aligned addresses)
    bus.rom_free_since = bus.gba.scheduler.cycles + CycleCount(bus.cycles)
  # Anchor for the routine-body cost models (everything before this point is
  # the shared dispatch + caller refill, common to all SWIs)
  let body_t0 = cpu.hle_body_start()
  # Real-BIOS SWI dispatch (0x140) switches to System mode and pushes
  # {r2, lr} onto the SYSTEM/USER stack before calling every routine; the
  # routines push their own frames below that. The pops restore everything,
  # but the words STAY in memory below sp — deterministic residue that games
  # can observe by reading uninitialized stack (Prince of Tennis 2004's
  # sound engine reads such a slot and takes a different path without it).
  # Model the dispatcher pair here and the per-routine frames below.
  if swi_num != 0x00:  # SoftReset wipes this RAM anyway
    let usp = cpu.sys_sp()
    cpu.gba.bus.write_word_internal(usp - 4, cpu.sys_lr())
    cpu.gba.bus.write_word_internal(usp - 8, cpu.r[2])
  case swi_num
  of 0x00:  # SoftReset — or, executed inside the stub BIOS, the boot traps
    # The caller's ISA decides how far the arm/thumb SWI handler steps the PC
    # after we return; capture it before any CPSR change so the final
    # set_reg(15) can aim exactly at the entry point (landing convention:
    # set_reg(15, target - step) + caller step -> executing `target`).
    let isa_step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
    if cpu.r[15] == 0x1DFE'u32 or cpu.r[15] == 0x1E02'u32:
      # SoundMain stub epilogue (see hle_swi 0x1C / new_bus): the real
      # dispatcher's `movs pc, lr` — restore the caller's CPSR from
      # SPSR_svc and return to lr_svc
      let target = cpu.r[14] and not 1'u32
      let spsr = cpu.spsr
      cpu.switch_mode(cast[CpuMode](spsr.mode))
      cpu.cpsr = spsr
      # This swi came from the thumb stub, so the thumb handler steps the
      # PC by 2 after we return
      discard cpu.set_reg(15, target - 2)
    elif cpu.r[15] == 8'u32:
      # Boot trap #1: the game jumped to the reset vector (0x00000000).
      # The real BIOS re-runs its full boot: it blanks the display,
      # silences/deconfigures the peripherals, clears its work RAM, replays
      # the ~271-frame logo sequence and re-enters the ROM at scanline 126
      # with the post-boot register file. I/O deltas below were measured by
      # diffing dingbat's real-BIOS machine state just before a warm
      # jump-to-0 against the state at the boot's ROM re-entry (Earthworm
      # Jim 2, whose IRQ dispatcher calls through a NULL handler slot and
      # relies on the resulting reboot). Not modeled: the Nintendo logo
      # image/palette in VRAM (forced blank hides nothing on the real boot;
      # the HLE shows a blank screen for the logo's duration) and the boot
      # jingle.
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
      # Sound: channel registers cleared while the master enable is still
      # on (they are write-protected when it is off), FIFOs reset, then the
      # master switched off — the measured end state of the boot jingle
      bus.write_half(0x04000084'u32, 0x0080'u16)
      for a in countup(0x04000060'u32, 0x04000080'u32, 2):
        bus.write_half(a, 0)
      bus.write_half(0x04000082'u32, 0x880E'u16)
      bus.write_half(0x04000084'u32, 0x0000'u16)
      bus.write_half(0x04000088'u32, 0x0200'u16)  # SOUNDBIAS
      # DMA + timers off (counters stay frozen, matching the real boot)
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
      # Park execution in the stub's wait loop (r0/r2 are its inputs); the
      # whole continuation is architectural, so save states and rollback
      # need nothing extra
      cpu.r[0] = 0x04000000'u32
      cpu.r[2] = 270  # vblank starts between vector entry and ROM re-entry
      discard cpu.set_reg(15, 0x200'u32 - isa_step)
    elif cpu.r[15] == 0x234'u32:
      # Boot trap #2: the wait loop finished at scanline 126 — hand the ROM
      # the measured post-boot register file
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
      # Enter system mode through switch_mode so the live r13/r14 rebank; a
      # direct CPSR write would leave the previous mode's registers active
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
      # The caller's SWI handler steps the PC after we return; aim one
      # instruction short so execution enters exactly at reset_addr (the
      # unadjusted set_reg skipped the target's first instruction — the
      # `b entrypoint` at 0x08000000 for a header-first ROM)
      discard cpu.set_reg(15, reset_addr - isa_step)
  of 0x02:  # Halt
    # Move the BIOS's post-wake return cost out of the upfront charge and
    # onto the resume boundary (see HALT_RETURN_COST)
    cpu.gba.bus.add_cycles(-HALT_RETURN_COST)
    cpu.halt_resume_charge = HALT_RETURN_COST
    cpu.halt_resume_addr = if cpu.cpsr.thumb: cpu.r[15] - 2 else: cpu.r[15] - 4
    # The real routine (0x1A0) halts with ip = 0x04000000, r2 = 0 and
    # lr_sys = 0x170 (the dispatcher trampoline) — register state user IRQ
    # dispatchers can observe (see hle_intr_wait); the caller's r12/r2/lr are
    # restored from the dispatcher's stack slots on resume
    cpu.gba.bus.write_word_internal(cpu.svc_sp() - 8, cpu.r[12])
    cpu.r[12] = 0x04000000'u32
    cpu.r[2] = 0
    cpu.set_sys_lr(0x170'u32)
    cpu.set_sys_sp(cpu.sys_sp() - 8)  # dispatcher {r2, lr} frame stays live
    cpu.halt_resume_pop = true        # ...and the resume pops it back
    cpu.halted = true
    # Halt exits when IE & IF is nonzero (IME is don't care), including
    # interrupts that were already pending on entry
    cpu.gba.interrupts.schedule_interrupt_check()
  of 0x03:  # Stop
    # Peripherals keep running (hardware stops sound/video/timers), but the
    # wake sources are faithful: only keypad/cartridge/SIO interrupts
    cpu.gba.bus.add_cycles(-HALT_RETURN_COST)
    cpu.halt_resume_charge = HALT_RETURN_COST
    cpu.halt_resume_addr = if cpu.cpsr.thumb: cpu.r[15] - 2 else: cpu.r[15] - 4
    # Same halted-register convention as Halt (real routine 0x1A8 shares
    # 0x1AC; its r2 holds 0x80, the Stop flag it wrote to HALTCNT)
    cpu.gba.bus.write_word_internal(cpu.svc_sp() - 8, cpu.r[12])
    cpu.r[12] = 0x04000000'u32
    cpu.r[2] = 0x80
    cpu.set_sys_lr(0x170'u32)
    cpu.set_sys_sp(cpu.sys_sp() - 8)  # dispatcher {r2, lr} frame stays live
    cpu.halt_resume_pop = true        # ...and the resume pops it back
    cpu.halted = true
    cpu.stopped = true
    # Stop blanks the LCD without any memory write; force a re-render
    cpu.gba.ppu.render_dirty = true
    cpu.gba.interrupts.schedule_interrupt_check()
  of 0x06: hle_div(cpu, 0, 1)  # Div
  of 0x07: hle_div(cpu, 1, 0)  # DivArm (swapped inputs)
  of 0x04:  # IntrWait(discard_flags, intr_flags)
    cpu.hle_intr_wait(cpu.r[0] != 0, uint16(cpu.r[1]))
  of 0x05:  # VBlankIntrWait = IntrWait(1, 1)
    # The real entry point (0x328) loads the IntrWait arguments into r0/r1;
    # r1 survives to the caller (r0 is overwritten by the matched flags)
    cpu.r[0] = 1
    cpu.r[1] = 1
    cpu.hle_intr_wait(true, 1'u16)
  of 0x08:  # Sqrt
    # Input-dependent cost of the real BIOS routine. The hardware algorithm
    # is unknown (the bundled replacement BIOS uses a different one), so this
    # is a monotone piecewise-linear fit through the mGBA suite's three
    # "BIOS Sqrt" timing datapoints (inputs 0, 0xFF, 0x12345678).
    block:
      let b = 32 - countLeadingZeroBits(max(cpu.r[0], 1'u32))
      let extra = if cpu.r[0] == 0: 48
                  elif b <= 8: 48 + (115 * b + 4) div 8
                  else: 163 + (916 * (b - 8) + 10) div 21
      cpu.idle(extra)
    let val = cpu.r[0]
    if val == 0:
      cpu.r[0] = 0
    else:
      var result_val: uint32 = 0
      var bit_val: uint32 = 1'u32 shl 30
      var num = val
      while bit_val > num:
        bit_val = bit_val shr 2
      while bit_val != 0:
        if num >= result_val + bit_val:
          num -= result_val + bit_val
          result_val = (result_val shr 1) + bit_val
        else:
          result_val = result_val shr 1
        bit_val = bit_val shr 2
      cpu.r[0] = result_val
  of 0x09:  # ArcTan
    cpu.idle(48)  # fixed-iteration polynomial in the real BIOS
    bios_arctan(cpu)
  of 0x0A:  # ArcTan2
    ## Matches real BIOS: full 32-bit signed inputs, same branching logic.
    let x = cast[int32](cpu.r[0])
    let y = cast[int32](cpu.r[1])
    # Cost of the real BIOS routine: octant fixups + an internal BIOS Div of
    # the ratio + the fixed-iteration ArcTan polynomial. Calibrated against
    # real-BIOS execution (axis cases exact, octants within ~40 cycles).
    let atan2_model =
      if y == 0: 26
      elif x == 0: 28
      else:
        let swap = abs(int64(x)) >= abs(int64(y))
        let num = cast[int32]((if swap: int64(y) else: int64(x)) shl 14)
        let den = if swap: x else: y
        70 + hle_div_body_cost(num, den) + 48
    if y == 0:
      if x >= 0:
        cpu.r[0] = 0
      else:
        cpu.r[0] = 0x8000'u32
    elif x == 0:
      if y >= 0:
        cpu.r[0] = 0x4000'u32
      else:
        cpu.r[0] = 0xC000'u32
    else:
      if y > 0:
        if x > 0:
          if x >= y:
            cpu.r[0] = cast[uint32]((int64(y) shl 14) div int64(x))
            bios_arctan(cpu)
          else:
            cpu.r[0] = cast[uint32]((int64(x) shl 14) div int64(y))
            bios_arctan(cpu)
            cpu.r[0] = 0x4000'u32 - cpu.r[0]
        else: # x < 0
          if -x >= y:
            cpu.r[0] = cast[uint32]((int64(y) shl 14) div int64(x))
            bios_arctan(cpu)
            cpu.r[0] = cpu.r[0] + 0x8000'u32
          else:
            cpu.r[0] = cast[uint32]((int64(x) shl 14) div int64(y))
            bios_arctan(cpu)
            cpu.r[0] = 0x4000'u32 - cpu.r[0]
      else: # y < 0
        if x > 0:
          if x >= -y:
            cpu.r[0] = cast[uint32]((int64(y) shl 14) div int64(x))
            bios_arctan(cpu)
            cpu.r[0] = cpu.r[0] + 0x10000'u32
          else:
            cpu.r[0] = cast[uint32]((int64(x) shl 14) div int64(y))
            bios_arctan(cpu)
            cpu.r[0] = 0xC000'u32 - cpu.r[0]
        else: # x <= 0
          if -x > -y:
            cpu.r[0] = cast[uint32]((int64(y) shl 14) div int64(x))
            bios_arctan(cpu)
            cpu.r[0] = cpu.r[0] + 0x8000'u32
          else:
            cpu.r[0] = cast[uint32]((int64(x) shl 14) div int64(y))
            bios_arctan(cpu)
            cpu.r[0] = 0xC000'u32 - cpu.r[0]
    cpu.r[3] = 0x170'u32
    cpu.hle_charge_body(body_t0, atan2_model)
  of 0x0B:  # CpuSet
    # Routine frame (thumb 0xB4C, System stack): push {r4, r5, lr}; the exit
    # is `pop {r4, r5}; pop {r3}; bx r3`, so r3 comes back holding the
    # dispatcher return address 0x170 on every path (validation-skip too).
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
    # The real BIOS validates the source before any access (byte length is
    # count*4 even in halfword mode — the check runs before the halving) and
    # returns with registers and memory untouched when it fails. This also
    # covers the old "reads from the protected BIOS region return 0" special
    # case: such sources never reach the copy loop at all.
    if not bios_addr_check(src, count shl 2):
      cpu.idle(BIOS_CHECK_SKIP_COST)
    else:
      # Addresses are NOT aligned: normal memory aligns on the bus anyway, and
      # SRAM (8-bit bus) genuinely sees the unaligned byte address.
      let src_page = int(bits_range(src, 24, 27))
      let dst_page = int(bits_range(dst, 24, 27))
      # Per-unit/fixed real-routine costs (see the model block below). The
      # per-chunk top-up keeps simulated time in step with the real loop so
      # peripheral events and IRQs land mid-copy at faithful cycle positions
      # (the HLE's own bus accesses undercharge — e.g. prefetched ROM reads —
      # and a single end-of-SWI top-up would defer a mid-copy vblank until
      # after every byte has been written).
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
        # The word paths use ldmia r0!/stmia r1!, so r0/r1 come back advanced
        # (fill still pops one source word)
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
        # On interruption the continuation re-reads its fill word from r0,
        # so the fill's source pop must not happen until the last leg
        cpu.r[0] = if interrupted and fill: src - 4 else: src
        cpu.r[1] = dst
      else:
        # The real BIOS uses ldrh: an odd source address reads rotated, so the
        # stored halfword is the addressed byte (ldrh+strh; hardware-verified).
        # The halfword paths index with an offset register (ldrh/strh [rX, r5])
        # and leave r0/r1 unmodified.
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
          # Continuation state (deviation: the real routine's offset-register
          # form leaves r0/r1 untouched — see HLE_COPY_IRQ_CHECK notes)
          cpu.r[0] = src
          cpu.r[1] = dst
      # Cost of the real BIOS's thumb copy/fill loop (routine at 0xB4C), for
      # the units actually performed. Every data access is nonsequential
      # (BIOS instruction fetches sit between them), so per-unit cost = loop
      # instructions + N-cost of src read + N-cost of dst write; fills read
      # src once (folded into the fixed part). Verified cycle-exact against
      # real-BIOS execution for word/half x copy/fill across
      # IWRAM/EWRAM/VRAM/ROM at two waitstate settings.
      cpu.hle_charge_body(body_t0, model_fixed + model_unit * int(done))
      if interrupted:
        cpu.r[2] = (ctrl and not 0x1FFFFF'u32) or (count - done)
        cpu.hle_swi_rewind()
  of 0x01:  # RegisterRamReset
    # The real routine (0x9C2) processes the flag groups in this order:
    # "other" I/O (bit 7), SIO (5), sound (6), EWRAM (0), VRAM (3), OAM (4),
    # palette (2), IWRAM last (1) — and, like the copy SWIs, runs with the
    # caller's IRQ mask, so its long RAM-clear loops are preempted by any
    # deliverable interrupt with the clears only partially done. Games rely
    # on both properties: Robot Wars - Advanced Destruction calls
    # RegisterRamReset(EWRAM|IWRAM) with vblank IRQs live; the vblank lands
    # inside the ~434k-cycle EWRAM clear and must be dispatched through the
    # game's IWRAM handler table, which the real routine has not reached yet
    # (IWRAM is cleared last). An atomic HLE defers that IRQ until after the
    # table is wiped and the game's dispatcher wedges in its unhandled-IRQ
    # loop (permanent black screen).
    #
    # The HLE therefore charges each phase in chunks, clears the RAM regions
    # progressively in step with the charged time (ascending, like the
    # BIOS's stmia memset), and on preemption rewinds the PC onto the SWI
    # with a continuation encoded in r0: bit 31 marker, un-charged remainder
    # of the current phase in bits 8-29, still-pending flag bits in the low
    # byte (the interrupted phase's own bit stays set; the clear offset is
    # derived from the remainder, so park/resume is deterministic). The real
    # routine keeps its flags in a register the whole time too (r7); handler-
    # visible registers mid-routine are routine scratch either way.
    # A fresh call is never misread: the marker bit plus a remainder outside
    # the possible phase-cost range (> 434375) falls back to a fresh call,
    # and the flags byte is the low 8 bits in both encodings.
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
          # I/O reset phases: the writes are quick and idempotent, so they
          # run (again, on the resumed path) up front, then the phase time
          # is charged. Re-acknowledging IF on a resumed bit-7 phase cannot
          # swallow the preempting IRQ: writing IE/IME to 0 makes further
          # phases non-preemptible in the first place.
          let phase_t0 = cpu.hle_body_start()
          case bit_idx
          of 5:  # Reset SIO
            cpu.gba.serial.siocnt = 0
            cpu.gba.serial.rcnt = 0
          of 6:  # Reset sound (0x4000060-0x4000084)
            cpu.gba.scheduler.clear(etAPUChannel1)
            cpu.gba.scheduler.clear(etAPUChannel2)
            cpu.gba.scheduler.clear(etAPUChannel3)
            cpu.gba.scheduler.clear(etAPUChannel4)
            cpu.gba.scheduler.clear(etAPUFrameSeq)
            cpu.gba.scheduler.clear(etAPUSample)
            cpu.gba.apu.sound_enabled = true
            # Real BIOS clears 0x60-0xAF per GBATEK (includes wave RAM at 0x90-0x9F)
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
            # Re-schedule APU events before any preemption can happen, so a
            # parked phase can never leave them cleared
            cpu.gba.apu.tick_frame_sequencer()
            cpu.gba.apu.get_sample()
          else:  # bit 7: reset all other I/O (except SIO and sound)
            for offset in 0x000'u32..0x05F'u32:
              cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
            for offset in 0x0B0'u32..0x11F'u32:
              cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
            for offset in 0x130'u32..0x133'u32:
              cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
            for offset in 0x15C'u32..0x1FF'u32:
              cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
            # The "other registers" group also covers the interrupt/waitstate
            # block: the real BIOS clears IE, acknowledges ALL pending IF bits,
            # resets WAITCNT, and clears IME (mGBA's HLE does the same). Pokemon
            # Pinball R/S relies on this: its boot code points 0x03007FFC at its
            # IntrMain and calls RegisterRamReset while the previous program's
            # sound-DMA IRQs are still enabled and firing; without the IE/IF/IME
            # clear, a stale DMA IRQ dispatches through the not-yet-built handler
            # table and jumps to address 0.
            cpu.gba.bus.write_half(0x04000200'u32, 0x0000'u16)  # IE
            cpu.gba.bus.write_half(0x04000202'u32, 0xFFFF'u16)  # IF (ack all)
            cpu.gba.bus.write_half(0x04000204'u32, 0x0000'u16)  # WAITCNT
            cpu.gba.bus.write_half(0x04000208'u32, 0x0000'u16)  # IME
            # The real BIOS leaves the display in forced blank, not zeroed
            cpu.gba.bus.write_half(0x04000000'u32, 0x0080'u16)
            # ...and resets the affine parameters to the identity transform, not
            # zero (mGBA's HLE stores 0x100 to BG2PA/PD and BG3PA/PD the same
            # way). Spider-Man: Mysterio's Menace calls RegisterRamReset(0xFD) at
            # boot and never writes the affine registers: its mode-4 comic viewer
            # relies on the BIOS-left identity matrix.
            cpu.gba.bus.write_half(0x04000020'u32, 0x0100'u16)  # BG2PA
            cpu.gba.bus.write_half(0x04000026'u32, 0x0100'u16)  # BG2PD
            cpu.gba.bus.write_half(0x04000030'u32, 0x0100'u16)  # BG3PA
            cpu.gba.bus.write_half(0x04000036'u32, 0x0100'u16)  # BG3PD
          # Top the phase's own I/O-write charges up to the phase cost, in
          # preemptible chunks
          if not continuing:
            charge = max(0, phase_cost - int(cpu.hle_body_start() - phase_t0))
          let remain = cpu.hle_charge_units_interruptible(charge)
          if remain > 0:
            park(flags and not (1'u32 shl bit_idx), remain)
        else:
          # RAM clear phases: clear in ascending order in step with the
          # charged time (byte offset derived from the remaining charge, so
          # the same mapping holds across park/resume)
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
    # Routine frame (ARM 0xBC4, System stack): push {r4-r10, lr}, lr = 0x170
    block:
      let usp = cpu.sys_sp()
      cpu.gba.bus.write_word_internal(usp - 12, 0x170'u32)
      for i in 0 .. 6:  # r10 at usp-16 down to r4 at usp-40
        cpu.gba.bus.write_word_internal(usp - 16 - uint32(i * 4), cpu.r[10 - i])
    var src = cpu.r[0]
    var dst = cpu.r[1]
    let ctrl = cpu.r[2]
    let raw_count = bits_range(ctrl, 0, 20)
    # The real BIOS validates before the copy using the UNROUNDED byte length
    # (the ldm/stm bursts round up to 8 words only afterwards), and returns
    # with registers and memory untouched when the check fails
    if not bios_addr_check(src, raw_count shl 2):
      cpu.idle(BIOS_CHECK_SKIP_COST)
    else:
      let count = (raw_count + 7) and not 7'u32  # round up to multiple of 8
      let fill = bit(ctrl, 24)
      let fill_val = cpu.gba.bus.read_word(src)
      var done = 0'u32
      var overhead_charged = 0
      var interrupted = false
      while done < count:
        let val = if fill: fill_val
                  else: cpu.gba.bus.read_word(src)
        cpu.gba.bus.write_word(dst, val)
        if not fill: src += 4
        dst += 4
        inc done
        # Interruptible like the real ldmia/stmia loop; the check interval is
        # a multiple of the 8-word burst so the remaining count stays one too
        # (see HLE_COPY_IRQ_CHECK notes). The loop-overhead charge is spread
        # over the chunks so mid-copy events land at faithful cycle positions.
        if (done and (HLE_COPY_IRQ_CHECK - 1)) == 0 and done < count:
          cpu.idle(HLE_COPY_IRQ_CHECK)
          overhead_charged += HLE_COPY_IRQ_CHECK
          cpu.gba.bus.catch_up()
          if cpu.hle_irq_deliverable():
            interrupted = true
            break
      # Loop overhead of the real BIOS ldmia/stmia loop beyond the bus accesses
      # (calibrated against the mGBA suite "CpuSet" timing test, which uses
      # swi 0xC despite its name), for the words actually transferred
      cpu.idle(int(done) + 5 - overhead_charged)
      cpu.r[0] = src
      cpu.r[1] = dst
      # The real routine's stm bursts go through r2-r9; r2 is restored by the
      # dispatcher pop but r3 keeps the last word stored
      if done > 0:
        cpu.r[3] = if fill: fill_val
                   else: cpu.gba.bus.read_word_internal(dst - 4)
      if interrupted:
        cpu.r[2] = (ctrl and not 0x1FFFFF'u32) or (count - done)
        cpu.hle_swi_rewind()
  of 0x0D:  # GetBiosChecksum
    cpu.r[0] = 0xBAAE187F'u32
  of 0x0E:  # BgAffineSet
    var src = cpu.r[0]
    var dst = cpu.r[1]
    let count = cpu.r[2]
    # Real BIOS cost per entry: fixed-point sin/cos lookups, four 16x16
    # multiplies and the src/dst accesses (2 words + 3 halfwords read,
    # 4 halfwords + 2 words written), all nonsequential. Calibrated against
    # real-BIOS execution (IWRAM structs exact, EWRAM within 5/entry).
    let affine_model = block:
      let bus = cpu.gba.bus
      let sp = int(bits_range(src, 24, 27))
      let dp = int(bits_range(dst, 24, 27))
      23 + int(count) * (73 + 2 * int(bus.wait32_n[sp]) + 3 * int(bus.wait16_n[sp]) +
                         4 * int(bus.wait16_n[dp]) + 2 * int(bus.wait32_n[dp]))
    for i in 0'u32 ..< count:
      let center_org_x = cast[int32](cpu.gba.bus.read_word(src))
      let center_org_y = cast[int32](cpu.gba.bus.read_word(src + 4))
      let display_cx = int32(cast[int16](cpu.gba.bus.read_half(src + 8)))
      let display_cy = int32(cast[int16](cpu.gba.bus.read_half(src + 10)))
      let scale_x = cast[int16](cpu.gba.bus.read_half(src + 12))
      let scale_y = cast[int16](cpu.gba.bus.read_half(src + 14))
      let angle = cpu.gba.bus.read_half(src + 16)
      let theta = float64(angle) / 32768.0 * PI
      let cos_t = cos(theta)
      let sin_t = sin(theta)
      let pa = cast[int16](int32(float64(scale_x) * cos_t))
      let pb = cast[int16](int32(-float64(scale_x) * sin_t))
      let pc = cast[int16](int32(float64(scale_y) * sin_t))
      let pd = cast[int16](int32(float64(scale_y) * cos_t))
      let start_x = int32(center_org_x) - (int32(pa) * display_cx + int32(pb) * display_cy)
      let start_y = int32(center_org_y) - (int32(pc) * display_cx + int32(pd) * display_cy)
      cpu.gba.bus.write_half(dst, cast[uint16](pa))
      cpu.gba.bus.write_half(dst + 2, cast[uint16](pb))
      cpu.gba.bus.write_half(dst + 4, cast[uint16](pc))
      cpu.gba.bus.write_half(dst + 6, cast[uint16](pd))
      cpu.gba.bus.write_word(dst + 8, cast[uint32](start_x))
      cpu.gba.bus.write_word(dst + 12, cast[uint32](start_y))
      src += 20
      dst += 16
    cpu.hle_charge_body(body_t0, affine_model)
  of 0x0F:  # ObjAffineSet
    var src = cpu.r[0]
    var dst = cpu.r[1]
    var count = cpu.r[2]
    let dst_stride = cpu.r[3]
    # Real BIOS cost per entry: sin/cos lookups + two multiplies + 3 halfword
    # reads and 4 halfword writes, all nonsequential. Calibrated cycle-exact
    # against real-BIOS execution for IWRAM and EWRAM structs (stride 2 and
    # 8 cost the same).
    let affine_model = block:
      let bus = cpu.gba.bus
      let sp = int(bits_range(src, 24, 27))
      let dp = int(bits_range(dst, 24, 27))
      15 + int(count) * (45 + 3 * int(bus.wait16_n[sp]) + 4 * int(bus.wait16_n[dp]))
    while count > 0:
      let sx = cast[int32](cast[int16](cpu.gba.bus.read_half(src)))
      let sy = cast[int32](cast[int16](cpu.gba.bus.read_half(src + 2)))
      let angle = uint32(cpu.gba.bus.read_half(src + 4))
      src += 8
      # GBA angle: 0x0000..0xFFFF = 0..2*pi
      let theta = float64(angle) / 32768.0 * 3.14159265358979323846
      let cos_val = cast[int16](int32(float64(sx) * cos(theta)))
      let sin_val = cast[int16](int32(float64(sx) * sin(theta)))
      let cos_val_y = cast[int16](int32(float64(sy) * cos(theta)))
      let sin_val_y = cast[int16](int32(float64(sy) * sin(theta)))
      cpu.gba.bus.write_half(dst, uint16(cos_val));             dst += dst_stride  # pa
      cpu.gba.bus.write_half(dst, uint16(cast[uint16](-sin_val))); dst += dst_stride  # pb
      cpu.gba.bus.write_half(dst, uint16(sin_val_y));           dst += dst_stride  # pc
      cpu.gba.bus.write_half(dst, uint16(cos_val_y));           dst += dst_stride  # pd
      count -= 1
    cpu.hle_charge_body(body_t0, affine_model)
  of 0x11:  # LZ77UnCompWram (8-bit writes)
    var src = cpu.r[0]
    let src_page = int(bits_range(src, 24, 27))
    let dst_page = int(bits_range(cpu.r[1], 24, 27))
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    # The real BIOS reads the header first (ldr r5, [r0], #4), then validates
    # the post-increment source with the header's length before decompressing
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
    # Cost of the real BIOS loop (routine at 0x10FC), per token kind. Rn/Db
    # are the nonsequential byte access costs at the src/dst pages (the
    # BIOS's ldrb/strb never form a data burst). Verified cycle-exact
    # against real-BIOS execution on calibration streams at two waitstate
    # settings; run bytes cost 7+2*Db (ldrb dst-offset + strb + loop).
    block:
      let bus = cpu.gba.bus
      let rn = int(bus.wait16_n[src_page])
      let db = int(bus.wait16_n[dst_page])
      cpu.hle_charge_body_interruptible(body_t0, 29 + int(bus.wait32_n[src_page]) +
        n_flags * (9 + rn) + n_lit * (16 + rn + db) +
        n_tok * (22 + 3 * rn) + n_runb * (7 + 2 * db))
  of 0x12:  # LZ77UnCompVram (16-bit writes)
    # Decompress into a local buffer first, then copy to VRAM via halfword
    # writes.  Direct VRAM decompression breaks back-references because
    # bytes are buffered into halfwords and not flushed until the second
    # byte arrives — reads of the unflushed byte hit stale VRAM.
    var src = cpu.r[0]
    let src_page = int(bits_range(src, 24, 27))
    let dst_page = int(bits_range(cpu.r[1], 24, 27))
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    # Same real-BIOS validation as the Wram variant (header read first)
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
    # Write to destination using halfword writes
    var dst = cpu.r[1]
    var idx: uint32 = 0
    while idx < decomp_len:
      if idx + 1 < decomp_len:
        cpu.gba.bus.write_half(dst, uint16(buf[idx]) or (uint16(buf[idx + 1]) shl 8))
        dst += 2; idx += 2
      else:
        cpu.gba.bus.write_half(dst, uint16(buf[idx]))
        dst += 2; idx += 1
    # Cost of the real BIOS loop (routine at 0x1194). Heavier than the Wram
    # variant: it buffers output bytes into halfwords with register-shift
    # ops and reads back-references from the destination with ldrh, so run
    # bytes cost 21+Dh and each completed output halfword adds one strh
    # (+Dh). Verified cycle-exact against real-BIOS execution on calibration
    # streams (VRAM and EWRAM destinations, two waitstate settings).
    block:
      let bus = cpu.gba.bus
      let rn = int(bus.wait16_n[src_page])
      let dh = int(bus.wait16_n[dst_page])
      cpu.hle_charge_body_interruptible(body_t0, 39 + int(bus.wait32_n[src_page]) +
        n_flags * (9 + rn) + n_lit * (20 + rn) + n_tok * (25 + 3 * rn) +
        n_runb * (21 + dh) + dh * int(decomp_len div 2))
  of 0x10:  # BitUnPack
    var src = cpu.r[0]
    var dst = cpu.r[1]
    let info = cpu.r[2]
    let src_len = uint32(cpu.gba.bus.read_half(info))
    # The real BIOS reads the source length halfword from the info block,
    # then validates the source region before touching anything else
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
    for i in 0'u32 ..< src_len:
      let byte_val = uint32(cpu.gba.bus[src]); src += 1
      var bit_pos: uint32 = 0
      while bit_pos < 8:
        let val = (byte_val shr bit_pos) and src_mask
        var expanded: uint32
        if val != 0 or zero_flag:
          expanded = val + offset_val
        else:
          expanded = 0
        out_word = out_word or ((expanded and dest_mask) shl out_bits)
        out_bits += dest_width
        if out_bits >= 32:
          cpu.gba.bus.write_word(dst, out_word)
          dst += 4
          out_word = 0
          out_bits = 0
        bit_pos += src_width
  of 0x13:  # HuffUnComp
    var src = cpu.r[0]
    let src_page = int(bits_range(src, 24, 27))
    let dst_page = int(bits_range(cpu.r[1], 24, 27))
    # The real BIOS (routine at 0x1014) validates the raw source address
    # before reading anything, with a constant 0x02000000 as the "length"
    # (which contributes no bits to the end-address test, so this is a pure
    # source-region check)
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
    # Align data start to 4-byte boundary
    var data_pos = (data_start + 3) and not 3'u32
    var dst = cpu.r[1]
    var written: uint32 = 0
    var out_word: uint32 = 0
    var out_bits: uint32 = 0
    var cur_node = tree_start
    var cur_word: uint32 = 0
    var bits_left: int = 0
    var n_node, n_leaf, n_words, n_outw = 0
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
    # Cost of the real BIOS bit-by-bit tree walk (routine at 0x1014): every
    # consumed input bit costs a fixed instruction budget plus two ldrb tree
    # reads at the source page (the BIOS re-reads the node byte for the leaf
    # flags); a leaf additionally reads the symbol byte (ldrb), reloads the
    # per-word symbol target from the stack and resets to the tree root; each
    # completed output word pays one str at the destination and each 32-bit
    # bitstream refill one ldr at the source. Constants instruction-counted
    # from the disassembly and calibrated against real-BIOS execution in
    # dingbat (scratch_swicalib.nim: 4/8-bit symbols, tree depths 1-8, ROM
    # and EWRAM sources, EWRAM and IWRAM destinations): cycle-exact on every
    # odd-depth stream, within 0.5% on even depths (a source-layout parity
    # artifact of the synthetic left-spine calibration trees).
    block:
      let bus = cpu.gba.bus
      let b = int(bus.wait16_n[src_page])   # nonseq byte read at src
      let w = int(bus.wait32_n[src_page])   # nonseq word read at src
      let d = int(bus.wait32_n[dst_page])   # nonseq word write at dst
      cpu.hle_charge_body_interruptible(body_t0, 57 + 2 * b + w +
        n_node * (25 + 2 * b) + n_leaf * (39 + 3 * b) +
        n_outw * d + n_words * (9 + w))
  of 0x14:  # RLUnCompWram (8-bit writes)
    var src = cpu.r[0]
    let src_page = int(bits_range(src, 24, 27))
    let dst_page = int(bits_range(cpu.r[1], 24, 27))
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    # Real-BIOS validation: header read first, then the source check
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
    # Cost of the real BIOS loop (Thumb routine at 0x1278): flag byte decode
    # ~10 + one nonseq byte read; literal bytes ldrb+strb (~11 + Rn + Db);
    # runs read their fill byte once (~9 + Rn) then strb per output byte
    # (~7 + Db). Constants from instruction-cycle counting of the
    # disassembly, cross-checked against real-BIOS execution.
    block:
      let bus = cpu.gba.bus
      let rn = int(bus.wait16_n[src_page])
      let db = int(bus.wait16_n[dst_page])
      cpu.hle_charge_body_interruptible(body_t0, 40 + int(bus.wait32_n[src_page]) +
        n_flags * (10 + rn) + n_lit * (11 + rn + db) +
        n_rruns * (9 + rn) + n_runb * (7 + db))
  of 0x15:  # RLUnCompVram (16-bit writes)
    var src = cpu.r[0]
    let src_page = int(bits_range(src, 24, 27))
    let dst_page = int(bits_range(cpu.r[1], 24, 27))
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    # Real-BIOS validation: header read first, then the source check
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
    # Cost of the real BIOS loop (Thumb routine at 0x12C0): heavier than the
    # Wram variant — the flag decode spills through the stack (~18 + Rn),
    # literal bytes buffer into halfwords (~14 + Rn), run bytes replay the
    # spilled fill byte (~13), and each completed output halfword is one
    # strh (+Dh). Constants from instruction-cycle counting of the
    # disassembly, cross-checked against real-BIOS execution.
    block:
      let bus = cpu.gba.bus
      let rn = int(bus.wait16_n[src_page])
      let dh = int(bus.wait16_n[dst_page])
      cpu.hle_charge_body_interruptible(body_t0, 45 + int(bus.wait32_n[src_page]) +
        n_flags * (18 + rn) + n_lit * (14 + rn) +
        n_rruns * (10 + rn) + n_runb * 13 + n_halves * (2 + dh))
  of 0x16:  # Diff8bitUnFilterWram (8-bit writes)
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    # Real-BIOS validation: header read first, then the source check
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
  of 0x17:  # Diff8bitUnFilterVram (16-bit writes)
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    # Real-BIOS validation: header read first, then the source check
    if not bios_addr_check(src, decomp_len):
      cpu.idle(BIOS_CHECK_SKIP_COST)
      return
    var dst = cpu.r[1]
    var written: uint32 = 0
    var out_buf: uint16 = 0
    var out_idx: uint32 = 0
    var prev = cpu.gba.bus[src]; src += 1
    # Output first byte
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
  of 0x18:  # Diff16bitUnFilter
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    # Real-BIOS validation: header read first, then the source check
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
  of 0x19:  # SoundBias(r0): 0 sets SOUNDBIAS=0x000, else SOUNDBIAS=0x200.
    # bias_level is the 9-bit field at register bits 1-9, so the 0x200 register
    # value is bias_level 0x100 (not 0x200, which would truncate to 0).
    cpu.gba.apu.soundbias.bias_level = if cpu.r[0] == 0: 0x000'u16 else: 0x100'u16
  of 0x1A, 0x1B, 0x1D, 0x1E, 0x20, 0x21, 0x22, 0x23, 0x24, 0x28, 0x29:
    discard  # Sound driver / music player stubs (games use their own engine)
  of 0x1C:  # SoundDriverMain
    if not cpu.gba.bus.stub_bios:
      # A real BIOS image is mapped (hle_after_bios): the stub trampolines
      # are absent, so keep the historical no-op behavior
      return
    # Execute the stub-BIOS SoundMain dispatch (thumb code at the real
    # routine's address, 0x1DC4): it checks the SoundInfo ident magic at
    # [0x03007FF0] — returning immediately when no MP2K driver is installed,
    # like the real routine — and otherwise locks the engine and calls the
    # game's registered ROM callbacks before unlocking. Games that drive
    # the BIOS-resident MP2K engine (Cyberdrive Zoids: SoundGetJumpList +
    # swi 0x1C every frame) block their main loop on state those callbacks
    # advance; with the old no-op they never booted. The BIOS PCM mixer is
    # not modeled (documented gap). Like the real dispatcher, the stub runs
    # in SVC mode on the SVC stack with the caller's r14 safely banked; its
    # closing `swi 0` is the dispatcher's `movs pc, lr` exit, handled as an
    # HLE trap (see the 0x00 case).
    let isa_step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
    let old_cpsr = cpu.cpsr
    let ret = cpu.r[15] - isa_step
    cpu.switch_mode(modeSVC)
    cpu.spsr = old_cpsr
    cpu.r[14] = ret
    cpu.cpsr.thumb = true
    discard cpu.set_reg(15, 0x1DC4'u32 - isa_step)
  of 0x2A:  # SoundGetJumpList
    # Copies the 36 sound-driver function pointers from the BIOS table
    # (0x3738) to [r0] — the same values as the real BIOS; the stub BIOS
    # backs them with code (see new_bus). Register protocol of the real
    # routine (0x2692): r0 advances past the destination (stmia r0!), r1
    # counts down to 0, r2 ends past the table, r3 holds the last entry.
    block:
      var dst = cpu.r[0]
      var last = 0'u32
      for i in 0 ..< 36:
        # Direct table read: the BIOS-protection latch does not apply (the
        # real routine executes from BIOS while it copies)
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
      # Instruction-counted from the real routine: per word, the table ldr,
      # the 0xBA4-style validation subroutine and the stmia at the
      # destination (+6 entry/exit)
      let dst_page = int(bits_range(cpu.r[0], 24, 27))
      cpu.hle_charge_body(body_t0, 6 + 36 * (33 + int(cpu.gba.bus.wait32_n[dst_page])))
  of 0x1F:  # MidiKey2Freq
    let base_freq = cpu.gba.bus.read_word(cpu.r[0] + 4)
    let key = cast[int32](cpu.r[1])
    let pitch = cast[int32](cpu.r[2])
    # BIOS reference key is 180 (not middle-C 60): WaveData.freq stores the
    # sample rate scaled up 10 octaves, and MidiKey2Freq divides it back down by
    # (180 - key - pitch/256) semitones. Using 60 made every note 120 semitones
    # (2^10 = 1024x) too high, so the M4A mixer strode through sample data ~1000x
    # too fast -> aliased screeching (Metroid Fusion intro).
    let exponent = (float64(key) - 180.0 + float64(pitch) / 256.0) / 12.0
    let freq = float64(base_freq) * pow(2.0, exponent)
    cpu.r[0] = uint32(freq)
  of 0x25:  # MultiBoot
    cpu.r[0] = 1'u32  # Return failure (link cable not emulated)
  else:
    echo "unimplemented SWI: 0x", toHex(swi_num, 2)

proc exception_return_restore*(cpu: CPU) =
  ## CPSR <- SPSR after an instruction that loaded r15 with the S bit set
  ## (subs pc, lr, #4 / ldmfd sp!, {..., pc}^). Assumes set_reg(15) already
  ## ran, so the pipeline offset is corrected when returning to thumb.
  cpu.instr_exc_return = true
  if cpu.spsr.thumb:
    cpu.r[15] -= 4
    # set_reg(15) already refilled the pipeline at ARM width; a return to
    # thumb refills with two halfword fetches instead. Charge the
    # difference (zero in IWRAM/BIOS, -6 in EWRAM/default ROM).
    let page = int(bits_range(cpu.r[15], 24, 27))
    cpu.gba.bus.add_cycles(2 * (int(cpu.gba.bus.wait16_s[page]) -
                                int(cpu.gba.bus.wait32_s[page])))
  let old_spsr = uint32(cpu.spsr)
  let was_irq_disabled = cpu.cpsr.irq_disable
  let new_mode = cast[CpuMode](cpu.spsr.mode)
  cpu.switch_mode(new_mode)
  cpu.cpsr = cast[PSR](old_spsr)
  let bank = mode_bank(new_mode)
  cpu.spsr = cast[PSR](if bank == 0: uint32(cpu.cpsr) else: cpu.spsr_banks[bank])
  if was_irq_disabled and not cpu.cpsr.irq_disable:
    cpu.gba.interrupts.schedule_interrupt_check()

proc arm_unimplemented*(cpu: CPU; instr: uint32) =
  # und() writes PC (vector 0x04); stepping past it would skip the vector
  cpu.und()

proc arm_unused*(cpu: CPU; instr: uint32) =
  cpu.und()

proc rotate_register*(cpu: CPU; instr: uint32; carry_out: ptr bool; allow_register_shifts: bool): uint32 =
  let reg        = int(bits_range(instr, 0, 3))
  let shift_type = int(bits_range(instr, 5, 6))
  let immediate  = not (allow_register_shifts and bit(instr, 4))
  var shift_amount: uint32
  if immediate:
    shift_amount = bits_range(instr, 7, 11)
  else:
    let shift_register = int(bits_range(instr, 8, 11))
    shift_amount = cpu.r[shift_register] and 0xFF'u32
  case shift_type
  of 0b00: cpu.lsl(cpu.r[reg], shift_amount, carry_out)
  of 0b01: cpu.lsr(cpu.r[reg], shift_amount, immediate, carry_out)
  of 0b10: cpu.asr(cpu.r[reg], shift_amount, immediate, carry_out)
  of 0b11: cpu.ror(cpu.r[reg], shift_amount, immediate, carry_out)
  else: raise newException(Exception, "Impossible shift type: " & hex_str(uint8(shift_type)))

proc immediate_offset*(cpu: CPU; instr: uint32; carry_out: ptr bool): uint32 =
  let rotate = bits_range(instr, 8, 11)
  let imm    = bits_range(instr, 0, 7)
  cpu.ror(imm, rotate shl 1, false, carry_out)

type ArmAluOp* = enum
  AND, EOR, SUB, RSB,
  ADD, ADC, SBC, RSC,
  TST, TEQ, CMP, CMN,
  ORR, MOV, BIC, MVN

proc arm_multiply*[accumulate, set_cond: static bool](cpu: CPU; instr: uint32) =
  let rd  = int(bits_range(instr, 16, 19))
  let rn  = int(bits_range(instr, 12, 15))
  let rs  = int(bits_range(instr, 8, 11))
  let rm  = int(bits_range(instr, 0, 3))
  let acc = when accumulate: cpu.r[rn] else: 0'u32
  cpu.idle(mul_i_cycles(cpu.r[rs], true) + (when accumulate: 1 else: 0))
  discard cpu.set_reg(rd, cpu.r[rm] * cpu.r[rs] + acc)
  when set_cond: cpu.set_neg_and_zero_flags(cpu.r[rd])
  if rd != 15: cpu.step_arm()

proc arm_multiply_long*[signed, accumulate, set_cond: static bool](cpu: CPU; instr: uint32) =
  let rdhi = int(bits_range(instr, 16, 19))
  let rdlo = int(bits_range(instr, 12, 15))
  let rs   = int(bits_range(instr, 8, 11))
  let rm   = int(bits_range(instr, 0, 3))
  var res: uint64 =
    when signed:
      cast[uint64](int64(cast[int32](cpu.r[rm])) * int64(cast[int32](cpu.r[rs])))
    else:
      uint64(cpu.r[rm]) * uint64(cpu.r[rs])
  cpu.idle(mul_i_cycles(cpu.r[rs], signed) + (when accumulate: 2 else: 1))
  when accumulate:
    res += (uint64(cpu.r[rdhi]) shl 32) or uint64(cpu.r[rdlo])
  discard cpu.set_reg(rdhi, uint32(res shr 32))
  discard cpu.set_reg(rdlo, uint32(res))
  when set_cond:
    cpu.cpsr.negative = bit(cpu.r[rdhi], 31)
    cpu.cpsr.zero     = (res == 0)
    # ARM7TDMI "meaningless" carry flag: determined by the Booth multiplier internals.
    # For long multiply, the carry depends on the number of Booth iterations and
    # the interaction of Rm/Rs bit patterns in the carry-save adder.
    block:
      let rs_val = cpu.r[rs]
      let rm_val = cpu.r[rm]
      when signed:
        var rs33 = uint64(rs_val)
        if bit(rs_val, 31): rs33 = rs33 or 0x1_00000000'u64
        let four_iters = not ((rs33 shr 8) == 0 or (rs33 shr 8) == 0x1FFFFFF'u64 or
                              (rs33 shr 16) == 0 or (rs33 shr 16) == 0x1FFFF'u64 or
                              (rs33 shr 24) == 0 or (rs33 shr 24) == 0x1FF'u64)
        cpu.cpsr.carry = four_iters and (bit(rm_val, 31) xor bit(rs_val, 31))
      else:
        let four_iters = rs_val > 0xFFFFFF'u32
        if four_iters and ((rs_val shr 29) == 7):
          # Rs bits [31:29] all set: Booth chunk 15 cancels, carry from chunk 16
          cpu.cpsr.carry = bit(rm_val, 30)
        else:
          cpu.cpsr.carry = four_iters and bit(rm_val, 31)
  if rdhi != 15 and rdlo != 15: cpu.step_arm()

proc arm_single_data_swap*[byte_quantity: static bool](cpu: CPU; instr: uint32) =
  let rn = int(bits_range(instr, 16, 19))
  let rd = int(bits_range(instr, 12, 15))
  let rm = int(bits_range(instr, 0, 3))
  when byte_quantity:
    let tmp = cpu.gba.bus[cpu.r[rn]]
    cpu.gba.bus[cpu.r[rn]] = uint8(cpu.r[rm])
    discard cpu.set_reg(rd, uint32(tmp))
  else:
    let tmp = cpu.gba.bus.read_word_rotate(cpu.r[rn])
    cpu.gba.bus.write_word(cpu.r[rn], cpu.r[rm])
    discard cpu.set_reg(rd, tmp)
  cpu.idle(1)
  if rd != 15: cpu.step_arm()

proc arm_branch_exchange*(cpu: CPU; instr: uint32) =
  let address = cpu.r[int(bits_range(instr, 0, 3))]
  cpu.cpsr.thumb = bit(address, 0)
  discard cpu.set_reg(15, address)

proc arm_halfword_data_transfer*[pre, add, immediate, write_back, load: static bool,
                                  sh: static uint32](cpu: CPU; instr: uint32) =
  let rn     = int(bits_range(instr, 16, 19))
  let rd     = int(bits_range(instr, 12, 15))
  let offset =
    when immediate:
      (bits_range(instr, 8, 11) shl 4) or bits_range(instr, 0, 3)
    else:
      cpu.r[int(bits_range(instr, 0, 3))]
  var address = cpu.r[rn]
  when pre:
    when add: address += offset
    else:     address -= offset
  when sh == 0b00:
    raise newException(Exception, "HalfwordDataTransfer sh=00: " & hex_str(instr))
  elif sh == 0b01:  # ldrh/strh
    when load:
      let value = cpu.gba.bus.read_half_rotate(address)
      cpu.idle(1)
      discard cpu.set_reg(rd, value)
    else:
      cpu.gba.bus.write_half(address, uint16(cpu.r[rd] and 0xFFFF'u32))
      if rd == 15:
        cpu.gba.bus.write_half(address, uint16(cpu.gba.bus.read_half(address)) + 4)
  elif sh == 0b10:  # ldrsb
    let value = uint32(cast[int32](cast[int8](cpu.gba.bus[address])))
    cpu.idle(1)
    discard cpu.set_reg(rd, value)
  else:  # sh == 0b11, ldrsh
    let value = cpu.gba.bus.read_half_signed(address)
    cpu.idle(1)
    discard cpu.set_reg(rd, value)
  when not pre:
    when add: address += offset
    else:     address -= offset
  when write_back or not pre:
    if rd != rn or not load:
      discard cpu.set_reg(rn, address)
  if not (load and rd == 15): cpu.step_arm()

proc arm_single_data_transfer*[imm_flag, pre_addressing, add_offset, byte_quantity,
                                 write_back, load, bit0: static bool](cpu: CPU; instr: uint32) =
  var carry_out = false
  let rn = int(bits_range(instr, 16, 19))
  let rd = int(bits_range(instr, 12, 15))
  let offset =
    when imm_flag:
      cpu.rotate_register(bits_range(instr, 0, 11), addr carry_out, allow_register_shifts = false)
    else:
      bits_range(instr, 0, 11)
  var address = cpu.r[rn]
  when pre_addressing:
    when add_offset: address += offset
    else:            address -= offset
  when load:
    let value =
      when byte_quantity:
        uint32(cpu.gba.bus[address])
      else:
        cpu.gba.bus.read_word_rotate(address)
    cpu.idle(1)
    discard cpu.set_reg(rd, value)
  else:
    when byte_quantity:
      cpu.gba.bus[address] = uint8(cpu.r[rd])
    else:
      cpu.gba.bus.write_word(address, cpu.r[rd])
    if rd == 15:
      cpu.gba.bus.write_word(address, cpu.gba.bus.read_word(address) + 4)
  when not pre_addressing:
    when add_offset: address += offset
    else:            address -= offset
  when write_back or not pre_addressing:
    if rd != rn or not load:
      discard cpu.set_reg(rn, address)
  if not (load and rd == 15): cpu.step_arm()

proc arm_block_data_transfer*[pre_address, add, s_bit, write_back, load: static bool](cpu: CPU; instr: uint32) =
  let rn = int(bits_range(instr, 16, 19))
  var list = bits_range(instr, 0, 15)
  var saved_mode: uint32 = 0
  var user_bank = false
  when s_bit:
    # LDM with the S bit and r15 in the list is an exception return: the
    # registers load into the current mode's banks and CPSR is restored from
    # SPSR after pc loads. Every other S-bit form transfers the user bank.
    if not (load and bit(list, 15)):
      user_bank = true
      saved_mode = cpu.cpsr.mode
      cpu.switch_mode(modeUSR)
  var address  = cpu.r[rn]
  var bits_set = count_set_bits(list)
  if bits_set == 0:
    bits_set = 16
    list = 0x8000'u32
  let step       = when add: 4 else: -4
  let final_addr = uint32(int(address) + bits_set * step)
  when add:
    when pre_address: address += 4
  else:
    address = final_addr
    when not pre_address: address += 4
  var first_transfer = false
  for idx in 0..15:
    if bit(list, idx):
      when load:
        let value = cpu.gba.bus.read_word(address)
        if idx == 15: cpu.idle(1)  # the I cycle precedes the pipeline refill
        discard cpu.set_reg(idx, value)
      else:
        cpu.gba.bus.write_word(address, cpu.r[idx])
        if idx == 15:
          cpu.gba.bus.write_word(address, cpu.gba.bus.read_word(address) + 4)
      address += 4
      when write_back:
        if not first_transfer and not (load and bit(list, rn)):
          discard cpu.set_reg(rn, final_addr)
      first_transfer = true
  when load:
    if not bit(list, 15): cpu.idle(1)  # I cycle after the last transfer
  when s_bit:
    if user_bank:
      cpu.switch_mode(cast[CpuMode](saved_mode))
    else:
      cpu.exception_return_restore()
  if not (load and bit(list, 15)): cpu.step_arm()

proc arm_branch*[link: static bool](cpu: CPU; instr: uint32) =
  let offset = cast[int32](bits_range(instr, 0, 23) shl 8) shr 6
  when link: discard cpu.set_reg(14, cpu.r[15] - 4)
  discard cpu.set_reg(15, uint32(int(cpu.r[15]) + offset))

proc arm_software_interrupt*(cpu: CPU; instr: uint32) =
  let use_hle = cpu.gba.use_hle or (cpu.gba.hle_after_bios and cpu.r[15] >= 0x08000000'u32)
  let swi_num = bits_range(instr, 16, 23)
  if use_hle:
    cpu.hle_swi(swi_num)
    cpu.step_arm()
  else:
    let lr = cpu.r[15] - 4
    let old_cpsr = cpu.cpsr
    cpu.switch_mode(modeSVC)
    cpu.spsr = old_cpsr
    discard cpu.set_reg(14, lr)
    cpu.cpsr.irq_disable = true
    discard cpu.set_reg(15, 0x08'u32)

proc arm_psr_transfer*[imm_flag, spsr, msr: static bool](cpu: CPU; instr: uint32) =
  let mode     = cast[CpuMode](cpu.cpsr.mode)
  let has_spsr = mode != modeUSR and mode != modeSYS
  when msr:
    var mask: uint32 = 0
    if bit(instr, 19): mask = mask or 0xFF000000'u32
    if bit(instr, 18): mask = mask or 0x00FF0000'u32
    if bit(instr, 17): mask = mask or 0x0000FF00'u32
    if bit(instr, 16): mask = mask or 0x000000FF'u32
    var carry_out = false
    let value =
      when imm_flag:
        cpu.immediate_offset(bits_range(instr, 0, 11), addr carry_out) and mask
      else:
        cpu.r[int(bits_range(instr, 0, 3))] and mask
    when spsr:
      if has_spsr:
        cpu.spsr = cast[PSR]((uint32(cpu.spsr) and not mask) or value)
    else:
      let was_irq_disabled = cpu.cpsr.irq_disable
      if (mask and 0xFF) > 0:
        cpu.switch_mode(cast[CpuMode](value and 0x1F'u32))
      cpu.cpsr = cast[PSR]((uint32(cpu.cpsr) and not mask) or value)
      if cpu.cpsr.thumb:
        # MSR really does write the T bit on ARM7TDMI (architecturally
        # UNPREDICTABLE, but well-defined on this core and relied on by
        # commercial software: Pokemon Pinball R/S's decompressor exits via
        # `msr cpsr, r2` with T set followed by a Thumb `bx r0`). The switch
        # happens mid-pipeline, so the two words already prefetched as ARM
        # are reinterpreted (mGBA-verified hardware model): the next opcode
        # (at A+4) executes as a Thumb nop, then the LOW halfword of the word
        # at A+8 executes, and fetching resumes at A+12. We stage the two
        # reinterpreted opcodes in the pipeline buffer; the usual +4 step
        # below leaves r15 tracking mGBA's PC exactly through the hand-off.
        cpu.pipeline.clear()
        cpu.pipeline.push(0x46C0'u32)  # Thumb nop (mov r8, r8)
        cpu.pipeline.push(cpu.gba.bus.read_word_internal(cpu.r[15]) and 0xFFFF'u32)
      if was_irq_disabled and not cpu.cpsr.irq_disable:
        cpu.gba.interrupts.schedule_interrupt_check()
  else:  # MRS
    let rd = int(bits_range(instr, 12, 15))
    if spsr and has_spsr:
      discard cpu.set_reg(rd, uint32(cpu.spsr))
    else:
      discard cpu.set_reg(rd, uint32(cpu.cpsr))
  when not msr:
    if bits_range(instr, 12, 15) != 15: cpu.step_arm()
  else:
    cpu.step_arm()

proc arm_data_processing*[imm_flag: static bool, opcode: static ArmAluOp,
                            set_cond, bit4: static bool](cpu: CPU; instr: uint32) =
  const pc_reads_12_ahead = not imm_flag and bit4
  when pc_reads_12_ahead:
    cpu.r[15] += 4
    cpu.idle(1)  # register-specified shift costs one internal cycle
  var barrel_carry = cpu.cpsr.carry
  let rn = int(bits_range(instr, 16, 19))
  let rd = int(bits_range(instr, 12, 15))
  let operand_2 =
    when imm_flag:
      cpu.immediate_offset(bits_range(instr, 0, 11), addr barrel_carry)
    else:
      cpu.rotate_register(bits_range(instr, 0, 11), addr barrel_carry, allow_register_shifts = true)
  when opcode == AND:
    discard cpu.set_reg(rd, cpu.r[rn] and operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  elif opcode == EOR:
    discard cpu.set_reg(rd, cpu.r[rn] xor operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  elif opcode == SUB:
    discard cpu.set_reg(rd, cpu.sub(cpu.r[rn], operand_2, set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == RSB:
    discard cpu.set_reg(rd, cpu.sub(operand_2, cpu.r[rn], set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == ADD:
    discard cpu.set_reg(rd, cpu.add(cpu.r[rn], operand_2, set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == ADC:
    discard cpu.set_reg(rd, cpu.adc(cpu.r[rn], operand_2, set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == SBC:
    discard cpu.set_reg(rd, cpu.sbc(cpu.r[rn], operand_2, set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == RSC:
    discard cpu.set_reg(rd, cpu.sbc(operand_2, cpu.r[rn], set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == TST:
    cpu.set_neg_and_zero_flags(cpu.r[rn] and operand_2)
    cpu.cpsr.carry = barrel_carry
    cpu.step_arm()
  elif opcode == TEQ:
    cpu.set_neg_and_zero_flags(cpu.r[rn] xor operand_2)
    cpu.cpsr.carry = barrel_carry
    cpu.step_arm()
  elif opcode == CMP:
    discard cpu.sub(cpu.r[rn], operand_2, set_cond)
    cpu.step_arm()
  elif opcode == CMN:
    discard cpu.add(cpu.r[rn], operand_2, set_cond)
    cpu.step_arm()
  elif opcode == ORR:
    discard cpu.set_reg(rd, cpu.r[rn] or operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  elif opcode == MOV:
    discard cpu.set_reg(rd, operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  elif opcode == BIC:
    discard cpu.set_reg(rd, cpu.r[rn] and not operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  else:  # MVN
    discard cpu.set_reg(rd, not operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  when pc_reads_12_ahead: cpu.r[15] -= 4
  if rd == 15 and set_cond:
    cpu.exception_return_restore()
