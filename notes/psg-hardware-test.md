# Validating the PSG against real hardware

Two GB/GBA sound behaviours rested on argument rather than measurement. One is
now settled in software (see below) by implementing PCM12/PCM34 and running
SameSuite; the other still wants a flash cart. This note records what was
measured, and what is left to test on hardware.

Also recorded here: SameSuite APU is now a usable oracle for dingbat, and it
says the GB APU has a lot of headroom — 8/70 as of this writing.

## RESOLVED — the wave-channel trigger delay is 5-6 T-cycles

Originally open, now settled *without* hardware. SameSuite's apu tests observe
the channels through the CGB's **PCM12/PCM34** registers ($FF76/$FF77, read-only
mirrors of each channel's current 4-bit digital output). dingbat stubbed both to
`0x00`, so every PCM-based test failed at the observation layer and told us
nothing. Implementing them turned the suite into a working oracle.

Sweeping `PSG_WAVE_TRIGGER_DELAY` against the two tests that pin it down:

| delay | channel_3_restart_delay | channel_3_shift_delay |
|-------|-------------------------|-----------------------|
| 3     | FAIL                    | FAIL                  |
| 4     | FAIL                    | FAIL                  |
| 5     | **PASS**                | **PASS**              |
| 6     | **PASS**                | **PASS**              |
| 7     | FAIL                    | FAIL                  |
| 8     | FAIL                    | FAIL                  |
| 9     | FAIL                    | FAIL                  |
| 12    | FAIL                    | FAIL                  |

SameSuite is validated against real CGB hardware, so this is hardware evidence at
one remove: the delay is real, and 5-6 T-cycles. The tests can't separate 5 from
6; dingbat uses 6. That also retroactively justifies scaling it x4 for the GBA —
it is a genuine physical delay, not a fudge, so it must be expressed in each
core's cycle units.

No flash cart needed for this one after all.

## Open question 2 — GBA wave RAM bank selection (suspected bug, NOT yet fixed)

GBATEK, on the GBA's 2x32-sample wave RAM at `4000090h-400009Fh`:

> "The currently selected Bank Number (Bit 6) will be played back, while
> reading/writing to/from wave RAM will address the other (not selected) bank."

dingbat's `gba/apu/channel3.nim` plays `wave_ram_bank` (correct) but *also* has
the CPU read and write `wave_ram_bank` — it should be the opposite bank. It
additionally applies the GB's "reading while enabled returns the byte at the
current play position" aliasing, which on the GBA should not arise at all, since
the CPU is on a different bank from the one playing.

The suspected fix is to index the CPU side with `ch.wave_ram_bank xor 1` and
drop the enabled-aliasing branch. It is left unapplied deliberately: it changes
audio behaviour for any game using the dual-bank feature, and nothing in our
automated suite covers it.

### How to test it (GBA, directly CPU-observable — no audio analysis needed)

This one needs no amplitude readback, so it is much easier than question 1:

1. Set `SOUND3CNT_L` bit 6 = 0 (play bank 0), write a recognisable pattern to
   `4000090h..400009Fh`.
2. Flip bit 6 to 1 (play bank 1), write a *different* pattern.
3. Flip back to 0 and read `4000090h..400009Fh`.
4. If the bytes are the ones written in step 2, GBATEK is right and dingbat is
   wrong. If they're from step 1, dingbat's current behaviour is right.

Do this with the channel both enabled and disabled — the enabled case also
settles whether the GB's play-position aliasing applies on GBA.

## Why the delay can't be measured directly on a GBA

The GBA has **no** equivalent of PCM12/PCM34 — GBATEK documents no register
exposing PSG output amplitude, and those two are CGB-only. Combined with the
bank behaviour above (the CPU sees the bank that *isn't* playing), there is no
CPU-visible probe of the wave channel's phase in GBA native mode. The
sub-microsecond difference at stake (18 GBA cycles ≈ 1.07 µs) is also too fine
to pull out of a headphone-jack recording reliably.

That is fine, because the delay is a property of the shared PSG block: measure
it on a CGB, where PCM34 makes it directly observable, then express the result
in each core's cycle units. GBATEK's identical sample-rate formula
(`2097152/(2048-n) Hz` on both) is what licenses carrying the number across.

A GBA/GBA SP running a `.gbc` on the flash cart exercises the CGB core, not the
GBA's native sound path, so it validates the PSG value but not the GBA wiring.

## Current SameSuite APU standing (GB core)

Implementing PCM12/PCM34 took the suite from 3/70 to 8/70 — the gain is small
but the point is that the remaining 62 failures are now *real* results about the
APU rather than artefacts of a missing observation register.

```
                              before   after
SameSuite apu (70 tests)       3        8
  channel_1 (21)               0        0
  channel_2 (16)               0        0
  channel_3 (16)               3        5
  channel_4 (11)               0        0
  div_* (5)                    0        0
```

These are demanding tests — they check APU behaviour at single-T-cycle
resolution and alignment against DIV, which dingbat's event-scheduler APU does
not currently model. Treat 8/70 as a baseline to improve against, not as a
regression. `channel_3_restart_delay` and `channel_3_shift_delay` are the two
that pinned down the trigger delay above.

To run them:

```
./dingbat_test <rom> --mode=mooneye --color --model=cgb --timeout=3000
```

SameSuite uses the mooneye convention (`LD B,B` then B=3 C=5 D=8 E=13 H=21 L=34).
The ROMs ship in the test-ROM bundle under `same-suite/apu/`. Note that some of
them only pass on CPU CGB E per SameSuite's own README, so a handful may be
unreachable without per-revision boot models.

## Other suites not currently wired into the runner

`dingbat_test_runner` builds tests only for blargg `cpu_instrs`, `instr_timing`
and `mem_timing`. Also sitting unused in the bundle:

* `blargg/dmg_sound`, `blargg/cgb_sound` — run with
  `--mode=sram --model=dmg`. dmg_sound 01-registers, 02-len ctr, 03-trigger and
  04-sweep all pass. Subtests 05-12, and all of cgb_sound, never write their
  result under our harness (they neither pass nor report a failure) — cause not
  yet diagnosed.
* `same-suite/` beyond apu — dma, ppu, interrupt, sgb.
