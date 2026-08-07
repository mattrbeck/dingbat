# SameSuite APU: state, diagnosis, and what full accuracy would cost

Score: **30/70** (div 1/5, channel_1 10/21, channel_2 10/15, channel_3 5/16,
channel_4 4/13), up from 10/70. With both blargg sound suites now green
(dmg_sound 12/12, cgb_sound 12/12) the APU tally across all three is **54/94**,
up from 29/94.

Run them with:

```
./dingbat_test <rom> --mode=mooneye --color --model=cgb --timeout=3000
```

or, for the whole suite at once alongside the two blargg sound suites:

```
./dingbat_test_runner --apu
```

which is opt-in and not part of the default gate (many of these fail, and they
would swamp `tests/results.md`).

SameSuite uses the mooneye convention (`LD B,B`, then B=3 C=5 D=8 E=13 H=21
L=34). ROMs ship in the test-ROM bundle under `same-suite/apu/`. Note its README
says some apu tests only pass on CPU CGB E, so a few may be unreachable without
per-revision boot models.

## Read the .asm, not the pixels

The single highest-leverage thing about this suite: **every test's source is in
the SameSuite repo and every one of them carries a one-paragraph comment stating
the hardware behaviour it measures, in cycles.** `channel_1_delay.asm` says "It
takes (sample length + 2) ticks from the moment channel 1 is enabled until PCM12
is affected"; `channel_1_restart.asm` says the restart delay "is actually 1 tick
shorter"; `channel_1_align_cpu.asm` says "Channel 1 is aligned to the APU's
enable time, not the CPU's start time"; `channel_1_duty_delay.asm` says
"Changing the duty becomes effective only after the current sample finishes".
Those four sentences ARE the model below. Nothing here was fitted.

To read a failure as data, dump WRAM `$c000..` after running the ROM headless
and diff it against the `CorrectResults` table, which is a plain `db` block at
the top of the `.asm` (no need to go looking for it in the ROM image). Rendering
both as `#`/`.` turns a bare FAIL into an alignment problem you can see.

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
harmless and costs `blargg/cgb_sound/08-len ctr during power`.

## The double-speed detail that governs everything

**Most of these tests run in double-speed mode** (`ld a,1 / ldh [rKEY1],a /
stop`); `channel_1_delay`, `channel_1_restart` and `channel_1_duty_delay` do
not, which is what makes them the useful cross-checks. So:

* 1 `nop` = 4 CPU cycles = **half an APU tick** in double speed, a whole one in
  single speed
* the APU tick is 4 scheduler cycles at single speed and 8 at double: the CPU
  clock doubles and the APU's does not

M-cycle component stepping already provides the resolution these tests need —
the pulse-channel failures were NOT a granularity wall.

## The pulse-channel model (resolved)

The previous version of this note proposed two fitted constants: a post-power-off
duty PHASE (from SameSuite's source commenting its duty patterns as the Pan Docs
patterns rotated left by one) and a trigger startup SUPPRESSION of "roughly 4
subtests". The open question was whether one setting of the pair satisfies more
than one test.

**Neither constant was real, and the phase one is falsified.**
`channel_1_delay` pins the duty table and the reset phase on its own: it runs at
single speed with duty 3, and its expected column is exactly Pan Docs'
`01111110` indexed from position 0. Rotating the table (or seeding the position
at 1, which is the same degree of freedom) breaks it. dingbat's table at
`channel1.nim:3` was right all along, and so was `wave_duty_position = 0` on
power-off. SameSuite's comment describes the same waveform from a different
definition of where the counter's zero sits.

What is real is four separate mechanisms, all of them documented, and **one
setting of all four satisfies nine tests per channel at once** — delay, align,
align_cpu, duty, duty_delay, restart, restart_nrx2_glitch, stop_restart and
freq_change, at single and double speed, at three frequencies, with no per-ROM
constant anywhere:

1. **The trigger is quantized to the APU's own 1 MHz tick grid**, and that grid
   is re-anchored by an APU power-ON, not by anything the CPU does. This is
   `channel_1_align_cpu` versus `channel_1_align`: nops inserted before the NR52
   power-on move the whole grid with the write and change nothing, while nops
   inserted between the power-on and the trigger move the answer by one CPU
   cycle. `GbApu.tick_phase` + `gb_pulse_trigger_deadline`.

2. **From that edge the first duty step is one full period PLUS two APU ticks**,
   or plus one tick when re-triggering a channel that is already on. Both
   numbers are quoted verbatim from `channel_1_delay.asm` and
   `channel_1_restart.asm`. Previously dingbat armed the next step one plain
   period from the write, which is early by exactly `period + 2` at single speed
   and by `period + 2` or `period + 2.5` at double, depending on the grid phase.

3. **The output sample is LATCHED at each duty step, not read from the duty
   table on demand** (`GbChannel1.sample_bit`, refreshed only in
   `ch1_catchup_slow`). This is one field that subsumes what the old note called
   "trigger startup suppression" and also fixes a test the old note never
   mentioned:
   * through the startup delay in (2) the latch still holds the pre-trigger
     sample — zero for a channel that was off — which is the pulse analogue of
     CH3's documented "triggering does not immediately start playing wave RAM",
     and is the whole of `channel_1_duty`'s residue;
   * across a restart it holds the sample the old pulse was playing, which is
     what `channel_1_restart.asm` describes in as many words;
   * across a mid-sample NR11 write it holds the OLD duty's bit, which is
     `channel_1_duty_delay` exactly — including the knife-edge case where the
     duty write lands on the same cycle as a step and the step still wins
     (apu_write catches the channel up before dispatching, so this falls out).

4. **The duty counter is clocked only while the channel is ON.** Switching a
   channel off freezes its phase where it stands; only an APU power-off resets
   it. `channel_1_stop_restart.asm`: "even after stopping the channel, the
   current sample index/phase remains unchanged. It is only reset by turning the
   APU off (NR52)." Implemented by parking `next_step` in `ch1_catchup_at` when
   `enabled` is false, and by parking all four channels on an APU power-off —
   which also fixed a plain bug, where the power-off cleared
   `wave_duty_position` but left a stale deadline armed, so the position it had
   just cleared stepped forward again on the next observation, off a period the
   register reset had already zeroed.

Per-channel result: channel_1 0/21 → 10/21, channel_2 0/15 → 10/15. In the
gbdev shootout, which drops `-cgb0B` and the three `freq_change_timing`
variants, that is 0/17 → 10/17 and 0/14 → 10/14.

### What is still failing on the pulse channels, and why

| Test (both channels) | Why it is not in the list above |
|---|---|
| `nrx2_glitch`, `nrx2_speed_change`, `volume` | The NRx2 "zombie mode" write glitch. Its own source says it "appears to be different across revisions". The DMG rule usually quoted (+1 when the old period was 0 and the envelope was still updating, ELSE +2 when the old direction was decrease) was tried: it takes `channel_1_volume` from 78/128 to 92/128 bytes but breaks two rows the current shared +1 already gets right, and passes neither version. Two revisions, not one right answer. Left alone; see the comment at `write_NRx2`. |
| `stop_div` | Length-counter clocking against DIV writes; its own comment points at `channel_3_stop_div`, which also fails. A frame-sequencer problem, not a waveform one. |
| `extra_length_clocking-cgb0B` | Named for a CPU revision. |
| `freq_change_timing-A/-cgb0BC/-cgbDE` | Three ROMs, three revisions; at most one can pass on any single model. Not in the shootout. |
| `sweep`, `sweep_restart`, `sweep_restart_2` (ch1 only) | Sweep unit, untouched by this work. |

## blargg dmg_sound: 7/12 -> 12/12

All five failures were the same missing axis: `channel3.nim` applied the **CGB**
wave-RAM rule to both models, and `apu.nim` applied one power-off/power-on rule
to both.

* **Wave RAM access (09, 12).** Pan Docs, Wave RAM: "On monochrome consoles,
  wave RAM can only be accessed on the same cycle that CH3 does. Otherwise,
  reads return $FF, and writes are ignored." `ch3_wave_open` is that window: the
  two T-cycles following a completed fetch. It needs one bit of new state
  (`wave_fetched`) because a trigger reloads the timer with `period + 6` and
  during that startup window there is no byte being read at all — without it the
  first read of blargg 09 comes back as data where hardware returns $FF, which
  was literally the only wrong byte out of 69.
* **Restart corruption (10).** Pan Docs: restarting CH3 while it is reading wave
  RAM corrupts the first four bytes — byte 0 alone if the byte being read is in
  the first four, else the aligned group of four containing it. The window for
  this is the OTHER half of the same 1 MHz sample cycle: the two T-cycles ending
  at the fetch, while it is in flight, and the byte involved is the one the
  fetch is about to latch (`wave_ram_position + 1`), not the one it last
  latched. Splitting the two halves (`ch3_wave_open` vs `ch3_wave_fetching`) is
  what makes 09/12 and 10 pass together; a single shared window passes at most
  one of them, and lands 10's corruption exactly one delay step late.
* **Power (08, 11).** Pan Docs, Power Control: the length counters are cleared
  by a power-off on CGB and are *untouched* by power on DMG, where they also
  remain writable through NRx1 while the APU is off. dingbat cleared them on
  power-ON for both models. Note the register-zeroing loop reloads each length
  counter from the now-zero NRx1, so the counters have to be lifted out of that
  loop and decided separately.

`cgb_sound` stayed 12/12 throughout, which is the point of doing this in the
same sitting as the pulse work: both touch APU power state.

## Cost

No perf cost. Retired instructions (DINGBAT_BENCH_COUNTERS, 600 frames, 90
warmup, best of 5): Pokemon Crystal **-0.105%**, Shantae **-0.035%** — slightly
*fewer*, because parking a switched-off channel's deadline skips catch-up work
that used to run. Framebuffer output is frame-identical for 600 frames on
Crystal, Silver, Shantae and Zelda LA DX.

`tests/results.md` is unchanged at 978/691. gambatte goes **3618 -> 3626/5005**
(eight `sound/ch3_*_ff30_*` DMG rows) with zero rows lost.

## Unserialized state

Three fields were added and none of them is in the save state:
`GbApu.tick_phase`, `GbChannel1/2.sample_bit`, `GbChannel3.wave_fetched`. Each
is refreshed within one duty period or one APU power cycle of a state load, none
is CPU-visible except through PCM12/PCM34, and a rollback snapshot that replays
the write that sets it reconstructs it exactly. Serializing them costs a GB
payload revision bump, which is worth spending on a batch of fields rather than
on these three; the field comments in `gb.nim` say so at each one. If a GB
payload bump happens for another reason, add them.

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

The pulse-channel work above confirms the prediction that neither was needed:
every one of those twenty rows was a phase/startup bug at a resolution M-cycle
stepping already reaches. The remaining channel_3 and channel_4 rows have not
been analysed and may not be.
