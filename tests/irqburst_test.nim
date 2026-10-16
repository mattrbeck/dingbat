## A timer interrupt raised just before a preemptible DMA burst is still
## taken (tests/roms/irqburst.s).
##
##   nimble test_irqburst
##
## The check recognising a timer interrupt can be drained inside a DMA burst
## that a higher-priority channel could preempt; check_interrupts then
## leaves the recognition to the burst's end (dma.nim run_pending). For a
## raise from before the burst that end booked nothing, so the interrupt
## sat pending with IME, CPSR.I and IE open and every later raise rode with
## it (docs/playtest-bugs.md §100, Famicom Mini Nazo no Murasamejou). The ROM
## walks a timer 0 overflow one cycle a line across an H-blank DMA3 burst
## made preemptible by an armed DMA0, and counts the interrupts it takes.
## Every overflow must be taken, each soon after it: the latency bound is
## the BIOS's dispatch plus one four-word burst, not a recorded value.

import std/[strformat, strutils]
import dingbat/gba/gba

const Rom = "tests/roms/irqburst.gba"
const Period = 1231          # the ROM's TM0 period, in cycles
const Reload = 0x10000 - Period
const Frames = 30            # 6840 overflows; every phase of the line ~5 times
const MaxLatency = 160       # cycles from overflow to the handler's TM0 read

var failures = 0

proc word(emu: GBA; a: uint32): uint32 =
  for k in 0'u32 .. 3: result = result or (uint32(emu.bus[a + k]) shl (8 * k))

proc run(label: string; waitloop: bool) =
  let emu = new_gba("", Rom, run_bios = false, use_hle = true)
  emu.post_init()
  emu.cpu.attempt_waitloop_detection = waitloop
  emu.storage.save_path = ""
  emu.step_frame()            # the ROM's setup; the timer starts in it
  let start = emu.word(0x02000000)
  let t0 = emu.rebased + int64(emu.scheduler.cycles)
  for _ in 1 .. Frames: emu.step_frame()
  let taken = int(emu.word(0x02000000) - start)
  let elapsed = emu.rebased + int64(emu.scheduler.cycles) - t0
  let overflows = int(elapsed div Period)
  let latency = int(emu.word(0x02000004)) - Reload
  var bad = false
  if abs(taken - overflows) > 1:
    bad = true
    echo &"  FAIL {label}: {taken} interrupts taken for {overflows} timer overflows"
  if latency < 0 or latency > MaxLatency:
    bad = true
    echo &"  FAIL {label}: an interrupt was taken {latency} cycles after its overflow " &
         &"(at most {MaxLatency})"
  if bad: inc failures
  else: echo &"{label}: {taken} interrupts for {overflows} overflows, the latest {latency} cycles"

run("waitloop skipping on", waitloop = true)
run("waitloop skipping off", waitloop = false)

if failures == 0: echo "EVERY TIMER INTERRUPT TAKEN AROUND THE DMA BURSTS"
else:
  echo failures, " FAILURES"
  quit(1)
