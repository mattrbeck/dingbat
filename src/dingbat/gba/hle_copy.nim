# CpuSet and CpuFastSet, run instruction by instruction (included by
# hle_bios.nim)
#
# The copy routines run with the caller's IRQ mask, so an interrupt takes
# them at the end of whichever of their instructions it arrives in: between
# an ldmia and its stmia, inside the loop's test, after a store. The HLE used
# to take one only at the end of a whole unit (a transfer, or an 8-word
# burst), up to ~120 cycles late inside a CpuFastSet to VRAM (Contra Advance's
# H-blank handler ran that late every line it fell in a copy), and from the
# caller's code after rewinding onto the SWI, so the handler's entry and
# return paid the caller's region and a fitted constant stood in for the
# rest (cpusi.c: a Thumb caller in the cartridge 2 cycles a preemption short
# at WAITCNT 0x4317, 2 long at 0x0000).
#
# Now each unit is the routine's own instructions with their times (the
# playtest driver's `trace` of the official BIOS in this core, one step per
# instruction; CpuSet's halfword copy is test, branch, ldrh, strh, add,
# branch back), the loads and stores land in the instruction that makes
# them, and an interrupt is taken at the instruction boundary the CPU would
# take it at -- including one recognised in the last wait states of a single
# store, which waits for the next instruction (IRQ_LAST_WAITS; an stmia's do
# not), and the boundaries after the loop up to the dispatcher's `msr` that
# masks interrupts for the return (copy_tail_steps). The loop starts where
# the console's does against the swi: hle_bios.nim routine_phase moves the
# fitted split of the fixed cost by the caller's comment read. A copy that
# stops for one parks where the console's routine is, in BIOS code: the
# SWI's frames go on the SVC and System stacks as a Halt's do, the routine's
# own frame below them, its state in registers (r0-r2 the call's arguments,
# r12 how far it got, r3 -- and r4-r10 for CpuFastSet -- the words loaded
# and not yet stored), and the PC on a trap in the stub BIOS (COPY_TRAP)
# that the interrupt returns to. Everything is architectural, so a save
# state taken while a copy waits on its interrupt resumes it. A copy also
# parks at the end of a video frame (hle_frame_ended), with no interrupt to
# take, and the trap runs it on at the next instruction.
#
# tools/biosdrv/cpusi4.c (CpuSet's four kinds from ARM and Thumb callers in
# IWRAM and the cartridge, under a timer interrupt every 3000 cycles and
# none) and fastsi.c (CpuFastSet copies and fills, EWRAM and cartridge to
# VRAM, likewise): every call's time and every interrupt's entry cycle are
# the console's; cpusi.c the same at WAITCNT 0x4317 (and its 0x0317 and
# 0x0000 rebuilds), 1340 of 1342 entries.

const COPY_TRAP = 0x0BC8'u32   # stub BIOS: an ARM `swi 0`

type
  CopyKind = enum
    ckHalfCopy, ckWordCopy, ckHalfFill, ckWordFill, ckFastCopy, ckFastFill
  CopyStep = object
    cost: int    # the instruction's cycles, its fetch included
    act: int     # 0: none, 1: the unit's load(s), 2: its store(s)
    waits: int   # a single store: the wait states of its access (an stmia's
                 # last waits defer nothing: fastsi.c)

proc copy_steps(bus: Bus; kind: CopyKind; sp, dp: int;
                steps: var array[6, CopyStep]): int =
  ## One unit of the loop, instruction by instruction: the routine's own
  ## times on the official BIOS in this core (a 1-cycle BIOS fetch per
  ## instruction; a load adds its access and an internal cycle, a store its
  ## access, a taken branch two refill fetches). Their sum is the unit cost
  ## the routine models were fitted to.
  template st(i, c, a, w: int) = steps[i] = CopyStep(cost: c, act: a, waits: w)
  case kind
  of ckHalfCopy:   # test, branch, ldrh, strh, add, branch back
    let ns = int(bus.wait16_n[sp])
    let nd = int(bus.wait16_n[dp])
    st(0, 1, 0, 0); st(1, 1, 0, 0); st(2, 2 + ns, 1, 0); st(3, 1 + nd, 2, nd - 1)
    st(4, 1, 0, 0); st(5, 3, 0, 0)
    6
  of ckWordCopy:   # test, branch, ldmia, stmia, branch back
    let ns = int(bus.wait32_n[sp])
    let nd = int(bus.wait32_n[dp])
    st(0, 1, 0, 0); st(1, 1, 0, 0); st(2, 2 + ns, 1, 0); st(3, 1 + nd, 2, nd - 1)
    st(4, 3, 0, 0)
    5
  of ckHalfFill:   # test, branch, strh, add, branch back
    let nd = int(bus.wait16_n[dp])
    st(0, 1, 0, 0); st(1, 1, 0, 0); st(2, 1 + nd, 2, nd - 1); st(3, 1, 0, 0)
    st(4, 3, 0, 0)
    5
  of ckWordFill:   # test, branch, stmia, branch back
    let nd = int(bus.wait32_n[dp])
    st(0, 1, 0, 0); st(1, 1, 0, 0); st(2, 1 + nd, 2, nd - 1); st(3, 3, 0, 0)
    4
  of ckFastCopy:   # subs, ldmia (8 words), stmia (8 words), branch back
    let bs = int(bus.wait32_n[sp]) + 7 * int(bus.wait32_s[sp])
    let bd = int(bus.wait32_n[dp]) + 7 * int(bus.wait32_s[dp])
    st(0, 1, 0, 0); st(1, 2 + bs, 1, 0); st(2, 1 + bd, 2, 0); st(3, 3, 0, 0)
    4
  of ckFastFill:   # subs, stmia (8 words), branch back
    let bd = int(bus.wait32_n[dp]) + 7 * int(bus.wait32_s[dp])
    st(0, 1, 0, 0); st(1, 1 + bd, 2, 0); st(2, 3, 0, 0)
    3

proc copy_tail_steps(cpu: CPU; kind: CopyKind; steps: var array[8, int]): int =
  ## The instructions after the loop that an interrupt can still come
  ## between: the loop's exit, the routine's pops and return, and the
  ## dispatcher's pop {r2, lr} and the instruction after it -- the next, an
  ## msr, masks interrupts for the rest of the return. The pops pay the
  ## System stack's region (swi_frame, as swi_stack_exit prices them).
  let w = cpu.sys_stack_waits()
  template pop(words: int): int = 2 + words + w.stack_block(words)
  case kind
  of ckHalfCopy, ckWordCopy, ckHalfFill, ckWordFill:
    # test, exit branch, pop {r4, r5}, pop {r3}, bx r3 | pop {r2, lr}, mov
    steps[0] = 1; steps[1] = 3; steps[2] = pop(2); steps[3] = pop(1); steps[4] = 3
    steps[5] = pop(2); steps[6] = 1
    7
  of ckFastCopy:
    # subs and the three skipped burst instructions, ldmfd, bx lr | ...
    steps[0] = 1; steps[1] = 1; steps[2] = 1; steps[3] = 1; steps[4] = pop(8)
    steps[5] = 3; steps[6] = pop(2); steps[7] = 1
    8
  of ckFastFill:
    # subs, the two skipped, the branch to the epilogue, ldmfd, bx lr | ...
    steps[0] = 1; steps[1] = 1; steps[2] = 1; steps[3] = 3; steps[4] = pop(8)
    steps[5] = 3; steps[6] = pop(2); steps[7] = 1
    8

type CopyRun = object
  kind: CopyKind
  src0, dst0, ctrl: uint32   # the call's r0, r1, r2
  units: uint32              # units in all (transfers; CpuFastSet: bursts)
  done: uint32               # units completed
  step: int                  # next instruction of the current unit
  held: array[8, uint32]     # loaded, not yet stored
  fill_val: uint32
  tail: int                  # the routine's cycles after its loop

proc copy_unit_bytes(k: CopyKind): uint32 {.inline.} =
  case k
  of ckHalfCopy, ckHalfFill: 2
  of ckWordCopy, ckWordFill: 4
  of ckFastCopy, ckFastFill: 32

proc copy_fast(k: CopyKind): bool {.inline.} = k in {ckFastCopy, ckFastFill}

proc copy_frame_words(k: CopyKind): int {.inline.} =
  ## The routine's own push below the dispatcher's {r2, lr}: CpuSet
  ## {r4, r5, lr}, CpuFastSet {r4-r10, lr}
  if k.copy_fast: 8 else: 3

proc copy_park(cpu: CPU; run: CopyRun; framed: bool) =
  ## Stop where the console's routine is when an interrupt (or the frame's
  ## end) comes: frames, state in registers, the PC on COPY_TRAP.
  let bus = cpu.gba.bus
  let isa_step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
  if not framed:
    # First stop of this call: the SWI's state on the SVC stack (as a Halt
    # keeps it), then System mode with the caller's I bit; the dispatcher's
    # {r2, lr} and the routine's frame are already in memory below sp_sys
    # (hle_swi, the routines' residue): take them onto the stack.
    let ret = cpu.r[15] - isa_step
    cpu.push_halt_svc_frame(ret)
    cpu.r[13] -= uint32(8 + 4 * run.kind.copy_frame_words)
  cpu.r[0] = run.src0
  cpu.r[1] = run.dst0
  # (the tail in r2's unused top bits: hle_bios routine_phase moves it)
  cpu.r[2] = (run.ctrl and 0x07FFFFFF'u32) or (uint32(clamp(run.tail, 0, 31)) shl 27)
  cpu.r[3] = run.held[0]
  if run.kind.copy_fast:
    for i in 1 .. 7: cpu.r[3 + i] = run.held[i]
  cpu.r[12] = uint32(run.step) or (uint32(ord(run.kind)) shl 4) or (run.done shl 8)
  let before = bus.cycles
  discard cpu.set_reg(15, COPY_TRAP - isa_step)  # the SWI handler steps isa_step
  bus.cycles = before

proc copy_return(cpu: CPU; swi_num: uint32; extra: int) =
  ## A parked copy's end: the dispatcher's return through the frames
  ## copy_park pushed, as cpu.hle_halt_return takes a Halt's, priced as an
  ## unparked call's return (swi_exit_cost, the refill in the caller's
  ## region included) once the caller's state is back.
  let bus = cpu.gba.bus
  # System stack: the dispatcher's {r2, lr}
  cpu.r[2] = bus.read_word_internal(cpu.r[13])
  cpu.r[14] = bus.read_word_internal(cpu.r[13] + 4)
  cpu.r[13] += 8
  # SVC stack: {caller CPSR, r12, return address}, then `movs pc, lr`
  cpu.switch_mode(modeSVC)
  cpu.cpsr = cast[PSR](uint32(modeSVC) or 0xC0'u32)
  let sp = cpu.r[13]
  cpu.spsr = cast[PSR](bus.read_word_internal(sp))
  cpu.r[12] = bus.read_word_internal(sp + 4)
  cpu.r[14] = bus.read_word_internal(sp + 8)
  cpu.r[13] = sp + 12
  # The return path (swi_exit_cost): the BIOS code before the refill, then
  # the `movs pc, lr`'s refill in the caller's region, at least N+S as an
  # unparked call's is (the pipeline refill and the Thumb correction that
  # follows it price it themselves)
  let page = int(bits_range(cpu.r[14], 24, 27))
  let refill = if cpu.spsr.thumb: int(bus.wait16_n[page]) + int(bus.wait16_s[page])
               else: int(bus.wait32_n[page]) + int(bus.wait32_s[page])
  cpu.idle(max(0, extra + SWI_HLE_EXIT + int(bus.wait16_s[page]) - 1 + cpu.swi_stack_exit(swi_num)))
  let t1 = cpu.hle_body_start()
  discard cpu.set_reg(15, cpu.r[14])
  cpu.exception_return_restore()
  let charged = int(cpu.hle_body_start() - t1)
  if refill > charged: bus.add_cycles(refill - charged)
  cpu.r[15] -= 4                         # arm_software_interrupt steps past the swi
  # and the stream after it as an unparked return leaves it (hle_swi): the
  # caller's next gamepak fetch is nonsequential (cpusi4.c: 2 cycles short
  # for a cartridge caller, ARM or Thumb, at every WAITCNT, without this)
  bus.rom_hot = false
  bus.rom_next_addr = 1
  bus.rom_free_since = bus.gba.scheduler.cycles + CycleCount(bus.cycles)
  bus.bios_latch = 0xE3A02004'u32        # as every HLE return leaves it

proc copy_finish(cpu: CPU; run: CopyRun; framed: bool; tail, exit_cost, stepped: int) =
  ## The routine's end: the registers it leaves, and from a parked copy the
  ## frames' pops and the return to the caller (cpu.hle_halt_return's path).
  let bus = cpu.gba.bus
  let w = run.kind.copy_unit_bytes
  # (CpuSet's word fill pops its fill word with ldmia r0!; CpuFastSet's
  # fill reads it with a plain ldr)
  let src_end = if run.kind == ckWordFill: run.src0 + 4
                elif run.kind in {ckHalfFill, ckFastFill}: run.src0
                else: run.src0 + run.units * w
  let dst_end = run.dst0 + run.units * w
  if framed:
    # Back to the dispatcher's frame: the routine pops its own (r4-r10 for
    # CpuFastSet, r4/r5 for CpuSet come back as the caller left them)
    let base = cpu.r[13]
    let nw = run.kind.copy_frame_words
    for i in 0 ..< nw - 1:
      cpu.r[4 + i] = bus.read_word_internal(base + uint32(4 * i))
    cpu.r[13] = base + uint32(4 * nw)
  case run.kind
  of ckHalfCopy, ckHalfFill:
    # (the halfword loops index with an offset register: r0/r1 as passed)
    cpu.r[0] = run.src0
    cpu.r[1] = run.dst0
    cpu.r[3] = 0x170'u32
  of ckWordCopy, ckWordFill:
    cpu.r[0] = src_end
    cpu.r[1] = dst_end
    cpu.r[3] = 0x170'u32
  of ckFastCopy, ckFastFill:
    cpu.r[0] = src_end
    cpu.r[1] = dst_end
    # The stm bursts go through r2-r9: r3 keeps the last burst's second
    # word (tools/biosdrv/swisp2.c)
    if run.units > 0:
      cpu.r[3] = if run.kind == ckFastFill: run.fill_val
                 else: bus.read_word_internal(dst_end - 28)
  # (`stepped`: the part of tail + return the tail program ran)
  if framed:
    cpu.copy_return(if run.kind.copy_fast: 0x0C else: 0x0B, tail - stepped)
  else:
    cpu.hle_busy(max(0, tail + exit_cost - stepped))

proc copy_exec(cpu: CPU; run: var CopyRun; framed: bool; t0: int64;
               lead, tail, exit_cost: int) =
  ## Run the copy from where `run` stands: `lead` cycles of the routine
  ## before its next instruction, then unit by unit, instruction by
  ## instruction; at each boundary an interrupt due (or the frame's end)
  ## parks it (copy_park), else the end comes (copy_finish). The clock runs
  ## from `t0` (an hle_body_now).
  let bus = cpu.gba.bus
  run.tail = tail
  var steps: array[6, CopyStep]
  let w = run.kind.copy_unit_bytes
  let fast = run.kind.copy_fast
  let is_fill = run.kind in {ckHalfFill, ckWordFill, ckFastFill}
  let half = run.kind in {ckHalfCopy, ckHalfFill}
  let sp = int(bits_range(run.src0, 24, 27))
  let dp = int(bits_range(run.dst0, 24, 27))
  let nsteps = bus.copy_steps(run.kind, sp, dp, steps)
  var cont = cpu.hle_cont_start(t0, sp, dp)
  var t = lead            # the body clock from t0 at the next instruction
  template charge_to(target: int) =
    let charged = int(cpu.hle_body_now() - t0)
    if target > charged: cpu.hle_busy(target - charged)
  charge_to(t)
  while run.done < run.units:
    let src = if is_fill: run.src0 else: run.src0 + run.done * w
    let dst = run.dst0 + run.done * w
    while run.step < nsteps:
      let s = steps[run.step]
      # The step's access starts after its fetch
      let at = t + 1
      if s.act == 1:
        if fast:
          for i in 0 .. 7:
            let a = src + uint32(4 * i)
            if cont.on:
              cpu.hle_cont_ahead(cont, at + (if i == 0: 0 else: int(bus.wait32_n[sp]) +
                                 (i - 1) * int(bus.wait32_s[sp])), a, true)
            if sp == 4:
              charge_to(at + cont.extra)
              run.held[i] = bus.read_word(a)
            else:
              run.held[i] = bus.read_word_internal(a)
        else:
          if cont.on: cpu.hle_cont_ahead(cont, at, src, not half)
          if sp == 4: charge_to(at + cont.extra)
          run.held[0] =
            if half:
              (if sp == 4: uint32(uint16(bus.read_half_rotate(src)))
               else: (let h = uint32(bus.read_half_internal(src)); let r = (src and 1) * 8;
                      uint32(uint16((h shr r) or (h shl (32 - r))))))
            elif sp == 4: bus.read_word(src)
            else: bus.read_word_internal(src)
      elif s.act == 2:
        let n = if fast: 8 else: 1
        for i in 0 ..< n:
          let a = dst + uint32(4 * i)
          let v = if is_fill: run.fill_val else: run.held[i]
          if cont.on:
            cpu.hle_cont_ahead(cont, at + (if i == 0: 0 else: int(bus.wait32_n[dp]) +
                               (i - 1) * int(bus.wait32_s[dp])), a, not half)
          if dp == 4:
            # An I/O store lands a cycle ahead of the instruction's data
            # cycle: what the timed write then arms (a DMA's enable) starts
            # on the console's cycle, which the routine's next fetches would
            # otherwise grant a cycle late (alyosha timing/dma_from_bios)
            charge_to(at - 1 + cont.extra)
            if half: bus.write_half(a, uint16(v)) else: bus.write_word(a, v)
          elif half: bus.write_half_internal(a, uint16(v))
          else: bus.write_word_internal(a, v)
      t += s.cost
      inc run.step
      charge_to(t + cont.extra)
      var unit_done = false
      if run.step == nsteps:
        run.step = 0
        inc run.done
        unit_done = true
      # The boundary: an interrupt recognised by now is taken here, unless
      # it came in this store's last wait states (then after the next one)
      bus.catch_up()
      if cpu.hle_frame_ended() or
         (cpu.hle_irq_now() and not (IRQ_LAST_WAITS and s.act == 2 and s.waits > 0 and
           cpu.irq_line_at > bus.sched.cycles + CycleCount(bus.cycles) - CycleCount(s.waits))):
        cpu.copy_park(run, framed)
        return
      if unit_done: break   # the next unit's addresses
  # The tail program (copy_tail_steps), boundary by boundary; its time
  # comes out of the tail and return the finish charges
  var tsteps: array[8, int]
  let ntail = cpu.copy_tail_steps(run.kind, tsteps)
  var stepped = 0
  for k in 0 ..< ntail: stepped += tsteps[k]
  if run.step < nsteps: run.step = nsteps
  while run.step < nsteps + ntail:
    t += tsteps[run.step - nsteps]
    inc run.step
    charge_to(t + cont.extra)
    bus.catch_up()
    if cpu.hle_frame_ended() or cpu.hle_irq_now():
      cpu.copy_park(run, framed)
      return
  # (cont's renderer waits stay charged)
  cpu.copy_finish(run, framed, tail, exit_cost, stepped)

proc copy_kind(fast: bool; ctrl: uint32): CopyKind =
  let fill = bit(ctrl, 24)
  if fast: (if fill: ckFastFill else: ckFastCopy)
  elif bit(ctrl, 26): (if fill: ckWordFill else: ckWordCopy)
  else: (if fill: ckHalfFill else: ckHalfCopy)

proc copy_resume(cpu: CPU) =
  ## COPY_TRAP: the copy parked by copy_park goes on. The trap's own fetch
  ## stands for the next instruction's, whose cost already counts one.
  let bus = cpu.gba.bus
  var run: CopyRun
  let st = cpu.r[12]
  run.step = int(st and 0xF)
  run.kind = CopyKind(int((st shr 4) and 0xF) mod 6)
  run.done = st shr 8
  run.src0 = cpu.r[0]
  run.dst0 = cpu.r[1]
  run.ctrl = cpu.r[2] and 0x07FFFFFF'u32
  run.tail = int(cpu.r[2] shr 27)
  run.held[0] = cpu.r[3]
  if run.kind.copy_fast:
    for i in 1 .. 7: run.held[i] = cpu.r[3 + i]
  let raw = bits_range(run.ctrl, 0, 20)
  run.units = if run.kind.copy_fast: (raw + 7) shr 3 else: raw
  if run.kind == ckHalfFill:
    let h = uint32(bus.read_half_internal(run.src0))
    let r = (run.src0 and 1) * 8
    run.fill_val = uint32(uint16((h shr r) or (h shl (32 - r))))
  elif run.kind in {ckWordFill, ckFastFill}:
    run.fill_val = bus.read_word_internal(run.src0)
  # The trap's fetch stands for the next instruction's
  cpu.copy_exec(run, framed = true, cpu.hle_body_now(), lead = -1, tail = run.tail, exit_cost = 0)
