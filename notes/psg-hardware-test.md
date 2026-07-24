# Validating the PSG against real hardware

Two GB/GBA sound behaviours in dingbat currently rest on argument rather than
measurement. Both are testable on real hardware with a flash cart. This note
records what to test, how, and what each result would mean.

## Open question 1 — the wave-channel trigger delay (magnitude)

`common/psg_envelope.nim` restarts channel 3's frequency timer at
`period + PSG_WAVE_TRIGGER_DELAY`, where the delay is 6 CPU cycles on the GB.
That 6 is inherited emulator lore: it is **not** in GBATEK, **not** in Pan Docs,
and predates dingbat's git history. What Pan Docs *does* establish is that some
startup delay is real — triggering CH3 doesn't immediately play wave RAM, and
the first sample read is index 1 rather than 0.

### How to measure it (CGB, cheapest and most precise)

The CGB exposes **PCM34 at $FF77** (read-only, undocumented but well known):
low nibble = channel 3's current PCM amplitude. This is exactly how LIJI32's
SameSuite observes wave-channel timing from the CPU — see
`apu/channel_3/channel_3_freq_change_delay.asm`, which reads `rPCM34` at swept
cycle offsets to find where a behaviour boundary lands.

Procedure:

1. Fill wave RAM with a ramp so every sample index is distinguishable
   (`$01 $23 $45 ...` gives sample *i* the value *i*).
2. Pick a slow period so single-cycle resolution is easy to read
   (small `n` in NR33/NR34 → long `(2048-n)*2` T-cycle sample period).
3. Enable the DAC (NR30 = $80), set volume to 100% (NR32 = $20).
4. Trigger (NR34 bit 7), then execute exactly *N* `nop`s, then `ld a, [$FF77]`.
5. Sweep *N* over a range covering the expected delay and record the amplitude
   for each. The *N* at which the value first changes from the pre-trigger
   sample to sample index 1 is the trigger→first-fetch delay in T-cycles.
6. Run the identical ROM under dingbat (`--mode=sram`, dumping results to cart
   RAM) and diff the two tables.

A table that matches with the constant at 6 confirms the inherited value; a
consistent offset tells you the correct one directly.

### Cheaper first step — run the suites that already exist

Before writing anything, run these on hardware and on dingbat and diff:

* **SameSuite** `apu/channel_3/*` (hardware-verified against a real CGB)
* **blargg** `dmg_sound` / `cgb_sound`

Both are already downloaded into the test ROM cache. Note two gaps on our side:
`dingbat_test_runner` does **not** run either sound suite (only `cpu_instrs`,
`instr_timing`, `mem_timing`), and while `dmg_sound` 01-04 pass via
`--mode=sram --model=dmg`, subtests 05-12 and all of `cgb_sound` never report a
result under our harness. Worth fixing regardless of the hardware work — that is
free coverage we already have on disk.

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

## Why question 1 can't be measured directly on a GBA

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
