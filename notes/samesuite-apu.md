# SameSuite APU: what its sources assert, and where dingbat stands

Score: **57/70** (div 5/5, channel_1 15/21, channel_2 15/15, channel_3 15/16,
channel_4 7/13), up from 10/70. With both blargg sound suites green (dmg_sound
12/12, cgb_sound 12/12) the APU tally across all three is **81/94**, up from
29/94.

The nine per-revision ROMs are now scored on the revision their filename names
(`--model=cgb0B` and friends), not on the default; see
`docs/gb-hardware-revisions.md`.

Run them with:

```
./dingbat_test <rom> --mode=mooneye --color --model=cgb --timeout=3000
```

or, for the whole suite at once alongside the two blargg sound suites:

```
./dingbat_test_runner --apu
```

which is opt-in and not part of the default gate. SameSuite uses the mooneye
convention (`LD B,B`, then B=3 C=5 D=8 E=13 H=21 L=34). ROMs ship in the
test-ROM bundle under `same-suite/apu/`.

## The method: read the .asm, not the pixels

**Every SameSuite APU test carries a comment at the top of its source stating
the hardware behaviour it measures, in cycles.** Those sentences are the whole
of the model below; nothing here was fitted to a reference image. Two rounds of
this work produced the same lesson twice, so it is worth stating plainly:
sweeping a constant until a ROM goes green is slower AND wronger than reading
the paragraph the ROM's author wrote about what he measured.

Sources are not in the ROM bundle — they are upstream:

* **`github.com/LIJI32/SameSuite`, pinned at `f15645fb049a47ea235f6d2c9a033e72d8087901`**
  (master, 2025-10-11). `apu/<channel>/<test>.asm`; `include/common.inc` has the
  `nops` macro (a `call` into a nop slide, exact to the M-cycle).
* gambatte's ROMs have sources too, in
  `github.com/pokemon-speedrunning/gambatte-core`, `test/hwtests/`. Its
  `.text@<addr>` directives are how it lands a write on an exact cycle; reading
  them is the only way to know what a `_1a`/`_1b` pair is bracketing.

**A header is strong evidence, not proof.** `channel_4_align.asm` says "channel
1", `channel_4_volume_div.asm` says "NR12", and `channel_1_stop_div.asm` says
"Channel 1 behave similarly to channel 3" in the channel_2 copy too. The rule
that survives: derive a constant from one test, then check it against a test it
was NOT derived from. Every number below has been through that.

To read a failure as data, dump WRAM from `RESULTS_START` (it is `$c000` in most
tests but `$c006` in `channel_4_lfsr_restart`) after running the ROM headless,
and diff it against the `CorrectResults` table, which is a plain `db` block at
the top of the `.asm`. Rendering both as `#`/`.` turns a bare FAIL into an
alignment problem you can see.

## Two things this work depends on that are easy to get wrong

**FF76/FF77 must catch the channels up before reading.** The PSG channels
advance lazily — their phase is only materialized at an observation point, and
these registers *are* an observation point. Reading them without syncing first
returns the phase from whenever the channel was last touched, which is exactly
the failure mode the whole suite is built to detect.

**Do not reset `frame_sequencer_stage` when the APU is powered off.** Pan Docs
documents the sequencer being reset when the APU is powered *on*, and the
power-on path already does it. Adding it to the power-off path as well looks
harmless and costs `blargg/cgb_sound/08-len ctr during power`.

## The double-speed detail that governs everything

Most of these tests run in double-speed mode (`ld a,1 / ldh [rKEY1],a / stop`);
`channel_1_delay`, `channel_1_restart`, `channel_1_duty_delay`,
`channel_4_delay`, `channel_4_frequency_alignment` and the whole `div` family do
not, which is what makes them the useful cross-checks. So:

* 1 `nop` = 4 CPU cycles = **half an APU tick** in double speed, a whole one in
  single speed
* the APU tick is 4 scheduler cycles at single speed and 8 at double: the CPU
  clock doubles and the APU's does not
* `nops N` is exactly N M-cycles (the `call`+`ret` around the slide are counted)

M-cycle component stepping already provides the resolution these tests need —
none of the failures below was a granularity wall.

---

# The catalogue

What each source asserts, whether dingbat matches, and where the code is. Rows
are shootout rows (SameSuite APU contributes 61). Sorted by channel.

## Pulse channels (channel_1 17 rows, channel_2 14 rows) — 12/17 and 12/14

| source | assertion | dingbat |
|---|---|---|
| `channel_1_align_cpu` | "Channel 1 is aligned to the APU's **enable** time, not the CPU's start time" | **matches** — `GbApu.tick_phase` is set by the NR52 power-on and `gb_trigger_deadline` rounds the trigger up to that grid |
| `channel_1_align` | "verifies that channel 1 ticks at 1MHz" | **matches** — `gb_apu_tick` |
| `channel_1_delay` | "It takes (sample length + 2) ticks from the moment channel 1 is enabled until PCM12 is affected. (The read operation itself takes 2 cycles)" | **matches** — `gb_trigger_deadline(..., 2)`. Also pins the duty TABLE: single speed, duty 3, and the expected column is Pan Docs' `01111110` indexed from position 0 |
| `channel_1_restart` | "after restarting, the start delay from the 'delay' test is actually 1 tick shorter. The countdown for the next sample is reset, but the new pulse's first sample will be the next sample the old pulse would have played" | **matches** — `extra_ticks = 1` when the channel was already on; the position is untouched |
| `channel_1_duty` | lists the duty patterns as `00000010 / 00000011 / 00001111 / 11111100` | **matches in substance.** These are the Pan Docs patterns rotated left by one, i.e. a different definition of where the counter's zero sits. A previous round proposed rotating dingbat's table or seeding the position at 1; `channel_1_delay` **falsifies both**. Do not rotate the table |
| `channel_1_duty_delay` | "Changing the duty becomes effective only after the current sample finishes" | **matches** — `GbChannel1.sample_bit` latches the duty bit once per step |
| `channel_1_freq_change` | "Changing channel 1's frequency takes effect after the current sample finishes" | **matches** — `next_step` is absolute, so a period change cannot move a pending step |
| `channel_1_stop_restart` | "even after stopping the channel, the current sample index/phase remains unchanged. It is only reset by turning the APU off (NR52)" | **matches** — `ch1_catchup_at` parks `next_step` while `enabled` is false |
| `channel_1_volume_div` | "The volume envelope is triggered by the DIV register after it ticks the APU (8 * (NR12 & 7)) times (at 512Hz)" | **matches** |
| `channel_1_nrx2_speed_change` | "the envelope speed can be changed while it's active, and the change takes effect after the next time it ticks. Enabling and disabling the envelope takes effect instantly. Enabling the envelope trigger an APU bug - in the next *even* DIV-APU tick, the APU will tick the volume envelope of that apropriate channel, even if it would not tick volume envelope at that tick otherwise" | **matches** — the first two sentences were already right; the glitch is `GbVolumeEnvChannel.env_extra_tick`. "Even DIV-APU tick" is dingbat's ODD `frame_sequencer_stage`: hardware's counter increments before the step, so its tick 2 is dingbat's step 1. Fitting the parity the other way passes tests 3/4/5 but fails 6/7, which is why those two exist |
| `channel_1_restart_nrx2_glitch` | "restarting the channel after triggering the NRx2 write glitch works as expected" | **matches** |
| `channel_1_nrx2_glitch` | "This tests the NRx2 write glitch ('Zombie Mode'). **It appears to be different across revisions**" | **matches**, 16/16 bytes. See below |
| `channel_1_volume` | "Attempts to change the volume of channel 1 without triggering the NRx2 write glitch" | **matches**, 128/128 bytes. Same mechanism |
| `channel_1_stop_div` | "Channel 1 behave similarly to channel 3, but with a smaller length range. See channel_3_stop_div" | **matches**, and it came free with the DIV-APU work |
| `channel_1_sweep` | *(no header)* | **does not match**, 136/144 bytes: one 16-byte window where the channel should already be silent. Nothing in the source says why |
| `channel_1_sweep_restart`, `_2` | "Several tests involving restarting the channel while sweep is active" / "Part 2" | **does not match** (85/144, 95/128). No cycle-level assertion to derive from |
| `channel_1_extra_length_clocking-cgb0B` | quotes the extra-length-clocking rule in full, then: "On revisions <= CPU CGB B, the length counter only has to have been disabled before; the current length enable state doesn't matter… fixed on CPU CGB C" | **matches on `--model=cgb0B`** (`GbQuirks.length_clock_any_nrx4`), and correctly does NOT on the default. Not a shootout row |
| `channel_1_freq_change_timing-A/-cgb0BC/-cgbDE` | *(no header; three ROMs, three CPU revisions)* | at most one can pass on any single model. Not shootout rows |

### On "Zombie Mode" — it was never revision-dependent, and it is now fixed

Two rounds parked these 4 rows behind `channel_1_nrx2_glitch`'s "appears to be
different across revisions". That sentence is true and it is not an excuse:
`apu/README.md`'s To Do says **"Currently, only revision E is tested and
documented"**, and its Results say CPU-CGB-E passes everything. One ROM, one
answer, and it is the answer for the revision dingbat is scored against
everywhere else.

The rule quoted from Pan Docs (+1 when the old period was zero and the envelope
was still updating, ELSE +2 when the old direction was decrease) is **one
column of a three-column table**, and the column is selected by the value being
WRITTEN. Solving `channel_1_volume`'s 128-byte `CorrectResults` for the
increment applied before the direction flip:

|  | new dec, per 0 | new dec, per != 0 | new inc |
|---|---|---|---|
| old per 0, dec  | 0 | −1 | +1 |
| old per!=0, dec | 0 |  0 | +2 |
| old per 0, inc  | 0 | +1 | +1 |
| old per!=0, inc | 0 |  0 |  0 |

The Pan Docs rule is the right-hand column; the old `+1` in both cases was a
third variant. `channel_1_nrx2_glitch` is the cross-check, not a second fit —
its write lands 1024 M-cycles after the trigger instead of 2 and its old
periods are 2 and 7 — and all 16 of its bytes fall out of the same table.
**144/144 bytes on both ROMs, both pulse channels; 4 shootout rows.** The table
is in the comment at `write_NRx2`.

## Channel 3 (13 shootout rows) — 12/13, and 15/16 of the full suite

| source | assertion | dingbat |
|---|---|---|
| `channel_3_delay` | "It takes (wavelength / 32) (i.e sample length) + 3 ticks from the moment channel 3 is enabled until PCM34 is affected. (The read operation itself takes 2 cycles)" | **matches** — the `+6` T-cycles at the trigger is exactly `sample length + 3 M-cycles` in the same accounting `channel_1_delay` spells out |
| `channel_3_first_sample` | "When channel 3 starts, it skips the very first wave sample and starts with the second (after the sample-long delay)… the delay is actually just one tick, but the output updates only after a first 'phantom' sample is played" | **matches** — the trigger sets `wave_ram_position = 0` and the first step advances to 1, i.e. the LOW nibble of byte 0 |
| `channel_3_restart_delay` | "Restarting channel 3 in the middle of a sample takes effect after the same delay calculation as in channel_3_delay. The previous sample remains playing until the first 'phantom' sample finishes" | **matches** — and note this is the test that says a plain trigger does NOT clear the sample buffer |
| `channel_3_restart_stop_delay` | "starting a pulse after stopping a previous one behaves the same as just starting a pulse" | **matches, after a fix.** Read together with `restart_delay` this is a proof: the only difference between the two is the NR30 stop, so **turning the DAC off is what clears the sample buffer**. `ch3_write`, NR30 arm |
| `channel_3_freq_change_delay` | "Modifying the wave length while the channel is playing will take effect only for the next sample" | **matches** |
| `channel_3_shift_delay` | "Modifying the channel 3 shift while the channel is playing affects PCM34 instantly, or at most after 2 ticks" | **matches** — the shift is applied at read time |
| `channel_3_shift_skip_delay` | "the delay cannot be skipped or shortened by modifying the shift value" | **matches** |
| `channel_3_stop_delay` | "Stopping channel 3 manually using the NR30 register affects PCM34 instantly" | **matches** |
| `channel_3_stop_div` | "Channel 3's stop timer is ticked by the DIV register at 512Hz. The sound stops instantly in the same cycle DIV's bit 5 turns from 1 to 0 (or bit 4 in single speed mode). The length of the sound is ((255 - NR31) * 2 + 1) DIV-APU ticks" | **matches**, once the DIV-APU work below landed |
| `channel_3_wave_ram_locked_write` | "The byte is written at the offset CH3 is currently reading. Except on AGB, where the write is simply ignored" | **matches** on CGB; the AGB case is not modelled and no row asks for it |
| `channel_3_wave_ram_sync` | "the value read from PCM34 and value read from the wave RAM are synced" | **matches** |
| `channel_3_and_glitch` | "Channel 3 is not affected by the PCM34 AND glitch in neither single not double speed mode" | **matches** — dingbat has no AND glitch to be affected by. Worth recording that a *pass* here is the absence of a behaviour, so it will silently start failing if anyone adds one |
| `channel_3_wave_ram_dac_on_rw` | "reading and writing to wave RAM while CH3's DAC is active but the channel is inactive" | **matches**. Not a shootout row |
| `channel_3_extra_length_clocking-cgb0/-cgbB` | as the pulse version, plus "On CPU CGB, CH3 requires ONE write to disable the channel when the length counter is 1. On CPU CGB B, CH3 requires TWO" | `-cgb0` **matches on `--model=cgb0`**. `-cgbB` still red: its two tables differ by exactly one write per row, but the header states the observable and not the mechanism, and two mechanisms fit it identically — see `docs/gb-hardware-revisions.md` §3.2. Neither is a shootout row |

**The one line that fixed seven of these** is not from SameSuite at all — it is
Pan Docs, Power Control, on what a power-ON resets: "the frame sequencer is
reset so that the next step will be 0, the square duty units are reset to the
first step of the waveform, **and the wave channel's sample buffer is reset to
0**". Without it, every CH3 subtest after the first read the PREVIOUS subtest's
wave byte out of PCM34 for the whole of the startup delay, which looked like a
delay bug and was not.

## Channel 4 (12 shootout rows) — 6/12

| source | assertion | dingbat |
|---|---|---|
| `channel_4_lfsr` / `_lfsr15` | "verifies the LFSR algorithm used is correct" | **matches.** dingbat's register is the BIT-COMPLEMENT of the usual convention: `lfsr = 0x7FFF` at trigger with `output = not bit0` is the same machine as `lfsr = 0` with `output = bit0`. **`channel_4_lfsr_restart`'s "the contents of the LFSR register are cleared on restart" is therefore already satisfied — setting it to 0 would break three passing rows.** This trap is why the sentence is worth writing down |
| `channel_4_lfsr_15_7` / `_7_15` | "the contents of the LFSR are retained correctly when switching" | **matches** — dingbat never truncates the upper bits |
| `channel_4_volume_div` | as the pulse version | **matches** |
| `channel_4_align` | "verifies that channel 1 [sic — it means 4] ticks at 1MHz" | **matches, after a fix** — CH4's trigger now goes through the same `gb_trigger_deadline` grid alignment as the squares |
| `channel_4_delay` | "**the delay is `sample length + 3` M-cycles, but it might be one M-cycle more or less**… I'm not completely sure about this logic yet. It appears to be related to how the noise frequency is made out of two different values" | **partly.** The `+3 M-cycles` minus the 2-cycle read gives `extra_ticks = 1`, which is now implemented and which is what earned `channel_4_align` and `channel_4_lfsr_7_15`. The test itself still fails on the "one M-cycle more or less" half |
| `channel_4_frequency_alignment` | *(no prose; the assertion is the annotation on its expected table)* | **does not match.** See below |
| `channel_4_equivalent_frequencies` | "identical frequencies that are expressed differently generate the same output, other than a potential off-by-one sample caused by the start delay" | **does not match** — same root cause |
| `channel_4_lfsr_restart` / `_restart_fast` | "the contents of the LFSR register are cleared on restart / even on a fast restart" | **does not match**, but NOT for the reason the header suggests: the whole result table is dingbat's own output shifted by exactly one subtest = one LFSR step = 2 M-cycles. It wants a trigger delay 2 M-cycles longer than `channel_4_delay` and `channel_4_align` allow (a sweep of the delay over {0,1,2,3} × {M-cycles, ticks} × {aligned, not} confirms no single value satisfies both, and +2 costs `lfsr`, `lfsr15` and `lfsr_15_7`) |
| `channel_4_freq_change` | "what happens when changing the frequency of channel 4 while it's playing. **Unfortunately the logic behind it is still unclear**" | written off by its own author |
| `channel_4_extra_length_clocking-cgb0B` | per-revision | not a shootout row |

### The divisor/shift split — diagnosed, not fixed

`ch4_frequency_timer` collapses NR43's two fields into one scalar:

```nim
(if ch.divisor_code == 0: 8'u32 else: uint32(ch.divisor_code) shl 4) shl ch.clock_shift
```

so `$09` (divisor 1, shift 0) and `$18` (divisor 0, shift 1) are literally the
same number. `channel_4_frequency_alignment` annotates its expected table with
which encodings are "affected" and which are "not affected", and **the split is
exactly `divisor_code == 0`**:

```
$09 affected     $0a affected     $0b affected     $0c affected     $29 affected     $1a affected
$18 NOT          $28 NOT          $38 NOT
```

which is a finding beyond the annotation itself: it is the divisor field, not
the shift field, that decides. That fits the "made out of two different values"
remark — divisor code 0 means 8 rather than 16, i.e. a half-unit tap on the
first divider stage.

It is **not** a constant offset, which was checked before giving up: at the same
period, `$18` fires one M-cycle EARLIER than `$09`, while `$28` fires one
M-cycle LATER than `$0a`. Modelling it needs the divisor and the shift as two
real cascaded counters with independent phases, which is a rewrite of
`ch4_frequency_timer` and its catch-up. **4 rows** (`frequency_alignment`,
`equivalent_frequencies`, `delay`, `freq_change`) are parked behind it, and
`freq_change` may be unreachable regardless.

## The DIV-APU family (5 shootout rows) — 5/5

One mechanism, exactly as suspected. All five were red; all five are green.

| source | assertion | dingbat |
|---|---|---|
| `div_write_trigger` | "writing to DIV while bit 4 is set triggers a DIV-APU event" | **the event was already there** (`timer.nim`, DIV write). What was missing is that a power-on must also settle `first_half_of_length_period` — leaving it stale from before the power-off made every NRx4 write after a power-on do an extra length clock it should not have |
| `div_write_trigger_10` | "starting the APU while bit 4 of the DIV register is set causes the APU to **skip the first DIV-APU event**" | **matches, after a fix** — `GbApu.div_skip` |
| `div_write_trigger_volume`, `_volume_10`, `div_trigger_volume_10` | *(no headers)* | **match**, and they are what pins the skip's exact shape |

### What "skip the first DIV-APU event" turned out to mean

Three readings were tried against the five tests at once, and only one survives:

* **not** "the sequencer starts at step 1" — that puts the envelope's first tick
  on the seventh event; `div_write_trigger_volume_10` and `div_trigger_volume_10`
  both want the ninth
* **not** "the event runs but does nothing" with everything else unchanged —
  that gets the envelope right and then fails `div_write_trigger_10`'s length
  column, where a length-1 channel must survive all 15 events
* **yes**: the event performs nothing and the sequencer does not advance, AND
  the extra-length-clocking gate reads as "the next step does not clock length"
  for as long as the skip is pending

The third is the one with a physical story: `first_half_of_length_period` is a
property of the **divider**, not of `frame_sequencer_stage`, and a skip is
exactly the state in which the two disagree. That is now what the field's
comment in `gb.nim` says. `div_write_trigger` and `div_write_trigger_volume`
were not used to derive it and both pass.

---

## blargg dmg_sound: 7/12 -> 12/12

All five failures were the same missing axis: `channel3.nim` applied the **CGB**
wave-RAM rule to both models, and `apu.nim` applied one power rule to both.

* **Wave RAM access (09, 12).** Pan Docs, Wave RAM: "On monochrome consoles,
  wave RAM can only be accessed on the same cycle that CH3 does. Otherwise,
  reads return $FF, and writes are ignored." `ch3_wave_open` is that window: the
  two T-cycles following a completed fetch. It needs one bit of state
  (`wave_fetched`) because a trigger reloads the timer with `period + 6` and
  during that startup window there is no byte being read at all.
* **Restart corruption (10).** Pan Docs: restarting CH3 while it is reading wave
  RAM corrupts the first four bytes. The window for this is the OTHER half of
  the same 1 MHz sample cycle — the two T-cycles ending at the fetch — and the
  byte involved is the one the fetch is about to latch. A single shared window
  passes 09/12 or 10, never both.
* **Power (08, 11).** Pan Docs, Power Control: the length counters are cleared
  by a power-off on CGB and are *untouched* by power on DMG, where they also
  remain writable through NRx1 while the APU is off.

`cgb_sound` stayed 12/12 throughout.

---

## Cost

No perf cost, measured twice. Retired instructions (DINGBAT_BENCH_COUNTERS, 600
frames, 90 warmup, best of 5) move by well under a tenth of a percent on Pokemon
Crystal and Shantae, in the *fewer* direction — parking a switched-off channel's
deadline skips catch-up work that used to run.

`tests/results.md` holds at 978/691. gambatte goes **3618 -> 3646/5005**.

### The two gambatte rows this cost

`sound/ch2_late_reset_nr52_2b` and `..._ds_2b` (both `out0`, both got 2)
regressed and are still red. They are the `b` half of a two-cycle bracket around
an APU power-on that lands ~6 T-cycles before DIV's tap bit rises; `1a`, `1b`,
`2a` and the `ds_` equivalents all still pass. The cause is isolated: it is the
`first_half_of_length_period` assignment at power-on, not `div_skip`. Five
variants were measured against these 8 ROMs and the 5 SameSuite div ROMs
together:

| power-on value of `first_half_of_length_period` | gambatte | SameSuite div |
|---|---|---|
| stale (the old behaviour) | 8/8 | 2/5 |
| `= div_skip` (shipped) | 6/8 | **5/5** |
| `= true` when `div_skip`, else stale | 4/8 | 4/5 |
| always `true` | 4/8 | 4/5 |
| always `false` | 6/8 | 4/5 |

No setting reaches 8/8, so the last two rows need something other than this
knob — most likely the exact cycle on which an NR52 power-on takes effect. Net
across the two suites the shipped setting is +7 SameSuite / −2 gambatte, and
gambatte is +20 overall.

## Unserialized state

Six fields have been added across the two rounds and none is in the save state:
`GbApu.tick_phase`, `GbApu.div_skip`, `GbChannel1/2.sample_bit`,
`GbChannel3.wave_fetched`, `GbVolumeEnvChannel.env_extra_tick`. **A seventh
joins them from outside the APU: `GB.revision`** (one byte, wanted next to
`cgb_enabled` in `GB_SEC_MEM`, older states reading back the default) — see
`docs/gb-hardware-revisions.md` §2.5 for what breaks until the bump. Each is
refreshed within one duty period, one APU power cycle or one 512 Hz step of a
state load; none is CPU-visible except through PCM12/PCM34; and each is written
only by a register write or a power-on, so a rollback snapshot that replays that
write reconstructs it exactly. Serializing them costs a GB payload revision
bump, which is a decision to take once for a batch of fields rather than six
times; the field comments in `gb.nim` say so at each one. **If a GB payload bump
happens for any other reason, add these six.**

## What full accuracy would cost

Measured, on an M2, best-of-9 interleaved against a control build whose `__text`
section is byte-identical to main's:

| approach | crystal | shantae | emerald (GBA) |
|---|---|---|---|
| per-cycle APU (each channel + sequencer counted down every CPU cycle) | **-24.3%** | **-20.2%** | -0.2% |

That is a **floor** — the prototype's counters reload without doing the duty
advance, LFSR shift, wave fetch or PCM update.

The cheap alternative is **on-demand catch-up**: leave the scheduler alone and
advance the APU to the exact cycle only when software observes it. It is the
pattern the GBA core already uses for the bus (`catch_up`); the missing piece is
sub-instruction cycle tracking in the GB core. Not built, not measured.

Two rounds of source-reading have now confirmed the prediction that neither was
needed: **every one of the 39 rows recovered so far was a phase, startup or
model-axis bug at a resolution M-cycle stepping already reaches.** The remaining
CH4 divisor/shift work is the first item that plausibly does need finer
structure, and even that is about having two counters rather than about
stepping them more often.
