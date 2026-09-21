# Hunting a cycle: the method

How the last mGBA suite row fell (`docs/playtest-bugs.md` sections 20-26),
written as the order to do things in next time. Every item is here because
skipping it cost days.

## 0. Before touching the emulator, check what the comparison rests on

A failing row is a statement about four things: the emulator, the test
binary, the expected value, and whatever measured the expected value. Only
the first is ours, and it is the one most tempting to edit.

1. **The test binary.** Is it the binary the expected value was measured
   with? Diff it against upstream's published build, function by function
   (`tools/romdiff.py`). Identical code in a different *harness* is still a
   different test: the suite fork ran thirteen suites back to back and a
   handler one suite registered cost the next one 11 cycles per V-blank
   (section 23).
2. **The rig.** Everything sent to the console is read back, arguments as
   well as code, and every cell is asked more than once
   (`tools/hwlink/rig.py`). The one "two-valued" cell in 152 was a flipped
   bit in an unverified argument (section 26).
3. **The expected value.** It may be a number only the author's emulator
   produces. The way to know is 4.

## 1. "It needs the flashcart" is a claim; test it

The link rig runs code from IWRAM, from EWRAM, and -- with an **empty slot**
-- from the gamepak region with real wait states (section 22,
`slotexec.py`, `slotdma.py`). Twice a section closed with "needs the
flashcart" and was wrong. Before writing that sentence, ask what the
measurement actually needs: gamepak *timing* does not need a cartridge;
gamepak *contents* do.

## 2. Run the whole sentence on the console before its words

Rebuild the failing test's own sequence as a payload that fits the rig
(`breakram.s` is the suite's `DMA Prefetch Break` from RAM) and sweep ONE
parameter in one-cycle steps -- a sled of one-cycle NOPs before the sequence.
Each k is an end-to-end number; every edge in the staircase is a one-cycle
statement. A constant offset between the console's staircase and ours is a
timing fact that no term-by-term comparison will show, because every term
can match while the sum does not (section 25).

## 3. Then split it with stamps

Once the sum disagrees, make the events stamp themselves: have the DMA's own
write stop a timer, have the handler read one. A stamp splits "X is late"
into "X is late relative to Y". Both ends late by the same amount means the
anchor moved, not the ends (the H-blank flag at 1007, section 25).

## 4. A passing row is evidence about a sum

If a row passes, the terms it adds up are right *in total*. Two of them can
each be a cycle out and cancel: IRQ entry was a cycle long and a timer stop a
cycle early, and ~250 suite rows that stop a timer in a handler passed on the
sum (section 26). So:

- when a hardware-measured change breaks many passing rows by a uniform
  amount, look for the partner error in what those rows have in common
  rather than reverting;
- find the probe that separates the terms (`tmrw.s`: a stop with no handler;
  `wakeirq.s`: a handler that reads and does not stop).

## 5. Compare every column

A runner that prints two columns is making two claims. `slotdma.s` printed D
(when the DMA wrote) and T (what the CPU paid); T was compared, D was filed
under "unmodelled" for a day, and D was the answer. The table tools mark any
mismatching cell `<<<`; do not explain one away before it has its own probe.

## 6. Knobs are for locating, not for fitting

`tools/knobsweep.py` builds the core with `-d:KNOB=n` and prints which rows
and cells move. Use it to learn what a constant touches and whether the
structure is right (the answer encodes the entry delay mod the loop period).
Do not ship a value because it turns the row green: ship it when the console
measured it, and record the measurement in a table.

## 7. Record, then gate

Every law measured on the console goes into a recorded table
(`tools/hwlink/r0-agb.json`, `breakram-agb.json`) and the tables are checked
without the console by `nimble test_cyclelaws` (CI). A later change that
passes the suite by moving a recorded cell is caught there.

## Rig safety (each cost a power cycle)

- `bx pc` sits on a word boundary. Emulators forgive a misaligned one; the
  console does not come back.
- Empty-slot execution is safe only at WAITCNT 0 and 0x4000.
- A direct HALTCNT write from IWRAM does not halt; halt through SWI 2.
- Give a payload a timer watchdog; it recovers a hang, not a rewritten vector.

## Harness traps

- Never peek memory while a probe is running. A debug read moves the
  open-bus latch like any other read, and `breakram.s` is reading that latch:
  the first draft of `tests/cyclelaws_test.nim` polled for the finish marker
  every frame and got 60 wrong cells from a core that gets all of them right.
- Count cycles from the listing, not the source: the assembler turns
  `ldr r0, =0x00800000` into a one-cycle `mov`.
- A long NOP sled pushes the literal pool out of range; `.ltorg` before it.

## The probe kit

`tests/roms/payloads/probe.inc` has the pieces every probe re-grew: the
halted, interrupt-anchored entry; the one-cycle NOP sled; timer stamps; a DMA
that stamps itself. `kitdemo.s` is the template -- `dmaphase.s`'s multiply and
NOP runs in twenty lines of macros, recorded on the console like any other
page (12 cells, all dingbat's). Copy it.

## The tools, in the order above

| step | tool |
|---|---|
| is the test binary theirs? | `tools/romdiff.py ours.elf ours.gba theirs.gba` |
| ask the console, repeatedly | `tools/hwlink/rig.py` (under `r0table.py`, `breakram.py`, `payloadcmp.py`) |
| a new probe | `tests/roms/payloads/probe.inc`, `kitdemo.s` |
| what does this constant touch? | `tools/knobsweep.py KNOB=a,b [--suite] [--grid]` |
| record a law | `tools/hwlink/r0table.py --record <payload>` |
| freeze the tables for CI | `tools/hwlink/lawrom.py` -> `tests/roms/cyclelaws/` |
| hold the core to them | `nimble test_cyclelaws` |
