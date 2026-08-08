# SameSuite APU: what its sources assert, and where dingbat stands

Score: **64/70** (div 5/5, channel_1 18/21, channel_2 15/15, channel_3 15/16,
channel_4 12/13), up from 10/70. With both blargg sound suites green (dmg_sound
12/12, cgb_sound 12/12) the APU tally across all three is **88/94**, up from
29/94.

Six rows are left, and every one of them is a byte or two short rather than a
mechanism away: `channel_1_sweep_restart` 143/144 bytes,
`channel_1_freq_change_timing-cgbDE` 15/16, `-cgb0BC` 14/16,
`channel_3_extra_length_clocking-cgbB` 20/32, `channel_1_sweep_restart_2`
95/128, `channel_4_freq_change` 46/64 (written off by its own author).

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

Round three adds a corollary, from two sources whose prose is *right about the
observable and wrong about the rule*. `channel_4_delay` says "sample length + 3
M-cycles" and the real rule is `period/2 + 2`; the two agree only at the one
sample length the author happened to measure. `channel_1_sweep` has no header at
all — its assertion is a one-line comment buried between two blocks of
`SubTest`s. **Read the expected TABLE as well as the prose, and read the
comments between the subtests**; solving a table for the rule that produces it
is what separated a model from a fit in every case below.

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

## Pulse channels (channel_1 17 rows, channel_2 14 rows) — 15/17 and 12/14

| source | assertion | dingbat |
|---|---|---|
| `channel_1_align_cpu` | "Channel 1 is aligned to the APU's **enable** time, not the CPU's start time" | **matches** — `GbApu.tick_phase` is set by the NR52 power-on and `gb_trigger_deadline` rounds the trigger up to that grid |
| `channel_1_align` | "verifies that channel 1 ticks at 1MHz" | **matches** — `gb_apu_tick` |
| `channel_1_delay` | "It takes (sample length + 2) ticks from the moment channel 1 is enabled until PCM12 is affected. (The read operation itself takes 2 cycles)" | **matches** — `gb_trigger_deadline(..., 2)`. Also pins the duty TABLE: single speed, duty 3, and the expected column is Pan Docs' `01111110` indexed from position 0 |
| `channel_1_restart` | "after restarting, the start delay from the 'delay' test is actually 1 tick shorter. The countdown for the next sample is reset, but the new pulse's first sample will be the next sample the old pulse would have played" | **matches** — `extra_ticks = 1` when the channel was already on; the position is untouched |
| `channel_1_duty` | lists the duty patterns as `00000010 / 00000011 / 00001111 / 11111100` | **matches in substance.** These are the Pan Docs patterns rotated left by one, i.e. a different definition of where the counter's zero sits. A previous round proposed rotating dingbat's table or seeding the position at 1; `channel_1_delay` **falsifies both**. Do not rotate the table |
| `channel_1_duty_delay` | "Changing the duty becomes effective only after the current sample finishes" | **matches** — `GbChannel1.sample_bit` latches the duty bit once per step |
| `channel_1_freq_change` | "Changing channel 1's frequency takes effect after the current sample finishes" | **matches** — `next_step` is absolute, so a period change cannot move a pending step. The one exception is a write landing on the reload cycle itself; see the freq_change_timing note below |
| `channel_1_stop_restart` | "even after stopping the channel, the current sample index/phase remains unchanged. It is only reset by turning the APU off (NR52)" | **matches** — `ch1_catchup_at` parks `next_step` while `enabled` is false |
| `channel_1_volume_div` | "The volume envelope is triggered by the DIV register after it ticks the APU (8 * (NR12 & 7)) times (at 512Hz)" | **matches** |
| `channel_1_nrx2_speed_change` | "the envelope speed can be changed while it's active, and the change takes effect after the next time it ticks. Enabling and disabling the envelope takes effect instantly. Enabling the envelope trigger an APU bug - in the next *even* DIV-APU tick, the APU will tick the volume envelope of that apropriate channel, even if it would not tick volume envelope at that tick otherwise" | **matches** — the first two sentences were already right; the glitch is `GbVolumeEnvChannel.env_extra_tick`. "Even DIV-APU tick" is dingbat's ODD `frame_sequencer_stage`: hardware's counter increments before the step, so its tick 2 is dingbat's step 1. Fitting the parity the other way passes tests 3/4/5 but fails 6/7, which is why those two exist |
| `channel_1_restart_nrx2_glitch` | "restarting the channel after triggering the NRx2 write glitch works as expected" | **matches** |
| `channel_1_nrx2_glitch` | "This tests the NRx2 write glitch ('Zombie Mode'). **It appears to be different across revisions**" | **matches**, 16/16 bytes. See below |
| `channel_1_volume` | "Attempts to change the volume of channel 1 without triggering the NRx2 write glitch" | **matches**, 128/128 bytes. Same mechanism |
| `channel_1_stop_div` | "Channel 1 behave similarly to channel 3, but with a smaller length range. See channel_3_stop_div" | **matches**, and it came free with the DIV-APU work |
| `channel_1_sweep` | *(no header, but see the annotation quoted below)* | **matches**, 144/144 |
| `channel_1_sweep_restart` | "Several tests involving restarting the channel while sweep is active" | **does not match**, but only just: 143/144, up from 85. Rounds 2-5 and 6-9 are exact; the one bad byte is in round 1, where a duty step lands on the observing read's exact cycle |
| `channel_1_sweep_restart_2` | "Part 2" | **does not match**, 95/128. See below |
| `channel_1_extra_length_clocking-cgb0B` | quotes the extra-length-clocking rule in full, then: "On revisions <= CPU CGB B, the length counter only has to have been disabled before; the current length enable state doesn't matter… fixed on CPU CGB C" | **matches on `--model=cgb0B`** (`GbQuirks.length_clock_any_nrx4`), and correctly does NOT on the default. Not a shootout row |
| `channel_1_freq_change_timing-A/-cgb0BC/-cgbDE` | *(no header; three ROMs, three CPU revisions)* | `-A` **matches**, 16/16; `-cgbDE` 15/16 and `-cgb0BC` 14/16. See below. Not shootout rows |

### The sweep's second overflow check is 8 M-cycles late, and re-reads NR10

Pan Docs describes the sweep step as one indivisible event: compute the new
frequency, disable on overflow, otherwise write it back and compute AGAIN,
disabling on overflow. Three SameSuite sources say the second calculation is
not part of that event at all, in the same words each time.

`channel_1_sweep` annotates the subtest block where its round-3 channel finally
goes quiet — 8 nops past the DIV-APU tick that did the sweep — with **"8 cycles
after trigger, the APU checks if the NEXT trigger overflows the frequency. If it
does, stop the channel"**. `channel_1_sweep_restart`'s rounds 3, 4 and 5 each
open with **"the channel should stop after 8 cycles, but we <do something to
NR10> before then"**, and those three rounds are what make the delay more than a
curiosity: the check reads NR10 **as it stands 8 M-cycles later**, so zeroing
NR10 cancels the stop outright (round 3) while merely changing the shift does
not (rounds 4 and 5). The gate is therefore the SHIFT, not the sweep period —
which it has to be anyway, because a trigger arms this check with sweep period 0
(blargg cgb_sound `06-overflow on trigger`).

The FIRST calculation is not delayed. `channel_1_sweep_restart_2` drives a sweep
whose first calculation overflows — NR10 shift 0, so the new frequency is twice
the old — and its channel stops with no 8-cycle grace at all.

An NRx4 TRIGGER's own overflow check ("if the shift is non-zero, frequency
calculation and the overflow check are performed immediately") gets the same
delay plus one APU tick: the write is latched on a tick edge and the countdown
starts on the tick after it. `channel_1_sweep_restart` round 2 measures exactly
that — restart a channel whose next sweep overflows and it stays audible for
nine more M-cycles, not eight.

**`channel_1_sweep` (144/144) and `channel_1_sweep_restart` 85 -> 143/144.** The
code is `GB_SWEEP_CHECK_DELAY`, `ch1_sweep_check_due` and the arm in `ch1_write`.

#### The trap this sets, and the one row it does not reach

Making a lazily-evaluated check able to clear `enabled` broke
`blargg/cgb_sound/07-len sweep period sync`, which had nothing to do with sweep
periods: `apu_read` deliberately did not catch CH1 up for NR52 ("reports
`enabled`, which no catch-up can change"), and blargg's `sync_sweep` helper is a
loop that polls NR52 waiting for a sweep overflow to disable the channel. It now
runs the pending check on an NR52 read. **If anything else is ever made to
change `enabled` off the register-write path, check every reader of it.**

`channel_1_sweep_restart_2` (95/128) is the row left, and it is unfinished
rather than blocked. What it measures is when a trigger's copy of NR13/NR14 into
the sweep SHADOW register becomes visible to the sweep unit: its channel is
disabled only when the restart lands 3 or more M-cycles before the DIV-APU
sweep, where dingbat disables whenever the restart lands at or before it. A
3 M-cycle shadow-copy pipeline plus a 1 M-cycle latency on the first
calculation's disable reproduces all 128 bytes — but both constants are visible
only in this one ROM, there is no test to cross-validate them against, and
fitting two numbers to one table is the thing this file exists to argue against.

### A register write and a timer reload on the same cycle: the write wins

`channel_1_freq_change_timing` ships as three ROMs, one per CPU revision, with
no header. Each triggers CH1 at frequency `$7fc` (4 M-cycles per sample), writes
NR14 = 0 after N nops to stretch the period to ~1800 M-cycles (freezing the duty
counter), and reports the sample right after that write and the sample it
settles on. Its single-speed row falls out byte for byte from one rule and no
other: **when the NR13/NR14 write lands on the exact cycle the frequency timer
reloads, the reload takes the value being written.** The step still happens — the
duty position advances — but the counter is loaded with the new period, so the
sample that was about to be played never is. A write one M-cycle later leaves
the pending sample alone, which is `channel_1_freq_change`'s "takes effect after
the current sample finishes"; the two are the same rule seen from either side of
one cycle, and `channel_1_freq_change` stays 128/128.

Detecting that tie needs `GbChannel1.last_step_at`. `next_step` alone will not
do: a trigger's start delay is `period + 2 ticks`, so a write two M-cycles after
a trigger leaves `next_step` exactly one period out and looks like a reload —
which is precisely the subtest `channel_1_freq_change`'s row 2 uses, and fitting
the rule without the new field costs that ROM.

The rule is mirrored onto CH2, which is the same duty hardware minus the sweep.
SameSuite ships no `channel_2_freq_change_timing`, so that half is by symmetry
and not by measurement; the channel_2 mirrors of every other pulse test still
pass either way.

**`-A` passes 16/16.** `-cgbDE` reaches 15/16 and `-cgb0BC` 14/16, and the
remaining bytes are all in the DOUBLE-SPEED row — which is the only row the
three ROMs disagree on, so at most one of them can ever pass on one machine.
dingbat's double-speed duty phase currently matches what the ROMs say AGB does.
Getting `-cgbDE` (the revision dingbat actually models) would mean a per-revision
double-speed duty phase, and would cost `-A`.

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

## Channel 4 (12 shootout rows) — 11/12

| source | assertion | dingbat |
|---|---|---|
| `channel_4_lfsr` / `_lfsr15` | "verifies the LFSR algorithm used is correct" | **matches.** dingbat's register is the BIT-COMPLEMENT of the usual convention: `lfsr = 0x7FFF` at trigger with `output = not bit0` is the same machine as `lfsr = 0` with `output = bit0`. **`channel_4_lfsr_restart`'s "the contents of the LFSR register are cleared on restart" is therefore already satisfied — setting it to 0 would break three passing rows.** This trap is why the sentence is worth writing down |
| `channel_4_lfsr_15_7` / `_7_15` | "the contents of the LFSR are retained correctly when switching" | **matches** — dingbat never truncates the upper bits |
| `channel_4_volume_div` | as the pulse version | **matches** |
| `channel_4_align` | "verifies that channel 1 [sic — it means 4] ticks at 1MHz" | **matches, after a fix** — CH4's trigger now goes through the same `gb_trigger_deadline` grid alignment as the squares |
| `channel_4_delay` | "**the delay is `sample length + 3` M-cycles, but it might be one M-cycle more or less**… I'm not completely sure about this logic yet. It appears to be related to how the noise frequency is made out of two different values" | **matches**, all 32 bytes. The delay is not `sample length + 3`; it is `period/2 + 2` M-cycles, and those two agree only at the 2 M-cycle sample the "+3" was read off. See below |
| `channel_4_frequency_alignment` | *(no prose; the assertion is the annotation on its expected table)* | **matches**, 144/144. See below |
| `channel_4_equivalent_frequencies` | "identical frequencies that are expressed differently generate the same output, other than a potential off-by-one sample caused by the start delay" | **matches**, 128/128, and it is the cross-check for the whole noise model: one encoding per rounding case, 512 nops deep into the LFSR sequence |
| `channel_4_lfsr_restart` / `_restart_fast` | "the contents of the LFSR register are cleared on restart / even on a fast restart" | **match**, and NOT for the reason the header suggests: the LFSR was always being cleared. Their expected tables are `channel_4_lfsr`'s shifted by exactly one LFSR step, i.e. a RESTART's first sample takes a full period where a fresh trigger's takes half |
| `channel_4_freq_change` | "what happens when changing the frequency of channel 4 while it's playing. **Unfortunately the logic behind it is still unclear**" | written off by its own author |
| `channel_4_extra_length_clocking-cgb0B` | per-revision | not a shootout row |

### The noise start delay: half a period, off a grid the trigger cannot reset

The previous round's diagnosis — "the divisor and the shift need two real
cascaded counters" — was wrong, and usefully so. `ch4_frequency_timer` still
collapses NR43 into one scalar `divisor << shift`, and that is fine: the PERIOD
really is a single number. What differs between two encodings of the same period
is only the PHASE the trigger starts them at, and that is expressible exactly.

Two facts, both solved out of the expected tables rather than swept for:

**1. A trigger's first period is half-length.** `channel_4_delay` drives NR43 =
`$08, $00, $18, $28`, i.e. sample lengths of 2, 2, 4 and 8 M-cycles, and its
first sample lands 3, 3, 4 and 6 M-cycles after the write. That is
`period/2 + 2`, not the `period + 1` the source's own "sample length + 3
M-cycles" prose suggests; the two agree only at the 2 M-cycle sample, which is
the one the author measured. The natural reading is a divide-by-two on the
divisor stage's output whose flip-flop a trigger clears, so the first edge
arrives after one half-period. A RESTART of an already-running channel leaves
that flip-flop alone and waits a full period — which is exactly the one-LFSR-step
offset between `channel_4_lfsr`'s expected table and `channel_4_lfsr_restart`'s.
(Both restart tests use a 2 M-cycle sample, where `period` and
`period/2 + one tick` are the same number, so they pin the SIZE of the restart
penalty and not its form.)

**2. The divisor stage counts on a 512 kHz grid the trigger cannot reset.**
`channel_4_frequency_alignment` runs nine NR43 encodings twice, once with an
extra nop before the trigger, and annotates each row "affected" or "not
affected". The split is exactly `divisor_code == 0`. Solving all 18 rows for the
effective start:

```
divisor_code == 0   start at the 1 MHz tick, like every other channel
divisor_code == 1   round that tick UP   to the 512 kHz grid
divisor_code >= 2   round that tick DOWN to the 512 kHz grid
```

The 512 kHz grid sits on the odd 1 MHz ticks counted from the APU power-on
(`GbApu.noise_phase`), which is why a power-on and not a trigger is what makes
these tests repeatable at all — every subtest power-cycles the APU, and if the
grid were anchored to anything free-running the expected tables could not be
monotone. Divisor code 0 escaping the grid is the "made out of two different
values" remark: code 0 means 8 T-cycles where every other code means `16*code`,
so it taps the half-step of the same divider and keeps 1 MHz resolution.

`channel_4_equivalent_frequencies` is the cross-check, not a second fit. It
drives `$0c`, `$1a`, `$29` and `$38` — one encoding per rounding case, all four
with a 16 M-cycle sample — 512 nops deep into the LFSR sequence, where a
one-M-cycle phase error moves a transition by a whole subtest. All 128 bytes fall
out. **5 rows** (`delay`, `frequency_alignment`, `equivalent_frequencies`,
`lfsr_restart`, `lfsr_restart_fast`); the code is `gb_noise_deadline`.

`divisor_code` 5-7 are not exercised by any SameSuite test and follow the `>= 2`
case because that is the only evidence there is.

### What is left on channel 4

`channel_4_freq_change` (46/64 bytes) is the only red row, and its header says
"Unfortunately the logic behind it is still unclear". It is the one test that
changes NR43 mid-flight, i.e. it asks what happens to the divisor stage's
in-progress count when the period changes under it — the question the model
above deliberately does not answer, because nothing else asks it.

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

Rounds one and two cost nothing, in the *fewer* direction — parking a
switched-off channel's deadline skipped catch-up work that used to run.

**Round three costs about a sixth of a percent.** Retired instructions
(DINGBAT_BENCH_COUNTERS, 600 frames, 90 warmup, best of 5, interleaved against a
control built from the same tree with only these files reverted): Pokemon
Crystal **+0.17%**, Shantae **+0.09%**. Both framebuffer-hash-identical over 600
frames. The cost is the pending-sweep-check guard, which sits in `ch1_catchup_at`
— the hottest proc in the APU — plus the `last_step_at` store in each square's
catch-up. Splitting the check's body out into a non-inline `ch1_sweep_check_run`
and leaving only the compare inline recovered roughly a third of it; the rest is
the stores. Worth knowing before adding a fourth per-catch-up test.

`tests/results.md` holds at 978/703 and gambatte at **3656/5005**, both
unchanged to the row.

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

Ten fields have been added across the three rounds and none is in the save
state. Rounds one and two: `GbApu.tick_phase`, `GbApu.div_skip`,
`GbChannel1/2.sample_bit`, `GbChannel3.wave_fetched`,
`GbVolumeEnvChannel.env_extra_tick`. Round three adds four more:

* **`GbApu.noise_phase`** — the 512 kHz grid the noise divisor counts on, set by
  an APU power-on exactly like `tick_phase`, worth at most one 1 MHz tick of
  noise phase if lost.
* **`GbChannel1.sweep_check_at`** — the pending sweep overflow check. Pending
  for at most 8 M-cycles once per sweep period. `savestate.nim`'s CH1 load path
  clears it explicitly: a deadline left over from the state being REPLACED would
  otherwise fire against the loaded registers.
* **`GbChannel1.last_step_at` / `GbChannel2.last_step_at`** — decide a one-cycle
  tie on an NR13/NR14 write and are rewritten by the next duty step, i.e. within
  one sample. `apu_rebase` clears them rather than shifting them (they are in the
  past and would underflow); losing a tie on a frame boundary is not observable.

**An eleventh joins them from outside the APU: `GB.revision`** (one byte, wanted next to
`cgb_enabled` in `GB_SEC_MEM`, older states reading back the default) — see
`docs/gb-hardware-revisions.md` §2.5 for what breaks until the bump. Each is
refreshed within one duty period, one APU power cycle or one 512 Hz step of a
state load; none is CPU-visible except through PCM12/PCM34; and each is written
only by a register write or a power-on, so a rollback snapshot that replays that
write reconstructs it exactly. Serializing them costs a GB payload revision
bump, which is a decision to take once for a batch of fields rather than ten
times; the field comments in `gb.nim` say so at each one. **If a GB payload bump
happens for any other reason, add these ten.**

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

Three rounds of source-reading have now confirmed the prediction that neither
was needed: **every one of the 46 rows recovered so far was a phase, startup or
model-axis bug at a resolution M-cycle stepping already reaches.** Round two
guessed that the CH4 divisor/shift problem would be the first item to need finer
structure. It did not: it needed a half-period start delay and a grid the
trigger cannot reset, both of which land on whole M-cycles. Nothing left on the
board argues for a per-cycle APU either — the three remaining reachable-looking
rows want a 1-3 M-cycle pipeline on a register copy, which is state, not
resolution.
