# Research: dynamic waitloop tracer

**Date:** 2026-07-11
**Status:** built, verified correct, **not landed** — measured net-negative on
every ROM tested. Code parked on branch `waitloop-tracer`.

This documents the design (it is subtle), the safety argument, and the
measurements that killed it, so the next person doesn't have to rediscover
either half.

## Motivation

The static waitloop detector (`waitloop.nim`, `analyze_loop`) proves a tight
Thumb loop is an *idle* loop — read-only, no loop-carried register
dependency, no embedded PC write — so `cpu.tick` can fast-forward the
scheduler to the next event instead of spinning. It catches every game's
VCOUNT vsync poll, but only 5 of the 9 idle loops that mGBA hardcodes
per-game overrides for.

Disassembling the misses (Advance Wars 1/2, FFTA) showed why the static
scanner can never catch them. The real shape is a **multi-block main loop
closed by an unconditional branch**, with a work path and an idle path:

```
loop: ldr r0, [r4]        ; frame-ready flag, set by the vblank IRQ handler
      cmp r0, #0
      beq skip
      bl  DoFrameWork     ; writes everywhere — but only when the flag is set
skip: bl  CheckSoftReset  ; push {lr}; read KEYINPUT; pop {r0}; bx r0
      b   loop
```

Two structural problems: the closing branch is *unconditional* (the static
detector only hooks conditional backward branches), and one path through the
body writes memory, so no static analysis under a read-only invariant can
pass it. This is exactly why mGBA gave up and shipped a hand-maintained
`overrides.c` idle-loop table.

## The idea: verify the iteration that just executed

Statically unprovable, dynamically easy. When the closing branch executes,
ask: *was the iteration that just ran read-only and idempotent?*

- If yes, machine state at every scheduler event boundary is identical
  whether the loop spins N times or once — fast-forwarding to the next event
  is invisible to the guest.
- If no (a work iteration), it already executed normally; nothing to undo.
  The tracer only ever *skips* future spins, never predicts.

Because the verdict is recomputed from the actually-executed instruction
stream, there is no stale-verdict hazard for RAM-resident code and no cache
invalidation story: a work iteration simply diverges and fails verification.
Stale positives are impossible by construction.

## Mechanics

State lives on `CPU` (`wl_*` fields); ~250 lines in `waitloop.nim`; hooks in
`cpu.tick` (one `unlikely(wl_tracing)` branch per instruction),
`thumb_unconditional_branch` (candidate closing branches: backward, span ≤ 64
bytes), and `cpu.irq` (an IRQ splices foreign instructions into the stream —
cancel the trace).

1. **Arming.** On the second consecutive sighting of the same backward
   unconditional branch site, start tracing (`wl_trace_begin`).
2. **Tracing.** Each executed instruction passes through `wl_trace_step`,
   which folds its register reads/writes into the same
   read-before-write/written-later accumulator scheme the static scanner
   uses, and enforces the idempotence rules below. Any violation aborts the
   trace.
3. **Verdict.** When the same closing branch executes again with the trace
   still alive and the stack balanced (`sp` delta 0), the iteration is
   verified: set `entered_waitloop` (tick fast-forwards the scheduler), and
   record the executed (PC, opcode) sequence.
4. **Confirm mode.** Subsequent iterations don't re-derive the verdict — the
   verdict is a function of the instruction sequence alone, not the values
   loaded — so `wl_trace_step` just compares PC+opcode against the recorded
   trace (two compares per instruction). Opcodes are compared as well as PCs
   because DMA can rewrite RAM-resident loop code without redirecting the
   CPU (an IRQ writer is caught by the `irq()` cancel hook). Divergence
   (work path, exit) stops the trace; the arming heuristic re-verifies later.

### Idempotence rules (`wl_trace_step`)

- **No loop-carried register dependency**: a register read before any write
  in the iteration must never be written later — except *invariant* writes
  (literal-pool `ldr rd, [pc]`, `mov rd, #imm`, `add rd, pc/sp, #imm`,
  pops of own pushes), whose value cannot differ between iterations.
- **No memory writes except `push`**, under a stack discipline: the running
  `sp` delta must stay ≤ 0 (never pop into the caller's frame) and return to
  exactly 0 at the closing branch. Then every popped slot provably holds a
  value this same iteration pushed, so the loop rewrites identical bytes to
  its own stack frame every spin — idempotent.
- **`sp`-relative loads OK** (own frame: written this iteration; caller
  frame: invariant while the loop runs); `sp`-relative *stores* rejected
  (would need per-slot tracking), `str`/`strh`/`strb`/`stmia` rejected.
- **Control flow is observed, not predicted**: `b`/`bcond`/`bl`/`bx`/
  `mov pc` carry no data effect; the trace just follows the executed path.
  `pop {…, pc}` is rejected (control via memory — strict). `bl` marks `lr`
  written.
- **Abort on**: SWI, ARM-mode execution, IRQ entry, iteration longer than
  `WL_TRACE_MAX_INSTRS` (48).

### Failure caching

A failing instruction *inside* the loop body (`[head, site]`) permanently
classifies the site as a non-waitloop (same negative caches as the static
detector). A failure *outside* the body (in a callee, or past an exit) may
belong to the work path only, so it must not poison the site: those bump a
32-slot direct-mapped suppression table, and a site with ≥ 2 out-of-body
failures is retried only 1 in 64 sightings — alternating work/idle loops
still get detected, never-idle loops stop paying a full trace per iteration.

### Safety argument

While fast-forwarding, the loop performs no stores except rewriting identical
bytes to its own stack frame, so state at every event boundary is the same
whether it spins N times or once. Every exit condition must therefore arrive
via a scheduler event: IRQ-written RAM (the IRQ is an event), DMA-written RAM
(etDMA), KEYINPUT (input at frame boundary), VCOUNT/DISPSTAT (PPU events),
SIO (etSerial). Enumerated non-event exits are all excluded by the rules:
register iteration counters (loop-carried dep, including through callees and
push/pop), cycle counting without a counter (impossible for a verified
iteration), open-bus reads (constant within a fixed loop), RTC (needs GPIO
writes). One genuine, pre-existing gap shared with the static detector: a
loop directly polling a **free-running timer counter (TMxD)** — its value
changes between events, so a threshold poll exits up to one event-gap late.
Not observed in any tested ROM.

## Verification (all passed)

- Per-frame framebuffer hashes identical to a no-tracer build across
  Emerald, Kirby, Golden Sun, AW1, AW2, FFTA (480 frames each).
- mGBA suite byte-identical at the 6734/7218 baseline.
- Savestate roundtrip (framebuffer + full state) MATCH on AW1; transient
  tracer state is reset on state load, nothing added to the save format.

## Why it isn't landed: the measurements

The tracer *works* — counters show 1.06M fast-forwards in 720 frames on the
AW1 title and 4.3M on FFTA's. It just doesn't *pay*. Host instructions
retired (stable to ~0.1% run-to-run, unlike wall-clock fps on this machine):

| ROM (5000 frames) | no tracer | tracer | delta |
|---|---|---|---|
| Kirby (tracer ~inactive) | 137.7 B | 138.9 B | **+0.8%** |
| Advance Wars 1 | 184.1 B | 187.6 B | **+1.9%** |
| FFTA | 181.2 B | 188.4 B | **+4.0%** |

The same holds at the 720-frame title-screen window (+1.8% on AW1), and the
original prototype tree shows the same +1.7% against its own baseline — the
"+15-18% fps on AW1" from the prototype session did not survive controlled
re-measurement (it was wall-clock noise under concurrent benchmark load).

The structural reason: a fast-forward can only skip the loop iterations that
would have run **between two scheduler events**, and one full iteration still
executes (now with trace-compare overhead) per event. GBA event density is
high — the APU noise channel reschedules every 32–512 cycles, the PPU posts
several events per scanline — so the AW/FFTA main loops barely spin between
events, and the skipped work rounds to nothing while the tracer's
per-instruction compares, arming attempts, and `fast_forward` dispatches are
paid on every single event gap. Contrast the static detector's vsync polls:
those sit in multi-scanline gaps and skip thousands of iterations at a time.

## If someone picks this up again

- The win condition is **long event gaps**, not more detected loops. A
  profitable variant would fast-forward only when
  `next_event - cycles` exceeds a few iteration-lengths, and drop out of
  confirm mode entirely (tracer fully idle) when the average skipped span at
  a site is small. That turns the FFTA +4% cost into ~0 but also caps the
  upside at ~0 on the current corpus — measure before believing.
- Any future claim should be validated with `/usr/bin/time -l` instructions
  retired, serially. Wall-clock fps on this machine swings ±10% between
  back-to-back identical runs.
- The code: branch `waitloop-tracer` (one commit on top of the PPU
  priority-walk rewrite). Hash/suite/roundtrip verification as above at the
  time of parking.
