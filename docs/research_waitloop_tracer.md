# Research: dynamic waitloop tracer (not landed)

Built and verified on branch `waitloop-tracer`; measured net-negative on
every ROM tested, so it is not on `main`. This records the design and the
reason, so it is not rebuilt blind.

## The loops the static detector cannot catch

`waitloop.nim` (`analyze_loop`) proves a tight Thumb loop idle — read-only,
no loop-carried register dependency, no PC write — and `cpu.tick`
fast-forwards the scheduler to the next event. It catches every VCOUNT vsync
poll. Disassembly of Advance Wars 1/2 and FFTA shows the main loop they idle
in is a multi-block loop closed by an **unconditional** branch, with a work
path that writes memory:

```
loop: ldr r0, [r4]        ; frame-ready flag set by the vblank handler
      cmp r0, #0
      beq skip
      bl  DoFrameWork     ; writes everywhere, only when the flag is set
skip: bl  CheckSoftReset  ; push {lr}; read KEYINPUT; pop {r0}; bx r0
      b   loop
```

No static analysis under a read-only invariant can pass that.

## The design: verify the iteration that just ran

At the closing branch, ask whether the iteration that just executed was
read-only and idempotent. If yes, state at every event boundary is identical
whether the loop spins N times or once, so fast-forwarding is invisible. If
no, it already ran; nothing to undo. The tracer only skips *future* spins,
so stale positives are impossible for RAM-resident code.

* Arm on the second sighting of the same backward unconditional branch
  (span ≤ 64 bytes); trace each instruction through the static scanner's
  read-before-write accumulator plus idempotence rules; verdict when the
  same branch executes with `sp` delta 0; then **confirm mode** compares
  PC+opcode against the recorded sequence (two compares per instruction —
  opcodes too, because DMA can rewrite RAM-resident code). An IRQ cancels the
  trace.
* Rules: no loop-carried register dependency except invariant writes
  (literal-pool `ldr`, `mov #imm`, `add rd, pc/sp, #imm`, pops of own pushes);
  no memory writes except `push` under a stack discipline (running `sp`
  delta ≤ 0, exactly 0 at the branch), so every pop reloads a value this
  iteration pushed; `sp`-relative loads OK, stores rejected; `pop {…, pc}`
  rejected; abort on SWI, ARM mode, IRQ entry, > 48 instructions.
* Failure caching: a failing instruction inside `[head, site]` classifies the
  site permanently; a failure in a callee or past an exit bumps a 32-slot
  suppression table (retry 1 in 64 after two), so alternating work/idle loops
  still get found.
* Safety: every exit condition of a verified loop must arrive via a scheduler
  event (IRQ, DMA, keypad at frame boundary, PPU, SIO). One shared gap with
  the static detector: a loop polling a free-running timer counter exits up
  to one event-gap late. Not seen in any tested ROM.

Verified: per-frame framebuffer hashes identical on six games (480 frames),
mGBA suite byte-identical, save-state round trip clean (tracer state is
transient, nothing serialized).

## Why it does not pay

Retired instructions over 5000 frames: Kirby +0.8 % (tracer ~inactive),
Advance Wars 1 +1.9 %, FFTA +4.0 %. A fast-forward can only skip the
iterations between two scheduler events, and one full iteration still runs
(with compare overhead) per event. GBA event density is high — the noise
channel reschedules every 32–512 cycles, the PPU posts several events per
scanline — so these loops barely spin between events, while the static
detector's vsync polls sit in multi-scanline gaps and skip thousands of
iterations. The earlier "+15–18 % fps" was wall-clock noise.

A profitable variant would fast-forward only when `next_event − cycles`
exceeds a few iteration lengths and drop out of confirm mode when the
average skipped span at a site is small — which caps the upside at ~0 on the
current corpus. Validate any claim with retired instructions, serially.
