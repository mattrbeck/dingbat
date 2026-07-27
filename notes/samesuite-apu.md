# SameSuite APU: state, diagnosis, and what full accuracy would cost

Score: **10/70** (div 1/5, channel_1 0/21, channel_2 0/15, channel_3 5/16,
channel_4 4/13).

Run them with:

```
./dingbat_test <rom> --mode=mooneye --color --model=cgb --timeout=3000
```

or, for the whole suite at once alongside the two blargg sound suites:

```
./dingbat_test_runner --apu
```

which is opt-in and not part of the default gate (most of these fail, and they
would swamp `tests/results.md`). Current APU tally across all three: 29/94.

SameSuite uses the mooneye convention (`LD B,B`, then B=3 C=5 D=8 E=13 H=21
L=34). ROMs ship in the test-ROM bundle under `same-suite/apu/`. Note its README
says some apu tests only pass on CPU CGB E, so a few may be unreachable without
per-revision boot models.

## Two things this work depends on that are easy to get wrong

**FF76/FF77 must catch the channels up before reading.** The PSG channels
advance lazily — their phase is only materialized at an observation point, and
these registers *are* an observation point. Reading them without syncing first
returns the phase from whenever the channel was last touched, which is exactly
the failure mode the whole suite is built to detect. This is not defensive
coding; omit it and the tests read stale data.

**Do not reset `frame_sequencer_stage` when the APU is powered off.** Pan Docs
documents the sequencer being reset when the APU is powered *on*, and the
power-on path already does it. Adding it to the power-off path as well looks
harmless and costs `blargg/cgb_sound/08-len ctr during power`. The rest of the
power-off phase reset (both squares' duty position, the wave sample position) is
documented and is what earns the channel_3/channel_4 passes — keep that.

## How to read a failure as data

The tests sample `rPCM12`/`rPCM34` into `$c000` and compare against a
`CorrectResults` table in the ROM. Both halves are recoverable:

* dump WRAM `$c000..` after running the ROM headless
* find the table in the ROM: it is the only 128-byte window that is exclusively
  `$00`/`$08` and is followed by code. For `channel_1_duty` it sits at `0x5AB`.

Rendering both as `#`/`.` strings, one duty group per row of 32, turns a bare
FAIL into an alignment problem you can actually see.

## The double-speed detail that governs everything

**These tests run in double-speed mode** (`ld a,1 / ldh [rKEY1],a / stop`). So:

* 1 `nop` = 4 CPU cycles = **2 APU cycles**
* at NR13/NR14 = `$FF`/`$87` the frequency is `$7FF`, so the duty period is
  4 APU cycles = **2 nops per duty position**, 16 nops per full 8-step cycle

That means M-cycle component stepping already provides the resolution these
tests need — the pulse-channel failures are NOT a granularity wall.

## channel_1_duty: fully characterised

With the post-power-off phase set correctly, the captured buffer reaches
**118/128 bytes** and duty 3 matches exactly. The entire residue is the first
~4 subtests of every duty group:

```
duty0  exp ................##..............
       got ##..............##..............
duty1  exp ................####............
       got ####............####............
duty2  exp ............########........####
       got ####........########........####
duty3  exp ....############....############
       got ....############....############   <- exact
```

So two things are still wrong, and they are separable:

1. **Post-power-off duty phase.** Sweeping it 0..7, only one value reproduces
   hardware's alignment. Independent corroboration: SameSuite's own source
   comments the duty patterns as `00000010 / 00000011 / 00001111 / 11111100`,
   which are exactly the Pan Docs patterns (`00000001 / 10000001 / 10000111 /
   01111110`, what dingbat uses) **rotated left by one** — the same one-step
   offset seen from the table's side.

2. **Trigger startup suppression.** Hardware emits nothing for roughly the
   first 4 subtests (~8 APU cycles) after a trigger; we emit the waveform
   immediately. This is the analogue of the documented CH3 behaviour ("triggering
   does not immediately start playing wave RAM"), which suggests it is real, but
   the magnitude here is fitted to this one test.

**Neither is committed.** Sweeping the phase alone does not make the test pass
(verified for all 8 values) — both are needed together, and both are currently
numbers fitted to a single test rather than behaviour derived from
documentation. Two magic constants tuned against one ROM is how you pass a test
and break games. What is committed is the part that IS defensible on its own:
powering the APU off now resets the channels' internal phase, which hardware
does and which made the previously irregular, history-dependent output
repeatable in the first place.

Next step: find a second, independent test that constrains the same two
quantities (`channel_1_delay`, `channel_1_align`, `channel_1_restart` are the
obvious candidates) and check whether one setting satisfies all of them. If it
does, they are real and worth committing; if each test wants a different value,
the model is wrong at a deeper level.

## What full accuracy would cost

Measured, on an M2, best-of-9 interleaved against a control build whose
`__text` section is byte-identical to main's:

| approach | crystal | shantae | emerald (GBA) |
|---|---|---|---|
| per-cycle APU (each channel + sequencer counted down every CPU cycle) | **-24.3%** | **-20.2%** | -0.2% |

That is a **floor** — the prototype's counters reload without doing the duty
advance, LFSR shift, wave fetch or PCM update. The naive cycle-accurate
architecture costs about a fifth of GB throughput.

The cheap alternative is **on-demand catch-up**: leave the scheduler alone and
advance the APU to the exact cycle only when software observes it. This is free
in the hot path — APU reads already sit in their own `of 0xFF10..0xFF3F` /
`0xFF76` / `0xFF77` branches in `memory.nim`, so non-APU accesses pay nothing —
with cost proportional to APU register reads, which games do a handful of times
per frame. It is the pattern the GBA core already uses for the bus (`catch_up`).
The missing piece is sub-instruction cycle tracking in the GB core. Not built,
not measured — architectural reasoning only.

Given the above, the pulse-channel failures do not appear to need either: they
are phase/startup bugs at a resolution M-cycle stepping already reaches.
